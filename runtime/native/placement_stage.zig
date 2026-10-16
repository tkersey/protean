//! Resumable transport bytes in an operator-owned private spool. A completed
//! file still has no execution authority; ordinary archive admission follows.
const std = @import("std");
const c = @import("native_c");
const p = @import("placement.zig");
const namespace = @import("namespace.zig");

pub fn path(a: std.mem.Allocator, directory: []const u8, offer: p.Offer) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/placement-{s}.par", .{ directory, std.fmt.bytesToHex(try p.digest(p.Offer, a, offer), .lower) });
}

pub fn write(a: std.mem.Allocator, directory: []const u8, offer: p.Offer, offset: u64, bytes: []const u8) !u64 {
    if (bytes.len > 32768 or offset > offer.archive_bytes or bytes.len > offer.archive_bytes - offset) return error.InvalidTransfer;
    const dir = try namespace.openDirectory(a, directory, false, true);
    defer _ = c.close(dir);
    const name = try std.fmt.allocPrintSentinel(a, "placement-{s}.par", .{std.fmt.bytesToHex(try p.digest(p.Offer, a, offer), .lower)}, 0);
    defer a.free(name);
    const fd = c.openat(dir, name.ptr, c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.StorageUnavailable;
    defer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
    var stat: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(fd, &stat) != 0) return error.StorageUnavailable;
    if (stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_mode & 0o077 != 0 or stat.st_uid != c.geteuid() or stat.st_nlink != 1 or stat.st_size < 0) return error.UnsafeStatePath;
    const size: u64 = @intCast(stat.st_size);
    if (size > offer.archive_bytes or offset > size) return error.InvalidTransfer;
    const overlap: usize = @intCast(@min(bytes.len, size - offset));
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
        const n = c.pwrite(fd, bytes[written..].ptr, bytes.len - written, @intCast(offset + written));
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.StorageUnavailable;
        written += @intCast(n);
    }
    if (c.fsync(fd) != 0 or c.fsync(dir) != 0) return error.StorageUnavailable;
    return @max(size, offset + bytes.len);
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
    try std.testing.expectEqual(@as(u64, 3), try write(a, directory, offer, 0, "abc"));
    try std.testing.expectEqual(@as(u64, 3), try write(a, directory, offer, 0, "abc"));
    try std.testing.expectError(error.OperationConflict, write(a, directory, offer, 0, "abd"));
    try std.testing.expectError(error.InvalidTransfer, write(a, directory, offer, 4, "e"));
    try std.testing.expectEqual(@as(u64, 4), try write(a, directory, offer, 2, "cd"));
    try std.testing.expectEqual(@as(u64, 6), try write(a, directory, offer, 4, "ef"));
    try std.testing.expectEqual(@as(u64, 6), try write(a, directory, offer, 0, ""));
    const filename = try path(a, directory, offer);
    defer a.free(filename);
    const bytes = try @import("configuration.zig").readFile(a, io, filename, null, true);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
}
