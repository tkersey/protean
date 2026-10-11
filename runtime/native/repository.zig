//! Immutable read-only repository snapshots. Filesystem capture is explicit;
//! subsequent tools read only these frozen bytes and never execute repository code.
const std = @import("std");
const contracts = @import("protean_contracts");
const storage = @import("store.zig");
const c = @import("native_c");

pub const maximum_files = 512;
pub const maximum_file_bytes = 256 * 1024;
pub const maximum_snapshot_bytes = storage.maximum_object_bytes;
pub const File = contracts.RepositorySnapshotFile;
pub const Record = contracts.RepositorySnapshot;

pub fn pathAllowed(path: []const u8) bool {
    if (path.len == 0 or path.len > 256 or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\') return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

pub const Snapshot = struct {
    decoded: contracts.Decoded(Record),
    identity: [32]u8,

    pub fn open(a: std.mem.Allocator, bytes: []const u8) !Snapshot {
        return openWithOwnership(a, bytes, false);
    }
    /// The profile owns these immutable bytes for the entire adapter lifetime.
    pub fn openBorrowed(a: std.mem.Allocator, bytes: []const u8) !Snapshot {
        return openWithOwnership(a, bytes, true);
    }
    fn openWithOwnership(a: std.mem.Allocator, bytes: []const u8, comptime borrowed: bool) !Snapshot {
        if (bytes.len > maximum_snapshot_bytes) return error.SnapshotCapacity;
        var record = if (borrowed) try contracts.decodeBorrowed(Record, a, bytes) else try contracts.decodeOwned(Record, a, bytes);
        errdefer record.deinit();
        if (record.value.version != 1) return error.UnsupportedSnapshot;
        var previous: ?[]const u8 = null;
        for (record.value.files.items) |file| {
            if (!pathAllowed(file.path.bytes) or (previous != null and !std.mem.lessThan(u8, previous.?, file.path.bytes)) or
                !std.mem.eql(u8, &storage.digest(file.contents.bytes), &file.sha256)) return error.InvalidSnapshot;
            previous = file.path.bytes;
        }
        return .{ .decoded = record, .identity = storage.digest(bytes) };
    }
    pub fn deinit(self: *Snapshot) void {
        self.decoded.deinit();
        self.* = undefined;
    }
    pub fn files(self: Snapshot) []const File {
        return self.decoded.value.files.items;
    }
    pub fn get(self: Snapshot, path: []const u8) ?File {
        if (!pathAllowed(path)) return null;
        // A bounded sorted catalog, with no filesystem or ambient lookup.
        var low: usize = 0;
        var high = self.files().len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const file = self.files()[middle];
            switch (std.mem.order(u8, file.path.bytes, path)) {
                .eq => return file,
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    payload_allocator: std.mem.Allocator,
    io: std.Io,
    files: std.ArrayList(File) = .empty,
    bytes: usize = 0,
    excluded: u32 = 0,
    visited: usize = 0,

    fn walk(self: *Collector, directory: std.Io.Dir, prefix: []const u8, depth: usize) anyerror!void {
        if (depth > 32) return error.SnapshotCapacity;
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            self.visited += 1;
            if (self.visited > 4096) return error.SnapshotCapacity;
            // These named administrative/build trees are outside this profile.
            // Count every excluded entry and expose it in the frozen record.
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "node_modules")) {
                self.excluded += 1;
                continue;
            }
            const path = if (prefix.len == 0) try self.allocator.dupe(u8, entry.name) else try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            if (!pathAllowed(path)) return error.InvalidSnapshotPath;
            switch (entry.kind) {
                .directory => {
                    const child = try directory.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                    defer child.close(self.io);
                    try self.walk(child, path, depth + 1);
                },
                .file => {
                    if (self.files.items.len == maximum_files) return error.SnapshotCapacity;
                    const name = try self.allocator.dupeSentinel(u8, entry.name, 0);
                    // A path can change after readdir. O_NONBLOCK prevents a
                    // replacement FIFO from blocking before fstat rejects it.
                    const fd = c.openat(directory.handle, name.ptr, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOCTTY);
                    if (fd < 0) return error.SnapshotIo;
                    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
                    defer file.close(self.io);
                    const before = try file.stat(self.io);
                    if (before.kind != .file) return error.UnsupportedSnapshotEntry;
                    if (before.size > maximum_file_bytes or before.size > maximum_snapshot_bytes - self.bytes) return error.SnapshotCapacity;
                    var buffer: [4096]u8 = undefined;
                    var reader = file.reader(self.io, &buffer);
                    const bytes = try self.payload_allocator.alloc(u8, @intCast(before.size));
                    errdefer self.payload_allocator.free(bytes);
                    reader.interface.readSliceAll(bytes) catch |err| return if (err == error.EndOfStream) error.SnapshotChanged else err;
                    if (reader.interface.takeByte()) |_| return error.SnapshotChanged else |err| if (err != error.EndOfStream) return err;
                    const after = try file.stat(self.io);
                    if (bytes.len != before.size or before.size != after.size or before.inode != after.inode or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) return error.SnapshotChanged;
                    self.bytes += bytes.len;
                    try self.files.append(self.allocator, .{ .path = .{ .bytes = path }, .sha256 = storage.digest(bytes), .contents = .{ .bytes = bytes } });
                },
                // In particular, never follow repository symlinks or open a
                // FIFO/device that could block or access another resource.
                else => return error.UnsupportedSnapshotEntry,
            }
        }
    }
};

pub fn capture(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    return captureWithScratch(a, a, io, root);
}

/// Keep temporary file buffers out of an output arena whose lifetime is the
/// whole task profile. Both allocators remain charged to the host budget.
pub fn captureWithScratch(a: std.mem.Allocator, scratch: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
    defer directory.close(io);
    var collector: Collector = .{ .allocator = arena.allocator(), .payload_allocator = scratch, .io = io };
    defer for (collector.files.items) |file| scratch.free(file.contents.bytes);
    try collector.walk(directory, "", 0);
    std.mem.sort(File, collector.files.items, {}, struct {
        fn less(_: void, left: File, right: File) bool {
            return std.mem.lessThan(u8, left.path.bytes, right.path.bytes);
        }
    }.less);
    const bytes = try contracts.encodeOwned(Record, a, .{ .version = 1, .excluded_entries = collector.excluded, .files = .{ .items = collector.files.items } });
    errdefer a.free(bytes);
    if (bytes.len > maximum_snapshot_bytes) return error.SnapshotCapacity;
    return bytes;
}

test "snapshot admission binds sorted paths and exact frozen content" {
    const a = std.testing.allocator;
    const source = "fn main() void {}\n";
    var files = [_]File{.{ .path = .{ .bytes = "src/main.zig" }, .sha256 = storage.digest(source), .contents = .{ .bytes = source } }};
    const bytes = try contracts.encodeOwned(Record, a, .{ .version = 1, .excluded_entries = 0, .files = .{ .items = &files } });
    defer a.free(bytes);
    var snapshot = try Snapshot.open(a, bytes);
    defer snapshot.deinit();
    var borrowed = try Snapshot.openBorrowed(a, bytes);
    defer borrowed.deinit();
    try std.testing.expectEqualDeep(snapshot.decoded.value, borrowed.decoded.value);
    const view = borrowed.get("src/main.zig").?.contents.bytes;
    try std.testing.expect(@intFromPtr(view.ptr) >= @intFromPtr(bytes.ptr));
    try std.testing.expect(@intFromPtr(view.ptr) + view.len <= @intFromPtr(bytes.ptr) + bytes.len);
    try std.testing.expectEqualStrings(source, snapshot.get("src/main.zig").?.contents.bytes);
    try std.testing.expect(snapshot.get("../src/main.zig") == null);
    files[0].sha256[0] ^= 1;
    const changed = try contracts.encodeOwned(Record, a, .{ .version = 1, .excluded_entries = 0, .files = .{ .items = &files } });
    defer a.free(changed);
    try std.testing.expectError(error.InvalidSnapshot, Snapshot.open(a, changed));
    try std.testing.expectError(error.InvalidSnapshot, Snapshot.openBorrowed(a, changed));
    try std.testing.expectError(error.Truncated, Snapshot.openBorrowed(a, bytes[0 .. bytes.len - 1]));
    for ([_][]const u8{ "/absolute", "../escape", "a/../b", "a//b", "a\\b", "./a" }) |path| try std.testing.expect(!pathAllowed(path));
    try std.testing.expect(pathAllowed("src/雪.zig"));
}

test "capture freezes bytes, reports exclusions and refuses repository symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "z.zig", .data = "old\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "雪\n" });
    try temporary.dir.createDir(io, ".git", .default_dir);
    var path: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path);
    const bytes = try capture(a, io, path[0..length]);
    defer a.free(bytes);
    var snapshot = try Snapshot.open(a, bytes);
    defer snapshot.deinit();
    try std.testing.expectEqual(1, snapshot.decoded.value.excluded_entries);
    try std.testing.expectEqualStrings("a.zig", snapshot.files()[0].path.bytes);
    const repeated = try capture(a, io, path[0..length]);
    defer a.free(repeated);
    try std.testing.expectEqualSlices(u8, bytes, repeated);
    try temporary.dir.writeFile(io, .{ .sub_path = "z.zig", .data = "new\n" });
    try std.testing.expectEqualStrings("old\n", snapshot.get("z.zig").?.contents.bytes);
    try temporary.dir.symLink(io, "z.zig", "link.zig", .{});
    try std.testing.expectError(error.UnsupportedSnapshotEntry, capture(a, io, path[0..length]));
}

/// Bounded snapshot queries shared by fixed and adaptive applications.
/// Application-owned records keep their published schema identities.
pub fn Tools(comptime t: type) type {
    return struct {
        pub fn list(a: std.mem.Allocator, snapshot: Snapshot, request: t.ListRequest) !t.ListObservation {
            // These are bounded lexical selectors over admitted snapshot paths, not
            // filesystem paths. A directory prefix such as "src/" is valid; a prefix
            // that matches no admitted path simply produces an empty page.
            var entries: std.ArrayList(t.ListEntry) = .empty;
            var truncated = false;
            for (snapshot.files()) |file| {
                if (!std.mem.startsWith(u8, file.path.bytes, request.prefix.bytes) or
                    !std.mem.lessThan(u8, request.after.bytes, file.path.bytes)) continue;
                if (entries.items.len == 32) {
                    truncated = true;
                    break;
                }
                try entries.append(a, .{ .path = file.path, .bytes = file.contents.bytes.len });
            }
            const value: t.Listing = .{
                .entries = .{ .items = entries.items },
                .truncated = truncated,
                .next = .{ .bytes = if (truncated) entries.items[entries.items.len - 1].path.bytes else "" },
            };
            return .{ .value = value, .model_text = try text(t.Listing, a, value) };
        }

        pub fn read(a: std.mem.Allocator, snapshot: Snapshot, request: t.ReadRequest) !t.ReadObservation {
            const value: t.ReadResult = value: {
                if (!pathAllowed(request.path.bytes)) break :value .{ .invalid = .{ .bytes = "Invalid logical snapshot path." } };
                const file = snapshot.get(request.path.bytes) orelse break :value .{ .missing = request.path };
                if (request.maximum == 0 or request.maximum > 4096 or request.start > file.contents.bytes.len)
                    break :value .{ .invalid = .{ .bytes = "Read requires maximum 1..4096 and an offset within the file." } };
                const start: usize = @intCast(request.start);
                const end = start + @min(@as(usize, request.maximum), file.contents.bytes.len - start);
                const content = file.contents.bytes[start..end];
                if (!std.unicode.utf8ValidateSlice(content)) break :value .{ .invalid = .{ .bytes = "Selected byte window is not complete UTF-8; adjust its boundaries." } };
                const hex = std.fmt.bytesToHex(file.sha256, .lower);
                break :value .{ .found = .{
                    .snapshot = snapshot.identity,
                    .path = file.path,
                    .sha256 = .{ .bytes = try a.dupe(u8, &hex) },
                    .start = start,
                    .end = end,
                    .file_bytes = file.contents.bytes.len,
                    .content = .{ .bytes = content },
                } };
            };
            return .{ .value = value, .model_text = try text(t.ReadResult, a, value) };
        }

        fn text(comptime T: type, a: std.mem.Allocator, value: T) !t.P.ResultText {
            const bytes = try @import("json.zig").canonical(a, try @import("values.zig").toJson(T, a, value));
            if (bytes.len > t.P.ResultText.max_length.?) return error.Capacity;
            return .{ .bytes = bytes };
        }
    };
}
