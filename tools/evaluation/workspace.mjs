// Live model-use evaluation is opt-in; native fixtures reuse the offline helpers.
import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile, appendFile, readdir, stat, realpath} from 'node:fs/promises';
import {resolve, join, dirname} from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {createInterface} from 'node:readline';
import {createHash} from 'node:crypto';
import {ProteanClient} from '../../test/support/stdio-client.mts';
import {readArchive} from '../../test/protean/native_archive.mjs';
import {decodeSchema, decodeValue} from '../../test/support/values.mjs';
import {contract} from '../../test/protean/adaptive_capture_checks.mjs';
import {createCorpus, gradeReport, compareCampaign, parseReport, campaignIdentity} from './recurrence.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const json = value => JSON.stringify(value, (_key, v) => typeof v === 'bigint' ? v.toString() : v, 2);
const arms = {
  ordinary: 'Use ordinary source listing, reading, inspection and reporting. Do not construct programs or use program, work or context actions.',
  pure: 'You may construct general pure programs and use their completed results as tools. Build with no exposed ports, start with terminal/owner_scheduled policy, wait for completion and collect the results. Work actions are limited to start, wait and collect, including when sent through placement.control. Do not materialize guest_view, use retained intermediate observations, or branch. Ordinary tools remain available.',
  retained: 'You may use ordinary tools and the full computational workspace. Whether to construct, retain, expose ports, branch or delegate is your choice.',
};
const reconstructionArms = {
  retained: 'Use ordinary tools and the retained computational workspace. Controller replacement is unavailable in this comparison arm.',
  reconstruction: 'You may inspect the active controller, build a controller from general source, optionally try it, and adopt it through a pure carry conversion. Choose whether reconstruction helps this task. Ordinary tools, existing work and choosing no replacement remain available.',
};
const runtimeArms = {
  ordinary: arms.ordinary,
  generic: 'You may use ordinary tools and the full retained computational workspace with the packaged generic runtime. Do not specialize a program, select another runtime, switch realization, or materialize a guest_view. This condition leaves ordinary evidence access and guest execution available.',
  runtime: 'You may use ordinary tools, the retained computational workspace, approved specialization, runtime switching, and executable runtime views or hypothetical analysis. Choose whether any of these help the task; they are optional. Include construction and inspection costs when judging reuse, and change your approach if broader evidence contradicts the current investigation.',
};
const semanticArms = {
  specialization: 'You may use ordinary tools, retained work, and built-in program specialization and runtime selection. Do not inspect or materialize semantic source, construct programmable observations or interpretations, derive or validate candidates, or use guarded execution.',
  interpretation: 'You may use ordinary tools, retained work, exact semantic source, programmable observations, and isolated interpretations. These capabilities are optional. Do not specialize, derive or validate runtime candidates, select another runtime, switch realization, or use guarded execution.',
  construction: 'You may use ordinary tools and all permitted semantic construction capabilities: exact source, programmable observations, isolated interpretations, generated transformers, candidate validation, guarded experiments and qualified realization selection. Choose whether any help this task; declining them or abandoning an unsuccessful candidate is allowed. Include all construction, validation, reference and observation costs.',
};
const option = (args, name, fallback) => { const i = args.indexOf(name); return i < 0 ? fallback : args[i + 1]; };
const [mode, ...args] = process.argv.slice(2);
if (import.meta.main && !['prepare', 'run'].includes(mode)) {
  console.log('prepare --config CONFIG --out DIRECTORY [--suite workspace|runtime|reconstruction|semantic|recurrence] [--repetitions 1] [--seconds 600]\nrecurrence preparation also requires --binary BINARY --driver DRIVER --application APPLICATION_JSON [--cost-model JSON]\nrun --plan DIRECTORY --binary BINARY --application APPLICATION_JSON [--driver DRIVER] --authorize-inference (--credential-file PRIVATE_FILE | --chatgpt-account ACCOUNT)');
  process.exit(mode === '--help' || !mode ? 0 : 2);
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function workspaceAction(action) {
  const command = action.arguments?.command;
  if (action.name === 'placement') {
    if (command?.tag === 'control') return {name: 'work', command: command.value?.command};
    if (['inspect', 'expand'].includes(command?.tag)) return {name: 'work', command};
  }
  return {name: action.name, command};
}
export function armViolations(arm, actions) {
  return actions.filter(action => {
    if (arm === 'ordinary') return ['program', 'work', 'context', 'placement'].includes(action.name);
    const {name, command} = workspaceAction(action);
    const guestView = (name === 'context' && command?.tag === 'materialize' && command.value?.input?.tag === 'guest_view') ||
      (name === 'work' && command?.tag === 'observe');
    const replacement = name === 'work' && (['realize', 'realize_controller', 'guard'].includes(command?.tag) ||
      (command?.tag === 'start' && command.value?.runtime?.tag === 'selected'));
    const candidate = name === 'program' && ['derive', 'validate'].includes(command?.tag);
    if (arm === 'recurrence') return replacement ||
      (name === 'program' && command?.tag === 'specialize') || action.name === 'reconstruct';
    if (arm === 'interpretation') return replacement || candidate || (name === 'program' && command?.tag === 'specialize');
    if (arm === 'specialization') return candidate || guestView ||
      (name === 'work' && command?.tag === 'guard') ||
      (name === 'program' && command?.tag === 'inspect' && command.value?.target?.tag === 'semantic_source') ||
      (name === 'context' && command?.tag === 'materialize' && command.value?.input?.tag === 'semantic_source');
    if (arm === 'generic') return replacement ||
      (name === 'program' && command?.tag === 'specialize') || guestView;
    if (arm !== 'pure') return false;
    if (guestView) return true;
    if (name === 'program') return command?.tag === 'build' && command.value?.exposures?.length;
    if (name !== 'work') return false;
    return !['start', 'wait', 'collect'].includes(command?.tag) ||
      (command?.tag === 'start' && (command.value?.policy?.stop !== 'terminal' || command.value?.policy?.continuation !== 'owner_scheduled'));
  });
}
function guardCosts(archive) {
  const previous = new Map();
  let reference = 0, candidate = 0;
  const events = [...archive.manifest[7]].sort((left, right) => left[0] < right[0] ? -1 : left[0] > right[0] ? 1 : 0);
  for (const row of events) {
    const event = decodeValue(archive.schemas.get('event'), archive.object(row[2]));
    for (const publication of event[5]) {
      const work = Buffer.from(publication[0]).toString('hex'), guard = publication[12];
      if (guard.tag === 0) { previous.delete(work); continue; }
      const value = guard.value;
      const id = Buffer.from(value[0][0]).toString('hex');
      const current = {id, reference: Number(value[10]), candidate: Number(value[11])};
      const prior = previous.get(work);
      const continuing = prior?.id === id && value[2] !== 0n;
      if (continuing) assert(current.reference >= prior.reference && current.candidate >= prior.candidate);
      reference += current.reference - (continuing ? prior.reference : 0);
      candidate += current.candidate - (continuing ? prior.candidate : 0);
      previous.set(work, current);
    }
  }
  return {reference, candidate};
}
function command(binary, args) {
  const r = spawnSync(binary, args, {encoding: 'utf8', maxBuffer: 64 << 20});
  if (r.status !== 0) throw new Error(`native command ${args[0]} failed: ${r.stderr}`);
  return JSON.parse(r.stdout);
}
async function bytesUnder(path) {
  let bytes = 0;
  for (const item of await readdir(path, {withFileTypes: true})) {
    const file = join(path, item.name);
    if (item.isDirectory()) bytes += await bytesUnder(file);
    else if (item.isFile()) bytes += (await stat(file)).size;
  }
  return bytes;
}
function capturedUsage(raw) {
  const bytes = new TextDecoder('utf-8', {fatal: true}).decode(raw[3]);
  if (raw[7] !== 2) return null;
  if (raw[4] === 0) return JSON.parse(bytes)?.usage;
  if (raw[4] !== 1 || raw[0] < 200 || raw[0] >= 300 || !raw[1]) return null;
  const frames = bytes.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n\n');
  for (const frame of frames.slice(0, -1)) {
    const data = frame.split('\n').filter(line => line === 'data' || line.startsWith('data:'))
      .map(line => line.slice(5).replace(/^ /, '')).join('\n');
    if (!data) continue;
    const event = JSON.parse(data);
    if (['response.completed', 'response.failed', 'response.incomplete'].includes(event.type)) return event.response?.usage;
    if (event.type === 'error') return null;
  }
  return null;
}

export function physicalProviderAttempt(id, disposition, state) {
  if (disposition !== undefined) return disposition !== 1;
  if (!state) return true;
  if ([0, 6].includes(state.tag)) return false;
  if ([1, 2, 3, 4, 7].includes(state.tag)) return digestHex(state.value[0]) === id;
  if (state.tag === 5) return state.value.tag !== 1 && digestHex(state.value.value[0]) === id;
  throw new Error('Unknown occurrence state');
}

export function workspaceMetrics(archive, application) {
  const captured = contract(application, 'CapturedResponse');
  const replySchema = contract(application, 'WorkspaceReply');
  const adaptiveResult = contract(application, 'AdaptiveResult');
  const adaptivePrepared = contract(application, 'AdaptivePrepared');
  const attempts = new Map(archive.manifest[6].filter(([kind]) => kind === 5).map(([, id, ref]) => [Buffer.from(id).toString('hex'), decodeValue(archive.schemas.get('attempt'), archive.object(ref))]));
  const captures = new Map(archive.manifest[6].filter(([kind]) => kind === 4).map(([, id, ref]) => [Buffer.from(id).toString('hex'), decodeValue(archive.schemas.get('capture'), archive.object(ref))]));
  const occurrences = new Map(archive.manifest[6].filter(([kind]) => kind === 0).map(([, id, ref]) => [Buffer.from(id).toString('hex'), decodeValue(archive.schemas.get('occurrence'), archive.object(ref))]));
  const stats = {controller: {calls: 0, input_tokens: 0, output_tokens: 0, missing_usage: 0, prepared_bytes: 0}, delegated: {calls: 0, input_tokens: 0, output_tokens: 0, missing_usage: 0, prepared_bytes: 0}, builds: 0, rejected_builds: 0, compiler_nanoseconds: 0, native_publication_nanoseconds: 0, checkpoint_publications: 0, current_checkpoint_bytes: 0, work_items: 0, result_bytes: 0, actions: [], physical_attempts: [],
    runtime_specializations_requested: 0, runtime_switches_requested: 0, guest_views_requested: 0,
    controller_adoptions: 0, rejected_adoptions: 0, controller_trials: 0, conversion_publication_nanoseconds: 0,
    admitted_runtimes: 0, distinct_runtime_artifact_bytes: 0, distinct_current_runtime_capsule_bytes: 0,
    runtime_specialization_nanoseconds: null, runtime_validation_nanoseconds: null,
    semantic_derivations_requested: 0, semantic_validations_requested: 0,
    guards_requested: 0, observers_requested: 0, candidate_artifacts: 0,
    distinct_candidate_code_bytes: 0, validated_candidates: 0, unvalidated_candidates: 0,
    guard_reference_nanoseconds: 0, guard_candidate_nanoseconds: 0};
  const conversions = new Set();
  for (const [kind,, reference] of archive.manifest[6]) {
    if (kind === 30) stats.controller_trials++;
    if (kind !== 27) continue;
    const succession = decodeValue(archive.schemas.get('controller_succession'), archive.object(reference));
    assert.equal(succession.length, 23);
    if (succession[17] === 2) stats.controller_adoptions++;
    if ([3, 4, 5, 6].includes(succession[17])) stats.rejected_adoptions++;
    if (succession[14].tag === 1) conversions.add(Buffer.from(succession[14].value).toString('hex'));
  }
  const runtimeArtifacts = new Map();
  const runtimeCapsules = new Map();
  const candidateCode = new Map();
  const candidates = new Set();
  const validatedCandidates = new Set();
  const semanticObservationSchema = {root: 0, types: [{product: [1, 1, 3]}, {sum: [2, 3]}, 'unit', {product: [4, 6]}, {array: {element: 5, length: 32}}, 'u8', 'u64']};
  for (const [,, reference] of archive.manifest[8]) {
    const receipt = decodeValue(archive.schemas.get('receipt'), archive.object(reference));
    if (receipt[11].tag !== 1 || receipt[11].value !== 10 || receipt[12].tag !== 1) continue;
    const observation = decodeValue(semanticObservationSchema, archive.object(receipt[12].value));
    if (observation[0].tag === 1 && observation[1].tag === 1)
      validatedCandidates.add(Buffer.from(observation[0].value[0]).toString('hex'));
  }
  const actions = [];
  // Count possible provider delivery, including unknown delivery, but exclude
  // positive non-invocation evidence. Rearming an occurrence is only permitted
  // from not_sent, so older uncaptured attempts are also known not to have run.
  for (const [id, attempt] of attempts) {
    const role = attempt[5] === 'agent.model.invoke.v13' ? 'controller' : attempt[5] === 'protean.workspace.inference/2' ? 'delegated' : null;
    if (!role) continue;
    const capture = captures.get(id);
    const occurrence = occurrences.get(Buffer.from(attempt[2]).toString('hex'));
    const state = occurrence?.[3];
    const count = stats[role];
    if (attempt[7].tag === 1) count.prepared_bytes += Number(attempt[7].value[1]);
    if (!physicalProviderAttempt(id, capture?.[5], state)) continue;
    count.calls++;
    const physical = {id, role, usage: null, capture_disposition: capture?.[5] ?? null};
    stats.physical_attempts.push(physical);
    if (!capture || capture[4].tag !== 1) { count.missing_usage++; continue; }
    const raw = decodeValue(captured, archive.object(capture[4].value));
    // Capture precedes response interpretation: HTTP errors and malformed
    // provider output still incurred a call, but supply no usable usage.
    let usage;
    try { usage = capturedUsage(raw); } catch { usage = null; }
    physical.usage = usage ?? null;
    const known = value => Number.isSafeInteger(value) && value >= 0;
    if (!known(usage?.input_tokens) || !known(usage?.output_tokens)) count.missing_usage++;
    if (known(usage?.input_tokens)) count.input_tokens += usage.input_tokens;
    if (known(usage?.output_tokens)) count.output_tokens += usage.output_tokens;
    // Costs come from raw captures; actions come only from the native
    // normalized result that the controller actually received.
    if (role === 'controller' && capture[6].tag === 1) {
      const normalized = decodeValue(adaptiveResult, resultValue(archive.object(capture[6].value[0])));
      const result = normalized[0];
      const calls = result.tag === 0 ? result.value[0].filter(item => item.tag === 0) : [];
      // This application's authored single-action admission also requires a
      // decoded, offered declaration and complete replay. Rejected proposals
      // are not actions, even inside a successfully normalized response.
      if (normalized[1].tag === 1 && normalized[2] === 0 && calls.length === 1) {
        const call = calls[0].value, ordinal = call[3];
        const request = decodeValue(adaptivePrepared, archive.object(attempt[7].value))[1];
        if (call[4].tag === 0 && call[4].value.tag === ordinal && request[5][ordinal] &&
            request[0][4].some(tool => tool[0] === ordinal && tool[2] === call[1])) {
          actions.push({watermark: BigInt(request[3][2]), action: {name: call[1], arguments: JSON.parse(Buffer.from(call[2]).toString())}});
        }
      }
    }
  }
  // Archive records are ordered by kind and random identity. The retained
  // controller request carries the causal model-call watermark across restart.
  stats.actions = actions.sort((a, b) => a.watermark < b.watermark ? -1 : a.watermark > b.watermark ? 1 : 0).map(item => item.action);
  for (const action of stats.actions) {
    const {name, command} = workspaceAction(action);
    if (name === 'program' && command?.tag === 'specialize') stats.runtime_specializations_requested++;
    if (name === 'program' && command?.tag === 'derive') stats.semantic_derivations_requested++;
    if (name === 'program' && command?.tag === 'validate') stats.semantic_validations_requested++;
    if (name === 'work' && command?.tag === 'guard') stats.guards_requested++;
    if (name === 'work' && command?.tag === 'observe') stats.observers_requested++;
    if (name === 'work' && ['realize', 'realize_controller'].includes(command?.tag)) stats.runtime_switches_requested++;
    if (name === 'context' && command?.tag === 'materialize' && command.value?.input?.tag === 'guest_view') stats.guest_views_requested++;
  }
  for (const [kind, id, reference] of archive.manifest[6]) {
    if (kind === 18) {
      const selected = decodeValue(archive.schemas.get('workspace_runtime'), archive.object(reference));
      assert.equal(selected.length, 5);
      stats.admitted_runtimes++;
      runtimeArtifacts.set(Buffer.from(selected[3][0]).toString('hex'), Number(selected[3][1]));
      if (selected[4].tag === 1) validatedCandidates.add(Buffer.from(selected[4].value[1][0]).toString('hex'));
    }
    if (kind === 31) {
      const candidate = decodeValue(archive.schemas.get('workspace_candidate'), archive.object(reference));
      candidates.add(Buffer.from(candidate[3][0]).toString('hex'));
      const code = candidate[4][4];
      candidateCode.set(Buffer.from(code[0]).toString('hex'), Number(code[1]));
      stats.candidate_artifacts++;
    }
    if (kind === 9) {
      const work = decodeValue(archive.schemas.get('workspace_work'), archive.object(reference));
      assert.equal(work[0], 3);
      assert.equal(work.length, 39);
      stats.work_items++; stats.native_publication_nanoseconds += Number(work[34]);
      if (conversions.has(Buffer.from(work[1]).toString('hex'))) stats.conversion_publication_nanoseconds += Number(work[34]);
      stats.checkpoint_publications += Number(work[20]);
      stats.current_checkpoint_bytes += Number(work[17][1]);
      for (const ref of [work[11].tag === 1 ? work[11].value : null, work[12].tag === 1 ? work[12].value[1] : null, work[13].tag === 1 ? work[13].value[0] : null])
        if (ref) runtimeCapsules.set(Buffer.from(ref[0]).toString('hex'), Number(ref[1]));
      if (work[28].tag === 1) stats.result_bytes += Number(work[28].value[1]);
    }
    if (kind !== 4) continue;
    const attempt = attempts.get(Buffer.from(id).toString('hex'));
    const capture = decodeValue(archive.schemas.get('capture'), archive.object(reference));
    if (attempt[8] === 1) {
      stats.builds++;
      if (capture[6].tag !== 1) continue;
      const reply = decodeValue(replySchema, resultValue(archive.object(capture[6].value[0])));
      const observation = JSON.parse(Buffer.from(reply[1]).toString());
      stats.compiler_nanoseconds += Number(observation.compiler_nanoseconds ?? 0);
      if (observation.error) stats.rejected_builds++;
      if (observation.validation === 'validated' && observation.candidate?.kind === 'candidate' &&
          /^[0-9a-f]{64}$/.test(observation.candidate.id) && observation.runtime?.kind === 'runtime' &&
          /^[0-9a-f]{64}$/.test(observation.runtime.id)) validatedCandidates.add(observation.candidate.id);
      continue;
    }
  }
  stats.distinct_runtime_artifact_bytes = [...runtimeArtifacts.values()].reduce((sum, bytes) => sum + bytes, 0);
  stats.distinct_current_runtime_capsule_bytes = [...runtimeCapsules.values()].reduce((sum, bytes) => sum + bytes, 0);
  stats.distinct_candidate_code_bytes = [...candidateCode.values()].reduce((sum, bytes) => sum + bytes, 0);
  stats.validated_candidates = [...candidates].filter(id => validatedCandidates.has(id)).length;
  stats.unvalidated_candidates = candidates.size - stats.validated_candidates;
  const guard = guardCosts(archive);
  stats.guard_reference_nanoseconds = guard.reference;
  stats.guard_candidate_nanoseconds = guard.candidate;
  return stats;
}

const resultSchema = {root: 0, types: [{product: [1, 3]}, {array: {element: 2, length: 32}}, 'u8', 'bytes']};
function resultValue(bytes) {
  assert.equal(bytes.subarray(0, 8).toString(), 'ABL_ERS3');
  assert.equal(bytes.readBigUInt64LE(12), BigInt(bytes.length - 20));
  return Buffer.from(decodeValue(resultSchema, bytes.subarray(20))[1]);
}

// Return an observation even when the runner fails after a potentially paid
// dispatch. The caller persists it before stopping; it never retries inference.
export async function evaluateCase({subject, build, output, binary, credential, application, seconds}, {Client = ProteanClient, runCommand = command} = {}) {
  const state = join(output, 'state');
  let client, result = null, status = null, task = null, peakRss = 0;
  const errors = [], record = (stage, error) => errors.push({stage, name: error.name, message: error.message});
  const started = performance.now();
  try {
    client = new Client(binary, ['--config', subject.config, '--authorize-inference', '--credential-file', resolve(credential), '--state-dir', state]);
    await client.initialize(); const description = await client.call('describe');
    task = await client.call('task.submit', {client_operation_id: subject.id, application_id: 'adaptive-agent', profile_id: description.profile.id, input: {schema_id: 'adaptive-agent.input.v2', value: {task: subject.prompt}}});
    for (;;) {
      status = await client.call('task.status', {task_id: task.task_id});
      const ps = spawnSync('ps', ['-o', 'rss=', '-p', String(client.child.pid)], {encoding: 'utf8'});
      if (ps.status === 0) peakRss = Math.max(peakRss, Number(ps.stdout.trim()) * 1024);
      if (['completed', 'failed', 'cancelled', 'unknown', 'blocked'].includes(status.status) || status.question || performance.now() - started >= seconds * 1000) break;
      await pause(100);
    }
    if (!['completed', 'failed', 'cancelled', 'unknown', 'blocked'].includes(status.status)) await client.call('task.cancel', {client_operation_id: subject.id + '-end', task_id: task.task_id, reason: 'Evaluation boundary: preserve unanswered state and stop further work.'});
    result = await client.call('task.result', {task_id: task.task_id});
    if (result.outcome?.value_ref) {
      const ref = result.outcome.value_ref, chunks = []; let offset = '0';
      for (;;) {
        const chunk = await client.call('artifact.read', {task_id: task.task_id, artifact_id: ref.artifact_id, offset, length: '32768'});
        assert.equal(chunk.sha256, ref.sha256); chunks.push(Buffer.from(chunk.data, 'base64url')); offset = chunk.next_offset;
        if (chunk.eof) break;
      }
      const bytes = Buffer.concat(chunks); assert.equal(hash(bytes), ref.sha256); assert.equal(BigInt(bytes.length), BigInt(ref.bytes));
      result.outcome.value = JSON.parse(bytes.toString());
    }
  } catch (error) { record('execution', error); }
  finally {
    if (client) try {
      const exit = await client.close();
      if (exit.code !== 0 || exit.signal !== null) throw new Error(`Native process exited with code ${exit.code}, signal ${exit.signal}`);
    } catch (error) { record('close', error); }
  }
  const elapsed_ms = performance.now() - started;
  let retained_namespace_bytes = null, metrics = null, archive = null;
  try { retained_namespace_bytes = await bytesUnder(state); } catch (error) { record('namespace', error); }
  if (task) {
    const archivePath = join(output, 'task.agnx');
    try {
      await runCommand(binary, ['export-checkpoint', '--config', subject.config, '--state-dir', state, '--task-id', task.task_id, '--output', archivePath]);
      archive = archivePath;
      metrics = workspaceMetrics(readArchive(await readFile(archivePath)), application);
    } catch (error) { record('measurements', error); }
  }
  const report = {subject, build, task, elapsed_ms, peak_rss_sampled_bytes: peakRss, retained_namespace_bytes, status, result, archive, metrics,
    arm_violations: metrics ? armViolations(subject.arm, metrics.actions) : null, errors,
    adjudication: {task_correctness: null, evidence_coverage: null, successful_reframing: null, unnecessary_construction: null, branch_executions_not_used: null,
      runtime_selection_appropriate: null, economic_benefit_including_setup: null,
      notes: 'Review expected.json, result and actions. Do not count scripted conformance traces as model efficacy. Missing usage or metrics is unknown, not zero.'}};
  await writeFile(join(output, 'report.json'), json(report));
  return report;
}

// Bind every prepared input before opening an attempt, including the oracle
// used later for manual adjudication. Reports retain these identities in subject.
export async function validatePreparedCase(subject) {
  assert.equal(hash(await readFile(subject.config)), subject.config_sha256, 'Prepared configuration changed; prepare a new comparison.');
  assert.deepEqual((await readdir(subject.snapshot)).sort(), subject.evidence.map(item => item.path).sort(), 'Evidence universe changed.');
  for (const item of subject.evidence) assert.equal(hash(await readFile(join(subject.snapshot, item.path))), item.sha256, 'Frozen evidence changed.');
  assert.equal(hash(await readFile(subject.expected)), subject.expected_sha256, 'Expected answers changed or are unbound; prepare a new comparison.');
}

export const recurrenceLimits = Object.freeze({wall_ms: 2700000, tokens: 512000,
  provider_attempts: 128, namespace_bytes: 1073741824, rss_bytes: 4294967296});
const queuedReminder = 'Inputs have already been queued for this task. Consume the queued inputs before asking for more.';
const recurrenceQuestions = Object.freeze({'Please send the next request.': {kind: 'wait'}});

export async function prepareRecurrence({config, directory, binary, driver, applicationPath,
  costModel = {kind: 'unpriced', currency: 'USD'}, intervalMs = 180000,
  limits = recurrenceLimits, questions = recurrenceQuestions}) {
  assert.equal(config.schema, 'adaptive-agent.configuration.v3');
  assert(Number.isSafeInteger(intervalMs) && intervalMs > 0 && intervalMs * 11 < limits.wall_ms);
  for (const limit of Object.values(limits)) assert(Number.isSafeInteger(limit) && limit > 0);
  for (const response of Object.values(questions))
    assert(response?.kind === 'wait' || (response?.kind === 'fact' && typeof response.text === 'string'));
  const profile = config.adaptive.profiles.find(p => p.id === config.adaptive.initial_profile);
  assert(profile && profile.efforts.includes(config.adaptive.initial_effort));
  const frozen = {...config, adaptive: {...config.adaptive, profiles: [{...profile,
    efforts: [config.adaptive.initial_effort], effort_update: false}], skills: []}};
  const identities = {binary_sha256: hash(await readFile(binary)),
    driver_sha256: hash(await readFile(driver)), application_sha256: hash(await readFile(applicationPath)),
    oracle_sha256: hash(await readFile(new URL('./recurrence.mjs', import.meta.url))),
    evaluator_sha256: hash(await readFile(new URL('./workspace.mjs', import.meta.url)))};
  await mkdir(directory);
  directory = await realpath(directory);
  const plan = {format: 'protean-recurrence-evaluation/1', suite: 'recurrence',
    identities, limits, cost_model: costModel, questions, queued_reminder: queuedReminder,
    profile: frozen.adaptive.profiles[0], initial_effort: frozen.adaptive.initial_effort,
    efficacy: 'unmeasured', cases: []};
  for (let pair = 0; pair < 3; pair++) {
    const corpus = structuredClone(createCorpus(pair + 1));
    for (let i = 0; i < corpus.packets.length; i++) corpus.packets[i].offset_ms = i * intervalMs;
    const pairRoot = join(directory, `pair-${pair + 1}`), snapshot = join(pairRoot, 'snapshot');
    await mkdir(snapshot, {recursive: true});
    const corpusPath = join(pairRoot, 'corpus.json'), corpusBytes = json(corpus);
    const expectedPath = join(pairRoot, 'expected.json'), expectedBytes = json(corpus.expected);
    await writeFile(corpusPath, corpusBytes, {flag: 'wx'});
    await writeFile(expectedPath, expectedBytes, {flag: 'wx'});
    const initial = {'contract.txt': corpus.contract, 'initial.txt': corpus.packets[0].bytes};
    for (const [name, bytes] of Object.entries(initial)) await writeFile(join(snapshot, name), bytes, {flag: 'wx'});
    const evidence = Object.entries(initial).map(([path, bytes]) => ({path, sha256: hash(bytes)}));
    for (const arm of pair === 1 ? ['ordinary', 'treatment'] : ['treatment', 'ordinary']) {
      const id = `pair-${pair + 1}-${arm}`, configPath = join(directory, `${id}.json`);
      const selected = {...frozen, adaptive: {...frozen.adaptive, snapshot_root: snapshot},
        tools: {...frozen.tools, build: arm === 'treatment', run: arm === 'treatment', reconstruct: false, inputs: []}};
      const configBytes = json(selected);
      await writeFile(configPath, configBytes, {flag: 'wx'});
      const condition = arm === 'ordinary' ? arms.ordinary :
        'Ordinary tools and retained workspace operations are available. Use the packaged runtime. Controller reconstruction and runtime replacement are unavailable.';
      plan.cases.push({id, pair: pair + 1, arm, config: configPath, config_sha256: hash(configBytes),
        snapshot, evidence, expected: expectedPath, expected_sha256: hash(expectedBytes),
        corpus: corpusPath, corpus_sha256: hash(corpusBytes),
        end_packet: {id: corpus.packets.at(-1).id, offset_ms: corpus.packets.at(-1).offset_ms},
        prompt: `${corpus.contract}\n\n${corpus.packets[0].bytes}\n\nEvaluation capability condition: ${condition}`});
    }
  }
  await writeFile(join(directory, 'plan.json'), json(plan), {flag: 'wx'});
  await writeFile(join(directory, 'plan.sha256'), hash(json(plan)) + '\n', {flag: 'wx'});
  return plan;
}

export async function validateRecurrencePlan(directory, {binary, driver, applicationPath}) {
  const bytes = await readFile(join(directory, 'plan.json'));
  assert.equal(hash(bytes), (await readFile(join(directory, 'plan.sha256'), 'utf8')).trim(), 'Frozen plan changed.');
  const plan = JSON.parse(bytes);
  assert.equal(plan.format, 'protean-recurrence-evaluation/1');
  assert.deepEqual(plan.cases.map(item => [item.pair, item.arm]),
    [[1, 'treatment'], [1, 'ordinary'], [2, 'ordinary'], [2, 'treatment'], [3, 'treatment'], [3, 'ordinary']]);
  for (const [name, path] of Object.entries({binary_sha256: binary, driver_sha256: driver,
    application_sha256: applicationPath, oracle_sha256: new URL('./recurrence.mjs', import.meta.url),
    evaluator_sha256: new URL('./workspace.mjs', import.meta.url)}))
    assert.equal(hash(await readFile(path)), plan.identities[name], `${name} changed; prepare a new campaign.`);
  for (const subject of plan.cases) {
    await validatePreparedCase(subject);
    assert.equal(hash(await readFile(subject.corpus)), subject.corpus_sha256, 'Frozen corpus changed.');
  }
  return plan;
}

export class RecurrenceDelivery {
  constructor(subject, corpus, plan, operations = []) {
    this.subject = subject;
    this.corpus = corpus;
    this.plan = plan;
    this.operations = structuredClone(operations);
    this.unresolved = null;
  }
  next(taskId, status, elapsed, consumedPacketIds = []) {
    const pending = this.operations.find(operation => !operation.acknowledged);
    if (pending) return pending;
    const delivered = new Set([this.corpus.packets[0].id,
      ...this.operations.filter(operation => operation.packet_id).map(operation => operation.packet_id)]);
    const due = this.corpus.packets.find(packet => !delivered.has(packet.id) && packet.offset_ms <= elapsed);
    const question = status.question;
    if (question) {
      const text = question.prompt?.prompt;
      const known = typeof text === 'string' && Object.hasOwn(this.plan.questions, text)
        ? this.plan.questions[text] : undefined;
      if (!known) { this.unresolved = {question, reason: 'No predeclared factual response.'}; return null; }
      const queued = this.operations.some(operation => operation.method === 'task.message' &&
        operation.acknowledged && !consumedPacketIds.includes(operation.packet_id));
      const waiting = known.kind === 'wait';
      if (waiting && !queued && !due) return null;
      const packet = waiting && !queued ? due : null;
      const answer = waiting ? queued ? this.plan.queued_reminder : packet.bytes : known.text;
      return this.add('task.respond', {client_operation_id: `${this.subject.id}-question-${question.question_id}-${question.question_revision}`,
        task_id: taskId, question_id: question.question_id, question_revision: question.question_revision,
        request_digest: question.request_digest, answer: {schema_id: question.answer_schema_id, value: {message: answer}}}, packet, elapsed);
    }
    if (!due) return null;
    return this.add('task.message', {client_operation_id: `${this.subject.id}-packet-${due.id}`, task_id: taskId,
      message: {schema_id: 'adaptive-agent.message.v2', value: {message: due.bytes}}}, due, elapsed);
  }
  add(method, params, packet, elapsed) {
    const operation = {ordinal: this.operations.length + 1, method, params,
      packet_id: packet?.id ?? null, scheduled_ms: packet?.offset_ms ?? null,
      attempted_ms: elapsed, acknowledged: false};
    this.operations.push(operation);
    return operation;
  }
  acknowledge(operation, result, elapsed) {
    assert(this.operations.includes(operation) && !operation.acknowledged);
    operation.acknowledged = true;
    operation.acknowledged_ms = elapsed;
    operation.result = result;
  }
}

export function recurrenceCost(report, model, usages) {
  const result = {model_id: model.id ?? null, currency: model.currency ?? null,
    total: null, complete: false, inference: null, host: null, storage: null, missing: []};
  if (model.kind !== 'tariff' || model.predeclared !== true) {
    result.missing.push('No predeclared deployment tariff.');
    return result;
  }
  for (const field of ['input_per_million', 'cached_input_per_million', 'output_per_million',
    'host_per_second', 'storage_per_byte_second', 'retention_seconds']) {
    if (!Number.isFinite(model[field]) || model[field] < 0) result.missing.push(field);
  }
  if (!model.id || !model.currency || !model.provider_source || !model.deployment_source)
    result.missing.push('Tariff identity and sources.');
  if (model.host_includes_attempt_storage !== true)
    result.missing.push('Deployment price must include storage during execution.');
  if (result.missing.length) return result;
  const calls = report.metrics ? report.metrics.controller.calls + report.metrics.delegated.calls : null;
  if (calls === null || calls !== usages.length) result.missing.push('Complete physical attempt inventory.');
  let inference = 0;
  for (const usage of usages) {
    if (!usage || !Number.isSafeInteger(usage.input_tokens) || usage.input_tokens < 0 ||
      !Number.isSafeInteger(usage.output_tokens) || usage.output_tokens < 0) {
      result.missing.push('Provider token usage.'); continue;
    }
    let cached = usage.input_tokens_details?.cached_tokens;
    if (model.input_per_million === model.cached_input_per_million) cached = 0;
    if (!Number.isSafeInteger(cached) || cached < 0 || cached > usage.input_tokens) {
      result.missing.push('Cached token usage.'); continue;
    }
    inference += ((usage.input_tokens - cached) * model.input_per_million +
      cached * model.cached_input_per_million + usage.output_tokens * model.output_per_million) / 1000000;
  }
  if (!Number.isFinite(report.elapsed_ms) || report.elapsed_ms < 0) result.missing.push('Complete elapsed time.');
  if (!Number.isSafeInteger(report.retained_namespace_bytes) || report.retained_namespace_bytes < 0)
    result.missing.push('Retained namespace size.');
  if (result.missing.length) return result;
  result.inference = inference;
  result.host = report.elapsed_ms / 1000 * model.host_per_second;
  result.storage = report.retained_namespace_bytes * model.retention_seconds * model.storage_per_byte_second;
  result.total = result.inference + result.host + result.storage;
  if (!Number.isFinite(result.total)) {
    result.total = null;
    result.missing.push('Finite total cost.');
    return result;
  }
  result.complete = true;
  return result;
}

export function recurrenceExpenditure(report, model) {
  const attempts = report.reuse.attempts.filter(attempt =>
    ['agent.model.invoke.v13', 'protean.workspace.inference/2'].includes(attempt.capability) &&
    attempt.dispatched_ms !== undefined);
  const excludedAt = attempt => attempt.physical_provider_attempt === false ||
    attempt.capture?.disposition === 'definitely_not_sent' ?
    attempt.not_sent_observed_ms ?? attempt.captured_ms ?? report.elapsed_ms : Infinity;
  const times = [...new Set([0, ...attempts.flatMap(attempt => [attempt.dispatched_ms,
    attempt.captured_ms, attempt.not_sent_observed_ms]).filter(time => time !== undefined), report.elapsed_ms])].sort((a, b) => a - b);
  return times.map(elapsed_ms => {
    const dispatched = attempts.filter(attempt => attempt.dispatched_ms <= elapsed_ms && excludedAt(attempt) > elapsed_ms);
    const usages = dispatched.map(attempt => attempt.captured_ms <= elapsed_ms ? attempt.usage ?? null : null);
    const complete = usages.every(usage => Number.isSafeInteger(usage?.input_tokens) &&
      Number.isSafeInteger(usage?.output_tokens));
    const final = elapsed_ms === report.elapsed_ms;
    const cost = recurrenceCost({metrics: {controller: {calls: dispatched.length}, delegated: {calls: 0}},
      elapsed_ms, retained_namespace_bytes: final ? report.retained_namespace_bytes : 0}, model, usages);
    return {elapsed_ms, physical_attempts: dispatched.length,
      input_tokens: complete ? usages.reduce((sum, usage) => sum + usage.input_tokens, 0) : null,
      output_tokens: complete ? usages.reduce((sum, usage) => sum + usage.output_tokens, 0) : null,
      cumulative_cost: final ? report.cost.total : cost.total,
      cost_complete: final ? report.cost.complete : cost.complete,
      retention_charged: final, completed_request_payback: null};
  });
}

const digestHex = value => typeof value === 'string' ? value : Buffer.from(value).toString('hex');
const referenceHex = value => digestHex(value.digest ?? value[0]);
const textField = value => typeof value === 'string' ? value : Buffer.from(value?.bytes ?? value ?? []).toString();
const containsText = (value, text) => typeof value === 'string' ? value.includes(text) :
  value !== null && typeof value === 'object' && Object.values(value).some(item => containsText(item, text));

export function decodeRecurrenceObservation(observation, schemas) {
  const decode = (name, bytes) => decodeValue(schemas.get(name), Buffer.from(bytes, 'base64'));
  const optional = value => value.tag === 1 ? value.value : null;
  const reference = value => value ? {digest: value[0], bytes: String(value[1])} : null;
  const eventKinds = ['accepted', 'input_required', 'input_accepted', 'message_queued', 'message_consumed',
    'message_not_consumed', 'cancellation_requested', 'parked', 'resumed', 'blocked', 'delivery_unknown',
    'completed', 'failed', 'cancelled', 'imported', 'reconciled', 'workspace', 'workspace_progress',
    'workspace_read', 'controller', 'controller_requested', 'execution', 'preparation', 'preparation_rejected'];
  const events = observation.events.map(row => {
    const event = decode('event', row.record_b64);
    assert.equal(event.length, 12);
    assert(eventKinds[event[3]]);
    return {task: event[0], seq: String(event[1]), revision: String(event[2]), kind: eventKinds[event[3]],
      data: {bytes: Buffer.from(event[4]).toString()},
      workspace_publications: event[5].map(publication => ({work: publication[0]})),
      record_b64: row.record_b64};
  });
  const attempts = observation.attempts.map(row => {
    const attempt = decode('attempt', row.attempt_b64), occurrence = decode('occurrence', row.occurrence_b64);
    assert.equal(attempt.length, 13); assert.equal(occurrence.length, 7);
    const states = ['ready', 'dispatching', 'awaiting', 'unknown', 'settled_reply', 'admitted', 'not_sent', 'captured'];
    const state = occurrence[3];
    const capture = row.capture_b64 ? decode('capture', row.capture_b64) : null;
    if (capture) assert.equal(capture.length, 8);
    return {...row, physical_provider_attempt: physicalProviderAttempt(digestHex(attempt[0]), capture?.[5], state),
      attempt: {id: attempt[0], task: attempt[1], occurrence: attempt[2],
      request: reference(attempt[3]), profile: reference(attempt[4]), capability: attempt[5], inference: attempt[6],
      prepared: reference(optional(attempt[7])), controller_context: optional(attempt[9]),
      preparation_cut: optional(attempt[12])},
      occurrence: {id: occurrence[0], state: {[states[state.tag]]: [1, 3, 6, 7].includes(state.tag) ?
        {id: state.value[0]} : state.value}},
      capture: capture ? {task: capture[0], occurrence: capture[1], attempt: capture[2],
        request: reference(capture[3]), response: reference(optional(capture[4])),
        disposition: ['complete', 'definitely_not_sent', 'unknown'][capture[5]],
        projection: optional(capture[6])} : undefined};
  });
  const records = (observation.records ?? []).map(row => {
    const raw = decode(row.kind, row.record_b64);
    let value;
    if (row.kind === 'workspace_work') {
      assert.equal(raw.length, 39); assert.equal(raw[0], 3);
      value = {id: raw[1], task: raw[2], program: raw[8], input: reference(raw[15]),
        outcome_kind: ['progressed', 'yielded', 'requested', 'completed', 'failed', 'cancelled'][raw[19]],
        result: reference(optional(raw[28])), result_value: reference(optional(raw[29]))};
    } else {
      assert.equal(raw.length, row.kind === 'workspace_value' ? 5 : 4);
      value = {id: raw[0], task: raw[1], artifact: reference(raw[2]), description: {}};
      if (row.kind === 'workspace_program') {
        assert.equal(raw[3][0], 2);
        value.description = {source: reference(raw[3][1]),
          source_kind: ['source_records', 'component_recipe', 'instrument_model', 'instrument_snapshot', 'source_derivation'][raw[3][2]],
          image: reference(raw[3][5])};
      } else if (row.kind === 'workspace_value') {
        value.description = {schema: reference(raw[3][1]), value: reference(raw[3][2]), provenance: reference(raw[3][3])};
        value.derivation = {kind: ['hypothesis', 'computation', 'acquisition', 'judgment', 'inspection', 'trial'][raw[4][0]],
          sources: {items: raw[4][1].map(reference)}, program: reference(optional(raw[4][2])), work: optional(raw[4][3])};
      } else {
        assert.equal(row.kind, 'workspace_view');
        const projection = optional(raw[3][3]);
        value.description = {values: {items: raw[3][1].map(reference)},
          projection: projection ? {result: reference(projection[0]), work: reference(projection[1]),
            program: reference(projection[2]), input: reference(projection[3]), observation: reference(projection[4]),
            values: {items: projection[5].map(reference)}, blocks: row.projection_blocks} : null};
      }
    }
    return {...row, value};
  });
  return {...observation, events, attempts, records};
}

export function presentedValues(description) {
  const projection = description.projection;
  if (!projection) return description.values.items.map(ref => ({kind: 'value', artifact_id: referenceHex(ref)}));
  assert(Array.isArray(projection.blocks), 'Projected view has no presentation blocks');
  let index = 0;
  const presented = [];
  for (const block of projection.blocks) {
    if (block.tag === 'computed') presented.push({kind: 'computed', artifact_id: referenceHex(projection.result)});
    else if (block.tag === 'value' || block.tag === 'source') {
      const declared = block.tag === 'value' ? block.value : block.value.value;
      const reference = projection.values.items[index++];
      assert(reference && declared.kind === 'value' && textField(declared.id) === referenceHex(reference),
        'Projected value differs from admitted presentation');
      presented.push({kind: block.tag, artifact_id: referenceHex(reference),
        ...(block.tag === 'source' ? {offset: block.value.offset, length: block.value.length} : {})});
    } else assert.equal(block.tag, 'explanation');
  }
  assert.equal(index, projection.values.items.length);
  return presented;
}

export class RecurrenceTrace {
  constructor(corpus, application) {
    this.corpus = corpus;
    this.application = application;
    this.attempts = new Map();
    this.records = new Map();
    this.visibility = new Map();
    this.events = [];
    this.creationEvents = new Map();
    this.workPublications = new Map();
    this.uses = [];
    this.epoch = 0;
    this.cursor = 0;
    this.first_boundary = null;
    this.cut = null;
  }
  dispatched(step, elapsed) {
    if (step.step !== 'dispatched') return;
    const id = digestHex(step.attempt);
    const prior = this.attempts.get(id) ?? {id};
    assert(prior.dispatched_ms === undefined, 'Physical attempt dispatched twice.');
    Object.assign(prior, {dispatched_ms: elapsed, dispatch_epoch: step.epoch,
      capability: step.capability, after_restart: this.cut !== null});
    this.attempts.set(id, prior);
  }
  observe(observation, elapsed) {
    for (const event of observation.events) {
      if (Number(event.seq) <= this.cursor) continue;
      assert.equal(Number(event.seq), this.cursor + 1, 'Missing owner event.');
      this.cursor = Number(event.seq);
      this.events.push({event, observed_ms: elapsed, publication_epoch: observation.epoch});
      const data = JSON.parse(textField(event.data));
      if (event.kind === 'workspace' && data.workspace_id && !this.creationEvents.has(data.workspace_id))
        this.creationEvents.set(data.workspace_id, Number(event.seq));
      for (const publication of event.workspace_publications ?? [])
        this.workPublications.set(digestHex(publication.work), Number(event.seq));
    }
    for (const row of observation.attempts) this.observeAttempt(row, observation.epoch, elapsed);
    for (const record of observation.records ?? []) {
      const identity = `${record.kind}:${digestHex(record.value.id)}`;
      const prior = this.records.get(identity);
      const next = {...record, first_seen_ms: prior?.first_seen_ms ?? elapsed,
        created_epoch: prior?.created_epoch ?? observation.epoch,
        creation_seq: prior?.creation_seq ?? this.creationEvents.get(record.value.artifact ? referenceHex(record.value.artifact) : digestHex(record.value.id)) ?? null,
        visibility_epoch: prior?.visibility_epoch ?? this.epoch};
      this.records.set(identity, next);
      if (record.kind === 'workspace_work' && record.value.outcome_kind === 'completed' && record.value.result &&
        !this.uses.some(use => use.kind === 'program' && use.work_id === digestHex(record.value.id))) {
        const program = this.artifactRecord('workspace_program', digestHex(record.value.program));
        if (program?.value.description.source_kind === 'source_records') this.uses.push({kind: 'program', artifact_id: referenceHex(program.value.artifact), custody_id: digestHex(program.value.id),
          work_id: digestHex(record.value.id), input_sha256: referenceHex(record.value.input),
          result_sha256: referenceHex(record.value.result), visibility_epoch: this.epoch,
          result_artifact_id: record.value.result_value ? referenceHex(record.value.result_value) : null,
          publication_epoch: observation.epoch, observed_ms: elapsed,
          created_epoch: program.created_epoch, creation_seq: program.creation_seq,
          event_seq: this.workPublications.get(digestHex(record.value.id)) ?? null,
          after_restart: this.cut !== null});
      }
    }
    this.descriptionUses(observation.epoch, elapsed);
    if (!this.first_boundary) this.first_boundary = this.qualifyingBoundary(observation, elapsed);
  }
  observeAttempt(row, publicationEpoch, elapsed) {
    const id = digestHex(row.attempt.id), prior = this.attempts.get(id) ?? {id};
    const capability = textField(row.attempt.capability);
    Object.assign(prior, {owner: row.attempt, capability, occurrence: row.occurrence,
      physical_provider_attempt: row.physical_provider_attempt});
    if (row.physical_provider_attempt === false) prior.not_sent_observed_ms ??= elapsed;
    if (row.prepared_b64 && capability === 'agent.model.invoke.v13') {
      const prepared = decodeValue(contract(this.application, 'AdaptivePrepared'), Buffer.from(row.prepared_b64, 'base64'));
      prior.prepared_sha256 = hash(Buffer.from(row.prepared_b64, 'base64'));
      prior.body = JSON.parse(Buffer.from(prepared[2]).toString());
      prior.selected_view = prepared[3].tag === 1 ? referenceHex(prepared[3].value) : null;
      prior.watermark = String(prepared[1][3][2]);
      if (prior.dispatched_ms !== undefined && prior.visibility_epoch === undefined) {
        const appeared = this.corpus.packets.filter(packet => !this.visibility.has(packet.id) && containsText(prior.body.input, packet.bytes));
        if (appeared.length) this.epoch++;
        prior.visibility_epoch = this.epoch;
        for (const packet of appeared) this.visibility.set(packet.id, {packet_id: packet.id,
          attempt_id: id, dispatch_ms: prior.dispatched_ms, observed_ms: elapsed,
          publication_epoch: publicationEpoch, visibility_epoch: this.epoch,
          preparation_cut: prior.owner.preparation_cut === null ? null : Number(prior.owner.preparation_cut),
          confirmed: false, prepared_sha256: prior.prepared_sha256});
      }
    }
    if (row.capture) {
      prior.capture = row.capture;
      prior.captured_ms ??= elapsed;
      if (row.response_b64 && ['agent.model.invoke.v13', 'protean.workspace.inference/2'].includes(capability)) {
        const raw = decodeValue(contract(this.application, 'CapturedResponse'), Buffer.from(row.response_b64, 'base64'));
        try { prior.usage = capturedUsage(raw) ?? null; } catch { prior.usage = null; }
        prior.response_sha256 = hash(Buffer.from(row.response_b64, 'base64'));
        prior.provider_response = raw[0] >= 200 && raw[0] < 300 && raw[7] === 2;
        if (row.capture.disposition === 'complete' && prior.provider_response) {
          for (const packet of this.corpus.packets) {
            const visibility = this.visibility.get(packet.id);
            if (visibility && !visibility.confirmed && containsText(prior.body?.input, packet.bytes))
              Object.assign(visibility, {confirmed: true, confirmation: {attempt_id: id,
                prepared_sha256: prior.prepared_sha256, response_sha256: prior.response_sha256, observed_ms: elapsed}});
          }
        }
      }
    }
    this.attempts.set(id, prior);
  }
  artifactRecord(kind, id) {
    return [...this.records.values()].find(record => record.kind === kind && referenceHex(record.value.artifact) === id);
  }
  descriptionCandidate(record) {
    const derivation = record.value.derivation;
    if (['hypothesis', 'judgment'].includes(derivation.kind)) return true;
    if (derivation.kind !== 'computation' || !derivation.program || !derivation.work) return false;
    const work = this.records.get(`workspace_work:${digestHex(derivation.work)}`);
    const program = work && this.artifactRecord('workspace_program', digestHex(work.value.program));
    return work?.value.outcome_kind === 'completed' && work.value.result &&
      program?.value.description.source_kind === 'source_records' &&
      referenceHex(program.value.artifact) === referenceHex(derivation.program) &&
      referenceHex(work.value.result) === referenceHex(record.value.description.value);
  }
  descriptionUses(publicationEpoch, elapsed) {
    for (const attempt of this.attempts.values()) {
      if (!attempt.selected_view || !attempt.capture || attempt.capture.disposition !== 'complete' ||
        !attempt.provider_response || attempt.visibility_epoch === undefined) continue;
      const view = this.artifactRecord('workspace_view', attempt.selected_view);
      if (!view) continue;
      for (const presented of presentedValues(view.value.description)) {
        const value = this.artifactRecord('workspace_value', presented.artifact_id);
        if (!value || !this.descriptionCandidate(value)) continue;
        const id = referenceHex(value.value.artifact);
        if (this.uses.some(use => use.kind === 'description' && use.artifact_id === id && use.attempt_id === attempt.id)) continue;
        this.uses.push({kind: 'description', artifact_id: id, custody_id: digestHex(value.value.id),
          view_id: referenceHex(view.value.artifact), presentation: presented,
          attempt_id: attempt.id, prepared_sha256: attempt.prepared_sha256,
          response_sha256: attempt.response_sha256, visibility_epoch: attempt.visibility_epoch,
          publication_epoch: publicationEpoch, observed_ms: elapsed, created_epoch: value.created_epoch,
          creation_seq: value.creation_seq,
          after_restart: attempt.after_restart ?? false});
      }
    }
  }
  qualifyingBoundary(observation, elapsed) {
    const ordered = [...this.uses].sort((a, b) => a.observed_ms - b.observed_ms ||
      (a.event_seq ?? Infinity) - (b.event_seq ?? Infinity));
    for (let j = 0; j < ordered.length; j++) for (let i = 0; i < j; i++) {
      const earlier = ordered[i], later = ordered[j];
      if (earlier.kind !== later.kind || earlier.artifact_id !== later.artifact_id ||
        earlier.visibility_epoch >= later.visibility_epoch) continue;
      if (earlier.kind === 'program' && earlier.input_sha256 === later.input_sha256) continue;
      const laterVisibility = [...this.visibility.values()].find(item => item.visibility_epoch === later.visibility_epoch);
      if (!laterVisibility || !creationPrecedes(later, laterVisibility)) continue;
      return {kind: later.kind, artifact_id: later.artifact_id, earlier, later,
        epoch: observation.epoch, head: observation.head, observed_ms: elapsed,
        worker_active: observation.worker_active, semantic_qualification: null};
    }
    return null;
  }
  consumedPackets(operations) {
    const consumed = new Set(this.events.filter(item => item.event.kind === 'message_consumed')
      .map(item => JSON.parse(textField(item.event.data)).message_id));
    return operations.filter(item => item.method === 'task.respond' || consumed.has(item.result?.message_id))
      .map(item => item.packet_id).filter(Boolean);
  }
  summary() {
    return {visibility: [...this.visibility.values()], uses: this.uses,
      first_boundary: this.first_boundary, cut: this.cut,
      artifacts: [...this.records.values()].filter(item => item.kind !== 'workspace_work'),
      attempts: [...this.attempts.values()].map(({body, ...attempt}) => attempt),
      post_restart_uses: this.cut ? this.uses.filter(use => use.after_restart && use.artifact_id === this.cut.artifact_id) : [],
      qualified: null, recovered: null,
      notes: 'Mechanical witnesses require source, scope, effective-input and supported-answer review. Inclusion is availability, not causal necessity.'};
  }
}

function creationPrecedes(use, visibility) {
  if (use.creation_seq != null && visibility.preparation_cut != null)
    return Number(use.creation_seq) <= Number(visibility.preparation_cut);
  return Number(use.created_epoch) < Number(visibility.publication_epoch);
}

export class RecurrenceDriver {
  constructor(binary, args) {
    this.child = spawn(binary, args, {detached: true, stdio: ['pipe', 'pipe', 'pipe']});
    this.pending = new Map();
    this.serial = 0;
    this.diagnostics = '';
    this.child.stderr.setEncoding('utf8').on('data', bytes => {
      this.diagnostics = (this.diagnostics + bytes).slice(-8192);
    });
    this.reader = createInterface({input: this.child.stdout});
    this.reader.on('line', line => {
      try {
        const reply = JSON.parse(line), pending = this.pending.get(reply.id);
        assert(pending, 'Uncorrelated evaluation response.');
        this.pending.delete(reply.id);
        if (reply.error) pending.reject(new Error(reply.error.message));
        else pending.resolve(reply.result);
      } catch (error) { this.fail(error); }
    });
    this.child.on('error', error => this.fail(error));
    this.child.stdin.on('error', error => this.fail(error));
    this.child.once('exit', () => this.kill());
    this.closed = new Promise(resolve => this.child.once('close', (code, signal) => {
      this.exit = {code, signal};
      this.fail(new Error(`Evaluation driver closed: ${code}/${signal}; ${this.diagnostics}`));
      resolve(this.exit);
    }));
  }
  fail(error) {
    this.failure ??= error;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
  call(method, params = {}) {
    if (this.failure) return Promise.reject(this.failure);
    const id = `evaluation-${++this.serial}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject});
      this.child.stdin.write(JSON.stringify({id, method, params}) + '\n', error => {
        if (error) this.fail(error);
      });
    });
  }
  kill() {
    if (!this.child.pid) return false;
    try { process.kill(-this.child.pid, 'SIGKILL'); return true; }
    catch (error) { if (error.code === 'ESRCH') return false; throw error; }
  }
  async waitClosed(timeoutMs = 6000) {
    let timer;
    try {
      return await Promise.race([this.closed, new Promise((_, reject) => {
        timer = setTimeout(() => {
          const error = new Error('Evaluation process group did not close after termination.');
          this.fail(error);
          this.child.stdout.destroy();
          this.child.stderr.destroy();
          this.child.stdin.destroy();
          reject(error);
        }, timeoutMs);
      })]);
    } finally { clearTimeout(timer); }
  }
  async close() {
    this.child.stdin.end();
    const timer = setTimeout(() => this.kill(), 6000);
    try { return await this.waitClosed(12000); } finally { clearTimeout(timer); }
  }
}

export function recurrenceArtifacts(archive) {
  const artifacts = [];
  for (const [kind, id, reference] of archive.manifest[6]) {
    if (kind === 8) {
      const record = decodeValue(archive.schemas.get('workspace_program'), archive.object(reference));
      const description = record[3], source = archive.object(description[1]);
      artifacts.push({kind: 'program', artifact_id: referenceHex(record[2]), custody_id: digestHex(id), source_sha256: hash(source),
        source_base64: source.toString('base64'), image_sha256: referenceHex(description[5]),
        source_kind: description[2]});
    } else if (kind === 10) {
      const record = decodeValue(archive.schemas.get('workspace_value'), archive.object(reference));
      const description = record[3], schema = archive.object(description[1]), bytes = archive.object(description[2]);
      artifacts.push({kind: 'description', artifact_id: referenceHex(record[2]), custody_id: digestHex(id), source_sha256: hash(bytes),
        schema_sha256: hash(schema), value: decodeValue(decodeSchema(schema), bytes),
        provenance: record[4]});
    }
  }
  return artifacts;
}

export function adjudicateRecurrence(report, corpus, judgment) {
  const reuse = structuredClone(report.reuse), failures = [];
  const artifact = reuse.authored_evidence.find(item => item.artifact_id === judgment.artifact_id);
  if (!artifact || artifact.source_sha256 !== judgment.source_sha256) failures.push('Unbound authored artifact.');
  for (const field of ['relationship', 'scope', 'observed_inadequacy', 'source_review'])
    if (typeof judgment[field] !== 'string' || !judgment[field].trim()) failures.push(`Missing ${field}.`);
  if (judgment.general_relationship !== true || judgment.constant_or_case_lookup !== false)
    failures.push('Source does not establish a reusable relationship.');
  if (judgment.scope_handling_correct !== true) failures.push('Scope or invalidation was not established.');
  const answers = report.result?.outcome?.value?.result;
  let finalAnswers = [];
  try { if (answers?.tag === 'report') finalAnswers = parseReport(answers.value.summary).answers; } catch {}
  const accepted = [];
  for (const proposed of judgment.uses ?? []) {
    const use = reuse.uses.find(item => item.artifact_id === judgment.artifact_id &&
      (item.work_id ?? item.attempt_id) === proposed.use_id);
    const packet = corpus.packets.find(item => item.request_ids.includes(proposed.request_id));
    const visible = reuse.visibility.find(item => item.packet_id === packet?.id);
    const scored = report.grading.answers.find(item => item.request_id === proposed.request_id);
    const matching = finalAnswers.filter(item => item?.request_id === proposed.request_id);
    const answer = matching.length === 1 ? matching[0] : null;
    const boundRefs = use && [use.artifact_id, use.result_artifact_id, use.result_sha256, use.work_id, use.view_id].filter(Boolean);
    if (!use || !visible?.confirmed || (packet.offset_ms > 0 && !creationPrecedes(use, visible)) ||
      use.visibility_epoch < visible.visibility_epoch || scored?.sound !== true ||
      !Array.isArray(answer?.artifact_refs) || !answer.artifact_refs.some(ref => boundRefs.includes(ref)) ||
      proposed.effective_input_matches_records !== true || proposed.supports_answer !== true ||
      proposed.scope_valid !== true) {
      failures.push(`Unestablished use: ${proposed.request_id}.`); continue;
    }
    accepted.push({...use, request_id: proposed.request_id, expected: scored.expected,
      later_request: packet.offset_ms > 0});
  }
  const later = accepted.filter(item => item.later_request);
  if (new Set(later.map(item => item.request_id)).size < 2) failures.push('Fewer than two supported later requests.');
  if (artifact?.kind === 'program' && (new Set(later.map(item => item.input_sha256)).size < 2 ||
    new Set(later.map(item => item.expected)).size < 2)) failures.push('Executable reuse lacks changed inputs and conclusions.');
  const useIdentity = use => use && `${use.kind}:${use.artifact_id}:${use.work_id ?? use.attempt_id}`;
  const first = reuse.first_boundary;
  const proxy = first && [first.earlier, first.later].map(use =>
    accepted.find(item => useIdentity(item) === useIdentity(use)));
  if (!proxy || proxy.some(use => !use) || proxy[0]?.request_id === proxy[1]?.request_id)
    failures.push('The original first interruption proxy is not supported cross-request reuse.');
  const cut = reuse.cut;
  const recovery = first && cut?.artifact_id === judgment.artifact_id && cut.exit?.signal === 'SIGKILL' &&
    useIdentity(cut.earlier) === useIdentity(first.earlier) &&
    useIdentity(cut.later) === useIdentity(first.later) &&
    cut.task_id === report.task?.task_id && cut.reopened_ms !== undefined &&
    accepted.some(item => item.after_restart && item.observed_ms >= cut.reopened_ms &&
      !proxy?.some(prior => useIdentity(prior) === useIdentity(item)));
  reuse.qualified = failures.length === 0;
  reuse.recovered = recovery === true && reuse.qualified;
  reuse.adjudication = {judgment, accepted_uses: accepted, failures,
    claim: 'Observed supported use; causal necessity and private reasoning are not established.'};
  return reuse;
}

export function recurrenceResults(plan, reports) {
  const comparison = compareCampaign(plan, reports);
  const lines = ['# Recurring release investigations', '',
    `Verdict: **${comparison.verdict}**. Qualified treatment traces: ${comparison.qualifying_traces}/3.`, '',
    'This controlled workload compares construction and retention with recovery against an uninterrupted ordinary agent with continuing context. It does not establish broad superiority or private reasoning.', '',
    '## Bound inputs', '', '```json', json({identities: plan.identities, profile: plan.profile,
      initial_effort: plan.initial_effort, limits: plan.limits, cost_model: plan.cost_model,
      workload: 'Twelve immutable release-readiness requests per attempt; three frozen matched pairs.',
      cases: plan.cases.map(item => ({id: item.id, corpus_sha256: item.corpus_sha256,
        expected_sha256: item.expected_sha256, config_sha256: item.config_sha256}))}), '```', '',
    '## Inclusive outcomes', '', '| Attempt | Sound / 12 | Critical | Total cost | Budget | Mechanism |',
    '| --- | ---: | ---: | ---: | --- | --- |'];
  for (const attempt of comparison.attempts) lines.push(`| ${attempt.subject.id} | ${attempt.grading?.sound ?? 'unknown'} | ${attempt.grading?.critical ?? 'unknown'} | ${attempt.cost ?? 'unknown'} ${attempt.currency ?? ''} | ${attempt.budget.compliant ?? 'unknown'} | ${attempt.mechanism ?? 'unreviewed'} |`);
  lines.push('', '## Matched and aggregate comparison', '', '```json', json({pairs: comparison.pairs,
    aggregate: comparison.aggregate, campaign_cost_positive: comparison.campaign_cost_positive,
    complete_milestone: comparison.complete_milestone, issues: comparison.issues}), '```', '',
    'Payback is judged only at stream completion against complete costs and supported final answers. An earlier expenditure crossing does not establish equal completed work or an exact break-even request.', '');
  for (const report of reports) {
    lines.push(`## ${report.subject.id}`, '',
      `[Full attempt, authored values/source, scope review and capture identities](${report.subject.id}/report.json).`, '',
      '```json', json({status: report.status?.status ?? null, grading: report.grading,
        observed_inadequacy: report.reuse.adjudication?.judgment.observed_inadequacy ?? null,
        scope: report.reuse.adjudication?.judgment.scope ?? null,
        relationship: report.reuse.adjudication?.judgment.relationship ?? null,
        visibility: report.reuse.visibility, uses: report.reuse.uses, interruption: report.reuse.cut,
        post_restart_uses: report.reuse.post_restart_uses, cost: report.cost,
        expenditure_trace: report.expenditure_trace,
        errors: report.errors, arm_violations: report.arm_violations,
        unresolved_question: report.unresolved_question}), '```', '');
  }
  lines.push('## Limits', '',
    'All planned attempts are included, including missing and unsuccessful attempts. Missing usage and prices remain unknown. Wall time is enforced; other resource ceilings are assessed from retained measurements. RSS is sampled. Physical request counts are not successful execution counts. Compilation and publication intervals are not added to elapsed time.', '',
    'Mechanical interruption proxies require finite source and trace adjudication. Availability alone is insufficient; constant answers, case-ID lookup, stale scope and unused artifacts do not qualify. Scripted fixtures establish harness behavior only. Experiment engineering and external adjudication are separate from operational agent costs.', '');
  return lines.join('\n');
}

async function readOutcome(client, taskId, result) {
  if (!result.outcome?.value_ref) return result;
  const ref = result.outcome.value_ref, chunks = [];
  let offset = '0';
  for (;;) {
    const chunk = await client.call('artifact.read', {task_id: taskId,
      artifact_id: ref.artifact_id, offset, length: '32768'});
    assert.equal(chunk.sha256, ref.sha256);
    chunks.push(Buffer.from(chunk.data, 'base64url'));
    offset = chunk.next_offset;
    if (chunk.eof) break;
  }
  const bytes = Buffer.concat(chunks);
  assert.equal(hash(bytes), ref.sha256);
  assert.equal(BigInt(bytes.length), BigInt(ref.bytes));
  result.outcome.value = JSON.parse(bytes.toString());
  return result;
}

export function inferenceArguments({credential, chatgptAccount, siwcBin, siwcAuthDir}) {
  assert(Boolean(credential) !== Boolean(chatgptAccount), 'Select one inference source: --credential-file or --chatgpt-account.');
  assert(chatgptAccount || !siwcBin, '--siwc-bin requires --chatgpt-account.');
  return ['--authorize-inference',
    ...(credential ? ['--credential-file', resolve(credential)] : ['--chatgpt-account', chatgptAccount]),
    ...(siwcBin ? ['--siwc-bin', resolve(siwcBin)] : []),
    ...(siwcAuthDir ? ['--siwc-auth-dir', resolve(siwcAuthDir)] : [])];
}

export async function evaluateRecurrence({subject, plan, output, driver, credential, chatgptAccount, siwcBin, siwcAuthDir, application,
  build, offline = false}, {Client = RecurrenceDriver, now = () => performance.now(), wait = pause} = {}) {
  const started = now();
  output = await realpath(output);
  const state = join(output, 'state'), corpus = JSON.parse(await readFile(subject.corpus));
  const delivery = new RecurrenceDelivery(subject, corpus, plan), trace = new RecurrenceTrace(corpus, application);
  const errors = [], samples = [], elapsed = () => now() - started;
  const record = (stage, error) => errors.push({stage, name: error.name, message: error.message});
  let client, watchdog, task = null, status = null, result = null, archivePath = null,
    metrics = null, retainedBytes = null, peakRss = null, timedOut = false, cutAttempted = false,
    artifactEvidence = [], schemas = null;
  const persist = async () => writeFile(join(output, 'progress.json'), json({task, status,
    elapsed_ms: elapsed(), operations: delivery.operations, trace: trace.summary(), errors}));
  const launch = () => {
    const options = ['--state-dir', state,
      ...(offline ? ['--offline'] : ['--config', subject.config, ...inferenceArguments({credential, chatgptAccount, siwcBin, siwcAuthDir})]),
      ...(task ? ['--profile-task', task.task_id] : [])];
    client = new Client(driver, options);
    clearTimeout(watchdog);
    watchdog = setTimeout(() => { timedOut = true; client.kill(); },
      Math.max(1, plan.limits.wall_ms - elapsed()));
  };
  const observe = async () => {
    const raw = await client.call('evaluation.observe', {task_id: task.task_id, after: String(trace.cursor)});
    if (raw.events.length || raw.attempts.length || raw.records?.length)
      await appendFile(join(output, 'observations.jsonl'), JSON.stringify({elapsed_ms: elapsed(), observation: raw}) + '\n');
    const observation = decodeRecurrenceObservation(raw, schemas);
    trace.observe(observation, elapsed());
    return observation;
  };
  const sample = () => {
    const ps = spawnSync('ps', ['-o', 'rss=', '-p', String(client.child.pid)], {encoding: 'utf8'});
    if (ps.status === 0 && /^\s*\d+\s*$/.test(ps.stdout)) {
      const rss = Number(ps.stdout.trim()) * 1024;
      peakRss = Math.max(peakRss ?? 0, rss);
      samples.push({elapsed_ms: elapsed(), rss_bytes: rss});
    }
  };
  try {
    launch();
    const description = await client.call('describe');
    const submit = {client_operation_id: subject.id, application_id: 'adaptive-agent', profile_id: description.profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: subject.prompt}}};
    await writeFile(join(output, 'submission.json'), json(submit), {flag: 'wx'});
    task = await client.call('task.submit', submit);
    const preflightPath = join(output, 'admitted.agnx');
    await client.call('evaluation.export', {task_id: task.task_id, path: preflightPath});
    const admitted = readArchive(await readFile(preflightPath));
    assert.equal(admitted.build.application_assets_sha256, plan.identities.application_sha256,
      'Driver and frozen application assets differ; no inference was dispatched.');
    schemas = admitted.schemas;
    await observe();
    await persist();
    let sampledAt = -Infinity;
    for (;;) {
      if (elapsed() >= plan.limits.wall_ms) { timedOut = true; break; }
      status = await client.call('task.status', {task_id: task.task_id});
      if (elapsed() - sampledAt >= 1000) { sample(); sampledAt = elapsed(); }
      if (['completed', 'failed', 'cancelled', 'unknown', 'blocked'].includes(status.status)) break;
      const operation = delivery.next(task.task_id, status, elapsed(), trace.consumedPackets(delivery.operations));
      if (delivery.unresolved) break;
      if (operation) {
        await persist();
        const receipt = await client.call(operation.method, operation.params);
        delivery.acknowledge(operation, receipt, elapsed());
        await observe();
        await persist();
        continue;
      }
      const step = await client.call('evaluation.step');
      trace.dispatched(step, elapsed());
      const observation = await observe();
      if (subject.arm === 'treatment' && trace.first_boundary && !cutAttempted) {
        cutAttempted = true;
        const boundary = trace.first_boundary;
        if (boundary.worker_active) {
          const active = [...trace.attempts.values()].filter(attempt =>
            attempt.dispatched_ms !== undefined && !attempt.capture);
          if (!active.length || active.some(attempt => Number(attempt.dispatch_epoch) >= Number(boundary.epoch))) {
            boundary.cut_failure = 'First eligible owner return already had a later or unaccounted acquisition.';
          } else {
            for (;;) {
              const drained = await client.call('evaluation.drain');
              if (drained.step === 'captured' || drained.step === 'idle') break;
              assert.equal(drained.step, 'pending');
              await wait(100);
            }
            await observe();
          }
        }
        if (!boundary.cut_failure) {
          const cutPath = join(output, 'cut.agnx');
          await client.call('evaluation.export', {task_id: task.task_id, path: cutPath});
          const sealedObservation = await observe();
          let acknowledged;
          try {
            acknowledged = await client.call('evaluation.pause', {task_id: task.task_id, epoch: sealedObservation.epoch});
          } catch (error) {
            if (!['UnsettledOccurrence', 'WorkerOutstanding', 'StaleBoundary'].includes(error.message)) throw error;
            boundary.cut_failure = error.message;
          }
          if (!acknowledged) { await persist(); continue; }
          trace.cut = {...boundary, sealed: acknowledged, task_id: task.task_id,
            archive_sha256: hash(await readFile(cutPath)), kill_requested_ms: elapsed()};
          await persist();
          assert(client.kill(), 'SIGKILL was not delivered.');
          const exit = await client.waitClosed();
          assert.equal(exit.signal, 'SIGKILL');
          trace.cut.exit = exit;
          trace.cut.killed_ms = elapsed();
          clearTimeout(watchdog);
          launch();
          const restored = await client.call('task.status', {task_id: task.task_id});
          assert.equal(restored.task_id, task.task_id);
          const reopened = await observe();
          assert.deepEqual(reopened.head, acknowledged.head, 'Reopen changed the sealed namespace head.');
          const resume = {client_operation_id: `${subject.id}-resume`, task_id: task.task_id,
            expected_revision: restored.revision};
          await writeFile(join(output, 'resume.json'), json(resume), {flag: 'wx'});
          await client.call('task.resume', resume);
          trace.cut.reopened_ms = elapsed();
          await observe();
          await persist();
        }
      }
      if (['idle', 'waiting', 'pending'].includes(step.step)) await wait(Math.min(100, Math.max(0, plan.limits.wall_ms - elapsed())));
    }
    if (!timedOut && !['completed', 'failed', 'cancelled', 'unknown', 'blocked'].includes(status?.status)) {
      await client.call('task.cancel', {client_operation_id: `${subject.id}-end`, task_id: task.task_id,
        reason: 'Evaluation boundary: preserve unanswered work.'});
    }
    if (!timedOut) result = await readOutcome(client, task.task_id, await client.call('task.result', {task_id: task.task_id}));
  } catch (error) {
    if (!timedOut) record('execution', error);
  } finally {
    if (client) {
      if (!timedOut && !client.exit && task) try {
        const remaining = await client.call('evaluation.observe', {task_id: task.task_id, after: String(trace.cursor)});
        if (remaining.worker_active) {
          while (!timedOut) {
            const step = await client.call('evaluation.drain');
            if (step.step === 'captured') break;
            assert.equal(step.step, 'pending', 'Draining must not dispatch new work.');
            await wait(100);
          }
        }
      } catch (error) { if (!timedOut) record('drain', error); }
      clearTimeout(watchdog);
      if (timedOut && !client.exit) client.kill();
      try {
        const exit = await client.close();
        if (!timedOut && (exit.code !== 0 || exit.signal !== null)) record('close', new Error(json(exit)));
      } catch (error) { record('close', error); }
    }
    clearTimeout(watchdog);
  }
  if (task) {
    try {
      client = new Client(driver, ['--state-dir', state,
        ...(offline ? ['--offline'] : ['--config', subject.config, ...inferenceArguments({credential, chatgptAccount, siwcBin, siwcAuthDir})]),
        '--profile-task', task.task_id]);
      const exportTimer = setTimeout(() => client.kill(), 30000);
      try {
        archivePath = join(output, 'task.agnx');
        await client.call('evaluation.export', {task_id: task.task_id, path: archivePath});
        const archive = readArchive(await readFile(archivePath));
        schemas ??= archive.schemas;
        await observe();
        metrics = workspaceMetrics(archive, application);
        artifactEvidence = recurrenceArtifacts(archive);
        status = await client.call('task.status', {task_id: task.task_id});
        if (!result) result = await readOutcome(client, task.task_id, await client.call('task.result', {task_id: task.task_id}));
      } finally { clearTimeout(exportTimer); await client.close(); }
    } catch (error) { record('measurements', error); }
  }
  try { retainedBytes = await bytesUnder(state); } catch (error) { record('namespace', error); }
  const finalResult = result?.outcome?.value?.result;
  const rawSummary = finalResult?.tag === 'report' ? finalResult.value.summary : '';
  const report = {subject, plan_sha256: campaignIdentity(plan), build, task, elapsed_ms: elapsed(), peak_rss_sampled_bytes: peakRss,
    retained_namespace_bytes: retainedBytes, status, result, archive: archivePath, metrics, errors,
    timed_out: timedOut, unresolved_question: delivery.unresolved, operations: delivery.operations,
    resource_samples: samples, grading: gradeReport(rawSummary, corpus, new Set(corpus.packets
      .filter(packet => trace.visibility.get(packet.id)?.confirmed).flatMap(packet => packet.request_ids))),
    reuse: trace.summary(),
    arm_violations: metrics ? armViolations(subject.arm === 'treatment' ? 'recurrence' : 'ordinary', metrics.actions) : null};
  const end = trace.visibility.get(corpus.packets.at(-1).id);
  if (status?.status === 'completed' && (!end?.confirmed || end.dispatch_ms < corpus.packets.at(-1).offset_ms))
    report.arm_violations = [...(report.arm_violations ?? []), {kind: 'premature_completion'}];
  report.reuse.authored_evidence = artifactEvidence;
  if (!report.reuse.first_boundary) report.reuse.qualified = false;
  if (!report.reuse.cut || !report.reuse.post_restart_uses.length) report.reuse.recovered = false;
  const usages = metrics?.physical_attempts.map(attempt => attempt.usage) ?? [];
  report.cost = recurrenceCost(report, plan.cost_model, usages);
  report.expenditure_trace = recurrenceExpenditure(report, plan.cost_model);
  await writeFile(join(output, 'report.json'), json(report));
  await persist();
  return report;
}

async function runRecurrence(directory, options) {
  const plan = await validateRecurrencePlan(directory, options);
  const application = JSON.parse(await readFile(options.applicationPath, 'utf8'));
  const build = command(options.binary, ['describe-build']);
  assert.equal(build.application_assets_sha256, plan.identities.application_sha256);
  const reports = [];
  for (const subject of plan.cases) {
    await validateRecurrencePlan(directory, options);
    const output = join(directory, subject.id);
    await mkdir(output);
    const report = await evaluateRecurrence({subject, plan, output, driver: options.driver,
      credential: options.credential, chatgptAccount: options.chatgptAccount,
      siwcBin: options.siwcBin, siwcAuthDir: options.siwcAuthDir, application, build});
    reports.push(report);
    await writeFile(join(directory, 'results.json'), json({plan_sha256: hash(json(plan)), reports,
      comparison: compareCampaign(plan, reports)}));
    await writeFile(join(directory, 'results.md'), recurrenceResults(plan, reports));
  }
  return {results: join(directory, 'results.json'), comparison: compareCampaign(plan, reports)};
}

if (import.meta.main) {
if (mode === 'prepare' && option(args, '--suite') === 'recurrence') {
  const directory = resolve(option(args, '--out', ''));
  const costPath = option(args, '--cost-model');
  const plan = await prepareRecurrence({config: JSON.parse(await readFile(resolve(option(args, '--config', '')), 'utf8')),
    directory, binary: resolve(option(args, '--binary', '')), driver: resolve(option(args, '--driver', '')),
    applicationPath: resolve(option(args, '--application', '')),
    ...(costPath ? {costModel: JSON.parse(await readFile(resolve(costPath), 'utf8'))} : {})});
  console.log(json({plan: join(directory, 'plan.json'), cases: plan.cases.length, live_calls: 0, efficacy: 'unmeasured'}));
} else if (mode === 'prepare') {
  const configFile = resolve(option(args, '--config', '')), directory = resolve(option(args, '--out', ''));
  const config = JSON.parse(await readFile(configFile, 'utf8'));
  assert.equal(config.schema, 'adaptive-agent.configuration.v3');
  const suite = option(args, '--suite', 'workspace');
  assert(['workspace', 'runtime', 'reconstruction', 'semantic'].includes(suite), 'Choose workspace, runtime, reconstruction or semantic evaluation.');
  const selectedArms = suite === 'runtime' ? runtimeArms : suite === 'reconstruction' ? reconstructionArms : suite === 'semantic' ? semanticArms : arms;
  const repetitions = Number(option(args, '--repetitions', '1')), seconds = Number(option(args, '--seconds', '600'));
  assert(Number.isSafeInteger(repetitions) && repetitions > 0 && Number.isSafeInteger(seconds) && seconds > 0);
  const profile = config.adaptive.profiles.find(p => p.id === config.adaptive.initial_profile); assert(profile);
  const frozen = {...config, adaptive: {...config.adaptive, profiles: [{...profile, efforts: [config.adaptive.initial_effort], effort_update: false}], skills: []}};
  const row = (id, key, value, group) => Object.fromEntries(Object.entries({id, key, value, group}).map(([k,v]) => [k, String(v)]));
  const rows = Array.from({length: 256}, (_, i) => row(i + 1, (i + 17) * 18, (i + 23) * 12, i % 8));
  const gcd = (a,b) => b ? gcd(b,a % b) : a;
  const sums = Array(8).fill(0); for (const row of rows) sums[Number(row.group)] += gcd(Number(row.key), Number(row.value));
  const families = [
    {id: 'direct', prompt: 'Which TCP port does the service use? Cite the defining source and report the answer.', files: {'service.conf': 'listen_port = 8087\n'}, expected: {port: 8087, evidence: ['service.conf']}, inputs: []},
    {id: 'repetitive', prompt: 'For each row, compute gcd(key, value). Report the sum of these GCDs for each group, covering every row. Explain how you established coverage.', files: {'rows.csv': 'id,key,value,group\n' + rows.map(r => [r.id,r.key,r.value,r.group].join(',')).join('\n') + '\n'}, expected: {sums, rows: rows.length, evidence: ['rows.csv']}, inputs: [{id: 'rows', description: 'The same complete rows as rows.csv, as typed structured input.', rows, relation: [], selected: []}]},
    {id: 'reframing', prompt: 'Investigate why yesterday’s scheduled rollout did not appear. The initial incident note suspects slow ingestion. Establish the cause from available evidence and explain any remaining uncertainty.', files: {'incident.md': 'At 09:00 UTC operators saw no rollout. Initial hypothesis: ingestion backlog delayed eligibility. Investigate that hypothesis.\n', 'ingestion.csv': 'time_utc,queue_depth,oldest_age_seconds\n08:50,2,1\n08:55,1,1\n09:00,0,0\n09:05,0,0\n', 'schedule.conf': 'rollout = 09:00\ntimezone = America/Los_Angeles\n', 'scheduler.log': '2026-10-13T16:00:00Z rollout started\n2026-10-13T16:00:03Z rollout completed\n'}, expected: {cause: 'Schedule timezone mismatch: 09:00 Los Angeles was 16:00 UTC; ingestion was clear and rollout completed then.', evidence: ['ingestion.csv', 'schedule.conf', 'scheduler.log'], reframing: 'Reject the ingestion hypothesis using broader evidence. A pending child may be abandoned without an answer; that is optional, not a prompted required phase.'}, inputs: []},
  ];
  if (suite === 'runtime' || suite === 'semantic') {
    const datasets = Array.from({length: 8}, (_, batch) => {
      const values = rows.map((r, i) => row(r.id, Number(r.key) + batch * 6, Number(r.value) + batch * (i % 5 + 1) * 12, r.group));
      const totals = Array(8).fill(0);
      for (const r of values) totals[Number(r.group)] += gcd(Number(r.key), Number(r.value));
      return {id: `rows-${batch}`, rows: values, sums: totals};
    });
    families[1] = {id: 'repetitive',
      prompt: 'For each of the eight independently supplied batches, compute gcd(key, value) for every row and report the sum for each group. Preserve batch identity and explain how you established complete coverage. Choose an approach appropriate to repeated execution on changing inputs.',
      files: Object.fromEntries(datasets.map(batch => [`${batch.id}.csv`, 'id,key,value,group\n' + batch.rows.map(r => [r.id,r.key,r.value,r.group].join(',')).join('\n') + '\n'])),
      expected: {batches: datasets.map(batch => ({id: batch.id, sums: batch.sums, rows: batch.rows.length})), evidence: datasets.map(batch => `${batch.id}.csv`), economy: 'Judge measured total costs against matched ordinary/generic runs; choosing specialization is not by itself a benefit.'},
      inputs: datasets.map(batch => ({id: batch.id, description: `Complete typed input matching ${batch.id}.csv.`, rows: batch.rows, relation: [], selected: []}))};
  }
  await mkdir(directory, {recursive: true});
  const plan = {format: 'protean-workspace-evaluation/1', suite, efficacy: 'unmeasured', repetitions, seconds_per_case: seconds, profile: frozen.adaptive.profiles[0], initial_effort: frozen.adaptive.initial_effort, cases: []};
  for (const family of families) {
    const snapshot = join(directory, family.id, 'snapshot'); await mkdir(snapshot, {recursive: true});
    for (const [name, value] of Object.entries(family.files)) await writeFile(join(snapshot,name), value);
    const expected = json(family.expected), expected_sha256 = hash(expected);
    await writeFile(join(directory,family.id,'expected.json'), expected);
    const evidence = Object.entries(family.files).sort(([a],[b]) => a.localeCompare(b)).map(([path, text]) => ({path, sha256: hash(text)}));
    const evidence_sha256 = hash(json(evidence));
    for (let repetition = 0; repetition < repetitions; repetition++) for (const [arm, instruction] of Object.entries(selectedArms)) {
      const id = `${family.id}-${repetition}-${arm}`, configPath = join(directory, `${id}.json`);
      const selected = {...frozen, adaptive: {...frozen.adaptive, snapshot_root: snapshot}, tools: {...frozen.tools, build: arm !== 'ordinary', run: arm !== 'ordinary', reconstruct: arm === 'reconstruction', inputs: family.inputs}};
      await writeFile(configPath, json(selected));
      plan.cases.push({id, family: family.id, arm, repetition, config: configPath, config_sha256: hash(json(selected)), evidence, evidence_sha256, snapshot, prompt: `${family.prompt}\n\nEvaluation capability condition: ${instruction}`, expected: join(directory,family.id,'expected.json'), expected_sha256});
    }
  }
  await writeFile(join(directory,'plan.json'), json(plan));
  console.log(json({plan: join(directory,'plan.json'), cases: plan.cases.length, live_calls: 0, efficacy: 'unmeasured'}));
} else {
  assert(args.includes('--authorize-inference'), 'Live evaluation requires explicit --authorize-inference. prepare makes no provider calls.');
  const credential = option(args, '--credential-file'), chatgptAccount = option(args, '--chatgpt-account'),
    siwcBin = option(args, '--siwc-bin'), siwcAuthDir = option(args, '--siwc-auth-dir');
  inferenceArguments({credential, chatgptAccount, siwcBin, siwcAuthDir});
  const directory = resolve(option(args,'--plan','')), binary = resolve(option(args,'--binary','')), application = JSON.parse(await readFile(resolve(option(args,'--application','')),'utf8'));
  const plan = JSON.parse(await readFile(join(directory,'plan.json'),'utf8'));
  if (plan.format === 'protean-recurrence-evaluation/1') {
    console.log(json(await runRecurrence(directory, {binary, driver: resolve(option(args, '--driver', '')),
      applicationPath: resolve(option(args, '--application', '')), credential, chatgptAccount, siwcBin, siwcAuthDir})));
  } else {
  assert(credential, 'This suite requires --credential-file; ChatGPT plan inference is supported by recurrence.');
  assert.equal(plan.format,'protean-workspace-evaluation/1');
  const build = command(binary,['describe-build']); assert.equal(build.application_assets_sha256, hash(await readFile(resolve(option(args,'--application','')))));
  const reports = [];
  for (const subject of plan.cases) {
    await validatePreparedCase(subject);
    const output = join(directory,subject.id); await mkdir(output); // Refuse to overwrite an earlier paid attempt.
    const report = await evaluateCase({subject, build, output, binary, credential, application, seconds: plan.seconds_per_case});
    reports.push(report);
    await writeFile(join(directory,'results.json'),json({format:plan.format,plan_sha256:hash(json(plan)),reports}));
    if (report.errors.length) throw new Error('Evaluation attempt failed; observations retained in ' + join(output, 'report.json'));
  }
  console.log(json({results:join(directory,'results.json'),runs:reports.length,efficacy:'requires recorded adjudication'}));
  }
}

}
