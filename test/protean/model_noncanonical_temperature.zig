const protean = @import("protean");

comptime {
    _ = protean.model(.{
        .name = "invalid",
        .protocol = struct {
            pub const semantic_identity = protean.model_invocation.protocol_identity;
        },
        .model = "fixture-model",
        .parameters = .{ .temperature = "0.20" },
    });
}
