//! Offline JSON Schema projection. Application values retain their existing
//! generated schemas; required parameter names come from protocol admission.
const std = @import("std");
const json = @import("json.zig");
const protocol = @import("protocol.zig");
const state = @import("state.zig");

const Property = struct { []const u8, json.Value };
fn literal(a: std.mem.Allocator, bytes: []const u8) !json.Value {
    return (try json.parse(a, bytes, .{})).value;
}
fn text(a: std.mem.Allocator, minimum: usize, maximum: usize) !json.Value {
    var value = try literal(a, "{\"type\":\"string\"}");
    try json.put(a, &value, "minLength", try json.number(a, minimum));
    try json.put(a, &value, "maxLength", try json.number(a, maximum));
    try json.put(a, &value, "x-max-utf8-bytes", try json.number(a, maximum));
    return value;
}
fn constant(a: std.mem.Allocator, value: []const u8) !json.Value {
    var result = json.object();
    try json.put(a, &result, "const", json.string(value));
    return result;
}
fn reference(a: std.mem.Allocator, name: []const u8) !json.Value {
    var result = json.object();
    try json.put(a, &result, "$ref", json.string(try std.fmt.allocPrint(a, "#/$defs/{s}", .{name})));
    return result;
}
fn strings(a: std.mem.Allocator, list: []const []const u8) !json.Value {
    var items: std.array_list.Managed(json.Value) = .init(a);
    for (list) |item| try items.append(json.string(item));
    return .{ .array = items };
}
fn enumeration(a: std.mem.Allocator, list: []const []const u8) !json.Value {
    var result = json.object();
    try json.put(a, &result, "enum", try strings(a, list));
    return result;
}
fn enumSchema(comptime T: type, a: std.mem.Allocator) !json.Value {
    var items: std.array_list.Managed(json.Value) = .init(a);
    for (@typeInfo(T).@"enum".field_names) |name| try items.append(json.string(name));
    var result = json.object();
    try json.put(a, &result, "enum", .{ .array = items });
    return result;
}
fn shape(a: std.mem.Allocator, properties: []const Property, optional: []const []const u8) !json.Value {
    var fields = json.object();
    var required: std.array_list.Managed(json.Value) = .init(a);
    for (properties) |property| {
        try json.put(a, &fields, property[0], property[1]);
        var is_optional = false;
        for (optional) |name| is_optional = is_optional or std.mem.eql(u8, name, property[0]);
        if (!is_optional) try required.append(json.string(property[0]));
    }
    var result = try literal(a, "{\"type\":\"object\",\"additionalProperties\":false}");
    try json.put(a, &result, "properties", fields);
    try json.put(a, &result, "required", .{ .array = required });
    return result;
}
fn extend(a: std.mem.Allocator, original: json.Value, properties: []const Property, optional: []const []const u8) !json.Value {
    var result = try json.copy(a, original);
    const fields = result.object.getPtr("properties").?;
    const required = result.object.getPtr("required").?;
    for (properties) |property| {
        try json.put(a, fields, property[0], property[1]);
        var is_optional = false;
        for (optional) |name| is_optional = is_optional or std.mem.eql(u8, name, property[0]);
        if (!is_optional) try required.array.append(json.string(property[0]));
    }
    return result;
}
fn array(a: std.mem.Allocator, child: json.Value, maximum: ?usize) !json.Value {
    var result = try literal(a, "{\"type\":\"array\"}");
    try json.put(a, &result, "items", child);
    if (maximum) |limit| try json.put(a, &result, "maxItems", try json.number(a, limit));
    return result;
}
fn nullable(a: std.mem.Allocator, child: json.Value) !json.Value {
    var items: std.array_list.Managed(json.Value) = .init(a);
    try items.append(child);
    try items.append(try literal(a, "{\"type\":\"null\"}"));
    var result = json.object();
    try json.put(a, &result, "anyOf", .{ .array = items });
    return result;
}
fn oneOf(a: std.mem.Allocator, values: []const json.Value) !json.Value {
    var items: std.array_list.Managed(json.Value) = .init(a);
    try items.appendSlice(values);
    var result = json.object();
    try json.put(a, &result, "oneOf", .{ .array = items });
    return result;
}
fn number(a: std.mem.Allocator, maximum: usize, default: ?usize) !json.Value {
    var result = try literal(a, "{\"type\":\"integer\",\"minimum\":1}");
    try json.put(a, &result, "maximum", try json.number(a, maximum));
    if (default) |value| try json.put(a, &result, "default", try json.number(a, value));
    return result;
}
fn counter(a: std.mem.Allocator, maximum: u64) !json.Value {
    // JSON Schema validates strings lexically. Generate the exact unsigned
    // range instead of relying on a floating-point maximum or a loose length.
    const digits = try std.fmt.allocPrint(a, "{d}", .{maximum});
    var parts: std.array_list.Managed([]const u8) = .init(a);
    try parts.append("0");
    if (digits.len > 1) try parts.append(try std.fmt.allocPrint(a, "[1-9][0-9]{{0,{d}}}", .{digits.len - 2}));
    for (digits, 0..) |digit, i| {
        const lower: u8 = if (i == 0) '1' else '0';
        if (digit <= lower) continue;
        try parts.append(try std.fmt.allocPrint(a, "{s}[{c}-{c}][0-9]{{{d}}}", .{ digits[0..i], lower, digit - 1, digits.len - i - 1 }));
    }
    try parts.append(digits);
    var result = try text(a, 1, digits.len);
    try json.put(a, &result, "pattern", json.string(try std.fmt.allocPrint(a, "^({s})(?![\\s\\S])", .{try std.mem.join(a, "|", parts.items)})));
    return result;
}
fn typed(a: std.mem.Allocator, application: json.Value, name: []const u8) !json.Value {
    const item = application.object.get(name).?;
    return shape(a, &.{ .{ "schema_id", try constant(a, item.object.get("schema_id").?.string) }, .{ "value", item.object.get("json").? } }, &.{});
}
fn parameter(a: std.mem.Allocator, method: protocol.Method, key: []const u8, application: json.Value, limits: protocol.Limits) !json.Value {
    if (method == .placement and std.mem.eql(u8, key, "request")) {
        const bytes = &@import("values.zig").schemas.ClientSchema(@import("placement.zig").Request).value;
        return (try json.parseAsset(a, bytes, bytes.len)).value;
    }
    if (std.mem.eql(u8, key, "task_id") or std.mem.eql(u8, key, "subscription_id")) return reference(a, "id128");
    if (std.mem.eql(u8, key, "question_id") or std.mem.eql(u8, key, "request_digest") or std.mem.eql(u8, key, "artifact_id") or std.mem.eql(u8, key, "occurrence_id") or std.mem.eql(u8, key, "attempt_id")) return reference(a, "digest");
    if (std.mem.eql(u8, key, "recovery")) return shape(a, &.{.{ "mechanism", try enumSchema(state.RecoveryRequest, a) }}, &.{});
    if (std.mem.eql(u8, key, "question_revision") or std.mem.eql(u8, key, "expected_revision") or std.mem.eql(u8, key, "after_seq") or std.mem.eql(u8, key, "offset")) return reference(a, "counter");
    if (std.mem.eql(u8, key, "input") or std.mem.eql(u8, key, "answer") or std.mem.eql(u8, key, "message")) return typed(a, application, key);
    if (std.mem.eql(u8, key, "application_id")) {
        var result = try constant(a, application.object.get("application_id").?.string);
        if (method == .describe) try json.put(a, &result, "default", application.object.get("application_id").?);
        return result;
    }
    // The launch admits the identifier; a static schema cannot select its
    // configured value. Task submission still checks exact profile membership.
    if (std.mem.eql(u8, key, "profile_id")) return text(a, 1, 128);
    if (std.mem.eql(u8, key, "client_operation_id")) return text(a, 1, 128);
    if (std.mem.eql(u8, key, "reason")) {
        var result = try text(a, 0, 256);
        try json.put(a, &result, "default", json.string("client requested cancellation"));
        return result;
    }
    if (std.mem.eql(u8, key, "limit")) return number(a, if (method == .describe) 16 else limits.event_page, 16);
    if (std.mem.eql(u8, key, "cursor")) {
        var result = try counter(a, @typeInfo(protocol.Method).@"enum".field_names.len);
        try json.put(a, &result, "default", json.string("0"));
        return result;
    }
    if (std.mem.eql(u8, key, "length")) {
        var result = try counter(a, limits.artifact_chunk_bytes);
        try json.put(a, &result, "not", try constant(a, "0"));
        return result;
    }
    if (std.mem.eql(u8, key, "mode")) return enumeration(a, &.{ "park", "cancel" });
    if (std.mem.eql(u8, key, "protocol_versions")) {
        var result = try array(a, try text(a, 0, 128), 16);
        try json.put(a, &result, "minItems", try json.number(a, 1));
        return result;
    }
    if (std.mem.eql(u8, key, "client_info")) {
        var result = try shape(a, &.{ .{ "name", try text(a, 0, 128) }, .{ "version", try text(a, 0, 128) } }, &.{});
        try json.put(a, &result, "default", .null);
        try json.put(a, &result, "description", json.string("Optional diagnostics; omission records no client metadata and grants no authority."));
        return result;
    }
    return error.InvalidProtocolSchema;
}

// The field contract drives both public JSON Schema and durable admission.
// A prompt is application presentation JSON, so it deliberately has no shape.
const EventField = struct {
    name: []const u8,
    kind: enum { digest, counter, name, prompt, prompt_ref, disposition, delivery },
    optional: bool = false,
};
fn eventFields(kind: state.EventType) []const EventField {
    return switch (kind) {
        .input_required => &.{ .{ .name = "question_id", .kind = .digest }, .{ .name = "question_revision", .kind = .counter }, .{ .name = "request_digest", .kind = .digest }, .{ .name = "answer_schema_id", .kind = .name }, .{ .name = "prompt", .kind = .prompt, .optional = true }, .{ .name = "prompt_ref", .kind = .prompt_ref, .optional = true } },
        .message_queued, .message_consumed, .message_not_consumed => &.{ .{ .name = "message_id", .kind = .digest }, .{ .name = "ordinal", .kind = .counter }, .{ .name = "disposition", .kind = .disposition } },
        .blocked => &.{.{ .name = "delivery", .kind = .delivery, .optional = true }},
        .imported => &.{.{ .name = "archive_sha256", .kind = .digest }},
        .reconciled => &.{.{ .name = "reconciliation_id", .kind = .digest }},
        .workspace_read => &.{.{ .name = "occurrence_id", .kind = .digest }},
        .workspace, .workspace_progress => &.{.{ .name = "workspace_id", .kind = .digest }},
        .accepted, .input_accepted, .cancellation_requested, .parked, .resumed, .delivery_unknown, .completed, .failed, .cancelled => &.{},
    };
}
fn questionReferenceSchema(a: std.mem.Allocator) !json.Value {
    return try shape(a, &.{
        .{ "artifact_id", try reference(a, "digest") },                       .{ "sha256", try reference(a, "digest") },
        .{ "bytes", try reference(a, "counter") },                            .{ "media_type", try constant(a, "application/json") },
        .{ "schema_id", try constant(a, "agent-native-question-prompt.v1") }, .{ "retention", try constant(a, "state-namespace") },
        .{ "question_id", try reference(a, "digest") },
    }, &.{});
}

fn eventPayload(a: std.mem.Allocator, kind: state.EventType) !json.Value {
    var fields: std.ArrayList(Property) = .empty;
    defer fields.deinit(a);
    var optional: std.ArrayList([]const u8) = .empty;
    defer optional.deinit(a);
    for (eventFields(kind)) |field| {
        const field_schema = switch (field.kind) {
            .digest => try reference(a, "digest"),
            .counter => try reference(a, "counter"),
            .name => try text(a, 1, 128),
            .prompt => json.object(),
            .prompt_ref => try questionReferenceSchema(a),
            .disposition => try enumSchema(state.MessageDisposition, a),
            .delivery => try constant(a, "definitely_not_sent"),
        };
        try fields.append(a, .{ field.name, field_schema });
        if (field.optional) try optional.append(a, field.name);
    }
    var result = try shape(a, fields.items, optional.items);
    if (kind == .input_required) try json.put(a, &result, "oneOf", try literal(a, "[{\"required\":[\"prompt\"]},{\"required\":[\"prompt_ref\"]}]"));
    return result;
}
pub fn validateEventData(a: std.mem.Allocator, kind: state.EventType, bytes: []const u8) !void {
    var parsed = try json.parse(a, bytes, .{ .bytes = 48 * 1024, .depth = 33 });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArchive;
    const fields = eventFields(kind);
    if (kind == .input_required and (parsed.value.object.contains("prompt") == parsed.value.object.contains("prompt_ref"))) return error.InvalidArchive;
    for (parsed.value.object.keys()) |key| {
        var found = false;
        for (fields) |field| if (std.mem.eql(u8, key, field.name)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidArchive;
    }
    for (fields) |field| {
        const value = parsed.value.object.get(field.name) orelse {
            if (field.optional) continue;
            return error.InvalidArchive;
        };
        switch (field.kind) {
            .prompt => {},
            .prompt_ref => {
                if (value != .object or value.object.count() != 7) return error.InvalidArchive;
                inline for (.{ "artifact_id", "sha256", "question_id" }) |name| {
                    const encoded = json.text(value.object.get(name) orelse return error.InvalidArchive) catch return error.InvalidArchive;
                    if (encoded.len != 64) return error.InvalidArchive;
                    var id: [32]u8 = undefined;
                    _ = std.fmt.hexToBytes(&id, encoded) catch return error.InvalidArchive;
                }
                if (!std.mem.eql(u8, value.object.get("artifact_id").?.string, value.object.get("sha256").?.string) or
                    !std.mem.eql(u8, value.object.get("question_id").?.string, (parsed.value.object.get("question_id") orelse return error.InvalidArchive).string)) return error.InvalidArchive;
                _ = json.decimal(u64, value.object.get("bytes") orelse return error.InvalidArchive) catch return error.InvalidArchive;
                inline for (.{ .{ "media_type", "application/json" }, .{ "schema_id", "agent-native-question-prompt.v1" }, .{ "retention", "state-namespace" } }) |pair| {
                    if (!std.mem.eql(u8, json.text(value.object.get(pair[0]) orelse return error.InvalidArchive) catch return error.InvalidArchive, pair[1])) return error.InvalidArchive;
                }
            },
            .counter => {
                _ = json.decimal(u64, value) catch return error.InvalidArchive;
            },
            .digest => {
                const encoded = json.text(value) catch return error.InvalidArchive;
                if (encoded.len != 64) return error.InvalidArchive;
                var digest: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&digest, encoded) catch return error.InvalidArchive;
            },
            .name => {
                const name = json.text(value) catch return error.InvalidArchive;
                if (name.len == 0 or name.len > 128) return error.InvalidArchive;
            },
            .disposition => {
                const name = json.text(value) catch return error.InvalidArchive;
                _ = std.meta.stringToEnum(state.MessageDisposition, name) orelse return error.InvalidArchive;
            },
            .delivery => if (!std.mem.eql(u8, json.text(value) catch return error.InvalidArchive, "definitely_not_sent")) return error.InvalidArchive,
        }
    }
}

pub fn document(a: std.mem.Allocator, application: json.Value, limits: protocol.Limits) !json.Value {
    var definitions = json.object();
    try json.put(a, &definitions, "id128", try literal(a, "{\"type\":\"string\",\"pattern\":\"^[0-9a-fA-F]{32}(?![\\\\s\\\\S])\"}"));
    try json.put(a, &definitions, "digest", try literal(a, "{\"type\":\"string\",\"pattern\":\"^[0-9a-fA-F]{64}(?![\\\\s\\\\S])\"}"));
    try json.put(a, &definitions, "counter", try counter(a, std.math.maxInt(u64)));
    try json.put(a, &definitions, "boolean", try literal(a, "{\"type\":\"boolean\"}"));
    try json.put(a, &definitions, "rpc_id", try literal(a, "{\"anyOf\":[{\"type\":\"null\"},{\"type\":\"string\",\"minLength\":1,\"maxLength\":128,\"x-max-utf8-bytes\":128},{\"type\":\"integer\",\"minimum\":-9007199254740991,\"maximum\":9007199254740991}]}"));
    const id = try reference(a, "id128");
    const digest = try reference(a, "digest");
    const count = try reference(a, "counter");
    const boolean = try reference(a, "boolean");
    const empty = try shape(a, &.{}, &.{});
    // Queries can expose saved tasks from another application or version.
    // Their schema identities are data; mutation parameters below still bind
    // the currently admitted application contract.
    const question = try eventPayload(a, .input_required);
    const message = try eventPayload(a, .message_queued);
    var snapshot = try shape(a, &.{
        .{ "task_id", id },                             .{ "application_id", try text(a, 1, 128) },                        .{ "profile_id", try text(a, 1, 128) },                    .{ "profile_digest", digest },
        .{ "status", try enumSchema(state.Status, a) }, .{ "revision", count },                                            .{ "result_available", boolean },                          .{ "earliest_available_seq", count },
        .{ "high_water_seq", count },                   .{ "blocker", try nullable(a, try enumSchema(state.Blocker, a)) }, .{ "cancellation", try nullable(a, try text(a, 0, 256)) }, .{ "pending_messages", try array(a, message, limits.pending_message_page) },
        .{ "pending_message_count", count },            .{ "pending_messages_truncated", boolean },                        .{ "message_history", try constant(a, "task.events") },    .{ "question", try nullable(a, question) },
    }, &.{});
    const availability = try shape(a, &.{ .{ "occurrence_id", digest }, .{ "attempt_id", digest }, .{ "mechanisms", try array(a, try enumSchema(state.RecoveryRequest, a), null) } }, &.{});
    snapshot = try extend(a, snapshot, &.{.{ "recovery", try nullable(a, availability) }}, &.{});
    snapshot = try extend(a, snapshot, &.{.{ "associated_work_disposed", boolean }}, &.{});
    try json.put(a, &definitions, "snapshot", snapshot);
    const artifact = try shape(a, &.{ .{ "artifact_id", digest }, .{ "sha256", digest }, .{ "bytes", count }, .{ "media_type", try constant(a, "application/json") }, .{ "schema_id", try text(a, 1, 128) }, .{ "retention", try constant(a, "state-namespace") } }, &.{});
    var outcomes: std.array_list.Managed(json.Value) = .init(a);
    inline for (.{ "output", "failure" }) |name| {
        var outcome = try shape(a, &.{
            .{ "type", try constant(a, if (comptime std.mem.eql(u8, name, "output")) "completed" else "failed") },
            .{ "schema_id", try text(a, 1, 128) },
            .{ "value", json.object() },
            .{ "value_ref", artifact },
        }, &.{ "value", "value_ref" });
        if (comptime std.mem.eql(u8, name, "failure")) outcome = try extend(a, outcome, &.{.{ "cleanup_complete", boolean }}, &.{});
        try json.put(a, &outcome, "oneOf", try literal(a, "[{\"required\":[\"value\"]},{\"required\":[\"value_ref\"]}]"));
        try outcomes.append(outcome);
    }
    try outcomes.append(try shape(a, &.{ .{ "type", try constant(a, "cancelled") }, .{ "cleanup_complete", boolean } }, &.{}));
    var outcome_schema = json.object();
    try json.put(a, &outcome_schema, "oneOf", .{ .array = outcomes });
    var task_result = try extend(a, snapshot, &.{ .{ "ready", boolean }, .{ "outcome", outcome_schema } }, &.{"outcome"});
    var result_cases = try literal(a, "[{\"if\":{\"properties\":{\"ready\":{\"const\":true}}},\"then\":{\"required\":[\"outcome\"]},\"else\":{\"not\":{\"required\":[\"outcome\"]}}}]");
    inline for (.{ "output", "failure" }) |name| {
        const contract = application.object.get(name).?;
        var saved = json.object();
        try json.put(a, &saved, "type", try constant(a, if (comptime std.mem.eql(u8, name, "output")) "completed" else "failed"));
        try json.put(a, &saved, "schema_id", try constant(a, contract.object.get("schema_id").?.string));
        var saved_outcome = json.object();
        try json.put(a, &saved_outcome, "properties", saved);
        var properties = json.object();
        try json.put(a, &properties, "application_id", try constant(a, application.object.get("application_id").?.string));
        try json.put(a, &properties, "outcome", saved_outcome);
        var condition = json.object();
        try json.put(a, &condition, "properties", properties);
        var typed_value = json.object();
        try json.put(a, &typed_value, "value", contract.object.get("json").?);
        var typed_outcome = json.object();
        try json.put(a, &typed_outcome, "properties", typed_value);
        var typed_properties = json.object();
        try json.put(a, &typed_properties, "outcome", typed_outcome);
        var value_constraint = json.object();
        try json.put(a, &value_constraint, "properties", typed_properties);
        var branch = json.object();
        try json.put(a, &branch, "if", condition);
        try json.put(a, &branch, "then", value_constraint);
        try result_cases.array.append(branch);
    }
    try json.put(a, &task_result, "allOf", result_cases);
    try json.put(a, &definitions, "task.result.result", task_result);
    inline for (.{ "task.submit", "task.message", "task.respond", "task.cancel", "task.resume", "task.reconcile" }) |name| {
        var admitted = try extend(a, snapshot, &.{ .{ "receipt_id", digest }, .{ "receipt_revision", count }, .{ "replayed", boolean }, .{ "disposition", try enumSchema(state.Disposition, a) } }, &.{});
        if (comptime std.mem.eql(u8, name, "task.message")) admitted = try extend(a, admitted, &.{.{ "message_id", digest }}, &.{});
        if (comptime std.mem.eql(u8, name, "task.respond")) admitted = try extend(a, admitted, &.{.{ "question_id", digest }}, &.{});
        if (comptime std.mem.eql(u8, name, "task.reconcile")) {
            const recovery = try shape(a, &.{ .{ "reconciliation_id", digest }, .{ "occurrence_id", digest }, .{ "attempt_id", digest }, .{ "status", try enumeration(a, &.{ "unresolved", "capture_admitted", "reply_settled", "pending", "not_sent" }) }, .{ "provenance", try enumeration(a, &.{ "none", "rederived", "authentic", "authoritative" }) }, .{ "mechanism", try text(a, 1, 128) }, .{ "mechanism_version", try counter(a, std.math.maxInt(u32)) }, .{ "reason", try nullable(a, try enumeration(a, &.{ "unsupported", "unavailable", "interrupted", "inconclusive", "rejected" })) } }, &.{});
            admitted = try extend(a, admitted, &.{.{ "reconciliation", recovery }}, &.{});
        }
        try json.put(a, &definitions, name ++ ".result", admitted);
    }
    var event_schema = try shape(a, &.{ .{ "task_id", id }, .{ "seq", count }, .{ "revision", count }, .{ "type", try enumSchema(state.EventType, a) }, .{ "data", try literal(a, "{\"type\":\"object\"}") } }, &.{});
    var event_cases: std.array_list.Managed(json.Value) = .init(a);
    inline for (@typeInfo(state.EventType).@"enum".field_names) |name| {
        const kind = @field(state.EventType, name);
        const payload = try eventPayload(a, kind);
        var condition = json.object();
        var when = json.object();
        var when_properties = json.object();
        try json.put(a, &when_properties, "type", try constant(a, name));
        try json.put(a, &when, "properties", when_properties);
        var then = json.object();
        var then_properties = json.object();
        try json.put(a, &then_properties, "data", payload);
        try json.put(a, &then, "properties", then_properties);
        try json.put(a, &condition, "if", when);
        try json.put(a, &condition, "then", then);
        try event_cases.append(condition);
    }
    try json.put(a, &event_schema, "allOf", .{ .array = event_cases });
    try json.put(a, &definitions, "event", event_schema);
    const event = try reference(a, "event");
    inline for (@typeInfo(protocol.Method).@"enum".field_names) |name| {
        const method = @field(protocol.Method, name);
        const fields = protocol.fields(method);
        var properties: std.array_list.Managed(Property) = .init(a);
        for (fields.required) |key| try properties.append(.{ key, try parameter(a, method, key, application, limits) });
        for (fields.optional) |key| try properties.append(.{ key, try parameter(a, method, key, application, limits) });
        var params = try shape(a, properties.items, fields.optional);
        if (method == .@"artifact.read") try json.put(a, &params, "dependentRequired", try literal(a, "{\"question_id\":[\"task_id\"]}"));
        try json.put(a, &definitions, name ++ ".params", params);
        try json.put(a, &definitions, name ++ ".request", try shape(a, &.{ .{ "jsonrpc", try constant(a, "2.0") }, .{ "id", try reference(a, "rpc_id") }, .{ "method", try constant(a, name) }, .{ "params", params } }, &.{}));
    }
    try json.put(a, &definitions, "ping.result", try shape(a, &.{.{ "server_instance_id", id }}, &.{}));
    try json.put(a, &definitions, "task.status.result", snapshot);
    try json.put(a, &definitions, "task.unsubscribe.result", empty);
    try json.put(a, &definitions, "shutdown.result", try shape(a, &.{ .{ "mode", try enumeration(a, &.{ "park", "cancel" }) }, .{ "accepted", try literal(a, "{\"const\":true}") } }, &.{}));
    try json.put(a, &definitions, "task.events.result", try shape(a, &.{ .{ "events", try array(a, event, limits.event_page) }, .{ "earliest_available_seq", count }, .{ "high_water_seq", count }, .{ "next_after_seq", count }, .{ "has_more", boolean } }, &.{}));
    try json.put(a, &definitions, "task.subscribe.result", try shape(a, &.{ .{ "subscription_id", id }, .{ "after_seq", count }, .{ "earliest_available_seq", count }, .{ "high_water_seq", count } }, &.{}));
    try json.put(a, &definitions, "artifact.read.result", try shape(a, &.{ .{ "encoding", try constant(a, "base64url") }, .{ "data", try text(a, 0, (limits.artifact_chunk_bytes * 4 + 2) / 3) }, .{ "sha256", digest }, .{ "total_bytes", count }, .{ "next_offset", count }, .{ "eof", boolean } }, &.{}));
    const event_params = try shape(a, &.{ .{ "subscription_id", id }, .{ "event", event } }, &.{});
    try json.put(a, &definitions, "task.event", try shape(a, &.{ .{ "jsonrpc", try constant(a, "2.0") }, .{ "method", try constant(a, "task.event") }, .{ "params", event_params } }, &.{}));
    const closed_params = try shape(a, &.{ .{ "subscription_id", id }, .{ "task_id", id }, .{ "reason", try constant(a, "CursorExpired") }, .{ "earliest_available_seq", count }, .{ "high_water_seq", count } }, &.{});
    try json.put(a, &definitions, "subscription.closed", try shape(a, &.{ .{ "jsonrpc", try constant(a, "2.0") }, .{ "method", try constant(a, "subscription.closed") }, .{ "params", closed_params } }, &.{}));
    const server_closed = try shape(a, &.{ .{ "mode", try enumeration(a, &.{ "park", "cancel" }) }, .{ "disposition", try enumeration(a, &.{ "parked", "cancelled", "incomplete" }) }, .{ "recovery_tasks", try array(a, id, limits.recovery_task_page) } }, &.{});
    for ([_][]const u8{ "server.recovery", "server.closed" }) |method| {
        try json.put(a, &definitions, method, try shape(a, &.{ .{ "jsonrpc", try constant(a, "2.0") }, .{ "method", try constant(a, method) }, .{ "params", server_closed } }, &.{}));
    }
    var limit_properties: std.array_list.Managed(Property) = .init(a);
    inline for (@typeInfo(protocol.Limits).@"struct".field_names) |name| {
        var property = json.object();
        try json.put(a, &property, "const", try json.number(a, @field(limits, name)));
        try limit_properties.append(.{ name, property });
    }
    const limits_schema = try shape(a, limit_properties.items, &.{});
    const capabilities = try shape(a, &.{ .{ "task_events", boolean }, .{ "message_input", boolean }, .{ "task_execution", boolean }, .{ "task_reconciliation", boolean } }, &.{});
    const info = try shape(a, &.{ .{ "name", try text(a, 1, 128) }, .{ "version", try text(a, 1, 128) } }, &.{});
    try json.put(a, &definitions, "initialize.result", try shape(a, &.{ .{ "protocol_version", try constant(a, protocol.version) }, .{ "server_instance_id", id }, .{ "server_info", info }, .{ "build_manifest_id", digest }, .{ "native_artifact_sha256", digest }, .{ "limits", limits_schema }, .{ "capabilities", capabilities } }, &.{}));
    const method_description = try shape(a, &.{ .{ "name", try enumSchema(protocol.Method, a) }, .{ "required_fields", try array(a, try text(a, 1, 128), 16) }, .{ "optional_fields", try array(a, try text(a, 1, 128), 16) }, .{ "params_schema", try text(a, 1, 128) }, .{ "result_schema", try text(a, 1, 128) } }, &.{});
    var app_properties: std.array_list.Managed(Property) = .init(a);
    for ([_][]const u8{ "application_id", "application_version", "client_mapping" }) |key| try app_properties.append(.{ key, try constant(a, application.object.get(key).?.string) });
    const schema_reference = try shape(a, &.{ .{ "artifact_id", digest }, .{ "sha256", digest }, .{ "bytes", count }, .{ "media_type", try constant(a, "application/json") }, .{ "schema_id", try text(a, 1, 128) }, .{ "retention", try constant(a, "embedded") } }, &.{});
    const app_reference = try extend(a, try shape(a, app_properties.items, &.{}), &.{.{ "metadata_ref", schema_reference }}, &.{});
    const schema_asset = try shape(a, &.{ .{ "schema_id", try text(a, 1, 128) }, .{ "wire_sha256", digest }, .{ "wire_base64url", try text(a, 0, limits.frame_bytes) }, .{ "json", try literal(a, "{\"type\":\"object\"}") } }, &.{});
    for ([_][]const u8{ "input", "output", "failure", "answer", "message" }) |key| try app_properties.append(.{ key, schema_asset });
    const capability = try shape(a, &.{ .{ "identity", try text(a, 1, 128) }, .{ "resource_role", try text(a, 1, 128) }, .{ "payload_sha256", digest }, .{ "resume_sha256", digest } }, &.{});
    try app_properties.append(.{ "capabilities", try array(a, capability, null) });
    const launch_profile = try nullable(a, try shape(a, &.{ .{ "id", try text(a, 1, 128) }, .{ "sha256", digest }, .{ "resource_identity", digest } }, &.{}));
    var description = try shape(a, &.{ .{ "methods", try array(a, method_description, 16) }, .{ "next_cursor", try nullable(a, count) }, .{ "application", try oneOf(a, &.{ try shape(a, app_properties.items, &.{}), app_reference }) }, .{ "execution_mode", try enumeration(a, &.{ "offline", "live" }) }, .{ "profile", launch_profile }, .{ "protocol_schema", try literal(a, "{\"type\":\"object\"}") }, .{ "protocol_schema_ref", schema_reference } }, &.{ "protocol_schema", "protocol_schema_ref" });
    try json.put(a, &description, "oneOf", try literal(a, "[{\"required\":[\"protocol_schema\"]},{\"required\":[\"protocol_schema_ref\"]}]"));
    try json.put(a, &definitions, "describe.result", description);
    var errors: std.array_list.Managed(json.Value) = .init(a);
    inline for (@typeInfo(protocol.Kind).@"enum".field_names) |name| {
        const kind = @field(protocol.Kind, name);
        var code = json.object();
        try json.put(a, &code, "const", try json.number(a, kind.code()));
        var details = try shape(a, &.{ .{ "kind", try constant(a, name) }, .{ "recovery", if (kind == .CursorExpired) try constant(a, "read_status_or_result") else try enumeration(a, &.{ "correct_request", "reconnect", "retry_same_operation_or_inspect" }) }, .{ "supported_versions", try array(a, try enumeration(a, &.{protocol.version}), 1) } }, &.{"supported_versions"});
        if (kind == .CursorExpired) details = try extend(a, details, &.{ .{ "earliest_available_seq", count }, .{ "high_water_seq", count } }, &.{});
        try errors.append(try shape(a, &.{ .{ "code", code }, .{ "message", try constant(a, name) }, .{ "data", details } }, &.{}));
    }
    var fault = json.object();
    try json.put(a, &fault, "oneOf", .{ .array = errors });
    try json.put(a, &definitions, "error", try shape(a, &.{ .{ "jsonrpc", try constant(a, "2.0") }, .{ "id", try reference(a, "rpc_id") }, .{ "error", fault } }, &.{}));
    inline for (@typeInfo(protocol.Method).@"enum".field_names) |name| {
        try json.put(a, &definitions, name ++ ".response", try shape(a, &.{ .{ "jsonrpc", try constant(a, "2.0") }, .{ "id", try reference(a, "rpc_id") }, .{ "result", try reference(a, name ++ ".result") } }, &.{}));
    }
    var result = json.object();
    try json.put(a, &result, "$schema", json.string("https://json-schema.org/draft/2020-12/schema"));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try json.canonical(a, definitions), &hash, .{});
    try json.put(a, &result, "$id", json.string(try std.fmt.allocPrint(a, "urn:agent:agent-host:1.0:{s}", .{std.fmt.bytesToHex(hash, .lower)})));
    try json.put(a, &result, "$defs", definitions);
    return result;
}
