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
const kosmos = @import("kosmos");
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
    placement: ?*const @import("placement.zig").Configuration = null,

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
const Active = struct { task: state.TaskId, work: ?state.Digest = null, execution_revision: u64, realization_revision: u64 = 0, outer_operation: ?state.Reference = null, root_control: ?[]u8 = null, root_quantum: u64 = 0, root_cut_ready: bool = false, driver: *evaluator.Driver };

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
        const PlacementKind = enum { move, control };
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
        cleanup_cursor: usize = 0,
        shutdown_cancel_requested: bool = false,
        owner_epoch: state.Digest = undefined,
        work: ?Work = null,
        placement_pending: std.ArrayList(struct { task: state.TaskId, id: state.Digest, kind: PlacementKind }) = .empty,
        placement_job: ?struct { task: state.TaskId, id: state.Digest, kind: PlacementKind, job: *@import("placement_job.zig").Job } = null,
        checked_workspace_programs: std.AutoHashMapUnmanaged(state.Digest, u64) = .empty,
        checked_workspace_runtimes: std.AutoHashMapUnmanaged(state.Digest, u64) = .empty,
        runtime_cache: ?struct { epoch: u64, artifact: kosmos.RuntimeArtifact } = null,
        // Import may use ordinary mutation projections only through an existing
        // matching receipt. Missing receipts must never execute a new mutation.
        workspace_replay: ?struct { replayed: bool, records: []const state.ArchiveRecord } = null,

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
        fn placementSite(self: *Self) !@import("placement.zig").Site {
            const configured = self.profile.placement orelse return error.UnsupportedCapability;
            return .{ .key = configured.signing_key.public_key.toBytes(), .namespace = self.namespace.identity };
        }
        fn requireCustody(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: ?state.Digest) !void {
            // Historical validation may project an existing receipt, but its
            // replay guard forbids executing a missing operation.
            if (self.workspace_replay != null) return;
            if (try @import("placement_journal.zig").custody(self.store(), a, .{ .task = task_id, .work = work_id })) |saved| {
                var current = saved;
                defer current.deinit();
                if (self.profile.placement == null) return error.CustodyNotLocal;
                try current.value.requireLocal(try self.placementSite());
            } else if (!try self.store().locallyAdmitted(task_id)) {
                return error.CustodyNotLocal;
            }
        }
        fn hasLocalCustody(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: ?state.Digest) !bool {
            self.requireCustody(a, task_id, work_id) catch |err| {
                if (err == error.CustodyNotLocal) return false;
                return err;
            };
            return true;
        }
        fn hasFrozenCustody(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: ?state.Digest) !bool {
            if (self.profile.placement == null) return false;
            var saved = try @import("placement_journal.zig").custody(self.store(), a, .{ .task = task_id, .work = work_id }) orelse return false;
            defer saved.deinit();
            return saved.value.phase == .frozen and std.meta.eql(saved.value.owner, try self.placementSite());
        }
        fn createCustody(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: ?state.Digest) !void {
            if (self.profile.placement == null) return;
            const p = @import("placement.zig");
            try @import("placement_journal.zig").putCustody(self.store(), a, p.Custody.initial(.{ .task = task_id, .work = work_id }, try self.placementSite()));
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
            return self.workspaceSettled(a, task_id, true, true, false);
        }
        fn workspaceSettled(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, require_disposal: bool, include_remote: bool, require_park: bool) !bool {
            var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            while (try query.step() == .row) {
                const bytes = try query.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                const id = bytes[0..32].*;
                _ = arena.reset(.retain_capacity);
                const temporary = arena.allocator();
                if (!try self.hasLocalCustody(temporary, task_id, id)) {
                    if (try self.hasFrozenCustody(temporary, task_id, id)) {
                        var frozen = try self.retainedWorkspaceWork(temporary, task_id, id);
                        defer frozen.deinit();
                        if (require_disposal or require_park or frozen.value.cancellation != null) return false;
                    }
                    if (!include_remote) continue;
                    var remote = try self.remoteWorkState(temporary, task_id, id);
                    defer remote.deinit();
                    if (remote.pending) return false;
                    if (require_disposal) {
                        const observed = if (remote.latest) |saved| saved.value.report.?.value.work_state.? else return false;
                        if (!remoteDisposed(observed)) return false;
                    } else if (require_park) {
                        const observed = if (remote.latest) |saved| saved.value.report.?.value.work_state.? else return false;
                        if (!remoteDisposed(observed) and !observed.parkSettled()) return false;
                    }
                    continue;
                }
                var child = try self.retainedWorkspaceWork(temporary, task_id, id);
                defer child.deinit();
                if (!try self.workspaceWorkSettled(temporary, child.value, require_disposal, require_park)) return false;
            }
            return true;
        }

        fn workspaceWorkSettled(self: *Self, a: std.mem.Allocator, child: workspace.Work, require_disposal: bool, require_park: bool) !bool {
            if (child.terminal()) {
                const outcome_bytes = try self.store().object(a, child.outcome, null);
                defer a.free(outcome_bytes);
                var outcome = try data.invocation.decode(data.invocation.Outcome, a, outcome_bytes);
                defer outcome.deinit();
                return cleanupComplete(outcome.value);
            }
            if (require_disposal or child.cancellation != null or (require_park and child.schedule != .parked)) return false;
            if (child.current_occurrence) |current| {
                var pending = try self.record(occurrence.Occurrence, a, "occurrence", current, child.task);
                defer pending.deinit();
                switch (pending.value.state) {
                    .dispatching, .unknown, .captured, .settled_reply => return false,
                    else => {},
                }
            }
            return true;
        }
        pub fn shutdownIncomplete(self: *Self, a: std.mem.Allocator) !bool {
            for (self.owned.items) |id| {
                var decoded = try self.task(a, id);
                defer decoded.deinit();
                const value = decoded.value;
                const controller = try self.hasLocalCustody(a, id, null);
                if (!controller and (self.shutdown_cancel_requested or value.cancellation != null) and try self.hasFrozenCustody(a, id, null)) return true;
                if (controller) {
                    if (value.terminal()) {
                        const bytes = try self.store().object(a, value.outcome, null);
                        defer a.free(bytes);
                        var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                        defer outcome.deinit();
                        if (!cleanupComplete(outcome.value)) return true;
                    } else if (try self.status(a, value) == .unknown or value.cancellation != null) return true;
                }
                if (!try self.workspaceSettled(a, id, self.shutdown_cancel_requested or (controller and value.cancellation != null), controller, controller and value.terminal())) return true;
            }
            return false;
        }

        /// Launch ownership names recovery tasks. Actual cancellation authority
        /// is the local controller or the independently held local work subjects.
        pub fn cancelOwned(self: *Self, a: std.mem.Allocator, instance: []const u8, reason: []const u8) !void {
            self.shutdown_cancel_requested = true;
            const owned = try a.dupe(state.TaskId, self.owned.items);
            defer a.free(owned);
            for (owned) |id| {
                if (try self.hasLocalCustody(a, id, null)) {
                    const operation_id = try std.fmt.allocPrint(a, "shutdown-{s}-{s}", .{ instance, std.fmt.bytesToHex(id, .lower) });
                    defer a.free(operation_id);
                    _ = try self.requestCancel(a, operation_id, id, reason);
                    continue;
                }
                const children = try self.workspaceIds(a, id);
                defer a.free(children);
                for (children) |work_id| {
                    if (!try self.hasLocalCustody(a, id, work_id)) continue;
                    var child = try self.workspaceWork(a, id, work_id);
                    defer child.deinit();
                    if (child.value.terminal()) continue;
                    const operation_id = try std.fmt.allocPrint(a, "shutdown-{s}-{s}", .{ instance, std.fmt.bytesToHex(work_id, .lower) });
                    defer a.free(operation_id);
                    _ = try self.workspaceControl(a, operation_id, id, work_id, child.value.execution_revision, child.value.control_revision, .{ .cancel = .{ .bytes = reason } });
                }
            }
        }

        pub fn placementActive(self: *const Self) bool {
            return self.placement_job != null or self.placement_pending.items.len != 0;
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
                    try self.effectSchedule(a, &value, pending.value, .parked, .unavailable_environment);
                    try self.persist(a, value, parent.value.revision, "work.recover-unknown", .preserve);
                }
            }
        }
        const RemoteWorkState = struct {
            latest: ?contracts.Decoded(@import("placement.zig").ControlRecord) = null,
            pending: bool = false,
            retry_pending: ?state.Digest = null,
            fn deinit(self: *@This()) void {
                if (self.latest) |*saved| saved.deinit();
            }
        };
        fn remoteDisposed(value: @import("placement.zig").WorkState) bool {
            return (value.outcome == .completed or value.outcome == .failed or value.outcome == .cancelled) and value.cleanup_complete;
        }
        fn remoteWorkState(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !RemoteWorkState {
            const p = @import("placement.zig");
            var result: RemoteWorkState = .{};
            errdefer result.deinit();
            var custody = try @import("placement_journal.zig").custody(self.store(), a, .{ .task = task_id, .work = work_id }) orelse return result;
            defer custody.deinit();
            if (custody.value.phase != .away) return result;
            var controller_custody = try @import("placement_journal.zig").custody(self.store(), a, .{ .task = task_id }) orelse return result;
            defer controller_custody.deinit();
            var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='placement_control' ORDER BY id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const bytes = try query.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                var saved = try self.record(p.ControlRecord, a, "placement_control", bytes[0..32].*, task_id);
                errdefer saved.deinit();
                const control = saved.value.control.value;
                if (!std.meta.eql(control.subject.work, work_id) or !std.meta.eql(control.controller, controller_custody.value.owner) or control.controller_epoch != controller_custody.value.epoch) {
                    saved.deinit();
                    continue;
                }
                if (saved.value.report) |report| {
                    if (!std.meta.eql(report.value.executor, custody.value.owner) or report.value.custody_epoch != custody.value.epoch) {
                        saved.deinit();
                        continue;
                    }
                    if (report.value.work_state) |observed| {
                        try p.matchReport(a, control, saved.value.route.items, report);
                        if (!std.meta.eql(report.value.control, try p.digest(p.Control, a, control)) or report.value.custody_epoch != custody.value.epoch) {
                            return error.InvalidRemoteCommand;
                        }
                        if (result.latest == null or observed.observed_at >= result.latest.?.value.report.?.value.work_state.?.observed_at) {
                            if (result.latest) |*old| old.deinit();
                            result.latest = saved;
                            continue;
                        }
                    }
                } else {
                    result.pending = true;
                    if (saved.value.last_error == null) result.retry_pending = saved.value.id;
                }
                saved.deinit();
            }
            return result;
        }
        fn settleRemoteWork(self: *Self, a: std.mem.Allocator, parent: state.Task, work_id: state.Digest) !bool {
            const p = @import("placement.zig");
            const cancellation_revision: ?u64 = if (parent.cancellation != null) try self.parentCancellationRevision(a, parent.id) else null;
            var observed = try self.remoteWorkState(a, parent.id, work_id);
            defer observed.deinit();
            if (observed.pending) {
                if (observed.retry_pending) |id| {
                    try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
                    self.placementQueue(parent.id, id, .control);
                }
                return false;
            }
            const reference = try wp.reference(a, .work, work_id);
            var command: wc.Work = .{ .inspect = .{ .work = reference } };
            var predecessor: state.Digest = @splat(0);
            if (observed.latest) |saved| {
                const report = saved.value.report.?;
                const current = report.value.work_state.?;
                if (remoteDisposed(current)) return false;
                predecessor = try p.digest(p.Report, a, report.value);
                const expected: wc.Expected = .{ .work = reference, .execution_revision = current.execution_revision, .control_revision = current.control_revision };
                // A signed rejection at unchanged revisions needs operator
                // reconciliation; do not generate an unbounded retry stream.
                if (report.value.reply.disposition == .rejected and saved.value.control.value.cleanup_request == cancellation_revision) {
                    const prior = switch (saved.value.control.value.command) {
                        .cancel => |v| v.expected,
                        .pump => |v| v.expected,
                        .park => |v| v,
                        else => null,
                    };
                    if (prior == null) return false;
                    if (prior) |revision| if (revision.execution_revision == expected.execution_revision and revision.control_revision == expected.control_revision) return false;
                }
                if (cancellation_revision) |revision| {
                    const acknowledged = try self.remoteCancellationAcknowledged(a, parent.id, work_id, revision);
                    if (acknowledged and current.explicitly_parked) return false;
                    command = if (current.cancellation == null or !acknowledged) .{ .cancel = .{ .expected = expected, .reason = parent.cancellation.? } } else .{ .pump = .{ .expected = expected, .base_quantum = 65536 } };
                } else {
                    if (current.explicitly_parked) {
                        if (current.parkSettled()) return false;
                    } else command = if (current.cancellation == null) .{ .park = expected } else .{ .pump = .{ .expected = expected, .base_quantum = 65536 } };
                }
            }
            const identity = if (cancellation_revision) |revision|
                try operation(struct { work: state.Digest, cancellation: state.Reason, request_revision: u64, predecessor: state.Digest }, a, .{ .work = work_id, .cancellation = parent.cancellation.?, .request_revision = revision, .predecessor = predecessor })
            else
                try operation(struct { work: state.Digest, completion_revision: u64, predecessor: state.Digest }, a, .{ .work = work_id, .completion_revision = parent.execution_revision, .predecessor = predecessor });
            const operation_name = try std.fmt.allocPrint(a, "{s}-{s}", .{ if (cancellation_revision != null) "cleanup" else "close", std.fmt.bytesToHex(identity, .lower) });
            defer a.free(operation_name);
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            const bytes = self.placementControlExpanded(a, operation_name, parent.id, command, null, true, cancellation_revision) catch |err| switch (err) {
                error.CustodyNotRemote, error.UnsupportedCapability, error.Denied => return false,
                else => return err,
            };
            defer a.free(bytes);
            var signed = try contracts.decodeOwned(p.Signed(p.Control), a, bytes);
            defer signed.deinit();
            const id = p.controlId(signed.value.value);
            var saved = try self.record(p.ControlRecord, a, "placement_control", id, parent.id);
            defer saved.deinit();
            if (saved.value.report != null) return false;
            self.placementQueue(parent.id, id, .control);
            return true;
        }

        fn parentCancellationRevision(self: *Self, a: std.mem.Allocator, task_id: state.TaskId) !u64 {
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq DESC", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                if (event_value.value.kind == .cancellation_requested) return event_value.value.revision;
            }
            return error.CorruptState;
        }

        fn remoteCancellationAcknowledged(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest, revision: u64) !bool {
            const p = @import("placement.zig");
            var controller = try @import("placement_journal.zig").custody(self.store(), a, .{ .task = task_id }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            var query = try self.store().database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(p.ControlRecord, a, try query.bytes(0));
                defer saved.deinit();
                const control = saved.value.control.value;
                if (control.command != .cancel or control.cleanup_request != revision or !std.meta.eql(control.subject.work, work_id) or
                    !std.meta.eql(control.controller, controller.value.owner) or control.controller_epoch != controller.value.epoch) continue;
                if (saved.value.report) |report| {
                    try p.matchReport(a, control, saved.value.route.items, report);
                    if (report.value.reply.disposition == .observed) return true;
                }
            }
            return false;
        }

        fn workspaceExplicitlyParked(self: *Self, a: std.mem.Allocator, child: workspace.Work) !bool {
            if (child.schedule != .parked) return false;
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq DESC", &.{.{ .blob = &child.task }});
            defer query.deinit();
            while (try query.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                const concerns_child = for (event_value.value.workspace_publications.items) |item| {
                    if (std.meta.eql(item.work, child.id)) break true;
                } else false;
                if (!concerns_child) continue;
                const ref = event_value.value.workspace_command orelse continue;
                const bytes = try self.store().object(a, ref, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value == .control) return command.value.control.command == .park;
            }
            return false;
        }

        fn settleWorkspaceOne(self: *Self, a: std.mem.Allocator, parent: state.Task, controller: bool) !bool {
            const ids = try self.workspaceIds(a, parent.id);
            defer a.free(ids);
            for (ids) |id| {
                if (!try self.hasLocalCustody(a, parent.id, id)) {
                    if (controller and (parent.cancellation != null or parent.terminal()) and try self.settleRemoteWork(a, parent, id)) return true;
                    continue;
                }
                var child = try self.workspaceWork(a, parent.id, id);
                defer child.deinit();
                if (child.value.terminal()) continue;
                if (!controller or parent.cancellation == null) {
                    if (child.value.cancellation != null and child.value.schedule != .parked) try self.subjectAdd(.{ .task = parent.id, .work = id });
                    if (controller and parent.terminal() and child.value.cancellation == null and child.value.schedule != .parked) {
                        try self.parkWorkspaceOnClose(a, parent.id, id);
                        self.subjectRemove(.{ .task = parent.id, .work = id });
                        return true;
                    }
                    continue;
                }
                if (child.value.cancellation != null and
                    (child.value.schedule != .parked or !try self.workspaceCancellationPending(a, parent.id, id)))
                {
                    if (child.value.schedule != .parked) try self.subjectAdd(.{ .task = parent.id, .work = id });
                    continue;
                }
                const operation_id = try std.fmt.allocPrint(a, "task-cancel-{s}-{d}", .{ std.fmt.bytesToHex(id, .lower), child.value.control_revision });
                defer a.free(operation_id);
                _ = try self.workspaceControl(a, operation_id, parent.id, id, child.value.execution_revision, child.value.control_revision, .{ .cancel = parent.cancellation.? });
                return true;
            }
            return false;
        }

        // Only a newer parent cancellation overrides an explicit child park.
        // Capture and execution publications do not acknowledge that intent.
        fn workspaceCancellationPending(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !bool {
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq DESC", &.{.{ .blob = &task_id }});
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
                const bytes = try self.store().object(a, ref, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value != .control or (command.value.control.command != .park and command.value.control.command != .cancel)) continue;
                return false;
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
            const bytes = (try self.store().receipt(a, &key, request)) orelse {
                if (self.workspace_replay != null) return error.InvalidArchive;
                return null;
            };
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Receipt, a, bytes);
            defer decoded.deinit();
            var bound_task = try self.task(a, decoded.value.task);
            defer bound_task.deinit();
            var saved = decoded.value;
            saved.client_operation_id = .{ .bytes = try a.dupe(u8, saved.client_operation_id.bytes) };
            if (self.workspace_replay != null and saved.method != .workspace) return error.InvalidArchive;
            return .{ .receipt = saved, .replayed = if (self.workspace_replay) |replay_only| replay_only.replayed else true };
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
            return self.publicationEvent(value, kind, bytes, &.{}, null);
        }
        fn publicationEvent(self: *Self, value: *state.Task, kind: state.EventType, bytes: []const u8, publications: []const state.WorkPublication, command: ?state.Reference) !void {
            value.event_high = try std.math.add(u64, value.event_high, 1);
            try self.store().putEvent(.{ .task = value.id, .seq = value.event_high, .revision = value.revision, .kind = kind, .data = .{ .bytes = bytes }, .workspace_publications = .{ .items = publications }, .workspace_command = command });
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
                if (i < self.cleanup_cursor) self.cleanup_cursor -= 1;
                if (self.cleanup_cursor >= self.owned.items.len) self.cleanup_cursor = 0;
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
        fn rootIdentity(id: state.TaskId) state.Digest {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update("protean.controller.outer.v1\x00");
            hash.update(&id);
            var result: state.Digest = undefined;
            hash.final(&result);
            return result;
        }
        fn rootProvenance(value: state.Task) kosmos.RuntimeCapsule.Provenance {
            return .{ .execution = rootIdentity(value.id), .custody = storage.digest(&value.id), .publication = .{ .digest = value.checkpoint.digest, .bytes = value.checkpoint.bytes } };
        }
        fn rootOperation(self: *Self, a: std.mem.Allocator, value: state.Task) !?contracts.Decoded(state.RootOperation) {
            const bytes = try self.store().recordBytes(a, "root_operation", rootIdentity(value.id), value.id) orelse return null;
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.RootOperation, a, bytes);
            errdefer decoded.deinit();
            if (!std.meta.eql(decoded.value.id, rootIdentity(value.id)) or !std.meta.eql(decoded.value.task, value.id) or decoded.value.execution_revision != value.execution_revision) return error.InvalidArchive;
            return decoded;
        }
        fn putRootOperation(self: *Self, a: std.mem.Allocator, value: state.RootOperation) !void {
            if (try self.store().recordBytes(a, "root_operation", value.id, value.task)) |bytes| {
                a.free(bytes);
                try self.store().putRecord(state.RootOperation, "root_operation", value.id, value.task, value);
            } else try self.store().createRecord(state.RootOperation, "root_operation", value.id, value.task, value);
        }
        fn rootConsumed(self: *Self, a: std.mem.Allocator, value: state.Task, control: data.invocation.Control) !?occurrence.Occurrence {
            if (control != .reply and control != .cancel) return null;
            const id = value.current_occurrence orelse return null;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, value.id);
            defer pending.deinit();
            return try occurrence.consumed(pending.value, .{ .id = id, .task = value.id, .request = pending.value.request }, if (control == .cancel) .cancel else .{ .reply = storage.digest(control.reply) }, value.cancellation != null);
        }
        fn retainRootOperation(self: *Self, a: std.mem.Allocator) !void {
            const active = self.active orelse return;
            if (active.work != null or active.root_control == null) return;
            var saved = try self.task(a, active.task);
            defer saved.deinit();
            if (saved.value.execution_revision != active.execution_revision) return error.CorruptState;
            // A completed physical operation has no pending command to freeze.
            // Finish its checkpoint publication before transferring this owner.
            if (active.root_cut_ready) {
                _ = try self.pumpRoot(a, saved.value);
                return;
            }
            const capsule = try active.driver.retainCapsule(rootProvenance(saved.value));
            const dependencies = try capsuleDependencies(a, capsule);
            defer a.free(dependencies);
            const code = try active.driver.runtimeBytes(a);
            defer a.free(code);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(code);
            const pending: state.OuterOperation = .{ .capsule = try self.store().putObject(capsule), .dependencies = .{ .items = dependencies }, .control = try self.store().putObject(active.root_control.?), .guest_quantum = active.root_quantum };
            try self.putRootOperation(a, .{ .id = rootIdentity(active.task), .task = active.task, .execution_revision = active.execution_revision, .pending = pending });
            try self.namespace.commit("controller.outer-suspend");
            self.active.?.outer_operation = pending.capsule;
        }
        fn validateRootOperation(self: *Self, a: std.mem.Allocator, value: state.Task, saved: state.RootOperation) !void {
            if (!std.meta.eql(saved.id, rootIdentity(value.id)) or !std.meta.eql(saved.task, value.id) or saved.execution_revision != value.execution_revision) return error.InvalidArchive;
            const pending = saved.pending orelse return;
            if (value.terminal() or pending.guest_quantum > 256) return error.InvalidArchive;
            const bytes = try self.store().object(a, pending.capsule, null);
            defer a.free(bytes);
            var envelope = try kosmos.RuntimeCapsule.read(a, bytes);
            defer envelope.deinit();
            const record_value = envelope.value.record;
            if (!std.meta.eql(record_value.provenance, rootProvenance(value)) or record_value.kind != .outer_execution or record_value.operation != .advance or
                !std.meta.eql(record_value.guest.image.digest, value.image.digest) or record_value.guest.image.bytes != value.image.bytes) return error.InvalidArchive;
            if (pending.dependencies.items.len != record_value.dependencies.len) return error.InvalidArchive;
            for (pending.dependencies.items, record_value.dependencies) |ref, expected| if (!std.meta.eql(ref.digest, expected.digest) or ref.bytes != expected.bytes) return error.InvalidArchive;
            const image = try self.store().object(a, value.image, null);
            defer a.free(image);
            var prepared = try self.program.prepare(a, image);
            defer prepared.deinit();
            if (!std.meta.eql(record_value.artifact.digest, prepared.runtime.identity) or record_value.artifact.bytes != prepared.runtime.core.?.encoded_length) return error.InvalidArchive;
            const code = try self.store().object(a, .{ .digest = record_value.artifact.digest, .bytes = record_value.artifact.bytes }, null);
            defer a.free(code);
            // Check the exact accepted control against the original guest cut
            // and the acquired occurrence, independently of the outer machine.
            const control_bytes = try self.store().object(a, pending.control, null);
            defer a.free(control_bytes);
            var accepted = try contracts.decodeOwned(data.invocation.Control, a, control_bytes);
            defer accepted.deinit();
            var command = try kosmos.RuntimeCapsule.readCommand(a, envelope.value.command);
            defer command.deinit();
            if (command.value != .advance or command.value.advance.quantum != pending.guest_quantum or (pending.guest_quantum == 0 and accepted.value != .reply)) return error.InvalidArchive;
            const actual = command.value.advance.control;
            switch (accepted.value) {
                .none => if (actual != .none or value.outcome_kind != .progressed or value.current_occurrence != null) return error.InvalidArchive,
                .resume_yield => if (actual != .resume_yield or value.outcome_kind != .yielded or value.current_occurrence != null) return error.InvalidArchive,
                .cancel => |reason| {
                    const cancellation = value.cancellation orelse return error.InvalidArchive;
                    if (value.cancellation_applied or reason != .text or !same(reason.text, cancellation.bytes) or actual != .cancel or !data.record.equal(data.invocation.Reason, reason, actual.cancel)) return error.InvalidArchive;
                    _ = try self.rootConsumed(a, value, accepted.value);
                },
                .reply => |reply| {
                    if (actual != .answer or value.outcome_kind != .requested or value.current_occurrence == null) return error.InvalidArchive;
                    var response = try data.invocation.decode(data.invocation.Result, a, reply);
                    defer response.deinit();
                    var occurrence_value = try self.record(occurrence.Occurrence, a, "occurrence", value.current_occurrence.?, value.id);
                    defer occurrence_value.deinit();
                    const prior = occurrence_value.value;
                    if (prior.work != null or prior.state != .settled_reply or !std.meta.eql(prior.state.settled_reply.reply, storage.digest(reply)) or !std.meta.eql(prior.request, response.value.request_identity) or !same(actual.answer, response.value.value)) return error.InvalidArchive;
                    _ = try self.rootConsumed(a, value, accepted.value);
                },
            }
            const Inspect = struct {
                fn claim(_: *anyopaque, _: kosmos.RuntimeCapsule.Reference, _: kosmos.RuntimeCapsule.Record, _: kosmos.RuntimeCapsule.Reference) !void {}
            };
            var context: u8 = 0;
            var candidate = try kosmos.RuntimeCapsule.restore(a, &prepared.guest, &prepared.runtime, bytes, .{ .context = &context, .claim = Inspect.claim });
            defer candidate.deinit();
        }

        fn retire(self: *Self, a: std.mem.Allocator) !void {
            try self.retainRootOperation(a);
            if (self.active) |active| {
                try active.driver.retire();
                try active.driver.destroy();
                if (active.root_control) |bytes| self.allocator.free(bytes);
                self.active = null;
            }
        }
        fn resident(self: *Self, a: std.mem.Allocator, value: state.Task) !*evaluator.Driver {
            try self.compatible(value);
            if (self.active) |active| {
                if (active.work == null and same(&active.task, &value.id) and active.execution_revision == value.execution_revision) return active.driver;
                try self.retire(a);
            }
            var pending = try self.rootOperation(a, value);
            defer if (pending) |*saved| saved.deinit();
            const root_control = if (pending != null and pending.?.value.pending != null) try self.store().object(self.allocator, pending.?.value.pending.?.control, null) else null;
            errdefer if (root_control) |bytes| self.allocator.free(bytes);
            const driver = if (pending != null and pending.?.value.pending != null) restored: {
                const operation_value = pending.?.value.pending.?;
                try self.validateRootOperation(a, value, pending.?.value);
                const bytes = try self.store().object(a, operation_value.capsule, null);
                defer a.free(bytes);
                const Owner = struct {
                    task: state.Task,
                    reference: state.Reference,
                    fn claim(context: *anyopaque, ref: kosmos.RuntimeCapsule.Reference, record_value: kosmos.RuntimeCapsule.Record, _: kosmos.RuntimeCapsule.Reference) !void {
                        const owner: *@This() = @ptrCast(@alignCast(context));
                        if (!std.meta.eql(ref.digest, owner.reference.digest) or ref.bytes != owner.reference.bytes or
                            !std.meta.eql(record_value.provenance, rootProvenance(owner.task))) return error.InvalidArchive;
                    }
                };
                var owner: Owner = .{ .task = value, .reference = operation_value.capsule };
                var runtime = try self.program.retainRuntime();
                defer runtime.deinit();
                break :restored try evaluator.Driver.openCapsule(self.allocator, self.assets.image, &runtime, bytes, .{ .context = &owner, .claim = Owner.claim });
            } else restored: {
                const checkpoint = try self.store().object(a, value.checkpoint, null);
                defer a.free(checkpoint);
                break :restored try evaluator.Driver.start(self.allocator, self.program, .{ .state = checkpoint });
            };
            self.active = .{ .task = value.id, .execution_revision = value.execution_revision, .driver = driver, .root_control = root_control };
            if (pending) |saved| if (saved.value.pending) |operation_value| {
                self.active.?.root_quantum = operation_value.guest_quantum;
                self.active.?.outer_operation = operation_value.capsule;
            };
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
            try self.createCustody(a, task_id, null);
            try self.store().putEvent(.{ .task = task_id, .seq = 1, .revision = 1, .kind = .accepted, .data = .{ .bytes = "{}" } });
            const admitted = try self.receipt(a, .submit, id, request, value, .accepted, null, null);
            try self.namespace.commit("task.submit");
            self.runnableAppendAssumeCapacity(task_id);
            self.claim(task_id);
            return admitted;
        }

        pub fn requestCancel(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, reason: []const u8) !Admission {
            try self.requireCustody(a, task_id, null);
            if (reason.len > 256 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidParams;
            const request = try cancelDigest(a, task_id, .{ .bytes = reason });
            if (try self.replay(a, id, request)) |prior| return prior;
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            const previous = value.revision;
            const needs_cancellation = !value.terminal() or !try self.associatedWorkDisposed(a, task_id);
            const queue_root = self.work == null or self.work.?.subject_work != null or !same(&self.work.?.task, &task_id);
            const executable = compatible: {
                self.compatible(value) catch |err| switch (err) {
                    error.IncompatibleProfile => break :compatible false,
                };
                break :compatible true;
            };
            var cleanup: std.ArrayList(workspace.Subject) = .empty;
            defer cleanup.deinit(a);
            if (needs_cancellation) {
                try self.ensureOwnershipCapacity(task_id);
            }
            if (needs_cancellation and executable) {
                const children = try self.workspaceIds(a, task_id);
                defer a.free(children);
                for (children) |child_id| {
                    if (!try self.hasLocalCustody(a, task_id, child_id)) continue;
                    var child = try self.retainedWorkspaceWork(a, task_id, child_id);
                    defer child.deinit();
                    // Reopening requires explicit ownership. A new cancel
                    // can continue already admitted cleanup even when the root
                    // has a result and ordinary task resume is unavailable.
                    if (!child.value.terminal() and child.value.cancellation != null and child.value.schedule != .parked)
                        try cleanup.append(a, .{ .task = task_id, .work = child_id });
                }
            }
            try self.runnable.ensureUnusedCapacity(self.allocator, cleanup.items.len + 1);
            value.revision = try std.math.add(u64, previous, 1);
            if (needs_cancellation and value.cancellation == null) value.cancellation = .{ .bytes = reason };
            if (needs_cancellation and !executable) {
                value.blocker = .incompatible_profile;
                value.schedule = .parked;
            } else if (executable) {
                if (value.blocker == .incompatible_profile) value.blocker = null;
                if (!value.terminal() and queue_root) value.schedule = .queued;
            }
            try self.store().begin();
            defer self.store().rollback();
            try self.event(&value, .cancellation_requested, "{}");
            const admitted = try self.receipt(a, .cancel, id, request, value, .cancellation_requested, null, null);
            try self.persist(a, value, previous, "task.cancel", .preserve);
            // The receipt now survives retries. If applying its cancellation
            // fails, only restart recovery may resume this owner's work.
            errdefer self.store().fence();
            // Cancellation intent survives a different launch configuration,
            // but it grants no authority to run the root or retained cleanup.
            if (needs_cancellation and !executable) {
                self.claim(task_id);
                return admitted;
            }
            for (cleanup.items) |subject| self.subjectAddAssumeCapacity(subject);
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
            if (needs_cancellation) {
                if (queue_root) try self.runnableAdd(task_id);
                self.claim(task_id);
            }
            return admitted;
        }

        pub fn resumeTask(self: *Self, a: std.mem.Allocator, id: []const u8, task_id: state.TaskId, expected: u64) !Admission {
            try self.requireCustody(a, task_id, null);
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
            try self.requireCustody(a, task_id, null);
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
            try self.requireCustody(a, task_id, null);
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
            try self.requireCustody(a, task_id, null);
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
            if (try self.pumpPlacement(a)) return .progressed;
            if (try self.pumpOwnedCleanup(a)) return .progressed;
            // Scan one round, without charging or preparing blocked leaves.
            // Each actual transition yields back to the host control channel.
            const count = self.runnable.items.len;
            for (0..count) |_| {
                if (self.runnable.items.len == 0) break;
                const id = self.runnable.items[self.runnable_cursor];
                self.runnable_cursor += 1;
                if (self.runnable_cursor == self.runnable.items.len) self.runnable_cursor = 0;
                const step = if (id.work) |work_id| try self.pumpWorkspace(a, id.task, work_id) else try self.pumpTask(a, id.task);
                if (step != .idle) return step;
            }
            return .idle;
        }

        // Cancellation is a retained obligation, independent of root runnable
        // membership. Custody changes need no producer-specific wake-up.
        fn pumpOwnedCleanup(self: *Self, a: std.mem.Allocator) !bool {
            const count = self.owned.items.len;
            for (0..count) |_| {
                if (self.owned.items.len == 0) break;
                const id = self.owned.items[self.cleanup_cursor];
                self.cleanup_cursor = (self.cleanup_cursor + 1) % self.owned.items.len;
                const controller = try self.hasLocalCustody(a, id, null);
                var parent = try self.task(a, id);
                defer parent.deinit();
                self.compatible(parent.value) catch continue;
                if (try self.settleWorkspaceOne(a, parent.value, controller)) return true;
                if (!controller) continue;
                if (parent.value.cancellation != null and !parent.value.terminal() and parent.value.schedule != .parked) try self.runnableAdd(id);
                if (parent.value.terminal() and try self.taskCleanupComplete(a, parent.value)) self.unclaim(id);
            }
            return false;
        }

        fn pumpTask(self: *Self, a: std.mem.Allocator, id: state.TaskId) !Step {
            self.requireCustody(a, id, null) catch |err| {
                if (err != error.CustodyNotLocal) return err;
                self.runnableRemove(id);
                return .idle;
            };
            var decoded = try self.task(a, id);
            defer decoded.deinit();
            const value = decoded.value;
            if (value.terminal()) {
                self.runnableRemove(id);
                if (try self.taskCleanupComplete(a, value)) self.unclaim(id);
                return .progressed;
            }
            self.compatible(value) catch return self.blocked(a, value, .incompatible_profile);
            if (self.active) |active| {
                if (active.work == null and std.meta.eql(active.task, id) and active.root_control != null) return self.pumpRoot(a, value);
            }
            var saved_operation = try self.rootOperation(a, value);
            defer if (saved_operation) |*saved| saved.deinit();
            if (saved_operation != null and saved_operation.?.value.pending != null) return self.pumpRoot(a, value);
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
            try self.requireCustody(a, initial.id, null);
            const driver = try self.resident(a, initial);
            const quantum: u64 = if (control == .reply and initial.cancellation != null and !initial.cancellation_applied) 0 else 256;
            _ = consumed;
            const encoded_control = try contracts.encodeOwned(data.invocation.Control, self.allocator, control);
            driver.beginAdvance(control, quantum) catch |err| {
                self.allocator.free(encoded_control);
                return err;
            };
            self.active.?.root_control = encoded_control;
            self.active.?.root_quantum = quantum;
            return self.pumpRoot(a, initial);
        }

        fn pumpRoot(self: *Self, a: std.mem.Allocator, initial: state.Task) anyerror!Step {
            const driver = try self.resident(a, initial);
            var decoded = try contracts.decodeOwned(data.invocation.Control, a, self.active.?.root_control orelse return error.CorruptState);
            defer decoded.deinit();
            const control = decoded.value;
            const consumed = try self.rootConsumed(a, initial, control);
            // Physical pumping is transactional. An allocation failure leaves
            // the accepted operation live and retryable without fencing storage.
            if (!self.active.?.root_cut_ready) {
                var progress = try driver.pump(65536);
                defer progress.deinit();
                if (progress == .suspended) return .progressed;
                if (progress != .event or progress.event.value != .cut) return error.InvalidRuntimeProgress;
                self.active.?.root_cut_ready = true;
            }
            // Publication is transactional too. Keep the completed-cut phase
            // on failure so retry cannot apply the accepted command twice.
            const publication = try driver.drive(a, .none, 0);
            self.allocator.free(self.active.?.root_control.?);
            self.active.?.root_control = null;
            self.active.?.root_cut_ready = false;
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
            // Terminal state has no remaining guest cleanup. Its checkpoint
            // and outcome are now owned by the transaction, so release the
            // physical evaluator before materializing potentially much larger
            // client JSON. Failure below still fences the uncommitted owner;
            // restart uses the prior durable cut and acquired reply.
            if (outcome.value == .completed or outcome.value == .failed or outcome.value == .cancelled) {
                try driver.close();
                try driver.destroy();
                self.active = null;
            }
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
            try self.putRootOperation(a, .{ .id = rootIdentity(value.id), .task = value.id, .execution_revision = value.execution_revision, .pending = null });
            try self.persist(a, value, initial.revision, "world.advance", .preserve);
            if (self.active) |*active| {
                active.outer_operation = null;
                active.execution_revision = value.execution_revision;
            }
            if (value.terminal()) {
                self.runnableRemove(value.id);
                const children = try self.workspaceIds(a, value.id);
                defer a.free(children);
                for (children) |child_id| {
                    if (!try self.hasLocalCustody(a, value.id, child_id)) continue;
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
        fn effectSchedule(self: *Self, a: std.mem.Allocator, parent: *state.Task, pending: occurrence.Occurrence, schedule: state.Schedule, blocker: ?state.Blocker) !void {
            const id = pending.work orelse return;
            var work = try self.retainedWorkspaceWork(a, parent.id, id);
            defer work.deinit();
            if (!std.meta.eql(work.value.current_occurrence, pending.id)) return error.StaleOccurrence;
            // Completion makes work eligible; it does not revoke a later park.
            if (schedule != .queued or work.value.schedule != .parked) work.value.schedule = schedule;
            work.value.blocker = blocker;
            work.value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try self.store().putRecord(workspace.Work, "workspace_work", id, parent.id, work.value);
            const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{std.fmt.bytesToHex(id, .lower)});
            defer a.free(event_data);
            const observed = try self.freezeWorkspaceWork(a, parent.id, try wp.reference(a, .work, id), true);
            try self.publicationEvent(parent, .workspace_progress, event_data, &.{try workPublication(a, observed)}, null);
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
            try self.effectSchedule(a, &parent, pending, .parked, reason);
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
                .workspace => return self.dispatchWorkspace(a, initial, dispatched, entry, request.value.binding.payload),
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
                    return self.dispatchAcquisition(a, initial, dispatched, entry, request_bytes, prepared, .environment);
                },
            }
        }

        fn dispatchAcquisition(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, entry: registry.Entry, request_bytes: []const u8, prepared: ?[]const u8, operation_kind: state.AttemptOperation) !Step {
            try self.requireCustody(a, initial.id, pending.work);
            if (self.work != null) return .idle;
            const subject = try self.occurrenceSubject(a, initial, pending);
            // Consume the already-authorized transition. Preparation and
            // settlement cannot reconstruct a different cancellation policy.
            const attempt = switch (pending.state) {
                .dispatching => |dispatching| dispatching.id,
                else => return error.UnsettledOccurrence,
            };
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
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, pending);
            try self.effectSchedule(a, &value, pending, .active, null);
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
            try self.effectSchedule(a, &value, saved.value, .queued, null);
            try self.persist(a, value, previous, "effect.capture", .preserve);
            try self.wakeOccurrence(a, value, saved.value);
        }

        fn interpretCapture(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence) !Step {
            try self.requireCustody(a, initial.id, pending.work);
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
            try self.effectSchedule(a, &value, pending, .queued, null);
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
            try self.currentWork(work);
            try self.requireCustody(a, work.task, work.subject_work);
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
            try self.requireCustody(a, work.task, work.subject_work);
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
            try self.effectSchedule(a, &value, saved.value, .queued, null);
            try self.persist(a, value, previous, "effect.acquire", .preserve);
            try self.wakeOccurrence(a, value, saved.value);
        }
        pub fn unknown(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try self.currentWork(work);
            try self.requireCustody(a, work.task, work.subject_work);
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
            try self.effectSchedule(a, &value, saved.value, .parked, .unavailable_environment);
            try self.persist(a, value, previous, "effect.unknown", .preserve);
            self.subjectRemove(.{ .task = work.task, .work = work.subject_work });
            try self.retire(a);
        }

        pub fn notSent(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try self.currentWork(work);
            try self.requireCustody(a, work.task, work.subject_work);
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
            try self.effectSchedule(a, &value, saved.value, if (cancelling) .queued else .parked, if (cancelling) null else .unavailable_environment);
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
                const protocol: @import("workspace_driver.zig").Protocol = .{
                    .class = port.interface.class,
                    .command_schema = request.binding.resume_schema,
                    .payload_schema = request.binding.payload_schema,
                    .payload = request.binding.payload,
                };
                const command = try protocol.decode(a, result.value.value);
                if (answer.value.command == .finish) {
                    if (command != .finish or answer.value.input != null) return error.InvalidArchive;
                } else {
                    if (command != .resume_value) return error.InvalidArchive;
                    const input = answer.value.input orelse return error.InvalidArchive;
                    const origin = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, input.digest));
                    if (!std.meta.eql(origin.artifact, input) or !std.meta.eql(origin.schema, port.interface.argument)) return error.InvalidArchive;
                    const input_bytes = command.resume_value;
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
                        if (try self.store().recordBytes(temporary, "workspace_reply", saved.id, value.id)) |bytes| {
                            try requireArchiveRecord(records, .workspace_reply, saved.id);
                            var evidence = try contracts.decodeOwned(workspace.ReplyObservation, temporary, bytes);
                            defer evidence.deinit();
                            try self.validateWorkspaceReply(temporary, value, saved, entry, request.value, evidence.value, reply_value.?, records);
                        } else {
                            try requireArchiveRecord(records, .attempt, reply.attempt);
                            try requireArchiveRecord(records, .capture, reply.attempt);
                            var attempt = try self.record(state.Attempt, temporary, "attempt", reply.attempt, value.id);
                            defer attempt.deinit();
                            if (attempt.value.operation != .workspace_build or !std.meta.eql(attempt.value.occurrence, saved.id)) return error.InvalidArchive;
                        }
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

        fn placementPeer(self: *Self, peer_name: []const u8) !@import("placement.zig").Peer {
            const config = self.profile.placement orelse return error.UnsupportedCapability;
            for (config.peers) |peer| if (same(peer.name, peer_name)) return peer;
            return error.Denied;
        }

        pub fn placementRequest(self: *Self, a: std.mem.Allocator, request: @import("placement.zig").Request) !json.Value {
            const p = @import("placement.zig");
            switch (request) {
                .identify => return values.toJson(struct { site: p.Site, native_build: state.Digest, resource_binding: state.Digest }, a, .{ .site = try self.placementSite(), .native_build = self.profile.runtime_identity, .resource_binding = try self.profile.resourceIdentity(a, self.application.image_identity) }),
                .challenge => |nonce| return values.toJson(p.Signed(p.Hello), a, try p.sign(p.Hello, a, (self.profile.placement orelse return error.UnsupportedCapability).signing_key, .{ .site = try self.placementSite(), .native_build = self.profile.runtime_identity, .challenge = nonce })),
                .status => |subject| return values.toJson(?p.Custody, a, try self.placementStatus(a, subject)),
                .cut => |subject| return values.toJson(p.Cut, a, try self.placementCut(a, subject)),
                .compatibility => |subject| return values.toJson(p.Compatibility, a, try self.placementCompatibility(a, subject)),
                .freeze => |v| return values.toJson(p.Intent, a, try self.placementFreeze(a, v.subject, v.peer.bytes, v.expected, v.transfer)),
                .move => |v| return values.toJson(p.Signed(p.Decision), a, try self.placementMove(a, v.subject, v.peer.bytes, v.expected, v.transfer)),
                .offer => |v| return values.toJson(p.Signed(p.Offer), a, try self.placementOffer(a, v.subject, v.peer.bytes, v.path.bytes)),
                .accept => |v| return values.toJson(p.Signed(p.Decision), a, try self.placementAccept(a, v.operation.bytes, v.peer.bytes, v.offer, v.path.bytes)),
                .stage => |v| {
                    try self.allowed();
                    const peer = try self.placementPeer(v.peer.bytes);
                    try p.verify(p.Offer, a, v.offer, peer.site);
                    if (!std.meta.eql(v.offer.value.intent.destination, try self.placementSite())) return error.InvalidTransfer;
                    if (peer.archive_limit) |limit| if (v.offer.value.archive_bytes > limit) return error.Capacity;
                    return values.toJson(u64, a, try @import("placement_stage.zig").write(a, try self.placementDirectory(a), v.offer.value, v.offset, v.bytes.bytes));
                },
                .accept_staged => |v| {
                    const path = try @import("placement_stage.zig").path(a, try self.placementDirectory(a), v.offer.value);
                    defer a.free(path);
                    return values.toJson(p.Signed(p.Decision), a, try self.placementAccept(a, v.operation.bytes, v.peer.bytes, v.offer, path));
                },
                .refuse => |v| return values.toJson(p.Signed(p.Decision), a, try self.placementRefuse(a, v.peer.bytes, v.offer, v.reason)),
                .decision => |v| try self.placementApplyDecision(a, v.subject, v.decision),
                .abort_unsent => |v| try self.placementAbortUnsent(a, v.subject, v.transfer),
                .withdraw => |v| try self.placementWithdraw(a, v.task, v.transfer),
                .control => |v| {
                    const bytes = try self.placementControl(a, v.operation.bytes, v.task, v.command);
                    defer a.free(bytes);
                    var signed = try contracts.decodeOwned(p.Signed(p.Control), a, bytes);
                    defer signed.deinit();
                    return values.toJson(p.Signed(p.Control), a, signed.value);
                },
                .execute_control => |v| {
                    const bytes = try self.placementExecuteControl(a, v.peer.bytes, v.control);
                    defer a.free(bytes);
                    var signed = try contracts.decodeOwned(p.Signed(p.Report), a, bytes);
                    defer signed.deinit();
                    return values.toJson(p.Signed(p.Report), a, signed.value);
                },
                .resolve_control => |v| {
                    const bytes = try self.placementResolveControl(a, v.peer.bytes, v.control, v.route.items);
                    defer a.free(bytes);
                    var resolution = try contracts.decodeOwned(p.ControlResolution, a, bytes);
                    defer resolution.deinit();
                    return values.toJson(p.ControlResolution, a, resolution.value);
                },
                .report => |v| try self.placementApplyReport(a, v.task, v.control, v.report),
                .follow_controller => |v| try self.placementFollowController(a, v.source.bytes, v.destination.bytes, v.offer, v.decision),
                .follow_controller_proof => |v| try self.placementFollowController(a, (try self.placementPeerAt(v.offer.value.intent.source)).name, (try self.placementPeerAt(v.decision.value.destination)).name, v.offer, v.decision),
            }
            return json.object();
        }

        fn placementDirectory(self: *Self, a: std.mem.Allocator) ![]const u8 {
            const configured = self.profile.placement orelse return error.UnsupportedCapability;
            const path = configured.transport_directory orelse return error.UnsupportedCapability;
            const c = @import("native_c");
            const dir = try @import("namespace.zig").openDirectory(a, path, false, true);
            defer _ = c.close(dir);
            var spool: c.struct_protean_native_stat = undefined;
            var owner: c.struct_protean_native_stat = undefined;
            if (c.protean_native_fstat(dir, &spool) != 0 or c.protean_native_fstat(self.namespace.directory, &owner) != 0) return error.StorageUnavailable;
            var cursor = c.dup(dir);
            if (cursor < 0) return error.StorageUnavailable;
            defer _ = c.close(cursor);
            while (true) {
                if (spool.st_dev == owner.st_dev and spool.st_ino == owner.st_ino) return error.UnsafeStatePath;
                const parent = c.openat(cursor, "..", c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
                if (parent < 0) return error.StorageUnavailable;
                var ancestor: c.struct_protean_native_stat = undefined;
                if (c.protean_native_fstat(parent, &ancestor) != 0) {
                    _ = c.close(parent);
                    return error.StorageUnavailable;
                }
                if (ancestor.st_dev == spool.st_dev and ancestor.st_ino == spool.st_ino) {
                    _ = c.close(parent);
                    break;
                }
                _ = c.close(cursor);
                cursor = parent;
                spool = ancestor;
            }
            return path;
        }

        fn placementPeerAt(self: *Self, site: @import("placement.zig").Site) !@import("placement.zig").Peer {
            const config = self.profile.placement orelse return error.UnsupportedCapability;
            for (config.peers) |peer| if (std.meta.eql(peer.site, site)) return peer;
            return error.Denied;
        }

        fn placementSubject(task_id: state.TaskId, selected: wc.PlacementSubject) !@import("placement.zig").Subject {
            return .{ .task = task_id, .work = switch (selected) {
                .controller => null,
                .work => |ref| try wp.identity(ref, .work),
            } };
        }

        fn placementReplyCopy(a: std.mem.Allocator, reply: wc.Reply) !wc.Reply {
            var result = reply;
            result.observation_json.bytes = try a.dupe(u8, reply.observation_json.bytes);
            inline for (.{ "selected_view", "program", "evidence" }) |field| if (@field(result, field)) |*ref| {
                ref.id.bytes = try a.dupe(u8, ref.id.bytes);
            };
            return result;
        }

        fn placementQueue(self: *Self, task_id: state.TaskId, id: state.Digest, kind: PlacementKind) void {
            if (self.placement_job) |running| if (std.meta.eql(running.id, id) and running.kind == kind) return;
            for (self.placement_pending.items) |pending| if (std.meta.eql(pending.id, id) and pending.kind == kind) return;
            self.placement_pending.appendAssumeCapacity(.{ .task = task_id, .id = id, .kind = kind });
        }

        fn placementFailure(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest, kind: PlacementKind, err: anyerror) !void {
            const p = @import("placement.zig");
            try self.store().begin();
            defer self.store().rollback();
            switch (kind) {
                .move => {
                    var saved = try self.record(p.Move, a, "placement_move", id, task_id);
                    defer saved.deinit();
                    saved.value.last_error = try name(@errorName(err));
                    try self.store().putRecord(p.Move, "placement_move", id, task_id, saved.value);
                },
                .control => {
                    var saved = try self.record(p.ControlRecord, a, "placement_control", id, task_id);
                    defer saved.deinit();
                    saved.value.last_error = try name(@errorName(err));
                    try self.store().putRecord(p.ControlRecord, "placement_control", id, task_id, saved.value);
                },
            }
            try self.namespace.commit("placement.transport-blocked");
        }

        fn placementStartJob(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest, kind: PlacementKind) !?*@import("placement_job.zig").Job {
            const p = @import("placement.zig");
            const jobs = @import("placement_job.zig");
            switch (kind) {
                .move => {
                    var saved = try self.record(p.Move, a, "placement_move", id, task_id);
                    defer saved.deinit();
                    if (!std.meta.eql(saved.value.owner, try self.placementSite())) return error.CustodyNotLocal;
                    if (saved.value.decision != null or saved.value.cancelled) return null;
                    const subject = saved.value.subject;
                    const prior = try self.placementStatus(a, subject);
                    if (prior) |custody| if (custody.intent) |intent| {
                        if (std.meta.eql(intent.transfer, id) and custody.decision != null) {
                            saved.value.decision = custody.decision;
                            saved.value.last_error = null;
                            try self.store().begin();
                            defer self.store().rollback();
                            try self.store().putRecord(p.Move, "placement_move", id, task_id, saved.value);
                            try self.namespace.commit("placement.move-recovered");
                            return null;
                        }
                    };
                    if (saved.value.withdraw_requested) {
                        const custody = prior orelse return error.InvalidTransfer;
                        const offer = custody.offer orelse return error.InvalidTransfer;
                        if (!std.meta.eql(offer.value.intent.transfer, id)) return error.InvalidTransfer;
                        const peer = try self.placementPeer(saved.value.request.site.bytes);
                        const input: jobs.Input = .{ .withdraw = offer };
                        const bytes = try contracts.encodeOwned(jobs.Input, a, input);
                        defer a.free(bytes);
                        try self.placementAuthorizeMessage(a, peer, subject, bytes);
                        return try jobs.Job.start(self.allocator, self.io, peer, input);
                    }
                    const expected = if (prior) |custody| expected: {
                        if (custody.intent) |intent| if (std.meta.eql(intent.transfer, id)) break :expected intent.cut;
                        if (custody.epoch != saved.value.request.custody_epoch) return error.StaleCustody;
                        break :expected try self.placementCut(a, subject);
                    } else try self.placementCut(a, subject);
                    _ = try self.placementFreeze(a, subject, saved.value.request.site.bytes, expected, id);
                    const path = try std.fmt.allocPrint(a, "{s}/outgoing-{s}.par", .{ try self.placementDirectory(a), std.fmt.bytesToHex(id, .lower) });
                    defer a.free(path);
                    const offer = try self.placementOffer(a, subject, saved.value.request.site.bytes, path);
                    return try jobs.Job.start(self.allocator, self.io, try self.placementPeer(saved.value.request.site.bytes), .{ .move = .{ .offer = offer, .path = .{ .bytes = path } } });
                },
                .control => {
                    var saved = try self.record(p.ControlRecord, a, "placement_control", id, task_id);
                    defer saved.deinit();
                    if (saved.value.report != null) return null;
                    try self.requireCustody(a, task_id, null);
                    if (!std.meta.eql(saved.value.control.value.controller, try self.placementSite())) return error.CustodyNotLocal;
                    const lineage = try @import("placement_journal.zig").controllerLineage(self.store(), a, task_id);
                    defer a.free(lineage);
                    const head = try p.routeHead(a, saved.value.control.value, saved.value.route.items);
                    const peer = try self.placementPeerAt(head.site);
                    const input: jobs.Input = .{ .control = .{ .message = saved.value.control, .route = saved.value.route, .lineage = .{ .items = lineage } } };
                    const bytes = try contracts.encodeOwned(jobs.Input, a, input);
                    defer a.free(bytes);
                    try self.placementAuthorizeMessage(a, peer, saved.value.control.value.subject, bytes);
                    return try jobs.Job.start(self.allocator, self.io, peer, input);
                },
            }
        }

        fn pumpPlacement(self: *Self, a: std.mem.Allocator) !bool {
            const p = @import("placement.zig");
            if (self.placement_job) |running| {
                if (!running.job.finished.load(.acquire)) return false;
                defer {
                    running.job.deinit();
                    self.placement_job = null;
                }
                const result = running.job.result catch |err| {
                    try self.placementFailure(a, running.task, running.id, running.kind, err);
                    return true;
                };
                switch (result) {
                    .decision => |decision| {
                        var saved = try self.record(p.Move, a, "placement_move", running.id, running.task);
                        defer saved.deinit();
                        try self.placementApplyDecision(a, saved.value.subject, decision);
                        saved.value.decision = decision;
                        saved.value.last_error = null;
                        try self.store().begin();
                        defer self.store().rollback();
                        try self.store().putRecord(p.Move, "placement_move", running.id, running.task, saved.value);
                        try self.namespace.commit("placement.move-complete");
                    },
                    .report => |bytes| {
                        var resolution = try contracts.decodeOwned(p.ControlResolution, a, bytes);
                        defer resolution.deinit();
                        switch (resolution.value) {
                            .report => |report| try self.placementApplyReport(a, running.task, running.id, report),
                            .next => |next| {
                                // The joined job still occupies placement_job;
                                // enqueue directly after reserving before commit.
                                self.placementFollowExecutor(a, running.task, running.id, next) catch |err| {
                                    if (self.store().fenced or err == error.OutOfMemory or err == error.StorageUnavailable) return err;
                                    try self.placementFailure(a, running.task, running.id, .control, err);
                                };
                            },
                        }
                    },
                }
                return true;
            }
            if (self.placement_pending.items.len == 0 or self.work != null) return false;
            const selected = self.placement_pending.orderedRemove(0);
            const job = self.placementStartJob(a, selected.task, selected.id, selected.kind) catch |err| {
                if (self.store().fenced or err == error.OutOfMemory or err == error.StorageUnavailable) return err;
                try self.placementFailure(a, selected.task, selected.id, selected.kind, err);
                return true;
            };
            if (job) |started| self.placement_job = .{ .task = selected.task, .id = selected.id, .kind = selected.kind, .job = started };
            return true;
        }

        /// Model-selected placement is a native operation with an immutable
        /// signed observation. A move queues transport only after this receipt;
        /// it cannot retire the controller from inside its own callback.
        fn placementModel(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, request: wc.Placement) !wc.Reply {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.requireCustody(a, task_id, null);
            const site = try self.placementSite();
            const id = p.operationId(site, task_id, operation_id, .action);
            if (try self.store().recordBytes(a, "placement_action", id, task_id)) |bytes| {
                defer a.free(bytes);
                var prior = try contracts.decodeOwned(p.ActionRecord, a, bytes);
                defer prior.deinit();
                try p.verify(p.Action, a, prior.value.action, site);
                const wanted = try contracts.encodeOwned(wc.Placement, a, request);
                defer a.free(wanted);
                const actual = try contracts.encodeOwned(wc.Placement, a, prior.value.action.value.request);
                defer a.free(actual);
                if (!same(wanted, actual)) return error.OperationConflict;
                return placementReplyCopy(a, prior.value.action.value.reply);
            }
            if (self.workspace_replay != null) return error.InvalidArchive;
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            var queued: ?struct { id: state.Digest, kind: PlacementKind } = null;
            var new_move: ?p.Move = null;
            var observation = json.object();
            switch (request) {
                .sites => {
                    var sites: std.array_list.Managed(json.Value) = .init(a);
                    for (self.profile.placement.?.peers) |peer| {
                        var item = json.object();
                        try json.put(a, &item, "name", json.string(try a.dupe(u8, peer.name)));
                        try json.put(a, &item, "site", try values.toJson(p.Site, a, peer.site));
                        try json.put(a, &item, "transport", .{ .bool = peer.channel != null });
                        try sites.append(item);
                    }
                    try json.put(a, &observation, "sites", .{ .array = sites });
                },
                .inspect => |selected| {
                    const subject = try placementSubject(task_id, selected);
                    try json.put(a, &observation, "custody", try values.toJson(?p.Custody, a, try self.placementStatus(a, subject)));
                    try json.put(a, &observation, "retained_cut", try values.toJson(p.Cut, a, try self.placementCut(a, subject)));
                },
                .assess => |selected| {
                    const subject = try placementSubject(task_id, selected.subject);
                    const peer = try self.placementPeer(selected.site.bytes);
                    const profiles_match = std.meta.eql(peer.compatibility, try self.placementCompatibility(a, subject)) and std.meta.eql(peer.resource_binding, try self.profile.resourceIdentity(a, self.application.image_identity));
                    try json.put(a, &observation, "compatible", .{ .bool = profiles_match });
                    try json.put(a, &observation, "transport", .{ .bool = peer.channel != null });
                    try json.put(a, &observation, "disclosure", json.string("checked over the exact private closure when staging"));
                    try json.put(a, &observation, "cut", try values.toJson(p.Cut, a, try self.placementCut(a, subject)));
                },
                .move => |selected| {
                    if (selected.operation.bytes.len == 0) return error.InvalidOperation;
                    const peer = try self.placementPeer(selected.site.bytes);
                    if (peer.channel == null) return error.UnsupportedCapability;
                    _ = try self.placementDirectory(a);
                    const move_id = p.operationId(site, task_id, selected.operation.bytes, .move);
                    if (try self.store().recordBytes(a, "placement_move", move_id, task_id)) |bytes| {
                        defer a.free(bytes);
                        var prior = try contracts.decodeOwned(p.Move, a, bytes);
                        defer prior.deinit();
                        const wanted = try contracts.encodeOwned(@TypeOf(selected), a, selected);
                        defer a.free(wanted);
                        const actual = try contracts.encodeOwned(@TypeOf(selected), a, prior.value.request);
                        defer a.free(actual);
                        if (!same(wanted, actual)) return error.OperationConflict;
                        observation = try values.toJson(p.Move, a, prior.value);
                        if (prior.value.decision == null and !prior.value.cancelled) queued = .{ .id = move_id, .kind = .move };
                    } else {
                        const subject = try placementSubject(task_id, selected.subject);
                        try self.requireCustody(a, task_id, subject.work);
                        const custody_value = (try self.placementStatus(a, subject)) orelse p.Custody.initial(subject, site);
                        try custody_value.requireLocal(site);
                        if (custody_value.epoch != selected.custody_epoch) return error.StaleCustody;
                        new_move = .{ .id = move_id, .task = task_id, .owner = site, .action = undefined, .request = selected, .subject = subject, .expected = null };
                        try json.put(a, &observation, "transfer", json.string(try a.dupe(u8, &std.fmt.bytesToHex(move_id, .lower))));
                        try json.put(a, &observation, "status", json.string("queued"));
                        queued = .{ .id = move_id, .kind = .move };
                    }
                },
                .retry, .withdraw => {
                    const selected_operation = if (request == .retry) request.retry.operation else request.withdraw.operation;
                    const move_id = p.operationId(site, task_id, selected_operation.bytes, .move);
                    if (request == .withdraw) try self.placementWithdraw(a, task_id, move_id);
                    var prior = try self.record(p.Move, a, "placement_move", move_id, task_id);
                    defer prior.deinit();
                    if (!std.meta.eql(prior.value.owner, site)) return error.CustodyNotLocal;
                    observation = try values.toJson(p.Move, a, prior.value);
                    if (prior.value.decision == null and !prior.value.cancelled) queued = .{ .id = move_id, .kind = .move };
                },
                .control, .expand => {
                    const expanded = request == .expand;
                    const selected_command: wc.Work = if (expanded) .{ .inspect = .{ .work = request.expand.work } } else request.control.command;
                    const selected_operation = if (expanded) request.expand.operation else request.control.operation;
                    const bytes = try self.placementControlExpanded(a, selected_operation.bytes, task_id, selected_command, if (expanded) .{ .reference = request.expand.reference, .page = request.expand.page } else null, true, null);
                    defer a.free(bytes);
                    var control = try contracts.decodeOwned(p.Signed(p.Control), a, bytes);
                    defer control.deinit();
                    const control_id = p.controlId(control.value.value);
                    var saved = try journal.control(self.store(), a, task_id, control_id) orelse return error.CorruptState;
                    defer saved.deinit();
                    if (saved.value.report) |report| {
                        // Remote references remain owned by that executor.
                        // An observation cannot mint local value/view custody.
                        try json.put(a, &observation, "remote_reply", try values.toJson(wc.Reply, a, report.value.reply));
                    } else {
                        const head = try p.routeHead(a, saved.value.control.value, saved.value.route.items);
                        const peer = try self.placementPeerAt(head.site);
                        if (peer.channel == null) return error.UnsupportedCapability;
                        try json.put(a, &observation, "control", json.string(try a.dupe(u8, &std.fmt.bytesToHex(control_id, .lower))));
                        try json.put(a, &observation, "status", json.string("queued"));
                        try json.put(a, &observation, "last_error", try values.toJson(?state.Name, a, saved.value.last_error));
                        queued = .{ .id = control_id, .kind = .control };
                    }
                },
            }
            const reply: wc.Reply = .{ .disposition = .observed, .observation_json = .{ .bytes = try json.canonical(a, observation) } };
            const signed = try p.sign(p.Action, a, self.profile.placement.?.signing_key, .{ .id = id, .task = task_id, .owner = site, .operation = try name(operation_id), .request = request, .reply = reply });
            try self.store().begin();
            defer self.store().rollback();
            var controller = try journal.custody(self.store(), a, .{ .task = task_id });
            defer if (controller) |*saved| saved.deinit();
            if (controller == null) try self.createCustody(a, task_id, null);
            try self.store().createRecord(p.ActionRecord, "placement_action", id, task_id, .{ .id = id, .task = task_id, .action = signed });
            if (new_move) |*move| {
                move.action = try self.snapshotRecord(p.ActionRecord, a, "placement_action", id, task_id);
                try self.store().createRecord(p.Move, "placement_move", move.id, task_id, move.*);
            }
            try self.namespace.commit("placement.model-action");
            if (queued) |pending| self.placementQueue(task_id, pending.id, pending.kind);
            return reply;
        }

        /// Historical signatures preserve identity; each new disclosure still
        /// needs the launch's current policy. The temporary object lets the
        /// policy inspect the exact bytes, without publishing a new operation.
        fn placementAuthorizeMessage(self: *Self, a: std.mem.Allocator, peer: @import("placement.zig").Peer, subject: @import("placement.zig").Subject, message_bytes: []const u8) !void {
            try self.allowed();
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const closure = try archive_api.disclosureClosure(scratch.allocator(), self.store(), subject.task);
            const refs = try scratch.allocator().alloc(state.Reference, closure.len + 1);
            @memcpy(refs[0..closure.len], closure);
            try self.store().begin();
            defer self.store().rollback();
            refs[closure.len] = try self.store().putObject(message_bytes);
            try peer.disclose(peer.context, subject, refs);
        }

        // The message's exact bytes join the current private task closure.
        // Disclosure admission happens before publication and transport.
        fn placementPutControl(self: *Self, a: std.mem.Allocator, peer: @import("placement.zig").Peer, record_value: @import("placement.zig").ControlRecord, message_bytes: []const u8, label: []const u8) !void {
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const closure = try archive_api.disclosureClosure(scratch.allocator(), self.store(), record_value.task);
            const refs = try scratch.allocator().alloc(state.Reference, closure.len + 1);
            @memcpy(refs[0..closure.len], closure);
            try self.store().begin();
            defer self.store().rollback();
            refs[closure.len] = try self.store().putObject(message_bytes);
            try peer.disclose(peer.context, record_value.control.value.subject, refs);
            try @import("placement_journal.zig").putControl(self.store(), a, record_value);
            try self.namespace.commit(label);
        }

        pub fn placementStatus(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject) !?@import("placement.zig").Custody {
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var saved = try @import("placement_journal.zig").custody(self.store(), a, subject) orelse return null;
            defer saved.deinit();
            return saved.value;
        }

        /// Persist before transport. An unanswered command prevents controller
        /// succession, so a delayed command cannot cross an ownership epoch.
        pub fn placementControl(self: *Self, a: std.mem.Allocator, operation_name: []const u8, task_id: state.TaskId, command: wc.Work) ![]u8 {
            return self.placementControlExpanded(a, operation_name, task_id, command, null, false, null);
        }
        fn placementControlExpanded(self: *Self, a: std.mem.Allocator, operation_name: []const u8, task_id: state.TaskId, command: wc.Work, expansion: @FieldType(@import("placement.zig").Control, "expansion"), require_transport: bool, cleanup_request: ?u64) ![]u8 {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const site = try self.placementSite();
            const work_id = try wp.identity(try p.commandWork(command), .work);
            var controller = try journal.custody(self.store(), a, .{ .task = task_id }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            try controller.value.requireLocal(site);
            var executor = try journal.custody(self.store(), a, .{ .task = task_id, .work = work_id }) orelse return error.InvalidTransfer;
            defer executor.deinit();
            if (executor.value.phase != .away or std.meta.eql(executor.value.owner, site)) return error.CustodyNotRemote;
            if (operation_name.len == 0 or operation_name.len > 128) return error.InvalidOperation;
            const value: p.Control = .{ .subject = .{ .task = task_id, .work = work_id }, .controller = site, .controller_epoch = controller.value.epoch, .executor = executor.value.owner, .custody_epoch = executor.value.epoch, .operation = .{ .bytes = operation_name }, .command = command, .expansion = expansion, .cleanup_request = cleanup_request };
            const id = p.controlId(value);
            if (try journal.control(self.store(), a, task_id, id)) |saved| {
                var prior = saved;
                defer prior.deinit();
                var replay_value = value;
                replay_value.executor = prior.value.control.value.executor;
                replay_value.custody_epoch = prior.value.control.value.custody_epoch;
                if (replay_value.cleanup_request == null) replay_value.cleanup_request = prior.value.control.value.cleanup_request;
                if (!std.meta.eql(try p.digest(p.Control, a, prior.value.control.value), try p.digest(p.Control, a, replay_value))) return error.OperationConflict;
                const bytes = try contracts.encodeOwned(p.Signed(p.Control), a, prior.value.control);
                errdefer a.free(bytes);
                const head = try p.routeHead(a, prior.value.control.value, prior.value.route.items);
                try self.placementAuthorizeMessage(a, try self.placementPeerAt(head.site), value.subject, bytes);
                return bytes;
            }
            if (require_transport and (try self.placementPeerAt(value.executor)).channel == null) return error.UnsupportedCapability;
            const signed = try p.sign(p.Control, a, self.profile.placement.?.signing_key, value);
            const result = try contracts.encodeOwned(p.Signed(p.Control), a, signed);
            errdefer a.free(result);
            try self.placementPutControl(a, try self.placementPeerAt(value.executor), .{ .id = id, .task = task_id, .control = signed }, result, "placement.control");
            return result;
        }

        pub fn placementExecuteControl(self: *Self, a: std.mem.Allocator, peer_name: []const u8, signed: @import("placement.zig").Signed(@import("placement.zig").Control)) ![]u8 {
            return self.placementExecuteRoutedControl(a, peer_name, signed, &.{});
        }

        pub fn placementResolveControl(self: *Self, a: std.mem.Allocator, peer_name: []const u8, signed: @import("placement.zig").Signed(@import("placement.zig").Control), route: []const @import("placement.zig").Succession) ![]u8 {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const peer = try self.placementPeer(peer_name);
            try p.verify(p.Control, a, signed, peer.site);
            const head = try p.routeHead(a, signed.value, route);
            if (!std.meta.eql(head.site, try self.placementSite())) return error.InvalidRemoteCommand;
            var prior = try journal.control(self.store(), a, signed.value.subject.task, p.controlId(signed.value));
            defer if (prior) |*saved| saved.deinit();
            if (prior) |saved| {
                if (!std.meta.eql(try p.digest(p.Control, a, signed.value), try p.digest(p.Control, a, saved.value.control.value))) return error.OperationConflict;
                if (saved.value.report) |report| {
                    try p.matchReport(a, signed.value, route, report);
                    const bytes = try contracts.encodeOwned(p.ControlResolution, a, .{ .report = report });
                    errdefer a.free(bytes);
                    try self.placementAuthorizeMessage(a, peer, signed.value.subject, bytes);
                    return bytes;
                }
            }
            var controller = try journal.custody(self.store(), a, .{ .task = signed.value.subject.task }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            if (!std.meta.eql(controller.value.owner, peer.site) or controller.value.epoch != signed.value.controller_epoch) return error.StaleController;
            if (try journal.nextExecutor(self.store(), a, signed.value.subject, head)) |next| {
                const bytes = try contracts.encodeOwned(p.ControlResolution, a, .{ .next = next });
                errdefer a.free(bytes);
                try self.placementAuthorizeMessage(a, peer, signed.value.subject, bytes);
                return bytes;
            }
            const report_bytes = try self.placementExecuteRoutedControl(a, peer_name, signed, route);
            defer a.free(report_bytes);
            var report = try contracts.decodeOwned(p.Signed(p.Report), a, report_bytes);
            defer report.deinit();
            const result = try contracts.encodeOwned(p.ControlResolution, a, .{ .report = report.value });
            errdefer a.free(result);
            try self.placementAuthorizeMessage(a, peer, signed.value.subject, result);
            return result;
        }

        fn placementExecuteRoutedControl(self: *Self, a: std.mem.Allocator, peer_name: []const u8, signed: @import("placement.zig").Signed(@import("placement.zig").Control), route: []const @import("placement.zig").Succession) ![]u8 {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const peer = try self.placementPeer(peer_name);
            const site = try self.placementSite();
            try p.verify(p.Control, a, signed, peer.site);
            const value = signed.value;
            const head = try p.routeHead(a, value, route);
            if (!std.meta.eql(head.site, site) or value.subject.work == null or
                !std.meta.eql(try wp.identity(try p.commandWork(value.command), .work), value.subject.work.?)) return error.InvalidRemoteCommand;
            const id = p.controlId(value);
            var prior = try journal.control(self.store(), a, value.subject.task, id);
            defer if (prior) |*saved| saved.deinit();
            if (prior) |saved| {
                if (!std.meta.eql(try p.digest(p.Control, a, saved.value.control.value), try p.digest(p.Control, a, value))) return error.OperationConflict;
                if (saved.value.report) |report| {
                    try p.matchReport(a, value, route, report);
                    const bytes = try contracts.encodeOwned(p.Signed(p.Report), a, report);
                    errdefer a.free(bytes);
                    try self.placementAuthorizeMessage(a, peer, value.subject, bytes);
                    return bytes;
                }
            }
            var controller = try journal.custody(self.store(), a, .{ .task = value.subject.task }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            if (!std.meta.eql(controller.value.owner, peer.site) or controller.value.epoch != value.controller_epoch) return error.StaleController;
            var executor = try journal.custody(self.store(), a, value.subject) orelse return error.InvalidTransfer;
            defer executor.deinit();
            try executor.value.requireLocal(site);
            if (executor.value.epoch != head.epoch) return error.StaleCustody;
            const route_changed = if (prior) |saved| changed: {
                if (saved.value.route.items.len != route.len) break :changed true;
                for (saved.value.route.items, route) |left, right| if (!std.meta.eql(left, right)) break :changed true;
                break :changed false;
            } else true;
            if (route_changed) {
                try self.store().begin();
                defer self.store().rollback();
                try journal.putControl(self.store(), a, .{ .id = id, .task = value.subject.task, .control = signed, .route = .{ .items = route } });
                try self.namespace.commit("placement.receive-control");
            }
            // Native workspace receipts make a retry after execution but before
            // report publication idempotent. The transport never supplies an
            // environmental response or new adapter grant.
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const operation_name = try std.fmt.allocPrint(scratch.allocator(), "placement-{s}", .{std.fmt.bytesToHex(id, .lower)});
            const selected: wc.Command = if (value.expansion) |expand| .{ .context = .{ .expand = .{ .reference = expand.reference, .page = expand.page } } } else .{ .work = value.command };
            const reply = try self.workspaceCommand(scratch.allocator(), operation_name, value.subject.task, selected);
            var observed_work = try self.workspaceWork(scratch.allocator(), value.subject.task, value.subject.work.?);
            defer observed_work.deinit();
            var observed_parent = try self.task(scratch.allocator(), value.subject.task);
            defer observed_parent.deinit();
            const outcome_bytes = try self.store().object(scratch.allocator(), observed_work.value.outcome, null);
            var outcome = try data.invocation.decode(data.invocation.Outcome, scratch.allocator(), outcome_bytes);
            defer outcome.deinit();
            const observed: p.WorkState = .{ .observed_at = observed_parent.value.event_high, .execution_revision = observed_work.value.execution_revision, .control_revision = observed_work.value.control_revision, .outcome = observed_work.value.outcome_kind, .cleanup_complete = cleanupComplete(outcome.value), .cancellation = observed_work.value.cancellation, .explicitly_parked = try self.workspaceExplicitlyParked(a, observed_work.value), .park_complete = try self.workspaceWorkSettled(a, observed_work.value, false, true) };
            const report = try p.sign(p.Report, a, self.profile.placement.?.signing_key, .{ .control = try p.digest(p.Control, a, value), .executor = site, .custody_epoch = head.epoch, .reply = reply, .work_state = observed });
            const result = try contracts.encodeOwned(p.Signed(p.Report), a, report);
            errdefer a.free(result);
            try self.placementPutControl(a, peer, .{ .id = id, .task = value.subject.task, .control = signed, .route = .{ .items = route }, .report = report }, result, "placement.control-report");
            return result;
        }

        pub fn placementFollowExecutor(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, control_id: state.Digest, next: @import("placement.zig").Succession) !void {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            try self.requireCustody(a, task_id, null);
            var saved = try journal.control(self.store(), a, task_id, control_id) orelse return error.InvalidRemoteCommand;
            defer saved.deinit();
            const control = saved.value.control.value;
            if (!std.meta.eql(control.controller, try self.placementSite()) or saved.value.report != null) return error.InvalidRemoteCommand;
            const head = try p.routeHead(a, control, saved.value.route.items);
            const successor = try p.routeNext(a, control.subject, head, next);
            _ = try self.placementPeerAt(successor.site);
            var directory = try journal.custody(self.store(), a, control.subject) orelse return error.InvalidTransfer;
            defer directory.deinit();
            if (directory.value.phase != .away) return error.CustodyNotRemote;
            const update = directory.value.epoch < successor.epoch;
            if (update and (!std.meta.eql(directory.value.owner, head.site) or directory.value.epoch != head.epoch)) return error.StaleCustody;
            if (directory.value.epoch == successor.epoch and !std.meta.eql(directory.value.owner, successor.site)) return error.InvalidTransfer;
            const route = try a.alloc(p.Succession, saved.value.route.items.len + 1);
            defer a.free(route);
            @memcpy(route[0..saved.value.route.items.len], saved.value.route.items);
            route[route.len - 1] = next;
            var updated = saved.value;
            updated.route = .{ .items = route };
            updated.last_error = null;
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            try self.store().begin();
            defer self.store().rollback();
            try journal.putControl(self.store(), a, updated);
            if (update) {
                directory.value.owner = successor.site;
                directory.value.epoch = successor.epoch;
                directory.value.intent = next.offer.value.intent;
                directory.value.offer = next.offer;
                directory.value.decision = next.decision;
                try journal.putCustody(self.store(), a, directory.value);
            }
            try self.namespace.commit("placement.executor-succession");
            self.placement_pending.appendAssumeCapacity(.{ .task = task_id, .id = control_id, .kind = .control });
        }

        pub fn placementApplyReport(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, control_id: state.Digest, report: @import("placement.zig").Signed(@import("placement.zig").Report)) !void {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            var saved = try journal.control(self.store(), a, task_id, control_id) orelse return error.InvalidRemoteCommand;
            defer saved.deinit();
            const control = saved.value.control.value;
            try p.matchReport(a, control, saved.value.route.items, report);
            if (!std.meta.eql(control.controller, try self.placementSite())) return error.InvalidRemoteCommand;
            if (saved.value.report) |prior| {
                if (!std.meta.eql(try p.digest(p.Report, a, prior.value), try p.digest(p.Report, a, report.value))) return error.OperationConflict;
                return;
            }
            saved.value.report = report;
            saved.value.last_error = null;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const wake = (parent.value.cancellation != null or parent.value.terminal()) and try self.hasLocalCustody(a, task_id, null);
            if (wake) {
                try self.ensureOwnershipCapacity(task_id);
                try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            }
            try self.store().begin();
            defer self.store().rollback();
            try journal.putControl(self.store(), a, saved.value);
            try self.namespace.commit("placement.acknowledge-control");
            if (wake) {
                self.claim(task_id);
                if (parent.value.cancellation != null) self.subjectAddAssumeCapacity(.{ .task = task_id });
            }
        }

        /// A worker learns controller succession from both native signatures.
        /// This updates a remote directory entry and cannot activate a copy.
        pub fn placementFollowController(self: *Self, a: std.mem.Allocator, source_peer: []const u8, destination_peer: []const u8, offer: @import("placement.zig").Signed(@import("placement.zig").Offer), decision: @import("placement.zig").Signed(@import("placement.zig").Decision)) !void {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const source_peer_value = try self.placementPeer(source_peer);
            const destination_peer_value = try self.placementPeer(destination_peer);
            try p.verify(p.Offer, a, offer, source_peer_value.site);
            try p.matchDecision(a, offer.value, decision);
            if (offer.value.intent.subject.work != null or decision.value.verdict != .accepted or
                !std.meta.eql(decision.value.destination, destination_peer_value.site)) return error.InvalidTransfer;
            const subject = offer.value.intent.subject;
            var saved = try journal.custody(self.store(), a, subject) orelse return error.InvalidTransfer;
            defer saved.deinit();
            const site = try self.placementSite();
            if (std.meta.eql(saved.value.owner, site) or std.meta.eql(decision.value.destination, site)) return error.InvalidTransfer;
            if (saved.value.epoch == decision.value.epoch and std.meta.eql(saved.value.owner, decision.value.destination)) return;
            if (saved.value.epoch != offer.value.intent.epoch or !std.meta.eql(saved.value.owner, source_peer_value.site)) return error.StaleController;
            try journal.requireSettled(self.store(), a, subject, site);
            saved.value.owner = decision.value.destination;
            saved.value.epoch = decision.value.epoch;
            saved.value.phase = .away;
            saved.value.intent = offer.value.intent;
            saved.value.offer = offer;
            saved.value.decision = decision;
            try self.store().begin();
            defer self.store().rollback();
            try journal.putCustody(self.store(), a, saved.value);
            try self.namespace.commit("placement.controller-succession");
        }

        /// Before an offer is published there is no possible destination
        /// acceptance. Once offered, only its signed decision can release it.
        pub fn placementAbortUnsent(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject, transfer: state.Digest) !void {
            const journal = @import("placement_journal.zig");
            try self.allowed();
            var saved = try journal.custody(self.store(), a, subject) orelse return error.InvalidTransfer;
            defer saved.deinit();
            if (saved.value.phase != .frozen or saved.value.intent == null or saved.value.offer != null or
                !std.meta.eql(saved.value.owner, try self.placementSite()) or !std.meta.eql(saved.value.intent.?.transfer, transfer)) return error.InvalidTransfer;
            saved.value.phase = .local;
            saved.value.intent = null;
            try self.store().begin();
            defer self.store().rollback();
            try journal.putCustody(self.store(), a, saved.value);
            try self.namespace.commit("placement.withdraw-unsent");
        }

        /// Stop local transport before deciding whether a peer could hold an
        /// offer. Published offers require that peer's durable refusal (or its
        /// already committed acceptance), even when no response was received.
        pub fn placementWithdraw(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, transfer: state.Digest) !void {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const site = try self.placementSite();
            var saved = try self.record(p.Move, a, "placement_move", transfer, task_id);
            defer saved.deinit();
            if (!std.meta.eql(saved.value.owner, site)) return error.CustodyNotLocal;
            if (saved.value.decision != null or saved.value.cancelled) return;
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            if (self.placement_job) |running| if (running.kind == .move and std.meta.eql(running.id, transfer)) {
                running.job.deinit();
                self.placement_job = null;
            };
            var i: usize = 0;
            while (i < self.placement_pending.items.len) {
                const pending = self.placement_pending.items[i];
                if (pending.kind == .move and std.meta.eql(pending.id, transfer)) {
                    _ = self.placement_pending.orderedRemove(i);
                } else i += 1;
            }
            var custody = try journal.custody(self.store(), a, saved.value.subject);
            defer if (custody) |*value| value.deinit();
            const same_transfer = if (custody) |value| if (value.value.intent) |intent| std.meta.eql(intent.transfer, transfer) else false else false;
            const offered = same_transfer and custody.?.value.offer != null;
            saved.value.withdraw_requested = true;
            saved.value.last_error = null;
            try self.store().begin();
            defer self.store().rollback();
            if (same_transfer and custody.?.value.decision != null) {
                saved.value.decision = custody.?.value.decision;
            } else if (!offered) {
                if (same_transfer and custody.?.value.phase == .frozen) {
                    custody.?.value.phase = .local;
                    custody.?.value.intent = null;
                    try journal.putCustody(self.store(), a, custody.?.value);
                }
                saved.value.cancelled = true;
            }
            try self.store().putRecord(p.Move, "placement_move", transfer, task_id, saved.value);
            try self.namespace.commit("placement.withdraw-requested");
            if (offered and saved.value.decision == null) self.placementQueue(task_id, transfer, .move);
        }

        pub fn placementCompatibility(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject) !@import("placement.zig").Compatibility {
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            // Compatibility belongs to the admitted artifact. Inspecting it
            // must not restore execution or acquire a publication obligation.
            var selected: ?SelectedRuntime = null;
            defer if (selected) |*runtime| runtime.deinit();
            if (subject.work) |id| {
                var child = try self.workspaceWork(a, subject.task, id);
                defer child.deinit();
                if (child.value.runtime) |ref| {
                    selected = try self.workspaceRuntime(a, subject.task, ref.digest, child.value.program);
                    if (!std.meta.eql(ref, selected.?.record.value.artifact)) return error.InvalidRuntime;
                }
            }
            var packaged = try self.program.retainRuntime();
            defer packaged.deinit();
            const manifest = if (selected) |runtime| runtime.admitted.content.value.manifest else packaged.content.value.manifest;
            return .{ .base = storage.digest(manifest.requirements.base), .admission = storage.digest(manifest.requirements.admission), .bridge = storage.digest(manifest.requirements.bridge), .semantics = manifest.source, .private_state = storage.digest(kosmos.RuntimeCapsule.identity) };
        }

        pub fn placementCut(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject) !@import("placement.zig").Cut {
            const p = @import("placement.zig");
            if (subject.work) |id| {
                var child = try self.workspaceWork(a, subject.task, id);
                defer child.deinit();
                const value = child.value;
                return .{ .execution = value.execution_revision, .control = value.control_revision, .realization = value.realization_revision, .checkpoint = p.ObjectIdentity.from(value.checkpoint), .outer = p.ObjectIdentity.optional(if (value.outer_operation) |pending| pending.capsule else value.runtime_capsule), .runtime = p.ObjectIdentity.optional(value.runtime) };
            }
            try self.retainRootOperation(a);
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var saved = try self.rootOperation(a, parent.value);
            defer if (saved) |*item| item.deinit();
            return .{ .execution = parent.value.execution_revision, .control = parent.value.revision, .realization = 0, .checkpoint = p.ObjectIdentity.from(parent.value.checkpoint), .outer = p.ObjectIdentity.optional(if (saved != null and saved.?.value.pending != null) saved.?.value.pending.?.capsule else null) };
        }

        /// Separate controller and work subjects retain independent epochs.
        /// This returns only after the source can no longer run the subject.
        pub fn placementFreeze(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject, peer_name: []const u8, expected: @import("placement.zig").Cut, transfer: state.Digest) !@import("placement.zig").Intent {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const site = try self.placementSite();
            const peer = try self.placementPeer(peer_name);
            var prior = try journal.custody(self.store(), a, subject);
            defer if (prior) |*saved| saved.deinit();
            if (prior == null and !try self.store().locallyAdmitted(subject.task)) return error.CustodyNotLocal;
            const current = if (prior) |saved| saved.value else p.Custody.initial(subject, site);
            if (current.phase == .frozen and current.intent != null and std.meta.eql(current.intent.?.transfer, transfer)) {
                const intent = current.intent.?;
                if (!std.meta.eql(intent.destination, peer.site) or !std.meta.eql(intent.cut, expected)) return error.OperationConflict;
                return intent;
            }
            try current.requireLocal(site);
            try journal.requireSettled(self.store(), a, subject, site);
            if (subject.work == null) {
                var moves = try self.store().database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_move' AND r.task=?", &.{.{ .blob = &subject.task }});
                defer moves.deinit();
                while (try moves.step() == .row) {
                    var moving = try contracts.decodeOwned(p.Move, a, try moves.bytes(0));
                    defer moving.deinit();
                    if (std.meta.eql(moving.value.owner, site) and moving.value.decision == null and !moving.value.cancelled and !std.meta.eql(moving.value.id, transfer)) return error.UnsettledRemoteControl;
                }
            }
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            try self.compatible(parent.value);
            if (!std.meta.eql(expected, try self.placementCut(a, subject))) return error.StaleRevision;
            if (self.work) |running| if (std.meta.eql(running.task, subject.task) and std.meta.eql(running.subject_work, subject.work)) return error.UnsettledOccurrence;
            if (subject.work) |work_id| {
                const ids = try self.workspaceIds(a, subject.task);
                defer a.free(ids);
                for (ids) |id| {
                    var child = try self.workspaceWork(a, subject.task, id);
                    defer child.deinit();
                    const ref = child.value.delegation orelse continue;
                    if (child.value.terminal() and child.value.answer_value == null) continue;
                    var delegation = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, ref, null));
                    defer delegation.deinit();
                    if (!std.meta.eql(work_id, child.value.id) and !std.meta.eql(work_id, delegation.value.work)) continue;
                    if (try self.delegationCurrent(a, parent.value, child.value)) return error.UnsettledOccurrence;
                }
            }
            var pending_rows = try self.store().database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='occurrence' AND r.task=?", &.{.{ .blob = &subject.task }});
            defer pending_rows.deinit();
            while (try pending_rows.step() == .row) {
                var pending = try contracts.decodeOwned(occurrence.Occurrence, a, try pending_rows.bytes(0));
                defer pending.deinit();
                if (!std.meta.eql(pending.value.work, subject.work)) continue;
                if (pending.value.state == .dispatching or pending.value.state == .unknown) return error.UnsettledOccurrence;
            }
            const compatibility = try self.placementCompatibility(a, subject);
            const resources = try self.profile.resourceIdentity(a, self.application.image_identity);
            if (!std.meta.eql(compatibility, peer.compatibility) or !std.meta.eql(resources, peer.resource_binding)) return error.IncompatibleProfile;
            const intent: p.Intent = .{ .transfer = transfer, .subject = subject, .source = site, .destination = peer.site, .source_native = self.profile.runtime_identity, .destination_native = peer.native_build, .epoch = current.epoch, .cut = expected, .compatibility = compatibility, .resources = resources, .disclosure = peer.disclosure_policy };
            const frozen = try current.freeze(site, intent);
            // Retire before publication. If retirement fails, nothing has been
            // offered and the sole source retains its prior ownership.
            if (self.active) |active| if (std.meta.eql(active.task, subject.task) and std.meta.eql(active.work, subject.work)) try self.retire(a);
            try self.store().begin();
            defer self.store().rollback();
            // Enabling placement on an existing local task first records its
            // complete controller/work directory. Copies of its other subjects
            // cannot inherit implicit local custody at a destination.
            var controller = try journal.custody(self.store(), a, .{ .task = subject.task });
            defer if (controller) |*record_value| record_value.deinit();
            if (controller == null) try journal.putCustody(self.store(), a, p.Custody.initial(.{ .task = subject.task }, site));
            const children = try self.workspaceIds(a, subject.task);
            defer a.free(children);
            for (children) |id| {
                var child = try journal.custody(self.store(), a, .{ .task = subject.task, .work = id });
                defer if (child) |*record_value| record_value.deinit();
                if (child == null) try journal.putCustody(self.store(), a, p.Custody.initial(.{ .task = subject.task, .work = id }, site));
            }
            try journal.putCustody(self.store(), a, frozen);
            // Capture the exact export while custody and its directory are still
            // unpublished. Later sibling progress cannot change this cut.
            var snapshot_arena = std.heap.ArenaAllocator.init(a);
            defer snapshot_arena.deinit();
            const snapshot_a = snapshot_arena.allocator();
            const manifest = try archive_api.prepare(snapshot_a, self.store(), subject.task, self.assets.manifest);
            try self.validateArchiveAdmissions(snapshot_a, parent.value, manifest);
            try self.validateOccurrenceProvenance(snapshot_a, parent.value, manifest.records.items);
            try self.validateCapturedProjections(parent.value, manifest.records.items, .inspect);
            try self.validateWorkspaceRecordBodies(snapshot_a, subject.task, manifest.records.items);
            try archive_api.retainAssets(snapshot_a, self.store(), self.assets.manifest);
            const snapshot: p.Snapshot = .{ .id = frozen.id, .task = subject.task, .work = subject.work, .frozen = .{ .intent = intent, .manifest = manifest } };
            if (try self.store().recordBytes(snapshot_a, "placement_snapshot", snapshot.id, snapshot.task)) |bytes| {
                snapshot_a.free(bytes);
                try self.store().putRecord(p.Snapshot, "placement_snapshot", snapshot.id, snapshot.task, snapshot);
            } else try self.store().createRecord(p.Snapshot, "placement_snapshot", snapshot.id, snapshot.task, snapshot);
            try self.namespace.commit("placement.freeze");
            self.subjectRemove(.{ .task = subject.task, .work = subject.work });
            return intent;
        }

        /// Prepare the authenticated transport file locally. No peer sees an
        /// offer until both its file and signed source record are durable.
        pub fn placementOffer(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject, peer_name: []const u8, path: []const u8) !@import("placement.zig").Signed(@import("placement.zig").Offer) {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const peer = try self.placementPeer(peer_name);
            var saved = try journal.custody(self.store(), a, subject) orelse return error.InvalidTransfer;
            defer saved.deinit();
            const site = try self.placementSite();
            if (saved.value.phase != .frozen or saved.value.intent == null or
                !std.meta.eql(saved.value.owner, site) or !std.meta.eql(saved.value.intent.?.source, site) or
                !std.meta.eql(saved.value.intent.?.destination, peer.site)) return error.InvalidTransfer;
            const intent = saved.value.intent.?;
            if (!std.meta.eql(intent.source_native, self.profile.runtime_identity) or !std.meta.eql(intent.destination_native, peer.native_build) or
                !std.meta.eql(intent.compatibility, peer.compatibility) or !std.meta.eql(intent.resources, peer.resource_binding) or
                !std.meta.eql(intent.resources, try self.profile.resourceIdentity(a, self.application.image_identity)) or
                !std.meta.eql(intent.disclosure, peer.disclosure_policy)) return error.IncompatibleProfile;
            if (saved.value.offer) |prior| {
                var retained = try archive_api.Reader.open(a, path);
                defer retained.deinit();
                if (!std.meta.eql(retained.identity, prior.value.archive_digest) or retained.bytes != prior.value.archive_bytes) return error.InvalidTransfer;
                if (peer.archive_limit) |limit| if (retained.bytes > limit) return error.Capacity;
                try peer.disclose(peer.context, subject, retained.manifest.value.objects.items);
                return prior;
            }
            var snapshot = try self.record(p.Snapshot, a, "placement_snapshot", saved.value.id, subject.task);
            defer snapshot.deinit();
            const frozen_snapshot = snapshot.value.frozen orelse return error.InvalidTransfer;
            if (!std.meta.eql(frozen_snapshot.intent, saved.value.intent.?)) return error.InvalidTransfer;
            const exported = try archive_api.writePrepared(self.allocator, self.io, self.store(), frozen_snapshot.manifest, self.assets.manifest, path, self.namespace.directory);
            var reader = try archive_api.Reader.open(a, path);
            defer reader.deinit();
            if (!std.meta.eql(reader.identity, exported.sha256) or reader.bytes != exported.bytes) return error.InvalidTransfer;
            if (peer.archive_limit) |limit| if (reader.bytes > limit) return error.Capacity;
            try peer.disclose(peer.context, subject, reader.manifest.value.objects.items);
            const signed = try p.sign(p.Offer, a, self.profile.placement.?.signing_key, .{ .intent = saved.value.intent.?, .archive_digest = exported.sha256, .archive_bytes = exported.bytes });
            const offered_value = try saved.value.offered(a, signed);
            try self.store().begin();
            defer self.store().rollback();
            try journal.putCustody(self.store(), a, offered_value);
            try self.namespace.commit("placement.offer");
            return signed;
        }

        /// Native convenience operation over the same bilateral protocol. All
        /// interruption paths retain frozen custody until a signed decision.
        pub fn placementMove(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject, peer_name: []const u8, expected: @import("placement.zig").Cut, transfer: state.Digest) !@import("placement.zig").Signed(@import("placement.zig").Decision) {
            const peer = try self.placementPeer(peer_name);
            if (peer.channel == null) return error.UnsupportedCapability;
            const directory = try self.placementDirectory(a);
            if (try self.placementStatus(a, subject)) |prior| if (prior.intent) |intent| {
                if (std.meta.eql(intent.transfer, transfer)) {
                    if (!std.meta.eql(intent.cut, expected) or !std.meta.eql(intent.destination, peer.site)) return error.OperationConflict;
                    if (prior.decision) |decision| return decision;
                }
            };
            _ = try self.placementFreeze(a, subject, peer_name, expected, transfer);
            const path = try std.fmt.allocPrint(a, "{s}/outgoing-{s}.par", .{ directory, std.fmt.bytesToHex(transfer, .lower) });
            defer a.free(path);
            const offer = try self.placementOffer(a, subject, peer_name, path);
            var connection = try @import("placement_transport.zig").Connection.open(a, self.io, peer);
            defer connection.deinit();
            const decision = try connection.transfer(a, offer, path);
            try self.placementApplyDecision(a, subject, decision);
            return decision;
        }

        pub fn placementApplyDecision(self: *Self, a: std.mem.Allocator, subject: @import("placement.zig").Subject, signed: @import("placement.zig").Signed(@import("placement.zig").Decision)) !void {
            const journal = @import("placement_journal.zig");
            try self.allowed();
            var saved = try journal.custody(self.store(), a, subject) orelse return error.InvalidTransfer;
            defer saved.deinit();
            const result = try saved.value.decided(a, signed);
            if (std.meta.eql(result, saved.value)) return;
            try self.store().begin();
            defer self.store().rollback();
            try journal.putCustody(self.store(), a, result);
            try self.namespace.commit("placement.decision");
            // Refusal releases custody but does not override a user's parked
            // state or implicitly select the next execution action.
        }

        pub fn placementRefuse(self: *Self, a: std.mem.Allocator, peer_name: []const u8, offered: @import("placement.zig").Signed(@import("placement.zig").Offer), reason: @import("placement.zig").Refusal) !@import("placement.zig").Signed(@import("placement.zig").Decision) {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const peer = try self.placementPeer(peer_name);
            const site = try self.placementSite();
            try p.verify(p.Offer, a, offered, peer.site);
            if (!std.meta.eql(offered.value.intent.destination, site)) return error.InvalidTransfer;
            if (try journal.decision(self.store(), a, offered.value.intent.transfer)) |existing| {
                var prior = existing;
                defer prior.deinit();
                try p.matchDecision(a, offered.value, prior.value);
                return prior.value;
            }
            const signed = try p.sign(p.Decision, a, self.profile.placement.?.signing_key, .{ .transfer = offered.value.intent.transfer, .offer_digest = try p.digest(p.Offer, a, offered.value), .source = peer.site, .destination = site, .epoch = try std.math.add(u64, offered.value.intent.epoch, 1), .verdict = .{ .refused = reason } });
            try self.store().begin();
            defer self.store().rollback();
            try journal.putDecision(self.store(), a, site, offered.value, signed);
            try self.namespace.commit("placement.refused");
            return signed;
        }

        pub fn exportCheckpoint(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, path: []const u8) !archive_api.Exported {
            try self.archiveAccess();
            try self.retainRootOperation(a);
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
            return self.importCheckpointFrom(a, id, path, null);
        }

        const PlacementImport = struct {
            offer: @import("placement.zig").Signed(@import("placement.zig").Offer),
            decision: @import("placement.zig").Signed(@import("placement.zig").Decision),
            peer: @import("placement.zig").Peer,
        };

        pub fn placementAccept(self: *Self, a: std.mem.Allocator, operation_id: []const u8, peer_name: []const u8, offered: @import("placement.zig").Signed(@import("placement.zig").Offer), path: []const u8) !@import("placement.zig").Signed(@import("placement.zig").Decision) {
            const p = @import("placement.zig");
            const journal = @import("placement_journal.zig");
            try self.allowed();
            const peer = try self.placementPeer(peer_name);
            const site = try self.placementSite();
            const intent = offered.value.intent;
            try p.verify(p.Offer, a, offered, peer.site);
            if (!std.meta.eql(intent.destination, site)) return error.InvalidTransfer;
            if (try journal.decision(self.store(), a, intent.transfer)) |existing| {
                var prior = existing;
                defer prior.deinit();
                try p.matchDecision(a, offered.value, prior.value);
                return prior.value;
            }
            if (!std.meta.eql(intent.destination_native, self.profile.runtime_identity) or !std.meta.eql(intent.source_native, peer.native_build) or
                !std.meta.eql(intent.compatibility, peer.compatibility) or !std.meta.eql(intent.resources, peer.resource_binding) or
                !std.meta.eql(intent.resources, try self.profile.resourceIdentity(a, self.application.image_identity)) or
                !std.meta.eql(intent.disclosure, peer.disclosure_policy)) return error.IncompatibleProfile;
            const signed = try p.sign(p.Decision, a, self.profile.placement.?.signing_key, .{ .transfer = intent.transfer, .offer_digest = try p.digest(p.Offer, a, offered.value), .source = peer.site, .destination = site, .epoch = try std.math.add(u64, intent.epoch, 1), .verdict = .accepted });
            _ = try self.importCheckpointFrom(a, operation_id, path, .{ .offer = offered, .decision = signed, .peer = peer });
            return signed;
        }

        fn importCheckpointFrom(self: *Self, a: std.mem.Allocator, id: []const u8, path: []const u8, placement: ?PlacementImport) !Admission {
            try self.archiveAccess();
            var reader = try archive_api.Reader.open(self.allocator, path);
            defer reader.deinit();
            const request = if (placement) |transfer| blk: {
                if (!std.meta.eql(reader.identity, transfer.offer.value.archive_digest) or reader.bytes != transfer.offer.value.archive_bytes) return error.InvalidTransfer;
                if (transfer.peer.archive_limit) |limit| if (reader.bytes > limit) return error.Capacity;
                try transfer.peer.disclose(transfer.peer.context, transfer.offer.value.intent.subject, reader.manifest.value.objects.items);
                const Request = struct { method: state.Method, archive: state.Digest, transfer: state.Digest };
                break :blk try operation(Request, a, .{ .method = .import_checkpoint, .archive = reader.identity, .transfer = transfer.offer.value.intent.transfer });
            } else blk: {
                const Request = struct { method: state.Method, archive: state.Digest };
                break :blk try operation(Request, a, .{ .method = .import_checkpoint, .archive = reader.identity });
            };
            if (try self.replay(a, id, request)) |prior| return prior;
            if ((placement == null and self.store().head.generation != 0) or self.active != null or self.runnable.items.len != 0) return error.NonEmptyNamespace;
            var tasks_present = try self.store().database.prepare("SELECT 1 FROM tasks LIMIT 1", &.{});
            defer tasks_present.deinit();
            if (try tasks_present.step() == .row) return error.NonEmptyNamespace;
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
            const accepted_custody = if (placement) |transfer| accepted: {
                const p = @import("placement.zig");
                const intent = transfer.offer.value.intent;
                if (!std.meta.eql(value.id, intent.subject.task) or !std.meta.eql(original_runtime, intent.source_native) or
                    !std.meta.eql(try self.placementCut(a, intent.subject), intent.cut) or
                    !std.meta.eql(try self.placementCompatibility(a, intent.subject), intent.compatibility)) return error.InvalidTransfer;
                var frozen = try @import("placement_journal.zig").custody(self.store(), a, intent.subject) orelse return error.InvalidTransfer;
                defer frozen.deinit();
                break :accepted try p.accept(a, try self.placementSite(), frozen.value, transfer.offer, transfer.decision);
            } else null;
            for (reader.manifest.value.records.items) |row| if (row.kind == .placement_custody) {
                var copied = try self.record(@import("placement.zig").Custody, a, "placement_custody", row.id, value.id);
                defer copied.deinit();
                if (copied.value.phase != .away) {
                    copied.value.phase = .away;
                    try @import("placement_journal.zig").putCustody(self.store(), a, copied.value);
                }
            };
            if (placement) |transfer| {
                const p = @import("placement.zig");
                const journal = @import("placement_journal.zig");
                const intent = transfer.offer.value.intent;
                // Copied controller/work data grants no custody over another
                // subject. Legacy unregistered subjects stay at the source.
                const others = try self.workspaceIds(a, value.id);
                defer a.free(others);
                for (others) |work_id| if (!std.meta.eql(intent.subject.work, @as(?state.Digest, work_id))) {
                    var prior = try journal.custody(self.store(), a, .{ .task = value.id, .work = work_id });
                    defer if (prior) |*record_value| record_value.deinit();
                    if (prior == null) try journal.putCustody(self.store(), a, p.Custody.initial(.{ .task = value.id, .work = work_id }, intent.source));
                };
                if (intent.subject.work != null) {
                    var prior = try journal.custody(self.store(), a, .{ .task = value.id });
                    defer if (prior) |*record_value| record_value.deinit();
                    if (prior == null) try journal.putCustody(self.store(), a, p.Custody.initial(.{ .task = value.id }, intent.source));
                }
                try self.retire(a);
                try journal.putCustody(self.store(), a, accepted_custody.?);
                try journal.putDecision(self.store(), a, try self.placementSite(), transfer.offer.value, transfer.decision);
            }
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

        /// Bind native intent to the actual kernel cancellation, for roots and
        /// children alike. A repeated cancel preserves any existing reason and
        /// therefore cannot establish this agreement.
        fn validateCancellation(a: std.mem.Allocator, value: anytype, outcome: data.invocation.Outcome, checkpoint: []const u8) !void {
            if (value.cancellation_applied and value.cancellation == null) return error.InvalidArchive;
            var graph: ?data.state_image.Owned = null;
            defer if (graph) |*decoded| decoded.deinit();
            const actual: ?data.invocation.Reason = switch (outcome) {
                .cancelled => |cancelled| cancelled.reason,
                .failed => |failure| failure.cancellation,
                .completed => null,
                else => blk: {
                    // The matching program has already admitted this checkpoint.
                    // Read its public graph without advancing authored cleanup.
                    graph = try data.state_image.decodeGraph(a, checkpoint);
                    var cursor = graph.?.state.roots.exit orelse break :blk null;
                    const nodes = graph.?.state.nodes;
                    for (0..nodes.len) |_| {
                        if (cursor.id >= nodes.len) return error.InvalidArchive;
                        const node = nodes[@intCast(cursor.id)].record;
                        if (node != .exit) return error.InvalidArchive;
                        if (node.exit.outer) |outer| {
                            cursor = outer;
                        } else break :blk node.exit.cancellation;
                    }
                    return error.InvalidArchive;
                },
            };
            if (value.cancellation_applied != (actual != null)) return error.InvalidArchive;
            if (actual) |reason| {
                const intent = value.cancellation orelse return error.InvalidArchive;
                if (reason != .text or !same(reason.text, intent.bytes)) return error.InvalidArchive;
            }
        }

        fn validateImportedState(self: *Self, a: std.mem.Allocator, value: state.Task, pending: ?occurrence.Occurrence) !void {
            if (value.cancellation_applied and value.cancellation == null) return error.InvalidArchive;
            try self.validatePendingMessages(a, value);
            var saved_operation = try self.rootOperation(a, value);
            defer if (saved_operation) |*saved| saved.deinit();
            if (saved_operation) |saved| try self.validateRootOperation(a, value, saved.value);
            const driver = restored: {
                // Restore owns its admitted input. Release the serialized copy
                // before reconstruction, even when the caller uses an arena.
                const guest_checkpoint = try self.store().object(self.allocator, value.checkpoint, null);
                defer self.allocator.free(guest_checkpoint);
                break :restored try evaluator.Driver.start(self.allocator, self.program, .{ .state = guest_checkpoint });
            };
            var driver_live = true;
            defer if (driver_live) {
                driver.retire() catch self.store().fence();
                driver.destroy() catch self.store().fence();
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
            try validateCancellation(a, value, decoded.value, checkpoint);
            // All guest/cut checks are complete. Result mapping consumes the
            // separately owned outcome, so it need not overlap the evaluator.
            try driver.retire();
            try driver.destroy();
            driver_live = false;
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
            return self.workspaceCommandFrom(a, operation_id, task_id, admitted, null);
        }
        fn workspaceCommandFrom(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, admitted: workspace.Authorized, basis: ?workspace.ReadObservation) !wc.Reply {
            try self.allowed();
            const command = admitted.command;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            if (command == .placement) return self.placementModel(a, operation_id, task_id, command.placement) catch |err| {
                if (self.store().fenced or err == error.OutOfMemory or err == error.StorageUnavailable) return err;
                return workspaceRejection(a, err);
            };
            const executed = self.workspaceExecute(a, operation_id, task_id, admitted, basis) catch |err| {
                if (self.store().fenced or err == error.OutOfMemory or err == error.StorageUnavailable) return err;
                return workspaceRejection(a, err);
            };
            // Admission is durable. Projection failures must never rewrite it
            // as a rejected operation; callers can retry its retained receipt.
            const observation = switch (executed) {
                .observation => |value| value,
                .admitted => |accepted| try self.workspaceAdmissionObservation(a, task_id, accepted),
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

        const WorkspaceExecution = union(enum) { observation: json.Value, admitted: Admission };

        fn workspaceExecute(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, authorized: workspace.Authorized, basis: ?workspace.ReadObservation) !WorkspaceExecution {
            const command = authorized.command;
            switch (command) {
                .placement => return error.InvalidState,
                .program => |program| switch (program) {
                    .describe => |request| {
                        const description = switch (request.section) {
                            .source_records => try @import("source_records.zig").describe(a),
                            .values => try a.dupe(u8, "Runtime values use JSON arrays for products and sequences, {\"tag\":ordinal,\"value\":payload} for sums, {} for unit, booleans, exact decimal strings for 64-bit integers, UTF-8 strings for text, and base64url strings for bytes. Supply the actual program input schema reference. Program source uses the separately described Horos record transport."),
                            .bindings => try a.dupe(u8, "Pure source records require no environmental adapter. No effect request grants authority. Workspace observations and input ports do not restrict the controller's next action."),
                            .runtimes => try a.dupe(u8, "The packaged generic Horos evaluator is the default. program.specialize derives a checked realization for an admitted program. work.start may select its task-owned runtime reference; work.realize switches at a guest cut without changing guest execution revision. work.request_cut publishes a guest or outer checkpoint. Runtime artifacts never grant environmental authority; active or unknown delivery blocks a switch."),
                            .examples => try construction.example(a),
                            .retention_query => try construction.runtimeQuery(a, true),
                            .divergence_query => try construction.runtimeQuery(a, false),
                            .hypothetical_reply => try construction.hypotheticalReply(a),
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
                        return .{ .observation = try wp.page(a, description, request.page) };
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
                            return .{ .observation = failure };
                        };
                        return .{ .admitted = admitted };
                    },
                    .inspect => |request| {
                        if (request.program.kind == .runtime) {
                            var selected = try self.workspaceRuntime(a, task_id, try wp.identity(request.program, .runtime), null);
                            defer selected.deinit();
                            const text = try json.canonical(a, try self.workspaceRuntimeObservation(a, selected.record.value));
                            defer a.free(text);
                            return .{ .observation = try wp.page(a, text, request.page) };
                        }
                        const id = try wp.identity(request.program, .program);
                        var program_value = try self.workspaceProgram(a, task_id, id);
                        defer program_value.deinit();
                        const observed = try self.workspaceProgramObservation(a, id, program_value.value.description);
                        const text = try json.canonical(a, observed);
                        defer a.free(text);
                        return .{ .observation = try wp.page(a, text, request.page) };
                    },
                    .specialize => |request| return .{ .admitted = try self.workspaceSpecializeWithHooks(a, operation_id, task_id, try wp.identity(request.program, .program), request.hooks) },
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
                        const selected: ?state.Reference = if (request.runtime == .selected) blk: {
                            var selected = try self.workspaceRuntime(a, task_id, try wp.identity(request.runtime.selected, .runtime), program_id);
                            defer selected.deinit();
                            break :blk selected.record.value.artifact;
                        } else null;
                        return .{ .admitted = try self.workspaceStartAdmitted(a, operation_id, task_id, program_id, input, request.policy, origin, null, selected) };
                    },
                    .pump => |request| return .{ .admitted = try self.workspacePump(a, operation_id, task_id, request) },
                    .realize => |request| return .{ .admitted = try self.workspaceRealize(a, operation_id, task_id, request) },
                    .request_cut => |request| return .{ .admitted = try self.workspaceRequestCut(a, operation_id, task_id, request) },
                    .inspect => |request| {
                        if (basis) |frozen| return .{ .observation = try self.renderWorkspaceWorkObservation(a, frozen.works.works.items[0].?.work, frozen.works.works.items[0].?.occurrence, frozen.works.event_watermark) };
                        var value = try self.workspaceWork(a, task_id, try wp.identity(request.work, .work));
                        defer value.deinit();
                        return .{ .observation = try self.workspaceWorkObservation(a, value.value) };
                    },
                    .collect => |request| {
                        var result: json.Value = .{ .array = .init(a) };
                        for (request.works.items, 0..) |ref, i| {
                            if (basis) |frozen| {
                                const item = frozen.works.works.items[i];
                                if (item) |observed| {
                                    try result.array.append(try self.renderWorkspaceWorkObservation(a, observed.work, observed.occurrence, frozen.works.event_watermark));
                                } else {
                                    var missing = json.object();
                                    try json.put(a, &missing, "work", try values.toJson(wc.Ref, a, ref));
                                    try json.put(a, &missing, "outcome", json.string("unavailable"));
                                    try result.array.append(missing);
                                }
                                continue;
                            }
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
                        return .{ .observation = result };
                    },
                    .advance, .park, .delegate, .cancel => {
                        if (work_command == .delegate and work_command.delegate.interpretation != .none) return .{ .admitted = try self.workspaceDelegate(a, operation_id, task_id, authorized) };
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
                        return .{ .admitted = admitted };
                    },
                    .wait => |request| {
                        var parent = try self.task(a, task_id);
                        defer parent.deinit();
                        var result = json.object();
                        const interrupted = if (basis) |frozen| frozen.wait.interrupted else parent.value.messages.items.len != 0 or parent.value.cancellation != null;
                        var ready = interrupted;
                        var selected: json.Value = .{ .array = .init(a) };
                        for (request.works.items, 0..) |ref, i| {
                            if (basis) |frozen| {
                                const observed = frozen.wait.works.items[i].?;
                                ready = ready or observed.work.event_watermark > request.after or observed.work.terminal();
                                try selected.array.append(try self.renderWorkspaceWorkObservation(a, observed.work, observed.occurrence, frozen.wait.event_watermark));
                            } else {
                                var work = try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
                                defer work.deinit();
                                ready = ready or work.value.event_watermark > request.after or work.value.terminal();
                                try selected.array.append(try self.workspaceWorkObservation(a, work.value));
                            }
                        }
                        try json.put(a, &result, "ready", .{ .bool = ready });
                        try json.put(a, &result, "interrupted", .{ .bool = interrupted });
                        try json.put(a, &result, "event_watermark", try json.number(a, if (basis) |frozen| frozen.wait.event_watermark else parent.value.event_high));
                        try json.put(a, &result, "works", selected);
                        return .{ .observation = result };
                    },
                    .interact => |request| return .{ .admitted = try self.workspaceInteract(a, operation_id, task_id, request) },
                },
                .context => |context| switch (context) {
                    .inspect => |request| {
                        var output = try wp.Range.init(a, request.page);
                        defer output.deinit(a);
                        try output.append("[");
                        if (basis) |frozen| {
                            const ids = try self.workspaceScopeAt(a, task_id, frozen.scope);
                            defer a.free(ids);
                            for (ids) |id| try appendWorkspaceReference(&output, id);
                        } else {
                            var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id", &.{.{ .blob = &task_id }});
                            defer query.deinit();
                            while (try query.step() == .row) {
                                const id = try query.bytes(0);
                                if (id.len != 32) return error.CorruptState;
                                try appendWorkspaceReference(&output, id[0..32].*);
                            }
                        }
                        try output.append("]");
                        return .{ .observation = try output.finish(a) };
                    },
                    .expand => |request| {
                        if (request.reference.kind == .port) {
                            const id = try wp.identity(request.reference, .port);
                            var port = try self.record(workspace.Port, a, "workspace_port", id, task_id);
                            defer port.deinit();
                            if (!std.meta.eql(port.value.id, id) or !std.meta.eql(port.value.task, task_id)) return error.CorruptState;
                            return .{ .observation = try self.workspacePayloadPage(a, port.value.interface.payload, port.value.payload, request.page) };
                        }
                        if (request.reference.kind == .work) {
                            if (basis) |frozen| {
                                const work = frozen.works.works.items[0].?.work;
                                const bytes = try self.store().object(a, work.outcome, null);
                                defer a.free(bytes);
                                var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                                defer outcome.deinit();
                                if (outcome.value != .failed) return error.InvalidState;
                                var program = try self.workspaceProgram(a, task_id, work.program);
                                defer program.deinit();
                                return .{ .observation = try self.workspacePayloadBytesPage(a, program.value.description.failure_schema, outcome.value.failed.value, request.page) };
                            }
                            var work = try self.retainedWorkspaceWork(a, task_id, try wp.identity(request.reference, .work));
                            defer work.deinit();
                            const bytes = try self.store().object(a, work.value.outcome, null);
                            defer a.free(bytes);
                            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
                            defer outcome.deinit();
                            if (outcome.value != .failed) return error.InvalidState;
                            var program = try self.workspaceProgram(a, task_id, work.value.program);
                            defer program.deinit();
                            return .{ .observation = try self.workspacePayloadBytesPage(a, program.value.description.failure_schema, outcome.value.failed.value, request.page) };
                        }
                        if (request.reference.kind == .view) {
                            return .{ .observation = try self.workspaceViewObservation(a, task_id, try wp.identity(request.reference, .view), request.page) };
                        }
                        if (request.reference.kind == .provenance or request.reference.kind == .schema) {
                            const reference = try self.workspaceOwnedDescriptor(a, task_id, request.reference);
                            const bytes = try self.store().object(a, reference, null);
                            defer a.free(bytes);
                            if (request.reference.kind == .provenance) {
                                var derivation = try contracts.decodeOwned(workspace.Derivation, a, bytes);
                                defer derivation.deinit();
                                return .{ .observation = try self.workspaceDerivationPage(a, derivation.value, request.page) };
                            }
                            const text = try json.canonical(a, try wp.schema(a, bytes));
                            defer a.free(text);
                            return .{ .observation = try wp.page(a, text, request.page) };
                        }
                        if (request.reference.kind == .source) {
                            return .{ .observation = try self.workspaceSourcePage(a, task_id, request.reference, request.page) };
                        }
                        const value = try self.workspaceValueReference(a, task_id, request.reference);
                        const schema = try self.store().object(a, value.schema, null);
                        defer a.free(schema);
                        const bytes = try self.store().object(a, value.value, null);
                        defer a.free(bytes);
                        return .{ .observation = try @import("dynamic_values.zig").page(a, schema, bytes, request.page) };
                    },
                    .materialize, .select => return .{ .admitted = try self.workspaceContextMutation(a, operation_id, task_id, context, authorized.snapshot, authorized.input) },
                },
            }
        }

        fn workspaceAdmissionObservation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, admitted: Admission) !json.Value {
            const receipt_value = admitted.receipt;
            if (!std.meta.eql(receipt_value.task, task_id)) return error.Denied;
            const bytes = try self.store().object(a, receipt_value.workspace_observation orelse return error.CorruptState, null);
            defer a.free(bytes);
            var observation = switch (receipt_value.workspace_kind orelse return error.CorruptState) {
                .runtime => blk: {
                    var selected = try contracts.decodeOwned(workspace.Runtime, a, bytes);
                    defer selected.deinit();
                    if (!std.meta.eql(selected.value.task, task_id) or !std.meta.eql(selected.value.artifact.digest, receipt_value.workspace.?)) return error.CorruptState;
                    break :blk try self.workspaceRuntimeObservation(a, selected.value);
                },
                .program => blk: {
                    var artifact = try contracts.decodeOwned(workspace.ProgramArtifact, a, bytes);
                    defer artifact.deinit();
                    break :blk try self.workspaceProgramObservation(a, receipt_value.workspace.?, artifact.value);
                },
                .work => blk: {
                    var value = try contracts.decodeOwned(workspace.WorkObservation, a, bytes);
                    defer value.deinit();
                    if (!std.meta.eql(value.value.work.task, task_id)) return error.Denied;
                    if (self.workspace_replay) |replay_only| {
                        var parent = try self.task(a, task_id);
                        defer parent.deinit();
                        try self.validateWorkspaceWorkSnapshot(a, parent.value, value.value, replay_only.records);
                        try self.validateHistoricalOccurrence(a, value.value);
                    }
                    break :blk try self.renderWorkspaceWorkObservation(a, value.value.work, value.value.occurrence, value.value.work.event_watermark);
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
            var parent = try self.task(a, value.task);
            defer parent.deinit();
            return self.renderWorkspaceWorkObservation(a, value, if (pending) |saved| saved.value else null, parent.value.event_high);
        }

        fn renderWorkspaceWorkObservation(self: *Self, a: std.mem.Allocator, value: workspace.Work, pending: ?occurrence.Occurrence, observed_at: u64) !json.Value {
            var result = json.object();
            try json.put(a, &result, "work", try values.toJson(wc.Ref, a, try wp.reference(a, .work, value.id)));
            try json.put(a, &result, "program", try values.toJson(wc.Ref, a, try wp.reference(a, .program, value.program)));
            try json.put(a, &result, "execution_revision", try json.number(a, value.execution_revision));
            try json.put(a, &result, "control_revision", try json.number(a, value.control_revision));
            try json.put(a, &result, "realization_revision", try json.number(a, value.realization_revision));
            try json.put(a, &result, "runtime", if (value.runtime) |ref| try values.toJson(wc.Ref, a, try wp.reference(a, .runtime, ref.digest)) else json.string("packaged-generic"));
            try json.put(a, &result, "available_cut", json.string(if (value.outer_operation != null) "outer_execution" else "guest_cut"));
            try json.put(a, &result, "outer_operation", try values.toJson(?state.Reference, a, if (value.outer_operation) |operation_value| operation_value.capsule else null));
            try json.put(a, &result, "runtime_capsule", try values.toJson(?state.Reference, a, value.runtime_capsule));
            try json.put(a, &result, "runtime_trace", try values.toJson(?kosmos.RuntimeInstrumentation.Output, a, if (value.runtime_trace) |trace| trace.output else null));
            try json.put(a, &result, "event_watermark", try json.number(a, observed_at));
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
                try json.put(a, &result, "port_accepts_command", .{ .bool = observed.state == .ready and workspaceInteractionAllowed(try self.workspaceStoppedAt(a, value.task, observed_at), value) });
            }
            const outcome_bytes = try self.store().object(a, value.outcome, null);
            defer a.free(outcome_bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, outcome_bytes);
            defer outcome.deinit();
            try json.put(a, &result, "cleanup_complete", .{ .bool = cleanupComplete(outcome.value) });
            if (outcome.value == .failed) {
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                try json.put(a, &result, "failure_preview", try self.workspacePayloadPreview(a, program.value.description.failure_schema, outcome.value.failed.value));
                try json.put(a, &result, "failure", try values.toJson(wc.Ref, a, try wp.reference(a, .work, value.id)));
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
                try json.put(a, &result, "result_preview", try @import("dynamic_values.zig").preview(a, schema, bytes));
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
            const payload = try self.store().object(a, port.payload, null);
            defer a.free(payload);
            try json.put(a, &result, "preview", try self.workspacePayloadPreview(a, port.interface.payload, payload));
            return result;
        }

        fn workspacePayloadPreview(self: *Self, a: std.mem.Allocator, schema_ref: state.Reference, payload: []const u8) !json.Value {
            const schema = try self.store().object(a, schema_ref, null);
            defer a.free(schema);
            return @import("dynamic_values.zig").preview(a, schema, payload);
        }

        fn workspacePayloadPage(self: *Self, a: std.mem.Allocator, schema_ref: state.Reference, payload_ref: state.Reference, page: wc.Page) !json.Value {
            const payload = try self.store().object(a, payload_ref, null);
            defer a.free(payload);
            return self.workspacePayloadBytesPage(a, schema_ref, payload, page);
        }

        fn workspacePayloadBytesPage(self: *Self, a: std.mem.Allocator, schema_ref: state.Reference, payload: []const u8, page: wc.Page) !json.Value {
            const schema = try self.store().object(a, schema_ref, null);
            defer a.free(schema);
            return @import("dynamic_values.zig").page(a, schema, payload, page);
        }

        pub fn workspaceInteract(self: *Self, allocator: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, interaction: @FieldType(wc.Work, "interact")) !Admission {
            try self.requireCustody(allocator, task_id, try wp.identity(interaction.expected.work, .work));
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const Request = workspace.InteractionRequest;
            const request_digest = try operation(Request, a, .{ .task = task_id, .interaction = interaction });
            if (try self.replay(allocator, operation_id, request_digest)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            var saved = try self.workspaceWork(a, task_id, try wp.identity(interaction.expected.work, .work));
            defer saved.deinit();
            var value = saved.value;
            if (value.execution_revision != interaction.expected.execution_revision or value.control_revision != interaction.expected.control_revision) return error.StaleRevision;
            if (!workspaceInteractionAllowed(parent.value.terminal() or parent.value.cancellation != null, value)) return error.InvalidState;
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
            const command_schema = try self.store().object(a, port.value.interface.command, null);
            defer a.free(command_schema);
            const payload_schema = if (interaction.command == .finish) try self.store().object(a, port.value.interface.payload, null) else &.{};
            defer a.free(payload_schema);
            const payload = if (interaction.command == .finish) try self.store().object(a, port.value.payload, null) else &.{};
            defer a.free(payload);
            const protocol: @import("workspace_driver.zig").Protocol = .{
                .class = port.value.interface.class,
                .command_schema = command_schema,
                .payload_schema = payload_schema,
                .payload = payload,
            };
            const command: @import("workspace_driver.zig").Command = switch (interaction.command) {
                .finish => .finish,
                .resume_value => |supplied| supplied_value: {
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
                    break :supplied_value .{ .resume_value = input.? };
                },
            };
            const command_bytes = try protocol.encode(a, command);
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
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request_digest, value.id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", value.id, task_id), .{ .interact = interaction });
            self.subjectAppendAssumeCapacity(.{ .task = task_id, .work = value.id });
            return admitted;
        }

        const WorkspaceSource = union(enum) { text: []u8, value: WorkspaceValueReference };

        fn workspaceSource(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref) ![]u8 {
            return switch (try self.resolveWorkspaceSource(a, task_id, ref)) {
                .text => |text| text,
                // Runtime value JSON has no named-record objects: its only
                // objects are unit {} and sums {tag,value}. Neither is a
                // source Document {version,module} or a Recipe
                // {instances,bindings,entry}. Do not expand incompatible data
                // on the owner before handing construction to the worker.
                .value => error.InvalidParams,
            };
        }

        fn workspaceSourcePage(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref, requested: wc.Page) !json.Value {
            return switch (try self.resolveWorkspaceSource(a, task_id, ref)) {
                .text => |text| blk: {
                    defer a.free(text);
                    break :blk try wp.page(a, text, requested);
                },
                .value => |value| try self.workspacePayloadPage(a, value.schema, value.value, requested),
            };
        }

        /// Resolve and authorize before choosing complete text or a bounded
        /// projection. Frozen typed inputs keep their compact representation.
        fn resolveWorkspaceSource(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref) !WorkspaceSource {
            const id = try wp.identity(ref, .source);
            var acquired = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_value' ORDER BY id", &.{.{ .blob = &task_id }});
            defer acquired.deinit();
            while (try acquired.step() == .row) {
                const key = try acquired.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var record_value = try self.record(workspace.Value, a, "workspace_value", key[0..32].*, task_id);
                defer record_value.deinit();
                if (!std.meta.eql(record_value.value.description.provenance.digest, id)) continue;
                const checked = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, record_value.value.artifact.digest));
                if (record_value.value.derivation.frozen_input != null) {
                    return .{ .value = checked };
                }
                const origin = record_value.value.derivation.acquisition orelse continue;
                const bytes = try self.store().object(a, origin.snapshot, null);
                defer a.free(bytes);
                var source = try @import("repository.zig").Snapshot.openBorrowed(a, bytes);
                defer source.deinit();
                const file = source.get(origin.path.bytes) orelse return error.CorruptState;
                if (!std.unicode.utf8ValidateSlice(file.contents.bytes)) return .{ .text = try json.canonical(a, try values.toJson(contracts.Bytes(null), a, file.contents)) };
                return .{ .text = try a.dupe(u8, file.contents.bytes) };
            }
            var query = try self.store().database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_program' ORDER BY id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const key = try query.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var program = try self.record(workspace.Program, a, "workspace_program", key[0..32].*, task_id);
                defer program.deinit();
                if (std.meta.eql(program.value.description.source.digest, id)) return .{ .text = try self.store().object(a, program.value.description.source, null) };
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
                var projected = origin;
                projected.path.bytes = try a.dupe(u8, origin.path.bytes);
                try json.put(a, &result, "acquisition", try values.toJson(workspace.SnapshotRange, a, projected));
                try json.put(a, &result, "complete_file", .{ .bool = origin.start == 0 and origin.end == origin.file_bytes });
            }
            if (derivation.frozen_input) |ref| try json.put(a, &result, "frozen_input", try values.toJson(state.Reference, a, ref));
            if (derivation.inspection) |origin| {
                try json.put(a, &result, "inspection", try values.toJson(wc.GuestViewSelection, a, .{ .expected = .{ .work = try wp.reference(a, .work, origin.observation.work.id), .execution_revision = origin.observation.work.execution_revision, .control_revision = origin.observation.work.control_revision }, .realization_revision = origin.observation.work.realization_revision, .nodes = origin.nodes }));
                try json.put(a, &result, "checkpoint", try values.toJson(state.Reference, a, origin.observation.work.checkpoint));
            }
            return result;
        }

        fn workspaceDerivationPage(self: *Self, a: std.mem.Allocator, derivation: workspace.Derivation, page: wc.Page) !json.Value {
            // Reuse the ordinary projection's fields, but fold its growing
            // source vector directly into the requested canonical byte range.
            var metadata = derivation;
            metadata.sources.items = &.{};
            const fields = try self.workspaceDerivationObservation(a, metadata);
            const keys = try a.dupe([]const u8, fields.object.keys());
            defer a.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.lessThan(u8, left, right);
                }
            }.less);
            var output = try wp.Range.init(a, page);
            defer output.deinit(a);
            var element = std.heap.ArenaAllocator.init(a);
            defer element.deinit();
            try output.append("{");
            for (keys, 0..) |key, index| {
                if (index != 0) try output.append(",");
                try output.append(try json.canonical(a, json.string(key)));
                try output.append(":");
                if (!same(key, "sources")) {
                    try output.append(try json.canonical(a, fields.object.get(key).?));
                    continue;
                }
                try output.append("[");
                for (derivation.sources.items, 0..) |ref, i| {
                    _ = element.reset(.retain_capacity);
                    const scratch = element.allocator();
                    if (i != 0) try output.append(",");
                    try output.append(try json.canonical(scratch, try values.toJson(wc.Ref, scratch, try wp.reference(scratch, .value, ref.digest))));
                }
                try output.append("]");
            }
            try output.append("}");
            return output.finish(a);
        }

        fn workspaceValueObservation(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest) !json.Value {
            const ref = try wp.reference(a, .value, id);
            const value = try self.workspaceValueReference(a, task_id, ref);
            const schema = try self.store().object(a, value.schema, null);
            defer a.free(schema);
            const bytes = try self.store().object(a, value.value, null);
            defer a.free(bytes);
            var result = json.object();
            try json.put(a, &result, "value", try values.toJson(wc.Ref, a, ref));
            try json.put(a, &result, "schema", try values.toJson(wc.Ref, a, try wp.reference(a, .schema, value.schema.digest)));
            try json.put(a, &result, "provenance", try values.toJson(wc.Ref, a, try wp.reference(a, .provenance, value.provenance.digest)));
            try json.put(a, &result, "preview", try @import("dynamic_values.zig").preview(a, schema, bytes));
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
            var selection = try wp.Range.init(a, page);
            defer selection.deinit(a);
            try selection.append("[");
            var element = std.heap.ArenaAllocator.init(a);
            defer element.deinit();
            for (saved.value.description.values.items, 0..) |ref, i| {
                // Each element is independently projected and released. A
                // bounded page never retains N complete value previews.
                _ = element.reset(.retain_capacity);
                const scratch = element.allocator();
                const value = try self.workspaceValueReference(scratch, task_id, try wp.reference(scratch, .value, ref.digest));
                if (!std.meta.eql(value.artifact, ref)) return error.CorruptState;
                if (i != 0) try selection.append(",");
                try selection.append(try json.canonical(scratch, try self.workspaceValueObservation(scratch, task_id, ref.digest)));
            }
            try selection.append("]");
            try json.put(a, &result, "selection", try selection.finish(a));
            try json.put(a, &result, "value_count", try json.number(a, saved.value.description.values.items.len));
            return result;
        }

        fn workspaceContextMutation(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, command: wc.Context, snapshot: ?state.Reference, input: ?state.Reference) !Admission {
            try self.requireCustody(a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const Request = workspace.ContextRequest;
            const request = try operation(Request, a, .{ .task = task_id, .command = command, .snapshot = snapshot, .input = input });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            try self.store().begin();
            defer self.store().rollback();
            const artifact: state.Reference, const kind: @FieldType(wc.Ref, "kind") = switch (command) {
                .materialize => |materialize| blk: {
                    if (materialize.input == .guest_view) {
                        if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
                        const selection = materialize.input.guest_view;
                        const observed = try self.freezeWorkspaceWork(a, task_id, selection.expected.work, false);
                        try inspectionSelection(observed.work, selection);
                        // The controller can disclose graph metadata of its own
                        // work. Node selection narrows that grant; it never
                        // exposes payload, source text or another task's work.
                        var prepared = try self.inspectionRuntime(a, observed.work);
                        defer prepared.deinit();
                        const code = try prepared.runtime.encode(a);
                        defer a.free(code);
                        const origin: workspace.Inspection = .{ .observation = observed, .nodes = selection.nodes, .runtime_code = try self.store().putObject(code) };
                        const derived = try self.workspaceInspectionBytes(a, task_id, origin);
                        defer a.free(derived.schema);
                        defer a.free(derived.value);
                        break :blk .{ try self.workspacePublishValue(a, task_id, try self.store().putObject(derived.schema), try self.store().putObject(derived.value), .{ .kind = .inspection, .sources = .{ .items = &.{} }, .inspection = origin }), .value };
                    }
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
            return self.workspaceCommit(a, parent.value, operation_id, request, artifact.digest, kind, artifact, .{ .context = .{ .command = command, .snapshot = snapshot, .input = input } });
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
            if (saved.value.derivation.inspection) |origin| {
                const d = saved.value.derivation;
                if (d.kind != .inspection or d.sources.items.len != 0 or d.program != null or d.work != null or d.acquisition != null or d.frozen_input != null or d.delegation != null or d.capture != null) return error.InvalidArchive;
                const derived = try self.workspaceInspectionBytes(a, task_id, origin);
                defer a.free(derived.schema);
                defer a.free(derived.value);
                if (!std.meta.eql(saved.value.description.schema, state.Reference{ .digest = storage.digest(derived.schema), .bytes = derived.schema.len }) or
                    !std.meta.eql(saved.value.description.value, state.Reference{ .digest = storage.digest(derived.value), .bytes = derived.value.len })) return error.InvalidArchive;
            } else if (saved.value.derivation.kind == .inspection) return error.InvalidArchive;
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
            const origin = saved.value.derivation;
            if (origin.program == null and origin.work == null and origin.acquisition == null and origin.frozen_input == null and origin.delegation == null and origin.capture == null and origin.inspection == null) {
                const expected: @TypeOf(origin.kind) = if (origin.sources.items.len == 0) .hypothesis else .judgment;
                if (origin.kind != expected) return error.InvalidArchive;
            }
            return .{ .artifact = saved.value.artifact, .schema = saved.value.description.schema, .value = saved.value.description.value, .provenance = saved.value.description.provenance };
        }

        fn inspectionSelection(work: workspace.Work, selected: wc.GuestViewSelection) !void {
            if (!std.meta.eql(work.id, try wp.identity(selected.expected.work, .work)) or
                work.execution_revision != selected.expected.execution_revision or work.control_revision != selected.expected.control_revision or
                work.realization_revision != selected.realization_revision) return error.StaleRevision;
        }

        fn inspectionRuntime(self: *Self, a: std.mem.Allocator, work: workspace.Work) !kosmos.Prepared {
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            const image = try self.store().object(a, program.value.description.image, null);
            defer a.free(image);
            if (work.runtime) |ref| {
                var selected = try self.workspaceRuntime(a, work.task, ref.digest, work.program);
                defer selected.deinit();
                return kosmos.Prepared.initWithRuntime(a, image, &selected.admitted);
            }
            return self.program.prepare(a, image);
        }

        fn workspaceInspectionBytes(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, origin: workspace.Inspection) !struct { schema: []u8, value: []u8 } {
            const work = origin.observation.work;
            if (!std.meta.eql(work.task, task_id)) return error.Denied;
            try self.validateWorkspacePublication(a, task_id, origin.observation);
            var prepared = try self.inspectionRuntime(a, work);
            defer prepared.deinit();
            const code = try self.store().object(a, origin.runtime_code, null);
            defer a.free(code);
            if (!std.meta.eql(prepared.runtime.identity, origin.runtime_code.digest)) return error.InvalidRuntime;
            const checkpoint = try self.store().object(a, work.checkpoint, null);
            defer a.free(checkpoint);
            var mask: ?[]bool = null;
            defer if (mask) |items| a.free(items);
            if (origin.nodes == .selected) {
                var decoded = try data.state_image.decodeGraph(a, checkpoint);
                defer decoded.deinit();
                mask = try a.alloc(bool, decoded.state.nodes.len);
                @memset(mask.?, false);
                for (origin.nodes.selected.items) |node| {
                    if (node >= mask.?.len) return error.InvalidDisclosure;
                    mask.?[@intCast(node)] = true;
                }
            }
            const disclosure = try operation(struct { task: state.TaskId, work: state.Digest, checkpoint: state.Reference, scope: wc.NodeScope }, a, .{ .task = task_id, .work = work.id, .checkpoint = work.checkpoint, .scope = origin.nodes });
            var view = try kosmos.RuntimeViews.capture(a, prepared.guest.core.?.admitted(), checkpoint, .{
                .guest = prepared.guest.core.?.admitted().identity(),
                .core = prepared.runtime.content.value.manifest.source,
                .realization = prepared.runtime.identity,
                .checkpoint = work.checkpoint.digest,
                .execution = work.id,
                .guest_revision = work.execution_revision,
                .realization_revision = work.realization_revision,
                .disclosure = disclosure,
            }, mask);
            defer view.deinit();
            const schema = try kosmos.RuntimeViews.schemaBytes(a);
            errdefer a.free(schema);
            return .{ .schema = schema, .value = try kosmos.RuntimeViews.encode(a, view.value) };
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
        fn workspaceSnapshotRange(self: *Self, a: std.mem.Allocator, parent: state.Task, snapshot: state.Reference, selection: anytype) !workspace.SnapshotRange {
            try workspaceSnapshotAccess(parent, snapshot);
            const bytes = try self.store().object(a, snapshot, null);
            defer a.free(bytes);
            var source = try @import("repository.zig").Snapshot.openBorrowed(a, bytes);
            defer source.deinit();
            const file = source.get(selection.path.bytes) orelse return error.SourceMissing;
            if (selection.offset > file.contents.bytes.len) return error.InvalidRange;
            return .{
                .snapshot = snapshot,
                .path = selection.path,
                .file_digest = file.sha256,
                .start = selection.offset,
                .end = selection.offset + @min(selection.maximum, file.contents.bytes.len - selection.offset),
                .file_bytes = file.contents.bytes.len,
                .excluded_entries = source.decoded.value.excluded_entries,
            };
        }
        fn workspaceMaterializeSnapshot(self: *Self, a: std.mem.Allocator, parent: state.Task, snapshot: state.Reference, selection: anytype) !state.Reference {
            const origin = try self.workspaceSnapshotRange(a, parent, snapshot, selection);
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

        fn workspaceIsRead(command: wc.Command) bool {
            return switch (command) {
                .program => |p| p != .build and p != .specialize,
                .work => |w| w == .inspect or w == .collect or w == .wait,
                .context => |c| c == .inspect or c == .expand,
                .placement => false,
            };
        }

        fn appendWorkspaceReference(output: *wp.Range, id: state.Digest) !void {
            if (output.total > 1) try output.append(",");
            // Ref's canonical JSON has only a fixed tag and hexadecimal ID.
            try output.append("{\"id\":\"");
            try output.append(&std.fmt.bytesToHex(id, .lower));
            try output.append("\",\"kind\":\"work\"}");
        }

        fn workspaceScopeAt(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, watermark: u64) ![]state.Digest {
            var ids: std.AutoHashMap(state.Digest, void) = .init(a);
            defer ids.deinit();
            var event_arena = std.heap.ArenaAllocator.init(a);
            defer event_arena.deinit();
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq", &.{ .{ .blob = &task_id }, .{ .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive } });
            defer query.deinit();
            while (try query.step() == .row) {
                _ = event_arena.reset(.retain_capacity);
                var event_value = try contracts.decodeOwned(state.Event, event_arena.allocator(), try query.bytes(0));
                defer event_value.deinit();
                // Scope follows the same publication facts as historical work
                // observations; display payloads cannot create or hide work.
                for (event_value.value.workspace_publications.items) |item| try ids.put(item.work, {});
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

        fn workspaceInteractionAllowed(parent_stopped: bool, child: workspace.Work) bool {
            return !child.terminal() and (child.cancellation == null or child.cancellation_applied) and
                (!parent_stopped or child.cancellation_applied);
        }

        fn workspaceStoppedAt(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, watermark: u64) !bool {
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq", &.{ .{ .blob = &task_id }, .{ .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive } });
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

        fn workspaceInterruptedAt(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, watermark: u64) !bool {
            var messages: u64 = 0;
            var cancelled = false;
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq", &.{ .{ .blob = &task_id }, .{ .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive } });
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                switch (saved.value.kind) {
                    .message_queued => messages = try std.math.add(u64, messages, 1),
                    .message_consumed, .message_not_consumed => messages = std.math.sub(u64, messages, 1) catch return error.InvalidArchive,
                    .cancellation_requested => cancelled = true,
                    else => {},
                }
            }
            return messages != 0 or cancelled;
        }

        fn freezeWorkspaceWork(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, ref: wc.Ref, retained: bool) !workspace.WorkObservation {
            var saved = if (retained) try self.retainedWorkspaceWork(a, task_id, try wp.identity(ref, .work)) else try self.workspaceWork(a, task_id, try wp.identity(ref, .work));
            defer saved.deinit();
            var work = saved.value;
            work.inputs.items = try a.dupe(state.Reference, work.inputs.items);
            work.runtime_dependencies.items = try a.dupe(state.Reference, work.runtime_dependencies.items);
            if (work.runtime_trace) |*trace| trace.dependencies.items = try a.dupe(state.Reference, trace.dependencies.items);
            if (work.outer_operation) |*pending| pending.dependencies.items = try a.dupe(state.Reference, pending.dependencies.items);
            if (work.cancellation) |reason| work.cancellation = .{ .bytes = try a.dupe(u8, reason.bytes) };
            var pending: ?occurrence.Occurrence = null;
            if (work.current_occurrence) |id| {
                var decoded = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                defer decoded.deinit();
                pending = decoded.value;
            }
            return .{ .work = work, .occurrence = pending };
        }

        fn workPublication(a: std.mem.Allocator, observed: workspace.WorkObservation) !state.WorkPublication {
            const bytes = try contracts.encodeOwned(workspace.WorkObservation, a, observed);
            defer a.free(bytes);
            return .{ .work = observed.work.id, .execution_revision = observed.work.execution_revision, .control_revision = observed.work.control_revision, .runtime = observed.work.runtime, .realization_revision = observed.work.realization_revision, .runtime_capsule = observed.work.runtime_capsule, .runtime_trace = observed.work.runtime_trace != null, .outer_operation = if (observed.work.outer_operation) |pending| pending.capsule else null, .checkpoint = observed.work.checkpoint, .observation = storage.digest(bytes), .control = workspace.ControlObservation.from(observed) };
        }

        fn samePublication(a: std.mem.Allocator, declared: state.WorkPublication, observed: state.WorkPublication) !bool {
            const left = try contracts.encodeOwned(state.WorkPublication, a, declared);
            defer a.free(left);
            const right = try contracts.encodeOwned(state.WorkPublication, a, observed);
            defer a.free(right);
            return same(left, right);
        }

        fn publicationSchedule(value: workspace.ControlObservation) state.Schedule {
            if (value.outcome == .requested) return if ((value.cancellation != null and !value.cancellation_applied) or (value.instrument and !value.port and value.policy.continuation == .owner_scheduled)) .queued else .parked;
            if (value.outcome == .completed or value.outcome == .failed or value.outcome == .cancelled) return .parked;
            return if (value.cancellation != null or (value.policy.continuation == .owner_scheduled and value.policy.stop != .next_slice and (value.outcome != .yielded or value.policy.stop == .terminal))) .queued else .parked;
        }

        const WorkspaceAdmission = struct { request: state.Digest, work: state.Digest, kind: @FieldType(wc.Ref, "kind") };

        fn workspaceInteractionReply(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, interaction: @FieldType(wc.Work, "interact")) !workspace.PortReply {
            var port = try self.record(workspace.Port, a, "workspace_port", try wp.identity(interaction.port, .port), task_id);
            defer port.deinit();
            if (!std.meta.eql(port.value.task, task_id) or !std.meta.eql(port.value.work, try wp.identity(interaction.expected.work, .work)) or
                port.value.generation != interaction.generation) return error.InvalidArchive;
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", port.value.occurrence, task_id);
            defer pending.deinit();
            const acquired = switch (pending.value.state) {
                .settled_reply => |reply| reply,
                .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            var saved = try self.record(workspace.PortReply, a, "workspace_port_reply", acquired.attempt, task_id);
            defer saved.deinit();
            const reply = saved.value;
            const port_bytes = try contracts.encodeOwned(workspace.Port, a, port.value);
            defer a.free(port_bytes);
            if (!std.meta.eql(reply.task, task_id) or !std.meta.eql(reply.id, acquired.attempt) or
                !std.meta.eql(reply.reply.digest, acquired.reply) or
                !std.meta.eql(reply.port, state.Reference{ .digest = storage.digest(port_bytes), .bytes = port_bytes.len })) return error.InvalidArchive;
            switch (interaction.command) {
                .finish => if (reply.command != .finish or reply.input != null) return error.InvalidArchive,
                .resume_value => |supplied| {
                    if (reply.command != .resume_value) return error.InvalidArchive;
                    const input = reply.input orelse return error.InvalidArchive;
                    const actual = try self.workspaceValueReference(a, task_id, try wp.reference(a, .value, input.digest));
                    if (!std.meta.eql(actual.artifact, input) or !std.meta.eql(actual.schema, port.value.interface.argument)) return error.InvalidArchive;
                    switch (supplied) {
                        .reference => |ref| {
                            const expected = try self.workspaceValueReference(a, task_id, ref);
                            if (!std.meta.eql(expected.artifact, input)) return error.InvalidArchive;
                        },
                        .inline_json => |inline_value| {
                            if (!std.meta.eql(try wp.identity(inline_value.schema, .schema), port.value.interface.argument.digest)) return error.InvalidArchive;
                            const descriptor = try self.store().object(a, port.value.interface.argument, null);
                            defer a.free(descriptor);
                            const text = inline_value.json_text.bytes;
                            var parsed = try json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
                            defer parsed.deinit();
                            const bytes = try @import("dynamic_values.zig").encode(a, descriptor, parsed.value);
                            defer a.free(bytes);
                            const provenance = try contracts.encodeOwned(workspace.Derivation, a, .{ .kind = .hypothesis, .sources = .{ .items = &.{} } });
                            defer a.free(provenance);
                            if (!std.meta.eql(actual.value, state.Reference{ .digest = storage.digest(bytes), .bytes = bytes.len }) or
                                !std.meta.eql(actual.provenance, state.Reference{ .digest = storage.digest(provenance), .bytes = provenance.len })) return error.InvalidArchive;
                        },
                    }
                },
            }
            return reply;
        }

        // Replay proves receipt stability only after admission. At the archive
        // boundary, derive the content relationship from the retained command.
        fn validateWorkspaceContextOutput(self: *Self, a: std.mem.Allocator, parent: state.Task, context: @FieldType(workspace.PublicationCommand, "context"), identity: state.Digest, event_seq: u64) !void {
            switch (context.command) {
                .select => |selection| {
                    const refs = try a.alloc(state.Reference, selection.values.items.len);
                    defer a.free(refs);
                    for (selection.values.items, refs) |ref, *out| out.* = (try self.workspaceValueReference(a, parent.id, ref)).artifact;
                    const bytes = try contracts.encodeOwned(workspace.ViewArtifact, a, .{ .values = .{ .items = refs } });
                    defer a.free(bytes);
                    if (!std.meta.eql(storage.digest(bytes), identity)) return error.InvalidArchive;
                },
                .materialize => |materialize| {
                    const actual = try self.workspaceValueReference(a, parent.id, try wp.reference(a, .value, identity));
                    var schema = actual.schema;
                    var payload = actual.value;
                    var derivation: workspace.Derivation = .{ .kind = .hypothesis, .sources = .{ .items = &.{} } };
                    var sources: std.ArrayList(state.Reference) = .empty;
                    defer sources.deinit(a);
                    switch (materialize.input) {
                        .guest_view => |selection| {
                            if (materialize.sources.items.len != 0) return error.InvalidArchive;
                            var retained = try self.record(workspace.Value, a, "workspace_value", try workspaceContentCustody(a, parent.id, identity), parent.id);
                            defer retained.deinit();
                            const origin = retained.value.derivation.inspection orelse return error.InvalidArchive;
                            try inspectionSelection(origin.observation.work, selection);
                            if (origin.observation.work.event_watermark >= event_seq) return error.InvalidArchive;
                            const requested_scope = try contracts.encodeOwned(wc.NodeScope, a, selection.nodes);
                            defer a.free(requested_scope);
                            const retained_scope = try contracts.encodeOwned(wc.NodeScope, a, origin.nodes);
                            defer a.free(retained_scope);
                            if (!same(requested_scope, retained_scope)) return error.InvalidArchive;
                            // Value access already reconstructs the exact bytes
                            // from the journal-bound observation and scope.
                            return;
                        },
                        .authorized_input => {
                            if (materialize.sources.items.len != 0) return error.InvalidArchive;
                            const ref = context.input orelse return error.InvalidArchive;
                            try workspaceSnapshotAccess(parent, ref);
                            derivation = .{ .kind = .acquisition, .sources = .{ .items = &.{} }, .frozen_input = ref };
                            // workspaceValueReference checks the actual schema
                            // and payload against this exact frozen input.
                        },
                        .snapshot => |selection| {
                            if (materialize.sources.items.len != 0) return error.InvalidArchive;
                            derivation = .{ .kind = .acquisition, .sources = .{ .items = &.{} }, .acquisition = try self.workspaceSnapshotRange(a, parent, context.snapshot orelse return error.InvalidArchive, selection) };
                        },
                        .value => |input| {
                            for (materialize.sources.items) |ref| try sources.append(a, (try self.workspaceValueReference(a, parent.id, ref)).artifact);
                            switch (input) {
                                .reference => |ref| {
                                    const origin = try self.workspaceValueReference(a, parent.id, ref);
                                    if (sources.items.len == 0) {
                                        if (!std.meta.eql(origin.artifact, actual.artifact)) return error.InvalidArchive;
                                        return;
                                    }
                                    try sources.append(a, origin.artifact);
                                    schema = origin.schema;
                                    payload = origin.value;
                                },
                                .inline_json => |inline_value| {
                                    schema = try self.workspaceOwnedDescriptor(a, parent.id, inline_value.schema);
                                    const descriptor = try self.store().object(a, schema, null);
                                    defer a.free(descriptor);
                                    const text = inline_value.json_text.bytes;
                                    var parsed = try json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
                                    defer parsed.deinit();
                                    const bytes = try @import("dynamic_values.zig").encode(a, descriptor, parsed.value);
                                    defer a.free(bytes);
                                    payload = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
                                },
                            }
                            derivation = .{ .kind = if (sources.items.len == 0) .hypothesis else .judgment, .sources = .{ .items = sources.items } };
                        },
                    }
                    const provenance = try contracts.encodeOwned(workspace.Derivation, a, derivation);
                    defer a.free(provenance);
                    if (!std.meta.eql(actual.schema, schema) or !std.meta.eql(actual.value, payload) or
                        !std.meta.eql(actual.provenance, state.Reference{ .digest = storage.digest(provenance), .bytes = provenance.len })) return error.InvalidArchive;
                },
                else => return error.InvalidArchive,
            }
        }

        // Validate the receipt's operation before interpreting any declared
        // publication. Neither the receipt kind nor an empty list can bypass it.
        fn validateWorkspaceAdmission(self: *Self, a: std.mem.Allocator, parent: state.Task, event_value: state.Event, command: workspace.PublicationCommand, admission: WorkspaceAdmission) !void {
            const items = event_value.workspace_publications.items;
            const kind: @FieldType(wc.Ref, "kind") = switch (command) {
                .build => .program,
                .specialize => .runtime,
                .context => |context| switch (context.command) {
                    .materialize => .value,
                    .select => .view,
                    else => return error.InvalidArchive,
                },
                else => .work,
            };
            if (admission.kind != kind) return error.InvalidArchive;
            const count: usize = switch (command) {
                .build, .context, .specialize => 0,
                .delegate => 2,
                else => 1,
            };
            if (items.len != count) return error.InvalidArchive;
            if (count != 0 and !std.meta.eql(items[0].work, admission.work)) return error.InvalidArchive;
            const request = switch (command) {
                .specialize => |selection| blk: {
                    var selected = try self.workspaceRuntime(a, parent.id, admission.work, selection.program);
                    defer selected.deinit();
                    const hooks = selected.admitted.content.value.hooks;
                    if (hooks.control != selection.hooks.control or hooks.storage != selection.hooks.storage) return error.InvalidArchive;
                    break :blk try operation(workspace.SpecializeRequest, a, .{ .task = parent.id, .program = selection.program, .hooks = selection.hooks });
                },
                .realize => |selection| try operation(workspace.RealizeRequest, a, .{ .task = parent.id, .work = admission.work, .execution = selection.execution, .control = selection.control, .realization = selection.realization, .runtime = selection.runtime }),
                .pump => |selection| blk: {
                    if (!std.meta.eql(try wp.identity(selection.expected.work, .work), admission.work)) return error.InvalidArchive;
                    break :blk try operation(workspace.PumpRequest, a, .{ .task = parent.id, .command = selection });
                },
                .request_cut => |selection| blk: {
                    if (!std.meta.eql(try wp.identity(selection.expected.work, .work), admission.work)) return error.InvalidArchive;
                    break :blk try operation(workspace.CutRequest, a, .{ .task = parent.id, .command = selection });
                },
                .build => blk: {
                    var program = try self.workspaceProgram(a, parent.id, admission.work);
                    defer program.deinit();
                    const artifact = program.value.description;
                    if (artifact.source_kind != .source_records and artifact.source_kind != .component_recipe) return error.InvalidArchive;
                    break :blk try operation(workspace.BuildRequest, a, .{ .task = parent.id, .source = .{ .bytes = try self.store().object(a, artifact.source, null) }, .source_kind = @fromBackingInt(@intCast(@backingInt(artifact.source_kind))), .catalog = artifact.catalog, .exposures = artifact.exposures });
                },
                .context => |context| blk: {
                    try self.validateWorkspaceContextOutput(a, parent, context, admission.work, event_value.seq);
                    break :blk try operation(workspace.ContextRequest, a, .{ .task = parent.id, .command = context.command, .snapshot = context.snapshot, .input = context.input });
                },
                .start => |start| blk: {
                    var work = try self.retainedWorkspaceWork(a, parent.id, admission.work);
                    defer work.deinit();
                    if (!start.origin) try self.validateWorkspaceInitialInput(a, work.value);
                    break :blk try operation(workspace.StartRequest, a, .{ .task = parent.id, .program = work.value.program, .input = .{ .bytes = try self.store().object(a, work.value.input, null) }, .policy = start.policy, .origin = if (start.origin) work.value.input_value else null, .runtime = start.runtime });
                },
                .control => |control| try operation(workspace.ControlRequest, a, .{ .task = parent.id, .work = admission.work, .execution = control.execution, .control = control.control, .command = control.command }),
                .interact => |interaction| try operation(workspace.InteractionRequest, a, .{ .task = parent.id, .interaction = interaction }),
                .delegate => |selection| blk: {
                    const target = try wp.identity(selection.expected.work, .work);
                    if (!std.meta.eql(items[1].work, target) or std.meta.eql(items[0].work, target)) return error.InvalidArchive;
                    var child = try self.retainedWorkspaceWork(a, parent.id, admission.work);
                    defer child.deinit();
                    try self.validateWorkspaceInitialInput(a, child.value);
                    break :blk try operation(workspace.DelegationRequest, a, .{ .task = parent.id, .command = selection });
                },
            };
            if (!std.meta.eql(request, admission.request)) return error.InvalidArchive;
        }

        /// An originless admission derives this identity from the constructor;
        /// equal schema/payload bytes do not authorize different ancestry.
        fn validateWorkspaceInitialInput(self: *Self, a: std.mem.Allocator, work: workspace.Work) !void {
            const ref = work.input_value orelse return error.InvalidArchive;
            const input = try self.workspaceValueReference(a, work.task, try wp.reference(a, .value, ref.digest));
            const provenance = try contracts.encodeOwned(workspace.Derivation, a, .{ .kind = .hypothesis, .sources = .{ .items = &.{} } });
            defer a.free(provenance);
            if (!std.meta.eql(input.provenance, state.Reference{ .digest = storage.digest(provenance), .bytes = provenance.len })) return error.InvalidArchive;
        }

        fn validateWorkspaceControl(self: *Self, a: std.mem.Allocator, parent: state.Task, event_value: state.Event, item: state.WorkPublication, prior: ?state.WorkPublication, command: ?workspace.PublicationCommand, admission: ?WorkspaceAdmission) !void {
            const actual = item.control;
            const execution_changed = if (prior) |before| item.execution_revision != before.execution_revision else true;
            if (execution_changed) {
                var required = false;
                if (item.runtime) |runtime| {
                    var selected = try self.workspaceRuntime(a, parent.id, runtime.digest, null);
                    defer selected.deinit();
                    required = selected.admitted.content.value.hooks.enabled();
                }
                if (item.runtime_trace != required) return error.InvalidArchive;
            } else if (command != null and command.? == .realize) {
                if (item.runtime_trace) return error.InvalidArchive;
            } else if (item.runtime_trace != prior.?.runtime_trace) return error.InvalidArchive;
            if (execution_changed and item.outer_operation != null) return error.InvalidArchive;
            if (item.outer_operation) |current_capsule| {
                if (prior) |before| {
                    if (before.outer_operation) |previous_capsule| {
                        if (!std.meta.eql(current_capsule, previous_capsule)) {
                            const before_bytes = try self.store().object(a, previous_capsule, null);
                            defer a.free(before_bytes);
                            const after_bytes = try self.store().object(a, current_capsule, null);
                            defer a.free(after_bytes);
                            var previous = try kosmos.RuntimeCapsule.read(a, before_bytes);
                            defer previous.deinit();
                            var current = try kosmos.RuntimeCapsule.read(a, after_bytes);
                            defer current.deinit();
                            if (current.value.record.outer_revision <= previous.value.record.outer_revision or
                                current.value.record.guest_revision != previous.value.record.guest_revision or
                                !std.meta.eql(current.value.record.artifact, previous.value.record.artifact) or
                                !same(current.value.command, previous.value.command)) return error.InvalidArchive;
                        }
                    } else if (command == null or command.? != .pump) return error.InvalidArchive;
                } else return error.InvalidArchive;
            } else if (!execution_changed and prior != null and prior.?.outer_operation != null) return error.InvalidArchive;
            if ((actual.outcome == .requested) != (actual.delivery != null) or (actual.port and actual.delivery == null)) return error.InvalidArchive;
            var expected = actual;
            if (prior) |before| {
                if (command == null or command.? != .realize) {
                    if (!std.meta.eql(item.runtime, before.runtime) or item.realization_revision != before.realization_revision) return error.InvalidArchive;
                }
                if (item.execution_revision == before.execution_revision) {
                    if (!std.meta.eql(item.checkpoint, before.checkpoint)) return error.InvalidArchive;
                    const pumping = item.outer_operation != null and !std.meta.eql(item.outer_operation, before.outer_operation);
                    if (!pumping and (command == null or (command.? != .realize and command.? != .request_cut)))
                        if (!std.meta.eql(item.runtime_capsule, before.runtime_capsule)) return error.InvalidArchive;
                } else if (item.runtime_capsule != null) return error.InvalidArchive;
                expected.policy = before.control.policy;
                expected.cancellation = before.control.cancellation;
                expected.blocker = before.control.blocker;
                expected.schedule = before.control.schedule;
                if (actual.instrument != before.control.instrument) return error.InvalidArchive;
                if (item.execution_revision == before.execution_revision and (actual.outcome != before.control.outcome or actual.port != before.control.port or actual.cancellation_applied != before.control.cancellation_applied)) return error.InvalidArchive;
            } else {
                if (item.execution_revision != 1 or item.control_revision != 1 or command == null) return error.InvalidArchive;
                if (item.realization_revision != 0 or item.runtime_capsule != null) return error.InvalidArchive;
                expected.cancellation = null;
                expected.blocker = null;
                if (actual.cancellation_applied) return error.InvalidArchive;
            }

            if (command) |decoded| switch (decoded) {
                .build, .context, .specialize => return error.InvalidArchive,
                .realize => |selection| {
                    const before = prior orelse return error.InvalidArchive;
                    if (before.outer_operation != null or selection.execution != before.execution_revision or selection.control != before.control_revision or selection.realization != before.realization_revision or
                        item.execution_revision != before.execution_revision or item.control_revision -| before.control_revision != 1 or item.realization_revision -| before.realization_revision != 1 or
                        !std.meta.eql(item.runtime, selection.runtime) or !std.meta.eql(item.runtime_capsule, selection.target) or
                        actual.delivery == .dispatching or actual.delivery == .unknown or actual.delivery != before.control.delivery) return error.InvalidArchive;
                    try self.validateRuntimeSwitch(a, parent.id, item, before, selection);
                },
                .pump => |selection| {
                    const before = prior orelse return error.InvalidArchive;
                    if (selection.expected.execution_revision != before.execution_revision or selection.expected.control_revision != before.control_revision or
                        !std.meta.eql(try wp.identity(selection.expected.work, .work), item.work) or item.control_revision -| before.control_revision != 1 or
                        selection.base_quantum == 0 or selection.base_quantum > 1048576) return error.InvalidArchive;
                    if (execution_changed) {
                        expected.schedule = publicationSchedule(expected);
                    } else {
                        if (item.outer_operation == null or actual.delivery != before.control.delivery) return error.InvalidArchive;
                        expected.schedule = if (expected.cancellation != null or expected.policy.continuation == .owner_scheduled) .queued else .parked;
                    }
                },
                .request_cut => |selection| {
                    const before = prior orelse return error.InvalidArchive;
                    if (selection.expected.execution_revision != before.execution_revision or selection.expected.control_revision != before.control_revision or
                        !std.meta.eql(try wp.identity(selection.expected.work, .work), item.work) or item.execution_revision != before.execution_revision or item.control_revision -| before.control_revision != 1 or
                        actual.delivery == .dispatching or actual.delivery == .unknown or actual.delivery != before.control.delivery or item.runtime_capsule == null) return error.InvalidArchive;
                    const capsule_bytes = try self.store().object(a, item.runtime_capsule.?, null);
                    defer a.free(capsule_bytes);
                    var capsule = try kosmos.RuntimeCapsule.read(a, capsule_bytes);
                    defer capsule.deinit();
                    if (!same(@tagName(capsule.value.record.kind), @tagName(selection.level))) return error.InvalidArchive;
                },
                .start => |start| {
                    if (prior != null or actual.instrument) return error.InvalidArchive;
                    if (!std.meta.eql(item.runtime, start.runtime)) return error.InvalidArchive;
                    expected.policy = start.policy;
                    expected.schedule = publicationSchedule(expected);
                },
                .control => |control| {
                    const before = prior orelse return error.InvalidArchive;
                    if (control.execution != before.execution_revision or control.control != before.control_revision) return error.InvalidArchive;
                    if (before.control.outcome == .completed or before.control.outcome == .failed or before.control.outcome == .cancelled) return error.InvalidArchive;
                    const advanced = item.execution_revision > before.execution_revision;
                    if (control.command == .advance) {
                        if (item.control_revision != before.control_revision) return error.InvalidArchive;
                        if (advanced) {
                            expected.schedule = publicationSchedule(expected);
                        } else {
                            if (before.outer_operation == null or item.outer_operation == null or actual.delivery != before.control.delivery) return error.InvalidArchive;
                            expected.schedule = if (expected.cancellation != null or expected.policy.continuation == .owner_scheduled) .queued else .parked;
                        }
                    } else {
                        if (item.control_revision -| before.control_revision != 1) return error.InvalidArchive;
                        switch (control.command) {
                            .park => {
                                if (advanced or actual.delivery != before.control.delivery) return error.InvalidArchive;
                                expected.schedule = .parked;
                            },
                            .delegate => |policy| {
                                if (advanced) return error.InvalidArchive;
                                expected.policy = policy;
                                const rearmed = before.control.delivery == .not_sent and before.control.instrument;
                                if (actual.delivery != (if (rearmed) .ready else before.control.delivery)) return error.InvalidArchive;
                                const runnable = item.outer_operation != null or actual.delivery == null or actual.delivery == .settled_reply or actual.delivery == .captured or (actual.delivery == .ready and actual.instrument);
                                expected.schedule = if (policy.continuation == .explicit_only) .parked else if (actual.delivery == .dispatching) .active else if (runnable) .queued else .parked;
                            },
                            .cancel => |reason| {
                                if (expected.cancellation == null) expected.cancellation = reason;
                                if (advanced) {
                                    expected.schedule = publicationSchedule(expected);
                                } else {
                                    if (actual.delivery != before.control.delivery) return error.InvalidArchive;
                                    expected.schedule = if (item.outer_operation != null) .queued else switch (actual.delivery orelse return error.InvalidArchive) {
                                        .dispatching => .active,
                                        .captured => .queued,
                                        .unknown => .parked,
                                        else => return error.InvalidArchive,
                                    };
                                }
                            },
                            .advance => unreachable,
                        }
                    }
                },
                .interact => |interaction| {
                    const before = prior orelse return error.InvalidArchive;
                    if (!std.meta.eql(try wp.identity(interaction.expected.work, .work), item.work) or
                        interaction.expected.execution_revision != before.execution_revision or interaction.expected.control_revision != before.control_revision or
                        item.execution_revision != before.execution_revision or item.control_revision -| before.control_revision != 1 or
                        actual.delivery != .settled_reply) return error.InvalidArchive;
                    expected.schedule = .queued;
                },
                .delegate => |selection| {
                    if (selection.interpretation == .none) return error.InvalidArchive;
                    const target = try wp.identity(selection.expected.work, .work);
                    if (std.meta.eql(item.work, target)) {
                        const before = prior orelse return error.InvalidArchive;
                        if (selection.expected.execution_revision != before.execution_revision or selection.expected.control_revision != before.control_revision or
                            item.execution_revision != before.execution_revision or item.control_revision -| before.control_revision != 1 or
                            actual.delivery != before.control.delivery) return error.InvalidArchive;
                        expected.policy = selection.policy;
                        expected.schedule = .parked;
                    } else {
                        if (prior != null or !actual.instrument or !std.meta.eql((admission orelse return error.InvalidArchive).work, item.work)) return error.InvalidArchive;
                        if (item.runtime != null) return error.InvalidArchive;
                        expected.policy = .{ .stop = .terminal, .continuation = .owner_scheduled };
                        expected.schedule = publicationSchedule(expected);
                    }
                },
            } else {
                const before = prior orelse return error.InvalidArchive;
                if (item.execution_revision > before.execution_revision) {
                    if (item.control_revision != before.control_revision) return error.InvalidArchive;
                    expected.schedule = publicationSchedule(expected);
                } else if (item.outer_operation != null and before.outer_operation != null and item.control_revision == before.control_revision) {
                    if (actual.delivery != before.control.delivery) return error.InvalidArchive;
                    expected.schedule = if (expected.cancellation != null or expected.policy.continuation == .owner_scheduled) .queued else .parked;
                } else if (item.control_revision > before.control_revision) {
                    if (item.execution_revision != before.execution_revision or !try self.workspaceStoppedAt(a, parent.id, event_value.seq - 1) or actual.delivery != before.control.delivery) return error.InvalidArchive;
                    expected.schedule = .parked;
                } else {
                    if (item.execution_revision != before.execution_revision or item.control_revision != before.control_revision or actual.delivery == null) return error.InvalidArchive;
                    if (actual.delivery == before.control.delivery and actual.blocker != null) {
                        // A dispatch/interpretation rejection records an actual
                        // environmental diagnostic, not an execution result.
                        if (actual.delivery != .ready and actual.delivery != .captured and actual.delivery != .unknown) return error.InvalidArchive;
                        expected.blocker = actual.blocker;
                        expected.schedule = .parked;
                    } else switch (actual.delivery.?) {
                        .dispatching => {
                            expected.schedule = .active;
                            expected.blocker = null;
                        },
                        .captured, .settled_reply => {
                            expected.schedule = if (before.control.schedule == .parked) .parked else .queued;
                            expected.blocker = null;
                        },
                        .unknown => {
                            expected.schedule = .parked;
                            expected.blocker = .unavailable_environment;
                        },
                        .not_sent => {
                            const cancelling = actual.cancellation != null and !actual.cancellation_applied;
                            expected.schedule = if (cancelling and before.control.schedule != .parked) .queued else .parked;
                            expected.blocker = if (cancelling) null else .unavailable_environment;
                        },
                        else => return error.InvalidArchive,
                    }
                }
            }
            const expected_bytes = try contracts.encodeOwned(workspace.ControlObservation, a, expected);
            defer a.free(expected_bytes);
            const actual_bytes = try contracts.encodeOwned(workspace.ControlObservation, a, actual);
            defer a.free(actual_bytes);
            if (!same(expected_bytes, actual_bytes)) return error.InvalidArchive;
        }

        fn workspacePublicationAt(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, id: state.Digest, watermark: u64) !u64 {
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq DESC", &.{ .{ .blob = &task_id }, .{ .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive } });
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                for (saved.value.workspace_publications.items) |item| if (std.meta.eql(item.work, id)) return saved.value.seq;
            }
            return error.InvalidArchive;
        }

        fn validateWorkspacePublications(self: *Self, a: std.mem.Allocator, parent: state.Task, records: []const state.ArchiveRecord) !void {
            const Position = struct { publication: state.WorkPublication, seq: u64 };
            var latest: std.AutoHashMap(state.Digest, Position) = .init(a);
            defer latest.deinit();
            var admissions: std.AutoHashMap(u64, WorkspaceAdmission) = .init(a);
            defer admissions.deinit();
            var replies: std.AutoHashMap(state.Digest, void) = .init(a);
            defer replies.deinit();
            var operations = try self.store().database.prepare("SELECT o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &parent.id }});
            defer operations.deinit();
            while (try operations.step() == .row) {
                var receipt_value = try contracts.decodeOwned(state.Receipt, a, try operations.bytes(0));
                defer receipt_value.deinit();
                const value = receipt_value.value;
                if (value.method != .workspace) continue;
                const entry = try admissions.getOrPut(value.revision);
                if (entry.found_existing) return error.InvalidArchive;
                entry.value_ptr.* = .{ .request = value.request_digest, .work = value.workspace orelse return error.InvalidArchive, .kind = value.workspace_kind orelse return error.InvalidArchive };
            }
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq", &.{.{ .blob = &parent.id }});
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                const event_value = saved.value;
                var command: ?contracts.Decoded(workspace.PublicationCommand) = null;
                defer if (command) |*decoded| decoded.deinit();
                const admission = if (event_value.kind == .workspace) admissions.fetchRemove(event_value.revision) else null;
                if (event_value.kind == .workspace) {
                    const ref = event_value.workspace_command orelse return error.InvalidArchive;
                    command = try contracts.decodeOwned(workspace.PublicationCommand, a, try self.store().object(a, ref, null));
                    try self.validateWorkspaceAdmission(a, parent, event_value, command.?.value, (admission orelse return error.InvalidArchive).value);
                    if (command.?.value == .interact) {
                        const reply = try self.workspaceInteractionReply(a, parent.id, command.?.value.interact);
                        try requireArchiveRecord(records, .workspace_port_reply, reply.id);
                        if ((try replies.getOrPut(reply.id)).found_existing) return error.InvalidArchive;
                    }
                } else if (event_value.workspace_command != null) return error.InvalidArchive;

                if (event_value.kind == .workspace_progress and event_value.workspace_publications.items.len == 0) return error.InvalidArchive;
                if (event_value.kind == .workspace_read) {
                    var parsed = try json.parseAsset(a, event_value.data.bytes, event_value.data.bytes.len);
                    defer parsed.deinit();
                    const text = try json.text(parsed.value.object.get("occurrence_id") orelse return error.InvalidArchive);
                    const id = try wp.identity(.{ .kind = .work, .id = .{ .bytes = text } }, .work);
                    try requireArchiveRecord(records, .workspace_reply, id);
                    var evidence = try self.record(workspace.ReplyObservation, a, "workspace_reply", id, parent.id);
                    defer evidence.deinit();
                    if (evidence.value.evidence != .read) return error.InvalidArchive;
                    const at = switch (evidence.value.evidence.read) {
                        .immutable => return error.InvalidArchive,
                        .scope => |value| value,
                        .works => |value| value.event_watermark,
                        .wait => |value| value.event_watermark,
                    };
                    if (event_value.seq == 0 or at != event_value.seq - 1) return error.InvalidArchive;
                }
                if (event_value.workspace_publications.items.len != 0 and event_value.kind != .workspace and event_value.kind != .workspace_progress) return error.InvalidArchive;
                if (event_value.workspace_publications.items.len != 0) {
                    var parsed = try json.parseAsset(a, event_value.data.bytes, event_value.data.bytes.len);
                    defer parsed.deinit();
                    const text = try json.text(parsed.value.object.get("workspace_id") orelse return error.InvalidArchive);
                    const id = try wp.identity(.{ .kind = .work, .id = .{ .bytes = text } }, .work);
                    if (!std.meta.eql(id, event_value.workspace_publications.items[0].work)) return error.InvalidArchive;
                }
                for (event_value.workspace_publications.items) |item| {
                    try requireArchiveRecord(records, .workspace_work, item.work);
                    if (latest.get(item.work)) |prior| {
                        if (prior.seq >= event_value.seq) return error.InvalidArchive;
                        inline for (.{ "execution_revision", "control_revision" }) |field| {
                            const before = @field(prior.publication, field);
                            const after = @field(item, field);
                            if (after < before or after - before > 1) return error.InvalidArchive;
                        }
                    } else if (item.execution_revision != 1 or item.control_revision != 1) return error.InvalidArchive;
                    try self.validateWorkspaceControl(a, parent, event_value, item, if (latest.get(item.work)) |prior| prior.publication else null, if (command) |decoded| decoded.value else null, if (admission) |entry| entry.value else null);
                    var retained = item;
                    if (item.control.cancellation) |reason| retained.control.cancellation = .{ .bytes = try a.dupe(u8, reason.bytes) };
                    try latest.put(item.work, .{ .publication = retained, .seq = event_value.seq });
                }
            }
            if (admissions.count() != 0) return error.InvalidArchive;
            for (records) |row| {
                if (row.kind == .workspace_port_reply and !replies.contains(row.id)) return error.InvalidArchive;
                if (row.kind != .workspace_work) continue;
                const current = try self.freezeWorkspaceWork(a, parent.id, try wp.reference(a, .work, row.id), true);
                const last = latest.get(row.id) orelse return error.InvalidArchive;
                if (last.seq != current.work.event_watermark or !try samePublication(a, last.publication, try workPublication(a, current))) return error.InvalidArchive;
            }
        }

        fn workspaceReadBasis(self: *Self, allocator: std.mem.Allocator, parent: state.Task, command: wc.Command) ![]u8 {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var basis: workspace.ReadObservation = .immutable;
            var refs: []const wc.Ref = &.{};
            var one: [1]wc.Ref = undefined;
            var retained = false;
            var collect = false;
            switch (command) {
                .work => |w| switch (w) {
                    .inspect => |r| {
                        one[0] = r.work;
                        refs = &one;
                    },
                    .collect => |r| {
                        refs = r.works.items;
                        collect = true;
                    },
                    .wait => |r| refs = r.works.items,
                    else => return error.InvalidState,
                },
                .context => |c| switch (c) {
                    .inspect => basis = .{ .scope = parent.event_high },
                    .expand => |r| if (r.reference.kind == .work) {
                        one[0] = r.reference;
                        refs = &one;
                        retained = true;
                    },
                    else => return error.InvalidState,
                },
                .program => |p| if (p == .build or p == .specialize) return error.InvalidState,
                .placement => return error.InvalidState,
            }
            if (command == .work or refs.len != 0) {
                const observations = try a.alloc(?workspace.WorkObservation, refs.len);
                for (refs, observations) |ref, *out| out.* = self.freezeWorkspaceWork(a, parent.id, ref, retained) catch |err| blk: {
                    if (!collect or err != error.ArtifactUnavailable) return err;
                    break :blk null;
                };
                basis = if (command == .work and command.work == .wait) .{ .wait = .{
                    .works = .{ .items = observations },
                    .interrupted = parent.messages.items.len != 0 or parent.cancellation != null,
                    .event_watermark = parent.event_high,
                } } else .{ .works = .{ .works = .{ .items = observations }, .event_watermark = parent.event_high } };
            }
            return contracts.encodeOwned(workspace.ReadObservation, allocator, basis);
        }

        fn rejectWorkspace(self: *Self, a: std.mem.Allocator, parent: state.Task, pending: occurrence.Occurrence, stage: @FieldType(@FieldType(workspace.ReplyEvidence, "rejected"), "stage"), err: anyerror) !Step {
            if (self.store().fenced or err == error.OutOfMemory or err == error.StorageUnavailable) return err;
            return self.settleWorkspaceReply(a, parent, pending, try workspaceRejection(a, err), .{ .rejected = .{ .stage = stage, .code = try name(@errorName(err)) } });
        }

        fn validateHistoricalOccurrence(self: *Self, a: std.mem.Allocator, observed: workspace.WorkObservation) !void {
            const work = observed.work;
            if (observed.occurrence) |pending| {
                if (!std.meta.eql(work.current_occurrence, pending.id) or !std.meta.eql(pending.task, work.task) or !std.meta.eql(pending.work, work.id)) return error.InvalidArchive;
                var current = try self.record(occurrence.Occurrence, a, "occurrence", pending.id, work.task);
                defer current.deinit();
                if (!std.meta.eql(current.value.request, pending.request) or !std.meta.eql(current.value.request_object, pending.request_object)) return error.InvalidArchive;
                // A settled observation must name the same acquired evidence;
                // later admission may change only its enclosing state tag.
                const acquired: ?occurrence.Acquired = switch (pending.state) {
                    .settled_reply => |r| r,
                    .admitted => |v| if (v == .reply) v.reply else null,
                    else => null,
                };
                if (acquired) |expected| {
                    const actual = switch (current.value.state) {
                        .settled_reply => |r| r,
                        .admitted => |v| if (v == .reply) v.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (!std.meta.eql(expected, actual)) return error.InvalidArchive;
                }
            } else if (work.current_occurrence != null) return error.InvalidArchive;
        }

        fn validateWorkspaceRead(self: *Self, a: std.mem.Allocator, parent: state.Task, command: wc.Command, basis: workspace.ReadObservation, records: []const state.ArchiveRecord) !void {
            if (!workspaceIsRead(command)) return error.InvalidArchive;
            var refs: []const wc.Ref = &.{};
            var one: [1]wc.Ref = undefined;
            var optional = false;
            var expected: std.meta.Tag(workspace.ReadObservation) = .immutable;
            switch (command) {
                .work => |w| switch (w) {
                    .inspect => |r| {
                        one[0] = r.work;
                        refs = &one;
                        expected = .works;
                    },
                    .collect => |r| {
                        refs = r.works.items;
                        expected = .works;
                        optional = true;
                    },
                    .wait => |r| {
                        refs = r.works.items;
                        expected = .wait;
                    },
                    else => return error.InvalidArchive,
                },
                .context => |c| switch (c) {
                    .inspect => expected = .scope,
                    .expand => |r| if (r.reference.kind == .work) {
                        one[0] = r.reference;
                        refs = &one;
                        expected = .works;
                    },
                    else => return error.InvalidArchive,
                },
                .program => {},
                .placement => return error.InvalidArchive,
            }
            if (std.meta.activeTag(basis) != expected) return error.InvalidArchive;
            switch (basis) {
                .immutable => {},
                .scope => |watermark| {
                    if (watermark > parent.event_high) return error.InvalidArchive;
                    for (try self.workspaceScopeAt(a, parent.id, watermark)) |id| try requireArchiveRecord(records, .workspace_work, id);
                },
                .works, .wait => {
                    const observed = if (basis == .works) basis.works.works.items else basis.wait.works.items;
                    const watermark = if (basis == .works) basis.works.event_watermark else basis.wait.event_watermark;
                    if (watermark > parent.event_high) return error.InvalidArchive;
                    const visible = if (optional) try self.workspaceScopeAt(a, parent.id, watermark) else &.{};
                    if (observed.len != refs.len) return error.InvalidArchive;
                    if (basis == .wait) {
                        if (basis.wait.event_watermark > parent.event_high or basis.wait.interrupted != try self.workspaceInterruptedAt(a, parent.id, basis.wait.event_watermark)) return error.InvalidArchive;
                    }
                    for (observed, refs) |item, ref| {
                        const id = try wp.identity(ref, .work);
                        const snapshot = item orelse {
                            if (!optional) return error.InvalidArchive;
                            for (visible) |published| if (std.meta.eql(published, id)) return error.InvalidArchive;
                            continue;
                        };
                        if (!std.meta.eql(snapshot.work.id, id) or snapshot.work.event_watermark > watermark) return error.InvalidArchive;
                        try requireArchiveRecord(records, .workspace_work, id);
                        try self.validateWorkspaceWorkSnapshot(a, parent, snapshot, records);
                        if (snapshot.work.event_watermark != try self.workspacePublicationAt(a, parent.id, id, watermark)) return error.InvalidArchive;
                        try self.validateHistoricalOccurrence(a, snapshot);
                    }
                },
            }
        }

        fn validateWorkspaceReply(self: *Self, a: std.mem.Allocator, parent: state.Task, pending: occurrence.Occurrence, entry: registry.Entry, request: data.invocation.Request, saved: workspace.ReplyObservation, reply: []const u8, records: []const state.ArchiveRecord) anyerror!void {
            if (pending.work != null or !std.meta.eql(saved.id, pending.id) or !std.meta.eql(saved.task, parent.id) or !std.meta.eql(saved.request, pending.request_object)) return error.InvalidArchive;
            const acquired = switch (pending.state) {
                .settled_reply => |r| r,
                .admitted => |v| if (v == .reply) v.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (!std.meta.eql(acquired.attempt, saved.attempt)) return error.InvalidArchive;
            const authorized_bytes = self.authorizeWorkspace(a, parent, entry, request.binding.payload) catch |err| {
                if (saved.evidence != .rejected or saved.evidence.rejected.stage != .authorization or !same(saved.evidence.rejected.code.bytes, @errorName(err))) return error.InvalidArchive;
                const expected = try contracts.encodeOwned(wc.Reply, a, try workspaceRejection(a, err));
                if (!same(reply, expected)) return error.InvalidArchive;
                return;
            };
            var authorized = try contracts.decodeOwned(workspace.Authorized, a, authorized_bytes);
            defer authorized.deinit();
            const command = authorized.value.command;
            const operation_id = std.fmt.bytesToHex(pending.id, .lower);
            const expected: wc.Reply = switch (saved.evidence) {
                .placement => |reference| placement_reply: {
                    const p = @import("placement.zig");
                    if (command != .placement) return error.InvalidArchive;
                    const bytes = try self.store().object(a, reference, null);
                    defer a.free(bytes);
                    var record_value = try contracts.decodeOwned(p.ActionRecord, a, bytes);
                    defer record_value.deinit();
                    const action = record_value.value.action;
                    try p.verify(p.Action, a, action, action.value.owner);
                    const id = p.operationId(action.value.owner, parent.id, &operation_id, .action);
                    if (!std.meta.eql(id, record_value.value.id) or !std.meta.eql(id, action.value.id) or
                        !std.meta.eql(parent.id, action.value.task) or !same(action.value.operation.bytes, &operation_id)) return error.InvalidArchive;
                    try requireArchiveRecord(records, .placement_action, id);
                    var indexed = try self.record(p.ActionRecord, a, "placement_action", id, parent.id);
                    defer indexed.deinit();
                    if (!std.meta.eql(indexed.value.action.signature, action.signature)) return error.InvalidArchive;
                    const wanted = try contracts.encodeOwned(wc.Placement, a, command.placement);
                    defer a.free(wanted);
                    const actual = try contracts.encodeOwned(wc.Placement, a, action.value.request);
                    defer a.free(actual);
                    if (!same(wanted, actual)) return error.InvalidArchive;
                    break :placement_reply try placementReplyCopy(a, action.value.reply);
                },
                .read => |basis| blk: {
                    const watermark: ?u64 = switch (basis) {
                        .immutable => null,
                        .scope => |at| at,
                        .works => |works| works.event_watermark,
                        .wait => |wait| wait.event_watermark,
                    };
                    if (watermark) |at| {
                        // The read's own journal position anchors its prefix;
                        // a forged cutoff cannot hide already-published work.
                        const sequence = std.math.add(u64, at, 1) catch return error.InvalidArchive;
                        var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &parent.id }, .{ .integer = std.math.cast(i64, sequence) orelse return error.InvalidArchive } });
                        defer query.deinit();
                        if (try query.step() != .row) return error.InvalidArchive;
                        var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                        defer event_value.deinit();
                        if (event_value.value.kind != .workspace_read) return error.InvalidArchive;
                        var event_data = try json.parse(a, event_value.value.data.bytes, .{});
                        defer event_data.deinit();
                        const id = try json.text(event_data.value.object.get("occurrence_id") orelse return error.InvalidArchive);
                        if (!same(id, &std.fmt.bytesToHex(pending.id, .lower))) return error.InvalidArchive;
                    }
                    try self.validateWorkspaceRead(a, parent, command, basis, records);
                    break :blk try self.workspaceCommandFrom(a, &operation_id, parent.id, authorized.value, basis);
                },
                .admitted => |admitted| blk: {
                    if (workspaceIsRead(command) or (command == .program and command.program == .build)) return error.InvalidArchive;
                    if (self.workspace_replay != null) return error.InvalidArchive;
                    self.workspace_replay = .{ .replayed = admitted.replayed, .records = records };
                    defer self.workspace_replay = null;
                    const result = try self.workspaceCommandAuthorized(a, &operation_id, parent.id, authorized.value);
                    if (result.disposition == .rejected) return error.InvalidArchive;
                    break :blk result;
                },
                .rejected => |failure| blk: {
                    if (failure.stage == .authorization or failure.code.bytes.len == 0) return error.InvalidArchive;
                    if (failure.stage == .preparation) {
                        if (command != .program or command.program != .build) return error.InvalidArchive;
                        _ = self.workspacePrepareBuild(a, parent, authorized.value) catch |err| {
                            if (!same(failure.code.bytes, @errorName(err))) return error.InvalidArchive;
                            break :blk try workspaceRejection(a, err);
                        };
                        return error.InvalidArchive;
                    }
                    const key = try self.operationKey(a, &operation_id);
                    if (try self.store().savedReceipt(a, &key)) |committed| {
                        a.free(committed);
                        return error.InvalidArchive;
                    }
                    // A captured operation failure is a diagnostic event. It
                    // can carry no result, selected view, program or evidence.
                    var observation = json.object();
                    try json.put(a, &observation, "error", json.string(failure.code.bytes));
                    break :blk .{ .disposition = .rejected, .observation_json = .{ .bytes = try json.canonical(a, observation) } };
                },
            };
            if (!same(reply, try contracts.encodeOwned(wc.Reply, a, expected))) return error.InvalidArchive;
        }

        fn dispatchWorkspace(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, entry: registry.Entry, payload: []const u8) !Step {
            const authorized = self.authorizeWorkspace(a, initial, entry, payload) catch |err| {
                return self.rejectWorkspace(a, initial, pending, .authorization, err);
            };
            defer a.free(authorized);
            var command = try contracts.decodeOwned(workspace.Authorized, a, authorized);
            defer command.deinit();
            const operation_id = std.fmt.bytesToHex(pending.id, .lower);
            if (command.value.command == .program and command.value.command.program == .build) {
                if (self.work != null) return .idle;
                const prepared = self.workspacePrepareBuild(a, initial, command.value) catch |err| {
                    return self.rejectWorkspace(a, initial, pending, .preparation, err);
                };
                defer a.free(prepared);
                const request_bytes = try self.store().object(a, pending.request_object, null);
                defer a.free(request_bytes);
                return self.dispatchAcquisition(a, initial, pending, entry, request_bytes, prepared, .workspace_build);
            }
            if (command.value.command == .work and command.value.command.work == .wait) {
                const selection = command.value.command.work.wait;
                const ready = self.workspaceWaitReady(a, initial, selection) catch |err| return self.rejectWorkspace(a, initial, pending, .operation, err);
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
            var basis: ?contracts.Decoded(workspace.ReadObservation) = null;
            defer if (basis) |*frozen| frozen.deinit();
            if (workspaceIsRead(command.value.command)) {
                const bytes = self.workspaceReadBasis(a, initial, command.value.command) catch |err| return self.rejectWorkspace(a, initial, pending, .operation, err);
                defer a.free(bytes);
                basis = try contracts.decodeOwned(workspace.ReadObservation, a, bytes);
            }
            const observation = try self.workspaceCommandFrom(a, &operation_id, initial.id, command.value, if (basis) |frozen| frozen.value else null);
            var parsed = try json.parseAsset(a, observation.observation_json.bytes, observation.observation_json.bytes.len);
            defer parsed.deinit();
            var placement_evidence: ?state.Reference = null;
            if (command.value.command == .placement and self.profile.placement != null) {
                const p = @import("placement.zig");
                const action_id = p.operationId(try self.placementSite(), initial.id, &operation_id, .action);
                if (try self.store().recordBytes(a, "placement_action", action_id, initial.id)) |bytes| {
                    defer a.free(bytes);
                    placement_evidence = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
                }
            }
            const evidence: workspace.ReplyEvidence = if (placement_evidence) |reference| .{ .placement = reference } else if (observation.disposition == .rejected)
                .{ .rejected = .{ .stage = .operation, .code = try name(try json.text(parsed.value.object.get("error") orelse return error.CorruptState)) } }
            else if (basis) |frozen| .{ .read = frozen.value } else .{ .admitted = .{ .replayed = (parsed.value.object.get("replayed") orelse return error.CorruptState).bool } };
            return self.settleWorkspaceReply(a, initial, pending, observation, evidence);
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
            // The retained capture/reply owns the program observation. A
            // second journal projection has no independent publication fact.
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
            if (parent.terminal() or !try self.hasLocalCustody(a, parent.id, null)) return false;
            var owned = ownership == .acquire;
            for (self.owned.items) |id| owned = owned or std.meta.eql(id, parent.id);
            if (!owned) return false;
            // Custody can retain cancellation while this launch cannot execute
            // the task. Journal writes must not turn that ownership into a wake.
            self.compatible(parent) catch |err| switch (err) {
                error.IncompatibleProfile => return false,
            };
            for (self.runnable.items) |subject| if (subject.work == null and std.meta.eql(subject.task, parent.id)) return false;
            const id = parent.current_occurrence orelse return false;
            const bytes = (try self.store().recordBytes(a, "workspace_wait", id, parent.id)) orelse return false;
            defer a.free(bytes);
            var waiting = try contracts.decodeOwned(workspace.Wait, a, bytes);
            defer waiting.deinit();
            return self.workspaceWaitReady(a, parent, waiting.value.selection);
        }

        fn settleWorkspaceReply(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence, observation: wc.Reply, evidence: workspace.ReplyEvidence) !Step {
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
            const attempt = switch (pending.state) {
                .dispatching => |dispatching| dispatching.id,
                else => return error.UnsettledOccurrence,
            };
            const binding: occurrence.Binding = .{ .id = pending.id, .task = initial.id, .request = pending.request };
            const acquired = try occurrence.acquired(pending, binding, attempt, storage.digest(bound));
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(bound);
            try self.store().createRecord(workspace.ReplyObservation, "workspace_reply", pending.id, initial.id, .{ .id = pending.id, .task = initial.id, .attempt = attempt, .request = pending.request_object, .evidence = evidence });
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, initial.id, acquired);
            if (evidence == .read and evidence.read != .immutable) {
                var event_data = json.object();
                try json.put(a, &event_data, "occurrence_id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(pending.id, .lower))));
                try self.event(&parent, .workspace_read, try json.canonical(a, event_data));
            }
            try self.persist(a, parent, fresh.value.revision, "workspace.reply", .preserve);
            return .progressed;
        }

        const SelectedRuntime = struct {
            record: contracts.Decoded(workspace.Runtime),
            admitted: kosmos.RuntimeArtifact,
            fn deinit(self: *SelectedRuntime) void {
                self.admitted.deinit();
                self.record.deinit();
            }
        };

        fn retainValidatedRuntime(self: *Self, admitted: *const kosmos.RuntimeArtifact) !void {
            var retained = try admitted.clone();
            errdefer retained.deinit();
            try self.checked_workspace_runtimes.put(self.allocator, admitted.identity, self.store().integrity_epoch);
            if (self.runtime_cache) |*cached| cached.artifact.deinit();
            self.runtime_cache = .{ .epoch = self.store().integrity_epoch, .artifact = retained };
        }

        fn workspaceRuntime(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, digest: state.Digest, program_id: ?state.Digest) !SelectedRuntime {
            const id = try workspaceContentCustody(a, task_id, digest);
            var saved = try self.record(workspace.Runtime, a, "workspace_runtime", id, task_id);
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.id, id) or !std.meta.eql(saved.value.task, task_id) or !std.meta.eql(saved.value.artifact.digest, digest)) return error.InvalidRuntime;
            var program = try self.workspaceProgram(a, task_id, saved.value.program);
            defer program.deinit();
            if (program_id) |required| if (!std.meta.eql(required, saved.value.program)) {
                var requested = try self.workspaceProgram(a, task_id, required);
                defer requested.deinit();
                if (!std.meta.eql(requested.value.description.image, program.value.description.image)) return error.InvalidRuntime;
            };
            const image = try self.store().object(a, program.value.description.image, null);
            defer a.free(image);
            const guest = try data.program_image.Admitted.decode(a, image);
            defer guest.deinit();
            var admitted = cached: {
                if (self.runtime_cache) |*cached| {
                    if (cached.epoch == self.store().integrity_epoch and std.meta.eql(cached.artifact.identity, digest)) break :cached try cached.artifact.clone();
                }
                const bytes = try self.store().object(a, saved.value.artifact, null);
                defer a.free(bytes);
                break :cached try kosmos.RuntimeArtifact.init(self.allocator, bytes, digest);
            };
            errdefer admitted.deinit();
            const bound = admitted.content.value.guest orelse return error.InvalidRuntime;
            if (!std.mem.eql(u8, &bound, &guest.identity()) or !same(admitted.content.value.manifest.compiler.horos_package, @import("native_options").horos_identity)) return error.InvalidRuntime;
            if (self.checked_workspace_runtimes.get(digest) != self.store().integrity_epoch) {
                // Validation owns and releases its large temporary arenas.
                // A caller's response arena may intentionally ignore free.
                try kosmos.RuntimeCompiler.validate(self.allocator, &admitted);
            }
            try self.retainValidatedRuntime(&admitted);
            return .{ .record = saved, .admitted = admitted };
        }

        fn workspaceRuntimeObservation(self: *Self, a: std.mem.Allocator, saved: workspace.Runtime) !json.Value {
            var selected = try self.workspaceRuntime(a, saved.task, saved.artifact.digest, saved.program);
            defer selected.deinit();
            if (!std.meta.eql(saved, selected.record.value)) return error.InvalidRuntime;
            const bundle = selected.admitted.content.value;
            var result = json.object();
            try json.put(a, &result, "runtime", try values.toJson(wc.Ref, a, try wp.reference(a, .runtime, saved.artifact.digest)));
            try json.put(a, &result, "origin_program", try values.toJson(wc.Ref, a, try wp.reference(a, .program, saved.program)));
            try json.put(a, &result, "guest", json.string(try a.dupe(u8, &std.fmt.bytesToHex(bundle.guest.?, .lower))));
            try json.put(a, &result, "source", json.string(try a.dupe(u8, &std.fmt.bytesToHex(bundle.manifest.source, .lower))));
            try json.put(a, &result, "base", json.string(try a.dupe(u8, bundle.manifest.requirements.base)));
            try json.put(a, &result, "admission", json.string(try a.dupe(u8, bundle.manifest.requirements.admission)));
            try json.put(a, &result, "bridge", json.string(try a.dupe(u8, bundle.manifest.requirements.bridge)));
            try json.put(a, &result, "artifact_bytes", try json.number(a, saved.artifact.bytes));
            try json.put(a, &result, "code_bytes", try json.number(a, bundle.image.len));
            try json.put(a, &result, "approval", json.string("exact-source-and-independent-derivation"));
            try json.put(a, &result, "hydration", json.string("canonical-guest-cut"));
            try json.put(a, &result, "hooks", try values.toJson(kosmos.RuntimeInstrumentation.Hooks, a, bundle.hooks));
            try json.put(a, &result, "trace_failure_policy", json.string("publication-fences-owner-and-retains-prior-durable-cut"));
            return result;
        }

        pub fn workspaceSpecialize(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest) !Admission {
            return self.workspaceSpecializeWithHooks(a, operation_id, task_id, program_id, .{});
        }

        pub fn workspaceSpecializeWithHooks(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, hooks: wc.RuntimeHooks) !Admission {
            try self.requireCustody(a, task_id, null);
            const request = try operation(workspace.SpecializeRequest, a, .{ .task = task_id, .program = program_id, .hooks = hooks });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            var program = try self.workspaceProgram(a, task_id, program_id);
            defer program.deinit();
            const image = try self.store().object(a, program.value.description.image, null);
            defer a.free(image);
            const guest = try data.program_image.Admitted.decode(a, image);
            defer guest.deinit();
            // Compiler and proof scratch ends before the next phase. Keeping it
            // in the caller's response arena retains completed work, including
            // independently decoded proofs, until that entire request ends.
            const bytes = try kosmos.RuntimeCompiler.compile(self.allocator, .{ .guest = guest, .horos_package = @import("native_options").horos_identity, .hooks = .{ .control = hooks.control, .storage = hooks.storage } });
            defer self.allocator.free(bytes);
            var admitted = try kosmos.RuntimeArtifact.init(self.allocator, bytes, storage.digest(bytes));
            defer admitted.deinit();
            try kosmos.RuntimeCompiler.validate(self.allocator, &admitted);
            try self.retainValidatedRuntime(&admitted);
            try self.store().begin();
            defer self.store().rollback();
            const artifact = try self.store().putObject(bytes);
            const id = try workspaceContentCustody(a, task_id, artifact.digest);
            var saved: workspace.Runtime = .{ .id = id, .task = task_id, .program = program_id, .artifact = artifact };
            if (try self.store().recordBytes(a, "workspace_runtime", id, task_id)) |prior| {
                defer a.free(prior);
                var existing = try self.workspaceRuntime(a, task_id, artifact.digest, program_id);
                defer existing.deinit();
                saved = existing.record.value;
            } else try self.store().createRecord(workspace.Runtime, "workspace_runtime", id, task_id, saved);
            const record_bytes = try contracts.encodeOwned(workspace.Runtime, a, saved);
            defer a.free(record_bytes);
            const observation = try self.store().putObject(record_bytes);
            return self.workspaceCommit(a, parent.value, operation_id, request, artifact.digest, .runtime, observation, .{ .specialize = .{ .program = program_id, .hooks = hooks } });
        }

        fn runtimeWork(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, expected: wc.Expected) !contracts.Decoded(workspace.Work) {
            try self.requireCustody(a, task_id, try wp.identity(expected.work, .work));
            var work = try self.workspaceWork(a, task_id, try wp.identity(expected.work, .work));
            errdefer work.deinit();
            if (work.value.execution_revision != expected.execution_revision or work.value.control_revision != expected.control_revision) return error.StaleRevision;
            if (work.value.current_occurrence) |id| {
                var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                defer pending.deinit();
                if (pending.value.state == .dispatching or pending.value.state == .unknown) return error.UnresolvedDelivery;
            }
            return work;
        }

        fn runtimeProvenance(work: workspace.Work) kosmos.RuntimeCapsule.Provenance {
            return .{ .execution = work.id, .custody = storage.digest(&work.task), .publication = .{ .digest = work.checkpoint.digest, .bytes = work.checkpoint.bytes } };
        }

        pub fn workspaceRequestCut(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, command: @FieldType(wc.Work, "request_cut")) !Admission {
            const request = try operation(workspace.CutRequest, a, .{ .task = task_id, .command = command });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            var work = try self.runtimeWork(a, task_id, command.expected);
            defer work.deinit();
            const driver = try self.workspaceResident(a, work.value);
            const capsule_receipt = try driver.publishCapsule(a, switch (command.level) {
                .guest_cut => .guest_cut,
                .outer_execution => .outer_execution,
            }, runtimeProvenance(work.value));
            defer capsule_receipt.deinit();
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(code);
            work.value.runtime_capsule = try self.store().putObject(capsule_receipt.bytes());
            work.value.runtime_dependencies = .{ .items = try capsuleDependencies(a, capsule_receipt.bytes()) };
            defer a.free(work.value.runtime_dependencies.items);
            work.value.control_revision = try std.math.add(u64, work.value.control_revision, 1);
            work.value.event_watermark = parent.value.event_high + 1;
            try self.store().putRecord(workspace.Work, "workspace_work", work.value.id, task_id, work.value);
            return self.workspaceCommit(a, parent.value, operation_id, request, work.value.id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work.value.id, task_id), .{ .request_cut = command });
        }

        pub fn workspaceRealize(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, command: @FieldType(wc.Work, "realize")) !Admission {
            var selected: ?SelectedRuntime = if (command.runtime == .selected) try self.workspaceRuntime(a, task_id, try wp.identity(command.runtime.selected, .runtime), null) else null;
            defer if (selected) |*item| item.deinit();
            const target: ?state.Reference = if (selected) |item| item.record.value.artifact else null;
            const work_id = try wp.identity(command.expected.work, .work);
            const request = try operation(workspace.RealizeRequest, a, .{ .task = task_id, .work = work_id, .execution = command.expected.execution_revision, .control = command.expected.control_revision, .realization = command.realization_revision, .runtime = target });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            var work = try self.runtimeWork(a, task_id, command.expected);
            defer work.deinit();
            if (work.value.outer_operation != null) return error.GuestCutUnavailable;
            if (work.value.realization_revision != command.realization_revision) return error.StaleRevision;
            var program = try self.workspaceProgram(a, task_id, work.value.program);
            defer program.deinit();
            if (selected) |item| if (!std.meta.eql(item.record.value.program, work.value.program)) {
                var origin = try self.workspaceProgram(a, task_id, item.record.value.program);
                defer origin.deinit();
                if (!std.meta.eql(origin.value.description.image, program.value.description.image)) return error.InvalidRuntime;
            };
            const image = try self.store().object(a, program.value.description.image, null);
            defer a.free(image);
            var generic: ?kosmos.Prepared = if (selected == null) try self.program.prepare(self.allocator, image) else null;
            defer if (generic) |*item| item.deinit();
            const target_artifact = if (selected) |*item| &item.admitted else &generic.?.runtime;
            const driver = try self.workspaceResident(a, work.value);
            const source_code = try driver.runtimeBytes(a);
            defer a.free(source_code);
            const target_code = try target_artifact.encode(a);
            defer a.free(target_code);
            const Publisher = struct {
                host: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                work: workspace.Work,
                operation_id: []const u8,
                request: state.Digest,
                target: ?state.Reference,
                source_code: []const u8,
                target_code: []const u8,
                result: ?Admission = null,
                failure: ?anyerror = null,
                fn publish(context: *anyopaque, _: kosmos.RuntimeCapsule.Binding, source_capsule: []const u8, target_capsule: []const u8) kosmos.RuntimeCapsule.SwitchDecision {
                    const publication: *@This() = @ptrCast(@alignCast(context));
                    publication.result = publication.commit(source_capsule, target_capsule) catch |err| {
                        publication.failure = err;
                        return if (publication.host.store().fenced) .uncertain else .rejected;
                    };
                    return .committed;
                }
                fn commit(publication: *@This(), source_capsule: []const u8, target_capsule: []const u8) !Admission {
                    const host = publication.host;
                    try host.store().begin();
                    defer host.store().rollback();
                    const source_code_ref = try host.store().putObject(publication.source_code);
                    const target_code_ref = try host.store().putObject(publication.target_code);
                    const before = try host.store().putObject(source_capsule);
                    const after = try host.store().putObject(target_capsule);
                    var next = publication.work;
                    next.runtime = publication.target;
                    next.runtime_capsule = after;
                    next.runtime_trace = null;
                    next.runtime_dependencies = .{ .items = try capsuleDependencies(publication.a, target_capsule) };
                    defer publication.a.free(next.runtime_dependencies.items);
                    next.realization_revision = try std.math.add(u64, next.realization_revision, 1);
                    next.control_revision = try std.math.add(u64, next.control_revision, 1);
                    next.event_watermark = publication.parent.event_high + 1;
                    try host.store().putRecord(workspace.Work, "workspace_work", next.id, next.task, next);
                    const dependencies = [_]state.Reference{ source_code_ref, target_code_ref, next.runtime_dependencies.items[1] };
                    return host.workspaceCommit(publication.a, publication.parent, publication.operation_id, publication.request, next.id, .work, try host.snapshotRecord(workspace.Work, publication.a, "workspace_work", next.id, next.task), .{ .realize = .{ .execution = publication.work.execution_revision, .control = publication.work.control_revision, .realization = publication.work.realization_revision, .runtime = publication.target, .source = before, .target = after, .dependencies = .{ .items = &dependencies } } });
                }
            };
            var publisher: Publisher = .{ .host = self, .a = a, .parent = parent.value, .work = work.value, .operation_id = operation_id, .request = request, .target = target, .source_code = source_code, .target_code = target_code };
            const decision = try driver.realize(try driver.runtimeBinding(), target_artifact, runtimeProvenance(work.value), .{ .context = &publisher, .publish = Publisher.publish });
            if (publisher.failure) |err| return err;
            if (decision != .committed) return error.PublicationUncertain;
            self.active.?.realization_revision = command.realization_revision + 1;
            return publisher.result orelse return error.CorruptState;
        }

        fn capsuleDependencies(a: std.mem.Allocator, bytes: []const u8) ![]state.Reference {
            var decoded = try kosmos.RuntimeCapsule.read(a, bytes);
            defer decoded.deinit();
            if (decoded.value.record.dependencies.len != 2) return error.InvalidRuntime;
            const refs = try a.alloc(state.Reference, 2);
            for (refs, decoded.value.record.dependencies) |*out, ref| out.* = .{ .digest = ref.digest, .bytes = ref.bytes };
            return refs;
        }

        fn validatePublishedCapsule(self: *Self, a: std.mem.Allocator, work: workspace.Work, ref: state.Reference, expected_runtime: ?state.Reference) !void {
            return self.validatePublishedCapsuleTrace(a, work, ref, expected_runtime, null, null);
        }

        fn validatePublishedCapsuleTrace(self: *Self, a: std.mem.Allocator, work: workspace.Work, ref: state.Reference, expected_runtime: ?state.Reference, trace: ?kosmos.RuntimeInstrumentation.Output, pending_operation: ?workspace.OuterOperation) !void {
            const bytes = try self.store().object(a, ref, null);
            defer a.free(bytes);
            var envelope = try kosmos.RuntimeCapsule.read(a, bytes);
            defer envelope.deinit();
            const record_value = envelope.value.record;
            if (!std.meta.eql(record_value.provenance.execution, work.id) or !std.meta.eql(record_value.provenance.custody, storage.digest(&work.task)) or
                record_value.provenance.publication == null or !std.meta.eql(record_value.provenance.publication.?.digest, work.checkpoint.digest) or record_value.provenance.publication.?.bytes != work.checkpoint.bytes) return error.InvalidArchive;
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            if (!std.meta.eql(record_value.guest.image.digest, program.value.description.image.digest) or record_value.guest.image.bytes != program.value.description.image.bytes) return error.InvalidArchive;
            const image = try self.store().object(a, program.value.description.image, null);
            defer a.free(image);
            const runtime_ref: state.Reference = .{ .digest = record_value.artifact.digest, .bytes = record_value.artifact.bytes };
            const code = try self.store().object(a, runtime_ref, null);
            defer a.free(code);
            var selected = if (expected_runtime) |expected| chosen: {
                if (!std.meta.eql(runtime_ref, expected)) return error.InvalidArchive;
                var owned = try self.workspaceRuntime(a, work.task, expected.digest, work.program);
                defer owned.deinit();
                if (!std.meta.eql(owned.record.value.artifact, expected)) return error.InvalidArchive;
                break :chosen try owned.admitted.clone();
            } else chosen: {
                var packaged = try self.program.prepare(a, image);
                defer packaged.deinit();
                if (!std.meta.eql(runtime_ref.digest, packaged.runtime.identity) or runtime_ref.bytes != packaged.runtime.core.?.encoded_length) return error.InvalidArchive;
                break :chosen try packaged.runtime.clone();
            };
            defer selected.deinit();
            var prepared = try kosmos.Prepared.initWithRuntime(a, image, &selected);
            defer prepared.deinit();
            const CheckOnly = struct {
                // Private archive candidate, never installed in Service.active
                // and never given an environmental adapter or execution turn.
                fn inspect(_: *anyopaque, _: kosmos.RuntimeCapsule.Reference, _: kosmos.RuntimeCapsule.Record, _: kosmos.RuntimeCapsule.Reference) !void {}
            };
            if (pending_operation) |pending| {
                if (trace != null or record_value.operation != .advance or record_value.kind != .outer_execution or
                    !std.meta.eql(ref, pending.capsule) or pending.guest_quantum > 256) return error.InvalidArchive;
                try self.validateOuterControl(a, work, pending, envelope.value.command);
            } else if (record_value.operation != null) return error.InvalidArchive;
            var context: u8 = 0;
            var candidate = try kosmos.RuntimeCapsule.restore(a, &prepared.guest, &selected, bytes, .{ .context = &context, .claim = CheckOnly.inspect });
            defer candidate.deinit();
            if (pending_operation != null) return;
            const checkpoint = try candidate.checkpoint(a);
            defer a.free(checkpoint);
            if (!std.meta.eql(storage.digest(checkpoint), work.checkpoint.digest) or checkpoint.len != work.checkpoint.bytes) return error.InvalidArchive;
            if (trace) |expected| {
                // Re-run only the source observer on a private candidate. A
                // zero-quantum advance does not perform a guest transition.
                if (!std.meta.eql(expected.source, selected.content.value.manifest.source) or
                    !std.meta.eql(expected.realization, selected.identity) or
                    !std.meta.eql(expected.guest, candidate.guest.admitted().identity()) or
                    expected.guest_revision != candidate.guest_revision) return error.InvalidArchive;
                var observation = try candidate.exchange(.{ .advance = .{ .control = .none, .quantum = 0 } });
                defer observation.deinit();
                if (observation.value != .cut or observation.value.cut.guest_work != 0 or !std.meta.eql(observation.value.cut.trace, @as(?kosmos.RuntimeInstrumentation.Trace, expected.trace))) return error.InvalidArchive;
            }
        }

        fn validateOuterControl(self: *Self, a: std.mem.Allocator, work: workspace.Work, pending: workspace.OuterOperation, encoded: []const u8) !void {
            const bytes = try self.store().object(a, pending.control, null);
            defer a.free(bytes);
            var accepted = try contracts.decodeOwned(data.invocation.Control, a, bytes);
            defer accepted.deinit();
            var issued = try kosmos.RuntimeCapsule.readCommand(a, encoded);
            defer issued.deinit();
            if (issued.value != .advance or issued.value.advance.quantum != pending.guest_quantum or
                (pending.guest_quantum == 0 and accepted.value != .reply)) return error.InvalidArchive;
            const actual = issued.value.advance.control;
            switch (accepted.value) {
                .none => if (actual != .none or work.outcome_kind != .progressed) return error.InvalidArchive,
                .resume_yield => if (actual != .resume_yield or work.outcome_kind != .yielded) return error.InvalidArchive,
                .cancel => |reason| {
                    const saved = work.cancellation orelse return error.InvalidArchive;
                    if (actual != .cancel or reason != .text or !same(reason.text, saved.bytes) or
                        !data.record.equal(data.invocation.Reason, reason, actual.cancel)) return error.InvalidArchive;
                },
                .reply => |reply| {
                    if (actual != .answer or work.outcome_kind != .requested) return error.InvalidArchive;
                    var response = try data.invocation.decode(data.invocation.Result, a, reply);
                    defer response.deinit();
                    var occurrence_value = try self.record(occurrence.Occurrence, a, "occurrence", work.current_occurrence orelse return error.InvalidArchive, work.task);
                    defer occurrence_value.deinit();
                    const value = occurrence_value.value;
                    const acquisition = switch (value.state) {
                        .settled_reply => |acquired| acquired,
                        .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (!std.meta.eql(value.work, work.id) or !std.meta.eql(value.request, response.value.request_identity) or
                        !std.meta.eql(acquisition.reply, storage.digest(reply)) or !same(actual.answer, response.value.value)) return error.InvalidArchive;
                },
            }
        }

        fn validateRuntimeSwitch(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, item: state.WorkPublication, prior: state.WorkPublication, command: @FieldType(workspace.PublicationCommand, "realize")) !void {
            var current = try self.workspaceWork(a, task_id, item.work);
            defer current.deinit();
            var work = current.value;
            work.checkpoint = prior.checkpoint orelse return error.InvalidArchive;
            try self.validatePublishedCapsule(a, work, command.source, prior.runtime);
            try self.validatePublishedCapsule(a, work, command.target, item.runtime);
            const before_bytes = try self.store().object(a, command.source, null);
            defer a.free(before_bytes);
            const after_bytes = try self.store().object(a, command.target, null);
            defer a.free(after_bytes);
            var before = try kosmos.RuntimeCapsule.read(a, before_bytes);
            defer before.deinit();
            var after = try kosmos.RuntimeCapsule.read(a, after_bytes);
            defer after.deinit();
            const source_record = before.value.record;
            const target_record = after.value.record;
            if (source_record.kind != .guest_cut or target_record.kind != .guest_cut or !same(before.value.checkpoint, after.value.checkpoint) or
                !std.meta.eql(source_record.checkpoint.digest, work.checkpoint.digest) or source_record.checkpoint.bytes != work.checkpoint.bytes or
                source_record.guest_revision != target_record.guest_revision or source_record.outer_revision == std.math.maxInt(u64) or target_record.outer_revision != source_record.outer_revision + 1) return error.InvalidArchive;
            const dependencies = [_]state.Reference{
                .{ .digest = source_record.artifact.digest, .bytes = source_record.artifact.bytes },
                .{ .digest = target_record.artifact.digest, .bytes = target_record.artifact.bytes },
                .{ .digest = target_record.guest.image.digest, .bytes = target_record.guest.image.bytes },
            };
            if (command.dependencies.items.len != dependencies.len) return error.InvalidArchive;
            for (dependencies, command.dependencies.items) |wanted, actual| if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
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
            if (saved.value.version != 2 or !std.meta.eql(saved.value.id, work_id) or !std.meta.eql(saved.value.task, task_id)) return error.CorruptState;
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
                !std.meta.eql(try wp.identity(selection.expected.work, .work), value.work) or
                (std.math.add(u64, selection.expected.control_revision, 1) catch return error.InvalidArchive) != value.control_revision) return error.InvalidArchive;
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
            try self.validateWorkspacePublications(a, parent.value, records);
            var receipts = try self.store().database.prepare("SELECT o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &task_id }});
            defer receipts.deinit();
            while (try receipts.step() == .row) {
                var receipt_value = try contracts.decodeOwned(state.Receipt, a, try receipts.bytes(0));
                defer receipt_value.deinit();
                if (receipt_value.value.method != .workspace or receipt_value.value.workspace_kind != .work) continue;
                var observed = try contracts.decodeOwned(workspace.WorkObservation, a, try self.store().object(a, receipt_value.value.workspace_observation orelse return error.InvalidArchive, null));
                defer observed.deinit();
                if (!std.meta.eql(receipt_value.value.task, task_id) or !std.meta.eql(receipt_value.value.workspace orelse return error.InvalidArchive, observed.value.work.id)) return error.InvalidArchive;
                var publication = try self.store().database.prepare("SELECT revision FROM events WHERE task=? AND seq=?", &.{ .{ .blob = &task_id }, .{ .integer = std.math.cast(i64, observed.value.work.event_watermark) orelse return error.InvalidArchive } });
                defer publication.deinit();
                if (try publication.step() != .row or try publication.integer(0) != std.math.cast(i64, receipt_value.value.revision) orelse return error.InvalidArchive) return error.InvalidArchive;
                try self.validateWorkspaceWorkSnapshot(a, parent.value, observed.value, records);
                try self.validateHistoricalOccurrence(a, observed.value);
            }
            const Generation = struct { work: state.Digest, generation: u64 };
            var generations: std.AutoHashMap(Generation, void) = .init(a);
            for (records) |row| switch (row.kind) {
                .root_operation => {
                    var saved = try self.record(state.RootOperation, a, "root_operation", row.id, task_id);
                    defer saved.deinit();
                    try self.validateRootOperation(a, parent.value, saved.value);
                },
                .workspace_runtime => {
                    var record_value = try self.record(workspace.Runtime, a, "workspace_runtime", row.id, task_id);
                    defer record_value.deinit();
                    var admitted = try self.workspaceRuntime(a, task_id, record_value.value.artifact.digest, record_value.value.program);
                    defer admitted.deinit();
                },
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
                    if (derivation.inspection) |origin| try self.validateWorkspaceWorkSnapshot(a, parent.value, origin.observation, records);
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
                .workspace_reply => {
                    try requireArchiveRecord(records, .occurrence, row.id);
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", row.id, task_id);
                    defer pending.deinit();
                    if (pending.value.work != null or !(pending.value.state == .settled_reply or (pending.value.state == .admitted and pending.value.state.admitted == .reply))) return error.InvalidArchive;
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
                for (0..std.math.cast(usize, value.port_generation) orelse return error.InvalidArchive) |i| if (!generations.contains(.{ .work = value.id, .generation = i + 1 })) return error.InvalidArchive;
                try self.validateWorkspaceWorkSnapshot(a, parent.value, try self.freezeWorkspaceWork(a, task_id, try wp.reference(a, .work, value.id), true), records);
            }
        }

        // Inputs are the ordered interaction history at this publication, plus
        // the instrument's answer when completed. A mutable list cannot certify
        // its own ancestry, even when every supplied reference is valid.
        fn validateWorkspaceInputs(self: *Self, a: std.mem.Allocator, value: workspace.Work) !void {
            var count: usize = 0;
            var query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq", &.{ .{ .blob = &value.task }, .{ .integer = std.math.cast(i64, value.event_watermark) orelse return error.InvalidArchive } });
            defer query.deinit();
            while (try query.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                const ref = event_value.value.workspace_command orelse continue;
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, try self.store().object(a, ref, null));
                defer command.deinit();
                if (command.value != .interact or !std.meta.eql(try wp.identity(command.value.interact.expected.work, .work), value.id)) continue;
                const reply = try self.workspaceInteractionReply(a, value.task, command.value.interact);
                if (reply.input) |input| {
                    if (count >= value.inputs.items.len or !std.meta.eql(value.inputs.items[count], input)) return error.InvalidArchive;
                    count += 1;
                }
            }
            if (value.answer_value) |answer| {
                if (count >= value.inputs.items.len or !std.meta.eql(value.inputs.items[count], answer)) return error.InvalidArchive;
                count += 1;
            }
            if (count != value.inputs.items.len) return error.InvalidArchive;
        }

        fn validateWorkspacePublication(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, snapshot: workspace.WorkObservation) !void {
            const value = snapshot.work;
            if (!std.meta.eql(value.task, task_id)) return error.InvalidArchive;
            const publication_binding = try workPublication(a, snapshot);
            var event_query = try self.store().database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &task_id }, .{ .integer = std.math.cast(i64, value.event_watermark) orelse return error.InvalidArchive } });
            defer event_query.deinit();
            if (try event_query.step() != .row) return error.InvalidArchive;
            var published = try contracts.decodeOwned(state.Event, a, try event_query.bytes(0));
            defer published.deinit();
            var matches: usize = 0;
            for (published.value.workspace_publications.items) |item| if (try samePublication(a, item, publication_binding)) {
                matches += 1;
            };
            if (matches != 1) return error.InvalidArchive;
        }

        fn validateWorkspaceWorkSnapshot(self: *Self, a: std.mem.Allocator, parent: state.Task, snapshot: workspace.WorkObservation, records: []const state.ArchiveRecord) !void {
            const value = snapshot.work;
            try self.validateWorkspacePublication(a, parent.id, snapshot);
            // A checkpoint certifies execution, not native custody facts. Those
            // facts either remain immutable or grow monotonically in the owner.
            var current = try self.workspaceWork(a, parent.id, value.id);
            defer current.deinit();
            inline for (.{ "version", "program", "input", "input_value", "origin_work", "delegation" }) |field|
                if (!std.meta.eql(@field(value, field), @field(current.value, field))) return error.InvalidArchive;
            inline for (.{ "execution_revision", "control_revision", "realization_revision", "port_generation", "event_watermark" }) |field|
                if (@field(value, field) > @field(current.value, field)) return error.InvalidArchive;
            if (value.realization_revision == current.value.realization_revision and !std.meta.eql(value.runtime, current.value.runtime)) return error.InvalidArchive;
            if (value.runtime) |ref| {
                var selected = try self.workspaceRuntime(a, parent.id, ref.digest, value.program);
                defer selected.deinit();
                if (!std.meta.eql(ref, selected.record.value.artifact)) return error.InvalidArchive;
                try requireArchiveRecord(records, .workspace_runtime, selected.record.value.id);
            }
            if (value.outer_operation) |pending| {
                try self.validatePublishedCapsuleTrace(a, value, pending.capsule, value.runtime, null, pending);
                const capsule_bytes = try self.store().object(a, pending.capsule, null);
                defer a.free(capsule_bytes);
                const dependencies = try capsuleDependencies(a, capsule_bytes);
                defer a.free(dependencies);
                if (dependencies.len != pending.dependencies.items.len) return error.InvalidArchive;
                for (dependencies, pending.dependencies.items) |wanted, actual| if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
            }
            if (value.runtime_capsule) |ref| {
                if (value.outer_operation) |pending| {
                    if (!std.meta.eql(ref, pending.capsule)) return error.InvalidArchive;
                } else try self.validatePublishedCapsule(a, value, ref, value.runtime);
                const capsule_bytes = try self.store().object(a, ref, null);
                defer a.free(capsule_bytes);
                const dependencies = try capsuleDependencies(a, capsule_bytes);
                defer a.free(dependencies);
                if (dependencies.len != value.runtime_dependencies.items.len) return error.InvalidArchive;
                for (dependencies, value.runtime_dependencies.items) |wanted, actual| if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
            } else if (value.runtime_dependencies.items.len != 0) return error.InvalidArchive;
            if (value.runtime_trace) |trace| {
                try self.validatePublishedCapsuleTrace(a, value, trace.capsule, value.runtime, trace.output, null);
                const bytes = try self.store().object(a, trace.capsule, null);
                defer a.free(bytes);
                const dependencies = try capsuleDependencies(a, bytes);
                defer a.free(dependencies);
                if (dependencies.len != trace.dependencies.items.len) return error.InvalidArchive;
                for (dependencies, trace.dependencies.items) |wanted, actual| if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
            }
            try self.validateWorkspaceInputs(a, value);
            inline for (.{ "result", "result_value", "answer_value", "instrument_occurrence" }) |field| {
                if (@field(value, field) != null and !std.meta.eql(@field(value, field), @field(current.value, field))) return error.InvalidArchive;
            }
            if (value.cancellation) |reason| {
                const actual = current.value.cancellation orelse return error.InvalidArchive;
                if (!same(reason.bytes, actual.bytes)) return error.InvalidArchive;
            }
            if (value.cancellation_applied and !current.value.cancellation_applied) return error.InvalidArchive;
            if (value.terminal() and value.execution_revision != current.value.execution_revision) return error.InvalidArchive;
            if (value.execution_revision == current.value.execution_revision) {
                inline for (.{ "checkpoint", "outcome", "outcome_kind", "current_occurrence", "current_port", "port_generation", "result", "result_value", "answer_value" }) |field|
                    if (!std.meta.eql(@field(value, field), @field(current.value, field))) return error.InvalidArchive;
            }
            if (value.execution_revision == 0 or value.control_revision == 0 or value.event_watermark > parent.event_high or
                (value.cancellation_applied and value.cancellation == null)) return error.InvalidArchive;
            var program = try self.workspaceProgram(a, parent.id, value.program);
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
            const input = try self.workspaceValueReference(a, parent.id, try wp.reference(a, .value, (value.input_value orelse return error.InvalidArchive).digest));
            if (!std.meta.eql(input.value, value.input) or !std.meta.eql(input.schema, program.value.description.input_schema)) return error.InvalidArchive;
            for (value.inputs.items) |ref| _ = try self.workspaceValueReference(a, parent.id, try wp.reference(a, .value, ref.digest));
            var prepared = try self.inspectionRuntime(self.allocator, value);
            defer prepared.deinit();
            const checkpoint = try self.store().object(a, value.checkpoint, null);
            defer a.free(checkpoint);
            var candidate = try kosmos.Session.restore(self.allocator, &prepared, checkpoint);
            defer candidate.deinit();
            var finished = try kosmos.invocation.finishPublication(a, &candidate, .receipt, null);
            defer finished.outcome.deinit();
            defer self.allocator.free(finished.checkpoint.?);
            const publication = .{ .outcome = try data.invocation.encodeOwned(data.invocation.Outcome, a, finished.outcome.record), .checkpoint = finished.checkpoint.? };
            defer a.free(publication.outcome);
            if (!std.meta.eql(storage.digest(publication.outcome), value.outcome.digest) or publication.outcome.len != value.outcome.bytes or
                !std.meta.eql(storage.digest(publication.checkpoint), value.checkpoint.digest) or publication.checkpoint.len != value.checkpoint.bytes) return error.InvalidArchive;
            var observed = try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer observed.deinit();
            if (!same(@tagName(observed.value), @tagName(value.outcome_kind))) return error.InvalidArchive;
            try validateCancellation(a, value, observed.value, publication.checkpoint);
            switch (observed.value) {
                .requested => |pending| {
                    const id = value.current_occurrence orelse return error.InvalidArchive;
                    var occurrence_value = try self.record(occurrence.Occurrence, a, "occurrence", id, parent.id);
                    defer occurrence_value.deinit();
                    if (!std.meta.eql(occurrence_value.value.request_object, state.Reference{ .digest = storage.digest(pending.request), .bytes = pending.request.len })) return error.InvalidArchive;
                    var route = try self.record(workspace.ExecutionRoute, a, "execution_route", id, parent.id);
                    defer route.deinit();
                    if (!std.meta.eql(value.current_port, route.value.port)) return error.InvalidArchive;
                },
                .completed => |bytes| {
                    if (value.result == null or value.result_value == null or !std.meta.eql(value.result.?, state.Reference{ .digest = storage.digest(bytes), .bytes = bytes.len })) return error.InvalidArchive;
                    const result = try self.workspaceValueReference(a, parent.id, try wp.reference(a, .value, value.result_value.?.digest));
                    if (!std.meta.eql(result.artifact, value.result_value.?) or !std.meta.eql(result.value, value.result.?) or !std.meta.eql(result.schema, program.value.description.result_schema)) return error.InvalidArchive;
                    var retained = try self.record(workspace.Value, a, "workspace_value", try workspaceContentCustody(a, parent.id, result.artifact.digest), parent.id);
                    defer retained.deinit();
                    const expected = try self.workspaceResultDerivation(a, value, program.value);
                    if (!same(try contracts.encodeOwned(workspace.Derivation, a, expected), try contracts.encodeOwned(workspace.Derivation, a, retained.value.derivation))) return error.InvalidArchive;
                },
                else => if (value.result != null or value.result_value != null) return error.InvalidArchive,
            }
            if (observed.value != .requested and (value.current_occurrence != null or value.current_port != null)) return error.InvalidArchive;
            if (native_program) try self.validateWorkspaceInstrumentAnswer(a, parent, value);
        }

        fn validateWorkspaceInstrumentAnswer(self: *Self, a: std.mem.Allocator, parent: state.Task, child: workspace.Work) !void {
            if (child.outcome_kind != .completed) {
                if (child.answer_value != null) return error.InvalidArchive;
                return;
            }
            var pending = try self.record(occurrence.Occurrence, a, "occurrence", child.instrument_occurrence orelse return error.InvalidArchive, parent.id);
            defer pending.deinit();
            if (!std.meta.eql(pending.value.work, child.id) or pending.value.state != .admitted or pending.value.state.admitted != .reply) return error.InvalidArchive;
            const admitted = pending.value.state.admitted.reply;
            var reply = try data.invocation.decode(data.invocation.Result, a, try self.store().acquiredObject(a, admitted.reply, null));
            defer reply.deinit();
            if (!std.meta.eql(reply.value.request_identity, pending.value.request) or
                !std.meta.eql(child.result, @as(?state.Reference, .{ .digest = storage.digest(reply.value.value), .bytes = reply.value.value.len }))) return error.InvalidArchive;
            var output = try contracts.decodeOwned(instrument.Output, a, reply.value.value);
            defer output.deinit();
            if (output.value == .unavailable) {
                if (child.answer_value != null) return error.InvalidArchive;
                return;
            }
            const answer_ref = child.answer_value orelse return error.InvalidArchive;
            const answer = try self.workspaceValueReference(a, parent.id, try wp.reference(a, .value, answer_ref.digest));
            const delegation_ref = child.delegation orelse return error.InvalidArchive;
            var delegation = try contracts.decodeOwned(workspace.Delegation, a, try self.store().object(a, delegation_ref, null));
            defer delegation.deinit();
            var port = try contracts.decodeOwned(workspace.Port, a, try self.store().object(a, delegation.value.port, null));
            defer port.deinit();
            if (!std.meta.eql(answer.artifact, answer_ref) or !std.meta.eql(answer.schema, port.value.interface.argument) or
                !std.meta.eql(answer.value, state.Reference{ .digest = storage.digest(output.value.answer.bytes), .bytes = output.value.answer.bytes.len })) return error.InvalidArchive;
            const expected: workspace.Derivation = switch (delegation.value.selection) {
                .snapshot => |selected| .{ .kind = .acquisition, .sources = .{ .items = &.{} }, .acquisition = try self.workspaceSnapshotRange(a, parent, delegation.value.snapshot orelse return error.InvalidArchive, selected) },
                .model => blk: {
                    var capture_value = try self.record(state.Capture, a, "capture", admitted.attempt, parent.id);
                    defer capture_value.deinit();
                    break :blk .{ .kind = .judgment, .sources = delegation.value.inputs, .work = child.id, .delegation = delegation_ref, .capture = capture_value.value.response orelse return error.InvalidArchive };
                },
                else => return error.InvalidArchive,
            };
            const provenance = try contracts.encodeOwned(workspace.Derivation, a, expected);
            if (!std.meta.eql(answer.provenance, state.Reference{ .digest = storage.digest(provenance), .bytes = provenance.len })) return error.InvalidArchive;
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
            try self.requireCustody(a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const Request = workspace.BuildRequest;
            const request = try operation(Request, a, .{ .task = task_id, .source = .{ .bytes = source }, .source_kind = source_kind, .catalog = catalog, .exposures = .{ .items = exposures } });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            if (parent.value.terminal() or parent.value.cancellation != null) return error.InvalidState;
            if (catalog) |ref| try workspaceSnapshotAccess(parent.value, ref);
            var built = try self.workspaceCompile(a, source, @fromBackingInt(@intCast(@backingInt(source_kind))), catalog, exposures, diagnostic);
            defer built.deinit();
            try self.store().begin();
            defer self.store().rollback();
            const saved = try self.workspaceStoreProgram(a, task_id, source, @fromBackingInt(@intCast(@backingInt(source_kind))), catalog, exposures, .{ .image = .{ .bytes = built.image }, .interface = built.interface, .ports = .{ .items = built.ports } });
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, saved.digest, .program, saved, .build);
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

        fn workspaceCommit(self: *Self, a: std.mem.Allocator, initial: state.Task, operation_id: ?[]const u8, request: state.Digest, identity: state.Digest, kind: @FieldType(contracts.workspace.Ref, "kind"), observation: state.Reference, command: ?workspace.PublicationCommand) !Admission {
            return self.workspaceCommitRelated(a, initial, operation_id, request, identity, kind, observation, null, command);
        }

        fn workspaceCommitRelated(self: *Self, a: std.mem.Allocator, initial: state.Task, operation_id: ?[]const u8, request: state.Digest, identity: state.Digest, kind: @FieldType(contracts.workspace.Ref, "kind"), observation: state.Reference, related: ?state.Digest, command: ?workspace.PublicationCommand) !Admission {
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{std.fmt.bytesToHex(identity, .lower)});
            defer a.free(event_data);
            var publications: [2]state.WorkPublication = undefined;
            var publication_count: usize = 0;
            var receipt_id: state.Digest = undefined;
            try self.io.randomSecure(&receipt_id);
            var frozen = observation;
            var decoded_work: ?contracts.Decoded(workspace.Work) = null;
            defer if (decoded_work) |*work| work.deinit();
            if (kind == .work) {
                const bytes = try self.store().object(a, observation, null);
                defer a.free(bytes);
                decoded_work = try contracts.decodeOwned(workspace.Work, a, bytes);
                const work = decoded_work.?;
                var pending: ?contracts.Decoded(occurrence.Occurrence) = null;
                defer if (pending) |*value| value.deinit();
                if (work.value.current_occurrence) |id| pending = try self.record(occurrence.Occurrence, a, "occurrence", id, parent.id);
                const observed: workspace.WorkObservation = .{ .work = work.value, .occurrence = if (pending) |value| value.value else null };
                publications[publication_count] = try workPublication(a, observed);
                publication_count += 1;
                const snapshot = try contracts.encodeOwned(workspace.WorkObservation, a, observed);
                defer a.free(snapshot);
                frozen = try self.store().putObject(snapshot);
            }
            if (related) |id| {
                publications[publication_count] = try workPublication(a, try self.freezeWorkspaceWork(a, parent.id, try wp.reference(a, .work, id), true));
                publication_count += 1;
            }
            const command_ref: ?state.Reference = if (command) |value| blk: {
                const bytes = try contracts.encodeOwned(workspace.PublicationCommand, a, value);
                defer a.free(bytes);
                break :blk try self.store().putObject(bytes);
            } else null;
            // Internal program publication is observed through the subsequent
            // work/delegation or captured build reply. Only work progress has
            // the retained publication facts needed for a journal projection.
            if (operation_id != null or publication_count != 0)
                try self.publicationEvent(&parent, if (operation_id != null) .workspace else .workspace_progress, event_data, publications[0..publication_count], command_ref);
            const saved: state.Receipt = .{ .id = receipt_id, .client_operation_id = try name(operation_id orelse "workspace.progress"), .method = .workspace, .request_digest = request, .task = parent.id, .revision = parent.revision, .disposition = .accepted, .workspace = identity, .workspace_kind = kind, .workspace_observation = frozen };
            if (operation_id) |op| {
                const bytes = try contracts.encodeOwned(state.Receipt, a, saved);
                defer a.free(bytes);
                const key = try self.operationKey(a, op);
                try self.store().putReceipt(&key, request, bytes);
            }
            try self.runnable.ensureUnusedCapacity(self.allocator, 2);
            const disposed = if (try self.hasLocalCustody(a, parent.id, null))
                parent.terminal() and try self.taskCleanupComplete(a, parent)
            else
                try self.workspaceSettled(a, parent.id, true, false, false);
            try self.persist(a, parent, initial.revision, "workspace.publish", .acquire);
            if (disposed) self.unclaim(parent.id);
            return .{ .receipt = saved, .replayed = false };
        }

        fn workspaceDelegate(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, authorized: workspace.Authorized) !Admission {
            const selection = authorized.command.work.delegate;
            const Request = workspace.DelegationRequest;
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
            try self.requireCustody(a, task_id, target_id);
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
            _ = try self.workspaceCommit(a, parent.value, null, @splat(0), program.digest, .program, program, null);
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
            return self.workspaceStartAdmitted(a, operation_id, task_id, program.digest, input, .{ .stop = .terminal, .continuation = .owner_scheduled }, null, .{ .record = record_value, .request = request, .policy = selection.policy, .command = selection }, null);
        }

        pub fn workspaceStart(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, input: []const u8, policy: workspace.RunPolicy) !Admission {
            return self.workspaceStartValue(a, operation_id, task_id, program_id, input, policy, null);
        }
        fn workspaceStartValue(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, input: []const u8, policy: workspace.RunPolicy, origin: ?state.Reference) !Admission {
            return self.workspaceStartAdmitted(a, operation_id, task_id, program_id, input, policy, origin, null, null);
        }
        const StartDelegation = struct { record: workspace.Delegation, request: state.Digest, policy: workspace.RunPolicy, command: @FieldType(wc.Work, "delegate") };
        fn workspaceStartAdmitted(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, program_id: state.Digest, input: []const u8, policy: workspace.RunPolicy, origin: ?state.Reference, delegated: ?StartDelegation, runtime: ?state.Reference) !Admission {
            try self.requireCustody(a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const Request = workspace.StartRequest;
            const request = if (delegated) |bound| bound.request else try operation(Request, a, .{ .task = task_id, .program = program_id, .input = .{ .bytes = input }, .policy = policy, .origin = origin, .runtime = runtime });
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
            var selected: ?SelectedRuntime = if (runtime) |ref| try self.workspaceRuntime(a, task_id, ref.digest, program_id) else null;
            defer if (selected) |*value| value.deinit();
            if (selected) |value| if (!std.meta.eql(runtime.?, value.record.value.artifact)) return error.InvalidRuntime;
            var packaged = try self.program.retainRuntime();
            defer packaged.deinit();
            const driver = try evaluator.Driver.openSelected(self.allocator, image, .{ .initial_args = input }, if (selected) |*value| &value.admitted else &packaged);
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
                .runtime = runtime,
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
            defer if (saved.runtime_trace) |trace| a.free(trace.dependencies.items);
            try self.store().createRecord(workspace.Work, "workspace_work", id, task_id, saved);
            try self.createCustody(a, task_id, id);
            const admitted = try self.workspaceCommitRelated(a, parent.value, operation_id, request, id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", id, task_id), if (delegated) |bound| bound.record.work else null, if (delegated) |bound| .{ .delegate = bound.command } else .{ .start = .{ .policy = policy, .origin = origin != null, .runtime = runtime } });
            self.active.?.execution_revision = saved.execution_revision;
            if (saved.schedule == .queued) self.subjectAppendAssumeCapacity(.{ .task = task_id, .work = id });
            return admitted;
        }

        fn workspaceTracePublication(self: *Self, a: std.mem.Allocator, value: workspace.Work, trace: kosmos.RuntimeInstrumentation.Output) !workspace.RuntimeTrace {
            const driver = self.active.?.driver;
            const capsule = try driver.publishCapsule(a, .outer_execution, runtimeProvenance(value));
            defer capsule.deinit();
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            _ = try self.store().putObject(code);
            return .{ .output = trace, .capsule = try self.store().putObject(capsule.bytes()), .dependencies = .{ .items = try capsuleDependencies(a, capsule.bytes()) } };
        }

        fn workspacePublication(self: *Self, a: std.mem.Allocator, value: *workspace.Work, publication: evaluator.Driver.Publication) !void {
            value.runtime_capsule = null;
            value.runtime_trace = null;
            value.outer_operation = null;
            value.runtime_dependencies = .{ .items = &.{} };
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer outcome.deinit();
            value.checkpoint = try self.store().putObject(publication.checkpoint);
            if (publication.trace) |trace| {
                value.runtime_trace = self.workspaceTracePublication(a, value.*, trace) catch return error.InstrumentationPublicationBlocked;
            }
            errdefer if (value.runtime_trace) |trace| a.free(trace.dependencies.items);
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
            value.schedule = publicationSchedule(workspace.ControlObservation.from(.{ .work = value.*, .occurrence = null }));
        }

        fn workspaceResident(self: *Self, a: std.mem.Allocator, value: workspace.Work) !*evaluator.Driver {
            if (self.active) |active| {
                if (std.meta.eql(active.task, value.task) and active.work != null and std.meta.eql(active.work.?, value.id) and active.execution_revision == value.execution_revision and active.realization_revision == value.realization_revision and std.meta.eql(active.outer_operation, if (value.outer_operation) |pending| @as(?state.Reference, pending.capsule) else null)) return active.driver;
                try self.retire(a);
            }
            var artifact = try self.workspaceProgram(a, value.task, value.program);
            defer artifact.deinit();
            const image = try self.store().object(a, artifact.value.description.image, null);
            defer a.free(image);
            const checkpoint = try self.store().object(a, value.checkpoint, null);
            defer a.free(checkpoint);
            var selected: ?SelectedRuntime = if (value.runtime) |ref| try self.workspaceRuntime(a, value.task, ref.digest, value.program) else null;
            defer if (selected) |*item| item.deinit();
            if (selected) |item| if (!std.meta.eql(value.runtime.?, item.record.value.artifact)) return error.InvalidRuntime;
            var packaged = try self.program.retainRuntime();
            defer packaged.deinit();
            const driver = if (value.outer_operation) |pending| restored: {
                try self.validatePublishedCapsuleTrace(a, value, pending.capsule, value.runtime, null, pending);
                const bytes = try self.store().object(a, pending.capsule, null);
                defer a.free(bytes);
                const Owner = struct {
                    work: workspace.Work,
                    reference: state.Reference,
                    fn claim(context: *anyopaque, ref: kosmos.RuntimeCapsule.Reference, record_value: kosmos.RuntimeCapsule.Record, _: kosmos.RuntimeCapsule.Reference) !void {
                        const owner: *@This() = @ptrCast(@alignCast(context));
                        if (!std.meta.eql(ref.digest, owner.reference.digest) or ref.bytes != owner.reference.bytes or
                            !std.meta.eql(record_value.provenance, runtimeProvenance(owner.work))) return error.InvalidArchive;
                    }
                };
                // The task's immutable publication and current exclusive native
                // namespace ownership authorize this one resident installation.
                var owner: Owner = .{ .work = value, .reference = pending.capsule };
                break :restored try evaluator.Driver.openCapsule(self.allocator, image, if (selected) |*item| &item.admitted else &packaged, bytes, .{ .context = &owner, .claim = Owner.claim });
            } else try evaluator.Driver.openSelected(self.allocator, image, .{ .state = checkpoint }, if (selected) |*item| &item.admitted else &packaged);
            self.active = .{ .task = value.task, .work = value.id, .execution_revision = value.execution_revision, .realization_revision = value.realization_revision, .outer_operation = if (value.outer_operation) |pending| pending.capsule else null, .driver = driver };
            return driver;
        }

        fn workspaceResultValue(self: *Self, a: std.mem.Allocator, value: workspace.Work, program: workspace.Program) !state.Reference {
            const derivation = try self.workspaceResultDerivation(a, value, program);
            defer a.free(derivation.sources.items);
            return self.workspacePublishValue(a, value.task, program.description.result_schema, value.result.?, derivation);
        }

        fn workspaceResultDerivation(_: *Self, a: std.mem.Allocator, value: workspace.Work, program: workspace.Program) !workspace.Derivation {
            const source_value = value.input_value orelse return error.CorruptState;
            const antecedents = try a.alloc(state.Reference, value.inputs.items.len + 1);
            antecedents[0] = source_value;
            @memcpy(antecedents[1..], value.inputs.items);
            return .{ .kind = .computation, .sources = .{ .items = antecedents }, .program = program.artifact, .work = value.id };
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
            if (!try self.hasLocalCustody(a, parent.id, admitted.work)) return false;
            var target = try self.workspaceWork(a, parent.id, admitted.work);
            defer target.deinit();
            return target.value.cancellation == null and !target.value.terminal() and target.value.control_revision == admitted.control_revision and std.meta.eql(target.value.current_port, admitted.port);
        }

        fn pumpWorkspace(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !Step {
            self.requireCustody(a, task_id, work_id) catch |err| {
                if (err != error.CustodyNotLocal) return err;
                self.subjectRemove(.{ .task = task_id, .work = work_id });
                return .idle;
            };
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
            if (saved.value.outer_operation != null) {
                _ = try self.workspacePumpWork(a, parent.value, saved.value, 65536, null, @splat(0), null);
                return .progressed;
            }
            if (saved.value.current_occurrence) |id| {
                var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                defer pending.deinit();
                if (saved.value.cancellation != null and !saved.value.cancellation_applied and
                    (pending.value.state == .ready or pending.value.state == .awaiting or pending.value.state == .not_sent))
                {
                    _ = try self.workspaceAdvance(a, parent.value, saved.value, .{ .cancel = .{ .text = saved.value.cancellation.?.bytes } }, null, @splat(0), null);
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
                _ = try self.workspaceAdvance(a, parent.value, saved.value, .{ .reply = reply }, null, @splat(0), null);
                return .progressed;
            }
            _ = try self.workspaceAdvance(a, parent.value, saved.value, workspaceContinuation(saved.value), null, @splat(0), null);
            return .progressed;
        }

        fn workspaceContinuation(value: workspace.Work) data.invocation.Control {
            if (value.cancellation != null and !value.cancellation_applied) return .{ .cancel = .{ .text = value.cancellation.?.bytes } };
            return if (value.outcome_kind == .yielded) .resume_yield else .none;
        }

        fn workspaceRunnable(self: *Self, a: std.mem.Allocator, parent: state.Task, child: workspace.Work) !bool {
            if (!try self.hasLocalCustody(a, parent.id, child.id)) return false;
            if (!child.terminal()) return child.schedule != .parked;
            return child.answer_value != null and try self.delegationCurrent(a, parent, child);
        }

        pub fn workspacePump(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, command: @FieldType(wc.Work, "pump")) !Admission {
            if (command.base_quantum == 0 or command.base_quantum > 1048576) return error.InvalidParams;
            const request = try operation(workspace.PumpRequest, a, .{ .task = task_id, .command = command });
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            var work = try self.runtimeWork(a, task_id, command.expected);
            defer work.deinit();
            if (work.value.terminal()) return error.InvalidState;
            if ((parent.value.terminal() or parent.value.cancellation != null) and work.value.cancellation == null) return error.InvalidState;
            work.value.control_revision = try std.math.add(u64, work.value.control_revision, 1);
            return self.workspacePumpWork(a, parent.value, work.value, command.base_quantum, operation_id, request, .{ .pump = command });
        }

        fn workspacePumpWork(self: *Self, a: std.mem.Allocator, parent: state.Task, initial: workspace.Work, base_quantum: u64, operation_id: ?[]const u8, request: state.Digest, command: ?workspace.PublicationCommand) !Admission {
            try self.requireCustody(a, initial.task, initial.id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const driver = try self.workspaceResident(a, initial);
            var control = workspaceContinuation(initial);
            var decoded: ?contracts.Decoded(data.invocation.Control) = null;
            defer if (decoded) |*value| value.deinit();
            var control_bytes: ?[]u8 = null;
            defer if (control_bytes) |bytes| a.free(bytes);
            var reply_bytes: ?[]u8 = null;
            defer if (reply_bytes) |bytes| a.free(bytes);
            const native_started = std.Io.Clock.awake.now(self.io);
            const guest_quantum = if (initial.outer_operation) |pending| pending.guest_quantum else blk: {
                if (initial.current_occurrence) |id| {
                    var occurrence_value = try self.record(occurrence.Occurrence, a, "occurrence", id, initial.task);
                    defer occurrence_value.deinit();
                    if (occurrence_value.value.state == .settled_reply) {
                        reply_bytes = try self.store().acquiredObject(a, occurrence_value.value.state.settled_reply.reply, null);
                        control = .{ .reply = reply_bytes.? };
                    } else if (control != .cancel or (occurrence_value.value.state != .ready and occurrence_value.value.state != .awaiting and occurrence_value.value.state != .not_sent)) return error.WaitingInput;
                }
                break :blk @as(u64, if (control == .reply and initial.cancellation != null and !initial.cancellation_applied) 0 else 256);
            };
            if (initial.outer_operation) |pending| {
                const bytes = try self.store().object(a, pending.control, null);
                defer a.free(bytes);
                decoded = try contracts.decodeOwned(data.invocation.Control, a, bytes);
                control = decoded.?.value;
            } else {
                control_bytes = try contracts.encodeOwned(data.invocation.Control, a, control);
                _ = try self.workspaceConsumed(a, initial, control);
                try driver.beginAdvance(control, guest_quantum);
            }
            errdefer self.store().fence();
            var progress = try driver.pump(base_quantum);
            defer progress.deinit();
            const elapsed = std.math.cast(u64, @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds)) orelse std.math.maxInt(u64);
            if (progress == .event and progress.event.value == .cut) {
                // The operation already applied its control. Publish the cut
                // with a read-only zero-quantum observation, never another reply.
                const publication = try driver.drive(a, .none, 0);
                defer a.free(publication.outcome);
                return self.workspaceFinish(a, parent, initial, control, publication, elapsed, operation_id, request, command);
            }
            if (progress != .suspended) return error.InvalidRuntimeProgress;
            const capsule = try driver.retainCapsule(runtimeProvenance(initial));
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(code);
            var value = initial;
            value.outer_operation = .{
                .capsule = try self.store().putObject(capsule),
                .dependencies = .{ .items = try capsuleDependencies(a, capsule) },
                .control = if (initial.outer_operation) |pending| pending.control else try self.store().putObject(control_bytes.?),
                .guest_quantum = guest_quantum,
            };
            defer a.free(value.outer_operation.?.dependencies.items);
            value.runtime_capsule = null;
            value.runtime_dependencies = .{ .items = &.{} };
            value.native_publication_nanoseconds +|= elapsed;
            value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            value.schedule = if (value.cancellation != null or value.policy.continuation == .owner_scheduled) .queued else .parked;
            try self.store().putRecord(workspace.Work, "workspace_work", value.id, value.task, value);
            const admitted = try self.workspaceCommit(a, parent, operation_id, request, value.id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", value.id, value.task), command);
            self.active.?.outer_operation = value.outer_operation.?.capsule;
            const subject: workspace.Subject = .{ .task = value.task, .work = value.id };
            if (value.schedule == .queued) self.subjectAddAssumeCapacity(subject) else self.subjectRemove(subject);
            return admitted;
        }

        fn workspaceConsumed(self: *Self, a: std.mem.Allocator, work: workspace.Work, control: data.invocation.Control) !?occurrence.Occurrence {
            if (control == .cancel or control == .reply) if (work.current_occurrence) |id| {
                var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, work.task);
                defer pending.deinit();
                return try occurrence.consumed(pending.value, .{ .id = id, .task = work.task, .work = work.id, .request = pending.value.request }, if (control == .cancel) .cancel else .{ .reply = storage.digest(control.reply) }, work.cancellation != null);
            };
            return null;
        }

        fn workspaceAdvance(self: *Self, a: std.mem.Allocator, parent: state.Task, initial: workspace.Work, control: data.invocation.Control, operation_id: ?[]const u8, request: state.Digest, command: ?workspace.PublicationCommand) !Admission {
            try self.requireCustody(a, initial.task, initial.id);
            if (initial.outer_operation != null) return self.workspacePumpWork(a, parent, initial, 65536, operation_id, request, command);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const driver = try self.workspaceResident(a, initial);
            _ = try self.workspaceConsumed(a, initial, control);
            const native_started = std.Io.Clock.awake.now(self.io);
            const publication = try driver.drive(a, control, if (control == .reply and initial.cancellation != null and !initial.cancellation_applied) 0 else 256);
            defer a.free(publication.outcome);
            errdefer self.store().fence();
            const elapsed = std.math.cast(u64, @max(0, std.Io.Clock.awake.now(self.io).nanoseconds - native_started.nanoseconds)) orelse std.math.maxInt(u64);
            return self.workspaceFinish(a, parent, initial, control, publication, elapsed, operation_id, request, command);
        }

        fn workspaceFinish(self: *Self, a: std.mem.Allocator, parent: state.Task, initial: workspace.Work, control: data.invocation.Control, publication: evaluator.Driver.Publication, elapsed: u64, operation_id: ?[]const u8, request: state.Digest, command: ?workspace.PublicationCommand) !Admission {
            const consumed = try self.workspaceConsumed(a, initial, control);
            var value = initial;
            value.native_publication_nanoseconds +|= elapsed;
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
            defer if (value.runtime_trace) |trace| a.free(trace.dependencies.items);
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
            const admitted = try self.workspaceCommit(a, parent, operation_id, request, value.id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", value.id, value.task), command);
            self.active.?.execution_revision = value.execution_revision;
            self.active.?.outer_operation = null;
            const subject: workspace.Subject = .{ .task = value.task, .work = value.id };
            if (runnable) self.subjectAddAssumeCapacity(subject) else self.subjectRemove(subject);
            return admitted;
        }

        pub fn workspaceControl(self: *Self, a: std.mem.Allocator, operation_id: []const u8, task_id: state.TaskId, work_id: state.Digest, expected_execution: u64, expected_control: u64, command: workspace.Command) !Admission {
            try self.requireCustody(a, task_id, work_id);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try self.compatible(parent.value);
            const Request = workspace.ControlRequest;
            const request = try operation(Request, a, .{ .task = task_id, .work = work_id, .execution = expected_execution, .control = expected_control, .command = command });
            const publication_command: workspace.PublicationCommand = .{ .control = .{ .execution = expected_execution, .control = expected_control, .command = command } };
            if (try self.replay(a, operation_id, request)) |prior| return prior;
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            var value = saved.value;
            if (value.execution_revision != expected_execution or value.control_revision != expected_control) return error.StaleRevision;
            if (value.terminal()) return error.InvalidState;
            if (command != .park and command != .cancel and (parent.value.terminal() or parent.value.cancellation != null)) return error.InvalidState;
            if (value.outer_operation != null and (command == .advance or command == .cancel)) {
                if (command == .cancel) {
                    if (command.cancel.bytes.len > 256 or !std.unicode.utf8ValidateSlice(command.cancel.bytes)) return error.InvalidParams;
                    if (value.cancellation == null) value.cancellation = command.cancel;
                    value.control_revision = try std.math.add(u64, value.control_revision, 1);
                }
                return self.workspacePumpWork(a, parent.value, value, 65536, operation_id, request, publication_command);
            }
            if (command == .cancel) {
                if (command.cancel.bytes.len > 256 or !std.unicode.utf8ValidateSlice(command.cancel.bytes)) return error.InvalidParams;
                if (value.cancellation == null) value.cancellation = command.cancel;
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
                        const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, work_id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work_id, task_id), publication_command);
                        if (self.work) |*active| if (std.meta.eql(active.subject_work, work_id) and std.meta.eql(active.task, task_id)) {
                            active.cancel_requested = true;
                        };
                        if (value.schedule == .queued) try self.subjectAdd(.{ .task = task_id, .work = work_id });
                        return admitted;
                    }
                    if (pending.value.state == .settled_reply) {
                        const reply = try self.store().acquiredObject(a, pending.value.state.settled_reply.reply, null);
                        defer a.free(reply);
                        return self.workspaceAdvance(a, parent.value, value, .{ .reply = reply }, operation_id, request, publication_command);
                    }
                }
                return self.workspaceAdvance(a, parent.value, value, .{ .cancel = .{ .text = value.cancellation.?.bytes } }, operation_id, request, publication_command);
            }
            if (command == .advance) {
                if (value.current_occurrence) |id| {
                    var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                    defer pending.deinit();
                    if (pending.value.state != .settled_reply) return error.WaitingInput;
                    const reply = try self.store().acquiredObject(a, pending.value.state.settled_reply.reply, null);
                    defer a.free(reply);
                    return self.workspaceAdvance(a, parent.value, value, .{ .reply = reply }, operation_id, request, publication_command);
                }
                return self.workspaceAdvance(a, parent.value, value, workspaceContinuation(value), operation_id, request, publication_command);
            }
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            var rearmed: ?occurrence.Occurrence = null;
            switch (command) {
                .park => value.schedule = .parked,
                .delegate => |policy| {
                    value.policy = policy;
                    var can_run = value.outer_operation != null or value.current_occurrence == null;
                    var in_flight = false;
                    if (value.current_occurrence) |id| {
                        var pending = try self.record(occurrence.Occurrence, a, "occurrence", id, task_id);
                        defer pending.deinit();
                        in_flight = pending.value.state == .dispatching;
                        can_run = value.outer_operation != null or pending.value.state == .settled_reply or pending.value.state == .captured or (pending.value.state == .ready and value.delegation != null);
                        if (value.outer_operation == null and pending.value.state == .not_sent and value.delegation != null) {
                            rearmed = try occurrence.rearm(pending.value, .{ .id = id, .task = task_id, .work = work_id, .request = pending.value.request });
                            can_run = true;
                        }
                    }
                    value.schedule = if (policy.continuation == .explicit_only) .parked else if (in_flight) .active else if (can_run) .queued else .parked;
                },
                .advance, .cancel => unreachable,
            }
            try self.store().begin();
            defer self.store().rollback();
            if (rearmed) |pending| try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, task_id, pending);
            try self.store().putRecord(workspace.Work, "workspace_work", work_id, task_id, value);
            const admitted = try self.workspaceCommit(a, parent.value, operation_id, request, work_id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work_id, task_id), publication_command);
            const subject: workspace.Subject = .{ .task = task_id, .work = work_id };
            if (value.schedule == .queued) try self.subjectAdd(subject) else self.subjectRemove(subject);
            return admitted;
        }

        fn parkWorkspaceOnClose(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, work_id: state.Digest) !void {
            try self.requireCustody(a, task_id, work_id);
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
            _ = try self.workspaceCommit(a, parent.value, null, @splat(0), work_id, .work, try self.snapshotRecord(workspace.Work, a, "workspace_work", work_id, task_id), null);
        }

        pub fn close(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            if (self.placement_job) |job| {
                job.job.deinit();
                self.placement_job = null;
            }
            try self.retire(a);
            try self.program.close();
            self.runnable.deinit(self.allocator);
            self.placement_pending.deinit(self.allocator);
            self.owned.deinit(self.allocator);
            self.checked_workspace_programs.deinit(self.allocator);
            self.checked_workspace_runtimes.deinit(self.allocator);
            if (self.runtime_cache) |*cached| cached.artifact.deinit();
            self.* = undefined;
        }

        pub fn park(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            if (self.placement_job) |job| {
                job.job.deinit();
                self.placement_job = null;
            }
            self.placement_pending.clearRetainingCapacity();
            for (self.owned.items) |id| {
                // Host suspension drops volatile ownership, not the child's
                // admitted scheduling intent. Explicit task resume restores
                // eligible children; a controller work.park remains durable.
                if (!try self.hasLocalCustody(a, id, null) and !try self.hasFrozenCustody(a, id, null)) continue;
                var decoded = try self.task(a, id);
                defer decoded.deinit();
                var value = decoded.value;
                if (value.terminal() or value.schedule == .parked) continue;
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
