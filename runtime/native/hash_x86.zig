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

export fn protean_x86_sha256_init(storage: *abi.State) void {
    hasher(storage).* = Sha256.init(.{});
}

export fn protean_x86_sha256_update(
    storage: *abi.State,
    bytes: [*]const u8,
    length: usize,
) void {
    hasher(storage).update(bytes[0..length]);
}

export fn protean_x86_sha256_final(storage: *abi.State, output: *[32]u8) void {
    hasher(storage).final(output);
}
