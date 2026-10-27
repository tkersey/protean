// OWN-13: a real baseline continuation survives an installation of a new image.
import assert from 'node:assert/strict';
import {mkdir, mkdtemp, readFile, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createHash, X509Certificate} from 'node:crypto';
import {createServer} from 'node:https';
import {once} from 'node:events';
import {certificates} from '../support/tls.mjs';
import {install} from '../../tools/native/install.mjs';
import {ProteanClient} from '../support/stdio-client.mts';

if (process.argv.length !== 4) throw new Error('Usage: node test/protean/workspace_runtime_retention.mjs BASELINE_EXECUTABLE NEW_EXECUTABLE');
const root = await realpath(await mkdtemp(join(tmpdir(), 'protean-retained-runtime-')));
const baseline = resolve(process.argv[2]), successor = resolve(process.argv[3]);
const digest = async path => createHash('sha256').update(await readFile(path)).digest('hex');
let client, provider;
let diagnostics = '';
async function launch(binary, state, taskId = null) {
  const frozen = taskId === null ? [] : ['--profile-task', taskId];
  client = new ProteanClient(binary, ['--state-dir', state, ...provider.args, ...frozen]);
  diagnostics = '';
  client.child.stderr.on('data', bytes => { diagnostics = (diagnostics + bytes).slice(-8192); });
  try { await client.initialize(); }
  catch (error) { throw new Error(`${binary}: ${diagnostics}`, {cause: error}); }
  return client.call('describe');
}
async function controlledProvider() {
  const tls = await certificates(root), trust = join(root, 'root.der');
  await writeFile(trust, new X509Certificate(tls.ca).raw);
  const snapshot = join(root, 'snapshot');
  await mkdir(join(snapshot, 'src'), {recursive: true});
  await writeFile(join(snapshot, 'src/main.zig'), 'pub fn main() void {}\n');
  const fixture = JSON.parse(await readFile(new URL('../../examples/adaptive/offline-responses.json', import.meta.url), 'utf8'));
  const replies = ['ask', 'read', 'report'].map(name => fixture.find(reply => reply.output.some(item => item.type === 'function_call' && item.name === name)));
  assert(replies.every(Boolean));
  const requests = [];
  let failure;
  const server = createServer(tls.A, async (request, response) => {
    try {
      assert.equal(request.url, '/v1/responses');
      assert.equal(request.headers.authorization, 'Bearer qualification-only');
      const chunks = []; for await (const chunk of request) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks));
      const index = requests.length;
      assert(index < replies.length);
      const call = replies[index].output.find(item => item.type === 'function_call');
      assert(body.tool_choice.tools.some(tool => tool.name === call.name));
      if (index > 0) {
        const previous = replies[index - 1].output.find(item => item.type === 'function_call');
        const output = body.input.find(item => item.type === 'function_call_output' && item.call_id === previous.call_id);
        assert(output);
        assert(JSON.stringify(output).includes(index === 1 ? 'Focus on observable behavior.' : 'pub fn main() void'));
      }
      requests.push(call.call_id);
      response.writeHead(200, {'content-type': 'application/json'});
      response.end(JSON.stringify(replies[index]));
    } catch (error) { failure = error; response.writeHead(500); response.end('{}'); }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const config = join(root, 'adaptive.json');
  const profile = {id: 'analysis', model: 'fixture-model-a', reasoning_mode: 'standard', reasoning_context: 'auto', efforts: ['medium'], effort_update: false,
    explicit_cache: true, additional_tools: true, cache_diagnostics: true, opaque_family: 'fixture', max_output_tokens: null,
    request_bytes: null, response_bytes: null, timeout_ms: null};
  await writeFile(config, JSON.stringify({schema: 'adaptive-agent.configuration.v3', tools: null, semantic_construction: null, adaptive: {
    workspace: 'retained-runtime', snapshot_root: snapshot, endpoint: `https://127.0.0.1:${server.address().port}/v1/responses`, audience: 'retained-runtime',
    profiles: [profile], initial_profile: 'analysis', initial_effort: 'medium', skills: [],
  }}));
  return {requests, args: ['--test-provider', '--trust-root', trust, '--config', config, '--authorize-inference'],
    check() { if (failure) throw failure; },
    async close() { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }};
}
async function until(read, predicate, taskId) {
  const deadline = Date.now() + 60000;
  const progress = [];
  for (;;) {
    const value = await read();
    provider.check();
    if (predicate(value)) return value;
    const observed = JSON.stringify({revision: value.revision, high_water_seq: value.high_water_seq, ready: value.ready});
    if (progress.at(-1) !== observed) {
      progress.push(observed);
      if (progress.length > 8) progress.shift();
    }
    if (Date.now() > deadline) {
      const sequence = BigInt(value.high_water_seq ?? '16');
      const afterSeq = sequence > 16n ? sequence - 16n : 0n;
      const observations = await Promise.allSettled([
        client.call('task.events', {task_id: taskId, after_seq: afterSeq.toString()}, 5000),
        client.call('task.result', {task_id: taskId}, 5000),
      ]);
      const details = observations.map(item => item.status === 'fulfilled' ? item.value : {error: String(item.reason)});
      console.error(JSON.stringify({progress, observations: details, stderr: diagnostics}).slice(-32768));
      throw new Error(`Timed out: ${JSON.stringify(value)}`);
    }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
}
try {
  provider = await controlledProvider();
  const prefix = join(root, 'installation'), state = join(root, 'original-state');
  const initial = await install(baseline, prefix);
  const oldHash = await digest(initial.current);
  const description = await launch(join(prefix, 'bin', 'protean'), state);
  const accepted = await client.call('task.submit', {client_operation_id: 'baseline-before-update', application_id: 'adaptive-agent', profile_id: description.profile.id, input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Inspect the repository and ask for the desired review focus.'}}});
  const waiting = await until(() => client.call('task.status', {task_id: accepted.task_id}), value => value.question != null, accepted.task_id);
  provider.check(); assert.equal(provider.requests.length, 1);
  await writeFile(join(root, 'snapshot/src/main.zig'), 'changed after baseline admission\n');
  await client.close(); client = null;
  const updated = await install(successor, prefix);
  assert.equal(updated.previous, initial.current);
  assert.equal(await digest(updated.previous), oldHash);
  assert.notEqual(await digest(updated.current), oldHash);
  const newDescription = await launch(join(prefix, 'bin', 'protean'), join(root, 'new-state'));
  assert.equal(newDescription.application.application_version, '8.0.0');
  assert.equal(provider.requests.length, 1);
  await client.close(); client = null;
  const reopenedDescription = await launch(updated.previous, state, accepted.task_id);
  assert.equal(reopenedDescription.profile.resource_identity, description.profile.resource_identity);
  const restored = await client.call('task.status', {task_id: accepted.task_id});
  assert.deepEqual(restored.question, waiting.question);
  assert.equal(restored.profile_digest, waiting.profile_digest);
  assert.equal(provider.requests.length, 1);
  await client.call('task.resume', {client_operation_id: 'original-resume', task_id: accepted.task_id, expected_revision: restored.revision});
  await client.call('task.respond', {client_operation_id: 'original-answer', task_id: accepted.task_id, question_id: waiting.question.question_id, question_revision: waiting.question.question_revision, request_digest: waiting.question.request_digest, answer: {schema_id: waiting.question.answer_schema_id, value: {message: 'Focus on observable behavior.'}}});
  const result = await until(() => client.call('task.result', {task_id: accepted.task_id}), value => value.ready, accepted.task_id);
  provider.check(); assert.equal(provider.requests.length, 3);
  assert.equal(result.outcome.value.result.tag, 'report');
  console.log(JSON.stringify({old_task_continued: true, baseline_sha256: oldHash, successor_sha256: await digest(updated.current), original_question_preserved: true, separate_namespaces: true}));
} finally {
  if (client) await client.close();
  if (provider) await provider.close();
  await rm(root, {recursive: true, force: true});
}
