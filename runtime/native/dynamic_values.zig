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

/// Page canonical JSON without expanding a zero-width collection into one
/// allocation per logical element. The temporary tree stores concatenation and
/// repetition; its lengths count JSON bytes, not canonical value bytes.
pub fn page(a: std.mem.Allocator, schema: []const u8, bytes: []const u8, requested: contracts.workspace.Page) !json.Value {
    if (requested.maximum == 0 or requested.maximum > 48 * 1024) return error.InvalidRange;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var decoded = try data.schema.decode(scratch, schema);
    defer decoded.deinit();
    try data.schema.validateValue(scratch, decoded.descriptor, bytes);
    var projection: Projection = .{ .allocator = scratch };
    const root = try projection.build(decoded.descriptor, bytes);
    const total = projection.nodes.items[root].length;
    if (requested.offset > total) return error.InvalidRange;
    const window = try scratch.alloc(u8, @intCast(@min(total - requested.offset, requested.maximum + 1)));
    try projection.copy(root, requested.offset, window);
    return @import("workspace_projection.zig").window(a, window, requested, total);
}

const Projection = struct {
    const Node = struct {
        length: u64,
        content: union(enum) { text: []const u8, concat: struct { left: usize, right: usize }, repeat: usize },
    };
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,

    fn add(self: *Projection, node: Node) !usize {
        const id = self.nodes.items.len;
        try self.nodes.append(self.allocator, node);
        return id;
    }
    fn text(self: *Projection, bytes: []const u8) !usize {
        return self.add(.{ .length = bytes.len, .content = .{ .text = bytes } });
    }
    fn concat(self: *Projection, left: usize, right: usize) !usize {
        return self.add(.{ .length = try std.math.add(u64, self.nodes.items[left].length, self.nodes.items[right].length), .content = .{ .concat = .{ .left = left, .right = right } } });
    }
    fn repeat(self: *Projection, child: usize, count: u64) !usize {
        return self.add(.{ .length = try std.math.mul(u64, self.nodes.items[child].length, count), .content = .{ .repeat = child } });
    }
    fn scalar(self: *Projection, value: json.Value) !usize {
        return self.text(try json.canonical(self.allocator, value));
    }

    fn build(self: *Projection, descriptor: data.schema.Descriptor, bytes: []const u8) !usize {
        const List = struct { schema: u64, index: u64 = 0, length: u64, accumulated: ?usize = null };
        const Task = union(enum) {
            value: u64,
            cache: struct { schema: u64, start: usize },
            sum: usize,
            list: List,
            next: struct { list: List, start: usize },
        };
        const a = self.allocator;
        var pending: std.ArrayList(Task) = .empty;
        var zero_width: std.AutoHashMap(u64, usize) = .init(a);
        var reader: data.wire.Reader = .{ .input = bytes };
        var result: usize = undefined;
        const comma = try self.text(",");
        const open = try self.text("[");
        const close = try self.text("]");
        try pending.append(a, .{ .value = descriptor.root });
        while (pending.pop()) |task| switch (task) {
            .cache => |entry| if (reader.position == entry.start) {
                try zero_width.put(entry.schema, result);
            },
            .sum => |prefix| result = try self.concat(try self.concat(prefix, result), try self.text("}")),
            .list => |list| {
                if (list.index == list.length) {
                    result = try self.concat(if (list.accumulated) |id| try self.concat(open, id) else open, close);
                    continue;
                }
                const shape = descriptor.types[@intCast(list.schema)];
                const child = switch (shape) {
                    .product => |fields| fields[@intCast(list.index)],
                    .seq => |element| element,
                    .vector => |vector| vector.element,
                    .array => |array| array.element,
                    else => unreachable,
                };
                try pending.append(a, .{ .next = .{ .list = list, .start = reader.position } });
                try pending.append(a, .{ .value = child });
            },
            .next => |next| {
                var list = next.list;
                const child = result;
                list.accumulated = if (list.accumulated) |id| try self.concat(try self.concat(id, comma), child) else child;
                list.index += 1;
                // With no consumed bytes, this schema has exactly one external
                // value. All remaining homogeneous elements have that value.
                if (descriptor.types[@intCast(list.schema)] != .product and reader.position == next.start and list.index != list.length) {
                    list.accumulated = try self.concat(list.accumulated.?, try self.repeat(try self.concat(comma, child), list.length - list.index));
                    list.index = list.length;
                }
                try pending.append(a, .{ .list = list });
            },
            .value => |id| {
                if (zero_width.get(id)) |cached| {
                    result = cached;
                    continue;
                }
                try pending.append(a, .{ .cache = .{ .schema = id, .start = reader.position } });
                switch (descriptor.types[@intCast(id)]) {
                    .unit => result = try self.text("{}"),
                    .boolean => result = try self.text(if (try reader.byte() == 0) "false" else "true"),
                    inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => |_, tag| result = try self.scalar(try values.toJson(integerType(tag), a, try reader.fixed(integerType(tag)))),
                    .enumeration => result = try self.scalar(try values.toJson(u32, a, try reader.fixed(u32))),
                    .bytes, .bounded_bytes => result = try self.scalar(try values.toJson(contracts.Bytes(null), a, .{ .bytes = try reader.bytes() })),
                    .text, .bounded_text => result = try self.scalar(json.string(try reader.text())),
                    .sum => |fields| {
                        const tag = try reader.count();
                        try pending.append(a, .{ .sum = try self.text(try std.fmt.allocPrint(a, "{{\"tag\":{d},\"value\":", .{tag})) });
                        try pending.append(a, .{ .value = fields[tag] });
                    },
                    .product, .seq, .vector, .array => {
                        const shape = descriptor.types[@intCast(id)];
                        const length: u64 = switch (shape) {
                            .product => |fields| fields.len,
                            .array => |array| array.length,
                            else => try reader.natural(),
                        };
                        try pending.append(a, .{ .list = .{ .schema = id, .length = length } });
                    },
                    .internal => return error.InvalidSchema,
                }
            },
        };
        try reader.finish();
        return result;
    }

    fn copy(self: *Projection, root: usize, offset: u64, output: []u8) !void {
        const Slice = struct { node: usize, offset: u64, output: []u8 };
        var pending: std.ArrayList(Slice) = .empty;
        try pending.append(self.allocator, .{ .node = root, .offset = offset, .output = output });
        while (pending.pop()) |slice| {
            if (slice.output.len == 0) continue;
            switch (self.nodes.items[slice.node].content) {
                .text => |bytes| @memcpy(slice.output, bytes[@intCast(slice.offset)..][0..slice.output.len]),
                .concat => |pair| {
                    const left = self.nodes.items[pair.left].length;
                    const count: usize = if (slice.offset < left) @intCast(@min(left - slice.offset, slice.output.len)) else 0;
                    if (count != slice.output.len) try pending.append(self.allocator, .{ .node = pair.right, .offset = if (slice.offset < left) 0 else slice.offset - left, .output = slice.output[count..] });
                    if (count != 0) try pending.append(self.allocator, .{ .node = pair.left, .offset = slice.offset, .output = slice.output[0..count] });
                },
                .repeat => |child| {
                    const length = self.nodes.items[child].length;
                    const start = slice.offset % length;
                    const count: usize = @intCast(@min(length - start, slice.output.len));
                    if (count != slice.output.len) try pending.append(self.allocator, .{ .node = slice.node, .offset = slice.offset + count, .output = slice.output[count..] });
                    try pending.append(self.allocator, .{ .node = child, .offset = start, .output = slice.output[0..count] });
                },
            }
        }
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
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const projected_page = try page(arena.allocator(), schema, actual, .{});
    try std.testing.expectEqualStrings(document, projected_page.object.get("text").?.string);
    try std.testing.expect(projected_page.object.get("complete").?.bool);
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

test "runtime schema JSON pages zero-width collections within fixed memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The old whole-value projection needs a billion JSON nodes for five input
    // bytes. Paging the same value, including its far end, fits in 256 KiB.
    const count = 1_000_000_000;
    const schema = try data.schema.encodeOwned(a, &.{ .{ .seq = 1 }, .unit }, 0);
    var encoded: [10]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &encoded };
    try writer.natural(count);
    const bytes = encoded[0..writer.position];
    var buffer: [256 * 1024]u8 = undefined;
    var limited = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expectError(error.OutOfMemory, decode(limited.allocator(), schema, bytes));
    limited.reset();
    const first = try page(limited.allocator(), schema, bytes, .{ .maximum = 10 });
    try std.testing.expectEqualStrings("[{},{},{},", first.object.get("text").?.string);
    try std.testing.expectEqual(@as(u64, 3 * count + 1), try json.numberInteger(u64, first.object.get("total_bytes").?.number_string));
    try std.testing.expect(!first.object.get("complete").?.bool);
    limited.reset();
    const last = try page(limited.allocator(), schema, bytes, .{ .offset = 3 * count - 5, .maximum = 10 });
    try std.testing.expectEqualStrings("{},{}]", last.object.get("text").?.string);
    try std.testing.expect(last.object.get("eof").?.bool);
    // Nested fixed arrays also have zero canonical width. Neither their schema
    // DAG nor the repeated JSON must be expanded by logical cardinality.
    const nested = try data.schema.encodeOwned(a, &.{ .{ .array = .{ .element = 1, .length = count } }, .{ .array = .{ .element = 2, .length = count } }, .{ .product = &.{ 3, 3 } }, .unit }, 0);
    limited.reset();
    const nested_first = try page(limited.allocator(), nested, "", .{ .maximum = 20 });
    try std.testing.expectEqualStrings("[[[{},{}],[{},{}],[{}"[0..20], nested_first.object.get("text").?.string);
}

test "runtime schema pages agree with whole JSON at UTF-8 and recursive boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try values.schemaBytes(contracts.Text(null), a);
    const bytes = try contracts.encodeOwned(contracts.Text(null), a, .{ .bytes = "雪a\n雪" });
    var decoded = try decode(a, schema, bytes);
    defer decoded.deinit();
    const expected = try json.canonical(a, decoded.value);
    for (0..expected.len + 1) |offset| for (1..6) |maximum| {
        const requested: contracts.workspace.Page = .{ .offset = offset, .maximum = @intCast(maximum) };
        const ordinary = @import("workspace_projection.zig").page(a, expected, requested) catch |err| {
            try std.testing.expectError(err, page(a, schema, bytes, requested));
            continue;
        };
        try std.testing.expectEqualStrings(try json.canonical(a, ordinary), try json.canonical(a, try page(a, schema, bytes, requested)));
    };
    const recursive = try data.schema.encodeOwned(a, &.{ .{ .sum = &.{ 1, 0 } }, .unit }, 0);
    const chain = try a.alloc(u8, 10_001);
    @memset(chain, 1);
    chain[chain.len - 1] = 0;
    var full = try decode(a, recursive, chain);
    defer full.deinit();
    const full_text = try json.canonical(a, full.value);
    const tail = try page(a, recursive, chain, .{ .offset = full_text.len - 40, .maximum = 40 });
    try std.testing.expectEqualStrings(full_text[full_text.len - 40 ..], tail.object.get("text").?.string);
}
