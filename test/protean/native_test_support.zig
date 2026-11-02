//! Shared manifest construction for native test fixtures.
const std = @import("std");

pub fn expectRetainedReceipt(a: std.mem.Allocator, namespace: anytype, expected: anytype) !void {
    var rows = try namespace.store.database.prepare(
        "SELECT o.body FROM operations p JOIN objects o ON o.digest=p.receipt " ++
            "WHERE p.task=? AND p.request=?",
        &.{ .{ .blob = &expected.task }, .{ .blob = &expected.request_digest } },
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    const encoded = try @import("protean").contracts.encodeOwned(@TypeOf(expected), a, expected);
    defer a.free(encoded);
    try std.testing.expectEqualSlices(u8, encoded, try rows.bytes(0));
    try std.testing.expectEqual(.done, try rows.step());
}

pub fn ownerManifest(
    a: std.mem.Allocator,
    image: []const u8,
    identity: [32]u8,
    application: []const u8,
) ![]u8 {
    var image_digest: [32]u8 = undefined;
    var assets_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &image_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(application, &assets_digest, .{});
    const image_hex = std.fmt.bytesToHex(image_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity, .lower);
    const assets_hex = std.fmt.bytesToHex(assets_digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{
        .format = "agent-native-build/v2",
        .native_host_contract = "unit-native-contract",
        .protocol = "agent-host/2.1",
        .client_mapping = "agent-client-values/1.1",
        .state_format = "agent-native-state/21",
        .optimize = "safe",
        .program_sha256 = @as([]const u8, &image_hex),
        .program_identity = @as([]const u8, &identity_hex),
        .application_assets_sha256 = @as([]const u8, &assets_hex),
        .dependencies = .{ .world = "unit-kosmos", .boundary = "unit-horos" },
        .compiler = .{ .version = "0.17.0" },
    }, .{});
}

pub fn cleanup(comptime operation: []const u8, result: anyerror!void) void {
    result catch |err| std.debug.panic("fixture {s} failed: {s}", .{ operation, @errorName(err) });
}
