const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kronos = @import("kronos");
const contracts = protean.contracts;
const model = protean.model_invocation;
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
const Inputs = struct { result: P.Result, offered: [2]bool, policy: model.Selection };
const allocator = std.testing.allocator;
const batch_policy: model.Selection = .{
    .minimum_calls = 1,
    .maximum_calls = 4,
    .parallel_calls = true,
};

fn item(value: u64) P.OutputItem {
    return .{ .function_call = .{
        .call_id = .{ .bytes = "call" },
        .name = .{ .bytes = "choose" },
        .arguments_json = .{ .bytes = "{\"value\":42}" },
        .tool_ordinal_claim = 0,
        .decoded_action = .{ .decoded = .{ .choose = .{ .value = value } } },
    } };
}

fn input(items: []const P.OutputItem) Inputs {
    return .{ .result = .{ .output = .{
        .items = .{ .items = items },
        .normalized_output_digest = @as([32]u8, @splat(0)),
    } }, .offered = .{ true, false }, .policy = batch_policy };
}

fn execute(comptime T: type, program: horos.data.activation.Program, value: Inputs) !contracts.Decoded(T) {
    const bytes = try contracts.encodeOwned(Inputs, allocator, value);
    defer allocator.free(bytes);
    const image = try allocator.alloc(u8, try horos.data.program_image.encodedLength(program));
    defer allocator.free(image);
    _ = try horos.data.program_image.encode(allocator, program, image);
    var outcome = try kronos.invocation.invoke(allocator, .{
        .image = image,
        .instance = .{ .initial_args = bytes },
    });
    defer outcome.deinit();
    try std.testing.expect(outcome.record == .completed);
    return contracts.decodeOwned(T, allocator, outcome.record.completed);
}

fn expectRejected(program: horos.data.activation.Program, value: Inputs, expected: P.InterpretationFailure) !void {
    var observed = try execute(P.BatchInterpretation, program, value);
    defer observed.deinit();
    try std.testing.expectEqual(expected, observed.value.rejected);
}

test "actual Kronos preserves every admitted call and enforces current call policy" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const entry = try P.interpretAll(&b);
    var compiled = try horos.program.compile(allocator, b.module(entry, try b.scalar(void)));
    defer compiled.deinit();
    const items = [_]P.OutputItem{
        .{ .reasoning = .{ .summary = .{ .bytes = "context" } } },
        item(42),
        .{ .message = .{ .role = .assistant, .content = .{ .bytes = "a note" } } },
        item(73),
    };
    var observed = try execute(P.BatchInterpretation, compiled.program, input(&items));
    defer observed.deinit();
    try std.testing.expectEqual(2, observed.value.accepted.len);
    try std.testing.expectEqual(42, observed.value.accepted[0].choose.value);
    try std.testing.expectEqual(73, observed.value.accepted[1].choose.value);

    var changed = input(&items);
    changed.policy.parallel_calls = false;
    try expectRejected(compiled.program, changed, .parallel_disallowed);
    changed.policy = .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = true };
    try expectRejected(compiled.program, changed, .multiple_calls);
    changed = input(&items);
    changed.policy.minimum_calls = 3;
    try expectRejected(compiled.program, changed, .missing_answer);
    changed.policy.minimum_calls = 5;
    try expectRejected(compiled.program, changed, .invalid_selection);
    changed.policy = .{ .minimum_calls = 0, .maximum_calls = 9, .parallel_calls = true };
    try expectRejected(compiled.program, changed, .invalid_selection);
    var empty = input(&.{});
    empty.policy.minimum_calls = 0;
    var empty_result = try execute(P.BatchInterpretation, compiled.program, empty);
    defer empty_result.deinit();
    try std.testing.expectEqual(0, empty_result.value.accepted.len);
}

test "actual Kronos rejects forged declaration association variants and offer custody" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const entry = try P.interpretAll(&b);
    var compiled = try horos.program.compile(allocator, b.module(entry, try b.scalar(void)));
    defer compiled.deinit();
    var items = [_]P.OutputItem{item(42)};
    items[0].function_call.name.bytes = "other";
    try expectRejected(compiled.program, input(&items), .declaration_mismatch);
    items[0] = item(42);
    items[0].function_call.tool_ordinal_claim = 1;
    try expectRejected(compiled.program, input(&items), .declaration_mismatch);
    items[0] = item(42);
    items[0].function_call.decoded_action.decoded = .{ .other = .{ .value = 42 } };
    try expectRejected(compiled.program, input(&items), .declaration_mismatch);
    items[0] = item(42);
    var unoffered = input(&items);
    unoffered.offered[0] = false;
    try expectRejected(compiled.program, unoffered, .unoffered);
    items[0].function_call.decoded_action = .{ .invalid = .integer_range };
    try expectRejected(compiled.program, input(&items), .invalid_arguments);
    inline for (.{
        .{ P.Result{ .refusal = .{ .bytes = "declined" } }, P.InterpretationFailure.refusal },
        .{ P.Result{ .transport_failure = .interrupted }, P.InterpretationFailure.transport },
        .{ P.Result{ .provider_failure = .{ .kind = .http_status, .http_status = 503 } }, P.InterpretationFailure.provider },
        .{ P.Result{ .unsupported_response = .invalid_utf8 }, P.InterpretationFailure.unsupported },
    }) |case| {
        var failed = input(&.{});
        failed.result = case[0];
        try expectRejected(compiled.program, failed, case[1]);
    }
}

test "single answer convenience rejects multiple calls instead of choosing one" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const entry = try P.interpreter(&b);
    var compiled = try horos.program.compile(allocator, b.module(entry, try b.scalar(void)));
    defer compiled.deinit();
    const items = [_]P.OutputItem{ item(42), item(73) };
    var value = input(items[0..1]);
    value.policy = .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false };
    var valid = try execute(P.Interpretation, compiled.program, value);
    defer valid.deinit();
    try std.testing.expectEqual(42, valid.value.accepted.choose.value);
    value.result.output.items.items = &items;
    var many = try execute(P.Interpretation, compiled.program, value);
    defer many.deinit();
    try std.testing.expectEqual(.multiple_calls, many.value.rejected);
    value.policy = batch_policy;
    var policy = try execute(P.Interpretation, compiled.program, value);
    defer policy.deinit();
    try std.testing.expectEqual(.non_single_policy, policy.value.rejected);
}
