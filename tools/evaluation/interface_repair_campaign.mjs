import assert from 'node:assert/strict';
import {createHash, randomBytes} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {readArchive} from '../../test/protean/native_archive.mjs';
import {makeRepairCorpus, assessScan, scanContract, taskContract, candidateContract} from './interface_repair.mjs';
import {RecurrenceDriver, command} from './workspace.mjs';
import {executeRepairTask} from './interface_repair_task.mjs';

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

async function identities({binary, driver, applicationPath}) {
  const hashes = await Promise.all([binary, driver, applicationPath].map(async path => hash(await readFile(path))));
  const evaluator = Object.fromEntries(await Promise.all(sourcesUsed.map(async path =>
    [path, hash(await readFile(new URL(path, import.meta.url)))])));
  return {binary_sha256:hashes[0], driver_sha256:hashes[1], application_sha256:hashes[2], evaluator,
    repository_head:execFileSync('git', ['-C',repository,'rev-parse','HEAD'], {encoding:'utf8'}).trim()};
}

async function exportSources(driver, build) {
  const scratch = await realpath(await mkdtemp(join(tmpdir(), 'protean-repair-sources-')));
  try {
    const client = new RecurrenceDriver(driver, ['--offline','--state-dir',join(scratch,'state')]);
    const timer = setTimeout(() => client.kill(), 30000);
    try {
      const sources = await client.call('evaluation.interface_repair.sources');
      for (const key of ['adequate','lossy']) assert.equal(typeof sources[key], 'string');
      assert.notEqual(sources.adequate, sources.lossy);
      const description = await client.call('describe');
      assert.equal(description.execution_mode,'offline');
      const task = await client.call('task.submit',{client_operation_id:'repair-preparation',
        application_id:'adaptive-agent',profile_id:description.profile.id,
        input:{schema_id:'adaptive-agent.input.v2',value:{task:'Validate the frozen experiment assets.'}}});
      const path = join(scratch,'admitted.agnx');
      await client.call('evaluation.export',{task_id:task.task_id,path});
      const archive = readArchive(await readFile(path));
      assert.equal(archive.task.inference_attempts,0n);
      for (const field of ['program_sha256','application_assets_sha256'])
        assert.equal(archive.build[field],build[field],`Driver and product disagree on ${field}.`);
      return sources;
    } finally {
      clearTimeout(timer);
      await client.close();
    }
  } finally { await rm(scratch,{recursive:true,force:true}); }
}

export function selectRepairProfile(config) {
  assert.equal(config.schema, 'adaptive-agent.configuration.v3');
  const adaptive = config.adaptive;
  const selected = adaptive.profiles.filter(p => p.id === adaptive.initial_profile);
  assert.equal(selected.length, 1, 'Select exactly one approved initial profile.');
  const [profile] = selected;
  assert(/^gpt-[0-9]+(?:\.[0-9]+)*-astra$/.test(profile.model), 'Directed repair requires an approved Astra model.');
  assert(profile.efforts.includes(adaptive.initial_effort), 'Initial effort is unavailable.');
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
  return [scanContract, 'The selected Boolean reports whether a counterexample was observed. The original complete scan and the partial scan in paired-scan.json have the same Boolean output. Only the complete scan covers the domain.',
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
    tools:{build:authored,run:authored,reconstruct:false,inputs:[]}, semantic_construction:null};
  const cfg = await frozenFile(join(home,'config.json'),encode(selected));
  const source = authored || arm === 'fixed-lossy' ? sources.lossy : arm === 'fixed-adequate' ? sources.adequate : null;
  return {id,arm,phase,case_id:specimen.case_id,case_path:cases[specimen.case_id].specimen.path,
    paired_case_path:paired ? cases[paired.case_id].specimen.path : null, config:cfg.path,config_sha256:cfg.sha256,
    snapshot,evidence,seed_path:source?.path ?? null,prompt:authored ? authorPrompt(specimen,paired) : decisionPrompt(specimen)};
}

export async function prepareInterfaceRepair({config,directory,binary,driver,applicationPath,study='episode',
  repetitions=1,seconds=600,route='api-key',costModel={kind:'unpriced'}}, deps = {}) {
  assert(['episode','comparison'].includes(study));
  assert(Number.isSafeInteger(repetitions) && repetitions>0 && (study !== 'episode' || repetitions===1));
  assert(Number.isSafeInteger(seconds) && seconds>0 && Number.isSafeInteger(seconds*1000*repetitions*arms.length));
  assert(['api-key','chatgpt'].includes(route));
  const profile = selectRepairProfile(config);
  const ids = await identities({binary,driver,applicationPath});
  const build = (deps.describeBuild ?? command)(binary,['describe-build']);
  assert.equal(build.application_assets_sha256,ids.application_sha256);
  await mkdir(directory,{mode:0o700});
  directory = await realpath(directory);
  const raw = await (deps.exportSources ?? exportSources)(driver,build);
  const privateRoot = join(directory,'private');
  await mkdir(privateRoot);
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
      conditions.push({repetition,arm,author,diagnostic,downstream});
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
  const plan = {format,suite:'interface-repair',study,seed,repetitions,identities:ids,build,profile,
    initial_effort:config.adaptive.initial_effort,route,cost_model:costModel,
    condition_ms,campaign_ceiling_ms,
    deadline_scope:'Each condition has its own allowance for setup, authoring, replay and downstream work. The campaign reserves an additional minute per condition for process closure and post-expiry archive measurement. Finalization time is charged and recorded.',
    sources,cases,conditions};
  const bytes = encode(plan);
  await save(join(directory,'plan.json'),bytes);
  await save(join(directory,'plan.sha256'),hash(bytes)+'\n');
  return plan;
}

async function validateFile(file) {
  const bytes = await readFile(file.path);
  assert.equal(hash(bytes),file.sha256,'Frozen material changed: '+file.path);
  return bytes;
}

export async function validateRepairPlan(directory,options) {
  const bytes = await readFile(join(directory,'plan.json'));
  assert.equal(hash(bytes),(await readFile(join(directory,'plan.sha256'),'utf8')).trim(),'Frozen plan changed.');
  const plan = JSON.parse(bytes);
  assert.equal(plan.format,format);
  assert.deepEqual(plan.identities,await identities(options),'Executable, application, evaluator or repository changed.');
  for (const file of Object.values(plan.sources)) await validateFile(file);
  for (const record of Object.values(plan.cases)) {
    const specimen = JSON.parse(await validateFile(record.specimen));
    assert.equal(encode(assessScan(specimen)),(await validateFile(record.expected)).toString());
  }
  for (const condition of plan.conditions) for (const subject of [condition.author,...condition.downstream].filter(Boolean)) {
    const config = JSON.parse(await validateFile({path:subject.config,sha256:subject.config_sha256}));
    assert.deepEqual(config.adaptive.profiles,[plan.profile]);
    assert.equal(config.adaptive.snapshot_root,subject.snapshot);
    assert.deepEqual(config.adaptive.skills,[]);
    assert.deepEqual(config.tools.inputs,[]);
    const entries = await readdir(subject.snapshot,{withFileTypes:true});
    assert(entries.every(entry=>entry.isFile()),'Unexpected model-visible directory or link.');
    assert.deepEqual(entries.map(e=>e.name).sort(),subject.evidence.map(e=>e.path).sort(),'Snapshot exposure changed.');
    for (const file of subject.evidence)
      await validateFile({path:join(subject.snapshot,file.path),sha256:file.sha256});
  }
  return plan;
}

function resources(tasks, costModel) {
  const started = tasks.filter(t=>t.state !== 'not_started');
  const inventories = started.map(t=>t.report?.metrics?.physical_attempts);
  const attempts = started.flatMap((task,i)=>inventories[i] ?? task.report?.observed_provider_attempts ?? []);
  const countKnown = inventories.every(Array.isArray);
  const usageComplete = countKnown && attempts.every(a=>Number.isSafeInteger(a.usage?.input_tokens) &&
    Number.isSafeInteger(a.usage?.output_tokens));
  const known = key => attempts.reduce((sum,a)=>sum+(Number.isSafeInteger(a.usage?.[key]) ? a.usage[key] : 0),0);
  const priced = costModel.kind === 'tariff' && started.every(t=>t.report?.cost?.complete);
  return {known_physical_attempts:attempts.length, physical_attempts:countKnown ? attempts.length : null,
    usage_complete:usageComplete, known_input_tokens:known('input_tokens'), known_output_tokens:known('output_tokens'),
    missing_usage_attempts:attempts.filter(a=>!Number.isSafeInteger(a.usage?.input_tokens) ||
      !Number.isSafeInteger(a.usage?.output_tokens)).length,
    monetary_cost:priced ? started.reduce((sum,t)=>sum+t.report.cost.total,0) : null,
    cost_model:costModel.id ?? costModel.kind};
}

function initialPresentation(report) {
  const trace = report?.adjudication;
  const attempts = trace?.delivery;
  if (!attempts?.length || attempts.some(a => a.preparation_cut == null)) return null;
  const first = attempts.reduce((a, b) => BigInt(a.preparation_cut) <= BigInt(b.preparation_cut) ? a : b);
  const sameCut = attempts.filter(a => BigInt(a.preparation_cut) === BigInt(first.preparation_cut));
  if (sameCut.some(a => a.prepared_sha256 !== first.prepared_sha256)) return null;
  const confirmed = sameCut.find(a => a.delivery === 'confirmed');
  if (!confirmed) return null;
  if (report.effective_condition === 'ordinary') return confirmed.selected_view === null;
  if (!report.bootstrap?.view || !trace.projection) return false;
  return confirmed.selected_view === report.bootstrap.view.id &&
    trace.projection.exposures.some(e => e.id === confirmed.id && e.rendered);
}

export function gradeCondition(condition, tasks, costModel) {
  const author = tasks.find(t=>t.subject.phase === 'author')?.report;
  const diagnostic = tasks.find(t=>t.subject.phase === 'diagnostic')?.report;
  const transfer = tasks.filter(t=>t.subject.phase === 'transfer');
  const collision = diagnostic?.adjudication?.collision ?? null;
  const cases = transfer.map(t=>{
    const r = t.report, grade = r?.grading, trace = r?.adjudication, projection = trace?.projection;
    const bound = trace?.report_bound === true;
    const initial = initialPresentation(r);
    const compliant = r?.arm_violations?.length || projection?.one_computed_block === false ? false :
      Array.isArray(r?.arm_violations) ? initial : null;
    const citedProjection = projection && grade?.answer?.support?.some(ref=>
      ref.kind === projection.result.kind && ref.id === projection.result.id);
    return {case_id:t.subject.case_id,state:t.state,task_report:t.file,answer:grade?.answer?.outcome ?? null,
      grading_errors:grade?.errors ?? null,errors:r?.errors ?? [],
      initial_presentation_confirmed:initial,
      correct:bound ? grade?.outcome_correct ?? null : null, supported:bound ? grade?.supported ?? null : null,
      unsupported_exhaustion:grade?.unsupported_exhaustion ?? null, compliant:r ? compliant : null,
      transfer_bound:trace?.transfer_bound ?? null,ordinary_fallback:trace?.ordinary_fallback ?? null,
      effective_condition:r?.effective_condition ?? null,delivery:trace?.delivery ?? null,
      candidate_rejection:r?.candidate_rejection ?? null,
      semantic_judgment:projection?.semantic_judgment ?? null,
      cited_projection:!!citedProjection,
      needs_payload_adjudication:!!citedProjection && bound && projection?.semantic_judgment === 'unestablished',
      exposed_computed:projection?.exposures.some(e=>e.rendered && e.delivery === 'confirmed') ?? null};
  });
  const complete = cases.length === condition.downstream.length && cases.every(c=>c.state === 'completed');
  const allSupported = complete && cases.every(c=>c.supported === true);
  const authored = author?.adjudication?.authored_and_applied === true;
  const supportedUses = cases.filter(c=>c.state === 'completed' && c.supported && c.cited_projection &&
    c.transfer_bound && c.exposed_computed && c.semantic_judgment === 'supported' &&
    c.compliant && c.ordinary_fallback === false);
  const initialAuthor = initialPresentation(author);
  const authorCompliant = initialAuthor === true && Array.isArray(author?.arm_violations) && !author.arm_violations.length &&
    author.adjudication?.uses?.some(use => use.program.id === author.adjudication.candidate?.program.id &&
      use.one_computed_block && use.model_start && use.model_select && use.canonical_input);
  const demonstrated = authored && authorCompliant && collision?.distinction_preserved === true &&
    ['incomplete','exhausted_declared_domain'].every(outcome=>supportedUses.some(c=>c.answer === outcome));
  return {repetition:condition.repetition,arm:condition.arm,planned_cases:condition.downstream.length,cases,
    author_report:tasks.find(t=>t.subject.phase === 'author')?.file ?? null,
    diagnostic_report:tasks.find(t=>t.subject.phase === 'diagnostic')?.file ?? null,
    authoring_attempted:!!author,author_initial_presentation_confirmed:initialAuthor,
    candidate_admitted:!!author?.adjudication?.candidate,authored_and_applied:authored,
    authoring_state:tasks.find(t=>t.subject.phase === 'author')?.state ?? null,
    nomination:author?.nomination?.status ?? null,nomination_error:author?.nomination_error ?? null,
    diagnosis:author?.nomination?.diagnosis ?? null,authoring_errors:author?.errors ?? [],
    collision,supported_repair:condition.arm !== 'repair' ? null : demonstrated ? 'demonstrated_on_tested_cases' : 'unestablished',
    supported_view_use_cases:supportedUses.map(c=>c.case_id),
    all_cases_completed:complete,all_cases_supported:allSupported,supported_answers:cases.filter(c=>c.supported).length,
    end_to_end_resources:resources(tasks,costModel), downstream_resources:resources(transfer,costModel)};
}

function taskState(report) {
  if (report.timed_out) return 'timed_out';
  if (report.errors.length) return 'infrastructure_failure';
  if (report.candidate_rejection) return 'candidate_rejected';
  if (report.subject.phase === 'diagnostic') return report.adjudication?.collision ? 'completed' : 'unanswered';
  if (report.status?.status !== 'completed') return 'unanswered';
  return 'completed';
}

function markdown(results) {
  const rows = results.conditions.map(c=>`| ${c.repetition+1} | ${c.arm} | ${c.cases.filter(t=>t.state === 'completed').length}/${c.planned_cases} | ${c.supported_answers} | ${c.authored_and_applied ? 'yes' : '—'} | ${c.end_to_end_resources.known_physical_attempts} | ${c.elapsed_ms.toFixed(0)} |`);
  const lines = ['# Directed interface repair','',
    '| Repetition | Condition | Completed decisions | Supported answers | Authored and applied | Known provider attempts | Elapsed ms |',
    '|---|---|---:|---:|---|---:|---:|',...rows,'',
    'One candidate reused across multiple cases counts as one authoring attempt.',''];
  for (const c of results.conditions) {
    const counts = new Map();
    for (const row of c.cases) counts.set(row.state,(counts.get(row.state) ?? 0)+1);
    lines.push('## Repetition '+(c.repetition+1)+' · '+c.arm,'');
    if (c.arm === 'repair') {
      lines.push('Authoring ended with `'+c.authoring_state+'`. Nomination was `'+(c.nomination ?? 'unavailable')+
        '`. Supported repair was `'+c.supported_repair+'`.','');
    }
    const r = c.end_to_end_resources;
    lines.push([...counts].map(([state,count])=>count+' '+state).join(', ')+'.',
      'Known usage was '+r.known_input_tokens+' input tokens and '+r.known_output_tokens+' output tokens.'+
      (r.usage_complete ? '' : ' These are lower bounds.')+
      (r.monetary_cost === null ? ' Monetary cost is unknown.' : ' Cost under the frozen tariff was '+r.monetary_cost+'.'),'',
      '| Case | Status | Answer | Supported | Ordinary evidence use |',
      '|---|---|---|---|---|');
    const label = flag => flag == null ? 'unknown' : flag ? 'yes' : 'no';
    for (const row of c.cases) lines.push('| '+[row.case_id,row.state,row.answer ?? '—',label(row.supported),
      label(row.ordinary_fallback)].join(' | ')+' |');
    lines.push('');
  }
  return lines.join('\n');
}

export async function runInterfaceRepair(directory, options, {execute=executeRepairTask,now=()=>performance.now()} = {}) {
  const plan = await validateRepairPlan(directory,options);
  assert.equal(options.chatgptAccount ? 'chatgpt' : 'api-key',plan.route,'Credential route differs from preparation.');
  const application = JSON.parse(await readFile(options.applicationPath));
  const plan_sha256 = hash(await readFile(join(directory,'plan.json')));
  const output = join(directory,'run');
  await mkdir(output,{mode:0o700});
  const results = {format,plan_sha256,study:plan.study,conditions:[],paired_cases:[]};
  const campaignStart = now(), campaignDeadline = campaignStart+plan.campaign_ceiling_ms;
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
        report = await execute({...options,output:dir,subject,candidate,deadline,build:plan.build,
          application,plan,plan_sha256});
      } catch (error) {
        report = {subject,errors:[{stage:'task_runner',name:error.name,message:error.message}],status:null,
          metrics:null,timed_out:false};
        await save(join(dir,'failure.json'),encode(report));
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
    measured.elapsed_ms = now()-start;
    measured.deadline_overrun_ms = Math.max(0,measured.elapsed_ms-plan.condition_ms);
    results.conditions.push(measured);
    await save(join(output,condition.repetition+'-'+condition.arm+'.json'),encode(measured));
  }
  results.elapsed_ms = now()-campaignStart;
  results.campaign_ceiling_exceeded = results.elapsed_ms > plan.campaign_ceiling_ms;
  for (let i=0;i<plan.repetitions;i++) {
    const conditions = results.conditions.filter(c=>c.repetition===i);
    for (const row of conditions[0].cases) results.paired_cases.push({repetition:i,case_id:row.case_id,
      conditions:Object.fromEntries(conditions.map(c=>[c.arm,c.cases.find(r=>r.case_id===row.case_id)]))});
  }
  await save(join(output,'results.json'),encode(results));
  await save(join(output,'results.md'),markdown(results));
  return {results:join(output,'results.json'),summary:join(output,'results.md'),conditions:results.conditions.length};
}
