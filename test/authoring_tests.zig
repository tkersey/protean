//! Compatible public authoring contracts. Private and alternate-module roots stay separate.
test {
    _ = @import("protean/authoring_tests.zig");
    _ = @import("protean/catalogs.zig");
    _ = @import("protean/participant.zig");
    _ = @import("protean/composed_owners.zig");
    _ = @import("protean/recursive_participant.zig");
    _ = @import("protean/selection.zig");
}
