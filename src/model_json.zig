const std = @import("std");

pub fn taggedOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional and @typeInfo(@typeInfo(T).optional.child) == .optional;
}

fn containsTaggedOptional(comptime T: type) bool {
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "protean_value_kind")) {
        return if (T.protean_value_kind == .vector) containsTaggedOptional(T.Child) else false;
    }
    return switch (@typeInfo(T)) {
        .optional => |info| taggedOptional(T) or containsTaggedOptional(info.child),
        .array => |info| containsTaggedOptional(info.child),
        inline .@"struct", .@"union" => |info| blk: {
            inline for (info.field_types) |Field| if (containsTaggedOptional(Field)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Preserve the existing mapping identity when no client representation changes.
pub fn clientMapping(comptime types: anytype) []const u8 {
    inline for (types) |T| if (containsTaggedOptional(T)) return "agent-client-values/1.1";
    return "agent-client-values/1.0";
}
pub fn isText(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "protean_value_kind") and
        T.protean_value_kind == .text;
}

pub fn maximumTextBytes(comptime T: type) usize {
    if (T.max_length == null) @compileError("Protean model JSON requires bounded Text");
    return @intCast(T.max_length.?);
}

const CountingWriter = struct {
    length: usize = 0,

    fn byte(self: *@This(), _: u8) void {
        self.length += 1;
    }

    fn raw(self: *@This(), value: []const u8) void {
        self.length += value.len;
    }
};

fn FixedWriter(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        cursor: usize = 0,

        fn byte(self: *@This(), value: u8) void {
            if (self.cursor >= capacity) @compileError("protean JSON writer overflow");
            self.bytes[self.cursor] = value;
            self.cursor += 1;
        }

        fn raw(self: *@This(), value: []const u8) void {
            if (value.len > capacity - self.cursor) {
                @compileError("protean JSON writer overflow");
            }
            @memcpy(self.bytes[self.cursor..][0..value.len], value);
            self.cursor += value.len;
        }

        fn finish(self: @This()) [capacity]u8 {
            if (self.cursor != capacity) @compileError("protean JSON writer underflow");
            return self.bytes;
        }
    };
}

fn writeString(writer: anytype, comptime value: []const u8) void {
    if (!std.unicode.utf8ValidateSlice(value)) {
        @compileError("protean JSON source string must be valid UTF-8");
    }
    const hex = "0123456789abcdef";
    writer.byte('"');
    inline for (value) |byte| switch (byte) {
        '"' => writer.raw("\\\""),
        '\\' => writer.raw("\\\\"),
        0x08 => writer.raw("\\b"),
        0x0c => writer.raw("\\f"),
        '\n' => writer.raw("\\n"),
        '\r' => writer.raw("\\r"),
        '\t' => writer.raw("\\t"),
        0x00...0x07, 0x0b, 0x0e...0x1f => {
            writer.raw("\\u00");
            writer.byte(hex[byte >> 4]);
            writer.byte(hex[byte & 0x0f]);
        },
        else => writer.byte(byte),
    };
    writer.byte('"');
}

fn writeUnsigned(writer: anytype, comptime value: anytype) void {
    writer.raw(std.fmt.comptimePrint("{d}", .{value}));
}

fn writeSchema(comptime T: type, writer: anytype) void {
    if (comptime isText(T)) {
        writer.raw("{\"type\":\"string\",\"description\":\"UTF-8 encoding must not exceed ");
        writeUnsigned(writer, maximumTextBytes(T));
        writer.raw(" bytes; maxLength is an additional character-count bound.\",\"maxLength\":");
        writeUnsigned(writer, maximumTextBytes(T));
        writer.byte('}');
        return;
    }
    switch (@typeInfo(T)) {
        .void => writer.raw("{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}"),
        .bool => writer.raw("{\"type\":\"boolean\"}"),
        .int => {
            writer.raw("{\"type\":\"integer\",\"minimum\":");
            writer.raw(std.fmt.comptimePrint("{d}", .{std.math.minInt(T)}));
            writer.raw(",\"maximum\":");
            writer.raw(std.fmt.comptimePrint("{d}", .{std.math.maxInt(T)}));
            writer.byte('}');
        },
        .@"enum" => |info| {
            writer.raw("{\"type\":\"string\",\"enum\":[");
            inline for (info.field_names, 0..) |field_name, index| {
                if (index != 0) writer.byte(',');
                writeString(writer, field_name);
            }
            writer.raw("]}");
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                @compileError("protean JSON tuple schemas are not implemented yet");
            }
            writer.raw("{\"type\":\"object\",\"properties\":{");
            inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
                if (index != 0) writer.byte(',');
                writeString(writer, field_name);
                writer.byte(':');
                writeSchema(FieldType, writer);
            }
            writer.raw("},\"required\":[");
            inline for (info.field_names, 0..) |field_name, index| {
                if (index != 0) writer.byte(',');
                writeString(writer, field_name);
            }
            writer.raw("],\"additionalProperties\":false}");
        },
        else => @compileError("protean JSON schema does not support " ++ @typeName(T)),
    }
}

fn writeToolSchema(comptime T: type, writer: anytype) void {
    if (@typeInfo(T) == .@"enum") {
        writer.raw("{\"type\":\"object\",\"properties\":{\"value\":");
        writeSchema(T, writer);
        writer.raw("},\"required\":[\"value\"],\"additionalProperties\":false}");
    } else {
        writeSchema(T, writer);
    }
}

/// Canonical provider-neutral JSON Schema bytes for one strict Action payload.
pub fn Schema(comptime T: type) type {
    return struct {
        const length = blk: {
            @setEvalBranchQuota(100_000);
            var writer = CountingWriter{};
            writeSchema(T, &writer);
            break :blk writer.length;
        };
        pub const value = blk: {
            @setEvalBranchQuota(100_000);
            var writer = FixedWriter(length){};
            writeSchema(T, &writer);
            break :blk writer.finish();
        };
    };
}

/// Canonical provider tool schema. Non-product authored-failure payloads use
/// one explicit `value` field because provider function inputs are objects.
pub fn ToolSchema(comptime T: type) type {
    return struct {
        const length = blk: {
            @setEvalBranchQuota(100_000);
            var writer = CountingWriter{};
            writeToolSchema(T, &writer);
            break :blk writer.length;
        };
        pub const value = blk: {
            @setEvalBranchQuota(100_000);
            var writer = FixedWriter(length){};
            writeToolSchema(T, &writer);
            break :blk writer.finish();
        };
    };
}

/// Versioned client mapping used by the native environment. Provider schemas
/// above retain their existing numeric meaning. Full-width client integers are
/// decimal strings; bytes are base64url; sums have explicit tag/value fields.
pub fn ClientSchema(comptime T: type) type {
    return struct {
        const length = blk: {
            @setEvalBranchQuota(1_000_000);
            var writer = CountingWriter{};
            writeClientSchema(T, &writer);
            break :blk writer.length;
        };
        pub const value = blk: {
            @setEvalBranchQuota(1_000_000);
            var writer = FixedWriter(length){};
            writeClientSchema(T, &writer);
            break :blk writer.finish();
        };
    };
}

// A positive decimal range partitions at the first digit below the maximum.
// Zero and the sign are supplied by the caller; leading zeros never enter it.
fn writePositiveDecimalRange(comptime maximum: u64, writer: anytype) void {
    const digits = std.fmt.comptimePrint("{d}", .{maximum});
    if (digits.len > 1) {
        writer.raw("[1-9][0-9]{0,");
        writeUnsigned(writer, digits.len - 2);
        writer.raw("}|");
    }
    for (digits, 0..) |digit, i| {
        const lower: u8 = if (i == 0) '1' else '0';
        if (digit <= lower) continue;
        writer.raw(digits[0..i]);
        writer.byte('[');
        writer.byte(lower);
        writer.byte('-');
        writer.byte(digit - 1);
        writer.raw("][0-9]{");
        writeUnsigned(writer, digits.len - i - 1);
        writer.raw("}|");
    }
    writer.raw(digits);
}

fn writeClientSchema(comptime T: type, writer: anytype) void {
    if (comptime isText(T)) {
        writer.raw("{\"type\":\"string\",\"maxLength\":");
        writeUnsigned(writer, maximumTextBytes(T));
        writer.raw(",\"x-max-utf8-bytes\":");
        writeUnsigned(writer, maximumTextBytes(T));
        writer.byte('}');
        return;
    }
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "protean_value_kind")) {
        if (T.protean_value_kind == .bytes) {
            const maximum = T.max_length orelse @compileError("client bytes must be bounded");
            writer.raw("{\"type\":\"string\",\"contentEncoding\":\"base64url\",\"maxLength\":");
            writeUnsigned(writer, std.base64.url_safe_no_pad.Encoder.calcSize(maximum));
            writer.raw(",\"x-maximum-bytes\":");
            writeUnsigned(writer, maximum);
            // Complete groups, then only canonical zero-padded terminal bits.
            // Strict end assertion also rejects a final newline.
            writer.raw(",\"pattern\":\"^(?:[A-Za-z0-9_-]{4})*(?:[A-Za-z0-9_-][AQgw]|[A-Za-z0-9_-]{2}[AEIMQUYcgkosw048])?(?![\\\\s\\\\S])\"");
            writer.byte('}');
            return;
        }
        if (T.protean_value_kind == .vector) {
            writer.raw("{\"type\":\"array\",\"maxItems\":");
            writeUnsigned(writer, T.max_length);
            writer.raw(",\"items\":");
            writeClientSchema(T.Child, writer);
            writer.byte('}');
            return;
        }
    }
    switch (@typeInfo(T)) {
        .void, .bool, .@"enum" => writeSchema(T, writer),
        .int => |info| {
            if (info.bits <= 32) return writeSchema(T, writer);
            if (info.bits != 64) @compileError("unsupported client integer width");
            writer.raw("{\"type\":\"string\",\"pattern\":\"");
            writer.raw("^(0|");
            writePositiveDecimalRange(std.math.maxInt(T), writer);
            if (info.signedness == .signed) {
                writer.raw("|-(");
                writePositiveDecimalRange(@as(u64, std.math.maxInt(T)) + 1, writer);
                writer.byte(')');
            }
            writer.raw(")(?![\\\\s\\\\S])");
            writer.raw("\",\"x-integer-minimum\":\"");
            writer.raw(std.fmt.comptimePrint("{d}", .{std.math.minInt(T)}));
            writer.raw("\",\"x-integer-maximum\":\"");
            writer.raw(std.fmt.comptimePrint("{d}", .{std.math.maxInt(T)}));
            writer.raw("\"}");
        },
        .optional => |info| {
            writer.raw("{\"anyOf\":[{\"type\":\"null\"},");
            if (comptime taggedOptional(T)) writer.raw("{\"type\":\"object\",\"properties\":{\"tag\":{\"const\":\"some\"},\"value\":");
            writeClientSchema(info.child, writer);
            if (comptime taggedOptional(T)) writer.raw("},\"required\":[\"tag\",\"value\"],\"additionalProperties\":false}");
            writer.raw("]}");
        },
        .array => |info| {
            writer.raw("{\"type\":\"array\",\"minItems\":");
            writeUnsigned(writer, info.len);
            writer.raw(",\"maxItems\":");
            writeUnsigned(writer, info.len);
            writer.raw(",\"items\":");
            writeClientSchema(info.child, writer);
            writer.byte('}');
        },
        .@"struct" => |info| {
            if (info.is_tuple) @compileError("client tuples need an explicit named mapping");
            writer.raw("{\"type\":\"object\",\"properties\":{");
            inline for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
                if (i != 0) writer.byte(',');
                writeString(writer, name);
                writer.byte(':');
                writeClientSchema(FieldType, writer);
            }
            writer.raw("},\"required\":[");
            inline for (info.field_names, 0..) |name, i| {
                if (i != 0) writer.byte(',');
                writeString(writer, name);
            }
            writer.raw("],\"additionalProperties\":false}");
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("client union must be tagged");
            writer.raw("{\"oneOf\":[");
            inline for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
                if (i != 0) writer.byte(',');
                writer.raw("{\"type\":\"object\",\"properties\":{\"tag\":{\"const\":");
                writeString(writer, name);
                writer.raw("},\"value\":");
                writeClientSchema(FieldType, writer);
                writer.raw("},\"required\":[\"tag\",\"value\"],\"additionalProperties\":false}");
            }
            writer.raw("]}");
        },
        else => @compileError("client values require a bounded ordinary contract: " ++ @typeName(T)),
    }
}

fn maximumValueBytes(comptime T: type) usize {
    if (comptime isText(T)) {
        return 2 + 6 * maximumTextBytes(T);
    }
    return switch (@typeInfo(T)) {
        .void => 2,
        .bool => 5,
        .int => @max(
            std.fmt.comptimePrint("{d}", .{std.math.minInt(T)}).len,
            std.fmt.comptimePrint("{d}", .{std.math.maxInt(T)}).len,
        ),
        .@"enum" => |info| blk: {
            var maximum: usize = 2;
            inline for (info.field_names) |field_name| {
                maximum = @max(maximum, 2 + 6 * field_name.len);
            }
            break :blk maximum;
        },
        .@"struct" => |info| blk: {
            var maximum: usize = 2;
            inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, index| {
                if (index != 0) maximum += 1;
                maximum += 2 + 6 * field_name.len + 1;
                maximum += maximumValueBytes(FieldType);
            }
            break :blk maximum;
        },
        else => @compileError(
            "protean JSON value bound does not support " ++ @typeName(T),
        ),
    };
}

pub fn maximumToolArgumentsByteLength(comptime T: type) usize {
    return if (@typeInfo(T) == .@"enum")
        10 + maximumValueBytes(T)
    else
        maximumValueBytes(T);
}
