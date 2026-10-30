import assert from 'node:assert/strict';

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
    return false;
  };
  if(frozenReleaseId!==undefined){
    const release=admitted.find(value=>value.id===frozenReleaseId);assert.ok(release,'frozen upstream publication disappeared');
    assert.ok(await reachable(release),'frozen upstream lineage changed');return release;
  }
  let successor=null;
  for(const release of admitted){
    if(release.source.tree===tree||!await reachable(release))continue;
    if(successor===null)successor=release;
    else if(await reader.forward(successor.source.commit,release.source.commit))successor=release;
    else assert.ok(await reader.forward(release.source.commit,successor.source.commit),'divergent successor publications');
  }
  if(successor!==null)return successor;
  if(!publicationRequired)return null;
  const exact=commits.get(selected.commit);
  if(exact!==undefined)return exact;
  assert.ok(equivalents.length<=1,'ambiguous source-equivalent publications');
  return equivalents[0]??null;
}

async function releaseHint(reader,release){
  const assets=release.assets?.filter(asset=>asset.name==='release.json');
  if(!assets||assets.length!==1)return null;
  const asset=assets[0];
  if(!Number.isSafeInteger(asset.id)||asset.id<=0||!Number.isSafeInteger(asset.size)||asset.size<=0||asset.size>1024*1024)return null;
  try{
    const {readRecord}=await import('./record.mjs');
    return readRecord(await reader.command(['api',`repos/${reader.repository}/releases/assets/${asset.id}`,'-H','Accept: application/octet-stream'],asset.size+1));
  }catch{return null;}
}

export async function admitFrozenSource(reader,selected,releaseId,admitOne,{readHint=releaseHint}={}){
  assert.ok(Number.isSafeInteger(releaseId)&&releaseId>0);
  const release=await admitOne(releaseId);assert.equal(release.id,releaseId);
  assert.match(release.source.commit,/^[0-9a-f]{40}$/);assert.match(release.source.tree,/^[0-9a-f]{40}$/);
  const tree=await selectedSourceTree(reader,selected);
  if(release.source.commit===selected.commit)assert.equal(release.source.tree,tree,'selected publication Git tree differs');
  if(release.source.tree===tree)return release;
  assert.ok(!await reader.forward(release.source.commit,selected.commit),'frozen publication predates selected development source');
  if(await reader.forward(selected.commit,release.source.commit))return release;
  const seen=new Set([releaseId]);
  for(const observed of await reader.releases()){
    if(seen.has(observed.id))continue;seen.add(observed.id);
    assert.ok(seen.size<=10000,'equivalent publication discovery capacity exceeded');
    let hint;
    try{
      hint=await readHint(reader,observed);
      if(hint?.source?.tree!==tree||!await reader.forward(hint.source.commit,release.source.commit))continue;
    }catch{continue;}
    let anchor;
    try{anchor=await admitOne(observed.id);}catch{continue;}
    assert.equal(anchor.id,observed.id);
    if(anchor.source.tree===tree&&await reader.forward(anchor.source.commit,release.source.commit))return release;
  }
  throw new Error('frozen publication has no authenticated selected source or equivalent publication anchor');
}
