//! Transactional environmental state. Kronos bytes are opaque objects; every
//! acknowledged mutation publishes its receipt, records and events together.
const std = @import("std");
const contracts = @import("protean_contracts");
const sqlite = @import("sqlite.zig");
const state = @import("state.zig");
const occurrence = @import("occurrence.zig");
const hash_abi = @import("hash_abi.zig");
const Digest = state.Digest;
pub const format: u32 = @import("native_options").state_format;
pub const state_bytes = @import("native_options").state_bytes;
pub const maximum_object_bytes = sqlite.maximum_blob_bytes;
pub const dispatch_reserve = 16 * 1024 * 1024;
pub const capture_dispatch_reserve = 20 * 1024 * 1024;
pub const captured_reserve = 15 * 1024 * 1024;
pub const acquired_reserve = 11 * 1024 * 1024;

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
pub fn Record(comptime kind: []const u8) type {
    return switch (@field(state.RecordKind, kind)) {
        .occurrence => occurrence.Occurrence,
        .question => state.Question,
        .message => state.Message,
        .artifact => state.Artifact,
        .capture => state.Capture,
        .attempt => state.Attempt,
        .origin => state.Origin,
    };
}
pub const Store = struct {
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    head: Head,
    transaction: bool = false,
    fenced: bool = false,

    /// The namespace owner has already authenticated the directory, acquired
    /// its OS lock and decided whether this is a new or existing database.
    pub fn init(a: std.mem.Allocator, database: *sqlite.Database, create: bool, namespace: Digest) !Store {
        try database.exec("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE;");
        try database.exec(std.fmt.comptimePrint("PRAGMA page_size=4096; PRAGMA max_page_count={d};", .{state_bytes / 4096}));
        if (create) {
            try database.exec("BEGIN IMMEDIATE;");
            errdefer database.exec("ROLLBACK;") catch {};
            try database.exec(std.fmt.comptimePrint("CREATE TABLE meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1), format INTEGER NOT NULL CHECK(format={d}), namespace BLOB NOT NULL, generation INTEGER NOT NULL, parent BLOB NOT NULL, head BLOB NOT NULL);", .{format}) ++
                \\CREATE TABLE objects(digest BLOB PRIMARY KEY CHECK(length(digest)=32), body BLOB NOT NULL);
                \\CREATE TABLE tasks(id BLOB PRIMARY KEY CHECK(length(id)=16), revision INTEGER NOT NULL, terminal INTEGER NOT NULL CHECK(terminal IN(0,1)), body BLOB NOT NULL REFERENCES objects(digest)) WITHOUT ROWID;
                \\CREATE TABLE operations(id TEXT PRIMARY KEY, request BLOB NOT NULL CHECK(length(request)=32), receipt BLOB NOT NULL REFERENCES objects(digest), task BLOB NOT NULL CHECK(length(task)=16)) WITHOUT ROWID;
                \\CREATE INDEX operation_tasks ON operations(task,id);
                \\CREATE TABLE records(kind TEXT NOT NULL, id BLOB NOT NULL, task BLOB NOT NULL REFERENCES tasks(id), body BLOB NOT NULL REFERENCES objects(digest), PRIMARY KEY(kind,id)) WITHOUT ROWID;
                \\CREATE TABLE events(task BLOB NOT NULL REFERENCES tasks(id), seq INTEGER NOT NULL, revision INTEGER NOT NULL, body BLOB NOT NULL REFERENCES objects(digest), PRIMARY KEY(task,seq)) WITHOUT ROWID;
                \\CREATE TABLE reservations(attempt BLOB PRIMARY KEY CHECK(length(attempt)=32), bytes INTEGER NOT NULL CHECK(bytes>=0 AND bytes<=20971520)) WITHOUT ROWID;
            );
            try database.run("INSERT INTO meta VALUES(1,?, ?,0,?,?)", &.{ .{ .integer = format }, .{ .blob = &namespace }, .{ .blob = &@as(Digest, @splat(0)) }, .{ .blob = &namespace } });
            try database.exec("COMMIT;");
        }
        var query = try database.prepare("SELECT format,namespace,generation,parent,head FROM meta WHERE singleton=1", &.{});
        defer query.deinit();
        if (try query.step() != .row or try query.integer(0) != format or !std.mem.eql(u8, try query.bytes(1), &namespace)) return error.CorruptState;
        const generation = try query.integer(2);
        if (generation < 0) return error.CorruptState;
        const parent = try query.bytes(3);
        const head = try query.bytes(4);
        if (parent.len != 32 or head.len != 32) return error.CorruptState;
        return .{ .allocator = a, .database = database, .head = .{ .generation = @intCast(generation), .parent = parent[0..32].*, .digest = head[0..32].* } };
    }

    pub fn begin(self: *Store) !void {
        if (self.fenced) return error.StorageUnavailable;
        if (self.transaction) return error.Busy;
        try self.database.exec("BEGIN IMMEDIATE;");
        self.transaction = true;
    }
    pub fn rollback(self: *Store) void {
        if (!self.transaction) return;
        self.database.exec("ROLLBACK;") catch {
            self.fenced = true;
        };
        self.transaction = false;
    }
    fn writing(self: *Store) !void {
        if (self.fenced or !self.transaction) return error.InvalidState;
    }

    /// The namespace must publish this returned head to its independently
    /// checked seal before acknowledging anything or dispatching an effect.
    pub fn commit(self: *Store, transition: []const u8) !Head {
        try self.writing();
        try self.checkCapacity();
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
            self.fenced = true;
            return error.CorruptState;
        }
        self.database.exec("COMMIT;") catch |err| {
            self.fenced = true;
            return err;
        };
        self.transaction = false;
        self.head = next;
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
    fn checkCapacity(self: *Store) !void {
        const page_size = try self.scalar("PRAGMA page_size");
        const pages = try self.scalar("PRAGMA page_count");
        const free = try self.scalar("PRAGMA freelist_count");
        const reserved = try self.scalar("SELECT coalesce(sum(bytes),0) FROM reservations");
        if (page_size != 4096 or free > pages) return error.CorruptState;
        // This check is on the resulting transaction, so another admission
        // cannot consume space reserved for an already dispatched operation.
        const used = try std.math.mul(u64, pages - free, page_size);
        if (used +| reserved > state_bytes - 1024 * 1024) return error.Capacity;
    }
    pub fn reserve(self: *Store, attempt: Digest) !void {
        try self.writing();
        try self.database.run("INSERT INTO reservations VALUES(?,?)", &.{ .{ .blob = &attempt }, .{ .integer = dispatch_reserve } });
    }
    pub fn reserveCapture(self: *Store, attempt: Digest) !void {
        try self.writing();
        try self.database.run("INSERT INTO reservations VALUES(?,?)", &.{ .{ .blob = &attempt }, .{ .integer = capture_dispatch_reserve } });
    }
    pub fn reserveCaptured(self: *Store, attempt: Digest) !void {
        try self.setReservation(attempt, captured_reserve);
    }
    pub fn reserveAcquired(self: *Store, attempt: Digest) !void {
        try self.setReservation(attempt, acquired_reserve);
    }
    fn setReservation(self: *Store, attempt: Digest, bytes: u64) !void {
        try self.writing();
        try self.database.run("UPDATE reservations SET bytes=? WHERE attempt=?", &.{ .{ .integer = @intCast(bytes) }, .{ .blob = &attempt } });
        if (try self.database.changes() != 1) return error.CorruptState;
    }
    pub fn releaseReservation(self: *Store, attempt: Digest) !void {
        try self.writing();
        try self.database.run("DELETE FROM reservations WHERE attempt=?", &.{.{ .blob = &attempt }});
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
        if (ref.bytes > maximum_object_bytes) return error.Capacity;
        try self.database.run("INSERT OR IGNORE INTO objects VALUES(?,zeroblob(?))", &.{ .{ .blob = &ref.digest }, .{ .integer = @intCast(ref.bytes) } });
        const inserted = try self.database.changes() == 1;
        const location = try self.objectLocation(ref.digest, maximum_object_bytes);
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
    pub fn object(self: *Store, a: std.mem.Allocator, ref: state.Reference, limit: usize) ![]u8 {
        if (ref.bytes > limit) return error.Capacity;
        const bytes = try self.acquiredObject(a, ref.digest, limit);
        errdefer a.free(bytes);
        if (bytes.len != ref.bytes) return error.CorruptState;
        return bytes;
    }
    /// Check the complete immutable object, retaining only the requested range.
    /// An empty destination verifies integrity without materializing the object.
    pub fn objectRange(self: *Store, ref: state.Reference, start: usize, destination: []u8) !void {
        if (ref.bytes > maximum_object_bytes) return error.Capacity;
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
        if (ref.bytes > maximum_object_bytes) return error.Capacity;
        const location = try self.objectLocation(ref.digest, maximum_object_bytes);
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
        if (!std.mem.eql(u8, &observed, &ref.digest)) return error.CorruptState;
    }
    /// Private occurrence lookup. Public artifact reads require a separate
    /// task/audience-bound artifact record, never a bare content digest.
    pub fn acquiredObject(self: *Store, a: std.mem.Allocator, id: Digest, limit: usize) ![]u8 {
        const location = try self.objectLocation(id, @min(limit, maximum_object_bytes));
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
        if (!std.mem.eql(u8, &digest(bytes), &id)) return error.CorruptState;
        return bytes;
    }
    fn objectLocation(self: *Store, id: Digest, limit: usize) !struct { row: i64, bytes: usize } {
        var query = try self.database.prepare("SELECT rowid,length(body) FROM objects WHERE digest=?", &.{.{ .blob = &id }});
        defer query.deinit();
        if (try query.step() != .row) return error.MissingArtifact;
        const length = try query.integer(1);
        if (length < 0 or length > limit) return error.Capacity;
        return .{ .row = try query.integer(0), .bytes = @intCast(length) };
    }
    fn recordObject(self: *Store, a: std.mem.Allocator, reference: []const u8) ![]u8 {
        if (reference.len != 32) return error.CorruptState;
        return self.acquiredObject(a, reference[0..32].*, 256 * 1024) catch |err| switch (err) {
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
        if (id.len == 0 or id.len > 128 or bytes.len > 64 * 1024) return error.Capacity;
        var decoded = try contracts.decodeOwned(state.Receipt, self.allocator, bytes);
        defer decoded.deinit();
        if (!std.mem.eql(u8, &decoded.value.request_digest, &request)) return error.CorruptState;
        const ref = try self.putObject(bytes);
        try self.database.run("INSERT INTO operations VALUES(?,?,?,?)", &.{ .{ .text = id }, .{ .blob = &request }, .{ .blob = &ref.digest }, .{ .blob = &decoded.value.task } });
    }

    pub fn putTask(self: *Store, task: state.Task, previous: ?u64) !void {
        try self.writing();
        if (task.revision > std.math.maxInt(i64)) return error.Capacity;
        const body = try contracts.encodeOwned(state.Task, self.allocator, task);
        defer self.allocator.free(body);
        const ref = try self.putObject(body);
        if (previous) |revision| {
            if (revision >= std.math.maxInt(i64) or task.revision != revision + 1) return error.StaleRevision;
            try self.database.run("UPDATE tasks SET revision=?,terminal=?,body=? WHERE id=? AND revision=?", &.{ .{ .integer = @intCast(task.revision) }, .{ .integer = @intFromBool(task.terminal()) }, .{ .blob = &ref.digest }, .{ .blob = &task.id }, .{ .integer = @intCast(revision) } });
            if (try self.database.changes() != 1) return error.StaleRevision;
        } else {
            if (task.revision != 1) return error.StaleRevision;
            try self.database.run("INSERT INTO tasks VALUES(?,?,?,?)", &.{ .{ .blob = &task.id }, .{ .integer = 1 }, .{ .integer = @intFromBool(task.terminal()) }, .{ .blob = &ref.digest } });
        }
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
        if (comptime std.mem.eql(u8, kind, "artifact") or std.mem.eql(u8, kind, "attempt") or std.mem.eql(u8, kind, "origin")) @compileError("immutable native records are created once");
        try self.writing();
        const body = try contracts.encodeOwned(T, self.allocator, value);
        defer self.allocator.free(body);
        if (body.len > 256 * 1024) return error.Capacity;
        const ref = try self.putObject(body);
        try self.database.run("UPDATE records SET body=? WHERE kind=? AND id=? AND task=?", &.{ .{ .blob = &ref.digest }, .{ .text = kind }, .{ .blob = &id }, .{ .blob = &task } });
        if (try self.database.changes() != 1) return error.CorruptState;
    }
    pub fn createRecord(self: *Store, comptime T: type, comptime kind: []const u8, id: Digest, task: state.TaskId, value: T) !void {
        if (T != Record(kind)) @compileError("native record type/kind mismatch");
        try self.writing();
        const body = try contracts.encodeOwned(T, self.allocator, value);
        defer self.allocator.free(body);
        if (body.len > 256 * 1024) return error.Capacity;
        const ref = try self.putObject(body);
        try self.database.run("INSERT INTO records VALUES(?,?,?,?)", &.{ .{ .text = kind }, .{ .blob = &id }, .{ .blob = &task }, .{ .blob = &ref.digest } });
    }
    pub fn recordBytes(self: *Store, a: std.mem.Allocator, comptime kind: []const u8, id: Digest, task: state.TaskId) !?[]u8 {
        var query = try self.database.prepare("SELECT body FROM records WHERE kind=? AND id=? AND task=?", &.{ .{ .text = kind }, .{ .blob = &id }, .{ .blob = &task } });
        defer query.deinit();
        if (try query.step() != .row) return null;
        return try self.recordObject(a, try query.bytes(0));
    }
    pub fn taskIds(self: *Store, a: std.mem.Allocator, nonterminal: bool) ![]state.TaskId {
        var query = try self.database.prepare("SELECT id FROM tasks WHERE (?=0 OR terminal=0) ORDER BY id LIMIT 1025", &.{.{ .integer = @intFromBool(nonterminal) }});
        defer query.deinit();
        var ids: std.ArrayList(state.TaskId) = .empty;
        errdefer ids.deinit(a);
        while (try query.step() == .row) {
            const bytes = try query.bytes(0);
            if (bytes.len != 16) return error.CorruptState;
            if (ids.items.len == 1024) return error.Capacity;
            try ids.append(a, bytes[0..16].*);
        }
        return ids.toOwnedSlice(a);
    }

    pub fn capabilityAttempts(self: *Store, task: state.TaskId, capability: []const u8) !u32 {
        var query = try self.database.prepare("SELECT body FROM records WHERE kind='attempt' AND task=? LIMIT 1025", &.{.{ .blob = &task }});
        defer query.deinit();
        var seen: usize = 0;
        var count: u32 = 0;
        while (try query.step() == .row) {
            if (seen == 1024) return error.Capacity;
            seen += 1;
            const bytes = try self.recordObject(self.allocator, try query.bytes(0));
            defer self.allocator.free(bytes);
            var attempt = try contracts.decodeOwned(state.Attempt, self.allocator, bytes);
            defer attempt.deinit();
            if (!std.mem.eql(u8, &task, &attempt.value.task)) return error.CorruptState;
            if (std.mem.eql(u8, capability, attempt.value.capability.bytes)) count += 1;
        }
        return count;
    }

    pub const ProjectionOwner = struct { attempt: Digest, object: state.Reference };
    /// Return provenance candidates, not permission. The capability owner must
    /// authorize disclosure before any returned object is read publicly.
    pub fn projectionOwners(self: *Store, a: std.mem.Allocator, task: state.TaskId, object_id: Digest) ![]ProjectionOwner {
        var query = try self.database.prepare("SELECT id,body FROM records WHERE kind='capture' AND task=? LIMIT 1025", &.{.{ .blob = &task }});
        defer query.deinit();
        var result: std.ArrayList(ProjectionOwner) = .empty;
        errdefer result.deinit(a);
        var seen: usize = 0;
        while (try query.step() == .row) {
            if (seen == 1024) return error.Capacity;
            seen += 1;
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

    pub fn objectReference(self: *Store, id: Digest, limit: usize) !state.Reference {
        var query = try self.database.prepare("SELECT length(body) FROM objects WHERE digest=?", &.{.{ .blob = &id }});
        defer query.deinit();
        if (try query.step() != .row) return error.MissingArtifact;
        const length = try query.integer(0);
        if (length < 0 or length > limit) return error.Capacity;
        return .{ .digest = id, .bytes = @intCast(length) };
    }
    fn indexedReference(self: *Store, bytes: []const u8) !state.Reference {
        if (bytes.len != 32) return error.CorruptState;
        return self.objectReference(bytes[0..32].*, 256 * 1024);
    }

    /// A bounded, task-scoped index snapshot. The archive owner validates each
    /// canonical record and computes its artifact closure before publication.
    pub fn archiveIndex(self: *Store, a: std.mem.Allocator, task_id: state.TaskId, build: state.Reference) !state.Archive {
        if (self.transaction or self.fenced) return error.Busy;
        const task_bytes = try self.taskBytes(a, task_id);
        defer a.free(task_bytes);
        var records: std.ArrayList(state.ArchiveRecord) = .empty;
        var events: std.ArrayList(state.ArchiveEvent) = .empty;
        var operations: std.ArrayList(state.ArchiveOperation) = .empty;
        var reservations: std.ArrayList(state.ArchiveReservation) = .empty;
        // The caller supplies an arena. No borrowed SQLite column escapes.
        {
            var query = try self.database.prepare("SELECT kind,id,body FROM records WHERE task=? ORDER BY kind,id LIMIT 1025", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                if (records.items.len == 1024) return error.Capacity;
                const kind = std.meta.stringToEnum(state.RecordKind, try query.bytes(0)) orelse return error.NonPortable;
                const id = try query.bytes(1);
                if (id.len != 32) return error.CorruptState;
                try records.append(a, .{ .kind = kind, .id = id[0..32].*, .body = try self.indexedReference(try query.bytes(2)) });
            }
        }
        {
            var query = try self.database.prepare("SELECT seq,revision,body FROM events WHERE task=? ORDER BY seq LIMIT 2049", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                if (events.items.len == 2048) return error.Capacity;
                const seq = try query.integer(0);
                const revision = try query.integer(1);
                if (seq <= 0 or revision <= 0) return error.CorruptState;
                try events.append(a, .{ .seq = @intCast(seq), .revision = @intCast(revision), .body = try self.indexedReference(try query.bytes(2)) });
            }
        }
        {
            var query = try self.database.prepare("SELECT id,request,receipt FROM operations WHERE task=? ORDER BY id LIMIT 2049", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                if (operations.items.len == 2048) return error.Capacity;
                const key = try query.bytes(0);
                const request = try query.bytes(1);
                if (key.len == 0 or key.len > 128 or request.len != 32) return error.CorruptState;
                try operations.append(a, .{ .key = .{ .bytes = try a.dupe(u8, key) }, .request = request[0..32].*, .body = try self.indexedReference(try query.bytes(2)) });
            }
        }
        {
            var query = try self.database.prepare("SELECT r.attempt,r.bytes FROM reservations r JOIN records x ON x.kind='attempt' AND x.id=r.attempt WHERE x.task=? ORDER BY r.attempt LIMIT 65", &.{.{ .blob = &task_id }});
            defer query.deinit();
            while (try query.step() == .row) {
                if (reservations.items.len == 64) return error.Capacity;
                const attempt = try query.bytes(0);
                const bytes = try query.integer(1);
                if (attempt.len != 32 or bytes <= 0 or bytes > capture_dispatch_reserve) return error.CorruptState;
                try reservations.append(a, .{ .attempt = attempt[0..32].*, .bytes = @intCast(bytes) });
            }
        }
        return .{
            .version = 1,
            .classification = .private,
            .profile = .offline_copy,
            .task = .{ .digest = digest(task_bytes), .bytes = task_bytes.len },
            .build = build,
            .schemas = .{ .items = &.{} },
            .records = .{ .items = try records.toOwnedSlice(a) },
            .events = .{ .items = try events.toOwnedSlice(a) },
            .operations = .{ .items = try operations.toOwnedSlice(a) },
            .reservations = .{ .items = try reservations.toOwnedSlice(a) },
            .objects = .{ .items = &.{} },
        };
    }

    /// Import is confined to a fresh namespace transaction. It preserves the
    /// archived task ID and history; grants and resume remain caller-owned.
    pub fn restoreArchiveIndex(self: *Store, a: std.mem.Allocator, archive: state.Archive, task: state.Task) !void {
        try self.writing();
        if (self.head.generation != 0 or task.revision == 0 or task.revision > std.math.maxInt(i64) or try self.scalar("SELECT count(*) FROM tasks") != 0) return error.InvalidState;
        const bytes = try contracts.encodeOwned(state.Task, a, task);
        defer a.free(bytes);
        const body = try self.putObject(bytes);
        try self.database.run("INSERT INTO tasks VALUES(?,?,?,?)", &.{ .{ .blob = &task.id }, .{ .integer = @intCast(task.revision) }, .{ .integer = @intFromBool(task.terminal()) }, .{ .blob = &body.digest } });
        for (archive.records.items) |row| try self.database.run("INSERT INTO records VALUES(?,?,?,?)", &.{ .{ .text = @tagName(row.kind) }, .{ .blob = &row.id }, .{ .blob = &task.id }, .{ .blob = &row.body.digest } });
        for (archive.events.items) |row| {
            if (row.seq == 0 or row.seq > std.math.maxInt(i64) or row.revision == 0 or row.revision > task.revision) return error.CorruptState;
            try self.database.run("INSERT INTO events VALUES(?,?,?,?)", &.{ .{ .blob = &task.id }, .{ .integer = @intCast(row.seq) }, .{ .integer = @intCast(row.revision) }, .{ .blob = &row.body.digest } });
        }
        for (archive.operations.items) |row| {
            const receipt_bytes = try self.object(a, row.body, 256 * 1024);
            defer a.free(receipt_bytes);
            try self.putReceipt(row.key.bytes, row.request, receipt_bytes);
        }
        for (archive.reservations.items) |row| {
            if (row.bytes == 0 or row.bytes > capture_dispatch_reserve) return error.CorruptState;
            try self.database.run("INSERT INTO reservations VALUES(?,?)", &.{ .{ .blob = &row.attempt }, .{ .integer = @intCast(row.bytes) } });
        }
    }
    pub fn putEvent(self: *Store, event: state.Event) !void {
        try self.writing();
        if (event.seq == 0 or event.seq > std.math.maxInt(i64) or event.revision > std.math.maxInt(i64)) return error.Capacity;
        try @import("schemas.zig").validateEventData(self.allocator, event.kind, event.data.bytes);
        const body = try contracts.encodeOwned(state.Event, self.allocator, event);
        defer self.allocator.free(body);
        const ref = try self.putObject(body);
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
    try db.run("UPDATE operations SET task=? WHERE id='request-1'", &.{.{ .blob = &@as(state.TaskId, @splat(3)) }});
    try std.testing.expectError(error.CorruptState, store.receipt(a, "request-1", digest("submit/input")));
    try db.run("UPDATE operations SET task=? WHERE id='request-1'", &.{.{ .blob = &@as(state.TaskId, @splat(2)) }});
    try db.run("UPDATE objects SET body=? WHERE digest=?", &.{ .{ .blob = "changed receipt" }, .{ .blob = &digest(receipt_bytes) } });
    try std.testing.expectError(error.CorruptState, store.receipt(a, "request-1", digest("submit/input")));
    try std.testing.expect(@import("native_c").sqlite3_memory_used() <= sqlite.heap_bytes);
}

test "file-backed objects cross allocator boundaries without growing the SQLite heap" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/objects.sqlite", .{path_buffer[0..path_length]});
    defer a.free(path);
    const bytes = try a.alloc(u8, maximum_object_bytes + 1);
    defer a.free(bytes);
    @memset(bytes, 0x5a);
    const sizes = [_]usize{ 0, 8 * 1024 * 1024, 8 * 1024 * 1024 + 1, 9 * 1024 * 1024, maximum_object_bytes };
    var references: [sizes.len]state.Reference = undefined;
    {
        const db = try sqlite.Database.open(a, path, true);
        defer db.destroy() catch unreachable;
        defer db.close() catch unreachable;
        var store = try Store.init(a, db, true, @splat(7));
        for (sizes, &references) |size, *reference| {
            try store.begin();
            reference.* = try store.putObject(bytes[0..size]);
            try std.testing.expectEqualDeep(reference.*, try store.putObject(bytes[0..size]));
            _ = try store.commit("large-object");
        }
        try store.begin();
        try std.testing.expectError(error.Capacity, store.putObject(bytes));
        store.rollback();
        bytes[0] ^= 1;
        try store.begin();
        const rolled_back = try store.putObject(bytes[0 .. 9 * 1024 * 1024]);
        store.rollback();
        try std.testing.expectError(error.MissingArtifact, store.object(a, rolled_back, maximum_object_bytes));
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
        try std.testing.expectError(error.MissingArtifact, store.object(a, invalid, maximum_object_bytes));
        try std.testing.expect(@import("native_c").sqlite3_memory_used() <= sqlite.heap_bytes);
    }
    {
        const db = try sqlite.Database.open(a, path, false);
        defer db.destroy() catch unreachable;
        defer db.close() catch unreachable;
        var store = try Store.init(a, db, false, @splat(7));
        for (sizes, references) |size, reference| {
            const actual = try store.object(a, reference, maximum_object_bytes);
            defer a.free(actual);
            try std.testing.expectEqualSlices(u8, bytes[0..size], actual);
        }
        const largest = references[references.len - 1];
        var range: [127]u8 = undefined;
        try store.objectRange(largest, 65500, &range);
        try std.testing.expectEqualSlices(u8, bytes[65500..][0..range.len], &range);
        try store.objectRange(largest, largest.bytes, &.{});
        try std.testing.expectError(error.InvalidParams, store.objectRange(largest, largest.bytes, &range));
        try std.testing.expectError(error.Capacity, store.object(a, largest, maximum_object_bytes - 1));
        try store.begin();
        const location = try store.objectLocation(largest.digest, maximum_object_bytes);
        var blob = try db.openBlob("objects", "body", location.row, true);
        try blob.write(&.{0xff}, maximum_object_bytes - 1);
        try blob.close();
        _ = try store.commit("corrupt-last-byte");
        // Corruption outside the requested range must still be rejected.
        try std.testing.expectError(error.CorruptState, store.objectRange(largest, 0, &range));
        try std.testing.expectError(error.CorruptState, store.objectRange(largest, 0, &.{}));
        try std.testing.expectError(error.CorruptState, store.object(a, largest, maximum_object_bytes));
        try store.begin();
        try std.testing.expectError(error.CorruptState, store.putObject(bytes[0..maximum_object_bytes]));
        store.rollback();
        try std.testing.expect(@import("native_c").sqlite3_memory_used() <= sqlite.heap_bytes);
    }
}

test "commits cannot spend another occurrence's reserved storage" {
    const a = std.testing.allocator;
    const db = try sqlite.Database.open(a, ":memory:", true);
    defer db.destroy() catch unreachable;
    defer db.close() catch unreachable;
    var store = try Store.init(a, db, true, @splat(7));
    for (0..15) |i| {
        var attempt: Digest = @splat(0);
        attempt[0] = @intCast(i);
        try store.begin();
        try store.reserve(attempt);
        _ = try store.commit("reserve");
    }
    try store.begin();
    try store.reserve(@splat(16));
    try std.testing.expectError(error.Capacity, store.commit("must-not-acknowledge"));
    store.rollback();
    try std.testing.expect(!store.fenced);
    try std.testing.expectEqual(15, store.head.generation);
    try store.begin();
    try store.releaseReservation(@splat(0));
    try store.reserve(@splat(16));
    _ = try store.commit("replace-released-reservation");
    try std.testing.expectEqual(16, store.head.generation);
}
