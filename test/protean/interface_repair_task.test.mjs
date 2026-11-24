import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {executeRepairTask} from '../../tools/evaluation/interface_repair_task.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');

async function setup(t) {
  const output = await mkdtemp(join(tmpdir(), 'protean-repair-runner-'));
  t.after(() => rm(output, {force: true, recursive: true}));
  const subject = {id: 'test-transfer', arm: 'repair', phase: 'transfer', case_id: 'test-case',
    case_path: join(output, 'case.json'), config: join(output, 'config.json'), config_sha256: hash('{}'),
    prompt: 'Classify the scan.', evidence: []};
  const bytes = JSON.stringify({case_id: subject.case_id, files: {}});
  await writeFile(subject.case_path, bytes);
  await writeFile(subject.config, '{}');
  const cases = {[subject.case_id]: {specimen: {path: subject.case_path, sha256: hash(bytes)}}};
  return {output, subject, build: {}, plan: {cases, cost_model: {kind: 'unpriced'}}, plan_sha256: 'a'.repeat(64),
    application: {}, driver: 'unused', credential: '/unopened', deadline: performance.now() + 2000};
}

test('a failed preflight retains the isolated task, reopens it only for measurements and charges unknowns', async t => {
  const options = await setup(t);
  const calls = [], launches = [], task_id = 'af'.repeat(16);
  class RejectedArchive {
    constructor(_, argv) { launches.push(argv); }
    async call(method) {
      calls.push(method);
      if (method === 'describe') return {execution_mode: 'live', profile: {id: 'adaptive'}};
      if (method === 'task.submit') return {task_id};
      if (method === 'evaluation.drain') return {step: 'idle'};
      throw new Error('UnexportableArchive');
    }
    async close() { return {code: 0, signal: null}; }
  }
  const report = await executeRepairTask(options, {Client: RejectedArchive});
  assert.equal(report.effective_condition, 'ordinary');
  assert.equal(report.fallback_reason, 'no_candidate');
  assert.equal(report.task.task_id, task_id);
  assert.deepEqual(calls, ['describe', 'task.submit', 'evaluation.export', 'evaluation.drain', 'evaluation.export']);
  assert.deepEqual(launches[1], [...launches[0], '--profile-task', task_id]);
  const descriptor = JSON.stringify({version: 1, plan_sha256: options.plan_sha256, submission_id: options.subject.id,
    prompt_sha256: hash(options.subject.prompt), phase: 'downstream', condition: 'ordinary', files: [], source_sha256: hash('')});
  assert.equal(launches[0].at(-1), hash(descriptor));
  assert.equal(report.archive, null);
  assert.equal(report.metrics, null);
  assert.equal(report.cost.total, null);
  assert(report.errors.some(e => e.stage === 'archive' && e.message === 'UnexportableArchive'));
  assert.deepEqual(JSON.parse(await readFile(join(options.output, 'report.json'))), report);
});

test('episode expiry kills the outstanding driver without a substitute dispatch', async t => {
  const options = await setup(t);
  options.deadline = performance.now() + 300;
  const calls = [];
  class StalledDriver {
    async call(method) {
      calls.push(method);
      return new Promise((_, reject) => { this.reject = reject; });
    }
    kill() { calls.push('killed'); this.reject(new Error('closed')); }
    async close() { return {code: null, signal: 'SIGKILL'}; }
  }
  const report = await executeRepairTask(options, {Client: StalledDriver});
  assert.equal(report.timed_out, true);
  assert.deepEqual(calls, ['describe', 'killed']);
  assert.equal(report.metrics, null);
  assert.equal(report.peak_rss_sampled_bytes, null);
  assert.equal(report.task, null);
});

test('changed frozen candidate bytes stop the task before launch', async t => {
  const options = await setup(t);
  const candidate = {source_b64: Buffer.from('changed source').toString('base64'), source_sha256: hash('frozen source')};
  const report = await executeRepairTask({...options, candidate}, {Client: class { constructor() { assert.fail('launched'); } }});
  assert.equal(report.task, null);
  assert(report.errors.some(e => e.stage === 'setup' && e.message.includes('Authored source changed')));
  assert.equal(report.adjudication, null);
});

test('diagnostic grading cannot consume a changed paired specimen after campaign validation', async t => {
  const options = await setup(t);
  const pair = JSON.stringify({case_id: 'paired-case', files: {}});
  const path = join(options.output, 'paired.json');
  options.subject.phase = 'diagnostic';
  options.subject.paired_case_path = path;
  options.plan.cases['paired-case'] = {specimen: {path, sha256: hash(pair)}};
  await writeFile(path, pair + '\n');
  const report = await executeRepairTask(options, {Client: class { constructor() { assert.fail('launched'); } }});
  assert.equal(report.task, null);
  assert(report.errors.some(e => e.stage === 'setup' && e.message.includes('Frozen case changed')));
  assert.equal(report.adjudication, null);
});
