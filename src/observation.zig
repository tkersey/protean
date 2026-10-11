//! One domain client, interpreted as live I/O or authored simulation.
//! Origin tags describe observations. Only the separate internal evidence
//! resource can satisfy a protected commitment's live-evidence requirement.
const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const typed = horos.authoring;
const authoring = @import("authoring.zig");
const decision = @import("decision.zig");
const Id = source.Id;

pub const Definition = struct {
    name: []const u8,
    live_effect: Id,
    family: decision.Family,
    question: Id,
    data: Id,
    observation: Id,
    proof: Id,
    evidence: Id,
    consume: Id,
    read_evidence: Id,
    live_function: Id,
    live_computation: Id,
};

/// Observation<T> = External(T) | Simulated(T).
/// Evidence<T> = (T, private LiveEvidence<T>).
/// Keeping the resource separate lets immutable data enter speculative scopes
/// while its one-shot evidence remains in the surrounding live computation.
pub fn define(c: authoring.Context, name: []const u8, live_effect: Id) !Definition {
    const b = c.builder;
    const instance = try b.specialization(Definition, "agent.observation/v1", .{name});
    if (instance.cached) |existing| {
        if (existing.live_effect != live_effect) return error.InvalidObservationContract;
        return existing;
    }
    try validate(c, name, live_effect);
    const effect = b.effects.items[@intCast(live_effect)];
    const observation = try b.schema(.{ .sum = &.{ effect.result, effect.result } });
    const identity = try b.allocator().print("agent.observation.ask.v1.{s}", .{name});
    const family = try decision.define(b, identity, effect.payload, observation);
    try c.registry.classify(family.effect, .internal);
    const proof = try b.resource(effect.result);
    const evidence = try b.schema(.{ .product = &.{ effect.result, proof } });
    const live = try b.declare(&.{effect.payload}, effect.result, &.{live_effect}, &.{});
    const read_evidence = try b.declare(&.{effect.payload}, evidence, &.{live_effect}, &.{});
    const consume = try b.declare(&.{proof}, effect.result, &.{}, &.{});
    for ([_]Id{ live, read_evidence, consume }) |f| try c.registry.privateFunction(f);
    try b.resourceAuthority(proof, &.{read_evidence}, &.{consume});
    try c.registry.protectResource(proof);
    const live_computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{effect.payload},
        .result = effect.result,
        .effects = &.{live_effect},
    } } });
    const d: Definition = .{
        .name = name,
        .live_effect = live_effect,
        .family = family,
        .question = effect.payload,
        .data = effect.result,
        .observation = observation,
        .proof = proof,
        .evidence = evidence,
        .consume = consume,
        .read_evidence = read_evidence,
        .live_function = live,
        .live_computation = live_computation,
    };
    try defineOwners(c, d);
    return instance.finish(b, d);
}

fn validate(c: authoring.Context, name: []const u8, effect: Id) !void {
    if (name.len == 0 or effect >= c.builder.effects.items.len)
        return error.InvalidObservationContract;
    const signature = c.builder.effects.items[@intCast(effect)];
    if (!signature.external or signature.bodies.len != 0 or signature.use_site_effects.len != 0)
        return error.InvalidObservationContract;
    for (c.registry.classifications.items) |classification| {
        if (classification.effect == effect and classification.role == .read) return;
    }
    return error.InvalidObservationContract;
}

fn defineOwners(c: authoring.Context, d: Definition) !void {
    const b = c.builder;
    const request = try b.term(.{ .perform = .{
        .effect = d.live_effect,
        .payload = try b.reference(b.parameter(d.live_function, 0)),
    } });
    try c.registry.protectSite(d.live_function, request, d.live_effect);
    try b.define(d.live_function, request);
    const observed = try b.variable(d.data);
    const read = try b.term(.{ .call = .{
        .function = d.live_function,
        .arguments = &.{try b.reference(b.parameter(d.read_evidence, 0))},
    } });
    try c.registry.allowPrivateCall(d.read_evidence, read, d.live_function);
    const actual = try b.reference(observed);
    const proof = try b.primitive(d.proof, .resource_pack, &.{actual}, 0);
    const result = try b.primitive(d.evidence, .product, &.{ actual, proof }, 0);
    try b.define(d.read_evidence, try b.bind(observed, read, try b.pure(result)));
    const represented = try b.primitive(d.data, .resource_unpack, &.{try b.reference(b.parameter(d.consume, 0))}, 0);
    try b.define(d.consume, try b.pure(represented));
}

pub fn ask(b: *source.Builder, d: Definition, capability: Id, question: Id) !Id {
    return decision.ask(b, d.family, capability, question);
}

/// The same authored client body is supplied to both interpretations.
pub fn withLive(
    c: authoring.Context,
    d: Definition,
    owner: Id,
    result: Id,
    body: Id,
    scope: decision.Scope,
    arguments: []const Id,
) !Id {
    const interpreter = try interpret(c.builder, d, result, d.live_computation, scope, .external);
    const responder = try c.builder.lambda(d.live_function, d.live_computation);
    try c.registry.allowPrivateLambda(owner, responder, d.live_function);
    return decision.handle(c.builder, interpreter, body, responder, arguments);
}

/// Simulator is an ordinary reusable computation Q -> T, with its actual row.
/// Any permitted model/read operations in it stay visible to Protean admission.
pub fn withSimulation(
    c: authoring.Context,
    d: Definition,
    result: Id,
    body: Id,
    simulator: Id,
    scope: decision.Scope,
    arguments: []const Id,
) !Id {
    if (simulator >= c.builder.values.items.len) return error.InvalidObservationContract;
    const schema = c.builder.values.items[@intCast(simulator)].schema;
    const interpreter = try interpret(c.builder, d, result, schema, scope, .simulated);
    return decision.handle(c.builder, interpreter, body, simulator, arguments);
}

const Origin = enum { external, simulated };

fn interpret(
    b: *source.Builder,
    d: Definition,
    result: Id,
    responder: Id,
    scope: decision.Scope,
    origin: Origin,
) !decision.Interpretation {
    try checkResponder(b, d, responder, scope.residual);
    const instance = try b.specialization(decision.Interpretation, "agent.observation.interpret/v1", .{
        d.family, result, responder, scope, origin,
    });
    if (instance.cached) |cached| return cached;
    const interpreted = try authoredInterpretation(b, d, result, responder, scope, origin);
    return instance.finish(b, interpreted);
}

fn authoredInterpretation(
    b: *source.Builder,
    d: Definition,
    result: Id,
    responder: Id,
    scope: decision.Scope,
    origin: Origin,
) !decision.Interpretation {
    const c = try typed.Context.init(b);
    const operation = try typed.interop.operation(c, d.family.effect);
    const answer = try typed.interop.schema(c, result);
    const observation = try typed.interop.schema(c, d.observation);
    const response = try typed.interop.namedCallable(c, responder, &.{"question"});
    const captures = try b.allocator().alloc(*const typed.Schema, scope.captures.len + 2);
    for (scope.captures, 0..) |id, i| captures[i] = try typed.interop.schema(c, id);
    captures[scope.captures.len] = try typed.interop.schema(c, d.family.capability);
    captures[scope.captures.len + 1] = response;
    const residual = try b.allocator().alloc(*const typed.Operation, scope.residual.effects.len);
    for (scope.residual.effects, residual) |id, *item| item.* = try typed.interop.operation(c, id);
    const owned = try b.allocator().alloc(*const typed.Region, scope.owned_regions.len);
    for (scope.owned_regions, owned) |id, *item| item.* = try typed.interop.region(c, id);
    const borrowed = try b.allocator().alloc(*const typed.Region, scope.borrowed_regions.len);
    for (scope.borrowed_regions, borrowed) |id, *item| item.* = try typed.interop.region(c, id);
    const handler = try c.handler(operation, answer, answer, .{
        .mode = .deep,
        .use = .linear,
        .obligations = true,
        .return_effects = &.{},
        .residual = residual,
        .captures = captures,
        .owned_regions = owned,
        .borrowed_regions = borrowed,
        .state = &.{.{ .name = "responder", .schema = response }},
    });
    const returns = try c.returnFunction(handler);
    const return_body = try c.body(returns);
    try c.define(returns, try return_body.ret(try return_body.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const body = try c.body(clause);
    const observed = try body.apply(try body.parameter("responder"), &.{.{
        .name = "question",
        .value = try body.parameter("payload"),
    }});
    const tagged = try body.variant(observation, switch (origin) {
        .external => "0",
        .simulated => "1",
    }, observed);
    const resumed = try body.resumeValue(try body.parameter("resumption"), tagged);
    try c.define(clause, try body.ret(resumed));
    return .{
        .handler = try typed.interop.handlerId(c, handler),
        .resumption = try typed.interop.schemaId(c, try typed.interop.resumptionSchema(c, handler)),
    };
}

fn checkResponder(b: *source.Builder, d: Definition, schema: Id, residual: source.Row) !void {
    if (schema >= b.schemas.items.len) return error.InvalidObservationContract;
    const shape = b.schemas.items[@intCast(schema)];
    if (shape != .internal or shape.internal != .computation)
        return error.InvalidObservationContract;
    const computation = shape.internal.computation;
    if (computation.parameters.len != 1 or computation.parameters[0] != d.question or
        computation.result != d.data or computation.use != .reusable)
        return error.InvalidObservationContract;
    for (computation.effects) |effect| {
        if (std.mem.indexOfScalar(Id, residual.effects, effect) == null)
            return error.InvalidEffect;
    }
}

/// Only this call returns commit-eligible evidence, after the corresponding live
/// effect. Resource authority rejects application/model/simulation proof minting.
pub fn readEvidence(c: authoring.Context, d: Definition, owner: Id, question: Id) !Id {
    return privateCall(c, owner, d.read_evidence, &.{question});
}

/// Consumption returns ordinary data and discharges ownership; it grants no
/// authority for another operation. Approval owns its own exact-data comparison.
pub fn consumeEvidence(c: authoring.Context, d: Definition, owner: Id, proof: Id) !Id {
    if (proof >= c.builder.values.items.len or
        c.builder.values.items[@intCast(proof)].schema != d.proof)
        return error.LiveEvidenceRequired;
    return privateCall(c, owner, d.consume, &.{proof});
}

fn privateCall(c: authoring.Context, owner: Id, function: Id, arguments: []const Id) !Id {
    const term = try c.builder.term(.{ .call = .{ .function = function, .arguments = arguments } });
    try c.registry.allowPrivateCall(owner, term, function);
    return term;
}
