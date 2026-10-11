const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kronos = @import("kronos");
const source = horos.source;
const data = horos.data;
const Id = source.Id;

const Responder = enum { rule, human, model };

fn add(b: *source.Builder, left: Id, right: Id) !Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ left, right },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}

// The same decision-using body is used without a responder-dependent branch.
fn decisionBody(b: *source.Builder, family: protean.decision.Family) !Id {
    const number = try b.scalar(u64);
    const body = try b.declare(&.{family.capability}, number, &.{family.effect}, &.{});
    const answer = try b.variable(number);
    const local = try b.variable(number);
    const asked = try protean.decision.ask(b, family, try b.reference(b.parameter(body, 0)), try b.constant(u64, 8));
    const completed = try b.pure(try add(b, try b.reference(local), try b.reference(answer)));
    try b.define(body, try b.bind(local, try b.pure(try b.constant(u64, 100)), try b.bind(answer, asked, completed)));
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{family.capability},
        .result = number,
        .effects = &.{family.effect},
        .use = .linear,
    } } });
    return b.lambda(body, computation);
}

fn decisionModule(b: *source.Builder, responder: Responder) !source.Module {
    const number = try b.scalar(u64);
    const unit = try b.scalar(void);
    const family = try protean.decision.define(b, "consumer.question", number, number);
    const external = if (responder != .rule) try b.effect(.{
        .identity = if (responder == .human) "consumer.human" else "consumer.model",
        .payload = number,
        .result = number,
    }) else null;
    const residual = if (external) |effect| try b.allocator().dupe(Id, &.{effect}) else &.{};
    const respond = try b.declare(&.{number}, number, residual, &.{});
    const question = try b.reference(b.parameter(respond, 0));
    try b.define(respond, if (external) |effect|
        try b.term(.{ .perform = .{ .effect = effect, .payload = question } })
    else
        try b.pure(try add(b, question, try b.constant(u64, 4))));
    const responder_schema = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{number},
        .result = number,
        .effects = residual,
    } } });
    const interpretation = try protean.decision.interpret(b, family, number, responder_schema, .{
        .captures = &.{number},
        .residual = .{ .effects = residual },
    });
    const entry = try b.declare(&.{}, number, residual, &.{});
    try b.define(entry, try protean.decision.handle(b, interpretation, try decisionBody(b, family), try b.lambda(respond, responder_schema), &.{}));
    return b.module(entry, unit);
}

fn replyBytes(a: std.mem.Allocator, request_bytes: []const u8, value: []const u8) ![]u8 {
    var request_owner_0 = try data.invocation.decode(data.invocation.Request, a, request_bytes);
    defer request_owner_0.deinit();
    const request = request_owner_0.value;
    const result = data.invocation.Result{
        .request_identity = request.request_identity,

        .value = value,
    };
    const bytes = try a.alloc(u8, try data.invocation.encodedLength(data.invocation.Result, result));
    errdefer a.free(bytes);
    _ = try data.invocation.encode(data.invocation.Result, a, result, bytes);
    return bytes;
}

fn execute(module: source.Module, prescribed: []const u8, expected: []const u8) !usize {
    const a = std.testing.allocator;
    var compiled = try horos.program.compile(a, module);
    defer compiled.deinit();
    const invocation_image_0 = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(invocation_image_0);
    _ = try horos.data.program_image.encode(a, compiled.program, invocation_image_0);
    var outcome = try kronos.invocation.invoke(a, .{
        .image = invocation_image_0,
        .instance = .{ .initial_args = &.{} },
    });
    defer outcome.deinit();
    var requests: usize = 0;
    while (outcome.record == .requested) {
        requests += 1;
        try std.testing.expect(requests <= 3); // finite test expectation, never a library budget
        const reply = try replyBytes(a, outcome.record.requested.request, prescribed);
        defer a.free(reply);
        const invocation_image_1 = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        defer a.free(invocation_image_1);
        _ = try horos.data.program_image.encode(a, compiled.program, invocation_image_1);
        var next = try kronos.invocation.invoke(a, .{
            .image = invocation_image_1,
            .instance = .{ .state = outcome.record.requested.state.? },
            .control = .{ .reply = reply },
        });
        outcome.deinit();
        outcome = next;
        next = undefined;
    }
    try std.testing.expect(outcome.record == .completed);
    try std.testing.expectEqualSlices(u8, expected, outcome.record.completed);
    return requests;
}

test "one Ask body preserves its local continuation under rule human and model interpretations" {
    for ([_]Responder{ .rule, .human, .model }) |responder| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const requests = try execute(try decisionModule(&b, responder), &.{ 12, 0, 0, 0, 0, 0, 0, 0 }, &.{ 112, 0, 0, 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(@as(usize, if (responder == .rule) 0 else 1), requests);
    }
}

test "Ask rejects incompatible and linear responder schemas and duplicate meanings" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const family = try protean.decision.define(&b, "question", number, number);
    const same = try protean.decision.define(&b, "question", number, number);
    try std.testing.expectEqual(family.effect, same.effect);
    try std.testing.expectError(error.InvalidSource, protean.decision.define(&b, "question", number, try b.scalar(bool)));
    const linear = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{number},
        .result = number,
        .use = .linear,
    } } });
    try std.testing.expectError(error.InvalidOwnership, protean.decision.interpret(&b, family, number, linear, .{}));
    try std.testing.expectError(error.TypeMismatch, protean.decision.interpret(&b, family, number, number, .{}));
}

test "Ask interpretation preserves captures regions cleanup and pure return" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const family = try protean.decision.define(&b, "question.metadata", number, number);
    const external = try b.effect(.{ .identity = "question.responder", .payload = number, .result = number });
    const responder = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{number},
        .result = number,
        .effects = &.{external},
    } } });
    const region = b.region();
    const interpretation = try protean.decision.interpret(&b, family, number, responder, .{
        .captures = &.{number},
        .residual = .{ .effects = &.{external} },
        .owned_regions = &.{region},
        .borrowed_regions = &.{region},
    });
    const token = b.schemas.items[@intCast(interpretation.resumption)].internal.resumption;
    try std.testing.expect(token.obligations);
    try std.testing.expectEqualSlices(Id, &.{ number, family.capability, responder }, token.capture_bound);
    try std.testing.expectEqualSlices(Id, &.{region}, token.owned_regions);
    try std.testing.expectEqualSlices(Id, &.{external}, token.effects);
    const handler = b.handlers.items[@intCast(interpretation.handler)];
    const returns = b.functions.items[@intCast(handler.return_function)];
    const clause = b.functions.items[@intCast(handler.clauses[0].function)];
    try std.testing.expectEqual(@as(usize, 0), returns.effects.len);
    try std.testing.expectEqualSlices(Id, &.{external}, clause.effects);
    try std.testing.expectEqualSlices(Id, &.{region}, returns.regions);
    try std.testing.expectEqualSlices(Id, &.{region}, clause.regions);
}

test "portable descriptor intersection covers 31 32 63 and rejects unavailable indexes" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const set = try protean.sets.define(&b, 64);
    var outer = @as([64]bool, @splat(false));
    outer[31] = true;
    outer[32] = true;
    outer[63] = true;
    var restriction = @as([64]bool, @splat(true));
    restriction[32] = false;
    const outer_value = try protean.sets.literal(&b, set, &outer);
    try std.testing.expectError(error.InvalidReference, protean.sets.member(&b, set, outer_value, 64));
    const intersection = try b.variable(set.schema);
    const results = try b.schema(.{ .array = .{ .element = try b.scalar(bool), .length = 4 } });
    var answers: [4]Id = undefined;
    var values: [4]Id = undefined;
    for (&answers, &values) |*answer, *value| {
        answer.* = try b.variable(try b.scalar(bool));
        value.* = try b.reference(answer.*);
    }
    var body = try b.pure(try b.primitive(results, .sequence, &values, 0));
    const indexes = [_]u64{ 31, 32, 63, 64 };
    var index: usize = indexes.len;
    while (index != 0) {
        index -= 1;
        body = try b.bind(answers[index], try protean.sets.contains(&b, set, try b.reference(intersection), try b.constant(u64, indexes[index])), body);
    }
    const entry = try b.declare(&.{}, results, &.{}, &.{});
    try b.define(entry, try b.bind(intersection, try protean.sets.intersection(&b, set, outer_value, try protean.sets.literal(&b, set, &restriction)), body));
    _ = try execute(b.module(entry, try b.scalar(void)), &.{}, &.{ 1, 0, 1, 0 });
}

fn scopeBodySchema(b: *source.Builder, reader: protean.scopes.Reader, residual: Id) !Id {
    const row = try (source.Row{ .effects = &.{residual} }).unionWith(b.allocator(), .{
        .effects = &.{reader.family.effect},
    });
    return b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{reader.family.capability},
        .result = reader.environment,
        .effects = row.effects,
        .use = .linear,
    } } });
}

test "reader interpretation retains captures regions cleanup and pure return" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const environment = try b.scalar(u64);
    const captured = try b.scalar(bool);
    const external = try b.effect(.{ .identity = "reader.residual", .payload = environment, .result = environment });
    const region = b.region();
    const reader = try protean.scopes.define(&b, "reader.metadata", environment, environment, .{
        .captures = &.{captured},
        .residual = .{ .effects = &.{external} },
        .owned_regions = &.{region},
        .borrowed_regions = &.{region},
    });
    const token = b.schemas.items[@intCast(reader.resumption)].internal.resumption;
    try std.testing.expect(token.obligations);
    try std.testing.expectEqualSlices(Id, &.{ captured, reader.family.capability, environment }, token.capture_bound);
    try std.testing.expectEqualSlices(Id, &.{region}, token.owned_regions);
    try std.testing.expectEqualSlices(Id, &.{external}, token.effects);
    const handler = b.handlers.items[@intCast(reader.handler)];
    try std.testing.expectEqualSlices(Id, &.{environment}, handler.state);
    const returns = b.functions.items[@intCast(handler.return_function)];
    const clause = b.functions.items[@intCast(handler.clauses[0].function)];
    try std.testing.expectEqual(@as(usize, 0), returns.effects.len);
    try std.testing.expectEqualSlices(Id, &.{external}, clause.effects);
    try std.testing.expectEqualSlices(Id, &.{region}, returns.regions);
    try std.testing.expectEqualSlices(Id, &.{region}, clause.regions);
}

test "nested lexical environments survive residual suspension and restore outer interpretation" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const external = try b.effect(.{
        .identity = "consumer.clarify",
        .payload = number,
        .result = number,
    });
    const reader = try protean.scopes.define(&b, "consumer.scope", number, number, .{
        .captures = &.{number},
        .residual = .{ .effects = &.{external} },
    });
    const computation = try scopeBodySchema(&b, reader, external);
    const effects = b.schemas.items[@intCast(computation)].internal.computation.effects;
    const inside = try b.declare(&.{reader.family.capability}, number, effects, &.{});
    const retained = try b.variable(number);
    const ignored = try b.variable(number);
    try b.define(inside, try b.bind(retained, try protean.scopes.read(&b, reader, try b.reference(b.parameter(inside, 0))), try b.bind(ignored, try b.term(.{ .perform = .{
        .effect = external,
        .payload = try b.reference(retained),
    } }), try b.pure(try b.reference(retained)))));
    const outer = try b.declare(&.{reader.family.capability}, number, effects, &.{});
    const before = try b.variable(number);
    const inner = try b.variable(number);
    const after = try b.variable(number);
    const cap = try b.reference(b.parameter(outer, 0));
    const result = try b.pure(try add(&b, try add(&b, try b.reference(before), try b.reference(inner)), try b.reference(after)));
    try b.define(outer, try b.bind(before, try protean.scopes.read(&b, reader, cap), try b.bind(inner, try protean.scopes.enter(&b, reader, try b.lambda(inside, computation), try b.constant(u64, 7), &.{}), try b.bind(after, try protean.scopes.read(&b, reader, cap), result))));
    const entry = try b.declare(&.{}, number, &.{external}, &.{});
    try b.define(entry, try protean.scopes.enter(&b, reader, try b.lambda(outer, computation), try b.constant(u64, 2), &.{}));
    const requests = try execute(b.module(entry, try b.scalar(void)), &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, &.{ 11, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), requests);
}

fn instructions(b: *source.Builder, shape: protean.scopes.Layout, n: u64) !Id {
    return b.primitive(shape.instructions, .sequence, &.{try b.constant(u64, n)}, 0);
}

test "scope contributions preserve lexical instructions memory and permission intersections" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const shape = try protean.scopes.layout(&b, number, number, 2, 64, 64);
    var tools = @as([64]bool, @splat(false));
    tools[31] = true;
    tools[32] = true;
    var skills = @as([64]bool, @splat(false));
    skills[31] = true;
    skills[63] = true;
    const initial = try protean.scopes.value(&b, shape, .{
        .model = try b.constant(u64, 0),
        .instructions = try instructions(&b, shape, 1),
        .models = try protean.sets.filled(&b, shape.models, true),
        .tools = try protean.sets.literal(&b, shape.tools, &tools),
        .skills = try protean.sets.literal(&b, shape.skills, &skills),
        .memory = try b.constant(u64, 11),
    });
    tools[32] = false;
    skills[31] = false;
    const first = try b.variable(shape.schema);
    const first_term = try protean.scopes.narrow(&b, shape, initial, .{
        .instructions = try instructions(&b, shape, 2),
        .models = try protean.sets.filled(&b, shape.models, true),
        .tools = try protean.sets.literal(&b, shape.tools, &tools),
        .skills = try protean.sets.literal(&b, shape.skills, &skills),
    });
    const second = try protean.scopes.narrow(&b, shape, try b.reference(first), .{
        .instructions = try instructions(&b, shape, 3),
        .models = try protean.sets.literal(&b, shape.models, &.{ true, false }),
        .tools = try protean.sets.filled(&b, shape.tools, true),
        .skills = try protean.sets.filled(&b, shape.skills, true),
    });
    const entry = try b.declare(&.{}, shape.schema, &.{}, &.{});
    try b.define(entry, try b.bind(first, first_term, second));
    var expected: [171]u8 = @splat(0);
    expected[8] = 3;
    expected[9] = 1;
    expected[17] = 2;
    expected[25] = 3;
    expected[33] = 1;
    expected[35 + 31] = 1;
    expected[99 + 63] = 1;
    expected[163] = 11;
    _ = try execute(b.module(entry, try b.scalar(void)), &.{}, &expected);
}

test "a disallowed model override is a declared denied answer" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const shape = try protean.scopes.layout(&b, number, number, 2, 0, 0);
    const initial = try protean.scopes.value(&b, shape, .{
        .model = try b.constant(u64, 0),
        .instructions = try instructions(&b, shape, 1),
        .models = try protean.sets.literal(&b, shape.models, &.{ true, false }),
        .tools = try protean.sets.filled(&b, shape.tools, false),
        .skills = try protean.sets.filled(&b, shape.skills, false),
        .memory = try b.constant(u64, 11),
    });
    const entry = try b.declare(&.{}, shape.override_result, &.{}, &.{});
    try b.define(entry, try protean.scopes.overrideModel(&b, shape, initial, 1));
    _ = try execute(b.module(entry, try b.scalar(void)), &.{}, &.{ 1, 1, 0, 0, 0, 0, 0, 0, 0 });
}

test "a permitted model override selects the inner profile and preserves scope data" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const shape = try protean.scopes.layout(&b, number, number, 2, 0, 0);
    const initial = try protean.scopes.value(&b, shape, .{
        .model = try b.constant(u64, 0),
        .instructions = try instructions(&b, shape, 1),
        .models = try protean.sets.filled(&b, shape.models, true),
        .tools = try protean.sets.filled(&b, shape.tools, false),
        .skills = try protean.sets.filled(&b, shape.skills, false),
        .memory = try b.constant(u64, 11),
    });
    const entry = try b.declare(&.{}, shape.override_result, &.{}, &.{});
    try b.define(entry, try protean.scopes.overrideModel(&b, shape, initial, 1));
    var expected: [28]u8 = @splat(0);
    expected[1] = 1; // retained selected model
    expected[9] = 1; // instruction count
    expected[10] = 1;
    expected[18] = 1;
    expected[19] = 1;
    expected[20] = 11; // retained epistemic value
    _ = try execute(b.module(entry, try b.scalar(void)), &.{}, &expected);
}

test "scope and set helper declarations are shared across repeated installations" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const number = try b.scalar(u64);
    const reader = try protean.scopes.define(&b, "scope.shared", number, number, .{});
    const set = try protean.sets.define(&b, 64);
    const all = try protean.sets.filled(&b, set, true);
    _ = try protean.sets.intersection(&b, set, all, all);
    const functions = b.functions.items.len;
    const handlers = b.handlers.items.len;
    for (0..64) |_| {
        const shared = try protean.scopes.define(&b, "scope.shared", number, number, .{});
        try std.testing.expectEqual(reader.handler, shared.handler);
        _ = try protean.sets.intersection(&b, set, all, all);
        try std.testing.expectEqual(functions, b.functions.items.len);
        try std.testing.expectEqual(handlers, b.handlers.items.len);
    }
}

test "descriptor values cannot substitute a larger catalog and responder rows cannot hide effects" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const small = try protean.sets.define(&b, 32);
    const large = try protean.sets.define(&b, 64);
    const all = try protean.sets.filled(&b, large, true);
    try std.testing.expectError(error.TypeMismatch, protean.sets.contains(&b, small, all, try b.constant(u64, 63)));
    const number = try b.scalar(u64);
    const family = try protean.decision.define(&b, "question.row", number, number);
    const effect = try b.effect(.{ .identity = "external.undeclared", .payload = number, .result = number });
    const responder = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{number},
        .result = number,
        .effects = &.{effect},
    } } });
    try std.testing.expectError(error.InvalidEffect, protean.decision.interpret(&b, family, number, responder, .{}));
}
