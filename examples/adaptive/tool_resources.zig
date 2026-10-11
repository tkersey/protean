//! Frozen value admission and the actual component interface view.
const std = @import("std");
const native = @import("protean_native");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const t = @import("application_types");
const wire = contracts.tool_construction;

pub fn referenceText(a: std.mem.Allocator, ref: t.model.ArtifactReference) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ std.fmt.bytesToHex(ref.digest, .lower), ref.bytes });
}
pub fn parseReference(text: []const u8) !t.model.ArtifactReference {
    if (text.len < 66 or text.len > 96 or text[64] != ':') return error.InvalidReference;
    for (text[0..64]) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidReference;
    const length = text[65..];
    if (length.len > 1 and length[0] == '0') return error.InvalidReference;
    for (length) |byte| if (byte < '0' or byte > '9') return error.InvalidReference;
    var digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&digest, text[0..64]);
    return .{ .digest = digest, .bytes = try std.fmt.parseInt(u64, length, 10) };
}

pub fn inputBytes(a: std.mem.Allocator, input: t.ToolInputConfig) ![]u8 {
    const rows = try a.alloc(t.tool_types.Row, input.rows.items.len);
    const relation = try a.alloc(t.tool_types.Row, input.relation.items.len);
    for ([_][]const t.DataRow{ input.rows.items, input.relation.items }, [_][]t.tool_types.Row{ rows, relation }) |source, target|
        for (source, target) |row, *out| {
            out.* = .{ .id = row.id, .key = row.key, .value = row.value, .group = row.group, .matches = 0, .match_id = 0, .mismatches = 0, .status = 0 };
        };
    const value = try contracts.encodeOwned(t.tool_types.Table, a, .{ .rows = .{ .items = rows }, .relation = .{ .items = relation }, .selected = input.selected });
    return contracts.encodeOwned(wire.Input, a, .{ .schema = .{ .bytes = try native.values.schemaBytes(t.tool_types.Table, a) }, .value = .{ .bytes = value } });
}

/// The initial reference domain has four shapes. A name is emitted only after
/// comparing the actual canonical descriptor; unknown shapes fail admission.
fn shapeName(a: std.mem.Allocator, program: data.activation.Program, id: u64) ![]const u8 {
    const actual = try data.schema.encodeOwned(a, program.schemas, id);
    inline for (.{ .{ t.tool_types.Table, "Table" }, .{ t.tool_types.Row, "Row" }, .{ bool, "boolean" }, .{ void, "unit" } }) |shape| {
        if (std.mem.eql(u8, actual, try native.values.schemaBytes(shape[0], a))) return shape[1];
    }
    return error.UnsupportedCatalogInterface;
}
fn symbols(a: std.mem.Allocator, program: data.activation.Program, entries: []const data.component.Symbol) !native.json.Value {
    var result: native.json.Value = .{ .array = .init(a) };
    for (entries) |entry| {
        if (entry.reference.kind != .function) return error.UnsupportedCatalogInterface;
        const function = program.functions[@intCast(entry.reference.id)];
        var value = native.json.object();
        try native.json.put(a, &value, "symbol", native.json.string(entry.name));
        var parameters: native.json.Value = .{ .array = .init(a) };
        for (function.inputs) |slot| try parameters.array.append(native.json.string(try shapeName(a, program, function.layout.slots[@intCast(slot)])));
        try native.json.put(a, &value, "parameters", parameters);
        try native.json.put(a, &value, "result", native.json.string(try shapeName(a, program, function.result)));
        try result.array.append(value);
    }
    return result;
}
pub fn skillBody(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var catalog = try contracts.decodeOwned(wire.Catalog, a, bytes);
    defer catalog.deinit();
    try native.tool_construction.validateCatalog(a, catalog.value);
    var view: native.json.Value = .{ .array = .init(a) };
    for (catalog.value.items) |item| {
        var component = try data.component.decode(a, item.object.bytes);
        defer component.deinit();
        var entry = native.json.object();
        try native.json.put(a, &entry, "component_id", native.json.string(item.id.bytes));
        try native.json.put(a, &entry, "imports", try symbols(a, component.object.program, component.object.imports));
        try native.json.put(a, &entry, "exports", try symbols(a, component.object.program, component.object.exports));
        try native.json.put(a, &entry, "failure", native.json.string(try shapeName(a, component.object.program, component.object.program.roots.failure)));
        try view.array.append(entry);
    }
    const rendered = try native.json.canonicalBounded(a, view, 16 * 1024);
    const body = try std.fmt.allocPrint(a, "{s}\n\n## Construction recipe contract\n" ++
        "Encode an object matching this schema as proposal_json (at most {d} UTF-8 bytes). " ++
        "Use unique instance keys; endpoint instance fields refer to those keys. " ++
        "Bind required imports to supplied exports using the catalog's actual symbols. " ++
        "Use at least one instance and an acyclic inter-instance graph. Unknown fields reject.\n" ++
        "Recipe JSON schema:\n{s}\n\n## Frozen reference domain\n" ++
        "Table contains rows, relation (each at most 32 Row values), and selected (at most 32 keys). " ++
        "Row has u64 fields id, key, value, group, matches, match_id, mismatches, status. " ++
        "compose applies first then second; map applies row to each row; filter retains rows satisfying keep; " ++
        "selected tests membership of row.key in selected; join matches row.key against relation and counts matches and unequal values; " ++
        "classify sets status 1 agreement, 2 mismatch, 3 missing, 4 ambiguous; orphan tests matches=0; " ++
        "swap exchanges rows and relation; group reduces rows by group to a count in value (status 5). " ++
        "All preserve Table's other fields except swap. These semantics do not select your composition.\n\n" ++
        "Actual frozen component signatures (complete):\n{s}\n", .{
        @embedFile("skills/tool-construction/SKILL.md"),
        contracts.json.maximumTextBytes(@FieldType(@FieldType(t.Action, "tool_build"), "proposal_json")),
        &contracts.json.ClientSchema(wire.Recipe).value,
        rendered,
    });
    if (body.len > 32 * 1024) return error.Capacity;
    return body;
}

pub fn policy(ctx: native.registry.ProjectionContext) !t.ToolPolicy {
    const root = (try native.json.parse(ctx.allocator, ctx.profile, .{ .bytes = 256 * 1024 })).value;
    return native.values.fromJson(t.ToolPolicy, ctx.allocator, native.json.get(root, "tool_construction") orelse return error.ToolConstructionNotAdmitted);
}
pub fn sameReference(left: t.model.ArtifactReference, right: t.model.ArtifactReference) bool {
    return left.bytes == right.bytes and std.mem.eql(u8, &left.digest, &right.digest);
}
