const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const registry = @import("../registry.zig");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Work = task_types.Work;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const projectionBinding = Worker.projectionBinding;
        const record = Records.record;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const store = Lifecycle.store;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn authorizeWorkspace(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            entry: registry.Entry,
            payload: []const u8,
        ) ![]u8 {
            return store(self).project([]u8, a, self.handlers, projectionBinding(
                self,
                initial,
            ), struct {
                authorize: *const fn (registry.ProjectionContext, []const u8) anyerror![]u8,
                payload: []const u8,
                pub fn run(this: @This(), ctx: registry.ProjectionContext) ![]u8 {
                    return this.authorize(ctx, this.payload);
                }
            }{ .authorize = entry.declaration.workspace.?, .payload = payload });
        }
        pub fn authorizeWorkspaceOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            entry: registry.Entry,
            payload: []const u8,
        ) ![]u8 {
            const bytes = try authorizeWorkspace(self, a, initial, entry, payload);
            errdefer a.free(bytes);
            var authorized = try contracts.decodeOwned(workspace.Authorized, a, bytes);
            defer authorized.deinit();
            const command = authorized.value.command;
            if (command == .program and command.program == .adopt)
                return error.ControllerHandoffRequired;
            if (pending.residual != null and !workspaceIsRead(command)) return error.Denied;
            return bytes;
        }
        pub fn workspaceIsRead(command: wc.Command) bool {
            return switch (command) {
                .program => |p| p != .build and p != .specialize and p != .adopt and
                    p != .derive and p != .validate and p != .retain and p != .import,
                .work => |w| w == .inspect or w == .collect or w == .wait,
                .context => |c| c == .inspect or c == .expand,
                .placement => false,
            };
        }
        pub fn workspaceCompiles(command: wc.Command) bool {
            return command == .program and (command.program == .build or
                command.program == .derive or command.program == .validate);
        }
        pub fn appendWorkspaceReference(output: *wp.Range, id: state.Digest) !void {
            if (output.total > 1) try output.append(",");
            // Ref's canonical JSON has only a fixed tag and hexadecimal ID.
            try output.append("{\"id\":\"");
            try output.append(&std.fmt.bytesToHex(id, .lower));
            try output.append("\",\"kind\":\"work\"}");
        }
        pub fn workspaceScopeAt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            watermark: u64,
        ) ![]state.Digest {
            var ids: std.AutoHashMap(state.Digest, void) = .init(a);
            defer ids.deinit();
            var event_arena = std.heap.ArenaAllocator.init(a);
            defer event_arena.deinit();
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            while (try query.step() == .row) {
                _ = event_arena.reset(.retain_capacity);
                var event_value = try contracts.decodeOwned(
                    state.Event,
                    event_arena.allocator(),
                    try query.bytes(0),
                );
                defer event_value.deinit();
                // Scope follows the same publication facts as historical work
                // observations; display payloads cannot create or hide work.
                for (event_value.value.workspace_publications.items) |item| try ids.put(
                    item.work,
                    {},
                );
            }
            const result = try a.alloc(state.Digest, ids.count());
            var iterator = ids.keyIterator();
            var i: usize = 0;
            while (iterator.next()) |id| : (i += 1) result[i] = id.*;
            std.mem.sort(state.Digest, result, {}, struct {
                fn less(_: void, left: state.Digest, right: state.Digest) bool {
                    return std.mem.order(u8, &left, &right) == .lt;
                }
            }.less);
            return result;
        }
        pub fn workspaceParentStopped(self: *const Self, parent: state.Task) bool {
            return parent.terminal() or parent.cancellation != null or
                if (self.remote_stopped_parent) |id| std.meta.eql(id, parent.id) else false;
        }
        pub fn workspaceInteractionAllowed(parent_stopped: bool, child: workspace.Work) bool {
            return !child.terminal() and
                (child.cancellation == null or child.cancellation_applied) and
                (!parent_stopped or child.cancellation_applied);
        }
        pub fn workspaceStoppedAt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            watermark: u64,
        ) !bool {
            if (self.remote_stopped_parent) |id| if (std.meta.eql(id, task_id)) return true;
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                switch (saved.value.kind) {
                    .cancellation_requested, .completed, .failed, .cancelled => return true,
                    else => {},
                }
            }
            return false;
        }
        pub fn workspaceInterruptedAt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            watermark: u64,
        ) !bool {
            var messages: u64 = 0;
            var cancelled = false;
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                switch (saved.value.kind) {
                    .message_queued => messages = try std.math.add(u64, messages, 1),
                    .message_consumed, .message_not_consumed => messages =
                        std.math.sub(u64, messages, 1) catch return error.InvalidArchive,
                    .cancellation_requested => cancelled = true,
                    else => {},
                }
            }
            return messages != 0 or cancelled;
        }
        pub fn freezeWorkspaceWork(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
            retained: bool,
        ) !workspace.WorkObservation {
            var saved = if (retained) try retainedWorkspaceWork(
                self,
                a,
                task_id,
                try wp.identity(ref, .work),
            ) else try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
            defer saved.deinit();
            var work = saved.value;
            if (work.observer) |observer| work.observer =
                try @import("../workspace_observers.zig").copyObserver(a, observer);
            errdefer if (work.observer) |observer|
                @import("../workspace_observers.zig").freeObserver(a, observer);
            work.inputs.items = try a.dupe(state.Reference, work.inputs.items);
            errdefer a.free(work.inputs.items);
            work.runtime_dependencies.items =
                try a.dupe(state.Reference, work.runtime_dependencies.items);
            errdefer a.free(work.runtime_dependencies.items);
            if (work.runtime_trace) |*trace| trace.dependencies.items =
                try a.dupe(state.Reference, trace.dependencies.items);
            errdefer if (work.runtime_trace) |trace| a.free(trace.dependencies.items);
            if (work.outer_operation) |*pending| pending.dependencies.items =
                try a.dupe(state.Reference, pending.dependencies.items);
            errdefer if (work.outer_operation) |pending| a.free(pending.dependencies.items);
            if (work.cancellation) |reason| work.cancellation = .{
                .bytes = try a.dupe(u8, reason.bytes),
            };
            errdefer if (work.cancellation) |reason| a.free(reason.bytes);
            if (work.guard) |guard| work.guard = try copyWorkspaceGuard(a, guard);
            errdefer if (work.guard) |guard| {
                if (guard.failure) |failure| a.free(failure.bytes);
                if (guard.reference_operation) |reference| a.free(reference.dependencies.items);
            };
            var pending: ?occurrence.Occurrence = null;
            if (work.current_occurrence) |id| {
                var decoded =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, task_id);
                defer decoded.deinit();
                pending = decoded.value;
            }
            return .{ .work = work, .occurrence = pending };
        }
        pub fn copyWorkspaceGuard(
            a: std.mem.Allocator,
            original: workspace.Guard,
        ) !workspace.Guard {
            var guard = original;
            if (guard.failure) |failure|
                guard.failure = .{ .bytes = try a.dupe(u8, failure.bytes) };
            errdefer if (guard.failure) |failure| a.free(failure.bytes);
            if (guard.reference_operation) |*pending|
                pending.dependencies.items =
                    try a.dupe(state.Reference, pending.dependencies.items);
            return guard;
        }
        pub fn workPublication(
            a: std.mem.Allocator,
            observed: workspace.WorkObservation,
        ) !state.WorkPublication {
            const bytes = try contracts.encodeOwned(workspace.WorkObservation, a, observed);
            defer a.free(bytes);
            return .{
                .observer = observed.work.observer,
                .work = observed.work.id,
                .execution_revision = observed.work.execution_revision,
                .control_revision = observed.work.control_revision,
                .runtime = observed.work.runtime,
                .realization_revision = observed.work.realization_revision,
                .runtime_capsule = observed.work.runtime_capsule,
                .runtime_trace = observed.work.runtime_trace != null,
                .outer_cursor = observed.work.outer_cursor,
                .guard = observed.work.guard,
                .guest_work = observed.work.guest_work,
                .outer_operation = if (observed.work.outer_operation) |pending|
                    pending.capsule
                else
                    null,
                .checkpoint = observed.work.checkpoint,
                .observation = storage.digest(bytes),
                .control = workspace.ControlObservation.from(observed),
            };
        }
        pub fn samePublication(
            a: std.mem.Allocator,
            declared: state.WorkPublication,
            observed: state.WorkPublication,
        ) !bool {
            const left = try contracts.encodeOwned(state.WorkPublication, a, declared);
            defer a.free(left);
            const right = try contracts.encodeOwned(state.WorkPublication, a, observed);
            defer a.free(right);
            return same(left, right);
        }
        pub fn publicationSchedule(value: workspace.ControlObservation) state.Schedule {
            if (value.outcome == .requested)
                return if ((value.cancellation != null and !value.cancellation_applied) or
                    ((value.instrument or value.trial) and !value.port and
                        value.policy.continuation == .owner_scheduled)) .queued else .parked;
            if (value.outcome == .completed or value.outcome == .failed or
                value.outcome == .cancelled)
                return .parked;
            return if (value.cancellation != null or
                (value.policy.continuation == .owner_scheduled and
                    value.policy.stop != .next_slice and
                    (value.outcome != .yielded or
                        value.policy.stop == .terminal))) .queued else .parked;
        }
        pub fn delegatedControl(
            before: workspace.ControlObservation,
            has_outer: bool,
            guard: ?workspace.Guard,
            policy: workspace.RunPolicy,
        ) workspace.ControlObservation {
            var after = before;
            after.policy = policy;
            if (guard) |binding| if (binding.disposition == .diverged) {
                after.schedule = .parked;
                return after;
            };
            if (!has_outer and before.delivery == .not_sent and (before.instrument or
                before.trial)) after.delivery = .ready;
            const cancel_ready = before.cancellation != null and !before.cancellation_applied and
                (after.delivery == .ready or after.delivery == .awaiting or
                    after.delivery == .not_sent);
            const runnable = has_outer or
                after.delivery == null or
                after.delivery == .settled_reply or
                after.delivery == .captured or
                (after.delivery == .ready and (before.instrument or before.trial)) or cancel_ready;
            after.schedule =
                if (policy.continuation == .explicit_only) .parked else if (after.delivery ==
                .dispatching) .active else if (runnable) .queued else .parked;
            return after;
        }
    };
}
