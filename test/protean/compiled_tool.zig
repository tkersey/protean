const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const source = horos.source;
const data = horos.data;
const a = std.testing.allocator;

fn object(hidden: bool) ![]u8 {
    return objectWith(hidden, false);
}
fn objectWith(hidden: bool, multi: bool) ![]u8 {
    return objectProfile(hidden, multi, false);
}
fn objectProfile(hidden: bool, multi: bool, internal: bool) ![]u8 {
    return objectNamed(hidden, multi, internal, "fixture/compiled-read");
}
fn objectNamed(hidden: bool, multi: bool, internal: bool, identity: []const u8) ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const read = try b.effect(.{ .identity = identity, .payload = integer, .result = integer, .control_use = if (multi) .multi else .linear, .external = !internal });
    if (multi) _ = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = read,
        .input = integer,
        .answer = integer,
        .handled = &.{read},
        .mode = .deep,
        .use = .multi,
    } } });
    if (hidden) _ = try b.effect(.{ .identity = "fixture/hidden", .payload = unit, .result = unit });
    const main = try b.declare(&.{integer}, integer, &.{read}, &.{});
    const value = try b.reference(b.parameter(main, 0));
    try b.define(main, if (internal) try b.pure(value) else try b.term(.{ .perform = .{ .effect = read, .payload = value } }));
    var compiled = try source.component.compile(a, b.module(main, unit), .{
        .imports = &.{.{ .name = "read", .reference = .{ .kind = .effect, .id = read } }},
        .exports = &.{.{ .name = "inspect", .reference = .{ .kind = .function, .id = main } }},
    });
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}

const Tool = struct {
    var identity: []const u8 = "fixture/compiled-read";
    var bytes: []u8 = &.{};
    var role: protean.admission.Role = .read;
    var rename = false;
    var internal = false;
    var internal_role: protean.admission.Role = .internal;
    pub fn declare(c: protean.Context) !protean.tools.Descriptor {
        const integer = try c.schema(u64);
        const read = if (internal) blk: {
            const effect = try c.builder.effect(.{ .identity = "fixture/compiled-read", .payload = integer, .result = integer, .external = false });
            try c.registry.classify(effect, internal_role);
            break :blk effect;
        } else try c.external(if (rename) "fixture/other" else identity, integer, integer, role);
        return protean.tools.declareCompiled(c, .{ .instance = "read-tool", .object = bytes, .entry = "inspect", .identity = "fixture/local-inspect", .payload = integer, .result = integer, .effects = &.{.{ .symbol = "read", .effect = read }}, .model_offered = true, .name = "inspect", .description = "Inspect a number using the compiled tool" });
    }
};
const Application = struct {
    var mutate = false;
    var speculate = false;
    pub fn emit(c: protean.Context) !source.Module {
        const tool = try c.catalogs.tool("inspect");
        const b = c.builder;
        const function = tool.implementation.local;
        const main = try b.declare(&.{tool.payload}, tool.result, b.functions.items[@intCast(function)].effects, &.{});
        try b.define(main, try protean.tools.perform(c, tool, try b.reference(b.parameter(main, 0))));
        if (speculate) try c.registry.speculate(function, b.functions.items[@intCast(function)].effects);
        if (mutate) @memset(Tool.bytes, 0xff);
        return b.module(main, try b.scalar(void));
    }
};
const System = protean.system(.{ .InitialArgs = u64, .Result = u64, .Failure = void, .tools = .{Tool}, .application = Application });

test "internal model participants cannot enter through a read-tool alias" {
    // Horos accepts this typed effectful component, but that does not grant
    // Protean model authority. A matching label and schema must not bypass it.
    Tool.identity = "agent.model.invoke.v3";
    defer Tool.identity = "fixture/compiled-read";
    Tool.bytes = try objectNamed(false, false, false, Tool.identity);
    defer a.free(Tool.bytes);
    var decoded = try data.component.decode(a, Tool.bytes);
    defer decoded.deinit();
    try std.testing.expectEqualStrings(Tool.identity, decoded.object.program.effects[0].identity);
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
    Tool.role = .model;
    defer Tool.role = .read;
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
}

test "compiled imports cannot hide mobility behind a read role or harmless alias" {
    for ([_][]const u8{ "agent.mobility.resolve.v1", "agent.mobility.relocate.v1" }) |identity| {
        Tool.identity = identity;
        defer Tool.identity = "fixture/compiled-read";
        Tool.bytes = try objectNamed(false, false, false, identity);
        defer a.free(Tool.bytes);
        try std.testing.expectError(error.EffectRoleMismatch, protean.compile(a, System));
        Tool.role = .mobility;
        defer Tool.role = .read;
        try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
        Tool.rename = true;
        defer Tool.rename = false;
        try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
    }
}

test "compiled internal requirements retain nominal and role bindings" {
    Tool.bytes = try objectProfile(false, false, true);
    defer a.free(Tool.bytes);
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
    Tool.internal = true;
    defer Tool.internal = false;
    var compiled = try protean.compile(a, System);
    defer compiled.deinit();
    try std.testing.expect(!compiled.program.effects[0].external);
    Tool.internal_role = .read;
    defer Tool.internal_role = .internal;
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
    Tool.internal_role = .internal;
    Application.speculate = true;
    defer Application.speculate = false;
    try std.testing.expectError(error.UnprovenComputationOrigin, protean.compile(a, System));
}

test "compiled local tool links owned object bytes through normal Protean compilation" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    Application.mutate = true;
    defer Application.mutate = false;
    var compiled = try protean.compile(a, System);
    defer compiled.deinit();
    try std.testing.expectEqual(1, compiled.program.effects.len);
    try std.testing.expectEqualStrings("fixture/compiled-read", compiled.program.effects[0].identity);
    const encoded = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(encoded);
    _ = try compiled.encode(a, encoded);
    var admitted = try data.program_image.decode(a, encoded);
    defer admitted.deinit();
    try std.testing.expectEqual(2, admitted.program.functions.len);
}

test "compiled imports cannot hide external operations rename meanings or grant authority" {
    Tool.bytes = try object(true);
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
    a.free(Tool.bytes);
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    Tool.rename = true;
    defer Tool.rename = false;
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
    Tool.rename = false;
    Tool.role = .commit;
    defer Tool.role = .read;
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
}

test "an opaque read-tool row is not permission to enter protected speculation" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    Application.speculate = true;
    defer Application.speculate = false;
    try std.testing.expectError(error.UnprovenComputationOrigin, protean.compile(a, System));
}

test "compiled read-tool admission rejects latent multi-shot control" {
    Tool.bytes = try objectWith(false, true);
    defer a.free(Tool.bytes);
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
}

test "an external compiled requirement cannot bind an internal declaration" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    Tool.internal = true;
    defer Tool.internal = false;
    try std.testing.expectError(error.InvalidCompiledTool, protean.compile(a, System));
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var compiled = try protean.compile(allocator, System);
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
}
test "compiled tool construction releases all partial object and link owners" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{});
}

test "compiled tool final link forwards semantic contract and deterministic limits" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    var stats: data.closed_compilation.Statistics = .{};
    var coalescing: data.coalescing.Statistics = .{};
    var structural = try protean.compile(a, System);
    defer structural.deinit();
    var limited = try protean.compileObserved(a, System, .{ .horos_options = .{
        .contract = .semantic,
        .semantic_work_limit = 0,
        .semantic_statistics = &stats,
        .coalescing = .{ .statistics = &coalescing },
    } });
    defer limited.deinit();
    try std.testing.expectEqual(data.closed_compilation.Outcome.work_limit, stats.outcome);
    try std.testing.expect(coalescing.outcome != .not_run);
    try std.testing.expectEqual(try data.program_image.identity(a, structural.program), try data.program_image.identity(a, limited.program));
    var semantic = try protean.compileObserved(a, System, .{ .horos_options = .{ .contract = .semantic, .semantic_statistics = &stats } });
    defer semantic.deinit();
    try std.testing.expect(stats.outcome == .applied or stats.outcome == .no_change);
    try std.testing.expectError(error.Capacity, protean.compileObserved(a, System, .{ .horos_options = .{ .contract = .semantic, .max_image_bytes = 0 } }));
}

test "compiled tool final link validates profiles before structural or work-limit returns" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    const invalid: data.closed_compilation.ProfilePolicy = .{ .record = .{
        .version = 0,
        .image_identity = @splat(0),
        .block_counts = &.{},
        .total = 0,
    } };
    for ([_]data.closed_compilation.Contract{ .structural, .semantic }) |contract| {
        try std.testing.expectError(error.InvalidOptimizationProfile, protean.compileObserved(a, System, .{ .horos_options = .{
            .contract = contract,
            .profile = invalid,
            .semantic_work_limit = 0,
        } }));
    }
}

test "compiled tool final link preserves valid profiles and rejects stale identities" {
    Tool.bytes = try object(false);
    defer a.free(Tool.bytes);
    // P01's documented zero-work rollback exposes the admitted original record
    // to the collector; the profiled compilation still uses ordinary defaults.
    var original = try protean.compileObserved(a, System, .{ .horos_options = .{ .coalescing = .{ .work_limit = 0 } } });
    defer original.deinit();
    var collector = try data.optimization_profile.Collector.init(a, original.program);
    defer collector.deinit();
    var profile = try collector.snapshot(a);
    defer profile.deinit();
    var stats: data.closed_compilation.Statistics = .{};
    var compiled = try protean.compileObserved(a, System, .{ .horos_options = .{
        .contract = .semantic,
        .profile = .{ .record = profile.record },
        .semantic_statistics = &stats,
    } });
    defer compiled.deinit();
    try std.testing.expect(stats.profile_used);
    var ordinary = try protean.compileObserved(a, System, .{ .horos_options = .{ .contract = .semantic } });
    defer ordinary.deinit();
    try std.testing.expectEqual(try data.program_image.identity(a, ordinary.program), try data.program_image.identity(a, compiled.program));
    profile.record.image_identity[0] ^= 1;
    try std.testing.expectError(error.InvalidOptimizationProfile, protean.compileObserved(a, System, .{ .horos_options = .{ .profile = .{ .record = profile.record } } }));
}
