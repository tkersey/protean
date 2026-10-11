const protean = @import("protean");
const Unsupported = protean.model_invocation.Question([]const u8, "answer", "Answer.", .{
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
comptime {
    _ = Unsupported.Request;
}
