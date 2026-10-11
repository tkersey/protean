const protean = @import("protean");

comptime {
    _ = protean.prompt.literal(.{
        .role = .developer,
        .content = "Preserve declared instructions.",
        .contents = "An unknown field cannot be silently discarded.",
    });
}
