//! Shared manifest construction for native test fixtures.
const std = @import("std");

pub fn ownerManifest(a: std.mem.Allocator, image: []const u8, identity: [32]u8, application: []const u8) ![]u8 {
    var image_digest: [32]u8 = undefined;
    var assets_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &image_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(application, &assets_digest, .{});
    const image_hex = std.fmt.bytesToHex(image_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity, .lower);
    const assets_hex = std.fmt.bytesToHex(assets_digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{
        .native_host_contract = "unit-native-contract",
        .protocol = "agent-host/2.1",
        .client_mapping = "agent-client-values/1.1",
        .state_format = "agent-native-state/15",
        .optimize = "safe",
        .program_sha256 = @as([]const u8, &image_hex),
        .program_identity = @as([]const u8, &identity_hex),
        .application_assets_sha256 = @as([]const u8, &assets_hex),
        .dependencies = .{ .world = "unit-kosmos", .boundary = "unit-horos" },
        .compiler = .{ .version = "0.17.0" },
    }, .{});
}
