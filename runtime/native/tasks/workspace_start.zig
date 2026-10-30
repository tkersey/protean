const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const SelectedRuntime = task_types.SelectedRuntime;
const StartDelegation = task_types.StartDelegation;
const Work = task_types.Work;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const compatible = Controller.compatible;
        const controllerView = Context.controllerView;
        const createCustody = Lifecycle.createCustody;
        const freeControllerViewWorks = Context.freeControllerViewWorks;
        const observerHeadIndex = Observers.observerHeadIndex;
        const observerHeadsAfter = Observers.observerHeadsAfter;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const requireSemanticPolicy = Observations.requireSemanticPolicy;
        const retire = Lifecycle.retire;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const subjectRemove = Scheduling.subjectRemove;
        const workspaceCommitRelated = publication_ops.workspaceCommitRelated;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspacePublication = Execution.workspacePublication;
        const workspacePublishValue = Inspection.workspacePublishValue;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const writeWorkspaceWork = publication_ops.writeWorkspaceWork;
        const Context = @import("controller_context.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const publication_ops = @import("workspace_publication.zig").Operations(Types, Self);
        pub fn workspaceStart(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
            input: []const u8,
            policy: workspace.RunPolicy,
        ) !Admission {
            return workspaceStartValue(
                self,
                a,
                operation_id,
                task_id,
                program_id,
                input,
                policy,
                null,
            );
        }
        fn workspaceStartValue(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
            input: []const u8,
            policy: workspace.RunPolicy,
            origin: ?state.Reference,
        ) !Admission {
            return workspaceStartAdmitted(
                self,
                a,
                operation_id,
                task_id,
                program_id,
                input,
                policy,
                origin,
                null,
                null,
                .{ .none = .{} },
                null,
                null,
            );
        }
        const WorkspaceStartAdmission = workspaceStartAdmissionType();
        fn workspaceStartAdmissionType() type {
            return struct {
                operation_id: []const u8,
                task_id: state.TaskId,
                program_id: state.Digest,
                input: []const u8,
                policy: workspace.RunPolicy,
                origin: ?state.Reference,
                delegated: ?StartDelegation,
                runtime: ?state.Reference,
                trial: wc.Trial,
                preparation: ?state.ControllerSuccession,
                observer: ?workspace.Observer,
            };
        }
        pub fn workspaceStartAdmitted(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
            input: []const u8,
            policy: workspace.RunPolicy,
            origin: ?state.Reference,
            delegated: ?StartDelegation,
            runtime: ?state.Reference,
            trial: wc.Trial,
            preparation: ?state.ControllerSuccession,
            observer: ?workspace.Observer,
        ) !Admission {
            return workspaceStartPrepared(self, a, .{
                .operation_id = operation_id,
                .task_id = task_id,
                .program_id = program_id,
                .input = input,
                .policy = policy,
                .origin = origin,
                .delegated = delegated,
                .runtime = runtime,
                .trial = trial,
                .preparation = preparation,
                .observer = observer,
            });
        }
        fn validateWorkspaceStartInput(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            artifact: workspace.Program,
        ) !void {
            const kind = artifact.description.source_kind;
            if ((artifact.description.controller != null) != (start.trial != .none) or
                (start.trial != .none and start.delegated != null))
                return error.ControllerTrialRequired;
            if ((kind == .instrument_model or
                kind == .instrument_snapshot) != (start.delegated != null))
                return error.InvalidDelegation;
            const schema =
                try store(self).object(a, artifact.description.input_schema, null);
            defer a.free(schema);
            var descriptor = try data.schema.decode(a, schema);
            defer descriptor.deinit();
            try data.schema.validateValue(a, descriptor.descriptor, start.input);
            if (start.trial != .none and (start.input.len < start.task_id.len or !same(
                start.input[0..start.task_id.len],
                &start.task_id,
            ))) return error.InvalidControllerTrial;
        }
        fn workspaceStartResponses(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            responses: []std.meta.Elem(
                @FieldType(@FieldType(workspace.Trial, "responses"), "items"),
            ),
        ) !void {
            const selected_responses = if (start.trial == .synthetic)
                start.trial.synthetic.responses.items
            else
                &.{};
            for (selected_responses, responses, 0..) |item, *out, i| {
                const payload =
                    try workspaceValueReference(self, a, start.task_id, item.payload);
                const response =
                    try workspaceValueReference(self, a, start.task_id, item.response);
                for (responses[0..i]) |prior| {
                    if (!same(item.identity.bytes, prior.identity.bytes)) continue;
                    var prior_payload = try contracts.decodeOwned(
                        workspace.ValueArtifact,
                        a,
                        try store(self).object(a, prior.payload, null),
                    );
                    defer prior_payload.deinit();
                    if (std.meta.eql(payload.schema, prior_payload.value.schema) and std.meta.eql(
                        payload.value,
                        prior_payload.value.value,
                    )) return error.AmbiguousTrialResponse;
                }
                out.* = .{
                    .identity = item.identity,
                    .payload = payload.artifact,
                    .response = response.artifact,
                };
            }
        }
        fn workspaceStartDriver(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            id: state.Digest,
            image: []const u8,
        ) !*evaluator.Driver {
            var selected: ?SelectedRuntime = if (start.runtime) |ref| try workspaceRuntime(
                self,
                a,
                start.task_id,
                ref.digest,
                start.program_id,
            ) else null;
            defer if (selected) |*value| value.deinit();
            if (selected) |value| {
                if (!std.meta.eql(start.runtime.?, value.record.value.artifact))
                    return error.InvalidRuntime;
                try requireSemanticPolicy(
                    self,
                    kosmos.RuntimeCompiler.approvedRootIdentity(&value.admitted),
                    kosmos.RuntimeCompiler.checker_identity,
                );
            }
            var packaged = try self.program.retainRuntime();
            defer packaged.deinit();
            const driver = try evaluator.Driver.openSelected(
                self.allocator,
                image,
                .{ .initial_args = start.input },
                if (selected) |*value| &value.admitted else &packaged,
            );
            self.active = .{
                .task = start.task_id,
                .subject = .{ .work = id },
                .execution_revision = 0,
                .driver = driver,
            };
            return driver;
        }
        fn workspaceStartDelegation(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            parent: state.Task,
        ) !?state.Reference {
            var delegation_ref: ?state.Reference = null;
            if (start.delegated) |bound| {
                const record_value = bound.record;
                var target = try self.workspaceWork(a, start.task_id, record_value.work);
                defer target.deinit();
                if (target.value.control_revision + 1 != record_value.control_revision or
                    !std.meta.eql(target.value.current_port, record_value.port) or
                    target.value.cancellation != null) return error.StaleRevision;
                target.value.control_revision = record_value.control_revision;
                target.value.policy = bound.policy;
                target.value.event_watermark = parent.event_high + 1;
                target.value.schedule = .parked;
                try writeWorkspaceWork(self, &target.value, .replace);
                try store(self).createRecord(
                    workspace.Delegation,
                    "workspace_delegation",
                    record_value.id,
                    start.task_id,
                    record_value,
                );
                delegation_ref = try snapshotRecord(
                    self,
                    workspace.Delegation,
                    a,
                    "workspace_delegation",
                    record_value.id,
                    start.task_id,
                );
            }
            return delegation_ref;
        }
        fn workspaceStartTrial(
            self: *Self,
            start: WorkspaceStartAdmission,
            parent: state.Task,
            id: state.Digest,
            trial_view: anytype,
            responses: anytype,
        ) !?state.Digest {
            return if (trial_view) |view| blk: {
                try store(self).createRecord(
                    workspace.Trial,
                    "workspace_trial",
                    id,
                    start.task_id,
                    .{
                        .id = id,
                        .task = start.task_id,
                        .selection = start.trial,
                        .view = try store(self).putObject(view.bytes),
                        .view_works = .{ .items = view.works },
                        .policy = parent.profile,
                        .responses = .{ .items = responses },
                    },
                );
                break :blk id;
            } else null;
        }
        fn workspaceStartTrialInputs(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            trial_ref: ?state.Digest,
            saved: *workspace.Work,
        ) !void {
            if (trial_ref) |trial_id| {
                var binding =
                    try record(self, workspace.Trial, a, "workspace_trial", trial_id, task_id);
                defer binding.deinit();
                const inputs = try a.alloc(state.Reference, binding.value.responses.items.len * 2);
                for (binding.value.responses.items, 0..) |response, i| {
                    inputs[i * 2] = response.payload;
                    inputs[i * 2 + 1] = response.response;
                }
                saved.inputs.items = inputs;
            }
        }
        fn workspaceStartRelated(
            self: *Self,
            start: WorkspaceStartAdmission,
            parent: state.Task,
            predecessor: ?*workspace.Work,
            id: state.Digest,
        ) !void {
            if (predecessor) |prior| {
                prior.*.observer.?.successor = id;
                prior.*.control_revision = try std.math.add(u64, prior.*.control_revision, 1);
                prior.*.event_watermark = try std.math.add(u64, parent.event_high, 1);
                try writeWorkspaceWork(self, &prior.*, .replace);
            }
            if (start.preparation) |initial| {
                var prepared = initial;
                if (!std.meta.eql(parent.controller_succession, prepared.id) or
                    prepared.conversion_work != null or prepared.phase != .preparing)
                    return error.StaleController;
                prepared.conversion_work = id;
                try store(self).putRecord(
                    state.ControllerSuccession,
                    "controller_succession",
                    prepared.id,
                    start.task_id,
                    prepared,
                );
            }
        }
        fn workspaceCommitStartedWork(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            initial_parent: state.Task,
            predecessor: ?*workspace.Work,
            heads: ?[]state.Digest,
            saved: workspace.Work,
            request: state.Digest,
        ) !Admission {
            var parent = initial_parent;
            const id = saved.id;
            if (heads) |items| {
                parent.observers_present = true;
                parent.observer_heads.items = items;
            }
            const admitted = try workspaceCommitRelated(
                self,
                a,
                parent,
                start.operation_id,
                request,
                id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", id, start.task_id),
                if (start.delegated) |bound|
                    bound.record.work
                else if (predecessor) |prior|
                    prior.*.id
                else
                    null,
                if (start.delegated) |bound| .{ .delegate = bound.command } else .{ .start = .{
                    .policy = start.policy,
                    .origin = start.origin != null,
                    .runtime = start.runtime,
                    .trial = start.trial,
                    .observer = start.observer,
                } },
            );
            if (predecessor) |prior| subjectRemove(self, .{
                .task = start.task_id,
                .work = prior.*.id,
            });
            self.active.?.execution_revision = saved.execution_revision;
            return admitted;
        }
        fn workspaceInitialWork(
            self: *Self,
            start: WorkspaceStartAdmission,
            parent: state.Task,
            id: state.Digest,
            trial_ref: ?state.Digest,
            delegation_ref: ?state.Reference,
            native_ns: u64,
        ) !workspace.Work {
            return .{
                .observer = start.observer,
                .id = id,
                .task = start.task_id,
                .trial = trial_ref,
                .program = start.program_id,
                .runtime = start.runtime,
                .delegation = delegation_ref,
                .origin_work = if (start.delegated) |bound| bound.record.work else null,
                .input = try store(self).putObject(start.input),
                .checkpoint = undefined,
                .outcome = undefined,
                .outcome_kind = .progressed,
                .execution_revision = 1,
                .native_publication_nanoseconds = native_ns,
                .control_revision = 1,
                .schedule = .parked,
                .policy = start.policy,
                .event_watermark = parent.event_high + 1,
            };
        }
        fn workspaceCreateStartedWork(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            initial_parent: state.Task,
            artifact: workspace.Program,
            predecessor: ?*workspace.Work,
            heads: ?[]state.Digest,
            id: state.Digest,
            trial_view: anytype,
            responses: anytype,
            publication: evaluator.Driver.Publication,
            native_ns: u64,
            request: state.Digest,
        ) !Admission {
            const parent = initial_parent;
            try store(self).begin();
            defer store(self).rollback();
            const delegation_ref = try workspaceStartDelegation(self, a, start, parent);
            const trial_ref =
                try workspaceStartTrial(self, start, parent, id, trial_view, responses);
            var saved = try workspaceInitialWork(
                self,
                start,
                parent,
                id,
                trial_ref,
                delegation_ref,
                native_ns,
            );
            try workspaceStartTrialInputs(self, a, start.task_id, trial_ref, &saved);
            defer if (trial_ref != null) a.free(saved.inputs.items);
            const observer_inputs = if (start.observer) |bound|
                &[_]state.Reference{ bound.source, bound.accumulator }
            else
                &.{};
            if (start.observer != null) saved.inputs = .{ .items = observer_inputs };
            saved.input_value = start.origin orelse try workspacePublishValue(
                self,
                a,
                start.task_id,
                artifact.description.input_schema,
                saved.input,
                .{
                    .kind = if (start.observer != null) .judgment else .hypothesis,
                    .sources = .{ .items = observer_inputs },
                },
            );
            try workspacePublication(self, a, &saved, publication);
            defer if (saved.runtime_trace) |trace| a.free(trace.dependencies.items);
            try writeWorkspaceWork(self, &saved, .create);
            try createCustody(self, a, start.task_id, id);
            try workspaceStartRelated(self, start, parent, predecessor, id);
            return workspaceCommitStartedWork(
                self,
                a,
                start,
                parent,
                predecessor,
                heads,
                saved,
                request,
            );
        }
        fn workspaceStartRequest(
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
        ) !state.Digest {
            const Request = workspace.StartRequest;
            return if (start.delegated) |bound| bound.request else if (start.observer) |bound|
                try operation(workspace.ObserveRequest, a, .{
                    .task = start.task_id,
                    .selection = bound.selection,
                })
            else
                try operation(Request, a, .{
                    .task = start.task_id,
                    .program = start.program_id,
                    .input = .{ .bytes = start.input },
                    .policy = start.policy,
                    .origin = start.origin,
                    .runtime = start.runtime,
                    .trial = start.trial,
                });
        }
        fn workspaceStartPredecessor(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            parent: state.Task,
        ) !?contracts.Decoded(workspace.Work) {
            var predecessor: ?contracts.Decoded(workspace.Work) = null;
            errdefer if (predecessor) |*prior| prior.deinit();
            if (start.observer) |bound| if (bound.selection.previous) |previous| {
                const previous_id = try wp.identity(previous, .work);
                try requireCustody(self, a, start.task_id, previous_id);
                predecessor = try self.workspaceWork(a, start.task_id, previous_id);
                const prior = predecessor.?.value;
                const prior_observer = prior.observer orelse return error.InvalidObserverInput;
                if (prior_observer.successor != null) return error.DuplicateObservation;
                if (!prior_observer.stopped and observerHeadIndex(parent, prior.id) == null)
                    return error.CorruptState;
            };
            return predecessor;
        }
        fn workspacePublishStartedDriver(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
            parent: state.Task,
            artifact: workspace.Program,
            predecessor: ?*workspace.Work,
            heads: ?[]state.Digest,
            id: state.Digest,
            trial_view: anytype,
            responses: anytype,
            driver: *evaluator.Driver,
            request: state.Digest,
        ) !Admission {
            const native_started = std.Io.Clock.awake.now(self.io);
            const publication = try driver.drive(a, .none, 256);
            const native_ns = std.math.cast(
                u64,
                @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds),
            ) orelse std.math.maxInt(u64);
            defer a.free(publication.outcome);
            errdefer store(self).fence();
            return workspaceCreateStartedWork(
                self,
                a,
                start,
                parent,
                artifact,
                predecessor,
                heads,
                id,
                trial_view,
                responses,
                publication,
                native_ns,
                request,
            );
        }
        fn workspaceStartPrepared(
            self: *Self,
            a: std.mem.Allocator,
            start: WorkspaceStartAdmission,
        ) !Admission {
            var parent = try self.task(a, start.task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            const request = try workspaceStartRequest(a, start);
            if (try replay(self, a, start.operation_id, request)) |prior| {
                if (start.preparation != null) return error.OperationConflict;
                return prior;
            }
            try requireCustody(self, a, start.task_id, null);
            var predecessor = try workspaceStartPredecessor(self, a, start, parent.value);
            defer if (predecessor) |*prior| prior.deinit();
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            var artifact = try self.workspaceProgram(a, start.task_id, start.program_id);
            defer artifact.deinit();
            try validateWorkspaceStartInput(self, a, start, artifact.value);
            const responses = try a.alloc(
                std.meta.Elem(@FieldType(@FieldType(workspace.Trial, "responses"), "items")),
                if (start.trial == .synthetic) start.trial.synthetic.responses.items.len else 0,
            );
            defer a.free(responses);
            try workspaceStartResponses(self, a, start, responses);
            const image =
                try store(self).object(a, artifact.value.description.image, null);
            defer a.free(image);
            const trial_view = if (start.trial != .none)
                try controllerView(self, a, parent.value)
            else
                null;
            defer if (trial_view) |view| {
                a.free(view.bytes);
                freeControllerViewWorks(a, view.works);
            };
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try retire(self, a);
            var id: state.Digest = undefined;
            if (start.delegated) |bound| id =
                bound.record.instrument else try self.io.randomSecure(&id);
            const heads = if (start.observer != null)
                try observerHeadsAfter(
                    a,
                    parent.value,
                    if (predecessor) |prior| prior.value.id else null,
                    id,
                )
            else
                null;
            defer if (heads) |items| a.free(items);
            const driver = try workspaceStartDriver(self, a, start, id, image);
            errdefer if (!store(self).fenced) retire(self, a) catch
                store(self).fence();
            return workspacePublishStartedDriver(
                self,
                a,
                start,
                parent.value,
                artifact.value,
                if (predecessor) |*prior| &prior.value else null,
                heads,
                id,
                trial_view,
                responses,
                driver,
                request,
            );
        }
    };
}
