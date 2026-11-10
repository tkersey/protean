import assert from 'node:assert/strict';
import test from 'node:test';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {encodeSchema, encodeValue} from '../support/values.mjs';
import {createCorpus, createOnlineCorpus, parseOnlineAnswer, gradeReport, gradeOnlineAnswers,
  combineOnlineGrading, oracle} from '../../tools/evaluation/recurrence.mjs';
import {RecurrenceDelivery, RecurrenceTrace, prepareRecurrence, validateRecurrencePlan, recurrenceStatus,
  resolveQuestion, sourceAcquisition} from '../../tools/evaluation/workspace.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const envelope = (packetId, answers) => JSON.stringify({kind: 'recurrence.answers.v1',
  packet_id: packetId, answers});

function example() {
  const targets = [{component: 'A', revision: '1'}, {component: 'B', revision: '1'}];
  const records = targets.flatMap((target, index) => [
    {kind: 'manifest', id: `m${index}`, ...target, complete: true, requirements: []},
    {kind: 'receipt', id: `r${index}`, ...target, scope: 'release', available: true,
      result: index === 0 ? 'pass' : 'fail'},
  ]);
  const requests = targets.map((target, index) => ({id: `q${index}`, target, scope: 'release',
    flags: {}, manifest_ids: [`m${index}`], receipt_ids: [`r${index}`]}));
  const packets = requests.map((request, index) => ({id: `p${index}`, offset_ms: index * 100,
    request_ids: [request.id], bytes: JSON.stringify({packet_id: `p${index}`,
      requests: [request], source_ranges: []})}));
  packets.push({id: 'end', offset_ms: 200, request_ids: [],
    bytes: JSON.stringify({packet_id: 'end', event: 'END'})});
  const answers = [
    {request_id: 'q0', status: 'ready', records: ['m0', 'r0'], artifact_refs: [],
      support: {coverage: [{...targets[0], receipts: ['r0']}]}},
    {request_id: 'q1', status: 'blocked', records: ['m1', 'r1'], artifact_refs: [],
      support: {blocker: targets[1], path: [targets[1]]}},
  ];
  const corpus = {delivery: 'online', records, requests, packets,
    sources: {'records.jsonl': records.map(record => JSON.stringify(record) + '\n').join('')}};
  const visibility = packets.map((packet, index) => ({packet_id: packet.id, confirmed: true,
    preparation_cut: String((index + 1) * 10)}));
  const events = answers.map((answer, index) => ({event_seq: String(index * 10 + 15),
    question_id: `question-${index}`, question_revision: '1', request_digest: `digest-${index}`,
    raw: envelope(packets[index].id, [answer]), observed_ms: index * 100 + 50}));
  for (const event of events) event.acquisition = {question_id: event.question_id,
    question_revision: event.question_revision, request_digest: event.request_digest,
    attempt_id: 'native-attempt', complete: true, record_ids: records.map(record => record.id)};
  return {corpus, answers, visibility, events};
}

const grading = value => gradeOnlineAnswers(value.corpus, value.events, value.visibility);
const row = (grade, id = 'q0') => grade.answers.find(answer => answer.request_id === id);
const finalGrade = (value, acquired = value.corpus.records.map(record => record.id)) => {
  const raw = JSON.stringify({answers: value.answers});
  return gradeReport(raw, value.corpus, null, acquired === null ? null : {
    summary_sha256: hash(raw), result_sha256: 'native-result', attempt_id: 'native-final-attempt',
    complete: true, record_ids: acquired});
};

test('legacy final-only corpora retain their frozen bytes', () => {
  const identities = [
    '9b2337bbbfe409bffd818f18ed10ed0b6e64d4b1098984d5ef6d939194971548',
    '8e2f954e6d3f09351c2b42cc2cc86de8c5067586d1510345e65d2e5e55dadaf6',
    'b065bd8f6132ae093b486e9e6a2ab7cafc5c4e779c14cdff157b70cf9cae8ec4',
  ];
  identities.forEach((identity, index) => assert.equal(hash(JSON.stringify(createCorpus(index + 1))), identity));
});

test('online snapshots contain immutable records without future request selections', () => {
  for (const seed of [1, 2, 3]) {
    const corpus = createOnlineCorpus(seed), source = Buffer.from(corpus.sources['records.jsonl']);
    assert.deepEqual(Object.keys(corpus.sources), ['records.jsonl']);
    assert.deepEqual(source.toString().trimEnd().split('\n').map(JSON.parse), corpus.records);
    const initial = corpus.contract + corpus.packets[0].bytes + source.toString();
    for (const request of corpus.requests.filter(item => !corpus.packets[0].request_ids.includes(item.id))) {
      assert.equal(initial.includes(JSON.stringify(request.id)), false);
      assert.equal(initial.includes(JSON.stringify(request)), false);
    }
    const known = new Set(corpus.records.map(record => record.id));
    for (const packet of corpus.packets.filter(item => item.request_ids.length)) {
      const contents = JSON.parse(packet.bytes), located = [];
      assert.equal(Object.hasOwn(contents, 'documents'), false);
      assert.deepEqual(contents.requests.map(request => request.id), packet.request_ids);
      for (const range of contents.source_ranges) {
        assert.equal(range.path, 'records.jsonl');
        assert(Number.isSafeInteger(range.start) && range.start >= 0);
        assert(Number.isSafeInteger(range.length) && range.length > 0 && range.length <= 4096);
        assert(range.start + range.length <= source.length);
        const bytes = source.subarray(range.start, range.start + range.length);
        assert.equal(bytes.at(-1), 10);
        located.push(...bytes.toString().trimEnd().split('\n').map(line => JSON.parse(line).id));
      }
      const required = new Set(contents.requests.flatMap(request =>
        [...request.manifest_ids, ...request.receipt_ids]).filter(id => known.has(id)));
      assert.deepEqual([...located].sort(), [...required].sort());
    }
  }
});

test('strict answer envelopes reject wrappers, extra fields and wrong structural types', () => {
  const {events} = example(), valid = events[0].raw;
  assert.deepEqual(parseOnlineAnswer(valid), JSON.parse(valid));
  const value = JSON.parse(valid);
  for (const raw of [`Here is the answer: ${valid}`, `${valid} trailing`, 'null', '[]', '{}',
    JSON.stringify({...value, extra: true}), JSON.stringify({...value, kind: 'answers'}),
    JSON.stringify({...value, packet_id: 1}), JSON.stringify({...value, answers: {}})]) {
    assert.equal(parseOnlineAnswer(raw), null, raw);
  }
});

test('ordinary supported answers earn complete success without retained construction', () => {
  const value = example();
  assert.deepEqual(value.corpus.requests.map(request => oracle(request, value.corpus.records).status),
    ['ready', 'blocked']);
  const online = grading(value);
  assert.equal(online.complete, true);
  assert.deepEqual(online.totals, {requests: 2, sound: 2, critical: 0, unanswered: 0});
  assert.deepEqual(combineOnlineGrading(finalGrade(value), online).totals, online.totals);
  assert(value.answers.every(answer => answer.artifact_refs.length === 0));
});

test('a perfect final report cannot replace missing online deliveries', () => {
  const value = example();
  const final = finalGrade(value);
  assert.equal(final.totals.sound, 2);
  value.events = [];
  assert.deepEqual(combineOnlineGrading(final, grading(value)).totals,
    {requests: 2, sound: 0, critical: 0, unanswered: 2});
});

test('answers require selection exposure before publication and precede the next exposure', () => {
  for (const [sequence, sound] of [['9', false], ['10', false], ['11', true], ['20', true], ['21', false]]) {
    const value = example();
    value.events[0].event_seq = sequence;
    assert.equal(row(grading(value)).sound, sound, `answer event ${sequence}`);
  }
  const value = example();
  value.events[0].observed_ms = 1000;
  assert.equal(row(grading(value)).sound, true);
});

test('large decimal event sequences retain exact exposure boundaries', () => {
  for (const [sequence, sound] of [['9007199254740992', false], ['9007199254740993', true],
    ['9007199254740994', true], ['9007199254740995', false]]) {
    const value = example();
    value.visibility[0].preparation_cut = '9007199254740992';
    value.visibility[1].preparation_cut = '9007199254740994';
    value.visibility[2].preparation_cut = '9007199254740998';
    value.events[0].event_seq = sequence;
    value.events[1].event_seq = '9007199254740996';
    assert.equal(row(grading(value)).sound, sound, sequence);
  }
});

test('unknown or unconfirmed source cuts never confer timely credit', () => {
  const changes = [
    value => { value.visibility[0].confirmed = false; },
    value => { delete value.visibility[0].preparation_cut; },
    value => { value.visibility[0].preparation_cut = 'bad'; },
    value => { value.visibility[0].preparation_cut = 9007199254740992; },
    value => { value.visibility[1].preparation_cut = null; },
  ];
  for (const change of changes) {
    const value = example();
    change(value);
    assert.equal(row(grading(value)).sound, false);
  }
});

test('missing native question bindings and malformed event sequences earn no credit', () => {
  const changes = [
    ['question_id', undefined], ['question_id', ''], ['request_digest', undefined],
    ['request_digest', ''], ['question_revision', undefined], ['question_revision', '-1'],
    ['event_seq', undefined], ['event_seq', ''], ['event_seq', '-1'], ['event_seq', '1.5'],
    ['event_seq', 9007199254740992],
  ];
  for (const [field, invalid] of changes) {
    const value = example();
    value.events[0][field] = invalid;
    assert.equal(row(grading(value)).sound, false, `${field}: ${invalid}`);
  }
});

test('future guesses cannot be bundled into the current packet or repaired later', () => {
  const value = example();
  value.events[0].raw = envelope('p0', value.answers);
  assert.equal(grading(value).totals.sound, 0);
  const guessed = example();
  guessed.events.unshift({...guessed.events[1], event_seq: '12', question_id: 'early'});
  assert.equal(row(grading(guessed), 'q1').sound, false);
  const unknown = example();
  unknown.events[0].raw = envelope('invented-packet', [unknown.answers[0]]);
  assert.equal(row(grading(unknown)).sound, false);
});

test('duplicate batches and duplicate answers cannot earn additional or restored credit', () => {
  const value = example();
  value.events.splice(1, 0, {...value.events[0], event_seq: '16', question_revision: '2'});
  assert.equal(row(grading(value)).sound, false);
  assert.equal(grading(value).complete, false);
  const repeated = example();
  repeated.events[0].raw = envelope('p0', [repeated.answers[0], repeated.answers[0]]);
  assert.equal(row(grading(repeated)).sound, false);
  assert.equal(row(grading(repeated)).critical, true);
});

test('identical replay deduplicates while conflicting replay invalidates its credit', () => {
  const value = example();
  value.events.push(structuredClone(value.events[0]));
  const replayed = grading(value);
  assert.equal(replayed.deliveries.length, 2);
  assert.deepEqual(replayed.totals, {requests: 2, sound: 2, critical: 0, unanswered: 0});
  const conflict = example();
  const unsupported = {...conflict.answers[0], status: 'blocked', support: {
    blocker: conflict.corpus.requests[0].target, path: [conflict.corpus.requests[0].target]}};
  conflict.events.push({...conflict.events[0], raw: envelope('p0', [unsupported])});
  assert.equal(row(grading(conflict)).sound, false);
  assert.equal(row(grading(conflict)).critical, true);
  const rebound = example();
  rebound.events.push({...rebound.events[0], question_id: 'another-question'});
  assert.equal(row(grading(rebound)).sound, false);
});

test('an earlier unsupported conclusion remains critical after online and final corrections', () => {
  const value = example();
  const correction = {...value.events[0], event_seq: '16', question_revision: '2'};
  value.events[0].raw = envelope('p0', [{...value.answers[0], records: [], support: {coverage: []}}]);
  value.events.splice(1, 0, correction);
  const correctedFinal = finalGrade(value);
  assert.equal(correctedFinal.totals.sound, 2);
  const combined = combineOnlineGrading(correctedFinal, grading(value));
  assert.equal(row(combined).critical, true);
  assert.equal(row(combined).sound, false);
  assert.equal(combined.totals.critical, 1);
  assert.equal(combined.totals.sound, 1);
});

test('valid online work cannot hide an unsupported final conclusion', () => {
  const value = example(), online = grading(value);
  value.answers[0].records = [];
  const combined = combineOnlineGrading(finalGrade(value), online);
  assert.equal(row(combined).critical, true);
  assert.equal(row(combined).sound, false);
});

test('resource observations preserve counter precision and missing usage stays unknown', () => {
  const counters = {admitted_attempts: '18446744073709551615', request_bytes: '9007199254740993',
    known_output_tokens: '0'};
  const status = {inference_observation: counters};
  assert.deepEqual(recurrenceStatus(status, 25, {wall_ms: 100}),
    {remaining_wall_ms: 75, inference_observation: counters});
  assert.deepEqual(recurrenceStatus({}, 25, {wall_ms: 100}), {remaining_wall_ms: 75,
    inference_observation: {admitted_attempts: null, request_bytes: null, known_output_tokens: null}});
  assert.equal(recurrenceStatus(status, 101, {wall_ms: 100}).remaining_wall_ms, 0);
  assert.deepEqual(status.inference_observation, counters);
});

test('online replies carry frozen resource status and replay the original question binding', () => {
  const value = example();
  const plan = {suite: 'recurrence-online', limits: {wall_ms: 1000}, questions: {
    'Please send the next request.': {kind: 'wait'}}, queued_reminder: 'Consume queued inputs.'};
  const question = {question_id: 'native-question', question_revision: '3', request_digest: 'native-digest',
    answer_schema_id: 'adaptive-agent.answer.v2', prompt: {prompt: value.events[0].raw}};
  const status = {question, inference_observation: {admitted_attempts: '4', request_bytes: '12000',
    known_output_tokens: '500'}};
  const before = new RecurrenceDelivery({id: 'attempt'}, value.corpus, plan);
  assert.equal(before.next('task', status, 99), null);
  const operation = before.next('task', status, 100);
  assert.equal(operation.method, 'task.respond');
  assert.equal(operation.packet_id, 'p1');
  assert.equal(operation.params.question_id, question.question_id);
  assert.equal(operation.params.request_digest, question.request_digest);
  assert.equal(operation.params.answer.value.message, value.corpus.packets[1].bytes + '\n\n' +
    JSON.stringify({evaluation_status: recurrenceStatus(status, 100, plan.limits)}));
  const after = new RecurrenceDelivery({id: 'attempt'}, value.corpus, plan,
    JSON.parse(JSON.stringify(before.operations)));
  const replay = after.next('task', {inference_observation: {admitted_attempts: '99'}}, 900);
  assert.deepEqual(replay, operation);
  assert.equal(replay.params.question_revision, '3');
});

test('online acknowledgments provide no correctness feedback or oracle-derived response', () => {
  const value = example();
  const plan = {suite: 'recurrence-online', limits: {wall_ms: 1000}, questions: {},
    queued_reminder: 'Consume queued inputs.'};
  const deliver = raw => {
    const question = {question_id: 'same-question', question_revision: '1', request_digest: 'same-digest',
      answer_schema_id: 'adaptive-agent.answer.v2', prompt: {prompt: raw}};
    return new RecurrenceDelivery({id: 'attempt'}, value.corpus, plan).next('task', {question}, 100);
  };
  const correct = deliver(value.events[0].raw);
  const incorrect = deliver(envelope('p0', [{...value.answers[0], status: 'blocked'}]));
  assert.deepEqual(incorrect, correct);
});

test('online plan snapshots expose source records while withholding future selections', async () => {
  const root = await mkdtemp(join(tmpdir(), 'protean-online-plan-'));
  try {
    const binary = join(root, 'product'), driver = join(root, 'driver'), applicationPath = join(root, 'application.json');
    await writeFile(binary, 'product');
    await writeFile(driver, 'driver');
    await writeFile(applicationPath, '{}');
    const config = JSON.parse(await readFile(new URL('../../examples/adaptive/adaptive.example.json', import.meta.url)));
    const directory = join(root, 'plan');
    const plan = await prepareRecurrence({config, directory, binary, driver, applicationPath,
      suite: 'recurrence-online'});
    assert.equal(plan.format, 'protean-recurrence-evaluation/2');
    assert.equal(plan.suite, 'recurrence-online');
    for (const subject of plan.cases) {
      const corpus = JSON.parse(await readFile(subject.corpus));
      const files = await readdir(subject.snapshot);
      assert.deepEqual(files.sort(), ['contract.txt', 'initial.txt', 'records.jsonl']);
      const source = await readFile(join(subject.snapshot, 'records.jsonl'), 'utf8');
      assert.equal(source, corpus.sources['records.jsonl']);
      const initial = await readFile(join(subject.snapshot, 'initial.txt'), 'utf8');
      assert.equal(initial, corpus.packets[0].bytes);
      for (const request of corpus.requests.filter(item => !corpus.packets[0].request_ids.includes(item.id)))
        assert.equal((source + initial + subject.prompt).includes(JSON.stringify(request.id)), false);
      const selected = JSON.parse(await readFile(subject.config));
      assert.deepEqual(selected.tools.inputs, []);
    }
    await validateRecurrencePlan(directory, {binary, driver, applicationPath});
    await writeFile(join(plan.cases[0].snapshot, 'records.jsonl'), 'changed');
    await assert.rejects(validateRecurrencePlan(directory, {binary, driver, applicationPath}), /Frozen evidence/);
  } finally { await rm(root, {recursive: true, force: true}); }
});

test('artifact-backed questions retain exact bytes and native question scope across chunks', async () => {
  const prompt = {prompt: 'Request evidence ' + '\u{1f642}'.repeat(9000)};
  const bytes = Buffer.from(JSON.stringify(prompt)), digest = hash(bytes), calls = [];
  const question = {question_id: 'native-question', question_revision: '5', request_digest: 'native-digest',
    answer_schema_id: 'adaptive-agent.answer.v2', prompt_ref: {artifact_id: digest, sha256: digest,
      bytes: String(bytes.length), question_id: 'native-question'}};
  const original = structuredClone(question);
  const client = {async call(method, params) {
    calls.push({method, params});
    const start = Number(params.offset), end = Math.min(start + 32768, bytes.length);
    return {sha256: digest, data: bytes.subarray(start, end).toString('base64url'),
      next_offset: String(end), eof: end === bytes.length};
  }};
  const resolved = await resolveQuestion(client, 'task', question);
  assert.deepEqual(resolved.prompt, prompt);
  assert.deepEqual(Buffer.from(resolved.prompt_b64, 'base64url'), bytes);
  assert.deepEqual(question, original);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls.map(call => call.params.offset), ['0', '32768']);
  for (const call of calls) {
    assert.equal(call.method, 'artifact.read');
    assert.equal(call.params.task_id, 'task');
    assert.equal(call.params.question_id, question.question_id);
    assert.equal(call.params.artifact_id, digest);
  }
});

test('artifact-backed questions reject changed digest and incomplete byte length', async () => {
  const bytes = Buffer.from(JSON.stringify({prompt: 'question'})), digest = hash(bytes);
  const reference = {artifact_id: digest, sha256: digest, bytes: String(bytes.length), question_id: 'q'};
  for (const change of [{sha256: '0'.repeat(64)}, {bytes: String(bytes.length + 1)}]) {
    const question = {question_id: 'q', prompt_ref: {...reference, ...change}};
    const client = {async call() { return {sha256: digest, data: bytes.toString('base64url'),
      next_offset: String(bytes.length), eof: true}; }};
    await assert.rejects(resolveQuestion(client, 'task', question));
  }
});

const ownerEvent = (sequence, kind, data = {}, revision = sequence) => ({
  seq: String(sequence), revision: String(revision), kind, data: JSON.stringify(data),
});

function exposureTrace(corpus, operations, events) {
  const trace = new RecurrenceTrace(corpus, {}, operations);
  trace.observe({events, attempts: [], records: [], epoch: 1}, 0);
  return trace;
}

function exposePacket(trace, packet, options = {}) {
  const id = options.id ?? 'prepared-attempt';
  const capability = 'protean.workspace.inference/2';
  if (options.dispatched !== false) trace.dispatched({step: 'dispatched', attempt: id,
    capability, epoch: 2}, options.elapsed ?? packet.offset_ms);
  const body = JSON.stringify({input: [{role: 'assistant', content: packet.bytes}]});
  trace.observeAttempt({attempt: {id, capability, preparation_cut: options.cut ?? '2'},
    physical_provider_attempt: options.physical ?? options.dispatched !== false,
    prepared_b64: Buffer.from('prepared-native-envelope').toString('base64'),
    prepared_context: {body_b64: Buffer.from(body).toString('base64'), selected_view: null}},
  3, Math.max(300, options.elapsed ?? packet.offset_ms));
  return trace.visibility.get(packet.id);
}

function completeModel(trace, id) {
  const schema = {root: 0, types: [{product: [1, 2, 3, 3, 4, 4, 4, 4]},
    'u16', 'boolean', 'bytes', 'u8']};
  const wire = Buffer.from(encodeSchema(schema));
  trace.application = {support: {CapturedResponse: {wire_base64url: wire.toString('base64url'),
    wire_sha256: hash(wire)}}};
  const response = Buffer.from(encodeValue(schema, [200, true, [],
    Buffer.from('{"usage":{"input_tokens":1,"output_tokens":1}}'), 0, 0, 0, 2])).toString('base64');
  trace.observeAttempt({attempt: trace.attempts.get(id).owner, physical_provider_attempt: true,
    capture: {disposition: 'complete'}, response_b64: response}, 4, 400);
}

test('initial selection requires admitted input before an actual model dispatch', () => {
  const {corpus} = example(), packet = corpus.packets[0];
  const absent = exposureTrace(corpus, [], []);
  assert.equal(exposePacket(absent, packet), undefined);
  for (const options of [{cut: '0'}, {dispatched: false}]) {
    const trace = exposureTrace(corpus, [], [ownerEvent(1, 'accepted')]);
    assert.equal(exposePacket(trace, packet, options), undefined);
  }
  const trace = exposureTrace(corpus, [], [ownerEvent(1, 'accepted')]);
  const visible = exposePacket(trace, packet, {cut: '1'});
  assert.equal(visible.packet_id, packet.id);
  assert.equal(visible.confirmed, false);
  assert.equal(trace.attempts.get('prepared-attempt').request_profile.serialized_bytes,
    Buffer.byteLength(JSON.stringify({input: [{role: 'assistant', content: packet.bytes}]})));
});

test('agent-created packet text cannot replace a scheduled admitted message', () => {
  const {corpus} = example(), packet = corpus.packets[1];
  const events = [ownerEvent(1, 'accepted'), ownerEvent(2, 'message_queued', {message_id: 'native-message'})];
  const admitted = {packet_id: packet.id, method: 'task.message', acknowledged: true,
    params: {message: {value: {message: packet.bytes}}},
    result: {message_id: 'native-message', receipt_revision: '2'}};
  const cases = [
    {operations: []},
    {operations: [{...admitted, acknowledged: false}]},
    {operations: [{...admitted, params: {message: {value: {message: 'unrelated message'}}}}]},
    {operations: [{...admitted, result: {message_id: 'other-message', receipt_revision: '2'}}]},
    {operations: [admitted], options: {cut: '1'}},
    {operations: [admitted], options: {elapsed: packet.offset_ms - 1}},
  ];
  for (const item of cases) {
    const trace = exposureTrace(corpus, item.operations, events);
    assert.equal(exposePacket(trace, packet, item.options), undefined);
  }
  const trace = exposureTrace(corpus, [admitted], events);
  assert.equal(exposePacket(trace, packet).packet_id, packet.id);
});

test('answer-carried selections require the exact admitted answer revision', () => {
  const {corpus} = example(), packet = corpus.packets[1];
  const events = [ownerEvent(1, 'accepted'), ownerEvent(2, 'input_accepted', {}, 7)];
  const admitted = {packet_id: packet.id, method: 'task.respond', acknowledged: true,
    params: {answer: {value: {message: packet.bytes}}},
    result: {receipt_revision: '7'}};
  for (const change of [{acknowledged: false}, {result: {receipt_revision: '6'}}, {result: {}},
    {params: {answer: {value: {message: 'unrelated answer'}}}}]) {
    const trace = exposureTrace(corpus, [{...admitted, ...change}], events);
    assert.equal(exposePacket(trace, packet), undefined);
  }
  const trace = exposureTrace(corpus, [admitted], events);
  const visible = exposePacket(trace, packet);
  assert.equal(visible.packet_id, packet.id);
  assert.equal(BigInt(visible.preparation_cut), 2n);
});

test('lost delivery acknowledgments replay the original admission before exposure', () => {
  const {corpus} = example(), packet = corpus.packets[1];
  const plan = {suite: 'recurrence-online', limits: {wall_ms: 1000}, questions: {},
    queued_reminder: 'Consume queued inputs.'};
  const before = new RecurrenceDelivery({id: 'attempt'}, corpus, plan);
  const operation = before.next('task', {}, packet.offset_ms);
  const reopened = new RecurrenceDelivery({id: 'attempt'}, corpus, plan,
    JSON.parse(JSON.stringify(before.operations)));
  const replayed = reopened.next('task', {}, 175);
  assert.deepEqual(replayed, operation);
  const events = [ownerEvent(1, 'accepted'), ownerEvent(2, 'message_queued', {message_id: 'original-message'})];
  const unacknowledged = exposureTrace(corpus, reopened.operations, events);
  assert.equal(exposePacket(unacknowledged, packet, {elapsed: 175}), undefined);
  reopened.acknowledge(replayed, {message_id: 'original-message', receipt_revision: '2', replayed: true}, 175);
  const trace = exposureTrace(corpus, reopened.operations, events);
  const original = exposePacket(trace, packet, {id: 'first-dispatch', elapsed: 176});
  exposePacket(trace, packet, {id: 'later-dispatch', elapsed: 190});
  assert.equal(trace.visibility.size, 1);
  assert.equal(trace.visibility.get(packet.id), original);
  assert.equal(original.attempt_id, 'first-dispatch');
});

test('replayed speculative captures cannot confirm a later admitted selection', () => {
  const {corpus} = example(), packet = corpus.packets[1], operations = [];
  const trace = exposureTrace(corpus, operations, [ownerEvent(1, 'accepted')]);
  assert.equal(exposePacket(trace, packet, {id: 'speculative', cut: '1'}), undefined);
  operations.push({packet_id: packet.id, method: 'task.message', acknowledged: true,
    params: {message: {value: {message: packet.bytes}}}, result: {message_id: 'native-message'}});
  trace.observe({events: [ownerEvent(2, 'message_queued', {message_id: 'native-message'})],
    attempts: [], records: [], epoch: 2}, 305);
  const visible = exposePacket(trace, packet, {id: 'admitted', cut: '2', elapsed: 310});
  completeModel(trace, 'speculative');
  assert.equal(visible.confirmed, false);
  completeModel(trace, 'admitted');
  assert.equal(visible.confirmed, true);
  assert.equal(visible.confirmation.attempt_id, 'admitted');
});

test('successful exposure cannot certify an earlier request that was never sent', () => {
  const {corpus} = example(), packet = corpus.packets[1];
  const operations = [{packet_id: packet.id, method: 'task.message', acknowledged: true,
    params: {message: {value: {message: packet.bytes}}}, result: {message_id: 'native-message'}}];
  const trace = exposureTrace(corpus, operations,
    [ownerEvent(1, 'accepted'), ownerEvent(2, 'message_queued', {message_id: 'native-message'})]);
  exposePacket(trace, packet, {id: 'not-sent', cut: '2', elapsed: 100});
  trace.observeAttempt({attempt: trace.attempts.get('not-sent').owner, physical_provider_attempt: false,
    capture: {disposition: 'definitely_not_sent'}}, 3, 301);
  exposePacket(trace, packet, {id: 'successful', cut: '5', elapsed: 310});
  completeModel(trace, 'successful');
  const visible = trace.visibility.get(packet.id);
  assert.equal(visible.confirmed, true);
  assert.equal(visible.attempt_id, 'successful');
  assert.equal(BigInt(visible.preparation_cut), 5n);
  assert.equal(visible.dispatch_ms, 310);
  assert.equal(visible.prepared_sha256, trace.attempts.get('successful').prepared_sha256);
});

test('unknown dispatch timing cannot confirm another prepared request', () => {
  const {corpus} = example(), packet = corpus.packets[1];
  const operations = [{packet_id: packet.id, method: 'task.message', acknowledged: true,
    params: {message: {value: {message: packet.bytes}}}, result: {message_id: 'native-message'}}];
  const trace = exposureTrace(corpus, operations,
    [ownerEvent(1, 'accepted'), ownerEvent(2, 'message_queued', {message_id: 'native-message'})]);
  const candidate = exposePacket(trace, packet, {id: 'known-dispatch'});
  exposePacket(trace, packet, {id: 'unknown-dispatch', dispatched: false});
  completeModel(trace, 'unknown-dispatch');
  assert.equal(candidate.confirmed, false);
  completeModel(trace, 'known-dispatch');
  assert.equal(candidate.confirmed, true);
  assert.equal(candidate.confirmation.attempt_id, 'known-dispatch');
});

test('possibly sent selections constrain deadlines until non-delivery is established', () => {
  const value = example(), {corpus} = value, packet = corpus.packets[1];
  const operations = [{packet_id: packet.id, method: 'task.message', acknowledged: true,
    params: {message: {value: {message: packet.bytes}}}, result: {message_id: 'native-message'}}];
  const trace = exposureTrace(corpus, operations,
    [ownerEvent(1, 'accepted'), ownerEvent(2, 'message_queued', {message_id: 'native-message'})]);
  exposePacket(trace, packet, {id: 'unknown-dispatch', dispatched: false, physical: true, cut: '2'});
  exposePacket(trace, packet, {id: 'successful', cut: '5', elapsed: 310});
  completeModel(trace, 'successful');
  let visible = trace.visibility.get(packet.id);
  assert.equal(BigInt(visible.confirmed_preparation_cut), 5n);
  assert.equal(BigInt(visible.possible_preparation_cut), 2n);
  value.visibility[0].preparation_cut = '1';
  value.visibility[1] = visible;
  value.visibility[2].preparation_cut = '10';
  value.events[0].event_seq = '3';
  value.events[1].event_seq = '4';
  const uncertain = grading(value);
  assert.equal(row(uncertain).sound, false);
  assert(row(uncertain).errors.includes('answer_after_next_selection'));
  assert.equal(row(uncertain, 'q1').sound, false);
  assert(row(uncertain, 'q1').errors.includes('request_not_selected'));
  trace.observeAttempt({attempt: trace.attempts.get('unknown-dispatch').owner,
    physical_provider_attempt: false, capture: {disposition: 'definitely_not_sent'}}, 5, 410);
  visible = trace.visibility.get(packet.id);
  assert.equal(BigInt(visible.possible_preparation_cut), 5n);
  value.visibility[1] = visible;
  assert.equal(row(grading(value)).sound, true);
  assert.equal(row(grading(value), 'q1').sound, false);
});

test('out-of-order captures retain the earliest confirmed admitted exposure', () => {
  const {corpus} = example(), packet = corpus.packets[1];
  const operations = [{packet_id: packet.id, method: 'task.message', acknowledged: true,
    params: {message: {value: {message: packet.bytes}}}, result: {message_id: 'native-message'}}];
  const trace = exposureTrace(corpus, operations,
    [ownerEvent(1, 'accepted'), ownerEvent(2, 'message_queued', {message_id: 'native-message'})]);
  exposePacket(trace, packet, {id: 'earlier', cut: '2', elapsed: 100});
  exposePacket(trace, packet, {id: 'later', cut: '5', elapsed: 310});
  completeModel(trace, 'later');
  assert.equal(BigInt(trace.visibility.get(packet.id).confirmed_preparation_cut), 5n);
  completeModel(trace, 'earlier');
  const visible = trace.visibility.get(packet.id);
  assert.equal(BigInt(visible.confirmed_preparation_cut), 2n);
  assert.equal(BigInt(visible.possible_preparation_cut), 2n);
  assert.equal(visible.attempt_id, 'earlier');
  assert.equal(visible.confirmation.attempt_id, 'earlier');
});


test('selection identities cannot substitute for acquired support', () => {
  const value = example();
  value.events[0].acquisition.record_ids = [];
  const result = grading(value);
  assert.equal(row(result).sound, false);
  assert.equal(row(result).critical, true);
  assert(row(result).errors.includes('unacquired_support'));
  assert.equal(result.complete, false);
  assert.equal(finalGrade(value).totals.sound, 2);
});

test('missing acquisition remains unknown and known errors still decide failure', () => {
  for (const change of [event => { delete event.acquisition; },
    event => { event.acquisition.question_id = 'another-question'; },
    event => { event.acquisition.attempt_id = ''; },
    event => { event.acquisition.complete = false; event.acquisition.record_ids = []; }]) {
    const value = example();
    change(value.events[0]);
    const result = grading(value);
    assert.equal(row(result).sound, null);
    assert.equal(row(result).critical, null);
    assert.equal(result.complete, null);
    const combined = combineOnlineGrading(finalGrade(value), result);
    assert.equal(combined.totals.sound, null);
    value.answers[1].status = 'ready';
    const failedFinal = combineOnlineGrading(finalGrade(value), result);
    assert.equal(failedFinal.complete, false);
    assert.equal(failedFinal.answers.find(answer => answer.request_id === 'q1').sound, false);
    value.answers[0].status = 'blocked';
    value.events[0].raw = envelope('p0', [value.answers[0]]);
    assert.equal(row(grading(value)).sound, false);
    assert.equal(row(grading(value)).critical, true);
    assert.equal(grading(value).complete, false);
  }
});

function acquisitionFixture() {
  const {corpus} = example(), source = Buffer.from(corpus.sources['records.jsonl']);
  const producer = {question_id: 'question', question_revision: '1', request_digest: 'request',
    task_id: '01'.repeat(16), controller_id: '02'.repeat(32), controller_epoch: '0',
    interaction_id: '03'.repeat(32), event_cut: '30', attempt_id: '04'.repeat(32)};
  const origin = {snapshot: {digest: '05'.repeat(32), bytes: '1000'}, path: 'records.jsonl',
    file_digest: hash(source), start: '0', end: String(source.length), file_bytes: String(source.length)};
  const interaction = {...producer, evidence: [], results: [], result_actions: [], source_artifacts: []};
  const value = (id, derivation) => ({kind: 'workspace_value', native_derivation: derivation,
    value: {id, task: producer.task_id, artifact: {digest: id, bytes: '1'},
      description: {provenance: {digest: id + '-source', bytes: '1'}}}});
  return {corpus, source, producer, origin, interaction, value};
}

test('source coverage follows consumed native computations and retained collect or wait results', () => {
  for (const command of ['collect', 'wait', 'inspect']) {
    const f = acquisitionFixture();
    const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin}),
      f.value('computed', {kind: 'computation', sources: [{digest: 'acquired', bytes: '1'}]})];
    const observed = {result: {kind: 'value', id: 'computed'}};
    const earlier = {...f.interaction, interaction_id: 'earlier', event_cut: '20',
      results: [{call_id: 'call', output: {tag: 'workspace', value: {reply: {disposition: 'observed',
        observation_json: JSON.stringify(command === 'collect' ? [observed] : command === 'wait' ? {works: [observed]} : observed)}}}}],
      result_actions: [{call_id: 'call', action: {tag: 'work', value: {command: {tag: command, value: {}}}}}]};
    const result = sourceAcquisition(f.corpus, f.producer, [earlier, f.interaction], records, true);
    assert.equal(result.complete, true);
    assert.deepEqual(result.record_ids, f.corpus.records.map(record => record.id));
    earlier.result_actions[0].action = {tag: 'placement', value: {command: {tag: 'control',
      value: {operation: 'owned-operation', command: {tag: command, value: {}}}}}};
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [earlier, f.interaction], records, true).record_ids,
      result.record_ids);
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids, []);
    earlier.event_cut = '31';
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [earlier, f.interaction], records, true).record_ids, []);
  }
});

test('direct acquisitions require exact source bytes and combine adjacent consumed ranges', () => {
  const f = acquisitionFixture(), boundary = f.source.indexOf(10) + 1;
  const direct = (start, end) => ({tag: 'source', value: {object: {digest: `${start}:${end}`, bytes: '1'}}});
  const evidence = [direct(0, boundary - 2), direct(boundary - 2, boundary)];
  f.interaction.evidence = evidence;
  f.interaction.source_artifacts = evidence.map((entry, index) => {
    const start = index ? boundary - 2 : 0, end = index ? boundary : boundary - 2;
    return {object: entry.value.object, task_id: f.producer.task_id,
      evidence: {...f.origin, sha256: hash(f.source), start, end, content: f.source.subarray(start, end).toString()}};
  });
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], [], true);
  assert.deepEqual(result().record_ids, ['m0']);
  f.interaction.source_artifacts[1].evidence.content = 'invented';
  assert.deepEqual(result().record_ids, []);
  assert.equal(result().complete, false);
  f.interaction.source_artifacts[1].evidence.content = f.source.subarray(boundary - 2, boundary).toString();
  f.interaction.source_artifacts[0].task_id = 'other-task';
  assert.deepEqual(result().record_ids, []);
  assert.equal(result().complete, false);
});

test('source expansion uses native source identity and actual returned page', () => {
  const f = acquisitionFixture();
  f.interaction.results = [{call_id: 'call', output: {tag: 'workspace', value: {reply: {disposition: 'observed',
    observation_json: JSON.stringify({text: f.source.toString(), offset: 0, next_offset: f.source.length})}}}}];
  f.interaction.result_actions = [{call_id: 'call', action: {tag: 'context', value: {command: {tag: 'expand',
    value: {reference: {kind: 'source', id: 'acquired-source'}}}}}}];
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: {...f.origin, end: '1'}})];
  assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids,
    f.corpus.records.map(record => record.id));
  f.interaction.result_actions[0].call_id = 'unrelated-call';
  const missing = sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  assert.deepEqual(missing.record_ids, []);
  assert.equal(missing.complete, false);
});

test('unconsumed work, hypotheses, forged lineage and other producer scopes receive no acquisition credit', () => {
  const f = acquisitionFixture();
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin}),
    f.value('assertion', {kind: 'judgment', sources: [{digest: 'acquired', bytes: '1'}]})];
  f.interaction.evidence = [{tag: 'workspace', value: {kind: 'value', id: 'assertion'}}];
  assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids, []);
  f.interaction.controller_id = 'another-controller';
  const missing = sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  assert.equal(missing.complete, false);
  assert.equal(sourceAcquisition(f.corpus, null, [f.interaction], records, true), null);
});

test('native delegated judgments and trial inputs retain acquisition without trusting authored judgments', () => {
  for (const kind of ['computation', 'trial']) {
    const f = acquisitionFixture();
    const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin}),
      f.value('model', {kind: 'judgment', sources: [{digest: 'acquired', bytes: '1'}],
        work: 'child', delegation: {digest: 'delegation'}, capture: {digest: 'capture'}}),
      f.value('result', {kind, sources: [{digest: 'model', bytes: '1'}]})];
    records[1].native_acquisition = {complete: true, inputs: [{kind: 'value', id: 'acquired'}],
      selected_view: null, port_inputs: []};
    f.interaction.evidence = [{tag: 'workspace', value: {kind: 'value', id: 'result'}}];
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids,
      f.corpus.records.map(record => record.id));
    delete records[1].native_derivation.capture;
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids, []);
  }
});

test('question producer is retained before its paged event and cannot be replaced by a later producer', () => {
  const f = acquisitionFixture(), value = example();
  f.corpus.packets = [];
  const trace = new RecurrenceTrace(f.corpus, {});
  const record = {kind: 'controller_interaction', value: {id: f.producer.interaction_id, task: f.producer.task_id},
    acquisition: f.interaction};
  trace.observe({epoch: 1, events: [], attempts: [], records: [record], question_producer: f.producer,
    acquisition_records_complete: true}, 1);
  const event = {seq: '1', kind: 'input_required', data: {bytes: JSON.stringify({...f.producer,
    prompt: {prompt: value.events[0].raw}})}};
  trace.observe({epoch: 2, events: [event], attempts: [], records: [], question_producer: null}, 2);
  trace.acquisitionEvidence();
  assert.equal(trace.answer_events[0].acquisition.attempt_id, f.producer.attempt_id);
  assert.equal(trace.answer_events[0].acquisition.complete, true);
  assert.deepEqual(trace.answer_events[0].acquisition.record_ids, []);
  assert.throws(() => trace.observe({epoch: 3, events: [], attempts: [], records: [],
    question_producer: {...f.producer, attempt_id: 'another-attempt'}}, 3), /Question producer changed/);
});

const selectedSource = (f, records, slices) => {
  const references = slices.map(({id}) => ({digest: id, bytes: '1'}));
  records.push({kind: 'workspace_view', value: {artifact: {digest: 'view', bytes: '1'},
    description: {values: {items: []}, projection: {result: {digest: 'projection', bytes: '1'},
      values: {items: references}, blocks: slices.map(({id, offset, length}) => ({tag: 'source',
        value: {value: {kind: 'value', id}, offset, length}}))}}}});
  f.interaction.selected_view = {kind: 'view', id: 'view'};
  f.interaction.exposure = {status: 'exposed', selected_view: f.interaction.selected_view};
};

const expandedValue = (f, id, text, offset, nextOffset, index = 0) => {
  const callId = `expand-${index}`;
  f.interaction.results.push({call_id: callId, output: {tag: 'workspace', value: {reply: {
    disposition: 'observed', observation_json: JSON.stringify({text, offset, next_offset: nextOffset})}}}});
  f.interaction.result_actions.push({call_id: callId, action: {tag: 'context', value: {
    command: {tag: 'expand', value: {reference: {kind: 'value', id}}}}}});
};

test('source presentations preserve relative extents and independent whole acquisition roots', () => {
  const f = acquisitionFixture(), end = f.source.indexOf(10);
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin})];
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  selectedSource(f, records, [{id: 'acquired', offset: 0, length: 1}]);
  assert.equal(result().complete, true);
  assert.deepEqual(result().record_ids, []);
  records.pop();
  selectedSource(f, records, [{id: 'acquired', offset: end - 1, length: 1},
    {id: 'acquired', offset: 0, length: end - 1}]);
  assert.deepEqual(result().record_ids, ['m0']);
  records.pop();
  selectedSource(f, records, [{id: 'acquired', offset: 0, length: 1}]);
  f.interaction.evidence = [{tag: 'workspace', value: {kind: 'value', id: 'acquired'}}];
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
  f.interaction.evidence = [];
  const start = end + 1, stop = f.source.indexOf(10, start);
  records[0].native_derivation.acquisition = {...f.origin, start: String(start)};
  records.pop();
  selectedSource(f, records, [{id: 'acquired', offset: 0, length: stop - start}]);
  assert.deepEqual(result().record_ids, ['r0']);
});

test('historical selections require actual exposure and retain earlier successful presentations', () => {
  const f = acquisitionFixture();
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin})];
  selectedSource(f, records, [{id: 'acquired', offset: 0, length: f.source.length}]);
  const earlier = {...f.interaction, interaction_id: 'earlier', event_cut: '20'};
  delete f.interaction.selected_view;
  delete f.interaction.exposure;
  const result = () => sourceAcquisition(f.corpus, f.producer, [earlier, f.interaction], records, true);
  earlier.exposure = {status: 'unexposed', selected_view: null};
  assert.deepEqual(result().record_ids, []);
  assert.equal(result().complete, true);
  for (const exposure of [undefined, {status: 'unknown', selected_view: null}]) {
    earlier.exposure = exposure;
    assert.deepEqual(result().record_ids, []);
    assert.equal(result().complete, false);
  }
  earlier.exposure = {status: 'exposed', selected_view: null};
  assert.deepEqual(result().record_ids, []);
  earlier.exposure.selected_view = earlier.selected_view;
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
  f.interaction.selected_view = earlier.selected_view;
  f.interaction.exposure = {status: 'unexposed', selected_view: null};
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
  earlier.event_cut = '31';
  assert.deepEqual(result().record_ids, []);
});

test('delegated presentations preserve slices through nested computations and union independent inputs', () => {
  const f = acquisitionFixture(), end = f.source.indexOf(10);
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin}),
    f.value('model', {kind: 'judgment', sources: [{digest: 'acquired', bytes: '1'}],
      work: 'child', delegation: {digest: 'delegation'}, capture: {digest: 'capture'}}),
    f.value('result', {kind: 'computation', sources: [{digest: 'model', bytes: '1'}]})];
  selectedSource(f, records, [{id: 'acquired', offset: 0, length: 1}]);
  records[1].native_acquisition = {complete: true, inputs: [],
    selected_view: f.interaction.selected_view, port_inputs: []};
  delete f.interaction.selected_view;
  delete f.interaction.exposure;
  f.interaction.evidence = [{tag: 'workspace', value: {kind: 'value', id: 'result'}}];
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  assert.equal(result().complete, true);
  assert.deepEqual(result().ranges, [[0, 1]]);
  assert.deepEqual(result().record_ids, []);
  records.at(-1).value.description.projection.blocks[0].value.length = end;
  assert.deepEqual(result().record_ids, ['m0']);
  records[1].native_acquisition.port_inputs = [{kind: 'value', id: 'acquired'}];
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
  records[1].native_acquisition.port_inputs = [];
  records[1].native_acquisition.selected_view = null;
  records[1].native_acquisition.inputs = [{kind: 'value', id: 'acquired'}];
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
  delete records[1].native_acquisition;
  assert.deepEqual(result().record_ids, []);
  assert.equal(result().complete, false);
});

test('delegated port observations follow frozen computation inputs without trusting hypotheses', () => {
  const f = acquisitionFixture();
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin}),
    f.value('guess', {kind: 'hypothesis', sources: [{digest: 'acquired', bytes: '1'}]}),
    f.value('model', {kind: 'judgment', sources: [], work: 'instrument',
      delegation: {digest: 'delegation'}, capture: {digest: 'capture'}}),
    {kind: 'workspace_work', value: {id: 'target', outcome_kind: 'running',
      observer_inputs: [{digest: 'acquired', bytes: '1'}]}}];
  const acquisition = {complete: true, inputs: [], selected_view: null,
    port_inputs: [{kind: 'value', id: 'acquired'}]};
  records[2].native_acquisition = acquisition;
  f.interaction.evidence = [{tag: 'workspace', value: {kind: 'value', id: 'model'}}];
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
  acquisition.port_inputs = [{kind: 'value', id: 'guess'}];
  assert.deepEqual(result().record_ids, []);
  assert.equal(result().complete, true);
  acquisition.port_inputs = [];
  assert.deepEqual(result().record_ids, []);
  acquisition.complete = false;
  assert.equal(result().complete, false);
});

test('delegated projection ancestry requires a presented computed block', () => {
  const f = acquisitionFixture();
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin}),
    f.value('projection', {kind: 'computation', sources: [{digest: 'acquired', bytes: '1'}]}),
    f.value('model', {kind: 'judgment', sources: [{digest: 'projection', bytes: '1'}],
      work: 'child', delegation: {digest: 'delegation'}, capture: {digest: 'capture'}})];
  selectedSource(f, records, []);
  const projection = records.at(-1).value.description.projection;
  projection.blocks = [{tag: 'explanation', value: 'A summary without a presented computation.'}];
  records[2].native_acquisition = {complete: true, inputs: [],
    selected_view: f.interaction.selected_view, port_inputs: []};
  delete f.interaction.selected_view;
  delete f.interaction.exposure;
  f.interaction.evidence = [{tag: 'workspace', value: {kind: 'value', id: 'model'}}];
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  assert.equal(result().complete, true);
  assert.deepEqual(result().record_ids, []);
  projection.blocks = [{tag: 'computed', value: null}];
  assert.deepEqual(result().record_ids, f.corpus.records.map(record => record.id));
});

test('expanded acquisition pages count complete JSON representations rather than the whole value', () => {
  const f = acquisitionFixture(), end = f.source.indexOf(10);
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin})];
  const payload = Buffer.from(JSON.stringify(f.source.toString()));
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  expandedValue(f, 'acquired', payload.subarray(0, 3).toString(), 0, 3);
  assert.equal(result().complete, true);
  assert.deepEqual(result().record_ids, []);
  const firstEnd = Buffer.byteLength(JSON.stringify(f.source.subarray(0, end).toString())) - 1;
  expandedValue(f, 'acquired', payload.subarray(3, firstEnd).toString(), 3, firstEnd, 1);
  assert.deepEqual(result().record_ids, ['m0']);
  expandedValue(f, 'acquired', 'invented', firstEnd, firstEnd + 8, 2);
  assert.equal(result().complete, false);
  assert.deepEqual(result().record_ids, ['m0']);
});

test('known program sources cannot erase a fully observed acquisition failure', () => {
  const f = acquisitionFixture(), value = example();
  const records = [{kind: 'workspace_program', value: {task: f.producer.task_id,
    artifact: {digest: 'program', bytes: '1'}, description: {source: {digest: 'program-source', bytes: '1'}}}}];
  f.interaction.results = [{call_id: 'source', output: {tag: 'workspace', value: {reply: {
    disposition: 'observed', observation_json: JSON.stringify({text: '{}', offset: 0, next_offset: 2})}}}}];
  f.interaction.result_actions = [{call_id: 'source', action: {tag: 'context', value: {command: {
    tag: 'expand', value: {reference: {kind: 'source', id: 'program-source'}}}}}}];
  const result = () => sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
  assert.equal(result().complete, true);
  value.events[0].acquisition = {...result(), question_id: value.events[0].question_id,
    question_revision: value.events[0].question_revision, request_digest: value.events[0].request_digest};
  assert.equal(row(grading(value)).sound, false);
  assert.equal(row(grading(value)).critical, true);
  records[0].value.description.source.digest = 'different-source';
  assert.equal(result().complete, false);
});

test('all early or out-of-packet claims contribute critical errors regardless of duplicate order', () => {
  for (const status of ['ready', 'blocked']) for (const beforeSelection of [true, false]) {
    for (const reversed of [true, false]) {
      const value = example(), definitive = {...value.answers[1], status},
        uncertain = {...definitive, status: 'incomplete'};
      const claims = reversed ? [definitive, uncertain] : [uncertain, definitive];
      const early = {...value.events[0], raw: envelope(beforeSelection ? 'p1' : 'p0', claims)};
      value.events.unshift(early);
      const online = grading(value);
      assert.equal(row(online, 'q1').critical, true);
      assert.equal(row(combineOnlineGrading(finalGrade(value), online), 'q1').critical, true);
    }
  }
});

test('final support has its own acquired records and cannot inherit online support by request identity', () => {
  const value = example(), online = grading(value);
  const original = value.corpus.records.find(record => record.id === 'r0');
  value.corpus.records = [...value.corpus.records, {...original, id: 'r0-later'}];
  value.corpus.requests[0] = {...value.corpus.requests[0], receipt_ids: ['r0', 'r0-later']};
  value.answers[0] = {...value.answers[0], records: ['m0', 'r0-later'],
    support: {coverage: [{component: 'A', revision: '1', receipts: ['r0-later']}]}};
  const unacquired = combineOnlineGrading(finalGrade(value, ['m0', 'r0', 'm1', 'r1']), online);
  assert.equal(row(unacquired).sound, false);
  assert.equal(row(unacquired).critical, true);
  assert.equal(unacquired.complete, false);
  assert.equal(combineOnlineGrading(finalGrade(value), online).complete, true);
  const unknown = combineOnlineGrading(finalGrade(value, null), online);
  assert.equal(row(unknown).sound, null);
  assert.equal(row(unknown).critical, null);
  assert.equal(unknown.complete, null);
  value.answers[0].status = 'blocked';
  const failed = combineOnlineGrading(finalGrade(value, null), online);
  assert.equal(row(failed).sound, false);
  assert.equal(row(failed).critical, true);
  assert.equal(failed.complete, false);
});

test('escaped and multibyte acquired payloads preserve page boundaries and union split representations', () => {
  const f = acquisitionFixture();
  const line = JSON.stringify({id: 'unicode', text: 'é雪🙂"\\\t'});
  f.corpus.sources['records.jsonl'] = line + '\n';
  f.source = Buffer.from(f.corpus.sources['records.jsonl']);
  f.origin = {...f.origin, file_digest: hash(f.source), end: String(f.source.length), file_bytes: String(f.source.length)};
  const records = [f.value('acquired', {kind: 'acquisition', acquisition: f.origin})];
  const payload = Buffer.from(JSON.stringify(f.source.toString())), stop = payload.length - 3;
  for (let split = 1; split < stop; split++) {
    if ((payload[split] & 0xc0) === 0x80) continue;
    f.interaction.results = []; f.interaction.result_actions = [];
    expandedValue(f, 'acquired', payload.subarray(0, split).toString(), 0, split);
    const before = sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
    assert.equal(before.complete, true);
    assert.deepEqual(before.record_ids, []);
    expandedValue(f, 'acquired', payload.subarray(split, stop).toString(), split, stop, 1);
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids, ['unicode']);
  }
});

test('invalid UTF8 acquisition subranges use exact base64 symbol coverage', () => {
  const f = acquisitionFixture(), line = JSON.stringify({id: 'unicode', text: 'é'});
  f.corpus.sources['records.jsonl'] = line + '\n';
  f.source = Buffer.from(f.corpus.sources['records.jsonl']);
  f.origin = {...f.origin, file_digest: hash(f.source), end: String(f.source.length), file_bytes: String(f.source.length)};
  const split = f.source.indexOf(Buffer.from('é')) + 1;
  const records = [f.value('left', {kind: 'acquisition', acquisition: {...f.origin, end: String(split)}}),
    f.value('right', {kind: 'acquisition', acquisition: {...f.origin, start: String(split), end: String(f.source.length - 1)}})];
  const left = Buffer.from(JSON.stringify(f.source.subarray(0, split).toString('base64url')));
  const right = Buffer.from(JSON.stringify(f.source.subarray(split, -1).toString('base64url')));
  for (let cut = 2; cut < right.length - 1; cut++) {
    f.interaction.results = []; f.interaction.result_actions = [];
    expandedValue(f, 'left', left.toString(), 0, left.length);
    expandedValue(f, 'right', right.subarray(0, cut).toString(), 0, cut, 1);
    const before = sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true);
    assert.equal(before.complete, true);
    assert.deepEqual(before.record_ids, []);
    expandedValue(f, 'right', right.subarray(cut).toString(), cut, right.length, 2);
    assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction], records, true).record_ids, ['unicode']);
  }
});

test('final acquisition is bound to exact summary bytes and missing proof cannot qualify a comparison', () => {
  const value = example(), raw = JSON.stringify({answers: value.answers}), online = grading(value);
  const proof = {summary_sha256: hash(raw), result_sha256: 'result', attempt_id: 'attempt',
    complete: true, record_ids: value.corpus.records.map(record => record.id)};
  for (const changed of [null, {...proof, summary_sha256: hash(raw + ' ')}, {...proof, result_sha256: ''},
    {...proof, attempt_id: ''}, {...proof, complete: false, record_ids: []}]) {
    const combined = combineOnlineGrading(gradeReport(raw, value.corpus, null, changed), online);
    assert.equal(combined.complete, null);
    assert.equal(row(combined).sound, null);
  }
  assert.equal(combineOnlineGrading(gradeReport(raw, value.corpus), online).complete, null);
});

test('terminal acquisition uses its own producer cut and remains stable across repeated observations', () => {
  const f = acquisitionFixture(), trace = new RecurrenceTrace({...f.corpus, packets: []}, {});
  const acquired = f.value('acquired', {kind: 'acquisition', acquisition: f.origin});
  const interaction = {...f.interaction, event_cut: '40', interaction_id: 'terminal',
    evidence: [{tag: 'workspace', value: {kind: 'value', id: 'acquired'}}]};
  const reportProducer = {...f.producer, event_cut: '40', interaction_id: 'terminal',
    result_sha256: 'result', summary_sha256: 'summary'};
  trace.observe({epoch: 1, events: [], attempts: [], records: [acquired,
    {kind: 'controller_interaction', value: {id: f.producer.interaction_id, task: f.producer.task_id}, acquisition: f.interaction},
    {kind: 'controller_interaction', value: {id: 'terminal', task: f.producer.task_id}, acquisition: interaction}],
  report_producer: reportProducer, acquisition_records_complete: true}, 1);
  trace.acquisitionEvidence();
  assert.deepEqual(sourceAcquisition(f.corpus, f.producer, [f.interaction, interaction], [acquired], true).record_ids, []);
  assert.deepEqual(trace.final_acquisition.record_ids, f.corpus.records.map(record => record.id));
  trace.observe({epoch: 2, events: [], attempts: [], records: [], report_producer: reportProducer}, 2);
  assert.throws(() => trace.observe({epoch: 3, events: [], attempts: [], records: [],
    report_producer: {...reportProducer, result_sha256: 'other-result'}}, 3), /Report producer changed/);
  interaction.event_cut = '41';
  assert.equal(sourceAcquisition(f.corpus, reportProducer, [f.interaction, interaction], [acquired], true).complete, false);
});
