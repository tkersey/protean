//! Transactional environmental state. Kosmos bytes are opaque objects; every
//! acknowledged mutation publishes its receipt, records and events together.
const std = @import("std");
const contracts = @import("protean_contracts");
const sqlite = @import("sqlite.zig");
const state = @import("state.zig");
const occurrence = @import("occurrence.zig");
const hash_abi = @import("hash_abi.zig");
const Digest = state.Digest;
pub const format: u32 = @import("native_options").state_format;

pub fn digest(bytes: []const u8) Digest {
    // Share the optimized standard-library primitive already linked for file
    // identity. Every byte is still checked; the store owns admission and trust.
    var hash: hash_abi.State = undefined;
    hash_abi.protean_native_sha256_init(&hash);
    hash_abi.protean_native_sha256_update(&hash, bytes.ptr, bytes.len);
    var result: Digest = undefined;
    hash_abi.protean_native_sha256_final(&hash, &result);
    return result;
}

test "object digests retain SHA-256 across padding and large input boundaries" {
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &std.fmt.bytesToHex(digest(""), .lower));
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &std.fmt.bytesToHex(digest("abc"), .lower));
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 37);
    for ([_]usize{ 1, 55, 56, 63, 64, 65, 255, 1024, 65535, 65536, 65537, bytes.len }) |length| {
        var expected: Digest = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..length], &expected, .{});
        try std.testing.expectEqualSlices(u8, &expected, &digest(bytes[0..length]));
    }
}

pub const Head = struct { generation: u64, parent: Digest, digest: Digest };
/// Native retention includes every portable kind and source-local snapshots.
/// Deriving the inclusion keeps new portable kinds in the native audit too.
pub const RecordKind = blk: {
    const names = @typeInfo(state.RecordKind).@"enum".field_names ++ &[_][]const u8{"placement_snapshot"};
    break :blk @Enum(u32, .exhaustive, names, &std.simd.iota(u32, names.len));
};
pub fn Record(comptime kind: []const u8) type {
    return switch (@field(RecordKind, kind)) {
        .occurrence => occurrence.Occurrence,
        .question => state.Question,
        .message => state.Message,
        .artifact => state.Artifact,
        .capture => state.Capture,
        .attempt => state.Attempt,
        .reconciliation => state.Reconciliation,
        .origin => state.Origin,
        .workspace_program => @import("workspace_state.zig").Program,
        .workspace_runtime => @import("workspace_state.zig").Runtime,
        .workspace_work => @import("workspace_state.zig").Work,
        .workspace_trial => @import("workspace_state.zig").Trial,
        .workspace_value => @import("workspace_state.zig").Value,
        .workspace_view => @import("workspace_state.zig").View,
        .workspace_port => @import("workspace_state.zig").Port,
        .workspace_port_reply => @import("workspace_state.zig").PortReply,
        .execution_route => @import("workspace_state.zig").ExecutionRoute,
        .workspace_wait => @import("workspace_state.zig").Wait,
        .workspace_delegation => @import("workspace_state.zig").Delegation,
        .workspace_reply => @import("workspace_state.zig").ReplyObservation,
        .placement_custody => @import("placement.zig").Custody,
        .placement_control => @import("placement.zig").ControlRecord,
        .placement_action => @import("placement.zig").ActionRecord,
        .placement_move => @import("placement.zig").Move,
        .placement_succession => @import("placement.zig").Succession,
        .placement_snapshot => @import("placement.zig").Snapshot,
        .root_operation => state.RootOperation,
        .controller_binding => state.ControllerBinding,
        .controller_interaction => state.ControllerInteraction,
        .controller_succession => state.ControllerSuccession,
        .controller_residual => state.ControllerResidual,
        .placement_behavior => @import("placement.zig").BehaviorRecord,
    };
}
pub const Store = struct {
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    head: Head,
    transaction: bool = false,
    fenced: bool = false,
    /// Independent of append generations: unrelated owner commits preserve
    /// validation facts, while a loss of custody invalidates all of them.
    integrity_epoch: u64 = 1,
    data_version: u64 = 0,
    sealed_generation: ?u64 = null,
    projecting: bool = false,
    context_cache: @import("adaptive_context.zig").Cache = .{},
    retention_epoch: ?u64 = null,
    retention_image: ?Digest = null,

    /// The namespace owner has already authenticated the directory, acquired
    /// its OS lock and decided whether this is a new or existing database.
    pub fn init(a: std.mem.Allocator, database: *sqlite.Database, create: bool, namespace: Digest) !Store {
        try database.exec("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE;");
        try database.exec("PRAGMA page_size=4096;");
        if (create) {
            try database.exec("BEGIN IMMEDIATE;");
            errdefer database.exec("ROLLBACK;") catch {};
            try database.exec(std.fmt.comptimePrint("CREATE TABLE meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1), format INTEGER NOT NULL CHECK(format={d}), namespace BLOB NOT NULL, generation INTEGER NOT NULL, parent BLOB NOT NULL, head BLOB NOT NULL);", .{format}) ++
                \\CREATE TABLE objects(digest BLOB PRIMARY KEY CHECK(length(digest)=32), body BLOB NOT NULL);
                \\CREATE TABLE dependencies(parent BLOB NOT NULL REFERENCES objects(digest), parent_bytes INTEGER NOT NULL CHECK(parent_bytes>=0), child BLOB NOT NULL REFERENCES objects(digest), child_bytes INTEGER NOT NULL CHECK(child_bytes>=0), PRIMARY KEY(parent,child)) WITHOUT ROWID;
                \\CREATE INDEX dependency_children ON dependencies(child,parent);
                \\CREATE TRIGGER dependency_lengths BEFORE INSERT ON dependencies BEGIN
                \\  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM objects WHERE digest=NEW.parent AND length(body)=NEW.parent_bytes) OR NOT EXISTS(SELECT 1 FROM objects WHERE digest=NEW.child AND length(body)=NEW.child_bytes) THEN RAISE(ABORT,'invalid dependency length') END;
                \\END;
                \\CREATE TRIGGER retained_object_immutable BEFORE UPDATE ON objects WHEN EXISTS(SELECT 1 FROM dependencies WHERE parent=OLD.digest OR child=OLD.digest) OR EXISTS(SELECT 1 FROM tasks WHERE body=OLD.digest) OR EXISTS(SELECT 1 FROM records WHERE body=OLD.digest) OR EXISTS(SELECT 1 FROM events WHERE body=OLD.digest) OR EXISTS(SELECT 1 FROM operations WHERE receipt=OLD.digest) BEGIN SELECT RAISE(ABORT,'retained object is immutable'); END;
                \\CREATE TABLE tasks(id BLOB PRIMARY KEY CHECK(length(id)=16), revision INTEGER NOT NULL, terminal INTEGER NOT NULL CHECK(terminal IN(0,1)), body BLOB NOT NULL REFERENCES objects(digest)) WITHOUT ROWID;
                \\CREATE TABLE operations(id TEXT PRIMARY KEY, request BLOB NOT NULL CHECK(length(request)=32), receipt BLOB NOT NULL REFERENCES objects(digest), task BLOB NOT NULL CHECK(length(task)=16)) WITHOUT ROWID;
                \\CREATE INDEX operation_tasks ON operations(task,id);
                \\CREATE TABLE records(kind TEXT NOT NULL, id BLOB NOT NULL, task BLOB NOT NULL REFERENCES tasks(id), body BLOB NOT NULL REFERENCES objects(digest), PRIMARY KEY(kind,id)) WITHOUT ROWID;
                \\CREATE TABLE events(task BLOB NOT NULL REFERENCES tasks(id), seq INTEGER NOT NULL, revision INTEGER NOT NULL, body BLOB NOT NULL REFERENCES objects(digest), PRIMARY KEY(task,seq)) WITHOUT ROWID;
                \\CREATE TABLE placement_decisions(transfer BLOB PRIMARY KEY CHECK(length(transfer)=32), body BLOB NOT NULL) WITHOUT ROWID;
                \\CREATE TABLE local_admissions(task BLOB PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE) WITHOUT ROWID;
            );
            try database.run("INSERT INTO meta VALUES(1,?, ?,0,?,?)", &.{ .{ .integer = format }, .{ .blob = &namespace }, .{ .blob = &@as(Digest, @splat(0)) }, .{ .blob = &namespace } });
            try database.exec("COMMIT;");
        }
        var query = try database.prepare("SELECT format,namespace,generation,parent,head FROM meta WHERE singleton=1", &.{});
        defer query.deinit();
        if (try query.step() != .row) return error.CorruptState;
        if (try query.integer(0) != format) return error.UnsupportedStateFormat;
        if (!std.mem.eql(u8, try query.bytes(1), &namespace)) return error.CorruptState;
        const generation = try query.integer(2);
        if (generation < 0) return error.CorruptState;
        const parent = try query.bytes(3);
        const head = try query.bytes(4);
        if (parent.len != 32 or head.len != 32) return error.CorruptState;
        var store: Store = .{ .allocator = a, .database = database, .head = .{ .generation = @intCast(generation), .parent = parent[0..32].*, .digest = head[0..32].* } };
        store.data_version = try store.scalar("PRAGMA data_version");
        return store;
    }

    /// Supported replacement/corruption hooks must call this before mutation.
    /// Invalidating custody never grants validation authority for the new epoch.
    pub fn invalidateIntegrity(self: *Store) void {
        self.context_cache.deinit(self.allocator);
        self.retention_epoch = null;
        self.retention_image = null;
        self.sealed_generation = null;
        self.integrity_epoch = std.math.add(u64, self.integrity_epoch, 1) catch {
            self.fenced = true;
            return;
        };
    }
    pub fn fence(self: *Store) void {
        if (!self.fenced) self.invalidateIntegrity();
        self.fenced = true;
    }
    fn corrupt(self: *Store) error{CorruptState} {
        self.fence();
        return error.CorruptState;
    }
    pub fn checkIntegrity(self: *Store) !void {
        if (self.fenced) return error.StorageUnavailable;
        errdefer self.fence();
        if (try self.scalar("PRAGMA data_version") != self.data_version) return error.CorruptState;
    }
    /// Namespace calls this only after verifying or durably publishing its seal.
    /// SQL commit alone cannot make a new head available for validation reuse.
    pub fn confirmSealed(self: *Store, head: Head) !void {
        try self.checkIntegrity();
        if (self.transaction or !std.meta.eql(head, self.head)) return error.InvalidState;
        self.sealed_generation = head.generation;
    }
    /// Publication custody only; callers must separately validate the complete
    /// dependency closure before retaining any semantic validation facts.
    pub fn publicationEpoch(self: *Store) !u64 {
        try self.checkIntegrity();
        if (self.transaction or self.sealed_generation != self.head.generation) return error.InvalidState;
        return self.integrity_epoch;
    }
    /// Reconstruct dependency closure under one database snapshot. Reopening,
    /// import and explicit audit never trust serialized retention metadata.
    pub fn auditRetention(self: *Store, handlers: @import("registry.zig").Registry, image: Digest) !@import("retention.zig").Statistics {
        const opened = !self.transaction;
        if (opened) try self.begin();
        defer if (opened) self.rollback();
        const statistics = @import("retention.zig").verify(self, handlers) catch |err| {
            if (err != error.OutOfMemory and err != error.Capacity) self.fence();
            return err;
        };
        if (opened and self.sealed_generation == self.head.generation) {
            self.retention_epoch = self.integrity_epoch;
            self.retention_image = image;
        }
        return statistics;
    }

    pub fn deinit(self: *Store) void {
        self.context_cache.deinit(self.allocator);
    }

    /// Run a pure projection under one read snapshot, releasing it before the
    /// caller can publish or dispatch environmental work. Import may borrow its
    /// existing transaction, but projection code still cannot write through the
    /// Store. A sealed view reconstructs missing cold retention facts through
    /// the registered codecs before projection. Transaction-scoped import/audit
    /// views still validate fully and cannot create reusable semantic facts.
    /// Results belong to the caller's arena; the view cannot escape this call.
    pub fn project(self: *Store, comptime Result: type, a: std.mem.Allocator, handlers: @import("registry.zig").Registry, binding: @import("registry.zig").ProjectionBinding, operation: anytype) anyerror!Result {
        if (!self.transaction and self.sealed_generation == self.head.generation and
            (self.retention_epoch != self.integrity_epoch or self.retention_image == null or
                !std.meta.eql(self.retention_image.?, binding.application)))
            _ = try self.auditRetention(handlers, binding.application);
        var scope = try ProjectionScope.open(self, binding);
        const result = operation.run(@as(@import("registry.zig").ProjectionContext, .{
            .allocator = a,
            .task = binding.task,
            .tenant = binding.tenant,
            .profile = binding.profile,
            .application = binding.application,
            .resources = binding.resources,
            .controller = binding.controller,
            .trial = binding.trial,
            .execution = binding.execution,
            .objects = .{ .source = &scope, .read_object = ProjectionScope.read, .native_scope = &scope },
        }));
        // Check and release even when the pure adapter failed. A malformed
        // proposed descendant does not invalidate intact committed ancestors.
        try scope.finish();
        return result;
    }

    const ProjectionScope = struct {
        store: *Store,
        epoch: u64,
        opened: bool,
        binding: @import("registry.zig").ProjectionBinding,

        fn open(self: *Store, binding: @import("registry.zig").ProjectionBinding) !ProjectionScope {
            if (self.projecting) return error.Busy;
            try self.checkIntegrity();
            const opened = !self.transaction;
            if (opened) try self.database.exec("BEGIN;");
            errdefer if (opened) self.database.exec("ROLLBACK;") catch self.fence();
            // BEGIN alone is deferred. Reading the head establishes the actual
            // snapshot/shared lock before the external-change check.
            if (try self.scalar("SELECT generation FROM meta WHERE singleton=1") != self.head.generation) return self.corrupt();
            try self.checkIntegrity();
            self.projecting = true;
            return .{ .store = self, .epoch = self.integrity_epoch, .opened = opened, .binding = binding };
        }

        fn read(source: *anyopaque, a: std.mem.Allocator, ref: state.Reference, limit: usize) ![]u8 {
            const scope: *ProjectionScope = @ptrCast(@alignCast(source));
            if (!scope.store.projecting or scope.store.fenced or scope.epoch != scope.store.integrity_epoch) return error.InvalidState;
            const bytes = try scope.store.object(a, ref, limit);
            scope.store.context_cache.object_reads +|= 1;
            scope.store.context_cache.object_bytes +|= bytes.len;
            return bytes;
        }

        fn finish(self: *ProjectionScope) !void {
            const owner = self.store;
            defer owner.projecting = false;
            if (self.opened) owner.database.exec("ROLLBACK;") catch |err| {
                owner.fence();
                return err;
            };
            try owner.checkIntegrity();
            if (self.epoch != owner.integrity_epoch) return error.InvalidState;
        }
    };

    /// Called only by ReadView and the pure context validator. The scoped view
    /// selects custody; adapters cannot populate the validation cache.
    pub fn validateContext(comptime P: type, source: ?*anyopaque, ctx: @import("registry.zig").ProjectionContext, reference: anytype, audience: []const u8, catalog: P.AdaptiveCatalog, reader: *@import("adaptive_history.zig").History(P).Reader) !*@import("adaptive_context.zig").Projection(P).ValidatedContext {
        var owner: ?*Store = null;
        if (source) |pointer| {
            const scope: *ProjectionScope = @ptrCast(@alignCast(pointer));
            const store = scope.store;
            if (!store.projecting or store.fenced or scope.epoch != store.integrity_epoch) return error.InvalidState;
            if (ctx.objects.source != pointer or ctx.objects.read_object != ProjectionScope.read or
                reader.ctx.objects.source != pointer or reader.ctx.objects.read_object != ProjectionScope.read) return error.InvalidContext;
            if (!std.meta.eql(ctx.task, scope.binding.task) or !std.mem.eql(u8, ctx.tenant, scope.binding.tenant) or
                !std.mem.eql(u8, ctx.profile, scope.binding.profile) or ctx.application == null or
                !std.meta.eql(ctx.application.?, scope.binding.application)) return error.InvalidContext;
            if (!std.meta.eql(ctx.execution, scope.binding.execution) or !std.meta.eql(ctx.controller, scope.binding.controller) or !std.meta.eql(ctx.trial, scope.binding.trial)) return error.InvalidContext;
            if (scope.opened and store.sealed_generation == store.head.generation and
                store.retention_epoch == scope.epoch and store.retention_image != null and
                std.meta.eql(store.retention_image.?, scope.binding.application)) owner = store;
        }
        return @import("adaptive_context.zig").Projection(P).validate(ctx, reference, audience, catalog, reader, owner);
    }

    pub fn recordHistoryRead(source: *anyopaque, bytes: usize) void {
        const scope: *ProjectionScope = @ptrCast(@alignCast(source));
        scope.store.context_cache.history_bytes +|= bytes;
    }

    /// Derive expected edges from the exact decoded codec, never from an
    /// imported edge list. A context lease requires this check for every newly
    /// admitted root and history chunk before trusting their retained closure.
    pub fn checkDependencies(self: *Store, comptime T: type, comptime Ref: type, parent: state.Reference, value: T) !void {
        var sink = struct {
            store: *Store,
            parent: state.Reference,
            pub fn add(this: *@This(), child: state.Reference) !void {
                var row = try this.store.database.prepare("SELECT parent_bytes,child_bytes FROM dependencies WHERE parent=? AND child=?", &.{ .{ .blob = &this.parent.digest }, .{ .blob = &child.digest } });
                defer row.deinit();
                if (try row.step() != .row or try row.integer(0) != this.parent.bytes or try row.integer(1) != child.bytes) return this.store.corrupt();
            }
            pub fn reply(_: *@This(), _: occurrence.Acquired) !void {
                @compileError("context dependencies cannot contain host occurrence replies");
            }
        }{ .store = self, .parent = parent };
        try state.visitReferencesAs(T, Ref, value, &sink);
    }

    pub fn begin(self: *Store) !void {
        if (self.fenced) return error.StorageUnavailable;
        if (self.transaction or self.projecting) return error.Busy;
        try self.database.exec("BEGIN IMMEDIATE;");
        self.transaction = true;
        errdefer self.rollback();
        // Acquire the writer lock before checking. Another connection cannot
        // slip a change between this custody check and authoritative writes.
        try self.checkIntegrity();
    }
    pub fn rollback(self: *Store) void {
        if (!self.transaction) return;
        // A borrowed import snapshot must not silently disappear beneath a
        // projection. Ordinary rollback after project returns preserves custody.
        if (self.projecting) self.fence();
        self.database.exec("ROLLBACK;") catch {
            self.fence();
        };
        self.transaction = false;
    }
    fn writing(self: *Store) !void {
        if (self.projecting) return error.Busy;
        if (self.fenced or !self.transaction) return error.InvalidState;
    }

    /// The namespace must publish this returned head to its independently
    /// checked seal before acknowledging anything or dispatching an effect.
    pub fn commit(self: *Store, transition: []const u8) !Head {
        try self.writing();
        if (self.head.generation == std.math.maxInt(i64)) return error.Capacity;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("agent.native.store.v1\x00");
        hash.update(&self.head.digest);
        var generation: [8]u8 = undefined;
        std.mem.writeInt(u64, &generation, self.head.generation + 1, .little);
        hash.update(&generation);
        hash.update(transition);
        var next: Head = .{ .generation = self.head.generation + 1, .parent = self.head.digest, .digest = undefined };
        hash.final(&next.digest);
        try self.database.run("UPDATE meta SET generation=?,parent=?,head=? WHERE singleton=1 AND generation=? AND head=?", &.{ .{ .integer = @intCast(next.generation) }, .{ .blob = &next.parent }, .{ .blob = &next.digest }, .{ .integer = @intCast(self.head.generation) }, .{ .blob = &self.head.digest } });
        if (try self.database.changes() != 1) {
            self.fence();
            return error.CorruptState;
        }
        self.database.exec("COMMIT;") catch |err| {
            self.fence();
            return err;
        };
        self.transaction = false;
        self.head = next;
        self.sealed_generation = null;
        return next;
    }
    fn scalar(self: *Store, comptime sql: [:0]const u8) !u64 {
        var query = try self.database.prepare(sql, &.{});
        defer query.deinit();
        if (try query.step() != .row) return error.CorruptState;
        const value = try query.integer(0);
        if (value < 0) return error.CorruptState;
        return @intCast(value);
    }

    pub fn putObject(self: *Store, bytes: []const u8) !state.Reference {
        const ref: state.Reference = .{ .digest = digest(bytes), .bytes = bytes.len };
        var source = struct {
            bytes: []const u8,
            pub fn read(this: *@This(), target: []u8) !void {
                @memcpy(target, this.bytes[0..target.len]);
                this.bytes = this.bytes[target.len..];
            }
        }{ .bytes = bytes };
        try self.acquireObject(ref, &source);
        return ref;
    }

    /// Acquire an exact-size source inside the caller's unpublished transaction.
    /// Neither a new object nor a duplicate is trusted until every byte matches
    /// its digest. A failed acquisition rolls back the entire transaction.
    pub fn acquireObject(self: *Store, ref: state.Reference, source: anytype) !void {
        try self.writing();
        errdefer self.rollback();
        if (ref.bytes > (try self.database.blobLimit())) return error.Capacity;
        try self.database.run("INSERT OR IGNORE INTO objects VALUES(?,zeroblob(?))", &.{ .{ .blob = &ref.digest }, .{ .integer = @intCast(ref.bytes) } });
        const inserted = try self.database.changes() == 1;
        const location = try self.objectLocation(ref.digest, (try self.database.blobLimit()));
        if (location.bytes != ref.bytes) return error.CorruptState;
        var blob = try self.database.openBlob("objects", "body", location.row, inserted);
        var closed = false;
        defer if (!closed) blob.close() catch {};
        if (blob.length() != ref.bytes) return error.CorruptState;
        var hash: hash_abi.State = undefined;
        hash_abi.protean_native_sha256_init(&hash);
        var buffer: [64 * 1024]u8 = undefined;
        var prior: [64 * 1024]u8 = undefined;
        var offset: usize = 0;
        while (offset < ref.bytes) {
            const chunk = buffer[0..@min(buffer.len, ref.bytes - offset)];
            try source.read(chunk);
            hash_abi.protean_native_sha256_update(&hash, chunk.ptr, chunk.len);
            if (inserted) {
                try blob.write(chunk, offset);
            } else {
                try blob.read(prior[0..chunk.len], offset);
                if (!std.mem.eql(u8, prior[0..chunk.len], chunk)) return error.CorruptState;
            }
            offset += chunk.len;
        }
        closed = true;
        try blob.close();
        var observed: Digest = undefined;
        hash_abi.protean_native_sha256_final(&hash, &observed);
        if (!std.mem.eql(u8, &observed, &ref.digest)) return error.InvalidObject;
    }
    pub fn object(self: *Store, a: std.mem.Allocator, ref: state.Reference, limit: ?usize) ![]u8 {
        if (limit != null and ref.bytes > limit.?) return error.Capacity;
        const bytes = try self.acquiredObject(a, ref.digest, limit);
        errdefer a.free(bytes);
        if (bytes.len != ref.bytes) return error.CorruptState;
        return bytes;
    }
    /// Check the complete immutable object, retaining only the requested range.
    /// An empty destination verifies integrity without materializing the object.
    pub fn objectRange(self: *Store, ref: state.Reference, start: usize, destination: []u8) !void {
        if (ref.bytes > (try self.database.blobLimit())) return error.Capacity;
        if (start > ref.bytes or destination.len > ref.bytes - start) return error.InvalidParams;
        var sink = struct {
            start: usize,
            destination: []u8,
            offset: usize = 0,
            pub fn write(this: *@This(), chunk: []const u8) !void {
                const first = @max(this.offset, this.start);
                const last = @min(this.offset + chunk.len, this.start + this.destination.len);
                if (first < last) @memcpy(this.destination[first - this.start .. last - this.start], chunk[first - this.offset .. last - this.offset]);
                this.offset += chunk.len;
            }
        }{ .start = start, .destination = destination };
        try self.writeObject(ref, &sink);
    }

    /// Sink bytes remain unpublished until this complete integrity check returns.
    pub fn writeObject(self: *Store, ref: state.Reference, sink: anytype) !void {
        if (ref.bytes > (try self.database.blobLimit())) return error.Capacity;
        const location = try self.objectLocation(ref.digest, (try self.database.blobLimit()));
        if (location.bytes != ref.bytes) return error.CorruptState;
        var blob = try self.database.openBlob("objects", "body", location.row, false);
        var closed = false;
        defer if (!closed) blob.close() catch {};
        if (blob.length() != ref.bytes) return error.CorruptState;
        var hash: hash_abi.State = undefined;
        hash_abi.protean_native_sha256_init(&hash);
        var buffer: [64 * 1024]u8 = undefined;
        var offset: usize = 0;
        while (offset < location.bytes) {
            const chunk = buffer[0..@min(buffer.len, location.bytes - offset)];
            try blob.read(chunk, offset);
            hash_abi.protean_native_sha256_update(&hash, chunk.ptr, chunk.len);
            try sink.write(chunk);
            offset += chunk.len;
        }
        closed = true;
        try blob.close();
        var observed: Digest = undefined;
        hash_abi.protean_native_sha256_final(&hash, &observed);
        if (!std.mem.eql(u8, &observed, &ref.digest)) return self.corrupt();
    }
    /// Private occurrence lookup. Public artifact reads require a separate
    /// task/audience-bound artifact record, never a bare content digest.
    pub fn acquiredObject(self: *Store, a: std.mem.Allocator, id: Digest, limit: ?usize) ![]u8 {
        const location = try self.objectLocation(id, if (limit) |maximum| @min(maximum, try self.database.blobLimit()) else try self.database.blobLimit());
        const bytes = try a.alloc(u8, location.bytes);
        errdefer a.free(bytes);
        var blob = try self.database.openBlob("objects", "body", location.row, false);
        var closed = false;
        defer if (!closed) blob.close() catch {};
        if (blob.length() != bytes.len) return error.CorruptState;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const chunk = bytes[offset..@min(bytes.len, offset + 64 * 1024)];
            try blob.read(chunk, offset);
            offset += chunk.len;
        }
        closed = true;
        try blob.close();
        if (!std.mem.eql(u8, &digest(bytes), &id)) return self.corrupt();
        return bytes;
    }
    fn objectLocation(self: *Store, id: Digest, limit: ?usize) !struct { row: i64, bytes: usize } {
        var query = try self.database.prepare("SELECT rowid,length(body) FROM objects WHERE digest=?", &.{.{ .blob = &id }});
        defer query.deinit();
        if (try query.step() != .row) return error.MissingArtifact;
        const length = try query.integer(1);
        if (length < 0 or (limit != null and length > limit.?)) return error.Capacity;
        return .{ .row = try query.integer(0), .bytes = @intCast(length) };
    }
    fn recordObject(self: *Store, a: std.mem.Allocator, reference: []const u8) ![]u8 {
        if (reference.len != 32) return error.CorruptState;
        return self.acquiredObject(a, reference[0..32].*, null) catch |err| switch (err) {
            error.MissingArtifact => error.CorruptState,
            else => err,
        };
    }

    /// Idempotency precedes mutable task/question checks. The caller hashes the
    /// admitted typed operation (including method), excluding JSON-RPC id.
    pub fn receipt(self: *Store, a: std.mem.Allocator, id: []const u8, request: Digest) !?[]u8 {
        var query = try self.database.prepare("SELECT request,receipt,task FROM operations WHERE id=?", &.{.{ .text = id }});
        defer query.deinit();
        if (try query.step() == .done) return null;
        if (!std.mem.eql(u8, try query.bytes(0), &request)) return error.OperationConflict;
        return try self.checkedReceipt(a, try query.bytes(1), try query.bytes(0), try query.bytes(2));
    }
    pub fn savedReceipt(self: *Store, a: std.mem.Allocator, id: []const u8) !?[]u8 {
        var query = try self.database.prepare("SELECT request,receipt,task FROM operations WHERE id=?", &.{.{ .text = id }});
        defer query.deinit();
        if (try query.step() == .done) return null;
        return try self.checkedReceipt(a, try query.bytes(1), try query.bytes(0), try query.bytes(2));
    }
    fn checkedReceipt(self: *Store, a: std.mem.Allocator, reference: []const u8, request: []const u8, task: []const u8) ![]u8 {
        const bytes = try self.recordObject(a, reference);
        errdefer a.free(bytes);
        var decoded = try contracts.decodeOwned(state.Receipt, a, bytes);
        defer decoded.deinit();
        if (!std.mem.eql(u8, &decoded.value.task, task) or !std.mem.eql(u8, &decoded.value.request_digest, request)) return error.CorruptState;
        return bytes;
    }
    pub fn putReceipt(self: *Store, id: []const u8, request: Digest, bytes: []const u8) !void {
        try self.writing();
        errdefer self.rollback();
        if (id.len == 0 or id.len > 128) return error.Capacity;
        var decoded = try contracts.decodeOwned(state.Receipt, self.allocator, bytes);
        defer decoded.deinit();
        if (!std.mem.eql(u8, &decoded.value.request_digest, &request)) return error.CorruptState;
        const ref = try self.putObject(bytes);
        try self.retainValue(state.Receipt, ref, decoded.value);
        try self.database.run("INSERT INTO operations VALUES(?,?,?,?)", &.{ .{ .text = id }, .{ .blob = &request }, .{ .blob = &ref.digest }, .{ .blob = &decoded.value.task } });
    }

    /// The selected registry entry supplies a pure, compiled codec. Adapters
    /// receive no Store capability, and Projection carries no asserted edges.
    pub fn retainProjection(self: *Store, decode: @import("registry.zig").DependencyDecoder, objects: []const []const u8) !void {
        try self.writing();
        errdefer self.rollback();
        const dependencies = try decode(self.allocator, objects);
        defer self.allocator.free(dependencies);
        var parents: std.AutoHashMap(Digest, u64) = .init(self.allocator);
        defer parents.deinit();
        for (objects) |bytes| try parents.put(digest(bytes), bytes.len);
        for (dependencies) |edge| {
            if ((parents.get(edge.parent.digest) orelse return error.InvalidProjection) != edge.parent.bytes) return error.InvalidProjection;
            try self.retainReference(edge.parent, edge.child);
        }
    }

    fn retainReference(self: *Store, parent: state.Reference, child: state.Reference) !void {
        try self.writing();
        if (parent.bytes > std.math.maxInt(i64) or child.bytes > std.math.maxInt(i64)) return error.Capacity;
        try self.database.run("INSERT OR IGNORE INTO dependencies VALUES(?,?,?,?)", &.{ .{ .blob = &parent.digest }, .{ .integer = @intCast(parent.bytes) }, .{ .blob = &child.digest }, .{ .integer = @intCast(child.bytes) } });
    }
    fn retainValue(self: *Store, comptime T: type, parent: state.Reference, value: T) !void {
        try self.retainValueDirect(T, parent, value);
        if (T == state.Reconciliation or T == state.Receipt or T == state.Event) {
            var history = struct {
                store: *Store,
                pub fn typed(this: *@This(), comptime V: type, ref: state.Reference, item: V) !void {
                    try this.store.retainValueDirect(V, ref, item);
                }
            }{ .store = self };
            if (T == state.Reconciliation) try state.visitReconciliationHistory(self.allocator, self, value, &history) else if (T == state.Event) try state.visitWorkspaceCommand(self.allocator, self, value, &history) else try state.visitWorkspaceReceipt(self.allocator, self, value, &history);
        }
    }
    fn retainValueDirect(self: *Store, comptime T: type, parent: state.Reference, value: T) !void {
        var sink = struct {
            store: *Store,
            parent: state.Reference,
            pub fn add(this: *@This(), child: state.Reference) !void {
                try this.store.retainReference(this.parent, child);
            }
            pub fn reply(this: *@This(), acquired: occurrence.Acquired) !void {
                try this.add(try this.store.objectReference(acquired.reply, null));
            }
        }{ .store = self, .parent = parent };
        try state.visitReferences(T, value, &sink);
    }
    fn retainEncoded(self: *Store, comptime T: type, parent: state.Reference) !void {
        const bytes = try self.object(self.allocator, parent, null);
        defer self.allocator.free(bytes);
        var decoded = try contracts.decodeOwned(T, self.allocator, bytes);
        defer decoded.deinit();
        try self.retainValue(T, parent, decoded.value);
    }

    pub fn putTask(self: *Store, task: state.Task, previous: ?u64) !void {
        try self.writing();
        errdefer self.rollback();
        if (task.revision > std.math.maxInt(i64)) return error.Capacity;
        const body = try contracts.encodeOwned(state.Task, self.allocator, task);
        defer self.allocator.free(body);
        const ref = try self.putObject(body);
        try self.retainValue(state.Task, ref, task);
        if (previous) |revision| {
            if (revision >= std.math.maxInt(i64) or task.revision != revision + 1) return error.StaleRevision;
            try self.database.run("UPDATE tasks SET revision=?,terminal=?,body=? WHERE id=? AND revision=?", &.{ .{ .integer = @intCast(task.revision) }, .{ .integer = @intFromBool(task.terminal()) }, .{ .blob = &ref.digest }, .{ .blob = &task.id }, .{ .integer = @intCast(revision) } });
            if (try self.database.changes() != 1) return error.StaleRevision;
        } else {
            if (task.revision != 1) return error.StaleRevision;
            try self.database.run("INSERT INTO tasks VALUES(?,?,?,?)", &.{ .{ .blob = &task.id }, .{ .integer = 1 }, .{ .integer = @intFromBool(task.terminal()) }, .{ .blob = &ref.digest } });
            // This namespace-local admission is deliberately absent from
            // archives. Import restores task data through its separate owner.
            try self.database.run("INSERT INTO local_admissions VALUES(?)", &.{.{ .blob = &task.id }});
        }
    }
    pub fn locallyAdmitted(self: *Store, task_id: state.TaskId) !bool {
        var query = try self.database.prepare("SELECT 1 FROM local_admissions WHERE task=?", &.{.{ .blob = &task_id }});
        defer query.deinit();
        return try query.step() == .row;
    }
    pub fn taskBytes(self: *Store, a: std.mem.Allocator, id: state.TaskId) ![]u8 {
        var query = try self.database.prepare("SELECT body,revision,terminal FROM tasks WHERE id=?", &.{.{ .blob = &id }});
        defer query.deinit();
        if (try query.step() != .row) return error.UnknownTask;
        const bytes = try self.recordObject(a, try query.bytes(0));
        errdefer a.free(bytes);
        var decoded = try contracts.decodeOwned(state.Task, a, bytes);
        defer decoded.deinit();
        if (!std.mem.eql(u8, &decoded.value.id, &id) or decoded.value.revision != try query.integer(1) or @intFromBool(decoded.value.terminal()) != try query.integer(2)) return error.CorruptState;
        return bytes;
    }
    pub fn putRecord(self: *Store, comptime T: type, comptime kind: []const u8, id: Digest, task: state.TaskId, value: T) !void {
        if (T != Record(kind)) @compileError("native record type/kind mismatch");
        if (comptime std.mem.eql(u8, kind, "placement_action")) @compileError("placement observations are immutable");
        if (comptime std.mem.eql(u8, kind, "placement_succession")) @compileError("placement succession proofs are immutable");
        if (comptime std.mem.eql(u8, kind, "workspace_runtime")) @compileError("immutable runtime records are created once");
        if (comptime std.mem.eql(u8, kind, "artifact") or std.mem.eql(u8, kind, "attempt") or std.mem.eql(u8, kind, "origin") or std.mem.eql(u8, kind, "workspace_program") or std.mem.eql(u8, kind, "workspace_value") or std.mem.eql(u8, kind, "workspace_view") or std.mem.eql(u8, kind, "workspace_port") or std.mem.eql(u8, kind, "workspace_port_reply") or std.mem.eql(u8, kind, "execution_route") or std.mem.eql(u8, kind, "workspace_wait") or std.mem.eql(u8, kind, "workspace_delegation") or std.mem.eql(u8, kind, "workspace_reply")) @compileError("immutable native records are created once");
        try self.writing();
        errdefer self.rollback();
        const body = try contracts.encodeOwned(T, self.allocator, value);
        defer self.allocator.free(body);
        const ref = try self.putObject(body);
        try self.retainValue(T, ref, value);
        try self.database.run("UPDATE records SET body=? WHERE kind=? AND id=? AND task=?", &.{ .{ .blob = &ref.digest }, .{ .text = kind }, .{ .blob = &id }, .{ .blob = &task } });
        if (try self.database.changes() != 1) return error.CorruptState;
    }
    pub fn createRecord(self: *Store, comptime T: type, comptime kind: []const u8, id: Digest, task: state.TaskId, value: T) !void {
        if (T != Record(kind)) @compileError("native record type/kind mismatch");
        try self.writing();
        errdefer self.rollback();
        const body = try contracts.encodeOwned(T, self.allocator, value);
        defer self.allocator.free(body);
        const ref = try self.putObject(body);
        try self.retainValue(T, ref, value);
        try self.database.run("INSERT INTO records VALUES(?,?,?,?)", &.{ .{ .text = kind }, .{ .blob = &id }, .{ .blob = &task }, .{ .blob = &ref.digest } });
    }
    pub fn recordBytes(self: *Store, a: std.mem.Allocator, comptime kind: []const u8, id: Digest, task: state.TaskId) !?[]u8 {
        var query = try self.database.prepare("SELECT body FROM records WHERE kind=? AND id=? AND task=?", &.{ .{ .text = kind }, .{ .blob = &id }, .{ .blob = &task } });
        defer query.deinit();
        if (try query.step() != .row) return null;
        return try self.recordObject(a, try query.bytes(0));
    }
    pub fn taskIds(self: *Store, a: std.mem.Allocator, nonterminal: bool) ![]state.TaskId {
        var query = try self.database.prepare("SELECT id FROM tasks WHERE (?=0 OR terminal=0) ORDER BY id", &.{.{ .integer = @intFromBool(nonterminal) }});
        defer query.deinit();
        var ids: std.ArrayList(state.TaskId) = .empty;
        errdefer ids.deinit(a);
        while (try query.step() == .row) {
            const bytes = try query.bytes(0);
            if (bytes.len != 16) return error.CorruptState;
            try ids.append(a, bytes[0..16].*);
        }
        return ids.toOwnedSlice(a);
    }

    pub fn capabilityAttempts(self: *Store, task: state.TaskId, capability: []const u8) !u64 {
        var query = try self.database.prepare("SELECT body FROM records WHERE kind='attempt' AND task=?", &.{.{ .blob = &task }});
        defer query.deinit();
        var count: u64 = 0;
        while (try query.step() == .row) {
            const bytes = try self.recordObject(self.allocator, try query.bytes(0));
            defer self.allocator.free(bytes);
            var attempt = try contracts.decodeOwned(state.Attempt, self.allocator, bytes);
            defer attempt.deinit();
            if (!std.mem.eql(u8, &task, &attempt.value.task)) return error.CorruptState;
            if (std.mem.eql(u8, capability, attempt.value.capability.bytes)) count = try std.math.add(u64, count, 1);
        }
        return count;
    }

    pub const ProjectionOwner = struct { attempt: Digest, object: state.Reference };
    /// Return provenance candidates, not permission. The capability owner must
    /// authorize disclosure before any returned object is read publicly.
    pub fn projectionOwners(self: *Store, a: std.mem.Allocator, task: state.TaskId, object_id: Digest) ![]ProjectionOwner {
        var query = try self.database.prepare("SELECT id,body FROM records WHERE kind='capture' AND task=?", &.{.{ .blob = &task }});
        defer query.deinit();
        var result: std.ArrayList(ProjectionOwner) = .empty;
        errdefer result.deinit(a);
        while (try query.step() == .row) {
            const bytes = try self.recordObject(self.allocator, try query.bytes(1));
            defer self.allocator.free(bytes);
            var capture = try contracts.decodeOwned(state.Capture, self.allocator, bytes);
            defer capture.deinit();
            if (!std.mem.eql(u8, &task, &capture.value.task) or !std.mem.eql(u8, try query.bytes(0), &capture.value.attempt)) return error.CorruptState;
            if (capture.value.disposition != .complete) continue;
            if (capture.value.projection) |projection| for (projection.objects.items) |ref| {
                if (std.mem.eql(u8, &ref.digest, &object_id)) try result.append(a, .{ .attempt = capture.value.attempt, .object = ref });
            };
        }
        return result.toOwnedSlice(a);
    }

    pub fn objectReference(self: *Store, id: Digest, limit: ?usize) !state.Reference {
        var query = try self.database.prepare("SELECT length(body) FROM objects WHERE digest=?", &.{.{ .blob = &id }});
        defer query.deinit();
        if (try query.step() != .row) return error.MissingArtifact;
        const length = try query.integer(0);
        if (length < 0 or (limit != null and length > limit.?)) return error.Capacity;
        return .{ .digest = id, .bytes = @intCast(length) };
    }
    fn indexedReference(self: *Store, bytes: []const u8) !state.Reference {
        if (bytes.len != 32) return error.CorruptState;
        return self.objectReference(bytes[0..32].*, null);
    }

    /// A task-scoped index snapshot. The archive owner validates each
    /// canonical record and computes its artifact closure before publication.
    /// Inside a transaction this observes its unpublished state. Source-local
    /// transfer snapshots are native obligations, never portable task records.
    pub fn archiveIndex(self: *Store, a: std.mem.Allocator, task_id: state.TaskId, build: state.Reference) !state.Archive {
        if (self.fenced) return error.Busy;
        const task_bytes = try self.taskBytes(a, task_id);
        defer a.free(task_bytes);
        var records: std.ArrayList(state.ArchiveRecord) = .empty;
        var events: std.ArrayList(state.ArchiveEvent) = .empty;
        var operations: std.ArrayList(state.ArchiveOperation) = .empty;
        // The caller supplies an arena. No borrowed SQLite column escapes.
        {
            var query = try self.database.prepare("SELECT kind,id,body FROM records WHERE task=? AND kind!='placement_snapshot' ORDER BY kind,id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const kind = std.meta.stringToEnum(state.RecordKind, try query.bytes(0)) orelse return error.NonPortable;
                const id = try query.bytes(1);
                if (id.len != 32) return error.CorruptState;
                try records.append(a, .{ .kind = kind, .id = id[0..32].*, .body = try self.indexedReference(try query.bytes(2)) });
            }
        }
        {
            var query = try self.database.prepare("SELECT seq,revision,body FROM events WHERE task=? ORDER BY seq", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const seq = try query.integer(0);
                const revision = try query.integer(1);
                if (seq <= 0 or revision <= 0) return error.CorruptState;
                try events.append(a, .{ .seq = @intCast(seq), .revision = @intCast(revision), .body = try self.indexedReference(try query.bytes(2)) });
            }
        }
        {
            var query = try self.database.prepare("SELECT id,request,receipt FROM operations WHERE task=? ORDER BY id", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                const key = try query.bytes(0);
                const request = try query.bytes(1);
                if (key.len == 0 or key.len > 128 or request.len != 32) return error.CorruptState;
                try operations.append(a, .{ .key = .{ .bytes = try a.dupe(u8, key) }, .request = request[0..32].*, .body = try self.indexedReference(try query.bytes(2)) });
            }
        }
        return .{
            .version = 2,
            .classification = .private,
            .profile = .offline_copy,
            .task = .{ .digest = digest(task_bytes), .bytes = task_bytes.len },
            .build = build,
            .schemas = .{ .items = &.{} },
            .records = .{ .items = try records.toOwnedSlice(a) },
            .events = .{ .items = try events.toOwnedSlice(a) },
            .operations = .{ .items = try operations.toOwnedSlice(a) },
            .objects = .{ .items = &.{} },
        };
    }

    /// Import is confined to an empty task namespace transaction. It preserves the
    /// archived task ID and history; grants and resume remain caller-owned.
    pub fn restoreArchiveIndex(self: *Store, a: std.mem.Allocator, archive: state.Archive, task: state.Task) !void {
        try self.writing();
        errdefer self.rollback();
        self.invalidateIntegrity();
        if (task.revision == 0 or task.revision > std.math.maxInt(i64) or try self.scalar("SELECT count(*) FROM tasks") != 0) return error.InvalidState;
        const bytes = try contracts.encodeOwned(state.Task, a, task);
        defer a.free(bytes);
        const body = try self.putObject(bytes);
        try self.retainValue(state.Task, body, task);
        try self.database.run("INSERT INTO tasks VALUES(?,?,?,?)", &.{ .{ .blob = &task.id }, .{ .integer = @intCast(task.revision) }, .{ .integer = @intFromBool(task.terminal()) }, .{ .blob = &body.digest } });
        for (archive.records.items) |row| {
            inline for (@typeInfo(state.RecordKind).@"enum".field_names) |kind| {
                if (row.kind == @field(state.RecordKind, kind)) try self.retainEncoded(Record(kind), row.body);
            }
            try self.database.run("INSERT INTO records VALUES(?,?,?,?)", &.{ .{ .text = @tagName(row.kind) }, .{ .blob = &row.id }, .{ .blob = &task.id }, .{ .blob = &row.body.digest } });
        }
        for (archive.events.items) |row| {
            if (row.seq == 0 or row.seq > std.math.maxInt(i64) or row.revision == 0 or row.revision > task.revision) return error.CorruptState;
            try self.retainEncoded(state.Event, row.body);
            try self.database.run("INSERT INTO events VALUES(?,?,?,?)", &.{ .{ .blob = &task.id }, .{ .integer = @intCast(row.seq) }, .{ .integer = @intCast(row.revision) }, .{ .blob = &row.body.digest } });
        }
        for (archive.operations.items) |row| {
            const receipt_bytes = try self.object(a, row.body, null);
            defer a.free(receipt_bytes);
            try self.putReceipt(row.key.bytes, row.request, receipt_bytes);
        }
    }
    pub fn putEvent(self: *Store, event: state.Event) !void {
        try self.writing();
        errdefer self.rollback();
        if (event.seq == 0 or event.seq > std.math.maxInt(i64) or event.revision > std.math.maxInt(i64)) return error.Capacity;
        try @import("schemas.zig").validateEventData(self.allocator, event.kind, event.data.bytes);
        const body = try contracts.encodeOwned(state.Event, self.allocator, event);
        defer self.allocator.free(body);
        const ref = try self.putObject(body);
        try self.retainValue(state.Event, ref, event);
        try self.database.run("INSERT INTO events VALUES(?,?,?,?)", &.{ .{ .blob = &event.task }, .{ .integer = @intCast(event.seq) }, .{ .integer = @intCast(event.revision) }, .{ .blob = &ref.digest } });
    }
    pub fn eventsAfter(self: *Store, a: std.mem.Allocator, task: state.TaskId, after: u64, limit: u32) ![][]u8 {
        if (after > std.math.maxInt(i64) or limit == 0 or limit > 128) return error.InvalidParams;
        var query = try self.database.prepare("SELECT e.body,o.body FROM events e LEFT JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq>? ORDER BY e.seq LIMIT ?", &.{ .{ .blob = &task }, .{ .integer = @intCast(after) }, .{ .integer = limit } });
        defer query.deinit();
        var records: std.ArrayList([]u8) = .empty;
        errdefer {
            for (records.items) |bytes| a.free(bytes);
            records.deinit(a);
        }
        var total: usize = 0;
        while (try query.step() == .row) {
            const reference = try query.bytes(0);
            const bytes = try query.bytes(1);
            if (reference.len != 32 or !std.mem.eql(u8, &digest(bytes), reference)) return error.CorruptState;
            if (total + bytes.len > 384 * 1024) break;
            const copied = try a.dupe(u8, bytes);
            errdefer a.free(copied);
            try records.append(a, copied);
            total += bytes.len;
        }
        return records.toOwnedSlice(a);
    }
};

test "objects and immutable admission receipts commit together or disappear together" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    try std.testing.expectError(error.AlreadyOpen, sqlite.Database.open(a, ":memory:", true));
    var store = try Store.init(a, db, true, @splat(7));
    const receipt_bytes = try contracts.encodeOwned(state.Receipt, a, .{ .id = @splat(1), .client_operation_id = .{ .bytes = "request-1" }, .method = .submit, .request_digest = digest("submit/input"), .task = @splat(2), .revision = 1, .disposition = .accepted });
    defer a.free(receipt_bytes);
    try store.begin();
    const ref = try store.putObject("acquired reply\x00\xff\x01");
    try store.putReceipt("request-1", digest("submit/input"), receipt_bytes);
    store.rollback();
    try std.testing.expect((try store.receipt(a, "request-1", digest("submit/input"))) == null);
    try std.testing.expectError(error.MissingArtifact, store.object(a, ref, 1024));
    try store.begin();
    _ = try store.putObject("acquired reply\x00\xff\x01");
    try store.putReceipt("request-1", digest("submit/input"), receipt_bytes);
    const head = try store.commit("admit/task-1");
    try std.testing.expectEqual(1, head.generation);
    const saved = (try store.receipt(a, "request-1", digest("submit/input"))).?;
    defer a.free(saved);
    try std.testing.expectEqualSlices(u8, receipt_bytes, saved);
    try std.testing.expectError(error.OperationConflict, store.receipt(a, "request-1", digest("submit/other-input")));
    const bytes = try store.object(a, ref, 1024);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("acquired reply\x00\xff\x01", bytes);
    const reopened = try Store.init(a, db, false, @splat(7));
    try std.testing.expectEqualDeep(head, reopened.head);
    try std.testing.expectError(error.CorruptState, Store.init(a, db, false, @splat(8)));
    store.invalidateIntegrity();
    try db.run("UPDATE operations SET task=? WHERE id='request-1'", &.{.{ .blob = &@as(state.TaskId, @splat(3)) }});
    try std.testing.expectError(error.CorruptState, store.receipt(a, "request-1", digest("submit/input")));
    try db.run("UPDATE operations SET task=? WHERE id='request-1'", &.{.{ .blob = &@as(state.TaskId, @splat(2)) }});
    try std.testing.expectError(error.Constraint, db.run("UPDATE objects SET body=? WHERE digest=?", &.{ .{ .blob = "changed receipt" }, .{ .blob = &digest(receipt_bytes) } }));
    // Deliberate corruption bypasses SQL update triggers via the low-level
    // blob API, after explicitly invalidating custody above.
    const receipt_location = try store.objectLocation(digest(receipt_bytes), null);
    var corrupted = try db.openBlob("objects", "body", receipt_location.row, true);
    try corrupted.write(&.{receipt_bytes[0] ^ 1}, 0);
    try corrupted.close();
    try std.testing.expectError(error.CorruptState, store.receipt(a, "request-1", digest("submit/input")));
}

test "file-backed objects cross former allocation limits and retain chunk integrity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/objects.sqlite", .{path_buffer[0..path_length]});
    defer a.free(path);
    const fixture_bytes = 16 * 1024 * 1024 + 1;
    const bytes = try a.alloc(u8, fixture_bytes);
    defer a.free(bytes);
    @memset(bytes, 0x5a);
    const sizes = [_]usize{ 0, 8 * 1024 * 1024, 8 * 1024 * 1024 + 1, 9 * 1024 * 1024, fixture_bytes };
    var references: [sizes.len]state.Reference = undefined;
    {
        const db = try sqlite.Database.open(a, path, true);
        defer db.destroy() catch unreachable;
        defer db.close() catch unreachable;
        var store = try Store.init(a, db, true, @splat(7));
        try std.testing.expect(try db.blobLimit() > fixture_bytes);
        try std.testing.expect(try store.scalar("PRAGMA max_page_count") > 256 * 1024 * 1024 / 4096);
        for (sizes, &references) |size, *reference| {
            try store.begin();
            reference.* = try store.putObject(bytes[0..size]);
            try std.testing.expectEqualDeep(reference.*, try store.putObject(bytes[0..size]));
            _ = try store.commit("large-object");
        }
        bytes[0] ^= 1;
        try store.begin();
        const rolled_back = try store.putObject(bytes[0 .. 9 * 1024 * 1024]);
        store.rollback();
        try std.testing.expectError(error.MissingArtifact, store.object(a, rolled_back, fixture_bytes));
        bytes[0] ^= 1;
        const invalid: state.Reference = .{ .digest = digest("expected"), .bytes = 8 };
        var bad_source = struct {
            pub fn read(_: *@This(), target: []u8) !void {
                @memset(target, 0);
            }
        }{};
        try store.begin();
        try std.testing.expectError(error.InvalidObject, store.acquireObject(invalid, &bad_source));
        try std.testing.expect(!store.transaction);
        try std.testing.expectError(error.InvalidState, store.commit("must-not-publish-invalid-object"));
        try std.testing.expectError(error.MissingArtifact, store.object(a, invalid, fixture_bytes));
    }
    {
        const db = try sqlite.Database.open(a, path, false);
        defer db.destroy() catch unreachable;
        defer db.close() catch unreachable;
        var store = try Store.init(a, db, false, @splat(7));
        for (sizes, references) |size, reference| {
            const actual = try store.object(a, reference, fixture_bytes);
            defer a.free(actual);
            try std.testing.expectEqualSlices(u8, bytes[0..size], actual);
        }
        const largest = references[references.len - 1];
        var range: [127]u8 = undefined;
        try store.objectRange(largest, 65500, &range);
        try std.testing.expectEqualSlices(u8, bytes[65500..][0..range.len], &range);
        try store.objectRange(largest, largest.bytes, &.{});
        try std.testing.expectError(error.InvalidParams, store.objectRange(largest, largest.bytes, &range));
        try std.testing.expectError(error.Capacity, store.object(a, largest, fixture_bytes - 1));
        store.invalidateIntegrity();
        try store.begin();
        const location = try store.objectLocation(largest.digest, fixture_bytes);
        var blob = try db.openBlob("objects", "body", location.row, true);
        try blob.write(&.{0xff}, fixture_bytes - 1);
        try blob.close();
        _ = try store.commit("corrupt-last-byte");
        // Corruption outside the requested range must still be rejected.
        try std.testing.expectError(error.CorruptState, store.objectRange(largest, 0, &range));
        try std.testing.expectError(error.CorruptState, store.objectRange(largest, 0, &.{}));
        try std.testing.expectError(error.CorruptState, store.object(a, largest, fixture_bytes));
        try std.testing.expect(store.fenced);
        try std.testing.expectError(error.StorageUnavailable, store.begin());
        // Reopening does not make corrupt bytes valid: duplicate admission
        // still checks the entire stored object before trusting it.
        store = try Store.init(a, db, false, @splat(7));
        try store.begin();
        try std.testing.expectError(error.CorruptState, store.putObject(bytes[0..fixture_bytes]));
        store.rollback();
    }
}

test "actual SQLite storage exhaustion rolls back unpublished objects" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    // Lower SQLite's actual page limit only for this fault-injection fixture.
    try db.exec("PRAGMA max_page_count=32;");
    const bytes = try a.alloc(u8, 256 * 1024);
    defer a.free(bytes);
    @memset(bytes, 0x5a);
    try store.begin();
    try std.testing.expectError(error.Capacity, store.putObject(bytes));
    store.rollback();
    try std.testing.expectEqual(0, store.head.generation);
    try std.testing.expect(!store.transaction);
    try std.testing.expectError(error.MissingArtifact, store.object(a, .{ .digest = digest(bytes), .bytes = bytes.len }, null));
    // SQLITE_FULL may roll back automatically. The owner stays fenced until
    // reopen; recovery must not turn uncertainty into a fresh admission.
    try std.testing.expect(store.fenced);
    try std.testing.expectError(error.StorageUnavailable, store.begin());
}

test "integrity epochs survive owner appends but require each committed head to be sealed" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    try std.testing.expectError(error.InvalidState, store.publicationEpoch());
    try store.confirmSealed(store.head);
    const epoch = try store.publicationEpoch();
    for (0..3) |_| {
        try store.begin();
        try std.testing.expectError(error.InvalidState, store.publicationEpoch());
        _ = try store.putObject("unchanged immutable object");
        const head = try store.commit("owner-append");
        try std.testing.expectEqual(epoch, store.integrity_epoch);
        try std.testing.expectError(error.InvalidState, store.publicationEpoch());
        var stale = head;
        stale.generation -= 1;
        try std.testing.expectError(error.InvalidState, store.confirmSealed(stale));
        try store.confirmSealed(head);
        try std.testing.expectEqual(epoch, try store.publicationEpoch());
    }
    try store.begin();
    _ = try store.putObject("unpublished descendant");
    store.rollback();
    try std.testing.expectEqual(epoch, try store.publicationEpoch());
    store.invalidateIntegrity();
    try std.testing.expectEqual(epoch + 1, store.integrity_epoch);
    try std.testing.expectError(error.InvalidState, store.publicationEpoch());
    store.fence();
    try std.testing.expectEqual(epoch + 2, store.integrity_epoch);
    try std.testing.expectError(error.StorageUnavailable, store.begin());
}

test "projection snapshots exclude writes and release on success rejection and allocation failure" {
    const c = @import("native_c");
    const registry = @import("registry.zig");
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &buffer);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/projection.sqlite", .{buffer[0..length]}, 0);
    defer a.free(path);
    const db = try sqlite.Database.open(a, path, true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    try store.begin();
    const ref = try store.putObject("retained");
    _ = try store.commit("fixture");
    try store.confirmSealed(store.head);
    const epoch = try store.publicationEpoch();
    var peer: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(path.ptr, &peer, c.SQLITE_OPEN_READWRITE, null));
    defer std.debug.assert(c.sqlite3_close(peer) == c.SQLITE_OK);
    const binding: registry.ProjectionBinding = .{ .task = @splat(9), .tenant = "tenant", .profile = "frozen profile", .application = @splat(8) };
    const Check = struct {
        store: *Store,
        peer: ?*c.sqlite3,
        reference: state.Reference,
        failure: ?anyerror,
        pub fn run(this: @This(), ctx: registry.ProjectionContext) !void {
            try std.testing.expectEqual(@as(state.TaskId, @splat(9)), ctx.task);
            try std.testing.expectEqualStrings("tenant", ctx.tenant);
            try std.testing.expectEqualStrings("frozen profile", ctx.profile);
            try std.testing.expectEqual(@as(Digest, @splat(8)), ctx.application.?);
            const bytes = try ctx.object(this.reference, 8);
            defer ctx.allocator.free(bytes);
            try std.testing.expectEqualStrings("retained", bytes);
            try std.testing.expectError(error.Busy, this.store.begin());
            try std.testing.expectError(error.Busy, this.store.putObject("unpublished"));
            try std.testing.expectError(error.Busy, this.store.commit("forbidden"));
            try std.testing.expectEqual(c.SQLITE_BUSY, c.sqlite3_exec(this.peer, "INSERT INTO objects VALUES(zeroblob(32),x'01')", null, null, null));
            if (this.failure) |failure| return failure;
        }
    };
    for ([_]?anyerror{ null, error.InvalidContext, error.OutOfMemory }) |failure| {
        for ([_]bool{ false, true }) |inside_import| {
            if (inside_import) try store.begin();
            var handlers = try registry.Registry.init(a, &.{});
            defer handlers.deinit();
            const result = store.project(void, a, handlers, binding, Check{ .store = &store, .peer = peer, .reference = ref, .failure = failure });
            if (failure) |expected| try std.testing.expectError(expected, result) else try result;
            try std.testing.expectEqual(inside_import, store.transaction);
            try std.testing.expect(!store.projecting and !store.fenced);
            try std.testing.expectEqual(epoch, store.integrity_epoch);
            if (inside_import) {
                // A borrowed transaction survives both ordinary rejection and
                // allocator failure, and is writable again after projection.
                _ = try store.putObject("unpublished");
                store.rollback();
            } else {
                try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(peer, "BEGIN IMMEDIATE; ROLLBACK;", null, null, null));
            }
        }
    }
    try std.testing.expectEqual(epoch, try store.publicationEpoch());
    // External mutation becomes possible only after the snapshot is released;
    // it must still be rejected by the next authoritative publication fence.
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(peer, "INSERT INTO objects VALUES(zeroblob(32),x'01')", null, null, null));
    try std.testing.expectError(error.CorruptState, store.begin());
    try std.testing.expect(store.fenced and !store.transaction and !store.projecting);
}

test "projection invalidation prevents returning a usable result" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    const binding: @import("registry.zig").ProjectionBinding = .{ .task = @splat(9), .tenant = "tenant", .profile = "profile", .application = @splat(8) };
    const operation = struct {
        store: *Store,
        pub fn run(this: @This(), ctx: @import("registry.zig").ProjectionContext) !u32 {
            this.store.invalidateIntegrity();
            try std.testing.expectError(error.InvalidState, ctx.object(.{ .digest = @splat(0), .bytes = 0 }, 0));
            return 42;
        }
    }{ .store = &store };
    var handlers = try @import("registry.zig").Registry.init(a, &.{});
    defer handlers.deinit();
    try std.testing.expectError(error.InvalidState, store.project(u32, a, handlers, binding, operation));
    try std.testing.expect(!store.projecting and !store.transaction);
    // No leaked SQLite transaction, even when the operation itself succeeded.
    try store.begin();
    store.rollback();
}

test "external SQLite commits fence both validation reuse and the next write transaction" {
    const c = @import("native_c");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    for (0..2) |mode| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/external-{d}.sqlite", .{ buffer[0..length], mode }, 0);
        defer a.free(path);
        const db = try sqlite.Database.open(a, path, true);
        defer db.destroy() catch unreachable;
        defer db.close() catch unreachable;
        var store = try Store.init(a, db, true, @splat(7));
        try store.confirmSealed(store.head);
        const epoch = try store.publicationEpoch();
        // A second raw connection deliberately violates namespace ownership.
        // The production Database wrapper itself still admits one owner only.
        var peer: ?*c.sqlite3 = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(path.ptr, &peer, c.SQLITE_OPEN_READWRITE, null));
        defer std.debug.assert(c.sqlite3_close(peer) == c.SQLITE_OK);
        try store.begin();
        try std.testing.expectEqual(c.SQLITE_BUSY, c.sqlite3_exec(peer, "INSERT INTO objects VALUES(zeroblob(32),x'01')", null, null, null));
        store.rollback();
        try std.testing.expectEqual(epoch, try store.publicationEpoch());
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(peer, "INSERT INTO objects VALUES(zeroblob(32),x'01')", null, null, null));
        if (mode == 0) {
            try std.testing.expectError(error.CorruptState, store.publicationEpoch());
        } else {
            // No prior read poll: begin checks while holding the writer lock.
            try std.testing.expectError(error.CorruptState, store.begin());
        }
        try std.testing.expect(store.fenced and !store.transaction);
        try std.testing.expectEqual(epoch + 1, store.integrity_epoch);
        try std.testing.expectEqual(@as(u64, 0), store.head.generation);
        try std.testing.expectError(error.StorageUnavailable, store.begin());
    }
}

fn retentionFixtureTask(reference: state.Reference) state.Task {
    var task = std.mem.zeroes(state.Task);
    task.id = @splat(2);
    task.revision = 1;
    task.profile = reference;
    task.image = reference;
    task.input = reference;
    task.checkpoint = reference;
    task.outcome = reference;
    return task;
}

test "typed host roots retain exact dependencies including uninterpreted captures" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    try store.begin();
    const input = try store.putObject("opaque fixture input");
    const raw = try store.putObject("\xff\x00not an interpretable provider response");
    const task = retentionFixtureTask(input);
    try store.putTask(task, null);
    const capture: state.Capture = .{ .task = task.id, .occurrence = @splat(3), .attempt = @splat(4), .request = input, .response = raw, .disposition = .complete };
    try store.createRecord(state.Capture, "capture", @splat(4), task.id, capture);
    const captured_body = (try store.recordBytes(a, "capture", @splat(4), task.id)).?;
    defer a.free(captured_body);
    const captured_ref: state.Reference = .{ .digest = digest(captured_body), .bytes = captured_body.len };
    _ = try store.commit("uninterpreted-capture");
    try store.confirmSealed(store.head);
    const epoch = try store.publicationEpoch();
    try std.testing.expectEqual(@as(u64, 3), try store.scalar("SELECT count(*) FROM dependencies"));
    // Retention is private object custody, independent of interpretation or
    // public artifact-disclosure permission.
    try std.testing.expectError(error.Constraint, db.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &raw.digest }}));
    try std.testing.expectError(error.Constraint, db.run("UPDATE objects SET body=x'00' WHERE digest=?", &.{.{ .blob = &raw.digest }}));
    var wrong = raw;
    wrong.bytes += 1;
    try store.begin();
    try std.testing.expectError(error.Constraint, store.retainReference(captured_ref, wrong));
    store.rollback();
    try std.testing.expectEqual(epoch, try store.publicationEpoch());
    // A missing child aborts publication and all previously inserted edges
    // from the same attempt. An already committed ancestor stays usable.
    var missing = capture;
    missing.attempt = @splat(5);
    missing.response = .{ .digest = @splat(9), .bytes = 1 };
    const missing_body = try contracts.encodeOwned(state.Capture, a, missing);
    defer a.free(missing_body);
    try store.begin();
    try std.testing.expectError(error.Constraint, store.createRecord(state.Capture, "capture", missing.attempt, task.id, missing));
    try std.testing.expect(!store.transaction);
    try std.testing.expectEqual(@as(u64, 3), try store.scalar("SELECT count(*) FROM dependencies"));
    try std.testing.expect((try store.recordBytes(a, "capture", missing.attempt, task.id)) == null);
    try std.testing.expectError(error.MissingArtifact, store.object(a, .{ .digest = digest(missing_body), .bytes = missing_body.len }, null));
    try std.testing.expectEqual(epoch, try store.publicationEpoch());
    // Updating the capture index does not release the old audit object's
    // dependencies; both original capture bytes and the new projection remain.
    var projected = capture;
    projected.projection = .{ .reply = input, .objects = .{ .items = &.{raw} }, .output_tokens = null };
    try store.begin();
    try store.putRecord(state.Capture, "capture", capture.attempt, task.id, projected);
    _ = try store.commit("project-capture");
    try std.testing.expectEqual(@as(u64, 5), try store.scalar("SELECT count(*) FROM dependencies"));
    try std.testing.expectError(error.Constraint, db.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &captured_ref.digest }}));
    const original = try store.object(a, captured_ref, null);
    defer a.free(original);
    try std.testing.expectEqualSlices(u8, captured_body, original);
}

test "occurrence codec retains its digest-only acquired reply" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    try store.begin();
    const input = try store.putObject("request");
    const reply = try store.putObject("reply");
    const task = retentionFixtureTask(input);
    try store.putTask(task, null);
    const saved: occurrence.Occurrence = .{ .id = @splat(3), .task = task.id, .request = input.digest, .request_object = input, .state = .{ .settled_reply = .{ .attempt = @splat(4), .reply = reply.digest } } };
    try store.createRecord(occurrence.Occurrence, "occurrence", saved.id, task.id, saved);
    _ = try store.commit("acquired-reply");
    try std.testing.expectEqual(@as(u64, 3), try store.scalar("SELECT count(*) FROM dependencies"));
    try std.testing.expectError(error.Constraint, db.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &reply.digest }}));
}

test "registered projection codecs retain nominal references and roll back incomplete closure" {
    const registry = @import("registry.zig");
    const Codec = struct {
        const Ref = struct { digest: [32]u8, bytes: u64 };
        const Lookalike = struct { digest: [32]u8, bytes: u64 };
        const Body = struct {
            schema: contracts.Utf8,
            children: contracts.Vector(Ref, null),
            unrelated: Lookalike,
        };
        fn decode(a: std.mem.Allocator, objects: []const []const u8) ![]registry.Dependency {
            var references: registry.ProjectionReferences = .{ .allocator = a };
            defer references.deinit();
            for (objects) |bytes| try references.object(Body, Ref, bytes, "fixture.projection.v1");
            return references.finish();
        }
        fn forged(a: std.mem.Allocator, _: []const []const u8) ![]registry.Dependency {
            const edges = try a.alloc(registry.Dependency, 1);
            edges[0] = .{ .parent = .{ .digest = @splat(9), .bytes = 1 }, .child = .{ .digest = @splat(8), .bytes = 1 } };
            return edges;
        }
    };
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    try store.begin();
    const child = try store.putObject("retained context history");
    const nominal: Codec.Ref = .{ .digest = child.digest, .bytes = child.bytes };
    var children = [_]Codec.Ref{ nominal, nominal };
    var body: Codec.Body = .{
        .schema = .{ .bytes = "fixture.projection.v1" },
        .children = .{ .items = &children },
        .unrelated = .{ .digest = @splat(1), .bytes = 123 },
    };
    const bytes = try contracts.encodeOwned(Codec.Body, a, body);
    defer a.free(bytes);
    _ = try store.putObject(bytes);
    try store.retainProjection(Codec.decode, &.{bytes});
    _ = try store.commit("context-projection");
    try store.confirmSealed(store.head);
    const epoch = try store.publicationEpoch();
    // Duplicate nominal references coalesce; matching struct shape alone is
    // not enough to claim that the unrelated value is an object dependency.
    try std.testing.expectEqual(@as(u64, 1), try store.scalar("SELECT count(*) FROM dependencies"));
    try std.testing.expectError(error.Constraint, db.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &child.digest }}));
    try std.testing.expectError(error.Constraint, db.run("UPDATE objects SET body=x'00' WHERE digest=?", &.{.{ .blob = &child.digest }}));
    for (0..3) |case| {
        children[1] = nominal;
        body.schema.bytes = "fixture.projection.v1";
        switch (case) {
            0 => children[1].bytes += 1,
            1 => children[1].digest = @splat(3),
            2 => body.schema.bytes = "fixture.projection.v0",
            else => unreachable,
        }
        const rejected = try contracts.encodeOwned(Codec.Body, a, body);
        defer a.free(rejected);
        try store.begin();
        const reference = try store.putObject(rejected);
        if (case < 2) {
            try std.testing.expectError(error.Constraint, store.retainProjection(Codec.decode, &.{rejected}));
        } else {
            try std.testing.expectError(error.InvalidProjection, store.retainProjection(Codec.decode, &.{rejected}));
        }
        try std.testing.expect(!store.transaction);
        try std.testing.expectEqual(@as(u64, 1), try store.scalar("SELECT count(*) FROM dependencies"));
        try std.testing.expectError(error.MissingArtifact, store.object(a, reference, null));
        try std.testing.expectEqual(epoch, try store.publicationEpoch());
    }
    try store.begin();
    try std.testing.expectError(error.InvalidProjection, store.retainProjection(Codec.forged, &.{bytes}));
    try std.testing.expect(!store.transaction);
    try std.testing.expectEqual(epoch, try store.publicationEpoch());
}

test "old state formats require a fresh namespace without rewriting old records" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    try db.exec("CREATE TABLE meta(singleton INTEGER PRIMARY KEY, format INTEGER, namespace BLOB, generation INTEGER, parent BLOB, head BLOB);");
    const namespace: Digest = @splat(7);
    try db.run("INSERT INTO meta VALUES(1,11,?,0,?,?)", &.{ .{ .blob = &namespace }, .{ .blob = &namespace }, .{ .blob = &namespace } });
    try std.testing.expectError(error.UnsupportedStateFormat, Store.init(a, db, false, namespace));
    var query = try db.prepare("SELECT format FROM meta WHERE singleton=1", &.{});
    defer query.deinit();
    try std.testing.expectEqual(.row, try query.step());
    try std.testing.expectEqual(@as(i64, 11), try query.integer(0));
    var tables = try db.prepare("SELECT count(*) FROM sqlite_schema WHERE type='table'", &.{});
    defer tables.deinit();
    try std.testing.expectEqual(.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 1), try tables.integer(0));
}

test "cold retention audit derives shared dependencies and detects missing edges and corrupt bodies" {
    const registry = @import("registry.zig");
    const a = std.testing.allocator;
    var handlers = try registry.Registry.init(a, &.{});
    defer handlers.deinit();
    for (0..4) |scenario| {
        const db = try sqlite.Database.open(a, ":memory:", true);
        defer db.destroy() catch unreachable;
        defer db.close() catch unreachable;
        var store = try Store.init(a, db, true, @splat(9));
        try store.begin();
        const input = try store.putObject("shared immutable input");
        const task = retentionFixtureTask(input);
        try store.putTask(task, null);
        const head = try store.commit("fixture");
        try store.confirmSealed(head);
        const statistics = try store.auditRetention(handlers, @splat(0));
        try std.testing.expectEqual(2, statistics.objects);
        try std.testing.expectEqual(1, statistics.edges);
        try std.testing.expectEqual(head.generation, store.sealed_generation.?);
        if (scenario == 0) {
            store.allocator = std.testing.failing_allocator;
            try std.testing.expectError(error.OutOfMemory, store.auditRetention(handlers, @splat(0)));
            store.allocator = a;
            try std.testing.expect(!store.fenced and !store.transaction);
            try std.testing.expectEqual(head.generation, store.sealed_generation.?);
            continue;
        }
        store.invalidateIntegrity();
        switch (scenario) {
            1 => try db.exec("DELETE FROM dependencies"),
            2 => try db.exec("UPDATE dependencies SET child_bytes=child_bytes+1"),
            3 => {
                try db.exec("DROP TRIGGER retained_object_immutable");
                try db.run("UPDATE objects SET body=? WHERE digest=?", &.{ .{ .blob = "altered immutable data" }, .{ .blob = &input.digest } });
            },
            else => unreachable,
        }
        try std.testing.expectError(error.CorruptState, store.auditRetention(handlers, @splat(0)));
        try std.testing.expect(store.fenced);
        try std.testing.expect(!store.transaction);
    }
}
