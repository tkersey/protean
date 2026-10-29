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
    fn testModule(
        g: Graph,
        step: *std.Build.Step,
        module_value: *std.Build.Module,
    ) *std.Build.Step.Compile {
        return g.testModuleFiltered(step, module_value, &.{});
    }
    fn testModuleFiltered(
        g: Graph,
        step: *std.Build.Step,
        module_value: *std.Build.Module,
        filters: []const []const u8,
    ) *std.Build.Step.Compile {
        const tests = g.compileTests(module_value, filters);
        const run = g.b.addRunArtifact(tests);
        run.has_side_effects = true;
        step.dependOn(&run.step);
        return tests;
    }
    fn compileTests(
        g: Graph,
        module_value: *std.Build.Module,
        filters: []const []const u8,
    ) *std.Build.Step.Compile {
        const tests = g.b.addTest(.{
            .root_module = module_value,
            .filters = filters,
            .use_llvm = if (linuxX86(g.b.graph.host)) g.optimize != .debug else null,
        });
        tests.step.dependOn(g.gate);
        return tests;
    }
    fn testModuleGrouped(
        g: Graph,
        step: *std.Build.Step,
        module_value: *std.Build.Module,
        groups: []const []const []const u8,
        selected: ?usize,
    ) *std.Build.Step.Compile {
        if (selected) |index| return g.testModuleFiltered(step, module_value, groups[index]);
        const tests = g.compileTests(module_value, &.{});
        const run = nodeCommand(g.b);
        run.addArg("node");
        run.addFileArg2(g.b.path("tools/native/qualification_tests.mjs"), .{});
        run.addArtifactArg(tests);
        run.addArg(
            std.json.Stringify.valueAlloc(g.b.allocator, groups, .{}) catch @panic("out of memory"),
        );
        run.has_side_effects = true;
        run.expectExitCode(0);
        step.dependOn(&run.step);
        return tests;
    }
    fn emitter(
        g: Graph,
        name: []const u8,
        module_value: *std.Build.Module,
    ) *std.Build.Step.Compile {
        const executable = g.b.addExecutable(.{
            .name = name,
            .root_module = module_value,
            .use_llvm = if (linuxX86(g.b.graph.host)) g.optimize != .debug else null,
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
    var graph: BuildGraph = .{ .b = b };
    graph.configure();
    graph.hostModules();
    graph.hostTool();
    graph.admitSource();
    graph.publicModules();
    graph.publishModules();
    graph.adaptiveAssets();
    graph.authoringChecks();
    graph.negativeTests();
    graph.nativeSteps();
    if (graph.native_enabled) graph.nativeBuild() else graph.missingNative();
    graph.pureChecks();
}

const BuildGraph = struct {
    b: *std.Build,
    optimize: std.lang.Optimize = undefined,
    target: std.Build.ResolvedTarget = undefined,
    native_target: std.Build.ResolvedTarget = undefined,
    source: ?std.Build.LazyPath = undefined,
    native_enabled: bool = undefined,
    default_musl: bool = undefined,
    kosmos_source: std.Build.LazyPath = undefined,
    sqlite_source: std.Build.LazyPath = undefined,
    adaptive_image: std.Build.LazyPath = undefined,
    adaptive_application: std.Build.LazyPath = undefined,
    runtime_source: std.Build.LazyPath = undefined,
    data: *std.Build.Module = undefined,
    horos: *std.Build.Module = undefined,
    contracts: *std.Build.Module = undefined,
    protean: *std.Build.Module = undefined,
    admission: *std.Build.Module = undefined,
    public_data: *std.Build.Module = undefined,
    public_horos: *std.Build.Module = undefined,
    public_contracts: *std.Build.Module = undefined,
    public_protean: *std.Build.Module = undefined,
    kosmos: *std.Build.Module = undefined,
    native_admission: *std.Build.Module = undefined,
    host_environment: *std.Build.Module = undefined,
    native_data: *std.Build.Module = undefined,
    native_contracts: *std.Build.Module = undefined,
    native_horos: *std.Build.Module = undefined,
    native_protean: *std.Build.Module = undefined,
    native_kosmos: *std.Build.Module = undefined,
    public_environment: *std.Build.Module = undefined,
    checked_kosmos: *std.Build.Module = undefined,
    checked_environment: *std.Build.Module = undefined,
    native_suite: *std.Build.Module = undefined,
    host_tool: *std.Build.Step.Compile = undefined,
    workspace_peer: *std.Build.Step.Compile = undefined,
    mobility_peer: *std.Build.Step.Compile = undefined,
    source_guard: *std.Build.Step.Run = undefined,
    native_guard: *std.Build.Step.Run = undefined,
    g: Graph = undefined,
    native_graph: Graph = undefined,
    check: *std.Build.Step = undefined,
    adaptive_image_step: *std.Build.Step = undefined,
    aggregate: *std.Build.Step = undefined,
    native_checks: *std.Build.Step = undefined,
    native_owner_integration: *std.Build.Step = undefined,
    native_owner_support: *std.Build.Step = undefined,
    native_packaged: *std.Build.Step = undefined,
    native_executable: *std.Build.Step = undefined,
    native_consumer: *std.Build.Step = undefined,
    scheduler_benchmark: *std.Build.Step = undefined,
    workspace_checks: *std.Build.Step = undefined,
    workspace_general: *std.Build.Step = undefined,
    adaptive_product: @import("build_native.zig").Product = undefined,

    fn nativeBuild(s: *BuildGraph) void {
        s.nativeSetup();
        s.hostEnvironment();
        s.nativeTargetModules();
        s.nativeEnvironmentSetup();
        s.workspaceGeneral();
        s.workspaceRuntime();
        s.workspacePeers();
        s.workspaceSemantics();
        s.publishNative();
        const product_supported =
            (s.native_target.result.os.tag == .macos and
                s.native_target.result.cpu.arch == .aarch64) or
            (s.native_target.result.os.tag == .linux and
                s.native_target.result.cpu.arch == .x86_64 and
                s.native_target.result.abi == .musl);
        if (product_supported) {
            s.productBuild();
            s.nativeSmoke();
            s.runtimeDiagnostics();
            s.httpsConsumer();
        } else s.unsupportedProduct();
        s.nativeSuite();
        s.nativeOwner();
        s.workspaceRecovery();
        s.scheduler();
        s.adaptiveResponse();
        s.nativeCrash();
    }

    fn configure(s: *BuildGraph) void {
        s.optimize = s.b.standardOptimizeOption(.{});
        s.target = s.b.standardTargetOptions(.{});
        s.source = s.b.option(
            std.Build.LazyPath,
            "horos-source",
            "Authenticated immutable Horos source copy",
        );
        s.native_enabled = s.b.option(
            bool,
            "native",
            "Enable native Kosmos host modules",
        ) orelse true;
        s.kosmos_source = s.b.option(
            std.Build.LazyPath,
            "kosmos-source",
            "Immutable Kosmos source for native agreement",
        ) orelse s.b.path(".protean-native/inputs/kosmos");
        s.sqlite_source = s.b.option(
            std.Build.LazyPath,
            "sqlite-source",
            "Authenticated optional native SQLite source",
        ) orelse s.b.path(".protean-native/inputs/sqlite");
    }

    fn hostModules(s: *BuildGraph) void {
        s.data = if (s.source) |root| s.b.createModule(.{
            .root_source_file = root.path(s.b, "src/data/root.zig"),
            .target = s.b.graph.host,
            .optimize = s.optimize,
        }) else s.b.dependency("horos", .{
            .target = s.b.graph.host,
            .optimize = s.optimize,
        }).module(
            "horos_data",
        );
        s.horos = if (s.source) |root| s.b.createModule(.{
            .root_source_file = root.path(s.b, "src/root.zig"),
            .target = s.b.graph.host,
            .optimize = s.optimize,
            .imports = &.{.{ .name = "horos_data", .module = s.data }},
        }) else s.b.dependency("horos", .{
            .target = s.b.graph.host,
            .optimize = s.optimize,
        }).module(
            "horos",
        );
        s.contracts = s.b.createModule(.{
            .root_source_file = s.b.path("src/contracts.zig"),
            .target = s.b.graph.host,
            .optimize = s.optimize,
            .imports = &.{.{ .name = "horos_data", .module = s.data }},
        });
        s.protean = s.b.createModule(.{
            .root_source_file = s.b.path("src/protean.zig"),
            .target = s.b.graph.host,
            .optimize = s.optimize,
            .imports = &.{
                .{ .name = "horos", .module = s.horos },
                .{ .name = "horos_data", .module = s.data },
                .{ .name = "protean_contracts", .module = s.contracts },
            },
        });
    }

    fn hostTool(s: *BuildGraph) void {
        s.host_tool = s.b.addExecutable(.{
            .name = "protean-native-build",
            .root_module = s.b.createModule(.{
                .root_source_file = s.b.path("tools/native/build_entry.zig"),
                .target = s.b.graph.host,
                .optimize = .safe,
                .imports = &.{.{
                    .name = "hash_abi",
                    .module = s.b.createModule(.{
                        .root_source_file = s.b.path("runtime/native/hash_abi.zig"),
                        .target = s.b.graph.host,
                        .optimize = .safe,
                    }),
                }},
            }),
            .use_llvm = if (linuxX86(s.b.graph.host)) false else null,
        });
        // Keep the driver on its existing backend and reuse the optimized primitive
        // without linking SQLite or any dependency that this driver must first admit.
        const build_hash = s.b.addLibrary(.{
            .name = "protean-build-hash",
            .linkage = .static,
            .root_module = s.b.createModule(.{
                .root_source_file = s.b.path("runtime/native/hash.zig"),
                .target = s.b.graph.host,
                .optimize = .safe,
            }),
            .use_llvm = true,
        });
        s.host_tool.root_module.linkLibrary(build_hash);
    }

    fn admitSource(s: *BuildGraph) void {
        s.source_guard = s.b.addRunArtifact(s.host_tool);
        s.source_guard.addArg("verify-horos");
        s.source_guard.addFileArg2(s.b.path("conformance/protean/dependencies.lock.json"), .{});
        if (s.source) |path| {
            s.source_guard.addDirectoryArg2(path, .{ .make_absolute = true });
            s.source_guard.addArg("source");
        } else {
            s.source_guard.addDirectoryArg2(s.b.dependency("horos", .{
                .target = s.b.graph.host,
                .optimize = s.optimize,
            }).path(
                ".",
            ), .{ .make_absolute = true });
            s.source_guard.addArg("package");
        }
        s.source_guard.has_side_effects = true;
        s.source_guard.expectExitCode(0);
        // Module consumers do not select this package's artifact steps. Carry the
        // authentication prerequisite in their module graph, without runtime code.
        const admission_files = s.b.addWriteFiles();
        admission_files.step.dependOn(&s.source_guard.step);
        s.admission = s.b.createModule(.{
            .root_source_file = admission_files.add("protean_dependency_admission.zig", ""),
        });
        s.protean.addImport("_protean_dependency_admission", s.admission);
        s.contracts.addImport("_protean_dependency_admission", s.admission);
        if (s.source != null) {
            // These override modules are constructed by Protean, not upstream modules.
            s.horos.addImport("_protean_dependency_admission", s.admission);
            s.data.addImport("_protean_dependency_admission", s.admission);
        }
    }

    fn publicModules(s: *BuildGraph) void {
        const host_target = s.target.query.isNative();
        // Emitters and native checks use the host graph above. Exported modules
        // independently honor a consumer's requested target.
        s.public_data = if (host_target) s.data else if (s.source) |root| s.b.createModule(
            .{
                .root_source_file = root.path(s.b, "src/data/root.zig"),
                .target = s.target,
                .optimize = s.optimize,
            },
        ) else s.b.dependency(
            "horos",
            .{ .target = s.target, .optimize = s.optimize },
        ).module(
            "horos_data",
        );
        s.public_horos = if (host_target) s.horos else if (s.source) |root| s.b.createModule(
            .{
                .root_source_file = root.path(s.b, "src/root.zig"),
                .target = s.target,
                .optimize = s.optimize,
                .imports = &.{.{ .name = "horos_data", .module = s.public_data }},
            },
        ) else s.b.dependency(
            "horos",
            .{ .target = s.target, .optimize = s.optimize },
        ).module(
            "horos",
        );
        s.public_contracts = if (host_target) s.contracts else s.b.createModule(.{
            .root_source_file = s.b.path("src/contracts.zig"),
            .target = s.target,
            .optimize = s.optimize,
            .imports = &.{.{ .name = "horos_data", .module = s.public_data }},
        });
        s.public_protean = if (host_target) s.protean else s.b.createModule(.{
            .root_source_file = s.b.path("src/protean.zig"),
            .target = s.target,
            .optimize = s.optimize,
            .imports = &.{
                .{ .name = "horos", .module = s.public_horos },
                .{ .name = "horos_data", .module = s.public_data },
                .{ .name = "protean_contracts", .module = s.public_contracts },
            },
        });
        if (!host_target) {
            s.public_protean.addImport("_protean_dependency_admission", s.admission);
            s.public_contracts.addImport("_protean_dependency_admission", s.admission);
            if (s.source != null) {
                s.public_horos.addImport("_protean_dependency_admission", s.admission);
                s.public_data.addImport("_protean_dependency_admission", s.admission);
            }
        }
    }

    fn publishModules(s: *BuildGraph) void {
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("horos"),
            s.public_horos,
        ) catch @panic(
            "out of memory",
        );
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("horos_data"),
            s.public_data,
        ) catch @panic(
            "out of memory",
        );
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_contracts"),
            s.public_contracts,
        ) catch @panic("out of memory");
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean"),
            s.public_protean,
        ) catch @panic(
            "out of memory",
        );
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_host_authoring"),
            s.protean,
        ) catch @panic("out of memory");
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("horos_host_authoring"),
            s.horos,
        ) catch @panic("out of memory");
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("horos_data_host"),
            s.data,
        ) catch @panic(
            "out of memory",
        );
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_contracts_host"),
            s.contracts,
        ) catch @panic("out of memory");
        s.g = .{
            .b = s.b,
            .optimize = s.optimize,
            .protean = s.protean,
            .horos = s.horos,
            .data = s.data,
            .contracts = s.contracts,
            .gate = &s.source_guard.step,
        };
    }

    fn adaptiveAssets(s: *BuildGraph) void {
        s.check = s.b.step("protean-authoring-tests", "Check retained authoring contracts");
        const adaptive_types = s.g.module("examples/adaptive/types.zig");
        const adaptive_definition = s.g.module("examples/adaptive/definition.zig");
        adaptive_definition.addImport("application_types", adaptive_types);
        const emitter_module = s.g.module("tools/native/emit.zig");
        emitter_module.addImport(
            "construction",
            s.g.module("runtime/native/program_construction.zig"),
        );
        emitter_module.addImport("definition", adaptive_definition);
        emitter_module.addImport("application_types", adaptive_types);
        const adaptive_emitter = s.g.emitter("protean-assets", emitter_module);
        // Match the public builder's backend for this build-time authoring tool.
        // The emitted image is independently compared with the installed product.
        if (linuxX86(s.b.graph.host)) adaptive_emitter.use_llvm = false;
        const adaptive_assets = s.b.addRunArtifact(adaptive_emitter);
        s.adaptive_image = adaptive_assets.addOutputFileArg2("program.bpi3", .{});
        s.adaptive_application = adaptive_assets.addOutputFileArg2("application.json", .{});
        s.check.dependOn(&adaptive_assets.step);
        s.adaptive_image_step = s.b.step(
            "protean-image",
            "Emit the adaptive Horos program and ordinary contracts",
        );
        s.adaptive_image_step.dependOn(
            &s.b.addInstallFileWithDir(
                s.adaptive_image,
                .prefix,
                "protean/adaptive/program.bpi3",
            ).step,
        );
        s.adaptive_image_step.dependOn(
            &s.b.addInstallFileWithDir(
                s.adaptive_application,
                .prefix,
                "protean/adaptive/application.json",
            ).step,
        );
    }

    fn authoringChecks(s: *BuildGraph) void {
        s.aggregate = s.b.step(
            "check-protean",
            "Check authoring and pure contracts without Kosmos",
        );
        const lint = s.b.step("lint", "Check formatting and the Zig source inventory");
        const format_check = s.b.addRunFile(.zig_exe);
        format_check.addArgs(&.{
            "fmt",
            "--check",
            "build.zig",
            "build_protean.zig",
            "build_native.zig",
            "src",
            "runtime/native",
            "tools/native",
            "examples/adaptive",
            "test/protean",
            "test/protean/https_probe.zig",
            "test/consumers/adaptive",
            "test/authoring_tests.zig",
        });
        lint.dependOn(&format_check.step);
        lint.dependOn(&s.b.addSystemCommand(&.{ "sh", "tools/check_zig_paths.sh" }).step);
        s.check.dependOn(lint);
        const workspace_values = s.b.step(
            "check-workspace-values",
            "Check runtime-schema workspace value projection",
        );
        const source_records = s.b.step(
            "check-source-records",
            "Check the model-facing Horos source-record transport",
        );
        const program_construction = s.b.step(
            "check-program-construction",
            "Check untrusted general source construction",
        );
        workspace_values.dependOn(program_construction);
        source_records.dependOn(program_construction);
        s.check.dependOn(program_construction);
        const admitted = s.g.module("test/protean/admission.zig");
        admitted.addImport("admission", s.g.helper("admission"));
        const dialogue = s.g.module("test/protean/dialogue_probe.zig");
        dialogue.addImport("interaction", s.g.helper("interaction"));
        const authoring_tests = [_]*std.Build.Step.Compile{
            s.g.testModule(s.check, s.g.module("test/authoring_tests.zig")),
            s.g.testModule(s.check, s.g.module("src/test_root.zig")),
            s.g.testModule(
                program_construction,
                s.g.module("runtime/native/program_construction.zig"),
            ),
            s.g.testModule(s.check, admitted),
            s.g.testModule(s.check, dialogue),
        };
        if (linuxX86(s.b.graph.host)) {
            for (authoring_tests) |tests| tests.use_llvm = false;
        }
    }

    fn negativeTests(s: *BuildGraph) void {
        inline for (.{
            .{ "model_runtime_callback", "Protean model declaration has unknown field 'execute'" },
            .{
                "model_unsupported_codec",
                "Protean model codec is unsupported for 'value': []const u8",
            },
            .{
                "model_unknown_parameter",
                "protean model parameters contain unsupported field 'provider_magic'",
            },
            .{ "model_unknown_field", "protean.model unknown source field 'paramters'" },
            .{
                "model_noncanonical_temperature",
                "protean model temperature must be a canonical decimal from 0 through 2",
            },
            .{ "prompt_unknown_field", "protean.prompt.literal unknown source field 'contents'" },
            .{ "skill_unknown_field", "protean.skill unknown source field 'actons'" },
        }) |negative| {
            const rejected = s.b.addTest(.{
                .root_module = s.g.module("test/protean/" ++ negative[0] ++ ".zig"),
            });
            rejected.expect_errors = .{ .contains = negative[1] };
            rejected.step.dependOn(s.g.gate);
            s.check.dependOn(&rejected.step);
        }
        const helper_tests = s.b.addTest(.{ .root_module = s.host_tool.root_module });
        const helper_tests_run = s.b.addRunArtifact(helper_tests);
        helper_tests_run.has_side_effects = true;
        s.check.dependOn(&helper_tests_run.step);
    }

    fn nativeSteps(s: *BuildGraph) void {
        s.native_checks = s.b.step(
            "check-native",
            "Check native and custody contracts against the selected Kosmos",
        );
        const native_product = s.b.step(
            "check-native-product",
            "Qualify the native adaptive application on the selected supported platform",
        );
        const native_owner = s.b.step(
            "check-native-owner",
            "Qualify native owner, context, and recovery contracts",
        );
        s.native_owner_integration = s.b.step(
            "check-native-owner-integration",
            "Qualify native task and occurrence ownership",
        );
        s.native_owner_support = s.b.step(
            "check-native-owner-support",
            "Qualify native unit, context, and crash recovery contracts",
        );
        native_owner.dependOn(s.native_owner_integration);
        native_owner.dependOn(s.native_owner_support);
        s.native_packaged = s.b.step(
            "check-native-packaged",
            "Qualify the packaged adaptive executable and HTTPS isolation",
        );
        s.native_executable = s.b.step(
            "check-native-executable",
            "Qualify the packaged adaptive executable and process isolation",
        );
        s.native_consumer = s.b.step(
            "check-native-https",
            "Check native HTTPS against an independent endpoint",
        );
        s.scheduler_benchmark = s.b.step(
            "bench-native-scheduler",
            "Measure idle Service scans with a held worker",
        );
        s.native_checks.dependOn(native_product);
        native_product.dependOn(native_owner);
        native_product.dependOn(s.native_packaged);
        s.native_packaged.dependOn(s.native_consumer);
        s.native_packaged.dependOn(s.native_executable);
    }

    fn nativeSetup(s: *BuildGraph) void {
        s.kosmos = s.b.createModule(.{
            .root_source_file = s.kosmos_source.path(s.b, "src/root.zig"),
            .target = s.b.graph.host,
            .optimize = s.optimize,
            .imports = &.{.{ .name = "horos_data", .module = s.data }},
        });
        s.native_guard = s.b.addRunArtifact(s.host_tool);
        s.native_guard.addArg("verify-native");
        s.native_guard.addFileArg2(s.b.path("conformance/protean/dependencies.lock.json"), .{});
        s.native_guard.addDirectoryArg2(s.kosmos_source, .{ .make_absolute = true });
        s.native_guard.addDirectoryArg2(s.sqlite_source, .{ .make_absolute = true });
        s.native_guard.addFileArg2(
            s.b.path("conformance/protean/native-dependencies.lock.json"),
            .{},
        );
        s.native_guard.has_side_effects = true;
        s.native_guard.expectExitCode(0);
        s.native_guard.step.dependOn(&s.source_guard.step);
        // Kosmos checks these ordinary bytes against an independent source
        // rebuild. Verify their exact source/compiler/content bindings here;
        // downstream builds need not compile that same host generator again.
        const runtime_options = s.b.addOptions();
        runtime_options.addOption(
            []const u8,
            "horos_package",
            @import("build.zig.zon").dependencies.horos.hash,
        );
        const runtime_emitter = s.b.addExecutable(
            .{ .name = "protean-runtime-artifact", .root_module = s.b.createModule(.{
                .root_source_file = s.kosmos_source.path(s.b, "src/semantic_packaged.zig"),
                .target = s.b.graph.host,
                .optimize = s.optimize,
            }) },
        );
        runtime_emitter.root_module.addOptions("artifact_options", runtime_options);
        runtime_emitter.step.dependOn(&s.native_guard.step);
        const emit_runtime = s.b.addRunArtifact(runtime_emitter);
        const runtime_files = s.b.addWriteFiles();
        _ = runtime_files.addCopyFile(emit_runtime.captureStdOut(.{}), "semantic-core.kar");
        s.runtime_source = runtime_files.add(
            "runtime.zig",
            "pub const bytes = @embedFile(\"semantic-core.kar\");\n",
        );
        s.kosmos.addImport("horos", s.horos);
        s.kosmos.addImport(
            "packaged_runtime",
            s.b.createModule(.{
                .root_source_file = s.runtime_source,
                .target = s.b.graph.host,
                .optimize = s.optimize,
            }),
        );
        s.native_graph = s.g;
        s.native_graph.gate = &s.native_guard.step;
        const native_admission_files = s.b.addWriteFiles();
        native_admission_files.step.dependOn(&s.native_guard.step);
        s.native_admission = s.b.createModule(.{
            .root_source_file = native_admission_files.add("native_dependency_admission.zig", ""),
        });
    }

    fn hostEnvironment(s: *BuildGraph) void {
        s.host_environment = nativeEnvironment(
            s.b,
            s.b.graph.host,
            s.optimize,
            s.kosmos,
            s.data,
            s.contracts,
            s.horos,
            s.protean,
            s.native_admission,
            s.sqlite_source,
            &s.native_guard.step,
        );
        // Host-default Linux packaging selects musl. Explicit unsupported target
        // requests are rejected by the public helper before creating emitters.
    }

    fn nativeTargetModules(s: *BuildGraph) void {
        s.default_musl = s.target.query.isNative() and linuxX86(s.target);
        s.native_target = if (s.default_musl) s.b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .musl,
        }) else s.target;
        s.native_data = if (!s.default_musl) s.public_data else s.b.createModule(.{
            .root_source_file = s.public_data.root_source_file,
            .target = s.native_target,
            .optimize = s.optimize,
        });
        s.native_contracts = if (!s.default_musl) s.public_contracts else s.b.createModule(.{
            .root_source_file = s.b.path("src/contracts.zig"),
            .target = s.native_target,
            .optimize = s.optimize,
            .imports = &.{.{ .name = "horos_data", .module = s.native_data }},
        });
        // Application type files can derive the existing model contract at
        // comptime. Only used runtime functions are linked; the deployed path
        // never invokes the authoring compiler or imports a language loader.
        s.native_horos = if (!s.default_musl) s.public_horos else s.b.createModule(.{
            .root_source_file = s.public_horos.root_source_file,
            .target = s.native_target,
            .optimize = s.optimize,
            .imports = &.{.{ .name = "horos_data", .module = s.native_data }},
        });
        s.native_protean = if (!s.default_musl) s.public_protean else s.b.createModule(.{
            .root_source_file = s.b.path("src/protean.zig"),
            .target = s.native_target,
            .optimize = s.optimize,
            .imports = &.{
                .{ .name = "horos", .module = s.native_horos },
                .{ .name = "horos_data", .module = s.native_data },
                .{ .name = "protean_contracts", .module = s.native_contracts },
            },
        });
    }

    fn nativeEnvironmentSetup(s: *BuildGraph) void {
        const host_target = !s.default_musl and s.target.query.isNative();
        s.native_kosmos = if (host_target) s.kosmos else s.b.createModule(
            .{
                .root_source_file = s.kosmos_source.path(s.b, "src/root.zig"),
                .target = s.native_target,
                .optimize = s.optimize,
                .imports = &.{.{ .name = "horos_data", .module = s.native_data }},
            },
        );
        if (s.native_kosmos != s.kosmos) {
            s.native_kosmos.addImport("horos", s.native_horos);
            s.native_kosmos.addImport(
                "packaged_runtime",
                s.b.createModule(.{
                    .root_source_file = s.runtime_source,
                    .target = s.native_target,
                    .optimize = s.optimize,
                }),
            );
        }
        s.public_environment = if (host_target) s.host_environment else nativeEnvironment(
            s.b,
            s.native_target,
            s.optimize,
            s.native_kosmos,
            s.native_data,
            s.native_contracts,
            s.native_horos,
            s.native_protean,
            s.native_admission,
            s.sqlite_source,
            &s.native_guard.step,
        );
        // Executed native checks use the delivered ABI when it runs on this
        // host. This also shares its C library instead of compiling a GNU-only
        // SQLite copy solely for tests of a musl product.
        const native_on_host =
            s.native_target.result.cpu.arch == s.b.graph.host.result.cpu.arch and
            s.native_target.result.os.tag == s.b.graph.host.result.os.tag;
        if (native_on_host) {
            s.native_graph.target = s.native_target;
            s.native_graph.protean = s.native_protean;
            s.native_graph.horos = s.native_horos;
            s.native_graph.data = s.native_data;
            s.native_graph.contracts = s.native_contracts;
        }
        s.checked_kosmos = if (native_on_host) s.native_kosmos else s.kosmos;
        s.checked_environment = if (native_on_host) s.public_environment else s.host_environment;
    }

    fn workspaceGeneral(s: *BuildGraph) void {
        const workspace_programs = s.native_graph.module("test/protean/workspace_programs.zig");
        // Execute generated programs in the requested optimization mode.
        // These roots instantiate the evaluator as well as test orchestration.
        workspace_programs.strip = s.optimize != .debug;
        workspace_programs.addImport("kosmos", s.checked_kosmos);
        workspace_programs.addImport("protean_native", s.checked_environment);
        s.workspace_checks = s.b.step(
            "check-workspace-programs",
            "Execute general source-record programs through native Kosmos",
        );
        s.workspace_general = s.b.step(
            "check-workspace-general",
            "Qualify workspace execution, inputs and provenance",
        );
        const workspace_group = s.b.option(
            enum { execution, retention, history },
            "workspace-group",
            "Select independent workspace qualification cases (default: all)",
        );
        const workspace_general_tests = s.native_graph.testModuleGrouped(
            s.workspace_general,
            workspace_programs,
            &.{
                &.{
                    "BUILD-",
                    "WORK-C",
                    "WORK-06",
                    "WORK-08",
                    "exposure carries",
                    "workspace commands",
                    "CTX-01",
                    "deep recursive workspace",
                },
                &.{ "WORK-01", "AUT-07", "OWN-02" },
                &.{ "collected history", "WORK-14", "delegated model interpretation" },
            },
            if (workspace_group) |group| @backingInt(group) else null,
        );
        s.b.step("build-workspace-general-check", "Build the retained workspace test executable")
            .dependOn(&s.b.addInstallArtifact(workspace_general_tests, .{
            .dest_dir = .{ .override = .{ .custom = "verification" } },
            .dest_sub_path = "workspace-general",
        }).step);
    }

    fn workspaceRuntime(s: *BuildGraph) void {
        const workspace_runtime_module = s.native_graph.module(
            "test/protean/workspace_runtime.zig",
        );
        workspace_runtime_module.strip = s.optimize != .debug;
        workspace_runtime_module.addImport("kosmos", s.checked_kosmos);
        workspace_runtime_module.addImport("protean_native", s.checked_environment);
        const workspace_runtime_checks = s.b.step(
            "check-workspace-runtime",
            "Qualify runtime selection and bilateral workspace custody",
        );
        const runtime_workspace_group = s.b.option(
            enum { selection, succession },
            "runtime-workspace-group",
            "Select independent runtime workspace qualification cases (default: all)",
        );
        const workspace_runtime_tests = s.native_graph.testModuleGrouped(
            workspace_runtime_checks,
            workspace_runtime_module,
            &.{
                &.{ "runtime selection", "terminal parent cancellation", "scheduler bounds" },
                &.{
                    "delayed controls",
                    "controller succession precedes",
                    "controller succession preserves",
                    "native placement carries the current cut",
                    "frozen controller",
                },
            },
            if (runtime_workspace_group) |group| @backingInt(group) else null,
        );
        s.b.step(
            "build-workspace-runtime-check",
            "Build the retained runtime workspace test executable",
        )
            .dependOn(&s.b.addInstallArtifact(workspace_runtime_tests, .{
            .dest_dir = .{ .override = .{ .custom = "verification" } },
            .dest_sub_path = "workspace-runtime",
        }).step);
        s.workspace_checks.dependOn(s.workspace_general);
        s.native_checks.dependOn(s.workspace_checks);
    }

    fn workspacePeers(s: *BuildGraph) void {
        const workspace_semantics_module = s.native_graph.module(
            "test/protean/workspace_semantics.zig",
        );
        workspace_semantics_module.strip = s.optimize != .debug;
        workspace_semantics_module.addImport("kosmos", s.checked_kosmos);
        workspace_semantics_module.addImport("protean_native", s.checked_environment);
        s.workspace_peer = s.native_graph.emitter(
            "workspace-semantics",
            workspace_semantics_module,
        );
        s.b.step("build-workspace-peer", "Build the verification-only source and capsule byte peer")
            .dependOn(
            &s.b.addInstallArtifact(s.workspace_peer, .{ .dest_dir = .{ .override = .{
                .custom = "verification",
            } } }).step,
        );
        const mobility_peer_module = s.native_graph.module(
            "test/protean/runtime_mobility_peer.zig",
        );
        mobility_peer_module.strip = s.optimize != .debug;
        mobility_peer_module.addImport("kosmos", s.checked_kosmos);
        mobility_peer_module.addImport("protean_native", s.checked_environment);
        s.mobility_peer = s.native_graph.emitter("runtime-mobility-peer", mobility_peer_module);
        s.b.step(
            "build-runtime-mobility-peer",
            "Build the source-emission and read-only mobility fixture peer",
        )
            .dependOn(
            &s.b.addInstallArtifact(s.mobility_peer, .{ .dest_dir = .{ .override = .{
                .custom = "verification",
            } } }).step,
        );
    }

    fn workspaceSemantics(s: *BuildGraph) void {
        const workspace_semantics_run = s.b.addSystemCommand(&.{"node"});
        workspace_semantics_run.addFileArg2(s.b.path("test/protean/workspace_semantics.mjs"), .{});
        workspace_semantics_run.addArtifactArg(s.workspace_peer);
        workspace_semantics_run.addFileArg2((s.source orelse s.b.dependency("horos", .{
            .target = s.b.graph.host,
            .optimize = s.optimize,
        }).path(
            "",
        )).path(
            s.b,
            "test/v2/source_oracle.mjs",
        ), .{ .make_absolute = true });
        workspace_semantics_run.addFileArg2(s.kosmos_source.path(
            s.b,
            "src/embedding/index.mjs",
        ), .{ .make_absolute = true });
        if (s.b.option(
            std.Build.LazyPath,
            "workspace-wasm",
            "Kosmos kernel for generated workspace native/WASM comparison",
        )) |wasm|
            workspace_semantics_run.addFileArg2(wasm, .{ .make_absolute = true });
        workspace_semantics_run.has_side_effects = true;
        const workspace_semantics = s.b.step(
            "check-workspace-semantics",
            "Compare newly generated workspace programs with the independent source oracle",
        );
        workspace_semantics.dependOn(&workspace_semantics_run.step);
        s.native_checks.dependOn(workspace_semantics);
    }

    fn publishNative(s: *BuildGraph) void {
        s.b.addNamedLazyPath("native-sqlite-source", s.sqlite_source);
        s.b.installArtifact(s.host_tool);
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_native"),
            s.public_environment,
        ) catch @panic("out of memory");
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_native_data"),
            s.native_data,
        ) catch @panic("out of memory");
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_native_contracts"),
            s.native_contracts,
        ) catch @panic("out of memory");
        s.b.modules.put(
            s.b.allocator,
            s.b.dupe("protean_native_types"),
            s.native_protean,
        ) catch @panic("out of memory");
    }

    fn productBuild(s: *BuildGraph) void {
        const native_modules: @import("build_native.zig").Modules = .{
            .root = s.b.path("."),
            .protean = s.protean,
            .horos = s.horos,
            .data = s.data,
            .contracts = s.contracts,
            .native = s.public_environment,
            .native_data = s.native_data,
            .native_contracts = s.native_contracts,
            .native_protean = s.native_protean,
            .sqlite_source = s.sqlite_source,
            .host_tool = s.host_tool,
        };
        s.adaptive_product = @import(
            "build_native.zig",
        ).addWithModules(s.b, native_modules, .{
            .name = "protean",
            .application = .{ .emitted = .{
                .image = s.adaptive_image,
                .application = s.adaptive_application,
                .types = s.b.path("examples/adaptive/types.zig"),
            } },
            .environment = s.b.path("examples/adaptive/environment.zig"),
        });
        const adaptive_reference = s.b.step(
            "protean",
            "Build the native Kosmos reference host for the adaptive program",
        );
        adaptive_reference.dependOn(&s.adaptive_product.install.step);
        adaptive_reference.dependOn(s.adaptive_image_step);
        s.native_executable.dependOn(adaptive_reference);
    }

    fn nativeSmoke(s: *BuildGraph) void {
        const adaptive_peer = nativeCheckCommand(s.b);
        adaptive_peer.addArgs(&.{ "node", "test/protean/native_adaptive.mjs" });
        adaptive_peer.addFileArg2(s.adaptive_product.executable.getEmittedBin(), .{
            .make_absolute = true,
        });
        adaptive_peer.addFileArg2(s.adaptive_application, .{ .make_absolute = true });
        adaptive_peer.addFileArg2(s.adaptive_image, .{ .make_absolute = true });
        adaptive_peer.addArg("smoke");
        s.native_executable.dependOn(&adaptive_peer.step);
        const placement_peer = nativeCheckCommand(s.b);
        placement_peer.addArgs(&.{ "node", "test/protean/native_placement.mjs" });
        placement_peer.addFileArg2(s.adaptive_product.executable.getEmittedBin(), .{
            .make_absolute = true,
        });
        placement_peer.step.dependOn(&adaptive_peer.step);
        s.b.step(
            "check-native-placement",
            "Qualify authenticated placement between native processes",
        ).dependOn(
            &placement_peer.step,
        );
        s.native_executable.dependOn(&placement_peer.step);
    }

    fn runtimeDiagnostics(s: *BuildGraph) void {
        const runtime_peer = nativeCheckCommand(s.b);
        runtime_peer.addArgs(&.{ "node", "test/protean/native_runtime.mjs" });
        runtime_peer.addFileArg2(s.adaptive_product.executable.getEmittedBin(), .{
            .make_absolute = true,
        });
        runtime_peer.addFileArg2(s.adaptive_application, .{ .make_absolute = true });
        runtime_peer.addArg("");
        runtime_peer.addArtifactArg(s.mobility_peer);
        s.b.step(
            "check-native-runtime",
            "Qualify scripted optional runtime choices through " ++
                "native inference and workspace boundaries",
        ).dependOn(
            &runtime_peer.step,
        );
        const retention_check = s.b.step(
            "check-workspace-runtime-retention",
            "Resume an old task with its retained original executable " ++
                "after installing the new product",
        );
        if (s.b.option(
            std.Build.LazyPath,
            "previous-runtime",
            "Retained previous Protean executable for namespace compatibility qualification",
        )) |previous| {
            const retention_run = s.b.addSystemCommand(&.{
                "node",
                "test/protean/workspace_runtime_retention.mjs",
            });
            retention_run.addFileArg2(previous, .{ .make_absolute = true });
            retention_run.addArtifactArg(s.adaptive_product.executable);
            retention_check.dependOn(&retention_run.step);
        } else retention_check.dependOn(
            &s.b.addFail(
                "select -Dprevious-runtime=<retained executable> for the old-task witness",
            ).step,
        );
    }

    fn httpsConsumer(s: *BuildGraph) void {
        const consumer_module = s.b.createModule(.{
            .root_source_file = s.b.path("test/protean/https_probe.zig"),
            .target = s.native_graph.target orelse s.b.graph.host,
            .optimize = s.optimize,
            .strip = s.optimize != .debug,
            .imports = &.{
                .{ .name = "kosmos", .module = s.checked_kosmos },
                .{ .name = "horos_data", .module = s.native_graph.data },
                .{ .name = "protean_native", .module = s.checked_environment },
                .{ .name = "protean_contracts", .module = s.native_graph.contracts },
            },
        });
        const consumer = s.b.addExecutable(.{
            .name = "protean-https-probe",
            .root_module = consumer_module,
            .use_llvm = if (linuxX86(s.native_target)) false else null,
        });
        consumer.step.dependOn(&s.native_guard.step);
        const https_peer = nodeCommand(s.b);
        https_peer.addArgs(&.{ "node", "test/protean/native_https.mjs" });
        https_peer.addFileArg2(consumer.getEmittedBin(), .{ .make_absolute = true });
        s.native_consumer.dependOn(&https_peer.step);
    }

    fn unsupportedProduct(s: *BuildGraph) void {
        const unsupported = s.b.addFail(
            "native product supports aarch64-macos and x86_64-linux-musl",
        );

        s.native_consumer.dependOn(&unsupported.step);
        s.native_packaged.dependOn(&unsupported.step);
        s.native_executable.dependOn(&unsupported.step);
    }

    fn nativeSuite(s: *BuildGraph) void {
        // These roots share exact module identities; compile their retained
        // tests together instead of rebuilding the same compiler eleven times.
        s.native_suite = s.native_graph.module("test/protean/native_tests.zig");
        // Generic owner/evaluator instantiations inherit the root's mode.
        // Keep execution representative of the requested product build.
        s.native_suite.strip = s.optimize != .debug;
        s.native_suite.addImport("kosmos", s.checked_kosmos);
        s.native_suite.addImport("protean_native", s.checked_environment);
        const adaptive_test_types = s.native_graph.module("examples/adaptive/types.zig");
        const adaptive_report = s.native_graph.module("examples/adaptive/report.zig");
        adaptive_report.addImport("application_types", adaptive_test_types);
        s.native_suite.addImport("adaptive_report", adaptive_report);
        const adaptive_test_environment = s.native_graph.module(
            "examples/adaptive/environment.zig",
        );
        adaptive_test_environment.addImport("application_types", adaptive_test_types);
        adaptive_test_environment.addImport("protean_native", s.checked_environment);
        s.native_suite.addImport("adaptive_types", adaptive_test_types);
        s.native_suite.addImport("adaptive_environment", adaptive_test_environment);
        s.native_suite.addAnonymousImport(
            "adaptive_image",
            .{ .root_source_file = s.adaptive_image },
        );
        s.native_suite.addAnonymousImport("adaptive_application", .{
            .root_source_file = s.adaptive_application,
        });
        const native_asset_writer = s.native_graph.module("tools/native/emit.zig");
        s.native_suite.addImport("native_asset_writer", native_asset_writer);
    }

    fn nativeOwner(s: *BuildGraph) void {
        inline for (.{
            .{ "adaptive", "test/protean/native_adaptive_tests.zig" },
            .{ "tasks", "test/protean/native_owner_tests.zig" },
        }) |group| {
            const suite = s.b.allocator.create(std.Build.Module) catch @panic("out of memory");
            suite.init(s.b, .{ .existing = s.native_suite });
            suite.root_source_file = s.b.path(group[1]);
            if (comptime std.mem.eql(u8, group[0], "tasks")) {
                suite.import_table = suite.import_table.clone(
                    s.b.allocator,
                ) catch @panic(
                    "out of memory",
                );
                _ = suite.import_table.swapRemove("adaptive_image");
                _ = suite.import_table.swapRemove("adaptive_application");
            }
            const checks = s.b.step(
                "check-native-owner-" ++ group[0],
                "Qualify native " ++ group[0] ++ " contracts",
            );
            const tests = s.native_graph.testModule(checks, suite);
            if (comptime std.mem.eql(u8, group[0], "tasks")) {
                if (linuxX86(s.b.graph.host))
                    tests.use_llvm = false;
            }
            s.b.step(
                "build-native-owner-" ++ group[0] ++ "-check",
                "Build the retained native " ++ group[0] ++ " test executable",
            )
                .dependOn(&s.b.addInstallArtifact(tests, .{
                .dest_dir = .{ .override = .{ .custom = "verification" } },
                .dest_sub_path = "native-owner-" ++ group[0],
            }).step);
            s.native_owner_integration.dependOn(checks);
        }
    }

    fn workspaceRecovery(s: *BuildGraph) void {
        const workspace_recovery_tests = s.b.addTest(.{
            .root_module = s.native_suite,
            .filters = &.{"adaptive workspace"},
            .use_llvm = if (linuxX86(s.b.graph.host)) s.optimize != .debug else null,
        });
        workspace_recovery_tests.step.dependOn(s.native_graph.gate);
        const workspace_recovery_run = s.b.addRunArtifact(workspace_recovery_tests);
        workspace_recovery_run.has_side_effects = true;
        s.b.step(
            "check-workspace-recovery",
            "Qualify workspace construction recovery through the adaptive controller",
        ).dependOn(
            &workspace_recovery_run.step,
        );
    }

    fn scheduler(s: *BuildGraph) void {
        // Reuse the fixture's complete import graph; keep the measured root in
        // the requested optimization mode.
        const scheduler_module = s.b.allocator.create(
            std.Build.Module,
        ) catch @panic(
            "out of memory",
        );
        scheduler_module.init(s.b, .{ .existing = s.native_suite });
        scheduler_module.root_source_file = s.b.path("test/protean/native_scheduler_benchmark.zig");
        scheduler_module.optimize = s.optimize;
        const scheduler_tests = s.b.addTest(.{
            .root_module = scheduler_module,
            .filters = &.{"native scheduler backlog benchmark"},
        });
        scheduler_tests.step.dependOn(&s.native_guard.step);
        const scheduler_run = s.b.addRunArtifact(scheduler_tests);
        scheduler_run.has_side_effects = true;
        s.scheduler_benchmark.dependOn(&scheduler_run.step);
    }

    fn adaptiveResponse(s: *BuildGraph) void {
        // History validation dominates test execution. Optimize its existing
        // cases with LLVM while preserving the requested mode, including Debug.
        const adaptive_response_suite = s.native_graph.module(
            "test/protean/adaptive_responses.zig",
        );
        adaptive_response_suite.strip = s.optimize != .debug;
        adaptive_response_suite.addImport("protean_native", s.checked_environment);
        const adaptive_response_tests = s.b.addTest(.{
            .root_module = adaptive_response_suite,
            .use_llvm = if (linuxX86(s.b.graph.host)) s.optimize != .debug else null,
        });
        adaptive_response_tests.step.dependOn(s.native_graph.gate);
        const adaptive_response_run = s.b.addRunArtifact(adaptive_response_tests);
        adaptive_response_run.has_side_effects = true;
        s.native_owner_support.dependOn(&adaptive_response_run.step);
        s.b.step(
            "check-adaptive-context",
            "Qualify retained adaptive context projection and explicit view selection",
        ).dependOn(
            &adaptive_response_run.step,
        );
    }

    fn nativeCrash(s: *BuildGraph) void {
        // Zig does not collect test declarations from named dependency modules.
        // Run the runtime's own root explicitly; the integration root above
        // independently exercises its public task owner with authored programs.
        const native_unit_tests = s.b.allocator.create(
            std.Build.Module,
        ) catch @panic(
            "out of memory",
        );
        native_unit_tests.init(s.b, .{ .existing = s.checked_environment });
        native_unit_tests.optimize = s.optimize;
        _ = s.native_graph.testModule(s.native_owner_support, native_unit_tests);
        const crash_module = s.native_graph.module("test/protean/native_recovery_crash.zig");
        crash_module.strip = s.optimize != .debug;
        crash_module.addImport("kosmos", s.checked_kosmos);
        crash_module.addImport("protean_native", s.checked_environment);
        // Private history/Worker access stays in the test graph. The Node
        // controller owns process death and independent reopen.
        const crash_probe = s.b.addTest(.{
            .name = "protean-recovery-crash",
            .root_module = crash_module,
            .filters = &.{"process-crash-controller-only"},
            .use_llvm = if (linuxX86(s.b.graph.host)) s.optimize != .debug else null,
        });
        crash_probe.step.dependOn(&s.native_guard.step);
        const crash_check = nodeCommand(s.b);
        crash_check.addArgs(&.{ "node", "test/protean/native_recovery_crash.mjs" });
        crash_check.addFileArg2(crash_probe.getEmittedBin(), .{ .make_absolute = true });
        crash_check.has_side_effects = true;
        s.b.step(
            "check-native-recovery-crash",
            "Kill and reopen native occurrence/recovery owners at durable boundaries",
        ).dependOn(
            &crash_check.step,
        );
        s.native_owner_support.dependOn(&crash_check.step);
    }

    fn missingNative(s: *BuildGraph) void {
        const missing = s.b.addFail(
            "enable -Dnative=true with authenticated Kosmos and SQLite sources",
        );
        s.native_checks.dependOn(&missing.step);
        s.native_owner_integration.dependOn(&missing.step);
        s.native_owner_support.dependOn(&missing.step);
        s.native_packaged.dependOn(&missing.step);
        s.native_executable.dependOn(&missing.step);
        s.native_consumer.dependOn(&missing.step);
        s.scheduler_benchmark.dependOn(&missing.step);
    }

    fn pureChecks(s: *BuildGraph) void {
        const pure = nodeCommand(s.b);
        pure.addArgs(&.{
            "node",
            "--test",
            "test/protean/values.test.mjs",
            "test/protean/qualification_tests.test.mjs",
        });
        pure.has_side_effects = true;
        s.check.dependOn(&pure.step);
        s.aggregate.dependOn(s.check);
        s.b.step("check-authoring-core", "Check retained authoring contracts").dependOn(s.check);
        s.b.step("check", "Check Protean authoring").dependOn(s.aggregate);
        s.b.default_step = s.aggregate;
    }
};

fn nativeEnvironment(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    kosmos: *std.Build.Module,
    data: *std.Build.Module,
    contracts: *std.Build.Module,
    horos: *std.Build.Module,
    protean: *std.Build.Module,
    admission: *std.Build.Module,
    sqlite_source: std.Build.LazyPath,
    gate: *std.Build.Step,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(
        []const u8,
        "horos_identity",
        @import("build.zig.zon").dependencies.horos.hash,
    );
    options.addOption(u32, "state_format", @import("build_native.zig").state_format);
    options.addOption([]const u8, "host_version", @import("build.zig.zon").version);
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
    const c_library = nativeLibrary(b, target, optimize, sqlite_source, gate);
    const module = b.createModule(.{
        .root_source_file = b.path("runtime/native/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "kosmos", .module = kosmos },
            .{ .name = "horos_data", .module = data },
            .{ .name = "protean_contracts", .module = contracts },
            .{ .name = "horos", .module = horos },
            .{ .name = "protean", .module = protean },
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
    run.addDirectoryArg2(
        b.graph.path(.install_prefix, ""),
        .{ .prefix = "PROTEAN_BUILD_PREFIX=", .make_absolute = true },
    );
    return run;
}

fn linuxX86(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .linux and target.result.cpu.arch == .x86_64;
}

fn nativeLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    sqlite_source: std.Build.LazyPath,
    gate: *std.Build.Step,
) *std.Build.Step.Compile {
    const c_module = b.createModule(.{
        .root_source_file = b.path("runtime/native/hash.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = true,
    });
    c_module.addIncludePath(sqlite_source);
    c_module.addCSourceFile(.{
        .file = sqlite_source.path(b, "sqlite3.c"),
        .flags = @import("build_native.zig").sqliteFlags(optimize),
    });
    c_module.addCSourceFile(
        .{
            .file = b.path("runtime/native/native_c.c"),
            .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" },
        },
    );
    const c_library = b.addLibrary(.{
        .name = "protean-native-c",
        .linkage = .static,
        .root_module = c_module,
        .use_llvm = true,
    });
    c_library.step.dependOn(gate);
    return c_library;
}
