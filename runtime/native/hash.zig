//! Private hash primitives. File and object owners retain bounded reads, metadata
//! checks, content admission and integrity policy.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("hash_abi.zig");
const accelerated_unit = @import("hash_accelerated.zig");

pub const Path = enum(u8) { software = 1, accelerated = 2 };

const accelerated_target = accelerated_unit.supports(builtin.cpu) and
    builtin.zig_backend != .stage2_c;
const dispatched = !accelerated_target and switch (builtin.cpu.arch) {
    .x86_64 => true,
    .aarch64 => builtin.os.tag == .linux,
    else => false,
};

pub const accelerated = if (dispatched) struct {
    extern fn protean_native_sha256_accelerated_init(storage: *abi.State) void;
    extern fn protean_native_sha256_accelerated_update(
        storage: *abi.State,
        bytes: [*]const u8,
        length: usize,
    ) void;
    extern fn protean_native_sha256_accelerated_final(storage: *abi.State, output: *[32]u8) void;
    pub const init = protean_native_sha256_accelerated_init;
    pub const update = protean_native_sha256_accelerated_update;
    pub const final = protean_native_sha256_accelerated_final;
} else accelerated_unit;

var decision: std.atomic.Value(u8) = .init(0);

pub fn path() Path {
    const recorded = decision.load(.acquire);
    if (recorded != 0) return @fromBackingInt(@intCast(recorded));
    const detected: Path = if (acceleratedAvailable()) .accelerated else .software;
    const winner = decision.cmpxchgStrong(0, @backingInt(detected), .acq_rel, .acquire);
    return if (winner) |earlier| @fromBackingInt(@intCast(earlier)) else detected;
}

fn acceleratedAvailable() bool {
    if (accelerated_target) return true;
    if (!dispatched) return false;
    return switch (builtin.cpu.arch) {
        .x86_64 => x86.supported(),
        else => linuxHardwareCapabilities() & std.os.linux.HWCAP.SHA2 != 0,
    };
}

fn linuxHardwareCapabilities() usize {
    if (builtin.link_libc) return std.c.getauxval(std.elf.AT.HWCAP);
    return std.os.linux.getauxval(std.elf.AT.HWCAP);
}

const x86 = struct {
    const sse3: u32 = 1 << 0;
    const ssse3: u32 = 1 << 9;
    const sse4_1: u32 = 1 << 19;
    const sse4_2: u32 = 1 << 20;
    const osxsave: u32 = 1 << 27;
    const avx: u32 = 1 << 28;
    const avx2: u32 = 1 << 5;
    const sha: u32 = 1 << 29;
    const sse_state: u32 = 1 << 1;
    const avx_state: u32 = 1 << 2;

    fn supported() bool {
        if (cpuid(0).eax < 7) return false;
        const vector_features = sse3 | ssse3 | sse4_1 | sse4_2 | osxsave | avx;
        if (cpuid(1).ecx & vector_features != vector_features) return false;
        const saved_state = sse_state | avx_state;
        if (extendedControl() & saved_state != saved_state) return false;
        const extensions = sha | avx2;
        return cpuid(7).ebx & extensions == extensions;
    }

    fn cpuid(leaf: u32) struct { eax: u32, ebx: u32, ecx: u32 } {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        asm volatile ("cpuid"
            : [_] "={eax}" (eax),
              [_] "={ebx}" (ebx),
              [_] "={ecx}" (ecx),
            : [_] "{eax}" (leaf),
              [_] "{ecx}" (@as(u32, 0)),
            : .{ .edx = true });
        return .{ .eax = eax, .ebx = ebx, .ecx = ecx };
    }

    fn extendedControl() u32 {
        return asm volatile ("xgetbv"
            : [_] "={eax}" (-> u32),
            : [_] "{ecx}" (@as(u32, 0)),
            : .{ .edx = true });
    }
};

export fn protean_native_sha256_init(storage: *abi.State) void {
    switch (path()) {
        .software => software.init(storage),
        .accelerated => accelerated.init(storage),
    }
}

export fn protean_native_sha256_update(
    storage: *abi.State,
    bytes: [*]const u8,
    length: usize,
) void {
    switch (path()) {
        .software => software.update(storage, bytes, length),
        .accelerated => accelerated.update(storage, bytes, length),
    }
}

export fn protean_native_sha256_final(storage: *abi.State, output: *[32]u8) void {
    switch (path()) {
        .software => software.final(storage, output),
        .accelerated => accelerated.final(storage, output),
    }
}

export fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void {
    std.crypto.hash.sha3.Sha3_256.hash(bytes[0..length], output, .{});
}

pub const software = struct {
    const State = struct {
        words: [8]u32,
        pending: [64]u8,
        pending_length: u8,
        total_length: u64,
    };
    const initial = [8]u32{
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    };

    comptime {
        std.debug.assert(@sizeOf(State) <= @sizeOf(abi.State));
        std.debug.assert(@alignOf(State) <= @alignOf(abi.State));
    }

    fn of(storage: *abi.State) *State {
        return @ptrCast(@alignCast(storage));
    }

    pub fn init(storage: *abi.State) void {
        of(storage).* = .{
            .words = initial,
            .pending = undefined,
            .pending_length = 0,
            .total_length = 0,
        };
    }

    pub fn update(storage: *abi.State, bytes: [*]const u8, length: usize) void {
        const state = of(storage);
        state.total_length +%= length;
        var input = bytes[0..length];
        if (state.pending_length != 0) {
            const taken = @min(input.len, state.pending.len - state.pending_length);
            @memcpy(state.pending[state.pending_length..][0..taken], input[0..taken]);
            state.pending_length += @intCast(taken);
            input = input[taken..];
            if (state.pending_length < state.pending.len) return;
            compress(&state.words, &state.pending);
            state.pending_length = 0;
        }
        const full = input.len - input.len % 64;
        for (std.mem.bytesAsSlice([64]u8, input[0..full])) |*block| {
            compress(&state.words, block);
        }
        @memcpy(state.pending[0 .. input.len - full], input[full..]);
        state.pending_length = @intCast(input.len - full);
    }

    pub fn final(storage: *abi.State, output: *[32]u8) void {
        const state = of(storage);
        var tail: [128]u8 = @splat(0);
        @memcpy(tail[0..state.pending_length], state.pending[0..state.pending_length]);
        tail[state.pending_length] = 0x80;
        const blocks: usize = if (state.pending_length < 56) 1 else 2;
        std.mem.writeInt(u64, tail[blocks * 64 - 8 ..][0..8], state.total_length *% 8, .big);
        for (std.mem.bytesAsSlice([64]u8, tail[0 .. blocks * 64])) |*block| {
            compress(&state.words, block);
        }
        for (state.words, 0..) |word, index| {
            std.mem.writeInt(u32, output[index * 4 ..][0..4], word, .big);
        }
    }
};

fn compress(words: *[8]u32, block: *const [64]u8) void {
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
    const working = if (comptime builtin.zig_backend == .stage2_x86_64)
        loopedRounds(words.*, &schedule)
    else
        unrolledRounds(words.*, &schedule);
    for (words, working) |*previous, word| previous.* +%= word;
}

fn loopedRounds(initial: [8]u32, schedule: *const [64]u32) [8]u32 {
    var a, var b, var c, var d, var e, var f, var g, var h = initial;
    for (schedule, constants) |word, constant| {
        const sigma1 = rotateWord(e, 6) ^ rotateWord(e, 11) ^ rotateWord(e, 25);
        const t1 = h +% sigma1 +% (g ^ (e & (f ^ g))) +% constant +% word;
        const t2 = (rotateWord(a, 2) ^ rotateWord(a, 13) ^ rotateWord(a, 22)) +%
            ((a & (b | c)) | (b & c));
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }
    return .{ a, b, c, d, e, f, g, h };
}

fn unrolledRounds(initial: [8]u32, schedule: *const [64]u32) [8]u32 {
    var working = initial;
    inline for (schedule, constants) |word, constant| round(&working, word +% constant);
    return working;
}

inline fn round(working: *[8]u32, input: u32) void {
    const rotr = std.math.rotr;
    const a, const b, const c, const d, const e, const f, const g, const h = working.*;
    const sigma1 = rotr(u32, e, 6) ^ rotr(u32, e, 11) ^ rotr(u32, e, 25);
    const t1 = h +% sigma1 +% (g ^ (e & (f ^ g))) +% input;
    const t2 = (rotr(u32, a, 2) ^ rotr(u32, a, 13) ^ rotr(u32, a, 22)) +%
        ((a & (b | c)) | (b & c));
    working.* = .{ t1 +% t2, a, b, c, d +% t1, e, f, g };
}

inline fn rotateWord(x: u32, comptime count: u5) u32 {
    return @call(.always_inline, std.math.rotr, .{ u32, x, count });
}

const constants = accelerated_unit.round_constants;

const vectors = [_]struct { input: []const u8, digest: []const u8 }{
    .{
        .input = "",
        .digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    },
    .{
        .input = "abc",
        .digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    },
    .{
        .input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        .digest = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    },
    .{
        .input = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" ++
            "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
        .digest = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    },
};

fn digestOf(comptime implementation: type, bytes: []const u8, split: usize) [32]u8 {
    var storage: abi.State = undefined;
    implementation.init(&storage);
    implementation.update(&storage, bytes.ptr, split);
    implementation.update(&storage, bytes[split..].ptr, bytes.len - split);
    var output: [32]u8 = undefined;
    implementation.final(&storage, &output);
    return output;
}

fn digestInChunks(comptime implementation: type, bytes: []const u8, random: std.Random) [32]u8 {
    var storage: abi.State = undefined;
    implementation.init(&storage);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk = 1 + random.uintLessThan(usize, @min(bytes.len - offset, 3 * 64 + 7));
        implementation.update(&storage, bytes[offset..].ptr, chunk);
        offset += chunk;
    }
    var output: [32]u8 = undefined;
    implementation.final(&storage, &output);
    return output;
}

test "software SHA-256 reproduces the standard vectors and a million repeated bytes" {
    for (vectors) |vector| {
        for ([_]usize{ 0, vector.input.len / 2, vector.input.len }) |split| {
            const actual = digestOf(software, vector.input, split);
            try std.testing.expectEqualStrings(vector.digest, &std.fmt.bytesToHex(actual, .lower));
        }
    }
    const repeated = try std.testing.allocator.alloc(u8, 1_000_000);
    defer std.testing.allocator.free(repeated);
    @memset(repeated, 'a');
    try std.testing.expectEqualStrings(
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        &std.fmt.bytesToHex(digestOf(software, repeated, 7), .lower),
    );
}

test "SHA-256 retains a seven-byte prefix across compression block boundaries" {
    var bytes: [129]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 37);
    const digests = [_][]const u8{
        "1b6e94ae18eff1dbc2ee77615845eaf55a88b19cb3a867179a0cfe90789943cf",
        "44d942056dd7041cfe6a1bbcb1a1f3afc385bb951b5efd787e71f514f29e1ddc",
        "a14a45b30d8e4eca06366744bea6597da4da3404e76a29019874cfec816bc586",
    };
    for (digests, 127..) |expected, length| {
        var state: abi.State = undefined;
        protean_native_sha256_init(&state);
        protean_native_sha256_update(&state, bytes[0..7], 7);
        protean_native_sha256_update(&state, bytes[7..].ptr, length - 7);
        var actual: [32]u8 = undefined;
        protean_native_sha256_final(&state, &actual);
        try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(actual, .lower));
        try std.testing.expectEqual(digestOf(software, bytes[0..length], 7), actual);
    }
}

test "the dispatch decision is recorded once and follows the CPU" {
    const first = path();
    try std.testing.expectEqual(first, path());
    try std.testing.expectEqual(
        @as(Path, if (acceleratedAvailable()) .accelerated else .software),
        first,
    );
    try std.testing.expectEqual(@backingInt(first), decision.load(.acquire));
    if (accelerated_target) try std.testing.expectEqual(Path.accelerated, first);
    if (!accelerated_target and !dispatched) try std.testing.expectEqual(Path.software, first);
}

test "accelerated SHA-256 agrees with the software oracle" {
    if (!acceleratedAvailable()) return std.testing.expectEqual(Path.software, path());
    for (vectors) |vector| {
        try std.testing.expectEqual(
            digestOf(software, vector.input, 0),
            digestOf(accelerated, vector.input, vector.input.len / 3),
        );
    }
    var bytes: [257]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 151 +% 13);
    for (0..bytes.len + 1) |length| {
        const expected = digestOf(software, bytes[0..length], 0);
        for ([_]usize{ 0, length / 2, length }) |split| {
            try std.testing.expectEqual(expected, digestOf(accelerated, bytes[0..length], split));
        }
    }
    try expectRandomAgreement(0x5348_4132_3536_0001, 48, 4 * 1024 * 1024);
}

fn expectRandomAgreement(seed: u64, cases: usize, longest: usize) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const bytes = try std.testing.allocator.alloc(u8, longest);
    defer std.testing.allocator.free(bytes);
    for (0..cases) |case| {
        const length = if (case % 4 == 0)
            random.uintAtMost(usize, longest)
        else
            random.uintAtMost(usize, 4096);
        random.bytes(bytes[0..length]);
        const input = bytes[0..length];
        const expected = digestOf(software, input, random.uintAtMost(usize, length));
        try std.testing.expectEqual(expected, digestInChunks(accelerated, input, random));
        try std.testing.expectEqual(expected, digestInChunks(software, input, random));
    }
}

test "the exported entry point produces the software oracle digest on every path" {
    var bytes: [1031]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 29);
    for ([_]usize{ 0, 1, 55, 56, 63, 64, 65, 127, 128, 1031 }) |length| {
        var state: abi.State = undefined;
        protean_native_sha256_init(&state);
        protean_native_sha256_update(&state, bytes[0..length].ptr, length);
        var actual: [32]u8 = undefined;
        protean_native_sha256_final(&state, &actual);
        try std.testing.expectEqual(digestOf(software, bytes[0..length], length / 2), actual);
    }
}
