//! Continuing conversations are ordinary calls and recursion in Horos source.
//! The application owns memory, turn result, failure, and closure policy.
const std = @import("std");
const source = @import("horos").source;
const interaction = @import("interaction.zig");
const Id = source.Id;
pub const Error = interaction.Error;

pub const Spec = struct {
    memory: Id,
    input: Id,
    reply: Id,
    result: Id,
    exchange: interaction.Definition,
    /// Ordinary function (Memory, Input) -> product(Memory, Reply).
    turn: Id,
    /// Ordinary function (Memory, CloseReason) -> Result.
    finish: Id,
    channel: Id,
    purpose: Id,
    presentation: Id,
    residual: source.Row = .{ .effects = &.{} },
    regions: []const Id = &.{},
};

pub const Loop = struct { function: Id, turn_result: Id };

/// A turn abort is an application-owned Reply variant; the turn handles its
/// cleanup before returning it. Only the declared close input calls finish.
pub fn define(b: *source.Builder, spec: Spec) Error!Loop {
    const close = spec.exchange.contract.close_conversation orelse return error.TypeMismatch;
    if (spec.exchange.contract.abort_turn != null or
        spec.exchange.contract.input != spec.input or
        spec.exchange.contract.outgoing != spec.reply) return error.TypeMismatch;
    const pair = try b.schema(.{ .product = &.{ spec.memory, spec.reply } });
    try checkFunction(b, spec.turn, &.{ spec.memory, spec.input }, pair, spec.residual);
    try checkFunction(b, spec.finish, &.{ spec.memory, close }, spec.result, spec.residual);
    if (std.mem.indexOfScalar(Id, spec.residual.effects, spec.exchange.effect) == null)
        return error.InvalidEffect;
    const instance = try b.specialization(Loop, "agent.conversation/v1", .{spec});
    if (instance.cached) |cached| return cached;
    const loop = try b.declare(&.{ spec.memory, spec.input }, spec.result, spec.residual.effects, spec.regions);
    const turn_result = try b.variable(pair);
    const memory = try b.variable(spec.memory);
    const reply = try b.variable(spec.reply);
    const next = try exchangeNext(b, spec, loop, memory, reply, close);
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(turn_result),
        .variables = &.{ memory, reply },
        .body = next,
    } });
    const turn = try b.term(.{ .call = .{
        .function = spec.turn,
        .arguments = &.{
            try b.reference(b.parameter(loop, 0)),
            try b.reference(b.parameter(loop, 1)),
        },
    } });
    try b.define(loop, try b.bind(turn_result, turn, unpack));
    return instance.finish(b, .{ .function = loop, .turn_result = pair });
}

fn exchangeNext(b: *source.Builder, spec: Spec, loop: Id, memory: Id, reply: Id, close: Id) Error!Id {
    const response = try b.variable(spec.exchange.reply);
    const input = try b.variable(spec.input);
    const reason = try b.variable(close);
    const next = try b.term(.{ .match_sum = .{
        .value = try b.reference(response),
        .cases = &.{
            .{ .variable = input, .body = try b.term(.{ .call = .{
                .function = loop,
                .arguments = &.{ try b.reference(memory), try b.reference(input) },
            } }) },
            .{ .variable = reason, .body = try b.term(.{ .call = .{
                .function = spec.finish,
                .arguments = &.{ try b.reference(memory), try b.reference(reason) },
            } }) },
        },
    } });
    return b.bind(response, try interaction.exchange(b, spec.exchange, .{
        .channel = spec.channel,
        .purpose = spec.purpose,
        .presentation = spec.presentation,
        .outgoing = try b.reference(reply),
    }), next);
}

pub fn run(b: *source.Builder, loop: Loop, memory: Id, input: Id) source.Error!Id {
    return b.term(.{ .call = .{
        .function = loop.function,
        .arguments = &.{ memory, input },
    } });
}

fn checkFunction(b: *source.Builder, id: Id, parameters: []const Id, result: Id, residual: source.Row) source.Error!void {
    if (id >= b.functions.items.len) return error.InvalidReference;
    const function = b.functions.items[@intCast(id)];
    if (function.parameters.len != parameters.len or function.result != result)
        return error.TypeMismatch;
    for (function.parameters, parameters) |parameter, schema| {
        if (b.variables.items[@intCast(parameter)] != schema) return error.TypeMismatch;
    }
    for (function.effects) |effect| {
        if (std.mem.indexOfScalar(Id, residual.effects, effect) == null)
            return error.InvalidEffect;
    }
}

test "conversation checks the nested turn and its exact next-input contract" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u32);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const contract = try interaction.define(&b, .{
        .name = "conversation.check",
        .channel = unit,
        .purpose = unit,
        .presentation = unit,
        .outgoing = integer,
        .input = integer,
        .close_conversation = unit,
    });
    const turn = try b.declare(&.{ integer, integer }, pair, &.{}, &.{});
    try b.define(turn, try b.pure(try b.primitive(pair, .product, &.{
        try b.reference(b.parameter(turn, 0)), try b.reference(b.parameter(turn, 1)),
    }, 0)));
    const finish = try b.declare(&.{ integer, unit }, integer, &.{}, &.{});
    try b.define(finish, try b.pure(try b.reference(b.parameter(finish, 0))));
    const nothing = try b.constant(void, {});
    const valid = Spec{
        .memory = integer,
        .input = integer,
        .reply = integer,
        .result = integer,
        .exchange = contract,
        .turn = turn,
        .finish = finish,
        .channel = nothing,
        .purpose = nothing,
        .presentation = nothing,
        .residual = .{ .effects = &.{contract.effect} },
    };
    const first = try define(&b, valid);
    try std.testing.expectEqual(first.function, (try define(&b, valid)).function);
    var wrong = valid;
    wrong.turn = finish;
    try std.testing.expectError(error.TypeMismatch, define(&b, wrong));
    wrong = valid;
    wrong.residual = .{ .effects = &.{} };
    try std.testing.expectError(error.InvalidEffect, define(&b, wrong));
    wrong = valid;
    wrong.exchange.contract.close_conversation = null;
    try std.testing.expectError(error.TypeMismatch, define(&b, wrong));
    wrong = valid;
    wrong.exchange.contract.abort_turn = unit;
    try std.testing.expectError(error.TypeMismatch, define(&b, wrong));
}
