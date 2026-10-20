//! Durable bilateral decisions and per-subject custody share the native
//! namespace transaction and crash seal. Transport acknowledgments do not.
const std = @import("std");
const contracts = @import("protean_contracts");
const storage = @import("store.zig");
const state = @import("state.zig");
const p = @import("placement.zig");

pub fn custody(store: *storage.Store, a: std.mem.Allocator, subject: p.Subject) !?contracts.Decoded(p.Custody) {
    const bytes = try store.recordBytes(a, "placement_custody", p.subjectId(subject), subject.task) orelse return null;
    defer a.free(bytes);
    var result = try contracts.decodeOwned(p.Custody, a, bytes);
    errdefer result.deinit();
    if (!std.meta.eql(result.value.task, subject.task) or !std.meta.eql(result.value.work, subject.work) or
        !std.meta.eql(result.value.id, p.subjectId(subject))) return error.CorruptState;
    return result;
}

pub fn putCustody(store: *storage.Store, a: std.mem.Allocator, value: p.Custody) !void {
    var prior = try custody(store, a, .{ .task = value.task, .work = value.work });
    defer if (prior) |*record| record.deinit();
    if (prior) |record| try retainCustodyDecision(store, a, record.value);
    try retainCustodyDecision(store, a, value);
    if (value.phase == .frozen) {
        const intent = value.intent orelse return error.InvalidTransfer;
        if (try decision(store, a, intent.transfer)) |record| {
            var decided = record;
            defer decided.deinit();
            return error.OperationConflict;
        }
        try requireCompatibleIntent(store, a, intent);
    }
    // Snapshot retirement is part of the same native custody transition.
    if (value.phase != .frozen) {
        if (try store.recordBytes(a, "placement_snapshot", value.id, value.task)) |bytes| {
            defer a.free(bytes);
            var snapshot = try contracts.decodeOwned(p.Snapshot, a, bytes);
            defer snapshot.deinit();
            if (snapshot.value.frozen != null) {
                snapshot.value.frozen = null;
                try store.putRecord(p.Snapshot, "placement_snapshot", value.id, value.task, snapshot.value);
            }
        }
    }
    if (value.decision) |signed| if (signed.value.verdict == .accepted) {
        const offer = value.offer orelse return error.InvalidTransfer;
        const succession: p.Succession = .{ .id = signed.value.transfer, .task = value.task, .offer = offer, .decision = signed };
        if (try store.recordBytes(a, "placement_succession", succession.id, succession.task)) |bytes| {
            defer a.free(bytes);
            var prior_proof = try contracts.decodeOwned(p.Succession, a, bytes);
            defer prior_proof.deinit();
            if (!std.meta.eql(prior_proof.value, succession)) return error.OperationConflict;
        } else try store.createRecord(p.Succession, "placement_succession", succession.id, succession.task, succession);
    };
    if (prior != null) {
        try store.putRecord(p.Custody, "placement_custody", value.id, value.task, value);
    } else try store.createRecord(p.Custody, "placement_custody", value.id, value.task, value);
}

fn retainCustodyDecision(store: *storage.Store, a: std.mem.Allocator, value: p.Custody) !void {
    const signed = value.decision orelse return;
    const offer = value.offer orelse return error.InvalidTransfer;
    try p.verify(p.Offer, a, offer, offer.value.intent.source);
    try retainDecision(store, a, offer.value, signed);
}

fn requireCompatibleIntent(store: *storage.Store, a: std.mem.Allocator, intent: p.Intent) !void {
    var rows = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_custody'", &.{});
    defer rows.deinit();
    while (try rows.step() == .row) {
        var other = try contracts.decodeOwned(p.Custody, a, try rows.bytes(0));
        defer other.deinit();
        if (other.value.phase != .frozen) continue;
        const retained = other.value.intent orelse return error.InvalidTransfer;
        if (std.meta.eql(retained.transfer, intent.transfer) and !std.meta.eql(retained, intent)) return error.OperationConflict;
    }
}

pub fn controllerLineage(store: *storage.Store, a: std.mem.Allocator, task: state.TaskId) ![]p.ControllerTransition {
    var list: std.ArrayList(p.ControllerTransition) = .empty;
    errdefer list.deinit(a);
    var rows = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_succession' AND r.task=?", &.{.{ .blob = &task }});
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try contracts.decodeOwned(p.Succession, a, try rows.bytes(0));
        defer saved.deinit();
        if (saved.value.offer.value.intent.subject.work == null) try list.append(a, .{ .move = saved.value });
    }
    var behaviors = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_behavior' AND r.task=?", &.{.{ .blob = &task }});
    defer behaviors.deinit();
    while (try behaviors.step() == .row) {
        var saved = try contracts.decodeOwned(p.BehaviorRecord, a, try behaviors.bytes(0));
        defer saved.deinit();
        try list.append(a, .{ .behavior = saved.value.decision });
    }
    std.mem.sort(p.ControllerTransition, list.items, {}, struct {
        fn less(_: void, lhs: p.ControllerTransition, rhs: p.ControllerTransition) bool {
            return lhs.epoch() < rhs.epoch();
        }
    }.less);
    return list.toOwnedSlice(a);
}

pub fn control(store: *storage.Store, a: std.mem.Allocator, task: state.TaskId, id: p.Digest) !?contracts.Decoded(p.ControlRecord) {
    const bytes = try store.recordBytes(a, "placement_control", id, task) orelse return null;
    defer a.free(bytes);
    var result = try contracts.decodeOwned(p.ControlRecord, a, bytes);
    errdefer result.deinit();
    if (!std.meta.eql(result.value.id, id) or !std.meta.eql(result.value.task, task) or
        !std.meta.eql(p.controlId(result.value.control.value), id)) return error.CorruptState;
    return result;
}

pub fn nextExecutor(store: *storage.Store, a: std.mem.Allocator, subject: p.Subject, current: p.Executor) !?p.Succession {
    var rows = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_succession' AND r.task=?", &.{.{ .blob = &subject.task }});
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try contracts.decodeOwned(p.Succession, a, try rows.bytes(0));
        defer saved.deinit();
        const intent = saved.value.offer.value.intent;
        if (!std.meta.eql(intent.subject, subject) or !std.meta.eql(intent.source, current.site) or intent.epoch != current.epoch) continue;
        _ = try p.routeNext(a, subject, current, saved.value);
        return saved.value;
    }
    return null;
}

pub fn putControl(store: *storage.Store, a: std.mem.Allocator, value: p.ControlRecord) !void {
    var prior = try control(store, a, value.task, value.id);
    defer if (prior) |*saved| saved.deinit();
    if (prior != null) {
        try store.putRecord(p.ControlRecord, "placement_control", value.id, value.task, value);
    } else try store.createRecord(p.ControlRecord, "placement_control", value.id, value.task, value);
}

pub fn requireSettled(store: *storage.Store, a: std.mem.Allocator, subject: p.Subject, site: p.Site) !void {
    var controller = try custody(store, a, .{ .task = subject.task });
    defer if (controller) |*saved| saved.deinit();
    const controller_site = if (controller) |saved| saved.value.owner else site;
    const controller_epoch = if (controller) |saved| saved.value.epoch else 0;
    var rows = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_control' AND r.task=?", &.{.{ .blob = &subject.task }});
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try contracts.decodeOwned(p.ControlRecord, a, try rows.bytes(0));
        defer saved.deinit();
        if (saved.value.report != null) continue;
        const message = saved.value.control.value;
        if (subject.work != null and !std.meta.eql(message.subject, subject)) continue;
        if (!std.meta.eql(message.controller, controller_site) or message.controller_epoch != controller_epoch) continue;
        if (std.meta.eql(message.controller, site)) return error.UnsettledRemoteControl;
        const head = try p.routeHead(a, message, saved.value.route.items);
        if (!std.meta.eql(head.site, site)) continue;
        var executor = try custody(store, a, message.subject);
        defer if (executor) |*current| current.deinit();
        if (executor) |current| {
            if (std.meta.eql(current.value.owner, site) and current.value.epoch == head.epoch and
                (current.value.phase == .local or current.value.phase == .frozen)) return error.UnsettledRemoteControl;
        }
        // A copied pending record at another executor is historical evidence,
        // not an obligation this namespace can settle.
    }
}

pub fn decision(store: *storage.Store, a: std.mem.Allocator, transfer: p.Digest) !?contracts.Decoded(p.Signed(p.Decision)) {
    try store.checkIntegrity();
    var row = try store.database.prepare("SELECT body FROM placement_decisions WHERE transfer=?", &.{.{ .blob = &transfer }});
    defer row.deinit();
    if (try row.step() != .row) return null;
    var result = try contracts.decodeOwned(p.Signed(p.Decision), a, try row.bytes(0));
    errdefer result.deinit();
    if (!std.meta.eql(result.value.value.transfer, transfer)) return error.CorruptState;
    return result;
}

/// Caller owns an open transaction. The unique transfer key makes acceptance
/// and refusal mutually exclusive, including after restart or a lost reply.
/// A refusal remains durable even when no task was admitted at this site.
pub fn putDecision(store: *storage.Store, a: std.mem.Allocator, site: p.Site, offer: p.Offer, signed: p.Signed(p.Decision)) !void {
    if (!std.meta.eql(site, signed.value.destination)) return error.InvalidTransfer;
    try retainDecision(store, a, offer, signed);
}

fn retainDecision(store: *storage.Store, a: std.mem.Allocator, offer: p.Offer, signed: p.Signed(p.Decision)) !void {
    if (!store.transaction or store.projecting or store.fenced) return error.InvalidState;
    try p.matchDecision(a, offer, signed);
    try requireCompatibleIntent(store, a, offer.intent);
    if (try decision(store, a, signed.value.transfer)) |saved| {
        var prior = saved;
        defer prior.deinit();
        if (!std.meta.eql(prior.value, signed)) return error.OperationConflict;
        return;
    }
    const bytes = try contracts.encodeOwned(p.Signed(p.Decision), a, signed);
    defer a.free(bytes);
    try store.database.run("INSERT INTO placement_decisions VALUES(?,?)", &.{ .{ .blob = &signed.value.transfer }, .{ .blob = bytes } });
}
