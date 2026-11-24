import test from 'node:test';
import assert from 'node:assert/strict';
import {adjudicateRepairTrace, canonicalProjectionInput, capturedModelResponse, confirmedApplication, diagnosticPresentation, inspectProjectionResult,
  selectedPresentation} from '../../tools/evaluation/interface_repair_trace.mjs';
import {canonicalEvidence, collisionProbe, makeRepairCorpus} from '../../tools/evaluation/interface_repair.mjs';
import {encodeValue} from '../support/values.mjs';

const view = 'a'.repeat(64);
const block = {kind: 'computed', value: '18446744073709551615'};
const envelope = JSON.stringify({selected_context_data: [block]});
const part = {type: 'input_text', text: envelope};
const user = {role: 'user', content: [part]};
const mistaken = [{role: 'assistant', content: [part]}, {type: 'function_call_output', output: [part]},
  {role: 'user', content: [{...part, prompt_cache_breakpoint: {mode: 'explicit'}}]},
  {role: 'user', content: [{...part, text: JSON.stringify({inputs: JSON.parse(envelope)})}]}];

test('successful HTTP transport and explicit model response are independent evidence', () => {
  const raw = (body, format = 0, status = 200) => [status, true, null, Buffer.from(body), format, null, null, 2];
  const body = {status: 'completed', error: null, output: [{type: 'function_call', status: 'completed',
    name: 'report', call_id: 'x', arguments: '{}'}]};
  const sse = (type, response) => 'data: ' + JSON.stringify({type, response}) + '\n\n';
  assert.equal(capturedModelResponse(raw(JSON.stringify(body))), true);
  assert.equal(capturedModelResponse(raw(sse('response.completed', body), 1)), true);
  assert.equal(capturedModelResponse(raw(sse('response.failed', {status: 'failed'}), 1)), false);
  assert.equal(capturedModelResponse(raw(JSON.stringify({status: 'failed', error: {code: 'invalid_user'}}))), false);
  assert.equal(capturedModelResponse(raw('{}', 0, 403)), false);
  assert.equal(capturedModelResponse(raw('unparseable')), null);
  assert.equal(capturedModelResponse(raw(JSON.stringify({...body, output: []}))), null);
  assert.equal(capturedModelResponse(raw(JSON.stringify(body)), [{tag: 4}]), null);
  for (const output of [body.output, [{type: 'message', role: 'assistant', status: 'incomplete', content: [
    {type: 'output_text', text: 'Partial output.'}]}], [{type: 'message', role: 'assistant', status: 'completed',
    content: [{type: 'refusal', refusal: 'Declined.'}]}]]) {
    const incomplete = {...body, status: 'incomplete', output};
    assert.equal(capturedModelResponse(raw(JSON.stringify(incomplete)), [{tag: 3}]), true);
    assert.equal(capturedModelResponse(raw(sse('response.incomplete', incomplete), 1)), true);
  }
  assert.equal(capturedModelResponse(raw(sse('response.incomplete', {...body, status:'incomplete', output:[]}), 1)), null);
});

test('canonical scan work requires the task-owned consumer observation as well as source-backed scan facts', () => {
  const specimen = makeRepairCorpus('canonical').development[0];
  const refs = Object.fromEntries(Object.keys(specimen.files).map((path, i) => [path, {kind: 'value', id: (i+1).toString(16).padStart(64, '0')}]));
  const input = [Buffer.alloc(32, 255), 1n], facts = canonicalEvidence(specimen, refs);
  const origins = Object.values(refs).map(r => [Buffer.from(r.id, 'hex'), 1n]);
  const values = new Map([[input[0].toString('hex'), {raw:[,,,,[null, origins]]}]]);
  const matches = (kind, id, observed) => canonicalProjectionInput(values, input, specimen, refs, [[kind, id], facts], observed);
  assert.equal(matches(12, view, view), true);
  assert.equal(matches(3, view, view), false);
  assert.equal(matches(12, view, null), false);
  assert.equal(matches(12, view, 'f'.repeat(64)), false);
});

test('selected rendering requires an authentic prepared selection and its unique native user envelope', () => {
  assert.equal(selectedPresentation(null, {input: [user]}), null);
  assert.equal(selectedPresentation(view, {input: mistaken}), null);
  const input = [...mistaken, user];
  assert.deepEqual(selectedPresentation(view, {input}), {index: mistaken.length, blocks: [block]});
  assert.equal(selectedPresentation(view, {input: [...input, structuredClone(user)]}), null);
  const prefix = {type: 'additional_tools', role: 'developer', tools: []};
  assert.deepEqual(selectedPresentation(view, {input: [prefix, ...input]}), {index: input.length, blocks: [block]});
});

test('unobserved work and nominations carry no authorship, exposure, or decision credit', () => {
  const archive = {manifest: [,,,,,,[]], task: {id: Array(16).fill(0), controller_interaction: {tag: 0}, result: {tag: 0}}};
  const specimen = makeRepairCorpus('missing').development[0];
  const nomination = {kind:'interface-repair.candidate.v1', status:'candidate', program:{kind:'program',id:view}, diagnosis:'repair'};
  const result = adjudicateRepairTrace({archive, application:{}, specimen, summary: JSON.stringify(nomination), nomination,
    observations: [{records: [], acquisition_records_complete: true}]});
  assert.equal(result.report_bound, false);
  assert.equal(result.authored_and_applied, false);
  assert.equal(result.transfer_bound, false);
  assert.equal(result.candidate, null);
  assert.equal(result.ordinary_fallback, null);
  assert.deepEqual(result.exposure, []);
  assert.deepEqual(result.delivery, []);
});

const resultSchema = {root: 0, types: [{product: [1, 11]}, {product: [2, 5]}, {product: [3, 4]},
  {enumeration: Array.from({length: 13}, (_, i) => i)}, {bounded_text: 64}, {seq: 6},
  {sum: [2, 7, 8, 10]}, {product: []}, {product: [2, 9, 9]}, 'u64', 'text', 'boolean']};
const consumer = [12, view], program = {kind: 'program', id: 'b'.repeat(64)};
const computed = {tag: 1, value: []};

test('diagnostic credit compares the payloads both executions propose to their shared consumer', () => {
  const proposal = (blocks, payload, observed = consumer) => {
    const bytes = encodeValue(resultSchema, [[observed, blocks], payload]);
    return {consumer, program, expected: payload ? 'exhausted_declared_domain' : 'incomplete',
      ...diagnosticPresentation(inspectProjectionResult(resultSchema, bytes), consumer)};
  };
  const left = proposal([computed], true), right = proposal([computed], false);
  assert.equal(collisionProbe(left, right).distinction_preserved, true);
  for (const invalid of [proposal([], false), proposal([{tag: 3, value: 'same'}], false),
    proposal([computed, computed], false), proposal([computed], false, [12, 'other'])]) {
    assert.equal(Object.hasOwn(invalid, 'payload'), false);
    assert.equal(collisionProbe(left, invalid).distinction_preserved, null);
  }
});

test('incompatible output envelopes and host materialization limits have local inspection results', () => {
  for (const schema of [{root: 0, types: ['boolean']}, {root: 0, types: [{product: [1, 1]}, 'boolean']}])
    assert.equal(inspectProjectionResult(schema, Buffer.from([1])).inspection_error, 'InvalidProjectionSchema');
  const header = encodeValue({...resultSchema, root: 1}, [consumer, [computed]]);
  const huge = {root: 0, types: [...resultSchema.types.slice(0, 11), {seq: 12}, 'unit']};
  const capacity = inspectProjectionResult(huge, Buffer.concat([header, Buffer.from([0xc1, 0x84, 0x3d])]));
  assert.equal(capacity.inspection_error, 'ValueCapacity');
  assert.deepEqual(diagnosticPresentation(capacity, consumer), {inspection_error: 'ValueCapacity'});
  assert.equal(inspectProjectionResult(resultSchema, header).inspection_error, 'Truncated');
  assert.equal(inspectProjectionResult(resultSchema, Buffer.concat([header, Buffer.from([1])])).payload, true);
});

test('single-block compliance belongs to the same ordered and confirmed author application', () => {
  const use = {program, canonical_input: true, view, model_start: {cut: '12'}, model_select: {cut: '15'},
    one_computed_block: true, exposures: []};
  const delivered = {id: 'one', delivery: 'confirmed', model_response: true, rendered: true, one_computed_block: true, preparation_cut: '15'};
  const multiple = {...use, view: 'multiple', one_computed_block: false, exposures: [delivered]};
  const seen = new Set(['one']);
  const applied = (...uses) => confirmedApplication(uses, {program}, '10', seen);
  for (const altered of [{rendered: false}, {model_response: null}, {model_response: false}, {id: 'elsewhere'}, {preparation_cut: '14'}]) {
    const other = {...use, exposures: [{...delivered, ...altered}]};
    assert.equal(applied(other), null);
    assert.equal(applied(other, multiple).one_computed_block, false);
  }
  const qualified = {...use, exposures: [delivered]};
  assert.equal(applied({...qualified, model_start: {cut: '9'}}), null);
  assert.equal(applied({...qualified, model_select: {cut: '11'}}), null);
  assert.equal(applied({...use, exposures: [{...delivered, one_computed_block: false}]}).one_computed_block, false);
  assert.deepEqual(applied(multiple, qualified).exposure, delivered);
  assert.equal(applied(multiple, qualified).view, view);
});
