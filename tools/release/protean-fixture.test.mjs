import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {sha256} from './encoding.mjs';
import {readRecord} from './record.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

const load = (repository, name) => readFileSync(new URL(`../../test/fixtures/release/${repository}/${name}`, import.meta.url));

test('native Protean final source preserves Kosmos derived Horos and both exact lock bytes', () => {
  const own = parseEvidenceJson(load('protean', 'source.json'));
  const kosmos = parseEvidenceJson(load('kosmos', 'source.json'));
  const horos = readRecord(load('horos', 'horos-v1.json'));
  assert.equal(own.commit, '581b1c55dc690ac5f5bd5e3af0d90ef3f4015008');
  assert.equal(own.tree, 'af3d078c2f58c5cebcf12b7ad31820ec00597507');
  assert.equal(own.sha256, '6039b449261224f44821c5d66a2e436033ecbc2712fcf747a25883512f09aa1f');
  assert.equal(own.size, 6824448); assert.equal(own.manifest.version, '8.0.1');
  assert.equal(own.packageIdentity, 'protean-8.0.1-dBg3hGo9YwBwGK78RcQcQR7RtXydaaQ5Q2Y40_Wc2JW_');
  assert.equal(own.dependencies.kosmos.commit, kosmos.commit);
  assert.equal(own.dependencies.kosmos.tree, kosmos.tree);
  assert.equal(own.dependencies.horos.commit, kosmos.manifest.horos.commit);
  assert.equal(own.dependencies.horos.commit, horos.source.commit);
  assert.equal(own.dependencies.horos.tree, horos.source.tree);
  assert.equal(own.manifest.horos.packageIdentity, horos.source.packageIdentity);
  assert.equal(own.manifest.horos.packageIdentity, kosmos.manifest.horos.packageIdentity);
  for (const [name, path, digest] of [
    ['build.zig.zon.txt', 'build.zig.zon', own.manifest.sha256],
    ['dependencies.lock.json', 'conformance/protean/dependencies.lock.json', own.lockSha256],
    ['native-dependencies.lock.json', 'conformance/protean/native-dependencies.lock.json', own.nativeLockSha256],
  ]) {
    const bytes = load('protean', name), file = own.files.find(value => value.path === path);
    assert.equal(digest, sha256(bytes)); assert.equal(file.mode, 0o644);
    assert.equal(file.blob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'));
  }
  const lock = parseEvidenceJson(load('protean', 'dependencies.lock.json'));
  assert.equal(lock.world.archive.sha256, kosmos.sha256); assert.equal(lock.world.archive.bytes, kosmos.size);
  assert.equal(lock.boundary.archive.sha256, horos.artifacts.find(value => value.role === 'source').sha256);
  assert.equal(lock.boundary.package.zigHash, own.manifest.horos.packageIdentity);
});
