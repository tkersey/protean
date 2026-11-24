import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdir, readFile, unlink, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {prepareInterfaceRepair} from '../../tools/evaluation/interface_repair_campaign.mjs';
import {executeRepairTask} from '../../tools/evaluation/interface_repair_task.mjs';
import {assessScan} from '../../tools/evaluation/interface_repair.mjs';
import {readArchive} from './native_archive.mjs';
import {contract} from './adaptive_capture_checks.mjs';
import {decodeValue, encodeValue} from '../support/values.mjs';
import {adjudicateRepairTrace} from '../../tools/evaluation/interface_repair_trace.mjs';
import {RecurrenceDriver} from '../../tools/evaluation/workspace.mjs';

const bootstrapMethod = 'evaluation.interface_repair.bootstrap';
const sha = text => createHash('sha256').update(text).digest('hex');

async function committedBootstrap(child, params) {
  const task = {task_id: params.task_id};
  const before = await child.call('task.status', task);
  const value = await child.call(bootstrapMethod, {...params, completed_only: true});
  assert.deepEqual(await child.call('task.status', task), before);
  return value;
}

function compareRecovered(actual, supplied, expectedPreparation = supplied.preparation) {
  const {build_metrics, preparation, ...evidence} = supplied;
  const {build_metrics: restored, preparation: observed, ...recovered} = actual;
  assert.equal(observed, expectedPreparation);
  assert.deepEqual(recovered, evidence);
  assert.equal(restored.build_commands, build_metrics.build_commands);
  assert.equal(restored.rejected_build_commands, build_metrics.rejected_build_commands);
  assert.equal(restored.compiler_nanoseconds, build_metrics.compiler_nanoseconds);
  assert.equal(restored.build_elapsed_nanoseconds, restored.build_commands === 0 ? '0' : null);
}

class CheckedBootstrapClient extends RecurrenceDriver {
  async call(method, params) {
    if (method !== bootstrapMethod || params.completed_only) return super.call(method, params);
    await assert.rejects(super.call(method, {...params, descriptor: params.descriptor + ' '}), /ChangedPlan/);
    await assert.rejects(super.call(method, {...params, source: params.source + ' '}), /ChangedProgram/);
    const result = await super.call(method, params);
    assert.deepEqual(await super.call(method, {...params, completed_only: true}), result);
    await assert.rejects(super.call(method, params), /InitialCutRequired/);
    return result;
  }
}

async function rejectedSubmission(launch, root, author, plan_sha256, source, baselinePrograms) {
  const descriptor = JSON.stringify({version: 1, plan_sha256, submission_id: author.id,
    prompt_sha256: sha(author.prompt), phase: 'author', condition: 'repair',
    files: author.evidence, source_sha256: sha(source), program_sha256: null});
  const child = launch(null, 'changed-prompt', ['--fixture-workspace', '--config', author.config,
    '--interface-repair-bootstrap', sha(descriptor)]);
  try {
    const {profile} = await child.call('describe');
    const extra = join(author.snapshot, 'later-file.txt');
    await writeFile(extra, 'added after the original driver captured its snapshot', {flag: 'wx'});
    try {
      const admission = await child.call('evaluation.interface_repair.admission', {descriptor});
      assert.equal(admission.profile_sha256, profile.sha256);
      const changed = launch(null, 'changed-admission', ['--fixture-workspace', '--config', author.config,
        '--interface-repair-bootstrap', sha(descriptor)]);
      try {
        await assert.rejects(changed.call('evaluation.interface_repair.admission', {descriptor}), /ChangedSnapshot/);
      } finally {
        changed.stdin.end();
        assert.deepEqual(await changed.exited, [0, null]);
      }
    } finally { await unlink(extra); }
    const task = await child.call('task.submit', {client_operation_id: author.id, application_id: 'adaptive-agent',
      profile_id: profile.id, input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Changed prompt.'}}});
    await assert.rejects(child.call(bootstrapMethod, {task_id: task.task_id, descriptor, source}), /ChangedSubmission/);
    const path = join(root, 'rejected-bootstrap.agnx');
    await child.call('evaluation.export', {task_id: task.task_id, path});
    const archive = readArchive(await readFile(path));
    assert.equal(archive.task.inference_attempts, 0n);
    assert.deepEqual(sourceInventory(archive), baselinePrograms);
  } finally {
    child.stdin.end();
    assert.deepEqual(await child.exited, [0, null]);
  }
}

async function restartAtSelection(launch, root, subject, plan_sha256, source, oversized) {
  const descriptor = JSON.stringify({version: 1, plan_sha256, submission_id: subject.id,
    prompt_sha256: sha(subject.prompt), phase: 'downstream', condition: 'fixed-lossy',
    files: subject.evidence, source_sha256: sha(source), program_sha256: null});
  const state = oversized ? 'rejected-presentation' : 'selection-recovery';
  let configPath = subject.config;
  if (oversized) {
    const config = JSON.parse(await readFile(configPath));
    for (const profile of config.adaptive.profiles) profile.request_bytes = 512;
    configPath = join(root, state + '.json');
    await writeFile(configPath, JSON.stringify(config));
  }
  const options = ['--fixture-workspace', '--config', configPath, '--interface-repair-bootstrap', sha(descriptor)];
  let child = launch(null, state, options);
  const close = async () => {
    child.stdin.end();
    assert.deepEqual(await child.exited, [0, null]);
  };
  const task = {};
  const reopen = async () => {
    await close();
    child = launch(task.task_id, state, options);
    const status = await child.call('task.status', task);
    if (status.status === 'parked') await child.call('task.resume',
      {...task, client_operation_id: 'resume-' + status.revision, expected_revision: status.revision});
  };
  try {
    const {profile} = await child.call('describe');
    const submitted = {client_operation_id: subject.id, application_id: 'adaptive-agent', profile_id: profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: subject.prompt}}};
    task.task_id = (await child.call('task.submit', submitted)).task_id;
    const setup = await child.call('evaluation.interface_repair.fixture_select', {...task, descriptor, source});
    assert(setup.view);
    assert.equal(setup.preparation, 'pending');
    await reopen();
    compareRecovered(await committedBootstrap(child, {...task, descriptor, source}), setup);
    if (oversized) {
      await assert.rejects(child.call('evaluation.step'), /ProjectionPreparationOversized/);
      await reopen();
      await assert.rejects(child.call('evaluation.step'), /ProjectionPreparationOversized/);
      const {preparation_rejection, ...selected} = await committedBootstrap(child, {...task, descriptor, source});
      compareRecovered(selected, setup, 'rejected');
      assert.equal(preparation_rejection, 'ProjectionPreparationOversized');
      const path = join(root, state + '.agnx');
      await child.call('evaluation.export', {...task, path});
      assert.equal(readArchive(await readFile(path)).task.inference_attempts, 0n);
      return;
    }
    assert.equal((await child.call('evaluation.step')).step, 'bootstrap_ready');
    await assert.rejects(child.call('task.submit', {...submitted, client_operation_id: 'another-task'}),
      /PlannedTaskRequired/);
    await child.call('evaluation.interface_repair.answer', {...task, summary: 'Controlled terminal report.'});
    const path = join(root, state + '.agnx');
    await child.call('evaluation.export', {...task, path});
    const before = readArchive(await readFile(path));
    assert(before.task.inference_attempts > 0n);
    await reopen();
    compareRecovered(await committedBootstrap(child, {...task, descriptor, source}), setup, 'ready');
    await assert.rejects(child.call('evaluation.interface_repair.answer', {...task, summary: 'Second report.'}),
      /InitialCutRequired/);
    for (let turn = 0; turn < 128; turn++) {
      if ((await child.call('task.status', task)).status === 'completed') break;
      await child.call('evaluation.step');
    }
    assert.equal((await child.call('task.status', task)).status, 'completed');
    const after = join(root, state + '-completed.agnx');
    await child.call('evaluation.export', {...task, path: after});
    assert.equal(readArchive(await readFile(after)).task.inference_attempts, before.task.inference_attempts);
  } finally { await close(); }
}

async function recoverBootstrap(launch, root, subject, plan_sha256, source, mode, programId = null) {
  const ordinary = mode === 'ordinary';
  const diagnostic = mode === 'diagnostic';
  const condition = diagnostic ? 'repair' : ordinary ? 'ordinary' : 'fixed-lossy';
  const descriptor = JSON.stringify({version: 1, plan_sha256, submission_id: subject.id,
    prompt_sha256: sha(subject.prompt), phase: diagnostic ? 'diagnostic' : 'downstream', condition,
    files: subject.evidence, source_sha256: sha(source), program_sha256: programId});
  const state = 'bootstrap-cuts-' + mode;
  const flags = ['--fixture-workspace', '--config', subject.config, '--interface-repair-bootstrap', sha(descriptor)];
  let child = launch(null, state, flags), task;
  const close = async () => {
    child.stdin.end();
    assert.deepEqual(await child.exited, [0, null]);
  };
  const capture = async label => {
    const path = join(root, state + '-' + label + '.agnx');
    await child.call('evaluation.export', {...task, path});
    return readArchive(await readFile(path));
  };
  try {
    const {profile} = await child.call('describe');
    const submitted = await child.call('task.submit', {client_operation_id: subject.id,
      application_id: 'adaptive-agent', profile_id: profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: subject.prompt}}});
    task = {task_id: submitted.task_id};
    const params = {...task, descriptor, source};
    assert.equal(await committedBootstrap(child, params), null);
    if (!diagnostic) {
      await close();
      child = launch(task.task_id, state, flags);
      const parked = await child.call('task.status', task);
      assert.equal(parked.status, 'parked');
      await child.call('task.resume', {...task, client_operation_id: 'resume-after-submit',
        expected_revision: parked.revision});
      assert.equal(await committedBootstrap(child, params), null);
      if (mode === 'early-message') {
        await child.call('task.message', {...task, client_operation_id: 'message-before-setup',
          message: {schema_id: 'adaptive-agent.message.v2', value: {message: 'Updated instructions.'}}});
        await assert.rejects(child.call(bootstrapMethod, params), /InitialCutRequired/);
        assert.equal(await committedBootstrap(child, params), null);
        return;
      }
    }
    const cuts = mode === 'joined' ? ['joined'] : diagnostic ? ['start', 'primary'] : ordinary ? ['acquisition'] : mode === 'cancelled' ? ['not_sent'] :
      mode === 'message' ? ['build'] : ['build', 'consumer', 'acquisition', 'start', 'primary'];
    let program = null, consumer = null, work = null;
    for (const stop_after of cuts) {
      await assert.rejects(child.call('evaluation.interface_repair.fixture_select', {...params, stop_after}),
        /FixtureCut/, stop_after);
      if (stop_after === 'joined') {
        assert.equal((await child.call('evaluation.drain')).step, 'captured');
        assert.equal((await child.call('evaluation.drain')).step, 'idle');
        assert.equal((await child.call('evaluation.step')).step, 'bootstrap_ready');
        assert((await committedBootstrap(child, params)).view);
        assert.equal((await capture('joined-save')).task.inference_attempts, 0n);
        return;
      }
      if (stop_after !== 'not_sent') assert.equal(await committedBootstrap(child, params), null);
      const before = await capture(stop_after);
      assert.equal(before.task.inference_attempts, 0n);
      const rows = n => before.manifest[6].filter(row => row[0] === n);
      if (!ordinary) {
        const match = rows(8).filter(row => {
          const record = decodeValue(before.schemas.get('workspace_program'), before.object(row[2]));
          return before.object(record[3][1]).equals(Buffer.from(source));
        });
        assert.equal(match.length, 1);
        const id = Buffer.from(match[0][1]).toString('hex');
        if (program) assert.equal(id, program);
        program = id;
      }
      for (const [kind, prior] of [[17, consumer], [9, work]]) {
        assert(rows(kind).length <= 1);
        if (prior) assert.equal(Buffer.from(rows(kind)[0][1]).toString('hex'), prior);
      }
      consumer = rows(17).length ? Buffer.from(rows(17)[0][1]).toString('hex') : null;
      work = rows(9).length ? Buffer.from(rows(9)[0][1]).toString('hex') : null;
      if (mode === 'cancelled') {
        await child.call('task.cancel', {...task, client_operation_id: 'cancel-unsent'});
        for (let n = 0; n < 32 && (await child.call('task.status', task)).status !== 'cancelled'; n++)
          await child.call('evaluation.step').catch(e => {
            assert.match(e.message, /InitialSetupBlocked|InitialPreparationFailed/);
          });
        assert.equal((await child.call('task.status', task)).status, 'cancelled');
      }
      await close();
      child = launch(task.task_id, state, flags);
      const reopened = await child.call('task.status', task);
      const restored = await capture(stop_after + '-reopen');
      assert.deepEqual(restored.task.input, before.task.input);
      assert.equal(restored.task.inference_attempts, 0n);
      if (mode === 'cancelled') {
        assert.equal(reopened.status, 'cancelled');
        const evidence = await committedBootstrap(child, params);
        assert.equal(evidence.consumer.id, consumer);
        assert(evidence.view);
        assert.equal(evidence.preparation, 'failed');
        await assert.rejects(child.call('evaluation.step'), /InitialPreparationFailed/);
        return;
      }
      if (reopened.status === 'parked') await child.call('task.resume', {...task,
        client_operation_id: 'resume-' + reopened.revision, expected_revision: reopened.revision});
      if (mode === 'message') {
        await child.call('task.message', {...task, client_operation_id: 'operator-message',
          message: {schema_id: 'adaptive-agent.message.v2', value: {message: 'Updated task instructions.'}}});
        await assert.rejects(child.call(bootstrapMethod, params), /InitialCutRequired/);
        return;
      }
    }
    const ready = await child.call(bootstrapMethod, params);
    assert.equal(ready.build_metrics.build_commands, ordinary ? 0 : diagnostic ? 1 : null);
    assert.equal(ready.build_metrics.rejected_build_commands, ordinary || diagnostic ? 0 : null);
    assert.equal(ready.build_metrics.build_elapsed_nanoseconds, ordinary ? '0' : null);
    assert.equal(ready.build_metrics.compiler_nanoseconds, ordinary ? '0' : null);
    assert.equal(ready.consumer?.id ?? null, consumer);
    assert.equal(ready.work?.id ?? null, work);
    assert.equal(Boolean(ready.view), !ordinary && !diagnostic);
    const committed = await capture('before-response-recovery');
    await close();
    child = launch(task.task_id, state, flags);
    const reopened = await capture('after-response-recovery-reopen');
    const recovered = await committedBootstrap(child, params);
    compareRecovered(recovered, ready);
    const retrieved = await capture('retrieved');
    assert.deepEqual(retrieved.manifest, reopened.manifest);
    assert.equal(retrieved.task.inference_attempts, committed.task.inference_attempts);
    if (diagnostic) {
      assert.notEqual(ready.work.id, ready.paired.work.id);
      const readyArchive = await capture('ready');
      assert.equal(readyArchive.manifest[6].filter(row => row[0] === 9).length, 2);
      assert.equal(readyArchive.manifest[6].filter(row => row[0] === 17).length, 1);
      assert.equal(readyArchive.task.inference_attempts, 0n);
    }
  } finally { await close(); }
}

async function rejectIncompatibleProgram(launch, root, subject, plan_sha256, scalar, large) {
  const state = large ? 'large-source' : 'scalar-input';
  const source = large ? scalar.source + ' '.repeat(1024 * 1024) : scalar.source;
  const path = join(root, state + '.source.json');
  await writeFile(path, source);
  const descriptor = JSON.stringify({version: 1, plan_sha256, submission_id: subject.id,
    prompt_sha256: sha(subject.prompt), phase: 'diagnostic', condition: 'repair',
    files: subject.evidence, source_sha256: sha(source), program_sha256: scalar.id});
  const options = ['--fixture-workspace', '--config', subject.config, '--interface-repair-source', path,
    '--interface-repair-bootstrap', sha(descriptor)];
  const child = launch(null, state, options);
  try {
    const {profile} = await child.call('describe');
    const {task_id} = await child.call('task.submit', {client_operation_id: subject.id,
      application_id: 'adaptive-agent', profile_id: profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: subject.prompt}}});
    await assert.rejects(child.call(bootstrapMethod, {task_id, descriptor, source: null}),
      large ? /ChangedExecutable/ : /ProjectionInputRejected/);
    if (!large) assert.equal((await committedBootstrap(child, {task_id, descriptor, source: null})).candidate_rejected,
      'ProjectionInputRejected');
    const retained = join(root, state + '.agnx');
    await child.call('evaluation.export', {task_id, path: retained});
    const archive = readArchive(await readFile(retained));
    assert(sourceInventory(archive).includes(sha(source)));
    assert.equal(archive.manifest[6].filter(([kind]) => kind === 9).length, 0);
    assert.equal(archive.task.inference_attempts, 0n);
  } finally {
    child.stdin.end();
    assert.deepEqual(await child.exited, [0, null]);
  }
}

async function rejectedProjection(launch, root, diagnostic, transfer, plan_sha256, forwarder) {
  const records = JSON.parse(forwarder);
  assert.equal(records.module.constants.length, 1);
  assert.equal(records.module.constants[0].bytes, 'AQE');
  records.module.constants[0].bytes = 'AA';
  const source = JSON.stringify(records);
  let program = null;
  for (const stage of ['build', 'diagnostic', 'downstream']) {
    const subject = stage === 'downstream' ? transfer : diagnostic;
    const descriptor = JSON.stringify({version:1,plan_sha256,submission_id:subject.id,
      prompt_sha256:sha(subject.prompt),phase:stage === 'downstream' ? stage : 'diagnostic',condition:'repair',files:subject.evidence,
      source_sha256:sha(source),program_sha256:program ?? '0'.repeat(64)});
    const state = 'rejected-projection-' + stage;
    const flags = ['--fixture-workspace','--config',subject.config,'--interface-repair-bootstrap',sha(descriptor)];
    let child = launch(null,state,flags);
    const close = async () => { child.stdin.end(); assert.deepEqual(await child.exited,[0,null]); };
    try {
      const {profile} = await child.call('describe');
      const {task_id} = await child.call('task.submit',{client_operation_id:subject.id,application_id:'adaptive-agent',
        profile_id:profile.id,input:{schema_id:'adaptive-agent.input.v2',value:{task:subject.prompt}}});
      const params = {task_id,descriptor,source}, path = join(root,state + '.agnx');
      if (stage === 'build') {
        await assert.rejects(child.call('evaluation.interface_repair.fixture_select',{...params,stop_after:'build'}),
          /FixtureCut/);
        await child.call('evaluation.export',{task_id,path});
        const archive = readArchive(await readFile(path));
        const built = archive.manifest[6].filter(row => row[0] === 8).map(row =>
          decodeValue(archive.schemas.get('workspace_program'),archive.object(row[2])))
          .find(row => archive.object(row[3][1]).equals(Buffer.from(source)));
        assert(built);
        program = Buffer.from(built[2][0]).toString('hex');
      } else {
        await assert.rejects(child.call(bootstrapMethod,params), /ProjectionResultRejected/);
        await close();
        child = launch(task_id,state,flags);
        const rejected = await committedBootstrap(child,params);
        assert.equal(rejected.candidate_rejected, 'ProjectionResultRejected');
        assert.equal(rejected.view, undefined);
        assert.equal(rejected.build_metrics.build_commands, 1);
        await child.call('evaluation.export',{task_id,path});
        assert.equal(readArchive(await readFile(path)).task.inference_attempts,0n);
      }
    } finally { await close(); }
  }
}

async function rejectedPreparation(root, transfer, options) {
  const config = JSON.parse(await readFile(transfer.config));
  for (const profile of config.adaptive.profiles) profile.request_bytes = 512;
  const bytes = JSON.stringify(config);
  const path = join(root, 'transfer-preparation-budget.json');
  await writeFile(path, bytes);
  const subject = {...transfer, config: path, config_sha256: sha(bytes)};
  class LostResponse extends RecurrenceDriver {
    async call(method, params) {
      try { return await super.call(method, params); }
      catch (error) {
        if (method === bootstrapMethod && !params.completed_only && error.message === 'ProjectionPreparationOversized')
          throw new Error('Interrupted bootstrap response.');
        throw error;
      }
    }
  }
  for (const [name, Client] of [['observed', RecurrenceDriver], ['interrupted', LostResponse]]) {
    const output = join(root, 'preparation-rejection-' + name);
    await mkdir(output);
    const report = await executeRepairTask({...options, subject, output, deadline: performance.now() + 60000},
      {scripted: true, scriptedAnswer, Client});
    const reason = 'ProjectionPreparationOversized';
    assert.equal(report.candidate_rejection, reason);
    assert.equal(report.bootstrap.preparation, 'rejected');
    assert.equal(report.bootstrap.preparation_rejection, reason);
    assert.equal(report.bootstrap.candidate_rejected, reason);
    assert.equal(report.bootstrap.view.kind, 'view');
    assert.deepEqual(report.bootstrap.program, options.candidate.program);
    assert.equal(report.errors.some(error => error.stage === 'archive' || error.stage === 'bootstrap_recovery'), false);
    assert.equal(report.errors.length, Client === LostResponse ? 1 : 0);
    assert.equal(report.cost.live_provider_attempts, 0);
    assert(report.status && report.final_metrics_complete);
  }
}

function scriptedAnswer(specimen, bootstrap) {
  const {domain, outcome} = assessScan(specimen);
  return JSON.stringify({kind: 'interface-repair.answer.v1', case_id: specimen.case_id,
    domain_identity: domain.identity, domain_revision: domain.revision, outcome,
    support: [domain.members.length ? bootstrap.result : bootstrap.manifest],
    explanation: 'The declared members have successful matching visits.'});
}

function sourceInventory(archive) {
  return archive.manifest[6].filter(([kind]) => kind === 8).map(([, , body]) => {
    const [, , , program] = decodeValue(archive.schemas.get('workspace_program'), archive.object(body));
    return sha(archive.object(program[1]));
  }).sort();
}

function checkUnrenderedCandidate(exact, use, exposure, change) {
  const {archive, application} = exact;
  const store = (schema, value) => {
    const bytes = Buffer.from(encodeValue(schema, value)), digest = sha(bytes);
    archive.objects.set(digest, bytes);
    return [[...Buffer.from(digest, 'hex')], BigInt(bytes.length)];
  };
  const schema = contract(application, 'AdaptivePrepared');
  const prepared = decodeValue(schema, archive.objects.get(exposure.prepared_sha256));
  const body = JSON.parse(Buffer.from(prepared[2]).toString());
  const part = body.input[exposure.input_index].content[0], envelope = JSON.parse(part.text);
  const blocks = envelope.selected_context_data;
  assert.equal(blocks.length, 1);
  assert.deepEqual(blocks[0].result, use.result);
  assert.deepEqual(blocks[0].value, use.payload);
  if (change === 'missing') blocks.pop();
  else blocks[0].value[0][0] = '0';
  part.text = JSON.stringify(envelope);
  prepared[2] = Buffer.from(JSON.stringify(body));
  const replacement = store(schema, prepared);
  const manifest = [...archive.manifest];
  manifest[6] = manifest[6].map(([kind, id, reference]) => {
    if ((kind !== 4 && kind !== 5) || Buffer.from(id).toString('hex') !== exposure.id) return [kind, id, reference];
    const schema = archive.schemas.get(kind === 4 ? 'capture' : 'attempt');
    const value = decodeValue(schema, archive.object(reference));
    if (kind === 4) value[3] = replacement;
    else value[7].value = replacement;
    return [kind, id, store(schema, value)];
  });
  const observations = structuredClone(exact.observations);
  for (const {report_producer} of observations) {
    if (report_producer?.attempt_id === exposure.id) report_producer.prepared_sha256 = Buffer.from(replacement[0]).toString('hex');
  }
  const trace = adjudicateRepairTrace({...exact, archive: {...archive, manifest}, observations});
  assert.equal(trace.report_bound, true);
  assert.deepEqual(trace.candidate.program, use.program);
  const altered = trace.uses.find(row => row.view.id === use.view.id);
  assert(altered.canonical_input && altered.model_start && altered.model_select);
  const [request] = altered.exposures;
  assert.equal(request.delivery, 'confirmed');
  assert.equal(request.input_index, exposure.input_index);
  assert.equal(request.rendered, false);
  assert(!trace.exposure.some(row => row.ref.id === use.result.id && row.requests?.length));
  assert(trace.ordinary_routes.some(row => row.kind === 'work_result_preview' && row.ref?.id === use.result.id));
  assert.equal(trace.authored_and_applied, false);
}

async function auditEvidence(report, application) {
  const specimen = JSON.parse(await readFile(report.subject.case_path));
  const archive = readArchive(await readFile(report.archive));
  const summary = report.result.outcome.value.result.value.summary;
  const observations = (await readFile(join(report.archive, '..', 'observations.jsonl'), 'utf8'))
    .trimEnd().split('\n').map(line => JSON.parse(line).observation);
  const exact = {archive, application, bootstrap: report.bootstrap, specimen,
    observations, summary, nomination: report.nomination};
  const manifest = JSON.parse(specimen.files['scan.json']);
  const altered = structuredClone(specimen);
  altered.files[manifest.visits[0].path] = '0';
  assert.equal(adjudicateRepairTrace({...exact, specimen: altered}).authored_and_applied, false);
  for (const key of ['identity', 'revision']) {
    const changed = structuredClone(manifest);
    changed.domain[key] = '0';
    const other = {...specimen, files: {...specimen.files, 'scan.json': JSON.stringify(changed)}};
    assert.equal(adjudicateRepairTrace({...exact, specimen: other}).authored_and_applied, false);
  }
  const use = report.adjudication.uses.find(use => use.view.id === report.fixture_receipt.view.id);
  const {exposures} = use;
  assert.equal(exposures.length, 1);
  assert.equal(exposures[0].id, report.adjudication.report_attempt);
  assert.equal(adjudicateRepairTrace(exact).authored_and_applied, true);
  for (const change of ['missing', 'different']) checkUnrenderedCandidate(exact, use, exposures[0], change);
  const unconfirmed = new Set(exposures.map(row => row.id));
  const records = archive.manifest[6].filter(([kind, id]) =>
    kind !== 4 || !unconfirmed.has(Buffer.from(id).toString('hex')));
  const absent = {...archive, manifest: [...archive.manifest]};
  absent.manifest[6] = records;
  const uncertain = adjudicateRepairTrace({...exact, archive: absent});
  assert.equal(uncertain.authored_and_applied, false);
  assert(uncertain.delivery.some(row => unconfirmed.has(row.id) && row.delivery === 'unknown'));
}

export async function checkInterfaceRepair(launch, root, {sources, application:ordinaryApplication, config, scalarProjection}) {
  const directory = join(root, 'directed-repair-plan');
  const preflight = readArchive(await readFile(join(root, 'preflight.agnx')));
  const driver = process.argv[2], applicationPath = process.argv[3];
  const options = {config: {...config, tools: {...config.tools, build: true, run: true},
    adaptive: {...config.adaptive,
    endpoint: 'https://127.0.0.1:1/v1/responses'}}, directory, study: 'comparison',
    binary: driver, driver, applicationPath};
  const checks = {describeBuild: () => preflight.build, validateConfiguration: () => ({valid: true})};
  const plan = await prepareInterfaceRepair(options, checks);
  const unclean = join(root, 'unclean-driver.cjs');
  await writeFile(unclean, '#!/usr/bin/env node\n' +
    'const child = require("node:child_process").spawn('+JSON.stringify(driver)+', process.argv.slice(2), {stdio:"inherit"});\n' +
    'child.on("exit", code => { process.exitCode = code || 7; });\n', {mode:0o700});
  const failedDirectory = join(root, 'unclean-preparation');
  await assert.rejects(prepareInterfaceRepair({...options,driver:unclean,directory:failedDirectory},checks),
    /Offline preparation driver did not exit cleanly/);
  await assert.rejects(readFile(join(failedDirectory,'plan.json')),{code:'ENOENT'});
  const {build} = plan.study_assets;
  const application = JSON.parse(await readFile(plan.study_assets.application.path));
  assert.notEqual(build.program_sha256,preflight.build.program_sha256);
  const rootSource = sha(ordinaryApplication.controller.source_records);
  const baselinePrograms = sourceInventory(preflight);
  assert(baselinePrograms.includes(rootSource));
  baselinePrograms.splice(baselinePrograms.indexOf(rootSource),1,sha(application.controller.source_records));
  baselinePrograms.sort();
  const plan_sha256 = (await readFile(join(directory, 'plan.sha256'), 'utf8')).trim();
  const {author, diagnostic, downstream} = plan.conditions.find(c => c.arm === 'repair');
  await rejectedSubmission(launch, root, author, plan_sha256, sources.lossy, baselinePrograms);
  const fixed = plan.conditions.find(c => c.arm === 'fixed-lossy').downstream[0];
  for (const oversized of [false, true])
    await restartAtSelection(launch, root, fixed, plan_sha256, sources.lossy, oversized);
  for (const large of [false, true])
    await rejectIncompatibleProgram(launch, root, diagnostic, plan_sha256, scalarProjection, large);
  const evidence = plan.conditions.find(c => c.arm === 'evidence').downstream[0];
  await recoverBootstrap(launch, root, evidence, plan_sha256, '', 'ordinary');
  for (const mode of ['projected', 'message', 'early-message', 'cancelled', 'joined'])
    await recoverBootstrap(launch, root, fixed, plan_sha256, sources.lossy, mode);
  const episode = async (subject, candidate = null) => {
    const output = join(root, 'result-' + subject.id);
    await mkdir(output);
    const report = await executeRepairTask({subject, plan, plan_sha256, driver, application,
      build, output, deadline: performance.now() + 60000, candidate}, {scripted: true, scriptedAnswer,
      Client: subject.phase === 'author' ? CheckedBootstrapClient : RecurrenceDriver});
    assert.deepEqual(report.errors, [], subject.id + ': ' + JSON.stringify(report.errors));
    assert.equal(report.timed_out, false);
    assert.equal(report.execution_mode, 'scripted_fixture');
    assert.equal(report.cost.live_provider_attempts, 0);
    const bytes = await readFile(report.archive);
    assert.equal(bytes.includes(Buffer.from(sources.adequate)), subject.arm === 'fixed-adequate');
    const allowed = subject.phase === 'author' ? [sources.lossy, report.fixture_receipt.source] :
      subject.arm === 'evidence' ? [] : [subject.arm === 'fixed-adequate' ? sources.adequate :
        subject.arm === 'fixed-lossy' ? sources.lossy : Buffer.from(candidate.source_b64, 'base64').toString()];
    assert.deepEqual(sourceInventory(readArchive(bytes)), [...baselinePrograms, ...allowed.map(sha)].sort());
    return report;
  };
  const development = await episode(author);
  const trace = development.adjudication;
  assert.equal(development.recovery.task_id, development.task.task_id);
  assert.deepEqual(development.recovery.selected_view, development.bootstrap.view);
  assert.notEqual(development.recovery.before, development.recovery.after);
  assert.equal(development.recovery.inference_attempts_before_first_use, 0);
  assert.equal(trace.report_bound, true);
  assert.deepEqual(trace.applied_use.view, development.fixture_receipt.view);
  assert.equal(development.controlled_application_path, true);
  assert.equal(trace.authored_and_applied, false);
  const {candidate} = trace;
  assert.deepEqual(candidate.program, development.fixture_receipt.program);
  assert.equal(Buffer.from(candidate.source_b64, 'base64').toString(), development.fixture_receipt.source);
  const projected = trace.uses.find(use => use.view.id === development.fixture_receipt.view.id);
  const forged = trace.uses.find(use => use.view.id === development.fixture_receipt.invalid_view.id);
  assert(forged.model_start && forged.model_select && forged.exposures.some(row => row.rendered));
  assert.equal(forged.canonical_input, false);
  assert.equal(forged.semantic_judgment, 'unestablished');
  assert(projected?.model_start && projected.model_select && projected.one_computed_block);
  assert.equal(projected.canonical_input, true);
  assert.equal(projected.semantic_judgment, 'supported');
  assert(projected.exposures.some(row => row.rendered && row.delivery === 'confirmed'));
  const first = trace.delivery.toSorted((left, right) =>
    BigInt(left.preparation_cut) < BigInt(right.preparation_cut) ? -1 : 1)[0];
  assert.equal(first.selected_view, development.bootstrap.view.id);
  assert(trace.projection.exposures.some(row => row.id === first.id && row.rendered));
  await auditEvidence(development, application);
  await rejectedProjection(launch, root, diagnostic, downstream[0], plan_sha256, development.fixture_receipt.source);
  await rejectedPreparation(root, downstream[0], {candidate, plan, plan_sha256, driver, application, build});
  await recoverBootstrap(launch, root, diagnostic, plan_sha256,
    Buffer.from(candidate.source_b64, 'base64').toString(), 'diagnostic', candidate.program.id);
  const probe = await episode(diagnostic, candidate);
  assert.equal(probe.bootstrap.view, null);
  assert.equal(probe.adjudication.delivery.length, 0);
  assert.equal(probe.adjudication.collision.distinction_preserved, true);
  assert.deepEqual(probe.adjudication.collision.left.consumer, probe.adjudication.collision.right.consumer);
  const transferred = await episode(downstream[0], candidate);
  assert.equal(transferred.adjudication.transfer_bound, true);
  assert.notEqual(transferred.bootstrap.consumer.id, development.bootstrap.consumer.id);
  assert.equal(transferred.grading?.supported, true);
  assert.equal(transferred.adjudication.ordinary_fallback, true);
  const archive = readArchive(await readFile(transferred.archive));
  const specimen = JSON.parse(await readFile(transferred.subject.case_path));
  const bootstrap = {...transferred.bootstrap, consumer: development.bootstrap.consumer};
  assert.equal(adjudicateRepairTrace({archive, application, specimen, candidate, bootstrap}).transfer_bound, false);
  for (const arm of ['fixed-lossy', 'fixed-adequate', 'evidence']) {
    const condition = plan.conditions.find(c => c.arm === arm);
    const control = await episode(condition.downstream[8]);
    assert.equal(control.grading.supported, true);
    assert.equal(control.adjudication.ordinary_fallback, true);
    if (arm === 'evidence') {
      assert.equal(control.bootstrap.view, null);
      assert.equal(control.adjudication.uses.length, 0);
    } else {
      assert.equal(control.adjudication.projection.canonical_input, true);
      assert.equal(control.adjudication.projection.known_lossy, arm === 'fixed-lossy');
      assert.equal(control.adjudication.projection.semantic_judgment,
        arm === 'fixed-adequate' ? 'supported' : 'unestablished');
    }
  }
}
