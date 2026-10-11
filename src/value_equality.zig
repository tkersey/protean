//! Structural equality for portable values, emitted through typed Horos code.
const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const a = horos.authoring;
const Id = source.Id;
pub const Error = source.Error || error{UnsupportedEqualitySchema};
pub const TypedError = a.Error || error{UnsupportedEqualitySchema};

/// Construct a pure comparison, retaining named schemas and recursive sharing.
pub fn create(c: *a.Context, schema: *const a.Schema, failure: *const a.FailureLiteral) TypedError!*const a.Function {
    const b = a.interop.builder(c);
    const id = try a.interop.schemaId(c, schema);
    _ = try a.interop.failureLiteralId(c, failure);
    try checkPortableSchema(b, id);
    return declare(c, schema, failure);
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

fn declare(c: *a.Context, schema: *const a.Schema, failure: *const a.FailureLiteral) TypedError!*const a.Function {
    const b = a.interop.builder(c);
    const id = try a.interop.schemaId(c, schema);
    const cached = try b.specialization(Id, "agent.value-equality/typed-v1", .{ @intFromPtr(c), @intFromPtr(schema), try a.interop.failureLiteralId(c, failure) });
    if (cached.cached) |function| return a.interop.declaredFunction(c, function);
    const function = try c.function("portable equality", &.{ .{ .name = "left", .schema = schema }, .{ .name = "right", .schema = schema } }, try c.scalar(bool), &.{});
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
    parent: *a.Body,
    condition: *const a.Value,
    yes: *a.Body,
    no: *a.Body,
    fn finish(g: @This(), value: *const a.Value) TypedError!*const a.Value {
        return g.parent.conditional(g.condition, try g.yes.ret(value), try g.no.ret(try g.no.constant(bool, false)));
    }
};
fn product(c: *a.Context, body: *a.Body, schema: *const a.Schema, left: *const a.Value, right: *const a.Value, failure: *const a.FailureLiteral) TypedError!*const a.Value {
    const allocator = a.interop.builder(c).allocator();
    var guards: std.ArrayList(Guard) = .empty;
    defer guards.deinit(allocator);
    var work = body;
    for (schema.fields()) |field| {
        const compared = try work.call(try declare(c, field.schema, failure), &.{ .{ .name = "left", .value = try work.field(left, field.name) }, .{ .name = "right", .value = try work.field(right, field.name) } });
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
    return result;
}
fn sum(c: *a.Context, body: *a.Body, schema: *const a.Schema, left: *const a.Value, right: *const a.Value, failure: *const a.FailureLiteral) TypedError!*const a.Value {
    const same = try body.equal(try body.variantTag(left), try body.variantTag(right));
    const matching = try body.branch();
    const different = try body.branch();
    const cases = try a.interop.builder(c).allocator().alloc(*const a.FinishedCase, schema.fields().len);
    for (schema.fields(), cases) |field, *finished| {
        const selected = try matching.caseOf(left, field.name);
        const work = selected.body();
        const payload = try work.variantPayload(right, field.name, failure);
        const equal = try work.call(try declare(c, field.schema, failure), &.{ .{ .name = "left", .value = selected.payload() }, .{ .name = "right", .value = payload } });
        finished.* = try selected.ret(equal);
    }
    return body.conditional(same, try matching.ret(try matching.match(left, cases)), try different.ret(try different.constant(bool, false)));
}
fn sequence(c: *a.Context, body: *a.Body, schema: *const a.Schema, left: *const a.Value, right: *const a.Value, failure: *const a.FailureLiteral) TypedError!*const a.Value {
    const integer = try c.scalar(u64);
    const boolean = try c.scalar(bool);
    const loop_fn = try c.function("compare sequence elements", &.{ .{ .name = "left", .schema = schema }, .{ .name = "right", .schema = schema }, .{ .name = "index", .schema = integer }, .{ .name = "length", .schema = integer } }, boolean, &.{});
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
    const equal = try working.call(try declare(c, schema.resultSchema() orelse return error.InvalidSchema, failure), &.{ .{ .name = "left", .value = l_some.payload() }, .{ .name = "right", .value = r_some.payload() } });
    const yes = try working.branch();
    const no = try working.branch();
    const next = try yes.call(loop_fn, &.{ .{ .name = "left", .value = l }, .{ .name = "right", .value = r }, .{ .name = "index", .value = try yes.checkedAdd(index, try yes.constant(u64, 1), failure) }, .{ .name = "length", .value = length } });
    const compared = try working.conditional(equal, try yes.ret(next), try no.ret(try no.constant(bool, false)));
    const right_match = try l_some.body().match(rv, &.{ try r_none.ret(try r_none.body().constant(bool, false)), try r_some.ret(compared) });
    const left_match = try active.match(lv, &.{ try l_none.ret(try l_none.body().constant(bool, false)), try l_some.ret(right_match) });
    try c.define(loop_fn, try loop.ret(try loop.conditional(try loop.equal(index, length), try ended.ret(try ended.constant(bool, true)), try active.ret(left_match))));
    const left_length = try body.sequenceLength(left);
    const right_length = try body.sequenceLength(right);
    const same = try body.branch();
    const different = try body.branch();
    const compared_all = try same.call(loop_fn, &.{ .{ .name = "left", .value = left }, .{ .name = "right", .value = right }, .{ .name = "index", .value = try same.constant(u64, 0) }, .{ .name = "length", .value = left_length } });
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
    const integer = try c.scalar(u64);
    const function = try create(c, integer, try c.literalFailure(void, {}));
    const body = try a.interop.scope(c);
    const left = try body.constant(u64, 13);
    const right = try body.constant(u64, 17);
    const compared = try body.call(function, &.{ .{ .name = "left", .value = left }, .{ .name = "right", .value = right } });
    const term = try a.interop.computationId(c, try body.ret(compared));
    try std.testing.expect(b.terms.items[@intCast(term)] == .call);
    const bad = try a.interop.scope(c);
    try std.testing.expectError(error.SchemaMismatch, bad.call(function, &.{ .{ .name = "left", .value = try bad.constant(u64, 13) }, .{ .name = "right", .value = try bad.constant(bool, true) } }));
    const foreign = try a.Context.init(&b);
    const imported = try a.interop.scope(foreign);
    try std.testing.expectError(error.InvalidReference, a.interop.adoptValue(imported, b.values.items.len, try foreign.scalar(u64)));
    try std.testing.expectError(error.ForeignHandle, imported.call(function, &.{ .{ .name = "left", .value = try imported.constant(u64, 13) }, .{ .name = "right", .value = try imported.constant(u64, 17) } }));
}

test "typed comparisons preserve named records and share equal failure literals" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const unit = try c.scalar(void);
    const choice = try c.alternatives(&.{ .{ .name = "empty", .schema = unit }, .{ .name = "count", .schema = try c.scalar(u64) } });
    const schema = try c.record(&.{ .{ .name = "label", .schema = try a.interop.schema(c, try b.schema(.{ .bounded_text = 16 })) }, .{ .name = "choice", .schema = choice } });
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
