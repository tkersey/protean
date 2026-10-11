const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const kronos = @import("kronos");
const source = horos.source;
const data = horos.data;
const Id = source.Id;

fn fixture(c: protean.Context) !protean.observation.Definition {
    _ = try c.builder.scalar(void);
    const number = try c.builder.scalar(u64);
    const read = try c.external("consumer.document.read", number, number, .read);
    return protean.observation.define(c, "document", read);
}

// Exactly this body is used under both interpretations. It knows only its
// domain operation and makes no decision based on the installed responder.
fn client(b: *source.Builder, d: protean.observation.Definition) !Id {
    const f = try b.declare(&.{d.family.capability}, d.observation, &.{d.family.effect}, &.{});
    try b.define(f, try protean.observation.ask(b, d, try b.reference(b.parameter(f, 0)), try b.constant(u64, 7)));
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.family.capability},
        .result = d.observation,
        .effects = &.{d.family.effect},
        .use = .linear,
    } } });
    return b.lambda(f, computation);
}

fn interpreted(c: protean.Context, live: bool) !source.Module {
    const b = c.builder;
    const d = try fixture(c);
    const entry = try b.declare(&.{}, d.observation, &.{d.live_effect}, &.{});
    const body = try client(b, d);
    const handled = if (live)
        try protean.observation.withLive(c, d, entry, d.observation, body, .{
            .residual = .{ .effects = &.{d.live_effect} },
        }, &.{})
    else blk: {
        const simulator = try b.declare(&.{d.question}, d.data, &.{}, &.{});
        try b.define(simulator, try b.pure(try b.constant(u64, 42)));
        const computation = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{d.question},
            .result = d.data,
        } } });
        break :blk try protean.observation.withSimulation(c, d, d.observation, body, try b.lambda(simulator, computation), .{}, &.{});
    };
    try b.define(entry, handled);
    return b.module(entry, try b.scalar(void));
}

fn boundReply(a: std.mem.Allocator, request_bytes: []const u8, answer: []const u8) ![]u8 {
    var request_owner_0 = try data.invocation.decode(data.invocation.Request, a, request_bytes);
    defer request_owner_0.deinit();
    const request = request_owner_0.value;
    const result = data.invocation.Result{
        .request_identity = request.request_identity,

        .value = answer,
    };
    const bytes = try a.alloc(u8, try data.invocation.encodedLength(data.invocation.Result, result));
    errdefer a.free(bytes);
    _ = try data.invocation.encode(data.invocation.Result, a, result, bytes);
    return bytes;
}

fn execute(module: source.Module, registry: *protean.admission.Registry, expected: []const u8) !usize {
    const a = std.testing.allocator;
    try protean.admission.verify(a, module, registry);
    var compiled = try horos.program.compile(a, module);
    defer compiled.deinit();
    const invocation_image_0 = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(invocation_image_0);
    _ = try horos.data.program_image.encode(a, compiled.program, invocation_image_0);
    var result = try kronos.invocation.invoke(a, .{
        .image = invocation_image_0,
        .instance = .{ .initial_args = &.{} },
    });
    defer result.deinit();
    var requests: usize = 0;
    while (result.record == .requested) {
        requests += 1;
        try std.testing.expectEqual(@as(usize, 1), requests);
        var request_owner_1 = try data.invocation.decode(data.invocation.Request, a, result.record.requested.request);
        defer request_owner_1.deinit();
        const request = request_owner_1.value;
        try std.testing.expectEqualStrings("consumer.document.read", request.binding.semantic_identity);
        const reply = try boundReply(a, result.record.requested.request, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
        defer a.free(reply);
        const invocation_image_1 = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        defer a.free(invocation_image_1);
        _ = try horos.data.program_image.encode(a, compiled.program, invocation_image_1);
        const next = try kronos.invocation.invoke(a, .{
            .image = invocation_image_1,
            .instance = .{ .state = result.record.requested.state.? },
            .control = .{ .reply = reply },
        });
        result.deinit();
        result = next;
    }
    try std.testing.expect(result.record == .completed);
    try std.testing.expectEqualSlices(u8, expected, result.record.completed);
    return requests;
}

test "one domain client uses actual live read or typed simulation as authored" {
    for ([_]bool{ true, false }) |live| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const c: protean.Context = .{ .builder = &b, .registry = &registry };
        const expected = [_]u8{ @intFromBool(!live), 42, 0, 0, 0, 0, 0, 0, 0 };
        const requests = try execute(try interpreted(c, live), &registry, &expected);
        try std.testing.expectEqual(@as(usize, if (live) 1 else 0), requests);
    }
}

test "live proof retains exactly the corresponding external result across suspension" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const d = try fixture(c);
    const pair = try b.schema(.{ .product = &.{ d.data, d.data } });
    const entry = try b.declare(&.{}, pair, &.{d.live_effect}, &.{});
    const evidence = try b.variable(d.evidence);
    const actual = try b.variable(d.data);
    const proof = try b.variable(d.proof);
    const consumed = try b.variable(d.data);
    const done = try b.pure(try b.primitive(pair, .product, &.{ try b.reference(actual), try b.reference(consumed) }, 0));
    const owned = try b.bind(consumed, try protean.observation.consumeEvidence(c, d, entry, try b.reference(proof)), done);
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(evidence),
        .variables = &.{ actual, proof },
        .body = owned,
    } });
    try b.define(entry, try b.bind(evidence, try protean.observation.readEvidence(c, d, entry, try b.constant(u64, 7)), unpack));
    _ = try execute(b.module(entry, try b.scalar(void)), &registry, &.{ 42, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0 });
}

test "a simulation or external label cannot supply a live evidence resource" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const d = try fixture(c);
    const entry = try b.declare(&.{}, d.data, &.{}, &.{});
    for (0..2) |origin| {
        const tagged = try b.primitive(d.observation, .variant, &.{try b.constant(u64, 42)}, origin);
        try std.testing.expectError(error.LiveEvidenceRequired, protean.observation.consumeEvidence(c, d, entry, tagged));
    }
    try std.testing.expectError(error.LiveEvidenceRequired, protean.observation.consumeEvidence(c, d, entry, try b.constant(u64, 42)));
}

test "equal data schemas do not make different live evidence contracts interchangeable" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const first = try fixture(c);
    const other_read = try c.external("consumer.other.read", first.question, first.data, .read);
    const second = try protean.observation.define(c, "other", other_read);
    try std.testing.expectError(error.InvalidObservationContract, protean.observation.define(c, "document", other_read));
    const owner = try b.declare(&.{second.proof}, first.data, &.{}, &.{});
    const different = try b.reference(b.parameter(owner, 0));
    try std.testing.expectError(error.LiveEvidenceRequired, protean.observation.consumeEvidence(c, first, owner, different));
}

test "application code cannot mint a live resource with raw source construction" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const d = try fixture(c);
    const entry = try b.declare(&.{}, d.data, &.{}, &.{});
    const forged = try b.primitive(d.proof, .resource_pack, &.{try b.constant(u64, 42)}, 0);
    try b.define(entry, try protean.observation.consumeEvidence(c, d, entry, forged));
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(std.testing.allocator, module, &registry);
    try std.testing.expectError(error.InvalidOwnership, horos.program.compile(std.testing.allocator, module));
}

test "raw handler cannot intercept the live read to mint evidence" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const d = try fixture(c);
    const capability = try b.schema(.{ .internal = .{ .capability = d.live_effect } });
    const responder = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.question},
        .result = d.data,
    } } });
    const family: protean.decision.Family = .{
        .effect = d.live_effect,
        .capability = capability,
        .question = d.question,
        .answer = d.data,
    };
    try std.testing.expectError(error.InvalidSource, protean.decision.interpret(&b, family, d.data, responder, .{}));
    // The typed constructor rejects external operations. Protean admission must
    // still inspect handlers supplied through the retained raw source path.
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = d.live_effect,
        .input = d.data,
        .answer = d.data,
        .capture_bound = &.{ capability, responder },
        .handled = &.{d.live_effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const returns = try b.declare(&.{ responder, d.data }, d.data, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const clause = try b.declare(&.{ responder, d.question, token }, d.data, &.{}, &.{});
    const answer = try b.variable(d.data);
    const answered = try b.term(.{ .apply = .{
        .computation = try b.reference(b.parameter(clause, 0)),
        .arguments = &.{try b.reference(b.parameter(clause, 1))},
    } });
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(clause, 2)),
        .argument = try b.reference(answer),
    } });
    try b.define(clause, try b.bind(answer, answered, resumed));
    _ = try b.handler(.{
        .mode = .deep,
        .input = d.data,
        .answer = d.data,
        .return_function = returns,
        .state = &.{responder},
        .effects = &.{},
        .clauses = &.{.{ .effect = d.live_effect, .function = clause, .resumption = token }},
    });
    const entry = try b.declare(&.{}, d.data, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(u64, 0)));
    try std.testing.expectError(error.ProtectedHandler, protean.admission.verify(std.testing.allocator, b.module(entry, try b.scalar(void)), &registry));
}

test "typed simulation stays admissible inside actual internal multi-shot control" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const d = try fixture(c);
    const typed = horos.authoring;
    const author = try typed.Context.init(&b);
    const family = try horos.library.choice.family(author, "consumer.choice");
    const choice = .{ .effect = try typed.interop.operationId(author, family.effect()), .capability = try typed.interop.schemaId(author, family.capability()) };
    try registry.classify(choice.effect, .internal);
    const boolean = try b.scalar(bool);
    const pair = try b.schema(.{ .product = &.{ boolean, d.observation } });
    const simulator = try b.declare(&.{d.question}, d.data, &.{}, &.{});
    try b.define(simulator, try b.pure(try b.constant(u64, 42)));
    const simulator_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.question},
        .result = d.data,
    } } });
    const body = try b.declare(&.{choice.capability}, pair, &.{choice.effect}, &.{});
    const selected = try b.variable(boolean);
    const observed = try b.variable(d.observation);
    const simulated = try protean.observation.withSimulation(c, d, d.observation, try client(&b, d), try b.lambda(simulator, simulator_type), .{}, &.{});
    const done = try b.pure(try b.primitive(pair, .product, &.{ try b.reference(selected), try b.reference(observed) }, 0));
    const choose = try b.term(.{ .perform = .{
        .effect = choice.effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(body, try b.bind(selected, choose, try b.bind(observed, simulated, done)));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{choice.capability},
        .result = pair,
        .effects = &.{choice.effect},
        .use = .linear,
    } } });
    const choice_interpretation = try horos.library.choice.all(author, family, try typed.interop.schema(author, pair), .{ .captures = .{ .continuation = &.{ family.capability(), try author.scalar(bool) } }, .residual = &.{} });
    const search = .{ .handler = try typed.interop.handlerId(author, choice_interpretation.handler), .answer = try typed.interop.schemaId(author, choice_interpretation.answer) };
    const entry = try b.declare(&.{}, search.answer, &.{}, &.{});
    try b.define(entry, try b.term(.{ .handle = .{
        .handler = search.handler,
        .body = try b.lambda(body, body_type),
    } }));
    const expected = [_]u8{ 2, 0, 1, 42, 0, 0, 0, 0, 0, 0, 0, 1, 1, 42, 0, 0, 0, 0, 0, 0, 0 };
    _ = try execute(b.module(entry, try b.scalar(void)), &registry, &expected);
}

test "live evidence acquisition is excluded even from read-admitted speculation" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const d = try fixture(c);
    const entry = try b.declare(&.{}, d.data, &.{d.live_effect}, &.{});
    const evidence = try b.variable(d.evidence);
    const actual = try b.variable(d.data);
    const proof = try b.variable(d.proof);
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(evidence),
        .variables = &.{ actual, proof },
        .body = try protean.observation.consumeEvidence(c, d, entry, try b.reference(proof)),
    } });
    try b.define(entry, try b.bind(evidence, try protean.observation.readEvidence(c, d, entry, try b.constant(u64, 7)), unpack));
    try registry.speculate(entry, &.{d.live_effect});
    try std.testing.expectError(error.SpeculativeCapture, protean.admission.verify(std.testing.allocator, b.module(entry, try b.scalar(void)), &registry));
}
