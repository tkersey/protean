import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {lstatSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, join, posix} from 'node:path';

const [operation, profile, argument, key] = process.argv.slice(2);
const profiles = {
  product: ['protean', [], null, ['executables/protean', 'protean/adaptive/application.json', 'protean/adaptive/program.bpi3']],
  owners: ['build-native-owner-tasks-check', [], 'native_owner_tests.zig', ['verification/native-owner-tasks']],
  'owner-adaptive-control': ['build-native-owner-adaptive-check', [], 'native_adaptive_tests.zig', ['verification/native-owner-adaptive']],
  workspace: ['build-workspace-general-check', ['-Dworkspace-group=execution'], 'workspace_programs.zig', ['verification/workspace-general']],
  'workspace-retention': ['build-workspace-general-check', ['-Dworkspace-group=retention'], 'workspace_programs.zig', ['verification/workspace-general']],
  'workspace-history': ['build-workspace-general-check', ['-Dworkspace-group=history'], 'workspace_programs.zig', ['verification/workspace-general']],
};
assert(Object.hasOwn(profiles, profile));
const [target, selection, testRoot, outputs] = profiles[profile];
const recipe = [target, ...selection, '-Doptimize=safe', '--summary', 'all', '--prefix-exe-dir', 'executables'];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const fileIdentity = file => {
  const stat = lstatSync(file);
  assert(stat.isFile(), file);
  return [stat.mode & 0o777, digest(readFileSync(file))];
};

if (operation === 'key') {
  assert(/^[0-9a-f]{64}$/.test(argument));
  const tracked = execFileSync('git', ['ls-files', '-z'], {encoding: 'utf8'}).split('\0').filter(Boolean);
  const files = new Set(['LICENSE', 'build.zig', 'build_protean.zig', 'build_native.zig', 'build.zig.zon', 'tools/native/qualification_build.mjs']);
  for (const file of tracked) {
    if (file.startsWith('src/') || file.startsWith('runtime/native/') || file.startsWith('conformance/protean/') ||
        (file.startsWith('tools/native/') && file.endsWith('.zig')) ||
        ((profile === 'product' || profile.startsWith('owner')) && file.startsWith('examples/adaptive/'))) files.add(file);
  }
  const modules = new Set(['std', 'builtin', 'root', 'protean', 'contracts', 'protean_contracts', 'horos', 'horos_data', 'kosmos', 'protean_native', 'adaptive_report', 'adaptive_types', 'adaptive_environment', 'native_asset_writer', 'native_c', 'native_options', 'hash_abi', 'environment', 'application_types', 'definition', 'construction', 'packaged_runtime', '_native_dependency_admission', '_protean_dependency_admission']);
  const generated = new Set(['adaptive_image', 'adaptive_application', 'native_image', 'native_application', 'native_manifest']);
  const pending = [...files].filter(file => file.endsWith('.zig') && file.includes('/')), visited = new Set();
  if (testRoot) pending.push(`test/protean/${testRoot}`);
  let conservative = false;
  while (pending.length) {
    const file = pending.pop();
    if (visited.has(file)) continue;
    visited.add(file);
    assert(tracked.includes(file), file);
    files.add(file);
    if (!file.endsWith('.zig')) continue;
    const source = readFileSync(file, 'utf8');
    const calls = [...source.matchAll(/@(import|embedFile)\s*\(\s*"([^"\\]*)"\s*\)/g)];
    if (calls.length !== [...source.matchAll(/@(import|embedFile)\b/g)].length) conservative = true;
    for (const [, kind, name] of calls) {
      const relative = posix.normalize(posix.join(dirname(file), name));
      if (tracked.includes(relative)) pending.push(relative);
      else if (!(kind === 'embedFile' ? generated : modules).has(name)) conservative = true;
    }
  }
  if (conservative) for (const file of tracked) files.add(file);
  const environment = execFileSync('zig', ['env'], {encoding: 'utf8'});
  const host = environment.match(/^\s*\.target = "([^"]+)",$/m)?.[1];
  assert(host);
  const options = Object.fromEntries(['ZIG_LIB_DIR', 'ZIG_LIBC', 'NIX_CFLAGS_COMPILE', 'NIX_CFLAGS_LINK', 'NIX_LDFLAGS', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH', 'CC', 'PKG_CONFIG'].map(name => [name, process.env[name] ?? null]));
  const nativeCapabilities = process.platform === 'linux' && process.arch === 'x64' ? null :
    digest(execFileSync('zig', ['targets'], {maxBuffer: 4 * 1024 * 1024}));
  const inputs = {compiler: argument, host, nativeCapabilities, options, recipe, files: [...files].sort().map(file => [file, ...fileIdentity(file)])};
  console.log(`protean-compiled-v3-${process.platform}-${process.arch}-safe-${profile}-${digest(JSON.stringify(inputs))}`);
} else if (operation === 'build') {
  const result = spawnSync('zig', ['build', ...recipe, '--prefix', argument], {stdio: 'inherit'});
  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
} else {
  assert(['seal', 'verify'].includes(operation));
  assert(key?.startsWith(`protean-compiled-v3-${process.platform}-${process.arch}-safe-${profile}-`));
  const value = {key, outputs: outputs.map(file => [file, ...fileIdentity(join(argument, file))])};
  assert(value.outputs.filter(([file, mode]) => file.startsWith('executables/') || file.startsWith('verification/')).every(([, mode]) => (mode & 0o111) !== 0));
  const manifest = join(argument, 'compiled-inputs.json');
  if (operation === 'seal') writeFileSync(manifest, JSON.stringify(value));
  else assert.deepEqual(JSON.parse(readFileSync(manifest, 'utf8')), value);
}
