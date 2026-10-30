import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {parseVersion} from './version.mjs';
import {proteanIdentityFields, proteanNativeArchive, validateProteanLinuxTarget} from './protean-package.mjs';

const repository = 'tkersey/protean', repositoryId = 1328996555;
const lane = name => `Qualification / ${name} / linux-x86_64`;
export const proteanJobs = Object.freeze({
  TigerStyle: ['Enforce TigerStyle on all tracked Zig source', 'Verify TigerStyle selection and failure behavior'],
  [lane('authoring')]: ['Check source inventory', 'Test repository-local release boundaries', 'Run retained qualification'],
  [lane('owners')]: ['Run retained qualification'],
  [lane('owner-adaptive-control')]: ['Run retained qualification'],
  [lane('owner-support')]: ['Run retained qualification'],
  [lane('workspace')]: ['Run retained qualification'],
  [lane('workspace-retention')]: ['Run retained qualification'],
  [lane('workspace-history')]: ['Run retained qualification'],
  [lane('correspondence')]: ['Run retained qualification'],
  [lane('native')]: ['Package completed native product', 'Publish completed native product before independent checks',
    'Run retained qualification', 'Retain independently qualified build identity', 'Package the executed adaptive application',
    'Retain executed adaptive application', 'Retain final native archive identity'],
  [lane('native-placement')]: ['Acquire current-run native product', 'Run retained qualification', 'Retain independently qualified build identity'],
  [lane('downstream')]: ['Prepare final full source archive', 'Run retained qualification', 'Retain consumer-tested source archive',
    'Retain native source and package identities', 'Retain independently qualified build identity'],
  native: ['Require complete qualification within ten minutes'],
});

export function proteanArtifacts(commit) {
  return {'source.tar': 64 * 1024 * 1024, 'source.json': 4 * 1024 * 1024,
    [proteanNativeArchive(commit)]: 256 * 1024 * 1024, 'protean-native.json': 4 * 1024 * 1024,
    'native-identity.json': 4 * 1024 * 1024, 'native-placement-identity.json': 4 * 1024 * 1024,
    'downstream-identity.json': 4 * 1024 * 1024};
}

function timestamp(value) {
  assert.equal(typeof value, 'string'); const result = Date.parse(value);
  assert.ok(Number.isFinite(result), 'missing original qualification timestamp'); return result;
}

export function validateProteanJobs(jobs, run) {
  assert.equal(run.run_attempt, 1, 'qualification retry cannot replace original evidence');
  const origin = timestamp(run.created_at); assert.ok(timestamp(run.run_started_at) >= origin);
  assert.ok(Array.isArray(jobs));
  const diagnostics = jobs.filter(job => job.name === 'Historical executable retention diagnostic');
  assert.ok(diagnostics.length <= 1, 'duplicate diagnostic job');
  for (const job of diagnostics) {
    assert.equal(job.run_id, run.id); assert.equal(job.run_attempt, 1); assert.equal(job.head_sha, run.head_sha);
    assert.equal(job.status, 'completed'); assert.equal(job.conclusion, 'skipped', 'diagnostic cannot substitute for full qualification');
  }
  const required = jobs.filter(job => !diagnostics.includes(job));
  assert.deepEqual(required.map(job => job.name).sort(), Object.keys(proteanJobs).sort(), 'required qualification inventory differs');
  for (const job of required) {
    assert.equal(job.run_id, run.id); assert.equal(job.run_attempt, 1); assert.equal(job.head_sha, run.head_sha);
    assert.equal(job.status, 'completed'); assert.equal(job.conclusion, 'success', `qualification failed: ${job.name}`);
    const start = timestamp(job.started_at), end = timestamp(job.completed_at);
    assert.ok(start >= origin && end >= start && end - origin <= 600000, 'original-trigger qualification deadline exceeded');
    assert.ok(end - start <= (job.name === 'native' ? 300000 : 600000), 'job deadline exceeded');
    assert.ok(job.labels?.includes(job.name === 'native' ? 'ubuntu-24.04' : 'ubuntu-22.04'), 'wrong native qualification platform');
    assert.ok(Array.isArray(job.steps), 'original step outcomes missing');
    for (const name of proteanJobs[job.name]) {
      const matching = job.steps.filter(step => step.name === name);
      assert.equal(matching.length, 1, `missing unique required step: ${name}`);
      const step = matching[0];
      assert.equal(step.status, 'completed'); assert.equal(step.conclusion, 'success', `required step did not pass: ${name}`);
      const stepStart = timestamp(step.started_at), stepEnd = timestamp(step.completed_at);
      assert.ok(stepStart >= start && stepEnd >= stepStart && stepEnd <= end, 'required step clock differs');
    }
  }
  const aggregate = required.find(job => job.name === 'native');
  for (const job of required.filter(job => job !== aggregate))
    assert.ok(timestamp(job.completed_at) <= timestamp(aggregate.started_at), 'aggregate precedes its required dependency');
}

export function validateProteanPayloads(payloads, {commit, tree}) {
  assert.ok(payloads instanceof Map);
  for (const [name, maximum] of Object.entries(proteanArtifacts(commit))) {
    const bytes = payloads.get(name);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= maximum, `missing bounded payload: ${name}`);
  }
  const inventory = parseEvidenceJson(payloads.get('source.json')), product = parseEvidenceJson(payloads.get('protean-native.json'));
  assert.equal(inventory.commit, commit); assert.equal(inventory.tree, tree); assert.equal(inventory.compiler, '0.17.0');
  assert.equal(inventory.archive, 'source.tar'); assert.equal(inventory.sha256, sha256(payloads.get('source.tar')));
  assert.equal(inventory.size, payloads.get('source.tar').length);
  parseVersion(inventory.manifest.version); assert.equal(inventory.manifest.minimumCompiler, '0.17.0');
  const prefix = `protean-${inventory.manifest.version}-`;
  assert.ok(inventory.packageIdentity.startsWith(prefix));
  assert.match(inventory.packageIdentity.slice(prefix.length), /^[A-Za-z0-9_-]{44}$/);
  for (const value of [inventory.lockSha256, inventory.nativeLockSha256, inventory.manifest.sha256])
    assert.match(value, /^[0-9a-f]{64}$/);
  for (const value of Object.values(inventory.dependencies)) {
    assert.match(value.commit, /^[0-9a-f]{40}$/); assert.match(value.tree, /^[0-9a-f]{40}$/);
  }
  assert.deepEqual(Object.keys(inventory.dependencies).sort(), ['horos', 'kosmos']);
  assert.equal(inventory.manifest.horos.commit, inventory.dependencies.horos.commit);
  assert.equal(inventory.manifest.horos.url, `git+https://github.com/tkersey/horos#${inventory.dependencies.horos.commit}`);
  assert.equal(inventory.manifest.horos.packageIdentity, inventory.dependencies.horos.packageIdentity);
  const [native, placement, downstream] = ['native', 'native-placement', 'downstream']
    .map(name => parseEvidenceJson(payloads.get(`${name}-identity.json`)));
  for (const key of proteanIdentityFields) {
    assert.notEqual(native.identity[key], undefined, key);
    assert.deepEqual(placement.identity[key], native.identity[key], key);
    assert.deepEqual(downstream.identity[key], native.identity[key], key);
  }
  assert.match(native.artifact_sha256, /^[0-9a-f]{64}$/);
  assert.equal(placement.artifact_sha256, native.artifact_sha256, 'placement did not execute the packaged binary');
  assert.equal(native.identity.compiler.version, '0.17.0'); validateProteanLinuxTarget(native.identity.target);
  assert.equal(native.identity.dependencies.boundary, inventory.dependencies.horos.commit);
  assert.equal(native.identity.dependencies.world, inventory.dependencies.kosmos.commit);
  assert.equal(native.identity.dependencies.dependency_lock_sha256, inventory.lockSha256);
  assert.equal(native.identity.dependencies.sqlite.lockSha256, inventory.nativeLockSha256);
  assert.equal(downstream.node_free_acquisition_build_install, true);
  assert.equal(downstream.package, inventory.packageIdentity);
  assert.deepEqual(downstream.source, {commit, tree, archiveSha256: inventory.sha256,
    receiptSha256: sha256(payloads.get('source.json')), packageIdentity: inventory.packageIdentity,
    lockSha256: inventory.lockSha256, nativeLockSha256: inventory.nativeLockSha256});
  const execution = downstream.installed_execution;
  assert.ok(execution && typeof execution === 'object', 'missing installed execution evidence');
  for (const key of ['admission_revision', 'execution_revision', 'cancellation_revision'])
    assert.match(execution[key], /^(0|[1-9][0-9]*)$/);
  assert.ok(BigInt(execution.execution_revision) > BigInt(execution.admission_revision));
  assert.ok(BigInt(execution.cancellation_revision) >= BigInt(execution.execution_revision));
  assert.ok(Number.isFinite(execution.elapsed_ms) && execution.elapsed_ms >= 0 && execution.elapsed_ms <= 30000);
  assert.equal(product.schema, 'protean-native-release/v1'); assert.equal(product.commit, commit);
  assert.equal(product.platform, 'linux-x86_64'); assert.deepEqual(product.identity, native.identity);
  assert.equal(product.archive.name, proteanNativeArchive(commit));
  const archive = payloads.get(product.archive.name);
  assert.equal(product.archive.bytes, archive.length); assert.equal(product.archive.sha256, sha256(archive));
  assert.equal(product.executable.name, 'protean'); assert.equal(product.executable.sha256, native.artifact_sha256);
  assert.equal(product.program.name, 'adaptive-program/program.bpi3'); assert.equal(product.program.sha256, native.identity.program_sha256);
  assert.equal(product.application.name, 'adaptive-program/application.json'); assert.equal(product.application.sha256, native.identity.application_assets_sha256);
  assert.equal(product.build.name, 'protean.build.json');
  for (const item of [product.executable, product.program, product.application, product.build]) {
    assert.ok(Number.isSafeInteger(item.bytes) && item.bytes > 0); assert.match(item.sha256, /^[0-9a-f]{64}$/);
  }
  return {inventory, product, native, placement, downstream};
}

async function pages(reader, path, field) {
  const all = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const value = await reader.api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    const rows = value[field]; assert.ok(Array.isArray(rows) && rows.length <= 100);
    for (const row of rows) {
      assert.ok(Number.isSafeInteger(row.id) && row.id > 0 && !seen.has(row.id), 'qualification pagination changed');
      seen.add(row.id); all.push(row);
    }
    if (rows.length < 100) return all;
  }
  throw new Error('qualification observation capacity exceeded');
}

export async function admitProteanQualification({runId, commit, tree, event = 'push'}, command = githubCommand) {
  assert.match(commit, /^[0-9a-f]{40}$/); assert.match(tree, /^[0-9a-f]{40}$/);
  assert.ok(Number.isSafeInteger(runId) && runId > 0); assert.ok(['push', 'pull_request'].includes(event));
  const reader = new GitHubReader(repository, command); await reader.verifyRepository();
  const run = await reader.api(`actions/runs/${runId}`);
  assert.equal(run.id, runId); assert.equal(run.repository.id, repositoryId); assert.equal(run.head_repository.id, repositoryId);
  assert.equal(run.path, '.github/workflows/zig.yml'); assert.equal(run.head_sha, commit); assert.equal(run.event, event);
  if (event === 'push') assert.equal(run.head_branch, 'main');
  assert.equal(run.run_attempt, 1); assert.equal(run.status, 'completed'); assert.equal(run.conclusion, 'success');
  const originals = await pages(reader, `actions/workflows/zig.yml/runs?head_sha=${commit}&event=${event}`, 'workflow_runs');
  assert.equal(originals.length, 1, 'ambiguous duplicate original qualification'); assert.equal(originals[0].id, runId);
  const workflow = await reader.api(`actions/workflows/${run.workflow_id}`); assert.equal(workflow.path, run.path);
  const definition = await reader.api(`contents/${run.path}?ref=${commit}`);
  assert.equal(definition.type, 'file'); assert.equal(definition.encoding, 'base64');
  const workflowBytes = Buffer.from(definition.content.replaceAll('\n', ''), 'base64');
  const jobs = await pages(reader, `actions/runs/${runId}/attempts/1/jobs`, 'jobs'); validateProteanJobs(jobs, run);
  const artifacts = await pages(reader, `actions/runs/${runId}/artifacts`, 'artifacts'), payloads = new Map();
  for (const [name, maximum] of Object.entries(proteanArtifacts(commit))) {
    const matches = artifacts.filter(artifact => artifact.name === name);
    assert.equal(matches.length, 1, `missing unique qualified artifact: ${name}`);
    const artifact = matches[0]; assert.equal(artifact.expired, false); assert.equal(artifact.workflow_run.id, runId);
    assert.equal(artifact.workflow_run.repository_id, repositoryId); assert.equal(artifact.workflow_run.head_repository_id, repositoryId);
    assert.equal(artifact.workflow_run.head_sha, commit);
    assert.ok(Number.isSafeInteger(artifact.size_in_bytes) && artifact.size_in_bytes > 0 && artifact.size_in_bytes <= maximum);
    const bytes = await command(['api', `repos/${repository}/actions/artifacts/${artifact.id}/zip`], maximum);
    assert.ok(Buffer.isBuffer(bytes)); assert.equal(bytes.length, artifact.size_in_bytes);
    assert.equal(artifact.digest, `sha256:${sha256(bytes)}`, 'original artifact transport digest differs');
    payloads.set(name, bytes);
  }
  validateProteanPayloads(payloads, {commit, tree});
  const actual = await reader.api(`git/commits/${commit}`); assert.equal(actual.sha, commit); assert.equal(actual.tree.sha, tree);
  const evidence = encodeRecord({run, jobs, artifacts, workflowSha256: sha256(workflowBytes)});
  return {run, jobs, payloads, evidence, workflow: {path: run.path, commit, sha256: sha256(workflowBytes)}};
}
