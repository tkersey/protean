import {createHash} from 'node:crypto';

const key = value => JSON.stringify([value.component, value.revision]);
const pair = value => ({component: value.component, revision: value.revision});
const canonical = value => JSON.stringify(normalize(value));
export const campaignIdentity = plan => createHash('sha256').update(canonical(plan)).digest('hex');
function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, normalize(value[k])]));
  return value;
}
function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}
const identity = value => value && typeof value.component === 'string' && typeof value.revision === 'string';
const unique = values => [...new Set(values)];

export function freezeRecords(records) {
  const byId = new Map();
  for (const record of records) {
    if (!record || typeof record.id !== 'string' || !identity(record)) throw new Error('Invalid record identity');
    if (record.kind === 'manifest') {
      if (typeof record.complete !== 'boolean' || !Array.isArray(record.requirements) ||
          record.requirements.some(r => !identity(r) || (r.flag !== undefined && typeof r.flag !== 'string'))) throw new Error('Invalid manifest');
    } else if (record.kind === 'receipt') {
      if (typeof record.scope !== 'string' || typeof record.available !== 'boolean' || !['pass', 'fail'].includes(record.result)) throw new Error('Invalid receipt');
    } else throw new Error('Invalid record kind');
    if (byId.has(record.id) && canonical(byId.get(record.id)) !== canonical(record)) throw new Error(`Immutable record collision: ${record.id}`);
    byId.set(record.id, record);
  }
  return freeze(structuredClone([...byId.values()]));
}

function manifestMeaning(record) {
  return canonical({component: record.component, revision: record.revision, complete: record.complete,
    requirements: unique(record.requirements.map(r => canonical({...pair(r), flag: r.flag ?? null}))).sort()});
}

export function oracle(request, records) {
  const universe = new Map(freezeRecords(records).map(r => [r.id, r]));
  if (!identity(request.target) || !Array.isArray(request.manifest_ids) || !Array.isArray(request.receipt_ids) ||
      typeof request.scope !== 'string' || !request.flags || typeof request.flags !== 'object' || Array.isArray(request.flags) ||
      Object.values(request.flags).some(v => typeof v !== 'boolean')) throw new Error('Invalid request');
  const manifests = unique(request.manifest_ids).map(id => universe.get(id)).filter(r => r?.kind === 'manifest');
  const receipts = unique(request.receipt_ids).map(id => universe.get(id)).filter(r => r?.kind === 'receipt');
  const reached = new Map([[key(request.target), {...pair(request.target), path: [pair(request.target)]}]]);
  const obligations = [], unresolved = [], blockers = [];
  for (const obligation of reached.values()) {
    const matching = manifests.filter(m => key(m) === key(obligation));
    const issue = (kind, details = {}) => unresolved.push({...pair(obligation), kind, ...details});
    const meanings = unique(matching.map(manifestMeaning));
    const active = [];
    if (!matching.length) issue('missing_manifest', {record_ids: []});
    else if (meanings.length !== 1) issue('conflicting_manifests', {record_ids: matching.map(r => r.id)});
    else {
      const manifest = matching[0];
      if (!manifest.complete) issue('incomplete_manifest', {record_ids: matching.map(r => r.id)});
      for (const requirement of manifest.requirements) {
        if (requirement.flag !== undefined && !Object.hasOwn(request.flags, requirement.flag)) {
          issue('unresolved_flag', {flag: requirement.flag, record_ids: matching.map(r => r.id)});
        } else if (requirement.flag === undefined || request.flags[requirement.flag]) {
          active.push(pair(requirement));
          if (!reached.has(key(requirement))) reached.set(key(requirement), {...pair(requirement), path: [...obligation.path, pair(requirement)]});
        }
      }
    }
    const valid = receipts.filter(r => key(r) === key(obligation) && r.scope === request.scope && r.available);
    const results = unique(valid.map(r => r.result));
    const result = results.length === 1 ? results[0] : results.length === 0 ? 'missing' : 'conflict';
    if (result === 'missing') issue('missing_validation', {record_ids: []});
    if (result === 'conflict') issue('conflicting_receipts', {record_ids: valid.map(r => r.id)});
    const row = {...obligation, manifest_ids: matching.map(r => r.id), receipt_ids: valid.map(r => r.id),
      manifests_resolved: meanings.length === 1, active_requirements: active, result};
    obligations.push(row);
    if (result === 'fail') blockers.push({...pair(obligation), path: obligation.path, receipt_ids: valid.map(r => r.id)});
  }
  return freeze({request_id: request.id, status: blockers.length ? 'blocked' : unresolved.length ? 'incomplete' : 'ready',
    obligations, blockers, unresolved});
}

export const contract = `Investigate each release request using the supplied component manifests, configuration, and validation records. Determine whether the release is ready, blocked, or incomplete. Support each conclusion with the relevant records. More requests will arrive during this task. Keep the task open until END, then submit one final report covering every request.

This is a controlled audit workload. Every packet has a packet_id, requests, and documents. Each document is one immutable record. Each request supplies id, target {component,revision}, flags (named Boolean configuration), scope, manifest_ids, and receipt_ids. Only those explicit record identities apply to that request, including referenced documents delivered previously. Later documents never change an earlier request's evidence universe. Exact strings identify components, revisions, scopes, and records; display names and other metadata do not identify them. Two different payloads may not claim the same record identity.

A manifest has kind=manifest, id, component, revision, complete, and requirements. Each requirement has component and revision and may have flag naming a Boolean configuration flag. A receipt has kind=receipt, id, component, revision, scope, available, and result (pass or fail). There are no version ranges, alternative dependencies, priorities, or temporal precedence rules.

The target and all directly or indirectly required prerequisites need validation. Repeated paths do not create additional obligations. Cycles are not failures. Requirements without flag are mandatory. Conditional requirements apply when their flag is true; a missing flag leaves uncertainty. Ready requires complete, unambiguous applicable requirements and uncontradicted successful validation for every obligation. A confirmed required component with uncontradicted failure establishes blocked even if unrelated information is missing. Otherwise the answer is incomplete.

Validation must match exact component, revision, scope, and supplied record identity. Stale, foreign, unavailable, or unbound receipts establish no result. Agreeing duplicate receipts add no coverage; valid pass/fail conflicts are unresolved. Missing or incomplete manifests prevent readiness. Confirmed listed requirements in an incomplete manifest still apply. Requirements from conflicting manifests cannot establish a path, although the component itself and independently confirmed paths remain obligations. Manifest agreement compares component/revision, completeness, and the set of requirement targets and activation conditions. Record identity, requirement ordering, display names, and irrelevant metadata do not create semantic disagreement.

To wait for more inputs, ask exactly "Please send the next request."

At END, put exactly one JSON object, without Markdown, in the ordinary report's summary field, in this format: {"answers":[{"request_id":"request identity","status":"ready|blocked|incomplete","records":["supporting raw record identities"],"artifact_refs":[],"support":{}}]}. Give one answer per request. artifact_refs lists any retained artifact identities used, or an empty array. These references do not replace raw record support. Documents in task messages are supplied premises, not independently acquired facts. Any native report claims must cite actual available evidence-vector entries; message and record identities are not evidence-vector indices. State supplied-premise conclusions conditionally where appropriate.

For ready, support must contain coverage: [{component,revision,receipts:["successful applicable receipt identities"]}] covering every obligation, and records must cite its applicable manifests and receipts. For blocked, support must contain blocker: {component,revision} and path: [{component,revision}, ...] starting at the target and ending at the blocker; cite the manifests establishing each step and its failure receipt. For incomplete, support must contain path to an unresolved component and unresolved: {kind,component,revision,flag?}; kind is missing_manifest, incomplete_manifest, conflicting_manifests, unresolved_flag, missing_validation, or conflicting_receipts. Cite the applicable records establishing the unresolved premise and the requirement path; missing records need no invented citation. A missing flag witness names flag. Cite both sides of a conflict. A path containing just the target is valid when the target itself is the witness. All cited records must belong to that request's applicable universe.`;

export function createCorpus(seed = 1) {
  if (!Number.isSafeInteger(seed)) throw new Error('Corpus seed must be a safe integer');
  let state = seed >>> 0;
  const shuffle = values => {
    const result = [...values];
    for (let i = result.length - 1; i > 0; i--) {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
      const j = state % (i + 1);
      [result[i], result[j]] = [result[j], result[i]];
    }
    return result;
  };
  const prefix = `audit-${seed}`;
  const names = shuffle(['engine', 'queue', 'gateway', 'catalog', 'cache', 'planner', 'worker', 'router', 'index', 'store', 'codec', 'journal', 'proxy', 'clock', 'schema', 'digest', 'ring-east', 'ring-west', 'ring-north', 'bundle', 'absent', 'unfamiliar-zeta', 'extension']);
  const p = (n, revision = 'r1') => ({component: `${prefix}/${names[n]}`, revision});
  const requirements = [[1, 2, 3], [4, 5, 6], [4, 6, 7], [5, 7, 8], [9, 10, 11], [9, 11, 12], [10, 12, 13], [11, 13, 14], [12, 14, 15], [14, 15], [14, 15], [15], [15], [15], [15], [], [17], [18], [16], [15, 20], [], [], [15]];
  const allRecords = [], requests = [], packets = [], published = new Set();
  const add = record => { allRecords.push(record); return record.id; };
  const base = requirements.map((deps, i) => ({kind: 'manifest', id: `${prefix}/manifest-${i}`, ...p(i),
    display_name: `Service ${names[(i + 5) % names.length]}`, complete: i !== 19,
    requirements: shuffle([...deps.map(n => p(n)), ...(i === 0 ? [{...p(22), flag: 'extended'}] : [])]),
    owner_note: `Team ${(i + seed) % 7}`, layout_revision: (i % 3) + 1}));
  base.forEach((m, i) => { if (i !== 20) add(m); });
  const initialManifestIds = base.filter((_, i) => i <= 15 || i === 22).map(m => m.id);
  const receipt = (scope, n, result = 'pass', extra = {}) => {
    const id = `${prefix}/receipt-${allRecords.length}`;
    return add({kind: 'receipt', id, ...p(n), scope, available: true, result,
      display_name: `Validation ${names[(n + 9) % names.length]}`, ...extra});
  };
  const passSet = (scope, ids) => ids.map(i => receipt(scope, i));
  const request = (target, scope, manifestIds, receiptIds, flags = {extended: false}) => {
    const result = {id: `${prefix}/request-${requests.length + 1}`, target, scope, flags,
      manifest_ids: shuffle(manifestIds), receipt_ids: shuffle(receiptIds)};
    requests.push(result);
    return result;
  };
  const packet = included => {
    const index = packets.length;
    const referenced = new Set(included.flatMap(r => [...r.manifest_ids, ...r.receipt_ids]));
    const documents = shuffle(allRecords.filter(r => referenced.has(r.id) && !published.has(r.id)));
    documents.forEach(r => published.add(r.id));
    const id = `${prefix}/packet-${index}`;
    packets.push({id, offset_ms: index * 180000, bytes: JSON.stringify({packet_id: id, requests: included, documents}, null, index % 2 ? 0 : 2), request_ids: included.map(r => r.id)});
  };
  const initialScope = `${prefix}/scope-initial`;
  const initialReceipts = passSet(initialScope, Array.from({length: 16}, (_, i) => i));
  const first = request(p(0), initialScope, initialManifestIds, initialReceipts);
  const secondScope = `${prefix}/scope-other`;
  const second = request(p(1), secondScope, initialManifestIds,
    [...passSet(secondScope, Array.from({length: 16}, (_, i) => i).filter(i => i !== 15)), receipt(secondScope, 15, 'fail')]);
  packet([first, second]);
  const smallScope = `${prefix}/scope-small`;
  packet([request(p(21), smallScope, [base[21].id], [receipt(smallScope, 21)])]);
  const changedScope = `${prefix}/scope-changed`;
  packet([request(p(0), changedScope, initialManifestIds,
    [...passSet(changedScope, Array.from({length: 15}, (_, i) => i)), receipt(changedScope, 15, 'fail')])]);
  const diamondScope = `${prefix}/scope-diamond`;
  const diamondReceipts = passSet(diamondScope, Array.from({length: 15}, (_, i) => i));
  packet([request(p(1), diamondScope, initialManifestIds,
    [...diamondReceipts, receipt(diamondScope, 9), receipt(diamondScope, 9)])]);
  const cycleScope = `${prefix}/scope-cycle`;
  packet([request(p(16), cycleScope, [16, 17, 18].map(i => base[i].id), passSet(cycleScope, [16, 17, 18]))]);
  const missingScope = `${prefix}/scope-partial`;
  packet([request(p(19), missingScope, [base[19].id, base[15].id, base[20].id], passSet(missingScope, [19, 15, 20]))]);
  const blockerScope = `${prefix}/scope-blocker`;
  packet([request(p(19), blockerScope, [base[19].id, base[15].id, base[20].id], [receipt(blockerScope, 19), receipt(blockerScope, 15, 'fail')])]);
  const conflictId = add({...base[4], id: `${prefix}/manifest-conflict`, requirements: [...base[4].requirements, p(22)]});
  const agreementId = add({...base[1], id: `${prefix}/manifest-agreement`, requirements: [...base[1].requirements].reverse(), display_name: 'Renamed presentation'});
  const conflictScope = `${prefix}/scope-conflict`;
  packet([request(p(1), conflictScope, [...initialManifestIds, conflictId, agreementId],
    [...passSet(conflictScope, Array.from({length: 16}, (_, i) => i)), receipt(conflictScope, 5, 'fail'),
      receipt(conflictScope, 6, 'fail', {revision: 'r0'}), receipt(`${prefix}/foreign`, 7, 'fail'),
      receipt(conflictScope, 8, 'fail', {available: false}), `${prefix}/unbound-receipt`])]);
  const revisionId = add({...base[0], id: `${prefix}/manifest-revision`, revision: 'r2', requirements: [...base[0].requirements, p(22)]});
  const revisionScope = `${prefix}/scope-revision`;
  packet([request(p(0, 'r2'), revisionScope, [...initialManifestIds, revisionId],
    [...passSet(revisionScope, Array.from({length: 16}, (_, i) => i)), receipt(revisionScope, 0, 'pass', {revision: 'r2'})])]);
  packet([request(p(0), initialScope, initialManifestIds, initialReceipts, {extended: true})]);
  packet([request(p(0), initialScope, initialManifestIds, initialReceipts)]);
  packets.push({id: `${prefix}/END`, offset_ms: 1980000, bytes: JSON.stringify({packet_id: `${prefix}/END`, event: 'END'}), request_ids: []});
  const records = freezeRecords(allRecords);
  const corpus = {contract, seed, packets, requests, records};
  return freeze({...corpus, expected: requests.map(r => oracle(r, requestRecords(corpus, r.id)))});
}

export function requestRecords(corpus, requestId) {
  if (corpus.delivery === 'online') return corpus.records;
  if (!Array.isArray(corpus.packets)) return corpus.records;
  const visible = [];
  for (const packet of corpus.packets) {
    const contents = JSON.parse(packet.bytes);
    visible.push(...(contents.documents ?? []));
    if (packet.request_ids.includes(requestId)) return freezeRecords(visible);
  }
  return [];
}

export function createOnlineCorpus(seed = 1) {
  const original = createCorpus(seed);
  let source = '';
  const locations = new Map();
  for (const record of original.records) {
    const bytes = JSON.stringify(record) + '\n';
    locations.set(record.id, {start: Buffer.byteLength(source), length: Buffer.byteLength(bytes)});
    source += bytes;
  }
  const packets = original.packets.map(packet => {
    if (!packet.request_ids.length) return packet;
    const requests = original.requests.filter(request => packet.request_ids.includes(request.id));
    const selected = unique(requests.flatMap(request => [...request.manifest_ids, ...request.receipt_ids]))
      .map(id => locations.get(id)).filter(Boolean).sort((left, right) => left.start - right.start);
    const ranges = [];
    for (const range of selected) {
      const previous = ranges.at(-1);
      if (previous && previous.start + previous.length === range.start && previous.length + range.length <= 4096)
        previous.length += range.length;
      else ranges.push({path: 'records.jsonl', ...range});
    }
    return {...packet, bytes: JSON.stringify({packet_id: packet.id, requests, source_ranges: ranges})};
  });
  const onlineContract = contract
    .replace('Keep the task open until END, then submit one final report covering every request.',
      'Answer each selected packet before consuming the next selection. Keep the task open until END, then submit one final report covering every request. Preserve supported answers while using time and inference economically; choose your own method and whether any retained computation or representation is useful.')
    .replace('Every packet has a packet_id, requests, and documents. Each document is one immutable record.',
      'Every selection packet has a packet_id, requests, and source_ranges. All immutable source records are available from the start in the admitted snapshot file records.jsonl, one JSON record per line. Future request choices are selected only by later packets. Source ranges locate applicable records in that file; they are ordinary snapshot byte ranges, not new authority or proof of coverage. Acquire and cite the actual source records. The source file is complete and immutable, and no new records arrive later.')
    .replace('Only those explicit record identities apply to that request, including referenced documents delivered previously. Later documents never change an earlier request\'s evidence universe.',
      'Only those explicit record identities apply to that request. The presence of other records in the snapshot never expands a request\'s evidence universe.')
    .replace('To wait for more inputs, ask exactly "Please send the next request."',
      'For each selected packet, call ask with question set to one JSON object as text: {"kind":"recurrence.answers.v1","packet_id":"selected packet identity","answers":[the supported answers to exactly that packet\'s requests]}. Use the same answer fields and support rules as the final report below. This delivers your answers to the consumer and waits for the next scheduled selection. No correctness feedback is provided. Deliver one answer batch per packet; a later correction does not erase an earlier unsupported conclusion. Reading records does not select a request, and guessing a future request earns no credit. If you need more input without delivering an answer, the ordinary wait phrase remains "Please send the next request."')
    .replace('Documents in task messages are supplied premises, not independently acquired facts.',
      'Request choices are supplied premises. Source records must be acquired from the admitted snapshot; record identities are not evidence-vector indices.') +
    '\n\nResource status accompanies existing deliveries. admitted_attempts and request_bytes are owner counters; request_bytes is bytes, not tokens. known_output_tokens is only a known lower bound. Missing values and monetary charges remain unknown. remaining_wall_ms is the external evaluator\'s remaining allowance, not a fresh deadline. No construction, representation, review, or controller replacement is required.';
  const corpus = {...original, contract: onlineContract, delivery: 'online', packets,
    sources: {'records.jsonl': source}};
  return freeze({...corpus, expected: corpus.requests.map(request => oracle(request, requestRecords(corpus, request.id)))});
}

export function parseOnlineAnswer(raw) {
  let value;
  try { value = JSON.parse(raw); } catch { return null; }
  return value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === 'answers,kind,packet_id' &&
    value.kind === 'recurrence.answers.v1' && typeof value.packet_id === 'string' &&
    Array.isArray(value.answers) ? value : null;
}

function proofPath(path, target, endpoint, expected, citations) {
  if (!Array.isArray(path) || !path.length || path.some(p => !identity(p)) ||
      key(path[0]) !== key(target) || key(path.at(-1)) !== key(endpoint)) return false;
  for (let i = 0; i + 1 < path.length; i++) {
    const row = expected.obligations.find(o => key(o) === key(path[i]));
    if (!row?.manifests_resolved || !row.manifest_ids.some(id => citations.has(id)) ||
        !row.active_requirements.some(p => key(p) === key(path[i + 1]))) return false;
  }
  return true;
}

function supportErrors(answer, request, expected, records) {
  const errors = [];
  if (!Array.isArray(answer.records) || answer.records.some(id => typeof id !== 'string') ||
      !Array.isArray(answer.artifact_refs) || answer.artifact_refs.some(id => typeof id !== 'string') ||
      !answer.support || typeof answer.support !== 'object' || Array.isArray(answer.support)) return ['malformed_support'];
  const citations = new Set(answer.records), applicable = new Set([...request.manifest_ids, ...request.receipt_ids]);
  if ([...citations].some(id => !applicable.has(id) || !records.has(id))) errors.push('inapplicable_record');
  const support = answer.support;
  if (answer.status === 'ready') {
    if (!Array.isArray(support.coverage)) return [...errors, 'missing_coverage'];
    const covered = new Set();
    for (const entry of support.coverage) {
      if (!identity(entry) || !Array.isArray(entry.receipts) || covered.has(key(entry))) { errors.push('invalid_coverage'); continue; }
      covered.add(key(entry));
      const row = expected.obligations.find(o => key(o) === key(entry));
      if (!row || row.result !== 'pass' || !row.manifests_resolved || !row.manifest_ids.some(id => citations.has(id)) ||
          !entry.receipts.length || entry.receipts.some(id => !citations.has(id) || !row.receipt_ids.includes(id))) errors.push('unsupported_coverage');
    }
    if (expected.obligations.some(o => !covered.has(key(o)))) errors.push('incomplete_coverage');
  } else if (answer.status === 'blocked') {
    const blocker = identity(support.blocker) && expected.blockers.find(o => key(o) === key(support.blocker));
    if (!blocker || !blocker.receipt_ids.some(id => citations.has(id)) ||
        !proofPath(support.path, request.target, blocker, expected, citations)) errors.push('unsupported_blocker');
  } else if (answer.status === 'incomplete') {
    const witness = support.unresolved;
    const issue = identity(witness) && expected.unresolved.find(o => key(o) === key(witness) && o.kind === witness.kind && o.flag === witness.flag);
    if (!issue || !proofPath(support.path, request.target, issue, expected, citations)) return [...errors, 'unsupported_uncertainty'];
    const cited = issue.record_ids.filter(id => citations.has(id)).map(id => records.get(id));
    if (['incomplete_manifest', 'unresolved_flag'].includes(issue.kind) && !cited.length) errors.push('uncited_uncertainty');
    if (issue.kind === 'conflicting_manifests' && unique(cited.map(manifestMeaning)).length < 2) errors.push('uncited_manifest_conflict');
    if (issue.kind === 'conflicting_receipts' && unique(cited.map(r => r.result)).length < 2) errors.push('uncited_receipt_conflict');
  }
  return unique(errors);
}

export function parseReport(raw) {
  const value = JSON.parse(raw);
  if (!value || typeof value !== 'object' || Array.isArray(value) || !Array.isArray(value.answers)) throw new Error('Expected answer map');
  return value;
}

export function gradeReport(rawSummary, corpus, visibleRequests = null) {
  freezeRecords(corpus.records);
  let report;
  try { report = parseReport(rawSummary); } catch { report = null; }
  const known = new Set(corpus.requests.map(r => r.id));
  const reportErrors = report ? report.answers.filter(a => !a || typeof a !== 'object' || !known.has(a.request_id)).map(() => 'unknown_request') : ['malformed_report'];
  const answers = corpus.requests.map(request => {
    const available = requestRecords(corpus, request.id);
    const records = new Map(available.map(r => [r.id, r]));
    const expected = oracle(request, available);
    const matching = visibleRequests && !visibleRequests.has(request.id) ? [] :
      report?.answers.filter(a => a?.request_id === request.id) ?? [];
    const answer = matching.length === 1 ? matching[0] : null;
    const errors = !report ? ['malformed_report'] : !matching.length ? ['unanswered'] : matching.length > 1 ? ['duplicate_request'] :
      !['ready', 'blocked', 'incomplete'].includes(answer.status) ? ['invalid_status'] :
        [...(answer.status === expected.status ? [] : ['incorrect_status']), ...supportErrors(answer, request, expected, records)];
    const sound = errors.length === 0;
    return {request_id: request.id, expected: expected.status, status: answer?.status ?? null, sound,
      critical: !sound && matching.some(a => ['ready', 'blocked'].includes(a.status)), unanswered: matching.length === 0, errors};
  });
  return {answers, errors: unique(reportErrors), totals: {requests: answers.length, sound: answers.filter(a => a.sound).length,
    critical: answers.filter(a => a.critical).length, unanswered: answers.filter(a => a.unanswered).length}};
}

const eventSequence = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? BigInt(value) :
  Number.isSafeInteger(value) && value >= 0 ? BigInt(value) : null;
const gradeTotals = answers => ({requests: answers.length, sound: answers.filter(answer => answer.sound).length,
  critical: answers.filter(answer => answer.critical).length, unanswered: answers.filter(answer => answer.unanswered).length});

export function gradeOnlineAnswers(corpus, answerEvents = [], visibility = []) {
  const errors = [], seen = new Map(), sequences = new Map(), deliveries = [];
  for (const event of answerEvents) {
    const sequence = eventSequence(event.event_seq), envelope = parseOnlineAnswer(event.raw);
    const identity = [event.event_seq, event.question_id, event.question_revision, event.request_digest];
    const binding = identity.map(value => String(value)).join('/');
    if (seen.get(binding) === event.raw) continue;
    const conflicting = seen.has(binding) || sequences.has(String(event.event_seq)) && sequences.get(String(event.event_seq)) !== binding;
    seen.set(binding, event.raw);
    sequences.set(String(event.event_seq), binding);
    const bound = sequence !== null && ['question_id', 'request_digest'].every(field =>
      typeof event[field] === 'string' && event[field].length > 0) && eventSequence(event.question_revision) !== null;
    const position = envelope ? corpus.packets.findIndex(packet => packet.id === envelope.packet_id && packet.request_ids.length) : -1;
    const packet = corpus.packets[position], next = corpus.packets[position + 1];
    const selected = visibility.find(item => item.packet_id === packet?.id && item.confirmed === true);
    const later = visibility.find(item => item.packet_id === next?.id);
    const selectedCut = eventSequence(selected && Object.hasOwn(selected, 'confirmed_preparation_cut') ?
      selected.confirmed_preparation_cut : selected?.preparation_cut);
    const laterCut = eventSequence(later && Object.hasOwn(later, 'possible_preparation_cut') ?
      later.possible_preparation_cut : later?.preparation_cut);
    const selectedBefore = bound && selectedCut !== null && selectedCut < sequence;
    const beforeNext = !later || later.possible_preparation_cut === null ||
      laterCut !== null && sequence !== null && sequence <= laterCut;
    const supplied = envelope?.answers ?? [];
    const scoped = !!packet && supplied.every(answer => packet.request_ids.includes(answer?.request_id));
    const grading = gradeReport(JSON.stringify({answers: supplied}), corpus,
      new Set(selectedBefore ? packet.request_ids : []));
    const faults = [!bound && 'unbound_answer_event', !envelope && 'malformed_answer_envelope',
      !packet && 'unknown_answer_packet', !selectedBefore && 'request_not_selected',
      !beforeNext && 'answer_after_next_selection', conflicting && 'conflicting_answer_replay',
      !scoped && 'answer_outside_packet'].filter(Boolean);
    deliveries.push({...event, envelope, timely: selectedBefore && beforeNext, errors: faults, grading});
    errors.push(...faults);
  }
  deliveries.sort((left, right) => {
    const a = eventSequence(left.event_seq), b = eventSequence(right.event_seq);
    return a === null ? 1 : b === null ? -1 : a < b ? -1 : a > b ? 1 : 0;
  });
  const answers = corpus.requests.map(request => {
    const packet = corpus.packets.find(item => item.request_ids.includes(request.id));
    const matching = deliveries.filter(delivery => delivery.envelope?.packet_id === packet?.id ||
      delivery.envelope?.answers.some(answer => answer?.request_id === request.id));
    const first = matching[0], row = first?.grading.answers.find(answer => answer.request_id === request.id);
    const supplied = first?.envelope?.answers.filter(answer => answer?.request_id === request.id) ?? [];
    const critical = matching.some(delivery => {
      const grade = delivery.grading.answers.find(answer => answer.request_id === request.id);
      return grade?.critical || (!delivery.timely || delivery.errors.length) &&
        delivery.envelope?.answers.some(answer => answer?.request_id === request.id && ['ready', 'blocked'].includes(answer.status));
    });
    return {request_id: request.id, expected: row?.expected ?? oracle(request, requestRecords(corpus, request.id)).status,
      status: row?.status ?? null, sound: matching.length === 1 && first.timely && first.errors.length === 0 && row.sound &&
        first.grading.errors.length === 0, critical, unanswered: !first || row.unanswered,
      errors: unique([...(row?.errors ?? ['unanswered']), ...(first?.errors ?? []),
        ...(first?.grading.errors ?? []), ...(matching.length > 1 ? ['duplicate_answer_delivery'] : [])]),
      answer: supplied.length === 1 ? supplied[0] : null,
      event_seq: first?.event_seq ?? null, question_id: first?.question_id ?? null,
      question_revision: first?.question_revision ?? null, request_digest: first?.request_digest ?? null,
      observed_ms: first?.observed_ms ?? null};
  });
  const complete = errors.length === 0 && answers.every(answer => answer.event_seq !== null && !answer.unanswered &&
    !answer.errors.includes('duplicate_answer_delivery'));
  return {deliveries, answers, errors: unique(errors), totals: gradeTotals(answers), complete};
}

export function combineOnlineGrading(finalGrading, onlineGrading) {
  const answers = finalGrading.answers.map(answer => {
    const delivered = onlineGrading.answers.find(item => item.request_id === answer.request_id);
    return {...answer, sound: answer.sound && delivered?.sound === true,
      critical: answer.critical || delivered?.critical === true,
      unanswered: answer.unanswered || !delivered || delivered.unanswered,
      errors: unique([...answer.errors, ...(delivered?.errors ?? ['missing_online_answer']).map(error => `online:${error}`)])};
  });
  return {answers, errors: unique([...finalGrading.errors, ...onlineGrading.errors.map(error => `online:${error}`)]),
    totals: gradeTotals(answers)};
}

const finite = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const sumKnown = values => values.every(finite) ? values.reduce((sum, value) => sum + value, 0) : null;
const conjunction = facts => facts.includes(false) ? false : facts.every(fact => fact === true) ? true : null;
const paybackQuality = (control, treatment) => [control?.sound, treatment?.sound, treatment?.critical].every(finite) ?
  treatment.sound >= control.sound && treatment.critical === 0 : null;

function compliance(report, limits) {
  const groups = [report?.metrics?.controller, report?.metrics?.delegated];
  const tokens = groups.every(g => g && g.missing_usage === 0) ? sumKnown(groups.flatMap(g => [g.input_tokens, g.output_tokens])) : null;
  const knownTokens = groups.flatMap(g => [g?.input_tokens, g?.output_tokens]).filter(finite);
  const lowerBounds = {tokens: knownTokens.length ? sumKnown(knownTokens) : null};
  const calls = sumKnown(groups.map(g => g?.calls));
  const measurements = {wall_ms: report?.elapsed_ms, tokens, provider_attempts: calls,
    namespace_bytes: report?.retained_namespace_bytes, rss_bytes: report?.peak_rss_sampled_bytes};
  const checks = Object.fromEntries(Object.entries(measurements).map(([name, value]) => [name,
    finite(value) && finite(limits?.[name]) ? value <= limits[name] : null]));
  if (finite(lowerBounds.tokens) && finite(limits?.tokens) && lowerBounds.tokens > limits.tokens) checks.tokens = false;
  return {measurements, lower_bounds: lowerBounds, checks,
    compliant: Object.values(checks).includes(false) ? false : Object.values(checks).includes(null) ? null : true};
}

export function compareCampaign(plan, reports = []) {
  const issues = [];
  const cases = Array.isArray(plan.cases) ? plan.cases : [];
  if (cases.length !== 6 || new Set(cases.map(c => c.id)).size !== 6) issues.push('Expected six distinct planned attempts');
  const model = plan.cost_model;
  const costModelKnown = model && typeof model.id === 'string' && model.id.length > 0 &&
    typeof model.currency === 'string' && model.currency.length > 0 && model.predeclared === true;
  if (!costModelKnown) issues.push('Predeclared cost model unavailable');
  const unattributedReports = [];
  const attempts = cases.map(subject => {
    const matches = reports.filter(r => r?.subject?.id === subject.id);
    const received = matches.length === 1 ? matches[0] : null;
    const identityMatches = !!received && canonical(received.subject) === canonical(subject) &&
      received.plan_sha256 === campaignIdentity(plan);
    if (!received) issues.push(`${subject.id}: ${matches.length ? 'duplicate reports' : 'missing report'}`);
    if (received && !identityMatches) issues.push(`${subject.id}: subject mismatch`);
    if (!identityMatches) unattributedReports.push(...matches);
    const report = identityMatches ? received : null;
    const totals = report?.grading?.totals;
    const gradingKnown = totals && ['requests', 'sound', 'critical', 'unanswered'].every(k => Number.isSafeInteger(totals[k]) && totals[k] >= 0) &&
      totals.requests === 12 && totals.sound + totals.critical <= totals.requests && totals.sound + totals.unanswered <= totals.requests;
    const integrityKnown = report && Array.isArray(report.arm_violations) && Array.isArray(report.errors);
    const end = subject.end_packet;
    const endVisible = end && Array.isArray(report?.reuse?.visibility) ? report.reuse.visibility.some(item =>
      item.packet_id === end.id && item.confirmed === true && finite(item.dispatch_ms) &&
      item.dispatch_ms >= end.offset_ms && item.dispatch_ms <= report.elapsed_ms) : null;
    const streamComplete = endVisible === null || !report?.status ? null : endVisible && report.status.status === 'completed';
    const serviceComplete = plan.suite !== 'recurrence-online' ? true : conjunction([
      typeof report?.online?.complete === 'boolean' ? report.online.complete : null,
      gradingKnown ? totals.sound === totals.requests && totals.critical === 0 && totals.unanswered === 0 : null,
    ]);
    const integrity = received && !identityMatches ? false : !integrityKnown ? null : report.arm_violations.length || report.errors.length ||
      streamComplete === false ? false : streamComplete === true ? true : null;
    const budget = compliance(report, plan.limits);
    const cost = costModelKnown && report?.cost?.complete === true && finite(report.cost.total) &&
      report.cost.model_id === model.id && report.cost.currency === model.currency ? report.cost.total : null;
    const reuse = report?.reuse;
    const mechanism = subject.arm === 'treatment' ? reuse?.qualified === false || reuse?.recovered === false ? false :
      reuse?.qualified === true && reuse?.recovered === true && integrity === true ? true : null : null;
    return {subject, present: !!received, stream_complete: streamComplete,
      ...(plan.suite === 'recurrence-online' ? {service_complete: serviceComplete} : {}),
      grading: gradingKnown ? totals : null, integrity, budget, cost,
      currency: model?.currency ?? null, mechanism, errors: report?.errors ?? null, arm_violations: report?.arm_violations ?? null};
  });
  const extraReports = reports.filter(r => !cases.some(c => c.id === r?.subject?.id));
  if (extraReports.length) issues.push('Unplanned attempts require separate inclusive accounting');
  const pairIds = unique(cases.map(c => c.pair));
  if (pairIds.length !== 3) issues.push('Expected three matched pairs');
  const pairs = pairIds.map(id => {
    const members = attempts.filter(a => a.subject.pair === id);
    const ordinary = members.filter(a => a.subject.arm === 'ordinary');
    const treatment = members.filter(a => a.subject.arm === 'treatment');
    if (ordinary.length !== 1 || treatment.length !== 1 || members.length !== 2) return {pair: id, verdict: 'undetermined', reason: 'Invalid pair membership', cost_positive: null, quality_improvement: null, mechanism: null};
    const [control] = ordinary, [enabled] = treatment;
    const valid = [control, enabled].every(a => a.present && a.grading && a.integrity === true);
    const within = [control, enabled].every(a => a.budget.compliant === true);
    const served = plan.suite !== 'recurrence-online' || [control, enabled].every(a => a.service_complete === true);
    const quality = valid && within && served ? enabled.grading.sound > control.grading.sound && enabled.grading.critical <= control.grading.critical : null;
    const costKnown = finite(control.cost) && finite(enabled.cost);
    const qualityEligible = valid ? paybackQuality(control.grading, enabled.grading) : null;
    const positive = qualityEligible === false || [control, enabled].some(a => a.service_complete === false) ? false :
      valid && within && served && costKnown ? enabled.cost < control.cost : null;
    let verdict = 'undetermined';
    if ([control, enabled].some(a => a.stream_complete === false || a.service_complete === false) ||
      valid && [control, enabled].some(a => a.budget.compliant === false)) verdict = 'no_practical_improvement';
    else if (positive) verdict = 'cost_positive_improvement';
    else if (quality && costKnown && enabled.cost > control.cost) verdict = 'tradeoff';
    else if (quality) verdict = 'quality_improvement_within_common_envelope';
    else if (positive === false) verdict = 'no_practical_improvement';
    return {pair: id, ordinary: control.subject.id, treatment: enabled.subject.id, verdict, cost_positive: positive,
      quality_improvement: quality, mechanism: enabled.mechanism, cost_difference: costKnown ? enabled.cost - control.cost : null,
      sound_difference: valid ? enabled.grading.sound - control.grading.sound : null};
  });
  const aggregate = Object.fromEntries(['ordinary', 'treatment'].map(arm => {
    const selected = attempts.filter(a => a.subject.arm === arm);
    return [arm, {attempts: selected.length, cost: selected.length === 3 ? sumKnown(selected.map(a => a.cost)) : null,
      sound: selected.length === 3 ? sumKnown(selected.map(a => a.grading?.sound)) : null,
      critical: selected.length === 3 ? sumKnown(selected.map(a => a.grading?.critical)) : null}];
  }));
  const qualifyingTraces = pairs.filter(p => p.cost_positive === true && p.mechanism === true).length;
  const complete = issues.length === 0 && attempts.every(a => a.present && a.grading && a.integrity === true &&
    a.budget.compliant === true && finite(a.cost) && (plan.suite !== 'recurrence-online' || a.service_complete === true));
  const qualityEligible = attempts.every(a => a.integrity === true) ? paybackQuality(aggregate.ordinary, aggregate.treatment) : null;
  const economics = qualityEligible === false || attempts.some(attempt => attempt.service_complete === false) ? false :
    complete && qualityEligible === true ? aggregate.treatment.cost < aggregate.ordinary.cost : null;
  const disqualified = attempts.some(a => a.stream_complete === false || a.service_complete === false || a.budget.compliant === false ||
    (a.subject.arm === 'treatment' && a.grading?.critical > 0));
  const noQualifyingTrace = pairs.length === 3 && pairs.every(pair => pair.mechanism === false || pair.cost_positive === false);
  const milestone = disqualified || economics === false || noQualifyingTrace ? false :
    complete && economics === true && qualifyingTraces > 0 ? true : null;
  return {attempts, pairs, aggregate, qualifying_traces: qualifyingTraces, campaign_cost_positive: economics, complete_milestone: milestone,
    verdict: milestone === true ? 'cost_positive_improvement' : milestone === false ? 'no_practical_improvement' : 'undetermined',
    issues, additional_attempts: extraReports, unattributed_reports: unattributedReports, earlier_payback_request: null};
}
