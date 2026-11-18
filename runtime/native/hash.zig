//! Private optimized standard-library hash primitives. File and object owners retain bounded
//! reads, metadata checks, content admission and integrity policy. This uses the same
//! standard-library algorithm as the caller's previous inline implementation.
const std = @import("std");
const abi = @import("hash_abi.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const builtin = @import("builtin");
const linux_x86 = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
const Features = enum(u8) { unknown, baseline, sha };
var features: std.atomic.Value(Features) = .init(.unknown);

extern fn protean_x86_sha256_init(storage: *abi.State) void;
extern fn protean_x86_sha256_update(storage: *abi.State, bytes: [*]const u8, length: usize) void;
extern fn protean_x86_sha256_final(storage: *abi.State, output: *[32]u8) void;

fn hasSha() bool {
    const known = features.load(.monotonic);
    if (known != .unknown) return known == .sha;
    const native = std.zig.system.resolveTargetQuery(std.Io.failing, .{
        .cpu_arch = .x86_64,
        .cpu_model = .native,
        .os_tag = .linux,
        .abi = builtin.abi,
    }) catch return false;
    const supported = native.cpu.hasAll(.x86, &.{ .sha, .avx2 });
    features.store(if (supported) .sha else .baseline, .monotonic);
    return supported;
}

comptime {
    std.debug.assert(@sizeOf(Sha256) <= @sizeOf(abi.State));
    std.debug.assert(@alignOf(Sha256) <= @alignOf(abi.State));
}

fn hasher(storage: *abi.State) *Sha256 {
    return @ptrCast(@alignCast(storage));
}

export fn protean_native_sha256_init(storage: *abi.State) void {
    if (linux_x86 and hasSha()) return protean_x86_sha256_init(storage);
    hasher(storage).* = Sha256.init(.{});
}

export fn protean_native_sha256_update(
    storage: *abi.State,
    bytes: [*]const u8,
    length: usize,
) void {
    if (linux_x86 and hasSha()) return protean_x86_sha256_update(storage, bytes, length);
    hasher(storage).update(bytes[0..length]);
}

export fn protean_native_sha256_final(storage: *abi.State, output: *[32]u8) void {
    if (linux_x86 and hasSha()) return protean_x86_sha256_final(storage, output);
    hasher(storage).final(output);
}

export fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void {
    std.crypto.hash.sha3.Sha3_256.hash(bytes[0..length], output, .{});
}
