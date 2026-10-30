import assert from 'node:assert/strict';
import test from 'node:test';
import {assembleProtean, assemblePublishedProtean} from './protean-assemble.mjs';
import {proteanFixture} from './protean-test-support.mjs';
import {encodeRecord, sha256} from './encoding.mjs';

const assemble = f => assembleProtean(f.input, f.payloads, f.manifest, f.lockBytes, f.nativeLockBytes, f.admitted);

test('Protean assembly derives final source and the exact transitive upstream tuple', () => {
  const f = proteanFixture(), result = {record: JSON.parse(assemble(f))};
  assert.equal(result.record.repository.name, 'tkersey/protean');
  assert.equal(result.record.source.lockSha256, sha256(f.lockBytes));
  assert.deepEqual(result.record.dependencies.map(value => value.release.id), [3, 4]);
  assert.equal(result.record.artifacts.length, 7);
  assert.equal(result.record.artifacts.find(value => value.role === 'native').platform, 'linux-x86_64');
});

for (const [name, mutate] of [
  ['manifest bytes', f => {f.manifest = Buffer.from('changed manifest');}],
  ['source lock bytes', f => {f.lockBytes = Buffer.from('{}');}],
  ['native lock bytes', f => {f.nativeLockBytes = Buffer.from('{}');}],
  ['unverified upstream', f => {delete f.admitted[0].admissionVerification;}],
  ['changed authenticated record', f => {f.admitted[1].record.source.tree = 'e'.repeat(40);}],
  ['independently selected Horos', f => {f.admitted[0].id++;}],
  ['duplicate upstream', f => {f.admitted[1] = f.admitted[0];}],
  ['missing native platform', f => {f.input.artifacts.find(value => value.role === 'native').platform = null;}],
  ['wrong native role', f => {f.input.artifacts.find(value => value.role === 'native').role = 'evidence';}],
  ['substituted final bytes', f => {f.payloads.set(f.packageInput.archiveName, Buffer.from('substitute'));}],
]) test(`Protean assembly rejects ${name}`, () => {
  const f = proteanFixture(); mutate(f); assert.throws(() => assemble(f));
});

test('Protean assembly requires native source inventory to contain each exact source definition', () => {
  const f = proteanFixture(); f.inventory.files[0].blob = 'e'.repeat(40);
  f.payloads.set('source.json', Buffer.from(JSON.stringify(f.inventory)));
  f.downstream.source.receiptSha256 = sha256(f.payloads.get('source.json'));
  f.payloads.set('downstream-identity.json', Buffer.from(JSON.stringify(f.downstream)));
  assert.throws(() => assemble(f), /captured source definition/);
});

test('Protean assembly rejects an authenticated Kosmos bound to a different Horos release', () => {
  const f = proteanFixture();
  f.admitted[1].record.dependencies[0].release.id++;
  f.admitted[1].recordSha256 = sha256(encodeRecord(f.admitted[1].record));
  assert.throws(() => assemble(f), /independent Horos selection/);
});

test('published assembly disallows an independent Horos selector before any network operation', async () => {
  await assert.rejects(assemblePublishedProtean({horosReleaseId: 3}, () => assert.fail('unexpected API')), /must be derived/);
});
