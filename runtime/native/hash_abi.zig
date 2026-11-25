//! Private C ABI between the application and the optimized
//! hash implementation. Both compile this one storage definition; neither
//! needs SQLite/libc header translation to establish the hash ABI.
const std = @import("std");
const builtin = @import("builtin");

pub const State = extern struct { storage: [256]u8 align(16) };

extern fn protean_native_sha256_init(storage: *State) void;
extern fn protean_native_sha256_update(storage: *State, bytes: [*]const u8, length: usize) void;
extern fn protean_native_sha256_final(storage: *State, output: *[32]u8) void;

pub extern fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void;

pub const Sha256 = struct {
    state: State,

    pub const digest_length = 32;
    pub const Options = struct {};

    pub fn init(_: Options) Sha256 {
        var self: Sha256 = undefined;
        protean_native_sha256_init(&self.state);
        return self;
    }

    pub fn update(self: *Sha256, bytes: []const u8) void {
        protean_native_sha256_update(&self.state, bytes.ptr, bytes.len);
    }

    pub fn final(self: *Sha256, output: *[digest_length]u8) void {
        protean_native_sha256_final(&self.state, output);
        if (comptime builtin.is_test) observation.observe(output);
    }

    pub fn finalResult(self: *Sha256) [digest_length]u8 {
        var output: [digest_length]u8 = undefined;
        self.final(&output);
        return output;
    }

    pub fn hash(bytes: []const u8, output: *[digest_length]u8, options: Options) void {
        var self: Sha256 = .init(options);
        self.update(bytes);
        self.final(output);
    }
};

pub const observation = if (builtin.is_test) struct {
    const subjects_max = 4;
    var keys: [subjects_max]std.atomic.Value(u64) = @splat(.init(0));
    var counts: [subjects_max]std.atomic.Value(u64) = @splat(.init(0));

    pub fn watch(subjects: []const []const u8) void {
        std.debug.assert(subjects.len <= subjects_max);
        var named: [subjects_max]u64 = @splat(0);
        for (subjects, named[0..subjects.len]) |subject, *slot| {
            var state: State = undefined;
            protean_native_sha256_init(&state);
            protean_native_sha256_update(&state, subject.ptr, subject.len);
            var digest: [Sha256.digest_length]u8 = undefined;
            protean_native_sha256_final(&state, &digest);
            slot.* = key(&digest);
        }
        for (&keys, &counts, named) |*watched, *count, value| {
            count.store(0, .seq_cst);
            watched.store(value, .seq_cst);
        }
    }

    pub fn observed(subject: usize) u64 {
        return counts[subject].load(.seq_cst);
    }

    fn observe(result: *const [Sha256.digest_length]u8) void {
        const observed_key = key(result);
        for (&keys, &counts) |*watched, *count| {
            if (watched.load(.seq_cst) == observed_key) _ = count.fetchAdd(1, .seq_cst);
        }
    }

    fn key(value: *const [Sha256.digest_length]u8) u64 {
        return @max(1, std.mem.readInt(u64, value[0..8], .little));
    }
} else struct {};
