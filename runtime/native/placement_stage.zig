//! Resumable transport bytes in an operator-owned private spool. A completed
//! file still has no execution authority; ordinary archive admission follows.
const std = @import("std");
const c = @import("native_c");
const p = @import("placement.zig");
const namespace = @import("namespace.zig");

pub fn path(a: std.mem.Allocator, directory: []const u8, offer: p.Offer) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/placement-{s}.par", .{
        directory,
        std.fmt.bytesToHex(try p.digest(p.Offer, a, offer), .lower),
    });
}

fn size(fd: c_int) !u64 {
    var stat: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(fd, &stat) != 0) return error.StorageUnavailable;
    if (stat.st_mode & c.S_IFMT != c.S_IFREG or
        stat.st_mode & 0o077 != 0 or
        stat.st_uid != c.geteuid() or
        stat.st_nlink != 1 or
        stat.st_size < 0)
    {
        return error.UnsafeStatePath;
    }
    return @intCast(stat.st_size);
}

fn stagingName(name: []const u8) bool {
    if (name.len != 78 or
        !std.mem.startsWith(u8, name, "placement-") or
        !std.mem.endsWith(u8, name, ".par"))
    {
        return false;
    }
    for (name[10..74]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn admitGrowth(
    a: std.mem.Allocator,
    io: std.Io,
    dir: c_int,
    limits: p.StagingLimits,
    added_file: bool,
    growth: u64,
) !void {
    var occupied: p.StagingLimits = .{ .bytes = 0, .files = 0 };
    const directory: std.Io.Dir = .{ .handle = dir };
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!stagingName(entry.name)) continue;
        const name = try a.dupeSentinel(u8, entry.name, 0);
        defer a.free(name);
        const fd = c.openat(dir, name.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.StorageUnavailable;
        defer _ = c.close(fd);
        occupied.bytes = try std.math.add(u64, occupied.bytes, try size(fd));
        occupied.files = try std.math.add(usize, occupied.files, 1);
    }
    if (added_file and occupied.files >= limits.files) return error.Capacity;
    if (growth != 0 and
        (occupied.bytes > limits.bytes or
            growth > limits.bytes - occupied.bytes))
    {
        return error.Capacity;
    }
}

pub fn retire(
    a: std.mem.Allocator,
    directory: []const u8,
    comptime kind: enum { placement, outgoing },
    identity: p.Digest,
) !void {
    const dir = try namespace.openDirectory(a, directory, false, true);
    defer _ = c.close(dir);
    if (c.flock(dir, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
    const name = try std.fmt.allocPrintSentinel(
        a,
        "{s}-{s}.par",
        .{ @tagName(kind), std.fmt.bytesToHex(identity, .lower) },
        0,
    );
    defer a.free(name);
    const fd = c.openat(dir, name.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return if (std.c.errno(fd) == .NOENT) {} else error.StorageUnavailable;
    defer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
    _ = try size(fd);
    if (c.unlinkat(dir, name.ptr, 0) != 0 or c.fsync(dir) != 0) return error.StorageUnavailable;
}

pub fn write(
    a: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    limits: ?p.StagingLimits,
    offer: p.Offer,
    offset: u64,
    bytes: []const u8,
) !u64 {
    if (bytes.len > 32768 or
        offset > offer.archive_bytes or
        bytes.len > offer.archive_bytes - offset)
    {
        return error.InvalidTransfer;
    }
    if (limits) |bound| if (offer.archive_bytes > bound.bytes) return error.Capacity;
    const dir = try namespace.openDirectory(a, directory, false, true);
    defer _ = c.close(dir);
    if (c.flock(dir, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
    const name = try std.fmt.allocPrintSentinel(
        a,
        "placement-{s}.par",
        .{std.fmt.bytesToHex(try p.digest(p.Offer, a, offer), .lower)},
        0,
    );
    defer a.free(name);
    var fd = c.openat(dir, name.ptr, c.O_RDWR | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC);
    const fresh = fd < 0;
    if (fresh and std.c.errno(fd) != .NOENT) return error.StorageUnavailable;
    defer if (fd >= 0) {
        _ = c.close(fd);
    };
    const current_size = if (fresh) 0 else try size(fd);
    if (current_size > offer.archive_bytes or offset > current_size) return error.InvalidTransfer;
    const next_size = @max(current_size, offset + bytes.len);
    if (limits) |bound| try admitGrowth(a, io, dir, bound, fresh, next_size - current_size);
    if (fresh) {
        fd = c.openat(
            dir,
            name.ptr,
            c.O_RDWR | c.O_CREAT | c.O_EXCL | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC,
            @as(c_uint, 0o600),
        );
        if (fd < 0) return error.StorageUnavailable;
    }
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
    try writeRange(fd, offset, bytes, current_size);
    if (c.fsync(fd) != 0 or c.fsync(dir) != 0) return error.StorageUnavailable;
    return next_size;
}

fn writeRange(fd: c_int, offset: u64, bytes: []const u8, current_size: u64) !void {
    const overlap: usize = @intCast(@min(bytes.len, current_size - offset));
    var buffer: [32768]u8 = undefined;
    var read: usize = 0;
    while (read < overlap) {
        const n = c.pread(fd, buffer[read..].ptr, overlap - read, @intCast(offset + read));
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.StorageUnavailable;
        read += @intCast(n);
    }
    if (!std.mem.eql(u8, buffer[0..overlap], bytes[0..overlap])) return error.OperationConflict;
    var written = overlap;
    while (written < bytes.len) {
        const n = c.pwrite(
            fd,
            bytes[written..].ptr,
            bytes.len - written,
            @intCast(offset + written),
        );
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.StorageUnavailable;
        written += @intCast(n);
    }
}

test "placement staging resumes exact prefixes and rejects conflicting bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(temporary.dir.handle, "spool", 0o700));
    var root: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &root);
    const directory = try std.fmt.allocPrint(a, "{s}/spool", .{root[0..length]});
    defer a.free(directory);
    var offer = std.mem.zeroes(p.Offer);
    offer.archive_bytes = 6;
    try std.testing.expectEqual(@as(u64, 3), try write(a, io, directory, null, offer, 0, "abc"));
    try std.testing.expectEqual(@as(u64, 3), try write(a, io, directory, null, offer, 0, "abc"));
    try std.testing.expectError(
        error.OperationConflict,
        write(a, io, directory, null, offer, 0, "abd"),
    );
    try std.testing.expectError(
        error.InvalidTransfer,
        write(a, io, directory, null, offer, 4, "e"),
    );
    try std.testing.expectEqual(@as(u64, 4), try write(a, io, directory, null, offer, 2, "cd"));
    try std.testing.expectEqual(@as(u64, 6), try write(a, io, directory, null, offer, 4, "ef"));
    try std.testing.expectEqual(@as(u64, 6), try write(a, io, directory, null, offer, 0, ""));
    const filename = try path(a, directory, offer);
    defer a.free(filename);
    const bytes = try @import("configuration.zig").readFile(a, io, filename, null, true);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
}

test "placement staging bounds aggregate bytes and files and retires exact archives" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(temporary.dir.handle, "spool", 0o700));
    var root: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &root);
    const directory = try std.fmt.allocPrint(a, "{s}/spool", .{root[0..length]});
    defer a.free(directory);
    const limits: p.StagingLimits = .{ .bytes = 6, .files = 2 };
    var first = std.mem.zeroes(p.Offer);
    first.archive_bytes = 4;
    var second = first;
    second.intent.transfer = @splat(1);
    var third = first;
    third.intent.transfer = @splat(2);
    try std.testing.expectEqual(@as(u64, 2), try write(a, io, directory, limits, first, 0, "ab"));
    try std.testing.expectEqual(@as(u64, 2), try write(a, io, directory, limits, second, 0, "cd"));
    try std.testing.expectError(error.Capacity, write(a, io, directory, limits, third, 0, ""));
    try std.testing.expectEqual(@as(u64, 4), try write(a, io, directory, limits, first, 2, "ef"));
    try std.testing.expectError(error.Capacity, write(a, io, directory, limits, second, 2, "gh"));
    try std.testing.expectEqual(@as(u64, 2), try write(a, io, directory, limits, second, 0, ""));
    try retire(a, directory, .placement, try p.digest(p.Offer, a, first));
    try retire(a, directory, .placement, try p.digest(p.Offer, a, first));
    try std.testing.expectEqual(@as(u64, 4), try write(a, io, directory, limits, second, 2, "gh"));
    try std.testing.expectEqual(@as(u64, 0), try write(a, io, directory, limits, third, 0, ""));
    const filename = try path(a, directory, second);
    defer a.free(filename);
    const bytes = try @import("configuration.zig").readFile(a, io, filename, null, true);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("cdgh", bytes);
    const dir = try namespace.openDirectory(a, directory, false, true);
    defer _ = c.close(dir);
    try std.testing.expectEqual(@as(c_int, 0), c.flock(dir, c.LOCK_EX | c.LOCK_NB));
    try std.testing.expectError(error.Busy, write(a, io, directory, limits, third, 0, ""));
    try std.testing.expectEqual(@as(c_int, 0), c.flock(dir, c.LOCK_UN));
    try retire(a, directory, .placement, try p.digest(p.Offer, a, second));
    try retire(a, directory, .placement, try p.digest(p.Offer, a, third));
    const spool: std.Io.Dir = .{ .handle = dir };
    var iterator = spool.iterate();
    try std.testing.expectEqual(null, try iterator.next(io));
}
