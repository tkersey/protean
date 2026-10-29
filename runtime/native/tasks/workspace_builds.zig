const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const build_job = @import("../workspace_build.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const construction = @import("../program_construction.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const CompilerFact = task_types.CompilerFact;
const Step = task_types.Step;
const Work = task_types.Work;
const WorkspaceAdmission = task_types.WorkspaceAdmission;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const authorizeWorkspaceOccurrence = Access.authorizeWorkspaceOccurrence;
        const compilerFact = Compiler.compilerFact;
        const compilerReference = Compiler.compilerReference;
        const dispatchAcquisition = Worker.dispatchAcquisition;
        const effectSchedule = Root.effectSchedule;
        const persist = Records.persist;
        const placementSite = Lifecycle.placementSite;
        const record = Records.record;
        const rejectWorkspace = Replay.rejectWorkspace;
        const replay = Records.replay;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const requireCustody = Lifecycle.requireCustody;
        const requireSemanticPolicy = Observations.requireSemanticPolicy;
        const retainCompilerFact = Compiler.retainCompilerFact;
        const retire = Lifecycle.retire;
        const runtimeCompilerFact = Programs.runtimeCompilerFact;
        const semanticRuntime = Observations.semanticRuntime;
        const settleWorkspaceReply = Waits.settleWorkspaceReply;
        const store = Lifecycle.store;
        const subjectRemove = Scheduling.subjectRemove;
        const validateWorkspaceReadIn = Replay.validateWorkspaceReadIn;
        const workspaceBuildSource = Sources.workspaceBuildSource;
        const workspaceCandidateObservation = Observations.workspaceCandidateObservation;
        const workspaceCommandFrom = Commands.workspaceCommandFrom;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceCompiles = Access.workspaceCompiles;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceIsRead = Access.workspaceIsRead;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspaceProgramObservation = Observations.workspaceProgramObservation;
        const workspaceReadBasis = Replay.workspaceReadBasis;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceSnapshotAccess = Inspection.workspaceSnapshotAccess;
        const workspaceSource = Sources.workspaceSource;
        const workspaceStoreProgram = Programs.workspaceStoreProgram;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const workspaceWaitReady = Waits.workspaceWaitReady;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Commands = @import("workspace_commands.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Sources = @import("workspace_sources.zig").Operations(Types, Self);
        const Waits = @import("workspace_waits.zig").Operations(Types, Self);
        pub fn dispatchWorkspace(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            entry: registry.Entry,
            payload: []const u8,
        ) !Step {
            const authorized = authorizeWorkspaceOccurrence(
                self,
                a,
                initial,
                pending,
                entry,
                payload,
            ) catch |err| {
                return rejectWorkspace(self, a, initial, pending, .authorization, err);
            };
            defer a.free(authorized);
            var command = try contracts.decodeOwned(workspace.Authorized, a, authorized);
            defer command.deinit();
            if (workspaceCompiles(command.value.command))
                return dispatchWorkspaceBuild(self, a, initial, pending, entry, command.value);
            if (command.value.command == .work and command.value.command.work == .wait) {
                if (try dispatchWorkspaceWait(
                    self,
                    a,
                    initial,
                    pending,
                    command.value.command.work.wait,
                )) |step| return step;
            }
            return dispatchWorkspaceObservation(self, a, initial, pending, command.value);
        }
        fn dispatchWorkspaceBuild(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            entry: registry.Entry,
            command: workspace.Authorized,
        ) !Step {
            if (self.work != null) return .idle;
            const prepared = workspacePrepareBuild(self, a, initial, command) catch |err| {
                return rejectWorkspace(self, a, initial, pending, .preparation, err);
            };
            defer a.free(prepared);
            const request_bytes = try store(self).object(a, pending.request_object, null);
            defer a.free(request_bytes);
            return dispatchAcquisition(
                self,
                a,
                initial,
                pending,
                entry,
                request_bytes,
                prepared,
                .workspace_build,
                if (command.command.program == .derive and
                    command.command.program.derive.ancestor == .controller) .from(
                    initial,
                ) else null,
            );
        }
        fn dispatchWorkspaceWait(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            selection: @FieldType(wc.Work, "wait"),
        ) !?Step {
            const ready = workspaceWaitReady(self, a, initial, selection) catch |err|
                return try rejectWorkspace(self, a, initial, pending, .operation, err);
            if (!ready) {
                var parked = false;
                if (pending.residual) |id| {
                    var residual = try record(
                        self,
                        state.ControllerResidual,
                        a,
                        "controller_residual",
                        id,
                        initial.id,
                    );
                    defer residual.deinit();
                    parked = residual.value.schedule == .parked and
                        residual.value.blocker == .waiting_workspace;
                }
                var retained = false;
                if (try store(self).recordBytes(
                    a,
                    "workspace_wait",
                    pending.id,
                    initial.id,
                )) |bytes| {
                    defer a.free(bytes);
                    var saved = try contracts.decodeOwned(workspace.Wait, a, bytes);
                    defer saved.deinit();
                    if (!std.meta.eql(saved.value.request, pending.request_object))
                        return error.CorruptState;
                    retained = true;
                }
                if (!retained or (pending.residual != null and !parked))
                    try parkWorkspaceWait(self, a, initial, pending, selection, retained);
                subjectRemove(self, .{ .task = initial.id, .residual = pending.residual });
                try retire(self, a);
                return .waiting;
            }
            return null;
        }
        fn parkWorkspaceWait(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            selection: @FieldType(wc.Work, "wait"),
            retained: bool,
        ) !void {
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (pending.residual == null) value.schedule = .parked;
            try store(self).begin();
            defer store(self).rollback();
            if (!retained) try store(self).createRecord(
                workspace.Wait,
                "workspace_wait",
                pending.id,
                initial.id,
                .{
                    .id = pending.id,
                    .task = initial.id,
                    .request = pending.request_object,
                    .selection = selection,
                },
            );
            try effectSchedule(self, a, &value, pending, .parked, .waiting_workspace);
            try persist(self, a, value, initial.revision, "workspace.wait", .preserve);
        }
        fn dispatchWorkspaceObservation(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            command: workspace.Authorized,
        ) !Step {
            const operation_id = std.fmt.bytesToHex(pending.id, .lower);
            var basis: ?contracts.Decoded(workspace.ReadObservation) = null;
            defer if (basis) |*frozen| frozen.deinit();
            if (workspaceIsRead(command.command)) {
                const bytes = workspaceReadBasis(self, a, initial, command.command) catch |err|
                    return rejectWorkspace(self, a, initial, pending, .operation, err);
                defer a.free(bytes);
                basis = try contracts.decodeOwned(workspace.ReadObservation, a, bytes);
            }
            const observation = try workspaceCommandFrom(
                self,
                a,
                &operation_id,
                initial.id,
                command,
                if (basis) |frozen| frozen.value else null,
            );
            var parsed = try json.parseAsset(
                a,
                observation.observation_json.bytes,
                observation.observation_json.bytes.len,
            );
            defer parsed.deinit();
            const placement_evidence =
                try workspacePlacementEvidence(self, a, initial.id, &operation_id, command.command);
            const evidence: workspace.ReplyEvidence = if (placement_evidence) |reference| .{
                .placement = reference,
            } else if (observation.disposition == .rejected)
                .{ .rejected = .{
                    .stage = .operation,
                    .code = try name(try json.text(parsed.value.object.get("error") orelse
                        return error.CorruptState)),
                } }
            else if (basis) |frozen| .{ .read = frozen.value } else .{ .admitted = .{
                .replayed = (parsed.value.object.get("replayed") orelse
                    return error.CorruptState).bool,
            } };
            return settleWorkspaceReply(self, a, initial, pending, observation, evidence);
        }
        fn workspacePlacementEvidence(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            operation_id: []const u8,
            command: wc.Command,
        ) !?state.Reference {
            if (command == .placement and self.profile.placement != null) {
                const p = @import("../placement.zig");
                const action_id =
                    p.operationId(try placementSite(self), task_id, operation_id, .action);
                if (try store(self).recordBytes(
                    a,
                    "placement_action",
                    action_id,
                    task_id,
                )) |bytes| {
                    defer a.free(bytes);
                    return .{ .digest = storage.digest(bytes), .bytes = bytes.len };
                }
            }
            return null;
        }
        pub fn workspacePrepareBuild(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            authorized: workspace.Authorized,
        ) ![]u8 {
            if (authorized.command.program != .build) {
                return workspacePrepareSemanticBuild(
                    self,
                    a,
                    parent,
                    authorized.command.program,
                    null,
                );
            }
            const build = authorized.command.program.build;
            const source = switch (build.source) {
                .json_text => |text| try a.dupe(u8, text.bytes),
                .reference => |ref| try workspaceBuildSource(
                    self,
                    a,
                    parent.id,
                    ref,
                    build.source_kind,
                ),
            };
            defer a.free(source);
            var catalog: ?[]u8 = null;
            defer if (catalog) |bytes| a.free(bytes);
            if (build.source_kind == .component_recipe) {
                const ref = authorized.catalog orelse return error.UnavailableCatalog;
                try workspaceSnapshotAccess(parent, ref);
                catalog = try store(self).object(a, ref, null);
            }
            const contract =
                if (build.role == .controller) try self.controllerContract(a) else null;
            defer if (contract) |value| {
                a.free(value.result.bytes);
                a.free(value.failure.bytes);
                for (value.imports.items) |item| if (item.native_result != null) a.free(
                    item.result.bytes,
                );
                a.free(value.imports.items);
            };
            return contracts.encodeOwned(build_job.Input, a, .{ .program = .{
                .source = .{ .bytes = source },
                .kind = build.source_kind,
                .catalog = if (catalog) |bytes| .{ .bytes = bytes } else null,
                .exposures = build.exposures,
                .controller = contract,
            } });
        }
        pub fn workspacePrepareSemanticBuild(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: wc.Program,
            frozen: ?workspace.ReadObservation,
        ) ![]u8 {
            switch (command) {
                .derive => |selected| return workspacePrepareDerivation(
                    self,
                    a,
                    parent,
                    selected,
                    frozen,
                ),
                .validate => |selected| {
                    var candidate = try self.workspaceCandidate(
                        a,
                        parent.id,
                        try wp.identity(selected.candidate, .candidate),
                    );
                    defer candidate.deinit();
                    const d = candidate.value.description;
                    try requireSemanticPolicy(self, d.root, d.checker.bytes);
                    const ancestor = try store(self).object(a, d.ancestor, null);
                    defer a.free(ancestor);
                    const code = try store(self).object(a, d.code, null);
                    defer a.free(code);
                    return contracts.encodeOwned(build_job.Input, a, .{ .validate = .{
                        .ancestor = .{ .bytes = ancestor },
                        .candidate = .{ .bytes = code },
                        .candidate_ref = candidate.value.artifact,
                        .program = candidate.value.program,
                        .guest = d.guest,
                        .root = d.root,
                        .checker = d.checker,
                    } });
                },
                else => return error.InvalidState,
            }
        }
        fn workspacePrepareDerivation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            selected: @FieldType(wc.Program, "derive"),
            frozen: ?workspace.ReadObservation,
        ) ![]u8 {
            const inspect: wc.Command = .{ .program = .{ .inspect = .{
                .target = .{ .semantic_source = .{
                    .subject = selected.ancestor,
                    .section = .{ .summary = .{} },
                } },
                .page = .{},
            } } };
            const basis_bytes = if (frozen) |basis|
                try contracts.encodeOwned(workspace.ReadObservation, a, basis)
            else
                try workspaceReadBasis(self, a, parent, inspect);
            defer a.free(basis_bytes);
            var basis = try contracts.decodeOwned(workspace.ReadObservation, a, basis_bytes);
            defer basis.deinit();
            var ancestor = try semanticRuntime(self, a, parent.id, selected.ancestor, basis.value);
            defer ancestor.deinit();
            const root = kosmos.RuntimeCompiler.approvedRootIdentity(&ancestor.admitted);
            const checker = kosmos.RuntimeCompiler.checker_identity;
            try requireSemanticPolicy(self, root, checker);
            return freezeSemanticDerive(
                self,
                a,
                parent.id,
                selected,
                ancestor.admitted,
                root,
                checker,
                basis.value,
            );
        }
        fn freezeSemanticDerive(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selected: @FieldType(wc.Program, "derive"),
            ancestor: kosmos.RuntimeArtifact,
            root: state.Digest,
            checker: []const u8,
            basis: workspace.ReadObservation,
        ) ![]u8 {
            const program_id = try wp.identity(selected.program, .program);
            var program = try self.workspaceProgram(a, task_id, program_id);
            defer program.deinit();
            const image = try store(self).object(a, program.value.description.image, null);
            defer a.free(image);
            const root_bytes = try ancestor.encode(a);
            defer a.free(root_bytes);
            const proposal = try workspaceProposal(self, a, task_id, selected.proposal);
            defer a.free(proposal);
            const producer =
                if (selected.proposal == .reference and selected.proposal.reference.kind == .value)
                    (try workspaceValueReference(
                        self,
                        a,
                        task_id,
                        selected.proposal.reference,
                    )).artifact
                else
                    null;
            return contracts.encodeOwned(build_job.Input, a, .{ .derive = .{
                .ancestor = .{ .bytes = root_bytes },
                .guest = .{ .bytes = image },
                .program = program_id,
                .proposal = .{ .bytes = proposal },
                .producer = producer,
                .root = root,
                .checker = try name(checker),
                .subject = selected.ancestor,
                .basis = basis,
            } });
        }
        pub fn workspaceProposal(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: wc.SourceInput,
        ) ![]u8 {
            if (input == .json_text) return a.dupe(u8, input.json_text.bytes);
            if (input.reference.kind == .source)
                return workspaceSource(self, a, task_id, input.reference);
            const source = try workspaceValueReference(self, a, task_id, input.reference);
            const schema = try values.schemaBytes(construction.CandidateDocument, a);
            defer a.free(schema);
            if (!std.meta.eql(source.schema, state.Reference{
                .digest = storage.digest(schema),
                .bytes = schema.len,
            })) return error.SchemaMismatch;
            const bytes = try store(self).object(a, source.value, null);
            defer a.free(bytes);
            var document = try contracts.decodeOwned(construction.CandidateDocument, a, bytes);
            defer document.deinit();
            if (document.value.version != 1) return error.UnsupportedVersion;
            return @import("../source_records.zig").encodeRecord(
                construction.CandidateDocument,
                a,
                document.value,
            );
        }
        pub fn validateSemanticReadPosition(
            basis: workspace.ReadObservation,
            event_seq: u64,
        ) !void {
            const watermark = switch (basis) {
                .immutable => return,
                .controller => |read| read.event_watermark,
                .works => |read| read.event_watermark,
                else => return error.InvalidArchive,
            };
            if (event_seq == 0 or watermark != event_seq - 1) return error.InvalidArchive;
        }
        pub fn validateSemanticInput(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: wc.Program,
            input: build_job.Input,
            records: []const state.ArchiveRecord,
            controller_read: ?state.ControllerReadCut,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            if (command == .derive and input == .derive) {
                const inspect: wc.Command = .{ .program = .{ .inspect = .{
                    .target = .{ .semantic_source = .{
                        .subject = command.derive.ancestor,
                        .section = .{ .summary = .{} },
                    } },
                    .page = .{},
                } } };
                try validateWorkspaceReadIn(
                    self,
                    a,
                    parent,
                    inspect,
                    input.derive.basis,
                    records,
                    controller_read,
                    checked,
                );
                return;
            }
            if (command != .validate or input != .validate or controller_read != null)
                return error.InvalidArchive;
            var candidate = try self.workspaceCandidate(
                a,
                parent.id,
                try wp.identity(command.validate.candidate, .candidate),
            );
            defer candidate.deinit();
            if (!std.meta.eql(candidate.value.artifact, input.validate.candidate_ref))
                return error.InvalidArchive;
            try requireArchiveRecord(records, .workspace_candidate, candidate.value.id);
        }
        pub fn validateSemanticPublication(
            self: *Self,
            parent: state.Task,
            selected: @FieldType(workspace.PublicationCommand, "semantic"),
            admission: WorkspaceAdmission,
            records: []const state.ArchiveRecord,
            event_seq: u64,
            controller_read: ?state.ControllerReadCut,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var phase: []const u8 = "input";
            errdefer std.debug.print("semantic publication: {s}\n", .{phase});
            const input_bytes = try store(self).object(a, selected.input, null);
            defer a.free(input_bytes);
            var input = try contracts.decodeOwned(build_job.Input, a, input_bytes);
            defer input.deinit();
            if (input.value == .derive)
                try validateSemanticReadPosition(input.value.derive.basis, event_seq);
            try validateSemanticInput(
                self,
                a,
                parent,
                selected.command,
                input.value,
                records,
                controller_read,
                checked,
            );
            phase = "frozen input";
            const frozen = try workspacePrepareSemanticBuild(
                self,
                a,
                parent,
                selected.command,
                if (input.value == .derive) input.value.derive.basis else null,
            );
            defer a.free(frozen);
            if (!same(frozen, input_bytes)) return error.InvalidArchive;
            const output_bytes = try store(self).object(a, selected.output, null);
            defer a.free(output_bytes);
            phase = "compiler output";
            try validateCompilerOutput(self, parent.id, input_bytes, output_bytes);
            phase = "retained observation";
            var output = try contracts.decodeOwned(build_job.Output, a, output_bytes);
            defer output.deinit();
            const observed = try retainedSemanticObservation(
                self,
                a,
                parent.id,
                input.value,
                output.value,
                selected.output,
            );
            const expected = try contracts.encodeOwned(workspace.SemanticObservation, a, observed);
            defer a.free(expected);
            const reference = admission.observation orelse return error.InvalidArchive;
            if (!std.meta.eql(reference, state.Reference{
                .digest = storage.digest(expected),
                .bytes = expected.len,
            }) or !std.meta.eql(
                admission.work,
                if (observed.candidate) |ref| ref.digest else reference.digest,
            ))
                return error.InvalidArchive;
        }
        pub fn validateCompilerOutput(
            self: *Self,
            task_id: state.TaskId,
            input: []const u8,
            output: []const u8,
        ) !void {
            const fact: CompilerFact = .{
                .kind = .output,
                .input = compilerReference(input),
                .output = compilerReference(output),
            };
            if (try compilerFact(self, fact)) return;
            const a = self.allocator;
            var frozen = try contracts.decodeOwned(build_job.Input, a, input);
            defer frozen.deinit();
            var actual = try contracts.decodeOwned(build_job.Output, a, output);
            defer actual.deinit();
            if (actual.value == .validation) switch (actual.value.validation.outcome) {
                .resource_exhausted, .interrupted, .unavailable_dependency => {
                    if (frozen.value != .validate or actual.value.validation.code.bytes.len == 0)
                        return error.InvalidArchive;
                    try retainCompilerFact(self, fact);
                    return;
                },
                else => {},
            };
            const task_name = std.fmt.bytesToHex(task_id, .lower);
            const expected_bytes = try build_job.run(.{
                .allocator = a,
                .io = self.io,
                .authority = &self.profile.authority,
                .task_id = &task_name,
                .profile = self.profile.bytes,
                .environment = null,
            }, input);
            defer a.free(expected_bytes);
            var expected = try contracts.decodeOwned(build_job.Output, a, expected_bytes);
            defer expected.deinit();
            switch (expected.value) {
                inline else => |*value| value.compiler_nanoseconds = 0,
            }
            switch (actual.value) {
                inline else => |*value| value.compiler_nanoseconds = 0,
            }
            const expected_value = try contracts.encodeOwned(build_job.Output, a, expected.value);
            defer a.free(expected_value);
            const actual_value = try contracts.encodeOwned(build_job.Output, a, actual.value);
            defer a.free(actual_value);
            if (!same(expected_value, actual_value)) return error.InvalidArchive;
            try retainCompilerFact(self, fact);
            try retainCompilerOutputEvidence(self, a, frozen.value, actual.value);
        }
        fn retainCompilerOutputEvidence(
            self: *Self,
            a: std.mem.Allocator,
            frozen: build_job.Input,
            actual: build_job.Output,
        ) !void {
            if (frozen == .derive and actual == .derived) {
                const description =
                    semanticCandidateDescription(frozen.derive, actual.derived.artifact.bytes);
                const bytes =
                    try contracts.encodeOwned(workspace.CandidateArtifact, a, description);
                defer a.free(bytes);
                try retainCompilerFact(self, .{
                    .kind = .candidate,
                    .input = compilerReference(bytes),
                    .output = description.code,
                });
            } else if (frozen == .validate and actual == .validation and
                actual.validation.outcome == .validated)
            {
                const selected = frozen.validate;
                try retainCompilerFact(
                    self,
                    try runtimeCompilerFact(a, compilerReference(selected.candidate.bytes), .{
                        .candidate = selected.candidate_ref,
                        .ancestor = compilerReference(selected.ancestor.bytes),
                        .guest = selected.guest,
                        .root = selected.root,
                        .checker = selected.checker,
                    }),
                );
            }
        }
        pub fn workspaceSemanticCommand(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: wc.Program,
        ) !Admission {
            const request = try operation(workspace.SemanticRequest, a, .{
                .task = task_id,
                .command = command,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            const input_bytes =
                try workspacePrepareSemanticBuild(self, a, parent.value, command, null);
            defer a.free(input_bytes);
            const task_name = std.fmt.bytesToHex(task_id, .lower);
            if (store(self).transaction) return error.CompilerPreparationRequired;
            const output_bytes = try build_job.run(.{
                .allocator = a,
                .io = self.io,
                .authority = &self.profile.authority,
                .task_id = &task_name,
                .profile = self.profile.bytes,
                .environment = null,
            }, input_bytes);
            defer a.free(output_bytes);
            var input = try contracts.decodeOwned(build_job.Input, a, input_bytes);
            defer input.deinit();
            var output = try contracts.decodeOwned(build_job.Output, a, output_bytes);
            defer output.deinit();
            try store(self).begin();
            defer store(self).rollback();
            const observed = try workspaceStoreSemantic(
                self,
                a,
                task_id,
                input.value,
                output.value,
                output_bytes,
            );
            const observed_bytes =
                try contracts.encodeOwned(workspace.SemanticObservation, a, observed);
            defer a.free(observed_bytes);
            const observation = try store(self).putObject(observed_bytes);
            return workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                request,
                if (observed.candidate) |ref| ref.digest else observation.digest,
                .candidate,
                observation,
                .{ .semantic = .{
                    .command = command,
                    .input = try store(self).putObject(input_bytes),
                    .output = observed.output,
                } },
            );
        }
        fn workspaceStoreSemantic(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: build_job.Input,
            output: build_job.Output,
            output_bytes: []const u8,
        ) !workspace.SemanticObservation {
            const result: workspace.SemanticObservation = .{
                .candidate = null,
                .runtime = null,
                .output = try store(self).putObject(output_bytes),
            };
            switch (output) {
                .rejected => return result,
                .derived => |derived| {
                    if (input != .derive) return error.InvalidCandidate;
                    var observed = result;
                    observed.candidate = try workspaceStoreCandidate(
                        self,
                        a,
                        task_id,
                        input.derive,
                        derived.artifact.bytes,
                    );
                    return observed;
                },
                .validation => |validation| {
                    if (input != .validate) return error.InvalidCandidate;
                    var observed = result;
                    observed.candidate = input.validate.candidate_ref;
                    if (validation.outcome == .validated) {
                        observed.runtime =
                            try workspaceStoreValidation(self, a, task_id, input.validate);
                    }
                    return observed;
                },
                .compiled, .rejected_contract => return error.InvalidCandidate,
            }
        }
        fn workspaceStoreCandidate(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: build_job.DeriveInput,
            code: []const u8,
        ) !state.Reference {
            var admitted = try kosmos.RuntimeArtifact.init(a, code, storage.digest(code));
            defer admitted.deinit();
            const lineage = admitted.content.value.lineage orelse return error.InvalidCandidate;
            if (!std.meta.eql(lineage.parent, storage.digest(input.ancestor.bytes)) or
                !std.meta.eql(lineage.root, input.root) or
                !same(lineage.checker, input.checker.bytes))
                return error.InvalidCandidate;
            _ = try store(self).putObject(input.ancestor.bytes);
            _ = try store(self).putObject(input.guest.bytes);
            _ = try store(self).putObject(input.proposal.bytes);
            _ = try store(self).putObject(code);
            const description = semanticCandidateDescription(input, code);
            const bytes = try contracts.encodeOwned(workspace.CandidateArtifact, a, description);
            defer a.free(bytes);
            const artifact = try store(self).putObject(bytes);
            const id = try workspaceContentCustody(a, task_id, artifact.digest);
            const value: workspace.Candidate = .{
                .id = id,
                .task = task_id,
                .program = input.program,
                .artifact = artifact,
                .description = description,
            };
            if (try store(self).recordBytes(a, "workspace_candidate", id, task_id)) |prior| {
                defer a.free(prior);
                var saved = try contracts.decodeOwned(workspace.Candidate, a, prior);
                defer saved.deinit();
                var canonical = value;
                canonical.program = saved.value.program;
                const expected = try contracts.encodeOwned(workspace.Candidate, a, canonical);
                defer a.free(expected);
                if (!same(prior, expected)) return error.InvalidCandidate;
            } else try store(self).createRecord(
                workspace.Candidate,
                "workspace_candidate",
                id,
                task_id,
                value,
            );
            return artifact;
        }
        fn semanticCandidateDescription(
            input: build_job.DeriveInput,
            code: []const u8,
        ) workspace.CandidateArtifact {
            return .{
                .ancestor = .{
                    .digest = storage.digest(input.ancestor.bytes),
                    .bytes = input.ancestor.bytes.len,
                },
                .guest = .{
                    .digest = storage.digest(input.guest.bytes),
                    .bytes = input.guest.bytes.len,
                },
                .proposal = .{
                    .digest = storage.digest(input.proposal.bytes),
                    .bytes = input.proposal.bytes.len,
                },
                .code = .{ .digest = storage.digest(code), .bytes = code.len },
                .producer = input.producer,
                .root = input.root,
                .checker = input.checker,
            };
        }
        pub fn retainedSemanticObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: build_job.Input,
            output: build_job.Output,
            output_ref: state.Reference,
        ) !workspace.SemanticObservation {
            var result: workspace.SemanticObservation = .{
                .candidate = null,
                .runtime = null,
                .output = output_ref,
            };
            switch (output) {
                .rejected => {},
                .derived => |derived| {
                    if (input != .derive) return error.InvalidArchive;
                    const description =
                        semanticCandidateDescription(input.derive, derived.artifact.bytes);
                    const bytes =
                        try contracts.encodeOwned(workspace.CandidateArtifact, a, description);
                    defer a.free(bytes);
                    var candidate = try self.workspaceCandidate(a, task_id, storage.digest(bytes));
                    defer candidate.deinit();
                    result.candidate = candidate.value.artifact;
                },
                .validation => |validation| {
                    if (input != .validate) return error.InvalidArchive;
                    var candidate = try self.workspaceCandidate(
                        a,
                        task_id,
                        input.validate.candidate_ref.digest,
                    );
                    defer candidate.deinit();
                    if (!std.meta.eql(candidate.value.artifact, input.validate.candidate_ref))
                        return error.InvalidArchive;
                    result.candidate = candidate.value.artifact;
                    if (validation.outcome == .validated) {
                        var runtime = try workspaceRuntime(
                            self,
                            a,
                            task_id,
                            candidate.value.description.code.digest,
                            candidate.value.program,
                        );
                        defer runtime.deinit();
                        result.runtime = runtime.record.value.artifact;
                    }
                },
                .compiled, .rejected_contract => return error.InvalidArchive,
            }
            return result;
        }
        fn workspaceStoreValidation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: build_job.ValidateInput,
        ) !state.Reference {
            var candidate =
                try self.workspaceCandidate(a, task_id, input.candidate_ref.digest);
            defer candidate.deinit();
            const d = candidate.value.description;
            if (!std.meta.eql(d.root, input.root) or !std.meta.eql(d.guest, input.guest) or
                !std.meta.eql(d.code.digest, storage.digest(input.candidate.bytes)) or
                !std.meta.eql(d.ancestor.digest, storage.digest(input.ancestor.bytes)) or
                !same(d.checker.bytes, input.checker.bytes)) return error.InvalidCandidate;
            const id = try workspaceContentCustody(a, task_id, d.code.digest);
            const value: workspace.Runtime = .{
                .id = id,
                .task = task_id,
                .program = candidate.value.program,
                .artifact = d.code,
                .validation = .{
                    .candidate = candidate.value.artifact,
                    .ancestor = d.ancestor,
                    .guest = d.guest,
                    .root = d.root,
                    .checker = d.checker,
                },
            };
            if (try store(self).recordBytes(a, "workspace_runtime", id, task_id)) |prior| {
                defer a.free(prior);
                var saved = try contracts.decodeOwned(workspace.Runtime, a, prior);
                defer saved.deinit();
                var canonical = value;
                const validation = saved.value.validation orelse return error.InvalidRuntime;
                canonical.program = saved.value.program;
                canonical.validation.?.candidate = validation.candidate;
                const expected = try contracts.encodeOwned(workspace.Runtime, a, canonical);
                defer a.free(expected);
                if (!same(prior, expected)) return error.InvalidRuntime;
            } else try store(self).createRecord(
                workspace.Runtime,
                "workspace_runtime",
                id,
                task_id,
                value,
            );
            return d.code;
        }
        pub fn workspaceSemanticObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            observed: workspace.SemanticObservation,
        ) !json.Value {
            const output_bytes = try store(self).object(a, observed.output, null);
            defer a.free(output_bytes);
            var decoded = try contracts.decodeOwned(build_job.Output, a, output_bytes);
            defer decoded.deinit();
            const output = decoded.value;
            var result = json.object();
            if (observed.candidate) |ref| {
                var candidate = try self.workspaceCandidate(a, task_id, ref.digest);
                defer candidate.deinit();
                result = try workspaceCandidateObservation(self, a, candidate.value);
            }
            switch (output) {
                .rejected => |failure| {
                    try json.put(
                        a,
                        &result,
                        "error",
                        json.string(try a.dupe(u8, failure.code.bytes)),
                    );
                    try json.put(a, &result, "construction", json.string("rejected"));
                },
                .derived => {},
                .validation => |validation| {
                    try json.put(
                        a,
                        &result,
                        "validation",
                        json.string(@tagName(validation.outcome)),
                    );
                    try json.put(a, &result, "diagnostic", json.string(
                        try a.dupe(u8, validation.code.bytes),
                    ));
                },
                .compiled, .rejected_contract => return error.InvalidCandidate,
            }
            if (observed.runtime) |ref| {
                try json.put(a, &result, "runtime", try values.toJson(
                    wc.Ref,
                    a,
                    try wp.reference(a, .runtime, ref.digest),
                ));
                try json.put(a, &result, "runtime_authority", .{ .bool = true });
            }
            const compiler_nanoseconds = switch (output) {
                inline else => |value| value.compiler_nanoseconds,
            };
            try json.put(
                a,
                &result,
                "compiler_nanoseconds",
                try json.number(a, compiler_nanoseconds),
            );
            return result;
        }
        pub fn workspaceBuildReply(
            self: *Self,
            a: std.mem.Allocator,
            program: ?state.Reference,
            output: build_job.Output,
        ) !wc.Reply {
            var result = json.object();
            if (output.rejection()) |failure| {
                try json.put(
                    a,
                    &result,
                    "compiler_nanoseconds",
                    try json.number(a, failure.compiler_nanoseconds),
                );
                try json.put(a, &result, "error", json.string(try a.dupe(u8, failure.code.bytes)));
                try json.put(a, &result, "phase", json.string(try a.dupe(u8, failure.phase.bytes)));
                try json.put(a, &result, "function", try values.toJson(?u64, a, failure.function));
                try json.put(a, &result, "term", try values.toJson(?u64, a, failure.term));
                try json.put(a, &result, "value", try values.toJson(?u64, a, failure.value));
                if (output == .rejected_contract) {
                    try json.put(
                        a,
                        &result,
                        "continuation_contract",
                        try values.toJson(
                            build_job.ContinuationDiagnostic,
                            a,
                            output.rejected_contract.continuation,
                        ),
                    );
                }
                return .{ .disposition = .rejected, .observation_json = .{
                    .bytes = try json.canonical(a, result),
                } };
            }
            const saved = program orelse return error.CorruptState;
            var artifact = try contracts.decodeOwned(
                workspace.ProgramArtifact,
                a,
                try store(self).object(a, saved, null),
            );
            defer artifact.deinit();
            result =
                try workspaceProgramObservation(self, a, saved.digest, artifact.value);
            try json.put(
                a,
                &result,
                "compiler_nanoseconds",
                try json.number(a, output.compiled.compiler_nanoseconds),
            );
            return .{ .disposition = .admitted, .program = try wp.reference(
                a,
                .program,
                saved.digest,
            ), .observation_json = .{ .bytes = try json.canonical(a, result) } };
        }
        pub fn interpretWorkspaceBuild(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            raw: state.Capture,
        ) !Step {
            const rendered = try store(self).object(a, raw.request, null);
            defer a.free(rendered);
            var input = try contracts.decodeOwned(build_job.Input, a, rendered);
            defer input.deinit();
            const response = try store(self).object(a, raw.response.?, null);
            defer a.free(response);
            var output = try contracts.decodeOwned(build_job.Output, a, response);
            defer output.deinit();
            if (input.value != .program) return interpretWorkspaceSemantic(
                self,
                a,
                initial,
                pending,
                attempt,
                raw,
                input.value,
                output.value,
                response,
            );
            return interpretWorkspaceProgram(
                self,
                a,
                initial,
                pending,
                attempt,
                raw,
                input.value,
                output.value,
            );
        }
        fn interpretWorkspaceProgram(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            raw: state.Capture,
            input: build_job.Input,
            output: build_job.Output,
        ) !Step {
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            const program: ?state.Reference =
                if (output == .compiled) try workspaceStoreProgram(
                    self,
                    a,
                    initial.id,
                    input.program.source.bytes,
                    @fromBackingInt(@intCast(@backingInt(input.program.kind))),
                    if (input.program.catalog) |bytes| .{
                        .digest = storage.digest(bytes.bytes),
                        .bytes = bytes.bytes.len,
                    } else null,
                    input.program.exposures.items,
                    output.compiled,
                ) else null;
            const reply = try workspaceBuildReply(self, a, program, output);
            const payload = try contracts.encodeOwned(wc.Reply, a, reply);
            defer a.free(payload);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = payload,
            });
            defer a.free(bound);
            const next = try occurrence.acquired(
                pending,
                .{
                    .id = pending.id,
                    .task = initial.id,
                    .request = pending.request,
                },
                attempt.id,
                storage.digest(bound),
            );
            var projected = raw;
            projected.projection = .{
                .reply = try store(self).putObject(bound),
                .objects = .{ .items = &.{} },
                .output_tokens = null,
            };
            try store(self).putRecord(state.Capture, "capture", attempt.id, initial.id, projected);
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                initial.id,
                next,
            );
            // The retained capture/reply owns the program observation. A
            // second journal projection has no independent publication fact.
            try persist(self, a, parent, initial.revision, "workspace.build", .preserve);
            if (program) |saved| try self.checked_workspace_programs.put(
                self.allocator,
                saved.digest,
                store(self).integrity_epoch,
            );
            return .progressed;
        }
        fn interpretWorkspaceSemantic(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            raw: state.Capture,
            input: build_job.Input,
            output: build_job.Output,
            response: []const u8,
        ) !Step {
            switch (output) {
                .derived => {
                    if (input != .derive) return error.InvalidCandidate;
                    var guest =
                        try self.workspaceProgram(a, initial.id, input.derive.program);
                    guest.deinit();
                },
                .validation => {
                    if (input != .validate) return error.InvalidCandidate;
                    var candidate = try self.workspaceCandidate(
                        a,
                        initial.id,
                        input.validate.candidate_ref.digest,
                    );
                    candidate.deinit();
                },
                .rejected => {},
                .compiled, .rejected_contract => return error.InvalidCandidate,
            }
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            const observed =
                try workspaceStoreSemantic(self, a, initial.id, input, output, response);
            const reply = try workspaceSemanticReply(self, a, initial.id, observed);
            const payload = try contracts.encodeOwned(wc.Reply, a, reply);
            defer a.free(payload);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = payload,
            });
            defer a.free(bound);
            const next = try occurrence.acquired(pending, .{
                .id = pending.id,
                .task = initial.id,
                .request = pending.request,
            }, attempt.id, storage.digest(bound));
            var projected = raw;
            projected.projection = .{
                .reply = try store(self).putObject(bound),
                .objects = .{ .items = &.{} },
                .output_tokens = null,
            };
            try store(self).putRecord(state.Capture, "capture", attempt.id, initial.id, projected);
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                initial.id,
                next,
            );
            try persist(self, a, parent, initial.revision, "workspace.semantic", .preserve);
            return .progressed;
        }
        pub fn workspaceSemanticReply(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            observed: workspace.SemanticObservation,
        ) !wc.Reply {
            const observation = try workspaceSemanticObservation(self, a, task_id, observed);
            return .{
                .disposition = if (observation.object.contains("error")) .rejected else .admitted,
                .observation_json = .{ .bytes = try json.canonical(a, observation) },
                .evidence = if (observation.object.get("runtime") orelse
                    observation.object.get("candidate")) |ref|
                    try values.fromJson(wc.Ref, a, ref)
                else
                    null,
            };
        }
    };
}
