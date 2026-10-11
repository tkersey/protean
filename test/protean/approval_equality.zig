const std = @import("std");
const horos = @import("horos");
const equality = @import("protean").value_equality;
const kronos = @import("kronos");
const Id = horos.source.Id;

fn observe(program: horos.data.activation.Program, left: []const u8, right: []const u8, expected: bool) !void {
    const args = try std.mem.concat(std.testing.allocator, u8, &.{ left, right });
    defer std.testing.allocator.free(args);
    const storage = try std.testing.allocator.alloc(u8, try horos.data.program_image.encodedLength(program));
    defer std.testing.allocator.free(storage);
    const image = try horos.data.program_image.encode(std.testing.allocator, program, storage);
    var outcome = try kronos.invocation.invoke(std.testing.allocator, .{ .image = image, .instance = .{ .initial_args = args } });
    defer outcome.deinit();
    try std.testing.expect(outcome.record == .completed);
    try std.testing.expectEqualSlices(u8, &.{@intFromBool(expected)}, outcome.record.completed);
}

fn check(b: *horos.source.Builder, schema: Id, left: []const u8, right: []const u8) !void {
    const c = try horos.authoring.Context.init(b);
    const contract = try horos.authoring.interop.schema(c, schema);
    const function = try equality.create(c, contract, try c.literalFailure(void, {}));
    var compiled = try c.compile(std.testing.allocator, function, try c.scalar(void));
    defer compiled.deinit();
    try observe(compiled.program, left, left, true);
    try observe(compiled.program, right, right, true);
    try observe(compiled.program, left, right, false);
    try observe(compiled.program, right, left, false);
}

test "unchanged native Kronos executes structural equality including recursive values" {
    var b = horos.source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const byte = try b.scalar(u8);
    try check(&b, try b.scalar(bool), &.{0}, &.{1});
    try check(&b, try b.scalar(i8), &.{255}, &.{127});
    try check(&b, try b.scalar(i64), &.{ 255, 255, 255, 255, 255, 255, 255, 255 }, &.{ 127, 0, 0, 0, 0, 0, 0, 0 });
    try check(&b, try b.schema(.{ .enumeration = &.{ 1, 1024 } }), &.{ 1, 0, 0, 0 }, &.{ 0, 4, 0, 0 });
    try check(&b, try b.schema(.text), &.{ 1, 'x' }, &.{ 2, 0xc3, 0xa9 });
    try check(&b, try b.schema(.{ .bounded_bytes = 32 }), &.{0}, &.{ 2, 0, 255 });
    try check(&b, try b.schema(.{ .product = &.{ byte, byte } }), &.{ 1, 2 }, &.{ 1, 3 });
    try check(&b, try b.schema(.{ .sum = &.{ unit, byte } }), &.{0}, &.{ 1, 2 });
    try check(&b, try b.schema(.{ .sum = &.{ unit, byte } }), &.{ 1, 1 }, &.{ 1, 2 });
    try check(&b, try b.schema(.{ .seq = byte }), &.{ 2, 1, 2 }, &.{ 2, 1, 3 });
    try check(&b, try b.schema(.{ .seq = byte }), &.{0}, &.{ 3, 1, 2, 3 });
    try check(&b, try b.schema(.{ .vector = .{ .element = byte, .maximum = 4 } }), &.{ 2, 1, 2 }, &.{ 3, 1, 2, 3 });
    try check(&b, try b.schema(.{ .array = .{ .element = byte, .length = 3 } }), &.{ 1, 2, 3 }, &.{ 1, 2, 4 });
    const tree = try b.reserveSchema();
    const node = try b.schema(.{ .product = &.{ byte, tree, tree } });
    try b.defineSchema(tree, .{ .sum = &.{ unit, node } });
    try check(&b, tree, &.{ 1, 3, 1, 1, 0, 0, 0 }, &.{ 1, 3, 1, 2, 0, 0, 0 });
    try check(&b, tree, &.{0}, &.{ 1, 3, 0, 0 });
}
