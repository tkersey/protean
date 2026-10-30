//! Explicit launch inputs. Applications admit their configuration into immutable
//! task data; credentials and compiled adapter handles remain process-local.
const std = @import("std");
const c = @import("native_c");
const json = @import("json.zig");
pub const SemanticPolicy = struct {
    roots: []const [32]u8,
    checkers: []const []const u8,
    guard: bool = false,
};
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
    semantic_construction: ?SemanticPolicy = null,
};

pub fn semanticPolicy(a: std.mem.Allocator, value: json.Value) !?SemanticPolicy {
    if (value == .null) return null;
    try @import("protocol.zig").closed(value, .{ .required = &.{ "roots", "checkers", "guard" } });
    const roots = value.object.get("roots").?;
    const checkers = value.object.get("checkers").?;
    const guard = value.object.get("guard").?;
    if (roots != .array or checkers != .array or guard != .bool or
        roots.array.items.len == 0 or checkers.array.items.len == 0)
        return error.InvalidConfiguration;
    const root_ids = try a.alloc([32]u8, roots.array.items.len);
    errdefer a.free(root_ids);
    for (roots.array.items, root_ids, 0..) |text, *id, index| {
        const bytes = try json.text(text);
        if (bytes.len != 64) return error.InvalidConfiguration;
        _ = std.fmt.hexToBytes(id, bytes) catch return error.InvalidConfiguration;
        if (!std.mem.eql(u8, bytes, &std.fmt.bytesToHex(id.*, .lower)))
            return error.InvalidConfiguration;
        for (root_ids[0..index]) |prior|
            if (std.meta.eql(prior, id.*)) return error.InvalidConfiguration;
    }
    const names = try a.alloc([]const u8, checkers.array.items.len);
    errdefer a.free(names);
    for (checkers.array.items, names, 0..) |text, *name, index| {
        name.* = try json.text(text);
        if (name.*.len == 0 or name.*.len > 128) return error.InvalidConfiguration;
        for (name.*) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidConfiguration;
        for (names[0..index]) |prior|
            if (std.mem.eql(u8, prior, name.*)) return error.InvalidConfiguration;
    }
    return .{ .roots = root_ids, .checkers = names, .guard = guard.bool };
}

test "semantic policy admits only explicit exact roots and checkers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = @as([32]u8, @splat(23));
    const document = try std.fmt.allocPrint(
        a,
        "{{\"roots\":[\"{s}\"],\"checkers\":[\"operator-selected-checker\"],\"guard\":true}}",
        .{std.fmt.bytesToHex(root, .lower)},
    );
    var parsed = try json.parse(a, document, .{});
    defer parsed.deinit();
    const admitted = (try semanticPolicy(a, parsed.value)).?;
    try std.testing.expectEqualDeep(root, admitted.roots[0]);
    try std.testing.expectEqualStrings("operator-selected-checker", admitted.checkers[0]);
    try std.testing.expect(admitted.guard);
    try std.testing.expect((try semanticPolicy(a, .null)) == null);
    const duplicate = parsed.value.object.get("roots").?.array.items[0];
    try parsed.value.object.getPtr("roots").?.array.append(duplicate);
    try std.testing.expectError(error.InvalidConfiguration, semanticPolicy(a, parsed.value));
    _ = parsed.value.object.getPtr("roots").?.array.pop();
    try parsed.value.object.getPtr("checkers").?.array.append(
        json.string("operator-selected-checker"),
    );
    try std.testing.expectError(error.InvalidConfiguration, semanticPolicy(a, parsed.value));
}

/// Explicit files only. Refuse symlinks and nonregular entries; secret
/// inputs additionally require the current user's private file permissions.
pub fn readFile(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    maximum: ?usize,
    secret: bool,
) ![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(
        u8,
        path,
        0,
    ) != null) return error.InvalidConfiguration;
    const name = try a.dupeSentinel(u8, path, 0);
    defer a.free(name);
    const fd = c.open(
        name.ptr,
        c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOCTTY,
    );
    if (fd < 0) return error.ConfigurationUnavailable;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    var info: c.struct_protean_native_stat = undefined;
    if (c.protean_native_fstat(
        fd,
        &info,
    ) != 0 or
        info.st_mode & c.S_IFMT != c.S_IFREG or
        info.st_size < 0) return error.InvalidConfiguration;
    if (secret and
        (info.st_uid != c.geteuid() or
            info.st_mode & 0o077 != 0))
    {
        return error.UnsafeCredentialFile;
    }
    if (maximum != null and @as(u64, @intCast(info.st_size)) > maximum.?) return error.Capacity;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(a, if (maximum) |limit| .limited(limit) else .unlimited);
}
