const std = @import("std");
const Graph = struct {
    b: *std.Build,
    optimize: std.lang.Optimize,
    protean: *std.Build.Module,
    horos: *std.Build.Module,
    data: *std.Build.Module,
    contracts: *std.Build.Module,
    gate: *std.Build.Step,
    target: ?std.Build.ResolvedTarget = null,

    fn module(g: Graph, path: []const u8) *std.Build.Module {
        return g.b.createModule(.{
            .root_source_file = g.b.path(path),
            .target = g.target orelse g.b.graph.host,
            .optimize = g.optimize,
            .imports = &.{
                .{ .name = "protean", .module = g.protean },
                .{ .name = "horos", .module = g.horos },
                .{ .name = "horos_data", .module = g.data },
                .{ .name = "protean_contracts", .module = g.contracts },
                .{ .name = "contracts", .module = g.contracts },
            },
        });
    }
    fn helper(g: Graph, name: []const u8) *std.Build.Module {
        return g.module(g.b.fmt("src/{s}.zig", .{name}));
    }
    fn testModule(g: Graph, step: *std.Build.Step, module_value: *std.Build.Module) void {
        const tests = g.b.addTest(.{
            .root_module = module_value,
            .use_llvm = if (g.b.graph.host.result.os.tag == .linux and g.b.graph.host.result.cpu.arch == .x86_64) false else null,
        });
        tests.step.dependOn(g.gate);
        step.dependOn(&g.b.addRunArtifact(tests).step);
    }
    fn emitter(g: Graph, name: []const u8, module_value: *std.Build.Module) *std.Build.Step.Compile {
        const executable = g.b.addExecutable(.{
            .name = name,
            .root_module = module_value,
            .use_llvm = if (g.b.graph.host.result.os.tag == .linux and g.b.graph.host.result.cpu.arch == .x86_64) false else null,
        });
        executable.step.dependOn(g.gate);
        return executable;
    }
};

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
            @compileError("Zig 0.17.0 is required");
    }
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const source = b.option(std.Build.LazyPath, "horos-source", "Authenticated immutable Horos source copy");
    const native_enabled = b.option(bool, "native", "Enable native Kronos host modules") orelse true;
    const kronos_source = b.option(std.Build.LazyPath, "kronos-source", "Immutable Kronos source for native agreement") orelse b.path(".protean-native/inputs/kronos");
    const sqlite_source = b.option(std.Build.LazyPath, "sqlite-source", "Authenticated optional native SQLite source") orelse b.path(".protean-native/inputs/sqlite");
    const data = if (source) |root| b.createModule(.{
        .root_source_file = root.path(b, "src/data/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) else b.dependency("horos", .{ .target = b.graph.host, .optimize = optimize }).module("horos_data");
    const horos = if (source) |root| b.createModule(.{
        .root_source_file = root.path(b, "src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    }) else b.dependency("horos", .{ .target = b.graph.host, .optimize = optimize }).module("horos");
    const contracts = b.createModule(.{
        .root_source_file = b.path("src/contracts.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    });
    const protean = b.createModule(.{
        .root_source_file = b.path("src/protean.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "horos", .module = horos }, .{ .name = "horos_data", .module = data }, .{ .name = "protean_contracts", .module = contracts } },
    });
    const host_tool = b.addExecutable(.{
        .name = "protean-native-build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/native/build_entry.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{.{ .name = "hash_abi", .module = b.createModule(.{ .root_source_file = b.path("runtime/native/hash_abi.zig"), .target = b.graph.host, .optimize = .safe }) }},
        }),
        .use_llvm = if (b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == .x86_64) false else null,
    });
    // Keep the driver on its existing backend and reuse the optimized primitive
    // without linking SQLite or any dependency that this driver must first admit.
    const build_hash = b.addLibrary(.{
        .name = "protean-build-hash",
        .linkage = .static,
        .root_module = b.createModule(.{ .root_source_file = b.path("runtime/native/hash.zig"), .target = b.graph.host, .optimize = .safe }),
        .use_llvm = true,
    });
    host_tool.root_module.linkLibrary(build_hash);
    const source_guard = b.addRunArtifact(host_tool);
    source_guard.addArg("verify-horos");
    source_guard.addFileArg2(b.path("conformance/protean/dependencies.lock.json"), .{});
    if (source) |path| {
        source_guard.addDirectoryArg2(path, .{ .make_absolute = true });
        source_guard.addArg("source");
    } else {
        source_guard.addDirectoryArg2(b.dependency("horos", .{ .target = b.graph.host, .optimize = optimize }).path("."), .{ .make_absolute = true });
        source_guard.addArg("package");
    }
    source_guard.has_side_effects = true;
    source_guard.expectExitCode(0);
    // Module consumers do not select this package's artifact steps. Carry the
    // authentication prerequisite in their module graph, without runtime code.
    const admission_files = b.addWriteFiles();
    admission_files.step.dependOn(&source_guard.step);
    const admission = b.createModule(.{
        .root_source_file = admission_files.add("protean_dependency_admission.zig", ""),
    });
    protean.addImport("_protean_dependency_admission", admission);
    contracts.addImport("_protean_dependency_admission", admission);
    if (source != null) {
        // These override modules are constructed by Protean, not upstream modules.
        horos.addImport("_protean_dependency_admission", admission);
        data.addImport("_protean_dependency_admission", admission);
    }
    // Emitters and native checks use the host graph above. Exported modules
    // independently honor a consumer's requested target.
    const public_data = if (target.query.isNative()) data else if (source) |root| b.createModule(.{
        .root_source_file = root.path(b, "src/data/root.zig"),
        .target = target,
        .optimize = optimize,
    }) else b.dependency("horos", .{ .target = target, .optimize = optimize }).module("horos_data");
    const public_horos = if (target.query.isNative()) horos else if (source) |root| b.createModule(.{
        .root_source_file = root.path(b, "src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = public_data }},
    }) else b.dependency("horos", .{ .target = target, .optimize = optimize }).module("horos");
    const public_contracts = if (target.query.isNative()) contracts else b.createModule(.{
        .root_source_file = b.path("src/contracts.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = public_data }},
    });
    const public_protean = if (target.query.isNative()) protean else b.createModule(.{
        .root_source_file = b.path("src/protean.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "horos", .module = public_horos }, .{ .name = "horos_data", .module = public_data }, .{ .name = "protean_contracts", .module = public_contracts } },
    });
    if (!target.query.isNative()) {
        public_protean.addImport("_protean_dependency_admission", admission);
        public_contracts.addImport("_protean_dependency_admission", admission);
        if (source != null) {
            public_horos.addImport("_protean_dependency_admission", admission);
            public_data.addImport("_protean_dependency_admission", admission);
        }
    }
    b.modules.put(b.allocator, b.dupe("horos"), public_horos) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("horos_data"), public_data) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("protean_contracts"), public_contracts) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("protean"), public_protean) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("protean_host_authoring"), protean) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("horos_host_authoring"), horos) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("horos_data_host"), data) catch @panic("out of memory");
    b.modules.put(b.allocator, b.dupe("protean_contracts_host"), contracts) catch @panic("out of memory");
    const g: Graph = .{ .b = b, .optimize = optimize, .protean = protean, .horos = horos, .data = data, .contracts = contracts, .gate = &source_guard.step };
    const check = b.step("protean-authoring-tests", "Check retained authoring contracts");
    const adaptive_types = g.module("examples/adaptive/types.zig");
    const adaptive_definition = g.module("examples/adaptive/definition.zig");
    adaptive_definition.addImport("application_types", adaptive_types);
    const emitter_module = g.module("tools/native/emit.zig");
    emitter_module.addImport("definition", adaptive_definition);
    emitter_module.addImport("application_types", adaptive_types);
    const adaptive_assets = b.addRunArtifact(g.emitter("protean-assets", emitter_module));
    const adaptive_image = adaptive_assets.addOutputFileArg2("program.bpi3", .{});
    const adaptive_application = adaptive_assets.addOutputFileArg2("application.json", .{});
    check.dependOn(&adaptive_assets.step);
    const adaptive_image_step = b.step("protean-image", "Emit the adaptive Horos program and ordinary contracts");
    adaptive_image_step.dependOn(&b.addInstallFileWithDir(adaptive_image, .prefix, "protean/adaptive/program.bpi3").step);
    adaptive_image_step.dependOn(&b.addInstallFileWithDir(adaptive_application, .prefix, "protean/adaptive/application.json").step);
    const aggregate = b.step("check-protean", "Check authoring and pure contracts without Kronos");
    const lint = b.step("lint", "Check formatting and the Zig source inventory");
    const format_check = b.addRunFile(.zig_exe);
    format_check.addArgs(&.{ "fmt", "--check", "build.zig", "build_protean.zig", "build_native.zig", "src", "runtime/native", "tools/native", "examples/adaptive", "test/protean", "test/protean/https_probe.zig", "test/consumers/adaptive/build.zig", "test/authoring_tests.zig" });
    lint.dependOn(&format_check.step);
    lint.dependOn(&b.addSystemCommand(&.{ "sh", "tools/check_zig_paths.sh" }).step);
    check.dependOn(lint);
    g.testModule(check, g.module("test/authoring_tests.zig"));
    g.testModule(check, g.module("src/test_root.zig"));
    const admitted = g.module("test/protean/admission.zig");
    admitted.addImport("admission", g.helper("admission"));
    g.testModule(check, admitted);
    const dialogue = g.module("test/protean/dialogue_probe.zig");
    dialogue.addImport("interaction", g.helper("interaction"));
    g.testModule(check, dialogue);
    inline for (.{
        .{ "model_runtime_callback", "Protean model declaration has unknown field 'execute'" },
        .{ "model_unsupported_codec", "Protean model codec is unsupported for 'value': []const u8" },
        .{ "model_unknown_parameter", "protean model parameters contain unsupported field 'provider_magic'" },
        .{ "model_unknown_field", "protean.model unknown source field 'paramters'" },
        .{ "model_noncanonical_temperature", "protean model temperature must be a canonical decimal from 0 through 2" },
        .{ "prompt_unknown_field", "protean.prompt.literal unknown source field 'contents'" },
        .{ "skill_unknown_field", "protean.skill unknown source field 'actons'" },
    }) |negative| {
        const rejected = b.addTest(.{ .root_module = g.module("test/protean/" ++ negative[0] ++ ".zig") });
        rejected.expect_errors = .{ .contains = negative[1] };
        rejected.step.dependOn(g.gate);
        check.dependOn(&rejected.step);
    }
    const helper_tests = b.addTest(.{ .root_module = host_tool.root_module });
    check.dependOn(&b.addRunArtifact(helper_tests).step);
    const native_checks = b.step("check-native", "Check native and custody contracts against the selected Kronos");
    const native_product = b.step("check-native-product", "Qualify the native adaptive application on the selected supported platform");
    const native_consumer = b.step("check-native-https", "Check native HTTPS against an independent endpoint");
    native_checks.dependOn(native_product);
    native_product.dependOn(native_consumer);
    if (native_enabled) {
        const kronos = b.createModule(.{
            .root_source_file = kronos_source.path(b, "src/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos_data", .module = data }},
        });
        const native_guard = b.addRunArtifact(host_tool);
        native_guard.addArg("verify-native");
        native_guard.addFileArg2(b.path("conformance/protean/dependencies.lock.json"), .{});
        native_guard.addDirectoryArg2(kronos_source, .{ .make_absolute = true });
        native_guard.addDirectoryArg2(sqlite_source, .{ .make_absolute = true });
        native_guard.addFileArg2(b.path("conformance/protean/native-dependencies.lock.json"), .{});
        native_guard.has_side_effects = true;
        native_guard.expectExitCode(0);
        native_guard.step.dependOn(&source_guard.step);
        var native_graph = g;
        native_graph.gate = &native_guard.step;
        const native_admission_files = b.addWriteFiles();
        native_admission_files.step.dependOn(&native_guard.step);
        const native_admission = b.createModule(.{ .root_source_file = native_admission_files.add("native_dependency_admission.zig", "") });
        const host_environment = nativeEnvironment(b, b.graph.host, optimize, kronos, data, contracts, native_admission, sqlite_source, &native_guard.step);
        // Host-default Linux packaging selects musl. Explicit unsupported target
        // requests are rejected by the public helper before creating emitters.
        const default_musl = target.query.isNative() and target.result.os.tag == .linux and target.result.cpu.arch == .x86_64;
        const native_target = if (default_musl) b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }) else target;
        const native_data = if (!default_musl) public_data else b.createModule(.{
            .root_source_file = public_data.root_source_file,
            .target = native_target,
            .optimize = optimize,
        });
        const native_contracts = if (!default_musl) public_contracts else b.createModule(.{
            .root_source_file = b.path("src/contracts.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos_data", .module = native_data }},
        });
        // Application type files can derive the existing model contract at
        // comptime. Only used runtime functions are linked; the deployed path
        // never invokes the authoring compiler or imports a language loader.
        const native_horos = if (!default_musl) public_horos else b.createModule(.{
            .root_source_file = public_horos.root_source_file,
            .target = native_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos_data", .module = native_data }},
        });
        const native_protean = if (!default_musl) public_protean else b.createModule(.{
            .root_source_file = b.path("src/protean.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "horos", .module = native_horos }, .{ .name = "horos_data", .module = native_data }, .{ .name = "protean_contracts", .module = native_contracts } },
        });
        const native_kronos = if (!default_musl and target.query.isNative()) kronos else b.createModule(.{
            .root_source_file = kronos_source.path(b, "src/root.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos_data", .module = native_data }},
        });
        const public_environment = if (!default_musl and target.query.isNative()) host_environment else nativeEnvironment(b, native_target, optimize, native_kronos, native_data, native_contracts, native_admission, sqlite_source, &native_guard.step);
        // Executed native checks use the delivered ABI when it runs on this
        // host. This also shares its C library instead of compiling a GNU-only
        // SQLite copy solely for tests of a musl product.
        const native_on_host = native_target.result.cpu.arch == b.graph.host.result.cpu.arch and native_target.result.os.tag == b.graph.host.result.os.tag;
        if (native_on_host) {
            native_graph.target = native_target;
            native_graph.protean = native_protean;
            native_graph.horos = native_horos;
            native_graph.data = native_data;
            native_graph.contracts = native_contracts;
        }
        const checked_kronos = if (native_on_host) native_kronos else kronos;
        const checked_environment = if (native_on_host) public_environment else host_environment;
        b.addNamedLazyPath("native-sqlite-source", sqlite_source);
        b.installArtifact(host_tool);
        b.modules.put(b.allocator, b.dupe("protean_native"), public_environment) catch @panic("out of memory");
        b.modules.put(b.allocator, b.dupe("protean_native_data"), native_data) catch @panic("out of memory");
        b.modules.put(b.allocator, b.dupe("protean_native_contracts"), native_contracts) catch @panic("out of memory");
        b.modules.put(b.allocator, b.dupe("protean_native_types"), native_protean) catch @panic("out of memory");
        const product_supported = (native_target.result.os.tag == .macos and native_target.result.cpu.arch == .aarch64) or
            (native_target.result.os.tag == .linux and native_target.result.cpu.arch == .x86_64 and native_target.result.abi == .musl);
        if (product_supported) {
            const native_modules: @import("build_native.zig").Modules = .{
                .root = b.path("."),
                .protean = protean,
                .horos = horos,
                .data = data,
                .contracts = contracts,
                .native = public_environment,
                .native_data = native_data,
                .native_contracts = native_contracts,
                .native_protean = native_protean,
                .sqlite_source = sqlite_source,
                .host_tool = host_tool,
            };
            const adaptive_product = @import("build_native.zig").addWithModules(b, native_modules, .{
                .name = "protean",
                .application = .{ .emitted = .{ .image = adaptive_image, .application = adaptive_application, .types = b.path("examples/adaptive/types.zig") } },
                .environment = b.path("examples/adaptive/environment.zig"),
            });
            const adaptive_reference = b.step("protean", "Build the native Kronos reference host for the adaptive program");
            adaptive_reference.dependOn(&adaptive_product.install.step);
            adaptive_reference.dependOn(adaptive_image_step);
            native_product.dependOn(adaptive_reference);
            const adaptive_peer = nativeCheckCommand(b);
            adaptive_peer.addArgs(&.{ "node", "test/protean/native_adaptive.mjs" });
            adaptive_peer.addFileArg2(adaptive_product.executable.getEmittedBin(), .{ .make_absolute = true });
            adaptive_peer.addFileArg2(adaptive_application, .{ .make_absolute = true });
            adaptive_peer.addFileArg2(adaptive_image, .{ .make_absolute = true });
            native_product.dependOn(&adaptive_peer.step);
            const consumer_module = b.createModule(.{
                .root_source_file = b.path("test/protean/https_probe.zig"),
                .target = native_graph.target orelse b.graph.host,
                .optimize = optimize,
                .strip = optimize != .debug,
                .imports = &.{ .{ .name = "kronos", .module = checked_kronos }, .{ .name = "horos_data", .module = native_graph.data }, .{ .name = "protean_native", .module = checked_environment }, .{ .name = "protean_contracts", .module = native_graph.contracts } },
            });
            const consumer = b.addExecutable(.{
                .name = "protean-https-probe",
                .root_module = consumer_module,
                .use_llvm = if (native_target.result.os.tag == .linux and native_target.result.cpu.arch == .x86_64) false else null,
            });
            consumer.step.dependOn(&native_guard.step);
            const https_peer = nodeCommand(b);
            https_peer.addArgs(&.{ "node", "test/protean/native_https.mjs" });
            https_peer.addFileArg2(consumer.getEmittedBin(), .{ .make_absolute = true });
            native_consumer.dependOn(&https_peer.step);
        } else {
            const unsupported = b.addFail("native product supports aarch64-macos and x86_64-linux-musl");

            native_consumer.dependOn(&unsupported.step);
            native_product.dependOn(&unsupported.step);
        }
        // These roots share exact module identities; compile their retained
        // tests together instead of rebuilding the same compiler eleven times.
        const native_suite = native_graph.module("test/protean/native_tests.zig");
        // Keep unit assertions and safety checks without optimizing test code.
        // The deployed applications and public API/HTTPS probe remain safe.
        native_suite.optimize = .debug;
        native_suite.strip = optimize != .debug;
        native_suite.addImport("kronos", checked_kronos);
        native_suite.addImport("protean_native", checked_environment);
        const adaptive_test_types = native_graph.module("examples/adaptive/types.zig");
        const adaptive_test_environment = native_graph.module("examples/adaptive/environment.zig");
        adaptive_test_environment.addImport("application_types", adaptive_test_types);
        adaptive_test_environment.addImport("protean_native", checked_environment);
        native_suite.addImport("adaptive_types", adaptive_test_types);
        native_suite.addImport("adaptive_environment", adaptive_test_environment);
        native_suite.addAnonymousImport("adaptive_image", .{ .root_source_file = adaptive_image });
        native_suite.addAnonymousImport("adaptive_application", .{ .root_source_file = adaptive_application });
        native_suite.addImport("native_asset_writer", native_graph.module("tools/native/emit.zig"));
        native_graph.testModule(native_product, native_suite);
        // Zig does not collect test declarations from named dependency modules.
        // Run the runtime's own root explicitly; the integration root above
        // independently exercises its public task owner with authored programs.
        const native_unit_tests = b.allocator.create(std.Build.Module) catch @panic("out of memory");
        native_unit_tests.init(b, .{ .existing = checked_environment });
        native_unit_tests.optimize = .debug;
        native_graph.testModule(native_product, native_unit_tests);
    } else {
        const missing = b.addFail("enable -Dnative=true with authenticated Kronos and SQLite sources");
        native_checks.dependOn(&missing.step);
        native_consumer.dependOn(&missing.step);
    }
    const pure = nodeCommand(b);
    pure.addArgs(&.{ "node", "--test", "test/protean/values.test.mjs" });
    pure.has_side_effects = true;
    check.dependOn(&pure.step);
    aggregate.dependOn(check);
    b.step("check-authoring-core", "Check retained authoring contracts").dependOn(check);
    b.step("check", "Check Protean authoring").dependOn(aggregate);
    b.default_step = aggregate;
}

fn nativeEnvironment(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, kronos: *std.Build.Module, data: *std.Build.Module, contracts: *std.Build.Module, admission: *std.Build.Module, sqlite_source: std.Build.LazyPath, gate: *std.Build.Step) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(u32, "sqlite_heap_bytes", @import("build_native.zig").sqlite_heap_bytes);
    options.addOption(u64, "state_bytes", @import("build_native.zig").state_bytes);
    options.addOption(u32, "state_format", @import("build_native.zig").state_format);
    // The exact admitted 0.17 compiler still supplies build-time translate-c.
    // Keep translation bound to that target/compiler tuple; @cImport is gone.
    const translated = b.addTranslateC(.{
        .root_source_file = b.path("runtime/native/native_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translated.addIncludePath(sqlite_source);
    translated.step.dependOn(gate);
    // C has a stable ABI here. Compile the large SQLite translation unit once
    // for this target, rather than again inside every executable and test root.
    const translated_module = translated.createModule();
    const c_module = b.createModule(.{
        .root_source_file = b.path("runtime/native/hash.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = true,
    });
    c_module.addIncludePath(sqlite_source);
    c_module.addCSourceFile(.{ .file = sqlite_source.path(b, "sqlite3.c"), .flags = @import("build_native.zig").sqliteFlags(optimize) });
    c_module.addCSourceFile(.{ .file = b.path("runtime/native/native_c.c"), .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" } });
    const c_library = b.addLibrary(.{ .name = "protean-native-c", .linkage = .static, .root_module = c_module, .use_llvm = true });
    c_library.step.dependOn(gate);
    const module = b.createModule(.{
        .root_source_file = b.path("runtime/native/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "kronos", .module = kronos },
            .{ .name = "horos_data", .module = data },
            .{ .name = "protean_contracts", .module = contracts },
            .{ .name = "_native_dependency_admission", .module = admission },
            .{ .name = "native_c", .module = translated_module },
        },
    });
    module.addOptions("native_options", options);
    module.linkLibrary(c_library);
    return module;
}

// Keep nested Node qualifiers on the build's selected toolchain and prefix.
fn nativeCheckCommand(b: *std.Build) *std.Build.Step.Run {
    const run = nodeCommand(b);
    // Inherited stdio holds Zig's global diagnostic lock for the whole check.
    // Capture both streams through stderr, preserving logs on success/failure
    // while independent compilers and peers continue. Positional argv remains
    // quoted, and exec preserves the checked process's exit/signal disposition.
    const prefix = [_]std.Build.Step.Run.Arg{
        .{ .bytes = "sh" },
        .{ .bytes = "-c" },
        .{ .bytes = "exec \"$@\" >&2" },
        .{ .bytes = "native-check" },
    };
    run.argv.insertSlice(b.allocator, 0, &prefix) catch @panic("out of memory");
    run.has_side_effects = true; // Checked stdio must never cache qualification.
    run.expectExitCode(0);
    return run;
}

fn nodeCommand(b: *std.Build) *std.Build.Step.Run {
    // Remove the runner context at launch, without caching the caller's PATH
    // or package/cache environment in the configured graph.
    const run = b.addSystemCommand(&.{ "env", "-u", "NODE_TEST_CONTEXT" });
    run.addFileArg2(.zig_exe, .{ .prefix = "PROTEAN_ZIG_EXE=", .make_absolute = true });
    run.addDirectoryArg2(.zig_lib, .{ .prefix = "ZIG_LIB_DIR=", .make_absolute = true });
    run.addDirectoryArg2(b.graph.path(.install_prefix, ""), .{ .prefix = "PROTEAN_BUILD_PREFIX=", .make_absolute = true });
    return run;
}
