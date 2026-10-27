// Independent downstream build witness. The controller uses Node; every
// acquisition/build/install command runs behind a native executable allowlist.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {basename, dirname, join, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import {ProteanClient} from '../support/stdio-client.mts';

const usage = 'usage: installations.mjs [ARCHIVE_SEED_DIRECTORY [REFERENCE_EXECUTABLE]]';
if (process.argv.length === 3 && process.argv[2] === '--help') { console.log(usage); process.exit(0); }
if (process.argv.length > 4 || process.argv.slice(2).some(arg => arg.startsWith('-'))) throw new Error(usage);

const root = resolve(import.meta.dirname, '../..');
// Linux CI reserves its final minute for identity publication and cleanup.
// macOS runs the same correctness checks without a wall-time performance gate.
const deadline = process.platform === 'linux' ? performance.now() + 540_000 : null;
const zig = realpathSync(process.env.PROTEAN_ZIG_EXE ?? execFileSync('which', ['zig'], {encoding: 'utf8'}).trim());
const description = execFileSync(zig, ['env'], {encoding: 'utf8'});
const library = realpathSync(JSON.parse(description.match(/^\s*\.lib_dir = (".*"),$/m)?.[1] ?? 'null'));
assert.equal(execFileSync(zig, ['version'], {encoding: 'utf8'}).trim(), '0.17.0');
const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'Protean downstream ü ')));
const cache = resolve(process.env.ZIG_GLOBAL_CACHE_DIR ?? join(scratch, 'global-cache'));
const local = join(cache, 'downstream-local');
const inputs = join(scratch, 'inputs');
const sandboxPath = value => process.platform === 'linux' ? value.replaceAll(scratch, '/tmp/Protean downstream ü') : value;
mkdirSync(cache, {recursive: true}); mkdirSync(local, {recursive: true}); mkdirSync(inputs);
// Package managers may expose the selected library through a directory link.
const libraryAlias = join(scratch, 'selected-zig-lib');
symlinkSync(library, libraryAlias, 'dir');
const env = {...process.env, PATH: '/usr/bin:/bin', ZIG_GLOBAL_CACHE_DIR: sandboxPath(cache), ZIG_LOCAL_CACHE_DIR: sandboxPath(local), ZIG_LIB_DIR: sandboxPath(libraryAlias)};
delete env.NODE_OPTIONS; delete env.NODE_TEST_CONTEXT; delete env.TAR_OPTIONS;
let prefix;
if (process.platform === 'darwin') {
  const profile = join(scratch, 'build.sb');
  // Zig discovers the installed macOS SDK through these native system tools.
  // Denying them changes compiler bootstrap behavior inside this fixture.
  writeFileSync(profile, `(version 1)\n(allow default)\n(deny process-exec)\n(allow process-exec (literal ${JSON.stringify(zig)}) (literal ${JSON.stringify(realpathSync("/usr/bin/tar"))}) (literal "/usr/bin/unzip") (literal "/usr/bin/xcode-select") (literal "/usr/bin/xcrun") (subpath ${JSON.stringify(scratch)}) (subpath ${JSON.stringify(cache)}))\n`);
  prefix = ['/usr/bin/sandbox-exec', '-f', profile];
} else if (process.platform === 'linux') {
  prefix = ['/usr/bin/bwrap', '--unshare-user', '--die-with-parent', '--new-session', '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp'];
  for (const path of ['/usr/lib', '/lib', '/lib64', '/etc/ssl', '/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf', '/usr/bin/tar', '/usr/bin/gzip', '/usr/bin/unzip', zig, library, root])
    if (existsSync(path)) prefix.push('--ro-bind', path, path);
  // Native metadata reads Zig's license beside its executable or library.
  // Expose those regular sidecar files without mounting an executable directory.
  for (const path of new Set([join(dirname(zig), 'LICENSE'), resolve(dirname(zig), '../LICENSE'), resolve(library, '../LICENSE'), resolve(library, '../../LICENSE')]))
    if (lstatSync(path, {throwIfNoEntry: false})?.isFile()) prefix.push('--ro-bind', path, path);
  prefix.push('--bind', scratch, sandboxPath(scratch));
  if (!cache.startsWith(scratch + '/')) prefix.push('--bind', cache, cache);
} else throw new Error('unsupported downstream qualification platform');

function run(executable, args, cwd = scratch, {failure = false, diagnostic, timeout = 300000} = {}) {
  timeout = deadline === null ? undefined : Math.min(timeout, Math.floor(deadline - performance.now()));
  assert(timeout === undefined || timeout > 0, 'independent installation exceeded its nine-minute budget');
  const command = [...prefix, ...(process.platform === 'linux' ? ['--chdir', sandboxPath(cwd)] : []), sandboxPath(executable), ...args.map(sandboxPath)];
  const operation = `${basename(executable)} ${args[0] ?? ''}${failure ? ' negative' : ''}`;
  const started = performance.now();
  console.error(`downstream ${operation}: started`);
  const result = spawnSync(command[0], command.slice(1), {cwd, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout});
  console.error(`downstream ${operation}: ${Math.round(performance.now() - started)} ms, status ${result.status}, signal ${result.signal}`);
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
  for (const name of [`horos-${lock.boundary.commit}.tar.gz`, `kosmos-${lock.world.commit}.tar.gz`, `${sqlite.archive.root}.zip`])
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
  assert.match(packageHash, /^protean-7\.0\.0-[A-Za-z0-9_-]+$/);
  const packageDir = join(scratch, 'package'); mkdirSync(packageDir);
  run('/usr/bin/tar', ['-xzf', join(cache, 'p', `${packageHash}.tar.gz`), '-C', packageDir]);
  const source = join(packageDir, 'source');
  renameSync(join(packageDir, packageHash), source);
  assert(existsSync(join(source, 'build.zig')));
  // Resolve the native qualifier's full module graph from the published bytes.
  // Loading its fixture helpers performs no provider or native execution.
  await import(pathToFileURL(join(source, 'test/protean/adaptive_native_peer.mjs')).href);
  for (const retired of ['runtime/model.mjs', 'runtime/mobility', 'examples/native-minimal', 'examples/repository-agent', 'tools/agent4/setup.mjs'])
    assert(!existsSync(join(source, retired)), `retired package member: ${retired}`);
  const consumer = scratch;
  copyFileSync(join(root, 'test/consumers/adaptive/build.zig'), join(consumer, 'build.zig'));
  const zon = readFileSync(join(root, 'test/consumers/adaptive/build.zig.zon'), 'utf8').replace('.path = "../../.."', '.path = "package/source"');
  writeFileSync(join(consumer, 'build.zig.zon'), zon);
  const prefixDir = join(scratch, 'installed');
  const buildArgs = ['build', '-Doptimize=safe', `-Dkosmos-source=${join(inputs, 'kosmos')}`, `-Dsqlite-source=${join(inputs, 'sqlite')}`, '--prefix', prefixDir, '--prefix-exe-dir', 'executables', '--summary', 'all'];
  run(zig, buildArgs, consumer, {timeout: 480_000});
  // The actual exported module graph must stop on either a changed package or
  // a changed native source override, before compiling/claiming new assets.
  for (const path of [join(consumer, 'zig-pkg', lock.boundary.package.zigHash, 'src/root.zig'), join(inputs, 'kosmos/src/root.zig')]) {
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
  const identity = Object.fromEntries(['program_sha256', 'application_assets_sha256', 'dependencies', 'compiler', 'target'].map(key => [key, manifest[key]]));
  const reference = process.argv[3];
  if (reference) {
    const expected = JSON.parse(execFileSync(resolve(reference), ['describe-build'], {encoding: 'utf8'}));
    for (const key of Object.keys(identity)) assert.deepEqual(identity[key], expected[key], key);
  }
  const launch = join(scratch, 'installed-launch');
  const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
  const command = [...prefix, ...(process.platform === 'linux' ? ['--chdir', sandboxPath(scratch)] : []), sandboxPath(executable)];
  writeFileSync(launch, `#!/bin/sh\nexec ${command.map(quote).join(' ')} "$@"\n`, {mode: 0o700});
  const client = new ProteanClient(launch, ['--offline', '--state-dir', sandboxPath(join(scratch, 'state'))], {cwd: scratch, env});
  const executionDeadline = Math.min(performance.now() + 30_000, deadline ?? Infinity);
  const request = (method, params) => {
    const remaining = Math.floor(executionDeadline - performance.now());
    assert(remaining > 0, 'installed execution exceeded its bounded witness budget');
    return client.call(method, params, remaining);
  };
  const executionStarted = performance.now();
  let installedExecution;
  try {
    const initialized = await request('initialize', {protocol_versions: ['agent-host/2.1'], client_info: {name: 'installed-witness', version: '1'}});
    assert.equal(initialized.protocol_version, 'agent-host/2.1');
    const description = await request('describe');
    const task = await request('task.submit', {client_operation_id: 'installed-start', application_id: 'adaptive-agent', profile_id: description.profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Exercise the independently installed application.'}}});
    let current;
    do {
      current = await request('task.status', {task_id: task.task_id});
      assert.equal(current.blocker, null);
      assert.equal(current.result_available, false);
      if (BigInt(current.revision) > BigInt(task.revision)) break;
      await new Promise(resolve => setTimeout(resolve, 20));
    } while (true);
    await request('task.cancel', {client_operation_id: 'installed-cancel', task_id: task.task_id});
    let cancelled;
    do {
      cancelled = await request('task.result', {task_id: task.task_id});
      if (cancelled.ready && cancelled.associated_work_disposed) break;
      await new Promise(resolve => setTimeout(resolve, 20));
    } while (true);
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(cancelled.outcome.cleanup_complete, true);
    assert.deepEqual(await client.close(), {code: 0, signal: null});
    installedExecution = {admission_revision: task.revision, execution_revision: current.revision, cancellation_revision: cancelled.revision, elapsed_ms: performance.now() - executionStarted};
    console.error(`downstream installed execution: ${Math.round(installedExecution.elapsed_ms)} ms`);
  } finally { await client.close(); }
  console.log(JSON.stringify({downstream: 'public addNativeSystem', node_free_acquisition_build_install: true, package: packageHash, target: manifest.target, program: manifest.program_sha256, identity, installed_execution: installedExecution, elapsed_seconds: (performance.now() - started) / 1000}));
} finally {
  rmSync(scratch, {recursive: true, force: true});
}
