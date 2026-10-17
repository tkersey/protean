//! The peer transport owns no Store or evaluator. The native owner publishes
//! its signed result after joining; interruption leaves the source frozen.
const std = @import("std");
const p = @import("placement.zig");
const transport = @import("placement_transport.zig");
const contracts = @import("protean_contracts");
pub const Input = union(enum) { move: struct { offer: p.Signed(p.Offer), path: contracts.Utf8 }, withdraw: p.Signed(p.Offer), control: struct { message: p.Signed(p.Control), route: contracts.Vector(p.Succession, null), lineage: contracts.Vector(p.Succession, null) } };
pub const Result = union(enum) { decision: p.Signed(p.Decision), report: []u8 };
pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    peer: p.Peer,
    owned_input: []u8,
    future: std.Io.Future(void) = undefined,
    finished: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    result: anyerror!Result = error.NotReady,

    pub fn start(a: std.mem.Allocator, io: std.Io, peer: p.Peer, input: Input) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const owned = try contracts.encodeOwned(Input, a, input);
        errdefer a.free(owned);
        // Decode inside the worker's arena; no borrowed command payload crosses
        // the caller's scratch lifetime.
        self.* = .{ .allocator = a, .io = io, .peer = peer, .owned_input = owned };
        self.future = try io.concurrent(run, .{self});
        return self;
    }
    fn exchange(self: *Job) !Result {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var connection = try transport.Connection.openCancelable(arena.allocator(), self.io, self.peer, &self.cancelled);
        defer connection.deinit();
        var input = try contracts.decodeOwned(Input, arena.allocator(), self.owned_input);
        defer input.deinit();
        return switch (input.value) {
            .move => |move| .{ .decision = try connection.transfer(arena.allocator(), move.offer, move.path.bytes) },
            .withdraw => |offer| withdrawn: {
                const json = try connection.request(arena.allocator(), .{ .refuse = .{ .peer = .{ .bytes = connection.channel.remote_name }, .offer = offer, .reason = .withdrawn } });
                const decision = try @import("values.zig").fromJson(p.Signed(p.Decision), arena.allocator(), json);
                try p.matchDecision(arena.allocator(), offer.value, decision);
                break :withdrawn .{ .decision = decision };
            },
            .control => |selected| control_result: {
                const control = selected.message;
                const remote = try @import("values.zig").fromJson(?p.Custody, arena.allocator(), try connection.request(arena.allocator(), .{ .status = .{ .task = control.value.subject.task } })) orelse return error.InvalidTransfer;
                for (selected.lineage.items) |succession| {
                    if (succession.decision.value.epoch <= remote.epoch) continue;
                    _ = try connection.request(arena.allocator(), .{ .follow_controller_proof = .{ .offer = succession.offer, .decision = succession.decision } });
                }
                const head = try p.routeHead(arena.allocator(), control.value, selected.route.items);
                if (!std.meta.eql(head.site, self.peer.site)) return error.InvalidRemoteCommand;
                const json = try connection.request(arena.allocator(), .{ .resolve_control = .{ .peer = .{ .bytes = connection.channel.remote_name }, .control = control, .route = selected.route } });
                const resolution = try @import("values.zig").fromJson(p.ControlResolution, arena.allocator(), json);
                switch (resolution) {
                    .report => |report| try p.matchReport(arena.allocator(), control.value, selected.route.items, report),
                    .next => |next| _ = try p.routeNext(arena.allocator(), control.value.subject, head, next),
                }
                break :control_result .{ .report = try contracts.encodeOwned(p.ControlResolution, self.allocator, resolution) };
            },
        };
    }
    fn run(self: *Job) void {
        self.result = self.exchange();
        self.finished.store(true, .release);
    }
    pub fn deinit(self: *Job) void {
        self.cancelled.store(true, .release);
        self.future.await(self.io);
        if (self.result) |result| switch (result) {
            .report => |bytes| self.allocator.free(bytes),
            .decision => {},
        } else |_| {}
        self.allocator.free(self.owned_input);
        self.allocator.destroy(self);
    }
};

test "placement transport cancellation joins without claiming a decision" {
    const peer: p.Peer = .{
        .name = "unavailable",
        .site = std.mem.zeroes(p.Site),
        .native_build = @splat(0),
        .compatibility = std.mem.zeroes(p.Compatibility),
        .resource_binding = @splat(0),
        .disclosure_policy = @splat(0),
        .context = undefined,
        .disclose = struct {
            fn check(_: *anyopaque, _: p.Subject, _: []const @import("state.zig").Reference) !void {}
        }.check,
        .channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "source", .timeout_ms = 1000 },
    };
    const job = try Job.start(std.testing.allocator, std.testing.io, peer, .{ .move = .{ .offer = std.mem.zeroes(p.Signed(p.Offer)), .path = .{ .bytes = "unused" } } });
    job.deinit();
}
