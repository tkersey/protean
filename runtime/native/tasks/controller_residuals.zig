const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Active = task_types.Active;
const Admission = task_types.Admission;
const Step = task_types.Step;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const capsuleDependencies = Realization.capsuleDependencies;
        const compatible = ControllerState.compatible;
        const controllerBinding = ControllerState.controllerBinding;
        const controllerRuntime = ControllerState.controllerRuntime;
        const controllerRuntimeAt = Realization.controllerRuntimeAt;
        const dispatch = Worker.dispatch;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const interpretCapture = Worker.interpretCapture;
        const pendingRecovery = Reconciliation.pendingRecovery;
        const persist = Records.persist;
        const record = Records.record;
        const recoveryWork = Reconciliation.recoveryWork;
        const replay = Records.replay;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const requireCustody = Lifecycle.requireCustody;
        const retire = Lifecycle.retire;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const subjectPublicationEvent = Records.subjectPublicationEvent;
        const subjectRemove = Scheduling.subjectRemove;
        const unclaim = Scheduling.unclaim;
        const validateCancellation = Checkpoint.validateCancellation;
        const validateControllerOperation = ControllerState.validateControllerOperation;
        const workspaceCommit = Publication.workspaceCommit;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Checkpoint = @import("checkpoint.zig").Operations(Types, Self);
        const ControllerState = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Reconciliation = @import("reconciliation.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        pub fn validateControllerResidual(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            records: []const state.ArchiveRecord,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var saved =
                try record(self, state.ControllerResidual, a, "controller_residual", id, parent.id);
            defer saved.deinit();
            try requireArchiveRecord(records, .controller_succession, saved.value.succession);
            if (saved.value.current_occurrence) |current| try requireArchiveRecord(
                records,
                .occurrence,
                current,
            );
            return validateControllerResidualValue(self, allocator, parent, saved.value, false);
        }
        fn validateControllerResidualValue(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
            historical: bool,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const id = residual.id;
            try validateResidualWait(self, a, parent, residual);
            var operation_value = try record(
                self,
                state.ControllerSuccession,
                a,
                "controller_succession",
                residual.succession,
                parent.id,
            );
            defer operation_value.deinit();
            const runtime_cut = try controllerRuntimeAt(
                self,
                a,
                parent,
                (operation_value.value.activation_event orelse return error.InvalidArchive) -| 1,
            );
            if (!std.meta.eql(residual.runtime, runtime_cut.runtime)) return error.InvalidArchive;
            if (operation_value.value.phase != .activated or
                !std.meta.eql(operation_value.value.residual, id) or !std.meta.eql(
                operation_value.value.predecessor,
                residual.controller,
            ) or !std.meta.eql(operation_value.value.checkpoint, residual.initial_checkpoint))
                return error.InvalidArchive;
            try validateResidualCheckpoint(
                self,
                a,
                parent,
                residual,
                operation_value.value,
                historical,
            );
        }
        fn validateResidualWait(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
        ) !void {
            if (residual.blocker == .waiting_workspace) {
                if (!residual.cancellation_applied or residual.schedule != .parked)
                    return error.InvalidArchive;
                const current = residual.current_occurrence orelse return error.InvalidArchive;
                var waiting =
                    try record(self, workspace.Wait, a, "workspace_wait", current, parent.id);
                defer waiting.deinit();
                if (!std.meta.eql(waiting.value.id, current) or
                    !std.meta.eql(waiting.value.task, parent.id)) return error.InvalidArchive;
            }
        }
        fn validateResidualCheckpoint(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
            operation_value: state.ControllerSuccession,
            historical: bool,
        ) !void {
            const binding =
                try controllerBinding(self, a, parent, residual.controller);
            const image = try store(self).object(a, binding.image, null);
            var prepared = try self.program.prepare(self.allocator, image);
            defer prepared.deinit();
            const checkpoint = try store(self).object(a, residual.checkpoint, null);
            var candidate = try kosmos.Session.restore(self.allocator, &prepared, checkpoint);
            defer candidate.deinit();
            var actual = try kosmos.invocation.finishPublication(a, &candidate, .receipt, null);
            defer actual.outcome.deinit();
            defer self.allocator.free(actual.checkpoint.?);
            try validateResidualOutcome(
                self,
                a,
                parent,
                residual,
                operation_value,
                historical,
                checkpoint,
                actual,
            );
        }
        fn validateResidualOutcome(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
            operation_value: state.ControllerSuccession,
            historical: bool,
            checkpoint: []const u8,
            actual: anytype,
        ) !void {
            const id = residual.id;
            const outcome =
                try data.invocation.encodeOwned(data.invocation.Outcome, a, actual.outcome.record);
            if (!std.meta.eql(residual.outcome, state.Reference{
                .digest = storage.digest(outcome),
                .bytes = outcome.len,
            }) or !same(checkpoint, actual.checkpoint.?) or !same(
                @tagName(residual.outcome_kind),
                @tagName(actual.outcome.record),
            )) return error.InvalidArchive;
            try validateCancellation(
                a,
                .{
                    .cancellation_applied = residual.cancellation_applied,
                    .cancellation = @as(?state.Reason, .{ .bytes = "Controller superseded" }),
                },
                actual.outcome.record,
                checkpoint,
            );
            if (!residual.cancellation_applied and
                (!std.meta.eql(residual.checkpoint, residual.initial_checkpoint) or !std.meta.eql(
                    residual.current_occurrence,
                    operation_value.handoff,
                ))) return error.InvalidArchive;
            if (actual.outcome.record == .requested) {
                const occurrence_id = residual.current_occurrence orelse
                    return error.InvalidArchive;
                var pending = try record(
                    self,
                    occurrence.Occurrence,
                    a,
                    "occurrence",
                    occurrence_id,
                    parent.id,
                );
                defer pending.deinit();
                const bytes = actual.outcome.record.requested.request;
                if (!std.meta.eql(pending.value.request_object, state.Reference{
                    .digest = storage.digest(bytes),
                    .bytes = bytes.len,
                }) or
                    pending.value.work != null or
                    (residual.cancellation_applied and
                        !std.meta.eql(pending.value.residual, id))) return error.InvalidArchive;
            } else if (residual.current_occurrence != null) return error.InvalidArchive;
            if (residual.outer_operation) |pending| _ = try validateControllerOperation(
                self,
                a,
                parent,
                pending,
                residual,
                historical,
            );
        }
        pub fn validateResidualObservation(
            self: *Self,
            a: std.mem.Allocator,
            observed: state.ControllerResidualObservation,
        ) !void {
            var current = try record(
                self,
                state.ControllerResidual,
                a,
                "controller_residual",
                observed.id,
                observed.task,
            );
            defer current.deinit();
            inline for (.{
                "controller",
                "succession",
                "initial_checkpoint",
                "runtime",
            }) |field| if (!std.meta.eql(@field(observed, field), @field(current.value, field)))
                return error.InvalidArchive;
            if (observed.execution_revision > current.value.execution_revision or
                observed.control_revision > current.value.control_revision or
                observed.control_revision == 0)
                return error.InvalidArchive;
            if (observed.execution_revision == current.value.execution_revision) inline for (.{
                "checkpoint",
                "outcome",
                "outcome_kind",
                "current_occurrence",
                "cancellation_applied",
            }) |field| {
                if (!std.meta.eql(@field(observed, field), @field(current.value, field)))
                    return error.InvalidArchive;
            };
            var parent = try self.task(a, observed.task);
            defer parent.deinit();
            try validateControllerResidualValue(
                self,
                self.allocator,
                parent.value,
                observed.retained(),
                true,
            );
        }
        pub fn controllerResidualObservation(
            _: *Self,
            a: std.mem.Allocator,
            value: state.ControllerResidualObservation,
        ) !json.Value {
            var result = try values.toJson(state.ControllerResidualObservation, a, value);
            try json.put(
                a,
                &result,
                "work",
                try values.toJson(wc.Ref, a, try wp.reference(a, .residual, value.id)),
            );
            try json.put(a, &result, "role", json.string("retired_controller"));
            return result;
        }
        pub fn residualPublication(
            self: *Self,
            a: std.mem.Allocator,
            value: state.ControllerResidual,
        ) !state.ResidualPublication {
            var pending: ?occurrence.Occurrence = null;
            if (value.current_occurrence) |id| {
                var saved =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, value.task);
                defer saved.deinit();
                pending = saved.value;
            }
            return .{ .value = .from(value), .occurrence = pending };
        }
        pub fn residualProgressEvent(
            self: *Self,
            a: std.mem.Allocator,
            parent: *state.Task,
            value: state.ControllerResidual,
        ) !void {
            const bytes = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{
                std.fmt.bytesToHex(value.id, .lower),
            });
            defer a.free(bytes);
            try subjectPublicationEvent(
                self,
                parent,
                .workspace_progress,
                bytes,
                &.{},
                &.{try residualPublication(self, a, value)},
                null,
                null,
                null,
            );
        }
        pub fn controllerResidualControl(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            id: state.Digest,
            execution: u64,
            control: u64,
            command: workspace.Command,
        ) !Admission {
            const request = try operation(workspace.ResidualControlRequest, a, .{
                .task = task_id,
                .residual = id,
                .execution = execution,
                .control = control,
                .command = command,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            if (command == .delegate) return error.InvalidControl;
            try requireCustody(self, a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            var saved =
                try record(self, state.ControllerResidual, a, "controller_residual", id, task_id);
            defer saved.deinit();
            const value = saved.value;
            if (execution != value.execution_revision or control != value.control_revision)
                return error.StaleRevision;
            if (value.outcome_kind == .completed or value.outcome_kind == .failed or
                value.outcome_kind == .cancelled)
                return error.TerminalTask;
            const rearmed = try rearmControllerResidual(self, a, task_id, value, command);
            return commitResidualControl(
                self,
                a,
                parent.value,
                operation_id,
                request,
                value,
                command,
                rearmed,
            );
        }
        fn rearmControllerResidual(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            value: state.ControllerResidual,
            command: workspace.Command,
        ) !?occurrence.Occurrence {
            var rearmed: ?occurrence.Occurrence = null;
            if (value.current_occurrence) |current| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", current, task_id);
                defer pending.deinit();
                if (pending.value.state == .unknown or pending.value.state == .dispatching)
                    return error.UnsettledOccurrence;
                if (command != .park and
                    pending.value.state == .not_sent) rearmed = try occurrence.rearm(
                    pending.value,
                    .{
                        .id = current,
                        .task = task_id,
                        .residual = pending.value.residual,
                        .request = pending.value.request,
                    },
                );
            }

            return rearmed;
        }
        fn commitResidualControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_id: []const u8,
            request: state.Digest,
            initial: state.ControllerResidual,
            command: workspace.Command,
            rearmed: ?occurrence.Occurrence,
        ) !Admission {
            var value = initial;
            const task_id = parent.id;
            const id = value.id;
            const execution = value.execution_revision;
            const control = value.control_revision;
            try ensureOwnershipCapacity(self, task_id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.schedule = if (command == .park) .parked else .queued;
            value.blocker = null;
            try store(self).begin();
            defer store(self).rollback();
            if (rearmed) |pending| try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                task_id,
                pending,
            );
            try store(self).putRecord(
                state.ControllerResidual,
                "controller_residual",
                id,
                task_id,
                value,
            );
            const admitted = try workspaceCommit(
                self,
                a,
                parent,
                operation_id,
                request,
                id,
                .residual,
                try snapshotRecord(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    task_id,
                ),
                .{ .residual = .{
                    .execution = execution,
                    .control = control,
                    .command = command,
                } },
            );
            const subject: workspace.Subject = .{ .task = task_id, .residual = id };
            if (command == .park) subjectRemove(self, subject) else {
                Scheduling.claim(self, task_id);
            }
            return admitted;
        }
        pub fn residualProvenance(
            value: state.ControllerResidual,
        ) kosmos.RuntimeCapsule.Provenance {
            return .{ .execution = value.id, .custody = value.controller, .publication = .{
                .digest = value.checkpoint.digest,
                .bytes = value.checkpoint.bytes,
            } };
        }
        pub fn retainResidualOperation(self: *Self, a: std.mem.Allocator, active: Active) !void {
            if (active.root_control == null) return;
            var saved = try record(
                self,
                state.ControllerResidual,
                a,
                "controller_residual",
                active.subject.residual,
                active.task,
            );
            defer saved.deinit();
            if (saved.value.execution_revision != active.execution_revision)
                return error.CorruptState;
            const capsule = try active.driver.retainCapsule(residualProvenance(saved.value));
            const dependencies = try capsuleDependencies(a, capsule);
            defer a.free(dependencies);
            const code = try active.driver.runtimeBytes(a);
            defer a.free(code);
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(code);
            saved.value.outer_operation = .{
                .capsule = try store(self).putObject(capsule),
                .dependencies = .{ .items = dependencies },
                .control = try store(self).putObject(active.root_control.?),
                .guest_quantum = active.root_quantum,
            };
            try store(self).putRecord(
                state.ControllerResidual,
                "controller_residual",
                saved.value.id,
                active.task,
                saved.value,
            );
            try self.namespace.commit("controller.residual-suspend");
            self.active.?.outer_operation = saved.value.outer_operation.?.capsule;
        }
        fn residualResident(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: state.ControllerResidual,
        ) !*evaluator.Driver {
            if (self.active) |active| {
                if (std.meta.eql(active.task, parent.id) and active.subject == .residual and
                    std.meta.eql(active.subject.residual, value.id) and
                    active.execution_revision == value.execution_revision) return active.driver;
                try retire(self, a);
            }
            const binding =
                try controllerBinding(self, a, parent, value.controller);
            const image = try store(self).object(a, binding.image, null);
            defer a.free(image);
            var runtime = try controllerRuntime(self, a, parent.id, binding.image, value.runtime);
            defer runtime.deinit();
            var root_control: ?[]u8 = null;
            errdefer if (root_control) |bytes| self.allocator.free(bytes);
            var ready = false;
            const driver = if (value.outer_operation) |pending| blk: {
                root_control =
                    try store(self).object(self.allocator, pending.control, null);
                const capsule = try store(self).object(a, pending.capsule, null);
                defer a.free(capsule);
                ready = try validateControllerOperation(self, a, parent, pending, value, false);
                const Owner = struct {
                    value: state.ControllerResidual,
                    fn claim(
                        context: *anyopaque,
                        ref: kosmos.RuntimeCapsule.Reference,
                        record_value: kosmos.RuntimeCapsule.Record,
                        _: kosmos.RuntimeCapsule.Reference,
                    ) !void {
                        const owner: *@This() = @ptrCast(@alignCast(context));
                        if (!std.meta.eql(
                            ref.digest,
                            owner.value.outer_operation.?.capsule.digest,
                        ) or !std.meta.eql(
                            record_value.provenance,
                            residualProvenance(owner.value),
                        )) return error.InvalidArchive;
                    }
                };
                var owner: Owner = .{ .value = value };
                break :blk try evaluator.Driver.openCapsule(
                    self.allocator,
                    image,
                    &runtime,
                    capsule,
                    .{ .context = &owner, .claim = Owner.claim },
                );
            } else blk: {
                const checkpoint = try store(self).object(a, value.checkpoint, null);
                defer a.free(checkpoint);
                break :blk try evaluator.Driver.openSelected(
                    self.allocator,
                    image,
                    .{ .state = checkpoint },
                    &runtime,
                );
            };
            self.active = .{
                .task = parent.id,
                .subject = .{ .residual = value.id },
                .execution_revision = value.execution_revision,
                .driver = driver,
                .root_control = root_control,
                .root_cut_ready = ready,
                .root_quantum = if (value.outer_operation) |pending| pending.guest_quantum else 0,
            };
            return driver;
        }
        pub fn pumpControllerResidual(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !Step {
            requireCustody(self, a, task_id, null) catch |err| {
                if (err != error.CustodyNotLocal) return err;
                subjectRemove(self, .{ .task = task_id, .residual = id });
                return .idle;
            };
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            var saved =
                try record(self, state.ControllerResidual, a, "controller_residual", id, task_id);
            defer saved.deinit();
            const residual = saved.value;
            if (residual.outcome_kind == .completed or residual.outcome_kind == .failed or
                residual.outcome_kind == .cancelled)
            {
                subjectRemove(self, .{ .task = task_id, .residual = id });
                if (try self.taskCleanupComplete(a, parent.value)) unclaim(self, task_id);
                return .idle;
            }
            if (residual.schedule == .parked) {
                subjectRemove(self, .{ .task = task_id, .residual = id });
                return .idle;
            }
            return pumpResidentResidual(self, a, parent.value, residual);
        }
        fn prepareResidualControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
            driver: *evaluator.Driver,
            current: ?contracts.Decoded(occurrence.Occurrence),
        ) !?Step {
            const task_id = parent.id;

            var control: data.invocation.Control = .none;
            if (!residual.cancellation_applied) {
                control = .{ .cancel = .{ .text = "Controller superseded" } };
            } else if (current) |item| switch (item.value.state) {
                .ready => return try dispatch(self, a, parent, item.value),
                .captured => return try interpretCapture(self, a, parent, item.value),
                .settled_reply => |reply| control = .{
                    .reply = try store(self).acquiredObject(a, reply.reply, null),
                },
                .unknown => |attempt| {
                    if (try pendingRecovery(
                        self,
                        a,
                        task_id,
                        item.value.id,
                        attempt.id,
                    )) |recovery_id| return try recoveryWork(
                        self,
                        a,
                        parent,
                        item.value,
                        recovery_id,
                    );
                    return .idle;
                },
                .dispatching, .not_sent => return .idle,
                else => return error.CorruptState,
            } else if (residual.outcome_kind == .yielded) control = .resume_yield;
            const encoded =
                try contracts.encodeOwned(data.invocation.Control, self.allocator, control);
            errdefer self.allocator.free(encoded);
            try driver.beginAdvance(control, 256);
            self.active.?.root_control = encoded;
            self.active.?.root_quantum = 256;

            return null;
        }
        fn consumeResidualOccurrence(
            task_id: state.TaskId,
            control: data.invocation.Control,
            current: ?contracts.Decoded(occurrence.Occurrence),
        ) !?occurrence.Occurrence {
            var consumed: ?occurrence.Occurrence = null;
            if (current) |item| {
                if (control == .reply or control == .cancel) consumed = try occurrence.consumed(
                    item.value,
                    .{
                        .id = item.value.id,
                        .task = task_id,
                        .work = item.value.work,
                        .residual = item.value.residual,
                        .request = item.value.request,
                    },
                    if (control == .cancel) .cancel else .{
                        .reply = storage.digest(control.reply),
                    },
                    true,
                );
            }

            return consumed;
        }
        fn pumpResidentResidual(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
        ) !Step {
            const task_id = parent.id;
            const driver = try residualResident(self, a, parent, residual);
            var current: ?contracts.Decoded(occurrence.Occurrence) = null;
            defer if (current) |*item| item.deinit();
            if (residual.current_occurrence) |occurrence_id| current = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                occurrence_id,
                task_id,
            );
            if (self.active.?.root_control == null) {
                if (try prepareResidualControl(
                    self,
                    a,
                    parent,
                    residual,
                    driver,
                    current,
                )) |step| return step;
            }
            var decoded =
                try contracts.decodeOwned(data.invocation.Control, a, self.active.?.root_control.?);
            defer decoded.deinit();
            const control = decoded.value;
            const consumed = try consumeResidualOccurrence(task_id, control, current);
            return advanceResidualController(self, a, parent, residual, driver, control, consumed);
        }
        fn storeResidualRequest(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            residual: *state.ControllerResidual,
            request_bytes: []const u8,
        ) !void {
            const task_id = value.id;
            const id = residual.id;

            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            const binding =
                try controllerBinding(self, a, value, residual.controller);
            if (!std.meta.eql(request.value.binding.program_identity, binding.program_identity))
                return error.InvalidControllerBinding;
            var occurrence_id: state.Digest = undefined;
            try self.io.randomSecure(&occurrence_id);
            try store(self).createRecord(
                occurrence.Occurrence,
                "occurrence",
                occurrence_id,
                task_id,
                .{
                    .id = occurrence_id,
                    .task = task_id,
                    .residual = id,
                    .request = request.value.request_identity,
                    .request_object = try store(self).putObject(request_bytes),
                },
            );
            try store(self).createRecord(
                workspace.ExecutionRoute,
                "execution_route",
                occurrence_id,
                task_id,
                .{
                    .id = occurrence_id,
                    .task = task_id,
                    .work = null,
                    .residual = id,
                    .image = binding.image,
                    .program_identity = binding.program_identity,
                    .controller = binding.id,
                    .controller_epoch = binding.epoch,
                },
            );
            residual.current_occurrence = occurrence_id;
            residual.outcome_kind = .requested;
        }
        fn storeResidualOutcome(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            residual: *state.ControllerResidual,
            outcome: data.invocation.Outcome,
        ) !void {
            switch (outcome) {
                .progressed => residual.outcome_kind = .progressed,
                .yielded => residual.outcome_kind = .yielded,
                .completed => residual.outcome_kind = .completed,
                .failed => residual.outcome_kind = .failed,
                .cancelled => residual.outcome_kind = .cancelled,
                .requested => |requested| try storeResidualRequest(
                    self,
                    a,
                    value,
                    residual,
                    requested.request,
                ),
                .needs_capacity => unreachable,
            }
        }
        fn publishResidualAdvance(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: state.ControllerResidual,
            driver: *evaluator.Driver,
            control: data.invocation.Control,
            consumed: ?occurrence.Occurrence,
            publication: anytype,
            outcome: data.invocation.Outcome,
        ) !Step {
            var residual = initial;
            const task_id = parent.id;
            const id = residual.id;
            residual.cancellation_applied = residual.cancellation_applied or control == .cancel;
            residual.execution_revision = try std.math.add(u64, residual.execution_revision, 1);
            residual.current_occurrence = null;
            residual.outer_operation = null;
            residual.schedule = .queued;
            var value = parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            residual.checkpoint = try store(self).putObject(publication.checkpoint);
            residual.outcome = try store(self).putObject(publication.outcome);
            if (consumed) |item| try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                item.id,
                task_id,
                item,
            );
            try storeResidualOutcome(self, a, value, &residual, outcome);

            const terminal = residual.outcome_kind == .completed or
                residual.outcome_kind == .failed or
                residual.outcome_kind == .cancelled;
            if (terminal) residual.schedule = .parked;
            try store(self).putRecord(
                state.ControllerResidual,
                "controller_residual",
                id,
                task_id,
                residual,
            );
            try residualProgressEvent(self, a, &value, residual);
            try persist(self, a, value, parent.revision, "controller.residual", .preserve);
            self.active.?.execution_revision = residual.execution_revision;
            if (terminal) {
                subjectRemove(self, .{ .task = task_id, .residual = id });
                try driver.close();
                try driver.destroy();
                self.active = null;
            }
            return .progressed;
        }
        fn advanceResidualController(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            residual: state.ControllerResidual,
            driver: *evaluator.Driver,
            control: data.invocation.Control,
            consumed: ?occurrence.Occurrence,
        ) !Step {
            if (!self.active.?.root_cut_ready) {
                var progress = try driver.pump(65536);
                defer progress.deinit();
                if (progress == .suspended) return .progressed;
                if (progress != .event or progress.event.value != .cut)
                    return error.InvalidRuntimeProgress;
                self.active.?.root_cut_ready = true;
            }
            const publication = try driver.drive(a, .none, 0);
            defer a.free(publication.outcome);
            errdefer store(self).fence();
            self.allocator.free(self.active.?.root_control.?);
            self.active.?.root_control = null;
            self.active.?.root_cut_ready = false;
            var outcome =
                try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer outcome.deinit();
            if (outcome.value == .needs_capacity) return error.Capacity;
            return publishResidualAdvance(
                self,
                a,
                parent,
                residual,
                driver,
                control,
                consumed,
                publication,
                outcome.value,
            );
        }
    };
}
