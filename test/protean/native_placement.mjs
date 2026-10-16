// Real native processes exchange a frozen continuation through the configured
// authenticated transport. No private production key or inference is used.
import assert from 'node:assert/strict';
import {createHash, createPrivateKey, createPublicKey} from 'node:crypto';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {deployment} from './native_deployment.mjs';
import {ProteanClient} from '../support/stdio-client.mts';

const app = deployment(process.argv[2], 'protean');
const sites = ['source', 'destination'].map((name, index) => {
  const seed = Buffer.alloc(32, index + 1);
  const privateKey = createPrivateKey({key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8'});
  const key = join(app.data, `${name}.key`), config = join(app.data, `${name}.json`);
  const spool = join(app.data, `${name}-spool`), state = join(app.data, name);
  mkdirSync(spool, {mode: 0o700});
  writeFileSync(key, seed.toString('hex'), {mode: 0o600});
  return {name, key, config, spool, state, publicKey: createPublicKey(privateKey).export({format: 'der', type: 'spki'}).subarray(-32).toString('hex')};
});
const hex = bytes => Buffer.from(bytes).toString('hex');
const request = (client, tag, value, timeout = 120_000) => client.call('placement', {request: {tag, value}}, timeout);
const config = (site, peers = []) => writeFileSync(site.config, JSON.stringify({signing_key_file: site.key, transport_directory: site.spool, peers}), {mode: 0o600});
const launch = async site => {
  const client = new ProteanClient(app.command, ['--offline', '--state-dir', site.state, '--placement-config', site.config], {cwd: app.data, env: {PATH: '/nonexistent'}});
  client.child.stderr.on('data', bytes => process.stderr.write(bytes));
  const initialized = await client.initialize();
  assert.equal(initialized.capabilities.placement, true);
  return client;
};
let active;
let passed = false;
try {
  const binary = createHash('sha256').update(readFileSync(app.executable)).digest('hex');
  for (const site of sites) {
    config(site);
    active = await launch(site);
    site.identity = await request(active, 'identify', {});
    assert.equal(hex(site.identity.site.key), site.publicKey);
    assert.equal(hex(site.identity.native_build), binary);
    await active.close(); active = null;
  }
  const [source, destination] = sites;
  active = await launch(source);
  const description = await active.call('describe');
  const submitted = await active.call('task.submit', {client_operation_id: 'placement-process-submit', application_id: 'adaptive-agent', profile_id: description.profile.id,
    input: {schema_id: 'adaptive-agent.input.v2', value: {task: 'Retain this offline continuation for native process transfer.'}}}, 120_000);
  await active.close(); active = null;
  active = await launch(source);
  const subject = {task: [...Buffer.from(submitted.task_id, 'hex')], work: null};
  const compatibility = await request(active, 'compatibility', subject);
  const cut = await request(active, 'cut', subject);
  await active.close(); active = null;
  const peer = (local, remote) => ({name: remote.name, public_key: remote.publicKey, namespace: hex(remote.identity.site.namespace), native_build: binary,
    resource_binding: hex(remote.identity.resource_binding), compatibility: Object.fromEntries(Object.entries(compatibility).map(([key, value]) => [key, hex(value)])),
    disclosure: {allow_private: true}, command: [app.executable, 'serve', '--transport', 'stdio', '--offline', '--state-dir', remote.state, '--placement-config', remote.config],
    remote_name: local.name, timeout_ms: 120_000});
  config(source, [peer(source, destination)]);
  config(destination, [peer(destination, source)]);
  active = await launch(source);
  const transfer = Array(32).fill(31);
  const move = {subject, peer: 'destination', expected: cut, transfer};
  const decision = await request(active, 'move', move, 300_000);
  assert.equal(decision.value.verdict.tag, 'accepted');
  assert.deepEqual(await request(active, 'move', move), decision, 'duplicate source transfer returns the committed signed decision');
  assert.equal((await request(active, 'status', subject)).phase, 'away');
  await assert.rejects(active.call('task.resume', {client_operation_id: 'stale-source', task_id: submitted.task_id, expected_revision: cut.control}), error => error.data?.kind === 'StateConflict');
  await active.close(); active = null;
  active = await launch(destination);
  const acquired = await request(active, 'status', subject);
  assert.equal(acquired.phase, 'local');
  assert.deepEqual(acquired.owner, destination.identity.site);
  assert.equal(acquired.epoch, '1');
  const carried = await request(active, 'cut', subject);
  assert.deepEqual(carried.outer, cut.outer);
  assert.deepEqual(carried.checkpoint, cut.checkpoint);
  assert.equal(carried.execution, cut.execution);
  assert.deepEqual(await request(active, 'refuse', {peer: 'source', offer: acquired.offer, reason: 'withdrawn'}), decision, 'withdrawal cannot revoke a committed acceptance');
  assert.equal(createHash('sha256').update(readFileSync(app.executable)).digest('hex'), binary);
  await active.close(); active = null;
  passed = true;
  console.log(JSON.stringify({native_placement: 'authenticated process transfer', duplicate_acceptance: true, destination_reopened: true, stale_source_rejected: true, native_binary_unchanged: true, live_provider: false}));
} finally {
  if (active) await active.close();
  await app.close(passed);
}
