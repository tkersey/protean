//! Sole native task/occurrence mutation owner. Front ends submit ordinary typed
//! inputs; workers return acquired bytes. Neither can drive a Kosmos resident.
const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("state.zig");
const occurrence = @import("occurrence.zig");
const storage = @import("store.zig");
const Namespace = @import("namespace.zig").Namespace;
const evaluator = @import("driver.zig");
const registry = @import("registry.zig");
const discovery = @import("discovery.zig");
const json = @import("json.zig");
const values = @import("values.zig");
const workspace = @import("workspace_state.zig");
const build_job = @import("workspace_build.zig");
const instrument = @import("workspace_instrument.zig");
const wp = @import("workspace_projection.zig");
const wc = contracts.workspace;
const construction = @import("program_construction.zig");
const archive_api = @import("archive.zig");

/// Terminal execution and settled cleanup are distinct Kosmos observations.
pub fn cleanupComplete(outcome: data.invocation.Outcome) bool {
    return switch (outcome) {
        .completed => true,
        .failed => |failure| std.mem.eql(u8, failure.cleanup_failures, &.{0}),
        .cancelled => |cancelled| std.mem.eql(u8, cancelled.cleanup_failures, &.{0}),
        else => false,
    };
}

pub const Profile = struct {
    id: []const u8,
    runtime_identity: state.Digest,
    /// Admitted immutable profile bytes, including concrete resource bindings.
    bytes: []const u8,
    authority: registry.Authority,
    /// Launch-owned adapter state, never persisted. Its stable address and
    /// backing allocations must outlive every joined worker using this profile.
    environment: ?*anyopaque = null,
    /// Immutable resource objects admitted with every new task. Their ordinary
    /// references are retained by the task and therefore included in archives.
    resources: []const []const u8 = &.{},

    pub fn validate(self: Profile) !void {
        _ = try name(self.id);
        _ = try name(self.authority.principal);
        if (self.authority.revoked) return error.Denied;
    }

    pub fn resourceIdentity(self: Profile, a: std.mem.Allocator, image: state.Digest) !state.Digest {
        const refs = try a.alloc(state.Reference, self.resources.len);
        defer a.free(refs);
        for (self.resources, refs) |bytes, *ref| ref.* = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        return registry.resourceIdentity(image, storage.digest(self.bytes), refs);
    }
};
pub const FrozenInputs = struct {
    profile_id: []const u8,
    profile: []const u8,
    resources: []const []const u8,
};
fn readFrozenInputs(a: std.mem.Allocator, value: state.Task, source: anytype) !FrozenInputs {
    const resources = try a.alloc([]const u8, value.resources.items.len);
    var acquired: usize = 0;
    errdefer {
        for (resources[0..acquired]) |bytes| a.free(bytes);
        a.free(resources);
    }
    for (value.resources.items, resources) |reference, *bytes| {
        bytes.* = try source.object(a, reference, null);
        acquired += 1;
    }
    const profile_id = try a.dupe(u8, value.profile_id.bytes);
    errdefer a.free(profile_id);
    return .{ .profile_id = profile_id, .profile = try source.object(a, value.profile, null), .resources = resources };
}
pub const Admission = struct { receipt: state.Receipt, replayed: bool };
pub const RecoveryAvailability = struct { occurrence: state.Digest, attempt: state.Digest, mechanisms: []const state.RecoveryRequest };
pub const Status = state.Status;
pub const Work = struct {
    owner_epoch: state.Digest,
    task: state.TaskId,
    subject_work: ?state.Digest = null,
    operation: state.AttemptOperation = .environment,
    occurrence: state.Digest,
    attempt: state.Digest,
    request: []const u8,
    prepared: ?[]const u8 = null,
    profile: []const u8 = &.{},
    entry: registry.Entry,
    cleanup: bool,
    /// A new cancellation request for this physical work, not prior task intent.
    cancel_requested: bool = false,
    recovery: ?struct { id: state.Digest, body: []const u8 } = null,
};
pub const WorkResult = union(enum) {
    acquired: []const u8,
    rederived: registry.RederivationFinding,
    not_sent,
    unknown,
    failure: anyerror,
};
const RecoveryCompletion = union(enum) { evidence: []const u8, rederived: registry.RederivationFinding };
const Recovered = union(enum) { capture: []const u8, reply: []const u8, not_sent, unsupported, unavailable, inconclusive, rejected };
pub const Step = union(enum) { idle, progressed, waiting, work: Work };
const Active = struct { task: state.TaskId, work: ?state.Digest = null, execution_revision: u64, driver: *evaluator.Driver };

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn operation(comptime T: type, a: std.mem.Allocator, value: T) !state.Digest {
    const bytes = try contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(bytes);
    var result: state.Digest = undefined;
    hash.final(&result);
    return result;
}
fn name(bytes: []const u8) !state.Name {
    if (bytes.len == 0 or bytes.len > 128 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidParams;
    return .{ .bytes = bytes };
}
fn answerDigest(a: std.mem.Allocator, task_id: state.TaskId, question_id: state.Digest, revision: u64, request_digest: state.Digest, schema_id: []const u8, answer: []const u8) !state.Digest {
    const Request = struct { method: state.Method, task: state.TaskId, question: state.Digest, revision: u64, request: state.Digest, schema: state.Name, answer: contracts.Bytes(null) };
    return operation(Request, a, .{ .method = .respond, .task = task_id, .question = question_id, .revision = revision, .request = request_digest, .schema = try name(schema_id), .answer = .{ .bytes = answer } });
}

fn cancelDigest(a: std.mem.Allocator, task_id: state.TaskId, reason: state.Reason) !state.Digest {
    const Request = struct { method: state.Method, task: state.TaskId, reason: state.Reason };
    return operation(Request, a, .{ .method = .cancel, .task = task_id, .reason = reason });
}

fn reconcileDigest(a: std.mem.Allocator, task_id: state.TaskId, expected: u64, occurrence_id: state.Digest, attempt_id: state.Digest, recovery: state.RecoveryRequest) !state.Digest {
    const Request = struct { method: state.Method, task: state.TaskId, revision: u64, occurrence: state.Digest, attempt: state.Digest, recovery: state.RecoveryRequest };
    return operation(Request, a, .{ .method = .reconcile, .task = task_id, .revision = expected, .occurrence = occurrence_id, .attempt = attempt_id, .recovery = recovery });
}

pub fn Service(comptime Types: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        namespace: *Namespace,
        assets: discovery.Assets,
        application: *const discovery.Application,
        handlers: registry.Registry,
        profile: Profile,
        program: *evaluator.Program,
        active: ?Active = null,
        /// Only this process's explicit admissions/resumes are runnable. Merely
        /// opening a namespace never resumes a persisted task.
        runnable: std.ArrayList(workspace.Subject) = .empty,
        /// Logical queue order is items[cursor..] followed by items[0..cursor].
        /// Advancing a turn must not move every remaining ID.
        runnable_cursor: usize = 0,
        /// Unsettled cleanup retains ownership, but never runnable work.
        owned: std.ArrayList(state.TaskId) = .empty,
        owner_epoch: state.Digest = undefined,
        work: ?Work = null,
        checked_workspace_programs: std.AutoHashMapUnmanaged(state.Digest, u64) = .empty,

        pub fn init(a: std.mem.Allocator, io: std.Io, namespace: *Namespace, assets: discovery.Assets, application: *const discovery.Application, handlers: registry.Registry, profile: Profile) !Self {
            try profile.validate();
            var self: Self = .{ .allocator = a, .io = io, .namespace = namespace, .assets = assets, .application = application, .handlers = handlers, .profile = profile, .program = try evaluator.Program.open(a, assets.image) };
            errdefer self.program.close() catch unreachable;
            try io.randomSecure(&self.owner_epoch);
            _ = try self.store().auditRetention(handlers, application.image_identity);
            try self.recover(a);
            try self.recoverWorkspace(a);
            return self;
        }
        fn store(self: *Self) *storage.Store {
            return &self.namespace.store;
        }
        fn allowed(self: *Self) !void {
            if (self.profile.authority.revoked or !self.profile.authority.disclosure) return error.Denied;
            if (self.store().fenced) return error.StorageUnavailable;
        }
        pub fn task(self: *Self, a: std.mem.Allocator, id: state.TaskId) !contracts.Decoded(state.Task) {
            try self.allowed();
            const bytes = try self.store().taskBytes(a, id);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Task, a, bytes);
            errdefer decoded.deinit();
            if (!same(decoded.value.principal.bytes, self.profile.authority.principal) or !same(decoded.value.tenant.bytes, self.profile.authority.tenant)) return error.Denied;
            if (!same(&decoded.value.id, &id)) return error.CorruptState;
            return decoded;
        }
        pub fn schemaArtifact(self: *Self, id: state.Digest) !discovery.Artifact {
            try self.allowed();
            return self.application.schemaArtifact(id);
        }
        pub fn projectedArtifact(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest) !state.Reference {
            var value = try self.task(a, task_id);
            defer value.deinit();
            try self.compatibleApplication(value.value);
            if (!same(&value.value.runtime_identity, &self.profile.runtime_identity)) return error.ArtifactUnavailable;
            const owners = try self.store().projectionOwners(a, task_id, id);
            defer a.free(owners);
            for (owners) |owner| {
                var attempt = try self.record(state.Attempt, a, "attempt", owner.attempt, task_id);
                defer attempt.deinit();
                if (!std.meta.eql(attempt.value.profile, value.value.profile)) return error.CorruptState;
                const bytes = try self.store().object(a, attempt.value.request, null);
                defer a.free(bytes);
                var request = try data.invocation.decode(data.invocation.Request, a, bytes);
                defer request.deinit();
                const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                if (entry.declaration.public_outputs) return owner.object;
            }
            return error.ArtifactUnavailable;
        }
        /// Rebuild adapter state from owned immutable data, never from the
        /// original filesystem paths. This read does not resume or grant work.
        pub fn frozenInputs(self: *Self, a: std.mem.Allocator, id: state.TaskId) !FrozenInputs {
            var decoded = try self.task(a, id);
            defer decoded.deinit();
            return readFrozenInputs(a, decoded.value, self.store());
        }
        /// Supply only the owned launch data needed to configure an import.
        /// This preview admits no task, grant, resident or external operation.
        pub fn frozenArchiveInputs(self: *Self, a: std.mem.Allocator, path: []const u8) !FrozenInputs {
            try self.allowed();
            var reader = try archive_api.Reader.open(a, path);
            defer reader.deinit();
            const bytes = try reader.object(a, reader.manifest.value.task, null);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Task, a, bytes);
            defer decoded.deinit();
            if (!same(decoded.value.principal.bytes, self.profile.authority.principal) or !same(decoded.value.tenant.bytes, self.profile.authority.tenant)) return error.Denied;
            return readFrozenInputs(a, decoded.value, &reader);
        }
        pub fn pendingQuestion(self: *Self, a: std.mem.Allocator, id: state.TaskId) !?contracts.Decoded(state.Question) {
            var value = try self.task(a, id);
            defer value.deinit();
            const current = value.value.current_occurrence orelse return null;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", current, id);
            defer saved.deinit();
            const question_id = switch (saved.value.state) {
                .awaiting => |waiting| waiting.question,
                else => return null,
            };
            return try self.record(state.Question, a, "question", question_id, id);
        }
        pub fn status(self: *Self, a: std.mem.Allocator, value: state.Task) !Status {
            switch (value.outcome_kind) {
                .completed => return .completed,
                .failed => return .failed,
                .cancelled => return .cancelled,
                else => {},
            }
            if (value.current_occurrence) |id| {
                var saved = try self.record(occurrence.Occurrence, a, "occurrence", id, value.id);
                defer saved.deinit();
                if (saved.value.state == .unknown or (saved.value.state == .dispatching and (self.work == null or !same(&self.work.?.occurrence, &id)))) return .unknown;
                if (saved.value.state == .awaiting and (value.cancellation == null or value.cancellation_applied)) return .waiting_input;
            }
            if (value.blocker != null) return .blocked;
            if (value.cancellation != null) return .cancelling;
            // Worker-owned execution is active while ineligible for another turn.
            if (self.work) |work| if (same(&work.task, &value.id)) return .running;
            for (self.runnable.items) |subject| if (subject.work == null and same(&subject.task, &value.id)) return if (value.schedule == .queued) .queued else .running;
            return .parked;
        }
        pub fn taskCleanupComplete(self: *Self, a: std.mem.Allocator, value: state.Task) !bool {
            if (!value.terminal()) return false;
            const bytes = try self.store().object(a, value.outcome, null);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            return cleanupComplete(outcome.value) and try self.associatedWorkDisposed(a, value.id);
        }
        pub fn associatedWorkDisposed(self: *Self, a: std.mem.Allocator, task_id: state.TaskId) !bool {
            return self.workspaceSettled(a, task_id, true);
        }
        fn workspaceSettled(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, require_disposal: bool) !bool {
            const ids = try self.workspaceIds(a, task_id);
            defer a.free(ids);
            for (ids) |id| {
                var child = try self.workspaceWork(a, task_id, id);
                defer child.deinit();
                if (child.value.terminal()) {
                    const bytes = try self.store().object(a, child.value.outcome, null);
                    defer a.free(bytes);
                    var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                    defer outcome.deinit();
                    if (!cleanupComplete(outcome.value)) return false;
                } else {
                    if (require_disposal or child.value.cancellation != null) return false;
                    if (child.value.current_occurrence) |current| {
                        var pending = try self.record(occurrence.Occurrence, a, "occurrence", current, task_id);
                        defer pending.deinit();
                        switch (pending.value.state) {
                            .dispatching, .unknown, .captured, .settled_reply => return false,
                            else => {},
                        }
                    }
                }
            }
            return true;
        }
        pub fn shutdownIncomplete(self: *Self, a: std.mem.Allocator) !bool {
            for (self.owned.items) |id| {
                var decoded = try self.task(a, id);
                defer decoded.deinit();
                const value = decoded.value;
                if (value.terminal()) {
                    const bytes = try self.store().object(a, value.outcome, null);
                    defer a.free(bytes);
                    var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                    defer outcome.deinit();
                    if (!cleanupComplete(outcome.value)) return true;
                } else if (try self.status(a, value) == .unknown or value.cancellation != null) return true;
                if (!try self.workspaceSettled(a, id, false)) return true;
            }
            return false;
        }
        fn workspaceIds(self: *Self, a: std.mem.Allocator, task_id: state.TaskId) ![]state.Digest {
            var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id", &.{.{ .blob = &task_id }});
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

        fn recoverWorkspace(self: *Self, a: std.mem.Allocator) !void {
            const tasks = try self.store().taskIds(a, false);
            defer a.free(tasks);
            for (tasks) |task_id| {
                const ids = try self.workspaceIds(a, task_id);
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
                    var child = try self.retainedWorkspaceWork(a, task_id, id);
                    defer child.deinit();
                    const current = child.value.current_occurrence orelse continue;
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", current, task_id);
                    defer pending.deinit();
                    if (pending.value.state != .dispatching) continue;
                    const lost = try occurrence.unknown(pending.value, .{ .id = current, .task = task_id, .work = id, .request = pending.value.request }, pending.value.state.dispatching.id);
                    var value = parent.value;
                    value.revision = try std.math.add(u64, value.revision, 1);
                    try self.store().begin();
                    defer self.store().rollback();
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", current, task_id, lost);
                    try self.effectSchedule(a, &value, pending.value, .parked, .unavailable_environment, false);
                    try self.persist(a, value, parent.value.revision, "work.recover-unknown", .preserve);
                }
            }
        }
        fn cancelWorkspaceOne(self: *Self, a: std.mem.Allocator, parent: state.Task) !bool {
            const ids = try self.workspaceIds(a, parent.id);
            defer a.free(ids);
            for (ids) |id| {
                var child = try self.workspaceWork(a, parent.id, id);
                defer child.deinit();
                if (child.value.terminal() or child.value.cancellation != null) continue;
                const operation_id = try std.fmt.allocPrint(a, "task-cancel-{s}", .{std.fmt.bytesToHex(id, .lower)});
                defer a.free(operation_id);
                _ = try self.workspaceControl(a, operation_id, parent.id, id, child.value.execution_revision, child.value.control_revision, .{ .cancel = parent.cancellation.? });
                return true;
            }
            return false;
        }

        fn recover(self: *Self, a: std.mem.Allocator) !void {
            const ids = try self.store().taskIds(a, true);
            defer a.free(ids);
            for (ids) |id| {
                var decoded = self.task(a, id) catch |err| switch (err) {
                    error.Denied => continue,
                    else => return err,
                };
                defer decoded.deinit();
                var value = decoded.value;
                const current = value.current_occurrence orelse continue;
                var saved = try self.record(occurrence.Occurrence, a, "occurrence", current, id);
                defer saved.deinit();
                if (saved.value.state != .dispatching) continue;
                const binding: occurrence.Binding = .{ .id = current, .task = id, .request = saved.value.request };
                var attempt = try self.record(state.Attempt, a, "attempt", saved.value.state.dispatching.id, id);
                defer attempt.deinit();
                const compiling = attempt.value.operation == .workspace_build;
                const lost = if (compiling) try occurrence.notSent(saved.value, binding, saved.value.state.dispatching.id) else try occurrence.unknown(saved.value, binding, saved.value.state.dispatching.id);
                const previous = value.revision;
                value.revision = try std.math.add(u64, previous, 1);
                value.schedule = .parked;
                value.blocker = .unavailable_environment;
                try self.store().begin();
                defer self.store().rollback();
                try self.store().putRecord(occurrence.Occurrence, "occurrence", current, id, lost);
                try self.event(&value, if (compiling) .blocked else .delivery_unknown, "{}");
                try self.persist(a, value, previous, "process.recover-dispatched", .preserve);
            }
            for (ids) |id| {
                var decoded = self.task(a, id) catch |err| switch (err) {
                    error.Denied => continue,
                    else => return err,
                };
                defer decoded.deinit();
                const current = decoded.value.current_occurrence orelse continue;
                var saved = try self.record(occurrence.Occurrence, a, "occurrence", current, id);
                defer saved.deinit();
                if (saved.value.state != .unknown) continue;
                const pending = try self.pendingRecovery(a, id, current, saved.value.state.unknown.id) orelse continue;
                var item = try self.record(state.Reconciliation, a, "reconciliation", pending, id);
                defer item.deinit();
                try self.finishRecovery(a, decoded.value, saved.value, item.value, null, .interrupted);
            }
        }
        fn record(self: *Self, comptime T: type, a: std.mem.Allocator, comptime kind: []const u8, id: state.Digest, task_id: state.TaskId) !contracts.Decoded(T) {
            if (T != storage.Record(kind)) @compileError("native record type/kind mismatch");
            const bytes = (try self.store().recordBytes(a, kind, id, task_id)) orelse return error.CorruptState;
            defer a.free(bytes);
            return contracts.decodeOwned(T, a, bytes);
        }
        fn replay(self: *Self, a: std.mem.Allocator, id: []const u8, request: state.Digest) !?Admission {
            try self.allowed();
            _ = try name(id);
            const key = try self.operationKey(a, id);
            const bytes = (try self.store().receipt(a, &key, request)) orelse return null;
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Receipt, a, bytes);
            defer decoded.deinit();
            var bound_task = try self.task(a, decoded.value.task);
            defer bound_task.deinit();
            var saved = decoded.value;
            saved.client_operation_id = .{ .bytes = try a.dupe(u8, saved.client_operation_id.bytes) };
            return .{ .receipt = saved, .replayed = true };
        }
        fn operationKey(self: *Self, a: std.mem.Allocator, id: []const u8) ![64]u8 {
            const Key = struct { principal: state.Name, tenant: state.Name, operation_id: state.Name };
            return std.fmt.bytesToHex(try operation(Key, a, .{ .principal = try name(self.profile.authority.principal), .tenant = try name(self.profile.authority.tenant), .operation_id = try name(id) }), .lower);
        }
        fn receipt(self: *Self, a: std.mem.Allocator, method: state.Method, id: []const u8, request: state.Digest, task_value: state.Task, disposition: state.Disposition, message_id: ?state.Digest, question: ?state.Digest) !Admission {
            return self.recoveryReceipt(a, method, id, request, task_value, disposition, message_id, question, null);
        }
        fn recoveryReceipt(self: *Self, a: std.mem.Allocator, method: state.Method, id: []const u8, request: state.Digest, task_value: state.Task, disposition: state.Disposition, message_id: ?state.Digest, question: ?state.Digest, reconciliation_id: ?state.Digest) !Admission {
            var identity: state.Digest = undefined;
            try self.io.randomSecure(&identity);
            const saved: state.Receipt = .{ .id = identity, .client_operation_id = try name(id), .method = method, .request_digest = request, .task = task_value.id, .revision = task_value.revision, .disposition = disposition, .message = message_id, .question = question, .reconciliation = reconciliation_id };
            const bytes = try contracts.encodeOwned(state.Receipt, a, saved);
            defer a.free(bytes);
            const key = try self.operationKey(a, id);
            try self.store().putReceipt(&key, request, bytes);
            return .{ .receipt = saved, .replayed = false };
        }
        fn event(self: *Self, value: *state.Task, kind: state.EventType, bytes: []const u8) !void {
            value.event_high = try std.math.add(u64, value.event_high, 1);
            try self.store().putEvent(.{ .task = value.id, .seq = value.event_high, .revision = value.revision, .kind = kind, .data = .{ .bytes = bytes } });
        }
        fn messageEvent(self: *Self, a: std.mem.Allocator, value: *state.Task, kind: state.EventType, item: state.Message) !void {
            const body = try state.messageData(a, item, item.disposition);
            const bytes = try json.canonical(a, body);
            defer a.free(bytes);
            try self.event(value, kind, bytes);
        }
        const Ownership = enum { preserve, acquire };

        fn persist(self: *Self, a: std.mem.Allocator, value: state.Task, previous: u64, transition: []const u8, ownership: Ownership) !void {
            try self.store().putTask(value, previous);
            // Eligibility is derived from the transaction's complete successor.
            // Reserve before commit: an acknowledged event cannot lose its
            // wake-up to allocation failure, or require each producer to notify.
            const wake = try self.workspaceWaitWakeNeeded(a, value, ownership);
            if (ownership == .acquire) try self.ensureOwnershipCapacity(value.id);
            if (wake) try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try self.namespace.commit(transition);
            if (ownership == .acquire) self.claim(value.id);
            if (wake) self.runnableAppendAssumeCapacity(value.id);
        }
        fn runnableAdd(self: *Self, id: state.TaskId) !void {
            return self.subjectAdd(.{ .task = id });
        }
        fn subjectAdd(self: *Self, subject: workspace.Subject) !void {
            for (self.runnable.items) |item| if (std.meta.eql(item, subject)) return;
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            self.subjectAppendAssumeCapacity(subject);
        }
        fn subjectAddAssumeCapacity(self: *Self, subject: workspace.Subject) void {
            for (self.runnable.items) |item| if (std.meta.eql(item, subject)) return;
            self.subjectAppendAssumeCapacity(subject);
        }
        fn runnableAppendAssumeCapacity(self: *Self, id: state.TaskId) void {
            self.subjectAppendAssumeCapacity(.{ .task = id });
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
        fn ensureOwnershipCapacity(self: *Self, id: ?state.TaskId) !void {
            if (id) |existing| for (self.owned.items) |prior| {
                if (same(&prior, &existing)) return;
            };
            try self.owned.ensureUnusedCapacity(self.allocator, 1);
        }
        fn claim(self: *Self, id: state.TaskId) void {
            for (self.owned.items) |prior| if (same(&prior, &id)) return;
            // Capacity is reserved before durable admission.
            self.owned.appendAssumeCapacity(id);
        }
        fn unclaim(self: *Self, id: state.TaskId) void {
            for (self.owned.items, 0..) |prior, i| if (same(&prior, &id)) {
                _ = self.owned.orderedRemove(i);
                return;
            };
        }
        fn runnableRemove(self: *Self, id: state.TaskId) void {
            self.subjectRemove(.{ .task = id });
        }
        fn subjectRemove(self: *Self, subject: workspace.Subject) void {
            for (self.runnable.items, 0..) |item, i| if (std.meta.eql(item, subject)) {
                _ = self.runnable.orderedRemove(i);
                if (i < self.runnable_cursor) self.runnable_cursor -= 1;
                if (self.runnable_cursor == self.runnable.items.len) self.runnable_cursor = 0;
                return;
            };
        }
        fn compatibleApplication(self: *Self, value: state.Task) !void {
            if (!same(value.application_id.bytes, Types.application_id) or
                !same(&value.image.digest, &storage.digest(self.assets.image))) return error.IncompatibleProfile;
        }
        fn acceptsMessages(self: *Self) bool {
            for (self.handlers.entries) |entry| if (entry.declaration.kind == .inbox) return true;
            return false;
        }
        fn compatible(self: *Self, value: state.Task) !void {
            try self.compatibleApplication(value);
            if (!same(&value.profile.digest, &storage.digest(self.profile.bytes)) or
                !same(&value.runtime_identity, &self.profile.runtime_identity)) return error.IncompatibleProfile;
            if (value.resources.items.len != self.profile.resources.len) return error.IncompatibleProfile;
            for (value.resources.items, self.profile.resources) |reference, bytes| {
                if (reference.bytes != bytes.len or !same(&reference.digest, &storage.digest(bytes))) return error.IncompatibleProfile;
            }
        }
        fn retire(self: *Self, a: std.mem.Allocator) !void {
            _ = a;
            if (self.active) |active| {
                try active.driver.retire();
                try active.driver.destroy();
                self.active = null;
            }
        }
        fn resident(self: *Self, a: std.mem.Allocator, value: state.Task) !*evaluator.Driver {
            try self.compatible(value);
            if (self.active) |active| {
                if (active.work == null and same(&active.task, &value.id) and active.execution_revision == value.execution_revision) return active.driver;
                try self.retire(a);
            }
            const checkpoint = try self.store().object(a, value.checkpoint, null);
            defer a.free(checkpoint);
            const driver = try evaluator.Driver.start(self.allocator, self.program, .{ .state = checkpoint });
            self.active = .{ .task = value.id, .execution_revision = value.execution_revision, .driver = driver };
            return driver;
        }

        fn submitDigest(a: std.mem.Allocator, profile_digest: state.Digest, input: Types.Input) !state.Digest {
            const Request = struct { method: state.Method, application: state.Name, profile_digest: state.Digest, input: Types.Input };
            return operation(Request, a, .{ .method = .submit, .application = try name(Types.application_id), .profile_digest = profile_digest, .input = input });
        }

        pub fn submit(self: *Self, a: std.mem.Allocator, id: []const u8, input: Types.Input) !Admission {
            try self.allowed();
            var profile_digest = storage.digest(self.profile.bytes);
            const key = try self.operationKey(a, id);
            if (try self.store().savedReceipt(a, &key)) |bytes| {
                defer a.free(bytes);
                var saved = try contracts.decodeOwned(state.Receipt, a, bytes);
                defer saved.deinit();
                if (saved.value.method == .submit) {
                    var original = try self.task(a, saved.value.task);
                    defer original.deinit();
                    // The original alias is resolved only on first admission.
                    // Retrying it after a launch configuration change recovers
                    // the original receipt and cannot rebind the existing task.
                    if (same(original.value.profile_id.bytes, self.profile.id)) profile_digest = original.value.profile.digest;
                }
            }
            const request = try submitDigest(a, profile_digest, input);
            if (try self.replay(a, id, request)) |prior| return prior;
            try self.ensureOwnershipCapacity(null);
            // Reserve scheduling capacity before making acceptance durable.
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try self.retire(a);
            var task_id: state.TaskId = undefined;
            try self.io.randomSecure(&task_id);
            const input_bytes = try contracts.encodeOwned(Types.Input, a, input);
            defer a.free(input_bytes);
            const driver = try evaluator.Driver.start(self.allocator, self.program, .{ .initial_args = input_bytes });
            self.active = .{ .task = task_id, .execution_revision = 0, .driver = driver };
            errdefer if (!self.store().fenced) {
                self.retire(a) catch {
                    self.store().fence();
                };
            };
            const publication = try driver.drive(a, .none, 0);
            // Retain the new receipt if durable admission fails after publish.
            errdefer self.store().fence();
            const outcome = publication.outcome;
            defer a.free(outcome);
            const checkpoint = publication.checkpoint;
            const resources = try a.alloc(state.Reference, self.profile.resources.len);
            defer a.free(resources);
            try self.store().begin();
            defer self.store().rollback();
            for (self.profile.resources, resources) |bytes, *reference| reference.* = try self.store().putObject(bytes);
            const value: state.Task = .{
                .id = task_id,
                .application_id = try name(Types.application_id),
                .input_schema_id = try name(Types.input_schema_id),
                .output_schema_id = try name(Types.output_schema_id),
                .failure_schema_id = try name(Types.failure_schema_id),
                .message_schema_id = try name(Types.message_schema_id),
                .principal = try name(self.profile.authority.principal),
                .tenant = try name(self.profile.authority.tenant),
                .profile_id = try name(self.profile.id),
                .profile = try self.store().putObject(self.profile.bytes),
                .resources = .{ .items = resources },
                .image = try self.store().putObject(self.assets.image),
                .runtime_identity = self.profile.runtime_identity,
                .input = try self.store().putObject(input_bytes),
                .checkpoint = try self.store().putObject(checkpoint),
                .outcome = try self.store().putObject(outcome),
                .outcome_kind = .progressed,
                .current_occurrence = null,
                .revision = 1,
                .execution_revision = 0,
                .schedule = .queued,
                .cancellation = null,
                .cancellation_applied = false,
                .blocker = null,
                .result = null,
                .client_result = null,
                .result_artifact = null,
                .event_floor = 1,
                .event_high = 1,
                .next_message = 1,
                .messages = .{ .items = &.{} },
                .inference_attempts = 0,
                .inference_request_bytes = 0,
                .inference_output_tokens = 0,
                .evidence_bytes = 0,
            };
            // Establish the referenced task before its foreign-keyed events.
            try self.store().putTask(value, null);
            try self.store().putEvent(.{ .task = task_id, .seq = 1, .revision = 1, .kind = .accepted, .data = .{ .bytes = "{}" } });
            const admitted = try self.receipt(a, .submit, id, request, value, .accepted, null, null);
            try self.namespace.commit("task.submit");
            self.runnableAppendAssumeCapacity(task_id);
            self.claim(task_id);
            return admitted;
        }

        pub fn requestCancel(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, reason: []const u8) !Admission {
            if (reason.len > 256 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidParams;
            const request = try cancelDigest(a, task_id, .{ .bytes = reason });
            if (try self.replay(a, id, request)) |prior| return prior;
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            const previous = value.revision;
            if (!value.terminal()) try self.ensureOwnershipCapacity(task_id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            value.revision = try std.math.add(u64, previous, 1);
            if (!value.terminal() and value.cancellation == null) value.cancellation = .{ .bytes = reason };
            try self.store().begin();
            defer self.store().rollback();
            try self.event(&value, .cancellation_requested, "{}");
            const admitted = try self.receipt(a, .cancel, id, request, value, .cancellation_requested, null, null);
            try self.persist(a, value, previous, "task.cancel", .preserve);
            // The receipt now survives retries. If applying its cancellation
            // fails, only restart recovery may resume this owner's work.
            errdefer self.store().fence();
            if (self.work) |*work| if (same(&work.task, &task_id)) {
                work.cancel_requested = true;
            };
            // A new cancellation can also interrupt admitted recovery before
            // it acquires the worker. Prior cancellation intent does not abort
            // a later explicit recovery needed to settle unknown delivery.
            if (!value.terminal() and (self.work == null or self.work.?.subject_work != null or !same(&self.work.?.task, &task_id))) {
                if (value.current_occurrence) |current| {
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", current, task_id);
                    defer pending.deinit();
                    if (pending.value.state == .unknown) {
                        if (try self.pendingRecovery(a, task_id, current, pending.value.state.unknown.id)) |recovery_id| {
                            var recovery = try self.record(state.Reconciliation, a, "reconciliation", recovery_id, task_id);
                            defer recovery.deinit();
                            try self.finishRecovery(a, value, pending.value, recovery.value, null, .unavailable);
                            self.claim(task_id);
                            return admitted;
                        }
                    }
                }
            }
            if (!value.terminal()) {
                if (self.work == null or self.work.?.subject_work != null or !same(&self.work.?.task, &task_id)) try self.runnableAdd(task_id);
                self.claim(task_id);
            }
            return admitted;
        }

        pub fn resumeTask(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, expected: u64) !Admission {
            const Request = struct { method: state.Method, task: state.TaskId, revision: u64 };
            const request = try operation(Request, a, .{ .method = .@"resume", .task = task_id, .revision = expected });
            if (try self.replay(a, id, request)) |prior| return prior;
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            try self.compatible(value);
            if (value.revision != expected) return error.StaleRevision;
            if (value.terminal()) return error.TerminalTask;
            try self.ensureOwnershipCapacity(task_id);
            var rearmed: ?occurrence.Occurrence = null;
            if (value.current_occurrence) |current| {
                var saved = try self.record(occurrence.Occurrence, a, "occurrence", current, task_id);
                defer saved.deinit();
                if (saved.value.state == .unknown or saved.value.state == .dispatching) return error.UnsettledOccurrence;
                if (saved.value.state == .not_sent) rearmed = try occurrence.rearm(saved.value, .{ .id = current, .task = task_id, .request = saved.value.request });
            }
            const children = try self.workspaceIds(a, task_id);
            defer a.free(children);
            var eligible: std.ArrayList(workspace.Subject) = .empty;
            defer eligible.deinit(a);
            for (children) |child_id| {
                var child = try self.workspaceWork(a, task_id, child_id);
                defer child.deinit();
                if (try self.workspaceRunnable(a, value, child.value)) try eligible.append(a, .{ .task = task_id, .work = child_id });
            }
            try self.runnable.ensureUnusedCapacity(self.allocator, eligible.items.len + 1);
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .queued;
            value.blocker = null;
            try self.store().begin();
            defer self.store().rollback();
            if (rearmed) |pending| try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, task_id, pending);
            try self.event(&value, .resumed, "{}");
            const admitted = try self.receipt(a, .@"resume", id, request, value, .resumed, null, null);
            try self.persist(a, value, expected, "task.resume", .preserve);
            self.subjectAddAssumeCapacity(.{ .task = task_id });
            self.claim(task_id);
            for (eligible.items) |child| self.subjectAddAssumeCapacity(child);
            return admitted;
        }

        /// Public recovery hints contain original IDs and compiled mechanisms,
        /// never prepared bytes or an authority to provide replacement replies.
        pub fn recoveryAvailability(self: *Self, a: std.mem.Allocator, task_id: state.TaskId) !?RecoveryAvailability {
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            const value = decoded.value;
            const id = value.current_occurrence orelse return null;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
            defer pending.deinit();
            if (pending.value.state != .unknown) return null;
            var result: RecoveryAvailability = .{ .occurrence = id, .attempt = pending.value.state.unknown.id, .mechanisms = &.{} };
            self.compatible(value) catch |err| return if (err == error.IncompatibleProfile) result else err;
            const bytes = try self.store().object(a, pending.value.request_object, null);
            defer a.free(bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, bytes);
            defer request.deinit();
            const entry = self.handlers.resolve(request.value, self.application.image_identity) catch |err| switch (err) {
                error.MissingCapability, error.CapabilitySchemaMismatch, error.Denied => return result,
            };
            if (entry.declaration.recovery) |adapter| {
                const can_lookup = adapter.lookup != null and blk: {
                    _ = self.handlers.admit(request.value, self.profile.authority, self.application.image_identity, registry.resourceIdentity(self.application.image_identity, value.profile.digest, value.resources.items)) catch break :blk false;
                    break :blk true;
                };
                result.mechanisms = if (adapter.rederive != null) (if (can_lookup) &.{ .rederive, .lookup } else &.{.rederive}) else if (can_lookup) &.{.lookup} else &.{};
            }
            return result;
        }

        pub fn reconciliation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest) !contracts.Decoded(state.Reconciliation) {
            var authorized = try self.task(a, task_id);
            defer authorized.deinit();
            return self.record(state.Reconciliation, a, "reconciliation", id, task_id);
        }

        /// Admit explicit recovery. Receipt lookup precedes revision/state
        /// checks; pure computation completes locally, while asynchronous
        /// lookup gets a sealed pending record before the worker may start.
        pub fn reconcile(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, expected: u64, occurrence_id: state.Digest, attempt_id: state.Digest, recovery: state.RecoveryRequest) !Admission {
            const request_digest = try reconcileDigest(a, task_id, expected, occurrence_id, attempt_id, recovery);
            if (try self.replay(a, id, request_digest)) |prior| return prior;
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            try self.compatible(value);
            if (value.revision != expected) return error.StaleRevision;
            if (value.terminal() or value.current_occurrence == null or !same(&value.current_occurrence.?, &occurrence_id)) return error.StaleOccurrence;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", occurrence_id, task_id);
            defer pending.deinit();
            if (pending.value.state != .unknown) return error.UnsettledOccurrence;
            if (!same(&pending.value.state.unknown.id, &attempt_id)) return error.StaleOccurrence;
            if (try self.pendingRecovery(a, task_id, occurrence_id, attempt_id) != null) return error.UnsettledOccurrence;
            var attempt = try self.record(state.Attempt, a, "attempt", attempt_id, task_id);
            defer attempt.deinit();
            const request_bytes = try self.store().object(a, attempt.value.request, null);
            defer a.free(request_bytes);
            var original_request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer original_request.deinit();
            const entry = try self.handlers.resolve(original_request.value, self.application.image_identity);
            const lookup = recovery == .lookup and if (entry.declaration.recovery) |adapter| adapter.lookup != null else false;
            if (lookup) {
                _ = try self.handlers.admit(original_request.value, self.profile.authority, self.application.image_identity, registry.resourceIdentity(self.application.image_identity, value.profile.digest, value.resources.items));
                if (entry.declaration.capture) |adapter| {
                    const prepared = try self.store().object(a, attempt.value.prepared orelse return error.CorruptState, null);
                    defer a.free(prepared);
                    const expected_prepared = try self.prepareProjection(a, value, adapter, original_request.value.binding.payload);
                    defer a.free(expected_prepared);
                    if (!same(prepared, expected_prepared)) return error.CorruptState;
                }
            }
            const rederive = recovery == .rederive and if (entry.declaration.recovery) |adapter| adapter.rederive != null else false;
            if (rederive) try self.validateRederivation(a, task_id, occurrence_id, attempt_id);
            const asynchronous = lookup or rederive;
            if (asynchronous) {
                try self.ensureOwnershipCapacity(task_id);
                try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            }
            var reconciliation_id: state.Digest = undefined;
            try self.io.randomSecure(&reconciliation_id);
            value.revision = try std.math.add(u64, expected, 1);
            try self.store().begin();
            defer self.store().rollback();
            var result: state.Reconciliation = .{
                .id = reconciliation_id,
                .task = task_id,
                .client_operation_id = try name(id),
                .request_digest = request_digest,
                .admission_revision = value.revision,
                .occurrence = occurrence_id,
                .attempt = attempt_id,
                .original_occurrence = try self.snapshotRecord(occurrence.Occurrence, a, "occurrence", occurrence_id, task_id),
                .original_attempt = try self.snapshotRecord(state.Attempt, a, "attempt", attempt_id, task_id),
                .request = attempt.value.request,
                .prepared = attempt.value.prepared,
                .profile = value.profile,
                .resources = value.resources,
                .capability = attempt.value.capability,
                .mechanism = try name(if (entry.declaration.recovery) |adapter| adapter.identity else "unavailable"),
                .mechanism_version = if (entry.declaration.recovery) |adapter| adapter.version else 0,
                .provenance = .none,
                .outcome = .{ .unresolved = .unsupported },
                .selection = recovery,
                .owner_epoch = if (asynchronous) self.owner_epoch else null,
            };
            if (asynchronous) {
                result.outcome = .pending;
                value.schedule = .queued;
                value.blocker = null;
                if (try self.store().recordBytes(a, "capture", attempt_id, task_id)) |prior| {
                    defer a.free(prior);
                    result.original_capture = try self.store().putObject(prior);
                }
            }
            try self.store().createRecord(state.Reconciliation, "reconciliation", reconciliation_id, task_id, result);
            const event_data = try std.fmt.allocPrint(a, "{{\"reconciliation_id\":\"{s}\"}}", .{std.fmt.bytesToHex(reconciliation_id, .lower)});
            defer a.free(event_data);
            try self.event(&value, .reconciled, event_data);
            const admitted = try self.recoveryReceipt(a, .reconcile, id, request_digest, value, .reconciled, null, null, reconciliation_id);
            try self.persist(a, value, expected, "task.reconcile", .preserve);
            if (asynchronous) {
                try self.runnableAdd(task_id);
                self.claim(task_id);
            }
            return admitted;
        }

        fn pendingRecovery(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, occurrence_id: state.Digest, attempt_id: state.Digest) !?state.Digest {
            var rows = try self.store().database.prepare("SELECT id FROM records WHERE kind='reconciliation' AND task=?", &.{.{ .blob = &task_id }});
            defer rows.deinit();
            var result: ?state.Digest = null;
            while (try rows.step() == .row) {
                const bytes = try rows.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                var item = try self.record(state.Reconciliation, a, "reconciliation", bytes[0..32].*, task_id);
                defer item.deinit();
                if (item.value.outcome != .pending) continue;
                if (result != null or !same(&item.value.occurrence, &occurrence_id) or !same(&item.value.attempt, &attempt_id)) return error.CorruptState;
                result = item.value.id;
            }
            return result;
        }

        fn recoveryWork(self: *Self, a: std.mem.Allocator, value: state.Task, pending: occurrence.Occurrence, id: state.Digest) !Step {
            if (self.work != null) return .idle;
            var saved = try self.record(state.Reconciliation, a, "reconciliation", id, value.id);
            defer saved.deinit();
            const item = saved.value;
            if (item.outcome != .pending or item.owner_epoch == null or !same(&item.owner_epoch.?, &self.owner_epoch)) return error.CorruptState;
            const request = try self.store().object(self.allocator, item.request, null);
            errdefer self.allocator.free(request);
            var decoded = try data.invocation.decode(data.invocation.Request, a, request);
            defer decoded.deinit();
            const entry = if (item.selection == .rederive) try self.handlers.resolve(decoded.value, self.application.image_identity) else self.handlers.admit(decoded.value, self.profile.authority, self.application.image_identity, registry.resourceIdentity(self.application.image_identity, value.profile.digest, value.resources.items)) catch {
                try self.finishRecovery(a, value, pending, item, null, .unavailable);
                self.allocator.free(request);
                return .progressed;
            };
            const prepared = if (item.prepared) |ref| try self.store().object(self.allocator, ref, null) else null;
            errdefer if (prepared) |bytes| self.allocator.free(bytes);
            const profile = try self.store().object(self.allocator, value.profile, null);
            errdefer self.allocator.free(profile);
            const body = try contracts.encodeOwned(state.Reconciliation, self.allocator, item);
            self.work = .{ .owner_epoch = self.owner_epoch, .task = value.id, .occurrence = pending.id, .attempt = item.attempt, .request = request, .prepared = prepared, .profile = profile, .entry = entry, .cleanup = false, .recovery = .{ .id = id, .body = body } };
            return .{ .work = self.work.? };
        }

        fn recoveryFinding(self: *Self, a: std.mem.Allocator, initial: state.Task, original: state.Reconciliation, identity: state.Digest, completion: RecoveryCompletion) !Recovered {
            const request_bytes = try self.store().object(a, original.request, null);
            defer a.free(request_bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            if (!same(&request.value.request_identity, &identity)) return error.InvalidRecovery;
            const entry = try self.handlers.resolve(request.value, self.application.image_identity);
            if (completion == .rederived) {
                if (original.selection != .rederive or entry.declaration.recovery == null or entry.declaration.recovery.?.rederive == null) return error.InvalidRecovery;
                return switch (completion.rederived) {
                    .unsupported => .unsupported,
                    .unavailable => .unavailable,
                    .inconclusive => .inconclusive,
                    .rejected => .rejected,
                    .result => |bytes| blk: {
                        if (entry.declaration.capture != null) break :blk .{ .capture = bytes };
                        var schema = try data.schema.decode(a, entry.resume_schema);
                        defer schema.deinit();
                        data.schema.validateValue(a, schema.descriptor, bytes) catch |err| switch (err) {
                            error.OutOfMemory, error.Capacity => return err,
                            else => return .rejected,
                        };
                        break :blk .{ .reply = bytes };
                    },
                };
            }
            if (original.selection != .lookup) return error.InvalidRecovery;
            const finding = try self.store().project(registry.RecoveryFinding, a, self.handlers, self.projectionBinding(initial), struct {
                handlers: registry.Registry,
                input: registry.RecoveryInput,
                evidence: []const u8,
                pub fn run(this: @This(), ctx: registry.ProjectionContext) !registry.RecoveryFinding {
                    return this.handlers.verifyRecovery(ctx, this.input, this.evidence);
                }
            }{ .handlers = self.handlers, .input = registry.RecoveryInput.fromReconciliation(original, identity, entry.declaration.inference), .evidence = completion.evidence });
            return switch (finding) {
                .capture => |bytes| .{ .capture = bytes },
                .not_sent => .not_sent,
                .inconclusive => .inconclusive,
                .unavailable => .unavailable,
                .rejected => .rejected,
            };
        }

        fn finishRecovery(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, original: state.Reconciliation, completion: ?RecoveryCompletion, failure: @FieldType(@FieldType(state.Reconciliation, "outcome"), "unresolved")) !void {
            if (original.outcome != .pending or pending.state != .unknown or !same(&pending.state.unknown.id, &original.attempt) or initial.current_occurrence == null or !same(&initial.current_occurrence.?, &original.occurrence)) return error.StaleOccurrence;
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const verified: ?Recovered = if (completion) |result| try self.recoveryFinding(arena.allocator(), initial, original, pending.request, result) else null;
            const advancing = if (verified) |finding| finding == .capture or finding == .reply or finding == .not_sent else false;
            if (advancing) try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .parked;
            value.blocker = .unavailable_environment;
            try self.store().begin();
            defer self.store().rollback();
            var result = original;
            result.previous = try self.snapshotRecord(state.Reconciliation, a, "reconciliation", original.id, value.id);
            result.evidence = if (completion != null and completion.? == .evidence) try self.store().putObject(completion.?.evidence) else null;
            result.outcome = .{ .unresolved = failure };
            if (verified) |finding| switch (finding) {
                .unsupported => result.outcome = .{ .unresolved = .unsupported },
                .inconclusive => result.outcome = .{ .unresolved = .inconclusive },
                .unavailable => result.outcome = .{ .unresolved = .unavailable },
                .rejected => result.outcome = .{ .unresolved = .rejected },
                .capture => |raw| {
                    const capture_value: state.Capture = .{ .task = value.id, .occurrence = pending.id, .attempt = original.attempt, .request = original.prepared orelse return error.CorruptState, .response = try self.store().putObject(raw), .disposition = .complete, .reconciliation = original.id };
                    if (try self.store().recordBytes(a, "capture", original.attempt, value.id)) |prior| {
                        defer a.free(prior);
                        if (original.original_capture == null) return error.CorruptState;
                        try self.store().putRecord(state.Capture, "capture", original.attempt, value.id, capture_value);
                    } else try self.store().createRecord(state.Capture, "capture", original.attempt, value.id, capture_value);
                    result.provenance = if (original.selection == .rederive) .rederived else .authentic;
                    result.outcome = .{ .capture_admitted = capture_value.response.? };
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, try occurrence.recoveredCapture(pending, .{ .id = pending.id, .task = value.id, .request = pending.request }, original.attempt));
                    value.schedule = .queued;
                    value.blocker = null;
                },
                .reply => |bytes| {
                    const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = bytes });
                    defer a.free(bound);
                    const ref = try self.store().putObject(bound);
                    result.provenance = .rederived;
                    result.outcome = .{ .reply_settled = ref };
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, try occurrence.acquired(pending, .{ .id = pending.id, .task = value.id, .request = pending.request }, original.attempt, ref.digest));
                    value.schedule = .queued;
                    value.blocker = null;
                },
                .not_sent => {
                    result.provenance = .authoritative;
                    result.outcome = .{ .not_sent = result.evidence.? };
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, try occurrence.recoveredNotSent(pending, .{ .id = pending.id, .task = value.id, .request = pending.request }, original.attempt));
                    if (value.cancellation != null) {
                        value.schedule = .queued;
                        value.blocker = null;
                    }
                },
            };
            try self.store().putRecord(state.Reconciliation, "reconciliation", result.id, value.id, result);
            try self.persist(a, value, initial.revision, "recovery.complete", .preserve);
            if (value.schedule == .queued) try self.runnableAdd(value.id) else self.runnableRemove(value.id);
        }

        fn snapshotRecord(self: *Self, comptime T: type, a: std.mem.Allocator, comptime kind: []const u8, id: state.Digest, task_id: state.TaskId) !state.Reference {
            if (T != storage.Record(kind)) @compileError("native record type/kind mismatch");
            const bytes = (try self.store().recordBytes(a, kind, id, task_id)) orelse return error.CorruptState;
            defer a.free(bytes);
            return self.store().putObject(bytes);
        }

        /// Check the original immutable inputs before sealing recovery admission.
        /// No computation or borrowed projection view escapes this call.
        fn validateRederivation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, occurrence_id: state.Digest, attempt_id: state.Digest) !void {
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            const value = decoded.value;
            try self.compatible(value);
            if (value.terminal() or value.current_occurrence == null or !same(&value.current_occurrence.?, &occurrence_id)) return error.StaleOccurrence;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", occurrence_id, task_id);
            defer pending.deinit();
            if (pending.value.state != .unknown) return error.UnsettledOccurrence;
            if (!same(&pending.value.state.unknown.id, &attempt_id)) return error.StaleOccurrence;
            var attempt = try self.record(state.Attempt, a, "attempt", attempt_id, task_id);
            defer attempt.deinit();
            const original = attempt.value;
            if (!same(&original.id, &attempt_id) or !same(&original.task, &task_id) or !same(&original.occurrence, &occurrence_id) or
                !std.meta.eql(original.profile, value.profile) or !std.meta.eql(original.request, pending.value.request_object)) return error.CorruptState;
            const input: registry.RecoveryInput = .{ .task = task_id, .occurrence = occurrence_id, .attempt = attempt_id, .request_identity = pending.value.request, .request = original.request, .prepared = original.prepared, .profile = original.profile, .resources = value.resources.items, .capability = original.capability.bytes, .inference = original.inference };
            return self.store().project(void, a, self.handlers, self.projectionBinding(value), struct {
                handlers: registry.Registry,
                input: registry.RecoveryInput,
                pub fn run(this: @This(), ctx: registry.ProjectionContext) !void {
                    return this.handlers.validateRederivation(ctx, this.input);
                }
            }{ .handlers = self.handlers, .input = input });
        }

        fn messageDigest(a: std.mem.Allocator, task_id: state.TaskId, input: Types.Message) !state.Digest {
            const Request = struct { method: state.Method, task: state.TaskId, schema: state.Name, value: Types.Message };
            return operation(Request, a, .{ .method = .message, .task = task_id, .schema = try name(Types.message_schema_id), .value = input });
        }

        pub fn message(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, input: Types.Message) !Admission {
            const request = try messageDigest(a, task_id, input);
            if (try self.replay(a, id, request)) |prior| return prior;
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            if (value.terminal() or value.cancellation != null) return error.TerminalTask;
            // Input belongs to the saved application's contract, independently
            // of which launch profile will eventually resume its execution.
            try self.compatibleApplication(value);
            if (!same(value.message_schema_id.bytes, Types.message_schema_id)) return error.IncompatibleProfile;
            if (!self.acceptsMessages()) return error.UnsupportedCapability;
            const bytes = try contracts.encodeOwned(Types.Message, a, input);
            defer a.free(bytes);
            var identity: state.Digest = undefined;
            try self.io.randomSecure(&identity);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const ordinal = value.next_message;
            value.next_message = try std.math.add(u64, ordinal, 1);
            const queue = try a.alloc(state.Digest, value.messages.items.len + 1);
            defer a.free(queue);
            @memcpy(queue[0..value.messages.items.len], value.messages.items);
            queue[queue.len - 1] = identity;
            value.messages = .{ .items = queue };
            try self.store().begin();
            defer self.store().rollback();
            const saved: state.Message = .{ .id = identity, .task = task_id, .ordinal = ordinal, .schema_id = try name(Types.message_schema_id), .value = try self.store().putObject(bytes), .disposition = .queued, .occurrence = null };
            try self.store().createRecord(state.Message, "message", identity, task_id, saved);
            try self.messageEvent(a, &value, .message_queued, saved);
            const admitted = try self.receipt(a, .message, id, request, value, .queued, identity, null);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try self.persist(a, value, previous, "task.message", .preserve);
            return admitted;
        }

        pub fn respond(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, question_id: state.Digest, revision: u64, request_digest: state.Digest, schema_id: []const u8, answer_json: json.Value) !Admission {
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            // Client-selected identities may be absent without corrupting the
            // store. Missing references from durable state still use record().
            const question_bytes = (try self.store().recordBytes(a, "question", question_id, task_id)) orelse {
                // Missing durable current-question references remain storage
                // corruption even when discovered during a client lookup.
                var current = try self.pendingQuestion(a, task_id);
                if (current) |*question| question.deinit();
                return error.StaleInteraction;
            };
            defer a.free(question_bytes);
            var question_decoded = try contracts.decodeOwned(state.Question, a, question_bytes);
            defer question_decoded.deinit();
            var question = question_decoded.value;
            if (question.revision != revision or !same(&question.request_digest, &request_digest) or !same(question.answer_schema_id.bytes, schema_id)) return error.StaleInteraction;
            var answer_bytes: ?[]u8 = null;
            defer if (answer_bytes) |bytes| a.free(bytes);
            for (self.handlers.entries) |entry| {
                if (entry.declaration.kind == .question and same(entry.declaration.answer_schema_id.?, schema_id) and same(&storage.digest(entry.resume_schema), &question.answer_schema_digest)) {
                    answer_bytes = try entry.declaration.answer.?(a, answer_json);
                    break;
                }
            }
            const answer = answer_bytes orelse return error.IncompatibleProfile;
            const request = try answerDigest(a, task_id, question_id, revision, request_digest, schema_id, answer);
            if (try self.replay(a, id, request)) |prior| return prior;
            if (question.answer) |saved_answer| {
                if (!same(&saved_answer.digest, &storage.digest(answer))) return error.AnswerConflict;
                const original = question.receipt orelse return error.CorruptState;
                const bytes = try contracts.encodeOwned(state.Receipt, a, original);
                defer a.free(bytes);
                const key = try self.operationKey(a, id);
                try self.store().begin();
                defer self.store().rollback();
                try self.store().putReceipt(&key, request, bytes);
                try self.namespace.commit("task.respond.replay");
                var retained = original;
                retained.client_operation_id = .{ .bytes = try a.dupe(u8, original.client_operation_id.bytes) };
                return .{ .receipt = retained, .replayed = true };
            }
            if (question.retired or value.terminal() or (value.cancellation != null and !value.cancellation_applied) or value.current_occurrence == null or !same(&value.current_occurrence.?, &question.occurrence)) return error.StaleInteraction;
            const original_request = try self.store().object(a, question.request, null);
            defer a.free(original_request);
            var admitted_request = try data.invocation.decode(data.invocation.Request, a, original_request);
            defer admitted_request.deinit();
            _ = try self.handlers.admit(admitted_request.value, self.profile.authority, self.application.image_identity, registry.resourceIdentity(self.application.image_identity, value.profile.digest, value.resources.items));
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", question.occurrence, task_id);
            defer pending.deinit();
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = question.request_digest, .value = answer });
            defer a.free(bound);
            const binding: occurrence.Binding = .{ .id = pending.value.id, .task = task_id, .request = pending.value.request };
            const acquired = try occurrence.answered(pending.value, binding, question_id, question.pending_digest, storage.digest(answer), storage.digest(bound), false);
            try self.ensureOwnershipCapacity(task_id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            value.schedule = .queued;
            try self.store().begin();
            defer self.store().rollback();
            question.answer = try self.store().putObject(answer);
            _ = try self.store().putObject(bound);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", acquired.id, task_id, acquired);
            try self.event(&value, .input_accepted, "{}");
            const admitted = try self.receipt(a, .respond, id, request, value, .answer_acquired, null, question_id);
            question.receipt = admitted.receipt;
            try self.store().putRecord(state.Question, "question", question_id, task_id, question);
            try self.persist(a, value, previous, "task.respond", .preserve);
            try self.runnableAdd(task_id);
            self.claim(task_id);
            return admitted;
        }

        fn blocked(self: *Self, a: std.mem.Allocator, initial: state.Task, blocker: state.Blocker) !Step {
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.blocker = blocker;
            value.schedule = .parked;
            try self.store().begin();
            defer self.store().rollback();
            try self.event(&value, .blocked, "{}");
            try self.persist(a, value, initial.revision, "task.blocked", .preserve);
            self.runnableRemove(value.id);
            try self.retire(a);
            return .waiting;
        }

        /// At most one bounded Kosmos quantum or one durable environmental
        /// transition. The caller services its control channel between calls.
        pub fn pump(self: *Self, a: std.mem.Allocator) !Step {
            try self.allowed();
            // Scan one round, without charging or preparing blocked leaves.
            // Each actual transition yields back to the host control channel.
            const count = self.runnable.items.len;
            for (0..count) |_| {
                const id = self.runnable.items[self.runnable_cursor];
                self.runnable_cursor += 1;
                if (self.runnable_cursor == self.runnable.items.len) self.runnable_cursor = 0;
                const step = if (id.work) |work_id| try self.pumpWorkspace(a, id.task, work_id) else try self.pumpTask(a, id.task);
                if (step != .idle) return step;
            }
            return .idle;
        }

        fn pumpTask(self: *Self, a: std.mem.Allocator, id: state.TaskId) !Step {
            var decoded = try self.task(a, id);
            defer decoded.deinit();
            const value = decoded.value;
            if (value.cancellation != null and try self.cancelWorkspaceOne(a, value)) return .progressed;
            if (value.terminal()) {
                self.runnableRemove(id);
                if (try self.taskCleanupComplete(a, value)) self.unclaim(id);
                return .progressed;
            }
            self.compatible(value) catch return self.blocked(a, value, .incompatible_profile);
            var current: ?contracts.Decoded(occurrence.Occurrence) = null;
            defer if (current) |*item| item.deinit();
            if (value.current_occurrence) |identity| current = try self.record(occurrence.Occurrence, a, "occurrence", identity, id);
            var control: data.invocation.Control = .none;
            var consumed: ?occurrence.Occurrence = null;
            var reply: ?[]u8 = null;
            defer if (reply) |bytes| a.free(bytes);
            if (current) |item| {
                const pending = item.value;
                const binding: occurrence.Binding = .{ .id = pending.id, .task = id, .request = pending.request };
                switch (pending.state) {
                    .captured => return self.interpretCapture(a, value, pending),
                    .unknown => |attempt| {
                        if (self.work) |work| if (work.recovery != null and same(&work.task, &id) and same(&work.occurrence, &pending.id) and same(&work.attempt, &attempt.id)) return .idle;
                        if (try self.pendingRecovery(a, value.id, pending.id, attempt.id)) |recovery_id| return self.recoveryWork(a, value, pending, recovery_id);
                        return self.blocked(a, value, .unavailable_environment);
                    },
                    .dispatching => |attempt| {
                        // This worker still owns the attempt even when another
                        // task now owns the sole physical Kosmos resident.
                        if (self.work) |work| if (same(&work.task, &id) and
                            same(&work.occurrence, &pending.id) and same(&work.attempt, &attempt.id)) return .idle;
                        return self.blocked(a, value, .unavailable_environment);
                    },
                    .settled_reply => |acquired| {
                        reply = try self.store().acquiredObject(a, acquired.reply, null);
                        consumed = try occurrence.consumed(pending, binding, .{ .reply = acquired.reply }, value.cancellation != null);
                        control = .{ .reply = reply.? };
                    },
                    .ready, .awaiting, .not_sent => {
                        if (value.cancellation != null and !value.cancellation_applied) {
                            consumed = try occurrence.consumed(pending, binding, .cancel, true);
                            control = .{ .cancel = .{ .text = value.cancellation.?.bytes } };
                        } else if (pending.state == .awaiting or pending.state == .not_sent) {
                            self.runnableRemove(id);
                            try self.retire(a);
                            return .waiting;
                        } else return self.dispatch(a, value, pending);
                    },
                    .admitted => return error.CorruptState,
                }
            } else if (value.cancellation != null and !value.cancellation_applied) {
                control = .{ .cancel = .{ .text = value.cancellation.?.bytes } };
            } else if (value.outcome_kind == .yielded) {
                control = .resume_yield;
            }
            return self.advance(a, value, control, consumed);
        }

        fn advance(self: *Self, a: std.mem.Allocator, initial: state.Task, control: data.invocation.Control, consumed: ?occurrence.Occurrence) !Step {
            const driver = try self.resident(a, initial);
            const quantum: u64 = if (control == .reply and initial.cancellation != null and !initial.cancellation_applied) 0 else 256;
            const publication = try driver.drive(a, control, quantum);
            const encoded = publication.outcome;
            defer a.free(encoded);
            // Kosmos may now be ahead of storage. Any failure below fences all
            // further effects; restart uses the old checkpoint and saved reply.
            errdefer self.store().fence();
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, encoded);
            defer outcome.deinit();
            if (outcome.value == .needs_capacity) return error.Capacity;
            const checkpoint = publication.checkpoint;
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.execution_revision = try std.math.add(u64, value.execution_revision, 1);
            value.current_occurrence = null;
            value.schedule = .active;
            value.blocker = null;
            if (control == .cancel) value.cancellation_applied = true;
            try self.store().begin();
            defer self.store().rollback();
            value.checkpoint = try self.store().putObject(checkpoint);
            value.outcome = try self.store().putObject(encoded);
            if (consumed) |prior| {
                try self.store().putRecord(occurrence.Occurrence, "occurrence", prior.id, value.id, prior);
                const question_id: ?state.Digest = switch (prior.state.admitted) {
                    .reply => |acquired| if (acquired.answer) |answer| answer.question else null,
                    .cancelled => |waiting| if (waiting) |question| question.question else null,
                };
                if (question_id) |id| {
                    var saved = try self.record(state.Question, a, "question", id, value.id);
                    defer saved.deinit();
                    saved.value.retired = true;
                    try self.store().putRecord(state.Question, "question", id, value.id, saved.value);
                }
                if (value.messages.items.len != 0) {
                    const message_id = value.messages.items[0];
                    var saved = try self.record(state.Message, a, "message", message_id, value.id);
                    defer saved.deinit();
                    if (saved.value.disposition == .acquired and saved.value.occurrence != null and same(&saved.value.occurrence.?, &prior.id)) {
                        saved.value.disposition = .consumed;
                        try self.store().putRecord(state.Message, "message", message_id, value.id, saved.value);
                        value.messages.items = value.messages.items[1..];
                        try self.messageEvent(a, &value, .message_consumed, saved.value);
                    }
                }
            }
            switch (outcome.value) {
                .progressed => value.outcome_kind = .progressed,
                .yielded => value.outcome_kind = .yielded,
                .requested => |pending| {
                    var request = try data.invocation.decode(data.invocation.Request, a, pending.request);
                    defer request.deinit();
                    var id: state.Digest = undefined;
                    try self.io.randomSecure(&id);
                    const next: occurrence.Occurrence = .{ .id = id, .task = value.id, .request = request.value.request_identity, .request_object = try self.store().putObject(pending.request) };
                    try self.store().createRecord(occurrence.Occurrence, "occurrence", id, value.id, next);
                    try self.store().createRecord(workspace.ExecutionRoute, "execution_route", id, value.id, .{ .id = id, .task = value.id, .work = null, .image = value.image, .program_identity = request.value.binding.program_identity });
                    value.current_occurrence = id;
                    value.outcome_kind = .requested;
                },
                .completed => |bytes| {
                    var checked = try contracts.decodeOwned(Types.Output, a, bytes);
                    defer checked.deinit();
                    value.outcome_kind = .completed;
                    value.result = try self.store().putObject(bytes);
                    try self.clientResult(Types.Output, a, &value, Types.output_schema_id, checked.value);
                    try self.event(&value, .completed, "{}");
                },
                .failed => |failure| {
                    var checked = try contracts.decodeOwned(Types.Failure, a, failure.value);
                    defer checked.deinit();
                    value.outcome_kind = .failed;
                    value.result = value.outcome;
                    try self.clientResult(Types.Failure, a, &value, Types.failure_schema_id, checked.value);
                    try self.event(&value, .failed, "{}");
                },
                .cancelled => {
                    value.outcome_kind = .cancelled;
                    value.result = value.outcome;
                    try self.event(&value, .cancelled, "{}");
                },
                .needs_capacity => unreachable,
            }
            if (value.terminal()) {
                value.schedule = .parked;
                for (value.messages.items) |id| {
                    var saved = try self.record(state.Message, a, "message", id, value.id);
                    defer saved.deinit();
                    saved.value.disposition = .not_consumed;
                    try self.store().putRecord(state.Message, "message", id, value.id, saved.value);
                    try self.messageEvent(a, &value, .message_not_consumed, saved.value);
                }
                value.messages.items = &.{};
            }
            try self.persist(a, value, initial.revision, "world.advance", .preserve);
            self.active.?.execution_revision = value.execution_revision;
            if (value.terminal()) {
                try driver.close();
                try driver.destroy();
                self.active = null;
                self.runnableRemove(value.id);
                const children = try self.workspaceIds(a, value.id);
                defer a.free(children);
                for (children) |child_id| {
                    var child = try self.workspaceWork(a, value.id, child_id);
                    defer child.deinit();
                    if (child.value.cancellation == null and !child.value.terminal()) {
                        try self.parkWorkspaceOnClose(a, value.id, child_id);
                        self.subjectRemove(.{ .task = value.id, .work = child_id });
                    }
                }
                if (try self.taskCleanupComplete(a, value)) self.unclaim(value.id);
            }
            return .progressed;
        }
        fn clientResult(self: *Self, comptime T: type, a: std.mem.Allocator, value: *state.Task, schema_id: []const u8, result: T) !void {
            const bytes = try json.canonicalBounded(self.allocator, try values.toJson(T, a, result), try self.store().database.blobLimit());
            defer self.allocator.free(bytes);
            value.client_result = try self.store().putObject(bytes);
            if (bytes.len > 60 * 1024) {
                var id: state.Digest = undefined;
                try self.io.randomSecure(&id);
                const artifact: state.Artifact = .{ .id = id, .task = value.id, .value = value.client_result.?, .media_type = .{ .bytes = "application/json" }, .schema_id = try name(schema_id) };
                try self.store().createRecord(state.Artifact, "artifact", id, value.id, artifact);
                value.result_artifact = id;
            }
        }

        fn occurrenceImage(self: *Self, a: std.mem.Allocator, parent: state.Task, pending: occurrence.Occurrence) !state.Digest {
            var route = try self.record(workspace.ExecutionRoute, a, "execution_route", pending.id, parent.id);
            defer route.deinit();
            if (!std.meta.eql(route.value.work, pending.work) or !std.meta.eql(route.value.task, parent.id) or !std.meta.eql(route.value.id, pending.id)) return error.CorruptState;
            if (pending.work) |id| {
                var work = try self.workspaceWork(a, parent.id, id);
                defer work.deinit();
                var program = try self.workspaceProgram(a, parent.id, work.value.program);
                defer program.deinit();
                if (!std.meta.eql(program.value.description.image, route.value.image) or !std.meta.eql(work.value.delegation, route.value.delegation)) return error.CorruptState;
            } else if (!std.meta.eql(parent.image, route.value.image) or !std.meta.eql(route.value.program_identity, self.application.image_identity)) return error.CorruptState;
            return route.value.program_identity;
        }

        const OccurrenceSubject = struct { image: state.Digest, cancelling: bool, cleanup: bool };
        fn occurrenceSubject(self: *Self, a: std.mem.Allocator, parent: state.Task, pending: occurrence.Occurrence) !OccurrenceSubject {
            var route = try self.record(workspace.ExecutionRoute, a, "execution_route", pending.id, parent.id);
            defer route.deinit();
            if (!std.meta.eql(route.value.work, pending.work) or !std.meta.eql(route.value.task, parent.id) or !std.meta.eql(route.value.id, pending.id)) return error.CorruptState;
            if (pending.work) |id| {
                var work = try self.workspaceWork(a, parent.id, id);
                defer work.deinit();
                if (!std.meta.eql(work.value.current_occurrence, pending.id)) return error.StaleOccurrence;
                var program = try self.workspaceProgram(a, parent.id, work.value.program);
                defer program.deinit();
                if (!std.meta.eql(program.value.description.image, route.value.image)) return error.CorruptState;
                return .{ .image = route.value.program_identity, .cancelling = work.value.cancellation != null, .cleanup = work.value.cancellation_applied };
            }
            if (!std.meta.eql(parent.current_occurrence, pending.id) or !std.meta.eql(parent.image, route.value.image) or !std.meta.eql(route.value.program_identity, self.application.image_identity)) return error.CorruptState;
            return .{ .image = route.value.program_identity, .cancelling = parent.cancellation != null, .cleanup = parent.cancellation_applied };
        }

        /// Inside the same transaction as its occurrence. Child accounting is
        /// visible in the task journal without changing the root continuation.
        fn effectSchedule(self: *Self, a: std.mem.Allocator, parent: *state.Task, pending: occurrence.Occurrence, schedule: state.Schedule, blocker: ?state.Blocker, preserve_park: bool) !void {
            const id = pending.work orelse return;
            var work = try self.retainedWorkspaceWork(a, parent.id, id);
            defer work.deinit();
            if (!std.meta.eql(work.value.current_occurrence, pending.id)) return error.StaleOccurrence;
            if (!preserve_park or work.value.schedule != .parked) work.value.schedule = schedule;
            work.value.blocker = blocker;
            work.value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try self.store().putRecord(workspace.Work, "workspace_work", id, parent.id, work.value);
            const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{std.fmt.bytesToHex(id, .lower)});
            defer a.free(event_data);
            try self.event(parent, .workspace_progress, event_data);
        }
        fn wakeOccurrence(self: *Self, a: std.mem.Allocator, parent: state.Task, pending: occurrence.Occurrence) !void {
            if (pending.work) |id| {
                var work = try self.workspaceWork(a, parent.id, id);
                defer work.deinit();
                if (work.value.schedule != .parked) try self.subjectAdd(.{ .task = parent.id, .work = id });
            } else try self.runnableAdd(parent.id);
        }
        fn blockedOccurrence(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, reason: state.Blocker) !Step {
            if (pending.work == null) return self.blocked(a, initial, reason);
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try self.store().begin();
            defer self.store().rollback();
            try self.effectSchedule(a, &parent, pending, .parked, reason, false);
            try self.persist(a, parent, initial.revision, "effect.blocked", .preserve);
            self.subjectRemove(.{ .task = parent.id, .work = pending.work });
            return .waiting;
        }

        fn dispatch(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence) !Step {
            const request_bytes = try self.store().object(a, pending.request_object, null);
            defer a.free(request_bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            const subject = try self.occurrenceSubject(a, initial, pending);
            if (!same(&request.value.request_identity, &pending.request)) return error.CorruptState;
            const entry = self.handlers.admit(request.value, self.profile.authority, subject.image, registry.resourceIdentity(self.application.image_identity, initial.profile.digest, initial.resources.items)) catch |err|
                return self.blockedOccurrence(a, initial, pending, if (err == error.Denied) .denied else .missing_capability);
            if (pending.work != null and entry.declaration.kind != .leaf) return self.blockedOccurrence(a, initial, pending, .missing_capability);
            if (entry.declaration.kind == .leaf and self.work != null) return .idle;
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const binding: occurrence.Binding = .{ .id = pending.id, .task = pending.task, .work = pending.work, .request = pending.request };
            const dispatched = try occurrence.dispatch(pending, binding, attempt, subject.cancelling, subject.cleanup);
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (pending.work == null) value.schedule = .active;
            const task_name = std.fmt.bytesToHex(value.id, .lower);
            const ctx: registry.Context = .{ .allocator = a, .io = self.io, .authority = &self.profile.authority, .task_id = &task_name, .profile = self.profile.bytes, .environment = self.profile.environment };
            switch (entry.declaration.kind) {
                .workspace => return self.dispatchWorkspace(a, initial, pending, entry, request.value.binding.payload),
                .question => {
                    const prompt = try json.canonical(a, try entry.declaration.present.?(ctx, request.value.binding.payload));
                    defer a.free(prompt);
                    var question_id: state.Digest = undefined;
                    try self.io.randomSecure(&question_id);
                    const waiting = try occurrence.awaiting(pending, binding, .{ .attempt = attempt, .question = question_id, .pending_digest = request.value.binding.pending_state_digest }, initial.cancellation != null and !initial.cancellation_applied);
                    try self.store().begin();
                    defer self.store().rollback();
                    const question: state.Question = .{ .id = question_id, .task = value.id, .occurrence = pending.id, .revision = 1, .request_digest = pending.request, .pending_digest = request.value.binding.pending_state_digest, .answer_schema_id = try name(entry.declaration.answer_schema_id.?), .answer_schema_digest = storage.digest(entry.resume_schema), .request = try self.store().putObject(request_bytes), .prompt = try self.store().putObject(prompt), .answer = null, .receipt = null, .retired = false };
                    try self.store().createRecord(state.Question, "question", question_id, value.id, question);
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, waiting);
                    const event_data = try state.questionData(a, question, prompt);
                    const event_bytes = try json.canonical(a, event_data);
                    defer a.free(event_bytes);
                    try self.event(&value, .input_required, event_bytes);
                    try self.persist(a, value, initial.revision, "question.awaiting", .preserve);
                    self.runnableRemove(value.id);
                    try self.retire(a);
                    return .waiting;
                },
                .inbox => {
                    var message_decoded: ?contracts.Decoded(state.Message) = null;
                    defer if (message_decoded) |*item| item.deinit();
                    var message_value: ?contracts.Decoded(Types.Message) = null;
                    defer if (message_value) |*item| item.deinit();
                    var input: contracts.InboxReply(Types.Message) = .empty;
                    var message_name: [64]u8 = undefined;
                    if (value.messages.items.len != 0) {
                        message_decoded = try self.record(state.Message, a, "message", value.messages.items[0], value.id);
                        const saved = &message_decoded.?.value;
                        if (saved.disposition != .queued or saved.occurrence != null) return error.CorruptState;
                        const message_bytes = try self.store().object(a, saved.value, null);
                        defer a.free(message_bytes);
                        message_value = try contracts.decodeOwned(Types.Message, a, message_bytes);
                        message_name = std.fmt.bytesToHex(saved.id, .lower);
                        input = .{ .message = .{ .id = .{ .bytes = &message_name }, .value = message_value.?.value } };
                        saved.disposition = .acquired;
                        saved.occurrence = pending.id;
                    }
                    const payload = try contracts.encodeOwned(contracts.InboxReply(Types.Message), a, input);
                    defer a.free(payload);
                    const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = payload });
                    defer a.free(bound);
                    const acquired = try occurrence.acquired(dispatched, binding, attempt, storage.digest(bound));
                    try self.store().begin();
                    defer self.store().rollback();
                    _ = try self.store().putObject(bound);
                    if (message_decoded) |saved| try self.store().putRecord(state.Message, "message", saved.value.id, value.id, saved.value);
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, acquired);
                    try self.persist(a, value, initial.revision, "inbox.acquire", .preserve);
                    return .progressed;
                },
                .leaf => {
                    var preparation = std.heap.ArenaAllocator.init(a);
                    defer preparation.deinit();
                    const prepared = if (entry.declaration.capture) |adapter| self.prepareProjection(preparation.allocator(), value, adapter, request.value.binding.payload) catch |err|
                        return self.blockedOccurrence(a, initial, pending, switch (err) {
                            error.Capacity, error.OutOfMemory => .capacity,
                            error.MissingArtifact, error.CorruptObject => .missing_artifact,
                            else => .incompatible_profile,
                        }) else null;
                    return self.dispatchAcquisition(a, initial, pending, entry, request_bytes, prepared, .environment);
                },
            }
        }

        fn dispatchAcquisition(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, entry: registry.Entry, request_bytes: []const u8, prepared: ?[]const u8, operation_kind: state.AttemptOperation) !Step {
            if (self.work != null) return .idle;
            const subject = try self.occurrenceSubject(a, initial, pending);
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const binding: occurrence.Binding = .{ .id = pending.id, .task = pending.task, .work = pending.work, .request = pending.request };
            const dispatched = try occurrence.dispatch(pending, binding, attempt, subject.cancelling, subject.cleanup);
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (pending.work == null) value.schedule = .active;
            const charged_bytes = if (prepared) |body| body.len else request_bytes.len;
            if (entry.declaration.inference) {
                value.inference_attempts = try std.math.add(u64, value.inference_attempts, 1);
                value.inference_request_bytes = try std.math.add(u64, value.inference_request_bytes, charged_bytes);
            }
            const retained = try self.allocator.dupe(u8, request_bytes);
            errdefer self.allocator.free(retained);
            const retained_prepared = if (prepared) |body| try self.allocator.dupe(u8, body) else null;
            errdefer if (retained_prepared) |body| self.allocator.free(body);
            const retained_profile = try self.allocator.dupe(u8, self.profile.bytes);
            errdefer self.allocator.free(retained_profile);
            const work: Work = .{ .owner_epoch = self.owner_epoch, .task = value.id, .subject_work = pending.work, .occurrence = pending.id, .attempt = attempt, .request = retained, .prepared = retained_prepared, .profile = retained_profile, .entry = entry, .operation = operation_kind, .cleanup = subject.cleanup };
            try self.store().begin();
            defer self.store().rollback();
            try self.store().createRecord(state.Attempt, "attempt", attempt, value.id, .{ .id = attempt, .task = value.id, .occurrence = pending.id, .request = try self.store().putObject(request_bytes), .profile = value.profile, .capability = try name(entry.declaration.identity), .operation = operation_kind, .inference = entry.declaration.inference, .prepared = if (prepared) |body| try self.store().putObject(body) else null });
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, dispatched);
            try self.effectSchedule(a, &value, pending, .active, null, false);
            try self.persist(a, value, initial.revision, "effect.dispatch", .preserve);
            self.work = work;
            self.subjectRemove(.{ .task = value.id, .work = pending.work });
            return .{ .work = work };
        }

        fn projectionBinding(self: *Self, value: state.Task) registry.ProjectionBinding {
            return .{ .task = value.id, .tenant = value.tenant.bytes, .profile = self.profile.bytes, .application = self.application.image_identity, .resources = value.resources.items };
        }

        fn prepareProjection(self: *Self, a: std.mem.Allocator, value: state.Task, adapter: registry.CaptureAdapter, payload: []const u8) ![]u8 {
            return self.store().project([]u8, a, self.handlers, self.projectionBinding(value), struct {
                adapter: registry.CaptureAdapter,
                payload: []const u8,
                pub fn run(this: @This(), context: registry.ProjectionContext) ![]u8 {
                    return this.adapter.prepare(context, this.payload);
                }
            }{ .adapter = adapter, .payload = payload });
        }

        fn interpretProjection(self: *Self, a: std.mem.Allocator, value: state.Task, adapter: registry.CaptureAdapter, payload: []const u8, prepared: []const u8, response: []const u8) !registry.Projection {
            return self.store().project(registry.Projection, a, self.handlers, self.projectionBinding(value), struct {
                adapter: registry.CaptureAdapter,
                payload: []const u8,
                prepared: []const u8,
                response: []const u8,
                pub fn run(this: @This(), context: registry.ProjectionContext) !registry.Projection {
                    return this.adapter.interpret(context, this.payload, this.prepared, this.response);
                }
            }{ .adapter = adapter, .payload = payload, .prepared = prepared, .response = response });
        }

        fn capture(self: *Self, a: std.mem.Allocator, work: Work, raw: []const u8) !void {
            defer self.releaseWork();
            errdefer self.store().fence();
            // Publication failure fences this owner. The durable dispatched
            // occurrence then recovers as unknown, never as permission to retry.
            if (work.prepared == null) return error.InvalidPreparedRequest;
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const next = try occurrence.captured(saved.value, .{ .id = work.occurrence, .task = work.task, .work = work.subject_work, .request = saved.value.request }, work.attempt);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            try self.store().begin();
            defer self.store().rollback();
            try self.store().createRecord(state.Capture, "capture", work.attempt, work.task, .{
                .task = work.task,
                .occurrence = work.occurrence,
                .attempt = work.attempt,
                .request = try self.store().putObject(work.prepared.?),
                .response = try self.store().putObject(raw),
                .disposition = .complete,
            });
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, next);
            try self.effectSchedule(a, &value, saved.value, .queued, null, true);
            try self.persist(a, value, previous, "effect.capture", .preserve);
            try self.wakeOccurrence(a, value, saved.value);
        }

        fn interpretCapture(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence) !Step {
            const attempt_id = pending.state.captured.id;
            var attempt = try self.record(state.Attempt, a, "attempt", attempt_id, initial.id);
            defer attempt.deinit();
            var raw = try self.record(state.Capture, a, "capture", attempt_id, initial.id);
            defer raw.deinit();
            if (raw.value.disposition != .complete or raw.value.response == null or raw.value.projection != null or attempt.value.prepared == null or
                !same(&attempt.value.occurrence, &pending.id) or !same(&raw.value.occurrence, &pending.id) or
                !same(&attempt.value.profile.digest, &initial.profile.digest) or
                !std.meta.eql(attempt.value.prepared.?, raw.value.request)) return error.CorruptState;
            const encoded = try self.store().object(a, attempt.value.request, null);
            defer a.free(encoded);
            var request = try data.invocation.decode(data.invocation.Request, a, encoded);
            defer request.deinit();
            if (!same(&request.value.request_identity, &pending.request)) return error.CorruptState;
            // Resolve the original schemas without acquiring another I/O grant.
            const entry = try self.handlers.resolve(request.value, (try self.occurrenceSubject(a, initial, pending)).image);
            if (attempt.value.operation == .workspace_build) return self.interpretWorkspaceBuild(a, initial, pending, attempt.value, raw.value);
            const adapter = entry.declaration.capture orelse return error.IncompatibleProfile;
            const rendered = try self.store().object(a, raw.value.request, null);
            defer a.free(rendered);
            const response = try self.store().object(a, raw.value.response.?, null);
            defer a.free(response);
            var projection_arena = std.heap.ArenaAllocator.init(a);
            defer projection_arena.deinit();
            const result = self.interpretProjection(projection_arena.allocator(), initial, adapter, request.value.binding.payload, rendered, response) catch
                return self.blockedOccurrence(a, initial, pending, .unavailable_environment);
            var schema = try data.schema.decode(a, entry.resume_schema);
            defer schema.deinit();
            data.schema.validateValue(a, schema.descriptor, result.reply) catch return self.blockedOccurrence(a, initial, pending, .unavailable_environment);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = result.reply });
            defer a.free(bound);
            const next = try occurrence.acquired(pending, .{ .id = pending.id, .task = initial.id, .work = pending.work, .request = pending.request }, attempt_id, storage.digest(bound));
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (entry.declaration.inference) if (result.output_tokens) |tokens| {
                value.inference_output_tokens = std.math.add(u64, value.inference_output_tokens, tokens) catch return self.blockedOccurrence(a, initial, pending, .capacity);
            };
            try self.store().begin();
            defer self.store().rollback();
            const reply = try self.store().putObject(bound);
            const objects = try a.alloc(state.Reference, result.objects.len);
            defer a.free(objects);
            for (result.objects, objects) |object, *reference| reference.* = try self.store().putObject(object);
            try self.store().retainProjection(adapter.dependencies, result.objects);
            var projected = raw.value;
            projected.projection = .{ .reply = reply, .objects = .{ .items = objects }, .output_tokens = result.output_tokens };
            try self.store().putRecord(state.Capture, "capture", attempt_id, initial.id, projected);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, initial.id, next);
            if (raw.value.reconciliation) |id| {
                var prior = try self.record(state.Reconciliation, a, "reconciliation", id, initial.id);
                defer prior.deinit();
                var recovery = prior.value;
                if (recovery.outcome != .capture_admitted or !same(&recovery.attempt, &attempt_id) or !same(&recovery.occurrence, &pending.id) or !std.meta.eql(recovery.outcome.capture_admitted, raw.value.response.?)) return error.CorruptState;
                recovery.previous = try self.snapshotRecord(state.Reconciliation, a, "reconciliation", id, initial.id);
                recovery.outcome = .{ .reply_settled = reply };
                try self.store().putRecord(state.Reconciliation, "reconciliation", id, initial.id, recovery);
            }
            try self.effectSchedule(a, &value, pending, .queued, null, true);
            try self.persist(a, value, initial.revision, "effect.interpret", .preserve);
            try self.wakeOccurrence(a, value, pending);
            return .progressed;
        }

        fn currentWork(self: *Self, work: Work) !void {
            const current = self.work orelse return error.StaleOccurrence;
            if (!same(&self.owner_epoch, &work.owner_epoch) or !same(&current.owner_epoch, &work.owner_epoch) or
                !same(&current.task, &work.task) or !std.meta.eql(current.subject_work, work.subject_work) or current.operation != work.operation or !same(&current.occurrence, &work.occurrence) or !same(&current.attempt, &work.attempt)) return error.StaleOccurrence;
            if ((current.recovery != null) != (work.recovery != null)) return error.StaleOccurrence;
            if (current.recovery) |item| if (!same(&item.id, &work.recovery.?.id)) return error.StaleOccurrence;
        }
        fn releaseWork(self: *Self) void {
            self.allocator.free(self.work.?.request);
            if (self.work.?.prepared) |body| self.allocator.free(body);
            self.allocator.free(self.work.?.profile);
            if (self.work.?.recovery) |item| self.allocator.free(item.body);
            self.work = null;
        }
        pub fn shouldCancelWork(self: *Self, work: Work) !bool {
            try self.currentWork(work);
            return !work.cleanup and self.work.?.cancel_requested;
        }

        /// All front ends publish a joined worker through this same owner.
        pub fn completeWork(self: *Self, a: std.mem.Allocator, work: Work, result: WorkResult) !void {
            switch (result) {
                .acquired => |bytes| return self.acquire(a, work, bytes),
                .not_sent => return self.notSent(a, work),
                .unknown => return self.unknown(a, work),
                .rederived => |finding| {
                    try self.currentWork(work);
                    if (work.recovery == null) return error.InvalidRecovery;
                    return self.completeRecoveryWork(a, work, .{ .rederived = finding });
                },
                .failure => |err| {
                    try self.currentWork(work);
                    self.releaseWork();
                    self.store().fence();
                    return err;
                },
            }
        }

        fn completeRecoveryWork(self: *Self, a: std.mem.Allocator, work: Work, completion: ?RecoveryCompletion) !void {
            try self.currentWork(work);
            defer self.releaseWork();
            errdefer self.store().fence();
            var value = try self.task(a, work.task);
            defer value.deinit();
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer pending.deinit();
            var item = try self.record(state.Reconciliation, a, "reconciliation", work.recovery.?.id, work.task);
            defer item.deinit();
            if (item.value.owner_epoch == null or !same(&item.value.owner_epoch.?, &work.owner_epoch) or !same(&item.value.attempt, &work.attempt) or !same(&item.value.occurrence, &work.occurrence)) return error.StaleOccurrence;
            try self.finishRecovery(a, value.value, pending.value, item.value, completion, .unavailable);
        }
        /// A worker has returned and will no longer access this work item.
        /// Acquisition is published before any subsequent Kosmos consumption.
        pub fn acquire(self: *Self, a: std.mem.Allocator, work: Work, reply: []const u8) !void {
            try self.currentWork(work);
            if (work.recovery != null) return self.completeRecoveryWork(a, work, .{ .evidence = reply });
            if (work.operation == .workspace_build or work.entry.declaration.capture != null) return self.capture(a, work, reply);
            defer self.releaseWork();
            errdefer self.store().fence();
            var schema = try data.schema.decode(a, work.entry.resume_schema);
            defer schema.deinit();
            try data.schema.validateValue(a, schema.descriptor, reply);
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const binding: occurrence.Binding = .{ .id = work.occurrence, .task = work.task, .work = work.subject_work, .request = saved.value.request };
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = saved.value.request, .value = reply });
            defer a.free(bound);
            const acquired = try occurrence.acquired(saved.value, binding, work.attempt, storage.digest(bound));
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(bound);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, acquired);
            try self.effectSchedule(a, &value, saved.value, .queued, null, true);
            try self.persist(a, value, previous, "effect.acquire", .preserve);
            try self.wakeOccurrence(a, value, saved.value);
        }
        pub fn unknown(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try self.currentWork(work);
            if (work.recovery != null) return self.completeRecoveryWork(a, work, null);
            defer self.releaseWork();
            errdefer self.store().fence();
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const binding: occurrence.Binding = .{ .id = work.occurrence, .task = work.task, .work = work.subject_work, .request = saved.value.request };
            const lost = try occurrence.unknown(saved.value, binding, work.attempt);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            if (work.subject_work == null) {
                value.schedule = .parked;
                value.blocker = .unavailable_environment;
            }
            try self.store().begin();
            defer self.store().rollback();
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, lost);
            if (work.subject_work == null) try self.event(&value, .delivery_unknown, "{}");
            try self.effectSchedule(a, &value, saved.value, .parked, .unavailable_environment, false);
            try self.persist(a, value, previous, "effect.unknown", .preserve);
            self.subjectRemove(.{ .task = work.task, .work = work.subject_work });
            try self.retire(a);
        }

        pub fn notSent(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try self.currentWork(work);
            if (work.recovery != null) return self.completeRecoveryWork(a, work, null);
            defer self.releaseWork();
            errdefer self.store().fence();
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const next = try occurrence.notSent(saved.value, .{ .id = work.occurrence, .task = work.task, .work = work.subject_work, .request = saved.value.request }, work.attempt);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const subject = try self.occurrenceSubject(a, value, saved.value);
            const cancelling = subject.cancelling and !subject.cleanup;
            if (cancelling) try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            if (work.subject_work == null) {
                value.blocker = if (cancelling) null else .unavailable_environment;
                value.schedule = if (cancelling) .queued else .parked;
            }
            try self.store().begin();
            defer self.store().rollback();
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, next);
            if (work.subject_work == null) try self.event(&value, .blocked, "{\"delivery\":\"definitely_not_sent\"}");
            try self.effectSchedule(a, &value, saved.value, if (cancelling) .queued else .parked, if (cancelling) null else .unavailable_environment, false);
            try self.persist(a, value, previous, "effect.not-sent", .preserve);
            if (cancelling) try self.wakeOccurrence(a, value, saved.value);
        }

        fn archiveAccess(self: *Self) !void {
            try self.allowed();
            if (self.work != null) return error.UnsettledOccurrence;
        }

        fn requireArchiveRecord(records: []const state.ArchiveRecord, kind: state.RecordKind, id: state.Digest) !void {
            for (records) |row| if (row.kind == kind and same(&row.id, &id)) return;
            return error.InvalidArchive;
        }

        /// Both directions of the inbox/message relationship are checked. An
        /// empty reply has no message; a nonempty reply names exactly the saved
        /// payload and its acquired/consumed boundary.
        fn validateInboxReply(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, saved: occurrence.Occurrence, bytes: []const u8) !?state.Digest {
            var decoded = try contracts.decodeOwned(contracts.InboxReply(Types.Message), a, bytes);
            defer decoded.deinit();
            if (decoded.value == .empty) return null;
            const input = decoded.value.message;
            var id: state.Digest = undefined;
            if (input.id.bytes.len != 64) return error.InvalidArchive;
            _ = std.fmt.hexToBytes(&id, input.id.bytes) catch return error.InvalidArchive;
            var message_value = try self.record(state.Message, a, "message", id, task_id);
            defer message_value.deinit();
            const item = message_value.value;
            const expected: state.MessageDisposition = switch (saved.state) {
                .settled_reply => .acquired,
                .admitted => |admitted| if (admitted == .reply) .consumed else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (item.disposition != expected or item.occurrence == null or !same(&item.occurrence.?, &saved.id)) return error.InvalidArchive;
            const encoded = try contracts.encodeOwned(Types.Message, a, input.value);
            defer a.free(encoded);
            if (item.value.bytes != encoded.len or !same(&item.value.digest, &storage.digest(encoded))) return error.InvalidArchive;
            return id;
        }

        /// The operation index preserves original identity even when a repeated
        /// answer also has aliases. Messages, receipts and inbox history are one
        /// admitted relationship, not independently trustworthy rows.
        fn validateArchiveAdmissions(self: *Self, a: std.mem.Allocator, value: state.Task, index: state.Archive) !void {
            var receipts: std.AutoHashMap(state.Digest, state.Digest) = .init(a);
            defer receipts.deinit();
            var submitted = false;
            var first_cancel: ?struct { revision: u64, request: state.Digest } = null;
            for (index.operations.items) |row| {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                const bytes = try self.store().object(temporary, row.body, null);
                var decoded = try contracts.decodeOwned(state.Receipt, temporary, bytes);
                defer decoded.deinit();
                const receipt_value = decoded.value;
                if (receipt_value.method == .cancel and (first_cancel == null or receipt_value.revision < first_cancel.?.revision)) {
                    first_cancel = .{ .revision = receipt_value.revision, .request = receipt_value.request_digest };
                }
                const primary = try self.operationKey(temporary, receipt_value.client_operation_id.bytes);
                const original = (try self.store().savedReceipt(temporary, &primary)) orelse return error.InvalidArchive;
                if (!same(bytes, original) or (!same(row.key.bytes, &primary) and receipt_value.method != .respond)) return error.InvalidArchive;
                const expected: state.Disposition = switch (receipt_value.method) {
                    .submit => .accepted,
                    .message => .queued,
                    .respond => .answer_acquired,
                    .cancel => .cancellation_requested,
                    .@"resume" => .resumed,
                    .import_checkpoint => .imported,
                    .reconcile => .reconciled,
                    .workspace => .accepted,
                };
                if (receipt_value.disposition != expected or (receipt_value.message != null) != (receipt_value.method == .message) or
                    (receipt_value.question != null) != (receipt_value.method == .respond)) return error.InvalidArchive;
                if (receipt_value.method == .submit) {
                    if (submitted or receipt_value.revision != 1) return error.InvalidArchive;
                    submitted = true;
                    const input_bytes = try self.store().object(temporary, value.input, null);
                    var input = try contracts.decodeOwned(Types.Input, temporary, input_bytes);
                    defer input.deinit();
                    const expected_digest = try submitDigest(temporary, value.profile.digest, input.value);
                    if (!same(&expected_digest, &receipt_value.request_digest)) return error.InvalidArchive;
                }
                if (receipt_value.method == .message) {
                    const id = receipt_value.message.?;
                    const found = try receipts.getOrPut(id);
                    if (found.found_existing) return error.InvalidArchive;
                    found.value_ptr.* = receipt_value.request_digest;
                }
                if (receipt_value.method == .reconcile) {
                    const id = receipt_value.reconciliation orelse return error.InvalidArchive;
                    try requireArchiveRecord(index.records.items, .reconciliation, id);
                    var recovery = try self.record(state.Reconciliation, temporary, "reconciliation", id, value.id);
                    defer recovery.deinit();
                    if (recovery.value.admission_revision == 0) return error.InvalidArchive;
                    const expected_digest = try reconcileDigest(temporary, value.id, recovery.value.admission_revision - 1, recovery.value.occurrence, recovery.value.attempt, recovery.value.selection);
                    if (!same(&expected_digest, &receipt_value.request_digest)) return error.InvalidArchive;
                }
            }
            if (!submitted) return error.InvalidArchive;
            if (value.cancellation) |reason| if (first_cancel) |admitted| {
                // Later cancel operations may acknowledge another reason, but
                // cannot replace the first durable control already accepted.
                const expected = try cancelDigest(a, value.id, reason);
                if (!same(&admitted.request, &expected)) return error.InvalidArchive;
            };
            var ordinals: std.AutoHashMap(u64, void) = .init(a);
            defer ordinals.deinit();
            var count: u64 = 0;
            for (index.records.items) |row| {
                if (row.kind != .message) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                var decoded = try self.record(state.Message, temporary, "message", row.id, value.id);
                defer decoded.deinit();
                const item = decoded.value;
                if (!same(item.schema_id.bytes, Types.message_schema_id) or item.ordinal == 0 or item.ordinal >= value.next_message) return error.InvalidArchive;
                const ordinal = try ordinals.getOrPut(item.ordinal);
                if (ordinal.found_existing) return error.InvalidArchive;
                count += 1;
                const bytes = try self.store().object(temporary, item.value, null);
                var payload = contracts.decodeOwned(Types.Message, temporary, bytes) catch |err| return if (err == error.OutOfMemory) err else error.InvalidArchive;
                defer payload.deinit();
                const receipt_digest = receipts.get(item.id) orelse return error.InvalidArchive;
                if (!same(&receipt_digest, &try messageDigest(temporary, value.id, payload.value))) return error.InvalidArchive;
                switch (item.disposition) {
                    .queued, .not_consumed => {
                        if (item.occurrence != null or (item.disposition == .not_consumed and !value.terminal())) return error.InvalidArchive;
                    },
                    .acquired, .consumed => {
                        const occurrence_id = item.occurrence orelse return error.InvalidArchive;
                        try requireArchiveRecord(index.records.items, .occurrence, occurrence_id);
                        var saved = try self.record(occurrence.Occurrence, temporary, "occurrence", occurrence_id, value.id);
                        defer saved.deinit();
                        const acquired = switch (saved.value.state) {
                            .settled_reply => |reply| reply,
                            .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.InvalidArchive,
                            else => return error.InvalidArchive,
                        };
                        const request_bytes = try self.store().object(temporary, saved.value.request_object, null);
                        var request = try data.invocation.decode(data.invocation.Request, temporary, request_bytes);
                        defer request.deinit();
                        const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                        if (entry.declaration.kind != .inbox) return error.InvalidArchive;
                        const bound = try self.store().acquiredObject(temporary, acquired.reply, null);
                        var reply = try data.invocation.decode(data.invocation.Result, temporary, bound);
                        defer reply.deinit();
                        const input_id = (try self.validateInboxReply(temporary, value.id, saved.value, reply.value.value)) orelse return error.InvalidArchive;
                        if (!same(&input_id, &item.id)) return error.InvalidArchive;
                    },
                }
            }
            if (value.next_message != count + 1 or receipts.count() != count) return error.InvalidArchive;
        }

        /// The retained request determines which acquisition evidence must
        /// exist. Validating only supplied attempts/questions misses omissions.
        fn validateWorkspacePortOccurrence(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, pending: occurrence.Occurrence, reference: state.Reference, request: data.invocation.Request, records: []const state.ArchiveRecord) !void {
            const bytes = try self.store().object(a, reference, null);
            var decoded = try contracts.decodeOwned(workspace.Port, a, bytes);
            defer decoded.deinit();
            const port = decoded.value;
            try requireArchiveRecord(records, .workspace_port, port.id);
            const record_bytes = (try self.store().recordBytes(a, "workspace_port", port.id, task_id)) orelse return error.InvalidArchive;
            const canonical: state.Reference = .{ .digest = storage.digest(record_bytes), .bytes = record_bytes.len };
            if (!std.meta.eql(canonical, reference) or !std.meta.eql(port.task, task_id) or
                !std.meta.eql(@as(?state.Digest, port.work), pending.work) or !std.meta.eql(port.occurrence, pending.id) or
                !std.meta.eql(port.request_identity, pending.request) or !std.meta.eql(port.request, pending.request_object) or port.generation == 0) return error.InvalidArchive;
            var work = try self.workspaceWork(a, task_id, port.work);
            defer work.deinit();
            var program = try self.workspaceProgram(a, task_id, work.value.program);
            defer program.deinit();
            if (!std.meta.eql(port.program, program.value.artifact) or port.generation > work.value.port_generation) return error.InvalidArchive;
            var matched = false;
            for (program.value.description.ports.items) |candidate| {
                if (!same(candidate.identity.bytes, port.interface.identity.bytes)) continue;
                if (candidate.class != port.interface.class) return error.InvalidArchive;
                inline for (.{ "argument", "observation", "payload", "command" }) |field| if (!std.meta.eql(@field(candidate, field), @field(port.interface, field))) return error.InvalidArchive;
                matched = true;
            }
            if (!matched or !same(port.interface.identity.bytes, request.binding.semantic_identity) or
                !std.meta.eql(port.interface.payload, state.Reference{ .digest = storage.digest(request.binding.payload_schema), .bytes = request.binding.payload_schema.len }) or
                !std.meta.eql(port.interface.command, state.Reference{ .digest = storage.digest(request.binding.resume_schema), .bytes = request.binding.resume_schema.len }) or
                !std.meta.eql(port.payload, state.Reference{ .digest = storage.digest(request.binding.payload), .bytes = request.binding.payload.len })) return error.InvalidArchive;
            var payload_schema = try data.schema.decode(a, request.binding.payload_schema);
            defer payload_schema.deinit();
            try data.schema.validateValue(a, payload_schema.descriptor, request.binding.payload);
            const acquired: ?occurrence.Acquired = switch (pending.state) {
                .ready => null,
                .settled_reply => |reply| reply,
                .admitted => |admitted| if (admitted == .reply) admitted.reply else if (admitted.cancelled == null) null else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (acquired) |reply| {
                if (reply.answer != null) return error.InvalidArchive;
                try requireArchiveRecord(records, .workspace_port_reply, reply.attempt);
                var answer = try self.record(workspace.PortReply, a, "workspace_port_reply", reply.attempt, task_id);
                defer answer.deinit();
                if (!std.meta.eql(answer.value.task, task_id) or !std.meta.eql(answer.value.id, reply.attempt) or
                    !std.meta.eql(answer.value.port, reference) or !std.meta.eql(answer.value.reply.digest, reply.reply)) return error.InvalidArchive;
                var result = try data.invocation.decode(data.invocation.Result, a, try self.store().object(a, answer.value.reply, null));
                defer result.deinit();
                if (!std.meta.eql(result.value.request_identity, pending.request)) return error.InvalidArchive;
                var result_schema = try data.schema.decode(a, request.binding.resume_schema);
                defer result_schema.deinit();
                try data.schema.validateValue(a, result_schema.descriptor, result.value.value);
                var command = try @import("dynamic_values.zig").decode(a, request.binding.resume_schema, result.value.value);
                defer command.deinit();
                if (answer.value.command == .finish) {
                    if (port.interface.class != .alternative or answer.value.input != null or try values.fromJson(u32, a, command.value.object.get("tag").?) != 1) return error.InvalidArchive;
                    var observation = try @import("dynamic_values.zig").decode(a, request.binding.payload_schema, request.binding.payload);
                    defer observation.deinit();
                    if (try values.fromJson(u32, a, observation.value.array.items[1].object.get("tag").?) != 1) return error.InvalidArchive;
                } else {
                    const input = answer.value.input orelse return error.InvalidArchive;
                    const origin = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, input.digest));
                    if (!std.meta.eql(origin.artifact, input) or !std.meta.eql(origin.schema, port.interface.argument)) return error.InvalidArchive;
                    const expected = if (port.interface.class == .alternative) blk: {
                        if (try values.fromJson(u32, a, command.value.object.get("tag").?) != 0) return error.InvalidArchive;
                        break :blk command.value.object.get("value").?;
                    } else command.value;
                    const schema = try self.store().object(a, port.interface.argument, null);
                    const input_bytes = try @import("dynamic_values.zig").encode(a, schema, expected);
                    if (!std.meta.eql(origin.value, state.Reference{ .digest = storage.digest(input_bytes), .bytes = input_bytes.len })) return error.InvalidArchive;
                    var found = false;
                    for (work.value.inputs.items) |source| found = found or std.meta.eql(source, input);
                    if (!found) return error.InvalidArchive;
                }
            }
        }

        fn validateOccurrenceProvenance(self: *Self, a: std.mem.Allocator, value: state.Task, records: []const state.ArchiveRecord) !void {
            // A history can contain many occurrences of the same immutable
            // image. Decode each distinct content reference once in this read
            // pass; every occurrence still checks its own request and route.
            var images: std.AutoHashMap(state.Reference, state.Digest) = .init(a);
            defer images.deinit();
            for (records) |row| {
                if (row.kind != .occurrence) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                var decoded = try self.record(occurrence.Occurrence, temporary, "occurrence", row.id, value.id);
                defer decoded.deinit();
                const saved = decoded.value;
                try requireArchiveRecord(records, .execution_route, saved.id);
                var route = try self.record(workspace.ExecutionRoute, temporary, "execution_route", saved.id, value.id);
                defer route.deinit();
                if (!std.meta.eql(route.value.task, value.id) or !std.meta.eql(route.value.id, saved.id) or !std.meta.eql(route.value.work, saved.work)) return error.InvalidArchive;
                var current_id = value.current_occurrence;
                var expected_image = value.image;
                if (saved.work) |work_id| {
                    try requireArchiveRecord(records, .workspace_work, work_id);
                    var work = try self.workspaceWork(temporary, value.id, work_id);
                    defer work.deinit();
                    var program = try self.workspaceProgram(temporary, value.id, work.value.program);
                    defer program.deinit();
                    expected_image = program.value.description.image;
                    current_id = work.value.current_occurrence;
                }
                if (!std.meta.eql(expected_image, route.value.image)) return error.InvalidArchive;
                const is_current = if (current_id) |id| same(&id, &saved.id) else false;
                if (is_current == (saved.state == .admitted)) return error.InvalidArchive;
                const encoded = try self.store().object(temporary, saved.request_object, null);
                var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
                defer request.deinit();
                const identity = images.get(expected_image) orelse identity: {
                    var image = try data.program_image.decode(temporary, try self.store().object(temporary, expected_image, null));
                    defer image.deinit();
                    try images.put(expected_image, image.identity);
                    break :identity image.identity;
                };
                if (!same(&request.value.request_identity, &saved.request) or !same(&request.value.binding.program_identity, &identity) or !same(&route.value.program_identity, &identity)) return error.InvalidArchive;
                if (route.value.port) |port| {
                    if (saved.work == null or route.value.delegation != null) return error.InvalidArchive;
                    try self.validateWorkspacePortOccurrence(temporary, value.id, saved, port, request.value, records);
                    continue;
                }
                if (saved.work) |id| {
                    var work = try self.workspaceWork(temporary, value.id, id);
                    defer work.deinit();
                    if (work.value.delegation == null or !std.meta.eql(work.value.delegation, route.value.delegation) or !std.meta.eql(work.value.instrument_occurrence, saved.id)) return error.InvalidArchive;
                    const input = try contracts.decodeOwned(instrument.Input, temporary, request.value.binding.payload);
                    if (!std.meta.eql(input.value.delegation, work.value.delegation.?)) return error.InvalidArchive;
                }
                // Cancellation can retire READY before a handler is available.
                // Neither that state nor READY claims any acquisition.
                if (saved.state == .ready or (saved.state == .admitted and saved.state.admitted == .cancelled and saved.state.admitted.cancelled == null)) continue;
                const entry = try self.handlers.resolve(request.value, route.value.program_identity);
                const acquired: ?occurrence.Acquired = switch (saved.state) {
                    .settled_reply => |reply| reply,
                    .admitted => |admitted| if (admitted == .reply) admitted.reply else null,
                    .awaiting, .not_sent, .unknown, .captured => null,
                    else => return error.UnsettledOccurrence,
                };
                var reply_value: ?[]const u8 = null;
                if (acquired) |reply| {
                    const bytes = try self.store().acquiredObject(temporary, reply.reply, null);
                    const result = try data.invocation.decode(data.invocation.Result, temporary, bytes);
                    // Keep the decoded backing until this iteration's arena ends.
                    if (!same(&result.value.request_identity, &saved.request)) return error.InvalidArchive;
                    var schema = try data.schema.decode(temporary, entry.resume_schema);
                    defer schema.deinit();
                    try data.schema.validateValue(temporary, schema.descriptor, result.value.value);
                    reply_value = result.value.value;
                }
                switch (entry.declaration.kind) {
                    .leaf => {
                        const attempt_id = if (acquired) |reply| reply.attempt else switch (saved.state) {
                            .not_sent, .unknown, .captured => |attempt| attempt.id,
                            else => return error.InvalidArchive,
                        };
                        if (acquired) |reply| if (reply.answer != null) return error.InvalidArchive;
                        try requireArchiveRecord(records, .attempt, attempt_id);
                        var attempt = try self.record(state.Attempt, temporary, "attempt", attempt_id, value.id);
                        defer attempt.deinit();
                        if (!same(&attempt.value.occurrence, &saved.id) or !std.meta.eql(attempt.value.request, saved.request_object)) return error.InvalidArchive;
                        if (saved.state == .captured and entry.declaration.capture == null) return error.InvalidArchive;
                        if ((acquired != null and entry.declaration.capture != null) or saved.state == .captured) {
                            try requireArchiveRecord(records, .capture, attempt_id);
                            var raw_capture = try self.record(state.Capture, temporary, "capture", attempt_id, value.id);
                            defer raw_capture.deinit();
                            if (!same(&raw_capture.value.occurrence, &saved.id)) return error.InvalidArchive;
                        }
                    },
                    .workspace => {
                        if (acquired == null) {
                            const attempt_id = switch (saved.state) {
                                .captured, .unknown, .not_sent => |attempt| attempt.id,
                                else => return error.InvalidArchive,
                            };
                            try requireArchiveRecord(records, .attempt, attempt_id);
                            var attempt = try self.record(state.Attempt, temporary, "attempt", attempt_id, value.id);
                            defer attempt.deinit();
                            if (attempt.value.operation != .workspace_build or !std.meta.eql(attempt.value.request, saved.request_object)) return error.InvalidArchive;
                            if (saved.state == .captured) try requireArchiveRecord(records, .capture, attempt_id);
                            continue;
                        }
                        const reply = acquired.?;
                        if (reply.answer != null) return error.InvalidArchive;
                        var observation = try contracts.decodeOwned(wc.Reply, temporary, reply_value.?);
                        defer observation.deinit();
                    },
                    .inbox => {
                        const reply = acquired orelse return error.InvalidArchive;
                        if (reply.answer != null) return error.InvalidArchive;
                        _ = try self.validateInboxReply(temporary, value.id, saved, reply_value.?);
                    },
                    .question => {
                        const waiting: ?occurrence.Waiting = switch (saved.state) {
                            .awaiting => |pending| pending,
                            .admitted => |admitted| if (admitted == .cancelled) admitted.cancelled else null,
                            else => null,
                        };
                        const answer: ?occurrence.Answer = if (acquired) |reply| reply.answer orelse return error.InvalidArchive else null;
                        const question_id = if (waiting) |pending| pending.question else if (answer) |bound| bound.question else return error.InvalidArchive;
                        try requireArchiveRecord(records, .question, question_id);
                        var question = try self.record(state.Question, temporary, "question", question_id, value.id);
                        defer question.deinit();
                        const q = question.value;
                        if (q.retired != (saved.state == .admitted) or q.revision == 0 or !same(&q.occurrence, &saved.id) or
                            !same(&q.request_digest, &saved.request) or !std.meta.eql(q.request, saved.request_object) or
                            !same(&q.pending_digest, &request.value.binding.pending_state_digest) or
                            !same(&q.answer_schema_digest, &storage.digest(entry.resume_schema)) or !same(q.answer_schema_id.bytes, entry.declaration.answer_schema_id.?)) return error.InvalidArchive;
                        if (waiting) |pending| {
                            if (q.answer != null or q.receipt != null or !same(&pending.pending_digest, &q.pending_digest)) return error.InvalidArchive;
                        } else {
                            const reference = q.answer orelse return error.InvalidArchive;
                            const answer_receipt = q.receipt orelse return error.InvalidArchive;
                            const bound = answer.?;
                            if (!same(&reference.digest, &storage.digest(reply_value.?)) or reference.bytes != reply_value.?.len or
                                !same(&bound.digest, &reference.digest) or !same(&bound.pending_digest, &q.pending_digest) or
                                !same(&answer_receipt.task, &value.id) or answer_receipt.method != .respond or answer_receipt.disposition != .answer_acquired or
                                answer_receipt.question == null or !same(&answer_receipt.question.?, &question_id)) return error.InvalidArchive;
                            const bytes = try self.store().object(temporary, reference, null);
                            const expected = try answerDigest(temporary, value.id, question_id, q.revision, q.request_digest, q.answer_schema_id.bytes, bytes);
                            if (!same(&expected, &answer_receipt.request_digest)) return error.InvalidArchive;
                            const key = try self.operationKey(temporary, answer_receipt.client_operation_id.bytes);
                            const receipt_bytes = (try self.store().savedReceipt(temporary, &key)) orelse return error.InvalidArchive;
                            if (!same(receipt_bytes, try contracts.encodeOwned(state.Receipt, temporary, answer_receipt))) return error.InvalidArchive;
                        }
                    },
                }
            }
            // A retained question (including one named by an answer receipt)
            // must also have its occurrence, rather than becoming replay debris.
            for (records) |row| {
                if (row.kind != .question) continue;
                var question = try self.record(state.Question, a, "question", row.id, value.id);
                defer question.deinit();
                try requireArchiveRecord(records, .occurrence, question.value.occurrence);
                var saved = try self.record(occurrence.Occurrence, a, "occurrence", question.value.occurrence, value.id);
                defer saved.deinit();
                const question_id: ?state.Digest = switch (saved.value.state) {
                    .awaiting => |waiting| waiting.question,
                    .settled_reply => |reply| if (reply.answer) |answer| answer.question else null,
                    .admitted => |admitted| switch (admitted) {
                        .reply => |reply| if (reply.answer) |answer| answer.question else null,
                        .cancelled => |waiting| if (waiting) |pending| pending.question else null,
                    },
                    else => null,
                };
                if (question_id == null or !same(&question_id.?, &row.id)) return error.InvalidArchive;
            }
        }

        /// Per-record scratch is backed by the service allocator so replay
        /// releases it even when the enclosing request allocator is an arena.
        /// A projected capture must reproduce its committed reply, replay
        /// objects and usage through the same pure adapter, without acquisition.
        /// Uninterpreted bytes remain private evidence, bound to the exact
        /// original attempt; transfer never claims that interpretation succeeds.
        fn validateCapturedProjections(self: *Self, value: state.Task, records: []const state.ArchiveRecord, mode: enum { inspect, retain }) !void {
            // Retained unsuccessful/rearmed attempts also need request/profile
            // coherence, even though they have no acquired response.
            for (records) |row| {
                if (row.kind != .attempt) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                var attempt = try self.record(state.Attempt, temporary, "attempt", row.id, value.id);
                defer attempt.deinit();
                try requireArchiveRecord(records, .occurrence, attempt.value.occurrence);
                var saved = try self.record(occurrence.Occurrence, temporary, "occurrence", attempt.value.occurrence, value.id);
                defer saved.deinit();
                const encoded = try self.store().object(temporary, attempt.value.request, null);
                var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
                defer request.deinit();
                const entry = try self.handlers.resolve(request.value, try self.occurrenceImage(temporary, value, saved.value));
                if (attempt.value.operation == .workspace_build) {
                    if (entry.declaration.kind != .workspace or saved.value.work != null or attempt.value.inference or attempt.value.prepared == null or
                        !same(&request.value.request_identity, &saved.value.request) or !std.meta.eql(attempt.value.request, saved.value.request_object) or
                        !std.meta.eql(attempt.value.profile, value.profile) or !same(attempt.value.capability.bytes, entry.declaration.identity)) return error.InvalidArchive;
                    const authorized_bytes = try self.authorizeWorkspace(temporary, value, entry, request.value.binding.payload);
                    var authorized = try contracts.decodeOwned(workspace.Authorized, temporary, authorized_bytes);
                    defer authorized.deinit();
                    if (authorized.value.command != .program or authorized.value.command.program != .build) return error.InvalidArchive;
                    const frozen = try self.workspacePrepareBuild(temporary, value, authorized.value);
                    if (!same(frozen, try self.store().object(temporary, attempt.value.prepared.?, null))) return error.InvalidArchive;
                    continue;
                }
                if (entry.declaration.kind != .leaf or !same(&request.value.request_identity, &saved.value.request) or
                    !std.meta.eql(attempt.value.request, saved.value.request_object) or !std.meta.eql(attempt.value.profile, value.profile) or !same(attempt.value.capability.bytes, entry.declaration.identity) or
                    attempt.value.inference != entry.declaration.inference or (attempt.value.prepared != null) != (entry.declaration.capture != null)) return error.InvalidArchive;
                if (entry.declaration.capture) |adapter| {
                    const prepared = try self.store().object(temporary, attempt.value.prepared.?, null);
                    if (!same(prepared, try self.prepareProjection(temporary, value, adapter, request.value.binding.payload))) return error.CorruptState;
                }
            }
            var output_tokens: u64 = 0;
            for (records) |row| {
                if (row.kind != .capture) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                var raw = try self.record(state.Capture, temporary, "capture", row.id, value.id);
                defer raw.deinit();
                const capture_value = raw.value;
                if (!same(&capture_value.attempt, &row.id) or (capture_value.disposition == .complete) != (capture_value.response != null)) return error.CorruptState;
                try requireArchiveRecord(records, .attempt, row.id);
                var attempt = try self.record(state.Attempt, temporary, "attempt", row.id, value.id);
                defer attempt.deinit();
                var saved = try self.record(occurrence.Occurrence, temporary, "occurrence", capture_value.occurrence, value.id);
                defer saved.deinit();
                if (attempt.value.prepared == null or !same(&attempt.value.occurrence, &capture_value.occurrence) or
                    !std.meta.eql(attempt.value.profile, value.profile) or !std.meta.eql(attempt.value.prepared.?, capture_value.request)) return error.CorruptState;
                if (attempt.value.operation == .workspace_build and capture_value.response != null) {
                    try self.validateWorkspaceBuildCapture(temporary, value, saved.value, attempt.value, capture_value);
                    if (capture_value.projection != null) continue;
                }
                const projection = capture_value.projection orelse {
                    const original_attempt = switch (saved.value.state) {
                        .captured => |pending| if (capture_value.disposition == .complete) pending.id else return error.CorruptState,
                        .unknown => |pending| if (capture_value.disposition == .unknown) pending.id else return error.CorruptState,
                        .not_sent => |pending| if (capture_value.disposition == .definitely_not_sent) pending.id else return error.CorruptState,
                        else => return error.CorruptState,
                    };
                    if (!same(&original_attempt, &row.id)) return error.CorruptState;
                    continue;
                };
                if (capture_value.disposition != .complete) return error.CorruptState;
                const acquired = switch (saved.value.state) {
                    .settled_reply => |reply| reply,
                    .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.CorruptState,
                    else => return error.UnsettledOccurrence,
                };
                if (!same(&acquired.attempt, &row.id) or !same(&acquired.reply, &projection.reply.digest)) return error.CorruptState;
                const encoded = try self.store().object(temporary, attempt.value.request, null);
                var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
                defer request.deinit();
                if (!same(&request.value.request_identity, &saved.value.request)) return error.CorruptState;
                const entry = try self.handlers.resolve(request.value, try self.occurrenceImage(temporary, value, saved.value));
                if (!same(attempt.value.capability.bytes, entry.declaration.identity) or attempt.value.inference != entry.declaration.inference) return error.IncompatibleProfile;
                const adapter = entry.declaration.capture orelse return error.IncompatibleProfile;
                const rendered = try self.store().object(temporary, capture_value.request, null);
                const response = try self.store().object(temporary, capture_value.response.?, null);
                const result = try self.interpretProjection(temporary, value, adapter, request.value.binding.payload, rendered, response);
                if (result.objects.len != projection.objects.items.len or result.output_tokens != projection.output_tokens) return error.CorruptState;
                for (result.objects, projection.objects.items) |object, reference| {
                    if (object.len != reference.bytes or !same(&storage.digest(object), &reference.digest)) return error.CorruptState;
                }
                if (mode == .retain) try self.store().retainProjection(adapter.dependencies, result.objects);
                var schema = try data.schema.decode(temporary, entry.resume_schema);
                defer schema.deinit();
                try data.schema.validateValue(temporary, schema.descriptor, result.reply);
                const bound = try data.invocation.encodeOwned(data.invocation.Result, temporary, .{ .request_identity = saved.value.request, .value = result.reply });
                if (!same(bound, try self.store().object(temporary, projection.reply, null))) return error.CorruptState;
                if (entry.declaration.inference) if (result.output_tokens) |tokens| {
                    output_tokens = try std.math.add(u64, output_tokens, tokens);
                };
            }
            if (output_tokens != value.inference_output_tokens) return error.CorruptState;
        }

        fn validateWorkspaceBuildCapture(self: *Self, a: std.mem.Allocator, parent: state.Task, pending: occurrence.Occurrence, attempt: state.Attempt, raw: state.Capture) !void {
            if (attempt.operation != .workspace_build or raw.disposition != .complete or raw.response == null or raw.reconciliation != null) return error.InvalidArchive;
            const prepared = try self.store().object(a, raw.request, null);
            const response = try self.store().object(a, raw.response.?, null);
            const task_name = std.fmt.bytesToHex(parent.id, .lower);
            const expected = try build_job.run(.{ .allocator = a, .io = self.io, .authority = &self.profile.authority, .task_id = &task_name, .profile = self.profile.bytes, .environment = null }, prepared);
            var checked_output = try contracts.decodeOwned(build_job.Output, a, expected);
            defer checked_output.deinit();
            var recorded_output = try contracts.decodeOwned(build_job.Output, a, response);
            defer recorded_output.deinit();
            // Recompilation proves every semantic output byte. Elapsed time is
            // historical accounting, not a reproducible compiler assertion or
            // imported authority. The stored projection below still binds it.
            switch (checked_output.value) {
                inline else => |*v| v.compiler_nanoseconds = 0,
            }
            switch (recorded_output.value) {
                inline else => |*v| v.compiler_nanoseconds = 0,
            }
            if (!same(try contracts.encodeOwned(build_job.Output, a, checked_output.value), try contracts.encodeOwned(build_job.Output, a, recorded_output.value))) return error.InvalidArchive;
            const projection = raw.projection orelse return;
            if (projection.objects.items.len != 0 or projection.output_tokens != null) return error.InvalidArchive;
            const acquired = switch (pending.state) {
                .settled_reply => |reply| reply,
                .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (!std.meta.eql(acquired.attempt, attempt.id) or !std.meta.eql(acquired.reply, projection.reply.digest)) return error.InvalidArchive;
            var output = try contracts.decodeOwned(build_job.Output, a, response);
            defer output.deinit();
            const bound_bytes = try self.store().object(a, projection.reply, null);
            var bound = try data.invocation.decode(data.invocation.Result, a, bound_bytes);
            defer bound.deinit();
            var reply = try contracts.decodeOwned(wc.Reply, a, bound.value.value);
            defer reply.deinit();
            var program: ?contracts.Decoded(workspace.Program) = null;
            defer if (program) |*item| item.deinit();
            if (output.value == .compiled) {
                const ref = reply.value.program orelse return error.InvalidArchive;
                program = try self.workspaceProgram(a, parent.id, try wp.identity(ref, .program));
                const artifact = program.?.value.description;
                var input = try contracts.decodeOwned(build_job.Input, a, prepared);
                defer input.deinit();
                if (!std.meta.eql(artifact.source, state.Reference{ .digest = storage.digest(input.value.source.bytes), .bytes = input.value.source.bytes.len }) or
                    @backingInt(artifact.source_kind) != @backingInt(input.value.kind) or !std.meta.eql(artifact.image, state.Reference{ .digest = storage.digest(output.value.compiled.image.bytes), .bytes = output.value.compiled.image.bytes.len })) return error.InvalidArchive;
                const exposures = try contracts.encodeOwned(contracts.Vector(wc.Exposure, null), a, input.value.exposures);
                if (!same(exposures, try contracts.encodeOwned(contracts.Vector(wc.Exposure, null), a, artifact.exposures))) return error.InvalidArchive;
                const catalog: ?state.Reference = if (input.value.catalog) |bytes| .{ .digest = storage.digest(bytes.bytes), .bytes = bytes.bytes.len } else null;
                if (!std.meta.eql(catalog, artifact.catalog)) return error.InvalidArchive;
            } else if (reply.value.program != null) return error.InvalidArchive;
            const replayed = try self.workspaceBuildReply(a, if (program) |item| item.value.artifact else null, output.value);
            const payload = try contracts.encodeOwned(wc.Reply, a, replayed);
            const result = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = payload });
            if (!same(result, bound_bytes)) return error.InvalidArchive;
        }

        pub fn exportCheckpoint(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, path: []const u8) !archive_api.Exported {
            try self.archiveAccess();
            _ = try self.store().auditRetention(self.handlers, self.application.image_identity);
            var value = try self.task(a, task_id);
            defer value.deinit();
            try self.compatible(value.value);
            {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const index = try self.store().archiveIndex(arena.allocator(), task_id, .{ .digest = storage.digest(self.assets.manifest), .bytes = self.assets.manifest.len });
                try self.validateArchiveAdmissions(arena.allocator(), value.value, index);
                try self.validateOccurrenceProvenance(arena.allocator(), value.value, index.records.items);
                try self.validateCapturedProjections(value.value, index.records.items, .inspect);
                try self.validateWorkspaceRecordBodies(arena.allocator(), task_id, index.records.items);
            }
            return archive_api.write(self.allocator, self.io, self.store(), task_id, self.assets.manifest, path, self.namespace.directory);
        }

        /// A data-copy admission into a fresh namespace, not live custody.
        /// Existing task IDs/receipts survive; current grants are never loaded
        /// from the archive and no resident becomes runnable on import.
        pub fn importCheckpoint(self: *Self, a: std.mem.Allocator, id: []const u8, path: []const u8) !Admission {
            try self.archiveAccess();
            var reader = try archive_api.Reader.open(self.allocator, path);
            defer reader.deinit();
            const Request = struct { method: state.Method, archive: state.Digest };
            const request = try operation(Request, a, .{ .method = .import_checkpoint, .archive = reader.identity });
            if (try self.replay(a, id, request)) |prior| return prior;
            if (self.store().head.generation != 0 or self.active != null or self.runnable.items.len != 0) return error.NonEmptyNamespace;
            try self.store().begin();
            defer self.store().rollback();
            try reader.acquire(self.store());
            var inspected = try archive_api.inspect(a, self.store(), reader.manifest.value, null);
            defer inspected.task.deinit();
            var value = inspected.task.value;
            if (!same(value.principal.bytes, self.profile.authority.principal) or !same(value.tenant.bytes, self.profile.authority.tenant)) return error.Denied;
            const original_runtime = value.runtime_identity;
            value.runtime_identity = self.profile.runtime_identity;
            value.schedule = .parked;
            try self.compatible(value);
            if (!same(value.input_schema_id.bytes, Types.input_schema_id) or !same(value.output_schema_id.bytes, Types.output_schema_id) or !same(value.failure_schema_id.bytes, Types.failure_schema_id) or !same(value.message_schema_id.bytes, Types.message_schema_id)) return error.IncompatibleProfile;
            const build_bytes = try self.store().object(a, reader.manifest.value.build, null);
            defer a.free(build_bytes);
            var build = try json.parseAsset(a, build_bytes, build_bytes.len);
            defer build.deinit();
            for ([_][]const u8{ "native_host_contract", "protocol", "client_mapping", "state_format", "program_sha256", "program_identity", "application_assets_sha256", "optimize" }) |field| {
                const expected = json.get(self.application.manifest, field) orelse return error.InvalidAssets;
                try discovery.sameField(build.value, field, try json.text(expected));
            }
            const dependencies = json.get(build.value, "dependencies") orelse return error.InvalidArchive;
            const current_dependencies = json.get(self.application.manifest, "dependencies") orelse return error.InvalidAssets;
            for ([_][]const u8{ "world", "boundary" }) |field| try discovery.sameField(dependencies, field, try json.text(json.get(current_dependencies, field) orelse return error.InvalidAssets));
            const compiler = json.get(build.value, "compiler") orelse return error.InvalidArchive;
            const current_compiler = json.get(self.application.manifest, "compiler") orelse return error.InvalidAssets;
            try discovery.sameField(compiler, "version", try json.text(json.get(current_compiler, "version") orelse return error.InvalidAssets));
            // Restore only inside the unpublished transaction, then admit the
            // original operation identities and all related input history.
            try self.store().restoreArchiveIndex(a, reader.manifest.value, value);
            try self.validateArchiveAdmissions(a, value, reader.manifest.value);
            try self.validateOccurrenceProvenance(a, value, reader.manifest.value.records.items);
            try self.validateCapturedProjections(value, reader.manifest.value.records.items, .retain);
            try self.validateWorkspaceRecordBodies(a, value.id, reader.manifest.value.records.items);
            // This transaction contains untrusted, unpublished archive data.
            // Reuse the closure validator without treating semantic rejection
            // as corruption of the committed namespace. Store integrity and
            // rollback failures retain their own fencing behavior.
            _ = try @import("retention.zig").verify(self.store(), self.handlers);
            try self.validateImportedState(a, value, inspected.current);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const origin: state.Origin = .{ .id = reader.identity, .task = value.id, .build = reader.manifest.value.build, .native_identity = original_runtime, .source_revision = previous };
            try self.store().createRecord(state.Origin, "origin", origin.id, value.id, origin);
            var event_data = json.object();
            try json.put(a, &event_data, "archive_sha256", json.string(try a.dupe(u8, &std.fmt.bytesToHex(reader.identity, .lower))));
            try self.event(&value, .imported, try json.canonical(a, event_data));
            const admitted = try self.receipt(a, .import_checkpoint, id, request, value, .imported, null, null);
            try self.persist(a, value, previous, "checkpoint.import", .preserve);
            // Imported pending lookups have no live worker in this owner.
            // A crash before this ordinary transition is handled on reopen.
            try self.recover(a);
            return admitted;
        }

        /// Ordering and byte bounds belong to the pending projection. Complete
        /// typed payload/receipt/occurrence coherence is checked for all history
        /// by validateArchiveAdmissions and validateOccurrenceProvenance.
        fn validatePendingMessages(self: *Self, a: std.mem.Allocator, value: state.Task) !void {
            if (value.messages.items.len != 0 and (value.terminal() or !self.acceptsMessages())) return error.InvalidArchive;
            var previous: u64 = 0;
            for (value.messages.items, 0..) |id, index| {
                var decoded = try self.record(state.Message, a, "message", id, value.id);
                defer decoded.deinit();
                const item = decoded.value;
                if (item.ordinal <= previous) return error.InvalidArchive;
                previous = item.ordinal;
                if (item.disposition == .acquired and index != 0) return error.InvalidArchive;
            }
        }

        fn validateImportedState(self: *Self, a: std.mem.Allocator, value: state.Task, pending: ?occurrence.Occurrence) !void {
            if (value.cancellation_applied and value.cancellation == null) return error.InvalidArchive;
            try self.validatePendingMessages(a, value);
            const driver = try self.resident(a, value);
            errdefer self.retire(a) catch {
                self.store().fence();
            };
            const publication = try driver.drive(a, .none, 0);
            const observed = publication.outcome;
            defer a.free(observed);
            const prior = try self.store().object(a, value.outcome, null);
            defer a.free(prior);
            if (!same(observed, prior)) return error.InvalidArchive;
            const checkpoint = publication.checkpoint;
            if (!same(&storage.digest(checkpoint), &value.checkpoint.digest) or checkpoint.len != value.checkpoint.bytes) return error.InvalidArchive;
            var decoded = try data.invocation.decode(data.invocation.Outcome, a, observed);
            defer decoded.deinit();
            if (!same(@tagName(decoded.value), @tagName(value.outcome_kind))) return error.InvalidArchive;
            const terminal_cancellation: ?data.invocation.Reason = switch (decoded.value) {
                .cancelled => |cancelled| cancelled.reason,
                .failed => |failure| failure.cancellation,
                else => null,
            };
            if (terminal_cancellation) |reason| {
                const intent = value.cancellation orelse return error.InvalidArchive;
                if (!value.cancellation_applied or reason != .text or !same(reason.text, intent.bytes)) return error.InvalidArchive;
            }
            if (value.cancellation_applied) switch (decoded.value) {
                .cancelled => {},
                .failed => |failure| if (failure.cancellation == null) return error.InvalidArchive,
                .completed => return error.InvalidArchive,
                else => {
                    // The imported marker claims Kosmos already received this
                    // control. Let Kosmos establish that it is a no-op without
                    // executing authored steps or dispatching any native work.
                    // The next publication replaces the borrowed checkpoint.
                    // Its exact persisted digest/length remain our comparison.
                    const next = try driver.drive(a, .{ .cancel = .{ .text = value.cancellation.?.bytes } }, 0);
                    const repeated = next.outcome;
                    defer a.free(repeated);
                    if (!same(repeated, observed) or next.checkpoint.len != value.checkpoint.bytes or
                        !same(&storage.digest(next.checkpoint), &value.checkpoint.digest)) return error.InvalidArchive;
                },
            };
            switch (decoded.value) {
                .requested => |requested| {
                    const current = pending orelse return error.InvalidArchive;
                    var request = try data.invocation.decode(data.invocation.Request, a, requested.request);
                    defer request.deinit();
                    if (!same(&current.request, &request.value.request_identity)) return error.InvalidArchive;
                    if (requested.request.len != current.request_object.bytes or !same(&storage.digest(requested.request), &current.request_object.digest)) return error.InvalidArchive;
                },
                .completed => |bytes| {
                    if (value.result == null or !same(&value.result.?.digest, &storage.digest(bytes))) return error.InvalidArchive;
                    try self.validateImportedResult(Types.Output, a, value, bytes);
                },
                .failed => |failure| {
                    if (value.result == null or !same(&value.result.?.digest, &value.outcome.digest)) return error.InvalidArchive;
                    try self.validateImportedResult(Types.Failure, a, value, failure.value);
                },
                .cancelled => {
                    if (value.result == null or !same(&value.result.?.digest, &value.outcome.digest) or value.client_result != null or value.result_artifact != null) return error.InvalidArchive;
                },
                else => {},
            }
            if (!value.terminal() and (value.result != null or value.client_result != null or value.result_artifact != null)) return error.InvalidArchive;
            try self.retire(a);
        }
        fn validateImportedResult(self: *Self, comptime T: type, a: std.mem.Allocator, value: state.Task, bytes: []const u8) !void {
            var decoded = try contracts.decodeOwned(T, a, bytes);
            defer decoded.deinit();
            const expected = try json.canonicalBounded(self.allocator, try values.toJson(T, a, decoded.value), try self.store().database.blobLimit());
            defer self.allocator.free(expected);
            const reference = value.client_result orelse return error.InvalidArchive;
            if (reference.bytes != expected.len or !same(&reference.digest, &storage.digest(expected))) return error.InvalidArchive;
            // Verify all stored bytes without retaining a second large value.
            try self.store().objectRange(reference, 0, &.{});
            if (value.result_artifact) |id| {
                var artifact = try self.record(state.Artifact, a, "artifact", id, value.id);
                defer artifact.deinit();
                if (!same(&artifact.value.value.digest, &reference.digest) or artifact.value.value.bytes != reference.bytes) return error.InvalidArchive;
                const schema_id = artifact.value.schema_id orelse return error.InvalidArchive;
                if (!same(artifact.value.media_type.bytes, "application/json") or !same(schema_id.bytes, if (value.outcome_kind == .completed) value.output_schema_id.bytes else value.failure_schema_id.bytes)) return error.InvalidArchive;
            } else if (expected.len > (@import("protocol.zig").Limits{}).inline_bytes) return error.InvalidArchive;
        }

        /// Call only after joining any in-flight worker. Closing is physical
        /// parking, never an implicit semantic cancellation or new dispatch.
        /// The caller must be the admitted root workspace occurrence. Adapters
        /// authenticate the original model call; this owner enforces custody.
        pub fn workspaceCommand(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, command: wc.Command) !wc.Reply {
            return self.workspaceCommandAuthorized(a, operation_id, task_id, .{ .command = command });
        }
        fn workspaceCommandAuthorized(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, admitted: workspace.Authorized) !wc.Reply {
            try self.allowed();
            const command = admitted.command;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const observation = self.workspaceExecute(a, operation_id, task_id, admitted) catch |err| {
                if (self.store().fenced or err == error.OutOfMemory or err == error.StorageUnavailable) return err;
                return workspaceRejection(a, err);
            };
            const rejected = observation == .object and observation.object.contains("error");
            const selected = if (!rejected and command == .context and command.context == .select)
                try values.fromJson(wc.Ref, a, observation.object.get("view") orelse return error.CorruptState)
            else
                null;
            const program = if (!rejected and command == .program and command.program == .build)
                try values.fromJson(wc.Ref, a, observation.object.get("program") orelse return error.CorruptState)
            else
                null;
            const evidence: ?wc.Ref = if (!rejected and observation == .object) blk: {
                const result = if (command == .context and command.context == .materialize) observation.object.get("value") else if (command == .work) observation.object.get("result") else null;
                break :blk if (result) |ref| try values.fromJson(wc.Ref, a, ref) else null;
            } else null;
            return .{ .disposition = if (rejected) .rejected else .observed, .observation_json = .{ .bytes = try json.canonical(a, observation) }, .selected_view = selected, .program = program, .evidence = evidence };
        }
        fn workspaceRejection(a: std.mem.Allocator, err: anyerror) !wc.Reply {
            var failure = json.object();
            try json.put(a, &failure, "error", json.string(@errorName(err)));
            return .{ .disposition = .rejected, .observation_json = .{ .bytes = try json.canonical(a, failure) } };
        }

        fn workspaceExecute(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, authorized: workspace.Authorized) !json.Value {
            const command = authorized.command;
            switch (command) {
                .program => |program| switch (program) {
                    .describe => |request| {
                        const description = switch (request.section) {
                            .source_records => try @import("source_records.zig").describe(a),
                            .values => try a.dupe(u8, "Runtime values use JSON arrays for products and sequences, {\"tag\":ordinal,\"value\":payload} for sums, {} for unit, booleans, exact decimal strings for 64-bit integers, UTF-8 strings for text, and base64url strings for bytes. Supply the actual program input schema reference. Program source uses the separately described Horos record transport."),
                            .bindings => try a.dupe(u8, "Pure source records require no environmental adapter. No effect request grants authority. Workspace observations and input ports do not restrict the controller's next action."),
                            .examples => try construction.example(a),
                            .components => blk: {
                                const ref = authorized.catalog orelse return error.UnavailableDescription;
                                var parent = try self.task(a, task_id);
                                defer parent.deinit();
                                try workspaceSnapshotAccess(parent.value, ref);
                                const bytes = try self.store().object(a, ref, null);
                                defer a.free(bytes);
                                break :blk try construction.describeComponents(a, bytes);
                            },
                        };
                        defer a.free(description);
                        return wp.page(a, description, request.page);
                    },
                    .build => |request| {
                        const text = switch (request.source) {
                            .json_text => |inline_text| try a.dupe(u8, inline_text.bytes),
                            .reference => |ref| try self.workspaceSource(a, task_id, ref),
                        };
                        defer a.free(text);
                        var diagnostic: construction.Diagnostic = .{};
                        const admitted = self.workspaceBuildKind(a, operation_id, task_id, text, request.source_kind, if (request.source_kind == .component_recipe) authorized.catalog else null, request.exposures.items, &diagnostic) catch |err| {
                            if (self.store().fenced or err == error.OutOfMemory) return err;
                            var failure = json.object();
                            try json.put(a, &failure, "error", json.string(@errorName(err)));
                            try json.put(a, &failure, "phase", json.string(@tagName(diagnostic.phase)));
                            try json.put(a, &failure, "function", try values.toJson(@TypeOf(diagnostic.source.function), a, diagnostic.source.function));
                            try json.put(a, &failure, "term", try values.toJson(@TypeOf(diagnostic.source.term), a, diagnostic.source.term));
                            try json.put(a, &failure, "value", try values.toJson(@TypeOf(diagnostic.source.value), a, diagnostic.source.value));
                            return failure;
                        };
                        return self.workspaceAdmissionObservation(a, task_id, admitted);
                    },
                    .inspect => |request| {
                        const id = try wp.identity(request.program, .program);
                        var program_value = try self.workspaceProgram(a, task_id, id);
                        defer program_value.deinit();
                        const observed = try self.workspaceProgramObservation(a, id, program_value.value.description);
                        const text = try json.canonical(a, observed);
                        defer a.free(text);
                        return wp.page(a, text, request.page);
                    },
                },
                .work => |work_command| switch (work_command) {
                    .start => |request| {
                        const program_id = try wp.identity(request.program, .program);
                        var program = try self.workspaceProgram(a, task_id, program_id);
                        defer program.deinit();
                        const artifact = program.value.description;
                        const schema = try self.store().object(a, artifact.input_schema, null);
                        defer a.free(schema);
                        var origin: ?state.Reference = null;
                        const input = switch (request.input) {
                            .inline_json => |inline_json| blk: {
                                if (!std.meta.eql(try wp.identity(inline_json.schema, .schema), artifact.input_schema.digest)) return error.SchemaMismatch;
                                const text = inline_json.json_text.bytes;
                                var parsed = try json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
                                defer parsed.deinit();
                                break :blk try @import("dynamic_values.zig").encode(a, schema, parsed.value);
                            },
                            .reference => |ref| blk: {
                                const value = try self.workspaceValueReference(a, task_id, ref);
                                if (!std.meta.eql(value.schema, artifact.input_schema)) return error.SchemaMismatch;
                                origin = value.artifact;
                                break :blk try self.store().object(a, value.value, null);
                            },
                        };
                        defer a.free(input);
                        return self.workspaceAdmissionObservation(a, task_id, try self.workspaceStartValue(a, operation_id, task_id, program_id, input, request.policy, origin));
                    },
                    .inspect => |request| {
                        var value = try self.workspaceWork(a, task_id, try wp.identity(request.work, .work));
                        defer value.deinit();
                        return self.workspaceWorkObservation(a, value.value);
                    },
                    .collect => |request| {
                        var result: json.Value = .{ .array = .init(a) };
                        for (request.works.items) |ref| {
                            var value = self.workspaceWork(a, task_id, try wp.identity(ref, .work)) catch |err| {
                                if (err != error.ArtifactUnavailable) return err;
                                var missing = json.object();
                                try json.put(a, &missing, "work", try values.toJson(wc.Ref, a, ref));
                                try json.put(a, &missing, "outcome", json.string("unavailable"));
                                try result.array.append(missing);
                                continue;
                            };
                            defer value.deinit();
                            try result.array.append(try self.workspaceWorkObservation(a, value.value));
                        }
                        return result;
                    },
                    .advance, .park, .delegate, .cancel => {
                        if (work_command == .delegate and work_command.delegate.interpretation != .none) return self.workspaceAdmissionObservation(a, task_id, try self.workspaceDelegate(a, operation_id, task_id, authorized));
                        const expected = switch (work_command) {
                            .advance, .park => |v| v,
                            .delegate => |v| v.expected,
                            .cancel => |v| v.expected,
                            else => unreachable,
                        };
                        const control: workspace.Command = switch (work_command) {
                            .advance => .advance,
                            .park => .park,
                            .delegate => |v| .{ .delegate = v.policy },
                            .cancel => |v| .{ .cancel = .{ .bytes = v.reason.bytes } },
                            else => unreachable,
                        };
                        const admitted = try self.workspaceControl(a, operation_id, task_id, try wp.identity(expected.work, .work), expected.execution_revision, expected.control_revision, control);
                        return self.workspaceAdmissionObservation(a, task_id, admitted);
                    },
                    .wait => |request| {
                        var parent = try self.task(a, task_id);
                        defer parent.deinit();
                        var result = json.object();
                        const ready = try self.workspaceWaitReady(a, parent.value, request);
                        try json.put(a, &result, "ready", .{ .bool = ready });
                        try json.put(a, &result, "interrupted", .{ .bool = parent.value.messages.items.len != 0 or parent.value.cancellation != null });
                        try json.put(a, &result, "event_watermark", try json.number(a, parent.value.event_high));
                        var selected: json.Value = .{ .array = .init(a) };
                        for (request.works.items) |ref| {
                            var work = try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
                            defer work.deinit();
                            try selected.array.append(try self.workspaceWorkObservation(a, work.value));
                        }
                        try json.put(a, &result, "works", selected);
                        return result;
                    },
                    .interact => |request| return self.workspaceAdmissionObservation(a, task_id, try self.workspaceInteract(a, operation_id, task_id, request)),
                },
                .context => |context| switch (context) {
                    .inspect => |request| {
                        var output: json.Value = .{ .array = .init(a) };
                        var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id", &.{.{ .blob = &task_id }});
                        defer query.deinit();
                        while (try query.step() == .row) {
                            const id = try query.bytes(0);
                            if (id.len != 32) return error.CorruptState;
                            try output.array.append(try values.toJson(wc.Ref, a, try wp.reference(a, .work, id[0..32].*)));
                        }
                        const text = try json.canonical(a, output);
                        defer a.free(text);
                        return wp.page(a, text, request.page);
                    },
                    .expand => |request| {
                        if (request.reference.kind == .port) {
                            const id = try wp.identity(request.reference, .port);
                            var port = try self.record(workspace.Port, a, "workspace_port", id, task_id);
                            defer port.deinit();
                            if (!std.meta.eql(port.value.id, id) or !std.meta.eql(port.value.task, task_id)) return error.CorruptState;
                            const observed = try self.workspacePortObservation(a, port.value);
                            const text = try json.canonical(a, observed);
                            defer a.free(text);
                            return wp.page(a, text, request.page);
                        }
                        if (request.reference.kind == .view) {
                            return self.workspaceViewObservation(a, task_id, try wp.identity(request.reference, .view), request.page);
                        }
                        if (request.reference.kind == .provenance or request.reference.kind == .schema) {
                            const reference = try self.workspaceOwnedDescriptor(a, task_id, request.reference);
                            const bytes = try self.store().object(a, reference, null);
                            defer a.free(bytes);
                            const projected = if (request.reference.kind == .schema) try wp.schema(a, bytes) else blk: {
                                var derivation = try contracts.decodeOwned(workspace.Derivation, a, bytes);
                                defer derivation.deinit();
                                break :blk try self.workspaceDerivationObservation(a, derivation.value);
                            };
                            const text = try json.canonical(a, projected);
                            defer a.free(text);
                            return wp.page(a, text, request.page);
                        }
                        if (request.reference.kind == .source) {
                            const text = try self.workspaceSource(a, task_id, request.reference);
                            defer a.free(text);
                            return wp.page(a, text, request.page);
                        }
                        const value = try self.workspaceValueReference(a, task_id, request.reference);
                        const schema = try self.store().object(a, value.schema, null);
                        defer a.free(schema);
                        const bytes = try self.store().object(a, value.value, null);
                        defer a.free(bytes);
                        var decoded = try @import("dynamic_values.zig").decode(a, schema, bytes);
                        defer decoded.deinit();
                        const text = try json.canonical(a, decoded.value);
                        defer a.free(text);
                        return wp.page(a, text, request.page);
                    },
                    .materialize, .select => return self.workspaceAdmissionObservation(a, task_id, try self.workspaceContextMutation(a, operation_id, task_id, context, authorized.snapshot, authorized.input)),
                },
            }
        }

        fn workspaceAdmissionObservation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, admitted: Admission) !json.Value {
            const receipt_value = admitted.receipt;
            if (!std.meta.eql(receipt_value.task, task_id)) return error.Denied;
            const bytes = try self.store().object(a, receipt_value.workspace_observation orelse return error.CorruptState, null);
            defer a.free(bytes);
            var observation = switch (receipt_value.workspace_kind orelse return error.CorruptState) {
                .program => blk: {
                    var artifact = try contracts.decodeOwned(workspace.ProgramArtifact, a, bytes);
                    defer artifact.deinit();
                    break :blk try self.workspaceProgramObservation(a, receipt_value.workspace.?, artifact.value);
                },
                .work => blk: {
                    var value = try contracts.decodeOwned(workspace.WorkObservation, a, bytes);
                    defer value.deinit();
                    if (!std.meta.eql(value.value.work.task, task_id)) return error.Denied;
                    break :blk try self.renderWorkspaceWorkObservation(a, value.value.work, value.value.occurrence);
                },
                .value => try self.workspaceValueObservation(a, task_id, receipt_value.workspace.?),
                .view => try self.workspaceViewObservation(a, task_id, receipt_value.workspace.?, .{}),
                else => return error.CorruptState,
            };
            try json.put(a, &observation, "replayed", .{ .bool = admitted.replayed });
            try json.put(a, &observation, "receipt_revision", try json.number(a, receipt_value.revision));
            return observation;
        }

        fn workspaceProgramObservation(self: *Self, a: std.mem.Allocator, id: state.Digest, artifact: workspace.ProgramArtifact) !json.Value {
            var result = json.object();
            try json.put(a, &result, "program", try values.toJson(wc.Ref, a, try wp.reference(a, .program, id)));
            try json.put(a, &result, "source", try values.toJson(wc.Ref, a, try wp.reference(a, .source, artifact.source.digest)));
            inline for (.{ "input", "result", "failure" }) |key| {
                const ref = @field(artifact, key ++ "_schema");
                const bytes = try self.store().object(a, ref, null);
                defer a.free(bytes);
                try json.put(a, &result, key ++ "_schema", try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)));
                try json.put(a, &result, key ++ "_descriptor", try wp.schema(a, bytes));
            }
            try json.put(a, &result, "construction_contract", json.string(try a.dupe(u8, artifact.construction_contract.bytes)));
            try json.put(a, &result, "source_kind", json.string(@tagName(artifact.source_kind)));
            var ports: json.Value = .{ .array = .init(a) };
            for (artifact.ports.items) |port| {
                var item = json.object();
                try json.put(a, &item, "identity", json.string(try a.dupe(u8, port.identity.bytes)));
                try json.put(a, &item, "class", json.string(@tagName(port.class)));
                inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                    const ref = @field(port, field);
                    try json.put(a, &item, field ++ "_schema", try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)));
                }
                try ports.array.append(item);
            }
            try json.put(a, &result, "ports", ports);
            return result;
        }

        fn workspaceWorkObservation(self: *Self, a: std.mem.Allocator, value: workspace.Work) !json.Value {
            var pending: ?contracts.Decoded(occurrence.Occurrence) = null;
            defer if (pending) |*saved| saved.deinit();
            if (value.current_occurrence) |id| pending = try self.record(occurrence.Occurrence, a, "occurrence", id, value.task);
            return self.renderWorkspaceWorkObservation(a, value, if (pending) |saved| saved.value else null);
        }

        fn renderWorkspaceWorkObservation(self: *Self, a: std.mem.Allocator, value: workspace.Work, pending: ?occurrence.Occurrence) !json.Value {
            var result = json.object();
            try json.put(a, &result, "work", try values.toJson(wc.Ref, a, try wp.reference(a, .work, value.id)));
            try json.put(a, &result, "program", try values.toJson(wc.Ref, a, try wp.reference(a, .program, value.program)));
            try json.put(a, &result, "execution_revision", try json.number(a, value.execution_revision));
            try json.put(a, &result, "control_revision", try json.number(a, value.control_revision));
            try json.put(a, &result, "event_watermark", try json.number(a, value.event_watermark));
            try json.put(a, &result, "outcome", json.string(@tagName(value.outcome_kind)));
            try json.put(a, &result, "schedule", json.string(@tagName(value.schedule)));
            try json.put(a, &result, "native_publication_nanoseconds", try json.number(a, value.native_publication_nanoseconds));
            try json.put(a, &result, "checkpoint_publications", try json.number(a, value.execution_revision));
            try json.put(a, &result, "control_port_reachable", .{ .bool = value.current_port != null });
            if (value.current_port) |ref| {
                const bytes = try self.store().object(a, ref, null);
                defer a.free(bytes);
                var port = try contracts.decodeOwned(workspace.Port, a, bytes);
                defer port.deinit();
                try json.put(a, &result, "port", try self.workspacePortObservation(a, port.value));
                const observed = pending orelse return error.CorruptState;
                if (!std.meta.eql(observed.id, port.value.occurrence)) return error.CorruptState;
                try json.put(a, &result, "port_accepts_command", .{ .bool = observed.state == .ready and (value.cancellation == null or value.cancellation_applied) });
            }
            const outcome_bytes = try self.store().object(a, value.outcome, null);
            defer a.free(outcome_bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, outcome_bytes);
            defer outcome.deinit();
            try json.put(a, &result, "cleanup_complete", .{ .bool = cleanupComplete(outcome.value) });
            if (outcome.value == .failed) {
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                const schema = try self.store().object(a, program.value.description.failure_schema, null);
                defer a.free(schema);
                var failure = try @import("dynamic_values.zig").decode(a, schema, outcome.value.failed.value);
                defer failure.deinit();
                const text = try json.canonical(a, failure.value);
                defer a.free(text);
                try json.put(a, &result, "failure_preview", try wp.page(a, text, .{}));
            }
            try json.put(a, &result, "input", try values.toJson(wc.Ref, a, try wp.reference(a, .value, (value.input_value orelse return error.CorruptState).digest)));
            if (value.current_occurrence) |id| {
                const observed = pending orelse return error.CorruptState;
                if (!std.meta.eql(observed.id, id)) return error.CorruptState;
                try json.put(a, &result, "delivery", json.string(@tagName(observed.state)));
                try json.put(a, &result, "occurrence", json.string(try a.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
            }
            if (value.origin_work) |id| try json.put(a, &result, "origin_work", try values.toJson(wc.Ref, a, try wp.reference(a, .work, id)));
            if (value.answer_value) |ref| try json.put(a, &result, "answer", try values.toJson(wc.Ref, a, try wp.reference(a, .value, ref.digest)));
            if (value.blocker) |blocker| try json.put(a, &result, "blocker", json.string(@tagName(blocker)));
            if (value.result) |ref| {
                try json.put(a, &result, "result", try values.toJson(wc.Ref, a, try wp.reference(a, .value, (value.result_value orelse return error.CorruptState).digest)));
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                const schema = try self.store().object(a, program.value.description.result_schema, null);
                defer a.free(schema);
                const bytes = try self.store().object(a, ref, null);
                defer a.free(bytes);
                var decoded = try @import("dynamic_values.zig").decode(a, schema, bytes);
                defer decoded.deinit();
                const text = try json.canonical(a, decoded.value);
                defer a.free(text);
                try json.put(a, &result, "result_preview", try wp.page(a, text, .{}));
            }
            return result;
        }

        fn workspacePortObservation(self: *Self, a: std.mem.Allocator, port: workspace.Port) !json.Value {
            var result = json.object();
            try json.put(a, &result, "reference", try values.toJson(wc.Ref, a, try wp.reference(a, .port, port.id)));
            try json.put(a, &result, "generation", try json.number(a, port.generation));
            try json.put(a, &result, "class", json.string(@tagName(port.interface.class)));
            try json.put(a, &result, "identity", json.string(try a.dupe(u8, port.interface.identity.bytes)));
            inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                const ref = @field(port.interface, field);
                const bytes = try self.store().object(a, ref, null);
                defer a.free(bytes);
                try json.put(a, &result, field ++ "_schema", try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)));
                try json.put(a, &result, field ++ "_descriptor", try wp.schema(a, bytes));
            }
            const schema = try self.store().object(a, port.interface.payload, null);
            defer a.free(schema);
            const payload = try self.store().object(a, port.payload, null);
            defer a.free(payload);
            var decoded = try @import("dynamic_values.zig").decode(a, schema, payload);
            defer decoded.deinit();
            const text = try json.canonical(a, decoded.value);
            defer a.free(text);
            try json.put(a, &result, "preview", try wp.page(a, text, .{}));
            return result;
        }

        pub fn workspaceInteract(self: *Self, allocator: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, interaction: @FieldType(wc.Work, "interact")) !Admission {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const Request = struct { kind: workspace.Operation = .interact, task: state.TaskId, interaction: @FieldType(wc.Work, "interact") };
            const request_digest = try operation(Request, a, .{ .task = task_id, .interaction = interaction });
            if (try self.replay(allocator, operation_id, request_digest)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            var saved = try self.workspaceWork(a, task_id, try wp.identity(interaction.expected.work, .work));
            defer saved.deinit();
            var value = saved.value;
            if (value.execution_revision != interaction.expected.execution_revision or value.control_revision != interaction.expected.control_revision) return error.StaleRevision;
            if (value.terminal() or (value.cancellation != null and !value.cancellation_applied) or
                ((parent.value.terminal() or parent.value.cancellation != null) and !value.cancellation_applied)) return error.InvalidState;
            const port_reference = value.current_port orelse return error.NoExposedPort;
            const port_bytes = try self.store().object(a, port_reference, null);
            defer a.free(port_bytes);
            var port = try contracts.decodeOwned(workspace.Port, a, port_bytes);
            defer port.deinit();
            if (!std.meta.eql(port.value.id, try wp.identity(interaction.port, .port)) or port.value.generation != interaction.generation or
                !std.meta.eql(port.value.task, task_id) or !std.meta.eql(port.value.work, value.id) or
                !std.meta.eql(value.current_occurrence, @as(?state.Digest, port.value.occurrence))) return error.StalePort;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", port.value.occurrence, task_id);
            defer pending.deinit();
            const binding: occurrence.Binding = .{ .id = port.value.occurrence, .task = task_id, .work = value.id, .request = port.value.request_identity };
            try occurrence.current(pending.value, binding);
            if (pending.value.state != .ready) return error.PortAlreadyAnswered;
            const argument_schema = try self.store().object(a, port.value.interface.argument, null);
            defer a.free(argument_schema);
            var input: ?[]u8 = null;
            defer if (input) |bytes| a.free(bytes);
            var origin: ?state.Reference = null;
            var command_json: json.Value = .null;
            switch (interaction.command) {
                .finish => {
                    if (port.value.interface.class != .alternative) return error.InvalidPortCommand;
                    const payload_schema = try self.store().object(a, port.value.interface.payload, null);
                    defer a.free(payload_schema);
                    const payload = try self.store().object(a, port.value.payload, null);
                    defer a.free(payload);
                    var observed = try @import("dynamic_values.zig").decode(a, payload_schema, payload);
                    defer observed.deinit();
                    const last = observed.value.array.items[1];
                    if (try values.fromJson(u32, a, last.object.get("tag").?) != 1) return error.NoBranchResult;
                    command_json = json.object();
                    try json.put(a, &command_json, "tag", try json.number(a, 1));
                    try json.put(a, &command_json, "value", json.object());
                },
                .resume_value => |supplied| {
                    input = switch (supplied) {
                        .inline_json => |inline_value| blk: {
                            if (!std.meta.eql(try wp.identity(inline_value.schema, .schema), port.value.interface.argument.digest)) return error.SchemaMismatch;
                            const text = inline_value.json_text.bytes;
                            var parsed = try json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
                            defer parsed.deinit();
                            break :blk try @import("dynamic_values.zig").encode(a, argument_schema, parsed.value);
                        },
                        .reference => |ref| blk: {
                            const selected = try self.workspaceValueReference(a, task_id, ref);
                            if (!std.meta.eql(selected.schema, port.value.interface.argument)) return error.SchemaMismatch;
                            origin = selected.artifact;
                            break :blk try self.store().object(a, selected.value, null);
                        },
                    };
                    var decoded = try @import("dynamic_values.zig").decode(a, argument_schema, input.?);
                    defer decoded.deinit();
                    // Own the JSON independently of the dynamic decoder arena.
                    const text = try json.canonical(a, decoded.value);
                    defer a.free(text);
                    const parsed = try json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
                    command_json = parsed.value;
                    if (port.value.interface.class == .alternative) {
                        command_json = json.object();
                        try json.put(a, &command_json, "tag", try json.number(a, 0));
                        try json.put(a, &command_json, "value", parsed.value);
                    }
                },
            }
            const command_schema = try self.store().object(a, port.value.interface.command, null);
            defer a.free(command_schema);
            const command_bytes = try @import("dynamic_values.zig").encode(a, command_schema, command_json);
            defer a.free(command_bytes);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.value.request, .value = command_bytes });
            defer a.free(bound);
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const dispatched = try occurrence.dispatch(pending.value, binding, attempt, false, false);
            const acquired = try occurrence.acquired(dispatched, binding, attempt, storage.digest(bound));
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try self.store().begin();
            defer self.store().rollback();
            if (input) |bytes| {
                origin = origin orelse try self.workspacePublishValue(a, task_id, port.value.interface.argument, try self.store().putObject(bytes), .{ .kind = .hypothesis, .sources = .{ .items = &.{} } });
                const inputs = try a.alloc(state.Reference, value.inputs.items.len + 1);
                @memcpy(inputs[0..value.inputs.items.len], value.inputs.items);
                inputs[value.inputs.items.len] = origin.?;
                value.inputs = .{ .items = inputs };
            }
            try self.store().createRecord(workspace.PortReply, "workspace_port_reply", attempt, task_id, .{ .id = attempt, .task = task_id, .port = port_reference, .reply = try self.store().putObject(bound), .input = origin, .command = if (interaction.command == .finish) .finish else .resume_value });
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.value.id, task_id, acquired);
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            value.schedule = .queued;
            try self.store().putRecord(workspace.Work, "workspace_work", value.id, task_id, value);
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request_digest, value.id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", value.id, task_id));
            self.subjectAppendAssumeCapacity(.{ .task = task_id, .work = value.id });
            return admitted;
        }

        fn workspaceSource(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref) ![]u8 {
            const id = try wp.identity(ref, .source);
            var acquired = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_value' ORDER BY id", &.{.{ .blob = &task_id }});
            defer acquired.deinit();
            while (try acquired.step() == .row) {
                const key = try acquired.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var record_value = try self.record(workspace.Value, a, "workspace_value", key[0..32].*, task_id);
                defer record_value.deinit();
                if (!std.meta.eql(record_value.value.description.provenance.digest, id)) continue;
                _ = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, record_value.value.artifact.digest));
                if (record_value.value.derivation.frozen_input != null) {
                    const checked = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, record_value.value.artifact.digest));
                    const schema = try self.store().object(a, checked.schema, null);
                    defer a.free(schema);
                    const value = try self.store().object(a, checked.value, null);
                    defer a.free(value);
                    var decoded = try @import("dynamic_values.zig").decode(a, schema, value);
                    defer decoded.deinit();
                    return json.canonical(a, decoded.value);
                }
                const origin = record_value.value.derivation.acquisition orelse continue;
                const bytes = try self.store().object(a, origin.snapshot, null);
                defer a.free(bytes);
                var source = try @import("repository.zig").Snapshot.openBorrowed(a, bytes);
                defer source.deinit();
                const file = source.get(origin.path.bytes) orelse return error.CorruptState;
                if (!std.unicode.utf8ValidateSlice(file.contents.bytes)) return json.canonical(a, try values.toJson(contracts.Bytes(null), a, file.contents));
                return a.dupe(u8, file.contents.bytes);
            }
            var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_program' ORDER BY id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const key = try query.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var program = try self.record(workspace.Program, a, "workspace_program", key[0..32].*, task_id);
                defer program.deinit();
                if (std.meta.eql(program.value.description.source.digest, id)) return self.store().object(a, program.value.description.source, null);
            }
            return error.ArtifactUnavailable;
        }
        const WorkspaceValueReference = struct { artifact: state.Reference, value: state.Reference, schema: state.Reference, provenance: state.Reference };
        fn workspaceOwnedDescriptor(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref) !state.Reference {
            if (ref.kind != .schema and ref.kind != .provenance) return error.InvalidReference;
            const id = try wp.identity(ref, ref.kind);
            var query = try self.store().database.prepare("SELECT id,kind FROM records WHERE task=? AND kind IN ('workspace_program','workspace_value') ORDER BY id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const key = try query.bytes(0);
                if (key.len != 32) return error.CorruptState;
                if (same(try query.bytes(1), "workspace_value")) {
                    var value = try self.record(workspace.Value, a, "workspace_value", key[0..32].*, task_id);
                    defer value.deinit();
                    const checked = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, value.value.artifact.digest));
                    const candidate = if (ref.kind == .schema) checked.schema else checked.provenance;
                    if (std.meta.eql(candidate.digest, id)) return candidate;
                } else if (ref.kind == .schema) {
                    var saved = try self.record(workspace.Program, a, "workspace_program", key[0..32].*, task_id);
                    defer saved.deinit();
                    var program = try self.workspaceProgram(a, task_id, saved.value.artifact.digest);
                    defer program.deinit();
                    inline for (.{ "input_schema", "result_schema", "failure_schema" }) |field| {
                        const candidate = @field(program.value.description, field);
                        if (std.meta.eql(candidate.digest, id)) return candidate;
                    }
                    for (program.value.description.ports.items) |port| inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                        const candidate = @field(port, field);
                        if (std.meta.eql(candidate.digest, id)) return candidate;
                    };
                }
            }
            return error.ArtifactUnavailable;
        }

        fn workspaceDerivationObservation(self: *Self, a: std.mem.Allocator, derivation: workspace.Derivation) !json.Value {
            _ = self;
            var result = json.object();
            try json.put(a, &result, "kind", json.string(@tagName(derivation.kind)));
            var sources: json.Value = .{ .array = .init(a) };
            for (derivation.sources.items) |ref| try sources.array.append(try values.toJson(wc.Ref, a, try wp.reference(a, .value, ref.digest)));
            try json.put(a, &result, "sources", sources);
            try json.put(a, &result, "coverage", json.string("No source-universe completeness is asserted by this derivation."));
            if (derivation.program) |ref| try json.put(a, &result, "program", try values.toJson(wc.Ref, a, try wp.reference(a, .program, ref.digest)));
            if (derivation.work) |id| try json.put(a, &result, "work", try values.toJson(wc.Ref, a, try wp.reference(a, .work, id)));
            if (derivation.acquisition) |origin| {
                try json.put(a, &result, "acquisition", try values.toJson(workspace.SnapshotRange, a, origin));
                try json.put(a, &result, "complete_file", .{ .bool = origin.start == 0 and origin.end == origin.file_bytes });
            }
            if (derivation.frozen_input) |ref| try json.put(a, &result, "frozen_input", try values.toJson(state.Reference, a, ref));
            return result;
        }

        fn workspaceValueObservation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest) !json.Value {
            const ref = try wp.reference(a, .value, id);
            const value = try self.workspaceValueReference(a, task_id, ref);
            const schema = try self.store().object(a, value.schema, null);
            defer a.free(schema);
            const bytes = try self.store().object(a, value.value, null);
            defer a.free(bytes);
            var decoded = try @import("dynamic_values.zig").decode(a, schema, bytes);
            defer decoded.deinit();
            const text = try json.canonical(a, decoded.value);
            defer a.free(text);
            var result = json.object();
            try json.put(a, &result, "value", try values.toJson(wc.Ref, a, ref));
            try json.put(a, &result, "schema", try values.toJson(wc.Ref, a, try wp.reference(a, .schema, value.schema.digest)));
            try json.put(a, &result, "provenance", try values.toJson(wc.Ref, a, try wp.reference(a, .provenance, value.provenance.digest)));
            try json.put(a, &result, "preview", try wp.page(a, text, .{}));
            const provenance = try self.store().object(a, value.provenance, null);
            defer a.free(provenance);
            var derivation = try contracts.decodeOwned(workspace.Derivation, a, provenance);
            defer derivation.deinit();
            try json.put(a, &result, "derivation", try self.workspaceDerivationObservation(a, derivation.value));
            if (derivation.value.acquisition != null or derivation.value.frozen_input != null) try json.put(a, &result, "source", try values.toJson(wc.Ref, a, try wp.reference(a, .source, value.provenance.digest)));
            return result;
        }

        fn workspaceViewObservation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest, page: wc.Page) !json.Value {
            const key = try workspaceContentCustody(a, task_id, id);
            var saved = try self.record(workspace.View, a, "workspace_view", key, task_id);
            defer saved.deinit();
            const bytes = try contracts.encodeOwned(workspace.ViewArtifact, a, saved.value.description);
            defer a.free(bytes);
            if (saved.value.description.version != 1 or !std.meta.eql(saved.value.task, task_id) or !std.meta.eql(saved.value.id, key) or !std.meta.eql(saved.value.artifact.digest, id) or !std.meta.eql(storage.digest(bytes), id) or bytes.len != saved.value.artifact.bytes) return error.CorruptState;
            var result = json.object();
            try json.put(a, &result, "view", try values.toJson(wc.Ref, a, try wp.reference(a, .view, id)));
            try json.put(a, &result, "coverage", json.string("selected_values_only"));
            var selected: json.Value = .{ .array = .init(a) };
            for (saved.value.description.values.items) |ref| {
                const value = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, ref.digest));
                if (!std.meta.eql(value.artifact, ref)) return error.CorruptState;
                try selected.array.append(try self.workspaceValueObservation(a, task_id, ref.digest));
            }
            const text = try json.canonical(a, selected);
            defer a.free(text);
            try json.put(a, &result, "selection", try wp.page(a, text, page));
            try json.put(a, &result, "value_count", try json.number(a, saved.value.description.values.items.len));
            return result;
        }

        fn workspaceContextMutation(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, command: wc.Context, snapshot: ?state.Reference, input: ?state.Reference) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const Request = struct { task: state.TaskId, command: wc.Context, snapshot: ?state.Reference, input: ?state.Reference };
            const request = try operation(Request, a, .{ .task = task_id, .command = command, .snapshot = snapshot, .input = input });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            try self.store().begin();
            defer self.store().rollback();
            const artifact: state.Reference, const kind: @FieldType(wc.Ref, "kind") = switch (command) {
                .materialize => |materialize| blk: {
                    if (materialize.input == .authorized_input) {
                        if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
                        const ref = input orelse return error.UnauthorizedInput;
                        try workspaceSnapshotAccess(parent.value, ref);
                        const bytes = try self.store().object(a, ref, null);
                        defer a.free(bytes);
                        var decoded = try contracts.decodeOwned(contracts.tool_construction.Input, a, bytes);
                        defer decoded.deinit();
                        var descriptor = try data.schema.decode(a, decoded.value.schema.bytes);
                        defer descriptor.deinit();
                        try data.schema.validateValue(a, descriptor.descriptor, decoded.value.value.bytes);
                        const value = try self.workspacePublishValue(a, task_id, try self.store().putObject(decoded.value.schema.bytes), try self.store().putObject(decoded.value.value.bytes), .{ .kind = .acquisition, .sources = .{ .items = &.{} }, .frozen_input = ref });
                        break :blk .{ value, .value };
                    }
                    if (materialize.input == .snapshot) {
                        const selection = materialize.input.snapshot;
                        if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
                        const source = snapshot orelse return error.Denied;
                        const result = try self.workspaceMaterializeSnapshot(a, parent.value, source, selection);
                        break :blk .{ result, .value };
                    }
                    var sources: std.ArrayList(state.Reference) = .empty;
                    defer sources.deinit(a);
                    for (materialize.sources.items) |ref| try sources.append(a, (try self.workspaceValueReference(a, task_id, ref)).artifact);
                    const schema: state.Reference, const payload: state.Reference = switch (materialize.input.value) {
                        .reference => |ref| inner: {
                            const origin = try self.workspaceValueReference(a, task_id, ref);
                            if (sources.items.len == 0) break :blk .{ origin.artifact, .value };
                            try sources.append(a, origin.artifact);
                            break :inner .{ origin.schema, origin.value };
                        },
                        .inline_json => |inline_value| inner: {
                            const schema = try self.workspaceOwnedDescriptor(a, task_id, inline_value.schema);
                            const descriptor = try self.store().object(a, schema, null);
                            defer a.free(descriptor);
                            const text = inline_value.json_text.bytes;
                            var parsed = try json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
                            defer parsed.deinit();
                            const bytes = try @import("dynamic_values.zig").encode(a, descriptor, parsed.value);
                            defer a.free(bytes);
                            break :inner .{ schema, try self.store().putObject(bytes) };
                        },
                    };
                    break :blk .{ try self.workspacePublishValue(a, task_id, schema, payload, .{ .kind = if (sources.items.len == 0) .hypothesis else .judgment, .sources = .{ .items = sources.items } }), .value };
                },
                .select => |selection| blk: {
                    const references = try a.alloc(state.Reference, selection.values.items.len);
                    defer a.free(references);
                    for (selection.values.items, references) |ref, *out| out.* = (try self.workspaceValueReference(a, task_id, ref)).artifact;
                    const view: workspace.ViewArtifact = .{ .values = .{ .items = references } };
                    const bytes = try contracts.encodeOwned(workspace.ViewArtifact, a, view);
                    defer a.free(bytes);
                    const ref = try self.store().putObject(bytes);
                    const key = try workspaceContentCustody(a, task_id, ref.digest);
                    if (try self.store().recordBytes(a, "workspace_view", key, task_id)) |prior| {
                        defer a.free(prior);
                        const expected = try contracts.encodeOwned(workspace.View, a, .{ .id = key, .task = task_id, .artifact = ref, .description = view });
                        defer a.free(expected);
                        if (!same(prior, expected)) return error.CorruptState;
                    } else try self.store().createRecord(workspace.View, "workspace_view", key, task_id, .{ .id = key, .task = task_id, .artifact = ref, .description = view });
                    break :blk .{ ref, .view };
                },
                else => return error.InvalidState,
            };
            return self.workspaceCommit(a, parent.value, operation_id, request, artifact.digest, kind, artifact);
        }

        fn workspaceValueReference(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref) !WorkspaceValueReference {
            const id = try wp.identity(ref, .value);
            const key = try workspaceContentCustody(a, task_id, id);
            var saved = try self.record(workspace.Value, a, "workspace_value", key, task_id);
            defer saved.deinit();
            if (!std.meta.eql(saved.value.task, task_id) or !std.meta.eql(saved.value.id, key) or !std.meta.eql(saved.value.artifact.digest, id)) return error.CorruptState;
            const encoded = try contracts.encodeOwned(workspace.ValueArtifact, a, saved.value.description);
            defer a.free(encoded);
            const provenance = try contracts.encodeOwned(workspace.Derivation, a, saved.value.derivation);
            defer a.free(provenance);
            if (saved.value.description.version != 1 or !std.meta.eql(storage.digest(encoded), id) or encoded.len != saved.value.artifact.bytes or !std.meta.eql(storage.digest(provenance), saved.value.description.provenance.digest)) return error.CorruptState;
            if (saved.value.derivation.acquisition) |origin| {
                if (saved.value.derivation.kind != .acquisition or saved.value.derivation.sources.items.len != 0 or saved.value.derivation.program != null or saved.value.derivation.work != null or saved.value.derivation.frozen_input != null) return error.CorruptState;
                var parent = try self.task(a, task_id);
                defer parent.deinit();
                try workspaceSnapshotAccess(parent.value, origin.snapshot);
                const derived = try self.workspaceSnapshotBytes(a, origin);
                defer a.free(derived.schema);
                defer a.free(derived.value);
                if (!std.meta.eql(saved.value.description.schema, state.Reference{ .digest = storage.digest(derived.schema), .bytes = derived.schema.len }) or !std.meta.eql(saved.value.description.value, state.Reference{ .digest = storage.digest(derived.value), .bytes = derived.value.len })) return error.CorruptState;
            } else if (saved.value.derivation.frozen_input) |frozen_ref| {
                if (saved.value.derivation.kind != .acquisition or saved.value.derivation.sources.items.len != 0 or saved.value.derivation.program != null or saved.value.derivation.work != null) return error.CorruptState;
                var parent = try self.task(a, task_id);
                defer parent.deinit();
                try workspaceSnapshotAccess(parent.value, frozen_ref);
                const bytes = try self.store().object(a, frozen_ref, null);
                defer a.free(bytes);
                var input_value = try contracts.decodeOwned(contracts.tool_construction.Input, a, bytes);
                defer input_value.deinit();
                if (!std.meta.eql(saved.value.description.schema, state.Reference{ .digest = storage.digest(input_value.value.schema.bytes), .bytes = input_value.value.schema.bytes.len }) or !std.meta.eql(saved.value.description.value, state.Reference{ .digest = storage.digest(input_value.value.value.bytes), .bytes = input_value.value.value.bytes.len })) return error.CorruptState;
                var descriptor = try data.schema.decode(a, input_value.value.schema.bytes);
                defer descriptor.deinit();
                try data.schema.validateValue(a, descriptor.descriptor, input_value.value.value.bytes);
            } else if (saved.value.derivation.kind == .acquisition) return error.CorruptState;
            if (saved.value.derivation.delegation != null or saved.value.derivation.capture != null) try self.validateDelegatedValue(a, task_id, saved.value);
            return .{ .artifact = saved.value.artifact, .schema = saved.value.description.schema, .value = saved.value.description.value, .provenance = saved.value.description.provenance };
        }

        fn validateDelegatedValue(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, value: workspace.Value) !void {
            const origin = value.derivation;
            if (origin.kind != .judgment or origin.program != null or origin.acquisition != null or origin.frozen_input != null or origin.delegation == null or origin.capture == null) return error.InvalidArchive;
            var work = try self.workspaceWork(a, task_id, origin.work orelse return error.InvalidArchive);
            defer work.deinit();
            if (work.value.outcome_kind != .completed or !std.meta.eql(work.value.delegation, origin.delegation) or !std.meta.eql(work.value.answer_value, value.artifact)) return error.InvalidArchive;
            var delegation = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, origin.delegation.?, null));
            defer delegation.deinit();
            if (delegation.value.selection != .model or !std.meta.eql(delegation.value.instrument, work.value.id) or !std.meta.eql(delegation.value.task, task_id) or origin.sources.items.len != delegation.value.inputs.items.len) return error.InvalidArchive;
            for (origin.sources.items, delegation.value.inputs.items) |left, right| if (!std.meta.eql(left, right)) return error.InvalidArchive;
            var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, delegation.value.port, null));
            defer port.deinit();
            var result = try contracts.decodeOwned(instrument.Output, a, try self.store().object(a, work.value.result orelse return error.InvalidArchive, null));
            defer result.deinit();
            if (result.value != .answer or !std.meta.eql(value.description.schema, port.value.interface.argument) or !std.meta.eql(value.description.value, state.Reference{ .digest = storage.digest(result.value.answer.bytes), .bytes = result.value.answer.bytes.len })) return error.InvalidArchive;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", work.value.instrument_occurrence orelse return error.InvalidArchive, task_id);
            defer pending.deinit();
            if (pending.value.state != .admitted or pending.value.state.admitted != .reply) return error.InvalidArchive;
            var capture_value = try self.record(state.Capture, a, "capture", pending.value.state.admitted.reply.attempt, task_id);
            defer capture_value.deinit();
            if (!std.meta.eql(capture_value.value.response, origin.capture)) return error.InvalidArchive;
        }

        fn workspaceSnapshotAccess(parent: state.Task, snapshot: state.Reference) !void {
            for (parent.resources.items) |ref| if (std.meta.eql(ref, snapshot)) return;
            return error.Denied;
        }
        fn workspaceSnapshotBytes(self: *Self, a: std.mem.Allocator, origin: workspace.SnapshotRange) !struct { schema: []u8, value: []u8 } {
            const bytes = try self.store().object(a, origin.snapshot, null);
            defer a.free(bytes);
            var source = try @import("repository.zig").Snapshot.openBorrowed(a, bytes);
            defer source.deinit();
            const file = source.get(origin.path.bytes) orelse return error.CorruptState;
            if (!std.meta.eql(file.sha256, origin.file_digest) or origin.start > origin.end or origin.end > file.contents.bytes.len or origin.file_bytes != file.contents.bytes.len or origin.excluded_entries != source.decoded.value.excluded_entries) return error.CorruptState;
            const part = file.contents.bytes[@intCast(origin.start)..@intCast(origin.end)];
            if (std.unicode.utf8ValidateSlice(part)) return .{ .schema = try values.schemaBytes(contracts.Utf8, a), .value = try contracts.encodeOwned(contracts.Utf8, a, .{ .bytes = part }) };
            return .{ .schema = try values.schemaBytes(contracts.Bytes(null), a), .value = try contracts.encodeOwned(contracts.Bytes(null), a, .{ .bytes = part }) };
        }
        fn workspaceMaterializeSnapshot(self: *Self, a: std.mem.Allocator, parent: state.Task, snapshot: state.Reference, selection: anytype) !state.Reference {
            try workspaceSnapshotAccess(parent, snapshot);
            const bytes = try self.store().object(a, snapshot, null);
            defer a.free(bytes);
            var source = try @import("repository.zig").Snapshot.openBorrowed(a, bytes);
            defer source.deinit();
            const file = source.get(selection.path.bytes) orelse return error.SourceMissing;
            if (selection.offset > file.contents.bytes.len) return error.InvalidRange;
            const origin: workspace.SnapshotRange = .{
                .snapshot = snapshot,
                .path = selection.path,
                .file_digest = file.sha256,
                .start = selection.offset,
                .end = selection.offset + @min(selection.maximum, file.contents.bytes.len - selection.offset),
                .file_bytes = file.contents.bytes.len,
                .excluded_entries = source.decoded.value.excluded_entries,
            };
            const derived = try self.workspaceSnapshotBytes(a, origin);
            defer a.free(derived.schema);
            defer a.free(derived.value);
            return self.workspacePublishValue(a, parent.id, try self.store().putObject(derived.schema), try self.store().putObject(derived.value), .{ .kind = .acquisition, .sources = .{ .items = &.{} }, .acquisition = origin });
        }

        fn workspacePublishValue(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, schema: state.Reference, value: state.Reference, derivation: workspace.Derivation) !state.Reference {
            const provenance_bytes = try contracts.encodeOwned(workspace.Derivation, a, derivation);
            defer a.free(provenance_bytes);
            const artifact: workspace.ValueArtifact = .{ .schema = schema, .value = value, .provenance = try self.store().putObject(provenance_bytes) };
            const bytes = try contracts.encodeOwned(workspace.ValueArtifact, a, artifact);
            defer a.free(bytes);
            const ref = try self.store().putObject(bytes);
            const key = try workspaceContentCustody(a, task_id, ref.digest);
            const record_value: workspace.Value = .{ .id = key, .task = task_id, .artifact = ref, .description = artifact, .derivation = derivation };
            if (try self.store().recordBytes(a, "workspace_value", key, task_id)) |prior| {
                defer a.free(prior);
                const expected = try contracts.encodeOwned(workspace.Value, a, record_value);
                defer a.free(expected);
                if (!same(prior, expected)) return error.CorruptState;
            } else try self.store().createRecord(workspace.Value, "workspace_value", key, task_id, record_value);
            return ref;
        }

        fn authorizeWorkspace(self: *Self, a: std.mem.Allocator, initial: state.Task, entry: registry.Entry, payload: []const u8) ![]u8 {
            return self.store().project([]u8, a, self.handlers, self.projectionBinding(initial), struct {
                authorize: *const fn (registry.ProjectionContext, []const u8) anyerror![]u8,
                payload: []const u8,
                pub fn run(this: @This(), ctx: registry.ProjectionContext) ![]u8 {
                    return this.authorize(ctx, this.payload);
                }
            }{ .authorize = entry.declaration.workspace.?, .payload = payload });
        }

        fn dispatchWorkspace(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, entry: registry.Entry, payload: []const u8) !Step {
            const authorized = self.authorizeWorkspace(a, initial, entry, payload) catch |err| {
                if (self.store().fenced or err == error.OutOfMemory) return err;
                return self.settleWorkspaceReply(a, initial, pending, try workspaceRejection(a, err));
            };
            defer a.free(authorized);
            var command = try contracts.decodeOwned(workspace.Authorized, a, authorized);
            defer command.deinit();
            const operation_id = std.fmt.bytesToHex(pending.id, .lower);
            if (command.value.command == .program and command.value.command.program == .build) {
                if (self.work != null) return .idle;
                const prepared = self.workspacePrepareBuild(a, initial, command.value) catch |err| {
                    if (self.store().fenced or err == error.OutOfMemory) return err;
                    return self.settleWorkspaceReply(a, initial, pending, try workspaceRejection(a, err));
                };
                defer a.free(prepared);
                const request_bytes = try self.store().object(a, pending.request_object, null);
                defer a.free(request_bytes);
                return self.dispatchAcquisition(a, initial, pending, entry, request_bytes, prepared, .workspace_build);
            }
            if (command.value.command == .work and command.value.command.work == .wait) {
                const selection = command.value.command.work.wait;
                const ready = self.workspaceWaitReady(a, initial, selection) catch |err| return self.settleWorkspaceReply(a, initial, pending, try workspaceRejection(a, err));
                if (!ready) {
                    if (try self.store().recordBytes(a, "workspace_wait", pending.id, initial.id)) |bytes| {
                        defer a.free(bytes);
                        var saved = try contracts.decodeOwned(workspace.Wait, a, bytes);
                        defer saved.deinit();
                        if (!std.meta.eql(saved.value.request, pending.request_object)) return error.CorruptState;
                    } else {
                        var value = initial;
                        value.revision = try std.math.add(u64, value.revision, 1);
                        value.schedule = .parked;
                        try self.store().begin();
                        defer self.store().rollback();
                        try self.store().createRecord(workspace.Wait, "workspace_wait", pending.id, initial.id, .{ .id = pending.id, .task = initial.id, .request = pending.request_object, .selection = selection });
                        try self.persist(a, value, initial.revision, "workspace.wait", .preserve);
                    }
                    self.runnableRemove(initial.id);
                    try self.retire(a);
                    return .waiting;
                }
            }
            const observation = try self.workspaceCommandAuthorized(a, &operation_id, initial.id, command.value);
            return self.settleWorkspaceReply(a, initial, pending, observation);
        }
        fn workspacePrepareBuild(self: *Self, a: std.mem.Allocator, parent: state.Task, authorized: workspace.Authorized) ![]u8 {
            const build = authorized.command.program.build;
            const source = switch (build.source) {
                .json_text => |text| try a.dupe(u8, text.bytes),
                .reference => |ref| try self.workspaceSource(a, parent.id, ref),
            };
            defer a.free(source);
            var catalog: ?[]u8 = null;
            defer if (catalog) |bytes| a.free(bytes);
            if (build.source_kind == .component_recipe) {
                const ref = authorized.catalog orelse return error.UnavailableCatalog;
                try workspaceSnapshotAccess(parent, ref);
                catalog = try self.store().object(a, ref, null);
            }
            return contracts.encodeOwned(build_job.Input, a, .{ .source = .{ .bytes = source }, .kind = build.source_kind, .catalog = if (catalog) |bytes| .{ .bytes = bytes } else null, .exposures = build.exposures });
        }

        fn workspaceBuildReply(self: *Self, a: std.mem.Allocator, program: ?state.Reference, output: build_job.Output) !wc.Reply {
            var observation = json.object();
            if (output == .rejected) {
                try json.put(a, &observation, "compiler_nanoseconds", try json.number(a, output.rejected.compiler_nanoseconds));
                const failure = output.rejected;
                try json.put(a, &observation, "error", json.string(try a.dupe(u8, failure.code.bytes)));
                try json.put(a, &observation, "phase", json.string(try a.dupe(u8, failure.phase.bytes)));
                try json.put(a, &observation, "function", try values.toJson(?u64, a, failure.function));
                try json.put(a, &observation, "term", try values.toJson(?u64, a, failure.term));
                try json.put(a, &observation, "value", try values.toJson(?u64, a, failure.value));
                return .{ .disposition = .rejected, .observation_json = .{ .bytes = try json.canonical(a, observation) } };
            }
            const saved = program orelse return error.CorruptState;
            var artifact = try contracts.decodeOwned(workspace.ProgramArtifact, a, try self.store().object(a, saved, null));
            defer artifact.deinit();
            observation = try self.workspaceProgramObservation(a, saved.digest, artifact.value);
            try json.put(a, &observation, "compiler_nanoseconds", try json.number(a, output.compiled.compiler_nanoseconds));
            return .{ .disposition = .admitted, .program = try wp.reference(a, .program, saved.digest), .observation_json = .{ .bytes = try json.canonical(a, observation) } };
        }

        fn interpretWorkspaceBuild(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, attempt: state.Attempt, raw: state.Capture) !Step {
            const rendered = try self.store().object(a, raw.request, null);
            defer a.free(rendered);
            var input = try contracts.decodeOwned(build_job.Input, a, rendered);
            defer input.deinit();
            const response = try self.store().object(a, raw.response.?, null);
            defer a.free(response);
            var output = try contracts.decodeOwned(build_job.Output, a, response);
            defer output.deinit();
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try self.store().begin();
            defer self.store().rollback();
            const program: ?state.Reference = if (output.value == .compiled) try self.workspaceStoreProgram(a, initial.id, input.value.source.bytes, @fromBackingInt(@intCast(@backingInt(input.value.kind))), if (input.value.catalog) |bytes| .{ .digest = storage.digest(bytes.bytes), .bytes = bytes.bytes.len } else null, input.value.exposures.items, output.value.compiled) else null;
            const reply = try self.workspaceBuildReply(a, program, output.value);
            const payload = try contracts.encodeOwned(wc.Reply, a, reply);
            defer a.free(payload);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = payload });
            defer a.free(bound);
            const next = try occurrence.acquired(pending, .{ .id = pending.id, .task = initial.id, .request = pending.request }, attempt.id, storage.digest(bound));
            var projected = raw;
            projected.projection = .{ .reply = try self.store().putObject(bound), .objects = .{ .items = &.{} }, .output_tokens = null };
            try self.store().putRecord(state.Capture, "capture", attempt.id, initial.id, projected);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, initial.id, next);
            if (program) |saved| {
                const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{std.fmt.bytesToHex(saved.digest, .lower)});
                defer a.free(event_data);
                try self.event(&parent, .workspace_progress, event_data);
            }
            try self.persist(a, parent, initial.revision, "workspace.build", .preserve);
            if (program) |saved| try self.checked_workspace_programs.put(self.allocator, saved.digest, self.store().integrity_epoch);
            return .progressed;
        }

        fn workspaceWaitReady(self: *Self, a: std.mem.Allocator, parent: state.Task, selection: @FieldType(wc.Work, "wait")) !bool {
            var ready = parent.messages.items.len != 0 or parent.cancellation != null;
            for (selection.works.items) |ref| {
                var work = try self.workspaceWork(a, parent.id, try wp.identity(ref, .work));
                defer work.deinit();
                ready = ready or work.value.event_watermark > selection.after or work.value.terminal();
            }
            return ready;
        }
        fn workspaceWaitWakeNeeded(self: *Self, a: std.mem.Allocator, parent: state.Task, ownership: Ownership) !bool {
            if (parent.terminal()) return false;
            var owned = ownership == .acquire;
            for (self.owned.items) |id| owned = owned or std.meta.eql(id, parent.id);
            if (!owned) return false;
            for (self.runnable.items) |subject| if (subject.work == null and std.meta.eql(subject.task, parent.id)) return false;
            const id = parent.current_occurrence orelse return false;
            const bytes = (try self.store().recordBytes(a, "workspace_wait", id, parent.id)) orelse return false;
            defer a.free(bytes);
            var waiting = try contracts.decodeOwned(workspace.Wait, a, bytes);
            defer waiting.deinit();
            return self.workspaceWaitReady(a, parent, waiting.value.selection);
        }

        fn settleWorkspaceReply(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, observation: wc.Reply) !Step {
            const reply = try contracts.encodeOwned(wc.Reply, a, observation);
            defer a.free(reply);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = reply });
            defer a.free(bound);
            // Workspace mutation may have advanced only the parent's control
            // journal. Its root occurrence and checkpoint remain unchanged.
            var fresh = try self.task(a, initial.id);
            defer fresh.deinit();
            var parent = fresh.value;
            if (!std.meta.eql(parent.current_occurrence, initial.current_occurrence)) return error.StaleOccurrence;
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const binding: occurrence.Binding = .{ .id = pending.id, .task = initial.id, .request = pending.request };
            const dispatched = try occurrence.dispatch(pending, binding, attempt, parent.cancellation != null, false);
            const acquired = try occurrence.acquired(dispatched, binding, attempt, storage.digest(bound));
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(bound);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, initial.id, acquired);
            try self.persist(a, parent, fresh.value.revision, "workspace.reply", .preserve);
            return .progressed;
        }

        pub fn workspaceProgram(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, program_id: state.Digest) !contracts.Decoded(workspace.Program) {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const custody_id = try workspaceContentCustody(a, task_id, program_id);
            const bytes = (try self.store().recordBytes(a, "workspace_program", custody_id, task_id)) orelse return error.ArtifactUnavailable;
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(workspace.Program, a, bytes);
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.id, custody_id) or !std.meta.eql(saved.value.artifact.digest, program_id) or !std.meta.eql(saved.value.task, task_id)) return error.CorruptState;
            const encoded = try contracts.encodeOwned(workspace.ProgramArtifact, a, saved.value.description);
            defer a.free(encoded);
            if (!std.meta.eql(storage.digest(encoded), saved.value.artifact.digest) or encoded.len != saved.value.artifact.bytes) return error.CorruptState;
            if (saved.value.description.catalog) |catalog| try workspaceSnapshotAccess(parent.value, catalog);
            try self.validateWorkspaceProgram(a, saved.value);
            return saved;
        }

        fn workspaceContentCustody(a: std.mem.Allocator, task_id: state.TaskId, program_id: state.Digest) !state.Digest {
            return workspace.custodyId(a, task_id, program_id);
        }

        fn validateWorkspaceProgram(self: *Self, a: std.mem.Allocator, saved: workspace.Program) !void {
            if (self.checked_workspace_programs.get(saved.artifact.digest)) |epoch| if (epoch == self.store().integrity_epoch) return;
            const artifact = saved.description;
            const contract = switch (artifact.source_kind) {
                .source_records => @import("source_records.zig").identity,
                .component_recipe => construction.component_identity,
                .instrument_model, .instrument_snapshot => instrument.identity,
            };
            if (artifact.version != 1 or !same(artifact.construction_contract.bytes, contract) or
                !std.meta.eql(artifact.authoring_identity, storage.digest(@import("native_options").horos_identity))) return error.IncompatibleProfile;
            const source = try self.store().object(a, artifact.source, null);
            defer a.free(source);
            var diagnostic: construction.Diagnostic = .{};
            var built = try self.workspaceCompile(a, source, artifact.source_kind, artifact.catalog, artifact.exposures.items, &diagnostic);
            defer built.deinit();
            inline for (.{ .{ artifact.image, built.image }, .{ artifact.input_schema, built.interface.input.bytes }, .{ artifact.result_schema, built.interface.output.bytes }, .{ artifact.failure_schema, built.interface.failure.bytes } }) |pair| {
                if (pair[0].bytes != pair[1].len or !std.meta.eql(pair[0].digest, storage.digest(pair[1]))) return error.CorruptState;
            }
            if (built.ports.len != artifact.ports.items.len) return error.CorruptState;
            for (built.ports, artifact.ports.items) |actual, declared| {
                if (!same(actual.identity.bytes, declared.identity.bytes) or actual.class != declared.class) return error.CorruptState;
                inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                    const bytes = @field(actual, field).bytes;
                    const ref = @field(declared, field);
                    if (ref.bytes != bytes.len or !std.meta.eql(ref.digest, storage.digest(bytes))) return error.CorruptState;
                }
            }
            try self.checked_workspace_programs.put(self.allocator, saved.artifact.digest, self.store().integrity_epoch);
        }

        pub fn workspaceWork(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !contracts.Decoded(workspace.Work) {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            return self.retainedWorkspaceWork(a, task_id, work_id);
        }

        fn retainedWorkspaceWork(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !contracts.Decoded(workspace.Work) {
            const bytes = (try self.store().recordBytes(a, "workspace_work", work_id, task_id)) orelse return error.ArtifactUnavailable;
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(workspace.Work, a, bytes);
            errdefer saved.deinit();
            if (saved.value.version != 1 or !std.meta.eql(saved.value.id, work_id) or !std.meta.eql(saved.value.task, task_id)) return error.CorruptState;
            return saved;
        }

        pub fn validateWorkspace(self: *Self, allocator: std.mem.Allocator, task_id: state.TaskId) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const index = try self.store().archiveIndex(a, task_id, .{ .digest = storage.digest(self.assets.manifest), .bytes = self.assets.manifest.len });
            try self.validateWorkspaceRecords(a, task_id, index.records.items);
        }
        fn validateDelegation(self: *Self, a: std.mem.Allocator, parent: state.Task, row: state.ArchiveRecord, records: []const state.ArchiveRecord) !void {
            var saved = try self.record(workspace.Delegation, a, "workspace_delegation", row.id, parent.id);
            defer saved.deinit();
            const value = saved.value;
            if (!std.meta.eql(value.id, row.id) or !std.meta.eql(value.task, parent.id)) return error.InvalidArchive;
            try requireArchiveRecord(records, .occurrence, value.parent_occurrence);
            try requireArchiveRecord(records, .workspace_work, value.instrument);
            try requireArchiveRecord(records, .workspace_work, value.work);
            var original = try self.record(occurrence.Occurrence, a, "occurrence", value.parent_occurrence, parent.id);
            defer original.deinit();
            if (original.value.work != null or !std.meta.eql(original.value.request_object, value.parent_request)) return error.InvalidArchive;
            var request = try data.invocation.decode(data.invocation.Request, a, try self.store().object(a, value.parent_request, null));
            defer request.deinit();
            const entry = try self.handlers.resolve(request.value, self.application.image_identity);
            if (entry.declaration.kind != .workspace) return error.InvalidArchive;
            var authorized = try contracts.decodeOwned(workspace.Authorized, a, try self.authorizeWorkspace(a, parent, entry, request.value.binding.payload));
            defer authorized.deinit();
            if (authorized.value.command != .work or authorized.value.command.work != .delegate) return error.InvalidArchive;
            const selection = authorized.value.command.work.delegate;
            if (selection.interpretation == .none or !same(try contracts.encodeOwned(wc.Interpretation, a, selection.interpretation), try contracts.encodeOwned(wc.Interpretation, a, value.selection)) or
                !std.meta.eql(try wp.identity(selection.expected.work, .work), value.work) or selection.expected.control_revision + 1 != value.control_revision) return error.InvalidArchive;
            if (!same(try contracts.encodeOwned(?workspace.ModelBinding, a, authorized.value.model), try contracts.encodeOwned(?workspace.ModelBinding, a, value.model))) return error.InvalidArchive;
            if (!std.meta.eql(if (value.selection == .snapshot) authorized.value.snapshot else null, value.snapshot)) return error.InvalidArchive;
            var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, value.port, null));
            defer port.deinit();
            const selected_port = switch (selection.interpretation) {
                .model => |v| v.port,
                .snapshot => |v| v.port,
                .none => unreachable,
            };
            const generation = switch (selection.interpretation) {
                .model => |v| v.generation,
                .snapshot => |v| v.generation,
                .none => unreachable,
            };
            if (!std.meta.eql(port.value.task, parent.id) or !std.meta.eql(port.value.work, value.work) or !std.meta.eql(port.value.program, value.program) or
                !std.meta.eql(port.value.id, try wp.identity(selected_port, .port)) or port.value.generation != generation) return error.InvalidArchive;
            var child = try self.workspaceWork(a, parent.id, value.instrument);
            defer child.deinit();
            if (!std.meta.eql(child.value.delegation, row.body) or !std.meta.eql(child.value.origin_work, value.work)) return error.InvalidArchive;
            var program = try self.workspaceProgram(a, parent.id, child.value.program);
            defer program.deinit();
            if (program.value.description.source_kind != @as(@TypeOf(program.value.description.source_kind), if (value.selection == .model) .instrument_model else .instrument_snapshot)) return error.InvalidArchive;
            var input = try contracts.decodeOwned(instrument.Input, a, try self.store().object(a, child.value.input, null));
            defer input.deinit();
            if (!std.meta.eql(input.value.delegation, row.body)) return error.InvalidArchive;
            if (selection.interpretation == .model) {
                if (value.model == null or selection.interpretation.model.inputs.items.len != value.inputs.items.len) return error.InvalidArchive;
                for (selection.interpretation.model.inputs.items, value.inputs.items) |ref, expected| {
                    const source = try self.workspaceValueReference(a, parent.id, ref);
                    if (!std.meta.eql(source.artifact, expected)) return error.InvalidArchive;
                }
            } else if (value.model != null or value.inputs.items.len != 0 or value.snapshot == null) return error.InvalidArchive;
        }

        pub fn validateWorkspaceRecords(self: *Self, allocator: std.mem.Allocator, task_id: state.TaskId, records: []const state.ArchiveRecord) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.validateOccurrenceProvenance(a, parent.value, records);
            try self.validateWorkspaceRecordBodies(a, task_id, records);
        }

        // Archive admission has already checked occurrence provenance before
        // replaying captured projections. Keep that ordering without checking
        // the complete occurrence history a second time here.
        fn validateWorkspaceRecordBodies(self: *Self, allocator: std.mem.Allocator, task_id: state.TaskId, records: []const state.ArchiveRecord) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const Generation = struct { work: state.Digest, generation: u64 };
            var generations: std.AutoHashMap(Generation, void) = .init(a);
            for (records) |row| switch (row.kind) {
                .workspace_program => {
                    var record_value = try self.record(workspace.Program, a, "workspace_program", row.id, task_id);
                    defer record_value.deinit();
                    var admitted = try self.workspaceProgram(a, task_id, record_value.value.artifact.digest);
                    defer admitted.deinit();
                },
                .workspace_value => {
                    var record_value = try self.record(workspace.Value, a, "workspace_value", row.id, task_id);
                    defer record_value.deinit();
                    const admitted = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, record_value.value.artifact.digest));
                    const descriptor_bytes = try self.store().object(a, admitted.schema, null);
                    var descriptor = try data.schema.decode(a, descriptor_bytes);
                    defer descriptor.deinit();
                    try data.schema.validateValue(a, descriptor.descriptor, try self.store().object(a, admitted.value, null));
                    for (record_value.value.derivation.sources.items) |ref| {
                        const source = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, ref.digest));
                        if (!std.meta.eql(source.artifact, ref)) return error.InvalidArchive;
                    }
                    const derivation = record_value.value.derivation;
                    if (derivation.kind == .computation) {
                        var work = try self.workspaceWork(a, task_id, derivation.work orelse return error.InvalidArchive);
                        defer work.deinit();
                        var program = try self.workspaceProgram(a, task_id, work.value.program);
                        defer program.deinit();
                        if (work.value.result_value == null or !std.meta.eql(work.value.result_value.?, admitted.artifact) or
                            work.value.result == null or !std.meta.eql(work.value.result.?, admitted.value) or
                            derivation.program == null or !std.meta.eql(derivation.program.?, program.value.artifact) or
                            !std.meta.eql(admitted.schema, program.value.description.result_schema) or
                            derivation.sources.items.len != work.value.inputs.items.len + 1 or work.value.input_value == null or
                            !std.meta.eql(derivation.sources.items[0], work.value.input_value.?)) return error.InvalidArchive;
                        for (derivation.sources.items[1..], work.value.inputs.items) |left, right| if (!std.meta.eql(left, right)) return error.InvalidArchive;
                    } else if (derivation.delegation != null) {
                        try self.validateDelegatedValue(a, task_id, record_value.value);
                    } else if (derivation.program != null or derivation.work != null or derivation.capture != null) return error.InvalidArchive;
                },
                .workspace_view => {
                    var record_value = try self.record(workspace.View, a, "workspace_view", row.id, task_id);
                    defer record_value.deinit();
                    _ = try self.workspaceViewObservation(a, task_id, record_value.value.artifact.digest, .{ .maximum = 1 });
                },
                .workspace_port => {
                    var port = try self.record(workspace.Port, a, "workspace_port", row.id, task_id);
                    defer port.deinit();
                    try requireArchiveRecord(records, .occurrence, port.value.occurrence);
                    var route = try self.record(workspace.ExecutionRoute, a, "execution_route", port.value.occurrence, task_id);
                    defer route.deinit();
                    if (route.value.port == null or !std.meta.eql(route.value.port.?, row.body)) return error.InvalidArchive;
                    const entry = try generations.getOrPut(.{ .work = port.value.work, .generation = port.value.generation });
                    if (entry.found_existing) return error.InvalidArchive;
                },
                .workspace_port_reply => {
                    var answer = try self.record(workspace.PortReply, a, "workspace_port_reply", row.id, task_id);
                    defer answer.deinit();
                    var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, answer.value.port, null));
                    defer port.deinit();
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", port.value.occurrence, task_id);
                    defer pending.deinit();
                    const acquired = switch (pending.value.state) {
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (!std.meta.eql(acquired.attempt, row.id) or !std.meta.eql(acquired.reply, answer.value.reply.digest)) return error.InvalidArchive;
                },
                .execution_route => {
                    try requireArchiveRecord(records, .occurrence, row.id);
                },
                .workspace_delegation => try self.validateDelegation(a, parent.value, row, records),
                .workspace_wait => {
                    var wait = try self.record(workspace.Wait, a, "workspace_wait", row.id, task_id);
                    defer wait.deinit();
                    try requireArchiveRecord(records, .occurrence, wait.value.id);
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", wait.value.id, task_id);
                    defer pending.deinit();
                    if (pending.value.work != null or !std.meta.eql(wait.value.request, pending.value.request_object)) return error.InvalidArchive;
                    var request = try data.invocation.decode(data.invocation.Request, a, try self.store().object(a, wait.value.request, null));
                    defer request.deinit();
                    const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                    if (entry.declaration.kind != .workspace) return error.InvalidArchive;
                    var authorized = try contracts.decodeOwned(workspace.Authorized, a, try self.authorizeWorkspace(a, parent.value, entry, request.value.binding.payload));
                    defer authorized.deinit();
                    if (authorized.value.command != .work or authorized.value.command.work != .wait) return error.InvalidArchive;
                    const expected = try contracts.encodeOwned(@TypeOf(wait.value.selection), a, authorized.value.command.work.wait);
                    const actual = try contracts.encodeOwned(@TypeOf(wait.value.selection), a, wait.value.selection);
                    if (!same(actual, expected)) return error.InvalidArchive;
                    for (wait.value.selection.works.items) |ref| {
                        var work = try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
                        work.deinit();
                    }
                },
                else => {},
            };
            for (records) |row| {
                if (row.kind != .workspace_work) continue;
                var saved = try self.workspaceWork(a, task_id, row.id);
                defer saved.deinit();
                const value = saved.value;
                if (value.execution_revision == 0 or value.control_revision == 0 or value.event_watermark > parent.value.event_high or
                    (value.cancellation_applied and value.cancellation == null)) return error.InvalidArchive;
                var program = try self.workspaceProgram(a, task_id, value.program);
                defer program.deinit();
                const native_program = program.value.description.source_kind == .instrument_model or program.value.description.source_kind == .instrument_snapshot;
                if (native_program != (value.delegation != null) or (value.delegation == null and (value.answer_value != null or value.instrument_occurrence != null))) return error.InvalidArchive;
                if (value.delegation) |ref| {
                    var delegation = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, ref, null));
                    defer delegation.deinit();
                    try requireArchiveRecord(records, .workspace_delegation, delegation.value.id);
                    if (!std.meta.eql(delegation.value.instrument, value.id)) return error.InvalidArchive;
                    if (value.instrument_occurrence) |id| try requireArchiveRecord(records, .occurrence, id);
                }
                const input = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, (value.input_value orelse return error.InvalidArchive).digest));
                if (!std.meta.eql(input.value, value.input) or !std.meta.eql(input.schema, program.value.description.input_schema)) return error.InvalidArchive;
                for (value.inputs.items) |ref| _ = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, ref.digest));
                for (0..std.math.cast(usize, value.port_generation) orelse return error.InvalidArchive) |i| if (!generations.contains(.{ .work = value.id, .generation = i + 1 })) return error.InvalidArchive;
                const driver = try self.workspaceResident(a, value);
                defer self.retire(a) catch self.store().fence();
                const publication = try driver.drive(a, .none, 0);
                if (!std.meta.eql(storage.digest(publication.outcome), value.outcome.digest) or publication.outcome.len != value.outcome.bytes or
                    !std.meta.eql(storage.digest(publication.checkpoint), value.checkpoint.digest) or publication.checkpoint.len != value.checkpoint.bytes) return error.InvalidArchive;
                var observed = try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
                defer observed.deinit();
                if (!same(@tagName(observed.value), @tagName(value.outcome_kind))) return error.InvalidArchive;
                switch (observed.value) {
                    .requested => |pending| {
                        const id = value.current_occurrence orelse return error.InvalidArchive;
                        var occurrence_value = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                        defer occurrence_value.deinit();
                        if (!std.meta.eql(occurrence_value.value.request_object, state.Reference{ .digest = storage.digest(pending.request), .bytes = pending.request.len })) return error.InvalidArchive;
                        var route = try self.record(workspace.ExecutionRoute, a, "execution_route", id, task_id);
                        defer route.deinit();
                        if (!std.meta.eql(value.current_port, route.value.port)) return error.InvalidArchive;
                    },
                    .completed => |bytes| {
                        if (value.result == null or value.result_value == null or !std.meta.eql(value.result.?, state.Reference{ .digest = storage.digest(bytes), .bytes = bytes.len })) return error.InvalidArchive;
                    },
                    else => if (value.result != null or value.result_value != null) return error.InvalidArchive,
                }
                if (observed.value != .requested and (value.current_occurrence != null or value.current_port != null)) return error.InvalidArchive;
            }
        }

        /// The compilation result stays local until the same transaction admits
        /// its complete dependency closure, custody and acknowledgment.
        pub fn workspaceBuild(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, source: []const u8, diagnostic: *construction.Diagnostic) !Admission {
            return self.workspaceBuildKind(a, operation_id, task_id, source, .source_records, null, &.{}, diagnostic);
        }
        fn workspaceCompile(self: *Self, a: std.mem.Allocator, source: []const u8, kind: @FieldType(workspace.ProgramArtifact, "source_kind"), catalog: ?state.Reference, exposures: []const wc.Exposure, diagnostic: *construction.Diagnostic) !construction.Built {
            if (kind == .instrument_model or kind == .instrument_snapshot) {
                if (!same(source, instrument.identity) or catalog != null or exposures.len != 0) return error.InvalidConstruction;
                return instrument.build(a, if (kind == .instrument_model) .model else .snapshot);
            }
            if (kind == .source_records) {
                if (catalog != null) return error.InvalidConstruction;
                return construction.buildExposed(a, source, exposures, null, diagnostic);
            }
            if (exposures.len != 0) return error.InvalidExposure;
            diagnostic.phase = .authority;
            const ref = catalog orelse return error.UnavailableCatalog;
            const bytes = try self.store().object(a, ref, null);
            defer a.free(bytes);
            diagnostic.phase = .compilation;
            const built = try construction.buildComponent(a, bytes, source);
            diagnostic.phase = .complete;
            return built;
        }
        fn workspaceBuildKind(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, source: []const u8, source_kind: wc.SourceKind, catalog: ?state.Reference, exposures: []const wc.Exposure, diagnostic: *construction.Diagnostic) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const Request = struct { method: state.Method = .workspace, kind: workspace.Operation = .build, task: state.TaskId, source: contracts.Bytes(null), source_kind: wc.SourceKind, catalog: ?state.Reference, exposures: contracts.Vector(wc.Exposure, null) };
            const request = try operation(Request, a, .{ .task = task_id, .source = .{ .bytes = source }, .source_kind = source_kind, .catalog = catalog, .exposures = .{ .items = exposures } });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            if (catalog) |ref| try workspaceSnapshotAccess(parent.value, ref);
            var built = try self.workspaceCompile(a, source, @fromBackingInt(@intCast(@backingInt(source_kind))), catalog, exposures, diagnostic);
            defer built.deinit();
            try self.store().begin();
            defer self.store().rollback();
            const saved = try self.workspaceStoreProgram(a, task_id, source, @fromBackingInt(@intCast(@backingInt(source_kind))), catalog, exposures, .{ .image = .{ .bytes = built.image }, .interface = built.interface, .ports = .{ .items = built.ports } });
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, saved.digest, .program, saved);
            try self.checked_workspace_programs.put(self.allocator, saved.digest, self.store().integrity_epoch);
            return admitted;
        }

        fn workspaceStoreProgram(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, source: []const u8, source_kind: @FieldType(workspace.ProgramArtifact, "source_kind"), catalog: ?state.Reference, exposures: []const wc.Exposure, built: build_job.Compiled) !state.Reference {
            const ports = try a.alloc(workspace.PortInterface, built.ports.items.len);
            defer a.free(ports);
            for (built.ports.items, ports) |port, *out| out.* = .{ .identity = port.identity, .class = port.class, .argument = try self.store().putObject(port.argument.bytes), .observation = try self.store().putObject(port.observation.bytes), .payload = try self.store().putObject(port.payload.bytes), .command = try self.store().putObject(port.command.bytes) };
            const artifact: workspace.ProgramArtifact = .{
                .source = try self.store().putObject(source),
                .source_kind = source_kind,
                .construction_contract = try name(switch (source_kind) {
                    .source_records => @import("source_records.zig").identity,
                    .component_recipe => construction.component_identity,
                    .instrument_model, .instrument_snapshot => instrument.identity,
                }),
                .authoring_identity = storage.digest(@import("native_options").horos_identity),
                .image = try self.store().putObject(built.image.bytes),
                .input_schema = try self.store().putObject(built.interface.input.bytes),
                .result_schema = try self.store().putObject(built.interface.output.bytes),
                .failure_schema = try self.store().putObject(built.interface.failure.bytes),
                .catalog = catalog,
                .exposures = .{ .items = exposures },
                .ports = .{ .items = ports },
            };
            const bytes = try contracts.encodeOwned(workspace.ProgramArtifact, a, artifact);
            defer a.free(bytes);
            const reference = try self.store().putObject(bytes);
            const id = try workspaceContentCustody(a, task_id, reference.digest);
            const saved: workspace.Program = .{ .id = id, .task = task_id, .artifact = reference, .description = artifact };
            if (try self.store().recordBytes(a, "workspace_program", id, task_id)) |prior| {
                defer a.free(prior);
                const expected = try contracts.encodeOwned(workspace.Program, a, saved);
                defer a.free(expected);
                if (!same(prior, expected)) return error.CorruptState;
            } else try self.store().createRecord(workspace.Program, "workspace_program", id, task_id, saved);
            return reference;
        }

        fn workspaceCommit(self: *Self, a: std.mem.Allocator, initial: state.Task, operation_id: ?[]const u8, request: state.Digest, identity: state.Digest, kind: @FieldType(contracts.workspace.Ref, "kind"), observation: state.Reference) !Admission {
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{std.fmt.bytesToHex(identity, .lower)});
            defer a.free(event_data);
            try self.event(&parent, if (operation_id != null) .workspace else .workspace_progress, event_data);
            var receipt_id: state.Digest = undefined;
            try self.io.randomSecure(&receipt_id);
            var frozen = observation;
            if (kind == .work) {
                const bytes = try self.store().object(a, observation, null);
                defer a.free(bytes);
                var work = try contracts.decodeOwned(workspace.Work, a, bytes);
                defer work.deinit();
                var pending: ?contracts.Decoded(occurrence.Occurrence) = null;
                defer if (pending) |*value| value.deinit();
                if (work.value.current_occurrence) |id| pending = try self.record(occurrence.Occurrence, a, "occurrence", id, parent.id);
                const snapshot = try contracts.encodeOwned(workspace.WorkObservation, a, .{ .work = work.value, .occurrence = if (pending) |value| value.value else null });
                defer a.free(snapshot);
                frozen = try self.store().putObject(snapshot);
            }
            const saved: state.Receipt = .{ .id = receipt_id, .client_operation_id = try name(operation_id orelse "workspace.progress"), .method = .workspace, .request_digest = request, .task = parent.id, .revision = parent.revision, .disposition = .accepted, .workspace = identity, .workspace_kind = kind, .workspace_observation = frozen };
            if (operation_id) |op| {
                const bytes = try contracts.encodeOwned(state.Receipt, a, saved);
                defer a.free(bytes);
                const key = try self.operationKey(a, op);
                try self.store().putReceipt(&key, request, bytes);
            }
            try self.runnable.ensureUnusedCapacity(self.allocator, 2);
            const disposed = parent.terminal() and try self.taskCleanupComplete(a, parent);
            try self.persist(a, parent, initial.revision, "workspace.publish", .acquire);
            if (disposed) self.unclaim(parent.id);
            return .{ .receipt = saved, .replayed = false };
        }

        fn workspaceDelegate(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, authorized: workspace.Authorized) !Admission {
            const selection = authorized.command.work.delegate;
            const Request = struct { task: state.TaskId, command: @FieldType(wc.Work, "delegate") };
            const request = try operation(Request, a, .{ .task = task_id, .command = selection });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            const parent_occurrence = parent.value.current_occurrence orelse return error.InvalidDelegation;
            const operation_name = std.fmt.bytesToHex(parent_occurrence, .lower);
            if (!same(operation_id, &operation_name)) return error.InvalidDelegation;
            var original = try self.record(occurrence.Occurrence, a, "occurrence", parent_occurrence, task_id);
            defer original.deinit();
            if (original.value.work != null or original.value.state != .ready) return error.InvalidDelegation;
            const target_id = try wp.identity(selection.expected.work, .work);
            var target = try self.workspaceWork(a, task_id, target_id);
            defer target.deinit();
            if (target.value.execution_revision != selection.expected.execution_revision or target.value.control_revision != selection.expected.control_revision) return error.StaleRevision;
            if (target.value.terminal() or target.value.cancellation != null) return error.InvalidState;
            const port_ref = target.value.current_port orelse return error.NoExposedPort;
            var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, port_ref, null));
            defer port.deinit();
            const selected_port = switch (selection.interpretation) {
                .model => |v| v.port,
                .snapshot => |v| v.port,
                .none => return error.InvalidDelegation,
            };
            const generation = switch (selection.interpretation) {
                .model => |v| v.generation,
                .snapshot => |v| v.generation,
                .none => unreachable,
            };
            if (!std.meta.eql(try wp.identity(selected_port, .port), port.value.id) or generation != port.value.generation or port.value.interface.class == .observation) return error.StaleOccurrence;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", port.value.occurrence, task_id);
            defer pending.deinit();
            if (pending.value.state != .ready) return error.UnsettledOccurrence;
            const kind: instrument.Kind = if (selection.interpretation == .model) .model else .snapshot;
            if (kind == .model and (authorized.model == null or !self.profile.authority.inference)) return error.Denied;
            if (kind == .snapshot) try workspaceSnapshotAccess(parent.value, authorized.snapshot orelse return error.Denied);
            var inputs: std.ArrayList(state.Reference) = .empty;
            defer inputs.deinit(a);
            if (selection.interpretation == .model) for (selection.interpretation.model.inputs.items) |ref| {
                const value = try self.workspaceValueReference(a, task_id, ref);
                try inputs.append(a, value.artifact);
            };
            var built = try instrument.build(a, kind);
            defer built.deinit();
            try self.store().begin();
            defer self.store().rollback();
            const program = try self.workspaceStoreProgram(a, task_id, instrument.identity, if (kind == .model) .instrument_model else .instrument_snapshot, null, &.{}, .{ .image = .{ .bytes = built.image }, .interface = built.interface, .ports = .{ .items = &.{} } });
            // This publication grants reusable immutable code, never execution.
            _ = try self.workspaceCommit(a, parent.value, null, @splat(0), program.digest, .program, program);
            try self.checked_workspace_programs.put(self.allocator, program.digest, self.store().integrity_epoch);
            var id: state.Digest = undefined;
            var instrument_id: state.Digest = undefined;
            try self.io.randomSecure(&id);
            try self.io.randomSecure(&instrument_id);
            const record_value: workspace.Delegation = .{ .id = id, .task = task_id, .parent_occurrence = parent_occurrence, .parent_request = original.value.request_object, .work = target_id, .instrument = instrument_id, .program = port.value.program, .port = port_ref, .control_revision = try std.math.add(u64, target.value.control_revision, 1), .selection = selection.interpretation, .model = authorized.model, .snapshot = if (kind == .snapshot) authorized.snapshot else null, .inputs = .{ .items = inputs.items } };
            const record_bytes = try contracts.encodeOwned(workspace.Delegation, a, record_value);
            defer a.free(record_bytes);
            const input = try contracts.encodeOwned(instrument.Input, a, .{ .delegation = .{ .digest = storage.digest(record_bytes), .bytes = record_bytes.len } });
            defer a.free(input);
            return self.workspaceStartAdmitted(a, operation_id, task_id, program.digest, input, .{ .stop = .terminal, .continuation = .owner_scheduled }, null, .{ .record = record_value, .request = request, .policy = selection.policy });
        }

        pub fn workspaceStart(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, input: []const u8, policy: workspace.RunPolicy) !Admission {
            return self.workspaceStartValue(a, operation_id, task_id, program_id, input, policy, null);
        }
        fn workspaceStartValue(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, input: []const u8, policy: workspace.RunPolicy, origin: ?state.Reference) !Admission {
            return self.workspaceStartAdmitted(a, operation_id, task_id, program_id, input, policy, origin, null);
        }
        const StartDelegation = struct { record: workspace.Delegation, request: state.Digest, policy: workspace.RunPolicy };
        fn workspaceStartAdmitted(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, input: []const u8, policy: workspace.RunPolicy, origin: ?state.Reference, delegated: ?StartDelegation) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const Request = struct { method: state.Method = .workspace, kind: workspace.Operation = .start, task: state.TaskId, program: state.Digest, input: contracts.Bytes(null), policy: workspace.RunPolicy, origin: ?state.Reference };
            const request = if (delegated) |bound| bound.request else try operation(Request, a, .{ .task = task_id, .program = program_id, .input = .{ .bytes = input }, .policy = policy, .origin = origin });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            var artifact = try self.workspaceProgram(a, task_id, program_id);
            defer artifact.deinit();
            const kind = artifact.value.description.source_kind;
            if ((kind == .instrument_model or kind == .instrument_snapshot) != (delegated != null)) return error.InvalidDelegation;
            const schema = try self.store().object(a, artifact.value.description.input_schema, null);
            defer a.free(schema);
            var descriptor = try data.schema.decode(a, schema);
            defer descriptor.deinit();
            try data.schema.validateValue(a, descriptor.descriptor, input);
            const image = try self.store().object(a, artifact.value.description.image, null);
            defer a.free(image);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try self.retire(a);
            var id: state.Digest = undefined;
            if (delegated) |bound| id = bound.record.instrument else try self.io.randomSecure(&id);
            const driver = try evaluator.Driver.open(self.allocator, image, .{ .initial_args = input });
            self.active = .{ .task = task_id, .work = id, .execution_revision = 0, .driver = driver };
            errdefer if (!self.store().fenced) self.retire(a) catch self.store().fence();
            const native_started = std.Io.Clock.awake.now(self.io);
            const publication = try driver.drive(a, .none, 256);
            const native_ns = std.math.cast(u64, @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds)) orelse std.math.maxInt(u64);
            defer a.free(publication.outcome);
            errdefer self.store().fence();
            try self.store().begin();
            defer self.store().rollback();
            var delegation_ref: ?state.Reference = null;
            if (delegated) |bound| {
                const record_value = bound.record;
                var target = try self.workspaceWork(a, task_id, record_value.work);
                defer target.deinit();
                if (target.value.control_revision + 1 != record_value.control_revision or !std.meta.eql(target.value.current_port, record_value.port) or target.value.cancellation != null) return error.StaleRevision;
                target.value.control_revision = record_value.control_revision;
                target.value.policy = bound.policy;
                target.value.event_watermark = parent.value.event_high + 1;
                target.value.schedule = .parked;
                try self.store().putRecord(workspace.Work, "workspace_work", target.value.id, task_id, target.value);
                try self.store().createRecord(workspace.Delegation, "workspace_delegation", record_value.id, task_id, record_value);
                delegation_ref = try self.snapshotRecord(workspace.Delegation, a, "workspace_delegation", record_value.id, task_id);
            }
            var saved: workspace.Work = .{
                .id = id,
                .task = task_id,
                .program = program_id,
                .delegation = delegation_ref,
                .origin_work = if (delegated) |bound| bound.record.work else null,
                .input = try self.store().putObject(input),
                .checkpoint = undefined,
                .outcome = undefined,
                .outcome_kind = .progressed,
                .execution_revision = 1,
                .native_publication_nanoseconds = native_ns,
                .control_revision = 1,
                .schedule = .parked,
                .policy = policy,
                .event_watermark = parent.value.event_high + 1,
            };
            saved.input_value = origin orelse try self.workspacePublishValue(a, task_id, artifact.value.description.input_schema, saved.input, .{ .kind = .hypothesis, .sources = .{ .items = &.{} } });
            try self.workspacePublication(a, &saved, publication);
            try self.store().createRecord(workspace.Work, "workspace_work", id, task_id, saved);
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", id, task_id));
            self.active.?.execution_revision = saved.execution_revision;
            if (saved.schedule == .queued) self.subjectAppendAssumeCapacity(.{ .task = task_id, .work = id });
            return admitted;
        }

        fn workspacePublication(self: *Self, a: std.mem.Allocator, value: *workspace.Work, publication: evaluator.Driver.Publication) !void {
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer outcome.deinit();
            value.checkpoint = try self.store().putObject(publication.checkpoint);
            value.outcome = try self.store().putObject(publication.outcome);
            value.schedule = .parked;
            switch (outcome.value) {
                .progressed => value.outcome_kind = .progressed,
                .yielded => value.outcome_kind = .yielded,
                .completed => |bytes| {
                    value.outcome_kind = .completed;
                    value.result = try self.store().putObject(bytes);
                    var program = try self.workspaceProgram(a, value.task, value.program);
                    defer program.deinit();
                    if (value.delegation == null) value.result_value = try self.workspaceResultValue(a, value.*, program.value);
                },
                .failed => {
                    value.outcome_kind = .failed;
                },
                .cancelled => {
                    value.outcome_kind = .cancelled;
                },
                .requested => |pending| {
                    var request = try data.invocation.decode(data.invocation.Request, a, pending.request);
                    defer request.deinit();
                    var id: state.Digest = undefined;
                    try self.io.randomSecure(&id);
                    const next: occurrence.Occurrence = .{ .id = id, .task = value.task, .work = value.id, .request = request.value.request_identity, .request_object = try self.store().putObject(pending.request) };
                    try self.store().createRecord(occurrence.Occurrence, "occurrence", id, value.task, next);
                    value.current_occurrence = id;
                    if (value.delegation != null) {
                        if (value.instrument_occurrence != null) return error.CorruptState;
                        value.instrument_occurrence = id;
                    }
                    value.outcome_kind = .requested;
                    var program = try self.workspaceProgram(a, value.task, value.program);
                    defer program.deinit();
                    for (program.value.description.ports.items) |port| {
                        if (!same(port.identity.bytes, request.value.binding.semantic_identity)) continue;
                        if (!std.meta.eql(storage.digest(request.value.binding.resume_schema), port.command.digest) or
                            !std.meta.eql(storage.digest(request.value.binding.payload_schema), port.payload.digest)) return error.CorruptState;
                        var port_id: state.Digest = undefined;
                        try self.io.randomSecure(&port_id);
                        value.port_generation = try std.math.add(u64, value.port_generation, 1);
                        const exposed: workspace.Port = .{ .id = port_id, .task = value.task, .work = value.id, .program = program.value.artifact, .occurrence = id, .request = next.request_object, .request_identity = next.request, .generation = value.port_generation, .interface = port, .payload = try self.store().putObject(request.value.binding.payload) };
                        try self.store().createRecord(workspace.Port, "workspace_port", port_id, value.task, exposed);
                        value.current_port = try self.snapshotRecord(workspace.Port, a, "workspace_port", port_id, value.task);
                        break;
                    }
                    try self.store().createRecord(workspace.ExecutionRoute, "execution_route", id, value.task, .{ .id = id, .task = value.task, .work = value.id, .image = program.value.description.image, .program_identity = request.value.binding.program_identity, .port = value.current_port, .delegation = value.delegation });
                },
                .needs_capacity => return error.Capacity,
            }
            // No unbound external request is dispatched. A run policy grants
            // continued computation, never the authority to invent an answer.
            if (value.outcome_kind == .requested and value.delegation != null and value.current_port == null and value.policy.continuation == .owner_scheduled) value.schedule = .queued;
            if (!value.terminal() and value.outcome_kind != .requested and (value.cancellation != null or (value.policy.continuation == .owner_scheduled and value.policy.stop != .next_slice and (value.outcome_kind != .yielded or value.policy.stop == .terminal)))) value.schedule = .queued;
        }

        fn workspaceResident(self: *Self, a: std.mem.Allocator, value: workspace.Work) !*evaluator.Driver {
            if (self.active) |active| {
                if (std.meta.eql(active.task, value.task) and active.work != null and std.meta.eql(active.work.?, value.id) and active.execution_revision == value.execution_revision) return active.driver;
                try self.retire(a);
            }
            var artifact = try self.workspaceProgram(a, value.task, value.program);
            defer artifact.deinit();
            const image = try self.store().object(a, artifact.value.description.image, null);
            defer a.free(image);
            const checkpoint = try self.store().object(a, value.checkpoint, null);
            defer a.free(checkpoint);
            const driver = try evaluator.Driver.open(self.allocator, image, .{ .state = checkpoint });
            self.active = .{ .task = value.task, .work = value.id, .execution_revision = value.execution_revision, .driver = driver };
            return driver;
        }

        fn workspaceResultValue(self: *Self, a: std.mem.Allocator, value: workspace.Work, program: workspace.Program) !state.Reference {
            const source_value = value.input_value orelse return error.CorruptState;
            const antecedents = try a.alloc(state.Reference, value.inputs.items.len + 1);
            defer a.free(antecedents);
            antecedents[0] = source_value;
            @memcpy(antecedents[1..], value.inputs.items);
            return self.workspacePublishValue(a, value.task, program.description.result_schema, value.result.?, .{ .kind = .computation, .sources = .{ .items = antecedents }, .program = program.artifact, .work = value.id });
        }

        fn workspaceInstrumentAnswer(self: *Self, a: std.mem.Allocator, parent: state.Task, child: workspace.Work) !?state.Reference {
            var output = try contracts.decodeOwned(instrument.Output, a, try self.store().object(a, child.result orelse return error.CorruptState, null));
            defer output.deinit();
            if (output.value != .answer) return null;
            const delegation_ref = child.delegation orelse return error.CorruptState;
            var admitted = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, delegation_ref, null));
            defer admitted.deinit();
            const delegation = admitted.value;
            if (!std.meta.eql(delegation.instrument, child.id) or !std.meta.eql(delegation.task, parent.id)) return error.CorruptState;
            var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, delegation.port, null));
            defer port.deinit();
            const schema = try self.store().object(a, port.value.interface.argument, null);
            var descriptor = try data.schema.decode(a, schema);
            defer descriptor.deinit();
            try data.schema.validateValue(a, descriptor.descriptor, output.value.answer.bytes);
            if (delegation.selection == .snapshot) {
                const snapshot = delegation.snapshot orelse return error.CorruptState;
                const selected = delegation.selection.snapshot;
                const ref = try self.workspaceMaterializeSnapshot(a, parent, snapshot, .{ .path = selected.path, .offset = selected.offset, .maximum = selected.maximum });
                const acquired = try self.workspaceValueReference(a, parent.id, try wp.reference(a, .value, ref.digest));
                if (!std.meta.eql(acquired.schema, port.value.interface.argument) or !std.meta.eql(acquired.value, state.Reference{ .digest = storage.digest(output.value.answer.bytes), .bytes = output.value.answer.bytes.len })) return error.CorruptState;
                return ref;
            }
            if (delegation.selection != .model) return error.CorruptState;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", child.instrument_occurrence orelse return error.CorruptState, parent.id);
            defer pending.deinit();
            if (pending.value.state != .admitted or pending.value.state.admitted != .reply) return error.CorruptState;
            var capture_value = try self.record(state.Capture, a, "capture", pending.value.state.admitted.reply.attempt, parent.id);
            defer capture_value.deinit();
            return try self.workspacePublishValue(a, parent.id, port.value.interface.argument, try self.store().putObject(output.value.answer.bytes), .{
                .kind = .judgment,
                .sources = delegation.inputs,
                .work = child.id,
                .delegation = delegation_ref,
                .capture = capture_value.value.response orelse return error.CorruptState,
            });
        }

        fn workspaceApplyAnswer(self: *Self, a: std.mem.Allocator, child: workspace.Work) !void {
            var parent = try self.task(a, child.task);
            defer parent.deinit();
            if (!try self.delegationCurrent(a, parent.value, child)) return;
            var admitted = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, child.delegation.?, null));
            defer admitted.deinit();
            var target = try self.workspaceWork(a, child.task, admitted.value.work);
            defer target.deinit();
            var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, admitted.value.port, null));
            defer port.deinit();
            const operation_id = try std.fmt.allocPrint(a, "delegation-{s}", .{std.fmt.bytesToHex(admitted.value.id, .lower)});
            defer a.free(operation_id);
            _ = try self.workspaceInteract(a, operation_id, child.task, .{ .expected = .{ .work = try wp.reference(a, .work, target.value.id), .execution_revision = target.value.execution_revision, .control_revision = target.value.control_revision }, .port = try wp.reference(a, .port, port.value.id), .generation = port.value.generation, .command = .{ .resume_value = .{ .reference = try wp.reference(a, .value, child.answer_value.?.digest) } } });
        }

        fn delegationCurrent(self: *Self, a: std.mem.Allocator, parent: state.Task, child: workspace.Work) !bool {
            if (parent.terminal() or parent.cancellation != null) return false;
            const ref = child.delegation orelse return false;
            var delegation = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, ref, null));
            defer delegation.deinit();
            const admitted = delegation.value;
            if (!std.meta.eql(admitted.task, parent.id) or !std.meta.eql(admitted.instrument, child.id)) return error.CorruptState;
            var target = try self.workspaceWork(a, parent.id, admitted.work);
            defer target.deinit();
            return target.value.cancellation == null and !target.value.terminal() and target.value.control_revision == admitted.control_revision and std.meta.eql(target.value.current_port, admitted.port);
        }

        fn pumpWorkspace(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !Step {
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            const subject: workspace.Subject = .{ .task = task_id, .work = work_id };
            if (saved.value.terminal() and saved.value.answer_value != null) {
                // Completion and delivery are distinct durable transitions.
                // The retained answer plus its current delegation is the
                // pending transfer, including after explicit task resume.
                try self.workspaceApplyAnswer(a, saved.value);
                self.subjectRemove(subject);
                return .progressed;
            }
            if (saved.value.terminal() or saved.value.schedule == .parked) {
                self.subjectRemove(subject);
                return .progressed;
            }
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if ((parent.value.cancellation != null or parent.value.terminal()) and saved.value.cancellation == null) {
                try self.parkWorkspaceOnClose(a, task_id, work_id);
                self.subjectRemove(subject);
                return .progressed;
            }
            if (saved.value.current_occurrence) |id| {
                var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                defer pending.deinit();
                if (saved.value.cancellation != null and !saved.value.cancellation_applied and
                    (pending.value.state == .ready or pending.value.state == .awaiting or pending.value.state == .not_sent))
                {
                    _ = try self.workspaceAdvance(a, parent.value, saved.value, .{ .cancel = .{ .text = saved.value.cancellation.?.bytes } }, null, @splat(0));
                    return .progressed;
                }
                if (pending.value.state == .captured) return self.interpretCapture(a, parent.value, pending.value);
                if (pending.value.state == .ready and saved.value.delegation != null) {
                    if (!try self.delegationCurrent(a, parent.value, saved.value)) return self.blockedOccurrence(a, parent.value, pending.value, .denied);
                    return self.dispatch(a, parent.value, pending.value);
                }
                if (pending.value.state == .unknown or pending.value.state == .not_sent) return self.blockedOccurrence(a, parent.value, pending.value, .unavailable_environment);
                if (pending.value.state != .settled_reply) return .idle;
                const reply = try self.store().acquiredObject(a, pending.value.state.settled_reply.reply, null);
                defer a.free(reply);
                _ = try self.workspaceAdvance(a, parent.value, saved.value, .{ .reply = reply }, null, @splat(0));
                return .progressed;
            }
            const control: data.invocation.Control = if (saved.value.cancellation != null and !saved.value.cancellation_applied) .{ .cancel = .{ .text = saved.value.cancellation.?.bytes } } else if (saved.value.outcome_kind == .yielded) .resume_yield else .none;
            _ = try self.workspaceAdvance(a, parent.value, saved.value, control, null, @splat(0));
            return .progressed;
        }

        fn workspaceRunnable(self: *Self, a: std.mem.Allocator, parent: state.Task, child: workspace.Work) !bool {
            if (!child.terminal()) return child.schedule != .parked;
            return child.answer_value != null and try self.delegationCurrent(a, parent, child);
        }

        fn workspaceAdvance(self: *Self, a: std.mem.Allocator, parent: state.Task, initial: workspace.Work, control: data.invocation.Control, operation_id: ?[]const u8, request: state.Digest) !Admission {
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const driver = try self.workspaceResident(a, initial);
            var consumed: ?occurrence.Occurrence = null;
            if (control == .cancel or control == .reply) if (initial.current_occurrence) |id| {
                var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, initial.task);
                defer pending.deinit();
                consumed = try occurrence.consumed(pending.value, .{ .id = id, .task = initial.task, .work = initial.id, .request = pending.value.request }, if (control == .cancel) .cancel else .{ .reply = storage.digest(control.reply) }, initial.cancellation != null);
            };
            const native_started = std.Io.Clock.awake.now(self.io);
            const publication = try driver.drive(a, control, if (control == .reply and initial.cancellation != null and !initial.cancellation_applied) 0 else 256);
            defer a.free(publication.outcome);
            errdefer self.store().fence();
            var value = initial;
            value.native_publication_nanoseconds +|= std.math.cast(u64, @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds)) orelse std.math.maxInt(u64);
            if (control == .cancel) value.cancellation_applied = true;
            if (consumed != null) {
                value.current_occurrence = null;
                value.current_port = null;
            }
            value.execution_revision = try std.math.add(u64, value.execution_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try self.store().begin();
            defer self.store().rollback();
            if (consumed) |prior| try self.store().putRecord(occurrence.Occurrence, "occurrence", prior.id, value.task, prior);
            try self.workspacePublication(a, &value, publication);
            if (value.outcome_kind == .completed and value.delegation != null) {
                value.answer_value = try self.workspaceInstrumentAnswer(a, parent, value);
                if (value.answer_value) |answer| {
                    const sources = try a.alloc(state.Reference, value.inputs.items.len + 1);
                    @memcpy(sources[0..value.inputs.items.len], value.inputs.items);
                    sources[value.inputs.items.len] = answer;
                    value.inputs = .{ .items = sources };
                }
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                value.result_value = try self.workspaceResultValue(a, value, program.value);
            }
            try self.store().putRecord(workspace.Work, "workspace_work", value.id, value.task, value);
            const runnable = try self.workspaceRunnable(a, parent, value);
            const admitted = try self.workspaceCommit(a, parent, operation_id, request, value.id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", value.id, value.task));
            self.active.?.execution_revision = value.execution_revision;
            const subject: workspace.Subject = .{ .task = value.task, .work = value.id };
            if (runnable) self.subjectAddAssumeCapacity(subject) else self.subjectRemove(subject);
            return admitted;
        }

        pub fn workspaceControl(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, work_id: state.Digest, expected_execution: u64, expected_control: u64, command: workspace.Command) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const Request = struct { method: state.Method = .workspace, kind: workspace.Operation = .control, task: state.TaskId, work: state.Digest, execution: u64, control: u64, command: workspace.Command };
            const request = try operation(Request, a, .{ .task = task_id, .work = work_id, .execution = expected_execution, .control = expected_control, .command = command });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            var value = saved.value;
            if (value.execution_revision != expected_execution or value.control_revision != expected_control) return error.StaleRevision;
            if (value.terminal()) return error.InvalidState;
            if (command != .park and command != .cancel and (parent.value.terminal() or parent.value.cancellation != null)) return error.InvalidState;
            if (command == .cancel) {
                if (command.cancel.bytes.len > 256 or !std.unicode.utf8ValidateSlice(command.cancel.bytes)) return error.InvalidParams;
                value.cancellation = command.cancel;
                value.control_revision = try std.math.add(u64, value.control_revision, 1);
                if (value.current_occurrence) |id| {
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                    defer pending.deinit();
                    if (pending.value.state == .dispatching or pending.value.state == .unknown or pending.value.state == .captured) {
                        value.schedule = switch (pending.value.state) {
                            .captured => .queued,
                            .dispatching => .active,
                            else => .parked,
                        };
                        value.event_watermark = parent.value.event_high + 1;
                        try self.runnable.ensureUnusedCapacity(self.allocator, 2);
                        try self.store().begin();
                        defer self.store().rollback();
                        try self.store().putRecord(workspace.Work, "workspace_work", work_id, task_id, value);
                        const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, work_id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work_id, task_id));
                        if (self.work) |*active| if (std.meta.eql(active.subject_work, work_id) and std.meta.eql(active.task, task_id)) {
                            active.cancel_requested = true;
                        };
                        if (value.schedule == .queued) try self.subjectAdd(.{ .task = task_id, .work = work_id });
                        return admitted;
                    }
                    if (pending.value.state == .settled_reply) {
                        const reply = try self.store().acquiredObject(a, pending.value.state.settled_reply.reply, null);
                        defer a.free(reply);
                        return self.workspaceAdvance(a, parent.value, value, .{ .reply = reply }, operation_id, request);
                    }
                }
                return self.workspaceAdvance(a, parent.value, value, .{ .cancel = .{ .text = command.cancel.bytes } }, operation_id, request);
            }
            if (command == .advance) {
                if (value.current_occurrence) |id| {
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                    defer pending.deinit();
                    if (pending.value.state != .settled_reply) return error.WaitingInput;
                    const reply = try self.store().acquiredObject(a, pending.value.state.settled_reply.reply, null);
                    defer a.free(reply);
                    return self.workspaceAdvance(a, parent.value, value, .{ .reply = reply }, operation_id, request);
                }
                return self.workspaceAdvance(a, parent.value, value, if (value.outcome_kind == .yielded) .resume_yield else .none, operation_id, request);
            }
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            var rearmed: ?occurrence.Occurrence = null;
            switch (command) {
                .park => value.schedule = .parked,
                .delegate => |policy| {
                    value.policy = policy;
                    var can_run = value.current_occurrence == null;
                    if (value.current_occurrence) |id| {
                        var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                        defer pending.deinit();
                        can_run = pending.value.state == .settled_reply or pending.value.state == .captured or (pending.value.state == .ready and value.delegation != null);
                        if (pending.value.state == .not_sent and value.delegation != null) {
                            rearmed = try occurrence.rearm(pending.value, .{ .id = id, .task = task_id, .work = work_id, .request = pending.value.request });
                            can_run = true;
                        }
                    }
                    value.schedule = if (can_run and policy.continuation == .owner_scheduled) .queued else .parked;
                },
                .advance, .cancel => unreachable,
            }
            try self.store().begin();
            defer self.store().rollback();
            if (rearmed) |pending| try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, task_id, pending);
            try self.store().putRecord(workspace.Work, "workspace_work", work_id, task_id, value);
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, work_id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work_id, task_id));
            const subject: workspace.Subject = .{ .task = task_id, .work = work_id };
            if (value.schedule == .queued) try self.subjectAdd(subject) else self.subjectRemove(subject);
            return admitted;
        }

        fn parkWorkspaceOnClose(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !void {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            if (saved.value.schedule == .parked) return;
            saved.value.schedule = .parked;
            saved.value.control_revision = try std.math.add(u64, saved.value.control_revision, 1);
            saved.value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            try self.store().begin();
            defer self.store().rollback();
            try self.store().putRecord(workspace.Work, "workspace_work", work_id, task_id, saved.value);
            _ = try self.workspaceCommit(a, parent.value, null, @splat(0), work_id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work_id, task_id));
        }

        pub fn close(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            try self.retire(a);
            try self.program.close();
            self.runnable.deinit(self.allocator);
            self.owned.deinit(self.allocator);
            self.checked_workspace_programs.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn park(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            for (0..self.runnable.items.len) |offset| {
                const id = self.runnable.items[(self.runnable_cursor + offset) % self.runnable.items.len];
                if (id.work) |work_id| {
                    try self.parkWorkspaceOnClose(a, id.task, work_id);
                    continue;
                }
                var decoded = try self.task(a, id.task);
                defer decoded.deinit();
                var value = decoded.value;
                if (value.terminal()) continue;
                const previous = value.revision;
                value.revision = try std.math.add(u64, previous, 1);
                value.schedule = .parked;
                try self.store().begin();
                defer self.store().rollback();
                try self.event(&value, .parked, "{}");
                try self.persist(a, value, previous, "task.park", .preserve);
            }
            self.runnable.clearRetainingCapacity();
            self.runnable_cursor = 0;
            try self.retire(a);
        }
    };
}
