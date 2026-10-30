const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const build_job = @import("../workspace_build.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const construction = @import("../program_construction.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const CompilerFact = task_types.CompilerFact;
const SelectedRuntime = task_types.SelectedRuntime;
const Work = task_types.Work;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const compatible = Controller.compatible;
        const compilerFact = compiler_ops.compilerFact;
        const compilerReference = compiler_ops.compilerReference;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const retainCompilerFact = compiler_ops.retainCompilerFact;
        const store = Lifecycle.store;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspaceSnapshotAccess = Inspection.workspaceSnapshotAccess;
        const compiler_ops = @import("compiler_preparation.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        fn retainValidatedRuntime(
            self: *Self,
            admitted: *const kosmos.RuntimeArtifact,
            fact: CompilerFact,
        ) !void {
            var retained = try admitted.clone();
            errdefer retained.deinit();
            try self.checked_workspace_runtimes.put(
                self.allocator,
                fact,
                store(self).integrity_epoch,
            );
            const compiled = if (self.runtime_cache) |cached|
                cached.compiled and cached.epoch == store(self).integrity_epoch and
                    std.meta.eql(cached.artifact.identity, admitted.identity)
            else
                false;
            if (self.runtime_cache) |*cached| cached.artifact.deinit();
            self.runtime_cache = .{
                .epoch = store(self).integrity_epoch,
                .artifact = retained,
                .compiled = compiled,
            };
        }
        fn compileWorkspaceRuntime(
            self: *Self,
            guest: *const data.program_image.Admitted,
            hooks: wc.RuntimeHooks,
        ) ![]u8 {
            const instrumentation: kosmos.RuntimeInstrumentation.Hooks = .{
                .control = hooks.control,
                .storage = hooks.storage,
            };
            if (self.runtime_cache) |*cached| {
                const bundle = cached.artifact.content.value;
                if (cached.compiled and cached.epoch == store(self).integrity_epoch and
                    bundle.guest != null and std.meta.eql(bundle.guest.?, guest.identity()) and
                    std.meta.eql(bundle.hooks, instrumentation))
                    return cached.artifact.encode(self.allocator);
            }
            return kosmos.RuntimeCompiler.compile(self.allocator, .{
                .guest = guest,
                .horos_package = @import("native_options").horos_identity,
                .hooks = instrumentation,
            });
        }
        pub fn runtimeCompilerFact(
            a: std.mem.Allocator,
            reference: state.Reference,
            validation: ?workspace.ValidationFact,
        ) !CompilerFact {
            const bytes = try contracts.encodeOwned(?workspace.ValidationFact, a, validation);
            defer a.free(bytes);
            return .{
                .kind = .runtime,
                .input = reference,
                .output = if (validation) |fact| fact.ancestor else .{
                    .digest = @splat(0),
                    .bytes = 0,
                },
                .context = storage.digest(bytes),
            };
        }
        pub fn validateRuntimeCompiler(
            self: *Self,
            a: std.mem.Allocator,
            reference: state.Reference,
            validation: ?workspace.ValidationFact,
            admitted: *const kosmos.RuntimeArtifact,
            source: anytype,
        ) !void {
            const fact = try runtimeCompilerFact(a, reference, validation);
            if (try compilerFact(self, fact)) return;
            if (admitted.content.value.lineage != null) {
                const declared = validation orelse return error.InvalidRuntime;
                const bytes = try source.object(a, declared.ancestor, null);
                defer a.free(bytes);
                var ancestor = try kosmos.RuntimeArtifact.init(a, bytes, declared.ancestor.digest);
                defer ancestor.deinit();
                try kosmos.RuntimeCompiler.validateAgainst(a, admitted, &ancestor);
            } else {
                if (validation != null) return error.InvalidRuntime;
                try kosmos.RuntimeCompiler.validate(a, admitted);
            }
            try retainCompilerFact(self, fact);
        }
        pub fn workspaceRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            digest: state.Digest,
            program_id: ?state.Digest,
        ) !SelectedRuntime {
            const id = try workspaceContentCustody(a, task_id, digest);
            var saved =
                try record(self, workspace.Runtime, a, "workspace_runtime", id, task_id);
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.id, id) or !std.meta.eql(saved.value.task, task_id) or
                !std.meta.eql(saved.value.artifact.digest, digest)) return error.InvalidRuntime;
            var program = try workspaceProgram(self, a, task_id, saved.value.program);
            defer program.deinit();
            if (program_id) |required| if (!std.meta.eql(required, saved.value.program)) {
                var requested = try workspaceProgram(self, a, task_id, required);
                defer requested.deinit();
                if (!std.meta.eql(
                    requested.value.description.image,
                    program.value.description.image,
                )) return error.InvalidRuntime;
            };
            const image =
                try store(self).object(a, program.value.description.image, null);
            defer a.free(image);
            const guest = try data.program_image.Admitted.decode(a, image);
            defer guest.deinit();
            var admitted = cached: {
                if (self.runtime_cache) |*cached| {
                    if (cached.epoch == store(self).integrity_epoch and std.meta.eql(
                        cached.artifact.identity,
                        digest,
                    )) break :cached try cached.artifact.clone();
                }
                const bytes = try store(self).object(a, saved.value.artifact, null);
                defer a.free(bytes);
                break :cached try kosmos.RuntimeArtifact.init(self.allocator, bytes, digest);
            };
            errdefer admitted.deinit();
            const bound = admitted.content.value.guest orelse return error.InvalidRuntime;
            if (!std.mem.eql(u8, &bound, &guest.identity()) or !same(
                admitted.content.value.manifest.compiler.horos_package,
                @import("native_options").horos_identity,
            )) return error.InvalidRuntime;
            const fact = try runtimeCompilerFact(a, saved.value.artifact, saved.value.validation);
            if (admitted.content.value.lineage != null) {
                try validateDerivedRuntime(self, a, saved.value, &admitted);
            } else if (saved.value.validation != null) return error.InvalidRuntime;
            if (self.checked_workspace_runtimes.get(fact) != store(self).integrity_epoch) {
                try validateRuntimeCompiler(
                    self,
                    self.allocator,
                    saved.value.artifact,
                    saved.value.validation,
                    &admitted,
                    store(self),
                );
            }
            try retainValidatedRuntime(self, &admitted, fact);
            return .{ .record = saved, .admitted = admitted };
        }
        fn validateDerivedRuntime(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Runtime,
            admitted: *const kosmos.RuntimeArtifact,
        ) !void {
            const fact = value.validation orelse return error.InvalidRuntime;
            if (fact.version != 1) return error.InvalidRuntime;
            var candidate =
                try self.workspaceCandidate(a, value.task, fact.candidate.digest);
            defer candidate.deinit();
            const d = candidate.value.description;
            if (!std.meta.eql(candidate.value.artifact, fact.candidate) or
                !std.meta.eql(d.code, value.artifact) or
                !std.meta.eql(d.ancestor, fact.ancestor) or !std.meta.eql(d.root, fact.root) or
                !std.meta.eql(d.guest, fact.guest) or !same(d.checker.bytes, fact.checker.bytes))
                return error.InvalidRuntime;
            if (!std.meta.eql(admitted.identity, value.artifact.digest))
                return error.InvalidRuntime;
        }
        pub fn workspaceRuntimeObservation(
            self: *Self,
            a: std.mem.Allocator,
            saved: workspace.Runtime,
        ) !json.Value {
            var selected =
                try workspaceRuntime(self, a, saved.task, saved.artifact.digest, saved.program);
            defer selected.deinit();
            if (!data.record.equal(workspace.Runtime, saved, selected.record.value))
                return error.InvalidRuntime;
            const bundle = selected.admitted.content.value;
            var result = json.object();
            try json.put(
                a,
                &result,
                "runtime",
                try values.toJson(wc.Ref, a, try wp.reference(a, .runtime, saved.artifact.digest)),
            );
            try json.put(
                a,
                &result,
                "origin_program",
                try values.toJson(wc.Ref, a, try wp.reference(a, .program, saved.program)),
            );
            try workspaceRuntimeDetails(a, &result, saved, bundle);
            return result;
        }
        fn workspaceRuntimeDetails(
            a: std.mem.Allocator,
            result: *json.Value,
            saved: workspace.Runtime,
            bundle: @FieldType(@FieldType(kosmos.RuntimeArtifact, "content"), "value"),
        ) !void {
            try json.put(
                a,
                result,
                "guest",
                json.string(try a.dupe(u8, &std.fmt.bytesToHex(bundle.guest.?, .lower))),
            );
            try json.put(
                a,
                result,
                "source",
                json.string(try a.dupe(u8, &std.fmt.bytesToHex(bundle.manifest.source, .lower))),
            );
            try json.put(
                a,
                result,
                "base",
                json.string(try a.dupe(u8, bundle.manifest.requirements.base)),
            );
            try json.put(
                a,
                result,
                "admission",
                json.string(try a.dupe(u8, bundle.manifest.requirements.admission)),
            );
            try json.put(
                a,
                result,
                "bridge",
                json.string(try a.dupe(u8, bundle.manifest.requirements.bridge)),
            );
            try json.put(a, result, "artifact_bytes", try json.number(a, saved.artifact.bytes));
            try json.put(a, result, "code_bytes", try json.number(a, bundle.image.len));
            try json.put(
                a,
                result,
                "approval",
                json.string("exact-source-and-independent-derivation"),
            );
            try json.put(a, result, "hydration", json.string("canonical-guest-cut"));
            try json.put(
                a,
                result,
                "hooks",
                try values.toJson(kosmos.RuntimeInstrumentation.Hooks, a, bundle.hooks),
            );
            try json.put(
                a,
                result,
                "trace_failure_policy",
                json.string("publication-fences-owner-and-retains-prior-durable-cut"),
            );
        }
        pub fn workspaceSpecialize(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
        ) !Admission {
            return workspaceSpecializeWithHooks(self, a, operation_id, task_id, program_id, .{});
        }
        pub fn workspaceSpecializeWithHooks(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
            hooks: wc.RuntimeHooks,
        ) !Admission {
            const request = try operation(workspace.SpecializeRequest, a, .{
                .task = task_id,
                .program = program_id,
                .hooks = hooks,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            var program = try workspaceProgram(self, a, task_id, program_id);
            defer program.deinit();
            const image =
                try store(self).object(a, program.value.description.image, null);
            defer a.free(image);
            const guest = try data.program_image.Admitted.decode(a, image);
            defer guest.deinit();
            // Compiler and proof scratch ends before the next phase. Keeping it
            // in the caller's response arena retains completed work, including
            // independently decoded proofs, until that entire request ends.
            if (store(self).transaction) return error.CompilerPreparationRequired;
            const bytes = try compileWorkspaceRuntime(self, guest, hooks);
            defer self.allocator.free(bytes);
            var admitted =
                try kosmos.RuntimeArtifact.init(self.allocator, bytes, storage.digest(bytes));
            defer admitted.deinit();
            try validateRuntimeCompiler(
                self,
                self.allocator,
                compilerReference(bytes),
                null,
                &admitted,
                store(self),
            );
            try retainValidatedRuntime(
                self,
                &admitted,
                try runtimeCompilerFact(a, compilerReference(bytes), null),
            );
            self.runtime_cache.?.compiled = true;
            try store(self).begin();
            defer store(self).rollback();
            const artifact = try store(self).putObject(bytes);
            const saved = try storeSpecializedRuntime(self, a, task_id, program_id, artifact);
            const record_bytes = try contracts.encodeOwned(workspace.Runtime, a, saved);
            defer a.free(record_bytes);
            const observation = try store(self).putObject(record_bytes);
            return workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                request,
                artifact.digest,
                .runtime,
                observation,
                .{ .specialize = .{ .program = program_id, .hooks = hooks } },
            );
        }
        fn storeSpecializedRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            program_id: state.Digest,
            artifact: state.Reference,
        ) !workspace.Runtime {
            const id = try workspaceContentCustody(a, task_id, artifact.digest);
            var saved: workspace.Runtime = .{
                .id = id,
                .task = task_id,
                .program = program_id,
                .artifact = artifact,
            };
            if (try store(self).recordBytes(a, "workspace_runtime", id, task_id)) |prior| {
                defer a.free(prior);
                var existing = try workspaceRuntime(self, a, task_id, artifact.digest, program_id);
                defer existing.deinit();
                saved = existing.record.value;
            } else try store(self).createRecord(
                workspace.Runtime,
                "workspace_runtime",
                id,
                task_id,
                saved,
            );
            return saved;
        }
        pub fn runtimeWork(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            expected: wc.Expected,
        ) !contracts.Decoded(workspace.Work) {
            try requireCustody(self, a, task_id, try wp.identity(expected.work, .work));
            var work = try workspaceWork(self, a, task_id, try wp.identity(expected.work, .work));
            errdefer work.deinit();
            if (work.value.execution_revision != expected.execution_revision or
                work.value.control_revision != expected.control_revision)
                return error.StaleRevision;
            if (work.value.current_occurrence) |id| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, task_id);
                defer pending.deinit();
                if (pending.value.state == .dispatching or pending.value.state == .unknown)
                    return error.UnresolvedDelivery;
            }
            return work;
        }
        pub fn workspaceProgram(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            program_id: state.Digest,
        ) !contracts.Decoded(workspace.Program) {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            const custody_id = try workspaceContentCustody(a, task_id, program_id);
            const bytes = (try store(self).recordBytes(
                a,
                "workspace_program",
                custody_id,
                task_id,
            )) orelse return error.ArtifactUnavailable;
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(workspace.Program, a, bytes);
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.id, custody_id) or
                !std.meta.eql(saved.value.artifact.digest, program_id) or
                !std.meta.eql(saved.value.task, task_id))
                return error.CorruptState;
            const encoded =
                try contracts.encodeOwned(workspace.ProgramArtifact, a, saved.value.description);
            defer a.free(encoded);
            if (!std.meta.eql(storage.digest(encoded), saved.value.artifact.digest) or
                encoded.len != saved.value.artifact.bytes) return error.CorruptState;
            if (saved.value.description.catalog) |catalog| try workspaceSnapshotAccess(
                parent.value,
                catalog,
            );
            try validateWorkspaceProgram(self, a, saved.value);
            return saved;
        }
        pub fn workspaceContentCustody(
            a: std.mem.Allocator,
            task_id: state.TaskId,
            program_id: state.Digest,
        ) !state.Digest {
            return workspace.custodyId(a, task_id, program_id);
        }
        fn validateWorkspaceProgram(
            self: *Self,
            a: std.mem.Allocator,
            saved: workspace.Program,
        ) !void {
            if (self.checked_workspace_programs.get(
                saved.artifact.digest,
            )) |epoch| if (epoch == store(self).integrity_epoch) return;
            try validateProgramCompiler(self, a, saved, store(self));
            try self.checked_workspace_programs.put(
                self.allocator,
                saved.artifact.digest,
                store(self).integrity_epoch,
            );
        }
        pub fn validateProgramCompiler(
            self: *Self,
            a: std.mem.Allocator,
            saved: workspace.Program,
            objects: anytype,
        ) !void {
            const artifact = saved.description;
            try validateCompilerArtifact(a, saved, artifact);
            if (try validateSeedProgram(self, a, artifact)) return;
            const context: state.Digest = if (artifact.controller != null) blk: {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const scratch = arena.allocator();
                const frozen_contract = try controllerContract(self, scratch);
                break :blk storage.digest(
                    try contracts.encodeOwned(
                        contracts.controller.Contract,
                        scratch,
                        frozen_contract,
                    ),
                );
            } else @splat(0);
            const fact: CompilerFact = .{
                .kind = .program,
                .input = saved.artifact,
                .output = artifact.image,
                .context = context,
            };
            if (try compilerFact(self, fact)) return;
            const source = try objects.object(a, artifact.source, null);
            defer a.free(source);
            var diagnostic: construction.Diagnostic = .{};
            var built = try workspaceCompileFrom(
                self,
                self.allocator,
                source,
                artifact.source_kind,
                artifact.catalog,
                artifact.exposures.items,
                if (artifact.controller != null) .controller else .computation,
                &diagnostic,
                objects,
            );
            defer built.deinit();
            try validateCompiledArtifact(a, artifact, built);
            try retainCompilerFact(self, fact);
        }
        pub fn workspaceWork(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !contracts.Decoded(workspace.Work) {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            return retainedWorkspaceWork(self, a, task_id, work_id);
        }
        pub fn retainedWorkspaceWork(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !contracts.Decoded(workspace.Work) {
            const bytes = (try store(self).recordBytes(
                a,
                "workspace_work",
                work_id,
                task_id,
            )) orelse return error.ArtifactUnavailable;
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(workspace.Work, a, bytes);
            errdefer saved.deinit();
            if (saved.value.version != 3 or !std.meta.eql(saved.value.id, work_id) or
                !std.meta.eql(saved.value.task, task_id)) return error.CorruptState;
            return saved;
        }
        pub fn workspaceBuild(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            source: []const u8,
            diagnostic: *construction.Diagnostic,
        ) !Admission {
            // The compilation result stays local until the same transaction admits
            // its complete dependency closure, custody and acknowledgment.
            return workspaceBuildKind(
                self,
                a,
                operation_id,
                task_id,
                source,
                .source_records,
                null,
                &.{},
                .computation,
                diagnostic,
            );
        }
        pub fn controllerContract(
            self: *Self,
            a: std.mem.Allocator,
        ) !contracts.controller.Contract {
            var imports: std.ArrayList(contracts.controller.Signature) = .empty;
            defer imports.deinit(a);
            errdefer for (imports.items) |item| if (item.native_result != null) a.free(
                item.result.bytes,
            );
            for (self.handlers.entries) |entry|
                if (entry.declaration.controller_import) |imported| {
                    try imports.ensureUnusedCapacity(a, 1);
                    imports.appendAssumeCapacity(.{
                        .import = imported,
                        .payload = .{ .bytes = entry.payload_schema },
                        .result = .{
                            .bytes = if (imported ==
                                .deliberate) try construction.controller.replySchema(
                                a,
                                entry.resume_schema,
                            ) else entry.resume_schema,
                        },
                        .native_result = if (imported == .deliberate) .{
                            .bytes = entry.resume_schema,
                        } else null,
                    });
                };
            const result = try values.schemaBytes(Types.Output, a);
            errdefer a.free(result);
            const failure = try values.schemaBytes(Types.Failure, a);
            errdefer a.free(failure);
            return .{
                .result = .{ .bytes = result },
                .failure = .{ .bytes = failure },
                .imports = .{ .items = try imports.toOwnedSlice(a) },
            };
        }
        fn workspaceCompile(
            self: *Self,
            a: std.mem.Allocator,
            source: []const u8,
            kind: @FieldType(workspace.ProgramArtifact, "source_kind"),
            catalog: ?state.Reference,
            exposures: []const wc.Exposure,
            role: wc.ProgramRole,
            diagnostic: *construction.Diagnostic,
        ) !construction.Built {
            if (store(self).transaction) return error.CompilerPreparationRequired;
            return workspaceCompileFrom(
                self,
                a,
                source,
                kind,
                catalog,
                exposures,
                role,
                diagnostic,
                store(self),
            );
        }
        fn workspaceCompileFrom(
            self: *Self,
            a: std.mem.Allocator,
            source: []const u8,
            kind: @FieldType(workspace.ProgramArtifact, "source_kind"),
            catalog: ?state.Reference,
            exposures: []const wc.Exposure,
            role: wc.ProgramRole,
            diagnostic: *construction.Diagnostic,
            objects: anytype,
        ) !construction.Built {
            if (store(self).transaction) return error.CompilerPreparationRequired;
            if (role == .controller) {
                if (kind != .source_records or catalog != null or exposures.len != 0)
                    return error.InvalidConstruction;
                const contract = try controllerContract(self, a);
                defer {
                    a.free(contract.result.bytes);
                    a.free(contract.failure.bytes);
                    for (contract.imports.items) |item| if (item.native_result != null) a.free(
                        item.result.bytes,
                    );
                    a.free(contract.imports.items);
                }
                return construction.buildController(a, source, contract, null, diagnostic);
            }
            if (kind == .instrument_model or kind == .instrument_snapshot) {
                if (!same(source, instrument.identity) or catalog != null or exposures.len != 0)
                    return error.InvalidConstruction;
                return instrument.build(a, if (kind == .instrument_model) .model else .snapshot);
            }
            if (kind == .source_records) {
                if (catalog != null) return error.InvalidConstruction;
                return construction.buildExposed(a, source, exposures, null, diagnostic);
            }
            if (kind == .source_derivation) {
                if (catalog != null) return error.InvalidConstruction;
                return construction.buildDerived(a, source, exposures, null, diagnostic);
            }
            if (exposures.len != 0) return error.InvalidExposure;
            diagnostic.phase = .authority;
            const ref = catalog orelse return error.UnavailableCatalog;
            const bytes = try objects.object(a, ref, null);
            defer a.free(bytes);
            diagnostic.phase = .compilation;
            const built = try construction.buildComponent(a, bytes, source);
            diagnostic.phase = .complete;
            return built;
        }
        pub fn workspaceBuildKind(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            source: []const u8,
            source_kind: wc.SourceKind,
            catalog: ?state.Reference,
            exposures: []const wc.Exposure,
            role: wc.ProgramRole,
            diagnostic: *construction.Diagnostic,
        ) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            const Request = workspace.BuildRequest;
            const request = try operation(Request, a, .{
                .task = task_id,
                .source = .{ .bytes = source },
                .source_kind = source_kind,
                .catalog = catalog,
                .exposures = .{ .items = exposures },
                .role = role,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            if (catalog) |ref| try workspaceSnapshotAccess(parent.value, ref);
            var built = try workspaceCompile(
                self,
                a,
                source,
                @fromBackingInt(@intCast(@backingInt(source_kind))),
                catalog,
                exposures,
                role,
                diagnostic,
            );
            defer built.deinit();
            try store(self).begin();
            defer store(self).rollback();
            const saved = try workspaceStoreProgram(self, a, task_id, source, @fromBackingInt(
                @intCast(@backingInt(source_kind)),
            ), catalog, exposures, .{
                .image = .{ .bytes = built.image },
                .interface = built.interface,
                .ports = .{ .items = built.ports },
                .controller = built.controller,
            });
            const admitted = try workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                request,
                saved.digest,
                .program,
                saved,
                .build,
            );
            try self.checked_workspace_programs.put(
                self.allocator,
                saved.digest,
                store(self).integrity_epoch,
            );
            return admitted;
        }
        pub fn workspaceStoreProgram(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            source: []const u8,
            source_kind: @FieldType(workspace.ProgramArtifact, "source_kind"),
            catalog: ?state.Reference,
            exposures: []const wc.Exposure,
            built: build_job.Compiled,
        ) !state.Reference {
            const ports = try a.alloc(workspace.PortInterface, built.ports.items.len);
            defer a.free(ports);
            var controller_schemas: std.ArrayList(state.Reference) = .empty;
            defer controller_schemas.deinit(a);
            if (built.controller) |descriptor| {
                const schemas =
                    try @import("../controller_construction.zig").schemas(a, descriptor);
                defer a.free(schemas);
                for (schemas) |schema| try controller_schemas.append(
                    a,
                    try store(self).putObject(schema),
                );
            }
            for (built.ports.items, ports) |port, *out| out.* = .{
                .identity = port.identity,
                .class = port.class,
                .argument = try store(self).putObject(port.argument.bytes),
                .observation = try store(self).putObject(port.observation.bytes),
                .payload = try store(self).putObject(port.payload.bytes),
                .command = try store(self).putObject(port.command.bytes),
            };
            const artifact: workspace.ProgramArtifact = .{
                .source = try store(self).putObject(source),
                .source_kind = source_kind,
                .construction_contract = try name(
                    if (built.controller !=
                        null) contracts.controller.identity else switch (source_kind) {
                        .source_records => @import("../source_records.zig").identity,
                        .source_derivation => @import("../source_records.zig").derivation_identity,
                        .component_recipe => construction.component_identity,
                        .instrument_model, .instrument_snapshot => instrument.identity,
                    },
                ),
                .authoring_identity = storage.digest(@import("native_options").horos_identity),
                .image = try store(self).putObject(built.image.bytes),
                .input_schema = try store(self).putObject(built.interface.input.bytes),
                .result_schema = try store(self).putObject(built.interface.output.bytes),
                .failure_schema = try store(self).putObject(built.interface.failure.bytes),
                .catalog = catalog,
                .exposures = .{ .items = exposures },
                .ports = .{ .items = ports },
                .controller = built.controller,
                .controller_schemas = .{ .items = controller_schemas.items },
            };
            return storeProgramCustody(self, a, task_id, artifact);
        }
        fn validateCompilerArtifact(
            a: std.mem.Allocator,
            saved: workspace.Program,
            artifact: workspace.ProgramArtifact,
        ) !void {
            const artifact_bytes =
                try contracts.encodeOwned(workspace.ProgramArtifact, a, artifact);
            defer a.free(artifact_bytes);
            if (!std.meta.eql(saved.artifact, compilerReference(artifact_bytes)))
                return error.InvalidArchive;
            const contract =
                if (artifact.controller !=
                null) contracts.controller.identity else switch (artifact.source_kind) {
                    .source_records => @import("../source_records.zig").identity,
                    .source_derivation => @import("../source_records.zig").derivation_identity,
                    .component_recipe => construction.component_identity,
                    .instrument_model, .instrument_snapshot => instrument.identity,
                };
            if (artifact.version != 2 or !same(artifact.construction_contract.bytes, contract) or
                !std.meta.eql(
                    artifact.authoring_identity,
                    storage.digest(@import("native_options").horos_identity),
                )) return error.IncompatibleProfile;
            if (artifact.controller) |descriptor| {
                const schemas =
                    try @import("../controller_construction.zig").schemas(a, descriptor);
                defer a.free(schemas);
                if (schemas.len != artifact.controller_schemas.items.len) return error.CorruptState;
                for (schemas, artifact.controller_schemas.items) |schema, ref|
                    if (ref.bytes != schema.len or
                        !std.meta.eql(ref.digest, storage.digest(schema)))
                        return error.CorruptState;
            } else if (artifact.controller_schemas.items.len != 0) return error.CorruptState;
        }
        fn validateSeedProgram(
            self: *Self,
            a: std.mem.Allocator,
            artifact: workspace.ProgramArtifact,
        ) !bool {
            if (self.application.controller) |seed| {
                if (std.meta.eql(artifact.source.digest, storage.digest(seed.source)) and
                    artifact.source.bytes == seed.source.len and std.meta.eql(
                    artifact.image.digest,
                    storage.digest(self.assets.image),
                ) and artifact.image.bytes == self.assets.image.len) {
                    if (artifact.source_kind != .source_records or
                        artifact.catalog != null or
                        artifact.exposures.items.len != 0 or
                        artifact.ports.items.len != 0 or
                        artifact.controller == null)
                        return error.CorruptState;
                    const descriptor = try contracts.encodeOwned(
                        contracts.controller.Descriptor,
                        a,
                        artifact.controller.?,
                    );
                    defer a.free(descriptor);
                    if (!same(descriptor, seed.descriptor)) return error.CorruptState;
                    if (comptime @hasDecl(Types, "ControllerInput")) {
                        inline for (.{
                            .{ artifact.input_schema, Types.ControllerInput },
                            .{ artifact.result_schema, Types.Output },
                            .{ artifact.failure_schema, Types.Failure },
                        }) |pair| {
                            const schema = try values.schemaBytes(pair[1], a);
                            defer a.free(schema);
                            if (pair[0].bytes != schema.len or !std.meta.eql(
                                pair[0].digest,
                                storage.digest(schema),
                            )) return error.CorruptState;
                        }
                    } else return error.CorruptState;
                    return true;
                }
            }

            return false;
        }
        fn validateCompiledArtifact(
            a: std.mem.Allocator,
            artifact: workspace.ProgramArtifact,
            built: anytype,
        ) !void {
            inline for (.{
                .{ artifact.image, built.image },
                .{ artifact.input_schema, built.interface.input.bytes },
                .{ artifact.result_schema, built.interface.output.bytes },
                .{ artifact.failure_schema, built.interface.failure.bytes },
            }) |pair| {
                if (pair[0].bytes != pair[1].len or !std.meta.eql(
                    pair[0].digest,
                    storage.digest(pair[1]),
                )) return error.CorruptState;
            }
            if (built.ports.len != artifact.ports.items.len) return error.CorruptState;
            for (built.ports, artifact.ports.items) |actual, declared| {
                if (!same(actual.identity.bytes, declared.identity.bytes) or
                    actual.class != declared.class) return error.CorruptState;
                inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                    const bytes = @field(actual, field).bytes;
                    const ref = @field(declared, field);
                    if (ref.bytes != bytes.len or !std.meta.eql(ref.digest, storage.digest(bytes)))
                        return error.CorruptState;
                }
            }
            const actual_controller =
                try contracts.encodeOwned(?contracts.controller.Descriptor, a, built.controller);
            defer a.free(actual_controller);
            const declared_controller =
                try contracts.encodeOwned(?contracts.controller.Descriptor, a, artifact.controller);
            defer a.free(declared_controller);
            if (!same(actual_controller, declared_controller)) return error.CorruptState;
        }
        fn storeProgramCustody(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            artifact: workspace.ProgramArtifact,
        ) !state.Reference {
            const bytes = try contracts.encodeOwned(workspace.ProgramArtifact, a, artifact);
            defer a.free(bytes);
            const reference = try store(self).putObject(bytes);
            const id = try workspaceContentCustody(a, task_id, reference.digest);
            const saved: workspace.Program = .{
                .id = id,
                .task = task_id,
                .artifact = reference,
                .description = artifact,
            };
            if (try store(self).recordBytes(a, "workspace_program", id, task_id)) |prior| {
                defer a.free(prior);
                const expected = try contracts.encodeOwned(workspace.Program, a, saved);
                defer a.free(expected);
                if (!same(prior, expected)) return error.CorruptState;
            } else try store(self).createRecord(
                workspace.Program,
                "workspace_program",
                id,
                task_id,
                saved,
            );
            return reference;
        }
    };
}
