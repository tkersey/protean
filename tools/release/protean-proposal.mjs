import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseVersion} from './version.mjs';
import {ProteanProposalClient} from './protean-proposal-github.mjs';
import {impactBlock, validateImpact} from './impact.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRecord} from './record.mjs';

export const proposalBranch = 'automation/dependency-release';
const zero = '0'.repeat(40);
const updateRefs = 'mutation UpdateProposal($input:UpdateRefsInput!){updateRefs(input:$input){clientMutationId}}';
const mergePull = 'mutation PromoteProposal($input:MergePullRequestInput!){mergePullRequest(input:$input){pullRequest{id}}}';
const disableMerge = 'mutation PauseProposal($input:DisablePullRequestAutoMergeInput!){disablePullRequestAutoMerge(input:$input){pullRequest{id}}}';
const timelineQuery = 'query ProposalHistory($number:Int!,$cursor:String){repository(owner:"tkersey",name:"protean"){databaseId pullRequest(number:$number){id headRefOid baseRefOid state autoMergeRequest{enabledBy{login} mergeMethod} timelineItems(first:100,after:$cursor,itemTypes:[AUTO_MERGE_DISABLED_EVENT,CLOSED_EVENT,REOPENED_EVENT,LABELED_EVENT,UNLABELED_EVENT,HEAD_REF_FORCE_PUSHED_EVENT]){nodes{__typename ... on AutoMergeDisabledEvent{id createdAt reasonCode actor{login}} ... on ClosedEvent{id createdAt actor{login}} ... on ReopenedEvent{id createdAt actor{login}} ... on LabeledEvent{id createdAt label{name} actor{login}} ... on UnlabeledEvent{id createdAt label{name} actor{login}} ... on HeadRefForcePushedEvent{id createdAt beforeCommit{oid} afterCommit{oid} actor{login}}} pageInfo{hasNextPage endCursor}}}}}';

function oid(value) { assert.match(value, /^[0-9a-f]{40}$/); return value; }
function objectId(type, bytes) { return createHash('sha1').update(`${type} ${bytes.length}\0`).update(bytes).digest('hex'); }
function identifier(value) { assert.ok(Number.isSafeInteger(value) && value > 0); return value; }

export const mechanicalPaths = Object.freeze(['build.zig.zon', 'conformance/protean/dependencies.lock.json']);
const maximumSourceBytes = 64 * 1024 * 1024;

function upstream(candidate) {
  identifier(candidate.kosmosReleaseId);
  assert.ok(Buffer.isBuffer(candidate.kosmosRecordBytes), 'original selected Kosmos release record required');
  const record = readRecord(candidate.kosmosRecordBytes);
  assert.equal(record.repository.name, 'tkersey/kosmos'); assert.equal(record.repository.id, 1251308461);
  assert.equal(record.dependencies.length, 1); assert.equal(record.dependencies[0].repository.name, 'tkersey/horos');
  assert.equal(Object.hasOwn(candidate, 'horos'), false, 'Horos must be derived from the selected Kosmos publication');
  return {record, recordSha256: sha256(candidate.kosmosRecordBytes), horos: record.dependencies[0]};
}

function nativeResult(candidate) {
  assert.ok(Buffer.isBuffer(candidate.nativeResultBytes) && candidate.nativeResultBytes.length <= 1024 * 1024,
    'original native generation result required');
  const result = parseEvidenceJson(candidate.nativeResultBytes), selected = upstream(candidate);
  assert.deepEqual(Object.keys(result).sort(), ['baseCommit', 'baseTree', 'horosRecordSha256', 'kosmosRecordSha256', 'lockSha256', 'schema', 'source', 'version']);
  assert.equal(result.schema, 'protean-refresh-result/v1');
  assert.equal(result.baseCommit, candidate.base); assert.equal(result.baseTree, candidate.baseTree);
  assert.equal(result.version, candidate.version); parseVersion(result.version);
  assert.equal(result.kosmosRecordSha256, selected.recordSha256, 'native selected Kosmos record differs');
  assert.equal(result.horosRecordSha256, selected.horos.release.recordSha256, 'native transitive Horos record differs');
  assert.equal(result.lockSha256, sha256(candidate.files.get('conformance/protean/dependencies.lock.json')), 'native generated lock differs');
  assert.deepEqual(Object.keys(result.source).sort(), ['bytes', 'entries', 'inventorySha256']);
  assert.match(result.source.inventorySha256, /^[0-9a-f]{64}$/);
  identifier(result.source.entries); identifier(result.source.bytes);
  assert.ok(result.source.entries <= 10000 && result.source.bytes <= maximumSourceBytes, 'native source inventory exceeds capacity');
  return result;
}

function fileDescriptors(candidate) {
  assert.ok(candidate.files instanceof Map, 'native output files required');
  assert.deepEqual([...candidate.files.keys()].sort(), mechanicalPaths, 'complete native mechanical projection required');
  let size = 0;
  return mechanicalPaths.map(path => {
    const bytes = candidate.files.get(path);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= maximumSourceBytes, 'invalid native file bytes');
    size += bytes.length; assert.ok(size <= maximumSourceBytes, 'native projection exceeds source capacity');
    return {path, sha256: sha256(bytes), bytes: bytes.length};
  });
}

export function nativeCandidateBinding(candidate) {
  const result = nativeResult(candidate);
  return {base: candidate.base, baseTree: candidate.baseTree, head: candidate.head, tree: candidate.tree,
    nativeResultSha256: sha256(candidate.nativeResultBytes), filesSha256: sha256(encodeRecord(fileDescriptors(candidate))),
    kosmosReleaseId: candidate.kosmosReleaseId, kosmosRecordSha256: result.kosmosRecordSha256,
    horosRecordSha256: result.horosRecordSha256, lockSha256: result.lockSha256,
    sourceInventorySha256: result.source.inventorySha256};
}

export function proposalMessage(candidate) {
  oid(candidate.base); oid(candidate.baseTree); parseVersion(candidate.version); fileDescriptors(candidate);
  const selected = upstream(candidate); nativeResult(candidate); validateImpact(candidate.impact);
  assert.equal(candidate.impact.disposition, 'compatible', 'breaking migrations require ordinary implementation work');
  return `Prepare Protean version ${candidate.version}\n\nrepository-proposal/v1\nbase: ${candidate.base}\nnative-result-sha256: ${sha256(candidate.nativeResultBytes)}\nfiles-sha256: ${sha256(encodeRecord(fileDescriptors(candidate)))}\nkosmos-release-id: ${candidate.kosmosReleaseId}\nkosmos-release-sha256: ${selected.recordSha256}\nhoros-release-sha256: ${selected.horos.release.recordSha256}\nimpact-sha256: ${sha256(encodeRecord(candidate.impact))}\n`;
}

function person(value) {
  assert.deepEqual(Object.keys(value).sort(), ['date', 'email', 'name']);
  for (const key of ['name', 'email']) assert.ok(typeof value[key] === 'string' && value[key].length > 0 && value[key].length <= 256 && !/[\x00-\x1f\x7f<>]/.test(value[key]));
  assert.match(value.date, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(new Date(value.date).toISOString(), value.date.replace('Z', '.000Z'));
  return `${value.name} <${value.email}> ${Date.parse(value.date) / 1000} +0000`;
}

export function proposalCommitOid(candidate) {
  oid(candidate.base); oid(candidate.tree);
  assert.equal(candidate.message, proposalMessage(candidate), 'unexpected proposal commit message');
  return objectId('commit', Buffer.from(`tree ${candidate.tree}\nparent ${candidate.base}\nauthor ${person(candidate.author)}\ncommitter ${person(candidate.committer)}\n\n${candidate.message}`));
}

function candidateCopy(value) {
  assert.deepEqual(Object.keys(value).sort(), ['author', 'base', 'baseTree', 'committer', 'files', 'head', 'impact',
    'kosmosRecordBytes', 'kosmosReleaseId', 'message', 'nativeResultBytes', 'tree', 'version'], 'unexpected native candidate fields');
  oid(value.head); fileDescriptors(value); nativeResult(value);
  const candidate = {...structuredClone(value), nativeResultBytes: Buffer.from(value.nativeResultBytes),
    kosmosRecordBytes: Buffer.from(value.kosmosRecordBytes),
    files: new Map([...value.files].map(([path, bytes]) => [path, Buffer.from(bytes)]))};
  assert.equal(proposalCommitOid(candidate), candidate.head, 'candidate commit identity mismatch');
  assert.notEqual(candidate.head, candidate.base, 'empty proposal commit');
  return candidate;
}

export function proposalDescription(candidate) {
  const descriptor = {...nativeCandidateBinding(candidate), version: candidate.version, impact: candidate.impact};
  const marker = `<!-- repository-proposal/v1 ${sha256(encodeRecord(descriptor))} -->`;
  const selected = upstream(candidate), kosmos = selected.record.source, horos = selected.horos.source;
  return {marker, body: `${marker}\n\nPrepare Protean ${candidate.version}.\n\nBase: \`${candidate.base}\`\nHead: \`${candidate.head}\`\n\nFrozen Kosmos publication: [release ${candidate.kosmosReleaseId}](https://api.github.com/repos/tkersey/kosmos/releases/${candidate.kosmosReleaseId}), commit \`${kosmos.commit}\`, tree \`${kosmos.tree}\`, package \`${kosmos.packageIdentity}\`, record SHA-256 \`${selected.recordSha256}\`.\n\nHoros derived from that publication: commit \`${horos.commit}\`, tree \`${horos.tree}\`, package \`${horos.packageIdentity}\`, record SHA-256 \`${selected.horos.release.recordSha256}\`.\n\nNative generated projection: ${mechanicalPaths.map(path => `\`${path}\``).join(', ')}.\n\n${impactBlock(candidate.impact)}\n\nAwaiting full qualification and owner review; publication is separately controlled.\n`};
}

export function describedProposalSubject(body) {
  assert.equal(typeof body, 'string');
  assert.match(body, /^<!-- repository-proposal\/v1 [0-9a-f]{64} -->\n/);
  const base = [...body.matchAll(/^Base: `([0-9a-f]{40})`$/gm)];
  const head = [...body.matchAll(/^Head: `([0-9a-f]{40})`$/gm)];
  assert.equal(base.length, 1, 'missing or ambiguous described proposal base');
  assert.equal(head.length, 1, 'missing or ambiguous described proposal head');
  return {base: base[0][1], head: head[0][1]};
}

export function proposalHoldEvents(events) {
  return events.filter(event => ['AutoMergeDisabledEvent', 'ClosedEvent', 'ReopenedEvent'].includes(event.__typename) ||
    (['LabeledEvent', 'UnlabeledEvent'].includes(event.__typename) && event.label?.name === 'automation-hold'));
}

async function get(client, path, missing = false, maximumBytes = 8 * 1024 * 1024) {
  const response = await client.request({path, maximumBytes});
  if (missing && response.status === 404) return null;
  assert.equal(response.status, 200, `GitHub observation unavailable: ${path}`);
  return response.body;
}

async function repository(client) {
  const value = await get(client, '');
  assert.equal(value.full_name, 'tkersey/protean'); assert.equal(value.id, 1328996555);
  assert.equal(value.default_branch, 'main');
  assert.ok(typeof value.node_id === 'string' && value.node_id.length > 0);
  return value;
}

async function mode(client) {
  const value = await get(client, '/actions/variables/REPOSITORY_AUTOMATION', true);
  if (value === null) return 'off';
  assert.equal(value.name, 'REPOSITORY_AUTOMATION');
  assert.ok(['off', 'propose', 'promote'].includes(value.value));
  return value.value;
}

async function reference(client, branch, missing = false) {
  const value = await get(client, `/git/ref/heads/${branch}`, missing);
  if (value === null) return null;
  assert.equal(value.ref, `refs/heads/${branch}`); assert.equal(value.object.type, 'commit');
  return oid(value.object.sha);
}

async function allPages(client, path) {
  const values = [];
  for (let page = 1; page <= 100; page++) {
    const part = await get(client, `${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    assert.ok(Array.isArray(part) && part.length <= 100);
    values.push(...part);
    if (part.length < 100) return values;
  }
  throw new Error('proposal observation capacity exceeded');
}

async function pulls(client) {
  const items = await allPages(client, `/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}`);
  const seen = new Set();
  for (const value of items) {
    identifier(value.number); assert.ok(!seen.has(value.number), 'pull pagination changed'); seen.add(value.number);
    assert.equal(value.head.ref, proposalBranch); assert.equal(value.head.repo?.id, 1328996555);
    assert.equal(value.base.ref, 'main'); assert.equal(value.base.repo?.id, 1328996555);
  }
  assert.ok(items.filter(value => value.state === 'open').length <= 1, 'multiple automation branch proposals');
  return items.sort((a, b) => b.number - a.number);
}

function owned(pull, actor) {
  assert.equal(pull.user?.id, actor.id, 'proposal is not automation-owned');
  assert.equal(pull.user?.login, actor.login, 'proposal actor changed');
  assert.ok(typeof pull.body === 'string' && /^<!-- repository-proposal\/v1 [0-9a-f]{64} -->\n/.test(pull.body), 'missing proposal provenance');
}

async function history(client, pull) {
  const events = [], cursors = new Set();
  let cursor = null;
  for (let page = 0; page < 100; page++) {
    const data = await client.graphql(timelineQuery, {number: pull.number, cursor});
    assert.equal(data.repository?.databaseId, 1328996555);
    const value = data.repository.pullRequest;
    assert.equal(value.id, pull.node_id); assert.equal(value.headRefOid, pull.head.sha);
    assert.equal(value.baseRefOid, pull.base.sha);
    assert.equal(value.state.toLowerCase(), pull.merged === true ? 'merged' : pull.state);
    const connection = value.timelineItems;
    assert.ok(Array.isArray(connection.nodes) && connection.nodes.length <= 100);
    events.push(...connection.nodes);
    if (connection.pageInfo.hasNextPage === false) return {events, autoMerge: value.autoMergeRequest};
    assert.equal(connection.pageInfo.hasNextPage, true);
    cursor = connection.pageInfo.endCursor;
    assert.ok(typeof cursor === 'string' && cursor.length > 0 && !cursors.has(cursor), 'invalid proposal history cursor');
    cursors.add(cursor);
  }
  throw new Error('proposal history capacity exceeded');
}

async function guard(client, candidate, branchBefore, allowed = ['propose', 'promote'], expectedBase = candidate.base) {
  const repo = await repository(client);
  assert.equal(await reference(client, 'main'), expectedBase, 'stale proposal base');
  assert.equal(await reference(client, proposalBranch, true), branchBefore, 'automation branch changed');
  assert.ok(allowed.includes(await mode(client)), 'proposal mutation disabled');
  return repo;
}

async function writeObserved(write, observe) {
  let failure;
  try { await write(); } catch (error) { failure = error; }
  try { return await observe(); }
  catch (error) { throw new Error('proposal write not confirmed; reobserve before retry', {cause: failure ?? error}); }
}

async function restWrite(client, request) {
  const response = await client.request(request);
  assert.ok([200, 201].includes(response.status), 'proposal GitHub write rejected');
}

function rootTree(entries) {
  assert.ok(Array.isArray(entries) && entries.length > 0 && entries.length <= 10000);
  const names = new Set();
  const values = entries.map(entry => {
    assert.ok(typeof entry.path === 'string' && entry.path.length > 0 && entry.path.isWellFormed() && !/[\0/]/.test(entry.path));
    assert.ok(!names.has(entry.path), 'duplicate Git tree path'); names.add(entry.path); oid(entry.sha);
    assert.ok(({blob: ['100644', '100755', '120000'], tree: ['040000'], commit: ['160000']})[entry.type]?.includes(entry.mode), 'invalid Git tree mode');
    return {entry, sort: Buffer.from(`${entry.path}${entry.type === 'tree' ? '/' : ''}`)};
  }).sort((a, b) => Buffer.compare(a.sort, b.sort));
  return objectId('tree', Buffer.concat(values.flatMap(({entry}) => [Buffer.from(`${entry.mode === '040000' ? '40000' : entry.mode} ${entry.path}\0`), Buffer.from(entry.sha, 'hex')])));
}

async function treeObject(client, sha) {
  const value = await get(client, `/git/trees/${oid(sha)}`);
  assert.equal(value.sha, sha); assert.equal(value.truncated, false, 'truncated source tree');
  assert.equal(rootTree(value.tree), sha, 'base Git tree identity mismatch');
  return value.tree;
}

async function sourceProjection(client, root) {
  const trees = new Map([['', {sha: root, entries: await treeObject(client, root)}]]);
  for (const path of ['conformance', 'conformance/protean']) {
    const slash = path.lastIndexOf('/'), parent = slash < 0 ? '' : path.slice(0, slash), name = path.slice(slash + 1);
    const entry = trees.get(parent).entries.find(value => value.path === name);
    assert.ok(entry && entry.type === 'tree' && entry.mode === '040000', 'native source directory missing');
    trees.set(path, {sha: entry.sha, entries: await treeObject(client, entry.sha)});
  }
  const files = new Map(), blobs = new Map();
  let total = 0;
  for (const path of mechanicalPaths) {
    const slash = path.lastIndexOf('/'), parent = slash < 0 ? '' : path.slice(0, slash), name = path.slice(slash + 1);
    const entry = trees.get(parent).entries.find(value => value.path === name);
    assert.ok(entry && entry.type === 'blob' && ['100644', '100755'].includes(entry.mode),
      'native mechanical source must be a regular file');
    let bytes = blobs.get(entry.sha);
    if (bytes === undefined) {
      const blob = await get(client, `/git/blobs/${entry.sha}`, false, 96 * 1024 * 1024);
      assert.equal(blob.sha, entry.sha); assert.equal(blob.encoding, 'base64');
      assert.ok(typeof blob.content === 'string' && blob.content.length <= 92 * 1024 * 1024);
      bytes = Buffer.from(blob.content.replaceAll('\n', ''), 'base64');
      assert.equal(bytes.length, blob.size); assert.equal(objectId('blob', bytes), entry.sha, 'source Git blob identity mismatch');
      blobs.set(entry.sha, bytes);
    }
    total += bytes.length; assert.ok(total <= maximumSourceBytes, 'source projection exceeds capacity');
    files.set(path, Buffer.from(bytes));
  }
  return {trees, files};
}

async function candidatePlan(client, candidate) {
  const base = await get(client, `/git/commits/${candidate.base}`);
  assert.equal(base.sha, candidate.base); assert.equal(base.tree.sha, candidate.baseTree, 'native generation base tree differs');
  const original = await sourceProjection(client, base.tree.sha);
  const changed = mechanicalPaths.filter(path => !original.files.get(path).equals(candidate.files.get(path)));
  assert.ok(changed.length > 0, 'proposal requires a nonempty native generation delta');
  const trees = new Map(), blobs = new Map();
  for (const path of changed) blobs.set(path, objectId('blob', candidate.files.get(path)));
  for (const prefix of ['conformance/protean', 'conformance', '']) {
    const before = original.trees.get(prefix);
    const entries = before.entries.map(entry => {
      const path = prefix === '' ? entry.path : `${prefix}/${entry.path}`;
      return blobs.has(path) ? {...entry, sha: blobs.get(path)} : trees.has(path) ? {...entry, sha: trees.get(path).sha} : {...entry};
    });
    const sha = rootTree(entries);
    trees.set(prefix, {sha, previous: before.sha, entries});
  }
  assert.equal(trees.get('').sha, candidate.tree, 'candidate changes outside exact native projection');
  return {original, changed, trees, blobs};
}

async function candidateObjects(client, candidate, branchBefore, admitCandidate) {
  const plan = await candidatePlan(client, candidate);
  const binding = await admitCandidate({candidate: candidateCopy(candidate),
    baseFiles: new Map([...plan.original.files].map(([path, bytes]) => [path, Buffer.from(bytes)])),
    baseTree: candidate.baseTree, changed: [...plan.changed]});
  assert.deepEqual(binding, nativeCandidateBinding(candidate), 'authenticated native generation binding required');
  const create = async (path, expected, body, validate) => {
    let object = await get(client, `${path}/${expected}`, true, 96 * 1024 * 1024);
    if (object === null) {
      await guard(client, candidate, branchBefore);
      object = await writeObserved(() => restWrite(client, {method: 'POST', path, body}), async () => {
        const value = await get(client, `${path}/${expected}`, false, 96 * 1024 * 1024);
        assert.equal(value.sha, expected); return value;
      });
    }
    assert.equal(object.sha, expected); validate(object);
  };
  for (const [path, sha] of plan.blobs) {
    const bytes = candidate.files.get(path);
    await create('/git/blobs', sha, {content: bytes.toString('base64'), encoding: 'base64'}, value => {
      assert.equal(value.encoding, 'base64');
      const actual = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
      assert.equal(actual.length, value.size); assert.equal(objectId('blob', actual), sha);
    });
  }
  for (const {sha, previous, entries} of plan.trees.values()) {
    if (sha === previous) continue;
    await create('/git/trees', sha, {tree: entries.map(({path, mode, type, sha}) => ({path, mode, type, sha}))}, value => {
      assert.equal(value.truncated, false); assert.equal(rootTree(value.tree), sha);
    });
  }
  await create('/git/commits', candidate.head, {tree: candidate.tree, parents: [candidate.base], message: candidate.message,
    author: candidate.author, committer: candidate.committer}, value => {
    assert.equal(value.tree.sha, candidate.tree); assert.deepEqual(value.parents.map(parent => parent.sha), [candidate.base]);
    assert.equal(value.message, candidate.message);
    assert.equal(proposalCommitOid({...candidate, author: value.author, committer: value.committer}), candidate.head);
  });
}

async function storedCandidate(client, candidate) {
  const value = await get(client, `/git/commits/${candidate.head}`);
  assert.equal(value.sha, candidate.head); assert.equal(value.tree.sha, candidate.tree);
  assert.deepEqual(value.parents.map(parent => parent.sha), [candidate.base]);
  assert.equal(value.message, candidate.message);
  assert.equal(proposalCommitOid({...candidate, author: value.author, committer: value.committer}), candidate.head);
  await candidatePlan(client, candidate);
  const projection = await sourceProjection(client, candidate.tree);
  for (const [path, bytes] of projection.files)
    assert.deepEqual(bytes, candidate.files.get(path), 'retired native projection differs from original Git source');
}

async function successorProposal({client, candidate, actor, pull, timeline, branchBefore, currentBase, admitCandidate, admitRetirement, admitResume}) {
  if (branchBefore !== pull.head.sha) return held('unknown human branch edit prevents successor preparation', pull);
  if (timeline.autoMerge !== null) return held('previous auto-merge request must be cancelled before successor preparation', pull);
  if (typeof admitRetirement !== 'function') return held('original owner epoch closure is required before successor preparation', pull);
  const previousSubject = describedProposalSubject(pull.body);
  const retirement = await admitRetirement({pull: structuredClone(pull), knownHead: branchBefore, previousSubject,
    events: structuredClone(timeline.events), candidate: candidateCopy(candidate)});
  if (retirement?.epochClosed !== true || retirement.previousCandidate === undefined) {
    return held('authenticated original candidate and closed epoch are required before successor preparation', pull);
  }
  const previous = candidateCopy(retirement.previousCandidate), previousDescription = proposalDescription(previous);
  if (![previous.head, candidate.head].includes(branchBefore)) return held('unknown human branch edit prevents successor preparation', pull);
  if (pull.draft || pull.body !== previousDescription.body || pull.title !== `Prepare Protean ${previous.version}`) {
    return held('human proposal metadata edits prevent automatic successor replacement', pull);
  }
  assert.notEqual(previous.head, candidate.head, 'successor must name a distinct admitted candidate');
  assert.equal(previous.base, previousSubject.base); assert.equal(previous.head, previousSubject.head);
  await storedCandidate(client, previous);
  const recovering = branchBefore === candidate.head;
  if (recovering) {
    await storedCandidate(client, candidate);
    await candidateObjects(client, candidate, branchBefore, value => admitCandidate({...value, recovering: true}));
  } else {
    assert.equal(candidate.base, currentBase, 'stale successor candidate');
    await candidateObjects(client, candidate, branchBefore, admitCandidate);
  }
  const observe = async expectedHead => {
    await guard(client, candidate, expectedHead, ['propose', 'promote'], currentBase);
    const current = await get(client, `/pulls/${pull.number}`);
    owned(current, actor);
    assert.equal(current.state, 'open'); assert.equal(current.head.sha, expectedHead);
    assert.equal(current.base.sha, currentBase); assert.equal(current.draft, false);
    assert.equal(current.body, pull.body, 'proposal body changed during successor preparation');
    assert.equal(current.title, pull.title, 'proposal title changed during successor preparation');
    assert.deepEqual(current.labels, pull.labels, 'proposal labels changed during successor preparation');
    const latest = await history(client, current);
    const transitions = latest.events.filter(event => !timeline.events.some(previous => previous.id === event.id) &&
      event.__typename === 'HeadRefForcePushedEvent' && event.beforeCommit?.oid === previous.head &&
      event.afterCommit?.oid === candidate.head && event.actor?.login === actor.login && expectedHead === candidate.head);
    assert.ok(transitions.length <= 1, 'ambiguous successor branch transition');
    assert.deepEqual({...latest, events: latest.events.filter(event => !transitions.includes(event))}, timeline,
      'proposal history changed during successor preparation');
    if (proposalHoldEvents(latest.events).length > 0) await admitResume({pull: current, events: latest.events, resumeHead: previous.head, candidate: candidateCopy(candidate)});
    return current;
  };
  await observe(branchBefore);
  if (branchBefore !== candidate.head) {
    const repo = await repository(client);
    await writeObserved(() => client.graphql(updateRefs, {input: {repositoryId: repo.node_id,
      refUpdates: [{name: `refs/heads/${proposalBranch}`, beforeOid: previous.head, afterOid: candidate.head, force: true}]} }), async () => {
      assert.equal(await reference(client, proposalBranch), candidate.head, 'successor branch update not observed');
    });
  }
  await observe(candidate.head);
  const description = proposalDescription(candidate);
  const updated = await writeObserved(() => restWrite(client, {method: 'PATCH', path: `/pulls/${pull.number}`,
    body: {title: `Prepare Protean ${candidate.version}`, body: description.body}}), async () => {
    const current = await get(client, `/pulls/${pull.number}`);
    owned(current, actor); assert.equal(current.state, 'open'); assert.equal(current.head.sha, candidate.head);
    assert.equal(current.body, description.body); assert.equal(current.title, `Prepare Protean ${candidate.version}`);
    return current;
  });
  if (!updated.assignees.some(value => value.login === 'tkersey')) {
    await guard(client, candidate, candidate.head, ['propose', 'promote'], currentBase);
    await writeObserved(() => restWrite(client, {method: 'POST', path: `/issues/${pull.number}/assignees`, body: {assignees: ['tkersey']}}), async () => {
      const assigned = await get(client, `/pulls/${pull.number}`);
      assert.ok(assigned.assignees.some(value => value.login === 'tkersey'));
    });
  }
  return {status: 'proposal open', number: pull.number, head: candidate.head, previousHead: previous.head};
}

function held(reason, pull) { return {status: 'held', reason, ...(pull ? {number: pull.number} : {})}; }

export async function pauseProteanProposals({actor, client = new ProteanProposalClient()}) {
  await repository(client); identifier(actor.id);
  const results = [];
  const requiresPause = (pull, selectedMode) => selectedMode !== 'promote' || pull.draft ||
    pull.labels.some(label => label.name === 'automation-hold');
  for (const value of (await pulls(client)).filter(pull => pull.state === 'open')) {
    const pull = await get(client, `/pulls/${value.number}`);
    assert.equal(pull.user?.id, actor.id); assert.equal(pull.user?.login, actor.login);
    if (!requiresPause(pull, await mode(client))) continue;
    const current = await history(client, pull);
    if (current.autoMerge === null) continue;
    assert.equal(current.autoMerge.enabledBy?.login, actor.login, 'cannot cancel unknown auto-merge owner');
    const latest = await get(client, `/pulls/${pull.number}`);
    assert.equal(latest.user?.id, actor.id); assert.equal(latest.user?.login, actor.login);
    if (latest.state !== 'open' || !requiresPause(latest, await mode(client))) continue;
    const latestHistory = await history(client, latest);
    if (latestHistory.autoMerge === null) continue;
    assert.equal(latestHistory.autoMerge.enabledBy?.login, actor.login, 'cannot cancel unknown auto-merge owner');
    const deciding = await get(client, `/pulls/${pull.number}`);
    assert.equal(deciding.user?.id, actor.id); assert.equal(deciding.user?.login, actor.login);
    if (deciding.state !== 'open' || !requiresPause(deciding, await mode(client))) continue;
    assert.equal(deciding.node_id, latest.node_id);
    await writeObserved(() => client.graphql(disableMerge, {input: {pullRequestId: deciding.node_id}}), async () => {
      const observed = await get(client, `/pulls/${pull.number}`);
      assert.equal((await history(client, observed)).autoMerge, null, 'auto-merge cancellation not observed');
    });
    results.push(held('automation-owned auto-merge disabled by current controls or owner hold', pull));
  }
  return results;
}

export async function recoverProposalMetadata({pull, actor, readCandidate, admitRetirement, admitResume, client}) {
  if (pull === null || describedProposalSubject(pull.body).head === pull.head.sha) return null;
  const candidate = await readCandidate(pull.head.sha);
  assert.equal(candidate.head, pull.head.sha);
  const result = await proposeProtean({candidate, actor, client, admitRetirement, admitResume,
    admitCandidate: async ({candidate: proposed, recovering}) => {
      assert.equal(recovering, true, 'metadata recovery cannot authorize a source transition');
      const original = await readCandidate(pull.head.sha);
      assert.deepEqual(candidateCopy(proposed), candidateCopy(original), 'original prepared candidate changed');
      return nativeCandidateBinding(original);
    },
  });
  return {candidate, result};
}

export async function proposeProtean({candidate: input, actor, admitCandidate, admitRetirement, admitResume,
  client = new ProteanProposalClient()}) {
  const candidate = candidateCopy(input), description = proposalDescription(candidate);
  identifier(actor.id); assert.ok(typeof actor.login === 'string' && actor.login.length > 0);
  assert.equal(typeof admitCandidate, 'function', 'native semantic admission required');
  await repository(client);
  const observedMode = await mode(client);
  if (observedMode === 'off') return {status: 'disabled'};
  const currentBase = await reference(client, 'main');
  const branchBefore = await reference(client, proposalBranch, true);
  const existing = await pulls(client);
  let pull = existing.find(value => value.state === 'open') ?? existing[0];
  if (pull) {
    pull = await get(client, `/pulls/${pull.number}`);
    owned(pull, actor);
    const timeline = await history(client, pull);
    const holdEvents = pull.merged ? [] : proposalHoldEvents(timeline.events);
    if (pull.labels.some(label => label.name === 'automation-hold') || (pull.state === 'closed' && !pull.merged) || holdEvents.length > 0) {
      if (typeof admitResume !== 'function') return held('manual closure, hold, or disabled auto-merge requires explicit owner resume', pull);
      await admitResume({pull: structuredClone(pull), events: structuredClone(timeline.events),
        resumeHead: describedProposalSubject(pull.body).head, candidate: candidateCopy(candidate)});
      if (pull.state === 'closed' && !pull.merged) return held('owner must reopen or retire the manually closed proposal before regeneration', pull);
    }
    if (pull.state === 'open') {
      const recovering = branchBefore === candidate.head && pull.head.sha === candidate.head &&
        describedProposalSubject(pull.body).head !== candidate.head;
      if (currentBase !== candidate.base && !recovering) return held('stale base; owner must close the previous epoch before regeneration', pull);
      if (pull.head.sha !== candidate.head || branchBefore !== candidate.head || !pull.body.startsWith(`${description.marker}\n`)) {
        return successorProposal({client, candidate, actor, pull, timeline, branchBefore, currentBase, admitCandidate, admitRetirement, admitResume});
      }
      assert.ok(pull.body.startsWith(`${description.marker}\n`), 'proposal binding changed');
      if (pull.base.sha !== candidate.base) return held('proposal base changed', pull);
      await candidateObjects(client, candidate, branchBefore, admitCandidate);
      if (!pull.assignees.some(value => value.login === 'tkersey')) {
        await guard(client, candidate, branchBefore);
        const current = await get(client, `/pulls/${pull.number}`);
        owned(current, actor); assert.equal(current.state, 'open'); assert.equal(current.head.sha, candidate.head);
        assert.equal(current.body, pull.body); assert.equal(current.title, pull.title); assert.equal(current.draft, pull.draft);
        assert.deepEqual(current.labels, pull.labels, 'proposal labels changed before assignment');
        const latest = await history(client, current);
        assert.deepEqual(latest, timeline, 'proposal history changed before assignment');
        if (holdEvents.length > 0) await admitResume({pull: current, events: latest.events, candidate: candidateCopy(candidate)});
        await writeObserved(() => restWrite(client, {method: 'POST', path: `/issues/${pull.number}/assignees`, body: {assignees: ['tkersey']}}), async () => {
          const assigned = await get(client, `/pulls/${pull.number}`);
          assert.ok(assigned.assignees.some(value => value.login === 'tkersey'));
        });
      }
      return {status: 'proposal open', number: pull.number, head: candidate.head};
    }
    if (pull.merged && pull.head.sha === candidate.head) return {status: 'landed—qualification pending', number: pull.number, head: candidate.head};
  }
  if (currentBase !== candidate.base) return held('stale base; owner must close the previous epoch before regeneration', pull);
  let reset = false;
  if (branchBefore !== null && branchBefore !== candidate.head) {
    if (!pull?.merged || pull.head.sha !== branchBefore) return held('unknown human branch edit; refusing branch replacement', pull);
    assert.equal(typeof admitRetirement, 'function', 'prior merged proposal epoch retirement required');
    await admitRetirement({pull: structuredClone(pull), knownHead: branchBefore, candidate: candidateCopy(candidate)});
    reset = true;
  }
  await candidateObjects(client, candidate, branchBefore, admitCandidate);
  if (branchBefore !== candidate.head) {
    const repo = await guard(client, candidate, branchBefore);
    assert.equal((await pulls(client)).filter(value => value.state === 'open').length, 0, 'proposal opened during preparation');
    await writeObserved(() => client.graphql(updateRefs, {input: {repositoryId: repo.node_id,
      refUpdates: [{name: `refs/heads/${proposalBranch}`, beforeOid: branchBefore ?? zero, afterOid: candidate.head, force: reset}]} }), async () => {
      assert.equal(await reference(client, proposalBranch), candidate.head, 'branch update not observed');
    });
  }
  await guard(client, candidate, candidate.head);
  assert.equal((await pulls(client)).filter(value => value.state === 'open').length, 0, 'proposal opened during preparation');
  pull = await writeObserved(() => restWrite(client, {method: 'POST', path: '/pulls', body: {
    title: `Prepare Protean ${candidate.version}`, head: proposalBranch, base: 'main', body: description.body,
    draft: false, maintainer_can_modify: false,
  }}), async () => {
    const found = (await pulls(client)).filter(value => value.state === 'open');
    assert.equal(found.length, 1, 'proposal creation not observed');
    const value = await get(client, `/pulls/${found[0].number}`);
    owned(value, actor); assert.equal(value.head.sha, candidate.head);
    assert.ok(value.body.startsWith(`${description.marker}\n`)); return value;
  });
  await guard(client, candidate, candidate.head);
  await writeObserved(() => restWrite(client, {method: 'POST', path: `/issues/${pull.number}/assignees`, body: {assignees: ['tkersey']}}), async () => {
    const value = await get(client, `/pulls/${pull.number}`);
    assert.ok(value.assignees.some(assignee => assignee.login === 'tkersey'));
  });
  return {status: 'proposal open', number: pull.number, head: candidate.head};
}

async function observedLanding(client, pull, candidate) {
  assert.equal(pull.head.ref, proposalBranch); assert.equal(pull.head.repo?.id, 1328996555);
  assert.equal(pull.base.ref, 'main'); assert.equal(pull.base.repo?.id, 1328996555);
  assert.equal(pull.head.sha, candidate.head); assert.equal(pull.merged, true);
  assert.equal(pull.state, 'closed'); assert.ok(Number.isFinite(Date.parse(pull.merged_at)));
  const commit = await get(client, `/git/commits/${oid(pull.merge_commit_sha)}`);
  assert.equal(commit.sha, pull.merge_commit_sha); assert.equal(commit.tree.sha, candidate.tree);
  assert.deepEqual(commit.parents.map(parent => parent.sha), [candidate.base], 'landing base differs from admitted source');
}

export async function promoteProtean({candidate: input, number, actor, admitPromotion, admitResume, client = new ProteanProposalClient()}) {
  const candidate = candidateCopy(input);
  identifier(number); identifier(actor.id);
  assert.equal(typeof admitPromotion, 'function', 'trusted promotion admission required');
  await repository(client);
  let pull = await get(client, `/pulls/${number}`);
  owned(pull, actor);
  assert.equal(pull.head.ref, proposalBranch); assert.equal(pull.head.repo?.id, 1328996555);
  assert.equal(pull.base.ref, 'main'); assert.equal(pull.base.repo?.id, 1328996555);
  if (pull.merged === true) {
    await observedLanding(client, pull, candidate);
    return {status: 'landed—qualification pending', number, head: candidate.head};
  }
  const timeline = await history(client, pull);
  const selectedMode = await mode(client);
  if (selectedMode !== 'promote') {
    if (timeline.autoMerge !== null && pull.state === 'open') {
      assert.equal(timeline.autoMerge.enabledBy?.login, actor.login, 'cannot cancel unknown auto-merge owner');
      assert.notEqual(await mode(client), 'promote', 'promotion control changed; reobserve');
      await writeObserved(() => client.graphql(disableMerge, {input: {pullRequestId: pull.node_id}}), async () => {
        const current = await get(client, `/pulls/${number}`);
        assert.equal((await history(client, current)).autoMerge, null, 'auto-merge cancellation not observed');
      });
      return {status: 'held', reason: 'automation-owned auto-merge disabled by current controls', number};
    }
    return {status: 'disabled', number};
  }
  if (pull.state !== 'open' || pull.draft || pull.labels.some(label => label.name === 'automation-hold')) return held('proposal is closed, draft, or explicitly held', pull);
  assert.ok(pull.assignees.some(value => value.login === 'tkersey'), 'proposal assignee missing');
  if (pull.head.sha !== candidate.head || pull.base.sha !== candidate.base || await reference(client, 'main') !== candidate.base ||
    await reference(client, proposalBranch) !== candidate.head) return held('stale base or human head edit prevents promotion', pull);
  assert.ok(pull.body.startsWith(`${proposalDescription(candidate).marker}\n`), 'proposal binding changed');
  const holds = proposalHoldEvents(timeline.events);
  if (holds.length > 0) {
    if (typeof admitResume !== 'function') return held('historical hold requires explicit owner resume', pull);
    await admitResume({pull: structuredClone(pull), events: structuredClone(timeline.events), candidate: candidateCopy(candidate)});
  }
  const branch = await get(client, '/branches/main');
  assert.equal(branch.protected, true, 'main is not protected');
  assert.equal(branch.commit.sha, candidate.base, 'protected branch advanced');
  const protection = await get(client, '/branches/main/protection', true);
  const rules = await allPages(client, '/rules/branches/main');
  assert.ok(protection !== null || rules.length > 0, 'effective protection unavailable');
  const repo = await repository(client);
  assert.equal(repo.allow_auto_merge, true, 'repository auto-merge unavailable');
  assert.equal(repo.allow_rebase_merge, true, 'protected rebase merge unavailable');
  const admittedBody = pull.body;
  await admitPromotion({candidate: candidateCopy(candidate), pull: structuredClone(pull),
    protection: structuredClone(protection), rules: structuredClone(rules), history: structuredClone(timeline.events), repository: structuredClone(repo)});
  await guard(client, candidate, candidate.head, ['promote']);
  pull = await get(client, `/pulls/${number}`);
  assert.equal(pull.state, 'open'); assert.equal(pull.head.sha, candidate.head); assert.equal(pull.base.sha, candidate.base);
  owned(pull, actor);
  assert.equal(pull.draft, false);
  assert.ok(pull.assignees.some(value => value.login === 'tkersey'), 'proposal assignee changed during admission');
  assert.ok(!pull.labels.some(label => label.name === 'automation-hold'), 'proposal held during admission');
  assert.equal(pull.body, admittedBody, 'reviewed proposal body changed during admission');
  assert.ok(pull.body.startsWith(`${proposalDescription(candidate).marker}\n`), 'proposal binding changed during admission');
  const current = await history(client, pull);
  assert.deepEqual(current.events, timeline.events, 'proposal history changed during admission');
  if (holds.length > 0) await admitResume({pull: structuredClone(pull), events: structuredClone(current.events), candidate: candidateCopy(candidate)});
  if (current.autoMerge !== null) {
    assert.equal(current.autoMerge.enabledBy?.login, actor.login, 'unknown auto-merge owner');
    assert.equal(current.autoMerge.mergeMethod, 'REBASE');
    return {status: 'promotion pending', number, head: candidate.head};
  }
  assert.equal(await mode(client), 'promote', 'promotion disabled');
  await writeObserved(() => client.graphql(mergePull, {input: {pullRequestId: pull.node_id, expectedHeadOid: candidate.head, mergeMethod: 'REBASE'}}), async () => {
    await observedLanding(client, await get(client, `/pulls/${number}`), candidate);
  });
  return {status: 'landed—qualification pending', number, head: candidate.head};
}
