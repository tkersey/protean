//! The real downstream API, selecting the single supported application.
const std = @import("std");
const protean_build = @import("protean");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const kosmos = b.option(std.Build.LazyPath, "kosmos-source", "Authenticated Kosmos source") orelse @panic("provide -Dkosmos-source");
    const sqlite = b.option(std.Build.LazyPath, "sqlite-source", "Authenticated SQLite source") orelse @panic("provide -Dsqlite-source");
    const dependency = b.dependency("protean", .{ .target = target, .optimize = optimize, .@"kosmos-source" = kosmos, .@"sqlite-source" = sqlite });
    const surface = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("package_surface.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "protean", .module = dependency.module("protean_host_authoring") }},
        }),
    });
    const surface_run = b.addRunArtifact(surface);
    surface_run.has_side_effects = true;
    b.getInstallStep().dependOn(&surface_run.step);
    _ = protean_build.addNativeSystem(b, dependency, .{
        .name = "protean",
        .application = .{ .source = .{
            .definition = dependency.path("examples/adaptive/definition.zig"),
            .types = dependency.path("examples/adaptive/types.zig"),
        } },
        .environment = dependency.path("examples/adaptive/environment.zig"),
    });
}
