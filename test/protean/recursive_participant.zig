//! Compiled participants over suspended task-valued hyperfunction endpoints.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const source = horos.source;
const hyper = horos.library.hyper;
const data = horos.data;
const fixture = @import("participant.zig");
const P = fixture.P;
const Input = fixture.Input;
const State = struct { input: Input, successor: bool };
const Id = source.Id;
const Types = struct {
    input: Id,
    state: Id,
    integer: Id,
    task: Id,
    pair: hyper.Pair,
    model: Id,
    read: Id,
    sample: Id,
};

fn types(b: *source.Builder) !Types {
    const cache = try b.specialization(Types, "fixture.recursive-participant/v1", .{});
    if (cache.cached) |value| return value;
    const input = try protean.contracts.schema(Input, b);
    const state = try protean.contracts.schema(State, b);
    const integer = try b.scalar(u64);
    const model = try P.declare(b);
    const read = try b.effect(.{ .identity = "fixture.recursive.reference-bytes", .payload = integer, .result = integer });
    const task = try b.reserveSchema();
    const pair = try hyper.pairWith(b, task, task, &.{ state, integer });
    try b.defineSchema(task, .{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = &.{ model, read },
        .capture_bound = &.{ state, pair.peer_forward, pair.peer_backward },
    } } });
    const sample = try b.declare(&.{input}, integer, &.{model}, &.{});
    return cache.finish(b, .{ .input = input, .state = state, .integer = integer, .task = task, .pair = pair, .model = model, .read = read, .sample = sample });
}

fn add(b: *source.Builder, t: Types, left: Id, right: Id) !Id {
    return b.value(.{ .schema = t.integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ left, right },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(try b.constant(void, {})) }},
    } } });
}

fn step(b: *source.Builder, q: hyper.Query, consumer: bool, repeat: bool) !Id {
    const t = try types(b);
    const task = try b.declare(&.{}, t.integer, &.{ t.model, t.read }, &.{});
    const need = try hyper.demand.family(b, "fixture.recursive.need", t.state, t.integer);
    const interpreted = try hyper.demand.interpret(b, q, need, t.integer, .{
        .captures = &.{ t.state, t.integer, t.pair.peer_forward, t.pair.peer_backward },
        .residual = .{ .effects = &.{ t.model, t.read } },
    });
    const inside = try b.declare(&.{need.capability}, t.integer, &.{ t.model, t.read, need.effect }, &.{});
    const capability = try b.reference(b.parameter(inside, 0));
    const contribution = try b.variable(t.integer);
    const input = try b.primitive(t.input, .field, &.{q.state}, 0);
    const next = try b.primitive(t.state, .product, &.{ input, try b.constant(bool, true) }, 0);
    var after = try b.pure(try add(b, t, try b.reference(contribution), try b.constant(u64, if (consumer) 13 else 10)));
    if (!consumer) {
        const sampled = try b.variable(t.integer);
        const summed = try add(b, t, try b.reference(contribution), try b.reference(sampled));
        after = try b.bind(sampled, try b.term(.{ .call = .{
            .function = t.sample,
            .arguments = &.{input},
        } }), try b.pure(try add(b, t, summed, try b.constant(u64, 10))));
    }
    if (repeat) after = try repeatContribution(b, need, capability, t, next, try b.reference(contribution));
    const nested = try b.bind(contribution, try hyper.demand.request(b, need, capability, next), after);
    const body = if (consumer) try b.term(.{ .conditional = .{
        .condition = try b.primitive(try b.scalar(bool), .field, &.{q.state}, 1),
        .when_true = try b.term(.{ .perform = .{
            .effect = t.read,
            .payload = try b.constant(u64, 0),
        } }),
        .when_false = nested,
    } }) else nested;
    try b.define(inside, body);
    try b.define(task, try hyper.demand.handle(b, interpreted, q.peer, try b.lambda(inside, interpreted.body)));
    const description = try b.declare(&.{}, t.task, &.{}, &.{});
    try b.define(description, try b.pure(try b.lambda(task, t.task)));
    return b.pure(try b.lambda(description, q.types.answer_forward));
}
const Producer = struct {
    pub fn emit(b: *source.Builder, q: hyper.Query) !Id {
        return step(b, q, false, false);
    }
};
const Consumer = struct {
    pub fn emit(b: *source.Builder, q: hyper.Query) !Id {
        return step(b, q, true, false);
    }
};
const Alternative = struct {
    pub fn emit(b: *source.Builder, q: hyper.Query) !Id {
        return step(b, q, true, true);
    }
};

fn repeatContribution(b: *source.Builder, need: hyper.demand.Family, capability: Id, t: Types, next: Id, first: Id) !Id {
    const second = try b.variable(t.integer);
    const combined = try add(b, t, first, try b.reference(second));
    const answer = try b.pure(try add(b, t, combined, try b.constant(u64, 13)));
    return b.bind(second, try hyper.demand.request(b, need, capability, next), answer);
}

fn object(allocator: std.mem.Allocator, consumer: bool) ![]u8 {
    return objectChecked(allocator, consumer, false, false);
}
fn objectChecked(allocator: std.mem.Allocator, consumer: bool, false_capture: bool, alternative: bool) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const t = try types(&b);
    if (false_capture) {
        const owned = try b.resource(t.integer);
        b.schemas.items[@intCast(t.task)].internal.computation.capture_bound =
            try b.allocator().dupe(Id, &.{owned});
    }
    const definition = if (alternative)
        try hyper.ana(&b, hyper.swap(t.pair), t.state, Alternative)
    else if (consumer)
        try hyper.ana(&b, hyper.swap(t.pair), t.state, Consumer)
    else
        try hyper.ana(&b, t.pair, t.state, Producer);
    var compiled = try source.component.compile(allocator, b.module(definition.function, try b.scalar(void)), .{
        .imports = &.{
            .{ .name = "model", .reference = .{ .kind = .effect, .id = t.model } },
            .{ .name = "read", .reference = .{ .kind = .effect, .id = t.read } },
            .{ .name = "sample", .reference = .{ .kind = .function, .id = t.sample } },
        },
        .exports = &.{.{ .name = "create", .reference = .{ .kind = .function, .id = definition.function } }},
        .borrows = &.{.{ .function = t.sample }},
    });
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}

fn defineSample(c: protean.Context, t: Types) !void {
    const b = c.builder;
    const interpreted = try protean.responders.defineModel(P, c, try b.constant(void, {}), false);
    const result = try b.variable(try c.schema(P.Interpretation));
    const accepted = try b.variable(try c.schema(P.AnswerType));
    const rejected = try b.variable(try c.schema(P.InterpretationFailure));
    const contribution = try b.variable(try c.schema(struct { value: u64 }));
    const answer = try b.term(.{ .match_sum = .{ .value = try b.reference(accepted), .cases = &.{.{ .variable = contribution, .body = try b.pure(try b.primitive(t.integer, .field, &.{try b.reference(contribution)}, 0)) }} } });
    const dispatch = try b.term(.{ .match_sum = .{ .value = try b.reference(result), .cases = &.{
        .{ .variable = accepted, .body = answer },
        .{ .variable = rejected, .body = try b.term(.{ .fail = try b.constant(void, {}) }) },
    } } });
    const input = try b.reference(b.parameter(t.sample, 0));
    const call = try b.term(.{ .call = .{ .function = interpreted, .arguments = &.{
        try b.primitive(try c.schema(P.Request), .field, &.{input}, 0),
        try b.primitive(try c.schema([1]bool), .field, &.{input}, 1),
    } } });
    try b.define(t.sample, try b.bind(result, call, dispatch));
}

const Application = struct {
    var producer_bytes: []const u8 = &.{};
    var consumer_bytes: []const u8 = &.{};
    var omit_reference = false;
    var assessment = false;
    var completion = false;
    pub fn emit(c: protean.Context) !source.Module {
        const b = c.builder;
        const t = try types(b);
        try c.registry.classify(t.model, .model);
        try c.registry.classify(t.read, .read);
        try defineSample(c, t);
        var bindings = t;
        if (completion) bindings.sample = try completionHelper(c, t);
        const producer = try install(c, bindings, "producer", producer_bytes, t.pair.forward);
        const consumer = try install(c, bindings, "consumer", consumer_bytes, t.pair.backward);
        if (assessment) try c.registry.speculate(producer, &.{ t.model, t.read });
        const entry = try b.declare(&.{t.input}, t.integer, &.{ t.model, t.read }, &.{});
        const initial = try b.primitive(t.state, .product, &.{
            try b.reference(b.parameter(entry, 0)), try b.constant(bool, false),
        }, 0);
        const p = try b.variable(t.pair.forward);
        const peer = try b.declare(&.{}, t.pair.forward, &.{}, &.{});
        try b.define(peer, try b.pure(try b.reference(p)));
        const participant = try b.variable(t.pair.backward);
        const delayed_task = try b.variable(t.pair.answer_backward);
        const task = try b.variable(t.task);
        const invoked = try hyper.invoke(b, try b.reference(participant), try b.lambda(peer, t.pair.peer_forward));
        const run = try b.bind(delayed_task, invoked, try b.bind(task, try hyper.force(b, try b.reference(delayed_task)), try hyper.force(b, try b.reference(task))));
        const created = try b.bind(participant, try b.term(.{ .call = .{
            .function = consumer,
            .arguments = &.{initial},
        } }), try withIdle(b, t, run));
        try b.define(entry, try b.bind(p, try b.term(.{ .call = .{
            .function = producer,
            .arguments = &.{initial},
        } }), created));
        return b.module(entry, try b.scalar(void));
    }
};
fn install(c: protean.Context, t: Types, name: []const u8, bytes: []const u8, result: Id) !Id {
    return protean.participant.declare(c, .{
        .instance = name,
        .object = bytes,
        .entry = "create",
        .parameters = &.{t.state},
        .result = result,
        .effects = if (Application.omit_reference) &.{.{ .symbol = "model", .effect = t.model }} else &.{ .{ .symbol = "model", .effect = t.model }, .{ .symbol = "read", .effect = t.read } },
        .functions = &.{.{ .symbol = "sample", .function = t.sample }},
    });
}
const System = protean.system(.{
    .InitialArgs = Input,
    .Result = u64,
    .Failure = void,
    .application = Application,
});

fn discardIdle(b: *source.Builder, g: horos.library.generator.Generator, value: Id) !Id {
    const payload = try b.variable(g.element);
    const package = try b.variable(g.package);
    const failure = try b.term(.{ .fail = try b.constant(void, {}) });
    const disposed = try horos.library.generator.close(b, g, try b.reference(package));
    const done = try b.bind(try b.variable(try b.scalar(void)), disposed, failure);
    return b.term(.{ .unpack_product = .{ .value = value, .variables = &.{ payload, package }, .body = done } });
}

/// Reuse the foundation's owned package mechanism. Its idle continuation remains
/// independently live while the reciprocal task and model responder are parked.
fn withIdle(b: *source.Builder, t: Types, work: Id) !Id {
    const unit = try b.scalar(void);
    const g = try horos.library.generator.defineExchange(b, "fixture.recursive.idle", unit, t.integer, unit, &.{ unit, t.integer }, &.{}, &.{}, .{ .effects = &.{t.read} });
    const body = try b.declare(&.{g.capability}, unit, &.{ t.read, g.effect }, &.{});
    const offered = try b.term(.{ .perform = .{ .effect = g.effect, .capability = try b.reference(b.parameter(body, 0)), .payload = try b.constant(u64, 7) } });
    const observed = try b.term(.{ .perform = .{ .effect = t.read, .payload = try b.constant(u64, 1) } });
    const finished = try b.pure(try b.constant(void, {}));
    try b.define(body, try b.bind(try b.variable(unit), offered, try b.bind(try b.variable(t.integer), observed, finished)));
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{g.capability},
        .result = unit,
        .effects = &.{ t.read, g.effect },
    } } });
    const answer = try b.variable(g.answer);
    const yielded = try b.variable(g.yielded);
    const payload = try b.variable(t.integer);
    const package = try b.variable(g.package);
    const result = try b.variable(t.integer);
    const next = try b.variable(g.answer);
    const unexpected = try b.variable(g.yielded);
    const finish = try b.term(.{ .match_sum = .{ .value = try b.reference(next), .cases = &.{
        .{ .variable = try b.variable(unit), .body = try b.pure(try b.reference(result)) },
        .{ .variable = unexpected, .body = try discardIdle(b, g, try b.reference(unexpected)) },
    } } });
    const resumed = try b.bind(next, try horos.library.generator.next(b, g, try b.reference(package)), finish);
    const execute = try b.bind(result, work, resumed);
    const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(yielded), .variables = &.{ payload, package }, .body = execute } });
    const dispatch = try b.term(.{ .match_sum = .{ .value = try b.reference(answer), .cases = &.{
        .{ .variable = try b.variable(unit), .body = try b.term(.{ .fail = try b.constant(void, {}) }) },
        .{ .variable = yielded, .body = unpack },
    } } });
    return b.bind(answer, try b.term(.{ .handle = .{
        .handler = g.handler,
        .body = try b.lambda(body, signature),
    } }), dispatch);
}

fn completionHelper(c: protean.Context, t: Types) !Id {
    const b = c.builder;
    const write = try c.external("fixture.recursive.target-write", t.input, t.integer, .write);
    const function = try b.declare(&.{t.input}, t.integer, &.{write}, &.{});
    const operation = try b.term(.{ .perform = .{ .effect = write, .payload = try b.reference(b.parameter(function, 0)) } });
    // Model the real trusted completion site; ordinary admission permits it.
    // A speculative import must still reject its actual write authority.
    try c.registry.protectSite(function, operation, write);
    try b.define(function, operation);
    return function;
}

test "recursive participant rejects an exclusive resource hidden in a reusable task" {
    try std.testing.expectError(error.InvalidOwnership, objectChecked(std.testing.allocator, false, true, false));
}

test "recursive participant normal admission rejects missing reference binding" {
    const allocator = std.testing.allocator;
    const p = try object(allocator, false);
    defer allocator.free(p);
    const c = try object(allocator, true);
    defer allocator.free(c);
    Application.producer_bytes = p;
    Application.consumer_bytes = c;
    Application.omit_reference = true;
    defer Application.omit_reference = false;
    try std.testing.expectError(error.InvalidParticipant, protean.compile(allocator, System));
}

test "recursive participant assessment examines imported completion authority" {
    const allocator = std.testing.allocator;
    const p = try object(allocator, false);
    defer allocator.free(p);
    const c = try object(allocator, true);
    defer allocator.free(c);
    Application.producer_bytes = p;
    Application.consumer_bytes = c;
    Application.assessment = true;
    defer Application.assessment = false;
    var permitted = try protean.compile(allocator, System);
    defer permitted.deinit();
    Application.completion = true;
    defer Application.completion = false;
    try std.testing.expectError(error.SpeculativeEffect, protean.compile(allocator, System));
}
