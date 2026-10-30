const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const build_job = @import("../workspace_build.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const construction = @import("../program_construction.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Work = task_types.Work;
const WorkspaceExecution = task_types.WorkspaceExecution;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const appendWorkspaceReference = Access.appendWorkspaceReference;
        const compatible = Controller.compatible;
        const controllerBinding = Controller.controllerBinding;
        const controllerResidualControl = Residuals.controllerResidualControl;
        const controllerResidualIds = Recovery.controllerResidualIds;
        const controllerResidualObservation = Residuals.controllerResidualObservation;
        const placementModel = Transport.placementModel;
        const record = Records.record;
        const renderWorkspaceWorkObservation = Observations.renderWorkspaceWorkObservation;
        const renderWorkspaceWorkObservationIn = Observations.renderWorkspaceWorkObservationIn;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const rootIdentity = Controller.rootIdentity;
        const store = Lifecycle.store;
        const validateHistoricalOccurrence = Replay.validateHistoricalOccurrence;
        const validateWorkspaceWorkSnapshotIn = Snapshots.validateWorkspaceWorkSnapshotIn;
        const workspaceBuildKind = Programs.workspaceBuildKind;
        const workspaceBuildSource = Sources.workspaceBuildSource;
        const workspaceCandidateObservation = Observations.workspaceCandidateObservation;
        const workspaceConsumer = Observations.workspaceConsumer;
        const workspaceContextMutation = Contexts.workspaceContextMutation;
        const workspaceDelegate = Publication.workspaceDelegate;
        const workspaceDerivationPage = Sources.workspaceDerivationPage;
        const workspaceOwnedDescriptor = Sources.workspaceOwnedDescriptor;
        const workspacePayloadBytesPage = Observations.workspacePayloadBytesPage;
        const workspacePayloadPage = Observations.workspacePayloadPage;
        const workspaceProgramObservation = Observations.workspaceProgramObservation;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceRuntimeObservation = Programs.workspaceRuntimeObservation;
        const workspaceScopeAt = Access.workspaceScopeAt;
        const workspaceSemanticCommand = Builds.workspaceSemanticCommand;
        const workspaceSemanticContract = Observations.workspaceSemanticContract;
        const workspaceSemanticObservation = Builds.workspaceSemanticObservation;
        const workspaceSemanticSource = Observations.workspaceSemanticSource;
        const workspaceSnapshotAccess = Inspection.workspaceSnapshotAccess;
        const workspaceSourcePage = Sources.workspaceSourcePage;
        const workspaceStartAdmitted = Start.workspaceStartAdmitted;
        const workspaceValueObservation = Sources.workspaceValueObservation;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const workspaceViewObservation = Sources.workspaceViewObservation;
        const workspaceWorkObservation = Observations.workspaceWorkObservation;
        const workspaceWorkObservationIn = Observations.workspaceWorkObservationIn;
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Builds = @import("workspace_builds.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Sources = @import("workspace_sources.zig").Operations(Types, Self);
        const Start = @import("workspace_start.zig").Operations(Types, Self);
        pub fn workspaceCommand(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: wc.Command,
        ) !wc.Reply {
            // Call only after joining any in-flight worker. Closing is physical
            // parking, never an implicit semantic cancellation or new dispatch.
            // The caller must be the admitted root workspace occurrence. Adapters
            // authenticate the original model call; this owner enforces custody.
            return workspaceCommandAuthorized(self, a, operation_id, task_id, .{
                .command = command,
            });
        }
        fn workspaceCommandAuthorized(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            admitted: workspace.Authorized,
        ) !wc.Reply {
            return workspaceCommandFrom(self, a, operation_id, task_id, admitted, null);
        }
        pub fn workspaceCommandFrom(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            admitted: workspace.Authorized,
            basis: ?workspace.ReadObservation,
        ) !wc.Reply {
            try allowed(self);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            var observers = Observers.CurrentObservers.init(a, task_id, parent.value.event_high);
            defer observers.deinit();
            return workspaceCommandFromIn(self, a, operation_id, task_id, admitted, basis, .{
                .current = &observers,
            });
        }
        pub fn workspaceCommandFromIn(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            admitted: workspace.Authorized,
            basis: ?workspace.ReadObservation,
            observers: Observers.ObserverScope,
        ) !wc.Reply {
            try allowed(self);
            const command = admitted.command;
            var compiler_facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            defer compiler_facts.deinit();
            const prior_compiler_facts = self.compiler_facts;
            if (command == .context and
                (command.context == .materialize or command.context == .select) and
                self.compiler_facts == null) self.compiler_facts = &compiler_facts;
            defer self.compiler_facts = prior_compiler_facts;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            if (command == .placement) return placementModel(
                self,
                a,
                operation_id,
                task_id,
                command.placement,
            ) catch |err| {
                if (store(self).fenced or err == error.OutOfMemory or
                    err == error.StorageUnavailable)
                    return err;
                return workspaceRejection(a, err);
            };
            const executed = workspaceExecute(
                self,
                a,
                operation_id,
                task_id,
                admitted,
                basis,
                observers,
            ) catch |err| {
                if (store(self).fenced or err == error.OutOfMemory or
                    err == error.StorageUnavailable)
                    return err;
                return workspaceRejection(a, err);
            };
            // Admission is durable. Projection failures must never rewrite it
            // as a rejected operation; callers can retry its retained receipt.
            const observation = switch (executed) {
                .observation => |value| value,
                .admitted => |accepted| try workspaceAdmissionObservation(
                    self,
                    a,
                    task_id,
                    accepted,
                ),
            };
            return workspaceObservedReply(a, command, observation);
        }
        fn workspaceObservedReply(
            a: std.mem.Allocator,
            command: wc.Command,
            observation: json.Value,
        ) !wc.Reply {
            const rejected = observation == .object and observation.object.contains("error");
            const selected = if (!rejected and command == .context and command.context == .select)
                try values.fromJson(wc.Ref, a, observation.object.get("view") orelse
                    return error.CorruptState)
            else
                null;
            const program = if (!rejected and command == .program and command.program == .build)
                try values.fromJson(wc.Ref, a, observation.object.get("program") orelse
                    return error.CorruptState)
            else
                null;
            const evidence: ?wc.Ref = if (!rejected and observation == .object) blk: {
                const result = if (command == .context and command.context == .materialize)
                    observation.object.get("value")
                else if (command == .work)
                    observation.object.get("result")
                else if (command == .program and
                    (command.program == .derive or command.program == .validate))
                    observation.object.get("runtime") orelse observation.object.get("candidate")
                else
                    null;
                break :blk if (result) |ref| try values.fromJson(wc.Ref, a, ref) else null;
            } else null;
            return .{
                .disposition = if (rejected) .rejected else .observed,
                .observation_json = .{ .bytes = try json.canonical(a, observation) },
                .selected_view = selected,
                .program = program,
                .evidence = evidence,
            };
        }
        pub fn workspaceRejection(a: std.mem.Allocator, err: anyerror) !wc.Reply {
            var failure = json.object();
            try json.put(a, &failure, "error", json.string(@errorName(err)));
            return .{ .disposition = .rejected, .observation_json = .{
                .bytes = try json.canonical(a, failure),
            } };
        }
        fn workspaceExecute(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            basis: ?workspace.ReadObservation,
            observers: Observers.ObserverScope,
        ) !WorkspaceExecution {
            const command = authorized.command;
            switch (command) {
                .placement => return error.InvalidState,
                .program => |program| return workspaceExecuteProgram(
                    self,
                    a,
                    operation_id,
                    task_id,
                    authorized,
                    basis,
                    program,
                ),
                .work => |work_command| return workspaceExecuteWork(
                    self,
                    a,
                    operation_id,
                    task_id,
                    authorized,
                    basis,
                    observers,
                    work_command,
                ),
                .context => |context| return workspaceExecuteContext(
                    self,
                    a,
                    operation_id,
                    task_id,
                    authorized,
                    basis,
                    context,
                ),
            }
        }
        fn workspaceExecuteProgram(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            basis: ?workspace.ReadObservation,
            program: wc.Program,
        ) !WorkspaceExecution {
            switch (program) {
                .adopt => |command_value| return executeProgramAdopt(
                    self,
                    a,
                    task_id,
                    command_value,
                ),
                .describe => |request| return executeProgramDescribe(
                    self,
                    a,
                    task_id,
                    authorized,
                    basis,
                    request,
                ),
                .build => |request| return executeProgramBuild(
                    self,
                    a,
                    operation_id,
                    task_id,
                    authorized,
                    request,
                ),
                .inspect => |request| return executeProgramInspect(
                    self,
                    a,
                    task_id,
                    basis,
                    request,
                ),
                .specialize => |request| return .{
                    .admitted = try self.workspaceSpecializeWithHooks(
                        a,
                        operation_id,
                        task_id,
                        try wp.identity(request.program, .program),
                        request.hooks,
                    ),
                },
                .derive, .validate => return .{ .admitted = try workspaceSemanticCommand(
                    self,
                    a,
                    operation_id,
                    task_id,
                    program,
                ) },
            }
        }
        fn executeProgramAdopt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            command_value: @FieldType(wc.Program, "adopt"),
        ) !WorkspaceExecution {
            var id: state.Digest = undefined;
            if (command_value.expected_handoff_identity.bytes.len != 64)
                return error.InvalidReference;
            _ = std.fmt.hexToBytes(&id, command_value.expected_handoff_identity.bytes) catch
                return error.InvalidReference;
            const bytes = (try store(self).recordBytes(
                a,
                "controller_succession",
                id,
                task_id,
            )) orelse return error.ControllerHandoffRequired;
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(state.ControllerSuccession, a, bytes);
            defer saved.deinit();
            const command_bytes = try contracts.encodeOwned(wc.Adoption, a, command_value);
            defer a.free(command_bytes);
            if (!std.meta.eql(saved.value.command.digest, storage.digest(command_bytes)))
                return error.OperationConflict;
            return .{
                .observation = try values.toJson(state.ControllerSuccession, a, saved.value),
            };
        }
        fn executeProgramDescribe(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            basis: ?workspace.ReadObservation,
            request: @FieldType(wc.Program, "describe"),
        ) !WorkspaceExecution {
            const description = switch (request.section) {
                .semantic_candidates => try workspaceSemanticContract(self, a, basis),
                .source_records => try @import("../source_records.zig").describe(a),
                .source_derivations => try @import("../source_records.zig").describeRecord(
                    @import("../source_records.zig").DerivationDocument,
                    a,
                ),
                .values => try describeWorkspaceValues(a),
                .bindings => try describeWorkspaceBindings(a),
                .runtimes => try describeWorkspaceRuntimes(a),
                .examples => try construction.example(a),
                .retention_query => try construction.runtimeQuery(a, true),
                .divergence_query => try construction.runtimeQuery(a, false),
                .hypothetical_reply => try construction.hypotheticalReply(a),
                .controller_contract => try describeControllerContract(self, a),
                .current_controller => try describeCurrentController(self, a, task_id, basis),
                .components => try describeComponents(self, a, task_id, authorized),
            };
            defer a.free(description);
            return .{ .observation = try wp.page(a, description, request.page) };
        }
        fn executeProgramBuild(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            request: @FieldType(wc.Program, "build"),
        ) !WorkspaceExecution {
            const text = switch (request.source) {
                .json_text => |inline_text| try a.dupe(u8, inline_text.bytes),
                .reference => |ref| try workspaceBuildSource(
                    self,
                    a,
                    task_id,
                    ref,
                    request.source_kind,
                ),
            };
            defer a.free(text);
            var diagnostic: construction.Diagnostic = .{};
            const admitted = workspaceBuildKind(
                self,
                a,
                operation_id,
                task_id,
                text,
                request.source_kind,
                if (request.source_kind == .component_recipe) authorized.catalog else null,
                request.exposures.items,
                request.role,
                &diagnostic,
            ) catch |err| {
                if (store(self).fenced or err == error.OutOfMemory) return err;
                return workspaceBuildFailure(a, err, diagnostic);
            };
            return .{ .admitted = admitted };
        }
        fn executeProgramInspect(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            request: @FieldType(wc.Program, "inspect"),
        ) !WorkspaceExecution {
            if (request.target == .consumer) {
                return .{
                    .observation = try workspaceConsumer(
                        self,
                        a,
                        task_id,
                        request.target.consumer,
                        request.page,
                    ),
                };
            }
            if (request.target == .semantic_source) {
                return .{ .observation = try workspaceSemanticSource(
                    self,
                    a,
                    task_id,
                    request.target.semantic_source,
                    request.page,
                    basis,
                ) };
            }
            const ref = request.target.program;
            if (ref.kind == .candidate) {
                var candidate =
                    try self.workspaceCandidate(a, task_id, try wp.identity(ref, .candidate));
                defer candidate.deinit();
                const text = try json.canonical(
                    a,
                    try workspaceCandidateObservation(self, a, candidate.value),
                );
                defer a.free(text);
                return .{ .observation = try wp.page(a, text, request.page) };
            }
            if (ref.kind == .runtime) {
                var selected =
                    try workspaceRuntime(self, a, task_id, try wp.identity(ref, .runtime), null);
                defer selected.deinit();
                const text = try json.canonical(
                    a,
                    try workspaceRuntimeObservation(self, a, selected.record.value),
                );
                defer a.free(text);
                return .{ .observation = try wp.page(a, text, request.page) };
            }
            const id = try wp.identity(ref, .program);
            var program_value = try self.workspaceProgram(a, task_id, id);
            defer program_value.deinit();
            const observed =
                try workspaceProgramObservation(self, a, id, program_value.value.description);
            const text = try json.canonical(a, observed);
            defer a.free(text);
            return .{ .observation = try wp.page(a, text, request.page) };
        }
        fn workspaceExecuteWork(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            basis: ?workspace.ReadObservation,
            observers: Observers.ObserverScope,
            work_command: wc.Work,
        ) !WorkspaceExecution {
            switch (work_command) {
                .inspect => |request| return executeWorkInspect(
                    self,
                    a,
                    task_id,
                    basis,
                    observers,
                    request,
                ),
                .collect => |request| return executeWorkCollect(
                    self,
                    a,
                    task_id,
                    basis,
                    observers,
                    request,
                ),
                .wait => |request| return executeWorkWait(
                    self,
                    a,
                    task_id,
                    basis,
                    observers,
                    request,
                ),
                else => return executeWorkMutation(
                    self,
                    a,
                    operation_id,
                    task_id,
                    authorized,
                    work_command,
                ),
            }
        }
        fn executeWorkMutation(
            self: *Self,
            a: std.mem.Allocator,
            op_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            work_command: wc.Work,
        ) !WorkspaceExecution {
            switch (work_command) {
                .stop_observing => |selection| return .{
                    .admitted = try self.workspaceStopObserving(a, op_id, task_id, selection),
                },
                .observe => |selection| return .{ .admitted = try self.workspaceObserve(
                    a,
                    op_id,
                    task_id,
                    selection,
                ) },

                .start => |request| return executeWorkStart(self, a, op_id, task_id, request),
                .pump => |request| return .{
                    .admitted = try self.workspacePump(a, op_id, task_id, request),
                },
                .realize => |request| return .{
                    .admitted = try self.workspaceRealize(a, op_id, task_id, request),
                },
                .realize_controller => |request| return .{
                    .admitted = try self.workspaceRealizeController(a, op_id, task_id, request),
                },
                .guard => |request| return .{ .admitted = try self.workspaceGuard(
                    a,
                    op_id,
                    task_id,
                    .{ .guard = request },
                ) },
                .unguard => |request| return .{ .admitted = try self.workspaceGuard(
                    a,
                    op_id,
                    task_id,
                    .{ .unguard = request },
                ) },
                .request_cut => |request| return .{
                    .admitted = try self.workspaceRequestCut(a, op_id, task_id, request),
                },
                .advance, .park, .delegate, .cancel => return executeWorkControl(
                    self,
                    a,
                    op_id,
                    task_id,
                    authorized,
                    work_command,
                ),
                .interact => |request| return .{
                    .admitted = try self.workspaceInteract(a, op_id, task_id, request),
                },
                .inspect, .collect, .wait => unreachable,
            }
        }
        fn executeWorkStart(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            request: @FieldType(wc.Work, "start"),
        ) !WorkspaceExecution {
            const program_id = try wp.identity(request.program, .program);
            var program = try self.workspaceProgram(a, task_id, program_id);
            defer program.deinit();
            const artifact = program.value.description;
            const schema = try store(self).object(a, artifact.input_schema, null);
            defer a.free(schema);
            var origin: ?state.Reference = null;
            const input = switch (request.input) {
                .inline_json => |inline_json| blk: {
                    if (!std.meta.eql(
                        try wp.identity(inline_json.schema, .schema),
                        artifact.input_schema.digest,
                    )) return error.SchemaMismatch;
                    const text = inline_json.json_text.bytes;
                    var parsed = try json.parse(a, text, .{
                        .bytes = text.len,
                        .depth = text.len,
                        .tokens = text.len,
                        .members = text.len,
                    });
                    defer parsed.deinit();
                    break :blk try @import("../dynamic_values.zig").encode(a, schema, parsed.value);
                },
                .reference => |ref| blk: {
                    const value = try workspaceValueReference(self, a, task_id, ref);
                    if (!std.meta.eql(value.schema, artifact.input_schema))
                        return error.SchemaMismatch;
                    origin = value.artifact;
                    break :blk try store(self).object(a, value.value, null);
                },
            };
            defer a.free(input);
            const selected: ?state.Reference = if (request.runtime == .selected) blk: {
                var selected = try workspaceRuntime(
                    self,
                    a,
                    task_id,
                    try wp.identity(request.runtime.selected, .runtime),
                    program_id,
                );
                defer selected.deinit();
                break :blk selected.record.value.artifact;
            } else null;
            return .{
                .admitted = try workspaceStartAdmitted(
                    self,
                    a,
                    operation_id,
                    task_id,
                    program_id,
                    input,
                    request.policy,
                    origin,
                    null,
                    selected,
                    request.trial,
                    null,
                    null,
                ),
            };
        }
        fn executeWorkInspect(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            observers: Observers.ObserverScope,
            request: @FieldType(wc.Work, "inspect"),
        ) !WorkspaceExecution {
            if (request.work.kind == .residual) {
                if (basis) |frozen| return .{
                    .observation = try controllerResidualObservation(
                        self,
                        a,
                        frozen.residual.value,
                    ),
                };
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    try wp.identity(request.work, .residual),
                    task_id,
                );
                defer residual.deinit();
                return .{
                    .observation = try controllerResidualObservation(
                        self,
                        a,
                        .from(residual.value),
                    ),
                };
            }
            if (basis) |frozen| return .{
                .observation = try renderWorkspaceWorkObservationIn(
                    self,
                    a,
                    frozen.works.works.items[0].?.work,
                    frozen.works.works.items[0].?.occurrence,
                    frozen.works.event_watermark,
                    try observers.at(task_id, frozen.works.event_watermark),
                ),
            };
            var value =
                try self.workspaceWork(a, task_id, try wp.identity(request.work, .work));
            defer value.deinit();
            return .{ .observation = try workspaceWorkObservation(self, a, value.value) };
        }
        fn executeWorkCollect(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            observers: Observers.ObserverScope,
            request: @FieldType(wc.Work, "collect"),
        ) !WorkspaceExecution {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            var result: json.Value = .{ .array = .init(a) };
            for (request.works.items, 0..) |ref, i| {
                if (basis) |frozen| {
                    const item = frozen.works.works.items[i];
                    if (item) |observed| {
                        try result.array.append(
                            try renderWorkspaceWorkObservationIn(
                                self,
                                a,
                                observed.work,
                                observed.occurrence,
                                frozen.works.event_watermark,
                                try observers.at(task_id, frozen.works.event_watermark),
                            ),
                        );
                    } else {
                        var missing = json.object();
                        try json.put(a, &missing, "work", try values.toJson(wc.Ref, a, ref));
                        try json.put(a, &missing, "outcome", json.string("unavailable"));
                        try result.array.append(missing);
                    }
                    continue;
                }
                var value =
                    self.workspaceWork(a, task_id, try wp.identity(ref, .work)) catch |err| {
                        if (err != error.ArtifactUnavailable) return err;
                        var missing = json.object();
                        try json.put(a, &missing, "work", try values.toJson(wc.Ref, a, ref));
                        try json.put(a, &missing, "outcome", json.string("unavailable"));
                        try result.array.append(missing);
                        continue;
                    };
                defer value.deinit();
                try result.array.append(
                    try workspaceWorkObservationIn(
                        self,
                        a,
                        value.value,
                        parent.value.event_high,
                        try observers.at(task_id, parent.value.event_high),
                    ),
                );
            }
            return .{ .observation = result };
        }
        fn executeWorkWait(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            observers: Observers.ObserverScope,
            request: @FieldType(wc.Work, "wait"),
        ) !WorkspaceExecution {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            var result = json.object();
            const interrupted = if (basis) |frozen|
                frozen.wait.interrupted
            else
                parent.value.messages.items.len != 0 or parent.value.cancellation != null;
            var ready = interrupted;
            var selected: json.Value = .{ .array = .init(a) };
            for (request.works.items, 0..) |ref, i| {
                if (basis) |frozen| {
                    const observed = frozen.wait.works.items[i].?;
                    ready = ready or
                        observed.work.event_watermark > request.after or
                        observed.work.terminal();
                    try selected.array.append(
                        try renderWorkspaceWorkObservationIn(
                            self,
                            a,
                            observed.work,
                            observed.occurrence,
                            frozen.wait.event_watermark,
                            try observers.at(task_id, frozen.wait.event_watermark),
                        ),
                    );
                } else {
                    var work =
                        try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
                    defer work.deinit();
                    ready = ready or
                        work.value.event_watermark > request.after or
                        work.value.terminal();
                    try selected.array.append(
                        try workspaceWorkObservationIn(
                            self,
                            a,
                            work.value,
                            parent.value.event_high,
                            try observers.at(task_id, parent.value.event_high),
                        ),
                    );
                }
            }
            try json.put(a, &result, "ready", .{ .bool = ready });
            try json.put(a, &result, "interrupted", .{ .bool = interrupted });
            try json.put(
                a,
                &result,
                "event_watermark",
                try json.number(
                    a,
                    if (basis) |frozen|
                        frozen.wait.event_watermark
                    else
                        parent.value.event_high,
                ),
            );
            try json.put(a, &result, "works", selected);
            return .{ .observation = result };
        }
        fn workspaceExecuteContext(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            basis: ?workspace.ReadObservation,
            context: wc.Context,
        ) !WorkspaceExecution {
            switch (context) {
                .inspect => |request| return executeContextInspect(
                    self,
                    a,
                    task_id,
                    basis,
                    request,
                ),
                .expand => |request| return executeContextExpand(self, a, task_id, basis, request),
                .materialize, .select => return .{
                    .admitted = try workspaceContextMutation(
                        self,
                        a,
                        operation_id,
                        task_id,
                        context,
                        authorized.snapshot,
                        authorized.input,
                    ),
                },
            }
        }
        fn executeContextInspect(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            request: @FieldType(wc.Context, "inspect"),
        ) !WorkspaceExecution {
            var output = try wp.Range.init(a, request.page);
            defer output.deinit(a);
            try output.append("[");
            if (basis) |frozen| {
                const ids = try workspaceScopeAt(self, a, task_id, frozen.scope);
                defer a.free(ids);
                for (ids) |id| try appendWorkspaceReference(&output, id);
            } else {
                var query = try store(self).database.prepare(
                    "SELECT id FROM records WHERE task=? AND kind='wo" ++
                        "rkspace_work' OR" ++
                        "DER BY id",
                    &.{.{ .blob = &task_id }},
                );
                defer query.deinit();
                while (try query.step() == .row) {
                    const id = try query.bytes(0);
                    if (id.len != 32) return error.CorruptState;
                    try appendWorkspaceReference(&output, id[0..32].*);
                }
            }
            try output.append("]");
            return .{ .observation = try output.finish(a) };
        }
        fn executeContextExpand(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            request: @FieldType(wc.Context, "expand"),
        ) !WorkspaceExecution {
            if (request.reference.kind == .port)
                return expandWorkspacePort(self, a, task_id, request);
            if (request.reference.kind == .work)
                return expandWorkspaceFailure(self, a, task_id, basis, request);
            if (request.reference.kind == .view) {
                return .{
                    .observation = try workspaceViewObservation(
                        self,
                        a,
                        task_id,
                        try wp.identity(request.reference, .view),
                        request.page,
                    ),
                };
            }
            if (request.reference.kind == .provenance or request.reference.kind == .schema)
                return expandWorkspaceDescriptor(self, a, task_id, request);

            if (request.reference.kind == .source) {
                return .{
                    .observation = try workspaceSourcePage(
                        self,
                        a,
                        task_id,
                        request.reference,
                        request.page,
                    ),
                };
            }
            const value = try workspaceValueReference(self, a, task_id, request.reference);
            const schema = try store(self).object(a, value.schema, null);
            defer a.free(schema);
            const bytes = try store(self).object(a, value.value, null);
            defer a.free(bytes);
            return .{
                .observation = try @import("../dynamic_values.zig").page(
                    a,
                    schema,
                    bytes,
                    request.page,
                ),
            };
        }
        fn describeControllerContract(self: *Self, a: std.mem.Allocator) ![]u8 {
            const contract = try self.controllerContract(a);
            defer {
                a.free(contract.result.bytes);
                a.free(contract.failure.bytes);
                for (contract.imports.items) |item|
                    if (item.native_result != null) a.free(item.result.bytes);
                a.free(contract.imports.items);
            }
            return try json.canonical(
                a,
                try values.toJson(contracts.controller.Contract, a, contract),
            );
        }
        fn describeCurrentController(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
        ) ![]u8 {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const id =
                (if (basis) |frozen| frozen.controller.binding else parent.value.controller) orelse
                return error.UnavailableDescription;
            const binding = try controllerBinding(self, a, parent.value, id);
            var artifact = try self.workspaceProgram(a, task_id, binding.program);
            defer artifact.deinit();
            var observation = try workspaceProgramObservation(
                self,
                a,
                binding.program,
                artifact.value.description,
            );
            try json.put(
                a,
                &observation,
                "binding",
                try values.toJson(state.ControllerBinding, a, binding),
            );
            try describeControllerRevision(a, &observation, parent.value, basis);
            var residuals: json.Value = .{ .array = .init(a) };
            const residual_ids =
                if (basis) |frozen|
                    frozen.controller.residuals.items
                else
                    try controllerResidualIds(self, a, task_id);
            defer if (basis == null) a.free(residual_ids);
            for (residual_ids) |residual_id| try residuals.array.append(
                try values.toJson(wc.Ref, a, try wp.reference(a, .residual, residual_id)),
            );
            try json.put(a, &observation, "residuals", residuals);
            return try json.canonical(a, observation);
        }
        fn describeComponents(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
        ) ![]u8 {
            const ref = authorized.catalog orelse
                return error.UnavailableDescription;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try workspaceSnapshotAccess(parent.value, ref);
            const bytes = try store(self).object(a, ref, null);
            defer a.free(bytes);
            return try construction.describeComponents(a, bytes);
        }
        fn describeWorkspaceValues(a: std.mem.Allocator) ![]u8 {
            return a.dupe(
                u8,
                "Runtime values use JSON arrays for products and " ++
                    "sequences, {\"ta" ++
                    "g\":ordinal,\"value\":payload} for sums, {} for " ++
                    "unit, booleans, " ++
                    "exact decimal strings for 64-bit integers, UTF-8" ++
                    " strings for tex" ++
                    "t, and base64url strings for bytes. Supply the a" ++
                    "ctual program in" ++
                    "put schema reference. Program source uses the se" ++
                    "parately describ" ++
                    "ed Horos record transport.",
            );
        }
        fn describeWorkspaceBindings(a: std.mem.Allocator) ![]u8 {
            return a.dupe(
                u8,
                "Pure source records require no environmental ada" ++
                    "pter. No effect " ++
                    "request grants authority. Workspace observations" ++
                    " and input ports" ++
                    " do not restrict the controller's next action.",
            );
        }
        fn describeWorkspaceRuntimes(a: std.mem.Allocator) ![]u8 {
            return a.dupe(
                u8,
                "The packaged generic Horos evaluator is the defa" ++
                    "ult. program.spe" ++
                    "cialize derives a checked realization for an adm" ++
                    "itted program. w" ++
                    "ork.start may select its task-owned runtime refe" ++
                    "rence; work.real" ++
                    "ize switches at a guest cut without changing gue" ++
                    "st execution rev" ++
                    "ision. work.request_cut publishes a guest or out" ++
                    "er checkpoint. R" ++
                    "untime artifacts never grant environmental autho" ++
                    "rity; active or " ++
                    "unknown delivery blocks a switch.",
            );
        }
        fn describeControllerRevision(
            a: std.mem.Allocator,
            observation: *json.Value,
            parent: state.Task,
            basis: ?workspace.ReadObservation,
        ) !void {
            const epoch =
                if (basis) |frozen|
                    frozen.controller.epoch
                else
                    parent.controller_epoch;
            try json.put(a, observation, "controller_epoch", try json.number(a, epoch));
            try json.put(
                a,
                observation,
                "execution_revision",
                try json.number(
                    a,
                    if (basis) |frozen|
                        frozen.controller.execution_revision
                    else
                        parent.execution_revision,
                ),
            );
            try json.put(
                a,
                observation,
                "realization_revision",
                try json.number(
                    a,
                    if (basis) |frozen|
                        frozen.controller.realization_revision
                    else
                        parent.realization_revision,
                ),
            );
            try json.put(
                a,
                observation,
                "selected_runtime",
                try values.toJson(
                    ?state.Reference,
                    a,
                    if (basis) |frozen|
                        frozen.controller.runtime
                    else
                        parent.controller_runtime,
                ),
            );
        }
        fn workspaceBuildFailure(
            a: std.mem.Allocator,
            err: anyerror,
            diagnostic: construction.Diagnostic,
        ) !WorkspaceExecution {
            var failure = json.object();
            try json.put(a, &failure, "error", json.string(@errorName(err)));
            try json.put(a, &failure, "phase", json.string(@tagName(diagnostic.phase)));
            try json.put(
                a,
                &failure,
                "function",
                try values.toJson(
                    @TypeOf(diagnostic.source.function),
                    a,
                    diagnostic.source.function,
                ),
            );
            try json.put(
                a,
                &failure,
                "term",
                try values.toJson(@TypeOf(diagnostic.source.term), a, diagnostic.source.term),
            );
            try json.put(
                a,
                &failure,
                "value",
                try values.toJson(@TypeOf(diagnostic.source.value), a, diagnostic.source.value),
            );
            if (diagnostic.source.continuation orelse
                diagnostic.source.target.continuation) |detail|
                try json.put(
                    a,
                    &failure,
                    "continuation_contract",
                    try values.toJson(build_job.ContinuationDiagnostic, a, .{
                        .domain = if (diagnostic.source.continuation != null) .source else .target,
                        .detail = detail,
                        .block = diagnostic.source.target.block,
                        .schema = diagnostic.source.target.schema,
                    }),
                );
            return .{ .observation = failure };
        }
        fn executeWorkControl(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            work_command: wc.Work,
        ) !WorkspaceExecution {
            if (work_command == .delegate and work_command.delegate.interpretation != .none)
                return .{
                    .admitted = try workspaceDelegate(self, a, operation_id, task_id, authorized),
                };
            const expected = switch (work_command) {
                .advance, .park => |v| v,
                .delegate => |v| v.expected,
                .cancel => |v| v.expected,
                else => unreachable,
            };
            const control: workspace.Command = switch (work_command) {
                .advance => .advance,
                .park => .park,
                .delegate => |v| .{ .delegate = v.policy },
                .cancel => |v| .{ .cancel = .{ .bytes = v.reason.bytes } },
                else => unreachable,
            };
            if (expected.work.kind == .residual) return .{
                .admitted = try controllerResidualControl(
                    self,
                    a,
                    operation_id,
                    task_id,
                    try wp.identity(expected.work, .residual),
                    expected.execution_revision,
                    expected.control_revision,
                    control,
                ),
            };
            const admitted = try self.workspaceControl(
                a,
                operation_id,
                task_id,
                try wp.identity(expected.work, .work),
                expected.execution_revision,
                expected.control_revision,
                control,
            );
            return .{ .admitted = admitted };
        }
        fn expandWorkspacePort(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            request: @FieldType(wc.Context, "expand"),
        ) !WorkspaceExecution {
            const id = try wp.identity(request.reference, .port);
            var port = try record(self, workspace.Port, a, "workspace_port", id, task_id);
            defer port.deinit();
            if (!std.meta.eql(port.value.id, id) or !std.meta.eql(port.value.task, task_id))
                return error.CorruptState;
            return .{
                .observation = try workspacePayloadPage(
                    self,
                    a,
                    port.value.interface.payload,
                    port.value.payload,
                    request.page,
                ),
            };
        }
        fn expandWorkspaceFailure(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            basis: ?workspace.ReadObservation,
            request: @FieldType(wc.Context, "expand"),
        ) !WorkspaceExecution {
            if (basis) |frozen| {
                const work = frozen.works.works.items[0].?.work;
                const bytes = try store(self).object(a, work.outcome, null);
                defer a.free(bytes);
                var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                defer outcome.deinit();
                if (outcome.value != .failed) return error.InvalidState;
                var program = try self.workspaceProgram(a, task_id, work.program);
                defer program.deinit();
                return .{
                    .observation = try workspacePayloadBytesPage(
                        self,
                        a,
                        program.value.description.failure_schema,
                        outcome.value.failed.value,
                        request.page,
                    ),
                };
            }
            var work = try retainedWorkspaceWork(
                self,
                a,
                task_id,
                try wp.identity(request.reference, .work),
            );
            defer work.deinit();
            const bytes = try store(self).object(a, work.value.outcome, null);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            if (outcome.value != .failed) return error.InvalidState;
            var program = try self.workspaceProgram(a, task_id, work.value.program);
            defer program.deinit();
            return .{
                .observation = try workspacePayloadBytesPage(
                    self,
                    a,
                    program.value.description.failure_schema,
                    outcome.value.failed.value,
                    request.page,
                ),
            };
        }
        fn expandWorkspaceDescriptor(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            request: @FieldType(wc.Context, "expand"),
        ) !WorkspaceExecution {
            const reference =
                try workspaceOwnedDescriptor(self, a, task_id, request.reference);
            const bytes = try store(self).object(a, reference, null);
            defer a.free(bytes);
            if (request.reference.kind == .provenance) {
                var derivation = try contracts.decodeOwned(workspace.Derivation, a, bytes);
                defer derivation.deinit();
                return .{
                    .observation = try workspaceDerivationPage(
                        self,
                        a,
                        derivation.value,
                        request.page,
                    ),
                };
            }
            const text = try json.canonical(a, try wp.schema(a, bytes));
            defer a.free(text);
            return .{ .observation = try wp.page(a, text, request.page) };
        }
        fn workspaceAdmissionObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            admitted: Admission,
        ) !json.Value {
            const receipt_value = admitted.receipt;
            if (!std.meta.eql(receipt_value.task, task_id)) return error.Denied;
            const bytes = try store(self).object(
                a,
                receipt_value.workspace_observation orelse return error.CorruptState,
                null,
            );
            defer a.free(bytes);
            var observation =
                switch (receipt_value.workspace_kind orelse return error.CorruptState) {
                    .controller => try admittedControllerObservation(
                        a,
                        task_id,
                        receipt_value,
                        bytes,
                    ),

                    .residual => try admittedResidualObservation(
                        self,
                        a,
                        task_id,
                        receipt_value,
                        bytes,
                    ),
                    .candidate => try admittedCandidateObservation(self, a, task_id, bytes),
                    .runtime => try admittedRuntimeObservation(
                        self,
                        a,
                        task_id,
                        receipt_value,
                        bytes,
                    ),

                    .program => try admittedProgramObservation(self, a, receipt_value, bytes),
                    .work => try admittedWorkObservation(self, a, task_id, bytes),
                    .value => try workspaceValueObservation(
                        self,
                        a,
                        task_id,
                        receipt_value.workspace.?,
                    ),
                    .view => try workspaceViewObservation(
                        self,
                        a,
                        task_id,
                        receipt_value.workspace.?,
                        .{},
                    ),
                    else => return error.CorruptState,
                };
            try json.put(a, &observation, "replayed", .{ .bool = admitted.replayed });
            try json.put(
                a,
                &observation,
                "receipt_revision",
                try json.number(a, receipt_value.revision),
            );
            return observation;
        }
        fn admittedControllerObservation(
            a: std.mem.Allocator,
            task_id: state.TaskId,
            receipt_value: state.Receipt,
            bytes: []const u8,
        ) !json.Value {
            if (!std.meta.eql(receipt_value.workspace.?, rootIdentity(task_id)))
                return error.InvalidArchive;
            var fact = try contracts.decodeOwned(workspace.ControllerRealization, a, bytes);
            defer fact.deinit();
            return try values.toJson(workspace.ControllerRealization, a, fact.value);
        }
        fn admittedResidualObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            receipt_value: state.Receipt,
            bytes: []const u8,
        ) !json.Value {
            var residual = try contracts.decodeOwned(state.ControllerResidual, a, bytes);
            defer residual.deinit();
            if (!std.meta.eql(residual.value.task, task_id) or !std.meta.eql(
                residual.value.id,
                receipt_value.workspace.?,
            )) return error.InvalidArchive;
            return try controllerResidualObservation(self, a, .from(residual.value));
        }
        fn admittedCandidateObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            bytes: []const u8,
        ) !json.Value {
            var selected = try contracts.decodeOwned(workspace.SemanticObservation, a, bytes);
            defer selected.deinit();
            return try workspaceSemanticObservation(self, a, task_id, selected.value);
        }
        fn admittedRuntimeObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            receipt_value: state.Receipt,
            bytes: []const u8,
        ) !json.Value {
            var selected = try contracts.decodeOwned(workspace.Runtime, a, bytes);
            defer selected.deinit();
            if (!std.meta.eql(selected.value.task, task_id) or !std.meta.eql(
                selected.value.artifact.digest,
                receipt_value.workspace.?,
            )) return error.CorruptState;
            return try workspaceRuntimeObservation(self, a, selected.value);
        }
        fn admittedProgramObservation(
            self: *Self,
            a: std.mem.Allocator,
            receipt_value: state.Receipt,
            bytes: []const u8,
        ) !json.Value {
            var artifact = try contracts.decodeOwned(workspace.ProgramArtifact, a, bytes);
            defer artifact.deinit();
            return try workspaceProgramObservation(
                self,
                a,
                receipt_value.workspace.?,
                artifact.value,
            );
        }
        fn admittedWorkObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            bytes: []const u8,
        ) !json.Value {
            var value = try contracts.decodeOwned(workspace.WorkObservation, a, bytes);
            defer value.deinit();
            if (!std.meta.eql(value.value.work.task, task_id)) return error.Denied;
            if (self.workspace_replay) |replay_only| {
                var parent = try self.task(a, task_id);
                defer parent.deinit();
                try validateWorkspaceWorkSnapshotIn(
                    self,
                    parent.value,
                    value.value,
                    replay_only.records,
                    replay_only.checked,
                );
                try validateHistoricalOccurrence(self, a, value.value);
                return try renderWorkspaceWorkObservationIn(
                    self,
                    a,
                    value.value.work,
                    value.value.occurrence,
                    value.value.work.event_watermark,
                    .{
                        .historical = try replay_only.checked.observer_successors.histories.get(
                            task_id,
                            value.value.work.event_watermark,
                        ),
                    },
                );
            }
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (value.value.work.event_watermark == parent.value.event_high) {
                var observers =
                    Observers.CurrentObservers.init(a, task_id, parent.value.event_high);
                defer observers.deinit();
                return try renderWorkspaceWorkObservationIn(
                    self,
                    a,
                    value.value.work,
                    value.value.occurrence,
                    parent.value.event_high,
                    .{ .current = &observers },
                );
            }
            return try renderWorkspaceWorkObservation(
                self,
                a,
                value.value.work,
                value.value.occurrence,
                value.value.work.event_watermark,
            );
        }
    };
}
