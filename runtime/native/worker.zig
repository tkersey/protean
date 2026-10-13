//! One environmental or pure recovery slot. Its private region and immutable
//! request outlive join; it never holds a Store or a Resident pointer.
const std = @import("std");
const data = @import("horos_data");
const tasks = @import("tasks.zig");
const registry = @import("registry.zig");

pub const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator = undefined,
    work: tasks.Work = undefined,
    authority: registry.Authority = undefined,
    environment: ?*anyopaque = null,
    future: ?std.Io.Future(void) = null,
    cancel_future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    joined: std.atomic.Value(bool) = .init(false),
    cancellation: std.atomic.Value(bool) = .init(false),
    invoked: bool = false,
    result: ?tasks.WorkResult = null,
    /// Diagnostic detail for an ordinary acquisition classified as unknown or
    /// not sent. The tagged result alone controls durable publication.
    failure: ?anyerror = null,

    pub fn init(a: std.mem.Allocator, io: std.Io) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        self.* = .{ .io = io, .allocator = a };
        return self;
    }
    pub fn deinit(self: *Worker, a: std.mem.Allocator) !void {
        if (self.future != null) return error.Busy;
        a.destroy(self);
    }
    pub fn start(self: *Worker, work: tasks.Work, authority: registry.Authority, environment: ?*anyopaque) !void {
        if (self.future != null) return error.Busy;
        self.arena = .init(self.allocator);
        self.work = work;
        self.authority = authority;
        self.environment = environment;
        self.result = null;
        self.failure = null;
        self.invoked = false;
        self.done.store(false, .release);
        self.joined.store(false, .release);
        self.cancellation.store(false, .release);
        self.cancel_future = null;
        self.future = self.io.concurrent(execute, .{self}) catch |err| {
            self.arena.deinit();
            return err;
        };
    }
    fn invoke(self: *Worker) !tasks.WorkResult {
        const a = self.arena.allocator();
        var request = try data.invocation.decode(data.invocation.Request, a, self.work.request);
        defer request.deinit();
        if (self.work.recovery) |item| {
            var saved = try @import("protean_contracts").decodeOwned(@import("state.zig").Reconciliation, a, item.body);
            defer saved.deinit();
            if (saved.value.selection == .rederive) {
                const ctx: registry.RederivationContext = .{ .allocator = a, .task = self.work.task, .profile = self.work.profile, .cancellation = &self.cancellation };
                if (self.cancellation.load(.acquire)) return .{ .rederived = .unavailable };
                const adapter = self.work.entry.declaration.recovery orelse return .{ .failure = error.UnsupportedRecovery };
                const rederive = adapter.rederive orelse return .{ .failure = error.UnsupportedRecovery };
                const finding = rederive(ctx, registry.RecoveryInput.fromReconciliation(saved.value, request.value.request_identity, self.work.entry.declaration.inference), request.value.binding.payload, self.work.prepared) catch |err| return switch (err) {
                    error.Canceled => .{ .rederived = .unavailable },
                    else => .{ .failure = err },
                };
                return .{ .rederived = finding };
            }
        }
        const id = std.fmt.bytesToHex(self.work.task, .lower);
        const ctx: registry.Context = .{ .allocator = a, .io = self.io, .authority = &self.authority, .task_id = &id, .profile = self.work.profile, .environment = self.environment, .cancellation = &self.cancellation };
        try ctx.checkCancellation();
        self.invoked = true;
        if (self.work.recovery) |item| {
            var saved = try @import("protean_contracts").decodeOwned(@import("state.zig").Reconciliation, a, item.body);
            defer saved.deinit();
            const adapter = self.work.entry.declaration.recovery orelse return error.UnsupportedRecovery;
            const lookup = adapter.lookup orelse return error.UnsupportedRecovery;
            return .{ .acquired = try lookup.acquire(ctx, registry.RecoveryInput.fromReconciliation(saved.value, request.value.request_identity, self.work.entry.declaration.inference), request.value.binding.payload, self.work.prepared) };
        }
        if (self.work.entry.declaration.capture) |adapter| {
            return switch (try adapter.acquire(ctx, self.work.prepared orelse return error.InvalidPreparedRequest)) {
                .captured => |bytes| .{ .acquired = bytes },
                .definitely_not_sent => |err| blk: {
                    self.invoked = false;
                    break :blk err;
                },
                .unknown => |err| err,
            };
        }
        return .{ .acquired = try self.work.entry.declaration.invoke.?(ctx, self.work.prepared orelse request.value.binding.payload) };
    }
    fn execute(self: *Worker) void {
        defer self.done.store(true, .release);
        self.result = self.invoke() catch |err| blk: {
            self.failure = err;
            // Failure decoding retained recovery inputs is operational, not
            // evidence that recovery was unavailable or the old effect unsent.
            if (self.work.recovery != null and !self.invoked and err != error.Canceled) break :blk .{ .failure = err };
            break :blk if (self.invoked) .unknown else .not_sent;
        };
    }
    fn cancelJoin(self: *Worker) void {
        self.future.?.cancel(self.io);
        self.joined.store(true, .release);
    }
    /// Cancellation itself may wait for an I/O cancellation point, so joining
    /// runs outside the control-plane loop. The host retains its hard deadline.
    pub fn cancel(self: *Worker) void {
        if (self.future == null or self.cancel_future != null) return;
        self.cancellation.store(true, .release);
        self.cancel_future = self.io.concurrent(cancelJoin, .{self}) catch return;
    }
    pub fn finished(self: *Worker) bool {
        if (self.future == null) return false;
        return if (self.cancel_future != null) self.joined.load(.acquire) else self.done.load(.acquire);
    }
    pub fn join(self: *Worker) !void {
        if (!self.finished()) return error.Busy;
        if (self.cancel_future) |*future| future.await(self.io) else self.future.?.await(self.io);
        self.future = null;
        self.cancel_future = null;
    }
    /// Called after join and durable result/unknown publication by the owner.
    pub fn release(self: *Worker) !void {
        if (self.future != null) return error.Busy;
        self.arena.deinit();
        self.result = null;
        self.failure = null;
    }
};
