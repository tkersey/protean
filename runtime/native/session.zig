const std = @import("std");
const tasks = @import("tasks.zig");
const Worker = @import("worker.zig").Worker;

pub const Progress = enum { idle, progressed, waiting };
pub const Completion = enum { none, completed, unknown };

pub fn Session(comptime Types: type) type {
    return struct {
        const Self = @This();
        const Publication = enum { none, joined, unstarted };

        service: *tasks.Service(Types),
        slot: *Worker,
        publication: Publication = .none,

        pub fn init(service: *tasks.Service(Types)) !Self {
            if (service.work != null or service.session_attached) return error.Busy;
            const slot = try Worker.init(service.allocator, service.io);
            service.session_attached = true;
            return .{
                .service = service,
                .slot = slot,
            };
        }

        pub fn deinit(self: *Self) !void {
            if (self.busy()) return error.Busy;
            try self.slot.deinit(self.service.allocator);
            self.service.session_attached = false;
            self.* = undefined;
        }

        pub fn busy(self: *const Self) bool {
            return self.slot.future != null or self.publication != .none;
        }

        pub fn collect(self: *Self, frame: std.mem.Allocator, cancel: bool) !Completion {
            if (self.slot.future != null) {
                if (cancel or try self.service.shouldCancelWork(self.slot.work))
                    self.slot.cancel();
                if (!self.slot.finished()) return .none;
                try self.slot.join();
                self.publication = .joined;
            }
            if (self.publication == .none) return .none;
            const result = if (self.publication == .unstarted)
                tasks.WorkResult.not_sent
            else
                self.slot.result orelse tasks.WorkResult.not_sent;
            const publication = self.service.completeWork(frame, self.slot.work, result);
            if (self.service.work == null) {
                if (self.publication == .joined) try self.slot.release();
                self.publication = .none;
            }
            try publication;
            return if (result == .unknown) .unknown else .completed;
        }

        pub fn advance(self: *Self, frame: std.mem.Allocator) !Progress {
            if (self.publication != .none) return error.Busy;
            return switch (try self.service.pump(frame)) {
                .idle => .idle,
                .waiting => .waiting,
                .progressed => .progressed,
                .work => |work| blk: {
                    self.slot.start(
                        work,
                        self.service.profile.authority,
                        self.service.profile.environment,
                    ) catch {
                        self.publication = .unstarted;
                        _ = try self.collect(frame, false);
                    };
                    break :blk .progressed;
                },
            };
        }

        pub fn tick(self: *Self, frame: std.mem.Allocator) !Progress {
            const completion = try self.collect(frame, false);
            const progress = try self.advance(frame);
            return if (completion != .none and progress == .idle) .progressed else progress;
        }

        pub fn park(self: *Self, frame: std.mem.Allocator) !void {
            if (self.busy()) return error.Busy;
            try self.service.park(frame);
        }
    };
}
