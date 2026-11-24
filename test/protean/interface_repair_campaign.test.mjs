import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {copyFile, mkdir, mkdtemp, readFile, symlink, writeFile, rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {parseRepairConfiguration, prepareInterfaceRepair, validateRepairPlan, selectRepairProfile, gradeCondition, repairOrder, formatRepairResults,
  runInterfaceRepair} from '../../tools/evaluation/interface_repair_campaign.mjs';
import {makeRepairCorpus, canonicalEvidence, inspectProjection} from '../../tools/evaluation/interface_repair.mjs';
import {gradeRepairDecision, writeRepairReport} from '../../tools/evaluation/interface_repair_task.mjs';
import {bytesUnder} from '../../tools/evaluation/workspace.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const fixtureCredentials = () => ({valid:true});
const studyProgram = sha('directed study');
const studyApplication = JSON.stringify({program_sha256:studyProgram});
const studyAssets = {application:studyApplication,build:{program_sha256:studyProgram,application_assets_sha256:sha(studyApplication)}};
const config = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.chatgpt.example.json',import.meta.url)));
config.tools = {build:true,run:true,reconstruct:false,inputs:[]};
const tariff = {kind:'tariff',predeclared:true,id:'synthetic',currency:'USD',provider_source:'fixture',
  deployment_source:'fixture',host_includes_attempt_storage:true,input_per_million:1,cached_input_per_million:1,
  output_per_million:2,host_per_second:0,storage_per_byte_second:0,retention_seconds:0};

test('preparation rejects absent authoring permissions and invalid tariffs before starting any work', async () => {
  for (const tools of [null, {...config.tools,build:false}, {...config.tools,run:false}])
    await assert.rejects(prepareInterfaceRepair({config:{...config,tools}}), /must allow build and run/);
  for (const costModel of [null,{},[],{kind:'tariff'}])
    await assert.rejects(prepareInterfaceRepair({config,costModel}), /cost model|declared tariff/);
});

test('CLI preparation checks the original JSON fields before deriving a study configuration', async t => {
  const root = await mkdtemp(join(tmpdir(),'repair-config-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const configPath = join(root,'config.json'), directory = join(root,'plan');
  await writeFile(configPath,'{"schema":1,"schema":1}');
  const result = spawnSync(process.execPath,['tools/evaluation/workspace.mjs','prepare','--suite','interface-repair',
    '--config',configPath,'--out',directory],{cwd:new URL('../../',import.meta.url),encoding:'utf8'});
  assert.notEqual(result.status,0);
  assert.match(result.stderr,/duplicate_field/);
  assert.equal(existsSync(directory),false);
});

test('selected profile limits retain exact native unsigned integer semantics',()=>{
  const input = JSON.stringify(config);
  const withLimit = token=>input.replace('"request_bytes":null','"request_bytes":'+token);
  for (const token of ['1e400','-1e400','1e-400','1.00000000000000000001','4294967296'])
    assert.throws(()=>selectRepairProfile(parseRepairConfiguration(withLimit(token))));
  for (const [token,expected] of [['1.000e2',100],['-0e29',0],['4294967295',4294967295],['null',null]])
    assert.equal(selectRepairProfile(parseRepairConfiguration(withLimit(token))).request_bytes,expected);
  const invalid = structuredClone(config);
  invalid.adaptive.profiles[0].effort_update='false';
  assert.throws(()=>selectRepairProfile(invalid),/effort_update/);
});

test('only the approved initial Astra model and effort survive preparation',()=>{
  const changed = structuredClone(config);
  changed.adaptive.profiles.push({...changed.adaptive.profiles[0],id:'alternate',model:'unapproved'});
  const p = selectRepairProfile(changed);
  assert.equal(p.id,changed.adaptive.initial_profile);
  assert.deepEqual(p.efforts,[changed.adaptive.initial_effort]);
  assert.equal(p.effort_update,false);
  for (const efforts of ['xhigh',['high','invalid'],['high','high']]) {
    const invalid = structuredClone(changed);
    invalid.adaptive.initial_effort = 'high';
    invalid.adaptive.profiles[0].efforts = efforts;
    assert.throws(()=>selectRepairProfile(invalid),/effort/);
  }
  changed.adaptive.profiles[0].model = 'not-astra';
  assert.throws(()=>selectRepairProfile(changed));
  assert.deepEqual(new Set(Array.from({length:4},(_,i)=>repairOrder('comparison',i)[0])),
    new Set(['repair','evidence','fixed-adequate','fixed-lossy']));
});

test('a frozen episode isolates all snapshots and retains an unsuccessful authoring attempt',async t=>{
  const root = await mkdtemp(join(tmpdir(),'interface-repair-plan-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const app = join(root,'application.json');
  await writeFile(app,'{}');
  const costModel = {...tariff};
  const opts = {binary:app,driver:app,applicationPath:app,config:structuredClone(config),costModel,directory:join(root,'episode'),route:'chatgpt'};
  const deps = {describeBuild:()=>({application_assets_sha256:sha('{}')}),
    validateConfiguration:()=>({valid:true}),
    exportSources:()=>({lossy:'sliced loss',adequate:'private reference program',study:studyAssets})};
  const preparing = prepareInterfaceRepair(opts,deps);
  costModel.output_per_million = 5;
  opts.config.adaptive.profiles[0].efforts.push('max');
  const plan = await preparing;
  assert.notEqual(plan.study_assets.application.sha256,plan.identities.application_sha256);
  assert.equal(plan.cost_model.output_per_million,2);
  assert.deepEqual(plan.approved_efforts,config.adaptive.profiles[0].efforts);
  assert.equal(plan.conditions.length,1);
  const [condition] = plan.conditions;
  assert.equal(condition.downstream.length,10);
  assert.equal(new Set(condition.downstream.map(c=>c.case_id)).size,10);
  assert(!condition.author.prompt.includes('interface-repair.answer.v1'));
  for (const subject of [condition.author,...condition.downstream]) {
    const bytes = await readFile(subject.config,'utf8');
    assert.equal(JSON.parse(bytes).adaptive.profiles.length,1);
    for (const item of subject.evidence) {
      const visible = await readFile(join(subject.snapshot,item.path),'utf8');
      assert(!visible.includes('private reference program'));
    }
  }
  await validateRepairPlan(opts.directory,opts);
  const alias = join(root,'alias');
  await symlink(opts.directory,alias);
  await validateRepairPlan(alias,opts);
  const copy = join(root,'copy');
  await mkdir(copy);
  for (const name of ['plan.json','plan.sha256']) await copyFile(join(opts.directory,name),join(copy,name));
  await assert.rejects(validateRepairPlan(copy,opts),/original preparation directory/);
  const unrelated = Buffer.alloc(2048);
  await writeFile(join(opts.directory,'other-study.bin'),unrelated);
  await assert.rejects(prepareInterfaceRepair(opts,deps),{code:'EEXIST'});
  await assert.rejects(runInterfaceRepair(opts.directory,{...opts,chatgptAccount:'fixture'}),/authorize-inference/);
  assert.equal(existsSync(join(opts.directory,'run')),false);
  opts.authorizeInference = true;
  await assert.rejects(runInterfaceRepair(opts.directory,{...opts,credential:'dummy'}),/route differs/);
  await assert.rejects(runInterfaceRepair(opts.directory,opts),/one inference source/);
  await assert.rejects(runInterfaceRepair(opts.directory,{...opts,credential:'dummy',chatgptAccount:'fixture'}),/one inference source/);
  const calls = [];
  const dispatch = {...opts,chatgptAccount:'fixture'};
  await assert.rejects(runInterfaceRepair(alias,dispatch,{validateCredentials:(binary,args)=>{
    assert.equal(binary,opts.binary);
    assert.deepEqual(args,['validate','--config',condition.author.config,'--chatgpt-account','fixture']);
    throw new Error('local credential unavailable');
  }}),/local credential unavailable/);
  assert.equal(existsSync(join(opts.directory,'run')),false);
  const {results,summary,timing} = await runInterfaceRepair(alias,dispatch,
    {validateCredentials:fixtureCredentials,execute:async ({subject,output,candidate,chatgptAccount,credential})=>{
      assert.equal(candidate,null);
      assert.equal(chatgptAccount,'fixture');
      assert.equal(credential,undefined);
      dispatch.credential = 'concurrent-api-key';
      delete dispatch.chatgptAccount;
      calls.push(subject.id);
      const report = {subject,nomination:{status:'no_candidate'},arm_violations:[],status:{status:'completed'},
        errors:[],adjudication:{report_bound:true,authored_and_applied:false},metrics:{physical_attempts:[{usage:null}]},
        grading:subject.phase === 'transfer' ? {supported:false,outcome_correct:false} : null};
      await writeFile(join(output,'report.json'),JSON.stringify(report));
      return report;
    }});
  assert.equal(calls.length,11);
  const timingBytes = await readFile(timing);
  assert.equal(JSON.parse(timingBytes).retained_bytes,await bytesUnder(opts.directory)-unrelated.length-timingBytes.length);
  assert.match(await readFile(summary,'utf8'), /Answered decisions/);
  const [measured] = JSON.parse(await readFile(results)).conditions;
  assert.equal(measured.end_to_end_resources.known_physical_attempts,11);
  assert.equal(measured.downstream_resources.known_physical_attempts,10);
  assert.equal(measured.end_to_end_resources.usage_complete,false);
  assert.equal(measured.supported_repair,'unestablished');
  const evaluatorDirectory = join(root,'source-package','tools','evaluation');
  for (const path of Object.keys(plan.identities.evaluator)) {
    const dest = join(evaluatorDirectory,path);
    await mkdir(dirname(dest),{recursive:true});
    await copyFile(new URL('../../tools/evaluation/'+path,import.meta.url),dest);
  }
  const oracle = join(evaluatorDirectory,'interface_repair.mjs');
  const original = await readFile(oracle,'utf8');
  await import(pathToFileURL(oracle));
  await writeFile(oracle,original+'\n');
  const packaged = await import(pathToFileURL(join(evaluatorDirectory,'interface_repair_campaign.mjs')));
  const packagedOpts = {...opts,directory:join(root,'packaged-episode')};
  await assert.rejects(packaged.prepareInterfaceRepair(packagedOpts,deps),/Loaded evaluator differs from its source/);
  await writeFile(oracle,original);
  const packagedPlan = await packaged.prepareInterfaceRepair(packagedOpts,deps);
  assert.equal(packagedPlan.identities.repository_head,null);
  assert.equal(packagedPlan.identities.loaded_evaluator['interface_repair.mjs'],sha(original));
  await assert.rejects(runInterfaceRepair(opts.directory,{...opts,chatgptAccount:'fixture'},{validateCredentials:fixtureCredentials}),{code:'EEXIST'});
  await writeFile(join(condition.author.snapshot,'unexpected.json'),'private');
  await assert.rejects(validateRepairPlan(opts.directory,opts),/Snapshot exposure changed/);
});

test('unstarted and timed out cases prevent an all-cases claim, irrespective of early successes',()=>{
  const subjects = ['a','b','c'].map(case_id=>({case_id,phase:'transfer'}));
  const rows = [{subject:subjects[0],state:'completed',report:{adjudication:{report_bound:true},
    arm_violations:[],grading:{answer:{outcome:'incomplete',support:[]},supported:true,outcome_correct:true}}},
    {subject:subjects[1],state:'timed_out',report:{}},{subject:subjects[2],state:'not_started'}];
  const measured = gradeCondition({repetition:1,arm:'repair',downstream:subjects},rows,{kind:'unpriced'});
  assert.equal(measured.all_cases_completed,false);
  assert.equal(measured.supported_answers,1);
  assert.equal(measured.all_cases_supported,false);
  assert.equal(measured.end_to_end_resources.physical_attempts,null);
  assert.equal(measured.end_to_end_resources.monetary_cost,null);
});

test('condition compliance requires the promised presentation in the first request', () => {
  const subject = {phase:'transfer',case_id:'a'}, condition = {arm:'fixed-lossy',downstream:[subject]};
  const first = {id:'first',preparation_cut:'2',prepared_sha256:'original',selected_view:'view',delivery:'confirmed',model_response:true};
  const later = {...first,id:'later',preparation_cut:'10',prepared_sha256:'subsequent'};
  const report = {bootstrap:{view:{id:'view'}},effective_condition:'fixed-lossy',arm_violations:[],
    adjudication:{delivery:[later,first],projection:{one_computed_block:true,result:{kind:'value',id:'result'},
      exposures:[{id:'later',rendered:true,one_computed_block:true},{id:'first',rendered:false,one_computed_block:false}]}}};
  const grade = () => gradeCondition(condition,[{subject,state:'completed',report}],{kind:'unpriced'}).cases[0];
  assert.equal(grade().compliant,false);
  report.adjudication.projection.exposures[1].rendered = true;
  assert.equal(grade().initial_presentation_confirmed,true);
  assert.equal(grade().compliant,false);
  report.adjudication.projection.exposures[1].one_computed_block = true;
  assert.equal(grade().compliant,true);
  first.delivery = 'unknown';
  first.model_response = null;
  assert.equal(grade().compliant,null);
  first.delivery = 'not_sent';
  first.model_response = false;
  assert.equal(grade().compliant,true);
  first.delivery = 'confirmed';
  assert.equal(grade().compliant,true);
  first.model_response = true;
  report.effective_condition = 'ordinary';
  report.adjudication.projection = null;
  assert.equal(grade().compliant,false);
  first.selected_view = null;
  assert.equal(grade().compliant,false);
  assert.equal(gradeCondition({...condition,arm:'evidence'},[{subject,state:'completed',report}],{kind:'unpriced'})
    .cases[0].compliant,true);
});

test('one exhausted condition preserves every later condition allowance', async t => {
  const root = await mkdtemp(join(tmpdir(),'repair-condition-deadlines-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const app = join(root,'application.json');
  await writeFile(app,'{}');
  const opts = {binary:app,driver:app,applicationPath:app,config,directory:join(root,'study'),
    route:'api-key',seconds:1,study:'comparison'};
  const plan = await prepareInterfaceRepair(opts,{
    describeBuild:()=>({application_assets_sha256:sha('{}')}),
    validateConfiguration:()=>({valid:true}),exportSources:()=>({lossy:'lossy',adequate:'adequate',study:studyAssets})
  });
  opts.authorizeInference = true;
  await assert.rejects(runInterfaceRepair(opts.directory,opts),/one inference source/);
  assert.equal(existsSync(join(opts.directory,'run')),false);
  let clock = 0;
  const {results} = await runInterfaceRepair(opts.directory,{...opts,credential:'fixture'},{
    validateCredentials:fixtureCredentials,
    now:()=>{
      if (existsSync(join(opts.directory,'run','0-evidence.json')))
        clock = Math.max(clock,plan.campaign_ceiling_ms-5);
      return existsSync(join(opts.directory,'run','results.md')) ? clock + plan.campaign_ceiling_ms : clock;
    },
    execute:async ({subject,deadline,output})=>{
      assert.equal(deadline-clock,subject.arm === 'fixed-adequate' ? 5 : plan.condition_ms);
      clock = deadline+20;
      const report = {subject,errors:[],timed_out:true,adjudication:null};
      await writeFile(join(output,'report.json'),JSON.stringify(report));
      return report;
    }
  });
  const result = JSON.parse(await readFile(results));
  assert.equal(result.conditions.length,4);
  for (const c of result.conditions) {
    assert.equal(c.effective_allowance_ms,c.arm === 'fixed-adequate' ? 5 : plan.condition_ms);
    assert.equal(c.elapsed_ms,c.effective_allowance_ms+20);
    assert.equal(c.deadline_overrun_ms,20);
    assert.equal(c.all_cases_completed,false);
    assert.equal(c.cases.filter(row=>row.state === 'not_started').length,c.arm === 'repair' ? 10 : 9);
  }
  const timing = JSON.parse(await readFile(join(opts.directory,'run',result.timing_file)));
  assert.equal(timing.campaign_ceiling_exceeded,true);
  assert.equal(timing.elapsed_ms,clock+plan.campaign_ceiling_ms);
});

const exhausted = 'exhausted_declared_domain';

test('a nested diagnostic survives condition and campaign publication with its task measurements', async t => {
  const root = await mkdtemp(join(tmpdir(),'repair-diagnostic-report-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const applicationPath = join(root,'application.json');
  await writeFile(applicationPath,'{}');
  const opts = {binary:applicationPath,driver:applicationPath,applicationPath,config,directory:join(root,'episode')};
  await prepareInterfaceRepair(opts,{describeBuild:()=>({application_assets_sha256:sha('{}')}),
    validateConfiguration:()=>({valid:true}),exportSources:()=>({lossy:'lossy',adequate:'adequate',study:studyAssets})});
  let payload = 'retained';
  for (let i=0;i<6000;i++) payload=[payload];
  const {results} = await runInterfaceRepair(opts.directory,{...opts,authorizeInference:true,credential:'fixture'},{
    validateCredentials:fixtureCredentials,
    now:()=>0, execute:async ({subject,output})=>{
      const adjudication = subject.phase === 'diagnostic' ? {collision:{distinction_preserved:false,left:{payload},right:{payload}}} :
        subject.phase === 'author' ? {candidate:{program:{id:'fixture'}}} : {};
      const report = {subject,errors:[],adjudication,execution_mode:'scripted_fixture',status:{status:'completed'},retained_namespace_bytes:37};
      await writeRepairReport(join(output,'report.json'),report);
      return report;
    }
  });
  const [condition] = JSON.parse(await readFile(results)).conditions;
  const task = JSON.parse(await readFile(condition.diagnostic_report));
  assert.equal(task.retained_namespace_bytes,37);
  const perCondition = JSON.parse(await readFile(join(dirname(results),'0-repair.json')));
  for (const collision of [task.adjudication.collision, perCondition.collision, condition.collision]) {
    assert.equal(collision.distinction_preserved,false);
    for (let value of [collision.left.payload,collision.right.payload]) {
      for (let i=0;i<6000;i++) { assert.equal(value.length,1); value=value[0]; }
      assert.equal(value,'retained');
    }
  }
});
const unpriced = {kind:'unpriced'};

function presentedReport(arm, id, outcome) {
  const result = {kind:'value',id:'result-'+id}, view = {kind:'view',id:'view-'+id};
  const attempt = {id:'first',selected_view:view.id,preparation_cut:'1',prepared_sha256:'prepared',delivery:'confirmed',model_response:true};
  return {effective_condition:arm,bootstrap:{view},arm_violations:[],errors:[],
    status:{status:'completed'},result:{outcome:{value:{result:{tag:'report'}}}},
    grading:{answer:{outcome,support:[result]},errors:[],outcome_correct:true,supported:true,unsupported_exhaustion:false},
    adjudication:{report_bound:true,delivery:[attempt],ordinary_fallback:false,transfer_bound:arm === 'repair',
      projection:{result,canonical_input:true,semantic_judgment:'supported',one_computed_block:true,
        exposures:[{...attempt,rendered:true,one_computed_block:true}]}}};
}

function coverageEpisode() {
  const subject = {phase:'author'};
  const author = {subject,state:'completed',report:presentedReport('repair','author',exhausted)};
  author.report.authoring_opportunity = true;
  Object.assign(author.report.adjudication,{candidate:{program:{id:'candidate'}},authored_and_applied:true,
    applied_use:{one_computed_block:true}});
  const diagnostic = {subject:{phase:'diagnostic'},state:'completed',report:{adjudication:{collision:{
    distinction_preserved:true,left:{expected:exhausted,semantic_judgment:'supported'},
    right:{expected:'incomplete',semantic_judgment:'supported'}}}}};
  const cases = [['full',exhausted],['hole','incomplete'],['empty',exhausted],['unknown','incomplete'],['mismatch','counterexample']]
    .map(([case_id,outcome])=>({subject:{phase:'transfer',case_id},state:'completed',report:presentedReport('repair',case_id,outcome)}));
  const condition = {arm:'repair',downstream:cases.map(t=>t.subject),coverage_pair:{complete:'full',partial:'hole'}};
  return {author,diagnostic,cases,grade:()=>gradeCondition(condition,[author,diagnostic,...cases],unpriced)};
}

test('the coverage repair requires an exposed compliant author use, a correct diagnostic pair and fresh coverage decisions',()=>{
  const {author,diagnostic,cases,grade} = coverageEpisode();
  assert.equal(grade().supported_repair,'demonstrated_on_tested_cases');
  author.report.adjudication.uses = [{one_computed_block:true}];
  author.report.adjudication.applied_use.one_computed_block = false;
  assert.equal(grade().coverage_repair_demonstrated,false);
  author.report.adjudication.applied_use.one_computed_block = true;
  for (const side of ['left','right']) {
    diagnostic.report.adjudication.collision[side].semantic_judgment = 'incorrect';
    assert.equal(grade().coverage_repair_demonstrated,false);
    diagnostic.report.adjudication.collision[side].semantic_judgment = 'supported';
  }
  for (const index of [0,1]) {
    const report = cases[index].report, selected = report.grading.answer.support;
    report.adjudication.ordinary_fallback = true;
    assert.equal(grade().coverage_repair_demonstrated,true);
    report.grading.answer.support = [{kind:'value',id:'ordinary-source'}];
    assert.equal(grade().coverage_repair_demonstrated,false);
    report.grading.answer.support = selected;
    report.adjudication.ordinary_fallback = false;
  }
  const mismatch = makeRepairCorpus('campaign-schema-counterexample').transfer[4];
  const sources = Object.fromEntries(Object.keys(mismatch.files).map(path=>[path,{kind:'value',id:sha(path)}]));
  const incorrect = inspectProjection(mismatch,sources,'ScanOutcome',{tag:1,value:canonicalEvidence(mismatch,sources)});
  assert.equal(incorrect.semantic_judgment,'unestablished');
  assert.equal(incorrect.schema_judgment,'incorrect');
  Object.assign(cases[4].report.adjudication.projection,incorrect);
  assert.equal(grade().coverage_repair_demonstrated,true);
  assert.deepEqual(grade().incorrect_projection_cases,['mismatch']);
  assert.equal(grade().supported_repair,'unestablished');
});

test('fixed controls earn supported view use and uncertain evidence routes and settled grades remain distinct',()=>{
  const subject = {phase:'transfer',case_id:'full'}, condition = {arm:'fixed-adequate',downstream:[subject]};
  const report = presentedReport('fixed-adequate','full',exhausted);
  const grade = ()=>gradeCondition(condition,[{subject,state:'completed',report}],unpriced);
  assert.deepEqual(grade().supported_view_use_cases,['full']);
  const original = report.adjudication.projection.result, alias = {kind:'value',id:'alias'};
  report.grading.answer.support = [alias];
  report.adjudication.evidence_complete = true;
  report.adjudication.exposure = [{ref:alias,paths:['scan.json']}];
  assert.equal(grade().cases[0].supported_view_use,false);
  report.adjudication.exposure[0].projected_result = original;
  assert.equal(grade().cases[0].cited_projection,false);
  assert.equal(grade().cases[0].cited_projection_alias,true);
  assert.equal(grade().cases[0].supported_view_use,true);
  report.adjudication.ordinary_fallback = null;
  assert.equal(grade().cases[0].supported_view_use,true);
  report.adjudication.ordinary_fallback = true;
  assert.equal(grade().cases[0].supported_view_use,true);
  report.adjudication.projection.semantic_judgment = 'unestablished';
  assert.equal(grade().cases[0].needs_payload_adjudication,false);
  report.grading.supported = false;
  report.grading.errors = ['unsupported_coverage'];
  assert.equal(grade().cases[0].needs_payload_adjudication,false);
  report.grading.supported = null;
  report.grading.errors = ['unadjudicated_payload'];
  assert.equal(grade().cases[0].needs_payload_adjudication,true);
});

test('a one-byte raw read does not invalidate the independent mismatch witness in a cited projection',()=>{
  const specimen = makeRepairCorpus('incidental-read').transfer[4], subject = {phase:'transfer',case_id:specimen.case_id};
  const scan = JSON.parse(specimen.files['scan.json']), witness = scan.visits.find(v=>specimen.files[v.path] !== v.member);
  const ref = label=>({kind:'value',id:sha(label)});
  const report = presentedReport('fixed-adequate',subject.case_id,'counterexample');
  const projection = report.adjudication.projection, result = ref('projection'), manifest = ref('manifest'), value = ref('witness');
  projection.result = result;
  report.adjudication.ordinary_fallback = true;
  const projected = {ref:result,paths:['scan.json',witness.path],semantic_judgment:'supported'};
  const partial = {ref:manifest,paths:[],range:{path:'scan.json',start:0,end:1}};
  const answer = {kind:'interface-repair.answer.v1',case_id:subject.case_id,domain_identity:scan.domain.identity,
    domain_revision:scan.domain.revision,outcome:'counterexample',support:[result],
    explanation:'Member '+witness.member+' disagrees with observed value '+specimen.files[witness.path]+'.'};
  const row = ()=>gradeCondition({arm:'fixed-adequate',downstream:[subject]},[{subject,state:'completed',report}],unpriced).cases[0];
  const adjudicate = (projectionRow,ordinaryRows,evidenceComplete=true)=>{
    Object.assign(report.adjudication,{evidence_complete:evidenceComplete,exposure:[projectionRow,...ordinaryRows],
      projection_exposure:[projectionRow]});
    return gradeRepairDecision(JSON.stringify(answer),specimen,report.adjudication);
  };
  report.grading = adjudicate(projected,[partial]);
  assert.equal(row().supported,true);
  assert.equal(row().ordinary_fallback,true);
  assert.equal(row().other_evidence_cited,false);
  assert.equal(row().supported_view_use,true);
  answer.support = [manifest,value];
  const raw = [{ref:manifest,paths:['scan.json']},{ref:value,paths:[witness.path]}];
  report.grading = adjudicate(projected,raw);
  assert.equal(row().supported,true);
  assert.equal(row().supported_view_use,false);
  answer.support.push(result);
  report.grading = adjudicate(projected,raw);
  assert.equal(row().other_evidence_cited,true);
  assert.equal(row().supported_view_use,true);
  report.grading = adjudicate({...projected,paths:['scan.json']},raw);
  assert.equal(row().supported,true);
  assert.equal(row().projection_citations_supported,false);
  assert.equal(row().supported_view_use,false);
  assert.equal(row().needs_payload_adjudication,false);
  report.grading = adjudicate({...projected,paths:[],semantic_judgment:'unestablished'},raw);
  assert.equal(row().supported,true);
  assert.equal(row().projection_citations_supported,null);
  assert.equal(row().needs_payload_adjudication,true);
  answer.support = [{kind:'view',id:sha('missing view expansion')}];
  report.grading = adjudicate(projected,[],false);
  assert.equal(report.grading.projection_citations_supported,null);
  assert.equal(row().projection_citations_supported,null);
  assert.equal(row().cited_projection_alias,null);
  assert.equal(row().other_evidence_cited,null);
  assert.equal(row().supported_view_use,null);
  report.grading = adjudicate(projected,[]);
  assert.equal(row().projection_citations_supported,false);
  assert.equal(row().cited_projection_alias,false);
  assert.equal(row().supported_view_use,false);
});

test('the published table separates citation support from credit under study conditions',()=>{
  const subject = {phase:'transfer',case_id:'full'};
  const report = presentedReport('fixed-adequate',subject.case_id,exhausted);
  report.arm_violations = ['outside assigned condition'];
  const measure = ()=>gradeCondition({arm:'fixed-adequate',repetition:0,downstream:[subject]},
    [{subject,state:'completed',report}],unpriced);
  const measured = measure();
  const [row] = measured.cases;
  assert.equal(row.projection_citations_supported,true);
  assert.equal(row.supported_view_use,false);
  const text = formatRepairResults({conditions:[{...measured,elapsed_ms:1}]});
  assert.ok(text.includes('| Cited view supports answer | Credited view use |'));
  assert.ok(text.includes('| full | completed | exhausted_declared_domain | yes | no | yes | no |'));
  report.grading.answer.support = [{kind:'value',id:'unverified-alias'}];
  report.grading.projection_citations_supported = null;
  report.adjudication.evidence_complete = false;
  const unclear = formatRepairResults({conditions:[{...measure(),elapsed_ms:1}]});
  assert.ok(unclear.includes('| full | completed | exhausted_declared_domain | yes | no | unknown | no |'));
});

test('a failed replay blocks the broader verdict while the demonstrated coverage distinction remains',()=>{
  const {cases,grade} = coverageEpisode();
  const replay = cases[4];
  replay.state = 'candidate_rejected';
  replay.report = {effective_condition:'repair',candidate_rejection:'ProjectionResultRejected'};
  const measured = grade();
  assert.equal(measured.coverage_repair_demonstrated,true);
  assert.equal(measured.supported_repair,'unestablished');
  assert.deepEqual(measured.rejected_replay_cases,['mismatch']);
  assert.deepEqual(measured.incorrect_projection_cases,[]);
});

test('the tested-cases verdict requires supported use on every case except a recorded non-start',()=>{
  const {cases,grade} = coverageEpisode();
  const last = cases.at(-1);
  Object.assign(last.report.adjudication.projection,{schema_kind:'other',schema_judgment:null,semantic_judgment:'supported'});
  assert.equal(grade().supported_repair,'demonstrated_on_tested_cases');
  last.state = 'timed_out';
  assert.equal(grade().coverage_repair_demonstrated,true);
  assert.equal(grade().supported_repair,'unestablished');
  last.state = 'completed';
  last.report.grading.supported = false;
  assert.equal(grade().supported_repair,'unestablished');
  last.report.grading.supported = null;
  last.report.grading.errors = ['unadjudicated_payload'];
  assert.equal(grade().cases.at(-1).needs_payload_adjudication,true);
  assert.equal(grade().supported_repair,'unestablished');
  last.state = 'not_started';
  delete last.report;
  assert.equal(grade().supported_repair,'demonstrated_on_tested_cases');
  assert.equal(grade().all_cases_completed,false);
  cases.pop();
  assert.equal(grade().cases.at(-1).state,'missing_record');
  assert.equal(grade().supported_repair,'unestablished');
});

test('zero physical controller attempts establish absence, while a host inspection limit leaves exposure open',()=>{
  const {cases,grade} = coverageEpisode();
  const r = cases[2].report;
  const e = r.adjudication.projection.exposures[0];
  e.rendered = null;
  e.one_computed_block = null;
  assert.equal(grade().cases[2].initial_presentation_confirmed,null);
  assert.equal(grade().cases[2].exposed_computed,null);
  r.adjudication.projection = null;
  r.adjudication.delivery = [];
  r.metrics = {physical_attempts:[]};
  r.final_metrics_complete = false;
  assert.equal(grade().cases[2].exposed_computed,null);
  r.final_metrics_complete = true;
  assert.equal(grade().cases[2].initial_presentation_confirmed,false);
  assert.equal(grade().cases[2].exposed_computed,false);
});

test('exhaustive confirmed provider errors prove non-exposure while retaining the physical calls',()=>{
  const {cases,grade} = coverageEpisode();
  const r = cases[2].report;
  r.final_metrics_complete = true;
  const attempt = r.adjudication.delivery[0];
  attempt.model_response = false;
  r.adjudication.projection.exposures[0].model_response = false;
  r.metrics = {controller:{calls:1},physical_attempts:[{id:attempt.id,role:'controller'}]};
  assert.equal(grade().cases[2].initial_presentation_confirmed,false);
  assert.equal(grade().cases[2].compliant,false);
  assert.equal(grade().cases[2].exposed_computed,false);
  assert.equal(grade().downstream_resources.known_physical_attempts,1);
  r.metrics.controller.calls++;
  r.metrics.physical_attempts.push({id:'uncaptured',role:'controller'});
  assert.equal(grade().cases[2].initial_presentation_confirmed,null);
  assert.equal(grade().cases[2].exposed_computed,null);
});

test('observed authoring opportunities and actual build attempts have separate denominators',()=>{
  const {author,grade} = coverageEpisode();
  const report = author.report;
  report.metrics = {actions:[]};
  report.final_metrics_complete = true;
  Object.assign(report.adjudication,{builds:[],candidate:null,authored_and_applied:false,applied_use:null});
  assert.equal(grade().authoring_opportunity,true);
  assert.equal(grade().authoring_attempted,false);
  report.adjudication.builds.push({disposition:'rejected'});
  assert.equal(grade().authoring_attempted,true);
  report.adjudication.builds = [];
  report.metrics.actions = [{name:'program',arguments:{command:{tag:'build'}}}];
  assert.equal(grade().authoring_attempted,true);
  report.metrics = null;
  report.final_metrics_complete = false;
  assert.equal(grade().authoring_attempted,null);
});

test('a bound ordinary decision can establish that no computed view reached the consumer',()=>{
  const subject = {phase:'transfer',case_id:'ord'};
  const report = presentedReport('ordinary','ord',exhausted);
  const trace = report.adjudication;
  trace.projection = null;
  trace.delivery[0].selected_view = null;
  const grade = arm=>gradeCondition({arm,downstream:[subject]},[{subject,state:'completed',report}],unpriced).cases[0];
  assert.equal(grade('evidence').exposed_computed,null);
  trace.evidence_complete = true;
  assert.equal(grade('evidence').exposed_computed,false);
  assert.equal(grade('repair').exposed_computed,false);
  trace.delivery.push({...trace.delivery[0],selected_view:'other',model_response:null,delivery:'unknown'});
  assert.equal(grade('evidence').exposed_computed,null);
});

test('a complete ordinary request inventory establishes non-exposure across a refusal',()=>{
  const subject = {phase:'transfer',case_id:'ord'}, report = presentedReport('ordinary','ord',exhausted);
  const trace = report.adjudication, attempt = trace.delivery[0];
  Object.assign(trace,{projection:null,report_bound:false,evidence_complete:false});
  report.result.outcome.value.result.tag = 'refusal';
  report.grading = null;
  attempt.selected_view = null;
  report.final_metrics_complete = true;
  report.metrics = {controller:{calls:1},physical_attempts:[{id:attempt.id,role:'controller'}]};
  const row = ()=>gradeCondition({arm:'evidence',downstream:[subject]},[{subject,state:'refusal',report}],unpriced).cases[0];
  assert.equal(row().decision,'refusal');
  assert.equal(row().exposed_computed,false);
  attempt.selected_view = 'uninspected';
  assert.equal(row().exposed_computed,null);
  attempt.selected_view = null;
  report.final_metrics_complete = false;
  assert.equal(row().exposed_computed,null);
  report.final_metrics_complete = true;
  trace.delivery = [];
  assert.equal(row().exposed_computed,null);
});

test('build totals include direct setup work and retain unmeasured compiler time',()=>{
  const subject = {phase:'transfer',case_id:'compiled'};
  const report = {effective_condition:'fixed-adequate',bootstrap:{program:{kind:'program',id:'p'}},
    metrics:{physical_attempts:[],build_commands:2,build_attempts:2,builds:2,settled_builds:2,timed_builds:2,
      known_rejected_build_commands:0,rejected_build_commands:0,compiler_nanoseconds:15}};
  const grade = ()=>gradeCondition({arm:'fixed-adequate',downstream:[subject]},[{subject,state:'completed',report}],unpriced)
    .downstream_resources;
  assert.equal(grade().builds,3);
  assert.equal(grade().bootstrap_builds,1);
  assert.equal(grade().bootstrap_build_elapsed_nanoseconds,null);
  assert.equal(grade().compiler_nanoseconds,null);
  assert.equal(grade().captured_compiler_nanoseconds,15);
  report.bootstrap.build_metrics = {build_commands:1,rejected_build_commands:0,build_elapsed_nanoseconds:null,compiler_nanoseconds:null};
  report.bootstrap_build_metrics = {build_commands:null,rejected_build_commands:null,build_elapsed_nanoseconds:'256',compiler_nanoseconds:null};
  assert.equal(grade().builds,3);
  assert.equal(grade().rejected_builds,0);
  assert.equal(grade().bootstrap_build_elapsed_nanoseconds,256);
  assert.equal(grade().compiler_nanoseconds,null);
  delete report.bootstrap_build_metrics;
  report.bootstrap.build_metrics = {build_commands:1,build_elapsed_nanoseconds:'123',compiler_nanoseconds:null};
  assert.equal(grade().bootstrap_build_elapsed_nanoseconds,123);
  assert.equal(grade().compiler_nanoseconds,null);
  report.bootstrap.build_metrics = {build_commands:null,rejected_build_commands:null,
    build_elapsed_nanoseconds:null,compiler_nanoseconds:null};
  assert.equal(grade().builds,null);
  assert.equal(grade().known_builds,2);
  assert.equal(grade().rejected_builds,null);
  report.bootstrap = null;
  report.candidate_rejection = 'ProjectionWorkFailed';
  assert.equal(grade().bootstrap_builds,1);
  report.candidate_rejection = null;
  assert.equal(grade().builds,null);
  report.effective_condition = 'ordinary';
  assert.equal(grade().bootstrap_builds,0);
  assert.equal(grade().builds,2);
  assert.equal(grade().compiler_nanoseconds,15);
  report.metrics.build_commands++;
  report.metrics.known_rejected_build_commands++;
  report.metrics.rejected_build_commands++;
  assert.equal(grade().builds,3);
  assert.equal(grade().dispatched_builds,2);
  assert.equal(grade().rejected_builds,1);
  assert.equal(grade().compiler_nanoseconds,15);
  report.metrics.build_commands++;
  report.metrics.build_attempts++;
  report.metrics.builds++;
  report.metrics.rejected_build_commands = null;
  assert.equal(grade().builds,4);
  assert.equal(grade().dispatched_builds,3);
  assert.equal(grade().captured_builds,3);
  assert.equal(grade().settled_builds,2);
  assert.equal(grade().timed_builds,2);
  assert.equal(grade().rejected_builds,null);
  assert.equal(grade().known_rejected_builds,1);
  assert.equal(grade().compiler_nanoseconds,null);
  report.metrics.settled_builds++;
  report.metrics.rejected_build_commands = 1;
  assert.equal(grade().rejected_builds,1);
  assert.equal(grade().compiler_nanoseconds,null);
});

test('a deadline before task admission has zero build work while a lost bootstrap reply remains open',()=>{
  const subject = {phase:'transfer',case_id:'expired'};
  const report = {task:null,bootstrap:null,effective_condition:'fixed-adequate',errors:[],timed_out:true,
    inference_dispatch_possible:false,metrics:null,final_metrics_complete:false};
  const resources = ()=>gradeCondition({arm:'fixed-adequate',downstream:[subject]},[{subject,state:'timed_out',report}],unpriced)
    .downstream_resources;
  for (const key of ['bootstrap_builds','bootstrap_build_elapsed_nanoseconds','builds','rejected_builds','compiler_nanoseconds'])
    assert.equal(resources()[key],0,key);
  report.task = {task_id:'admitted'};
  for (const key of ['bootstrap_builds','bootstrap_build_elapsed_nanoseconds','builds','rejected_builds','compiler_nanoseconds'])
    assert.equal(resources()[key],null,key);
});

test('native terminal outcomes and incomplete reports do not supply decisions; bound wrong classifications do',()=>{
  const {cases,grade} = coverageEpisode();
  const r = cases[0].report;
  r.grading = null;
  for (const tag of ['refusal','capacity','no_result','report']) {
    r.result.outcome.value.result.tag = tag;
    assert.equal(grade().cases[0].decision,tag === 'report' ? 'ungraded_report' : tag);
    assert.equal(grade().answered_cases,4);
    assert.equal(grade().all_cases_completed,false);
  }
  r.grading = {answer:null,errors:['invalid_json'],supported:false};
  assert.equal(grade().cases[0].state,'malformed_answer');
  r.grading = {answer:{outcome:exhausted,support:[]},errors:['wrong_subject'],supported:false,
    outcome_correct:false,unsupported_exhaustion:true};
  r.adjudication.report_bound = false;
  assert.equal(grade().cases[0].state,'unbound_report');
  assert.equal(grade().cases[0].unsupported_exhaustion,null);
  r.adjudication.report_bound = true;
  assert.equal(grade().cases[0].unsupported_exhaustion,true);
  assert.equal(grade().all_cases_completed,true);
  assert.equal(grade().all_cases_supported,false);
  assert.equal(grade().answered_cases,5);
  cases[0].state = 'timed_out';
  assert.equal(grade().answered_cases,5);
  assert.equal(grade().completed_cases,4);
  assert.equal(grade().all_cases_completed,false);
});

test('attempt costs retain partial nonnegative usage and physical request bytes through failed authoring',()=>{
  const author = {subject:{phase:'author'},state:'infrastructure_failure',report:{authoring_opportunity:false,
    final_metrics_complete:true,metrics:{physical_attempts:[]},cost:{complete:true,total:2}}};
  const subject = {phase:'transfer',case_id:'one'};
  const transfer = {subject,state:'timed_out',report:{observed_provider_attempts:[
    {request_body_bytes:51,usage:{input_tokens:-2,output_tokens:8}},
    {request_body_bytes:null,usage:{input_tokens:3,output_tokens:-1}}]}};
  const grade = ()=>gradeCondition({arm:'repair',downstream:[subject]},[author,transfer],{kind:'tariff'});
  assert.equal(grade().authoring_attempted,false);
  author.report.authoring_opportunity = null;
  assert.equal(grade().authoring_attempted,null);
  const r = grade().end_to_end_resources;
  assert.equal(r.physical_attempts,null);
  assert.equal(r.known_physical_attempts,2);
  assert.equal(r.known_input_tokens,3);
  assert.equal(r.known_output_tokens,8);
  assert.equal(r.usage_complete,false);
  assert.equal(r.missing_usage_attempts,2);
  assert.equal(r.known_request_body_bytes,51);
  assert.equal(r.request_body_bytes,null);
  assert.equal(r.monetary_cost,null);
  assert.equal(r.known_monetary_cost,2);
  transfer.report.metrics = {physical_attempts:[{request_body_bytes:51,usage:{input_tokens:3,output_tokens:8}}]};
  transfer.report.final_metrics_complete = true;
  assert.equal(grade().end_to_end_resources.request_body_bytes,51);
  assert.equal(grade().end_to_end_resources.usage_complete,true);
});

test('partially priced tasks retain known host, storage, and independently priced input and output',()=>{
  const subject = {phase:'transfer',case_id:'one'};
  const report = {elapsed_ms:10000,retained_namespace_bytes:5,cost:{complete:false,total:null},
    observed_provider_attempts:[{usage:{input_tokens:100000}},{usage:{output_tokens:50000}},{usage:null}]};
  const price = {...tariff,host_per_second:1,retention_seconds:2,storage_per_byte_second:0.01};
  const grade = ()=>gradeCondition({arm:'evidence',downstream:[subject]},[{subject,state:'timed_out',report}],price)
    .end_to_end_resources;
  assert.equal(grade().known_inference_cost,0.2);
  assert.ok(Math.abs(grade().known_monetary_cost-10.3)<1e-12);
  assert.equal(grade().monetary_cost,null);
  price.cached_input_per_million = 0.5;
  assert.ok(Math.abs(grade().known_inference_cost-0.15)<1e-12);
  report.observed_provider_attempts[0].usage.input_tokens_details = {cached_tokens:10000};
  assert.equal(grade().known_inference_cost,0.195);
});

test('exact tariff components follow the charged units, independently of unrelated missing measurements',()=>{
  const subject = {phase:'transfer',case_id:'priced'};
  const usage = {input_tokens:100000,output_tokens:100000}, report = {final_metrics_complete:true,
    metrics:{physical_attempts:[{usage}]},cost:{inference:null,complete:false}};
  const price = {...tariff,storage_per_byte_second:1,retention_seconds:1};
  const grade = ()=>gradeCondition({arm:'evidence',downstream:[subject]},[{subject,state:'completed',report}],price)
    .end_to_end_resources;
  assert.ok(Math.abs(grade().inference_cost-0.3)<1e-12);
  assert.equal(grade().monetary_cost,null);
  delete usage.input_tokens;
  price.input_per_million = 0;
  price.cached_input_per_million = 0.5;
  usage.input_tokens_details = {cached_tokens:100000};
  assert.equal(grade().inference_cost,0.25);
  delete usage.input_tokens_details;
  assert.equal(grade().inference_cost,null);
  assert.equal(grade().known_inference_cost,0.2);
  report.observed_provider_attempts = [{usage:null}];
  report.metrics = null;
  report.final_metrics_complete = false;
  price.cached_input_per_million = 0;
  price.output_per_million = 0;
  assert.equal(grade().inference_cost,0);
  price.retention_seconds = 0;
  assert.equal(grade().monetary_cost,0);
  price.output_per_million = 2;
  assert.equal(grade().inference_cost,null);
  report.observed_provider_attempts = [];
  report.inference_dispatch_possible = false;
  assert.equal(grade().physical_attempts,0);
  assert.equal(grade().inference_cost,0);
  report.inference_dispatch_possible = true;
  assert.equal(grade().physical_attempts,null);
  assert.equal(grade().inference_cost,null);
});

test('scripted fixture measurements retain work and exclude simulated provider traffic',()=>{
  const subject = {phase:'author'}, report = {execution_mode:'scripted_fixture',final_metrics_complete:true,
    metrics:{physical_attempts:[{request_body_bytes:100,usage:{input_tokens:7,output_tokens:5}}],work_items:2}};
  const r = gradeCondition({arm:'repair',downstream:[]},[{subject,state:'completed',report}],tariff).end_to_end_resources;
  assert.equal(r.physical_attempts,0);
  assert.equal(r.request_body_bytes,0);
  assert.equal(r.known_input_tokens,0);
  assert.equal(r.inference_cost,0);
  assert.equal(r.work_items,2);
});
