import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {prepareInterfaceRepair, validateRepairPlan, selectRepairProfile, gradeCondition, repairOrder,
  runInterfaceRepair} from '../../tools/evaluation/interface_repair_campaign.mjs';
import {makeRepairCorpus, canonicalEvidence, inspectProjection} from '../../tools/evaluation/interface_repair.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const config = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.chatgpt.example.json',import.meta.url)));
config.tools = {build:true,run:true,reconstruct:false,inputs:[]};

test('preparation rejects absent authoring permissions and invalid tariffs before starting any work', async () => {
  for (const tools of [null, {...config.tools,build:false}, {...config.tools,run:false}])
    await assert.rejects(prepareInterfaceRepair({config:{...config,tools}}), /must allow build and run/);
  for (const costModel of [null,{},[],{kind:'tariff'}])
    await assert.rejects(prepareInterfaceRepair({config,costModel}), /cost model|declared tariff/);
});

test('only the approved initial Astra model and effort survive preparation',()=>{
  const changed = structuredClone(config);
  changed.adaptive.profiles.push({...changed.adaptive.profiles[0],id:'alternate',model:'unapproved'});
  const p = selectRepairProfile(changed);
  assert.equal(p.id,changed.adaptive.initial_profile);
  assert.deepEqual(p.efforts,[changed.adaptive.initial_effort]);
  assert.equal(p.effort_update,false);
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
  const opts = {binary:app,driver:app,applicationPath:app,config,directory:join(root,'episode'),route:'chatgpt'};
  const deps = {describeBuild:()=>({application_assets_sha256:sha('{}')}),
    validateConfiguration:()=>({valid:true}),
    exportSources:()=>({lossy:'sliced loss',adequate:'private reference program'})};
  const plan = await prepareInterfaceRepair(opts,deps);
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
  await assert.rejects(prepareInterfaceRepair(opts,deps),{code:'EEXIST'});
  await assert.rejects(runInterfaceRepair(opts.directory,{...opts,credential:'dummy'}),/route differs/);
  const calls = [];
  const {results} = await runInterfaceRepair(opts.directory,{...opts,chatgptAccount:'fixture'},
    {execute:async ({subject,output,candidate})=>{
      assert.equal(candidate,null);
      calls.push(subject.id);
      const report = {subject,nomination:{status:'no_candidate'},arm_violations:[],status:{status:'completed'},
        errors:[],adjudication:{report_bound:true,authored_and_applied:false},metrics:{physical_attempts:[{usage:null}]},
        grading:subject.phase === 'transfer' ? {supported:false,outcome_correct:false} : null};
      await writeFile(join(output,'report.json'),JSON.stringify(report));
      return report;
    }});
  assert.equal(calls.length,11);
  const [measured] = JSON.parse(await readFile(results)).conditions;
  assert.equal(measured.end_to_end_resources.known_physical_attempts,11);
  assert.equal(measured.downstream_resources.known_physical_attempts,10);
  assert.equal(measured.end_to_end_resources.usage_complete,false);
  assert.equal(measured.supported_repair,'unestablished');
  await assert.rejects(runInterfaceRepair(opts.directory,{...opts,chatgptAccount:'fixture'}),{code:'EEXIST'});
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
  const first = {id:'first',preparation_cut:'2',prepared_sha256:'original',selected_view:'view',delivery:'confirmed'};
  const later = {...first,id:'later',preparation_cut:'10',prepared_sha256:'subsequent'};
  const report = {bootstrap:{view:{id:'view'}},effective_condition:'fixed-lossy',arm_violations:[],
    adjudication:{delivery:[later,first],projection:{one_computed_block:true,result:{kind:'value',id:'result'},
      exposures:[{id:'later',rendered:true},{id:'first',rendered:false}]}}};
  const grade = () => gradeCondition(condition,[{subject,state:'completed',report}],{kind:'unpriced'}).cases[0];
  assert.equal(grade().compliant,false);
  report.adjudication.projection.exposures[1].rendered = true;
  assert.equal(grade().compliant,true);
  first.delivery = 'unknown';
  assert.equal(grade().compliant,null);
  first.delivery = 'confirmed';
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
    validateConfiguration:()=>({valid:true}),exportSources:()=>({lossy:'lossy',adequate:'adequate'})
  });
  let clock = 0;
  const {results} = await runInterfaceRepair(opts.directory,{...opts,credential:'fixture'},{
    now:()=>existsSync(join(opts.directory,'run','results.md')) ? clock + plan.campaign_ceiling_ms : clock,
    execute:async ({subject,deadline,output})=>{
      assert.equal(deadline-clock,plan.condition_ms);
      clock = deadline+20;
      const report = {subject,errors:[],timed_out:true,adjudication:null};
      await writeFile(join(output,'report.json'),JSON.stringify(report));
      return report;
    }
  });
  const result = JSON.parse(await readFile(results));
  assert.equal(result.conditions.length,4);
  for (const c of result.conditions) {
    assert.equal(c.elapsed_ms,1020);
    assert.equal(c.all_cases_completed,false);
    assert.equal(c.cases.filter(row=>row.state === 'not_started').length,c.arm === 'repair' ? 10 : 9);
  }
  const timing = JSON.parse(await readFile(join(opts.directory,'run',result.timing_file)));
  assert.equal(timing.campaign_ceiling_exceeded,true);
  assert.equal(timing.elapsed_ms,clock+plan.campaign_ceiling_ms);
});

const exhausted = 'exhausted_declared_domain';
const unpriced = {kind:'unpriced'};

function presentedReport(arm, id, outcome) {
  const result = {kind:'value',id:'result-'+id}, view = {kind:'view',id:'view-'+id};
  const attempt = {id:'first',selected_view:view.id,preparation_cut:'1',prepared_sha256:'prepared',delivery:'confirmed'};
  return {effective_condition:arm,bootstrap:{view},arm_violations:[],errors:[],
    status:{status:'completed'},result:{outcome:{value:{result:{tag:'report'}}}},
    grading:{answer:{outcome,support:[result]},errors:[],outcome_correct:true,supported:true,unsupported_exhaustion:false},
    adjudication:{report_bound:true,delivery:[attempt],ordinary_fallback:false,transfer_bound:arm === 'repair',
      projection:{result,canonical_input:true,semantic_judgment:'supported',one_computed_block:true,
        exposures:[{...attempt,rendered:true}]}}};
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
    cases[index].report.adjudication.ordinary_fallback = true;
    assert.equal(grade().coverage_repair_demonstrated,false);
    cases[index].report.adjudication.ordinary_fallback = false;
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
  report.adjudication.ordinary_fallback = null;
  assert.equal(grade().cases[0].supported_view_use,null);
  report.adjudication.ordinary_fallback = true;
  assert.equal(grade().cases[0].supported_view_use,false);
  report.adjudication.projection.semantic_judgment = 'unestablished';
  assert.equal(grade().cases[0].needs_payload_adjudication,false);
  report.grading.supported = false;
  report.grading.errors = ['unsupported_coverage'];
  assert.equal(grade().cases[0].needs_payload_adjudication,false);
  report.grading.supported = null;
  report.grading.errors = ['unadjudicated_payload'];
  assert.equal(grade().cases[0].needs_payload_adjudication,true);
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
