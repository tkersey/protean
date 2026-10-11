//! Independent numeric decision oracle executed by unchanged native Kronos.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const kronos = @import("kronos");
const source = horos.source;
const clarification = protean.clarification;
const a = std.testing.allocator;
const Known = struct { candidate: u64, key: u64 };
const Assessed = union(enum) { known: Known, unavailable, rejected, inconclusive };
const Evaluation = struct { id: u64, assessed: Assessed };
const Group = struct { id: u64, known: Known, members: []const u64 };
const Choice = struct { reason: u8, groups: []const Group };
const Classification = union(enum) { common: Group, choice: Choice, unresolved: []const Evaluation };
const NonAction = union(enum) { incomplete: []const Evaluation, other, unsure, unoffered };
const Resolution = union(enum) {
    common: Group,
    selected: Group,
    unresolved: NonAction,
    aborted,
    closed,
};
const Input = struct { evaluations: []const Evaluation, mandatory: bool = false };

const Fixture = struct {
    compiled: source.Compiled,

    fn init(domain: clarification.Domain, select: bool) !Fixture {
        var b = source.Builder.init(a);
        defer b.deinit();
        const integer = try b.scalar(u64);
        const d = try clarification.define(&b, .{
            .identity = "test.numeric.clarification",
            .candidate = integer,
            .key = integer,
            .domain = domain,
            .failure = try b.constant(void, {}),
        });
        // Independent native wire types must match the exported source schemas.
        try std.testing.expectEqual(try protean.contracts.schema(Classification, &b), d.types.classification);
        const entry = if (select) d.select else d.classify;
        return .{ .compiled = try horos.program.compile(a, b.module(entry, try b.scalar(void))) };
    }

    fn deinit(f: *Fixture) void {
        f.compiled.deinit();
    }

    fn run(f: Fixture, comptime In: type, comptime Out: type, input: In) !protean.contracts.Decoded(Out) {
        const args = try protean.contracts.encodeOwned(In, a, input);
        defer a.free(args);
        const invocation_image_0 = try a.alloc(u8, try horos.data.program_image.encodedLength(f.compiled.program));
        defer a.free(invocation_image_0);
        _ = try horos.data.program_image.encode(a, f.compiled.program, invocation_image_0);
        var outcome = try kronos.invocation.invoke(a, .{
            .image = invocation_image_0,
            .instance = .{ .initial_args = args },
        });
        defer outcome.deinit();
        try std.testing.expect(outcome.record == .completed);
        return protean.contracts.decodeOwned(Out, a, outcome.record.completed);
    }

    fn classify(f: Fixture, input: Input) !protean.contracts.Decoded(Classification) {
        return f.run(Input, Classification, input);
    }
};

fn known(id: u64, key: u64) Evaluation {
    return .{ .id = id, .assessed = .{ .known = .{ .candidate = id * 10, .key = key } } };
}

test "complete domain agreement retains intent; explicit clarification overrides agreement" {
    var f = try Fixture.init(.{ .finite = &.{ 1, 2 } }, false);
    defer f.deinit();
    var common = try f.classify(.{ .evaluations = &.{ known(1, 100), known(2, 100) } });
    defer common.deinit();
    try std.testing.expect(common.value == .common);
    try std.testing.expectEqual(@as(u64, 1), common.value.common.id);
    try std.testing.expectEqual(@as(u64, 10), common.value.common.known.candidate);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, common.value.common.members);
    var mandatory = try f.classify(.{
        .evaluations = &.{ known(1, 100), known(2, 100) },
        .mandatory = true,
    });
    defer mandatory.deinit();
    try std.testing.expect(mandatory.value == .choice);
    try std.testing.expectEqual(@as(u8, 1), mandatory.value.choice.reason);
    try std.testing.expectEqual(@as(usize, 2), mandatory.value.choice.groups.len);
}

test "three hypotheses form two consequence classes under every permutation" {
    var f = try Fixture.init(.{ .finite = &.{ 1, 2, 3 } }, false);
    defer f.deinit();
    const values = [_]Evaluation{ known(1, 100), known(2, 100), known(3, 200) };
    const permutations = [_][3]usize{
        .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 },
        .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 },
    };
    for (permutations) |p| {
        var result = try f.classify(.{ .evaluations = &.{
            values[p[0]], values[p[1]], values[p[2]],
        } });
        defer result.deinit();
        try std.testing.expect(result.value == .choice);
        try std.testing.expectEqual(@as(u8, 0), result.value.choice.reason);
        try std.testing.expectEqual(@as(usize, 2), result.value.choice.groups.len);
        for (result.value.choice.groups) |group| {
            switch (group.id) {
                1 => {
                    try std.testing.expectEqual(@as(u64, 100), group.known.key);
                    try std.testing.expectEqual(@as(u64, 10), group.known.candidate);
                    try std.testing.expectEqual(@as(usize, 2), group.members.len);
                    try std.testing.expect(std.mem.indexOfScalar(u64, group.members, 1) != null);
                    try std.testing.expect(std.mem.indexOfScalar(u64, group.members, 2) != null);
                },
                3 => try std.testing.expectEqualSlices(u64, &.{3}, group.members),
                else => return error.UnexpectedGroup,
            }
        }
    }
}

test "empty, missing, duplicate, foreign, and non-Known results cannot become agreement" {
    var f = try Fixture.init(.{ .finite = &.{ 1, 2 } }, false);
    defer f.deinit();
    const cases = [_][]const Evaluation{
        &.{},                                                     &.{known(1, 100)},                                            &.{ known(1, 100), known(1, 100) },
        &.{ known(1, 100), known(3, 100) },                       &.{ known(1, 100), known(2, 100), known(3, 100) },            &.{ known(1, 100), .{ .id = 2, .assessed = .unavailable } },
        &.{ known(1, 100), .{ .id = 2, .assessed = .rejected } }, &.{ known(1, 100), .{ .id = 2, .assessed = .inconclusive } },
    };
    for (cases) |values| for ([_]bool{ false, true }) |mandatory| {
        var result = try f.classify(.{ .evaluations = values, .mandatory = mandatory });
        defer result.deinit();
        try std.testing.expect(result.value == .unresolved);
        try std.testing.expectEqual(values.len, result.value.unresolved.len);
    };
}

test "equal open samples require a qualified choice; invalid samples remain unresolved" {
    var f = try Fixture.init(.open, false);
    defer f.deinit();
    var result = try f.classify(.{ .evaluations = &.{ known(1, 100), known(2, 100) } });
    defer result.deinit();
    try std.testing.expect(result.value == .choice);
    try std.testing.expectEqual(@as(u8, 2), result.value.choice.reason);
    try std.testing.expectEqual(@as(usize, 1), result.value.choice.groups.len);
    var invalid = try f.classify(.{ .evaluations = &.{ known(1, 100), known(1, 100) } });
    defer invalid.deinit();
    try std.testing.expect(invalid.value == .unresolved);
}

test "selection accepts offered group IDs and rejects an unoffered member or foreign ID" {
    var f = try Fixture.init(.{ .finite = &.{ 1, 2, 3 } }, true);
    defer f.deinit();
    const groups = [_]Group{
        .{ .id = 1, .known = .{ .candidate = 10, .key = 100 }, .members = &.{ 1, 2 } },
        .{ .id = 3, .known = .{ .candidate = 30, .key = 200 }, .members = &.{3} },
    };
    const Select = struct { groups: []const Group, id: u64 };
    for ([_]u64{ 1, 2, 3, 4 }) |id| {
        var result = try f.run(Select, Resolution, .{ .groups = &groups, .id = id });
        defer result.deinit();
        if (id == 1 or id == 3) {
            try std.testing.expect(result.value == .selected);
            try std.testing.expectEqual(id * 10, result.value.selected.known.candidate);
        } else try std.testing.expect(result.value == .unresolved);
    }
}

const Id = source.Id;
const NumericModel = protean.model(.{
    .name = "clarification-numeric-test",
    .model = "fixture-model",
    .protocol = struct {
        pub const semantic_identity = "agent.model.protocol.openai-responses-v2";
    },
});
const NumericAction = union(enum) { score: struct { value: u64 } };
const P = protean.model_invocation.Profile(NumericAction, .{.{ .name = "score", .description = "Assess the numeric alternative." }}, .{
    .model_id_bytes = 32,
    .temperature_bytes = 8,
    .maximum_messages = 4,
    .message_bytes = 64,
    .maximum_output_items = 4,
    .call_id_bytes = 32,
    .arguments_json_bytes = 256,
    .result_text_bytes = 64,
    .provider_response_bytes = 4096,
});
const Composition = struct {
    compiled: source.Compiled,
    source_functions: usize,
    source_terms: usize,

    fn init(allocator: std.mem.Allocator, count: usize) !Composition {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const c = protean.Context{ .builder = &b, .registry = &registry };
        const unit = try b.scalar(void);
        const integer = try b.scalar(u64);
        const ids = try b.schema(.{ .seq = integer });
        const model = try P.declare(&b);
        try registry.classify(model, .model);
        const region = b.region();
        const region_type = try b.schema(.{ .internal = .{ .region = region } });
        const cell = try b.schema(.{ .internal = .{ .cell = .{
            .element = integer,
            .region = region,
        } } });
        const domain = try b.allocator().alloc(u64, count);
        for (domain, 1..) |*id, value| id.* = value;
        const d = try clarification.define(&b, .{
            .identity = "test.clarification.multi",
            .candidate = integer,
            .key = integer,
            .domain = .{ .finite = domain },
            .failure = try b.constant(void, {}),
            .scope = .{
                .captures = &.{ unit, integer, ids, cell },
                .owned_regions = &.{region},
                .residual = .{ .effects = &.{model} },
            },
        });
        const exchange = try protean.interaction.define(&b, .{
            .name = "test.clarification.choice",
            .channel = unit,
            .purpose = unit,
            .presentation = unit,
            .outgoing = try b.schema(.{ .product = &.{ integer, d.types.choice } }),
            .input = d.types.input,
            .abort_turn = unit,
            .close_conversation = unit,
        });
        try registry.classify(exchange.effect, .interaction);
        const entry = try b.declare(&.{ integer, ids }, d.types.resolution, &.{ model, exchange.effect }, &.{});
        const body = try capturedBody(c, d, entry, model, region, region_type, cell);
        const resolve = try compositionResolver(&b, d, exchange);
        const classified = try b.variable(d.types.classification);
        const next = try call(&b, resolve, &.{
            try b.reference(b.parameter(entry, 0)), try b.reference(classified),
        });
        try b.define(entry, try b.bind(classified, try clarification.explore(c, d, body, &.{}, try b.constant(bool, false)), next));
        const module = b.module(entry, unit);
        try protean.admission.verify(allocator, module, &registry);
        return .{
            .compiled = try horos.program.compile(allocator, module),
            .source_functions = b.functions.items.len,
            .source_terms = b.terms.items.len,
        };
    }
};

fn compositionResolver(b: *source.Builder, d: clarification.Definition, exchange: protean.interaction.Definition) !Id {
    const integer = try b.scalar(u64);
    const present = try b.declare(&.{ integer, d.types.choice }, exchange.contract.outgoing, &.{}, &.{});
    try b.define(present, try b.pure(try b.primitive(exchange.contract.outgoing, .product, &.{
        try b.reference(b.parameter(present, 0)), try b.reference(b.parameter(present, 1)),
    }, 0)));
    return clarification.resolver(b, d, .{
        .context = integer,
        .present = present,
        .exchange = exchange,
        .channel = try b.constant(void, {}),
        .purpose = try b.constant(void, {}),
        .presentation = try b.constant(void, {}),
    });
}

fn capturedBody(c: protean.Context, d: clarification.Definition, entry: Id, model: Id, region: Id, region_type: Id, cell_type: Id) !Id {
    const b = c.builder;
    const integer = try b.scalar(u64);
    const ids = try b.schema(.{ .seq = integer });
    const effects = &.{ model, d.multi.effect };
    const body = try b.declare(&.{d.multi.capability}, d.types.evaluation, effects, &.{});
    const inside = try b.declare(&.{region_type}, d.types.evaluation, effects, &.{region});
    const cell = try b.variable(cell_type);
    const prefix = try b.variable(integer);
    const choice = try b.variable(integer);
    const before = try b.variable(integer);
    const stored = try b.variable(try b.scalar(void));
    const reply = try b.variable(integer);
    const select = try protean.deliberation.choose(b, d.multi, try b.reference(b.parameter(body, 0)), try b.reference(b.parameter(entry, 1)));
    const read_cell = try b.primitive(integer, .cell_get, &.{try b.reference(cell)}, 0);
    const interpreted = try b.variable(try c.schema(P.Interpretation));
    const accepted = try b.variable(try c.schema(NumericAction));
    const rejected = try b.variable(try c.schema(P.InterpretationFailure));
    const action = try b.variable(try c.schema(@FieldType(NumericAction, "score")));
    const request = try numericRequest(c, &.{
        try b.reference(prefix), try b.reference(choice), try b.reference(before),
    });
    const perform = try protean.responders.invokeModel(P, c, d.failure, false, request, try c.literal([1]bool, .{true}));
    const value = try b.primitive(integer, .field, &.{try b.reference(action)}, 0);
    const after = try b.bind(reply, try b.pure(value), try nonTailAssessment(b, d, reply, before, choice, read_cell));
    const chosen = try b.term(.{ .match_sum = .{
        .value = try b.reference(accepted),
        .cases = &.{.{ .variable = action, .body = after }},
    } });
    const unavailable = try b.primitive(d.types.evaluation, .product, &.{
        try b.reference(choice), try b.primitive(d.types.assessed, .variant, &.{try b.constant(void, {})}, 1),
    }, 0);
    const checked = try b.term(.{ .match_sum = .{
        .value = try b.reference(interpreted),
        .cases = &.{
            .{ .variable = accepted, .body = chosen },
            .{ .variable = rejected, .body = try b.pure(unavailable) },
        },
    } });
    const set = try b.primitive(try b.scalar(void), .cell_set, &.{
        try b.reference(cell), try b.reference(choice),
    }, 0);
    const branch = try b.bind(choice, select, try b.bind(before, try b.pure(read_cell), try b.bind(stored, try b.pure(set), try b.bind(interpreted, perform, checked))));
    const new = try b.primitive(cell_type, .cell_new, &.{
        try b.reference(b.parameter(inside, 0)), try b.constant(u64, 11),
    }, 0);
    try b.define(inside, try b.bind(cell, try b.pure(new), try b.bind(prefix, try b.pure(try b.reference(b.parameter(entry, 0))), branch)));
    const inside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region_type},
        .result = d.types.evaluation,
        .effects = effects,
        .capture_bound = &.{ integer, ids, d.multi.capability },
        .regions = &.{region},
    } } });
    try b.define(body, try b.term(.{ .with_region = .{
        .region = region,
        .body = try b.lambda(inside, inside_type),
    } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{d.multi.capability},
        .result = d.types.evaluation,
        .effects = effects,
        .capture_bound = &.{ integer, ids },
    } } });
    return b.lambda(body, body_type);
}

fn nonTailAssessment(b: *source.Builder, d: clarification.Definition, reply: Id, before: Id, choice: Id, cell: Id) !Id {
    const integer = try b.scalar(u64);
    const value = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ try b.reference(reply), try b.reference(before) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(d.failure),
        }},
    } } });
    const evaluated = try b.primitive(d.types.evaluation, .product, &.{
        try b.reference(choice),
        try b.primitive(d.types.assessed, .variant, &.{
            try b.primitive(d.types.known, .product, &.{ value, value }, 0),
        }, 0),
    }, 0);
    const is_current = try b.primitive(try b.scalar(bool), .equal, &.{ cell, try b.reference(choice) }, 0);
    return b.term(.{ .conditional = .{
        .condition = is_current,
        .when_true = try b.pure(evaluated),
        .when_false = try b.term(.{ .fail = d.failure }),
    } });
}

fn call(b: *source.Builder, function: Id, arguments: []const Id) !Id {
    return b.term(.{ .call = .{ .function = function, .arguments = arguments } });
}

fn respond(outcome: *kronos.invocation.Outcome, program: horos.data.activation.Program, comptime T: type, value: T, statistics: ?*kronos.Statistics) !void {
    const protocol = horos.data.invocation;
    var request_owner_0 = try protocol.decode(protocol.Request, a, outcome.record.requested.request);
    defer request_owner_0.deinit();
    const request = request_owner_0.value;
    const bytes = try protean.contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    const result = protocol.Result{
        .request_identity = request.request_identity,

        .value = bytes,
    };
    const encoded = try a.alloc(u8, try protocol.encodedLength(protocol.Result, result));
    defer a.free(encoded);
    _ = try protocol.encode(protocol.Result, a, result, encoded);
    const invocation_image_1 = try a.alloc(u8, try horos.data.program_image.encodedLength(program));
    defer a.free(invocation_image_1);
    _ = try horos.data.program_image.encode(a, program, invocation_image_1);
    const next = observed: {
        const instance: horos.data.invocation.Instance = .{ .state = outcome.record.requested.state.? };
        var session = switch (instance) {
            .initial_args => |initial| try kronos.Session.initImage(a, invocation_image_1, initial),
            .state => |state| try kronos.Session.restoreImage(a, invocation_image_1, state),
        };
        defer session.deinit();
        session.statistics = statistics;
        if (statistics) |observed_statistics| session.store.statistics = &observed_statistics.storage;
        _ = try kronos.invocation.advance(&session, .{ .reply = encoded }, null);
        break :observed try kronos.invocation.finish(a, &session, true);
    };
    outcome.deinit();
    outcome.* = next;
}

test "protected composition resumes captured futures, groups non-tail results, and retains choices" {
    var f = try Composition.init(a, 2);
    defer f.compiled.deinit();
    const Initial = struct { context: u64, ids: []const u64 };
    const args = try protean.contracts.encodeOwned(Initial, a, .{ .context = 77, .ids = &.{ 1, 2 } });
    defer a.free(args);
    for ([_]bool{ false, true }) |divergent| {
        var statistics: kronos.Statistics = .{};
        const invocation_image_2 = try a.alloc(u8, try horos.data.program_image.encodedLength(f.compiled.program));
        defer a.free(invocation_image_2);
        _ = try horos.data.program_image.encode(a, f.compiled.program, invocation_image_2);
        var outcome = observed: {
            const instance: horos.data.invocation.Instance = .{ .initial_args = args };
            var session = switch (instance) {
                .initial_args => |initial| try kronos.Session.initImage(a, invocation_image_2, initial),
                .state => |state| try kronos.Session.restoreImage(a, invocation_image_2, state),
            };
            defer session.deinit();
            session.statistics = &statistics;
            session.store.statistics = &statistics.storage;
            _ = try kronos.invocation.advance(&session, .none, null);
            break :observed try kronos.invocation.finish(a, &session, true);
        };
        defer outcome.deinit();
        for (1..3) |id| {
            try std.testing.expect(outcome.record == .requested);
            var graph = try horos.data.state_image.decodeGraph(a, outcome.record.requested.state.?);
            defer graph.deinit();
            var templates: usize = 0;
            var cells: usize = 0;
            for (graph.state.nodes) |node| switch (node.record) {
                .multi_template => templates += 1,
                .cell => cells += 1,
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), templates);
            try std.testing.expectEqual(@as(usize, 2), cells);
            var decoded_request_0 = try horos.data.invocation.decode(
                horos.data.invocation.Request,
                a,
                outcome.record.requested.request,
            );
            defer decoded_request_0.deinit();
            const request = decoded_request_0.value;
            var received = try protean.contracts.decodeOwned(P.Request, a, request.binding.payload);
            defer received.deinit();
            const messages = received.value.messages.items;
            try std.testing.expectEqual(@as(usize, 3), messages.len);
            try std.testing.expectEqualStrings("77", messages[0].content.bytes);
            try std.testing.expectEqualStrings(if (id == 1) "1" else "2", messages[1].content.bytes);
            try std.testing.expectEqualStrings("11", messages[2].content.bytes);
            const value: u64 = if (divergent) id else 40;
            const json = try a.print("{{\"value\":{d}}}", .{value});
            defer a.free(json);
            const items = [_]P.OutputItem{.{ .function_call = .{
                .call_id = .{ .bytes = "fixture" },
                .name = .{ .bytes = "score" },
                .arguments_json = .{ .bytes = json },
                .tool_ordinal_claim = 0,
                .decoded_action = .{ .decoded = .{ .score = .{ .value = value } } },
            } }};
            try respond(&outcome, f.compiled.program, P.Result, .{ .output = .{
                .items = .{ .items = &items },
                .normalized_output_digest = @as([32]u8, @splat(0)),
            } }, &statistics);
        }
        if (divergent) {
            try std.testing.expect(outcome.record == .requested);
            var decoded_request_1 = try horos.data.invocation.decode(
                horos.data.invocation.Request,
                a,
                outcome.record.requested.request,
            );
            defer decoded_request_1.deinit();
            const request = decoded_request_1.value;
            const Outgoing = struct { context: u64, choice: Choice };
            var question = try protean.contracts.decodeOwned(Outgoing, a, request.binding.payload);
            defer question.deinit();
            try std.testing.expectEqual(@as(u64, 77), question.value.context);
            try std.testing.expectEqual(@as(usize, 2), question.value.choice.groups.len);
            const Answer = union(enum) { select: u64, other, unsure };
            const Reply = union(enum) { input: Answer, abort_turn, close };
            try respond(&outcome, f.compiled.program, Reply, .{ .input = .{ .select = 2 } }, &statistics);
        }
        try std.testing.expect(outcome.record == .completed);
        try std.testing.expectEqual(@as(u64, 1), statistics.multi_templates);
        try std.testing.expectEqual(@as(u64, 2), statistics.branch_activations);
        var done = try protean.contracts.decodeOwned(Resolution, a, outcome.record.completed);
        defer done.deinit();
        if (divergent) {
            try std.testing.expect(done.value == .selected);
            try std.testing.expectEqual(@as(u64, 13), done.value.selected.known.candidate);
        } else {
            try std.testing.expect(done.value == .common);
            try std.testing.expectEqual(@as(u64, 51), done.value.common.known.candidate);
            try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, done.value.common.members);
        }
    }
}

fn numericRequest(c: protean.Context, values: []const Id) !Id {
    const b = c.builder;
    const template = try P.templateValue(NumericModel, .{ .items = &.{} }, .{
        .minimum_calls = 1,
        .maximum_calls = 1,
        .parallel_calls = false,
    });
    const messages = try b.allocator().alloc(Id, values.len);
    for (messages, values) |*message, value| {
        const text = try b.primitive(try b.schema(.text), .text_integer, &.{value}, 0);
        const bounded = try b.value(.{
            .schema = try c.schema(P.MessageText),
            .expression = .{ .primitive = .{
                .opcode = .blob_concat,
                .operands = &.{
                    try c.literal(P.MessageText, .{ .bytes = "" }), text,
                },
                .failures = &.{.{ .kind = .capacity_exceeded, .value = try b.failureLiteral(try b.constant(void, {})) }},
            } },
        });
        message.* = try b.primitive(try c.schema(P.Message), .product, &.{
            try c.literal(protean.model_invocation.MessageRole, .user), bounded,
        }, 0);
    }
    var fields: [@typeInfo(P.Request).@"struct".field_names.len]Id = undefined;
    inline for (@typeInfo(P.Request).@"struct".field_names, @typeInfo(P.Request).@"struct".field_types, 0..) |field_name, FieldType, i| {
        fields[i] = if (i == 3) try b.primitive(try c.schema(P.Messages), .sequence, messages, 0) else try c.literal(FieldType, @field(template, field_name));
    }
    return b.primitive(try c.schema(P.Request), .product, &fields, 0);
}

test "equal scores cannot conceal different operative keys" {
    var f = try Fixture.init(.{ .finite = &.{ 1, 2 } }, false);
    defer f.deinit();
    var result = try f.classify(.{ .evaluations = &.{
        .{ .id = 1, .assessed = .{ .known = .{ .candidate = 42, .key = 100 } } },
        .{ .id = 2, .assessed = .{ .known = .{ .candidate = 42, .key = 200 } } },
    } });
    defer result.deinit();
    try std.testing.expect(result.value == .choice);
}

test "one authored proposal body serves a growing declared domain" {
    for ([_]usize{ 1, 2, 3, 8 }) |count| try growingDomain(count);
}

fn growingDomain(count: usize) !void {
    var f = try Composition.init(a, count);
    defer f.compiled.deinit();
    const ids = try a.alloc(u64, count);
    defer a.free(ids);
    for (ids, 1..) |*id, value| id.* = value;
    const Initial = struct { context: u64, ids: []const u64 };
    const args = try protean.contracts.encodeOwned(Initial, a, .{ .context = 99, .ids = ids });
    defer a.free(args);
    var statistics: kronos.Statistics = .{};
    const invocation_image_3 = try a.alloc(u8, try horos.data.program_image.encodedLength(f.compiled.program));
    defer a.free(invocation_image_3);
    _ = try horos.data.program_image.encode(a, f.compiled.program, invocation_image_3);
    var outcome = observed: {
        const instance: horos.data.invocation.Instance = .{ .initial_args = args };
        var session = switch (instance) {
            .initial_args => |initial| try kronos.Session.initImage(a, invocation_image_3, initial),
            .state => |state| try kronos.Session.restoreImage(a, invocation_image_3, state),
        };
        defer session.deinit();
        session.statistics = &statistics;
        session.store.statistics = &statistics.storage;
        _ = try kronos.invocation.advance(&session, .none, null);
        break :observed try kronos.invocation.finish(a, &session, true);
    };
    defer outcome.deinit();
    var calls: usize = 0;
    var peak: usize = 0;
    const items = [_]P.OutputItem{.{ .function_call = .{
        .call_id = .{ .bytes = "fixture" },
        .name = .{ .bytes = "score" },
        .arguments_json = .{ .bytes = "{\"value\":40}" },
        .tool_ordinal_claim = 0,
        .decoded_action = .{ .decoded = .{ .score = .{ .value = 40 } } },
    } }};
    while (outcome.record == .requested) {
        calls += 1;
        try std.testing.expect(calls <= count);
        peak = @max(peak, outcome.record.requested.state.?.len);
        var decoded_request_2 = try horos.data.invocation.decode(
            horos.data.invocation.Request,
            a,
            outcome.record.requested.request,
        );
        defer decoded_request_2.deinit();
        const request = decoded_request_2.value;
        try std.testing.expectEqualStrings(protean.model_invocation.semantic_identity, request.binding.semantic_identity);
        var context = try protean.contracts.decodeOwned(P.Request, a, request.binding.payload);
        defer context.deinit();
        try std.testing.expectEqualStrings("99", context.value.messages.items[0].content.bytes);
        try std.testing.expectEqualStrings("11", context.value.messages.items[2].content.bytes);
        try respond(&outcome, f.compiled.program, P.Result, .{ .output = .{
            .items = .{ .items = &items },
            .normalized_output_digest = @as([32]u8, @splat(0)),
        } }, &statistics);
    }
    try std.testing.expect(outcome.record == .completed);
    try std.testing.expectEqual(count, calls);
    try std.testing.expectEqual(@as(u64, 1), statistics.multi_templates);
    try std.testing.expectEqual(count, statistics.branch_activations);
    var result = try protean.contracts.decodeOwned(Resolution, a, outcome.record.completed);
    defer result.deinit();
    try std.testing.expect(result.value == .common);
    try std.testing.expectEqualSlices(u64, ids, result.value.common.members);
    try std.testing.expectEqual(@as(u64, 51), result.value.common.known.candidate);
    std.debug.print("clarification hypotheses={d} templates={d} activations={d} " ++
        "pending_peak={d} result_bytes={d}\n", .{
        count, statistics.multi_templates,   statistics.branch_activations,
        peak,  outcome.record.completed.len,
    });
}
