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
    if (value.decision) |signed| if (signed.value.verdict == .accepted) {
        const offer = value.offer orelse return error.InvalidTransfer;
        try p.verify(p.Offer, a, offer, offer.value.intent.source);
        try p.matchDecision(a, offer.value, signed);
        const succession: p.Succession = .{ .id = signed.value.transfer, .task = value.task, .offer = offer, .decision = signed };
        if (try store.recordBytes(a, "placement_succession", succession.id, succession.task)) |bytes| {
            defer a.free(bytes);
            var prior_proof = try contracts.decodeOwned(p.Succession, a, bytes);
            defer prior_proof.deinit();
            if (!std.meta.eql(prior_proof.value, succession)) return error.OperationConflict;
        } else try store.createRecord(p.Succession, "placement_succession", succession.id, succession.task, succession);
    };
    var prior = try custody(store, a, .{ .task = value.task, .work = value.work });
    defer if (prior) |*record| record.deinit();
    if (prior != null) {
        try store.putRecord(p.Custody, "placement_custody", value.id, value.task, value);
    } else try store.createRecord(p.Custody, "placement_custody", value.id, value.task, value);
}

pub fn controllerLineage(store: *storage.Store, a: std.mem.Allocator, task: state.TaskId) ![]p.Succession {
    var list: std.ArrayList(p.Succession) = .empty;
    errdefer list.deinit(a);
    var rows = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_succession' AND r.task=?", &.{.{ .blob = &task }});
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try contracts.decodeOwned(p.Succession, a, try rows.bytes(0));
        defer saved.deinit();
        if (saved.value.offer.value.intent.subject.work == null) try list.append(a, saved.value);
    }
    std.mem.sort(p.Succession, list.items, {}, struct {
        fn less(_: void, lhs: p.Succession, rhs: p.Succession) bool {
            return lhs.decision.value.epoch < rhs.decision.value.epoch;
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

pub fn putControl(store: *storage.Store, a: std.mem.Allocator, value: p.ControlRecord) !void {
    var prior = try control(store, a, value.task, value.id);
    defer if (prior) |*saved| saved.deinit();
    if (prior != null) {
        try store.putRecord(p.ControlRecord, "placement_control", value.id, value.task, value);
    } else try store.createRecord(p.ControlRecord, "placement_control", value.id, value.task, value);
}

pub fn requireSettled(store: *storage.Store, a: std.mem.Allocator, subject: p.Subject) !void {
    var rows = try store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.kind='placement_control' AND r.task=?", &.{.{ .blob = &subject.task }});
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try contracts.decodeOwned(p.ControlRecord, a, try rows.bytes(0));
        defer saved.deinit();
        if (saved.value.report == null and (subject.work == null or std.meta.eql(saved.value.control.value.subject, subject))) return error.UnsettledRemoteControl;
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
    if (!store.transaction or store.projecting or store.fenced) return error.InvalidState;
    if (!std.meta.eql(site, signed.value.destination)) return error.InvalidTransfer;
    try p.matchDecision(a, offer, signed);
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
