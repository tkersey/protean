import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

const whitespace = character => character === ' ' || character === '\n' || character === '\r' || character === '\t';
const byteLength = text => Buffer.byteLength(text, 'utf8');
const roles = new Set(['system', 'developer', 'user', 'assistant', 'tool']);
const itemTypes = new Set(['message', 'function_call', 'function_call_output', 'reasoning',
  'configuration_update', 'additional_tools', 'item_reference']);

function skipWhitespace(text, start) {
  while (whitespace(text[start])) start++;
  return start;
}

function stringEnd(text, start) {
  for (let index = start + 1; index < text.length; index++) {
    if (text[index] === '\\') index++;
    else if (text[index] === '"') return index + 1;
  }
  throw new Error('Invalid prepared request JSON.');
}

function valueEnd(text, start) {
  if (text[start] === '"') return stringEnd(text, start);
  if (text[start] === '[' || text[start] === '{') {
    let depth = 0;
    for (let index = start; index < text.length; index++) {
      const character = text[index];
      if (character === '"') index = stringEnd(text, index) - 1;
      else if (character === '[' || character === '{') depth++;
      else if (character === ']' || character === '}') {
        if (--depth === 0) return index + 1;
      }
    }
  } else {
    let end = start;
    while (end < text.length && !whitespace(text[end]) && !',]}'.includes(text[end])) end++;
    return end;
  }
  throw new Error('Invalid prepared request JSON.');
}

function fields(text, start = 0) {
  const result = [], names = new Set();
  let index = skipWhitespace(text, skipWhitespace(text, start) + 1);
  while (text[index] !== '}') {
    const start = index, keyEnd = stringEnd(text, start);
    const name = JSON.parse(text.slice(start, keyEnd));
    if (names.has(name)) throw new Error('Duplicate prepared request field.');
    names.add(name);
    const valueStart = skipWhitespace(text, skipWhitespace(text, keyEnd) + 1);
    const end = valueEnd(text, valueStart);
    result.push({name, start, keyEnd, valueStart, end});
    index = skipWhitespace(text, end);
    if (text[index] === ',') index = skipWhitespace(text, index + 1);
  }
  return result;
}

function elements(text, field) {
  const result = [];
  let index = skipWhitespace(text, field.valueStart + 1);
  while (text[index] !== ']') {
    const end = valueEnd(text, index);
    result.push({start: index, end});
    index = skipWhitespace(text, end);
    if (text[index] === ',') index = skipWhitespace(text, index + 1);
  }
  return result;
}

function arrayProfile(text, field, values, metadata) {
  const items = elements(text, field).map((span, index) => ({index,
    serialized_bytes: byteLength(text.slice(span.start, span.end)), ...metadata(values[index], span)}));
  const serialized_bytes = byteLength(text.slice(field.valueStart, field.end));
  return {serialized_bytes,
    array_overhead_bytes: serialized_bytes - items.reduce((sum, item) => sum + item.serialized_bytes, 0), items};
}

function toolMetadata(value) {
  const name = value?.name;
  return typeof name === 'string' && /^[A-Za-z0-9_.:-]{1,128}$/.test(name) ? {name} : {};
}

function inputMetadata(text, value, span) {
  const result = {role: roles.has(value?.role) ? value.role : 'unassigned',
    type: itemTypes.has(value?.type) ? value.type : value?.type === undefined ? 'unspecified' : 'other'};
  if (value?.type === 'additional_tools') {
    const tools = fields(text, span.start).find(field => field.name === 'tools');
    if (tools) {
      if (!Array.isArray(value.tools)) throw new Error('Prepared request tools must be an array.');
      result.tools = arrayProfile(text, tools, value.tools, toolMetadata);
    }
  }
  return result;
}

export function profilePreparedRequest(text) {
  if (typeof text !== 'string') throw new TypeError('Prepared request must be its original JSON string.');
  if (Buffer.from(text, 'utf8').toString('utf8') !== text)
    throw new Error('Prepared request must contain valid Unicode.');
  let body;
  try { body = JSON.parse(text); }
  catch { throw new Error('Invalid prepared request JSON.'); }
  if (body === null || typeof body !== 'object' || Array.isArray(body))
    throw new Error('Prepared request must be a JSON object.');
  const spans = fields(text);
  const measured = spans.map(field => ({name: field.name,
    serialized_bytes: byteLength(text.slice(field.start, field.end)),
    key_bytes: byteLength(text.slice(field.start, field.keyEnd)),
    separator_bytes: byteLength(text.slice(field.keyEnd, field.valueStart)),
    value_bytes: byteLength(text.slice(field.valueStart, field.end))}));
  const serialized_bytes = byteLength(text);
  const result = {format: 'protean-request-profile/1', serialized_bytes,
    envelope_bytes: serialized_bytes - measured.reduce((sum, field) => sum + field.serialized_bytes, 0),
    fields: measured};
  const tools = spans.find(field => field.name === 'tools');
  if (tools) {
    if (!Array.isArray(body.tools)) throw new Error('Prepared request tools must be an array.');
    result.tools = arrayProfile(text, tools, body.tools, toolMetadata);
  }
  const input = spans.find(field => field.name === 'input');
  if (input) {
    if (Array.isArray(body.input)) {
      result.input = arrayProfile(text, input, body.input, (value, span) => inputMetadata(text, value, span));
      const groups = new Map();
      for (const item of result.input.items) {
        const group = groups.get(item.role) ?? {role: item.role, items: 0, serialized_bytes: 0};
        group.items++;
        group.serialized_bytes += item.serialized_bytes;
        groups.set(item.role, group);
      }
      result.input.roles = [...groups.values()];
    } else if (typeof body.input === 'string') {
      result.input = {serialized_bytes: byteLength(text.slice(input.valueStart, input.end)), kind: 'string'};
    } else throw new Error('Prepared request input must be an array or string.');
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 3) throw new Error('Expected one prepared request JSON file.');
    const bytes = await readFile(process.argv[2]);
    const text = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(bytes);
    process.stdout.write(JSON.stringify(profilePreparedRequest(text), null, 2) + '\n');
  } catch {
    process.stderr.write('Could not profile the prepared request JSON file.\n');
    process.exitCode = 1;
  }
}
