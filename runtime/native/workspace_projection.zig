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
    var end = start + @min(bytes.len - start, requested.maximum);
    if (start < bytes.len and bytes[start] & 0xc0 == 0x80) return error.InvalidRange;
    while (end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
    if (start != bytes.len and end == start) return error.InvalidRange;
    var result = json.object();
    try json.put(a, &result, "text", json.string(try a.dupe(u8, bytes[start..end])));
    try json.put(a, &result, "offset", try json.number(a, start));
    try json.put(a, &result, "next_offset", try json.number(a, end));
    try json.put(a, &result, "total_bytes", try json.number(a, bytes.len));
    try json.put(a, &result, "complete", .{ .bool = start == 0 and end == bytes.len });
    try json.put(a, &result, "eof", .{ .bool = end == bytes.len });
    return result;
}
pub fn schema(a: std.mem.Allocator, bytes: []const u8) !json.Value {
    var decoded = try data.schema.decode(a, bytes);
    defer decoded.deinit();
    return @import("source_records.zig").project(data.schema.Descriptor, a, decoded.descriptor);
}
