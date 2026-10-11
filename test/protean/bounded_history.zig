//! Budget order and bounded history are ordinary authored policy, not host state.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const kronos = @import("kronos");
const Id = horos.source.Id;
const History = protean.contracts.Vector(u64, 2);
const Input = struct { turns: u8, effects: u8, drop_oldest: bool };
const Choice = union(enum) { observe: u64, finish: void };
const Failure = enum { turn_budget, effect_budget, history_overflow };
const Pair = struct { head: u64, rest: History };
const System = protean.system(.{ .InitialArgs = Input, .Result = History, .Failure = Failure, .application = Application });

const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const decide = try c.external("history.decide", try c.schema(History), try c.schema(Choice), .read);
        const observe = try c.external("history.observe", try c.schema(u64), try c.schema(u64), .read);
        const loop = try b.declare(&.{ try c.schema(Input), try c.schema(History) }, try c.schema(History), &.{ decide, observe }, &.{});
        const input = try b.reference(b.parameter(loop, 0));
        const history = try b.reference(b.parameter(loop, 1));
        const turns = try field(c, u8, input, 0);
        const effects = try field(c, u8, input, 1);
        const drop = try field(c, bool, input, 2);
        const selected = try b.variable(try c.schema(Choice));
        const value = try b.variable(try c.schema(u64));
        const done = try b.variable(try c.schema(void));
        const observed = try b.variable(try c.schema(u64));
        const room = try b.variable(try c.schema(History));
        const tail = try makeRoom(c, history, drop);
        const appended = try b.value(.{ .schema = try c.schema(History), .expression = .{ .primitive = .{
            .opcode = .sequence_append,
            .operands = &.{ try b.reference(room), try b.reference(observed) },
            .failures = &.{.{ .kind = .capacity_exceeded, .value = try b.failureLiteral(try c.literal(Failure, .history_overflow)) }},
        } } });
        const next = try b.primitive(try c.schema(Input), .product, &.{ try subtract(c, turns, .turn_budget), try subtract(c, effects, .effect_budget), drop }, 0);
        const continued = try b.term(.{ .call = .{ .function = loop, .arguments = &.{ next, appended } } });
        const operation = try b.bind(room, tail, try b.bind(observed, try b.term(.{ .perform = .{ .effect = observe, .payload = try b.reference(value) } }), continued));
        const admitted = try b.term(.{ .conditional = .{
            .condition = try less(c, try c.literal(u8, 0), effects),
            .when_true = operation,
            .when_false = try fail(c, .effect_budget),
        } });
        const choice = try b.term(.{ .match_sum = .{ .value = try b.reference(selected), .cases = &.{
            .{ .variable = value, .body = admitted }, .{ .variable = done, .body = try b.pure(history) },
        } } });
        const decide_term = try b.bind(selected, try b.term(.{ .perform = .{ .effect = decide, .payload = history } }), choice);
        try b.define(loop, try b.term(.{ .conditional = .{
            .condition = try less(c, try c.literal(u8, 0), turns),
            .when_true = decide_term,
            .when_false = try fail(c, .turn_budget),
        } }));
        const entry = try b.declare(&.{try c.schema(Input)}, try c.schema(History), &.{ decide, observe }, &.{});
        try b.define(entry, try b.term(.{ .call = .{ .function = loop, .arguments = &.{ try b.reference(b.parameter(entry, 0)), try c.literal(History, .{ .items = &.{} }) } } }));
        return b.module(entry, try c.schema(Failure));
    }
};

fn makeRoom(c: protean.Context, history: Id, drop: Id) !Id {
    const b = c.builder;
    const length = try b.primitive(try c.schema(u64), .sequence_length, &.{history}, 0);
    const empty = try b.variable(try c.schema(void));
    const pair = try b.variable(try c.schema(Pair));
    const removed = try b.term(.{ .match_sum = .{ .value = try b.primitive(try c.schema(?Pair), .sequence_pop, &.{history}, 0), .cases = &.{
        .{ .variable = empty, .body = try fail(c, .history_overflow) },
        .{ .variable = pair, .body = try b.pure(try field(c, History, try b.reference(pair), 1)) },
    } } });
    const full = try b.term(.{ .conditional = .{ .condition = drop, .when_true = removed, .when_false = try fail(c, .history_overflow) } });
    return b.term(.{ .conditional = .{ .condition = try less(c, length, try c.literal(u64, 2)), .when_true = try b.pure(history), .when_false = full } });
}
fn field(c: protean.Context, comptime T: type, value: Id, index: u64) !Id {
    return c.builder.primitive(try c.schema(T), .field, &.{value}, index);
}
fn less(c: protean.Context, a: Id, z: Id) !Id {
    return c.builder.primitive(try c.schema(bool), .less, &.{ a, z }, 0);
}
fn subtract(c: protean.Context, value: Id, failure: Failure) !Id {
    return c.builder.value(.{ .schema = try c.schema(u8), .expression = .{ .primitive = .{
        .opcode = .integer_sub,
        .operands = &.{ value, try c.literal(u8, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = try c.builder.failureLiteral(try c.literal(Failure, failure)) }},
    } } });
}
fn fail(c: protean.Context, value: Failure) !Id {
    return c.builder.term(.{ .fail = try c.literal(Failure, value) });
}

const Driver = struct {
    image: []u8,
    outcome: kronos.invocation.Outcome,
    fn init(input: Input) !Driver {
        const a = std.testing.allocator;
        var compiled = try protean.compile(a, System);
        defer compiled.deinit();
        const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        errdefer a.free(image);
        _ = try compiled.encode(a, image);
        const args = try protean.contracts.encodeOwned(Input, a, input);
        defer a.free(args);
        return .{ .image = image, .outcome = try kronos.invocation.invoke(a, .{ .image = image, .instance = .{ .initial_args = args } }) };
    }
    fn deinit(d: *Driver) void {
        d.outcome.deinit();
        std.testing.allocator.free(d.image);
    }
    fn request(d: *Driver, comptime T: type, name: []const u8) !protean.contracts.Decoded(T) {
        try std.testing.expect(d.outcome.record == .requested);
        var r = try horos.data.invocation.decode(horos.data.invocation.Request, std.testing.allocator, d.outcome.record.requested.request);
        defer r.deinit();
        try std.testing.expectEqualStrings(name, r.value.binding.semantic_identity);
        return protean.contracts.decodeOwned(T, std.testing.allocator, r.value.binding.payload);
    }
    fn reply(d: *Driver, comptime T: type, value: T) !void {
        const a = std.testing.allocator;
        var r = try horos.data.invocation.decode(horos.data.invocation.Request, a, d.outcome.record.requested.request);
        defer r.deinit();
        const bytes = try protean.contracts.encodeOwned(T, a, value);
        defer a.free(bytes);
        const reply_bytes = try horos.data.invocation.encodeOwned(horos.data.invocation.Result, a, .{ .request_identity = r.value.request_identity, .value = bytes });
        defer a.free(reply_bytes);
        const next = try kronos.invocation.invoke(a, .{ .image = d.image, .instance = .{ .state = d.outcome.record.requested.state.? }, .control = .{ .reply = reply_bytes } });
        d.outcome.deinit();
        d.outcome = next;
    }
    fn failure(d: *Driver, expected: Failure) !void {
        try std.testing.expect(d.outcome.record == .failed);
        var value = try protean.contracts.decodeOwned(Failure, std.testing.allocator, d.outcome.record.failed.value);
        defer value.deinit();
        try std.testing.expectEqual(expected, value.value);
    }
    fn observe(d: *Driver, value: u64) !void {
        var request_ = try d.request(History, "history.decide");
        defer request_.deinit();
        try d.reply(Choice, .{ .observe = value });
        var operation = try d.request(u64, "history.observe");
        defer operation.deinit();
        try std.testing.expectEqual(value, operation.value);
        try d.reply(u64, value);
    }
};

test "authored turn and effect budgets fail before excess requests" {
    var none = try Driver.init(.{ .turns = 0, .effects = 0, .drop_oldest = false });
    defer none.deinit();
    try none.failure(.turn_budget);
    var d = try Driver.init(.{ .turns = 1, .effects = 1, .drop_oldest = false });
    defer d.deinit();
    try d.observe(7);
    try d.failure(.turn_budget);
}

test "effect budget precedes history overflow and neither emits an excess operation" {
    for ([_]u8{ 2, 3 }) |effects| {
        var d = try Driver.init(.{ .turns = 4, .effects = effects, .drop_oldest = false });
        defer d.deinit();
        try d.observe(1);
        try d.observe(2);
        try d.reply(Choice, .{ .observe = 3 });
        try d.failure(if (effects == 2) .effect_budget else .history_overflow);
    }
}

test "drop-oldest retains exactly the newest two observations across 32 fresh restores" {
    var d = try Driver.init(.{ .turns = 33, .effects = 32, .drop_oldest = true });
    defer d.deinit();
    var saturated_size: usize = 0;
    for (0..32) |i| {
        try d.observe(i);
        var history = try d.request(History, "history.decide");
        defer history.deinit();
        const expected = [_]u64{ if (i > 0) i - 1 else 0, i };
        try std.testing.expectEqualSlices(u64, if (i == 0) &.{0} else &expected, history.value.items);
        const size = d.outcome.record.requested.state.?.len;
        if (i == 1) saturated_size = size;
        if (i >= 1) try std.testing.expect(size <= saturated_size + 32);
    }
    try d.reply(Choice, .{ .finish = {} });
    try std.testing.expect(d.outcome.record == .completed);
    var result = try protean.contracts.decodeOwned(History, std.testing.allocator, d.outcome.record.completed);
    defer result.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 30, 31 }, result.value.items);
}
