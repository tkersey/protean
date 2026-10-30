import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync} from 'node:fs';
import {basename} from 'node:path';
import {pathToFileURL} from 'node:url';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

export const proteanIdentityFields = Object.freeze(['program_sha256', 'application_assets_sha256', 'dependencies', 'compiler', 'target']);
export const proteanNativeArchive = commit => {
  assert.match(commit, /^[0-9a-f]{40}$/);
  return `protean-Linux-X64-${commit}.tar.gz`;
};

export function sealProteanProduct({commit, archiveName, archiveBytes, buildBytes, executableBytes, applicationBytes, programBytes, identityBytes}) {
  assert.equal(archiveName, proteanNativeArchive(commit));
  for (const bytes of [archiveBytes, buildBytes, executableBytes, applicationBytes, programBytes, identityBytes])
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 256 * 1024 * 1024);
  const build = parseEvidenceJson(buildBytes), native = parseEvidenceJson(identityBytes);
  assert.equal(build.format, 'agent-native-build/v2'); assert.equal(build.target, 'x86_64-linux-musl');
  assert.equal(build.optimize, 'safe'); assert.equal(build.compiler.version, '0.17.0');
  assert.equal(build.artifact_sha256, sha256(executableBytes)); assert.equal(native.artifact_sha256, build.artifact_sha256);
  assert.equal(build.program_sha256, sha256(programBytes));
  assert.equal(build.application_assets_sha256, sha256(applicationBytes));
  const identity = Object.fromEntries(proteanIdentityFields.map(key => [key, build[key]]));
  assert.deepEqual(identity, native.identity, 'final packaged product differs from executed native identity');
  return encodeRecord({schema: 'protean-native-release/v1', commit, platform: 'linux-x86_64',
    archive: {name: archiveName, bytes: archiveBytes.length, sha256: sha256(archiveBytes)},
    executable: {name: 'protean', bytes: executableBytes.length, sha256: sha256(executableBytes)},
    build: {name: 'protean.build.json', bytes: buildBytes.length, sha256: sha256(buildBytes)},
    application: {name: 'adaptive-program/application.json', bytes: applicationBytes.length, sha256: sha256(applicationBytes)},
    program: {name: 'adaptive-program/program.bpi3', bytes: programBytes.length, sha256: sha256(programBytes)},
    identity});
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  assert.equal(process.argv.length, 5, 'expected archive native-identity output');
  const [archive, identity, output] = process.argv.slice(2);
  const commit = execFileSync('git', ['--no-replace-objects', 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
  const archiveBytes = readFileSync(archive);
  const member = name => execFileSync('/usr/bin/tar', ['-xOzf', archive, name], {maxBuffer: 256 * 1024 * 1024, timeout: 30000});
  const receipt = sealProteanProduct({commit, archiveName: basename(archive), archiveBytes,
    buildBytes: member('protean.build.json'), executableBytes: member('protean'),
    applicationBytes: member('adaptive-program/application.json'), programBytes: member('adaptive-program/program.bpi3'),
    identityBytes: readFileSync(identity)});
  assert.equal(sha256(readFileSync(archive)), sha256(archiveBytes), 'final archive changed during verification');
  writeFileSync(output, receipt, {flag: 'wx'});
}
