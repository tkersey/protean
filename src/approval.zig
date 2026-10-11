//! Approval and consumption are one ordinary staged computation. Only this
//! computation owns its protected effects and its non-cloneable internal grant.
const std = @import("std");
const source = @import("horos").source;
const typed = @import("horos").authoring;
const authoring = @import("authoring.zig");
const interaction = @import("interaction.zig");
const equality = @import("value_equality.zig");
pub const Id = source.Id;

/// A declaration may require provenance from a protected live observation. Its
/// one-shot proof travels separately from the portable proposal and challenge.
pub const Evidence = struct {
    proof: Id,
    consume: Id,
    project: Id,
};

pub const Config = struct {
    name: []const u8,
    proposal: Id,
    occurrence: Id,
    principal: Id,
    reason: Id,
    commit_effect: Id,
    /// Pure (proposal, authenticated principal) -> bool. The adapter authenticates
    /// identity; this image-owned function checks the required declared scope.
    authority: Id,
    /// (proposal) -> bool, with declared read-only effects if required. The
    /// environmental commit must atomically enforce its retained precondition.
    revalidate: Id,
    /// Literal source value with the enclosing module's failure schema.
    failure: Id,
    channel: []const u8,
    evidence: ?Evidence = null,
    /// Optional program-owned (proposal) -> bool placement after exact approval.
    /// Only protected mobility effects are permitted. The private one-shot grant
    /// stays in this owner across placement; revalidation still runs afterwards.
    placement: ?Id = null,
};

pub const Definition = struct {
    config: Config,
    entry: Id,
    function: Id,
    proposal: Id,
    occurrence: Id,
    principal: Id,
    challenge: Id,
    decision: Id,
    reply: Id,
    result: Id,
    issuer: Id,
    exchange: interaction.Definition,
    effects: []const Id,
    regions: []const Id,
};

/// All schemas and functions belong to this Context's Builder. A proposal must
/// contain the exact operation, arguments, live evidence, reason and scope used
/// by this declaration's policy. The returned safe operation never exposes grant.
pub fn define(c: authoring.Context, cfg: Config) !Definition {
    const b = c.builder;
    const instance = try b.specialization(Definition, "agent.approval/v1", .{cfg.name});
    if (instance.cached) |existing| {
        if (!sameConfig(existing.config, cfg)) return error.InvalidApprovalContract;
        return existing;
    }
    try validate(c, cfg);
    const unit = try b.scalar(void);
    const text = try b.schema(.text);
    const operation_result = b.effects.items[@intCast(cfg.commit_effect)].result;
    const challenge = try b.schema(.{ .product = &.{ cfg.occurrence, cfg.proposal } });
    const decision = try b.schema(.{ .sum = &.{ unit, cfg.reason, cfg.proposal } });
    const reply = try b.schema(.{ .product = &.{ challenge, cfg.principal, decision } });
    const result = try b.schema(.{ .sum = &.{ operation_result, cfg.reason, unit, unit } });
    const issuer_name = try b.allocator().print(
        "agent.approval.issue.v1.{s}",
        .{cfg.name},
    );
    const issuer = try c.external(issuer_name, cfg.proposal, cfg.occurrence, .approval);
    const exchange = try interaction.define(b, .{
        .name = cfg.name,
        .channel = text,
        .purpose = text,
        .presentation = unit,
        .outgoing = challenge,
        .input = reply,
    });
    try c.registry.classify(exchange.effect, .approval);
    try c.registry.classify(cfg.commit_effect, .commit);
    const effects = try effectRow(
        b,
        &.{ issuer, exchange.effect, cfg.commit_effect },
        cfg.revalidate,
        cfg.placement,
    );
    const regions = try regionRow(b, cfg);
    const data = if (cfg.evidence) |e| b.functions.items[@intCast(e.consume)].result else null;
    const parameters: []const Id = if (data) |schema| &.{ cfg.proposal, schema } else &.{cfg.proposal};
    const function = try b.declare(parameters, result, effects, regions);
    const entry = if (cfg.evidence) |e| try b.declare(
        &.{ cfg.proposal, e.proof },
        result,
        effects,
        regions,
    ) else function;
    if (entry != function) try c.registry.privateFunction(entry);
    try c.registry.privateFunction(function);
    const grant = try b.resource(cfg.proposal);
    try b.resourceAuthority(grant, &.{function}, &.{function});
    try c.registry.protectResource(grant);
    const d: Definition = .{
        .config = cfg,
        .entry = entry,
        .function = function,
        .proposal = cfg.proposal,
        .occurrence = cfg.occurrence,
        .principal = cfg.principal,
        .challenge = challenge,
        .decision = decision,
        .reply = reply,
        .result = result,
        .issuer = issuer,
        .exchange = exchange,
        .effects = effects,
        .regions = regions,
    };
    try b.define(function, try body(c, d, cfg, grant));
    if (cfg.evidence) |e| try b.define(entry, try enterWithEvidence(c, d, e));
    return instance.finish(b, d);
}

/// Owner is the enclosing authored function. Final admission binds this exact
/// call site to the private checked owner; copying the source term elsewhere
/// does not create another authorized route.
pub fn approveAndCommit(c: authoring.Context, d: Definition, owner: Id, proposal: Id) !Id {
    if (d.config.evidence != null) return error.LiveEvidenceRequired;
    const term = try c.builder.term(.{ .call = .{
        .function = d.entry,
        .arguments = &.{proposal},
    } });
    try c.registry.allowPrivateCall(owner, term, d.entry);
    return term;
}

/// The actual live proof is consumed inside the checked owner before any human
/// question. Its data remains private across amendments; a changed base cannot
/// inherit a proof for a different observation.
pub fn approveWithEvidence(
    c: authoring.Context,
    d: Definition,
    owner: Id,
    proposal: Id,
    proof: Id,
) !Id {
    if (d.config.evidence == null) return error.UnexpectedLiveEvidence;
    const term = try c.builder.term(.{ .call = .{
        .function = d.entry,
        .arguments = &.{ proposal, proof },
    } });
    try c.registry.allowPrivateCall(owner, term, d.entry);
    return term;
}

fn enterWithEvidence(c: authoring.Context, d: Definition, e: Evidence) !Id {
    const b = c.builder;
    const actual = try b.variable(b.functions.items[@intCast(e.consume)].result);
    const consume = try b.term(.{ .call = .{
        .function = e.consume,
        .arguments = &.{try b.reference(b.parameter(d.entry, 1))},
    } });
    try c.registry.allowPrivateCall(d.entry, consume, e.consume);
    const start = try b.term(.{ .call = .{
        .function = d.function,
        .arguments = &.{
            try b.reference(b.parameter(d.entry, 0)), try b.reference(actual),
        },
    } });
    try c.registry.allowPrivateCall(d.entry, start, d.function);
    return b.bind(actual, consume, start);
}

fn validate(c: authoring.Context, cfg: Config) !void {
    const b = c.builder;
    const boolean = try b.scalar(bool);
    if (cfg.name.len == 0 or cfg.channel.len == 0) return error.InvalidApprovalContract;
    if (cfg.commit_effect >= b.effects.items.len) return error.InvalidApprovalContract;
    const commit = b.effects.items[@intCast(cfg.commit_effect)];
    if (!commit.external or commit.payload != cfg.proposal or
        commit.result >= b.schemas.items.len) return error.InvalidApprovalContract;
    const outcome = b.schemas.items[@intCast(commit.result)];
    if (outcome != .sum or outcome.sum.len != 4) return error.InvalidCommitOutcome;
    try checkFunction(b, cfg.authority, &.{ cfg.proposal, cfg.principal }, boolean);
    try checkFunction(b, cfg.revalidate, &.{cfg.proposal}, boolean);
    if (cfg.placement) |placement| {
        try checkFunction(b, placement, &.{cfg.proposal}, boolean);
        for (b.functions.items[@intCast(placement)].effects) |effect| {
            var movable = false;
            for (c.registry.classifications.items) |item| {
                if (item.effect == effect and item.role == .mobility) movable = true;
            }
            if (!movable) return error.InvalidApprovalPlacement;
        }
    }
    if (cfg.evidence) |e| {
        if (e.proof >= b.schemas.items.len or e.consume >= b.functions.items.len)
            return error.InvalidLiveEvidence;
        const shape = b.schemas.items[@intCast(e.proof)];
        if (shape != .internal or shape.internal != .abstract_resource or
            shape.internal.abstract_resource >= b.resources.items.len or
            std.mem.indexOfScalar(Id, c.registry.protected_resources.items, e.proof) == null)
            return error.InvalidLiveEvidence;
        const data = b.functions.items[@intCast(e.consume)].result;
        try checkFunction(b, e.consume, &.{e.proof}, data);
        try checkFunction(b, e.project, &.{cfg.proposal}, data);
        if (b.functions.items[@intCast(e.consume)].effects.len != 0 or
            b.functions.items[@intCast(e.project)].effects.len != 0 or
            std.mem.indexOfScalar(Id, c.registry.private_functions.items, e.consume) == null)
            return error.InvalidLiveEvidence;
        const resource = b.resources.items[@intCast(shape.internal.abstract_resource)];
        if (resource.representation != data or
            std.mem.indexOfScalar(Id, resource.eliminators, e.consume) == null)
            return error.InvalidLiveEvidence;
    }
    if (b.functions.items[@intCast(cfg.authority)].effects.len != 0)
        return error.InvalidApprovalAuthority;
    for (b.functions.items[@intCast(cfg.revalidate)].effects) |effect| {
        const roles = c.registry.classifications.items;
        var read = false;
        for (roles) |item| if (item.effect == effect) {
            read = item.role == .read;
        };
        if (!read) return error.InvalidApprovalPrecondition;
    }
}

fn checkFunction(b: *source.Builder, function: Id, parameters: []const Id, result: Id) !void {
    if (function >= b.functions.items.len) return error.InvalidApprovalContract;
    const f = b.functions.items[@intCast(function)];
    if (f.result != result or f.parameters.len != parameters.len)
        return error.InvalidApprovalContract;
    for (f.parameters, parameters) |actual, expected|
        if (b.variables.items[@intCast(actual)] != expected) return error.InvalidApprovalContract;
}

fn effectRow(b: *source.Builder, initial: []const Id, revalidate: Id, placement: ?Id) ![]const Id {
    var effects: std.ArrayList(Id) = .empty;
    try effects.appendSlice(b.allocator(), initial);
    for (b.functions.items[@intCast(revalidate)].effects) |effect| {
        if (std.mem.indexOfScalar(Id, effects.items, effect) == null)
            try effects.append(b.allocator(), effect);
    }
    if (placement) |function| for (b.functions.items[@intCast(function)].effects) |effect| {
        if (std.mem.indexOfScalar(Id, effects.items, effect) == null)
            try effects.append(b.allocator(), effect);
    };
    std.mem.sort(Id, effects.items, {}, std.sort.asc(Id));
    return effects.toOwnedSlice(b.allocator());
}

fn regionRow(b: *source.Builder, cfg: Config) ![]const Id {
    var regions: std.ArrayList(Id) = .empty;
    var functions = [_]Id{ cfg.authority, cfg.revalidate, 0, 0, 0 };
    var count: usize = 2;
    if (cfg.evidence) |e| {
        functions[2] = e.consume;
        functions[3] = e.project;
        count = 4;
    }
    if (cfg.placement) |placement| {
        functions[count] = placement;
        count += 1;
    }
    for (functions[0..count]) |function| {
        for (b.functions.items[@intCast(function)].regions) |region| {
            if (std.mem.indexOfScalar(Id, regions.items, region) == null)
                try regions.append(b.allocator(), region);
        }
    }
    std.mem.sort(Id, regions.items, {}, std.sort.asc(Id));
    return regions.toOwnedSlice(b.allocator());
}

fn body(c: authoring.Context, d: Definition, cfg: Config, grant: Id) !Id {
    const b = c.builder;
    const proposal = try b.reference(b.parameter(d.function, 0));
    const occurrence = try b.variable(d.occurrence);
    const retained = try b.variable(d.challenge);
    const incoming = try b.variable(d.exchange.reply);
    const answered = try b.variable(d.reply);
    const challenge = try b.primitive(d.challenge, .product, &.{
        try b.reference(occurrence), proposal,
    }, 0);
    const asked = try interaction.exchange(b, d.exchange, .{
        .channel = try textValue(b, cfg.channel),
        .purpose = try textValue(b, "approval"),
        .presentation = try b.constant(void, {}),
        .outgoing = try b.reference(retained),
    });
    try c.registry.protectSite(d.function, asked, d.exchange.effect);
    const issuance = try protectedPerform(c, d.function, d.issuer, proposal);
    const handled = try b.term(.{ .match_sum = .{
        .value = try b.reference(incoming),
        .cases = &.{.{ .variable = answered, .body = try answer(c, d, cfg, grant, proposal, try b.reference(retained), try b.reference(answered)) }},
    } });
    const next = try b.bind(occurrence, issuance, try b.bind(retained, try b.pure(challenge), try b.bind(incoming, asked, handled)));
    if (cfg.evidence) |e| return evidenceMatches(c, d, e, proposal, cfg.failure, next);
    return next;
}

fn answer(
    c: authoring.Context,
    d: Definition,
    cfg: Config,
    grant: Id,
    proposal: Id,
    retained: Id,
    incoming: Id,
) !Id {
    const b = c.builder;
    const t = try typed.Context.init(b);
    const root = try typed.interop.scope(t);
    const challenge = try typed.interop.schema(t, d.challenge);
    _ = try b.failureLiteral(cfg.failure);
    const fault = try typed.interop.literalFailure(t, cfg.failure, try typed.interop.schema(t, b.values.items[@intCast(cfg.failure)].schema));
    const compare = try equality.create(t, challenge, fault);
    const reply = try typed.interop.adoptValue(root, incoming, try typed.interop.schema(t, d.reply));
    const expected = try typed.interop.adoptValue(root, retained, challenge);
    const same = try root.call(compare, &.{ .{ .name = "left", .value = expected }, .{ .name = "right", .value = try root.field(reply, "0") } });
    const matching = try root.branch();
    const invalid = try root.branch();
    const result = try typed.interop.schema(t, d.result);
    const principal = try matching.field(reply, "1");
    const auth = try b.term(.{ .call = .{ .function = cfg.authority, .arguments = &.{ proposal, try typed.interop.valueId(matching, principal) } } });
    const allowed = try typed.interop.term(matching, auth, try t.scalar(bool));
    const authorized = try matching.branch();
    const denied = try matching.branch();
    const decision = try decisionBody(c, d, cfg, grant, proposal, try typed.interop.valueId(authorized, try authorized.field(reply, "2")));
    const checked = try matching.conditional(allowed, try authorized.ret(try typed.interop.term(authorized, decision, result)), try denied.ret(try denied.variant(result, "3", try denied.constant(void, {}))));
    return typed.interop.computationId(t, try root.ret(try root.conditional(same, try matching.ret(checked), try invalid.ret(try invalid.variant(result, "2", try invalid.constant(void, {}))))));
}

fn decisionBody(
    c: authoring.Context,
    d: Definition,
    cfg: Config,
    grant: Id,
    proposal: Id,
    selected: Id,
) !Id {
    const b = c.builder;
    const approved = try b.variable(try b.scalar(void));
    const rejected = try b.variable(cfg.reason);
    const amended = try b.variable(cfg.proposal);
    return b.term(.{ .match_sum = .{ .value = selected, .cases = &.{
        .{ .variable = approved, .body = try commitBody(c, d, cfg, grant, proposal) },
        .{ .variable = rejected, .body = try b.pure(try b.primitive(d.result, .variant, &.{try b.reference(rejected)}, 1)) },
        .{ .variable = amended, .body = try repeat(c, d, try b.reference(amended)) },
    } } });
}

fn commitBody(c: authoring.Context, d: Definition, cfg: Config, grant: Id, proposal: Id) !Id {
    if (cfg.placement) |placement| return placedCommitBody(c, d, cfg, grant, proposal, placement);
    const b = c.builder;
    const allowed = try b.variable(try b.scalar(bool));
    const permission = try b.variable(grant);
    const consumed = try b.variable(d.proposal);
    const operation_result = b.effects.items[@intCast(cfg.commit_effect)].result;
    const observed = try b.variable(operation_result);
    const performed = try protectedPerform(c, d.function, cfg.commit_effect, try b.reference(consumed));
    const result = try b.pure(try b.primitive(d.result, .variant, &.{try b.reference(observed)}, 0));
    const consume = try b.primitive(d.proposal, .resource_unpack, &.{try b.reference(permission)}, 0);
    const mint = try b.primitive(grant, .resource_pack, &.{proposal}, 0);
    const commit = try b.bind(permission, try b.pure(mint), try b.bind(consumed, try b.pure(consume), try b.bind(observed, performed, result)));
    const revalidate = try b.term(.{ .call = .{
        .function = cfg.revalidate,
        .arguments = &.{proposal},
    } });
    return b.bind(allowed, revalidate, try b.term(.{ .conditional = .{
        .condition = try b.reference(allowed),
        .when_true = commit,
        .when_false = try emptyResult(b, d, 3),
    } }));
}

fn placedCommitBody(c: authoring.Context, d: Definition, cfg: Config, grant: Id, proposal: Id, placement: Id) !Id {
    const b = c.builder;
    const permission = try b.variable(grant);
    const placed = try b.variable(try b.scalar(bool));
    const consumed = try b.variable(d.proposal);
    const allowed = try b.variable(try b.scalar(bool));
    const observed = try b.variable(b.effects.items[@intCast(cfg.commit_effect)].result);
    const commit = try b.bind(observed, try protectedPerform(c, d.function, cfg.commit_effect, try b.reference(consumed)), try b.pure(try b.primitive(d.result, .variant, &.{try b.reference(observed)}, 0)));
    const revalidate = try b.term(.{ .call = .{ .function = cfg.revalidate, .arguments = &.{try b.reference(consumed)} } });
    const checked = try b.bind(allowed, revalidate, try b.term(.{ .conditional = .{
        .condition = try b.reference(allowed),
        .when_true = commit,
        .when_false = try emptyResult(b, d, 3),
    } }));
    const selected = try b.term(.{ .conditional = .{
        .condition = try b.reference(placed),
        .when_true = checked,
        .when_false = try emptyResult(b, d, 3),
    } });
    const move = try b.term(.{ .call = .{ .function = placement, .arguments = &.{proposal} } });
    const mint = try b.pure(try b.primitive(grant, .resource_pack, &.{proposal}, 0));
    const consume = try b.pure(try b.primitive(d.proposal, .resource_unpack, &.{try b.reference(permission)}, 0));
    // Both placement branches consume the same retained grant. No caller can
    // extract it, skip final revalidation, or turn refusal into commit authority.
    return b.bind(permission, mint, try b.bind(placed, move, try b.bind(consumed, consume, selected)));
}

fn protectedPerform(c: authoring.Context, owner: Id, effect: Id, payload: Id) !Id {
    const term = try c.builder.term(.{ .perform = .{ .effect = effect, .payload = payload } });
    try c.registry.protectSite(owner, term, effect);
    return term;
}

fn emptyResult(b: *source.Builder, d: Definition, tag: Id) !Id {
    return b.pure(try b.primitive(d.result, .variant, &.{try b.constant(void, {})}, tag));
}

fn textValue(b: *source.Builder, value: []const u8) !Id {
    const contracts = @import("protean_contracts");
    return b.literal(.{
        .schema = try b.schema(.text),
        .bytes = try contracts.encodeOwned(contracts.Utf8, b.allocator(), .{ .bytes = value }),
    });
}

fn sameConfig(a: Config, b: Config) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.channel, b.channel) and
        a.proposal == b.proposal and a.occurrence == b.occurrence and a.principal == b.principal and
        a.reason == b.reason and a.commit_effect == b.commit_effect and
        a.authority == b.authority and
        a.revalidate == b.revalidate and a.failure == b.failure and
        std.meta.eql(a.evidence, b.evidence) and a.placement == b.placement;
}

fn evidenceMatches(
    c: authoring.Context,
    d: Definition,
    e: Evidence,
    proposal: Id,
    failure: Id,
    next: Id,
) !Id {
    const b = c.builder;
    const t = try typed.Context.init(b);
    const root = try typed.interop.scope(t);
    const data = try typed.interop.schema(t, b.functions.items[@intCast(e.consume)].result);
    _ = try b.failureLiteral(failure);
    const fault = try typed.interop.literalFailure(t, failure, try typed.interop.schema(t, b.values.items[@intCast(failure)].schema));
    const compare = try equality.create(t, data, fault);
    const project = try b.term(.{ .call = .{ .function = e.project, .arguments = &.{proposal} } });
    const projected = try typed.interop.term(root, project, data);
    const actual = try typed.interop.adoptValue(root, try b.reference(b.parameter(d.function, 1)), data);
    const same = try root.call(compare, &.{ .{ .name = "left", .value = projected }, .{ .name = "right", .value = actual } });
    const yes = try root.branch();
    const no = try root.branch();
    const result = try typed.interop.schema(t, d.result);
    return typed.interop.computationId(t, try root.ret(try root.conditional(same, try yes.ret(try typed.interop.term(yes, next, result)), try no.ret(try no.variant(result, "3", try no.constant(void, {}))))));
}

fn repeat(c: authoring.Context, d: Definition, proposal: Id) !Id {
    const b = c.builder;
    const args: []const Id = if (d.config.evidence != null) &.{
        proposal, try b.reference(b.parameter(d.function, 1)),
    } else &.{proposal};
    const term = try b.term(.{ .call = .{ .function = d.function, .arguments = args } });
    try c.registry.allowPrivateCall(d.function, term, d.function);
    return term;
}
