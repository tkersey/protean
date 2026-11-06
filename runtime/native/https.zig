//! A single cancellable HTTPS POST. No redirects, retries, proxy discovery, or
//! provider interpretation. The caller persists captured bytes before decoding.
const std = @import("std");
const sse = @import("responses_sse.zig");
pub const Format = sse.Format;

pub const Config = struct {
    endpoint: []const u8,
    /// Explicit launch input; never discover credentials from the environment.
    token: []const u8,
    /// Explicit DER trust root, or the platform's declared system trust store.
    trust_root: ?[]const u8 = null,
    request_limit: ?u32 = null,
    response_limit: ?u32 = null,
    timeout_ms: ?u32 = null,
    format: Format = .json,

    pub fn validate(self: Config) !std.Uri {
        if (self.endpoint.len == 0 or self.token.len == 0 or
            self.request_limit == 0 or
            self.response_limit == 0 or
            self.timeout_ms == 0) return error.InvalidConfiguration;
        for (self.endpoint) |byte| if (byte <= 0x20 or
            byte >= 0x7f or
            byte == '\\') return error.InvalidConfiguration;
        for (self.token) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguration;
        if (self.trust_root) |root| if (root.len == 0) return error.InvalidConfiguration;
        const uri = std.Uri.parse(self.endpoint) catch return error.InvalidConfiguration;
        if (!std.mem.eql(
            u8,
            uri.scheme,
            "https",
        ) or
            uri.host == null or
            uri.user != null or
            uri.password != null or
            uri.fragment != null) return error.InvalidConfiguration;
        return uri;
    }
};

pub const Capture = struct {
    status: u16,
    identity_encoding: bool,
    format: Format = .json,
    media_type: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    request_id: ?[]const u8,
    body: []const u8,

    pub fn deinit(self: Capture, a: std.mem.Allocator) void {
        if (self.request_id) |id| a.free(id);
        if (self.media_type) |value| a.free(value);
        if (self.content_encoding) |value| a.free(value);
        a.free(self.body);
    }
};
pub const Outcome = union(enum) {
    captured: Capture,
    definitely_not_sent: anyerror,
    unknown: anyerror,
};

const Exchange = struct {
    a: std.mem.Allocator,
    io: std.Io,
    config: Config,
    uri: std.Uri,
    body: []const u8,
    sent: bool = false,
    capture: ?Capture = null,
    failure: ?anyerror = null,

    fn perform(self: *Exchange) void {
        self.capture = self.send() catch |err| {
            self.failure = err;
            return;
        };
    }

    fn send(self: *Exchange) !Capture {
        var client: std.http.Client = .{
            .allocator = self.a,
            .io = self.io,
            .read_buffer_size = 16 * 1024,
        };
        defer client.deinit();
        if (self.config.trust_root) |der| {
            const now = std.Io.Clock.real.now(self.io);
            try client.ca_bundle.bytes.appendSlice(self.a, der);
            try client.ca_bundle.parseCert(self.a, 0, now.toSeconds());
            client.now = now;
        }
        const authorization = try std.fmt.allocPrint(self.a, "Bearer {s}", .{self.config.token});
        defer {
            std.crypto.secureZero(u8, authorization);
            self.a.free(authorization);
        }
        var request = try client.request(.POST, self.uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .extra_headers = if (self.config.format == .sse)
                &.{.{ .name = "accept", .value = "text/event-stream" }}
            else
                &.{},
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer releaseRequest(&request);
        request.transfer_encoding = .{ .content_length = self.body.len };
        // From this point, even a partial write may have dispatched inference.
        self.sent = true;
        var body = try request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(self.body);
        try body.end();
        try request.connection.?.flush();
        var response = try request.receiveHead(&.{});
        return self.collect(&response);
    }

    fn collect(self: *Exchange, response: *std.http.Client.Response) !Capture {
        const identity_encoding = response.head.content_encoding == .identity;
        var metadata = try self.readMetadata(response);
        metadata.identity_encoding = identity_encoding;
        const streamed = self.config.format == .sse and metadata.status >= 200 and
            metadata.status < 300 and identity_encoding and sse.eventStream(metadata.media_type);
        if (response.head.content_length) |length| {
            if (!streamed and self.config.response_limit != null and
                length > self.config.response_limit.?)
                return error.ResponseCapacity;
        }
        if (streamed) {
            metadata.body = try self.readStream(response.reader(&.{}));
            return metadata;
        }
        const expected_length = if (response.head.transfer_encoding == .none)
            response.head.content_length
        else
            null;
        const bytes = response.reader(&.{}).allocRemaining(
            self.a,
            if (self.config.response_limit) |limit| .limited(limit) else .unlimited,
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseCapacity,
            error.ReadFailed => return response.bodyErr() orelse err,
            else => return err,
        };
        // The standard fixed-length reader propagates transport EOF unchanged;
        // allocRemaining accepts EOF even when declared body bytes are missing.
        if (expected_length) |length| if (bytes.len != length) return error.TruncatedResponse;
        metadata.body = bytes;
        return metadata;
    }

    fn readMetadata(self: *Exchange, response: *std.http.Client.Response) !Capture {
        var capture: Capture = .{
            .status = @intCast(@backingInt(response.head.status)),
            .identity_encoding = true,
            .format = self.config.format,
            .request_id = null,
            .body = &.{},
        };
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            inline for (.{
                .{ "x-request-id", "request_id" },
                .{ "content-type", "media_type" },
                .{ "content-encoding", "content_encoding" },
            }) |mapping| if (std.ascii.eqlIgnoreCase(header.name, mapping[0])) {
                if (@field(capture, mapping[1]) != null) return error.DuplicateResponseHeader;
                @field(capture, mapping[1]) = try self.a.dupe(u8, header.value);
            };
        }
        return capture;
    }

    fn readStream(self: *Exchange, reader: *std.Io.Reader) ![]const u8 {
        var bytes: std.ArrayList(u8) = .empty;
        var framer: sse.Framer = .{};
        var buffer: [4096]u8 = undefined;
        var eof = false;
        while (!eof) {
            var vectors = [_][]u8{&buffer};
            const buffered = reader.buffered();
            const count = if (buffered.len != 0) blk: {
                const count = @min(buffered.len, buffer.len);
                @memcpy(buffer[0..count], buffered[0..count]);
                reader.toss(count);
                break :blk count;
            } else reader.readVec(&vectors) catch |err| switch (err) {
                error.EndOfStream => blk: {
                    eof = true;
                    break :blk 0;
                },
                else => return err,
            };
            try bytes.appendSlice(self.a, buffer[0..count]);
            while (framer.next(bytes.items, eof)) |frame| {
                if (!try sse.terminalFrame(self.a, frame)) continue;
                return self.finishStream(&bytes, framer.offset);
            }
            var final_carriage_return = framer;
            if (final_carriage_return.next(bytes.items, true)) |frame| {
                if (try sse.terminalFrame(self.a, frame))
                    return self.finishStream(&bytes, final_carriage_return.offset);
            }
            if (self.config.response_limit) |limit| if (bytes.items.len > limit)
                return error.ResponseCapacity;
        }
        return error.MissingTerminalResponse;
    }

    fn finishStream(self: *Exchange, bytes: *std.ArrayList(u8), boundary: usize) ![]const u8 {
        if (self.config.response_limit) |limit| if (boundary > limit) return error.ResponseCapacity;
        bytes.shrinkRetainingCapacity(boundary);
        return bytes.toOwnedSlice(self.a);
    }
};

fn releaseRequest(request: *std.http.Client.Request) void {
    if (request.connection) |connection| {
        connection.closing = true;
        std.crypto.secureZero(u8, connection.writer().buffer);
        std.crypto.secureZero(u8, connection.stream_writer.interface.buffer);
    }
    request.deinit();
}

fn deadline(io: std.Io, milliseconds: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(milliseconds), .awake);
}

fn copyCapture(a: std.mem.Allocator, capture: Capture) !Capture {
    var result = capture;
    result.body = try a.dupe(u8, capture.body);
    errdefer a.free(result.body);
    result.request_id = if (capture.request_id) |value| try a.dupe(u8, value) else null;
    errdefer if (result.request_id) |value| a.free(value);
    result.media_type = if (capture.media_type) |value| try a.dupe(u8, value) else null;
    errdefer if (result.media_type) |value| a.free(value);
    result.content_encoding = if (capture.content_encoding) |value| try a.dupe(u8, value) else null;
    return result;
}

pub fn post(a: std.mem.Allocator, io: std.Io, config: Config, body: []const u8) Outcome {
    const uri = config.validate() catch |err| return .{ .definitely_not_sent = err };
    if (config.request_limit != null and body.len > config.request_limit.?) return .{
        .definitely_not_sent = error.RequestCapacity,
    };
    // This arena is touched only by the exchange task until it joins. Results
    // losing a race with the timer remain owned here and cannot leak.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var exchange: Exchange = .{
        .a = arena.allocator(),
        .io = io,
        .config = config,
        .uri = uri,
        .body = body,
    };
    const Event = union(enum) { response: void, timer: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &events);
    if (config.timeout_ms) |milliseconds| select.concurrent(.timer, deadline, .{
        io,
        milliseconds,
    }) catch |err| return .{ .definitely_not_sent = err };
    select.concurrent(.response, Exchange.perform, .{&exchange}) catch |err| {
        select.cancelDiscard();
        return .{ .definitely_not_sent = err };
    };
    const first: ?Event = select.await() catch null;
    select.cancelDiscard();
    // A complete response wins even when cancellation or the timer became
    // ready concurrently. It must not be downgraded to unknown delivery.
    if (exchange.capture) |capture| {
        return .{ .captured = copyCapture(a, capture) catch |err| return .{ .unknown = err } };
    }
    const failure = if (first == null)
        error.Canceled
    else if (first.? == .timer)
        error.Timeout
    else
        exchange.failure orelse error.TransportFailure;
    return if (exchange.sent) .{ .unknown = failure } else .{ .definitely_not_sent = failure };
}

test "HTTPS rejects plaintext, authority confusion and header injection before dispatch" {
    for ([_][]const u8{
        "http://example.test/v1/responses",
        "https://user@example.test/",
        "https://example.test/#fragment",
        "https://example.test/\r\nx: y",
    }) |endpoint| {
        try std.testing.expectError(
            error.InvalidConfiguration,
            (Config{ .endpoint = endpoint, .token = "fixture" }).validate(),
        );
    }
    try std.testing.expectError(
        error.InvalidConfiguration,
        (Config{ .endpoint = "https://example.test/", .token = "x\r\ny" }).validate(),
    );
    _ = try (Config{
        .endpoint = "https://example.test/v1/responses",
        .token = "fixture",
    }).validate();
}

test "HTTPS SSE reader stops at terminal before trailing bytes and enforces captured byte cap" {
    const terminal = "event: error\ndata: {\"type\":\"error\"}\n\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var exchange: Exchange = .{
        .a = arena.allocator(),
        .io = std.testing.io,
        .config = .{ .endpoint = "https://example.test/", .token = "fixture", .format = .sse },
        .uri = try std.Uri.parse("https://example.test/"),
        .body = "{}",
    };
    var reader = std.Io.Reader.fixed(terminal ++ "unread trailing bytes");
    exchange.config.response_limit = terminal.len;
    try std.testing.expectEqualStrings(terminal, try exchange.readStream(&reader));
    reader = .failing;
    reader.buffer = @constCast(terminal);
    reader.end = terminal.len;
    try std.testing.expectEqualStrings(terminal, try exchange.readStream(&reader));
    const carriage_terminal = "event: error\rdata: {\"type\":\"error\"}\r\r";
    reader = .failing;
    reader.buffer = @constCast(carriage_terminal);
    reader.end = carriage_terminal.len;
    try std.testing.expectEqualStrings(carriage_terminal, try exchange.readStream(&reader));
    reader = .fixed(terminal);
    exchange.config.response_limit = terminal.len - 1;
    try std.testing.expectError(error.ResponseCapacity, exchange.readStream(&reader));
    reader = .fixed("data: [DONE]\n\n");
    try std.testing.expectError(error.MissingTerminalResponse, exchange.readStream(&reader));
}

fn captureAllocationProbe(a: std.mem.Allocator) !void {
    const capture = try copyCapture(a, .{
        .status = 200,
        .identity_encoding = true,
        .format = .sse,
        .media_type = "text/event-stream",
        .content_encoding = "identity",
        .request_id = "request-fixture",
        .body = "event: error\ndata: {\"type\":\"error\"}\n\n",
    });
    defer capture.deinit(a);
    try std.testing.expectEqualStrings("text/event-stream", capture.media_type.?);
}

test "HTTPS capture transfer cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, captureAllocationProbe, .{});
}

test "HTTPS invalid configuration remains unsent without network access" {
    const outcome = post(
        std.testing.allocator,
        std.testing.io,
        .{ .endpoint = "http://example.test/", .token = "fixture" },
        "{}",
    );
    try std.testing.expect(outcome == .definitely_not_sent);
}
