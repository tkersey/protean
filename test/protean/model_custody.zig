const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kronos = @import("kronos");
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
const Input = struct { request: P.Request, offered: [2]bool };
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

fn template(tools: []const P.ToolDeclaration, selection: model.Selection) P.Request {
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

fn compileModel(comptime Q: type, comptime multiple: bool) !source.Compiled {
    return compileResponder(Q, multiple, false);
}

fn compileResponder(comptime Q: type, comptime multiple: bool, comptime observed: bool) !source.Compiled {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const context: protean.Context = .{ .builder = &b, .registry = &registry };
    const failure = try b.constant(void, {});
    const define = if (observed) protean.responders.defineModelObserved else protean.responders.defineModel;
    const entry = try define(Q, context, failure, multiple);
    const shared = try define(Q, context, failure, multiple);
    try std.testing.expectEqual(entry, shared);
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    return horos.program.compile(allocator, module);
}

test "protected Protean source rejects raw model emission with forged request-time offers" {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const context: protean.Context = .{ .builder = &b, .registry = &registry };
    const effect = try P.declare(&b);
    try registry.classify(effect, .model);
    const entry = try b.declare(&.{try context.schema(P.Request)}, try context.schema(P.Interpretation), &.{effect}, &.{});
    const normalized = try b.variable(try context.schema(P.Result));
    const request = try b.reference(b.parameter(entry, 0));
    const raw = try b.term(.{ .perform = .{ .effect = effect, .payload = request } });
    const forged = try b.term(.{ .call = .{
        .function = try P.interpreter(&b),
        .arguments = &.{
            try b.reference(normalized),
            try context.literal([2]bool, .{ true, true }),
            try context.literal(model.Selection, single),
        },
    } });
    try b.define(entry, try b.bind(normalized, raw, forged));
    const module = b.module(entry, try b.scalar(void));
    // Valid public Horos source may choose another policy. It cannot acquire
    // Protean's offer-custody claim merely by invoking the pure candidate decoder.
    var raw_compiled = try horos.program.compile(allocator, module);
    defer raw_compiled.deinit();
    try std.testing.expectError(error.ProtectedEffectBypass, protean.admission.verify(allocator, module, &registry));
}

test "reserved model identity cannot evade custody by omitted or read classification" {
    inline for (.{ @as(?protean.admission.Role, null), @as(?protean.admission.Role, .read) }) |role| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const context: protean.Context = .{ .builder = &b, .registry = &registry };
        const effect = try P.declare(&b);
        if (role) |classification| try registry.classify(effect, classification);
        const entry = try b.declare(&.{try context.schema(P.Request)}, try context.schema(P.Result), &.{effect}, &.{});
        try b.define(entry, try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.reference(b.parameter(entry, 0)),
        } }));
        const module = b.module(entry, try b.scalar(void));
        var raw = try horos.program.compile(allocator, module);
        defer raw.deinit();
        try std.testing.expectError(error.EffectRoleMismatch, protean.admission.verify(allocator, module, &registry));
    }
}

test "observed model result preserves normalized provenance and typed recovery details" {
    const Observation = protean.responders.ModelObservation(P, false);
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const context: protean.Context = .{ .builder = &b, .registry = &registry };
    const failure = try b.constant(void, {});
    const entry = try protean.responders.defineModelObserved(P, context, failure, false);
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
    try expectNormalized(success, observed.value.normalized);
    const Case = struct { reply: P.Result, rejection: P.InterpretationFailure };
    const cases = [_]Case{
        .{ .reply = result(&.{call(.other, 73)}), .rejection = .unoffered },
        .{ .reply = .{ .refusal = .{ .bytes = "The full refusal reason." } }, .rejection = .refusal },
        .{ .reply = .{ .transport_failure = .interrupted }, .rejection = .transport },
        .{ .reply = .{ .transport_failure = .unavailable }, .rejection = .transport },
        .{ .reply = .{ .provider_failure = .{ .kind = .http_status, .http_status = 503 } }, .rejection = .provider },
        .{ .reply = .{ .provider_failure = .{ .kind = .response_incomplete, .http_status = 0 } }, .rejection = .provider },
        .{ .reply = .{ .unsupported_response = .invalid_utf8 }, .rejection = .unsupported },
    };
    for (cases) |case| {
        var rejected = try finish(Observation, compiled.program, parked, case.reply);
        defer rejected.deinit();
        try std.testing.expectEqual(case.rejection, rejected.value.interpretation.rejected);
        try expectNormalized(case.reply, rejected.value.normalized);
    }
}

fn expectNormalized(expected: P.Result, actual: P.Result) !void {
    const expected_bytes = try contracts.encodeOwned(P.Result, allocator, expected);
    defer allocator.free(expected_bytes);
    const actual_bytes = try contracts.encodeOwned(P.Result, allocator, actual);
    defer allocator.free(actual_bytes);
    try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
}

fn start(program: data.activation.Program, value: Input) !kronos.invocation.Outcome {
    const bytes = try contracts.encodeOwned(Input, allocator, value);
    defer allocator.free(bytes);
    const invocation_image_0 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(program));
    defer allocator.free(invocation_image_0);
    _ = try horos.data.program_image.encode(allocator, program, invocation_image_0);
    return kronos.invocation.invoke(allocator, .{
        .image = invocation_image_0,
        .instance = .{ .initial_args = bytes },
    });
}

fn expectRequest(outcome: kronos.invocation.Outcome, value: Input) !void {
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
    expected.tools = try P.declarationsValue(allocator, value.offered);
    defer allocator.free(expected.tools.items);
    const expected_bytes = try contracts.encodeOwned(P.Request, allocator, expected);
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
            .decoded_action = .{ .decoded = @unionInit(Answer, @tagName(name), .{ .value = value }) },
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
    parked: kronos.invocation.Outcome,
    reply: Result,
) !kronos.invocation.Outcome {
    try std.testing.expect(parked.record == .requested);
    var request_owner_1 = try data.invocation.decode(
        data.invocation.Request,
        allocator,
        parked.record.requested.request,
    );
    defer request_owner_1.deinit();
    const request = request_owner_1.value;
    const value = try contracts.encodeOwned(Result, allocator, reply);
    defer allocator.free(value);
    const bound: data.invocation.Result = .{
        .request_identity = request.request_identity,

        .value = value,
    };
    const length = try data.invocation.encodedLength(data.invocation.Result, bound);
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    _ = try data.invocation.encode(data.invocation.Result, allocator, bound, bytes);
    const invocation_image_1 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(program));
    defer allocator.free(invocation_image_1);
    _ = try horos.data.program_image.encode(allocator, program, invocation_image_1);
    return kronos.invocation.invoke(allocator, .{
        .image = invocation_image_1,
        .instance = .{ .state = parked.record.requested.state.? },
        .control = .{ .reply = bytes },
    });
}

fn finish(
    comptime T: type,
    program: data.activation.Program,
    parked: kronos.invocation.Outcome,
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
        const invocation_image_2 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        defer allocator.free(invocation_image_2);
        _ = try horos.data.program_image.encode(allocator, compiled.program, invocation_image_2);
        var parked = try kronos.invocation.invoke(allocator, .{
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
        inline for (.{ false, true }) |observed| {
            var compiled = try compileResponder(P, multiple, observed);
            defer compiled.deinit();
            inline for (.{
                "maximum_output_items",    "maximum_call_id_bytes",     "maximum_name_bytes",
                "maximum_arguments_bytes", "maximum_result_text_bytes",
            }) |field| {
                var value: Input = .{
                    .request = template(&.{}, single),
                    .offered = .{ true, false },
                };
                @field(value.request.normalization_limits, field) += 1;
                var rejected = try start(compiled.program, value);
                defer rejected.deinit();
                try std.testing.expect(rejected.record == .failed);
                try std.testing.expectEqualSlices(u8, &.{}, rejected.record.failed.value);
                @field(value.request.normalization_limits, field) -= 1;
                var exact = try start(compiled.program, value);
                defer exact.deinit();
                try expectRequest(exact, value);
                @field(value.request.normalization_limits, field) = 0;
                value.request.selection = .{
                    .minimum_calls = 0,
                    .maximum_calls = 0,
                    .parallel_calls = false,
                };
                var tighter = try start(compiled.program, value);
                defer tighter.deinit();
                try expectRequest(tighter, value);
                var finished = try resumeResult(P.Result, compiled.program, tighter, .{ .unsupported_response = .normalization_limit });
                defer finished.deinit();
                try std.testing.expect(finished.record == .completed);
            }
            // These policy limits do not change any field of P.Result. They
            // remain caller-owned rather than acquiring an unnecessary cap.
            var independent: Input = .{
                .request = template(&.{}, single),
                .offered = .{ true, false },
            };
            independent.request.normalization_limits.maximum_argument_name_bytes += 1;
            independent.request.normalization_limits.maximum_argument_fields += 1;
            independent.request.maximum_provider_response_bytes = P.representation.provider_response_bytes + 1;
            var admitted = try start(compiled.program, independent);
            defer admitted.deinit();
            try expectRequest(admitted, independent);
            for (0..3) |case| {
                var invalid = independent;
                switch (case) {
                    0 => invalid.request.selection.minimum_calls = 2,
                    1 => invalid.request.selection.maximum_calls =
                        invalid.request.normalization_limits.maximum_output_items + 1,
                    2 => invalid.request.maximum_provider_response_bytes = 0,
                    else => unreachable,
                }
                var rejected = try start(compiled.program, invalid);
                defer rejected.deinit();
                try std.testing.expect(rejected.record == .failed);
            }
        }
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
        changed.request.selection = policy;
        var pending = try start(compiled.program, changed);
        defer pending.deinit();
        try expectRequest(pending, changed);
        var observed = try finish(P.BatchInterpretation, compiled.program, pending, result(&items));
        defer observed.deinit();
        try std.testing.expectEqual(reason, observed.value.rejected);
    }
}

fn pairModule(c: protean.Context) !source.Module {
    const b = c.builder;
    const effect = try P.declare(b);
    const entry = try b.declare(
        &.{try c.schema(PairInput)},
        try c.schema(PairResult),
        &.{effect},
        &.{},
    );
    const args = try b.reference(b.parameter(entry, 0));
    const first = try b.primitive(try c.schema(Input), .field, &.{args}, 0);
    const second = try b.primitive(try c.schema(Input), .field, &.{args}, 1);
    const first_answer = try b.variable(try c.schema(P.Interpretation));
    const second_answer = try b.variable(try c.schema(P.Interpretation));
    const answers = try b.primitive(try c.schema(PairResult), .product, &.{
        try b.reference(first_answer), try b.reference(second_answer),
    }, 0);
    const first_call = try pairCall(c, first);
    const second_call = try pairCall(c, second);
    const finish_pair = try b.bind(second_answer, second_call, try b.pure(answers));
    try b.define(entry, try b.bind(first_answer, first_call, finish_pair));
    return b.module(entry, try b.scalar(void));
}

fn pairCall(c: protean.Context, value: source.Id) !source.Id {
    return protean.responders.invokeModel(
        P,
        c,
        try c.builder.constant(void, {}),
        false,
        try c.builder.primitive(try c.schema(P.Request), .field, &.{value}, 0),
        try c.builder.primitive(try c.schema([2]bool), .field, &.{value}, 1),
    );
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
    const invocation_image_3 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer allocator.free(invocation_image_3);
    _ = try horos.data.program_image.encode(allocator, compiled.program, invocation_image_3);
    var first = try kronos.invocation.invoke(allocator, .{
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
    const ManyInput = struct { request: Q.Request, offered: [64]bool };
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
        .request = request,
        .offered = offered,
    });
    defer allocator.free(bytes);
    const invocation_image_4 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer allocator.free(invocation_image_4);
    _ = try horos.data.program_image.encode(allocator, compiled.program, invocation_image_4);
    var parked = try kronos.invocation.invoke(allocator, .{
        .image = invocation_image_4,
        .instance = .{ .initial_args = bytes },
    });
    defer parked.deinit();
    try std.testing.expect(parked.record == .requested);
    var request_owner_2 = try data.invocation.decode(
        data.invocation.Request,
        allocator,
        parked.record.requested.request,
    );
    defer request_owner_2.deinit();
    const external = request_owner_2.value;
    var payload = try contracts.decodeOwned(Q.Request, allocator, external.binding.payload);
    defer payload.deinit();
    try std.testing.expectEqualStrings(model.semantic_identity, external.binding.semantic_identity);
    try std.testing.expectEqual(3, payload.value.tools.items.len);
    inline for (.{ 31, 32, 63 }, 0..) |index, position| {
        const declaration = payload.value.tools.items[position];
        try std.testing.expectEqual(index, declaration.action_ordinal);
        try std.testing.expectEqual(index * 2 + 3, declaration.action_tag);
        const name = std.fmt.comptimePrint("tool_{d}", .{index});
        try std.testing.expectEqualStrings(name, declaration.name.bytes);
    }
    inline for (.{ 31, 32, 63, 0 }) |index| {
        var outcome = try resumeResult(Q.Result, compiled.program, parked, manyReply(Q, index));
        defer outcome.deinit();
        try std.testing.expect(outcome.record == .completed);
        var observed = try contracts.decodeOwned(Q.Interpretation, allocator, outcome.record.completed);
        defer observed.deinit();
        if (index == 0) {
            try std.testing.expectEqual(.unoffered, observed.value.rejected);
        } else {
            const name = std.fmt.comptimePrint("tool_{d}", .{index});
            try std.testing.expectEqual(42, @field(observed.value.accepted, name).value);
        }
    }
}

test "stateless replay responder retains opaque data while protecting the request-time offer" {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const entry = try protean.responders.defineReplayModelObserved(P, c, try b.constant(void, {}), false);
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const ReplayInput = struct { request: P.ReplayRequest, offered: [2]bool };
    const input: ReplayInput = .{ .request = .{ .invocation = template(&.{}, single), .replay = .{ .bytes = "[]" }, .results = .{ .items = &.{} } }, .offered = .{ true, false } };
    const args = try contracts.encodeOwned(ReplayInput, allocator, input);
    defer allocator.free(args);
    const image = try allocator.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer allocator.free(image);
    _ = try data.program_image.encode(allocator, compiled.program, image);
    var parked = try kronos.invocation.invoke(allocator, .{ .image = image, .instance = .{ .initial_args = args } });
    defer parked.deinit();
    try std.testing.expect(parked.record == .requested);
    var request = try data.invocation.decode(data.invocation.Request, allocator, parked.record.requested.request);
    defer request.deinit();
    try std.testing.expectEqualStrings(model.replay_semantic_identity, request.value.binding.semantic_identity);
    var payload = try contracts.decodeOwned(P.ReplayRequest, allocator, request.value.binding.payload);
    defer payload.deinit();
    try std.testing.expectEqual(1, payload.value.invocation.tools.items.len);
    try std.testing.expectEqualStrings("choose", payload.value.invocation.tools.items[0].name.bytes);
    const Observation = protean.responders.ReplayModelObservation(P, false);
    for ([_]model.ReplayStatus{ .complete, .unsupported, .capacity }) |status| {
        const reply: P.ReplayResult = .{ .result = result(&.{call(.choose, 42)}), .replay = .{ .bytes = "opaque synthetic replay" }, .replay_status = status, .usage = null };
        var finished = try resumeResult(P.ReplayResult, compiled.program, parked, reply);
        defer finished.deinit();
        try std.testing.expect(finished.record == .completed);
        var observed = try contracts.decodeOwned(Observation, allocator, finished.record.completed);
        defer observed.deinit();
        try std.testing.expectEqualStrings(reply.replay.bytes, observed.value.normalized.replay.bytes);
        if (status == .complete) try std.testing.expectEqual(42, observed.value.interpretation.accepted.choose.value) else try std.testing.expectEqual(.unsupported, observed.value.interpretation.rejected);
    }
    const unoffered: P.ReplayResult = .{ .result = result(&.{call(.other, 73)}), .replay = .{ .bytes = "[]" }, .replay_status = .complete, .usage = null };
    var refused = try resumeResult(P.ReplayResult, compiled.program, parked, unoffered);
    defer refused.deinit();
    var observation = try contracts.decodeOwned(Observation, allocator, refused.record.completed);
    defer observation.deinit();
    try std.testing.expectEqual(.unoffered, observation.value.interpretation.rejected);
}

test "replay model identity cannot bypass the protected responder" {
    inline for (.{ @as(?protean.admission.Role, null), @as(?protean.admission.Role, .read), @as(?protean.admission.Role, .model) }) |role| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const c: protean.Context = .{ .builder = &b, .registry = &registry };
        const effect = try P.declareReplay(&b);
        if (role) |classification| try registry.classify(effect, classification);
        const entry = try b.declare(&.{try c.schema(P.ReplayRequest)}, try c.schema(P.ReplayResult), &.{effect}, &.{});
        try b.define(entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.reference(b.parameter(entry, 0)) } }));
        try std.testing.expectError(if (role == .model) error.ProtectedEffectBypass else error.EffectRoleMismatch, protean.admission.verify(allocator, b.module(entry, try b.scalar(void)), &registry));
    }
}

test "reference responder preserves frozen bindings and the exact request-time offer" {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const entry = try protean.responders.defineReferenceModelObserved(P, c, try b.constant(void, {}), false);
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const ReferenceInput = struct { request: P.ReferenceRequest, offered: [2]bool };
    const input: ReferenceInput = .{ .request = .{ .invocation = template(&.{}, single), .replay = null, .results = .{ .items = &.{} }, .profile = @splat(9) }, .offered = .{ true, false } };
    const args = try contracts.encodeOwned(ReferenceInput, allocator, input);
    defer allocator.free(args);
    const image = try allocator.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer allocator.free(image);
    _ = try data.program_image.encode(allocator, compiled.program, image);
    var parked = try kronos.invocation.invoke(allocator, .{ .image = image, .instance = .{ .initial_args = args } });
    defer parked.deinit();
    try std.testing.expect(parked.record == .requested);
    var request = try data.invocation.decode(data.invocation.Request, allocator, parked.record.requested.request);
    defer request.deinit();
    try std.testing.expectEqualStrings(model.reference_semantic_identity, request.value.binding.semantic_identity);
    var payload = try contracts.decodeOwned(P.ReferenceRequest, allocator, request.value.binding.payload);
    defer payload.deinit();
    try std.testing.expectEqualSlices(u8, &input.request.profile, &payload.value.profile);
    try std.testing.expectEqual(1, payload.value.invocation.tools.items.len);
    try std.testing.expectEqualStrings("choose", payload.value.invocation.tools.items[0].name.bytes);
    const reference: model.ContextReference = .{ .digest = @splat(1), .bytes = 1234, .schema = .{ .bytes = model.context_semantic_identity }, .profile = @splat(9), .task = @splat(2), .tenant = .{ .bytes = "local" }, .audience = .{ .bytes = "owner" }, .first = 0, .next = 2 };
    inline for (.{ .complete, .unsupported, .capacity }) |status| {
        const reply: P.ReferenceResult = .{ .result = result(&.{call(.choose, 42)}), .replay = reference, .replay_status = status, .usage = null };
        var finished = try resumeResult(P.ReferenceResult, compiled.program, parked, reply);
        defer finished.deinit();
        var observed = try contracts.decodeOwned(protean.responders.ReferenceModelObservation(P, false), allocator, finished.record.completed);
        defer observed.deinit();
        try std.testing.expectEqualDeep(reference, observed.value.normalized.replay.?);
        if (status == .complete) try std.testing.expectEqual(42, observed.value.interpretation.accepted.choose.value) else try std.testing.expectEqual(.unsupported, observed.value.interpretation.rejected);
    }
    const unoffered: P.ReferenceResult = .{ .result = result(&.{call(.other, 73)}), .replay = reference, .replay_status = .complete, .usage = null };
    var refused = try resumeResult(P.ReferenceResult, compiled.program, parked, unoffered);
    defer refused.deinit();
    var observation = try contracts.decodeOwned(protean.responders.ReferenceModelObservation(P, false), allocator, refused.record.completed);
    defer observation.deinit();
    try std.testing.expectEqual(.unoffered, observation.value.interpretation.rejected);
}

test "reference model identity cannot bypass the protected responder" {
    inline for (.{ @as(?protean.admission.Role, null), @as(?protean.admission.Role, .read), @as(?protean.admission.Role, .model) }) |role| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const c: protean.Context = .{ .builder = &b, .registry = &registry };
        const effect = try P.declareReference(&b);
        if (role) |classification| try registry.classify(effect, classification);
        const entry = try b.declare(&.{try c.schema(P.ReferenceRequest)}, try c.schema(P.ReferenceResult), &.{effect}, &.{});
        try b.define(entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.reference(b.parameter(entry, 0)) } }));
        try std.testing.expectError(if (role == .model) error.ProtectedEffectBypass else error.EffectRoleMismatch, protean.admission.verify(allocator, b.module(entry, try b.scalar(void)), &registry));
    }
}

test "adaptive responder keeps definitions separate from original call authority" {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const entry = try protean.responders.defineAdaptiveModelObserved(P, c, try b.constant(void, {}), false);
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const AdaptiveInput = struct { request: P.AdaptiveRequest, offered: [2]bool };
    var input: AdaptiveInput = .{
        .request = .{
            .invocation = template(&.{}, single),
            .policy = @splat(9),
            .selection = .{ .profile_id = .{ .bytes = "analysis" }, .profile_digest = @splat(7), .effective_effort = .high, .control_revision = 4 },
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
    const image = try allocator.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer allocator.free(image);
    _ = try data.program_image.encode(allocator, compiled.program, image);
    const args = try contracts.encodeOwned(AdaptiveInput, allocator, input);
    defer allocator.free(args);
    var parked = try kronos.invocation.invoke(allocator, .{ .image = image, .instance = .{ .initial_args = args } });
    defer parked.deinit();
    try std.testing.expect(parked.record == .requested);
    var request = try data.invocation.decode(data.invocation.Request, allocator, parked.record.requested.request);
    defer request.deinit();
    try std.testing.expectEqualStrings(model.adaptive_semantic_identity, request.value.binding.semantic_identity);
    var payload = try contracts.decodeOwned(P.AdaptiveRequest, allocator, request.value.binding.payload);
    defer payload.deinit();
    try std.testing.expectEqualDeep(input.request.selection, payload.value.selection);
    try std.testing.expectEqualDeep(input.request.plan, payload.value.plan);
    try std.testing.expectEqualSlices(u8, &input.request.policy, &payload.value.policy);
    try std.testing.expectEqualDeep(input.offered, payload.value.offered);
    try std.testing.expectEqual(2, payload.value.invocation.tools.items.len);
    try std.testing.expectEqualStrings("other", payload.value.invocation.tools.items[1].name.bytes);
    inline for (.{ .choose, .other }) |answer| {
        const reply: P.AdaptiveResult = .{ .result = result(&.{call(answer, 42)}), .replay = null, .replay_status = .complete, .usage = null };
        var finished = try resumeResult(P.AdaptiveResult, compiled.program, parked, reply);
        defer finished.deinit();
        var observation = try contracts.decodeOwned(protean.responders.AdaptiveModelObservation(P, false), allocator, finished.record.completed);
        defer observation.deinit();
        if (answer == .choose) try std.testing.expectEqual(42, observation.value.interpretation.accepted.choose.value) else try std.testing.expectEqual(.unoffered, observation.value.interpretation.rejected);
    }
    // An offered action without a materialized definition fails before I/O.
    input.request.materialized = .{ false, true };
    const invalid_args = try contracts.encodeOwned(AdaptiveInput, allocator, input);
    defer allocator.free(invalid_args);
    var rejected = try kronos.invocation.invoke(allocator, .{ .image = image, .instance = .{ .initial_args = invalid_args } });
    defer rejected.deinit();
    try std.testing.expect(rejected.record == .failed);
}

test "adaptive model identity cannot bypass the protected responder" {
    inline for (.{ @as(?protean.admission.Role, null), @as(?protean.admission.Role, .read), @as(?protean.admission.Role, .model) }) |role| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(b.allocator());
        defer registry.deinit();
        const c: protean.Context = .{ .builder = &b, .registry = &registry };
        const effect = try P.declareAdaptive(&b);
        if (role) |classification| try registry.classify(effect, classification);
        const entry = try b.declare(&.{try c.schema(P.AdaptiveRequest)}, try c.schema(P.AdaptiveResult), &.{effect}, &.{});
        try b.define(entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.reference(b.parameter(entry, 0)) } }));
        try std.testing.expectError(if (role == .model) error.ProtectedEffectBypass else error.EffectRoleMismatch, protean.admission.verify(allocator, b.module(entry, try b.scalar(void)), &registry));
    }
}
