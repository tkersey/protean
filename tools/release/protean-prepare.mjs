import assert from 'node:assert/strict';
import {execFile, spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {mkdirSync, readFileSync, writeFileSync, realpathSync, lstatSync, readdirSync} from 'node:fs';
import {dirname, join, isAbsolute} from 'node:path';
import {GitHubReader} from './github.mjs';
import {selectPublishedSource,admitFrozenSource} from './protean-upstream-selection.mjs';
import {admitPublishedRelease} from './release-admission.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRecord} from './record.mjs';
import {parseVersion} from './version.mjs';
import {validateImpact} from './impact.mjs';
import {mechanicalPaths, proposalMessage, proposalCommitOid, nativeCandidateBinding} from './protean-proposal.mjs';

const execute = promisify(execFile), maximumSourceBytes = 64 * 1024 * 1024;
const repositories = new Set(['tkersey/protean', 'tkersey/kosmos', 'tkersey/horos']);
const oid = value => {assert.match(value, /^[0-9a-f]{40}$/); return value;};
const digest = value => {assert.match(value, /^[0-9a-f]{64}$/); return value;};

export function preparationEnvironment(root) {
  return {PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', HOME: join(root, 'home'),
    TMPDIR: join(root, 'tmp'), XDG_CONFIG_HOME: join(root, 'home'),
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_TERMINAL_PROMPT: '0',
    GIT_ATTR_NOSYSTEM: '1', LANG: 'C', LC_ALL: 'C'};
}

async function command(file, args, root) {
  const result = await execute(file, args, {cwd: root, env: preparationEnvironment(root),
    encoding: 'buffer', maxBuffer: maximumSourceBytes, timeout: 60000});
  return result.stdout;
}

async function git(root, repository, args) {
  return command('/usr/bin/git', ['-C', repository, '--no-replace-objects', ...args], root);
}

async function cloneRepository({repository, commit, destination, root}) {
  assert.ok(repositories.has(repository)); oid(commit);
  mkdirSync(destination, {mode: 0o700});
  await git(root, destination, ['init', '--quiet']);
  await git(root, destination, ['-c', 'credential.helper=', '-c', 'http.extraHeader=',
    'fetch', '--no-tags', '--no-recurse-submodules', `https://github.com/${repository}.git`, commit]);
  await git(root, destination, ['-c', 'core.hooksPath=/dev/null', 'checkout', '--quiet', '--detach', commit]);
}

function binary(value, base) {
  assert.deepEqual(Object.keys(value).sort(), ['path', 'sha256', 'sourceCommit']);
  assert.equal(value.sourceCommit, base, 'native tooling must belong to the accepted source base');
  assert.ok(isAbsolute(value.path));
  const path = realpathSync(value.path), stat = lstatSync(path);
  assert.ok(stat.isFile() && stat.size > 0 && stat.size <= 512 * 1024 * 1024);
  assert.equal(sha256(readFileSync(path)), digest(value.sha256), 'trusted native tool changed');
  return {...value, path};
}

export function nativeInvocation({tool, compiler, root, args, readOnlyPaths = [], platform = process.platform}) {
  const env = preparationEnvironment(root), compilerDirectory = dirname(compiler.path);
  const libraries = [join(compilerDirectory, 'lib'), join(compilerDirectory, '../lib/zig'),
    join(compilerDirectory, '../lib')].filter(path => {
    try {return lstatSync(join(path, 'std/std.zig')).isFile();} catch {return false;}
  }).map(path => realpathSync(path));
  if (platform === 'darwin') {
    const quote = JSON.stringify;
    const reads = ['/System', '/usr', '/bin', '/sbin', '/Library/Developer', '/Applications/Xcode.app',
      '/opt/homebrew/Cellar', '/usr/local/Cellar', ...libraries];
    const profile = `(version 1)(deny default)(import "system.sb")(allow process*)(allow sysctl-read)(allow mach-lookup)(allow file-read-metadata)(allow file-read* file-map-executable (literal "/dev/null") (literal "/dev/urandom") ${reads.map(path => `(subpath ${quote(path)})`).join(' ')} (literal ${quote(tool.path)}) (literal ${quote(compiler.path)}))(allow file-read* file-write* file-map-executable (subpath ${quote(root)}))(allow file-write* (literal "/dev/null"))${readOnlyPaths.map(path => `(deny file-write* (subpath ${quote(path)}))`).join('')}`;
    return {file: '/usr/bin/sandbox-exec', args: ['-p', profile, tool.path, ...args], env};
  }
  assert.equal(platform, 'linux', 'native preparation requires supported sandbox');
  const bindings = ['/usr', '/bin', '/lib', '/lib64'].filter(path => {try {return lstatSync(path).isDirectory() || lstatSync(path).isSymbolicLink();} catch {return false;}});
  return {file: '/usr/bin/bwrap', args: ['--unshare-all', '--new-session', '--die-with-parent',
    ...bindings.flatMap(path => ['--ro-bind', path, path]), '--proc', '/proc', '--dev', '/dev',
    '--tmpfs', '/tmp', '--bind', root, root, '--ro-bind', compiler.path, compiler.path,
    ...libraries.flatMap(path => ['--ro-bind', path, path]),
    '--ro-bind', tool.path, tool.path, ...readOnlyPaths.flatMap(path => ['--ro-bind', path, path]),
    '--chdir', root, '--', tool.path, ...args], env};
}

async function runNative(input) {
  const captures = join(input.root, 'host-captures');
  mkdirSync(captures, {mode: 0o700, recursive: true});
  const captureRoot = join(captures, `execution-${input.ordinal}`);
  mkdirSync(captureRoot, {mode: 0o700});
  const invocation = nativeInvocation({...input, readOnlyPaths: [...input.readOnlyPaths, captures]});
  const result = await nativeProcess(invocation, input.root, input.timeoutMs);
  writeFileSync(join(captureRoot, 'stdout.bin'), result.stdout, {flag: 'wx', mode: 0o400});
  writeFileSync(join(captureRoot, 'stderr.txt'), result.stderr, {flag: 'wx', mode: 0o400});
  assert.equal(result.failure, null, `native preparation process failed: ${result.failure}`);
  assert.equal(result.code, 0, `native preparation exited ${result.code} (${result.signal}); diagnostics: ${captureRoot}`);
  return {stdout: result.stdout, stderr: result.stderr};
}

function nativeProcess(invocation, root, timeoutMs) {
  assert.ok(Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 600000);
  return new Promise(resolve => {
    const child = spawn(invocation.file, invocation.args, {cwd: root, env: invocation.env,
      stdio: ['ignore', 'pipe', 'pipe'], detached: true});
    const stdout = [], stderr = [];
    let failure = null, timer, escalation, total = 0;
    const kill = signal => {
      if (!child.pid) return;
      try {process.kill(-child.pid, signal);} catch (error) {if (error.code !== 'ESRCH') failure ??= `cleanup:${error.code}`;}
    };
    const stop = reason => {
      if (failure) return;
      failure = reason; kill('SIGTERM'); escalation = setTimeout(() => kill('SIGKILL'), 1000);
    };
    const retain = (target, bytes) => {
      total += bytes.length;
      if (total > maximumSourceBytes) return stop('output-limit');
      target.push(Buffer.from(bytes));
    };
    child.stdout.on('data', bytes => retain(stdout, bytes));
    child.stderr.on('data', bytes => retain(stderr, bytes));
    child.once('error', error => {failure ??= `spawn:${error.code}`;});
    child.once('close', (code, signal) => {
      clearTimeout(timer); clearTimeout(escalation); kill('SIGKILL');
      resolve({code, signal, failure, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr)});
    });
    timer = setTimeout(() => stop('deadline'), timeoutMs);
  });
}

async function sourceState(root, repository, base, tree) {
  assert.equal((await git(root, repository, ['rev-parse', 'HEAD'])).toString().trim(), base, 'source base changed');
  assert.equal((await git(root, repository, ['rev-parse', 'HEAD^{tree}'])).toString().trim(), tree, 'source tree changed');
  assert.equal((await git(root, repository, ['status', '--porcelain', '--untracked-files=all'])).length, 0, 'source checkout changed');
}

function fileBytes(path, maximum = maximumSourceBytes) {
  const stat = lstatSync(path);
  assert.ok(stat.isFile() && !stat.isSymbolicLink() && stat.size <= maximum, 'unsupported native output file');
  const bytes = readFileSync(path); assert.equal(bytes.length, stat.size); return bytes;
}

function compareVersion(left, right) {
  const a = parseVersion(left), b = parseVersion(right);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

function admittedRelease(value, id, repository = 'tkersey/kosmos') {
  assert.equal(value.id, id);
  assert.ok(value.paths instanceof Map && value.payloads instanceof Map);
  const bytes = fileBytes(value.paths.get('release.json'), 1024 * 1024), record = readRecord(bytes);
  assert.deepEqual(record, value.record); assert.equal(sha256(bytes), value.recordSha256);
  assert.equal(record.repository.name, repository);
  assert.ok(Buffer.isBuffer(value.admissionVerification) && value.admissionVerification.length > 0);
  const archive = record.artifacts.find(item => item.role === 'source');
  assert.equal(archive.name, 'source.tar');
  const payload = fileBytes(value.paths.get('source.tar'));
  assert.equal(sha256(payload), archive.sha256); assert.equal(payload.length, archive.bytes);
  assert.deepEqual(payload, value.payloads.get('source.tar'));
  return {id, source: record.source, ...value, recordBytes: bytes};
}

async function discover(reader, admit, root, selected, releaseId, versionDecision) {
  await reader.verifyRepository();
  const admitOne=async id=>admittedRelease(await admit({repository:'tkersey/kosmos',releaseId:id,outputDirectory:join(root,'release-'+id)}),id);
  const frozen=versionDecision!==undefined&&typeof versionDecision!=='function'?versionDecision:null;
  if(frozen!==null){
    if(releaseId!==undefined)assert.equal(releaseId,frozen.kosmosReleaseId,'conflicting frozen upstream identity');
    releaseId=frozen.kosmosReleaseId;
  }
  let successor;
  if(releaseId!==undefined)successor=await admitFrozenSource(reader,selected,releaseId,admitOne);
  else{
    const admitted=[];
    for(const release of await reader.releases()){
      assert.ok(Array.isArray(release.assets),'release asset discovery missing');
      if(release.assets.some(asset=>asset.name==='release.json'))admitted.push(await admitOne(release.id));
    }
    successor=await selectPublishedSource(reader,selected,admitted,{publicationRequired:versionDecision!==undefined});
  }
  if(successor===null)return null;
  if(frozen!==null)assert.equal(successor.recordSha256,frozen.kosmosRecordSha256,'frozen upstream record changed');
  assert.ok(compareVersion(successor.source.version,selected.version)>=0,'upstream version downgrade');
  const changed=successor.source.commit!==selected.commit;
  if(changed){
    assert.equal(successor.record.compatibility.disposition,'compatible','upstream breaking migration requires ordinary implementation');
    assert.notEqual(successor.record.compatibility.impact,'major','upstream major migration requires ordinary implementation');
  }else assert.equal(successor.source.version,selected.version);
  return {...successor,changed};
}

async function outputProjection(root, repository, output, base) {
  const bytes = await git(root, repository, ['ls-tree', '-rz', base]);
  const entries = new TextDecoder('utf-8', {fatal: true}).decode(bytes).split('\0').filter(Boolean).map(line => {
    const match = /^(100644|100755) blob ([0-9a-f]{40})\t([\s\S]+)$/.exec(line);
    assert.ok(match, 'unsupported base source entry');
    assert.ok(!match[3].includes('\\') && match[3].split('/').every(part =>
      part.length > 0 && part !== '.' && part !== '..' && part.toLowerCase() !== '.git'), 'unsafe source path');
    return {mode: match[1], sha: match[2], path: match[3]};
  });
  assert.ok(entries.length > 0 && entries.length <= 10000);
  const expected = new Map(entries.map(value => [value.path, value])), actual = new Map(), stack = [''];
  let total = 0;
  for (let count = 0; stack.length > 0; count++) {
    assert.ok(count <= 20000, 'native source directory capacity');
    const parent = stack.pop();
    for (const name of readdirSync(join(output, parent))) {
      const path = parent ? `${parent}/${name}` : name, full = join(output, path), stat = lstatSync(full);
      assert.ok(!stat.isSymbolicLink(), 'native output symlink');
      if (stat.isDirectory()) {stack.push(path); continue;}
      assert.ok(expected.has(path), 'unexpected native source output');
      const data = fileBytes(full); total += data.length; assert.ok(total <= maximumSourceBytes);
      const mode = stat.mode & 0o777; assert.equal(mode, Number.parseInt(expected.get(path).mode.slice(-3), 8), 'source mode changed');
      actual.set(path, data);
    }
  }
  assert.deepEqual([...actual.keys()].sort(), [...expected.keys()].sort(), 'incomplete native source output');
  await git(root, repository, ['read-tree', base]);
  const changed = [];
  for (const {path, sha, mode} of entries) {
    const data = actual.get(path);
    const obtained = createHash('sha1').update(`blob ${data.length}\0`).update(data).digest('hex');
    if (obtained === sha) continue;
    assert.ok(mechanicalPaths.includes(path), 'native generator changed unauthorized source');
    const temporary = join(root, 'blob-input'); writeFileSync(temporary, data);
    assert.equal((await git(root, repository, ['hash-object', '-w', temporary])).toString().trim(), obtained);
    changed.push(path);
    await git(root, repository, ['update-index', '--cacheinfo', `${mode},${obtained},${path}`]);
  }
  const tree = (await git(root, repository, ['write-tree'])).toString().trim();
  await git(root, repository, ['read-tree', base]);
  return {tree, changed: changed.sort(), files: new Map(mechanicalPaths.map(path => [path, actual.get(path)]))};
}

export async function prepareProtean({base, baseTree, tool: toolInput, compiler: compilerInput, outputDirectory,
  versionDecision, admitVersionDecision, author, selectedReleaseId}, options = {}) {
  oid(base); oid(baseTree);
  if (selectedReleaseId !== undefined) assert.ok(Number.isSafeInteger(selectedReleaseId) && selectedReleaseId > 0);
  assert.equal(typeof admitVersionDecision, 'function', 'authenticated version decision required');
  assert.ok(isAbsolute(outputDirectory)); mkdirSync(outputDirectory, {mode: 0o700});
  const root = realpathSync(outputDirectory);
  for (const name of ['home', 'tmp']) mkdirSync(join(root, name), {mode: 0o700});
  const tool = binary(toolInput, base), compiler = binary(compilerInput, base);
  const clone = options.cloneRepository ?? cloneRepository, native = options.runNative ?? runNative;
  const reader = options.reader ?? new GitHubReader('tkersey/kosmos');
  const admit = options.admitPublishedRelease ?? admitPublishedRelease;
  const repository = join(root, 'base'); await clone({repository: 'tkersey/protean', commit: base, destination: repository, root});
  await sourceState(root, repository, base, baseTree);
  const captures = [], readOnlyPaths = [repository], started = Date.now();
  const run = async args => {
    const timeoutMs = Math.min(540000, 600000 - (Date.now() - started));
    assert.ok(timeoutMs > 0, 'preparation deadline exceeded');
    const result = await native({tool, compiler, root, args, readOnlyPaths: [...readOnlyPaths], ordinal: captures.length, timeoutMs});
    assert.ok(Buffer.isBuffer(result.stdout) && Buffer.isBuffer(result.stderr));
    captures.push({args, stdoutSha256: sha256(result.stdout), stderrSha256: sha256(result.stderr)});
    return result.stdout;
  };
  const factsBytes = await run(['source-manifest', repository]), facts = parseEvidenceJson(factsBytes);
  const manifest = facts.manifest;
  assert.equal(manifest.sha256, sha256(fileBytes(join(repository, 'build.zig.zon'))));
  assert.equal(facts.lockSha256, sha256(fileBytes(join(repository, 'conformance/protean/dependencies.lock.json'))));
  assert.equal(manifest.minimumCompiler, '0.17.0'); parseVersion(manifest.version);
  oid(facts.dependencies.kosmos.commit); oid(facts.dependencies.kosmos.tree);
  const lock = parseEvidenceJson(fileBytes(join(repository, 'conformance/protean/dependencies.lock.json')));
  assert.equal(lock.world.commit, facts.dependencies.kosmos.commit);
  assert.equal(lock.world.gitTree, facts.dependencies.kosmos.tree); parseVersion(lock.world.version);
  const successor = await discover(reader, admit, root, {...facts.dependencies.kosmos, version: lock.world.version}, selectedReleaseId, versionDecision);
  if (successor === null || (!successor.changed && versionDecision === undefined)) {
    await sourceState(root, repository, base, baseTree);
    return {status: 'unchanged', base, baseTree, facts};
  }
  const requested = typeof versionDecision === 'function' ? await versionDecision({base, baseTree,
    currentVersion: manifest.version, upstream: successor}) : versionDecision;
  if (requested === null) {
    await sourceState(root, repository, base, baseTree);
    return {status: 'unchanged', base, baseTree, facts};
  }
  const decision = structuredClone(requested);
  assert.deepEqual(Object.keys(decision).sort(), ['base', 'baseTree', 'impact', 'kosmosRecordSha256', 'kosmosReleaseId', 'version']);
  assert.equal(decision.base, base); assert.equal(decision.baseTree, baseTree);
  assert.equal(decision.kosmosReleaseId, successor.id); assert.equal(decision.kosmosRecordSha256, successor.recordSha256);
  validateImpact(decision.impact); assert.equal(decision.impact.disposition, 'compatible'); assert.equal(decision.impact.impact, 'patch');
  assert.ok(compareVersion(decision.version, manifest.version) >= 0, 'own version downgrade');
  if (!successor.changed && decision.version === manifest.version) {
    await sourceState(root, repository, base, baseTree);
    return {status: 'unchanged', base, baseTree, facts};
  }
  const decisionBytes = encodeRecord(decision), decisionSha256 = sha256(decisionBytes);
  assert.equal(await admitVersionDecision({decisionBytes: Buffer.from(decisionBytes), base, baseTree,
    currentVersion: manifest.version, upstream: structuredClone(successor.record.source)}), decisionSha256,
  'version decision is not authenticated');
  const upstreamRepository = join(root, 'kosmos');
  await clone({repository: 'tkersey/kosmos', commit: successor.record.source.commit, destination: upstreamRepository, root});
  await sourceState(root, upstreamRepository, successor.record.source.commit, successor.record.source.tree);
  assert.equal(successor.record.dependencies.length, 1);
  const derived = successor.record.dependencies[0];
  assert.equal(derived.repository.name, 'tkersey/horos');
  const upstreamDirectory = join(root, 'upstream'); mkdirSync(upstreamDirectory);
  const horosDirectory = join(upstreamDirectory, digest(derived.release.recordSha256));
  const horos = admittedRelease(await admit({repository: 'tkersey/horos', releaseId: derived.release.id,
    outputDirectory: horosDirectory}), derived.release.id, 'tkersey/horos');
  assert.equal(horos.recordSha256, derived.release.recordSha256);
  assert.deepEqual(horos.record.source, derived.source); assert.equal(horos.record.tag, derived.release.tag);
  const horosRepository = join(horosDirectory, 'repository.git');
  await clone({repository: 'tkersey/horos', commit: derived.source.commit, destination: horosRepository, root});
  await sourceState(root, horosRepository, derived.source.commit, derived.source.tree);
  const input = {schema: 'protean-refresh/v1', baseCommit: base, baseTree, version: decision.version,
    kosmos: {record: successor.paths.get('release.json'), archive: successor.paths.get('source.tar'), repository: upstreamRepository},
    upstreamDirectory};
  const inputPath = join(root, 'input.json'), output = join(root, 'generated');
  writeFileSync(inputPath, encodeRecord(input), {flag: 'wx', mode: 0o400});
  readOnlyPaths.push(upstreamRepository, upstreamDirectory, dirname(successor.paths.get('release.json')), inputPath);
  await run(['refresh', repository, inputPath, output, compiler.path]);
  const nativeResultBytes = fileBytes(join(output, 'result.json'), 1024 * 1024);
  readOnlyPaths.push(join(output, 'source'), join(output, 'sources/horos'), join(output, 'sources/kosmos'), join(output, 'result.json'));
  await run(['coherence', join(output, 'source'), join(output, 'sources'), compiler.path]);
  const projection = await outputProjection(root, repository, join(output, 'source'), base);
  assert.ok(projection.changed.length > 0, 'native refresh produced no source delta');
  await sourceState(root, repository, base, baseTree);
  await sourceState(root, upstreamRepository, successor.record.source.commit, successor.record.source.tree);
  await sourceState(root, horosRepository, derived.source.commit, derived.source.tree);
  const date = (await git(root, repository, ['show', '-s', '--format=%cI', base])).toString().trim();
  const attribution = {...structuredClone(author), date: new Date(date).toISOString().replace('.000Z', 'Z')};
  const candidate = {base, baseTree, tree: projection.tree, version: decision.version, files: projection.files,
    nativeResultBytes, kosmosReleaseId: successor.id, kosmosRecordBytes: successor.recordBytes, impact: decision.impact,
    author: attribution, committer: {...attribution}};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  const binding = nativeCandidateBinding(candidate);
  const files = mechanicalPaths.map(path => ({path, sha256: sha256(candidate.files.get(path)), bytes: candidate.files.get(path).length}));
  const {nativeResultBytes: omittedResult, kosmosRecordBytes: omittedRecord, ...descriptor} = candidate;
  const candidateBytes = encodeRecord({...descriptor, schema: 'protean-prepared-candidate/v1', files,
    nativeResultSha256: sha256(omittedResult), kosmosRecordSha256: sha256(omittedRecord)});
  const proofBytes = encodeRecord({schema: 'protean-native-preparation/v1', binding, decisionSha256,
    tool: toolInput, compiler: compilerInput, manifestSha256: sha256(factsBytes),
    admissionSha256: sha256(successor.admissionVerification), horosAdmissionSha256: sha256(horos.admissionVerification), captures});
  writeFileSync(join(root, 'candidate.json'), candidateBytes, {flag: 'wx', mode: 0o400});
  writeFileSync(join(root, 'preparation.json'), proofBytes, {flag: 'wx', mode: 0o400});
  return {status: 'prepared', candidate, candidateBytes, proofBytes, decisionBytes,
    upstreamRecordBytes: successor.recordBytes, upstreamAdmissionBytes: successor.admissionVerification,
    derivedRecordBytes: horos.recordBytes, derivedAdmissionBytes: horos.admissionVerification};
}

export async function readProteanSource({source, controlCommit, tool: toolInput, compiler: compilerInput, outputDirectory}, options = {}) {
  oid(source.commit); oid(source.tree); oid(controlCommit);
  assert.ok(isAbsolute(outputDirectory)); mkdirSync(outputDirectory, {mode: 0o700});
  const root = realpathSync(outputDirectory);
  for (const name of ['home', 'tmp']) mkdirSync(join(root, name), {mode: 0o700});
  const tool = binary(toolInput, controlCommit), compiler = binary(compilerInput, controlCommit);
  const repository = join(root, 'source'), clone = options.cloneRepository ?? cloneRepository;
  await clone({repository: 'tkersey/protean', commit: source.commit, destination: repository, root});
  await sourceState(root, repository, source.commit, source.tree);
  const native = options.runNative ?? runNative;
  const result = await native({tool, compiler, root, args: ['source-manifest', repository],
    readOnlyPaths: [repository], ordinal: 0, timeoutMs: 60000});
  const facts = parseEvidenceJson(result.stdout), manifestBytes = fileBytes(join(repository, 'build.zig.zon'));
  assert.equal(facts.manifest.sha256, sha256(manifestBytes));
  assert.equal(facts.lockSha256, sha256(fileBytes(join(repository, 'conformance/protean/dependencies.lock.json'))));
  assert.equal(facts.nativeLockSha256, sha256(fileBytes(join(repository, 'conformance/protean/native-dependencies.lock.json'))));
  assert.equal(facts.manifest.minimumCompiler, '0.17.0'); parseVersion(facts.manifest.version);
  await sourceState(root, repository, source.commit, source.tree);
  return {facts, manifestBytes};
}
