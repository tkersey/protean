//! Protean authoring has no Kronos runtime dependency. Runtime checks are explicit.
pub const build = @import("build_protean.zig").build;
pub const addNativeSystem = @import("build_native.zig").addNativeSystem;
pub const NativeAssets = @import("build_native.zig").Assets;
