//! Authoring contracts with one shared compiler/module graph.
test {
    _ = @import("values.zig");
    _ = @import("approval_probe.zig");
    _ = @import("callable.zig");
    _ = @import("compiled_tool.zig");
}
