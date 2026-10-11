//! Typed questions interpreted by statically authored computations.
//! These helpers emit Horos source, never runtime Zig callbacks.
const horos = @import("horos");
const typed = horos.authoring;
const source = horos.source;
const Id = source.Id;

pub const Family = struct { effect: Id, capability: Id, question: Id, answer: Id };
pub const Interpretation = struct { handler: Id, resumption: Id };
pub const Scope = struct {
    captures: []const Id = &.{},
    residual: source.Row = .{ .effects = &.{} },
    owned_regions: []const Id = &.{},
    borrowed_regions: []const Id = &.{},
};

pub fn define(b: *source.Builder, identity: []const u8, question: Id, answer: Id) source.Error!Family {
    const instance = try b.specialization(Family, "agent.ask/v1", .{ identity, question, answer });
    if (instance.cached) |cached| return cached;
    for (b.effects.items) |effect| {
        if (@import("std").mem.eql(u8, effect.identity, identity)) return error.InvalidSource;
    }
    const family = authoredFamily(b, identity, question, answer) catch |err| return typed.sourceError(err);
    return instance.finish(b, family);
}

fn authoredFamily(b: *source.Builder, identity: []const u8, question: Id, answer: Id) typed.Error!Family {
    const c = try typed.Context.init(b);
    const effect = try c.local(identity, try typed.interop.schema(c, question), try typed.interop.schema(c, answer), .linear);
    return .{
        .effect = try typed.interop.operationId(c, effect),
        .capability = try typed.interop.schemaId(c, try c.capability(effect)),
        .question = question,
        .answer = answer,
    };
}

/// The responder is a reusable authored computation Q -> A. Its row and captures
/// remain subject to Horos admission, including effects used while answering.
/// It may be implemented with human/model effects, rules, or a delegated body.
pub fn interpret(
    b: *source.Builder,
    family: Family,
    result: Id,
    responder: Id,
    scope: Scope,
) source.Error!Interpretation {
    try checkResponder(b, family, responder, scope.residual);
    const instance = try b.specialization(Interpretation, "agent.ask.interpret/v1", .{
        family, result, responder, scope,
    });
    if (instance.cached) |cached| return cached;
    const interpretation = authoredInterpretation(b, family, result, responder, scope) catch |err|
        return typed.sourceError(err);
    return instance.finish(b, interpretation);
}

fn schemas(c: *typed.Context, ids: []const Id) typed.Error![]const *const typed.Schema {
    const result = try typed.interop.builder(c).allocator().alloc(*const typed.Schema, ids.len);
    for (ids, result) |id, *item| item.* = try typed.interop.schema(c, id);
    return result;
}

fn operations(c: *typed.Context, ids: []const Id) typed.Error![]const *const typed.Operation {
    const result = try typed.interop.builder(c).allocator().alloc(*const typed.Operation, ids.len);
    for (ids, result) |id, *item| item.* = try typed.interop.operation(c, id);
    return result;
}

fn regions(c: *typed.Context, ids: []const Id) typed.Error![]const *const typed.Region {
    const result = try typed.interop.builder(c).allocator().alloc(*const typed.Region, ids.len);
    for (ids, result) |id, *item| item.* = try typed.interop.region(c, id);
    return result;
}

fn authoredInterpretation(
    b: *source.Builder,
    family: Family,
    result: Id,
    responder: Id,
    scope: Scope,
) typed.Error!Interpretation {
    const c = try typed.Context.init(b);
    const operation = try typed.interop.operation(c, family.effect);
    const answer_schema = try typed.interop.schema(c, result);
    const responder_schema = try typed.interop.namedCallable(c, responder, &.{"question"});
    const captures = try b.allocator().alloc(*const typed.Schema, scope.captures.len + 2);
    @memcpy(captures[0..scope.captures.len], try schemas(c, scope.captures));
    captures[scope.captures.len] = try typed.interop.schema(c, family.capability);
    captures[scope.captures.len + 1] = responder_schema;
    const handler = try c.handler(operation, answer_schema, answer_schema, .{
        .mode = .deep,
        .use = .linear,
        .obligations = true,
        .return_effects = &.{},
        .residual = try operations(c, scope.residual.effects),
        .captures = captures,
        .owned_regions = try regions(c, scope.owned_regions),
        .borrowed_regions = try regions(c, scope.borrowed_regions),
        .state = &.{.{ .name = "responder", .schema = responder_schema }},
    });
    const returns = try c.returnFunction(handler);
    const return_body = try c.body(returns);
    try c.define(returns, try return_body.ret(try return_body.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const clause_body = try c.body(clause);
    const reply = try clause_body.apply(try clause_body.parameter("responder"), &.{.{
        .name = "question",
        .value = try clause_body.parameter("payload"),
    }});
    const resumed = try clause_body.resumeValue(try clause_body.parameter("resumption"), reply);
    try c.define(clause, try clause_body.ret(resumed));
    return .{
        .handler = try typed.interop.handlerId(c, handler),
        .resumption = try typed.interop.schemaId(c, try typed.interop.resumptionSchema(c, handler)),
    };
}

fn checkResponder(b: *source.Builder, family: Family, schema: Id, residual: source.Row) !void {
    if (schema >= b.schemas.items.len) return error.InvalidReference;
    const shape = b.schemas.items[@intCast(schema)];
    if (shape != .internal or shape.internal != .computation) return error.TypeMismatch;
    const computation = shape.internal.computation;
    if (computation.parameters.len != 1 or computation.parameters[0] != family.question or
        computation.result != family.answer) return error.TypeMismatch;
    if (computation.use != .reusable) return error.InvalidOwnership;
    for (computation.effects) |effect| {
        if (@import("std").mem.indexOfScalar(Id, residual.effects, effect) == null)
            return error.InvalidEffect;
    }
}

pub fn ask(b: *source.Builder, family: Family, capability: Id, question: Id) source.Error!Id {
    return b.term(.{ .perform = .{
        .effect = family.effect,
        .capability = capability,
        .payload = question,
    } });
}

pub fn handle(
    b: *source.Builder,
    interpretation: Interpretation,
    body: Id,
    responder: Id,
    arguments: []const Id,
) source.Error!Id {
    return b.term(.{ .handle = .{
        .handler = interpretation.handler,
        .body = body,
        .arguments = arguments,
        .state = &.{responder},
    } });
}
