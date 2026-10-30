const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Ownership = task_types.Ownership;
const Step = task_types.Step;
const Work = task_types.Work;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const compatible = Controller.compatible;
        const controllerResidualIds = Recovery.controllerResidualIds;
        const effectSchedule = Root.effectSchedule;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const persistOccurrence = Root.persistOccurrence;
        const record = Records.record;
        const residualProgressEvent = Residuals.residualProgressEvent;
        const store = Lifecycle.store;
        const subjectPublicationEvent = Records.subjectPublicationEvent;
        const validateControllerReadCut = Replay.validateControllerReadCut;
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        pub fn workspaceWaitReady(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            selection: @FieldType(wc.Work, "wait"),
        ) !bool {
            var ready = parent.messages.items.len != 0 or parent.cancellation != null;
            for (selection.works.items) |ref| {
                var work =
                    try self.workspaceWork(a, parent.id, try wp.identity(ref, .work));
                defer work.deinit();
                ready = ready or
                    work.value.event_watermark > selection.after or
                    work.value.terminal();
            }
            return ready;
        }
        pub fn workspaceWaitWakeups(
            self: *Self,
            a: std.mem.Allocator,
            parent: *state.Task,
            ownership: Ownership,
            wake: *std.ArrayList(workspace.Subject),
        ) !void {
            if (!try hasLocalCustody(self, a, parent.id, null)) return;
            var owned = ownership == .acquire;
            for (self.owned.items) |id| owned = owned or std.meta.eql(id, parent.id);
            if (!owned) return;
            // Custody can retain cancellation while this launch cannot execute
            // the task. Journal writes must not turn that ownership into a wake.
            compatible(self, parent.*) catch |err| switch (err) {
                error.IncompatibleProfile => return,
            };
            if (!parent.terminal()) if (parent.current_occurrence) |id| {
                if (try workspaceWaitReadyAt(self, a, parent.*, id))
                    try wake.append(a, .{ .task = parent.id });
            };
            const ids = try controllerResidualIds(self, a, parent.id);
            defer a.free(ids);
            for (ids) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    parent.id,
                );
                defer residual.deinit();
                if (residual.value.schedule != .parked or
                    residual.value.blocker != .waiting_workspace or
                    !residual.value.cancellation_applied)
                    continue;
                const current = residual.value.current_occurrence orelse continue;
                if (!try workspaceWaitReadyAt(self, a, parent.*, current)) continue;
                residual.value.schedule = .queued;
                residual.value.blocker = null;
                try store(self).putRecord(
                    state.ControllerResidual,
                    "controller_residual",
                    id,
                    parent.id,
                    residual.value,
                );
                try residualProgressEvent(self, a, parent, residual.value);
                try wake.append(a, .{ .task = parent.id, .residual = id });
            }
        }
        fn workspaceWaitReadyAt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
        ) !bool {
            const bytes = (try store(self).recordBytes(
                a,
                "workspace_wait",
                id,
                parent.id,
            )) orelse return false;
            defer a.free(bytes);
            var waiting = try contracts.decodeOwned(workspace.Wait, a, bytes);
            defer waiting.deinit();
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, parent.id);
            defer pending.deinit();
            if (pending.value.state != .ready) return false;
            return workspaceWaitReady(self, a, parent, waiting.value.selection);
        }
        pub fn settleWorkspaceReply(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            observation: wc.Reply,
            evidence: workspace.ReplyEvidence,
        ) !Step {
            const reply = try contracts.encodeOwned(wc.Reply, a, observation);
            defer a.free(reply);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = reply,
            });
            defer a.free(bound);
            // Workspace mutation may have advanced only the parent's control
            // journal. Its root occurrence and checkpoint remain unchanged.
            var fresh = try self.task(a, initial.id);
            defer fresh.deinit();
            var parent = fresh.value;
            if (!std.meta.eql(parent.current_occurrence, initial.current_occurrence))
                return error.StaleOccurrence;
            const attempt = switch (pending.state) {
                .dispatching => |dispatching| dispatching.id,
                else => return error.UnsettledOccurrence,
            };
            const binding: occurrence.Binding = .{
                .id = pending.id,
                .task = initial.id,
                .work = pending.work,
                .residual = pending.residual,
                .request = pending.request,
            };
            const acquired =
                try occurrence.acquired(pending, binding, attempt, storage.digest(bound));
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            try storeWorkspaceReply(self, initial, pending, attempt, evidence, acquired, bound);
            try publishWorkspaceRead(self, a, &parent, fresh.value, pending, evidence);
            try effectSchedule(self, a, &parent, pending, .queued, null);
            try persistOccurrence(
                self,
                a,
                parent,
                fresh.value.revision,
                "workspace.reply",
                pending,
                true,
            );
            return .progressed;
        }
        fn storeWorkspaceReply(
            self: *Self,
            initial: state.Task,
            pending: occurrence.Occurrence,
            attempt: @FieldType(state.Attempt, "id"),
            evidence: workspace.ReplyEvidence,
            acquired: occurrence.Occurrence,
            bound: []const u8,
        ) !void {
            _ = try store(self).putObject(bound);
            try store(self).createRecord(
                workspace.ReplyObservation,
                "workspace_reply",
                pending.id,
                initial.id,
                .{
                    .id = pending.id,
                    .task = initial.id,
                    .attempt = attempt,
                    .request = pending.request_object,
                    .evidence = evidence,
                },
            );
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                initial.id,
                acquired,
            );
        }
        fn publishWorkspaceRead(
            self: *Self,
            a: std.mem.Allocator,
            parent: *state.Task,
            fresh: state.Task,
            pending: occurrence.Occurrence,
            evidence: workspace.ReplyEvidence,
        ) !void {
            if (evidence == .read and evidence.read != .immutable) {
                var event_data = json.object();
                try json.put(
                    a,
                    &event_data,
                    "occurrence_id",
                    json.string(try a.dupe(u8, &std.fmt.bytesToHex(pending.id, .lower))),
                );
                const cut: ?state.ControllerReadCut =
                    if (evidence.read == .controller) .from(fresh) else null;
                try validateControllerReadCut(evidence.read, cut);
                try subjectPublicationEvent(
                    self,
                    parent,
                    .workspace_read,
                    try json.canonical(a, event_data),
                    &.{},
                    &.{},
                    null,
                    cut,
                    null,
                );
            }
        }
    };
}
