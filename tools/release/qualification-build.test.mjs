import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import test from 'node:test';

const script = readFileSync(new URL('../native/qualification_build.mjs', import.meta.url));

function fixture(t, {importSuffix = '', embedSuffix = '', extra = ''} = {}) {
  const root = mkdtempSync(join(tmpdir(), 'protean-compiled-inputs-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const repository = join(root, 'repository'), bin = join(root, 'bin');
  const write = (file, bytes) => {
    const path = join(repository, file);
    mkdirSync(dirname(path), {recursive: true});
    writeFileSync(path, bytes);
  };
  for (const file of ['LICENSE', 'build.zig', 'build_protean.zig', 'build_native.zig', 'build.zig.zon']) write(file, 'fixture\n');
  write('tools/native/qualification_build.mjs', script);
  write('tools/release/unrelated.mjs', 'export const version = 1;\n');
  write('src/root.zig', `const child = @import("../fixtures/child.zig"${importSuffix});\nconst std = @import("std"${importSuffix});\n${extra}`);
  write('fixtures/child.zig', `const bytes = @embedFile("payload.txt"${embedSuffix});\nconst manifest = @embedFile("native_manifest"${embedSuffix});\n`);
  write('fixtures/payload.txt', 'payload\n');
  mkdirSync(bin);
  const zig = join(bin, 'zig');
  writeFileSync(zig, '#!/bin/sh\ncase "$1" in\n  env) printf \'    .target = "x86_64-linux-musl",\\n\' ;;\n  targets) printf \'{}\\n\' ;;\n  *) exit 1 ;;\nesac\n');
  chmodSync(zig, 0o755);
  execFileSync('git', ['init', '--quiet', repository]);
  execFileSync('git', ['add', '.'], {cwd: repository});
  const key = (compiler = 'a'.repeat(64), options = {}) => execFileSync(process.execPath,
    ['tools/native/qualification_build.mjs', 'key', 'product', compiler],
    {cwd: repository, env: {...process.env, PATH: `${bin}:${process.env.PATH}`, ...options}, encoding: 'utf8', timeout: 10000}).trim();
  return {write, key, repository};
}

for (const [name, syntax] of [
  ['ordinary literal calls', {}],
  ['trailing comma import', {importSuffix: ','}],
  ['trailing comma embed', {embedSuffix: ','}],
  ['multiline trailing comma calls', {importSuffix: ' \n, \n', embedSuffix: ' \n, \n'}],
]) test(`compiled key selects transitive inputs for ${name}`, t => {
  const f = fixture(t, syntax), before = f.key();
  assert.match(before, /^protean-compiled-v3-[a-z0-9]+-[a-z0-9]+-safe-product-[a-f0-9]{64}$/);
  assert.equal(f.key(), before);
  f.write('tools/release/unrelated.mjs', 'export const version = 2;\n');
  assert.equal(f.key(), before, 'unrelated release edits must not invalidate compiled inputs');
  const child = readFileSync(join(f.repository, 'fixtures/child.zig'));
  f.write('fixtures/child.zig', `${child}\npub const changed = true;\n`);
  assert.notEqual(f.key(), before, 'transitive import changes must invalidate compiled inputs');
  f.write('fixtures/child.zig', child);
  assert.equal(f.key(), before);
  f.write('fixtures/payload.txt', 'changed payload\n');
  assert.notEqual(f.key(), before, 'transitive embed changes must invalidate compiled inputs');
});

for (const [name, extra] of [
  ['nonliteral import', 'const unknown = @import(module_name);\n'],
  ['nonliteral embed', 'const unknown = @embedFile("prefix" ++ "suffix");\n'],
  ['unknown module', 'const unknown = @import("unknown_module",);\n'],
  ['unknown embed', 'const unknown = @embedFile("unknown_asset",);\n'],
]) test(`compiled key retains all tracked inputs for ${name}`, t => {
  const f = fixture(t, {extra}), before = f.key();
  f.write('tools/release/unrelated.mjs', 'export const version = 2;\n');
  assert.notEqual(f.key(), before);
});

test('compiled key retains compiler and environment option identities', t => {
  const f = fixture(t), before = f.key();
  assert.notEqual(f.key('b'.repeat(64)), before);
  assert.notEqual(f.key(undefined, {ZIG_LIB_DIR: '/different/zig/lib'}), before);
});
