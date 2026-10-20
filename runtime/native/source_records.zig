//! Data-only transport for the linked Horos source.Module. Reflection owns the
//! grammar; Horos owns source semantics. No pointer or callback crosses JSON.
const std = @import("std");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const json = @import("json.zig");
const values = @import("values.zig");

pub const identity = "protean-horos-source-records/1";
pub const Document = struct { version: u32, module: horos.source.Module };
const Error = values.Error;

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    module: horos.source.Module,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// All fields are explicit, including nullable and defaulted native fields.
/// Grammar depth follows record types, not algorithm recursion or record count.
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Owned {
    var decoded = try decodeRecord(Document, a, bytes);
    errdefer decoded.deinit();
    if (decoded.value.version != 1) return error.UnsupportedVersion;
    return .{ .arena = decoded.arena, .module = decoded.value.module };
}

pub fn decodeRecord(
    comptime T: type,
    a: std.mem.Allocator,
    bytes: []const u8,
) !contracts.Decoded(T) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var parsed = try json.parse(scratch, bytes, .{
        .bytes = bytes.len,
        .depth = comptime depth(T),
        .tokens = bytes.len,
        .members = bytes.len,
    });
    defer parsed.deinit();
    const value = try fromJson(T, scratch, parsed.value);
    return .{ .arena = arena, .value = value };
}

pub fn encode(a: std.mem.Allocator, module: horos.source.Module) ![]u8 {
    return encodeRecord(Document, a, .{ .version = 1, .module = module });
}

pub fn encodeRecord(comptime T: type, a: std.mem.Allocator, value: T) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return json.canonical(a, try toJson(T, arena.allocator(), value));
}

pub fn describe(a: std.mem.Allocator) ![]u8 {
    return describeRecord(Document, a);
}

pub fn describeRecord(comptime T: type, a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return json.canonical(a, try schema(T, arena.allocator()));
}

fn depth(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .optional => |info| depth(info.child),
        .array => |info| 1 + depth(info.child),
        .pointer => |info| if (info.child == u8) 0 else 1 + depth(info.child),
        inline .@"struct", .@"union" => |info| blk: {
            var maximum: usize = 0;
            for (info.field_types) |Child| maximum = @max(maximum, depth(Child));
            break :blk 1 + maximum;
        },
        .void => 1,
        else => 0,
    };
}

fn fromJson(comptime T: type, a: std.mem.Allocator, value: json.Value) Error!T {
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => values.fromJson(T, a, value),
        .optional => |info| if (value == .null) null else @as(T, try fromJson(info.child, a, value)),
        .pointer => |info| blk: {
            comptime if (info.size != .slice or !info.attrs.@"const") @compileError("source transport only admits immutable slices");
            if (info.child == u8) break :blk (try values.fromJson(contracts.Bytes(null), a, value)).bytes;
            if (value != .array) return error.InvalidParams;
            const result = try a.alloc(info.child, value.array.items.len);
            for (result, value.array.items) |*slot, child| slot.* = try fromJson(info.child, a, child);
            break :blk result;
        },
        .array => |info| blk: {
            if (value != .array or value.array.items.len != info.len) return error.InvalidParams;
            var result: T = undefined;
            for (&result, value.array.items) |*slot, child|
                slot.* = try fromJson(info.child, a, child);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            if (value != .object or value.object.count() != info.field_names.len) return error.InvalidParams;
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Child| {
                @field(result, name) = try fromJson(Child, a, value.object.get(name) orelse return error.InvalidParams);
            }
            break :blk result;
        },
        .@"union" => |info| blk: {
            if (value != .object or value.object.count() != 2) return error.InvalidParams;
            const tag = try json.text(value.object.get("tag") orelse return error.InvalidParams);
            const child = value.object.get("value") orelse return error.InvalidParams;
            inline for (info.field_names, info.field_types) |name, Child| {
                if (std.mem.eql(u8, tag, name)) break :blk @unionInit(T, name, try fromJson(Child, a, child));
            }
            return error.InvalidParams;
        },
        else => @compileError("unsupported source-record field: " ++ @typeName(T)),
    };
}

pub fn project(comptime T: type, a: std.mem.Allocator, value: T) std.mem.Allocator.Error!json.Value {
    return toJson(T, a, value);
}

pub fn pageRecord(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
    requested: contracts.workspace.Page,
) !json.Value {
    var range = try @import("workspace_projection.zig").Range.init(a, requested);
    defer range.deinit(a);
    try appendRecord(T, &range, value);
    return range.finish(a);
}

fn appendRecord(
    comptime T: type,
    range: *@import("workspace_projection.zig").Range,
    value: T,
) anyerror!void {
    switch (@typeInfo(T)) {
        .void => try range.append("{}"),
        .bool => try range.append(if (value) "true" else "false"),
        .int => |info| {
            var buffer: [64]u8 = undefined;
            if (info.bits == 64) try range.append("\"");
            try range.append(try std.fmt.bufPrint(&buffer, "{d}", .{value}));
            if (info.bits == 64) try range.append("\"");
        },
        .@"enum" => try appendName(range, @tagName(value)),
        .optional => |info| if (value) |child|
            try appendRecord(info.child, range, child)
        else
            try range.append("null"),
        .pointer => |info| {
            if (info.child == u8) return appendBytes(range, value);
            try appendSequence(info.child, range, value);
        },
        .array => |info| try appendSequence(info.child, range, &value),
        .@"struct" => |info| {
            try range.append("{");
            inline for (comptime sortedNames(T), 0..) |name, index| {
                if (index != 0) try range.append(",");
                try appendName(range, name);
                try range.append(":");
                try appendRecord(@FieldType(T, name), range, @field(value, name));
            }
            _ = info;
            try range.append("}");
        },
        .@"union" => |info| {
            try range.append("{\"tag\":");
            try appendName(range, @tagName(value));
            try range.append(",\"value\":");
            inline for (info.field_names, info.field_types) |name, Child| {
                if (std.mem.eql(u8, @tagName(value), name))
                    try appendRecord(Child, range, @field(value, name));
            }
            try range.append("}");
        },
        else => @compileError("unsupported source-record field: " ++ @typeName(T)),
    }
}

fn sortedNames(comptime T: type) [@typeInfo(T).@"struct".field_names.len][]const u8 {
    var names: [@typeInfo(T).@"struct".field_names.len][]const u8 = undefined;
    for (@typeInfo(T).@"struct".field_names, 0..) |name, index| names[index] = name;
    for (@min(1, names.len)..names.len) |end| {
        var index = end;
        while (index > 0 and std.mem.order(u8, names[index], names[index - 1]) == .lt) {
            std.mem.swap([]const u8, &names[index], &names[index - 1]);
            index -= 1;
        }
    }
    return names;
}

fn appendName(range: *@import("workspace_projection.zig").Range, name: []const u8) !void {
    try range.append("\"");
    for (name) |byte| {
        if (byte == '"' or byte == '\\') try range.append("\\");
        try range.append(&.{byte});
    }
    try range.append("\"");
}

fn appendSequence(
    comptime T: type,
    range: *@import("workspace_projection.zig").Range,
    value: []const T,
) !void {
    try range.append("[");
    for (value, 0..) |child, index| {
        if (index != 0) try range.append(",");
        try appendRecord(T, range, child);
    }
    try range.append("]");
}

fn appendBytes(range: *@import("workspace_projection.zig").Range, value: []const u8) !void {
    try range.append("\"");
    var offset: usize = 0;
    var buffer: [4096]u8 = undefined;
    while (offset < value.len) {
        const count = @min(3072, value.len - offset);
        try range.append(std.base64.url_safe_no_pad.Encoder.encode(
            &buffer,
            value[offset..][0..count],
        ));
        offset += count;
    }
    try range.append("\"");
}

fn toJson(comptime T: type, a: std.mem.Allocator, value: T) std.mem.Allocator.Error!json.Value {
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => values.toJson(T, a, value),
        .optional => |info| if (value) |child| toJson(info.child, a, child) else .null,
        .pointer => |info| blk: {
            comptime if (info.size != .slice or !info.attrs.@"const") @compileError("source transport only admits immutable slices");
            if (info.child == u8) break :blk try values.toJson(contracts.Bytes(null), a, .{ .bytes = value });
            var array: std.array_list.Managed(json.Value) = .init(a);
            for (value) |child| try array.append(try toJson(info.child, a, child));
            break :blk .{ .array = array };
        },
        .array => |info| blk: {
            var array: std.array_list.Managed(json.Value) = .init(a);
            for (value) |child| try array.append(try toJson(info.child, a, child));
            break :blk .{ .array = array };
        },
        .@"struct" => |info| blk: {
            var result = json.object();
            inline for (info.field_names, info.field_types) |name, Child| try json.put(a, &result, name, try toJson(Child, a, @field(value, name)));
            break :blk result;
        },
        .@"union" => |info| blk: {
            var result = json.object();
            try json.put(a, &result, "tag", json.string(@tagName(value)));
            inline for (info.field_names, info.field_types) |name, Child| {
                if (std.mem.eql(u8, @tagName(value), name)) try json.put(a, &result, "value", try toJson(Child, a, @field(value, name)));
            }
            break :blk result;
        },
        else => @compileError("unsupported source-record field: " ++ @typeName(T)),
    };
}

fn typed(a: std.mem.Allocator, name: []const u8) !json.Value {
    var result = json.object();
    try json.put(a, &result, "type", json.string(name));
    return result;
}

fn schema(comptime T: type, a: std.mem.Allocator) std.mem.Allocator.Error!json.Value {
    switch (@typeInfo(T)) {
        .bool => return typed(a, "boolean"),
        .int => |info| {
            var result = try typed(a, if (info.bits == 64) "string" else "integer");
            try json.put(a, &result, "description", json.string(if (info.bits == 64) "Canonical decimal integer string; no leading zero, plus sign, or negative zero." else "Exact integer within the declared native range."));
            if (info.bits == 64) {
                try json.put(a, &result, "pattern", json.string(if (info.signedness == .unsigned) "^(0|[1-9][0-9]*)$" else "^(0|-?[1-9][0-9]*)$"));
            } else {
                try json.put(a, &result, "minimum", try json.number(a, std.math.minInt(T)));
                try json.put(a, &result, "maximum", try json.number(a, std.math.maxInt(T)));
            }
            return result;
        },
        .@"enum" => |info| {
            var result = try typed(a, "string");
            var names: std.array_list.Managed(json.Value) = .init(a);
            inline for (info.field_names) |name| try names.append(json.string(name));
            try json.put(a, &result, "enum", .{ .array = names });
            return result;
        },
        .optional => |info| {
            var result = json.object();
            var alternatives: std.array_list.Managed(json.Value) = .init(a);
            try alternatives.append(try typed(a, "null"));
            try alternatives.append(try schema(info.child, a));
            try json.put(a, &result, "anyOf", .{ .array = alternatives });
            return result;
        },
        .pointer => |info| {
            comptime if (info.size != .slice or !info.attrs.@"const") @compileError("source transport only admits immutable slices");
            if (info.child == u8) {
                var result = try typed(a, "string");
                try json.put(a, &result, "description", json.string("Bytes encoded as canonical unpadded base64url, including effect identity bytes and literal wire bytes."));
                try json.put(a, &result, "pattern", json.string("^[A-Za-z0-9_-]*$"));
                return result;
            }
            var result = try typed(a, "array");
            try json.put(a, &result, "items", try schema(info.child, a));
            return result;
        },
        .array => |info| {
            var result = try typed(a, "array");
            try json.put(a, &result, "items", try schema(info.child, a));
            try json.put(a, &result, "minItems", try json.number(a, info.len));
            try json.put(a, &result, "maxItems", try json.number(a, info.len));
            return result;
        },
        .void, .@"struct" => {
            var result = try typed(a, "object");
            var properties = json.object();
            var required: std.array_list.Managed(json.Value) = .init(a);
            if (T != void) inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, Child| {
                try json.put(a, &properties, name, try schema(Child, a));
                try required.append(json.string(name));
            };
            try json.put(a, &result, "properties", properties);
            try json.put(a, &result, "required", .{ .array = required });
            try json.put(a, &result, "additionalProperties", .{ .bool = false });
            return result;
        },
        .@"union" => |info| {
            var result = json.object();
            var alternatives: std.array_list.Managed(json.Value) = .init(a);
            inline for (info.field_names, info.field_types) |name, Child| {
                var member = try typed(a, "object");
                var properties = json.object();
                var tag = try typed(a, "string");
                try json.put(a, &tag, "const", json.string(name));
                try json.put(a, &properties, "tag", tag);
                try json.put(a, &properties, "value", try schema(Child, a));
                var required: std.array_list.Managed(json.Value) = .init(a);
                try required.appendSlice(&.{ json.string("tag"), json.string("value") });
                try json.put(a, &member, "properties", properties);
                try json.put(a, &member, "required", .{ .array = required });
                try json.put(a, &member, "additionalProperties", .{ .bool = false });
                try alternatives.append(member);
            }
            try json.put(a, &result, "oneOf", .{ .array = alternatives });
            return result;
        },
        else => @compileError("unsupported source-record field: " ++ @typeName(T)),
    }
}

test "source-record projection owns decoded memory and derives its schema from the actual records" {
    const a = std.testing.allocator;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const original = try horos.source.examples.lexical(&b);
    const bytes = try encode(a, original);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    a.free(bytes);
    const again = try encode(a, decoded.module);
    defer a.free(again);
    const expected = try encode(a, original);
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, again);
    for ([_]u32{ 1, 37, 4096 }) |maximum| {
        var offset: u64 = 0;
        while (offset < expected.len) {
            var page_arena = std.heap.ArenaAllocator.init(a);
            defer page_arena.deinit();
            const scratch = page_arena.allocator();
            const request: contracts.workspace.Page = .{
                .offset = offset,
                .maximum = maximum,
            };
            const selected = try pageRecord(Document, scratch, .{
                .version = 1,
                .module = original,
            }, request);
            const full = try @import("workspace_projection.zig").page(scratch, expected, request);
            try std.testing.expectEqualStrings(
                try json.canonical(scratch, full),
                try json.canonical(scratch, selected),
            );
            offset += selected.object.get("text").?.string.len;
        }
    }
    const description = try describe(a);
    defer a.free(description);
    var parsed = try json.parseAsset(a, description, description.len);
    defer parsed.deinit();
    const module_properties = parsed.value.object.get("properties").?.object.get("module").?.object.get("properties").?;
    inline for (@typeInfo(horos.source.Module).@"struct".field_names) |name| try std.testing.expect(module_properties.object.contains(name));
    const descriptor = try values.schemaBytes(Document, a);
    defer a.free(descriptor);
    var schema_value = try @import("horos_data").schema.decode(a, descriptor);
    defer schema_value.deinit();
    const encoded_value = try contracts.encodeOwned(Document, a, .{ .version = 1, .module = original });
    defer a.free(encoded_value);
    try @import("horos_data").schema.validateValue(a, schema_value.descriptor, encoded_value);
    var document = try contracts.decodeOwned(Document, a, encoded_value);
    defer document.deinit();
    const projected = try encode(a, document.value.module);
    defer a.free(projected);
    try std.testing.expectEqualStrings(expected, projected);
    const Record = struct { bytes: []const u8, digest: [32]u8 };
    const record: Record = .{ .bytes = &@as([24577]u8, @splat(255)), .digest = @splat(17) };
    const full_record = try encodeRecord(Record, a, record);
    defer a.free(full_record);
    const record_request: contracts.workspace.Page = .{ .offset = 4093, .maximum = 128 };
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const bounded = try pageRecord(Record, fixed.allocator(), record, record_request);
    try std.testing.expectEqualStrings(
        full_record[4093..][0..128],
        bounded.object.get("text").?.string,
    );
    var record_decoded = try decodeRecord(Record, a, full_record);
    defer record_decoded.deinit();
    try std.testing.expectEqualDeep(record, record_decoded.value);
}
