//! Consequence-sensitive decisions emitted as ordinary Horos computations.
//! The application owns the proposal boundary and the completeness of its key.
//! This module owns coverage, exact-key grouping, and offered-choice selection.
const std = @import("std");
const source = @import("horos").source;
const typed = @import("horos").authoring;
const deliberation = @import("deliberation.zig");
const equality = @import("value_equality.zig");
const interaction = @import("interaction.zig");
const Id = source.Id;
const Builder = source.Builder;
pub const Error = equality.Error || interaction.Error || error{InvalidClarificationDomain};

/// Finite IDs are the authored decision dimension, never model confidence.
/// Hypothesis meaning is application code/data keyed by these stable IDs.
pub const Domain = union(enum) { finite: []const u64, open };

pub const Types = struct {
    candidate: Id,
    key: Id,
    known: Id,
    /// Known(candidate, key) | Unavailable | Rejected | Inconclusive.
    assessed: Id,
    /// (program-supplied hypothesis ID, assessed).
    evaluation: Id,
    evaluations: Id,
    ids: Id,
    /// (offered ID = minimum member ID, representative known, member IDs).
    group: Id,
    groups: Id,
    /// (reason: different=0, mandatory=1, open=2, groups).
    choice: Id,
    /// Common(group) | NeedsChoice(choice) | Unresolved(evaluations).
    classification: Id,
    /// Incomplete(evaluations) | Other | NotSure | Unoffered.
    non_action: Id,
    /// Common(group) | Selected(group) | Unresolved | TurnAborted | Closed.
    resolution: Id,
    /// Select(offered ID) | Other | NotSure. This is not approval.
    input: Id,
};

pub const Spec = struct {
    identity: []const u8,
    candidate: Id,
    key: Id,
    domain: Domain,
    failure: Id,
    scope: deliberation.Scope = .{},
};

pub const Definition = struct {
    types: Types,
    failure: Id,
    multi: deliberation.Deliberation,
    /// Pure (evaluations, mandatory_clarification) -> classification.
    classify: Id,
    /// Pure (groups, offered_id) -> Selected(group) | Unresolved.
    select: Id,
};

/// Work is bounded by the finite runtime input length: quadratic scans and
/// structural key comparisons. Storage retains only ordinary results/groups.
/// Missing, duplicate, invalid, or non-Known entries never enter grouping.
pub fn define(b: *Builder, spec: Spec) Error!Definition {
    if (spec.domain == .finite) {
        const ids = spec.domain.finite;
        if (ids.len == 0) return error.InvalidClarificationDomain;
        for (ids, 0..) |id, i| {
            if (std.mem.indexOfScalar(u64, ids[0..i], id) != null)
                return error.InvalidClarificationDomain;
        }
    }
    // Also rejects internal types nested in externally presented candidates.
    try equality.checkPortableSchema(b, spec.candidate);
    _ = try b.failureLiteral(spec.failure);
    try equality.checkPortableSchema(b, spec.key);
    const cached = try b.specialization(Definition, "agent.clarification/v1", .{spec});
    if (cached.cached) |present| return present;
    const t = try schemas(b, spec.candidate, spec.key);
    const e = Emit{ .b = b, .t = t, .failure = spec.failure };
    const contains = try containsId(e);
    const valid = try validateEvaluations(e, spec.domain, contains);
    const insert = insertGroup(e, spec.key) catch |err| return switch (err) {
        error.UnsupportedEqualitySchema => error.UnsupportedEqualitySchema,
        else => typed.sourceError(@errorCast(err)),
    };
    const group = try groupEvaluations(e, insert);
    const classified = try classifier(e, spec.domain, valid, group);
    const multi = try deliberation.define(
        b,
        spec.identity,
        try b.scalar(u64),
        t.evaluation,
        spec.scope,
    );
    return cached.finish(b, .{
        .types = t,
        .failure = spec.failure,
        .multi = multi,
        .classify = classified,
        .select = try selector(e),
    });
}

fn schemas(b: *Builder, candidate: Id, key: Id) Error!Types {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const ids = try b.schema(.{ .seq = integer });
    const known = try b.schema(.{ .product = &.{ candidate, key } });
    const assessed = try b.schema(.{ .sum = &.{ known, unit, unit, unit } });
    const evaluation = try b.schema(.{ .product = &.{ integer, assessed } });
    const group = try b.schema(.{ .product = &.{ integer, known, ids } });
    const groups = try b.schema(.{ .seq = group });
    const choice = try b.schema(.{ .product = &.{ try b.scalar(u8), groups } });
    const evaluations = try b.schema(.{ .seq = evaluation });
    const non_action = try b.schema(.{ .sum = &.{ evaluations, unit, unit, unit } });
    return .{
        .candidate = candidate,
        .key = key,
        .known = known,
        .assessed = assessed,
        .evaluation = evaluation,
        .evaluations = evaluations,
        .ids = ids,
        .group = group,
        .groups = groups,
        .choice = choice,
        .classification = try b.schema(.{ .sum = &.{ group, choice, evaluations } }),
        .non_action = non_action,
        .resolution = try b.schema(.{ .sum = &.{ group, group, non_action, unit, unit } }),
        .input = try b.schema(.{ .sum = &.{ integer, unit, unit } }),
    };
}

/// The actual installed body must be a computation value with first parameter
/// multi.capability and result types.evaluation. It chooses the interpretation
/// before producing/checking its proposal. Registration inspects its transitive
/// code and capture graph; metadata is not an admission bypass.
pub fn explore(
    c: anytype,
    d: Definition,
    body: Id,
    arguments: []const Id,
    mandatory: Id,
) !Id {
    const b = c.builder;
    if (body >= b.values.items.len) return error.InvalidReference;
    const function = switch (b.values.items[body].expression) {
        .lambda => |f| f,
        else => return error.TypeMismatch,
    };
    const allowed = b.handlers.items[d.multi.handler].effects;
    for (allowed) |effect| {
        var admitted = false;
        for (c.registry.classifications.items) |classification| {
            if (classification.effect != effect) continue;
            admitted = classification.role == .model or
                (!b.effects.items[effect].external and
                    (classification.role == .simulation or classification.role == .internal));
        }
        if (!admitted) return error.SpeculativeEffect;
    }
    try deliberation.register(c, d.multi, function, allowed);
    const evaluations = try b.variable(d.types.evaluations);
    return b.bind(evaluations, try deliberation.evaluate(b, d.multi, body, arguments), try call(b, d.classify, &.{ try b.reference(evaluations), mandatory }));
}

/// A pure application presenter (context, choice) -> outgoing builds the exact
/// consequence distinction. The waiting continuation retains context and groups.
/// Only this question's offered IDs select a proposal; Other/NotSure do not.
pub const Presentation = struct {
    context: Id,
    present: Id,
    exchange: interaction.Definition,
    channel: Id,
    purpose: Id,
    presentation: Id,
};

pub fn resolver(b: *Builder, d: Definition, p: Presentation) Error!Id {
    const unit = try b.scalar(void);
    const contract = p.exchange.contract;
    if (contract.input != d.types.input or contract.abort_turn != unit or
        contract.close_conversation != unit) return error.InvalidInteractionContract;
    try checkPure(b, p.present, &.{ p.context, d.types.choice }, contract.outgoing);
    // Checking complete portable schemas also catches context/resource leaks.
    const failure = d.failure;
    try equality.checkPortableSchema(b, p.context);
    _ = try b.failureLiteral(failure);
    try equality.checkPortableSchema(b, contract.outgoing);
    const f = try b.declare(&.{ p.context, d.types.classification }, d.types.resolution, &.{p.exchange.effect}, &.{});
    const common = try b.variable(d.types.group);
    const choice = try b.variable(d.types.choice);
    const unresolved = try b.variable(d.types.evaluations);
    const e = Emit{ .b = b, .t = d.types, .failure = failure };
    try b.define(f, try b.term(.{ .match_sum = .{
        .value = try b.reference(b.parameter(f, 1)),
        .cases = &.{
            .{ .variable = common, .body = try e.returnVariant(
                d.types.resolution,
                try b.reference(common),
                0,
            ) },
            .{ .variable = choice, .body = try ask(e, d, p, try b.reference(b.parameter(f, 0)), try b.reference(choice)) },
            .{ .variable = unresolved, .body = try e.nonAction(try b.reference(unresolved), 0) },
        },
    } }));
    return f;
}

fn ask(e: Emit, d: Definition, p: Presentation, context: Id, choice: Id) Error!Id {
    const b = e.b;
    const outgoing = try b.variable(p.exchange.contract.outgoing);
    const response = try b.variable(p.exchange.reply);
    const input = try b.variable(e.t.input);
    const abort = try b.variable(try b.scalar(void));
    const close = try b.variable(try b.scalar(void));
    const reply = try b.term(.{ .match_sum = .{
        .value = try b.reference(response),
        .cases = &.{
            .{ .variable = input, .body = try inputReply(e, d, try e.field(e.t.groups, choice, 1), try b.reference(input)) },
            .{ .variable = abort, .body = try e.returnVariant(e.t.resolution, try b.constant(void, {}), 3) },
            .{ .variable = close, .body = try e.returnVariant(e.t.resolution, try b.constant(void, {}), 4) },
        },
    } });
    const exchange = try interaction.exchange(b, p.exchange, .{
        .channel = p.channel,
        .purpose = p.purpose,
        .presentation = p.presentation,
        .outgoing = try b.reference(outgoing),
    });
    return b.bind(outgoing, try call(b, p.present, &.{ context, choice }), try b.bind(response, exchange, reply));
}

fn inputReply(e: Emit, d: Definition, groups: Id, input: Id) Error!Id {
    const b = e.b;
    const selected = try b.variable(try b.scalar(u64));
    const other = try b.variable(try b.scalar(void));
    const unsure = try b.variable(try b.scalar(void));
    return b.term(.{ .match_sum = .{ .value = input, .cases = &.{
        .{ .variable = selected, .body = try call(b, d.select, &.{ groups, try b.reference(selected) }) },
        .{ .variable = other, .body = try e.nonAction(try b.constant(void, {}), 1) },
        .{ .variable = unsure, .body = try e.nonAction(try b.constant(void, {}), 2) },
    } } });
}

fn containsId(e: Emit) Error!Id {
    const b = e.b;
    const integer = try b.scalar(u64);
    const f = try b.declare(&.{ e.t.ids, integer }, try b.scalar(bool), &.{}, &.{});
    const ids = try b.reference(b.parameter(f, 0));
    const wanted = try b.reference(b.parameter(f, 1));
    const pop = try Pop.init(b, e.t.ids, integer);
    const next = try call(b, f, &.{ try b.reference(pop.rest), wanted });
    const found = try e.conditional(try e.equal(try b.reference(pop.head), wanted), try b.pure(try b.constant(bool, true)), next);
    try b.define(f, try pop.match(b, ids, try b.pure(try b.constant(bool, false)), found));
    return f;
}

fn validateEvaluations(e: Emit, domain: Domain, contains: Id) Error!Id {
    const b = e.b;
    const boolean = try b.scalar(bool);
    const integer = try b.scalar(u64);
    const f = try b.declare(&.{ e.t.evaluations, e.t.ids }, boolean, &.{}, &.{});
    const remaining = try b.reference(b.parameter(f, 0));
    const seen = try b.reference(b.parameter(f, 1));
    const pop = try Pop.init(b, e.t.evaluations, e.t.evaluation);
    const item = try b.reference(pop.head);
    const id = try e.field(integer, item, 0);
    const assessed = try e.field(e.t.assessed, item, 1);
    const duplicate = try b.variable(boolean);
    const no = try b.pure(try b.constant(bool, false));
    const appended = try e.concat(e.t.ids, seen, try e.sequence(e.t.ids, &.{id}));
    var admitted = try e.conditional(try e.equal(
        try b.primitive(integer, .variant_tag, &.{assessed}, 0),
        try b.constant(u64, 0),
    ), try call(b, f, &.{ try b.reference(pop.rest), appended }), no);
    if (domain == .finite) {
        var member = no;
        for (domain.finite) |required| member = try e.conditional(
            try e.equal(id, try b.constant(u64, required)),
            admitted,
            member,
        );
        admitted = member;
    }
    const checked = try b.bind(duplicate, try call(b, contains, &.{ seen, id }), try e.conditional(try b.reference(duplicate), no, admitted));
    try b.define(f, try pop.match(b, remaining, try b.pure(try b.constant(bool, true)), checked));
    return f;
}

fn classifier(e: Emit, domain: Domain, valid: Id, group: Id) Error!Id {
    const b = e.b;
    const boolean = try b.scalar(bool);
    const f = try b.declare(&.{ e.t.evaluations, boolean }, e.t.classification, &.{}, &.{});
    const evaluations = try b.reference(b.parameter(f, 0));
    const mandatory = try b.reference(b.parameter(f, 1));
    const checked = try b.variable(boolean);
    const grouped = try b.variable(e.t.groups);
    const no = try e.returnVariant(e.t.classification, evaluations, 2);
    const grouped_value = try b.reference(grouped);
    const choice_kind = if (domain == .open) try b.constant(u8, 2) else try b.primitive(try b.scalar(u8), .select, &.{
        mandatory, try b.constant(u8, 1), try b.constant(u8, 0),
    }, 0);
    const question = try e.returnVariant(e.t.classification, try e.product(e.t.choice, &.{ choice_kind, grouped_value }), 1);
    const pop = try Pop.init(b, e.t.groups, e.t.group);
    const common = try pop.match(b, grouped_value, no, try e.returnVariant(e.t.classification, try b.reference(pop.head), 0));
    const one = try e.equal(try e.length(grouped_value), try b.constant(u64, 1));
    const decision = if (domain == .open) question else try e.conditional(mandatory, question, try e.conditional(one, common, question));
    const grouped_term = try b.bind(grouped, try call(b, group, &.{
        evaluations, try e.sequence(e.t.groups, &.{}), mandatory,
    }), decision);
    var body = try b.bind(checked, try call(b, valid, &.{
        evaluations, try e.sequence(e.t.ids, &.{}),
    }), try e.conditional(try b.reference(checked), grouped_term, no));
    const length = try e.length(evaluations);
    if (domain == .finite) body = try e.conditional(
        try e.equal(length, try b.constant(u64, domain.finite.len)),
        body,
        no,
    );
    body = try e.conditional(try e.equal(length, try b.constant(u64, 0)), no, body);
    try b.define(f, body);
    return f;
}

fn groupEvaluations(e: Emit, insert: Id) Error!Id {
    const b = e.b;
    const boolean = try b.scalar(bool);
    const f = try b.declare(&.{ e.t.evaluations, e.t.groups, boolean }, e.t.groups, &.{}, &.{});
    const remaining = try b.reference(b.parameter(f, 0));
    const groups = try b.reference(b.parameter(f, 1));
    const mandatory = try b.reference(b.parameter(f, 2));
    const pop = try Pop.init(b, e.t.evaluations, e.t.evaluation);
    const updated = try b.variable(e.t.groups);
    const id = try e.field(try b.scalar(u64), try b.reference(pop.head), 0);
    const known = try e.payload(e.t.known, try e.field(e.t.assessed, try b.reference(pop.head), 1), 0);
    const single = try e.product(e.t.group, &.{
        id, known, try e.sequence(e.t.ids, &.{id}),
    });
    const add = try e.conditional(mandatory, try b.pure(try e.concat(e.t.groups, groups, try e.sequence(e.t.groups, &.{single}))), try call(b, insert, &.{ groups, single }));
    const next = try b.bind(updated, add, try call(b, f, &.{
        try b.reference(pop.rest), try b.reference(updated), mandatory,
    }));
    try b.define(f, try pop.match(b, remaining, try b.pure(groups), next));
    return f;
}

fn insertGroup(e: Emit, key: Id) equality.TypedError!Id {
    const c = try typed.Context.init(e.b);
    const group = try typed.interop.schema(c, e.t.group);
    const groups = try typed.interop.schema(c, e.t.groups);
    const fault = try typed.interop.literalFailure(c, e.failure, try typed.interop.schema(c, e.b.values.items[@intCast(e.failure)].schema));
    const equal = try equality.create(c, try typed.interop.schema(c, key), fault);
    const f = try c.function("group exact clarification keys", &.{ .{ .name = "groups", .schema = groups }, .{ .name = "added", .schema = group } }, groups, &.{});
    const body = try c.body(f);
    const added = try body.parameter("added");
    const popped = try body.pop(try body.parameter("groups"));
    const empty = try body.caseOf(popped, "empty");
    const item = try body.caseOf(popped, "item");
    const work = item.body();
    const old = try work.field(item.payload(), "head");
    const tail = try work.field(item.payload(), "tail");
    const same = try work.call(equal, &.{
        .{ .name = "left", .value = try work.field(try work.field(old, "1"), "1") },
        .{ .name = "right", .value = try work.field(try work.field(added, "1"), "1") },
    });
    const yes = try work.branch();
    const no = try work.branch();
    const earlier = try yes.less(try yes.field(added, "0"), try yes.field(old, "0"));
    const representative = try yes.select(earlier, added, old);
    const merged = try yes.product(group, &.{
        .{ .name = "0", .value = try yes.field(representative, "0") },
        .{ .name = "1", .value = try yes.field(representative, "1") },
        .{ .name = "2", .value = try yes.concat(try yes.field(old, "2"), try yes.field(added, "2")) },
    });
    const combined = try yes.concat(try yes.sequenceValue(groups, &.{merged}), tail);
    const rest = try no.call(f, &.{ .{ .name = "groups", .value = tail }, .{ .name = "added", .value = added } });
    const retained = try no.concat(try no.sequenceValue(groups, &.{old}), rest);
    const selected = try work.conditional(same, try yes.ret(combined), try no.ret(retained));
    try c.define(f, try body.ret(try body.match(popped, &.{
        try empty.ret(try empty.body().sequenceValue(groups, &.{added})), try item.ret(selected),
    })));
    return typed.interop.functionId(c, f);
}

fn selector(e: Emit) Error!Id {
    const b = e.b;
    const integer = try b.scalar(u64);
    const f = try b.declare(&.{ e.t.groups, integer }, e.t.resolution, &.{}, &.{});
    const groups = try b.reference(b.parameter(f, 0));
    const offered = try b.reference(b.parameter(f, 1));
    const pop = try Pop.init(b, e.t.groups, e.t.group);
    const group = try b.reference(pop.head);
    const found = try e.conditional(try e.equal(try e.field(integer, group, 0), offered), try e.returnVariant(e.t.resolution, group, 1), try call(b, f, &.{ try b.reference(pop.rest), offered }));
    const unoffered = try e.nonAction(try b.constant(void, {}), 3);
    try b.define(f, try pop.match(b, groups, unoffered, found));
    return f;
}

fn checkPure(b: *Builder, id: Id, parameters: []const Id, result: Id) Error!void {
    if (id >= b.functions.items.len) return error.InvalidReference;
    const f = b.functions.items[id];
    if (f.result != result or f.parameters.len != parameters.len) return error.TypeMismatch;
    if (f.effects.len != 0 or f.regions.len != 0) return error.InvalidEffect;
    for (f.parameters, parameters) |variable, schema| {
        if (b.variables.items[variable] != schema) return error.TypeMismatch;
    }
}

const Pop = struct {
    optional: Id,
    absent: Id,
    present: Id,
    head: Id,
    rest: Id,

    fn init(b: *Builder, sequence: Id, element: Id) Error!Pop {
        const pair = try b.schema(.{ .product = &.{ element, sequence } });
        const unit = try b.scalar(void);
        return .{
            .optional = try b.schema(.{ .sum = &.{ unit, pair } }),
            .absent = try b.variable(unit),
            .present = try b.variable(pair),
            .head = try b.variable(element),
            .rest = try b.variable(sequence),
        };
    }

    fn match(p: Pop, b: *Builder, value: Id, empty: Id, found: Id) Error!Id {
        const unpack = try b.term(.{ .unpack_product = .{
            .value = try b.reference(p.present),
            .variables = &.{ p.head, p.rest },
            .body = found,
        } });
        return b.term(.{ .match_sum = .{
            .value = try b.primitive(p.optional, .sequence_pop, &.{value}, 0),
            .cases = &.{
                .{ .variable = p.absent, .body = empty },
                .{ .variable = p.present, .body = unpack },
            },
        } });
    }
};

const Emit = struct {
    b: *Builder,
    t: Types,
    failure: Id,

    fn field(e: Emit, schema: Id, value: Id, index: u64) Error!Id {
        return e.b.primitive(schema, .field, &.{value}, index);
    }
    fn product(e: Emit, schema: Id, values: []const Id) Error!Id {
        return e.b.primitive(schema, .product, values, 0);
    }
    fn sequence(e: Emit, schema: Id, values: []const Id) Error!Id {
        return e.b.primitive(schema, .sequence, values, 0);
    }
    fn concat(e: Emit, schema: Id, left: Id, right: Id) Error!Id {
        return e.b.primitive(schema, .sequence_concat, &.{ left, right }, 0);
    }
    fn length(e: Emit, value: Id) Error!Id {
        return e.b.primitive(try e.b.scalar(u64), .sequence_length, &.{value}, 0);
    }
    fn equal(e: Emit, left: Id, right: Id) Error!Id {
        return e.b.primitive(try e.b.scalar(bool), .equal, &.{ left, right }, 0);
    }
    fn conditional(e: Emit, condition: Id, yes: Id, no: Id) Error!Id {
        return e.b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = yes,
            .when_false = no,
        } });
    }
    fn returnVariant(e: Emit, schema: Id, value: Id, tag: u64) Error!Id {
        return e.b.pure(try e.b.primitive(schema, .variant, &.{value}, tag));
    }
    fn nonAction(e: Emit, value: Id, tag: u64) Error!Id {
        const reason = try e.b.primitive(e.t.non_action, .variant, &.{value}, tag);
        return e.returnVariant(e.t.resolution, reason, 2);
    }
    fn payload(e: Emit, schema: Id, value: Id, tag: u64) Error!Id {
        return e.b.value(.{ .schema = schema, .expression = .{ .primitive = .{
            .opcode = .variant_payload,
            .operands = &.{value},
            .immediate = tag,
            .failures = &.{.{
                .kind = .invalid_variant,
                .value = try e.b.failureLiteral(e.failure),
            }},
        } } });
    }
};

fn call(b: *Builder, function: Id, arguments: []const Id) Error!Id {
    return b.term(.{ .call = .{ .function = function, .arguments = arguments } });
}

test "domain and portable projection declarations reject before authoring control" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    var spec = Spec{
        .identity = "clarification.contract-test",
        .candidate = integer,
        .key = integer,
        .domain = .{ .finite = &.{} },
        .failure = try b.constant(void, {}),
    };
    try std.testing.expectError(error.InvalidClarificationDomain, define(&b, spec));
    spec.domain = .{ .finite = &.{ 1, 1 } };
    try std.testing.expectError(error.InvalidClarificationDomain, define(&b, spec));
    spec.domain = .{ .finite = &.{ 1, 2 } };
    const cell = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = b.region(),
    } } });
    spec.key = try b.schema(.{ .product = &.{ integer, cell } });
    try std.testing.expectError(error.UnsupportedEqualitySchema, define(&b, spec));
    spec.key = integer;
    spec.candidate = cell;
    try std.testing.expectError(error.UnsupportedEqualitySchema, define(&b, spec));
    spec.candidate = integer;
    const d = try define(&b, spec);
    const declarations = b.functions.items.len;
    try std.testing.expectEqual(d.classify, (try define(&b, spec)).classify);
    try std.testing.expectEqual(declarations, b.functions.items.len);
    var compiled = try @import("horos").program.compile(
        std.testing.allocator,
        b.module(d.classify, try b.scalar(void)),
    );
    defer compiled.deinit();
}

test "presenter requires the exact pure signature and portable context" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const d = try define(&b, .{
        .identity = "clarification.presentation-test",
        .candidate = integer,
        .key = integer,
        .domain = .{ .finite = &.{ 1, 2 } },
        .failure = try b.constant(void, {}),
    });
    const exchange = try interaction.define(&b, .{
        .name = "clarification.presentation-test",
        .channel = unit,
        .purpose = unit,
        .presentation = unit,
        .outgoing = d.types.choice,
        .input = d.types.input,
        .abort_turn = unit,
        .close_conversation = unit,
    });
    const present = try b.declare(&.{ integer, d.types.choice }, d.types.choice, &.{}, &.{});
    try b.define(present, try b.pure(try b.reference(b.parameter(present, 1))));
    const nothing = try b.constant(void, {});
    var p = Presentation{
        .context = integer,
        .present = present,
        .exchange = exchange,
        .channel = nothing,
        .purpose = nothing,
        .presentation = nothing,
    };
    const resolve = try resolver(&b, d, p);
    var compiled = try @import("horos").program.compile(
        std.testing.allocator,
        b.module(resolve, unit),
    );
    defer compiled.deinit();
    p.present = try b.declare(&.{ integer, d.types.choice }, d.types.choice, &.{exchange.effect}, &.{});
    try std.testing.expectError(error.InvalidEffect, resolver(&b, d, p));
    p.present = try b.declare(&.{integer}, d.types.choice, &.{}, &.{});
    try std.testing.expectError(error.TypeMismatch, resolver(&b, d, p));
}

test "clarification excludes live and human effects even when explicitly listed" {
    const admission = @import("admission.zig");
    for ([_]admission.Role{
        .read, .write, .commit, .approval, .interaction, .internal, .simulation,
    }) |role| {
        var b = Builder.init(std.testing.allocator);
        defer b.deinit();
        var registry = admission.Registry.init(b.allocator());
        defer registry.deinit();
        const c = @import("authoring.zig").Context{ .builder = &b, .registry = &registry };
        const integer = try b.scalar(u64);
        const effect = try c.external("test.clarification.forbidden", integer, integer, role);
        const d = try define(&b, .{
            .identity = "test.clarification.forbidden-multi",
            .candidate = integer,
            .key = integer,
            .domain = .{ .finite = &.{ 1, 2 } },
            .failure = try b.constant(void, {}),
            .scope = .{ .residual = .{ .effects = &.{effect} } },
        });
        const body = try b.declare(&.{d.multi.capability}, d.types.evaluation, &.{ d.multi.effect, effect }, &.{});
        try b.define(body, try b.term(.{ .fail = d.failure }));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{d.multi.capability},
            .result = d.types.evaluation,
            .effects = &.{ d.multi.effect, effect },
        } } });
        try std.testing.expectError(error.SpeculativeEffect, explore(c, d, try b.lambda(body, body_type), &.{}, try b.constant(bool, false)));
    }
}
