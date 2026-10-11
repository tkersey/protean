//! Checked adapters at Protean's raw source-record boundaries.
const a = @import("horos").authoring;
const Id = @import("horos").source.Id;

pub fn literal(c: *a.Context, value: Id) a.Error!*const a.Value(a.Dynamic) {
    const b = a.interop.builder(c);
    const item = b.constants.items[@intCast(try b.failureLiteral(value))];
    return a.interop.encodedLiteral(c, try a.interop.schema(c, item.schema), item.bytes);
}

/// Names are supplied by the source owner; every portable signature component
/// is reconstructed from the actual source record and checked before mapping.
pub fn callable(c: *a.Context, id: Id, parameters: anytype) @TypeOf(c.callable(parameters, @as(*const a.Schema(a.Dynamic), undefined), .{}, .{ .use = .reusable })) {
    const b = a.interop.builder(c);
    const imported = try a.interop.schema(c, id);
    const shape = b.schemas.items[@intCast(id)];
    if (shape != .internal or shape.internal != .computation) return error.InvalidCategory;
    const signature = shape.internal.computation;
    const effects = try b.allocator().alloc(*const a.Operation(a.Dynamic), signature.effects.len);
    for (signature.effects, effects) |effect, *target| target.* = try a.interop.operation(c, effect);
    const regions = try b.allocator().alloc(*const a.Region, signature.regions.len);
    for (signature.regions, regions) |region, *target| target.* = try a.interop.region(c, region);
    const captures = try b.allocator().alloc(*const a.Schema(a.Dynamic), signature.capture_bound.len);
    for (signature.capture_bound, captures) |capture, *target| target.* = try a.interop.schema(c, capture);
    const expected = try c.callable(parameters, try a.interop.schema(c, signature.result), effects, .{ .use = signature.use, .regions = regions, .captures = captures });
    return a.interop.mapSchema(c, imported, expected);
}
