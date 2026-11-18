//! Private hash primitives. File and object owners retain bounded reads, metadata
//! checks, content admission and integrity policy.
const std = @import("std");
const builtin = @import("builtin");
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

export fn protean_native_sha256_update(
    storage: *abi.State,
    bytes: [*]const u8,
    length: usize,
) void {
    const state = hasher(storage);
    if (comptime builtin.zig_backend == .stage2_x86_64 and builtin.os.tag == .linux and
        !builtin.cpu.hasAll(.x86, &.{ .sha, .avx2 }))
    {
        if (length >= Sha256.block_length) return updateBlocks(state, bytes[0..length]);
    }
    state.update(bytes[0..length]);
}

export fn protean_native_sha256_final(storage: *abi.State, output: *[32]u8) void {
    hasher(storage).final(output);
}

export fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void {
    std.crypto.hash.sha3.Sha3_256.hash(bytes[0..length], output, .{});
}

fn updateBlocks(state: *Sha256, input: []const u8) void {
    const block_length = Sha256.block_length;
    const prefix = if (state.buf_len == 0) 0 else block_length - @as(usize, state.buf_len);
    if (prefix != 0) state.update(input[0..prefix]);
    const remaining = input[prefix..];
    const full_length = remaining.len - remaining.len % block_length;
    for (std.mem.bytesAsSlice([block_length]u8, remaining[0..full_length])) |*block| {
        compress(state, block);
    }
    state.total_len += full_length;
    state.update(remaining[full_length..]);
}

fn compress(state: *Sha256, block: *const [64]u8) void {
    var schedule: [64]u32 = undefined;
    for (schedule[0..16], std.mem.bytesAsSlice(u32, block)) |*word, input| {
        word.* = if (builtin.cpu.arch.endian() == .little) @byteSwap(input) else input;
    }

    for (
        schedule[16..],
        schedule[0..48],
        schedule[9..57],
        schedule[1..49],
        schedule[14..62],
    ) |*out, old16, old7, old15, old2| {
        const sigma0 = rotateWord(old15, 7) ^ rotateWord(old15, 18) ^ (old15 >> 3);
        const sigma1 = rotateWord(old2, 17) ^ rotateWord(old2, 19) ^ (old2 >> 10);
        out.* = old16 +% old7 +% sigma0 +% sigma1;
    }
    var a, var b, var c, var d, var e, var f, var g, var h = state.s;
    for (schedule, constants) |word, constant| {
        const sigma1 = rotateWord(e, 6) ^ rotateWord(e, 11) ^ rotateWord(e, 25);
        const t1 = h +% sigma1 +% (g ^ (e & (f ^ g))) +% constant +% word;
        const sigma0 = rotateWord(a, 2) ^ rotateWord(a, 13) ^ rotateWord(a, 22);
        const t2 = sigma0 +% ((a & (b | c)) | (b & c));
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }
    const working = [8]u32{ a, b, c, d, e, f, g, h };
    for (&state.s, working) |*previous, word| previous.* +%= word;
}

inline fn rotateWord(x: u32, comptime count: u5) u32 {
    return @call(.always_inline, std.math.rotr, .{ u32, x, count });
}

const constants = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};
