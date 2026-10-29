const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const GuardOperation = task_types.GuardOperation;
const SelectedRuntime = task_types.SelectedRuntime;
const Step = task_types.Step;
const Work = task_types.Work;
const operation = task_types.operation;
const same = task_types.same;

var guest_segment_proofs: @import("../guest_segment_proofs.zig") = .{};

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const blockControllerRequest = Succession.blockControllerRequest;
        const blockedOccurrence = Root.blockedOccurrence;
        const capsuleDependencies = Realization.capsuleDependencies;
        const compatible = Controller.compatible;
        const controllerOffer = ControllerProtocol.controllerOffer;
        const dispatch = Worker.dispatch;
        const effectSchedule = Root.effectSchedule;
        const guestSegmentFact = GuestValidation.guestSegmentFact;
        const guestSegmentKey = GuestValidation.guestSegmentKey;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const interpretCapture = Worker.interpretCapture;
        const observerAdvanceAllowed = Observers.observerAdvanceAllowed;
        const observerGuestQuantum = Observers.observerGuestQuantum;
        const parkWorkspaceOnClose = control_ops.parkWorkspaceOnClose;
        const persist = Records.persist;
        const projectionBinding = Worker.projectionBinding;
        const publicationSchedule = Access.publicationSchedule;
        const pumpObserver = Observers.pumpObserver;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const requireRuntimePolicy = Observations.requireRuntimePolicy;
        const retainObservedOuter = Observers.retainObservedOuter;
        const retire = Lifecycle.retire;
        const runtimeProvenance = Guards.runtimeProvenance;
        const runtimeWork = Programs.runtimeWork;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const subjectRemove = Scheduling.subjectRemove;
        const validatePublishedCapsuleTrace = Realization.validatePublishedCapsuleTrace;
        const workspaceCommit = publication_ops.workspaceCommit;
        const workspaceGuardAdvance = Guards.workspaceGuardAdvance;
        const workspaceMaterializeSnapshot = Inspection.workspaceMaterializeSnapshot;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspacePublishValue = Inspection.workspacePublishValue;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const writeWorkspaceWork = publication_ops.writeWorkspaceWork;
        const ControllerProtocol = @import("controller_protocol.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Succession = @import("controller_succession.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const control_ops = @import("workspace_control.zig").Operations(Types, Self);
        const Guards = @import("workspace_guards.zig").Operations(Types, Self);
        const GuestValidation = @import("workspace_guest_validation.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Interaction = @import("workspace_interaction.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const publication_ops = @import("workspace_publication.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        fn workspaceTracePublication(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            trace: kosmos.RuntimeInstrumentation.Output,
        ) !workspace.RuntimeTrace {
            const driver = self.active.?.driver;
            const capsule =
                try driver.publishCapsule(a, .outer_execution, runtimeProvenance(value));
            defer capsule.deinit();
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            _ = try store(self).putObject(code);
            return .{
                .output = trace,
                .capsule = try store(self).putObject(capsule.bytes()),
                .dependencies = .{ .items = try capsuleDependencies(a, capsule.bytes()) },
            };
        }
        fn workspacePublishRequestedPort(
            self: *Self,
            a: std.mem.Allocator,
            value: *workspace.Work,
            program: workspace.Program,
            request: data.invocation.Request,
            next: occurrence.Occurrence,
        ) !void {
            for (program.description.ports.items) |port| {
                if (!same(port.identity.bytes, request.binding.semantic_identity)) continue;
                if (!std.meta.eql(
                    storage.digest(request.binding.resume_schema),
                    port.command.digest,
                ) or
                    !std.meta.eql(
                        storage.digest(request.binding.payload_schema),
                        port.payload.digest,
                    )) return error.CorruptState;
                var port_id: state.Digest = undefined;
                try self.io.randomSecure(&port_id);
                value.port_generation = try std.math.add(u64, value.port_generation, 1);
                const exposed: workspace.Port = .{
                    .id = port_id,
                    .task = value.task,
                    .work = value.id,
                    .program = program.artifact,
                    .occurrence = next.id,
                    .request = next.request_object,
                    .request_identity = next.request,
                    .generation = value.port_generation,
                    .interface = port,
                    .payload = try store(self).putObject(request.binding.payload),
                };
                try store(self).createRecord(
                    workspace.Port,
                    "workspace_port",
                    port_id,
                    value.task,
                    exposed,
                );
                value.current_port = try snapshotRecord(
                    self,
                    workspace.Port,
                    a,
                    "workspace_port",
                    port_id,
                    value.task,
                );
                break;
            }
        }
        fn workspaceRequestedPublication(
            self: *Self,
            a: std.mem.Allocator,
            value: *workspace.Work,
            pending: anytype,
        ) !void {
            var request = try data.invocation.decode(data.invocation.Request, a, pending.request);
            defer request.deinit();
            var id: state.Digest = undefined;
            try self.io.randomSecure(&id);
            const next: occurrence.Occurrence = .{
                .id = id,
                .task = value.task,
                .work = value.id,
                .request = request.value.request_identity,
                .request_object = try store(self).putObject(pending.request),
            };
            try store(self).createRecord(occurrence.Occurrence, "occurrence", id, value.task, next);
            value.current_occurrence = id;
            if (value.delegation != null) {
                if (value.instrument_occurrence != null) return error.CorruptState;
                value.instrument_occurrence = id;
            }
            value.outcome_kind = .requested;
            var program = try self.workspaceProgram(a, value.task, value.program);
            defer program.deinit();
            try workspacePublishRequestedPort(self, a, value, program.value, request.value, next);
            try store(self).createRecord(
                workspace.ExecutionRoute,
                "execution_route",
                id,
                value.task,
                .{
                    .id = id,
                    .task = value.task,
                    .work = value.id,
                    .image = program.value.description.image,
                    .program_identity = request.value.binding.program_identity,
                    .port = value.current_port,
                    .delegation = value.delegation,
                },
            );
        }
        pub fn workspacePublication(
            self: *Self,
            a: std.mem.Allocator,
            value: *workspace.Work,
            publication: evaluator.Driver.Publication,
        ) !void {
            value.guest_work = publication.guest_work;
            if (value.blocker == .observation_blocked) value.blocker = null;
            value.runtime_capsule = null;
            value.runtime_trace = null;
            value.outer_operation = null;
            value.runtime_dependencies = .{ .items = &.{} };
            var outcome =
                try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer outcome.deinit();
            value.checkpoint = try store(self).putObject(publication.checkpoint);
            if (publication.trace) |trace| {
                value.runtime_trace = workspaceTracePublication(self, a, value.*, trace) catch
                    return error.InstrumentationPublicationBlocked;
            }
            errdefer if (value.runtime_trace) |trace| a.free(trace.dependencies.items);
            value.outcome = try store(self).putObject(publication.outcome);
            value.schedule = .parked;
            switch (outcome.value) {
                .progressed => value.outcome_kind = .progressed,
                .yielded => value.outcome_kind = .yielded,
                .completed => |bytes| {
                    value.outcome_kind = .completed;
                    if (value.observer) |*observer| observer.consumed_revision =
                        observer.source_revision;
                    value.result = try store(self).putObject(bytes);
                    var program = try self.workspaceProgram(a, value.task, value.program);
                    defer program.deinit();
                    if (value.delegation == null) value.result_value =
                        try workspaceResultValue(self, a, value.*, program.value);
                },
                .failed => {
                    value.outcome_kind = .failed;
                },
                .cancelled => {
                    value.outcome_kind = .cancelled;
                },
                .requested => |pending| {
                    try workspaceRequestedPublication(self, a, value, pending);
                },
                .needs_capacity => return error.Capacity,
            }
            // No unbound external request is dispatched. A run policy grants
            // continued computation, never the authority to invent an answer.
            value.schedule = publicationSchedule(workspace.ControlObservation.from(.{
                .work = value.*,
                .occurrence = null,
            }));
            if (publication.segment) |segment|
                guest_segment_proofs.retain(
                    try guestSegmentKey(try guestSegmentFact(segment, value.*)),
                );
        }
        fn workspaceRestoreCapsule(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            pending: anytype,
            image: []const u8,
            runtime: anytype,
        ) !*evaluator.Driver {
            try validatePublishedCapsuleTrace(
                self,
                a,
                value,
                pending.capsule,
                value.runtime,
                null,
                pending,
            );
            const bytes = try store(self).object(a, pending.capsule, null);
            defer a.free(bytes);
            const Owner = struct {
                work: workspace.Work,
                reference: state.Reference,
                fn claim(
                    context: *anyopaque,
                    ref: kosmos.RuntimeCapsule.Reference,
                    record_value: kosmos.RuntimeCapsule.Record,
                    _: kosmos.RuntimeCapsule.Reference,
                ) !void {
                    const owner: *@This() = @ptrCast(@alignCast(context));
                    if (!std.meta.eql(ref.digest, owner.reference.digest) or
                        ref.bytes != owner.reference.bytes or
                        !std.meta.eql(
                            record_value.provenance,
                            runtimeProvenance(owner.work),
                        )) return error.InvalidArchive;
                }
            };
            // The task's immutable publication and current exclusive native
            // namespace ownership authorize this one resident installation.
            var owner: Owner = .{ .work = value, .reference = pending.capsule };
            return evaluator.Driver.openCapsule(
                self.allocator,
                image,
                runtime,
                bytes,
                .{
                    .context = &owner,
                    .claim = Owner.claim,
                },
            );
        }
        pub fn workspaceResident(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
        ) !*evaluator.Driver {
            if (self.active) |active| {
                if (std.meta.eql(active.task, value.task) and active.subject == .work and
                    std.meta.eql(active.subject.work, value.id) and
                    active.execution_revision == value.execution_revision and
                    active.realization_revision == value.realization_revision and
                    std.meta.eql(
                        active.outer_operation,
                        if (value.outer_operation) |pending| @as(
                            ?state.Reference,
                            pending.capsule,
                        ) else null,
                    )) return active.driver;
                try retire(self, a);
            }
            var artifact = try self.workspaceProgram(a, value.task, value.program);
            defer artifact.deinit();
            const image =
                try store(self).object(a, artifact.value.description.image, null);
            defer a.free(image);
            const checkpoint = try store(self).object(a, value.checkpoint, null);
            defer a.free(checkpoint);
            var selected: ?SelectedRuntime = if (value.runtime) |ref| try workspaceRuntime(
                self,
                a,
                value.task,
                ref.digest,
                value.program,
            ) else null;
            defer if (selected) |*item| item.deinit();
            if (selected) |item| if (!std.meta.eql(value.runtime.?, item.record.value.artifact))
                return error.InvalidRuntime;
            var packaged = try self.program.retainRuntime();
            defer packaged.deinit();
            const driver = if (value.outer_operation) |pending| restored: {
                break :restored try workspaceRestoreCapsule(
                    self,
                    a,
                    value,
                    pending,
                    image,
                    if (selected) |*item| &item.admitted else &packaged,
                );
            } else try evaluator.Driver.openSelected(
                self.allocator,
                image,
                .{ .state = checkpoint },
                if (selected) |*item| &item.admitted else &packaged,
            );
            self.active = .{
                .task = value.task,
                .subject = .{ .work = value.id },
                .execution_revision = value.execution_revision,
                .realization_revision = value.realization_revision,
                .outer_operation = if (value.outer_operation) |pending| pending.capsule else null,
                .driver = driver,
            };
            return driver;
        }
        fn workspaceResultValue(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            program: workspace.Program,
        ) !state.Reference {
            const derivation = try workspaceResultDerivation(self, a, value, program);
            defer a.free(derivation.sources.items);
            return workspacePublishValue(
                self,
                a,
                value.task,
                program.description.result_schema,
                value.result.?,
                derivation,
            );
        }
        pub fn workspaceResultDerivation(
            _: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            program: workspace.Program,
        ) !workspace.Derivation {
            const source_value = value.input_value orelse return error.CorruptState;
            const antecedents = try a.alloc(state.Reference, value.inputs.items.len + 1);
            antecedents[0] = source_value;
            @memcpy(antecedents[1..], value.inputs.items);
            return .{
                .kind = if (value.trial != null) .trial else .computation,
                .sources = .{ .items = antecedents },
                .program = program.artifact,
                .work = value.id,
            };
        }
        fn workspaceInstrumentSnapshotAnswer(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            delegation: workspace.Delegation,
            port: workspace.Port,
            answer: []const u8,
        ) !state.Reference {
            const snapshot = delegation.snapshot orelse return error.CorruptState;
            const selected = delegation.selection.snapshot;
            const ref = try workspaceMaterializeSnapshot(
                self,
                a,
                parent,
                snapshot,
                .{
                    .path = selected.path,
                    .offset = selected.offset,
                    .maximum = selected.maximum,
                },
            );
            const acquired = try workspaceValueReference(
                self,
                a,
                parent.id,
                try wp.reference(a, .value, ref.digest),
            );
            if (!std.meta.eql(acquired.schema, port.interface.argument) or
                !std.meta.eql(acquired.value, state.Reference{
                    .digest = storage.digest(answer),
                    .bytes = answer.len,
                })) return error.CorruptState;
            return ref;
        }
        fn workspaceInstrumentModelAnswer(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            child: workspace.Work,
            delegation: workspace.Delegation,
            delegation_ref: state.Reference,
            port: workspace.Port,
            answer: []const u8,
        ) !state.Reference {
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                child.instrument_occurrence orelse return error.CorruptState,
                parent.id,
            );
            defer pending.deinit();
            if (pending.value.state != .admitted or pending.value.state.admitted != .reply)
                return error.CorruptState;
            var capture_value = try record(
                self,
                state.Capture,
                a,
                "capture",
                pending.value.state.admitted.reply.attempt,
                parent.id,
            );
            defer capture_value.deinit();
            return try workspacePublishValue(
                self,
                a,
                parent.id,
                port.interface.argument,
                try store(self).putObject(answer),
                .{
                    .kind = .judgment,
                    .sources = delegation.inputs,
                    .work = child.id,
                    .delegation = delegation_ref,
                    .capture = capture_value.value.response orelse return error.CorruptState,
                },
            );
        }
        fn workspaceInstrumentAnswer(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            child: workspace.Work,
        ) !?state.Reference {
            var output = try contracts.decodeOwned(
                instrument.Output,
                a,
                try store(self).object(a, child.result orelse return error.CorruptState, null),
            );
            defer output.deinit();
            if (output.value != .answer) return null;
            const delegation_ref = child.delegation orelse return error.CorruptState;
            var admitted = try contracts.decodeOwned(
                workspace.Delegation,
                a,
                try store(self).object(a, delegation_ref, null),
            );
            defer admitted.deinit();
            const delegation = admitted.value;
            if (!std.meta.eql(delegation.instrument, child.id) or
                !std.meta.eql(delegation.task, parent.id))
                return error.CorruptState;
            var port = try contracts.decodeOwned(
                workspace.Port,
                a,
                try store(self).object(a, delegation.port, null),
            );
            defer port.deinit();
            const schema = try store(self).object(a, port.value.interface.argument, null);
            var descriptor = try data.schema.decode(a, schema);
            defer descriptor.deinit();
            try data.schema.validateValue(a, descriptor.descriptor, output.value.answer.bytes);
            if (delegation.selection == .snapshot)
                return try workspaceInstrumentSnapshotAnswer(
                    self,
                    a,
                    parent,
                    delegation,
                    port.value,
                    output.value.answer.bytes,
                );
            if (delegation.selection != .model) return error.CorruptState;
            return try workspaceInstrumentModelAnswer(
                self,
                a,
                parent,
                child,
                delegation,
                delegation_ref,
                port.value,
                output.value.answer.bytes,
            );
        }
        fn workspaceApplyAnswer(self: *Self, a: std.mem.Allocator, child: workspace.Work) !void {
            var parent = try self.task(a, child.task);
            defer parent.deinit();
            if (!try delegationCurrent(self, a, parent.value, child)) return;
            var admitted = try contracts.decodeOwned(
                workspace.Delegation,
                a,
                try store(self).object(a, child.delegation.?, null),
            );
            defer admitted.deinit();
            var target = try self.workspaceWork(a, child.task, admitted.value.work);
            defer target.deinit();
            var port = try contracts.decodeOwned(
                workspace.Port,
                a,
                try store(self).object(a, admitted.value.port, null),
            );
            defer port.deinit();
            const operation_id = try std.fmt.allocPrint(a, "delegation-{s}", .{
                std.fmt.bytesToHex(admitted.value.id, .lower),
            });
            defer a.free(operation_id);
            _ = try self.workspaceInteract(
                a,
                operation_id,
                child.task,
                .{ .expected = .{
                    .work = try wp.reference(a, .work, target.value.id),
                    .execution_revision = target.value.execution_revision,
                    .control_revision = target.value.control_revision,
                }, .port = try wp.reference(
                    a,
                    .port,
                    port.value.id,
                ), .generation = port.value.generation, .command = .{ .resume_value = .{
                    .reference = try wp.reference(a, .value, child.answer_value.?.digest),
                } } },
            );
        }
        pub fn delegationCurrent(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            child: workspace.Work,
        ) !bool {
            if (parent.terminal() or parent.cancellation != null) return false;
            const ref = child.delegation orelse return false;
            var delegation = try contracts.decodeOwned(
                workspace.Delegation,
                a,
                try store(self).object(a, ref, null),
            );
            defer delegation.deinit();
            const admitted = delegation.value;
            if (!std.meta.eql(admitted.task, parent.id) or
                !std.meta.eql(admitted.instrument, child.id))
                return error.CorruptState;
            if (!try hasLocalCustody(self, a, parent.id, admitted.work)) return false;
            var target = try self.workspaceWork(a, parent.id, admitted.work);
            defer target.deinit();
            return target.value.cancellation == null and
                !target.value.terminal() and
                target.value.control_revision == admitted.control_revision and
                std.meta.eql(target.value.current_port, admitted.port);
        }
        fn controllerTrialResponse(
            self: *Self,
            a: std.mem.Allocator,
            trial: workspace.Trial,
            request: data.invocation.Request,
        ) ![]u8 {
            for (trial.responses.items) |item| {
                if (!same(item.identity.bytes, request.binding.semantic_identity)) continue;
                var payload = try contracts.decodeOwned(
                    workspace.ValueArtifact,
                    a,
                    try store(self).object(a, item.payload, null),
                );
                defer payload.deinit();
                if (!std.meta.eql(
                    payload.value.schema.digest,
                    storage.digest(request.binding.payload_schema),
                ) or !std.meta.eql(
                    payload.value.value.digest,
                    storage.digest(request.binding.payload),
                )) continue;
                var response = try contracts.decodeOwned(
                    workspace.ValueArtifact,
                    a,
                    try store(self).object(a, item.response, null),
                );
                defer response.deinit();
                if (!std.meta.eql(
                    response.value.schema.digest,
                    storage.digest(request.binding.resume_schema),
                )) return error.SchemaMismatch;
                return store(self).object(a, response.value.value, null);
            }
            return error.ObservationUnavailable;
        }
        pub fn controllerTrialReply(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            request: data.invocation.Request,
        ) ![]u8 {
            var trial = try record(
                self,
                workspace.Trial,
                a,
                "workspace_trial",
                work.trial orelse return error.InvalidControllerTrial,
                work.task,
            );
            defer trial.deinit();
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            const descriptor = program.value.description.controller orelse
                return error.InvalidControllerTrial;
            const c = contracts.controller;
            if (same(request.binding.semantic_identity, c.boot_identity)) {
                const input = try store(self).object(a, work.input, null);
                defer a.free(input);
                if (!same(input, request.binding.payload)) return error.InvalidControllerTrial;
                return a.dupe(u8, &.{});
            }
            if (same(request.binding.semantic_identity, c.offer_identity)) {
                var parent = try self.task(a, work.task);
                defer parent.deinit();
                var binding = projectionBinding(self, parent.value);
                binding.execution = request.binding.program_identity;
                binding.trial = .{ .work = work.id, .view = trial.value.view };
                return controllerOffer(self, a, binding, request.binding.payload);
            }
            if (same(request.binding.semantic_identity, c.handoff_identity)) {
                const model = for (descriptor.imports.items) |item| {
                    if (item.import == .deliberate) break item;
                } else return error.InvalidControllerTrial;
                var schema = try data.schema.decode(a, model.payload.bytes);
                defer schema.deinit();
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const facts =
                    try data.admission.schemas(arena.allocator(), schema.descriptor.types);
                var reader: data.wire.Reader = .{ .input = request.binding.payload };
                _ = try data.admission.readValue(
                    arena.allocator(),
                    schema.descriptor.types,
                    facts,
                    schema.descriptor.root,
                    &reader,
                );
                return std.mem.concat(a, u8, &.{ request.binding.payload[reader.position..], &.{
                    0,
                } });
            }
            return controllerTrialResponse(self, a, trial.value, request);
        }
        pub fn controllerTrialAllowsLive(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            request: data.invocation.Request,
        ) !bool {
            if (!same(
                request.binding.semantic_identity,
                contracts.controller.effect_prefix ++ "deliberate",
            )) return false;
            const entry = for (self.handlers.entries) |item| {
                if (item.declaration.controller_import == .deliberate) break item;
            } else return false;
            if (entry.declaration.kind != .leaf or !entry.declaration.inference) return false;
            var trial = try record(
                self,
                workspace.Trial,
                a,
                "workspace_trial",
                work.trial orelse return error.InvalidControllerTrial,
                work.task,
            );
            defer trial.deinit();
            return trial.value.selection == .synthetic and
                trial.value.selection.synthetic.live_inference;
        }
        fn settleControllerTrial(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work: workspace.Work,
            pending: occurrence.Occurrence,
        ) !Step {
            const request_bytes = try store(self).object(a, pending.request_object, null);
            defer a.free(request_bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            const payload = controllerTrialReply(self, a, work, request.value) catch |err| {
                if (err == error.ObservationUnavailable) {
                    if (try controllerTrialAllowsLive(self, a, work, request.value))
                        return dispatch(self, a, parent, pending);
                    return blockedOccurrence(self, a, parent, pending, .unavailable_environment);
                }
                return blockControllerRequest(self, a, parent, pending, err);
            };
            defer a.free(payload);
            var schema = try data.schema.decode(a, request.value.binding.resume_schema);
            defer schema.deinit();
            data.schema.validateValue(a, schema.descriptor, payload) catch |err|
                return blockControllerRequest(self, a, parent, pending, err);
            const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = payload,
            });
            defer a.free(reply);
            const binding: occurrence.Binding = .{
                .id = pending.id,
                .task = parent.id,
                .work = work.id,
                .request = pending.request,
            };
            const dispatched = try occurrence.dispatch(pending, binding, pending.id, false, false);
            const acquired =
                try occurrence.acquired(dispatched, binding, pending.id, storage.digest(reply));
            var value = parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(reply);
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                parent.id,
                acquired,
            );
            try effectSchedule(self, a, &value, acquired, .queued, null);
            try persist(self, a, value, parent.revision, "controller.trial-reply", .preserve);
            return .progressed;
        }
        fn parkControllerTrialReply(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
        ) !Step {
            var value = initial;
            value.schedule = .parked;
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try store(self).begin();
            defer store(self).rollback();
            try writeWorkspaceWork(self, &value, .replace);
            _ = try workspaceCommit(
                self,
                a,
                parent,
                null,
                @splat(0),
                value.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, value.task),
                null,
            );
            return .progressed;
        }
        fn pumpWorkspaceDelivery(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            pending: occurrence.Occurrence,
        ) !?Step {
            if (pending.state == .captured)
                return try interpretCapture(self, a, parent, pending);
            if (pending.state == .ready and value.trial != null)
                return try settleControllerTrial(self, a, parent, value, pending);
            if (pending.state == .ready and value.delegation != null) {
                if (!try delegationCurrent(self, a, parent, value))
                    return try blockedOccurrence(self, a, parent, pending, .denied);
                return try dispatch(self, a, parent, pending);
            }
            if (pending.state == .unknown or pending.state == .not_sent)
                return try blockedOccurrence(self, a, parent, pending, .unavailable_environment);
            return null;
        }
        fn pumpWorkspaceOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            id: state.Digest,
        ) !Step {
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, value.task);
            defer pending.deinit();
            if (value.cancellation != null and !value.cancellation_applied and
                (pending.value.state == .ready or pending.value.state == .awaiting or
                    pending.value.state == .not_sent))
            {
                _ = try workspaceAdvance(
                    self,
                    a,
                    parent,
                    value,
                    .{ .cancel = .{ .text = value.cancellation.?.bytes } },
                    null,
                    @splat(0),
                    null,
                );
                return .progressed;
            }
            if (try pumpWorkspaceDelivery(
                self,
                a,
                parent,
                value,
                pending.value,
            )) |step| return step;
            if (pending.value.state != .settled_reply) return .idle;
            if (value.trial != null and
                value.policy.continuation == .explicit_only and value.cancellation == null)
                return parkControllerTrialReply(self, a, parent, value);
            const reply =
                try store(self).acquiredObject(a, pending.value.state.settled_reply.reply, null);
            defer a.free(reply);
            _ = try workspaceAdvance(
                self,
                a,
                parent,
                value,
                .{ .reply = reply },
                null,
                @splat(0),
                null,
            );
            return .progressed;
        }
        pub fn pumpWorkspace(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !Step {
            requireCustody(self, a, task_id, work_id) catch |err| {
                if (err != error.CustodyNotLocal) return err;
                subjectRemove(self, .{ .task = task_id, .work = work_id });
                return .idle;
            };
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            const subject: workspace.Subject = .{ .task = task_id, .work = work_id };
            if (saved.value.outcome_kind == .completed and saved.value.observer != null)
                return pumpObserver(self, a, saved.value);
            if (saved.value.terminal() and saved.value.answer_value != null) {
                // Completion and delivery are distinct durable transitions.
                // The retained answer plus its current delegation is the
                // pending transfer, including after explicit task resume.
                try workspaceApplyAnswer(self, a, saved.value);
                subjectRemove(self, subject);
                return .progressed;
            }
            if (saved.value.terminal() or saved.value.schedule == .parked) {
                subjectRemove(self, subject);
                return .progressed;
            }
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if ((parent.value.cancellation != null or parent.value.terminal()) and
                saved.value.cancellation == null)
            {
                try parkWorkspaceOnClose(self, a, task_id, work_id);
                subjectRemove(self, subject);
                return .progressed;
            }
            if (saved.value.outer_operation != null) {
                _ = try workspacePumpWork(
                    self,
                    a,
                    parent.value,
                    saved.value,
                    65536,
                    null,
                    @splat(0),
                    null,
                );
                return .progressed;
            }
            if (saved.value.current_occurrence) |id| {
                return pumpWorkspaceOccurrence(self, a, parent.value, saved.value, id);
            }
            _ = try workspaceAdvance(
                self,
                a,
                parent.value,
                saved.value,
                workspaceContinuation(saved.value),
                null,
                @splat(0),
                null,
            );
            return .progressed;
        }
        pub fn workspaceContinuation(value: workspace.Work) data.invocation.Control {
            if (value.cancellation != null and !value.cancellation_applied) return .{ .cancel = .{
                .text = value.cancellation.?.bytes,
            } };
            return if (value.outcome_kind == .yielded) .resume_yield else .none;
        }
        pub fn workspaceRunnable(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            child: workspace.Work,
        ) !bool {
            if (!try hasLocalCustody(self, a, parent.id, child.id)) return false;
            if (!child.terminal()) return child.schedule != .parked;
            if (child.observer) |observer| {
                if (child.outcome_kind == .completed and !observer.stopped and
                    observer.selection.policy.continuation == .owner_scheduled and
                    !workspaceParentStopped(self, parent))
                    return observer.successor == null;
            }
            return child.answer_value != null and try delegationCurrent(self, a, parent, child);
        }
        pub fn workspacePump(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "pump"),
        ) !Admission {
            if (command.base_quantum == 0 or command.base_quantum > 1048576)
                return error.InvalidParams;
            const request =
                try operation(workspace.PumpRequest, a, .{
                    .task = task_id,
                    .command = command,
                });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            var work = try runtimeWork(self, a, task_id, command.expected);
            defer work.deinit();
            if (work.value.terminal()) return error.InvalidState;
            if (workspaceParentStopped(self, parent.value) and
                work.value.cancellation == null) return error.InvalidState;
            if (try queueControllerTrial(
                self,
                a,
                parent.value,
                work.value,
                operation_id,
                request,
                .{
                    .pump = command,
                },
            )) |admitted| return admitted;
            work.value.control_revision = try std.math.add(u64, work.value.control_revision, 1);
            return workspacePumpWork(
                self,
                a,
                parent.value,
                work.value,
                command.base_quantum,
                operation_id,
                request,
                .{ .pump = command },
            );
        }
        pub fn trialControlReady(value: workspace.ControlObservation) bool {
            return value.trial and
                !value.port and
                (value.cancellation == null or value.cancellation_applied) and
                (value.delivery == .ready or value.delivery == .not_sent);
        }
        pub fn queueControllerTrial(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            operation_id: []const u8,
            request: state.Digest,
            command: workspace.PublicationCommand,
        ) !?Admission {
            if (initial.trial == null or initial.outer_operation != null) return null;
            const id = initial.current_occurrence orelse return null;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, parent.id);
            defer pending.deinit();
            if (!trialControlReady(workspace.ControlObservation.from(.{
                .work = initial,
                .occurrence = pending.value,
            }))) return null;
            try requireCustody(self, a, parent.id, initial.id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            var value = initial;
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            value.schedule = .queued;
            value.blocker = null;
            try store(self).begin();
            defer store(self).rollback();
            if (pending.value.state == .not_sent) try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                id,
                parent.id,
                try occurrence.rearm(pending.value, .{
                    .id = id,
                    .task = parent.id,
                    .work = value.id,
                    .request = pending.value.request,
                }),
            );
            try writeWorkspaceWork(self, &value, .replace);
            const admitted = try workspaceCommit(
                self,
                a,
                parent,
                operation_id,
                request,
                value.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, parent.id),
                command,
            );
            return admitted;
        }
        fn workspacePumpQuantum(
            self: *Self,
            a: std.mem.Allocator,
            initial: workspace.Work,
            control: *data.invocation.Control,
            reply_bytes: *?[]u8,
        ) !u64 {
            return if (initial.outer_operation) |pending|
                pending.guest_quantum
            else blk: {
                if (initial.current_occurrence) |id| {
                    var occurrence_value =
                        try record(self, occurrence.Occurrence, a, "occurrence", id, initial.task);
                    defer occurrence_value.deinit();
                    if (occurrence_value.value.state == .settled_reply) {
                        reply_bytes.* = try store(self).acquiredObject(
                            a,
                            occurrence_value.value.state.settled_reply.reply,
                            null,
                        );
                        control.* = .{ .reply = reply_bytes.*.? };
                    } else if (control.* != .cancel or
                        (occurrence_value.value.state != .ready and
                            occurrence_value.value.state != .awaiting and
                            occurrence_value.value.state != .not_sent))
                        return error.WaitingInput;
                }
                break :blk @as(
                    u64,
                    if (control.* == .reply and initial.cancellation != null and
                        !initial.cancellation_applied) 0 else try observerGuestQuantum(
                        self,
                        a,
                        initial,
                    ),
                );
            };
        }
        fn workspaceSuspendPump(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            driver: *evaluator.Driver,
            control_bytes: ?[]const u8,
            guest_quantum: u64,
            elapsed: u64,
            operation_id: ?[]const u8,
            request: state.Digest,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            const capsule = try driver.retainCapsule(runtimeProvenance(initial));
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(code);
            var value = initial;
            value.outer_operation = .{
                .capsule = try store(self).putObject(capsule),
                .dependencies = .{ .items = try capsuleDependencies(a, capsule) },
                .control = if (initial.outer_operation) |pending|
                    pending.control
                else
                    try store(self).putObject(control_bytes.?),
                .guest_quantum = guest_quantum,
            };
            defer a.free(value.outer_operation.?.dependencies.items);
            value.runtime_capsule = null;
            value.runtime_dependencies = .{ .items = &.{} };
            value.native_publication_nanoseconds +|= elapsed;
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            value.schedule = if (value.cancellation != null or
                value.policy.continuation == .owner_scheduled) .queued else .parked;
            try writeWorkspaceWork(self, &value, .replace);
            const admitted = try workspaceCommit(
                self,
                a,
                parent,
                operation_id,
                request,
                value.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, value.task),
                command,
            );
            self.active.?.outer_operation = value.outer_operation.?.capsule;
            return admitted;
        }
        fn workspacePumpDriver(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            driver: *evaluator.Driver,
            control: data.invocation.Control,
            control_bytes: ?[]const u8,
            guest_quantum: u64,
            base_quantum: u64,
            native_started: anytype,
            operation_value: GuardOperation,
        ) !Admission {
            errdefer store(self).fence();
            var progress = try driver.pump(base_quantum);
            defer progress.deinit();
            const elapsed = std.math.cast(
                u64,
                @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds),
            ) orelse std.math.maxInt(u64);
            if (progress == .event and progress.event.value == .cut) {
                // The operation already applied its control. Publish the cut
                // with a read-only zero-quantum observation, never another reply.
                var publication = try driver.drive(a, .none, 0);
                defer a.free(publication.outcome);
                publication.guest_work = progress.event.value.cut.guest_work;
                return workspaceFinish(
                    self,
                    a,
                    parent,
                    initial,
                    control,
                    publication,
                    elapsed,
                    operation_value.operation_id,
                    operation_value.request,
                    operation_value.command,
                );
            }
            if (progress != .suspended) return error.InvalidRuntimeProgress;
            return workspaceSuspendPump(
                self,
                a,
                parent,
                initial,
                driver,
                control_bytes,
                guest_quantum,
                elapsed,
                operation_value.operation_id,
                operation_value.request,
                operation_value.command,
            );
        }
        pub fn workspacePumpWork(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            base_quantum: u64,
            operation_id: ?[]const u8,
            request: state.Digest,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            if (initial.cancellation == null)
                try requireRuntimePolicy(self, a, initial.task, initial.runtime);
            try requireCustody(self, a, initial.task, initial.id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            var control = workspaceContinuation(initial);
            var decoded: ?contracts.Decoded(data.invocation.Control) = null;
            defer if (decoded) |*value| value.deinit();
            var control_bytes: ?[]u8 = null;
            defer if (control_bytes) |bytes| a.free(bytes);
            var reply_bytes: ?[]u8 = null;
            defer if (reply_bytes) |bytes| a.free(bytes);
            const native_started = std.Io.Clock.awake.now(self.io);
            const guest_quantum =
                try workspacePumpQuantum(self, a, initial, &control, &reply_bytes);
            try observerAdvanceAllowed(self, a, initial);
            if (initial.guard != null and initial.cancellation == null)
                return workspaceGuardAdvance(
                    self,
                    a,
                    parent,
                    initial,
                    control,
                    try observerGuestQuantum(self, a, initial),
                    base_quantum,
                    operation_id,
                    request,
                    command,
                );
            const driver = try workspaceResident(self, a, initial);
            if (initial.outer_operation) |pending| {
                const bytes = try store(self).object(a, pending.control, null);
                defer a.free(bytes);
                decoded = try contracts.decodeOwned(data.invocation.Control, a, bytes);
                control = decoded.?.value;
            } else {
                control_bytes = try contracts.encodeOwned(data.invocation.Control, a, control);
                _ = try workspaceConsumed(self, a, initial, control);
                try driver.beginAdvance(control, guest_quantum);
            }
            return workspacePumpDriver(
                self,
                a,
                parent,
                initial,
                driver,
                control,
                control_bytes,
                guest_quantum,
                base_quantum,
                native_started,
                .{
                    .operation_id = operation_id,
                    .request = request,
                    .command = command,
                },
            );
        }
        pub fn workspaceConsumed(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            control: data.invocation.Control,
        ) !?occurrence.Occurrence {
            if (control == .cancel or control == .reply) if (work.current_occurrence) |id| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, work.task);
                defer pending.deinit();
                return try occurrence.consumed(
                    pending.value,
                    .{
                        .id = id,
                        .task = work.task,
                        .work = work.id,
                        .request = pending.value.request,
                    },
                    if (control == .cancel) .cancel else .{
                        .reply = storage.digest(control.reply),
                    },
                    work.cancellation != null,
                );
            };
            return null;
        }
        pub fn workspaceAdvance(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: data.invocation.Control,
            operation_id: ?[]const u8,
            request: state.Digest,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            if (initial.cancellation == null)
                try requireRuntimePolicy(self, a, initial.task, initial.runtime);
            try requireCustody(self, a, initial.task, initial.id);
            try observerAdvanceAllowed(self, a, initial);
            if (initial.guard != null and initial.cancellation == null)
                return workspaceGuardAdvance(
                    self,
                    a,
                    parent,
                    initial,
                    control,
                    try observerGuestQuantum(self, a, initial),
                    65536,
                    operation_id,
                    request,
                    command,
                );
            if (initial.outer_operation != null) return workspacePumpWork(
                self,
                a,
                parent,
                initial,
                65536,
                operation_id,
                request,
                command,
            );
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const driver = try workspaceResident(self, a, initial);
            _ = try workspaceConsumed(self, a, initial, control);
            const native_started = std.Io.Clock.awake.now(self.io);
            const publication = try driver.drive(
                a,
                control,
                if (control == .reply and initial.cancellation != null and
                    !initial.cancellation_applied) 0 else try observerGuestQuantum(
                    self,
                    a,
                    initial,
                ),
            );
            defer a.free(publication.outcome);
            errdefer store(self).fence();
            const elapsed = std.math.cast(
                u64,
                @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds),
            ) orelse std.math.maxInt(u64);
            return workspaceFinish(
                self,
                a,
                parent,
                initial,
                control,
                publication,
                elapsed,
                operation_id,
                request,
                command,
            );
        }
        pub fn workspaceFinish(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: data.invocation.Control,
            publication: evaluator.Driver.Publication,
            elapsed: u64,
            operation_id: ?[]const u8,
            request: state.Digest,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            const consumed = try workspaceConsumed(self, a, initial, control);
            var value = initial;
            if (value.cancellation != null) value.guard = null;
            value.native_publication_nanoseconds +|= elapsed;
            if (control == .cancel) value.cancellation_applied = true;
            if (consumed != null) {
                value.current_occurrence = null;
                value.current_port = null;
            }
            value.execution_revision = try std.math.add(u64, value.execution_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try store(self).begin();
            defer store(self).rollback();
            if (consumed) |prior| try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                prior.id,
                value.task,
                prior,
            );
            try workspacePublication(self, a, &value, publication);
            defer if (value.runtime_trace) |trace| a.free(trace.dependencies.items);
            if (parent.observers_present) try retainObservedOuter(self, a, &value);
            defer if (value.runtime_capsule != null) a.free(value.runtime_dependencies.items);
            if (value.outcome_kind == .completed and value.delegation != null) {
                value.answer_value = try workspaceInstrumentAnswer(self, a, parent, value);
                if (value.answer_value) |answer| {
                    const sources = try a.alloc(state.Reference, value.inputs.items.len + 1);
                    @memcpy(sources[0..value.inputs.items.len], value.inputs.items);
                    sources[value.inputs.items.len] = answer;
                    value.inputs = .{ .items = sources };
                }
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                value.result_value = try workspaceResultValue(self, a, value, program.value);
            }
            try writeWorkspaceWork(self, &value, .replace);
            const admitted = try workspaceCommit(
                self,
                a,
                parent,
                operation_id,
                request,
                value.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, value.task),
                command,
            );
            self.active.?.execution_revision = value.execution_revision;
            self.active.?.outer_operation = null;
            return admitted;
        }
    };
}
