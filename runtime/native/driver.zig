//! Stable-address evaluator storage, reachable only by the native task owner.
//! Environmental callbacks receive values/authority, never this handle.
const std = @import("std");
const kronos = @import("kronos");
const data = @import("horos_data");

const Storage = struct {
    parent: std.mem.Allocator,
    budget: kronos.AllocationBudget,
    program: *Program,
    own_program: bool,
    resident: kronos.Resident,
    live: bool,
};

const ProgramStorage = struct {
    parent: std.mem.Allocator,
    budget: kronos.AllocationBudget,
    prepared: kronos.Prepared,
    residents: usize = 0,
};

/// Shared prepared image, owned by the single task service. Its address remains
/// stable until all residents have retired; no adapter receives this handle.
pub const Program = opaque {
    fn storage(self: *Program) *ProgramStorage {
        return @ptrCast(@alignCast(self));
    }
    pub fn open(a: std.mem.Allocator, image: []const u8, working_bytes: usize) !*Program {
        const owner = try a.create(ProgramStorage);
        errdefer a.destroy(owner);
        owner.* = .{ .parent = a, .budget = .{ .parent = a, .limit = working_bytes }, .prepared = undefined };
        owner.prepared = try kronos.Prepared.init(owner.budget.allocator(), image);
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

    pub fn open(a: std.mem.Allocator, image: []const u8, instance: data.invocation.Instance, working_bytes: usize) !*Driver {
        const program = try Program.open(a, image, working_bytes);
        errdefer program.close() catch unreachable;
        const driver = try start(a, program, instance, working_bytes);
        driver.storage().own_program = true;
        return driver;
    }

    pub fn start(a: std.mem.Allocator, program: *Program, instance: data.invocation.Instance, working_bytes: usize) !*Driver {
        if (working_bytes == 0) return error.Capacity;
        const owner = try a.create(Storage);
        errdefer a.destroy(owner);
        owner.parent = a;
        owner.budget = .{ .parent = a, .limit = working_bytes };
        owner.program = program;
        owner.own_program = false;
        const prepared = &program.storage().prepared;
        owner.resident = switch (instance) {
            .initial_args => |args| try kronos.Resident.start(owner.budget.allocator(), prepared, args),
            .state => |state| try kronos.Resident.restore(owner.budget.allocator(), prepared, state),
        };
        program.storage().residents += 1;
        owner.live = true;
        return @ptrCast(owner);
    }

    pub fn drive(self: *Driver, output: std.mem.Allocator, control: data.invocation.Control, quantum: u64) ![]u8 {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        return owner.resident.driveEncoded(output, control, .{ .quantum = quantum });
    }
    pub fn checkpoint(self: *Driver, output: std.mem.Allocator) ![]u8 {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        return owner.resident.checkpoint(output);
    }
    pub fn close(self: *Driver) !void {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        try owner.resident.close();
        owner.live = false;
        owner.program.storage().residents -= 1;
        if (owner.own_program) try owner.program.close();
    }
    /// The task owner may call this only after publishing a checkpoint, or for
    /// an explicitly nondurable demo. A failure leaves the resident owned/live.
    pub fn retire(self: *Driver, output: std.mem.Allocator) ![]u8 {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        const state = try owner.resident.takeCheckpoint(output);
        owner.live = false;
        owner.program.storage().residents -= 1;
        if (owner.own_program) try owner.program.close();
        return state;
    }
    /// Retired handles remain allocated until the enclosing owner drops them,
    /// allowing all ordinary operations after close to reject before access.
    pub fn destroy(self: *Driver) !void {
        const owner = self.storage();
        if (owner.live) return error.UnfinishedSession;
        owner.parent.destroy(owner);
    }
};
