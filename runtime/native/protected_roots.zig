const std = @import("std");
const c = @import("native_c");

pub const Roots = struct {
    io: std.Io,
    declared: []const []const u8 = &.{},
    resolved: []const []const u8 = &.{},

    pub fn init(
        a: std.mem.Allocator,
        io: std.Io,
        home: ?[]const u8,
        custom: ?[]const u8,
    ) !Roots {
        var paths: std.ArrayList([]const u8) = .empty;
        if (home) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.InvalidHome;
            try paths.append(a, try std.fs.path.join(a, &.{ path, ".config", "siwc" }));
        } else return error.MissingHome;
        if (custom) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.InvalidAuthDirectory;
            try paths.append(a, try a.dupe(u8, path));
        }
        const resolved = try a.alloc([]const u8, paths.items.len);
        for (paths.items, resolved) |path, *out| out.* = try prospective(a, io, path);
        return .{ .io = io, .declared = paths.items, .resolved = resolved };
    }

    pub fn contains(self: Roots, a: std.mem.Allocator, path: []const u8) !bool {
        const actual = try prospective(a, self.io, path);
        defer a.free(actual);
        return self.containsResolved(a, actual);
    }

    pub fn containsFd(self: Roots, a: std.mem.Allocator, fd: c_int) !bool {
        var buffer: [4096]u8 = undefined;
        const length = c.protean_native_fd_path(fd, &buffer, buffer.len);
        if (length < 0) return error.FileIdentityUnavailable;
        return self.containsResolved(a, buffer[0..@intCast(length)]);
    }

    fn containsResolved(self: Roots, a: std.mem.Allocator, actual: []const u8) !bool {
        for (self.resolved) |root| if (within(root, actual)) return true;
        for (self.declared) |root| {
            const current = try prospective(a, self.io, root);
            defer a.free(current);
            if (within(current, actual)) return true;
        }
        return false;
    }
};

fn within(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or
        (std.mem.startsWith(u8, path, root) and
            (std.mem.eql(u8, root, "/") or (path.len > root.len and path[root.len] == '/')));
}

pub fn prospective(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidProtectedPath;
    var candidate = path;
    var suffix: std.ArrayList([]const u8) = .empty;
    defer suffix.deinit(a);
    while (candidate.len != 0) {
        const existing = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, a) catch |err|
            switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
        if (existing) |resolved| {
            defer a.free(resolved);
            var result = try a.dupe(u8, resolved);
            errdefer a.free(result);
            var i = suffix.items.len;
            while (i != 0) {
                i -= 1;
                const joined = try std.fs.path.join(a, &.{ result, suffix.items[i] });
                a.free(result);
                result = joined;
            }
            return result;
        }
        const leaf = std.fs.path.basename(candidate);
        if (std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, ".."))
            return error.InvalidProtectedPath;
        try suffix.append(a, leaf);
        candidate = std.fs.path.dirname(candidate) orelse ".";
    }
    return error.ProtectedRootUnavailable;
}

test "protected containment distinguishes siblings and descendants" {
    try std.testing.expect(within("/a/siwc", "/a/siwc/pending"));
    try std.testing.expect(within("/a/siwc", "/a/siwc"));
    try std.testing.expect(!within("/a/siwc", "/a/siwc-old/file"));
    try std.testing.expect(within("/", "/a"));
}
