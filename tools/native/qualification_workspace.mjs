import {mkdirSync, realpathSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';

export function acquireWorkspace(parent, name) {
  mkdirSync(parent, {recursive: true});
  const directory = realpathSync(parent);
  for (let slot = 0; ; slot++) {
    const path = join(directory, name + ' ' + slot);
    const lease = new DatabaseSync(path + '.lock');
    try {
      lease.exec('BEGIN EXCLUSIVE');
    } catch (error) {
      lease.close();
      if (error.errcode === 5) continue;
      throw error;
    }
    const clean = () => rmSync(path, {recursive: true, force: true});
    try {
      clean();
      mkdirSync(path, {mode: 0o700});
    } catch (error) {
      lease.close();
      throw error;
    }
    function release() {
      if (!lease.isOpen) return;
      try { clean(); } finally { lease.close(); }
    }
    return {path, slot, release, [Symbol.dispose]: release};
  }
}

export function gitEnvironment(source = process.env) {
  const env = {...source, GIT_NO_REPLACE_OBJECTS: '1'};
  for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE', 'GIT_NAMESPACE',
    'GIT_SHALLOW_FILE', 'GIT_QUARANTINE_PATH', 'GIT_PREFIX', 'GIT_IMPLICIT_WORK_TREE', 'GIT_ATTR_SOURCE', 'GIT_CONFIG']) delete env[key];
  return env;
}
