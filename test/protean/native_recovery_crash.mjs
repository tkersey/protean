// SIGKILL is deliberately external to the owner. Each verifier is a new
// process opening the surviving namespace, never a graceful Service.close.
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, realpathSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createInterface} from 'node:readline';
import {once} from 'node:events';

const executable = process.argv[2];
const phases = [
  ...['ready', 'dispatched', 'invoked', 'acquired', 'captured', 'interpreted', 'settled', 'completed'].map(cut => `original-${cut}`),
  ...['admitted', 'dispatched', 'invoked', 'acquired', 'captured', 'interpreted', 'settled', 'completed'].map(cut => `lookup-${cut}`),
];
const root = realpathSync(mkdtempSync(join(tmpdir(), 'protean-recovery-crash-')));
try {
  for (const phase of phases) {
    const path = join(root, phase);
    const env = {...process.env, PROTEAN_CRASH_PATH: path, PROTEAN_CRASH_PHASE: phase};
    const child = spawn(executable, [], {env: {...env, PROTEAN_CRASH_MODE: 'crash'}, stdio: ['ignore', 'pipe', 'pipe']});
    const exited = once(child, 'exit');
    let stderr = '', witness;
    const invocations = [];
    child.stderr.setEncoding('utf8').on('data', chunk => stderr += chunk);
    const deadline = setTimeout(() => child.kill('SIGKILL'), 20_000);
    try {
      for await (const line of createInterface({input: child.stdout})) {
        const event = JSON.parse(line);
        if (event.invoked) invocations.push(event.invoked);
        if (event.cut) {
          assert.equal(event.cut, phase);
          witness = event.witness;
          assert(child.kill('SIGKILL'));
        }
      }
      const [code, signal] = await exited;
      assert(witness, `${phase}: no cut reached: ${code}/${signal}\n${stderr}`);
      assert.equal(signal, 'SIGKILL');
      const beforeInvocation = /-(ready|admitted|dispatched)$/.test(phase);
      assert.deepEqual(invocations, beforeInvocation ? [] : [phase.split('-')[0]]);
      // Reopening twice also detects duplicate charges or recovery execution.
      for (let reopen = 0; reopen < 2; reopen++) {
        const expected = reopen === 1 && /-(captured|interpreted|settled)$/.test(phase) ? `${phase.split('-')[0]}-completed` : phase;
        const result = spawnSync(executable, [], {env: {...env, PROTEAN_CRASH_MODE: 'verify', PROTEAN_CRASH_PHASE: expected, PROTEAN_CRASH_WITNESS: JSON.stringify(witness)}, encoding: 'utf8', timeout: 20_000});
        assert.equal(result.status, 0, `${phase} reopen ${reopen}: ${result.error ?? result.stderr}`);
        assert.deepEqual(JSON.parse(result.stdout), {verified: expected});
      }
    } finally {
      clearTimeout(deadline);
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      await exited.catch(() => {});
    }
  }
  console.log(JSON.stringify({recovery_process_crashes: phases.length, reopen_checks: phases.length * 2, original_reinvocations: 0, automatic_lookups: 0}));
} finally { rmSync(root, {recursive: true, force: true}); }
