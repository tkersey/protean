//! One nonblocking framed stdio transport. It reserves output before dispatch,
//! retains RPC IDs until their complete frame is written, and owns deadlines.
const std = @import("std");
const c = @import("native_c");
const json = @import("json.zig");
const protocol = @import("protocol.zig");

pub const Id = union(enum) {
    null,
    number: i64,
    text: struct { bytes: [128]u8, len: u8 },

    pub fn from(value: json.Value) !Id {
        return switch (value) {
            .null => .null,
            .number_string => |text| .{ .number = try json.safeInteger(text) },
            .string => |text| blk: {
                if (text.len == 0 or text.len > 128) return error.InvalidParams;
                var result: Id = .{ .text = .{ .bytes = undefined, .len = @intCast(text.len) } };
                @memcpy(result.text.bytes[0..text.len], text);
                break :blk result;
            },
            else => error.InvalidParams,
        };
    }
    fn equal(a: Id, b: Id) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .number => |value| value == b.number,
            .text => |text| text.len == b.text.len and std.mem.eql(
                u8,
                text.bytes[0..text.len],
                b.text.bytes[0..b.text.len],
            ),
        };
    }
};
const Frame = struct {
    bytes: []u8,
    offset: usize = 0,
    ids: [16]Id = undefined,
    count: usize = 0,
    private: bool,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: protocol.Limits,
    stdin_flags: c_int,
    stdout_flags: c_int,
    framing: protocol.Framer,
    input: [8192]u8 = undefined,
    input_start: usize = 0,
    input_end: usize = 0,
    pending: ?[]const u8 = null,
    eof: bool = false,
    frame_started: ?i64 = null,
    queue: [64]?Frame = @splat(null),
    head: usize = 0,
    count: usize = 0,
    queued_bytes: usize = 0,
    outstanding: usize = 0,
    output_progress: ?i64 = null,

    pub fn init(a: std.mem.Allocator, io: std.Io, limits: protocol.Limits) !Transport {
        const input_flags = c.fcntl(0, c.F_GETFL);
        const output_flags = c.fcntl(1, c.F_GETFL);
        if (input_flags < 0 or output_flags < 0) return error.IoUnavailable;
        const buffer = try a.alloc(u8, limits.frame_bytes - 1);
        errdefer a.free(buffer);
        if (c.fcntl(0, c.F_SETFL, input_flags | c.O_NONBLOCK) < 0) return error.IoUnavailable;
        errdefer _ = c.fcntl(0, c.F_SETFL, input_flags);
        if (c.fcntl(1, c.F_SETFL, output_flags | c.O_NONBLOCK) < 0) return error.IoUnavailable;
        return .{
            .allocator = a,
            .io = io,
            .limits = limits,
            .stdin_flags = input_flags,
            .stdout_flags = output_flags,
            .framing = .{ .buffer = buffer },
        };
    }
    pub fn deinit(self: *Transport) void {
        for (&self.queue) |*slot| if (slot.*) |frame| {
            self.allocator.free(frame.bytes);
            slot.* = null;
        };
        self.allocator.free(self.framing.buffer);
        _ = c.fcntl(0, c.F_SETFL, self.stdin_flags);
        _ = c.fcntl(1, c.F_SETFL, self.stdout_flags);
        self.* = undefined;
    }
    pub fn now(self: *Transport) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
    pub fn deadlines(self: *Transport) !void {
        const time = self.now();
        if (self.frame_started) |start| if (time - start >= self.limits.incomplete_frame_ms)
            return error.FrameTimeout;
        if (self.output_progress) |start| if (time - start >= self.limits.output_stall_ms)
            return error.OutputStall;
    }
    pub fn next(self: *Transport) !?[]const u8 {
        if (self.pending) |bytes| return bytes;
        if (self.eof) return null;
        while (true) { // tiger: event-loop
            if (self.input_start == self.input_end) {
                const count = c.read(0, &self.input, self.input.len);
                if (count < 0) switch (std.c.errno(count)) {
                    .INTR => continue,
                    .AGAIN => return null,
                    else => return error.InputClosed,
                };
                if (count == 0) {
                    self.eof = true;
                    try self.framing.eof();
                    return null;
                }
                self.input_start = 0;
                self.input_end = @intCast(count);
            }
            if (self.frame_started == null) self.frame_started = self.now();
            const chunk = try self.framing.push(self.input[self.input_start..self.input_end]);
            self.input_start += chunk.consumed;
            if (chunk.frame) |bytes| {
                self.frame_started = null;
                self.pending = bytes;
                return bytes;
            }
        }
    }
    pub fn consumed(self: *Transport) void {
        self.pending = null;
    }
    /// A complete frame has at most one frame-sized response, including batches.
    /// Keep one frame's space available for control/error publication.
    pub fn canAdmit(self: Transport) bool {
        return self.outstanding < self.limits.in_flight_calls and
            self.count < self.queue.len and
            self.queued_bytes + self.limits.frame_bytes <= self.limits.outbound_bytes;
    }
    pub fn preflight(self: Transport, ids: []const Id) !void {
        if (ids.len > self.limits.in_flight_calls or
            self.outstanding + ids.len > self.limits.in_flight_calls or
            !self.canAdmit())
            return error.Overloaded;
        for (ids, 0..) |id, i| {
            for (ids[0..i]) |prior| if (Id.equal(id, prior)) return error.DuplicateId;
            for (self.queue) |slot| if (slot) |frame| {
                for (frame.ids[0..frame.count]) |prior| if (Id.equal(
                    id,
                    prior,
                )) return error.DuplicateId;
            };
        }
    }
    pub fn enqueue(self: *Transport, bytes: []const u8, ids: []const Id, private: bool) !void {
        if (bytes.len + 1 > self.limits.frame_bytes or
            ids.len > 16 or
            self.count == self.queue.len or
            self.queued_bytes + bytes.len + 1 > self.limits.outbound_bytes)
            return error.Overloaded;
        const owned = try self.allocator.alloc(u8, bytes.len + 1);
        @memcpy(owned[0..bytes.len], bytes);
        owned[bytes.len] = '\n';
        var frame: Frame = .{ .bytes = owned, .private = private, .count = ids.len };
        @memcpy(frame.ids[0..ids.len], ids);
        self.queue[(self.head + self.count) % self.queue.len] = frame;
        self.count += 1;
        self.outstanding += ids.len;
        self.queued_bytes += owned.len;
        if (self.output_progress == null) self.output_progress = self.now();
    }
    pub fn flush(self: *Transport, disclose_private: bool) !void {
        // A bounded number of writes prevents a busy stdout from starving input.
        for (0..16) |_| {
            if (self.count == 0) return;
            const frame = &self.queue[self.head].?;
            if (frame.private and !disclose_private) return error.Denied;
            const bytes = frame.bytes[frame.offset..];
            const count = c.write(1, bytes.ptr, bytes.len);
            if (count < 0) switch (std.c.errno(count)) {
                .INTR => continue,
                .AGAIN => return,
                else => return error.OutputClosed,
            };
            if (count == 0) return;
            frame.offset += @intCast(count);
            self.output_progress = self.now();
            if (frame.offset == frame.bytes.len) {
                self.queued_bytes -= frame.bytes.len;
                self.outstanding -= frame.count;
                self.allocator.free(frame.bytes);
                self.queue[self.head] = null;
                self.head = (self.head + 1) % self.queue.len;
                self.count -= 1;
                if (self.count == 0) self.output_progress = null;
            }
        }
    }
    pub fn wait(self: *Transport, read: bool, milliseconds: c_int) !void {
        if (@import("builtin").os.tag == .macos and self.count == 0) {
            // Darwin does not report a disconnected pipe/socket with events=0.
            // Probe write readiness without waiting, then retain the ordinary
            // input timeout below: an idle writable stdout must not cause spin.
            var output = c.struct_pollfd{ .fd = 1, .events = c.POLLOUT, .revents = 0 };
            const ready = c.poll(&output, 1, 0);
            if (ready < 0 and std.c.errno(ready) != .INTR) return error.IoUnavailable;
            if (output.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0)
                return error.OutputClosed;
        }
        var fds = [_]c.struct_pollfd{
            .{
                .fd = if (read and !self.eof and self.pending == null) 0 else -1,
                .events = c.POLLIN,
                .revents = 0,
            },
            // Closure is a connection event even without a pending write.
            // Request write readiness only for queued output, avoiding idle spin.
            .{ .fd = 1, .events = if (self.count != 0) c.POLLOUT else 0, .revents = 0 },
        };
        const count = c.poll(&fds, fds.len, milliseconds);
        if (count < 0 and std.c.errno(count) != .INTR) return error.IoUnavailable;
        if (fds[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.OutputClosed;
    }
};

test "idle output waits without spinning and detects closed pipe and socket readers" {
    const saved = c.dup(1);
    try std.testing.expect(saved >= 0);
    defer _ = c.close(saved);
    defer _ = c.dup2(saved, 1);
    for ([_]bool{ false, true }) |socket| {
        var fds: [2]c_int = undefined;
        const opened = if (socket) c.socketpair(
            c.AF_UNIX,
            c.SOCK_STREAM,
            0,
            &fds,
        ) else c.pipe(&fds);
        try std.testing.expectEqual(0, opened);
        var reader_open = true;
        defer {
            if (reader_open) _ = c.close(fds[0]);
        }
        defer _ = c.close(fds[1]);
        try std.testing.expectEqual(1, c.dup2(fds[1], 1));
        var transport = try Transport.init(std.testing.allocator, std.testing.io, .{});
        defer transport.deinit();
        const started = transport.now();
        try transport.wait(false, 40);
        try std.testing.expect(transport.now() - started >= 20);
        try std.testing.expectEqual(0, c.close(fds[0]));
        reader_open = false;
        try std.testing.expectError(error.OutputClosed, transport.wait(false, 40));
    }
}

test "outstanding request identity normalizes integer spellings without conflating strings" {
    const first = try Id.from(.{ .number_string = "1" });
    try std.testing.expect(Id.equal(first, try Id.from(.{ .number_string = "1.0" })));
    try std.testing.expect(Id.equal(first, try Id.from(.{ .number_string = "1e0" })));
    try std.testing.expect(!Id.equal(first, try Id.from(json.string("1"))));
    try std.testing.expect(Id.equal(.null, .null));
}

test "write opportunity after owner work distinguishes queued output from a stalled reader" {
    const saved = c.dup(1);
    try std.testing.expect(saved >= 0);
    defer _ = c.close(saved);
    defer _ = c.dup2(saved, 1);
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expectEqual(1, c.dup2(fds[1], 1));
    var transport = try Transport.init(std.testing.allocator, std.testing.io, .{});
    defer transport.deinit();

    try transport.enqueue("ok", &.{}, false);
    transport.output_progress = transport.now() - transport.limits.output_stall_ms - 1;
    try transport.flush(true);
    try transport.deadlines();
    try std.testing.expectEqual(0, transport.count);
    var received: [3]u8 = undefined;
    try std.testing.expectEqual(3, c.read(fds[0], &received, received.len));
    try std.testing.expectEqualStrings("ok\n", &received);

    const fill: [4096]u8 = @splat(0);
    while (true) { // tiger: event-loop
        const written = c.write(1, &fill, fill.len);
        if (written < 0) {
            if (std.c.errno(written) == .INTR) continue;
            try std.testing.expectEqual(std.c.E.AGAIN, std.c.errno(written));
            break;
        }
        try std.testing.expect(written > 0);
    }
    // A failed PIPE_BUF-sized write may leave room for a smaller frame.
    while (true) { // tiger: event-loop
        const written = c.write(1, &fill, 1);
        if (written < 0) {
            if (std.c.errno(written) == .INTR) continue;
            try std.testing.expectEqual(std.c.E.AGAIN, std.c.errno(written));
            break;
        }
        try std.testing.expectEqual(1, written);
    }
    try transport.enqueue("blocked", &.{}, false);
    transport.output_progress = transport.now() - transport.limits.output_stall_ms - 1;
    try transport.flush(true);
    try std.testing.expectEqual(1, transport.count);
    try std.testing.expectError(error.OutputStall, transport.deadlines());
}
