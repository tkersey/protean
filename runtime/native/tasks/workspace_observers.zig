const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Step = task_types.Step;
const Work = task_types.Work;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const capsuleDependencies = Realization.capsuleDependencies;
        const compatible = Controller.compatible;
        const inspectionRuntime = Inspection.inspectionRuntime;
        const inspectionSelection = Inspection.inspectionSelection;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const runtimeProvenance = Guards.runtimeProvenance;
        const samePublication = Access.samePublication;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const subjectRemove = Scheduling.subjectRemove;
        const task = Tasks.task;
        const validateWorkspacePublication = Snapshots.validateWorkspacePublication;
        const workPublication = Access.workPublication;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceContextMutation = Contexts.workspaceContextMutation;
        const workspaceIds = Recovery.workspaceIds;
        const workspaceInspectionBytes = Inspection.workspaceInspectionBytes;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspaceStartAdmitted = Start.workspaceStartAdmitted;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const writeWorkspaceWork = Publication.writeWorkspaceWork;
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Guards = @import("workspace_guards.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        const ResidualValidation =
            @import("workspace_residual_validation.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Start = @import("workspace_start.zig").Operations(Types, Self);
        pub fn activeObserver(_: *Self, work: workspace.Work) bool {
            const observer = work.observer orelse return false;
            return !observer.stopped and observer.successor == null;
        }
        pub fn observerHeadIndex(parent: state.Task, id: state.Digest) ?usize {
            for (parent.observer_heads.items, 0..) |head, index|
                if (std.meta.eql(head, id)) return index;
            return null;
        }
        pub fn observerHeadOrder(_: void, left: state.Digest, right: state.Digest) bool {
            return std.mem.order(u8, &left, &right) == .lt;
        }
        pub fn observerHeadsAfter(
            a: std.mem.Allocator,
            parent: state.Task,
            removed: ?state.Digest,
            added: ?state.Digest,
        ) ![]state.Digest {
            var heads: std.ArrayList(state.Digest) = .empty;
            errdefer heads.deinit(a);
            for (parent.observer_heads.items, 0..) |head, index| {
                if (index != 0 and
                    !observerHeadOrder({}, parent.observer_heads.items[index - 1], head))
                    return error.CorruptState;
                if (removed) |id| if (std.meta.eql(head, id)) continue;
                if (added) |id| if (std.meta.eql(head, id)) return error.CorruptState;
                try heads.append(a, head);
            }
            if (added) |id| try heads.append(a, id);
            std.mem.sort(state.Digest, heads.items, {}, observerHeadOrder);
            return heads.toOwnedSlice(a);
        }
        pub fn requireObserverMobility(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work_id: ?state.Digest,
        ) !void {
            if (parent.observer_heads.items.len != 0) try compatible(self, parent);
            for (parent.observer_heads.items) |id| {
                var work = try retainedWorkspaceWork(self, a, parent.id, id);
                defer work.deinit();
                const observer = work.value.observer orelse return error.CorruptState;
                if (!activeObserver(self, work.value)) return error.CorruptState;
                if (work_id) |selected| {
                    if (!std.meta.eql(selected, id) and
                        !std.meta.eql(selected, observer.source_work)) continue;
                    return error.ActiveObserverMobilityUnsupported;
                } else if (observer.selection.policy.continuation == .owner_scheduled)
                    return error.ScheduledObserverMobilityUnsupported;
            }
        }
        pub fn requireMovableControllerDependency(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
        ) !void {
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            const id = parent.value.controller_succession orelse return;
            if (subject.work == null) return error.UnsettledController;
            var operation_value = try record(
                self,
                state.ControllerSuccession,
                a,
                "controller_succession",
                id,
                subject.task,
            );
            defer operation_value.deinit();
            if (std.meta.eql(subject.work, operation_value.value.conversion_work))
                return error.UnsettledController;
        }
        pub fn workspaceStopObserving(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            expected: wc.Expected,
        ) !Admission {
            const request = try operation(workspace.StopObservingRequest, a, .{
                .task = task_id,
                .expected = expected,
            });
            if (try replay(self, a, id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const work_id = try wp.identity(expected.work, .work);
            try requireCustody(self, a, task_id, work_id);
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            if (saved.value.execution_revision != expected.execution_revision or
                saved.value.control_revision != expected.control_revision)
                return error.StaleRevision;
            var value = saved.value;
            if (value.observer == null or value.observer.?.successor != null)
                return error.InvalidObserverInput;
            if (!value.observer.?.stopped and
                observerHeadIndex(parent.value, value.id) == null) return error.CorruptState;
            const heads = try observerHeadsAfter(a, parent.value, value.id, null);
            defer a.free(heads);
            parent.value.observer_heads.items = heads;
            value.observer.?.stopped = true;
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            try store(self).begin();
            defer store(self).rollback();
            try writeWorkspaceWork(self, &value, .replace);
            const frozen =
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, task_id);
            return workspaceCommit(
                self,
                a,
                parent.value,
                id,
                request,
                value.id,
                .work,
                frozen,
                .{ .stop_observing = expected },
            );
        }
        pub fn validateObserverSuccessionPublication(
            self: *Self,
            a: std.mem.Allocator,
            event_value: state.Event,
            item: state.WorkPublication,
            prior: ?state.WorkPublication,
            command: ?workspace.PublicationCommand,
        ) !bool {
            const before = prior orelse return false;
            const selected = command orelse return false;
            if (selected != .start) return false;
            const observer = selected.start.observer orelse return error.InvalidArchive;
            const previous = observer.selection.previous orelse return error.InvalidArchive;
            const publications = event_value.workspace_publications.items;
            if (publications.len != 2 or !std.meta.eql(publications[1].work, item.work) or
                !std.meta.eql(try wp.identity(previous, .work), item.work))
                return error.InvalidArchive;
            const reference = observer.previous orelse return error.InvalidArchive;
            const bytes = try store(self).object(a, reference, null);
            defer a.free(bytes);
            var retained = try contracts.decodeOwned(workspace.Work, a, bytes);
            defer retained.deinit();
            const predecessor = retained.value;
            var snapshot: workspace.WorkObservation = .{ .work = predecessor, .occurrence = null };
            if (!try samePublication(a, before, try workPublication(a, snapshot)))
                return error.InvalidArchive;
            if (predecessor.observer == null or predecessor.observer.?.successor != null or
                predecessor.outcome_kind != .completed or predecessor.cancellation != null)
                return error.InvalidArchive;
            const previous_bytes = try contracts.encodeOwned(workspace.Work, a, predecessor);
            defer a.free(previous_bytes);
            const previous_reference: state.Reference = .{
                .digest = storage.digest(previous_bytes),
                .bytes = previous_bytes.len,
            };
            if (!std.meta.eql(observer.previous, @as(?state.Reference, previous_reference)))
                return error.InvalidArchive;
            snapshot.work.observer.?.successor = publications[0].work;
            snapshot.work.control_revision = try std.math.add(u64, predecessor.control_revision, 1);
            snapshot.work.event_watermark = event_value.seq;
            if (!try samePublication(a, item, try workPublication(a, snapshot)))
                return error.InvalidArchive;
            return true;
        }
        pub fn validateObserverPublication(
            a: std.mem.Allocator,
            item: state.WorkPublication,
            prior: ?state.WorkPublication,
            command: ?workspace.PublicationCommand,
        ) !void {
            const observer = item.observer orelse {
                if (prior != null and prior.?.observer != null) return error.InvalidArchive;
                if (command) |selected| switch (selected) {
                    .start => |start| if (start.observer != null) return error.InvalidArchive,
                    .stop_observing => return error.InvalidArchive,
                    else => {},
                };
                return;
            };
            const completed = item.control.outcome == .completed;
            if (observer.consumed_revision != @as(?u64, if (completed)
                observer.source_revision
            else
                null)) return error.InvalidArchive;
            if (prior) |before| {
                var expected = before.observer orelse return error.InvalidArchive;
                expected.consumed_revision = observer.consumed_revision;
                if (!std.meta.eql(expected.incomplete, observer.incomplete)) {
                    if (command != null or expected.stopped or !completed or
                        before.control.outcome != .completed or observer.incomplete == null or
                        expected.selection.policy.continuation != .owner_scheduled)
                        return error.InvalidArchive;
                    expected.incomplete = observer.incomplete;
                }
                if (command != null and command.? == .stop_observing) {
                    const selected = command.?.stop_observing;
                    if (!std.meta.eql(try wp.identity(selected.work, .work), item.work) or
                        selected.execution_revision != before.execution_revision or
                        selected.control_revision != before.control_revision or
                        item.control_revision -| before.control_revision != 1 or
                        item.execution_revision != before.execution_revision)
                        return error.InvalidArchive;
                    expected.stopped = true;
                }
                const bytes = try contracts.encodeOwned(workspace.Observer, a, expected);
                defer a.free(bytes);
                const actual = try contracts.encodeOwned(workspace.Observer, a, observer);
                defer a.free(actual);
                if (!same(bytes, actual)) return error.InvalidArchive;
            } else {
                if (observer.stopped or observer.successor != null or observer.incomplete != null or
                    command == null or command.? != .start)
                    return error.InvalidArchive;
                var expected = command.?.start.observer orelse return error.InvalidArchive;
                expected.consumed_revision = observer.consumed_revision;
                const requested = try contracts.encodeOwned(workspace.Observer, a, expected);
                defer a.free(requested);
                const actual = try contracts.encodeOwned(workspace.Observer, a, observer);
                defer a.free(actual);
                if (!same(requested, actual)) return error.InvalidArchive;
            }
        }
        pub const ObserverSuccessors = observerSuccessorsType();
        fn observerSuccessorsType() type {
            return struct {
                const Entry = struct { id: state.Digest, duplicate: bool };
                allocator: std.mem.Allocator,
                task: state.TaskId,
                entries: std.AutoHashMapUnmanaged(state.Digest, Entry) = .empty,
                loaded: bool = false,
                histories: ObserverHistories,

                pub fn init(a: std.mem.Allocator, task_id: state.TaskId) ObserverSuccessors {
                    return .{ .allocator = a, .task = task_id, .histories = .{ .allocator = a } };
                }

                pub fn deinit(self: *ObserverSuccessors) void {
                    self.entries.deinit(self.allocator);
                    self.histories.deinit();
                }

                pub fn next(
                    self: *ObserverSuccessors,
                    service: *Self,
                    id: state.Digest,
                ) !?state.Digest {
                    if (!self.loaded) try self.load(service);
                    const entry = self.entries.get(id) orelse return null;
                    if (entry.duplicate) return error.InvalidArchive;
                    return entry.id;
                }

                pub fn load(self: *ObserverSuccessors, service: *Self) !void {
                    var entries: std.AutoHashMapUnmanaged(state.Digest, Entry) = .empty;
                    errdefer entries.deinit(self.allocator);
                    const ids = try workspaceIds(service, self.allocator, self.task);
                    defer self.allocator.free(ids);
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    for (ids) |id| {
                        _ = arena.reset(.retain_capacity);
                        var other =
                            try retainedWorkspaceWork(service, arena.allocator(), self.task, id);
                        defer other.deinit();
                        const observer = other.value.observer orelse continue;
                        const prior = observer.selection.previous orelse continue;
                        const entry =
                            try entries.getOrPut(self.allocator, try wp.identity(prior, .work));
                        if (entry.found_existing) entry.value_ptr.duplicate =
                            true else entry.value_ptr.* =
                            .{ .id = other.value.id, .duplicate = false };
                    }
                    self.entries = entries;
                    self.loaded = true;
                }
            };
        }
        pub fn validateObservedAdvance(
            before: state.WorkPublication,
            after: state.WorkPublication,
            prefix: *@import("../workspace_observers.zig").PublicationPrefix,
        ) !void {
            if (before.execution_revision == after.execution_revision and
                std.meta.eql(
                    before.outer_operation orelse before.runtime_capsule,
                    after.outer_operation orelse after.runtime_capsule,
                )) return;
            const active = prefix.lossless(before.work) orelse return;
            var outer: ?struct { before: u64, after: u64 } = null;
            for (active.keys()) |id| {
                const observer = prefix.latest.get(id).?.publication.observer.?;
                if (observer.selection.source.level == .guest_cut and
                    before.execution_revision == after.execution_revision) continue;
                var cursor = before.execution_revision;
                if (observer.selection.source.level == .outer_execution) {
                    if (outer == null) outer = .{
                        .before = try prefix.outerRevision(
                            before.work,
                            std.math.maxInt(u64),
                            before.outer_operation orelse before.runtime_capsule,
                        ),
                        .after = try prefix.outerRevision(
                            after.work,
                            std.math.maxInt(u64),
                            after.outer_operation orelse after.runtime_capsule,
                        ),
                    };
                    cursor = outer.?.before;
                    if (cursor == outer.?.after) continue;
                }
                if (observer.consumed_revision == null or observer.consumed_revision.? != cursor)
                    return error.InvalidArchive;
            }
        }
        pub fn pumpObserver(self: *Self, a: std.mem.Allocator, work: workspace.Work) !Step {
            const observer = work.observer.?;
            const subject: workspace.Subject = .{ .task = work.task, .work = work.id };
            var parent = try self.task(a, work.task);
            defer parent.deinit();
            if (workspaceParentStopped(self, parent.value) or observer.stopped or
                observer.selection.policy.continuation != .owner_scheduled or
                observer.successor != null)
            {
                subjectRemove(self, subject);
                return .progressed;
            }
            var source = try self.workspaceWork(a, work.task, observer.source_work);
            defer source.deinit();
            const consumed = observer.consumed_revision orelse return error.InvalidObserverInput;
            const revision =
                try observerSourceRevision(self, a, source.value, observer.selection.source.level);
            if (revision -| consumed < observer.selection.policy.cadence)
                return .idle;
            if (observer.incomplete) |incomplete| if (incomplete.revision == revision)
                return .idle;
            var selection = observer.selection;
            selection.source.expected.execution_revision = source.value.execution_revision;
            selection.source.expected.control_revision = source.value.control_revision;
            selection.source.realization_revision = source.value.realization_revision;
            selection.previous = try wp.reference(a, .work, work.id);
            const identity = try operation(struct {
                revision: u64,
                request: workspace.ObserveRequest,
            }, a, .{
                .revision = revision,
                .request = .{ .task = work.task, .selection = selection },
            });
            const operation_id = try std.fmt.allocPrint(a, "observe-{s}", .{
                std.fmt.bytesToHex(identity, .lower),
            });
            defer a.free(operation_id);
            _ = workspaceObserve(self, a, operation_id, work.task, selection) catch |err| {
                const diagnostic: @FieldType(workspace.Observer.Incomplete, "diagnostic") =
                    switch (err) {
                        error.InvalidDisclosure => .invalid_disclosure,
                        error.OuterCutUnavailable => .outer_cut_unavailable,
                        else => return err,
                    };
                return recordObserverIncomplete(
                    self,
                    a,
                    parent.value,
                    work,
                    source.value,
                    revision,
                    diagnostic,
                );
            };
            subjectRemove(self, subject);
            return .progressed;
        }
        fn recordObserverIncomplete(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work: workspace.Work,
            source: workspace.Work,
            revision: u64,
            diagnostic: @FieldType(workspace.Observer.Incomplete, "diagnostic"),
        ) !Step {
            var prepared = try inspectionRuntime(self, a, source);
            defer prepared.deinit();
            const code = try prepared.runtime.encode(a);
            defer a.free(code);
            var pending: ?contracts.Decoded(occurrence.Occurrence) = null;
            defer if (pending) |*value| value.deinit();
            if (source.current_occurrence) |id|
                pending = try record(self, occurrence.Occurrence, a, "occurrence", id, source.task);
            const snapshot = try contracts.encodeOwned(workspace.WorkObservation, a, .{
                .work = source,
                .occurrence = if (pending) |value| value.value else null,
            });
            defer a.free(snapshot);
            try store(self).begin();
            defer store(self).rollback();
            var value = work;
            value.observer.?.incomplete = .{
                .publication = source.event_watermark,
                .revision = revision,
                .source = try store(self).putObject(snapshot),
                .runtime_code = try store(self).putObject(code),
                .diagnostic = diagnostic,
            };
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try writeWorkspaceWork(self, &value, .replace);
            _ = try workspaceCommit(
                self,
                a,
                parent,
                null,
                @splat(0),
                value.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, value.task),
                null,
            );
            return .progressed;
        }
        pub fn validateObserverPreparationProgress(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            watermark: u64,
            item: state.WorkPublication,
            prior: ?state.WorkPublication,
            command: ?workspace.PublicationCommand,
            histories: *ObserverHistories,
        ) !bool {
            const observer = item.observer orelse return false;
            const before = prior orelse return false;
            const previous = before.observer orelse return error.InvalidArchive;
            if (std.meta.eql(previous.incomplete, observer.incomplete)) return false;
            const incomplete = observer.incomplete orelse return error.InvalidArchive;
            if (previous.incomplete) |failed| if (failed.revision >= incomplete.revision)
                return error.InvalidArchive;
            if (command != null or item.execution_revision != before.execution_revision or
                item.control_revision != before.control_revision or
                incomplete.publication != try ResidualValidation.workspacePublicationAt(
                    self,
                    a,
                    task_id,
                    observer.source_work,
                    watermark -| 1,
                )) return error.InvalidArchive;
            var expected = before;
            expected.observer.?.incomplete = incomplete;
            expected.observation = item.observation;
            if (!try samePublication(a, expected, item)) return error.InvalidArchive;
            try validateObserverIncompleteAt(
                self,
                a,
                task_id,
                item.control.outcome,
                watermark,
                observer,
                histories,
            );
            return true;
        }
        fn validateObserverIncomplete(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            histories: *ObserverHistories,
        ) !void {
            const observer = work.observer orelse return;
            return validateObserverIncompleteAt(
                self,
                a,
                work.task,
                work.outcome_kind,
                work.event_watermark,
                observer,
                histories,
            );
        }
        fn validateObserverIncompleteAt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            outcome: state.Outcome,
            watermark: u64,
            observer: workspace.Observer,
            histories: *ObserverHistories,
        ) !void {
            const incomplete = observer.incomplete orelse return;
            const consumed = observer.consumed_revision orelse return error.InvalidArchive;
            if (outcome != .completed or incomplete.publication >= watermark or
                incomplete.revision -| consumed < observer.selection.policy.cadence or
                observer.selection.policy.continuation != .owner_scheduled)
                return error.InvalidArchive;
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                    "WHERE e.task=? AND e.seq=?",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, incomplete.publication) orelse
                        return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            if (try query.step() != .row) return error.InvalidArchive;
            var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
            defer event_value.deinit();
            for (event_value.value.workspace_publications.items) |publication| {
                if (!std.meta.eql(publication.work, observer.source_work)) continue;
                if (!std.meta.eql(publication.observation, incomplete.source.digest))
                    return error.InvalidArchive;
                const bytes = try store(self).object(a, incomplete.source, null);
                defer a.free(bytes);
                var source = try contracts.decodeOwned(workspace.WorkObservation, a, bytes);
                defer source.deinit();
                if (!std.meta.eql(source.value.work.id, observer.source_work) or
                    source.value.work.event_watermark != incomplete.publication)
                    return error.InvalidArchive;
                try validateWorkspacePublication(self, a, task_id, source.value);
                try histories.validateCursor(self, a, source.value.work);
                if (incomplete.revision != try observerSourceRevision(
                    self,
                    a,
                    source.value.work,
                    observer.selection.source.level,
                )) return error.InvalidArchive;
                return validateObserverPreparationCut(self, a, observer, source.value);
            }
            return error.InvalidArchive;
        }
        fn validateObserverPreparationCut(
            self: *Self,
            a: std.mem.Allocator,
            observer: workspace.Observer,
            source: workspace.WorkObservation,
        ) !void {
            const incomplete = observer.incomplete.?;
            var prepared = try inspectionRuntime(self, a, source.work);
            defer prepared.deinit();
            const code = try store(self).object(a, incomplete.runtime_code, null);
            defer a.free(code);
            if (!std.meta.eql(prepared.runtime.identity, incomplete.runtime_code.digest))
                return error.InvalidArchive;
            if (incomplete.diagnostic == .outer_cut_unavailable) {
                if (observer.selection.source.level != .outer_execution or
                    source.work.outer_operation != null)
                    return error.InvalidArchive;
                if (source.work.runtime_capsule) |ref| {
                    const bytes = try store(self).object(a, ref, null);
                    defer a.free(bytes);
                    var capsule = try kosmos.RuntimeCapsule.read(a, bytes);
                    defer capsule.deinit();
                    if (capsule.value.record.kind != .guest_cut) return error.InvalidArchive;
                }
                return;
            }
            const disclosed = workspaceInspectionBytes(self, a, source.work.task, .{
                .level = observer.selection.source.level,
                .observation = source,
                .nodes = observer.selection.source.nodes,
                .disclosure = observer.selection.source.disclosure,
                .runtime_code = incomplete.runtime_code,
            }) catch |err| switch (err) {
                error.InvalidDisclosure => return,
                else => return err,
            };
            a.free(disclosed.schema);
            a.free(disclosed.value);
            return error.InvalidArchive;
        }
        pub fn observerAdvanceAllowed(
            self: *Self,
            a: std.mem.Allocator,
            source: workspace.Work,
        ) !void {
            return observerAdvanceAllowedFor(self, a, source, null);
        }
        pub fn observerAdvanceAllowedFor(
            self: *Self,
            a: std.mem.Allocator,
            source: workspace.Work,
            level: ?@FieldType(wc.GuestViewSelection, "level"),
        ) !void {
            var parent = try self.task(a, source.task);
            defer parent.deinit();
            if (parent.value.observer_heads.items.len != 0)
                try compatible(self, parent.value);
            for (parent.value.observer_heads.items) |id| {
                var saved = try retainedWorkspaceWork(self, a, source.task, id);
                defer saved.deinit();
                const observer = saved.value.observer orelse return error.CorruptState;
                if (!activeObserver(self, saved.value)) return error.CorruptState;
                if (observer.selection.policy.delivery != .lossless or
                    (level != null and observer.selection.source.level != level.?) or
                    !std.meta.eql(observer.source_work, source.id)) continue;
                if (observer.consumed_revision == null or
                    observer.consumed_revision.? !=
                        try observerSourceRevision(
                            self,
                            a,
                            source,
                            observer.selection.source.level,
                        ))
                    return error.ObservationBlocked;
            }
        }
        pub fn observationBlockedAt(
            source: state.WorkPublication,
            prefix: *@import("../workspace_observers.zig").PublicationPrefix,
        ) !bool {
            return prefix.blocked(
                source.work,
                source.execution_revision,
                std.math.maxInt(u64),
                source.outer_operation orelse source.runtime_capsule,
            );
        }
        pub const ObserverScope = observerScopeType();
        fn observerScopeType() type {
            return union(enum) {
                current: *CurrentObservers,
                historical: *ObserverHistories,

                pub fn at(
                    scope: ObserverScope,
                    task_id: state.TaskId,
                    watermark: u64,
                ) !WorkObservers {
                    return switch (scope) {
                        .current => |index| if (std.meta.eql(index.task, task_id) and
                            index.watermark == watermark)
                            .{ .current = index }
                        else
                            error.InvalidArchive,
                        .historical => |histories| .{
                            .historical = try histories.get(task_id, watermark),
                        },
                    };
                }
            };
        }
        pub const WorkObservers = workObserversType();
        fn workObserversType() type {
            return union(enum) {
                current: *CurrentObservers,
                historical: HistoricalRead,

                pub fn blocked(
                    observers: WorkObservers,
                    service: *Self,
                    source: workspace.Work,
                    observed_at: u64,
                ) !bool {
                    switch (observers) {
                        inline .current, .historical => |index| {
                            if (observed_at != index.watermark) return error.InvalidArchive;
                            return index.blocked(service, source);
                        },
                    }
                }
            };
        }
        pub const CurrentObservers = currentObserversType();
        fn currentObserversType() type {
            return struct {
                const Key = struct {
                    source: state.Digest,
                    level: @FieldType(wc.GuestViewSelection, "level"),
                };
                allocator: std.mem.Allocator,
                task: state.TaskId,
                watermark: u64,
                loaded: bool = false,
                revisions: std.AutoHashMapUnmanaged(Key, ?u64) = .empty,

                pub fn init(
                    a: std.mem.Allocator,
                    task_id: state.TaskId,
                    watermark: u64,
                ) CurrentObservers {
                    return .{ .allocator = a, .task = task_id, .watermark = watermark };
                }

                pub fn deinit(index: *CurrentObservers) void {
                    index.revisions.deinit(index.allocator);
                }

                pub fn load(index: *CurrentObservers, service: *Self) !void {
                    const a = index.allocator;
                    var parent = try task(service, a, index.task);
                    defer parent.deinit();
                    if (index.watermark != parent.value.event_high) return error.InvalidArchive;
                    for (parent.value.observer_heads.items) |id| {
                        var saved = try retainedWorkspaceWork(service, a, index.task, id);
                        defer saved.deinit();
                        const observer = saved.value.observer orelse return error.CorruptState;
                        if (!activeObserver(service, saved.value)) return error.CorruptState;
                        if (observer.selection.policy.delivery != .lossless) continue;
                        const entry = try index.revisions.getOrPut(a, .{
                            .source = observer.source_work,
                            .level = observer.selection.source.level,
                        });
                        if (!entry.found_existing) {
                            entry.value_ptr.* = observer.consumed_revision;
                        } else if (!std.meta.eql(entry.value_ptr.*, observer.consumed_revision)) {
                            entry.value_ptr.* = null;
                        }
                    }
                    index.loaded = true;
                }

                pub fn blocked(
                    index: *CurrentObservers,
                    service: *Self,
                    source: workspace.Work,
                ) !bool {
                    if (!std.meta.eql(source.task, index.task) or
                        source.event_watermark > index.watermark)
                        return error.InvalidArchive;
                    if (!index.loaded) try index.load(service);
                    const levels = [_]@FieldType(wc.GuestViewSelection, "level"){
                        .guest_cut,
                        .outer_execution,
                    };
                    for (levels) |level| {
                        const consumed = index.revisions.get(.{
                            .source = source.id,
                            .level = level,
                        }) orelse continue;
                        if (consumed == null or consumed.? != try observerSourceRevision(
                            service,
                            index.allocator,
                            source,
                            level,
                        ))
                            return true;
                    }
                    return false;
                }
            };
        }
        pub const ObserverHistories = observerHistoriesType();
        fn observerHistoriesType() type {
            return struct {
                allocator: std.mem.Allocator,
                entries: std.AutoHashMapUnmanaged(state.TaskId, *HistoricalObservers) = .empty,

                pub fn deinit(histories: *ObserverHistories) void {
                    const a = histories.allocator;
                    var iterator = histories.entries.valueIterator();
                    while (iterator.next()) |index| {
                        index.*.deinit();
                        a.destroy(index.*);
                    }
                    histories.entries.deinit(a);
                }

                pub fn validateCursor(
                    histories: *ObserverHistories,
                    service: *Self,
                    a: std.mem.Allocator,
                    work: workspace.Work,
                ) !void {
                    var parent = try task(service, a, work.task);
                    defer parent.deinit();
                    const read = try histories.get(work.task, parent.value.event_high);
                    const index = read.index;
                    try index.load(service);
                    if (work.event_watermark > index.watermark) return error.InvalidArchive;
                    const cursor = index.history.outerCursorAt(work.id, work.event_watermark);
                    if (!std.meta.eql(work.outer_cursor, cursor))
                        return error.InvalidArchive;
                }

                pub fn get(
                    histories: *ObserverHistories,
                    task_id: state.TaskId,
                    watermark: u64,
                ) !HistoricalRead {
                    const a = histories.allocator;
                    if (histories.entries.get(task_id)) |index|
                        return .{ .index = index, .watermark = watermark };
                    const index = try a.create(HistoricalObservers);
                    errdefer a.destroy(index);
                    index.* = .init(a, task_id, std.math.maxInt(u64));
                    try histories.entries.put(a, task_id, index);
                    return .{ .index = index, .watermark = watermark };
                }
            };
        }
        const HistoricalRead = historicalReadType();
        fn historicalReadType() type {
            return struct {
                index: *HistoricalObservers,
                watermark: u64,

                pub fn blocked(read: HistoricalRead, service: *Self, source: workspace.Work) !bool {
                    const index = read.index;
                    if (!std.meta.eql(source.task, index.task) or
                        source.event_watermark > read.watermark)
                        return error.InvalidArchive;
                    try index.prepare(service);
                    if (read.watermark > index.watermark) return error.InvalidArchive;
                    if (!index.observers_present.?) return false;
                    try index.load(service);
                    return index.history.blocked(
                        source.id,
                        source.execution_revision,
                        source.event_watermark,
                        read.watermark,
                        if (source.outer_operation) |pending|
                            pending.capsule
                        else
                            source.runtime_capsule,
                    );
                }
            };
        }
        pub const HistoricalObservers = historicalObserversType();
        fn historicalObserversType() type {
            return struct {
                const History = @import("../workspace_observers.zig").PublicationHistory;
                allocator: std.mem.Allocator,
                task: state.TaskId,
                watermark: u64,
                loaded: bool = false,
                observers_present: ?bool = null,
                history: History,

                pub fn init(
                    a: std.mem.Allocator,
                    task_id: state.TaskId,
                    watermark: u64,
                ) HistoricalObservers {
                    return .{
                        .allocator = a,
                        .task = task_id,
                        .watermark = watermark,
                        .history = .init(a),
                    };
                }

                pub fn deinit(index: *HistoricalObservers) void {
                    index.history.deinit();
                }

                pub fn prepare(index: *HistoricalObservers, service: *Self) !void {
                    if (index.observers_present != null) return;
                    var parent = try task(service, index.allocator, index.task);
                    defer parent.deinit();
                    index.watermark = @min(index.watermark, parent.value.event_high);
                    index.observers_present = parent.value.observers_present;
                }

                pub fn load(index: *HistoricalObservers, service: *Self) !void {
                    if (index.loaded) return;
                    try index.prepare(service);
                    var history = History.init(index.allocator);
                    errdefer history.deinit();
                    var builder = History.Builder.init(service.allocator, &history);
                    defer builder.deinit();
                    var rows = try store(service).database.prepare(
                        "SELECT e.seq, o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                            "WHERE e.task=? AND e.seq<=? ORDER BY e.seq",
                        &.{ .{ .blob = &index.task }, .{
                            .integer = std.math.cast(i64, index.watermark) orelse
                                return error.InvalidArchive,
                        } },
                    );
                    defer rows.deinit();
                    while (try rows.step() == .row) {
                        var event_value = try contracts.decodeOwned(
                            state.Event,
                            service.allocator,
                            try rows.bytes(1),
                        );
                        defer event_value.deinit();
                        if (event_value.value.seq != try rows.integer(0))
                            return error.InvalidArchive;
                        for (event_value.value.workspace_publications.items) |item|
                            try builder.put(item, event_value.value.seq);
                    }
                    index.history.deinit();
                    index.history = history;
                    index.loaded = true;
                }
            };
        }
        pub fn observerSourceRevision(
            _: *Self,
            _: std.mem.Allocator,
            work: workspace.Work,
            level: @FieldType(wc.GuestViewSelection, "level"),
        ) !u64 {
            if (level == .guest_cut) return work.execution_revision;
            return (try workspaceOuterCursor(work)).revision;
        }
        pub fn workspaceOuterCursor(work: workspace.Work) !workspace.OuterCursor {
            var cursor = work.outer_cursor;
            const capsule =
                (if (work.outer_operation) |pending|
                    pending.capsule
                else
                    work.runtime_capsule) orelse
                return cursor;
            if (cursor.last) |previous| {
                if (!std.meta.eql(previous, capsule.digest))
                    cursor.revision = try std.math.add(u64, cursor.revision, 1);
            }
            cursor.last = capsule.digest;
            return cursor;
        }
        pub fn observerGuestQuantum(
            self: *Self,
            a: std.mem.Allocator,
            source: workspace.Work,
        ) !u64 {
            var parent = try self.task(a, source.task);
            defer parent.deinit();
            if (parent.value.observer_heads.items.len != 0)
                try compatible(self, parent.value);
            for (parent.value.observer_heads.items) |id| {
                var saved = try retainedWorkspaceWork(self, a, source.task, id);
                defer saved.deinit();
                const observer = saved.value.observer orelse return error.CorruptState;
                if (!activeObserver(self, saved.value)) return error.CorruptState;
                if (observer.selection.policy.granularity == .one_guest_step and
                    std.meta.eql(observer.source_work, source.id)) return 1;
            }
            return 256;
        }
        pub fn retainObservedOuter(
            self: *Self,
            a: std.mem.Allocator,
            value: *workspace.Work,
        ) !void {
            var parent = try self.task(a, value.task);
            defer parent.deinit();
            if (parent.value.observer_heads.items.len != 0)
                try compatible(self, parent.value);
            for (parent.value.observer_heads.items) |id| {
                var work = try retainedWorkspaceWork(self, a, value.task, id);
                defer work.deinit();
                const observer = work.value.observer orelse return error.CorruptState;
                if (!activeObserver(self, work.value)) return error.CorruptState;
                if (observer.selection.source.level != .outer_execution or
                    !std.meta.eql(observer.source_work, value.id)) continue;
                const driver = self.active.?.driver;
                const capsule = try driver.retainCapsule(runtimeProvenance(value.*));
                const code = try driver.runtimeBytes(a);
                defer a.free(code);
                _ = try store(self).putObject(code);
                value.runtime_capsule = try store(self).putObject(capsule);
                value.runtime_dependencies = .{ .items = try capsuleDependencies(a, capsule) };
                return;
            }
        }
        fn workspaceObserverSource(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            selection: wc.Observe,
        ) !workspace.Observer {
            const key = storage.digest(operation_id);
            const view_id = try std.fmt.allocPrint(a, "observe-view-{s}", .{
                std.fmt.bytesToHex(key, .lower),
            });
            defer a.free(view_id);
            const view = try workspaceContextMutation(self, a, view_id, task_id, .{
                .materialize = .{
                    .input = .{ .guest_view = selection.source },
                    .sources = .{ .items = &.{} },
                },
            }, null, null);
            const view_ref = try wp.reference(a, .value, view.receipt.workspace.?);
            const disclosed = try workspaceValueReference(self, a, task_id, view_ref);
            const custody =
                try workspaceContentCustody(a, task_id, disclosed.artifact.digest);
            var saved =
                try record(self, workspace.Value, a, "workspace_value", custody, task_id);
            defer saved.deinit();
            const source = saved.value.derivation.inspection orelse
                return error.InvalidObserverInput;
            var current_source =
                try self.workspaceWork(a, task_id, source.observation.work.id);
            defer current_source.deinit();
            try inspectionSelection(current_source.value, selection.source);
            const source_revision = try observerSourceRevision(
                self,
                a,
                source.observation.work,
                selection.source.level,
            );
            if (source_revision != try observerSourceRevision(
                self,
                a,
                current_source.value,
                selection.source.level,
            )) return error.StaleRevision;
            const accumulator =
                try workspaceValueReference(self, a, task_id, selection.accumulator);
            return .{
                .selection = selection,
                .source = disclosed.artifact,
                .source_work = source.observation.work.id,
                .source_revision = source_revision,
                .accumulator = accumulator.artifact,
            };
        }
        pub fn workspaceObserve(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            selection: wc.Observe,
        ) !Admission {
            const request = try operation(workspace.ObserveRequest, a, .{
                .task = task_id,
                .selection = selection,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(
                self,
                a,
                task_id,
                try wp.identity(selection.source.expected.work, .work),
            );
            try @import("../workspace_observers.zig").validatePolicy(selection.policy);
            var observer = try workspaceObserverSource(self, a, operation_id, task_id, selection);
            try bindObserverPrevious(self, a, task_id, &observer);
            const input = try observerInput(self, a, task_id, observer);
            defer a.free(input);
            return workspaceStartAdmitted(
                self,
                a,
                operation_id,
                task_id,
                try wp.identity(selection.program, .program),
                input,
                .{ .stop = .terminal, .continuation = .owner_scheduled },
                null,
                null,
                null,
                .{ .none = .{} },
                null,
                observer,
            );
        }
        fn bindObserverPrevious(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            observer: *workspace.Observer,
        ) !void {
            const ref = observer.selection.previous orelse return;
            var prior = try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
            defer prior.deinit();
            const before = prior.value.observer orelse return error.InvalidObserverInput;
            const program = try wp.identity(observer.selection.program, .program);
            if (prior.value.outcome_kind != .completed or prior.value.cancellation != null or
                !std.meta.eql(prior.value.program, program) or
                !std.meta.eql(before.source_work, observer.source_work))
                return error.InvalidObserverInput;
            try observerScope(a, before.selection.source, observer.selection.source);
            const consumed = before.consumed_revision orelse return error.InvalidObserverInput;
            const next = observer.source_revision;
            if (next <= consumed) return error.DuplicateObservation;
            if (observer.selection.policy.delivery == .lossless and next != consumed + 1)
                return error.ObservationGap;
            const snapshot = try contracts.encodeOwned(workspace.Work, a, prior.value);
            defer a.free(snapshot);
            observer.previous = .{ .digest = storage.digest(snapshot), .bytes = snapshot.len };
            observer.accumulator = prior.value.result_value orelse
                return error.InvalidObserverInput;
            if (next > consumed + 1) {
                observer.gap_first = consumed + 1;
                observer.gap_last = next - 1;
            }
        }
        fn observerInput(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            observer: workspace.Observer,
        ) ![]u8 {
            const helpers = @import("../workspace_observers.zig");
            const envelope = try observerEnvelope(self, a, task_id, observer);
            defer a.free(envelope);
            const program_id = try wp.identity(observer.selection.program, .program);
            var program = try self.workspaceProgram(a, task_id, program_id);
            defer program.deinit();
            const view_ref = try wp.reference(a, .value, observer.source.digest);
            const disclosed = try workspaceValueReference(self, a, task_id, view_ref);
            const view = .{
                .schema = try store(self).object(a, disclosed.schema, null),
                .value = try store(self).object(a, disclosed.value, null),
            };
            defer a.free(view.schema);
            defer a.free(view.value);
            const accumulator_ref = try wp.reference(a, .value, observer.accumulator.digest);
            const accumulator =
                try workspaceValueReference(self, a, task_id, accumulator_ref);
            const schema = try store(self).object(a, accumulator.schema, null);
            defer a.free(schema);
            const bytes = try store(self).object(a, accumulator.value, null);
            defer a.free(bytes);
            const input_schema =
                try store(self).object(a, program.value.description.input_schema, null);
            defer a.free(input_schema);
            const output_schema =
                try store(self).object(a, program.value.description.result_schema, null);
            defer a.free(output_schema);
            if (observer.previous == null) return helpers.input(
                a,
                input_schema,
                output_schema,
                view.schema,
                view.value,
                envelope,
                schema,
                bytes,
            );
            const acc_schema = try helpers.fieldSchema(a, schema, 0);
            defer a.free(acc_schema);
            var decoded = try @import("../dynamic_values.zig").decode(a, schema, bytes);
            defer decoded.deinit();
            const acc_bytes = try @import("../dynamic_values.zig").encode(
                a,
                acc_schema,
                decoded.value.array.items[0],
            );
            defer a.free(acc_bytes);
            return helpers.input(
                a,
                input_schema,
                output_schema,
                view.schema,
                view.value,
                envelope,
                acc_schema,
                acc_bytes,
            );
        }
        fn observerEnvelope(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            observer: workspace.Observer,
        ) ![]u8 {
            const id = try workspaceContentCustody(a, task_id, observer.source.digest);
            var value =
                try record(self, workspace.Value, a, "workspace_value", id, task_id);
            defer value.deinit();
            const observed = value.value.derivation.inspection.?.observation;
            var prior_cursor: ?u64 = null;
            var granularity: @FieldType(wc.ObserverPolicy, "granularity") = .publication;
            if (observer.previous) |ref| {
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                var before = try contracts.decodeOwned(workspace.Work, a, bytes);
                defer before.deinit();
                const previous = before.value.observer orelse return error.InvalidObserverInput;
                prior_cursor = previous.consumed_revision orelse return error.InvalidObserverInput;
                if (previous.selection.policy.granularity == .one_guest_step and
                    observer.selection.source.level == .guest_cut and
                    observed.work.guest_work <= 1 and
                    observer.source_revision -| prior_cursor.? == 1) granularity = .one_guest_step;
            }
            return contracts.encodeOwned(workspace.ObserverEnvelope, a, .{
                .selection = observer.selection.source,
                .publication = observed.work.event_watermark,
                .cursor = observer.source_revision,
                .prior_cursor = prior_cursor,
                .guest_work_delta = if (observer.selection.source.level == .guest_cut)
                    observed.work.guest_work
                else
                    null,
                .gap_first = observer.gap_first,
                .gap_last = observer.gap_last,
                .granularity = granularity,
                .disclosed_value = observer.source,
                .control = workspace.ControlObservation.from(observed),
            });
        }
        fn validateObserverPrevious(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            observer: workspace.Observer,
            successors: *ObserverSuccessors,
        ) !void {
            if (observer.previous) |previous| {
                const bytes = try store(self).object(a, previous, null);
                defer a.free(bytes);
                var prior = try contracts.decodeOwned(workspace.Work, a, bytes);
                defer prior.deinit();
                const previous_id = try wp.identity(observer.selection.previous.?, .work);
                if (!std.meta.eql(
                    try successors.next(self, previous_id),
                    @as(?state.Digest, work.id),
                ))
                    return error.InvalidArchive;
                if (!std.meta.eql(prior.value.task, work.task) or
                    !std.meta.eql(prior.value.id, previous_id) or
                    !std.meta.eql(prior.value.result_value, observer.accumulator) or
                    prior.value.outcome_kind != .completed or prior.value.cancellation != null)
                    return error.InvalidArchive;
                try validateWorkspacePublication(self, a, work.task, .{
                    .work = prior.value,
                    .occurrence = null,
                });
                try successors.histories.validateCursor(self, a, prior.value);
                const before = prior.value.observer orelse return error.InvalidArchive;
                const consumed = before.consumed_revision orelse return error.InvalidArchive;
                if (!std.meta.eql(prior.value.program, work.program) or
                    !std.meta.eql(before.source_work, observer.source_work) or
                    observer.source_revision <= consumed) return error.InvalidArchive;
                try observerScope(a, before.selection.source, observer.selection.source);
                const skipped = observer.source_revision - consumed > 1;
                if (observer.selection.policy.delivery == .lossless and skipped)
                    return error.InvalidArchive;
                if (observer.gap_first != @as(?u64, if (skipped) consumed + 1 else null) or
                    observer.gap_last != @as(?u64, if (skipped)
                        observer.source_revision - 1
                    else
                        null)) return error.InvalidArchive;
            } else {
                const initial =
                    try workspaceValueReference(self, a, work.task, observer.selection.accumulator);
                if (!std.meta.eql(initial.artifact, observer.accumulator) or
                    observer.gap_first != null or observer.gap_last != null)
                    return error.InvalidArchive;
            }
        }
        pub fn validateObserver(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            successors: *ObserverSuccessors,
        ) !void {
            try successors.histories.validateCursor(self, a, work);
            const observer = work.observer orelse return;
            if (observer.successor != null and
                !std.meta.eql(observer.successor, try successors.next(self, work.id)))
                return error.InvalidArchive;
            @import("../workspace_observers.zig").validatePolicy(observer.selection.policy) catch
                return error.InvalidArchive;
            try validateObserverIncomplete(self, a, work, &successors.histories);
            if ((observer.previous == null) != (observer.selection.previous == null))
                return error.InvalidArchive;
            const custody =
                try workspaceContentCustody(a, work.task, observer.source.digest);
            var saved =
                try record(self, workspace.Value, a, "workspace_value", custody, work.task);
            defer saved.deinit();
            const origin = saved.value.derivation.inspection orelse return error.InvalidArchive;
            if (!std.meta.eql(origin.observation.work.task, work.task)) return error.InvalidArchive;
            try successors.histories.validateCursor(self, a, origin.observation.work);
            try inspectionSelection(origin.observation.work, observer.selection.source);
            var selected = observer.selection.source;
            selected.level = origin.level;
            selected.nodes = origin.nodes;
            selected.disclosure = origin.disclosure;
            try observerScope(a, selected, observer.selection.source);
            const source_revision = try observerSourceRevision(
                self,
                a,
                origin.observation.work,
                observer.selection.source.level,
            );
            if (!std.meta.eql(origin.observation.work.id, observer.source_work) or
                source_revision != observer.source_revision)
                return error.InvalidArchive;
            if (!std.meta.eql(work.program, try wp.identity(observer.selection.program, .program)))
                return error.InvalidArchive;
            if (observer.consumed_revision != @as(?u64, if (work.outcome_kind == .completed)
                observer.source_revision
            else
                null))
                return error.InvalidArchive;
            const expected = try observerInput(self, a, work.task, observer);
            defer a.free(expected);
            if (!std.meta.eql(storage.digest(expected), work.input.digest) or
                expected.len != work.input.bytes) return error.InvalidArchive;
            try validateObserverPrevious(self, a, work, observer, successors);
        }
        fn observerScope(
            a: std.mem.Allocator,
            before: wc.GuestViewSelection,
            after: wc.GuestViewSelection,
        ) !void {
            var expected = before;
            expected.expected = after.expected;
            expected.realization_revision = after.realization_revision;
            const old = try contracts.encodeOwned(wc.GuestViewSelection, a, expected);
            defer a.free(old);
            const new = try contracts.encodeOwned(wc.GuestViewSelection, a, after);
            defer a.free(new);
            if (!same(old, new)) return error.InvalidObserverInput;
        }
    };
}
