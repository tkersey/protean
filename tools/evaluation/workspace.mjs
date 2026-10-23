// Live model-use evaluation is opt-in; native fixtures reuse the offline helpers.
import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile, readdir, stat} from 'node:fs/promises';
import {resolve, join, dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {ProteanClient} from '../../test/support/stdio-client.mts';
import {readArchive} from '../../test/protean/native_archive.mjs';
import {decodeValue} from '../../test/support/values.mjs';
import {contract} from '../../test/protean/adaptive_capture_checks.mjs';

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
  console.log('prepare --config CONFIG --out DIRECTORY [--suite workspace|runtime|reconstruction|semantic] [--repetitions 1] [--seconds 600]\nrun --plan DIRECTORY --binary BINARY --application APPLICATION_JSON --authorize-inference --credential-file PRIVATE_FILE');
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
    const guestView = name === 'context' && command?.tag === 'materialize' && command.value?.input?.tag === 'guest_view';
    const replacement = name === 'work' && (['realize', 'realize_controller', 'guard'].includes(command?.tag) ||
      (command?.tag === 'start' && command.value?.runtime?.tag === 'selected'));
    const candidate = name === 'program' && ['derive', 'validate'].includes(command?.tag);
    if (arm === 'interpretation') return replacement || candidate || (name === 'program' && command?.tag === 'specialize');
    if (arm === 'specialization') return candidate || guestView ||
      (name === 'work' && ['guard', 'observe'].includes(command?.tag)) ||
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
export function workspaceMetrics(archive, application) {
  const captured = contract(application, 'CapturedResponse');
  const replySchema = contract(application, 'WorkspaceReply');
  const adaptiveResult = contract(application, 'AdaptiveResult');
  const adaptivePrepared = contract(application, 'AdaptivePrepared');
  const attempts = new Map(archive.manifest[6].filter(([kind]) => kind === 5).map(([, id, ref]) => [Buffer.from(id).toString('hex'), decodeValue(archive.schemas.get('attempt'), archive.object(ref))]));
  const captures = new Map(archive.manifest[6].filter(([kind]) => kind === 4).map(([, id, ref]) => [Buffer.from(id).toString('hex'), decodeValue(archive.schemas.get('capture'), archive.object(ref))]));
  const occurrences = new Map(archive.manifest[6].filter(([kind]) => kind === 0).map(([, id, ref]) => [Buffer.from(id).toString('hex'), decodeValue(archive.schemas.get('occurrence'), archive.object(ref))]));
  const stats = {controller: {calls: 0, input_tokens: 0, output_tokens: 0, missing_usage: 0, prepared_bytes: 0}, delegated: {calls: 0, input_tokens: 0, output_tokens: 0, missing_usage: 0, prepared_bytes: 0}, builds: 0, rejected_builds: 0, compiler_nanoseconds: 0, native_publication_nanoseconds: 0, checkpoint_publications: 0, current_checkpoint_bytes: 0, work_items: 0, result_bytes: 0, actions: [],
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
  const actions = [];
  // Count possible provider delivery, including unknown delivery, but exclude
  // positive non-invocation evidence. Rearming an occurrence is only permitted
  // from not_sent, so older uncaptured attempts are also known not to have run.
  for (const [id, attempt] of attempts) {
    const role = attempt[5] === 'agent.model.invoke.v11' ? 'controller' : attempt[5] === 'protean.workspace.inference/1' ? 'delegated' : null;
    if (!role) continue;
    const capture = captures.get(id);
    const occurrence = occurrences.get(Buffer.from(attempt[2]).toString('hex'));
    const state = occurrence?.[3];
    let notSent = capture?.[5] === 1;
    if (!capture && state) {
      if (state.tag === 0 || state.tag === 6) notSent = true; // ready after rearm, or not_sent
      else if ([1, 2, 3, 4, 7].includes(state.tag)) {
        notSent = Buffer.from(state.value[0]).toString('hex') !== id;
      } else if (state.tag === 5) {
        // Cancellation cannot consume unknown/dispatching/captured inference.
        notSent = state.value.tag === 1 || Buffer.from(state.value.value[0]).toString('hex') !== id;
      }
    }
    const count = stats[role];
    if (attempt[7].tag === 1) count.prepared_bytes += Number(attempt[7].value[1]);
    if (notSent) continue;
    count.calls++;
    if (!capture || capture[4].tag !== 1) { count.missing_usage++; continue; }
    const raw = decodeValue(captured, archive.object(capture[4].value));
    // Capture precedes response interpretation: HTTP errors and malformed
    // provider output still incurred a call, but supply no usable usage.
    let response;
    try { response = JSON.parse(Buffer.from(raw[3]).toString()); } catch { response = null; }
    const usage = response?.usage;
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
      assert.equal(work.length, 38);
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
      await runCommand(binary, ['export-checkpoint', '--state-dir', state, '--task-id', task.task_id, '--output', archivePath]);
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

if (import.meta.main) {
if (mode === 'prepare') {
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
  const credential = option(args, '--credential-file'); assert(credential, 'Provide the separately authorized credential file.');
  const directory = resolve(option(args,'--plan','')), binary = resolve(option(args,'--binary','')), application = JSON.parse(await readFile(resolve(option(args,'--application','')),'utf8'));
  const plan = JSON.parse(await readFile(join(directory,'plan.json'),'utf8')); assert.equal(plan.format,'protean-workspace-evaluation/1');
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
