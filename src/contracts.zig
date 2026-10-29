//! Pure Protean value support over Horos native contracts and canonical value bytes.
//! This module imports no source compiler, evaluator, or process framing codec.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
pub const native = data.schema.native;
const wire = data.wire;
/// Pure JSON projections share this module identity with the ordinary codecs.
pub const json = @import("model_json.zig");
pub const workspace = @import("workspace_contracts.zig");
pub const controller = @import("controller_contracts.zig");
pub const tool_construction = @import("tool_construction_contracts.zig");

/// Immutable HTTP capture retained separately from model result projections.
pub const CapturedResponse = struct {
    status: u16,
    identity_encoding: bool,
    request_id: ?Utf8,
    body: Bytes(null),
};

/// Frozen read-only repository bytes; validation and capture belong to each
/// environment, while the record itself has one shared wire definition.
pub const RepositorySnapshotFile = struct {
    path: Utf8,
    sha256: [32]u8,
    contents: Bytes(null),
};
pub const RepositorySnapshot = struct {
    version: u32,
    excluded_entries: u64,
    files: Vector(RepositorySnapshotFile, null),
};

/// One ordinary inbox result shared by authoring and native environments.
/// The message identity and value stay bound across saved-reply recovery.
pub const inbox_semantic_identity = "agent.input.inbox.v1";
pub fn InboxReply(comptime Message: type) type {
    return union(enum) {
        empty: void,
        message: struct { id: Text(128), value: Message },
    };
}

/// Optional representation bounds never encode infinity as a numeric sentinel.
pub fn exceeds(length: usize, maximum: anytype) bool {
    return if (maximum) |limit| length > limit else false;
}

pub const Error = wire.Error || std.mem.Allocator.Error || error{InvalidValue};
pub const Descriptor = data.schema.Descriptor;

pub const Text = native.Text;
pub const Bytes = native.Bytes;
pub const Utf8 = native.Utf8;
pub const Vector = native.Vector;

/// Raw schema catalogs are a deliberate data/compiler integration boundary.
/// Ordinary application authoring uses its Context.schema(T) typed result.
pub fn schema(comptime T: type, builder: anytype) !p.Id {
    return native.lower(native.info(T), builder);
}

/// Canonical export of an explicit (including recursive) public schema catalog.
/// Upstream admission rejects internal resources and every containing schema.
pub fn descriptorOwned(
    allocator: std.mem.Allocator,
    types: []const p.Schema,
    root: p.Id,
) data.schema.Error!data.schema.Owned {
    return data.schema.canonicalize(allocator, types, root);
}

pub fn encodeOwned(comptime T: type, allocator: std.mem.Allocator, value: T) Error![]u8 {
    @setEvalBranchQuota(100_000);
    var measure: wire.Writer = .{};
    try write(T, value, &measure);
    const bytes = try allocator.alloc(u8, measure.position);
    errdefer allocator.free(bytes);
    var output: wire.Writer = .{ .output = bytes };
    try write(T, value, &output);
    return bytes;
}

/// Owns decoded containers. decodeOwned also owns byte/text slices;
/// decodeBorrowed keeps those slices in its caller-owned immutable input.
pub fn Decoded(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn decodeOwned(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Decoded(T) {
    return decode(T, allocator, bytes, false);
}

/// Uses the same value admission as decodeOwned, borrowing only byte/text
/// payloads. The immutable input must outlive the decoded value and its views.
pub fn decodeBorrowed(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Decoded(T) {
    return decode(T, allocator, bytes, true);
}

fn decode(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    comptime borrow_bytes: bool,
) Error!Decoded(T) {
    @setEvalBranchQuota(100_000);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var input: wire.Reader = .{ .input = bytes };
    const value = try read(T, arena.allocator(), &input, borrow_bytes);
    try input.finish();
    return .{ .arena = arena, .value = value };
}

fn checkBlob(comptime T: type, bytes: []const u8) Error!void {
    if (T.max_length) |maximum| if (bytes.len > maximum) return error.InvalidValue;
    if (T.protean_value_kind == .text and !std.unicode.utf8ValidateSlice(bytes))
        return error.InvalidUtf8;
}

inline fn write(comptime T: type, value: T, output: *wire.Writer) Error!void {
    _ = comptime native.info(T);
    if (comptime native.wrapped(T)) {
        if (T.protean_value_kind == .vector) {
            if (@as(
                ?u64,
                T.max_length,
            )) |maximum| if (value.items.len > maximum) return error.InvalidValue;
            return writeSlice(T.Child, value.items, output);
        }
        try checkBlob(T, value.bytes);
        return output.bytes(value.bytes);
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try output.byte(@intFromBool(value)),
        .int => {
            try output.fixed(T, value);
        },
        .@"enum" => {
            try output.fixed(u32, @intCast(@backingInt(value)));
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types) |field_name, FieldType|
            try write(FieldType, @field(value, field_name), output),
        .@"union" => |info| {
            inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
                if (std.meta.activeTag(value) == @field(info.tag_type.?, field_name)) {
                    try output.natural(index);
                    try write(FieldType, @field(value, field_name), output);
                    return;
                }
            }
        },
        .optional => |info| {
            try output.natural(if (value == null) 0 else 1);
            if (value) |present| try write(info.child, present, output);
        },
        .array => |info| for (value) |element| try write(info.child, element, output),
        .pointer => |info| {
            try writeSlice(info.child, value, output);
        },
        else => @compileError("Unsupported Protean portable value type: " ++ @typeName(T)),
    }
}

fn writeSlice(comptime T: type, values: []const T, output: *wire.Writer) Error!void {
    try output.natural(values.len);
    if (T == u8) return output.put(values);
    if (comptime minimumSize(T) == 0) return;
    for (values) |element| try write(T, element, output);
}

/// The minimum wire size lets hostile collection counts reject before allocation.
fn minimumSize(comptime T: type) usize {
    return minimumContract(native.info(T));
}
inline fn minimumContract(comptime shape: native.Info) usize {
    return switch (shape) {
        .unit => 0,
        .boolean => 1,
        .integer => |T| @sizeOf(T),
        .enumeration => 4,
        .product => |Fields| blk: {
            var size: usize = 0;
            inline for (@typeInfo(
                Fields,
            ).@"struct".field_types) |Child| size += minimumContract(Child.contract);
            break :blk size;
        },
        .array => |array| array.length * minimumContract(array.element.contract),
        .sum, .sequence, .text, .bytes => 1,
    };
}

inline fn read(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: *wire.Reader,
    comptime borrow_bytes: bool,
) Error!T {
    _ = comptime native.info(T);
    if (comptime native.wrapped(T)) {
        if (T.protean_value_kind == .vector) {
            const count = try input.count();
            if (@as(?u64, T.max_length)) |maximum| if (count > maximum) return error.InvalidValue;
            return .{ .items = try readElements(T.Child, allocator, input, count, borrow_bytes) };
        }
        const bytes = try input.bytes();
        try checkBlob(T, bytes);
        return .{ .bytes = if (borrow_bytes) bytes else try allocator.dupe(u8, bytes) };
    }
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try input.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidValue,
        },
        .int => blk: {
            break :blk input.fixed(T);
        },
        .@"enum" => readEnum(T, input),
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |field_name, FieldType|
                @field(result, field_name) = try read(FieldType, allocator, input, borrow_bytes);
            break :blk result;
        },
        .@"union" => |info| blk: {
            const tag = try input.natural();
            inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
                if (tag == index) break :blk @unionInit(
                    T,
                    field_name,
                    try read(FieldType, allocator, input, borrow_bytes),
                );
            }
            break :blk error.InvalidValue;
        },
        .optional => |info| switch (try input.natural()) {
            0 => null,
            1 => try read(info.child, allocator, input, borrow_bytes),
            else => error.InvalidValue,
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*element| element.* = try read(
                info.child,
                allocator,
                input,
                borrow_bytes,
            );
            break :blk result;
        },
        .pointer => |info| blk: {
            break :blk readElements(info.child, allocator, input, try input.count(), borrow_bytes);
        },
        else => @compileError("Unsupported Protean portable value type: " ++ @typeName(T)),
    };
}

fn readElements(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: *wire.Reader,
    count: usize,
    comptime borrow_bytes: bool,
) Error![]T {
    const minimum = comptime minimumSize(T);
    if (minimum > 0 and count > (input.input.len - input.position) / minimum)
        return error.Truncated;
    _ = std.math.mul(usize, count, @sizeOf(T)) catch return error.InvalidLength;
    const result = try allocator.alloc(T, count);
    if (comptime minimum == 0) return result;
    for (result) |*element| element.* = try read(T, allocator, input, borrow_bytes);
    return result;
}

fn readEnum(comptime T: type, input: *wire.Reader) Error!T {
    const tag = try input.fixed(u32);
    inline for (@typeInfo(T).@"enum".field_names, @typeInfo(
        T,
    ).@"enum".field_values) |field_name, field_value| {
        if (tag == field_value) return @field(T, field_name);
    }
    return error.InvalidValue;
}
