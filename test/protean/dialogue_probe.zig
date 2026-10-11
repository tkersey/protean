//! A consumer owns all control. Protean only constructs ordinary dialogue terms.
const std = @import("std");
const horos = @import("horos");
const dialogue = horos.library.generator;
const interaction = @import("interaction");
const bsrc = horos.source;
const Builder = bsrc.Builder;
const Id = bsrc.Id;

pub const Mode = enum {
    twice,
    dispose_owned,
    exchange,
    deep_exchange,
    wide_exchange,
    yield_once,
    double_use,
    borrowed_escape,
};

pub fn build(b: *Builder, mode: Mode) !bsrc.Module {
    if (mode == .yield_once) {
        const unit = try b.scalar(void);
        const integer = try b.scalar(u64);
        const entry = try b.declare(&.{}, integer, &.{}, &.{});
        try b.define(entry, try b.term(.{ .yield_then = try b.pure(try b.constant(u64, 42)) }));
        return b.module(entry, unit);
    }
    if (mode == .exchange) return typedExchange(b);
    if (mode == .deep_exchange or mode == .wide_exchange) return portableExchange(b, mode);
    if (mode == .borrowed_escape) return borrowedEscape(b);
    if (mode == .dispose_owned) return disposal(b);
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const delayed = try b.effect(.{
        .identity = "agent.probe.dialogue.delay.v1",
        .payload = integer,
        .result = integer,
    });
    const d = try dialogue.defineExchange(b, "agent.probe.dialogue.typed.v1", integer, integer, integer, &.{integer}, &.{}, &.{}, .{ .effects = &.{} });
    const body = try b.declare(&.{d.capability}, integer, &.{d.effect}, &.{});
    const first = try b.variable(integer);
    const second = try b.variable(integer);
    const cap = try b.reference(b.parameter(body, 0));
    const offered = try arithmetic(b, .integer_add, try b.constant(u64, 10), try b.reference(first));
    const result = try arithmetic(b, .integer_add, offered, try b.reference(second));
    try b.define(body, try b.bind(first, try dialogue.offer(b, d, cap, try b.constant(u64, 10)), try b.bind(second, try dialogue.offer(b, d, cap, offered), try b.pure(result))));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.capability},
        .result = integer,
        .effects = &.{d.effect},
    } } });
    const entry = try b.declare(&.{}, integer, &.{delayed}, &.{});
    const started = try dialogue.start(b, d, try b.lambda(body, body_type), &.{});
    const ended = try finish(b, d);
    const second_step = try awaitingStep(b, d, try b.constant(u64, 7), ended, false);
    const first_step = try delayedStep(b, d, delayed, second_step, mode == .double_use);
    try b.define(entry, try consumeAnswer(b, d, started, first_step));
    return b.module(entry, unit);
}

fn portableExchange(b: *Builder, mode: Mode) !bsrc.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u8);
    const list = if (mode == .deep_exchange) blk: {
        const list = try b.reserveSchema();
        const pair = try b.schema(.{ .product = &.{ integer, list } });
        try b.defineSchema(list, .{ .sum = &.{ unit, pair } });
        break :blk list;
    } else try b.schema(.{ .seq = unit });
    const text = try b.schema(.text);
    const contract = try interaction.define(b, .{
        .name = if (mode == .deep_exchange) "probe.deep" else "probe.wide",
        .channel = text,
        .purpose = text,
        .presentation = unit,
        .outgoing = list,
        .input = unit,
    });
    const entry = try b.declare(&.{list}, unit, &.{contract.effect}, &.{});
    const response = try b.variable(contract.reply);
    const request = try interaction.exchange(b, contract, .{
        .channel = try b.literal(.{ .schema = text, .bytes = "\x05human" }),
        .purpose = try b.literal(.{ .schema = text, .bytes = "\x07message" }),
        .presentation = try b.constant(void, {}),
        .outgoing = try b.reference(b.parameter(entry, 0)),
    });
    // The second occurrence exercises deep rendering after resume as well.
    try b.define(entry, try b.bind(response, request, try b.bind(try b.variable(contract.reply), request, try b.pure(try b.constant(void, {})))));
    return b.module(entry, unit);
}

fn typedExchange(b: *Builder) !bsrc.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const text = try b.schema(.text);
    const contract = try interaction.define(b, .{
        .name = "probe.clarification",
        .channel = text,
        .purpose = text,
        .presentation = unit,
        .outgoing = integer,
        .input = integer,
        .close_conversation = unit,
    });
    const entry = try b.declare(&.{}, integer, &.{contract.effect}, &.{});
    const response = try b.variable(contract.reply);
    const input = try b.variable(integer);
    const close = try b.variable(unit);
    const request = try interaction.exchange(b, contract, .{
        .channel = try b.literal(.{ .schema = text, .bytes = "\x05human" }),
        .purpose = try b.literal(.{ .schema = text, .bytes = "\x0dclarification" }),
        .presentation = try b.constant(void, {}),
        .outgoing = try b.constant(u64, 27),
    });
    const checked = try b.term(.{ .match_sum = .{
        .value = try b.reference(response),
        .cases = &.{
            .{ .variable = input, .body = try b.pure(try arithmetic(b, .integer_add, try b.reference(input), try b.constant(u64, 1))) },
            .{ .variable = close, .body = try b.pure(try b.constant(u64, 0)) },
        },
    } });
    try b.define(entry, try b.bind(response, request, checked));
    return b.module(entry, unit);
}

const Continuation = struct { variable: Id, body: Id };

fn consumeAnswer(b: *Builder, d: dialogue.Generator, term: Id, next: Continuation) !Id {
    _ = d;
    return b.bind(next.variable, term, next.body);
}

fn failure(b: *Builder) !Id {
    return b.term(.{ .fail = try b.constant(void, {}) });
}

fn arithmetic(b: *Builder, opcode: horos.data.program.Opcode, a: Id, c: Id) !Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = opcode,
        .operands = &.{ a, c },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(try b.constant(void, {})) }},
    } } });
}

fn finish(b: *Builder, d: dialogue.Generator) !Continuation {
    const step = try b.variable(d.answer);
    const done = try b.variable(d.result);
    const awaiting = try b.variable(d.yielded);
    const result = try arithmetic(b, .integer_mul, try b.reference(done), try b.constant(u64, 2));
    return .{ .variable = step, .body = try b.term(.{ .match_sum = .{
        .value = try b.reference(step),
        .cases = &.{
            .{ .variable = done, .body = try b.pure(result) },
            .{ .variable = awaiting, .body = try disposeUnexpected(b, d, awaiting) },
        },
    } }) };
}

fn disposeUnexpected(b: *Builder, d: dialogue.Generator, awaiting: Id) !Id {
    const outgoing = try b.variable(d.element);
    const future = try b.variable(d.package);
    const ignored = try b.variable(try b.scalar(void));
    const closed = try dialogue.close(b, d, try b.reference(future));
    return b.term(.{ .unpack_product = .{
        .value = try b.reference(awaiting),
        .variables = &.{ outgoing, future },
        .body = try b.bind(ignored, closed, try failure(b)),
    } });
}

fn awaitingStep(
    b: *Builder,
    d: dialogue.Generator,
    input: Id,
    next: Continuation,
    duplicate: bool,
) !Continuation {
    const step = try b.variable(d.answer);
    const done = try b.variable(d.result);
    const awaiting = try b.variable(d.yielded);
    const outgoing = try b.variable(d.element);
    const future = try b.variable(d.package);
    var advance = try consumeAnswer(b, d, try dialogue.exchange(b, d, try b.reference(future), input), next);
    if (duplicate) {
        const discarded = try b.variable(try b.scalar(void));
        advance = try b.bind(discarded, try dialogue.close(b, d, try b.reference(future)), advance);
    }
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(awaiting),
        .variables = &.{ outgoing, future },
        .body = advance,
    } });
    return .{ .variable = step, .body = try b.term(.{ .match_sum = .{
        .value = try b.reference(step),
        .cases = &.{
            .{ .variable = done, .body = try failure(b) },
            .{ .variable = awaiting, .body = unpack },
        },
    } }) };
}

fn delayedStep(
    b: *Builder,
    d: dialogue.Generator,
    delayed: Id,
    next: Continuation,
    duplicate: bool,
) !Continuation {
    const step = try b.variable(d.answer);
    const done = try b.variable(d.result);
    const awaiting = try b.variable(d.yielded);
    const outgoing = try b.variable(d.element);
    const future = try b.variable(d.package);
    const response = try b.variable(d.input);
    var resumed = try consumeAnswer(b, d, try dialogue.exchange(b, d, try b.reference(future), try b.reference(response)), next);
    if (duplicate) {
        const ignored = try b.variable(try b.scalar(void));
        resumed = try b.bind(ignored, try dialogue.close(b, d, try b.reference(future)), resumed);
    }
    const parked = try b.bind(response, try b.term(.{ .perform = .{
        .effect = delayed,
        .payload = try b.reference(outgoing),
    } }), resumed);
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(awaiting),
        .variables = &.{ outgoing, future },
        .body = parked,
    } });
    return .{ .variable = step, .body = try b.term(.{ .match_sum = .{
        .value = try b.reference(step),
        .cases = &.{
            .{ .variable = done, .body = try failure(b) },
            .{ .variable = awaiting, .body = unpack },
        },
    } }) };
}

fn disposal(b: *Builder) !bsrc.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const region = b.region();
    const region_type = try b.schema(.{ .internal = .{ .region = region } });
    const cell_type = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = region,
    } } });
    const release = try b.effect(.{
        .identity = "agent.probe.dialogue.cleanup.v1",
        .payload = integer,
        .result = unit,
    });
    const d = try dialogue.defineExchange(b, "agent.probe.dialogue.owned.v1", integer, integer, integer, &.{ unit, integer, cell_type }, &.{region}, &.{}, .{ .effects = &.{release} });
    const entry = try b.declare(&.{}, integer, &.{release}, &.{});
    const start_fn = try b.declare(&.{d.capability}, integer, &.{ release, d.effect }, &.{});
    const inside = try b.declare(&.{region_type}, integer, &.{ release, d.effect }, &.{region});
    const body = try b.declare(&.{}, integer, &.{d.effect}, &.{region});
    const cell = try b.variable(cell_type);
    const read = try b.primitive(integer, .cell_get, &.{try b.reference(cell)}, 0);
    const answer = try b.variable(integer);
    try b.define(body, try b.bind(answer, try dialogue.offer(b, d, try b.reference(b.parameter(start_fn, 0)), read), try b.pure(try b.reference(answer))));
    const exit = try horos.library.cleanup.exitInfo(b, unit);
    const cleanup = try b.declare(&.{exit}, unit, &.{release}, &.{region});
    try b.define(cleanup, try b.term(.{ .perform = .{ .effect = release, .payload = read } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = &.{d.effect},
        .capture_bound = &.{ d.capability, cell_type },
        .regions = &.{region},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit},
        .result = unit,
        .effects = &.{release},
        .capture_bound = &.{cell_type},
        .regions = &.{region},
    } } });
    const protected = try b.term(.{ .protect = .{
        .body = try b.lambda(body, body_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } });
    const created = try b.primitive(cell_type, .cell_new, &.{ try b.reference(b.parameter(inside, 0)), try b.constant(u64, 42) }, 0);
    try b.define(inside, try b.bind(cell, try b.pure(created), protected));
    const inside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region_type},
        .result = integer,
        .effects = &.{ release, d.effect },
        .capture_bound = &.{d.capability},
        .regions = &.{region},
    } } });
    try b.define(start_fn, try b.term(.{ .with_region = .{
        .region = region,
        .body = try b.lambda(inside, inside_type),
    } }));
    const start_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.capability},
        .result = integer,
        .effects = &.{ release, d.effect },
    } } });
    const next = try disposeStep(b, d);
    try b.define(entry, try consumeAnswer(b, d, try dialogue.start(b, d, try b.lambda(start_fn, start_type), &.{}), next));
    return b.module(entry, unit);
}

fn disposeStep(b: *Builder, d: dialogue.Generator) !Continuation {
    const step = try b.variable(d.answer);
    const done = try b.variable(d.result);
    const awaiting = try b.variable(d.yielded);
    const outgoing = try b.variable(d.element);
    const future = try b.variable(d.package);
    const ignored = try b.variable(try b.scalar(void));
    const closed = try b.bind(ignored, try dialogue.close(b, d, try b.reference(future)), try b.pure(try b.reference(outgoing)));
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(awaiting),
        .variables = &.{ outgoing, future },
        .body = closed,
    } });
    return .{ .variable = step, .body = try b.term(.{ .match_sum = .{
        .value = try b.reference(step),
        .cases = &.{
            .{ .variable = done, .body = try failure(b) },
            .{ .variable = awaiting, .body = unpack },
        },
    } }) };
}

fn borrowedEscape(b: *Builder) !bsrc.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const region = b.region();
    const region_type = try b.schema(.{ .internal = .{ .region = region } });
    const cell_type = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = region,
    } } });
    const d = try dialogue.defineExchange(b, "agent.probe.dialogue.borrow.v1", integer, integer, integer, &.{ integer, cell_type }, &.{}, &.{region}, .{ .effects = &.{} });
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    const inside = try b.declare(&.{region_type}, d.answer, &.{}, &.{region});
    const body = try b.declare(&.{d.capability}, integer, &.{d.effect}, &.{region});
    const cell = try b.variable(cell_type);
    const ignored = try b.variable(integer);
    const read = try b.primitive(integer, .cell_get, &.{try b.reference(cell)}, 0);
    try b.define(body, try b.bind(ignored, try dialogue.offer(b, d, try b.reference(b.parameter(body, 0)), read), try b.pure(read)));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.capability},
        .result = integer,
        .effects = &.{d.effect},
        .capture_bound = &.{cell_type},
        .regions = &.{region},
    } } });
    const created = try b.primitive(cell_type, .cell_new, &.{ try b.reference(b.parameter(inside, 0)), try b.constant(u64, 42) }, 0);
    try b.define(inside, try b.bind(cell, try b.pure(created), try dialogue.start(b, d, try b.lambda(body, body_type), &.{})));
    const inside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region_type},
        .result = d.answer,
        .regions = &.{region},
    } } });
    const escaped = try b.term(.{ .with_region = .{
        .region = region,
        .body = try b.lambda(inside, inside_type),
    } });
    const resumed = try awaitingStep(b, d, try b.constant(u64, 7), try finish(b, d), false);
    try b.define(entry, try consumeAnswer(b, d, escaped, resumed));
    return b.module(entry, unit);
}

test "consumed dialogue future cannot be resumed" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectError(error.UnavailableSlot, horos.program.compile(std.testing.allocator, try build(&b, .double_use)));
}

test "borrowed dialogue future cannot escape creator region" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectError(error.InvalidOwnership, horos.program.compile(std.testing.allocator, try build(&b, .borrowed_escape)));
}
