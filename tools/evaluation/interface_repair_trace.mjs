import {createHash} from 'node:crypto';
import {isDeepStrictEqual as equal} from 'node:util';
import {contract} from '../../test/protean/adaptive_capture_checks.mjs';
import {decodeSchema, decodeValue, encodeSchema} from '../../test/support/values.mjs';
import {physicalProviderAttempt} from './workspace.mjs';
import {assessScan, canonicalEvidence, collisionProbe, inspectProjection, parseCandidate} from './interface_repair.mjs';

const hex = bytes => Buffer.from(bytes).toString('hex');
const digest = ref => ref && hex(ref[0]);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const some = option => option?.tag === 1 ? option.value : null;
const ref = (kind, id) => ({kind, id});
const same = (a, b) => a && b && a.kind === b.kind && a.id === b.id;
const typed = (archive, schema, bytes) => decodeValue(decodeSchema(archive.object(schema)), archive.object(bytes));
const schemaId = (types, root) => sha(encodeSchema({types, root}));
const scanTypes = [
  {product: [1, 2]}, {product: [3, 3, 4, 5]}, {seq: 6}, 'u64', 'boolean', {seq: 3},
  {product: [3, 3, 3, 4, 3, 7]}, {product: [8, 9]}, {enumeration: Array.from({length: 13}, (_, i) => i)},
  {bounded_text: 64}, {sum: [6, 0, 11]}, {product: [12, 0]}, {enumeration: [0, 1, 2, 3]},
];
const inputSchemaId = schemaId([...scanTypes, {product: [7, 0]}], scanTypes.length);
const scanSchemas = new Map([[schemaId(scanTypes, 0), 'ScanEvidence'], [schemaId(scanTypes, 10), 'ScanOutcome']]);

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
  const pinned = JSON.parse(archive.object(archive.task.profile)).snapshot;
  const snapshotRef = [pinned.digest, BigInt(pinned.bytes)];
  const snapshotSchema = {root: 0, types: [{product: [1, 2, 3]}, 'u32', 'u64', {seq: 4},
    {product: [5, 6, 8]}, 'text', {array: {element: 7, length: 32}}, 'u8', 'bytes']};
  const [, excluded, entries] = decodeValue(snapshotSchema, archive.object(snapshotRef));
  const files = new Map(entries.map(([path, hash, bytes]) => [path, {hash: hex(hash), bytes: Buffer.from(bytes)}]));
  if (excluded !== 0n || files.size !== entries.length) return refs;
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

function canonicalRun(values, inputRef, specimen, sourceRefs, actual) {
  const paths = ['scan.json', ...JSON.parse(specimen.files['scan.json']).visits.map(v => v.path)
    .filter(path => Object.hasOwn(specimen.files, path))];
  if (paths.some(path => !sourceRefs[path]) || !equal(actual[1], canonicalEvidence(specimen, sourceRefs))) return false;
  const todo = [digest(inputRef)], ancestry = new Set();
  while (todo.length) {
    const id = todo.pop();
    if (ancestry.has(id)) continue;
    ancestry.add(id);
    for (const source of values.get(id)?.raw[4][1] ?? []) todo.push(digest(source));
  }
  return paths.every(path => ancestry.has(sourceRefs[path].id));
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
    const response = bound && captured && decodeValue(contract(application, 'CapturedResponse'), archive.object(captured));
    const occurrence = occurrences.get(hex(raw[2]));
    const physical = physicalProviderAttempt(id, bound ? capture[5] : undefined, occurrence?.[3]);
    const confirmed = bound && capture[5] === 0 && response && response[0] >= 200 && response[0] < 300 && response[7] === 2;
    rows.push({id, occurrence: hex(raw[2]), prepared_sha256: preparedId,
      capture_sha256: bound && captured ? digest(captured) : null, selected_view: digest(some(prepared[3])),
      preparation_cut: some(raw[12])?.toString() ?? null,
      delivery: confirmed ? 'confirmed' : physical ? 'unknown' : 'not_sent',
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
    const attempt = occurrence && attempts.find(row => row.occurrence === hex(occurrence) && row.delivery === 'confirmed');
    return [{...acquired, previous, attempt}];
  }).sort((a, b) => BigInt(a.event_cut) < BigInt(b.event_cut) ? -1 : BigInt(a.event_cut) > BigInt(b.event_cut) ? 1 : 0);
}

function actionsAt(interaction) {
  if (!interaction.previous) return [];
  return interaction.results.flatMap(pending => {
    const action = interaction.result_actions.find(row => row.call_id === pending.call_id)?.action;
    if (!action || pending.output.tag !== 'workspace') return [];
    const reply = pending.output.value.reply;
    return [{action, command: action.value.command, reply, observation: JSON.parse(reply.observation_json),
      attempt_id: interaction.previous.id, prepared_sha256: interaction.previous.prepared_sha256,
      interaction_id: interaction.interaction_id, call_id: pending.call_id, cut: interaction.event_cut}];
  });
}

function authored(programs, actions, bootstrap, nomination) {
  if (nomination?.status !== 'candidate' || same(bootstrap?.program, nomination.program)) return null;
  const program = programs.get(nomination.program.id);
  if (!program || program.raw[3][2] !== 0) return null;
  return actions.find(({action, command, reply, observation}) => action.tag === 'program' &&
    command.tag === 'build' && command.value.source_kind === 'source_records' && reply.disposition === 'admitted' &&
    same(reply.program, nomination.program) && same(observation.program, nomination.program) && same(observation.source, ref('source', digest(program.raw[3][1]))) &&
    (command.value.source.tag !== 'json_text' || sha(command.value.source.value) === digest(program.raw[3][1])));
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
  if (typeof value === 'bigint') return String(value);
  if (value === null) return {};
  if (value instanceof Uint8Array) return Buffer.from(value).toString('base64url');
  if (Array.isArray(value)) return value.map(renderedValue);
  if (typeof value === 'object') return {tag: value.tag, value: renderedValue(value.value)};
  return value;
}

function execution(archive, programs, values, specimen, sourceRefs, programRef, inputRef, resultRef, work) {
  const program = programs.get(digest(programRef)), result = values.get(digest(resultRef)),
    input = values.get(digest(inputRef));
  if (!program || !result || !input || work[19] !== 3 || hex(work[2]) !== hex(archive.task.id) ||
      hex(work[8]) !== digest(programRef) || !equal(some(work[16]), inputRef) ||
      !equal(some(work[29]), resultRef) || !equal(some(work[28]), result.raw[3][2]) ||
      !equal(work[15], input.raw[3][2]) || !equal(program.raw[3][6], input.raw[3][1]) ||
      !equal(program.raw[3][7], result.raw[3][1])) return null;
  const actual = typed(archive, input.raw[3][1], input.raw[3][2]);
  const output = typed(archive, result.raw[3][1], result.raw[3][2]);
  const descriptor = decodeSchema(archive.object(result.raw[3][1]));
  const payloadRoot = descriptor.types[descriptor.root].product[1];
  const payloadSchema = schemaId(descriptor.types, payloadRoot);
  const schemaKind = scanSchemas.get(payloadSchema) ?? 'other';
  const proof = digest(input.raw[3][1]) === inputSchemaId && equal(actual[0], output[0][0]) &&
    canonicalRun(values, inputRef, specimen, sourceRefs, actual);
  const semantic = proof ? inspectProjection(specimen, sourceRefs, schemaKind, output[1]) :
    {semantic_judgment: 'unestablished', paths: []};
  return {program, actual, output, payloadSchema, schemaKind, proof, semantic};
}

function projectionUse(archive, view, programs, values, specimen, sourceRefs, attempts, actions, lossySourceDigest) {
  const p = some(view.raw[3][3]);
  if (!p) return null;
  const [resultRef, workRef, programRef, inputRef] = p;
  const work = decodeValue(archive.schemas.get('workspace_work'), archive.object(workRef));
  const result = execution(archive, programs, values, specimen, sourceRefs, programRef, inputRef, resultRef, work);
  if (!result) return null;
  const {actual, output, payloadSchema, schemaKind, proof, semantic} = result;
  const observed = decodeValue(archive.schemas.get('workspace_reply'), archive.object(p[4]));
  if (!equal(actual[0], [12, hex(observed[0])]) || !equal(observed[1], archive.task.id) ||
      observed[4].tag !== 0 || observed[4].value.tag !== 7) return null;
  const resultReference = ref('value', digest(resultRef)), viewReference = ref('view', digest(view.raw[2]));
  const selection = actions.find(({action, command, reply, observation}) => action.tag === 'context' &&
    command.tag === 'select' && command.value.tag === 'projected' && same(command.value.value, resultReference) &&
    reply.disposition === 'observed' && same(reply.selected_view, viewReference) && same(observation.view, viewReference));
  const started = actions.find(({action, command, reply, observation}) => {
    const operation = action.tag === 'work' ? command :
      action.tag === 'placement' && command.tag === 'control' ? command.value.command : null;
    return operation?.tag === 'start' && reply.disposition === 'observed' &&
      same(operation.value.program, ref('program', digest(programRef))) &&
      same(observation.work, ref('work', hex(work[1])));
  });
  const exposures = attempts.filter(row => row.selected_view === viewReference.id).map(row => {
    const material = selectedPresentation(row.selected_view, row.body);
    const blocks = material?.blocks ?? [];
    const rendered = blocks.some(b => b?.kind === 'computed' && same(b.result, resultReference) &&
      b.schema_identity === payloadSchema && equal(b.value, renderedValue(output[1])));
    return {...publicAttempt(row), rendered, input_index: material?.index ?? null};
  });
  return {view: viewReference, program: ref('program', digest(programRef)), input: ref('value', digest(inputRef)),
    result: resultReference, work: ref('work', hex(work[1])), consumer: ref('observation', actual[0][1]),
    canonical_input: proof, payload: renderedValue(output[1]), payload_schema_sha256: payloadSchema, schema_kind: schemaKind,
    known_lossy: digest(result.program.raw[3][1]) === lossySourceDigest,
    ...semantic, one_computed_block: output[0][1].length === 1 && output[0][1][0].tag === 1,
    model_start: started ? {attempt_id: started.attempt_id, call_id: started.call_id, cut: started.cut} : null,
    model_select: selection ? {attempt_id: selection.attempt_id, call_id: selection.call_id, cut: selection.cut} : null,
    exposures};
}

function bindReport(archive, observations, interactions, summary) {
  if (typeof summary !== 'string') return null;
  const finalId = some(archive.task.controller_interaction);
  const result = some(archive.task.result);
  if (!result || !finalId) return null;
  for (const {report_producer: source} of observations) {
    if (!source || source.summary_sha256 !== sha(summary) || source.result_sha256 !== digest(result) ||
        source.interaction_id !== hex(finalId) || source.task_id !== hex(archive.task.id)) continue;
    const last = interactions.find(i => i.interaction_id === source.interaction_id);
    if (last?.attempt?.id === source.attempt_id && last.attempt.prepared_sha256 === source.prepared_sha256) return last;
  }
  return null;
}

function decisionSupport(archive, application, specimen, sourceRefs, values, interactions, uses, producer) {
  const exposure = [], routes = [], unresolved = [];
  if (!producer) return {exposure, routes, unresolved};
  const history = interactions.filter(i => i.controller_id === producer.controller_id &&
    i.controller_epoch === producer.controller_epoch && BigInt(i.event_cut) <= BigInt(producer.event_cut) &&
    i.attempt?.delivery === 'confirmed');
  const visibleAttempts = new Set(history.map(i => i.attempt.id));
  for (const use of uses) {
    const requests = use.exposures.filter(e => visibleAttempts.has(e.id) && e.delivery === 'confirmed' && e.rendered);
    if (requests.length) exposure.push({ref: use.result, paths: use.paths, semantic_judgment: use.semantic_judgment,
      known_lossy: use.known_lossy, schema_sha256: use.payload_schema_sha256, value: use.payload, requests: requests.map(e => ({
        attempt_id: e.id, prepared_sha256: e.prepared_sha256, input_index: e.input_index}))});
  }
  const sourcePaths = new Map(Object.entries(sourceRefs).map(([path, value]) => [value.id, path]));
  const pages = new Map();
  const seen = new Set();
  const see = (kind, path, i, cited) => {
    const key = [kind, i.interaction_id, path, cited?.kind, cited?.id].join('/');
    if (seen.has(key)) return;
    seen.add(key);
    routes.push({kind, path, interaction_id: i.interaction_id, attempt_id: i.attempt.id});
    if (cited) exposure.push({ref: cited, paths: [path]});
  };
  for (const i of history) {
    for (const block of selectedPresentation(i.attempt.selected_view, i.attempt.body)?.blocks ?? []) {
      const value = block.value_reference, path = value && sourcePaths.get(value.id);
      if (path && block.kind === 'acquisition' && block.value === specimen.files[path])
        see('presented_source', path, i, value);
    }
    for (const {action, command, reply, observation} of actionsAt(i)) {
      if (action.tag === 'work' && reply.disposition === 'observed') {
        const results = command.tag === 'collect' ? observation : command.tag === 'wait' ? observation.works : [observation];
        for (const item of Array.isArray(results) ? results : []) {
          const use = uses.find(u => same(u.result, item.result));
          if (use && item.result_preview?.text) unresolved.push({kind: 'work_result_preview', ref: use.result});
        }
      }
      if (action.tag !== 'context') continue;
      if (command.tag === 'materialize' && command.value.input.tag === 'snapshot') {
        const path = command.value.input.value.path;
        if (reply.disposition === 'rejected' && observation.error === 'SourceMissing' &&
            !Object.hasOwn(specimen.files, path)) see('missing_read', path, i, null);
        if (reply.disposition === 'observed' && Object.hasOwn(specimen.files, path)) {
          const value = sourceRefs[path], preview = observation.preview;
          const complete = same(value, observation.value) && preview?.complete === true &&
            preview.text === JSON.stringify(specimen.files[path]);
          see('snapshot_acquisition', path, i, complete ? value : null);
        }
      }
      if (command.tag !== 'expand' || reply.disposition !== 'observed') continue;
      const wanted = command.value.reference;
      let path;
      if (wanted.kind === 'value') path = sourcePaths.get(wanted.id);
      else if (wanted.kind === 'source') path = Object.keys(sourceRefs).find(key => {
        return digest(values.get(sourceRefs[key].id)?.raw[3][3]) === wanted.id;
      });
      if (!path && wanted.kind === 'value' && values.has(wanted.id)) {
        const raw = values.get(wanted.id).raw;
        const value = typed(archive, raw[3][1], raw[3][2]);
        const use = uses.find(u => same(u.input, wanted) || same(u.result, wanted));
        const paths = use && same(use.input, wanted) && use.canonical_input ? assessScan(specimen).paths :
          use && same(use.result, wanted) && use.semantic_judgment === 'supported' ? use.paths : null;
        if (paths && observation.complete === true && equal(renderedValue(value), JSON.parse(observation.text))) {
          for (const path of paths) see('expanded_computation', path, i, wanted);
        } else unresolved.push({kind: 'other_value_expansion', ref: wanted});
      }
      if (!path) continue;
      const text = wanted.kind === 'value' ? JSON.stringify(specimen.files[path]) : specimen.files[path];
      const bytes = Buffer.from(text), offset = BigInt(observation.offset), end = BigInt(observation.next_offset);
      if (offset > end || end > BigInt(bytes.length) || BigInt(observation.total_bytes) !== BigInt(bytes.length) ||
          !Buffer.from(observation.text).equals(bytes.subarray(Number(offset), Number(end)))) continue;
      see('expansion', path, i, null);
      const ranges = pages.get(wanted.id) ?? [];
      ranges.push([Number(offset), Number(end)]);
      pages.set(wanted.id, ranges);
      let covered = 0;
      for (const [start, stop] of ranges.sort((a,b) => a[0] - b[0])) {
        if (start > covered) break;
        covered = Math.max(covered, stop);
      }
      if (covered === bytes.length) see('complete_expansion', path, i, wanted);
    }
    for (const pending of i.results) {
      if (pending.output.tag !== 'work') continue;
      const object = pending.output.value;
      const artifact = decodeValue(contract(application, 'WorkArtifact'), archive.object([object.digest, BigInt(object.bytes)]));
      if (artifact[0] !== 2 || hex(artifact[1]) !== i.task_id || artifact[6].tag !== 1) continue;
      const [, result] = artifact[6].value;
      if (result.tag === 1 && !Object.hasOwn(specimen.files, result.value)) see('missing_read', result.value, i, null);
      if (result.tag !== 0) continue;
      const [, path, hash, start, end, size, content] = result.value;
      if (!Object.hasOwn(specimen.files, path) || hash !== sha(specimen.files[path]) ||
          size !== BigInt(Buffer.byteLength(specimen.files[path])) ||
          !Buffer.from(content).equals(Buffer.from(specimen.files[path]).subarray(Number(start), Number(end)))) continue;
      see('ordinary_read', path, i, null);
    }
  }
  const missing = new Set(routes.filter(r => r.kind === 'missing_read').map(r => r.path));
  for (const row of exposure) {
    if (same(row.ref, sourceRefs['scan.json']) && row.paths.includes('scan.json'))
      row.paths.push(...JSON.parse(specimen.files['scan.json']).visits.map(v => v.path).filter(p => missing.has(p)));
  }
  return {exposure, routes, unresolved};
}

export function adjudicateRepairTrace({archive, application, observations = [], bootstrap, specimen, summary,
  nomination, candidate: frozen, lossySourceDigest}) {
  const task = hex(archive.task.id), rows = (kind, schema) => inventory(archive, kind, schema)
    .filter(row => hex(row.raw[1]) === task);
  const programs = new Map(rows(8, 'workspace_program').map(row => [digest(row.raw[2]), row]));
  const values = new Map(rows(10, 'workspace_value').map(row => [digest(row.raw[2]), row]));
  const sourceRefs = acquisitions(archive, values, specimen, bootstrap?.manifest ? bootstrap : null);
  const attempts = controllerAttempts(archive, application);
  const history = interactions(archive, application, observations, attempts);
  const producer = bindReport(archive, observations, history, summary);
  const actions = history.flatMap(actionsAt);
  const proposed = producer && nomination ? parseCandidate(summary) : null;
  const builds = actions.filter(a => a.action.tag === 'program' && a.command.tag === 'build').map(a => ({
    attempt_id: a.attempt_id, call_id: a.call_id, cut: a.cut, source_kind: a.command.value.source_kind,
    disposition: a.reply.disposition, program: a.reply.program, rejection: a.observation.error ?? null}));
  const selections = actions.filter(a => a.action.tag === 'context' && a.command.tag === 'select').map(a => ({
    attempt_id: a.attempt_id, call_id: a.call_id, cut: a.cut, selection: a.command.value,
    disposition: a.reply.disposition, view: a.reply.selected_view, rejection: a.observation.error ?? null}));
  const build = proposed && equal(proposed, nomination) && authored(programs, actions, bootstrap, nomination);
  const candidate = build ? {...material(archive, programs.get(nomination.program.id)), author_task: task,
    build_attempt: build.attempt_id, build_call: build.call_id, build_result_cut: build.cut} : null;
  const uses = rows(11, 'workspace_view').map(row =>
    projectionUse(archive, row, programs, values, specimen, sourceRefs, attempts, actions, lossySourceDigest)).filter(Boolean);
  const projected = uses.find(v => same(v.view, bootstrap?.view) && same(v.result, bootstrap?.result) &&
    same(v.program, bootstrap?.program) && same(v.input, bootstrap?.input) && same(v.work, bootstrap?.work) &&
    same(v.consumer, bootstrap?.consumer));
  const actual = projected && material(archive, programs.get(projected.program.id));
  const transfer = Boolean(frozen && frozen.author_task !== task && projected?.canonical_input && actual &&
    ['source_sha256', 'image_sha256', 'input_schema_sha256', 'result_schema_sha256', 'failure_schema_sha256']
      .every(key => actual[key] === frozen[key]));
  const applied = candidate && uses.find(v => same(v.program, candidate.program) && v.canonical_input &&
    v.model_start && v.model_select && BigInt(v.model_start.cut) > BigInt(build.cut) &&
    BigInt(v.model_select.cut) > BigInt(v.model_start.cut) && v.exposures.some(e =>
      e.delivery === 'confirmed' && e.rendered && e.preparation_cut !== null && BigInt(e.preparation_cut) >= BigInt(v.model_select.cut)));
  const builtPrograms = new Set(builds.filter(b => b.disposition === 'admitted').map(b => b.program?.id));
  const work = inventory(archive, 9, 'workspace_work').flatMap(({raw}) => {
    const program = hex(raw[8]);
    if (hex(raw[2]) !== task || !builtPrograms.has(program)) return [];
    const inputRef = some(raw[16]), input = values.get(digest(inputRef)), result = some(raw[29]);
    const canonical = input && digest(input.raw[3][1]) === inputSchemaId &&
      canonicalRun(values, inputRef, specimen, sourceRefs, typed(archive, input.raw[3][1], input.raw[3][2]));
    return [{work: ref('work', hex(raw[1])), program: ref('program', program), input_sha256: digest(raw[15]),
      input: inputRef ? ref('value', digest(inputRef)) : null, canonical_input: Boolean(canonical),
      outcome: ['progressed', 'yielded', 'requested', 'completed', 'failed', 'cancelled'][raw[19]],
      result: result ? ref('value', digest(result)) : null}];
  });
  const support = decisionSupport(archive, application, specimen, sourceRefs, values, history, uses, producer);
  return {candidate, builds, work, selections, report_bound: Boolean(producer), report_attempt: producer?.attempt.id ?? null,
    authored_and_applied: Boolean(applied), transfer_bound: transfer, projection: projected ?? null, uses,
    exposure: support.exposure, ordinary_routes: support.routes, unresolved_evidence_routes: support.unresolved,
    ordinary_fallback: support.routes.length ? true : producer && !support.unresolved.length &&
      history.length === inventory(archive, 26, 'controller_interaction').length && observations.some(o => o.acquisition_records_complete) ? false : null,
    delivery: attempts.map(publicAttempt)};
}

export function adjudicateRepairCollision({archive, bootstrap, specimen, pairedSpecimen, candidate}) {
  const task = hex(archive.task.id);
  const byArtifact = (kind, name) => new Map(inventory(archive, kind, name).filter(row =>
    hex(row.raw[1]) === task).map(row => [digest(row.raw[2]), row]));
  const programs = byArtifact(8, 'workspace_program'), values = byArtifact(10, 'workspace_value');
  const works = inventory(archive, 9, 'workspace_work');
  const consumer = inventory(archive, 17, 'workspace_reply').find(row => row.id === bootstrap?.consumer?.id &&
    hex(row.raw[1]) === task && row.raw[4].tag === 0 && row.raw[4].value.tag === 7);
  const program = programs.get(bootstrap?.program?.id);
  const inspect = (receipt, source, manifestPath) => {
    if (!program || !consumer || !receipt || !source || !candidate || candidate.author_task === task) return null;
    const executable = material(archive, program);
    if (!['source_sha256', 'image_sha256', 'input_schema_sha256', 'result_schema_sha256', 'failure_schema_sha256']
        .every(key => executable[key] === candidate[key])) return null;
    const row = works.find(r => r.id === receipt.work?.id);
    const input = values.get(receipt.input?.id), result = values.get(receipt.result?.id);
    if (!row || !input || !result) return null;
    const refs = acquisitions(archive, values, source, receipt, manifestPath);
    const run = execution(archive, programs, values, source, refs, program.raw[2], input.raw[2], result.raw[2], row.raw);
    if (!run?.proof || !equal(run.actual[0], [12, bootstrap.consumer?.id]) ||
        !equal(run.output[0][0], run.actual[0])) return null;
    return {consumer: bootstrap.consumer, program: executable.program, work: receipt.work, input: receipt.input,
      result: receipt.result, payload: renderedValue(run.output[1]), expected: assessScan(source).outcome,
      schema_kind: run.schemaKind, ...run.semantic};
  };
  const left = inspect(bootstrap, specimen, 'scan.json');
  const right = inspect(bootstrap?.paired, pairedSpecimen, 'paired-scan.json');
  return {...collisionProbe(left, right), left, right};
}
