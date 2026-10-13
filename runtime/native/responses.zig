//! Responses transport and normalization. All actions remain ordinary proposals
//! for the existing checked responder; this adapter never dispatches tools.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const json = @import("json.zig");
const https = @import("https.zig");
const storage = @import("store.zig");

pub const Settings = struct {
    endpoint: contracts.Text(2048),
    audience: contracts.Text(128),
    model: contracts.Text(128),
    effort: contracts.Text(16),
    max_output_tokens: ?u32,
    request_bytes: ?u32,
    response_bytes: ?u32,
    timeout_ms: ?u32,
};
pub const Environment = struct {
    token: []const u8,
    approved_endpoint: []const u8,
    trust_root: ?[]const u8 = null,
};
pub const Raw = contracts.CapturedResponse;

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn field(value: json.Value, key: []const u8) !json.Value {
    return json.get(value, key) orelse error.UnsupportedResponse;
}
fn text(value: json.Value, key: []const u8) ![]const u8 {
    return json.text(try field(value, key));
}
fn is(value: json.Value, key: []const u8, expected: []const u8) bool {
    return equal(text(value, key) catch return false, expected);
}
fn only(value: json.Value, keys: []const []const u8) !void {
    if (value != .object) return error.UnsupportedResponse;
    for (value.object.keys()) |key| {
        var found = false;
        for (keys) |allowed| found = found or equal(key, allowed);
        if (!found) return error.UnsupportedResponse;
    }
}
fn list(a: std.mem.Allocator) json.Value {
    return .{ .array = .init(a) };
}
const ArgumentError = error{ WrongType, UnknownField, MissingField, IntegerRange, Capacity } || std.mem.Allocator.Error;
fn argument(comptime T: type, a: std.mem.Allocator, value: json.Value) ArgumentError!T {
    if (comptime contracts.json.isText(T)) {
        if (value != .string) return error.WrongType;
        if (contracts.exceeds(value.string.len, T.max_length)) return error.Capacity;
        return .{ .bytes = value.string };
    }
    if (comptime contracts.native.wrapped(T) and T.protean_value_kind == .vector) {
        if (value != .array) return error.WrongType;
        if (contracts.exceeds(value.array.items.len, T.max_length)) return error.Capacity;
        const items = try a.alloc(T.Child, value.array.items.len);
        errdefer a.free(items);
        for (items, value.array.items) |*item, child| item.* = try argument(T.Child, a, child);
        return .{ .items = items };
    }
    return switch (@typeInfo(T)) {
        .int => blk: {
            if (value != .number_string) return error.WrongType;
            // The shared model contract first classifies an exact i64/u64
            // JSON integer, then applies the field's narrower range. A
            // nonintegral/outside-carrier number is a type error, not overflow
            // of an otherwise admitted integer field.
            if (value.number_string[0] == '-') {
                const number = json.numberInteger(i64, value.number_string) catch return error.WrongType;
                if (number < 0 and @typeInfo(T).int.signedness == .unsigned) return error.WrongType;
                break :blk std.math.cast(T, number) orelse error.IntegerRange;
            }
            const number = json.numberInteger(u64, value.number_string) catch return error.WrongType;
            break :blk std.math.cast(T, number) orelse error.IntegerRange;
        },
        .bool => if (value == .bool) value.bool else error.WrongType,
        .@"enum" => blk: {
            if (value != .string) return error.WrongType;
            inline for (@typeInfo(T).@"enum".field_names) |name| if (equal(value.string, name)) break :blk @field(T, name);
            return error.WrongType;
        },
        .@"struct" => |info| blk: {
            if (value != .object) return error.WrongType;
            for (value.object.keys()) |key| {
                var found = false;
                inline for (info.field_names) |name| found = found or equal(key, name);
                if (!found) return error.UnknownField;
            }
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, FieldType| @field(result, name) = try argument(FieldType, a, value.object.get(name) orelse return error.MissingField);
            break :blk result;
        },
        else => @compileError("unsupported model argument"),
    };
}

/// Provider output grammar shared by the sole v11 adapter and pure recovery.
pub fn OutputNormalizer(comptime P: type) type {
    return struct {
        fn decodeAction(a: std.mem.Allocator, name: []const u8, arguments: []const u8) !P.DecodedAnswer {
            // Admission bounds count supplied fields, including duplicates,
            // before typed decoding, as in the retained shared contract.
            var scanner = std.json.Scanner.initCompleteInput(a, arguments);
            defer scanner.deinit();
            if ((scanner.next() catch return .{ .invalid = .malformed }) != .object_begin) return .{ .invalid = .malformed };
            var fields: usize = 0;
            const limits = P.normalizationLimits();
            while ((scanner.peekNextTokenType() catch return .{ .invalid = .malformed }) != .object_end) : (fields += 1) {
                if (fields == limits.maximum_argument_fields) return .{ .invalid = .capacity };
                const token = scanner.nextAllocMax(a, .alloc_if_needed, arguments.len) catch return .{ .invalid = .malformed };
                const key = switch (token) {
                    .string, .allocated_string => |bytes| bytes,
                    else => return .{ .invalid = .malformed },
                };
                defer if (token == .allocated_string) a.free(token.allocated_string);
                if (key.len > limits.maximum_argument_name_bytes) return .{ .invalid = .malformed };
                scanner.skipValue() catch return .{ .invalid = .malformed };
            }
            _ = scanner.next() catch return .{ .invalid = .malformed };
            if ((scanner.next() catch return .{ .invalid = .malformed }) != .end_of_document) return .{ .invalid = .malformed };
            const parsed = json.parse(a, arguments, .{ .bytes = P.representation.arguments_json_bytes orelse arguments.len, .tokens = arguments.len, .members = arguments.len }) catch |err| return .{ .invalid = switch (err) {
                error.DuplicateKey => .duplicate_field,
                error.Capacity => .capacity,
                else => .malformed,
            } };
            inline for (@typeInfo(P.AnswerType).@"union".field_names, @typeInfo(P.AnswerType).@"union".field_types, 0..) |tag, T, index| {
                if (equal(name, P.allDeclarations().items[index].name.bytes)) {
                    const child = if (@typeInfo(T) == .@"enum") blk: {
                        if (parsed.value != .object or parsed.value.object.count() != 1) return .{ .invalid = .unknown_field };
                        break :blk parsed.value.object.get("value") orelse return .{ .invalid = .missing_field };
                    } else parsed.value;
                    const value = argument(T, a, child) catch |err| return .{ .invalid = switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.WrongType => .wrong_type,
                        error.UnknownField => .unknown_field,
                        error.MissingField => .missing_field,
                        error.IntegerRange => .integer_range,
                        error.Capacity => .capacity,
                    } };
                    return .{ .decoded = @unionInit(P.AnswerType, tag, value) };
                }
            }
            return .{ .invalid = .unknown_field };
        }

        /// Output grammar and exact argument codec. Policy and context admission
        /// belong to the v11 adapter.
        pub fn normalize(a: std.mem.Allocator, invocation: P.Request, output: json.Value) !P.Result {
            var items: std.ArrayList(P.OutputItem) = .empty;
            var calls: usize = 0;
            var refusal: ?[]const u8 = null;
            for (output.array.items) |item| {
                _ = try replayItem(a, item);
                if (is(item, "type", "function_call")) {
                    calls += 1;
                    if (calls > 1) return error.UnsupportedResponse;
                    const call_id = try text(item, "call_id");
                    const name = try text(item, "name");
                    const args = try text(item, "arguments");
                    if (call_id.len == 0 or contracts.exceeds(call_id.len, P.representation.call_id_bytes) or name.len > P.ToolName.max_length.? or contracts.exceeds(args.len, P.representation.arguments_json_bytes)) return error.Capacity;
                    var ordinal: u32 = std.math.maxInt(u32);
                    for (invocation.tools.items) |tool| if (equal(tool.name.bytes, name)) {
                        ordinal = tool.action_ordinal;
                    };
                    try items.append(a, .{ .function_call = .{ .call_id = .{ .bytes = call_id }, .name = .{ .bytes = name }, .arguments_json = .{ .bytes = args }, .tool_ordinal_claim = ordinal, .decoded_action = if (ordinal == std.math.maxInt(u32)) .{ .invalid = .unknown_field } else try decodeAction(a, name, args) } });
                } else if (is(item, "type", "message")) {
                    var joined: std.ArrayList(u8) = .empty;
                    const content = try field(item, "content");
                    for (content.array.items) |part| {
                        if (is(part, "type", "refusal")) {
                            if (refusal != null or joined.items.len != 0) return error.MixedRefusal;
                            refusal = try text(part, "refusal");
                        } else {
                            if (refusal != null) return error.MixedRefusal;
                            try joined.appendSlice(a, try text(part, "text"));
                        }
                    }
                    if (contracts.exceeds(joined.items.len, P.representation.result_text_bytes)) return error.Capacity;
                    if (refusal == null) try items.append(a, .{ .message = .{ .role = .assistant, .content = .{ .bytes = joined.items } } });
                } else {
                    var joined: std.ArrayList(u8) = .empty;
                    const summary = try field(item, "summary");
                    for (summary.array.items, 0..) |part, index| {
                        if (index != 0) try joined.append(a, '\n');
                        try joined.appendSlice(a, try text(part, "text"));
                    }
                    if (contracts.exceeds(joined.items.len, P.representation.result_text_bytes)) return error.Capacity;
                    try items.append(a, .{ .reasoning = .{ .summary = .{ .bytes = joined.items } } });
                }
            }
            if (refusal) |message| {
                for (items.items) |item| if (item != .reasoning) return error.MixedRefusal;
                if (contracts.exceeds(message.len, P.representation.result_text_bytes)) return error.Capacity;
                return .{ .refusal = .{ .bytes = message } };
            }
            const encoded = try contracts.encodeOwned(P.OutputItems, a, .{ .items = items.items });
            return .{ .output = .{ .items = .{ .items = items.items }, .normalized_output_digest = storage.digest(encoded) } };
        }
    };
}

/// Transport only: callers derive these settings from their frozen policy and
/// exact prepared occurrence. This never changes Context.profile or chooses a
/// fallback model after ambiguous delivery.
pub fn acquireSettings(ctx: registry.Context, config: Settings, rendered: []const u8) !registry.Acquisition {
    ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
    const environment: *const Environment = @ptrCast(@alignCast(ctx.environment orelse return .{ .definitely_not_sent = error.MissingCredential }));
    if (!equal(config.endpoint.bytes, environment.approved_endpoint) or !ctx.authority.inference or ctx.authority.revoked or !ctx.authority.disclosure) return .{ .definitely_not_sent = error.Denied };
    return switch (https.post(ctx.allocator, ctx.io, .{ .endpoint = config.endpoint.bytes, .token = environment.token, .trust_root = environment.trust_root, .request_limit = config.request_bytes, .response_limit = config.response_bytes, .timeout_ms = config.timeout_ms }, rendered)) {
        .definitely_not_sent => |err| .{ .definitely_not_sent = err },
        .unknown => |err| .{ .unknown = err },
        .captured => |raw| .{ .captured = try contracts.encodeOwned(Raw, ctx.allocator, .{ .status = raw.status, .identity_encoding = raw.identity_encoding, .request_id = if (raw.request_id) |id| .{ .bytes = id } else null, .body = .{ .bytes = raw.body } }) },
    };
}

pub fn replayItem(a: std.mem.Allocator, item: json.Value) !json.Value {
    _ = a;
    if (is(item, "type", "function_call")) {
        try only(item, &.{ "type", "id", "call_id", "name", "arguments", "status" });
        if (!is(item, "status", "completed") or (try text(item, "call_id")).len == 0 or (try text(item, "name")).len == 0) return error.UnsupportedResponse;
        _ = try text(item, "arguments");
    } else if (is(item, "type", "reasoning")) {
        try only(item, &.{ "type", "id", "summary", "content", "encrypted_content", "status" });
        if (json.get(item, "status") != null and !is(item, "status", "completed")) return error.UnsupportedResponse;
        if ((try text(item, "encrypted_content")).len == 0) return error.UnsupportedResponse;
        // Responses may return optional reasoning content even when it is
        // empty. Validate its documented shape and retain the original item;
        // content is private replay material, not a public reasoning summary.
        if (json.get(item, "content")) |content| if (content != .null) {
            if (content != .array) return error.UnsupportedResponse;
            for (content.array.items) |part| {
                try only(part, &.{ "type", "text" });
                if (!is(part, "type", "reasoning_text")) return error.UnsupportedResponse;
                _ = try text(part, "text");
            }
        };
        const summary = try field(item, "summary");
        if (summary != .array) return error.UnsupportedResponse;
        for (summary.array.items) |part| {
            try only(part, &.{ "type", "text" });
            if (!is(part, "type", "summary_text")) return error.UnsupportedResponse;
            _ = try text(part, "text");
        }
    } else if (is(item, "type", "message")) {
        try only(item, &.{ "type", "id", "status", "role", "content", "phase" });
        if (!is(item, "status", "completed") or !is(item, "role", "assistant")) return error.UnsupportedResponse;
        if (json.get(item, "phase")) |phase| if (phase != .null and !equal(try json.text(phase), "commentary") and !equal(try json.text(phase), "final_answer")) return error.UnsupportedResponse;
        const content = try field(item, "content");
        if (content != .array or content.array.items.len == 0) return error.UnsupportedResponse;
        for (content.array.items) |part| {
            if (is(part, "type", "output_text")) {
                try only(part, &.{ "type", "text", "annotations", "logprobs" });
                _ = try text(part, "text");
                inline for (.{ "annotations", "logprobs" }) |key| if (json.get(part, key)) |annotations| {
                    if (annotations != .array or annotations.array.items.len != 0) return error.UnsupportedResponse;
                };
            } else if (is(part, "type", "refusal")) {
                try only(part, &.{ "type", "refusal" });
                _ = try text(part, "refusal");
            } else return error.UnsupportedResponse;
        }
    } else return error.UnsupportedResponse;
    if (json.get(item, "id")) |id| if (id != .string or id.string.len == 0) return error.UnsupportedResponse;
    return item;
}
