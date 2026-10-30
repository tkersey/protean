import assert from 'node:assert/strict';
import test from 'node:test';
import {observeProteanReview} from './review-observer.mjs';
import {impactBlock, versionPreparationImpact} from './impact.mjs';
import {sha256, encodeRecord} from './encoding.mjs';
import {metadata} from './test-support.mjs';
import {proposalBranch, proposalDescription, mechanicalPaths} from './protean-proposal.mjs';
import {proteanJobs} from './protean-qualification.mjs';

const base = 'a'.repeat(40), head = 'b'.repeat(40), tree = 'c'.repeat(40);

function fixture() {
  const mode = {status: 200, body: {name: 'REPOSITORY_AUTOMATION', value: 'propose'}};
  const main = {ref: 'refs/heads/main', object: {type: 'commit', sha: base}};
  const pull = {number: 4, state: 'open', draft: false, labels: [], title: 'Prepare version',
    body: impactBlock(versionPreparationImpact), base: {sha: base, ref: 'main', repo: {id: 1328996555}},
    head: {sha: head, ref: 'feature/source-change', repo: {id: 1328996555}}};
  const run = {id: 10, status: 'completed', conclusion: 'success'};
  const evidence = Buffer.from('original verified qualification fixture');
  const qualification = {run: {...run, html_url: 'https://github.com/tkersey/protean/actions/runs/10'}, evidence,
    workflow: {path: '.github/workflows/zig.yml', commit: head, sha256: sha256(Buffer.from('qualification definition'))},
    jobs: Object.keys(proteanJobs).map((name, index) => ({id: index + 20, name, conclusion: 'success'}))};
  const responses = new Map([
    ['', {full_name: 'tkersey/protean', id: 1328996555, default_branch: 'main'}],
    ['/git/ref/heads/main', main],
    ['/pulls?state=open&base=main&per_page=100&page=1', [pull]],
    ['/pulls/4', pull],
    [`/git/commits/${head}`, {sha: head, tree: {sha: tree}}],
    [`/actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request&per_page=100&page=1`, {workflow_runs: [run]}],
    [`/contents/docs/repository-local-releases.md?ref=${base}`, {type: 'file', encoding: 'base64', content: Buffer.from('Accepted local fixture requirements').toString('base64')}],
  ]);
  let qualified = 0;
  const command = async args => {
    const key = args[1].slice('repos/tkersey/protean'.length);
    assert.ok(responses.has(key), `unexpected observer API ${key}`);
    return Buffer.from(JSON.stringify(responses.get(key)));
  };
  const client = {request: async ({path, method}) => {
    assert.equal(method, undefined); assert.equal(path, '/actions/variables/REPOSITORY_AUTOMATION'); return mode;
  }};
  const qualify = async options => {
    qualified++;
    assert.deepEqual(options, {runId: 10, commit: head, tree, event: 'pull_request'});
    assert.equal(run.conclusion, 'success', 'original qualification failed');
    return qualification;
  };
  let prior = null; const preparation = {};
  const observe = () => observeProteanReview({controlCommit: base}, command, client, async () => prior, qualify, preparation);
  return {mode, main, pull, run, responses, qualification, preparation, observe, qualified: () => qualified, setPrior: value => {prior = value;}};
}

test('qualification inventory remains independently fixed by the repository contract', () => {
  assert.deepEqual(Object.keys(proteanJobs).sort(), ['TigerStyle', 'native',
    ...['authoring', 'owners', 'owner-adaptive-control', 'owner-support', 'workspace', 'workspace-retention',
      'workspace-history', 'correspondence', 'native', 'native-placement', 'downstream']
      .map(name => `Qualification / ${name} / linux-x86_64`)].sort());
});

test('read-only observer binds exact original qualification, impact and requirements before owner dispatch', async () => {
  const value = fixture(), result = await value.observe();
  assert.equal(result.status, 'ready'); assert.equal(value.qualified(), 1);
  assert.equal(result.context.base, base); assert.equal(result.context.head, head); assert.equal(result.context.tree, tree);
  assert.equal(result.context.qualification.evidenceSha256, sha256(value.qualification.evidence));
  assert.deepEqual(Buffer.from(result.context.qualification.originalEvidence, 'base64'), value.qualification.evidence);
  assert.equal(result.context.proof_inventory.length, 13); assert.equal(result.previous, null);
});

test('missing control defaults off without qualification or model admission', async () => {
  const value = fixture(); value.mode.status = 404;
  assert.equal((await value.observe()).status, 'disabled'); assert.equal(value.qualified(), 0);
});

test('uncompleted original qualification stays pending and is never replaced', async () => {
  const value = fixture(); value.run.status = 'in_progress';
  const result = await value.observe();
  assert.equal(result.status, 'waiting'); assert.equal(result.observations[0].status, 'qualification pending');
  assert.equal(value.qualified(), 0);
});

for (const [name, change] of [
  ['failed original qualification', value => {value.run.conclusion = 'failure';}],
  ['duplicate favorable run', value => {value.responses.get(`/actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request&per_page=100&page=1`).workflow_runs.push({...value.run, id: 11});}],
  ['missing declaration', value => {value.pull.body = 'No reviewed impact.';}],
  ['stale pull base', value => {value.pull.base.sha = tree;}],
]) {
  test(`observer blocks ${name}`, async () => {
    const value = fixture(); change(value);
    const result = await value.observe(); assert.equal(result.status, 'waiting');
    assert.equal(result.observations[0].status, 'blocked');
  });
}

test('pending owner state resumes unchanged original context and cannot rewrite impact', async () => {
  const value = fixture(), first = await value.observe();
  const prior = {base, value: {status: 'pending', envelope: {context: first.context}, run: {id: 40}, artifact: {id: 41},
    bytes: Buffer.from('original pending owner result'), workflow: {commit: base, sha256: 'd'.repeat(64)}}};
  value.setPrior(prior);
  const resumed = await value.observe();
  assert.equal(resumed.status, 'ready'); assert.deepEqual(resumed.context, first.context);
  assert.equal(resumed.previous.runId, 40);
  value.pull.body = impactBlock({...versionPreparationImpact, rationale: 'Changed after review.'});
  const changed = await value.observe();
  assert.equal(changed.observations[0].status, 'blocked'); assert.match(changed.observations[0].reason, /impact changed/);
});

test('terminal or already-running owner blocks a second invocation', async () => {
  for (const status of ['blocked', 'running']) {
    const value = fixture(); value.setPrior({base, value: {status, reason: 'Retain original invocation.'}});
    const result = await value.observe(); assert.equal(result.observations[0].status, status);
    assert.equal(value.qualified(), 0);
  }
});

test('draft, explicit hold and foreign candidates are not automatic review subjects', async () => {
  for (const mutate of [value => {value.pull.draft = true;}, value => {value.pull.labels = [{name: 'automation-hold'}];},
    value => {value.pull.head.repo.id++;}]) {
    const value = fixture(); mutate(value);
    assert.equal((await value.observe()).status, 'unchanged'); assert.equal(value.qualified(), 0);
  }
});

test('changed accepted main blocks the stale control checkout', async () => {
  const value = fixture(); value.main.object.sha = tree;
  await assert.rejects(value.observe(), /control checkout is stale/);
});

function preparedCandidate() {
  const record=metadata('kosmos'),kosmosRecordBytes=encodeRecord(record);
  const files=new Map(mechanicalPaths.map(path=>[path,Buffer.from('native fixture '+path)]));
  const nativeResultBytes=Buffer.from(JSON.stringify({schema:'protean-refresh-result/v1',baseCommit:base,baseTree:tree,version:'1.0.1',
    kosmosRecordSha256:sha256(kosmosRecordBytes),horosRecordSha256:record.dependencies[0].release.recordSha256,
    lockSha256:sha256(files.get(mechanicalPaths[1])),source:{entries:2,bytes:100,inventorySha256:'d'.repeat(64)}}));
  return {base,baseTree:tree,head,tree,version:'1.0.1',files,nativeResultBytes,kosmosRecordBytes,kosmosReleaseId:7,
    impact:{impact:'patch',disposition:'compatible',rationale:'Explicit synthetic native review input.',contracts:['native generation']}};
}

test('automation review retains authenticated compact preparation before original owner dispatch',async()=>{
  const f=fixture(),candidate=preparedCandidate();f.pull.head.ref=proposalBranch;f.pull.body=proposalDescription(candidate).body;
  let calls=0;const compact={schema:'test-only compact authenticated preparation',head};
  f.preparation.readPreparation=async subject=>{calls++;assert.deepEqual(subject,{base,head});return {candidate};};
  f.preparation.compactPreparation=value=>{assert.equal(value.candidate,candidate);return compact;};
  const result=await f.observe();assert.equal(result.status,'ready');assert.equal(calls,1);
  assert.deepEqual(result.context.preparation,compact);
  f.setPrior({base,value:{status:'pending',envelope:{context:result.context},run:{id:40},artifact:{id:41},
    bytes:Buffer.from('original owner result'),workflow:{commit:base,sha256:'d'.repeat(64)}}});
  f.preparation.readPreparation=async()=>{throw Error('original frozen context must be reused');};
  const resumed=await f.observe();assert.equal(resumed.status,'ready');assert.deepEqual(resumed.context,result.context);
});

test('automation review cannot launch without original native preparation',async()=>{
  const f=fixture();f.pull.head.ref=proposalBranch;f.preparation.readPreparation=async()=>null;
  const result=await f.observe();assert.equal(result.status,'waiting');
  assert.match(result.observations[0].reason,/original native preparation is unavailable/);
});

test('native preparation subject mismatch blocks before owner dispatch',async()=>{
  const f=fixture(),candidate=preparedCandidate();f.pull.head.ref=proposalBranch;f.pull.body=proposalDescription(candidate).body;
  f.preparation.readPreparation=async()=>({candidate:{...candidate,tree:base}});
  const result=await f.observe();assert.equal(result.status,'waiting');assert.equal(result.observations[0].status,'blocked');
});

test('complete original context capacity is checked before owner invocation admission',async()=>{
  const f=fixture();f.responses.get(`/contents/docs/repository-local-releases.md?ref=${base}`).content=Buffer.alloc(4*1024*1024,97).toString('base64');
  const result=await f.observe();assert.equal(result.status,'waiting');assert.match(result.observations[0].reason,/exceed owner context capacity/);
});
