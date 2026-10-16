//! Truthful, bounded model observations. Runtime and owner state stay private.
const std = @import("std");
const c = @import("protean_contracts");
const data = @import("horos_data");
const json = @import("json.zig");
const state = @import("state.zig");
const w = c.workspace;

pub fn reference(a: std.mem.Allocator, kind: @FieldType(w.Ref, "kind"), digest: state.Digest) !w.Ref {
    return .{ .kind = kind, .id = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) } };
}
pub fn identity(ref: w.Ref, kind: @FieldType(w.Ref, "kind")) !state.Digest {
    if (ref.kind != kind or ref.id.bytes.len != 64) return error.InvalidReference;
    var result: state.Digest = undefined;
    _ = std.fmt.hexToBytes(&result, ref.id.bytes) catch return error.InvalidReference;
    return result;
}
pub fn page(a: std.mem.Allocator, bytes: []const u8, requested: w.Page) !json.Value {
    if (requested.maximum == 0 or requested.maximum > 48 * 1024 or requested.offset > bytes.len) return error.InvalidRange;
    const start: usize = @intCast(requested.offset);
    return window(a, bytes[start..][0..@min(bytes.len - start, requested.maximum + 1)], requested, bytes.len);
}

/// Fold serialized fragments into one byte range. Concatenation preserves
/// exact order and multiplicity without retaining the complete serialization.
pub const Range = struct {
    requested: w.Page,
    bytes: []u8,
    total: u64 = 0,
    used: usize = 0,

    pub fn init(a: std.mem.Allocator, requested: w.Page) !Range {
        if (requested.maximum == 0 or requested.maximum > 48 * 1024) return error.InvalidRange;
        return .{ .requested = requested, .bytes = try a.alloc(u8, requested.maximum + 1) };
    }
    pub fn deinit(self: *Range, a: std.mem.Allocator) void {
        a.free(self.bytes);
    }
    pub fn append(self: *Range, bytes: []const u8) !void {
        const end = try std.math.add(u64, self.total, bytes.len);
        if (end > self.requested.offset and self.used < self.bytes.len) {
            const start: usize = @intCast(self.requested.offset -| self.total);
            const count = @min(bytes.len - start, self.bytes.len - self.used);
            @memcpy(self.bytes[self.used..][0..count], bytes[start..][0..count]);
            self.used += count;
        }
        self.total = end;
    }
    pub fn finish(self: Range, a: std.mem.Allocator) !json.Value {
        return window(a, self.bytes[0..self.used], self.requested, self.total);
    }
};

/// A projected window includes one lookahead byte when it is not at EOF.
/// This preserves UTF-8 boundaries without materializing the complete value.
pub fn window(a: std.mem.Allocator, bytes: []const u8, requested: w.Page, total: u64) !json.Value {
    if (requested.maximum == 0 or requested.maximum > 48 * 1024 or requested.offset > total) return error.InvalidRange;
    if (bytes.len != @min(total - requested.offset, requested.maximum + 1)) return error.InvalidRange;
    var length = @min(bytes.len, requested.maximum);
    if (bytes.len != 0 and bytes[0] & 0xc0 == 0x80) return error.InvalidRange;
    while (length < bytes.len and bytes[length] & 0xc0 == 0x80) length -= 1;
    if (requested.offset != total and length == 0) return error.InvalidRange;
    const end = requested.offset + length;
    var result = json.object();
    try json.put(a, &result, "text", json.string(try a.dupe(u8, bytes[0..length])));
    try json.put(a, &result, "offset", try json.number(a, requested.offset));
    try json.put(a, &result, "next_offset", try json.number(a, end));
    try json.put(a, &result, "total_bytes", try json.number(a, total));
    try json.put(a, &result, "complete", .{ .bool = requested.offset == 0 and end == total });
    try json.put(a, &result, "eof", .{ .bool = end == total });
    return result;
}
pub fn schema(a: std.mem.Allocator, bytes: []const u8) !json.Value {
    var decoded = try data.schema.decode(a, bytes);
    defer decoded.deinit();
    return @import("source_records.zig").project(data.schema.Descriptor, a, decoded.descriptor);
}

test "range folding agrees with complete paging across every fragment boundary" {
    const a = std.testing.allocator;
    const text = "[{},\"é🙂\",{},{}]";
    for (0..text.len + 1) |split| {
        for (0..text.len + 2) |offset| {
            for (1..6) |maximum| {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const scratch = arena.allocator();
                const request: w.Page = .{ .offset = offset, .maximum = @intCast(maximum) };
                var range = try Range.init(scratch, request);
                try range.append(text[0..split]);
                try range.append("");
                try range.append(text[split..]);
                const expected = page(scratch, text, request) catch |err| {
                    try std.testing.expectError(err, range.finish(scratch));
                    continue;
                };
                try std.testing.expectEqualStrings(try json.canonical(scratch, expected), try json.canonical(scratch, try range.finish(scratch)));
            }
        }
    }
}
