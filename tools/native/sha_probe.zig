const std = @import("std");
const abi = @import("hash_abi");
extern fn protean_probe_cpu() u8;

pub fn main(init: std.process.Init) !void {
    const bytes = try init.gpa.alloc(u8, 64 * 1024 * 1024);
    defer init.gpa.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i);
    var digest: [32]u8 = undefined;
    const start = std.Io.Clock.awake.now(init.io).toMilliseconds();
    var hash: abi.State = undefined;
    abi.protean_native_sha256_init(&hash);
    for (0..1024) |i| abi.protean_native_sha256_update(&hash, bytes[i * 65536 ..].ptr, 65536);
    abi.protean_native_sha256_final(&hash, &digest);
    const finish = std.Io.Clock.awake.now(init.io).toMilliseconds();
    std.debug.print("SHA PROBE 64MiB chunked {d}ms accelerated={d} sha256={x}\n", .{
        finish - start, protean_probe_cpu(), &digest,
    });
    try std.testing.expectEqualStrings(
        "281e519df3077b557c6b03f5da83c4e8d397219259615dd7c3308f89cae8f2a6",
        &std.fmt.bytesToHex(digest, .lower),
    );
}
