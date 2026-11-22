import {execFileSync, spawn} from 'node:child_process';
import {existsSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

function signalGroup(pid, signal) {
  try { process.kill(-pid, signal); return true; }
  catch (error) { if (error.code === 'ESRCH' || error.code === 'EPERM') return false; throw error; }
}

const psEnvironment = {PATH: '/usr/bin:/bin', TZ: 'UTC', LC_ALL: 'C'};

function started(pid) {
  try { return execFileSync('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], {encoding: 'utf8', env: psEnvironment}).trim(); }
  catch (error) { if (error.status === 1 && !String(error.stdout ?? '').trim()) return ''; throw error; }
}

export function spawnQualificationGroup(command, args, options,
  registration = (options.env ?? process.env).PROTEAN_QUALIFICATION_GROUPS, prefix = '') {
  const detached = {...options, detached: true};
  if (!registration) return spawn(command, args, detached);
  const base = registration + '/' + prefix;
  const child = spawn('/bin/sh', ['-c', 'TZ=UTC LC_ALL=C /bin/ps -o lstart= -p $$ > "$1$$.new" && test -s "$1$$.new" && /bin/mv "$1$$.new" "$1$$" || { echo "qualification: cannot register process group $$ in $1" >&2; exit 125; }; shift; exec "$@"',
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

function registrations(directory) {
  const found = [];
  let entries;
  try { entries = readdirSync(directory, {withFileTypes: true}); }
  catch (error) { if (error.code === 'ENOENT') return found; throw error; }
  for (const entry of entries) {
    const path = directory + '/' + entry.name;
    if (entry.isDirectory()) found.push(...registrations(path));
    else if (entry.isFile()) found.push({name: entry.name, path});
  }
  return found;
}

function liveGroups(root, directory, supervisorsOnly = false) {
  const groups = new Map([[root.pid, root.started || null]]);
  for (const {name, path} of registrations(directory)) {
    const supervisor = name.startsWith('supervisor-');
    if (supervisorsOnly && !supervisor) continue;
    let recorded;
    try { recorded = readFileSync(path, 'utf8').trim(); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    groups.set(Number(supervisor ? name.slice('supervisor-'.length) : name), recorded);
  }
  return [...groups].filter(([pid, recorded]) => {
    if (!Number.isSafeInteger(pid) || pid <= 1 || !signalGroup(pid, 0)) return false;
    const current = started(pid);
    return current === '' || current === recorded;
  }).map(([pid]) => pid);
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
  let child, root, timer, abort, cleanupFailed = false;
  try {
    child = spawnQualificationGroup(command, args, {cwd, stdio,
      env: {...env, PROTEAN_QUALIFICATION_GROUPS: directory}}, inherited ?? null, 'supervisor-');
    if (child.pid) root = {pid: child.pid, started: started(child.pid)};
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
    if (liveGroups(root, scope).length) throw new Error('qualification command left live processes');
    if (performance.now() >= deadline) throw new Error('deadline exceeded');
    return result;
  } catch (error) {
    if (child?.pid) {
      try { seal(); await terminate(root, scope); }
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
