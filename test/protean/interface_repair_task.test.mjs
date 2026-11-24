import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {executeRepairTask} from '../../tools/evaluation/interface_repair_task.mjs';
import {providerRequestBodyBytes} from '../../tools/evaluation/workspace.mjs';
import {decisionSupport} from '../../tools/evaluation/interface_repair_trace.mjs';
import {encodeSchema, encodeValue} from '../support/values.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');

async function setup(t) {
  const output = await mkdtemp(join(tmpdir(), 'protean-repair-runner-'));
  t.after(() => rm(output, {force: true, recursive: true}));
  const subject = {id: 'test-transfer', arm: 'repair', phase: 'transfer', case_id: 'test-case',
    case_path: join(output, 'case.json'), config: join(output, 'config.json'), config_sha256: hash('{}'),
    prompt: 'Classify the scan.', evidence: []};
  const bytes = JSON.stringify({case_id: subject.case_id, files: {}});
  await writeFile(subject.case_path, bytes);
  await writeFile(subject.config, '{}');
  const cases = {[subject.case_id]: {specimen: {path: subject.case_path, sha256: hash(bytes)}}};
  return {output, subject, build: {}, plan: {cases, cost_model: {kind: 'unpriced'}}, plan_sha256: 'a'.repeat(64),
    application: {}, driver: 'unused', credential: '/unopened', deadline: performance.now() + 2000};
}

test('a failed preflight retains the isolated task, reopens it only for measurements and charges unknowns', async t => {
  const options = await setup(t);
  const calls = [], launches = [], task_id = 'af'.repeat(16);
  class RejectedArchive {
    constructor(_, argv) { launches.push(argv); }
    async call(method) {
      calls.push(method);
      if (method === 'describe') return {execution_mode: 'live', profile: {id: 'adaptive'}};
      if (method === 'task.submit') return {task_id};
      if (method === 'evaluation.drain') return {step: 'idle'};
      throw new Error('UnexportableArchive');
    }
    async close() { return {code: 0, signal: null}; }
  }
  const report = await executeRepairTask(options, {Client: RejectedArchive});
  assert.equal(report.effective_condition, 'ordinary');
  assert.equal(report.fallback_reason, 'no_candidate');
  assert.equal(report.task.task_id, task_id);
  assert.deepEqual(calls, ['describe', 'task.submit', 'evaluation.export', 'evaluation.drain', 'evaluation.export']);
  assert.deepEqual(launches[1], [...launches[0], '--profile-task', task_id]);
  const descriptor = JSON.stringify({version: 1, plan_sha256: options.plan_sha256, submission_id: options.subject.id,
    prompt_sha256: hash(options.subject.prompt), phase: 'downstream', condition: 'ordinary', files: [], source_sha256: hash(''), program_sha256: null});
  assert.equal(launches[0].at(-1), hash(descriptor));
  assert.equal(report.archive, null);
  assert.equal(report.metrics, null);
  assert.equal(report.cost.total, null);
  assert(report.errors.some(e => e.stage === 'archive' && e.message === 'UnexportableArchive'));
  assert.deepEqual(JSON.parse(await readFile(join(options.output, 'report.json'))), report);
});

test('episode expiry kills the outstanding driver without a substitute dispatch', async t => {
  const options = await setup(t);
  options.deadline = performance.now() + 300;
  const calls = [];
  class StalledDriver {
    async call(method) {
      calls.push(method);
      return new Promise((_, reject) => { this.reject = reject; });
    }
    kill() { calls.push('killed'); this.reject(new Error('closed')); }
    async close() { return {code: null, signal: 'SIGKILL'}; }
  }
  const report = await executeRepairTask(options, {Client: StalledDriver});
  assert.equal(report.timed_out, true);
  assert.deepEqual(calls, ['describe', 'killed']);
  assert.equal(report.metrics, null);
  assert.equal(report.peak_rss_sampled_bytes, null);
  assert.equal(report.task, null);
});

test('changed frozen candidate bytes stop the task before launch', async t => {
  const options = await setup(t);
  const candidate = {source_b64: Buffer.from('changed source').toString('base64'), source_sha256: hash('frozen source')};
  const report = await executeRepairTask({...options, candidate}, {Client: class { constructor() { assert.fail('launched'); } }});
  assert.equal(report.task, null);
  assert(report.errors.some(e => e.stage === 'setup' && e.message.includes('Authored source changed')));
  assert.equal(report.adjudication, null);
});

test('diagnostic grading cannot consume a changed paired specimen after campaign validation', async t => {
  const options = await setup(t);
  const pair = JSON.stringify({case_id: 'paired-case', files: {}});
  const path = join(options.output, 'paired.json');
  options.subject.phase = 'diagnostic';
  options.subject.paired_case_path = path;
  options.plan.cases['paired-case'] = {specimen: {path, sha256: hash(pair)}};
  await writeFile(path, pair + '\n');
  const report = await executeRepairTask(options, {Client: class { constructor() { assert.fail('launched'); } }});
  assert.equal(report.task, null);
  assert(report.errors.some(e => e.stage === 'setup' && e.message.includes('Frozen case changed')));
  assert.equal(report.adjudication, null);
});

function schemaSupport(schema) {
  const bytes = Buffer.from(encodeSchema(schema));
  return {wire_base64url: bytes.toString('base64url'), wire_sha256: hash(bytes)};
}

test('provider body accounting excludes both controller and delegated typed preparation metadata', () => {
  const body = Buffer.from('{"input":"é"}');
  const controller = {root: 0, types: [{product: [1, 1, 1]}, 'bytes']};
  const application = {support: {AdaptivePrepared: schemaSupport(controller)}};
  const prepared = encodeValue(controller, [Buffer.alloc(128), Buffer.alloc(64), body]);
  assert.equal(providerRequestBodyBytes(prepared, 'controller', null, application), body.length);
  const delegated = {root: 0, types: [{product: [1, 1, 2, 2]}, 'bytes', {sum: [3, 1]}, 'unit']};
  const metadata = encodeValue(delegated, [Buffer.alloc(511), body, {tag: 1, value: Buffer.alloc(99)}, {tag: 0, value: null}]);
  const schemas = new Map([['workspace_delegation', {root: 0, types: [{product: Array(12).fill(1)}, {sum: [2, 3]}, 'unit', 'bytes']}]]);
  assert.equal(providerRequestBodyBytes(metadata, 'delegated', schemas, null), body.length);
  assert.equal(providerRequestBodyBytes(null, 'controller', null, null), null);
});

function decisionFixture() {
  const objects = new Map();
  const put = bytes => {
    const id = hash(bytes);
    objects.set(id, Buffer.from(bytes));
    return [Buffer.from(id, 'hex'), BigInt(bytes.length)];
  };
  const val = (kind, raw) => ({kind, id: Buffer.from(raw[0]).toString('hex')});
  const path = 'scan.json', member = 'r-a', absent = 'r-b';
  const file = JSON.stringify({domain: {identity: '1', revision: '1', known: true, members: ['1']},
    visits: [member, absent].map(path => ({domain_identity: '1', domain_revision: '1', member: '1', path}))});
  const specimen = {files: {[path]: file, [member]: '2'}};
  const snapshotSchema = {root: 0, types: [{product: [1, 2, 3]}, 'u32', 'u64', {seq: 4},
    {product: [5, 6, 8]}, 'text', {array: {element: 7, length: 32}}, 'u8', 'bytes']};
  const snapshot = put(encodeValue(snapshotSchema, [2, 0n, Object.entries(specimen.files).map(([name, content]) =>
    [name, [...Buffer.from(hash(content), 'hex')], Buffer.from(content)])]));
  const profile = put(Buffer.from(JSON.stringify({snapshot: {digest: [...snapshot[0]], bytes: String(snapshot[1])}})));
  const archive = {task: {profile}, object: r => objects.get(Buffer.from(r[0]).toString('hex'))};
  const textSchema = {types: ['text'], root: 0}, schemaRef = put(encodeSchema(textSchema));
  const values = new Map();
  const value = (id, text, origin, name) => {
    const object = put(Buffer.from(id)), source = put(Buffer.from('origin-' + id));
    const contents = put(encodeValue(textSchema, text));
    const raw = [null, null, object, [null, schemaRef, contents, source], origin];
    const handle = val('value', object);
    values.set(handle.id, {raw});
    return {handle, source: val('source', source), text, path: name, raw};
  };
  const acquire = (name, start, end) => {
    const text = specimen.files[name];
    return value(name + start + ':' + end, text.slice(start,end), [2, [], null, null,
      {tag: 1, value: [snapshot, name, Buffer.from(hash(text), 'hex'), BigInt(start), BigInt(end), BigInt(text.length)]}], name);
  };
  const full = acquire(path, 0, file.length), slice = acquire(path, 0, 4), witness = acquire(member, 0, 1);
  const input = value('canonical', 'canonical-input', [1, [], null, null, {tag: 0}]);
  const result = value('projection', 'projected-result', [1, [], null, null, {tag: 0}]);
  const refs = {[path]: full.handle, [member]: witness.handle};
  const history = [];
  const page = (text, start = 0, end = Buffer.byteLength(text)) => ({offset: start, next_offset: end,
    total_bytes: Buffer.byteLength(text), text: Buffer.from(text).subarray(start, end).toString()});
  const step = (tag, command, observation, {disposition = 'observed', selected = null, block = null, mismatch = false} = {}) => {
    const id = String(history.length + 1), call_id = 'call-' + id;
    const reply = {disposition, observation_json: JSON.stringify(observation), evidence: observation.value};
    const input = [{type: 'function_call_output', call_id, output: [{type: 'input_text', text: JSON.stringify({
      disposition, observation: mismatch ? {} : observation})}]}];
    if (block) input.push({role: 'user', content: [{type: 'input_text', text: JSON.stringify({selected_context_data: [block]})}]});
    history.push({interaction_id: id, event_cut: id, attempt: {id, delivery: 'confirmed', selected_view: selected, body: {input}},
      previous: {id: 'previous', delivery: 'confirmed'}, results: [{call_id, output: {tag: 'workspace', value: {reply}}}],
      result_actions: [{call_id, action: {tag, value: {command}}}]});
  };
  const expand = (handle, text, start, end) => step('context', {tag: 'expand', value: {reference: handle}}, page(text, start, end));
  const materialize = item => step('context', {tag: 'materialize', value: {input: {tag: 'value', value: {tag: 'reference', value: item.handle}}}},
    {value: item.handle, source: item.source, preview: page(JSON.stringify(item.text))});
  const workSchema = {root: 0, types: [{product: [1,2,3,3,4,3,5,3,4]}, 'u8', 'bytes', 'unit', 'text', {sum:[6,10]},
    {product:[7,8]}, {product:[4,4]}, {product:[9,16,4]}, {seq:13}, {product:[11,12]},
    {product:[4,14,1]}, {sum:[15,4]}, {product:[4,14]}, 'u64', {product:[2,4,4,14,14,14,4]}, 'boolean']};
  const work = (result, rendered) => {
    const task = Buffer.alloc(16), id = String(history.length + 1), call_id = 'work-' + id;
    const text = JSON.stringify(rendered);
    const artifact = put(encodeValue(workSchema, [2, task, null, null, call_id, null, result, null, text]));
    history.push({interaction_id: id, task_id: task.toString('hex'), event_cut: id, previous: {delivery: 'confirmed'},
      attempt: {id, delivery: 'confirmed', body: {input: [{type:'function_call_output', call_id, output: text}]}},
      results: [{call_id, output: {tag: 'work', value: {digest: [...artifact[0]], bytes: String(artifact[1])}}}], result_actions: []});
  };
  const support = (uses = []) => decisionSupport(archive, {support: {WorkArtifact: schemaSupport(workSchema)}},
    specimen, refs, values, history, uses, history.at(-1));
  return {step, support, expand, materialize, work, snapshot, history, page, path, member, absent, file, slice, full, witness, input, result, value};
}

test('verified acquisition previews and ranged source expansions bind both manifest references to observed misses', () => {
  const f = decisionFixture();
  f.materialize(f.slice);
  assert.deepEqual(f.support().exposure, []);
  f.expand(f.slice.source, f.file, 8);
  assert.deepEqual(f.support().exposure, []);
  f.expand(f.slice.source, f.file, 0, 8);
  f.materialize(f.full);
  f.step('context', {tag: 'materialize', value: {input: {tag: 'snapshot', value: {path: f.absent}}}},
    {error: 'SourceMissing'}, {disposition: 'rejected'});
  const {routes, unresolved, exposure} = f.support();
  assert.deepEqual(unresolved, []);
  assert(routes.some(row => row.kind === 'missing_read'));
  for (const ref of [f.full.handle, f.full.source, f.slice.source])
    assert(exposure.some(row => row.ref.id === ref.id && row.paths.includes(f.path) && row.paths.includes(f.absent)));
  assert(!exposure.some(row => row.ref.id === f.slice.handle.id));
});

test('only confirmed returned bytes credit a retained reference or its copied alias', () => {
  const f = decisionFixture();
  const alias = f.value('copy', f.file, [3, [f.full.raw[2]], null, null, {tag: 0}]);
  const cmd = {tag: 'materialize', value: {input: {tag: 'value', value: {tag: 'reference', value: f.full.handle}}}};
  const observation = {value: alias.handle, preview: f.page(JSON.stringify(f.file))};
  f.step('context', cmd, observation, {mismatch: true});
  assert.equal(f.support().unresolved.length, 1);
  assert.deepEqual(f.support().exposure, []);
  f.step('context', cmd, observation);
  assert(f.support().exposure.some(row => row.ref.id === alias.handle.id && row.paths.includes(f.path)));
});

test('same-result previews retain projection credit and paged canonical-input reads constitute fallback', () => {
  const f = decisionFixture(), selected = 'a'.repeat(64);
  const row = ['1','1','1',true,'2',[3,f.witness.handle.id]];
  const payload = [[1, 1, true, [1]], [row]];
  const use = {canonical_input: true, input: f.input.handle, result: f.result.handle, paths: [f.path, f.member],
    one_computed_block: true, payload, payload_schema_sha256: 's', schema_kind: 'ScanEvidence', semantic_judgment: 'supported',
    exposures: [{id: '1', rendered: true, delivery: 'confirmed'}]};
  f.step('work', {tag: 'inspect'}, {result: use.result, result_preview: f.page(JSON.stringify(f.result.text))},
    {selected, block: {kind: 'computed', schema_identity: 's', result: use.result, value: payload}});
  assert.deepEqual(f.support([use]).routes, []);
  assert.deepEqual(f.support([use]).unresolved, []);
  assert(f.support([use]).exposure.some(e => e.ref.id === f.witness.handle.id && e.paths.length === 1 && e.paths[0] === f.member));
  const text = JSON.stringify(f.input.text);
  f.expand(f.input.handle, text, 3);
  assert(f.support([use]).unresolved.some(row => row.ref?.id === f.input.handle.id));
  assert(!f.support([use]).exposure.some(row => row.ref.id === f.input.handle.id));
  f.expand(f.input.handle, text, 0, 3);
  assert(f.support([use]).routes.some(row => row.ref?.id === f.input.handle.id));
  assert(f.support([use]).exposure.some(row => row.ref.id === f.input.handle.id && row.paths.includes(f.absent)));
});

test('delivered ordinary listings establish scoped absence and ordinary read pages bind to a visible source handle', () => {
  const f = decisionFixture();
  f.materialize(f.slice);
  const listing = [['r-a', 1n]];
  f.work({tag: 0, value: [['r-', ''], [listing, false, '']]}, {entries: [{path:'r-a',bytes:'1'}], truncated:false, next:''});
  const read = (start, end) => {
    const content = f.file.slice(start, end);
    const found = [f.snapshot[0], f.path, hash(f.file), BigInt(start), BigInt(end), BigInt(f.file.length), content];
    f.work({tag: 1, value: [[f.path, BigInt(start), end - start], {tag: 0, value: found}]},
      {tag: 'found', value: {snapshot: [...f.snapshot[0]], path: f.path, sha256: hash(f.file), start: String(start), end: String(end),
        file_bytes: String(f.file.length), content}});
  };
  read(0, 20);
  assert.deepEqual(f.support().exposure, []);
  read(20, f.file.length);
  const {routes, exposure, unresolved} = f.support();
  assert.deepEqual(unresolved, []);
  assert(routes.some(row => row.kind === 'snapshot_listing' && row.path === f.absent));
  assert(routes.some(row => row.kind === 'ordinary_read' && row.path === f.path));
  assert(exposure.some(row => row.ref.id === f.slice.source.id && row.paths.includes(f.path) && row.paths.includes(f.absent)));
  assert(!exposure.some(row => row.ref.id === f.witness.handle.id));
});
