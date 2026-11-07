import assert from 'node:assert/strict';
import test from 'node:test';
import {contract, createCorpus, freezeRecords, oracle, requestRecords, gradeReport, compareCampaign} from '../../tools/evaluation/recurrence.mjs';

const p = (component, revision = '1') => ({component, revision});
const manifest = (component, requirements = [], extra = {}) => ({kind: 'manifest', id: `m-${component}`, ...p(component), complete: true,
  requirements: requirements.map(r => typeof r === 'string' ? p(r) : r), ...extra});
const receipt = (component, result = 'pass', extra = {}) => ({kind: 'receipt', id: `r-${component}-${result}`, ...p(component), scope: 'release', available: true, result, ...extra});
const request = (records, extra = {}) => ({id: 'q', target: p('A'), flags: {}, scope: 'release',
  manifest_ids: records.filter(r => r.kind === 'manifest').map(r => r.id), receipt_ids: records.filter(r => r.kind === 'receipt').map(r => r.id), ...extra});
const grade = (records, answer, extra = {}) => gradeReport(JSON.stringify({answers: [answer]}), {requests: [request(records, extra)], records});
const ready = (components, records) => ({request_id: 'q', status: 'ready', records: records.map(r => r.id), artifact_refs: [],
  support: {coverage: components.map(component => ({...p(component), receipts: records.filter(r => r.kind === 'receipt' && r.component === component).map(r => r.id)}))}});
const blocked = (records, path) => ({request_id: 'q', status: 'blocked', records: records.map(r => r.id), artifact_refs: [], support: {blocker: p(path.at(-1)), path: path.map(c => p(c))}});
const incomplete = (records, path, kind, extra = {}) => ({request_id: 'q', status: 'incomplete', records: records.map(r => r.id), artifact_refs: [],
  support: {path: path.map(c => p(c)), unresolved: {...p(path.at(-1)), kind, ...extra}}});

test('undelivered requests stay unanswered even when a report guesses their supported answer', () => {
  const records = [manifest('A'), receipt('A')];
  const raw = JSON.stringify({answers: [ready(['A'], records)]});
  const corpus = {requests: [request(records)], records};
  assert.equal(gradeReport(raw, corpus, new Set(['q'])).totals.sound, 1);
  assert.deepEqual(gradeReport(raw, corpus, new Set()).totals,
    {requests: 1, sound: 0, critical: 0, unanswered: 1});
});

test('diamond obligations deduplicate and duplicate receipts cannot cover a missing leaf', () => {
  const records = [manifest('A', ['B', 'C']), manifest('B', ['D']), manifest('C', ['D']), manifest('D'),
    receipt('A'), receipt('B'), receipt('C'), receipt('B', 'pass', {id: 'duplicate'})];
  const result = oracle(request(records), records);
  assert.equal(result.status, 'incomplete');
  assert.deepEqual(result.obligations.map(o => o.component), ['A', 'B', 'C', 'D']);
  assert.deepEqual(result.unresolved.map(i => [i.component, i.kind]), [['D', 'missing_validation']]);
  assert.equal(grade(records, incomplete(records, ['A', 'C', 'D'], 'missing_validation')).totals.sound, 1);
  const complete = [...records, receipt('D')];
  assert.equal(oracle(request(complete), complete).status, 'ready');
  assert.equal(grade(complete, ready(['A', 'B', 'C', 'D'], complete)).totals.sound, 1);
});

test('cycles terminate and permit fully validated readiness', () => {
  const records = [manifest('A', ['B']), manifest('B', ['C']), manifest('C', ['A']), receipt('A'), receipt('B'), receipt('C')];
  const result = oracle(request(records), records);
  assert.equal(result.status, 'ready');
  assert.equal(result.obligations.length, 3);
  assert.equal(grade(records, ready(['A', 'B', 'C'], records)).totals.sound, 1);
});

test('manifest agreement ignores ordering, names, metadata and repeated requirement entries', () => {
  const records = [manifest('A', ['B', 'C']), manifest('A', ['C', 'B', 'B'], {id: 'renamed', display_name: 'Different', irrelevant: 42}),
    manifest('B'), manifest('C'), receipt('A'), receipt('B'), receipt('C')];
  assert.equal(oracle(request(records), records).status, 'ready');
  const changed = [...records, manifest('A', ['B'], {id: 'conflicting'})];
  const result = oracle(request(changed), changed);
  assert.equal(result.status, 'incomplete');
  assert.deepEqual(result.obligations.map(o => o.component), ['A']);
  assert.equal(grade(changed, incomplete(changed, ['A'], 'conflicting_manifests')).totals.sound, 1);
});

test('conflicting manifests cannot prove a failure path, but independent paths survive', () => {
  const records = [manifest('A', ['B', 'C']), manifest('B', ['D']), manifest('B', [], {id: 'm-B-other'}), manifest('C'), manifest('D'),
    receipt('A'), receipt('B'), receipt('C'), receipt('D', 'fail')];
  assert.equal(oracle(request(records), records).status, 'incomplete');
  assert.equal(grade(records, blocked(records, ['A', 'B', 'D'])).totals.critical, 1);
  const independent = records.map(r => r.id === 'm-C' ? manifest('C', ['D']) : r);
  const result = oracle(request(independent), independent);
  assert.equal(result.status, 'blocked');
  assert.deepEqual(result.blockers[0].path.map(o => o.component), ['A', 'C', 'D']);
  assert.equal(grade(independent, blocked(independent, ['A', 'C', 'D'])).totals.sound, 1);
  assert.equal(grade(independent, blocked(independent, ['A', 'B', 'D'])).totals.sound, 0);
});

test('confirmed failure dominates unrelated missing and incomplete requirements', () => {
  const records = [manifest('A', ['B', 'C'], {complete: false}), manifest('B'), receipt('A'), receipt('B', 'fail')];
  const result = oracle(request(records), records);
  assert.equal(result.status, 'blocked');
  assert.deepEqual(result.unresolved.map(i => [i.component, i.kind]), [
    ['A', 'incomplete_manifest'], ['C', 'missing_manifest'], ['C', 'missing_validation'],
  ]);
  assert.equal(grade(records, blocked(records, ['A', 'B'])).totals.sound, 1);
  assert.equal(grade(records, incomplete(records, ['C'], 'missing_manifest')).totals.sound, 0);
});

test('missing and incomplete manifests are not empty manifests', () => {
  const absent = [receipt('A')];
  assert.equal(oracle(request(absent), absent).status, 'incomplete');
  assert.equal(grade(absent, incomplete(absent, ['A'], 'missing_manifest')).totals.sound, 1);
  const partial = [manifest('A', ['B'], {complete: false}), manifest('B'), receipt('A'), receipt('B')];
  assert.equal(oracle(request(partial), partial).status, 'incomplete');
  assert.equal(grade(partial, incomplete(partial, ['A'], 'incomplete_manifest')).totals.sound, 1);
});

test('receipts require exact identity, revision, scope, availability and consistent results', () => {
  const records = [manifest('A'), receipt('A', 'fail', {id: 'stale', revision: '0'}), receipt('A', 'fail', {id: 'foreign', scope: 'foreign'}),
    receipt('A', 'fail', {id: 'unavailable', available: false}), receipt('B', 'fail'), receipt('A', 'pass', {id: 'not-applicable'})];
  const query = request(records, {receipt_ids: ['stale', 'foreign', 'unavailable', 'r-B-fail', 'unbound']});
  assert.equal(oracle(query, records).status, 'incomplete');
  const conflict = [manifest('A'), receipt('A'), receipt('A', 'fail')];
  assert.equal(oracle(request(conflict), conflict).status, 'incomplete');
  assert.equal(grade(conflict, incomplete(conflict, ['A'], 'conflicting_receipts')).totals.sound, 1);
  const oneSide = incomplete(conflict, ['A'], 'conflicting_receipts');
  oneSide.records = ['r-A-pass'];
  assert.equal(grade(conflict, oneSide).totals.sound, 0);
  assert.equal(grade(conflict, blocked(conflict, ['A'])).totals.critical, 1);
});

test('a changed exact revision adds the only unresolved obligation', () => {
  const records = [manifest('A', ['B']), manifest('A', ['B', 'C'], {id: 'm-A2', revision: '2'}), manifest('B'), manifest('C'),
    receipt('A'), receipt('A', 'pass', {id: 'r-A2', revision: '2'}), receipt('B')];
  assert.equal(oracle(request(records), records).status, 'ready');
  const revised = oracle(request(records, {target: p('A', '2')}), records);
  assert.equal(revised.status, 'incomplete');
  assert.deepEqual(revised.unresolved.map(i => [i.component, i.kind]), [['C', 'missing_validation']]);
});

test('Boolean activation alone changes the answer and missing activation cannot prove a blocker', () => {
  const records = [manifest('A', [{...p('B'), flag: 'feature'}]), manifest('B'), receipt('A'), receipt('B', 'fail')];
  assert.equal(oracle(request(records, {flags: {feature: false}}), records).status, 'ready');
  assert.equal(oracle(request(records, {flags: {feature: true}}), records).status, 'blocked');
  assert.equal(oracle(request(records), records).status, 'incomplete');
  assert.equal(grade(records, blocked(records, ['A', 'B'])).totals.critical, 1);
  assert.equal(grade(records, incomplete(records, ['A'], 'unresolved_flag', {flag: 'feature'})).totals.sound, 1);
});

test('record identity collisions reject preparation and frozen records cannot change', () => {
  const source = [manifest('A')];
  const frozen = freezeRecords(source);
  source[0].complete = false;
  assert.equal(frozen[0].complete, true);
  assert.throws(() => { frozen[0].requirements.push(p('B')); }, TypeError);
  assert.throws(() => freezeRecords([manifest('A'), manifest('A', ['B'])]), /collision/);
  assert.equal(freezeRecords([manifest('A'), manifest('A')]).length, 1);
});

test('later records neither expand request membership nor bind an earlier unavailable identity', () => {
  const first = [manifest('A')];
  const later = receipt('A');
  const early = request(first, {receipt_ids: [later.id]});
  const next = {...early, id: 'next'};
  const corpus = {requests: [early, next], records: [...first, later], packets: [
    {request_ids: ['q'], bytes: JSON.stringify({documents: first})},
    {request_ids: ['next'], bytes: JSON.stringify({documents: [later]})},
  ]};
  assert.equal(oracle(early, requestRecords(corpus, 'q')).status, 'incomplete');
  assert.equal(oracle(next, requestRecords(corpus, 'next')).status, 'ready');
  const earlyAnswer = incomplete(first, ['A'], 'missing_validation');
  const laterAnswer = {...ready(['A'], [...first, later]), request_id: 'next'};
  assert.equal(gradeReport(JSON.stringify({answers: [earlyAnswer, laterAnswer]}), corpus).totals.sound, 2);
  assert.equal(oracle(request(first), [...first, later]).status, 'incomplete');
});

test('unsupported conclusions, forged paths and omitted coverage fail despite correct status', () => {
  const records = [manifest('A', ['B']), manifest('B'), receipt('A'), receipt('B')];
  const unsupported = ready(['A', 'B'], records);
  unsupported.records = ['r-A-pass', 'r-B-pass'];
  assert.equal(grade(records, unsupported).totals.critical, 1);
  assert.equal(grade(records, ready(['A'], records)).totals.critical, 1);
  const failures = records.map(r => r.id === 'r-B-pass' ? receipt('B', 'fail') : r);
  assert.equal(grade(failures, blocked(failures, ['B'])).totals.critical, 1);
  assert.equal(grade(failures, blocked(failures.filter(r => r.kind === 'receipt'), ['A', 'B'])).totals.critical, 1);
  const partial = [manifest('A', ['B']), manifest('B'), receipt('A')];
  assert.equal(grade(partial, incomplete(partial, ['B'], 'missing_validation')).totals.sound, 0);
});

test('malformed whole reports receive no substring salvage and duplicate answers invalidate their request', () => {
  const records = [manifest('A'), receipt('A')];
  const corpus = {records, requests: [request(records)]};
  const answer = ready(['A'], records);
  const valid = JSON.stringify({answers: [answer]});
  assert.equal(gradeReport(valid, corpus).totals.sound, 1);
  assert.equal(gradeReport(`Here is the answer: ${valid}`, corpus).totals.sound, 0);
  assert.equal(gradeReport(`${valid} trailing`, corpus).errors[0], 'malformed_report');
  const duplicates = gradeReport(JSON.stringify({answers: [answer, answer]}), corpus);
  assert.deepEqual(duplicates.answers[0].errors, ['duplicate_request']);
  assert.equal(duplicates.totals.critical, 1);
  assert.equal(gradeReport('{"answers":[]}', corpus).totals.unanswered, 1);
  const missingRefs = structuredClone(answer);
  delete missingRefs.artifact_refs;
  assert.equal(grade(records, missingRefs).totals.sound, 0);
});

test('three frozen seeds expose raw documents on the exact schedule and preserve case distinctions', () => {
  for (const seed of [1, 2, 3]) {
    const corpus = createCorpus(seed);
    assert.equal(corpus.requests.length, 12);
    assert.equal(corpus.packets.length, 12);
    assert.deepEqual(corpus.packets.map(p => p.offset_ms), Array.from({length: 12}, (_, i) => i * 180000));
    assert.equal(corpus.packets[0].request_ids.length, 2);
    assert.equal(corpus.packets.at(-1).offset_ms, 1980000);
    assert.equal(JSON.parse(corpus.packets.at(-1).bytes).event, 'END');
    assert.deepEqual(corpus.expected.map(e => e.status), ['ready', 'blocked', 'ready', 'blocked', 'incomplete', 'ready', 'incomplete', 'blocked', 'incomplete', 'incomplete', 'incomplete', 'ready']);
    assert.deepEqual(corpus.expected[9].unresolved.map(i => i.kind), ['missing_validation']);
    assert.deepEqual(corpus.expected[10].unresolved.map(i => i.kind), ['missing_validation']);
    assert.equal(corpus.expected[9].unresolved[0].component, corpus.expected[10].unresolved[0].component);
    assert.equal(corpus.requests[10].scope, corpus.requests[0].scope);
    assert.deepEqual([...corpus.requests[10].manifest_ids].sort(), [...corpus.requests[0].manifest_ids].sort());
    assert.deepEqual([...corpus.requests[10].receipt_ids].sort(), [...corpus.requests[0].receipt_ids].sort());
    const initial = JSON.parse(corpus.packets[0].bytes);
    assert.equal(initial.documents.some(r => r.id === corpus.requests[9].manifest_ids.find(id => id.endsWith('/manifest-revision'))), false);
    const allIds = corpus.packets.flatMap(p => (JSON.parse(p.bytes).documents ?? []).map(r => r.id));
    assert.equal(allIds.length, new Set(allIds).size);
    assert.equal(Object.isFrozen(corpus.requests[0].flags), true);
    assert.equal(corpus.packets[0].bytes, createCorpus(seed).packets[0].bytes);
    for (const packet of corpus.packets) assert.equal(JSON.parse(packet.bytes).packet_id, packet.id);
    assert.equal(contract.includes('To wait for more inputs, ask exactly "Please send the next request."'), true);
  }
});

const limits = {wall_ms: 2700000, tokens: 512000, provider_attempts: 128, namespace_bytes: 1073741824, rss_bytes: 4294967296};
function campaign() {
  const cases = [1, 2, 3].flatMap(pair => (pair === 2 ? ['ordinary', 'treatment'] : ['treatment', 'ordinary']).map(arm => ({id: `${pair}-${arm}`, pair, arm})));
  const plan = {cases, limits, cost_model: {id: 'frozen-cost', currency: 'USD', predeclared: true}};
  const reports = cases.map(subject => ({subject, grading: {totals: {requests: 12, sound: 12, critical: 0, unanswered: 0}}, elapsed_ms: 2400000,
    peak_rss_sampled_bytes: 1000000, retained_namespace_bytes: 1000000,
    metrics: {controller: {calls: 50, input_tokens: 10000, output_tokens: 10000, missing_usage: 0}, delegated: {calls: 0, input_tokens: 0, output_tokens: 0, missing_usage: 0}},
    arm_violations: [], errors: [], cost: {model_id: 'frozen-cost', total: subject.arm === 'ordinary' ? 10 : 8, currency: 'USD', complete: true},
    reuse: {qualified: true, recovered: true}}));
  return {plan, reports};
}

test('campaign compares actual sums across all six attempts and requires the same-trace conjunction', () => {
  const {plan, reports} = campaign();
  const result = compareCampaign(plan, reports);
  assert.equal(result.complete_milestone, true);
  assert.equal(result.qualifying_traces, 3);
  assert.equal(result.aggregate.treatment.cost, 24);
  assert.equal(result.aggregate.ordinary.cost, 30);
  assert.equal(result.earlier_payback_request, null);
  for (const report of reports) if (report.subject.arm === 'treatment') report.reuse.recovered = false;
  assert.equal(compareCampaign(plan, reports).complete_milestone, false);
  assert.equal(compareCampaign(plan, reports).campaign_cost_positive, true);
});

test('an unfavorable attempt remains in campaign economics despite a positive existence witness', () => {
  const {plan, reports} = campaign();
  reports.find(r => r.subject.id === '3-treatment').cost.total = 30;
  const result = compareCampaign(plan, reports);
  assert.equal(result.qualifying_traces, 2);
  assert.equal(result.aggregate.treatment.cost, 46);
  assert.equal(result.complete_milestone, false);
});

test('missing reports, usage, prices, duplicate attempts and unknown recovery never become zero or success', () => {
  const {plan, reports} = campaign();
  const missing = compareCampaign(plan, reports.slice(1));
  assert.equal(missing.aggregate.treatment.cost, null);
  assert.equal(missing.aggregate.treatment.sound, null);
  assert.equal(missing.complete_milestone, null);
  const unknown = structuredClone(reports);
  unknown[0].metrics.controller.missing_usage = 1;
  unknown[0].cost.total = null;
  unknown[0].cost.complete = false;
  unknown[0].reuse.recovered = null;
  const result = compareCampaign(plan, unknown);
  assert.equal(result.attempts[0].budget.compliant, null);
  assert.equal(result.attempts[0].cost, null);
  assert.equal(result.attempts[0].mechanism, null);
  assert.equal(result.complete_milestone, null);
  assert.equal(compareCampaign(plan, [...reports, reports[0]]).complete_milestone, null);
  const noModel = {...plan, cost_model: {currency: 'USD'}};
  assert.equal(compareCampaign(noModel, reports).aggregate.ordinary.cost, null);
});

test('common ceilings cannot be averaged away and arm violations defeat attribution', () => {
  const {plan, reports} = campaign();
  reports[0].elapsed_ms = limits.wall_ms + 1;
  assert.equal(compareCampaign(plan, reports).pairs[0].verdict, 'no_practical_improvement');
  assert.equal(compareCampaign(plan, reports).complete_milestone, false);
  reports[0].elapsed_ms = 2400000;
  reports[0].arm_violations.push('excluded operation');
  assert.equal(compareCampaign(plan, reports).pairs[0].verdict, 'undetermined');
  assert.equal(compareCampaign(plan, reports).complete_milestone, null);
});

test('quality gains with more expenditure are a tradeoff and partial outcomes retain their counts', () => {
  const {plan, reports} = campaign();
  const control = reports.find(r => r.subject.id === '1-ordinary');
  control.grading.totals = {requests: 12, sound: 8, critical: 0, unanswered: 4};
  reports.find(r => r.subject.id === '1-treatment').cost.total = 11;
  const result = compareCampaign(plan, reports);
  assert.equal(result.pairs[0].verdict, 'tradeoff');
  assert.equal(result.pairs[0].cost_positive, false);
  assert.equal(result.pairs[0].quality_improvement, true);
  assert.equal(result.aggregate.ordinary.sound, 32);
});
