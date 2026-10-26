// OWN-13: a real baseline continuation survives an installation of a new image.
import assert from 'node:assert/strict';
import {mkdtemp, readFile, realpath, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {install} from '../../tools/native/install.mjs';
import {ProteanClient} from '../support/stdio-client.mts';

if (process.argv.length !== 4) throw new Error('Usage: node test/protean/workspace_runtime_retention.mjs BASELINE_EXECUTABLE NEW_EXECUTABLE');
const root = await realpath(await mkdtemp(join(tmpdir(), 'protean-retained-runtime-')));
const baseline = resolve(process.argv[2]), successor = resolve(process.argv[3]);
const digest = async path => createHash('sha256').update(await readFile(path)).digest('hex');
let client;
async function launch(binary, state) {
  client = new ProteanClient(binary, ['--offline', '--state-dir', state]);
  let diagnostics = '';
  client.child.stderr.on('data', bytes => { diagnostics += bytes; });
  try { await client.initialize(); }
  catch (error) { throw new Error(`${binary}: ${diagnostics}`, {cause: error}); }
  return client.call('describe');
}
async function until(read, predicate) {
  const deadline = Date.now() + 60000;
  for (;;) {
    const value = await read();
    if (predicate(value)) return value;
    if (Date.now() > deadline) throw new Error(`Timed out: ${JSON.stringify(value)}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
try {
  const prefix = join(root, 'installation'), state = join(root, 'original-state');
  const initial = await install(baseline, prefix);
  const oldHash = await digest(initial.current);
  const description = await launch(join(prefix, 'bin', 'protean'), state);
  const accepted = await client.call('task.submit', {client_operation_id: 'baseline-before-update', application_id: 'adaptive-agent', profile_id: description.profile.id, input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Inspect the repository and ask for the desired review focus.'}}});
  const waiting = await until(() => client.call('task.status', {task_id: accepted.task_id}), value => value.question != null);
  await client.close(); client = null;
  const updated = await install(successor, prefix);
  assert.equal(updated.previous, initial.current);
  assert.equal(await digest(updated.previous), oldHash);
  assert.notEqual(await digest(updated.current), oldHash);
  const newDescription = await launch(join(prefix, 'bin', 'protean'), join(root, 'new-state'));
  assert.equal(newDescription.application.application_version, '8.0.0');
  await client.close(); client = null;
  await launch(updated.previous, state);
  const restored = await client.call('task.status', {task_id: accepted.task_id});
  assert.deepEqual(restored.question, waiting.question);
  await client.call('task.resume', {client_operation_id: 'original-resume', task_id: accepted.task_id, expected_revision: restored.revision});
  await client.call('task.respond', {client_operation_id: 'original-answer', task_id: accepted.task_id, question_id: waiting.question.question_id, question_revision: waiting.question.question_revision, request_digest: waiting.question.request_digest, answer: {schema_id: waiting.question.answer_schema_id, value: {message: 'Focus on observable behavior.'}}});
  const result = await until(() => client.call('task.result', {task_id: accepted.task_id}), value => value.ready);
  assert.equal(result.outcome.value.result.tag, 'report');
  console.log(JSON.stringify({old_task_continued: true, baseline_sha256: oldHash, successor_sha256: await digest(updated.current), original_question_preserved: true, separate_namespaces: true}));
} finally {
  if (client) await client.close();
  await rm(root, {recursive: true, force: true});
}
