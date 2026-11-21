import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, realpathSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const [cache] = process.argv.slice(2);
const dir = realpathSync(mkdtempSync(join(tmpdir(), 'protean-clang-inputs-')));
const object = join(dir, 'probe.o');
const header = join(dir, 'value.h');
const compile = () => {
  const result = spawnSync(process.env.PROTEAN_ZIG_EXE, ['build', 'build-clang-probe', '-Dnative=false',
    '-Dclang-probe-source=' + join(dir, 'probe.c'), '--prefix', dir, '--cache-dir', cache, '-j2'],
  {encoding: 'utf8'});
  if (result.error) throw result.error;
  return result;
};
const success = () => {
  const result = compile();
  assert.equal(result.status, 0, result.stderr);
};
const identity = () => {
  const {ino, mtimeNs} = statSync(object, {bigint: true});
  return {ino, mtimeNs, bytes: readFileSync(object)};
};
try {
  writeFileSync(join(dir, 'outer.h'), '#include "value.h"\n');
  writeFileSync(join(dir, 'probe.c'), '#include "outer.h"\nint probe(void) { return VALUE; }\n');
  writeFileSync(header, '#define VALUE 7\n');
  success();
  const initial = identity();
  success();
  assert.deepEqual(identity(), initial, 'unchanged Clang output must retain its identity');
  writeFileSync(header, '#define VALUE 12345\n');
  success();
  const changed = identity();
  assert.notDeepEqual(changed.bytes, initial.bytes, 'a header-only change must reach code generation');
  writeFileSync(header, '#error intentional_invalid_clang_input\n');
  const failure = compile();
  assert.notEqual(failure.status, 0);
  assert.match(failure.stderr, /intentional_invalid_clang_input/);
  assert.deepEqual(identity(), changed, 'a failed compilation must preserve the published object');
} finally {
  rmSync(dir, {recursive: true, force: true});
}
