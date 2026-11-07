import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp, mkdir, readFile, rm, realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterface} from 'node:readline';
import {readArchive} from './native_archive.mjs';
import {decodeRecurrenceObservation, prepareRecurrence, evaluateRecurrence} from '../../tools/evaluation/workspace.mjs';

const executable = process.argv[2];
const root = await realpath(await mkdtemp(join(tmpdir(), 'protean-recurrence-driver-')));
const children = [];
function launch(task) {
  const child = spawn(executable, ['--offline', '--state-dir', join(root, 'state'),
    ...(task ? ['--profile-task', task] : [])], {stdio: ['pipe', 'pipe', 'pipe']});
  children.push(child);
  child.exited = once(child, 'exit');
  let sequence = 0, stderr = '';
  const pending = new Map();
  child.stderr.setEncoding('utf8').on('data', bytes => stderr += bytes);
  createInterface({input: child.stdout}).on('line', line => {
    const reply = JSON.parse(line), call = pending.get(reply.id);
    assert(call, `unmatched reply ${line}`);
    pending.delete(reply.id);
    clearTimeout(call.timer);
    if (reply.error) call.reject(new Error(reply.error.message)); else call.resolve(reply.result);
  });
  child.once('exit', (code, signal) => {
    for (const call of pending.values()) {
      clearTimeout(call.timer);
      call.reject(new Error(`driver exited ${code}/${signal}: ${stderr}`));
    }
    pending.clear();
  });
  child.call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { reject(new Error(`timeout: ${method}: ${stderr}`)); child.kill('SIGKILL'); }, 30_000);
    pending.set(id, {resolve, reject, timer});
    child.stdin.write(JSON.stringify({id, method, params}) + '\n');
  });
  return child;
}

try {
  let child = launch();
  const description = await child.call('describe');
  const submission = {client_operation_id: 'recurrence-offline-submit', application_id: 'adaptive-agent',
    profile_id: description.profile.id, input: {schema_id: 'adaptive-agent.input.v2',
      value: {task: 'Explain the fixture entry point using source evidence and exercise the approved adaptive controls.'}}};
  const accepted = await child.call('task.submit', submission);
  const preflightPath = join(root, 'preflight.agnx');
  const preflightReceipt = await child.call('evaluation.export', {task_id: accepted.task_id, path: preflightPath});
  const preflight = readArchive(await readFile(preflightPath));
  assert.equal(preflight.task.inference_attempts, 0n);
  const idleDrain = await child.call('evaluation.drain');
  assert.equal(idleDrain.step, 'idle');
  assert.equal(idleDrain.worker_active, false);
  assert.deepEqual(idleDrain.head, preflightReceipt.head);
  const observe = async () => decodeRecurrenceObservation(
    await child.call('evaluation.observe', {task_id: accepted.task_id}), preflight.schemas);
  let observation, captured, priorEpoch;
  for (let turn = 0; turn < 1000; turn++) {
    const step = await child.call('evaluation.step');
    observation = await observe();
    captured = observation.attempts.find(item => item.attempt.inference && item.capture?.disposition === 'complete');
    if (step.step === 'captured' && captured) break;
    priorEpoch = step.epoch;
  }
  assert(captured, 'actual scripted adaptive worker must publish its capture');
  assert.equal(typeof captured.attempt_b64, 'string');
  assert.equal(typeof captured.capture_b64, 'string');
  assert.equal(observation.worker_active, false);
  assert.equal(captured.occurrence.state.captured.id.join(','), captured.attempt.id.join(','));
  await assert.rejects(child.call('evaluation.pause', {epoch: priorEpoch}), /StaleBoundary/);
  const archivePath = join(root, 'cut.agnx');
  const exported = await child.call('evaluation.export', {task_id: accepted.task_id, path: archivePath});
  const sealed = await child.call('evaluation.pause', {task_id: accepted.task_id, epoch: exported.epoch});
  assert.equal(sealed.step, 'sealed');
  assert.deepEqual(sealed.head, exported.head);
  await assert.rejects(child.call('evaluation.step'), /EvaluationPaused/);
  await assert.rejects(child.call('evaluation.drain'), /EvaluationPaused/);
  const before = readArchive(await readFile(archivePath));
  assert(child.kill('SIGKILL'));
  assert.deepEqual(await child.exited, [null, 'SIGKILL']);
  child = launch(accepted.task_id);
  const reopened = await child.call('task.status', {task_id: accepted.task_id});
  const restored = await observe();
  const original = restored.attempts.find(item => item.attempt.id.join(',') === captured.attempt.id.join(','));
  assert(original, 'captured preparation remains observable after reopen');
  assert.equal(original.attempt_b64, captured.attempt_b64);
  assert.equal(original.capture_b64, captured.capture_b64);
  assert.deepEqual(original.capture, captured.capture);
  assert.equal(original.prepared_b64, captured.prepared_b64);
  assert.equal(original.response_b64, captured.response_b64);
  await child.call('task.resume', {client_operation_id: 'recurrence-offline-resume',
    task_id: accepted.task_id, expected_revision: reopened.revision});
  let resumed;
  for (let turn = 0; turn < 200; turn++) {
    const step = await child.call('evaluation.step');
    resumed = await observe();
    const current = resumed.attempts.find(item => item.attempt.id.join(',') === captured.attempt.id.join(','));
    if (current?.capture?.projection) break;
    assert.notEqual(step.step, 'dispatched', 'captured response must settle without redispatch');
  }
  assert(resumed.attempts.some(item => item.attempt.id.join(',') === captured.attempt.id.join(',') && item.capture?.projection));
  const status = await child.call('task.status', {task_id: accepted.task_id});
  assert.equal(status.task_id, accepted.task_id);
  const afterPath = join(root, 'resumed.agnx');
  await child.call('evaluation.export', {task_id: accepted.task_id, path: afterPath});
  const after = readArchive(await readFile(afterPath));
  assert.deepEqual(after.task.runtime_identity, before.task.runtime_identity);
  assert.deepEqual(after.task.profile, before.task.profile);
  assert.equal(after.task.inference_attempts, before.task.inference_attempts);
  child.stdin.end();
  assert.deepEqual(await child.exited, [0, null]);
  const config = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.example.json', import.meta.url)));
  const applicationPath = process.argv[3], application = JSON.parse(await readFile(applicationPath));
  const plan = await prepareRecurrence({config, directory: join(root, 'campaign'), binary: executable,
    driver: executable, applicationPath, intervalMs: 100,
    limits: {wall_ms: 15000, tokens: 512000, provider_attempts: 128, namespace_bytes: 1073741824, rss_bytes: 4294967296}});
  const subject = plan.cases[1], output = join(root, 'supervisor');
  await mkdir(output);
  const observed = await evaluateRecurrence({subject, plan, output, driver: executable,
    application, build: {scripted_fixture: true}, offline: true});
  assert.deepEqual(observed.errors, []);
  assert(observed.metrics.controller.calls > 0);
  assert.equal(observed.grading.totals.requests, 12);
  assert.equal(observed.grading.totals.sound, 0);
  assert.equal(observed.reuse.qualified, false);
  assert(observed.reuse.visibility.some(item => item.packet_id.endsWith('/packet-0')));
  assert.equal(observed.metrics.physical_attempts.length,
    observed.metrics.controller.calls + observed.metrics.delegated.calls);
  const mismatchedOutput = join(root, 'mismatched');
  await mkdir(mismatchedOutput);
  const mismatch = await evaluateRecurrence({subject, plan: {...plan,
    identities: {...plan.identities, application_sha256: '0'.repeat(64)}}, output: mismatchedOutput,
    driver: executable, application, build: {scripted_fixture: true}, offline: true});
  assert(mismatch.errors.some(item => item.message.includes('Driver and frozen application assets differ')));
  assert.equal(mismatch.metrics.controller.calls, 0);
  console.log(JSON.stringify({sealed_capture: true, external_sigkill: true, captured_response_reused: true}));
} finally {
  for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  await Promise.all(children.map(child => child.exited));
  await rm(root, {recursive: true, force: true});
}
