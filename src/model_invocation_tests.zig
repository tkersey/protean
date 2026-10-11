const std = @import("std");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const invocation = @import("model_invocation.zig");

const limits: invocation.Limits = .{
    .model_id_bytes = 32,
    .temperature_bytes = 64,
    .maximum_messages = 4,
    .message_bytes = 256,
    .maximum_output_items = 8,
    .call_id_bytes = 64,
    .arguments_json_bytes = 1024,
    .result_text_bytes = 256,
    .provider_response_bytes = 4096,
};
const FixtureAnswer = union(enum(u32)) {
    choose: struct {
        text: contracts.Text(16),
        signed: i64,
        unsigned: u64,
        enabled: bool,
        mode: enum(u32) { low = 9, high = 3 },
    } = 7,
    decline: enum(u32) { no = 3, later = 9 } = 31,
};
const Fixture = invocation.Profile(FixtureAnswer, .{
    .{ .name = "choose", .description = "Propose a typed answer." },
    .{ .name = "decline", .description = "Decline the question." },
}, limits);

test "model declarations preserve logical tags and derive strict schemas/codecs" {
    const declarations = Fixture.allDeclarations().items;
    try std.testing.expectEqual(2, declarations.len);
    try std.testing.expectEqual(7, declarations[0].action_tag);
    try std.testing.expectEqual(1, declarations[1].action_ordinal);
    try std.testing.expectEqual(31, declarations[1].action_tag);
    const fields = declarations[0].argument_codec.items;
    try std.testing.expectEqual(5, fields.len);
    try std.testing.expectEqual(16, fields[0].maximum_bytes);
    try std.testing.expect(std.mem.indexOf(u8, declarations[0].input_schema_json.bytes, "\"maxLength\":16") != null);
    try std.testing.expectEqualSlices(u32, &.{ 9, 3 }, fields[4].enum_tags.items);
    try std.testing.expect(std.mem.indexOf(u8, declarations[0].input_schema_json.bytes, "18446744073709551615") != null);
    try std.testing.expect(std.mem.indexOf(u8, declarations[0].input_schema_json.bytes, "\"additionalProperties\":false") != null);
}

test "normalized Answer uses sum ordinal while enum payload keeps explicit tags" {
    const result: Fixture.Result = .{ .output = .{
        .items = .{ .items = &.{.{ .function_call = .{
            .call_id = .{ .bytes = "call" },
            .name = .{ .bytes = "decline" },
            .arguments_json = .{ .bytes = "{\"value\":\"later\"}" },
            .tool_ordinal_claim = 1,
            .decoded_action = .{ .decoded = .{ .decline = .later } },
        } }} },
        .normalized_output_digest = @as([32]u8, @splat(0)),
    } };
    const bytes = try contracts.encodeOwned(Fixture.Result, std.testing.allocator, result);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0 }, bytes[0..3]);
    var restored = try contracts.decodeOwned(Fixture.Result, std.testing.allocator, bytes);
    defer restored.deinit();
    const call = restored.value.output.items.items[0].function_call;
    try std.testing.expectEqual(.later, call.decoded_action.decoded.decline);
    try std.testing.expectEqual(1, call.tool_ordinal_claim);
}

test "model effect is ordinary and a typed question requires no executable tool" {
    const Question = invocation.Question(i64, "answer", "Answer the integer question.", limits);
    var builder = horos.source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const first = try Question.declare(&builder);
    try std.testing.expectEqual(first, try Question.declare(&builder));
    try std.testing.expectEqualStrings(invocation.semantic_identity, builder.effects.items[@intCast(first)].identity);
    const request = try contracts.schema(Question.Request, &builder);
    const result = try contracts.schema(Question.Result, &builder);
    try std.testing.expectEqual(request, builder.effects.items[@intCast(first)].payload);
    try std.testing.expectEqual(result, builder.effects.items[@intCast(first)].result);
    try std.testing.expect(builder.effects.items[@intCast(first)].external);
    const facts = try horos.data.admission.schemas(std.testing.allocator, builder.schemas.items);
    defer std.testing.allocator.free(facts.minimum);
    defer std.testing.allocator.free(facts.exportable);
    try std.testing.expectEqualStrings("answer", Question.allDeclarations().items[0].name.bytes);
}

test "stateless replay is an additive bounded ordinary contract with exact legacy prefix" {
    const result: Fixture.ReplayResult = .{
        .result = .{ .refusal = .{ .bytes = "no" } },
        .replay = .{ .bytes = "[]" },
        .replay_status = .complete,
        .usage = .{ .input_tokens = 7, .output_tokens = 3, .cached_input_tokens = 2 },
    };
    const encoded = try contracts.encodeOwned(Fixture.ReplayResult, std.testing.allocator, result);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{
        1, 2, 'n', 'o', 2, '[', ']', 0, 0, 0, 0, 1,
        7, 0, 0,   0,   0, 0,   0,   0, 3, 0, 0, 0,
        0, 0, 0,   0,   1, 2,   0,   0, 0, 0, 0, 0,
        0,
    }, encoded);
    var restored = try contracts.decodeOwned(Fixture.ReplayResult, std.testing.allocator, encoded);
    defer restored.deinit();
    try std.testing.expectEqualStrings("[]", restored.value.replay.bytes);
    try std.testing.expectEqual(2, restored.value.usage.?.cached_input_tokens.?);
    var builder = horos.source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const legacy = try Fixture.declare(&builder);
    const replay = try Fixture.declareReplay(&builder);
    try std.testing.expect(legacy != replay);
    try std.testing.expectEqual(replay, try Fixture.declareReplay(&builder));
    try std.testing.expectEqualStrings(invocation.replay_semantic_identity, builder.effects.items[@intCast(replay)].identity);
    try std.testing.expectEqual(try contracts.schema(Fixture.ReplayRequest, &builder), builder.effects.items[@intCast(replay)].payload);
    try std.testing.expectEqual(invocation.maximum_replay_bytes, Fixture.ReplayBytes.max_length.?);
}

test "reference replay carries bounded bindings without copying provider history" {
    const reference: invocation.ContextReference = .{
        .digest = @splat(1),
        .bytes = 1024 * 1024,
        .schema = .{ .bytes = invocation.context_semantic_identity },
        .profile = @splat(2),
        .task = @splat(3),
        .tenant = .{ .bytes = "tenant" },
        .audience = .{ .bytes = "principal" },
        .first = 0,
        .next = 37,
    };
    const result: Fixture.ReferenceResult = .{
        .result = .{ .refusal = .{ .bytes = "no" } },
        .replay = reference,
        .replay_status = .complete,
        .usage = null,
    };
    const encoded = try contracts.encodeOwned(Fixture.ReferenceResult, std.testing.allocator, result);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len < 256);
    var decoded = try contracts.decodeOwned(Fixture.ReferenceResult, std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(reference, decoded.value.replay.?);
    var builder = horos.source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const v3 = try Fixture.declare(&builder);
    const v4 = try Fixture.declareReplay(&builder);
    const v5 = try Fixture.declareReference(&builder);
    try std.testing.expect(v3 != v4 and v4 != v5 and v3 != v5);
    try std.testing.expectEqualStrings(invocation.reference_semantic_identity, builder.effects.items[@intCast(v5)].identity);
    try std.testing.expectEqual(v5, try Fixture.declareReference(&builder));
}
