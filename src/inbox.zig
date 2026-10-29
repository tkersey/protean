//! Nonblocking user input at an explicit authored boundary. This is ordinary
//! data, not approval, a pending-question answer, or a host-driven new turn.
const authoring = @import("authoring.zig");
const std = @import("std");
const contracts = @import("protean_contracts");
const horos = @import("horos");
const a = horos.authoring;
const Id = horos.source.Id;
pub const semantic_identity = contracts.inbox_semantic_identity;

pub fn Profile(comptime Message: type) type {
    return struct {
        pub const Reply = contracts.InboxReply(Message);
        pub const Operation = a.Operation(
            a.OperationSignature(
                a.Shape(void),
                a.Shape(Reply),
                horos.data.schema.native.Fields(&.{}, &.{}),
            ),
        );
        pub fn declare(c: authoring.Context) !*const Operation {
            const b = c.builder;
            const payload = try a.interop.schemaId(c.author, try c.schema(void));
            const result = try a.interop.schemaId(c.author, try c.schema(Reply));
            const slot = try b.specialization(Id, semantic_identity, .{});
            const effect = if (slot.cached) |cached| blk: {
                const existing = b.effects.items[@intCast(cached)];
                if (existing.payload != payload or existing.result != result)
                    return error.InvalidInboxContract;
                break :blk cached;
            } else blk: {
                for (b.effects.items) |existing| if (std.mem.eql(
                    u8,
                    existing.identity,
                    semantic_identity,
                )) return error.InvalidInboxContract;
                break :blk try slot.finish(
                    b,
                    try b.effect(.{
                        .identity = semantic_identity,
                        .payload = payload,
                        .result = result,
                    }),
                );
            };
            try c.registry.classify(effect, .read);
            return a.interop.externalOperation(
                c.author,
                effect,
                try c.schema(void),
                try c.schema(Reply),
            );
        }
    };
}
