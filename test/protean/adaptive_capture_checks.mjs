// Independent, read-only observations of native captures and controlled HTTPS.
// No execution, admission, prompt rendering, provider interpretation or recovery.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {decodeSchema} from '../support/values.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export function contract(application, name) {
  const entry = application.support[name], bytes = Buffer.from(entry.wire_base64url, 'base64url');
  assert.equal(bytes.toString('base64url'), entry.wire_base64url);
  assert.equal(hash(bytes), entry.wire_sha256);
  return decodeSchema(bytes);
}
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object' ?
  Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
const canonical = value => Buffer.from(JSON.stringify(ordered(value)));
const names = ['list', 'read', 'ask', 'report', 'stop', 'inference_set', 'skill_set', 'inspect'];
function markers(body) {
  return body.input.flatMap((item, index) => {
    const field = item.type === 'function_call_output' ? 'output' : 'content';
    return Array.isArray(item[field]) ? item[field].flatMap((part, n) => part.prompt_cache_breakpoint?.mode === 'explicit' ? [`input[${index}].${field}[${n}]`] : []) : [];
  });
}
function visible(body) {
  // Explicit local ordering, not the provider's hidden prompt or token prefix.
  const settings = {model: body.model, reasoning: body.reasoning, parallel_tool_calls: body.parallel_tool_calls,
    text: body.text ?? null, service_tier: body.service_tier ?? null, context_management: body.context_management ?? null};
  return Buffer.concat([settings, body.tools, ...body.input].flatMap(value => [canonical(value), Buffer.from('\n')]));
}
function prefix(left, right) {
  if (!left) return 0;
  let n = 0; while (n < left.length && n < right.length && left[n] === right[n]) n++;
  return n;
}

export function assertAdaptiveCaptures(rows, skillBodies) {
  rows.sort((a,b)=>Number(a.request[3][2]-b.request[3][2]));
  for (const [index,row] of rows.entries()) {
    const [invocation,,,,materialized,offered]=row.request;
    assert.deepEqual(invocation[4].map(tool=>tool[2]),names.filter((_,n)=>materialized[n]));
    assert(offered.every((value,n)=>!value||materialized[n]));
    const prior=rows[index-1], previous=prior?markers(prior.http):[];
    const added=markers(row.http).filter(path=>{
      if(!prior||!previous.includes(path))return true;
      const position=Number(path.match(/^input\[(\d+)\]/)[1]);
      return !canonical(row.http.input.slice(0,position+1)).equals(canonical(prior.http.input.slice(0,position+1)));
    });
    assert(added.length<=2);
  }
  const transientIndices = rows.flatMap((row, index) => row.request[3][6].some(skill => skill[3] === 1 && skill[4]) ? [index] : []);
  assert(transientIndices.length >= 2 && transientIndices.at(-1) < rows.length - 1);
  const active = rows[transientIndices[0]].request[3][6].find(skill => skill[3] === 1 && skill[4]);
  const transientBody = skillBodies.find(skill => skill.id === active[1]).body;
  for (const index of transientIndices) {
    const body = rows[index].http, position = body.input.findIndex(item => item.content?.some(part => part.text === transientBody));
    assert(position >= 0 && markers(body).every(path => Number(path.match(/^input\[(\d+)\]/)[1]) < position));
  }
  assert(prefix(visible(rows[transientIndices[1] - 1].http), visible(rows[transientIndices[1]].http)) < visible(rows[transientIndices[0]].http).length);
  const contains = value => typeof value === 'string' ? value.includes(transientBody) : value && typeof value === 'object' ? Object.values(value).some(contains) : false;
  assert(!contains(rows[transientIndices.at(-1) + 1].http));
}
