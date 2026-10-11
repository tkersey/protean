// Independent archive peer using the existing ordinary value codec. It never
// imports native implementation code or treats an archive as execution authority.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {decodeSchema, decodeValue, encodeValue} from '../support/values.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest();
const key = reference => Buffer.from(reference[0]).toString('hex');
const taskFields = ['id', 'application_id', 'input_schema_id', 'output_schema_id', 'failure_schema_id', 'message_schema_id', 'principal', 'tenant', 'profile_id', 'profile', 'resources', 'image', 'runtime_identity', 'input', 'checkpoint', 'outcome', 'outcome_kind', 'current_occurrence', 'revision', 'execution_revision', 'schedule', 'cancellation', 'cancellation_applied', 'blocker', 'result', 'client_result', 'result_artifact', 'event_floor', 'event_high', 'next_message', 'messages', 'inference_attempts', 'inference_request_bytes', 'inference_output_tokens', 'evidence_bytes'];

export function readArchive(bytes) {
  assert.equal(bytes.subarray(0, 8).toString(), 'AGNX0001');
  const schemaLength = bytes.readUInt32LE(8), manifestLength = bytes.readUInt32LE(12);
  assert(schemaLength <= 65536 && manifestLength <= 1048576);
  assert.equal(bytes.readUInt32LE(20), 0);
  const schemaBytes = bytes.subarray(32, 32 + schemaLength);
  const schema = decodeSchema(schemaBytes);
  const manifest = decodeValue(schema, bytes.subarray(32 + schemaLength, 32 + schemaLength + manifestLength));
  assert.equal(manifest.length, 11);
  assert.deepEqual(manifest.slice(0, 3), [1, 0, 0]);
  const [,,, taskReference, buildReference, definitions,,,,, references] = manifest;
  assert.equal(references.length, bytes.readUInt32LE(16));
  let offset = 32 + schemaLength + manifestLength;
  assert.equal(BigInt(bytes.length - offset), bytes.readBigUInt64LE(24));
  const objects = new Map();
  let previous = '';
  for (const reference of references) {
    const digest = key(reference), length = Number(reference[1]);
    assert(Number.isSafeInteger(length) && length >= 0 && length <= 16 * 1024 * 1024);
    assert(previous < digest);
    const value = bytes.subarray(offset, offset + length);
    assert.equal(value.length, length);
    assert.equal(hash(value).toString('hex'), digest);
    objects.set(digest, value);
    offset += length;
    previous = digest;
  }
  assert.equal(offset, bytes.length);
  const object = reference => {
    const bytes = objects.get(key(reference));
    assert(bytes, 'missing independent archive object');
    assert.equal(BigInt(bytes.length), reference[1]);
    return bytes;
  };
  const schemas = new Map(definitions.map(([name, reference]) => [name, decodeSchema(object(reference))]));
  assert.deepEqual([...schemas.keys()], ['task', 'event', 'receipt', 'occurrence', 'question', 'message', 'artifact', 'capture', 'attempt', 'origin']);
  const taskValue = decodeValue(schemas.get('task'), object(taskReference));
  assert.equal(taskValue.length, taskFields.length);
  const task = Object.fromEntries(taskFields.map((name, index) => [name, taskValue[index]]));
  const build = JSON.parse(object(buildReference));
  assert.equal(object(task.image).subarray(0, 8).toString(), 'ABL_BPI3');
  assert.equal(object(task.checkpoint).subarray(0, 8).toString(), 'ABL_PST3');
  assert.equal(object(task.outcome).subarray(0, 8).toString(), 'ABL_PKO3');
  assert.equal(key(task.image), build.program_sha256);
  return {schemaBytes, schema, manifest, objects, schemas, taskValue, task, build, object};
}

function encode(archive) {
  const references = [...archive.objects].sort(([left], [right]) => left.localeCompare(right)).map(([digest, bytes]) => [[...Buffer.from(digest, 'hex')], BigInt(bytes.length)]);
  archive.manifest[10] = references;
  const manifest = Buffer.from(encodeValue(archive.schema, archive.manifest));
  const body = references.map(reference => archive.objects.get(key(reference)));
  const header = Buffer.alloc(32);
  header.write('AGNX0001');
  header.writeUInt32LE(archive.schemaBytes.length, 8);
  header.writeUInt32LE(manifest.length, 12);
  header.writeUInt32LE(references.length, 16);
  header.writeBigUInt64LE(BigInt(body.reduce((n, bytes) => n + bytes.length, 0)), 24);
  return Buffer.concat([header, archive.schemaBytes, manifest, ...body]);
}
function replace(archive, oldReference, bytes) {
  if (oldReference) archive.objects.delete(key(oldReference));
  const digest = hash(bytes);
  archive.objects.set(digest.toString('hex'), bytes);
  return [[...digest], BigInt(bytes.length)];
}
export function missingCaptures(bytes, change = 'all') {
  const archive = readArchive(bytes);
  assert.equal(archive.task.inference_output_tokens, 0n, 'absent usage must not mask capture completeness');
  const captures = archive.manifest[6].filter(([kind]) => kind === 4);
  assert(captures.length > 1);
  const removed = change === 'all' ? captures : captures.slice(0, 1);
  for (const row of removed) {
    const capture = decodeValue(archive.schemas.get('capture'), archive.object(row[2]));
    assert.equal(capture[4].tag, 1);
    assert.equal(capture[6].tag, 1);
    archive.objects.delete(key(row[2]));
    archive.objects.delete(key(capture[4].value));
    for (const reference of capture[6].value[1]) archive.objects.delete(key(reference));
    archive.manifest[6] = archive.manifest[6].filter(candidate => candidate !== row);
    if (change === 'prepared-marker') {
      const attempt = archive.manifest[6].find(([kind, id]) => kind === 5 && Buffer.from(id).equals(Buffer.from(row[1])));
      assert(attempt);
      const value = decodeValue(archive.schemas.get('attempt'), archive.object(attempt[2]));
      assert.equal(value[7].tag, 1);
      // Prepared bytes remain charged in the task counter. Preserve the byte
      // total so this sibling reaches handler/attempt coherence admission.
      archive.taskValue[taskFields.indexOf('inference_request_bytes')] += value[3][1] - value[7].value[1];
      archive.objects.delete(key(value[7].value));
      value[7] = {tag: 0, value: null};
      attempt[2] = replace(archive, attempt[2], Buffer.from(encodeValue(archive.schemas.get('attempt'), value)));
      archive.manifest[3] = replace(archive, archive.manifest[3], Buffer.from(encodeValue(archive.schemas.get('task'), archive.taskValue)));
    }
  }
  return encode(archive);
}

// Keep the original raw object available to its audit dependents while changing
// the response selected by one capture record. This reaches pure projection
// comparison instead of merely breaking the archive's hash graph.
export function tamperedAdaptiveControl(bytes, capturedResponseSchema) {
  const archive = readArchive(bytes);
  for (const row of archive.manifest[6]) {
    if (row[0] !== 4) continue;
    const attemptRow = archive.manifest[6].find(([kind, id]) => kind === 5 && Buffer.from(id).equals(Buffer.from(row[1])));
    const attempt = decodeValue(archive.schemas.get('attempt'), archive.object(attemptRow[2]));
    if (attempt[5] !== 'agent.model.invoke.v6') continue;
    const capture = decodeValue(archive.schemas.get('capture'), archive.object(row[2]));
    const raw = decodeValue(capturedResponseSchema, archive.object(capture[4].value));
    const body = JSON.parse(Buffer.from(raw[3]).toString('utf8'));
    const call = body.output.find(item => item.type === 'function_call' && item.name === 'inference_set');
    if (!call) continue;
    const args = JSON.parse(call.arguments); args.expected_revision++; call.arguments = JSON.stringify(args);
    raw[3] = Buffer.from(JSON.stringify(body));
    capture[4] = {tag: 1, value: replace(archive, null, Buffer.from(encodeValue(capturedResponseSchema, raw)))};
    row[2] = replace(archive, row[2], Buffer.from(encodeValue(archive.schemas.get('capture'), capture)));
    return encode(archive);
  }
  assert.fail('adaptive inference control capture is required');
}

function pruneObjects(archive) {
  const retained = new Set();
  const visit = value => {
    if (Array.isArray(value)) {
      if (value.length === 2 && Array.isArray(value[0]) && value[0].length === 32 && typeof value[1] === 'bigint') retained.add(key(value));
      else value.forEach(visit);
    } else if (value && typeof value === 'object') Object.values(value).forEach(visit);
  };
  visit(archive.manifest.slice(3, 10));
  visit(archive.taskValue);
  const kinds = ['occurrence', 'question', 'message', 'artifact', 'capture', 'attempt', 'origin'];
  for (const [kind,, reference] of archive.manifest[6]) {
    const value = decodeValue(archive.schemas.get(kinds[kind]), archive.object(reference));
    visit(value);
    if (kind === 0) {
      const state = value[3];
      const reply = state.tag === 4 ? state.value : state.tag === 5 && state.value.tag === 0 ? state.value.value : null;
      if (reply) retained.add(Buffer.from(reply[1]).toString('hex'));
    }
  }
  for (const row of archive.manifest[7]) visit(decodeValue(archive.schemas.get('event'), archive.object(row[2])));
  for (const row of archive.manifest[8]) visit(decodeValue(archive.schemas.get('receipt'), archive.object(row[2])));
  for (const digest of archive.objects.keys()) if (!retained.has(digest)) archive.objects.delete(digest);
}


export function missingCheckpoint(bytes) {
  const archive = readArchive(bytes);
  archive.objects.delete(key(archive.task.checkpoint));
  return encode(archive);
}

export function changedProfile(bytes) {
  const archive = readArchive(bytes);
  const profile = JSON.parse(archive.object(archive.task.profile));
  archive.taskValue[9] = replace(archive, null, Buffer.from(JSON.stringify({...profile, changed_profile: true})));
  archive.manifest[3] = replace(archive, archive.manifest[3], Buffer.from(encodeValue(archive.schemas.get('task'), archive.taskValue)));
  return encode(archive);
}

export function extraPrivateArtifact(bytes, source = 'checkpoint') {
  const archive = readArchive(bytes);
  let reference = archive.task[source];
  if (source === 'capture') {
    const row = archive.manifest[6].find(([kind]) => kind === 4);
    assert(row);
    const capture = decodeValue(archive.schemas.get('capture'), archive.object(row[2]));
    assert.equal(capture[4].tag, 1);
    reference = capture[4].value;
  }
  assert(reference);
  archive.object(reference); // the bytes already belong to the private archive
  const id = [...hash(Buffer.from('unpublished private artifact'))];
  const artifact = [id, {tag: 1, value: archive.task.id}, reference, 'application/octet-stream', {tag: 0, value: null}];
  const body = replace(archive, null, Buffer.from(encodeValue(archive.schemas.get('artifact'), artifact)));
  archive.manifest[6].push([3, id, body]);
  archive.manifest[6].sort((left, right) => left[0] - right[0] || Buffer.compare(Buffer.from(left[1]), Buffer.from(right[1])));
  return encode(archive);
}

export function omittedAttempts(bytes) {
  const archive = readArchive(bytes);
  assert(archive.manifest[6].some(([kind]) => kind === 5));
  archive.manifest[6] = archive.manifest[6].filter(([kind]) => kind !== 4 && kind !== 5);
  archive.manifest[9] = [];
  for (const field of ['inference_attempts', 'inference_request_bytes']) archive.taskValue[taskFields.indexOf(field)] = field === 'inference_attempts' ? 0 : 0n;
  archive.manifest[3] = replace(archive, archive.manifest[3], Buffer.from(encodeValue(archive.schemas.get('task'), archive.taskValue)));
  pruneObjects(archive);
  return encode(archive);
}

export function changedOperationKey(bytes, change = 'key') {
  const archive = readArchive(bytes);
  const row = archive.manifest[8].find(row => decodeValue(archive.schemas.get('receipt'), archive.object(row[2]))[2] === 0);
  assert(row, 'fixture must retain submission receipt');
  if (change === 'omitted') {
    archive.manifest[8] = archive.manifest[8].filter(item => item !== row);
    archive.objects.delete(key(row[2]));
  } else row[0] = 'f'.repeat(64);
  archive.manifest[8].sort((a, b) => a[0].localeCompare(b[0]));
  return encode(archive);
}

export function invalidEventData(bytes, change) {
  const archive = readArchive(bytes);
  const row = archive.manifest[7].find(row => decodeValue(archive.schemas.get('event'), archive.object(row[2]))[3] === (change === 'question-counter' ? 1 : 0));
  assert(row);
  const value = decodeValue(archive.schemas.get('event'), archive.object(row[2]));
  const payload = JSON.parse(Buffer.from(value[4]).toString());
  const replacement = change === 'null' ? null : change === 'extra-field' ? {extra: true} : {...payload, question_revision: 1};
  value[4] = [...Buffer.from(JSON.stringify(replacement))];
  row[2] = replace(archive, row[2], Buffer.from(encodeValue(archive.schemas.get('event'), value)));
  return encode(archive);
}
