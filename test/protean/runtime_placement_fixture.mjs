// Deterministic public fixture keys and operator-owned native process channels.
// This helper prepares peers; the prescribed model trace selects the moves.
import assert from 'node:assert/strict';
import {createHash, createPrivateKey, createPublicKey} from 'node:crypto';
import {execFile} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {promisify} from 'node:util';
import {ProteanClient} from '../support/stdio-client.mts';
import {readArchive} from './native_archive.mjs';

const hex = bytes => Buffer.from(bytes).toString('hex');
export const placementRequest = (client, tag, value) => client.call('placement', {request: {tag, value}}, 120_000);

export async function runtimePlacementFixture(app, configuration, trust, sourceState) {
  const binary = createHash('sha256').update(await readFile(app.executable)).digest('hex');
  const directory = await mkdtemp(join(app.data, 'runtime-placement-'));
  const sites = [];
  for (const [index, name] of ['controller', 'executor', 'successor'].entries()) {
    const seed = Buffer.alloc(32, 51 + index);
    const privateKey = createPrivateKey({key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8'});
    const key = join(directory, name + '-runtime.key'), config = join(directory, name + '-runtime-placement.json');
    const spool = join(directory, name + '-runtime-spool');
    const state = index === 0 ? sourceState : join(directory, name + '-runtime-state');
    await mkdir(spool, {mode: 0o700});
    await writeFile(key, seed.toString('hex'), {mode: 0o600});
    await writeFile(config, JSON.stringify({signing_key_file: key, transport_directory: spool, peers: []}), {mode: 0o600});
    sites.push({name, key, config, spool, state, publicKey: createPublicKey(privateKey).export({format: 'der', type: 'spki'}).subarray(-32).toString('hex')});
  }
  const flags = site => ['--state-dir', site.state, '--placement-config', site.config, '--config', configuration, '--authorize-inference', '--test-provider', '--trust-root', trust];
  // Compatibility names the semantic service, independently of the profile's
  // resources. Obtain it from the actual binary without any model request.
  const probe = new ProteanClient(app.command, ['--offline', '--state-dir', join(directory, 'probe'), '--placement-config', sites[0].config], {cwd: app.data, env: {PATH: '/nonexistent'}});
  let compatibility, probeTask;
  try {
    await probe.initialize();
    const description = await probe.call('describe');
    const task = await probe.call('task.submit', {client_operation_id: 'compatibility-probe', application_id: 'adaptive-agent', profile_id: description.profile.id,
      input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Retain an offline compatibility witness.'}}});
    compatibility = await placementRequest(probe, 'compatibility', {task: [...Buffer.from(task.task_id, 'hex')], work: null});
    probeTask = task.task_id;
  } finally { assert.deepEqual(await probe.close(), {code: 0, signal: null}); }
  const probeArchive = join(directory, 'probe.par');
  await promisify(execFile)(app.command, ['export-checkpoint', '--offline', '--state-dir', join(directory, 'probe'), '--task-id', probeTask, '--output', probeArchive], {cwd: app.data, env: {PATH: '/nonexistent'}});
  const controlSchema = readArchive(await readFile(probeArchive)).schemas.get('placement_control');
  for (const site of sites) {
    const client = new ProteanClient(app.command, flags(site), {cwd: app.data, env: {PATH: '/nonexistent'}});
    client.child.stderr.on('data', bytes => process.stderr.write(bytes));
    try {
      await client.initialize();
      site.identity = await placementRequest(client, 'identify', {});
      assert.equal(hex(site.identity.site.key), site.publicKey);
      assert.equal(hex(site.identity.native_build), binary);
    } finally { assert.deepEqual(await client.close(), {code: 0, signal: null}); }
  }
  for (const site of sites) {
    const peers = sites.filter(remote => remote !== site).map(remote => ({
      name: remote.name, public_key: remote.publicKey, namespace: hex(remote.identity.site.namespace), native_build: binary,
      resource_binding: hex(remote.identity.resource_binding),
      compatibility: Object.fromEntries(Object.entries(compatibility).map(([key, value]) => [key, value === null ? null : hex(value)])),
      disclosure: {allow_private: true}, command: [app.executable, 'serve', '--transport', 'stdio', ...flags(remote)],
      remote_name: site.name, timeout_ms: 120_000,
    }));
    await writeFile(site.config, JSON.stringify({signing_key_file: site.key, transport_directory: site.spool, peers}), {mode: 0o600});
  }
  return {source: sites[0], executor: sites[1], successor: sites[2], binary, controlSchema};
}
