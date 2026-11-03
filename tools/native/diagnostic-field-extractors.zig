const std = @import("std");
const data = @import("horos_data");
const g = data.graph;
const Store = @import("../interpreter_v2/store.zig").Store;

pub const GuestValue = struct {
    schema: u64,
    kind: u64,
    blob_id: ?u64,
};

fn encoded(store: *const Store, value: g.Value) ?[]const u8 {
    if (value.body != .blob) return null;
    const id = std.math.cast(usize, value.body.blob.id) orelse return null;
    if (id >= store.blobs.items.len or !store.blob_alive.items[id]) return null;
    return store.blobs.items[id].bytes;
}

fn aggregate(store: *const Store, value: g.Value) ?@FieldType(g.Node, "aggregate") {
    const reference = switch (value.body) {
        .reference => |reference| reference,
        .owned => |owned| owned.node,
        else => return null,
    };
    const node = store.get(reference) catch return null;
    if (node != .aggregate) return null;
    return node.aggregate;
}

pub fn scalarU64(store: *const Store, value: g.Value) ?u64 {
    if (value.body == .scalar) return std.mem.readInt(u64, &value.body.scalar, .little);
    const bytes = encoded(store, value) orelse return null;
    if (bytes.len != 8) return null;
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn blobReference(store: *const Store, value: g.Value) ?u64 {
    if (aggregate(store, value)) |parts| {
        if (parts.fields.len != 1) return null;
        return scalarU64(store, parts.fields[0]);
    }
    return scalarU64(store, value);
}

fn guestBody(store: *const Store, schema: u64, value: g.Value) ?GuestValue {
    if (aggregate(store, value)) |parts| {
        if (parts.tag > 3 or parts.fields.len != 1) return null;
        return .{
            .schema = schema,
            .kind = parts.tag,
            .blob_id = if (parts.tag == 1)
                blobReference(store, parts.fields[0]) orelse return null
            else
                null,
        };
    }
    var reader: data.wire.Reader = .{ .input = encoded(store, value) orelse return null };
    const kind = reader.natural() catch return null;
    if (kind > 3) return null;
    return .{
        .schema = schema,
        .kind = kind,
        .blob_id = if (kind == 1) reader.fixed(u64) catch return null else null,
    };
}

pub fn guestValue(store: *const Store, value: g.Value) ?GuestValue {
    if (aggregate(store, value)) |parts| {
        if (parts.fields.len != 2) return null;
        const schema = scalarU64(store, parts.fields[0]) orelse return null;
        return guestBody(store, schema, parts.fields[1]);
    }
    var reader: data.wire.Reader = .{ .input = encoded(store, value) orelse return null };
    const schema = reader.fixed(u64) catch return null;
    const kind = reader.natural() catch return null;
    if (kind > 3) return null;
    return .{
        .schema = schema,
        .kind = kind,
        .blob_id = if (kind == 1) reader.fixed(u64) catch return null else null,
    };
}

pub fn bytesLength(store: *const Store, value: g.Value) ?u64 {
    var reader: data.wire.Reader = .{ .input = encoded(store, value) orelse return null };
    const bytes = reader.bytes() catch return null;
    reader.finish() catch return null;
    return @intCast(bytes.len);
}
