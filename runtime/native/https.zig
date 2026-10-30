//! A single cancellable HTTPS POST. No redirects, retries, proxy discovery, or
//! provider interpretation. The caller persists captured bytes before decoding.
const std = @import("std");

pub const Config = struct {
    endpoint: []const u8,
    /// Explicit launch input; never discover credentials from the environment.
    token: []const u8,
    /// Explicit DER trust root, or the platform's declared system trust store.
    trust_root: ?[]const u8 = null,
    request_limit: ?u32 = null,
    response_limit: ?u32 = null,
    timeout_ms: ?u32 = null,

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
    request_id: ?[]const u8,
    body: []const u8,

    pub fn deinit(self: Capture, a: std.mem.Allocator) void {
        if (self.request_id) |id| a.free(id);
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
        defer self.a.free(authorization);
        var request = try client.request(.POST, self.uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = self.body.len };
        // From this point, even a partial write may have dispatched inference.
        self.sent = true;
        var body = try request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(self.body);
        try body.end();
        try request.connection.?.flush();
        var response = try request.receiveHead(&.{});
        const identity_encoding = response.head.content_encoding == .identity;
        if (response.head.content_length) |length| {
            if (self.config.response_limit != null and length > self.config.response_limit.?)
                return error.ResponseCapacity;
        }
        var request_id: ?[]const u8 = null;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "x-request-id")) continue;
            if (request_id != null) return error.InvalidResponseIdentifier;
            request_id = try self.a.dupe(u8, header.value);
        }
        const status: u16 = @intCast(@backingInt(response.head.status));
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
        return .{
            .status = status,
            .identity_encoding = identity_encoding,
            .request_id = request_id,
            .body = bytes,
        };
    }
};

fn deadline(io: std.Io, milliseconds: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(milliseconds), .awake);
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
        const bytes = a.dupe(u8, capture.body) catch |err| return .{ .unknown = err };
        const id = if (capture.request_id) |value| a.dupe(u8, value) catch |err| {
            a.free(bytes);
            return .{ .unknown = err };
        } else null;
        return .{ .captured = .{
            .status = capture.status,
            .identity_encoding = capture.identity_encoding,
            .request_id = id,
            .body = bytes,
        } };
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
