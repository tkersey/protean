import assert from 'node:assert/strict';
import test from 'node:test';
import {sealProteanProduct} from './protean-package.mjs';
import {proteanFixture} from './protean-test-support.mjs';
import {sha256} from './encoding.mjs';

test('final archive receipt binds the executed executable, program and application', () => {
  const f = proteanFixture(), receipt = JSON.parse(sealProteanProduct(f.packageInput));
  assert.equal(receipt.archive.sha256, sha256(f.packageInput.archiveBytes));
  assert.equal(receipt.executable.sha256, f.native.artifact_sha256);
  assert.deepEqual(receipt.identity, f.native.identity);
});

for (const field of ['executableBytes', 'programBytes', 'applicationBytes'])
  test(`final archive rejects changed ${field}`, () => {
    const f = proteanFixture(); f.packageInput[field] = Buffer.from('changed packaged content');
    assert.throws(() => sealProteanProduct(f.packageInput));
  });

for (const [name, mutate] of [
  ['source name', f => {f.packageInput.archiveName = 'protean-Linux-X64-wrong.tar.gz';}],
  ['compiler', build => {build.compiler.version = '0.16.0';}],
  ['target', build => {build.target = 'aarch64-macos';}],
  ['unsafe mode', build => {build.optimize = 'fast';}],
]) test(`final archive rejects wrong ${name}`, () => {
  const f = proteanFixture();
  if (name === 'source name') mutate(f);
  else {
    const build = JSON.parse(f.packageInput.buildBytes); mutate(build);
    f.packageInput.buildBytes = Buffer.from(JSON.stringify(build));
  }
  assert.throws(() => sealProteanProduct(f.packageInput));
});

test('final archive rejects a different executed native identity', () => {
  const f = proteanFixture(); f.native.identity.dependencies.boundary = 'e'.repeat(40);
  f.packageInput.identityBytes = Buffer.from(JSON.stringify(f.native));
  assert.throws(() => sealProteanProduct(f.packageInput));
});
