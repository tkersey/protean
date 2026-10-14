//! Stable-address evaluator storage, reachable only by the native task owner.
//! Environmental callbacks receive values/authority, never this handle.
const std = @import("std");
const kosmos = @import("kosmos");
const data = @import("horos_data");

const Storage = struct {
    parent: std.mem.Allocator,
    program: *Program,
    own_program: bool,
    resident: kosmos.Resident,
    live: bool,
    checkpoint: ?*kosmos.Checkpoint,
};

const ProgramStorage = struct {
    parent: std.mem.Allocator,
    prepared: kosmos.Prepared,
    residents: usize = 0,
};

/// Shared prepared image, owned by the single task service. Its address remains
/// stable until all residents have retired; no adapter receives this handle.
pub const Program = opaque {
    fn storage(self: *Program) *ProgramStorage {
        return @ptrCast(@alignCast(self));
    }
    pub fn open(a: std.mem.Allocator, image: []const u8) !*Program {
        const owner = try a.create(ProgramStorage);
        errdefer a.destroy(owner);
        owner.* = .{ .parent = a, .prepared = undefined };
        owner.prepared = try kosmos.Prepared.init(a, image);
        return @ptrCast(owner);
    }
    pub fn close(self: *Program) !void {
        const owner = self.storage();
        if (owner.residents != 0) return error.UnfinishedSession;
        owner.prepared.deinit();
        owner.parent.destroy(owner);
    }
};

pub const Driver = opaque {
    fn storage(self: *Driver) *Storage {
        return @ptrCast(@alignCast(self));
    }

    pub fn open(a: std.mem.Allocator, image: []const u8, instance: data.invocation.Instance) !*Driver {
        const program = try Program.open(a, image);
        errdefer program.close() catch unreachable;
        const driver = try start(a, program, instance);
        driver.storage().own_program = true;
        return driver;
    }

    pub fn start(a: std.mem.Allocator, program: *Program, instance: data.invocation.Instance) !*Driver {
        const owner = try a.create(Storage);
        errdefer a.destroy(owner);
        owner.parent = a;
        owner.program = program;
        owner.own_program = false;
        const prepared = &program.storage().prepared;
        owner.resident = switch (instance) {
            .initial_args => |args| try kosmos.Resident.start(a, prepared, args),
            .state => |state| try kosmos.Resident.restore(a, prepared, state),
        };
        program.storage().residents += 1;
        owner.live = true;
        owner.checkpoint = null;
        return @ptrCast(owner);
    }

    /// The outcome belongs to output. The checkpoint remains owned here until
    /// the next successful drive or retirement, including after storage fails.
    pub const Publication = struct { outcome: []u8, checkpoint: []const u8 };

    pub fn drive(self: *Driver, output: std.mem.Allocator, control: data.invocation.Control, quantum: u64) !Publication {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        var published = try owner.resident.publish(.{ .encoded = output }, control, .{ .quantum = quantum, .checkpoint = .receipt });
        const checkpoint = published.takeCheckpoint().?;
        if (owner.checkpoint) |previous| previous.deinit();
        owner.checkpoint = checkpoint;
        return .{ .outcome = published.outcome.encoded, .checkpoint = checkpoint.bytes() };
    }
    pub fn close(self: *Driver) !void {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        try owner.resident.close();
        if (owner.checkpoint) |checkpoint| checkpoint.deinit();
        owner.checkpoint = null;
        owner.live = false;
        owner.program.storage().residents -= 1;
        if (owner.own_program) try owner.program.close();
    }
    /// The task owner may call this only after publishing a checkpoint, or for
    /// an explicitly nondurable demo. A failure leaves the resident owned/live.
    pub fn retire(self: *Driver) !void {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        if (owner.checkpoint) |checkpoint| {
            try owner.resident.transferCheckpoint(checkpoint);
            checkpoint.deinit();
            owner.checkpoint = null;
        } else {
            // A newly restored resident may be retired before its first drive.
            const state = try owner.resident.takeCheckpoint(owner.parent);
            owner.parent.free(state);
        }
        owner.live = false;
        owner.program.storage().residents -= 1;
        if (owner.own_program) try owner.program.close();
    }
    /// Retired handles remain allocated until the enclosing owner drops them,
    /// allowing all ordinary operations after close to reject before access.
    pub fn destroy(self: *Driver) !void {
        const owner = self.storage();
        if (owner.live) return error.UnfinishedSession;
        owner.parent.destroy(owner);
    }
};

test "driver retains one publication across output lifetime and failed drive then transfers without allocation" {
    const a = std.testing.allocator;
    // Historical yielding bytes identity, also exercised by Kosmos's public
    // large-state restoration tests. The original image is not recompiled.
    var image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(&image, "41424c5f4250493303000000200000000000000001000001020a0000000100000100010000020000070100000000000000000000");
    var failing = std.testing.FailingAllocator.init(a, .{});
    const driver = try Driver.open(failing.allocator(), &image, .{ .initial_args = &.{ 1, 42 } });
    defer driver.destroy() catch unreachable;
    var statistics: kosmos.Statistics = .{};
    try driver.storage().resident.setStatistics(&statistics);
    var checkpoint: []u8 = undefined;
    {
        var frame = std.heap.ArenaAllocator.init(a);
        defer frame.deinit();
        const published = try driver.drive(frame.allocator(), .none, 256);
        var outcome = try data.invocation.decode(data.invocation.Outcome, a, published.outcome);
        defer outcome.deinit();
        try std.testing.expect(outcome.value == .yielded);
        checkpoint = try a.dupe(u8, published.checkpoint);
    }
    defer a.free(checkpoint);
    try std.testing.expectEqual(1, statistics.state_projections);
    const receipt = driver.storage().checkpoint.?;
    try std.testing.expectEqualSlices(u8, checkpoint, receipt.bytes());
    var no_output = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, driver.drive(no_output.allocator(), .resume_yield, 256));
    try std.testing.expectEqual(receipt, driver.storage().checkpoint.?);
    try std.testing.expectEqualSlices(u8, checkpoint, receipt.bytes());
    const before = statistics.state_projections;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try driver.retire();
    try std.testing.expectEqual(before, statistics.state_projections);
    try std.testing.expectError(error.InvalidState, driver.drive(a, .none, 0));
    const restored = try Driver.open(a, &image, .{ .state = checkpoint });
    defer restored.destroy() catch unreachable;
    const complete = try restored.drive(a, .resume_yield, 256);
    defer a.free(complete.outcome);
    var outcome = try data.invocation.decode(data.invocation.Outcome, a, complete.outcome);
    defer outcome.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 42 }, outcome.value.completed);
    try restored.close();
}
