import assert from 'node:assert/strict';
import {createHash, randomBytes} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {readArchive} from '../../test/protean/native_archive.mjs';
import {makeRepairCorpus, assessScan, scanContract, taskContract, candidateContract} from './interface_repair.mjs';
import {RecurrenceDriver, bytesUnder, command, inferenceArguments, tariffErrors} from './workspace.mjs';
import {executeRepairTask, writeRepairReport} from './interface_repair_task.mjs';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const arms = ['repair', 'fixed-lossy', 'evidence', 'fixed-adequate'];
const format = 'protean-interface-repair/1';
const encode = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const save = (path, bytes) => writeFile(path, bytes, {flag:'wx', mode:0o600});
const sourcesUsed = ['interface_repair.mjs', 'interface_repair_campaign.mjs', 'interface_repair_task.mjs',
  'interface_repair_trace.mjs', 'workspace.mjs', 'recurrence.mjs', 'request_profile.mjs', '../../test/protean/native_archive.mjs',
  '../../test/support/stdio-client.mts', '../../test/support/values.mjs', '../../test/protean/adaptive_capture_checks.mjs',
  '../native/qualification_process.mjs'];

let loadedEvaluator;
async function loadedSources() {
  const {Session} = await import('node:inspector/promises');
  const wanted = new Map(sourcesUsed.map(path=>[new URL(path,import.meta.url).href,path]));
  const hashes = new Map();
  const session = new Session();
  session.connect();
  try {
    session.on('Debugger.scriptParsed',({params})=>{
      const path = wanted.get(params.url);
      if (path) hashes.set(path,!hashes.has(path) || hashes.get(path) === params.hash ? params.hash : null);
    });
    await session.post('Debugger.enable');
    for (const path of sourcesUsed) assert(/^[a-f0-9]{64}$/.test(hashes.get(path) ?? ''),'Missing loaded evaluator identity: '+path);
    return Object.fromEntries(hashes);
  } finally { session.disconnect(); }
}

function repositoryHead() {
  const git = args=>spawnSync('git',['-C',repository,'rev-parse',...args],{encoding:'utf8'});
  const root = git(['--show-toplevel']);
  if (root.status !== 0 || resolve(root.stdout.trim()) !== resolve(repository)) return null;
  const head = git(['--verify','HEAD']);
  return head.status === 0 ? head.stdout.trim() : null;
}

async function identities({binary, driver}, applicationBytes) {
  loadedEvaluator ??= loadedSources();
  const loaded = await loadedEvaluator;
  const hashes = await Promise.all([binary, driver].map(async path => hash(await readFile(path))));
  const evaluator = Object.fromEntries(await Promise.all(sourcesUsed.map(async path =>
    [path, hash(await readFile(new URL(path, import.meta.url)))])));
  for (const path of sourcesUsed.filter(path=>path.endsWith('.mjs')))
    assert.equal(evaluator[path],loaded[path],'Loaded evaluator differs from its source: '+path);
  return {binary_sha256:hashes[0], driver_sha256:hashes[1], application_sha256:hash(applicationBytes),
    evaluator,loaded_evaluator:{...loaded},repository_head:repositoryHead()};
}

async function exportSources(driver, build) {
  const scratch = await realpath(await mkdtemp(join(tmpdir(), 'protean-repair-sources-')));
  async function preflight(name, study) {
    const args = ['--offline','--state-dir',join(scratch,name)];
    if (study) args.push('--interface-repair-bootstrap',hash('offline preparation'));
    const client = new RecurrenceDriver(driver, args);
    const timer = setTimeout(() => client.kill(), 30000);
    let verified = false;
    try {
      const sources = study ? null : await client.call('evaluation.interface_repair.sources');
      const assets = study ?? await client.call('evaluation.interface_repair.assets');
      const description = await client.call('describe');
      assert.equal(description.execution_mode,'offline');
      const task = await client.call('task.submit',{client_operation_id:'repair-preparation',
        application_id:'adaptive-agent',profile_id:description.profile.id,
        input:{schema_id:'adaptive-agent.input.v2',value:{task:'Validate the frozen experiment assets.'}}});
      const path = join(scratch,name+'.agnx');
      await client.call('evaluation.export',{task_id:task.task_id,path});
      const archive = readArchive(await readFile(path));
      assert.equal(archive.task.inference_attempts,0n);
      if (study) assert.deepEqual(archive.build,study.build,'Admitted study build differs from the private manifest.');
      else for (const field of ['program_sha256','application_assets_sha256'])
        assert.equal(archive.build[field],build[field],`Driver and product disagree on ${field}.`);
      verified = true;
      return {...sources,study:assets};
    } finally {
      clearTimeout(timer);
      const exit = await client.close();
      if (verified) assert.deepEqual(exit,{code:0,signal:null},'Offline preparation driver did not exit cleanly.');
    }
  }
  try {
    const raw = await preflight('ordinary',null);
    await preflight('study',raw.study);
    return raw;
  } finally { await rm(scratch,{recursive:true,force:true}); }
}

function validateEfforts(efforts, selected) {
  const supported = ['none','minimal','low','medium','high','xhigh','max'];
  assert(Array.isArray(efforts) && efforts.every(effort=>supported.includes(effort)) &&
    new Set(efforts).size === efforts.length, 'Invalid approved effort list.');
  assert(efforts.includes(selected), 'Initial effort is unavailable.');
}

export function selectRepairProfile(config) {
  assert.equal(config.schema, 'adaptive-agent.configuration.v3');
  const adaptive = config.adaptive;
  const selected = adaptive.profiles.filter(p => p.id === adaptive.initial_profile);
  assert.equal(selected.length, 1, 'Select exactly one approved initial profile.');
  const [profile] = selected;
  assert(/^gpt-[0-9]+(?:\.[0-9]+)*-astra$/.test(profile.model), 'Directed repair requires an approved Astra model.');
  validateEfforts(profile.efforts,adaptive.initial_effort);
  return {...profile, efforts:[adaptive.initial_effort], effort_update:false};
}

export function repairOrder(study, repetition) {
  if (study === 'episode') return ['repair'];
  assert.equal(study,'comparison');
  const index = repetition % arms.length;
  return [...arms.slice(index),...arms.slice(0,index)];
}

async function frozenFile(path, bytes) {
  await save(path, bytes);
  return {path,sha256:hash(bytes)};
}

function authorPrompt(complete, partial) {
  return [scanContract, 'The selected Boolean is true when no counterexample was observed. The original complete scan and the partial scan in paired-scan.json have the same Boolean output. Only the complete scan covers the domain.',
    'Inspect the current selection and original evidence. Use program.describe projection for a neutral executable envelope and program.inspect for the seed. Preserve the original domain, revision and source observations.',
    'The canonical development case is '+complete.case_id+'. The paired development case is '+partial.case_id+'.',
    candidateContract].join('\n\n');
}

function decisionPrompt(specimen) {
  return [taskContract,'Classify the scan for case '+specimen.case_id+'. Inspect the supplied presentation and evidence as needed. context.materialize(snapshot) supplies citable value references and context.expand exposes their bytes. Building or running new programs, selecting another view, reconstruction, and runtime replacement are outside this downstream condition.'].join('\n\n');
}

async function freezeSubject({root, iteration, arm, phase, specimen, paired, cases, config, profile, sources}) {
  const id = [iteration,arm,phase,specimen.case_id].join('-');
  const home = join(root,id), snapshot = join(home,'snapshot');
  await mkdir(snapshot,{recursive:true});
  let files = {...specimen.files};
  if (paired) {
    const {'scan.json':scan,...observations} = paired.files;
    for (const [name, bytes] of Object.entries(observations))
      assert(!(name in files) || files[name] === bytes, 'Development observations collide.');
    files = {...files,...observations,'paired-scan.json':scan};
  }
  const evidence = [];
  for (const [name, bytes] of Object.entries(files).sort(([a],[b])=>a.localeCompare(b))) {
    assert(/^[A-Za-z0-9_.-]+$/.test(name) && !['.','..'].includes(name));
    await save(join(snapshot,name),bytes);
    evidence.push({path:name,sha256:hash(bytes)});
  }
  const authored = phase === 'author';
  const selected = {schema:config.schema,adaptive:{...config.adaptive,snapshot_root:snapshot,profiles:[profile],skills:[]},
    tools:{build:authored && config.tools.build,run:authored && config.tools.run,reconstruct:false,inputs:[]}, semantic_construction:null};
  const cfg = await frozenFile(join(home,'config.json'),encode(selected));
  const source = authored || arm === 'fixed-lossy' ? sources.lossy : arm === 'fixed-adequate' ? sources.adequate : null;
  return {id,arm,phase,case_id:specimen.case_id,case_path:cases[specimen.case_id].specimen.path,
    paired_case_path:paired ? cases[paired.case_id].specimen.path : null, config:cfg.path,config_sha256:cfg.sha256,
    snapshot,evidence,seed_path:source?.path ?? null,prompt:authored ? authorPrompt(specimen,paired) : decisionPrompt(specimen)};
}

export async function prepareInterfaceRepair({config,directory,binary,driver,applicationPath,study='episode',
  repetitions=1,seconds=600,route='api-key',costModel={kind:'unpriced'}}, deps = {}) {
  config = structuredClone(config);
  costModel = structuredClone(costModel);
  assert(['episode','comparison'].includes(study));
  assert(Number.isSafeInteger(repetitions) && repetitions>0 && (study !== 'episode' || repetitions===1));
  assert(Number.isSafeInteger(seconds) && seconds>0 && Number.isSafeInteger(seconds*1000*repetitions*arms.length));
  assert(['api-key','chatgpt'].includes(route));
  assert(config.tools?.build === true && config.tools.run === true,
    'The approved configuration must allow build and run for the authoring task.');
  validateCostModel(costModel);
  const profile = selectRepairProfile(config);
  const approvedEfforts = config.adaptive.profiles.find(p=>p.id === profile.id).efforts;
  const ids = await identities({binary,driver},await readFile(applicationPath));
  const build = (deps.describeBuild ?? command)(binary,['describe-build']);
  assert.equal(build.application_assets_sha256,ids.application_sha256);
  await mkdir(directory,{mode:0o700});
  directory = await realpath(directory);
  const raw = await (deps.exportSources ?? exportSources)(driver,build);
  const privateRoot = join(directory,'private');
  await mkdir(privateRoot);
  assert.equal(typeof raw.study.application,'string');
  assert.match(raw.study.build.program_sha256,/^[0-9a-f]{64}$/);
  assert.equal(hash(raw.study.application),raw.study.build.application_assets_sha256);
  assert.equal(JSON.parse(raw.study.application).program_sha256,raw.study.build.program_sha256);
  assert.equal(typeof raw.lossy,'string');
  assert.equal(typeof raw.adequate,'string');
  assert.notEqual(raw.lossy,raw.adequate);
  const studyAssets = {application:await frozenFile(join(privateRoot,'application.json'),raw.study.application),
    build:raw.study.build};
  const sources = {};
  for (const key of ['lossy','adequate'])
    sources[key] = await frozenFile(join(privateRoot,key+'.json'),raw[key]);
  const cases = {}, conditions = [];
  const seed = randomBytes(32).toString('hex');
  for (let repetition=0; repetition<repetitions; repetition++) {
    const {development,transfer} = makeRepairCorpus(seed,repetition);
    for (const specimen of [...development,...transfer]) {
      if (cases[specimen.case_id]) {
        assert.equal(cases[specimen.case_id].specimen.sha256,hash(encode(specimen)));
        continue;
      }
      cases[specimen.case_id] = {
        specimen:await frozenFile(join(privateRoot,specimen.case_id+'.json'),encode(specimen)),
        expected:await frozenFile(join(privateRoot,specimen.case_id+'.expected.json'),encode(assessScan(specimen)))};
    }
    for (const arm of repairOrder(study,repetition)) {
      const common = {root:directory,iteration:repetition,arm,cases,config,profile,sources};
      const author = arm === 'repair' ? await freezeSubject({...common,phase:'author',specimen:development[0],paired:development[1]}) : null;
      const diagnostic = author ? {...author,id:author.id+'-diagnostic',phase:'diagnostic'} : null;
      const downstream = [];
      for (const specimen of transfer)
        downstream.push(await freezeSubject({...common,phase:'transfer',specimen}));
      conditions.push({repetition,arm,author,diagnostic,downstream,
        coverage_pair:{complete:transfer[0].case_id,partial:transfer[1].case_id}});
    }
  }
  const validateConfiguration = deps.validateConfiguration ?? (path => command(binary, [
    'validate','--config',path,...(route === 'chatgpt' ? ['--chatgpt-account','offline-validation'] : [])]));
  for (const condition of conditions) {
    for (const subject of [condition.author,...condition.downstream].filter(Boolean)) {
      const result = await validateConfiguration(subject.config);
      assert.equal(result.valid,true,'Product rejected the frozen configuration.');
    }
  }
  const condition_ms = seconds*1000;
  const campaign_ceiling_ms = conditions.length*(condition_ms+60_000);
  assert(Number.isSafeInteger(campaign_ceiling_ms));
  const plan = {format,suite:'interface-repair',study,seed,repetitions,identities:ids,build,study_assets:studyAssets,profile,
    initial_effort:config.adaptive.initial_effort,approved_efforts:approvedEfforts,route,cost_model:costModel,
    approved_tools:{build:config.tools.build,run:config.tools.run},
    condition_ms,campaign_ceiling_ms,
    deadline_scope:'Each condition has its own allowance for setup, authoring, replay and downstream work. The campaign reserves an additional minute per condition for process closure and post-expiry archive measurement. Finalization time is charged and recorded.',
    sources,cases,conditions};
  const bytes = encode(plan);
  await save(join(directory,'plan.json'),bytes);
  await save(join(directory,'plan.sha256'),hash(bytes)+'\n');
  return plan;
}

function validateCostModel(model) {
  assert(model && ['unpriced','tariff'].includes(model.kind), 'Expected an unpriced cost model or a declared tariff.');
  if (model.kind === 'tariff') assert.deepEqual(tariffErrors(model), [], 'Incomplete declared tariff.');
}

async function readRepairPlan(directory,options) {
  directory = await realpath(directory);
  const manifest = join(directory,'plan.json'), digest = join(directory,'plan.sha256');
  const preparedFiles = new Set([manifest,digest]);
  const bytes = await readFile(manifest);
  const plan_sha256 = hash(bytes);
  assert.equal(plan_sha256,(await readFile(digest,'utf8')).trim(),'Frozen plan changed.');
  const plan = JSON.parse(bytes);
  assert.equal(plan.format,format);
  assert.equal(plan.study_assets.application.path,join(directory,'private','application.json'),
    'Run the plan from its original preparation directory.');
  async function validateFile(file) {
    const contents = await readFile(file.path);
    assert.equal(hash(contents),file.sha256,'Frozen material changed: '+file.path);
    preparedFiles.add(file.path);
    return contents;
  }
  validateCostModel(plan.cost_model);
  validateEfforts(plan.approved_efforts,plan.initial_effort);
  assert.deepEqual(plan.profile.efforts,[plan.initial_effort]);
  assert.deepEqual(plan.approved_tools,{build:true,run:true},'Missing original build and run permissions.');
  const applicationBytes = await readFile(options.applicationPath);
  assert.deepEqual(plan.identities,await identities(options,applicationBytes),'Executable, application, evaluator or repository changed.');
  for (const file of Object.values(plan.sources)) await validateFile(file);
  for (const record of Object.values(plan.cases)) {
    const specimen = JSON.parse(await validateFile(record.specimen));
    assert.equal(encode(assessScan(specimen)),(await validateFile(record.expected)).toString());
  }
  for (const condition of plan.conditions) for (const subject of [condition.author,...condition.downstream].filter(Boolean)) {
    const config = JSON.parse(await validateFile({path:subject.config,sha256:subject.config_sha256}));
    assert.deepEqual(config.adaptive.profiles,[plan.profile]);
    assert.equal(config.adaptive.initial_profile,plan.profile.id);
    assert.equal(config.adaptive.initial_effort,plan.initial_effort);
    assert.equal(config.adaptive.snapshot_root,subject.snapshot);
    assert.deepEqual(config.adaptive.skills,[]);
    const author = subject.phase === 'author';
    assert.deepEqual(config.tools,{build:author,run:author,reconstruct:false,inputs:[]});
    const entries = await readdir(subject.snapshot,{withFileTypes:true});
    assert(entries.every(entry=>entry.isFile()),'Unexpected model-visible directory or link.');
    assert.deepEqual(entries.map(e=>e.name).sort(),subject.evidence.map(e=>e.path).sort(),'Snapshot exposure changed.');
    for (const file of subject.evidence)
      await validateFile({path:join(subject.snapshot,file.path),sha256:file.sha256});
  }
  const studyBytes = await validateFile(plan.study_assets.application);
  const application = JSON.parse(studyBytes);
  assert.equal(hash(studyBytes),plan.study_assets.build.application_assets_sha256);
  assert.equal(application.program_sha256,plan.study_assets.build.program_sha256);
  return {plan,plan_sha256,application,directory,preparedFiles};
}

export async function validateRepairPlan(directory,options) {
  return (await readRepairPlan(directory,options)).plan;
}

function bootstrapBuild(report) {
  const observed = report?.bootstrap?.build_metrics ?? report?.bootstrap_build_metrics;
  const readsOnly = report?.effective_condition === 'ordinary';
  const beforeBootstrap = report?.errors?.some(error=>error.stage === 'setup');
  const performed = report?.bootstrap?.program?.kind === 'program' || Boolean(report?.candidate_rejection);
  const commands = observed ? observed.build_commands : performed ? 1 : readsOnly || beforeBootstrap ? 0 : null;
  const ns = field => {
    const raw = observed?.[field];
    const value = typeof raw === 'string' && /^[0-9]+$/.test(raw) ? Number(raw) : raw;
    return Number.isSafeInteger(value) && value >= 0 ? value : commands === 0 ? 0 : null;
  };
  return {commands, rejected:observed && Object.hasOwn(observed,'rejected_build_commands') ? observed.rejected_build_commands :
    (commands === 0 || report?.bootstrap?.program || (performed && report.candidate_rejection !== 'ProjectionBuildRejected') ? 0 : null),
    elapsed:ns('build_elapsed_nanoseconds'),compiler:ns('compiler_nanoseconds')};
}

function providerTraffic(report) {
  if (report?.execution_mode === 'scripted_fixture') return {attempts:[],complete:true};
  const archived = report?.metrics?.physical_attempts;
  const attempts = archived ?? report?.observed_provider_attempts ?? [];
  return {attempts,complete:Array.isArray(archived) && report.final_metrics_complete !== false ||
    report?.inference_dispatch_possible === false && attempts.length === 0};
}

function taskCharges(report, model, traffic) {
  const measured = value=>Number.isFinite(value) && value >= 0;
  const count = value=>Number.isSafeInteger(value) && value >= 0;
  const charged = report?.cost?.complete === true && measured(report.cost.total) ? report.cost.total : null;
  if (tariffErrors(model).length) return {inference:null,total:charged,knownInference:0,knownTotal:charged ?? 0};
  const inputRate = model.input_per_million, cachedRate = model.cached_input_per_million, outputRate = model.output_per_million;
  let exact = traffic.complete || (inputRate === 0 && cachedRate === 0 && outputRate === 0);
  let inference = 0;
  for (const {usage} of traffic.attempts) {
    const input = usage?.input_tokens, cached = usage?.input_tokens_details?.cached_tokens, output = usage?.output_tokens;
    if (count(input)) {
      if (count(cached) && cached <= input) inference += ((input-cached)*inputRate+cached*cachedRate)/1000000;
      else {
        inference += input*Math.min(inputRate,cachedRate)/1000000;
        if (input > 0 && inputRate !== cachedRate) exact = false;
      }
    } else {
      if (count(cached)) inference += cached*cachedRate/1000000;
      if (inputRate !== 0 || (cachedRate !== 0 && !count(cached))) exact = false;
    }
    if (count(output)) inference += output*outputRate/1000000;
    else if (outputRate !== 0) exact = false;
  }
  if (measured(report?.cost?.inference)) { inference = report.cost.inference; exact = true; }
  const host = model.host_per_second === 0 ? 0 : measured(report?.elapsed_ms) ?
    report.elapsed_ms/1000*model.host_per_second : null;
  const storage = model.storage_per_byte_second === 0 || model.retention_seconds === 0 ? 0 :
    count(report?.retained_namespace_bytes) ? report.retained_namespace_bytes*model.retention_seconds*model.storage_per_byte_second : null;
  const knownTotal = charged ?? inference+(host ?? 0)+(storage ?? 0);
  const total = charged ?? (exact && host !== null && storage !== null ? knownTotal : null);
  return {inference:exact ? inference : null,total,knownInference:inference,knownTotal};
}

function resources(tasks, costModel) {
  const started = tasks.filter(t=>t.state !== 'not_started');
  const traffic = started.map(t=>providerTraffic(t.report));
  const attempts = traffic.flatMap(group=>group.attempts);
  const countKnown = traffic.every(group=>group.complete);
  const count = value => Number.isSafeInteger(value) && value >= 0;
  const knownSum = values => values.reduce((sum, value)=>sum+(count(value) ? value : 0),0);
  const missingUsage = attempts.filter(a=>!count(a.usage?.input_tokens) || !count(a.usage?.output_tokens)).length;
  const bodyBytes = attempts.map(a=>a.request_body_bytes);
  const knownBodyBytes = knownSum(bodyBytes);
  const total = values=>values.every(count) ? knownSum(values) : null;
  const taskMetric = key => {
    const fields = started.map(t=>t.report?.metrics?.[key]);
    return fields.every(count) && started.every(t=>t.report?.final_metrics_complete !== false) ? knownSum(fields) : null;
  };
  const namespaces = started.map(t=>t.report?.retained_namespace_bytes);
  const bootstrap = started.map(t=>bootstrapBuild(t.report));
  const bootstrapCommands = bootstrap.map(b=>b.commands), capturedBuilds = taskMetric('builds');
  const issuedBuilds = taskMetric('build_attempts'), settledBuilds = taskMetric('settled_builds');
  const timedBuilds = taskMetric('timed_builds'), commands = taskMetric('build_commands');
  const capturedCompiler = knownSum(started.map(t=>t.report?.metrics?.compiler_nanoseconds));
  const rejected = bootstrap.map(b=>b.rejected);
  const knownRejected = knownSum([...rejected,...started.map(t=>t.report?.metrics?.known_rejected_build_commands)]);
  const rss = started.map(t=>t.report?.peak_rss_sampled_bytes).filter(count);
  const charges = costModel.kind === 'tariff' ? started.map((t,i)=>taskCharges(t.report,costModel,traffic[i])) : [];
  const sumCharges = field=>costModel.kind === 'tariff' && charges.every(c=>Number.isFinite(c[field])) ?
    charges.reduce((sum,c)=>sum+c[field],0) : null;
  return {known_physical_attempts:attempts.length, physical_attempts:countKnown ? attempts.length : null,
    usage_complete:countKnown && !missingUsage, known_input_tokens:knownSum(attempts.map(a=>a.usage?.input_tokens)),
    known_output_tokens:knownSum(attempts.map(a=>a.usage?.output_tokens)), missing_usage_attempts:missingUsage,
    known_request_body_bytes:knownBodyBytes, request_body_bytes:countKnown && bodyBytes.every(count) ? knownBodyBytes : null,
    captured_builds:capturedBuilds,bootstrap_builds:total(bootstrapCommands),known_bootstrap_builds:knownSum(bootstrapCommands),
    dispatched_builds:issuedBuilds,settled_builds:settledBuilds,timed_builds:timedBuilds,
    builds:total([commands,...bootstrapCommands]),known_builds:knownSum([...bootstrapCommands,...started.map(t=>t.report?.metrics?.build_commands)]),
    rejected_builds:total([taskMetric('rejected_build_commands'),...rejected]),known_rejected_builds:knownRejected,
    work_items:taskMetric('work_items'),captured_compiler_nanoseconds:capturedCompiler,
    bootstrap_build_elapsed_nanoseconds:total(bootstrap.map(b=>b.elapsed)),
    compiler_nanoseconds:issuedBuilds !== null && issuedBuilds === settledBuilds && issuedBuilds === timedBuilds ?
      total([taskMetric('compiler_nanoseconds'),...bootstrap.map(b=>b.compiler)]) : null,result_bytes:taskMetric('result_bytes'),
    retained_namespace_bytes:namespaces.every(count) ? knownSum(namespaces) : null,
    max_sampled_rss_bytes:rss.length ? rss.reduce((a,b)=>Math.max(a,b)) : null,
    monetary_scope:'task_execution_and_retention',
    monetary_cost:sumCharges('total'),known_monetary_cost:sumCharges('knownTotal'),
    inference_cost:sumCharges('inference'),known_inference_cost:sumCharges('knownInference'),
    cost_model:costModel.id ?? costModel.kind};
}

function inventoriedControllerDelivery(report) {
  if (report?.inference_dispatch_possible === false && report.execution_mode !== 'scripted_fixture') return [];
  if (report?.final_metrics_complete !== true) return null;
  const inventory = report?.metrics?.physical_attempts;
  if (!Array.isArray(inventory)) return report.metrics?.controller?.calls === 0 ? [] : null;
  if (inventory.some(a=>a.role !== 'delegated' && a.role !== 'controller')) return null;
  const controllers = inventory.filter(a=>a.role === 'controller');
  const count = report.metrics?.controller?.calls;
  if (count != null && count !== controllers.length) return null;
  const rows = controllers.map(a=>a.id && report.adjudication?.delivery?.find(d=>d.id === a.id));
  return rows.every(Boolean) ? rows : null;
}

function initialPresentation(report) {
  const trace = report?.adjudication;
  const attempts = trace?.delivery?.filter(a=>a.delivery !== 'not_sent' && a.model_response !== false);
  const unknown = {confirmed:null,one_computed_block:null};
  if (!attempts?.length && inventoriedControllerDelivery(report)?.every(a=>a.model_response === false))
    return {confirmed:false,one_computed_block:null};
  if (!attempts?.length || attempts.some(a => a.preparation_cut == null)) return unknown;
  const first = attempts.reduce((a, b) => BigInt(a.preparation_cut) <= BigInt(b.preparation_cut) ? a : b);
  const sameCut = attempts.filter(a => BigInt(a.preparation_cut) === BigInt(first.preparation_cut));
  if (sameCut.some(a => a.prepared_sha256 !== first.prepared_sha256)) return unknown;
  const confirmed = sameCut.find(a => a.delivery === 'confirmed' && a.model_response === true);
  if (!confirmed) return unknown;
  if (report.effective_condition === 'ordinary') return {confirmed:confirmed.selected_view === null,one_computed_block:null};
  const view = report.bootstrap?.view;
  if (!view || view.id !== confirmed.selected_view) return {confirmed:false,one_computed_block:false};
  const exposure = trace.projection?.exposures.find(e=>e.id === confirmed.id);
  return {confirmed:exposure?.rendered ?? null,one_computed_block:exposure?.one_computed_block ?? null};
}

function decisionState(report) {
  const tag = report?.result?.outcome?.value?.result?.tag;
  if (['refusal','capacity','no_result'].includes(tag)) return tag;
  if (report?.grading == null) return tag === 'report' ? 'ungraded_report' : 'unanswered';
  if (report.adjudication?.report_bound !== true) return 'unbound_report';
  return report.grading.answer ? 'answered' : 'malformed_answer';
}

function allObserved(facts) {
  if (facts.includes(false)) return false;
  return facts.every(fact=>fact === true) ? true : null;
}

export function gradeCondition(condition, tasks, costModel) {
  const authorTask = tasks.find(t=>t.subject.phase === 'author');
  const author = authorTask?.report;
  const diagnostic = tasks.find(t=>t.subject.phase === 'diagnostic')?.report;
  const transfer = tasks.filter(t=>t.subject.phase === 'transfer');
  const collision = diagnostic?.adjudication?.collision ?? null;
  const cases = condition.downstream.map(subject=>{
    const t = transfer.find(task=>task.subject.case_id === subject.case_id) ?? {subject,state:'missing_record'};
    const r = t.report, grade = r?.grading, trace = r?.adjudication, projection = trace?.projection;
    const bound = trace?.report_bound === true;
    const initial = initialPresentation(r);
    const ordinary = condition.arm === 'evidence' || condition.arm === 'repair' && !author?.adjudication?.candidate;
    const expectedArm = ordinary ? 'ordinary' : condition.arm;
    const compliant = allObserved([initial.confirmed, r?.effective_condition == null ? null : r.effective_condition === expectedArm,
      Array.isArray(r?.arm_violations) ? r.arm_violations.length === 0 : null,
      expectedArm === 'ordinary' || allObserved([projection?.one_computed_block,initial.one_computed_block])]);
    const decision = decisionState(r), answered = decision === 'answered';
    const sameRef = (a,b) => a && b && a.kind === b.kind && a.id === b.id;
    const citedProjection = answered ? Boolean(projection && grade.answer.support.some(ref=>sameRef(ref,projection.result))) : null;
    const projectedAlias = ref=>projection && trace.exposure?.some(row=>sameRef(row.projected_result,projection.result) &&
      !sameRef(row.ref,projection.result) && sameRef(ref,row.ref));
    const citedAlias = answered ? grade.answer.support.some(projectedAlias) : null;
    const projectionCited = citedProjection || citedAlias;
    const otherCited = answered ? grade.answer.support.some(ref=>!sameRef(ref,projection?.result) && !projectedAlias(ref)) : null;
    const projectionSupport = !answered ? null : !projectionCited ? false :
      Object.hasOwn(grade,'projection_citations_supported') ? grade.projection_citations_supported :
      !otherCited && projection.semantic_judgment === 'supported' ? grade.supported : null;
    const exposures = projection?.exposures ?? [];
    const ordinaryOnly = r?.effective_condition === 'ordinary' && !projection && bound && trace.evidence_complete &&
      trace.delivery?.some(e=>e.model_response === true) && trace.delivery.every(e=>
        e.selected_view === null || e.delivery === 'not_sent' || e.model_response === false);
    const inventoried = inventoriedControllerDelivery(r);
    const exposed = exposures.some(e=>e.rendered && e.delivery === 'confirmed' && e.model_response === true) ? true :
      inventoried?.every(a=>a.model_response === false) || ordinaryOnly ||
      (trace?.evidence_complete || inventoried) && exposures.length && exposures.every(e=>e.rendered === false ||
        e.delivery === 'not_sent' || e.model_response === false) ? false : null;
    const projectionBinding = condition.arm === 'repair' ? trace?.transfer_bound : projection?.canonical_input;
    const supportedUse = !answered ? null : allObserved([grade.supported,projectionCited,projectionSupport,compliant,exposed,
      projectionBinding]);
    return {case_id:t.subject.case_id,state:t.state === 'completed' && !answered ? decision : t.state,
      decision, native_status:r?.status?.status ?? null,task_report:t.file ?? null,answer:grade?.answer?.outcome ?? null,
      grading_errors:grade?.errors ?? null,errors:r?.errors ?? [],
      initial_presentation_confirmed:initial.confirmed,
      correct:bound ? grade?.outcome_correct ?? null : null, supported:bound ? grade?.supported ?? null : null,
      unsupported_exhaustion:bound ? grade?.unsupported_exhaustion ?? null : null, compliant:r ? compliant : null,
      transfer_bound:trace?.transfer_bound ?? null,ordinary_fallback:trace?.ordinary_fallback ?? null,
      fallback_reason:r?.fallback_reason ?? null,effective_condition:r?.effective_condition ?? null,delivery:trace?.delivery ?? null,
      candidate_rejection:r?.candidate_rejection ?? null,
      semantic_judgment:projection?.semantic_judgment ?? null,
      schema_judgment:projection?.schema_judgment ?? null,
      exact_evidence_preservation:projection?.exact_evidence_preservation ?? null,
      cited_projection:citedProjection,cited_projection_alias:citedAlias,supported_view_use:supportedUse,
      other_evidence_cited:otherCited,projection_citations_supported:projectionSupport,
      needs_payload_adjudication:answered && (grade.supported == null && grade.errors?.includes('unadjudicated_payload') === true ||
        projectionSupport == null && grade.projection_citation_errors?.includes('unadjudicated_payload') === true),
      exposed_computed:exposed};
  });
  const complete = cases.length > 0 && cases.every(c=>c.state === 'completed' && c.decision === 'answered');
  const allSupported = complete && cases.every(c=>c.supported === true);
  const authored = author?.adjudication?.authored_and_applied === true;
  const supportedUses = cases.filter(c=>c.state === 'completed' && c.supported_view_use === true);
  const initialAuthor = initialPresentation(author).confirmed;
  const authorCompliant = initialAuthor === true && author?.effective_condition === 'repair' &&
    Array.isArray(author.arm_violations) && !author.arm_violations.length && author.adjudication?.applied_use?.one_computed_block === true;
  const completeOutcome = 'exhausted_declared_domain';
  const diagnosticSupported = collision?.distinction_preserved === true &&
    collision.left?.semantic_judgment === 'supported' && collision.left.expected === completeOutcome &&
    collision.right?.semantic_judgment === 'supported' && collision.right.expected === 'incomplete';
  const coverageDemonstrated = authored && authorCompliant && diagnosticSupported &&
    supportedUses.some(c=>c.case_id === condition.coverage_pair?.complete && c.answer === completeOutcome) &&
    supportedUses.some(c=>c.case_id === condition.coverage_pair?.partial && c.answer === 'incomplete');
  const incorrectProjections = cases.filter(c=>c.transfer_bound === true &&
    (c.schema_judgment === 'incorrect' || c.semantic_judgment === 'incorrect')).map(c=>c.case_id);
  const rejectedReplays = cases.filter(c=>c.candidate_rejection != null).map(c=>c.case_id);
  const opportunity = authorTask?.state === 'not_started' ? false : author?.authoring_opportunity ?? null;
  const buildAction = author?.metrics?.actions?.some(a=>a.name === 'program' && a.arguments?.command?.tag === 'build');
  const attempted = author?.execution_mode === 'scripted_fixture' ? false :
    author?.adjudication?.builds?.length || buildAction ? true :
    opportunity === false || author?.final_metrics_complete && buildAction === false ? false : null;
  return {repetition:condition.repetition,arm:condition.arm,planned_cases:condition.downstream.length,cases,
    author_report:authorTask?.file ?? null,
    diagnostic_report:tasks.find(t=>t.subject.phase === 'diagnostic')?.file ?? null,
    authoring_opportunity:opportunity,authoring_attempted:attempted,author_initial_presentation_confirmed:initialAuthor,
    candidate_admitted:!!author?.adjudication?.candidate,authored_and_applied:authored,
    authoring_state:authorTask?.state ?? null,
    nomination:author?.nomination?.status ?? null,nomination_error:author?.nomination_error ?? null,
    diagnosis:author?.nomination?.diagnosis ?? null,authoring_errors:author?.errors ?? [],
    collision,coverage_pair:condition.coverage_pair ?? null,
    coverage_repair_demonstrated:condition.arm === 'repair' ? coverageDemonstrated : null,
    incorrect_projection_cases:incorrectProjections,rejected_replay_cases:rejectedReplays,
    supported_repair:condition.arm !== 'repair' ? null : coverageDemonstrated && !incorrectProjections.length && !rejectedReplays.length &&
      cases.every(c=>c.state === 'not_started' || c.state === 'completed' && c.supported_view_use === true) ?
      'demonstrated_on_tested_cases' : 'unestablished',
    supported_view_use_cases:supportedUses.map(c=>c.case_id),
    answered_cases:cases.filter(c=>c.decision === 'answered').length,
    completed_cases:cases.filter(c=>c.state === 'completed' && c.decision === 'answered').length,
    all_cases_completed:complete,all_cases_supported:allSupported,supported_answers:cases.filter(c=>c.supported).length,
    end_to_end_resources:resources(tasks,costModel), downstream_resources:resources(transfer,costModel)};
}

function taskState(report) {
  if (report.timed_out) return 'timed_out';
  if (report.errors.length) return 'infrastructure_failure';
  if (report.candidate_rejection) return 'candidate_rejected';
  if (report.subject.phase === 'diagnostic')
    return typeof report.adjudication?.collision?.distinction_preserved === 'boolean' ? 'completed' : 'unanswered';
  if (report.status?.status !== 'completed') return 'unanswered';
  if (report.subject.phase === 'transfer') {
    const decision = decisionState(report);
    return decision === 'answered' ? 'completed' : decision;
  }
  return 'completed';
}

export function formatRepairResults(results) {
  const rows = results.conditions.map(c=>`| ${c.repetition+1} | ${c.arm} | ${c.answered_cases}/${c.planned_cases} | ${c.completed_cases} | ${c.supported_answers} | ${c.authored_and_applied ? 'yes' : '—'} | ${c.end_to_end_resources.known_physical_attempts} | ${c.elapsed_ms.toFixed(0)} |`);
  const lines = ['# Directed interface repair','',
    '| Repetition | Condition | Answered decisions | Completed cases | Supported answers | Authored and applied | Known provider attempts | Elapsed ms |',
    '|---|---|---:|---:|---:|---|---:|---:|',...rows,'',
    'One candidate reused across multiple cases counts as one authoring attempt.',''];
  const label = flag => flag == null ? 'unknown' : flag ? 'yes' : 'no';
  for (const c of results.conditions) {
    const counts = new Map();
    for (const row of c.cases) counts.set(row.state,(counts.get(row.state) ?? 0)+1);
    lines.push('## Repetition '+(c.repetition+1)+' · '+c.arm,'');
    if (c.arm === 'repair') {
      lines.push('Authoring opportunity was recorded as '+label(c.authoring_opportunity)+
        ' and a build attempt as '+label(c.authoring_attempted)+'. Authoring ended with `'+c.authoring_state+'`. Nomination was `'+(c.nomination ?? 'unavailable')+
        '`. Supported repair was `'+c.supported_repair+'`.','');
      if (c.coverage_repair_demonstrated) lines.push('The authored view supported the fresh complete and partial coverage decisions.','');
      if (c.incorrect_projection_cases.length) lines.push('The transfer projector gave an incorrect payload on '+
        c.incorrect_projection_cases.map(id=>'`'+id+'`').join(', ')+'.','');
      if (c.rejected_replay_cases.length) lines.push('The candidate was rejected during replay on '+
        c.rejected_replay_cases.map(id=>'`'+id+'`').join(', ')+'.','');
    }
    const r = c.end_to_end_resources;
    lines.push([...counts].map(([state,count])=>count+' '+state).join(', ')+'.',
      'Known usage was '+r.known_input_tokens+' input tokens and '+r.known_output_tokens+' output tokens.'+
      (r.usage_complete ? '' : ' These are lower bounds.')+
      ' Prepared request bodies for confirmed or possible provider attempts accounted for '+r.known_request_body_bytes+' known bytes.'+
      (r.request_body_bytes === null ? ' Their total size is unknown.' : '')+
      (r.monetary_cost === null ? r.known_monetary_cost === null ? ' Total task charges are unknown.' :
        ' Known task charges under the frozen tariff were at least '+r.known_monetary_cost+'.' :
        ' Task charges under the frozen tariff were '+r.monetary_cost+'.'),'',
      '| Case | Status | Answer | Supported | Ordinary evidence accessed | Cited view supports answer | Credited view use |',
      '|---|---|---|---|---|---|---|');
    for (const row of c.cases) lines.push('| '+[row.case_id,row.state,row.answer ?? '—',label(row.supported),
      label(row.ordinary_fallback),label(row.projection_citations_supported),label(row.supported_view_use)].join(' | ')+' |');
    lines.push('');
  }
  return lines.join('\n');
}

export async function runInterfaceRepair(directory, options, {execute=executeRepairTask,now=()=>performance.now()} = {}) {
  options = {...options};
  assert(options.authorizeInference === true,'Explicit --authorize-inference is required.');
  inferenceArguments(options);
  const campaignStart = now();
  const {plan,plan_sha256,application,directory:preparedDirectory,preparedFiles} = await readRepairPlan(directory,options);
  assert.equal(options.chatgptAccount ? 'chatgpt' : 'api-key',plan.route,'Credential route differs from preparation.');
  const output = join(preparedDirectory,'run');
  await mkdir(output,{mode:0o700});
  const results = {format,plan_sha256,study:plan.study,timing_file:'timing.json',conditions:[],paired_cases:[]};
  const campaignDeadline = campaignStart+plan.campaign_ceiling_ms;
  let inferenceCost = plan.cost_model.kind === 'tariff' ? 0 : null;
  for (const condition of plan.conditions) {
    const start = now(), deadline = Math.min(start+plan.condition_ms,campaignDeadline);
    let candidate = null;
    const tasks = [];
    const run = async subject=>{
      if (now() >= deadline) {
        tasks.push({subject,state:'not_started',file:null});
        return null;
      }
      const dir = join(output,subject.id);
      await mkdir(dir);
      let report;
      try {
        report = await execute({...options,output:dir,subject,candidate,deadline,build:plan.study_assets.build,
          application,plan,plan_sha256});
      } catch (error) {
        report = {subject,errors:[{stage:'task_runner',name:error.name,message:error.message}],status:null,
          metrics:null,timed_out:false};
        await writeRepairReport(join(dir,'failure.json'),report,2);
        tasks.push({subject,report,file:join(dir,'failure.json'),state:'infrastructure_failure'});
        return report;
      }
      tasks.push({subject,report,file:join(dir,'report.json'),state:taskState(report)});
      return report;
    };
    if (condition.author) {
      const author = await run(condition.author);
      candidate = author?.adjudication?.candidate ?? null;
      if (candidate) await run(condition.diagnostic);
    }
    for (const subject of condition.downstream) await run(subject);
    const measured = gradeCondition(condition,tasks,plan.cost_model);
    const charged = measured.end_to_end_resources.inference_cost;
    inferenceCost = inferenceCost !== null && charged !== null ? inferenceCost+charged : null;
    measured.elapsed_ms = now()-start;
    measured.effective_allowance_ms = Math.max(0,deadline-start);
    measured.deadline_overrun_ms = Math.max(0,measured.elapsed_ms-measured.effective_allowance_ms);
    results.conditions.push(measured);
    await writeRepairReport(join(output,condition.repetition+'-'+condition.arm+'.json'),measured,2);
  }
  for (let i=0;i<plan.repetitions;i++) {
    const conditions = results.conditions.filter(c=>c.repetition===i);
    for (const row of conditions[0].cases) results.paired_cases.push({repetition:i,case_id:row.case_id,
      conditions:Object.fromEntries(conditions.map(c=>[c.arm,c.cases.find(r=>r.case_id===row.case_id)]))});
  }
  await writeRepairReport(join(output,'results.json'),results,2);
  await save(join(output,'results.md'),formatRepairResults(results));
  let retained_bytes = await bytesUnder(output);
  for (const path of preparedFiles) {
    let file;
    try { file = await lstat(path); } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    if (file.isFile()) retained_bytes += file.size;
  }
  const elapsed_ms = now()-campaignStart;
  const timing = join(output,results.timing_file);
  const model = plan.cost_model;
  const host = model.kind === 'tariff' ? elapsed_ms / 1000 * model.host_per_second : null;
  const storage = model.kind === 'tariff' ? retained_bytes * model.storage_per_byte_second * model.retention_seconds : null;
  const total = inferenceCost !== null ? inferenceCost + host + storage : null;
  const knownInference = model.kind === 'tariff' ?
    results.conditions.reduce((sum,c)=>sum+c.end_to_end_resources.known_inference_cost,0) : null;
  await save(timing,encode({plan_sha256,elapsed_ms,campaign_ceiling_ms:plan.campaign_ceiling_ms,
    campaign_ceiling_exceeded:elapsed_ms>plan.campaign_ceiling_ms,retained_bytes,
    cost:{model:model.id ?? model.kind,currency:model.currency ?? null,inference:inferenceCost,known_inference:knownInference,
      known_total:knownInference === null ? null : knownInference+host+storage,host,storage,
      total:Number.isFinite(total) ? total : null}}));
  return {results:join(output,'results.json'),summary:join(output,'results.md'),timing,conditions:results.conditions.length};
}
