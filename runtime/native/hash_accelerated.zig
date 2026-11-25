const std = @import("std");
const builtin = @import("builtin");
const abi = @import("hash_abi.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn supports(cpu: std.Target.Cpu) bool {
    return switch (cpu.arch) {
        .x86_64 => cpu.hasAll(.x86, &.{ .sha, .avx2 }),
        .aarch64 => cpu.has(.aarch64, .sha2),
        else => false,
    };
}

comptime {
    std.debug.assert(@sizeOf(Sha256) <= @sizeOf(abi.State));
    std.debug.assert(@alignOf(Sha256) <= @alignOf(abi.State));
    if (@import("root") == @This()) {
        if (!supports(builtin.cpu) or builtin.zig_backend == .stage2_c)
            @compileError("the accelerated SHA-256 unit requires its CPU extensions");
        @export(&init, .{ .name = "protean_native_sha256_accelerated_init" });
        @export(&update, .{ .name = "protean_native_sha256_accelerated_update" });
        @export(&final, .{ .name = "protean_native_sha256_accelerated_final" });
    }
}

fn hasher(storage: *abi.State) *Sha256 {
    return @ptrCast(@alignCast(storage));
}

pub fn init(storage: *abi.State) callconv(.c) void {
    hasher(storage).* = .init(.{});
}

pub fn update(storage: *abi.State, bytes: [*]const u8, length: usize) callconv(.c) void {
    if (comptime builtin.zig_backend == .stage2_x86_64)
        return direct.update(hasher(storage), bytes[0..length]);
    hasher(storage).update(bytes[0..length]);
}

pub fn final(storage: *abi.State, output: *[32]u8) callconv(.c) void {
    hasher(storage).final(output);
}

pub const round_constants: [64]u32 align(16) = .{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

const direct = struct {
    const Vector = @Vector(4, u32);
    const reverse: [16]u8 align(16) = .{ 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12 };

    fn update(hash: *Sha256, bytes: []const u8) void {
        var input = bytes;
        if (hash.buf_len != 0) {
            const count = @min(input.len, 64 - @as(usize, hash.buf_len));
            hash.update(input[0..count]);
            input = input[count..];
        }
        const full = input.len - input.len % 64;
        if (full != 0) {
            blocks(&hash.s, input[0..full]);
            hash.total_len += full;
        }
        hash.update(input[full..]);
    }

    fn blocks(state: *[8]u32, input: []const u8) void {
        std.debug.assert(input.len % 64 == 0);
        var x: Vector = .{ state[5], state[4], state[1], state[0] };
        var y: Vector = .{ state[7], state[6], state[3], state[2] };
        for (0..input.len / 64) |index| {
            const previous_x = x;
            const previous_y = y;
            asm volatile (loadVector("rdi", 0, 3) ++ loadVector("rdi", 16, 4) ++
                    loadVector("rdi", 32, 5) ++ loadVector("rdi", 48, 6) ++
                    loadVector("rsi", 0, 7) ++
                    \\vpshufb %%xmm7, %%xmm3, %%xmm3
                    \\vpshufb %%xmm7, %%xmm4, %%xmm4
                    \\vpshufb %%xmm7, %%xmm5, %%xmm5
                    \\vpshufb %%xmm7, %%xmm6, %%xmm6
                    \\
                ++ roundInstructions()
                : [x] "={xmm1}" (x),
                  [y] "={xmm2}" (y),
                : [_] "0" (x),
                  [_] "1" (y),
                  [block] "{rdi}" (input[index * 64 ..].ptr),
                  [reverse] "{rsi}" (&reverse),
                  [constants] "{rdx}" (&round_constants),
                : .{
                  .rax = true,
                  .xmm0 = true,
                  .xmm3 = true,
                  .xmm4 = true,
                  .xmm5 = true,
                  .xmm6 = true,
                  .xmm7 = true,
                  .memory = true,
                });
            x +%= previous_x;
            y +%= previous_y;
        }
        state.* = .{ x[3], x[2], y[3], y[2], x[1], x[0], y[1], y[0] };
    }

    fn loadVector(comptime base: []const u8, comptime offset: usize, comptime dest: u8) []const u8 {
        return std.fmt.comptimePrint(
            \\movq {d}(%%{s}), %%rax
            \\vmovq %%rax, %%xmm{d}
            \\movq {d}(%%{s}), %%rax
            \\vpinsrq $1, %%rax, %%xmm{d}, %%xmm{d}
            \\
        , .{ offset, base, dest, offset + 8, base, dest, dest });
    }

    fn roundInstructions() []const u8 {
        @setEvalBranchQuota(30000);
        comptime var result: []const u8 = "";
        inline for (0..16) |group| {
            const a = 3 + group % 4;
            const b = 3 + (group + 1) % 4;
            const c = 3 + (group + 2) % 4;
            const d = 3 + (group + 3) % 4;
            result = result ++ loadVector("rdx", group * 16, 0) ++ std.fmt.comptimePrint(
                \\vpaddd %%xmm0, %%xmm{d}, %%xmm0
                \\sha256rnds2 %%xmm1, %%xmm2
                \\vpsrldq $8, %%xmm0, %%xmm0
                \\sha256rnds2 %%xmm2, %%xmm1
                \\
            , .{a});
            if (group < 12) result = result ++ std.fmt.comptimePrint(
                \\sha256msg1 %%xmm{d}, %%xmm{d}
                \\vpalignr $4, %%xmm{d}, %%xmm{d}, %%xmm7
                \\paddd %%xmm7, %%xmm{d}
                \\sha256msg2 %%xmm{d}, %%xmm{d}
                \\
            , .{ b, a, c, d, a, d, a });
        }
        return result;
    }
};
