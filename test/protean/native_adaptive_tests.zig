//! Authored adaptive-controller checks with the shared native module graph.
comptime {
    _ = @import("adaptive_controls.zig");
    _ = @import("adaptive_reports.zig");
    _ = @import("adaptive_recovery.zig");
    _ = @import("projection_recovery.zig");
    _ = @import("projection_failure_tests.zig");
    _ = @import("projection_late_recovery.zig");
    _ = @import("workspace_projection_tests.zig");
}
