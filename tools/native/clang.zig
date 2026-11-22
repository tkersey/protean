const std = @import("std");

pub fn stageSources(
    tool: *std.Build.Step.Compile,
    sources: *std.Build.Step.WriteFile,
    optimize: std.lang.Optimize,
    name: []const u8,
) std.Build.LazyPath {
    const b = tool.step.owner;
    const copy = b.addRunArtifact(tool);
    copy.addArgs(&.{ "stage-c", name, @tagName(optimize) });
    copy.setCwd(sources.getDirectory());
    return copy.addOutputDirectoryArg2(name, .{ .make_absolute = true });
}

pub fn configuration(
    tool: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.ConfigHeader {
    const b = tool.step.owner;
    const guard = b.addRunArtifact(tool);
    guard.addArg("check-c-environment");
    guard.has_side_effects = true;
    guard.expectExitCode(0);
    const temporary = b.addTempFiles().add("config.zig", "");
    const root = b.addWriteFiles().addCopyFile(temporary, "config.zig");
    const module = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = .safe,
        .strip = true,
        .link_libc = true,
    });
    const source = b.addWriteFiles().add("config.c", "int protean_c_configuration_probe;\n");
    module.addCSourceFile(.{ .file = source, .flags = &.{"-frecord-command-line"} });
    const probe = b.addObject(.{ .name = "config", .root_module = module, .use_llvm = true });
    probe.step.dependOn(&guard.step);
    const hash = b.addRunArtifact(tool);
    hash.addArg("c-configuration");
    hash.addFileArg2(probe.getEmittedBin(), .{});
    const template = hash.addOutputFileArg2("configuration.in", .{});
    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = template },
        .include_path = "protean_c_configuration.h",
    }, .{});
}

pub fn object(
    config: *std.Build.Step.ConfigHeader,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    source: std.Build.LazyPath,
    includes: ?std.Build.LazyPath,
    flags: []const []const u8,
    name: []const u8,
) std.Build.LazyPath {
    const b = config.step.owner;
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = true,
    });
    module.addConfigHeader(config);
    if (includes) |dir| module.addIncludePath(dir);
    module.addCSourceFile(.{ .file = source, .flags = flags });
    const compiled = b.addObject(.{ .name = name, .root_module = module, .use_llvm = true });
    return compiled.getEmittedBin();
}

fn probeSource(b: *std.Build, source: std.Build.LazyPath) !std.Build.LazyPath {
    const path = switch (source) {
        .cwd_relative => |path| path,
        else => return source,
    };
    const directory = std.fs.path.dirname(path) orelse ".";
    b.dependOnDirectoryMetadata(b.graph.cwdRelativePath(directory));
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, directory, b.allocator);
    return b.graph.cwdRelativePath(b.pathJoin(&.{ canonical, std.fs.path.basename(path) }));
}

pub fn probeStep(tool: *std.Build.Step.Compile, source: std.Build.LazyPath) void {
    const b = tool.step.owner;
    const target = b.graph.host;
    const probe = b.step("build-clang-probe", "Build the header mutation fixture");
    const physical = probeSource(b, source) catch |err| {
        const message = b.fmt("cannot resolve the probe source directory: {t}", .{err});
        probe.dependOn(&b.addFail(message).step);
        return;
    };
    const config = configuration(tool, target);
    const result = object(config, target, .safe, physical, null, &.{}, "probe");
    const install = b.addInstallFile(result, "probe.o");
    const path = b.addSystemCommand(&.{ "printf", "%s\n" });
    path.addFileArg2(result, .{ .make_absolute = true });
    path.has_side_effects = true;
    probe.dependOn(&install.step);
    probe.dependOn(&path.step);
}

pub fn build(b: *std.Build) void {
    const tool = b.addExecutable(.{
        .name = "protean-clang-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dependencies.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
        .use_llvm = if (b.graph.host.result.os.tag == .linux and
            b.graph.host.result.cpu.arch == .x86_64) false else null,
    });
    if (b.option(std.Build.LazyPath, "clang-probe-source", "Header mutation fixture")) |source| {
        probeStep(tool, source);
    }
}
