//! Dynamic retained control and aliased cells inside a multi-shot delimiter.
//! The cleanup belongs to its outer protection scope and cannot be cloned.
const source = @import("horos").source;
const Id = @import("horos_data").program.Id;

test "movable runtime source admits dynamic retained control and outer cleanup" {
    const std = @import("std");
    var builder = source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const module = try build(&builder);
    // The workspace exposes these three operations through its typed bridge.
    // The standalone admission test uses ordinary external effect boundaries.
    for (builder.effects.items[0..3]) |*effect| effect.external = true;
    var diagnostic: source.Diagnostic = .{};
    var compiled = source.lowerObserved(std.testing.allocator, module, .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("mobility source: {any}\n", .{diagnostic});
        return err;
    };
    defer compiled.deinit();
}

fn binary(b: *source.Builder, opcode: @FieldType(@import("horos_data").activation.Instruction, "opcode"), result: Id, left: Id, right: Id) !Id {
    return b.value(.{ .schema = result, .expression = .{ .primitive = .{
        .opcode = opcode,
        .operands = &.{ left, right },
        .failures = if (opcode == .equal) &.{} else &.{.{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(try b.constant(void, {})) }},
    } } });
}
fn ref(b: *source.Builder, function: Id, index: usize) !Id {
    return b.reference(b.parameter(function, index));
}
fn call(b: *source.Builder, function: Id, arguments: []const Id) !Id {
    return b.term(.{ .call = .{ .function = function, .arguments = arguments } });
}

pub fn build(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const input = try b.schema(.{ .product = &.{ u, u } });
    const command = try b.schema(.{ .sum = &.{ u, unit } });
    const exit_info = try @import("horos").library.cleanup.exitInfo(b, unit);
    const prefix = try b.effect(.{ .identity = "mobility/prefix", .payload = u, .result = unit, .external = false });
    const select = try b.effect(.{ .identity = "mobility/alternative", .payload = u, .result = command, .external = false });
    const cleanup_effect = try b.effect(.{ .identity = "mobility/cleanup", .payload = exit_info, .result = unit, .external = false });
    const ask = try b.effect(.{ .identity = "mobility/capture", .payload = unit, .result = u, .control_use = .multi, .external = false });
    const cap = try b.schema(.{ .internal = .{ .capability = ask } });
    const region = b.region();
    const rtype = try b.schema(.{ .internal = .{ .region = region } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = u, .region = region } } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = ask,
        .input = u,
        .answer = u,
        .effects = &.{select},
        .owned_regions = &.{region},
        .handled = &.{ask},
        .mode = .deep,
        .use = .multi,
        .capture_bound = &.{ u, cell, rtype },
    } } });
    const zero = try b.constant(u64, 0);
    const one = try b.constant(u64, 1);
    const nothing = try b.constant(void, {});
    const main = try b.declare(&.{input}, u, &.{ prefix, select, cleanup_effect }, &.{});
    const count = try b.variable(u);
    const seed = try b.variable(u);
    const common = try b.variable(u);
    const prefix_loop = try b.declare(&.{ u, u }, u, &.{}, &.{});
    try b.define(prefix_loop, try b.term(.{ .conditional = .{
        .condition = try binary(b, .equal, boolean, try ref(b, prefix_loop, 0), zero),
        .when_true = try b.pure(try ref(b, prefix_loop, 1)),
        .when_false = try call(b, prefix_loop, &.{ try binary(b, .integer_sub, u, try ref(b, prefix_loop, 0), one), try binary(b, .integer_add, u, try ref(b, prefix_loop, 1), one) }),
    } }));
    const recurse = try b.declare(&.{ u, cap, cell, cell }, u, &.{ask}, &.{region});
    const answer = try b.variable(u);
    const updated = try binary(b, .integer_add, u, try b.primitive(u, .cell_get, &.{try ref(b, recurse, 2)}, 0), try b.reference(answer));
    const leaf = try b.bind(answer, try b.term(.{ .perform = .{ .effect = ask, .capability = try ref(b, recurse, 1), .payload = nothing } }), try b.bind(try b.variable(unit), try b.pure(try b.primitive(unit, .cell_set, &.{ try ref(b, recurse, 2), updated }, 0)), try b.pure(try b.primitive(u, .cell_get, &.{try ref(b, recurse, 3)}, 0))));
    const returned = try b.variable(u);
    const non_tail = try b.bind(returned, try call(b, recurse, &.{ try binary(b, .integer_sub, u, try ref(b, recurse, 0), one), try ref(b, recurse, 1), try ref(b, recurse, 2), try ref(b, recurse, 3) }), try b.pure(try binary(b, .integer_add, u, try b.reference(returned), one)));
    try b.define(recurse, try b.term(.{ .conditional = .{ .condition = try binary(b, .equal, boolean, try ref(b, recurse, 0), zero), .when_true = leaf, .when_false = non_tail } }));
    const body = try b.declare(&.{cap}, u, &.{ask}, &.{});
    const scoped = try b.declare(&.{rtype}, u, &.{ask}, &.{region});
    const owned = try b.variable(cell);
    const alias = try b.variable(cell);
    try b.define(scoped, try b.bind(owned, try b.pure(try b.primitive(cell, .cell_new, &.{ try ref(b, scoped, 0), try b.reference(common) }, 0)), try b.bind(alias, try b.pure(try b.reference(owned)), try call(b, recurse, &.{ try b.reference(count), try ref(b, body, 0), try b.reference(owned), try b.reference(alias) }))));
    const scoped_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{rtype}, .result = u, .effects = &.{ask}, .capture_bound = &.{ u, cap }, .regions = &.{region} } } });
    try b.define(body, try b.term(.{ .with_region = .{ .region = region, .body = try b.lambda(scoped, scoped_type) } }));
    const returns = try b.declare(&.{u}, u, &.{}, &.{});
    try b.define(returns, try b.pure(try ref(b, returns, 0)));
    const choose = try b.declare(&.{ token, u }, u, &.{select}, &.{});
    const choice = try b.variable(command);
    const selected = try b.variable(u);
    const result = try b.variable(u);
    const branches = try b.term(.{ .match_sum = .{ .value = try b.reference(choice), .cases = &.{
        .{ .variable = selected, .body = try b.bind(result, try b.term(.{ .resume_value = .{ .resumption = try ref(b, choose, 0), .argument = try b.reference(selected) } }), try call(b, choose, &.{ try ref(b, choose, 0), try b.reference(result) })) },
        .{ .variable = try b.variable(unit), .body = try b.pure(try ref(b, choose, 1)) },
    } } });
    try b.define(choose, try b.bind(choice, try b.term(.{ .perform = .{ .effect = select, .payload = try ref(b, choose, 1) } }), branches));
    const clause = try b.declare(&.{ unit, token }, u, &.{select}, &.{});
    try b.define(clause, try call(b, choose, &.{ try ref(b, clause, 1), zero }));
    const handler = try b.handler(.{ .mode = .deep, .input = u, .answer = u, .effects = &.{select}, .return_function = returns, .clauses = &.{.{ .effect = ask, .function = clause, .resumption = token }} });
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = u, .effects = &.{ask}, .capture_bound = &.{u} } } });
    const protected = try b.declare(&.{}, u, &.{ prefix, select }, &.{});
    const handled = try b.term(.{ .handle = .{ .handler = handler, .body = try b.lambda(body, body_type) } });
    try b.define(protected, try b.bind(common, try call(b, prefix_loop, &.{ try b.reference(count), try b.reference(seed) }), try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = prefix, .payload = try b.reference(common) } }), handled)));
    const cleanup = try b.declare(&.{exit_info}, unit, &.{cleanup_effect}, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{ .effect = cleanup_effect, .payload = try ref(b, cleanup, 0) } }));
    const protected_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = u, .effects = &.{ prefix, select }, .capture_bound = &.{u} } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{exit_info}, .result = unit, .effects = &.{cleanup_effect} } } });
    try b.define(main, try b.term(.{ .unpack_product = .{ .value = try ref(b, main, 0), .variables = &.{ count, seed }, .body = try b.term(.{ .protect = .{ .body = try b.lambda(protected, protected_type), .cleanup = try b.lambda(cleanup, cleanup_type) } }) } }));
    return b.module(main, unit);
}
