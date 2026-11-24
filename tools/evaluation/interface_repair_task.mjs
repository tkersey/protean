import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {appendFile, readFile, realpath, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {setTimeout as wait} from 'node:timers/promises';
import {readArchive} from '../../test/protean/native_archive.mjs';
import {contract} from '../../test/protean/adaptive_capture_checks.mjs';
import {decodeValue} from '../../test/support/values.mjs';
import {armViolations, bytesUnder, capturedUsage, decodeRecurrenceObservation, inferenceArguments, readOutcome, RecurrenceDriver,
  recurrenceCost, workspaceMetrics} from './workspace.mjs';
import {parseCandidate, gradeAnswer} from './interface_repair.mjs';
import {adjudicateRepairTrace, adjudicateRepairCollision} from './interface_repair_trace.mjs';
import {campaignIdentity} from './recurrence.mjs';

const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? String(v) : v);
const hash = value => createHash('sha256').update(value).digest('hex');
const sourceText = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});
const terminal = new Set(['completed', 'failed', 'cancelled', 'unknown', 'blocked', 'waiting_input']);
const rejectedCandidate = new Set(['ProjectionBuildRejected', 'ProjectionInputRejected', 'ProjectionStartRejected',
  'ProjectionWorkFailed', 'ProjectionSelectionRejected']);

function conditionViolations(subject, actions) {
  const prohibited = new Set(armViolations('recurrence', actions));
  for (const action of actions) {
    let {name} = action, command = action.arguments?.command;
    if (name === 'placement' && command?.tag === 'control') {
      name = 'work';
      command = command.value?.command;
    }
    if (name === 'program' && ['adopt', 'derive', 'validate'].includes(command?.tag) ||
        name === 'program' && command?.tag === 'build' && command.value?.role === 'controller')
      prohibited.add(action);
    if (subject.phase === 'author') continue;
    if (name === 'program' && !['describe', 'inspect'].includes(command?.tag) ||
        name === 'work' && !['inspect', 'wait', 'collect'].includes(command?.tag) ||
        name === 'context' && command?.tag === 'select') prohibited.add(action);
  }
  return [...prohibited];
}

function rssBytes(pid) {
  if (!pid) return null;
  const {status, stdout} = spawnSync('ps', ['-o', 'rss=', '-p', String(pid)], {encoding: 'utf8'});
  return status === 0 && /^\s*\d+\s*$/.test(stdout) ? Number(stdout.trim()) * 1024 : null;
}

function confirmedAttempts(observations, schemas, application, attempts) {
  const response = contract(application, 'CapturedResponse');
  for (const page of observations) {
    const decoded = decodeRecurrenceObservation({...page, events: [], records: []}, schemas);
    for (const row of decoded.attempts) {
      const capability = row.attempt.capability;
      if (!['agent.model.invoke.v13', 'protean.workspace.inference/2'].includes(capability) ||
          row.capture?.disposition !== 'complete' || !row.response_b64) continue;
      const id = Buffer.from(row.attempt.id).toString('hex');
      if (attempts.has(id)) continue;
      const body = decodeValue(response, Buffer.from(row.response_b64, 'base64'));
      let usage;
      try { usage = capturedUsage(body) ?? null; } catch { usage = null; }
      attempts.set(id, {id, role: capability === 'agent.model.invoke.v13' ? 'controller' : 'delegated', usage});
    }
  }
}

async function readSpecimen(plan, path, expectedId) {
  const bytes = await readFile(path);
  const specimen = JSON.parse(bytes);
  const binding = plan.cases[specimen.case_id]?.specimen;
  assert(binding && binding.path === path && hash(bytes) === binding.sha256, 'Frozen case changed.');
  if (expectedId !== undefined) assert.equal(specimen.case_id, expectedId);
  return specimen;
}

async function initialCondition({plan, plan_sha256, subject, candidate}) {
  assert(/^[a-f0-9]{64}$/.test(plan_sha256), 'Missing frozen plan identity.');
  const condition = subject.arm === 'evidence' || subject.phase === 'transfer' && subject.arm === 'repair' && !candidate
    ? 'ordinary' : subject.arm;
  let source = '';
  if (condition === 'repair' && subject.phase !== 'author') {
    const bytes = Buffer.from(candidate.source_b64, 'base64');
    assert.equal(hash(bytes), candidate.source_sha256, 'Authored source changed.');
    source = sourceText.decode(bytes);
  } else if (condition !== 'ordinary') {
    const seed = subject.arm === 'fixed-adequate' ? plan.sources.adequate : plan.sources.lossy;
    assert.equal(subject.seed_path, seed.path);
    const bytes = await readFile(seed.path);
    assert.equal(hash(bytes), seed.sha256, 'Frozen seed changed.');
    source = sourceText.decode(bytes);
  }
  const descriptor = json({version: 1, plan_sha256, submission_id: subject.id,
    prompt_sha256: hash(subject.prompt),
    phase: subject.phase === 'transfer' ? 'downstream' : subject.phase, condition,
    files: subject.evidence, source_sha256: hash(source)});
  return {condition, descriptor, source};
}

export async function executeRepairTask(options, {Client = RecurrenceDriver, scripted = false, scriptedAnswer} = {}) {
  const {subject, plan, deadline, driver, application, build, candidate = null} = options;
  const started = performance.now();
  const elapsed = () => performance.now() - started;
  const output = await realpath(options.output);
  const state = join(output, 'state'), observations = [];
  const write = (name, value) => writeFile(join(output, name), json(value), {flag: 'wx', mode: 0o600});
  const report = {subject, build, plan_sha256: options.plan_sha256, execution_mode: scripted ? 'scripted_fixture' : 'live',
    task: null, status: null, result: null, bootstrap: null,
    nomination: null, nomination_error: null, adjudication: null, grading: null,
    archive: null, metrics: null, arm_violations: null, peak_rss_sampled_bytes: null,
    retained_namespace_bytes: null, timed_out: false, errors: [], candidate_rejection: null,
    effective_condition: null, fallback_reason: null};
  const record = (stage, error) => report.errors.push({stage, name: error.name, message: error.message});
  let client, timer, startup, schemas, cursor = '0', specimen, pairedSpecimen, stage = 'setup';
  const observe = async () => {
    const raw = await client.call('evaluation.observe', {task_id: report.task.task_id, after: cursor, acquisition: true});
    assert(!raw.events.length || BigInt(raw.cursor) > BigInt(cursor), 'Native observation cursor did not advance.');
    cursor = String(raw.cursor);
    if (raw.events.length || raw.attempts.length || raw.records.length || raw.report_producer) {
      await appendFile(join(output, 'observations.jsonl'), json({elapsed_ms: elapsed(), observation: raw}) + '\n',
        {mode: 0o600});
      observations.push(raw);
    }
    return raw;
  };
  const checkDeadline = () => {
    if (performance.now() < deadline && !report.timed_out) return;
    report.timed_out = true;
    client?.kill();
    throw new Error('Episode deadline expired.');
  };
  const armDeadline = () => {
    const left = deadline - performance.now();
    if (left > 0) timer = setTimeout(armDeadline, Math.min(Math.ceil(left), 2147483647));
    else {
      report.timed_out = true;
      client?.kill();
    }
  };
  const close = async (stage, killed = false) => {
    if (!client) return;
    try {
      const exit = await client.close();
      if (!killed && (exit.code !== 0 || exit.signal !== null)) throw new Error(json(exit));
    } catch (error) { record(stage, error); }
    client = null;
  };
  try {
    assert(Number.isFinite(deadline), 'An absolute episode deadline is required.');
    checkDeadline();
    await write('started.json', {id: subject.id, case_id: subject.case_id, phase: subject.phase,
      remaining_ms: Math.max(0, deadline - started)});
    specimen = await readSpecimen(plan, subject.case_path, subject.case_id);
    if (subject.phase === 'diagnostic') {
      pairedSpecimen = await readSpecimen(plan, subject.paired_case_path);
      assert.notEqual(specimen.case_id, pairedSpecimen.case_id);
    }
    const configuration = await readFile(subject.config);
    assert.equal(hash(configuration), subject.config_sha256);
    const initial = await initialCondition(options);
    report.effective_condition = initial.condition;
    if (subject.arm === 'repair' && initial.condition === 'ordinary') report.fallback_reason = 'no_candidate';
    startup = ['--state-dir', state, '--config', subject.config,
      ...(scripted ? ['--offline', '--fixture-workspace'] : inferenceArguments(options)),
      '--interface-repair-bootstrap', hash(initial.descriptor)];
    checkDeadline();
    client = new Client(driver, startup);
    armDeadline();
    const description = await client.call('describe');
    assert.equal(description.execution_mode, scripted ? 'offline' : 'live');
    const submit = {client_operation_id: subject.id, application_id: 'adaptive-agent', profile_id: description.profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: subject.prompt}}};
    await write('submission.json', submit);
    report.task = await client.call('task.submit', submit);
    await write('accepted.json', report.task);
    const task_id = report.task.task_id;
    const preflight = join(output, 'admitted.agnx');
    await client.call('evaluation.export', {task_id, path: preflight});
    const admitted = readArchive(await readFile(preflight));
    schemas = admitted.schemas;
    assert.equal(admitted.build.application_assets_sha256, plan.identities.application_sha256);
    assert.equal(admitted.build.program_sha256, build.program_sha256);
    assert.equal(Buffer.from(admitted.task.runtime_identity).toString('hex'), plan.identities.driver_sha256);
    const launchProfile = JSON.parse(admitted.object(admitted.task.profile));
    assert.equal(launchProfile.configuration_digest, campaignIdentity(JSON.parse(configuration)));
    assert.equal(Buffer.from(admitted.task.id).toString('hex'), task_id);
    assert.equal(BigInt(admitted.task.inference_attempts), 0n);
    stage = 'bootstrap';
    checkDeadline();
    {
      const params = {task_id, descriptor: initial.descriptor, source: initial.source};
      await write('bootstrap-request.json', params);
      report.bootstrap = await client.call('evaluation.interface_repair.bootstrap', params);
      await write('bootstrap.json', report.bootstrap);
      const path = join(output, 'bootstrapped.agnx');
      await client.call('evaluation.export', {task_id, path});
      const archive = readArchive(await readFile(path));
      assert.equal(Buffer.from(archive.task.id).toString('hex'), task_id);
      assert.equal(BigInt(archive.task.inference_attempts), 0n, 'Bootstrap dispatched inference.');
      if (initial.condition === 'ordinary' || subject.phase === 'diagnostic') {
        assert.equal(report.bootstrap.view, null);
      } else {
        const bound = adjudicateRepairTrace({archive, application, bootstrap: report.bootstrap, specimen, candidate});
        assert(bound.projection?.canonical_input, 'Selected seed lacks a canonical source-backed work input.');
        if (candidate) assert(bound.transfer_bound, 'Transfer does not match frozen executable and schemas.');
      }
      if (scripted && subject.phase === 'author') {
        await close('bootstrap_close');
        assert(!report.errors.length, 'Could not establish a clean bootstrap restart.');
        checkDeadline();
        client = new Client(driver, [...startup, '--profile-task', task_id]);
        const reopened = join(output, 'reopened.agnx');
        await client.call('evaluation.export', {task_id, path: reopened});
        const restored = readArchive(await readFile(reopened));
        for (const field of ['id', 'profile', 'input', 'image', 'runtime_identity'])
          assert.deepEqual(restored.task[field], archive.task[field], 'Bootstrap restart changed ' + field);
        assert.equal(BigInt(restored.task.inference_attempts), 0n);
        const bound = adjudicateRepairTrace({archive: restored, application, bootstrap: report.bootstrap, specimen});
        assert(bound.projection?.canonical_input && !bound.delivery.length, 'Bootstrap restart lost its initial projection.');
        const status = await client.call('task.status', {task_id});
        if (status.status === 'parked') await client.call('task.resume', {
          client_operation_id: subject.id + '-reopen', task_id, expected_revision: status.revision});
        report.recovery = {task_id, before: path, after: reopened, selected_view: bound.projection.view,
          inference_attempts_before_first_use: 0};
      }
    }
    await observe();
    stage = 'execution';
    if (scripted && subject.phase === 'author') {
      report.fixture_receipt = await client.call('evaluation.interface_repair.fixture', {
        task_id, canonical_input: report.bootstrap.input});
    } else if (scripted && subject.phase === 'transfer') {
      report.fixture_receipt = await client.call('evaluation.interface_repair.answer', {
        task_id, summary: scriptedAnswer(specimen, report.bootstrap)});
    }
    let lastSample = -Infinity;
    while (subject.phase !== 'diagnostic') {
      checkDeadline();
      report.status = await client.call('task.status', {task_id});
      if (elapsed() - lastSample >= 1000) {
        const rss = rssBytes(client.child?.pid);
        if (rss !== null) report.peak_rss_sampled_bytes = Math.max(report.peak_rss_sampled_bytes ?? 0, rss);
        lastSample = elapsed();
      }
      if (terminal.has(report.status.status) || report.status.question) break;
      checkDeadline();
      const step = await client.call('evaluation.step');
      if (step.step === 'dispatched')
        await appendFile(join(output, 'dispatches.jsonl'), json({elapsed_ms: elapsed(), ...step}) + '\n', {mode: 0o600});
      if (!['pending', 'waiting', 'idle'].includes(step.step)) await observe();
      else await wait(Math.min(100, Math.max(0, deadline - performance.now())));
    }
  } catch (error) {
    if (candidate && stage === 'bootstrap' && rejectedCandidate.has(error.message))
      report.candidate_rejection = error.message;
    else if (!report.timed_out) record(stage, error);
  } finally {
    if (report.task && client && !report.timed_out && !client.exit && !client.failure) {
      try {
        for (;;) {
          checkDeadline();
          const drain = await client.call('evaluation.drain');
          if (drain.step !== 'pending') { assert(['idle', 'captured'].includes(drain.step)); break; }
          await wait(100);
        }
      } catch (error) { if (!report.timed_out) record('drain', error); }
    }
    clearTimeout(timer);
    await close('close', report.timed_out);
  }
  report.execution_ms = elapsed();
  if (report.task) {
    const task_id = report.task.task_id;
    let finalArchive;
    try {
      client = new Client(driver, [...startup, '--profile-task', task_id]);
      timer = setTimeout(() => client?.kill(), 30000);
      const path = join(output, 'task.agnx');
      await client.call('evaluation.export', {task_id, path});
      const archive = readArchive(await readFile(path));
      assert.equal(Buffer.from(archive.task.id).toString('hex'), task_id);
      finalArchive = archive;
      report.archive = path;
      report.status = await client.call('task.status', {task_id});
      report.result = await readOutcome(client, task_id, await client.call('task.result', {task_id}));
      cursor = '0';
      while ((await observe()).events.length) {}
    } catch (error) { record('archive', error); }
    finally { clearTimeout(timer); await close('archive_close'); }
    if (finalArchive) {
      try {
        report.metrics = workspaceMetrics(finalArchive, application);
        report.arm_violations = conditionViolations(subject, report.metrics.actions);
      } catch (error) { record('metrics', error); }
      const result = report.result?.outcome?.value?.result;
      const summary = result?.tag === 'report' ? result.value.summary : null;
      if (summary !== null && subject.phase === 'author') {
        try { report.nomination = parseCandidate(summary); }
        catch (error) { report.nomination_error = error.message; }
      }
      try {
        report.adjudication = adjudicateRepairTrace({archive: finalArchive, application, observations,
          bootstrap: report.bootstrap, specimen, summary, nomination: report.nomination, candidate});
        if (scripted) {
          report.controlled_application_path = report.adjudication.authored_and_applied;
          report.adjudication.authored_and_applied = false;
        }
        if (subject.phase === 'diagnostic' && report.bootstrap) {
          report.adjudication.collision = adjudicateRepairCollision({archive: finalArchive,
            bootstrap: report.bootstrap, specimen, pairedSpecimen, candidate});
        }
        if (summary !== null && subject.phase === 'transfer') {
          const {report_bound, exposure} = report.adjudication;
          report.grading = gradeAnswer(summary, specimen, report_bound ? exposure : null);
        }
      } catch (error) { record('adjudication', error); }
    }
  }
  try { report.retained_namespace_bytes = await bytesUnder(state); }
  catch (error) { record('namespace', error); }
  if (!report.metrics && observations.length) {
    const attempts = new Map();
    try { confirmedAttempts(observations, schemas, application, attempts); }
    catch (error) { record('observed_usage', error); }
    report.observed_provider_attempts = [...attempts.values()];
  }
  report.elapsed_ms = elapsed();
  report.finalization_ms = report.elapsed_ms - report.execution_ms;
  report.cost = scripted ? {live_provider_attempts: 0, total: null, complete: false, missing: ['Scripted qualification.']} :
    recurrenceCost(report, plan.cost_model, report.metrics?.physical_attempts.map(attempt => attempt.usage) ?? []);
  await write('report.json', report);
  return report;
}
