const std = @import("std");
const c = std.c;
const protocol = @import("siwc_protocol.zig");
pub const Cancellation = ?*const std.atomic.Value(bool);
pub const local_timeout_ms: i64 = 10_000;
pub const credential_timeout_ms: i64 = 120_000;
pub const models_timeout_ms: i64 = 150_000;
pub const stderr_bytes_max = 32 * 1024;
pub const version_bytes_max = 64;

pub const Clock = struct {
    context: ?*anyopaque = null,
    monotonic: ?*const fn (?*anyopaque) i64 = null,
    unix_seconds: ?*const fn (?*anyopaque) i64 = null,

    pub fn milliseconds(self: Clock, io: std.Io) i64 {
        if (self.monotonic) |read| return read(self.context);
        return std.Io.Clock.awake.now(io).toMilliseconds();
    }
    pub fn seconds(self: Clock, io: std.Io) i64 {
        if (self.unix_seconds) |read| return read(self.context);
        return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    }
};

pub fn check(io: std.Io, cancelled: Cancellation) !void {
    try std.Io.checkCancel(io);
    if (cancelled) |flag| if (flag.load(.acquire)) return error.Canceled;
}

pub fn lock(io: std.Io, gate: *std.atomic.Value(bool), cancelled: Cancellation) !void {
    try check(io, cancelled);
    while (gate.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        try check(io, cancelled);
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    check(io, cancelled) catch |err| {
        gate.store(false, .release);
        return err;
    };
}

pub const Output = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    length: usize,

    pub fn slice(self: Output) []const u8 {
        return self.bytes[0..self.length];
    }
    pub fn deinit(self: *Output) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Pipe = struct {
    file: std.Io.File,
    bytes: []u8,
    length: usize = 0,
    eof: bool = false,

    fn drain(self: *Pipe) !void {
        if (self.eof) return;
        var extra: [1]u8 = undefined;
        defer std.crypto.secureZero(u8, &extra);
        const target = if (self.length == self.bytes.len) &extra else self.bytes[self.length..];
        const count = c.read(self.file.handle, target.ptr, target.len);
        if (count < 0) return switch (c.errno(count)) {
            .INTR, .AGAIN => {},
            else => error.SiwcProcessUnavailable,
        };
        if (count == 0) {
            self.eof = true;
            return;
        }
        if (self.length == self.bytes.len) return error.SiwcOutputLimit;
        self.length += @intCast(count);
    }
};

fn nonblocking(file: std.Io.File) !void {
    const flags = c.fcntl(file.handle, c.F.GETFL);
    if (flags < 0) return error.SiwcProcessUnavailable;
    const nonblock: c_int = @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    if (c.fcntl(file.handle, c.F.SETFL, flags | nonblock) < 0)
        return error.SiwcProcessUnavailable;
}

fn reap(child: *std.process.Child) !?bool {
    const pid = child.id orelse return true;
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, c.W.NOHANG);
    if (result == 0) return null;
    if (result < 0) return switch (c.errno(result)) {
        .INTR => null,
        else => error.SiwcProcessUnavailable,
    };
    child.id = null;
    const bits: u32 = @bitCast(status);
    return c.W.IFEXITED(bits) and c.W.EXITSTATUS(bits) == 0;
}

fn stop(child: *std.process.Child, io: std.Io) void {
    const pid = child.id orelse return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    _ = c.kill(pid, .KILL);
    _ = child.wait(io) catch return;
}

const Supervision = struct {
    io: std.Io,
    clock: Clock,
    cancelled: Cancellation,
    timeout_ms: i64,

    fn run(self: Supervision, child: *std.process.Child, out: *Pipe, err: *Pipe) !void {
        const started = self.clock.milliseconds(self.io);
        var succeeded: ?bool = null;
        while (succeeded == null or !out.eof or !err.eof) {
            try check(self.io, self.cancelled);
            if (self.clock.milliseconds(self.io) - started >= self.timeout_ms)
                return error.SiwcTimeout;
            try out.drain();
            try err.drain();
            if (succeeded == null) succeeded = try reap(child);
            if (succeeded != null and out.eof and err.eof) break;
            var events = [_]c.pollfd{
                .{ .fd = if (out.eof) -1 else out.file.handle, .events = c.POLL.IN, .revents = 0 },
                .{ .fd = if (err.eof) -1 else err.file.handle, .events = c.POLL.IN, .revents = 0 },
            };
            const polled = c.poll(&events, events.len, 10);
            if (polled < 0 and c.errno(polled) != .INTR) return error.SiwcProcessUnavailable;
        }
        if (!succeeded.?) return error.SiwcCommandFailed;
    }
};

pub const Request = struct {
    argv: []const []const u8,
    home: ?[]const u8,
    stdout_bytes_max: usize,
    timeout_ms: i64,
    clock: Clock = .{},
};

pub fn run(a: std.mem.Allocator, io: std.Io, request: Request, cancelled: Cancellation) !Output {
    try check(io, cancelled);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    if (request.home) |home| try environment.put("HOME", home);
    var output: Output = .{
        .allocator = a,
        .bytes = try a.alloc(u8, request.stdout_bytes_max),
        .length = 0,
    };
    errdefer output.deinit();
    const error_bytes = try a.alloc(u8, stderr_bytes_max);
    defer {
        std.crypto.secureZero(u8, error_bytes);
        a.free(error_bytes);
    }
    var child = std.process.spawn(io, .{
        .argv = request.argv,
        .environ_map = &environment,
        .cwd = .{ .path = "/" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.SiwcProcessUnavailable,
    };
    var out: Pipe = .{ .file = child.stdout.?, .bytes = output.bytes };
    var err: Pipe = .{ .file = child.stderr.?, .bytes = error_bytes };
    child.stdout = null;
    child.stderr = null;
    defer out.file.close(io);
    defer err.file.close(io);
    defer stop(&child, io);
    try nonblocking(out.file);
    try nonblocking(err.file);
    const supervision: Supervision = .{
        .io = io,
        .clock = request.clock,
        .cancelled = cancelled,
        .timeout_ms = request.timeout_ms,
    };
    try supervision.run(&child, &out, &err);
    output.length = out.length;
    return output;
}

test "process rejects nonzero success output and enforces output bounds" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var out = try run(a, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf ok; printf private >&2" },
        .home = null,
        .stdout_bytes_max = 2,
        .timeout_ms = local_timeout_ms,
    }, null);
    defer out.deinit();
    try std.testing.expectEqualStrings("ok", out.slice());
    try std.testing.expectError(error.SiwcCommandFailed, run(a, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf '{}'; exit 1" },
        .home = null,
        .stdout_bytes_max = 16,
        .timeout_ms = local_timeout_ms,
    }, null));
    try std.testing.expectError(error.SiwcOutputLimit, run(a, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf abc" },
        .home = null,
        .stdout_bytes_max = 2,
        .timeout_ms = local_timeout_ms,
    }, null));
}

test "process deadline reaps a child even after pipes close" {
    try std.testing.expectError(error.SiwcTimeout, run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; while :; do :; done" },
        .home = null,
        .stdout_bytes_max = 16,
        .timeout_ms = 30,
    }, null));
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, run(std.testing.allocator, std.testing.io, .{
        .argv = &.{"/missing/helper"},
        .home = null,
        .stdout_bytes_max = 16,
        .timeout_ms = 30,
    }, &cancelled));
}

test "minimal child environment contains only requested HOME" {
    const a = std.testing.allocator;
    for ([_]?[]const u8{ null, "/synthetic/operator" }) |home| {
        var output = try run(a, std.testing.io, .{
            .argv = &.{"/usr/bin/env"},
            .home = home,
            .stdout_bytes_max = 1024,
            .timeout_ms = local_timeout_ms,
        }, null);
        defer output.deinit();
        try std.testing.expectEqualStrings(
            if (home == null) "" else "HOME=/synthetic/operator\n",
            output.slice(),
        );
    }
}

test "both full pipes drain without deadlock and cancellation joins a running child" {
    var output = try run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "i=0; while [ $i -lt 16 ]; do printf '%8192s' x; " ++
            "printf '%2048s' y >&2; i=$((i+1)); done" },
        .home = null,
        .stdout_bytes_max = 128 * 1024,
        .timeout_ms = local_timeout_ms,
    }, null);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 128 * 1024), output.slice().len);
    const Cancel = struct {
        fn run(flag: *std.atomic.Value(bool)) !void {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
            flag.store(true, .release);
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    var future = try std.testing.io.concurrent(Cancel.run, .{&flag});
    defer future.await(std.testing.io) catch @panic("cancel fixture failed");
    try std.testing.expectError(error.Canceled, run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "while :; do :; done" },
        .home = null,
        .stdout_bytes_max = 16,
        .timeout_ms = local_timeout_ms,
    }, &flag));
}
