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

for (const target of ['x86_64-linux-musl', 'x86_64-linux.5.10-musl', 'x86_64-linux.5.10...7.2-musl', 'x86_64-linux.5.10.1...7.2.3-musl'])
  test(`final archive preserves supported native target ${target}`, () => {
    const f = proteanFixture({target}), receipt = JSON.parse(sealProteanProduct(f.packageInput));
    assert.equal(receipt.identity.target, target);
  });

for (const target of [
  'aarch64-linux.5.10...7.2-musl', 'x86_64-macos.5.10...7.2-musl', 'x86_64-linux.5.10...7.2-gnu',
  'x86_64-linux.5.10...7.2-musleabihf', 'x86_64-linux.5-musl', 'x86_64-linux.5.10..7.2-musl',
  'x86_64-linux.5.10...-musl', 'x86_64-linux.05.10...7.2-musl', 'x86_64-linux.5.10.1.2-musl',
  'x86_64-linux.7.2...5.10-musl', 'x86_64-linux.18446744073709551616.0-musl',
  'x86_64-linux-musl.1.2', 'x86_64-linux-musl\n', '', null,
]) test(`final archive rejects internally consistent unsupported target ${JSON.stringify(target)}`, () => {
  const f = proteanFixture(), build = JSON.parse(f.packageInput.buildBytes);
  build.target = target; f.native.identity.target = target;
  f.packageInput.buildBytes = Buffer.from(JSON.stringify(build));
  f.packageInput.identityBytes = Buffer.from(JSON.stringify(f.native));
  assert.throws(() => sealProteanProduct(f.packageInput), /target/);
});

test('different supported target strings cannot stand in for the executed native identity', () => {
  const f = proteanFixture(), build = JSON.parse(f.packageInput.buildBytes); build.target = 'x86_64-linux-musl';
  f.packageInput.buildBytes = Buffer.from(JSON.stringify(build));
  assert.throws(() => sealProteanProduct(f.packageInput), /differs from executed native identity/);
});

test('native receipt preserves the source-owned SQLite filename inventory', () => {
  const f = proteanFixture(), receipt = JSON.parse(sealProteanProduct(f.packageInput));
  assert.deepEqual(Object.keys(receipt.identity.dependencies.sqlite.files), ['sqlite3.c', 'sqlite3.h']);
  assert.deepEqual(receipt.identity.dependencies.sqlite.files, f.native.identity.dependencies.sqlite.files);
  assert.deepEqual(sealProteanProduct(f.packageInput), sealProteanProduct(f.packageInput));
});
