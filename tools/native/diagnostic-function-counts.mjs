import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';

const root = process.env.RUNNER_TEMP + '/candidate/kosmos/src';
const profile = process.env.RUNNER_TEMP + '/profile';
const sessionPath = root + '/base/session.zig';
let source = readFileSync(sessionPath, 'utf8');
const increment = '        self.transitions +%= 1;';
assert.equal(source.split(increment).length, 2);
source = source.replace(increment, increment + '\n        diagnosticStep(&self.program_identity, code.function);');
const code = '        const code = self.program.blocks[@intCast(control.block)];';
assert.equal(source.split(code).length, 2);
source = source.replace(code, code + '\n        diagnosticSample(self, code.function, control.parent);');
source += String.raw`
const diagnostic_identity = [_]u8{
    0xaf, 0x7a, 0x66, 0x48, 0x74, 0xcb, 0xad, 0xac,
    0x0c, 0x75, 0x5d, 0x45, 0x79, 0x12, 0xa8, 0xab,
    0xa4, 0x43, 0x6c, 0x9a, 0xbc, 0x30, 0x81, 0xd4,
    0x0a, 0x55, 0x80, 0x2c, 0x6a, 0xcd, 0xdd, 0xcc,
};
var diagnostic_counts: [463]u64 = @splat(0);
var diagnostic_steps: u64 = 0;
var diagnostic_other: u64 = 0;
var diagnostic_overflow: u64 = 0;
var diagnostic_stacks: [463]u64 = @splat(0);
var diagnostic_samples: u64 = 0;
var diagnostic_truncated: u64 = 0;
var diagnostic_invalid: u64 = 0;

fn diagnosticSample(self: *const Session, function: p.Id, parent: ?g.NodeRef) void {
    if (self.transitions & 1023 != 0 or
        !std.mem.eql(u8, &self.program_identity, &diagnostic_identity)) return;
    var seen: [463]bool = @splat(false);
    if (function >= seen.len) return;
    seen[@intCast(function)] = true;
    var next = parent;
    for (0..128) |_| {
        const reference = next orelse break;
        const node = self.store.get(reference) catch {
            diagnostic_invalid +|= 1;
            break;
        };
        const block = switch (node) {
            .control => |item| selected: {
                next = item.parent;
                break :selected item.block;
            },
            .continuation => |item| selected: {
                next = item.parent;
                break :selected item.source_block;
            },
            else => {
                diagnostic_invalid +|= 1;
                break;
            },
        };
        if (block >= self.program.blocks.len) break;
        const caller = self.program.blocks[@intCast(block)].function;
        if (caller >= seen.len) break;
        seen[@intCast(caller)] = true;
    }
    if (next != null) diagnostic_truncated +|= 1;
    for (seen, 0..) |present, id| if (present) {
        diagnostic_stacks[id] +|= 1;
    };
    diagnostic_samples +|= 1;
}

fn diagnosticStep(identity: *const [32]u8, function: p.Id) void {
    if (!std.mem.eql(u8, identity, &diagnostic_identity)) {
        diagnostic_other +|= 1;
        return;
    }
    if (function >= diagnostic_counts.len) {
        diagnostic_overflow +|= 1;
        return;
    }
    diagnostic_counts[@intCast(function)] +|= 1;
    diagnostic_steps +%= 1;
    if (diagnostic_steps & ((1 << 20) - 1) == 0) diagnosticDump();
}

pub fn diagnosticDump() void {
    std.debug.print("function-counts overflow={d} other={d} total={d}\n", .{
        diagnostic_overflow, diagnostic_other, diagnostic_steps,
    });
    std.debug.print("function-program {s}\n", .{
        std.fmt.bytesToHex(diagnostic_identity, .lower),
    });
    std.debug.print("function-samples {d} truncated={d} invalid={d}\n", .{
        diagnostic_samples, diagnostic_truncated, diagnostic_invalid,
    });
    for (&diagnostic_counts, 0..) |*count, function| {
        if (count.* != 0) std.debug.print("function-work {d} {d}\n", .{ function, count.* });
        if (diagnostic_stacks[function] != 0) std.debug.print("function-stack {d} {d}\n", .{
            function, diagnostic_stacks[function],
        });
        count.* = 0;
        diagnostic_stacks[function] = 0;
    }
    diagnostic_samples = 0;
    diagnostic_truncated = 0;
    diagnostic_invalid = 0;
}
`;
writeFileSync(sessionPath, source);
writeFileSync(root + '/root.zig', readFileSync(root + '/root.zig', 'utf8') +
    '\npub const diagnosticDump = @import("base/session.zig").diagnosticDump;\n');
const testPath = 'test/protean/projection_recovery.zig';
let test = readFileSync(testPath, 'utf8');
const init = '    pub fn init(self: *Fixture) !void {';
assert.equal(test.split(init).length, 2);
test = test.replace(init, init + '\n        defer @import("kosmos").diagnosticDump();');
writeFileSync(testPath, test);
const command = JSON.parse(readFileSync(profile + '/candidate-command.json', 'utf8'));
const emit = command.findIndex(arg => arg.startsWith('-femit-bin='));
assert(emit >= 0);
command[emit] = '-femit-bin=' + profile + '/native-owner-adaptive-functions';
writeFileSync(profile + '/functions-command.json', JSON.stringify(command));
writeFileSync(profile + '/functions-session.zig', source);
if (!process.env.DIAGNOSTIC_VALIDATE_ONLY) {
    const result = spawnSync(command[0], command.slice(1), {stdio: 'inherit'});
    if (result.error) throw result.error;
    process.exit(result.status ?? 1);
}
