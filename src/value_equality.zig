//! Structural equality for portable values, emitted through typed Horos code.
const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const a = horos.authoring;
const Id = source.Id;
const native = horos.data.schema.native;
const Boolean = a.Shape(bool);
const V = *const a.Value(a.Dynamic);
const S = *const a.Schema(a.Dynamic);
const Fault = *const a.FailureLiteral(a.Dynamic);
const Branch = a.Body(native.Fields(&.{}, &.{}));
fn Comparison(comptime Shape: type) type {
    return a.Function(a.Signature(native.Fields(&.{ "left", "right" }, &.{ Shape, Shape }), Boolean));
}

pub const Error = source.Error || error{UnsupportedEqualitySchema};
pub const TypedError = a.Error || error{UnsupportedEqualitySchema};

/// Construct a pure comparison, retaining named schemas and recursive sharing.
pub fn create(c: *a.Context, schema: anytype, failure: anytype) TypedError!*const Comparison(a.ShapeOf(@TypeOf(schema))) {
    const b = a.interop.builder(c);
    const id = try a.interop.schemaId(c, schema);
    _ = try a.interop.failureLiteralId(c, failure);
    try checkPortableSchema(b, id);
    const function = try declare(c, a.interop.erase(schema), a.interop.erase(failure));
    return a.interop.refineFunction(c, function, try c.callable(.{ .left = schema, .right = schema }, try c.schema(bool), .{}, .{ .use = .reusable }));
}

/// Inspect a source schema for portable equality/presentation admission without
/// emitting code. This is an IR admission boundary: IDs belong to this Builder,
/// and every call rechecks the current graph, including recursive children.
pub fn checkPortableSchema(b: *source.Builder, schema: Id) Error!void {
    var visited = std.AutoHashMapUnmanaged(Id, void){};
    defer visited.deinit(b.allocator());
    try portable(b, schema, &visited);
}

fn portable(
    b: *source.Builder,
    schema: Id,
    visited: *std.AutoHashMapUnmanaged(Id, void),
) Error!void {
    if (schema >= b.schemas.items.len) return error.InvalidReference;
    const entry = try visited.getOrPut(b.allocator(), schema);
    if (entry.found_existing) return;
    switch (b.schemas.items[@intCast(schema)]) {
        .internal => return error.UnsupportedEqualitySchema,
        .product, .sum => |children| for (children) |child| try portable(b, child, visited),
        .seq => |element| try portable(b, element, visited),
        .vector => |vector| try portable(b, vector.element, visited),
        .array => |array| try portable(b, array.element, visited),
        else => {},
    }
}

fn declare(c: *a.Context, schema: S, failure: Fault) TypedError!*const Comparison(a.Dynamic) {
    const b = a.interop.builder(c);
    const id = try a.interop.schemaId(c, schema);
    const cached = try b.specialization(Id, "agent.value-equality/typed-v1", .{ @intFromPtr(c), @intFromPtr(schema), try a.interop.failureLiteralId(c, failure) });
    if (cached.cached) |function| return a.interop.refineFunction(c, try a.interop.declaredFunction(c, function), try c.callable(.{ .left = schema, .right = schema }, try c.schema(bool), .{}, .{ .use = .reusable }));
    const function = try c.function("portable equality", .{ .left = schema, .right = schema }, try c.schema(bool), &.{});
    // Register before descending into recursive portable schemas.
    _ = try cached.finish(b, try a.interop.functionId(c, function));
    const body = try c.body(function);
    const left = try body.parameter("left");
    const right = try body.parameter("right");
    const result = switch (b.schemas.items[@intCast(id)]) {
        .unit => try body.constant(bool, true),
        .boolean, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => try body.equal(left, right),
        .enumeration => try body.equal(try body.enumTag(left), try body.enumTag(right)),
        .bytes, .text, .bounded_bytes, .bounded_text => try body.equal(try body.blobCompare(left, right), try body.constant(i8, 0)),
        .product => try product(c, body, schema, left, right, failure),
        .sum => try sum(c, body, schema, left, right, failure),
        .seq, .vector, .array => try sequence(c, body, schema, left, right, failure),
        .internal => return error.UnsupportedEqualitySchema,
    };
    try c.define(function, try body.ret(result));
    return function;
}
const Guard = struct {
    parent: *Branch,
    condition: *const a.Value(Boolean),
    yes: *Branch,
    no: *Branch,
    fn finish(g: @This(), value: *const a.Value(Boolean)) TypedError!*const a.Value(Boolean) {
        return g.parent.conditional(g.condition, try g.yes.ret(value), try g.no.ret(try g.no.constant(bool, false)));
    }
};
fn product(c: *a.Context, body: anytype, schema: S, left: V, right: V, failure: Fault) TypedError!*const a.Value(Boolean) {
    const allocator = a.interop.builder(c).allocator();
    var guards: std.ArrayList(Guard) = .empty;
    defer guards.deinit(allocator);
    const block = try body.branch();
    var work = block;
    const fields = try a.interop.fields(c, schema);
    for (0..fields.len()) |i| {
        const field = fields.at(i).?;
        const compared = try work.call(try declare(c, field.handle, failure), .{ .left = try a.interop.field(work, left, field.name), .right = try a.interop.field(work, right, field.name) });
        const yes = try work.branch();
        try guards.append(allocator, .{ .parent = work, .condition = compared, .yes = yes, .no = try work.branch() });
        work = yes;
    }
    var result = try work.constant(bool, true);
    var remaining = guards.items.len;
    while (remaining != 0) {
        remaining -= 1;
        result = try guards.items[remaining].finish(result);
    }
    return body.block(try block.ret(result));
}
fn sum(c: *a.Context, body: anytype, schema: S, left: V, right: V, failure: Fault) TypedError!*const a.Value(Boolean) {
    const same = try body.equal(try body.variantTag(left), try body.variantTag(right));
    const matching = try body.branch();
    const different = try body.branch();
    const fields = try a.interop.fields(c, schema);
    const entries = try a.interop.builder(c).allocator().alloc(a.interop.NamedEntry(.finished_case), fields.len());
    for (entries, 0..) |*entry, i| {
        const field = fields.at(i).?;
        const selected = try a.interop.caseOf(matching, left, field.name);
        const work = selected.body();
        const payload = try a.interop.variantPayload(work, right, field.name, failure);
        const equal = try work.call(try declare(c, field.handle, failure), .{ .left = selected.payload(), .right = payload });
        entry.* = .{ .name = field.name, .handle = a.interop.erase(try selected.ret(equal)) };
    }
    const cases = try a.interop.RuntimeNamed(.finished_case).init(c, entries);
    const matched = try a.interop.refineValue(matching, try matching.match(left, cases), try c.schema(bool));
    return body.conditional(same, try matching.ret(matched), try different.ret(try different.constant(bool, false)));
}
fn sequence(c: *a.Context, body: anytype, schema: S, left: V, right: V, failure: Fault) TypedError!*const a.Value(Boolean) {
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const loop_fn = try c.function("compare sequence elements", .{ .left = schema, .right = schema, .index = integer, .length = integer }, boolean, &.{});
    const loop = try c.body(loop_fn);
    const l = try loop.parameter("left");
    const r = try loop.parameter("right");
    const index = try loop.parameter("index");
    const length = try loop.parameter("length");
    const ended = try loop.branch();
    const active = try loop.branch();
    const lv = try active.sequenceGet(l, index);
    const l_none = try active.caseOf(lv, "none");
    const l_some = try active.caseOf(lv, "some");
    const rv = try l_some.body().sequenceGet(r, index);
    const r_none = try l_some.body().caseOf(rv, "none");
    const r_some = try l_some.body().caseOf(rv, "some");
    const working = r_some.body();
    const equal = try working.call(try declare(c, try a.interop.resultSchema(c, schema), failure), .{ .left = l_some.payload(), .right = r_some.payload() });
    const yes = try working.branch();
    const no = try working.branch();
    const next = try yes.call(loop_fn, .{ .left = l, .right = r, .index = try yes.checkedAdd(index, try yes.constant(u64, 1), failure), .length = length });
    const compared = try working.conditional(equal, try yes.ret(next), try no.ret(try no.constant(bool, false)));
    const right_match = try l_some.body().match(rv, .{ .none = try r_none.ret(try r_none.body().constant(bool, false)), .some = try r_some.ret(compared) });
    const left_match = try active.match(lv, .{ .none = try l_none.ret(try l_none.body().constant(bool, false)), .some = try l_some.ret(right_match) });
    try c.define(loop_fn, try loop.ret(try loop.conditional(try loop.equal(index, length), try ended.ret(try ended.constant(bool, true)), try active.ret(left_match))));
    const left_length = try body.sequenceLength(left);
    const right_length = try body.sequenceLength(right);
    const same = try body.branch();
    const different = try body.branch();
    const compared_all = try same.call(loop_fn, .{ .left = left, .right = right, .index = try same.constant(u64, 0), .length = left_length });
    return body.conditional(try body.equal(left_length, right_length), try same.ret(compared_all), try different.ret(try different.constant(bool, false)));
}

test "internal values reject at any recursive schema depth before declarations" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const region = b.region();
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = unit, .region = region } } });
    const recursive = try b.reserveSchema();
    const nested = try b.schema(.{ .product = &.{ recursive, cell } });
    try b.defineSchema(recursive, .{ .sum = &.{ unit, nested } });
    const before = b.functions.items.len;
    const c = try a.Context.init(&b);
    try std.testing.expectError(error.UnsupportedEqualitySchema, create(c, try a.interop.schema(c, recursive), try c.literalFailure(void, {})));
    try std.testing.expectEqual(before, b.functions.items.len);
}

test "typed comparison calls validate schemas, origins and raw import bounds" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const integer = try c.schema(u64);
    const function = try create(c, integer, try c.literalFailure(void, {}));
    const body = try c.body(try c.function("test body", .{}, try c.schema(bool), .{}));
    const left = try body.constant(u64, 13);
    const right = try body.constant(u64, 17);
    const compared = try body.call(function, .{ .left = left, .right = right });
    const term = try a.interop.computationId(c, try body.ret(compared));
    try std.testing.expect(b.terms.items[@intCast(term)] == .call);
    const bad = try c.body(try c.function("bad test body", .{}, try c.schema(bool), .{}));
    try std.testing.expectError(error.SchemaMismatch, bad.call(a.interop.erase(function), .{ .left = try bad.constant(u64, 13), .right = try bad.constant(bool, true) }));
    const foreign = try a.Context.init(&b);
    const imported = try foreign.body(try foreign.function("foreign test body", .{}, try foreign.schema(bool), .{}));
    try std.testing.expectError(error.InvalidSchema, a.interop.schema(foreign, b.schemas.items.len));
    try std.testing.expectError(error.ForeignHandle, imported.call(function, .{ .left = try imported.constant(u64, 13), .right = try imported.constant(u64, 17) }));
}

test "typed comparisons preserve named records and share equal failure literals" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const unit = try c.schema(void);
    const choice = try c.alternatives(.{ .empty = unit, .count = try c.schema(u64) });
    const schema = try c.record(.{ .label = try a.interop.schema(c, try b.schema(.{ .bounded_text = 16 })), .choice = choice });
    const function = try create(c, schema, try c.literalFailure(void, {}));
    const declarations = b.functions.items.len;
    try std.testing.expect(function == try create(c, schema, try c.literalFailure(void, {})));
    try std.testing.expectEqual(declarations, b.functions.items.len);
    const foreign = try a.Context.init(&b);
    try std.testing.expectError(error.ForeignHandle, create(foreign, schema, try foreign.literalFailure(void, {})));
    var compiled = try c.compile(std.testing.allocator, function, unit);
    defer compiled.deinit();
}

test "portable schema admission emits no code and rechecks recursive mutable graphs" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const leaf = try b.reserveSchema();
    try b.defineSchema(leaf, .u64);
    const tree = try b.reserveSchema();
    const node = try b.schema(.{ .product = &.{ leaf, tree } });
    try b.defineSchema(tree, .{ .sum = &.{ leaf, node } });
    try checkPortableSchema(&b, tree);
    try std.testing.expectEqual(@as(usize, 0), b.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), b.values.items.len);
    // Source admission observes the present graph; a previous successful check
    // is not a certificate for a subsequently changed source declaration.
    b.schemas.items[@intCast(leaf)] = .{ .internal = .{ .cell = .{ .element = tree, .region = b.region() } } };
    try std.testing.expectError(error.UnsupportedEqualitySchema, checkPortableSchema(&b, tree));
    try std.testing.expectError(error.InvalidReference, checkPortableSchema(&b, b.schemas.items.len));
    try std.testing.expectEqual(@as(usize, 0), b.functions.items.len);
}
