//! Reconstruct retained dependencies from canonical owners. The stored edge
//! table is checked against decoded records and registered projection codecs;
//! it is never the source of its own completeness proof.
const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const storage = @import("store.zig");
const state = @import("state.zig");
const registry = @import("registry.zig");
const occurrence = @import("occurrence.zig");
const Ref = state.Reference;
const Digest = state.Digest;
const Key = struct { kind: state.RecordKind, task: state.TaskId, id: Digest };
const Edge = struct { parent: Digest, child: Digest };
pub const Statistics = struct { objects: u64 = 0, bytes: u64 = 0, edges: u64 = 0 };
const Object = struct { length: u64, body: ?[]const u8 = null };

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn fixed(comptime size: usize, bytes: []const u8) ![size]u8 {
    if (bytes.len != size) return error.CorruptState;
    return bytes[0..size].*;
}
const Audit = struct {
    a: std.mem.Allocator,
    store: *storage.Store,
    handlers: registry.Registry,
    objects: std.AutoArrayHashMapUnmanaged(Digest, Object) = .empty,
    edges: std.AutoHashMapUnmanaged(Edge, void) = .empty,
    images: std.AutoHashMapUnmanaged(Digest, Digest) = .empty,
    tasks: std.AutoHashMapUnmanaged(state.TaskId, struct { revision: u64, profile: Ref, body: Ref, image: Ref }) = .empty,
    records: std.AutoArrayHashMapUnmanaged(Key, Ref) = .empty,
    recovery_receipts: std.AutoHashMapUnmanaged(Key, void) = .empty,
    statistics: Statistics = .{},

    fn add(self: *Audit, ref: Ref) !void {
        const found = try self.objects.getOrPut(self.a, ref.digest);
        if (found.found_existing) {
            if (found.value_ptr.length != ref.bytes) return error.CorruptState;
        } else found.value_ptr.* = .{ .length = ref.bytes };
    }
    fn indexed(self: *Audit, bytes: []const u8) !Ref {
        const ref = try self.store.objectReference(try fixed(32, bytes), null);
        try self.add(ref);
        return ref;
    }
    /// Typed bodies are read once and retained only for this pass. Large opaque
    /// checkpoints/captures are verified in streaming form in finish().
    fn body(self: *Audit, ref: Ref) ![]const u8 {
        try self.add(ref);
        if (self.objects.get(ref.digest).?.body) |bytes| return bytes;
        const bytes = try self.store.object(self.a, ref, null);
        self.objects.getPtr(ref.digest).?.body = bytes;
        return bytes;
    }
    fn edge(self: *Audit, parent: Ref, child: Ref) !void {
        try self.add(parent);
        try self.add(child);
        try self.edges.put(self.a, .{ .parent = parent.digest, .child = child.digest }, {});
    }
    fn imageIdentity(self: *Audit, ref: Ref) !Digest {
        try self.add(ref);
        if (self.images.get(ref.digest)) |identity| return identity;
        // A saved request belongs to its task's canonical program, independently
        // of the launching executable. Raw object hashes are not program IDs.
        var decoded = try data.program_image.decode(self.store.allocator, try self.body(ref));
        defer decoded.deinit();
        try self.images.put(self.a, ref.digest, decoded.identity);
        return decoded.identity;
    }
    fn occurrenceImage(self: *Audit, saved: occurrence.Occurrence) !Digest {
        var route = try self.record(.execution_route, saved.task, saved.id);
        defer route.deinit();
        if (!std.meta.eql(route.value.work, saved.work) or !std.meta.eql(route.value.task, saved.task) or !std.meta.eql(route.value.id, saved.id)) return error.CorruptState;
        var image = self.tasks.get(saved.task).?.image;
        if (saved.work) |id| {
            var work = try self.record(.workspace_work, saved.task, id);
            defer work.deinit();
            var program = try self.record(.workspace_program, saved.task, try @import("workspace_state.zig").custodyId(self.a, saved.task, work.value.program));
            defer program.deinit();
            image = program.value.description.image;
            if (!std.meta.eql(route.value.delegation, work.value.delegation)) return error.CorruptState;
        }
        if (!std.meta.eql(image, route.value.image)) return error.CorruptState;
        const identity = try self.imageIdentity(image);
        if (!std.meta.eql(identity, route.value.program_identity)) return error.CorruptState;
        return identity;
    }
    fn value(self: *Audit, comptime T: type, parent: Ref, input: T) !void {
        var sink = struct {
            audit: *Audit,
            parent: Ref,
            pub fn add(this: *@This(), child: Ref) !void {
                try this.audit.edge(this.parent, child);
            }
            pub fn reply(this: *@This(), acquired: occurrence.Acquired) !void {
                try this.add(try this.audit.store.objectReference(acquired.reply, null));
            }
        }{ .audit = self, .parent = parent };
        try state.visitReferences(T, input, &sink);
    }
    fn taskRoots(self: *Audit) !void {
        var rows = try self.store.database.prepare("SELECT id,revision,terminal,body FROM tasks", &.{});
        defer rows.deinit();
        while (try rows.step() == .row) {
            const id = try fixed(16, try rows.bytes(0));
            const ref = try self.indexed(try rows.bytes(3));
            var decoded = try contracts.decodeOwned(state.Task, self.a, try self.body(ref));
            defer decoded.deinit();
            const task = decoded.value;
            if (!same(&task.id, &id) or task.revision != try rows.integer(1) or @intFromBool(task.terminal()) != try rows.integer(2)) return error.CorruptState;
            try self.tasks.put(self.a, id, .{ .revision = task.revision, .profile = task.profile, .body = ref, .image = task.image });
            try self.value(state.Task, ref, task);
        }
    }
    fn recordRoots(self: *Audit) !void {
        var rows = try self.store.database.prepare("SELECT kind,id,task,body FROM records", &.{});
        defer rows.deinit();
        while (try rows.step() == .row) {
            const kind = std.meta.stringToEnum(state.RecordKind, try rows.bytes(0)) orelse return error.CorruptState;
            const id = try fixed(32, try rows.bytes(1));
            const task = try fixed(16, try rows.bytes(2));
            if (!self.tasks.contains(task)) return error.CorruptState;
            const ref = try self.indexed(try rows.bytes(3));
            try self.records.put(self.a, .{ .kind = kind, .task = task, .id = id }, ref);
            inline for (@typeInfo(state.RecordKind).@"enum".field_names) |name| {
                if (kind == @field(state.RecordKind, name)) {
                    const T = storage.Record(name);
                    var decoded = try contracts.decodeOwned(T, self.a, try self.body(ref));
                    defer decoded.deinit();
                    const item = decoded.value;
                    const bound_task = if (T == state.Artifact) item.task orelse return error.CorruptState else item.task;
                    const bound_id = if (T == state.Capture) item.attempt else item.id;
                    if (!same(&bound_task, &task) or !same(&bound_id, &id)) return error.CorruptState;
                    try self.value(T, ref, item);
                    if (T == state.Reconciliation) try state.visitReconciliationHistory(self.a, self.store, item, self);
                }
            }
        }
    }
    fn otherRoots(self: *Audit) !void {
        {
            var rows = try self.store.database.prepare("SELECT task,seq,revision,body FROM events", &.{});
            defer rows.deinit();
            while (try rows.step() == .row) {
                const task = try fixed(16, try rows.bytes(0));
                const owner = self.tasks.get(task) orelse return error.CorruptState;
                const ref = try self.indexed(try rows.bytes(3));
                var decoded = try contracts.decodeOwned(state.Event, self.a, try self.body(ref));
                defer decoded.deinit();
                const event = decoded.value;
                if (!same(&event.task, &task) or event.seq != try rows.integer(1) or event.revision != try rows.integer(2) or event.revision > owner.revision) return error.CorruptState;
                try self.value(state.Event, ref, event);
            }
        }
        {
            var rows = try self.store.database.prepare("SELECT task,request,receipt FROM operations", &.{});
            defer rows.deinit();
            while (try rows.step() == .row) {
                const task = try fixed(16, try rows.bytes(0));
                const owner = self.tasks.get(task) orelse return error.CorruptState;
                const request = try fixed(32, try rows.bytes(1));
                const ref = try self.indexed(try rows.bytes(2));
                var decoded = try contracts.decodeOwned(state.Receipt, self.a, try self.body(ref));
                defer decoded.deinit();
                const receipt = decoded.value;
                if (!same(&receipt.task, &task) or !same(&receipt.request_digest, &request) or receipt.revision > owner.revision) return error.CorruptState;
                try self.value(state.Receipt, ref, receipt);
                try state.visitWorkspaceReceipt(self.a, self.store, receipt, self);
                if ((receipt.method == .reconcile) != (receipt.reconciliation != null)) return error.CorruptState;
                if (receipt.reconciliation) |id| {
                    var recovery = try self.record(.reconciliation, task, id);
                    defer recovery.deinit();
                    if (recovery.value.admission_revision != receipt.revision or !std.meta.eql(recovery.value.request_digest, receipt.request_digest) or !same(recovery.value.client_operation_id.bytes, receipt.client_operation_id.bytes)) return error.CorruptState;
                    try self.recovery_receipts.put(self.a, .{ .kind = .reconciliation, .task = task, .id = id }, {});
                }
            }
        }
    }
    pub fn typed(self: *Audit, comptime T: type, parent: Ref, input: T) !void {
        try self.value(T, parent, input);
    }
    fn record(self: *Audit, comptime kind: state.RecordKind, task: state.TaskId, id: Digest) !contracts.Decoded(storage.Record(@tagName(kind))) {
        const ref = self.records.get(.{ .kind = kind, .task = task, .id = id }) orelse return error.CorruptState;
        return contracts.decodeOwned(storage.Record(@tagName(kind)), self.a, try self.body(ref));
    }
    fn projections(self: *Audit) !void {
        for (self.records.keys()) |key| {
            if (key.kind != .capture) continue;
            var decoded = try self.record(.capture, key.task, key.id);
            defer decoded.deinit();
            const capture = decoded.value;
            if (capture.reconciliation) |id| if (!self.records.contains(.{ .kind = .reconciliation, .task = key.task, .id = id })) return error.CorruptState;
            var attempt = try self.record(.attempt, key.task, capture.attempt);
            defer attempt.deinit();
            var saved = try self.record(.occurrence, key.task, capture.occurrence);
            defer saved.deinit();
            const owner = self.tasks.get(key.task).?;
            if (!same(&attempt.value.occurrence, &capture.occurrence) or attempt.value.prepared == null or
                !std.meta.eql(attempt.value.prepared.?, capture.request) or !std.meta.eql(attempt.value.profile, owner.profile) or
                !std.meta.eql(attempt.value.request, saved.value.request_object)) return error.CorruptState;
            var request = try data.invocation.decode(data.invocation.Request, self.a, try self.body(attempt.value.request));
            defer request.deinit();
            if (!same(&request.value.request_identity, &saved.value.request)) return error.CorruptState;
            const entry = try self.handlers.resolve(request.value, try self.occurrenceImage(saved.value));
            if (!same(entry.declaration.identity, attempt.value.capability.bytes) or entry.declaration.inference != attempt.value.inference) return error.CorruptState;
            if (attempt.value.operation == .workspace_build) {
                if (entry.declaration.kind != .workspace or attempt.value.inference or saved.value.work != null or
                    (capture.disposition == .complete) != (capture.response != null)) return error.CorruptState;
                if (capture.projection) |projection| if (projection.objects.items.len != 0 or projection.output_tokens != null) return error.CorruptState;
                continue;
            }
            const adapter = entry.declaration.capture orelse return error.CorruptState;
            if ((capture.disposition == .complete) != (capture.response != null)) return error.CorruptState;
            // Raw capture is durable before interpretation, including a response
            // that the pure interpreter will reject. Its bytes remain opaque.
            const projection = capture.projection orelse continue;
            if (capture.disposition != .complete or capture.response == null) return error.CorruptState;
            const objects = try self.a.alloc([]const u8, projection.objects.items.len);
            var parents: std.AutoHashMapUnmanaged(Digest, u64) = .empty;
            for (objects, projection.objects.items) |*bytes, ref| {
                bytes.* = try self.body(ref);
                try parents.put(self.a, ref.digest, ref.bytes);
            }
            const edges = try adapter.dependencies(self.a, objects);
            for (edges) |dependency| {
                if ((parents.get(dependency.parent.digest) orelse return error.InvalidProjection) != dependency.parent.bytes) return error.InvalidProjection;
                try self.edge(dependency.parent, dependency.child);
            }
        }
    }
    fn reconciliations(self: *Audit) !void {
        var pending_owners = std.AutoHashMap(Key, void).init(self.a);
        defer pending_owners.deinit();
        for (self.records.keys()) |key| {
            if (key.kind != .reconciliation) continue;
            if (!self.recovery_receipts.contains(key)) return error.CorruptState;
            var decoded = try self.record(.reconciliation, key.task, key.id);
            defer decoded.deinit();
            const item = decoded.value;
            const owner = self.tasks.get(key.task).?;
            var task = try contracts.decodeOwned(state.Task, self.a, try self.body(owner.body));
            defer task.deinit();
            if (item.admission_revision > owner.revision or !std.meta.eql(item.profile, owner.profile) or item.resources.items.len != task.value.resources.items.len) return error.CorruptState;
            for (item.resources.items, task.value.resources.items) |actual, expected| if (!std.meta.eql(actual, expected)) return error.CorruptState;
            if (!std.meta.eql(self.records.get(.{ .kind = .attempt, .task = key.task, .id = item.attempt }) orelse return error.CorruptState, item.original_attempt)) return error.CorruptState;
            var occurrence_value = try self.record(.occurrence, key.task, item.occurrence);
            defer occurrence_value.deinit();
            if (!std.meta.eql(occurrence_value.value.request_object, item.request)) return error.CorruptState;
            var request = try data.invocation.decode(data.invocation.Request, self.a, try self.body(item.request));
            defer request.deinit();
            if (!std.meta.eql(request.value.request_identity, occurrence_value.value.request)) return error.CorruptState;
            const image = try self.occurrenceImage(occurrence_value.value);
            const entry = try self.handlers.resolve(request.value, image);
            if (!same(entry.declaration.identity, item.capability.bytes)) return error.CorruptState;
            if (item.provenance != .none or item.owner_epoch != null) {
                const adapter = entry.declaration.recovery orelse return error.CorruptState;
                if (!same(adapter.identity, item.mechanism.bytes) or adapter.version != item.mechanism_version) return error.CorruptState;
                if (item.selection == .lookup and adapter.lookup == null) return error.CorruptState;
                if (item.selection == .rederive and adapter.rederive == null) return error.CorruptState;
            }
            switch (item.outcome) {
                .pending => {
                    const saved = occurrence_value.value;
                    if (saved.state != .unknown or !std.meta.eql(saved.state.unknown.id, item.attempt) or task.value.current_occurrence == null or !std.meta.eql(task.value.current_occurrence.?, item.occurrence)) return error.CorruptState;
                    const owner_key: Key = .{ .kind = .occurrence, .task = key.task, .id = item.occurrence };
                    if ((try pending_owners.getOrPut(owner_key)).found_existing) return error.CorruptState;
                },
                .not_sent => {},
                .unresolved => {},
                .capture_admitted => |ref| {
                    const pending = occurrence_value.value.state;
                    if (pending != .captured or !std.meta.eql(pending.captured.id, item.attempt)) return error.CorruptState;
                    var capture = try self.record(.capture, key.task, item.attempt);
                    defer capture.deinit();
                    if (capture.value.reconciliation == null or !std.meta.eql(capture.value.reconciliation.?, key.id) or capture.value.response == null or !std.meta.eql(capture.value.response.?, ref) or capture.value.projection != null) return error.CorruptState;
                },
                .reply_settled => |ref| {
                    const acquired = switch (occurrence_value.value.state) {
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted == .reply) admitted.reply else return error.CorruptState,
                        else => return error.CorruptState,
                    };
                    if (!std.meta.eql(acquired.attempt, item.attempt) or !std.meta.eql(acquired.reply, ref.digest)) return error.CorruptState;
                    if (entry.declaration.capture != null) {
                        var capture = try self.record(.capture, key.task, item.attempt);
                        defer capture.deinit();
                        if (capture.value.reconciliation == null or !std.meta.eql(capture.value.reconciliation.?, key.id) or capture.value.projection == null or !std.meta.eql(capture.value.projection.?.reply, ref) or item.previous == null) return error.CorruptState;
                    }
                },
            }
            if (item.provenance == .authentic or item.provenance == .authoritative) {
                const evidence = try self.body(item.evidence orelse return error.CorruptState);
                const input = registry.RecoveryInput.fromReconciliation(item, request.value.request_identity, entry.declaration.inference);
                const finding = try self.store.project(registry.RecoveryFinding, self.a, self.handlers, .{ .task = key.task, .tenant = task.value.tenant.bytes, .profile = try self.body(item.profile), .application = image, .resources = item.resources.items }, struct {
                    handlers: registry.Registry,
                    input: registry.RecoveryInput,
                    evidence: []const u8,
                    pub fn run(this: @This(), ctx: registry.ProjectionContext) !registry.RecoveryFinding {
                        return this.handlers.verifyRecovery(ctx, this.input, this.evidence);
                    }
                }{ .handlers = self.handlers, .input = input, .evidence = evidence });
                if (item.provenance == .authoritative) {
                    if (finding != .not_sent) return error.CorruptState;
                } else {
                    if (finding != .capture) return error.CorruptState;
                    var captured = try self.record(.capture, key.task, item.attempt);
                    defer captured.deinit();
                    const ref = captured.value.response orelse return error.CorruptState;
                    if (ref.bytes != finding.capture.len or !std.meta.eql(ref.digest, storage.digest(finding.capture))) return error.CorruptState;
                }
            }
        }
    }
    fn finish(self: *Audit) !Statistics {
        // Compare each derived edge, including both expected lengths. A missing
        // edge cannot borrow authority from the mere existence of its child.
        var edges = self.edges.keyIterator();
        while (edges.next()) |dependency| {
            var row = try self.store.database.prepare("SELECT parent_bytes,child_bytes FROM dependencies WHERE parent=? AND child=?", &.{ .{ .blob = &dependency.parent }, .{ .blob = &dependency.child } });
            defer row.deinit();
            if (try row.step() != .row or try row.integer(0) != self.objects.get(dependency.parent).?.length or try row.integer(1) != self.objects.get(dependency.child).?.length) return error.CorruptState;
        }
        // Iteration is flat: references are extracted by typed owners above,
        // without trusting stored edges or recursively chasing a native stack.
        for (self.objects.keys(), self.objects.values()) |id, object| {
            if (object.body == null) try self.store.objectRange(.{ .digest = id, .bytes = object.length }, 0, &.{});
            self.statistics.objects += 1;
            self.statistics.bytes = try std.math.add(u64, self.statistics.bytes, object.length);
        }
        self.statistics.edges = self.edges.count();
        return self.statistics;
    }
};

/// Caller holds the Store transaction for a stable database view. No projection
/// interpretation, provider acquisition, grants, or artifact disclosure occurs.
pub fn verify(store: *storage.Store, handlers: registry.Registry) !Statistics {
    if (!store.transaction) return error.InvalidState;
    var arena = std.heap.ArenaAllocator.init(store.allocator);
    defer arena.deinit();
    var audit: Audit = .{ .a = arena.allocator(), .store = store, .handlers = handlers };
    try audit.taskRoots();
    try audit.recordRoots();
    try audit.otherRoots();
    try audit.projections();
    try audit.reconciliations();
    return audit.finish();
}
