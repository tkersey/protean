import assert from 'node:assert/strict';
import {requireCompatibleSource,sourceCompatibility} from './upstream-compatibility.mjs';

export async function selectedSourceTree(reader,selected){
  assert.match(selected.commit,/^[0-9a-f]{40}$/);
  const value=await reader.api(`git/commits/${selected.commit}`);
  assert.equal(value.sha,selected.commit);assert.match(value.tree.sha,/^[0-9a-f]{40}$/);
  if(selected.tree!==undefined)assert.equal(value.tree.sha,selected.tree,'selected dependency Git tree differs');
  return value.tree.sha;
}

export async function selectPublishedSource(reader,selected,admitted,{publicationRequired=false,frozenReleaseId}={}){
  const tree=await selectedSourceTree(reader,selected),ids=new Set(),commits=new Map();
  for(const release of admitted){
    assert.ok(Number.isSafeInteger(release.id)&&release.id>0&&!ids.has(release.id),'duplicate admitted release');ids.add(release.id);
    assert.match(release.source.commit,/^[0-9a-f]{40}$/);assert.match(release.source.tree,/^[0-9a-f]{40}$/);
    assert.ok(!commits.has(release.source.commit),'ambiguous publications for one source');commits.set(release.source.commit,release);
    if(release.source.commit===selected.commit)assert.equal(release.source.tree,tree,'selected publication Git tree differs');
  }
  const equivalents=admitted.filter(release=>release.source.tree===tree);
  const anchors=[selected.commit,...equivalents.map(release=>release.source.commit).filter(commit=>commit!==selected.commit)];
  const reachable=async release=>{
    if(release.source.tree===tree)return true;
    if(await reader.forward(release.source.commit,selected.commit))return false;
    for(const anchor of anchors)if(await reader.forward(anchor,release.source.commit))return true;
    return (await sourceCompatibility(reader,selected,tree,release,async id=>admitted.find(value=>value.id===id))).related;
  };
  if(frozenReleaseId!==undefined){
    const release=admitted.find(value=>value.id===frozenReleaseId);assert.ok(release,'frozen upstream publication disappeared');
    assert.ok(await reachable(release),'frozen upstream lineage changed');
    await requireCompatibleSource(reader,selected,tree,release,async id=>admitted.find(value=>value.id===id));return release;
  }
  let successor=null;
  for(const release of admitted){
    if(release.source.tree===tree||!await reachable(release))continue;
    if(successor===null)successor=release;
    else if(await reader.forward(successor.source.commit,release.source.commit))successor=release;
    else assert.ok(await reader.forward(release.source.commit,successor.source.commit),'divergent successor publications');
  }
  if(successor!==null){
    await requireCompatibleSource(reader,selected,tree,successor,async id=>admitted.find(value=>value.id===id));return successor;
  }
  if(!publicationRequired)return null;
  const exact=commits.get(selected.commit);
  if(exact!==undefined)return exact;
  assert.ok(equivalents.length<=1,'ambiguous source-equivalent publications');
  return equivalents[0]??null;
}

export async function admitFrozenSource(reader,selected,releaseId,admitOne){
  assert.ok(Number.isSafeInteger(releaseId)&&releaseId>0);
  const cache=new Map();
  const admitted=async id=>{if(!cache.has(id))cache.set(id,await admitOne(id));return cache.get(id);};
  const release=await admitted(releaseId);assert.equal(release.id,releaseId);
  assert.match(release.source.commit,/^[0-9a-f]{40}$/);assert.match(release.source.tree,/^[0-9a-f]{40}$/);
  const tree=await selectedSourceTree(reader,selected);
  if(release.source.commit===selected.commit)assert.equal(release.source.tree,tree,'selected publication Git tree differs');
  if(release.source.tree===tree)return release;
  assert.ok(!await reader.forward(release.source.commit,selected.commit),'frozen publication predates selected development source');
  await requireCompatibleSource(reader,selected,tree,release,admitted);
  return release;
}
