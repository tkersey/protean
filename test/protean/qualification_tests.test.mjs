import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test, {after} from 'node:test';

const directory = mkdtempSync(join(tmpdir(), 'protean-qualification-tests-'));
after(() => rmSync(directory, {recursive: true, force: true}));
const source = join(directory, 'fixture.zig'), binary = join(directory, 'fixture');
writeFileSync(source, `
const std = @import("std");
test "first" {
    std.debug.print("visited first\\n", .{});
    const mode = std.testing.environ.getPosix("PROTEAN_QUALIFICATION_TEST_MODE") orelse "";
    if (std.mem.eql(u8, mode, "close-input")) std.Io.File.stdin().close(std.testing.io);
}
test "second" { std.debug.print("visited second\\n", .{}); }
test "third" {
    std.debug.print("visited third\\n", .{});
    const mode = std.testing.environ.getPosix("PROTEAN_QUALIFICATION_TEST_MODE") orelse "";
    if (std.mem.eql(u8, mode, "fail")) return error.IntentionalFailure;
    if (std.mem.eql(u8, mode, "skip")) return error.SkipZigTest;
    if (std.mem.eql(u8, mode, "log")) std.log.err("intentional logged error", .{});
    if (std.mem.eql(u8, mode, "leak")) _ = try std.testing.allocator.alloc(u8, 1);
    if (std.mem.eql(u8, mode, "exit")) std.process.exit(7);
}
`);
execFileSync(process.env.PROTEAN_ZIG_EXE ?? 'zig', ['test', source, '-Osafe', '--test-no-exec', `-femit-bin=${binary}`], {timeout: 30_000});
const groups = [['first'], ['second'], ['third']];
function run(selection = groups, mode = '') {
  const result = spawnSync(process.execPath, ['tools/native/qualification_tests.mjs', binary, JSON.stringify(selection)], {
    encoding: 'utf8', timeout: 10_000,
    env: {...process.env, PROTEAN_QUALIFICATION_TEST_MODE: mode},
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

test('qualification executes every real Zig test exactly once across independent processes', () => {
  const result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^3\/3 tests passed across 3 independent groups\./);
  for (const name of ['first', 'second', 'third']) assert.equal(result.stderr.split(`visited ${name}\n`).length - 1, 1);
});

test('qualification rejects omissions overlaps and empty groups before execution', () => {
  for (const selection of [[['first'], ['second']], [['first', 'second'], ['second', 'third']], [...groups, ['absent']]]) {
    const result = run(selection);
    assert.notEqual(result.status, 0);
    assert(!result.stderr.includes('visited '));
  }
});

test('failed skipped logged leaked and interrupted Zig tests cannot pass qualification', () => {
  for (const mode of ['fail', 'skip', 'log', 'leak', 'exit']) {
    const result = run(groups, mode);
    assert.notEqual(result.status, 0, mode);
    assert.match(result.stderr, /incomplete Zig test qualification/, mode);
  }
});

test('a closed test input pipe fails through awaited process cleanup', () => {
  const result = run([['first', 'second'], ['third']], 'close-input');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /incomplete Zig test qualification/);
  assert(!result.stderr.includes("Unhandled 'error' event"));
});
