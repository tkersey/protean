//! Executable approval policy fixture independent of its environmental adapter.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const source = horos.source;
const Id = source.Id;
const contracts = protean.contracts;

pub const Proposal = struct {
    operation: u32,
    base_version: u64,
    replacement: contracts.Text(128),
    live_evidence: bool,
};
pub const Commit = protean.tools.CommitResult(Proposal, Proposal, u8, u8);
const Mode = enum {
    valid,
    scoped,
    scoped_evidence,
    evidence,
    forged_evidence,
    reused_evidence,
    raw_commit,
    private_call,
    speculative,
    placement_read,
    placement_commit,
};

pub fn build(c: protean.Context, mode: Mode) !source.Module {
    if (mode == .scoped or mode == .scoped_evidence)
        return scopedApproval(c, mode == .scoped_evidence);
    const b = c.builder;
    const proposal = try c.schema(Proposal);
    const boolean = try b.scalar(bool);
    const principal = try b.scalar(u32);
    const commit = try c.external("agent.tool.document.replace.v1", proposal, try c.schema(Commit), .commit);
    const authority = try b.declare(&.{ proposal, principal }, boolean, &.{}, &.{});
    const identity = try b.reference(b.parameter(authority, 1));
    try b.define(authority, try b.pure(try b.primitive(boolean, .equal, &.{ identity, try b.constant(u32, 7) }, 0)));
    const policy = try b.declare(&.{proposal}, boolean, &.{}, &.{});
    const selected = try b.reference(b.parameter(policy, 0));
    const version = try b.primitive(try b.scalar(u64), .field, &.{selected}, 1);
    const live = try b.primitive(boolean, .field, &.{selected}, 3);
    try b.define(policy, try b.term(.{ .conditional = .{
        .condition = live,
        .when_true = try b.pure(try b.primitive(boolean, .equal, &.{ version, try b.constant(u64, 42) }, 0)),
        .when_false = try b.pure(try b.constant(bool, false)),
    } }));
    const failure = try b.constant(void, {});
    const witness = if (mode == .evidence or mode == .forged_evidence or mode == .reused_evidence)
        try liveWitness(c, proposal)
    else
        null;
    const placement: ?Id = if (mode == .placement_read or mode == .placement_commit) blk: {
        const effect = if (mode == .placement_commit) commit else try c.external("test.placement.read", proposal, boolean, .read);
        const function = try b.declare(&.{proposal}, boolean, &.{effect}, &.{});
        try b.define(function, try b.pure(try b.constant(bool, true)));
        break :blk function;
    } else null;
    const d = try protean.approval.define(c, .{
        .name = "probe.document",
        .proposal = proposal,
        .occurrence = try b.scalar(u64),
        .principal = principal,
        .reason = try c.schema(contracts.Text(128)),
        .commit_effect = commit,
        .authority = authority,
        .revalidate = policy,
        .failure = failure,
        .channel = "document-owner",
        .evidence = if (witness) |w| .{ .proof = w.proof, .consume = w.consume, .project = w.project } else null,
        .placement = placement,
    });
    const functions_before = b.functions.items.len;
    for (0..64) |_| {
        const repeated = try protean.approval.define(c, d.config);
        if (repeated.function != d.function or b.functions.items.len != functions_before)
            return error.UnsharedApprovalBody;
    }
    var incompatible = d.config;
    incompatible.principal = try b.scalar(u8);
    try std.testing.expectError(error.InvalidApprovalContract, protean.approval.define(c, incompatible));
    const entry_result = if (mode == .raw_commit) try c.schema(Commit) else d.result;
    const effects = if (witness) |w| (try (source.Row{ .effects = d.effects }).unionWith(b.allocator(), .{ .effects = &.{w.effect} })).effects else d.effects;
    const entry = try b.declare(&.{proposal}, entry_result, effects, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const term = switch (mode) {
        .raw_commit => try b.term(.{ .perform = .{ .effect = commit, .payload = input } }),
        .private_call => try b.term(.{ .call = .{
            .function = d.function,
            .arguments = &.{input},
        } }),
        .valid, .speculative, .scoped, .scoped_evidence, .placement_read, .placement_commit => try protean.approval.approveAndCommit(c, d, entry, input),
        .evidence, .forged_evidence, .reused_evidence => blk: {
            const w = witness.?;
            try std.testing.expectError(error.LiveEvidenceRequired, protean.approval.approveAndCommit(c, d, entry, input));
            const proof = try b.variable(w.proof);
            const read = try b.term(.{ .call = .{ .function = w.read, .arguments = &.{} } });
            try c.registry.allowPrivateCall(entry, read, w.read);
            const acquire = if (mode == .forged_evidence) try b.pure(try b.primitive(w.proof, .resource_pack, &.{try b.constant(u64, 42)}, 0)) else read;
            const first = try protean.approval.approveWithEvidence(c, d, entry, input, try b.reference(proof));
            const next = if (mode == .reused_evidence) try b.bind(try b.variable(d.result), first, try protean.approval.approveWithEvidence(c, d, entry, input, try b.reference(proof))) else first;
            break :blk try b.bind(proof, acquire, next);
        },
    };
    try b.define(entry, term);
    if (mode == .speculative) try c.registry.speculate(entry, d.effects);
    return b.module(entry, try b.scalar(void));
}

test "approval emits ordinary checked BPI3 with a consumed private grant" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const module = try build(.{ .builder = &b, .registry = &registry }, .valid);
    try protean.admission.verify(std.testing.allocator, module, &registry);
    var compiled = try horos.program.compile(std.testing.allocator, module);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.resources.len);
    try std.testing.expect(compiled.program.functions.len > 1);
}

test "approval placement cannot hide ordinary I/O or commitment before final revalidation" {
    inline for (.{ Mode.placement_read, Mode.placement_commit }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(std.testing.allocator);
        defer registry.deinit();
        try std.testing.expectError(error.InvalidApprovalPlacement, build(.{ .builder = &b, .registry = &registry }, mode));
    }
}

test "protected source rejects raw commit, stolen private call, and speculative authority" {
    inline for (.{
        .{ Mode.raw_commit, error.ProtectedEffectBypass },
        .{ Mode.private_call, error.PrivateFunctionBypass },
        .{ Mode.speculative, error.SpeculativeEffect },
    }) |scenario| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(std.testing.allocator);
        defer registry.deinit();
        const module = try build(.{ .builder = &b, .registry = &registry }, scenario[0]);
        try std.testing.expectError(scenario[1], protean.admission.verify(std.testing.allocator, module, &registry));
    }
}

test "tool metadata and dispatch share one declaration without granting commit" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const integer = try b.scalar(u64);
    const read = try c.external("test.document.read", integer, integer, .read);
    const descriptor: protean.tools.Descriptor = .{
        .identity = "test.document.read",
        .payload = integer,
        .result = integer,
        .implementation = .{ .external = read },
        .role = .read,
        .model_offered = false,
    };
    try protean.tools.validate(c, &.{descriptor});
    _ = try protean.tools.perform(c, descriptor, try b.constant(u64, 0));
    try std.testing.expectError(error.DuplicateToolDeclaration, protean.tools.validate(c, &.{ descriptor, descriptor }));
    var altered = descriptor;
    altered.identity = "other.document.read";
    try std.testing.expectError(error.InvalidToolDeclaration, protean.tools.validate(c, &.{altered}));
    const commit = try c.external("test.document.commit", integer, integer, .commit);
    altered = descriptor;
    altered.identity = "test.document.commit";
    altered.implementation = .{ .external = commit };
    altered.role = .commit;
    try std.testing.expectError(error.ProtectedToolRequiresCheckedOwner, protean.tools.perform(c, altered, try b.constant(u64, 0)));
}

const LiveWitness = struct { proof: Id, consume: Id, project: Id, read: Id, effect: Id };

fn liveWitness(c: protean.Context, proposal: Id) !LiveWitness {
    const b = c.builder;
    const integer = try b.scalar(u64);
    const effect = try c.external("agent.tool.document.read.version.v1", try b.scalar(void), integer, .read);
    const proof = try b.resource(integer);
    const read = try b.declare(&.{}, proof, &.{effect}, &.{});
    const consume = try b.declare(&.{proof}, integer, &.{}, &.{});
    const project = try b.declare(&.{proposal}, integer, &.{}, &.{});
    try c.registry.privateFunction(read);
    try c.registry.privateFunction(consume);
    try c.registry.protectResource(proof);
    try b.resourceAuthority(proof, &.{read}, &.{consume});
    const data = try b.variable(integer);
    const perform = try b.term(.{ .perform = .{ .effect = effect, .payload = try b.constant(void, {}) } });
    try b.define(read, try b.bind(data, perform, try b.pure(try b.primitive(proof, .resource_pack, &.{try b.reference(data)}, 0))));
    try b.define(consume, try b.pure(try b.primitive(integer, .resource_unpack, &.{try b.reference(b.parameter(consume, 0))}, 0)));
    const selected = try b.reference(b.parameter(project, 0));
    try b.define(project, try b.pure(if (proposal == integer) selected else try b.primitive(integer, .field, &.{selected}, 1)));
    return .{ .proof = proof, .consume = consume, .project = project, .read = read, .effect = effect };
}

test "required live proof stays private and is consumed before approval" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const module = try build(.{ .builder = &b, .registry = &registry }, .evidence);
    try protean.admission.verify(std.testing.allocator, module, &registry);
    var compiled = try horos.program.compile(std.testing.allocator, module);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 2), compiled.program.scopes.resources.len);
}

test "a simulated value cannot forge a live proof and a live proof cannot be used twice" {
    for ([_]Mode{ .forged_evidence, .reused_evidence }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(std.testing.allocator);
        defer registry.deinit();
        const module = try build(.{ .builder = &b, .registry = &registry }, mode);
        try protean.admission.verify(std.testing.allocator, module, &registry);
        const expected = if (mode == .reused_evidence) error.UnavailableSlot else error.InvalidOwnership;
        try std.testing.expectError(expected, horos.program.compile(std.testing.allocator, module));
    }
}

fn scopedApproval(c: protean.Context, evidence: bool) !source.Module {
    const b = c.builder;
    const boolean = try b.scalar(bool);
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const region = b.region();
    const region_type = try b.schema(.{ .internal = .{ .region = region } });
    const cell_type = try b.schema(.{ .internal = .{ .cell = .{ .element = boolean, .region = region } } });
    const cell = try b.variable(cell_type);
    const authority = try b.declare(&.{ integer, integer }, boolean, &.{}, &.{});
    try b.define(authority, try b.pure(try b.constant(bool, true)));
    const policy = try b.declare(&.{integer}, boolean, &.{}, &.{region});
    try b.define(policy, try b.pure(try b.primitive(boolean, .cell_get, &.{try b.reference(cell)}, 0)));
    const operation_result = try b.schema(.{ .sum = &.{ integer, integer, unit, unit } });
    const commit = try c.external("agent.tool.scoped.commit.v1", integer, operation_result, .commit);
    const witness = if (evidence) try liveWitness(c, integer) else null;
    const d = try protean.approval.define(c, .{
        .name = "probe.scoped",
        .proposal = integer,
        .occurrence = integer,
        .principal = integer,
        .reason = unit,
        .commit_effect = commit,
        .authority = authority,
        .revalidate = policy,
        .failure = try b.constant(void, {}),
        .channel = "owner",
        .evidence = if (witness) |w|
            .{ .proof = w.proof, .consume = w.consume, .project = w.project }
        else
            null,
    });
    try std.testing.expectEqualSlices(Id, &.{region}, d.regions);
    const effects = if (witness) |w| (try (source.Row{ .effects = d.effects }).unionWith(
        b.allocator(),
        .{ .effects = &.{w.effect} },
    )).effects else d.effects;
    const root = try b.declare(&.{boolean}, d.result, effects, &.{});
    const inside = try b.declare(&.{region_type}, d.result, effects, &.{region});
    const created = try b.primitive(cell_type, .cell_new, &.{
        try b.reference(b.parameter(inside, 0)), try b.reference(b.parameter(root, 0)),
    }, 0);
    const operation = if (witness) |w| try scopedEvidence(c, d, inside, w) else try protean.approval.approveAndCommit(c, d, inside, try b.constant(u64, 42));
    try b.define(inside, try b.bind(cell, try b.pure(created), operation));
    const inside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region_type},
        .result = d.result,
        .effects = effects,
        .capture_bound = &.{boolean},
        .regions = &.{region},
    } } });
    try b.define(root, try b.term(.{ .with_region = .{ .region = region, .body = try b.lambda(inside, inside_type) } }));
    return b.module(root, unit);
}

fn scopedEvidence(c: protean.Context, d: protean.approval.Definition, owner: Id, w: LiveWitness) !Id {
    const b = c.builder;
    const proof = try b.variable(w.proof);
    const read = try b.term(.{ .call = .{ .function = w.read, .arguments = &.{} } });
    try c.registry.allowPrivateCall(owner, read, w.read);
    const approve = try protean.approval.approveWithEvidence(
        c,
        d,
        owner,
        try b.constant(u64, 42),
        try b.reference(proof),
    );
    return b.bind(proof, read, approve);
}

test "current policy may borrow a scoped cell across the approval interaction" {
    for ([_]Mode{ .scoped, .scoped_evidence }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        var registry = protean.admission.Registry.init(std.testing.allocator);
        defer registry.deinit();
        const module = try build(.{ .builder = &b, .registry = &registry }, mode);
        try protean.admission.verify(std.testing.allocator, module, &registry);
        var compiled = try horos.program.compile(std.testing.allocator, module);
        defer compiled.deinit();
        try std.testing.expectEqual(@as(Id, 1), compiled.program.scopes.region_count);
    }
}
