import assert from 'node:assert/strict';
import test from 'node:test';
import {selectPublishedSource,admitFrozenSource} from './protean-upstream-selection.mjs';
import {discoverKosmosRelease} from './protean-preparation-plan.mjs';
import {metadata} from './test-support.mjs';
import {attachCompatibility} from './compatibility-test-support.mjs';
import {encodeRecord,sha256} from './encoding.mjs';

const oid=n=>n.toString(16).padStart(40,'0');
function fixture(){
  const trees=new Map(Array.from({length:8},(_,i)=>[oid(i),oid(i+20)])),admissions=[];
  const releases=new Map(),selected={commit:oid(0),tree:trees.get(oid(0)),version:'8.0.0',packageIdentity:`kosmos-8.0.0-${'a'.repeat(44)}`};
  const reader={async verifyRepository(){},async api(path){const commit=path.slice('git/commits/'.length);assert.ok(trees.has(commit));return {sha:commit,tree:{sha:trees.get(commit)}};},
    async forward(base,head){return Number.parseInt(base,16)<=Number.parseInt(head,16);},
    async releases(){return [...releases.values()].reverse().map(value=>({id:value.id,assets:[{name:'release.json'}]}));}};
  const publish=(n,{version=`8.0.${n}`,impact='patch',disposition='compatible',baseline=null,base=baseline?.source.commit??selected.commit,changes}={})=>{
    const record=metadata('kosmos');record.source.commit=oid(n);record.source.tree=trees.get(oid(n));record.source.version=version;
    record.source.packageIdentity=`kosmos-${version}-${'a'.repeat(44)}`;record.compatibility.impact=impact;record.compatibility.disposition=disposition;
    const payloads=attachCompatibility(record,base,{baseline:baseline?{releaseId:baseline.id,recordSha256:baseline.recordSha256,source:baseline.source}:null,changes});
    const value={id:n,record,source:record.source,payloads,recordSha256:sha256(encodeRecord(record))};releases.set(n,value);return value;
  };
  const admit=async id=>{admissions.push(id);assert.ok(releases.has(id),'missing original publication');return releases.get(id);};
  const interval=(base,head,impact='patch',disposition='compatible')=>({base:oid(base),head:oid(head),pull:head,
    subject:{base:oid(base),head:oid(head),tree:trees.get(oid(head))},landedCommits:[oid(head)],
    review:{runId:head,artifactId:head,sha256:'a'.repeat(64)},versionOnly:false,
    declaration:{impact,disposition,rationale:'Synthetic reviewed interval.',contracts:['fixture API']}});
  const discover=()=>selectPublishedSource(reader,selected,[...releases.values()].reverse());
  const frozen=id=>admitFrozenSource(reader,selected,id,admit);
  return {trees,releases,selected,reader,publish,admit,admissions,interval,discover,frozen};
}

for(const route of ['discover','frozen']){
  test(`${route} rejects a patch after a skipped breaking release`,async()=>{
    const f=fixture(),major=f.publish(1,{version:'9.0.0',impact:'major',disposition:'breaking'});
    f.publish(2,{version:'9.0.1',baseline:major});
    await assert.rejects(route==='discover'?f.discover():f.frozen(2),/breaking migration/);
  });
  test(`${route} composes compatible intervals across missed polls`,async()=>{
    const f=fixture(),first=f.publish(1),last=f.publish(2,{baseline:first});
    assert.equal(await (route==='discover'?f.discover():f.frozen(2)),last);
  });
  test(`${route} rejects missing predecessor evidence`,async()=>{
    const f=fixture(),first=f.publish(1);f.publish(2,{baseline:first});f.releases.delete(1);
    await assert.rejects(route==='discover'?f.discover():f.frozen(2),/missing/);
  });
}
test('frozen interval admission loads only authenticated linked predecessors',async()=>{
  const f=fixture(),first=f.publish(1),last=f.publish(2,{baseline:first});
  f.reader.releases=async()=>assert.fail('newer malformed release must not be observed');
  assert.equal(await f.frozen(2),last);assert.deepEqual(f.admissions,[2,1]);
});
test('development source after a breaking interval admits only the compatible suffix',async()=>{
  const f=fixture(),first=f.publish(1),changes=[f.interval(1,2,'major','breaking'),f.interval(2,3)];
  const last=f.publish(3,{baseline:first,impact:'major',disposition:'breaking',changes});
  f.selected.commit=oid(2);f.selected.tree=f.trees.get(oid(2));
  assert.equal(await f.discover(),last);assert.equal(await f.frozen(3),last);
});
test('an indivisible reviewed range cannot invent compatibility from an interior development pin',async()=>{
  const f=fixture();f.publish(3);f.selected.commit=oid(2);f.selected.tree=f.trees.get(oid(2));
  await assert.rejects(f.frozen(3),/missing upstream compatibility coverage/);
});
test('compatible bootstrap base followed by version preparation reaches the first publication',async()=>{
  const f=fixture(),last=f.publish(2),boundary=JSON.parse(last.payloads.get('publication-boundary.json'));
  boundary.bootstrap.subject.head=oid(1);boundary.bootstrap.subject.tree=f.trees.get(oid(1));
  boundary.changes=[{...f.interval(1,2),versionOnly:true}];
  const bytes=encodeRecord(boundary),asset=last.record.artifacts.find(value=>value.name==='publication-boundary.json');
  last.payloads.set(asset.name,bytes);asset.bytes=bytes.length;asset.sha256=sha256(bytes);last.recordSha256=sha256(encodeRecord(last.record));
  assert.equal(await f.frozen(2),last);
});
test('source-equivalent forward revert restores the accepted source without transferring identities',async()=>{
  const f=fixture();f.publish(1,{version:'9.0.0',impact:'major',disposition:'breaking'});
  f.trees.set(oid(2),f.selected.tree);const restored=f.publish(2,{version:'9.0.1',impact:'major',disposition:'breaking'});
  assert.equal(await f.frozen(2),restored);assert.notEqual(restored.source.commit,f.selected.commit);
  assert.equal(await selectPublishedSource(f.reader,f.selected,[restored]),null);
});
test('ordinary forward compatible revert remains admissible',async()=>{
  const f=fixture(),first=f.publish(1);f.trees.set(oid(2),oid(90));
  const restored=f.publish(2,{baseline:first});assert.equal(await f.frozen(2),restored);
});
for(const corruption of ['digest','source','gap','payload','schema'])test(`rejects ${corruption} corruption in compatibility evidence`,async()=>{
  const f=fixture(),first=f.publish(1),last=f.publish(2,{baseline:first});
  if(corruption==='payload')last.payloads.clear();
  else{
    const boundary=JSON.parse(last.payloads.get('publication-boundary.json'));
    if(corruption==='digest')boundary.baseline.recordSha256='f'.repeat(64);
    if(corruption==='source')boundary.baseline.source.tree='f'.repeat(40);
    if(corruption==='gap')boundary.changes[0].base=oid(5);
    if(corruption==='schema')boundary.schema='repository-publication-boundary/v2';
    const bytes=encodeRecord(boundary),asset=last.record.artifacts.find(value=>value.name==='publication-boundary.json');
    last.payloads.set(asset.name,bytes);asset.bytes=bytes.length;asset.sha256=sha256(bytes);
  }
  await assert.rejects(f.frozen(2));
});
test('planner preserves authenticated boundary bytes after temporary admission cleanup',async()=>{
  const f=fixture(),last=f.publish(1);
  const value=await discoverKosmosRelease(f.selected,{reader:f.reader,admit:async({releaseId})=>f.admit(releaseId)});
  assert.equal(value.id,last.id);assert.deepEqual(value.payloads.get('publication-boundary.json'),last.payloads.get('publication-boundary.json'));
});
test('planner blocks the skipped breaking interval on both discovery and frozen input',async()=>{
  const f=fixture(),major=f.publish(1,{version:'9.0.0',impact:'major',disposition:'breaking'});f.publish(2,{version:'9.0.1',baseline:major});
  const options={reader:f.reader,admit:async({releaseId})=>f.admit(releaseId)};
  await assert.rejects(discoverKosmosRelease(f.selected,options),/breaking migration/);
  await assert.rejects(discoverKosmosRelease(f.selected,{...options,releaseId:2}),/breaking migration/);
});

import {computedCompatibilityBoundary} from './compatibility-boundary-test-support.mjs';
import {requireCompatibleSource} from './upstream-compatibility.mjs';

test('actual publisher bootstrap and mapped version preparation compose into consumer compatibility',async()=>{
  const f=await computedCompatibilityBoundary();assert.equal(f.boundary.status,'ready');
  assert.notEqual(f.boundary.record.changes[0].subject.head,f.boundary.record.changes[0].head);
  const record={repository:{name:f.repository},source:{...f.boundary.record.source,version:f.boundary.version},
    compatibility:{impact:'patch',disposition:'compatible',evidence:'publication-boundary.json'},
    artifacts:[{name:'publication-boundary.json',bytes:f.boundary.bytes.length,sha256:sha256(f.boundary.bytes)}]};
  const release={id:1,record,source:record.source,payloads:new Map([['publication-boundary.json',f.boundary.bytes]])};
  const reader={forward:async(a,b)=>f.forward(a,b),api:async path=>f.commits.get(path.slice('git/commits/'.length))};
  await requireCompatibleSource(reader,f.selected,f.selected.tree,release,async()=>assert.fail('bootstrap must cover the selection'));
});

test('equal tree at an intermediate reviewed endpoint anchors a divergent selected commit',async()=>{
  const f=fixture(),first=f.publish(1),last=f.publish(3,{baseline:first,changes:[f.interval(1,2),f.interval(2,3)]});
  const branch=oid(7);f.trees.set(branch,f.trees.get(oid(2)));f.selected.commit=branch;f.selected.tree=f.trees.get(branch);
  f.reader.forward=async(a,b)=>a===b||(a!==branch&&b!==branch&&Number.parseInt(a,16)<=Number.parseInt(b,16));
  assert.equal(await f.discover(),last);assert.equal(await f.frozen(3),last);
});
