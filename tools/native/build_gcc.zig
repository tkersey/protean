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
    host_runtime: ?LazyPath = null,

    pub const Driver = struct { path: LazyPath, name: []const u8 };

    pub fn init(b: *Build, target: Build.ResolvedTarget, driver: Driver) Gcc {
        const probe = b.addSystemCommand(&.{"bash"});
        probe.addFileArg2(b.path("tools/native/gcc-identity.sh"), .{});
        probe.addDirectoryArg2(driver.path.dirname(), .{ .make_absolute = true });
        probe.addArg(driver.name);
        probe.addArg(target.result.zigTriple(b.allocator) catch @panic("out of memory"));
        probe.has_side_effects = true;
        return .{
            .driver = driver.path,
            .identity = probe.addOutputFileArg2("gcc-identity.json", .{}),
        };
    }

    pub fn fromDependency(dep: *Build.Dependency) ?Gcc {
        return .{
            .driver = dep.builder.named_lazy_paths.get("darwin-gcc") orelse return null,
            .identity = dep.namedLazyPath("darwin-gcc-identity"),
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
                .safe => "-O1",
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
        return gcc.object(b, compile.getEmittedBin(), .zig_lib, flags, null, name);
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
        const target = root.resolved_target.?;
        const link = driver.command(b, "link native executable with GCC");
        link.addArg(Gcc.minimum(b, target));
        link.addFileArg2(driver.generatedObject(b, emitted), .{});
        if (library) |file| link.addFileArg2(file, .{});
        link.addFileArg2(driver.runtime(b, target), .{});
        if (aliases) for (posix_symbols) |sym| {
            link.addArg(b.fmt("-Wl,-alias,_{s},_protean_posix_{s}", .{ sym, sym }));
        };
        link.addArg("-o");
        return .{ .compile = emitted, .path = link.addOutputFileArg2(emitted.name, .{}) };
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
        return step;
    }
};
