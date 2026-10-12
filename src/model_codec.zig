//! The strict model JSON subset and its self-describing argument codecs.
//! Model-visible answers are data. This module grants no operation authority.
const std = @import("std");
const contracts = @import("protean_contracts");
pub const json = contracts.json;

pub const FieldKind = enum { text, signed_integer, unsigned_integer, boolean, enumeration };
const StructuredKind = enum { text, signed_integer, unsigned_integer, boolean, enumeration, product, sequence };
fn vector(comptime T: type) bool {
    return contracts.native.wrapped(T) and T.protean_value_kind == .vector;
}
fn structured(comptime T: type) bool {
    return !json.isText(T) and @typeInfo(T) == .@"struct";
}
fn nodeCount(comptime T: type) usize {
    if (vector(T)) return 1 + nodeCount(T.Child);
    if (structured(T)) {
        var count: usize = 1;
        for (@typeInfo(T).@"struct".field_types) |Child| count += nodeCount(Child);
        return count;
    }
    return 1;
}
const Maxima = struct {
    names: usize = 1,
    fields: usize = 0,
    enums: usize = 0,
    nodes: usize = 0,
    nested: bool = false,
    fn inspect(self: *Maxima, comptime name: []const u8, comptime T: type) void {
        self.names = @max(self.names, name.len);
        if (vector(T)) {
            self.nested = true;
            self.inspect("", T.Child);
        } else if (structured(T)) {
            self.nested = true;
            for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field, Child| self.inspect(field, Child);
        } else if (@typeInfo(T) == .@"enum") {
            const info = @typeInfo(T).@"enum";
            self.enums = @max(self.enums, info.field_names.len);
            for (info.field_names) |member| self.names = @max(self.names, member.len);
        }
    }
};
pub const DecodeFailure = enum {
    malformed,
    duplicate_field,
    unknown_field,
    missing_field,
    wrong_type,
    integer_range,
    capacity,
};

fn checkField(comptime name: []const u8, comptime T: type) void {
    if (json.isText(T)) {
        return;
    }
    if (vector(T)) return checkField(name, T.Child);
    switch (@typeInfo(T)) {
        .@"struct" => checkPayload(T),
        .bool => {},
        .int => |info| if (info.bits != 8 and info.bits != 16 and
            info.bits != 32 and info.bits != 64)
        {
            @compileError("Protean model codec integer width is unsupported: " ++ name);
        },
        .@"enum" => |info| {
            if (info.mode != .exhaustive)
                @compileError("Protean model codec requires an exhaustive enum: " ++ name);
            for (info.field_values) |value| if (value < 0 or value > std.math.maxInt(u32))
                @compileError("Protean model codec enum tags must fit u32: " ++ name);
        },
        else => @compileError("Protean model codec is unsupported for '" ++ name ++
            "': " ++ @typeName(T)),
    }
}

pub fn checkPayload(comptime T: type) void {
    if (json.isText(T)) @compileError("Protean model payload must be a product or enum");
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.is_tuple) @compileError("Protean model codec does not admit tuple payloads");
            for (info.field_names, info.field_types) |name, FieldType| checkField(name, FieldType);
        },
        .@"enum" => checkField("value", T),
        else => @compileError("Protean model payload must be a product or enum: " ++
            @typeName(T)),
    }
}

fn fieldCount(comptime T: type) usize {
    return if (@typeInfo(T) == .@"enum") 1 else @typeInfo(T).@"struct".field_names.len;
}

pub fn Profile(comptime Answer: type) type {
    if (@typeInfo(Answer) != .@"union" or @typeInfo(Answer).@"union".tag_type == null)
        @compileError("Protean model Answer must be a tagged union");
    const variants = @typeInfo(Answer).@"union".field_types;
    const maxima = comptime blk: {
        var result: Maxima = .{};
        for (variants) |Variant| {
            checkPayload(Variant);
            result.fields = @max(result.fields, fieldCount(Variant));
            if (@typeInfo(Variant) == .@"enum") {
                result.inspect("value", Variant);
                result.nodes = @max(result.nodes, 1);
            } else {
                var count: usize = 0;
                for (@typeInfo(Variant).@"struct".field_names, @typeInfo(Variant).@"struct".field_types) |name, FieldType| {
                    result.inspect(name, FieldType);
                    count += nodeCount(FieldType);
                }
                result.nodes = @max(result.nodes, count);
            }
        }
        break :blk result;
    };
    return struct {
        pub const FieldName = contracts.Text(maxima.names);
        pub const EnumNames = contracts.Vector(FieldName, maxima.enums);
        pub const EnumTags = contracts.Vector(u32, maxima.enums);
        pub const Field = struct {
            name: FieldName,
            kind: if (maxima.nested) StructuredKind else FieldKind,
            bit_width: u16,
            maximum_bytes: ?u64,
            enum_names: EnumNames,
            enum_tags: EnumTags,
        };
        /// Nested profiles use a preorder forest: products have one child per
        /// field, sequences have one unnamed element child. Flat profiles keep
        /// their exact existing field-vector codec and encoding.
        pub const Node = struct { field: Field, children: u32, maximum_items: ?u64 };
        pub const maximum_fields = maxima.fields;
        pub const Codec = if (maxima.nested) contracts.Vector(Node, maxima.nodes) else contracts.Vector(Field, maxima.fields);
        pub const Decoded = union(enum) { decoded: Answer, invalid: DecodeFailure };

        fn fieldValue(comptime name: []const u8, comptime T: type) Field {
            const enumeration = comptime if (@typeInfo(T) == .@"enum") blk: {
                const info = @typeInfo(T).@"enum";
                var names: [info.field_names.len]FieldName = undefined;
                var tags: [info.field_values.len]u32 = undefined;
                for (info.field_names, info.field_values, 0..) |member_name, member_value, i| {
                    names[i] = .{ .bytes = member_name };
                    tags[i] = @intCast(member_value);
                }
                const frozen_names = names;
                const frozen_tags = tags;
                break :blk .{ .names = frozen_names, .tags = frozen_tags };
            } else .{ .names = [_]FieldName{}, .tags = [_]u32{} };
            return .{
                .name = .{ .bytes = name },
                .kind = if (json.isText(T)) .text else if (vector(T)) .sequence else switch (@typeInfo(T)) {
                    .bool => .boolean,
                    .int => |info| if (info.signedness == .signed)
                        .signed_integer
                    else
                        .unsigned_integer,
                    .@"enum" => .enumeration,
                    .@"struct" => .product,
                    else => unreachable,
                },
                .bit_width = if (@typeInfo(T) == .int) @bitSizeOf(T) else 0,
                .maximum_bytes = if (json.isText(T)) T.max_length else null,
                .enum_names = .{ .items = &(comptime enumeration.names) },
                .enum_tags = .{ .items = &(comptime enumeration.tags) },
            };
        }

        fn appendNodes(comptime name: []const u8, comptime T: type, nodes: []Node, cursor: *usize) void {
            nodes[cursor.*] = .{ .field = fieldValue(name, T), .children = if (vector(T)) 1 else if (structured(T)) @intCast(@typeInfo(T).@"struct".field_names.len) else 0, .maximum_items = if (vector(T)) T.max_length else null };
            cursor.* += 1;
            if (vector(T)) {
                appendNodes("", T.Child, nodes, cursor);
            } else if (structured(T)) {
                for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field, Child| appendNodes(field, Child, nodes, cursor);
            }
        }

        /// Type-owned immutable metadata, never a slice into a live native stack.
        pub fn value(comptime index: usize) Codec {
            @setEvalBranchQuota(100_000);
            const Payload = variants[index];
            if (comptime maxima.nested) {
                const nodes = comptime blk: {
                    var result: [if (@typeInfo(Payload) == .@"enum") 1 else nodeCount(Payload) - 1]Node = undefined;
                    var cursor: usize = 0;
                    if (@typeInfo(Payload) == .@"enum") {
                        appendNodes("value", Payload, &result, &cursor);
                    } else for (@typeInfo(Payload).@"struct".field_names, @typeInfo(Payload).@"struct".field_types) |name, FieldType| appendNodes(name, FieldType, &result, &cursor);
                    break :blk result;
                };
                return .{ .items = &nodes };
            }
            const values = comptime blk: {
                var result: [fieldCount(Payload)]Field = undefined;
                if (@typeInfo(Payload) == .@"enum") {
                    result[0] = fieldValue("value", Payload);
                } else for (@typeInfo(Payload).@"struct".field_names, @typeInfo(Payload).@"struct".field_types, 0..) |name, FieldType, i| {
                    result[i] = fieldValue(name, FieldType);
                }
                break :blk result;
            };
            return .{ .items = &values };
        }
    };
}
