//! Explicit launch inputs. Applications admit their configuration into immutable
//! task data; credentials and compiled adapter handles remain process-local.
const std = @import("std");
const c = @import("native_c");
pub const Options = struct {
    offline: bool,
    /// Reclaimable temporary allocations, separate from the profile arena.
    scratch_allocator: ?std.mem.Allocator = null,
    test_provider: bool = false,
    config_path: ?[]const u8 = null,
    credential_path: ?[]const u8 = null,
    trust_root_path: ?[]const u8 = null,
};
pub const Admitted = struct {
    id: []const u8,
    bytes: []const u8,
    resources: []const []const u8 = &.{},
    environment: ?*anyopaque = null,
};

/// Bounded explicit files only. Refuse symlinks and nonregular entries; secret
/// inputs additionally require the current user's private file permissions.
pub fn readFile(a: std.mem.Allocator, io: std.Io, path: []const u8, maximum: usize, secret: bool) ![]u8 {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidConfiguration;
    const name = try a.dupeSentinel(u8, path, 0);
    defer a.free(name);
    const fd = c.open(name.ptr, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOCTTY);
    if (fd < 0) return error.ConfigurationUnavailable;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    var info: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(fd, &info) != 0 or info.st_mode & c.S_IFMT != c.S_IFREG or info.st_size < 0) return error.InvalidConfiguration;
    if (secret and (info.st_uid != c.geteuid() or info.st_mode & 0o077 != 0)) return error.UnsafeCredentialFile;
    if (@as(u64, @intCast(info.st_size)) > maximum) return error.Capacity;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(maximum));
}
