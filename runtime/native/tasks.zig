//! Sole native task/occurrence mutation owner. Front ends submit ordinary typed
//! inputs; workers return acquired bytes. Neither can drive a Kronos resident.
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
const archive_api = @import("archive.zig");

/// Terminal execution and settled cleanup are distinct Kronos observations.
pub fn cleanupComplete(outcome: data.invocation.Outcome) bool {
    return switch (outcome) {
        .completed => true,
        .failed => |failure| std.mem.eql(u8, failure.cleanup_failures, &.{0}),
        .cancelled => |cancelled| std.mem.eql(u8, cancelled.cleanup_failures, &.{0}),
        else => false,
    };
}

pub const maximum_resources = state.maximum_resources;
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
        if (self.bytes.len > 256 * 1024 or self.authority.revoked) return error.Denied;
    }

    pub fn resourceIdentity(self: Profile, image: state.Digest) !state.Digest {
        if (self.resources.len > maximum_resources) return error.Capacity;
        var refs: [maximum_resources]state.Reference = undefined;
        for (self.resources, refs[0..self.resources.len]) |bytes, *ref| ref.* = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        return registry.resourceIdentity(image, storage.digest(self.bytes), refs[0..self.resources.len]);
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
    var total: u64 = 0;
    for (value.resources.items, resources) |reference, *bytes| {
        total = std.math.add(u64, total, reference.bytes) catch return error.Capacity;
        if (total > 16 * 1024 * 1024) return error.Capacity;
        bytes.* = try source.object(a, reference, 16 * 1024 * 1024);
        acquired += 1;
    }
    const profile_id = try a.dupe(u8, value.profile_id.bytes);
    errdefer a.free(profile_id);
    return .{ .profile_id = profile_id, .profile = try source.object(a, value.profile, 256 * 1024), .resources = resources };
}
pub const Admission = struct { receipt: state.Receipt, replayed: bool };
pub const Status = state.Status;
pub const Work = struct {
    task: state.TaskId,
    occurrence: state.Digest,
    attempt: state.Digest,
    request: []const u8,
    prepared: ?[]const u8 = null,
    profile: []const u8 = &.{},
    exhausted_capabilities: []const []const u8 = &.{},
    entry: registry.Entry,
    cleanup: bool,
};
pub const Step = union(enum) { idle, progressed, waiting, work: Work };
const Active = struct { task: state.TaskId, execution_revision: u64, driver: *evaluator.Driver };

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
    const Request = struct { method: state.Method, task: state.TaskId, question: state.Digest, revision: u64, request: state.Digest, schema: state.Name, answer: contracts.Bytes(64 * 1024) };
    return operation(Request, a, .{ .method = .respond, .task = task_id, .question = question_id, .revision = revision, .request = request_digest, .schema = try name(schema_id), .answer = .{ .bytes = answer } });
}

fn cancelDigest(a: std.mem.Allocator, task_id: state.TaskId, reason: state.Reason) !state.Digest {
    const Request = struct { method: state.Method, task: state.TaskId, reason: state.Reason };
    return operation(Request, a, .{ .method = .cancel, .task = task_id, .reason = reason });
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
        runnable: std.ArrayList(state.TaskId) = .empty,
        /// Unsettled cleanup retains ownership, but never runnable work.
        owned: [16]?state.TaskId = @splat(null),
        work: ?Work = null,

        pub fn init(a: std.mem.Allocator, io: std.Io, namespace: *Namespace, assets: discovery.Assets, application: *const discovery.Application, handlers: registry.Registry, profile: Profile) !Self {
            try profile.validate();
            var self: Self = .{ .allocator = a, .io = io, .namespace = namespace, .assets = assets, .application = application, .handlers = handlers, .profile = profile, .program = try evaluator.Program.open(a, assets.image, 8 * 1024 * 1024) };
            errdefer self.program.close() catch unreachable;
            try self.recover(a);
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
                const bytes = try self.store().object(a, attempt.value.request, 4 * 1024 * 1024);
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
            const bytes = try reader.object(a, reader.manifest.value.task, 256 * 1024);
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
            for (self.runnable.items) |id| if (same(&id, &value.id)) return if (value.schedule == .queued) .queued else .running;
            return .parked;
        }
        pub fn taskCleanupComplete(self: *Self, a: std.mem.Allocator, value: state.Task) !bool {
            if (!value.terminal()) return false;
            const bytes = try self.store().object(a, value.outcome, 4 * 1024 * 1024);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            return cleanupComplete(outcome.value);
        }
        pub fn shutdownIncomplete(self: *Self, a: std.mem.Allocator) !bool {
            for (self.owned) |owned| if (owned) |id| {
                var decoded = try self.task(a, id);
                defer decoded.deinit();
                const value = decoded.value;
                if (value.terminal()) {
                    if (!try self.taskCleanupComplete(a, value)) return true;
                } else if (try self.status(a, value) == .unknown or value.cancellation != null) return true;
            };
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
                const lost = try occurrence.unknown(saved.value, binding, saved.value.state.dispatching.id);
                const previous = value.revision;
                value.revision = try std.math.add(u64, previous, 1);
                value.schedule = .parked;
                value.blocker = .unavailable_environment;
                try self.store().begin();
                defer self.store().rollback();
                try self.store().putRecord(occurrence.Occurrence, "occurrence", current, id, lost);
                try self.event(&value, .delivery_unknown, "{}");
                try self.persist(value, previous, "process.recover-unknown");
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
            var identity: state.Digest = undefined;
            try self.io.randomSecure(&identity);
            const saved: state.Receipt = .{ .id = identity, .client_operation_id = try name(id), .method = method, .request_digest = request, .task = task_value.id, .revision = task_value.revision, .disposition = disposition, .message = message_id, .question = question };
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
        fn persist(self: *Self, value: state.Task, previous: u64, transition: []const u8) !void {
            try self.store().putTask(value, previous);
            try self.namespace.commit(transition);
        }
        fn runnableAdd(self: *Self, id: state.TaskId) !void {
            for (self.runnable.items) |item| if (same(&item, &id)) return;
            if (self.runnable.items.len == 16) return error.Capacity;
            try self.runnable.append(self.allocator, id);
        }
        fn ensureOwnershipCapacity(self: *Self, id: ?state.TaskId) !void {
            for (self.owned) |slot| {
                if (slot == null) return;
                if (id) |existing| if (same(&slot.?, &existing)) return;
            }
            return error.Capacity;
        }
        fn claim(self: *Self, id: state.TaskId) void {
            for (self.owned) |slot| if (slot) |prior| if (same(&prior, &id)) return;
            for (&self.owned) |*slot| if (slot.* == null) {
                slot.* = id;
                return;
            };
            unreachable; // Capacity is reserved before durable admission.
        }
        fn unclaim(self: *Self, id: state.TaskId) void {
            for (&self.owned) |*slot| if (slot.*) |prior| if (same(&prior, &id)) {
                slot.* = null;
                return;
            };
        }
        fn runnableRemove(self: *Self, id: state.TaskId) void {
            for (self.runnable.items, 0..) |item, i| if (same(&item, &id)) {
                _ = self.runnable.orderedRemove(i);
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
            if (self.active) |active| {
                const checkpoint = try active.driver.retire(a);
                a.free(checkpoint);
                try active.driver.destroy();
                self.active = null;
            }
        }
        fn resident(self: *Self, a: std.mem.Allocator, value: state.Task) !*evaluator.Driver {
            try self.compatible(value);
            if (self.active) |active| {
                if (same(&active.task, &value.id) and active.execution_revision == value.execution_revision) return active.driver;
                try self.retire(a);
            }
            const checkpoint = try self.store().object(a, value.checkpoint, 1024 * 1024);
            defer a.free(checkpoint);
            const driver = try evaluator.Driver.start(self.allocator, self.program, .{ .state = checkpoint }, 8 * 1024 * 1024);
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
            const ids = try self.store().taskIds(a, true);
            defer a.free(ids);
            if (ids.len >= 16) return error.Capacity;
            try self.ensureOwnershipCapacity(null);
            // Reserve scheduling capacity before making acceptance durable.
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try self.retire(a);
            var task_id: state.TaskId = undefined;
            try self.io.randomSecure(&task_id);
            const input_bytes = try contracts.encodeOwned(Types.Input, a, input);
            defer a.free(input_bytes);
            const driver = try evaluator.Driver.start(self.allocator, self.program, .{ .initial_args = input_bytes }, 8 * 1024 * 1024);
            self.active = .{ .task = task_id, .execution_revision = 0, .driver = driver };
            errdefer self.retire(a) catch {
                self.store().fenced = true;
            };
            const outcome = try driver.drive(a, .none, 0);
            defer a.free(outcome);
            const checkpoint = try driver.checkpoint(a);
            defer a.free(checkpoint);
            if (checkpoint.len > 1024 * 1024) return error.Capacity;
            if (self.profile.resources.len > maximum_resources) return error.Capacity;
            var resource_bytes: u64 = 0;
            for (self.profile.resources) |bytes| {
                resource_bytes = std.math.add(u64, resource_bytes, bytes.len) catch return error.Capacity;
                if (resource_bytes > 16 * 1024 * 1024) return error.Capacity;
            }
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
            self.runnable.appendAssumeCapacity(task_id);
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
            try self.persist(value, previous, "task.cancel");
            if (!value.terminal()) {
                try self.runnableAdd(task_id);
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
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .queued;
            value.blocker = null;
            try self.store().begin();
            defer self.store().rollback();
            if (rearmed) |pending| try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, task_id, pending);
            try self.event(&value, .resumed, "{}");
            const admitted = try self.receipt(a, .@"resume", id, request, value, .resumed, null, null);
            try self.persist(value, expected, "task.resume");
            try self.runnableAdd(task_id);
            self.claim(task_id);
            return admitted;
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
            if (value.messages.items.len >= 16) return error.Capacity;
            const bytes = try contracts.encodeOwned(Types.Message, a, input);
            defer a.free(bytes);
            var queued_bytes: u64 = bytes.len;
            for (value.messages.items) |message_id| {
                var saved = try self.record(state.Message, a, "message", message_id, task_id);
                defer saved.deinit();
                queued_bytes = try std.math.add(u64, queued_bytes, saved.value.value.bytes);
            }
            if (queued_bytes > 256 * 1024) return error.Capacity;
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
            try self.persist(value, previous, "task.message");
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
            const original_request = try self.store().object(a, question.request, 4 * 1024 * 1024);
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
            try self.persist(value, previous, "task.respond");
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
            try self.persist(value, initial.revision, "task.blocked");
            self.runnableRemove(value.id);
            try self.retire(a);
            return .waiting;
        }

        /// At most one bounded Kronos quantum or one durable environmental
        /// transition. The caller services its control channel between calls.
        pub fn pump(self: *Self, a: std.mem.Allocator) !Step {
            try self.allowed();
            if (self.work != null or self.runnable.items.len == 0) return .idle;
            const id = self.runnable.items[0];
            var decoded = try self.task(a, id);
            defer decoded.deinit();
            const value = decoded.value;
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
                    .unknown, .dispatching => return self.blocked(a, value, .unavailable_environment),
                    .settled_reply => |acquired| {
                        reply = try self.store().acquiredObject(a, acquired.reply, 4 * 1024 * 1024);
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
            const encoded = try driver.drive(a, control, quantum);
            defer a.free(encoded);
            // Kronos may now be ahead of storage. Any failure below fences all
            // further effects; restart uses the old checkpoint and saved reply.
            errdefer self.store().fenced = true;
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, encoded);
            defer outcome.deinit();
            if (outcome.value == .needs_capacity) return error.Capacity;
            const checkpoint = try driver.checkpoint(a);
            defer a.free(checkpoint);
            if (checkpoint.len > 1024 * 1024 or encoded.len > 4 * 1024 * 1024) return error.Capacity;
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
                if (prior.state.admitted == .reply) try self.store().releaseReservation(prior.state.admitted.reply.attempt);
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
            try self.persist(value, initial.revision, "world.advance");
            self.active.?.execution_revision = value.execution_revision;
            if (value.terminal()) {
                try driver.close();
                try driver.destroy();
                self.active = null;
                self.runnableRemove(value.id);
                if (cleanupComplete(outcome.value)) self.unclaim(value.id);
            }
            return .progressed;
        }
        fn clientResult(self: *Self, comptime T: type, a: std.mem.Allocator, value: *state.Task, schema_id: []const u8, result: T) !void {
            const bytes = try json.canonicalBounded(self.allocator, try values.toJson(T, a, result), storage.maximum_object_bytes);
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

        fn dispatch(self: *Self, a: std.mem.Allocator, initial: state.Task, pending: occurrence.Occurrence) !Step {
            const bytes = try self.store().object(a, initial.outcome, 4 * 1024 * 1024);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            if (outcome.value != .requested) return error.CorruptState;
            const request_bytes = outcome.value.requested.request;
            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            if (!same(&request.value.request_identity, &pending.request)) return error.CorruptState;
            const entry = self.handlers.admit(request.value, self.profile.authority, self.application.image_identity, registry.resourceIdentity(self.application.image_identity, initial.profile.digest, initial.resources.items)) catch |err|
                return self.blocked(a, initial, if (err == error.Denied) .denied else .missing_capability);
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const binding: occurrence.Binding = .{ .id = pending.id, .task = pending.task, .request = pending.request };
            const dispatched = try occurrence.dispatch(pending, binding, attempt, initial.cancellation != null, initial.cancellation_applied);
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .active;
            const task_name = std.fmt.bytesToHex(value.id, .lower);
            const ctx: registry.Context = .{ .allocator = a, .io = self.io, .authority = &self.profile.authority, .task_id = &task_name, .profile = self.profile.bytes, .environment = self.profile.environment };
            switch (entry.declaration.kind) {
                .question => {
                    const prompt = try json.canonical(a, try entry.declaration.present.?(ctx, request.value.binding.payload));
                    defer a.free(prompt);
                    if (prompt.len > 32 * 1024) return self.blocked(a, initial, .capacity);
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
                    try self.persist(value, initial.revision, "question.awaiting");
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
                        const message_bytes = try self.store().object(a, saved.value, 256 * 1024);
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
                    try self.persist(value, initial.revision, "inbox.acquire");
                    return .progressed;
                },
                .leaf => {
                    if (entry.declaration.attempt_limit) |limit| {
                        if (try self.store().capabilityAttempts(value.id, entry.declaration.identity) >= limit) return self.blocked(a, initial, .capacity);
                    }
                    var preparation = std.heap.ArenaAllocator.init(a);
                    defer preparation.deinit();
                    const prepared = if (entry.declaration.capture) |adapter| adapter.prepare(self.projectionContext(preparation.allocator(), value), request.value.binding.payload) catch |err|
                        return self.blocked(a, initial, switch (err) {
                            error.Capacity, error.OutOfMemory => .capacity,
                            error.MissingArtifact, error.CorruptObject => .missing_artifact,
                            else => .incompatible_profile,
                        }) else null;
                    if (prepared) |body| if (body.len > 2 * 1024 * 1024) return self.blocked(a, initial, .capacity);
                    const charged_bytes = if (prepared) |body| body.len else request_bytes.len;
                    if (entry.declaration.inference) {
                        const maximum = if (entry.declaration.inference_attempt_limit) |limit|
                            @min(@as(u32, 16), limit(preparation.allocator(), self.profile.bytes) catch return self.blocked(a, initial, .incompatible_profile))
                        else
                            16;
                        if (value.inference_attempts >= maximum or value.inference_request_bytes + charged_bytes > 8 * 1024 * 1024) return self.blocked(a, initial, .capacity);
                        value.inference_attempts += 1;
                        value.inference_request_bytes += charged_bytes;
                    }
                    const retained = try self.allocator.dupe(u8, request_bytes);
                    errdefer self.allocator.free(retained);
                    const retained_prepared = if (prepared) |body| try self.allocator.dupe(u8, body) else null;
                    errdefer if (retained_prepared) |body| self.allocator.free(body);
                    const retained_profile = try self.allocator.dupe(u8, self.profile.bytes);
                    errdefer self.allocator.free(retained_profile);
                    const exhausted = try self.exhaustedCapabilities(value.id, entry.declaration.identity);
                    errdefer self.allocator.free(exhausted);
                    const work: Work = .{ .task = value.id, .occurrence = pending.id, .attempt = attempt, .request = retained, .prepared = retained_prepared, .profile = retained_profile, .exhausted_capabilities = exhausted, .entry = entry, .cleanup = value.cancellation_applied };
                    try self.store().begin();
                    defer self.store().rollback();
                    if (entry.declaration.capture != null) try self.store().reserveCapture(attempt) else try self.store().reserve(attempt);
                    try self.store().createRecord(state.Attempt, "attempt", attempt, value.id, .{ .id = attempt, .task = value.id, .occurrence = pending.id, .request = try self.store().putObject(request_bytes), .profile = value.profile, .capability = try name(entry.declaration.identity), .inference = entry.declaration.inference, .prepared = if (prepared) |body| try self.store().putObject(body) else null });
                    try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, value.id, dispatched);
                    try self.persist(value, initial.revision, "effect.dispatch");
                    self.work = work;
                    return .{ .work = work };
                },
            }
        }

        fn exhaustedCapabilities(self: *Self, task_id: state.TaskId, dispatch_identity: []const u8) ![]const []const u8 {
            var exhausted: std.ArrayList([]const u8) = .empty;
            errdefer exhausted.deinit(self.allocator);
            for (self.handlers.entries) |entry| if (entry.declaration.attempt_limit) |limit| {
                const used = try self.store().capabilityAttempts(task_id, entry.declaration.identity);
                const dispatched: u32 = @intFromBool(same(entry.declaration.identity, dispatch_identity));
                if (used + dispatched >= limit) try exhausted.append(self.allocator, entry.declaration.identity);
            };
            return exhausted.toOwnedSlice(self.allocator);
        }

        fn projectionContext(self: *Self, a: std.mem.Allocator, value: state.Task) registry.ProjectionContext {
            return .{ .allocator = a, .task = value.id, .tenant = value.tenant.bytes, .profile = self.profile.bytes, .objects = .{ .owner = self.store(), .read = struct {
                fn read(owner: *anyopaque, allocator: std.mem.Allocator, ref: state.Reference, limit: usize) ![]u8 {
                    const objects: *storage.Store = @ptrCast(@alignCast(owner));
                    return objects.object(allocator, ref, limit);
                }
            }.read } };
        }

        fn capture(self: *Self, a: std.mem.Allocator, work: Work, raw: []const u8) !void {
            defer self.releaseWork();
            errdefer self.store().fenced = true;
            // The initial native profile keeps captured bytes within its
            // existing durable acquisition reservation.
            if (raw.len > 4 * 1024 * 1024 or work.prepared == null) return error.Capacity;
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const next = try occurrence.captured(saved.value, .{ .id = work.occurrence, .task = work.task, .request = saved.value.request }, work.attempt);
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
            try self.store().reserveCaptured(work.attempt);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, next);
            try self.persist(value, previous, "effect.capture");
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
            const encoded = try self.store().object(a, attempt.value.request, 4 * 1024 * 1024);
            defer a.free(encoded);
            var request = try data.invocation.decode(data.invocation.Request, a, encoded);
            defer request.deinit();
            if (!same(&request.value.request_identity, &pending.request)) return error.CorruptState;
            // Resolve the original schemas without acquiring another I/O grant.
            const entry = try self.handlers.resolve(request.value, self.application.image_identity);
            const adapter = entry.declaration.capture orelse return error.IncompatibleProfile;
            const rendered = try self.store().object(a, raw.value.request, 2 * 1024 * 1024);
            defer a.free(rendered);
            const response = try self.store().object(a, raw.value.response.?, 4 * 1024 * 1024);
            defer a.free(response);
            var projection_arena = std.heap.ArenaAllocator.init(a);
            defer projection_arena.deinit();
            const result = adapter.interpret(self.projectionContext(projection_arena.allocator(), initial), request.value.binding.payload, rendered, response) catch
                return self.blocked(a, initial, .unavailable_environment);
            if (result.reply.len > 1024 * 1024 or result.objects.len > 16) return self.blocked(a, initial, .capacity);
            var total: usize = 0;
            for (result.objects) |object| {
                total = std.math.add(usize, total, object.len) catch return self.blocked(a, initial, .capacity);
                if (total > 2 * 1024 * 1024) return self.blocked(a, initial, .capacity);
            }
            var schema = try data.schema.decode(a, entry.resume_schema);
            defer schema.deinit();
            data.schema.validateValue(a, schema.descriptor, result.reply) catch return self.blocked(a, initial, .unavailable_environment);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = result.reply });
            defer a.free(bound);
            const next = try occurrence.acquired(pending, .{ .id = pending.id, .task = initial.id, .request = pending.request }, attempt_id, storage.digest(bound));
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (entry.declaration.inference) if (result.output_tokens) |tokens| {
                value.inference_output_tokens = std.math.add(u64, value.inference_output_tokens, tokens) catch return self.blocked(a, initial, .capacity);
            };
            try self.store().begin();
            defer self.store().rollback();
            // Projection publication spends its own reserved phase; the
            // successor retains the same budget as a directly acquired reply.
            try self.store().reserveAcquired(attempt_id);
            const reply = try self.store().putObject(bound);
            const objects = try a.alloc(state.Reference, result.objects.len);
            defer a.free(objects);
            for (result.objects, objects) |object, *reference| reference.* = try self.store().putObject(object);
            var projected = raw.value;
            projected.projection = .{ .reply = reply, .objects = .{ .items = objects }, .output_tokens = result.output_tokens };
            try self.store().putRecord(state.Capture, "capture", attempt_id, initial.id, projected);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", pending.id, initial.id, next);
            try self.persist(value, initial.revision, "effect.interpret");
            return .progressed;
        }

        fn currentWork(self: *Self, work: Work) !void {
            const current = self.work orelse return error.StaleOccurrence;
            if (!same(&current.task, &work.task) or !same(&current.occurrence, &work.occurrence) or !same(&current.attempt, &work.attempt)) return error.StaleOccurrence;
        }
        fn releaseWork(self: *Self) void {
            self.allocator.free(self.work.?.request);
            if (self.work.?.prepared) |body| self.allocator.free(body);
            self.allocator.free(self.work.?.profile);
            self.allocator.free(self.work.?.exhausted_capabilities);
            self.work = null;
        }
        /// A worker has returned and will no longer access this work item.
        /// Acquisition is published before any subsequent Kronos consumption.
        pub fn acquire(self: *Self, a: std.mem.Allocator, work: Work, reply: []const u8) !void {
            try self.currentWork(work);
            if (work.entry.declaration.capture != null) return self.capture(a, work, reply);
            defer self.releaseWork();
            errdefer self.store().fenced = true;
            if (reply.len > 4 * 1024 * 1024) return error.Capacity;
            var schema = try data.schema.decode(a, work.entry.resume_schema);
            defer schema.deinit();
            try data.schema.validateValue(a, schema.descriptor, reply);
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const binding: occurrence.Binding = .{ .id = work.occurrence, .task = work.task, .request = saved.value.request };
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = saved.value.request, .value = reply });
            defer a.free(bound);
            const acquired = try occurrence.acquired(saved.value, binding, work.attempt, storage.digest(bound));
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            try self.store().begin();
            defer self.store().rollback();
            _ = try self.store().putObject(bound);
            try self.store().reserveAcquired(work.attempt);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, acquired);
            try self.persist(value, previous, "effect.acquire");
        }
        pub fn unknown(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try self.currentWork(work);
            defer self.releaseWork();
            errdefer self.store().fenced = true;
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const binding: occurrence.Binding = .{ .id = work.occurrence, .task = work.task, .request = saved.value.request };
            const lost = try occurrence.unknown(saved.value, binding, work.attempt);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            value.schedule = .parked;
            value.blocker = .unavailable_environment;
            try self.store().begin();
            defer self.store().rollback();
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, lost);
            try self.event(&value, .delivery_unknown, "{}");
            try self.persist(value, previous, "effect.unknown");
            self.runnableRemove(work.task);
            try self.retire(a);
        }

        pub fn notSent(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try self.currentWork(work);
            defer self.releaseWork();
            var decoded = try self.task(a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved = try self.record(occurrence.Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const next = try occurrence.notSent(saved.value, .{ .id = work.occurrence, .task = work.task, .request = saved.value.request }, work.attempt);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            value.blocker = if (value.cancellation != null and !value.cancellation_applied) null else .unavailable_environment;
            try self.store().begin();
            defer self.store().rollback();
            try self.store().releaseReservation(work.attempt);
            try self.store().putRecord(occurrence.Occurrence, "occurrence", work.occurrence, work.task, next);
            try self.event(&value, .blocked, "{\"delivery\":\"definitely_not_sent\"}");
            try self.persist(value, previous, "effect.not-sent");
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
                const bytes = try self.store().object(temporary, row.body, 256 * 1024);
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
                };
                if (receipt_value.disposition != expected or (receipt_value.message != null) != (receipt_value.method == .message) or
                    (receipt_value.question != null) != (receipt_value.method == .respond)) return error.InvalidArchive;
                if (receipt_value.method == .submit) {
                    if (submitted or receipt_value.revision != 1) return error.InvalidArchive;
                    submitted = true;
                    const input_bytes = try self.store().object(temporary, value.input, 4 * 1024 * 1024);
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
                const bytes = try self.store().object(temporary, item.value, 256 * 1024);
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
                        const request_bytes = try self.store().object(temporary, saved.value.request_object, 4 * 1024 * 1024);
                        var request = try data.invocation.decode(data.invocation.Request, temporary, request_bytes);
                        defer request.deinit();
                        const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                        if (entry.declaration.kind != .inbox) return error.InvalidArchive;
                        const bound = try self.store().acquiredObject(temporary, acquired.reply, 4 * 1024 * 1024);
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
        fn validateOccurrenceProvenance(self: *Self, a: std.mem.Allocator, value: state.Task, records: []const state.ArchiveRecord) !void {
            for (records) |row| {
                if (row.kind != .occurrence) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                var decoded = try self.record(occurrence.Occurrence, temporary, "occurrence", row.id, value.id);
                defer decoded.deinit();
                const saved = decoded.value;
                const is_current = if (value.current_occurrence) |id| same(&id, &saved.id) else false;
                if (is_current == (saved.state == .admitted)) return error.InvalidArchive;
                const encoded = try self.store().object(temporary, saved.request_object, 4 * 1024 * 1024);
                var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
                defer request.deinit();
                if (!same(&request.value.request_identity, &saved.request) or !same(&request.value.binding.program_identity, &self.application.image_identity)) return error.InvalidArchive;
                // Cancellation can retire READY before a handler is available.
                // Neither that state nor READY claims any acquisition.
                if (saved.state == .ready or (saved.state == .admitted and saved.state.admitted == .cancelled and saved.state.admitted.cancelled == null)) continue;
                const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                const acquired: ?occurrence.Acquired = switch (saved.state) {
                    .settled_reply => |reply| reply,
                    .admitted => |admitted| if (admitted == .reply) admitted.reply else null,
                    .awaiting, .not_sent => null,
                    else => return error.UnsettledOccurrence,
                };
                var reply_value: ?[]const u8 = null;
                if (acquired) |reply| {
                    const bytes = try self.store().acquiredObject(temporary, reply.reply, 4 * 1024 * 1024);
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
                        const attempt_id = if (acquired) |reply| reply.attempt else if (saved.state == .not_sent) saved.state.not_sent.id else return error.InvalidArchive;
                        if (acquired) |reply| if (reply.answer != null) return error.InvalidArchive;
                        try requireArchiveRecord(records, .attempt, attempt_id);
                        var attempt = try self.record(state.Attempt, temporary, "attempt", attempt_id, value.id);
                        defer attempt.deinit();
                        if (!same(&attempt.value.occurrence, &saved.id) or !std.meta.eql(attempt.value.request, saved.request_object)) return error.InvalidArchive;
                        if (acquired != null and entry.declaration.capture != null) {
                            try requireArchiveRecord(records, .capture, attempt_id);
                            var raw_capture = try self.record(state.Capture, temporary, "capture", attempt_id, value.id);
                            defer raw_capture.deinit();
                            if (!same(&raw_capture.value.occurrence, &saved.id)) return error.InvalidArchive;
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
                            const bytes = try self.store().object(temporary, reference, 64 * 1024);
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
        /// A transferable capture must reproduce its committed reply, replay
        /// objects and usage through the same pure adapter, without acquisition.
        fn validateCapturedProjections(self: *Self, value: state.Task, records: []const state.ArchiveRecord) !void {
            // Retained unsuccessful/rearmed attempts also need request/profile
            // coherence, even though they have no acquired response.
            for (records) |row| {
                if (row.kind != .attempt) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const temporary = arena.allocator();
                var attempt = try self.record(state.Attempt, temporary, "attempt", row.id, value.id);
                defer attempt.deinit();
                var saved = try self.record(occurrence.Occurrence, temporary, "occurrence", attempt.value.occurrence, value.id);
                defer saved.deinit();
                const encoded = try self.store().object(temporary, attempt.value.request, 4 * 1024 * 1024);
                var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
                defer request.deinit();
                const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                if (entry.declaration.attempt_limit) |limit| {
                    if (try self.store().capabilityAttempts(value.id, entry.declaration.identity) > limit) return error.InvalidArchive;
                }
                if (entry.declaration.kind != .leaf or !same(&request.value.request_identity, &saved.value.request) or
                    !std.meta.eql(attempt.value.request, saved.value.request_object) or !std.meta.eql(attempt.value.profile, value.profile) or !same(attempt.value.capability.bytes, entry.declaration.identity) or
                    attempt.value.inference != entry.declaration.inference or (attempt.value.prepared != null) != (entry.declaration.capture != null)) return error.InvalidArchive;
                if (entry.declaration.inference_attempt_limit) |limit| {
                    const profile = try self.store().object(temporary, value.profile, 256 * 1024);
                    if (value.inference_attempts > @min(@as(u32, 16), try limit(temporary, profile))) return error.InvalidArchive;
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
                const projection = capture_value.projection orelse return error.UnsettledOccurrence;
                if (capture_value.disposition != .complete or capture_value.response == null or !same(&capture_value.attempt, &row.id)) return error.CorruptState;
                var attempt = try self.record(state.Attempt, temporary, "attempt", row.id, value.id);
                defer attempt.deinit();
                var saved = try self.record(occurrence.Occurrence, temporary, "occurrence", capture_value.occurrence, value.id);
                defer saved.deinit();
                const acquired = switch (saved.value.state) {
                    .settled_reply => |reply| reply,
                    .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.CorruptState,
                    else => return error.UnsettledOccurrence,
                };
                if (attempt.value.prepared == null or !same(&attempt.value.occurrence, &capture_value.occurrence) or
                    !std.meta.eql(attempt.value.profile, value.profile) or !std.meta.eql(attempt.value.prepared.?, capture_value.request) or
                    !same(&acquired.attempt, &row.id) or !same(&acquired.reply, &projection.reply.digest)) return error.CorruptState;
                const encoded = try self.store().object(temporary, attempt.value.request, 4 * 1024 * 1024);
                var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
                defer request.deinit();
                if (!same(&request.value.request_identity, &saved.value.request)) return error.CorruptState;
                const entry = try self.handlers.resolve(request.value, self.application.image_identity);
                if (!same(attempt.value.capability.bytes, entry.declaration.identity) or attempt.value.inference != entry.declaration.inference) return error.IncompatibleProfile;
                const adapter = entry.declaration.capture orelse return error.IncompatibleProfile;
                const context = self.projectionContext(temporary, value);
                const rendered = try self.store().object(temporary, capture_value.request, 2 * 1024 * 1024);
                if (!same(rendered, try adapter.prepare(context, request.value.binding.payload))) return error.CorruptState;
                const response = try self.store().object(temporary, capture_value.response.?, 4 * 1024 * 1024);
                const result = try adapter.interpret(context, request.value.binding.payload, rendered, response);
                if (result.reply.len > 1024 * 1024 or result.objects.len != projection.objects.items.len or result.output_tokens != projection.output_tokens) return error.CorruptState;
                var total: u64 = 0;
                for (result.objects, projection.objects.items) |object, reference| {
                    total = try std.math.add(u64, total, object.len);
                    if (total > 2 * 1024 * 1024 or object.len != reference.bytes or !same(&storage.digest(object), &reference.digest)) return error.CorruptState;
                }
                var schema = try data.schema.decode(temporary, entry.resume_schema);
                defer schema.deinit();
                try data.schema.validateValue(temporary, schema.descriptor, result.reply);
                const bound = try data.invocation.encodeOwned(data.invocation.Result, temporary, .{ .request_identity = saved.value.request, .value = result.reply });
                if (!same(bound, try self.store().object(temporary, projection.reply, 4 * 1024 * 1024))) return error.CorruptState;
                if (entry.declaration.inference) if (result.output_tokens) |tokens| {
                    output_tokens = try std.math.add(u64, output_tokens, tokens);
                };
            }
            if (output_tokens != value.inference_output_tokens) return error.CorruptState;
        }

        pub fn exportCheckpoint(self: *Self, a: std.mem.Allocator, task_id: state.TaskId, path: []const u8) !archive_api.Exported {
            try self.archiveAccess();
            var value = try self.task(a, task_id);
            defer value.deinit();
            try self.compatible(value.value);
            {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const index = try self.store().archiveIndex(arena.allocator(), task_id, .{ .digest = storage.digest(self.assets.manifest), .bytes = self.assets.manifest.len });
                try self.validateArchiveAdmissions(arena.allocator(), value.value, index);
                try self.validateOccurrenceProvenance(arena.allocator(), value.value, index.records.items);
                try self.validateCapturedProjections(value.value, index.records.items);
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
            const build_bytes = try self.store().object(a, reader.manifest.value.build, 256 * 1024);
            defer a.free(build_bytes);
            var build = try json.parse(a, build_bytes, .{ .bytes = 256 * 1024 });
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
            try self.validateCapturedProjections(value, reader.manifest.value.records.items);
            try self.validateImportedState(a, value, inspected.current);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const origin: state.Origin = .{ .id = reader.identity, .task = value.id, .build = reader.manifest.value.build, .native_identity = original_runtime, .source_revision = previous };
            try self.store().createRecord(state.Origin, "origin", origin.id, value.id, origin);
            var event_data = json.object();
            try json.put(a, &event_data, "archive_sha256", json.string(try a.dupe(u8, &std.fmt.bytesToHex(reader.identity, .lower))));
            try self.event(&value, .imported, try json.canonical(a, event_data));
            const admitted = try self.receipt(a, .import_checkpoint, id, request, value, .imported, null, null);
            try self.persist(value, previous, "checkpoint.import");
            return admitted;
        }

        /// Ordering and byte bounds belong to the pending projection. Complete
        /// typed payload/receipt/occurrence coherence is checked for all history
        /// by validateArchiveAdmissions and validateOccurrenceProvenance.
        fn validatePendingMessages(self: *Self, a: std.mem.Allocator, value: state.Task) !void {
            if (value.messages.items.len != 0 and (value.terminal() or !self.acceptsMessages())) return error.InvalidArchive;
            var previous: u64 = 0;
            var bytes: u64 = 0;
            for (value.messages.items, 0..) |id, index| {
                var decoded = try self.record(state.Message, a, "message", id, value.id);
                defer decoded.deinit();
                const item = decoded.value;
                if (item.ordinal <= previous) return error.InvalidArchive;
                previous = item.ordinal;
                bytes = std.math.add(u64, bytes, item.value.bytes) catch return error.InvalidArchive;
                if (bytes > 256 * 1024 or (item.disposition == .acquired and index != 0)) return error.InvalidArchive;
            }
        }

        fn validateImportedState(self: *Self, a: std.mem.Allocator, value: state.Task, pending: ?occurrence.Occurrence) !void {
            if (value.cancellation_applied and value.cancellation == null) return error.InvalidArchive;
            try self.validatePendingMessages(a, value);
            const driver = try self.resident(a, value);
            errdefer self.retire(a) catch {
                self.store().fenced = true;
            };
            const observed = try driver.drive(a, .none, 0);
            defer a.free(observed);
            const prior = try self.store().object(a, value.outcome, 4 * 1024 * 1024);
            defer a.free(prior);
            if (!same(observed, prior)) return error.InvalidArchive;
            const checkpoint = try driver.checkpoint(a);
            defer a.free(checkpoint);
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
                    // The imported marker claims Kronos already received this
                    // control. Let Kronos establish that it is a no-op without
                    // executing authored steps or dispatching any native work.
                    const repeated = try driver.drive(a, .{ .cancel = .{ .text = value.cancellation.?.bytes } }, 0);
                    defer a.free(repeated);
                    const repeated_checkpoint = try driver.checkpoint(a);
                    defer a.free(repeated_checkpoint);
                    if (!same(repeated, observed) or !same(repeated_checkpoint, checkpoint)) return error.InvalidArchive;
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
            const expected = try json.canonicalBounded(self.allocator, try values.toJson(T, a, decoded.value), storage.maximum_object_bytes);
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
        pub fn close(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            try self.retire(a);
            try self.program.close();
            self.runnable.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn park(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            for (self.runnable.items) |id| {
                var decoded = try self.task(a, id);
                defer decoded.deinit();
                var value = decoded.value;
                if (value.terminal()) continue;
                const previous = value.revision;
                value.revision = try std.math.add(u64, previous, 1);
                value.schedule = .parked;
                try self.store().begin();
                defer self.store().rollback();
                try self.event(&value, .parked, "{}");
                try self.persist(value, previous, "task.park");
            }
            self.runnable.clearRetainingCapacity();
            try self.retire(a);
        }
    };
}
