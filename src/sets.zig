//! Descriptor-sized portable sets. Their cardinality is the declared catalog
//! size, independent of any scalar mask width or Protean lifetime limit.
const horos = @import("horos");
const source = horos.source;
const Id = source.Id;

pub const Set = struct { schema: Id, length: usize };

pub fn define(b: *source.Builder, length: usize) source.Error!Set {
    return .{
        .schema = try b.schema(.{ .array = .{
            .element = try b.scalar(bool),
            .length = length,
        } }),
        .length = length,
    };
}

pub fn literal(b: *source.Builder, set: Set, members: []const bool) source.Error!Id {
    try checkSet(b, set);
    if (members.len != set.length) return error.TypeMismatch;
    const bytes = try b.allocator().alloc(u8, members.len);
    for (members, bytes) |member_value, *byte| byte.* = @intFromBool(member_value);
    return b.literal(.{ .schema = set.schema, .bytes = bytes });
}

pub fn filled(b: *source.Builder, set: Set, available: bool) source.Error!Id {
    try checkSet(b, set);
    const bytes = try b.allocator().alloc(u8, set.length);
    @memset(bytes, @intFromBool(available));
    return b.literal(.{ .schema = set.schema, .bytes = bytes });
}

/// Static catalog indexes reject during authoring instead of truncating a mask.
pub fn member(b: *source.Builder, set: Set, value: Id, index: usize) source.Error!Id {
    if (index >= set.length) return error.InvalidReference;
    return contains(b, set, value, try b.constant(u64, index));
}

/// Dynamic indexes are ordinary authored control. Out-of-catalog is unavailable.
pub fn contains(b: *source.Builder, set: Set, value: Id, index: Id) source.Error!Id {
    try checkValue(b, set, value);
    const boolean = try b.scalar(bool);
    const unit = try b.scalar(void);
    const optional = try b.schema(.{ .sum = &.{ unit, boolean } });
    const selected = try b.primitive(optional, .sequence_get, &.{ value, index }, 0);
    const absent = try b.variable(unit);
    const present = try b.variable(boolean);
    return b.term(.{ .match_sum = .{ .value = selected, .cases = &.{
        .{ .variable = absent, .body = try b.pure(try b.constant(bool, false)) },
        .{ .variable = present, .body = try b.pure(try b.reference(present)) },
    } } });
}

/// Narrowing can never enable a member absent from either input permission set.
pub fn intersection(b: *source.Builder, set: Set, outer: Id, restriction: Id) source.Error!Id {
    try checkValue(b, set, outer);
    try checkValue(b, set, restriction);
    return b.term(.{ .call = .{
        .function = try intersectionFunction(b, set),
        .arguments = &.{ outer, restriction },
    } });
}

fn intersectionFunction(b: *source.Builder, set: Set) source.Error!Id {
    const instance = try b.specialization(Id, "agent.set.intersection/v1", set);
    if (instance.cached) |cached| return cached;
    const function = try b.declare(&.{ set.schema, set.schema }, set.schema, &.{}, &.{});
    const outer = try b.reference(b.parameter(function, 0));
    const restriction = try b.reference(b.parameter(function, 1));
    const items = try b.allocator().alloc(Id, set.length);
    const left = try b.allocator().alloc(Id, set.length);
    const right = try b.allocator().alloc(Id, set.length);
    const boolean = try b.scalar(bool);
    const denied = try b.constant(bool, false);
    for (items, 0..) |*item, index| {
        left[index] = try b.variable(boolean);
        right[index] = try b.variable(boolean);
        item.* = try b.primitive(boolean, .select, &.{
            try b.reference(left[index]), try b.reference(right[index]), denied,
        }, 0);
    }
    var body = try b.pure(try b.primitive(set.schema, .sequence, items, 0));
    var index = set.length;
    while (index != 0) {
        index -= 1;
        body = try b.bind(right[index], try member(b, set, restriction, index), body);
        body = try b.bind(left[index], try member(b, set, outer, index), body);
    }
    try b.define(function, body);
    return instance.finish(b, function);
}

fn checkSet(b: *source.Builder, set: Set) source.Error!void {
    if (set.schema >= b.schemas.items.len) return error.InvalidReference;
    const shape = b.schemas.items[@intCast(set.schema)];
    if (shape != .array or shape.array.length != set.length) return error.TypeMismatch;
    if (shape.array.element >= b.schemas.items.len) return error.InvalidReference;
    if (b.schemas.items[@intCast(shape.array.element)] != .boolean) return error.TypeMismatch;
}

fn checkValue(b: *source.Builder, set: Set, value: Id) source.Error!void {
    try checkSet(b, set);
    if (value >= b.values.items.len) return error.InvalidReference;
    if (b.values.items[@intCast(value)].schema != set.schema) return error.TypeMismatch;
}
