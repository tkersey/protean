const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;

pub const posix_symbols = [_][]const u8{
    "open", "openat", "read",   "write", "pread",      "pwrite",   "unlinkat",
    "poll", "kill",   "linkat", "pipe",  "socketpair", "fchmodat",
};

pub const Gcc = struct {
    driver: LazyPath,
    identity: LazyPath,
    header: LazyPath,
    host_runtime: ?LazyPath = null,

    pub const Driver = struct { path: LazyPath, name: []const u8 };

    pub fn init(b: *Build, target: Build.ResolvedTarget, driver: Driver) Gcc {
        const probe = b.addSystemCommand(&.{"bash"});
        probe.addFileArg2(b.path("tools/native/gcc-identity.sh"), .{});
        probe.addDirectoryArg2(driver.path.dirname(), .{ .make_absolute = true });
        probe.addArg(driver.name);
        probe.addArg(target.result.zigTriple(b.allocator) catch @panic("out of memory"));
        probe.has_side_effects = true;
        const original = b.graph.path(.zig_lib, "zig.h");
        return .{
            .header = if (isDarwin(target)) portableHeader(b, original) else original,
            .driver = driver.path,
            .identity = probe.addOutputFileArg2("gcc-identity.json", .{}),
        };
    }

    fn portableHeader(b: *Build, original: LazyPath) LazyPath {
        const fix = b.addSystemCommand(&.{ "awk", "-f" });
        fix.addFileArg2(b.path("tools/native/zig-0.17.1-header.awk"), .{});
        fix.addFileArg2(original, .{});
        return fix.captureStdOut(.{ .basename = "zig.h" });
    }

    pub fn fromDependency(dep: *Build.Dependency) ?Gcc {
        return .{
            .driver = dep.builder.named_lazy_paths.get("darwin-gcc") orelse return null,
            .identity = dep.namedLazyPath("darwin-gcc-identity"),
            .header = dep.namedLazyPath("darwin-zig-header"),
            .host_runtime = dep.namedLazyPath("darwin-gcc-rt"),
        };
    }

    pub fn isDarwin(target: Build.ResolvedTarget) bool {
        return target.result.os.tag == .macos and target.result.cpu.arch == .aarch64;
    }

    fn command(gcc: Gcc, b: *Build, name: []const u8) *Build.Step.Run {
        const run = Build.Step.Run.create(b, name);
        run.addFileArg2(gcc.driver, .{ .make_absolute = true });
        run.addFileInput(gcc.identity);
        return run;
    }

    pub fn object(
        gcc: Gcc,
        b: *Build,
        source: LazyPath,
        includes: LazyPath,
        flags: []const []const u8,
        gate: ?*Build.Step,
        name: []const u8,
    ) LazyPath {
        const run = gcc.command(b, "compile native C with GCC");
        run.addArgs(flags);
        run.addDirectoryArg2(includes, .{ .prefix = "-I" });
        run.addArgs(&.{ "-MD", "-MF" });
        _ = run.addDepFileOutputArg2("headers.d", .{});
        run.addArg("-c");
        run.addFileArg2(source, .{});
        run.addArg("-o");
        if (gate) |step| run.step.dependOn(step);
        return run.addOutputFileArg2(name, .{});
    }

    fn cRoot(b: *Build, original: *Build.Module) *Build.Module {
        const root = b.allocator.create(Build.Module) catch @panic("out of memory");
        root.init(b, .{ .existing = original });
        root.cached_graph = .{ .modules = &.{}, .names = &.{} };
        var target = original.resolved_target.?;
        target.query.ofmt = .c;
        target.result.ofmt = .c;
        root.resolved_target = target;
        root.link_libc = true;
        return root;
    }

    pub fn minimum(b: *Build, target: Build.ResolvedTarget) []const u8 {
        return b.fmt("-mmacosx-version-min={f}", .{target.result.os.version_range.semver.min});
    }

    pub fn generatedFlags(
        b: *Build,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        strip: bool,
    ) []const []const u8 {
        return b.allocator.dupe([]const u8, &.{
            "-std=gnu17",
            "-march=armv8-a",
            minimum(b, target),
            "-fno-strict-aliasing",
            "-fno-ipa-modref",
            "-Wno-builtin-declaration-mismatch",
            switch (optimize) {
                .safe => "-O2",
                .debug => "-Og",
                .fast => "-O3",
                .small => "-Os",
            },
            if (strip) "-g0" else "-g",
        }) catch @panic("out of memory");
    }

    fn generatedObject(gcc: Gcc, b: *Build, compile: *Build.Step.Compile) LazyPath {
        const root = compile.root_module;
        const mode = root.optimize orelse .debug;
        const strip = root.strip orelse (mode != .debug);
        const flags = generatedFlags(b, root.resolved_target.?, mode, strip);
        const name = b.fmt("{s}.o", .{compile.name});
        return gcc.object(b, compile.getEmittedBin(), gcc.header.dirname(), flags, null, name);
    }

    pub fn zigObject(gcc: Gcc, b: *Build, name: []const u8, root: *Build.Module) LazyPath {
        const emitted = b.addObject(.{
            .name = name,
            .root_module = cRoot(b, root),
            .use_llvm = false,
        });
        return gcc.generatedObject(b, emitted);
    }

    pub fn runtime(gcc: Gcc, b: *Build, requested: Build.ResolvedTarget) LazyPath {
        var target = requested;
        target.query.ofmt = .macho;
        target.result.ofmt = .macho;
        if (gcc.host_runtime) |host_runtime| {
            const host_min = b.graph.host.result.os.version_range.semver.min;
            if (target.result.os.version_range.semver.min.order(host_min) == .eq)
                return host_runtime;
        }
        const root = b.createModule(.{
            .root_source_file = b.graph.path(.zig_lib, "compiler_rt.zig"),
            .target = target,
            .optimize = .small,
            .strip = true,
        });
        const archive = b.createModule(.{ .target = target, .optimize = .small });
        archive.addObjectFile(gcc.zigObject(b, "compiler-rt", root));
        return b.addLibrary(.{
            .name = "zig-rt",
            .root_module = archive,
            .linkage = .static,
            .use_llvm = false,
        }).getEmittedBin();
    }
};

pub const Binary = struct {
    compile: *Build.Step.Compile,
    path: LazyPath,
    debug_symbols: ?LazyPath = null,

    fn fromDependency(
        b: *Build,
        dep: *Build.Dependency,
        options: anytype,
        link_native: bool,
    ) Binary {
        const gcc = Gcc.fromDependency(dep);
        const library = if (gcc != null and link_native)
            dep.namedLazyPath("darwin-native-library")
        else
            null;
        return create(b, options, gcc, library, link_native);
    }

    pub fn addTest(
        b: *Build,
        dep: *Build.Dependency,
        options: Build.TestOptions,
        link_native: bool,
    ) Binary {
        return fromDependency(b, dep, options, link_native);
    }

    pub fn addExecutable(
        b: *Build,
        dep: *Build.Dependency,
        options: Build.ExecutableOptions,
        link_native: bool,
    ) Binary {
        return fromDependency(b, dep, options, link_native);
    }

    pub fn create(
        b: *Build,
        options: anytype,
        gcc: ?Gcc,
        library: ?LazyPath,
        aliases: bool,
    ) Binary {
        var selected = options;
        const root = selected.root_module;
        if (gcc != null) {
            if (!Gcc.isDarwin(root.resolved_target.?)) @panic("expected aarch64-macos target");
            selected.root_module = Gcc.cRoot(b, root);
            selected.use_llvm = false;
        }
        const emitted = if (@TypeOf(options) == Build.TestOptions)
            b.addTest(selected)
        else
            b.addExecutable(selected);
        const driver = gcc orelse return .{ .compile = emitted, .path = emitted.getEmittedBin() };
        const object = driver.generatedObject(b, emitted);
        if (emitted.kind == .test_obj) return .{ .compile = emitted, .path = object };
        const target = root.resolved_target.?;
        const script = b.addWriteFiles().add("darwin-link.sh", @embedFile("darwin-link.sh"));
        const link = b.addSystemCommand(&.{"bash"});
        link.addFileArg2(script, .{});
        link.addArg("link");
        link.addFileArg2(driver.driver, .{ .make_absolute = true });
        link.addFileInput(driver.identity);
        const path = link.addOutputFileArg2(emitted.name, .{});
        _ = link.addDepFileOutputArg2("linked.d", .{});
        link.addArg(Gcc.minimum(b, target));
        link.addFileArg2(object, .{ .make_absolute = true });
        const search = b.addSystemCommand(&.{"bash"});
        search.addFileArg2(script, .{});
        search.addArg("find");
        search.addFileArg2(driver.driver, .{ .make_absolute = true });
        addModuleInputs(b, link, search, emitted, library);
        link.addFileArg2(driver.runtime(b, target), .{ .make_absolute = true });
        if (aliases) for (posix_symbols) |sym| {
            link.addArg(b.fmt("-Wl,-alias,_{s},_protean_posix_{s}", .{ sym, sym }));
        };
        const stripped = root.strip orelse ((root.optimize orelse .debug) != .debug);
        if (stripped) {
            link.addArg("-Wl,-S,-x");
            return .{ .compile = emitted, .path = path };
        }
        const dsym = b.addSystemCommand(&.{ "/usr/bin/dsymutil", "-o" });
        const symbols = dsym.addOutputDirectoryArg2(b.fmt("{s}.dSYM", .{emitted.name}), .{});
        dsym.addArg("--embed-resource");
        dsym.addFileArg2(emitted.getEmittedBin(), .{
            .make_absolute = true,
            .suffix = b.fmt("=Sources/{s}.c", .{emitted.name}),
        });
        dsym.addArg("--embed-resource");
        dsym.addFileArg2(driver.header, .{ .make_absolute = true, .suffix = "=Sources/zig.h" });
        dsym.addFileArg2(path, .{ .make_absolute = true });
        dsym.addFileInput(object);
        return .{ .compile = emitted, .path = path, .debug_symbols = symbols };
    }

    fn addModuleInputs(
        b: *Build,
        link: *Build.Step.Run,
        search: *Build.Step.Run,
        emitted: *Build.Step.Compile,
        library: ?LazyPath,
    ) void {
        const initial = search.argv.items.len;
        for (emitted.getCompileDependencies(false)) |artifact| {
            if (artifact.isDynamicLibrary()) continue;
            for (artifact.root_module.getGraph().modules, 0..) |module, index| {
                if (module.link_libcpp == true) link.addArg("-lc++");
                addSearchPaths(link, search, module);
                var sources: std.ArrayList(Build.Module.LinkObject) = .empty;
                for (module.link_objects.items) |input| switch (input) {
                    .other_step => |other| {
                        if (other.kind != .lib and artifact != emitted) continue;
                        const file = other.getEmittedBin();
                        link.addFileArg2(file, .{ .make_absolute = true });
                        if (other.isDynamicLibrary()) {
                            link.addArgs(&.{ "-Xlinker", "-rpath", "-Xlinker" });
                            link.addDirectoryArg2(file.dirname(), .{ .make_absolute = true });
                        }
                    },
                    .static_path => |file| if (artifact == emitted) {
                        link.addFileArg2(file, .{ .make_absolute = true });
                    },
                    .system_lib => |lib| addSystemLibrary(b, search, lib),
                    else => if (artifact == emitted) {
                        sources.append(b.allocator, input) catch @panic("out of memory");
                    },
                };
                if (sources.items.len != 0) {
                    const foreign = b.createModule(.{});
                    foreign.init(b, .{ .existing = module });
                    foreign.root_source_file = null;
                    foreign.import_table = .empty;
                    foreign.cached_graph = .{ .modules = &.{}, .names = &.{} };
                    foreign.link_objects = sources;
                    for (module.link_objects.items) |input| {
                        if (input != .system_lib) continue;
                        foreign.link_objects.append(b.allocator, input) catch @panic("OOM");
                    }
                    var target = emitted.root_module.resolved_target.?;
                    target.query.ofmt = .macho;
                    target.result.ofmt = .macho;
                    foreign.resolved_target = target;
                    const archive = b.addLibrary(.{
                        .linkage = .static,
                        .name = b.fmt("link-input-{d}", .{index}),
                        .root_module = foreign,
                        .use_llvm = false,
                    });
                    link.addArgs(&.{ "-Xlinker", "-force_load", "-Xlinker" });
                    link.addFileArg2(archive.getEmittedBin(), .{ .make_absolute = true });
                }
            }
        }
        if (search.argv.items.len != initial) {
            search.has_side_effects = true;
            link.addFileArg2(search.captureStdOut(.{ .basename = "link.rsp" }), .{ .prefix = "@" });
        }
        if (library) |file| {
            link.addArg("--native-library");
            link.addFileArg2(file, .{ .make_absolute = true });
        }
        emitted.root_module.cached_graph = .{ .modules = &.{}, .names = &.{} };
    }

    fn addSearchPaths(link: *Build.Step.Run, search: *Build.Step.Run, module: *Build.Module) void {
        for (module.lib_paths.items) |path| {
            search.addDirectoryArg2(path, .{ .prefix = "-L", .make_absolute = true });
        }
        for (module.include_dirs.items) |dir| switch (dir) {
            .framework_path, .framework_path_system => |path| {
                search.addDirectoryArg2(path, .{ .prefix = "-F", .make_absolute = true });
            },
            else => {},
        };
        for (module.rpaths.items) |path| {
            link.addArgs(&.{ "-Xlinker", "-rpath", "-Xlinker" });
            switch (path) {
                .lazy_path => |dir| link.addDirectoryArg2(dir, .{ .make_absolute = true }),
                .special => |name| link.addArg(name),
            }
        }
        for (module.frameworks.keys(), module.frameworks.values()) |name, opts| {
            search.addArgs(&.{
                "--framework",
                name,
                if (opts.needed) "needed" else if (opts.weak) "weak" else "normal",
            });
        }
    }

    fn addSystemLibrary(b: *Build, search: *Build.Step.Run, lib: Build.Module.SystemLib) void {
        if (lib.use_pkg_config != .no) {
            if (pkgConfigFlags(b, lib.name)) |flags| {
                var i: usize = 0;
                while (i < flags.libs.len) : (i += 1) {
                    const flag = flags.libs[i];
                    const value = if (flag.len == 2) value: {
                        i += 1;
                        break :value flags.libs[i];
                    } else flag[2..];
                    if (flag[1] == 'L') {
                        search.addArg(b.fmt("-L{s}", .{value}));
                    } else addLibrarySearch(search, value, lib);
                }
                search.addArgs(flags.unknown_flags);
                for (flags.cflags) |arg| {
                    if (std.mem.eql(u8, arg, "-rpath")) {
                        search.addArgs(&.{ "-Xlinker", "-rpath", "-Xlinker" });
                    } else search.addArg(arg);
                }
                return;
            }
            if (lib.use_pkg_config == .force) @panic("pkg-config could not resolve library");
        }
        addLibrarySearch(search, lib.name, lib);
    }

    fn addLibrarySearch(
        search: *Build.Step.Run,
        name: []const u8,
        lib: Build.Module.SystemLib,
    ) void {
        search.addArgs(&.{
            "--system-library",
            name,
            @tagName(lib.preferred_link_mode),
            @tagName(lib.search_strategy),
            if (lib.needed) "needed" else if (lib.weak) "weak" else "normal",
        });
    }

    fn pkgConfigFlags(b: *Build, name: []const u8) ?std.zig.PkgConfig.Parsed {
        b.graph.poisonCache();
        const pc = std.zig.PkgConfig.exe(&b.graph.environ_map);
        const list = b.runFallible(&.{ pc, "--list-all" }, .{ .stderr_behavior = .ignore });
        if (list != .success) return null;
        var diagnostic: std.zig.PkgConfig.Diagnostic = undefined;
        const known = std.zig.PkgConfig.init(b.allocator, list.success, &diagnostic) catch
            return null;
        const found = known.find(name) orelse return null;
        const libs = b.runFallible(&.{ pc, known.all[found].name, "--libs" }, .{
            .stderr_behavior = .ignore,
        });
        if (libs != .success) return null;
        return std.zig.PkgConfig.parse(b.allocator, libs.success) catch null;
    }

    pub fn run(binary: Binary, b: *Build) *Build.Step.Run {
        if (binary.compile.rootModuleTarget().ofmt != .c) return b.addRunArtifact(binary.compile);
        const step = Build.Step.Run.create(b, b.fmt("run {s}", .{binary.compile.name}));
        step.addFileArg2(binary.path, .{});
        if (binary.compile.kind == .@"test") {
            if (binary.compile.test_runner == null or binary.compile.test_runner.?.mode == .server)
                step.enableTestRunnerMode()
            else
                step.expectExitCode(0);
        }
        return step;
    }

    pub fn install(
        binary: Binary,
        b: *Build,
        options: Build.Step.InstallArtifact.Options,
    ) *Build.Step.InstallArtifact {
        if (binary.compile.rootModuleTarget().ofmt != .c)
            return b.addInstallArtifact(binary.compile, options);
        const step = b.addInstallArtifact(binary.compile, .{ .dest_dir = .disabled });
        const dest: Build.InstallDir = switch (options.dest_dir) {
            .disabled => return step,
            .default => .bin,
            .override => |dir| dir,
        };
        const name = options.dest_sub_path orelse binary.compile.name;
        step.step.dependOn(&b.addInstallFileWithDir(binary.path, dest, name).step);
        if (binary.debug_symbols) |symbols| {
            step.step.dependOn(&b.addInstallDirectory(.{
                .source_dir = symbols,
                .install_dir = dest,
                .install_subdir = b.fmt("{s}.dSYM", .{name}),
            }).step);
        }
        return step;
    }
};
