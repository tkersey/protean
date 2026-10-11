//! Build-time compiled relational components. Runtime only receives their BMO1.
const std = @import("std");
const horos = @import("horos");
const c = @import("protean_contracts");
const t = @import("application_types").tool_types;
const source = horos.source;
const data = horos.data;
const Id = source.Id;
pub const kinds = [_]Kind{ .compose, .map, .filter, .selected, .join, .classify, .orphan, .swap, .group };
pub const Kind = enum { compose, map, filter, selected, join, classify, orphan, swap, group };

const E = struct {
    b: *source.Builder,
    unit: Id,
    integer: Id,
    boolean: Id,
    row: Id,
    rows: Id,
    keys: Id,
    table: Id,
    fn init(b: *source.Builder) !E {
        return .{ .b = b, .unit = try b.scalar(void), .integer = try b.scalar(u64), .boolean = try b.scalar(bool), .row = try c.schema(t.Row, b), .rows = try c.schema(t.Rows, b), .keys = try c.schema(t.Keys, b), .table = try c.schema(t.Table, b) };
    }
    fn n(e: E, value: u64) !Id {
        return e.b.constant(u64, value);
    }
    fn param(e: E, f: Id, index: usize) !Id {
        return e.b.reference(e.b.parameter(f, index));
    }
    fn field(e: E, schema: Id, value: Id, index: u64) !Id {
        return e.b.primitive(schema, .field, &.{value}, index);
    }
    fn col(e: E, value: Id, index: u64) !Id {
        return e.field(e.integer, value, index);
    }
    fn eq(e: E, left: Id, right: Id) !Id {
        return e.b.primitive(e.boolean, .equal, &.{ left, right }, 0);
    }
    fn length(e: E, value: Id) !Id {
        return e.b.primitive(e.integer, .sequence_length, &.{value}, 0);
    }
    fn call(e: E, f: Id, args: []const Id) !Id {
        return e.b.term(.{ .call = .{ .function = f, .arguments = args } });
    }
    fn choose(e: E, condition: Id, yes: Id, no: Id) !Id {
        return e.b.term(.{ .conditional = .{ .condition = condition, .when_true = yes, .when_false = no } });
    }
    fn primitive(e: E, schema: Id, opcode: data.program.Opcode, operands: []const Id, fault: data.program.Fault) !Id {
        return e.b.value(.{ .schema = schema, .expression = .{ .primitive = .{ .opcode = opcode, .operands = operands, .failures = &.{.{ .kind = fault, .value = try e.b.failureLiteral(try e.b.constant(void, {})) }} } } });
    }
    fn add(e: E, left: Id, right: Id) !Id {
        return e.primitive(e.integer, .integer_add, &.{ left, right }, .arithmetic_overflow);
    }
    fn get(e: E, schema: Id, list: Id, index: Id) !Id {
        const optional = try e.b.schema(.{ .sum = &.{ e.unit, schema } });
        const found = try e.b.primitive(optional, .sequence_get, &.{ list, index }, 0);
        return e.b.value(.{ .schema = schema, .expression = .{ .primitive = .{
            .opcode = .variant_payload,
            .operands = &.{found},
            .immediate = 1,
            .failures = &.{.{ .kind = .invalid_variant, .value = try e.b.failureLiteral(try e.b.constant(void, {})) }},
        } } });
    }
    fn append(e: E, list: Id, row: Id) !Id {
        return e.primitive(e.rows, .sequence_append, &.{ list, row }, .capacity_exceeded);
    }
    fn empty(e: E) !Id {
        return e.b.primitive(e.rows, .sequence, &.{}, 0);
    }
    fn tableWith(e: E, table: Id, rows: Id, relation: ?Id) !Id {
        return e.b.primitive(e.table, .product, &.{ rows, relation orelse try e.field(e.rows, table, 1), try e.field(e.keys, table, 2) }, 0);
    }
    fn rowWith(e: E, row: Id, changes: anytype) !Id {
        var fields: [8]Id = undefined;
        inline for (@typeInfo(t.Row).@"struct".field_names, 0..) |name, i| fields[i] = if (@hasField(@TypeOf(changes), name)) @field(changes, name) else try e.col(row, i);
        return e.b.primitive(e.row, .product, &fields, 0);
    }
};
fn symbol(name: []const u8, function: Id) data.component.Symbol {
    return .{ .name = name, .reference = .{ .kind = .function, .id = function } };
}

pub fn emit(allocator: std.mem.Allocator, kind: Kind) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const e = try E.init(&b);
    var imports: std.ArrayList(data.component.Symbol) = .empty;
    var borrows: std.ArrayList(data.borrow_contract.Summary) = .empty;
    const a = b.allocator();
    const root = switch (kind) {
        .compose => blk: {
            const first = try b.declare(&.{e.table}, e.table, &.{}, &.{});
            const second = try b.declare(&.{e.table}, e.table, &.{}, &.{});
            try imports.appendSlice(a, &.{ symbol("first", first), symbol("second", second) });
            try borrows.appendSlice(a, &.{ .{ .function = first }, .{ .function = second } });
            const entry = try b.declare(&.{e.table}, e.table, &.{}, &.{});
            const intermediate = try b.variable(e.table);
            try b.define(entry, try b.bind(intermediate, try e.call(first, &.{try e.param(entry, 0)}), try e.call(second, &.{try b.reference(intermediate)})));
            break :blk entry;
        },
        .map, .filter => blk: {
            const operation = try b.declare(&.{ e.table, e.row }, if (kind == .map) e.row else e.boolean, &.{}, &.{});
            try imports.append(a, symbol(if (kind == .map) "row" else "keep", operation));
            try borrows.append(a, .{ .function = operation });
            const entry = try b.declare(&.{e.table}, e.table, &.{}, &.{});
            const loop = try b.declare(&.{ e.table, e.integer, e.rows }, e.rows, &.{}, &.{});
            const table = try e.param(loop, 0);
            const index = try e.param(loop, 1);
            const out = try e.param(loop, 2);
            const rows = try e.field(e.rows, table, 0);
            const row = try e.get(e.row, rows, index);
            const result = try b.variable(if (kind == .map) e.row else e.boolean);
            const next = try e.add(index, try e.n(1));
            const appended = try e.call(loop, &.{ table, next, try e.append(out, if (kind == .map) try b.reference(result) else row) });
            const step = try b.bind(result, try e.call(operation, &.{ table, row }), if (kind == .map) appended else try e.choose(try b.reference(result), appended, try e.call(loop, &.{ table, next, out })));
            try b.define(loop, try e.choose(try e.eq(index, try e.length(rows)), try b.pure(out), step));
            const input = try e.param(entry, 0);
            const mapped = try b.variable(e.rows);
            try b.define(entry, try b.bind(mapped, try e.call(loop, &.{ input, try e.n(0), try e.empty() }), try b.pure(try e.tableWith(input, try b.reference(mapped), null))));
            break :blk entry;
        },
        .selected => blk: {
            const entry = try b.declare(&.{ e.table, e.row }, e.boolean, &.{}, &.{});
            const loop = try b.declare(&.{ e.keys, e.integer, e.integer }, e.boolean, &.{}, &.{});
            const keys = try e.param(loop, 0);
            const key = try e.param(loop, 1);
            const index = try e.param(loop, 2);
            try b.define(loop, try e.choose(try e.eq(index, try e.length(keys)), try b.pure(try b.constant(bool, false)), try e.choose(try e.eq(key, try e.get(e.integer, keys, index)), try b.pure(try b.constant(bool, true)), try e.call(loop, &.{ keys, key, try e.add(index, try e.n(1)) }))));
            try b.define(entry, try e.call(loop, &.{ try e.field(e.keys, try e.param(entry, 0), 2), try e.col(try e.param(entry, 1), 1), try e.n(0) }));
            break :blk entry;
        },
        .join => blk: {
            const entry = try b.declare(&.{ e.table, e.row }, e.row, &.{}, &.{});
            const loop = try b.declare(&.{ e.rows, e.row, e.integer }, e.row, &.{}, &.{});
            const rows = try e.param(loop, 0);
            const row = try e.param(loop, 1);
            const index = try e.param(loop, 2);
            const other = try e.get(e.row, rows, index);
            const next = try e.add(index, try e.n(1));
            const matched = try e.rowWith(row, .{ .matches = try e.add(try e.col(row, 4), try e.n(1)), .match_id = try e.col(other, 0) });
            const mismatch = try e.rowWith(matched, .{ .mismatches = try e.add(try e.col(row, 6), try e.n(1)) });
            const classify = try e.choose(try e.eq(try e.col(row, 2), try e.col(other, 2)), try e.call(loop, &.{ rows, matched, next }), try e.call(loop, &.{ rows, mismatch, next }));
            const step = try e.choose(try e.eq(try e.col(row, 1), try e.col(other, 1)), classify, try e.call(loop, &.{ rows, row, next }));
            try b.define(loop, try e.choose(try e.eq(index, try e.length(rows)), try b.pure(row), step));
            const original = try e.param(entry, 1);
            try b.define(entry, try e.call(loop, &.{ try e.field(e.rows, try e.param(entry, 0), 1), try e.rowWith(original, .{ .matches = try e.n(0), .match_id = try e.n(0), .mismatches = try e.n(0), .status = try e.n(0) }), try e.n(0) }));
            break :blk entry;
        },
        .classify => blk: {
            const entry = try b.declare(&.{ e.table, e.row }, e.row, &.{}, &.{});
            const row = try e.param(entry, 1);
            const matching = try e.choose(try e.eq(try e.col(row, 6), try e.n(0)), try b.pure(try e.rowWith(row, .{ .status = try e.n(1) })), try b.pure(try e.rowWith(row, .{ .status = try e.n(2) })));
            const present = try e.choose(try e.eq(try e.col(row, 4), try e.n(1)), matching, try b.pure(try e.rowWith(row, .{ .status = try e.n(4) })));
            try b.define(entry, try e.choose(try e.eq(try e.col(row, 4), try e.n(0)), try b.pure(try e.rowWith(row, .{ .status = try e.n(3) })), present));
            break :blk entry;
        },
        .orphan => blk: {
            const entry = try b.declare(&.{ e.table, e.row }, e.boolean, &.{}, &.{});
            try b.define(entry, try b.pure(try e.eq(try e.col(try e.param(entry, 1), 4), try e.n(0))));
            break :blk entry;
        },
        .swap => blk: {
            const entry = try b.declare(&.{e.table}, e.table, &.{}, &.{});
            const table = try e.param(entry, 0);
            try b.define(entry, try b.pure(try e.tableWith(table, try e.field(e.rows, table, 1), try e.field(e.rows, table, 0))));
            break :blk entry;
        },
        .group => try grouped(e),
    };
    var diagnostic: source.Diagnostic = .{};
    var compiled = source.component.compileObserved(allocator, b.module(root, e.unit), .{ .imports = imports.items, .borrows = borrows.items, .exports = &.{symbol("apply", root)} }, .{ .diagnostic = &diagnostic }) catch |err| {
        std.log.err("tool component {s}: {s}; {any}", .{ @tagName(kind), @errorName(err), diagnostic });
        return err;
    };
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}

/// Reduce each group to a count. Keep the first source ID as its representative;
/// the relation and selected keys remain available in the ordinary result.
fn grouped(e: E) !Id {
    const b = e.b;
    const entry = try b.declare(&.{e.table}, e.table, &.{}, &.{});
    const insert = try b.declare(&.{ e.rows, e.row, e.integer }, e.rows, &.{}, &.{});
    const groups = try e.param(insert, 0);
    const row = try e.param(insert, 1);
    const index = try e.param(insert, 2);
    const current = try e.get(e.row, groups, index);
    const incremented = try e.rowWith(current, .{ .value = try e.add(try e.col(current, 2), try e.n(1)) });
    const updated = try e.primitive(e.rows, .sequence_set, &.{ groups, index, incremented }, .invalid_index);
    const found = try e.choose(try e.eq(try e.col(current, 3), try e.col(row, 3)), try b.pure(updated), try e.call(insert, &.{ groups, row, try e.add(index, try e.n(1)) }));
    const initial = try e.rowWith(row, .{ .value = try e.n(1), .matches = try e.n(0), .match_id = try e.n(0), .mismatches = try e.n(0), .status = try e.n(5) });
    try b.define(insert, try e.choose(try e.eq(index, try e.length(groups)), try b.pure(try e.append(groups, initial)), found));
    const loop = try b.declare(&.{ e.rows, e.integer, e.rows }, e.rows, &.{}, &.{});
    const rows = try e.param(loop, 0);
    const i = try e.param(loop, 1);
    const out = try e.param(loop, 2);
    const next = try b.variable(e.rows);
    const step = try b.bind(next, try e.call(insert, &.{ out, try e.get(e.row, rows, i), try e.n(0) }), try e.call(loop, &.{ rows, try e.add(i, try e.n(1)), try b.reference(next) }));
    try b.define(loop, try e.choose(try e.eq(i, try e.length(rows)), try b.pure(out), step));
    const input = try e.param(entry, 0);
    const result = try b.variable(e.rows);
    try b.define(entry, try b.bind(result, try e.call(loop, &.{ try e.field(e.rows, input, 0), try e.n(0), try e.empty() }), try b.pure(try e.tableWith(input, try b.reference(result), null))));
    return entry;
}

pub fn catalog(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: [kinds.len]c.tool_construction.Component = undefined;
    for (kinds, &entries) |kind, *item| item.* = .{ .id = .{ .bytes = @tagName(kind) }, .object = .{ .bytes = try emit(a, kind) } };
    return c.encodeOwned(c.tool_construction.Catalog, allocator, .{ .items = &entries });
}
