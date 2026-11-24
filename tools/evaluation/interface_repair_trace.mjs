import {createHash} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {contract} from '../../test/protean/adaptive_capture_checks.mjs';
import {decodeSchema, decodeValue, encodeSchema, ValueCodecError} from '../../test/support/values.mjs';
import {acquiredPageRanges, physicalProviderAttempt} from './workspace.mjs';
import {assessScan, canonicalEvidence, collisionProbe, inspectProjection, parseCandidate, samePresentedValue, strictJson, unsignedJsonInteger} from './interface_repair.mjs';

const hex = bytes => Buffer.from(bytes).toString('hex');
const digest = ref => ref && hex(ref[0]);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const some = option => option?.tag === 1 ? option.value : null;
const ref = (kind, id) => ({kind, id});
const same = (a, b) => a && b && a.kind === b.kind && a.id === b.id;
const observationId = value => value?.[0] === 12 && typeof value[1] === 'string' && /^[a-f0-9]{64}$/i.test(value[1]) ?
  value[1].toLowerCase() : null;
const actionRef = value => typeof value?.id === 'string' && /^[a-f0-9]{64}$/i.test(value.id) ?
  ref(value.kind, value.id.toLowerCase()) : value;
const typed = (archive, schema, bytes) => decodeValue(decodeSchema(archive.object(schema)), archive.object(bytes));
const schemaId = (types, root) => sha(encodeSchema({types, root}));
const scanTypes = [
  {product: [1, 2]}, {product: [3, 3, 4, 5]}, {seq: 6}, 'u64', 'boolean', {seq: 3},
  {product: [3, 3, 3, 4, 3, 7]}, {product: [8, 9]}, {enumeration: Array.from({length: 13}, (_, i) => i)},
  {bounded_text: 64}, {sum: [6, 0, 11]}, {product: [12, 0]}, {enumeration: [0, 1, 2, 3]},
];
const inputSchemaId = schemaId([...scanTypes, {product: [7, 0]}], scanTypes.length);
const scanSchemas = new Map([[schemaId(scanTypes, 0), 'ScanEvidence'], [schemaId(scanTypes, 10), 'ScanOutcome']]);
const proposalSchemaId = schemaId([{product: [1, 4]}, {product: [2, 3]}, scanTypes[8], {bounded_text: 64},
  {seq: 5}, {sum: [1, 6, 7, 9]}, {product: []}, {product: [1, 8, 8]}, 'u64', 'text'], 0);

function payloadSchema(descriptor) {
  const fields = descriptor.types[descriptor.root].product;
  return fields?.length === 2 && schemaId(descriptor.types, fields[0]) === proposalSchemaId ?
    encodeSchema({types: descriptor.types, root: fields[1]}) : null;
}

function displayedSchema(bytes) {
  return {root: '0', types: decodeSchema(bytes).types.map(type => {
    if (typeof type === 'string') return {tag: type, value: {}};
    const [[tag, raw]] = Object.entries(type);
    const value = tag === 'enumeration' ? raw : Array.isArray(raw) ? raw.map(String) :
      typeof raw === 'object' ? Object.fromEntries(Object.entries(raw).map(([key, n]) => [key, String(n)])) : String(raw);
    return {tag, value};
  })};
}

export function inspectProjectionResult(descriptor, bytes) {
  const bytesSchema = payloadSchema(descriptor);
  if (!bytesSchema) return {inspection_error: 'InvalidProjectionSchema'};
  const schema = sha(bytesSchema), display = displayedSchema(bytesSchema);
  try {
    const [proposal, value] = decodeValue(descriptor, bytes);
    const computed = proposal[1].some(b => b.tag === 1);
    return {consumer: proposal[0], has_computed_block: computed, one_computed_block: computed && proposal[1].length === 1,
      schema, display, value, payload: renderedValue(value)};
  } catch (error) {
    if (!(error instanceof ValueCodecError || error instanceof RangeError)) throw error;
    return {schema, display, inspection_error: error.code ?? 'ValueCapacity'};
  }
}

export function diagnosticPresentation(presentation, expectedConsumer) {
  const id = observationId(presentation.consumer);
  const error = presentation.inspection_error ?? (!id || id !== observationId(expectedConsumer) ? 'ConsumerMismatch' :
    presentation.one_computed_block ? null : 'ExpectedOneComputedBlock');
  return error ? {inspection_error: error} : {inspection_error: null, payload: presentation.payload};
}

function inventory(archive, kind, schema) {
  return archive.manifest[6].filter(row => row[0] === kind).map(([, id, body]) => {
    const raw = decodeValue(archive.schemas.get(schema), archive.object(body));
    return {id: hex(id), body: digest(body), raw};
  });
}

function material(archive, program) {
  const [, , artifact, d] = program.raw;
  const source = archive.object(d[1]);
  return {program: ref('program', digest(artifact)), source_b64: source.toString('base64'),
    source_sha256: digest(d[1]), image_sha256: digest(d[5]), input_schema_sha256: digest(d[6]),
    result_schema_sha256: digest(d[7]), failure_schema_sha256: digest(d[8]),
    entry: JSON.parse(source).module.entry};
}

function acquisitions(archive, values, specimen, receipt, manifestPath = 'scan.json') {
  const refs = Object.create(null), visits = JSON.parse(specimen.files['scan.json']).visits;
  if (!values.size) return refs;
  const {pinned, excluded, files} = repairSnapshot(archive);
  const snapshotRef = [pinned.digest, BigInt(pinned.bytes)];
  if (excluded !== 0n) return refs;
  for (const path of ['scan.json', ...visits.map(v => v.path)]) {
    const bytes = specimen.files[path], file = files.get(path === 'scan.json' ? manifestPath : path);
    if (file ? typeof bytes !== 'string' || sha(bytes) !== file.hash || !file.bytes.equals(Buffer.from(bytes)) :
        bytes !== undefined) return refs;
  }
  const expected = new Map(visits.map((v, i) => [v.path, receipt?.visits?.[i]]));
  expected.set('scan.json', receipt?.manifest);
  for (const {raw} of values.values()) {
    const acquisition = some(raw[4][4]);
    if (raw[4][0] !== 2 || !acquisition) continue;
    const [snapshot, actualPath, fileDigest, start, end, size] = acquisition;
    if (digest(snapshot) !== digest(snapshotRef) || snapshot[1] !== snapshotRef[1]) continue;
    const path = actualPath === manifestPath ? 'scan.json' : actualPath;
    if (path === 'scan.json' && actualPath !== manifestPath) continue;
    const content = specimen.files[path], value = ref('value', digest(raw[2]));
    if (typeof content !== 'string' || hex(fileDigest) !== sha(content) || start !== 0n ||
        end !== BigInt(Buffer.byteLength(content)) || size !== end ||
        typed(archive, raw[3][1], raw[3][2]) !== content ||
        (receipt && (!expected.has(path) || !same(expected.get(path), value)))) continue;
    refs[path] = value;
  }
  return refs;
}

export function canonicalProjectionInput(values, inputRef, specimen, sourceRefs, actual, observedConsumerId) {
  const paths = ['scan.json', ...JSON.parse(specimen.files['scan.json']).visits.map(v => v.path)
    .filter(path => Object.hasOwn(specimen.files, path))];
  if (!observedConsumerId || observationId(actual?.[0]) !== observedConsumerId ||
      paths.some(path => !sourceRefs[path]) || !equal(actual[1], canonicalEvidence(specimen, sourceRefs))) return false;
  const todo = [digest(inputRef)], ancestry = new Set();
  while (todo.length) {
    const id = todo.pop();
    if (ancestry.has(id)) continue;
    ancestry.add(id);
    for (const source of values.get(id)?.raw[4][1] ?? []) todo.push(digest(source));
  }
  return paths.every(path => ancestry.has(sourceRefs[path].id));
}

function scanInput(archive, input) {
  if (digest(input.raw[3][1]) !== inputSchemaId) return null;
  try { return typed(archive, input.raw[3][1], input.raw[3][2]); }
  catch (error) {
    if (error instanceof ValueCodecError) return null;
    throw error;
  }
}

const nonempty = value => typeof value === 'string' && value.length > 0;

function modelItem(item, incomplete) {
  if (item?.status !== 'completed' && !(incomplete && ['incomplete','in_progress'].includes(item?.status)) &&
      !(item?.type === 'reasoning' && item.status === undefined)) return false;
  if (item.type === 'function_call') return nonempty(item.call_id) && nonempty(item.name) && typeof item.arguments === 'string';
  if (item.type === 'reasoning') return nonempty(item.encrypted_content) ||
    Array.isArray(item.summary) && item.summary.some(p => p?.type === 'summary_text' && nonempty(p.text)) ||
    Array.isArray(item.content) && item.content.some(p => p?.type === 'reasoning_text' && nonempty(p.text));
  return item.type === 'message' && item.role === 'assistant' && Array.isArray(item.content) &&
    item.content.some(p => p?.type === 'output_text' && nonempty(p.text) || p?.type === 'refusal' && nonempty(p.refusal));
}

const finalizedItem = item => item && ['function_call', 'message', 'reasoning'].includes(item.type) &&
  (item.status === 'completed' || item.type === 'reasoning' && item.status === undefined);

function reconcileOutput(items, roster) {
  if (!Array.isArray(roster) || roster.length > items.size) return null;
  const ordered = Array.from({length: items.size}, (_, i) => items.get(BigInt(i)));
  if (!ordered.every(finalizedItem)) return null;
  let previous = -1;
  for (const [i, part] of roster.entries()) {
    if (!part || typeof part !== 'object') return null;
    const k = ordered.length === roster.length ? i : ordered.findIndex(item =>
      ['id', 'call_id'].some(key => nonempty(part[key]) && part[key] === item[key]));
    if (k <= previous || part.type !== ordered[k].type) return null;
    const pending = [[ordered[k], part]];
    while (pending.length) {
      const [target, patch] = pending.pop();
      if (target === patch) continue;
      if (JSON.isRawJSON(target) || JSON.isRawJSON(patch)) {
        if (!JSON.isRawJSON(target) || !JSON.isRawJSON(patch) || target.rawJSON !== patch.rawJSON) return null;
        continue;
      }
      if (!target || !patch || typeof target !== 'object' || typeof patch !== 'object' ||
          Array.isArray(target) !== Array.isArray(patch) || Array.isArray(target) && target.length !== patch.length) return null;
      for (const key of Object.keys(patch)) {
        if (Object.hasOwn(target, key)) pending.push([target[key], patch[key]]);
        else Object.defineProperty(target, key, {value: patch[key], enumerable: true});
      }
    }
    if (!finalizedItem(ordered[k])) return null;
    previous = k;
  }
  for (const key of ['id', 'call_id']) {
    const ids = ordered.filter(item => Object.hasOwn(item, key)).map(item => item[key]);
    if (!ids.every(nonempty) || ids.length !== new Set(ids).size) return null;
  }
  return ordered;
}

function eventInteger(token) {
  return JSON.isRawJSON(token) ? unsignedJsonInteger(token.rawJSON) : token === undefined ? undefined : null;
}

const contentEvents = new Map([
  ['response.output_text', ['message','text']], ['response.refusal', ['message','refusal']],
  ['response.reasoning_text', ['reasoning','text']], ['response.reasoning_summary_text', ['reasoning','text']],
  ['response.function_call_arguments', ['function_call','arguments']],
]);

function responseStream(text) {
  const frames = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n\n');
  if (frames.pop() !== '') return null;
  const items = new Map();
  const progress = new Map(), owners = new Map();
  const identities = {id: new Set(), call_id: new Set()};
  let responseId, sequence, sawContent = false;
  const observe = (id, index, type, role, identified, content, declaration = false) => {
    if (content) sawContent = true;
    if (index === null || !nonempty(id) && !(id === undefined && declaration && typeof index === 'bigint')) return;
    const named = progress.get(id), slot = owners.get(index);
    const item = named ?? slot ?? {valid:true, content:false, identified:false};
    const update = fields => {
      for (const key of ['id','index','type','role']) {
        if (fields[key] === undefined) continue;
        if (item[key] !== undefined && item[key] !== fields[key]) item.valid = false;
        else item[key] = fields[key];
      }
    };
    if (named && slot && named !== slot) {
      update(slot);
      item.valid &&= slot.valid;
      item.content ||= slot.content;
      item.identified ||= slot.identified;
      slot.valid = false;
    }
    update({id,index,type,role});
    if (nonempty(id)) progress.set(id, item);
    if (index !== undefined) owners.set(index, item);
    item.identified ||= identified;
    item.content ||= content;
  };
  const observeItem = (item, index, incomplete) => {
    if (!item) return;
    const identified = item.type === 'function_call' || item.type === 'reasoning' || item.type === 'message' && item.role === 'assistant';
    observe(item.id, index, item.type, item.role, identified, modelItem(item, incomplete), true);
  };
  for (const [i, frame] of frames.entries()) {
    const parts = [];
    let label;
    for (const line of frame.split('\n')) {
      const colon = line.indexOf(':');
      const key = colon < 0 ? line : line.slice(0, colon), value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
      if (key === 'data') parts.push(value);
      if (key === 'event') {
        if (label !== undefined && label !== value) return null;
        label = value;
      }
    }
    const data = parts.join('\n');
    if (!data || data === '[DONE]') continue;
    const event = strictJson(data, (key, value, context) => typeof value === 'number' ? JSON.rawJSON(context.source) : value);
    if (!nonempty(event.type) || label !== undefined && label !== event.type) return null;
    for (const id of [event.response_id, event.response?.id]) {
      if (id === undefined) continue;
      if (!nonempty(id) || responseId !== undefined && responseId !== id) return null;
      responseId = id;
    }
    if (event.sequence_number !== undefined) {
      const ordinal = eventInteger(event.sequence_number);
      if (ordinal === null || ordinal <= sequence) return null;
      sequence = ordinal;
    }
    const index = eventInteger(event.output_index);
    if (event.type === 'response.output_item.added' || event.type === 'response.output_item.done') observeItem(event.item, index, true);
    const suffix = event.type.lastIndexOf('.'), phase = event.type.slice(suffix + 1);
    const family = event.type.slice(0, suffix);
    const part = ['response.content_part','response.reasoning_summary_part'].includes(family) && ['added','done'].includes(phase) ?
      event.part : null;
    const partType = part?.type === 'summary_text' ? 'reasoning_summary_text' : part?.type;
    const content = contentEvents.get(part ? 'response.' + partType : family);
    if (phase === 'delta' || content && (phase === 'done' || part)) {
      const value = phase === 'delta' ? event.delta : (part ?? event)[content[1]];
      if (nonempty(value)) {
        const validPart = !part || (family === 'response.reasoning_summary_part' ? part.type === 'summary_text' :
          ['output_text','refusal','reasoning_text'].includes(part.type));
        if (content && validPart)
          observe(event.item_id, index, content[0], content[0] === 'message' ? 'assistant' : undefined,
            nonempty(event.response_id) && typeof index === 'bigint', true);
        else sawContent = true;
      }
    }
    if (event.type === 'response.output_item.done') {
      const item = event.item;
      if (typeof index !== 'bigint' || items.has(index) ||
          !['reasoning', 'message', 'function_call'].includes(item?.type)) return null;
      for (const [key, ids] of Object.entries(identities)) {
        if (!Object.hasOwn(item, key)) continue;
        if (!nonempty(item[key]) || ids.has(item[key])) return null;
        ids.add(item[key]);
      }
      items.set(index, item);
    }
    if (!['response.completed', 'response.incomplete', 'response.failed', 'error'].includes(event.type)) continue;
    if (i + 1 !== frames.length) return null;
    const body = event.type === 'error' ? {status:'failed'} : event.response;
    if (event.type !== 'error' && (!nonempty(body?.id) || body.status !== event.type.slice('response.'.length))) return null;
    let output = body.output;
    if (body.status === 'completed') {
      output = reconcileOutput(items, output);
      if (!output || body.error !== null) return null;
    }
    if (Array.isArray(output)) for (const [ordinal,item] of output.entries()) {
      const index = body.status === 'completed' ? BigInt(ordinal) : progress.get(item?.id)?.index ?? BigInt(ordinal);
      observeItem(item, index, body.status !== 'completed');
    }
    const emitted = [...progress.values(), ...owners.values()].some(item => item.valid && item.content && item.identified);
    return emitted || (sawContent || body.status !== 'failed' ? null : false);
  }
  return null;
}

export function capturedModelResponse(raw) {
  if (!raw || raw[7] !== 2) return null;
  if (raw[0] < 200 || raw[0] >= 300) return false;
  if (!raw[1]) return null;
  let body;
  try {
    const bytes = new TextDecoder('utf-8', {fatal: true}).decode(raw[3]);
    if (raw[4] === 0) body = strictJson(bytes);
    else if (raw[4] === 1) {
      const media = some(raw[5]);
      if (media && media.split(';')[0].trim().toLowerCase() !== 'text/event-stream') return null;
      return responseStream(bytes);
    } else return null;
  } catch { return null; }
  if (body?.status === 'failed') return Array.isArray(body.output) && body.output.some(item => modelItem(item, true));
  const incomplete = body?.status === 'incomplete';
  if ((!incomplete && (body?.status !== 'completed' || body.error !== null)) ||
      !Array.isArray(body.output)) return null;
  return body.output.some(item => modelItem(item, incomplete)) ? true : null;
}

function controllerAttempts(archive, application) {
  const captures = new Map(inventory(archive, 4, 'capture').map(row => [row.id, row.raw]));
  const occurrences = new Map(inventory(archive, 0, 'occurrence').map(row => [row.id, row.raw]));
  const rows = [];
  for (const {id, raw} of inventory(archive, 5, 'attempt')) {
    const preparedRef = some(raw[7]);
    if (raw[5] !== 'agent.model.invoke.v13' || !preparedRef) continue;
    const prepared = decodeValue(contract(application, 'AdaptivePrepared'), archive.object(preparedRef));
    const capture = captures.get(id), captured = capture && some(capture[4]);
    const preparedId = digest(preparedRef);
    const bound = capture && equal(raw[1], capture[0]) && equal(raw[2], capture[1]) &&
      hex(capture[2]) === id && equal(capture[3], preparedRef);
    const occurrence = occurrences.get(hex(raw[2]));
    const physical = physicalProviderAttempt(id, bound ? capture[5] : undefined, occurrence?.[3]);
    const confirmed = bound && capture[5] === 0 && captured;
    const reply = confirmed ? some(capture[6])?.[0] : null;
    const admitted = occurrence?.[3].tag === 5 && occurrence[3].value.tag === 0 ? occurrence[3].value.value : null;
    const projection = reply && admitted && hex(admitted[0]) === id && equal(admitted[1], reply[0]) &&
      equal(occurrence[1], archive.task.id) && equal(raw[1], occurrence[1]) && equal(raw[3], occurrence[4]) &&
      archive.objects.get(digest(reply))?.length === Number(reply[1]) ? digest(reply) : null;
    let modelResponse = physical ? null : false;
    if (confirmed) {
      try {
        const response = decodeValue(contract(application, 'CapturedResponse'), archive.object(captured));
        modelResponse = capturedModelResponse(response);
      } catch { modelResponse = null; }
    }
    rows.push({id, occurrence: hex(raw[2]), prepared_sha256: preparedId,
      capture_projection_sha256: projection,
      capture_sha256: bound && captured ? digest(captured) : null, selected_view: digest(some(prepared[3])),
      preparation_cut: some(raw[12])?.toString() ?? null, request_body_bytes: prepared[2].length,
      delivery: confirmed ? 'confirmed' : physical ? 'unknown' : 'not_sent',
      model_response: modelResponse,
      body: JSON.parse(Buffer.from(prepared[2]).toString())});
  }
  return rows;
}

function interactions(archive, application, observations, attempts) {
  const records = inventory(archive, 26, 'controller_interaction');
  const receipts = new Map(observations.flatMap(o => o.records ?? []).filter(row => row.acquisition)
    .map(row => [row.body, row.acquisition]));
  const task = hex(archive.task.id);
  return records.flatMap(({raw, id, body}) => {
    const acquired = receipts.get(body);
    if (!acquired || acquired.interaction_id !== id || hex(raw[1]) !== task || acquired.task_id !== task ||
        acquired.event_cut !== String(raw[8]) || acquired.carry_sha256 !== digest(raw[5])) return [];
    const carry = typed(archive, raw[6], raw[5]);
    const replay = some(carry[1][2]);
    const context = replay && decodeValue(contract(application, 'AdaptiveContext'), archive.object(replay[0]));
    const previous = context && hex(context[2]) === task && attempts.find(row =>
      row.prepared_sha256 === digest(context[10]) && row.capture_sha256 === digest(context[9]));
    const occurrence = some(raw[11]);
    const replies = occurrence && attempts.filter(row => row.occurrence === hex(occurrence) && row.model_response === true);
    const attempt = replies?.find(row => row.capture_projection_sha256) ?? replies?.[0];
    return [{...acquired, previous, attempt}];
  }).sort((a, b) => BigInt(a.event_cut) < BigInt(b.event_cut) ? -1 : BigInt(a.event_cut) > BigInt(b.event_cut) ? 1 : 0);
}

function actionsAt(interaction) {
  if (interaction.previous?.model_response !== true) return [];
  return interaction.results.flatMap(pending => {
    const action = interaction.result_actions.find(row => row.call_id === pending.call_id)?.action;
    if (!action || pending.output.tag !== 'workspace') return [];
    const reply = pending.output.value.reply;
    return [{action, command: action.value.command, reply, observation: JSON.parse(reply.observation_json),
      attempt_id: interaction.previous.id, prepared_sha256: interaction.previous.prepared_sha256,
      interaction_id: interaction.interaction_id, call_id: pending.call_id, cut: interaction.event_cut}];
  });
}

function authored(programs, actions, nomination) {
  if (nomination?.status !== 'candidate') return null;
  const program = programs.get(nomination.program.id);
  if (!program) return null;
  return actions.find(({action, command, reply, observation}) => action.tag === 'program' &&
    command.tag === 'build' && command.value.source_kind === 'source_records' && reply.disposition === 'admitted' &&
    same(reply.program, nomination.program) && same(observation.program, nomination.program) &&
    observation.source_kind === 'source_records' && same(observation.source, ref('source', digest(program.raw[3][1]))) &&
    ['input', 'result', 'failure'].every((name, i) =>
      same(observation[name + '_schema'], ref('schema', digest(program.raw[3][6 + i])))) &&
    (command.value.source.tag !== 'json_text' || sha(command.value.source.value) === digest(program.raw[3][1])));
}

export function incompatibleBuild(archive, build, program, observations, uses, seed) {
  const d = program.raw[3], command = build.command.value;
  if (!seed) return 'SeedExecutableUnestablished';
  if (equal(d[5], seed.raw[3][5])) return 'UnchangedSeedExecutable';
  if (d[2] !== 0 || command.role !== 'computation' || some(d[12])) return 'IncompatibleProgramRole';
  if (command.exposures.length || d[10].length) return 'ExposedProgram';
  if (digest(d[6]) !== inputSchemaId) return 'InvalidInputSchema';
  if (!payloadSchema(decodeSchema(archive.object(d[7])))) return 'InvalidProjectionSchema';
  const observed = observations.flatMap(o => o.records ?? []).find(r => r.kind === 'workspace_program' &&
    r.body === program.body && typeof r.pure === 'boolean');
  if (observed) return observed.pure ? null : 'ImpureProjection';
  if (uses.some(u => same(u.program, build.reply.program))) return null;
  const {module} = JSON.parse(archive.object(d[1]));
  if (module.functions[module.entry].effects.length) return 'ImpureProjection';
  return module.effects.some(effect => effect.external) ? 'PurityUnestablished' : null;
}

function matchesFrozen(actual, candidate) {
  return actual && candidate && same(actual.program, candidate.program) &&
    ['source_sha256', 'image_sha256', 'input_schema_sha256', 'result_schema_sha256', 'failure_schema_sha256']
      .every(key => actual[key] === candidate[key]) && actual.source_b64 === candidate.source_b64;
}

function publicAttempt(row) {
  const {body, ...rest} = row;
  return rest;
}

export function selectedPresentation(selectedView, body) {
  if (!selectedView || !Array.isArray(body?.input)) return null;
  const envelopes = [];
  for (const [index, item] of body.input.entries()) {
    if (item?.role !== 'user' || Object.keys(item).length !== 2 ||
        !Array.isArray(item.content) || item.content.length !== 1) continue;
    const [part] = item.content;
    if (part?.type !== 'input_text' || Object.keys(part).length !== 2 ||
        !part.text?.startsWith('{"selected_context_data":[')) continue;
    let envelope;
    try { envelope = JSON.parse(part.text); } catch { continue; }
    if (Object.keys(envelope).length === 1 && Array.isArray(envelope.selected_context_data))
      envelopes.push({index, blocks: envelope.selected_context_data});
  }
  return envelopes.length === 1 ? envelopes[0] : null;
}

function renderedValue(value) {
  const root = {}, pending = [[root, 'value', value]];
  while (pending.length) {
    const [parent, key, input] = pending.pop();
    if (Array.isArray(input)) {
      const output = parent[key] = new Array(input.length);
      for (let i = input.length - 1; i >= 0; i--) pending.push([output, i, input[i]]);
    } else if (input === null) parent[key] = {};
    else if (input instanceof Uint8Array) parent[key] = Buffer.from(input).toString('base64url');
    else if (typeof input === 'object') {
      const output = parent[key] = {tag: input.tag};
      pending.push([output, 'value', input.value]);
    } else parent[key] = typeof input === 'bigint' ? String(input) : input;
  }
  return root.value;
}

function execution(archive, programs, values, specimen, sourceRefs, programRef, inputRef, resultRef, work, consumerId) {
  const program = programs.get(digest(programRef)), result = values.get(digest(resultRef)),
    input = values.get(digest(inputRef));
  if (!program || !result || !input || work[19] !== 3 || hex(work[2]) !== hex(archive.task.id) ||
      hex(work[8]) !== digest(programRef) || !equal(some(work[16]), inputRef) ||
      !equal(some(work[29]), resultRef) || !equal(some(work[28]), result.raw[3][2]) ||
      !equal(work[15], input.raw[3][2]) || !equal(program.raw[3][6], input.raw[3][1]) ||
      !equal(program.raw[3][7], result.raw[3][1]) || some(work[5]) ||
      digest(input.raw[3][1]) !== inputSchemaId) return null;
  const actual = scanInput(archive, input);
  if (!actual) return null;
  const descriptor = decodeSchema(archive.object(result.raw[3][1]));
  const presented = inspectProjectionResult(descriptor, archive.object(result.raw[3][2]));
  const schemaKind = scanSchemas.get(presented.schema) ?? 'other';
  const proof = canonicalProjectionInput(values, inputRef, specimen, sourceRefs, actual, consumerId);
  const semantic = proof && presented.has_computed_block && observationId(presented.consumer) === consumerId ?
    inspectProjection(specimen, sourceRefs, schemaKind, presented.value) :
    {semantic_judgment: 'unestablished', paths: []};
  return {program, actual, presented, schemaKind, proof, semantic};
}

export function computedPresentation(block, result, schema, payload, expectedDescriptor) {
  if (block?.kind !== 'computed' || !same(block.result, result) || block.schema_identity !== schema ||
      !expectedDescriptor || !samePresentedValue(block.schema, expectedDescriptor) || !Object.hasOwn(block, 'value')) return false;
  return payload === undefined ? null : samePresentedValue(block.value, payload);
}

export function computedRendering(blocks, result, schema, payload, expectedDescriptor) {
  const matches = blocks.map(block => computedPresentation(block, result, schema, payload, expectedDescriptor));
  return matches.includes(true) || (matches.includes(null) ? null : false);
}

function projectionUse(archive, view, programs, values, specimen, sourceRefs, attempts, actions, lossyImages, build, schemas) {
  const p = some(view.raw[3][3]);
  if (!p) return null;
  const [resultRef, workRef, programRef, inputRef] = p;
  const work = decodeValue(archive.schemas.get('workspace_work'), archive.object(workRef));
  const observed = decodeValue(archive.schemas.get('workspace_reply'), archive.object(p[4]));
  if (!equal(observed[1], archive.task.id) || observed[4].tag !== 0 || observed[4].value.tag !== 7) return null;
  const result = execution(archive, programs, values, specimen, sourceRefs, programRef, inputRef, resultRef, work, hex(observed[0]));
  if (!result) return null;
  const {actual, presented, schemaKind, proof, semantic} = result;
  const consumerId = hex(observed[0]);
  if (observationId(actual[0]) !== consumerId || (!presented.inspection_error && observationId(presented.consumer) !== consumerId)) return null;
  const resultReference = ref('value', digest(resultRef)), viewReference = ref('view', digest(view.raw[2]));
  const started = actions.find(({action, command, reply, observation, cut}) => {
    const operation = action.tag === 'work' ? command :
      action.tag === 'placement' && command.tag === 'control' ? command.value.command : null;
    return operation?.tag === 'start' && reply.disposition === 'observed' &&
      (!build || !same(build.reply.program, actionRef(operation.value.program)) || BigInt(cut) > BigInt(build.cut)) &&
      same(actionRef(operation.value.program), ref('program', digest(programRef))) &&
      same(observation.work, ref('work', hex(work[1])));
  });
  const selection = actions.find(({action, command, reply, observation, cut}) => action.tag === 'context' &&
    command.tag === 'select' && command.value.tag === 'projected' && same(actionRef(command.value.value), resultReference) &&
    (!started || BigInt(cut) > BigInt(started.cut)) && reply.disposition === 'observed' &&
    same(reply.selected_view, viewReference) && same(observation.view, viewReference));
  const exposures = attempts.filter(row => row.selected_view === viewReference.id).map(row => {
    const material = selectedPresentation(row.selected_view, row.body);
    const blocks = material?.blocks ?? [];
    const rendered = presented.has_computed_block !== false &&
      computedRendering(blocks, resultReference, presented.schema, presented.payload, presented.display);
    if (rendered !== false && row.model_response === true) schemas[presented.schema] = presented.display;
    return {...publicAttempt(row), rendered, one_computed_block: blocks.length === 1 ? rendered : false, input_index: material?.index ?? null};
  });
  return {view: viewReference, program: ref('program', digest(programRef)), input: ref('value', digest(inputRef)),
    result: resultReference, work: ref('work', hex(work[1])), consumer: ref('observation', consumerId),
    canonical_input: proof, payload: presented.payload, payload_schema_sha256: presented.schema ?? null,
    payload_descriptor: presented.display ?? null, schema_kind: schemaKind,
    inspection_error: presented.inspection_error ?? null,
    known_lossy: lossyImages.has(digest(result.program.raw[3][5])),
    ...semantic, one_computed_block: presented.one_computed_block ?? null,
    model_start: started ? {attempt_id: started.attempt_id, call_id: started.call_id, cut: started.cut} : null,
    model_select: selection ? {attempt_id: selection.attempt_id, call_id: selection.call_id, cut: selection.cut} : null,
    exposures};
}

export function bindReport(archive, observations, interactions, summary) {
  if (typeof summary !== 'string') return null;
  const finalId = some(archive.task.controller_interaction);
  const result = some(archive.task.result);
  if (!result || !finalId) return null;
  for (const {report_producer: source} of observations) {
    if (!source || source.summary_sha256 !== sha(summary) || source.result_sha256 !== digest(result) ||
        source.interaction_id !== hex(finalId) || source.task_id !== hex(archive.task.id)) continue;
    const last = interactions.find(i => i.interaction_id === source.interaction_id);
    if (last?.attempt?.id === source.attempt_id && last.attempt.prepared_sha256 === source.prepared_sha256 &&
        nonempty(last.attempt.capture_projection_sha256) && last.attempt.capture_projection_sha256 === source.capture_projection_sha256 &&
        last.controller_id === source.controller_id && last.controller_epoch === source.controller_epoch &&
        last.event_cut === source.event_cut) return last;
  }
  return null;
}

export function confirmedApplication(uses, candidate, buildCut, reportAttempts) {
  if (!candidate) return null;
  let selected = null;
  for (const use of uses) {
    if (!same(use.program, candidate.program) || !use.canonical_input || !use.model_start || !use.model_select ||
        BigInt(use.model_start.cut) <= BigInt(buildCut) || BigInt(use.model_select.cut) <= BigInt(use.model_start.cut)) continue;
    for (const exposure of use.exposures) {
      if (!reportAttempts.has(exposure.id) || exposure.delivery !== 'confirmed' || exposure.model_response !== true || !exposure.rendered ||
          exposure.preparation_cut === null || BigInt(exposure.preparation_cut) < BigInt(use.model_select.cut)) continue;
      const one = use.one_computed_block === true && exposure.one_computed_block === true;
      if (selected && (selected.one_computed_block && !one || selected.one_computed_block === one &&
          BigInt(selected.exposure.preparation_cut) <= BigInt(exposure.preparation_cut))) continue;
      const {view, program, input, work, result, consumer, model_start, model_select} = use;
      selected = {view, program, input, work, result, consumer, model_start, model_select, exposure, one_computed_block: one};
    }
  }
  return selected;
}

function repairSnapshot(archive) {
  const pinned = JSON.parse(archive.object(archive.task.profile)).snapshot;
  const schema = {root: 0, types: [{product: [1, 2, 3]}, 'u32', 'u64', {seq: 4},
    {product: [5, 6, 8]}, 'text', {array: {element: 7, length: 32}}, 'u8', 'bytes']};
  const [version, excluded, entries] = decodeValue(schema, archive.object([pinned.digest, BigInt(pinned.bytes)]));
  const files = new Map(entries.map(([path, hash, bytes]) => [path, {hash: hex(hash), bytes: Buffer.from(bytes)}]));
  if (version !== 2 || files.size !== entries.length || [...files.values()].some(file => file.hash !== sha(file.bytes)))
    throw new Error('Invalid repair snapshot');
  return {pinned, excluded, files};
}

function coverRange(pages, key, start, end, total, first = 0) {
  const ranges = pages.get(key) ?? [];
  ranges.push([start, end]);
  ranges.sort((a, b) => a[0] - b[0]);
  let covered = first;
  for (const [lo, hi] of ranges) {
    if (lo > covered) break;
    covered = Math.max(covered, hi);
  }
  pages.set(key, ranges);
  return covered >= total;
}

function pageRange(page, bytes) {
  const start = page?.offset, end = page?.next_offset;
  if (typeof page?.text !== 'string' || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
      start < 0 || end < start || end > bytes.length || page.total_bytes !== bytes.length ||
      !bytes.subarray(start, end).equals(Buffer.from(page.text))) return null;
  return [start, end];
}

function receivedOutput(attempt, callId) {
  const input = attempt.body.input;
  const last = input.findLastIndex(item => item.type === 'function_call');
  if (last < 0 || input[last].call_id !== callId) return null;
  const items = input.slice(last + 1).filter(item => item.type === 'function_call_output' && item.call_id === callId);
  if (items.length !== 1) return null;
  const output = items[0].output;
  if (typeof output === 'string') return output;
  return output?.length === 1 && output[0].type === 'input_text' ? output[0].text : null;
}

const metadataDescriptions = new Set(['source_records', 'source_derivations', 'values', 'bindings', 'runtimes',
  'examples', 'projection', 'retention_query', 'divergence_query', 'hypothetical_reply', 'controller_contract',
  'semantic_candidates', 'components']);

export function decisionSupport(archive, application, specimen, sourceRefs, values, interactions, uses, producer, projector = null, consumers = new Set(), pairedSpecimen = null) {
  const exposure = [], projection_exposure = [], routes = [], unresolved = [];
  if (!producer) {
    const observed = interactions.filter(i => i.attempt?.model_response === true);
    for (const group of Map.groupBy(observed, i => i.controller_id + '/' + i.controller_epoch).values()) {
      const access = decisionSupport(archive, application, specimen, sourceRefs, values, group, uses, group.at(-1),
        projector, consumers, pairedSpecimen);
      routes.push(...access.routes);
      unresolved.push(...access.unresolved);
    }
    return {exposure, projection_exposure, routes, unresolved};
  }
  const history = interactions.filter(i => i.controller_id === producer.controller_id &&
    i.controller_epoch === producer.controller_epoch && BigInt(i.event_cut) <= BigInt(producer.event_cut) &&
    i.attempt?.model_response === true);
  const {pinned, excluded, files} = repairSnapshot(archive);
  const visits = JSON.parse(specimen.files['scan.json']).visits;
  const primary = new Set(['scan.json', ...visits.map(v => v.path)]);
  const expectedFiles = new Map([...primary].map(path => [path, specimen.files[path]]));
  const pairedManifest = pairedSpecimen?.files['scan.json'];
  if (typeof pairedManifest === 'string' && files.get('paired-scan.json')?.bytes.equals(Buffer.from(pairedManifest))) {
    expectedFiles.set('paired-scan.json', pairedManifest);
    for (const {path} of JSON.parse(pairedManifest).visits)
      if (!primary.has(path)) expectedFiles.set(path, pairedSpecimen.files[path]);
  }
  const present = path => typeof expectedFiles.get(path) === 'string' &&
    files.get(path)?.bytes.equals(Buffer.from(expectedFiles.get(path)));
  const absent = path => expectedFiles.has(path) && excluded === 0n && !files.has(path) && expectedFiles.get(path) === undefined;
  const byValue = new Map(), bySource = new Map(), handles = new Map(), pages = new Map(), completePaths = new Set();
  const missing = new Set(), presented = new Map(), partialComputations = new Map(), covered = new Set();
  const remember = (value, path) => handles.set(value.kind + value.id, {value, path});
  const credit = (value, paths) => exposure.push({ref: value, paths: [...paths]});
  for (const row of values.values()) {
    const raw = row.raw, origin = some(raw[4][4]);
    if (raw[4][0] !== 2 || !origin) continue;
    const [snapshot, path, hash, start, end, size] = origin;
    if (!present(path) || digest(snapshot) !== hex(pinned.digest) || snapshot[1] !== BigInt(pinned.bytes)) continue;
    const file = files.get(path);
    if (hex(hash) !== file.hash || size !== BigInt(file.bytes.length) || start > end || end > size) continue;
    const text = typed(archive, raw[3][1], raw[3][2]);
    if (typeof text !== 'string' || !file.bytes.subarray(Number(start), Number(end)).equals(Buffer.from(text))) continue;
    const value = ref('value', digest(raw[2])), source = ref('source', digest(raw[3][3]));
    const item = {path, start: Number(start), end: Number(end), text, value, source};
    byValue.set(value.id, item);
    bySource.set(source.id, item);
  }
  const marked = new Map();
  const note = (list, kind, i, extra = {}) => {
    const row = {kind, interaction_id: i.interaction_id, attempt_id: i.attempt.id, ...extra};
    const key = JSON.stringify(row), seen = marked.get(list) ?? new Set();
    marked.set(list, seen);
    if (!seen.has(key)) { seen.add(key); list.push(row); }
  };
  const markSource = (i, kind, path, start, end) => {
    const total = files.get(path).bytes.length;
    note(routes, kind, i, {path});
    if (coverRange(pages, 'file:' + path, start, end, total)) completePaths.add(path);
  };
  const computation = new Map();
  for (const use of uses) {
    if (use.canonical_input) computation.set(use.input.id, {input: true, use});
    computation.set(use.result.id, {input: false, use});
  }
  const fromProjection = (row, use) => {
    exposure.push(row);
    if (same(use?.result, projector?.result)) {
      const {ref, paths, semantic_judgment, known_lossy} = row;
      projection_exposure.push({ref, paths, semantic_judgment, known_lossy});
    }
  };
  const embedded = (use, presentedUse) => {
    if (use.semantic_judgment !== 'supported') return;
    let rows;
    if (use.schema_kind === 'ScanEvidence') rows = use.payload[1];
    else if (use.schema_kind === 'ScanOutcome') {
      const {tag, value} = use.payload;
      rows = tag === 0 ? [value] : tag === 1 ? value[1] : value[1][1];
    }
    if (!rows) return;
    for (const row of rows) {
      const acquisition = row[5], item = acquisition?.[0] === 3 && byValue.get(acquisition[1]);
      if (!item || !same(item.value, sourceRefs[item.path]) || !use.paths.includes(item.path)) continue;
      if (row[3] && item.path !== 'scan.json' && row[4] === specimen.files[item.path])
        fromProjection({ref:item.value, paths:[item.path]}, presentedUse);
      remember(item.value, item.path);
    }
  };
  const inputEvidence = (i, kind, wanted, complete, key) => {
    note(routes, kind, i, {ref:wanted});
    if (!complete) return;
    covered.add(key);
    credit(wanted, primary);
    embedded({schema_kind:'ScanEvidence', semantic_judgment:'supported', paths:[...primary],
      payload:renderedValue(canonicalEvidence(specimen,sourceRefs))});
  };
  const preview = (i, kind, wanted, page, source, container, selectedBlock) => {
    const item = wanted?.kind === 'source' ? bySource.get(wanted.id) : wanted?.kind === 'value' && byValue.get(wanted.id);
    const computed = !item && wanted?.kind === 'value' && computation.get(wanted.id);
    if (!item && !computed) { note(unresolved, kind, i, {ref: wanted}); return; }
    const key = computed ? 'value' + (computed.input ? computed.use.input.id : computed.use.result.id) : wanted.kind + wanted.id;
    let text, evidenceStart;
    if (item) text = wanted.kind === 'source' ? expectedFiles.get(item.path) : JSON.stringify(item.text);
    else {
      const raw = values.get(wanted.id)?.raw;
      if (!raw) { note(unresolved, kind, i, {ref: wanted}); return; }
      try {
        const value = renderedValue(typed(archive, raw[3][1], raw[3][2]));
        if (selectedBlock) {
          if (selectedBlock.kind === 'judgment' && raw[4][0] === 3 && !Object.hasOwn(selectedBlock,'slice') &&
              same(selectedBlock.provenance,ref('provenance',digest(raw[3][3]))) &&
              samePresentedValue(selectedBlock.schema,displayedSchema(archive.object(raw[3][1]))) &&
              samePresentedValue(selectedBlock.value,value)) inputEvidence(i,kind,wanted,true,key);
          else note(unresolved,kind,i,{ref:wanted});
          return;
        }
        text = JSON.stringify(value);
        if (computed.input && Array.isArray(value) && value.length === 2)
          evidenceStart = Buffer.byteLength(JSON.stringify(value[0])) + 2;
      }
      catch (error) {
        if (error.code !== 'ValueCapacity' && !(error instanceof RangeError)) throw error;
        note(unresolved, kind, i, {ref: wanted}); return;
      }
    }
    const bytes = Buffer.from(text), range = pageRange(page, bytes);
    if (!range) { note(unresolved, kind, i, {ref: wanted}); return; }
    const [start, end] = range;
    const complete = coverRange(pages, key, start, end,
      evidenceStart === undefined ? bytes.length : bytes.length - 1, evidenceStart);
    if (item) {
      if (wanted.kind === 'source' || item.start === 0 && item.end === files.get(item.path).bytes.length)
        remember(wanted, item.path);
      if (same(source, item.source)) remember(source, item.path);
      note(routes, kind, i, {path: item.path});
      if (wanted.kind === 'source') markSource(i, kind, item.path, start, end);
      else {
        const ranges = complete ? [[0, item.end - item.start]] :
          acquiredPageRanges(Buffer.from(item.text), true, pages.get(key));
        for (const [lo, hi] of ranges) {
          const start = item.start + lo, end = item.start + hi;
          markSource(i, kind, item.path, start, end);
          if (start !== 0 || end !== files.get(item.path).bytes.length)
            exposure.push({ref: wanted, paths: [], range: {path: item.path, start, end}});
        }
      }
      return;
    }
    const {input, use} = computed;
    if (complete) covered.add(key);
    else if (input) partialComputations.set(wanted.id, {kind, i, wanted, key});
    if (input) return inputEvidence(i,kind,wanted,complete,key);
    const alreadyShown = presented.has(use.result.id);
    if (alreadyShown) {
      if (!use.one_computed_block) note(unresolved, kind, i, {ref: wanted});
    } else if (!complete) partialComputations.set(wanted.id, {kind, i, wanted, key});
    else if (use.semantic_judgment === 'supported') note(routes, kind, i, {ref: wanted});
    else note(unresolved, kind, i, {ref: wanted});
    const citation = container ?? wanted;
    if (!same(citation, use.result) && (!container || use.one_computed_block) && (alreadyShown || complete)) {
      const original = presented.get(use.result.id) ?? {paths:use.paths, semantic_judgment:use.semantic_judgment,
        known_lossy:use.known_lossy, schema_sha256:use.payload_schema_sha256, value:use.payload};
      fromProjection({...original, ref:citation, projected_result:use.result, alias_preview_attempt:i.attempt.id},
        alreadyShown ? use : null);
    }
    if (complete && use.semantic_judgment === 'supported') {
      if (!alreadyShown || same(wanted, use.result)) credit(wanted,use.paths);
      embedded(use);
    }
  };
  for (const i of history) {
    for (const use of uses) {
      const request = use.exposures.find(e => e.id === i.attempt.id && e.model_response === true && e.rendered);
      if (!request) continue;
      const description = {ref: use.result, paths: use.paths, semantic_judgment: use.semantic_judgment,
        known_lossy: use.known_lossy, schema_sha256: use.payload_schema_sha256, value: use.payload,
        requests: [{attempt_id: request.id, prepared_sha256: request.prepared_sha256, input_index: request.input_index}]};
      fromProjection(description, use);
      presented.set(use.result.id, description);
      if (use.one_computed_block) covered.add('value' + use.result.id);
      embedded(use, use);
    }
    const selection = selectedPresentation(i.attempt.selected_view, i.attempt.body);
    for (const block of selection?.blocks ?? []) {
      if (block.kind === 'computed' && uses.some(use => use.exposures.some(e => e.id === i.attempt.id && e.rendered) &&
          computedPresentation(block, use.result, use.payload_schema_sha256, use.payload, use.payload_descriptor))) continue;
      const val = block.value_reference;
      if (block.kind === 'judgment' && val?.kind === 'value' && computation.get(val.id)?.input) {
        preview(i,'presented_input',val,null,null,null,block);
        continue;
      }
      const item = val?.kind === 'value' && byValue.get(val.id);
      if (item && block.kind === (item.source ? 'acquisition' : 'judgment')) {
        const full = Buffer.from(item.text);
        const start = block.slice ? Number(block.slice.offset) : 0;
        const end = block.slice ? start + Number(block.slice.length) : full.length;
        if (Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && end >= start &&
            end <= full.length && typeof block.value === 'string' && full.subarray(start, end).equals(Buffer.from(block.value))) {
          if (item.start === 0 && item.end === files.get(item.path).bytes.length) remember(val, item.path);
          const offset = item.start + start, limit = item.start + end;
          markSource(i, 'presented_source', item.path, offset, limit);
          if (offset !== 0 || limit !== files.get(item.path).bytes.length)
            exposure.push({ref: val, paths: [], range: {path: item.path, start: offset, end: limit}});
          continue;
        }
      }
      note(unresolved, 'other_selected_block', i);
    }
    if (!selection && i.attempt.selected_view) note(unresolved, 'unverified_selected_view', i);
    const actions = actionsAt(i);
    for (const pending of i.results) {
      const output = receivedOutput(i.attempt, pending.call_id);
      if (pending.output.tag === 'workspace') {
        const entry = actions.find(a => a.call_id === pending.call_id);
        if (!entry || !output) { note(unresolved, 'unconfirmed_workspace_output', i); continue; }
        const {action, command, reply, observation} = entry;
        let rendered;
        try { rendered = JSON.parse(output); } catch {}
        if (rendered?.disposition !== reply.disposition || !equal(rendered.observation, observation)) {
          note(unresolved, 'unconfirmed_workspace_output', i); continue;
        }
        if (action.tag === 'context' && command.tag === 'materialize') {
          const input = command.value.input, path = input.tag === 'snapshot' && input.value.path;
          if (path && reply.disposition === 'rejected' && observation.error === 'SourceMissing' && absent(path)) {
            note(routes, 'missing_read', i, {path}); missing.add(path);
          }
          if (path && reply.disposition === 'rejected' && observation.error === 'InvalidRange' && present(path)) {
            if (BigInt(input.value.offset) > BigInt(files.get(path).bytes.length)) note(routes, 'file_present', i, {path});
            else note(unresolved, 'unverified_range_rejection', i, {path});
          }
          if (reply.disposition !== 'observed') continue;
          const wanted = observation.value;
          if (!wanted || !same(reply.evidence, wanted)) { note(unresolved, 'unbound_value_preview', i); continue; }
          if (path && byValue.get(wanted.id)?.path !== path) { note(unresolved, 'unbound_acquisition', i); continue; }
          if (input.tag === 'value' && input.value.tag === 'reference') {
            const origin = actionRef(input.value.value);
            if (!same(origin, wanted)) {
              const original = values.get(origin.id)?.raw, alias = values.get(wanted.id)?.raw;
              const sources = command.value.sources?.map(actionRef);
              if (!original || !alias || origin.kind !== 'value' || wanted.kind !== 'value' ||
                  !Array.isArray(sources) || !sources.length || sources.some(s => s.kind !== 'value' || !values.has(s.id)) ||
                  alias[4][0] !== 3 || !equal(alias[4][1], [...sources.map(s => values.get(s.id).raw[2]), original[2]]) ||
                  !equal(original[3][1], alias[3][1]) || !equal(original[3][2], alias[3][2])) {
                note(unresolved, 'unbound_alias', i); continue;
              }
              if (byValue.has(origin.id)) byValue.set(wanted.id, {...byValue.get(origin.id), value: wanted, source: null});
              if (computation.has(origin.id)) computation.set(wanted.id, computation.get(origin.id));
            }
          }
          preview(i, path ? 'snapshot_acquisition' : 'materialized_value', wanted, observation.preview, observation.source);
        } else if (action.tag === 'program' && command.tag === 'inspect' && reply.disposition === 'observed' &&
            (command.value.target.tag === 'program' && same(actionRef(command.value.target.value), projector?.program) ||
             command.value.target.tag === 'consumer' && same(actionRef(command.value.target.value.program), projector?.program))) continue;
        else if (action.tag === 'program' && command.tag === 'describe' && metadataDescriptions.has(command.value.section) &&
            reply.disposition === 'observed') continue;
        else if (action.tag === 'context' && reply.disposition === 'observed' && observation.consumer?.kind === 'observation' &&
            consumers.has(observation.consumer.id) && typeof observation.binding?.text === 'string' &&
            (command.tag === 'inspect' && command.value.consumer?.target.tag === 'controller' ||
             command.tag === 'expand' && same(actionRef(command.value.reference), observation.consumer))) continue;
        else if (action.tag === 'context' && command.tag === 'expand' && reply.disposition === 'observed' &&
            same(actionRef(command.value.reference), projector?.source) && pageRange(observation, projector.source_bytes)) continue;
        else if (action.tag === 'context' && command.tag === 'expand' && reply.disposition === 'observed') {
          const wanted = actionRef(command.value.reference);
          if (wanted.kind === 'schema' && projector?.schema_ids?.includes(wanted.id)) {
            const bytes = archive.objects.get(wanted.id);
            if (bytes && sha(bytes) === wanted.id) {
              try {
                if (pageRange(observation, Buffer.from(JSON.stringify(displayedSchema(bytes))))) continue;
              } catch (error) {
                if (!(error instanceof ValueCodecError)) throw error;
              }
            }
          }
          const use = wanted.kind === 'view' && uses.find(u => same(u.view, wanted) && same(wanted, observation.view) &&
            same(u.result, observation.projection_result) && same(u.consumer, actionRef(observation.consumer)) &&
            observation.coverage === 'selected_blocks_only');
          preview(i, 'expansion', use ? use.result : wanted, use ? observation.selection : observation, null, use?.view);
        }
        else if ((action.tag === 'work' || action.tag === 'placement' && command.tag === 'control') && reply.disposition === 'observed') {
          const op = action.tag === 'work' ? command : command.value.command;
          const items = op.tag === 'wait' ? observation.works : op.tag === 'collect' ? observation : [observation];
          if (!Array.isArray(items)) { note(unresolved, 'unverified_work_output', i); continue; }
          for (const item of items) {
            if (item.failure_preview) note(unresolved, 'work_failure_preview', i, {ref:item.failure});
            if (item.port?.preview) note(unresolved, 'work_port_preview', i, {ref:item.port.reference});
            if (item.result_preview) {
              const use = uses.find(u => same(u.work, item.work) && same(u.program, item.program) && same(u.result, item.result));
              preview(i, 'work_result_preview', item.result, item.result_preview, null, use?.work);
            }
            else if (item.result) note(unresolved, 'unverified_work_preview', i);
          }
        } else if (reply.disposition === 'observed' && !(action.tag === 'context' && command.tag === 'inspect' &&
            !command.value.consumer)) note(unresolved, 'other_workspace_output', i);
        continue;
      }
      if (pending.output.tag === 'report_rejection') {
        let report;
        try { report = JSON.parse(output); } catch {}
        if (!equal(report, pending.output.value)) note(unresolved, 'unbound_report_rejection', i);
        continue;
      }
      if (pending.output.tag === 'control') {
        const object = pending.output.value;
        try {
          const [receipt,text] = decodeValue(contract(application,'ReceiptArtifact'),archive.object([object.digest,BigInt(object.bytes)]));
          if (i.previous?.model_response === true && hex(receipt[0]) === i.task_id &&
              digest(receipt[1]) === i.previous.capture_sha256 && receipt[2] === pending.call_id && output === text) continue;
        } catch {}
        note(unresolved,'unbound_control_receipt',i);
        continue;
      }
      if (pending.output.tag !== 'work') {
        note(unresolved, 'other_tool_output', i); continue;
      }
      const object = pending.output.value;
      const artifact = decodeValue(contract(application, 'WorkArtifact'), archive.object([object.digest, BigInt(object.bytes)]));
      const result = artifact[6];
      if (i.previous?.model_response !== true || artifact[0] !== 2 || hex(artifact[1]) !== i.task_id ||
          artifact[4] !== pending.call_id || output !== artifact[8]) {
        note(unresolved, 'unconfirmed_work_output', i); continue;
      }
      let rendered;
      if (result.tag === 0 || result.tag === 1) {
        try { rendered = JSON.parse(output); } catch { note(unresolved, 'unverified_work_text', i); continue; }
      }
      if (result.tag === 0) {
        const [[prefix, after], [entries, truncated, next]] = result.value;
        const ordered = [...files].filter(([path]) => path.startsWith(prefix) && path > after)
          .sort(([a], [b]) => Buffer.from(a).compare(Buffer.from(b)));
        const expected = ordered.slice(0, 32).map(([path, file]) => [path, BigInt(file.bytes.length)]);
        const listing = {entries: entries.map(([path, bytes]) => ({path, bytes: String(bytes)})), truncated, next};
        if (!equal(entries, expected) || !equal(rendered, listing) ||
            truncated !== (ordered.length > 32) || next !== (truncated ? expected.at(-1)[0] : '')) {
          note(unresolved, 'unbound_listing', i); continue;
        }
        for (const path of expectedFiles.keys()) {
          if (!path.startsWith(prefix) || path <= after || truncated && path > next) continue;
          note(routes, 'snapshot_listing', i, {path});
          if (absent(path)) missing.add(path);
        }
      } else if (result.tag === 1) {
        const [[requestedPath, offset, maximum], read] = result.value;
        if (read.tag === 2 && present(requestedPath)) {
          if (equal(rendered, {tag: 'invalid', value: read.value}) &&
              read.value === 'Read requires maximum 1..4096 and an offset within the file.' &&
              (BigInt(offset) > BigInt(files.get(requestedPath).bytes.length) || maximum < 1 || maximum > 4096))
            note(routes, 'file_present', i, {path: requestedPath});
          else note(unresolved, 'unverified_read_rejection', i, {path: requestedPath});
        }
        if (read.tag === 1 && expectedFiles.has(requestedPath)) {
          if (read.value === requestedPath && absent(requestedPath) && equal(rendered, {tag: 'missing', value: requestedPath})) {
            note(routes, 'missing_read', i, {path: requestedPath}); missing.add(requestedPath);
          } else note(unresolved, 'unbound_missing_read', i);
        }
        if (read.tag !== 0) continue;
        const [snapshot, path, hash, start, end, size, text] = read.value;
        const file = files.get(path);
        const found = {snapshot: [...snapshot], path, sha256: hash, start: String(start), end: String(end), file_bytes: String(size), content: text};
        if (!present(path) || path !== requestedPath || hex(snapshot) !== hex(pinned.digest) ||
            !equal(rendered, {tag: 'found', value: found}) ||
            hash !== file.hash || size !== BigInt(file.bytes.length) || start > end || end > size ||
            !Buffer.from(text).equals(file.bytes.subarray(Number(start), Number(end)))) {
          note(unresolved, 'unbound_read', i); continue;
        }
        markSource(i, 'ordinary_read', path, Number(start), Number(end));
      } else note(unresolved, 'other_work_output', i);
    }
  }
  for (const {kind, i, wanted, key} of partialComputations.values())
    if (!covered.has(key)) note(unresolved, kind, i, {ref: wanted});
  const primaryMissing = [...missing].filter(path => primary.has(path));
  for (const {value, path} of handles.values()) if (completePaths.has(path))
    credit(value, path === 'scan.json' ? [path, ...primaryMissing] : [path]);
  for (const row of exposure) if (row.range?.path === 'scan.json' && primaryMissing.length) row.declared_missing = primaryMissing;
  return {exposure, projection_exposure, routes, unresolved};
}

export function adjudicateRepairTrace({archive, application, observations = [], bootstrap, specimen, pairedSpecimen, summary,
  nomination, candidate: frozen, lossySourceDigest}) {
  const task = hex(archive.task.id), rows = (kind, schema) => inventory(archive, kind, schema)
    .filter(row => hex(row.raw[1]) === task);
  const programs = new Map(rows(8, 'workspace_program').map(row => [digest(row.raw[2]), row]));
  const values = new Map(rows(10, 'workspace_value').map(row => [digest(row.raw[2]), row]));
  const sourceRefs = acquisitions(archive, values, specimen, bootstrap?.manifest ? bootstrap : null);
  const attempts = controllerAttempts(archive, application);
  const history = interactions(archive, application, observations, attempts);
  const producer = bindReport(archive, observations, history, summary);
  const reportHistory = producer ? history.filter(i => i.controller_id === producer.controller_id &&
    i.controller_epoch === producer.controller_epoch && BigInt(i.event_cut) <= BigInt(producer.event_cut)) : [];
  const actions = (producer ? reportHistory : history).flatMap(actionsAt);
  const proposed = producer && nomination ? parseCandidate(summary) : null;
  const builds = actions.filter(a => a.action.tag === 'program' && a.command.tag === 'build').map(a => ({
    attempt_id: a.attempt_id, call_id: a.call_id, cut: a.cut, source_kind: a.command.value.source_kind,
    disposition: a.reply.disposition, program: a.reply.program, rejection: a.observation.error ?? null}));
  const selections = actions.filter(a => a.action.tag === 'context' && a.command.tag === 'select').map(a => ({
    attempt_id: a.attempt_id, call_id: a.call_id, cut: a.cut, selection: a.command.value,
    disposition: a.reply.disposition, view: a.reply.selected_view, rejection: a.observation.error ?? null}));
  const build = proposed && equal(proposed, nomination) && authored(programs, actions, nomination);
  const lossyImages = new Set([...programs.values()].filter(p => digest(p.raw[3][1]) === lossySourceDigest)
    .map(p => digest(p.raw[3][5])));
  const presentedSchemas = {};
  const uses = rows(11, 'workspace_view').map(row =>
    projectionUse(archive, row, programs, values, specimen, sourceRefs, attempts, actions, lossyImages, build, presentedSchemas)).filter(Boolean);
  const rejection = build ? incompatibleBuild(archive, build, programs.get(nomination.program.id), observations, uses,
    programs.get(bootstrap?.program?.id)) : null;
  const candidate = build && !rejection ? {...material(archive, programs.get(nomination.program.id)), author_task: task,
    build_attempt: build.attempt_id, build_call: build.call_id, build_result_cut: build.cut} : null;
  const projected = uses.find(v => same(v.view, bootstrap?.view) && same(v.result, bootstrap?.result) &&
    same(v.program, bootstrap?.program) && same(v.input, bootstrap?.input) && same(v.work, bootstrap?.work) &&
    same(v.consumer, bootstrap?.consumer));
  const actual = projected && material(archive, programs.get(projected.program.id));
  const transfer = Boolean(frozen && frozen.author_task !== task && projected?.canonical_input &&
    matchesFrozen(actual, frozen) && same(bootstrap.input_schema, ref('schema', actual.input_schema_sha256)) &&
    same(bootstrap.output_schema, ref('schema', actual.result_schema_sha256)));
  const applied = confirmedApplication(uses, candidate, build?.cut, new Set(reportHistory.map(i => i.attempt?.id)));
  const builtPrograms = new Set(builds.filter(b => b.disposition === 'admitted').map(b => b.program?.id));
  const observedConsumers = rows(17, 'workspace_reply').filter(({raw}) => raw[4].tag === 0 &&
    raw[4].value.tag === 7 && equal(raw[4].value.value[0], archive.task.id));
  const consumers = new Set(observedConsumers.map(r => r.id));
  const controllerConsumers = new Set(observedConsumers.filter(({raw}) => raw[4].value.value[9][0].tag === 0).map(r => r.id));
  const work = inventory(archive, 9, 'workspace_work').flatMap(({raw}) => {
    const program = hex(raw[8]);
    if (hex(raw[2]) !== task || !builtPrograms.has(program)) return [];
    const inputRef = some(raw[16]), input = values.get(digest(inputRef)), result = some(raw[29]);
    const supplied = input && scanInput(archive, input);
    const suppliedConsumer = observationId(supplied?.[0]);
    const consumerId = consumers.has(suppliedConsumer) ? suppliedConsumer : null;
    const canonical = supplied && consumerId &&
      equal(raw[15], input.raw[3][2]) && equal(programs.get(program)?.raw[3][6], input.raw[3][1]) &&
      canonicalProjectionInput(values, inputRef, specimen, sourceRefs, supplied, consumerId);
    return [{work: ref('work', hex(raw[1])), program: ref('program', program), input_sha256: digest(raw[15]),
      input: inputRef ? ref('value', digest(inputRef)) : null, canonical_input: Boolean(canonical),
      outcome: ['progressed', 'yielded', 'requested', 'completed', 'failed', 'cancelled'][raw[19]],
      result: result ? ref('value', digest(result)) : null}];
  });
  const projector = actual && {program: actual.program, result: projected.result, source: ref('source', actual.source_sha256),
    source_bytes: archive.objects.get(actual.source_sha256),
    schema_ids: [actual.input_schema_sha256, actual.result_schema_sha256, actual.failure_schema_sha256]};
  const support = decisionSupport(archive, application, specimen, sourceRefs, values, history, uses, producer, projector, controllerConsumers, pairedSpecimen);
  const evidenceComplete = Boolean(producer && !support.unresolved.length && !attempts.some(a => a.model_response === null) &&
    history.length === inventory(archive, 26, 'controller_interaction').length &&
    observations.some(o => o.acquisition_records_complete && o.report_producer?.attempt_id === producer.attempt.id));
  return {candidate, nomination_rejection: rejection, builds, work, selections, report_bound: Boolean(producer),
    report_attempt: producer?.attempt.id ?? null, authored_and_applied: Boolean(applied), applied_use: applied,
    transfer_bound: transfer, projection: projected ?? null, uses,
    exposure: support.exposure, projection_exposure: support.projection_exposure, presented_schemas: presentedSchemas,
    ordinary_routes: support.routes, unresolved_evidence_routes: support.unresolved,
    evidence_complete: evidenceComplete, ordinary_fallback: support.routes.length ? true : evidenceComplete ? false : null,
    delivery: attempts.map(publicAttempt)};
}

export function adjudicateRepairCollision({archive, bootstrap, specimen, pairedSpecimen, candidate}) {
  const task = hex(archive.task.id);
  const byArtifact = (kind, name) => new Map(inventory(archive, kind, name).filter(row =>
    hex(row.raw[1]) === task).map(row => [digest(row.raw[2]), row]));
  const programs = byArtifact(8, 'workspace_program'), values = byArtifact(10, 'workspace_value');
  const works = inventory(archive, 9, 'workspace_work');
  const consumer = inventory(archive, 17, 'workspace_reply').find(row => same(bootstrap?.consumer, ref('observation', row.id)) &&
    hex(row.raw[1]) === task && row.raw[4].tag === 0 && row.raw[4].value.tag === 7);
  const program = programs.get(bootstrap?.program?.id);
  const inspect = (receipt, source, manifestPath) => {
    if (!program || !consumer || !receipt || !source || !candidate || candidate.author_task === task) return null;
    const executable = material(archive, program);
    if (!matchesFrozen(executable, candidate) || !same(bootstrap.program, executable.program) ||
        !same(bootstrap.input_schema, ref('schema', executable.input_schema_sha256)) ||
        !same(bootstrap.output_schema, ref('schema', executable.result_schema_sha256))) return null;
    const row = works.find(r => r.id === receipt.work?.id);
    const input = values.get(receipt.input?.id), result = values.get(receipt.result?.id);
    if (!row || !input || !result || !same(receipt.work, ref('work', hex(row.raw[1]))) ||
        !same(receipt.input, ref('value', digest(input.raw[2]))) ||
        !same(receipt.result, ref('value', digest(result.raw[2])))) return null;
    const refs = acquisitions(archive, values, source, receipt, manifestPath);
    const run = execution(archive, programs, values, source, refs, program.raw[2], input.raw[2], result.raw[2], row.raw, consumer.id);
    if (!run?.proof || observationId(run.actual[0]) !== bootstrap.consumer.id) return null;
    const presentation = run.presented;
    const inspected = diagnosticPresentation(presentation, run.actual[0]);
    return {consumer: bootstrap.consumer, program: executable.program, work: receipt.work, input: receipt.input,
      result: receipt.result, expected: assessScan(source).outcome, schema_kind: run.schemaKind,
      one_computed_block: presentation.one_computed_block ?? null, ...inspected,
      ...(inspected.inspection_error ? {semantic_judgment: 'unestablished', paths: []} : run.semantic)};
  };
  const left = inspect(bootstrap, specimen, 'scan.json');
  const right = inspect(bootstrap?.paired, pairedSpecimen, 'paired-scan.json');
  return {...collisionProbe(left, right), left, right};
}
