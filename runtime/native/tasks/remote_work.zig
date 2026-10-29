const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const RemoteWorkState = task_types.RemoteWorkState;
const Work = task_types.Work;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const activeObserver = Observers.activeObserver;
        const placementControlExpanded = PlacementControl.placementControlExpanded;
        const placementQueue = Transport.placementQueue;
        const record = Records.record;
        const retainedWorkspaceDisposed = Tasks.retainedWorkspaceDisposed;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const retainsController = Recovery.retainsController;
        const store = Lifecycle.store;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const PlacementControl = @import("placement_control.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn remoteDisposed(value: @import("../placement.zig").WorkState) bool {
            return !value.observer_active and (value.outcome == .completed or
                value.outcome == .failed or value.outcome == .cancelled) and value.cleanup_complete;
        }
        pub fn stopRemoteObserverOne(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !bool {
            var child = try retainedWorkspaceWork(self, a, task_id, work_id);
            defer child.deinit();
            if (!activeObserver(self, child.value)) return false;
            var remote = try remoteWorkState(self, a, task_id, work_id);
            defer remote.deinit();
            if (remote.latest) |saved| if (!saved.value.report.?.value.work_state.?.observer_active)
                return false;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            return settleRemoteWork(self, a, parent.value, work_id);
        }
        pub fn remoteWorkState(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !RemoteWorkState {
            var result: RemoteWorkState = .{};
            errdefer result.deinit();
            var custody =
                try @import("../placement_journal.zig").custody(store(self), a, .{
                    .task = task_id,
                    .work = work_id,
                }) orelse return result;
            defer custody.deinit();
            if (custody.value.phase != .away) return result;
            var controller_custody = try @import("../placement_journal.zig").custody(
                store(self),
                a,
                .{ .task = task_id },
            ) orelse return result;
            defer controller_custody.deinit();
            var query = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='placement_control' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                const bytes = try query.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                try observeRemoteControl(
                    self,
                    a,
                    task_id,
                    work_id,
                    bytes[0..32].*,
                    custody.value,
                    controller_custody.value,
                    &result,
                );
            }
            return result;
        }
        fn observeRemoteControl(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
            id: state.Digest,
            custody: @import("../placement.zig").Custody,
            controller_custody: @import("../placement.zig").Custody,
            result: *RemoteWorkState,
        ) !void {
            const p = @import("../placement.zig");
            var saved =
                try record(self, p.ControlRecord, a, "placement_control", id, task_id);
            errdefer saved.deinit();
            const control = saved.value.control.value;
            if (!std.meta.eql(control.subject.work, work_id) or !std.meta.eql(
                control.controller,
                controller_custody.owner,
            ) or control.controller_epoch != controller_custody.epoch) {
                saved.deinit();
                return;
            }
            if (saved.value.report) |report| {
                if (!std.meta.eql(report.value.executor, custody.owner) or
                    report.value.custody_epoch != custody.epoch)
                {
                    saved.deinit();
                    return;
                }
                if (report.value.work_state) |observed| {
                    try p.matchReport(a, control, saved.value.route.items, report);
                    if (!std.meta.eql(report.value.control, try p.digest(p.Control, a, control)) or
                        report.value.custody_epoch != custody.epoch)
                    {
                        return error.InvalidRemoteCommand;
                    }
                    if (result.latest == null or
                        observed.observed_at >=
                            result.latest.?.value.report.?.value.work_state.?.observed_at)
                    {
                        if (result.latest) |*old| old.deinit();
                        result.latest = saved;
                        return;
                    }
                }
            } else {
                result.pending = true;
                if (saved.value.last_error == null) result.retry_pending = saved.value.id;
            }
            saved.deinit();
        }
        pub fn settleRemoteWork(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work_id: state.Digest,
        ) !bool {
            const cancellation_revision: ?u64 =
                if (parent.cancellation !=
                null) try parentCancellationRevision(self, a, parent.id) else null;
            var observed = try remoteWorkState(self, a, parent.id, work_id);
            defer observed.deinit();
            if (observed.pending) {
                if (observed.retry_pending) |id| {
                    try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
                    placementQueue(self, parent.id, id, .control);
                }
                return false;
            }
            if (try retainedWorkspaceDisposed(self, a, parent.id, work_id)) return false;
            const reference = try wp.reference(a, .work, work_id);
            var command: wc.Work = .{ .inspect = .{ .work = reference } };
            var predecessor: state.Digest = @splat(0);
            command = try remoteSettlementCommand(
                self,
                a,
                parent,
                work_id,
                reference,
                cancellation_revision,
                observed,
                &predecessor,
            ) orelse return false;
            return publishRemoteSettlement(
                self,
                a,
                parent,
                work_id,
                cancellation_revision,
                predecessor,
                command,
            );
        }
        fn remoteSettlementCommand(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work_id: state.Digest,
            reference: anytype,
            cancellation_revision: ?u64,
            observed: RemoteWorkState,
            predecessor: *state.Digest,
        ) !?wc.Work {
            const p = @import("../placement.zig");
            var command: wc.Work = .{ .inspect = .{ .work = reference } };
            if (observed.latest) |saved| {
                const report = saved.value.report.?;
                const current = report.value.work_state.?;
                if (remoteDisposed(current)) return null;
                predecessor.* = try p.digest(p.Report, a, report.value);
                const expected: wc.Expected = .{
                    .work = reference,
                    .execution_revision = current.execution_revision,
                    .control_revision = current.control_revision,
                };
                // A signed rejection at unchanged revisions needs operator
                // reconciliation; do not generate an unbounded retry stream.
                if (report.value.reply.disposition == .rejected and
                    saved.value.control.value.cleanup_request == cancellation_revision)
                {
                    const prior = switch (saved.value.control.value.command) {
                        .cancel => |v| v.expected,
                        .pump => |v| v.expected,
                        .park, .stop_observing => |v| v,
                        else => null,
                    };
                    if (prior == null) return null;
                    if (prior) |revision|
                        if (revision.execution_revision == expected.execution_revision and
                            revision.control_revision == expected.control_revision)
                            return null;
                }
                if (current.observer_active) {
                    command = .{ .stop_observing = expected };
                } else if (cancellation_revision) |revision| {
                    const acknowledged =
                        try remoteCancellationAcknowledged(self, a, parent.id, work_id, revision);
                    if (acknowledged and current.explicitly_parked) return null;
                    command = if (current.cancellation == null or !acknowledged) .{ .cancel = .{
                        .expected = expected,
                        .reason = parent.cancellation.?,
                    } } else .{ .pump = .{ .expected = expected, .base_quantum = 65536 } };
                } else {
                    if (current.explicitly_parked) {
                        if (current.parkSettled()) return null;
                    } else command = if (current.cancellation == null) .{
                        .park = expected,
                    } else .{ .pump = .{ .expected = expected, .base_quantum = 65536 } };
                }
            }
            return command;
        }
        fn publishRemoteSettlement(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work_id: state.Digest,
            cancellation_revision: ?u64,
            predecessor: state.Digest,
            command: wc.Work,
        ) !bool {
            const p = @import("../placement.zig");
            const identity = if (cancellation_revision) |revision|
                try operation(struct {
                    work: state.Digest,
                    cancellation: state.Reason,
                    request_revision: u64,
                    predecessor: state.Digest,
                }, a, .{
                    .work = work_id,
                    .cancellation = parent.cancellation.?,
                    .request_revision = revision,
                    .predecessor = predecessor,
                })
            else
                try operation(struct {
                    work: state.Digest,
                    completion_revision: u64,
                    predecessor: state.Digest,
                }, a, .{
                    .work = work_id,
                    .completion_revision = parent.execution_revision,
                    .predecessor = predecessor,
                });
            const operation_name = try std.fmt.allocPrint(a, "{s}-{s}", .{
                if (cancellation_revision != null) "cleanup" else "close",
                std.fmt.bytesToHex(identity, .lower),
            });
            defer a.free(operation_name);
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            const bytes = placementControlExpanded(
                self,
                a,
                operation_name,
                parent.id,
                command,
                null,
                true,
                cancellation_revision,
            ) catch |err| switch (err) {
                error.CustodyNotRemote, error.UnsupportedCapability, error.Denied => return false,
                else => return err,
            };
            defer a.free(bytes);
            var signed = try contracts.decodeOwned(p.Signed(p.Control), a, bytes);
            defer signed.deinit();
            const id = p.controlId(signed.value.value);
            var saved =
                try record(self, p.ControlRecord, a, "placement_control", id, parent.id);
            defer saved.deinit();
            if (saved.value.report != null) return false;
            placementQueue(self, parent.id, id, .control);
            return true;
        }
        fn parentCancellationRevision(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !u64 {
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? ORDER BY e.seq DESC",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                if (event_value.value.kind == .cancellation_requested)
                    return event_value.value.revision;
            }
            return error.CorruptState;
        }
        fn remoteCancellationAcknowledged(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
            revision: u64,
        ) !bool {
            const p = @import("../placement.zig");
            var events = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.revision>? ORDER BY e.seq DESC",
                &.{ .{ .blob = &task_id }, .{ .integer = @intCast(revision) } },
            );
            defer events.deinit();
            while (try events.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try events.bytes(0));
                defer event_value.deinit();
                const concerns_child = for (event_value.value.workspace_publications.items) |item| {
                    if (std.meta.eql(item.work, work_id)) break true;
                } else false;
                if (!concerns_child) continue;
                const reference = event_value.value.workspace_command orelse continue;
                const bytes = try store(self).object(a, reference, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value == .control and command.value.control.command == .cancel)
                    return true;
            }
            var query = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='placement_control'",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(p.ControlRecord, a, try query.bytes(0));
                defer saved.deinit();
                const control = saved.value.control.value;
                if (control.command != .cancel or control.cleanup_request != revision or
                    !std.meta.eql(control.subject.work, work_id)) continue;
                if (saved.value.report) |report| {
                    try p.matchReport(a, control, saved.value.route.items, report);
                    if (report.value.reply.disposition == .observed and
                        try retainsController(self, a, control)) return true;
                }
            }
            return false;
        }
    };
}
