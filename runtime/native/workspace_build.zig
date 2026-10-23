//! Frozen compiler work for the existing acquisition slot. No Store or Resident
//! crosses the worker boundary; only the owner can publish program custody.
const std = @import("std");
const c = @import("protean_contracts");
const construction = @import("program_construction.zig");
const registry = @import("registry.zig");
const kosmos = @import("kosmos");
const data = @import("horos_data");
const state = @import("state.zig");

pub const ProgramInput = struct {
    source: c.Bytes(null),
    kind: c.workspace.SourceKind,
    catalog: ?c.Bytes(null),
    exposures: c.Vector(c.workspace.Exposure, null),
    controller: ?c.controller.Contract = null,
};
pub const DeriveInput = struct {
    ancestor: c.Bytes(null),
    guest: c.Bytes(null),
    program: state.Digest,
    proposal: c.Bytes(null),
    producer: ?state.Reference,
    root: state.Digest,
    checker: state.Name,
    subject: c.workspace.SemanticTarget,
    basis: @import("workspace_state.zig").ReadObservation,
};
pub const ValidateInput = struct {
    ancestor: c.Bytes(null),
    candidate: c.Bytes(null),
    candidate_ref: state.Reference,
    program: state.Digest,
    guest: state.Reference,
    root: state.Digest,
    checker: state.Name,
};
pub const Input = union(enum) {
    program: ProgramInput,
    derive: DeriveInput,
    validate: ValidateInput,
};
pub const Compiled = struct {
    image: c.Bytes(null),
    interface: c.tool_construction.Interface,
    ports: c.Vector(construction.PortInterface, null),
    controller: ?c.controller.Descriptor = null,
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
    derived: struct { artifact: c.Bytes(null), compiler_nanoseconds: u64 = 0 },
    validation: struct {
        outcome: c.workspace.ValidationOutcome,
        code: c.Utf8,
        compiler_nanoseconds: u64 = 0,
    },
};

pub fn run(ctx: registry.Context, bytes: []const u8) ![]u8 {
    try ctx.checkCancellation();
    var input = try c.decodeOwned(Input, ctx.allocator, bytes);
    defer input.deinit();
    switch (input.value) {
        .program => |program| return runProgram(ctx, program),
        .derive => |proposal| return runDerive(ctx, proposal),
        .validate => |candidate| return runValidate(ctx, candidate),
    }
}

fn runProgram(ctx: registry.Context, input: ProgramInput) ![]u8 {
    var diagnostic: construction.Diagnostic = .{};
    const started = std.Io.Clock.awake.now(ctx.io);
    var built = compile(ctx, input, &diagnostic) catch |err| {
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
        .controller = built.controller,
        .compiler_nanoseconds = elapsed(ctx.io, started),
    } });
}

fn elapsed(io: std.Io, started: std.Io.Timestamp) u64 {
    return std.math.cast(u64, @max(0, std.Io.Clock.awake.now(io).nanoseconds - started.nanoseconds)) orelse std.math.maxInt(u64);
}

fn compile(
    ctx: registry.Context,
    input: ProgramInput,
    diagnostic: *construction.Diagnostic,
) !construction.Built {
    if (input.controller) |contract| {
        if (input.kind != .source_records or input.catalog != null or input.exposures.items.len != 0) return error.InvalidConstruction;
        return construction.buildController(ctx.allocator, input.source.bytes, contract, ctx.cancellation, diagnostic);
    }
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

fn runDerive(ctx: registry.Context, input: DeriveInput) ![]u8 {
    const started = std.Io.Clock.awake.now(ctx.io);
    const bytes = derive(ctx, input) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        return c.encodeOwned(Output, ctx.allocator, .{ .rejected = .{
            .code = .{ .bytes = @errorName(err) },
            .phase = .{ .bytes = "construction" },
            .function = null,
            .term = null,
            .value = null,
            .compiler_nanoseconds = elapsed(ctx.io, started),
        } });
    };
    defer ctx.allocator.free(bytes);
    return c.encodeOwned(Output, ctx.allocator, .{ .derived = .{
        .artifact = .{ .bytes = bytes },
        .compiler_nanoseconds = elapsed(ctx.io, started),
    } });
}

fn derive(ctx: registry.Context, input: DeriveInput) ![]u8 {
    const a = ctx.allocator;
    try ctx.checkCancellation();
    var ancestor = try kosmos.RuntimeArtifact.init(
        a,
        input.ancestor.bytes,
        @import("store.zig").digest(input.ancestor.bytes),
    );
    defer ancestor.deinit();
    if (!std.meta.eql(kosmos.RuntimeCompiler.approvedRootIdentity(&ancestor), input.root))
        return error.InvalidRuntime;
    const guest = try data.program_image.Admitted.decode(a, input.guest.bytes);
    defer guest.deinit();
    var proposal = try @import("source_records.zig").decodeRecord(
        construction.CandidateDocument,
        a,
        input.proposal.bytes,
    );
    defer proposal.deinit();
    if (proposal.value.version != 1) return error.UnsupportedVersion;
    const bytes = try kosmos.RuntimeCompiler.deriveRecord(a, &ancestor, guest, proposal.value.proposal, .{
        .horos_package = @import("native_options").horos_identity,
    });
    errdefer a.free(bytes);
    try ctx.checkCancellation();
    return bytes;
}

fn runValidate(ctx: registry.Context, input: ValidateInput) ![]u8 {
    const started = std.Io.Clock.awake.now(ctx.io);
    const result: struct { c.workspace.ValidationOutcome, []const u8 } =
        if (validate(ctx, input)) |_| .{ .validated, "" } else |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => .{ .resource_exhausted, @errorName(err) },
            error.Canceled => .{ .interrupted, @errorName(err) },
            error.UnsupportedRelation => .{ .unsupported_relation, @errorName(err) },
            error.Capacity, error.RelationLimit, error.WorkLimit, error.SpecializationLimit => .{ .resource_exhausted, @errorName(err) },
            error.ArtifactUnavailable => .{ .unavailable_dependency, @errorName(err) },
            else => .{ .rejected, @errorName(err) },
        };
    return c.encodeOwned(Output, ctx.allocator, .{ .validation = .{
        .outcome = result[0],
        .code = .{ .bytes = result[1] },
        .compiler_nanoseconds = elapsed(ctx.io, started),
    } });
}

fn validate(ctx: registry.Context, input: ValidateInput) !void {
    const a = ctx.allocator;
    try ctx.checkCancellation();
    var ancestor = try kosmos.RuntimeArtifact.init(
        a,
        input.ancestor.bytes,
        @import("store.zig").digest(input.ancestor.bytes),
    );
    defer ancestor.deinit();
    var candidate = try kosmos.RuntimeArtifact.init(
        a,
        input.candidate.bytes,
        @import("store.zig").digest(input.candidate.bytes),
    );
    defer candidate.deinit();
    if (!std.meta.eql(kosmos.RuntimeCompiler.approvedRootIdentity(&ancestor), input.root) or
        !std.mem.eql(u8, candidate.content.value.manifest.compiler.policy, input.checker.bytes))
    {
        return error.InvalidRuntime;
    }
    try kosmos.RuntimeCompiler.validateAgainst(a, &candidate, &ancestor);
    try ctx.checkCancellation();
}

test "semantic derivation interruption does not become a compiler rejection" {
    var cancelled = std.atomic.Value(bool).init(true);
    const authority: registry.Authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" };
    try std.testing.expectError(error.Canceled, runDerive(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .authority = &authority,
        .task_id = "test",
        .profile = "test",
        .environment = null,
        .cancellation = &cancelled,
    }, .{
        .ancestor = .{ .bytes = "" },
        .guest = .{ .bytes = "" },
        .program = @splat(0),
        .proposal = .{ .bytes = "" },
        .producer = null,
        .root = @splat(0),
        .checker = .{ .bytes = "test" },
        .subject = .{ .controller = .{ .cut = .{ .epoch = 0, .execution_revision = 0 } } },
        .basis = .immutable,
    }));
}
