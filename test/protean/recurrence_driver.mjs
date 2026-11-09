import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp, mkdir, readFile, rm, realpath, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterface} from 'node:readline';
import {setTimeout as delay} from 'node:timers/promises';
import {readArchive} from './native_archive.mjs';
import {decodeRecurrenceObservation, prepareRecurrence, evaluateRecurrence, presentedValues, RecurrenceTrace} from '../../tools/evaluation/workspace.mjs';
import {contract} from './adaptive_capture_checks.mjs';
import {decodeValue, encodeValue} from '../support/values.mjs';

const executable = process.argv[2];
const root = await realpath(await mkdtemp(join(tmpdir(), 'protean-recurrence-driver-')));
const children = [];
function launch(task, state = 'state') {
  const child = spawn(executable, ['--offline', '--state-dir', join(root, state),
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
    if (reply.error) call.reject(new Error(`${reply.error.message}: ${stderr}`)); else call.resolve(reply.result);
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
  const fixtureChild = launch(null, 'fixture-state');
  const fixtureTask = await fixtureChild.call('task.submit', submission);
  const fixture = await fixtureChild.call('evaluation.fixture', {task_id: fixtureTask.task_id});
  const nativeRecords = decodeRecurrenceObservation(
    await fixtureChild.call('evaluation.observe', {task_id: fixtureTask.task_id}), preflight.schemas);
  const nativeTrace = new RecurrenceTrace({packets: []}, application);
  nativeTrace.observe(nativeRecords, 0);
  const hex = bytes => Buffer.from(bytes).toString('hex');
  const work = nativeRecords.records.find(row => row.kind === 'workspace_work');
  const program = nativeRecords.records.find(row => row.kind === 'workspace_program' &&
    hex(row.value.artifact.digest) === hex(work.value.program));
  const computed = nativeRecords.records.find(row => row.kind === 'workspace_value' && row.value.derivation.kind === 'computation');
  const view = nativeRecords.records.find(row => row.kind === 'workspace_view');
  assert(program && work && computed && view, 'native owner must publish every workspace record');
  assert.notDeepEqual(program.value.id, program.value.artifact.digest);
  assert.deepEqual(work.value.program, program.value.artifact.digest);
  assert.deepEqual(computed.value.derivation.program.digest, program.value.artifact.digest);
  assert.deepEqual(computed.value.derivation.work, work.value.id);
  assert.deepEqual(work.value.result.digest, computed.value.description.value.digest);
  assert.deepEqual(work.value.result_value.digest, computed.value.artifact.digest);
  assert.equal(nativeTrace.uses.length, 1);
  assert.equal(nativeTrace.uses[0].artifact_id, hex(program.value.artifact.digest));
  assert.equal(nativeTrace.uses[0].custody_id, hex(program.value.id));
  assert.equal(nativeTrace.uses[0].result_artifact_id, hex(computed.value.artifact.digest));
  assert.equal(typeof nativeTrace.uses[0].creation_seq, 'number');
  assert.equal(nativeTrace.descriptionCandidate(computed), true);
  assert.deepEqual(view.value.description.values.items, []);
  assert.equal(fixture.view.id, hex(view.value.artifact.digest));
  assert.deepEqual(view.value.description.projection.result.digest, computed.value.artifact.digest);
  assert.equal(hex(view.value.description.projection.work.digest), work.body);
  assert.deepEqual(view.value.description.projection.program.digest, program.value.artifact.digest);
  assert.deepEqual(presentedValues(view.value.description), [
    {kind: 'computed', artifact_id: hex(computed.value.artifact.digest)},
  ]);
  assert([...nativeTrace.attempts.values()].some(attempt =>
    attempt.selected_view === hex(view.value.artifact.digest) && attempt.provider_response),
  'native preparation and captured response must use the projected view');
  fixtureChild.stdin.end();
  assert.deepEqual(await fixtureChild.exited, [0, null]);
  const preparedSchema = contract(application, 'AdaptivePrepared'), responseSchema = contract(application, 'CapturedResponse');
  const visibility = new RecurrenceTrace({packets: [{id: 'initial', bytes: 'initial packet'},
    {id: 'later', bytes: 'later packet'}]}, application);
  const observeAttempt = (id, bytes, status, cut) => {
    const prepared = decodeValue(preparedSchema, Buffer.from(captured.prepared_b64, 'base64'));
    const response = decodeValue(responseSchema, Buffer.from(captured.response_b64, 'base64'));
    prepared[2] = Buffer.from(JSON.stringify({input: [{role: 'user', content: bytes}]}));
    response[0] = status;
    visibility.dispatched({step: 'dispatched', attempt: id, epoch: cut, capability: 'agent.model.invoke.v13'}, cut);
    visibility.observeAttempt({...captured, attempt: {...captured.attempt, id, preparation_cut: cut},
      prepared_b64: Buffer.from(encodeValue(preparedSchema, prepared)).toString('base64'),
      response_b64: Buffer.from(encodeValue(responseSchema, response)).toString('base64')}, cut, cut);
  };
  observeAttempt('initial', 'initial packet', 200, 1);
  observeAttempt('failed', 'later packet', 503, 3);
  assert.equal(visibility.visibility.get('later').confirmed, false);
  observeAttempt('unrelated', 'initial packet', 200, 4);
  assert.equal(visibility.visibility.get('later').confirmed, false);
  observeAttempt('retry', 'later packet', 200, 6);
  const exposed = visibility.visibility.get('later');
  assert.equal(exposed.confirmed, true);
  assert.equal(exposed.attempt_id, 'failed');
  assert.equal(exposed.preparation_cut, 3);
  assert.equal(exposed.visibility_epoch, 2);
  observeAttempt('failed-again', 'later packet', 503, 7);
  assert.equal(exposed.confirmed, true);
  visibility.uses.push(...[1, 2].map(epoch => ({kind: 'description', artifact_id: 'late-index',
    attempt_id: `use-${epoch}`, visibility_epoch: epoch, creation_seq: 5, observed_ms: epoch})));
  assert.equal(visibility.qualifyingBoundary({epoch: 8}, 8), null);
  const digest = Array(32).fill(1), task = Array(16).fill(2), reference = [digest, 1n];
  const none = {tag: 0, value: null};
  const value = [digest, task, reference, [1, reference, reference, reference],
    [1, [reference], {tag: 1, value: reference}, {tag: 1, value: digest}, none, none, none, none, none, none]];
  const decoded = decodeRecurrenceObservation({events: [], attempts: [], records: [{kind: 'workspace_value',
    record_b64: Buffer.from(encodeValue(preflight.schemas.get('workspace_value'), value)).toString('base64')}]}, preflight.schemas);
  assert.deepEqual(decoded.records[0].value.derivation.program, {digest, bytes: '1'});
  assert.deepEqual(decoded.records[0].value.derivation.work, digest);
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
  assert.equal(observed.expenditure_trace.at(-1).physical_attempts, observed.metrics.physical_attempts.length);
  const mismatchedOutput = join(root, 'mismatched');
  await mkdir(mismatchedOutput);
  const mismatch = await evaluateRecurrence({subject, plan: {...plan,
    identities: {...plan.identities, application_sha256: '0'.repeat(64)}}, output: mismatchedOutput,
    driver: executable, application, build: {scripted_fixture: true}, offline: true});
  assert(mismatch.errors.some(item => item.message.includes('Driver and frozen application assets differ')));
  assert.equal(mismatch.metrics.controller.calls, 0);
  const helper = join(root, 'siwc-fixture'), helperPidPath = join(root, 'helper.pid');
  const auth = join(root, 'auth'), timeoutOutput = join(root, 'timeout');
  await mkdir(auth);
  await mkdir(timeoutOutput);
  const quotedPidPath = `'${helperPidPath.replaceAll("'", "'\\''")}'`;
  await writeFile(helper, `#!/bin/sh\nprintf '%s\\n' "$$" > ${quotedPidPath}\nexec /bin/sleep 20\n`, {mode: 0o700});
  const chatgptConfig = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.chatgpt.example.json', import.meta.url)));
  const timeoutPlan = await prepareRecurrence({config: chatgptConfig, directory: join(root, 'timeout-campaign'),
    binary: executable, driver: executable, applicationPath, intervalMs: 50,
    limits: {...plan.limits, wall_ms: 1000}});
  const helperAlive = pid => {
    try { process.kill(pid, 0); return true; }
    catch (error) { if (error.code === 'ESRCH') return false; throw error; }
  };
  try {
    const timeout = await evaluateRecurrence({subject: timeoutPlan.cases[0], plan: timeoutPlan,
      output: timeoutOutput, driver: executable, chatgptAccount: 'fixture', siwcBin: helper,
      siwcAuthDir: auth, application, build: {fixture: true}});
    assert.equal(timeout.timed_out, true);
    const helperPid = Number((await readFile(helperPidPath, 'utf8')).trim());
    assert(Number.isSafeInteger(helperPid) && helperPid > 0);
    for (let attempt = 0; attempt < 50 && helperAlive(helperPid); attempt++) await delay(20);
    assert.equal(helperAlive(helperPid), false, 'wall watchdog must terminate the native authentication helper');
  } finally {
    const helperPid = await readFile(helperPidPath, 'utf8').then(text => Number(text.trim()), error => {
      if (error.code === 'ENOENT') return null;
      throw error;
    });
    if (helperPid && helperAlive(helperPid)) process.kill(helperPid, 'SIGKILL');
  }
  console.log(JSON.stringify({sealed_capture: true, external_sigkill: true, captured_response_reused: true,
    native_workspace_lineage: true, native_helper_watchdog: true}));
} finally {
  for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  await Promise.all(children.map(child => child.exited));
  await rm(root, {recursive: true, force: true});
}
