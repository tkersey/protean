import test from 'node:test';
import assert from 'node:assert/strict';
import {adjudicateRepairTrace, selectedPresentation} from '../../tools/evaluation/interface_repair_trace.mjs';
import {makeRepairCorpus} from '../../tools/evaluation/interface_repair.mjs';

const view = 'a'.repeat(64);
const block = {kind: 'computed', value: '18446744073709551615'};
const envelope = JSON.stringify({selected_context_data: [block]});
const part = {type: 'input_text', text: envelope};
const user = {role: 'user', content: [part]};
const mistaken = [{role: 'assistant', content: [part]}, {type: 'function_call_output', output: [part]},
  {role: 'user', content: [{...part, prompt_cache_breakpoint: {mode: 'explicit'}}]},
  {role: 'user', content: [{...part, text: JSON.stringify({inputs: JSON.parse(envelope)})}]}];

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
