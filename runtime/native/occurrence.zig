//! Standalone adaptation of mobility/custody.mjs's environmental occurrence
//! contract. Canonical Kronos state remains opaque; no application phase lives
//! here. The Store publishes these transitions atomically with their artifacts.
const std = @import("std");
pub const Digest = [32]u8;
pub const TaskId = [16]u8;
pub const Error = error{ StaleOccurrence, UnsettledOccurrence, CancellationPending, ReplyConflict, QuestionMismatch, InvalidControl };

pub const Attempt = struct { id: Digest };
pub const Waiting = struct { attempt: Digest, question: Digest, pending_digest: Digest };
pub const Answer = struct { question: Digest, pending_digest: Digest, digest: Digest };
pub const Acquired = struct { attempt: Digest, reply: Digest, answer: ?Answer = null };
pub const Admitted = union(enum) { reply: Acquired, cancelled: ?Waiting };
pub const State = union(enum) {
    ready,
    dispatching: Attempt,
    awaiting: Waiting,
    unknown: Attempt,
    settled_reply: Acquired,
    admitted: Admitted,
    not_sent: Attempt,
    captured: Attempt,
};
pub const Occurrence = struct {
    id: Digest,
    task: TaskId,
    request: Digest,
    state: State = .ready,
    request_object: @import("state.zig").Reference,
};
pub const Binding = struct { id: Digest, task: TaskId, request: Digest };

fn equal(a: Digest, b: Digest) bool {
    return std.mem.eql(u8, &a, &b);
}
pub fn current(value: Occurrence, binding: Binding) Error!void {
    if (!equal(value.id, binding.id) or !std.mem.eql(u8, &value.task, &binding.task) or !equal(value.request, binding.request)) return error.StaleOccurrence;
}

pub fn dispatch(value: Occurrence, binding: Binding, attempt: Digest, cancellation_pending: bool, cleanup: bool) Error!Occurrence {
    try current(value, binding);
    if (value.state != .ready) return error.UnsettledOccurrence;
    if (cancellation_pending and !cleanup) return error.CancellationPending;
    var next = value;
    next.state = .{ .dispatching = .{ .id = attempt } };
    return next;
}

/// Register known human waiting directly from READY. No network operation or
/// process-local promise sits between admission and the durable question.
pub fn awaiting(value: Occurrence, binding: Binding, pending: Waiting, cancellation_pending: bool) Error!Occurrence {
    var next = try dispatch(value, binding, pending.attempt, cancellation_pending, false);
    next.state = .{ .awaiting = pending };
    return next;
}

pub fn unknown(value: Occurrence, binding: Binding, attempt: Digest) Error!Occurrence {
    try current(value, binding);
    const prior = switch (value.state) {
        .dispatching, .unknown => |item| item.id,
        else => return error.UnsettledOccurrence,
    };
    if (!equal(prior, attempt)) return error.StaleOccurrence;
    var next = value;
    next.state = .{ .unknown = .{ .id = attempt } };
    return next;
}

/// Only an I/O owner with positive evidence that invocation never began may
/// publish this state. A timeout after invocation is UNKNOWN instead.
pub fn notSent(value: Occurrence, binding: Binding, attempt: Digest) Error!Occurrence {
    try current(value, binding);
    if (value.state != .dispatching or !equal(value.state.dispatching.id, attempt)) return error.UnsettledOccurrence;
    var next = value;
    next.state = .{ .not_sent = .{ .id = attempt } };
    return next;
}

pub fn rearm(value: Occurrence, binding: Binding) Error!Occurrence {
    try current(value, binding);
    if (value.state != .not_sent) return error.UnsettledOccurrence;
    var next = value;
    next.state = .ready;
    return next;
}

pub fn acquired(value: Occurrence, binding: Binding, attempt: Digest, reply: Digest) Error!Occurrence {
    try current(value, binding);
    const prior = switch (value.state) {
        .dispatching, .unknown, .captured => |item| item.id,
        .settled_reply => |saved| {
            if (!equal(saved.attempt, attempt) or saved.answer != null or !equal(saved.reply, reply)) return error.ReplyConflict;
            return value;
        },
        else => return error.UnsettledOccurrence,
    };
    if (!equal(prior, attempt)) return error.StaleOccurrence;
    var next = value;
    next.state = .{ .settled_reply = .{ .attempt = attempt, .reply = reply } };
    return next;
}

/// Exact external bytes are durable, but no interpretation is admitted yet.
/// This state cannot dispatch again or be replaced by cancellation.
pub fn captured(value: Occurrence, binding: Binding, attempt: Digest) Error!Occurrence {
    try current(value, binding);
    if (value.state != .dispatching or !equal(value.state.dispatching.id, attempt)) return error.UnsettledOccurrence;
    var next = value;
    next.state = .{ .captured = .{ .id = attempt } };
    return next;
}

pub fn answered(value: Occurrence, binding: Binding, question: Digest, pending_digest: Digest, answer: Digest, reply: Digest, cancellation_pending: bool) Error!Occurrence {
    try current(value, binding);
    if (cancellation_pending) return error.CancellationPending;
    const pending = switch (value.state) {
        .awaiting => |item| item,
        // Historical answer replay belongs to the Store's immutable operation
        // receipt. It never revives or advances a different current occurrence.
        else => return error.QuestionMismatch,
    };
    if (!equal(pending.question, question) or !equal(pending.pending_digest, pending_digest)) return error.QuestionMismatch;
    var next = value;
    next.state = .{ .settled_reply = .{ .attempt = pending.attempt, .reply = reply, .answer = .{
        .question = pending.question,
        .pending_digest = pending.pending_digest,
        .digest = answer,
    } } };
    return next;
}

pub const Control = union(enum) { reply: Digest, cancel };

/// A received client message is not a Control. Only a durably acquired bound
/// reply or an admitted cancellation can retire an external occurrence.
pub fn consumed(value: Occurrence, binding: Binding, control: Control, cancellation_pending: bool) Error!Occurrence {
    try current(value, binding);
    var next = value;
    switch (control) {
        .reply => |reply| {
            if (value.state != .settled_reply or !equal(value.state.settled_reply.reply, reply)) return error.UnsettledOccurrence;
            next.state = .{ .admitted = .{ .reply = value.state.settled_reply } };
        },
        .cancel => {
            if (!cancellation_pending) return error.InvalidControl;
            if (value.state != .ready and value.state != .awaiting and value.state != .not_sent) return error.UnsettledOccurrence;
            next.state = .{ .admitted = .{ .cancelled = if (value.state == .awaiting) value.state.awaiting else null } };
        },
    }
    return next;
}

test "unknown delivery cannot become dispatchable or cancelled without an acquired reply" {
    const binding: Binding = .{ .id = @splat(1), .task = @splat(2), .request = @splat(3) };
    const initial: Occurrence = .{ .id = binding.id, .task = binding.task, .request = binding.request, .request_object = .{ .digest = @splat(0), .bytes = 0 } };
    const sent = try dispatch(initial, binding, @splat(4), false, false);
    const lost = try unknown(sent, binding, @splat(4));
    try std.testing.expectError(error.UnsettledOccurrence, dispatch(lost, binding, @splat(5), false, false));
    try std.testing.expectError(error.UnsettledOccurrence, consumed(lost, binding, .cancel, true));
    const saved = try acquired(lost, binding, @splat(4), @splat(6));
    try std.testing.expectError(error.ReplyConflict, acquired(saved, binding, @splat(4), @splat(7)));
    try std.testing.expectEqualDeep(saved, try acquired(saved, binding, @splat(4), @splat(6)));
    const done = try consumed(saved, binding, .{ .reply = @splat(6) }, true);
    try std.testing.expect(done.state == .admitted);
}

test "question acquisition binds the pending occurrence and serializes against cancellation" {
    const binding: Binding = .{ .id = @splat(1), .task = @splat(2), .request = @splat(3) };
    const initial: Occurrence = .{ .id = binding.id, .task = binding.task, .request = binding.request, .request_object = .{ .digest = @splat(0), .bytes = 0 } };
    const waiting = try awaiting(initial, binding, .{ .attempt = @splat(4), .question = @splat(5), .pending_digest = @splat(6) }, false);
    try std.testing.expectError(error.QuestionMismatch, answered(waiting, binding, @splat(7), @splat(6), @splat(8), @splat(9), false));
    try std.testing.expectError(error.CancellationPending, answered(waiting, binding, @splat(5), @splat(6), @splat(8), @splat(9), true));
    const result = try answered(waiting, binding, @splat(5), @splat(6), @splat(8), @splat(9), false);
    try std.testing.expect(result.state == .settled_reply);
    try std.testing.expectError(error.UnsettledOccurrence, consumed(result, binding, .cancel, true));
    try std.testing.expect((try consumed(waiting, binding, .cancel, true)).state == .admitted);
}

test "positive no-invocation evidence permits cancellation or an explicit rearm, not an unknown retry" {
    const binding: Binding = .{ .id = @splat(1), .task = @splat(2), .request = @splat(3) };
    const initial: Occurrence = .{ .id = binding.id, .task = binding.task, .request = binding.request, .request_object = .{ .digest = @splat(0), .bytes = 0 } };
    const sent = try dispatch(initial, binding, @splat(4), false, false);
    const stopped = try notSent(sent, binding, @splat(4));
    try std.testing.expect((try consumed(stopped, binding, .cancel, true)).state == .admitted);
    try std.testing.expect((try rearm(stopped, binding)).state == .ready);
    try std.testing.expectError(error.UnsettledOccurrence, rearm(try unknown(sent, binding, @splat(4)), binding));
    try std.testing.expectError(error.UnsettledOccurrence, acquired(stopped, binding, @splat(4), @splat(5)));
}

test "durable raw capture can only advance through interpretation, never redispatch or cancellation" {
    const binding: Binding = .{ .id = @splat(1), .task = @splat(2), .request = @splat(3) };
    const initial: Occurrence = .{ .id = binding.id, .task = binding.task, .request = binding.request, .request_object = .{ .digest = @splat(0), .bytes = 0 } };
    const sent = try dispatch(initial, binding, @splat(4), false, false);
    try std.testing.expectError(error.UnsettledOccurrence, captured(sent, binding, @splat(5)));
    const raw = try captured(sent, binding, @splat(4));
    try std.testing.expectError(error.UnsettledOccurrence, dispatch(raw, binding, @splat(5), false, false));
    try std.testing.expectError(error.UnsettledOccurrence, consumed(raw, binding, .cancel, true));
    try std.testing.expectError(error.UnsettledOccurrence, unknown(raw, binding, @splat(4)));
    try std.testing.expectError(error.UnsettledOccurrence, notSent(raw, binding, @splat(4)));
    try std.testing.expectError(error.StaleOccurrence, acquired(raw, binding, @splat(5), @splat(6)));
    const reply = try acquired(raw, binding, @splat(4), @splat(6));
    try std.testing.expect((try consumed(reply, binding, .{ .reply = @splat(6) }, true)).state == .admitted);
}
