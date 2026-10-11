// Independent wire codec for native archive/capture peers. No JSON client mapping
// or application execution lives here.
// Copyright (c) 2026 Agent contributors. MIT license.
// Pure application values. No process framing, execution, or Kronos internals.
// Wire source: Boundary 2 docs/bpi3-wire.md (profile 1).

const U64_MAX = (1n << 64n) - 1n;
const U32_MAX = (1n << 32n) - 1n;
const SAFE_MAX = BigInt(Number.MAX_SAFE_INTEGER);
const encoder = new TextEncoder();
// ignoreBOM preserves a leading U+FEFF; the protocol performs no normalization.
const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const scalarNames = ['unit', 'boolean', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'bytes', 'text'];
const compositeNames = ['product', 'sum', 'seq', 'vector', 'array', 'bounded_bytes', 'bounded_text', 'enumeration'];
const schemaTags = { product: 12, sum: 13, seq: 14, vector: 15, array: 17, bounded_bytes: 18, bounded_text: 19, enumeration: 20 };

export class ValueCodecError extends Error {
  constructor(code, message) { super(message); this.name = 'ValueCodecError'; this.code = code; }
}
function fail(code, message) { throw new ValueCodecError(code, message); }
function invalid(message) { fail('InvalidValue', message); }
function schemaError(message) { fail('InvalidSchema', message); }
function exactKeys(value, keys, error = invalid) {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(value))) error('Expected a plain record');
  const actual = Reflect.ownKeys(value);
  if (actual.length !== keys.length || actual.some(key => !keys.includes(key))) error(`Expected exactly these fields: ${keys.join(', ')}`);
  for (const key of actual) if (!Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value')) error('Accessor properties are not value data');
}
function integer(value, error = invalid) {
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number' && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === 'string' && /^-?(0|[1-9][0-9]*)$/.test(value)) return BigInt(value);
  error('Expected an exact integer (BigInt, safe integer, or decimal string)');
}
function natural(value, error = invalid) {
  const n = integer(value, error);
  if (n < 0n || n > U64_MAX) error('Unsigned integer is outside u64');
  return n;
}
function number(n) { return n <= SAFE_MAX ? Number(n) : n; }
function utf8(value, error = invalid) {
  if (typeof value !== 'string') error('Expected text');
  // TextEncoder otherwise replaces unpaired UTF-16 surrogates silently.
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) error('Invalid UTF-16 surrogate pair');
    } else if (c >= 0xdc00 && c <= 0xdfff) error('Unpaired UTF-16 surrogate');
  }
  return encoder.encode(value);
}
function byteArray(value) {
  if (value instanceof Uint8Array) return value;
  if (!Array.isArray(value)) invalid('Expected bytes as Uint8Array or an array');
  const result = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i++) {
    const byte = integer(value[i]);
    if (byte < 0n || byte > 255n) invalid('Byte is outside u8');
    result[i] = Number(byte);
  }
  return result;
}

// This is a configurable embedding allocation budget, not a portable schema
// bound. Exceeding it reports ValueCapacity, never invalidity of the value.
function budget(options = {}) {
  exactKeys(options, Object.keys(options));
  if (Object.keys(options).some(key => key !== 'maxNodes')) invalid('Unknown value codec option');
  const maximum = options.maxNodes ?? 1_000_000;
  if (!Number.isSafeInteger(maximum) || maximum < 1) invalid('maxNodes must be a positive safe integer');
  let count = 0;
  return (amount = 1) => {
    if (!Number.isSafeInteger(amount) || amount < 0 || amount > maximum - count) fail('ValueCapacity', 'Value exceeds configured host materialization capacity (maxNodes)');
    count += amount;
  };
}

class Writer {
  chunks = [];
  length = 0;
  put(bytes) {
    if (!Number.isSafeInteger(this.length + bytes.length)) fail('ValueCapacity', 'Encoded value exceeds host addressable capacity');
    this.chunks.push(bytes); this.length += bytes.length;
  }
  nat(value) {
    let remaining = natural(value);
    const bytes = [];
    do { let byte = Number(remaining & 127n); remaining >>= 7n; if (remaining) byte |= 128; bytes.push(byte); } while (remaining);
    this.put(Uint8Array.from(bytes));
  }
  fixed(value, width) {
    let remaining = BigInt.asUintN(width * 8, value);
    const bytes = new Uint8Array(width);
    for (let i = 0; i < width; i++) { bytes[i] = Number(remaining & 255n); remaining >>= 8n; }
    this.put(bytes);
  }
  finish() {
    let result;
    try { result = new Uint8Array(this.length); } catch (error) { if (error instanceof RangeError) fail('ValueCapacity', 'Encoded value exceeds host byte capacity'); throw error; }
    let at = 0;
    for (const bytes of this.chunks) { result.set(bytes, at); at += bytes.length; }
    return result;
  }
}
class Reader {
  constructor(bytes) { if (!(bytes instanceof Uint8Array)) invalid('Wire input must be Uint8Array'); this.bytes = bytes; this.position = 0; }
  take(length) {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.bytes.length - this.position) fail('Truncated', 'Wire length exceeds remaining bytes');
    const result = this.bytes.subarray(this.position, this.position + length);
    this.position += length;
    return result;
  }
  byte() { return this.take(1)[0]; }
  nat() {
    let value = 0n;
    for (let i = 0; i < 10; i++) {
      const byte = this.byte();
      if (i === 9 && byte > 1) fail('InvalidLength', 'LEB128 exceeds u64');
      value |= BigInt(byte & 127) << BigInt(i * 7);
      if ((byte & 128) === 0) {
        if (i !== 0 && byte === 0) fail('NonCanonical', 'Overlong LEB128');
        return value;
      }
    }
    fail('InvalidLength', 'LEB128 exceeds ten bytes');
  }
  fixed(width) {
    const bytes = this.take(width);
    let value = 0n;
    for (let i = width - 1; i >= 0; i--) value = (value << 8n) | BigInt(bytes[i]);
    return value;
  }
  blob() {
    const length = this.nat();
    if (length > BigInt(this.bytes.length - this.position)) fail('Truncated', 'Wire blob length exceeds remaining bytes');
    return this.take(Number(length));
  }
  ids() {
    const count = this.nat();
    if (count > BigInt(this.bytes.length - this.position)) fail('Truncated', 'Schema count exceeds remaining bytes');
    return Array.from({ length: Number(count) }, () => number(this.nat()));
  }
  finish() { if (this.position !== this.bytes.length) fail('NonCanonical', 'Trailing value bytes'); }
}

/** Minimal u64 LEB128 used by application lengths and sum ordinals. */
export function encodeNatural(value) {
  const writer = new Writer(); writer.nat(value); return writer.finish();
}

/** Decode one minimal u64 LEB128. offset is the next unread byte on return. */
export function decodeNatural(bytes, offset = 0) {
  const reader = new Reader(bytes);
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > bytes.length) invalid('Invalid natural byte offset');
  reader.position = offset;
  const value = reader.nat();
  return { value, offset: reader.position };
}

function kind(type) {
  if (typeof type === 'string') {
    if (!scalarNames.includes(type)) schemaError(`Unsupported scalar schema: ${type}`);
    return type;
  }
  if (type === null || typeof type !== 'object' || Array.isArray(type)) schemaError('Expected a schema declaration');
  const keys = compositeNames.filter(key => Object.hasOwn(type, key));
  if (keys.length !== 1) schemaError('Expected exactly one exportable schema constructor');
  const key = keys[0];
  const metadata = key === 'product' ? 'fields' : key === 'sum' ? 'variants' : key === 'enumeration' ? 'names' : null;
  exactKeys(type, metadata && Object.hasOwn(type, metadata) ? [key, metadata] : [key], schemaError);
  return key;
}
function children(type, name = kind(type)) {
  if (name === 'product' || name === 'sum') return type[name];
  if (name === 'seq') return [type.seq];
  if (name === 'vector' || name === 'array') return [type[name].element];
  return [];
}
function checkNames(names, count) {
  if (!Array.isArray(names) || names.length !== count || names.some(name => typeof name !== 'string') || new Set(names).size !== names.length) schemaError('Field/variant names must be distinct strings matching their schema count');
  for (const name of names) utf8(name, schemaError);
}
function validateDescriptor(descriptor) {
  exactKeys(descriptor, ['root', 'types'], schemaError);
  const { types, root } = descriptor;
  if (!Array.isArray(types) || types.length === 0) schemaError('Expected a nonempty schema catalog');
  if (!Number.isSafeInteger(root) || root < 0 || root >= types.length) schemaError('Invalid root schema reference');
  const names = types.map(kind);
  for (let i = 0; i < types.length; i++) {
    const type = types[i], name = names[i];
    if (name === 'product' || name === 'sum') {
      if (!Array.isArray(type[name]) || (name === 'sum' && type.sum.length === 0)) schemaError('Expected schema references; sums must be nonempty');
      const metadata = name === 'product' ? 'fields' : 'variants';
      if (Object.hasOwn(type, metadata)) checkNames(type[metadata], type[name].length);
    } else if (name === 'vector' || name === 'array') {
      const limit = name === 'vector' ? 'maximum' : 'length';
      exactKeys(type[name], ['element', limit], schemaError);
      natural(type[name][limit], schemaError);
    } else if (name === 'bounded_bytes' || name === 'bounded_text') natural(type[name], schemaError);
    else if (name === 'enumeration') {
      if (!Array.isArray(type.enumeration)) schemaError('Expected enumeration tags');
      let previous = -1n;
      for (const tag of type.enumeration) {
        const current = natural(tag, schemaError);
        if (current > U32_MAX || current <= previous) schemaError('Enumeration tags must be increasing unique u32 values');
        previous = current;
      }
      if (Object.hasOwn(type, 'names')) checkNames(type.names, type.enumeration.length);
    }
    for (const reference of children(type, name)) if (!Number.isSafeInteger(reference) || reference < 0 || reference >= types.length) schemaError('Invalid schema reference');
  }
  // The same least fixed point as public Horos schema admission; a zero
  // width array breaks its size dependency, while a sum needs a finite case.
  const minimum = types.map(() => U64_MAX);
  let changed = true;
  while (changed) {
    changed = false;
    for (let i = 0; i < types.length; i++) {
      const type = types[i], name = names[i];
      let width;
      if (name === 'unit') width = 0n;
      else if (name === 'product') width = type.product.reduce((total, id) => total + minimum[id], 0n);
      else if (name === 'sum') width = type.sum.reduce((low, id) => minimum[id] < low ? minimum[id] : low, U64_MAX) + 1n;
      else if (name === 'array') width = natural(type.array.length) * minimum[type.array.element];
      else if (name === 'enumeration') width = 4n;
      else if (/^[iu](8|16|32|64)$/.test(name)) width = BigInt(Number(name.slice(1)) / 8);
      else width = 1n;
      if (width < minimum[i]) { minimum[i] = width; changed = true; }
    }
  }
  if (minimum.some(width => width === U64_MAX)) schemaError('Schema contains an unproductive or overflowing size cycle');
  return { types, root, names, minimum };
}

function canonicalize(descriptor) {
  const { types, root, names } = validateDescriptor(descriptor);
  let classes = types.map(() => 0);
  for (;;) {
    const seen = new Map();
    const next = types.map((type, i) => {
      const name = names[i];
      const bound = name === 'vector' ? String(natural(type.vector.maximum)) : name === 'array' ? String(natural(type.array.length)) : name.startsWith('bounded_') ? String(natural(type[name])) : '';
      const tags = name === 'enumeration' ? type.enumeration.map(tag => String(natural(tag))) : [];
      const key = JSON.stringify([name, bound, tags, children(type, name).map(id => classes[id])]);
      if (!seen.has(key)) seen.set(key, i);
      return seen.get(key);
    });
    if (next.every((value, i) => value === classes[i])) break;
    classes = next;
  }
  const order = [], map = new Map(), pending = [classes[root]];
  while (pending.length) {
    const id = pending.pop();
    if (map.has(id)) continue;
    map.set(id, order.length); order.push(id);
    const refs = children(types[id], names[id]);
    for (let i = refs.length - 1; i >= 0; i--) pending.push(classes[refs[i]]);
  }
  const ref = id => map.get(classes[id]);
  return { root: 0, types: order.map(id => {
    const type = types[id], name = names[id];
    if (scalarNames.includes(name)) return name;
    if (name === 'product' || name === 'sum') return { [name]: type[name].map(ref) };
    if (name === 'seq') return { seq: ref(type.seq) };
    if (name === 'array' || name === 'vector') {
      const bound = name === 'array' ? 'length' : 'maximum';
      return { [name]: { element: ref(type[name].element), [bound]: number(natural(type[name][bound])) } };
    }
    if (name === 'enumeration') return { enumeration: type.enumeration.map(tag => Number(natural(tag))) };
    return { [name]: number(natural(type[name])) };
  }) };
}

/** Canonical, unframed Horos standalone schema bytes. Labels are not wire data. */
export function encodeSchema(descriptor) {
  const canonical = canonicalize(descriptor), writer = new Writer();
  writer.nat(0); writer.nat(canonical.types.length);
  for (const type of canonical.types) {
    const name = kind(type), scalar = scalarNames.indexOf(name);
    writer.nat(scalar >= 0 ? scalar : schemaTags[name]);
    if (name === 'product' || name === 'sum' || name === 'enumeration') { writer.nat(type[name].length); for (const id of type[name]) writer.nat(id); }
    else if (name === 'seq') writer.nat(type.seq);
    else if (name === 'vector' || name === 'array') { writer.nat(type[name].element); writer.nat(type[name][name === 'vector' ? 'maximum' : 'length']); }
    else if (name.startsWith('bounded_')) writer.nat(type[name]);
  }
  return writer.finish();
}

/** Decode and require the canonical, exportable standalone schema descriptor. */
export function decodeSchema(bytes) {
  const reader = new Reader(bytes), root = reader.nat(), count = reader.nat();
  if (root !== 0n) fail('NonCanonical', 'Standalone schema root must be zero');
  if (count > BigInt(bytes.length - reader.position)) fail('Truncated', 'Schema catalog exceeds remaining bytes');
  const types = [];
  for (let i = 0; i < Number(count); i++) {
    const tag = reader.nat();
    if (tag < 12n) types.push(scalarNames[Number(tag)]);
    else switch (tag) {
      case 12n: types.push({ product: reader.ids() }); break;
      case 13n: types.push({ sum: reader.ids() }); break;
      case 14n: types.push({ seq: number(reader.nat()) }); break;
      case 15n: types.push({ vector: { element: number(reader.nat()), maximum: number(reader.nat()) } }); break;
      case 17n: types.push({ array: { element: number(reader.nat()), length: number(reader.nat()) } }); break;
      case 18n: types.push({ bounded_bytes: number(reader.nat()) }); break;
      case 19n: types.push({ bounded_text: number(reader.nat()) }); break;
      case 20n: types.push({ enumeration: reader.ids() }); break;
      case 16n: schemaError('Internal schemas cannot cross application value boundaries'); break;
      default: schemaError('Unknown schema tag');
    }
  }
  reader.finish();
  const result = { root: 0, types }, canonical = encodeSchema(result);
  if (bytes.length !== canonical.length || bytes.some((byte, i) => byte !== canonical[i])) fail('NonCanonical', 'Schema catalog is not the canonical structural descriptor');
  return result;
}

/** Encode one value. Unit is null; products are arrays or exact named objects;
 * sums are {tag: ordinal, value}; i64/u64 are exact integers, never floats. */
export function encodeValue(descriptor, value, options) {
  const { types, root, names } = validateDescriptor(descriptor);
  const spend = budget(options), writer = new Writer(), active = new WeakSet();
  const pending = [{ id: root, value }];
  while (pending.length) {
    const task = pending.pop();
    if (task.leave) { active.delete(task.leave); continue; }
    if (!task.prepaid) spend();
    const type = types[task.id], name = names[task.id], value = task.value;
    if (name === 'unit') { if (value !== null) invalid('Unit is represented by null'); }
    else if (name === 'boolean') { if (typeof value !== 'boolean') invalid('Expected boolean'); writer.fixed(value ? 1n : 0n, 1); }
    else if (/^[iu](8|16|32|64)$/.test(name)) {
      const bits = Number(name.slice(1)), signed = name[0] === 'i', n = integer(value);
      const min = signed ? -(1n << BigInt(bits - 1)) : 0n, max = (1n << BigInt(signed ? bits - 1 : bits)) - 1n;
      if (n < min || n > max) invalid(`Integer outside ${name}`);
      writer.fixed(n, bits / 8);
    } else if (name === 'enumeration') {
      const tag = natural(value);
      if (!type.enumeration.some(allowed => natural(allowed) === tag)) invalid('Unknown enumeration tag');
      writer.fixed(tag, 4);
    } else if (['bytes', 'text', 'bounded_bytes', 'bounded_text'].includes(name)) {
      const content = name.endsWith('text') ? utf8(value) : byteArray(value);
      if (name.startsWith('bounded_') && BigInt(content.length) > natural(type[name])) invalid('Value exceeds declared byte bound');
      writer.nat(content.length); writer.put(content);
    } else {
      if (value === null || typeof value !== 'object') invalid('Expected an aggregate value');
      if (active.has(value)) invalid('Cyclic native objects are not finite portable values');
      active.add(value); pending.push({ leave: value });
      if (name === 'product') {
        if (type.fields) exactKeys(value, type.fields);
        else if (!Array.isArray(value) || value.length !== type.product.length) invalid('Product field count mismatch');
        spend(type.product.length);
        for (let i = type.product.length - 1; i >= 0; i--) pending.push({ id: type.product[i], value: value[type.fields ? type.fields[i] : i], prepaid: true });
      } else if (name === 'sum') {
        exactKeys(value, ['tag', 'value']);
        const tag = natural(value.tag);
        if (tag >= BigInt(type.sum.length)) invalid('Unknown sum variant');
        writer.nat(tag); pending.push({ id: type.sum[Number(tag)], value: value.value });
      } else {
        if (!Array.isArray(value)) invalid('Expected a sequence array');
        const declaration = type[name], element = name === 'seq' ? declaration : declaration.element;
        if (name === 'array') { if (BigInt(value.length) !== natural(declaration.length)) invalid('Fixed array length mismatch'); }
        else { if (name === 'vector' && BigInt(value.length) > natural(declaration.maximum)) invalid('Vector bound exceeded'); writer.nat(value.length); }
        spend(value.length);
        for (let i = value.length - 1; i >= 0; i--) pending.push({ id: element, value: value[i], prepaid: true });
      }
    }
  }
  return writer.finish();
}

/** Decode one canonical value to detached host data. maxNodes is an explicit
 * host allocation budget (default 1,000,000); ValueCapacity is not invalidity. */
export function decodeValue(descriptor, bytes, options) {
  const { types, root, names, minimum } = validateDescriptor(descriptor), reader = new Reader(bytes), spend = budget(options);
  const result = [], pending = [{ id: root, parent: result, key: 0 }];
  while (pending.length) {
    const task = pending.pop(), type = types[task.id], name = names[task.id];
    if (!task.prepaid) spend();
    let value;
    if (name === 'unit') value = null;
    else if (name === 'boolean') { const n = reader.byte(); if (n > 1) invalid('Invalid boolean byte'); value = n === 1; }
    else if (/^[iu](8|16|32|64)$/.test(name)) {
      const bits = Number(name.slice(1)); value = reader.fixed(bits / 8);
      if (name[0] === 'i') value = BigInt.asIntN(bits, value);
      if (bits !== 64) value = Number(value);
    } else if (name === 'enumeration') {
      const tag = reader.fixed(4);
      if (!type.enumeration.some(allowed => natural(allowed) === tag)) invalid('Unknown enumeration tag');
      value = Number(tag);
    } else if (['bytes', 'text', 'bounded_bytes', 'bounded_text'].includes(name)) {
      const content = reader.blob();
      if (name.startsWith('bounded_') && BigInt(content.length) > natural(type[name])) invalid('Value exceeds declared byte bound');
      if (name.endsWith('text')) { try { value = decoder.decode(content); } catch { fail('InvalidUtf8', 'Malformed UTF-8'); } }
      else value = Uint8Array.from(content);
    } else if (name === 'product') {
      spend(type.product.length);
      value = type.fields ? {} : [];
      for (let i = type.product.length - 1; i >= 0; i--) pending.push({ id: type.product[i], parent: value, key: type.fields ? type.fields[i] : i, prepaid: true });
    } else if (name === 'sum') {
      const tag = reader.nat();
      if (tag >= BigInt(type.sum.length)) invalid('Unknown sum variant');
      value = { tag: Number(tag), value: null };
      pending.push({ id: type.sum[Number(tag)], parent: value, key: 'value' });
    } else {
      const declaration = type[name], element = name === 'seq' ? declaration : declaration.element;
      const count = name === 'array' ? natural(declaration.length) : reader.nat();
      if (name === 'vector' && count > natural(declaration.maximum)) invalid('Vector bound exceeded');
      if (minimum[element] * count > BigInt(bytes.length - reader.position)) fail('Truncated', 'Sequence cannot fit remaining input');
      if (count > SAFE_MAX) fail('ValueCapacity', 'Sequence exceeds host addressable capacity');
      spend(Number(count)); value = [];
      for (let i = Number(count) - 1; i >= 0; i--) pending.push({ id: element, parent: value, key: i, prepaid: true });
    }
    Object.defineProperty(task.parent, task.key, { value, enumerable: true, configurable: true, writable: true });
  }
  reader.finish();
  return result[0];
}

// Iterative JSON parsing preserves integer lexemes and sees duplicate fields
// before object construction. JSON.parse alone cannot provide either guarantee.
