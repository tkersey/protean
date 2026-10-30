const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const registry = @import("../registry.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Recovered = task_types.Recovered;
const RecoveryAvailability = task_types.RecoveryAvailability;
const RecoveryCompletion = task_types.RecoveryCompletion;
const Step = task_types.Step;
const name = task_types.name;
const reconcileDigest = task_types.reconcileDigest;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const claim = Scheduling.claim;
        const compatible = Controller.compatible;
        const effectSchedule = Root.effectSchedule;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const event = Records.event;
        const occurrenceImage = Root.occurrenceImage;
        const occurrenceProjectionBinding = Worker.occurrenceProjectionBinding;
        const occurrenceSubject = Root.occurrenceSubject;
        const persistOccurrence = Root.persistOccurrence;
        const prepareProjection = Worker.prepareProjection;
        const record = Records.record;
        const recoveryReceipt = Records.recoveryReceipt;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const runnableRemove = Scheduling.runnableRemove;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        pub fn recoveryAvailability(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !?RecoveryAvailability {
            // Public recovery hints contain original IDs and compiled mechanisms,
            // never prepared bytes or an authority to provide replacement replies.
            return subjectRecoveryAvailability(self, a, task_id, null);
        }
        pub fn subjectRecoveryAvailability(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            residual_id: ?state.Digest,
        ) !?RecoveryAvailability {
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            const value = decoded.value;
            const id = if (residual_id) |residual| blk: {
                var saved = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    residual,
                    task_id,
                );
                defer saved.deinit();
                break :blk saved.value.current_occurrence orelse return null;
            } else value.current_occurrence orelse return null;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, task_id);
            defer pending.deinit();
            if (pending.value.state != .unknown) return null;
            var result: RecoveryAvailability = .{
                .occurrence = id,
                .attempt = pending.value.state.unknown.id,
                .mechanisms = &.{},
            };
            compatible(self, value) catch |err|
                return if (err == error.IncompatibleProfile) result else err;
            const bytes = try store(self).object(a, pending.value.request_object, null);
            defer a.free(bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, bytes);
            defer request.deinit();
            const entry = self.handlers.resolve(
                request.value,
                try occurrenceImage(self, a, value, pending.value),
            ) catch |err| switch (err) {
                error.MissingCapability,
                error.CapabilitySchemaMismatch,
                error.Denied,
                => return result,
                else => return err,
            };
            if (entry.declaration.recovery) |adapter| {
                const can_lookup = adapter.lookup != null and blk: {
                    _ = self.handlers.admit(
                        request.value,
                        self.profile.authority,
                        try occurrenceImage(self, a, value, pending.value),
                        registry.resourceIdentity(
                            self.application.image_identity,
                            value.profile.digest,
                            value.resources.items,
                        ),
                    ) catch break :blk false;
                    break :blk true;
                };
                result.mechanisms = if (adapter.rederive != null) (if (can_lookup) &.{
                    .rederive,
                    .lookup,
                } else &.{.rederive}) else if (can_lookup) &.{.lookup} else &.{};
            }
            return result;
        }
        pub fn reconciliation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !contracts.Decoded(state.Reconciliation) {
            var authorized = try self.task(a, task_id);
            defer authorized.deinit();
            return record(self, state.Reconciliation, a, "reconciliation", id, task_id);
        }
        pub fn reconcile(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            expected: u64,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
            recovery: state.RecoveryRequest,
        ) !Admission {
            // Admit explicit recovery. Receipt lookup precedes revision/state
            // checks; pure computation completes locally, while asynchronous
            // lookup gets a sealed pending record before the worker may start.
            const request_digest =
                try reconcileDigest(a, task_id, expected, occurrence_id, attempt_id, recovery);
            if (try replay(self, a, id, request_digest)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            const value = decoded.value;
            try compatible(self, value);
            if (value.revision != expected) return error.StaleRevision;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", occurrence_id, task_id);
            defer pending.deinit();
            try validateReconciliation(self, a, value, pending.value, occurrence_id, attempt_id);
            var attempt =
                try record(self, state.Attempt, a, "attempt", attempt_id, task_id);
            defer attempt.deinit();
            var original_request = try recoveryRequest(self, a, attempt.value);
            defer original_request.deinit();
            const entry = try self.handlers.resolve(
                original_request.value,
                try occurrenceImage(self, a, value, pending.value),
            );
            const asynchronous = try admitRecoveryMechanism(
                self,
                a,
                value,
                pending.value,
                attempt.value,
                original_request.value,
                entry,
                recovery,
                occurrence_id,
                attempt_id,
            );
            return publishReconciliation(
                self,
                a,
                id,
                value,
                pending.value,
                attempt.value,
                request_digest,
                recovery,
                entry,
                asynchronous,
                occurrence_id,
                attempt_id,
            );
        }
        fn recoveryRequest(
            self: *Self,
            a: std.mem.Allocator,
            attempt: state.Attempt,
        ) !data.invocation.Owned(data.invocation.Request) {
            const request_bytes = try store(self).object(a, attempt.request, null);
            defer a.free(request_bytes);
            return try data.invocation.decode(data.invocation.Request, a, request_bytes);
        }
        fn validateReconciliation(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: occurrence.Occurrence,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
        ) !void {
            if (pending.work != null) return error.StaleOccurrence;
            _ = try occurrenceSubject(self, a, value, pending);
            if (pending.state != .unknown) return error.UnsettledOccurrence;
            if (!same(&pending.state.unknown.id, &attempt_id)) return error.StaleOccurrence;
            if (try pendingRecovery(self, a, value.id, occurrence_id, attempt_id) != null)
                return error.UnsettledOccurrence;
        }
        fn validateLookupRecovery(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            request: data.invocation.Request,
            entry: anytype,
        ) !void {
            _ = try self.handlers.admit(
                request,
                self.profile.authority,
                try occurrenceImage(self, a, value, pending),
                registry.resourceIdentity(
                    self.application.image_identity,
                    value.profile.digest,
                    value.resources.items,
                ),
            );
            if (entry.declaration.capture) |adapter| {
                const prepared = try store(self).object(a, attempt.prepared orelse
                    return error.CorruptState, null);
                defer a.free(prepared);
                const expected_prepared = try prepareProjection(
                    self,
                    a,
                    value,
                    pending,
                    adapter,
                    try entry.payload(a, request.binding.payload),
                );
                defer a.free(expected_prepared);
                if (!same(prepared, expected_prepared)) return error.CorruptState;
            }
        }
        fn admitRecoveryMechanism(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            request: data.invocation.Request,
            entry: anytype,
            recovery: state.RecoveryRequest,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
        ) !bool {
            const lookup = recovery == .lookup and
                if (entry.declaration.recovery) |adapter| adapter.lookup != null else false;
            if (lookup)
                try validateLookupRecovery(self, a, value, pending, attempt, request, entry);
            const rederive = recovery == .rederive and
                if (entry.declaration.recovery) |adapter| adapter.rederive != null else false;
            if (rederive) try validateRederivation(self, a, value.id, occurrence_id, attempt_id);
            const asynchronous = lookup or rederive;
            if (asynchronous) {
                try ensureOwnershipCapacity(self, value.id);
                try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            }
            return asynchronous;
        }
        fn reconciliationRecord(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            value: state.Task,
            _: occurrence.Occurrence,
            attempt: state.Attempt,
            request_digest: state.Digest,
            recovery: state.RecoveryRequest,
            entry: anytype,
            asynchronous: bool,
            reconciliation_id: state.Digest,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
        ) !state.Reconciliation {
            const task_id = value.id;
            return .{
                .id = reconciliation_id,
                .task = task_id,
                .client_operation_id = try name(id),
                .request_digest = request_digest,
                .admission_revision = value.revision,
                .occurrence = occurrence_id,
                .attempt = attempt_id,
                .original_occurrence = try snapshotRecord(
                    self,
                    occurrence.Occurrence,
                    a,
                    "occurrence",
                    occurrence_id,
                    task_id,
                ),
                .original_attempt = try snapshotRecord(
                    self,
                    state.Attempt,
                    a,
                    "attempt",
                    attempt_id,
                    task_id,
                ),
                .request = attempt.request,
                .prepared = attempt.prepared,
                .profile = value.profile,
                .resources = value.resources,
                .capability = attempt.capability,
                .mechanism = try name(
                    if (entry.declaration.recovery) |adapter| adapter.identity else "unavailable",
                ),
                .mechanism_version = if (entry.declaration.recovery) |adapter|
                    adapter.version
                else
                    0,
                .provenance = .none,
                .outcome = .{ .unresolved = .unsupported },
                .selection = recovery,
                .owner_epoch = if (asynchronous) self.owner_epoch else null,
            };
        }
        fn publishReconciliation(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            initial: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            request_digest: state.Digest,
            recovery: state.RecoveryRequest,
            entry: anytype,
            asynchronous: bool,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
        ) !Admission {
            var value = initial;
            const expected = initial.revision;
            const task_id = initial.id;
            var reconciliation_id: state.Digest = undefined;
            try self.io.randomSecure(&reconciliation_id);
            value.revision = try std.math.add(u64, expected, 1);
            try store(self).begin();
            defer store(self).rollback();
            var result = try reconciliationRecord(
                self,
                a,
                id,
                value,
                pending,
                attempt,
                request_digest,
                recovery,
                entry,
                asynchronous,
                reconciliation_id,
                occurrence_id,
                attempt_id,
            );
            if (asynchronous) try queueReconciliation(self, a, &value, &result, attempt_id);
            if (pending.residual != null) {
                if (asynchronous) try effectSchedule(self, a, &value, pending, .queued, null);
                value.schedule = initial.schedule;
                value.blocker = initial.blocker;
            }
            try store(self).createRecord(
                state.Reconciliation,
                "reconciliation",
                reconciliation_id,
                task_id,
                result,
            );
            const admitted =
                try reconciliationAdmission(self, a, id, request_digest, &value, reconciliation_id);
            try persistOccurrence(
                self,
                a,
                value,
                expected,
                "task.reconcile",
                pending,
                asynchronous,
            );
            if (asynchronous) {
                claim(self, task_id);
            }
            return admitted;
        }
        fn queueReconciliation(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            result: *state.Reconciliation,
            attempt_id: state.Digest,
        ) !void {
            result.outcome = .pending;
            value.schedule = .queued;
            value.blocker = null;
            if (try store(self).recordBytes(a, "capture", attempt_id, value.id)) |prior| {
                defer a.free(prior);
                result.original_capture = try store(self).putObject(prior);
            }
        }
        fn reconciliationAdmission(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request_digest: state.Digest,
            value: *state.Task,
            reconciliation_id: state.Digest,
        ) !Admission {
            const event_data = try std.fmt.allocPrint(a, "{{\"reconciliation_id\":\"{s}\"}}", .{
                std.fmt.bytesToHex(reconciliation_id, .lower),
            });
            defer a.free(event_data);
            try event(self, value, .reconciled, event_data);
            const admitted = try recoveryReceipt(
                self,
                a,
                .reconcile,
                id,
                request_digest,
                value.*,
                .reconciled,
                null,
                null,
                reconciliation_id,
            );
            return admitted;
        }
        pub fn pendingRecovery(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
        ) !?state.Digest {
            var rows = try store(self).database.prepare(
                "SELECT id FROM records WHERE kind='reconciliation' AND task=?",
                &.{.{ .blob = &task_id }},
            );
            defer rows.deinit();
            var result: ?state.Digest = null;
            while (try rows.step() == .row) {
                const bytes = try rows.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                var item = try record(
                    self,
                    state.Reconciliation,
                    a,
                    "reconciliation",
                    bytes[0..32].*,
                    task_id,
                );
                defer item.deinit();
                if (item.value.outcome != .pending) continue;
                if (!same(&item.value.occurrence, &occurrence_id) or
                    !same(&item.value.attempt, &attempt_id))
                    continue;
                if (result != null) return error.CorruptState;
                result = item.value.id;
            }
            return result;
        }
        pub fn recoveryWork(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: occurrence.Occurrence,
            id: state.Digest,
        ) !Step {
            if (self.work != null) return .idle;
            var saved =
                try record(self, state.Reconciliation, a, "reconciliation", id, value.id);
            defer saved.deinit();
            const item = saved.value;
            if (item.outcome != .pending or item.owner_epoch == null or
                !same(&item.owner_epoch.?, &self.owner_epoch)) return error.CorruptState;
            const request = try store(self).object(self.allocator, item.request, null);
            errdefer self.allocator.free(request);
            var decoded = try data.invocation.decode(data.invocation.Request, a, request);
            defer decoded.deinit();
            const entry = if (item.selection == .rederive) try self.handlers.resolve(
                decoded.value,
                try occurrenceImage(self, a, value, pending),
            ) else self.handlers.admit(
                decoded.value,
                self.profile.authority,
                try occurrenceImage(self, a, value, pending),
                registry.resourceIdentity(
                    self.application.image_identity,
                    value.profile.digest,
                    value.resources.items,
                ),
            ) catch {
                try finishRecovery(self, a, value, pending, item, null, .unavailable);
                self.allocator.free(request);
                return .progressed;
            };
            const prepared = if (item.prepared) |ref| try store(self).object(
                self.allocator,
                ref,
                null,
            ) else null;
            errdefer if (prepared) |bytes| self.allocator.free(bytes);
            const profile = try store(self).object(self.allocator, value.profile, null);
            errdefer self.allocator.free(profile);
            const body = try contracts.encodeOwned(state.Reconciliation, self.allocator, item);
            self.work = .{
                .owner_epoch = self.owner_epoch,
                .task = value.id,
                .subject_work = pending.work,
                .subject_residual = pending.residual,
                .occurrence = pending.id,
                .attempt = item.attempt,
                .request = request,
                .prepared = prepared,
                .profile = profile,
                .entry = entry,
                .cleanup = pending.residual != null,
                .recovery = .{ .id = id, .body = body },
            };
            return .{ .work = self.work.? };
        }
        fn recoveryFinding(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            original: state.Reconciliation,
            identity: state.Digest,
            completion: RecoveryCompletion,
        ) !Recovered {
            const request_bytes = try store(self).object(a, original.request, null);
            defer a.free(request_bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            if (!same(&request.value.request_identity, &identity)) return error.InvalidRecovery;
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                original.occurrence,
                initial.id,
            );
            defer pending.deinit();
            const entry = try self.handlers.resolve(
                request.value,
                try occurrenceImage(self, a, initial, pending.value),
            );
            if (completion == .rederived) return rederivedFinding(a, original, completion, entry);
            if (original.selection != .lookup) return error.InvalidRecovery;
            const finding = try store(self).project(
                registry.RecoveryFinding,
                a,
                self.handlers,
                try occurrenceProjectionBinding(self, a, initial, pending.value),
                struct {
                    handlers: registry.Registry,
                    input: registry.RecoveryInput,
                    evidence: []const u8,
                    pub fn run(
                        this: @This(),
                        ctx: registry.ProjectionContext,
                    ) !registry.RecoveryFinding {
                        return this.handlers.verifyRecovery(ctx, this.input, this.evidence);
                    }
                }{ .handlers = self.handlers, .input = registry.RecoveryInput.fromReconciliation(
                    original,
                    identity,
                    entry.declaration.inference,
                ), .evidence = completion.evidence },
            );
            return switch (finding) {
                .capture => |bytes| .{ .capture = bytes },
                .not_sent => .not_sent,
                .inconclusive => .inconclusive,
                .unavailable => .unavailable,
                .rejected => .rejected,
            };
        }
        fn rederivedFinding(
            a: std.mem.Allocator,
            original: state.Reconciliation,
            completion: RecoveryCompletion,
            entry: anytype,
        ) !Recovered {
            if (original.selection != .rederive or entry.declaration.recovery == null or
                entry.declaration.recovery.?.rederive == null)
                return error.InvalidRecovery;
            return switch (completion.rederived) {
                .unsupported => .unsupported,
                .unavailable => .unavailable,
                .inconclusive => .inconclusive,
                .rejected => .rejected,
                .result => |bytes| blk: {
                    if (entry.declaration.capture != null) break :blk .{ .capture = bytes };
                    var schema = try data.schema.decode(a, entry.resume_schema);
                    defer schema.deinit();
                    data.schema.validateValue(a, schema.descriptor, bytes) catch |err|
                        switch (err) {
                            error.OutOfMemory, error.Capacity => return err,
                            else => return .rejected,
                        };
                    break :blk .{ .reply = bytes };
                },
            };
        }
        pub fn finishRecovery(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            original: state.Reconciliation,
            completion: ?RecoveryCompletion,
            failure: @FieldType(@FieldType(state.Reconciliation, "outcome"), "unresolved"),
        ) !void {
            try validateRecoveryCompletion(self, a, initial, pending, original);
            if (completion != null) _ = try occurrenceSubject(self, a, initial, pending);
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const verified: ?Recovered = if (completion) |result| try recoveryFinding(
                self,
                arena.allocator(),
                initial,
                original,
                pending.request,
                result,
            ) else null;
            const advancing = if (verified) |finding| finding == .capture or
                finding == .reply or
                (finding == .not_sent and pending.residual == null) else false;
            if (advancing) try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .parked;
            value.blocker = .unavailable_environment;
            try store(self).begin();
            defer store(self).rollback();
            var result =
                try recoveryCompletionRecord(self, a, value.id, original, completion, failure);
            try applyRecoveryFinding(self, a, &value, pending, original, &result, verified);
            if (pending.residual != null) {
                try effectSchedule(
                    self,
                    a,
                    &value,
                    pending,
                    if (advancing) .queued else .parked,
                    if (advancing) null else .unavailable_environment,
                );
                value.schedule = initial.schedule;
                value.blocker = initial.blocker;
            }
            try store(self).putRecord(
                state.Reconciliation,
                "reconciliation",
                result.id,
                value.id,
                result,
            );
            try persistOccurrence(
                self,
                a,
                value,
                initial.revision,
                "recovery.complete",
                pending,
                if (pending.residual != null) advancing else value.schedule == .queued,
            );
            if (pending.residual == null and
                value.schedule != .queued) runnableRemove(self, value.id);
        }
        fn recoveryCompletionRecord(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            original: state.Reconciliation,
            completion: ?RecoveryCompletion,
            failure: @FieldType(@FieldType(state.Reconciliation, "outcome"), "unresolved"),
        ) !state.Reconciliation {
            var result = original;
            result.previous = try snapshotRecord(
                self,
                state.Reconciliation,
                a,
                "reconciliation",
                original.id,
                task_id,
            );
            result.evidence = if (completion != null and completion.? == .evidence)
                try store(self).putObject(completion.?.evidence)
            else
                null;
            result.outcome = .{ .unresolved = failure };
            return result;
        }
        fn validateRecoveryCompletion(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            original: state.Reconciliation,
        ) !void {
            if (original.outcome != .pending or pending.state != .unknown or
                !same(&pending.state.unknown.id, &original.attempt)) return error.StaleOccurrence;
            if (!std.meta.eql(original.task, initial.id) or
                !std.meta.eql(pending.task, initial.id) or
                !std.meta.eql(original.occurrence, pending.id) or pending.work != null)
                return error.StaleOccurrence;
            if (pending.residual) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    initial.id,
                );
                defer residual.deinit();
                if (!residual.value.cancellation_applied or !std.meta.eql(
                    residual.value.current_occurrence,
                    pending.id,
                )) return error.StaleOccurrence;
            } else if (!std.meta.eql(initial.current_occurrence, pending.id))
                return error.StaleOccurrence;
        }
        fn completeRecoveryCapture(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            pending: occurrence.Occurrence,
            original: state.Reconciliation,
            result: *state.Reconciliation,
            raw: []const u8,
        ) !void {
            const capture_value: state.Capture = .{
                .task = value.id,
                .occurrence = pending.id,
                .attempt = original.attempt,
                .request = original.prepared orelse return error.CorruptState,
                .response = try store(self).putObject(raw),
                .disposition = .complete,
                .reconciliation = original.id,
            };
            if (try store(self).recordBytes(a, "capture", original.attempt, value.id)) |prior| {
                defer a.free(prior);
                if (original.original_capture == null) return error.CorruptState;
                try store(self).putRecord(
                    state.Capture,
                    "capture",
                    original.attempt,
                    value.id,
                    capture_value,
                );
            } else try store(self).createRecord(
                state.Capture,
                "capture",
                original.attempt,
                value.id,
                capture_value,
            );
            result.provenance =
                if (original.selection == .rederive) .rederived else .authentic;
            result.outcome = .{ .capture_admitted = capture_value.response.? };
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                value.id,
                try occurrence.recoveredCapture(
                    pending,
                    .{
                        .id = pending.id,
                        .task = value.id,
                        .work = pending.work,
                        .residual = pending.residual,
                        .request = pending.request,
                    },
                    original.attempt,
                ),
            );
            value.schedule = .queued;
            value.blocker = null;
        }
        fn completeRecoveryReply(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            pending: occurrence.Occurrence,
            original: state.Reconciliation,
            result: *state.Reconciliation,
            bytes: []const u8,
        ) !void {
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = bytes,
            });
            defer a.free(bound);
            const ref = try store(self).putObject(bound);
            result.provenance = .rederived;
            result.outcome = .{ .reply_settled = ref };
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                value.id,
                try occurrence.acquired(
                    pending,
                    .{
                        .id = pending.id,
                        .task = value.id,
                        .work = pending.work,
                        .residual = pending.residual,
                        .request = pending.request,
                    },
                    original.attempt,
                    ref.digest,
                ),
            );
            value.schedule = .queued;
            value.blocker = null;
        }
        fn completeRecoveryNotSent(
            self: *Self,
            _: std.mem.Allocator,
            value: *state.Task,
            pending: occurrence.Occurrence,
            original: state.Reconciliation,
            result: *state.Reconciliation,
        ) !void {
            result.provenance = .authoritative;
            result.outcome = .{ .not_sent = result.evidence.? };
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                value.id,
                try occurrence.recoveredNotSent(
                    pending,
                    .{
                        .id = pending.id,
                        .task = value.id,
                        .work = pending.work,
                        .residual = pending.residual,
                        .request = pending.request,
                    },
                    original.attempt,
                ),
            );
            if (value.cancellation != null) {
                value.schedule = .queued;
                value.blocker = null;
            }
        }
        fn applyRecoveryFinding(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            pending: occurrence.Occurrence,
            original: state.Reconciliation,
            result: *state.Reconciliation,
            verified: ?Recovered,
        ) !void {
            if (verified) |finding| switch (finding) {
                .unsupported => result.outcome = .{ .unresolved = .unsupported },
                .inconclusive => result.outcome = .{ .unresolved = .inconclusive },
                .unavailable => result.outcome = .{ .unresolved = .unavailable },
                .rejected => result.outcome = .{ .unresolved = .rejected },
                .capture => |raw| try completeRecoveryCapture(
                    self,
                    a,
                    value,
                    pending,
                    original,
                    result,
                    raw,
                ),
                .reply => |bytes| try completeRecoveryReply(
                    self,
                    a,
                    value,
                    pending,
                    original,
                    result,
                    bytes,
                ),
                .not_sent => try completeRecoveryNotSent(self, a, value, pending, original, result),
            };
        }
        fn validateRederivation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
        ) !void {
            // Check the original immutable inputs before sealing recovery admission.
            // No computation or borrowed projection view escapes this call.
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            const value = decoded.value;
            try compatible(self, value);
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", occurrence_id, task_id);
            defer pending.deinit();
            if (pending.value.work != null) return error.StaleOccurrence;
            _ = try occurrenceSubject(self, a, value, pending.value);
            if (pending.value.state != .unknown) return error.UnsettledOccurrence;
            if (!same(&pending.value.state.unknown.id, &attempt_id)) return error.StaleOccurrence;
            var attempt =
                try record(self, state.Attempt, a, "attempt", attempt_id, task_id);
            defer attempt.deinit();
            const original = attempt.value;
            if (!same(&original.id, &attempt_id) or
                !same(&original.task, &task_id) or
                !same(&original.occurrence, &occurrence_id) or
                !std.meta.eql(original.profile, value.profile) or !std.meta.eql(
                original.request,
                pending.value.request_object,
            )) return error.CorruptState;
            const input: registry.RecoveryInput = .{
                .task = task_id,
                .occurrence = occurrence_id,
                .attempt = attempt_id,
                .request_identity = pending.value.request,
                .request = original.request,
                .prepared = original.prepared,
                .profile = original.profile,
                .resources = value.resources.items,
                .capability = original.capability.bytes,
                .inference = original.inference,
            };
            return store(self).project(
                void,
                a,
                self.handlers,
                try occurrenceProjectionBinding(self, a, value, pending.value),
                struct {
                    handlers: registry.Registry,
                    input: registry.RecoveryInput,
                    pub fn run(this: @This(), ctx: registry.ProjectionContext) !void {
                        return this.handlers.validateRederivation(ctx, this.input);
                    }
                }{ .handlers = self.handlers, .input = input },
            );
        }
    };
}
