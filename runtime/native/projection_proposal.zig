const std = @import("std");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const values = @import("values.zig");
const wc = contracts.workspace;

pub fn Envelope(comptime Header: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        header: Header,
        payload_schema: []const u8,
        payload: []const u8,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn decodeResult(
    a: std.mem.Allocator,
    schema: []const u8,
    bytes: []const u8,
) !Envelope(wc.ProjectionProposal) {
    return decodeEnvelope(wc.ProjectionProposal, a, schema, bytes);
}

pub fn decodeInput(
    a: std.mem.Allocator,
    schema: []const u8,
    bytes: []const u8,
) !Envelope(wc.Ref) {
    return decodeEnvelope(wc.Ref, a, schema, bytes);
}

fn decodeEnvelope(
    comptime Header: type,
    a: std.mem.Allocator,
    schema: []const u8,
    bytes: []const u8,
) !Envelope(Header) {
    var descriptor = try data.schema.decode(a, schema);
    defer descriptor.deinit();
    const fields = switch (descriptor.descriptor.types[@intCast(descriptor.descriptor.root)]) {
        .product => |fields| fields,
        else => return error.InvalidProjectionSchema,
    };
    if (fields.len != 2) return error.InvalidProjectionSchema;
    try requireHeaderSchema(Header, a, descriptor.descriptor, fields[0]);
    try data.schema.validateValue(a, descriptor.descriptor, bytes);
    var consumed: usize = 0;
    var header = try contracts.decodePrefixOwned(Header, a, bytes, &consumed);
    errdefer header.deinit();
    const owned = header.arena.allocator();
    const payload_schema = try data.schema.encodeOwned(
        owned,
        descriptor.descriptor.types,
        fields[1],
    );
    const payload = try owned.dupe(u8, bytes[consumed..]);
    return .{
        .arena = header.arena,
        .header = header.value,
        .payload_schema = payload_schema,
        .payload = payload,
    };
}

fn requireHeaderSchema(
    comptime Header: type,
    a: std.mem.Allocator,
    descriptor: data.schema.Descriptor,
    field: u64,
) !void {
    const actual = try data.schema.encodeOwned(a, descriptor.types, field);
    defer a.free(actual);
    const expected = try values.schemaBytes(Header, a);
    defer a.free(expected);
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidProjectionSchema;
}

const testing_consumer: wc.Ref = .{ .kind = .observation, .id = .{ .bytes = "consumer" } };
const testing_proposal: wc.ProjectionProposal = .{
    .consumer = testing_consumer,
    .blocks = .{ .items = &.{.{ .computed = .{} }} },
};

fn expectPayload(comptime T: type, value: T) !void {
    const a = std.testing.allocator;
    const Result = wc.ProjectionResult(T);
    const schema = try values.schemaBytes(Result, a);
    defer a.free(schema);
    const bytes = try contracts.encodeOwned(Result, a, .{
        .proposal = testing_proposal,
        .value = value,
    });
    defer a.free(bytes);
    var decoded = try decodeResult(a, schema, bytes);
    defer decoded.deinit();
    const expected_schema = try values.schemaBytes(T, a);
    defer a.free(expected_schema);
    const expected = try contracts.encodeOwned(T, a, value);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected_schema, decoded.payload_schema);
    try std.testing.expectEqualSlices(u8, expected, decoded.payload);
    try std.testing.expectEqual(.observation, decoded.header.consumer.kind);
    try std.testing.expectEqualStrings("consumer", decoded.header.consumer.id.bytes);
    try std.testing.expectEqual(@as(usize, 1), decoded.header.blocks.items.len);
    try std.testing.expect(decoded.header.blocks.items[0] == .computed);
    @memset(schema, 0);
    @memset(bytes, 0);
    try std.testing.expectEqualSlices(u8, expected_schema, decoded.payload_schema);
    try std.testing.expectEqualSlices(u8, expected, decoded.payload);
    try std.testing.expectEqualStrings("consumer", decoded.header.consumer.id.bytes);
}

test "projection envelope preserves distinct payload schemas and exact owned bytes" {
    try expectPayload(u64, 31);
    const Aggregate = struct { total: u32, missing: contracts.Vector(u64, null) };
    try expectPayload(Aggregate, .{ .total = 31, .missing = .{ .items = &.{ 7, 9 } } });
    try expectPayload(void, {});
}

test "projection input preserves its actual consumer and zero-width payload" {
    const a = std.testing.allocator;
    const Input = wc.ProjectionInput(void);
    const schema = try values.schemaBytes(Input, a);
    defer a.free(schema);
    const bytes = try contracts.encodeOwned(Input, a, .{
        .consumer = testing_consumer,
        .value = {},
    });
    defer a.free(bytes);
    var decoded = try decodeInput(a, schema, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(.observation, decoded.header.kind);
    try std.testing.expectEqualStrings("consumer", decoded.header.id.bytes);
    try std.testing.expectEqual(@as(usize, 0), decoded.payload.len);
    const expected_schema = try values.schemaBytes(void, a);
    defer a.free(expected_schema);
    try std.testing.expectEqualSlices(u8, expected_schema, decoded.payload_schema);
}

fn expectInvalidSchema(comptime T: type, value: T) !void {
    const a = std.testing.allocator;
    const schema = try values.schemaBytes(T, a);
    defer a.free(schema);
    const bytes = try contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    try std.testing.expectError(error.InvalidProjectionSchema, decodeResult(a, schema, bytes));
}

test "projection envelope rejects wrong header identity and missing or extra fields" {
    try expectInvalidSchema(u64, 1);
    try expectInvalidSchema(struct { header: u64, value: u64 }, .{ .header = 1, .value = 2 });
    try expectInvalidSchema(struct { header: wc.ProjectionProposal }, .{
        .header = testing_proposal,
    });
    const Extra = struct { header: wc.ProjectionProposal, value: u64, extra: bool };
    try expectInvalidSchema(Extra, .{ .header = testing_proposal, .value = 2, .extra = true });
    const a = std.testing.allocator;
    const wrong_schema = try values.schemaBytes(wc.ProjectionResult(u64), a);
    defer a.free(wrong_schema);
    const bytes = try contracts.encodeOwned(wc.ProjectionResult(u64), a, .{
        .proposal = testing_proposal,
        .value = 4,
    });
    defer a.free(bytes);
    try std.testing.expectError(error.InvalidProjectionSchema, decodeInput(a, wrong_schema, bytes));
}

test "projection envelope rejects truncated and trailing result bytes" {
    const a = std.testing.allocator;
    const Result = wc.ProjectionResult(u64);
    const schema = try values.schemaBytes(Result, a);
    defer a.free(schema);
    const bytes = try contracts.encodeOwned(Result, a, .{
        .proposal = testing_proposal,
        .value = 12,
    });
    defer a.free(bytes);
    for (0..bytes.len) |length| {
        if (decodeResult(a, schema, bytes[0..length])) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.AcceptedTruncatedProjection;
        } else |err| if (err == error.OutOfMemory) return err;
    }
    const trailing = try std.mem.concat(a, u8, &.{ bytes, &.{0} });
    defer a.free(trailing);
    if (decodeResult(a, schema, trailing)) |result| {
        var unexpected = result;
        unexpected.deinit();
        return error.AcceptedTrailingProjection;
    } else |err| if (err == error.OutOfMemory) return err;
}

fn allocationDecode(a: std.mem.Allocator) !void {
    const Result = wc.ProjectionResult(contracts.Utf8);
    const schema = try values.schemaBytes(Result, a);
    defer a.free(schema);
    const bytes = try contracts.encodeOwned(Result, a, .{
        .proposal = testing_proposal,
        .value = .{ .bytes = "actual result" },
    });
    defer a.free(bytes);
    var decoded = try decodeResult(a, schema, bytes);
    defer decoded.deinit();
    var payload = try contracts.decodeOwned(contracts.Utf8, a, decoded.payload);
    defer payload.deinit();
    try std.testing.expectEqualStrings("actual result", payload.value.bytes);
}

test "projection envelope releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationDecode, .{});
}
