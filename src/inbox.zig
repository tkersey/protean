//! Nonblocking user input at an explicit authored boundary. This is ordinary
//! data, not approval, a pending-question answer, or a host-driven new turn.
const authoring = @import("authoring.zig");
const std = @import("std");
const contracts = @import("protean_contracts");
const Id = @import("horos").source.Id;
pub const semantic_identity = contracts.inbox_semantic_identity;

pub fn Profile(comptime Message: type) type {
    return struct {
        pub const Reply = contracts.InboxReply(Message);
        pub fn declare(c: authoring.Context) !Id {
            const b = c.builder;
            const payload = try c.schema(void);
            const result = try c.schema(Reply);
            const slot = try b.specialization(Id, semantic_identity, .{});
            const effect = if (slot.cached) |cached| blk: {
                const existing = b.effects.items[@intCast(cached)];
                if (existing.payload != payload or existing.result != result) return error.InvalidInboxContract;
                break :blk cached;
            } else blk: {
                for (b.effects.items) |existing| if (std.mem.eql(u8, existing.identity, semantic_identity)) return error.InvalidInboxContract;
                break :blk try slot.finish(b, try b.effect(.{ .identity = semantic_identity, .payload = payload, .result = result }));
            };
            try c.registry.classify(effect, .read);
            return effect;
        }
        pub fn poll(c: authoring.Context) !Id {
            return c.builder.term(.{ .perform = .{
                .effect = try declare(c),
                .payload = try c.builder.constant(void, {}),
            } });
        }
    };
}
