import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import test from 'node:test';
import {proposalBranch, proposalMessage, proposalCommitOid} from './protean-proposal.mjs';
import {metadata} from './test-support.mjs';
import {encodeRecord} from './encoding.mjs';
import {currentProteanSource, appActor, storedProteanCandidate, preparationPulls, promotionRequirements,
  originalProteanQualification, retireProteanProposal} from './release-observation.mjs';
import {sha256} from './encoding.mjs';

const base = 'a'.repeat(40), actor = {id: 42, login: 'protean-release[bot]'};
const blob = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
const file = bytes => ({type: 'file', encoding: 'base64', content: bytes.toString('base64'), sha: blob(bytes)});
async function fixture() {
  const tree = 'b'.repeat(40), baseManifest = Buffer.from('base manifest'), prepared = Buffer.from('prepared manifest');
  const files = new Map([['build.zig.zon', prepared], ['conformance/protean/dependencies.lock.json', Buffer.from('native lock')]]);
  const kosmosRecordBytes = encodeRecord(metadata('kosmos')), selected = metadata('kosmos');
  const nativeResultBytes = Buffer.from(JSON.stringify({schema: 'protean-refresh-result/v1', baseCommit: base, baseTree: tree,
    version: '1.0.1', kosmosRecordSha256: sha256(kosmosRecordBytes), horosRecordSha256: selected.dependencies[0].release.recordSha256,
    lockSha256: sha256(files.get('conformance/protean/dependencies.lock.json')), source: {entries: 2, bytes: 64, inventorySha256: 'c'.repeat(64)}}));
  const person = {name: actor.login, email: 'fixture@example.invalid', date: '2026-10-30T00:00:00Z'};
  const candidate = {base, baseTree: tree, tree: 'd'.repeat(40), version: '1.0.1', files, nativeResultBytes,
    kosmosReleaseId: 7, kosmosRecordBytes, author: person, committer: {...person},
    impact: {impact: 'patch', disposition: 'compatible', rationale: 'Synthetic recovered native source.', contracts: ['native generation']}};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  const native = {recover: async subject => {
    assert.equal(subject.head, candidate.head); assert.equal(subject.base, base); return candidate;
  }};
  const repository = {id: 1328996555, full_name: 'tkersey/protean', default_branch: 'main'};
  const values = new Map([
    ['', repository], ['/git/ref/heads/main', {ref: 'refs/heads/main', object: {type: 'commit', sha: base}}],
    [`/git/commits/${base}`, {sha: base, tree: {sha: tree}, committer: {date: person.date}}],
    [`/contents/build.zig.zon?ref=${base}`, file(baseManifest)],
    [`/git/commits/${candidate.head}`, {sha: candidate.head, tree: {sha: candidate.tree},
      parents: [{sha: base}], message: candidate.message, author: person, committer: {...person}}],
    [`/contents/build.zig.zon?ref=${candidate.head}`, file(prepared)],
  ]);
  const client = {async request({path, method = 'GET'}) {
    assert.equal(method, 'GET'); assert.ok(values.has(path), path); return {status: 200, body: structuredClone(values.get(path))};
  }};
  const run = {id: 17, head_sha: candidate.head, event: 'pull_request', repository: {id: 1328996555},
    head_repository: {id: 1328996555}, path: '.github/workflows/zig.yml', run_attempt: 1,
    status: 'completed', conclusion: 'failure'};
  const runs = [run];
  const command = async args => {
    const path = args[1];
    if (path === `repos/tkersey/protean/actions/workflows/zig.yml/runs?head_sha=${candidate.head}&event=pull_request&per_page=100&page=1`)
      return Buffer.from(JSON.stringify({workflow_runs: runs}));
    assert.equal(path, 'repos/tkersey/protean/actions/runs/17'); return Buffer.from(JSON.stringify(run));
  };
  const pull = {id: 52, number: 52, state: 'open', head: {ref: proposalBranch, sha: candidate.head, repo: {id: 1328996555}},
    base: {ref: 'main', repo: {id: 1328996555}}};
  let result = {status: 'absent'};
  const retire = retireProteanProposal({client, native, actor, command, readResult: async () => result});
  return {candidate, client, native, actor, values, tree, run, runs, command, pull,
    retire: () => retire({pull, knownHead: candidate.head}), setReview: value => {result = value;}};
}

test('stored candidate binds authenticated original native projection to the exact Git commit', async () => {
  const f = await fixture();
  assert.deepEqual(await currentProteanSource(f.client), {commit: base, tree: f.tree});
  assert.deepEqual(await storedProteanCandidate(f.candidate.head, f), f.candidate);
  f.values.get(`/git/commits/${f.candidate.head}`).message += 'changed';
  await assert.rejects(storedProteanCandidate(f.candidate.head, f), /strictly equal/);
});

test('pre-review retirement admits only the unique original terminal failed qualification', async () => {
  const f = await fixture(), result = await f.retire();
  assert.equal(result.epochClosed, true); assert.deepEqual(result.previousCandidate, f.candidate);
  assert.deepEqual(result.qualificationFailure, {runId: 17, conclusion: 'failure'});
});

for (const [name, mutate] of [
  ['success', f => {f.run.conclusion = 'success';}],
  ['pending', f => {f.run.status = 'in_progress'; f.run.conclusion = null;}],
  ['skipped', f => {f.run.conclusion = 'skipped';}],
  ['neutral', f => {f.run.conclusion = 'neutral';}],
  ['missing run', f => {f.runs.length = 0;}],
  ['duplicate run', f => {f.runs.push({...f.run, id: 18});}],
  ['retry', f => {f.run.run_attempt = 2;}],
  ['wrong repository', f => {f.run.head_repository.id++;}],
  ['different workflow', f => {f.run.path = '.github/workflows/other.yml';}],
  ['different source', f => {f.run.head_sha = base;}],
  ['manual run', f => {f.run.event = 'workflow_dispatch';}],
]) test(`unreviewed retirement refuses ${name}`, async () => {
  const f = await fixture(); mutate(f); await assert.rejects(f.retire());
});

test('an original authenticated closed owner epoch permits successor preparation', async () => {
  const f = await fixture();
  const envelope = {schema: 'repository-review-result/v1', context: {repository: 'tkersey/protean', base,
    head: f.candidate.head, tree: f.candidate.tree, pullNumber: 52}, status: 'blocked', reason: 'Owner closed the invalidated epoch.',
    epochClosed: true, turn: 1, previousSha256: null, stateSha256: null, retainedEvidence: null};
  f.setReview({status: 'blocked', bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 20}, artifact: {id: 21}});
  assert.equal((await f.retire()).review.runId, 20);
  envelope.epochClosed = false;
  f.setReview({status: 'blocked', bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 20}, artifact: {id: 21}});
  await assert.rejects(f.retire(), /did not close/);
});

for (const status of ['pending', 'running']) test(`owner ${status} is never replaced by a failed product run`, async () => {
  const f = await fixture(); f.setReview({status}); await assert.rejects(f.retire(), /still active/);
});

test('check requirements derive actual accepted definitions and retain effective human policy', async () => {
  const f = await fixture();
  for (const path of ['.github/workflows/repository-automation.yml', '.github/workflows/repository-review.yml',
    '.github/workflows/zig.yml', 'docs/repository-local-releases.md'])
    f.values.set(`/contents/${path}?ref=${base}`, file(Buffer.from(path)));
  const value = await promotionRequirements(base, 77, f.client);
  assert.equal(value.checks.qualification.appId, 15368); assert.equal(value.checks.review.appId, 77);
  assert.equal(value.control.sha256, sha256(Buffer.from(value.control.path)));
  assert.equal(value.reviews.requiredApprovingReviewCount, 0);
  assert.equal(value.acceptedRequirements.text, 'docs/repository-local-releases.md');
});

test('preparation pull observation rejects multiple open candidates', async () => {
  const f = await fixture();
  f.values.set(`/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}&per_page=100&page=1`, [f.pull]);
  assert.equal((await preparationPulls(f.client))[0].number, 52);
  f.values.get(`/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}&per_page=100&page=1`).push({...f.pull, id: 53, number: 53});
  await assert.rejects(preparationPulls(f.client), /multiple open/);
});

test('App actor identity is obtained from the exact installation login', async () => {
  const value = await appActor({repository: 'tkersey/protean', repositoryId: 1328996555, appId: 1, login: actor.login}, async args => {
    assert.equal(args[1], 'users/protean-release%5Bbot%5D'); return Buffer.from(JSON.stringify({...actor, type: 'Bot'}));
  });
  assert.deepEqual(value, actor);
});

import {frozenProteanCandidate} from './release-observation.mjs';
for(const status of ['pending','running','complete'])test(`original ${status} candidate stays frozen across later discovery`,async()=>{
  const f=await fixture();const candidate=await frozenProteanCandidate(f.pull,{commit:base},{readCandidate:async()=>f.candidate,
    readResult:async()=>({status}),qualification:async()=>assert.fail('active owner must remain authoritative')});
  assert.deepEqual(candidate,f.candidate);
});
test('only closed blocked owner or original terminal failed qualification permits fresh discovery',async()=>{
  const f=await fixture(),options={readCandidate:async()=>f.candidate,readResult:async()=>({status:'blocked',envelope:{epochClosed:true}})};
  assert.equal(await frozenProteanCandidate(f.pull,{commit:base},options),null);
  options.readResult=async()=>({status:'absent'});options.qualification=async()=>({status:'completed',conclusion:'failure'});
  assert.equal(await frozenProteanCandidate(f.pull,{commit:base},options),null);
  options.qualification=async()=>({status:'completed',conclusion:'success'});
  assert.deepEqual(await frozenProteanCandidate(f.pull,{commit:base},options),f.candidate);
  await assert.rejects(frozenProteanCandidate(f.pull,{commit:'f'.repeat(40)},options),/stale base/);
});

test('original prepared candidate stays frozen before its first PR is created',async()=>{
  const f=await fixture(),readPreparation=async value=>{assert.deepEqual(value,{base});return {candidate:f.candidate};};
  assert.deepEqual(await frozenProteanCandidate(null,{commit:base},{readPreparation}),f.candidate);
  assert.equal(await frozenProteanCandidate(null,{commit:base},{readPreparation:async()=>null}),null);
});
