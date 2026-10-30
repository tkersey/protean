import {createHash} from 'node:crypto';
import {metadata} from './test-support.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {proteanJobs} from './protean-qualification.mjs';
import {proteanNativeArchive, sealProteanProduct} from './protean-package.mjs';

export function proteanFixture({target = 'x86_64-linux.5.10...7.2-musl'} = {}) {
  const input = metadata('protean'), commit = input.source.commit, tree = input.source.tree;
  const horosRecord = metadata('horos');
  const horos = {id: 3, record: horosRecord, recordSha256: sha256(encodeRecord(horosRecord)),
    admissionVerification: Buffer.from('synthetic original Horos authentication fixture')};
  const kosmosRecord = metadata('kosmos');
  kosmosRecord.dependencies = [{repository: horosRecord.repository, source: horosRecord.source,
    release: {id: horos.id, tag: horosRecord.tag, recordSha256: horos.recordSha256}}];
  const kosmos = {id: 4, record: kosmosRecord, recordSha256: sha256(encodeRecord(kosmosRecord)),
    admissionVerification: Buffer.from('synthetic original Kosmos authentication fixture')};
  const lockItem = record => ({repository: record.repository.name, commit: record.source.commit,
    gitTree: record.source.tree, version: record.source.version,
    archive: {format: 'repository-source-tar/v1',
      url: `https://github.com/${record.repository.name}/releases/download/${record.tag}/source.tar`,
      sha256: record.artifacts[0].sha256, bytes: record.artifacts[0].bytes}});
  const lock = {format: 'agent-native-source-lock/v2', status: 'released-integration',
    boundary: {...lockItem(horosRecord), package: {zigHash: horosRecord.source.packageIdentity}}, world: lockItem(kosmosRecord)};
  const lockBytes = Buffer.from(JSON.stringify(lock)), nativeLockBytes = Buffer.from('{"sqlite":"synthetic native lock fixture"}');
  const manifest = Buffer.from(`.{ .version = "1.0.0", .minimum_zig_version = "0.17.0", .dependencies = .{ .horos = .{ .url = "git+https://github.com/tkersey/horos#${commit}", .hash = "${horosRecord.source.packageIdentity}" } } }\n`);
  const sourceArchive = Buffer.from('synthetic source adapter payload, not native source authentication');
  const inventory = {commit, tree, archive: 'source.tar', sha256: sha256(sourceArchive), size: sourceArchive.length,
    packageIdentity: input.source.packageIdentity, compiler: '0.17.0',
    manifest: {sha256: sha256(manifest), version: '1.0.0', minimumCompiler: '0.17.0',
      horos: {url: `git+https://github.com/tkersey/horos#${commit}`, commit, packageIdentity: horosRecord.source.packageIdentity}},
    lockSha256: sha256(lockBytes), nativeLockSha256: sha256(nativeLockBytes),
    dependencies: {horos: {commit, tree, packageIdentity: horosRecord.source.packageIdentity}, kosmos: {commit, tree}},
    files: [['build.zig.zon', manifest], ['conformance/protean/dependencies.lock.json', lockBytes],
      ['conformance/protean/native-dependencies.lock.json', nativeLockBytes]].map(([path, bytes]) => ({
        path, mode: 0o644, blob: createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')}))};
  const executableBytes = Buffer.from('synthetic executed binary'), applicationBytes = Buffer.from('{"synthetic":"application"}');
  const programBytes = Buffer.from('synthetic admitted program'), archiveBytes = Buffer.from('synthetic final product archive');
  const identity = {program_sha256: sha256(programBytes), application_assets_sha256: sha256(applicationBytes),
    dependencies: {boundary: commit, world: commit, dependency_lock_sha256: sha256(lockBytes),
      sqlite: {lockSha256: sha256(nativeLockBytes), files: {
        'sqlite3.c': {bytes: 9515341, sha256: 'e'.repeat(64)},
        'sqlite3.h': {bytes: 690838, sha256: 'f'.repeat(64)},
      }}},
    compiler: {version: '0.17.0', executable_sha256: 'c'.repeat(64), library_inventory_sha256: 'd'.repeat(64)}, target};
  const native = {identity, artifact_sha256: sha256(executableBytes)};
  const build = {format: 'agent-native-build/v2', optimize: 'safe', ...identity, artifact_sha256: native.artifact_sha256};
  const packageInput = {commit, archiveName: proteanNativeArchive(commit), archiveBytes, executableBytes,
    applicationBytes, programBytes, buildBytes: Buffer.from(JSON.stringify(build)), identityBytes: Buffer.from(JSON.stringify(native))};
  const payloads = new Map([['source.tar', sourceArchive], ['source.json', Buffer.from(JSON.stringify(inventory))],
    [proteanNativeArchive(commit), archiveBytes], ['protean-native.json', sealProteanProduct(packageInput)],
    ['native-identity.json', Buffer.from(JSON.stringify(native))], ['native-placement-identity.json', Buffer.from(JSON.stringify(native))]]);
  const downstream = {identity, node_free_acquisition_build_install: true, package: inventory.packageIdentity,
    source: {commit, tree, archiveSha256: inventory.sha256, receiptSha256: sha256(payloads.get('source.json')),
      packageIdentity: inventory.packageIdentity, lockSha256: inventory.lockSha256, nativeLockSha256: inventory.nativeLockSha256},
    installed_execution: {admission_revision: '1', execution_revision: '2', cancellation_revision: '3', elapsed_ms: 20}};
  payloads.set('downstream-identity.json', Buffer.from(JSON.stringify(downstream)));
  input.artifacts[1].name = 'source.json';
  input.artifacts = input.artifacts.filter(value => value.name !== 'evidence.json');
  input.qualification.results[0].evidence = 'protean-native.json';
  input.qualification.aggregate.evidence = 'protean-native.json';
  input.review.landing.evidence = 'protean-native.json';
  input.review.closeout = 'protean-native.json';
  input.review.originalEvidence = ['protean-native.json'];
  input.compatibility.evidence = 'protean-native.json';
  for (const name of [...payloads.keys()].filter(name => !['source.tar', 'source.json'].includes(name)))
    input.artifacts.push({name, role: name === proteanNativeArchive(commit) ? 'native' : 'evidence',
      platform: name === proteanNativeArchive(commit) ? 'linux-x86_64' : null, bytes: 1, sha256: 'c'.repeat(64)});
  const run = {id: 17, repository: {id: 1328996555}, head_repository: {id: 1328996555},
    path: '.github/workflows/zig.yml', head_sha: commit, event: 'push', head_branch: 'main',
    run_attempt: 1, status: 'completed', conclusion: 'success', workflow_id: 23,
    created_at: '2026-10-30T00:00:00Z', run_started_at: '2026-10-30T00:01:00Z'};
  const jobs = Object.entries(proteanJobs).map(([name, names], index) => {
    const started_at = name === 'native' ? '2026-10-30T00:08:00Z' : '2026-10-30T00:01:00Z';
    const completed_at = name === 'native' ? '2026-10-30T00:09:00Z' : '2026-10-30T00:07:00Z';
    return {id: index + 50, name, run_id: 17, run_attempt: 1, head_sha: commit, status: 'completed', conclusion: 'success',
      started_at, completed_at, labels: [name === 'native' ? 'ubuntu-24.04' : 'ubuntu-22.04'],
      steps: names.map(name => ({name, status: 'completed', conclusion: 'success', started_at, completed_at}))};
  });
  const artifacts = [...payloads].map(([name, bytes], index) => ({id: index + 80, name, expired: false,
    size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    workflow_run: {id: 17, repository_id: 1328996555, head_repository_id: 1328996555, head_sha: commit}}));
  const replies = new Map([
    ['repos/tkersey/protean', {full_name: 'tkersey/protean', id: 1328996555, default_branch: 'main'}],
    ['repos/tkersey/protean/actions/runs/17', run],
    [`repos/tkersey/protean/actions/workflows/zig.yml/runs?head_sha=${commit}&event=push&per_page=100&page=1`, {workflow_runs: [run]}],
    ['repos/tkersey/protean/actions/workflows/23', {path: run.path}],
    [`repos/tkersey/protean/contents/${run.path}?ref=${commit}`, {type: 'file', encoding: 'base64', content: Buffer.from('synthetic workflow').toString('base64')}],
    ['repos/tkersey/protean/actions/runs/17/attempts/1/jobs?per_page=100&page=1', {jobs}],
    ['repos/tkersey/protean/actions/runs/17/artifacts?per_page=100&page=1', {artifacts}],
    [`repos/tkersey/protean/git/commits/${commit}`, {sha: commit, tree: {sha: tree}}],
    ...artifacts.map(artifact => [`repos/tkersey/protean/actions/artifacts/${artifact.id}/zip`, payloads.get(artifact.name)]),
  ]);
  const command = async args => {
    if (!replies.has(args[1])) throw new Error(`unexpected API: ${args[1]}`);
    const value = replies.get(args[1]); return Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  };
  return {input, admitted: [horos, kosmos], lock, lockBytes, nativeLockBytes, manifest, inventory, native, downstream,
    packageInput, payloads, run, jobs, artifacts, replies, command, commit, tree};
}
