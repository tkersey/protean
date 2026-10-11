const protean = @import("protean");
const Invalid = protean.model_invocation.Profile(union(enum) { answer: struct { value: u32 } }, .{
    .{ .name = "answer", .description = "Answer.", .execute = callback },
}, .{
    .model_id_bytes = 32,
    .temperature_bytes = 8,
    .maximum_messages = 4,
    .message_bytes = 128,
    .maximum_output_items = 4,
    .call_id_bytes = 32,
    .arguments_json_bytes = 256,
    .result_text_bytes = 128,
    .provider_response_bytes = 4096,
});
fn callback(value: u32) u32 {
    return value;
}
comptime {
    _ = Invalid.Request;
}
