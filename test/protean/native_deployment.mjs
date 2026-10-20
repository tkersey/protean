// Qualification controller only. The application sees its executable, selected
// user data and OS facilities; source trees and language runtimes are excluded.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {copyFileSync, createReadStream, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {createInterface} from 'node:readline';

const shell = value => `'${value.replaceAll("'", "'\\''")}'`;

async function* traceExecutions(path) {
  const input = createReadStream(path);
  const lines = createInterface({input});
  try {
    for await (const line of lines) {
      if (!/\bexecve(?:at)?\(/.test(line)) continue;
      assert(!line.includes('execveat('), line);
      const match = line.match(/execve\("((?:\\.|[^"\\])*)"/);
      assert(match, line);
      const octets = match[1].match(/\\x[0-9a-fA-F]{2}/g) ?? [];
      assert.equal(octets.join(''), match[1], line);
      yield {path: Buffer.from(octets.map(octet => parseInt(octet.slice(2), 16))).toString('utf8'), pid: Number(line.match(/^\s*(\d+)\s+/)?.[1])};
    }
  } finally { lines.close(); input.destroy(); }
}

export function deployment(source, name) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'Protean deployment ü ')));
  const data = join(root, 'data'), controller = join(root, 'controller');
  mkdirSync(data, {mode: 0o700});
  mkdirSync(controller, {mode: 0o700});
  const executable = join(root, name), command = join(controller, 'launch');
  copyFileSync(source, executable);
  const binary = readFileSync(executable), sha256 = createHash('sha256').update(binary).digest('hex');
  const format = execFileSync('file', ['-b', executable], {encoding: 'utf8'}).trim();
  let libraries = [], signing = 'not-applicable';
  if (process.platform === 'linux') {
    assert.match(format, /ELF 64-bit.*x86-64/);
    const linkage = execFileSync('readelf', ['-lWd', executable], {encoding: 'utf8'});
    assert(!/INTERP|\(NEEDED\)|\(RPATH\)|\(RUNPATH\)/.test(linkage), 'Linux product must have no dynamic loader or shared-library dependency');
    // Filter in the kernel so unrelated file/SQLite calls do not incur ptrace
    // stops. Every process event and descendant remains traced and checked.
    const args = ['/usr/bin/strace', '--seccomp-bpf', '-f', '-qq', '-xx', '-s', '4096', '-e', 'trace=process', '-o'];
    const isolate = ['/usr/bin/bwrap', '--unshare-user', '--die-with-parent', '--unshare-pid', '--new-session', '--uid', '0', '--gid', '0',
      '--proc', '/proc', '--dev', '/dev', '--ro-bind', executable, executable, '--bind', data, data, '--chdir'];
    // The controller owns tracing and namespace setup. Neither tool is mounted
    // into the application boundary. bwrap terminates with its tracer parent.
    writeFileSync(command, `#!/bin/sh\nexec ${args.map(shell).join(' ')} ${shell(join(controller, 'trace.'))}$$ ${isolate.map(shell).join(' ')} "$PWD" ${shell(executable)} "$@"\n`, {mode: 0o700});
  } else if (process.platform === 'darwin') {
    assert.match(format, /Mach-O 64-bit executable arm64/);
    libraries = execFileSync('otool', ['-L', executable], {encoding: 'utf8'}).trim().split('\n').slice(1).map(line => line.trim().split(' (')[0]);
    assert(libraries.length > 0 && libraries.every(path => path.startsWith('/usr/lib/') || path.startsWith('/System/Library/')), 'only declared OS libraries may be linked');
    execFileSync('codesign', ['--verify', '--strict', executable], {stdio: 'pipe'});
    const signature = spawnSync('codesign', ['-dv', '--verbose=2', executable], {encoding: 'utf8'});
    assert.equal(signature.status, 0, signature.stderr);
    signing = /Signature=adhoc/.test(signature.stderr) ? 'ad-hoc' : 'verified; not release-qualified';
    const ancestors = [];
    for (let path = root;; path = dirname(path)) {
      ancestors.push(`(literal ${JSON.stringify(path)})`);
      if (dirname(path) === path) break;
    }
    const profile = join(controller, 'deployment.sb');
    writeFileSync(profile, `(version 1)\n(allow default)\n(deny process-exec)\n(allow process-exec (literal ${JSON.stringify(executable)}))\n(deny file-read-data)\n(allow file-read-data (literal ${JSON.stringify(executable)}) (subpath ${JSON.stringify(data)}) ${ancestors.join(' ')} (subpath "/System") (subpath "/usr/lib") (subpath "/dev"))\n(deny file-write*)\n(allow file-write* (subpath ${JSON.stringify(data)}) (subpath "/dev"))\n`, {mode: 0o600});
    writeFileSync(command, `#!/bin/sh\nexec /usr/bin/sandbox-exec -f ${shell(profile)} ${shell(executable)} "$@"\n`, {mode: 0o700});
  } else throw new Error('unqualified native deployment platform');
  return {data, controller, executable, command, async signal(child, signal) {
    if (process.platform !== 'linux') return child.kill(signal);
    // The launched PID is strace, not the application inside bwrap's new
    // session. Its private trace identifies the application's host PID.
    let application;
    for await (const execution of traceExecutions(join(controller, `trace.${child.pid}`))) {
      if (execution.path === executable) { application = execution.pid; break; }
    }
    assert(Number.isSafeInteger(application) && application > 1, 'trace must identify the original application PID');
    process.kill(application, signal);
  }, async close(passed) {
    try {
      let executions = 0;
      if (process.platform === 'linux' && passed) {
        const traces = readdirSync(controller).filter(name => name.startsWith('trace.'));
        assert(traces.length > 0, 'deployment must have an executed trace');
        for (const name of traces) {
          for await (const execution of traceExecutions(join(controller, name))) {
            assert(execution.path === '/usr/bin/bwrap' || execution.path === executable, `unexpected deployment executable: ${execution.path}`);
            if (execution.path === executable) executions++;
          }
        }
        assert(executions > 0);
      }
      console.log(JSON.stringify({native_deployment: name, passed, platform: process.platform, format, libraries, signing, sha256, bytes: binary.length, traced_executions: executions,
        boundary: process.platform === 'linux' ? 'private user/mount/PID namespaces' : 'OS file-read and executable allowlist'}));
    } finally { rmSync(root, {recursive: true, force: true}); }
  }};
}
