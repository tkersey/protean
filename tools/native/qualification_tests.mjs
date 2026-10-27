import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';

const [executable, encodedGroups] = process.argv.slice(2);
const groups = JSON.parse(encodedGroups);
assert(groups.length > 0 && groups.every(group => group.length > 0 && group.every(filter => typeof filter === 'string' && filter.length > 0)));

async function* frames(stream) {
  let pending = Buffer.alloc(0);
  for await (const chunk of stream) {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 8) {
      const size = pending.readUInt32LE(4);
      if (pending.length < 8 + size) break;
      yield {tag: pending.readUInt32LE(0), body: pending.subarray(8, 8 + size)};
      pending = pending.subarray(8 + size);
    }
  }
  assert.equal(pending.length, 0, 'truncated Zig test message');
}

function client() {
  const child = spawn(executable, ['--listen=-'], {stdio: ['pipe', 'pipe', 'pipe']});
  const messages = frames(child.stdout)[Symbol.asyncIterator]();
  child.stderr.pipe(process.stderr, {end: false});
  let writeError;
  child.stdin.on('error', error => {
    writeError = error;
    child.kill();
  });
  const closed = new Promise(resolve => {
    child.once('error', error => resolve({error}));
    child.once('close', (code, signal) => resolve({code, signal}));
  });
  async function send(tag, body = Buffer.alloc(0)) {
    const header = Buffer.alloc(8);
    header.writeUInt32LE(tag);
    header.writeUInt32LE(body.length, 4);
    await new Promise((resolve, reject) => child.stdin.write(Buffer.concat([header, body]), error => error ? reject(error) : resolve()));
  }
  async function receive(tag) {
    const next = await messages.next();
    if (next.done && writeError) throw writeError;
    assert(!next.done, `Zig test process ended before message ${tag}`);
    assert.equal(next.value.tag, tag, 'unexpected Zig test message');
    return next.value.body;
  }
  async function metadata() {
    assert.equal((await receive(0)).toString(), '0.17.0');
    await send(4);
    const body = await receive(3);
    const stringBytes = body.readUInt32LE(0), count = body.readUInt32LE(4);
    assert.equal(body.length, 8 + count * 8 + stringBytes);
    const strings = body.subarray(8 + count * 8);
    return Array.from({length: count}, (_, index) => {
      const offset = body.readUInt32LE(8 + index * 4), end = strings.indexOf(0, offset);
      assert(offset < strings.length && end >= offset);
      return strings.subarray(offset, end).toString();
    });
  }
  async function run(indices, names) {
    let passed = 0;
    for (const index of indices) {
      const request = Buffer.alloc(4);
      request.writeUInt32LE(index);
      await send(5, request);
      assert.equal((await receive(5)).length, 0);
      const result = await receive(4);
      assert.equal(result.length, 12);
      assert.equal(result.readUInt32LE(0), index);
      const flags = result.readBigUInt64LE(4);
      if ((flags & ~4n) === 0n) passed += 1;
      else process.stderr.write(`Failed Zig test ${names[index]}: flags=${flags}\n`);
    }
    await send(0);
    const exit = await closed;
    assert.equal(exit.code, 0, `Zig test process failed: ${exit.error ?? exit.signal}`);
    return passed;
  }
  return {child, closed, metadata, run};
}

const clients = groups.map(() => client());
const stop = () => { for (const {child} of clients) if (child.exitCode === null) child.kill(); };
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
  stop();
  process.exit(signal === 'SIGINT' ? 130 : 143);
});
try {
  const inventories = await Promise.all(clients.map(value => value.metadata()));
  const names = inventories[0];
  for (const inventory of inventories) assert.deepEqual(inventory, names);
  const partitions = groups.map(() => []);
  for (let index = 0; index < names.length; index += 1) {
    const selected = groups.flatMap((filters, group) => filters.some(filter => names[index].includes(filter)) ? [group] : []);
    assert.equal(selected.length, 1, `Zig test must belong to exactly one group: ${names[index]}`);
    partitions[selected[0]].push(index);
  }
  assert(partitions.every(indices => indices.length > 0), 'empty Zig test group');
  const results = await Promise.allSettled(clients.map((value, group) => value.run(partitions[group], names)));
  for (const result of results) if (result.status === 'rejected') process.stderr.write(`${result.reason}\n`);
  const passed = results.reduce((sum, result) => sum + (result.status === 'fulfilled' ? result.value : 0), 0);
  process.stdout.write(`${passed}/${names.length} tests passed across ${groups.length} independent groups.\n`);
  assert(results.every(result => result.status === 'fulfilled') && passed === names.length, 'incomplete Zig test qualification');
} finally {
  stop();
  await Promise.all(clients.map(value => value.closed));
}
