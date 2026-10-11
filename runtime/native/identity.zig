//! Runtime artifact identity is observed from the executing binary, not inferred
//! from a WASM digest or from metadata that can survive a native code change.
const std = @import("std");
const hash_abi = @import("hash_abi.zig");
pub const Identity = struct { sha256: [32]u8, bytes: u64 };

pub fn executable(io: std.Io) !Identity {
    const file = try std.process.openExecutable(io, .{});
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.size == 0 or before.size > 256 * 1024 * 1024) return error.UnsupportedNativeArtifact;
    var hash: hash_abi.State = undefined;
    hash_abi.protean_native_sha256_init(&hash);
    var buffer: [64 * 1024]u8 = undefined;
    var length: u64 = 0;
    while (true) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) continue;
        length = try std.math.add(u64, length, count);
        if (length > before.size) return error.NativeArtifactChanged;
        hash_abi.protean_native_sha256_update(&hash, &buffer, count);
    }
    const after = try file.stat(io);
    if (length != before.size or before.inode != after.inode or before.size != after.size or !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) return error.NativeArtifactChanged;
    var result: Identity = .{ .sha256 = undefined, .bytes = length };
    hash_abi.protean_native_sha256_final(&hash, &result.sha256);
    return result;
}
