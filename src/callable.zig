//! A static function identity may select its own ordinary computation schema.
//! This separates higher-order origins without changing runtime instructions,
//! adding an evaluator, or asserting that the function's effects are safe.
const source = @import("horos").source;
const p = @import("horos").data.program;

pub const Definition = struct { function: p.Id, schema: p.Id };

/// Repeated installation of the same function/signature shares one declaration.
/// Horos checks the signature's parameters, row, captures, and ownership
/// against actual source during compilation. Protean independently inspects code.
/// The returned schema is nominal within this module, using public source terms.
pub fn define(
    builder: *source.Builder,
    function: p.Id,
    signature: p.ComputationType,
) source.Error!Definition {
    if (function >= builder.functions.items.len) return error.InvalidReference;
    const instance = try builder.specialization(Definition, "agent.callable/v1", .{
        function, signature,
    });
    if (instance.cached) |cached| return cached;
    const schema = try builder.reserveSchema();
    try builder.defineSchema(schema, .{ .internal = .{ .computation = signature } });
    return instance.finish(builder, .{ .function = function, .schema = schema });
}

/// Produces an ordinary Horos lambda value. Reusing a schema for unrelated
/// code does not confer admission: the final source-origin scan still checks it.
pub fn value(builder: *source.Builder, definition: Definition) source.Error!p.Id {
    if (definition.function >= builder.functions.items.len or
        definition.schema >= builder.schemas.items.len) return error.InvalidReference;
    const schema = builder.schemas.items[@intCast(definition.schema)];
    if (schema != .internal or schema.internal != .computation) return error.TypeMismatch;
    return builder.lambda(definition.function, definition.schema);
}
