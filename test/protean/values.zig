const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const contracts = @import("contracts");
const a = std.testing.allocator;

const Mode = enum(u32) { later = 63, first = 7 };
const Envelope = struct {
    enabled: bool,
    delta: i64,
    label: contracts.Text(16),
    mode: Mode,
    answer: ?u16,
    samples: [2]u8,
    choices: contracts.Vector(i16, 3),
    blob: contracts.Bytes(4),
};
const envelope: Envelope = .{
    .enabled = true,
    .delta = -2,
    .label = .{ .bytes = "λ" },
    .mode = .later,
    .answer = 0x1234,
    .samples = .{ 3, 4 },
    .choices = .{ .items = &.{ -1, 2 } },
    .blob = .{ .bytes = &.{ 0, 255 } },
};
const expected = [_]u8{
    1,  254, 255, 255, 255, 255, 255, 255, 255,
    2,  206, 187, 63,  0,   0,   0,   1,   52,
    18, 3,   4,   2,   255, 255, 2,   0,   2,
    0,  255,
};

test "descriptor derivation and value bytes agree with public Horos admission" {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const root = try contracts.schema(Envelope, &builder);
    const bytes = try contracts.encodeOwned(Envelope, a, envelope);
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, &expected, bytes);
    try data.schema.validateValue(a, .{ .root = root, .types = builder.schemas.items }, bytes);
    const encoded = try data.schema.encodeOwned(a, builder.schemas.items, root);
    defer a.free(encoded);
    const schema_bytes = [_]u8{
        0, 13, 12, 8,  1,  2, 3,  4,  5,  8, 10, 12,
        1, 5,  19, 16, 20, 2, 7,  63, 13, 2, 6,  7,
        0, 7,  17, 9,  2,  6, 15, 11, 3,  3, 18, 4,
    };
    try std.testing.expectEqualSlices(u8, &schema_bytes, encoded);
    const fixture = try std.json.parseFromSlice(std.json.Value, a, @embedFile("values-vectors.json"), .{ .allocate = .alloc_always });
    defer fixture.deinit();
    const vector = fixture.value.object.get("envelope").?;
    const fixture_schema = vector.object.get("schemaBytes").?.array.items;
    try std.testing.expectEqual(encoded.len, fixture_schema.len);
    for (encoded, fixture_schema) |byte, expected_byte|
        try std.testing.expectEqual(@as(i64, byte), expected_byte.integer);
    const fixture_value = vector.object.get("valueBytes").?.array.items;
    try std.testing.expectEqual(bytes.len, fixture_value.len);
    for (bytes, fixture_value) |byte, expected_byte|
        try std.testing.expectEqual(@as(i64, byte), expected_byte.integer);
    var parsed = try data.schema.decode(a, encoded);
    defer parsed.deinit();
    try data.schema.validateValue(a, parsed.descriptor, &expected);
    var decoded = try contracts.decodeOwned(Envelope, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(envelope.delta, decoded.value.delta);
    try std.testing.expectEqual(envelope.mode, decoded.value.mode);
    try std.testing.expectEqual(envelope.answer, decoded.value.answer);
    try std.testing.expectEqualStrings("λ", decoded.value.label.bytes);
    try std.testing.expectEqualSlices(i16, envelope.choices.items, decoded.value.choices.items);
}

test "decoded slices own backing storage and nested arrays survive input mutation" {
    const T = struct { text: contracts.Utf8, rows: []const [2]u16, raw: []const u8 };
    const value: T = .{
        .text = .{ .bytes = "owned" },
        .rows = &.{.{ 3, 17 }},
        .raw = "bytes",
    };
    const bytes = try contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    var decoded = try contracts.decodeOwned(T, a, bytes);
    defer decoded.deinit();
    @memset(bytes, 0);
    try std.testing.expectEqualStrings("owned", decoded.value.text.bytes);
    try std.testing.expectEqualStrings("bytes", decoded.value.raw);
    try std.testing.expectEqual(@as(u16, 17), decoded.value.rows[0][1]);
}

test "tagged unions use ordinal tags while enums retain their explicit tags" {
    const T = union(enum) { number: u64, empty: void, text: contracts.Text(5) };
    const value: T = .{ .number = std.math.maxInt(u64) };
    const bytes = try contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 255, 255, 255, 255, 255, 255, 255 }, bytes);
    var decoded = try contracts.decodeOwned(T, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.value.number);
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const root = try contracts.schema(T, &builder);
    try data.schema.validateValue(a, .{ .root = root, .types = builder.schemas.items }, bytes);
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(T, a, &.{3}));
    try std.testing.expectError(error.NonCanonical, contracts.decodeOwned(T, a, &.{ 0x81, 0 }));
}

test "sparse union tag values do not replace declaration ordinals on the wire" {
    const Tag = enum(u32) { first = 63, later = 7 };
    const Choice = union(Tag) { first: void, later: u8 };
    const first = try contracts.encodeOwned(Choice, a, .{ .first = {} });
    defer a.free(first);
    const later = try contracts.encodeOwned(Choice, a, .{ .later = 42 });
    defer a.free(later);
    try std.testing.expectEqualSlices(u8, &.{0}, first);
    try std.testing.expectEqualSlices(u8, &.{ 1, 42 }, later);
    var decoded = try contracts.decodeOwned(Choice, a, &.{ 1, 42 });
    defer decoded.deinit();
    try std.testing.expectEqual(Tag.later, std.meta.activeTag(decoded.value));
    try std.testing.expectEqual(@as(u8, 42), decoded.value.later);
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const root = try contracts.schema(Choice, &builder);
    try data.schema.validateValue(a, .{ .root = root, .types = builder.schemas.items }, first);
    try data.schema.validateValue(a, .{ .root = root, .types = builder.schemas.items }, later);
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(Choice, a, &.{ 63, 42 }));
}

test "fixed integers retain full width and signed extrema" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64 }) |T| {
        inline for (.{ std.math.minInt(T), std.math.maxInt(T) }) |value| {
            const bytes = try contracts.encodeOwned(T, a, value);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(T, a, bytes);
            defer decoded.deinit();
            try std.testing.expectEqual(value, decoded.value);
        }
    }
}

test "malformed and semantically invalid input reject without mutating bytes" {
    var bytes = expected;
    bytes[0] = 2;
    const saved = bytes;
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(Envelope, a, &bytes));
    try std.testing.expectEqualSlices(u8, &saved, &bytes);
    try std.testing.expectError(error.Truncated, contracts.decodeOwned(u64, a, &.{1}));
    try std.testing.expectError(error.NonCanonical, contracts.decodeOwned(void, a, &.{0}));
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(?u8, a, &.{2}));
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(Mode, a, &.{ 8, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidUtf8, contracts.decodeOwned(contracts.Text(8), a, &.{ 2, 0xc0, 0x80 }));
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(contracts.Text(1), a, &.{ 2, 'a', 'b' }));
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(contracts.Vector(u8, 1), a, &.{ 2, 0, 0 }));
    try std.testing.expectError(error.Truncated, contracts.decodeOwned([]const u64, a, &.{ 255, 255, 255, 255, 15 }));
}

test "outbound values validate UTF8 and explicit bounds" {
    try std.testing.expectError(error.InvalidValue, contracts.encodeOwned(contracts.Text(1), a, .{ .bytes = "λ" }));
    try std.testing.expectError(error.InvalidUtf8, contracts.encodeOwned(contracts.Utf8, a, .{ .bytes = &.{0xff} }));
    try std.testing.expectError(error.InvalidValue, contracts.encodeOwned(contracts.Vector(u8, 1), a, .{ .items = &.{ 1, 2 } }));
}

test "explicit recursive descriptors are canonicalized and exclude internal values" {
    const types: []const data.program.Schema = &.{ .unit, .{ .sum = &.{ 0, 1 } } };
    var recursive = try contracts.descriptorOwned(a, types, 1);
    defer recursive.deinit();
    try data.schema.validateValue(a, recursive.descriptor, &.{ 1, 1, 0 });
    const internal: []const data.program.Schema = &.{
        .{ .internal = .{ .capability = 0 } }, .{ .product = &.{0} },
    };
    try std.testing.expectError(error.InvalidSchema, contracts.descriptorOwned(a, internal, 1));
}

test "failed decode frees owned allocations" {
    const Test = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var decoded = try contracts.decodeOwned(Envelope, allocator, &expected);
            defer decoded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(a, Test.run, .{});
}

fn agree(descriptor: data.schema.Descriptor, bytes: []const u8) !void {
    const horos_accepts = if (data.schema.validateValue(a, descriptor, bytes))
        true
    else |_|
        false;
    const protean_accepts = if (contracts.decodeOwned(Envelope, a, bytes)) |parsed| blk: {
        var owned = parsed;
        defer owned.deinit();
        break :blk true;
    } else |_| false;
    try std.testing.expectEqual(horos_accepts, protean_accepts);
}

test "every byte mutation and truncation agrees with public Horos value admission" {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const root = try contracts.schema(Envelope, &builder);
    const descriptor: data.schema.Descriptor = .{ .root = root, .types = builder.schemas.items };
    for (0..expected.len) |index| {
        for ([_]u8{ 0, 1, 127, 128, 255 }) |replacement| {
            var changed = expected;
            changed[index] = replacement;
            try agree(descriptor, &changed);
        }
        try agree(descriptor, expected[0..index]);
    }
    try agree(descriptor, &expected);
}
