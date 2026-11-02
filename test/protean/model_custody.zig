const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kosmos = @import("kosmos");
const contracts = protean.contracts;
const model = protean.model_invocation;
const source = horos.source;
const data = horos.data;
const allocator = std.testing.allocator;

const Answer = union(enum(u32)) {
    choose: struct { value: u64 } = 9,
    other: struct { value: u64 } = 31,
};
const P = model.Profile(Answer, .{
    .{ .name = "choose", .description = "Choose a value." },
    .{ .name = "other", .description = "Offer another value." },
}, .{
    .model_id_bytes = 32,
    .temperature_bytes = 8,
    .maximum_messages = 4,
    .message_bytes = 128,
    .maximum_output_items = 8,
    .call_id_bytes = 32,
    .arguments_json_bytes = 256,
    .result_text_bytes = 128,
    .provider_response_bytes = 4096,
});
const Input = struct { request: P.AdaptiveRequest, offered: [2]bool };
const PairInput = struct { first: Input, second: Input };
const PairResult = struct { first: P.Interpretation, second: P.Interpretation };
const single: model.Selection = .{
    .minimum_calls = 1,
    .maximum_calls = 1,
    .parallel_calls = false,
};
const batch: model.Selection = .{
    .minimum_calls = 1,
    .maximum_calls = 4,
    .parallel_calls = true,
};

fn invocation(tools: []const P.ToolDeclaration, selection: model.Selection) P.Request {
    return .{
        .protocol = .{ .bytes = model.protocol_identity },
        .model = .{ .bytes = "custody-model" },
        .parameters = .{
            .max_output_tokens = 777,
            .temperature = .{ .bytes = "0.125" },
            .reasoning = .{ .effort = .low, .summary = .concise },
        },
        .messages = .{ .items = &.{
            .{ .role = .system, .content = .{ .bytes = "Retain these instructions." } },
            .{ .role = .user, .content = .{ .bytes = "Choose a typed answer." } },
        } },
        .tools = .{ .items = tools },
        .selection = selection,
        .response_policy = .{
            .store = false,
            .stream = false,
            .background = false,
            .truncation = .disabled,
        },
        .normalization_limits = P.normalizationLimits(),
        .maximum_provider_response_bytes = 3072,
    };
}

fn template(tools: []const P.ToolDeclaration, selection: model.Selection) P.AdaptiveRequest {
    return .{
        .invocation = invocation(tools, selection),
        .policy = @splat(9),
        .selection = .{
            .profile_id = .{ .bytes = "fixture" },
            .profile_digest = @splat(7),
            .effective_effort = .low,
            .control_revision = 0,
        },
        .plan = .{
            .epoch = 0,
            .reason = .initial,
            .watermark = 0,
            .eviction_generation = 0,
            .prior = null,
            .catalog = .{ .digest = @splat(5), .bytes = 1 },
            .skills = .{ .items = &.{} },
        },
        .materialized = @splat(true),
        .offered = @splat(true),
        .results = .{ .items = &.{} },
    };
}

fn compileModel(comptime Q: type, comptime multiple: bool) !source.Compiled {
    return compileResponder(Q, multiple, false);
}

fn compileResponder(
    comptime Q: type,
    comptime multiple: bool,
    comptime observed: bool,
) !source.Compiled {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const context = try protean.Context.init(&b, &registry);
    const failure = try context.literal(void, {});
    const define = if (observed)
        protean.responders.defineModelObserved
    else
        protean.responders.defineModel;
    const entry_handle = try define(Q, context, failure, multiple);
    const entry = try horos.authoring.interop.functionId(context.author, entry_handle);
    const shared = try define(Q, context, failure, multiple);
    try std.testing.expectEqual(entry_handle, shared);
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    return horos.program.compile(allocator, module);
}

test "protected Protean source rejects raw model emission with forged request-time offers" {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const context = try protean.Context.init(&b, &registry);
    const effect = try horos.authoring.interop.operationId(context.author, try P.declare(context));
    const entry = try b.declare(&.{
        try contracts.schema(P.AdaptiveRequest, &b),
    }, try contracts.schema(P.Interpretation, &b), &.{effect}, &.{});
    const normalized = try b.variable(try contracts.schema(P.AdaptiveResult, &b));
    const request = try b.reference(b.parameter(entry, 0));
    const raw = try b.term(.{ .perform = .{ .effect = effect, .payload = request } });
    const forged = try b.term(.{ .call = .{
        .function = try horos.authoring.interop.functionId(
            context.author,
            try P.interpreter(context),
        ),
        .arguments = &.{
            try b.primitive(
                try contracts.schema(P.Result, &b),
                .field,
                &.{try b.reference(normalized)},
                0,
            ),
            try horos.authoring.interop.valueId(
                context.author,
                try context.literal([2]bool, .{ true, true }),
            ),
            try horos.authoring.interop.valueId(
                context.author,
                try context.literal(model.Selection, single),
            ),
        },
    } });
    try b.define(entry, try b.bind(normalized, raw, forged));
    const module = b.module(entry, try b.scalar(void));
    // Valid public Horos source may choose another policy. It cannot acquire
    // Protean's offer-custody claim merely by invoking the pure candidate decoder.
    var raw_compiled = try horos.program.compile(allocator, module);
    defer raw_compiled.deinit();
    try std.testing.expectError(
        error.ProtectedEffectBypass,
        protean.admission.verify(allocator, module, &registry),
    );
}

test "reserved model identity cannot evade custody by omitted or read classification" {
    inline for (.{
        @as(?protean.admission.Role, null),
        @as(?protean.admission.Role, .read),
    }) |role| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const effect = try P.source.declare(&b);
        if (role) |classification| try registry.classify(effect, classification);
        const entry = try b.declare(&.{
            try contracts.schema(P.AdaptiveRequest, &b),
        }, try contracts.schema(P.AdaptiveResult, &b), &.{effect}, &.{});
        try b.define(entry, try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.reference(b.parameter(entry, 0)),
        } }));
        const module = b.module(entry, try b.scalar(void));
        var raw = try horos.program.compile(allocator, module);
        defer raw.deinit();
        try std.testing.expectError(
            error.EffectRoleMismatch,
            protean.admission.verify(allocator, module, &registry),
        );
    }
}

test "observed model result preserves normalized provenance and typed recovery details" {
    const Observation = protean.responders.ModelObservation(P, false);
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const context = try protean.Context.init(&b, &registry);
    const failure = try context.literal(void, {});
    const entry_handle = try protean.responders.defineModelObserved(P, context, failure, false);
    const entry = try horos.authoring.interop.functionId(context.author, entry_handle);
    _ = try protean.responders.defineModel(P, context, failure, false);
    // The convenience projection reuses the same checked model-emission owner.
    try std.testing.expectEqual(1, registry.sites.items.len);
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const value: Input = .{ .request = template(&.{}, single), .offered = .{ true, false } };
    var parked = try start(compiled.program, value);
    defer parked.deinit();
    try expectRequest(parked, value);
    const success = result(&.{
        .{ .reasoning = .{ .summary = .{ .bytes = "A declared summary." } } },
        call(.choose, 42),
        .{ .message = .{ .role = .assistant, .content = .{ .bytes = "Keep this observation." } } },
    });
    var observed = try finish(Observation, compiled.program, parked, success);
    defer observed.deinit();
    try std.testing.expectEqual(42, observed.value.interpretation.accepted.choose.value);
    try expectNormalized(success, observed.value.normalized.result);
    const Case = struct { reply: P.Result, rejection: P.InterpretationFailure };
    const cases = [_]Case{
        .{ .reply = result(&.{call(.other, 73)}), .rejection = .unoffered },
        .{
            .reply = .{ .refusal = .{ .bytes = "The full refusal reason." } },
            .rejection = .refusal,
        },
        .{ .reply = .{ .transport_failure = .interrupted }, .rejection = .transport },
        .{ .reply = .{ .transport_failure = .unavailable }, .rejection = .transport },
        .{
            .reply = .{ .provider_failure = .{ .kind = .http_status, .http_status = 503 } },
            .rejection = .provider,
        },
        .{
            .reply = .{ .provider_failure = .{ .kind = .response_incomplete, .http_status = 0 } },
            .rejection = .provider,
        },
        .{ .reply = .{ .unsupported_response = .invalid_utf8 }, .rejection = .unsupported },
    };
    for (cases) |case| {
        var rejected = try finish(Observation, compiled.program, parked, case.reply);
        defer rejected.deinit();
        try std.testing.expectEqual(case.rejection, rejected.value.interpretation.rejected);
        try expectNormalized(case.reply, rejected.value.normalized.result);
    }
}

fn expectNormalized(expected: P.Result, actual: P.Result) !void {
    const expected_bytes = try contracts.encodeOwned(P.Result, allocator, expected);
    defer allocator.free(expected_bytes);
    const actual_bytes = try contracts.encodeOwned(P.Result, allocator, actual);
    defer allocator.free(actual_bytes);
    try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
}

fn start(program: data.activation.Program, value: Input) !kosmos.invocation.Outcome {
    const bytes = try contracts.encodeOwned(Input, allocator, value);
    defer allocator.free(bytes);
    const invocation_image_0 = try allocator.alloc(
        u8,
        try horos.data.program_image.encodedLength(program),
    );
    defer allocator.free(invocation_image_0);
    _ = try horos.data.program_image.encode(allocator, program, invocation_image_0);
    return kosmos.invocation.invoke(allocator, .{
        .image = invocation_image_0,
        .instance = .{ .initial_args = bytes },
    });
}

fn expectRequest(outcome: kosmos.invocation.Outcome, value: Input) !void {
    try std.testing.expect(outcome.record == .requested);
    var request_owner_0 = try data.invocation.decode(
        data.invocation.Request,
        allocator,
        outcome.record.requested.request,
    );
    defer request_owner_0.deinit();
    const request = request_owner_0.value;
    try std.testing.expectEqualStrings(model.semantic_identity, request.binding.semantic_identity);
    var expected = value.request;
    expected.invocation.tools = try P.declarationsValue(allocator, value.request.materialized);
    defer allocator.free(expected.invocation.tools.items);
    expected.offered = value.offered;
    const expected_bytes = try contracts.encodeOwned(P.AdaptiveRequest, allocator, expected);
    defer allocator.free(expected_bytes);
    // Comparing the complete payload also checks parameters, message order,
    // selection, response policy, and normalization/representation limits.
    try std.testing.expectEqualSlices(u8, expected_bytes, request.binding.payload);
}

fn call(comptime name: std.meta.Tag(Answer), value: u64) P.OutputItem {
    return .{
        .function_call = .{
            .call_id = .{ .bytes = if (name == .choose) "first-call" else "second-call" },
            .name = .{ .bytes = @tagName(name) },
            .arguments_json = .{
                .bytes = switch (value) {
                    42 => "{\"value\":42}",
                    73 => "{\"value\":73}",
                    else => unreachable, // Values in this finite fixture.
                },
            },
            .tool_ordinal_claim = if (name == .choose) 0 else 1,
            .decoded_action = .{
                .decoded = @unionInit(Answer, @tagName(name), .{ .value = value }),
            },
        },
    };
}

fn result(items: []const P.OutputItem) P.Result {
    return .{ .output = .{
        .items = .{ .items = items },
        .normalized_output_digest = @as([32]u8, @splat(0)),
    } };
}

fn resumeResult(
    comptime Result: type,
    program: data.activation.Program,
    parked: kosmos.invocation.Outcome,
    reply: Result,
) !kosmos.invocation.Outcome {
    try std.testing.expect(parked.record == .requested);
    var request_owner_1 = try data.invocation.decode(
        data.invocation.Request,
        allocator,
        parked.record.requested.request,
    );
    defer request_owner_1.deinit();
    const request = request_owner_1.value;
    const value = if (Result == P.Result) try contracts.encodeOwned(P.AdaptiveResult, allocator, .{
        .result = reply,
        .replay = null,
        .replay_status = .complete,
        .usage = null,
    }) else try contracts.encodeOwned(Result, allocator, reply);
    defer allocator.free(value);
    const bound: data.invocation.Result = .{
        .request_identity = request.request_identity,

        .value = value,
    };
    const length = try data.invocation.encodedLength(data.invocation.Result, bound);
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    _ = try data.invocation.encode(data.invocation.Result, allocator, bound, bytes);
    const invocation_image_1 = try allocator.alloc(
        u8,
        try horos.data.program_image.encodedLength(program),
    );
    defer allocator.free(invocation_image_1);
    _ = try horos.data.program_image.encode(allocator, program, invocation_image_1);
    return kosmos.invocation.invoke(allocator, .{
        .image = invocation_image_1,
        .instance = .{ .state = parked.record.requested.state.? },
        .control = .{ .reply = bytes },
    });
}

fn finish(
    comptime T: type,
    program: data.activation.Program,
    parked: kosmos.invocation.Outcome,
    reply: P.Result,
) !contracts.Decoded(T) {
    var outcome = try resumeResult(P.Result, program, parked, reply);
    defer outcome.deinit();
    try std.testing.expect(outcome.record == .completed);
    return contracts.decodeOwned(T, allocator, outcome.record.completed);
}

test "model responder derives held offers and preserves the complete semantic request" {
    var compiled = try compileModel(P, false);
    defer compiled.deinit();
    var forged = P.allDeclarations().items[0..2].*;
    for (&forged) |*declaration| {
        declaration.name.bytes = "bogus";
        declaration.action_ordinal = 99;
        declaration.action_tag = 17;
        declaration.input_schema_json.bytes = "{}";
        declaration.strict = false;
    }
    // Both invocations execute the same image; the input changes the offered set.
    inline for (.{ @as([2]bool, .{ true, false }), @as([2]bool, .{ false, true }) }) |offered| {
        const value: Input = .{ .request = template(&forged, single), .offered = offered };
        const bytes = try contracts.encodeOwned(Input, allocator, value);
        defer allocator.free(bytes);
        const invocation_image_2 = try allocator.alloc(
            u8,
            try horos.data.program_image.encodedLength(compiled.program),
        );
        defer allocator.free(invocation_image_2);
        _ = try horos.data.program_image.encode(allocator, compiled.program, invocation_image_2);
        var parked = try kosmos.invocation.invoke(allocator, .{
            .image = invocation_image_2,
            .instance = .{ .initial_args = bytes },
        });
        defer parked.deinit();
        // PST2 owns the suspended call. Caller storage is no longer its source.
        @memset(bytes, 0xa5);
        try expectRequest(parked, value);
        const answer = call(if (offered[0]) .choose else .other, 42);
        var observed = try finish(P.Interpretation, compiled.program, parked, result(&.{answer}));
        defer observed.deinit();
        try std.testing.expectEqual(42, if (offered[0])
            observed.value.accepted.choose.value
        else
            observed.value.accepted.other.value);
    }
}

test "dynamic normalization bounds preserve reply-schema compatibility before model I/O" {
    inline for (.{ false, true }) |multiple| {
        var compiled = try compileModel(P, multiple);
        defer compiled.deinit();
        inline for (.{
            "maximum_output_items",    "maximum_call_id_bytes",     "maximum_name_bytes",
            "maximum_arguments_bytes", "maximum_result_text_bytes",
        }) |field| {
            try checkNormalizationField(compiled.program, field);
        }
        try checkIndependentLimits(compiled.program);
    }
}

test "model responder rejects forged names variants ordinals and a later caller offer change" {
    var compiled = try compileModel(P, false);
    defer compiled.deinit();
    var value: Input = .{
        .request = template(P.allDeclarations().items, single),
        .offered = .{ true, false },
    };
    var parked = try start(compiled.program, value);
    defer parked.deinit();
    try expectRequest(parked, value);
    value.offered = .{ false, true };
    const failures = [_]P.InterpretationFailure{
        .declaration_mismatch, .declaration_mismatch, .declaration_mismatch,
        .unoffered,            .invalid_arguments,
    };
    var cases = @as([failures.len]P.OutputItem, @splat(call(.choose, 42)));
    cases[0].function_call.name.bytes = "other";
    cases[1].function_call.tool_ordinal_claim = 1;
    cases[2].function_call.decoded_action.decoded = .{ .other = .{ .value = 42 } };
    cases[3] = call(.other, 42);
    cases[4].function_call.decoded_action = .{ .invalid = .integer_range };
    for (cases, failures) |item, expected| {
        var observed = try finish(P.Interpretation, compiled.program, parked, result(&.{item}));
        defer observed.deinit();
        try std.testing.expectEqual(expected, observed.value.rejected);
    }
}

test "batch responder retains ordered candidates and enforces captured call policy" {
    var compiled = try compileModel(P, true);
    defer compiled.deinit();
    const items = [_]P.OutputItem{
        .{ .reasoning = .{ .summary = .{ .bytes = "Consider both." } } },
        call(.choose, 42),
        .{ .message = .{ .role = .assistant, .content = .{ .bytes = "Second answer follows." } } },
        call(.other, 73),
    };
    const value: Input = .{ .request = template(&.{}, batch), .offered = .{ true, true } };
    var parked = try start(compiled.program, value);
    defer parked.deinit();
    try expectRequest(parked, value);
    var accepted = try finish(P.BatchInterpretation, compiled.program, parked, result(&items));
    defer accepted.deinit();
    try std.testing.expectEqual(2, accepted.value.accepted.len);
    try std.testing.expectEqual(42, accepted.value.accepted[0].choose.value);
    try std.testing.expectEqual(73, accepted.value.accepted[1].other.value);

    var policies = @as([3]model.Selection, @splat(batch));
    policies[0].parallel_calls = false;
    policies[1].maximum_calls = 1;
    policies[2].minimum_calls = 3;
    const reasons = [_]P.InterpretationFailure{
        .parallel_disallowed, .multiple_calls, .missing_answer,
    };
    for (policies, reasons) |policy, reason| {
        var changed = value;
        changed.request.invocation.selection = policy;
        var pending = try start(compiled.program, changed);
        defer pending.deinit();
        try expectRequest(pending, changed);
        var observed = try finish(P.BatchInterpretation, compiled.program, pending, result(&items));
        defer observed.deinit();
        try std.testing.expectEqual(reason, observed.value.rejected);
    }
}

fn pairModule(c: protean.Context) !source.Module {
    const t = c.author;
    const effect = try P.declare(c);
    const responder = try protean.responders.defineModel(P, c, try c.literal(void, {}), false);
    const entry = try t.function("paired model calls", .{
        .input = try c.schema(PairInput),
    }, try c.schema(PairResult), .{effect});
    const body = try t.body(entry);
    const input = try body.parameter("input");
    const first = try body.field(input, "first");
    const second = try body.field(input, "second");
    const first_answer = try body.call(responder, .{
        .request = try body.field(first, "request"),
        .offered = try body.field(first, "offered"),
    });
    const second_answer = try body.call(responder, .{
        .request = try body.field(second, "request"),
        .offered = try body.field(second, "offered"),
    });
    const answers = try body.product(
        try c.schema(PairResult),
        .{ .first = first_answer, .second = second_answer },
    );
    try t.define(entry, try body.ret(answers));
    return t.module(entry, try c.schema(void));
}

test "two scoped model calls retain separate offered sets and post answer continuation" {
    const Application = struct {
        pub const emit = pairModule;
    };
    const System = protean.system(.{
        .InitialArgs = PairInput,
        .Result = PairResult,
        .Failure = void,
        .application = Application,
    });
    var compiled = try protean.compile(allocator, System);
    defer compiled.deinit();
    const input: PairInput = .{
        .first = .{ .request = template(&.{}, single), .offered = .{ true, false } },
        .second = .{
            .request = template(P.allDeclarations().items, single),
            .offered = .{ false, true },
        },
    };
    const bytes = try contracts.encodeOwned(PairInput, allocator, input);
    defer allocator.free(bytes);
    const invocation_image_3 = try allocator.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer allocator.free(invocation_image_3);
    _ = try horos.data.program_image.encode(allocator, compiled.program, invocation_image_3);
    var first = try kosmos.invocation.invoke(allocator, .{
        .image = invocation_image_3,
        .instance = .{ .initial_args = bytes },
    });
    defer first.deinit();
    try expectRequest(first, input.first);
    var second = try resumeResult(P.Result, compiled.program, first, result(&.{call(.choose, 42)}));
    defer second.deinit();
    try expectRequest(second, input.second);
    var observed = try finish(PairResult, compiled.program, second, result(&.{call(.other, 73)}));
    defer observed.deinit();
    try std.testing.expectEqual(42, observed.value.first.accepted.choose.value);
    try std.testing.expectEqual(73, observed.value.second.accepted.other.value);
    var stale = try finish(PairResult, compiled.program, second, result(&.{call(.choose, 42)}));
    defer stale.deinit();
    try std.testing.expectEqual(42, stale.value.first.accepted.choose.value);
    try std.testing.expectEqual(.unoffered, stale.value.second.rejected);
}

fn Many() type {
    @setEvalBranchQuota(100_000);
    const Payload = struct { value: u32 };
    const Declaration = struct { name: []const u8, description: []const u8 };
    var names: [64][:0]const u8 = undefined;
    var tags: [64]u32 = undefined;
    var types: [64]type = undefined;
    var declarations: [64]Declaration = undefined;
    for (0..64) |index| {
        const name = std.fmt.comptimePrint("tool_{d}", .{index});
        names[index] = name;
        tags[index] = @intCast(index * 2 + 3);
        types[index] = Payload;
        declarations[index] = .{ .name = name, .description = "A typed candidate." };
    }
    const Tag = @Enum(u32, .exhaustive, &names, &tags);
    const ManyAnswer = @Union(.auto, Tag, &names, &types, &@splat(.{}));
    return model.Profile(ManyAnswer, declarations, P.representation);
}

fn manyReply(comptime Q: type, comptime index: usize) Q.Result {
    const name = std.fmt.comptimePrint("tool_{d}", .{index});
    const items = comptime [_]Q.OutputItem{.{ .function_call = .{
        .call_id = .{ .bytes = "many-call" },
        .name = .{ .bytes = name },
        .arguments_json = .{ .bytes = "{\"value\":42}" },
        .tool_ordinal_claim = index,
        .decoded_action = .{ .decoded = @unionInit(Q.AnswerType, name, .{ .value = 42 }) },
    } }};
    return .{ .output = .{
        .items = .{ .items = &items },
        .normalized_output_digest = @as([32]u8, @splat(0)),
    } };
}

fn expectSharedSchema(comptime Q: type, program: data.activation.Program) !void {
    const schema_json = Q.allDeclarations().items[0].input_schema_json.bytes;
    var copies: usize = 0;
    for (program.constants) |constant| {
        copies += std.mem.count(u8, constant.bytes, schema_json);
    }
    // Count bytes in the compiled image's actual constant pool, including any
    // aggregate literals that could otherwise hide duplicate schema payloads.
    try std.testing.expectEqual(1, copies);
}

test "model responder executes indexes 31 32 and 63 while an unoffered declaration rejects" {
    const Q = Many();
    const ManyInput = struct { request: Q.AdaptiveRequest, offered: [64]bool };
    const FixtureModel = protean.model(.{
        .name = "many",
        .model = "many-custody-model",
        .protocol = struct {
            pub const semantic_identity = model.protocol_identity;
        },
    });
    var compiled = try compileModel(Q, false);
    defer compiled.deinit();
    try expectSharedSchema(Q, compiled.program);
    var offered = @as([64]bool, @splat(false));
    offered[31] = true;
    offered[32] = true;
    offered[63] = true;
    const request = try Q.templateValue(FixtureModel, .{ .items = &.{} }, single);
    const bytes = try contracts.encodeOwned(ManyInput, allocator, .{
        .request = .{
            .invocation = request,
            .policy = @splat(9),
            .selection = template(&.{}, single).selection,
            .plan = template(
                &.{},
                single,
            ).plan,
            .materialized = offered,
            .offered = offered,
            .results = .{ .items = &.{} },
        },
        .offered = offered,
    });
    defer allocator.free(bytes);
    const invocation_image_4 = try allocator.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer allocator.free(invocation_image_4);
    _ = try horos.data.program_image.encode(allocator, compiled.program, invocation_image_4);
    var parked = try kosmos.invocation.invoke(allocator, .{
        .image = invocation_image_4,
        .instance = .{ .initial_args = bytes },
    });
    defer parked.deinit();
    try std.testing.expect(parked.record == .requested);
    try expectManyRequest(Q, parked);
    inline for (.{ 31, 32, 63, 0 }) |index| {
        var outcome = try resumeResult(Q.AdaptiveResult, compiled.program, parked, .{
            .result = manyReply(Q, index),
            .replay = null,
            .replay_status = .complete,
            .usage = null,
        });
        defer outcome.deinit();
        try std.testing.expect(outcome.record == .completed);
        var observed = try contracts.decodeOwned(
            Q.Interpretation,
            allocator,
            outcome.record.completed,
        );
        defer observed.deinit();
        if (index == 0) {
            try std.testing.expectEqual(.unoffered, observed.value.rejected);
        } else {
            const name = std.fmt.comptimePrint("tool_{d}", .{index});
            try std.testing.expectEqual(42, @field(observed.value.accepted, name).value);
        }
    }
}

test "adaptive responder keeps definitions separate from original call authority" {
    var compiled = try compileResponder(P, false, true);
    defer compiled.deinit();
    var input = adaptiveAuthorityInput();
    var parked = try start(compiled.program, input);
    defer parked.deinit();
    try std.testing.expect(parked.record == .requested);
    try expectAdaptivePayload(input, parked);
    try expectAdaptiveAnswers(compiled.program, parked);
    try expectAdaptiveReplay(compiled.program, parked);
    // An offered action without a materialized definition fails before I/O.
    input.request.materialized = .{ false, true };
    var rejected = try start(compiled.program, input);
    defer rejected.deinit();
    try std.testing.expect(rejected.record == .failed);
}

test "adaptive model identity cannot bypass the protected responder" {
    inline for (.{
        @as(?protean.admission.Role, null),
        @as(?protean.admission.Role, .read),
        @as(?protean.admission.Role, .model),
    }) |role| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const effect = try P.source.declare(&b);
        if (role) |classification| try registry.classify(effect, classification);
        const entry = try b.declare(&.{
            try contracts.schema(P.AdaptiveRequest, &b),
        }, try contracts.schema(P.AdaptiveResult, &b), &.{effect}, &.{});
        try b.define(
            entry,
            try b.term(.{ .perform = .{
                .effect = effect,
                .payload = try b.reference(b.parameter(entry, 0)),
            } }),
        );
        try std.testing.expectError(
            if (role == .model) error.ProtectedEffectBypass else error.EffectRoleMismatch,
            protean.admission.verify(allocator, b.module(entry, try b.scalar(void)), &registry),
        );
    }
}

fn checkNormalizationField(program: data.activation.Program, comptime field: []const u8) !void {
    var value: Input = .{
        .request = template(&.{}, single),
        .offered = .{ true, false },
    };
    if (@typeInfo(
        @FieldType(@TypeOf(value.request.invocation.normalization_limits), field),
    ) == .optional) @field(
        value.request.invocation.normalization_limits,
        field,
    ).? += 1 else @field(
        value.request.invocation.normalization_limits,
        field,
    ) += 1;
    var rejected = try start(program, value);
    defer rejected.deinit();
    try std.testing.expect(rejected.record == .failed);
    try std.testing.expectEqualSlices(u8, &.{}, rejected.record.failed.value);
    @field(value.request.invocation.normalization_limits, field) = 0;
    value.request.invocation.selection = .{
        .minimum_calls = 0,
        .maximum_calls = 0,
        .parallel_calls = false,
    };
    var tighter = try start(program, value);
    defer tighter.deinit();
    try expectRequest(tighter, value);
    var finished = try resumeResult(P.Result, program, tighter, .{
        .unsupported_response = .normalization_limit,
    });
    defer finished.deinit();
    try std.testing.expect(finished.record == .completed);
}

fn checkIndependentLimits(program: data.activation.Program) !void {
    const exact_input: Input = .{ .request = template(&.{}, single), .offered = .{ true, false } };
    var exact = try start(program, exact_input);
    defer exact.deinit();
    try expectRequest(exact, exact_input);
    // These policy limits do not change any field of P.Result. They
    // remain caller-owned rather than acquiring an unnecessary cap.
    var independent: Input = .{
        .request = template(&.{}, single),
        .offered = .{ true, false },
    };
    independent.request.invocation.normalization_limits.maximum_argument_name_bytes += 1;
    independent.request.invocation.normalization_limits.maximum_argument_fields += 1;
    independent.request.invocation.maximum_provider_response_bytes =
        P.representation.provider_response_bytes.? + 1;
    var admitted = try start(program, independent);
    defer admitted.deinit();
    try expectRequest(admitted, independent);
    for (0..3) |case| {
        var invalid = independent;
        switch (case) {
            0 => invalid.request.invocation.selection.minimum_calls = 2,
            1 => invalid.request.invocation.selection.maximum_calls =
                invalid.request.invocation.normalization_limits.maximum_output_items.? + 1,
            2 => invalid.request.invocation.maximum_provider_response_bytes = 0,
            else => unreachable,
        }
        var rejected = try start(program, invalid);
        defer rejected.deinit();
        try std.testing.expect(rejected.record == .failed);
    }
}

fn expectManyRequest(comptime Q: type, parked: kosmos.invocation.Outcome) !void {
    var request_owner_2 = try data.invocation.decode(
        data.invocation.Request,
        allocator,
        parked.record.requested.request,
    );
    defer request_owner_2.deinit();
    const external = request_owner_2.value;
    var payload = try contracts.decodeOwned(Q.AdaptiveRequest, allocator, external.binding.payload);
    defer payload.deinit();
    try std.testing.expectEqualStrings(model.semantic_identity, external.binding.semantic_identity);
    try std.testing.expectEqual(3, payload.value.invocation.tools.items.len);
    inline for (.{ 31, 32, 63 }, 0..) |index, position| {
        const declaration = payload.value.invocation.tools.items[position];
        try std.testing.expectEqual(index, declaration.action_ordinal);
        try std.testing.expectEqual(index * 2 + 3, declaration.action_tag);
        const name = std.fmt.comptimePrint("tool_{d}", .{index});
        try std.testing.expectEqualStrings(name, declaration.name.bytes);
    }
}

fn adaptiveAuthorityInput() Input {
    return .{
        .request = .{
            .invocation = invocation(&.{}, single),
            .policy = @splat(9),
            .selection = .{
                .profile_id = .{ .bytes = "analysis" },
                .profile_digest = @splat(7),
                .effective_effort = .high,
                .control_revision = 4,
            },
            .plan = .{
                .epoch = 3,
                .reason = .model_change,
                .watermark = 12,
                .eviction_generation = 2,
                .prior = null,
                .catalog = .{ .digest = @splat(5), .bytes = 256 },
                .skills = .{ .items = &.{} },
            },
            .materialized = .{ true, true },
            // This forged template offer must not override the captured argument.
            .offered = .{ true, true },
            .results = .{ .items = &.{} },
        },
        .offered = .{ true, false },
    };
}

fn expectAdaptivePayload(input: Input, parked: kosmos.invocation.Outcome) !void {
    var request = try data.invocation.decode(
        data.invocation.Request,
        allocator,
        parked.record.requested.request,
    );
    defer request.deinit();
    try std.testing.expectEqualStrings(
        model.semantic_identity,
        request.value.binding.semantic_identity,
    );
    var payload = try contracts.decodeOwned(
        P.AdaptiveRequest,
        allocator,
        request.value.binding.payload,
    );
    defer payload.deinit();
    try std.testing.expectEqualDeep(input.request.selection, payload.value.selection);
    try std.testing.expectEqualDeep(input.request.plan, payload.value.plan);
    try std.testing.expectEqualSlices(u8, &input.request.policy, &payload.value.policy);
    try std.testing.expectEqualDeep(input.offered, payload.value.offered);
    try std.testing.expectEqual(2, payload.value.invocation.tools.items.len);
    try std.testing.expectEqualStrings("other", payload.value.invocation.tools.items[1].name.bytes);
}

fn expectAdaptiveAnswers(
    program: data.activation.Program,
    parked: kosmos.invocation.Outcome,
) !void {
    inline for (.{ .choose, .other }) |answer| {
        const reply: P.AdaptiveResult = .{
            .result = result(&.{call(answer, 42)}),
            .replay = null,
            .replay_status = .complete,
            .usage = null,
        };
        var finished = try resumeResult(P.AdaptiveResult, program, parked, reply);
        defer finished.deinit();
        var observation = try contracts.decodeOwned(
            protean.responders.ModelObservation(P, false),
            allocator,
            finished.record.completed,
        );
        defer observation.deinit();
        if (answer == .choose) try std.testing.expectEqual(
            42,
            observation.value.interpretation.accepted.choose.value,
        ) else try std.testing.expectEqual(
            .unoffered,
            observation.value.interpretation.rejected,
        );
    }
}

fn expectAdaptiveReplay(
    program: data.activation.Program,
    parked: kosmos.invocation.Outcome,
) !void {
    const reference: model.AdaptiveContextReference = .{
        .object = .{ .digest = @splat(1), .bytes = 1234 },
        .schema = .{ .bytes = model.adaptive_context_semantic_identity },
        .policy = @splat(9),
        .selection = @splat(7),
        .task = @splat(2),
        .tenant = .{ .bytes = "local" },
        .audience = .{ .bytes = "owner" },
        .epoch = 3,
        .watermark = 12,
        .eviction_generation = 2,
    };
    for ([_]model.ReplayStatus{ .complete, .unsupported, .capacity }) |status| {
        const reply: P.AdaptiveResult = .{
            .result = result(&.{call(.choose, 42)}),
            .replay = reference,
            .replay_status = status,
            .usage = null,
        };
        var finished = try resumeResult(P.AdaptiveResult, program, parked, reply);
        defer finished.deinit();
        var observed = try contracts.decodeOwned(
            protean.responders.ModelObservation(P, false),
            allocator,
            finished.record.completed,
        );
        defer observed.deinit();
        try std.testing.expectEqualDeep(reference, observed.value.normalized.replay.?);
        if (status == .complete) try std.testing.expectEqual(
            42,
            observed.value.interpretation.accepted.choose.value,
        ) else try std.testing.expectEqual(
            .unsupported,
            observed.value.interpretation.rejected,
        );
    }
}
