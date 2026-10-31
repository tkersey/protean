import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {runProteanAutomation, automationOperations} from './protean-automation-runner.mjs';
import {encodeRecord,sha256} from './encoding.mjs';
import {metadata} from './test-support.mjs';
import {jobPermissions} from './app-token.mjs';
import {proposalBranch,nativeCandidateBinding,mechanicalPaths} from './protean-proposal.mjs';

const base = 'a'.repeat(40), tree = 'b'.repeat(40), head = 'c'.repeat(40);
const actor = {id: 42, login: 'protean-release[bot]'};
function fixture() {
  const original = Buffer.from('native fixture base manifest'), prepared = Buffer.from('native fixture prepared manifest');
  const candidate={base,head,tree,baseTree:tree,version:'1.0.1',kosmosReleaseId:1,kosmosRecordBytes:encodeRecord(metadata('kosmos')),files:new Map(mechanicalPaths.map(path=>[path,Buffer.from(prepared)]))};
  candidate.nativeResultBytes=encodeRecord({schema:'protean-refresh-result/v1',baseCommit:base,baseTree:tree,version:candidate.version,
    kosmosRecordSha256:sha256(candidate.kosmosRecordBytes),horosRecordSha256:metadata('kosmos').dependencies[0].release.recordSha256,
    source:{inventorySha256:'e'.repeat(64),entries:4,bytes:1024},lockSha256:sha256(candidate.files.get('conformance/protean/dependencies.lock.json'))});
  const originalBinding=nativeCandidateBinding(candidate);
  const identity = {repository: 'tkersey/protean', repositoryId: 1328996555, role: 'writer', appId: 9,
    permissions: {...jobPermissions.writer}, expiresAt: '2099-01-01T00:00:00Z'};
  const pull = {id: 52, number: 52, state: 'open', head: {ref: proposalBranch, sha: head, repo: {id: 1328996555}},
    base: {ref: 'main', sha: base, repo: {id: 1328996555}}};
  const state = {mode: 'promote', source: {commit: base, tree}, boundaryStatus: 'prepare', version: '1.0.1',
    run: {id: 17, status: 'completed', conclusion: 'success'}, review: 'success', calls: [], writes: [],
    pulls: [pull], pauseFailure: false, boundaryCalls: 0, onBoundary: null, modeAfterPropose: null};
  const client = {async request({path, method = 'GET'}) {
    assert.equal(method, 'GET'); state.calls.push(path);
    if (path === '/actions/variables/REPOSITORY_AUTOMATION')
      return state.controlsForbidden ? {status: 403} : {status: 200, body: {name: 'REPOSITORY_AUTOMATION', value: state.mode}};
    if (path.startsWith('/contents/build.zig.zon?ref=')) return {status: 200, body: {type: 'file', encoding: 'base64',
      content: original.toString('base64'), sha: createHash('sha1').update(`blob ${original.length}\0`).update(original).digest('hex')}};
    if (path.startsWith('/pulls?')) return {status: 200, body: structuredClone(state.pulls)};
    assert.equal(path, '/releases?per_page=100&page=1'); return {status: 200, body: []};
  }};
  const native = {read: bytes => {
    assert.ok(bytes.equals(original) || bytes.equals(prepared), 'not native admitted manifest bytes');
    return bytes.equals(original) ? '1.0.0' : '1.0.1';
  }, facts:()=>({version:'1.0.0'}),prepare: (bytes, version) => {
    assert.deepEqual(bytes, original); assert.equal(version, '1.0.1'); return Buffer.from(prepared);
  }};
  const dependencies = {client,
    actorReader: async value => {assert.equal(value, identity); state.calls.push('actor'); return actor;},
    sourceReader: async () => {state.calls.push('source'); return {...state.source};},
    pause: async value => {assert.equal(value.actor, actor); state.calls.push('pause'); if (state.pauseFailure) throw Error('cancellation unavailable'); return {mode: state.mode, results: [], pending: []};},
    reportReview: async value => {state.calls.push('review'); assert.equal(value.appId, 9); return {status: 'reported', conclusion: state.review};},
    reportStatus: async value => {state.calls.push('comment'); assert.equal(value.appId, 9); return {status: 'reported'};},
    operations: () => ({
      recover: async () => null,
      freeze:async()=>null,
      plan: async source => {
        state.boundaryCalls++; state.onBoundary?.(state.boundaryCalls); state.calls.push('boundary');
        return {status:state.boundaryStatus,decision:{version:state.version,kosmosRecordSha256:'e'.repeat(64)}};
      },
      preparation:async value=>value.version==='1.0.1'?{candidate,binding:originalBinding,decisionBytes:Buffer.from('decision')}:null,
      retire: async () => {throw Error('retirement belongs to separately tested original evidence adapter');},
      resume: async () => {throw Error('resume belongs to separately tested owner command adapter');},
      propose: async value => {
        for (const key of ['admitCandidate', 'admitRetirement', 'admitResume']) assert.equal(typeof value[key], 'function');
        await value.admitCandidate({candidate, baseManifest: original}); state.writes.push('proposal');
        if (state.modeAfterPropose) state.mode = state.modeAfterPropose;
        return {status: 'proposal open', number: 52, head};
      },
      qualification: async value => {assert.equal(value, head); state.calls.push('qualification'); return state.run;},
      requirements: async (value, appId) => {assert.equal(value, base); assert.equal(appId, 9); return {fixture: 'actual required definitions'};},
      promotion: value => {
        assert.equal(value.qualificationRunId, 17); assert.deepEqual(value.expected, {fixture: 'actual required definitions'});
        return async () => {await value.admitCandidate({candidate}); state.calls.push('promotion admitted');};
      },
      promote: async value => {
        assert.equal(value.number, 52); await value.admitPromotion({candidate, pull});
        state.writes.push('promotion'); return {status: 'promotion requested', number: 52, head};
      },
    }),
  };
  const options = {controlCommit: base, identity, native};
  return {state, candidate, options, dependencies, run: () => runProteanAutomation(options, dependencies)};
}

test('operational runner binds native preparation and promotion to fresh publication decisions', async () => {
  const f = fixture(), value = await f.run();
  assert.equal(value.status, 'promotion requested'); assert.deepEqual(f.state.writes, ['proposal', 'promotion']);
  assert.equal(f.state.calls[1], 'pause'); assert.equal(f.state.boundaryCalls, 3);
  assert.ok(f.state.calls.includes('promotion admitted'));
});

test('off still pauses first and reports normal original-review checks without proposal or comment writes', async () => {
  const f = fixture(); f.state.mode = 'off'; f.candidate.nativeResultBytes = Buffer.from('unknown branch edit');
  const value = await f.run();
  assert.equal(value.status, 'disabled'); assert.equal(value.pauseVerified, true);
  assert.ok(f.state.calls.indexOf('pause') < f.state.calls.indexOf('source'));
  assert.ok(f.state.calls.includes('review')); assert.ok(!f.state.calls.includes('comment'));
  assert.deepEqual(f.state.writes, []); assert.equal(f.state.boundaryCalls, 0);
});

test('missing App remains read-only and cannot acknowledge cancellation', async () => {
  const f = fixture(); f.options.identity = null; f.state.mode = 'off'; f.state.controlsForbidden = true;
  const value = await f.run(); assert.equal(value.status, 'disabled'); assert.equal(value.pauseVerified, false);
  assert.match(value.reason, /cancellation is unverified/);
  assert.ok(f.state.calls.includes('/releases?per_page=100&page=1'));
  assert.ok(!f.state.calls.some(value => ['actor', 'pause', 'review', 'comment'].includes(value)));
  f.options.configuredMode = 'propose'; assert.equal((await f.run()).status, 'blocked');
  assert.ok(!f.state.calls.includes('/actions/variables/REPOSITORY_AUTOMATION'));
  assert.deepEqual(f.state.writes, []);
});

test('unconfirmed cancellation blocks before manifest or candidate observation', async () => {
  const f = fixture(); f.state.pauseFailure = true;
  const value = await f.run(); assert.equal(value.status, 'blocked'); assert.equal(value.pauseVerified, false);
  assert.ok(!f.state.calls.includes('source')); assert.deepEqual(f.state.writes, []);
});

test('propose mode prepares the ordinary PR but never promotes', async () => {
  const f = fixture(); f.state.mode = 'propose';
  assert.equal((await f.run()).status, 'proposal open'); assert.deepEqual(f.state.writes, ['proposal']);
  assert.ok(!f.state.calls.includes('qualification'));
});

test('control withdrawal after preparation cancels owned auto-merge before stopping', async () => {
  const f = fixture(); f.state.modeAfterPropose = 'off';
  const value = await f.run(); assert.equal(value.mode, 'off');
  assert.equal(f.state.calls.filter(value => value === 'pause').length, 2);
  assert.deepEqual(f.state.writes, ['proposal']);
});

for (const [name, change] of [
  ['unstarted original qualification', f => {f.state.run = null;}],
  ['pending qualification', f => {f.state.run.status = 'in_progress'; f.state.run.conclusion = null;}],
  ['failed qualification', f => {f.state.run.conclusion = 'failure';}],
  ['pending original owner', f => {f.state.review = undefined;}],
  ['blocked original owner', f => {f.state.review = 'failure';}],
]) test(`runner retains ${name} without promotion or retry`, async () => {
  const f = fixture(); change(f); await f.run(); assert.deepEqual(f.state.writes, ['proposal']);
  assert.ok(!f.state.calls.includes('promotion admitted'));
});

for (const [name, change] of [
  ['changed decision', f => {f.state.onBoundary = call => {if (call === 2) f.state.boundaryStatus = 'ready';};}],
  ['changed version', f => {f.state.onBoundary = call => {if (call === 2) f.state.version = '1.0.2';};}],
  ['changed native bytes', f => {f.candidate.nativeResultBytes = Buffer.from('different native output');}],
]) test(`native source admission rejects ${name} before proposal writes`, async () => {
  const f = fixture(); change(f); assert.equal((await f.run()).status, 'held'); assert.deepEqual(f.state.writes, []);
});

test('stale accepted control does not prepare or promote source', async () => {
  const f = fixture(); f.options.controlCommit = 'f'.repeat(40);
  assert.equal((await f.run()).status, 'held'); assert.deepEqual(f.state.writes, []); assert.equal(f.state.boundaryCalls, 0);
});

for (const key of ['role', 'permissions', 'expiresAt']) test(`writer refuses invalid ${key}`, async () => {
  const f = fixture(); f.options.identity[key] = key === 'role' ? 'observer' : key === 'permissions' ? {} : '2000-01-01T00:00:00Z';
  await assert.rejects(f.run()); assert.deepEqual(f.state.writes, []);
});

test('production operations provide concrete owner, native, qualification and promotion procedures', () => {
  const f = fixture(); const value = automationOperations({client: f.dependencies.client, command: async () => assert.fail('unexpected API'),
    native: f.options.native, actor});
  assert.deepEqual(Object.keys(value).sort(), ['recover', 'plan', 'freeze', 'preparation', 'retire', 'orphan', 'resume', 'propose', 'promote',
    'qualification', 'requirements', 'promotion'].sort());
  assert.ok(Object.values(value).every(value => typeof value === 'function'));
});

test('workflow compiles only trusted native code before creating any App credentials', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/repository-automation.yml', import.meta.url), 'utf8');
  assert.ok(workflow.indexOf('zig build-exe tools/native/dependencies.zig') < workflow.indexOf('REPOSITORY_APP_PRIVATE_KEY'));
  assert.match(workflow, /persist-credentials: false/); assert.match(workflow, /cancel-in-progress: false/);
  assert.match(workflow, /create tkersey\/protean writer/); assert.match(workflow, /app-token.mjs revoke/);
  assert.ok(!workflow.includes('pull_request_target')); assert.ok(!workflow.includes('pull_request.head.sha'));
});

test('active original candidate freezes selection and artifact head through proposal and promotion',async()=>{
  const f=fixture(),make=f.dependencies.operations;let selections=0,reads=0;
  f.dependencies.operations=()=>{const value=make(),plan=value.plan,read=value.preparation;return {...value,
    freeze:async(pull,source)=>{assert.equal(pull.head.sha,head);assert.equal(source.commit,base);return f.candidate;},
    plan:async(source,frozen)=>{assert.equal(frozen,f.candidate);selections++;return plan(source);},
    preparation:async selection=>{assert.equal(selection.head,head);reads++;return read(selection);}};};
  assert.equal((await f.run()).status,'promotion requested');assert.equal(selections,3);assert.equal(reads,3);
});
