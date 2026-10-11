//! Native declaration of the ordinary authored inbox capability. Acquisition
//! and consumption are performed only by the durable task/occurrence owner.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const values = @import("values.zig");

pub const identity = contracts.inbox_semantic_identity;

pub fn Reply(comptime Message: type) type {
    return contracts.InboxReply(Message);
}

pub fn declaration(comptime Message: type) registry.Declaration {
    return .{
        .identity = identity,
        .resource_role = "user",
        .kind = .inbox,
        .payload_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return values.schemaBytes(void, a);
            }
        }.schema,
        .resume_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return values.schemaBytes(Reply(Message), a);
            }
        }.schema,
    };
}
