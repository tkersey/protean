import assert from 'node:assert/strict';
import test from 'node:test';
import {attachCompatibility} from './compatibility-test-support.mjs';
import {selectPublishedSource} from './protean-upstream-selection.mjs';

const pin='a'.repeat(40),counterpart='b'.repeat(40),successor='c'.repeat(40),other='d'.repeat(40),tree='e'.repeat(40),changed='f'.repeat(40);
function fixture(){
  const pairs=new Set(),calls=[];
  const reader={async api(path){const commit=path.slice('git/commits/'.length);assert.ok([pin,counterpart].includes(commit));return {sha:commit,tree:{sha:tree}};},
    async forward(base,head){calls.push([base,head]);return base===head||pairs.has(`${base}:${head}`);}};
  const equivalent={id:1,source:{commit:counterpart,tree}},next={id:2,source:{commit:successor,tree:changed,version:'1.0.1'}};
  next.record={repository:{name:'tkersey/kosmos'},source:next.source,artifacts:[],compatibility:{impact:'patch',disposition:'compatible'}};
  next.payloads=attachCompatibility(next.record,pin);
  return {pairs,reader,equivalent,next,selected:{commit:pin,tree},calls};
}
test('qualified squash counterpart is selected only when exact publication binding is required',async()=>{
  const f=fixture();assert.equal(await selectPublishedSource(f.reader,f.selected,[f.equivalent]),null);
  assert.equal(await selectPublishedSource(f.reader,f.selected,[f.equivalent],{publicationRequired:true}),f.equivalent);
});
test('source equivalent descendant does not cause commit spelling normalization',async()=>{
  const f=fixture();f.pairs.add(`${pin}:${counterpart}`);
  assert.equal(await selectPublishedSource(f.reader,f.selected,[f.equivalent]),null);
});
test('substantive qualified successor beyond a squash counterpart is discoverable',async()=>{
  const f=fixture();f.pairs.add(`${counterpart}:${successor}`);f.next.payloads=attachCompatibility(f.next.record,counterpart);
  assert.equal(await selectPublishedSource(f.reader,f.selected,[f.equivalent,f.next]),f.next);
});
test('development source ahead of an otherwise eligible publication never moves backwards',async()=>{
  const f=fixture();f.pairs.add(`${counterpart}:${successor}`);f.pairs.add(`${successor}:${pin}`);
  assert.equal(await selectPublishedSource(f.reader,f.selected,[f.equivalent,f.next]),null);
});
test('exact publication is preferred over equivalent spelling when it already exists',async()=>{
  const f=fixture(),exact={id:3,source:{commit:pin,tree}};
  assert.equal(await selectPublishedSource(f.reader,f.selected,[f.equivalent,exact],{publicationRequired:true}),exact);
});
test('frozen qualified selection remains fixed when a newer publication appears',async()=>{
  const f=fixture();f.pairs.add(`${pin}:${successor}`);f.pairs.add(`${successor}:${other}`);
  const newer={id:3,source:{commit:other,tree:'0'.repeat(40)}};
  assert.equal(await selectPublishedSource(f.reader,f.selected,[f.next,newer],{frozenReleaseId:2}),f.next);
});
test('different successor branches beyond equivalent sources fail rather than guessing',async()=>{
  const f=fixture();f.pairs.add(`${counterpart}:${successor}`);f.pairs.add(`${pin}:${other}`);
  await assert.rejects(selectPublishedSource(f.reader,f.selected,[f.equivalent,f.next,{id:3,source:{commit:other,tree:'0'.repeat(40)}}]),/divergent/);
});
test('ambiguous equal-tree counterparts and mismatched owning tree fail closed',async()=>{
  const f=fixture();await assert.rejects(selectPublishedSource(f.reader,f.selected,[f.equivalent,{id:3,source:{commit:other,tree}}],{publicationRequired:true}),/ambiguous/);
  await assert.rejects(selectPublishedSource(f.reader,{commit:pin,tree:changed},[]),/Git tree differs/);
});

import {admitFrozenSource} from './protean-upstream-selection.mjs';
for(const kind of ['forward','equivalent'])test(`frozen ${kind} publication ignores malformed or breaking newer releases`,async()=>{
  const f=fixture(),chosen=kind==='equivalent'?f.equivalent:f.next,admissions=[];
  if(kind==='forward')f.pairs.add(`${pin}:${successor}`);
  f.reader.releases=async()=>assert.fail('exact admitted frozen release must not discover newer publications');
  const value=await admitFrozenSource(f.reader,f.selected,chosen.id,async id=>{admissions.push(id);assert.equal(id,chosen.id);return chosen;});
  assert.equal(value,chosen);assert.deepEqual(admissions,[chosen.id]);
});
test('frozen divergent successor uses its authenticated equivalent bootstrap base without release hints',async()=>{
  const f=fixture(),admissions=[];f.pairs.add(`${counterpart}:${successor}`);
  f.next.payloads=attachCompatibility(f.next.record,counterpart);
  f.reader.releases=async()=>assert.fail('authenticated source interval does not need release hints');
  const value=await admitFrozenSource(f.reader,f.selected,2,async id=>{admissions.push(id);return f.next;});
  assert.equal(value,f.next);assert.deepEqual(admissions,[2]);
});
test('source equivalence cannot replace missing authenticated interval evidence',async()=>{
  const f=fixture();f.pairs.add(`${counterpart}:${successor}`);f.next.payloads.clear();
  f.reader.releases=async()=>[{id:1}];
  await assert.rejects(admitFrozenSource(f.reader,f.selected,2,async()=>f.next),/missing authenticated/);
});
test('frozen different-tree publication behind development source is rejected before discovery',async()=>{
  const f=fixture();f.pairs.add(`${successor}:${pin}`);f.reader.releases=async()=>assert.fail('no anchor can authorize downgrade');
  await assert.rejects(admitFrozenSource(f.reader,f.selected,2,async()=>f.next),/predates/);
});
test('unrelated malformed hints are never observed when original boundary proves source equivalence',async()=>{
  const f=fixture();f.pairs.add(`${counterpart}:${successor}`);f.next.payloads=attachCompatibility(f.next.record,counterpart);
  f.reader.releases=async()=>assert.fail('unrelated malformed publication');
  assert.equal(await admitFrozenSource(f.reader,f.selected,2,async()=>f.next),f.next);
});
