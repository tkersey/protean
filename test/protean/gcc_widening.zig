const std = @import("std");

noinline fn checkWidening(comptime Signed: type, value: Signed) !void {
    const expected_high: u64 = if (value < 0) std.math.maxInt(u64) else 0;
    const expected_low: u64 = @bitCast(@as(i64, value));
    const expected = (@as(u128, expected_high) << 64) | expected_low;
    const signed: i128 = value;
    try std.testing.expectEqual(expected, @as(u128, @bitCast(signed)));
    const decoded: i128 = @bitCast(expected);
    try std.testing.expectEqual(value, @as(Signed, @intCast(decoded)));
    const odd_width: i65 = value;
    const low_65: u65 = @truncate(expected);
    try std.testing.expectEqual(low_65, @as(u65, @bitCast(odd_width)));
    try std.testing.expectEqual(value, @as(Signed, @intCast(@as(i65, @bitCast(low_65)))));
    if (value >= 0) try std.testing.expectEqual(expected, @as(u128, @intCast(value)));

    const Unsigned = @Int(.unsigned, @bitSizeOf(Signed));
    const source_bits: Unsigned = @bitCast(value);
    const source_mask = std.math.maxInt(Unsigned);
    try std.testing.expectEqual(expected & source_mask, @as(u128, source_bits));
    const unsigned_expected: i128 = @intCast(expected & source_mask);
    try std.testing.expectEqual(unsigned_expected, @as(i128, source_bits));
}

test "generated C preserves sign extension and source-width bit casts" {
    inline for (.{ i7, i8, i15, i16, i24, i31, i32, i63, i64 }) |Signed| {
        const min = std.math.minInt(Signed);
        const max = std.math.maxInt(Signed);
        for ([_]Signed{ min, min + 1, -2, -1, 0, 1, max - 1, max }) |value|
            try checkWidening(Signed, value);
    }
}
