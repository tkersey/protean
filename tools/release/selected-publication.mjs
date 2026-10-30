import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {GitHubReader, githubCommand} from './github.mjs';
import {readRecord} from './record.mjs';
import {sha256} from './encoding.mjs';
import {admitPublishedRelease} from './release-admission.mjs';

export async function admitSelectedPublication({repository, commit, tree, packageIdentity}, command = githubCommand, admit = admitPublishedRelease) {
  assert.ok(['tkersey/horos', 'tkersey/kosmos'].includes(repository));
  assert.match(commit, /^[0-9a-f]{40}$/);
  if (tree !== undefined) assert.match(tree, /^[0-9a-f]{40}$/);
  const reader = new GitHubReader(repository, command);
  await reader.verifyRepository();
  let selected = null;
  for (const release of await reader.releases()) {
    const assets = [], seen = new Set();
    for (let page = 1; page <= 3; page++) {
      const rows = await reader.api(`releases/${release.id}/assets?per_page=100&page=${page}`);
      assert.ok(Array.isArray(rows) && rows.length <= 100);
      for (const item of rows) {
        assert.ok(Number.isSafeInteger(item.id) && item.id > 0 && !seen.has(item.id));
        seen.add(item.id); assets.push(item);
      }
      if (rows.length < 100) break;
      assert.ok(page < 3, 'publication asset capacity exceeded');
    }
    const records = assets.filter(asset => asset.name === 'release.json');
    assert.ok(records.length <= 1, 'ambiguous upstream record');
    if (records.length === 0) continue;
    const asset = records[0]; assert.ok(asset.size > 0 && asset.size <= 1024 * 1024);
    const bytes = await command(['api', `repos/${repository}/releases/assets/${asset.id}`, '-H', 'Accept: application/octet-stream'], asset.size + 1);
    assert.equal(bytes.length, asset.size); assert.equal(asset.digest, `sha256:${sha256(bytes)}`);
    const hint = readRecord(bytes);
    if (hint.source.commit !== commit) continue;
    assert.equal(hint.repository.name, repository);
    assert.equal(selected, null, 'multiple completed releases claim the exact selected source');
    const directory = mkdtempSync(join(tmpdir(), 'selected-publication-'));
    try {
      const publication = await admit({repository, releaseId: release.id, outputDirectory: join(directory, 'release')}, command);
      assert.equal(publication.id, release.id); assert.equal(publication.recordSha256, sha256(bytes));
      assert.equal(publication.record.source.commit, commit);
      if (tree !== undefined) assert.equal(publication.record.source.tree, tree, 'selected upstream tree differs');
      if (packageIdentity !== undefined) assert.equal(publication.record.source.packageIdentity, packageIdentity, 'selected upstream package differs');
      selected = publication;
    } finally {rmSync(directory, {recursive: true, force: true});}
  }
  assert.ok(selected, `selected source has no matching completed qualified publication: ${repository}@${commit}`);
  return selected;
}
