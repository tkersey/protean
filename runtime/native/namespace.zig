//! Private local namespace and process-crash seal. This is not distributed
//! custody: an archive import needs new admission; copying this directory is
//! rejected by its bound directory device/inode and OS principal.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const journal = @import("store.zig");
const c = @import("native_c");

fn regular(fd: c_int) !c.struct_protean_native_stat {
    var stat: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(fd, &stat) != 0) return error.StorageUnavailable;
    if (stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_mode & 0o077 != 0 or stat.st_uid != c.geteuid() or stat.st_nlink != 1) return error.UnsafeStatePath;
    return stat;
}
fn openFile(dir: c_int, name: [:0]const u8, flags: c_int) !c_int {
    const fd = c.openat(dir, name.ptr, flags | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return switch (std.c.errno(fd)) {
        .NOENT => error.FileNotFound,
        .EXIST => error.AlreadyExists,
        else => error.UnsafeStatePath,
    };
    errdefer _ = c.close(fd);
    _ = try regular(fd);
    return fd;
}
fn trustedParent(fd: c_int) !void {
    var stat: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(fd, &stat) != 0) return error.StorageUnavailable;
    // SQLite opens a pathname after descriptor-based namespace admission.
    // An untrusted writer must not be able to replace any admitted ancestor in
    // that interval. Root and this OS principal are the launch trust boundary;
    // sticky /tmp is allowed, ordinary shared writable parents are not.
    if (stat.st_uid != 0 and stat.st_uid != c.geteuid()) return error.UnsafeStatePath;
    if (stat.st_mode & 0o022 != 0 and stat.st_mode & c.S_ISVTX == 0) return error.UnsafeStatePath;
}
fn inspectDirectory(a: std.mem.Allocator, io: std.Io, fd: c_int, validate_files: bool) !bool {
    const directory: std.Io.Dir = .{ .handle = fd };
    var iterator = directory.iterate();
    var count: usize = 0;
    var has_lock = false;
    while (try iterator.next(io)) |entry| {
        var known = false;
        for ([_][]const u8{ "owner.lock", "identity", "state.sqlite", "state.sqlite-journal", "seal", "seal.next" }) |name| known = known or std.mem.eql(u8, name, entry.name);
        if (!known) return error.UnsafeStatePath;
        count += 1;
        has_lock = has_lock or std.mem.eql(u8, entry.name, "owner.lock");
        if (validate_files) {
            const name = try a.dupeSentinel(u8, entry.name, 0);
            defer a.free(name);
            const file = try openFile(fd, name, c.O_RDONLY);
            _ = c.close(file);
        }
    }
    if (count != 0 and !has_lock) return error.CorruptState;
    return count != 0;
}
fn readExact(fd: c_int, out: []u8) !void {
    const stat = try regular(fd);
    if (stat.st_size != out.len) return error.CorruptState;
    var offset: usize = 0;
    while (offset < out.len) {
        const n = c.pread(fd, out[offset..].ptr, out.len - offset, @intCast(offset));
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.StorageUnavailable;
        offset += @intCast(n);
    }
}
fn writeExact(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.StorageUnavailable;
        offset += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.StorageUnavailable;
}

// Relative SQLite paths are expanded by its VFS. Check the physical cwd's
// ancestors too, so a writable parent cannot replace that expanded pathname.
fn trustedAncestry(start: c_int) !void {
    var current = c.openat(start, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (current < 0) return error.StorageUnavailable;
    defer _ = c.close(current);
    for (0..4096) |_| {
        try trustedParent(current);
        var stat: c.struct_protean_native_stat = undefined;
        if (c.protean_native_fstat(current, &stat) != 0) return error.StorageUnavailable;
        const parent = c.openat(current, "..", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (parent < 0) return error.StorageUnavailable;
        var parent_stat: c.struct_protean_native_stat = undefined;
        if (c.protean_native_fstat(parent, &parent_stat) != 0) {
            _ = c.close(parent);
            return error.StorageUnavailable;
        }
        if (stat.st_dev == parent_stat.st_dev and stat.st_ino == parent_stat.st_ino) {
            _ = c.close(parent);
            return;
        }
        _ = c.close(current);
        current = parent;
    }
    return error.UnsafeStatePath;
}

/// Descriptor-based path admission shared by state namespaces and archives.
/// The caller owns the returned descriptor. Only namespaces create a final dir.
pub fn openDirectory(a: std.mem.Allocator, path: []const u8, create_final: bool, private_final: bool) !c_int {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafeStatePath;
    // Walk every component without following symlinks. Only the selected
    // final directory may be created; no ambient parent tree is modified.
    var components = std.mem.tokenizeScalar(u8, path, '/');
    var dir = c.open(if (path[0] == '/') "/" else ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (dir < 0) return error.StorageUnavailable;
    errdefer _ = c.close(dir);
    try trustedAncestry(dir);
    var component = components.next();
    while (component) |part| {
        try trustedParent(dir);
        if (std.mem.eql(u8, part, "..")) return error.UnsafeStatePath;
        const next = components.next();
        if (!std.mem.eql(u8, part, ".")) {
            const name = try a.dupeSentinel(u8, part, 0);
            defer a.free(name);
            var child = c.openat(dir, name.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            if (child < 0 and create_final and next == null and std.c.errno(child) == .NOENT) {
                if (c.mkdirat(dir, name.ptr, 0o700) != 0) return error.StorageUnavailable;
                child = c.openat(dir, name.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
            }
            if (child < 0) return error.UnsafeStatePath;
            _ = c.close(dir);
            dir = child;
        }
        component = next;
    }
    var stat: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(dir, &stat) != 0) return error.StorageUnavailable;
    if (private_final) {
        if (stat.st_mode & 0o077 != 0 or stat.st_uid != c.geteuid()) return error.UnsafeStatePath;
    } else try trustedParent(dir);
    return dir;
}

pub const Namespace = struct {
    allocator: std.mem.Allocator,
    directory: c_int,
    lock: c_int,
    database: *sqlite.Database,
    store: journal.Store,
    identity: [32]u8,

    pub fn open(a: std.mem.Allocator, io: std.Io, path: []const u8) !Namespace {
        const dir = try openDirectory(a, path, true, true);
        errdefer _ = c.close(dir);
        var stat: c.struct_protean_native_stat = undefined;
        if (c.protean_native_fstat(dir, &stat) != 0) return error.StorageUnavailable;
        _ = try inspectDirectory(a, io, dir, false);
        const lock = try openFile(dir, "owner.lock", c.O_RDWR | c.O_CREAT);
        errdefer _ = c.close(lock);
        if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
        _ = try inspectDirectory(a, io, dir, true);

        var fresh = false;
        const identity_file = openFile(dir, "identity", c.O_RDONLY) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // Never initialize over an existing database or seal.
                for ([_][:0]const u8{ "state.sqlite", "seal", "seal.next", "state.sqlite-journal" }) |name| {
                    const existing = openFile(dir, name, c.O_RDONLY) catch |failure| switch (failure) {
                        error.FileNotFound => continue,
                        else => return failure,
                    };
                    _ = c.close(existing);
                    return error.CorruptState;
                }
                fresh = true;
                break :blk try openFile(dir, "identity", c.O_RDWR | c.O_CREAT | c.O_EXCL);
            },
            else => return err,
        };
        defer _ = c.close(identity_file);
        var identity_bytes: [64]u8 = undefined;
        if (fresh) {
            @memcpy(identity_bytes[0..8], "AGNNS001");
            try io.randomSecure(identity_bytes[8..40]);
            std.mem.writeInt(u64, identity_bytes[40..48], @intCast(stat.st_dev), .little);
            std.mem.writeInt(u64, identity_bytes[48..56], @intCast(stat.st_ino), .little);
            std.mem.writeInt(u64, identity_bytes[56..64], @intCast(stat.st_uid), .little);
            try writeExact(identity_file, &identity_bytes);
        } else {
            try readExact(identity_file, &identity_bytes);
            if (!std.mem.eql(u8, identity_bytes[0..8], "AGNNS001") or
                std.mem.readInt(u64, identity_bytes[40..48], .little) != stat.st_dev or
                std.mem.readInt(u64, identity_bytes[48..56], .little) != stat.st_ino or
                std.mem.readInt(u64, identity_bytes[56..64], .little) != stat.st_uid) return error.ForeignNamespace;
        }
        const identity = identity_bytes[8..40].*;
        const database_file = try openFile(dir, "state.sqlite", c.O_RDWR | (if (fresh) @as(c_int, c.O_CREAT | c.O_EXCL) else 0));
        defer _ = c.close(database_file);
        // SQLite inherits the precreated private database's mode for journals.
        // Check any existing recovery journal before SQLite opens it.
        if (openFile(dir, "state.sqlite-journal", c.O_RDONLY)) |journal_fd| {
            _ = c.close(journal_fd);
        } else |err| if (err != error.FileNotFound) return err;
        const name = try std.fmt.allocPrint(a, "{s}/state.sqlite", .{path});
        defer a.free(name);
        const database = try sqlite.Database.open(a, name, false);
        errdefer {
            database.close() catch {};
            database.destroy() catch {};
        }
        var self: Namespace = .{ .allocator = a, .directory = dir, .lock = lock, .database = database, .store = try journal.Store.init(a, database, fresh, identity), .identity = identity };
        if (fresh) {
            try self.seal();
        } else {
            const seal_fd = try openFile(dir, "seal", c.O_RDONLY);
            defer _ = c.close(seal_fd);
            var bytes: [80]u8 = undefined;
            try readExact(seal_fd, &bytes);
            if (!std.mem.eql(u8, bytes[0..8], "AGNHD001")) return error.CorruptState;
            const generation = std.mem.readInt(u64, bytes[8..16], .little);
            const current = self.store.head;
            if (generation == current.generation) {
                if (!std.mem.eql(u8, bytes[16..48], &current.parent) or !std.mem.eql(u8, bytes[48..80], &current.digest)) return error.CorruptState;
            } else if (generation < std.math.maxInt(u64) and generation + 1 == current.generation and std.mem.eql(u8, bytes[48..80], &current.parent)) {
                // Process died after SQLite commit, before seal publication.
                try self.seal();
            } else return error.RollbackDetected;
        }
        return self;
    }

    fn seal(self: *Namespace) !void {
        errdefer self.store.fenced = true;
        // A leftover temporary seal is never authoritative. Check its type and
        // ownership before replacing it; no symlink or hardlink is truncated.
        if (openFile(self.directory, "seal.next", c.O_RDONLY)) |fd| {
            _ = c.close(fd);
            if (c.unlinkat(self.directory, "seal.next", 0) != 0) return error.StorageUnavailable;
        } else |err| if (err != error.FileNotFound) return err;
        const fd = try openFile(self.directory, "seal.next", c.O_WRONLY | c.O_CREAT | c.O_EXCL);
        defer _ = c.close(fd);
        var bytes: [80]u8 = undefined;
        @memcpy(bytes[0..8], "AGNHD001");
        std.mem.writeInt(u64, bytes[8..16], self.store.head.generation, .little);
        @memcpy(bytes[16..48], &self.store.head.parent);
        @memcpy(bytes[48..80], &self.store.head.digest);
        try writeExact(fd, &bytes);
        if (c.renameat(self.directory, "seal.next", self.directory, "seal") != 0 or c.fsync(self.directory) != 0) return error.StorageUnavailable;
    }
    pub fn commit(self: *Namespace, transition: []const u8) !void {
        _ = try self.store.commit(transition);
        try self.seal();
    }
    /// The task owner joins all workers and retires residents first.
    pub fn close(self: *Namespace) !void {
        self.store.rollback();
        try self.database.close();
        try self.database.destroy();
        _ = c.close(self.lock);
        _ = c.close(self.directory);
        self.* = undefined;
    }
};

test "namespace excludes a second owner and recovers the SQLite commit to seal gap" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(a, "{s}/private state λ", .{buffer[0..length]});
    defer a.free(path);
    var first = try Namespace.open(a, io, path);
    var live = true;
    defer if (live) first.close() catch unreachable;
    try std.testing.expectError(error.Busy, Namespace.open(a, io, path));
    try first.store.begin();
    const ref = try first.store.putObject("acquired before disconnect");
    _ = try first.store.commit("acquire");
    // Deliberately leave the old seal, as a kill between commit and rename does.
    try first.close();
    live = false;
    var recovered = try Namespace.open(a, io, path);
    defer recovered.close() catch unreachable;
    try std.testing.expectEqual(1, recovered.store.head.generation);
    const bytes = try recovered.store.object(a, ref, 1024);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("acquired before disconnect", bytes);
    try recovered.store.begin();
    _ = try recovered.store.putObject("after recovery");
    try recovered.commit("after-recovery");
    try std.testing.expectEqual(2, recovered.store.head.generation);
}

test "namespace refuses a database older than its published seal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{buffer[0..length]});
    defer a.free(path);
    var owner = try Namespace.open(a, io, path);
    var live = true;
    defer if (live) owner.close() catch unreachable;
    const original = owner.store.head;
    try owner.store.begin();
    try owner.commit("one");
    // Inject a stale database generation without rolling back its external seal.
    try owner.database.run("UPDATE meta SET generation=0,parent=?,head=? WHERE singleton=1", &.{ .{ .blob = &original.parent }, .{ .blob = &original.digest } });
    try owner.close();
    live = false;
    try std.testing.expectError(error.RollbackDetected, Namespace.open(a, io, path));
}

test "namespace rejects an ancestor another principal could replace" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    if (c.mkdirat(temporary.dir.handle, "shared", 0o700) != 0) return error.StorageUnavailable;
    if (c.fchmodat(temporary.dir.handle, "shared", 0o777, 0) != 0) return error.StorageUnavailable;
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(a, "{s}/shared/state", .{buffer[0..length]});
    defer a.free(path);
    try std.testing.expectError(error.UnsafeStatePath, Namespace.open(a, io, path));
}
