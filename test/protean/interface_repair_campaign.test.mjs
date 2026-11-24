import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {prepareInterfaceRepair, validateRepairPlan, selectRepairProfile, gradeCondition, repairOrder,
  runInterfaceRepair} from '../../tools/evaluation/interface_repair_campaign.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const config = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.chatgpt.example.json',import.meta.url)));

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
    arm_violations:[],grading:{supported:true,outcome_correct:true}}},
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
  assert.equal(grade().compliant,true);
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
    now:()=>clock,
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
  assert.equal(result.campaign_ceiling_exceeded,false);
});
