//! First-order typed interaction declarations and ordinary Horos performs.
//! Internal dialogue futures never belong in an interaction contract: Horos
//! admission checks external portability of the complete emitted module.
const std = @import("std");
const source = @import("horos").source;
pub const Id = source.Id;
pub const Error = source.Error || error{InvalidInteractionContract};
pub const identity_prefix = "agent.interaction.exchange.v1.";

/// Schema identifiers belong to the Builder passed to define(). Presentation
/// may use a declared option/sum schema, or unit when presentation is absent.
/// Names are nonempty ASCII identifiers beginning with an alphanumeric byte;
/// subsequent bytes may additionally contain '.', '-', or '_'.
pub const Contract = struct {
    name: []const u8,
    channel: Id,
    purpose: Id,
    presentation: Id,
    outgoing: Id,
    input: Id,
    abort_turn: ?Id = null,
    close_conversation: ?Id = null,
};

pub const Definition = struct {
    contract: Contract,
    effect: Id,
    payload: Id,
    reply: Id,
    abort_turn_tag: ?Id,
    close_conversation_tag: ?Id,
};

/// Repeated compatible declarations share an effect. A name cannot change its
/// schema association or admitted control variants within the same Builder.
pub fn define(builder: *source.Builder, contract: Contract) Error!Definition {
    try validateContract(builder, contract);
    const instance = try builder.specialization(
        Definition,
        "agent.interaction.exchange/v1",
        .{contract.name},
    );
    if (instance.cached) |present| {
        if (!sameContract(present.contract, contract)) return error.InvalidInteractionContract;
        return present;
    }
    const identity = try builder.allocator().print("{s}{s}", .{
        identity_prefix, contract.name,
    });
    // A raw effect with the same name has no declaration proving the meaning
    // of its sum alternatives. Do not silently adopt it based on shape alone.
    for (builder.effects.items) |effect| {
        if (std.mem.eql(u8, effect.identity, identity)) return error.InvalidInteractionContract;
    }
    const payload = try builder.schema(.{ .product = &.{
        contract.channel, contract.purpose, contract.presentation, contract.outgoing,
    } });
    var alternatives = [_]Id{ contract.input, 0, 0 };
    var count: usize = 1;
    const abort_tag = appendAlternative(&alternatives, &count, contract.abort_turn);
    const close_tag = appendAlternative(&alternatives, &count, contract.close_conversation);
    const reply = try builder.schema(.{ .sum = alternatives[0..count] });
    const effect = try builder.effect(.{
        .identity = identity,
        .payload = payload,
        .result = reply,
        .external = true,
    });
    return instance.finish(builder, .{
        .contract = contract,
        .effect = effect,
        .payload = payload,
        .reply = reply,
        .abort_turn_tag = abort_tag,
        .close_conversation_tag = close_tag,
    });
}

/// Source value IDs, in the fixed semantic payload order. This constructs a
/// perform term; Kronos supplies the one outstanding ERQ2/ERS2 interaction.
pub const Outgoing = struct { channel: Id, purpose: Id, presentation: Id, outgoing: Id };

pub fn exchange(builder: *source.Builder, definition: Definition, values: Outgoing) Error!Id {
    const fields = [_]Id{ values.channel, values.purpose, values.presentation, values.outgoing };
    const schemas = [_]Id{
        definition.contract.channel,      definition.contract.purpose,
        definition.contract.presentation, definition.contract.outgoing,
    };
    for (fields, schemas) |field, schema| try expectValue(builder, field, schema);
    const payload = try builder.primitive(definition.payload, .product, &fields, 0);
    return builder.term(.{ .perform = .{ .effect = definition.effect, .payload = payload } });
}

/// Helpers construct ordinary source values for authored interpretations/tests.
/// An environment instead encodes the declared reply and binds it with Kronos.
pub fn value(builder: *source.Builder, definition: Definition, input: Id) Error!Id {
    try expectValue(builder, input, definition.contract.input);
    return builder.primitive(definition.reply, .variant, &.{input}, 0);
}

pub fn abortTurn(builder: *source.Builder, definition: Definition, reason: Id) Error!Id {
    const schema = definition.contract.abort_turn orelse return error.InvalidInteractionContract;
    const tag = definition.abort_turn_tag orelse return error.InvalidInteractionContract;
    try expectValue(builder, reason, schema);
    return builder.primitive(definition.reply, .variant, &.{reason}, tag);
}

pub fn closeConversation(builder: *source.Builder, definition: Definition, reason: Id) Error!Id {
    const schema = definition.contract.close_conversation orelse
        return error.InvalidInteractionContract;
    const tag = definition.close_conversation_tag orelse return error.InvalidInteractionContract;
    try expectValue(builder, reason, schema);
    return builder.primitive(definition.reply, .variant, &.{reason}, tag);
}

fn validateContract(builder: *const source.Builder, contract: Contract) Error!void {
    if (contract.name.len == 0 or !std.ascii.isAlphanumeric(contract.name[0])) {
        return error.InvalidInteractionContract;
    }
    for (contract.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') {
            return error.InvalidInteractionContract;
        }
    }
    const required = [_]Id{
        contract.channel, contract.purpose, contract.presentation, contract.outgoing, contract.input,
    };
    for (required) |schema| if (schema >= builder.schemas.items.len) {
        return error.InvalidInteractionContract;
    };
    const optional = [_]?Id{ contract.abort_turn, contract.close_conversation };
    for (optional) |schema| if (schema) |id| {
        if (id >= builder.schemas.items.len) return error.InvalidInteractionContract;
    };
}

fn sameContract(a: Contract, b: Contract) bool {
    return std.mem.eql(u8, a.name, b.name) and a.channel == b.channel and
        a.purpose == b.purpose and a.presentation == b.presentation and
        a.outgoing == b.outgoing and a.input == b.input and
        a.abort_turn == b.abort_turn and a.close_conversation == b.close_conversation;
}

fn appendAlternative(alternatives: *[3]Id, count: *usize, schema: ?Id) ?Id {
    const present = schema orelse return null;
    const tag: Id = @intCast(count.*);
    alternatives[count.*] = present;
    count.* += 1;
    return tag;
}

fn expectValue(builder: *const source.Builder, id: Id, schema: Id) Error!void {
    if (id >= builder.values.items.len) return error.InvalidReference;
    if (builder.values.items[@intCast(id)].schema != schema) return error.TypeMismatch;
}

test "interaction identity includes the declared control meanings" {
    var builder = source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const unit = try builder.scalar(void);
    const integer = try builder.scalar(u32);
    var contract = Contract{
        .name = "review.clarification",
        .channel = unit,
        .purpose = unit,
        .presentation = unit,
        .outgoing = integer,
        .input = integer,
        .abort_turn = unit,
    };
    const first = try define(&builder, contract);
    const again = try define(&builder, contract);
    try std.testing.expectEqual(first.effect, again.effect);
    try std.testing.expectEqual(@as(?Id, 1), first.abort_turn_tag);
    try std.testing.expectEqual(@as(?Id, null), first.close_conversation_tag);
    contract.abort_turn = null;
    contract.close_conversation = unit;
    try std.testing.expectError(error.InvalidInteractionContract, define(&builder, contract));
    contract.close_conversation = null;
    contract.input = unit;
    try std.testing.expectError(error.InvalidInteractionContract, define(&builder, contract));
}

test "exchange preserves payload order and does not widen reply variants" {
    var builder = source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const unit = try builder.scalar(void);
    const integer = try builder.scalar(u32);
    const definition = try define(&builder, .{
        .name = "message",
        .channel = unit,
        .purpose = unit,
        .presentation = unit,
        .outgoing = integer,
        .input = integer,
        .close_conversation = unit,
    });
    const nothing = try builder.constant(void, {});
    const message = try builder.constant(u32, 7);
    const term = try exchange(&builder, definition, .{
        .channel = nothing,
        .purpose = nothing,
        .presentation = nothing,
        .outgoing = message,
    });
    try std.testing.expectEqual(definition.effect, builder.terms.items[@intCast(term)].perform.effect);
    const shape = builder.schemas.items[@intCast(definition.payload)].product;
    try std.testing.expectEqualSlices(Id, &.{ unit, unit, unit, integer }, shape);
    try std.testing.expectEqual(@as(?Id, 1), definition.close_conversation_tag);
    _ = try value(&builder, definition, message);
    _ = try closeConversation(&builder, definition, nothing);
    try std.testing.expectError(error.InvalidInteractionContract, abortTurn(&builder, definition, nothing));
    try std.testing.expectError(error.TypeMismatch, value(&builder, definition, nothing));
}

test "invalid names, schema references, and undeclared identity collisions reject" {
    var builder = source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const unit = try builder.scalar(void);
    var contract = Contract{
        .name = "",
        .channel = unit,
        .purpose = unit,
        .presentation = unit,
        .outgoing = unit,
        .input = unit,
    };
    for ([_][]const u8{ "", "bad name", ".leading", "slash/name", "new\nline" }) |name| {
        contract.name = name;
        try std.testing.expectError(error.InvalidInteractionContract, define(&builder, contract));
    }
    contract.name = "valid";
    contract.input = std.math.maxInt(Id);
    try std.testing.expectError(error.InvalidInteractionContract, define(&builder, contract));
    contract.input = unit;
    _ = try builder.effect(.{
        .identity = identity_prefix ++ "valid",
        .payload = unit,
        .result = unit,
    });
    try std.testing.expectError(error.InvalidInteractionContract, define(&builder, contract));
}

test "definition and specialization own the caller's contract name" {
    var builder = source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const unit = try builder.scalar(void);
    var name = "question".*;
    var contract = Contract{
        .name = &name,
        .channel = unit,
        .purpose = unit,
        .presentation = unit,
        .outgoing = unit,
        .input = unit,
    };
    const original = try define(&builder, contract);
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("question", original.contract.name);
    contract.name = "question";
    const repeated = try define(&builder, contract);
    try std.testing.expectEqual(original.effect, repeated.effect);
    try std.testing.expectEqualStrings("question", repeated.contract.name);
    const effect = builder.effects.items[@intCast(repeated.effect)];
    try std.testing.expectEqualStrings(identity_prefix ++ "question", effect.identity);
}
