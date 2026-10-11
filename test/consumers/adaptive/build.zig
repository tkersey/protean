//! The real downstream API, selecting the single supported application.
const std = @import("std");
const protean_build = @import("protean");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const kosmos = b.option(std.Build.LazyPath, "kosmos-source", "Authenticated Kosmos source") orelse @panic("provide -Dkosmos-source");
    const sqlite = b.option(std.Build.LazyPath, "sqlite-source", "Authenticated SQLite source") orelse @panic("provide -Dsqlite-source");
    const dependency = b.dependency("protean", .{ .target = target, .optimize = optimize, .@"kosmos-source" = kosmos, .@"sqlite-source" = sqlite });
    _ = protean_build.addNativeSystem(b, dependency, .{
        .name = "protean",
        .application = .{ .source = .{
            .definition = dependency.path("examples/adaptive/definition.zig"),
            .types = dependency.path("examples/adaptive/types.zig"),
        } },
        .environment = dependency.path("examples/adaptive/environment.zig"),
    });
}
