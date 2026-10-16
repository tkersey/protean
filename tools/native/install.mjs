// Optional installation helper. Runtime execution needs only the retained binary.
import {copyFile, mkdir, readFile, rename, rm, stat, symlink, writeFile} from 'node:fs/promises';
import {createHash, randomUUID} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {dirname, join, relative, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

async function identify(path) {
  const bytes = await readFile(path);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const result = spawnSync(path, ['describe-build'], {encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024});
  if (result.status !== 0) throw new Error(`Cannot identify runtime: ${result.stderr || result.error}`);
  const manifest = JSON.parse(result.stdout);
  if (manifest.artifact_sha256 !== sha256 || BigInt(manifest.artifact_bytes) !== BigInt(bytes.length)) throw new Error('Runtime manifest does not match its executable');
  return {sha256, manifest};
}

export async function install(source, prefix) {
  source = resolve(source); prefix = resolve(prefix);
  const bin = join(prefix, 'bin', 'protean');
  const runtimes = join(prefix, 'lib', 'protean', 'runtimes');
  await mkdir(runtimes, {recursive: true});
  await mkdir(dirname(bin), {recursive: true});
  async function retain(path) {
    const identity = await identify(path);
    const directory = join(runtimes, identity.sha256);
    const executable = join(directory, 'protean');
    try {
      const prior = await identify(executable);
      if (prior.sha256 !== identity.sha256) throw new Error('Conflicting retained runtime');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const temporary = join(runtimes, `.install-${randomUUID()}`);
      await mkdir(temporary);
      try {
        await copyFile(path, join(temporary, 'protean'));
        // Recheck after copying so a source changed during install cannot be
        // published under the wrong content identity.
        if ((await identify(join(temporary, 'protean'))).sha256 !== identity.sha256) throw new Error('Runtime changed during installation');
        await writeFile(join(temporary, 'describe-build.json'), `${JSON.stringify(identity.manifest, null, 2)}\n`);
        await rename(temporary, directory);
      } finally { await rm(temporary, {recursive: true, force: true}); }
    }
    return {...identity, executable};
  }
  let previous = null;
  try { await stat(bin); previous = await retain(bin); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const current = await retain(source);
  const link = join(dirname(bin), `.protean-${randomUUID()}`);
  try {
    await symlink(relative(dirname(bin), current.executable), link);
    await rename(link, bin);
  } finally { await rm(link, {force: true}); }
  return {current: current.executable, previous: previous?.executable ?? null, namespaces: 'unchanged; continue existing tasks with their retained runtime and original state directory'};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 4) throw new Error('Usage: node tools/native/install.mjs EXECUTABLE PREFIX');
  console.log(JSON.stringify(await install(process.argv[2], process.argv[3])));
}
