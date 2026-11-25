//! Private C ABI between the application and the optimized
//! hash implementation. Both compile this one storage definition; neither
//! needs SQLite/libc header translation to establish the hash ABI.
pub const State = extern struct { storage: [256]u8 align(16) };

pub extern fn protean_native_sha256_init(storage: *State) void;
pub extern fn protean_native_sha256_update(storage: *State, bytes: [*]const u8, length: usize) void;
pub extern fn protean_native_sha256_final(storage: *State, output: *[32]u8) void;

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
