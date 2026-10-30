import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync, lstatSync} from 'node:fs';
import {join} from 'node:path';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRecord} from './record.mjs';
import {GitHubReader, githubCommand} from './github.mjs';
import {workflowPages, authenticateWorkflowArtifact} from './workflow-artifact.mjs';
import {mechanicalPaths, nativeCandidateBinding, proposalMessage, proposalCommitOid} from './protean-proposal.mjs';

const repository = 'tkersey/protean', repositoryId = 1328996555;
export const preparationWorkflow = '.github/workflows/repository-preparation.yml';
export const preparationJob = 'Native candidate preparation';
const maximumBytes = 192 * 1024 * 1024;
const oid = value => {assert.match(value, /^[0-9a-f]{40}$/); return value;};
const id = value => {assert.ok(Number.isSafeInteger(value) && value > 0); return value;};

export function preparationName(base, head) {
  return `protean-preparation-${oid(base)}-${oid(head)}.json`;
}

function bytes(value, maximum = 64 * 1024 * 1024) {
  assert.equal(typeof value, 'string');
  const decoded = Buffer.from(value, 'base64');
  assert.equal(decoded.toString('base64'), value); assert.ok(decoded.length <= maximum);
  return decoded;
}

function canonical(value) {
  const original = bytes(value, 1024 * 1024), parsed = parseEvidenceJson(original);
  assert.deepEqual(encodeRecord(parsed), original, 'noncanonical preparation evidence');
  return {bytes: original, value: parsed};
}

export function readPreparationBytes(input, expected = {}) {
  assert.ok(Buffer.isBuffer(input) && input.length <= maximumBytes);
  const value = parseEvidenceJson(input, maximumBytes);
  assert.deepEqual(Object.keys(value), ['schema', 'context', 'candidate', 'nativeResult', 'proof', 'decision',
    'upstreamRecord', 'upstreamAdmission', 'derivedRecord', 'derivedAdmission', 'files', 'captures']);
  assert.deepEqual(Buffer.from(`${JSON.stringify(value)}\n`), input, 'noncanonical preparation transport');
  assert.equal(value.schema, 'protean-preparation-artifact/v1');
  assert.deepEqual(Object.keys(value.context), ['repository', 'controlCommit', 'runId']);
  assert.equal(value.context.repository, repository); oid(value.context.controlCommit); id(value.context.runId);
  const descriptor = canonical(value.candidate), proof = canonical(value.proof), decision = canonical(value.decision);
  assert.deepEqual(Object.keys(descriptor.value).sort(), ['author','base','baseTree','committer','files','head','impact','kosmosRecordSha256','kosmosReleaseId',
    'message','nativeResultSha256','schema','tree','version']);
  assert.equal(descriptor.value.schema, 'protean-prepared-candidate/v1');
  assert.equal(descriptor.value.base, value.context.controlCommit);
  for (const field of ['base','head']) if (expected[field] !== undefined) assert.equal(descriptor.value[field], expected[field]);
  if (expected.controlCommit !== undefined) assert.equal(value.context.controlCommit, expected.controlCommit);
  assert.ok(Array.isArray(value.files)); assert.deepEqual(value.files.map(item => item.path), mechanicalPaths);
  assert.deepEqual(descriptor.value.files.map(item => item.path), mechanicalPaths);
  const files = new Map(); let total = 0;
  for (let index = 0; index < value.files.length; index++) {
    const file = value.files[index]; assert.deepEqual(Object.keys(file), ['path','data']);
    const data = bytes(file.data); total += data.length; assert.ok(total <= 64 * 1024 * 1024);
    const expectedFile = descriptor.value.files[index];
    assert.equal(data.length, expectedFile.bytes); assert.equal(sha256(data), expectedFile.sha256);
    files.set(file.path, data);
  }
  const nativeResultBytes = bytes(value.nativeResult, 1024 * 1024);
  assert.equal(sha256(nativeResultBytes), descriptor.value.nativeResultSha256);
  const upstreamRecordBytes = bytes(value.upstreamRecord, 1024 * 1024), upstream = readRecord(upstreamRecordBytes);
  assert.equal(upstream.repository.name, 'tkersey/kosmos');
  assert.equal(sha256(upstreamRecordBytes), descriptor.value.kosmosRecordSha256);
  const {schema: ignoredSchema, nativeResultSha256: ignoredDigest, kosmosRecordSha256: ignoredRecord, ...fields} = descriptor.value;
  const candidate = {...fields, files, nativeResultBytes, kosmosRecordBytes: upstreamRecordBytes};
  assert.equal(candidate.message, proposalMessage(candidate)); assert.equal(candidate.head, proposalCommitOid(candidate));
  const binding = nativeCandidateBinding(candidate);
  assert.equal(proof.value.schema, 'protean-native-preparation/v1'); assert.deepEqual(proof.value.binding, binding);
  for (const tool of [proof.value.tool, proof.value.compiler]) {
    assert.equal(tool.sourceCommit, candidate.base); assert.match(tool.sha256, /^[0-9a-f]{64}$/);
  }
  assert.equal(proof.value.decisionSha256, sha256(decision.bytes));
  for (const field of ['base','baseTree','version']) assert.equal(decision.value[field], candidate[field]);
  assert.deepEqual(decision.value.impact, candidate.impact);
  assert.equal(decision.value.kosmosReleaseId, candidate.kosmosReleaseId);
  assert.equal(decision.value.kosmosRecordSha256, sha256(upstreamRecordBytes));
  assert.equal(upstream.dependencies.length, 1);
  const derived = upstream.dependencies[0]; assert.equal(derived.repository.name, 'tkersey/horos');
  const derivedRecordBytes = bytes(value.derivedRecord, 1024 * 1024), derivedRecord = readRecord(derivedRecordBytes);
  assert.equal(derivedRecord.repository.name, 'tkersey/horos');
  assert.equal(sha256(derivedRecordBytes), derived.release.recordSha256);
  assert.deepEqual(derivedRecord.source, derived.source); assert.equal(derivedRecord.tag, derived.release.tag);
  const derivedAdmissionBytes = bytes(value.derivedAdmission, 8 * 1024 * 1024);
  assert.ok(derivedAdmissionBytes.length > 0); assert.equal(sha256(derivedAdmissionBytes), proof.value.horosAdmissionSha256);
  const upstreamAdmissionBytes = bytes(value.upstreamAdmission, 8 * 1024 * 1024);
  assert.ok(upstreamAdmissionBytes.length > 0); assert.equal(sha256(upstreamAdmissionBytes), proof.value.admissionSha256);
  assert.ok(Array.isArray(value.captures)); assert.equal(value.captures.length, 3); assert.equal(proof.value.captures.length, 3);
  const captures = value.captures.map((capture,index) => {
    assert.deepEqual(Object.keys(capture), ['index','stdout','stderr']); assert.equal(capture.index,index);
    const stdout = bytes(capture.stdout), stderr = bytes(capture.stderr);
    total += stdout.length + stderr.length; assert.ok(total <= 128 * 1024 * 1024);
    const original = proof.value.captures[index];
    assert.equal(original.args[0], ['source-manifest','refresh','coherence'][index]);
    if (index > 0) assert.equal(original.args[index === 1 ? 4 : 3], proof.value.compiler.path);
    assert.equal(sha256(stdout), original.stdoutSha256); assert.equal(sha256(stderr), original.stderrSha256);
    return {stdout,stderr};
  });
  assert.equal(sha256(captures[0].stdout), proof.value.manifestSha256);
  return {status:'prepared',candidate,binding,context:value.context,candidateBytes:descriptor.bytes,
    proofBytes:proof.bytes,decisionBytes:decision.bytes,upstreamRecordBytes,upstreamAdmissionBytes,derivedRecordBytes,derivedAdmissionBytes,captures};
}

export function serializePreparation(result, {controlCommit, runId}, outputDirectory) {
  assert.equal(result.status,'prepared'); oid(controlCommit); id(runId);
  const encoded = data => {assert.ok(Buffer.isBuffer(data)); return data.toString('base64');};
  const captures = [0,1,2].map(index => {
    const read = name => {
      const path = join(outputDirectory,'host-captures',`execution-${index}`,name), stat = lstatSync(path);
      assert.ok(stat.isFile() && !stat.isSymbolicLink() && stat.size <= 64 * 1024 * 1024);
      return readFileSync(path);
    };
    return {index,stdout:encoded(read('stdout.bin')),stderr:encoded(read('stderr.txt'))};
  });
  const value = {schema:'protean-preparation-artifact/v1',context:{repository,controlCommit,runId},
    candidate:encoded(result.candidateBytes),nativeResult:encoded(result.candidate.nativeResultBytes),
    proof:encoded(result.proofBytes),decision:encoded(result.decisionBytes),upstreamRecord:encoded(result.upstreamRecordBytes),
    upstreamAdmission:encoded(result.upstreamAdmissionBytes),derivedRecord:encoded(result.derivedRecordBytes),
    derivedAdmission:encoded(result.derivedAdmissionBytes),
    files:mechanicalPaths.map(path=>({path,data:encoded(result.candidate.files.get(path))})),captures};
  const output = Buffer.from(`${JSON.stringify(value)}\n`); readPreparationBytes(output,{base:controlCommit}); return output;
}

function provenance(result, decoded) {
  const {run,job,artifact,workflow}=result, base=decoded.candidate.base;
  id(run.id);id(job.id);id(artifact.id);
  assert.equal(run.repository.id,repositoryId);assert.equal(run.head_repository.id,repositoryId);
  assert.equal(run.run_attempt,1);assert.equal(run.head_branch,'main');assert.equal(run.head_sha,base);
  assert.equal(run.status,'completed');assert.equal(run.conclusion,'success');
  assert.ok(['schedule','workflow_dispatch','workflow_run'].includes(run.event));
  assert.equal(run.path,preparationWorkflow);assert.equal(workflow.path,preparationWorkflow);assert.equal(workflow.commit,base);
  assert.match(workflow.sha256,/^[0-9a-f]{64}$/);
  assert.equal(job.name,preparationJob);assert.equal(job.run_id,run.id);assert.equal(job.run_attempt,1);assert.equal(job.head_sha,base);
  assert.equal(job.status,'completed');assert.equal(job.conclusion,'success');assert.ok(job.labels.includes('ubuntu-24.04'));
  const start=Date.parse(job.started_at),end=Date.parse(job.completed_at);
  assert.ok(Number.isFinite(start)&&Number.isFinite(end)&&end>=start&&end-start<=600000);
  for(const name of ['Compile accepted native preparation tool','Generate frozen native candidate','Upload original preparation evidence']){
    const steps=job.steps.filter(step=>step.name===name);assert.equal(steps.length,1);
    assert.equal(steps[0].status,'completed');assert.equal(steps[0].conclusion,'success');
  }
  assert.equal(artifact.name,preparationName(base,decoded.candidate.head));
  assert.equal(artifact.workflow_run.id,run.id);assert.equal(artifact.workflow_run.repository_id,repositoryId);
  assert.equal(artifact.workflow_run.head_repository_id,repositoryId);assert.equal(artifact.workflow_run.head_sha,base);
  assert.equal(artifact.size_in_bytes,result.bytes.length);assert.equal(artifact.digest,'sha256:'+sha256(result.bytes));
  assert.equal(decoded.context.runId,run.id);
}

export function compactProteanPreparation(result) {
  const decoded=readPreparationBytes(result.bytes);provenance(result,decoded);
  const value=parseEvidenceJson(result.bytes,maximumBytes);
  value.files=decoded.candidate.files.size===mechanicalPaths.length?JSON.parse(decoded.candidateBytes).files:null;
  const compact={schema:'protean-retained-preparation/v1',value,run:result.run,job:result.job,artifact:result.artifact,workflow:result.workflow};
  assert.ok(Buffer.byteLength(JSON.stringify(compact))<=3*1024*1024,
    'compact preparation exceeds owner context capacity; recover bounded original evidence before review');
  return compact;
}

export function hydrateProteanPreparation(compact,files,expected={}) {
  assert.equal(compact.schema,'protean-retained-preparation/v1');
  assert.ok(Buffer.byteLength(JSON.stringify(compact))<=3*1024*1024,'retained preparation exceeds capacity');
  assert.ok(files instanceof Map);assert.deepEqual([...files.keys()],mechanicalPaths);
  const value=structuredClone(compact.value);
  assert.deepEqual(value.files,canonical(value.candidate).value.files);
  value.files=mechanicalPaths.map(path=>({path,data:files.get(path).toString('base64')}));
  const original=Buffer.from(JSON.stringify(value)+'\n'), decoded=readPreparationBytes(original,expected);
  const result={bytes:original,run:compact.run,job:compact.job,artifact:compact.artifact,workflow:compact.workflow,...decoded};
  provenance(result,decoded);return result;
}

async function retainedPreparation(reader,base,head,command) {
  if(head===undefined)return null;
  const commit=await reader.api('git/commits/'+head);
  assert.equal(commit.sha,head);assert.deepEqual(commit.parents.map(item=>item.sha),[base]);
  const {readReviewResult}=await import('./review-result.mjs');
  const review=await readReviewResult({repository,base,head,tree:commit.tree.sha,purpose:'pull'},command);
  if(review.status!=='complete'||!review.envelope.context.preparation)return null;
  const files=new Map();
  for(const path of mechanicalPaths){
    const blob=await reader.api('contents/'+path+'?ref='+head);
    assert.equal(blob.type,'file');assert.equal(blob.encoding,'base64');
    const data=Buffer.from(blob.content.replaceAll('\n',''),'base64');
    assert.equal(blob.sha,createHash('sha1').update(Buffer.from('blob '+data.length+'\0')).update(data).digest('hex'));
    files.set(path,data);
  }
  const result=hydrateProteanPreparation(review.envelope.context.preparation,files,{base,head});
  assert.equal(result.candidate.tree,commit.tree.sha);assert.equal(result.candidate.message,commit.message);
  return result;
}

export async function readProteanPreparation({base,head,kosmosRecordSha256,version}, command = githubCommand) {
  oid(base); if (head !== undefined) oid(head);
  const reader = new GitHubReader(repository,command); await reader.verifyRepository();
  const artifacts = await workflowPages(reader,'actions/artifacts','artifacts');
  const matches = artifacts.filter(item => {
    const match = /^protean-preparation-([0-9a-f]{40})-([0-9a-f]{40})\.json$/.exec(item.name);
    return match && match[1] === base && (head === undefined || match[2] === head) &&
      item.workflow_run?.repository_id === repositoryId && item.workflow_run?.head_repository_id === repositoryId &&
      item.workflow_run?.head_sha === base && item.workflow_run?.head_branch === 'main';
  });
  assert.ok(matches.length <= 64, 'preparation evidence capacity exceeded');
  if(matches.length===0){
    const retained=await retainedPreparation(reader,base,head,command);
    if(retained!==null){
      if(kosmosRecordSha256!==undefined)assert.equal(sha256(retained.candidate.kosmosRecordBytes),kosmosRecordSha256);
      if(version!==undefined)assert.equal(retained.candidate.version,version);
    }
    return retained;
  }
  const definition = await reader.api(`contents/${preparationWorkflow}?ref=${base}`);
  assert.equal(definition.type,'file'); assert.equal(definition.encoding,'base64');
  const workflowSha256 = sha256(Buffer.from(definition.content.replaceAll('\n',''),'base64'));
  let selected = null;
  for (const item of matches) {
    const retained=item.expired?await retainedPreparation(reader,base,/([0-9a-f]{40})\.json$/.exec(item.name)[1],command):null;
    assert.ok(!item.expired||retained!==null,'original preparation expired; recover original published evidence before proceeding');
    if(retained!==null){assert.equal(retained.artifact.id,item.id);assert.equal(retained.artifact.digest,item.digest);}
    const result = retained??await authenticateWorkflowArtifact({repository,runId:item.workflow_run.id,controlCommit:base,
      workflowPath:preparationWorkflow,workflowSha256,jobName:preparationJob,name:item.name,maximumBytes},command);
    for (const name of ['Compile accepted native preparation tool','Generate frozen native candidate','Upload original preparation evidence']) {
      const steps=result.job.steps.filter(step=>step.name===name);
      assert.equal(steps.length,1); assert.equal(steps[0].status,'completed'); assert.equal(steps[0].conclusion,'success');
    }
    const decoded=readPreparationBytes(result.bytes,{base,head});
    provenance(result,decoded);
    assert.equal(decoded.context.runId,result.run.id);
    assert.equal(item.name,preparationName(base,decoded.candidate.head));
    if (kosmosRecordSha256 !== undefined && sha256(decoded.candidate.kosmosRecordBytes) !== kosmosRecordSha256) continue;
    if (version !== undefined && decoded.candidate.version !== version) continue;
    assert.equal(selected,null,'multiple original preparations for one candidate input');
    selected={...result,...decoded};
  }
  return selected;
}
