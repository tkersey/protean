//! Data-only Horos construction and pure native Kosmos execution.
//! Callers own task admission, occurrence accounting, and durable publication.
const std = @import("std");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const contracts = @import("protean_contracts");
const json = @import("json.zig");
const values = @import("values.zig");

const wire = contracts.tool_construction;
pub const Name = wire.Name;
pub const Component = wire.Component;
pub const Catalog = wire.Catalog;
pub const Endpoint = wire.Endpoint;
pub const Recipe = wire.Recipe;
pub const Interface = wire.Interface;
pub const Built = wire.Built;
pub const Program = wire.Program;
pub const Input = wire.Input;

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

/// Catalog bytes come from the frozen resource closure, never model arguments.
pub fn construct(output: std.mem.Allocator, scratch: std.mem.Allocator, task: [16]u8, profile: []const u8, catalog_bytes: []const u8, proposal: []const u8) !Program {
    var catalog = try contracts.decodeOwned(Catalog, scratch, catalog_bytes);
    defer catalog.deinit();
    const recipe = try output.dupe(u8, proposal);
    errdefer output.free(recipe);
    return .{ .task = task, .policy = digest(profile), .catalog = digest(catalog_bytes), .recipe = .{ .bytes = recipe }, .built = try build(output, scratch, catalog.value, proposal) };
}

/// Re-admit the derivation and compare it to the exact retained program. Linking
/// is validation here: execution still receives the originally referenced bytes.
pub fn execute(output: std.mem.Allocator, scratch: std.mem.Allocator, cancellation: ?*const std.atomic.Value(bool), task: [16]u8, profile: []const u8, catalog_bytes: []const u8, program: Program, input: Input) ![]u8 {
    if (program.version != 2 or !same(&program.task, &task) or !same(&program.policy, &digest(profile)) or !same(&program.catalog, &digest(catalog_bytes))) return error.UnauthorizedProgram;
    if (cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    const a = arena.allocator();
    var catalog = try contracts.decodeOwned(Catalog, a, catalog_bytes);
    defer catalog.deinit();
    const derived = try build(a, scratch, catalog.value, program.recipe.bytes);
    if (!same(derived.image.bytes, program.built.image.bytes) or
        !same(derived.interface.input.bytes, program.built.interface.input.bytes) or
        !same(derived.interface.output.bytes, program.built.interface.output.bytes) or
        !same(derived.interface.failure.bytes, program.built.interface.failure.bytes)) return error.InvalidDerivation;
    return run(output, scratch, cancellation, program.built, input.schema.bytes, input.value.bytes);
}

/// The caller supplies an already task-admitted catalog, never model bytes.
pub fn validateCatalog(a: std.mem.Allocator, catalog: Catalog) !void {
    if (catalog.items.len == 0) return error.InvalidCatalog;
    for (catalog.items, 0..) |item, i| {
        if (item.id.bytes.len == 0) return error.InvalidCatalog;
        for (catalog.items[0..i]) |prior| if (same(prior.id.bytes, item.id.bytes)) return error.InvalidCatalog;
        var decoded = try data.component.decode(a, item.object.bytes);
        defer decoded.deinit();
        for (decoded.object.program.effects) |effect| if (effect.external) return error.ForbiddenEffect;
    }
}

fn instanceIndex(recipe: Recipe, key: []const u8) !usize {
    for (recipe.instances.items, 0..) |item, i| if (same(item.key.bytes, key)) return i;
    return error.MissingInstance;
}

// Kahn's algorithm uses storage proportional to the admitted recipe, without a
// matrix or a fixed instance universe. Repeated edges are counted separately.
fn acyclic(a: std.mem.Allocator, recipe: Recipe) !void {
    const n = recipe.instances.items.len;
    const degree = try a.alloc(usize, n);
    defer a.free(degree);
    @memset(degree, 0);
    const heads = try a.alloc(?usize, n);
    defer a.free(heads);
    @memset(heads, null);
    const Edge = struct { to: usize, next: ?usize };
    const edges = try a.alloc(Edge, recipe.bindings.items.len);
    defer a.free(edges);
    for (recipe.bindings.items, edges, 0..) |binding, *edge, i| {
        const from = try instanceIndex(recipe, binding.required.instance.bytes);
        const to = try instanceIndex(recipe, binding.supplied.instance.bytes);
        edge.* = .{ .to = to, .next = heads[from] };
        heads[from] = i;
        degree[to] = try std.math.add(usize, degree[to], 1);
    }
    const queue = try a.alloc(usize, n);
    defer a.free(queue);
    var tail: usize = 0;
    for (degree, 0..) |count, i| if (count == 0) {
        queue[tail] = i;
        tail += 1;
    };
    var cursor: usize = 0;
    while (cursor < tail) : (cursor += 1) {
        var next = heads[queue[cursor]];
        while (next) |i| {
            const edge = edges[i];
            degree[edge.to] -= 1;
            if (degree[edge.to] == 0) {
                queue[tail] = edge.to;
                tail += 1;
            }
            next = edge.next;
        }
    }
    if (tail != n) return error.CyclicComposition;
}

/// No external effects, even unreachable ones, and only ordinary public values
/// may cross the generated invocation boundary. Horos owns schema meaning.
pub fn interfaceOf(a: std.mem.Allocator, program: data.activation.Program) !Interface {
    for (program.effects) |effect| if (effect.external) return error.ForbiddenEffect;
    const entry = program.functions[@intCast(program.roots.entry)];
    if (entry.inputs.len != 1) return error.InvalidInterface;
    const input = entry.layout.slots[@intCast(entry.inputs[0])];
    const facts = try data.admission.schemas(a, program.schemas);
    defer a.free(facts.minimum);
    defer a.free(facts.exportable);
    for ([_]u64{ input, program.roots.result, program.roots.failure }) |id|
        if (!facts.exportable[@intCast(id)]) return error.ForbiddenInterface;
    const input_bytes = try data.schema.encodeOwned(a, program.schemas, input);
    errdefer a.free(input_bytes);
    const output_bytes = try data.schema.encodeOwned(a, program.schemas, program.roots.result);
    errdefer a.free(output_bytes);
    const failure_bytes = try data.schema.encodeOwned(a, program.schemas, program.roots.failure);
    errdefer a.free(failure_bytes);
    return .{ .input = .{ .bytes = input_bytes }, .output = .{ .bytes = output_bytes }, .failure = .{ .bytes = failure_bytes } };
}

pub fn build(output: std.mem.Allocator, scratch: std.mem.Allocator, catalog: Catalog, proposal: []const u8) !Built {
    // Recipe structure has fixed grammar depth; breadth follows actual input.
    var parsed = try json.parse(scratch, proposal, .{ .bytes = proposal.len, .depth = 6, .tokens = proposal.len, .members = proposal.len });
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    const a = arena.allocator();
    try validateCatalog(a, catalog);
    const recipe = try values.fromJson(Recipe, a, parsed.value);
    if (recipe.instances.items.len == 0) return error.InvalidRecipe;
    try acyclic(a, recipe);
    const instances = try a.alloc(data.linker.Instance, recipe.instances.items.len);
    for (recipe.instances.items, instances) |item, *instance| {
        var object: ?[]const u8 = null;
        for (catalog.items) |candidate| if (same(candidate.id.bytes, item.component_id.bytes)) {
            object = candidate.object.bytes;
            break;
        };
        instance.* = .{ .key = item.key.bytes, .object = object orelse return error.UnknownComponent };
    }
    const bindings = try a.alloc(data.linker.Binding, recipe.bindings.items.len);
    for (recipe.bindings.items, bindings) |item, *binding| binding.* = .{
        .required = .{ .instance = item.required.instance.bytes, .symbol = item.required.symbol.bytes },
        .supplied = .{ .instance = item.supplied.instance.bytes, .symbol = item.supplied.symbol.bytes },
    };
    var linked = try data.linker.linkWithCompilation(scratch, instances, bindings, .{ .instance = recipe.entry.instance.bytes, .symbol = recipe.entry.symbol.bytes }, .{});
    defer linked.deinit();
    const interface = try interfaceOf(a, linked.program);
    const length = try data.program_image.encodedLength(linked.program);
    const bytes = try a.alloc(u8, length);
    _ = try linked.encode(a, bytes);
    const image_copy = try output.dupe(u8, bytes);
    errdefer output.free(image_copy);
    const input_copy = try output.dupe(u8, interface.input.bytes);
    errdefer output.free(input_copy);
    const output_copy = try output.dupe(u8, interface.output.bytes);
    errdefer output.free(output_copy);
    const failure_copy = try output.dupe(u8, interface.failure.bytes);
    return .{ .image = .{ .bytes = image_copy }, .interface = .{
        .input = .{ .bytes = input_copy },
        .output = .{ .bytes = output_copy },
        .failure = .{ .bytes = failure_copy },
    } };
}

/// A fresh pure Session is entirely owned by this occurrence. Its public
/// deinitializer releases interrupted work; no resident or checkpoint escapes.
/// Quanta bound cancellation latency, not the lifetime of a valid computation.
pub fn run(output: std.mem.Allocator, parent: std.mem.Allocator, cancellation: ?*const std.atomic.Value(bool), built: Built, input_schema: []const u8, input: []const u8) ![]u8 {
    if (cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
    const a = parent;
    var prepared = try kosmos.Prepared.init(a, built.image.bytes);
    defer prepared.deinit();
    var session = try kosmos.Session.start(a, &prepared, input);
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const actual = try interfaceOf(arena.allocator(), session.program);
    if (!same(actual.input.bytes, input_schema) or !same(actual.input.bytes, built.interface.input.bytes) or !same(actual.output.bytes, built.interface.output.bytes) or !same(actual.failure.bytes, built.interface.failure.bytes)) return error.IncompatibleInterface;
    while (true) {
        if (cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
        const progress = try session.run(256);
        if (cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
        switch (progress) {
            .progressed => {},
            .yielded => try session.resumeYield(),
            .requested => return error.ForbiddenEffect,
            .failed => return error.ProgramFailed,
            .cancelled => return error.Canceled,
            .completed => |value| {
                const bytes = try session.bytes(&value);
                return output.dupe(u8, bytes);
            },
        }
    }
}
