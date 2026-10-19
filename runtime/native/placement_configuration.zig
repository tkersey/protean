//! Operator-owned launch configuration. Neither guest values nor archives can
//! select a signing key, destination process, or private disclosure policy.
const std = @import("std");
const p = @import("placement.zig");
const storage = @import("store.zig");
const configuration = @import("configuration.zig");

const Policy = struct {
    allow_private: bool = false,
    denied_objects: []const []const u8 = &.{},
    maximum_object_bytes: ?u64 = null,
};
const Peer = struct {
    name: []const u8,
    public_key: []const u8,
    namespace: []const u8,
    native_build: []const u8,
    compatibility: struct { base: []const u8, admission: []const u8, bridge: []const u8, semantics: []const u8, private_state: []const u8 },
    resource_binding: []const u8,
    disclosure: Policy,
    archive_limit: ?u64 = null,
    command: ?[]const []const u8 = null,
    remote_name: ?[]const u8 = null,
    timeout_ms: u32 = 30000,
};
const Document = struct { signing_key_file: []const u8, peers: []const Peer, transport_directory: ?[]const u8 = null, staging_limits: ?p.StagingLimits = null };
const Disclosure = struct {
    allow_private: bool,
    denied: []const p.Digest,
    maximum_object_bytes: ?u64,

    fn check(context: *anyopaque, _: p.Subject, objects: []const @import("state.zig").Reference) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.allow_private) return error.DisclosureDenied;
        var total: u64 = 0;
        for (objects) |object| {
            for (self.denied) |denied| if (std.meta.eql(denied, object.digest)) return error.DisclosureDenied;
            total = try std.math.add(u64, total, object.bytes);
        }
        if (self.maximum_object_bytes) |maximum| if (total > maximum) return error.DisclosureDenied;
    }
};
fn digest(text: []const u8) !p.Digest {
    if (text.len != 64) return error.InvalidConfiguration;
    var result: p.Digest = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.InvalidConfiguration;
    return result;
}

/// All returned storage belongs to the launch arena. The secret seed buffer is
/// erased immediately; the live signing key never enters a durable record.
pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !*const p.Configuration {
    const bytes = try configuration.readFile(a, io, path, null, false);
    defer a.free(bytes);
    const document = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
    const key_bytes = try configuration.readFile(a, io, document.signing_key_file, 128, true);
    defer {
        std.crypto.secureZero(u8, key_bytes);
        a.free(key_bytes);
    }
    var seed = try digest(std.mem.trim(u8, key_bytes, "\r\n"));
    defer std.crypto.secureZero(u8, &seed);
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const peers = try a.alloc(p.Peer, document.peers.len);
    for (document.peers, peers, 0..) |input, *peer, index| {
        if (input.name.len == 0 or input.name.len > 128) return error.InvalidConfiguration;
        for (document.peers[0..index]) |prior| if (std.mem.eql(u8, prior.name, input.name)) return error.InvalidConfiguration;
        const policy = try a.create(Disclosure);
        const denied = try a.alloc(p.Digest, input.disclosure.denied_objects.len);
        for (input.disclosure.denied_objects, denied) |object, *output| output.* = try digest(object);
        policy.* = .{ .allow_private = input.disclosure.allow_private, .denied = denied, .maximum_object_bytes = input.disclosure.maximum_object_bytes };
        const policy_bytes = try std.json.Stringify.valueAlloc(a, input.disclosure, .{});
        defer a.free(policy_bytes);
        peer.* = .{
            .name = input.name,
            .site = .{ .key = try digest(input.public_key), .namespace = try digest(input.namespace) },
            .native_build = try digest(input.native_build),
            .compatibility = .{ .base = try digest(input.compatibility.base), .admission = try digest(input.compatibility.admission), .bridge = try digest(input.compatibility.bridge), .semantics = try digest(input.compatibility.semantics), .private_state = try digest(input.compatibility.private_state) },
            .resource_binding = try digest(input.resource_binding),
            .disclosure_policy = storage.digest(policy_bytes),
            .archive_limit = input.archive_limit,
            .channel = if (input.command) |argv| channel: {
                if (argv.len == 0 or argv[0].len == 0 or input.timeout_ms == 0) return error.InvalidConfiguration;
                const remote = input.remote_name orelse return error.InvalidConfiguration;
                if (remote.len == 0 or remote.len > 128) return error.InvalidConfiguration;
                break :channel .{ .argv = argv, .remote_name = remote, .timeout_ms = input.timeout_ms };
            } else null,
            .context = policy,
            .disclose = Disclosure.check,
        };
        for (peers[0..index]) |prior| if (std.meta.eql(prior.site, peer.site)) return error.InvalidConfiguration;
    }
    const result = try a.create(p.Configuration);
    result.* = .{ .signing_key = key, .peers = peers, .transport_directory = document.transport_directory, .staging_limits = document.staging_limits };
    return result;
}

test "placement disclosure checks private policy and every actual object" {
    var policy: Disclosure = .{ .allow_private = true, .denied = &.{@splat(1)}, .maximum_object_bytes = 10 };
    const subject: p.Subject = .{ .task = @splat(2) };
    try Disclosure.check(&policy, subject, &.{.{ .digest = @splat(3), .bytes = 10 }});
    try std.testing.expectError(error.DisclosureDenied, Disclosure.check(&policy, subject, &.{.{ .digest = @splat(1), .bytes = 1 }}));
    try std.testing.expectError(error.DisclosureDenied, Disclosure.check(&policy, subject, &.{.{ .digest = @splat(3), .bytes = 11 }}));
    policy.allow_private = false;
    try std.testing.expectError(error.DisclosureDenied, Disclosure.check(&policy, subject, &.{}));
}

test "placement launch configuration admits private keys and pinned peers" {
    const io = std.testing.io;
    const c = @import("native_c");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &root);
    const key_path = try std.fmt.allocPrint(a, "{s}/key", .{root[0..length]});
    const config_path = try std.fmt.allocPrint(a, "{s}/config.json", .{root[0..length]});
    const hex = "0101010101010101010101010101010101010101010101010101010101010101";
    try temporary.dir.writeFile(io, .{ .sub_path = "key", .data = hex });
    try std.testing.expectEqual(@as(c_int, 0), c.fchmodat(temporary.dir.handle, "key", 0o600, 0));
    const peer: Peer = .{ .name = "peer", .public_key = hex, .namespace = hex, .native_build = hex, .compatibility = .{ .base = hex, .admission = hex, .bridge = hex, .semantics = hex, .private_state = hex }, .resource_binding = hex, .disclosure = .{ .allow_private = true }, .command = &.{"/usr/bin/false"}, .remote_name = "source" };
    const bytes = try std.json.Stringify.valueAlloc(a, Document{ .signing_key_file = key_path, .peers = &.{peer}, .transport_directory = root[0..length], .staging_limits = .{ .bytes = 4096, .files = 2 } }, .{});
    try temporary.dir.writeFile(io, .{ .sub_path = "config.json", .data = bytes });
    const configured = try load(a, io, config_path);
    try std.testing.expectEqualDeep(p.StagingLimits{ .bytes = 4096, .files = 2 }, configured.staging_limits.?);
    try std.testing.expectEqualStrings("peer", configured.peers[0].name);
    try std.testing.expectEqualStrings("/usr/bin/false", configured.peers[0].channel.?.argv[0]);
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(1));
    try std.testing.expectEqualDeep(key.public_key.toBytes(), configured.signing_key.public_key.toBytes());
    try std.testing.expectEqual(@as(c_int, 0), c.fchmodat(temporary.dir.handle, "key", 0o644, 0));
    try std.testing.expectError(error.UnsafeCredentialFile, load(a, io, config_path));
}
