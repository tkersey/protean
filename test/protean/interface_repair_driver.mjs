import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdir, readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {prepareInterfaceRepair} from '../../tools/evaluation/interface_repair_campaign.mjs';
import {executeRepairTask} from '../../tools/evaluation/interface_repair_task.mjs';
import {assessScan} from '../../tools/evaluation/interface_repair.mjs';
import {readArchive} from './native_archive.mjs';
import {decodeValue} from '../support/values.mjs';
import {adjudicateRepairTrace} from '../../tools/evaluation/interface_repair_trace.mjs';
import {RecurrenceDriver} from '../../tools/evaluation/workspace.mjs';

const bootstrapMethod = 'evaluation.interface_repair.bootstrap';
const sha = text => createHash('sha256').update(text).digest('hex');

class CheckedBootstrapClient extends RecurrenceDriver {
  async call(method, params) {
    if (method !== bootstrapMethod) return super.call(method, params);
    await assert.rejects(super.call(method, {...params, descriptor: params.descriptor + ' '}), /ChangedPlan/);
    await assert.rejects(super.call(method, {...params, source: params.source + ' '}), /ChangedProgram/);
    const result = await super.call(method, params);
    await assert.rejects(super.call(method, params), /InitialCutRequired/);
    return result;
  }
}

async function rejectedSubmission(launch, root, author, plan_sha256, source, baselinePrograms) {
  const descriptor = JSON.stringify({version: 1, plan_sha256, submission_id: author.id,
    prompt_sha256: sha(author.prompt), phase: 'author', condition: 'repair',
    files: author.evidence, source_sha256: sha(source)});
  const child = launch(null, 'changed-prompt', ['--fixture-workspace', '--config', author.config,
    '--interface-repair-bootstrap', sha(descriptor)]);
  try {
    const {profile} = await child.call('describe');
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
  const exposures = report.adjudication.uses.find(use => use.view.id === report.fixture_receipt.view.id).exposures;
  const unconfirmed = new Set(exposures.map(row => row.id));
  const records = archive.manifest[6].filter(([kind, id]) =>
    kind !== 4 || !unconfirmed.has(Buffer.from(id).toString('hex')));
  const absent = {...archive, manifest: [...archive.manifest]};
  absent.manifest[6] = records;
  const uncertain = adjudicateRepairTrace({...exact, archive: absent});
  assert.equal(uncertain.authored_and_applied, false);
  assert(uncertain.delivery.some(row => unconfirmed.has(row.id) && row.delivery === 'unknown'));
}

export async function checkInterfaceRepair(launch, root, {sources, application, config}) {
  const directory = join(root, 'directed-repair-plan');
  const preflight = readArchive(await readFile(join(root, 'preflight.agnx')));
  const {build} = preflight, baselinePrograms = sourceInventory(preflight);
  const driver = process.argv[2], applicationPath = process.argv[3];
  const plan = await prepareInterfaceRepair({config: {...config, adaptive: {...config.adaptive,
    endpoint: 'https://127.0.0.1:1/v1/responses'}}, directory, study: 'comparison',
    binary: driver, driver, applicationPath},
  {describeBuild: () => build, exportSources: () => sources, validateConfiguration: () => ({valid: true})});
  const plan_sha256 = (await readFile(join(directory, 'plan.sha256'), 'utf8')).trim();
  const {author, diagnostic, downstream} = plan.conditions.find(c => c.arm === 'repair');
  await rejectedSubmission(launch, root, author, plan_sha256, sources.lossy, baselinePrograms);
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
      assert.equal(control.adjudication.projection.semantic_judgment,
        arm === 'fixed-adequate' ? 'supported' : 'unestablished');
    }
  }
}
