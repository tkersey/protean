//! Candidate admission is ordinary staged control, shared by every responder.
const std = @import("std");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const ast = horos.source.ast;
const Id = horos.data.program.Id;
const Case = std.meta.Child(@FieldType(@FieldType(ast.Term, "match_sum"), "cases"));

pub const Failure = enum {
    refusal,
    transport,
    provider,
    unsupported,
    missing_answer,
    multiple_calls,
    invalid_arguments,
    declaration_mismatch,
    unoffered,
    non_single_policy,
    invalid_selection,
    parallel_disallowed,
};

pub fn Result(comptime Answer: type) type {
    return union(enum) { accepted: Answer, rejected: Failure };
}

pub fn define(comptime P: type, builder: *horos.source.Builder) !Id {
    return Generator(P, false).define(builder);
}

pub fn defineAll(comptime P: type, builder: *horos.source.Builder) !Id {
    return Generator(P, true).define(builder);
}

fn Generator(comptime P: type, comptime batch: bool) type {
    return struct {
        b: *horos.source.Builder,
        answer: Id,
        interpretation: Id,
        offered: Id,
        held: Id,
        scan: Id,

        const G = @This();
        const Answer = P.AnswerType;
        const Offered = [P.declaration_count]bool;
        const Held = if (batch) []const Answer else ?Answer;
        const Interpretation = Result(if (batch) []const Answer else Answer);

        fn schema(g: G, comptime T: type) !Id {
            return contracts.schema(T, g.b);
        }

        fn literal(g: G, comptime T: type, value: T) !Id {
            return g.b.literal(.{
                .schema = try g.schema(T),
                .bytes = try contracts.encodeOwned(T, g.b.allocator(), value),
            });
        }

        fn field(g: G, value: Id, index: usize, comptime T: type) !Id {
            return g.b.primitive(try g.schema(T), .field, &.{value}, index);
        }

        fn reject(g: G, reason: Failure) !Id {
            return g.b.pure(try g.literal(Interpretation, .{ .rejected = reason }));
        }

        fn accepted(g: G, value: Id) !Id {
            return g.b.pure(try g.b.primitive(g.interpretation, .variant, &.{value}, 0));
        }

        fn recurse(g: G, rest: Id, held: Id, offered: Id, selection: Id) !Id {
            return g.b.term(.{ .call = .{ .function = g.scan, .arguments = &.{ rest, held, offered, selection } } });
        }

        fn selectionValue(g: G) !Id {
            return g.b.reference(g.b.parameter(g.scan, 3));
        }

        fn guard(g: G, condition: Id, yes: Id, reason: Failure) !Id {
            return g.b.term(.{ .conditional = .{ .condition = condition, .when_true = yes, .when_false = try g.reject(reason) } });
        }

        fn equal(g: G, left: Id, right: Id) !Id {
            return g.b.primitive(try g.schema(bool), .equal, &.{ left, right }, 0);
        }

        fn define(b: *horos.source.Builder) !Id {
            const instance = try b.specialization(Id, "agent.model.answer-admission/v3", .{
                @typeName(P), batch,
            });
            if (instance.cached) |cached| return cached;
            const interpretation = try contracts.schema(Interpretation, b);
            const result = try contracts.schema(P.Result, b);
            const offered = try contracts.schema(Offered, b);
            const held = try contracts.schema(Held, b);
            const items = try contracts.schema(P.OutputItems, b);
            const entry = try b.declare(&.{ result, offered, try contracts.schema(@import("model_invocation.zig").Selection, b) }, interpretation, &.{}, &.{});
            const scan = try b.declare(&.{ items, held, offered, try contracts.schema(@import("model_invocation.zig").Selection, b) }, interpretation, &.{}, &.{});
            const g: G = .{ .b = b, .answer = try contracts.schema(Answer, b), .interpretation = interpretation, .offered = offered, .held = held, .scan = scan };
            try b.define(scan, try g.scanBody());
            try b.define(entry, try g.entryBody(entry));
            return instance.finish(b, entry);
        }

        fn entryBody(g: G, entry: Id) !Id {
            const b = g.b;
            const incoming = try b.reference(b.parameter(entry, 0));
            const offered = try b.reference(b.parameter(entry, 1));
            const selection = try b.reference(b.parameter(entry, 2));
            const output = try b.variable(try g.schema(P.Output));
            const call = try g.recurse(try g.field(try b.reference(output), 0, P.OutputItems), try g.literal(Held, if (batch) &.{} else null), offered, selection);
            const result_fields = @typeInfo(P.Result).@"union".field_types;
            var cases: [result_fields.len]Case = undefined;
            cases[0] = .{ .variable = output, .body = call };
            inline for (result_fields[1..], 1..) |FieldType, index| {
                const reasons = [_]Failure{ .refusal, .transport, .provider, .unsupported };
                cases[index] = .{ .variable = try b.variable(try g.schema(FieldType)), .body = try g.reject(reasons[index - 1]) };
            }
            const matched = try b.term(.{ .match_sum = .{ .value = incoming, .cases = &cases } });
            const maximum = try g.field(selection, 1, u32);
            const minimum = try g.field(selection, 0, u32);
            if (batch) {
                const reversed = try b.primitive(try g.schema(bool), .less, &.{ maximum, minimum }, 0);
                const over_limit = try b.primitive(try g.schema(bool), .less, &.{ try b.constant(u32, P.representation.maximum_output_items), maximum }, 0);
                const ordered = try b.primitive(try g.schema(bool), .boolean_not, &.{reversed}, 0);
                const bounded = try b.primitive(try g.schema(bool), .boolean_not, &.{over_limit}, 0);
                return g.guard(ordered, try g.guard(bounded, matched, .invalid_selection), .invalid_selection);
            }
            const min_over_one = try b.primitive(try g.schema(bool), .less, &.{ try b.constant(u32, 1), minimum }, 0);
            const valid_min = try b.primitive(try g.schema(bool), .boolean_not, &.{min_over_one}, 0);
            return g.guard(try g.equal(maximum, try b.constant(u32, 1)), try g.guard(valid_min, matched, .non_single_policy), .non_single_policy);
        }

        fn scanBody(g: G) !Id {
            const b = g.b;
            const rest = try b.reference(b.parameter(g.scan, 0));
            const held = try b.reference(b.parameter(g.scan, 1));
            const offered = try b.reference(b.parameter(g.scan, 2));
            const Pair = struct { item: P.OutputItem, rest: P.OutputItems };
            const popped = try b.primitive(try g.schema(?Pair), .sequence_pop, &.{rest}, 0);
            const empty = try b.variable(try g.schema(void));
            const pair = try b.variable(try g.schema(Pair));
            const remaining = try g.field(try b.reference(pair), 1, P.OutputItems);
            const item = try g.field(try b.reference(pair), 0, P.OutputItem);
            return b.term(.{ .match_sum = .{ .value = popped, .cases = &.{
                .{ .variable = empty, .body = try g.finishHeld(held) },
                .{ .variable = pair, .body = try g.itemBody(item, remaining, held, offered) },
            } } });
        }

        fn finishHeld(g: G, held: Id) !Id {
            if (batch) return g.finishBatch(held);
            const absent = try g.b.variable(try g.schema(void));
            const present = try g.b.variable(g.answer);
            return g.b.term(.{ .match_sum = .{ .value = held, .cases = &.{
                .{ .variable = absent, .body = try g.reject(.missing_answer) },
                .{ .variable = present, .body = try g.accepted(try g.b.reference(present)) },
            } } });
        }

        fn finishBatch(g: G, held: Id) !Id {
            const b = g.b;
            const policy = try g.selectionValue();
            const count = try b.primitive(try g.schema(u64), .sequence_length, &.{held}, 0);
            const minimum = try b.primitive(try g.schema(u64), .integer_convert, &.{try g.field(policy, 0, u32)}, 0);
            const maximum = try b.primitive(try g.schema(u64), .integer_convert, &.{try g.field(policy, 1, u32)}, 0);
            const short = try b.primitive(try g.schema(bool), .less, &.{ count, minimum }, 0);
            const excess = try b.primitive(try g.schema(bool), .less, &.{ maximum, count }, 0);
            const multiple = try b.primitive(try g.schema(bool), .less, &.{ try b.constant(u64, 1), count }, 0);
            const admitted_parallel = try g.field(policy, 2, bool);
            const result = try b.term(.{ .conditional = .{
                .condition = multiple,
                .when_true = try g.guard(admitted_parallel, try g.accepted(held), .parallel_disallowed),
                .when_false = try g.accepted(held),
            } });
            const enough = try b.primitive(try g.schema(bool), .boolean_not, &.{short}, 0);
            const within = try b.primitive(try g.schema(bool), .boolean_not, &.{excess}, 0);
            return g.guard(enough, try g.guard(within, result, .multiple_calls), .missing_answer);
        }

        fn itemBody(g: G, item: Id, rest: Id, held: Id, offered: Id) !Id {
            const fields = @typeInfo(P.OutputItem).@"union".field_types;
            var cases: [fields.len]Case = undefined;
            inline for (fields, 0..) |FieldType, index| {
                const variable = try g.b.variable(try g.schema(FieldType));
                cases[index] = .{ .variable = variable, .body = if (index == 0)
                    try g.callBody(try g.b.reference(variable), rest, held, offered)
                else
                    try g.recurse(rest, held, offered, try g.selectionValue()) };
            }
            return g.b.term(.{ .match_sum = .{ .value = item, .cases = &cases } });
        }

        fn callBody(g: G, call: Id, rest: Id, held: Id, offered: Id) !Id {
            const b = g.b;
            const decoded = try g.field(call, 4, P.DecodedAnswer);
            const answer = try b.variable(g.answer);
            const failure = try b.variable(try g.schema(@import("model_codec.zig").DecodeFailure));
            const decision = try b.term(.{ .match_sum = .{ .value = decoded, .cases = &.{
                .{ .variable = answer, .body = try g.checkAnswer(call, rest, try b.reference(answer), held, offered) },
                .{ .variable = failure, .body = try g.reject(.invalid_arguments) },
            } } });
            if (batch) return decision;
            const absent = try b.variable(try g.schema(void));
            const present = try b.variable(g.answer);
            return b.term(.{ .match_sum = .{ .value = held, .cases = &.{
                .{ .variable = absent, .body = decision },
                .{ .variable = present, .body = try g.reject(.multiple_calls) },
            } } });
        }

        fn checkAnswer(g: G, call: Id, rest: Id, answer: Id, held: Id, offered: Id) !Id {
            const fields = @typeInfo(Answer).@"union".field_types;
            var cases: [fields.len]Case = undefined;
            inline for (fields, 0..) |FieldType, index| {
                cases[index] = .{ .variable = try g.b.variable(try g.schema(FieldType)), .body = try g.checkDeclaration(call, rest, answer, held, offered, index) };
            }
            return g.b.term(.{ .match_sum = .{ .value = answer, .cases = &cases } });
        }

        fn checkDeclaration(g: G, call: Id, rest: Id, answer: Id, held: Id, offered: Id, comptime index: usize) !Id {
            const b = g.b;
            const name = try g.field(call, 1, P.ToolName);
            const declaration = try P.declarationValue(b, index);
            const expected = try g.field(declaration, 2, P.ToolName);
            const compared = try b.primitive(try g.schema(i8), .blob_compare, &.{ name, expected }, 0);
            const ordinal = try g.field(call, 3, u32);
            const allowed = try b.primitive(try g.schema(?bool), .sequence_get, &.{ offered, try b.constant(u64, index) }, 0);
            const next_held = if (batch)
                try b.primitive(g.held, .sequence_append, &.{ held, answer }, 0)
            else
                try b.primitive(g.held, .variant, &.{answer}, 1);
            const absent = try b.variable(try g.schema(void));
            const present = try b.variable(try g.schema(bool));
            const availability = try b.term(.{ .match_sum = .{ .value = allowed, .cases = &.{
                .{ .variable = absent, .body = try g.reject(.unoffered) },
                .{ .variable = present, .body = try g.guard(try b.reference(present), try g.recurse(rest, next_held, offered, try g.selectionValue()), .unoffered) },
            } } });
            return g.guard(try g.equal(compared, try b.constant(i8, 0)), try g.guard(try g.equal(ordinal, try b.constant(u32, index)), availability, .declaration_mismatch), .declaration_mismatch);
        }
    };
}
