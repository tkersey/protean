//! Fixed-profile Responses projection. All actions remain ordinary proposals
//! for the existing checked responder; this adapter never dispatches tools.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const values = @import("values.zig");
const json = @import("json.zig");
const https = @import("https.zig");
const storage = @import("store.zig");

pub const Settings = struct {
    endpoint: contracts.Text(2048),
    audience: contracts.Text(128),
    model: contracts.Text(128),
    effort: contracts.Text(16),
    max_output_tokens: u32,
    request_bytes: u32,
    response_bytes: u32,
    timeout_ms: u32,
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
pub fn settings(a: std.mem.Allocator, profile: []const u8) !Settings {
    const parsed = try json.parse(a, profile, .{ .bytes = 256 * 1024 });
    const result = try values.fromJson(Settings, a, try field(parsed.value, "responses"));
    if (result.model.bytes.len == 0 or result.audience.bytes.len == 0 or result.max_output_tokens == 0 or result.max_output_tokens > 32768) return error.InvalidConfiguration;
    // HTTPS validates the finite transport limits without making a connection.
    _ = try (https.Config{ .endpoint = result.endpoint.bytes, .token = "validation", .request_limit = result.request_bytes, .response_limit = result.response_bytes, .timeout_ms = result.timeout_ms }).validate();
    return result;
}

const ArgumentError = error{ WrongType, UnknownField, MissingField, IntegerRange, Capacity };
fn argument(comptime T: type, value: json.Value) ArgumentError!T {
    if (comptime contracts.json.isText(T)) {
        if (value != .string) return error.WrongType;
        if (value.string.len > contracts.json.maximumTextBytes(T)) return error.Capacity;
        return .{ .bytes = value.string };
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
            inline for (info.field_names, info.field_types) |name, FieldType| @field(result, name) = try argument(FieldType, value.object.get(name) orelse return error.MissingField);
            break :blk result;
        },
        else => @compileError("unsupported model argument"),
    };
}

pub fn Adapter(comptime P: type) type {
    return struct {
        const Self = @This();
        const Reference = @typeInfo(@FieldType(P.ReferenceRequest, "replay")).optional.child;

        pub fn declaration() registry.Declaration {
            return .{ .identity = P.reference_identity, .resource_role = "inference", .kind = .leaf, .inference = true, .background = true, .payload_schema = struct {
                fn schema(a: std.mem.Allocator) ![]u8 {
                    return values.schemaBytes(P.ReferenceRequest, a);
                }
            }.schema, .resume_schema = struct {
                fn schema(a: std.mem.Allocator) ![]u8 {
                    return values.schemaBytes(P.ReferenceResult, a);
                }
            }.schema, .capture = .{ .prepare = prepare, .acquire = acquire, .interpret = interpret } };
        }

        fn bind(ctx: registry.ProjectionContext, request: P.ReferenceRequest, config: Settings) !void {
            const invocation = request.invocation;
            if (!equal(&request.profile, &storage.digest(ctx.profile)) or !equal(invocation.protocol.bytes, "agent.model.protocol.openai-responses-v2") or
                !equal(invocation.model.bytes, config.model.bytes) or invocation.parameters.max_output_tokens != config.max_output_tokens or invocation.parameters.temperature != null or
                invocation.response_policy.store or invocation.response_policy.stream or invocation.response_policy.background or
                invocation.selection.parallel_calls or invocation.selection.maximum_calls > 1 or invocation.selection.minimum_calls > invocation.selection.maximum_calls or
                invocation.maximum_provider_response_bytes != config.response_bytes or config.response_bytes > P.representation.provider_response_bytes) return error.IncompatibleProfile;
            const reasoning = invocation.parameters.reasoning orelse return error.IncompatibleProfile;
            if (reasoning.effort == null or !equal(@tagName(reasoning.effort.?), config.effort.bytes) or reasoning.summary != null) return error.IncompatibleProfile;
            const catalog = P.allDeclarations().items;
            var previous: ?u32 = null;
            for (invocation.tools.items) |tool| {
                if (tool.action_ordinal >= catalog.len or (previous != null and tool.action_ordinal <= previous.?)) return error.InvalidDeclaration;
                previous = tool.action_ordinal;
                const expected = try contracts.encodeOwned(P.ToolDeclaration, ctx.allocator, catalog[tool.action_ordinal]);
                const supplied = try contracts.encodeOwned(P.ToolDeclaration, ctx.allocator, tool);
                if (!equal(expected, supplied)) return error.InvalidDeclaration;
            }
            if (!std.meta.eql(invocation.normalization_limits, P.normalizationLimits())) return error.IncompatibleProfile;
        }

        fn history(ctx: registry.ProjectionContext, request: P.ReferenceRequest, config: Settings) !json.Value {
            var input = list(ctx.allocator);
            if (request.replay) |ref| {
                if (!equal(ref.schema.bytes, P.context_identity) or !equal(&ref.profile, &request.profile) or !equal(&ref.task, &ctx.task) or
                    !equal(ref.tenant.bytes, ctx.tenant) or !equal(ref.audience.bytes, config.audience.bytes) or ref.first != 0 or ref.next > 8192) return error.InvalidContext;
                var current: ?registry.ObjectReference = .{ .digest = ref.digest, .bytes = ref.bytes };
                var previous_next = ref.next;
                var depth: usize = 0;
                while (current) |reference| {
                    if (depth == 64) return error.Capacity;
                    const bytes = try ctx.object(reference, 2 * 1024 * 1024);
                    defer ctx.allocator.free(bytes);
                    var artifact = try contracts.decodeOwned(P.Context, ctx.allocator, bytes);
                    defer artifact.deinit();
                    const value = artifact.value;
                    if (!equal(value.schema.bytes, ref.schema.bytes) or !equal(&value.profile, &ref.profile) or !equal(&value.task, &ref.task) or
                        !equal(value.tenant.bytes, ref.tenant.bytes) or !equal(value.audience.bytes, ref.audience.bytes) or value.first != 0 or
                        value.next > previous_next or (depth == 0 and value.next != ref.next)) return error.InvalidContext;
                    const raw = try ctx.object(.{ .digest = value.source_capture.digest, .bytes = value.source_capture.bytes }, 4 * 1024 * 1024);
                    ctx.allocator.free(raw);
                    if (depth == 0) {
                        const parsed = try json.parse(ctx.allocator, value.items.bytes, .{ .bytes = 2 * 1024 * 1024 });
                        input = parsed.value;
                        if (input != .array or input.array.items.len != ref.next) return error.InvalidContext;
                    }
                    previous_next = value.next;
                    current = if (value.parent) |parent| .{ .digest = parent.digest, .bytes = parent.bytes } else null;
                    depth += 1;
                }
            }
            var pending = try replayCalls(ctx.allocator, input);
            for (request.results.items) |result| {
                if (!pending.remove(result.call_id.bytes)) return error.CallPairMismatch;
                var item = json.object();
                try json.put(ctx.allocator, &item, "type", json.string("function_call_output"));
                try json.put(ctx.allocator, &item, "call_id", json.string(result.call_id.bytes));
                try json.put(ctx.allocator, &item, "output", json.string(result.output.bytes));
                try input.array.append(item);
            }
            if (pending.count() != 0) return error.MissingCallResult;
            for (request.invocation.messages.items) |message| {
                var item = json.object();
                try json.put(ctx.allocator, &item, "role", json.string(@tagName(message.role)));
                try json.put(ctx.allocator, &item, "content", json.string(message.content.bytes));
                try input.array.append(item);
            }
            return input;
        }

        pub fn prepare(ctx: registry.ProjectionContext, bytes: []const u8) ![]u8 {
            var request = try contracts.decodeOwned(P.ReferenceRequest, ctx.allocator, bytes);
            defer request.deinit();
            const config = try settings(ctx.allocator, ctx.profile);
            try bind(ctx, request.value, config);
            var body = json.object();
            try json.put(ctx.allocator, &body, "model", json.string(config.model.bytes));
            try json.put(ctx.allocator, &body, "input", try history(ctx, request.value, config));
            try json.put(ctx.allocator, &body, "max_output_tokens", try json.number(ctx.allocator, config.max_output_tokens));
            var reasoning = json.object();
            try json.put(ctx.allocator, &reasoning, "effort", json.string(config.effort.bytes));
            try json.put(ctx.allocator, &body, "reasoning", reasoning);
            var tools = list(ctx.allocator);
            for (request.value.invocation.tools.items) |tool| {
                var item = json.object();
                try json.put(ctx.allocator, &item, "type", json.string("function"));
                try json.put(ctx.allocator, &item, "name", json.string(tool.name.bytes));
                try json.put(ctx.allocator, &item, "description", json.string(tool.description.bytes));
                const schema = try json.parse(ctx.allocator, tool.input_schema_json.bytes, .{});
                try json.put(ctx.allocator, &item, "parameters", schema.value);
                try json.put(ctx.allocator, &item, "strict", .{ .bool = tool.strict });
                try tools.array.append(item);
            }
            try json.put(ctx.allocator, &body, "tools", tools);
            const selection = request.value.invocation.selection;
            try json.put(ctx.allocator, &body, "tool_choice", json.string(if (selection.maximum_calls == 0) "none" else if (selection.minimum_calls == 1) "required" else "auto"));
            inline for (.{ "parallel_tool_calls", "store", "stream", "background" }) |key| try json.put(ctx.allocator, &body, key, .{ .bool = false });
            try json.put(ctx.allocator, &body, "truncation", json.string("disabled"));
            const rendered = try json.canonical(ctx.allocator, body);
            if (rendered.len > config.request_bytes) return error.Capacity;
            return rendered;
        }

        pub fn acquire(ctx: registry.Context, rendered: []const u8) !registry.Acquisition {
            ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
            const config = settings(ctx.allocator, ctx.profile) catch |err| return .{ .definitely_not_sent = err };
            return acquireSettings(ctx, config, rendered);
        }

        const Interpreted = struct {
            result: P.Result,
            replay: ?Reference = null,
            replay_status: @FieldType(P.ReferenceResult, "replay_status") = .unsupported,
            objects: []const []const u8 = &.{},
        };
        fn encode(ctx: registry.ProjectionContext, interpreted: Interpreted, usage: @FieldType(P.ReferenceResult, "usage")) !registry.Projection {
            const result: P.ReferenceResult = .{ .result = interpreted.result, .replay = interpreted.replay, .replay_status = interpreted.replay_status, .usage = usage };
            return .{ .reply = try contracts.encodeOwned(P.ReferenceResult, ctx.allocator, result), .objects = interpreted.objects, .output_tokens = if (usage) |available| available.output_tokens else null };
        }
        fn unsupported(reason: @FieldType(P.Result, "unsupported_response")) Interpreted {
            return .{ .result = .{ .unsupported_response = reason }, .replay_status = if (reason == .normalization_limit) .capacity else .unsupported };
        }

        pub fn interpret(ctx: registry.ProjectionContext, request_bytes: []const u8, rendered: []const u8, captured: []const u8) !registry.Projection {
            var request = try contracts.decodeOwned(P.ReferenceRequest, ctx.allocator, request_bytes);
            defer request.deinit();
            const config = try settings(ctx.allocator, ctx.profile);
            try bind(ctx, request.value, config);
            if (!equal(try prepare(ctx, request_bytes), rendered)) return error.InvalidCapture;
            var raw = try contracts.decodeOwned(Raw, ctx.allocator, captured);
            defer raw.deinit();
            if (raw.value.status < 200 or raw.value.status >= 300) return encode(ctx, .{ .result = .{ .provider_failure = .{ .kind = .http_status, .http_status = raw.value.status } } }, null);
            if (!raw.value.identity_encoding) return encode(ctx, unsupported(.unsupported_output_item), null);
            if (!std.unicode.utf8ValidateSlice(raw.value.body.bytes)) return encode(ctx, unsupported(.invalid_utf8), null);
            const response = json.parse(ctx.allocator, raw.value.body.bytes, .{ .bytes = config.response_bytes }) catch |err| return encode(ctx, unsupported(if (err == error.Capacity) .normalization_limit else .malformed_json), null);
            const body = response.value;
            // Returned usage is an observation of the captured response, not a
            // consequence of accepting its actions or replay. Attach it once.
            const usage = readUsage(body);
            const interpreted = try interpretBody(ctx, request.value, config, captured, body, if (usage) |_| true else |_| false);
            return encode(ctx, interpreted, usage catch null);
        }

        fn interpretBody(ctx: registry.ProjectionContext, request: P.ReferenceRequest, config: Settings, captured: []const u8, body: json.Value, usage_valid: bool) !Interpreted {
            if (is(body, "status", "failed") or is(body, "status", "incomplete")) return .{ .result = .{ .provider_failure = .{ .kind = if (is(body, "status", "failed")) .response_failed else .response_incomplete, .http_status = 0 } } };
            if (!is(body, "status", "completed") or (json.get(body, "error") orelse return unsupported(.unsupported_status)) != .null) return unsupported(.unsupported_status);
            const output = field(body, "output") catch return unsupported(.unsupported_status);
            if (output != .array) return unsupported(.unsupported_status);
            if (output.array.items.len > P.representation.maximum_output_items) return unsupported(.normalization_limit);
            const normalized = normalize(ctx.allocator, request.invocation, output) catch |err| return unsupported(if (err == error.Capacity) .normalization_limit else if (err == error.MixedRefusal) .mixed_refusal else .unsupported_output_item);
            var input = try history(ctx, request, config);
            for (output.array.items) |item| try input.array.append(try replayItem(ctx.allocator, item));
            _ = replayCalls(ctx.allocator, input) catch return unsupported(.unsupported_output_item);
            const replay = try json.canonical(ctx.allocator, input);
            if (replay.len > 2 * 1024 * 1024 or input.array.items.len > 8192) return unsupported(.normalization_limit);
            if (!usage_valid) return unsupported(.unsupported_output_item);
            const artifact = try contracts.encodeOwned(P.Context, ctx.allocator, .{ .schema = .{ .bytes = P.context_identity }, .profile = request.profile, .task = ctx.task, .tenant = .{ .bytes = ctx.tenant }, .audience = config.audience, .first = 0, .next = input.array.items.len, .source_capture = .{ .digest = storage.digest(captured), .bytes = captured.len }, .parent = if (request.replay) |prior| .{ .digest = prior.digest, .bytes = prior.bytes } else null, .items = .{ .bytes = replay } });
            if (artifact.len > 2 * 1024 * 1024) return unsupported(.normalization_limit);
            const ref: Reference = .{ .digest = storage.digest(artifact), .bytes = artifact.len, .schema = .{ .bytes = P.context_identity }, .profile = request.profile, .task = ctx.task, .tenant = .{ .bytes = ctx.tenant }, .audience = config.audience, .first = 0, .next = input.array.items.len };
            const objects = try ctx.allocator.alloc([]const u8, 1);
            objects[0] = artifact;
            return .{ .result = normalized, .replay = ref, .replay_status = .complete, .objects = objects };
        }

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
                const token = scanner.nextAllocMax(a, .alloc_if_needed, P.representation.arguments_json_bytes) catch return .{ .invalid = .malformed };
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
            const parsed = json.parse(a, arguments, .{ .bytes = P.representation.arguments_json_bytes }) catch |err| return .{ .invalid = switch (err) {
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
                    const value = argument(T, child) catch |err| return .{ .invalid = switch (err) {
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

        /// Shared output grammar and exact argument codec. Version-specific
        /// policy and context admission stay with their respective adapters.
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
                    if (call_id.len == 0 or call_id.len > P.representation.call_id_bytes or name.len > P.ToolName.max_length.? or args.len > P.representation.arguments_json_bytes) return error.Capacity;
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
                    if (joined.items.len > P.representation.result_text_bytes) return error.Capacity;
                    if (refusal == null) try items.append(a, .{ .message = .{ .role = .assistant, .content = .{ .bytes = joined.items } } });
                } else {
                    var joined: std.ArrayList(u8) = .empty;
                    const summary = try field(item, "summary");
                    for (summary.array.items, 0..) |part, index| {
                        if (index != 0) try joined.append(a, '\n');
                        try joined.appendSlice(a, try text(part, "text"));
                    }
                    if (joined.items.len > P.representation.result_text_bytes) return error.Capacity;
                    try items.append(a, .{ .reasoning = .{ .summary = .{ .bytes = joined.items } } });
                }
            }
            if (refusal) |message| {
                for (items.items) |item| if (item != .reasoning) return error.MixedRefusal;
                if (message.len > P.representation.result_text_bytes) return error.Capacity;
                return .{ .refusal = .{ .bytes = message } };
            }
            const encoded = try contracts.encodeOwned(P.OutputItems, a, .{ .items = items.items });
            return .{ .output = .{ .items = .{ .items = items.items }, .normalized_output_digest = storage.digest(encoded) } };
        }

        fn readUsage(body: json.Value) !@FieldType(P.ReferenceResult, "usage") {
            const usage = json.get(body, "usage") orelse return null;
            if (usage == .null) return null;
            const input = try count(try field(usage, "input_tokens"));
            const output = try count(try field(usage, "output_tokens"));
            var cached: ?u64 = null;
            if (json.get(usage, "input_tokens_details")) |details| if (details != .null) {
                if (json.get(details, "cached_tokens")) |value| if (value != .null) {
                    cached = try count(value);
                };
            };
            if (cached != null and cached.? > input) return error.UnsupportedResponse;
            return .{ .input_tokens = input, .output_tokens = output, .cached_input_tokens = cached };
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

fn count(value: json.Value) !u64 {
    if (value != .number_string) return error.UnsupportedResponse;
    return json.numberInteger(u64, value.number_string);
}

/// Closed output-to-input grammar. Only these admitted item fields survive;
/// the response envelope is never appended as input. Opaque bytes stay opaque.
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

fn replayCalls(a: std.mem.Allocator, input: json.Value) !std.StringHashMap(void) {
    if (input != .array or input.array.items.len > 8192) return error.Capacity;
    var seen = std.StringHashMap(void).init(a);
    var pending = std.StringHashMap(void).init(a);
    for (input.array.items) |item| {
        if (is(item, "type", "function_call_output")) {
            try only(item, &.{ "type", "call_id", "output" });
            _ = try text(item, "output");
            if (!pending.remove(try text(item, "call_id"))) return error.CallPairMismatch;
        } else if (json.get(item, "type") == null) {
            try only(item, &.{ "role", "content" });
            const role = try text(item, "role");
            if (!equal(role, "system") and !equal(role, "developer") and !equal(role, "user") and !equal(role, "assistant")) return error.UnsupportedResponse;
            _ = try text(item, "content");
            if (pending.count() != 0) return error.MissingCallResult;
        } else {
            _ = try replayItem(a, item);
            if (is(item, "type", "function_call")) {
                const id = try text(item, "call_id");
                const entry = try seen.getOrPut(id);
                if (entry.found_existing) return error.DuplicateCall;
                try pending.put(id, {});
            }
        }
    }
    return pending;
}
