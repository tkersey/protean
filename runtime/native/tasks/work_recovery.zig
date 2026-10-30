const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const task_types = @import("types.zig");
const Work = task_types.Work;
const cleanupComplete = task_types.cleanupComplete;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const activeObserver = Observers.activeObserver;
        const effectSchedule = Root.effectSchedule;
        const event = Records.event;
        const finishRecovery = reconciliation_ops.finishRecovery;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const parkWorkspaceOnClose = control_ops.parkWorkspaceOnClose;
        const pendingRecovery = reconciliation_ops.pendingRecovery;
        const persist = Records.persist;
        const record = Records.record;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const settleRemoteWork = RemoteWork.settleRemoteWork;
        const stopRemoteObserverOne = RemoteWork.stopRemoteObserverOne;
        const store = Lifecycle.store;
        const subjectAdd = Scheduling.subjectAdd;
        const subjectRemove = Scheduling.subjectRemove;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const reconciliation_ops = @import("reconciliation.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const RemoteWork = @import("remote_work.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const control_ops = @import("workspace_control.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn workspaceIds(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) ![]state.Digest {
            var query = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            var ids: std.ArrayList(state.Digest) = .empty;
            errdefer ids.deinit(a);
            while (try query.step() == .row) {
                const bytes = try query.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                try ids.append(a, bytes[0..32].*);
            }
            return ids.toOwnedSlice(a);
        }
        pub fn controllerResidualIds(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) ![]state.Digest {
            var query = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='controller_residual' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            var ids: std.ArrayList(state.Digest) = .empty;
            errdefer ids.deinit(a);
            while (try query.step() == .row) {
                const bytes = try query.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                try ids.append(a, bytes[0..32].*);
            }
            return ids.toOwnedSlice(a);
        }
        pub fn controllerResidualsSettled(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !bool {
            const ids = try controllerResidualIds(self, a, task_id);
            defer a.free(ids);
            for (ids) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    task_id,
                );
                defer residual.deinit();
                const bytes = try store(self).object(a, residual.value.outcome, null);
                defer a.free(bytes);
                var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                defer outcome.deinit();
                if (!cleanupComplete(outcome.value)) return false;
            }
            return true;
        }
        pub fn appendControllerResiduals(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            subjects: *std.ArrayList(workspace.Subject),
        ) !void {
            const ids = try controllerResidualIds(self, a, task_id);
            defer a.free(ids);
            for (ids) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    task_id,
                );
                defer residual.deinit();
                if (residual.value.schedule != .parked) try subjects.append(a, .{
                    .task = task_id,
                    .residual = id,
                });
            }
        }
        pub fn recoverControllerResiduals(
            self: *Self,
            a: std.mem.Allocator,
            selected: ?state.TaskId,
        ) !void {
            const tasks = try store(self).taskIds(a, false);
            defer a.free(tasks);
            for (tasks) |task_id| {
                if (selected) |id| if (!std.meta.eql(id, task_id)) continue;
                var authorized = self.task(a, task_id) catch |err| switch (err) {
                    error.Denied => continue,
                    else => return err,
                };
                defer authorized.deinit();
                const ids = try controllerResidualIds(self, a, task_id);
                defer a.free(ids);
                for (ids) |id| {
                    try recoverControllerResidual(self, a, task_id, id);
                }
            }
        }
        fn recoverControllerResidual(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !void {
            var residual =
                try record(self, state.ControllerResidual, a, "controller_residual", id, task_id);
            defer residual.deinit();
            const current = residual.value.current_occurrence orelse return;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", current, task_id);
            defer pending.deinit();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (pending.value.state == .dispatching) {
                try recoverDispatchedResidual(
                    self,
                    a,
                    task_id,
                    id,
                    current,
                    parent.value,
                    pending.value,
                );
            } else if (pending.value.state == .unknown) {
                const recovery_id = (try pendingRecovery(
                    self,
                    a,
                    task_id,
                    current,
                    pending.value.state.unknown.id,
                )) orelse return;
                var recovery = try record(
                    self,
                    state.Reconciliation,
                    a,
                    "reconciliation",
                    recovery_id,
                    task_id,
                );
                defer recovery.deinit();
                try finishRecovery(
                    self,
                    a,
                    parent.value,
                    pending.value,
                    recovery.value,
                    null,
                    .interrupted,
                );
            }
        }
        fn recoverDispatchedResidual(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            current: state.Digest,
            parent: state.Task,
            pending: occurrence.Occurrence,
        ) !void {
            const lost = try occurrence.unknown(
                pending,
                .{
                    .id = current,
                    .task = task_id,
                    .residual = id,
                    .request = pending.request,
                },
                pending.state.dispatching.id,
            );
            var value = parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            try store(self).putRecord(occurrence.Occurrence, "occurrence", current, task_id, lost);
            try effectSchedule(self, a, &value, pending, .parked, .unavailable_environment);
            try persist(self, a, value, parent.revision, "controller.recover-cleanup", .preserve);
        }
        pub fn recoverWorkspace(self: *Self, a: std.mem.Allocator) !void {
            const tasks = try store(self).taskIds(a, false);
            defer a.free(tasks);
            for (tasks) |task_id| {
                const ids = try workspaceIds(self, a, task_id);
                defer a.free(ids);
                for (ids) |id| {
                    var parent = self.task(a, task_id) catch |err| switch (err) {
                        error.Denied => continue,
                        else => return err,
                    };
                    defer parent.deinit();
                    // Reopening classifies lost delivery before the launch
                    // profile is selected. This transition uses retained task
                    // custody, and grants no new execution authority.
                    var child = try retainedWorkspaceWork(self, a, task_id, id);
                    defer child.deinit();
                    const current = child.value.current_occurrence orelse continue;
                    var pending =
                        try record(self, occurrence.Occurrence, a, "occurrence", current, task_id);
                    defer pending.deinit();
                    if (pending.value.state != .dispatching) continue;
                    const lost = try occurrence.unknown(
                        pending.value,
                        .{
                            .id = current,
                            .task = task_id,
                            .work = id,
                            .request = pending.value.request,
                        },
                        pending.value.state.dispatching.id,
                    );
                    var value = parent.value;
                    value.revision = try std.math.add(u64, value.revision, 1);
                    try store(self).begin();
                    defer store(self).rollback();
                    try store(self).putRecord(
                        occurrence.Occurrence,
                        "occurrence",
                        current,
                        task_id,
                        lost,
                    );
                    try effectSchedule(
                        self,
                        a,
                        &value,
                        pending.value,
                        .parked,
                        .unavailable_environment,
                    );
                    try persist(
                        self,
                        a,
                        value,
                        parent.value.revision,
                        "work.recover-unknown",
                        .preserve,
                    );
                }
            }
        }
        pub fn retainsController(
            self: *Self,
            a: std.mem.Allocator,
            control: @import("../placement.zig").Control,
        ) !bool {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var current = try journal.custody(store(self), a, .{
                .task = control.subject.task,
            }) orelse return error.InvalidTransfer;
            defer current.deinit();
            var site = current.value.owner;
            var epoch = current.value.epoch;
            if (std.meta.eql(control.controller, site) and control.controller_epoch == epoch)
                return true;
            const lineage =
                try journal.controllerLineage(store(self), a, control.subject.task);
            defer a.free(lineage);
            var index = lineage.len;
            while (index > 0) {
                index -= 1;
                const transition = lineage[index];
                if (transition == .behavior) {
                    const prior = transition.behavior;
                    if (prior.value.epoch != epoch or !std.meta.eql(prior.value.owner, site))
                        continue;
                    try p.verify(p.Behavior, a, prior, site);
                    if (!std.meta.eql(prior.value.task, control.subject.task) or
                        prior.value.epoch != try std.math.add(u64, prior.value.previous_epoch, 1))
                        return error.InvalidTransfer;
                    epoch = prior.value.previous_epoch;
                    if (std.meta.eql(control.controller, site) and
                        control.controller_epoch == epoch) return true;
                    continue;
                }
                const prior = transition.move;
                const intent = prior.offer.value.intent;
                if (prior.decision.value.epoch != epoch or
                    !std.meta.eql(prior.decision.value.destination, site)) continue;
                try p.verify(p.Offer, a, prior.offer, intent.source);
                try p.matchDecision(a, prior.offer.value, prior.decision);
                if (prior.decision.value.verdict != .accepted or !std.meta.eql(
                    prior.decision.value.destination,
                    intent.destination,
                ) or !std.meta.eql(intent.subject.task, control.subject.task) or
                    intent.subject.work != null) return error.InvalidTransfer;
                site = intent.source;
                epoch = intent.epoch;
                if (std.meta.eql(control.controller, site) and control.controller_epoch == epoch)
                    return true;
            }
            return false;
        }
        pub fn workspaceExplicitlyParked(
            self: *Self,
            a: std.mem.Allocator,
            child: workspace.Work,
        ) !bool {
            if (child.schedule != .parked) return false;
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? ORDER BY e.seq DESC",
                &.{.{ .blob = &child.task }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                const concerns_child = for (event_value.value.workspace_publications.items) |item| {
                    if (std.meta.eql(item.work, child.id)) break true;
                } else false;
                if (!concerns_child) continue;
                const ref = event_value.value.workspace_command orelse continue;
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value == .control) return command.value.control.command == .park;
            }
            return false;
        }
        pub fn settleWorkspaceOne(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            controller: bool,
        ) !bool {
            const ids = try workspaceIds(self, a, parent.id);
            defer a.free(ids);
            if (controller and (parent.cancellation != null or parent.terminal()) and
                try stopWorkspaceObserverOne(self, a, parent.id, parent.observer_heads.items))
                return true;
            for (ids) |id| {
                if (try settleWorkspaceChild(self, a, parent, controller, id)) return true;
            }
            return false;
        }
        fn settleWorkspaceChild(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            controller: bool,
            id: state.Digest,
        ) !bool {
            if (!try hasLocalCustody(self, a, parent.id, id)) {
                if (controller and (parent.cancellation != null or parent.terminal()) and
                    try settleRemoteWork(self, a, parent, id)) return true;
                return false;
            }
            var child = try self.workspaceWork(a, parent.id, id);
            defer child.deinit();
            if (self.shutdown_cancel_requested and
                try stopLocalWorkspaceObserver(self, a, child.value)) return true;
            if (child.value.terminal()) return false;
            if (!controller or parent.cancellation == null) {
                if (child.value.cancellation != null and
                    child.value.schedule != .parked) try subjectAdd(
                    self,
                    .{
                        .task = parent.id,
                        .work = id,
                    },
                );
                if (controller and parent.terminal() and child.value.cancellation == null and
                    child.value.schedule != .parked)
                {
                    try parkWorkspaceOnClose(self, a, parent.id, id);
                    subjectRemove(self, .{ .task = parent.id, .work = id });
                    return true;
                }
                return false;
            }
            if (child.value.cancellation != null and (child.value.schedule != .parked or
                !try workspaceCancellationPending(self, a, parent.id, id)))
            {
                if (child.value.schedule != .parked) try subjectAdd(self, .{
                    .task = parent.id,
                    .work = id,
                });
                return false;
            }
            const operation_id = try std.fmt.allocPrint(a, "task-cancel-{s}-{d}", .{
                std.fmt.bytesToHex(id, .lower),
                child.value.control_revision,
            });
            defer a.free(operation_id);
            _ = try self.workspaceControl(
                a,
                operation_id,
                parent.id,
                id,
                child.value.execution_revision,
                child.value.control_revision,
                .{ .cancel = parent.cancellation.? },
            );
            return true;
        }
        fn stopWorkspaceObserverOne(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ids: []const state.Digest,
        ) !bool {
            for (ids) |id| {
                if (!try hasLocalCustody(self, a, task_id, id)) {
                    if (try stopRemoteObserverOne(self, a, task_id, id)) return true;
                    continue;
                }
                var child = try self.workspaceWork(a, task_id, id);
                defer child.deinit();
                if (try stopLocalWorkspaceObserver(self, a, child.value)) return true;
            }
            return false;
        }
        pub fn stopLocalWorkspaceObserver(
            self: *Self,
            a: std.mem.Allocator,
            child: workspace.Work,
        ) !bool {
            if (!activeObserver(self, child)) return false;
            const operation_id = try std.fmt.allocPrint(a, "stop-cancelled-observer-{s}-{d}", .{
                std.fmt.bytesToHex(child.id, .lower), child.control_revision,
            });
            defer a.free(operation_id);
            _ = try self.workspaceStopObserving(a, operation_id, child.task, .{
                .work = try wp.reference(a, .work, child.id),
                .execution_revision = child.execution_revision,
                .control_revision = child.control_revision,
            });
            return true;
        }
        fn workspaceCancellationPending(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !bool {
            // Only a newer parent cancellation overrides an explicit child park.
            // Capture and execution publications do not acknowledge that intent.
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? ORDER BY e.seq DESC",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                if (saved.value.kind == .cancellation_requested) return true;
                const concerns_child = for (saved.value.workspace_publications.items) |item| {
                    if (std.meta.eql(item.work, work_id)) break true;
                } else false;
                if (!concerns_child) continue;
                const ref = saved.value.workspace_command orelse continue;
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value != .control or (command.value.control.command != .park and
                    command.value.control.command != .cancel))
                    continue;
                return false;
            }
            return false;
        }
        pub fn recover(self: *Self, a: std.mem.Allocator, selected: ?state.TaskId) !void {
            const ids = try store(self).taskIds(a, true);
            defer a.free(ids);
            for (ids) |id| {
                if (selected) |task_id| if (!std.meta.eql(id, task_id)) continue;
                try recoverDispatchedTask(self, a, id);
            }
            for (ids) |id| {
                if (selected) |task_id| if (!std.meta.eql(id, task_id)) continue;
                try recoverUnknownTask(self, a, id);
            }
        }
        fn recoverUnknownTask(self: *Self, a: std.mem.Allocator, id: state.TaskId) !void {
            var decoded = self.task(a, id) catch |err| switch (err) {
                error.Denied => return,
                else => return err,
            };
            defer decoded.deinit();
            const current = decoded.value.current_occurrence orelse return;
            var saved =
                try record(self, occurrence.Occurrence, a, "occurrence", current, id);
            defer saved.deinit();
            if (saved.value.state != .unknown) return;
            const pending = try pendingRecovery(
                self,
                a,
                id,
                current,
                saved.value.state.unknown.id,
            ) orelse return;
            var item =
                try record(self, state.Reconciliation, a, "reconciliation", pending, id);
            defer item.deinit();
            try finishRecovery(self, a, decoded.value, saved.value, item.value, null, .interrupted);
        }
        fn recoverDispatchedTask(self: *Self, a: std.mem.Allocator, id: state.TaskId) !void {
            var decoded = self.task(a, id) catch |err| switch (err) {
                error.Denied => return,
                else => return err,
            };
            defer decoded.deinit();
            var value = decoded.value;
            const current = value.current_occurrence orelse return;
            var saved =
                try record(self, occurrence.Occurrence, a, "occurrence", current, id);
            defer saved.deinit();
            if (saved.value.state != .dispatching) return;
            const binding: occurrence.Binding = .{
                .id = current,
                .task = id,
                .request = saved.value.request,
            };
            var attempt =
                try record(self, state.Attempt, a, "attempt", saved.value.state.dispatching.id, id);
            defer attempt.deinit();
            const compiling = attempt.value.operation == .workspace_build;
            const lost = if (compiling) try occurrence.notSent(
                saved.value,
                binding,
                saved.value.state.dispatching.id,
            ) else try occurrence.unknown(saved.value, binding, saved.value.state.dispatching.id);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            value.schedule = .parked;
            value.blocker = .unavailable_environment;
            try store(self).begin();
            defer store(self).rollback();
            try store(self).putRecord(occurrence.Occurrence, "occurrence", current, id, lost);
            try event(self, &value, if (compiling) .blocked else .delivery_unknown, "{}");
            try persist(self, a, value, previous, "process.recover-dispatched", .preserve);
        }
    };
}
