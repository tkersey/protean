import assert from 'node:assert/strict';
import test from 'node:test';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {profilePreparedRequest} from '../../tools/evaluation/request_profile.mjs';

const execute = promisify(execFile);
const bytes = value => Buffer.byteLength(value, 'utf8');

test('request partitions preserve exact delimiters, whitespace, escapes and multibyte bytes', () => {
  const first = String.raw`{"role":"user","content":"é😀\" private prompt"}`;
  const second = String.raw`{"type":"function_call_output","call_id":"1","output":"line\n\u03bb"}`;
  const tool = '{"type":"function","name":"read","description":"private description café","parameters":{"type":"object"}}';
  const input = `[ ${first},\n${second} ]`, tools = `[${tool}]`;
  const raw = ` \n{ "input" : ${input}, "tools" : ${tools}, "seed":18446744073709551615 }\t`;
  const profile = profilePreparedRequest(raw);
  assert.equal(profile.serialized_bytes, bytes(raw));
  assert.equal(profile.envelope_bytes, 11);
  assert.deepEqual(profile.fields, [
    {name: 'input', serialized_bytes: bytes(input) + 10, key_bytes: 7, separator_bytes: 3, value_bytes: bytes(input)},
    {name: 'tools', serialized_bytes: bytes(tools) + 10, key_bytes: 7, separator_bytes: 3, value_bytes: bytes(tools)},
    {name: 'seed', serialized_bytes: 27, key_bytes: 6, separator_bytes: 1, value_bytes: 20},
  ]);
  assert.deepEqual(profile.input.items, [
    {index: 0, serialized_bytes: bytes(first), role: 'user', type: 'unspecified'},
    {index: 1, serialized_bytes: bytes(second), role: 'unassigned', type: 'function_call_output'},
  ]);
  assert.equal(profile.input.array_overhead_bytes, 6);
  assert.deepEqual(profile.input.roles, [
    {role: 'user', items: 1, serialized_bytes: bytes(first)},
    {role: 'unassigned', items: 1, serialized_bytes: bytes(second)},
  ]);
  assert.deepEqual(profile.tools, {serialized_bytes: bytes(tools), array_overhead_bytes: 2,
    items: [{index: 0, serialized_bytes: bytes(tool), name: 'read'}]});
  assert.equal(profile.envelope_bytes + profile.fields.reduce((sum, field) => sum + field.serialized_bytes, 0), bytes(raw));
  for (const field of profile.fields)
    assert.equal(field.key_bytes + field.separator_bytes + field.value_bytes, field.serialized_bytes);
  for (const partition of [profile.input, profile.tools])
    assert.equal(partition.array_overhead_bytes + partition.items.reduce((sum, item) => sum + item.serialized_bytes, 0), partition.serialized_bytes);
  const rendered = JSON.stringify(profile);
  for (const secret of ['private prompt', 'private description', 'café', 'é', '😀', '18446744073709551615'])
    assert.equal(rendered.includes(secret), false);
});

test('numeric spelling and escaped keys are measured without parse and stringify normalization', () => {
  const raw = String.raw`{"\u0069nput":[],"tools":[],"seed":18446744073709551615,"temperature":-0.000e+12}`;
  const profile = profilePreparedRequest(raw);
  assert.equal(profile.serialized_bytes, bytes(raw));
  assert.equal(profile.fields[0].name, 'input');
  assert.equal(profile.fields[0].key_bytes, 12);
  assert.equal(profile.fields.find(field => field.name === 'seed').value_bytes, 20);
  assert.equal(profile.fields.find(field => field.name === 'temperature').value_bytes, 10);
  assert.notEqual(profile.serialized_bytes, bytes(JSON.stringify(JSON.parse(raw))));
  assert.deepEqual(profile.input, {serialized_bytes: 2, array_overhead_bytes: 2, items: [], roles: []});
  assert.deepEqual(profile.tools, {serialized_bytes: 2, array_overhead_bytes: 2, items: []});
});

test('nested structures and delimiter characters inside strings do not split measurements', () => {
  const tool = String.raw`{"name":"query","parameters":{"items":[{"enum":["}","[",",","\\\""]}]}}`;
  const input = '{"role":"developer","content":[{"type":"input_text","text":"[[{\\\""}]}';
  const raw = `{"tools":[${tool}],"input":[${input},${input}]}`;
  const profile = profilePreparedRequest(raw);
  assert.deepEqual(profile.tools.items, [{index: 0, serialized_bytes: bytes(tool), name: 'query'}]);
  assert.deepEqual(profile.input.roles, [{role: 'developer', items: 2, serialized_bytes: bytes(input) * 2}]);
  assert.equal(profile.input.array_overhead_bytes, 3);
  assert.equal(profile.envelope_bytes, 3);
});

test('absent arrays and direct string input retain exact byte measurements', () => {
  assert.deepEqual(profilePreparedRequest(' \n{}\t'), {format: 'protean-request-profile/1',
    serialized_bytes: 5, envelope_bytes: 5, fields: []});
  const raw = String.raw`{"input":"private\n😀"}`;
  const profile = profilePreparedRequest(raw);
  assert.deepEqual(profile.input, {kind: 'string', serialized_bytes: bytes(String.raw`"private\n😀"`)});
  assert.equal(JSON.stringify(profile).includes('private'), false);
});

test('invalid requests fail without quoting private input or accepting duplicate fields', () => {
  for (const raw of ['{"input":"secret', 'null', '[]', '{"tools":false}', '{"input":{}}',
    '{"input":[],"input":[]}', String.raw`{"input":[],"\u0069nput":[]}`, '\ud800']) {
    assert.throws(() => profilePreparedRequest(raw), error => !error.message.includes('secret'));
  }
  assert.throws(() => profilePreparedRequest({input: []}), /original JSON string/);
});

test('CLI returns only a profile and refuses invalid UTF-8 or a discarded byte-order mark', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'protean-request-profile-'));
  const script = fileURLToPath(new URL('../../tools/evaluation/request_profile.mjs', import.meta.url));
  try {
    const input = join(directory, 'request.json');
    const raw = '{"input":"private input 😀","tools":[]}';
    await writeFile(input, raw);
    const result = await execute(process.execPath, [script, input]);
    assert.deepEqual(JSON.parse(result.stdout), profilePreparedRequest(raw));
    assert.equal(result.stderr, '');
    assert.equal(result.stdout.includes('private input'), false);
    for (const invalid of [Buffer.from([123, 34, 105, 110, 112, 117, 116, 34, 58, 34, 255, 34, 125]),
      Buffer.concat([Buffer.from([239, 187, 191]), Buffer.from(raw)])]) {
      await writeFile(input, invalid);
      await assert.rejects(execute(process.execPath, [script, input]), error =>
        error.code === 1 && error.stdout === '' && error.stderr === 'Could not profile the prepared request JSON file.\n');
    }
  } finally { await rm(directory, {recursive: true, force: true}); }
});
