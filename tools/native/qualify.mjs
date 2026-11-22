import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {availableParallelism, totalmem} from 'node:os';
import {basename, dirname, join, resolve} from 'node:path';
import {runQualificationCommand} from './qualification_process.mjs';
import {acquireWorkspace, gitEnvironment} from './qualification_workspace.mjs';

const started = performance.now();
const budget = 600_000;
const [cacheArg, globalArg, network, ...options] = process.argv.slice(2);
const zig = process.env.PROTEAN_ZIG_EXE;
const mac = process.platform === 'darwin' && process.arch === 'arm64';
const linux = process.platform === 'linux' && process.arch === 'x64';
assert(mac || linux, 'qualification requires an arm64 macOS or x86-64 Linux host');
assert(zig && cacheArg && globalArg && ['online', 'offline'].includes(network), 'invoke zig build qualify');
const localCache = resolve(cacheArg), globalCache = resolve(globalArg);
const env = gitEnvironment({...process.env, ZIG_GLOBAL_CACHE_DIR: globalCache});
delete env.ZIG_PROGRESS;
delete env.ZIG_LOCAL_PKG_DIR;
const listing = options.length === 1 && options[0] === '--list';
const selection = options.length === 2 && options[0] === '--group' ? options[1].split(',') : null;
assert(options.length === 0 || listing || selection?.every(Boolean),
  'usage: zig build qualify [-- --list | -- --group NAME[,NAME...]]');
const source = realpathSync(resolve(import.meta.dirname, '../..'));
const seconds = ms => (ms / 1000).toFixed(3) + 's';
const inputs = '.protean-native/inputs';
const controller = new AbortController();
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'])
  process.once(signal, () => controller.abort(new Error(signal)));

function sharedDeadline() {
  let pid = process.ppid, age = 0;
  while (pid > 1) {
    let row;
    try { row = execFileSync('ps', ['-p', String(pid), '-o', 'ppid=,etime=,comm='], {encoding: 'utf8'}).trim(); }
    catch { break; }
    const match = row.match(/^(\d+)\s+([\d:-]+)\s+(.+)$/);
    if (!match || !['zig', 'maker', basename(zig)].includes(basename(match[3]))) break;
    const [time, days] = match[2].split('-').reverse();
    age = (Number(days ?? 0) * 86400 + time.split(':').reduce((a, b) => a * 60 + Number(b), 0) + 1) * 1000;
    pid = Number(match[1]);
  }
  return started + budget - age;
}
const deadline = sharedDeadline();
// Elapsed time is reported from the same origin as the deadline: the zig build invocation.
const origin = deadline - budget;
const identityKeys = ['program_sha256', 'application_assets_sha256', 'dependencies', 'compiler', 'target',
  'artifact_zig_backend'];
const git = (cwd, ...args) => execFileSync('git', ['-c', 'core.hooksPath=/dev/null', '-C', cwd, ...args],
  {env, encoding: 'utf8', timeout: Math.max(1, Math.ceil(Math.min(budget, deadline - performance.now())))}).trimEnd();
const clean = cwd => assert.equal(git(cwd, 'status', '--porcelain', '--untracked-files=all',
  '--ignore-submodules=none'), '', 'qualification requires the complete committed candidate');

function checkout(directory, candidate) {
  const work = join(directory, 'source');
  const prepare = () => {
    // Own every object: the source can be replaced at the same path between runs.
    if (!existsSync(join(work, '.git', 'HEAD')) || existsSync(join(work, '.git', 'objects', 'info', 'alternates'))) {
      rmSync(work, {recursive: true, force: true});
      git(directory, '-c', 'init.defaultBranch=qualification', 'init', '--quiet', '--template=', '--', work);
    }
    git(work, 'fetch', '--quiet', '--no-tags', '--update-shallow', '--', source, '+HEAD:refs/qualification/candidate');
    assert.equal(git(work, 'rev-parse', 'refs/qualification/candidate'), candidate, 'source HEAD moved');
    // Committed bytes, not the caller's line-ending or filter configuration.
    mkdirSync(join(work, '.git', 'info'), {recursive: true});
    writeFileSync(join(work, '.git', 'info', 'attributes'), '* -text -eol -filter -ident\n');
    git(work, 'clean', '-ffd');
    git(work, 'checkout', '--quiet', '--force', '--detach', candidate);
    assert.equal(git(work, 'rev-parse', 'HEAD'), candidate);
    clean(work);
  };
  try { prepare(); }
  catch (error) {
    // An interrupted run can leave locks or partial state; rebuild the slot once.
    if (error.message === 'source HEAD moved') throw error;
    console.warn('Rebuilding qualification checkout:', error.message.split('\n')[0]);
    rmSync(work, {recursive: true, force: true});
    prepare();
  }
  return work;
}

function seedArchives(work) {
  const read = file => JSON.parse(readFileSync(join(work, 'conformance/protean', file)));
  const lock = read('dependencies.lock.json'), native = read('native-dependencies.lock.json');
  mkdirSync(join(work, inputs), {recursive: true});
  for (const file of [`horos-${lock.boundary.commit}.tar.gz`, `kosmos-${lock.world.commit}.tar.gz`,
    native.sqlite.archive.root + '.zip']) {
    const origin = join(source, inputs, file), target = join(work, inputs, file);
    if (existsSync(target) || !existsSync(origin)) continue;
    // A seed interrupted mid-copy must not leave a partial archive at the final path.
    const partial = target + '.partial-' + process.pid;
    copyFileSync(origin, partial);
    renameSync(partial, target);
  }
}

function inventory(work, prefix) {
  const directPrefix = join(prefix, 'direct');
  const direct = ['-Dtarget=x86_64-linux-musl', '-Dnative-direct=true'];
  const offline = network === 'offline' ? ['--system', join(work, 'zig-pkg')] : [];
  // The largest compile steps peak near 3 GiB.
  const jobs = Math.max(1, Math.min(availableParallelism(), Math.floor(totalmem() / 3 / 2 ** 30)));
  const buildIn = (dest, ...targets) => [zig, 'build', ...targets, '-Doptimize=safe', '-j' + jobs, '--prefix',
    dest, '--cache-dir', localCache, '--summary', 'all', ...offline];
  const build = (...targets) => buildIn(prefix, ...targets);
  const smoke = (root, backend) => [process.execPath, 'test/protean/native_adaptive.mjs', join(root, 'bin/protean'),
    join(root, 'protean/adaptive/application.json'), join(root, 'protean/adaptive/program.bpi3'), 'smoke', backend];
  const commands = new Map();
  const add = (name, command, needs = []) => commands.set(name, {name, command, needs});
  add('tigerstyle', ['bash', 'tools/tiger-style.sh', '--all', 'HEAD']);
  add('tigerstyle-integration', ['bash', 'tools/test-tiger-style.sh',
    ...(selection?.includes('tigerstyle-integration') ? [] : ['--if-changed', localCache])]);
  add('setup', [zig, 'run', 'tools/native/dependencies.zig', '--cache-dir', localCache, '--', 'setup',
    'conformance/protean/dependencies.lock.json', 'conformance/protean/native-dependencies.lock.json',
    inputs, zig, ...(network === 'offline' ? ['--offline'] : [])]);
  add('authoring-https', build('check-protean', 'check-native-https'), ['setup']);
  add('product', build('protean'), ['setup']);
  if (mac) add('native-build-and-tests', build('protean', 'check-protean', 'check-native-https'), ['setup']);
  if (linux) {
    add('direct-product', buildIn(directPrefix, 'protean', 'check-native-direct-hash', ...direct), ['setup']);
    add('direct-smoke', smoke(directPrefix, 'stage2_x86_64'), ['direct-product']);
  }
  add('native-smoke', smoke(prefix, 'stage2_llvm'), ['product']);
  add('native-placement', [process.execPath, 'test/protean/native_placement.mjs', join(prefix, 'bin/protean')], ['product']);
  add('downstream-identity', [process.execPath, 'test/protean/installations.mjs', inputs, join(prefix, 'bin/protean')], ['product']);
  add('downstream', [process.execPath, 'test/protean/installations.mjs', inputs], ['setup']);
  const full = ['tigerstyle', 'tigerstyle-integration', 'setup', ...(mac ? ['native-build-and-tests'] :
    ['authoring-https', 'product', 'direct-product', 'direct-smoke']), 'native-smoke', 'native-placement', 'downstream-identity'];
  return {commands, full};
}

function selected(commands, names) {
  const result = new Set();
  function include(group) {
    assert(commands.has(group), 'unknown qualification group: ' + group);
    if (result.has(group)) return;
    for (const prerequisite of commands.get(group).needs) include(prerequisite);
    result.add(group);
  }
  names.forEach(include);
  return [...result];
}

if (listing) {
  const {commands, full} = inventory(source, '');
  console.log('Full qualification:', full.join(', '));
  for (const name of commands.keys()) console.log('--group', name, 'runs', selected(commands, [name]).join(', '));
  process.exit(0);
}

let lease, pending = [], passed = 0, skipped = 0;
const ran = new Set();
try {
  const candidate = git(source, 'rev-parse', '--verify', 'HEAD^{commit}');
  clean(source);
  env.PROTEAN_QUALIFICATION_COMMIT = candidate;
  env.PROTEAN_QUALIFICATION_GIT_SOURCE = source;
  const key = createHash('sha256').update(source).digest('hex');
  const slots = join(globalCache, 'protean-qualification', key);
  lease = acquireWorkspace(slots, 'run');
  const directory = join(slots, 'checkout-' + lease.slot);
  mkdirSync(directory, {recursive: true});
  const work = checkout(directory, candidate);
  const {commands, full} = inventory(work, lease.path);
  pending = selection ? selected(commands, selection) : [...full];
  console.log('Protean local qualification', candidate, process.platform, process.arch,
    '600s shared');
  while (pending.length) {
    const name = pending[0], [program, ...args] = commands.get(name).command;
    const start = performance.now();
    const conditional = name === 'tigerstyle-integration' && !selection?.includes(name);
    if (name === 'setup') seedArchives(work);
    console.log('Starting', name);
    const code = await runQualificationCommand(program, args, {cwd: work, env, signal: controller.signal,
      deadline, allowedExitCodes: conditional ? [0, 77] : [0]});
    if (code === 77) { skipped++; console.log('Skipped', name, '(launcher inputs unchanged)'); }
    else { passed++; console.log('Passed', name, seconds(performance.now() - start)); }
    ran.add(name);
    pending.shift();
  }
  const identityPath = process.env.PROTEAN_PRODUCT_IDENTITY;
  if (identityPath && (ran.has('product') || ran.has('native-build-and-tests'))) {
    // CI compares this product's identity with the independently built downstream consumer.
    const manifest = JSON.parse(execFileSync(join(lease.path, 'bin/protean'), ['describe-build'], {encoding: 'utf8'}));
    writeFileSync(identityPath, JSON.stringify(Object.fromEntries(identityKeys.map(key => [key, manifest[key]]))));
  }
  clean(work);
  assert.equal(git(work, 'rev-parse', 'HEAD'), candidate, 'qualification checkout changed');
  lease.release();
  lease = undefined;
  controller.signal.throwIfAborted();
  assert(performance.now() < deadline, 'deadline exceeded');
  console.log(selection ? 'Selected groups passed:' : 'Qualified', selection?.join(', ') ?? candidate);
} catch (error) {
  console.error(error.message);
  console.error('Incomplete qualification. Remaining groups:', pending.join(', '));
  process.exitCode = 1;
} finally {
  lease?.release();
  console.log('Passed', passed, 'groups, skipped', skipped, 'in', seconds(performance.now() - origin),
    'since zig build started');
}
