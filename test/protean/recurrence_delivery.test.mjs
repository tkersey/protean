import assert from 'node:assert/strict';
import test from 'node:test';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createInterface} from 'node:readline';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {RecurrenceDelivery, RecurrenceTrace, RecurrenceDriver, prepareRecurrence, validateRecurrencePlan,
  recurrenceCost, recurrenceExpenditure, physicalProviderAttempt, presentedValues, adjudicateRecurrence, armViolations, inferenceArguments} from '../../tools/evaluation/workspace.mjs';

const packets = [
  {id: 'initial', offset_ms: 0, bytes: 'initial'},
  {id: 'next', offset_ms: 100, bytes: 'next facts'},
  {id: 'end', offset_ms: 200, bytes: 'END'},
];
const plan = {questions: {'Please send the next request.': {kind: 'wait'},
  'What is a component identity?': {kind: 'fact', text: 'Use exact string identities.'}},
  queued_reminder: 'Consume queued inputs.'};
const question = {question_id: 'q1', question_revision: '3', request_digest: 'digest',
  answer_schema_id: 'adaptive-agent.answer.v2', prompt: {prompt: 'Please send the next request.'}};

test('driver termination owns helpers and closes inherited pipes', {timeout: 15000}, async () => {
  const signals = ['SIGINT', 'SIGTERM', 'exit'];
  const listeners = signals.map(signal => process.listenerCount(signal));
  for (const forced of [true, false]) {
    const program = `
      const {spawn} = require('node:child_process');
      const {createInterface} = require('node:readline');
      const helper = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {stdio: 'inherit'});
      createInterface({input: process.stdin}).on('line', line => {
        const {id} = JSON.parse(line);
        process.stdout.write(JSON.stringify({id, result: {helper: helper.pid}}) + '\\n');
      }).on('close', () => process.exit(0));
    `;
    const driver = new RecurrenceDriver(process.execPath, ['-e', program]);
    try {
      const {helper} = await driver.call('ready');
      process.kill(helper, 0);
      if (forced) assert(driver.kill());
      const exit = forced ? await driver.waitClosed() : await driver.close();
      assert.deepEqual(exit, forced ? {code: null, signal: 'SIGKILL'} : {code: 0, signal: null});
      assert.equal(driver.kill(), false);
      for (let retry = 0; retry < 100; retry++) {
        try { process.kill(helper, 0); }
        catch (error) { assert.equal(error.code, 'ESRCH'); break; }
        assert(retry < 99, 'driver helper remained alive after process-group termination');
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    } finally { driver.kill(); await driver.waitClosed(); }
  }
  assert.deepEqual(signals.map(signal => process.listenerCount(signal)), listeners);
});

test('supervisor exit terminates all currently owned driver groups', {timeout: 15000}, async () => {
  const module = new URL('../../tools/evaluation/workspace.mjs', import.meta.url).href;
  const program = `
    const {spawn} = require('node:child_process');
    const {createInterface} = require('node:readline');
    const helper = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {stdio: 'inherit'});
    createInterface({input: process.stdin}).on('line', line => {
      const {id} = JSON.parse(line);
      process.stdout.write(JSON.stringify({id, result: {helper: helper.pid}}) + '\\n');
    }).on('close', () => process.exit(0));
  `;
  const supervisorSource = `
    import {RecurrenceDriver} from ${JSON.stringify(module)};
    const retired = new RecurrenceDriver(process.execPath, ['-e', ${JSON.stringify(program)}]);
    await retired.call('ready');
    await retired.close();
    const groups = [];
    for (let index = 0; index < 2; index++) {
      const driver = new RecurrenceDriver(process.execPath, ['-e', ${JSON.stringify(program)}]);
      groups.push({driver: driver.child.pid, ...(await driver.call('ready'))});
    }
    process.stdin.once('data', () => process.exit(7));
    console.log(JSON.stringify(groups));
  `;
  for (const signal of ['SIGINT', 'SIGTERM', null]) {
    const supervisor = spawn(process.execPath, ['--input-type=module', '-e', supervisorSource], {stdio: ['pipe', 'pipe', 'pipe']});
    const exited = once(supervisor, 'exit');
    const reader = createInterface({input: supervisor.stdout});
    let groups = [];
    try {
      const ready = await Promise.race([once(reader, 'line'), exited.then(exit => { throw new Error(`Supervisor exited before ready: ${exit}`); })]);
      groups = JSON.parse(ready[0]);
      if (signal) assert(supervisor.kill(signal));
      else supervisor.stdin.end('exit');
      assert.deepEqual(await exited, signal ? [null, signal] : [7, null]);
      for (const pid of groups.flatMap(group => [group.driver, group.helper])) {
        for (let retry = 0; retry < 100; retry++) {
          try { process.kill(pid, 0); }
          catch (error) { assert.equal(error.code, 'ESRCH'); break; }
          assert(retry < 99, `owned process ${pid} survived supervisor ${signal ?? 'exit'}`);
          await new Promise(resolve => setTimeout(resolve, 10));
        }
      }
    } finally {
      if (supervisor.exitCode === null && supervisor.signalCode === null) supervisor.kill('SIGKILL');
      await exited;
      reader.close();
      for (const group of groups) {
        try { process.kill(-group.driver, 'SIGKILL'); }
        catch (error) { assert.equal(error.code, 'ESRCH'); }
      }
    }
  }
});

test('waiting preserves schedule and uses exactly one channel per packet', () => {
  const delivery = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  assert.equal(delivery.next('task', {question}, 99), null);
  assert.equal(delivery.unresolved, null);
  const response = delivery.next('task', {question}, 100);
  assert.equal(response.method, 'task.respond');
  assert.equal(response.params.answer.value.message, 'next facts');
  assert.equal(response.params.question_revision, '3');
  delivery.acknowledge(response, {receipt_id: 'receipt'}, 101);
  assert.equal(delivery.next('task', {}, 199), null);
  const end = delivery.next('task', {}, 200);
  assert.equal(end.method, 'task.message');
  assert.equal(end.params.message.value.message, 'END');
  delivery.acknowledge(end, {message_id: 'm2'}, 201);
  assert.equal(delivery.next('task', {}, 1000), null);
  assert.equal(delivery.operations.filter(item => item.packet_id === 'next').length, 1);
});

test('queued END releases a waiting question without duplicating END or waiting forever', () => {
  const delivery = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  const next = delivery.next('task', {}, 100);
  delivery.acknowledge(next, {message_id: 'm1'}, 101);
  const end = delivery.next('task', {}, 200, ['next']);
  delivery.acknowledge(end, {message_id: 'm2'}, 201);
  const answer = delivery.next('task', {question}, 250, ['next']);
  assert.equal(answer.packet_id, null);
  assert.equal(answer.params.answer.value.message, plan.queued_reminder);
  assert.equal(delivery.operations.filter(item => item.packet_id === 'end').length, 1);
});

test('reopen replays exact unacknowledged response including its original question binding', () => {
  const before = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  const operation = before.next('task', {question}, 100);
  const persisted = JSON.parse(JSON.stringify(before.operations));
  const after = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan, persisted);
  assert.deepEqual(after.next('task', {}, 250), operation);
  after.acknowledge(after.operations[0], {receipt_id: 'original'}, 251);
  assert.equal(after.next('task', {}, 250).packet_id, 'end');
});

test('only predeclared facts answer substantive questions', () => {
  const delivery = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  const fact = {...question, prompt: {prompt: 'What is a component identity?'}};
  assert.equal(delivery.next('task', {question: fact}, 1).params.answer.value.message, 'Use exact string identities.');
  const other = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  assert.equal(other.next('task', {question: {...question, prompt: {prompt: 'Which requests are blocked?'}}}, 1), null);
  assert.match(other.unresolved.reason, /No predeclared/);
  const inherited = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  assert.equal(inherited.next('task', {question: {...question, prompt: {prompt: '__proto__'}}}, 100), null);
  assert.match(inherited.unresolved.reason, /No predeclared/);
});

test('queued input cannot authorize an unknown question or replace a declared fact', () => {
  for (const throughEnd of [false, true]) {
    for (const text of ['Which requests are blocked?', 'Model request failed. Retry?', '__proto__']) {
      const delivery = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
      const next = delivery.next('task', {}, 100);
      delivery.acknowledge(next, {message_id: 'm1'}, 101);
      if (throughEnd) {
        const end = delivery.next('task', {}, 200, ['next']);
        delivery.acknowledge(end, {message_id: 'm2'}, 201);
      }
      assert.equal(delivery.next('task', {question: {...question, prompt: {prompt: text}}}, 250,
        throughEnd ? ['next'] : []), null);
      assert.match(delivery.unresolved.reason, /No predeclared/);
    }
    const delivery = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
    const next = delivery.next('task', {}, 100);
    delivery.acknowledge(next, {message_id: 'm1'}, 101);
    if (throughEnd) {
      const end = delivery.next('task', {}, 200, ['next']);
      delivery.acknowledge(end, {message_id: 'm2'}, 201);
    }
    const fact = {...question, prompt: {prompt: 'What is a component identity?'}};
    assert.equal(delivery.next('task', {question: fact}, 250, throughEnd ? ['next'] : []).params.answer.value.message,
      'Use exact string identities.');
  }
});

test('preparation freezes six pairs and isolates all later bytes from snapshots and catalogs', async () => {
  const root = await mkdtemp(join(tmpdir(), 'protean-recurrence-'));
  try {
    const binary = join(root, 'product'), driver = join(root, 'driver'), applicationPath = join(root, 'application.json');
    await writeFile(binary, 'product'); await writeFile(driver, 'driver'); await writeFile(applicationPath, '{}');
    const config = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.example.json', import.meta.url)));
    const directory = join(root, 'plan');
    const prepared = await prepareRecurrence({config, directory, binary, driver, applicationPath});
    assert.equal(prepared.cases.length, 6);
    assert.equal(new Set(prepared.cases.map(item => item.pair)).size, 3);
    for (const subject of prepared.cases) {
      const corpus = JSON.parse(await readFile(subject.corpus));
      assert.equal(corpus.requests.length, 12);
      const initial = await readFile(join(subject.snapshot, 'initial.txt'), 'utf8');
      assert.equal(initial, corpus.packets[0].bytes);
      const selected = JSON.parse(await readFile(subject.config));
      assert.deepEqual(selected.tools.inputs, []);
      assert.equal(selected.tools.reconstruct, false);
      for (const packet of corpus.packets.slice(1)) {
        assert(!initial.includes(packet.bytes));
        assert(!subject.prompt.includes(packet.bytes));
      }
    }
    await validateRecurrencePlan(directory, {binary, driver, applicationPath});
    await writeFile(prepared.cases[0].corpus, '{}');
    await assert.rejects(validateRecurrencePlan(directory, {binary, driver, applicationPath}), /Frozen corpus changed/);
  } finally { await rm(root, {recursive: true, force: true}); }
});

test('monetary costs require complete usage, cache charges and deployment pricing', () => {
  const report = {metrics: {controller: {calls: 1}, delegated: {calls: 0}}, elapsed_ms: 2000,
    retained_namespace_bytes: 100};
  const model = {kind: 'tariff', predeclared: true, id: 'test', currency: 'USD',
    provider_source: 'fixture tariff', deployment_source: 'fixture deployment', host_includes_attempt_storage: true, input_per_million: 2,
    cached_input_per_million: 1, output_per_million: 4, host_per_second: 0.1,
    storage_per_byte_second: 0.001, retention_seconds: 10};
  const usage = {input_tokens: 1000000, output_tokens: 1000000, input_tokens_details: {cached_tokens: 500000}};
  const cost = recurrenceCost(report, model, [usage]);
  assert.equal(cost.complete, true);
  assert.equal(cost.total, 6.7);
  assert.equal(recurrenceCost(report, model, [null]).complete, false);
  assert.equal(recurrenceCost(report, model, [{input_tokens: 1, output_tokens: 1}]).complete, false);
  assert.equal(recurrenceCost(report, {...model, host_per_second: null}, [usage]).complete, false);
  assert.equal(recurrenceCost(report, {...model, predeclared: false}, [usage]).complete, false);
});

test('mechanical reuse preserves the first boundary and rejects equal effective input digests', () => {
  const trace = new RecurrenceTrace({packets: []}, {});
  trace.visibility.set('p1', {visibility_epoch: 1, publication_epoch: 4});
  trace.visibility.set('p2', {visibility_epoch: 2, publication_epoch: 8});
  const first = {kind: 'program', artifact_id: 'program', work_id: 'w1', input_sha256: 'input1',
    visibility_epoch: 1, created_epoch: 2};
  trace.uses.push(first, {...first, work_id: 'w2', visibility_epoch: 2});
  assert.equal(trace.qualifyingBoundary({epoch: 9}, 100), null);
  trace.uses[1].input_sha256 = 'input2';
  const boundary = trace.qualifyingBoundary({epoch: 9, worker_active: true}, 100);
  assert.equal(boundary.worker_active, true);
  trace.first_boundary = boundary;
  trace.observe({events: [], attempts: [], records: [], epoch: 10, worker_active: false}, 101);
  assert.equal(trace.first_boundary, boundary);
});

function computedDescriptionTrace() {
  const trace = new RecurrenceTrace({packets: []}, {});
  const reference = digest => ({digest, bytes: '1'});
  const records = [
    {kind: 'workspace_program', value: {id: 'program', artifact: reference('program-artifact'),
      description: {source_kind: 'source_records'}}},
    {kind: 'workspace_work', value: {id: 'work', program: 'program-artifact', outcome_kind: 'completed', result: reference('result')}},
    {kind: 'workspace_value', value: {id: 'index', artifact: reference('index-artifact'), description: {value: reference('result')},
      derivation: {kind: 'computation', sources: {items: []}, program: reference('program-artifact'), work: 'work'}}},
    {kind: 'workspace_view', value: {id: 'view', artifact: reference('view-artifact'),
      description: {values: {items: [reference('index-artifact')]}}}},
  ];
  for (const record of records) trace.records.set(`${record.kind}:${record.value.id}`,
    {...record, created_epoch: 1, creation_seq: 1});
  for (let epoch = 1; epoch <= 3; epoch++) {
    trace.visibility.set(`packet-${epoch}`, {visibility_epoch: epoch, publication_epoch: epoch + 1, preparation_cut: epoch + 1});
    trace.attempts.set(`attempt-${epoch}`, {id: `attempt-${epoch}`, selected_view: 'view-artifact',
      capture: {disposition: 'complete'}, provider_response: true, visibility_epoch: epoch,
      after_restart: epoch === 3});
  }
  return trace;
}

test('one authored computation can support later retained-description use and recovery', () => {
  const trace = computedDescriptionTrace();
  trace.descriptionUses(5, 100);
  assert.equal(trace.uses.length, 3);
  assert(trace.uses.every(use => use.kind === 'description' && use.artifact_id === 'index-artifact'));
  assert.equal(trace.qualifyingBoundary({epoch: 5}, 100).artifact_id, 'index-artifact');
  trace.cut = {artifact_id: 'index-artifact'};
  assert.equal(trace.summary().post_restart_uses.length, 1);
  trace.descriptionUses(6, 110);
  assert.equal(trace.uses.length, 3);
});

test('computed description candidates require matching authored-program and completed-result lineage', () => {
  const mutations = [
    trace => trace.records.get('workspace_value:index').value.derivation.kind = 'acquisition',
    trace => trace.records.get('workspace_value:index').value.derivation.program.digest = 'another-program',
    trace => trace.records.get('workspace_value:index').value.derivation.work = 'missing-work',
    trace => trace.records.get('workspace_value:index').value.description.value.digest = 'another-result',
    trace => trace.records.get('workspace_program:program').value.description.source_kind = 'component_recipe',
    trace => trace.records.get('workspace_work:work').value.outcome_kind = 'failed',
    trace => trace.records.get('workspace_work:work').value.program = 'another-program',
    trace => { for (const attempt of trace.attempts.values()) attempt.selected_view = null; },
  ];
  for (const mutate of mutations) {
    const trace = computedDescriptionTrace();
    mutate(trace);
    trace.descriptionUses(5, 100);
    assert.deepEqual(trace.uses, []);
  }
});

function reviewFixture() {
  const uses = [
    {kind: 'program', artifact_id: 'p', work_id: 'w1', input_sha256: 'input-1', created_epoch: 2,
      visibility_epoch: 1, observed_ms: 10, after_restart: false},
    {kind: 'program', artifact_id: 'p', work_id: 'w2', input_sha256: 'input-2', created_epoch: 2,
      visibility_epoch: 2, observed_ms: 30, after_restart: false},
    {kind: 'program', artifact_id: 'p', work_id: 'w3', input_sha256: 'input-3', created_epoch: 2,
      visibility_epoch: 3, observed_ms: 50, after_restart: true},
  ];
  const answers = ['r1', 'r2', 'r3'].map(request_id => ({request_id, artifact_refs: ['p']}));
  const boundary = {artifact_id: 'p', earlier: uses[0], later: uses[1]};
  const report = {task: {task_id: 'task'}, grading: {answers: [
    {request_id: 'r1', sound: true, expected: 'ready'}, {request_id: 'r2', sound: true, expected: 'blocked'},
    {request_id: 'r3', sound: true, expected: 'ready'}]},
    result: {outcome: {value: {result: {tag: 'report', value: {summary: JSON.stringify({answers})}}}}},
    reuse: {uses, authored_evidence: [{artifact_id: 'p', kind: 'program', source_sha256: 'source'}],
      visibility: [{packet_id: 'packet1', confirmed: true, publication_epoch: 1, visibility_epoch: 1},
        {packet_id: 'packet2', confirmed: true, publication_epoch: 3, visibility_epoch: 2},
        {packet_id: 'packet3', confirmed: true, publication_epoch: 5, visibility_epoch: 3}],
      first_boundary: boundary,
      cut: {...boundary, task_id: 'task', exit: {signal: 'SIGKILL'}, reopened_ms: 40}}};
  const corpus = {packets: ['r1', 'r2', 'r3'].map((request, i) =>
    ({id: `packet${i + 1}`, offset_ms: i * 20, request_ids: [request]}))};
  const judgment = {artifact_id: 'p', source_sha256: 'source', relationship: 'Required closure over supplied manifests',
    scope: 'Exact manifests and flags', observed_inadequacy: 'Repeated reconstruction',
    source_review: 'Traverses supplied requirements and reads current validation records', general_relationship: true,
    constant_or_case_lookup: false, scope_handling_correct: true,
    uses: uses.map((use, i) => ({use_id: use.work_id, request_id: `r${i + 1}`,
      effective_input_matches_records: true, supports_answer: true, scope_valid: true}))};
  return {report, corpus, judgment};
}

test('changed-input supported reuse must survive source and scope review in the same interrupted trace', () => {
  const {report, corpus, judgment} = reviewFixture();
  const result = adjudicateRecurrence(report, corpus, judgment);
  assert.equal(result.qualified, true);
  assert.equal(result.recovered, true);
  assert.equal(adjudicateRecurrence(report, corpus, {...judgment, constant_or_case_lookup: true}).qualified, false);
  assert.equal(adjudicateRecurrence(report, corpus, {...judgment, scope_handling_correct: false}).qualified, false);
  assert.equal(adjudicateRecurrence(report, corpus, {...judgment, source_sha256: 'another-source'}).qualified, false);
  report.reuse.uses = [];
  assert.equal(adjudicateRecurrence(report, corpus, judgment).qualified, false);
});

test('answer references bind public artifacts and results rather than task custody records', () => {
  for (const reference of ['p', 'result-artifact', 'custody']) {
    const {report, corpus, judgment} = reviewFixture();
    report.reuse.authored_evidence[0].custody_id = 'custody';
    for (const use of report.reuse.uses) Object.assign(use, {custody_id: 'custody', result_artifact_id: 'result-artifact'});
    report.result.outcome.value.result.value.summary = JSON.stringify({answers:
      ['r1', 'r2', 'r3'].map(request_id => ({request_id, artifact_refs: [reference]}))});
    assert.equal(adjudicateRecurrence(report, corpus, judgment).qualified, reference !== 'custody');
  }
});

test('availability, late construction and a separate recovery fixture cannot establish discovery', () => {
  const {report, corpus, judgment} = reviewFixture();
  report.result.outcome.value.result.value.summary = JSON.stringify({answers: []});
  assert.equal(adjudicateRecurrence(report, corpus, judgment).qualified, false);
  const fresh = reviewFixture();
  fresh.report.reuse.uses[1].created_epoch = 3;
  assert.equal(adjudicateRecurrence(fresh.report, fresh.corpus, fresh.judgment).qualified, false);
  const separate = reviewFixture();
  separate.report.reuse.cut.task_id = 'another-task';
  assert.equal(adjudicateRecurrence(separate.report, separate.corpus, separate.judgment).recovered, false);
});

test('reuse adjudication keeps valid answer siblings and safely rejects malformed maps', () => {
  const valid = reviewFixture();
  const summary = valid.report.result.outcome.value.result.value;
  const answers = JSON.parse(summary.summary).answers;
  summary.summary = JSON.stringify({answers: [null, ...answers, {request_id: 'unrecognized'}]});
  assert.equal(adjudicateRecurrence(valid.report, valid.corpus, valid.judgment).qualified, true);
  for (const raw of ['broken', 'null', '{}', '{"answers":null}', '{"answers":{}}', '{"answers":[null]}']) {
    const {report, corpus, judgment} = reviewFixture();
    report.result.outcome.value.result.value.summary = raw;
    assert.equal(adjudicateRecurrence(report, corpus, judgment).qualified, false);
  }
  for (const malformed of [undefined, null, 'p', {}]) {
    const {report, corpus, judgment} = reviewFixture();
    report.result.outcome.value.result.value.summary = JSON.stringify({answers: answers.map(answer =>
      ({...answer, artifact_refs: malformed}))});
    assert.equal(adjudicateRecurrence(report, corpus, judgment).qualified, false);
  }
  const duplicate = reviewFixture();
  duplicate.report.result.outcome.value.result.value.summary = JSON.stringify({answers: [...answers, ...answers]});
  assert.equal(adjudicateRecurrence(duplicate.report, duplicate.corpus, duplicate.judgment).qualified, false);
});

test('favorable later uses cannot replace an irrelevant first interruption proxy', () => {
  const {report, corpus, judgment} = reviewFixture();
  const original = {...report.reuse.uses[0], work_id: 'internal-test'};
  report.reuse.first_boundary.earlier = original;
  report.reuse.cut.earlier = original;
  report.reuse.uses.push(original);
  const result = adjudicateRecurrence(report, corpus, judgment);
  assert.equal(result.qualified, false);
  assert.equal(result.recovered, false);
  assert(result.adjudication.failures.some(item => item.includes('original first interruption proxy')));
});

test('recurrence permits projections and observations while preserving the packaged runtime', () => {
  const actions = [
    {name: 'context', arguments: {command: {tag: 'materialize', value: {input: {tag: 'guest_view'}}}}},
    {name: 'context', arguments: {command: {tag: 'select'}}},
    {name: 'work', arguments: {command: {tag: 'observe'}}},
    {name: 'program', arguments: {command: {tag: 'build'}}},
  ];
  assert.deepEqual(armViolations('recurrence', actions), []);
  assert.equal(armViolations('ordinary', actions).length, 4);
  const forbidden = [{name: 'reconstruct'},
    {name: 'work', arguments: {command: {tag: 'realize_controller'}}},
    {name: 'program', arguments: {command: {tag: 'specialize'}}}];
  assert.deepEqual(armViolations('recurrence', forbidden), forbidden);
});

test('inference source selection preserves SIWC and excludes mixed billing', () => {
  assert.deepEqual(inferenceArguments({chatgptAccount: 'personal'}),
    ['--authorize-inference', '--chatgpt-account', 'personal']);
  assert.deepEqual(inferenceArguments({credential: '/private/key'}),
    ['--authorize-inference', '--credential-file', '/private/key']);
  assert.throws(() => inferenceArguments({}));
  assert.throws(() => inferenceArguments({credential: '/private/key', chatgptAccount: 'personal'}));
  assert.throws(() => inferenceArguments({credential: '/private/key', siwcBin: '/bin/siwc'}));
});

test('projected presentation counts rendered values and computed payloads, not dependencies', () => {
  const reference = digest => ({digest, bytes: '1'});
  const projection = {result: reference('index-artifact'), program: reference('program-artifact'),
    values: {items: [reference('index-artifact'), reference('source-artifact')]}, blocks: [
      {tag: 'explanation', value: 'An explanation is not a retained description.'},
      {tag: 'value', value: {kind: 'value', id: 'index-artifact'}},
      {tag: 'source', value: {value: {kind: 'value', id: 'source-artifact'}, offset: '2', length: '3'}},
      {tag: 'computed', value: {}},
    ]};
  const description = {values: {items: []}, projection};
  assert.deepEqual(presentedValues(description), [
    {kind: 'value', artifact_id: 'index-artifact'},
    {kind: 'source', artifact_id: 'source-artifact', offset: '2', length: '3'},
    {kind: 'computed', artifact_id: 'index-artifact'},
  ]);
  const trace = computedDescriptionTrace();
  trace.records.get('workspace_view:view').value.description = description;
  trace.descriptionUses(5, 100);
  assert.equal(trace.uses.length, 3);
  assert(trace.uses.every(use => use.artifact_id === 'index-artifact' && use.view_id === 'view-artifact'));
  projection.values.items = [];
  projection.blocks = [{tag: 'explanation', value: 'No retained payload.'}];
  trace.uses = [];
  trace.descriptionUses(6, 110);
  assert.deepEqual(trace.uses, []);
  projection.blocks = [{tag: 'computed', value: {}}];
  trace.descriptionUses(7, 120);
  assert.equal(trace.uses.length, 3);
});

test('provider accounting distinguishes not-sent, rearmed, cancelled, and unknown acquisitions', () => {
  const id = 'a', other = 'b';
  const states = [
    [{tag: 0, value: null}, false],
    [{tag: 6, value: [id]}, false],
    ...[1, 2, 3, 4, 7].flatMap(tag => [[{tag, value: [id]}, true], [{tag, value: [other]}, false]]),
    [{tag: 5, value: {tag: 1, value: null}}, false],
    [{tag: 5, value: {tag: 0, value: [id]}}, true],
    [{tag: 5, value: {tag: 0, value: [other]}}, false],
    [undefined, true],
  ];
  for (const [state, possible] of states) {
    assert.equal(physicalProviderAttempt(id, undefined, state), possible);
    assert.equal(physicalProviderAttempt(id, 1, state), false);
    assert.equal(physicalProviderAttempt(id, 0, state), true);
    assert.equal(physicalProviderAttempt(id, 2, state), true);
    const trace = new RecurrenceTrace({packets: []}, {});
    trace.dispatched({step: 'dispatched', attempt: id, capability: 'agent.model.invoke.v13', epoch: 1}, 10);
    trace.observeAttempt({attempt: {id, capability: 'agent.model.invoke.v13'}, occurrence: {state},
      physical_provider_attempt: physicalProviderAttempt(id, undefined, state)}, 2, 20);
    const report = {elapsed_ms: 100, retained_namespace_bytes: 0, reuse: trace.summary(),
      cost: {total: null, complete: false}};
    const curve = recurrenceExpenditure(report, {kind: 'unpriced'}), final = curve.at(-1);
    assert.equal(curve.find(point => point.elapsed_ms === 10).physical_attempts, 1);
    assert.equal(curve.find(point => point.elapsed_ms === 10).input_tokens, null);
    assert.equal(final.physical_attempts, possible ? 1 : 0);
    assert.equal(final.input_tokens, possible ? null : 0);
  }
});

test('lost dispatch acknowledgments retain unknown timing and final archive expenditure', () => {
  const trace = new RecurrenceTrace({packets: []}, {});
  trace.observeAttempt({attempt: {id: 'lost-ack', capability: 'agent.model.invoke.v13'},
    physical_provider_attempt: true}, 1, 30);
  const report = {elapsed_ms: 100, retained_namespace_bytes: 0, reuse: trace.summary(),
    metrics: {physical_attempts: [{id: 'lost-ack', usage: {input_tokens: 7, output_tokens: 3}}]},
    cost: {total: null, complete: false}};
  const curve = recurrenceExpenditure(report, {kind: 'unpriced'});
  assert.equal(curve.at(-1).physical_attempts, 1);
  assert.equal(curve.at(-1).input_tokens, 7);
  assert.equal(curve.at(-1).output_tokens, 3);
  assert.equal(curve[0].physical_attempts, null);
  assert.equal(curve[0].input_tokens, null);
  assert.equal(curve.find(point => point.elapsed_ms === 30).physical_attempts, 1);
  assert.equal(curve.find(point => point.elapsed_ms === 30).input_tokens, null);
  assert.equal(report.reuse.attempts[0].dispatched_ms, undefined);
  assert.deepEqual(report.reuse.visibility, []);
  report.metrics.physical_attempts[0].usage.output_tokens = -1;
  const malformed = recurrenceExpenditure(report, {kind: 'unpriced'}).at(-1);
  assert.equal(malformed.physical_attempts, 1);
  assert.equal(malformed.input_tokens, null);
  assert.equal(malformed.output_tokens, null);
  report.metrics = null;
  const unavailable = recurrenceExpenditure(report, {kind: 'unpriced'}).at(-1);
  assert.equal(unavailable.physical_attempts, null);
  assert.equal(unavailable.known_physical_attempts, 1);
  assert.equal(unavailable.input_tokens, null);
});

test('program reuse joins public content while preserving custody and work identities', () => {
  const reference = digest => ({digest, bytes: '1'});
  const trace = new RecurrenceTrace({packets: []}, {});
  const observe = (records, epoch, events = []) => trace.observe({records, events, attempts: [], epoch}, epoch * 10);
  observe([{kind: 'workspace_program', value: {id: 'custody', artifact: reference('public'),
    description: {source_kind: 'source_records'}}}], 1, [{seq: '1', kind: 'workspace', data: JSON.stringify({workspace_id: 'public'})}]);
  for (let epoch = 1; epoch <= 2; epoch++) {
    trace.epoch = epoch;
    trace.visibility.set(`packet-${epoch}`, {visibility_epoch: epoch, publication_epoch: epoch + 2, preparation_cut: 2});
    observe([{kind: 'workspace_work', value: {id: `work-${epoch}`, program: 'public',
      input: reference(`input-${epoch}`), outcome_kind: 'completed', result: reference(`result-${epoch}`),
      result_value: reference(`result-artifact-${epoch}`)}}], epoch + 2);
  }
  assert.equal(trace.uses.length, 2);
  assert(trace.uses.every(use => use.artifact_id === 'public' && use.custody_id === 'custody' && use.creation_seq === 1));
  assert.deepEqual(trace.uses.map(use => use.result_artifact_id), ['result-artifact-1', 'result-artifact-2']);
  assert.equal(trace.first_boundary.artifact_id, 'public');
  const boundary = trace.first_boundary;
  observe([], 10);
  assert.equal(trace.first_boundary, boundary);
});
