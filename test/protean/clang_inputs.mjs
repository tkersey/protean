import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const [cache] = process.argv.slice(2);
const buildFile = fileURLToPath(new URL('../../tools/native/clang.zig', import.meta.url));
const dir = mkdtempSync(join(tmpdir(), 'protean-clang-inputs-'));
const installed = join(dir, 'probe.o');
const header = join(dir, 'value.h');
const compile = () => {
  const result = spawnSync(process.env.PROTEAN_ZIG_EXE, ['build', '--build-file', buildFile,
    'build-clang-probe', '-Dclang-probe-source=' + join(dir, 'alias', 'probe.c'), '--prefix', dir,
    '--cache-dir', resolve(cache), '-j2'], {encoding: 'utf8'});
  if (result.error) throw result.error;
  return result;
};
const success = () => {
  const result = compile();
  assert.equal(result.status, 0, result.stderr);
  const path = result.stdout.trim();
  assert.ok(isAbsolute(path), 'probe must report its compiler-owned object');
  assert.deepEqual(readFileSync(path), readFileSync(installed));
  return path;
};
const identity = path => {
  const {ino, mtimeNs} = statSync(path, {bigint: true});
  return {ino, mtimeNs, bytes: readFileSync(path)};
};
try {
  symlinkSync('.', join(dir, 'alias'), 'dir');
  writeFileSync(join(dir, 'outer.h'), '#include "value.h"\n');
  writeFileSync(join(dir, 'probe.c'), '#include "outer.h"\nint probe(void) { return VALUE; }\n');
  writeFileSync(header, '#define VALUE 7\n');
  const first = success();
  const initial = identity(first);
  assert.equal(success(), first);
  assert.deepEqual(identity(first), initial);
  writeFileSync(header, '#define VALUE 12345\n');
  const second = success();
  const changed = identity(second);
  assert.notEqual(second, first);
  assert.notDeepEqual(changed.bytes, initial.bytes, 'header-only change must reach code generation');
  assert.deepEqual(identity(first), initial);
  writeFileSync(header, '#error intentional_invalid_clang_input\n');
  const failure = compile();
  assert.notEqual(failure.status, 0);
  assert.match(failure.stderr, /intentional_invalid_clang_input/);
  assert.deepEqual(identity(first), initial);
  assert.deepEqual(identity(second), changed, 'failed compilation changed the last valid object');
} finally {
  rmSync(dir, {recursive: true, force: true});
}
