// Qualification controller only. The application sees its executable, selected
// user data and OS facilities; source trees and language runtimes are excluded.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';

const shell = value => `'${value.replaceAll("'", "'\\''")}'`;

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
    const isolate = ['/usr/bin/bwrap', '--unshare-user', '--die-with-parent', '--new-session', '--uid', '0', '--gid', '0', '--info-fd', '3',
      '--proc', '/proc', '--dev', '/dev', '--ro-bind', executable, executable, '--bind', data, data, '--chdir'];
    writeFileSync(command, `#!/bin/sh\ndeployment_umask=$(umask)\numask 077\nexec 3>${shell(join(controller, 'info.'))}$$\numask "$deployment_umask"\nexec ${isolate.map(shell).join(' ')} "$PWD" ${shell(executable)} "$@"\n`, {mode: 0o700});
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
    assert.equal(child.exitCode, null, 'application launcher must still be running');
    assert.equal(child.signalCode, null, 'application launcher must still be running');
    const application = JSON.parse(readFileSync(join(controller, `info.${child.pid}`), 'utf8'))['child-pid'];
    assert(Number.isSafeInteger(application) && application > 1 && application !== child.pid, 'bubblewrap must identify the application PID');
    process.kill(application, signal);
  }, async close(passed) {
    try {
      console.log(JSON.stringify({native_deployment: name, passed, platform: process.platform, format, libraries, signing, sha256, bytes: binary.length,
        boundary: process.platform === 'linux' ? 'private user/mount namespaces' : 'OS file-read and executable allowlist'}));
    } finally { rmSync(root, {recursive: true, force: true}); }
  }};
}
