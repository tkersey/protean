import {spawn} from 'node:child_process';
import {existsSync, mkdtempSync, readdirSync, renameSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}

export function spawnQualificationGroup(command, args, options,
  registration = (options.env ?? process.env).PROTEAN_QUALIFICATION_GROUPS, prefix = '') {
  const detached = {...options, detached: true};
  if (!registration) return spawn(command, args, detached);
  const base = registration + '/' + prefix;
  const child = spawn('/bin/sh', ['-c', ': > "$1$$" && test -f "$1$$" || exit 125; shift; exec "$@"',
    'qualification', base, command, ...args], detached);
  if (child.pid) child.once('close', () => {
    const path = base + child.pid;
    function release() {
      if (!existsSync(path)) return;
      if (signalGroup(child.pid, 0)) setTimeout(release, 10).unref();
      else rmSync(path, {force: true});
    }
    release();
  });
  return child;
}

function liveGroups(root, directory, supervisorsOnly = false) {
  const registrations = readdirSync(directory, {recursive: true, withFileTypes: true});
  const groups = new Set([root]);
  for (const entry of registrations) {
    if (!entry.isFile()) continue;
    if (entry.name.startsWith('supervisor-')) groups.add(Number(entry.name.slice('supervisor-'.length)));
    else if (!supervisorsOnly) groups.add(Number(entry.name));
  }
  return [...groups].filter(pid => Number.isSafeInteger(pid) && pid > 1 && signalGroup(pid, 0));
}

async function terminate(root, directory) {
  for (const pid of liveGroups(root, directory, true)) signalGroup(pid, 'SIGTERM');
  const grace = performance.now() + 250;
  let groups = liveGroups(root, directory);
  while (groups.length && performance.now() < grace) {
    await delay(10);
    groups = liveGroups(root, directory);
  }
  const limit = performance.now() + 1000;
  while (groups.length) {
    for (const pid of groups) signalGroup(pid, 'SIGKILL');
    await delay(10);
    groups = liveGroups(root, directory);
    if (groups.length && performance.now() >= limit)
      throw new Error('qualification process groups still present after SIGKILL: ' + groups.join(', '));
  }
}

export async function runQualificationCommand(command, args, {
  env = process.env, cwd, stdio = 'inherit', signal, deadline, allowedExitCodes = [0],
}) {
  signal?.throwIfAborted();
  if (!(deadline > performance.now())) throw new Error('deadline exceeded');
  const inherited = env.PROTEAN_QUALIFICATION_GROUPS;
  const directory = mkdtempSync(join(inherited ?? tmpdir(), 'protean-qualification-groups-'));
  let scope = directory;
  function seal() {
    if (scope !== directory) return;
    const closing = directory + '.closed';
    renameSync(directory, closing);
    scope = closing;
  }
  let child, timer, abort, cleanupFailed = false;
  try {
    child = spawnQualificationGroup(command, args, {cwd, stdio,
      env: {...env, PROTEAN_QUALIFICATION_GROUPS: directory}}, inherited ?? null, 'supervisor-');
    const result = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', (code, killedBy) => {
        if (code !== null && allowedExitCodes.includes(code)) resolve(code);
        else reject(new Error(killedBy ?? 'exit ' + code));
      });
      abort = () => reject(signal.reason);
      signal?.addEventListener('abort', abort, {once: true});
      timer = setTimeout(() => reject(new Error('deadline exceeded')), Math.ceil(deadline - performance.now()));
    });
    signal?.throwIfAborted();
    seal();
    if (liveGroups(child.pid, scope).length) throw new Error('qualification command left live processes');
    if (performance.now() >= deadline) throw new Error('deadline exceeded');
    return result;
  } catch (error) {
    if (child?.pid) {
      try { seal(); await terminate(child.pid, scope); }
      catch (failure) {
        cleanupFailed = true;
        throw new Error(`${error.message}; cleanup in ${scope} failed: ${failure.message}`, {cause: failure});
      }
    }
    throw error;
  } finally {
    clearTimeout(timer);
    if (abort) signal?.removeEventListener('abort', abort);
    if (!cleanupFailed) rmSync(scope, {recursive: true, force: true});
  }
}
