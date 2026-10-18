// Prescribed choices exercise the actual model/workspace boundary. They make
// no claim that a live model discovers the strategy or chooses it well.
import assert from 'node:assert/strict';
const call = (name, tag, value) => [name, {command: {tag, value}}];
const observed = reply => {
  assert(['observed', 'admitted'].includes(reply.disposition), JSON.stringify(reply));
  return reply.observation;
};

export function* runtimeTrace(subject, scenario) {
  assert(subject.offered.has('program') && subject.offered.has('work') && subject.offered.has('context'));
  if (scenario === 'tools-runtime-ordinary') {
    yield ['read', {path: 'src/main.zig', start: 0, maximum: 4096}];
    yield ['stop', {reason: 'The ordinary source read answered this small investigation; no runtime construction was needed.'}];
    return;
  }
  yield ['skill_set', {operation: 'load', skill_id: 'tool-construction', version: '1', residency: 'resident', expected_revision: 0, reason: 'Exercise optional runtime selection and inspection.'}];
  if (['tools-runtime-mobility', 'tools-runtime-guest-mobility'].includes(scenario)) {
    yield* mobilityTrace(subject, scenario === 'tools-runtime-guest-mobility');
    return;
  }
  const built = observed(yield call('program', 'build', {source: {tag: 'json_text', value: JSON.stringify(subject.recipe)}, source_kind: 'component_recipe', exposures: []}));
  subject.program = built.program;
  if (scenario === 'tools-runtime-placement') {
    yield* placementTrace(subject);
    return;
  }
  if (scenario === 'tools-runtime-specialized') {
    const runtime = observed(yield call('program', 'specialize', {program: subject.program, hooks: {control: false, storage: false}}));
    assert.equal(runtime.runtime.kind, 'runtime');
    assert.equal(runtime.approval, 'exact-source-and-independent-derivation');
    subject.runtime = runtime.runtime;
    subject.results = [];
    for (const index of [0, 1, 0]) {
      const input = observed(yield call('context', 'materialize', {input: {tag: 'authorized_input', value: subject.inputs[index].id}, sources: []})).value;
      let work = observed(yield call('work', 'start', {program: subject.program, input: {tag: 'reference', value: input}, policy: {stop: 'terminal', continuation: 'owner_scheduled'}, runtime: {tag: 'selected', value: subject.runtime}}));
      if (work.outcome !== 'completed') {
        observed(yield call('work', 'wait', {works: [work.work], after: Number.MAX_SAFE_INTEGER}));
        work = observed(yield call('work', 'inspect', {work: work.work}));
      }
      assert.equal(work.outcome, 'completed');
      assert.deepEqual(work.runtime, subject.runtime);
      const rows = JSON.parse(work.result_preview.text);
      assert.deepEqual(rows[0].map(row => [row[0], row[7]]), index === 0 ? [['1','1'],['2','2'],['3','3'],['4','4']] : [['80','1']]);
      subject.results.push(work.result);
    }
    yield ['stop', {reason: 'One admitted specialization served three runs with changing inputs; the results remain acquired evidence.'}];
    return;
  }
  assert.equal(scenario, 'tools-runtime-reframe');
  const sites = observed(yield call('placement', 'sites', {}));
  assert.deepEqual(sites.sites, [], 'an optional empty placement directory does not restrict the investigation');
  const input = observed(yield call('context', 'materialize', {input: {tag: 'authorized_input', value: subject.inputs[0].id}, sources: []})).value;
  const work = observed(yield call('work', 'start', {program: subject.program, input: {tag: 'reference', value: input}, policy: {stop: 'next_slice', continuation: 'explicit_only'}, runtime: {tag: 'packaged', value: {}}}));
  const view = observed(yield call('context', 'materialize', {input: {tag: 'guest_view', value: {
    expected: {work: work.work, execution_revision: work.execution_revision, control_revision: work.control_revision},
    realization_revision: work.realization_revision, nodes: {tag: 'all', value: {}},
  }}, sources: []}));
  subject.view = view.value;
  assert.equal(subject.view.kind, 'value');
  observed(yield call('context', 'select', {values: [subject.view]}));
  assert(subject.offered.has('read') && subject.offered.has('stop') && subject.offered.has('context'));
  yield ['read', {path: 'src/main.zig', start: 0, maximum: 4096}];
  yield ['stop', {reason: 'The runtime structure view does not establish the source claim. The investigation switched to source evidence without continuing the experiment.'}];
}

function* remoteControl(operation, command) {
  for (let attempt = 0; attempt < 32; attempt++) {
    const observation = observed(yield call('placement', 'control', {operation, command}));
    if (observation.remote_reply) {
      assert.equal(observation.remote_reply.disposition, 'observed', JSON.stringify(observation));
      return JSON.parse(observation.remote_reply.observation_json);
    }
    assert.equal(observation.status, 'queued');
    assert.equal(observation.last_error, null, JSON.stringify(observation));
  }
  assert.fail('fixture remote control did not receive its signed report');
}

function* placementTrace(subject) {
  const runtime = observed(yield call('program', 'specialize', {program: subject.program, hooks: {control: false, storage: false}}));
  subject.runtime = runtime.runtime;
  const input = observed(yield call('context', 'materialize', {input: {tag: 'authorized_input', value: subject.inputs[0].id}, sources: []})).value;
  let work = observed(yield call('work', 'start', {program: subject.program, input: {tag: 'reference', value: input},
    policy: {stop: 'next_slice', continuation: 'explicit_only'}, runtime: {tag: 'selected', value: subject.runtime}}));
  const expected = value => ({work: value.work, execution_revision: value.execution_revision, control_revision: value.control_revision});
  const originalRevision = work.execution_revision;
  work = observed(yield call('work', 'pump', {expected: expected(work), base_quantum: 1}));
  assert(work.outer_operation, 'movement must carry actual specialized outer microprogress');
  assert.equal(work.execution_revision, originalRevision, 'a base step is not a guest publication');
  subject.outer = work.outer_operation;
  subject.movedWork = work.work;
  const selected = {tag: 'work', value: work.work};
  const sites = observed(yield call('placement', 'sites', {}));
  assert.deepEqual(sites.sites.map(site => site.name), ['executor', 'successor']);
  const assessment = observed(yield call('placement', 'assess', {subject: selected, site: 'executor'}));
  assert.equal(assessment.compatible, true);
  assert.deepEqual(assessment.cut.outer, subject.outer);
  observed(yield call('placement', 'move', {operation: 'move-specialized-work', subject: selected, site: 'executor', custody_epoch: 0}));
  let moved = false;
  for (let attempt = 0; attempt < 32; attempt++) {
    const placement = observed(yield call('placement', 'inspect', selected));
    if (placement.custody?.phase === 'away') { moved = true; break; }
    assert(!placement.custody?.decision || placement.custody.decision.value.verdict.tag === 'accepted', JSON.stringify(placement));
  }
  assert(moved, 'fixture work transfer did not settle');
  const remote = yield* remoteControl('inspect-transferred-work', {tag: 'inspect', value: {work: work.work}});
  assert.deepEqual(remote.outer_operation, subject.outer);
  assert.deepEqual(remote.runtime, subject.runtime);
  assert.equal(remote.execution_revision, originalRevision);
  subject.controllerMove = true;
  observed(yield call('placement', 'move', {operation: 'move-controller', subject: {tag: 'controller', value: {}}, site: 'successor', custody_epoch: 0}));
  // The fixture resumes the accepted controller at its new site. Its next
  // command carries the signed succession proof to the existing executor.
  work = yield* remoteControl('inspect-from-successor', {tag: 'inspect', value: {work: work.work}});
  assert(subject.controllerMoved, 'the continuation must run at the successor');
  for (let index = 0; index < 128 && work.outcome !== 'completed'; index++) {
    work = yield* remoteControl('finish-remote-work-' + index, {tag: 'pump', value: {expected: expected(work), base_quantum: 1_000_000}});
  }
  assert.equal(work.outcome, 'completed');
  const rows = JSON.parse(work.result_preview.text);
  assert.deepEqual(rows[0].map(row => [row[0], row[7]]), Array.from({length: 16}, (_, i) => [String(2000 + i), '1']));
  subject.results = [work.result];
  yield ['stop', {reason: 'The selected runtime and suspended work moved to a native executor. The controller moved separately, resumed, and collected the exact result through signed control reports.'}];
}

function* mobilityTrace(subject, guestCut = false) {
  const built = observed(yield call('program', 'build', {source: {tag: 'json_text', value: subject.mobility.transport}, source_kind: 'source_records',
    exposures: [{effect: 0, class: 'observation'}, {effect: 1, class: 'input'}, {effect: 2, class: 'observation'}]}));
  subject.program = built.program;
  const description = built;
  const expected = work => ({work: work.work, execution_revision: work.execution_revision, control_revision: work.control_revision});
  let remote = false, serial = 0;
  function* command(tag, value) {
    return remote ? yield* remoteControl('mobility-' + serial++, {tag, value}) : observed(yield call('work', tag, value));
  }
  function* atPort(work, generation) {
    for (let i = 0; i < 128; i++) {
      if (!work.outer_operation && work.port_accepts_command && Number(work.port.generation) === generation) return work;
      assert(!['completed', 'failed', 'cancelled'].includes(work.outcome), JSON.stringify(work));
      if (work.schedule !== 'parked') work = yield* command('inspect', {work: work.work});
      else if (work.outer_operation) work = yield* command('pump', {expected: expected(work), base_quantum: 1_000_000});
      else work = yield* command('advance', expected(work));
    }
    assert.fail('mobility fixture did not reach its next port');
  }
  function* answer(work, value) {
    return yield* command('interact', {expected: expected(work), port: work.port.reference, generation: work.port.generation,
      command: {tag: 'resume_value', value: {tag: 'inline_json', value: {schema: work.port.argument_schema, json_text: JSON.stringify(value)}}}});
  }
  let work = yield* command('start', {program: subject.program,
    input: {tag: 'inline_json', value: {schema: description.input_schema, json_text: '["128","100"]'}},
    // Guest-cut transfer observes complete exposed ports; the native owner may
    // schedule the intervening slices. The outer-clone trace retains explicit
    // scheduling so it can capture and inspect an unfinished clone operation.
    policy: {stop: 'next_exposed_event', continuation: guestCut ? 'owner_scheduled' : 'explicit_only'}, runtime: {tag: 'packaged', value: {}}});
  work = yield* atPort(work, 1);
  assert.equal(JSON.parse(work.port.preview.text), '228');
  work = yield* answer(work, {});
  work = yield* atPort(work, 2);
  assert.equal(JSON.parse(work.port.preview.text), '0');
  work = yield* answer(work, {tag: 0, value: '10'});
  work = yield* atPort(work, 3);
  subject.branchValues = [JSON.parse(work.port.preview.text)];
  assert.equal(subject.branchValues[0], '366');
  const view = observed(yield call('context', 'materialize', {input: {tag: 'guest_view', value: {
    expected: expected(work), realization_revision: work.realization_revision, nodes: {tag: 'all', value: {}}}}, sources: []}));
  subject.view = view.value;
  function* pages(name, tag, value) {
    let text = '', offset = 0;
    for (let i = 0; i < 256; i++) {
      const page = observed(yield call(name, tag, {...value, page: {offset, maximum: 48 * 1024}}));
      assert.equal(Number(page.offset), offset);
      text += page.text;
      assert.equal(Number(page.next_offset), Buffer.byteLength(text));
      if (page.eof) {
        assert.equal(Number(page.total_bytes), Buffer.byteLength(text));
        return text;
      }
      assert(Number(page.next_offset) > offset);
      offset = Number(page.next_offset);
    }
    assert.fail('fixture description exceeded its paging bound');
  }
  const guestView = JSON.parse(yield* pages('context', 'expand', {reference: subject.view}));
  const roots = guestView[3], edges = guestView[4];
  const rootIds = new Set(roots.map(root => root[0]));
  const retainedEdge = edges.find(edge => rootIds.has(edge[0]) && !rootIds.has(edge[1]));
  assert(retainedEdge, 'the actual branch view must expose a nontrivial retention path');
  const querySource = yield* pages('program', 'describe', {section: 'retention_query'});
  const query = observed(yield call('program', 'build', {source: {tag: 'json_text', value: querySource}, source_kind: 'source_records', exposures: []}));
  const queryInput = observed(yield call('context', 'materialize', {input: {tag: 'value', value: {tag: 'inline_json', value: {
    schema: query.input_schema, json_text: JSON.stringify([guestView, retainedEdge[1]]),
  }}}, sources: [subject.view]})).value;
  let queryWork = observed(yield call('work', 'start', {program: query.program, input: {tag: 'reference', value: queryInput},
    policy: {stop: 'terminal', continuation: 'owner_scheduled'}, runtime: {tag: 'packaged', value: {}}}));
  if (queryWork.outcome !== 'completed') {
    observed(yield call('work', 'wait', {works: [queryWork.work], after: Number.MAX_SAFE_INTEGER}));
    queryWork = observed(yield call('work', 'inspect', {work: queryWork.work}));
  }
  assert.equal(queryWork.outcome, 'completed');
  const retention = JSON.parse(yield* pages('context', 'expand', {reference: queryWork.result}));
  assert.deepEqual(retention[0], guestView[0]);
  assert.equal(Number(retention[1]), 0);
  assert.equal(retention[2].tag, 1);
  assert(roots.some(root => JSON.stringify(root) === JSON.stringify(retention[2].value)));
  assert(retention[3].length > 0);
  let node = retention[2].value[0];
  for (const edge of retention[3]) {
    assert.equal(edge[0], node);
    assert(edges.some(actual => JSON.stringify(actual) === JSON.stringify(edge)));
    node = edge[1];
  }
  assert.equal(node, retainedEdge[1]);
  subject.retention = {target: node, result: queryWork.result, path: retention[3]};
  const afterQuery = yield* command('inspect', {work: work.work});
  assert.deepEqual(expected(afterQuery), expected(work));
  assert.equal(afterQuery.realization_revision, work.realization_revision);
  assert.deepEqual(afterQuery.port, work.port);
  const specialized = observed(yield call('program', 'specialize', {program: subject.program, hooks: {control: true, storage: true}}));
  subject.runtime = specialized.runtime;
  const revision = work.execution_revision;
  work = yield* command('realize', {expected: expected(work), realization_revision: work.realization_revision, runtime: {tag: 'selected', value: subject.runtime}});
  assert.equal(work.execution_revision, revision);
  if (guestCut) {
    work = yield* command('request_cut', {expected: expected(work), level: 'guest_cut'});
    assert(!work.outer_operation);
    assert(work.runtime_capsule);
    subject.guestCut = work.runtime_capsule;
    subject.guestRevision = work.execution_revision;
  } else {
    work = yield* answer(work, {tag: 0, value: '20'});
    for (let i = 0; i < 128; i++) {
      work = yield* command('inspect', {work: work.work});
      if (work.schedule === 'parked') break;
    }
    const before = work.execution_revision;
    subject.findClone = true;
    for (let i = 0; i < 256; i++) {
      // Group the initial four base slices. The required live clone witness
      // and the finer subsequent cuts remain checked before any transfer.
      work = yield* command('pump', {expected: expected(work), base_quantum: i === 0 ? 262_144 : 65_536});
      if (subject.clonePhase?.clone_frames > 0 && subject.clonePhase.clone_bindings > 0) break;
      assert(work.outer_operation || !work.port_accepts_command, 'the clone must be observed before its result');
    }
    subject.findClone = false;
    assert(subject.clonePhase?.clone_frames > 0 && subject.clonePhase.clone_bindings > 0, 'the actual capsule must retain live locals inside a progressed clone function');
    assert(work.outer_operation);
    assert.equal(work.execution_revision, before);
    subject.outer = work.outer_operation;
    const unavailable = yield call('work', 'request_cut', {expected: expected(work), level: 'guest_cut'});
    assert.equal(unavailable.disposition, 'rejected');
    assert.equal(unavailable.observation.error, 'GuestCutUnavailable');
  }
  const selected = {tag: 'work', value: work.work};
  assert.equal(observed(yield call('placement', 'assess', {subject: selected, site: 'executor'})).compatible, true);
  observed(yield call('placement', 'move', {operation: 'move-mobility-work', subject: selected, site: 'executor', custody_epoch: 0}));
  let moved = false;
  let latestPlacement;
  for (let i = 0; i < 1024; i++) {
    const placement = observed(yield call('placement', 'inspect', selected));
    latestPlacement = placement;
    if (placement.custody?.phase === 'away') { moved = true; break; }
  }
  assert(moved, JSON.stringify(latestPlacement));
  if (!guestCut) {
    subject.controllerMove = true;
    observed(yield call('placement', 'move', {operation: 'move-mobility-controller', subject: {tag: 'controller', value: {}}, site: 'successor', custody_epoch: 0}));
  }
  remote = true;
  work = yield* command('inspect', {work: work.work});
  if (!guestCut) assert(subject.controllerMoved);
  assert.deepEqual(work.runtime, subject.runtime);
  if (guestCut) {
    assert(!work.outer_operation);
    assert.deepEqual(work.runtime_capsule, subject.guestCut);
    assert.equal(work.execution_revision, subject.guestRevision);
    work = yield* answer(work, {tag: 0, value: '20'});
  } else assert.deepEqual(work.outer_operation, subject.outer);
  work = yield* atPort(work, 4);
  subject.branchValues.push(JSON.parse(work.port.preview.text));
  assert.equal(subject.branchValues[1], '376', 'the second branch starts from the saved cell, not the first branch mutation');
  work = yield* command('cancel', {expected: expected(work), reason: 'Both alternatives are acquired; close the retained parent scope.'});
  work = yield* atPort(work, 5);
  assert.equal(work.port.class, 'observation');
  work = yield* answer(work, {});
  // Cancellation cleanup is owner-scheduled. A signed interaction report can
  // already be older than the next committed cleanup transition when received.
  for (let i = 0; i < 128 && work.outcome !== 'cancelled'; i++)
    work = yield* command('inspect', {work: work.work});
  assert.equal(work.outcome, 'cancelled');
  assert.equal(work.cleanup_complete, true);
  subject.cleanupComplete = true;
  yield ['stop', {reason: guestCut
    ? 'One dynamic prefix supplied two isolated alternatives. After an ordinary retention query and specialization, the canonical guest cut moved to a fresh native executor. Its second alternative and cancellation cleanup completed there.'
    : 'One dynamic prefix supplied two isolated alternatives. An ordinary query explained a retained node from the first branch view. The chosen evaluator and suspended work moved with their controller; cancellation completed the single outer cleanup.'}];
}
