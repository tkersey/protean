import test from 'node:test';
import assert from 'node:assert/strict';
import {assessScan, canonicalEvidence, collisionProbe, gradeAnswer, inspectProjection, makeRepairCorpus,
  parseAnswer, parseCandidate} from '../../tools/evaluation/interface_repair.mjs';

const corpus = makeRepairCorpus('qualification');
const complete = 'exhausted_declared_domain', partial = 'incomplete', mismatch = 'counterexample';
const sourceRef = (ordinal, kind = 'value') => ({kind, id: ordinal.toString(16).padStart(64, '0')});
const refs = specimen => Object.fromEntries(Object.keys(specimen.files).map((path, i) => [path, sourceRef(i + 1)]));

function edit(specimen, fn) {
  const copy = structuredClone(specimen), scan = JSON.parse(copy.files['scan.json']);
  fn(scan, copy.files);
  copy.files['scan.json'] = JSON.stringify(scan);
  return copy;
}
function report(specimen, changes = {}) {
  const expected = assessScan(specimen);
  return JSON.stringify({kind: 'interface-repair.answer.v1', case_id: specimen.case_id,
    domain_identity: expected.domain.identity, domain_revision: expected.domain.revision, outcome: expected.outcome,
    support: [sourceRef(100)], explanation: 'The cited observation supports this conclusion.', ...changes});
}
const exposure = specimen => [{ref: sourceRef(100), paths: assessScan(specimen).paths}];

test('frozen corpus separates the original visible pair from ten new instances on each repetition', () => {
  assert.deepEqual(corpus.development.map(c => assessScan(c).outcome), [complete, partial]);
  assert.deepEqual(corpus.transfer.map(c => assessScan(c).outcome), [complete, partial, partial, complete,
    mismatch, partial, partial, partial, complete, partial]);
  assert.deepEqual(makeRepairCorpus('qualification'), corpus);
  const other = makeRepairCorpus('qualification', 1);
  assert.deepEqual(other.development, corpus.development);
  assert.equal(new Set([...other.transfer, ...corpus.transfer].map(c => c.case_id)).size, 20);
  assert.equal(new Set(corpus.transfer.map(c => assessScan(c).domain.members.length)).size > 1, true);
  assert.ok(corpus.transfer.some(c => BigInt(assessScan(c).domain.identity) > BigInt(Number.MAX_SAFE_INTEGER)));
  for (const specimen of [...corpus.transfer, ...corpus.development]) {
    assert.match(specimen.case_id, /^[a-f0-9]+$/);
    assert.ok(Object.keys(specimen.files).every(path => path === 'scan.json' || /^r-[a-f0-9]+$/.test(path)));
    assert.deepEqual(Object.keys(JSON.parse(specimen.files['scan.json'])).sort(), ['domain', 'visits']);
  }
});

test('assessment reads member bytes, validates stale unavailable metadata before coverage, and retains mismatches', () => {
  const example = corpus.development[0];
  const stale = edit(example, ({visits}) => visits.push({...visits[0], domain_revision: '0', path: 'r-absent'}));
  assert.equal(assessScan(stale).outcome, partial);
  const failed = edit(example, ({visits}) => visits.push({...visits[0], path: 'r-absent'}));
  assert.equal(assessScan(failed).outcome, complete);
  const additional = edit(stale, ({visits}, files) => {
    visits.push({...visits[0], path: 'r-different'});
    files['r-different'] = '9';
  });
  assert.equal(assessScan(additional).outcome, mismatch);
  assert.equal(assessScan(edit(additional, ({visits}) => visits.reverse())).outcome, mismatch);
  assert.equal(assessScan(edit(additional, ({domain}) => { domain.known = false; })).outcome, partial);
  assert.equal(assessScan(edit(example, ({visits}) => { visits[1] = visits[0]; })).outcome, partial);
  assert.equal(assessScan(edit(example, ({visits}) => { visits[0].domain_identity = '42'; })).outcome, partial);
  assert.equal(assessScan(edit(example, ({visits}) => { visits[0].member = '3'; })).outcome, partial);
  assert.throws(() => assessScan(edit(example, ({visits}, files) => { files[visits[0].path] = '01'; })), /u64/);
  assert.throws(() => assessScan(edit(example, ({domain}) => domain.members.push('1'))), /duplicate_declaration/);
});

test('nomination requires one exact report with a compatible canonical program ref', () => {
  const candidate = {kind: 'interface-repair.candidate.v1', status: 'candidate', program: sourceRef(1, 'program'),
    diagnosis: 'A quoted "field": and {braces} are ordinary string content.'};
  const raw = JSON.stringify(candidate);
  assert.deepEqual(parseCandidate(raw), candidate);
  assert.throws(() => parseCandidate(raw.replace('"id":', '"\\u0069d":"extra","id":')), /duplicate_field/);
  assert.throws(() => parseCandidate(raw.replace('"program":', '"program":null,"program":')), /duplicate_field/);
  assert.throws(() => parseCandidate(raw + '{}'), /invalid_json/);
  for (const mutation of [{status: 'no_candidate'}, {program: null}, {program: sourceRef(1)},
    {program: {...candidate.program, id: 'id'}}, {extra: 1}, {diagnosis: null}])
    assert.throws(() => parseCandidate(JSON.stringify({...candidate, ...mutation})));
  assert.equal(parseCandidate(JSON.stringify({...candidate, status: 'no_candidate', program: null})).status, 'no_candidate');
});

test('terminal answers preserve full u64 precision, reject ambiguous or noncanonical envelopes', () => {
  const specimen = corpus.transfer[0];
  assert.equal(parseAnswer(report(specimen, {domain_identity: '18446744073709551615'})).domain_identity,
    '18446744073709551615');
  for (const mutation of [{domain_identity: '18446744073709551616'}, {domain_revision: '01'}, {domain_identity: 41},
    {support: ['abc']}, {support: [{kind: 'value', id: 'FF'.repeat(32)}]}, {extra: null}, {kind: 'old'}])
    assert.throws(() => parseAnswer(report(specimen, mutation)));
  assert.throws(() => parseAnswer(report(specimen).replace('"support":', '"support":[],"support":')), /duplicate_field/);
  assert.deepEqual(gradeAnswer('x', specimen, []).errors, ['invalid_json']);
});

test('answer grading requires exposed sources spanning the universe and the specific mismatch', () => {
  const [specimen, hole] = corpus.development;
  assert.ok(gradeAnswer(report(specimen), specimen, exposure(specimen)).supported);
  const unsupported = gradeAnswer(report(specimen), specimen, [{ref: sourceRef(100), paths: ['scan.json']}]);
  assert.ok(unsupported.unsupported_exhaustion);
  assert.ok(unsupported.outcome_correct);
  assert.ok(unsupported.errors.includes('unsupported_coverage'));
  assert.ok(gradeAnswer(report(specimen), specimen, []).errors.includes('unexposed_support'));
  assert.ok(gradeAnswer(report(specimen), specimen, null).errors.includes('unverified_exposure'));
  assert.ok(gradeAnswer(report(specimen, {domain_revision:'8'}), specimen, exposure(specimen)).errors.includes('wrong_subject'));
  assert.ok(gradeAnswer(report(specimen, {case_id:hole.case_id}), specimen, exposure(specimen)).errors.includes('wrong_case'));
  assert.ok(gradeAnswer(report(hole, {outcome:complete}), hole, exposure(hole)).unsupported_exhaustion);
  const example = corpus.transfer[4];
  assert.ok(gradeAnswer(report(example), example, exposure(example)).supported);
  assert.ok(gradeAnswer(report(example), example, [{ref: sourceRef(100), paths: ['scan.json']}])
    .errors.includes('unsupported_witness'));
});

test('incomplete explanations are independently checked and unknown claims stay open', () => {
  const specimen = corpus.development[1];
  const grade = explanation => gradeAnswer(report(specimen, {explanation}), specimen, exposure(specimen));
  assert.ok(grade('Missing successful coverage of member 2.').supported);
  assert.deepEqual(grade('Missing successful coverage of member 1.').errors, ['incorrect_explanation']);
  assert.deepEqual(grade('Unknown domain.').errors, ['incorrect_explanation']);
  assert.deepEqual(grade('Correct, plus an invented fact.').errors, ['unadjudicated_explanation']);
  for (const [index, explanation] of [[5, 'Invalid visit revision.'], [6, 'Invalid visit identity.'], [7, 'Unknown domain.']]) {
    const example = corpus.transfer[index];
    assert.ok(gradeAnswer(report(example, {explanation}), example, [{ref: sourceRef(100), paths: ['scan.json']}]).supported);
  }
  const mixed = edit(specimen, ({visits}) => visits.push({...visits[0], domain_revision:'0', path:'r-absent'}));
  const answer = report(mixed, {explanation:'Invalid visit revision.'});
  assert.ok(gradeAnswer(answer, mixed, [{ref: sourceRef(100), paths:['scan.json']}]).errors.includes('unexamined_visit'));
  assert.ok(gradeAnswer(answer, mixed, [{ref: sourceRef(100), paths:Object.keys(mixed.files)}]).supported);
});

test('schema-specific checking requires exact subject, observed bytes and ancestry-bearing references', () => {
  const example = corpus.transfer[0], sources = refs(example), canonical = canonicalEvidence(example, sources);
  assert.ok(canonical[0][0] > BigInt(Number.MAX_SAFE_INTEGER));
  assert.equal(inspectProjection(example, sources, 'ScanEvidence', canonical).semantic_judgment, 'supported');
  for (const mutate of [value => value[0][0]++, value => value[0][1]++, value => value[1][0][4]++,
    value => { value[1][0][5] = [3, sourceRef(1234).id]; }]) {
    const altered = structuredClone(canonical); mutate(altered);
    assert.equal(inspectProjection(example, sources, 'ScanEvidence', altered).semantic_judgment, 'incorrect');
    assert.equal(inspectProjection(example, sources, 'ScanOutcome', {tag:1,value:altered}).semantic_judgment, 'incorrect');
  }
  const specimen = corpus.transfer[4], map = refs(specimen), evidence = canonicalEvidence(specimen, map);
  const witness = evidence[1].find(visit => visit[2] !== visit[4]);
  assert.equal(inspectProjection(specimen, map, 'ScanOutcome', {tag:0,value:witness}).semantic_judgment, 'supported');
  assert.equal(inspectProjection(specimen, map, 'ScanOutcome', {tag:0,value:evidence[1].at(-1)}).semantic_judgment, 'incorrect');
  const failed = corpus.transfer[9], failing = canonicalEvidence(failed, refs(failed));
  assert.deepEqual(failing[1].at(-1).slice(3), [false, 0n, [3, refs(failed)['scan.json'].id]]);
  assert.equal(inspectProjection(failed, refs(failed), 'ScanOutcome', {tag:2,value:[3,failing]}).semantic_judgment, 'supported');
});

test('same-consumer probe can falsify a generic payload but differing bytes do not certify it', () => {
  const left = {consumer: sourceRef(7, 'observation'), program: sourceRef(8, 'program'), payload: true, expected: complete};
  const right = {...left, expected: partial};
  assert.equal(collisionProbe(left, right).semantic_judgment, 'lost_distinction');
  assert.deepEqual(collisionProbe(left, {...right,payload:'opaque hash'}), {
    distinction_preserved:true, semantic_judgment:'unestablished'});
  assert.equal(collisionProbe(left, {...right,consumer:sourceRef(9, 'observation')}).distinction_preserved, null);
  assert.equal(inspectProjection(corpus.transfer[0], {}, 'unknown', 'unique hash').semantic_judgment, 'unestablished');
});
