//! Native semantic checks with one shared Kronos/Protean module graph.
test {
    _ = @import("adaptive_controls.zig");
    _ = @import("adaptive_responses.zig");
    _ = @import("adaptive_recovery.zig");
    _ = @import("native_tasks.zig");
    _ = @import("native_responses.zig");
    _ = @import("bounded_history.zig");
    _ = @import("decision_scopes.zig");
    _ = @import("model_admission.zig");
    _ = @import("model_custody.zig");
    _ = @import("observation.zig");
    _ = @import("approval_equality.zig");
    _ = @import("callable_runtime.zig");
    _ = @import("clarification.zig");
}
