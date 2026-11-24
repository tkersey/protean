import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {writeRepairReport} from '../../tools/evaluation/interface_repair_task.mjs';
import {createHash} from 'node:crypto';
import {adjudicateRepairTrace, bindReport, canonicalProjectionInput, capturedModelResponse, computedRendering, confirmedApplication, diagnosticPresentation, inspectProjectionResult,
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
  const body = {id: 'r', status: 'completed', error: null, output: [{type: 'function_call', status: 'completed',
    name: 'report', call_id: 'x', arguments: '{}'}]};
  const sse = (type, response) => 'data: ' + JSON.stringify({type, response}) + '\n\n';
  assert.equal(capturedModelResponse(raw(JSON.stringify(body))), true);
  const done = 'data: ' + JSON.stringify({type: 'response.output_item.done', output_index: 0, item: body.output[0]}) + '\n\n';
  assert.equal(capturedModelResponse(raw(done + sse('response.completed', body), 1)), true);
  assert.equal(capturedModelResponse(raw(sse('response.failed', {status: 'failed', id: 'r'}), 1)), false);
  assert.equal(capturedModelResponse(raw(JSON.stringify({status: 'failed', error: {code: 'invalid_user'}}))), false);
  assert.equal(capturedModelResponse(raw('{}', 0, 403)), false);
  assert.equal(capturedModelResponse(raw('unparseable')), null);
  assert.equal(capturedModelResponse(raw(JSON.stringify({...body, output: []}))), null);
  assert.equal(capturedModelResponse(raw(JSON.stringify({...body, usage:{input_tokens:'unavailable'}}))), true);
  assert.equal(capturedModelResponse(raw(JSON.stringify({...body, output:[{...body.output[0], arguments:''}]}))), true);
  for (const output of [body.output, [{type: 'message', role: 'assistant', status: 'incomplete', content: [
    {type: 'output_text', text: 'Partial output.'}]}], [{type: 'message', role: 'assistant', status: 'completed',
    content: [{type: 'refusal', refusal: 'Declined.'}]}]]) {
    const incomplete = {...body, status: 'incomplete', output};
    assert.equal(capturedModelResponse(raw(JSON.stringify(incomplete))), true);
    assert.equal(capturedModelResponse(raw(sse('response.incomplete', incomplete), 1)), true);
  }
  assert.equal(capturedModelResponse(raw(sse('response.incomplete', {...body, status:'incomplete', output:[]}), 1)), null);
});

test('the provider terminal and finalized items bind generated output to a single response', () => {
  const frame = value => 'data: ' + JSON.stringify(value) + '\n\n';
  const read = events => capturedModelResponse([200,true,null,Buffer.from(events.map(frame).join('')),1,null,null,2]);
  const created = {type:'response.created', sequence_number: 1, response:{id:'r'}};
  const call = {type:'function_call', status:'completed', id:'fc', call_id:'c', name:'choose', arguments:'{}'};
  const done = {type:'response.output_item.done', sequence_number: 2, output_index:0, item:call};
  const finish = output => ({type:'response.completed', sequence_number: 3, response:{id:'r', status:'completed', error:null, output}});
  for (const roster of [[], [{type:'function_call', id:'fc'}], [call]]) assert.equal(read([created, done, finish(roster)]), true);
  assert.equal(read([created, done, finish([{...call, name:'other'}])]), null);
  assert.equal(read([created, done, {...finish([]), sequence_number: 1}]), null);
  const partial = {type:'response.incomplete', response:{id:'r', status:'incomplete', output:[
    {type:'reasoning', summary:[{type:'summary_text',text:'Observed scan facts.'}]}]}};
  assert.equal(read([created, partial]), true);
  assert.equal(read([created, {...partial,response:{...partial.response,id:'other'}}]), null);
  const json = output => [200,true,null,Buffer.from(JSON.stringify({status:'completed',error:null,output})),0,null,null,2];
  const empty = {type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:''}]};
  assert.equal(capturedModelResponse(json([empty])), null);
  assert.equal(capturedModelResponse(json([])), null);
  for (const status of ['incomplete', 'failed']) {
    const terminal = {type:'response.' + status, response:{id:'r', status, output:[]}};
    assert.equal(read([created, done, terminal]), true);
    assert.equal(read([created, {...done, item:empty}, terminal]), status === 'failed' ? false : null);
    assert.equal(read([created, done, {...terminal,response:{...terminal.response,id:'another'}}]), null);
  }
  assert.equal(read([created, done, {type:'error', code:'stream_failed'}]), true);
});

test('response captures preserve exact event ordinals and require unambiguous JSON', () => {
  const read = (text, format = 1) => capturedModelResponse([200,true,null,Buffer.from(text),format,null,null,2]);
  const done = seq => 'data: {"type":"response.output_item.done","sequence_number":' + seq +
    ',"output_index":0,"item":{"type":"function_call","status":"completed","name":"report","call_id":"a","arguments":""}}\n\n';
  const last = 'data: {"type":"response.completed","sequence_number":18446744073709551615,' +
    '"response":{"id":"r","status":"completed","error":null,"output":[]}}\n\n';
  assert.equal(read(done('1844674407370955161.4e1') + last), true);
  assert.equal(read(done('18446744073709551615') + last), null);
  for (const invalid of ['18446744073709551616','0.001','-1']) assert.equal(read(done(invalid) + last), null);
  assert.equal(read('{"status":"failed","status":"completed","error":null,"output":[]}', 0), null);
  assert.equal(read(done('1') + last.replace('"id":"r"', '"id":"r","id":"s"')), null);
});

test('partial streamed output carries its item or response attribution through termination', () => {
  const read = events => capturedModelResponse([200, true, null, Buffer.from(events.map(event =>
    'data: ' + JSON.stringify(event) + '\n\n').join('')), 1, null, null, 2]);
  const added = {type:'response.output_item.added', output_index:0, response_id:'r',
    item:{id:'m',type:'message',role:'assistant',status:'in_progress'}};
  const delta = {type:'response.output_text.delta', output_index:0, item_id:'m', content_index:0, delta:'Observed'};
  for (const terminal of [{type:'error'}, ...['failed', 'incomplete', 'completed'].map(status =>
    ({type:'response.' + status, response:{id:'r',status,error:null,output:[]}}))]) {
    assert.equal(read([added, delta, terminal]), true);
    assert.equal(read([{...delta, response_id:'r'}, terminal]), true);
    assert.equal(read([delta, terminal]), null);
    assert.equal(read([added, {...delta, output_index:1}, terminal]), null);
  }
  const done = (output_index, item) => ({type:'response.output_item.done', output_index, item});
  const call = {id:'f',type:'function_call',call_id:'c',name:'report',arguments:'{}',status:'completed'};
  const reasoning = {type:'reasoning',id:'reason',summary:[]};
  const roster = {type:'response.completed',response:{id:'r',status:'completed',error:null,
    output:[call,{type:'reasoning',id:'reason',status:'incomplete'}]}};
  assert.equal(read([done(0,call),done(1,reasoning),roster]), null);
});

test('report credit requires the admitted archive projection identified by the producer', () => {
  const digest = value => createHash('sha256').update(value).digest();
  const bytes = digest('report'), task = digest('task').subarray(0, 16), interaction = digest('interaction');
  const archive = {task:{id:task,controller_interaction:{tag:1,value:interaction},result:{tag:1,value:[bytes,10n]}}};
  const receipt = {task_id:task.toString('hex'),interaction_id:interaction.toString('hex'),controller_id:'controller',
    controller_epoch:'0',event_cut:'9',attempt_id:'attempt',prepared_sha256:'prepared',capture_projection_sha256:'projection',
    result_sha256:bytes.toString('hex'),summary_sha256:digest('summary').toString('hex')};
  const last = {...receipt,attempt:{id:'attempt',prepared_sha256:'prepared',capture_projection_sha256:'projection'}};
  const bind = source => bindReport(archive, [{report_producer: source}], [last], 'summary');
  assert.equal(bind(receipt), last);
  assert.equal(bind({...receipt,capture_projection_sha256:'other'}), null);
  delete last.attempt.capture_projection_sha256;
  assert.equal(bind(receipt), null);
  assert.equal(bind({...receipt,capture_projection_sha256:undefined}), null);
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

test('rendered credit binds the actual displayed schema and retains unknown host inspection', async t => {
  const result = {kind:'value',id:view};
  const inspected = inspectProjectionResult(resultSchema, encodeValue(resultSchema, [[consumer,[computed]],true]));
  const block = {kind:'computed',result,schema_identity:inspected.schema,schema:inspected.display,value:true};
  const rendered = (b, payload = true) => computedRendering([b], result, inspected.schema, payload, inspected.display);
  assert.equal(rendered(block), true);
  assert.equal(rendered({...block,schema:undefined}), false);
  assert.equal(rendered({...block,schema:{root:'0',types:[{tag:'u64',value:{}}]}}), false);
  assert.equal(computedRendering([block], result, inspected.schema, undefined, inspected.display), null);
  let a = [], b = [];
  for (let i = 0; i < 4000; i++) { a = [a]; b = [b]; }
  const recursive = {root:0, types:[...resultSchema.types.slice(0, 11), {seq:11}]};
  const recursiveOutput = inspectProjectionResult(recursive, encodeValue(recursive, [[consumer,[computed]],b]));
  assert.equal(recursiveOutput.inspection_error, undefined);
  assert.equal(computedRendering([{...block,schema:recursiveOutput.display,schema_identity:recursiveOutput.schema,value:a}],
    result, recursiveOutput.schema, recursiveOutput.payload, recursiveOutput.display), true);
  const pair = {program, consumer, expected:'incomplete',payload:a};
  assert.equal(collisionProbe(pair, {...pair,expected:'exhausted_declared_domain',payload:b}).distinction_preserved, false);
  const directory = await mkdtemp(join(tmpdir(), 'protean-repair-payload-'));
  t.after(() => rm(directory, {recursive:true, force:true}));
  const metrics = {compiler_nanoseconds: 18446744073709551615n, missing: undefined, usage: [undefined, null]};
  for (const [filename, indent] of [['report.json', undefined], ['results.json', 2]]) {
    const path = join(directory, filename);
    await writeRepairReport(path, {metrics, projection: recursiveOutput, collision: pair}, indent);
    const saved = JSON.parse(await readFile(path, 'utf8'));
    assert.deepEqual(saved.metrics, {compiler_nanoseconds:'18446744073709551615', usage:[null, null]});
    assert.equal(saved.projection.schema, recursiveOutput.schema);
    assert.equal(computedRendering([{...block,schema:recursiveOutput.display,schema_identity:recursiveOutput.schema,value:a}],
      result, recursiveOutput.schema, saved.projection.payload, saved.projection.display), true);
    assert.equal(collisionProbe(saved.collision, {...pair,expected:'exhausted_declared_domain'}).distinction_preserved, false);
    await assert.rejects(writeRepairReport(path, {replacement:true}, indent), {code:'EEXIST'});
  }
});

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
