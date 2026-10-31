import assert from 'node:assert/strict';
import {sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {validateImpact} from './impact.mjs';

const oid=value=>assert.match(value,/^[0-9a-f]{40}$/);
const digest=value=>assert.match(value,/^[0-9a-f]{64}$/);
const id=value=>assert.ok(Number.isSafeInteger(value)&&value>0);
function fields(value,names){
  assert.ok(value&&typeof value==='object'&&!Array.isArray(value),'missing compatibility evidence object');
  assert.deepEqual(Object.keys(value).sort(),names.split(' ').sort(),'unsupported compatibility evidence fields');
}
function subject(value){fields(value,'base head tree');oid(value.base);oid(value.head);oid(value.tree);}
function review(value){fields(value,'runId artifactId sha256');id(value.runId);id(value.artifactId);digest(value.sha256);}
function change(value){
  fields(value,'base head pull subject landedCommits review declaration versionOnly');
  oid(value.base);oid(value.head);id(value.pull);subject(value.subject);review(value.review);validateImpact(value.declaration);
  assert.equal(value.base,value.subject.base,'reviewed and landed compatibility bases differ');
  assert.equal(typeof value.versionOnly,'boolean');
  assert.ok(Array.isArray(value.landedCommits)&&value.landedCommits.length>0&&value.landedCommits.length<=10000);
  value.landedCommits.forEach(oid);assert.equal(new Set(value.landedCommits).size,value.landedCommits.length);
  assert.equal(value.landedCommits.at(-1),value.head,'compatibility landing endpoint differs');
  return {base:value.base,head:value.head,tree:value.subject.tree,declaration:value.declaration};
}
export function publicationCompatibility(release){
  const record=release.record,name=record.compatibility.evidence;
  assert.equal(name,'publication-boundary.json','unsupported upstream compatibility evidence');
  const bytes=release.payloads?.get(name),asset=record.artifacts.find(value=>value.name===name);
  assert.ok(Buffer.isBuffer(bytes)&&asset,'missing authenticated upstream compatibility evidence');
  assert.equal(bytes.length,asset.bytes,'upstream compatibility evidence size differs');
  assert.equal(sha256(bytes),asset.sha256,'upstream compatibility evidence digest differs');
  const boundary=parseEvidenceJson(bytes,16*1024*1024);
  fields(boundary,'schema repository source pendingVersion version status baseline bootstrap changes');
  assert.equal(boundary.schema,'repository-publication-boundary/v1');
  assert.equal(boundary.repository,record.repository.name);assert.equal(boundary.status,'ready');
  fields(boundary.source,'commit tree');
  assert.equal(boundary.source.commit,release.source.commit);assert.equal(boundary.source.tree,release.source.tree);
  assert.equal(boundary.version,release.source.version);assert.equal(boundary.pendingVersion,boundary.version);
  assert.ok(Array.isArray(boundary.changes)&&boundary.changes.length<=10000);
  const edges=boundary.changes.map(change),declarations=boundary.changes.filter(value=>!value.versionOnly).map(value=>value.declaration);
  let start;
  if(boundary.baseline!==null){
    assert.equal(boundary.bootstrap,null);fields(boundary.baseline,'releaseId recordSha256 source');
    id(boundary.baseline.releaseId);digest(boundary.baseline.recordSha256);
    oid(boundary.baseline.source.commit);oid(boundary.baseline.source.tree);start=boundary.baseline.source.commit;
  }else{
    const bootstrap=boundary.bootstrap;
    fields(bootstrap,'subject initialVersion disposition rationale declaration review correspondence');
    subject(bootstrap.subject);review(bootstrap.review);validateImpact(bootstrap.declaration);
    assert.equal(bootstrap.disposition,bootstrap.declaration.disposition);
    assert.ok(typeof bootstrap.rationale==='string'&&bootstrap.rationale.length>0);
    let edge={base:bootstrap.subject.base,head:bootstrap.subject.head,tree:bootstrap.subject.tree,declaration:bootstrap.declaration};
    if(bootstrap.correspondence!==null){
      edge=change(bootstrap.correspondence);
      assert.deepEqual(bootstrap.correspondence.subject,bootstrap.subject);
      assert.deepEqual(bootstrap.correspondence.declaration,bootstrap.declaration);
      assert.deepEqual(bootstrap.correspondence.review,bootstrap.review);
    }
    edges.unshift(edge);declarations.unshift(bootstrap.declaration);start=edge.base;
  }
  for(const edge of edges){assert.equal(edge.base,start,'upstream compatibility interval gap');start=edge.head;}
  assert.equal(start,release.source.commit,'upstream compatibility endpoint differs');
  if(edges.length>0)assert.equal(edges.at(-1).tree,release.source.tree,'upstream compatibility endpoint tree differs');
  const impacts=['none','patch','minor','major'];
  const impact=declarations.length===0?'patch':impacts[Math.max(...declarations.map(value=>impacts.indexOf(value.impact)))];
  assert.equal(record.compatibility.impact,impact,'contradictory upstream compatibility impact');
  assert.equal(record.compatibility.disposition,declarations.some(value=>value.disposition==='breaking')?'breaking':'compatible',
    'contradictory upstream compatibility disposition');
  return {edges,baseline:boundary.baseline};
}

export async function sourceCompatibility(reader,selected,tree,candidate,loadRelease){
  let release=candidate,violation=null;
  const seen=new Set();let count=0;
  const result=()=>({related:true,violation});
  for(;;){
    if(release.source.commit===selected.commit){assert.equal(release.source.tree,tree);return result();}
    if(release.source.tree===tree)return result();
    assert.ok(!seen.has(release.id)&&seen.size<10000,'upstream compatibility publication cycle or capacity');seen.add(release.id);
    const {edges,baseline}=publicationCompatibility(release);
    let cursor=release.source.commit;
    for(const edge of [...edges].reverse()){
      assert.ok(++count<=10000,'upstream compatibility interval capacity exceeded');
      assert.equal(cursor,edge.head);
      if(cursor===selected.commit)assert.equal(edge.tree,tree,'selected compatibility endpoint tree differs');
      if(cursor===selected.commit||edge.tree===tree)return result();
      assert.ok(await reader.forward(edge.base,edge.head),'upstream compatibility interval is not forward source history');
      if(edge.declaration.disposition!=='compatible')violation??='upstream breaking migration requires ordinary implementation';
      if(edge.declaration.impact==='major')violation??='upstream major migration requires ordinary implementation';
      cursor=edge.base;
      if(cursor===selected.commit)return result();
    }
    if(baseline===null){
      const origin=await reader.api(`git/commits/${cursor}`);
      assert.equal(origin.sha,cursor);oid(origin.tree.sha);
      return origin.tree.sha===tree?result():{related:false,violation:null};
    }
    assert.equal(cursor,baseline.source.commit);
    if(cursor===selected.commit){assert.equal(baseline.source.tree,tree);return result();}
    if(baseline.source.tree===tree)return result();
    release=await loadRelease(baseline.releaseId);
    assert.ok(release,'missing upstream compatibility predecessor publication');
    assert.equal(release.id,baseline.releaseId);
    assert.equal(release.recordSha256,baseline.recordSha256,'upstream compatibility predecessor digest differs');
    assert.deepEqual(release.source,baseline.source,'upstream compatibility predecessor source differs');
  }
}

export async function requireCompatibleSource(reader,selected,tree,candidate,loadRelease){
  const relation=await sourceCompatibility(reader,selected,tree,candidate,loadRelease);
  assert.ok(relation.related,'missing upstream compatibility coverage for selected source');
  assert.equal(relation.violation,null,relation.violation??'upstream compatibility required');
}
