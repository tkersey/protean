import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {appendFileSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {describedProposalSubject} from './protean-proposal.mjs';
import {ProteanProposalClient} from './protean-proposal-github.mjs';
import {GitHubReader,githubCommand} from './github.mjs';
import {jobPermissions} from './app-token.mjs';
import {readRegular} from './review-owner.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {encodeRecord,sha256} from './encoding.mjs';
import {automationMode} from './review-observer.mjs';
import {workflowPages} from './workflow-artifact.mjs';
import {manifestOperations} from './protean-native-manifest.mjs';
import {currentProteanSource,appActor,preparationPulls,retireProteanProposal,frozenProteanCandidate} from './release-observation.mjs';
import {proteanPreparationPlan} from './protean-preparation-plan.mjs';
import {prepareProtean} from './protean-prepare.mjs';
import {preparationWorkflow,readProteanPreparation,serializePreparation,preparationName} from './protean-preparation-artifact.mjs';

export const preparationStartName=digest=>{assert.match(digest,/^[0-9a-f]{64}$/);return `protean-preparation-start-${digest}.json`;};

export async function priorPreparationAttempt({base,decisionSha256},command=githubCommand){
  const reader=new GitHubReader('tkersey/protean',command),artifacts=await workflowPages(reader,'actions/artifacts','artifacts');
  const starts=artifacts.filter(item=>item.name===preparationStartName(decisionSha256)&&
    item.workflow_run?.repository_id===1328996555&&item.workflow_run?.head_repository_id===1328996555&&
    item.workflow_run?.head_sha===base&&item.workflow_run?.head_branch==='main');
  for(const item of starts){
    const run=await reader.api(`actions/runs/${item.workflow_run.id}`);
    if(run.path!==preparationWorkflow)continue;
    assert.equal(run.head_sha,base);assert.equal(run.run_attempt,1);
    assert.equal(run.repository.id,1328996555);assert.equal(run.head_repository.id,1328996555);
    return {runId:run.id,status:run.status,conclusion:run.conclusion};
  }
  const runs=await workflowPages(reader,`actions/workflows/repository-preparation.yml/runs?head_sha=${base}`,'workflow_runs');
  for(const run of runs){
    if(run.path!==preparationWorkflow||run.head_sha!==base||run.head_branch!=='main'||
      run.repository?.id!==1328996555||run.head_repository?.id!==1328996555)continue;
    const original=artifacts.some(item=>/^protean-preparation-start-[0-9a-f]{64}\.json$/.test(item.name)&&item.workflow_run?.id===run.id);
    if(original)continue;
    const jobs=await workflowPages(reader,`actions/runs/${run.id}/attempts/1/jobs`,'jobs');
    if(jobs.some(job=>job.name==='Native candidate preparation'&&job.steps.some(step=>step.name==='Generate frozen native candidate'&&
      step.started_at&&step.status!=='queued'&&step.conclusion!=='skipped'))){
      return {runId:run.id,status:run.status,conclusion:run.conclusion,reason:'original generation-start evidence missing'};
    }
  }
  return null;
}

export async function planProteanPreparation({controlCommit,identity,native},{client=new ProteanProposalClient(),command=githubCommand,
  sourceReader=currentProteanSource,actorReader=appActor,plan=proteanPreparationPlan,read=readProteanPreparation,
  prior=priorPreparationAttempt,pulls=preparationPulls,retire=retireProteanProposal,freeze=frozenProteanCandidate}={}){
  assert.equal(identity.repository,'tkersey/protean');assert.equal(identity.repositoryId,1328996555);
  assert.equal(identity.role,'observer');assert.deepEqual(identity.permissions,jobPermissions.observer);
  assert.ok(Date.parse(identity.expiresAt)>Date.now(),'read credential expired');
  if(await automationMode(client)==='off')return {status:'disabled'};
  const source=await sourceReader(client);
  if(source.commit!==controlCommit)return {status:'held',reason:'Accepted main changed; observe the current source before preparation.'};
  const actor=await actorReader(identity,command),current=(await pulls(client)).find(value=>value.state==='open')??null;
  if(current && describedProposalSubject(current.body).head!==current.head.sha)
    return {status:'held',reason:'Complete the admitted successor metadata recovery before preparing another source.'};
  const frozen=await freeze(current,source,{client,command});
  const selected=await plan({source,client,command,native,actor,frozen});
  if(selected.status!=='prepare')return selected;
  const original=await read({base:source.commit,...(frozen===null?{}:{head:frozen.head}),kosmosRecordSha256:selected.decision.kosmosRecordSha256,version:selected.decision.version},command);
  if(original!==null)return {status:'prepared',head:original.candidate.head,runId:original.run.id};
  if(current){
    if(current.draft||current.labels.some(label=>label.name==='automation-hold'))return {status:'held',reason:'The current proposal is draft or held by its owner.'};
    await retire({client,command,native,actor})({pull:current,knownHead:current.head.sha});
  }
  const previous=await prior({base:source.commit,decisionSha256:selected.decisionSha256},command);
  if(previous!==null)return {status:'held',reason:'Original native generation already started; recover its evidence before another invocation.',original:previous};
  return {...selected,actor,source,status:'ready'};
}

export async function generateProteanPreparation({plan,tool,compiler,outputDirectory,runId},{client=new ProteanProposalClient(),
  command=githubCommand,native=manifestOperations(tool.path,compiler.path),sourceReader=currentProteanSource,
  select=proteanPreparationPlan,prepare=prepareProtean}={}){
  assert.equal(plan.status,'ready');assert.equal(tool.sourceCommit,plan.source.commit);assert.equal(compiler.sourceCommit,plan.source.commit);
  assert.notEqual(await automationMode(client),'off','automation disabled before native preparation');
  const admitVersionDecision=async({decisionBytes})=>{
    assert.notEqual(await automationMode(client),'off','automation disabled before native generation');
    const source=await sourceReader(client);assert.deepEqual(source,plan.source,'source changed before generation');
    const frozen={base:plan.source.commit,kosmosReleaseId:plan.decision.kosmosReleaseId,kosmosRecordSha256:plan.decision.kosmosRecordSha256};
    const current=await select({source,client,command,native,actor:plan.actor,frozen});
    assert.equal(current.status,'prepare');assert.equal(current.decisionSha256,plan.decisionSha256,'approved native inputs changed');
    assert.deepEqual(decisionBytes,encodeRecord(current.decision));return current.decisionSha256;
  };
  const result=await prepare({base:plan.source.commit,baseTree:plan.source.tree,tool,compiler,outputDirectory,
    versionDecision:plan.decision,admitVersionDecision,author:{name:plan.actor.login,email:`${plan.actor.id}+${plan.actor.login}@users.noreply.github.com`}});
  assert.equal(result.status,'prepared','frozen upstream selection changed');
  return {result,bytes:serializePreparation(result,{controlCommit:plan.source.commit,runId},outputDirectory)};
}

if(import.meta.main){
  const [operation,control,toolPath,compilerPath,output,identityPath]=process.argv.slice(2);
  assert.ok(['plan','generate'].includes(operation)&&control&&toolPath&&compilerPath&&output&&identityPath&&process.argv.length===8);
  const root=resolve(control),directory=resolve(output),git=args=>execFileSync('git',['--no-replace-objects',...args],{cwd:root,encoding:'utf8',timeout:30000}).trim();
  const controlCommit=git(['rev-parse','HEAD']);assert.equal(git(['status','--porcelain=v1','--untracked-files=no']),'');
  if(process.env.GITHUB_SHA)assert.equal(controlCommit,process.env.GITHUB_SHA);
  const identity=parseEvidenceJson(readRegular(resolve(identityPath),1024*1024)),native=manifestOperations(resolve(toolPath),resolve(compilerPath));
  let result;
  if(operation==='plan'){
    mkdirSync(directory,{mode:0o700});result=await planProteanPreparation({controlCommit,identity,native});
    if(result.status==='ready'){
      writeFileSync(join(directory,'plan.json'),encodeRecord(result),{flag:'wx',mode:0o400});
      writeFileSync(join(directory,preparationStartName(result.decisionSha256)),encodeRecord({schema:'protean-preparation-start/v1',base:controlCommit,
        runId:Number(process.env.GITHUB_RUN_ID),decisionSha256:result.decisionSha256}),{flag:'wx',mode:0o400});
      if(process.env.GITHUB_OUTPUT)appendFileSync(process.env.GITHUB_OUTPUT,`ready=true\nstart_name=${preparationStartName(result.decisionSha256)}\n`);
    }
  }else{
    const plan=parseEvidenceJson(readRegular(join(directory,'plan.json'),4*1024*1024));
    assert.equal(plan.source.commit,controlCommit);
    const tool={path:resolve(toolPath),sha256:sha256(readFileSync(toolPath)),sourceCommit:controlCommit};
    const compiler={path:resolve(compilerPath),sha256:sha256(readFileSync(compilerPath)),sourceCommit:controlCommit};
    const generated=await generateProteanPreparation({plan,tool,compiler,outputDirectory:join(directory,'native'),runId:Number(process.env.GITHUB_RUN_ID)},
      {native});
    const name=preparationName(controlCommit,generated.result.candidate.head);
    writeFileSync(join(directory,name),generated.bytes,{flag:'wx',mode:0o400});
    if(process.env.GITHUB_OUTPUT)appendFileSync(process.env.GITHUB_OUTPUT,`name=${name}\n`);
    result={status:'prepared',base:controlCommit,head:generated.result.candidate.head};
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if(process.env.GITHUB_STEP_SUMMARY)appendFileSync(process.env.GITHUB_STEP_SUMMARY,`\nNative preparation observation\n\n\`\`\`json\n${JSON.stringify(result,null,2)}\n\`\`\`\n`);
}
