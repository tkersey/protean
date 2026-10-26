const std = @import("std");
const Self = @This();
const Digest = [32]u8;

mutex: std.atomic.Mutex = .unlocked,
keys: [1024]?Digest = @splat(null),

pub fn contains(self: *Self, key: Digest) bool {
    if (!self.mutex.tryLock()) return false;
    defer self.mutex.unlock();
    const start = index(key);
    for (0..self.keys.len) |offset| {
        const existing = self.keys[(start + offset) % self.keys.len] orelse return false;
        if (std.meta.eql(existing, key)) return true;
    }
    return false;
}

pub fn retain(self: *Self, key: Digest) void {
    if (!self.mutex.tryLock()) return;
    defer self.mutex.unlock();
    const start = index(key);
    for (0..self.keys.len) |offset| {
        const slot = &self.keys[(start + offset) % self.keys.len];
        if (slot.*) |existing| {
            if (std.meta.eql(existing, key)) return;
        } else {
            slot.* = key;
            return;
        }
    }
    self.keys[start] = key;
}

fn index(key: Digest) usize {
    return std.mem.readInt(u16, key[0..2], .little) % 1024;
}

fn collidingKey(value: u64) Digest {
    var key: Digest = @splat(0);
    std.mem.writeInt(u64, key[8..16], value, .little);
    return key;
}

test "colliding guest proofs remain available through the full retained capacity" {
    var proofs: Self = .{};
    for (0..proofs.keys.len) |i| {
        const key = collidingKey(i);
        try std.testing.expect(!proofs.contains(key));
        proofs.retain(key);
    }
    for (0..proofs.keys.len) |i| try std.testing.expect(proofs.contains(collidingKey(i)));
    for (0..proofs.keys.len) |i| proofs.retain(collidingKey(i));
    for (0..proofs.keys.len) |i| try std.testing.expect(proofs.contains(collidingKey(i)));
    try std.testing.expect(!proofs.contains(collidingKey(proofs.keys.len)));
}

test "full guest proof replacement preserves exact membership and bounded storage" {
    var proofs: Self = .{};
    for (0..proofs.keys.len) |i| proofs.retain(collidingKey(i));
    proofs.retain(collidingKey(proofs.keys.len));
    try std.testing.expect(!proofs.contains(collidingKey(0)));
    try std.testing.expect(proofs.contains(collidingKey(proofs.keys.len)));
    for (1..proofs.keys.len) |i| try std.testing.expect(proofs.contains(collidingKey(i)));
    try std.testing.expect(!proofs.contains(collidingKey(proofs.keys.len + 1)));
}

test "guest proof collision clusters wrap without hiding retained keys" {
    var proofs: Self = .{};
    var keys: [4]Digest = undefined;
    for (&keys, 0..) |*key, i| {
        key.* = collidingKey(i);
        std.mem.writeInt(u16, key[0..2], 1023, .little);
    }
    for (keys[0..3]) |key| proofs.retain(key);
    for (keys[0..3]) |key| try std.testing.expect(proofs.contains(key));
    try std.testing.expect(!proofs.contains(keys[3]));
    try std.testing.expectEqualDeep(keys[0], proofs.keys[1023].?);
    try std.testing.expectEqualDeep(keys[1], proofs.keys[0].?);
    try std.testing.expectEqualDeep(keys[2], proofs.keys[1].?);
}

test "busy guest proofs remain an optional optimization without waiting or mutation" {
    var proofs: Self = .{};
    const first = collidingKey(1);
    const second = collidingKey(2);
    proofs.retain(first);
    try std.testing.expect(proofs.mutex.tryLock());
    try std.testing.expect(!proofs.contains(first));
    proofs.retain(second);
    proofs.mutex.unlock();
    try std.testing.expect(proofs.contains(first));
    try std.testing.expect(!proofs.contains(second));
}
