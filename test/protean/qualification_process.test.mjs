import assert from 'node:assert/strict';
import {existsSync, mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {setTimeout as delay} from 'node:timers/promises';
import {runQualificationCommand, spawnQualificationGroup} from '../../tools/native/qualification_process.mjs';

const module = new URL('../../tools/evaluation/workspace.mjs', import.meta.url).href;
const worker = `
  import {spawn} from 'node:child_process';
  import {renameSync, writeFileSync} from 'node:fs';
  const helper = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {stdio: 'inherit'});
  writeFileSync(process.argv[1] + '.tmp', JSON.stringify([process.ppid, process.pid, helper.pid]));
  renameSync(process.argv[1] + '.tmp', process.argv[1]);
  setInterval(() => {}, 1000);
`;
const controller = `
  import {RecurrenceDriver} from ${JSON.stringify(module)};
  import {writeFileSync} from 'node:fs';
  process.on('SIGTERM', () => { writeFileSync(process.argv[1] + '.signal', 'SIGTERM'); process.exit(0); });
  new RecurrenceDriver(process.execPath, ['--input-type=module', '-e', ${JSON.stringify(worker)}, process.argv[1]]);
`;

function alive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}

for (const reason of ['cancellation', 'deadline', 'controller killed']) {
  test('qualifier reaps detached driver and helper on ' + reason, async () => {
    const directory = mkdtempSync(join(tmpdir(), 'protean-supervisor-test-'));
    const ready = join(directory, 'ready');
    const abort = new AbortController();
    const deadline = performance.now() + (reason === 'deadline' ? 3000 : 15000);
    const result = runQualificationCommand(process.execPath, ['--input-type=module', '-e', controller, ready],
      {signal: abort.signal, deadline}).then(code => ({code}), error => ({error}));
    let ids;
    try {
      while (performance.now() < deadline) {
        try { ids = JSON.parse(readFileSync(ready)); break; }
        catch (error) { if (error.code !== 'ENOENT') throw error; }
        await delay(5);
      }
      assert(ids?.every(alive), 'controller, driver, and helper must start');
      if (reason === 'cancellation') abort.abort(new Error('interrupted'));
      if (reason === 'deadline') process.kill(ids[0], 'SIGSTOP');
      if (reason === 'controller killed') process.kill(ids[0], 'SIGKILL');
      const {error} = await result;
      assert.match(error?.message ?? '', {cancellation: /interrupted/, deadline: /deadline/, 'controller killed': /SIGKILL/}[reason]);
      if (reason === 'cancellation') assert.equal(readFileSync(ready + '.signal', 'utf8'), 'SIGTERM');
      assert.deepEqual(ids.map(alive), [false, false, false]);
    } finally {
      abort.abort(new Error('test cleanup'));
      await result;
      for (const pid of ids ?? []) if (alive(pid)) process.kill(pid, 'SIGKILL');
      rmSync(directory, {recursive: true, force: true});
    }
  });
}

test('qualification requires a successful spawn and accepted exit before the deadline', async () => {
  const options = {deadline: performance.now() + 10000, cwd: tmpdir(), env: {MESSAGE: 'a b'}};
  const script = "process.exit(process.argv[1] === process.env.MESSAGE ? 77 : 1)";
  const args = ['-e', script, 'a b'];
  assert.equal(await runQualificationCommand(process.execPath, args, {...options, allowedExitCodes: [0, 77]}), 77);
  await assert.rejects(runQualificationCommand(process.execPath, args, options), /exit 77/);
  await assert.rejects(runQualificationCommand('/nonexistent/protean-command', [], options), /ENOENT/);
  await assert.rejects(runQualificationCommand(process.execPath, args, {...options, deadline: 0}), /deadline/);
  await assert.rejects(runQualificationCommand(process.execPath, ['-e', 'setInterval(() => {}, 1000)'],
    {...options, deadline: performance.now() + 100}), /deadline/);
  await assert.rejects(runQualificationCommand(process.execPath, args, {...options,
    signal: AbortSignal.abort(new Error('interrupted before start'))}), /interrupted before start/);
});

test('a closed qualification scope refuses late workers and reaps helpers after their leader exits', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'protean-released-group-'));
  const record = join(directory, 'record');
  const api = new URL('../../tools/native/qualification_process.mjs', import.meta.url).href;
  const helper = `
    import {spawn} from 'node:child_process';
    import {writeFileSync} from 'node:fs';
    const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {stdio: 'ignore'});
    writeFileSync(process.argv[1], JSON.stringify([process.env.PROTEAN_QUALIFICATION_GROUPS, child.pid]));
    child.unref();`;
  const program = `
    import {spawnQualificationGroup} from ${JSON.stringify(api)};
    import {once} from 'node:events';
    await once(spawnQualificationGroup(process.execPath, ['--input-type=module', '-e', ${JSON.stringify(helper)},
      process.argv[1]], {stdio: 'ignore'}), 'close');`;
  try {
    await assert.rejects(runQualificationCommand(process.execPath, ['--input-type=module', '-e', program, record],
      {deadline: performance.now() + 15000}), /left live processes/);
    const [retired, pid] = JSON.parse(readFileSync(record));
    assert.equal(alive(pid), false);
    const witness = join(directory, 'late-worker');
    const late = spawnQualificationGroup(process.execPath, ['-e', 'require("node:fs").writeFileSync(process.argv[1], "")', witness],
      {stdio: 'ignore'}, retired);
    assert.notEqual((await once(late, 'close'))[0], 0);
    assert.equal(existsSync(witness), false);
  } finally { rmSync(directory, {recursive: true, force: true}); }
});

test('a registration whose pid now leads an unrelated group is neither reported nor signalled', async () => {
  const unrelated = spawn('sleep', ['30'], {detached: true, stdio: 'ignore'});
  try {
    // The command forges a registration naming the unrelated group with another start time.
    const script = 'require("node:fs").writeFileSync(process.env.PROTEAN_QUALIFICATION_GROUPS + "/" + process.argv[1], "Thu Jan  1 00:00:00 1970\\n")';
    await runQualificationCommand(process.execPath, ['-e', script, String(unrelated.pid)],
      {deadline: performance.now() + 10000, cwd: tmpdir(), stdio: 'ignore'});
    process.kill(-unrelated.pid, 0);
    assert.equal(unrelated.exitCode, null);
    assert.equal(unrelated.signalCode, null);
  } finally {
    process.kill(-unrelated.pid, 'SIGKILL');
  }
});
