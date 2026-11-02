import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
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
let binaryReady = false;
const groups = [['first'], ['second'], ['third']];
function run(selection = groups, mode = '', selectedGroups) {
  if (!binaryReady) {
    execFileSync(process.env.PROTEAN_ZIG_EXE ?? 'zig', ['test', source, '-Osafe', '--test-no-exec', `-femit-bin=${binary}`], {timeout: 30_000});
    binaryReady = true;
  }
  const args = ['tools/native/qualification_tests.mjs', binary, JSON.stringify(selection)];
  if (selectedGroups !== undefined) args.push(JSON.stringify(selectedGroups));
  const result = spawnSync(process.execPath, args, {
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

test('separate group selections retain complete inventory and execute every selected test once', () => {
  const results = [[0, 2], [1]].map(selection => run(groups, '', selection));
  for (const result of results) {
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /3 tests in complete inventory/);
  }
  const visits = results.map(result => result.stderr).join('');
  for (const name of ['first', 'second', 'third']) assert.equal(visits.split(`visited ${name}\n`).length - 1, 1);
  assert(!results[0].stderr.includes('visited second'));
  assert.match(results[0].stdout, /^2\/2 tests passed across 2 independent groups/);
  assert.match(results[1].stdout, /^1\/1 tests passed across 1 independent groups/);
});

test('selected groups reject invalid selection and defects in the complete partition', () => {
  for (const selection of [[], [0, 0], [3], [-1], [0.5], ['0'], null, {}]) {
    const result = run(groups, '', selection);
    assert.notEqual(result.status, 0);
    assert(!result.stderr.includes('visited '));
  }
  for (const partition of [[['first'], ['second']], [['first'], ['second', 'third'], ['third']], [...groups, ['absent']]]) {
    const result = run(partition, '', [0]);
    assert.notEqual(result.status, 0);
    assert(!result.stderr.includes('visited '));
  }
  for (const mode of ['fail', 'skip', 'log', 'leak', 'exit']) {
    const result = run(groups, mode, [2]);
    assert.notEqual(result.status, 0, mode);
    assert.match(result.stderr, /incomplete Zig test qualification/, mode);
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

function compiledFixture() {
  const root = mkdtempSync(join(directory, 'inputs-'));
  const script = resolve('tools/native/qualification_build.mjs');
  const write = (file, bytes) => {
    mkdirSync(dirname(join(root, file)), {recursive: true});
    writeFileSync(join(root, file), bytes);
  };
  for (const file of ['LICENSE', 'build.zig', 'build_protean.zig', 'build_native.zig', 'build.zig.zon', 'README.md']) write(file, 'fixture\n');
  write('tools/native/qualification_build.mjs', readFileSync(script));
  write('src/root.zig', 'const std = @import(\n    "std",\n);\n');
  write('runtime/native/root.zig', 'const child = @import(\n    "child.zig",\n);\n');
  write('runtime/native/child.zig', 'pub const value = 1;\n');
  write('examples/adaptive/definition.zig', 'const c = @import("protean_contracts",);\nconst text = @embedFile(\n    "instructions.txt",\n);\n');
  write('examples/adaptive/instructions.txt', 'instructions');
  write('examples/adaptive/projection_example.zig', 'pub const value = 1;\n');
  write('test/protean/native_adaptive_tests.zig', 'comptime { _ = @import("adaptive_recovery.zig"); _ = @import("projection_recovery.zig"); }\n');
  write('test/protean/adaptive_recovery.zig', 'const image = @embedFile("adaptive_image");\n');
  write('test/protean/projection_recovery.zig', 'const example = @import("projection_example");\n');
  execFileSync('git', ['init', '--quiet', root]);
  execFileSync('git', ['-C', root, 'add', '.']);
  write('bin/zig', `#!${process.execPath}\nif (process.argv[2] === 'env') process.stdout.write('.{\\n    .target = "x86_64-linux.6.8...6.8-musl",\\n}\\n'); else if (process.argv[2] === 'targets') process.stdout.write('fixture capabilities'); else process.exit(91);\n`);
  const executable = join(root, 'bin/zig');
  execFileSync('chmod', ['+x', executable]);
  const key = (profile, compiler = '1'.repeat(64), options = {}) => execFileSync(process.execPath, [script, 'key', profile, compiler], {
    cwd: root, encoding: 'utf8', timeout: 10_000,
    env: {...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, ...options},
  }).trim();
  return {write, key, read: file => readFileSync(join(root, file), 'utf8')};
}

test('compiled keys accept trailing commas and retain exact profile input dependencies', () => {
  const fixture = compiledFixture();
  const product = fixture.key('product'), adaptive = fixture.key('owner-adaptive-control');
  fixture.write('README.md', 'unrelated prose\n');
  assert.equal(fixture.key('product'), product);
  assert.equal(fixture.key('owner-adaptive-control'), adaptive);
  for (const name of ['adaptive_recovery', 'projection_recovery']) {
    const before = fixture.key('owner-adaptive-control');
    const file = `test/protean/${name}.zig`;
    fixture.write(file, `${fixture.read(file)}\nconst changed = true;\n`);
    assert.equal(fixture.key('product'), product, name);
    assert.notEqual(fixture.key('owner-adaptive-control'), before, name);
  }
  assert.notEqual(fixture.key('owner-adaptive-control'), adaptive);
  for (const file of ['examples/adaptive/projection_example.zig', 'examples/adaptive/instructions.txt', 'runtime/native/child.zig']) {
    const before = ['product', 'owner-adaptive-control'].map(profile => fixture.key(profile));
    fixture.write(file, 'changed content\n');
    for (const [index, profile] of ['product', 'owner-adaptive-control'].entries()) assert.notEqual(fixture.key(profile), before[index], file);
  }
  const current = fixture.key('product');
  assert.notEqual(fixture.key('product', '2'.repeat(64)), current, 'compiler identity');
  assert.notEqual(fixture.key('product', undefined, {CC: 'fixture-distinct-compiler'}), current, 'compiler environment');
});

test('compiled keys conservatively include unknown and dynamic import inputs', () => {
  for (const source of ['const other = @import("unmapped_module");\n', 'const other = @import(name);\n']) {
    const fixture = compiledFixture();
    fixture.write('src/root.zig', source);
    const before = fixture.key('product');
    fixture.write('README.md', 'conservatively retained input\n');
    assert.notEqual(fixture.key('product'), before, source);
  }
});
