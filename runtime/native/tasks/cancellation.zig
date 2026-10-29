const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const cancelDigest = task_types.cancelDigest;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const reconciliation_ops = @import("reconciliation.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const ArrayList = std.ArrayList;
        const appendControllerResiduals = Recovery.appendControllerResiduals;
        const associatedWorkDisposed = Tasks.associatedWorkDisposed;
        const claim = Scheduling.claim;
        const compatible = Controller.compatible;
        const decodeOwned = contracts.decodeOwned;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const event = Records.event;
        const finishRecovery = reconciliation_ops.finishRecovery;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const persistScheduled = Records.persistScheduled;
        const rearm = occurrence.rearm;
        const receipt = Records.receipt;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const store = Lifecycle.store;
        const task = Tasks.task;
        const workspaceIds = Recovery.workspaceIds;
        const workspaceRunnable = Execution.workspaceRunnable;
        const workspaceWork = Programs.workspaceWork;
        pub fn requestCancel(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            reason: []const u8,
        ) !Admission {
            if (reason.len > 256 or !std.unicode.utf8ValidateSlice(
                reason,
            )) return error.InvalidParams;
            const request = try cancelDigest(a, task_id, .{ .bytes = reason });
            if (try replay(self, a, id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var decoded = try task(self, a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            const previous = value.revision;
            const needs_cancellation =
                !value.terminal() or !try associatedWorkDisposed(self, a, task_id);
            const queue_root = self.work == null or
                self.work.?.subject_work != null or
                self.work.?.subject_residual != null or
                !same(&self.work.?.task, &task_id);
            const executable = compatible: {
                compatible(self, value) catch |err| switch (err) {
                    error.IncompatibleProfile => break :compatible false,
                };
                break :compatible true;
            };
            var cleanup: ArrayList(workspace.Subject) = .empty;
            defer cleanup.deinit(a);
            if (needs_cancellation) {
                try ensureOwnershipCapacity(self, task_id);
            }
            if (needs_cancellation and executable) try cancellationCleanup(
                self,
                a,
                task_id,
                queue_root,
                &cleanup,
            );
            try applyCancellation(&value, reason, needs_cancellation, executable, queue_root);
            try store(self).begin();
            defer store(self).rollback();
            try event(self, &value, .cancellation_requested, "{}");
            const admitted = try receipt(
                self,
                a,
                .cancel,
                id,
                request,
                value,
                .cancellation_requested,
                null,
                null,
            );
            try persistScheduled(self, a, value, previous, "task.cancel", .preserve, cleanup.items);
            return applyPublishedCancellation(
                self,
                a,
                task_id,
                needs_cancellation,
                executable,
                admitted,
            );
        }
        fn applyPublishedCancellation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            needs_cancellation: bool,
            executable: bool,
            admitted: Admission,
        ) !Admission {
            // The receipt now survives retries. If applying its cancellation
            // fails, only restart recovery may resume this owner's work.
            errdefer store(self).fence();
            // Cancellation intent survives a different launch configuration,
            // but it grants no authority to run the root or retained cleanup.
            if (needs_cancellation and !executable) {
                claim(self, task_id);
                return admitted;
            }
            if (self.work) |*work| if (same(&work.task, &task_id)) {
                work.cancel_requested = true;
            };
            // A new cancellation can also interrupt admitted recovery before
            // it acquires the worker. Prior cancellation intent does not abort
            // a later explicit recovery needed to settle unknown delivery.
            try interruptQueuedRecoveries(self, a, task_id);
            if (needs_cancellation) {
                claim(self, task_id);
            }
            return admitted;
        }
        fn cancellationCleanup(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            queue_root: bool,
            cleanup: *ArrayList(workspace.Subject),
        ) !void {
            {
                const children = try workspaceIds(self, a, task_id);
                defer a.free(children);
                for (children) |child_id| {
                    if (!try hasLocalCustody(self, a, task_id, child_id)) continue;
                    var child = try retainedWorkspaceWork(self, a, task_id, child_id);
                    defer child.deinit();
                    // Reopening requires explicit ownership. A new cancel
                    // can continue already admitted cleanup even when the root
                    // has a result and ordinary task resume is unavailable.
                    if (!child.value.terminal() and
                        child.value.cancellation != null and
                        child.value.schedule != .parked)
                        try cleanup.append(a, .{ .task = task_id, .work = child_id });
                }
            }
            try appendControllerResiduals(self, a, task_id, cleanup);
            if (queue_root) try cleanup.append(a, .{ .task = task_id });
        }
        fn applyCancellation(
            value: *state.Task,
            reason: []const u8,
            needs_cancellation: bool,
            executable: bool,
            queue_root: bool,
        ) !void {
            value.*.revision = try std.math.add(u64, value.revision, 1);
            if (needs_cancellation and value.*.cancellation == null) value.*.cancellation = .{
                .bytes = reason,
            };
            if (needs_cancellation and !executable) {
                value.*.blocker = .incompatible_profile;
                value.*.schedule = .parked;
            } else if (executable) {
                if (value.*.blocker == .incompatible_profile) value.*.blocker = null;
                if (!value.*.terminal() and queue_root) value.*.schedule = .queued;
            }
        }
        fn interruptQueuedRecoveries(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !void {
            var query = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='reconciliation'",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            var pending_ids: ArrayList(state.Digest) = .empty;
            defer pending_ids.deinit(a);
            while (try query.step() == .row) {
                var item = try decodeOwned(state.Reconciliation, a, try query.bytes(0));
                defer item.deinit();
                if (item.value.outcome != .pending) continue;
                if (self.work) |work| if (std.meta.eql(
                    work.task,
                    task_id,
                )) if (work.recovery) |recovery| if (std.meta.eql(
                    recovery.id,
                    item.value.id,
                )) continue;
                try pending_ids.append(a, item.value.id);
            }
            for (pending_ids.items) |id| {
                var item = try record(self, state.Reconciliation, a, "reconciliation", id, task_id);
                defer item.deinit();
                var pending = try record(
                    self,
                    occurrence.Occurrence,
                    a,
                    "occurrence",
                    item.value.occurrence,
                    task_id,
                );
                defer pending.deinit();
                var parent = try task(self, a, task_id);
                defer parent.deinit();
                try finishRecovery(
                    self,
                    a,
                    parent.value,
                    pending.value,
                    item.value,
                    null,
                    .unavailable,
                );
            }
        }
        pub fn resumeTask(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            expected: u64,
        ) !Admission {
            const Request = struct { method: state.Method, task: state.TaskId, revision: u64 };
            const request = try operation(Request, a, .{
                .method = .@"resume",
                .task = task_id,
                .revision = expected,
            });
            if (try replay(self, a, id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var decoded = try task(self, a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            try compatible(self, value);
            if (value.revision != expected) return error.StaleRevision;
            if (value.terminal()) return error.TerminalTask;
            try ensureOwnershipCapacity(self, task_id);
            const rearmed = try resumedOccurrence(self, a, value);
            const children = try workspaceIds(self, a, task_id);
            defer a.free(children);
            var eligible: ArrayList(workspace.Subject) = .empty;
            defer eligible.deinit(a);
            try eligible.append(a, .{ .task = task_id });
            for (children) |child_id| {
                var child = try workspaceWork(self, a, task_id, child_id);
                defer child.deinit();
                if (try workspaceRunnable(
                    self,
                    a,
                    value,
                    child.value,
                )) try eligible.append(a, .{ .task = task_id, .work = child_id });
            }
            try appendControllerResiduals(self, a, task_id, &eligible);
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .queued;
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
            try event(self, &value, .resumed, "{}");
            const admitted =
                try receipt(self, a, .@"resume", id, request, value, .resumed, null, null);
            try persistScheduled(
                self,
                a,
                value,
                expected,
                "task.resume",
                .preserve,
                eligible.items,
            );
            claim(self, task_id);
            return admitted;
        }
        fn resumedOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
        ) !?occurrence.Occurrence {
            var rearmed: ?occurrence.Occurrence = null;
            if (value.current_occurrence) |current| {
                var saved = try record(
                    self,
                    occurrence.Occurrence,
                    a,
                    "occurrence",
                    current,
                    value.id,
                );
                defer saved.deinit();
                if (saved.value.state == .unknown or saved.value.state == .dispatching)
                    return error.UnsettledOccurrence;
                if (saved.value.state == .not_sent) rearmed = try rearm(saved.value, .{
                    .id = current,
                    .task = value.id,
                    .request = saved.value.request,
                });
            }
            return rearmed;
        }
    };
}
