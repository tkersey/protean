import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRegular} from './review-owner.mjs';
import {parseVersion} from './version.mjs';

export function manifestOperations(path) {
  const tool = realpathSync(path), digest = sha256(readRegular(tool, 128 * 1024 * 1024));
  return {sha256: digest, read(bytes) {
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1024 * 1024);
    const directory = mkdtempSync(join(tmpdir(), 'protean-manifest-'));
    try {
      const input = join(directory, 'manifest.zon'); writeFileSync(input, bytes, {flag: 'wx', mode: 0o600});
      assert.equal(sha256(readRegular(tool, 128 * 1024 * 1024)), digest, 'trusted native parser changed');
      const result = parseEvidenceJson(execFileSync(tool, ['manifest-version', input], {cwd: directory,
        encoding: 'buffer', env: {PATH: process.env.PATH, TMPDIR: directory}, timeout: 30000, maxBuffer: 65536}));
      assert.equal(result.sha256, sha256(bytes)); assert.equal(result.minimumCompiler, '0.17.0');
      parseVersion(result.version); return result.version;
    } finally {rmSync(directory, {recursive: true, force: true});}
  }};
}
