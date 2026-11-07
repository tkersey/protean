import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {RecurrenceDelivery, RecurrenceTrace, prepareRecurrence, validateRecurrencePlan,
  recurrenceCost, adjudicateRecurrence, armViolations} from '../../tools/evaluation/workspace.mjs';

const packets = [
  {id: 'initial', offset_ms: 0, bytes: 'initial'},
  {id: 'next', offset_ms: 100, bytes: 'next facts'},
  {id: 'end', offset_ms: 200, bytes: 'END'},
];
const plan = {questions: {'Please send the next request.': {kind: 'wait'},
  'What is a component identity?': {kind: 'fact', text: 'Use exact string identities.'}},
  queued_reminder: 'Consume queued inputs.'};
const question = {question_id: 'q1', question_revision: '3', request_digest: 'digest',
  answer_schema_id: 'adaptive-agent.answer.v2', prompt: {question: 'Please send the next request.'}};

test('waiting preserves schedule and uses exactly one channel per packet', () => {
  const delivery = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  assert.equal(delivery.next('task', {question}, 99), null);
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
  const fact = {...question, prompt: {question: 'What is a component identity?'}};
  assert.equal(delivery.next('task', {question: fact}, 1).params.answer.value.message, 'Use exact string identities.');
  const other = new RecurrenceDelivery({id: 'attempt'}, {packets}, plan);
  assert.equal(other.next('task', {question: {...question, prompt: {question: 'Which requests are blocked?'}}}, 1), null);
  assert.match(other.unresolved.reason, /No predeclared/);
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
