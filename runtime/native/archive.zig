//! Environmental archives. Canonical Kosmos objects and ordinary Protean
//! records travel as data; namespace locks, grants and subscriptions do not.
const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("state.zig");
const occurrence = @import("occurrence.zig");
const storage = @import("store.zig");
const values = @import("values.zig");
const json = @import("json.zig");
const namespace = @import("namespace.zig");
const c = @import("native_c");

const magic = "AGNX0001";
const temporary_prefix = ".protean-archive-";
const temporary_length = temporary_prefix.len + 32;
pub const Exported = struct { sha256: state.Digest, bytes: u64 };
const Blob = struct { reference: state.Reference, bytes: []const u8 };
const SchemaSet = struct { schemas: []const state.ArchiveSchema, blobs: []const Blob };
const primary_schemas = .{
    .{ "task", state.Task },
    .{ "event", state.Event },
    .{ "receipt", state.Receipt },
};

pub fn schemaBytes(a: std.mem.Allocator, name: []const u8) ![]u8 {
    inline for (primary_schemas) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return schemaDefinition(entry[1], a, a);
    }
    inline for (@typeInfo(state.RecordKind).@"enum".field_names) |kind| {
        if (std.mem.eql(u8, name, kind)) return schemaDefinition(storage.Record(kind), a, a);
    }
    return error.InvalidArchive;
}

fn schemaDefinition(comptime T: type, a: std.mem.Allocator, backing: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    return a.dupe(u8, try values.schemaBytes(T, arena.allocator()));
}

fn schemaSet(a: std.mem.Allocator, backing: std.mem.Allocator) !SchemaSet {
    var schemas: std.ArrayList(state.ArchiveSchema) = .empty;
    var blobs: std.ArrayList(Blob) = .empty;
    inline for (primary_schemas) |entry| {
        const bytes = try schemaDefinition(entry[1], a, backing);
        const reference: state.Reference = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        try schemas.append(a, .{ .name = .{ .bytes = entry[0] }, .definition = reference });
        try blobs.append(a, .{ .reference = reference, .bytes = bytes });
    }
    inline for (@typeInfo(state.RecordKind).@"enum".field_names) |name| {
        const bytes = try schemaDefinition(storage.Record(name), a, backing);
        const reference: state.Reference = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        try schemas.append(a, .{ .name = .{ .bytes = name }, .definition = reference });
        try blobs.append(a, .{ .reference = reference, .bytes = bytes });
    }
    return .{ .schemas = try schemas.toOwnedSlice(a), .blobs = try blobs.toOwnedSlice(a) };
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn readAt(fd: c_int, offset: u64, bytes: []u8) !void {
    var position: usize = 0;
    while (position < bytes.len) {
        const count = c.pread(
            fd,
            bytes[position..].ptr,
            bytes.len - position,
            @intCast(offset + position),
        );
        if (count < 0 and std.c.errno(count) == .INTR) continue;
        if (count <= 0) return error.InvalidArchive;
        position += @intCast(count);
    }
}
fn privateFile(fd: c_int) !u64 {
    var stat: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(fd, &stat) != 0) return error.StorageUnavailable;
    if (stat.st_mode & c.S_IFMT != c.S_IFREG or
        stat.st_mode & 0o077 != 0 or
        stat.st_uid != c.geteuid() or
        stat.st_size < 0)
        return error.UnsafeStatePath;
    return @intCast(stat.st_size);
}
fn parent(a: std.mem.Allocator, path: []const u8) !struct { fd: c_int, name: [:0]u8 } {
    if (path.len == 0 or path[path.len - 1] == '/' or std.mem.indexOfScalar(
        u8,
        path,
        0,
    ) != null) return error.InvalidParams;
    const name = std.fs.path.basename(path);
    if (same(name, ".") or same(name, "..")) return error.InvalidParams;
    const directory = try namespace.openDirectory(
        a,
        std.fs.path.dirname(path) orelse ".",
        false,
        false,
    );
    errdefer _ = c.close(directory);
    return .{ .fd = directory, .name = try a.dupeSentinel(u8, name, 0) };
}

const Output = struct {
    allocator: std.mem.Allocator,
    directory: c_int,
    fd: c_int,
    name: [:0]u8,
    temporary: [temporary_length:0]u8,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    bytes: u64 = 0,

    fn open(a: std.mem.Allocator, io: std.Io, path: []const u8, state_directory: c_int) !Output {
        const location = try parent(a, path);
        errdefer {
            _ = c.close(location.fd);
            a.free(location.name);
        }
        var source: c.struct_protean_native_stat = undefined;
        var destination: c.struct_protean_native_stat = undefined;
        if (c.protean_native_fstat(state_directory, &source) != 0 or c.protean_native_fstat(
            location.fd,
            &destination,
        ) != 0) return error.StorageUnavailable;
        if (source.st_dev == destination.st_dev and
            source.st_ino == destination.st_ino)
            return error.UnsafeStatePath;
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        var temporary: [temporary_length:0]u8 = undefined;
        @memcpy(temporary[0..temporary_prefix.len], temporary_prefix);
        @memcpy(
            temporary[temporary_prefix.len..temporary_length],
            &std.fmt.bytesToHex(random, .lower),
        );
        temporary[temporary_length] = 0;
        const fd = c.openat(
            location.fd,
            &temporary,
            c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC,
            @as(c_uint, 0o600),
        );
        if (fd < 0) return error.StorageUnavailable;
        return .{
            .allocator = a,
            .directory = location.fd,
            .fd = fd,
            .name = location.name,
            .temporary = temporary,
        };
    }
    fn deinit(self: *Output) void {
        _ = c.close(self.fd);
        _ = c.unlinkat(self.directory, &self.temporary, 0);
        _ = c.close(self.directory);
        self.allocator.free(self.name);
    }
    pub fn write(self: *Output, bytes: []const u8) !void {
        const next = try std.math.add(u64, self.bytes, bytes.len);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = c.write(self.fd, bytes[offset..].ptr, bytes.len - offset);
            if (count < 0 and std.c.errno(count) == .INTR) continue;
            if (count <= 0) return error.StorageUnavailable;
            offset += @intCast(count);
        }
        self.hash.update(bytes);
        self.bytes = next;
    }
    fn finish(self: *Output) !Exported {
        if (c.fsync(self.fd) != 0) return error.StorageUnavailable;
        // Atomic, no-replace publication on the same filesystem. A crash may
        // retain the private temporary hard link, not a partial final archive.
        if (c.linkat(self.directory, &self.temporary, self.directory, self.name.ptr, 0) != 0)
            return if (std.c.errno(-1) == .EXIST) error.AlreadyExists else error.StorageUnavailable;
        if (c.fsync(self.directory) != 0) return error.StorageUnavailable;
        if (c.unlinkat(self.directory, &self.temporary, 0) != 0 or
            c.fsync(self.directory) != 0)
            return error.StorageUnavailable;
        var digest: state.Digest = undefined;
        self.hash.final(&digest);
        return .{ .sha256 = digest, .bytes = self.bytes };
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    prefix: []u8,
    manifest: contracts.Decoded(state.Archive),
    identity: state.Digest,
    bytes: u64,

    pub fn open(a: std.mem.Allocator, path: []const u8) !Reader {
        const location = try parent(a, path);
        defer {
            _ = c.close(location.fd);
            a.free(location.name);
        }
        const fd = c.openat(
            location.fd,
            location.name.ptr,
            c.O_RDONLY | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC,
        );
        if (fd < 0) return error.NotFound;
        errdefer _ = c.close(fd);
        const length = try privateFile(fd);
        if (length < 32) return error.InvalidArchive;
        var header: [32]u8 = undefined;
        try readAt(fd, 0, &header);
        if (!same(header[0..8], magic) or std.mem.readInt(
            u32,
            header[20..24],
            .little,
        ) != 0) return error.InvalidArchive;
        const schema_len = std.mem.readInt(u32, header[8..12], .little);
        const manifest_len = std.mem.readInt(u32, header[12..16], .little);
        const count = std.mem.readInt(u32, header[16..20], .little);
        const body_len = std.mem.readInt(u64, header[24..32], .little);
        const prefix_len = @as(u64, 32) + schema_len + manifest_len;
        if (prefix_len > length or body_len != length - prefix_len) return error.InvalidArchive;
        const prefix = try a.alloc(
            u8,
            std.math.cast(usize, prefix_len) orelse return error.Capacity,
        );
        errdefer a.free(prefix);
        try readAt(fd, 0, prefix);
        if (!same(prefix[0..32], &header)) return error.InvalidArchive;
        const expected_schema = try values.schemaBytes(state.Archive, a);
        defer a.free(expected_schema);
        if (!same(prefix[32 .. 32 + schema_len], expected_schema)) return error.NonPortable;
        var manifest = contracts.decodeOwned(
            state.Archive,
            a,
            prefix[32 + schema_len ..],
        ) catch |err| return if (err == error.OutOfMemory) err else error.InvalidArchive;
        errdefer manifest.deinit();
        try validateArchiveObjects(manifest.value, count, body_len);
        const identity = try archiveDigest(fd, prefix, length);
        return .{
            .allocator = a,
            .fd = fd,
            .prefix = prefix,
            .manifest = manifest,
            .identity = identity,
            .bytes = length,
        };
    }
    pub fn deinit(self: *Reader) void {
        self.manifest.deinit();
        self.allocator.free(self.prefix);
        _ = c.close(self.fd);
    }
    /// Preview only declared, digest-checked immutable data. Import still
    /// reacquires and authenticates the complete archive before publication.
    pub fn object(
        self: *Reader,
        a: std.mem.Allocator,
        wanted: state.Reference,
        limit: ?usize,
    ) ![]u8 {
        if (limit != null and wanted.bytes > limit.?) return error.Capacity;
        var offset: u64 = self.prefix.len;
        for (self.manifest.value.objects.items) |reference| {
            if (same(&reference.digest, &wanted.digest)) {
                if (reference.bytes != wanted.bytes) return error.InvalidArchive;
                const bytes = try a.alloc(u8, @intCast(reference.bytes));
                errdefer a.free(bytes);
                try readAt(self.fd, offset, bytes);
                if (!same(&storage.digest(bytes), &reference.digest)) return error.InvalidArchive;
                return bytes;
            }
            offset += reference.bytes;
        }
        return error.MissingArtifact;
    }
    pub fn acquire(self: *Reader, store: *storage.Store) !void {
        if (!store.transaction or store.fenced) return error.InvalidState;
        const prefix = try self.allocator.alloc(u8, self.prefix.len);
        defer self.allocator.free(prefix);
        try readAt(self.fd, 0, prefix);
        if (!same(prefix, self.prefix)) return error.InvalidArchive;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(prefix);
        var source = struct {
            fd: c_int,
            offset: u64,
            hash: *std.crypto.hash.sha2.Sha256,
            pub fn read(this: *@This(), bytes: []u8) !void {
                try readAt(this.fd, this.offset, bytes);
                this.hash.update(bytes);
                this.offset += bytes.len;
            }
        }{ .fd = self.fd, .offset = prefix.len, .hash = &hash };
        for (self.manifest.value.objects.items) |ref| store.acquireObject(
            ref,
            &source,
        ) catch |err| return if (err == error.InvalidObject) error.InvalidArchive else err;
        var identity: state.Digest = undefined;
        hash.final(&identity);
        if (!same(&identity, &self.identity) or
            try privateFile(self.fd) != self.bytes)
            return error.InvalidArchive;
    }
};

fn validateArchiveObjects(value: state.Archive, count: u32, body_len: u64) !void {
    if (value.version != 2 or count != value.objects.items.len) return error.NonPortable;
    var total: u64 = 0;
    for (value.objects.items, 0..) |ref, i| {
        if ((i != 0 and std.mem.order(
            u8,
            &value.objects.items[i - 1].digest,
            &ref.digest,
        ) != .lt)) return error.InvalidArchive;
        total = try std.math.add(u64, total, ref.bytes);
    }
    if (total != body_len) return error.InvalidArchive;
}

fn archiveDigest(fd: c_int, prefix: []const u8, length: u64) !state.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prefix);
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = prefix.len;
    while (offset < length) {
        const size: usize = @intCast(@min(buffer.len, length - offset));
        try readAt(fd, offset, buffer[0..size]);
        hash.update(buffer[0..size]);
        offset += size;
    }
    var identity: state.Digest = undefined;
    hash.final(&identity);
    return identity;
}

pub fn record(archive: state.Archive, kind: state.RecordKind, id: state.Digest) ?state.Reference {
    for (archive.records.items) |row| if (row.kind == kind and same(&row.id, &id)) return row.body;
    return null;
}

const Collector = struct {
    allocator: std.mem.Allocator,
    store: *storage.Store,
    supplied: []const Blob,
    objects: std.AutoArrayHashMapUnmanaged(state.Digest, state.Reference) = .empty,
    bytes: u64 = 0,

    pub fn add(self: *Collector, ref: state.Reference) !void {
        if (self.objects.get(ref.digest)) |prior| {
            if (prior.bytes != ref.bytes) return error.CorruptState;
            return;
        }
        var supplied = false;
        for (self.supplied) |blob| if (same(&blob.reference.digest, &ref.digest)) {
            if (blob.bytes.len != ref.bytes) return error.CorruptState;
            supplied = true;
            break;
        };
        if (!supplied) {
            const actual = try self.store.objectReference(ref.digest, null);
            if (actual.bytes != ref.bytes) return error.CorruptState;
        }
        try self.objects.put(self.allocator, ref.digest, ref);
        self.bytes = try std.math.add(u64, self.bytes, ref.bytes);
    }
    fn visit(self: *Collector, comptime T: type, value: T) !void {
        try state.visitReferences(T, value, self);
    }
    pub fn typed(self: *Collector, comptime T: type, ref: state.Reference, value: T) !void {
        try self.add(ref);
        try self.visit(T, value);
    }
    pub fn reply(self: *Collector, value: occurrence.Acquired) !void {
        try self.add(try self.store.objectReference(value.reply, null));
    }
    pub fn observerSource(self: *Collector, ref: state.Reference) !void {
        try state.visitObserverSource(self.allocator, self.store, ref, self);
    }
    pub fn reuseDefinition(self: *Collector, ref: state.Reference) !void {
        try state.visitReuseDefinition(self.allocator, self.store, ref, self);
    }
};

pub const Inspected = struct {
    task: contracts.Decoded(state.Task),
    objects: []state.Reference,
    current: ?occurrence.Occurrence,
};

const AdmissionFact = struct {
    request_digest: state.Digest,
    method: state.Method,
    receipt: state.Digest,
    question: ?state.Digest,
    message: ?state.Digest,
    reconciliation: ?state.Digest,
    workspace: ?state.Digest,
    event_seen: bool = false,
};
const AdmissionFacts = std.AutoHashMap(u64, AdmissionFact);
const EventPosition = struct { revision: u64, seq: u64 };
const RecordEvents = std.AutoHashMap(state.Digest, EventPosition);

fn admissionMethod(kind: state.EventType) ?state.Method {
    return switch (kind) {
        .accepted => .submit,
        .input_accepted => .respond,
        .message_queued => .message,
        .cancellation_requested => .cancel,
        .resumed => .@"resume",
        .imported => .import_checkpoint,
        .reconciled => .reconcile,
        .workspace => .workspace,
        .controller_requested => .adopt,
        .workspace_progress,
        .workspace_read,
        .controller,
        .execution,
        .input_required,
        .message_consumed,
        .message_not_consumed,
        .parked,
        .blocked,
        .delivery_unknown,
        .completed,
        .failed,
        .cancelled,
        => null,
    };
}

/// Events are retained projections, not an independently authoritative history.
/// Check facts whose owners survive in the archive; an old question need not be
/// pending, and an old queued message may since have been consumed or retired.
fn validateEventFacts(
    store: *storage.Store,
    archive: state.Archive,
    task: state.Task,
    admissions: *const AdmissionFacts,
    event: state.Event,
) !?state.Digest {
    var arena = std.heap.ArenaAllocator.init(store.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = (try json.parse(a, event.data.bytes, .{ .bytes = 48 * 1024, .depth = 33 })).value;
    const admission = admissions.get(event.revision);
    if (admissionMethod(event.kind)) |method| {
        if (admission == null or admission.?.method != method) return error.InvalidArchive;
    }
    var facts: EventFacts = .{
        .a = a,
        .store = store,
        .archive = archive,
        .task = task,
        .admission = admission,
        .event = event,
        .data = data,
    };
    const expected = try facts.expected() orelse return null;
    if (!same(try json.canonical(a, data), try json.canonical(a, expected)))
        return error.InvalidArchive;
    return facts.record_id;
}

const EventFacts = struct {
    a: std.mem.Allocator,
    store: *storage.Store,
    archive: state.Archive,
    task: state.Task,
    admission: ?AdmissionFact,
    event: state.Event,
    data: json.Value,
    record_id: ?state.Digest = null,

    fn expected(self: *EventFacts) !?json.Value {
        return switch (self.event.kind) {
            .controller_requested => try self.controllerRequested(),
            .controller => try self.controller(),
            .reconciled => try self.reconciled(),
            .completed, .failed, .cancelled => {
                if (!same(
                    @tagName(self.event.kind),
                    @tagName(self.task.outcome_kind),
                )) return error.InvalidArchive;
                return null;
            },
            .input_required => try self.inputRequired(),
            .input_accepted => try self.inputAccepted(),
            .message_queued, .message_consumed, .message_not_consumed => try self.messageFacts(),
            .imported => try self.imported(),
            .workspace => try self.workspace(),
            .workspace_progress,
            .workspace_read,
            .accepted,
            .cancellation_requested,
            .resumed,
            => return null,
            .execution => {
                if (self.admission != null) return error.InvalidArchive;
                return null;
            },
            // These may precede later progress and have no retained receipt or
            // immutable record of the historical schedule/blocker. Their shape and
            // journal range remain checked; current state cannot refute old state.
            .parked, .blocked, .delivery_unknown => return null,
        };
    }
    fn controllerRequested(self: *EventFacts) !?json.Value {
        const operation_id = json.get(self.data, "operation") orelse return error.InvalidArchive;
        if (operation_id != .string or operation_id.string.len != 64) return error.InvalidArchive;
        var id: state.Digest = undefined;
        _ = std.fmt.hexToBytes(&id, operation_id.string) catch return error.InvalidArchive;
        const reference = record(
            self.archive,
            .controller_succession,
            id,
        ) orelse return error.InvalidArchive;
        var succession = try contracts.decodeOwned(
            state.ControllerSuccession,
            self.a,
            try self.store.object(self.a, reference, null),
        );
        defer succession.deinit();
        const operator = succession.value.operator_admission orelse return error.InvalidArchive;
        if (operator.revision != self.event.revision or
            operator.event != self.event.seq or
            self.event.revision <= 1)
            return error.InvalidArchive;
        var command = try contracts.decodeOwned(
            contracts.workspace.Adoption,
            self.a,
            try self.store.object(self.a, succession.value.command, null),
        );
        defer command.deinit();
        const bytes = try contracts.encodeOwned(state.ControllerAdoptionRequest, self.a, .{
            .task = self.task.id,
            .revision = self.event.revision - 1,
            .command = command.value,
        });
        var request_hash = std.crypto.hash.sha2.Sha256.init(.{});
        request_hash.update("agent.native.operation.v1\x00");
        request_hash.update(bytes);
        var request_digest: state.Digest = undefined;
        request_hash.final(&request_digest);
        if (!std.meta.eql(
            request_digest,
            self.admission.?.request_digest,
        )) return error.InvalidArchive;
        var result = json.object();
        try json.put(
            self.a,
            &result,
            "operation",
            json.string(try self.a.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
        );
        return result;
    }
    fn controller(self: *EventFacts) !?json.Value {
        var id: state.Digest = undefined;
        _ = std.fmt.hexToBytes(
            &id,
            self.data.object.get("operation").?.string,
        ) catch return error.InvalidArchive;
        const reference = record(
            self.archive,
            .controller_succession,
            id,
        ) orelse return error.InvalidArchive;
        var succession = try contracts.decodeOwned(
            state.ControllerSuccession,
            self.a,
            try self.store.object(self.a, reference, null),
        );
        defer succession.deinit();
        if (succession.value.phase != .activated or
            succession.value.activation_event != self.event.seq)
            return error.InvalidArchive;
        const predecessor = record(
            self.archive,
            .controller_binding,
            succession.value.predecessor,
        ) orelse return error.InvalidArchive;
        var binding = try contracts.decodeOwned(
            state.ControllerBinding,
            self.a,
            try self.store.object(self.a, predecessor, null),
        );
        defer binding.deinit();
        const epoch = succession.value.activated_epoch orelse return error.InvalidArchive;
        if (epoch <= binding.value.epoch) return error.InvalidArchive;
        var result = json.object();
        try json.put(
            self.a,
            &result,
            "operation",
            json.string(try self.a.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
        );
        try json.put(self.a, &result, "phase", json.string("activated"));
        try json.put(
            self.a,
            &result,
            "epoch",
            json.string(
                try std.fmt.allocPrint(self.a, "{d}", .{
                    succession.value.activated_epoch orelse return error.InvalidArchive,
                }),
            ),
        );
        return result;
    }
    fn reconciled(self: *EventFacts) !?json.Value {
        const id = self.admission.?.reconciliation orelse return error.InvalidArchive;
        const ref = record(self.archive, .reconciliation, id) orelse return error.InvalidArchive;
        var decoded = try contracts.decodeOwned(
            state.Reconciliation,
            self.a,
            try self.store.object(self.a, ref, null),
        );
        defer decoded.deinit();
        if (decoded.value.admission_revision != self.event.revision) return error.InvalidArchive;
        var result = json.object();
        try json.put(
            self.a,
            &result,
            "reconciliation_id",
            json.string(try self.a.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
        );
        return result;
    }
    fn inputRequired(self: *EventFacts) !?json.Value {
        var id: state.Digest = undefined;
        _ = std.fmt.hexToBytes(
            &id,
            self.data.object.get("question_id").?.string,
        ) catch return error.InvalidArchive;
        const reference = record(self.archive, .question, id) orelse return error.InvalidArchive;
        const bytes = try self.store.object(self.a, reference, null);
        const question = (try contracts.decodeOwned(state.Question, self.a, bytes)).value;
        if (question.receipt) |answer| if (self.event.revision >= answer.revision)
            return error.InvalidArchive;
        self.record_id = id;
        const prompt = try self.store.object(self.a, question.prompt, null);
        return try state.questionData(self.a, question, prompt);
    }
    fn inputAccepted(self: *EventFacts) !?json.Value {
        const fact = self.admission.?;
        const id = fact.question orelse return error.InvalidArchive;
        const reference = record(self.archive, .question, id) orelse return error.InvalidArchive;
        const bytes = try self.store.object(self.a, reference, null);
        const question = (try contracts.decodeOwned(state.Question, self.a, bytes)).value;
        const receipt = question.receipt orelse return error.InvalidArchive;
        if (question.answer == null or !same(
            &storage.digest(try contracts.encodeOwned(state.Receipt, self.a, receipt)),
            &fact.receipt,
        )) return error.InvalidArchive;
        return null;
    }
    fn messageFacts(self: *EventFacts) !?json.Value {
        var id: state.Digest = undefined;
        _ = std.fmt.hexToBytes(
            &id,
            self.data.object.get("message_id").?.string,
        ) catch return error.InvalidArchive;
        if (self.event.kind == .message_queued and (self.admission.?.message == null or !same(
            &id,
            &self.admission.?.message.?,
        ))) return error.InvalidArchive;
        const reference = record(self.archive, .message, id) orelse return error.InvalidArchive;
        const bytes = try self.store.object(self.a, reference, null);
        const message = (try contracts.decodeOwned(state.Message, self.a, bytes)).value;
        self.record_id = id;
        const disposition: state.MessageDisposition = switch (self.event.kind) {
            .message_queued => .queued,
            .message_consumed => .consumed,
            .message_not_consumed => .not_consumed,
            else => unreachable,
        };
        if (disposition != .queued and
            disposition != message.disposition)
            return error.InvalidArchive;
        return try state.messageData(self.a, message, disposition);
    }
    fn imported(self: *EventFacts) !?json.Value {
        var id: state.Digest = undefined;
        _ = std.fmt.hexToBytes(
            &id,
            self.data.object.get("archive_sha256").?.string,
        ) catch return error.InvalidArchive;
        const reference = record(self.archive, .origin, id) orelse return error.InvalidArchive;
        const bytes = try self.store.object(self.a, reference, null);
        const origin = (try contracts.decodeOwned(state.Origin, self.a, bytes)).value;
        if (origin.source_revision != self.event.revision - 1) return error.InvalidArchive;
        const request_bytes = if (origin.transfer) |transfer| blk: {
            if (record(
                self.archive,
                .placement_succession,
                transfer,
            ) == null) return error.InvalidArchive;
            const Request = struct {
                method: state.Method,
                archive: state.Digest,
                transfer: state.Digest,
            };
            break :blk try contracts.encodeOwned(Request, self.a, .{
                .method = .import_checkpoint,
                .archive = id,
                .transfer = transfer,
            });
        } else blk: {
            const Request = struct { method: state.Method, archive: state.Digest };
            break :blk try contracts.encodeOwned(Request, self.a, .{
                .method = .import_checkpoint,
                .archive = id,
            });
        };
        var request_hash = std.crypto.hash.sha2.Sha256.init(.{});
        request_hash.update("agent.native.operation.v1\x00");
        request_hash.update(request_bytes);
        var request_digest: state.Digest = undefined;
        request_hash.final(&request_digest);
        if (!std.meta.eql(
            self.admission.?.request_digest,
            request_digest,
        )) return error.InvalidArchive;
        return null;
    }
    fn workspace(self: *EventFacts) !?json.Value {
        var id: state.Digest = undefined;
        _ = std.fmt.hexToBytes(
            &id,
            self.data.object.get("workspace_id").?.string,
        ) catch return error.InvalidArchive;
        if (self.admission.?.workspace == null or !same(
            &id,
            &self.admission.?.workspace.?,
        )) return error.InvalidArchive;
        return null;
    }
};

/// Every ordinary Reference is traversed structurally. The occurrence owner
/// additionally identifies its private acquired-reply digest. Unknown record
/// kinds cannot disappear through an open-ended serialization fallback.
pub fn inspect(
    a: std.mem.Allocator,
    store: *storage.Store,
    archive: state.Archive,
    supplied_build: ?[]const u8,
) !Inspected {
    const expected = try schemaSet(a, store.allocator);
    var supplied: std.ArrayList(Blob) = .empty;
    if (supplied_build) |bytes| {
        try supplied.append(a, .{ .reference = archive.build, .bytes = bytes });
        try supplied.appendSlice(a, expected.blobs);
    }
    var collector: Collector = .{ .allocator = a, .store = store, .supplied = supplied.items };
    defer collector.objects.deinit(a);
    try inspectSchemas(&collector, archive, expected);
    const task_bytes = try store.object(store.allocator, archive.task, null);
    defer store.allocator.free(task_bytes);
    var task = try contracts.decodeOwned(state.Task, store.allocator, task_bytes);
    errdefer task.deinit();
    const value = task.value;
    try collector.visit(state.Task, value);
    try inspectTask(value);
    var inspection: Inspection = .{
        .a = a,
        .store = store,
        .archive = archive,
        .value = value,
        .collector = &collector,
        .admissions = .init(a),
        .message_admissions = .init(a),
        .questions = .init(a),
        .settlements = .init(a),
        .event_next = value.event_floor,
    };
    defer inspection.deinit();
    try inspection.inspectRecords();
    try inspection.inspectOperations();
    try inspection.inspectEvents();
    try inspection.retainedFacts();
    return .{
        .task = task,
        .objects = try inspection.finalObjects(supplied_build),
        .current = inspection.current,
    };
}

fn inspectSchemas(collector: *Collector, archive: state.Archive, expected: SchemaSet) !void {
    try collector.add(archive.task);
    try collector.add(archive.build);
    if (archive.schemas.items.len != expected.schemas.len) return error.NonPortable;
    for (archive.schemas.items, expected.schemas) |declared, wanted| {
        if (!same(
            declared.name.bytes,
            wanted.name.bytes,
        ) or declared.definition.bytes != wanted.definition.bytes or !same(
            &declared.definition.digest,
            &wanted.definition.digest,
        )) return error.NonPortable;
        try collector.add(declared.definition);
    }
}

fn inspectTask(value: state.Task) !void {
    if (value.revision == 0 or value.revision > std.math.maxInt(
        i64,
    ) or
        value.execution_revision >= value.revision or
        value.event_floor == 0 or
        value.event_high < value.event_floor or
        value.event_high > std.math.maxInt(
            i64,
        )) return error.CorruptState;
}

const Inspection = struct {
    a: std.mem.Allocator,
    store: *storage.Store,
    archive: state.Archive,
    value: state.Task,
    collector: *Collector,
    current: ?occurrence.Occurrence = null,
    inference_attempts: u64 = 0,
    inference_bytes: u64 = 0,
    admissions: AdmissionFacts,
    message_admissions: std.AutoHashMap(state.Digest, u64),
    last_nonterminal_revision: u64 = 0,
    terminal: ?EventPosition = null,
    nonterminal_event: bool = false,
    questions: RecordEvents,
    settlements: RecordEvents,
    event_next: u64,
    event_revision: u64 = 0,

    fn deinit(self: *Inspection) void {
        self.admissions.deinit();
        self.message_admissions.deinit();
        self.questions.deinit();
        self.settlements.deinit();
    }
    fn inspectRecords(self: *Inspection) !void {
        for (self.archive.records.items, 0..) |row, index| {
            for (self.archive.records.items[0..index]) |prior| if (prior.kind == row.kind and same(
                &prior.id,
                &row.id,
            )) return error.InvalidArchive;
            try self.collector.add(row.body);
            const bytes = try self.store.object(self.store.allocator, row.body, null);
            defer self.store.allocator.free(bytes);
            inline for (@typeInfo(state.RecordKind).@"enum".field_names) |kind| {
                if (row.kind == @field(state.RecordKind, kind)) {
                    const T = storage.Record(kind);
                    var decoded = try contracts.decodeOwned(T, self.store.allocator, bytes);
                    defer decoded.deinit();
                    try self.inspectRecord(kind, row, decoded.value);
                }
            }
        }

        if (self.inference_attempts != self.value.inference_attempts or
            self.inference_bytes != self.value.inference_request_bytes or
            (self.value.current_occurrence != null) != (self.current != null) or
            (self.value.outcome_kind == .requested) != (self.current != null))
            return error.CorruptState;
        if (self.current) |pending| if (pending.state == .awaiting and record(
            self.archive,
            .question,
            pending.state.awaiting.question,
        ) == null) return error.CorruptState;
        for (self.value.messages.items, 0..) |id, i| {
            if (record(self.archive, .message, id) == null) return error.CorruptState;
            for (self.value.messages.items[0..i]) |prior| if (same(&id, &prior))
                return error.CorruptState;
        }
    }
    fn inspectRecord(
        self: *Inspection,
        comptime kind: []const u8,
        row: state.ArchiveRecord,
        item: storage.Record(kind),
    ) !void {
        const T = storage.Record(kind);
        if (comptime @hasField(T, "id")) if (!same(&item.id, &row.id)) return error.CorruptState;
        if (comptime same(kind, "artifact")) {
            if (item.task == null or !same(
                &item.task.?,
                &self.value.id,
            )) return error.CorruptState;
            const published = self.value.result_artifact orelse return error.InvalidArchive;
            if (!same(&published, &item.id)) return error.InvalidArchive;
        } else if (!same(&item.task, &self.value.id)) return error.CorruptState;
        try self.collector.visit(T, item);
        if (T == state.Reconciliation) try state.visitReconciliationHistory(
            self.a,
            self.store,
            item,
            self.collector,
        );
        if (comptime same(kind, "placement_action")) try self.placementAction(item);
        if (comptime same(kind, "placement_control")) try self.placementControl(item);
        if (comptime same(kind, "placement_move")) try self.placementMove(item);
        if (comptime same(kind, "placement_behavior")) try self.placementBehavior(item);
        if (comptime same(kind, "placement_succession")) try self.placementSuccession(item);

        try self.recordState(kind, row, item);
    }
    fn recordState(
        self: *Inspection,
        comptime kind: []const u8,
        row: state.ArchiveRecord,
        item: storage.Record(kind),
    ) !void {
        if (comptime same(kind, "occurrence")) {
            switch (item.state) {
                .dispatching => return error.UnsettledOccurrence,
                .settled_reply, .admitted => {},
                else => {},
            }
            if (self.value.current_occurrence) |id| if (same(&id, &item.id)) {
                if (item.state == .admitted) return error.CorruptState;
                self.current = item;
            };
        } else if (comptime same(kind, "attempt")) {
            if (item.inference) {
                self.inference_attempts = try std.math.add(u64, self.inference_attempts, 1);
                self.inference_bytes = try std.math.add(
                    u64,
                    self.inference_bytes,
                    if (item.prepared) |body| body.bytes else item.request.bytes,
                );
            }
        } else if (comptime same(kind, "capture")) {
            if ((item.disposition == .complete) != (item.response != null) or
                (item.projection != null and
                    item.disposition != .complete))
                return error.CorruptState;
            if (!same(&item.attempt, &row.id) or record(
                self.archive,
                .attempt,
                item.attempt,
            ) == null) return error.CorruptState;
        } else if (comptime same(kind, "message")) {
            // Pending membership is an equality, not just validation
            // of whichever queue entries the archive retained.
            var queued = false;
            for (self.value.messages.items) |id| if (same(&id, &item.id)) {
                queued = true;
                break;
            };
            if (queued != (item.disposition == .queued or
                item.disposition == .acquired))
                return error.InvalidArchive;
        } else if (comptime same(kind, "origin")) {
            if (item.source_revision == 0 or
                item.source_revision >= self.value.revision)
                return error.CorruptState;
        }
    }
    fn placementAction(self: *Inspection, item: storage.Record("placement_action")) !void {
        const p = @import("placement.zig");
        try p.verify(p.Action, self.a, item.action, item.action.value.owner);
        if (!std.meta.eql(item.id, item.action.value.id) or
            !std.meta.eql(item.task, item.action.value.task) or
            !std.meta.eql(
                item.id,
                p.operationId(
                    item.action.value.owner,
                    item.task,
                    item.action.value.operation.bytes,
                    .action,
                ),
            )) return error.InvalidArchive;
    }
    fn placementControl(self: *Inspection, item: storage.Record("placement_control")) !void {
        const p = @import("placement.zig");
        try p.verify(p.Control, self.a, item.control, item.control.value.controller);
        if (!std.meta.eql(item.id, p.controlId(item.control.value)) or !std.meta.eql(
            item.task,
            item.control.value.subject.task,
        )) return error.InvalidArchive;
        _ = try p.routeHead(self.a, item.control.value, item.route.items);
        if (item.report) |report| {
            try p.matchReport(self.a, item.control.value, item.route.items, report);
        }
    }
    fn placementMove(self: *Inspection, item: storage.Record("placement_move")) !void {
        const p = @import("placement.zig");
        const action_bytes = try self.store.object(self.a, item.action, null);
        defer self.a.free(action_bytes);
        var action = try contracts.decodeOwned(p.ActionRecord, self.a, action_bytes);
        defer action.deinit();
        try p.verify(p.Action, self.a, action.value.action, item.owner);
        if (action.value.action.value.request != .move or !std.meta.eql(
            item.task,
            action.value.task,
        ) or
            !std.meta.eql(
                item.id,
                p.operationId(item.owner, item.task, item.request.operation.bytes, .move),
            )) return error.InvalidArchive;
        if (!std.meta.eql(item.subject.task, item.task)) return error.InvalidArchive;
        switch (item.request.subject) {
            .controller => if (item.subject.work != null) return error.InvalidArchive,
            .work => |ref| {
                if (ref.kind != .work or
                    ref.id.bytes.len != 64 or
                    item.subject.work == null)
                    return error.InvalidArchive;
                var expected_work: state.Digest = undefined;
                _ = std.fmt.hexToBytes(
                    &expected_work,
                    ref.id.bytes,
                ) catch return error.InvalidArchive;
                if (!std.meta.eql(
                    expected_work,
                    item.subject.work.?,
                )) return error.InvalidArchive;
            },
        }
        const wanted = try contracts.encodeOwned(
            @TypeOf(item.request),
            self.a,
            action.value.action.value.request.move,
        );
        defer self.a.free(wanted);
        const actual = try contracts.encodeOwned(
            @TypeOf(item.request),
            self.a,
            item.request,
        );
        defer self.a.free(actual);
        if (!same(wanted, actual)) return error.InvalidArchive;
    }
    fn placementBehavior(self: *Inspection, item: storage.Record("placement_behavior")) !void {
        const p = @import("placement.zig");
        const behavior = item.decision.value;
        try p.verify(p.Behavior, self.a, item.decision, behavior.owner);
        if (!std.meta.eql(item.id, behavior.operation) or
            !std.meta.eql(item.task, behavior.task) or
            behavior.epoch != try std.math.add(
                u64,
                behavior.previous_epoch,
                1,
            ) or std.meta.eql(
            behavior.predecessor,
            behavior.successor,
        )) return error.InvalidArchive;
    }
    fn placementSuccession(self: *Inspection, item: storage.Record("placement_succession")) !void {
        const p = @import("placement.zig");
        try p.verify(p.Offer, self.a, item.offer, item.offer.value.intent.source);
        try p.matchDecision(self.a, item.offer.value, item.decision);
        if (item.decision.value.verdict != .accepted or !std.meta.eql(
            item.id,
            item.decision.value.transfer,
        ) or
            !std.meta.eql(
                item.task,
                item.offer.value.intent.subject.task,
            )) return error.InvalidArchive;
    }
    fn inspectOperations(self: *Inspection) !void {
        for (self.archive.operations.items, 0..) |row, i| {
            try self.inspectOperation(row, i);
        }
    }
    fn inspectOperation(self: *Inspection, row: state.ArchiveOperation, i: usize) !void {
        for (self.archive.operations.items[0..i]) |prior| if (same(
            row.key.bytes,
            prior.key.bytes,
        )) return error.InvalidArchive;
        try self.collector.add(row.body);
        const bytes = try self.store.object(self.store.allocator, row.body, null);
        defer self.store.allocator.free(bytes);
        var decoded = try contracts.decodeOwned(state.Receipt, self.store.allocator, bytes);
        defer decoded.deinit();
        try self.collector.visit(state.Receipt, decoded.value);
        try state.visitWorkspaceReceipt(self.a, self.store, decoded.value, self.collector);
        if (!same(&decoded.value.task, &self.value.id) or !same(
            &decoded.value.request_digest,
            &row.request,
        ) or
            decoded.value.revision == 0 or
            decoded.value.revision > self.value.revision)
            return error.CorruptState;
        try self.receiptFacts(row, decoded.value);
    }
    fn receiptFacts(self: *Inspection, row: state.ArchiveOperation, receipt: state.Receipt) !void {
        // Kosmos cannot attest control which the host acknowledged but has not
        // applied yet. A nonterminal task must retain that durable intent.
        // A cancellation requested after termination need not create intent.
        if (receipt.method == .cancel and
            !self.value.terminal() and
            self.value.cancellation == null)
            return error.InvalidArchive;
        switch (receipt.method) {
            .submit,
            .respond,
            .message,
            .@"resume",
            .adopt,
            => self.last_nonterminal_revision = @max(
                self.last_nonterminal_revision,
                receipt.revision,
            ),
            .cancel, .import_checkpoint, .workspace, .reconcile => {},
        }
        const fact: AdmissionFact = .{
            .request_digest = receipt.request_digest,
            .method = receipt.method,
            .receipt = row.body.digest,
            .question = receipt.question,
            .message = receipt.message,
            .reconciliation = receipt.reconciliation,
            .workspace = receipt.workspace,
        };
        const entry = try self.admissions.getOrPut(receipt.revision);
        if (entry.found_existing and !std.meta.eql(
            entry.value_ptr.*,
            fact,
        )) return error.InvalidArchive;
        entry.value_ptr.* = fact;
        try self.receiptMembership(receipt);
    }
    fn receiptMembership(self: *Inspection, receipt: state.Receipt) !void {
        // An acknowledged follow-up cannot disappear by deleting both its row
        // and its queue entry while retaining the immutable admission receipt.
        if (receipt.method == .message and receipt.message == null) return error.InvalidArchive;
        if (receipt.message) |id| {
            if (record(self.archive, .message, id) == null) return error.InvalidArchive;
            const admitted = try self.message_admissions.getOrPut(id);
            if (admitted.found_existing) return error.InvalidArchive;
            admitted.value_ptr.* = receipt.revision;
        }
        if (receipt.method == .respond and receipt.question == null) return error.InvalidArchive;
        if (receipt.question) |id| if (record(
            self.archive,
            .question,
            id,
        ) == null) return error.InvalidArchive;
        if ((receipt.method == .reconcile) != (receipt.reconciliation != null))
            return error.InvalidArchive;
        if (receipt.reconciliation) |id| try self.reconciliationReceipt(receipt, id);
    }
    fn reconciliationReceipt(self: *Inspection, receipt: state.Receipt, id: state.Digest) !void {
        const ref = record(self.archive, .reconciliation, id) orelse return error.InvalidArchive;
        var recovery = try contracts.decodeOwned(
            state.Reconciliation,
            self.a,
            try self.store.object(self.a, ref, null),
        );
        defer recovery.deinit();
        if (recovery.value.admission_revision != receipt.revision or !std.meta.eql(
            recovery.value.request_digest,
            receipt.request_digest,
        ) or !same(
            recovery.value.client_operation_id.bytes,
            receipt.client_operation_id.bytes,
        )) return error.InvalidArchive;
        const occurrence_ref = record(
            self.archive,
            .occurrence,
            recovery.value.occurrence,
        ) orelse return error.InvalidArchive;
        var pending = try contracts.decodeOwned(
            occurrence.Occurrence,
            self.a,
            try self.store.object(self.a, occurrence_ref, null),
        );
        defer pending.deinit();
        if (pending.value.residual == null) self.last_nonterminal_revision = @max(
            self.last_nonterminal_revision,
            receipt.revision,
        );
    }
    fn inspectEvents(self: *Inspection) !void {
        var root_history: state.RootHistory = .init(self.value);
        for (self.archive.events.items) |row| try self.inspectEvent(row, &root_history);
        if (self.event_next - 1 != self.value.event_high) return error.CorruptState;
        try root_history.finish(self.value);
    }
    fn inspectEvent(
        self: *Inspection,
        row: state.ArchiveEvent,
        root_history: *state.RootHistory,
    ) !void {
        if (row.seq != self.event_next or
            row.revision == 0 or
            row.revision < self.event_revision or
            row.revision > self.value.revision)
            return error.CorruptState;
        try self.collector.add(row.body);
        const bytes = try self.store.object(self.store.allocator, row.body, null);
        defer self.store.allocator.free(bytes);
        var decoded = try contracts.decodeOwned(state.Event, self.store.allocator, bytes);
        defer decoded.deinit();
        try self.collector.visit(state.Event, decoded.value);
        try root_history.observe(decoded.value);
        try state.visitWorkspaceEvent(self.a, self.store, row.body, decoded.value, self.collector);
        if (!same(
            &decoded.value.task,
            &self.value.id,
        ) or
            decoded.value.seq != row.seq or
            decoded.value.revision != row.revision)
            return error.CorruptState;
        try @import("schemas.zig").validateEventData(
            self.store.allocator,
            decoded.value.kind,
            decoded.value.data.bytes,
        );
        const identity = try validateEventFacts(
            self.store,
            self.archive,
            self.value,
            &self.admissions,
            decoded.value,
        );
        if (admissionMethod(decoded.value.kind) != null) {
            const admitted = self.admissions.getPtr(decoded.value.revision).?;
            if (admitted.event_seen) return error.InvalidArchive;
            admitted.event_seen = true;
        }
        const position: EventPosition = .{ .revision = row.revision, .seq = row.seq };
        const records: ?*RecordEvents = switch (decoded.value.kind) {
            .input_required => &self.questions,
            .message_consumed, .message_not_consumed => &self.settlements,
            else => null,
        };
        if (records) |index| {
            const entry = try index.getOrPut(identity.?);
            if (entry.found_existing) return error.InvalidArchive;
            entry.value_ptr.* = position;
        }
        try self.eventPosition(decoded.value, position);
        self.event_next += 1;
        self.event_revision = row.revision;
    }
    fn eventPosition(self: *Inspection, event: state.Event, position: EventPosition) !void {
        switch (event.kind) {
            .completed, .failed, .cancelled => {
                if (self.terminal != null or
                    event.revision <= self.last_nonterminal_revision)
                    return error.InvalidArchive;
                self.terminal = position;
            },
            // These are the only publications that may follow termination.
            .cancellation_requested,
            .imported,
            .message_not_consumed,
            .workspace,
            .workspace_progress,
            => {},
            .reconciled, .workspace_read => {
                const occurrence_id = try self.eventOccurrence(event);
                const occurrence_ref = record(
                    self.archive,
                    .occurrence,
                    occurrence_id,
                ) orelse return error.InvalidArchive;
                var pending = try contracts.decodeOwned(
                    occurrence.Occurrence,
                    self.a,
                    try self.store.object(self.a, occurrence_ref, null),
                );
                defer pending.deinit();
                if (pending.value.residual == null) {
                    if (self.terminal != null) return error.InvalidArchive;
                    self.nonterminal_event = true;
                }
            },
            else => {
                if (self.terminal != null) return error.InvalidArchive;
                self.nonterminal_event = true;
            },
        }
    }
    fn eventOccurrence(self: *Inspection, event: state.Event) !state.Digest {
        return if (event.kind == .reconciled) id: {
            const admission = self.admissions.get(
                event.revision,
            ) orelse return error.InvalidArchive;
            const reconciliation_id = admission.reconciliation orelse return error.InvalidArchive;
            const ref = record(
                self.archive,
                .reconciliation,
                reconciliation_id,
            ) orelse return error.InvalidArchive;
            var recovery = try contracts.decodeOwned(
                state.Reconciliation,
                self.a,
                try self.store.object(self.a, ref, null),
            );
            defer recovery.deinit();
            break :id recovery.value.occurrence;
        } else id: {
            var data = try json.parse(self.a, event.data.bytes, .{});
            defer data.deinit();
            const text = try json.text(
                json.get(data.value, "occurrence_id") orelse return error.InvalidArchive,
            );
            var id: state.Digest = undefined;
            _ = std.fmt.hexToBytes(&id, text) catch return error.InvalidArchive;
            break :id id;
        };
    }
    fn retainedFacts(self: *Inspection) !void {
        // Supplied events must agree with their facts, and facts whose events are
        // known to be retained must be represented. Prefix pruning may cut through
        // a revision, so only later revisions are certain when the floor is >1.
        const first_revision = self.archive.events.items[0].revision;
        var omitted: u64 = 0;
        var facts = self.admissions.iterator();
        while (facts.next()) |fact| {
            if (!fact.value_ptr.event_seen) {
                if (fact.key_ptr.* > first_revision) return error.InvalidArchive;
                omitted += 1;
            }
        }
        // These admissions require a nonterminal task. Its terminal transition is
        // later, so a suffix retaining that revision must retain the outcome event.
        if (self.value.terminal() and self.terminal == null) {
            if (self.last_nonterminal_revision >= first_revision or
                self.nonterminal_event)
                return error.InvalidArchive;
            omitted += 1;
        }
        // Question creation and message settlement are owned facts too, although
        // they do not each mint an operation receipt. Preserve their projections
        // whenever the retained range proves they cannot have been pruned.
        for (self.archive.records.items) |row| omitted += try self.omittedRecord(
            row,
            first_revision,
        );
        // Each fact above has one distinct publication. Even unknown prefix
        // timing cannot hide more publications than the number of pruned events.
        if (omitted > self.value.event_floor - 1) return error.InvalidArchive;
    }
    fn omittedRecord(self: *Inspection, row: state.ArchiveRecord, first_revision: u64) !u64 {
        if (row.kind == .question) {
            if (!self.questions.contains(row.id)) return 1;
        } else if (row.kind == .message) {
            const admitted = self.message_admissions.get(row.id) orelse return error.InvalidArchive;
            const bytes = try self.store.object(self.store.allocator, row.body, null);
            defer self.store.allocator.free(bytes);
            var decoded = try contracts.decodeOwned(state.Message, self.store.allocator, bytes);
            defer decoded.deinit();
            const disposition = decoded.value.disposition;
            if (disposition == .queued or disposition == .acquired) return 0;
            if (self.settlements.get(row.id)) |event| {
                if (event.revision <= admitted) return error.InvalidArchive;
                if (disposition == .not_consumed) {
                    if (!self.value.terminal()) return error.InvalidArchive;
                    if (self.terminal) |outcome| {
                        if (event.revision != outcome.revision or
                            event.seq <= outcome.seq)
                            return error.InvalidArchive;
                    } else if (self.value.event_floor == 1 or
                        event.revision != first_revision)
                        return error.InvalidArchive;
                }
            } else {
                if (admitted >= first_revision) return error.InvalidArchive;
                return 1;
            }
        }

        return 0;
    }
    fn finalObjects(self: *Inspection, supplied_build: ?[]const u8) ![]state.Reference {
        const objects = try self.a.dupe(state.Reference, self.collector.objects.values());
        std.mem.sort(state.Reference, objects, {}, struct {
            fn less(_: void, left: state.Reference, right: state.Reference) bool {
                return std.mem.order(u8, &left.digest, &right.digest) == .lt;
            }
        }.less);
        if (supplied_build == null) {
            if (objects.len != self.archive.objects.items.len) return error.InvalidArchive;
            for (objects, self.archive.objects.items) |actual, declared| {
                if (actual.bytes != declared.bytes or !same(&actual.digest, &declared.digest))
                    return error.InvalidArchive;
            }
        }

        return objects;
    }
};

/// Current retained data for disclosure of a control message or observation.
/// Unlike a movable execution archive, this may include an active occurrence:
/// examining its bytes cannot activate it at another owner.
pub fn disclosureClosure(
    a: std.mem.Allocator,
    store: *storage.Store,
    task: state.TaskId,
) ![]state.Reference {
    try store.checkIntegrity();
    var query = try store.database.prepare(
        \\WITH RECURSIVE roots(digest) AS (
        \\ SELECT body FROM tasks WHERE id=? UNION SELECT body FROM records WHERE task=?
        \\ UNION SELECT body FROM events WHERE task=? UNION SELECT receipt FROM operations WHERE task=?
        \\), reachable(digest) AS (
        \\ SELECT digest FROM roots UNION SELECT d.child FROM dependencies d JOIN reachable r ON d.parent=r.digest
        \\) SELECT o.digest,length(o.body) FROM objects o JOIN reachable r ON o.digest=r.digest ORDER BY o.digest
    , &.{ .{ .blob = &task }, .{ .blob = &task }, .{ .blob = &task }, .{ .blob = &task } });
    defer query.deinit();
    var result: std.ArrayList(state.Reference) = .empty;
    errdefer result.deinit(a);
    while (try query.step() == .row) {
        const id = try query.bytes(0);
        const length = try query.integer(1);
        if (id.len != 32 or length < 0) return error.CorruptState;
        try result.append(a, .{ .digest = id[0..32].*, .bytes = @intCast(length) });
    }
    return result.toOwnedSlice(a);
}

/// Build a complete immutable index while the caller owns its snapshot scope.
/// A caller retaining it beyond the current store state must retain its edges.
pub fn prepare(
    a: std.mem.Allocator,
    store: *storage.Store,
    task: state.TaskId,
    build: []const u8,
) !state.Archive {
    var manifest = try store.archiveIndex(a, task, .{
        .digest = storage.digest(build),
        .bytes = build.len,
    });
    const definitions = try schemaSet(a, store.allocator);
    manifest.schemas.items = definitions.schemas;
    var inspected = try inspect(a, store, manifest, build);
    defer inspected.task.deinit();
    manifest.objects.items = inspected.objects;
    return manifest;
}

/// The transaction retaining a prepared snapshot must also retain the supplied
/// build and schema bytes. All other objects already belong to the Store.
pub fn retainAssets(a: std.mem.Allocator, store: *storage.Store, build: []const u8) !void {
    _ = try store.putObject(build);
    const definitions = try schemaSet(a, store.allocator);
    for (definitions.blobs) |blob| _ = try store.putObject(blob.bytes);
}

pub fn write(
    a: std.mem.Allocator,
    io: std.Io,
    store: *storage.Store,
    task: state.TaskId,
    build: []const u8,
    path: []const u8,
    state_directory: c_int,
) !Exported {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const manifest = try prepare(arena.allocator(), store, task, build);
    return writeManifest(a, io, store, manifest, build, path, state_directory, false);
}

fn sameReferences(left: []const state.Reference, right: []const state.Reference) bool {
    if (left.len != right.len) return false;
    for (left, right) |lhs, rhs| if (!std.meta.eql(lhs, rhs)) return false;
    return true;
}

pub fn writePrepared(
    a: std.mem.Allocator,
    io: std.Io,
    store: *storage.Store,
    manifest: state.Archive,
    build: []const u8,
    path: []const u8,
    state_directory: c_int,
) !Exported {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var inspected = try inspect(arena.allocator(), store, manifest, build);
    defer inspected.task.deinit();
    if (!std.meta.eql(
        storage.digest(build),
        manifest.build.digest,
    ) or build.len != manifest.build.bytes or
        !sameReferences(inspected.objects, manifest.objects.items)) return error.InvalidArchive;
    return writeManifest(a, io, store, manifest, build, path, state_directory, true);
}

fn writeManifest(
    a: std.mem.Allocator,
    io: std.Io,
    store: *storage.Store,
    manifest: state.Archive,
    build: []const u8,
    path: []const u8,
    state_directory: c_int,
    replay: bool,
) !Exported {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    const definitions = try schemaSet(temporary, store.allocator);
    const schema = try values.schemaBytes(state.Archive, temporary);
    const encoded = try contracts.encodeOwned(state.Archive, temporary, manifest);
    const header = try archiveHeader(manifest, schema.len, encoded.len);
    var output = try Output.open(a, io, path, state_directory);
    defer output.deinit();
    try output.write(&header);
    try output.write(schema);
    try output.write(encoded);
    try writeArchiveObjects(a, store, manifest, build, definitions, &output);
    return finishArchive(a, path, &output, replay);
}

fn archiveHeader(manifest: state.Archive, schema_len: usize, encoded_len: usize) ![32]u8 {
    var total: u64 = 0;
    for (manifest.objects.items) |ref| total = try std.math.add(u64, total, ref.bytes);
    var header: [32]u8 = @splat(0);
    @memcpy(header[0..8], magic);
    std.mem.writeInt(
        u32,
        header[8..12],
        std.math.cast(u32, schema_len) orelse return error.Capacity,
        .little,
    );
    std.mem.writeInt(
        u32,
        header[12..16],
        std.math.cast(u32, encoded_len) orelse return error.Capacity,
        .little,
    );
    std.mem.writeInt(
        u32,
        header[16..20],
        std.math.cast(u32, manifest.objects.items.len) orelse return error.Capacity,
        .little,
    );
    std.mem.writeInt(u64, header[24..32], total, .little);
    return header;
}

fn writeArchiveObjects(
    a: std.mem.Allocator,
    store: *storage.Store,
    manifest: state.Archive,
    build: []const u8,
    definitions: SchemaSet,
    output: *Output,
) !void {
    for (manifest.objects.items) |ref| {
        var supplied: ?[]const u8 = if (same(&ref.digest, &manifest.build.digest)) build else null;
        for (definitions.blobs) |blob| if (same(&ref.digest, &blob.reference.digest)) {
            supplied = blob.bytes;
            break;
        };
        if (supplied) |content| {
            // A supplied immutable schema/build asset is not a license to mask
            // corruption of a previously imported copy in the same store.
            const prior = store.object(a, ref, null) catch |err| switch (err) {
                error.MissingArtifact => null,
                else => return err,
            };
            if (prior) |bytes| {
                defer a.free(bytes);
                if (!same(bytes, content)) return error.CorruptState;
            }
            try output.write(content);
        } else {
            try store.writeObject(ref, output);
        }
    }
}

fn finishArchive(a: std.mem.Allocator, path: []const u8, output: *Output, replay: bool) !Exported {
    return output.finish() catch |err| {
        if (!replay or err != error.AlreadyExists) return err;
        // A crash may publish the file before its signed offer. Compare every
        // byte with the retained snapshot, including all sibling records.
        var expected: state.Digest = undefined;
        output.hash.final(&expected);
        var retained = try Reader.open(a, path);
        defer retained.deinit();
        if (!std.meta.eql(
            retained.identity,
            expected,
        ) or retained.bytes != output.bytes) return error.InvalidTransfer;
        // The interrupted writer may have linked before syncing the directory.
        // The offer can become durable only after both retained bytes and name.
        if (c.fsync(retained.fd) != 0 or
            c.fsync(output.directory) != 0)
            return error.StorageUnavailable;
        return .{ .sha256 = expected, .bytes = output.bytes };
    };
}
