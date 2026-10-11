//! Private optimized standard-library hash primitives. File and object owners retain bounded
//! reads, metadata checks, content admission and integrity policy. This uses the same
//! standard-library algorithm as the caller's previous inline implementation.
const std = @import("std");
const abi = @import("hash_abi.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

comptime {
    std.debug.assert(@sizeOf(Sha256) <= @sizeOf(abi.State));
    std.debug.assert(@alignOf(Sha256) <= @alignOf(abi.State));
}

fn hasher(storage: *abi.State) *Sha256 {
    return @ptrCast(@alignCast(storage));
}

export fn protean_native_sha256_init(storage: *abi.State) void {
    hasher(storage).* = Sha256.init(.{});
}

export fn protean_native_sha256_update(storage: *abi.State, bytes: [*]const u8, length: usize) void {
    hasher(storage).update(bytes[0..length]);
}

export fn protean_native_sha256_final(storage: *abi.State, output: *[32]u8) void {
    hasher(storage).final(output);
}

export fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void {
    std.crypto.hash.sha3.Sha3_256.hash(bytes[0..length], output, .{});
}
