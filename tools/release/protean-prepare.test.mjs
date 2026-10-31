import assert from 'node:assert/strict';
import test from 'node:test';
import {attachCompatibility} from './compatibility-test-support.mjs';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {prepareProtean, readProteanSource, preparationEnvironment, nativeInvocation} from './protean-prepare.mjs';
import {mechanicalPaths, nativeCandidateBinding} from './protean-proposal.mjs';
import {metadata} from './test-support.mjs';
import {encodeRecord, sha256} from './encoding.mjs';

const executable = process.execPath, executableSha256 = sha256(readFileSync(executable));
function fixture(t, selectedPublished = false) {
  const root = mkdtempSync(join(tmpdir(), 'protean-prepare-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const env = {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_AUTHOR_DATE: '2026-01-01T00:00:00Z',
    GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_DATE: '2026-01-01T00:00:00Z'};
  const git = (repo, args) => execFileSync('/usr/bin/git', ['-C', repo, ...args], {encoding: 'utf8', env}).trimEnd();
  const repositories = new Map(['protean', 'kosmos', 'horos'].map(name => [`tkersey/${name}`, join(root, name)]));
  const write = (directory, path, bytes) => {mkdirSync(dirname(join(directory, path)), {recursive: true}); writeFileSync(join(directory, path), bytes);};
  for (const directory of repositories.values()) {
    mkdirSync(directory); git(directory, ['init', '--quiet']); write(directory, 'README.md', 'initial\n');
    git(directory, ['add', '.']); git(directory, ['commit', '--quiet', '-m', 'Initial']);
  }
  const repo = repositories.get('tkersey/protean'), upstream = repositories.get('tkersey/kosmos');
  let selected = git(upstream, ['rev-parse', 'HEAD']);
  write(upstream, 'README.md', 'successor\n'); git(upstream, ['add', '.']); git(upstream, ['commit', '--quiet', '-m', 'Successor']);
  let head = git(upstream, ['rev-parse', 'HEAD']); const tree = git(upstream, ['rev-parse', 'HEAD^{tree}']);
  if (selectedPublished) selected = head;
  if(selectedPublished==='equivalent'){git(upstream,['commit','--quiet','--allow-empty','-m','Qualified squash counterpart']);head=git(upstream,['rev-parse','HEAD']);}
  const sourcePaths = [...mechanicalPaths, 'conformance/protean/native-dependencies.lock.json', 'README.md', 'notes/unicode ü\nname.txt'];
  for (const path of sourcePaths) write(repo, path, `base ${path}\n`);
  write(repo, mechanicalPaths[1], JSON.stringify({world: {commit: selected, gitTree: git(upstream, ['rev-parse', `${selected}^{tree}`]), version: selectedPublished ? '1.0.1' : '1.0.0'}}));
  git(repo, ['add', '.']); git(repo, ['commit', '--quiet', '-m', 'Fixture base']);
  const base = git(repo, ['rev-parse', 'HEAD']), baseTree = git(repo, ['rev-parse', 'HEAD^{tree}']);
  const records = new Map();
  const archive = Buffer.from('explicit synthetic native transport fixture');
  for (const name of ['horos', 'kosmos']) {
    const directory = repositories.get(`tkersey/${name}`), record = metadata(name);
    record.source.commit = git(directory, ['rev-parse', 'HEAD']); record.source.tree = git(directory, ['rev-parse', 'HEAD^{tree}']);
    record.source.version = '1.0.1'; record.source.packageIdentity = `${name}-1.0.1-${'a'.repeat(44)}`; record.tag = 'v1.0.1';
    record.qualification.run.commit = record.source.commit; record.qualification.run.tree = record.source.tree;
    record.review.landing.commit = record.source.commit; record.review.landing.tree = record.source.tree;
    record.artifacts[0].sha256 = sha256(archive); record.artifacts[0].bytes = archive.length;
    if (name === 'kosmos') {
      const horos = records.get('tkersey/horos');
      record.dependencies = [{repository: horos.repository, source: horos.source,
        release: {id: 6, tag: horos.tag, recordSha256: sha256(encodeRecord(horos))}}];
    }
    records.set(`tkersey/${name}`, record);
  }
  const record = records.get('tkersey/kosmos');
  const compatibilityPayloads=attachCompatibility(record,selected);
  const state = {calls: [], admissions: [], selected, mutate: null, sourceChange: false, badManifest: false,
    extraSource: false, missingOutput: false, wrongMode: false, badArchive: false, forgedDerived: false};
  const options = {
    reader: {async api(path){const commit=path.slice('git/commits/'.length);return {sha:commit,tree:{sha:git(upstream,['rev-parse',`${commit}^{tree}`])}};},async verifyRepository() {}, async releases() {return [{id: 7, assets: [{name: 'release.json'}]}];},
      async forward(a,b) {try {git(upstream,['merge-base','--is-ancestor',a,b]);return true;}catch{return false;}}},
    async admitPublishedRelease({repository,releaseId,outputDirectory}) {
      state.admissions.push({repository, releaseId}); mkdirSync(outputDirectory);
      const original = structuredClone(records.get(repository));
      if (repository === 'tkersey/horos' && state.forgedDerived) original.source.version = '1.0.2';
      const bytes = encodeRecord(original);
      writeFileSync(join(outputDirectory,'release.json'),bytes);
      writeFileSync(join(outputDirectory,'source.tar'),state.badArchive ? 'corrupt' : archive);
      return {id:releaseId,record:original,recordSha256:sha256(bytes),
        payloads:new Map([['source.tar',archive],...(repository==='tkersey/kosmos'?compatibilityPayloads:[])]),paths:new Map([['release.json',join(outputDirectory,'release.json')],['source.tar',join(outputDirectory,'source.tar')]]),
        admissionVerification:Buffer.from('test-only authentication')};
    },
    async cloneRepository({repository,commit,destination}) {
      execFileSync('/usr/bin/git',['clone','--quiet','--no-hardlinks',repositories.get(repository),destination],{env});
      git(destination,['checkout','--quiet','--detach',commit]);
    },
    async runNative({args}) {
      state.calls.push(args[0]);
      if(args[0] === 'source-manifest') return {stdout:encodeRecord({
        manifest:{sha256:state.badManifest?'f'.repeat(64):sha256(readFileSync(join(args[1],'build.zig.zon'))),version:'1.0.0',minimumCompiler:'0.17.0'},
        lockSha256:sha256(readFileSync(join(args[1],mechanicalPaths[1]))),
        nativeLockSha256:sha256(readFileSync(join(args[1],'conformance/protean/native-dependencies.lock.json'))),
        dependencies:{kosmos:{commit:state.selected,tree:git(upstream,['rev-parse',`${state.selected}^{tree}`])}}}),stderr:Buffer.alloc(0)};
      if(args[0] === 'coherence')return {stdout:Buffer.alloc(0),stderr:Buffer.alloc(0)};
      assert.equal(args[0],'refresh');const input=JSON.parse(readFileSync(args[2])),output=args[3];
      assert.equal(Object.hasOwn(input,'horos'),false);
      for(const path of sourcePaths)write(join(output,'source'),path,readFileSync(join(args[1],path)));
      for(const path of mechanicalPaths)write(join(output,'source'),path,`prepared ${path}\n`);
      const result={schema:'protean-refresh-result/v1',baseCommit:base,baseTree,version:input.version,
        kosmosRecordSha256:sha256(encodeRecord(record)),horosRecordSha256:record.dependencies[0].release.recordSha256,
        lockSha256:sha256(readFileSync(join(output,'source',mechanicalPaths[1]))),
        source:{entries:sourcePaths.length,bytes:256,inventorySha256:'e'.repeat(64)}};
      state.mutate?.(result);write(output,'result.json',Buffer.from(JSON.stringify(result)));
      if(state.extraSource)write(join(output,'source'),'README.md','forged\n');
      if(state.sourceChange)write(args[1],'README.md','changed base\n');
      if(state.missingOutput)rmSync(join(output,'source',mechanicalPaths[1]));
      if(state.wrongMode)chmodSync(join(output,'source',mechanicalPaths[1]),0o755);
      return {stdout:Buffer.alloc(0),stderr:Buffer.alloc(0)};
    },
  };
  const decision=()=>({base,baseTree,version:'1.0.1',kosmosReleaseId:7,kosmosRecordSha256:sha256(encodeRecord(record)),
    impact:{impact:'patch',disposition:'compatible',rationale:'Explicit test-only approved native dependency refresh.',contracts:['native dependency']}});
  let counter=0;
  const input=()=>({base,baseTree,tool:{path:executable,sha256:executableSha256,sourceCommit:base},
    compiler:{path:executable,sha256:executableSha256,sourceCommit:base},outputDirectory:join(root,`output-${counter++}`),
    versionDecision:decision(),admitVersionDecision:async({decisionBytes})=>sha256(decisionBytes),author:{name:'Protean Automation',email:'fixture@example.invalid'}});
  return {root,state,record,head,selected,base,baseTree,options,input,decision,git,upstream,compatibilityPayloads,
    prepare:(changes={},overrides={})=>prepareProtean({...input(),...changes},{...options,...overrides})};
}

test('prepares one Kosmos selection and derives its exact Horos with deterministic Git source',async t=>{
  const f=fixture(t),first=await f.prepare(),second=await f.prepare();
  assert.equal(first.status,'prepared');assert.equal(first.candidate.head,second.candidate.head);
  assert.deepEqual(first.candidateBytes,second.candidateBytes);
  assert.deepEqual([...first.candidate.files.keys()],mechanicalPaths);
  assert.equal(first.candidate.author.date,'2026-01-01T00:00:00Z');
  assert.deepEqual(JSON.parse(first.proofBytes).binding,nativeCandidateBinding(first.candidate));
  assert.deepEqual(f.state.calls,['source-manifest','refresh','coherence','source-manifest','refresh','coherence']);
  assert.deepEqual(f.state.admissions,[{repository:'tkersey/kosmos',releaseId:7},{repository:'tkersey/horos',releaseId:6},
    {repository:'tkersey/kosmos',releaseId:7},{repository:'tkersey/horos',releaseId:6}]);
});

test('no admissible successor leaves the current source unchanged without a decision or generation',async t=>{
  const f=fixture(t);
  f.options.reader.releases = async () => [];
  const result=await f.prepare({versionDecision:undefined});
  assert.equal(result.status,'unchanged');assert.deepEqual(f.state.calls,['source-manifest']);
});

for(const [name,change] of [
  ['upstream breaking change',f=>{f.record.compatibility.disposition='breaking';}],
  ['upstream major migration',f=>{f.record.compatibility.impact='major';}],
  ['upstream version downgrade',f=>{f.record.source.version='0.9.9';f.record.source.packageIdentity=`kosmos-0.9.9-${'a'.repeat(44)}`;f.record.tag='v0.9.9';}],
  ['native manifest mismatch',f=>{f.state.badManifest=true;}],
  ['admitted source corruption',f=>{f.state.badArchive=true;}],
  ['different derived Horos publication',f=>{f.state.forgedDerived=true;}],
])test(`rejects ${name} before native generation`,async t=>{
  const f=fixture(t);change(f);await assert.rejects(f.prepare());assert.deepEqual(f.state.calls,['source-manifest']);
});

for(const [name,change] of [
  ['unapproved output',f=>{f.state.extraSource=true;}],
  ['changed source base',f=>{f.state.sourceChange=true;}],
  ['missing generated file',f=>{f.state.missingOutput=true;}],
  ['changed executable mode',f=>{f.state.wrongMode=true;}],
  ['wrong selected record',f=>{f.state.mutate=value=>{value.kosmosRecordSha256='f'.repeat(64);};}],
  ['wrong derived Horos record',f=>{f.state.mutate=value=>{value.horosRecordSha256='f'.repeat(64);};}],
  ['wrong generated lock',f=>{f.state.mutate=value=>{value.lockSha256='f'.repeat(64);};}],
])test(`rejects ${name} without candidate export`,async t=>{
  const f=fixture(t);change(f);await assert.rejects(f.prepare());
});

test('tool source and version authority bind exact source and selected Kosmos publication',async t=>{
  const f=fixture(t),input=f.input();
  await assert.rejects(f.prepare({tool:{...input.tool,sourceCommit:'f'.repeat(40)}}),/accepted source base/);
  await assert.rejects(f.prepare({admitVersionDecision:async()=>undefined}),/not authenticated/);
  await assert.rejects(f.prepare({versionDecision:{...f.decision(),base:'f'.repeat(40)}}));
  await assert.rejects(f.prepare({versionDecision:{...f.decision(),kosmosRecordSha256:'f'.repeat(64)}}));
  await assert.rejects(f.prepare({versionDecision:{...f.decision(),version:'0.9.9'}}),/own version downgrade/);
});

test('native process environment and platform sandbox exclude credentials and host home',()=>{
  const root='/private/tmp/isolated',env=preparationEnvironment(root);
  for(const key of ['GH_TOKEN','GITHUB_TOKEN','SSH_AUTH_SOCK','AWS_SECRET_ACCESS_KEY'])assert.equal(env[key],undefined);
  assert.equal(env.HOME,`${root}/home`);assert.equal(env.GIT_CONFIG_GLOBAL,'/dev/null');
  const input={tool:{path:'/accepted/native'},compiler:{path:'/compiler/bin/zig'},root,args:['source-manifest'],platform:'darwin'};
  const mac=nativeInvocation(input);assert.equal(mac.file,'/usr/bin/sandbox-exec');
  assert.match(mac.args[1],/\(deny default\)/);assert.ok(!mac.args[1].includes('allow network'));
  const linux=nativeInvocation({...input,platform:'linux'});assert.equal(linux.file,'/usr/bin/bwrap');
  assert.ok(linux.args.includes('--unshare-all'));assert.ok(!linux.args.includes(process.env.HOME));
});

test('exact current Kosmos can support an independently approved own version change',async t=>{
  const f=fixture(t,true); f.record.compatibility.impact='major';
  const result=await f.prepare({versionDecision:async input=>{
    assert.equal(input.upstream.changed,false);assert.equal(input.currentVersion,'1.0.0');return f.decision();
  }});
  assert.equal(result.status,'prepared');assert.equal(result.candidate.kosmosReleaseId,7);
  assert.equal(result.candidate.version,'1.0.1');
});

test('exact current publication without a version decision is unchanged',async t=>{
  const f=fixture(t,true),result=await f.prepare({versionDecision:undefined});
  assert.equal(result.status,'unchanged');assert.deepEqual(f.state.calls,['source-manifest']);
});

test('read-only source facts bind every original manifest and lock before native generation',async t=>{
  const f=fixture(t),input=f.input();
  const result=await readProteanSource({source:{commit:f.base,tree:f.baseTree},controlCommit:f.base,
    tool:input.tool,compiler:input.compiler,outputDirectory:input.outputDirectory},f.options);
  assert.equal(result.facts.manifest.version,'1.0.0');assert.equal(result.facts.manifest.sha256,sha256(result.manifestBytes));
  assert.deepEqual(f.state.calls,['source-manifest']);
});

test('source equivalent publication without an independent decision does not normalize commits',async t=>{
  const f=fixture(t,'equivalent'),result=await f.prepare({versionDecision:undefined});
  assert.equal(result.status,'unchanged');assert.deepEqual(f.state.calls,['source-manifest']);
});
test('source equivalent publication adoption regenerates complete native binding under an independent decision',async t=>{
  const f=fixture(t,'equivalent'),result=await f.prepare();
  assert.equal(result.status,'prepared');assert.deepEqual(f.state.calls,['source-manifest','refresh','coherence']);
  assert.notEqual(f.selected,f.head);assert.equal(result.candidate.kosmosReleaseId,7);
  assert.equal(nativeCandidateBinding(result.candidate).kosmosRecordSha256,sha256(encodeRecord(f.record)));
});
test('source equivalent publication still rejects a version downgrade',async t=>{
  const f=fixture(t,'equivalent');f.record.source.version='0.9.0';f.record.source.packageIdentity=`kosmos-0.9.0-${'a'.repeat(44)}`;f.record.tag='v0.9.0';
  await assert.rejects(f.prepare(),/downgrade/);assert.deepEqual(f.state.calls,['source-manifest']);
});

test('native generation consumes exactly the approved Kosmos and derived Horos despite newer releases',async t=>{
  const f=fixture(t);f.options.reader.releases=async()=>assert.fail('frozen input must not rediscover latest publication');
  const result=await f.prepare();assert.equal(result.candidate.kosmosReleaseId,7);
  assert.deepEqual(f.state.admissions,[{repository:'tkersey/kosmos',releaseId:7},{repository:'tkersey/horos',releaseId:6}]);
  assert.deepEqual(f.state.calls,['source-manifest','refresh','coherence']);
});
test('native generation rejects changed bytes under the frozen release identity before refresh',async t=>{
  const f=fixture(t),decision=f.decision();decision.kosmosRecordSha256='f'.repeat(64);
  await assert.rejects(f.prepare({versionDecision:decision}),/frozen upstream record changed/);
  assert.deepEqual(f.state.calls,['source-manifest']);
});

test('native preparation blocks a frozen patch whose predecessor crossed a breaking boundary',async t=>{
  const f=fixture(t),previous=structuredClone(f.record),name=previous.repository.name.split('/')[1];
  previous.source.version='9.0.0';previous.source.packageIdentity=`${name}-9.0.0-${'a'.repeat(44)}`;previous.tag='v9.0.0';
  previous.compatibility.impact='major';previous.compatibility.disposition='breaking';
  const previousPayloads=attachCompatibility(previous,f.selected),previousBytes=encodeRecord(previous);
  writeFileSync(join(f.upstream,'README.md'),'compatible patch after breaking publication\n');
  f.git(f.upstream,['add','.']);f.git(f.upstream,['commit','--quiet','-m','Compatible patch']);
  Object.assign(f.record.source,{commit:f.git(f.upstream,['rev-parse','HEAD']),tree:f.git(f.upstream,['rev-parse','HEAD^{tree}']),
    version:'9.0.1',packageIdentity:`${name}-9.0.1-${'a'.repeat(44)}`});f.record.tag='v9.0.1';
  Object.assign(f.record.qualification.run,{commit:f.record.source.commit,tree:f.record.source.tree});
  Object.assign(f.record.review.landing,{commit:f.record.source.commit,tree:f.record.source.tree});
  const payloads=attachCompatibility(f.record,previous.source.commit,{baseline:{releaseId:6,recordSha256:sha256(previousBytes),source:previous.source}});
  for(const [name,bytes] of payloads)f.compatibilityPayloads.set(name,bytes);
  const admit=f.options.admitPublishedRelease;
  f.options.admitPublishedRelease=async request=>{
    const value=await admit(request);
    if(request.releaseId!==6)return value;
    writeFileSync(value.paths.get('release.json'),previousBytes);
    return {...value,id:6,record:previous,recordSha256:sha256(previousBytes),payloads:new Map([...value.payloads,...previousPayloads])};
  };
  await assert.rejects(f.prepare(),/breaking migration/);
  assert.deepEqual(f.state.calls,['source-manifest']);
});
