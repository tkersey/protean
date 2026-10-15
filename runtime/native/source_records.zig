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
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var parsed = try json.parse(scratch, bytes, .{
        .bytes = bytes.len,
        .depth = comptime depth(Document),
        .tokens = bytes.len,
        .members = bytes.len,
    });
    defer parsed.deinit();
    const document = try fromJson(Document, scratch, parsed.value);
    if (document.version != 1) return error.UnsupportedVersion;
    return .{ .arena = arena, .module = document.module };
}

pub fn encode(a: std.mem.Allocator, module: horos.source.Module) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return json.canonical(a, try toJson(Document, arena.allocator(), .{ .version = 1, .module = module }));
}

pub fn describe(a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return json.canonical(a, try schema(Document, arena.allocator()));
}

fn depth(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .optional => |info| depth(info.child),
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
    const description = try describe(a);
    defer a.free(description);
    var parsed = try json.parseAsset(a, description, description.len);
    defer parsed.deinit();
    const module_properties = parsed.value.object.get("properties").?.object.get("module").?.object.get("properties").?;
    inline for (@typeInfo(horos.source.Module).@"struct".field_names) |name| try std.testing.expect(module_properties.object.contains(name));
}
