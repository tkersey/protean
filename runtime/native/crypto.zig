const std = @import("std");

pub const secureZero = std.crypto.secureZero;
pub const Ed25519 = std.crypto.sign.Ed25519;
pub const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
pub const Sha256 = @import("hash_abi.zig").Sha256;
