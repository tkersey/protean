// External fixture controller for the copied native Kosmos host. Fixture indexes
// choose prescribed provider replies, never the agent's policy or continuation.
import assert from 'node:assert/strict';
import {createServer} from 'node:https';
import {X509Certificate, createHash} from 'node:crypto';
import {once} from 'node:events';
import {mkdir, writeFile, readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {ProteanClient} from '../support/stdio-client.mts';
import {certificates} from '../support/tls.mjs';
import {readArchive, missingCaptures, tamperedAdaptiveControl, missingCheckpoint, changedProfile, extraPrivateArtifact, omittedAttempts, changedOperationKey, invalidEventData} from './native_archive.mjs';
import {decodeValue, encodeValue} from '../support/values.mjs';
import {workspaceMetrics} from '../../tools/evaluation/workspace.mjs';
import {contract, assertAdaptiveCaptures} from './adaptive_capture_checks.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const reference = bytes => [[...createHash('sha256').update(bytes).digest()], BigInt(bytes.length)];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function within(promise, milliseconds, message) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), milliseconds); })]); }
  finally { clearTimeout(timer); }
}
async function until(read, predicate, maximum = 400) {
  for (let n = 0; n < maximum; n++) {
    const value = await read(); if (predicate(value)) return value;
    assert(!['blocked', 'failed', 'unknown', 'completed', 'cancelled'].includes(value.status), `unexpected adaptive status ${JSON.stringify(value)}`);
    await delay(10);
  }
  assert.fail('adaptive task timeout');
}
const resultSchema = {root: 0, types: [{product: [1, 3]}, {array: {element: 2, length: 32}}, 'u8', 'bytes']};
function resultValue(bytes) {
  assert.equal(bytes.subarray(0, 8).toString(), 'ABL_ERS3');
  assert.equal(bytes.readBigUInt64LE(12), BigInt(bytes.length - 20));
  return Buffer.from(decodeValue(resultSchema, bytes.subarray(20))[1]);
}
function linkRecipe(stages) {
  const instances = [], bindings = [];
  const bind = (from, symbol, to) => bindings.push({required: {instance: from, symbol}, supplied: {instance: to, symbol: 'apply'}});
  stages.forEach(([component_id, operation], index) => {
    const key = `stage${index}`; instances.push({key, component_id});
    if (operation) { instances.push({key: `operation${index}`, component_id: operation}); bind(key, component_id === 'map' ? 'row' : 'keep', `operation${index}`); }
    if (index + 1 < stages.length) {
      instances.push({key: `compose${index}`, component_id: 'compose'}); bind(`compose${index}`, 'first', key);
      bind(`compose${index}`, 'second', index + 2 === stages.length ? `stage${index + 1}` : `compose${index + 1}`);
    }
  });
  return {instances, bindings, entry: {instance: 'compose0', symbol: 'apply'}};
}
function strings(value) {
  if (typeof value === 'string') return [value];
  if (value && typeof value === 'object') return Object.values(value).flatMap(strings);
  return [];
}

const workspaceCall = (family, tag, value) => [family, {command: {tag, value}}];
function* workspaceTrace(subject, scenario) {
  const skill = (operation, revision, skill_id = 'tool-construction') => ['skill_set', {operation, skill_id, version: '1', residency: operation === 'load' ? 'resident' : 'unchanged', expected_revision: revision, reason: 'Exercise retained computation and independent execution authority.'}];
  const build = recipe => workspaceCall('program', 'build', {source: {tag: 'json_text', value: JSON.stringify(recipe)}, source_kind: 'component_recipe', exposures: []});
  function* materialize(id) {
    const reply = yield workspaceCall('context', 'materialize', {input: {tag: 'authorized_input', value: id}, sources: []});
    assert.equal(reply.disposition, 'observed', JSON.stringify(reply));
    subject.evidenceCount = reply.evidence_index + 1;
    return reply.observation.value;
  }
  function* run(input, expected) {
    assert(subject.offered.has('work'));
    let reply = yield workspaceCall('work', 'start', {program: subject.program, input: {tag: 'reference', value: input}, policy: {stop: 'terminal', continuation: 'owner_scheduled'}});
    assert.equal(reply.disposition, 'observed', JSON.stringify(reply));
    const work = reply.observation.work;
    if (reply.observation.outcome !== 'completed') {
      const waited = yield workspaceCall('work', 'wait', {works: [work], after: Number.MAX_SAFE_INTEGER});
      assert.equal(waited.observation.works[0].outcome, 'completed', JSON.stringify(waited));
      reply = yield workspaceCall('work', 'inspect', {work});
    }
    assert.equal(reply.observation.outcome, 'completed', JSON.stringify(reply));
    assert.deepEqual(reply.observation.program, subject.program);
    const table = JSON.parse(reply.observation.result_preview.text);
    assert.deepEqual(table[0].map(row => scenario === 'tools-reverse' ? [row[3], row[2]] : [row[0], row[7]]), expected);
    assert.equal(reply.evidence_index, subject.evidenceCount);
    subject.evidenceCount++;
    subject.resultIndices.push(reply.evidence_index);
    subject.results.push(reply.observation.result);
    return reply;
  }
  assert(subject.offered.has('program') && subject.offered.has('work') && subject.offered.has('context'));
  subject.resultIndices = []; subject.results = []; subject.evidenceCount = 0;
  if (scenario === 'tools-disabled') {
    yield skill('load', 0);
    yield skill('unload', 1);
    assert(subject.offered.has('program'), 'description remains available without construction permission');
    const denied = yield build(subject.recipe);
    assert.equal(denied.disposition, 'rejected');
    assert.equal(denied.observation.error, 'Unauthorized');
    yield ['stop', {reason: 'Construction is not authorized; ordinary actions remain available.'}];
    return;
  }
  if (scenario === 'tools-foreign') {
    const input = yield* materialize(subject.inputs[0].id);
    const denied = yield workspaceCall('work', 'start', {program: subject.foreign, input: {tag: 'reference', value: input}, policy: {stop: 'terminal', continuation: 'owner_scheduled'}});
    assert.equal(denied.disposition, 'rejected');
    assert.equal(denied.observation.error, 'ArtifactUnavailable');
    yield ['stop', {reason: 'The foreign task program reference was not admitted.'}];
    return;
  }
  yield skill('load', 0);
  const marker = 'Recipe JSON schema:\n';
  const contractText = strings(subject.body.input).find(text => text.includes(marker));
  assert(contractText, 'loading construction exposes the actual recipe contract');
  const recipeSchema = JSON.parse(contractText.slice(contractText.indexOf(marker) + marker.length).split('\n')[0]);
  assert.deepEqual(recipeSchema.required, ['instances', 'bindings', 'entry']);
  assert.equal(recipeSchema.additionalProperties, false);
  assert.equal(Object.hasOwn(recipeSchema.properties.instances, 'maxItems'), false);
  assert.deepEqual(recipeSchema.properties.instances.items.required, ['key', 'component_id']);
  assert.equal(Object.hasOwn(recipeSchema.properties.instances.items.properties.key, 'maxLength'), false);
  assert.equal(Object.hasOwn(recipeSchema.properties.bindings, 'maxItems'), false);
  assert.deepEqual(recipeSchema.properties.bindings.items.required, ['required', 'supplied']);
  assert.deepEqual(recipeSchema.properties.bindings.items.properties.required.required, ['instance', 'symbol']);
  assert.deepEqual(recipeSchema.properties.entry.required, ['instance', 'symbol']);
  if (scenario === 'tools-reuse') for (let attempt = 0; attempt < 3; attempt++) {
    const denied = yield build({...subject.recipe, unapproved_policy: attempt});
    assert.equal(denied.disposition, 'rejected');
    assert(subject.offered.has('program'), 'unsuccessful attempts do not revoke construction');
  }
  const built = yield build(subject.recipe);
  assert.equal(built.disposition, 'admitted', JSON.stringify(built));
  subject.program = built.observation.program;
  const firstInput = yield* materialize(subject.inputs[0].id);
  const first = yield* run(firstInput, scenario === 'tools-reverse' ? [['3','2'],['4','1']] : [['1','1'],['2','2'],['3','3'],['4','4']]);
  if (scenario === 'tools-reverse') {
    yield ['report', {summary: 'Three unsupported source records, grouped into counts two and one.', claims: [{kind: 'observation', statement: 'Three unsupported source records, grouped into counts two and one.', reasoning: '', evidence_indices: [first.evidence_index]}], limitations: []}];
    return;
  }
  yield skill('load', 1, 'invariant-review');
  assert(!subject.offered.has('inspect'), 'computed evidence is not a source-file inspection target');
  yield ['read', {path: 'src/main.zig', start: 0, maximum: 4096}];
  subject.sourceIndex = subject.evidenceCount++;
  assert(subject.offered.has('inspect'));
  const inappropriate = yield ['inspect', {evidence_index: first.evidence_index}];
  assert.match(inappropriate, /source-file evidence/);
  const inspected = yield ['inspect', {evidence_index: subject.sourceIndex}];
  assert.match(inspected, new RegExp(`Observed 0 lines.*evidence ${subject.sourceIndex}`));
  yield skill('unload', 2, 'invariant-review');
  subject.heldIndex = subject.calls + 1;
  yield ['ask', {question: 'The first audit and source inspection are acquired. Continue on the second input?'}];
  assert(subject.offered.has('program'), 'construction remains available after restart');
  yield skill('deactivate', 3);
  yield skill('unload', 4);
  assert(subject.offered.has('work') && subject.offered.has('program'));
  assert(strings(subject.body.input).some(text => text.includes('Retained workspace program references') && text.includes(subject.program.id)));
  const secondInput = yield* materialize(subject.inputs[1].id);
  for (let n = 0; n < 11; n++) yield* run(n % 2 ? firstInput : secondInput, n % 2 ? [['1','1'],['2','2'],['3','3'],['4','4']] : [['80','1']]);
  for (let n = 0; n < 12; n++) {
    assert(subject.offered.has('skill_set'), 'control revisions remain available beyond sixteen');
    yield skill(n % 2 ? 'unload' : 'load', 5 + n, 'repository-orientation');
  }
  yield ['report', {summary: 'The same admitted program continued auditing both inputs after restart.', claims: [
    {kind: 'observation', statement: 'The source range and second computed audit are acquired.', reasoning: '', evidence_indices: [subject.sourceIndex, subject.resultIndices.at(-1)]},
    {kind: 'inference', statement: 'The retained program supports comparing both audit results.', reasoning: 'The first and last computed values retain that program as provenance.', evidence_indices: [subject.resultIndices[0], subject.resultIndices.at(-1)]},
    {kind: 'hypothesis', statement: 'Other inputs may reveal discrepancies.', reasoning: 'Only the admitted inputs were exercised.', evidence_indices: []}], limitations: ['No universal correctness claim.']}];
}

export async function verifyAdaptiveNative({app, applicationPath}) {
  const assetBytes = await readFile(applicationPath), asset = JSON.parse(assetBytes);
  const fixture = JSON.parse(Buffer.from(asset.resources.find(row => row.id === 'adaptive-agent.offline-responses').base64url, 'base64url'));
  const root = join(app.data, 'controlled snapshot'), state = join(app.data, 'controlled state'), configPath = join(app.data, 'adaptive.json');
  await mkdir(join(root, 'src'), {recursive: true});
  const source = 'pub fn main() void {\n    // The offline fixture has no external effects.\n}\n';
  await writeFile(join(root, 'src/main.zig'), source);
  const tls = await certificates(app.controller), trust = join(app.data, 'adaptive-root.der');
  await writeFile(trust, new X509Certificate(tls.ca).raw);
  const requests = [], sockets = new Set();
  let providerFailure, announceHeld, releaseHeld;
  let scenario = 'trajectory', alternateIndex = 0, alternateRequests = 0, announceAlternate;
  let toolSubject;
  const selectScenario = name => {
    scenario = name; alternateIndex = 0;
    return new Promise(resolve => { announceAlternate = resolve; });
  };
  const held = new Promise(resolve => { announceHeld = resolve; }), release = new Promise(resolve => { releaseHeld = resolve; });
  const server = createServer(tls.A, async (request, response) => {
    try {
      const chunks = []; for await (const bytes of request) chunks.push(bytes);
      const bytes = Buffer.concat(chunks), body = JSON.parse(bytes);
      assert.equal(Object.hasOwn(body, 'max_output_tokens'), false, 'normal requests omit an artificial output-token cap');
      assert.equal(request.url, '/v1/responses'); assert.equal(request.headers.authorization, 'Bearer qualification-only');
      if (scenario.startsWith('tools-')) {
        const index = alternateIndex++, subject = toolSubject;
        subject.calls = index; subject.body = body;
        subject.offered = new Set(body.tool_choice.tools.map(tool => tool.name));
        let previous;
        if (index === 0) {
          const marker = 'Authorized typed Table inputs: ', text = strings(body.input).find(text => text.includes(marker));
          assert(text); subject.inputs = JSON.parse(text.slice(text.indexOf(marker) + marker.length));
          assert.equal(subject.inputs.length, 2);
          subject.trace = workspaceTrace(subject, scenario);
        } else {
          const result = body.input.find(item => item.type === 'function_call_output' && item.call_id === `tools-${index - 1}`);
          assert(result, `missing paired output ${index - 1}`);
          const text = typeof result.output === 'string' ? result.output : result.output[0].text;
          try { previous = JSON.parse(text); } catch { previous = text; }
        }
        const next = subject.trace.next(previous);
        assert(!next.done, 'the recorded scenario must finish through a real controller action');
        const call = next.value;
        response.writeHead(200, {'content-type': 'application/json'});
        response.end(JSON.stringify({id: `tools-response-${index}`, status: 'completed', error: null, output: [{type: 'function_call', status: 'completed', call_id: `tools-${index}`, name: call[0], arguments: JSON.stringify(call[1])}]}));
        return;
      }
      if (scenario !== 'trajectory') {
        alternateRequests++;
        const index = alternateIndex++;
        if (scenario === 'disabled-offer') {
          assert(index <= 7);
          const reply = index === 7 ? {id: 'disabled-inspection', status: 'completed', error: null, output: [
            {type: 'function_call', status: 'completed', call_id: 'disabled-inspection', name: 'inspect', arguments: '{"evidence_index":0}'}]} : fixture[index];
          if (index === 7) assert(!body.tool_choice.tools.some(tool => tool.name === 'inspect'));
          response.writeHead(200, {'content-type': 'application/json'}); response.end(JSON.stringify(reply));
        } else { assert.equal(index, 0); announceAlternate(); } // Held until native cancellation closes the socket.
        return;
      }
      const index = requests.length;
      requests.push({bytes, body});
      assert(index < fixture.length); assert.equal(request.url, '/v1/responses'); assert.equal(request.headers.authorization, 'Bearer qualification-only');
      assert.equal(body.model, index >= 6 && index <= 8 ? 'fixture-model-b' : 'fixture-model-a');
      assert.equal(body.reasoning.effort, index >= 5 && index <= 8 ? 'high' : 'medium');
      assert.deepEqual(body.reasoning, {mode: 'standard', context: 'auto', effort: body.reasoning.effort});
      assert.equal(body.tools.length, 10); assert(!body.tools.some(tool => tool.name === 'inspect'));
      for (const key of ['store', 'stream', 'background', 'parallel_tool_calls']) assert.equal(body[key], false);
      assert.equal(body.truncation, 'disabled'); assert(!Object.hasOwn(body, 'previous_response_id') && !Object.hasOwn(body, 'conversation'));
      assert.equal(body.tool_choice.tools.some(tool => tool.name === 'inspect'), index >= 3 && index <= 6);
      if (index === 0) { announceHeld(); await release; }
      response.writeHead(200, {'content-type': 'application/json'}); response.end(JSON.stringify(fixture[index]));
    } catch (error) { providerFailure = error; response.writeHead(500); response.end('{}'); }
  });
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const profile = (id, model) => ({id, model, reasoning_mode: 'standard', reasoning_context: 'auto', efforts: ['medium', 'high'], effort_update: false,
    explicit_cache: true, additional_tools: true, cache_diagnostics: true, opaque_family: 'fixture', max_output_tokens: null,
    request_bytes: null, response_bytes: null, timeout_ms: null});
  const skills = [], skillBodies = [];
  for (const id of ['repository-orientation', 'invariant-review', 'technical-reporting']) {
    const resource = asset.resources.find(row => row.id === id), markdown = join(app.data, `${id}.md`);
    await writeFile(markdown, Buffer.from(resource.base64url, 'base64url'));
    skillBodies.push({id, body: Buffer.from(resource.base64url, 'base64url').toString('utf8')});
    skills.push({id, version: '1', description: id, markdown, tools: Array.from({length: 8}, (_value, index) => id === 'invariant-review' && index === 7)});
  }
  const config = {workspace: 'adaptive-controlled', snapshot_root: root, endpoint: `https://127.0.0.1:${server.address().port}/v1/responses`, audience: 'controlled-adaptive',
    profiles: [profile('analysis', 'fixture-model-a'), profile('deep', 'fixture-model-b')], initial_profile: 'analysis', initial_effort: 'medium', skills};
  const configuration = adaptive => ({schema: 'adaptive-agent.configuration.v3', adaptive, tools: null});
  await writeFile(configPath, JSON.stringify(configuration(config)));
  const invoke = (...args) => {
    const result = spawnSync(app.command, [...args, '--test-provider', '--trust-root', trust], {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024});
    assert.equal(result.status, 0, result.error ?? `${result.stderr}\n${result.stdout}`); return JSON.parse(result.stdout);
  };
  let client;
  const launch = async (extra, selectedState = state, versions = ['agent-host/2.1']) => {
    client = new ProteanClient(app.command, ['--state-dir', selectedState, '--authorize-inference', '--test-provider', '--trust-root', trust, ...extra], {cwd: app.data, env: {PATH: '/nonexistent'}});
    const initialized = await client.initialize(versions);
    assert.equal(initialized.server_info.version, '5.0.0');
    assert.equal(initialized.protocol_version, 'agent-host/2.1');
    assert.equal(Object.hasOwn(initialized.capabilities, 'task_reconciliation'), true);
    return client;
  };
  const artifact = async (taskId, ref) => {
    const id = typeof ref === 'string' ? ref.split(':')[0] : ref.artifact_id ?? Buffer.from(ref.digest).toString('hex');
    const expectedHash = ref.sha256 ?? id;
    const chunks = []; let offset = '0', done = false;
    while (!done) {
      const chunk = await client.call('artifact.read', {...(taskId === null ? {} : {task_id: taskId}), artifact_id: id, offset, length: '32768'});
      assert.equal(chunk.sha256, expectedHash); chunks.push(Buffer.from(chunk.data, 'base64url')); offset = chunk.next_offset; done = chunk.eof;
    }
    const bytes = Buffer.concat(chunks); assert.equal(hash(bytes), expectedHash);
    if (typeof ref !== 'string') assert.equal(BigInt(bytes.length), BigInt(ref.bytes));
    return bytes;
  };
  try {
    invoke('validate', '--config', configPath); assert.equal(requests.length, 0);
    const retiredConfig = join(app.data, 'retired-quota-contract.json');
    await writeFile(retiredConfig, JSON.stringify({...configuration(config), schema: 'adaptive-agent.configuration.v2'}));
    const retired = spawnSync(app.command, ['validate', '--config', retiredConfig, '--test-provider', '--trust-root', trust],
      {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 10000});
    assert.equal(retired.status, 64, 'old finite contracts require their original build');
    for (const [field, value] of [['id', 'review/guards'], ['version', '1.0.0+local']]) {
      const invalid = structuredClone(config), path = join(app.data, `invalid-skill-${field}.json`);
      invalid.skills[0][field] = value;
      await writeFile(path, JSON.stringify(configuration(invalid)));
      const rejected = spawnSync(app.command, ['validate', '--config', path, '--test-provider', '--trust-root', trust],
        {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 10000});
      assert.equal(rejected.status, 64, `${field}: ${rejected.error ?? rejected.stdout}`);
      assert.equal(requests.length, 0, 'invalid catalog admission cannot dispatch inference');
    }
    const credential = join(app.data, 'synthetic-private-credential'), leakedConfig = join(app.data, 'credential-profile.json');
    await writeFile(credential, 'qualification-only\n', {mode: 0o600});
    await writeFile(leakedConfig, JSON.stringify(configuration({...config, endpoint: 'https://api.openai.com/v1/responses', workspace: 'qualification-only'})));
    const leaked = spawnSync(app.command, ['validate', '--config', leakedConfig, '--credential-file', credential],
      {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 10000});
    assert.equal(leaked.status, 64); assert(!`${leaked.stdout}${leaked.stderr}`.includes('qualification-only'));
    assert.equal(requests.length, 0, 'credential validation cannot dispatch inference');
    await launch(['--config', configPath]);
    const description = await client.call('describe');
    const accepted = await client.call('task.submit', {client_operation_id: 'adaptive-controlled-submit', application_id: 'adaptive-agent', profile_id: description.profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Explain the fixture entry point using source evidence and exercise the approved adaptive controls.'}}});
    let timer;
    try { await Promise.race([held, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('provider hold timeout')), 15000); })]); }
    finally { clearTimeout(timer); }
    if (providerFailure) throw providerFailure;
    const pingStart = performance.now(); await client.call('ping', {}, 2000); const pingMs = performance.now() - pingStart;
    const statusStart = performance.now(); const heldStatus = await client.call('task.status', {task_id: accepted.task_id}, 2000); const statusMs = performance.now() - statusStart;
    assert.equal(heldStatus.profile_digest, accepted.profile_digest);
    const message = {client_operation_id: 'adaptive-held-followup', task_id: accepted.task_id,
      message: {schema_id: 'adaptive-agent.message.v2', value: {message: 'FOLLOWUP-A: distinguish observations from unrun checks.'}}};
    const queued = await client.call('task.message', message, 2000); assert.equal(queued.disposition, 'queued');
    assert.equal((await client.call('task.message', message, 2000)).receipt_id, queued.receipt_id);
    for (const [id, text] of [['two', 'FOLLOWUP-B: retain original source identity.'], ['three', 'FOLLOWUP-C: do not claim unrun checks.']]) {
      assert.equal((await client.call('task.message', {...message, client_operation_id: `adaptive-held-${id}`,
        message: {...message.message, value: {message: text}}}, 2000)).disposition, 'queued');
    }
    assert.equal(requests.length, 1); assert(!requests[0].bytes.includes('FOLLOWUP-A'));
    releaseHeld();
    const waiting = await until(() => client.call('task.status', {task_id: accepted.task_id}), value => value.question != null);
    if (providerFailure) throw providerFailure;
    assert.equal(requests.length, 13); assert(requests[1].bytes.includes('FOLLOWUP-A'));
    assert(requests[7].bytes.includes('OPAQUE-SKILL-CONTEXT-6'));
    assert(!requests[8].bytes.includes('OPAQUE-SKILL-CONTEXT-6'));
    assert(!requests[8].body.input.some(item => item.type === 'additional_tools' && item.tools.some(tool => tool.name === 'inspect')));
    assert.equal(waiting.profile_digest, accepted.profile_digest);
    const leftover = await client.call('task.message', {...message, client_operation_id: 'adaptive-after-restart',
      message: {...message.message, value: {message: 'FOLLOWUP-D: use the acquired source identity after restart.'}}});
    assert.equal(leftover.disposition, 'queued');
    await app.signal(client.child, 'SIGKILL'); await client.closed; client = null;
    await writeFile(join(root, 'src/main.zig'), 'changed after admission\n');
    const changedConfig = join(app.data, 'changed-adaptive.json');
    await writeFile(changedConfig, JSON.stringify(configuration({...config, initial_effort: 'high'})));
    const refused = spawnSync(app.command, ['resume', '--state-dir', state, '--task-id', accepted.task_id, '--config', changedConfig, '--test-provider', '--trust-root', trust],
      {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 10000});
    assert.equal(refused.status, 64); assert.equal(requests.length, 13);
    await launch(['--profile-task', accepted.task_id]);
    const reopenedDescription = await client.call('describe');
    assert.equal(reopenedDescription.profile.resource_identity, description.profile.resource_identity);
    const reopened = await client.call('task.status', {task_id: accepted.task_id});
    assert.deepEqual(reopened.question, waiting.question); assert.equal(requests.length, 13);
    await client.call('task.resume', {client_operation_id: 'adaptive-resume', task_id: accepted.task_id, expected_revision: reopened.revision});
    const answer = {client_operation_id: 'adaptive-answer', task_id: accepted.task_id,
      question_id: waiting.question.question_id, question_revision: waiting.question.question_revision, request_digest: waiting.question.request_digest,
      answer: {schema_id: waiting.question.answer_schema_id, value: {message: 'Focus on observable behavior.'}}};
    await assert.rejects(client.call('task.respond', {...answer, client_operation_id: 'adaptive-stale-answer', request_digest: '0'.repeat(64)}), error => error.data?.kind === 'StaleInteraction');
    const answered = await client.call('task.respond', answer);
    assert.equal((await client.call('task.respond', answer)).receipt_id, answered.receipt_id);
    const result = await until(() => client.call('task.result', {task_id: accepted.task_id}), value => value.ready);
    if (providerFailure) throw providerFailure;
    assert.equal(requests.length, 14); assert.equal(result.outcome.value.control.selection.control_revision, '8');
    assert.equal(result.outcome.value.control.eviction_generation, '2'); assert.equal(result.outcome.value.evidence[0].tag, 'source'); assert.equal(result.outcome.value.evidence[0].value.sha256, hash(Buffer.from(source)));
    assert.deepEqual(await client.close(), {code: 0, signal: null}); client = null;
    const archivePath = join(app.data, 'adaptive-complete.bundle');
    invoke('export-checkpoint', '--state-dir', state, '--task-id', accepted.task_id, '--output', archivePath);
    const archiveBytes = await readFile(archivePath), archive = readArchive(archiveBytes);
    const importedState = join(app.data, 'adaptive imported');
    const imported = invoke('import-checkpoint', '--state-dir', importedState, '--input', archivePath, '--operation-id', 'adaptive-import');
    assert.equal(imported.task_id, accepted.task_id);
    assert.deepEqual(invoke('result', '--state-dir', importedState, '--task-id', accepted.task_id).outcome.value, result.outcome.value);
    const schemas = Object.fromEntries(['AdaptivePrepared', 'CapturedResponse', 'AdaptiveResult', 'AdaptiveContext', 'HistoryChunk', 'PreparationProduct', 'PreparationCapture', 'PreparationResult', 'WorkReply', 'WorkArtifact']
      .map(name => [name, contract(asset, name)]));
    assert.equal(archive.task.resources.length, skillBodies.length + 2);
    for (const [index, skill] of skillBodies.entries()) assert.equal(archive.object(archive.task.resources[index + 1]).toString('utf8'), skill.body);
    const messageStates = archive.manifest[6].filter(([kind]) => kind === 2).map(([, , ref]) => decodeValue(archive.schemas.get('message'), archive.object(ref))[5]);
    assert.equal(messageStates.filter(state => state === 2).length, 4, 'all four follow-ups are consumed once, in addition to the clarification answer');
    assert(requests[13].bytes.includes('FOLLOWUP-D'));
    assert.equal(messageStates.filter(state => state === 3).length, 0, 'the former answer-plus-followup quota does not abandon queued input');
    let providerProjections = 0, controlProjections = 0, workProjections = 0, readEvidence = 0;
    const captureRows = [], toolNames = ['list', 'read', 'ask', 'report', 'stop', 'inference_set', 'skill_set', 'inspect'];
    const revisions = [0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 7, 8, 8];
    const epochs = [0, 0, 0, 0, 0, 1, 2, 2, 3, 4, 4, 4, 5, 5];
    const eviction = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2];
    const seen = new Set();
    const frozenProfileBytes = archive.object(archive.task.profile), frozenProfile = JSON.parse(frozenProfileBytes.toString('utf8'));
    for (const [kind, id, ref] of archive.manifest[6]) {
      if (kind !== 4) continue;
      const capture = decodeValue(archive.schemas.get('capture'), archive.object(ref));
      const attemptRow = archive.manifest[6].find(([tag, candidate]) => tag === 5 && Buffer.from(candidate).equals(Buffer.from(id)));
      const attempt = decodeValue(archive.schemas.get('attempt'), archive.object(attemptRow[2]));
      const identity = attempt[5], prepared = archive.object(capture[3]), rawBytes = archive.object(capture[4].value);
      const replyBytes = resultValue(archive.object(capture[6].value[0]));
      assert.equal(capture[5], 0); assert.equal(capture[6].tag, 1);
      if (identity === 'agent.model.invoke.v11') {
        const envelope = decodeValue(schemas.AdaptivePrepared, prepared);
        assert.equal(envelope.length, 3); assert.equal(envelope[0], 1);
        const request = envelope[1], plan = request[3], index = Number(plan[2]);
        assert.equal(request.length, 7); assert.equal(plan.length, 8); assert(index >= 0 && index < 14 && !seen.has(index)); seen.add(index);
        assert.equal(Buffer.from(request[1]).toString('hex'), hash(frozenProfileBytes));
        const requestBytes = Buffer.from(envelope[2]), raw = decodeValue(schemas.CapturedResponse, rawBytes);
        assert(requestBytes.equals(requests[index].bytes), 'immutable preparation equals observed HTTPS bytes');
        assert.equal(raw[0], 200); assert.equal(raw[1], true); assert.equal(raw[2].tag, 0);
        const responseBytes = Buffer.from(raw[3]);
        assert(responseBytes.equals(Buffer.from(JSON.stringify(fixture[index]))), 'raw capture equals independent provider fixture');
        assert.equal(request[2][3], BigInt(revisions[index])); assert.equal(plan[0], BigInt(epochs[index])); assert.equal(plan[3], BigInt(eviction[index]));
        assert.equal(request[2][0], index >= 6 && index <= 8 ? 'deep' : 'analysis');
        assert.equal(request[2][2], index >= 5 && index <= 8 ? 4 : 3);
        assert.equal(request[4][7], index >= 3 && index <= 7, 'deactivated skill remains materialized until unload');
        assert.equal(request[5][7], index >= 3 && index <= 6, 'deactivation removes callable permission');
        assert.equal(request[5][2], true, 'clarification remains offered after all accepted inputs');
        const expectedSkills = index >= 3 && index <= 7 ? ['invariant-review'] : index === 10 || index === 11 ? ['technical-reporting'] : [];
        assert.deepEqual(plan[6].map(skill => skill[1]), expectedSkills);
        const reply = decodeValue(schemas.AdaptiveResult, replyBytes);
        assert.equal(reply[0].tag, 0); assert.equal(reply[1].tag, 1); assert.equal(reply[2], 0); assert.equal(reply[3].tag, 0);
        const call = reply[0].value[0].find(item => item.tag === 0).value;
        const expectedCall = fixture[index].output.find(item => item.type === 'function_call');
        assert.deepEqual(call.slice(0, 2), [expectedCall.call_id, expectedCall.name]);
        assert(Buffer.from(call[2]).equals(Buffer.from(expectedCall.arguments)), 'argument JSON bytes are preserved exactly');
        assert.equal(call[3], toolNames.indexOf(expectedCall.name));
        const context = decodeValue(schemas.AdaptiveContext, archive.object(reply[1].value[0]));
        assert.equal(context.length, 13); assert.deepEqual(context[2], archive.task.id);
        assert.equal(context[0], 'agent.model.context.responses.adaptive.v7'); assert.deepEqual(context[1], request[1]);
        assert.equal(context[3], archive.task.tenant); assert.equal(context[4], frozenProfile.adaptive.audience);
        assert.equal(context[6], request[2][2]);
        assert.deepEqual(context[5], request[2]); assert.deepEqual(context[7], plan); assert.equal(context[8], BigInt(index + 1));
        assert.deepEqual(context[9], reference(rawBytes)); assert.deepEqual(context[10], reference(prepared));
        assert.deepEqual(context[11], {tag: 1, value: fixture[index].id});
        const transientBodies = plan[6].filter(skill => skill[3] === 1 && skill[4]).map(skill => skillBodies.find(body => body.id === skill[1]).body);
        const chunks = [], visitedChunks = new Set();
        let history = context[12];
        const eventCount = history.tag === 1 ? history.value[1] : 0n;
        while (history.tag === 1) {
          const [ref, count] = history.value, identity = Buffer.from(ref[0]).toString('hex');
          assert(!visitedChunks.has(identity), 'history chain is acyclic'); visitedChunks.add(identity);
          const chunk = decodeValue(schemas.HistoryChunk, archive.object(ref));
          assert.equal(chunk[0], 'agent.model.context.history.chunk.v1');
          assert(chunk[3].length > 0); assert.equal(chunk[2] + BigInt(chunk[3].length), count);
          assert.equal(chunk[2], chunk[1].tag === 1 ? chunk[1].value[1] : 0n);
          if (chunk[1].tag === 1) assert(chunk[1].value[1] < count);
          chunks.push(chunk[3]); history = chunk[1];
        }
        const events = chunks.reverse().flat();
        assert.equal(BigInt(events.length), eventCount);
        assert(events.every(([, origin]) => origin[0] <= plan[2]), 'history origins cannot claim future exposure');
        const committedInput = requests[index].body.input.filter(item => !(item.role === 'developer' && item.content?.length === 1 && transientBodies.includes(item.content[0]?.text)));
        assert.deepEqual(events.map(([item]) => JSON.parse(Buffer.from(item).toString('utf8'))), [...committedInput, ...fixture[index].output], 'ordered replay appends original output without retaining transient injection');
        captureRows.push({request, http: requests[index].body});
        providerProjections++;
      } else {
        if (identity === 'agent.adaptive.context.prepare.v2') {
          const observation = decodeValue(schemas.PreparationCapture, rawBytes);
          assert.equal(Buffer.from(observation[0]).toString('hex'), hash(prepared));
          assert.equal(observation.length, 1, 'preparation captures no quota-exhaustion policy');
          const product = decodeValue(schemas.PreparationProduct, prepared);
          assert(Buffer.from(encodeValue(schemas.PreparationResult, product[0])).equals(replyBytes));
          assert.deepEqual((product[1].tag === 1 ? [reference(Buffer.from(product[1].value))] : []), capture[6].value[1]);
          controlProjections++;
        } else {
          assert(prepared.equals(rawBytes), 'deterministic work retained its original prepared capture');
          assert(['agent.adaptive.snapshot.work.v2', 'agent.adaptive.snapshot.guards.v2'].includes(identity));
          const work = decodeValue(schemas.WorkArtifact, rawBytes), reply = decodeValue(schemas.WorkReply, replyBytes);
          assert.deepEqual(reply[0], reference(rawBytes)); assert.deepEqual(capture[6].value[1], [reference(rawBytes)]);
          assert.deepEqual(work[1], archive.task.id);
          if (work[7].tag === 1) { readEvidence++; assert.equal(work[7].value[6], source); assert.equal(work[7].value[2], hash(Buffer.from(source))); }
          workProjections++;
        }
      }
    }
    assert.equal(providerProjections, 14); assert.equal(controlProjections, 22); assert.equal(workProjections, 4); assert.equal(readEvidence, 1);
    for (const [name, bytes] of [
      ['missing-capture', missingCaptures(archiveBytes, 'one')], ['tampered-control', tamperedAdaptiveControl(archiveBytes, schemas.CapturedResponse)],
      ['missing-checkpoint', missingCheckpoint(archiveBytes)], ['changed-profile', changedProfile(archiveBytes)],
      ['private-checkpoint', extraPrivateArtifact(archiveBytes)], ['private-capture', extraPrivateArtifact(archiveBytes, 'capture')],
      ['omitted-attempts', omittedAttempts(archiveBytes)], ['changed-operation', changedOperationKey(archiveBytes)],
      ['omitted-submission', changedOperationKey(archiveBytes, 'omitted')], ['invalid-event', invalidEventData(archiveBytes, 'null')],
    ]) {
      const path = join(app.data, `${name}.bundle`); await writeFile(path, bytes, {mode: 0o600});
      const rejected = spawnSync(app.command, ['import-checkpoint', '--state-dir', join(app.data, `${name}-state`), '--input', path, '--operation-id', name,
        '--test-provider', '--trust-root', trust], {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024});
      assert.equal(rejected.status, 64, name);
    }
    assert.equal(requests.length, 14, 'recovery, import and pure projection replay perform no inference');
    // A well-typed call can still be forbidden by the original offered set.
    selectScenario('disabled-offer');
    const deniedState = join(app.data, 'disabled offer');
    await launch(['--config', configPath], deniedState);
    const deniedProfile = (await client.call('describe')).profile;
    const deniedTask = await client.call('task.submit', {client_operation_id: 'disabled-offer-submit', application_id: 'adaptive-agent', profile_id: deniedProfile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Reject inspection after its skill is deactivated.'}}});
    const deniedResult = await until(() => client.call('task.result', {task_id: deniedTask.task_id}), value => value.ready);
    if (providerFailure) throw providerFailure;
    assert.equal(alternateIndex, 8); assert.equal(deniedResult.outcome.value.result.tag, 'no_result');
    assert.equal(deniedResult.outcome.value.model_calls, '8'); assert.equal(deniedResult.outcome.value.work_calls, '3');
    assert.equal(deniedResult.outcome.value.control.skills[0].active, false);
    assert.deepEqual(await client.close(), {code: 0, signal: null}); client = null;
    const deniedPath = join(app.data, 'disabled-offer.bundle');
    invoke('export-checkpoint', '--state-dir', deniedState, '--task-id', deniedTask.task_id, '--output', deniedPath);
    const deniedArchive = readArchive(await readFile(deniedPath));
    let offeredWitness = false;
    for (const [kind, id, ref] of deniedArchive.manifest[6]) {
      if (kind !== 4) continue;
      const attemptRow = deniedArchive.manifest[6].find(([tag, candidate]) => tag === 5 && Buffer.from(candidate).equals(Buffer.from(id)));
      const attempt = decodeValue(deniedArchive.schemas.get('attempt'), deniedArchive.object(attemptRow[2]));
      if (attempt[5] !== 'agent.model.invoke.v11') continue;
      const capture = decodeValue(deniedArchive.schemas.get('capture'), deniedArchive.object(ref));
      const request = decodeValue(schemas.AdaptivePrepared, deniedArchive.object(capture[3]))[1];
      if (request[3][2] !== 7n) continue;
      assert.equal(request[4][7], true); assert.equal(request[5][7], false);
      const reply = decodeValue(schemas.AdaptiveResult, resultValue(deniedArchive.object(capture[6].value[0])));
      assert.equal(reply[0].tag, 0);
      const call = reply[0].value[0].find(item => item.tag === 0).value;
      assert.equal(call[1], 'inspect'); assert.equal(call[4].tag, 0, 'typed action was decoded before the checked responder rejected its offer');
      offeredWitness = true;
    }
    assert(offeredWitness);

    const cancellations = [];
    for (const method of ['protocol', 'SIGINT', 'SIGTERM']) {
      const heldRequest = selectScenario(method), selectedState = join(app.data, `cancel-${method}`);
      await launch(['--config', configPath], selectedState);
      const profile = (await client.call('describe')).profile;
      const submission = {client_operation_id: 'native-interrupt-submit', application_id: 'adaptive-agent', profile_id: profile.id,
        input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Cancel the held native adaptive inference.'}}};
      const task = await client.call('task.submit', submission);
      await within(heldRequest, 15000, 'native cancellation request not received');
      await client.call('task.message', {client_operation_id: 'cli-interrupt', task_id: task.task_id,
        message: {schema_id: 'adaptive-agent.message.v2', value: {message: 'This valid caller ID must not prevent native interruption.'}}});
      const cancelParams = {client_operation_id: 'native-cancel-once', task_id: task.task_id};
      let cancellation;
      const stopStarted = performance.now();
      if (method === 'protocol') {
        cancellation = await client.call('task.cancel', cancelParams, 2000);
        assert.equal(cancellation.disposition, 'cancellation_requested');
        await until(() => client.call('task.status', {task_id: task.task_id}), value => value.status === 'unknown');
        assert.deepEqual(await within(client.close(), 3000, 'native cancellation close timeout'), {code: 2, signal: null});
      } else {
        await app.signal(client.child, method);
        assert.deepEqual(await within(client.closed, 3000, 'native signal did not stop held inference'), {code: 2, signal: null});
      }
      client = null;
      const milliseconds = performance.now() - stopStarted;
      await launch(['--config', configPath], selectedState, ['agent-host/2.1']);
      const unknown = await client.call('task.status', {task_id: task.task_id});
      assert.equal(unknown.status, 'unknown'); assert.notEqual(unknown.cancellation, null);
      assert.equal((await client.call('task.submit', submission)).task_id, task.task_id);
      if (cancellation) assert.equal((await client.call('task.cancel', cancelParams)).receipt_id, cancellation.receipt_id);
      await assert.rejects(client.call('task.resume', {client_operation_id: 'no-unknown-retry', task_id: task.task_id, expected_revision: unknown.revision}), error => error.data?.kind === 'StateConflict');
      assert.deepEqual(unknown.recovery.mechanisms, [], 'provider has no authoritative receipt retrieval');
      assert.match(unknown.recovery.occurrence_id, /^[0-9a-f]{64}$/);
      assert.match(unknown.recovery.attempt_id, /^[0-9a-f]{64}$/);
      const description = await client.call('describe');
      assert(description.methods.some(method => method.name === 'task.reconcile'));
      const schemas = description.protocol_schema ?? JSON.parse((await artifact(null, description.protocol_schema_ref)).toString('utf8'));
      assert.equal(schemas.$defs['initialize.result'].properties.protocol_version.const, 'agent-host/2.1');
      assert.equal(schemas.$defs['task.reconcile.params'].additionalProperties, false);
      assert.deepEqual(schemas.$defs['task.reconcile.params'].properties.recovery.required, ['mechanism']);
      const recovery = {client_operation_id: 'recover-provider-once', task_id: task.task_id, expected_revision: unknown.revision,
        occurrence_id: unknown.recovery.occurrence_id, attempt_id: unknown.recovery.attempt_id, recovery: {mechanism: 'rederive'}};
      await assert.rejects(client.call('task.reconcile', {...recovery, recovery: {mechanism: 'rederive', safe_to_retry: true}}), error => error.data?.kind === 'InvalidParams');
      const admitted = await client.call('task.reconcile', recovery);
      assert.equal(admitted.status, 'unknown'); assert.equal(admitted.replayed, false);
      assert.equal(admitted.reconciliation.status, 'unresolved');
      assert.equal(admitted.reconciliation.reason, 'unsupported');
      assert.equal(admitted.reconciliation.provenance, 'none');
      assert.deepEqual(Object.keys(admitted.reconciliation).sort(), ['attempt_id', 'mechanism', 'mechanism_version', 'occurrence_id', 'provenance', 'reason', 'reconciliation_id', 'status']);
      const replay = await client.call('task.reconcile', recovery);
      assert.equal(replay.receipt_id, admitted.receipt_id); assert.equal(replay.replayed, true);
      await assert.rejects(client.call('task.reconcile', {...recovery, expected_revision: admitted.revision}), error => error.data?.kind === 'OperationConflict');
      const events = await client.call('task.events', {task_id: task.task_id, after_seq: unknown.high_water_seq});
      assert(events.events.some(event => event.type === 'reconciled' && event.data.reconciliation_id === admitted.reconciliation.reconciliation_id));

      assert.equal(alternateIndex, 1, 'unknown adaptive delivery cannot be retried');
      assert.deepEqual(await client.close(), {code: 0, signal: null}); client = null;
      cancellations.push({method, milliseconds, provider_requests: alternateIndex, recovered_status: unknown.status});
    }
    const row = (id, key, value, group) => Object.fromEntries(Object.entries({id, key, value, group}).map(([name, value]) => [name, String(value)]));
    const relation = [row(11, 10, 100, 1), row(12, 20, 201, 1), row(13, 40, 400, 2), row(14, 40, 401, 2), row(15, 90, 1, 3), row(16, 91, 1, 3), row(17, 92, 1, 4)];
    const inputs = [
      {id: 'first', description: 'Selected lock scope against source records, including agreement, mismatch, missing and ambiguity.', rows: [row(1, 10, 100, 1), row(2, 20, 200, 1), row(3, 30, 300, 2), row(4, 40, 400, 2), row(5, 50, 500, 3)], relation, selected: ['10', '20', '30', '40']},
      {id: 'second', description: 'Changed lock scope and value: row 80 now agrees with key 20.', rows: [row(80, 20, 201, 9)], relation, selected: ['20']},
    ];
    const coverageRecipe = linkRecipe([['filter', 'selected'], ['map', 'join'], ['map', 'classify']]);
    const reverseRecipe = linkRecipe([['filter', 'selected'], ['swap'], ['map', 'join'], ['filter', 'orphan'], ['group']]);
    let retainedProgram, retainedState;
    const toolRuns = [];
    for (const name of ['tools-reuse', 'tools-reverse', 'tools-disabled', 'tools-foreign']) {
      scenario = name; alternateIndex = 0;
      toolSubject = {recipe: name === 'tools-reverse' ? reverseRecipe : coverageRecipe, foreign: retainedProgram};
      let selectedState = name === 'tools-foreign' ? retainedState : join(app.data, name);
      const selectedConfig = join(app.data, `${name}.json`);
      await writeFile(selectedConfig, JSON.stringify({schema: 'adaptive-agent.configuration.v3', adaptive: {...config, skills: name === 'tools-reuse' ? config.skills.filter(skill => ['invariant-review', 'repository-orientation'].includes(skill.id)) : []}, tools: {build: !['tools-foreign', 'tools-disabled'].includes(name), run: true, inputs}}));
      await launch(['--config', selectedConfig], selectedState);
      const description = await client.call('describe');
      const task = await client.call('task.submit', {client_operation_id: name, application_id: 'adaptive-agent', profile_id: description.profile.id,
        input: {schema_id: 'adaptive-agent.input.v2', value: {task: name === 'tools-reverse' ? 'Group source records unsupported by the selected lock scope.' : 'Audit selected lock records against source records, retaining all classifications and reuse the tool on the second input.'}}});
      if (name === 'tools-reuse') {
        const waiting = await until(async () => {
          const value = await client.call('task.status', {task_id: task.task_id});
          if (value.status === 'completed' || value.status === 'failed') assert.fail(`${name}: ${JSON.stringify(await client.call('task.result', {task_id: task.task_id}))}`);
          return value;
        }, value => value.question != null, 2000);
        if (providerFailure) throw providerFailure;
        assert.equal(alternateIndex, toolSubject.heldIndex);
        await app.signal(client.child, 'SIGKILL'); await client.closed; client = null;
        const bundle = join(app.data, 'constructed-tool.bundle');
        invoke('export-checkpoint', '--state-dir', selectedState, '--task-id', task.task_id, '--output', bundle);
        selectedState = join(app.data, 'constructed tool imported');
        assert.equal(invoke('import-checkpoint', '--state-dir', selectedState, '--input', bundle, '--operation-id', 'constructed-import').task_id, task.task_id);
        await launch(['--profile-task', task.task_id], selectedState);
        const reopened = await client.call('task.status', {task_id: task.task_id});
        assert.deepEqual(reopened.question, waiting.question); assert.equal(alternateIndex, toolSubject.heldIndex);
        const exported = readArchive(await readFile(bundle));
        const savedProgram = exported.manifest[6].filter(([kind]) => kind === 8).map(([, , ref]) => decodeValue(exported.schemas.get('workspace_program'), exported.object(ref))).find(record => Buffer.from(record[2][0]).toString('hex') === toolSubject.program.id);
        assert(savedProgram, 'the exact task-owned program survives export');
        assert.equal(exported.object(savedProgram[3][5]).subarray(0, 8).toString(), 'ABL_BPI3');

        const attempts = exported.manifest[6].filter(([kind]) => kind === 5).map(([, , ref]) => decodeValue(exported.schemas.get('attempt'), exported.object(ref))[5]);
        assert.equal(attempts.filter(identity => identity === 'agent.adaptive.workspace.v1').length, 4);
        assert.equal(attempts.filter(identity => identity === 'agent.adaptive.snapshot.guards.v2').length, 1, 'generated-evidence rejection never dispatches source inspection');
        let privateChecks = 0;
        for (const [kind, id, ref] of exported.manifest[6]) {
          if (kind !== 4) continue;
          const row = exported.manifest[6].find(([kind, candidate]) => kind === 5 && Buffer.from(candidate).equals(Buffer.from(id)));
          const attempt = decodeValue(exported.schemas.get('attempt'), exported.object(row[2]));
          if (attempt[5] !== 'agent.model.invoke.v11') continue;
          const capture = decodeValue(exported.schemas.get('capture'), exported.object(ref));
          for (const privateRef of [capture[4].value, ...capture[6].value[1]]) {
            await assert.rejects(client.call('artifact.read', {task_id: task.task_id, artifact_id: Buffer.from(privateRef[0]).toString('hex'), offset: '0', length: '1'}), error => error.data?.kind === 'ArtifactUnavailable');
            privateChecks++;
          }
          break;
        }
        assert(privateChecks >= 2, 'raw capture and private projection remain unreadable');
        await client.call('task.resume', {client_operation_id: 'constructed-resume', task_id: task.task_id, expected_revision: reopened.revision});
        await client.call('task.respond', {client_operation_id: 'constructed-answer', task_id: task.task_id, question_id: waiting.question.question_id,
          question_revision: waiting.question.question_revision, request_digest: waiting.question.request_digest,
          answer: {schema_id: waiting.question.answer_schema_id, value: {message: 'Continue on the second admitted input with the same generated program.'}}});
      }
      const result = await until(() => client.call('task.result', {task_id: task.task_id}), value => value.ready, 2000);
      if (providerFailure) throw providerFailure;
      if (result.outcome.value_ref) {
        assert.equal(result.outcome.value_ref.schema_id, 'adaptive-agent.output.v5');
        result.outcome.value = JSON.parse((await artifact(task.task_id, result.outcome.value_ref)).toString('utf8'));
      }
      if (name === 'tools-reuse' || name === 'tools-reverse') {
        assert.equal(result.outcome.value.result.tag, 'report');
        assert.equal(result.outcome.value.programs.length, 1);
        assert.deepEqual(result.outcome.value.programs[0], toolSubject.program);
        assert.equal(result.outcome.value.evidence[0].tag, 'workspace', 'the configured input retains acquisition provenance');
        for (const [n, index] of toolSubject.resultIndices.entries()) {
          assert.equal(result.outcome.value.evidence[index].tag, 'workspace');
          assert.deepEqual(result.outcome.value.evidence[index].value, toolSubject.results[n]);
        }
      } else {
        assert.equal(result.outcome.value.result.tag, 'no_result');
        assert.equal(result.outcome.value.programs.length, 0);
        assert.equal(result.outcome.value.work_calls, name === 'tools-disabled' ? '1' : '2');
      }
      if (name === 'tools-reuse') {
        retainedProgram = toolSubject.program; retainedState = selectedState;
        assert(alternateIndex > 38, 'materialization, retained work and the original long control trace all ran');
        assert.equal(result.outcome.value.model_calls, String(alternateIndex));
        assert.equal(result.outcome.value.evidence.length, 15, 'twelve results, two inputs, and the source remain retained');
        assert.deepEqual(result.outcome.value.result.value.claims[0].evidence_indices, [String(toolSubject.sourceIndex), String(toolSubject.resultIndices.at(-1))]);
        assert.equal(result.outcome.value.evidence[toolSubject.sourceIndex].tag, 'source');
        assert.equal(result.outcome.value.control.selection.control_revision, '17');
        assert.equal(result.outcome.value.control.skills.length, 0);
      }
      toolRuns.push({scenario: name, provider_calls: alternateIndex, disposition: result.outcome.value.result.tag});
      assert.deepEqual(await client.close(), {code: 0, signal: null}); client = null;
      if (name === 'tools-reuse') {
        const measured = join(app.data, 'workspace-accounting.bundle');
        const exportStarted = performance.now();
        invoke('export-checkpoint', '--state-dir', selectedState, '--task-id', task.task_id, '--output', measured);
        toolRuns.at(-1).archive_export_ms = performance.now() - exportStarted;
        const metrics = workspaceMetrics(readArchive(await readFile(measured)), JSON.parse(await readFile(applicationPath, 'utf8')));
        assert.equal(metrics.controller.calls, alternateIndex);
        assert.equal(metrics.delegated.calls, 0);
        assert.equal(metrics.work_items, 12);
        assert(metrics.builds >= 1 && metrics.compiler_nanoseconds > 0 && metrics.native_publication_nanoseconds > 0);
        assert(metrics.checkpoint_publications >= 12 && metrics.current_checkpoint_bytes > 0);
        assert.equal(metrics.actions.filter(action => action.name === 'program' && action.arguments.command.tag === 'build').length, 4);
      }
    }
    assertAdaptiveCaptures(captureRows, skillBodies);
    console.log(JSON.stringify({adaptive_native: 'controlled HTTPS, held inbox, frozen policy, killed question, archive and independent captured-record checks',
      model_attempts: requests.length, request_bytes: requests.map(item => item.bytes.length),
      held_ping_ms: pingMs, held_status_ms: statusMs, archive_bytes: archiveBytes.length,
      independent_negative_provider_requests: alternateRequests,
      provider_projections: providerProjections, context_projections: controlProjections, work_projections: workProjections,
      consumed_messages: 4, not_consumed_messages: 0, disabled_offer_rejected: offeredWitness, cancellations, tool_construction: toolRuns,
      live_provider: false}));
  } catch (error) {
    throw providerFailure ?? error;
  } finally {
    releaseHeld(); if (client) { client.child.kill('SIGKILL'); await client.closed; }
    for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve));
  }
}
