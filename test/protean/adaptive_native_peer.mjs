// External fixture controller for the copied native Kronos host. Fixture indexes
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
      assert.equal(request.url, '/v1/responses'); assert.equal(request.headers.authorization, 'Bearer qualification-only');
      if (scenario.startsWith('tools-')) {
        const index = alternateIndex++, subject = toolSubject;
        const offered = new Set(body.tool_choice.tools.map(tool => tool.name));
        const outputText = call => {
          const item = body.input.find(item => item.type === 'function_call_output' && item.call_id === `tools-${call}`);
          assert(item, `missing acquired tool output ${call}`);
          if (typeof item.output === 'string') return item.output;
          assert(Array.isArray(item.output) && item.output.length === 1);
          assert.equal(item.output[0].type, 'input_text');
          return item.output[0].text;
        };
        const output = call => JSON.parse(outputText(call));
        const skill = (operation, revision, skill_id = 'tool-construction') => ['skill_set', {operation, skill_id, version: '1', residency: operation === 'load' ? 'resident' : 'unchanged', expected_revision: revision, reason: 'Exercise checked composition and independent execution authority.'}];
        if (index === 1 && (scenario === 'tools-reuse' || scenario === 'tools-reverse')) {
          const marker = 'Recipe JSON schema:\n', text = strings(body.input).find(text => text.includes(marker));
          assert(text, 'loading construction exposes the nested recipe contract to the model');
          const recipe = JSON.parse(text.slice(text.indexOf(marker) + marker.length).split('\n')[0]);
          assert.deepEqual(recipe.required, ['instances', 'bindings', 'entry']);
          assert.equal(recipe.additionalProperties, false);
          assert.equal(recipe.properties.instances.maxItems, 16);
          assert.deepEqual(recipe.properties.instances.items.required, ['key', 'component_id']);
          assert.equal(recipe.properties.instances.items.properties.key.maxLength, 64);
          assert.equal(recipe.properties.bindings.maxItems, 64);
          assert.deepEqual(recipe.properties.bindings.items.required, ['required', 'supplied']);
          assert.deepEqual(recipe.properties.bindings.items.properties.required.required, ['instance', 'symbol']);
          assert.deepEqual(recipe.properties.entry.required, ['instance', 'symbol']);
          assert.match(text, /proposal_json \(at most 2700 UTF-8 bytes\)/);
        }
        if (index === 0) {
          assert(!offered.has('tool_build')); assert(offered.has('tool_run'));
          const marker = 'Authorized typed Table inputs: ', text = strings(body.input).find(text => text.includes(marker));
          assert(text); subject.inputs = JSON.parse(text.slice(text.indexOf(marker) + marker.length));
          assert.equal(subject.inputs.length, 2);
        }
        let call;
        if (scenario === 'tools-disabled') {
          call = index === 0 ? skill('load', 0) : index === 1 ? skill('unload', 1) : ['tool_build', {proposal_json: JSON.stringify(subject.recipe)}];
          assert(index <= 2); if (index === 2) assert(!offered.has('tool_build'));
        } else if (scenario === 'tools-foreign') {
          call = index === 0 ? ['tool_run', {tool_ref: subject.foreign, input_ref: subject.inputs[0].input_ref}] : ['stop', {reason: 'The foreign task reference was not admitted.'}];
          assert(index <= 1);
          if (index === 1) { const result = output(0); assert.equal(result.disposition, 'rejected'); assert.equal(result.reason, 'UnauthorizedProgram'); }
        } else if (scenario === 'tools-reverse') {
          if (index === 0) call = skill('load', 0);
          if (index === 1) call = ['tool_build', {proposal_json: JSON.stringify(subject.recipe)}];
          if (index === 2) { const built = output(1); assert.equal(built.disposition, 'structurally_admitted', JSON.stringify(built)); subject.program = built.tool_ref; call = ['tool_run', {tool_ref: subject.program, input_ref: subject.inputs[0].input_ref}]; }
          if (index === 3) { const result = output(2); assert.equal(result.disposition, 'completed', JSON.stringify(result)); assert.deepEqual(result.value.rows.map(row => [row.group, row.value]), [['3', '2'], ['4', '1']]); call = ['report', {summary: 'Three unsupported source records, grouped into counts two and one.', evidence_index: 0}]; }
          assert(index <= 3);
        } else {
          if (index === 0) call = skill('load', 0);
          if (index >= 1 && index <= 3) {
            assert(offered.has('tool_build'));
            if (index > 1) assert.equal(output(index - 1).disposition, 'rejected');
            call = ['tool_build', {proposal_json: JSON.stringify({...subject.recipe, unapproved_policy: index})}];
          }
          if (index === 4) { assert.equal(output(3).disposition, 'rejected'); assert(offered.has('tool_build')); call = ['tool_build', {proposal_json: JSON.stringify(subject.recipe)}]; }
          if (index === 5) {
            const built = output(4); assert.equal(built.disposition, 'structurally_admitted', JSON.stringify(built)); subject.program = built.tool_ref;
            assert(!offered.has('tool_build'), 'four physical construction attempts exhaust the offered allowance');
            assert(offered.has('tool_run')); call = ['tool_run', {tool_ref: subject.program, input_ref: subject.inputs[0].input_ref}];
          }
          if (index === 6) { const result = output(5); assert.equal(result.disposition, 'completed', JSON.stringify(result)); assert.deepEqual(result.value.rows.map(row => [row.id, row.status]), [['1', '1'], ['2', '2'], ['3', '3'], ['4', '4']]); call = skill('load', 1, 'invariant-review'); }
          if (index === 7) { assert(!offered.has('inspect'), 'generated-only evidence is not a source inspection target'); call = ['read', {path: 'src/main.zig', start: 0, maximum: 4096}]; }
          if (index === 8) { assert(offered.has('inspect')); call = ['inspect', {evidence_index: 0}]; }
          if (index === 9) { assert.match(outputText(8), /source-file evidence/); call = ['inspect', {evidence_index: 1}]; }
          if (index === 10) { assert.match(outputText(9), /Observed 0 lines.*evidence 1/); call = skill('unload', 2, 'invariant-review'); }
          if (index === 11) call = ['ask', {question: 'The first audit and source inspection are acquired. Continue on the second input?'}];
          if (index === 12) { assert(!offered.has('tool_build'), 'exhausted construction remains unavailable after restart/import while its skill is active'); call = skill('deactivate', 3); }
          if (index === 13) call = skill('unload', 4);
          if (index === 14) {
            assert(!offered.has('tool_build')); assert(offered.has('tool_run'));
            assert(strings(body.input).some(text => text.includes('Retained generated tool references') && text.includes(subject.program)));
            call = ['tool_run', {tool_ref: subject.program, input_ref: subject.inputs[1].input_ref}];
          }
          if (index === 15) { const result = output(14); assert.equal(result.disposition, 'completed', JSON.stringify(result)); assert.equal(result.tool_ref, subject.program); assert.deepEqual(result.value.rows.map(row => [row.id, row.status]), [['80', '1']]); call = ['report', {summary: 'The same admitted program found agreement on the changed second input.', evidence_index: 2}]; }
          assert(index <= 15);
        }
        assert(call);
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
      assert.equal(body.tools.length, 7); assert(!body.tools.some(tool => tool.name === 'inspect'));
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
    explicit_cache: true, additional_tools: true, cache_diagnostics: true, opaque_family: 'fixture', max_output_tokens: 4096,
    request_bytes: 256 * 1024, response_bytes: 512 * 1024, timeout_ms: 10000});
  const skills = [], skillBodies = [];
  for (const id of ['repository-orientation', 'invariant-review', 'technical-reporting']) {
    const resource = asset.resources.find(row => row.id === id), markdown = join(app.data, `${id}.md`);
    await writeFile(markdown, Buffer.from(resource.base64url, 'base64url'));
    skillBodies.push({id, body: Buffer.from(resource.base64url, 'base64url').toString('utf8')});
    skills.push({id, version: '1', description: id, markdown, tools: Array.from({length: 8}, (_value, index) => id === 'invariant-review' && index === 7)});
  }
  const config = {workspace: 'adaptive-controlled', snapshot_root: root, endpoint: `https://127.0.0.1:${server.address().port}/v1/responses`, audience: 'controlled-adaptive',
    profiles: [profile('analysis', 'fixture-model-a'), profile('deep', 'fixture-model-b')], initial_profile: 'analysis', initial_effort: 'medium', skills,
    maximum_model_calls: 16, maximum_control_revision: 16};
  await writeFile(configPath, JSON.stringify(config));
  const invoke = (...args) => {
    const result = spawnSync(app.command, [...args, '--test-provider', '--trust-root', trust], {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024});
    assert.equal(result.status, 0, result.error ?? `${result.stderr}\n${result.stdout}`); return JSON.parse(result.stdout);
  };
  let client;
  const launch = async (extra, selectedState = state) => {
    client = new ProteanClient(app.command, ['--state-dir', selectedState, '--authorize-inference', '--test-provider', '--trust-root', trust, ...extra], {cwd: app.data, env: {PATH: '/nonexistent'}});
    await client.initialize(); return client;
  };
  const artifact = async (taskId, ref) => {
    const id = typeof ref === 'string' ? ref.split(':')[0] : Buffer.from(ref.digest).toString('hex');
    const chunks = []; let offset = '0', done = false;
    while (!done) {
      const chunk = await client.call('artifact.read', {task_id: taskId, artifact_id: id, offset, length: '32768'});
      assert.equal(chunk.sha256, id); chunks.push(Buffer.from(chunk.data, 'base64url')); offset = chunk.next_offset; done = chunk.eof;
    }
    const bytes = Buffer.concat(chunks); assert.equal(hash(bytes), id); return bytes;
  };
  try {
    invoke('validate', '--config', configPath); assert.equal(requests.length, 0);
    for (const [field, value] of [['id', 'review/guards'], ['version', '1.0.0+local']]) {
      const invalid = structuredClone(config), path = join(app.data, `invalid-skill-${field}.json`);
      invalid.skills[0][field] = value;
      await writeFile(path, JSON.stringify(invalid));
      const rejected = spawnSync(app.command, ['validate', '--config', path, '--test-provider', '--trust-root', trust],
        {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 10000});
      assert.equal(rejected.status, 64, `${field}: ${rejected.error ?? rejected.stdout}`);
      assert.equal(requests.length, 0, 'invalid catalog admission cannot dispatch inference');
    }
    const credential = join(app.data, 'synthetic-private-credential'), leakedConfig = join(app.data, 'credential-profile.json');
    await writeFile(credential, 'qualification-only\n', {mode: 0o600});
    await writeFile(leakedConfig, JSON.stringify({...config, endpoint: 'https://api.openai.com/v1/responses', workspace: 'qualification-only'}));
    const leaked = spawnSync(app.command, ['validate', '--config', leakedConfig, '--credential-file', credential],
      {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 10000});
    assert.equal(leaked.status, 64); assert(!`${leaked.stdout}${leaked.stderr}`.includes('qualification-only'));
    assert.equal(requests.length, 0, 'credential validation cannot dispatch inference');
    await launch(['--config', configPath]);
    const description = await client.call('describe');
    const accepted = await client.call('task.submit', {client_operation_id: 'adaptive-controlled-submit', application_id: 'adaptive-agent', profile_id: description.profile.id,
      input: {schema_id: 'adaptive-agent.input.v1', value: {task: 'Explain the fixture entry point using source evidence and exercise the approved adaptive controls.'}}});
    let timer;
    try { await Promise.race([held, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('provider hold timeout')), 15000); })]); }
    finally { clearTimeout(timer); }
    if (providerFailure) throw providerFailure;
    const pingStart = performance.now(); await client.call('ping', {}, 2000); const pingMs = performance.now() - pingStart;
    const statusStart = performance.now(); const heldStatus = await client.call('task.status', {task_id: accepted.task_id}, 2000); const statusMs = performance.now() - statusStart;
    assert.equal(heldStatus.profile_digest, accepted.profile_digest);
    const message = {client_operation_id: 'adaptive-held-followup', task_id: accepted.task_id,
      message: {schema_id: 'adaptive-agent.message.v1', value: {message: 'FOLLOWUP-A: distinguish observations from unrun checks.'}}};
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
    const leftover = await client.call('task.message', {...message, client_operation_id: 'adaptive-unconsumed',
      message: {...message.message, value: {message: 'Retain this input when the authored allowance is full.'}}});
    assert.equal(leftover.disposition, 'queued');
    app.signal(client.child, 'SIGKILL'); await client.closed; client = null;
    await writeFile(join(root, 'src/main.zig'), 'changed after admission\n');
    const changedConfig = join(app.data, 'changed-adaptive.json');
    await writeFile(changedConfig, JSON.stringify({...config, initial_effort: 'high'}));
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
    const schemas = Object.fromEntries(['AdaptivePrepared', 'CapturedResponse', 'AdaptiveResult', 'AdaptiveContext', 'PreparationProduct', 'PreparationCapture', 'PreparationResult', 'WorkReply', 'WorkArtifact']
      .map(name => [name, contract(asset, name)]));
    assert.equal(archive.task.resources.length, skillBodies.length + 2);
    for (const [index, skill] of skillBodies.entries()) assert.equal(archive.object(archive.task.resources[index + 1]).toString('utf8'), skill.body);
    const messageStates = archive.manifest[6].filter(([kind]) => kind === 2).map(([, , ref]) => decodeValue(archive.schemas.get('message'), archive.object(ref))[5]);
    assert.equal(messageStates.filter(state => state === 2).length, 3, 'three authored follow-ups consumed');
    assert.equal(messageStates.filter(state => state === 3).length, 1, 'input beyond the authored allowance remains not consumed');
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
      if (identity === 'agent.model.invoke.v6') {
        const envelope = decodeValue(schemas.AdaptivePrepared, prepared);
        assert.equal(envelope.length, 3); assert.equal(envelope[0], 1);
        const request = envelope[1], plan = request[3], index = Number(plan[2]);
        assert.equal(request.length, 7); assert.equal(plan.length, 7); assert(index >= 0 && index < 14 && !seen.has(index)); seen.add(index);
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
        assert.equal(request[5][2], index !== 13, 'the exact authored input allowance removes ask');
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
        assert.equal(context.length, 14); assert.deepEqual(context[2], archive.task.id);
        assert.equal(context[0], 'agent.model.context.responses.adaptive.v4'); assert.deepEqual(context[1], request[1]);
        assert.equal(context[3], archive.task.tenant); assert.equal(context[4], frozenProfile.adaptive.audience);
        assert.equal(context[6], request[2][2]);
        assert.deepEqual(context[5], request[2]); assert.deepEqual(context[7], plan); assert.equal(context[8], BigInt(index + 1));
        assert.deepEqual(context[9], reference(rawBytes)); assert.deepEqual(context[10], reference(prepared));
        assert.deepEqual(context[11], {tag: 1, value: fixture[index].id});
        const transientBodies = plan[6].filter(skill => skill[3] === 1 && skill[4]).map(skill => skillBodies.find(body => body.id === skill[1]).body);
        assert.equal(context[13].length, JSON.parse(Buffer.from(context[12]).toString('utf8')).length);
        assert(context[13].every(origin => origin[0] <= plan[2]), 'history origins cannot claim future exposure');
        const committedInput = requests[index].body.input.filter(item => !(item.role === 'developer' && item.content?.length === 1 && transientBodies.includes(item.content[0]?.text)));
        assert.deepEqual(JSON.parse(Buffer.from(context[12]).toString('utf8')), [...committedInput, ...fixture[index].output], 'ordered replay appends original output without retaining transient injection');
        captureRows.push({request, http: requests[index].body});
        providerProjections++;
      } else {
        if (identity === 'agent.adaptive.context.prepare.v1') {
          const observation = decodeValue(schemas.PreparationCapture, rawBytes);
          assert.equal(Buffer.from(observation[0]).toString('hex'), hash(prepared));
          assert.deepEqual(observation.slice(1), [false, false], 'legacy trajectory performs no constructed-tool attempts');
          const product = decodeValue(schemas.PreparationProduct, prepared);
          assert(Buffer.from(encodeValue(schemas.PreparationResult, product[0])).equals(replyBytes));
          assert.deepEqual((product[1].tag === 1 ? [reference(Buffer.from(product[1].value))] : []), capture[6].value[1]);
          controlProjections++;
        } else {
          assert(prepared.equals(rawBytes), 'deterministic work retained its original prepared capture');
          assert(['agent.adaptive.snapshot.work.v1', 'agent.adaptive.snapshot.guards.v1'].includes(identity));
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
      input: {schema_id: 'adaptive-agent.input.v1', value: {task: 'Reject inspection after its skill is deactivated.'}}});
    const deniedResult = await until(() => client.call('task.result', {task_id: deniedTask.task_id}), value => value.ready);
    if (providerFailure) throw providerFailure;
    assert.equal(alternateIndex, 8); assert.equal(deniedResult.outcome.value.disposition, 'no_result');
    assert.equal(deniedResult.outcome.value.model_calls, 8); assert.equal(deniedResult.outcome.value.work_calls, 3);
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
      if (attempt[5] !== 'agent.model.invoke.v6') continue;
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
        input: {schema_id: 'adaptive-agent.input.v1', value: {task: 'Cancel the held native adaptive inference.'}}};
      const task = await client.call('task.submit', submission);
      await within(heldRequest, 15000, 'native cancellation request not received');
      await client.call('task.message', {client_operation_id: 'cli-interrupt', task_id: task.task_id,
        message: {schema_id: 'adaptive-agent.message.v1', value: {message: 'This valid caller ID must not prevent native interruption.'}}});
      const cancelParams = {client_operation_id: 'native-cancel-once', task_id: task.task_id};
      let cancellation;
      const stopStarted = performance.now();
      if (method === 'protocol') {
        cancellation = await client.call('task.cancel', cancelParams, 2000);
        assert.equal(cancellation.disposition, 'cancellation_requested');
        await until(() => client.call('task.status', {task_id: task.task_id}), value => value.status === 'unknown');
        assert.deepEqual(await within(client.close(), 3000, 'native cancellation close timeout'), {code: 2, signal: null});
      } else {
        app.signal(client.child, method);
        assert.deepEqual(await within(client.closed, 3000, 'native signal did not stop held inference'), {code: 2, signal: null});
      }
      client = null;
      const milliseconds = performance.now() - stopStarted;
      await launch(['--config', configPath], selectedState);
      const unknown = await client.call('task.status', {task_id: task.task_id});
      assert.equal(unknown.status, 'unknown'); assert.notEqual(unknown.cancellation, null);
      assert.equal((await client.call('task.submit', submission)).task_id, task.task_id);
      if (cancellation) assert.equal((await client.call('task.cancel', cancelParams)).receipt_id, cancellation.receipt_id);
      await assert.rejects(client.call('task.resume', {client_operation_id: 'no-unknown-retry', task_id: task.task_id, expected_revision: unknown.revision}), error => error.data?.kind === 'StateConflict');
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
      await writeFile(selectedConfig, JSON.stringify({schema: 'adaptive-agent.configuration.v2', adaptive: {...config, skills: name === 'tools-reuse' ? config.skills.filter(skill => skill.id === 'invariant-review') : []}, tools: {build: name !== 'tools-foreign', run: true, inputs}}));
      await launch(['--config', selectedConfig], selectedState);
      const description = await client.call('describe');
      const task = await client.call('task.submit', {client_operation_id: name, application_id: 'adaptive-agent', profile_id: description.profile.id,
        input: {schema_id: 'adaptive-agent.input.v1', value: {task: name === 'tools-reverse' ? 'Group source records unsupported by the selected lock scope.' : 'Audit selected lock records against source records, retaining all classifications and reuse the tool on the second input.'}}});
      if (name === 'tools-reuse') {
        const waiting = await until(async () => {
          const value = await client.call('task.status', {task_id: task.task_id});
          if (value.status === 'completed' || value.status === 'failed') assert.fail(`${name}: ${JSON.stringify(await client.call('task.result', {task_id: task.task_id}))}`);
          return value;
        }, value => value.question != null, 2000);
        if (providerFailure) throw providerFailure;
        assert.equal(alternateIndex, 12);
        const originalProgram = await artifact(task.task_id, toolSubject.program);
        assert.equal(Buffer.from(decodeValue(contract(asset, 'ToolProgram'), originalProgram)[5][0]).subarray(0, 8).toString(), 'ABL_BPI3');
        app.signal(client.child, 'SIGKILL'); await client.closed; client = null;
        const bundle = join(app.data, 'constructed-tool.bundle');
        invoke('export-checkpoint', '--state-dir', selectedState, '--task-id', task.task_id, '--output', bundle);
        selectedState = join(app.data, 'constructed tool imported');
        assert.equal(invoke('import-checkpoint', '--state-dir', selectedState, '--input', bundle, '--operation-id', 'constructed-import').task_id, task.task_id);
        await launch(['--profile-task', task.task_id], selectedState);
        const reopened = await client.call('task.status', {task_id: task.task_id});
        assert.deepEqual(reopened.question, waiting.question); assert.equal(alternateIndex, 12);
        assert((await artifact(task.task_id, toolSubject.program)).equals(originalProgram));
        const exported = readArchive(await readFile(bundle));
        const attempts = exported.manifest[6].filter(([kind]) => kind === 5).map(([, , ref]) => decodeValue(exported.schemas.get('attempt'), exported.object(ref))[5]);
        assert.equal(attempts.filter(identity => identity === 'agent.adaptive.tool.build.v1').length, 4);
        assert.equal(attempts.filter(identity => identity === 'agent.adaptive.snapshot.guards.v1').length, 1, 'generated-evidence rejection never dispatches source inspection');
        let privateChecks = 0;
        for (const [kind, id, ref] of exported.manifest[6]) {
          if (kind !== 4) continue;
          const row = exported.manifest[6].find(([kind, candidate]) => kind === 5 && Buffer.from(candidate).equals(Buffer.from(id)));
          const attempt = decodeValue(exported.schemas.get('attempt'), exported.object(row[2]));
          if (attempt[5] !== 'agent.model.invoke.v6') continue;
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
      if (name === 'tools-reuse' || name === 'tools-reverse') {
        assert.equal(result.outcome.value.disposition, 'report');
        assert.equal(result.outcome.value.programs.length, 1);
        assert.equal(result.outcome.value.evidence[0].tag, 'generated');
        const program = result.outcome.value.programs[0];
        assert.equal(`${Buffer.from(program.digest).toString('hex')}:${program.bytes}`, toolSubject.program);
        assert.deepEqual(result.outcome.value.evidence[0].value.program, program);
        const evidence = decodeValue(contract(asset, 'ToolArtifact'), await artifact(task.task_id, result.outcome.value.evidence[0].value.object));
        assert.equal(evidence[3].tag, 1, 'public evidence is the acquired run result');
      } else {
        assert.equal(result.outcome.value.disposition, 'no_result');
        assert.equal(result.outcome.value.programs.length, 0);
        assert.equal(result.outcome.value.work_calls, name === 'tools-disabled' ? 0 : 1);
      }
      if (name === 'tools-reuse') { retainedProgram = toolSubject.program; retainedState = selectedState; assert.equal(alternateIndex, 16); assert.equal(result.outcome.value.control.skills.length, 0); }
      toolRuns.push({scenario: name, provider_calls: alternateIndex, disposition: result.outcome.value.disposition});
      assert.deepEqual(await client.close(), {code: 0, signal: null}); client = null;
    }
    assertAdaptiveCaptures(captureRows, skillBodies);
    console.log(JSON.stringify({adaptive_native: 'controlled HTTPS, held inbox, frozen policy, killed question, archive and independent captured-record checks',
      model_attempts: requests.length, request_bytes: requests.map(item => item.bytes.length),
      held_ping_ms: pingMs, held_status_ms: statusMs, archive_bytes: archiveBytes.length,
      independent_negative_provider_requests: alternateRequests,
      provider_projections: providerProjections, context_projections: controlProjections, work_projections: workProjections,
      consumed_messages: 3, not_consumed_messages: 1, disabled_offer_rejected: offeredWitness, cancellations, tool_construction: toolRuns,
      live_provider: false}));
  } catch (error) {
    throw providerFailure ?? error;
  } finally {
    releaseHeld(); if (client) { client.child.kill('SIGKILL'); await client.closed; }
    for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve));
  }
}
