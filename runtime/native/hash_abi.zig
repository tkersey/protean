//! Private C ABI between the application and the optimized standard-library
//! hash implementation. Both compile this one storage definition; neither
//! needs SQLite/libc header translation to establish the hash ABI.
pub const State = extern struct { storage: [256]u8 align(16) };

pub extern fn protean_native_sha256_init(storage: *State) void;
pub extern fn protean_native_sha256_update(storage: *State, bytes: [*]const u8, length: usize) void;
pub extern fn protean_native_sha256_final(storage: *State, output: *[32]u8) void;

pub extern fn protean_native_sha3_256(bytes: [*]const u8, length: usize, output: *[32]u8) void;
