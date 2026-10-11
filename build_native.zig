//! Build/environmental API. No target program executes while generating assets.
const std = @import("std");
/// One packaging constant supplies both the namespace reader and manifest.
pub const state_format: u32 = 10;
pub const sqlite_heap_bytes: u32 = 16 * 1024 * 1024;
pub const state_bytes: u64 = 256 * 1024 * 1024;
pub const sqlite_flags: []const []const u8 = &.{ "-std=c99", "-DSQLITE_THREADSAFE=1", "-DSQLITE_ENABLE_MEMSYS5=1", "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=1", "-DSQLITE_DEFAULT_FOREIGN_KEYS=1" };

pub fn sqliteFlags(optimize: std.lang.Optimize) []const []const u8 {
    // Reduce optimization work on the amalgamation while retaining safe mode's
    // hardening and undefined-behavior traps. Other build modes keep their defaults.
    return if (optimize == .safe) sqlite_flags ++ &[_][]const u8{"-O1"} else sqlite_flags;
}

pub const Assets = struct {
    image: std.Build.LazyPath,
    application: std.Build.LazyPath,
    types: std.Build.LazyPath,
};
pub const Source = struct { definition: std.Build.LazyPath, types: std.Build.LazyPath };
pub const Options = struct {
    name: []const u8,
    environment: std.Build.LazyPath,
    /// Reuse the complete emitted application for another target. Its type
    /// mapping travels with its image, so a second source cannot be ignored.
    application: union(enum) { source: Source, emitted: Assets },
};
pub const Product = struct {
    executable: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    assets: Assets,
    manifest: std.Build.LazyPath,
};

/// The dependency must select its admitted Kronos source and SQLite with the normal
/// Protean build options. Pure authoring consumers never need those options.
pub fn addNativeSystem(b: *std.Build, dependency: *std.Build.Dependency, options: Options) Product {
    const product = addWithModules(b, .{
        .root = dependency.path("."),
        .protean = dependency.module("protean_host_authoring"),
        .horos = dependency.module("horos_host_authoring"),
        .data = dependency.module("horos_data_host"),
        .contracts = dependency.module("protean_contracts_host"),
        .native = dependency.module("protean_native"),
        .native_contracts = dependency.module("protean_native_contracts"),
        .native_protean = dependency.module("protean_native_types"),
        .native_data = dependency.module("protean_native_data"),
        .sqlite_source = dependency.namedLazyPath("native-sqlite-source"),
        .host_tool = dependency.artifact("protean-native-build"),
    }, options);
    b.getInstallStep().dependOn(&product.install.step);
    return product;
}

// Also used by Protean's own examples so the downstream and repository recipes
// select the identical builder. Module identities come from one admitted graph.
pub const Modules = struct {
    root: std.Build.LazyPath,
    protean: *std.Build.Module,
    horos: *std.Build.Module,
    data: *std.Build.Module,
    contracts: *std.Build.Module,
    native: *std.Build.Module,
    native_contracts: *std.Build.Module,
    native_protean: *std.Build.Module,
    native_data: *std.Build.Module,
    sqlite_source: std.Build.LazyPath,
    host_tool: *std.Build.Step.Compile,
};

pub fn addWithModules(b: *std.Build, modules: Modules, options: Options) Product {
    const target = modules.native.resolved_target orelse @panic("native target is required");
    const supported = (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) or
        (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and target.result.abi == .musl);
    if (!supported) @panic("native product supports aarch64-macos and x86_64-linux-musl");
    const optimize = modules.native.optimize orelse .safe;
    const assets = switch (options.application) {
        .source => |source| generate(b, modules, source),
        .emitted => |assets| assets,
    };

    const types = b.createModule(.{
        .root_source_file = assets.types,
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "protean_contracts", .module = modules.native_contracts }, .{ .name = "protean", .module = modules.native_protean } },
    });
    const environment = b.createModule(.{
        .root_source_file = options.environment,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protean_native", .module = modules.native },
            .{ .name = "application_types", .module = types },
            .{ .name = "protean_contracts", .module = modules.native_contracts },
            .{ .name = "horos_data", .module = modules.native_data },
        },
    });
    const manifest = b.addRunArtifact(modules.host_tool);
    manifest.addArg("manifest");
    manifest.has_side_effects = true;
    manifest.addFileArg2(assets.image, .{});
    manifest.addFileArg2(assets.application, .{});
    manifest.addFileArg2(modules.root.path(b, "conformance/protean/dependencies.lock.json"), .{});
    manifest.addFileArg2(modules.root.path(b, "LICENSE"), .{});
    const kronos = modules.native.import_table.get("kronos") orelse @panic("missing admitted Kronos module");
    manifest.addFileArg2(kronos.root_source_file.?.dirname().dirname().path(b, "LICENSE"), .{});
    manifest.addFileArg2(modules.native_data.root_source_file.?.dirname().dirname().dirname().path(b, "LICENSE"), .{});
    manifest.addDirectoryArg2(modules.sqlite_source, .{ .make_absolute = true });
    manifest.addArg(b.fmt("{d}", .{sqlite_heap_bytes}));
    manifest.addArg(std.json.Stringify.valueAlloc(b.allocator, sqliteFlags(optimize), .{}) catch @panic("out of memory"));
    manifest.addArg(b.fmt("{d}", .{state_bytes}));
    manifest.addArg(b.fmt("agent-native-state/{d}", .{state_format}));
    manifest.addArgs(&.{ target.result.zigTriple(b.allocator) catch @panic("out of memory"), @tagName(optimize) });
    // Always-run steps do not hash file arguments into their output directory
    // in Zig 0.17. Distinguish the named products even on the same target so
    // concurrent manifest writers cannot overwrite one another's output.
    const manifest_file = manifest.addOutputFileArg2(b.fmt("{s}-manifest.json", .{options.name}), .{});
    manifest.addFileArg2(modules.root.path(b, "conformance/protean/native-dependencies.lock.json"), .{});
    manifest.addFileArg2(.zig_exe, .{ .make_absolute = true });
    manifest.addDirectoryArg2(.zig_lib, .{ .make_absolute = true });

    const root = b.createModule(.{
        .root_source_file = modules.root.path(b, "runtime/native/entry.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "protean_native", .module = modules.native },
            .{ .name = "environment", .module = environment },
            .{ .name = "application_types", .module = types },
            .{ .name = "protean_contracts", .module = modules.native_contracts },
        },
    });
    root.addAnonymousImport("native_image", .{ .root_source_file = assets.image });
    root.addAnonymousImport("native_application", .{ .root_source_file = assets.application });
    root.addAnonymousImport("native_manifest", .{ .root_source_file = manifest_file });
    const executable = b.addExecutable(.{
        .name = options.name,
        .root_module = root,
        .use_llvm = if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64) false else null,
    });
    const install = b.addInstallArtifact(executable, .{});
    return .{ .executable = executable, .install = install, .assets = assets, .manifest = manifest_file };
}

fn generate(b: *std.Build, modules: Modules, source: Source) Assets {
    const optimize = modules.protean.optimize orelse .safe;
    const types = b.createModule(.{
        .root_source_file = source.types,
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "protean_contracts", .module = modules.contracts }, .{ .name = "protean", .module = modules.protean } },
    });
    const definition = b.createModule(.{
        .root_source_file = source.definition,
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protean", .module = modules.protean },
            .{ .name = "horos", .module = modules.horos },
            .{ .name = "horos_data", .module = modules.data },
            .{ .name = "protean_contracts", .module = modules.contracts },
            .{ .name = "application_types", .module = types },
        },
    });
    const emitter = b.addExecutable(.{
        .name = "protean-native-assets",
        .use_llvm = if (b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == .x86_64) false else null,
        .root_module = b.createModule(.{
            .root_source_file = modules.root.path(b, "tools/native/emit.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "definition", .module = definition },
                .{ .name = "application_types", .module = types },
                .{ .name = "protean", .module = modules.protean },
                .{ .name = "horos", .module = modules.horos },
            },
        }),
    });
    const run = b.addRunArtifact(emitter);
    return .{
        .image = run.addOutputFileArg2("program.bpi3", .{}),
        .application = run.addOutputFileArg2("application.json", .{}),
        .types = source.types,
    };
}
