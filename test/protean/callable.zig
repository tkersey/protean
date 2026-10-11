const std = @import("std");
const bnd = @import("horos");
const protean = @import("protean");
const admission = protean.admission;
const callable = protean.callable;
const Id = bnd.source.Id;
const B = bnd.source.Builder;

pub const Representation = enum { interned, static_code, unsafe_reuse, unsafe_code };

pub fn build(b: *B, registry: *admission.Registry, representation: Representation, count: usize) !bnd.source.Module {
    const unit = try b.scalar(void);
    const signature: bnd.data.program.ComputationType = .{ .parameters = &.{}, .result = unit };
    const safe = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(safe, try b.pure(try b.constant(void, {})));
    const safe_code: callable.Definition = if (representation == .interned) .{
        .function = safe,
        .schema = try b.schema(.{ .internal = .{ .computation = signature } }),
    } else try callable.define(b, safe, signature);

    // This local effect is legal outside speculation, but not admitted inside.
    const u = try b.effect(.{ .identity = "probe/outside-only", .payload = unit, .result = unit, .external = false });
    const cap = try b.schema(.{ .internal = .{ .capability = u } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = u, .input = unit, .answer = unit, .handled = &.{u}, .mode = .deep, .use = .linear } } });
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, unit, &.{}, &.{});
    try b.define(clause, try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 1)), .argument = try b.constant(void, {}) } }));
    const local = try b.handler(.{ .mode = .deep, .input = unit, .answer = unit, .return_function = returns, .clauses = &.{.{ .effect = u, .function = clause, .resumption = token }} });
    const local_body = try b.declare(&.{cap}, unit, &.{u}, &.{});
    try b.define(local_body, try b.term(.{ .perform = .{ .effect = u, .capability = try b.reference(b.parameter(local_body, 0)), .payload = try b.constant(void, {}) } }));
    const local_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = unit, .effects = &.{u} } } });
    const outside = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(outside, try b.term(.{ .handle = .{ .handler = local, .body = try b.lambda(local_body, local_type) } }));
    const outside_code: callable.Definition = switch (representation) {
        .interned, .unsafe_reuse => .{ .function = outside, .schema = safe_code.schema },
        .static_code, .unsafe_code => try callable.define(b, outside, signature),
    };
    const supplied = switch (representation) {
        .unsafe_reuse, .unsafe_code => outside_code,
        else => safe_code,
    };
    const callback = supplied.schema;

    // One reusable higher-order helper receives the safe callback as a VALUE.
    const typed = bnd.authoring;
    const author = try typed.Context.init(b);
    const family = try bnd.library.choice.family(author, "probe/choice");
    const choice = .{ .effect = try typed.interop.operationId(author, family.effect()), .capability = try typed.interop.schemaId(author, family.capability()) };
    try registry.classify(choice.effect, .internal);
    const interpreted = try bnd.library.choice.all(author, family, try author.scalar(void), .{ .captures = .{ .continuation = &.{ try author.scalar(void), try typed.interop.schema(author, callback), family.capability() } }, .residual = &.{} });
    const all = .{ .handler = try typed.interop.handlerId(author, interpreted.handler), .answer = try typed.interop.schemaId(author, interpreted.answer) };
    const body = try b.declare(&.{ choice.capability, callback }, unit, &.{choice.effect}, &.{});
    const decision = try b.variable(try b.scalar(bool));
    try b.define(body, try b.bind(decision, try b.term(.{ .perform = .{ .effect = choice.effect, .capability = try b.reference(b.parameter(body, 0)), .payload = try b.constant(void, {}) } }), try b.term(.{ .apply = .{ .computation = try b.reference(b.parameter(body, 1)), .arguments = &.{} } })));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ choice.capability, callback }, .result = unit, .effects = &.{choice.effect} } } });
    const root = try b.declare(&.{}, unit, &.{}, &.{});
    // The unrelated callback runs only AFTER all speculative work returns.
    var tail = try b.term(.{ .apply = .{ .computation = try callable.value(b, outside_code), .arguments = &.{} } });
    for (0..count) |_| {
        const result = try b.variable(all.answer);
        const evaluate = try b.term(.{ .handle = .{
            .handler = all.handler,
            .body = try b.lambda(body, body_type),
            .arguments = &.{try callable.value(b, supplied)},
        } });
        tail = try b.bind(result, evaluate, tail);
    }
    try b.define(root, tail);
    return b.module(root, unit);
}

test "static-code identity does not assert effect safety or bless schema reuse" {
    for ([_]Representation{ .unsafe_reuse, .unsafe_code }) |representation| {
        const a = std.testing.allocator;
        var b = B.init(a);
        defer b.deinit();
        var registry = admission.Registry.init(a);
        defer registry.deinit();
        const module = try build(&b, &registry, representation, 1);
        var compiled = try bnd.program.compile(a, module);
        defer compiled.deinit();
        try std.testing.expectError(error.SpeculativeEffect, admission.verify(a, module, &registry));
    }
}

test "1 8 and 64 callable installations share schema and executable body" {
    for ([_]usize{ 1, 8, 64 }) |count| {
        var b = B.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const function = try b.declare(&.{}, unit, &.{}, &.{});
        try b.define(function, try b.pure(try b.constant(void, {})));
        const signature: bnd.data.program.ComputationType = .{
            .parameters = &.{},
            .result = unit,
        };
        const declaration = try callable.define(&b, function, signature);
        const schemas = b.schemas.items.len;
        const functions = b.functions.items.len;
        for (0..count) |_| {
            const again = try callable.define(&b, function, signature);
            try std.testing.expectEqual(declaration, again);
            _ = try callable.value(&b, again);
        }
        try std.testing.expectEqual(schemas, b.schemas.items.len);
        try std.testing.expectEqual(functions, b.functions.items.len);
    }
}
