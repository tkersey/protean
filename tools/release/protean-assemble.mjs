import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {parseEvidenceJson} from './evidence-json.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {produceRecord, validateRecord} from './record.mjs';
import {validateProteanPayloads} from './protean-qualification.mjs';
import {proteanNativeArchive} from './protean-package.mjs';

const sourceLockPath = 'conformance/protean/dependencies.lock.json';
const nativeLockPath = 'conformance/protean/native-dependencies.lock.json';

function upstream(value, repository) {
  assert.ok(value && typeof value === 'object', 'admitted upstream publication missing');
  validateRecord(value.record); assert.equal(value.record.repository.name, repository);
  assert.ok(Number.isSafeInteger(value.id) && value.id > 0);
  assert.equal(value.recordSha256, sha256(encodeRecord(value.record)), 'admitted upstream record changed');
  assert.ok(Buffer.isBuffer(value.admissionVerification) && value.admissionVerification.length > 0,
    'original authenticated publication evidence missing');
  return {repository: value.record.repository, source: value.record.source,
    release: {id: value.id, tag: value.record.tag, recordSha256: value.recordSha256}};
}

function sourceDefinition(inventory, path, bytes) {
  assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1024 * 1024);
  const entries = inventory.files.filter(file => file.path === path);
  assert.equal(entries.length, 1, 'missing unique source definition'); assert.equal(entries[0].mode, 0o644);
  assert.equal(entries[0].blob, createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'),
    'captured source definition differs from native Git inventory');
}

function lockBinding(value, admitted) {
  const source = admitted.record.source;
  assert.equal(value.repository, admitted.record.repository.name); assert.equal(value.commit, source.commit);
  assert.equal(value.gitTree, source.tree); assert.equal(value.version, source.version);
  if (value.repository === 'tkersey/horos') assert.equal(value.package.zigHash, source.packageIdentity);
  if (value.archive.format !== undefined) {
    assert.equal(value.archive.format, 'repository-source-tar/v1');
    assert.equal(value.archive.url, `https://github.com/${value.repository}/releases/download/${admitted.record.tag}/source.tar`);
    const archive = admitted.record.artifacts.find(item => item.role === 'source');
    assert.equal(value.archive.sha256, archive.sha256); assert.equal(value.archive.bytes, archive.bytes);
  } else assert.equal(value.archive.url, `https://github.com/${value.repository}/archive/${source.commit}.tar.gz`);
}

export function assembleProtean(metadata, payloads, manifestBytes, lockBytes, nativeLockBytes, admitted) {
  assert.equal(metadata.repository.name, 'tkersey/protean');
  const inventory = parseEvidenceJson(payloads.get('source.json'));
  validateProteanPayloads(payloads, {commit: inventory.commit, tree: inventory.tree});
  assert.ok(Array.isArray(inventory.files) && inventory.files.length > 0 && inventory.files.length <= 10000);
  assert.equal(new Set(inventory.files.map(file => file.path)).size, inventory.files.length, 'duplicate full source inventory');
  for (const [path, bytes] of [['build.zig.zon', manifestBytes], [sourceLockPath, lockBytes], [nativeLockPath, nativeLockBytes]])
    sourceDefinition(inventory, path, bytes);
  assert.equal(inventory.manifest.sha256, sha256(manifestBytes));
  assert.equal(inventory.lockSha256, sha256(lockBytes)); assert.equal(inventory.nativeLockSha256, sha256(nativeLockBytes));
  assert.ok(Array.isArray(admitted) && admitted.length === 2, 'exact Kosmos and its derived Horos publications required');
  const [horos, kosmos] = admitted;
  const dependencies = [upstream(horos, 'tkersey/horos'), upstream(kosmos, 'tkersey/kosmos')];
  assert.deepEqual(kosmos.record.dependencies, [dependencies[0]], 'independent Horos selection differs from admitted Kosmos');
  for (const [name, value] of [['horos', horos], ['kosmos', kosmos]]) {
    assert.equal(inventory.dependencies[name].commit, value.record.source.commit);
    assert.equal(inventory.dependencies[name].tree, value.record.source.tree);
  }
  assert.equal(inventory.manifest.horos.url, `git+https://github.com/tkersey/horos#${horos.record.source.commit}`);
  assert.equal(inventory.manifest.horos.packageIdentity, horos.record.source.packageIdentity);
  const lock = parseEvidenceJson(lockBytes);
  assert.equal(lock.format, 'agent-native-source-lock/v2');
  assert.ok(['development-integration', 'released-integration'].includes(lock.status));
  lockBinding(lock.boundary, horos); lockBinding(lock.world, kosmos);
  const version = inventory.manifest.version;
  const source = {commit: inventory.commit, tree: inventory.tree, version, manifestSha256: sha256(manifestBytes),
    packageIdentity: inventory.packageIdentity, lockSha256: sha256(lockBytes)};
  const required = {'source.tar': 'source', 'source.json': 'inventory', [proteanNativeArchive(source.commit)]: 'native',
    'protean-native.json': 'evidence', 'native-identity.json': 'evidence',
    'native-placement-identity.json': 'evidence', 'downstream-identity.json': 'evidence'};
  for (const [name, role] of Object.entries(required)) {
    const matches = metadata.artifacts.filter(artifact => artifact.name === name);
    assert.equal(matches.length, 1, `missing unique final payload: ${name}`); assert.equal(matches[0].role, role);
    assert.equal(matches[0].platform, role === 'native' ? 'linux-x86_64' : null);
  }
  return produceRecord({...metadata, source, tag: `v${version}`, dependencies}, payloads);
}

export async function assemblePublishedProtean(options, command) {
  assert.ok(!Object.hasOwn(options, 'horosReleaseId'), 'Horos must be derived from selected authenticated Kosmos');
  const {metadata, payloads, manifestBytes, lockBytes, nativeLockBytes, kosmosReleaseId, upstreamDirectory} = options;
  const {admitPublishedRelease} = await import('./release-admission.mjs');
  mkdirSync(upstreamDirectory, {recursive: true, mode: 0o700});
  const kosmos = await admitPublishedRelease({repository: 'tkersey/kosmos', releaseId: kosmosReleaseId,
    outputDirectory: join(upstreamDirectory, 'kosmos')}, command);
  assert.equal(kosmos.record.dependencies.length, 1); assert.equal(kosmos.record.dependencies[0].repository.name, 'tkersey/horos');
  const horos = await admitPublishedRelease({repository: 'tkersey/horos', releaseId: kosmos.record.dependencies[0].release.id,
    outputDirectory: join(upstreamDirectory, 'horos')}, command);
  return assembleProtean(metadata, payloads, manifestBytes, lockBytes, nativeLockBytes, [horos, kosmos]);
}
