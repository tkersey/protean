//! Shared authored inputs for independent workspace execution and controller traces.
const source = @import("horos").source;

pub fn retainedHandlers(b: *source.Builder, shallow: bool) !source.Module {
    const original = if (shallow) try source.examples.shallowResumptions(b) else try source.examples.successorState(b);
    // These fixtures supply every capability explicitly. Making their effects
    // internal permits source ingestion without changing attachment identity.
    for (b.effects.items) |*effect| effect.external = false;
    const function = b.functions.items[@intCast(original.entry)];
    const root = try b.declare(&.{try b.scalar(void)}, function.result, function.effects, function.regions);
    try b.define(root, try b.term(.{ .call = .{ .function = original.entry, .arguments = &.{} } }));
    return b.module(root, original.failure);
}

pub fn yieldingDisposal(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const u = try b.scalar(u64);
    const info = try @import("horos").library.cleanup.exitInfo(b, unit);
    const observed = try b.effect(.{ .identity = "example/disposal", .payload = info, .result = unit, .external = false });
    const body = try b.declare(&.{}, u, &.{}, &.{});
    try b.define(body, try b.term(.{ .yield_then = try b.pure(try b.constant(u64, 42)) }));
    const cleanup = try b.declare(&.{info}, unit, &.{observed}, &.{});
    const requested = try b.term(.{ .perform = .{ .effect = observed, .payload = try b.reference(b.parameter(cleanup, 0)) } });
    const finished = try b.term(.{ .yield_then = try b.pure(try b.constant(void, {})) });
    try b.define(cleanup, try b.term(.{ .yield_then = try b.bind(try b.variable(unit), requested, finished) }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = u } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = &.{observed} } } });
    const entry = try b.declare(&.{unit}, u, &.{observed}, &.{});
    try b.define(entry, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(cleanup, cleanup_type) } }));
    return b.module(entry, unit);
}

pub fn distinctAttachments(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const u = try b.scalar(u64);
    const effect = try b.effect(.{ .identity = "example/attachments", .payload = unit, .result = u, .external = false });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const returns = try b.declare(&.{u}, u, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    var handlers: [2]source.Id = undefined;
    for (&handlers, [_]u64{ 42, 99 }) |*handler, answer| {
        const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = effect, .input = u, .answer = u, .handled = &.{effect}, .effects = &.{effect}, .capture_bound = &.{ unit, u, cap }, .mode = .deep, .use = .linear } } });
        const clause = try b.declare(&.{ unit, token }, u, &.{effect}, &.{});
        try b.define(clause, try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 1)), .argument = try b.constant(u64, answer) } }));
        handler.* = try b.handler(.{ .mode = .deep, .input = u, .answer = u, .effects = &.{effect}, .return_function = returns, .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }} });
    }
    const body = try b.declare(&.{ cap, cap }, u, &.{effect}, &.{});
    try b.define(body, try b.term(.{ .perform = .{ .effect = effect, .capability = try b.reference(b.parameter(body, 1)), .payload = try b.constant(void, {}) } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ cap, cap }, .result = u, .effects = &.{effect} } } });
    const outer = try b.declare(&.{cap}, u, &.{effect}, &.{});
    try b.define(outer, try b.term(.{ .handle = .{ .handler = handlers[1], .body = try b.lambda(body, body_type), .arguments = &.{try b.reference(b.parameter(outer, 0))} } }));
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = u, .effects = &.{effect} } } });
    const main = try b.declare(&.{unit}, u, &.{effect}, &.{});
    try b.define(main, try b.term(.{ .handle = .{ .handler = handlers[0], .body = try b.lambda(outer, outer_type) } }));
    return b.module(main, unit);
}

pub fn binaryQuestion(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const ask = try b.effect(.{ .identity = "example/binary-question", .payload = unit, .result = boolean, .external = false });
    const entry = try b.declare(&.{unit}, boolean, &.{ask}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }));
    return b.module(entry, unit);
}

pub fn mutableAlternatives(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const prefix = try b.effect(.{ .identity = "example/prefix", .payload = u, .result = unit, .external = false });
    const ask = try b.effect(.{ .identity = "example/alternative", .payload = unit, .result = u, .external = false, .control_use = .multi });
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = u, .region = r } } });
    const main = try b.declare(&.{u}, u, &.{ prefix, ask }, &.{});
    const inside = try b.declare(&.{ region, u }, u, &.{ prefix, ask }, &.{r});
    const allocated = try b.variable(cell);
    const alias = try b.variable(cell);
    const answer = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const initial = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(b.parameter(inside, 1)), try b.constant(u64, 1) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const before = try b.primitive(u, .cell_get, &.{try b.reference(alias)}, 0);
    const sum = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ before, try b.reference(answer) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const write = try b.primitive(unit, .cell_set, &.{ try b.reference(allocated), sum }, 0);
    const result = try b.pure(try b.primitive(u, .cell_get, &.{try b.reference(alias)}, 0));
    const update = try b.bind(try b.variable(unit), try b.pure(write), result);
    const choice = try b.bind(answer, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }), update);
    const emitted = try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = prefix, .payload = initial } }), choice);
    const aliased = try b.bind(alias, try b.pure(try b.reference(allocated)), emitted);
    try b.define(inside, try b.bind(allocated, try b.pure(try b.primitive(cell, .cell_new, &.{ try b.reference(b.parameter(inside, 0)), initial }, 0)), aliased));
    const body = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ region, u }, .result = u, .effects = &.{ prefix, ask }, .regions = &.{r} } } });
    try b.define(main, try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(inside, body), .arguments = &.{try b.reference(b.parameter(main, 0))} } }));
    return b.module(main, unit);
}

pub fn exclusiveAlternative(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const resource = try b.resource(u);
    const ask = try b.effect(.{ .identity = "example/exclusive", .payload = unit, .result = unit, .external = false, .control_use = .multi });
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const consume = try b.declare(&.{resource}, u, &.{}, &.{});
    try b.resourceAuthority(resource, &.{factory}, &.{consume});
    try b.define(factory, try b.pure(try b.primitive(resource, .resource_pack, &.{try b.constant(u64, 42)}, 0)));
    try b.define(consume, try b.pure(try b.primitive(u, .resource_unpack, &.{try b.reference(b.parameter(consume, 0))}, 0)));
    const main = try b.declare(&.{unit}, u, &.{ask}, &.{});
    const owned = try b.variable(resource);
    const result = try b.term(.{ .call = .{ .function = consume, .arguments = &.{try b.reference(owned)} } });
    const pause = try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }), result);
    try b.define(main, try b.bind(owned, try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } }), pause));
    return b.module(main, unit);
}

pub fn gcd(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ u, u } });
    const recur = try b.declare(&.{ u, u }, u, &.{}, &.{});
    const entry = try b.declare(&.{pair}, u, &.{}, &.{});
    const x = try b.reference(b.parameter(recur, 0));
    const y = try b.reference(b.parameter(recur, 1));
    const zero = try b.constant(u64, 0);
    const condition = try b.primitive(try b.scalar(bool), .equal, &.{ y, zero }, 0);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const rem = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_rem, .operands = &.{ x, y }, .failures = &.{
        .{ .kind = .arithmetic_overflow, .value = fault }, .{ .kind = .division_by_zero, .value = fault },
    } } } });
    const done = try b.pure(x);
    const again = try b.term(.{ .call = .{ .function = recur, .arguments = &.{ y, rem } } });
    try b.define(recur, try b.term(.{ .conditional = .{ .condition = condition, .when_true = done, .when_false = again } }));
    const left = try b.variable(u);
    const right = try b.variable(u);
    const run = try b.term(.{ .call = .{ .function = recur, .arguments = &.{ try b.reference(left), try b.reference(right) } } });
    try b.define(entry, try b.term(.{ .unpack_product = .{ .value = try b.reference(b.parameter(entry, 0)), .variables = &.{ left, right }, .body = run } }));
    return b.module(entry, unit);
}

pub fn listLength(b: *source.Builder) !source.Module {
    return listLengthWithYields(b, true);
}

pub fn listLengthWithYields(b: *source.Builder, yields: bool) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const list = try b.reserveSchema();
    const cons = try b.schema(.{ .product = &.{ u, list } });
    try b.defineSchema(list, .{ .sum = &.{ unit, cons } });
    const recurse = try b.declare(&.{list}, u, &.{}, &.{});
    const empty = try b.variable(unit);
    const nonempty = try b.variable(cons);
    const head = try b.variable(u);
    const tail = try b.variable(list);
    const length = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const incremented = try b.value(.{ .schema = u, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ try b.reference(length), try b.constant(u64, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
    } } });
    const call = try b.term(.{ .call = .{ .function = recurse, .arguments = &.{try b.reference(tail)} } });
    const joined = try b.bind(length, call, try b.pure(incremented));
    const yielded = if (yields) try b.term(.{ .yield_then = joined }) else joined;
    const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(nonempty), .variables = &.{ head, tail }, .body = yielded } });
    const done = try b.pure(try b.constant(u64, 0));
    try b.define(recurse, try b.term(.{ .match_sum = .{ .value = try b.reference(b.parameter(recurse, 0)), .cases = &.{
        .{ .variable = empty, .body = done }, .{ .variable = nonempty, .body = unpack },
    } } }));
    return b.module(recurse, unit);
}

pub fn alternatives(b: *source.Builder, multi: bool) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const emitted = try b.effect(.{ .identity = "example/prefix", .payload = u, .result = unit, .external = false });
    const ask = try b.effect(.{ .identity = "example/alternative", .payload = unit, .result = u, .external = false, .control_use = if (multi) .multi else .linear });
    const entry = try b.declare(&.{u}, u, &.{ emitted, ask }, &.{});
    const prefix_value = try b.variable(u);
    const ignored = try b.variable(unit);
    const answer = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const prefix = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(b.parameter(entry, 0)), try b.constant(u64, 1) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const result = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(prefix_value), try b.reference(answer) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const branch = try b.bind(answer, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }), try b.pure(result));
    const emit = try b.bind(ignored, try b.term(.{ .perform = .{ .effect = emitted, .payload = try b.reference(prefix_value) } }), branch);
    try b.define(entry, try b.bind(prefix_value, try b.pure(prefix), emit));
    return b.module(entry, unit);
}
