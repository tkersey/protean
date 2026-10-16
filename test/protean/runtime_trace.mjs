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
