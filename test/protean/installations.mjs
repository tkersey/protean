// Independent downstream build witness. The controller uses Node; every
// acquisition/build/install command runs behind a native executable allowlist.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {tmpdir} from 'node:os';

const usage = 'usage: installations.mjs [ARCHIVE_SEED_DIRECTORY [REFERENCE_EXECUTABLE]]';
if (process.argv.length === 3 && process.argv[2] === '--help') { console.log(usage); process.exit(0); }
if (process.argv.length > 4 || process.argv.slice(2).some(arg => arg.startsWith('-'))) throw new Error(usage);

const root = resolve(import.meta.dirname, '../..');
const zig = realpathSync(process.env.PROTEAN_ZIG_EXE ?? execFileSync('which', ['zig'], {encoding: 'utf8'}).trim());
const description = execFileSync(zig, ['env'], {encoding: 'utf8'});
const library = realpathSync(JSON.parse(description.match(/^\s*\.lib_dir = (".*"),$/m)?.[1] ?? 'null'));
assert.equal(execFileSync(zig, ['version'], {encoding: 'utf8'}).trim(), '0.17.0');
const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'Protean downstream ü ')));
const cache = resolve(process.env.ZIG_GLOBAL_CACHE_DIR ?? join(scratch, 'global-cache'));
const local = join(scratch, 'local-cache'), inputs = join(scratch, 'inputs');
mkdirSync(cache, {recursive: true}); mkdirSync(local); mkdirSync(inputs);
// Package managers may expose the selected library through a directory link.
const libraryAlias = join(scratch, 'selected-zig-lib');
symlinkSync(library, libraryAlias, 'dir');
const env = {...process.env, PATH: '/usr/bin:/bin', ZIG_GLOBAL_CACHE_DIR: cache, ZIG_LOCAL_CACHE_DIR: local, ZIG_LIB_DIR: libraryAlias};
delete env.NODE_OPTIONS; delete env.NODE_TEST_CONTEXT; delete env.TAR_OPTIONS;
let prefix;
if (process.platform === 'darwin') {
  const profile = join(scratch, 'build.sb');
  writeFileSync(profile, `(version 1)\n(allow default)\n(deny process-exec)\n(allow process-exec (literal ${JSON.stringify(zig)}) (literal ${JSON.stringify(realpathSync("/usr/bin/tar"))}) (literal "/usr/bin/unzip") (subpath ${JSON.stringify(scratch)}) (subpath ${JSON.stringify(cache)}))\n`);
  prefix = ['/usr/bin/sandbox-exec', '-f', profile];
} else if (process.platform === 'linux') {
  prefix = ['/usr/bin/bwrap', '--unshare-user', '--die-with-parent', '--new-session', '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp'];
  for (const path of ['/usr/lib', '/lib', '/lib64', '/etc/ssl', '/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf', '/usr/bin/tar', '/usr/bin/gzip', '/usr/bin/unzip', zig, library, root])
    if (existsSync(path)) prefix.push('--ro-bind', path, path);
  // Native metadata reads Zig's license beside its executable or library.
  // Expose those regular sidecar files without mounting an executable directory.
  for (const path of new Set([join(dirname(zig), 'LICENSE'), resolve(dirname(zig), '../LICENSE'), resolve(library, '../LICENSE'), resolve(library, '../../LICENSE')]))
    if (lstatSync(path, {throwIfNoEntry: false})?.isFile()) prefix.push('--ro-bind', path, path);
  prefix.push('--bind', scratch, scratch);
  if (!cache.startsWith(scratch + '/')) prefix.push('--bind', cache, cache);
} else throw new Error('unsupported downstream qualification platform');

function run(executable, args, cwd = scratch, {failure = false, diagnostic, timeout = 300000} = {}) {
  const command = [...prefix, ...(process.platform === 'linux' ? ['--chdir', cwd] : []), executable, ...args];
  const result = spawnSync(command[0], command.slice(1), {cwd, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout});
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.signal, null, result.stderr);
  if (failure) {
    assert.notEqual(result.status, 0, 'negative witness unexpectedly succeeded');
    if (diagnostic) assert(result.stderr.includes(diagnostic), result.stderr);
  } else assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

try {
  // An absolute interpreter path also fails, not only PATH lookup.
  run(process.execPath, ['--version'], scratch, {failure: true});
  if (existsSync('/usr/bin/python3')) run('/usr/bin/python3', ['--version'], scratch, {failure: true});
  const sourceLock = join(root, 'conformance/protean/dependencies.lock.json');
  const nativeLock = join(root, 'conformance/protean/native-dependencies.lock.json');
  const lock = JSON.parse(readFileSync(sourceLock)), sqlite = JSON.parse(readFileSync(nativeLock)).sqlite;
  // Cached transport bytes are optional and remain untrusted until native setup
  // authenticates them. No source or pre-generated manifest is copied.
  const seed = resolve(process.argv[2] ?? join(root, '.protean-native/inputs'));
  for (const name of [`horos-${lock.boundary.commit}.tar.gz`, `kronos-${lock.world.commit}.tar.gz`, `${sqlite.archive.root}.zip`])
    if (existsSync(join(seed, name))) copyFileSync(join(seed, name), join(inputs, name));
  const started = performance.now();
  run(zig, ['run', join(root, 'tools/native/dependencies.zig'), '--', 'setup', sourceLock, nativeLock, inputs, zig]);
  // Export declared source from the working candidate, excluding ignored local
  // stores/caches and their sockets. Zig still owns the package and its hash.
  const exportRoot = join(scratch, 'source'); mkdirSync(exportRoot);
  const declared = [...readFileSync(join(root, 'build.zig.zon'), 'utf8').split('.paths = .{')[1].split('},')[0].matchAll(/"([^"]+)"/g)].map(match => match[1]);
  const sourceFiles = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], {cwd: root}).toString().split('\0').filter(Boolean);
  for (const file of sourceFiles) if (declared.some(path => file === path || file.startsWith(path + '/')) && existsSync(join(root, file))) {
    const target = join(exportRoot, file); mkdirSync(dirname(target), {recursive: true}); copyFileSync(join(root, file), target);
  }
  const packageHash = run(zig, ['fetch', exportRoot]);
  assert.match(packageHash, /^protean-4\.0\.0-dev\.0-[A-Za-z0-9_-]+$/);
  const packageDir = join(scratch, 'package'); mkdirSync(packageDir);
  run('/usr/bin/tar', ['-xzf', join(cache, 'p', `${packageHash}.tar.gz`), '-C', packageDir]);
  const source = join(packageDir, packageHash);
  assert(existsSync(join(source, 'build.zig')));
  for (const retired of ['runtime/model.mjs', 'runtime/mobility', 'examples/native-minimal', 'examples/repository-agent', 'tools/agent4/setup.mjs'])
    assert(!existsSync(join(source, retired)), `retired package member: ${retired}`);
  const consumer = join(scratch, 'consumer'); mkdirSync(consumer);
  copyFileSync(join(root, 'test/consumers/adaptive/build.zig'), join(consumer, 'build.zig'));
  const zon = readFileSync(join(root, 'test/consumers/adaptive/build.zig.zon'), 'utf8').replace('.path = "../../.."', `.path = "../package/${packageHash}"`);
  writeFileSync(join(consumer, 'build.zig.zon'), zon);
  const prefixDir = join(scratch, 'installed');
  const buildArgs = ['build', '-Doptimize=safe', `-Dkronos-source=${join(inputs, 'kronos')}`, `-Dsqlite-source=${join(inputs, 'sqlite')}`, '--prefix', prefixDir, '--prefix-exe-dir', 'executables', '--summary', 'all'];
  run(zig, buildArgs, consumer);
  // The actual exported module graph must stop on either a changed package or
  // a changed native source override, before compiling/claiming new assets.
  for (const path of [join(consumer, 'zig-pkg', lock.boundary.package.zigHash, 'src/root.zig'), join(inputs, 'kronos/src/root.zig')]) {
    const original = readFileSync(path);
    try {
      writeFileSync(path, Buffer.concat([original, Buffer.from('\n// changed after admission\n')]));
      run(zig, buildArgs, consumer, {failure: true, diagnostic: 'IdentityMismatch'});
    } finally { writeFileSync(path, original); }
  }
  const executable = join(prefixDir, 'executables/protean');
  const manifest = JSON.parse(run(executable, ['describe-build']));
  assert.equal(manifest.application_id, 'adaptive-agent');
  assert.equal(manifest.dependencies.world, lock.world.commit);
  assert.equal(manifest.dependencies.boundary, lock.boundary.commit);
  const reference = process.argv[3];
  if (reference) {
    const expected = JSON.parse(execFileSync(resolve(reference), ['describe-build'], {encoding: 'utf8'}));
    for (const key of ['program_sha256', 'application_assets_sha256', 'dependencies', 'compiler', 'target']) assert.deepEqual(manifest[key], expected[key], key);
  }
  const demo = JSON.parse(run(executable, ['demo', '--offline', '--state-dir', join(scratch, 'state')]));
  assert.equal(demo.output.disposition, 'report');
  assert.equal(demo.output.model_calls, 14);
  console.log(JSON.stringify({downstream: 'public addNativeSystem', node_free_acquisition_build_install: true, package: packageHash, target: manifest.target, program: manifest.program_sha256, elapsed_seconds: (performance.now() - started) / 1000}));
} finally {
  rmSync(scratch, {recursive: true, force: true});
}
