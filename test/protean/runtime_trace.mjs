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
  if (['tools-runtime-mobility', 'tools-runtime-guest-mobility'].includes(scenario)) {
    yield* mobilityTrace(subject, scenario === 'tools-runtime-guest-mobility');
    return;
  }
  const built = observed(yield call('program', 'build', {source: {tag: 'json_text', value: JSON.stringify(subject.recipe)}, source_kind: 'component_recipe', exposures: []}));
  subject.program = built.program;
  if (scenario === 'tools-runtime-specialized') {
    const runtime = observed(yield call('program', 'specialize', {program: subject.program, hooks: {control: false, storage: false}}));
    assert.equal(runtime.runtime.kind, 'runtime');
    assert.equal(runtime.approval, 'exact-source-and-independent-derivation');
    subject.runtime = runtime.runtime;
    subject.results = [];
    for (const index of [0, 1, 2]) {
      const input = observed(yield call('context', 'materialize', {input: {tag: 'authorized_input', value: subject.inputs[index].id}, sources: []})).value;
      let work = observed(yield call('work', 'start', {program: subject.program, input: {tag: 'reference', value: input}, policy: {stop: 'terminal', continuation: 'owner_scheduled'}, runtime: {tag: 'selected', value: subject.runtime}}));
      if (work.outcome !== 'completed') {
        const waited = observed(yield call('work', 'wait', {works: [work.work], after: Number.MAX_SAFE_INTEGER}));
        assert.equal(waited.interrupted, false);
        assert.equal(waited.works.length, 1);
        work = waited.works[0];
      }
      assert.equal(work.outcome, 'completed');
      assert.deepEqual(work.runtime, subject.runtime);
      const rows = JSON.parse(work.result_preview.text);
      assert.deepEqual(rows[0].map(row => [row[0], row[7]]), index === 0 ? [['1','1'],['2','2'],['3','3'],['4','4']] : index === 1 ? [['80','1']] : Array.from({length: 16}, (_, i) => [String(2000 + i), '1']));
      subject.results.push(work.result);
    }
    yield ['stop', {reason: 'One admitted specialization served three runs with changing inputs, including the sixteen-row batch; the results remain acquired evidence.'}];
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
    input: {tag: 'inline_json', value: {schema: description.input_schema, json_text: guestCut ? '["8","100"]' : '["128","100"]'}},
    policy: {stop: 'next_exposed_event', continuation: 'owner_scheduled'}, runtime: {tag: 'packaged', value: {}}});
  work = yield* atPort(work, 1);
  assert.equal(JSON.parse(work.port.preview.text), guestCut ? '108' : '228');
  work = yield* answer(work, {});
  work = yield* atPort(work, 2);
  assert.equal(JSON.parse(work.port.preview.text), '0');
  subject.branchValues = [];
  if (guestCut) {
    work = yield* answer(work, {tag: 0, value: '10'});
    work = yield* atPort(work, 3);
    subject.branchValues.push(JSON.parse(work.port.preview.text));
    assert.equal(subject.branchValues[0], '126');
  }
  if (!guestCut) {
    const before = work;
    work = yield* command('delegate', {expected: expected(work), policy: {stop: 'next_exposed_event', continuation: 'explicit_only'}, interpretation: {tag: 'none', value: {}}});
    assert.equal(work.execution_revision, before.execution_revision);
    assert.equal(work.realization_revision, before.realization_revision);
    assert.deepEqual(work.port, before.port);
  }
  // The guest-cut demonstration owns the complete retention-query sequence.
  // The outer-capsule demonstration independently owns the unfinished clone,
  // exact micro-progress, controller succession and remote cleanup assertions.
  if (guestCut) {
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
      const waited = observed(yield call('work', 'wait', {works: [queryWork.work], after: Number.MAX_SAFE_INTEGER}));
      assert.equal(waited.interrupted, false);
      assert.equal(waited.works.length, 1);
      queryWork = waited.works[0];
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
  }
  subject.runtime = 'packaged-generic';
  if (guestCut) {
    const specialized = observed(yield call('program', 'specialize', {program: subject.program, hooks: {control: false, storage: false}}));
    subject.runtime = specialized.runtime;
    const revision = work.execution_revision;
    work = yield* command('realize', {expected: expected(work), realization_revision: work.realization_revision, runtime: {tag: 'selected', value: subject.runtime}});
    assert.equal(work.execution_revision, revision);
    work = yield* command('request_cut', {expected: expected(work), level: 'guest_cut'});
    assert(!work.outer_operation);
    assert(work.runtime_capsule);
    subject.guestCut = work.runtime_capsule;
    subject.guestRevision = work.execution_revision;
  } else {
    work = yield* answer(work, {tag: 0, value: '20'});
    for (let i = 0; i < 128 && work.schedule !== 'parked'; i++)
      work = yield* command('inspect', {work: work.work});
    assert.equal(work.schedule, 'parked');
    const before = work.execution_revision;
    subject.findClone = true;
    for (let i = 0; i < 256; i++) {
      work = yield* command('pump', {expected: expected(work), base_quantum: i === 0 ? 262_144 : 65_536});
      if (subject.clonePhase?.clone_frames > 0 && subject.clonePhase.clone_bindings > 0) break;
      assert(work.outer_operation || !work.port_accepts_command, 'the clone must be observed before its result');
    }
    subject.findClone = false;
    assert(subject.clonePhase?.clone_frames > 0 && subject.clonePhase.clone_bindings > 0, 'the actual capsule must retain live locals inside a progressed clone function');
    assert(work.outer_operation);
    assert.equal(work.execution_revision, before);
    subject.outer = work.outer_operation;
    subject.outerRevision = work.execution_revision;
    const unavailable = yield call('work', 'request_cut', {expected: expected(work), level: 'guest_cut'});
    assert.equal(unavailable.disposition, 'rejected');
    assert.equal(unavailable.observation.error, 'GuestCutUnavailable');
  }
  const selected = {tag: 'work', value: work.work};
  const assessment = observed(yield call('placement', 'assess', {subject: selected, site: 'executor'}));
  assert.equal(assessment.compatible, true);
  if (!guestCut) assert.deepEqual(assessment.cut.outer, subject.outer);
  observed(yield call('placement', 'move', {operation: 'move-mobility-work', subject: selected, site: 'executor', custody_epoch: 0}));
  let moved = false;
  let latestPlacement;
  for (let i = 0; i < 1024; i++) {
    const placement = observed(yield call('placement', 'inspect', selected));
    latestPlacement = placement;
    if (placement.custody?.phase === 'away') { moved = true; break; }
  }
  assert(moved, JSON.stringify(latestPlacement));
  remote = true;
  work = yield* command('inspect', {work: work.work});
  assert.deepEqual(work.runtime, subject.runtime);
  if (guestCut) {
    assert(!work.outer_operation);
    assert.deepEqual(work.runtime_capsule, subject.guestCut);
    assert.equal(work.execution_revision, subject.guestRevision);
    work = yield* answer(work, {tag: 0, value: '20'});
  } else {
    assert.deepEqual(work.outer_operation, subject.outer);
    assert.equal(work.execution_revision, subject.outerRevision);
  }
  work = yield* atPort(work, guestCut ? 4 : 3);
  subject.branchValues.push(JSON.parse(work.port.preview.text));
  assert.equal(subject.branchValues.at(-1), guestCut ? '136' : '376');
  if (!guestCut) {
    const beforeSwitch = work;
    work = yield* command('realize', {expected: expected(work), realization_revision: work.realization_revision, runtime: {tag: 'packaged', value: {}}});
    assert.equal(work.execution_revision, beforeSwitch.execution_revision);
    assert.equal(work.realization_revision, beforeSwitch.realization_revision + 1);
    assert.equal(work.runtime, 'packaged-generic');
    assert.deepEqual(work.port, beforeSwitch.port);
    subject.controllerMove = true;
    observed(yield call('placement', 'move', {operation: 'move-mobility-controller', subject: {tag: 'controller', value: {}}, site: 'successor', custody_epoch: 0}));
    assert(subject.controllerMoved);
  }
  work = yield* command('cancel', {expected: expected(work), reason: 'The selected alternatives are acquired; close the retained parent scope.'});
  work = yield* atPort(work, guestCut ? 5 : 4);
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
    : 'A large unfinished clone and its chosen evaluator moved before the first alternative completed. The controller moved separately; cancellation completed the single outer cleanup.'}];
}
