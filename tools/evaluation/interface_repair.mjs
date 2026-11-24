import {createHash} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';

export const scanContract = `Classify a finite scan at the declared identity and revision. The snapshot scan.json declares the subject and lists visits. A visit's source file supplies its actual observed unsigned integer. Missing files indicate failed acquisition. An unknown declaration establishes no authoritative universe and is incomplete. In a known universe a valid available observation unequal to its declared member is a counterexample, including when another visit matches or is invalid. Otherwise any visit with invalid identity, revision or membership makes the scan incomplete, even if unavailable. Exhaustion requires successful matching coverage of every distinct declared member. Duplicate or unavailable visits add no coverage. A known empty domain with no invalid visits is exhausted.`;

export const taskContract = `${scanContract}

Use the terminal report summary for your answer. Return exactly the JSON fields kind ("interface-repair.answer.v1"), case_id, domain_identity, domain_revision (both subject fields are canonical unsigned decimal strings), outcome ("counterexample", "incomplete", or "exhausted_declared_domain"), support (an array of canonical workspace references to evidence you received), and explanation (a string). Cite evidence for the declaration and conclusions about the visits. For a counterexample cite the witnessed mismatch. For exhaustion account for the whole universe. For incomplete identify the missing premise. For exhaustion, "The declared members have successful matching visits." is automatically checkable. For a counterexample, use "Member N disagrees with observed value M." with the witnessed unsigned values. For incomplete, checkable explanations include "Unknown domain.", "Invalid visit identity.", "Invalid visit revision.", "Visit outside domain.", and "Missing successful coverage of member N." Use canonical unsigned decimal numbers for N and M. Other explanations are retained for adjudication.`;

export const candidateContract = `This is directed interface repair. The complete and partial development scans produce the same inadequate Boolean but require different conclusions. Construct a new ordinary pure ProjectionInput(ScanEvidence) -> ProjectionResult(U) with one computed block addressed to the supplied consumer. Use program.build with source_records, execute on the canonical input, select its result and inspect the next request. Nominate your program through the terminal report summary as exactly {"kind":"interface-repair.candidate.v1","status":"candidate","program":<workspace program reference>,"diagnosis":"..."} or use status "no_candidate" and program null. No specific payload layout is required.`;

const incomplete = 'incomplete';
const exhausted = 'exhausted_declared_domain';
const counterexample = 'counterexample';
const outcomes = [counterexample, exhausted, incomplete];
const refKinds = ['program', 'work', 'port', 'value', 'schema', 'source', 'provenance', 'view',
  'runtime', 'residual', 'candidate', 'controller', 'observation'];
const u64Max = '18446744073709551615';

function demand(condition, reason) {
  if (!condition) throw new Error(reason);
}
function uint(value) {
  demand(typeof value === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(value) &&
    (value.length < 20 || value <= u64Max), 'invalid_u64');
  return value;
}
function fields(value, keys) {
  demand(value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key)), 'unexpected_fields');
}
function strictJson(text) {
  demand(typeof text === 'string', 'invalid_json');
  let value;
  try { value = JSON.parse(text); } catch { throw new Error('invalid_json'); }
  const objects = [];
  for (const token of text.matchAll(/"(?:\\.|[^"\\])*"|[{}]/gs)) {
    if (token[0] === '{') objects.push(new Set());
    else if (token[0] === '}') objects.pop();
    else {
      let next = token.index + token[0].length;
      while (next < text.length && ' \t\n\r'.includes(text[next])) next++;
      if (text[next] !== ':') continue;
      const key = JSON.parse(token[0]), keys = objects.at(-1);
      demand(!keys.has(key), 'duplicate_field');
      keys.add(key);
    }
  }
  return value;
}
function reference(value) {
  fields(value, ['kind', 'id']);
  demand(refKinds.includes(value.kind) && typeof value.id === 'string' && /^[a-f0-9]{64}$/.test(value.id),
    'invalid_reference');
  return value;
}
export function parseCandidate(summary) {
  const value = strictJson(summary);
  fields(value, ['kind', 'status', 'program', 'diagnosis']);
  demand(value.kind === 'interface-repair.candidate.v1' && typeof value.diagnosis === 'string', 'invalid_candidate');
  if (value.status === 'candidate') demand(reference(value.program).kind === 'program', 'invalid_candidate_program');
  else demand(value.status === 'no_candidate' && value.program === null, 'invalid_candidate_status');
  return value;
}
export function parseAnswer(summary) {
  const value = strictJson(summary);
  fields(value, ['kind', 'case_id', 'domain_identity', 'domain_revision', 'outcome', 'support', 'explanation']);
  demand(value.kind === 'interface-repair.answer.v1' && typeof value.case_id === 'string' &&
    value.case_id.length && outcomes.includes(value.outcome) && typeof value.explanation === 'string' &&
    value.explanation.trim().length && Array.isArray(value.support), 'invalid_answer');
  uint(value.domain_identity);
  uint(value.domain_revision);
  value.support.forEach(reference);
  return value;
}

const hash = (...parts) => createHash('sha256').update(JSON.stringify(parts)).digest();
const opaque = (...parts) => hash(...parts).toString('hex').slice(0, 24);
function makeCase(key, domain, sequence) {
  const files = {}, visits = sequence.map(({index, identity, revision, actual, unavailable = false}) => {
    const member = domain.members[index], path = 'r-' + opaque(key, index, actual ?? member, unavailable);
    if (!unavailable) files[path] = actual ?? member;
    return {domain_identity: identity ?? domain.identity, domain_revision: revision ?? domain.revision, member, path};
  });
  files['scan.json'] = JSON.stringify({domain, visits});
  return {case_id: opaque(key, 'case'), files};
}
function transferCase(seed, repetition, family) {
  const key = [seed, repetition, family];
  const number = label => hash(key, label).readBigUInt64BE();
  const length = 2 + Number(number('size') % 4n);
  const start = number('members') % (BigInt(u64Max) - 2n * BigInt(length));
  const members = Array.from({length}, (_, i) => String(start + 2n * BigInt(i)));
  const identity = number('domain') | 1n, revision = number('revision') | 1n;
  const domain = {identity: String(identity), revision: String(revision), known: family !== 7, members};
  let visits = members.map((_, index) => ({index}));
  switch (family) {
    case 0: break;
    case 1: visits.pop(); break;
    case 2: visits = [...visits.slice(0, -1), visits[0]]; break;
    case 3: visits = [visits.at(-1), ...visits.reverse()]; break;
    case 4: visits.splice(1, 0, {index: 0, actual: String(start + 1n)}); break;
    case 5: visits = visits.map(visit => ({...visit, revision: String(revision - 1n)})); break;
    case 6: visits = visits.map(visit => ({...visit, identity: String(identity - 1n)})); break;
    case 7: break;
    case 8: domain.members = []; visits = []; break;
    case 9: visits.at(-1).unavailable = true; break;
    default: throw new Error('unknown_transfer_family');
  }
  return makeCase(key, domain, visits);
}
export function makeRepairCorpus(seed, repetition = 0) {
  demand(typeof seed === 'string' && seed.length > 0 && Number.isSafeInteger(repetition) && repetition >= 0,
    'invalid_corpus_seed');
  const domain = {identity: '41', revision: '7', known: true, members: ['1', '2']};
  const development = [2, 1].map(count => makeCase(['development', count], domain,
    Array.from({length: count}, (_, index) => ({index}))));
  const transfer = Array.from({length: 10}, (_, family) => transferCase(seed, repetition, family));
  return {development, transfer};
}

function readScan({files}) {
  const manifest = strictJson(files['scan.json']);
  fields(manifest, ['domain', 'visits']);
  const {domain, visits} = manifest;
  fields(domain, ['identity', 'revision', 'known', 'members']);
  uint(domain.identity);
  uint(domain.revision);
  demand(typeof domain.known === 'boolean' && Array.isArray(domain.members) && Array.isArray(visits),
    'invalid_scan');
  domain.members.forEach(uint);
  demand(new Set(domain.members).size === domain.members.length, 'duplicate_declaration');
  for (const visit of visits) {
    fields(visit, ['domain_identity', 'domain_revision', 'member', 'path']);
    uint(visit.domain_identity);
    uint(visit.domain_revision);
    uint(visit.member);
    demand(typeof visit.path === 'string' && /^r-[a-zA-Z0-9-]+$/.test(visit.path), 'invalid_source_path');
    if (Object.hasOwn(files, visit.path)) uint(files[visit.path]);
  }
  return {domain, visits};
}
export function assessScan(specimen) {
  const {domain, visits} = readScan(specimen);
  const covered = new Map(), witnesses = [], invalid = new Set(), validPaths = new Set();
  for (const visit of visits) {
    if (visit.domain_identity !== domain.identity || visit.domain_revision !== domain.revision ||
        !domain.members.includes(visit.member)) {
      if (visit.domain_identity !== domain.identity) invalid.add('identity');
      if (visit.domain_revision !== domain.revision) invalid.add('revision');
      if (!domain.members.includes(visit.member)) invalid.add('membership');
      continue;
    }
    validPaths.add(visit.path);
    if (!Object.hasOwn(specimen.files, visit.path)) continue;
    if (specimen.files[visit.path] !== visit.member) witnesses.push(visit);
    else covered.set(visit.member, [...(covered.get(visit.member) ?? []), visit.path]);
  }
  const missing = domain.members.filter(member => !covered.has(member));
  const outcome = !domain.known ? incomplete : witnesses.length ? counterexample :
    invalid.size || missing.length ? incomplete : exhausted;
  return {outcome, domain, missing, invalid: [...invalid], valid_visit_paths: [...validPaths], witnesses,
    covered: Object.fromEntries(covered), paths: [...new Set(['scan.json', ...visits.map(v => v.path)])]};
}

export function canonicalEvidence(specimen, sourceRefs) {
  const {domain, visits} = readScan(specimen);
  const encodedVisits = visits.map(visit => {
    const available = Object.hasOwn(specimen.files, visit.path);
    const ref = reference(sourceRefs[available ? visit.path : 'scan.json']);
    demand(ref.kind === 'value', 'invalid_source_reference');
    return [BigInt(visit.domain_identity), BigInt(visit.domain_revision), BigInt(visit.member), available,
      available ? BigInt(specimen.files[visit.path]) : 0n, [3, ref.id]];
  });
  return [[BigInt(domain.identity), BigInt(domain.revision), domain.known, domain.members.map(BigInt)], encodedVisits];
}

function sameMultiset(left, right) {
  if (!Array.isArray(left) || left.length !== right.length) return false;
  const remaining = [...right];
  for (const value of left) {
    const at = remaining.findIndex(other => isDeepStrictEqual(value, other));
    if (at < 0) return false;
    remaining.splice(at, 1);
  }
  return true;
}

function sameScanFacts(evidence, canonical) {
  if (!Array.isArray(evidence) || evidence.length !== 2) return false;
  const [domain, visits] = evidence, [declared, observed] = canonical;
  return Array.isArray(domain) && domain.length === 4 && isDeepStrictEqual(domain.slice(0, 3), declared.slice(0, 3)) &&
    sameMultiset(domain[3], declared[3]) && sameMultiset(visits, observed);
}

export function inspectProjection(specimen, sourceRefs, schemaKind, payload) {
  if (schemaKind !== 'ScanEvidence' && schemaKind !== 'ScanOutcome')
    return {semantic_judgment: 'unestablished', schema_judgment: null, exact_evidence_preservation: null, paths: []};
  const expected = assessScan(specimen), canonical = canonicalEvidence(specimen, sourceRefs);
  let supported = false, paths = expected.paths, exact = null;
  if (schemaKind === 'ScanEvidence' || payload?.tag === 1 || payload?.tag === 2) {
    const evidence = schemaKind === 'ScanEvidence' ? payload : payload.tag === 1 ? payload.value : payload.value?.[1];
    exact = isDeepStrictEqual(evidence, canonical);
    supported = exact || sameScanFacts(evidence, canonical);
    if (schemaKind === 'ScanOutcome') {
      const reason = payload.value?.[0];
      const trueReason = expected.domain.known ?
        (reason === 2 && expected.invalid.length > 0) || (reason === 3 && expected.missing.length > 0) : reason === 0;
      supported = supported && outcomes[payload.tag] === expected.outcome &&
        (payload.tag !== 2 || trueReason);
    }
  } else if (payload?.tag === 0 && expected.outcome === counterexample) {
    const {visits} = readScan(specimen);
    const i = canonical[1].findIndex(visit => isDeepStrictEqual(visit, payload.value));
    if (i >= 0 && expected.witnesses.some(witness => isDeepStrictEqual(witness, visits[i]))) {
      supported = true;
      paths = ['scan.json', visits[i].path];
    }
  }
  return {semantic_judgment: supported ? 'supported' : 'unestablished', schema_judgment: supported ? 'supported' : 'incorrect',
    exact_evidence_preservation: exact, paths: supported ? paths : []};
}

export function collisionProbe(left, right) {
  if (!left || !right || !outcomes.includes(left.expected) || !outcomes.includes(right.expected) ||
      left.expected === right.expected || !left.consumer || !left.program ||
      !isDeepStrictEqual(left.consumer, right.consumer) || !isDeepStrictEqual(left.program, right.program) ||
      left.payload === undefined || right.payload === undefined)
    return {distinction_preserved: null, semantic_judgment: 'unestablished'};
  const distinct = !isDeepStrictEqual(left.payload, right.payload);
  return {distinction_preserved: distinct, semantic_judgment: distinct ? 'unestablished' : 'lost_distinction'};
}

function checkExplanation(text, expected, files) {
  const statement = text.trim().replace(/\.$/, '').toLowerCase();
  if (statement === 'the declared members have successful matching visits')
    return {outcome: exhausted, verified: expected.domain.known && expected.missing.length === 0};
  const mismatch = /^member ([0-9]+) disagrees with observed value ([0-9]+)$/.exec(statement);
  if (mismatch) {
    const witnesses = expected.witnesses.filter(visit => visit.member === mismatch[1] && files[visit.path] === mismatch[2]);
    return {outcome: counterexample, verified: expected.domain.known && witnesses.length > 0, witnesses};
  }
  let verified;
  if (statement === 'unknown domain') verified = !expected.domain.known;
  else if (statement === 'invalid visit identity') verified = expected.domain.known && expected.invalid.includes('identity');
  else if (statement === 'invalid visit revision') verified = expected.domain.known && expected.invalid.includes('revision');
  else if (statement === 'visit outside domain') verified = expected.domain.known && expected.invalid.includes('membership');
  else {
    const missing = /^missing successful coverage of member ([0-9]+)$/.exec(statement);
    if (!missing) return {outcome: null, verified: null};
    verified = expected.domain.known && expected.missing.includes(missing[1]);
  }
  return {outcome: incomplete, verified};
}

export function gradeAnswer(summary, specimen, exposure, evidenceComplete = exposure != null) {
  const expected = assessScan(specimen);
  let answer;
  try { answer = parseAnswer(summary); } catch (error) {
    return {answer: null, outcome_correct: null, supported: false, unsupported_exhaustion: null,
      explanation_verified: null, errors: [error.message]};
  }
  const errors = [];
  if (answer.case_id !== specimen.case_id) errors.push('wrong_case');
  if (answer.domain_identity !== expected.domain.identity || answer.domain_revision !== expected.domain.revision)
    errors.push('wrong_subject');
  if (answer.outcome !== expected.outcome) errors.push('wrong_outcome');
  const outcome_correct = errors.length === 0, paths = new Set();
  let unadjudicatedPayload = false, allCitationsInsufficient = answer.support.length > 0;
  if (!answer.support.length) errors.push('missing_support');
  if (exposure == null) errors.push('unverified_exposure');
  else for (const cited of answer.support) {
    const matches = exposure.filter(row => isDeepStrictEqual(row.ref, cited));
    if (!matches.length) errors.push(evidenceComplete ? 'unexposed_support' : 'unverified_exposure');
    if (!matches.length || matches.some(row => !row.known_lossy && row.semantic_judgment !== 'incorrect'))
      allCitationsInsufficient = false;
    for (const match of matches) {
      for (const path of match.paths) paths.add(path);
      if (match.semantic_judgment === 'unestablished' && !match.known_lossy) unadjudicatedPayload = true;
    }
  }
  const missingEvidence = [];
  const explanation = checkExplanation(answer.explanation, expected, specimen.files);
  if (explanation.verified === null) errors.push('unadjudicated_explanation');
  else if (!explanation.verified) errors.push('incorrect_explanation');
  else if (explanation.outcome !== answer.outcome) errors.push('irrelevant_explanation');
  if (exposure != null && !paths.has('scan.json')) missingEvidence.push('unsupported_declaration');
  if (answer.outcome === counterexample && exposure != null) {
    if (!(explanation.witnesses ?? expected.witnesses).some(witness => paths.has(witness.path)))
      missingEvidence.push('unsupported_witness');
  } else if (answer.outcome === exhausted && exposure != null) {
    if (!expected.domain.known || expected.domain.members.some(member =>
      !expected.covered[member]?.some(path => paths.has(path)))) missingEvidence.push('unsupported_coverage');
    if (expected.paths.some(path => !paths.has(path))) missingEvidence.push('unexamined_visit');
  } else if (answer.outcome === incomplete && expected.outcome === incomplete) {
    if (exposure != null && expected.domain.known && expected.valid_visit_paths.some(path => !paths.has(path)))
      missingEvidence.push('unexamined_visit');
  }
  if (missingEvidence.length) {
    if (unadjudicatedPayload) errors.push('unadjudicated_payload');
    else if (!evidenceComplete && !allCitationsInsufficient) errors.push('unverified_exposure');
    else errors.push(...missingEvidence);
  }
  const supported = !errors.length || (errors.every(error =>
    error === 'unverified_exposure' || error === 'unadjudicated_explanation' || error === 'unadjudicated_payload') ? null : false);
  return {answer, outcome_correct, supported, explanation_verified: explanation.verified,
    unsupported_exhaustion: answer.outcome !== exhausted ? false : supported === null ? null : !supported,
    errors: [...new Set(errors)]};
}
