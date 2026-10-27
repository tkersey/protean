//! Private authoring checks; never imported by the public production module.
test {
    _ = @import("model_invocation_tests.zig");
    _ = @import("model_interpretation.zig");
}
