import assert from 'node:assert/strict';
import test from 'node:test';
import {admitProteanQualification, validateProteanJobs, validateProteanPayloads} from './protean-qualification.mjs';
import {proteanFixture} from './protean-test-support.mjs';

test('original complete Protean qualification retains final consumer-tested source and native payloads', async () => {
  const f = proteanFixture(), result = await admitProteanQualification({runId: 17, commit: f.commit, tree: f.tree}, f.command);
  assert.equal(result.jobs.length, 13); assert.equal(result.payloads.size, 7);
  for (const [name, bytes] of f.payloads) assert.deepEqual(result.payloads.get(name), bytes);
});

for (const [name, mutate] of [
  ['missing lane', f => {f.jobs.splice(2, 1);}],
  ['duplicate lane', f => {f.jobs.push({...f.jobs[0], id: 200});}],
  ['failed TigerStyle', f => {f.jobs[0].conclusion = 'failure';}],
  ['skipped lane', f => {f.jobs[1].conclusion = 'skipped';}],
  ['neutral aggregate', f => {f.jobs.at(-1).conclusion = 'neutral';}],
  ['second attempt', f => {f.run.run_attempt = 2;}],
  ['retry job', f => {f.jobs[1].run_attempt = 2;}],
  ['wrong native platform', f => {f.jobs[1].labels = ['macos-15'];}],
  ['original trigger budget overrun', f => {f.run.created_at = '2026-10-29T23:57:59Z';}],
  ['missing source consumption step', f => {f.jobs.at(-2).steps.splice(1, 1);}],
  ['failed source retention', f => {f.jobs.at(-2).steps[2].conclusion = 'failure';}],
  ['skipped final native archive', f => {f.jobs.find(job => job.name.includes('/ native /')).steps.at(-1).conclusion = 'skipped';}],
  ['required step outside job clock', f => {f.jobs[1].steps[0].started_at = '2026-10-30T00:00:00Z';}],
  ['aggregate before required work', f => {f.jobs.at(-1).started_at = '2026-10-30T00:06:00Z'; f.jobs.at(-1).steps[0].started_at = '2026-10-30T00:06:00Z';}],
]) test(`full qualification rejects ${name}`, () => {
  const f = proteanFixture(); mutate(f); assert.throws(() => validateProteanJobs(f.jobs, f.run));
});

test('unselected retention diagnostic carries no qualification credit', () => {
  const f = proteanFixture(); f.jobs.push({id: 999, name: 'Historical executable retention diagnostic', run_id: 17,
    run_attempt: 1, head_sha: f.commit, status: 'completed', conclusion: 'skipped'});
  validateProteanJobs(f.jobs, f.run);
  f.jobs.at(-1).conclusion = 'success'; assert.throws(() => validateProteanJobs(f.jobs, f.run));
});

for (const [name, mutate] of [
  ['source bytes', f => {f.payloads.set('source.tar', Buffer.from('corrupt'));}],
  ['native archive bytes', f => {f.payloads.set(f.packageInput.archiveName, Buffer.from('corrupt'));}],
  ['wrong package', f => {f.downstream.package = 'protean-99.0.0-wrong';}],
  ['placement different binary', f => {
    const value = JSON.parse(f.payloads.get('native-placement-identity.json')); value.artifact_sha256 = 'e'.repeat(64);
    f.payloads.set('native-placement-identity.json', Buffer.from(JSON.stringify(value)));
  }],
  ['downstream changed lock', f => {f.downstream.identity = structuredClone(f.downstream.identity); f.downstream.identity.dependencies.dependency_lock_sha256 = 'e'.repeat(64);}],
  ['source receipt not consumed', f => {f.downstream.source.receiptSha256 = 'e'.repeat(64);}],
  ['interpreter-based acquisition', f => {f.downstream.node_free_acquisition_build_install = false;}],
  ['missing installed execution', f => {delete f.downstream.installed_execution;}],
]) test(`final payload admission rejects ${name}`, () => {
  const f = proteanFixture(); mutate(f); f.payloads.set('downstream-identity.json', Buffer.from(JSON.stringify(f.downstream)));
  assert.throws(() => validateProteanPayloads(f.payloads, f));
});

for (const [name, mutate] of [
  ['manual diagnostic', f => {f.run.event = 'workflow_dispatch';}],
  ['changed subject', f => {f.run.head_sha = 'e'.repeat(40);}],
  ['duplicate original run', f => {f.replies.get(`repos/tkersey/protean/actions/workflows/zig.yml/runs?head_sha=${f.commit}&event=push&per_page=100&page=1`).workflow_runs.push({...f.run, id: 18});}],
  ['expired original payload', f => {f.artifacts[0].expired = true;}],
  ['wrong producer run', f => {f.artifacts[0].workflow_run.id++;}],
  ['corrupt original payload', f => {f.replies.set('repos/tkersey/protean/actions/artifacts/80/zip', Buffer.from('corrupt'));}],
]) test(`remote qualification admission rejects ${name}`, async () => {
  const f = proteanFixture(); mutate(f);
  await assert.rejects(admitProteanQualification({runId: 17, commit: f.commit, tree: f.tree}, f.command));
});
