const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const discovery = @import("../discovery.zig");
const workspace = @import("../workspace_state.zig");
const archive_api = @import("../archive.zig");
const task_types = @import("types.zig");
const FrozenInputs = task_types.FrozenInputs;
const Status = task_types.Status;
const Work = task_types.Work;
const cleanupComplete = task_types.cleanupComplete;
const operation = task_types.operation;
const readFrozenInputs = task_types.readFrozenInputs;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const compatibleApplication = Admission.compatibleApplication;
        const controllerResidualsSettled = Recovery.controllerResidualsSettled;
        const hasFrozenCustody = Lifecycle.hasFrozenCustody;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const occurrenceImage = Root.occurrenceImage;
        const record = Records.record;
        const remoteDisposed = RemoteWork.remoteDisposed;
        const remoteWorkState = RemoteWork.remoteWorkState;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const stopLocalWorkspaceObserver = Recovery.stopLocalWorkspaceObserver;
        const store = Lifecycle.store;
        const workspaceIds = Recovery.workspaceIds;
        const Admission = @import("admission.zig").Operations(Types, Self);
        const Cancellation = @import("cancellation.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const RemoteWork = @import("remote_work.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Control = @import("workspace_control.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn task(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
        ) !contracts.Decoded(state.Task) {
            try allowed(self);
            const bytes = try store(self).taskBytes(a, id);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Task, a, bytes);
            errdefer decoded.deinit();
            if (!same(decoded.value.principal.bytes, self.profile.authority.principal) or !same(
                decoded.value.tenant.bytes,
                self.profile.authority.tenant,
            )) return error.Denied;
            if (!same(&decoded.value.id, &id)) return error.CorruptState;
            return decoded;
        }
        pub fn schemaArtifact(self: *Self, id: state.Digest) !discovery.Artifact {
            try allowed(self);
            return self.application.schemaArtifact(id);
        }
        pub fn projectedArtifact(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !state.Reference {
            var value = try task(self, a, task_id);
            defer value.deinit();
            try compatibleApplication(self, value.value);
            if (!same(&value.value.runtime_identity, &self.profile.runtime_identity))
                return error.ArtifactUnavailable;
            const owners = try store(self).projectionOwners(a, task_id, id);
            defer a.free(owners);
            for (owners) |owner| {
                var attempt =
                    try record(self, state.Attempt, a, "attempt", owner.attempt, task_id);
                defer attempt.deinit();
                if (!std.meta.eql(attempt.value.profile, value.value.profile))
                    return error.CorruptState;
                const bytes = try store(self).object(a, attempt.value.request, null);
                defer a.free(bytes);
                var request = try data.invocation.decode(data.invocation.Request, a, bytes);
                defer request.deinit();
                var pending = try record(
                    self,
                    occurrence.Occurrence,
                    a,
                    "occurrence",
                    attempt.value.occurrence,
                    task_id,
                );
                defer pending.deinit();
                const entry = try self.handlers.resolve(
                    request.value,
                    try occurrenceImage(self, a, value.value, pending.value),
                );
                if (entry.declaration.public_outputs) return owner.object;
            }
            return error.ArtifactUnavailable;
        }
        pub fn frozenInputs(self: *Self, a: std.mem.Allocator, id: state.TaskId) !FrozenInputs {
            // Rebuild adapter state from owned immutable data, never from the
            // original filesystem paths. This read does not resume or grant work.
            var decoded = try task(self, a, id);
            defer decoded.deinit();
            return readFrozenInputs(a, decoded.value, store(self));
        }
        pub fn frozenArchiveInputs(
            self: *Self,
            a: std.mem.Allocator,
            path: []const u8,
        ) !FrozenInputs {
            // Supply only the owned launch data needed to configure an import.
            // This preview admits no task, grant, resident or external operation.
            try allowed(self);
            var reader = try archive_api.Reader.open(a, path);
            defer reader.deinit();
            const bytes = try reader.object(a, reader.manifest.value.task, null);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Task, a, bytes);
            defer decoded.deinit();
            if (!same(decoded.value.principal.bytes, self.profile.authority.principal) or !same(
                decoded.value.tenant.bytes,
                self.profile.authority.tenant,
            )) return error.Denied;
            return readFrozenInputs(a, decoded.value, &reader);
        }
        pub fn pendingQuestion(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
        ) !?contracts.Decoded(state.Question) {
            var value = try task(self, a, id);
            defer value.deinit();
            const current = value.value.current_occurrence orelse return null;
            var saved =
                try record(self, occurrence.Occurrence, a, "occurrence", current, id);
            defer saved.deinit();
            const question_id = switch (saved.value.state) {
                .awaiting => |waiting| waiting.question,
                else => return null,
            };
            return try record(self, state.Question, a, "question", question_id, id);
        }
        pub fn status(self: *Self, a: std.mem.Allocator, value: state.Task) !Status {
            switch (value.outcome_kind) {
                .completed => return .completed,
                .failed => return .failed,
                .cancelled => return .cancelled,
                else => {},
            }
            if (value.current_occurrence) |id| {
                var saved =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, value.id);
                defer saved.deinit();
                if (saved.value.state == .unknown or (saved.value.state == .dispatching and
                    (self.work == null or !same(&self.work.?.occurrence, &id)))) return .unknown;
                if (saved.value.state == .awaiting and
                    (value.cancellation == null or value.cancellation_applied))
                    return .waiting_input;
            }
            if (value.blocker != null) return .blocked;
            if (value.cancellation != null) return .cancelling;
            // Worker-owned execution is active while ineligible for another turn.
            if (self.work) |work| if (same(&work.task, &value.id)) return .running;
            for (self.runnable.items) |subject| if (subject.work == null and same(
                &subject.task,
                &value.id,
            )) return if (value.schedule == .queued) .queued else .running;
            return .parked;
        }
        pub fn taskCleanupComplete(self: *Self, a: std.mem.Allocator, value: state.Task) !bool {
            if (!value.terminal()) return false;
            const bytes = try store(self).object(a, value.outcome, null);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            return cleanupComplete(outcome.value) and try associatedWorkDisposed(self, a, value.id);
        }
        pub fn associatedWorkDisposed(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !bool {
            return try controllerResidualsSettled(self, a, task_id) and
                try workspaceSettled(self, a, task_id, true, true, false);
        }
        pub fn workspaceSettled(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            require_disposal: bool,
            include_remote: bool,
            require_park: bool,
        ) !bool {
            var query = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            while (try query.step() == .row) {
                const bytes = try query.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                const id = bytes[0..32].*;
                _ = arena.reset(.retain_capacity);
                const temporary = arena.allocator();
                if (!try hasLocalCustody(self, temporary, task_id, id)) {
                    if (try hasFrozenCustody(self, temporary, task_id, id)) {
                        var frozen =
                            try retainedWorkspaceWork(self, temporary, task_id, id);
                        defer frozen.deinit();
                        if (require_disposal or require_park or frozen.value.cancellation != null)
                            return false;
                    }
                    if (!include_remote) continue;
                    var remote = try remoteWorkState(self, temporary, task_id, id);
                    defer remote.deinit();
                    if (remote.pending) return false;
                    if (try retainedWorkspaceDisposed(self, temporary, task_id, id)) continue;
                    if (require_disposal) {
                        const observed =
                            if (remote.latest) |saved|
                                saved.value.report.?.value.work_state.?
                            else
                                return false;
                        if (!remoteDisposed(observed)) return false;
                    } else if (require_park) {
                        const observed =
                            if (remote.latest) |saved|
                                saved.value.report.?.value.work_state.?
                            else
                                return false;
                        if (!remoteDisposed(observed) and !observed.parkSettled())
                            return false;
                    }
                    continue;
                }
                var child = try retainedWorkspaceWork(self, temporary, task_id, id);
                defer child.deinit();
                if (!try workspaceWorkSettled(
                    self,
                    temporary,
                    child.value,
                    require_disposal,
                    require_park,
                )) return false;
            }
            return true;
        }
        pub fn workspaceWorkSettled(
            self: *Self,
            a: std.mem.Allocator,
            child: workspace.Work,
            require_disposal: bool,
            require_park: bool,
        ) !bool {
            if (require_disposal and child.observer != null and !child.observer.?.stopped and
                child.observer.?.successor == null) return false;
            if (child.terminal()) {
                const outcome_bytes = try store(self).object(a, child.outcome, null);
                defer a.free(outcome_bytes);
                var outcome = try data.invocation.decode(data.invocation.Outcome, a, outcome_bytes);
                defer outcome.deinit();
                return cleanupComplete(outcome.value);
            }
            if (require_disposal or child.cancellation != null or (require_park and
                child.schedule != .parked))
                return false;
            if (child.current_occurrence) |current| {
                var pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", current, child.task);
                defer pending.deinit();
                switch (pending.value.state) {
                    .dispatching, .unknown, .captured, .settled_reply => return false,
                    else => {},
                }
            }
            return true;
        }
        pub fn retainedWorkspaceDisposed(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !bool {
            var child = try retainedWorkspaceWork(self, a, task_id, work_id);
            defer child.deinit();
            return child.value.terminal() and
                try workspaceWorkSettled(self, a, child.value, true, false);
        }
        pub fn shutdownIncomplete(self: *Self, a: std.mem.Allocator) !bool {
            for (self.owned.items) |id| {
                var decoded = try task(self, a, id);
                defer decoded.deinit();
                const value = decoded.value;
                const controller = try hasLocalCustody(self, a, id, null) or
                    try hasFrozenCustody(self, a, id, null);
                if (controller) {
                    if (value.terminal()) {
                        const bytes = try store(self).object(a, value.outcome, null);
                        defer a.free(bytes);
                        var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                        defer outcome.deinit();
                        if (!cleanupComplete(outcome.value)) return true;
                    } else if (self.shutdown_cancel_requested or try status(
                        self,
                        a,
                        value,
                    ) == .unknown or value.cancellation != null) return true;
                }
                if (controller and !try controllerResidualsSettled(self, a, id))
                    return true;
                if (!try workspaceSettled(
                    self,
                    a,
                    id,
                    self.shutdown_cancel_requested or (controller and value.cancellation != null),
                    controller,
                    controller and value.terminal(),
                )) return true;
            }
            return false;
        }
        pub fn cancelOwned(
            self: *Self,
            a: std.mem.Allocator,
            instance: []const u8,
            reason: []const u8,
        ) !void {
            // Launch ownership names recovery tasks. Actual cancellation authority
            // is the local controller or the independently held local work subjects.
            self.shutdown_cancel_requested = true;
            const owned = try a.dupe(state.TaskId, self.owned.items);
            defer a.free(owned);
            for (owned) |id| {
                if (try hasLocalCustody(self, a, id, null)) {
                    const operation_id = try std.fmt.allocPrint(a, "shutdown-{s}-{s}", .{
                        instance,
                        std.fmt.bytesToHex(id, .lower),
                    });
                    defer a.free(operation_id);
                    _ = try self.requestCancel(a, operation_id, id, reason);
                    continue;
                }
                const children = try workspaceIds(self, a, id);
                defer a.free(children);
                for (children) |work_id| {
                    if (!try hasLocalCustody(self, a, id, work_id)) continue;
                    var child = try self.workspaceWork(a, id, work_id);
                    defer child.deinit();
                    if (try stopLocalWorkspaceObserver(self, a, child.value)) {
                        const updated = try self.workspaceWork(a, id, work_id);
                        child.deinit();
                        child = updated;
                    }
                    if (child.value.terminal()) continue;
                    const Identity = struct {
                        instance: contracts.Bytes(null),
                        task: state.TaskId,
                        work: state.Digest,
                    };
                    const identity = try operation(Identity, a, .{
                        .instance = .{ .bytes = instance },
                        .task = id,
                        .work = work_id,
                    });
                    const operation_id = try std.fmt.allocPrint(a, "shutdown-work-{s}", .{
                        std.fmt.bytesToHex(identity, .lower),
                    });
                    defer a.free(operation_id);
                    _ = try self.workspaceControl(
                        a,
                        operation_id,
                        id,
                        work_id,
                        child.value.execution_revision,
                        child.value.control_revision,
                        .{ .cancel = .{ .bytes = reason } },
                    );
                }
            }
        }
        pub fn placementActive(self: *const Self) bool {
            return self.placement_job != null or self.placement_pending.items.len != 0;
        }
    };
}
