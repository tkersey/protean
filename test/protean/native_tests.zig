//! Native semantic checks with one shared Kosmos/Protean module graph.
comptime {
    _ = @import("native_adaptive_tests.zig");
    _ = @import("native_owner_tests.zig");
}
