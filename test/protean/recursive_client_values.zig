const std = @import("std");
const contracts = @import("contracts");
const values = @import("values");
const Node = struct { children: contracts.Vector(@This(), null) };

test "decode recursive client values" {
    _ = try values.fromJson(Node, std.testing.allocator, .null);
}

test "encode recursive client values" {
    _ = try values.toJson(Node, std.testing.allocator, .{ .children = .{ .items = &.{} } });
}
