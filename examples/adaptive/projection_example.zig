const std = @import("std");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const native = @import("protean_native");
const wc = contracts.workspace;
const Id = horos.source.Id;

pub const Domain = struct {
    identity: u64,
    revision: u64,
    known: bool,
    members: contracts.Vector(u64, null),
};
pub const Visit = struct {
    domain_identity: u64,
    domain_revision: u64,
    member: u64,
    available: bool,
    observed: u64,
    evidence: wc.Ref,
};
pub const ScanEvidence = struct { domain: Domain, visits: contracts.Vector(Visit, null) };
pub const BadOutcome = struct { no_counterexample_observed: bool };
pub const IncompleteReason = enum {
    unknown_domain,
    ambiguous_domain,
    invalid_evidence,
    missing_or_failed_coverage,
};
pub const Incomplete = struct { reason: IncompleteReason, evidence: ScanEvidence };
pub const ScanOutcome = union(enum) {
    counterexample: Visit,
    exhausted_declared_domain: ScanEvidence,
    incomplete: Incomplete,
};
pub const ComparisonInput = struct {
    left: wc.ProjectionResult(BadOutcome),
    right: wc.ProjectionResult(BadOutcome),
    left_evidence: ScanEvidence,
    right_evidence: ScanEvidence,
};
pub const Comparison = struct {
    equal_projected_payload: bool,
    distinct_required_outcomes: bool,
    left: ScanOutcome,
    right: ScanOutcome,
};
pub const Program = enum { producer, bad_projector, repaired_projector, comparison };
const VisitSummary = union(enum) { clear: bool, counterexample: Visit };

pub fn source(a: std.mem.Allocator, program: Program) ![]u8 {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    var generator: Generator = .{ .b = &builder };
    const entry = if (program == .producer) try generator.producer() else blk: {
        try generator.defineScans();
        break :blk switch (program) {
            .producer => unreachable,
            .bad_projector => try generator.projector(false),
            .repaired_projector => try generator.projector(true),
            .comparison => try generator.comparison(),
        };
    };
    return native.source_records.encode(a, builder.module(entry, try builder.scalar(void)));
}

const Generator = struct {
    b: *horos.source.Builder,
    contains: Id = undefined,
    successful: Id = undefined,
    unique: Id = undefined,
    covered: Id = undefined,
    visits: Id = undefined,
    outcome: Id = undefined,

    fn schema(g: Generator, comptime T: type) !Id {
        return contracts.schema(T, g.b);
    }
    fn parameter(g: Generator, function: Id, index: usize) !Id {
        return g.b.reference(g.b.parameter(function, index));
    }
    fn field(g: Generator, comptime T: type, value: Id, index: u64) !Id {
        return g.b.primitive(try g.schema(T), .field, &.{value}, index);
    }
    fn product(g: Generator, comptime T: type, operands: []const Id) !Id {
        return g.b.primitive(try g.schema(T), .product, operands, 0);
    }
    fn variant(g: Generator, comptime T: type, tag: u64, payload: Id) !Id {
        return g.b.primitive(try g.schema(T), .variant, &.{payload}, tag);
    }
    fn equal(g: Generator, left: Id, right: Id) !Id {
        return g.b.primitive(try g.schema(bool), .equal, &.{ left, right }, 0);
    }
    fn both(g: Generator, left: Id, right: Id) !Id {
        return g.b.primitive(try g.schema(bool), .select, &.{
            left, right, try g.b.constant(bool, false),
        }, 0);
    }
    fn not(g: Generator, value: Id) !Id {
        return g.b.primitive(try g.schema(bool), .boolean_not, &.{value}, 0);
    }
    fn literal(g: Generator, comptime T: type, value: T) !Id {
        return g.b.literal(.{
            .schema = try g.schema(T),
            .bytes = try contracts.encodeOwned(T, g.b.allocator(), value),
        });
    }
    fn call(g: Generator, function: Id, arguments: []const Id) !Id {
        return g.b.term(.{ .call = .{ .function = function, .arguments = arguments } });
    }
    fn choose(g: Generator, condition: Id, yes: Id, no: Id) !Id {
        return g.b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = yes,
            .when_false = no,
        } });
    }
    fn increment(g: Generator, index: Id) !Id {
        return g.b.value(.{ .schema = try g.schema(u64), .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ index, try g.b.constant(u64, 1) },
            .failures = &.{.{
                .kind = .arithmetic_overflow,
                .value = try g.b.failureLiteral(try g.b.constant(void, {})),
            }},
        } } });
    }
    fn get(g: Generator, comptime T: type, items: Id, index: Id) !Id {
        return g.b.primitive(try g.schema(?T), .sequence_get, &.{ items, index }, 0);
    }
    fn optional(g: Generator, value: Id, present: Id, yes: Id, no: Id) !Id {
        return g.b.term(.{ .match_sum = .{ .value = value, .cases = &.{
            .{ .variable = try g.b.variable(try g.schema(void)), .body = no },
            .{ .variable = present, .body = yes },
        } } });
    }

    fn producer(g: Generator) !Id {
        const evidence = try g.schema(ScanEvidence);
        const entry = try g.b.declare(&.{evidence}, evidence, &.{}, &.{});
        try g.b.define(entry, try g.b.pure(try g.parameter(entry, 0)));
        return entry;
    }

    fn defineScans(g: *Generator) !void {
        const evidence = try g.schema(ScanEvidence);
        const integer = try g.schema(u64);
        const boolean = try g.schema(bool);
        g.contains = try g.b.declare(&.{
            try g.schema(contracts.Vector(u64, null)), integer, integer,
        }, boolean, &.{}, &.{});
        g.successful = try g.b.declare(&.{ evidence, integer, integer }, boolean, &.{}, &.{});
        g.unique = try g.b.declare(&.{ evidence, integer }, boolean, &.{}, &.{});
        g.covered = try g.b.declare(&.{ evidence, integer }, boolean, &.{}, &.{});
        g.visits = try g.b.declare(
            &.{ evidence, integer, boolean },
            try g.schema(VisitSummary),
            &.{},
            &.{},
        );
        g.outcome = try g.b.declare(&.{evidence}, try g.schema(ScanOutcome), &.{}, &.{});
        try g.defineContains();
        try g.defineSuccessful();
        try g.defineMembers(true);
        try g.defineMembers(false);
        try g.defineVisits();
        try g.defineOutcome();
    }

    fn defineContains(g: Generator) !void {
        const items = try g.parameter(g.contains, 0);
        const index = try g.parameter(g.contains, 1);
        const wanted = try g.parameter(g.contains, 2);
        const item = try g.b.variable(try g.schema(u64));
        const found = try g.choose(
            try g.equal(try g.b.reference(item), wanted),
            try g.b.pure(try g.b.constant(bool, true)),
            try g.call(g.contains, &.{ items, try g.increment(index), wanted }),
        );
        try g.b.define(g.contains, try g.optional(
            try g.get(u64, items, index),
            item,
            found,
            try g.b.pure(try g.b.constant(bool, false)),
        ));
    }

    fn matchingVisit(g: Generator, evidence: Id, visit: Id) !Id {
        const domain = try g.field(Domain, evidence, 0);
        return g.both(
            try g.equal(try g.field(u64, domain, 0), try g.field(u64, visit, 0)),
            try g.equal(try g.field(u64, domain, 1), try g.field(u64, visit, 1)),
        );
    }

    fn defineSuccessful(g: Generator) !void {
        const evidence = try g.parameter(g.successful, 0);
        const member = try g.parameter(g.successful, 1);
        const index = try g.parameter(g.successful, 2);
        const items = try g.field(contracts.Vector(Visit, null), evidence, 1);
        const item = try g.b.variable(try g.schema(Visit));
        const visit = try g.b.reference(item);
        const matching = try g.both(try g.matchingVisit(evidence, visit), try g.both(
            try g.field(bool, visit, 3),
            try g.both(
                try g.equal(member, try g.field(u64, visit, 2)),
                try g.equal(member, try g.field(u64, visit, 4)),
            ),
        ));
        const found = try g.choose(
            matching,
            try g.b.pure(try g.b.constant(bool, true)),
            try g.call(g.successful, &.{ evidence, member, try g.increment(index) }),
        );
        try g.b.define(g.successful, try g.optional(
            try g.get(Visit, items, index),
            item,
            found,
            try g.b.pure(try g.b.constant(bool, false)),
        ));
    }

    fn defineMembers(g: Generator, unique: bool) !void {
        const function = if (unique) g.unique else g.covered;
        const evidence = try g.parameter(function, 0);
        const index = try g.parameter(function, 1);
        const domain = try g.field(Domain, evidence, 0);
        const items = try g.field(contracts.Vector(u64, null), domain, 3);
        const item = try g.b.variable(try g.schema(u64));
        const checked = try g.b.variable(try g.schema(bool));
        const next = try g.increment(index);
        const check = if (unique)
            try g.call(g.contains, &.{ items, next, try g.b.reference(item) })
        else
            try g.call(g.successful, &.{
                evidence, try g.b.reference(item), try g.b.constant(u64, 0),
            });
        const passed = if (unique)
            try g.not(try g.b.reference(checked))
        else
            try g.b.reference(checked);
        const present = try g.b.bind(checked, check, try g.choose(
            passed,
            try g.call(function, &.{ evidence, next }),
            try g.b.pure(try g.b.constant(bool, false)),
        ));
        try g.b.define(function, try g.optional(
            try g.get(u64, items, index),
            item,
            present,
            try g.b.pure(try g.b.constant(bool, true)),
        ));
    }

    fn defineVisits(g: Generator) !void {
        const evidence = try g.parameter(g.visits, 0);
        const index = try g.parameter(g.visits, 1);
        const invalid = try g.parameter(g.visits, 2);
        const items = try g.field(contracts.Vector(Visit, null), evidence, 1);
        const item = try g.b.variable(try g.schema(Visit));
        const visit = try g.b.reference(item);
        const member = try g.b.variable(try g.schema(bool));
        const domain = try g.field(Domain, evidence, 0);
        const membership = try g.call(g.contains, &.{
            try g.field(contracts.Vector(u64, null), domain, 3),
            try g.b.constant(u64, 0),
            try g.field(u64, visit, 2),
        });
        const valid = try g.both(try g.matchingVisit(evidence, visit), try g.b.reference(member));
        const violated = try g.both(
            try g.field(bool, visit, 3),
            try g.not(try g.equal(try g.field(u64, visit, 2), try g.field(u64, visit, 4))),
        );
        const next = try g.increment(index);
        const accepted = try g.choose(
            violated,
            try g.b.pure(try g.variant(VisitSummary, 1, visit)),
            try g.call(g.visits, &.{ evidence, next, invalid }),
        );
        const present = try g.b.bind(member, membership, try g.choose(
            valid,
            accepted,
            try g.call(g.visits, &.{ evidence, next, try g.b.constant(bool, true) }),
        ));
        try g.b.define(g.visits, try g.optional(
            try g.get(Visit, items, index),
            item,
            present,
            try g.b.pure(try g.variant(VisitSummary, 0, invalid)),
        ));
    }

    fn incomplete(g: Generator, evidence: Id, reason: IncompleteReason) !Id {
        return g.b.pure(try g.variant(ScanOutcome, 2, try g.product(Incomplete, &.{
            try g.literal(IncompleteReason, reason), evidence,
        })));
    }

    fn finishCoverage(g: Generator, evidence: Id) !Id {
        const covered = try g.b.variable(try g.schema(bool));
        return g.b.bind(
            covered,
            try g.call(g.covered, &.{ evidence, try g.b.constant(u64, 0) }),
            try g.choose(
                try g.b.reference(covered),
                try g.b.pure(try g.variant(ScanOutcome, 1, evidence)),
                try g.incomplete(evidence, .missing_or_failed_coverage),
            ),
        );
    }

    fn checkedOutcome(g: Generator, evidence: Id) !Id {
        const summary = try g.b.variable(try g.schema(VisitSummary));
        const invalid = try g.b.variable(try g.schema(bool));
        const witness = try g.b.variable(try g.schema(Visit));
        const classified = try g.b.term(.{ .match_sum = .{
            .value = try g.b.reference(summary),
            .cases = &.{
                .{ .variable = invalid, .body = try g.choose(
                    try g.b.reference(invalid),
                    try g.incomplete(evidence, .invalid_evidence),
                    try g.finishCoverage(evidence),
                ) },
                .{ .variable = witness, .body = try g.b.pure(try g.variant(
                    ScanOutcome,
                    0,
                    try g.b.reference(witness),
                )) },
            },
        } });
        return g.b.bind(summary, try g.call(g.visits, &.{
            evidence, try g.b.constant(u64, 0), try g.b.constant(bool, false),
        }), classified);
    }

    fn defineOutcome(g: Generator) !void {
        const evidence = try g.parameter(g.outcome, 0);
        const domain = try g.field(Domain, evidence, 0);
        const unique = try g.b.variable(try g.schema(bool));
        const checked = try g.b.bind(
            unique,
            try g.call(g.unique, &.{ evidence, try g.b.constant(u64, 0) }),
            try g.choose(
                try g.b.reference(unique),
                try g.checkedOutcome(evidence),
                try g.incomplete(evidence, .ambiguous_domain),
            ),
        );
        try g.b.define(g.outcome, try g.choose(
            try g.field(bool, domain, 2),
            checked,
            try g.incomplete(evidence, .unknown_domain),
        ));
    }

    fn proposal(g: Generator, consumer: Id) !Id {
        const blocks = try g.literal(contracts.Vector(wc.PresentationBlock, null), .{
            .items = &.{.{ .computed = .{} }},
        });
        return g.product(wc.ProjectionProposal, &.{ consumer, blocks });
    }

    fn projector(g: Generator, comptime repaired: bool) !Id {
        const Payload = if (repaired) ScanOutcome else BadOutcome;
        const Input = wc.ProjectionInput(ScanEvidence);
        const Result = wc.ProjectionResult(Payload);
        const entry = try g.b.declare(&.{try g.schema(Input)}, try g.schema(Result), &.{}, &.{});
        const input = try g.parameter(entry, 0);
        const proposal_value = try g.proposal(try g.field(wc.Ref, input, 0));
        const evidence = try g.field(ScanEvidence, input, 1);
        const payload = try g.b.variable(try g.schema(Payload));
        const computation = if (repaired)
            try g.call(g.outcome, &.{evidence})
        else
            try g.badOutcome(evidence);
        try g.b.define(entry, try g.b.bind(
            payload,
            computation,
            try g.b.pure(try g.product(Result, &.{ proposal_value, try g.b.reference(payload) })),
        ));
        return entry;
    }

    fn badOutcome(g: Generator, evidence: Id) !Id {
        const summary = try g.b.variable(try g.schema(VisitSummary));
        const clear = try g.b.variable(try g.schema(bool));
        const witness = try g.b.variable(try g.schema(Visit));
        const result = try g.b.term(.{ .match_sum = .{
            .value = try g.b.reference(summary),
            .cases = &.{
                .{ .variable = clear, .body = try g.b.pure(try g.literal(
                    BadOutcome,
                    .{ .no_counterexample_observed = true },
                )) },
                .{ .variable = witness, .body = try g.b.pure(try g.literal(
                    BadOutcome,
                    .{ .no_counterexample_observed = false },
                )) },
            },
        } });
        return g.b.bind(summary, try g.call(g.visits, &.{
            evidence, try g.b.constant(u64, 0), try g.b.constant(bool, false),
        }), result);
    }

    fn comparison(g: Generator) !Id {
        const entry = try g.b.declare(
            &.{try g.schema(ComparisonInput)},
            try g.schema(Comparison),
            &.{},
            &.{},
        );
        const input = try g.parameter(entry, 0);
        const left = try g.b.variable(try g.schema(ScanOutcome));
        const right = try g.b.variable(try g.schema(ScanOutcome));
        const left_payload = try g.field(
            BadOutcome,
            try g.field(wc.ProjectionResult(BadOutcome), input, 0),
            1,
        );
        const right_payload = try g.field(
            BadOutcome,
            try g.field(wc.ProjectionResult(BadOutcome), input, 1),
            1,
        );
        const equal_payload = try g.equal(
            try g.field(bool, left_payload, 0),
            try g.field(bool, right_payload, 0),
        );
        const left_tag = try g.b.primitive(
            try g.schema(u64),
            .variant_tag,
            &.{try g.b.reference(left)},
            0,
        );
        const right_tag = try g.b.primitive(
            try g.schema(u64),
            .variant_tag,
            &.{try g.b.reference(right)},
            0,
        );
        const result = try g.product(Comparison, &.{
            equal_payload,           try g.not(try g.equal(left_tag, right_tag)),
            try g.b.reference(left), try g.b.reference(right),
        });
        try g.b.define(entry, try g.b.bind(
            left,
            try g.call(g.outcome, &.{try g.field(ScanEvidence, input, 2)}),
            try g.b.bind(
                right,
                try g.call(g.outcome, &.{try g.field(ScanEvidence, input, 3)}),
                try g.b.pure(result),
            ),
        ));
        return entry;
    }
};
