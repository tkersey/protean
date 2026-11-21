import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {mkdtempSync, realpathSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';

const started = performance.now();
const budget = 600_000;
const [localCache, globalCache, adaptiveGroups, workspaceGroups, ...options] = process.argv.slice(2);
const zig = process.env.PROTEAN_ZIG_EXE;
const mac = process.platform === 'darwin' && process.arch === 'arm64';
const linux = process.platform === 'linux' && process.arch === 'x64';
assert(mac || linux, 'qualification requires an arm64 macOS or x86-64 Linux host');
assert(zig && localCache && globalCache && adaptiveGroups && workspaceGroups, 'invoke zig build qualify');
const env = {...process.env, PATH: dirname(zig) + ':' + process.env.PATH, ZIG_GLOBAL_CACHE_DIR: globalCache};
delete env.ZIG_PROGRESS;
const listing = options.length === 1 && options[0] === '--list';
const selection = options.length === 2 && options[0] === '--group' ? options[1] : null;
assert(options.length === 0 || listing || selection, 'usage: zig build qualify [-- --list | -- --group NAME]');
const prefix = listing ? '' : realpathSync(mkdtempSync(join(tmpdir(), 'protean-qualify-')));
const inputs = '.protean-native/inputs';
const app = join(prefix, 'bin/protean');
const directPrefix = join(prefix, 'direct');
const node = process.execPath;
const buildIn = (destination, ...targets) => [zig, 'build', ...targets, '-Doptimize=safe', '-j2',
  '--prefix', destination, '--cache-dir', localCache, '--summary', 'all'];
const build = (...targets) => buildIn(prefix, ...targets);
const directOptions = ['-Dtarget=x86_64-linux-musl', '-Dnative-direct=true'];
const smoke = (root, backend) => [node, 'test/protean/native_adaptive.mjs', join(root, 'bin/protean'),
  join(root, 'protean/adaptive/application.json'), join(root, 'protean/adaptive/program.bpi3'), 'smoke', backend];
const groupedTests = (name, encoded, prerequisite, fixedIndex) => {
  const index = fixedIndex ?? JSON.parse(encoded).findIndex((_, i) => selection === name + '-' + (i + 1));
  const args = [node, 'tools/native/qualification_tests.mjs', join(prefix, 'verification', name), encoded];
  if (index >= 0) args.push(JSON.stringify([index]));
  return [index >= 0 ? name + '-' + (index + 1) : name, args, [prerequisite]];
};
const sharedGraph = mac && (!selection || selection === 'native-build-and-tests');
const product = sharedGraph ? 'native-build-and-tests' : 'product';
const inventory = [
  ['tigerstyle', ['bash', 'tools/tiger-style.sh', '--all', 'HEAD']],
  ['tigerstyle-integration', ['bash', 'tools/test-tiger-style.sh', localCache]],
  ['setup', [zig, 'run', 'tools/native/dependencies.zig', '--cache-dir', localCache,
    '--', 'setup', 'conformance/protean/dependencies.lock.json', 'conformance/protean/native-dependencies.lock.json', inputs, zig]],
  ...(sharedGraph ? [
    [product, build('protean', 'check-native-owner', 'check-recurrence-driver',
      'check-workspace-semantics', 'check-protean', 'check-native-https'), ['setup']],
    ['workspace-general', build('check-workspace-general'), ['setup']],
  ] : [
    ['authoring-https', build('check-protean', 'check-native-https'), ['setup']],
    ['task-owners', build('check-native-owner-tasks'), ['setup']],
    ['adaptive-build', build('build-native-owner-adaptive-check'), ['setup']],
    ...(linux ? JSON.parse(adaptiveGroups).map((_, index) =>
      groupedTests('native-owner-adaptive', adaptiveGroups, 'adaptive-build', index))
      : [groupedTests('native-owner-adaptive', adaptiveGroups, 'adaptive-build')]),
    ['owner-support', build('check-native-owner-support'), ['setup']],
    ['workspace-build', build('build-workspace-general-check'), ['setup']],
    groupedTests('workspace-general', workspaceGroups, 'workspace-build'),
    ['correspondence', build('check-workspace-semantics'), ['setup']],
    ['recurrence', build('check-recurrence-driver'), ['setup']],
    ['product', build('protean'), ['setup']],
  ]),
  ...(linux ? [
    ['direct-recurrence', buildIn(directPrefix, 'check-recurrence-driver', ...directOptions), ['setup']],
    ['direct-product', buildIn(directPrefix, 'protean', ...directOptions), ['setup']],
    ['direct-smoke', smoke(directPrefix, 'stage2_x86_64'), ['direct-product']],
  ] : []),
  ['native-smoke', smoke(prefix, 'stage2_llvm'), [product]],
  ['native-placement', [node, 'test/protean/native_placement.mjs', app], [product]],
  ['downstream-identity', [node, 'test/protean/installations.mjs', inputs, app], [product]],
];

if (listing) {
  for (const [name, , dependencies = []] of inventory)
    console.log(name, dependencies.length ? '(requires ' + dependencies.join(', ') + ')' : '');
  if (mac) console.log('Individual Zig targets are also selectable as authoring-https, task-owners,',
    'adaptive-build, native-owner-adaptive, owner-support, workspace-build, correspondence, recurrence, product.');
  process.exit(0);
}
const needed = new Set(selection ? [selection] : inventory.map(([name]) => name));
for (const [name, , dependencies = []] of inventory.toReversed())
  if (needed.has(name)) for (const dependency of dependencies) needed.add(dependency);
const groups = inventory.filter(([name]) => needed.has(name));

const seconds = ms => (ms / 1000).toFixed(3) + 's';
let child;
let interruption;
function stop(reason) {
  interruption ??= reason;
  if (child?.pid) {
    try { process.kill(-child.pid, 'SIGKILL'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
}
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.once(signal, () => stop(signal));
const head = () => execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
const clean = () => assert.equal(execFileSync('git', ['status', '--porcelain'], {encoding: 'utf8'}), '',
  'qualification requires the complete committed candidate');
let completed = 0;
try {
  assert(groups.length === needed.size, 'unknown qualification group: ' + selection);
  const candidate = head();
  console.log('Protean local qualification', candidate, process.platform, process.arch, '600s per group');
  clean();
  for (const [name, [command, ...args]] of groups) {
    const start = performance.now();
    const deadline = start + budget;
    assert(!interruption, interruption);
    console.log('Starting', name);
    child = spawn(command, args, {env, detached: true, stdio: 'inherit'});
    const timer = setTimeout(() => stop('deadline exceeded'), Math.max(0, deadline - performance.now()));
    let result;
    try {
      result = await new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('close', (code, signal) => resolve({code, signal}));
      });
      if (result.code !== 0) stop(result.signal ?? 'exit ' + result.code);
    } finally { clearTimeout(timer); child = undefined; }
    const end = performance.now();
    if (interruption || result.code !== 0 || end > deadline)
      throw new Error(name + ' incomplete after ' + seconds(end - start) + ' (' +
        (interruption ?? result.signal ?? (result.code || 'deadline exceeded')) + ')');
    completed++;
    console.log('Passed', name, seconds(end - start));
  }
  clean();
  assert.equal(head(), candidate, 'candidate changed during qualification');
  console.log(selection ? 'Selected group passed:' : 'Qualified', selection ?? candidate);
} catch (error) {
  console.error(error.message);
  console.error('Incomplete qualification.', 'Remaining groups:', groups.slice(completed).map(([name]) => name).join(', '));
  process.exitCode = 1;
} finally {
  rmSync(prefix, {recursive: true, force: true});
  console.log('Completed', completed + '/' + groups.length, 'groups in', seconds(performance.now() - started));
}
