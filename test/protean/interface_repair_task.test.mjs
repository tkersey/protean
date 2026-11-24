import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {executeRepairTask} from '../../tools/evaluation/interface_repair_task.mjs';
import {providerRequestBodyBytes, workspaceBuildOutcomes} from '../../tools/evaluation/workspace.mjs';
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
    application: {}, driver: 'unused', credential: '/unopened', authorizeInference:true, deadline: performance.now() + 2000};
}

test('live task execution requires explicit inference authorization before a driver can start', async t => {
  const options = await setup(t);
  delete options.authorizeInference;
  await assert.rejects(executeRepairTask(options), /explicit --authorize-inference/);
});

test('a failed preflight retains the isolated task, reopens it only for measurements and charges unknowns', async t => {
  const options = await setup(t);
  const calls = [], launches = [], task_id = 'af'.repeat(16);
  const samples = [];
  let rss = 64;
  t.mock.timers.enable({apis: ['setInterval']});
  class RejectedArchive {
    constructor(_, argv) {
      launches.push(argv);
      this.child = {pid: launches.length};
    }
    async call(method) {
      calls.push(method);
      if (method === 'describe') return {execution_mode: 'live', profile: {id: 'adaptive', sha256: hash('profile')}};
      if (method === 'evaluation.interface_repair.admission') return {profile_sha256: hash('profile'), configuration_digest: hash('{}')};
      if (method === 'task.submit') return {task_id};
      if (method === 'evaluation.drain') return {step: 'idle'};
      rss = this.child.pid * 1024;
      t.mock.timers.tick(1000);
      rss = 64;
      throw new Error('UnexportableArchive');
    }
    async close() { return {code: 0, signal: null}; }
  }
  const report = await executeRepairTask(options, {Client: RejectedArchive, sampleRss(pid) {
    samples.push([pid, rss]);
    return rss;
  }});
  t.mock.timers.tick(1000);
  assert.deepEqual(samples, [[1, 64], [1, 1024], [1, 64], [2, 64], [2, 2048], [2, 64]]);
  assert.equal(report.peak_rss_sampled_bytes, 2048);
  assert.equal(report.effective_condition, 'ordinary');
  assert.equal(report.fallback_reason, 'no_candidate');
  assert.equal(report.task.task_id, task_id);
  assert.deepEqual(calls, ['describe', 'evaluation.interface_repair.admission', 'task.submit', 'evaluation.export', 'evaluation.drain', 'evaluation.export']);
  assert.equal(report.inference_dispatch_possible, false);
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

test('unverified captured inputs leave no task or inference dispatch', async t => {
  const options = await setup(t);
  const calls = [];
  class ChangedSnapshot {
    async call(method) {
      calls.push(method);
      if (method === 'describe') return {execution_mode: 'live', profile: {id: 'adaptive', sha256: hash('profile')}};
      if (method === 'evaluation.interface_repair.admission') throw new Error('ChangedSnapshot');
      assert.fail(method);
    }
    async close() { return {code: 0, signal: null}; }
  }
  const report = await executeRepairTask(options, {Client: ChangedSnapshot});
  assert.deepEqual(calls, ['describe', 'evaluation.interface_repair.admission']);
  assert.equal(report.task, null);
  assert.equal(report.inference_dispatch_possible, false);
  assert(report.errors.some(e => e.stage === 'setup' && e.message === 'ChangedSnapshot'));
});

test('changed frozen candidate bytes stop the task before launch', async t => {
  const options = await setup(t);
  const candidate = {source_b64: Buffer.from('changed source').toString('base64'), source_sha256: hash('frozen source')};
  const report = await executeRepairTask({...options, candidate}, {Client: class { constructor() { assert.fail('launched'); } }});
  assert.equal(report.task, null);
  assert(report.errors.some(e => e.stage === 'setup' && e.message.includes('Authored source changed')));
  assert.equal(report.retained_namespace_bytes, 0);
  assert(!report.errors.some(e => e.stage === 'namespace'));
  assert.equal(report.adjudication, null);
});

test('an existing unmeasurable namespace retains its measurement error', async t => {
  const options = await setup(t);
  await writeFile(join(options.output,'state'),'not a directory');
  const report = await executeRepairTask({...options,deadline:0}, {Client: class { constructor() { assert.fail('launched'); } }});
  assert.equal(report.retained_namespace_bytes, null);
  assert(report.errors.some(e => e.stage === 'namespace' && e.message.includes('ENOTDIR')));
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

test('command accounting joins a pre-worker rejection to its captured call and retains an unsettled command', () => {
  const digest = [...Buffer.alloc(32, 7)], id = Buffer.from(digest).toString('hex');
  const key = id + '/build-1';
  const modelSchema = {root: 0, types: [{product: [1, 2, 3]}, {product: [4]}, 'text', {sum: [5]},
    {product: [6]}, {sum: [7, 7]}, 'bytes', 'unit']};
  const model = encodeValue(modelSchema, [[[Buffer.from(digest)]], 'build-1', {tag: 0, value: {tag: 1, value: null}}]);
  const digestType = {array: {element: 3, length: 32}};
  const requestTail = encodeValue({root: 0, types: [{product: [1, 1, 1, 1, 2]}, 'bytes', digestType, 'u8']},
    [Buffer.from('protean.controller/1/workspace'), encodeSchema(modelSchema), Buffer.alloc(0), model, digest]);
  const frame = (magic, data) => {
    const header = Buffer.alloc(20);
    header.write(magic);
    header.writeUInt16LE(3, 8);
    header.writeBigUInt64LE(BigInt(data.length), 12);
    return Buffer.concat([header, data]);
  };
  const request = frame('ABL_ERQ3', Buffer.concat([Buffer.alloc(65), requestTail]));
  const replySchema = {root: 0, types: [{product: [1]}, 'u8']};
  const reply = frame('ABL_ERS3', encodeValue({root: 0, types: [{product: [2, 1]}, 'bytes', digestType, 'u8']},
    [digest, encodeValue(replySchema, [2])]));
  const object = Buffer.from(hash(reply), 'hex');
  const archive = {objects: new Map([[hash(reply), reply]]), object: () => request};
  const occurrence = [digest, null, digest, {tag: 4, value: [digest, object]}, null, {tag: 0}];
  const measure = commands => workspaceBuildOutcomes(archive, new Map([[id, occurrence]]), new Set([id]), commands, replySchema);
  assert.deepEqual(measure(new Map([[key, null]])), {build_commands: 1, settled_build_commands: 1,
    known_rejected_build_commands: 1, rejected_build_commands: 1});
  occurrence[3] = {tag: 7, value: [digest]};
  assert.deepEqual(measure(new Map([[key, null]])), {build_commands: 1, settled_build_commands: 0,
    known_rejected_build_commands: 0, rejected_build_commands: null});
});

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
  const large = {root:0,types:[{product:[1,2,2]},{array:{element:3,length:1_000_001}},'bytes','unit']};
  const bounded = {support:{AdaptivePrepared:schemaSupport(large)}};
  assert.equal(providerRequestBodyBytes(Buffer.from([0,0]),'controller',null,bounded),null);
  assert.throws(()=>providerRequestBodyBytes(Buffer.alloc(0),'controller',null,application),{code:'Truncated'});
});

function decisionFixture(pairedSpecimen) {
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
  const snapshotFiles = {...specimen.files};
  if (pairedSpecimen) {
    const {'scan.json': manifest, ...members} = pairedSpecimen.files;
    Object.assign(snapshotFiles, members, {'paired-scan.json':manifest});
  }
  const snapshotSchema = {root: 0, types: [{product: [1, 2, 3]}, 'u32', 'u64', {seq: 4},
    {product: [5, 6, 8]}, 'text', {array: {element: 7, length: 32}}, 'u8', 'bytes']};
  const snapshot = put(encodeValue(snapshotSchema, [2, 0n, Object.entries(snapshotFiles).map(([name, content]) =>
    [name, [...Buffer.from(hash(content), 'hex')], Buffer.from(content)])]));
  const profile = put(Buffer.from(JSON.stringify({snapshot: {digest: [...snapshot[0]], bytes: String(snapshot[1])}})));
  const archive = {objects, task: {profile}, object: r => objects.get(Buffer.from(r[0]).toString('hex'))};
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
    const text = snapshotFiles[name];
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
    const input = [{type: 'function_call', call_id}, {type: 'function_call_output', call_id, output: [{type: 'input_text', text: JSON.stringify({
      disposition, observation: mismatch ? {} : observation})}]}];
    if (block) input.push({role: 'user', content: [{type: 'input_text', text: JSON.stringify({selected_context_data: [block]})}]});
    history.push({interaction_id: id, event_cut: id, attempt: {id, delivery: 'confirmed', model_response: true, selected_view: selected, body: {input}},
      previous: {id: 'previous', delivery: 'confirmed', model_response: true}, results: [{call_id, output: {tag: 'workspace', value: {reply}}}],
      result_actions: [{call_id, action: {tag, value: {command}}}]});
  };
  const expand = (handle, text, start, end) => step('context', {tag: 'expand', value: {reference: handle}}, page(text, start, end));
  const materialize = item => step('context', {tag: 'materialize', value: {input: {tag: 'value', value: {tag: 'reference', value: item.handle}}}},
    {value: item.handle, source: item.source, preview: page(JSON.stringify(item.text))});
  const workSchema = {root: 0, types: [{product: [1,2,3,3,4,3,5,3,4]}, 'u8', 'bytes', 'unit', 'text', {sum:[6,10]},
    {product:[7,8]}, {product:[4,4]}, {product:[9,16,4]}, {seq:13}, {product:[11,12]},
    {product:[4,14,1]}, {sum:[15,4,4]}, {product:[4,14]}, 'u64', {product:[2,4,4,14,14,14,4]}, 'boolean']};
  const controlSchema = {root:0,types:[{product:[1,7]}, {product:[2,4,7,6,6,8,9,10,10,11,11,12,12,6,6]},
    {array:{element:3,length:16}}, 'u8', {product:[5,6]}, {array:{element:3,length:32}}, 'u64','text',
    {enumeration:[0,1,2]}, {enumeration:[0,1,2,3,4,5,6,7]}, {bounded_text:64}, {bounded_text:128}, {enumeration:[0,1,2,3,4,5,6]}]};
  const work = (result, rendered) => {
    const task = Buffer.alloc(16), id = String(history.length + 1), call_id = 'work-' + id;
    const text = JSON.stringify(rendered);
    const artifact = put(encodeValue(workSchema, [2, task, null, null, call_id, null, result, null, text]));
    history.push({interaction_id: id, task_id: task.toString('hex'), event_cut: id, previous: {delivery: 'confirmed', model_response: true},
      attempt: {id, delivery: 'confirmed', model_response: true, body: {input: [{type:'function_call', call_id}, {type:'function_call_output', call_id, output: text}]}},
      results: [{call_id, output: {tag: 'work', value: {digest: [...artifact[0]], bytes: String(artifact[1])}}}], result_actions: []});
  };
  const support = (uses = [], projector = null, consumers, producer = history.at(-1)) => decisionSupport(archive,
    {support: {WorkArtifact:schemaSupport(workSchema), ReceiptArtifact:schemaSupport(controlSchema)}},
    specimen, refs, values, history, uses, producer, projector, consumers, pairedSpecimen);
  return {step, support, expand, acquire, materialize, work, snapshot, history, page, path, member, absent, file, slice, full, witness, input, result, value, put, controlSchema};
}

test('a delivered control receipt establishes metadata only for its recorded task, capture and call', () => {
  const f = decisionFixture(), task = Buffer.alloc(16), capture = f.put(Buffer.from('capture')), text = 'Unchanged';
  f.step('program', {tag:'describe',value:{section:'components'}}, {});
  const [i] = f.history, pending = i.results[0];
  const receipt = [[...task],[[...capture[0]],capture[1]],pending.call_id,1n,1n,1,0,'adaptive','adaptive','m','m',1,1,0n,0n];
  const object = f.put(encodeValue(f.controlSchema,[receipt,text]));
  pending.output = {tag:'control',value:{digest:[...object[0]],bytes:String(object[1])}};
  i.task_id = task.toString('hex');
  i.previous.capture_sha256 = Buffer.from(capture[0]).toString('hex');
  const delivered = i.attempt.body.input[1];
  delivered.output = text;
  assert.deepEqual(f.support(), {exposure:[], projection_exposure:[], routes:[], unresolved:[]});
  for (const [target,key,value] of [[i,'task_id','other'], [i.previous,'capture_sha256','other'],
    [pending,'call_id','other'], [delivered,'output','Different']]) {
    const original = target[key];
    target[key] = value;
    assert(f.support().unresolved.some(r => r.kind === 'unbound_control_receipt'));
    target[key] = original;
  }
});

test('a delivered judgment or complete pages of its ScanEvidence field support the canonical input citation', () => {
  const bind = f => {
    const ids = Array.from({length:13},(_,i) => i);
    const fields = [[1,4],[2,3],ids,64,[5,9],[6,6,7,8],null,null,6,10,[6,6,6,7,6,1]];
    const tags = ['product','product','enumeration','bounded_text','product','product','u64','boolean','seq','seq','product'];
    const schema = {root:0,types:fields.map((v,i) => v === null ? tags[i] : {[tags[i]]:v})};
    const display = {root:'0',types:fields.map((v,i) => ({tag:tags[i],value: v === null ? {} :
      tags[i] === 'enumeration' ? v : Array.isArray(v) ? v.map(String) : String(v)}))};
    const model = [[12,'e'.repeat(64)],[['1','1',true,['1']],[
      ['1','1','1',true,'2',[3,f.witness.handle.id]], ['1','1','1',false,'0',[3,f.full.handle.id]]]]];
    const x = f.input;
    x.raw[4][0] = 3;
    x.raw[3][1] = f.put(encodeSchema(schema));
    x.raw[3][2] = f.put(encodeValue(schema,model));
    const use = {canonical_input:true,input:x.handle,result:f.result.handle,exposures:[]};
    const block = {kind:'judgment',value_reference:x.handle,schema:display,provenance:{...x.source,kind:'provenance'},value:model};
    return {use,block, support:() => f.support([use]), credited:() => f.support([use]).exposure
      .some(row => row.ref.id === x.handle.id && [f.path,f.member,f.absent].every(path => row.paths.includes(path)))};
  };
  const f = decisionFixture(), pages = bind(f), text = JSON.stringify(pages.block.value);
  const start = text.indexOf(JSON.stringify(pages.block.value[1])), end = text.length - 1;
  f.expand(f.input.handle,text,start,end - 1);
  assert(pages.support().routes.some(row => row.kind === 'expansion'));
  assert(!pages.credited());
  f.expand(f.input.handle,text,end - 1,end);
  assert(pages.credited());
  for (const patch of [{}, {schema:{}}, {value:[]}, {provenance:{kind:'value',id:'other'}}]) {
    const f = decisionFixture(), judgment = bind(f);
    f.step('program',{tag:'describe',value:{section:'components'}},{}, {selected:'a'.repeat(64),block:{...judgment.block,...patch}});
    assert.equal(judgment.credited(),!Object.keys(patch).length);
    assert.equal(judgment.support().unresolved.length,Object.keys(patch).length);
  }
});

test('verified partial snapshot handles each carry only their own source interval', () => {
  const f = decisionFixture(), tail = f.acquire(f.path, 4, f.file.length);
  f.materialize(f.slice);
  f.materialize(tail);
  const {exposure} = f.support();
  for (const [item, start, end] of [[f.slice, 0, 4], [tail, 4, f.file.length]]) {
    const entry = exposure.find(e => e.ref.id === item.handle.id);
    assert.deepEqual(entry.paths, []);
    assert.deepEqual(entry.range, {path: f.path, start, end});
  }
});

test('a confirmed ordinary acquisition survives a missing report without becoming decision support', () => {
  const f = decisionFixture();
  f.materialize(f.full);
  const evidence = () => f.support([],null,undefined,null);
  assert(evidence().routes.some(r => r.path === f.path));
  assert.deepEqual(evidence().exposure, []);
  assert.deepEqual(evidence().projection_exposure, []);
  f.history[0].attempt.model_response = null;
  assert.deepEqual(evidence().routes, []);
});

test('a reused settled call ID binds the current materialization output', () => {
  const f = decisionFixture();
  f.materialize(f.full);
  const [call, output] = f.history[0].attempt.body.input;
  f.history[0].attempt.body.input.unshift({...call}, {...output, output:'old output'});
  assert(f.support().exposure.some(r => r.ref.id === f.full.handle.id));
  f.history[0].attempt.body.input[1] = output;
  f.history[0].attempt.body.input[3] = {...output, output:'wrong current output'};
  assert(!f.support().exposure.some(r => r.ref.id === f.full.handle.id));
});

test('ordinary paired development reads are attributed to their own manifest and visits', () => {
  const path = 'paired-scan.json', member = 'r-pair', missing = 'r-pair-missing';
  const manifest = JSON.stringify({domain:{identity:'1',revision:'1',known:true,members:['1']},
    visits:[member,missing].map(path => ({domain_identity:'1',domain_revision:'1',member:'1',path}))});
  const f = decisionFixture({files:{'scan.json':manifest,[member]:'1'}});
  const size = BigInt(Buffer.byteLength(manifest)), found = [f.snapshot[0],path,hash(manifest),0n,size,size,manifest];
  f.work({tag:1,value:[[path,0n,Number(size)],{tag:0,value:found}]}, {tag:'found',value:{snapshot:[...f.snapshot[0]],
    path,sha256:hash(manifest),start:'0',end:String(size),file_bytes:String(size),content:manifest}});
  const paired = f.acquire(member, 0, 1);
  f.materialize(paired);
  f.work({tag:1,value:[[missing,0n,1],{tag:1,value:missing}]}, {tag:'missing',value:missing});
  f.materialize(f.full);
  const {exposure, routes, unresolved} = f.support();
  assert.deepEqual(unresolved, []);
  assert(routes.some(row => row.kind === 'ordinary_read' && row.path === path));
  assert(routes.some(row => row.kind === 'missing_read' && row.path === missing));
  assert(exposure.some(row => row.ref.id === paired.handle.id && row.paths.includes(member)));
  assert(!exposure.some(row => row.ref.id === f.full.handle.id && row.paths.includes(missing)));
});

test('failed or suspended work previews keep possible independent evidence visible', () => {
  const f = decisionFixture(), work = {kind:'work',id:'3'.repeat(64)}, port = {kind:'port',id:'4'.repeat(64)};
  f.step('work', {tag:'wait'}, {works:[{work, failure:work, failure_preview:f.page('failure detail')}]});
  f.step('work', {tag:'inspect'}, {work, port:{reference:port,preview:f.page('port payload')}});
  const {unresolved, routes} = f.support();
  assert.deepEqual(routes, []);
  assert.deepEqual(unresolved.map(r => [r.kind,r.ref]), [['work_failure_preview',work],['work_port_preview',port]]);
});

test('escaped value pages and ordinary byte reads can jointly establish a complete source', () => {
  const f = decisionFixture(), split = 12;
  const shown = JSON.stringify(f.file), end = Buffer.byteLength(JSON.stringify(f.file.slice(0, split))) - 1;
  f.expand(f.full.handle, shown, 0, end);
  assert(!f.support().exposure.some(r => r.paths.includes(f.path)));
  const text = f.file.slice(split), size = BigInt(f.file.length), found = [f.snapshot[0], f.path,hash(f.file),BigInt(split),size,size,text];
  f.work({tag:1,value:[[f.path,BigInt(split),text.length],{tag:0,value:found}]},
    {tag:'found',value:{snapshot:[...f.snapshot[0]],path:f.path,sha256:hash(f.file),start:String(split),end:String(size),file_bytes:String(size),content:text}});
  assert(f.support().exposure.some(r => r.ref.id === f.full.handle.id && r.paths.includes(f.path)));
});

test('confirmed range rejections distinguish file presence from returned file contents', () => {
  const f = decisionFixture(), reason = 'Read requires maximum 1..4096 and an offset within the file.';
  f.work({tag: 1, value: [[f.member, 99n, 1], {tag: 2, value: reason}]}, {tag: 'invalid', value: reason});
  f.step('context', {tag: 'materialize', value: {input: {tag: 'snapshot', value: {path:f.path, offset:'99999', maximum:'1'}}}},
    {error: 'InvalidRange'}, {disposition:'rejected'});
  const result = f.support();
  assert.deepEqual(result.routes.map(r => [r.kind, r.path]), [['file_present', f.member], ['file_present', f.path]]);
  assert.deepEqual(result.exposure, []);
});

test('a bound report correction discloses metadata only', () => {
  const f = decisionFixture(), rejection = {reason: 'empty_report', claim_index: null, evidence_position: null};
  f.step('context', {tag: 'inspect', value: {}}, {});
  const i = f.history[0];
  i.results[0].output = {tag: 'report_rejection', value: rejection};
  i.attempt.body.input[1].output[0].text = JSON.stringify(rejection);
  assert.deepEqual(f.support().unresolved, []);
  i.attempt.body.input[1].output[0].text = 'different text';
  assert.equal(f.support().unresolved[0].kind, 'unbound_report_rejection');
});

test('unfamiliar projected results retain verified copy ancestry after projector inspection', () => {
  const f = decisionFixture(), selected = 'b'.repeat(64), descriptor = {root: '0', types: [{tag:'text',value:{}}]};
  const use = {input: f.input.handle, result: f.result.handle, paths: [], one_computed_block: true, payload: 'value',
    payload_schema_sha256: 'schema', payload_descriptor: descriptor, schema_kind: 'other', semantic_judgment: 'unestablished',
    exposures: [{id: '1', rendered: true, model_response: true, delivery: 'confirmed'}]};
  const projector = {program: {kind:'program', id:'c'.repeat(64)}, source:f.slice.source, source_bytes:Buffer.from('projector')};
  f.step('program', {tag: 'inspect', value: {target: {tag: 'program', value: projector.program}}},
    f.page('projector descriptor'), {selected, block: {kind: 'computed', schema_identity: 'schema', schema: descriptor,
      result: use.result, value: use.payload}});
  f.expand(projector.source, 'projector', 0, 5);
  const alias = f.value('copy', f.result.text, [3, [f.witness.raw[2], f.result.raw[2]], null, null, {tag: 0}]);
  const cmd = {tag: 'materialize', value: {sources: [f.witness.handle], input: {tag: 'value', value: {tag: 'reference', value: use.result}}}};
  f.step('context', cmd, {value: alias.handle, preview: f.page(JSON.stringify(alias.text), 0, 3)});
  const linked = f.support([use], projector);
  assert.deepEqual(linked.routes, []);
  assert.deepEqual(linked.unresolved, []);
  assert.equal(linked.exposure[0].schema_sha256, 'schema');
  const copied = linked.exposure.find(row => row.ref.id === alias.handle.id);
  assert.deepEqual(copied.projected_result, use.result);
  assert.deepEqual(copied.paths, []);
  assert.equal(copied.semantic_judgment, 'unestablished');
  alias.raw[4][1] = [];
  const unbound = f.support([use], projector);
  assert(!unbound.exposure.some(row => row.ref.id === alias.handle.id));
  assert(unbound.unresolved.some(row => row.kind === 'unbound_alias'));
});

test('a host-limited recursive result preview preserves other verified source evidence', () => {
  const f = decisionFixture();
  f.result.raw[3][1] = f.put(encodeSchema({types: [{seq: 0}], root: 0}));
  f.result.raw[3][2] = f.put(Buffer.concat([Buffer.alloc(12000, 1), Buffer.from([0])]));
  f.expand(f.result.handle, '[]', 0);
  f.materialize(f.full);
  const support = f.support([{input:f.input.handle, result:f.result.handle, exposures:[]}]);
  assert(support.unresolved.some(r => r.ref?.id === f.result.handle.id));
  assert(support.exposure.some(r => r.ref.id === f.full.handle.id && r.paths.includes(f.path)));
});

test('verified acquisition previews and ranged source expansions bind both manifest references to observed misses', () => {
  const f = decisionFixture();
  f.materialize(f.slice);
  assert(!f.support().exposure.some(row => row.paths.length));
  f.expand(f.slice.source, f.file, 8);
  assert(!f.support().exposure.some(row => row.paths.length));
  f.expand(f.slice.source, f.file, 0, 8);
  f.materialize(f.full);
  f.step('context', {tag: 'materialize', value: {input: {tag: 'snapshot', value: {path: f.absent}}}},
    {error: 'SourceMissing'}, {disposition: 'rejected'});
  const {routes, unresolved, exposure} = f.support();
  assert.deepEqual(unresolved, []);
  assert(routes.some(row => row.kind === 'missing_read'));
  for (const ref of [f.full.handle, f.full.source, f.slice.source])
    assert(exposure.some(row => row.ref.id === ref.id && row.paths.includes(f.path) && row.paths.includes(f.absent)));
  assert.deepEqual(exposure.find(row => row.ref.id === f.slice.handle.id).range, {path: f.path, start: 0, end: 4});
});

test('only confirmed returned bytes credit a retained reference or its copied alias', () => {
  const f = decisionFixture();
  const alias = f.value('copy', f.file, [3, [f.witness.raw[2], f.full.raw[2]], null, null, {tag: 0}]);
  const cmd = {tag: 'materialize', value: {sources: [f.witness.handle], input: {tag: 'value', value: {tag: 'reference', value: f.full.handle}}}};
  const observation = {value: alias.handle, preview: f.page(JSON.stringify(f.file))};
  f.step('context', cmd, observation, {mismatch: true});
  assert.equal(f.support().unresolved.length, 1);
  assert(!f.support().exposure.some(row => row.paths.length));
  f.step('context', cmd, observation);
  assert(f.support().exposure.some(row => row.ref.id === alias.handle.id && row.paths.includes(f.path)));
});

test('same-result previews retain projection credit and paged canonical-input reads constitute fallback', () => {
  const f = decisionFixture(), selected = 'a'.repeat(64);
  const row = ['1','1','1',true,'2',[3,f.witness.handle.id]];
  const payload = [[1, 1, true, [1]], [row]];
  const use = {canonical_input: true, input: f.input.handle, result: f.result.handle, paths: [f.path, f.member],
    one_computed_block: true, payload, payload_schema_sha256: 's', payload_descriptor: {root:'0',types:[]}, schema_kind: 'ScanEvidence', semantic_judgment: 'supported',
    exposures: [{id: '1', rendered: true, delivery: 'confirmed', model_response: true}]};
  f.step('work', {tag: 'inspect'}, {result: use.result, result_preview: f.page(JSON.stringify(f.result.text))},
    {selected, block: {kind: 'computed', schema_identity: 's', schema: use.payload_descriptor, result: use.result, value: payload}});
  assert.deepEqual(f.support([use]).routes, []);
  assert.deepEqual(f.support([use]).unresolved, []);
  assert(f.support([use]).exposure.some(e => e.ref.id === f.witness.handle.id && e.paths.length === 1 && e.paths[0] === f.member));
  const projected = f.support([use], {result:use.result}).projection_exposure;
  assert(projected.some(row => row.ref.id === use.result.id && row.paths.includes(f.path)));
  assert(projected.some(row => row.ref.id === f.witness.handle.id && row.paths.includes(f.member)));
  const text = JSON.stringify(f.input.text);
  f.expand(f.input.handle, text, 3);
  assert(f.support([use]).routes.some(row => row.ref?.id === f.input.handle.id));
  assert(!f.support([use]).exposure.some(row => row.ref.id === f.input.handle.id));
  assert(f.support([use]).unresolved.some(row => row.ref?.id === f.input.handle.id));
  f.expand(f.input.handle, text, 0, 3);
  assert.deepEqual(f.support([use]).unresolved, []);
  assert(f.support([use]).routes.some(row => row.ref?.id === f.input.handle.id));
  assert(f.support([use]).exposure.some(row => row.ref.id === f.input.handle.id && row.paths.includes(f.absent)));
});

test('static guidance, bound controller metadata and a verified same-view reread do not disclose fresh scan evidence', () => {
  const f = decisionFixture(), descriptor = {root:'0', types:[{tag:'text',value:{}}]};
  const use = {view:{kind:'view',id:'d'.repeat(64)}, work:{kind:'work',id:'f'.repeat(64)}, program:{kind:'program',id:'a'.repeat(64)},
    consumer:{kind:'observation',id:'e'.repeat(64)}, input:f.input.handle,
    result:f.result.handle, canonical_input:true, paths:[], payload:'shown', payload_descriptor: descriptor,
    payload_schema_sha256:'s', schema_kind:'other', semantic_judgment:'unestablished', one_computed_block:true,
    exposures:[{id:'1',rendered:true,delivery:'confirmed',model_response:true}]};
  f.step('program',{tag:'describe',value:{section:'projection'}},f.page('static projection documentation'),
    {selected:use.view.id,block:{kind:'computed',value:'shown',schema:descriptor,schema_identity:'s',result:use.result}});
  for (const section of ['components','semantic_candidates'])
    f.step('program',{tag:'describe',value:{section}},f.page('contract metadata'));
  f.step('context',{tag:'inspect',value:{consumer:{target:{tag:'controller',value:{}}}}},
    {consumer:use.consumer,binding:f.page('binding metadata')});
  f.step('context',{tag:'expand',value:{reference:use.consumer}}, {consumer:use.consumer,binding:f.page('binding metadata', 3)});
  f.step('program',{tag:'inspect',value:{target:{tag:'consumer',value:{program:{...use.program,id:use.program.id.toUpperCase()},function:'main',binding:'input'}}}},
    f.page('projector consumer'));
  const schema = {kind:'schema', id:Buffer.from(f.input.raw[3][1][0]).toString('hex')};
  f.expand(schema, JSON.stringify(descriptor), 3, 11);
  f.step('context',{tag:'expand',value:{reference:use.view}},
    {view:use.view,consumer:use.consumer,projection_result:use.result,coverage:'selected_blocks_only',selection:f.page(JSON.stringify(f.result.text))});
  f.step('work', {tag:'inspect'}, {program:use.program, work:use.work, result:use.result, result_preview:f.page(JSON.stringify(f.result.text))});
  const projector = {program:use.program, result:use.result, schema_ids:[schema.id]};
  const read = () => f.support([use], projector, new Set([use.consumer.id]));
  assert.deepEqual(read().unresolved, []);
  assert.deepEqual(read().routes, []);
  for (const alias of [use.view, use.work]) {
    const citation = read().exposure.find(row => row.ref.id === alias.id);
    assert.deepEqual(citation.projected_result, use.result);
    assert.equal(citation.semantic_judgment, 'unestablished');
    assert(read().projection_exposure.some(row => row.ref.id === alias.id));
  }
  f.expand(f.input.handle, JSON.stringify(f.input.text), 0, 0);
  assert(read().routes.some(r => r.kind === 'expansion' && r.ref.id === f.input.handle.id));
  assert(!read().projection_exposure.some(row => row.ref.id === f.input.handle.id));
  f.expand(schema, 'unverified schema');
  assert(read().unresolved.some(r => r.ref?.id === schema.id));
});

test('a view citation requires delivery of its result and a matching view expansion', () => {
  const f = decisionFixture(), use = {view:{kind:'view',id:'c'.repeat(64)}, consumer:{kind:'observation',id:'d'.repeat(64)},
    input:f.input.handle, result:f.result.handle, paths:[f.path,f.member], one_computed_block:true,
    semantic_judgment:'supported', schema_kind:'other', exposures:[]};
  const text = JSON.stringify(f.result.text);
  const show = (result, page) => f.step('context', {tag:'expand',value:{reference:use.view}},
    {view:use.view,consumer:use.consumer,projection_result:result,coverage:'selected_blocks_only',selection:page});
  const cited = () => f.support([use], {result:use.result}).exposure.find(e => e.ref.id === use.view.id);
  show(f.input.handle, f.page(text));
  assert.equal(cited(), undefined);
  show(use.result, f.page(text, 0, 5));
  assert.equal(cited(), undefined);
  show(use.result, f.page(text, 5));
  assert.deepEqual(cited().paths, use.paths);
  assert.deepEqual(f.support([use], {result:use.result}).projection_exposure, []);
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
  assert(!f.support().exposure.some(row => row.paths.length));
  read(20, f.file.length);
  const {routes, exposure, unresolved} = f.support();
  assert.deepEqual(unresolved, []);
  assert(routes.some(row => row.kind === 'snapshot_listing' && row.path === f.absent));
  assert(routes.some(row => row.kind === 'ordinary_read' && row.path === f.path));
  assert(exposure.some(row => row.ref.id === f.slice.source.id && row.paths.includes(f.path) && row.paths.includes(f.absent)));
  assert(!exposure.some(row => row.ref.id === f.witness.handle.id));
});
