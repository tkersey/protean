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
    const supported = shaInstructionsAvailable();
    std.debug.print("STARTUP SHA path {s}\n", .{if (supported) "accelerated" else "baseline"});
    features.store(if (supported) .sha else .baseline, .monotonic);
    return supported;
}

fn shaInstructionsAvailable() bool {
    if (cpuid(0).eax < 7) return false;
    const legacy = cpuid(1).ecx;
    const required = (1 << 9) | (1 << 19) | (1 << 26) | (1 << 27) | (1 << 28);
    if (legacy & required != required) return false;
    const extended = cpuid(7).ebx;
    const sha_avx2 = (1 << 29) | (1 << 5);
    if (extended & sha_avx2 != sha_avx2) return false;
    const registers = asm volatile ("xgetbv"
        : [_] "={eax}" (-> u32),
        : [_] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
    return registers & 6 == 6;
}

const CpuRegisters = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32) CpuRegisters {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (@as(u32, 0)),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

export fn protean_native_sha256_init(storage: *abi.State) void {
    if (linux_x86 and hasSha()) return protean_x86_sha256_init(storage);
    storage.hasher().* = Sha256.init(.{});
}

export fn protean_native_sha256_update(
    storage: *abi.State,
    bytes: [*]const u8,
    length: usize,
) void {
    if (linux_x86 and hasSha()) return protean_x86_sha256_update(storage, bytes, length);
    storage.hasher().update(bytes[0..length]);
}

export fn protean_native_sha256_final(storage: *abi.State, output: *[32]u8) void {
    if (linux_x86 and hasSha()) return protean_x86_sha256_final(storage, output);
    storage.hasher().final(output);
}

export fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void {
    std.crypto.hash.sha3.Sha3_256.hash(bytes[0..length], output, .{});
}

export fn protean_probe_cpu() u8 {
    return @intFromBool(hasSha());
}
