const std = @import("std");
const horos = @import("horos");
const authoring = @import("authoring.zig");
const source = horos.source;
const Id = source.Id;

pub const identity_prefix = "agent.notification.deliver.v1.";

pub fn Request(comptime Destination: type, comptime Key: type, comptime Payload: type) type {
    return struct { destination: Destination, key: Key, payload: Payload };
}

pub fn Dispatcher(comptime Input: type, comptime Result: type) type {
    const RequestType = @FieldType(Input, "delivery");
    const Reply = @FieldType(Result, "delivery");
    comptime {
        if (@typeInfo(Input) != .@"union" or @typeInfo(Result) != .@"union")
            @compileError("notification dispatcher requires tagged input and result unions");
        if (@typeInfo(Input).@"union".tag_type == null or
            @typeInfo(Result).@"union".tag_type == null)
            @compileError("notification dispatcher requires tagged input and result unions");
        if (@typeInfo(RequestType) != .@"struct")
            @compileError("notification request requires a product");
        for (.{ "destination", "key", "payload" }) |field| {
            if (!@hasField(RequestType, field))
                @compileError("notification request requires " ++ field);
        }
    }
    return struct {
        pub fn emit(c: authoring.Context, name: []const u8, ordinary: Id) !Id {
            const b = c.builder;
            try validateName(name);
            if (ordinary >= b.functions.items.len) return error.InvalidNotificationEntry;
            const input = try schema(c, Input);
            const result = try schema(c, Result);
            const delegate = b.functions.items[@intCast(ordinary)];
            if (delegate.parameters.len != 1 or delegate.result != result or
                delegate.parameters[0] >= b.variables.items.len or
                b.variables.items[@intCast(delegate.parameters[0])] != input)
                return error.InvalidNotificationEntry;
            const operation = try c.external(
                try b.allocator().print("{s}{s}", .{ identity_prefix, name }),
                try c.schema(RequestType),
                try c.schema(Reply),
                .write,
            );
            const effect = try horos.authoring.interop.operationId(c.author, operation);
            const count = try std.math.add(usize, delegate.effects.len, 1);
            const effects = try b.allocator().alloc(Id, count);
            @memcpy(effects[0..delegate.effects.len], delegate.effects);
            effects[delegate.effects.len] = effect;
            const entry = try b.declare(&.{input}, result, effects, &.{});
            const argument = try b.reference(b.functions.items[@intCast(entry)].parameters[0]);
            const fields = @typeInfo(Input).@"union";
            var cases: [fields.field_names.len]std.meta.Elem(@FieldType(
                @FieldType(source.ast.Term, "match_sum"),
                "cases",
            )) = undefined;
            inline for (fields.field_names, fields.field_types, 0..) |field, FieldType, index| {
                const variable = try b.variable(try schema(c, FieldType));
                cases[index] = .{
                    .variable = variable,
                    .body = if (comptime std.mem.eql(u8, field, "delivery"))
                        try deliver(c, entry, effect, variable)
                    else
                        try b.term(.{ .call = .{
                            .function = ordinary,
                            .arguments = &.{argument},
                        } }),
                };
            }
            const body = try b.term(.{ .match_sum = .{ .value = argument, .cases = &cases } });
            try b.define(entry, body);
            const registry_allocator = c.registry.arena.allocator();
            try c.registry.entry_dispatches.append(c.registry.arena.allocator(), .{
                .function = entry,
                .body = body,
                .ordinary = ordinary,
                .effect = effect,
                .identity = try registry_allocator.dupe(
                    u8,
                    b.effects.items[@intCast(effect)].identity,
                ),
                .delivery_case = comptime fieldIndex(Input, "delivery"),
                .result_case = comptime fieldIndex(Result, "delivery"),
                .case_count = fields.field_names.len,
            });
            return entry;
        }

        fn deliver(c: authoring.Context, entry: Id, effect: Id, request: Id) !Id {
            const b = c.builder;
            const perform = try b.term(.{ .perform = .{
                .effect = effect,
                .payload = try b.reference(request),
            } });
            try c.registry.protectSite(entry, perform, effect);
            const reply = try b.variable(try schema(c, Reply));
            const returned = try b.primitive(
                try schema(c, Result),
                .variant,
                &.{try b.reference(reply)},
                comptime fieldIndex(Result, "delivery"),
            );
            return b.bind(reply, perform, try b.pure(returned));
        }
    };
}

fn schema(c: authoring.Context, comptime T: type) !Id {
    return horos.authoring.interop.schemaId(c.author, try c.schema(T));
}

fn fieldIndex(comptime T: type, comptime name: []const u8) Id {
    inline for (@typeInfo(T).@"union".field_names, 0..) |field, index| {
        if (comptime std.mem.eql(u8, field, name)) return index;
    }
    @compileError("notification variant is missing");
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0]))
        return error.InvalidNotificationIdentity;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_')
            return error.InvalidNotificationIdentity;
    }
}
