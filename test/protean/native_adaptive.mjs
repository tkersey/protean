// Exercise the authored adaptive loop through the copied native product.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {deployment} from './native_deployment.mjs';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {verifyAdaptiveNative} from './adaptive_native_peer.mjs';

const image = readFileSync(process.argv[4]), application = JSON.parse(readFileSync(process.argv[3], 'utf8'));
assert.equal(image.subarray(0, 8).toString(), 'ABL_BPI3');
assert.equal(createHash('sha256').update(image).digest('hex'), application.program_sha256);

const app = deployment(process.argv[2], 'protean');
let passed = false;
try {
  const invoke = (...args) => {
    const result = spawnSync(app.command, args, {cwd: app.data, env: {PATH: '/nonexistent'}, encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024});
    assert.equal(result.status, 0, `${args[0]}: ${result.error ?? result.stderr}\n${result.stdout}`);
    return JSON.parse(result.stdout);
  };
  const manifest = invoke('describe-build');
  assert.equal(manifest.format, 'agent-native-build/v1');
  assert.equal(manifest.application_id, 'adaptive-agent');
  assert.equal(manifest.protocol, 'agent-host/1.0');
  assert.equal(manifest.compiler.version, '0.17.0');
  assert.equal(manifest.artifact_sha256, createHash('sha256').update(readFileSync(app.executable)).digest('hex'));
  assert.equal(manifest.program_sha256, application.program_sha256);
  assert.equal(manifest.application_assets_sha256, createHash('sha256').update(readFileSync(process.argv[3])).digest('hex'));
  assert.equal(manifest.dependencies.sqlite.version, '3.53.4');
  assert.deepEqual(manifest.licenses.map(item => item.component).sort(), ['Protean', 'Kronos', 'Horos', 'Zig standard library', 'SQLite', ...(manifest.target.includes('linux') ? ['musl libc'] : [])].sort());
  assert(manifest.licenses.some(item => item.component === 'SQLite' && item.text.includes('disclaims copyright')));
  assert(!JSON.stringify(manifest).includes(process.cwd()));
  const result = invoke('demo', '--offline', '--state-dir', join(app.data, 'adaptive state'));
  assert.equal(result.mode, 'offline-demo');
  assert.equal(result.output.disposition, 'report');
  assert.equal(result.output.model_calls, 14);
  assert.equal(result.output.work_calls, 5);
  assert.equal(result.output.control.selection.profile_id, 'analysis');
  assert.equal(result.output.control.selection.effective_effort, 'medium');
  assert.equal(result.output.control.selection.control_revision, '8');
  assert.equal(result.output.control.skills.length, 0);
  assert.equal(result.output.receipts.length, 8);
  assert.equal(result.output.evidence.length, 1);
  assert.equal(result.output.evidence[0].tag, 'source');
  assert.equal(result.output.evidence[0].value.path, 'src/main.zig');
  assert.deepEqual(result.output.receipts.map(item => item.next_revision), ['1', '2', '3', '4', '5', '6', '7', '8']);
  assert.equal(result.output.receipts[3].context_epoch, result.output.receipts[2].context_epoch, 'resident deactivation retains the epoch');
  assert.equal(BigInt(result.output.receipts[4].context_epoch), BigInt(result.output.receipts[3].context_epoch) + 1n, 'physical unload creates a new projection');
  assert.equal(BigInt(result.output.control.eviction_generation), 2n);
  await verifyAdaptiveNative({app, applicationPath: process.argv[3]});
  passed = true;
  console.log(JSON.stringify({adaptive: 'authored control scenario', model_calls: result.output.model_calls, controls: result.output.receipts.length, live_provider: false}));
} finally {
  app.close(passed);
}
