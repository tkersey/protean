const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const state = native.testing.state;
const occurrence = native.testing.occurrence;
const support = @import("workspace_test_support.zig");

pub fn rejectLeafMessage(h: anytype, message_id: state.Digest) !void {
    const a = h.frame;
    const task = h.accepted.receipt.task;
    const declarations = try a.alloc(native.Declaration, h.service.handlers.entries.len);
    var replaced = false;
    for (h.service.handlers.entries, declarations) |entry, *declaration| {
        declaration.* = entry.declaration;
        if (declaration.kind != .inbox) continue;
        try std.testing.expect(!replaced);
        declaration.kind = .leaf;
        declaration.invoke = unexpectedInvocation;
        replaced = true;
    }
    try std.testing.expect(replaced);
    var handlers = try native.Registry.init(a, declarations);
    defer handlers.deinit();
    const original = h.service.handlers;
    h.service.handlers = handlers;
    defer h.service.handlers = original;
    const attempt = try insertAttempt(h, message_id);
    defer support.expectCleanup(removeAttempt(h, attempt));
    try h.service.validateWorkspace(a, task);
    try std.testing.expectError(error.InvalidArchive, h.service.exportCheckpoint(
        a,
        task,
        try std.fmt.allocPrint(a, "{s}/leaf-message.bundle", .{h.path_buffer[0..h.length]}),
    ));
}

fn insertAttempt(h: anytype, message_id: state.Digest) !state.Digest {
    const a = h.frame;
    const store = &h.namespace.store;
    const task = h.accepted.receipt.task;
    const message_bytes = (try store.recordBytes(a, "message", message_id, task)).?;
    var message = try contracts.decodeOwned(state.Message, a, message_bytes);
    defer message.deinit();
    try std.testing.expectEqual(.consumed, message.value.disposition);
    const id = message.value.occurrence.?;
    const occurrence_bytes = (try store.recordBytes(a, "occurrence", id, task)).?;
    var saved = try contracts.decodeOwned(occurrence.Occurrence, a, occurrence_bytes);
    defer saved.deinit();
    const acquired = switch (saved.value.state) {
        .settled_reply => |reply| reply,
        .admitted => |admitted| admitted.reply,
        else => return error.ExpectedAcquiredMessage,
    };
    try std.testing.expectEqual(null, try store.recordBytes(a, "attempt", acquired.attempt, task));
    var parent = try h.service.task(a, task);
    defer parent.deinit();
    try store.begin();
    defer store.rollback();
    try store.createRecord(state.Attempt, "attempt", acquired.attempt, task, .{
        .id = acquired.attempt,
        .task = task,
        .occurrence = id,
        .request = saved.value.request_object,
        .profile = parent.value.profile,
        .capability = .{ .bytes = native.inbox.identity },
        .inference = false,
    });
    store.invalidateIntegrity();
    try h.namespace.commit("test.leaf-message-attempt");
    return acquired.attempt;
}

fn removeAttempt(h: anytype, attempt: state.Digest) !void {
    const store = &h.namespace.store;
    try store.begin();
    defer store.rollback();
    try store.database.run("DELETE FROM records WHERE kind='attempt' AND id=? AND task=?", &.{
        .{ .blob = &attempt },
        .{ .blob = &h.accepted.receipt.task },
    });
    store.invalidateIntegrity();
    try h.namespace.commit("test.restore-inbox-history");
}

fn unexpectedInvocation(_: native.Context, _: []const u8) ![]u8 {
    return error.UnexpectedInvocation;
}
