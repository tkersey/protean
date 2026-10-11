import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodeNatural, encodeNatural, decodeValue, encodeValue, decodeSchema, encodeSchema, ValueCodecError } from '../support/values.mjs';

const schema = type => ({ root: 0, types: [type] });
const hex = bytes => Buffer.from(bytes).toString('hex');
const bytes = text => Uint8Array.from(Buffer.from(text, 'hex'));
function rejects(code, callback) { assert.throws(callback, error => error instanceof ValueCodecError && error.code === code); }

test('primitive values use canonical Horos bytes, exact integers, and detached data', () => {
  const vectors = [
    ['unit', null, ''], ['boolean', true, '01'], ['boolean', false, '00'],
    ['i8', -128, '80'], ['i16', -32768, '0080'], ['i32', -2147483648, '00000080'],
    ['i64', -(1n << 63n), '0000000000000080'],
    ['u8', 255, 'ff'], ['u16', 65535, 'ffff'], ['u32', 4294967295, 'ffffffff'],
    ['u64', (1n << 64n) - 1n, 'ffffffffffffffff'],
    ['text', 'é😀', '06c3a9f09f9880'], ['text', '\ufeffA', '04efbbbf41'],
    ['bytes', Uint8Array.of(0, 255), '0200ff'],
  ];
  for (const [type, value, expected] of vectors) {
    assert.equal(hex(encodeValue(schema(type), value)), expected, type);
    assert.deepEqual(decodeValue(schema(type), bytes(expected)), value, type);
  }
  assert.equal(hex(encodeValue(schema('u64'), '18446744073709551615')), 'ffffffffffffffff');
  const input = bytes('0200ff'), decoded = decodeValue(schema('bytes'), input);
  decoded[0] = 8;
  assert.equal(hex(input), '0200ff');
});

test('integer ranges and types reject instead of truncating or coercing', () => {
  for (const [type, value] of [['u8', -1], ['u8', 256], ['i8', -129], ['i8', 128], ['u64', 1n << 64n], ['i64', 1n << 63n], ['u64', 9007199254740992], ['u32', 1.5], ['u8', true], ['u8', '1e2'], ['u8', '01']]) {
    rejects('InvalidValue', () => encodeValue(schema(type), value));
  }
  rejects('InvalidValue', () => encodeValue(schema('boolean'), 1));
  rejects('InvalidValue', () => decodeValue(schema('boolean'), bytes('02')));
  rejects('InvalidValue', () => encodeValue(schema('unit'), undefined));
  rejects('Truncated', () => decodeValue(schema('u64'), bytes('00')));
  rejects('NonCanonical', () => decodeValue(schema('unit'), bytes('00')));
});

test('ULEB naturals distinguish overlong, overflowing and truncated inputs', () => {
  for (const n of [0n, 127n, 128n, 16384n, (1n << 64n) - 1n]) {
    const encoded = encodeNatural(n), input = Uint8Array.from([77, ...encoded, 88]);
    assert.deepEqual(decodeNatural(input, 1), { value: n, offset: encoded.length + 1 });
  }
  assert.equal(hex(encodeNatural(128)), '8001');
  rejects('NonCanonical', () => decodeNatural(bytes('8000')));
  rejects('InvalidLength', () => decodeNatural(bytes('ffffffffffffffffff02')));
  rejects('InvalidLength', () => decodeNatural(bytes('ffffffffffffffffff81')));
  rejects('Truncated', () => decodeNatural(bytes('80')));
  rejects('InvalidValue', () => encodeNatural(-1));
  rejects('InvalidValue', () => encodeNatural(1n << 64n));
  rejects('InvalidValue', () => decodeNatural(bytes('00'), -1));
});

test('UTF-8 is strict, byte-bounded, and preserves BOM and normalization form', () => {
  for (const text of ['\ud800', '\udfff', 'x\ud800y']) rejects('InvalidValue', () => encodeValue(schema('text'), text));
  for (const wire of ['02c080', '03eda080', '04f4908080', '01ff']) rejects('InvalidUtf8', () => decodeValue(schema('text'), bytes(wire)));
  assert.equal(hex(encodeValue(schema({ bounded_text: 2 }), 'é')), '02c3a9');
  rejects('InvalidValue', () => encodeValue(schema({ bounded_text: 1 }), 'é'));
  rejects('InvalidValue', () => decodeValue(schema({ bounded_text: 1 }), bytes('02c3a9')));
  rejects('InvalidValue', () => encodeValue(schema({ bounded_bytes: 1 }), [1, 2]));
  rejects('InvalidValue', () => encodeValue(schema('bytes'), [256]));
  rejects('InvalidValue', () => encodeValue(schema('bytes'), [-1]));
  rejects('InvalidValue', () => encodeValue(schema('bytes'), [1.2]));
  rejects('Truncated', () => decodeValue(schema('text'), bytes('0361')));
  rejects('NonCanonical', () => decodeValue(schema('text'), bytes('8000')));
  assert.equal(decodeValue(schema('text'), encodeValue(schema('text'), 'e\u0301')), 'e\u0301');
});

test('products, ordinal sums, bounded sequences and fixed arrays have distinct encodings', () => {
  const descriptor = { root: 0, types: [{ product: [1, 2, 3, 4], fields: ['question', 'answer', 'alternatives', 'flags'] }, 'text', { sum: [5, 6], variants: ['none', 'some'] }, { vector: { element: 6, maximum: 3 } }, { array: { element: 7, length: 2 } }, 'unit', 'u16', 'boolean'] };
  const value = { question: 'Q', answer: { tag: 1, value: 513 }, alternatives: [1, 2], flags: [true, false] };
  assert.equal(hex(encodeValue(descriptor, value)), '015101010202010002000100');
  assert.deepEqual(decodeValue(descriptor, encodeValue(descriptor, value)), value);
  rejects('InvalidValue', () => encodeValue(descriptor, { ...value, extra: null }));
  rejects('InvalidValue', () => encodeValue(descriptor, { ...value, flags: [true] }));
  rejects('InvalidValue', () => encodeValue(descriptor, { ...value, alternatives: [1, 2, 3, 4] }));
  rejects('InvalidValue', () => encodeValue(descriptor, { ...value, answer: { tag: 2, value: null } }));
  rejects('InvalidValue', () => encodeValue(descriptor, { ...value, answer: { tag: 0, value: null, extra: 1 } }));
  const noNames = { root: 0, types: [{ product: [1, 1] }, 'u8'] };
  assert.deepEqual(decodeValue(noNames, bytes('0102')), [1, 2]);
  rejects('InvalidValue', () => encodeValue(noNames, [1]));
  rejects('InvalidValue', () => encodeValue(noNames, { 0: 1, 1: 2 }));
  const seq = { root: 0, types: [{ seq: 1 }, 'u8'] };
  assert.equal(hex(encodeValue(seq, Array(128).fill(3))).slice(0, 4), '8001');
});

test('enumerations retain explicit u32 tags, including an empty domain', () => {
  const descriptor = schema({ enumeration: [0, 128, 4294967295], names: ['first', 'middle', 'last'] });
  assert.equal(hex(encodeValue(descriptor, 128)), '80000000');
  assert.equal(decodeValue(descriptor, bytes('ffffffff')), 4294967295);
  rejects('InvalidValue', () => encodeValue(descriptor, 1));
  rejects('InvalidValue', () => decodeValue(descriptor, bytes('01000000')));
  rejects('InvalidValue', () => encodeValue(schema({ enumeration: [] }), 0));
  rejects('InvalidSchema', () => encodeSchema(schema({ enumeration: [4, 4] })));
  rejects('InvalidSchema', () => encodeSchema(schema({ enumeration: [2, 1] })));
  rejects('InvalidSchema', () => encodeSchema(schema({ enumeration: [1n << 32n] })));
});

test('schema bytes use reachable structural canonicalization and depth-first IDs', () => {
  const a = { root: 0, types: [{ product: [1, 2], fields: ['left', 'right'] }, 'u64', 'u64'] };
  const b = { root: 1, types: ['u64', { product: [0, 0] }] };
  assert.equal(hex(encodeSchema(a)), '00020c02010109');
  assert.deepEqual(encodeSchema(a), encodeSchema(b));
  assert.deepEqual(decodeSchema(encodeSchema(a)), { root: 0, types: [{ product: [1, 1] }, 'u64'] });
  const withUnreachable = { root: 1, types: ['text', 'boolean'] };
  assert.equal(hex(encodeSchema(withUnreachable)), '000101');
  rejects('NonCanonical', () => decodeSchema(bytes('00020c0201010900')));
  rejects('NonCanonical', () => decodeSchema(bytes('010109')));
  rejects('NonCanonical', () => decodeSchema(bytes('00020109')));
  rejects('NonCanonical', () => decodeSchema(bytes('00030c0201020909')));
  rejects('NonCanonical', () => decodeSchema(bytes('80000100')));
  rejects('InvalidSchema', () => decodeSchema(bytes('000110')));
  rejects('InvalidSchema', () => decodeSchema(bytes('000115')));
  rejects('InvalidSchema', () => encodeSchema({ root: 0, types: [{ internal: 'capability' }] }));
  rejects('InvalidSchema', () => encodeSchema({ root: 0, types: [{ product: [4] }] }));
  rejects('InvalidSchema', () => encodeSchema({ root: 0, types: [{ sum: [] }] }));
});

test('recursive definitions merge by bisimulation and finite values need no native recursion', () => {
  const descriptor = { root: 0, types: [{ sum: [1, 2] }, 'unit', { product: [3, 0] }, 'u8'] };
  const duplicate = { root: 0, types: [{ sum: [1, 2] }, 'unit', { product: [3, 4] }, 'u8', { sum: [1, 2] }] };
  assert.deepEqual(encodeSchema(descriptor), encodeSchema(duplicate));
  assert.deepEqual(decodeSchema(encodeSchema(descriptor)), descriptor);
  let value = { tag: 0, value: null };
  for (let i = 0; i < 5_000; i++) value = { tag: 1, value: [i % 256, value] };
  const encoded = encodeValue(descriptor, value), decoded = decodeValue(descriptor, encoded);
  assert.deepEqual(encodeValue(descriptor, decoded), encoded);
  assert.equal(encoded.length, 10_001);
  const cyclic = { tag: 1, value: [1, null] }; cyclic.value[1] = cyclic;
  rejects('InvalidValue', () => encodeValue(descriptor, cyclic));
  rejects('InvalidSchema', () => encodeSchema({ root: 0, types: [{ product: [0] }] }));
  rejects('InvalidSchema', () => encodeSchema({ root: 0, types: [{ sum: [0] }] }));
  const emptyArray = { root: 0, types: [{ array: { element: 0, length: 0 } }] };
  assert.deepEqual(decodeValue(emptyArray, new Uint8Array()), []);
  assert.deepEqual(decodeSchema(encodeSchema(emptyArray)), emptyArray);
});

test('host materialization limits do not label well-typed zero-width sequences invalid', () => {
  const descriptor = { root: 0, types: [{ seq: 1 }, 'unit'] };
  rejects('ValueCapacity', () => decodeValue(descriptor, encodeNatural((1n << 64n) - 1n)));
  rejects('ValueCapacity', () => decodeValue(descriptor, bytes('03'), { maxNodes: 3 }));
  assert.deepEqual(decodeValue(descriptor, bytes('03'), { maxNodes: 4 }), [null, null, null]);
  rejects('ValueCapacity', () => encodeValue(descriptor, [null, null, null], { maxNodes: 3 }));
  assert.equal(hex(encodeValue(descriptor, [null, null, null], { maxNodes: 4 })), '03');
  rejects('InvalidValue', () => decodeValue(descriptor, bytes('00'), { maxNodes: 0 }));
  rejects('InvalidValue', () => decodeValue(descriptor, bytes('00'), { unknown: 100 }));
  const vector = { root: 0, types: [{ vector: { element: 1, maximum: 2 } }, 'unit'] };
  rejects('InvalidValue', () => decodeValue(vector, bytes('03')));
  rejects('Truncated', () => decodeValue({ root: 0, types: [{ seq: 1 }, 'u64'] }, bytes('0200')));
});

test('schema bounds retain u64 precision, including equivalent declared bounds', () => {
  const descriptor = { root: 0, types: [{ product: [1, 2, 3, 4, 5] }, { vector: { element: 6, maximum: (1n << 64n) - 1n } }, { array: { element: 6, length: 0 } }, { bounded_bytes: '18446744073709551615' }, { bounded_text: 0 }, { bounded_text: '-0' }, 'unit'] };
  const decoded = decodeSchema(encodeSchema(descriptor));
  assert.equal(decoded.types.filter(type => type?.bounded_text === 0).length, 1);
  const bounded = decoded.types.find(type => type?.bounded_bytes !== undefined);
  assert.equal(bounded.bounded_bytes, (1n << 64n) - 1n);
  assert.deepEqual(encodeSchema(decoded), encodeSchema(descriptor));
});

test('pure JS codecs match independent Zig/public Horos schema and value bytes', () => {
  const { envelope } = JSON.parse(readFileSync(new URL('./values-vectors.json', import.meta.url), 'utf8'));
  const schemaBytes = Uint8Array.from(envelope.schemaBytes), valueBytes = Uint8Array.from(envelope.valueBytes);
  const descriptor = decodeSchema(schemaBytes);
  assert.deepEqual(encodeSchema(descriptor), schemaBytes);
  assert.deepEqual(encodeValue(descriptor, envelope.value), valueBytes);
  const expected = [...envelope.value]; expected[1] = BigInt(expected[1]); expected[7] = Uint8Array.from(expected[7]);
  assert.deepEqual(decodeValue(descriptor, valueBytes), expected);
});
