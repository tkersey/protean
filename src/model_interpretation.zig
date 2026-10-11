//! Candidate admission is ordinary checked control, shared by every responder.
const horos = @import("horos");
const a = horos.authoring;
const native = horos.data.schema.native;
const authoring = @import("authoring.zig");
const Selection = @import("model_invocation.zig").Selection;
const Id = horos.source.Id;
fn V(comptime T: type) type {
    return *const a.Value(a.Shape(T));
}
fn Fn(comptime InputType: type, comptime OutputType: type) type {
    return a.Function(a.Signature(a.Shape(InputType).contract.product, a.Shape(OutputType)));
}
const Branch = a.Body(native.Fields(&.{}, &.{}));

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
pub fn Input(comptime P: type) type {
    return struct { result: P.Result, offered: [P.declaration_count]bool, selection: Selection };
}
pub fn Function(comptime P: type, comptime batch: bool) type {
    return Fn(Input(P), Result(if (batch) []const P.AnswerType else P.AnswerType));
}
pub fn define(comptime P: type, context: authoring.Context) !*const Function(P, false) {
    return Generator(P, false).define(context);
}
pub fn defineAll(comptime P: type, context: authoring.Context) !*const Function(P, true) {
    return Generator(P, true).define(context);
}

fn Generator(comptime P: type, comptime batch: bool) type {
    return struct {
        context: authoring.Context,
        scan: *const Fn(ScanInput, Interpretation),
        const G = @This();
        const Answer = P.AnswerType;
        const Offered = [P.declaration_count]bool;
        const Held = if (batch) []const Answer else ?Answer;
        const Interpretation = Result(if (batch) []const Answer else Answer);
        const ScanInput = struct { items: P.OutputItems, held: Held, offered: Offered, selection: Selection };
        fn Cases(comptime T: type) type {
            const fields = @typeInfo(T).@"union";
            var types: [fields.field_names.len]type = undefined;
            for (fields.field_names, 0..) |name, i| {
                const Case = @TypeOf(@as(*Branch, undefined).caseOf(@as(V(T), undefined), name) catch unreachable);
                types[i] = @TypeOf(@as(Case, undefined).ret(@as(V(Interpretation), undefined)) catch unreachable);
            }
            return native.Fields(fields.field_names, &types);
        }
        fn reject(g: G, reason: Failure) !V(Interpretation) {
            return g.context.literal(Interpretation, .{ .rejected = reason });
        }
        fn accepted(g: G, body: anytype, value: anytype) !V(Interpretation) {
            return body.variant(try g.context.schema(Interpretation), "accepted", value);
        }
        fn recurse(g: G, body: anytype, rest: V(P.OutputItems), held: V(Held), offered: V(Offered), selection: V(Selection)) !V(Interpretation) {
            return body.call(g.scan, .{ .items = rest, .held = held, .offered = offered, .selection = selection });
        }
        fn define(context: authoring.Context) !*const Function(P, batch) {
            const c = context.author;
            const b = context.builder;
            const instance = try b.specialization(Id, "agent.model.answer-admission/v3", .{ @intFromPtr(c), @typeName(P), batch });
            const signature = try c.callable(.{ .result = try c.schema(P.Result), .offered = try c.schema(Offered), .selection = try c.schema(Selection) }, try c.schema(Interpretation), .{}, .{ .use = .reusable });
            if (instance.cached) |cached| return a.interop.refineFunction(c, try a.interop.declaredFunction(c, cached), signature);
            const entry = try c.functionFor("model answer admission", signature);
            const scan = try c.function("model answer scan", .{ .items = try c.schema(P.OutputItems), .held = try c.schema(Held), .offered = try c.schema(Offered), .selection = try c.schema(Selection) }, try c.schema(Interpretation), .{});
            const g: G = .{ .context = context, .scan = scan };
            try g.defineScan();
            try g.defineEntry(entry);
            _ = try instance.finish(b, try a.interop.functionId(c, entry));
            return entry;
        }
        fn defineEntry(g: G, entry: *const Function(P, batch)) !void {
            const c = g.context.author;
            const body = try c.body(entry);
            const incoming = try body.parameter("result");
            const offered = try body.parameter("offered");
            const selection = try body.parameter("selection");
            const maximum = try body.field(selection, "maximum_calls");
            const minimum = try body.field(selection, "minimum_calls");
            const admitted = try body.branch();
            const rejected = try body.branch();
            var cases: Cases(P.Result) = undefined;
            inline for (@typeInfo(P.Result).@"union".field_names, 0..) |name, index| {
                const selected = try admitted.caseOf(incoming, name);
                const work = selected.body();
                const result = if (index == 0)
                    try g.recurse(work, try work.field(selected.payload(), "items"), try g.context.literal(Held, if (batch) &.{} else null), offered, selection)
                else
                    try g.reject(([_]Failure{ .refusal, .transport, .provider, .unsupported })[index - 1]);
                @field(cases, name) = try selected.ret(result);
            }
            const matched = try admitted.match(incoming, cases);
            const valid = if (batch) blk: {
                const ordered = try body.booleanNot(try body.less(maximum, minimum));
                const bounded = if (P.representation.maximum_output_items) |limit| try body.booleanNot(try body.less(try body.constant(u32, limit), maximum)) else try body.constant(bool, true);
                break :blk try body.select(ordered, bounded, try body.constant(bool, false));
            } else try body.select(try body.equal(maximum, try body.constant(u32, 1)), try body.booleanNot(try body.less(try body.constant(u32, 1), minimum)), try body.constant(bool, false));
            try c.define(entry, try body.ret(try body.conditional(valid, try admitted.ret(matched), try rejected.ret(try g.reject(if (batch) .invalid_selection else .non_single_policy)))));
        }
        fn defineScan(g: G) !void {
            const c = g.context.author;
            const body = try c.body(g.scan);
            const rest = try body.parameter("items");
            const held = try body.parameter("held");
            const offered = try body.parameter("offered");
            const selection = try body.parameter("selection");
            const popped = try body.pop(rest);
            const empty = try body.caseOf(popped, "empty");
            const item = try body.caseOf(popped, "item");
            const work = item.body();
            const result = try body.match(popped, .{
                .empty = try empty.ret(try g.finishHeld(empty.body(), held, selection)),
                .item = try item.ret(try g.itemBody(work, try work.field(item.payload(), "head"), try work.field(item.payload(), "tail"), held, offered, selection)),
            });
            try c.define(g.scan, try body.ret(result));
        }
        fn finishHeld(g: G, body: anytype, held: V(Held), selection: V(Selection)) !V(Interpretation) {
            if (batch) return g.finishBatch(body, held, selection);
            const absent = try body.caseOf(held, "none");
            const present = try body.caseOf(held, "some");
            return body.match(held, .{ .none = try absent.ret(try g.reject(.missing_answer)), .some = try present.ret(try g.accepted(present.body(), present.payload())) });
        }
        fn finishBatch(g: G, body: anytype, held: V(Held), policy: V(Selection)) !V(Interpretation) {
            const count = try body.sequenceLength(held);
            const integer = try g.context.schema(u64);
            const minimum = try body.convertInteger(integer, try body.field(policy, "minimum_calls"), .{});
            const maximum = try body.convertInteger(integer, try body.field(policy, "maximum_calls"), .{});
            const enough = try body.branch();
            const short = try body.branch();
            const within = try enough.branch();
            const excess = try enough.branch();
            const parallel = try within.branch();
            const forbidden = try within.branch();
            const multiple = try within.less(try within.constant(u64, 1), count);
            const parallel_ok = try within.select(multiple, try within.field(policy, "parallel_calls"), try within.constant(bool, true));
            const admitted = try within.conditional(parallel_ok, try parallel.ret(try g.accepted(parallel, held)), try forbidden.ret(try g.reject(.parallel_disallowed)));
            const bounded = try enough.conditional(try enough.booleanNot(try enough.less(maximum, count)), try within.ret(admitted), try excess.ret(try g.reject(.multiple_calls)));
            return body.conditional(try body.booleanNot(try body.less(count, minimum)), try enough.ret(bounded), try short.ret(try g.reject(.missing_answer)));
        }
        fn itemBody(g: G, body: anytype, item: V(P.OutputItem), rest: V(P.OutputItems), held: V(Held), offered: V(Offered), selection: V(Selection)) !V(Interpretation) {
            var cases: Cases(P.OutputItem) = undefined;
            inline for (@typeInfo(P.OutputItem).@"union".field_names, 0..) |name, index| {
                const selected = try body.caseOf(item, name);
                @field(cases, name) = try selected.ret(if (index == 0) try g.callBody(selected.body(), selected.payload(), rest, held, offered, selection) else try g.recurse(selected.body(), rest, held, offered, selection));
            }
            return body.match(item, cases);
        }
        fn callBody(g: G, body: anytype, call: V(P.FunctionCall), rest: V(P.OutputItems), held: V(Held), offered: V(Offered), selection: V(Selection)) !V(Interpretation) {
            if (batch) return g.decodeCall(body, call, rest, held, offered, selection);
            const absent = try body.caseOf(held, "none");
            const present = try body.caseOf(held, "some");
            return body.match(held, .{ .none = try absent.ret(try g.decodeCall(absent.body(), call, rest, held, offered, selection)), .some = try present.ret(try g.reject(.multiple_calls)) });
        }
        fn decodeCall(g: G, body: anytype, call: V(P.FunctionCall), rest: V(P.OutputItems), held: V(Held), offered: V(Offered), selection: V(Selection)) !V(Interpretation) {
            const decoded = try body.field(call, "decoded_action");
            const answer = try body.caseOf(decoded, "decoded");
            const failure = try body.caseOf(decoded, "invalid");
            return body.match(decoded, .{ .decoded = try answer.ret(try g.checkAnswer(answer.body(), call, rest, answer.payload(), held, offered, selection)), .invalid = try failure.ret(try g.reject(.invalid_arguments)) });
        }
        fn checkAnswer(g: G, body: anytype, call: V(P.FunctionCall), rest: V(P.OutputItems), answer: V(Answer), held: V(Held), offered: V(Offered), selection: V(Selection)) !V(Interpretation) {
            var cases: Cases(Answer) = undefined;
            inline for (@typeInfo(Answer).@"union".field_names, 0..) |name, index| {
                const selected = try body.caseOf(answer, name);
                @field(cases, name) = try selected.ret(try g.checkDeclaration(selected.body(), call, rest, answer, held, offered, selection, index));
            }
            return body.match(answer, cases);
        }
        fn checkDeclaration(g: G, body: anytype, call: V(P.FunctionCall), rest: V(P.OutputItems), answer: V(Answer), held: V(Held), offered: V(Offered), selection: V(Selection), comptime index: usize) !V(Interpretation) {
            const name = try body.field(call, "name");
            const expected = try g.context.literal(P.ToolName, P.allDeclarations().items[index].name);
            const same_name = try body.equal(try body.blobCompare(name, expected), try body.constant(i8, 0));
            const same_ordinal = try body.equal(try body.field(call, "tool_ordinal_claim"), try body.constant(u32, index));
            const valid = try body.branch();
            const mismatch = try body.branch();
            const allowed = try valid.sequenceGet(offered, try valid.constant(u64, index));
            const absent = try valid.caseOf(allowed, "none");
            const present = try valid.caseOf(allowed, "some");
            const work = present.body();
            const enabled = try work.branch();
            const disabled = try work.branch();
            const next_held = if (batch) try enabled.append(held, answer, .{}) else try enabled.variant(try g.context.schema(Held), "some", answer);
            const result = try work.conditional(present.payload(), try enabled.ret(try g.recurse(enabled, rest, next_held, offered, selection)), try disabled.ret(try g.reject(.unoffered)));
            const availability = try valid.match(allowed, .{ .none = try absent.ret(try g.reject(.unoffered)), .some = try present.ret(result) });
            return body.conditional(try body.select(same_name, same_ordinal, try body.constant(bool, false)), try valid.ret(availability), try mismatch.ret(try g.reject(.declaration_mismatch)));
        }
    };
}

test "typed model admission retains its signature with unrelated pending schemas" {
    const std = @import("std");
    const P = @import("model_invocation.zig").Profile(union(enum) { choose: struct { value: u64 } }, .{.{ .name = "choose", .description = "Choose a value." }}, .{ .maximum_output_items = 2 });
    var b = horos.source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var registry = @import("admission.zig").Registry.init(b.allocator());
    defer registry.deinit();
    const context = try authoring.Context.init(&b, &registry);
    const unrelated = try context.author.declareSchema(.alternatives, a.Dynamic);
    const function = try P.interpreter(context);
    try std.testing.expect(@TypeOf(function) == *const Function(P, false));
    try std.testing.expectEqual(function, try P.interpreter(context));
    try context.author.defineAlternatives(unrelated, .{ .unused = try context.schema(void) });
    var compiled = try context.author.compile(std.testing.allocator, function, try context.schema(void));
    defer compiled.deinit();
}
