//! JSON projection of an actual canonical Horos schema, without a comptime type.
//! Products use ordered arrays; sums use {tag: ordinal, value: payload}.
//! Scalar spellings share the existing client codec. No internal value escapes.
const std = @import("std");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const json = @import("json.zig");
const values = @import("values.zig");

pub const identity = "protean-workspace-values/1";
const Error = data.schema.Error || values.Error;

/// Returned bytes are independently owned. Schema decoding checks canonicality
/// and exportability before any catalog lookup; Horos checks the final value.
pub fn encode(a: std.mem.Allocator, schema: []const u8, value: json.Value) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var decoded = try data.schema.decode(scratch, schema);
    defer decoded.deinit();
    var measure: data.wire.Writer = .{};
    try write(scratch, decoded.descriptor, value, &measure);
    const bytes = try a.alloc(u8, measure.position);
    errdefer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try write(scratch, decoded.descriptor, value, &writer);
    try data.schema.validateValue(scratch, decoded.descriptor, bytes);
    return bytes;
}

fn write(a: std.mem.Allocator, descriptor: data.schema.Descriptor, root: json.Value, writer: *data.wire.Writer) Error!void {
    const Task = struct { schema: u64, value: json.Value };
    var pending: std.ArrayList(Task) = .empty;
    defer pending.deinit(a);
    try pending.append(a, .{ .schema = descriptor.root, .value = root });
    while (pending.pop()) |task| {
        const shape = descriptor.types[@intCast(task.schema)];
        const value = task.value;
        switch (shape) {
            .unit => _ = try values.fromJson(void, a, value),
            .boolean => try writer.byte(@intFromBool(try values.fromJson(bool, a, value))),
            inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |_, tag| {
                try writeInteger(tag, a, value, writer);
            },
            .enumeration => |tags| {
                const tag = try values.fromJson(u32, a, value);
                if (std.mem.indexOfScalar(u32, tags, tag) == null) return error.InvalidParams;
                try writer.fixed(u32, tag);
            },
            .bytes, .bounded_bytes => {
                const bytes = (try values.fromJson(contracts.Bytes(null), a, value)).bytes;
                if (shape == .bounded_bytes and bytes.len > shape.bounded_bytes) return error.InvalidParams;
                try writer.bytes(bytes);
            },
            .text, .bounded_text => {
                const text = (try values.fromJson(contracts.Text(null), a, value)).bytes;
                if (shape == .bounded_text and text.len > shape.bounded_text) return error.InvalidParams;
                try writer.bytes(text);
            },
            .sum => |fields| {
                if (value != .object or value.object.count() != 2) return error.InvalidParams;
                const tag = try values.fromJson(u32, a, value.object.get("tag") orelse return error.InvalidParams);
                if (tag >= fields.len) return error.InvalidParams;
                try writer.natural(tag);
                try pending.append(a, .{ .schema = fields[tag], .value = value.object.get("value") orelse return error.InvalidParams });
            },
            .product, .seq, .vector, .array => {
                if (value != .array) return error.InvalidParams;
                const items = value.array.items;
                switch (shape) {
                    .product => |fields| if (items.len != fields.len) return error.InvalidParams,
                    .array => |array| if (items.len != array.length) return error.InvalidParams,
                    .vector => |vector| {
                        if (items.len > vector.maximum) return error.InvalidParams;
                        try writer.natural(items.len);
                    },
                    .seq => try writer.natural(items.len),
                    else => unreachable,
                }
                var i = items.len;
                while (i != 0) {
                    i -= 1;
                    const child = switch (shape) {
                        .product => |fields| fields[i],
                        .seq => |element| element,
                        .vector => |vector| vector.element,
                        .array => |array| array.element,
                        else => unreachable,
                    };
                    try pending.append(a, .{ .schema = child, .value = items[i] });
                }
            },
            .internal => return error.InvalidSchema,
        }
    }
}

fn integerType(comptime tag: data.program.SchemaTag) type {
    return switch (tag) {
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        else => @compileError("not an integer schema"),
    };
}

fn writeInteger(comptime tag: data.program.SchemaTag, a: std.mem.Allocator, value: json.Value, writer: *data.wire.Writer) Error!void {
    const T = integerType(tag);
    try writer.fixed(T, try values.fromJson(T, a, value));
}

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: json.Value,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// All strings and children belong to the result, including text from input.
/// Explicit work stacks handle recursive schemas without native recursion.
pub fn decode(a: std.mem.Allocator, schema: []const u8, bytes: []const u8) Error!Owned {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    var decoded = try data.schema.decode(scratch, schema);
    defer decoded.deinit();
    try data.schema.validateValue(scratch, decoded.descriptor, bytes);
    var result: json.Value = undefined;
    const Task = struct { schema: u64, target: *json.Value };
    var pending: std.ArrayList(Task) = .empty;
    try pending.append(scratch, .{ .schema = decoded.descriptor.root, .target = &result });
    var reader: data.wire.Reader = .{ .input = bytes };
    while (pending.pop()) |task| {
        const shape = decoded.descriptor.types[@intCast(task.schema)];
        const target = task.target;
        switch (shape) {
            .unit => target.* = json.object(),
            .boolean => target.* = .{ .bool = try reader.byte() != 0 },
            inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |_, tag| {
                const T = integerType(tag);
                target.* = try values.toJson(T, scratch, try reader.fixed(T));
            },
            .enumeration => target.* = try values.toJson(u32, scratch, try reader.fixed(u32)),
            .bytes, .bounded_bytes => target.* = try values.toJson(contracts.Bytes(null), scratch, .{ .bytes = try reader.bytes() }),
            .text, .bounded_text => target.* = json.string(try scratch.dupe(u8, try reader.text())),
            .sum => |fields| {
                const tag = try reader.count();
                target.* = json.object();
                try json.put(scratch, target, "tag", try json.number(scratch, tag));
                try json.put(scratch, target, "value", .null);
                try pending.append(scratch, .{ .schema = fields[tag], .target = target.object.getPtr("value").? });
            },
            .product, .seq, .vector, .array => {
                const length = switch (shape) {
                    .product => |fields| fields.len,
                    .array => |array| std.math.cast(usize, array.length) orelse return error.Capacity,
                    else => try reader.count(),
                };
                target.* = .{ .array = .init(scratch) };
                try target.array.resize(length);
                var i = length;
                while (i != 0) {
                    i -= 1;
                    const child = switch (shape) {
                        .product => |fields| fields[i],
                        .seq => |element| element,
                        .vector => |vector| vector.element,
                        .array => |array| array.element,
                        else => unreachable,
                    };
                    try pending.append(scratch, .{ .schema = child, .target = &target.array.items[i] });
                }
            },
            .internal => return error.InvalidSchema,
        }
    }
    try reader.finish();
    return .{ .arena = arena, .value = result };
}

test "runtime schema JSON agrees with independent native codecs and exact scalar bytes" {
    const a = std.testing.allocator;
    const T = struct {
        count: u64,
        delta: i64,
        text: contracts.Text(8),
        bytes: contracts.Bytes(2),
        choice: union(enum) { empty: void, number: u16 },
        items: contracts.Vector(i8, 3),
        pair: [2]bool,
        mode: enum(u32) { first = 7, last = 63 },
    };
    const schema = try values.schemaBytes(T, a);
    defer a.free(schema);
    const expected = try contracts.encodeOwned(T, a, .{
        .count = std.math.maxInt(u64),
        .delta = std.math.minInt(i64),
        .text = .{ .bytes = "雪" },
        .bytes = .{ .bytes = &.{ 0, 255 } },
        .choice = .{ .number = 4660 },
        .items = .{ .items = &.{ -128, 127 } },
        .pair = .{ true, false },
        .mode = .last,
    });
    defer a.free(expected);
    const document = "[\"18446744073709551615\",\"-9223372036854775808\",\"雪\",\"AP8\",{\"tag\":1,\"value\":4660},[-128,127],[true,false],63]";
    var parsed = try json.parse(a, document, .{});
    defer parsed.deinit();
    const actual = try encode(a, schema, parsed.value);
    defer a.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
    var projected = try decode(a, schema, actual);
    defer projected.deinit();
    const encoded_json = try json.canonical(a, projected.value);
    defer a.free(encoded_json);
    try std.testing.expectEqualStrings(document, encoded_json);
}

test "runtime schema JSON rejects bounds, coercion, malformed variants and internal schemas" {
    const a = std.testing.allocator;
    const Case = struct { shape: data.program.Schema, document: []const u8 };
    for ([_]Case{
        .{ .shape = .u8, .document = "256" },
        .{ .shape = .u64, .document = "18446744073709551615" },
        .{ .shape = .u64, .document = "\"18446744073709551616\"" },
        .{ .shape = .i64, .document = "\"-9223372036854775809\"" },
        .{ .shape = .boolean, .document = "1" },
        .{ .shape = .unit, .document = "null" },
        .{ .shape = .{ .bounded_bytes = 1 }, .document = "\"AP8\"" },
        .{ .shape = .bytes, .document = "\"AP9\"" },
        .{ .shape = .bytes, .document = "\"AP8=\"" },
        .{ .shape = .{ .bounded_text = 2 }, .document = "\"雪\"" },
        .{ .shape = .{ .enumeration = &.{ 7, 63 } }, .document = "0" },
        .{ .shape = .{ .sum = &.{1} }, .document = "{\"tag\":1,\"value\":{}}" },
        .{ .shape = .{ .sum = &.{1} }, .document = "{\"tag\":0,\"value\":{},\"extra\":true}" },
        .{ .shape = .{ .product = &.{1} }, .document = "[]" },
        .{ .shape = .{ .array = .{ .element = 1, .length = 2 } }, .document = "[{}]" },
        .{ .shape = .{ .vector = .{ .element = 1, .maximum = 1 } }, .document = "[{},{}]" },
    }) |case| {
        const schema = try data.schema.encodeOwned(a, &.{ case.shape, .unit }, 0);
        defer a.free(schema);
        var parsed = try json.parse(a, case.document, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidParams, encode(a, schema, parsed.value));
    }
    // Canonical descriptor bytes: root 0, one internal capability schema.
    try std.testing.expectError(error.InvalidSchema, encode(a, &.{ 0, 1, 16, 1, 0 }, json.object()));
    const boolean_schema = try values.schemaBytes(bool, a);
    defer a.free(boolean_schema);
    try std.testing.expectError(error.InvalidValue, decode(a, boolean_schema, &.{2}));
    try std.testing.expectError(error.NonCanonical, decode(a, boolean_schema, &.{ 1, 0 }));
}

test "runtime schema projection traverses deep recursive values without a depth cutoff" {
    const a = std.testing.allocator;
    const schema = try data.schema.encodeOwned(a, &.{ .{ .sum = &.{ 1, 0 } }, .unit }, 0);
    defer a.free(schema);
    const input = try a.alloc(u8, 10_001);
    defer a.free(input);
    @memset(input, 1);
    input[input.len - 1] = 0;
    var projected = try decode(a, schema, input);
    defer projected.deinit();
    const result = try encode(a, schema, projected.value);
    defer a.free(result);
    try std.testing.expectEqualSlices(u8, input, result);
}

fn allocationProbe(a: std.mem.Allocator) !void {
    const schema = try values.schemaBytes(contracts.Vector(contracts.Bytes(null), null), a);
    defer a.free(schema);
    var projected = try decode(a, schema, &.{ 2, 2, 0, 255, 1, 7 });
    defer projected.deinit();
    const result = try encode(a, schema, projected.value);
    defer a.free(result);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 0, 255, 1, 7 }, result);
}

test "runtime schema projection releases partial owners on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
