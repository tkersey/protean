import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {manifestOperations} from './protean-native-manifest.mjs';
import {sha256} from './encoding.mjs';

function fixture(t, mutation = value => value) {
  const root = mkdtempSync(join(tmpdir(), 'protean-native-parser-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const bytes = Buffer.from('.{ .version = "8.0.0", .minimum_zig_version = "0.17.0" }');
  const result = mutation({version: '8.0.0', minimumCompiler: '0.17.0', sha256: sha256(bytes)});
  const path = join(root, 'parser');
  writeFileSync(path, `#!/bin/sh\nset -eu\ntest "$1" = manifest-version\ntest -f "$2"\ntest -z "\${GH_TOKEN-}"\ntest -z "\${GITHUB_TOKEN-}"\ntest -z "\${REPOSITORY_APP_PRIVATE_KEY-}"\nprintf '%s' '${JSON.stringify(result)}'\n`, {mode: 0o700});
  return {path, bytes, native: manifestOperations(path)};
}

test('version parser wrapper binds native result bytes and strips write credentials', t => {
  const f = fixture(t), old = process.env.GH_TOKEN;
  process.env.GH_TOKEN = 'synthetic writer credential';
  try {assert.equal(f.native.read(f.bytes), '8.0.0');}
  finally {if (old === undefined) delete process.env.GH_TOKEN; else process.env.GH_TOKEN = old;}
});

for (const [name, mutation] of [
  ['changed manifest', value => ({...value, sha256: 'f'.repeat(64)})],
  ['wrong compiler', value => ({...value, minimumCompiler: '0.16.0'})],
  ['invalid version', value => ({...value, version: '08.0.0'})],
]) test(`version parser refuses ${name}`, t => {
  const f = fixture(t, mutation); assert.throws(() => f.native.read(f.bytes));
});

test('version parser checks its accepted binary on every invocation', t => {
  const f = fixture(t); writeFileSync(f.path, '#!/bin/sh\nexit 0\n');
  assert.throws(() => f.native.read(f.bytes), /trusted native parser changed/);
});
