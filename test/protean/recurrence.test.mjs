import assert from 'node:assert/strict';
import test from 'node:test';
import {contract, createCorpus, freezeRecords, oracle, requestRecords, gradeReport, compareCampaign, campaignIdentity} from '../../tools/evaluation/recurrence.mjs';

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
  const cases = [1, 2, 3].flatMap(pair => (pair === 2 ? ['ordinary', 'treatment'] : ['treatment', 'ordinary']).map(arm => ({id: `${pair}-${arm}`, pair, arm,
    config_sha256: `${pair}-${arm}-config`, corpus_sha256: `${pair}-corpus`, expected_sha256: `${pair}-expected`,
    end_packet: {id: `${pair}-END`, offset_ms: 1980000}})));
  const plan = {cases, limits, cost_model: {id: 'frozen-cost', currency: 'USD', predeclared: true}};
  const reports = cases.map(subject => ({subject, plan_sha256: campaignIdentity(plan), grading: {totals: {requests: 12, sound: 12, critical: 0, unanswered: 0}}, elapsed_ms: 2400000,
    peak_rss_sampled_bytes: 1000000, retained_namespace_bytes: 1000000,
    metrics: {controller: {calls: 50, input_tokens: 10000, output_tokens: 10000, missing_usage: 0}, delegated: {calls: 0, input_tokens: 0, output_tokens: 0, missing_usage: 0}},
    arm_violations: [], errors: [], cost: {model_id: 'frozen-cost', total: subject.arm === 'ordinary' ? 10 : 8, currency: 'USD', complete: true},
    status: {status: 'completed'},
    reuse: {qualified: true, recovered: true, visibility: [{packet_id: subject.end_packet.id, confirmed: true, dispatch_ms: 1980001}]}}));
  return {plan, reports};
}

test('comparison rejects measurements from different frozen inputs', () => {
  for (const field of ['config_sha256', 'corpus_sha256', 'expected_sha256']) {
    const {plan, reports} = campaign();
    reports[0] = {...reports[0], subject: {...reports[0].subject, [field]: 'foreign'}};
    const result = compareCampaign(plan, reports);
    assert.equal(result.attempts[0].integrity, false);
    assert.notEqual(result.complete_milestone, true);
    assert.notEqual(result.pairs[0].cost_positive, true);
  }
});

test('unbound reports retain expenditure without deciding any planned outcome', () => {
  for (const field of ['config_sha256', 'corpus_sha256', 'expected_sha256', 'plan_sha256']) {
    const {plan, reports} = campaign();
    const foreign = structuredClone(reports[0]);
    if (field === 'plan_sha256') foreign.plan_sha256 = 'foreign';
    else foreign.subject[field] = 'foreign';
    foreign.elapsed_ms = limits.wall_ms + 1;
    foreign.metrics.controller.input_tokens = limits.tokens + 1;
    foreign.grading.totals = {requests: 12, sound: 11, critical: 1, unanswered: 0};
    foreign.reuse = {qualified: false, recovered: false, visibility: []};
    const result = compareCampaign(plan, [foreign]);
    const attempt = result.attempts[0];
    assert.equal(attempt.present, true);
    assert.equal(attempt.integrity, false);
    assert.equal(attempt.stream_complete, null);
    assert.equal(attempt.grading, null);
    assert.equal(attempt.budget.compliant, null);
    assert.equal(attempt.cost, null);
    assert.equal(attempt.mechanism, null);
    assert.equal(result.complete_milestone, null);
    assert.equal(result.verdict, 'undetermined');
    assert.equal(result.pairs[0].verdict, 'undetermined');
    assert.deepEqual(result.unattributed_reports, [foreign]);
    assert.equal(result.unattributed_reports[0].cost.total, foreign.cost.total);
    assert.equal(result.aggregate.treatment.sound, null);
  }
  const {plan, reports} = campaign();
  const duplicates = compareCampaign(plan, [reports[0], reports[0]]);
  assert.deepEqual(duplicates.unattributed_reports, [reports[0], reports[0]]);
  assert.equal(duplicates.complete_milestone, null);
});

test('known token subtotals can disprove compliance while exact usage stays unknown', () => {
  for (const missingRole of ['controller', 'delegated']) {
    for (const tokens of [limits.tokens + 1, limits.tokens, limits.tokens - 1]) {
      const {plan, reports} = campaign();
      const report = reports[0];
      report.metrics.controller.input_tokens = tokens - 10;
      report.metrics.controller.output_tokens = 5;
      report.metrics.delegated.input_tokens = 3;
      report.metrics.delegated.output_tokens = 2;
      report.metrics[missingRole].missing_usage = 1;
      report.cost = {...report.cost, complete: false, total: null};
      const result = compareCampaign(plan, reports);
      const budget = result.attempts[0].budget;
      assert.equal(budget.measurements.tokens, null);
      assert.equal(budget.checks.tokens, tokens > limits.tokens ? false : null);
      assert.equal(budget.compliant, tokens > limits.tokens ? false : null);
      assert.equal(result.complete_milestone, tokens > limits.tokens ? false : null);
      assert.equal(budget.lower_bounds.tokens, tokens);
      assert.equal(result.aggregate.treatment.cost, null);
    }
  }
});

test('all supported answers before END do not establish complete-stream payback', () => {
  const {plan, reports} = campaign();
  reports[0].elapsed_ms = 1810000;
  reports[0].reuse.visibility = [];
  const result = compareCampaign(plan, reports);
  assert.equal(result.attempts[0].grading.sound, 12);
  assert.equal(result.attempts[0].integrity, false);
  assert.equal(result.complete_milestone, false);
  assert.notEqual(result.pairs[0].cost_positive, true);
  assert.equal(result.pairs[0].verdict, 'no_practical_improvement');
});

test('missing stream evidence stays unknown and changed plan terms reject attribution', () => {
  const {plan, reports} = campaign();
  delete reports[0].reuse.visibility;
  assert.equal(compareCampaign(plan, reports).attempts[0].stream_complete, null);
  assert.equal(compareCampaign(plan, reports).complete_milestone, null);
  const changed = {...plan, limits: {...plan.limits, tokens: plan.limits.tokens * 2}};
  assert(compareCampaign(changed, reports).attempts.every(attempt => attempt.integrity === false));
});

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

test('a failed same-pair conjunction stays false even when other pairs save money', () => {
  for (const expensive of [1, 2, 3]) {
    const {plan, reports} = campaign();
    for (const report of reports.filter(item => item.subject.arm === 'treatment')) {
      report.cost.total = report.subject.pair === expensive ? 12 : 8;
      report.reuse.recovered = report.subject.pair === expensive;
    }
    const result = compareCampaign(plan, reports);
    assert.equal(result.campaign_cost_positive, true);
    assert.equal(result.qualifying_traces, 0);
    assert.equal(result.complete_milestone, false);
    reports.find(item => item.subject.id === `${expensive === 1 ? 2 : 1}-treatment`).reuse.recovered = null;
    assert.equal(compareCampaign(plan, reports).complete_milestone, null);
  }
});

test('absent mechanisms disprove the milestone without inventing missing prices', () => {
  const {plan, reports} = campaign();
  plan.cost_model = {kind: 'unpriced', currency: 'USD'};
  for (const report of reports) report.plan_sha256 = campaignIdentity(plan);
  for (const report of reports.filter(item => item.subject.arm === 'treatment')) report.reuse.recovered = false;
  const result = compareCampaign(plan, reports);
  assert.equal(result.complete_milestone, false);
  assert.equal(result.campaign_cost_positive, null);
  assert.equal(result.aggregate.treatment.cost, null);
  reports.find(item => item.subject.id === '1-treatment').reuse.recovered = null;
  assert.equal(compareCampaign(plan, reports).complete_milestone, null);
});

test('known quality deficits disprove payback despite unavailable prices', () => {
  for (const unavailable of ['tariffs', 'charge']) {
    for (const deficientPairs of [[1], [1, 2, 3]]) {
      const {plan, reports} = campaign();
      if (unavailable === 'tariffs') plan.cost_model = {kind: 'unpriced', currency: 'USD'};
      for (const report of reports) {
        report.plan_sha256 = campaignIdentity(plan);
        if (report.subject.arm === 'treatment' && deficientPairs.includes(report.subject.pair)) {
          report.grading.totals = {requests: 12, sound: 11, critical: 0, unanswered: 1};
          report.cost = {...report.cost, complete: false, total: null};
        }
      }
      const result = compareCampaign(plan, reports);
      assert.equal(result.aggregate.ordinary.sound, 36);
      assert.equal(result.aggregate.treatment.sound, 36 - deficientPairs.length);
      assert.equal(result.aggregate.treatment.cost, null);
      assert.equal(result.campaign_cost_positive, false);
      assert.equal(result.complete_milestone, false);
      assert.equal(result.verdict, 'no_practical_improvement');
      for (const pair of result.pairs.filter(pair => deficientPairs.includes(pair.pair))) {
        assert.equal(pair.cost_positive, false);
        assert.equal(pair.verdict, 'no_practical_improvement');
        assert.equal(pair.cost_difference, null);
      }
    }
  }
});

test('pair quality losses remain separate from compensated campaign quality', () => {
  const {plan, reports} = campaign();
  plan.cost_model = {kind: 'unpriced', currency: 'USD'};
  for (const report of reports) report.plan_sha256 = campaignIdentity(plan);
  reports.find(report => report.subject.id === '1-treatment').grading.totals = {requests: 12, sound: 11, critical: 0, unanswered: 1};
  reports.find(report => report.subject.id === '2-ordinary').grading.totals = {requests: 12, sound: 10, critical: 0, unanswered: 2};
  const result = compareCampaign(plan, reports);
  assert.equal(result.aggregate.treatment.sound, 35);
  assert.equal(result.aggregate.ordinary.sound, 34);
  assert.equal(result.pairs[0].cost_positive, false);
  assert.equal(result.pairs[1].verdict, 'quality_improvement_within_common_envelope');
  assert.equal(result.campaign_cost_positive, null);
  assert.equal(result.complete_milestone, null);
  for (const report of reports.filter(report => report.subject.arm === 'treatment' && report.subject.pair !== 1)) report.reuse.recovered = false;
  assert.equal(compareCampaign(plan, reports).complete_milestone, false);
});

test('unpriced quality evidence must be attributable and sufficient to disprove payback', () => {
  for (const evidence of ['equal', 'gain', 'missing', 'foreign', 'violated']) {
    const {plan, reports} = campaign();
    plan.cost_model = {kind: 'unpriced', currency: 'USD'};
    for (const report of reports) report.plan_sha256 = campaignIdentity(plan);
    const treatment = reports.find(report => report.subject.id === '1-treatment');
    const control = reports.find(report => report.subject.id === '1-ordinary');
    if (evidence === 'gain') control.grading.totals = {requests: 12, sound: 11, critical: 0, unanswered: 1};
    if (['missing', 'foreign', 'violated'].includes(evidence)) treatment.grading.totals = {requests: 12, sound: 11, critical: 0, unanswered: 1};
    if (evidence === 'missing') delete control.grading;
    if (evidence === 'foreign') treatment.subject = {...treatment.subject, config_sha256: 'foreign'};
    if (evidence === 'violated') treatment.arm_violations.push('excluded operation');
    const result = compareCampaign(plan, reports);
    assert.equal(result.pairs[0].cost_positive, null);
    assert.equal(result.campaign_cost_positive, null);
    assert.equal(result.complete_milestone, null);
    assert.equal(result.aggregate.treatment.cost, null);
  }
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

function onlineCampaign() {
  const value = campaign();
  value.plan.suite = 'recurrence-online';
  for (const report of value.reports) {
    report.plan_sha256 = campaignIdentity(value.plan);
    report.final_grading = structuredClone(report.grading);
    report.online = {complete: true};
  }
  return value;
}

test('cheaper online attempts cannot claim payback from the same missing or unsupported service', () => {
  for (const failure of ['incomplete_delivery', 'unanswered', 'unsupported']) {
    const {plan, reports} = onlineCampaign();
    for (const report of reports) {
      if (failure === 'incomplete_delivery') report.online.complete = false;
      else report.grading.totals = {requests: 12, sound: 11,
        critical: failure === 'unsupported' ? 1 : 0, unanswered: failure === 'unanswered' ? 1 : 0};
      assert.equal(report.final_grading.totals.sound, 12);
    }
    const result = compareCampaign(plan, reports);
    assert(result.attempts.every(attempt => attempt.service_complete === false));
    assert(result.pairs.every(pair => pair.cost_positive === false));
    assert.equal(result.campaign_cost_positive, false);
    assert.equal(result.complete_milestone, false);
    assert.equal(result.verdict, 'no_practical_improvement');
    assert.equal(result.aggregate.treatment.cost, 24);
    assert.equal(result.aggregate.ordinary.cost, 30);
  }
});

test('missing online evidence remains unknown despite a correct final report and lower cost', () => {
  const {plan, reports} = onlineCampaign();
  delete reports[0].online;
  const result = compareCampaign(plan, reports);
  assert.equal(result.attempts[0].grading.sound, 12);
  assert.equal(result.attempts[0].service_complete, null);
  assert.equal(result.attempts[0].cost, 8);
  assert.equal(result.pairs[0].cost_positive, null);
  assert.equal(result.campaign_cost_positive, null);
  assert.equal(result.complete_milestone, null);
});

test('complete online and final service preserves qualifying cost savings without ordinary construction', () => {
  const {plan, reports} = onlineCampaign();
  for (const report of reports.filter(item => item.subject.arm === 'ordinary'))
    report.reuse = {...report.reuse, qualified: false, recovered: false};
  const result = compareCampaign(plan, reports);
  assert(result.attempts.every(attempt => attempt.service_complete === true));
  assert(result.attempts.filter(attempt => attempt.subject.arm === 'ordinary')
    .every(attempt => attempt.mechanism === null));
  assert(result.pairs.every(pair => pair.cost_positive === true));
  assert.equal(result.qualifying_traces, 3);
  assert.equal(result.campaign_cost_positive, true);
  assert.equal(result.complete_milestone, true);
  for (const report of reports.filter(item => item.subject.arm === 'treatment')) report.reuse.recovered = false;
  const absentMechanism = compareCampaign(plan, reports);
  assert(absentMechanism.attempts.every(attempt => attempt.service_complete === true));
  assert.equal(absentMechanism.campaign_cost_positive, true);
  assert.equal(absentMechanism.complete_milestone, false);
});
