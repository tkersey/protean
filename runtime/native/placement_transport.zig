//! Native stdio peer transport. The operator supplies argv; model values can
//! select only an admitted peer name. No compiler or guest callback is used.
const std = @import("std");
const c = @import("native_c");
const json = @import("json.zig");
const values = @import("values.zig");
const protocol = @import("protocol.zig");
const contracts = @import("protean_contracts");
const p = @import("placement.zig");

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    channel: p.Channel,
    sequence: u64 = 0,
    input: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    frame: []u8,
    cancelled: ?*const std.atomic.Value(bool) = null,

    pub fn open(a: std.mem.Allocator, io: std.Io, peer: p.Peer) !Connection {
        return openCancelable(a, io, peer, null);
    }
    pub fn openCancelable(a: std.mem.Allocator, io: std.Io, peer: p.Peer, cancelled: ?*const std.atomic.Value(bool)) !Connection {
        const channel = peer.channel orelse return error.UnsupportedCapability;
        if (channel.argv.len == 0 or channel.timeout_ms == 0) return error.InvalidConfiguration;
        var child = try std.process.spawn(io, .{ .argv = channel.argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
        errdefer child.kill(io);
        const frame = try a.alloc(u8, (protocol.Limits{}).frame_bytes);
        errdefer a.free(frame);
        for ([_]c_int{ child.stdin.?.handle, child.stdout.?.handle }) |fd| {
            const flags = c.fcntl(fd, c.F_GETFL);
            if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.IoUnavailable;
        }
        var result: Connection = .{ .allocator = a, .io = io, .child = child, .channel = channel, .frame = frame, .cancelled = cancelled };
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var params = json.object();
        var versions: std.array_list.Managed(json.Value) = .init(temporary);
        try versions.append(json.string(protocol.version));
        try json.put(temporary, &params, "protocol_versions", .{ .array = versions });
        const initialized = try result.rpc(temporary, "initialize", params);
        if (!std.mem.eql(u8, try json.text(json.get(initialized, "protocol_version") orelse return error.InvalidPeer), protocol.version)) return error.InvalidPeer;
        var challenge: p.Digest = undefined;
        try io.randomSecure(&challenge);
        const hello = try values.fromJson(p.Signed(p.Hello), temporary, try result.request(temporary, .{ .challenge = challenge }));
        try p.verify(p.Hello, temporary, hello, peer.site);
        if (!std.meta.eql(hello.value.challenge, challenge) or !std.meta.eql(hello.value.native_build, peer.native_build)) return error.InvalidPeer;
        return result;
    }

    pub fn deinit(self: *Connection) void {
        // Transport closure is never a custody decision. The peer's native
        // seal owns recovery if the process stops after committing a reply.
        self.child.kill(self.io);
        self.allocator.free(self.frame);
    }

    fn ready(self: *Connection, fd: c_int, event: c_short, deadline: i64) !void {
        while (true) {
            if (self.cancelled) |flag| if (flag.load(.acquire)) return error.Cancelled;
            const remaining = deadline - std.Io.Clock.awake.now(self.io).toMilliseconds();
            if (remaining <= 0) return error.PeerTimeout;
            var descriptor: c.struct_pollfd = .{ .fd = fd, .events = event, .revents = 0 };
            const n = c.poll(&descriptor, 1, @intCast(@min(remaining, 100)));
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n < 0) return error.IoUnavailable;
            if (descriptor.revents & event != 0) return;
            if (descriptor.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.PeerDisconnected;
        }
    }

    fn write(self: *Connection, bytes: []const u8, deadline: i64) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.ready(self.child.stdin.?.handle, c.POLLOUT, deadline);
            const n = c.write(self.child.stdin.?.handle, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and (std.c.errno(n) == .INTR or std.c.errno(n) == .AGAIN)) continue;
            if (n <= 0) return error.PeerDisconnected;
            offset += @intCast(n);
        }
    }

    fn read(self: *Connection, deadline: i64) ![]const u8 {
        var length: usize = 0;
        while (true) {
            if (self.start == self.end) {
                try self.ready(self.child.stdout.?.handle, c.POLLIN, deadline);
                const n = c.read(self.child.stdout.?.handle, &self.input, self.input.len);
                if (n < 0 and (std.c.errno(n) == .INTR or std.c.errno(n) == .AGAIN)) continue;
                if (n <= 0) return error.PeerDisconnected;
                self.start = 0;
                self.end = @intCast(n);
            }
            const byte = self.input[self.start];
            self.start += 1;
            if (byte == '\n') return self.frame[0..length];
            if (length == self.frame.len) return error.FrameTooLarge;
            self.frame[length] = byte;
            length += 1;
        }
    }

    fn rpc(self: *Connection, a: std.mem.Allocator, method: []const u8, params: json.Value) !json.Value {
        self.sequence = try std.math.add(u64, self.sequence, 1);
        const id = try std.fmt.allocPrint(a, "{d}", .{self.sequence});
        var call = json.object();
        try json.put(a, &call, "jsonrpc", json.string("2.0"));
        try json.put(a, &call, "id", json.string(id));
        try json.put(a, &call, "method", json.string(method));
        try json.put(a, &call, "params", params);
        const bytes = try json.canonical(a, call);
        if (bytes.len + 1 > self.frame.len) return error.FrameTooLarge;
        const deadline = try std.math.add(i64, std.Io.Clock.awake.now(self.io).toMilliseconds(), self.channel.timeout_ms);
        try self.write(bytes, deadline);
        try self.write("\n", deadline);
        const frame = try self.read(deadline);
        var response = try json.parseAsset(a, frame, frame.len);
        defer response.deinit();
        if (!std.mem.eql(u8, try json.text(json.get(response.value, "id") orelse return error.InvalidPeer), id)) return error.InvalidPeer;
        if (json.get(response.value, "error") != null) return error.PeerRejected;
        return json.copy(a, json.get(response.value, "result") orelse return error.InvalidPeer);
    }

    pub fn request(self: *Connection, a: std.mem.Allocator, value: p.Request) !json.Value {
        var params = json.object();
        try json.put(a, &params, "request", try values.toJson(p.Request, a, value));
        return self.rpc(a, "placement", params);
    }

    pub fn transfer(self: *Connection, a: std.mem.Allocator, offer: p.Signed(p.Offer), path: []const u8) !p.Signed(p.Decision) {
        const archive = @import("archive.zig");
        var reader = try archive.Reader.open(a, path);
        defer reader.deinit();
        if (!std.meta.eql(reader.identity, offer.value.archive_digest) or reader.bytes != offer.value.archive_bytes) return error.InvalidTransfer;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        var offset = try values.fromJson(u64, scratch.allocator(), try self.request(scratch.allocator(), .{ .stage = .{ .peer = .{ .bytes = self.channel.remote_name }, .offer = offer, .offset = 0, .bytes = .{ .bytes = &.{} } } }));
        if (offset > reader.bytes) return error.InvalidPeer;
        var buffer: [32768]u8 = undefined;
        while (offset < reader.bytes) {
            _ = scratch.reset(.retain_capacity);
            const length: usize = @intCast(@min(buffer.len, reader.bytes - offset));
            var read_count: usize = 0;
            while (read_count < length) {
                const n = c.pread(reader.fd, buffer[read_count..].ptr, length - read_count, @intCast(offset + read_count));
                if (n < 0 and std.c.errno(n) == .INTR) continue;
                if (n <= 0) return error.InvalidArchive;
                read_count += @intCast(n);
            }
            const next = try values.fromJson(u64, scratch.allocator(), try self.request(scratch.allocator(), .{ .stage = .{ .peer = .{ .bytes = self.channel.remote_name }, .offer = offer, .offset = offset, .bytes = .{ .bytes = buffer[0..length] } } }));
            if (next != offset + length) return error.InvalidPeer;
            offset = next;
        }
        _ = scratch.reset(.retain_capacity);
        const operation_name = std.fmt.bytesToHex(offer.value.intent.transfer, .lower);
        const response = self.request(scratch.allocator(), .{ .accept_staged = .{ .operation = .{ .bytes = &operation_name }, .peer = .{ .bytes = self.channel.remote_name }, .offer = offer } }) catch |err| {
            if (err != error.PeerRejected) return err;
            // A reported error is not evidence that acceptance did not commit.
            // The native decision owner returns any prior acceptance here.
            const decided = try self.request(scratch.allocator(), .{ .refuse = .{ .peer = .{ .bytes = self.channel.remote_name }, .offer = offer, .reason = .withdrawn } });
            const decision = try values.fromJson(p.Signed(p.Decision), scratch.allocator(), decided);
            try p.matchDecision(a, offer.value, decision);
            return decision;
        };
        const decision = try values.fromJson(p.Signed(p.Decision), scratch.allocator(), response);
        try p.matchDecision(a, offer.value, decision);
        return decision;
    }
};
