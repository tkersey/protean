import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {mkdir, readFile, rename, writeFile} from 'node:fs/promises';
import {setTimeout as delay} from 'node:timers/promises';
import {join} from 'node:path';

const execute = promisify(execFile), [operation, directory] = process.argv.slice(2);
const files = ['executables/protean', 'protean/adaptive/application.json', 'protean/adaptive/program.bpi3'];
const metadata = 'qualification-product.json', members = [...files, metadata].sort();
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const source = (await execute('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'})).stdout.trim();
const context = {source, run: process.env.GITHUB_RUN_ID, attempt: process.env.GITHUB_RUN_ATTEMPT};
assert(directory && /^[0-9]+$/.test(context.run) && /^[0-9]+$/.test(context.attempt));

if (operation === 'pack') {
  const inputs = process.env.QUALIFICATION_INPUTS, lane = process.env.QUALIFICATION_LANE;
  assert(['native', 'native-placement'].includes(lane));
  assert(inputs?.startsWith('protean-compiled-v2-') && inputs.includes('-safe-product-'));
  const hashes = Object.fromEntries(await Promise.all(files.map(async file => [file, sha256(await readFile(join(directory, file)))])));
  await writeFile(join(directory, metadata), JSON.stringify({format: 'protean-qualification-product/v1', context, inputs, hashes}));
  await execute('tar', ['-czf', join(process.env.RUNNER_TEMP, `native-product-${lane}-${context.attempt}.tar.gz`), '-C', directory, ...members]);
} else {
  assert.equal(operation, 'receive');
  const repo = process.env.GITHUB_REPOSITORY;
  const api = async (path, timeout = 30_000) => (await execute('gh', ['api', `repos/${repo}/${path}`], {encoding: 'buffer', maxBuffer: 64 * 1024 * 1024, timeout})).stdout;
  const run = JSON.parse(await api(`actions/runs/${context.run}`));
  assert.equal(String(run.id), context.run);
  assert.equal(String(run.run_attempt), context.attempt);
  const deadline = Date.parse(run.run_started_at) + 600_000;
  const names = ['native', 'native-placement'].map(lane => `native-product-${lane}-${context.attempt}.tar.gz`);
  let artifact;
  while (Date.now() < deadline) {
    const inventory = JSON.parse(await api(`actions/runs/${context.run}/artifacts?per_page=100`, Math.max(1, deadline - Date.now())));
    assert(inventory.total_count <= 100);
    const matches = inventory.artifacts.filter(value => names.includes(value.name));
    assert.equal(new Set(matches.map(value => value.name)).size, matches.length);
    if (matches.length) {
      artifact = matches.sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id - b.id)[0];
      break;
    }
    await delay(Math.min(2000, Math.max(1, deadline - Date.now())));
  }
  assert(artifact, 'a current-run native producer must publish within the workflow deadline');
  assert.equal(artifact.expired, false);
  assert.equal(String(artifact.workflow_run.id), context.run);
  assert.equal(artifact.workflow_run.head_sha, run.head_sha);
  const bytes = await api(`actions/artifacts/${artifact.id}/zip`, Math.max(1, deadline - Date.now()));
  assert.equal(`sha256:${sha256(bytes)}`, artifact.digest);
  const archive = join(process.env.RUNNER_TEMP, 'qualification-product.tar.gz');
  await writeFile(archive, bytes);
  const listing = (await execute('tar', ['-tzf', archive], {encoding: 'utf8'})).stdout.trim().split('\n').sort();
  assert.deepEqual(listing, members);
  const incoming = `${directory}.incoming-${artifact.id}`;
  await mkdir(incoming);
  await execute('tar', ['-xzf', archive, '-C', incoming]);
  const saved = JSON.parse(await readFile(join(incoming, metadata), 'utf8'));
  assert.equal(saved.format, 'protean-qualification-product/v1');
  assert.deepEqual(saved.context, context);
  assert(saved.inputs.startsWith('protean-compiled-v2-') && saved.inputs.includes('-safe-product-'));
  assert.deepEqual(Object.keys(saved.hashes).sort(), [...files].sort());
  for (const file of files) assert.equal(sha256(await readFile(join(incoming, file))), saved.hashes[file]);
  await rename(incoming, directory);
  console.log(JSON.stringify({qualification_product: artifact.name, artifact_digest: artifact.digest, artifact_id: artifact.id, source, received_at: new Date().toISOString()}));
}
