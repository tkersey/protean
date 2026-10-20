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
    const request = try contracts.schema(Question.AdaptiveRequest, &builder);
    const result = try contracts.schema(Question.AdaptiveResult, &builder);
    try std.testing.expectEqual(request, builder.effects.items[@intCast(first)].payload);
    try std.testing.expectEqual(result, builder.effects.items[@intCast(first)].result);
    try std.testing.expect(builder.effects.items[@intCast(first)].external);
    const facts = try horos.data.admission.schemas(std.testing.allocator, builder.schemas.items);
    defer std.testing.allocator.free(facts.minimum);
    defer std.testing.allocator.free(facts.exportable);
    try std.testing.expectEqualStrings("answer", Question.allDeclarations().items[0].name.bytes);
}

test "v11 is the sole model effect and retains current context bindings" {
    const reference: invocation.AdaptiveContextReference = .{
        .object = .{ .digest = @splat(1), .bytes = 1024 * 1024 },
        .schema = .{ .bytes = invocation.adaptive_context_semantic_identity },
        .policy = @splat(2),
        .selection = @splat(4),
        .task = @splat(3),
        .tenant = .{ .bytes = "tenant" },
        .audience = .{ .bytes = "principal" },
        .epoch = 2,
        .watermark = 37,
        .eviction_generation = 1,
    };
    const result: Fixture.AdaptiveResult = .{
        .result = .{ .refusal = .{ .bytes = "no" } },
        .replay = reference,
        .replay_status = .complete,
        .usage = null,
    };
    const encoded = try contracts.encodeOwned(Fixture.AdaptiveResult, std.testing.allocator, result);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len < 256);
    var decoded = try contracts.decodeOwned(Fixture.AdaptiveResult, std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(reference, decoded.value.replay.?);
    var builder = horos.source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const effect = try Fixture.declare(&builder);
    try std.testing.expectEqualStrings("agent.model.invoke.v11", builder.effects.items[@intCast(effect)].identity);
    try std.testing.expectEqual(effect, try Fixture.declare(&builder));
    try std.testing.expectEqual(@as(usize, 1), builder.effects.items.len);
    try std.testing.expectEqual(try contracts.schema(Fixture.AdaptiveRequest, &builder), builder.effects.items[@intCast(effect)].payload);
    try std.testing.expectEqual(try contracts.schema(Fixture.AdaptiveResult, &builder), builder.effects.items[@intCast(effect)].result);
}

test "nested tool codecs describe bounded vectors without changing flat field codecs" {
    const Nested = invocation.Profile(union(enum) {
        propose: struct { rows: contracts.Vector(struct { label: contracts.Text(8), mode: enum(u32) { first = 7, second = 19 } }, 2) },
    }, .{.{ .name = "propose", .description = "Propose rows." }}, limits);
    const tool = Nested.allDeclarations().items[0];
    try std.testing.expectEqual(@as(usize, 4), tool.argument_codec.items.len);
    try std.testing.expectEqual(.sequence, tool.argument_codec.items[0].field.kind);
    try std.testing.expectEqual(@as(?u64, 2), tool.argument_codec.items[0].maximum_items);
    try std.testing.expectEqual(@as(u32, 1), tool.argument_codec.items[0].children);
    try std.testing.expectEqual(.product, tool.argument_codec.items[1].field.kind);
    try std.testing.expectEqual(@as(u32, 2), tool.argument_codec.items[1].children);
    try std.testing.expectEqualSlices(u32, &.{ 7, 19 }, tool.argument_codec.items[3].field.enum_tags.items);
    try std.testing.expectEqual(@as(u32, 1), Nested.normalizationLimits().maximum_argument_fields);
    try std.testing.expect(std.mem.indexOf(u8, tool.input_schema_json.bytes, "\"maxItems\":2") != null);
    // Existing flat consumers still receive their six-field metadata records.
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(Fixture.ArgumentCodec.Child).@"struct".field_names.len);
}

test "bounded tool arguments support nested union payloads" {
    const Nested = invocation.Profile(union(enum) {
        choose: struct { option: union(enum) { left: bool, right: u8 } },
    }, .{.{ .name = "choose", .description = "Choose a value." }}, .{ .arguments_json_bytes = 256 });
    const tool = Nested.allDeclarations().items[0];
    try std.testing.expectEqual(@as(?u32, 256), Nested.normalizationLimits().maximum_arguments_bytes);
    try std.testing.expect(std.mem.indexOf(u8, tool.input_schema_json.bytes, "\"anyOf\"") != null);
}

test "optional model inputs retain nullable schemas and nested codec structure" {
    const Optional = invocation.Profile(union(enum) {
        observe: struct { selection: ?struct { node: u64 } },
    }, .{.{ .name = "observe", .description = "Select disclosed input." }}, limits);
    const tool = Optional.allDeclarations().items[0];
    try std.testing.expectEqual(@as(usize, 3), tool.argument_codec.items.len);
    try std.testing.expectEqual(.optional, tool.argument_codec.items[0].field.kind);
    try std.testing.expectEqual(@as(u32, 1), tool.argument_codec.items[0].children);
    try std.testing.expectEqual(.product, tool.argument_codec.items[1].field.kind);
    try std.testing.expectEqual(.unsigned_integer, tool.argument_codec.items[2].field.kind);
    try std.testing.expect(std.mem.indexOf(u8, tool.input_schema_json.bytes, "\"type\":\"null\"") != null);
}

test "guest snapshot disclosure remains an explicit model boolean" {
    const Selected = invocation.Profile(union(enum) {
        disclose: @import("workspace_contracts.zig").Disclosure,
    }, .{.{ .name = "disclose", .description = "Select guest data." }}, limits);
    const tool = Selected.allDeclarations().items[0];
    try std.testing.expect(std.mem.indexOf(
        u8,
        tool.input_schema_json.bytes,
        "\"snapshot\":{\"type\":\"boolean\"}",
    ) != null);
    const last = tool.argument_codec.items[tool.argument_codec.items.len - 1];
    try std.testing.expectEqualStrings("snapshot", last.field.name.bytes);
    try std.testing.expectEqual(.boolean, last.field.kind);
    const defaults: @import("workspace_contracts.zig").Disclosure = .{};
    try std.testing.expect(!defaults.snapshot);
}
