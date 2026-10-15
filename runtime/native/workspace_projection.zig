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
