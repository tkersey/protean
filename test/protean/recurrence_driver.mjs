import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {once} from 'node:events';
import {mkdtemp, mkdir, readFile, rm, realpath, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterface} from 'node:readline';
import {setTimeout as delay} from 'node:timers/promises';
import {readArchive} from './native_archive.mjs';
import {decodeRecurrenceObservation, prepareRecurrence, evaluateRecurrence, presentedValues, RecurrenceTrace, RecurrenceDriver, workspaceMetrics} from '../../tools/evaluation/workspace.mjs';
import {contract} from './adaptive_capture_checks.mjs';
import {decodeValue, encodeValue} from '../support/values.mjs';

const executable = process.argv[2];
const root = await realpath(await mkdtemp(join(tmpdir(), 'protean-recurrence-driver-')));
const children = [];
function launch(task, state = 'state', options = []) {
  const child = spawn(executable, ['--offline', '--state-dir', join(root, state),
    ...options, ...(task ? ['--profile-task', task] : [])], {stdio: ['pipe', 'pipe', 'pipe']});
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
    await child.call('evaluation.observe', {task_id: accepted.task_id, acquisition: true}), preflight.schemas);
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
  let producerObservation;
  for (let turn = 0; turn < 1500; turn++) {
    await child.call('evaluation.step');
    producerObservation = await observe();
    if (producerObservation.question_producer || (await child.call('task.status', {task_id: accepted.task_id})).question) break;
  }
  const producer = producerObservation.question_producer;
  assert(producer, 'native ask must bind its exact admitted producer');
  let input = producerObservation.events.find(event => event.kind === 'input_required');
  let page = producerObservation;
  while (!input && page.events.length) {
    page = decodeRecurrenceObservation(await child.call('evaluation.observe', {task_id: accepted.task_id,
      after: page.cursor, acquisition: true}), preflight.schemas);
    input = page.events.find(event => event.kind === 'input_required');
  }
  assert(input, 'input-required event remains available beyond the first event page');
  const question = JSON.parse(input.data.bytes);
  assert.equal(producer.question_id, question.question_id);
  assert.equal(producer.question_revision, question.question_revision);
  assert.equal(producer.request_digest, question.request_digest);
  const emptyPage = await child.call('evaluation.observe', {task_id: accepted.task_id, after: page.cursor, acquisition: true});
  assert.equal(emptyPage.events.length, 0);
  assert.deepEqual(emptyPage.question_producer, producer);
  const legacyPage = await child.call('evaluation.observe', {task_id: accepted.task_id, after: page.cursor});
  assert.equal(Object.hasOwn(legacyPage, 'question_producer'), false);
  assert.equal(Object.hasOwn(legacyPage, 'acquisition_records_complete'), false);
  assert(legacyPage.records.every(row => row.kind !== 'controller_interaction' && !Object.hasOwn(row, 'native_derivation')));
  assert(child.kill('SIGKILL'));
  assert.deepEqual(await child.exited, [null, 'SIGKILL']);
  child = launch(accepted.task_id);
  const questionReopened = await observe();
  assert.deepEqual(questionReopened.question_producer, producer);
  const carry = questionReopened.records.find(row => row.kind === 'controller_interaction' &&
    row.acquisition.interaction_id === producer.interaction_id).acquisition;
  assert(carry.source_artifacts.length > 0, 'direct acquisition survives later model turns and reopening');
  assert(carry.source_artifacts.every(row => row.task_id === accepted.task_id && row.evidence.content.length > 0));
  await child.call('task.respond', {client_operation_id: 'producer-binding-answer', task_id: accepted.task_id,
    question_id: question.question_id, question_revision: question.question_revision,
    request_digest: question.request_digest, answer: {schema_id: question.answer_schema_id,
      value: {message: 'Yes, focus on observable behavior.'}}});
  assert.equal((await observe()).question_producer, null);
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
  const delegatedSnapshot = join(root, 'delegated-snapshot'), delegatedConfigPath = join(root, 'delegated.json');
  await mkdir(delegatedSnapshot);
  await writeFile(join(delegatedSnapshot, 'fixture.txt'), 'Native delegated fixture evidence.');
  await writeFile(delegatedConfigPath, JSON.stringify({...config, adaptive: {...config.adaptive,
    workspace: 'recurrence-native-fixture', snapshot_root: delegatedSnapshot,
    endpoint: 'https://127.0.0.1:1/v1/responses', skills: []},
  tools: {build: true, run: true, reconstruct: false, inputs: []}}));
  const delegatedOptions = ['--fixture-workspace', '--config', delegatedConfigPath];
  let delegatedChild = launch(null, 'delegated-state', delegatedOptions);
  const delegatedProfile = await delegatedChild.call('describe');
  const delegatedTask = await delegatedChild.call('task.submit', {...submission,
    profile_id: delegatedProfile.profile.id});
  const packets = [1, 2, 3].map(number => ({id: `delegated-${number}`, bytes: `Native delegated packet ${number}.`}));
  const delegatedTrace = new RecurrenceTrace({packets}, application), delegatedObservations = [];
  let retainedValue;
  for (const [index, packet] of packets.entries()) {
    if (index === 2) {
      delegatedTrace.cut = {artifact_id: retainedValue.id};
      assert(delegatedChild.kill('SIGKILL'));
      assert.deepEqual(await delegatedChild.exited, [null, 'SIGKILL']);
      delegatedChild = launch(delegatedTask.task_id, 'delegated-state', delegatedOptions);
      const status = await delegatedChild.call('task.status', {task_id: delegatedTask.task_id});
      const reopened = decodeRecurrenceObservation(await delegatedChild.call('evaluation.observe',
        {task_id: delegatedTask.task_id}), preflight.schemas);
      const previous = [...delegatedTrace.attempts.values()].filter(row => row.capability === 'protean.workspace.inference/2');
      for (const saved of previous) {
        const restored = reopened.attempts.find(row => hex(row.attempt.id) === saved.id);
        assert(restored?.capture);
        assert.equal(createHash('sha256').update(Buffer.from(restored.prepared_b64, 'base64')).digest('hex'), saved.prepared_sha256);
        assert.equal(createHash('sha256').update(Buffer.from(restored.response_b64, 'base64')).digest('hex'), saved.response_sha256);
      }
      delegatedTrace.observe(reopened, index);
      await delegatedChild.call('task.resume', {client_operation_id: 'delegated-fixture-resume',
        task_id: delegatedTask.task_id, expected_revision: status.revision});
    }
    const result = await delegatedChild.call('evaluation.fixture', {task_id: delegatedTask.task_id,
      delegated: true, packet: packet.bytes, ...(retainedValue ? {value: retainedValue} : {})});
    retainedValue ??= result.value;
    assert.deepEqual(result.value, retainedValue);
    delegatedTrace.dispatched({step: 'dispatched', attempt: result.attempt,
      capability: 'protean.workspace.inference/2', epoch: index + 1}, index + 1);
    let found;
    for (let page = 0; page < 20; page++) {
      const observation = decodeRecurrenceObservation(await delegatedChild.call('evaluation.observe',
        {task_id: delegatedTask.task_id, after: String(delegatedTrace.cursor)}), preflight.schemas);
      delegatedObservations.push(observation);
      found ??= observation.attempts.find(row => hex(row.attempt.id) === result.attempt);
      delegatedTrace.observe(observation, index + 1);
      if (observation.events.length < 128) break;
    }
    assert.equal(found?.capture?.disposition, 'complete');
    assert.equal(found.prepared_context.selected_view, result.view);
    assert(Buffer.from(found.prepared_context.body_b64, 'base64').toString().includes(packet.bytes));
    const attempt = delegatedTrace.attempts.get(result.attempt);
    assert.equal(attempt.selected_view, result.view);
    assert.deepEqual(attempt.usage, {input_tokens: 7, output_tokens: 3, total_tokens: 10});
    assert.equal(delegatedTrace.visibility.get(packet.id).confirmed, true);
    const uses = delegatedTrace.uses.filter(use => use.kind === 'description');
    assert.equal(uses.length, index + 1);
    assert(uses.every(use => use.artifact_id === retainedValue.id));
  }
  assert.equal(delegatedTrace.first_boundary.kind, 'description');
  assert.equal(delegatedTrace.first_boundary.artifact_id, retainedValue.id);
  assert.equal(delegatedTrace.summary().post_restart_uses.length, 1);
  const noCapture = new RecurrenceTrace({packets}, application);
  for (const observation of delegatedObservations) {
    for (const row of observation.attempts) if (row.prepared_context && !noCapture.attempts.has(hex(row.attempt.id)))
      noCapture.dispatched({step: 'dispatched', attempt: row.attempt.id,
        capability: 'protean.workspace.inference/2', epoch: observation.epoch}, observation.epoch);
    noCapture.observe({...observation, attempts: observation.attempts.map(row =>
      row.prepared_context ? {...row, capture: undefined, response_b64: undefined} : row)}, observation.epoch);
  }
  assert.equal(noCapture.uses.filter(use => use.kind === 'description').length, 0);
  const sameEpoch = new RecurrenceTrace({packets: [packets[0]]}, application);
  for (const observation of delegatedObservations) {
    for (const row of observation.attempts) if (row.prepared_context && !sameEpoch.attempts.has(hex(row.attempt.id)))
      sameEpoch.dispatched({step: 'dispatched', attempt: row.attempt.id,
        capability: 'protean.workspace.inference/2', epoch: observation.epoch}, observation.epoch);
    sameEpoch.observe(observation, observation.epoch);
  }
  assert.equal(sameEpoch.first_boundary, null);
  const delegatedArchivePath = join(root, 'delegated.agnx');
  await delegatedChild.call('evaluation.export', {task_id: delegatedTask.task_id, path: delegatedArchivePath});
  const delegatedMetrics = workspaceMetrics(readArchive(await readFile(delegatedArchivePath)), application);
  assert.equal(delegatedMetrics.delegated.calls, 3);
  assert.equal(delegatedMetrics.delegated.missing_usage, 0);
  assert.equal(delegatedMetrics.delegated.input_tokens, 21);
  assert.equal(delegatedMetrics.delegated.output_tokens, 9);
  delegatedChild.stdin.end();
  assert.deepEqual(await delegatedChild.exited, [0, null]);
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
  for (const fault of ['active', 'captured', 'closed', 'unacknowledged']) {
    const faultOutput = join(root, `finalize-${fault}`), dispatches = [];
    await mkdir(faultOutput);
    let faulted = false, originalExposure, targetDispatch, faultDispatchCount;
    let startedAt, dispatchedAt, observeDispatchTime = false;
    const now = () => {
      const current = performance.now();
      startedAt ??= current;
      if (observeDispatchTime) { dispatchedAt = current - startedAt; observeDispatchTime = false; }
      return current;
    };
    class FaultDriver extends RecurrenceDriver {
      async call(method, params = {}) {
        if (method === 'task.status' && this.pendingFault && !faulted) {
          faulted = true;
          faultDispatchCount = dispatches.length;
          if (fault !== 'active') {
            let captured = false;
            for (let turn = 0; turn < 300; turn++) {
              const drained = await super.call('evaluation.drain');
              if (drained.step === 'captured') { captured = true; break; }
              assert.equal(drained.step, 'pending');
              await delay(10);
            }
            assert(captured, 'the fault fixture must commit the actual response before failing');
          }
          if (fault === 'closed') { this.kill(); await this.waitClosed(); }
          throw new Error(`native-finalization-${fault}`);
        }
        const result = await super.call(method, params);
        if (method === 'evaluation.step' && result.step === 'dispatched') {
          dispatches.push(result);
          if (result.capability === 'agent.model.invoke.v13' && !faulted) {
            targetDispatch = result;
            if (fault === 'unacknowledged') {
              faulted = true;
              faultDispatchCount = dispatches.length;
              throw new Error(`native-finalization-${fault}`);
            }
            this.pendingFault = true;
            observeDispatchTime = true;
          }
        }
        if (method === 'evaluation.observe' && targetDispatch && !faulted)
          originalExposure ??= decodeRecurrenceObservation(result, preflight.schemas).attempts
            .find(row => hex(row.attempt.id) === targetDispatch.attempt);
        return result;
      }
    }
    const report = await evaluateRecurrence({subject, plan, output: faultOutput, driver: executable,
      application, build: {scripted_fixture: true}, offline: true}, {Client: FaultDriver, now});
    assert(faulted);
    assert.equal(dispatches.length, faultDispatchCount, 'finalization must not dispatch new work');
    assert.equal(dispatches.filter(step => step.capability === 'agent.model.invoke.v13').length, 1);
    assert(report.errors.some(error => error.stage === 'execution' && error.message === `native-finalization-${fault}`));
    const traced = report.reuse.attempts.find(attempt => attempt.id === targetDispatch.attempt);
    assert.equal(traced?.capture?.disposition, 'complete');
    assert.equal(traced.usage, null);
    assert.equal(report.metrics.controller.calls, 1);
    assert.equal(report.metrics.controller.missing_usage, 1);
    assert.equal(report.metrics.physical_attempts.length, 1);
    assert.equal(report.expenditure_trace.at(-1).physical_attempts, 1);
    if (fault === 'unacknowledged') {
      assert.equal(traced.dispatched_ms, undefined);
      assert.equal(report.reuse.visibility.length, 0);
    } else {
      assert(originalExposure && originalExposure.capture === undefined);
      assert.equal(traced.dispatched_ms, dispatchedAt);
      assert.equal(traced.visibility_epoch, 1);
      assert.equal(traced.prepared_sha256, createHash('sha256')
        .update(Buffer.from(originalExposure.prepared_b64, 'base64')).digest('hex'));
      assert.equal(report.reuse.visibility[0].dispatch_ms, dispatchedAt);
      assert.equal(report.reuse.visibility[0].preparation_cut, Number(originalExposure.attempt.preparation_cut));
    }
    const archive = readArchive(await readFile(report.archive));
    const rawRows = (await readFile(join(faultOutput, 'observations.jsonl'), 'utf8')).trim().split('\n')
      .flatMap(line => decodeRecurrenceObservation(JSON.parse(line).observation, archive.schemas).attempts);
    const captured = rawRows.find(row => hex(row.attempt.id) === traced.id && row.capture?.disposition === 'complete');
    assert(captured, 'raw observations must retain the drained or reopened native capture');
    const captureEntry = archive.manifest[6].find(([kind, id]) => kind === 4 && hex(id) === traced.id);
    assert.deepEqual(Buffer.from(captured.capture_b64, 'base64'), archive.object(captureEntry[2]));
    assert.equal(createHash('sha256').update(Buffer.from(captured.prepared_b64, 'base64')).digest('hex'), traced.prepared_sha256);
    assert.equal(createHash('sha256').update(Buffer.from(captured.response_b64, 'base64')).digest('hex'), traced.response_sha256);
  }
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
  for (const signal of ['SIGINT', 'SIGTERM']) {
    const signalRoot = join(root, signal), pidPath = join(signalRoot, 'helper.pid');
    const signalHelper = join(signalRoot, 'siwc'), parameters = join(signalRoot, 'parameters.json');
    await mkdir(signalRoot);
    const output = join(signalRoot, 'output');
    await mkdir(output);
    const quoted = `'${pidPath.replaceAll("'", "'\\''")}'`;
    await writeFile(signalHelper, `#!/bin/sh\nprintf '%s %s\\n' "$$" "$PPID" > ${quoted}\nexec /bin/sleep 20\n`, {mode: 0o700});
    await writeFile(parameters, JSON.stringify({subject: timeoutPlan.cases[0],
      plan: {...timeoutPlan, limits: {...timeoutPlan.limits, wall_ms: 60000}}, output,
      driver: executable, chatgptAccount: 'fixture', siwcBin: signalHelper, siwcAuthDir: auth,
      application, build: {fixture: true}}));
    const moduleUrl = new URL('../../tools/evaluation/workspace.mjs', import.meta.url).href;
    const script = `import {readFile} from 'node:fs/promises';
      import {evaluateRecurrence} from ${JSON.stringify(moduleUrl)};
      await evaluateRecurrence(JSON.parse(await readFile(process.argv[1], 'utf8')));`;
    const supervisor = spawn(process.execPath, ['--input-type=module', '-e', script, parameters],
      {stdio: ['ignore', 'pipe', 'pipe']});
    children.push(supervisor);
    supervisor.exited = once(supervisor, 'exit');
    let diagnostics = '', helperPid, driverPid;
    supervisor.stderr.setEncoding('utf8').on('data', bytes => diagnostics += bytes);
    try {
      for (let attempt = 0; attempt < 500; attempt++) {
        const ids = await readFile(pidPath, 'utf8').catch(error => {
          if (error.code === 'ENOENT') return null;
          throw error;
        });
        if (ids) { [helperPid, driverPid] = ids.trim().split(' ').map(Number); break; }
        assert.equal(supervisor.exitCode, null, diagnostics);
        await delay(10);
      }
      assert([helperPid, driverPid].every(pid => Number.isSafeInteger(pid) && pid > 0), diagnostics);
      assert(helperAlive(helperPid) && helperAlive(driverPid));
      assert(supervisor.kill(signal));
      const exit = await Promise.race([supervisor.exited, delay(6000, null, {ref: false}).then(() => {
        throw new Error(`Supervisor did not close after ${signal}: ${diagnostics}`);
      })]);
      assert.deepEqual(exit, [null, signal]);
      for (let attempt = 0; attempt < 100 && (helperAlive(helperPid) || helperAlive(driverPid)); attempt++) await delay(10);
      assert.equal(helperAlive(helperPid), false, `${signal} must terminate the native authentication helper`);
      assert.equal(helperAlive(driverPid), false, `${signal} must terminate the native driver`);
    } finally {
      for (const pid of [helperPid, driverPid]) if (pid && helperAlive(pid)) process.kill(pid, 'SIGKILL');
    }
  }
  console.log(JSON.stringify({sealed_capture: true, external_sigkill: true, captured_response_reused: true,
    native_workspace_lineage: true, delegated_description_reuse: true, native_finalization: true,
    native_helper_watchdog: true, native_supervisor_signals: true}));
} finally {
  for (const child of children) if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  await Promise.all(children.map(child => child.exited));
  await rm(root, {recursive: true, force: true});
}
