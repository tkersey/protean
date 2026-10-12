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
    image: Digest,
    objects: std.AutoArrayHashMapUnmanaged(Digest, Object) = .empty,
    edges: std.AutoHashMapUnmanaged(Edge, void) = .empty,
    tasks: std.AutoHashMapUnmanaged(state.TaskId, struct { revision: u64, profile: Ref }) = .empty,
    records: std.AutoArrayHashMapUnmanaged(Key, Ref) = .empty,
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
            try self.tasks.put(self.a, id, .{ .revision = task.revision, .profile = task.profile });
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
            }
        }
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
            const entry = try self.handlers.resolve(request.value, self.image);
            if (!same(entry.declaration.identity, attempt.value.capability.bytes) or entry.declaration.inference != attempt.value.inference) return error.CorruptState;
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
pub fn verify(store: *storage.Store, handlers: registry.Registry, image: Digest) !Statistics {
    if (!store.transaction) return error.InvalidState;
    var arena = std.heap.ArenaAllocator.init(store.allocator);
    defer arena.deinit();
    var audit: Audit = .{ .a = arena.allocator(), .store = store, .handlers = handlers, .image = image };
    try audit.taskRoots();
    try audit.recordRoots();
    try audit.otherRoots();
    try audit.projections();
    return audit.finish();
}
