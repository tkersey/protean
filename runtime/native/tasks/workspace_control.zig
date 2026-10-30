const std = @import("std");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Work = task_types.Work;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const compatible = Controller.compatible;
        const delegatedControl = Access.delegatedControl;
        const observerAdvanceAllowed = Observers.observerAdvanceAllowed;
        const queueControllerTrial = Execution.queueControllerTrial;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const workspaceAdvance = Execution.workspaceAdvance;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceContinuation = Execution.workspaceContinuation;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspacePumpWork = Execution.workspacePumpWork;
        const writeWorkspaceWork = Publication.writeWorkspaceWork;
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        fn workspaceObservationCancellation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            reason: state.Reason,
            operation_id: []const u8,
            request: state.Digest,
            command: workspace.PublicationCommand,
        ) !?Admission {
            if (reason.bytes.len > 256 or !std.unicode.utf8ValidateSlice(reason.bytes))
                return error.InvalidParams;
            const observation_waiting = waiting: {
                observerAdvanceAllowed(self, a, initial) catch |err| switch (err) {
                    error.ObservationBlocked => break :waiting true,
                    else => return err,
                };
                break :waiting false;
            };
            if (!observation_waiting) return null;
            var value = initial;
            if (value.cancellation == null) value.cancellation = reason;
            value.guard = null;
            value.schedule = .queued;
            value.blocker = .observation_blocked;
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try store(self).begin();
            defer store(self).rollback();
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
            if (self.work) |*active| if (std.meta.eql(active.subject_work, value.id) and
                std.meta.eql(active.task, value.task))
            {
                active.cancel_requested = true;
            };
            return admitted;
        }
        fn workspaceCancelPending(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            pending: occurrence.Occurrence,
            operation_id: []const u8,
            request: state.Digest,
            publication_command: workspace.PublicationCommand,
        ) !?Admission {
            var value = initial;
            if (pending.state == .dispatching or pending.state == .unknown or
                pending.state == .captured)
            {
                value.schedule = switch (pending.state) {
                    .captured => .queued,
                    .dispatching => .active,
                    else => .parked,
                };
                value.event_watermark = parent.event_high + 1;
                try self.runnable.ensureUnusedCapacity(self.allocator, 2);
                try store(self).begin();
                defer store(self).rollback();
                try writeWorkspaceWork(self, &value, .replace);
                const admitted = try workspaceCommit(
                    self,
                    a,
                    parent,
                    operation_id,
                    request,
                    value.id,
                    .work,
                    try snapshotRecord(
                        self,
                        workspace.Work,
                        a,
                        "workspace_work",
                        value.id,
                        value.task,
                    ),
                    publication_command,
                );
                if (self.work) |*active| if (std.meta.eql(active.subject_work, value.id) and
                    std.meta.eql(active.task, value.task))
                {
                    active.cancel_requested = true;
                };
                return admitted;
            }
            return null;
        }
        fn workspaceCancelControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            reason: state.Reason,
            operation_id: []const u8,
            request: state.Digest,
            publication_command: workspace.PublicationCommand,
        ) !Admission {
            var value = initial;
            value.guard = null;
            if (reason.bytes.len > 256 or !std.unicode.utf8ValidateSlice(reason.bytes))
                return error.InvalidParams;
            if (value.cancellation == null) value.cancellation = reason;
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            if (value.current_occurrence) |id| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, value.task);
                defer pending.deinit();
                if (try workspaceCancelPending(
                    self,
                    a,
                    parent,
                    value,
                    pending.value,
                    operation_id,
                    request,
                    publication_command,
                )) |admitted| return admitted;
                if (pending.value.state == .settled_reply) {
                    const reply = try store(self).acquiredObject(
                        a,
                        pending.value.state.settled_reply.reply,
                        null,
                    );
                    defer a.free(reply);
                    return workspaceAdvance(
                        self,
                        a,
                        parent,
                        value,
                        .{ .reply = reply },
                        operation_id,
                        request,
                        publication_command,
                    );
                }
            }
            return workspaceAdvance(
                self,
                a,
                parent,
                value,
                .{ .cancel = .{ .text = value.cancellation.?.bytes } },
                operation_id,
                request,
                publication_command,
            );
        }
        fn workspaceAdvanceControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            operation_id: []const u8,
            request: state.Digest,
            publication_command: workspace.PublicationCommand,
        ) !Admission {
            if (try queueControllerTrial(
                self,
                a,
                parent,
                value,
                operation_id,
                request,
                publication_command,
            )) |admitted| return admitted;
            if (value.current_occurrence) |id| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, value.task);
                defer pending.deinit();
                if (pending.value.state != .settled_reply) return error.WaitingInput;
                const reply = try store(self).acquiredObject(
                    a,
                    pending.value.state.settled_reply.reply,
                    null,
                );
                defer a.free(reply);
                return workspaceAdvance(
                    self,
                    a,
                    parent,
                    value,
                    .{ .reply = reply },
                    operation_id,
                    request,
                    publication_command,
                );
            }
            return workspaceAdvance(
                self,
                a,
                parent,
                value,
                workspaceContinuation(value),
                operation_id,
                request,
                publication_command,
            );
        }
        fn workspaceDelegateControl(
            self: *Self,
            a: std.mem.Allocator,
            value: *workspace.Work,
            policy: workspace.RunPolicy,
        ) !?occurrence.Occurrence {
            var rearmed: ?occurrence.Occurrence = null;
            var before =
                workspace.ControlObservation.from(.{
                    .work = value.*,
                    .occurrence = null,
                });
            if (value.current_occurrence) |id| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, value.task);
                defer pending.deinit();
                before.delivery = std.meta.activeTag(pending.value.state);
                const delegated =
                    delegatedControl(before, value.outer_operation != null, value.guard, policy);
                if (delegated.delivery != before.delivery) {
                    rearmed = try occurrence.rearm(pending.value, .{
                        .id = id,
                        .task = value.task,
                        .work = value.id,
                        .request = pending.value.request,
                    });
                }
            }
            const delegated =
                delegatedControl(before, value.outer_operation != null, value.guard, policy);
            value.policy = delegated.policy;
            value.schedule = delegated.schedule;
            return rearmed;
        }
        fn workspaceScheduleControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            command: workspace.Command,
            operation_id: []const u8,
            request: state.Digest,
            publication_command: workspace.PublicationCommand,
        ) !Admission {
            var value = initial;
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            var rearmed: ?occurrence.Occurrence = null;
            switch (command) {
                .park => value.schedule = .parked,
                .delegate => |policy| {
                    rearmed = try workspaceDelegateControl(self, a, &value, policy);
                },
                .advance, .cancel => unreachable,
            }
            try store(self).begin();
            defer store(self).rollback();
            if (rearmed) |pending| try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                value.task,
                pending,
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
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, value.task),
                publication_command,
            );
            return admitted;
        }
        fn workspaceControlAdmitted(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            command: workspace.Command,
            operation_id: []const u8,
            request: state.Digest,
            publication_command: workspace.PublicationCommand,
        ) !Admission {
            var value = initial;
            if (command == .cancel) if (try workspaceObservationCancellation(
                self,
                a,
                parent,
                value,
                command.cancel,
                operation_id,
                request,
                publication_command,
            )) |admitted| return admitted;
            if (value.outer_operation != null and (command == .advance or command == .cancel)) {
                if (command == .cancel) {
                    if (command.cancel.bytes.len > 256 or !std.unicode.utf8ValidateSlice(
                        command.cancel.bytes,
                    )) return error.InvalidParams;
                    if (value.cancellation == null) value.cancellation = command.cancel;
                    value.control_revision = try std.math.add(u64, value.control_revision, 1);
                }
                return workspacePumpWork(
                    self,
                    a,
                    parent,
                    value,
                    65536,
                    operation_id,
                    request,
                    publication_command,
                );
            }
            if (command == .cancel) return workspaceCancelControl(
                self,
                a,
                parent,
                value,
                command.cancel,
                operation_id,
                request,
                publication_command,
            );
            if (command == .advance) return workspaceAdvanceControl(
                self,
                a,
                parent,
                value,
                operation_id,
                request,
                publication_command,
            );
            return workspaceScheduleControl(
                self,
                a,
                parent,
                value,
                command,
                operation_id,
                request,
                publication_command,
            );
        }
        pub fn workspaceControl(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            work_id: state.Digest,
            expected_execution: u64,
            expected_control: u64,
            command: workspace.Command,
        ) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            const Request = workspace.ControlRequest;
            const request = try operation(Request, a, .{
                .task = task_id,
                .work = work_id,
                .execution = expected_execution,
                .control = expected_control,
                .command = command,
            });
            const publication_command: workspace.PublicationCommand = .{ .control = .{
                .execution = expected_execution,
                .control = expected_control,
                .command = command,
            } };
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, work_id);
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            const value = saved.value;
            if (value.execution_revision != expected_execution or
                value.control_revision != expected_control)
                return error.StaleRevision;
            if (value.terminal()) return error.InvalidState;
            if (command != .park and command != .cancel and
                workspaceParentStopped(self, parent.value)) return error.InvalidState;
            return workspaceControlAdmitted(
                self,
                a,
                parent.value,
                value,
                command,
                operation_id,
                request,
                publication_command,
            );
        }
        pub fn parkWorkspaceOnClose(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !void {
            try requireCustody(self, a, task_id, work_id);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            if (saved.value.schedule == .parked) return;
            saved.value.schedule = .parked;
            saved.value.control_revision = try std.math.add(u64, saved.value.control_revision, 1);
            saved.value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            try store(self).begin();
            defer store(self).rollback();
            try writeWorkspaceWork(self, &saved.value, .replace);
            _ = try workspaceCommit(
                self,
                a,
                parent.value,
                null,
                @splat(0),
                work_id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", work_id, task_id),
                null,
            );
        }
    };
}
