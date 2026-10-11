//! Scoped candidate evaluation: multi-shot exploration and sequential assessment.
//! Alternatives and assessments are program values; no host snapshot is cloned.
const source = @import("horos").source;
pub const Id = source.Id;

pub const Scope = struct {
    captures: []const Id = &.{},
    owned_regions: []const Id = &.{},
    borrowed_regions: []const Id = &.{},
    residual: source.Row = .{ .effects = &.{} },
};

pub const Deliberation = struct {
    effect: Id,
    capability: Id,
    candidate: Id,
    assessment: Id,
    alternatives: Id,
    answer: Id,
    resumption: Id,
    handler: Id,
    clause: Id,
    collect: Id,
};

/// Scope rows declare the actual capture/effect domain. Horos checks their
/// use and lifetime; protected Protean admission additionally checks effect roles.
/// The caller acquires approval and exclusive live resources after evaluate.
pub fn define(
    b: *source.Builder,
    identity: []const u8,
    candidate: Id,
    assessment: Id,
    scope: Scope,
) source.Error!Deliberation {
    const instance = try b.specialization(Deliberation, "agent.deliberation/v1", .{
        identity, candidate, assessment, scope,
    });
    if (instance.cached) |cached| return cached;
    const alternatives = try b.schema(.{ .seq = candidate });
    const answer = try b.schema(.{ .seq = assessment });
    const effect = try b.effect(.{
        .identity = identity,
        .payload = alternatives,
        .result = candidate,
        .control_use = .multi,
        .external = false,
    });
    const capability = try b.schema(.{ .internal = .{ .capability = effect } });
    const captures = try b.allocator().alloc(Id, scope.captures.len + 1);
    @memcpy(captures[0..scope.captures.len], scope.captures);
    captures[scope.captures.len] = capability;
    const resumption = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = candidate,
        .answer = answer,
        .effects = scope.residual.effects,
        .capture_bound = captures,
        .handled = &.{effect},
        .mode = .deep,
        .use = .multi,
        .owned_regions = scope.owned_regions,
    } } });
    return instance.finish(b, try interpretation(b, .{
        .effect = effect,
        .capability = capability,
        .candidate = candidate,
        .assessment = assessment,
        .alternatives = alternatives,
        .answer = answer,
        .resumption = resumption,
        .handler = 0,
        .clause = 0,
        .collect = 0,
    }, scope));
}

fn interpretation(
    b: *source.Builder,
    definition: Deliberation,
    scope: Scope,
) source.Error!Deliberation {
    var d = definition;
    const returns = try b.declare(&.{d.assessment}, d.answer, &.{}, scope.borrowed_regions);
    const returned = try b.reference(b.parameter(returns, 0));
    const singleton = try b.primitive(d.answer, .sequence, &.{returned}, 0);
    try b.define(returns, try b.pure(singleton));
    d.collect = try collector(b, d, scope);
    d.clause = try b.declare(
        &.{ d.alternatives, d.resumption },
        d.answer,
        scope.residual.effects,
        scope.borrowed_regions,
    );
    const arguments = [_]Id{
        try b.reference(b.parameter(d.clause, 1)),
        try b.reference(b.parameter(d.clause, 0)),
        try b.primitive(d.answer, .sequence, &.{}, 0),
    };
    try b.define(d.clause, try b.term(.{ .call = .{
        .function = d.collect,
        .arguments = &arguments,
    } }));
    d.handler = try b.handler(.{
        .mode = .deep,
        .input = d.assessment,
        .answer = d.answer,
        .return_function = returns,
        .clauses = &.{.{ .effect = d.effect, .function = d.clause, .resumption = d.resumption }},
        .effects = scope.residual.effects,
    });
    return d;
}

fn collector(b: *source.Builder, d: Deliberation, scope: Scope) source.Error!Id {
    const unit = try b.scalar(void);
    const popped = try b.schema(.{ .product = &.{ d.candidate, d.alternatives } });
    const optional = try b.schema(.{ .sum = &.{ unit, popped } });
    const collect = try b.declare(
        &.{ d.resumption, d.alternatives, d.answer },
        d.answer,
        scope.residual.effects,
        scope.borrowed_regions,
    );
    const template = try b.reference(b.parameter(collect, 0));
    const remaining = try b.reference(b.parameter(collect, 1));
    const found = try b.reference(b.parameter(collect, 2));
    const empty = try b.variable(unit);
    const present = try b.variable(popped);
    const candidate = try b.variable(d.candidate);
    const rest = try b.variable(d.alternatives);
    const assessed = try b.variable(d.answer);
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = template,
        .argument = try b.reference(candidate),
    } });
    const resumed_answer = try b.reference(assessed);
    const combined = try b.primitive(d.answer, .sequence_concat, &.{ found, resumed_answer }, 0);
    const recurse = try b.term(.{ .call = .{
        .function = collect,
        .arguments = &.{ template, try b.reference(rest), combined },
    } });
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(present),
        .variables = &.{ candidate, rest },
        .body = try b.bind(assessed, resumed, recurse),
    } });
    const popped_value = try b.primitive(optional, .sequence_pop, &.{remaining}, 0);
    try b.define(collect, try b.term(.{ .match_sum = .{
        .value = popped_value,
        .cases = &.{
            .{ .variable = empty, .body = try b.pure(found) },
            .{ .variable = present, .body = unpack },
        },
    } }));
    return collect;
}

/// Body is a Horos computation value whose first parameter is the internal
/// choice capability. Its result is one assessment, including non-tail work.
pub fn evaluate(
    b: *source.Builder,
    d: Deliberation,
    body: Id,
    arguments: []const Id,
) source.Error!Id {
    return b.term(.{ .handle = .{
        .handler = d.handler,
        .body = body,
        .arguments = arguments,
    } });
}

/// Register the actual function installed under this multi handler with the
/// protected Protean context. The admitted effects are an explicit allow-list;
/// final admission inspects their roles and the transitive source computation.
pub fn register(context: anytype, d: Deliberation, body: Id, allowed: []const Id) !void {
    try context.registry.classify(d.effect, .internal);
    try context.registry.speculate(body, allowed);
}

/// Each candidate resumes the same internal continuation. An empty collection
/// produces an empty assessment collection; it is an authored policy choice.
pub fn choose(
    b: *source.Builder,
    d: Deliberation,
    capability: Id,
    alternatives: Id,
) source.Error!Id {
    return b.term(.{ .perform = .{
        .effect = d.effect,
        .capability = capability,
        .payload = alternatives,
    } });
}

/// Sequential assessment of immutable candidate data. Selection returns ordinary
/// evidence, never an approval or the caller's completion continuation.
pub const SelectionSpec = struct {
    candidate: Id,
    assessment: Id,
    maximum: u32,
    assess: Id,
    choose: Id,
    allowed: []const Id = &.{},
    failure: Id,
};
pub const SelectionTypes = struct { candidates: Id, assessed: Id, assessments: Id, choice: Id, result: Id };
pub const Selection = struct { function: Id, types: SelectionTypes };
pub fn selectionTypes(b: *source.Builder, candidate: Id, assessment: Id, maximum: u32) source.Error!SelectionTypes {
    if (candidate >= b.schemas.items.len or assessment >= b.schemas.items.len) return error.InvalidReference;
    if (maximum == 0) return error.Capacity;
    const row = try b.schema(.{ .product = &.{ candidate, assessment } });
    const rows = try b.schema(.{ .vector = .{ .element = row, .maximum = maximum } });
    return .{ .candidates = try b.schema(.{ .vector = .{ .element = candidate, .maximum = maximum } }), .assessed = row, .assessments = rows, .choice = try b.schema(.{ .sum = &.{ try b.scalar(u64), try b.scalar(void) } }), .result = try b.schema(.{ .sum = &.{ row, rows } }) };
}

/// assess: Candidate -> Assessment with the admitted assessment effects.
/// choose: [(Candidate, Assessment)] -> Index | Unresolved, pure.
/// Every candidate is assessed in order, including unavailable/failed data. The
/// consumer owns interpretation of that data; no scalar scoring is imposed here.
pub fn selectSequential(c: anytype, spec: SelectionSpec) !Selection {
    const b = c.builder;
    const cache = try b.specialization(Selection, "agent.deliberation.select-sequential/v1", .{spec});
    if (cache.cached) |d| return d;
    const d = try selectionTypes(b, spec.candidate, spec.assessment, spec.maximum);
    try selectionFunction(b, spec.assess, spec.candidate, spec.assessment, spec.allowed);
    try selectionFunction(b, spec.choose, d.assessments, d.choice, &.{});
    try c.registry.speculate(spec.assess, spec.allowed);
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const loop = try b.declare(&.{ d.candidates, integer, d.assessments }, d.result, spec.allowed, &.{});
    const candidates = try b.reference(b.parameter(loop, 0));
    const index = try b.reference(b.parameter(loop, 1));
    const collected = try b.reference(b.parameter(loop, 2));
    const candidate = try b.variable(spec.candidate);
    const assessment = try b.variable(spec.assessment);
    const row = try b.primitive(d.assessed, .product, &.{ try b.reference(candidate), try b.reference(assessment) }, 0);
    const appended = try b.value(.{ .schema = d.assessments, .expression = .{ .primitive = .{
        .opcode = .sequence_append,
        .operands = &.{ collected, row },
        .failures = &.{.{ .kind = .capacity_exceeded, .value = try b.failureLiteral(spec.failure) }},
    } } });
    const next = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ index, try b.constant(u64, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(spec.failure) }},
    } } });
    const proceed = try b.bind(assessment, try b.term(.{ .call = .{ .function = spec.assess, .arguments = &.{try b.reference(candidate)} } }), try b.term(.{ .call = .{ .function = loop, .arguments = &.{ candidates, next, appended } } }));
    const choice = try b.variable(d.choice);
    const chosen = try b.variable(integer);
    const selected = try b.variable(d.assessed);
    const unresolved = try b.pure(try b.primitive(d.result, .variant, &.{collected}, 1));
    const lookup = try b.primitive(try b.schema(.{ .sum = &.{ unit, d.assessed } }), .sequence_get, &.{ collected, try b.reference(chosen) }, 0);
    const checked = try b.term(.{ .match_sum = .{ .value = lookup, .cases = &.{
        .{ .variable = try b.variable(unit), .body = unresolved },
        .{ .variable = selected, .body = try b.pure(try b.primitive(d.result, .variant, &.{try b.reference(selected)}, 0)) },
    } } });
    const resolve = try b.bind(choice, try b.term(.{ .call = .{ .function = spec.choose, .arguments = &.{collected} } }), try b.term(.{ .match_sum = .{ .value = try b.reference(choice), .cases = &.{
        .{ .variable = chosen, .body = checked }, .{ .variable = try b.variable(unit), .body = unresolved },
    } } }));
    const optional = try b.schema(.{ .sum = &.{ unit, spec.candidate } });
    try b.define(loop, try b.term(.{ .match_sum = .{ .value = try b.primitive(optional, .sequence_get, &.{ candidates, index }, 0), .cases = &.{
        .{ .variable = try b.variable(unit), .body = resolve }, .{ .variable = candidate, .body = proceed },
    } } }));
    const function = try b.declare(&.{d.candidates}, d.result, spec.allowed, &.{});
    try b.define(function, try b.term(.{ .call = .{ .function = loop, .arguments = &.{ try b.reference(b.parameter(function, 0)), try b.constant(u64, 0), try b.primitive(d.assessments, .sequence, &.{}, 0) } } }));
    return cache.finish(b, .{ .function = function, .types = d });
}
fn selectionFunction(b: *source.Builder, function: Id, input: Id, output: Id, allowed: []const Id) source.Error!void {
    if (function >= b.functions.items.len) return error.InvalidReference;
    const f = b.functions.items[@intCast(function)];
    if (f.parameters.len != 1 or f.result != output) return error.TypeMismatch;
    if (f.parameters[0] >= b.variables.items.len) return error.InvalidReference;
    if (b.variables.items[@intCast(f.parameters[0])] != input) return error.TypeMismatch;
    for (f.effects) |effect| if (@import("std").mem.indexOfScalar(Id, allowed, effect) == null) return error.InvalidEffect;
}
