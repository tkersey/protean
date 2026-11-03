import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const root = process.env.RUNNER_TEMP + '/candidate/kosmos/src';
const profile = process.env.RUNNER_TEMP + '/profile';
const path = root + '/base/session.zig';
let source = readFileSync(path, 'utf8');
for (const [before, after] of [
    ['    transitions: usize = 0,', '    transitions: usize = 0,\n    diagnostic_token: u64 = 0,'],
    ['        var frame = try self.frames.getForUpdate(current.id);', '        var frame = try self.frames.getForUpdate(current.id);\n        diagnosticEntry(self, current, control.block, &frame);\n        diagnosticSample(self, current);'],
    ['        self.transitions +%= 1;', '        self.transitions +%= 1;\n        diagnosticStep(self);'],
]) {
    assert.equal(source.split(before).length, 2);
    source = source.replace(before, after);
}
source += '\n' + readFileSync('tools/native/diagnostic-field-counters.zig', 'utf8');
writeFileSync(path, source);
writeFileSync(root + '/base/diagnostic_fields.zig', readFileSync('tools/native/diagnostic-field-extractors.zig'));
writeFileSync(root + '/root.zig', readFileSync(root + '/root.zig', 'utf8') +
    '\npub const diagnosticDump = @import("base/session.zig").diagnosticDump;\n');
const testPath = 'test/protean/projection_recovery.zig';
let test = readFileSync(testPath, 'utf8');
const init = '    pub fn init(self: *Fixture) !void {';
assert.equal(test.split(init).length, 2);
test = test.replace(init, init + '\n        defer @import("kosmos").diagnosticDump();');
writeFileSync(testPath, test);
const lines = readFileSync(profile + '/build.log', 'utf8').split('\n').filter(line =>
    line.startsWith('info(verbose): ') && line.includes('zig test ') &&
    line.includes('-Mroot=test/protean/native_adaptive_tests.zig'));
assert.equal(lines.length, 1);
const command = lines[0].slice('info(verbose): '.length).trim().split(/\s+/)
    .filter(arg => arg !== '--listen=-');
assert(command.includes('-fno-llvm') && command.includes('-Osafe'));
const selected = '-Mkosmos=.protean-native/inputs/kosmos/src/root.zig';
assert.equal(command.filter(arg => arg === selected).length, 1);
command[command.indexOf(selected)] = '-Mkosmos=' + root + '/root.zig';
command.push('--test-no-exec', '-femit-bin=' + profile + '/native-owner-adaptive-fields');
writeFileSync(profile + '/fields-command.json', JSON.stringify(command));
writeFileSync(profile + '/fields-session.zig', source);
writeFileSync(profile + '/diagnostic_fields.zig', readFileSync(root + '/base/diagnostic_fields.zig'));
if (!process.env.DIAGNOSTIC_VALIDATE_ONLY) {
    const result = spawnSync(command[0], command.slice(1), {stdio: 'inherit'});
    if (result.error) throw result.error;
    process.exit(result.status ?? 1);
}
