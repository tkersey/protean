//! Native client values use the existing ordinary Protean codecs and schemas.
//! JSON only projects those values; it is not an alternate Kosmos wire format.
const std = @import("std");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const json = @import("json.zig");

test "client JSON integers accept exact equivalent spellings within the declared range" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "1", "1.0", "1e0" }) |number|
        try std.testing.expectEqual(
            @as(u32, 1),
            try fromJson(u32, a, .{ .number_string = number }),
        );
    try std.testing.expectError(error.InvalidParams, fromJson(u32, a, .{ .number_string = "-1" }));
    try std.testing.expectError(
        error.InvalidParams,
        fromJson(u32, a, .{ .number_string = "4294967296" }),
    );
    try std.testing.expectError(error.InvalidParams, fromJson(u32, a, .{ .number_string = "1.5" }));
}
pub const schemas = contracts.json;
pub const Error = error{InvalidParams} || std.mem.Allocator.Error;

pub inline fn fromJson(comptime T: type, a: std.mem.Allocator, value: json.Value) Error!T {
    @setEvalBranchQuota(100_000);
    if (comptime schemas.isText(T)) {
        const text = try json.text(value);
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidParams;
        if (T.max_length) |maximum| if (text.len > maximum) return error.InvalidParams;
        return .{ .bytes = text };
    }
    if (comptime contracts.native.wrapped(T)) {
        if (T.protean_value_kind == .bytes) {
            const text = try json.text(value);
            const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(
                text,
            ) catch return error.InvalidParams;
            if (T.max_length) |maximum| if (size > maximum) return error.InvalidParams;
            const bytes = try a.alloc(u8, size);
            std.base64.url_safe_no_pad.Decoder.decode(bytes, text) catch return error.InvalidParams;
            // Require canonical trailing bits and forbid padded aliases.
            const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(size));
            if (!std.mem.eql(
                u8,
                text,
                std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes),
            )) return error.InvalidParams;
            return .{ .bytes = bytes };
        }
        if (T.protean_value_kind == .vector) {
            if (value != .array) return error.InvalidParams;
            if (@as(
                ?u64,
                T.max_length,
            )) |maximum| if (value.array.items.len > maximum) return error.InvalidParams;
            const result = try a.alloc(T.Child, value.array.items.len);
            for (result, value.array.items) |*slot, child| slot.* = try fromJson(T.Child, a, child);
            return .{ .items = result };
        }
    }
    return switch (@typeInfo(T)) {
        .void => if (value == .object and value.object.count() == 0) {} else error.InvalidParams,
        .bool => if (value == .bool) value.bool else error.InvalidParams,
        .int => |info| if (info.bits == 64) try json.decimal(
            T,
            value,
        ) else if (value == .number_string) std.math.cast(
            T,
            try json.safeInteger(value.number_string),
        ) orelse error.InvalidParams else error.InvalidParams,
        .@"enum" => std.meta.stringToEnum(T, try json.text(value)) orelse error.InvalidParams,
        .optional => try optionalFromJson(T, a, value),
        .array => try arrayFromJson(T, a, value),
        .@"struct" => try structFromJson(T, a, value),
        .@"union" => try unionFromJson(T, a, value),
        else => @compileError("unsupported native client contract: " ++ @typeName(T)),
    };
}

pub inline fn toJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!json.Value {
    @setEvalBranchQuota(100_000);
    if (comptime schemas.isText(T)) return json.string(try a.dupe(u8, value.bytes));
    if (comptime contracts.native.wrapped(T)) {
        if (T.protean_value_kind == .bytes) {
            const result = try a.alloc(
                u8,
                std.base64.url_safe_no_pad.Encoder.calcSize(value.bytes.len),
            );
            return json.string(std.base64.url_safe_no_pad.Encoder.encode(result, value.bytes));
        }
        if (T.protean_value_kind == .vector) {
            var array: std.array_list.Managed(json.Value) = .init(a);
            for (value.items) |child| try array.append(try toJson(T.Child, a, child));
            return .{ .array = array };
        }
    }
    return switch (@typeInfo(T)) {
        .void => json.object(),
        .bool => .{ .bool = value },
        .int => |info| if (info.bits == 64) json.string(
            try std.fmt.allocPrint(a, "{d}", .{value}),
        ) else try json.number(a, value),
        .@"enum" => json.string(@tagName(value)),
        .optional => try optionalToJson(T, a, value),
        .array => try arrayToJson(T, a, value),
        .@"struct" => try structToJson(T, a, value),
        .@"union" => try unionToJson(T, a, value),
        else => @compileError("unsupported native client contract: " ++ @typeName(T)),
    };
}

inline fn optionalFromJson(comptime T: type, a: std.mem.Allocator, value: json.Value) Error!T {
    const info = @typeInfo(T).optional;
    if (value == .null) return null;
    if (comptime schemas.taggedOptional(T)) {
        if (value != .object or value.object.count() != 2) return error.InvalidParams;
        const tag = try json.text(
            value.object.get("tag") orelse return error.InvalidParams,
        );
        if (!std.mem.eql(u8, tag, "some")) return error.InvalidParams;
        return @as(
            T,
            try fromJson(
                info.child,
                a,
                value.object.get("value") orelse return error.InvalidParams,
            ),
        );
    }
    return @as(T, try fromJson(info.child, a, value));
}

inline fn arrayFromJson(comptime T: type, a: std.mem.Allocator, value: json.Value) Error!T {
    const info = @typeInfo(T).array;
    if (value != .array or value.array.items.len != info.len) return error.InvalidParams;
    var result: T = undefined;
    for (&result, value.array.items) |*slot, child| slot.* = try fromJson(
        info.child,
        a,
        child,
    );
    return result;
}

inline fn structFromJson(comptime T: type, a: std.mem.Allocator, value: json.Value) Error!T {
    const info = @typeInfo(T).@"struct";
    if (value != .object or
        value.object.count() != info.field_names.len)
        return error.InvalidParams;
    var result: T = undefined;
    inline for (info.field_names, info.field_types) |name, FieldType| {
        @field(result, name) = try fromJson(
            FieldType,
            a,
            value.object.get(name) orelse return error.InvalidParams,
        );
    }
    return result;
}

inline fn unionFromJson(comptime T: type, a: std.mem.Allocator, value: json.Value) Error!T {
    const info = @typeInfo(T).@"union";
    if (value != .object or value.object.count() != 2) return error.InvalidParams;
    const tag = try json.text(value.object.get("tag") orelse return error.InvalidParams);
    const child = value.object.get("value") orelse return error.InvalidParams;
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (std.mem.eql(u8, tag, name))
            return @unionInit(T, name, try fromJson(FieldType, a, child));
    }
    return error.InvalidParams;
}

inline fn optionalToJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!json.Value {
    const info = @typeInfo(T).optional;
    const child = value orelse return .null;
    const projected = try toJson(info.child, a, child);
    if (comptime schemas.taggedOptional(T)) {
        var result = json.object();
        try json.put(a, &result, "tag", json.string("some"));
        try json.put(a, &result, "value", projected);
        return result;
    }
    return projected;
}

inline fn arrayToJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!json.Value {
    const info = @typeInfo(T).array;
    var array: std.array_list.Managed(json.Value) = .init(a);
    for (value) |child| try array.append(try toJson(info.child, a, child));
    return .{ .array = array };
}

inline fn structToJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!json.Value {
    const info = @typeInfo(T).@"struct";
    var result = json.object();
    inline for (info.field_names, info.field_types) |name, FieldType| try json.put(
        a,
        &result,
        name,
        try toJson(FieldType, a, @field(value, name)),
    );
    return result;
}

inline fn unionToJson(
    comptime T: type,
    a: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error!json.Value {
    const info = @typeInfo(T).@"union";
    var result = json.object();
    try json.put(a, &result, "tag", json.string(@tagName(value)));
    inline for (info.field_names, info.field_types) |name, FieldType| {
        if (std.mem.eql(u8, @tagName(value), name)) try json.put(
            a,
            &result,
            "value",
            try toJson(FieldType, a, @field(value, name)),
        );
    }
    return result;
}

pub fn encodeClient(comptime T: type, a: std.mem.Allocator, value: json.Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return contracts.encodeOwned(T, a, try fromJson(T, arena.allocator(), value));
}

const Catalog = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(data.program.Schema) = .empty,
    pub fn schema(self: *Catalog, shape: data.program.Schema) std.mem.Allocator.Error!u64 {
        const owned: data.program.Schema = switch (shape) {
            .product => |fields| .{ .product = try self.allocator.dupe(u64, fields) },
            .sum => |fields| .{ .sum = try self.allocator.dupe(u64, fields) },
            .enumeration => |tags| .{ .enumeration = try self.allocator.dupe(u32, tags) },
            else => shape,
        };
        const id = self.types.items.len;
        try self.types.append(self.allocator, owned);
        return @intCast(id);
    }
};

/// A data catalog, not a source compiler. Canonicalization and encoding remain
/// owned by Horos; handler schemas and authored schemas share that owner.
pub fn schemaBytes(comptime T: type, a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var catalog = Catalog{ .allocator = arena.allocator() };
    const root = try contracts.schema(T, &catalog);
    return data.schema.encodeOwned(a, catalog.types.items, root);
}

test "client mapping preserves full-width values and rejects coercion and unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Record = struct {
        count: u64,
        text: contracts.Text(16),
        bytes: contracts.Bytes(4),
        choice: ?bool,
    };
    var parsed = try json.parse(
        a,
        "{\"count\":\"18446744073709551615\",\"text\":\"雪\",\"bytes\":\"AP8\",\"choice\":null}",
        .{},
    );
    defer parsed.deinit();
    const encoded = try encodeClient(Record, a, parsed.value);
    var decoded = try contracts.decodeOwned(Record, a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.value.count);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, decoded.value.bytes.bytes);
    const result = try toJson(Record, a, decoded.value);
    try std.testing.expectEqualStrings("18446744073709551615", result.object.get("count").?.string);
    try parsed.value.object.put(a, "count", .{ .number_string = "18446744073709551615" });
    try std.testing.expectError(error.InvalidParams, fromJson(Record, a, parsed.value));
    try parsed.value.object.put(a, "count", .{ .string = "1" });
    try parsed.value.object.put(a, "extra", .null);
    try std.testing.expectError(error.InvalidParams, fromJson(Record, a, parsed.value));
    const runtime_schema = try schemas.ClientSchema(Record).alloc(std.testing.allocator);
    defer std.testing.allocator.free(runtime_schema);
    try std.testing.expectEqualSlices(u8, &schemas.ClientSchema(Record).value, runtime_schema);
    try std.testing.expectError(
        error.OutOfMemory,
        schemas.ClientSchema(Record).alloc(std.testing.failing_allocator),
    );
    const Escaped = struct { @"quote\"slash\\雪": union(enum) { signed: i64, nested: ??bool } };
    const escaped_schema = try schemas.ClientSchema(Escaped).alloc(std.testing.allocator);
    defer std.testing.allocator.free(escaped_schema);
    try std.testing.expectEqualSlices(u8, &schemas.ClientSchema(Escaped).value, escaped_schema);
    var schema = try json.parse(a, &schemas.ClientSchema(Record).value, .{});
    defer schema.deinit();
    try std.testing.expectEqualStrings(
        "string",
        schema.value.object.get("properties").?.object.get("count").?.object.get("type").?.string,
    );
}

test "nested optional client values preserve every independent wire discriminant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { wire: []const u8, client: []const u8 };
    inline for (.{
        .{ ?bool, [_]Case{
            .{ .wire = &.{0}, .client = "null" },
            .{ .wire = &.{ 1, 0 }, .client = "false" },
            .{ .wire = &.{ 1, 1 }, .client = "true" },
        } },
        .{ ??bool, [_]Case{
            .{ .wire = &.{0}, .client = "null" },
            .{ .wire = &.{ 1, 0 }, .client = "{\"tag\":\"some\",\"value\":null}" },
            .{ .wire = &.{ 1, 1, 0 }, .client = "{\"tag\":\"some\",\"value\":false}" },
            .{ .wire = &.{ 1, 1, 1 }, .client = "{\"tag\":\"some\",\"value\":true}" },
        } },
        .{ ???bool, [_]Case{
            .{ .wire = &.{0}, .client = "null" },
            .{ .wire = &.{ 1, 0 }, .client = "{\"tag\":\"some\",\"value\":null}" },
            .{
                .wire = &.{ 1, 1, 0 },
                .client = "{\"tag\":\"some\",\"value\":{\"tag\":\"some\",\"value\":null}}",
            },
            .{
                .wire = &.{ 1, 1, 1, 0 },
                .client = "{\"tag\":\"some\",\"value\":{\"tag\":\"some\",\"value\":false}}",
            },
            .{
                .wire = &.{ 1, 1, 1, 1 },
                .client = "{\"tag\":\"some\",\"value\":{\"tag\":\"some\",\"value\":true}}",
            },
        } },
        .{ ??void, [_]Case{
            .{ .wire = &.{0}, .client = "null" },
            .{ .wire = &.{ 1, 0 }, .client = "{\"tag\":\"some\",\"value\":null}" },
            .{ .wire = &.{ 1, 1 }, .client = "{\"tag\":\"some\",\"value\":{}}" },
        } },
    }) |fixture| {
        const T = fixture[0];
        for (fixture[1]) |case| {
            var decoded = try contracts.decodeOwned(T, a, case.wire);
            defer decoded.deinit();
            const projected = try toJson(T, a, decoded.value);
            try std.testing.expectEqualStrings(case.client, try json.canonical(a, projected));
            const parsed = try json.parse(a, case.client, .{});
            try std.testing.expectEqualSlices(u8, case.wire, try encodeClient(T, a, parsed.value));
        }
    }
    try std.testing.expectEqualStrings("agent-client-values/1.1", schemas.client_mapping);
}

test "JSON projection owns nested text independently of decoded input" {
    const Text = contracts.Utf8;
    const Choice = union(enum) { text: Text, empty: void };
    const Record = struct { text: Text, nested: [1]?Choice };
    var output = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer output.deinit();
    const bytes = try contracts.encodeOwned(Record, std.testing.allocator, .{ .text = .{
        .bytes = "root",
    }, .nested = .{.{ .text = .{ .bytes = "nested" } }} });
    defer std.testing.allocator.free(bytes);
    var source = try contracts.decodeOwned(Record, std.testing.allocator, bytes);
    const projected = try toJson(Record, output.allocator(), source.value);
    @memset(@constCast(source.value.text.bytes), 'x');
    @memset(@constCast(source.value.nested[0].?.text.bytes), 'x');
    source.deinit();
    try std.testing.expectEqualStrings("root", projected.object.get("text").?.string);
    try std.testing.expectEqualStrings(
        "nested",
        projected.object.get("nested").?.array.items[0].object.get("value").?.string,
    );
}
