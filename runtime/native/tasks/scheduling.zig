const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const Step = task_types.Step;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const blocked = Messages.blocked;
        const compatible = Controller.compatible;
        const controllerResidualControl = Residuals.controllerResidualControl;
        const controllerResidualIds = Recovery.controllerResidualIds;
        const dispatch = Worker.dispatch;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const interpretCapture = Worker.interpretCapture;
        const pendingRecovery = reconciliation_ops.pendingRecovery;
        const pumpControllerResidual = Residuals.pumpControllerResidual;
        const pumpControllerSuccession = Succession.pumpControllerSuccession;
        const pumpPlacement = Transport.pumpPlacement;
        const pumpRoot = Root.pumpRoot;
        const pumpWorkspace = Execution.pumpWorkspace;
        const record = Records.record;
        const recoveryWork = reconciliation_ops.recoveryWork;
        const requireCustody = Lifecycle.requireCustody;
        const requireRuntimePolicy = Observations.requireRuntimePolicy;
        const resident = Lifecycle.resident;
        const retire = Lifecycle.retire;
        const rootOperation = Controller.rootOperation;
        const settleWorkspaceOne = Recovery.settleWorkspaceOne;
        const store = Lifecycle.store;
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Succession = @import("controller_succession.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Messages = @import("messages.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const reconciliation_ops = @import("reconciliation.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        fn runnableAdd(self: *Self, id: state.TaskId) !void {
            return subjectAdd(self, .{ .task = id });
        }
        pub fn subjectAdd(self: *Self, subject: workspace.Subject) !void {
            for (self.runnable.items) |item| if (std.meta.eql(item, subject)) return;
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            subjectAppendAssumeCapacity(self, subject);
        }
        pub fn subjectAddAssumeCapacity(self: *Self, subject: workspace.Subject) void {
            for (self.runnable.items) |item| if (std.meta.eql(item, subject)) return;
            subjectAppendAssumeCapacity(self, subject);
        }
        pub fn runnableAppendAssumeCapacity(self: *Self, id: state.TaskId) void {
            subjectAppendAssumeCapacity(self, .{ .task = id });
        }
        fn subjectAppendAssumeCapacity(self: *Self, subject: workspace.Subject) void {
            if (self.runnable_cursor == 0) {
                self.runnable.appendAssumeCapacity(subject);
            } else {
                // Insert immediately before the logical head, preserving that
                // head's position after insertion. New work is always last.
                self.runnable.insertAssumeCapacity(self.runnable_cursor, subject);
                self.runnable_cursor += 1;
            }
        }
        pub fn ensureOwnershipCapacity(self: *Self, id: ?state.TaskId) !void {
            if (id) |existing| for (self.owned.items) |prior| {
                if (same(&prior, &existing)) return;
            };
            try self.owned.ensureUnusedCapacity(self.allocator, 1);
        }
        pub fn claim(self: *Self, id: state.TaskId) void {
            for (self.owned.items) |prior| if (same(&prior, &id)) return;
            // Capacity is reserved before durable admission.
            self.owned.appendAssumeCapacity(id);
        }
        pub fn unclaim(self: *Self, id: state.TaskId) void {
            for (self.owned.items, 0..) |prior, i| if (same(&prior, &id)) {
                _ = self.owned.orderedRemove(i);
                if (i < self.cleanup_cursor) self.cleanup_cursor -= 1;
                if (self.cleanup_cursor >= self.owned.items.len) self.cleanup_cursor = 0;
                return;
            };
        }
        pub fn runnableRemove(self: *Self, id: state.TaskId) void {
            subjectRemove(self, .{ .task = id });
        }
        pub fn subjectRemove(self: *Self, subject: workspace.Subject) void {
            for (self.runnable.items, 0..) |item, i| if (std.meta.eql(item, subject)) {
                _ = self.runnable.orderedRemove(i);
                if (i < self.runnable_cursor) self.runnable_cursor -= 1;
                if (self.runnable_cursor == self.runnable.items.len) self.runnable_cursor = 0;
                return;
            };
        }
        pub fn pump(self: *Self, a: std.mem.Allocator) !Step {
            // At most one bounded Kosmos quantum or one durable environmental
            // transition. The caller services its control channel between calls.
            try allowed(self);
            if (try pumpPlacement(self, a)) return .progressed;
            const cleanup_count = self.owned.items.len;
            if (try pumpOwnedCleanup(self, a, @min(cleanup_count, 1))) return .progressed;
            const step = try pumpRunnable(self, a);
            if (step != .idle or cleanup_count <= 1) return step;
            if (try pumpOwnedCleanup(self, a, cleanup_count - 1)) return .progressed;
            return pumpRunnable(self, a);
        }
        fn pumpRunnable(self: *Self, a: std.mem.Allocator) !Step {
            // Scan one round, without charging or preparing blocked leaves.
            // Each actual transition yields back to the host control channel.
            const count = self.runnable.items.len;
            for (0..count) |_| {
                if (self.runnable.items.len == 0) break;
                const id = self.runnable.items[self.runnable_cursor];
                self.runnable_cursor += 1;
                if (self.runnable_cursor == self.runnable.items.len) self.runnable_cursor = 0;
                const step = (if (id.residual) |residual_id|
                    pumpControllerResidual(self, a, id.task, residual_id)
                else if (id.work) |work_id|
                    pumpWorkspace(self, a, id.task, work_id)
                else
                    pumpTask(self, a, id.task)) catch |err| switch (err) {
                    error.ObservationBlocked,
                    error.SemanticPolicyDenied,
                    error.GuardPolicyDenied,
                    => .idle,
                    else => return err,
                };
                if (step != .idle) return step;
            }
            return .idle;
        }
        fn pumpOwnedCleanup(self: *Self, a: std.mem.Allocator, count: usize) !bool {
            // Cancellation is a retained obligation, independent of root runnable
            // membership. Custody changes need no producer-specific wake-up.
            for (0..count) |_| {
                if (self.owned.items.len == 0) break;
                const id = self.owned.items[self.cleanup_cursor];
                self.cleanup_cursor = (self.cleanup_cursor + 1) % self.owned.items.len;
                const controller = try hasLocalCustody(self, a, id, null);
                var parent = try self.task(a, id);
                defer parent.deinit();
                compatible(self, parent.value) catch continue;
                if (try settleWorkspaceOne(self, a, parent.value, controller)) return true;
                if (!controller) continue;
                if (try settleControllerResiduals(self, a, parent.value)) return true;
                if (try rootCleanupRunnable(self, a, parent.value)) try runnableAdd(self, id);
                if (parent.value.terminal() and
                    try self.taskCleanupComplete(a, parent.value)) unclaim(self, id);
            }
            return false;
        }
        fn settleControllerResiduals(self: *Self, a: std.mem.Allocator, parent: state.Task) !bool {
            const ids = try controllerResidualIds(self, a, parent.id);
            defer a.free(ids);
            for (ids) |id| {
                var saved = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    parent.id,
                );
                defer saved.deinit();
                const residual = saved.value;
                if (residual.outcome_kind == .completed or residual.outcome_kind == .failed or
                    residual.outcome_kind == .cancelled)
                    continue;
                if (residual.schedule != .parked) {
                    try subjectAdd(self, .{ .task = parent.id, .residual = id });
                } else if (parent.cancellation != null and
                    try residualCancellationPending(self, a, parent.id, id))
                {
                    const operation_id = try std.fmt.allocPrint(a, "residual-cancel-{s}-{d}", .{
                        std.fmt.bytesToHex(id, .lower),
                        residual.control_revision,
                    });
                    defer a.free(operation_id);
                    _ = controllerResidualControl(
                        self,
                        a,
                        operation_id,
                        parent.id,
                        id,
                        residual.execution_revision,
                        residual.control_revision,
                        .{ .cancel = parent.cancellation.? },
                    ) catch |err| switch (err) {
                        error.UnsettledOccurrence => continue,
                        else => return err,
                    };
                    return true;
                }
            }
            return false;
        }
        fn residualCancellationPending(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !bool {
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? ORDER BY e.seq DESC",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            const expected = std.fmt.bytesToHex(id, .lower);
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                if (saved.value.kind == .cancellation_requested) return true;
                if (saved.value.kind == .reconciled) {
                    var data_value = try json.parse(a, saved.value.data.bytes, .{});
                    defer data_value.deinit();
                    const text = try json.text(
                        json.get(data_value.value, "reconciliation_id") orelse
                            return error.CorruptState,
                    );
                    var recovery_id: state.Digest = undefined;
                    if (text.len != 64) return error.CorruptState;
                    _ = try std.fmt.hexToBytes(&recovery_id, text);
                    var recovery = try record(
                        self,
                        state.Reconciliation,
                        a,
                        "reconciliation",
                        recovery_id,
                        task_id,
                    );
                    defer recovery.deinit();
                    var pending = try record(
                        self,
                        occurrence.Occurrence,
                        a,
                        "occurrence",
                        recovery.value.occurrence,
                        task_id,
                    );
                    defer pending.deinit();
                    if (std.meta.eql(pending.value.residual, id)) return false;
                }
                const ref = saved.value.workspace_command orelse continue;
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value != .residual or (command.value.residual.command != .park and
                    command.value.residual.command != .cancel))
                    continue;
                var event_data = try json.parse(a, saved.value.data.bytes, .{});
                defer event_data.deinit();
                const identity =
                    json.get(event_data.value, "workspace_id") orelse return error.CorruptState;
                if (identity == .string and same(identity.string, &expected)) return false;
            }
            return false;
        }
        fn rootCleanupRunnable(self: *Self, a: std.mem.Allocator, value: state.Task) !bool {
            if (value.cancellation == null or value.terminal() or value.schedule == .parked)
                return false;
            if (!value.cancellation_applied) return true;
            const id = value.current_occurrence orelse return true;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, value.id);
            defer pending.deinit();
            return pending.value.state != .awaiting and pending.value.state != .not_sent;
        }
        fn pumpTask(self: *Self, a: std.mem.Allocator, id: state.TaskId) !Step {
            requireCustody(self, a, id, null) catch |err| {
                if (err != error.CustodyNotLocal) return err;
                runnableRemove(self, id);
                return .idle;
            };
            var decoded = try self.task(a, id);
            defer decoded.deinit();
            const value = decoded.value;
            if (value.terminal()) {
                runnableRemove(self, id);
                if (try self.taskCleanupComplete(a, value)) unclaim(self, id);
                return .progressed;
            }
            compatible(self, value) catch
                return blocked(self, a, value, .incompatible_profile);
            if (value.controller_succession) |succession| return pumpControllerSuccession(
                self,
                a,
                value,
                succession,
            );
            if (self.active) |active| {
                if (active.subject == .root and std.meta.eql(active.task, id) and
                    active.root_control != null) return pumpRoot(self, a, value);
            }
            var saved_operation = try rootOperation(self, a, value);
            defer if (saved_operation) |*saved| saved.deinit();
            if (saved_operation != null and saved_operation.?.value.pending != null)
                return pumpRoot(self, a, value);
            return pumpTaskOccurrence(self, a, value);
        }
        fn pumpTaskOccurrence(self: *Self, a: std.mem.Allocator, value: state.Task) !Step {
            const id = value.id;
            var current: ?contracts.Decoded(occurrence.Occurrence) = null;
            defer if (current) |*item| item.deinit();
            if (value.current_occurrence) |identity| current =
                try record(self, occurrence.Occurrence, a, "occurrence", identity, id);
            var control: data.invocation.Control = .none;
            if (current) |item| {
                return pumpPendingOccurrence(self, a, value, item.value);
            } else if (value.cancellation != null and !value.cancellation_applied) {
                control = .{ .cancel = .{ .text = value.cancellation.?.bytes } };
            } else if (value.outcome_kind == .yielded) {
                control = .resume_yield;
            }
            return advance(self, a, value, control, null);
        }
        fn pumpPendingOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: occurrence.Occurrence,
        ) !Step {
            const id = value.id;
            var control: data.invocation.Control = .none;
            var consumed: ?occurrence.Occurrence = null;
            var reply: ?[]u8 = null;
            defer if (reply) |bytes| a.free(bytes);

            const binding: occurrence.Binding = .{
                .id = pending.id,
                .task = id,
                .request = pending.request,
            };
            switch (pending.state) {
                .captured => return interpretCapture(self, a, value, pending),
                .unknown => |attempt| return pumpUnknownOccurrence(
                    self,
                    a,
                    value,
                    pending,
                    attempt,
                ),
                .dispatching => |attempt| {
                    // This worker still owns the attempt even when another
                    // task now owns the sole physical Kosmos resident.
                    if (self.work) |work| if (same(&work.task, &id) and
                        same(&work.occurrence, &pending.id) and same(&work.attempt, &attempt.id))
                        return .idle;
                    return blocked(self, a, value, .unavailable_environment);
                },
                .settled_reply => |acquired| {
                    reply = try store(self).acquiredObject(a, acquired.reply, null);
                    consumed = try occurrence.consumed(
                        pending,
                        binding,
                        .{ .reply = acquired.reply },
                        value.cancellation != null,
                    );
                    control = .{ .reply = reply.? };
                },
                .ready, .awaiting, .not_sent => {
                    if (value.cancellation != null and !value.cancellation_applied) {
                        consumed = try occurrence.consumed(pending, binding, .cancel, true);
                        control = .{ .cancel = .{ .text = value.cancellation.?.bytes } };
                    } else if (pending.state == .awaiting or pending.state == .not_sent) {
                        runnableRemove(self, id);
                        try retire(self, a);
                        return .waiting;
                    } else return dispatch(self, a, value, pending);
                },
                .admitted => return error.CorruptState,
            }
            return advance(self, a, value, control, consumed);
        }
        fn pumpUnknownOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: occurrence.Occurrence,
            attempt: anytype,
        ) !Step {
            if (self.work) |work| if (work.recovery != null and same(&work.task, &value.id) and
                same(&work.occurrence, &pending.id) and same(&work.attempt, &attempt.id))
                return .idle;
            if (try pendingRecovery(
                self,
                a,
                value.id,
                pending.id,
                attempt.id,
            )) |recovery_id| return recoveryWork(self, a, value, pending, recovery_id);
            return blocked(self, a, value, .unavailable_environment);
        }
        fn advance(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            control: data.invocation.Control,
            consumed: ?occurrence.Occurrence,
        ) !Step {
            if (initial.cancellation == null) try requireRuntimePolicy(
                self,
                a,
                initial.id,
                initial.controller_runtime,
            );
            try requireCustody(self, a, initial.id, null);
            const driver = try resident(self, a, initial);
            const quantum: u64 = if (control == .reply and initial.cancellation != null and
                !initial.cancellation_applied) 0 else 256;
            _ = consumed;
            const encoded_control =
                try contracts.encodeOwned(data.invocation.Control, self.allocator, control);
            driver.beginAdvance(control, quantum) catch |err| {
                self.allocator.free(encoded_control);
                return err;
            };
            self.active.?.root_control = encoded_control;
            self.active.?.root_quantum = quantum;
            return pumpRoot(self, a, initial);
        }
    };
}
