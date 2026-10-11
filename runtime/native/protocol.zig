//! agent-host/1.0 admission. This layer cannot drive Kronos or dispatch a tool.
const std = @import("std");
const json = @import("json.zig");
pub const version = "agent-host/1.0";

pub const Limits = struct {
    frame_bytes: usize = 1024 * 1024,
    json_depth: usize = 32,
    json_tokens: usize = 65_536,
    id_bytes: usize = 128,
    object_members: usize = 4096,
    batch_elements: usize = 16,
    in_flight_calls: usize = 16,
    outbound_bytes: usize = 4 * 1024 * 1024,
    inline_bytes: usize = 60 * 1024,
    artifact_chunk_bytes: usize = 32 * 1024,
    event_page: usize = 128,
    subscriptions: usize = 16,
    nonterminal_tasks: usize = 16,
    queued_messages: usize = 16,
    queued_message_bytes: usize = 256 * 1024,
    incomplete_frame_ms: u32 = 30_000,
    output_stall_ms: u32 = 5000,
    state_database_bytes: u64 = @import("native_options").state_bytes,
};

/// Caller supplies a bounded buffer of frame_bytes - 1. Returned frames borrow
/// it until the next push; parsing/admission must finish before that call.
pub const Framer = struct {
    buffer: []u8,
    length: usize = 0,
    ready: bool = false,
    pub const Read = struct { consumed: usize, frame: ?[]const u8 };

    pub fn push(self: *Framer, input: []const u8) error{FrameTooLarge}!Read {
        if (self.ready) {
            self.length = 0;
            self.ready = false;
        }
        const newline = std.mem.indexOfScalar(u8, input, '\n');
        const count = newline orelse input.len;
        if (count > self.buffer.len - self.length) return error.FrameTooLarge;
        @memcpy(self.buffer[self.length..][0..count], input[0..count]);
        self.length += count;
        if (newline == null) return .{ .consumed = count, .frame = null };
        self.ready = true;
        const end = self.length - @intFromBool(self.length != 0 and self.buffer[self.length - 1] == '\r');
        return .{ .consumed = count + 1, .frame = self.buffer[0..end] };
    }
    pub fn incomplete(self: Framer) bool {
        return self.length != 0 and !self.ready;
    }
    pub fn eof(self: Framer) error{TruncatedFrame}!void {
        if (self.incomplete()) return error.TruncatedFrame;
    }
};

pub const Kind = enum {
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    ProtocolState,
    Denied,
    NotFound,
    UnsupportedCapability,
    OperationConflict,
    StaleInteraction,
    AnswerConflict,
    CursorExpired,
    Overloaded,
    StateConflict,
    ArtifactUnavailable,
    StorageUnavailable,

    pub fn code(kind: Kind) i32 {
        return switch (kind) {
            .ParseError => -32700,
            .InvalidRequest => -32600,
            .MethodNotFound => -32601,
            .InvalidParams => -32602,
            .InternalError => -32603,
            .ProtocolState => -32000,
            .Denied => -32001,
            .NotFound => -32002,
            .UnsupportedCapability => -32003,
            .OperationConflict => -32004,
            .StaleInteraction => -32005,
            .AnswerConflict => -32006,
            .CursorExpired => -32007,
            .Overloaded => -32008,
            .StateConflict => -32009,
            .ArtifactUnavailable => -32010,
            .StorageUnavailable => -32011,
        };
    }
};

pub const Method = enum {
    initialize,
    describe,
    ping,
    @"task.submit",
    @"task.message",
    @"task.respond",
    @"task.status",
    @"task.result",
    @"task.events",
    @"task.subscribe",
    @"task.unsubscribe",
    @"task.cancel",
    @"task.resume",
    @"artifact.read",
    shutdown,
};

pub const Fields = struct { required: []const []const u8, optional: []const []const u8 = &.{} };
pub fn fields(method: Method) Fields {
    return switch (method) {
        .initialize => .{ .required = &.{"protocol_versions"}, .optional = &.{"client_info"} },
        .describe => .{ .required = &.{}, .optional = &.{ "application_id", "cursor", "limit" } },
        .ping => .{ .required = &.{} },
        .@"task.submit" => .{ .required = &.{ "client_operation_id", "application_id", "profile_id", "input" } },
        .@"task.message" => .{ .required = &.{ "client_operation_id", "task_id", "message" } },
        .@"task.respond" => .{ .required = &.{ "client_operation_id", "task_id", "question_id", "question_revision", "request_digest", "answer" } },
        .@"task.status", .@"task.result" => .{ .required = &.{"task_id"} },
        .@"task.events" => .{ .required = &.{ "task_id", "after_seq" }, .optional = &.{"limit"} },
        .@"task.subscribe" => .{ .required = &.{ "task_id", "after_seq" } },
        .@"task.unsubscribe" => .{ .required = &.{"subscription_id"} },
        .@"task.cancel" => .{ .required = &.{ "client_operation_id", "task_id" }, .optional = &.{"reason"} },
        .@"task.resume" => .{ .required = &.{ "client_operation_id", "task_id", "expected_revision" } },
        .@"artifact.read" => .{ .required = &.{ "artifact_id", "offset", "length" }, .optional = &.{ "task_id", "question_id" } },
        .shutdown => .{ .required = &.{"mode"} },
    };
}

pub fn closed(value: json.Value, spec: Fields) error{InvalidParams}!void {
    if (value != .object or value.object.count() < spec.required.len or value.object.count() > spec.required.len + spec.optional.len) return error.InvalidParams;
    for (spec.required) |key| if (!value.object.contains(key)) return error.InvalidParams;
    for (value.object.keys()) |key| {
        var known = false;
        for (spec.required) |allowed| known = known or std.mem.eql(u8, key, allowed);
        for (spec.optional) |allowed| known = known or std.mem.eql(u8, key, allowed);
        if (!known) return error.InvalidParams;
    }
}

pub const Call = struct { id: json.Value, method: Method, params: json.Value };
pub const Failure = struct { id: json.Value = .null, kind: Kind };
pub const Admitted = union(enum) { call: Call, notification, failure: Failure };

fn validId(value: json.Value, limit: usize) bool {
    return switch (value) {
        .null => true,
        .string => |text| text.len > 0 and text.len <= limit,
        .number_string => |text| blk: {
            if (text.len > limit) break :blk false;
            const integer = json.safeInteger(text) catch break :blk false;
            break :blk integer >= -9007199254740991 and integer <= 9007199254740991;
        },
        else => false,
    };
}

pub fn admit(value: json.Value, limits: Limits, batch: bool) Admitted {
    closed(value, .{ .required = &.{ "jsonrpc", "method" }, .optional = &.{ "id", "params" } }) catch
        return .{ .failure = .{ .kind = .InvalidRequest } };
    const rpc = value.object.get("jsonrpc").?;
    const name = value.object.get("method").?;
    if (rpc != .string or !std.mem.eql(u8, rpc.string, "2.0") or name != .string or name.string.len == 0 or name.string.len > limits.id_bytes)
        return .{ .failure = .{ .kind = .InvalidRequest } };
    // A structurally valid notification cannot mutate state, even when it names
    // a real method. No response is emitted and no initialization is performed.
    const id = value.object.get("id") orelse return .notification;
    if (!validId(id, limits.id_bytes)) return .{ .failure = .{ .kind = .InvalidRequest } };
    const params = value.object.get("params") orelse return .{ .failure = .{ .id = id, .kind = .InvalidParams } };
    const method = std.meta.stringToEnum(Method, name.string) orelse return .{ .failure = .{ .id = id, .kind = .MethodNotFound } };
    if (batch and method == .initialize) return .{ .failure = .{ .id = id, .kind = .InvalidRequest } };
    closed(params, fields(method)) catch return .{ .failure = .{ .id = id, .kind = .InvalidParams } };
    return .{ .call = .{ .id = id, .method = method, .params = params } };
}

pub fn equalId(a: json.Value, b: json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .string => |s| std.mem.eql(u8, s, b.string),
        .number_string => |s| (json.safeInteger(s) catch return false) == (json.safeInteger(b.number_string) catch return false),
        else => false,
    };
}

/// Preflight the complete bounded batch before any member can reach an owner.
/// Duplicate IDs are a connection-fatal correlation ambiguity, not two calls.
pub fn batchPreflight(values: []const json.Value, limits: Limits) error{ InvalidBatch, DuplicateId }!void {
    if (values.len == 0 or values.len > limits.batch_elements) return error.InvalidBatch;
    for (values, 0..) |value, i| {
        const id = json.get(value, "id") orelse continue;
        if (!validId(id, limits.id_bytes)) continue;
        for (values[0..i]) |prior| if (json.get(prior, "id")) |other| {
            if (validId(other, limits.id_bytes) and equalId(id, other)) return error.DuplicateId;
        };
    }
}

pub fn response(a: std.mem.Allocator, id: json.Value, result: json.Value) !json.Value {
    var output = json.object();
    try json.put(a, &output, "jsonrpc", json.string("2.0"));
    try json.put(a, &output, "id", id);
    try json.put(a, &output, "result", result);
    return output;
}
pub fn failure(a: std.mem.Allocator, id: json.Value, kind: Kind, recovery: []const u8) !json.Value {
    var details = json.object();
    try json.put(a, &details, "kind", json.string(@tagName(kind)));
    try json.put(a, &details, "recovery", json.string(recovery));
    var fault = json.object();
    try json.put(a, &fault, "code", try json.number(a, kind.code()));
    try json.put(a, &fault, "message", json.string(@tagName(kind)));
    try json.put(a, &fault, "data", details);
    var output = json.object();
    try json.put(a, &output, "jsonrpc", json.string("2.0"));
    try json.put(a, &output, "id", id);
    try json.put(a, &output, "error", fault);
    return output;
}
pub fn notification(a: std.mem.Allocator, method: []const u8, params: json.Value) !json.Value {
    var output = json.object();
    try json.put(a, &output, "jsonrpc", json.string("2.0"));
    try json.put(a, &output, "method", json.string(method));
    try json.put(a, &output, "params", params);
    return output;
}

test "framer handles split utf8 coalescing crlf truncation and exact limits" {
    var buffer: [16]u8 = undefined;
    var framing = Framer{ .buffer = &buffer };
    try std.testing.expect((try framing.push("\"\xe9")).frame == null);
    const first = try framing.push("\x9b\xaa\"\r\n{}\n");
    try std.testing.expectEqualStrings("\"雪\"", first.frame.?);
    try std.testing.expectEqual(5, first.consumed);
    try std.testing.expectEqualStrings("{}", (try framing.push("{}\n")).frame.?);
    try framing.eof();
    _ = try framing.push("[1");
    try std.testing.expectError(error.TruncatedFrame, framing.eof());
    try std.testing.expectError(error.FrameTooLarge, framing.push("012345678901234"));
}

test "notifications never become calls and batch duplicate ids fail before dispatch" {
    const a = std.testing.allocator;
    var ignored = try json.parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"task.cancel\",\"params\":{}}", .{});
    defer ignored.deinit();
    try std.testing.expect(admit(ignored.value, .{}, false) == .notification);
    var batch = try json.parse(a, "[{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"id\":\"x\"},{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"id\":\"x\"}]", .{});
    defer batch.deinit();
    try std.testing.expectError(error.DuplicateId, batchPreflight(batch.value.array.items, .{}));
    try std.testing.expectError(error.InvalidBatch, batchPreflight(&.{}, .{}));
}
