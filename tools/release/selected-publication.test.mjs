import assert from 'node:assert/strict';
import test from 'node:test';
import {admitSelectedPublication} from './selected-publication.mjs';
import {metadata} from './test-support.mjs';
import {encodeRecord, sha256} from './encoding.mjs';

function fixture() {
  const record = metadata('horos'), bytes = encodeRecord(record);
  const releases = [{id: 3, draft: false, prerelease: false}], seen = [];
  const input = {repository: 'tkersey/horos', commit: record.source.commit, packageIdentity: record.source.packageIdentity};
  const command = async args => {
    const path = args[1];
    if (path === 'repos/tkersey/horos/releases/assets/4') return bytes;
    const value = path === 'repos/tkersey/horos' ? {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'} :
      path === 'repos/tkersey/horos/releases?per_page=100&page=1' ? releases :
      path === 'repos/tkersey/horos/releases/3/assets?per_page=100&page=1' ? [{id: 4, name: 'release.json', size: bytes.length, digest: `sha256:${sha256(bytes)}`}] : undefined;
    assert.ok(value, path); return Buffer.from(JSON.stringify(value));
  };
  const admitted = {id: 3, record, recordSha256: sha256(bytes), admissionVerification: Buffer.from('test')};
  const admit = async options => {seen.push(options); assert.equal(options.releaseId, 3); return admitted;};
  return {input, command, admit, admitted, seen, releases, bytes};
}

test('publication authenticates exactly the existing selection before using source facts', async () => {
  const f = fixture(); assert.equal(await admitSelectedPublication(f.input, f.command, f.admit), f.admitted);
  assert.equal(f.seen.length, 1);
});

test('an unrelated published successor never substitutes for the selected development source', async () => {
  const f = fixture(); f.input.commit = 'd'.repeat(40);
  await assert.rejects(() => admitSelectedPublication(f.input, f.command, f.admit), /no matching completed/);
  assert.equal(f.seen.length, 0);
});

for (const field of ['tree', 'packageIdentity']) test(`matching commit still requires selected ${field}`, async () => {
  const f = fixture(); f.input[field] = field === 'tree' ? 'd'.repeat(40) : `horos-1.0.0-${'Z'.repeat(44)}`;
  await assert.rejects(() => admitSelectedPublication(f.input, f.command, f.admit), /differs/);
});

test('a plausible unauthenticated record cannot satisfy upstream publication', async () => {
  const f = fixture(); await assert.rejects(() => admitSelectedPublication(f.input, f.command, async () => {throw new Error('wrong signer');}), /wrong signer/);
});

test('source mismatch after authenticated download invalidates the hint', async () => {
  const f = fixture(); f.admitted.record.source.commit = 'd'.repeat(40);
  await assert.rejects(() => admitSelectedPublication(f.input, f.command, f.admit));
});

test('no completed publication blocks even with an otherwise valid immutable source pin', async () => {
  const f = fixture(); f.releases.length = 0;
  await assert.rejects(() => admitSelectedPublication(f.input, f.command, f.admit), /no matching completed/);
});

test('unsupported upstream repository is rejected before discovery', async () => {
  const f = fixture(); f.input.repository = 'tkersey/protean';
  await assert.rejects(() => admitSelectedPublication(f.input, () => assert.fail('unexpected network'), f.admit));
});
