//! Frozen compiler work for the existing acquisition slot. No Store or Resident
//! crosses the worker boundary; only the owner can publish program custody.
const std = @import("std");
const c = @import("protean_contracts");
const construction = @import("program_construction.zig");
const registry = @import("registry.zig");

pub const Input = struct {
    source: c.Bytes(null),
    kind: c.workspace.SourceKind,
    catalog: ?c.Bytes(null),
    exposures: c.Vector(c.workspace.Exposure, null),
};
pub const Compiled = struct {
    image: c.Bytes(null),
    interface: c.tool_construction.Interface,
    ports: c.Vector(construction.PortInterface, null),
    compiler_nanoseconds: u64 = 0,
};
pub const Output = union(enum) {
    compiled: Compiled,
    rejected: struct {
        code: c.Utf8,
        phase: c.Utf8,
        function: ?u64,
        term: ?u64,
        value: ?u64,
        compiler_nanoseconds: u64 = 0,
    },
};

pub fn run(ctx: registry.Context, bytes: []const u8) ![]u8 {
    try ctx.checkCancellation();
    var input = try c.decodeOwned(Input, ctx.allocator, bytes);
    defer input.deinit();
    var diagnostic: construction.Diagnostic = .{};
    const started = std.Io.Clock.awake.now(ctx.io);
    var built = compile(ctx, input.value, &diagnostic) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return c.encodeOwned(Output, ctx.allocator, .{ .rejected = .{
            .code = .{ .bytes = @errorName(err) },
            .phase = .{ .bytes = @tagName(diagnostic.phase) },
            .function = diagnostic.source.function,
            .term = diagnostic.source.term,
            .value = diagnostic.source.value,
            .compiler_nanoseconds = elapsed(ctx.io, started),
        } });
    };
    defer built.deinit();
    try ctx.checkCancellation();
    return c.encodeOwned(Output, ctx.allocator, .{ .compiled = .{
        .image = .{ .bytes = built.image },
        .interface = built.interface,
        .ports = .{ .items = built.ports },
        .compiler_nanoseconds = elapsed(ctx.io, started),
    } });
}

fn elapsed(io: std.Io, started: std.Io.Timestamp) u64 {
    return std.math.cast(u64, @max(0, std.Io.Clock.awake.now(io).nanoseconds - started.nanoseconds)) orelse std.math.maxInt(u64);
}

fn compile(ctx: registry.Context, input: Input, diagnostic: *construction.Diagnostic) !construction.Built {
    if (input.kind == .source_records) {
        if (input.catalog != null) return error.InvalidConstruction;
        return construction.buildExposed(ctx.allocator, input.source.bytes, input.exposures.items, ctx.cancellation, diagnostic);
    }
    diagnostic.phase = .authority;
    if (input.exposures.items.len != 0) return error.InvalidExposure;
    const catalog = input.catalog orelse return error.UnavailableCatalog;
    diagnostic.phase = .compilation;
    return construction.buildComponent(ctx.allocator, catalog.bytes, input.source.bytes);
}
