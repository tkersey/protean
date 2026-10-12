//! Ordinary, versioned environmental records. Kosmos continuations remain the
//! existing BPI3/PST3/PKO3 artifacts, never native pointers or application phases.
const contracts = @import("protean_contracts");
const std = @import("std");
const json = @import("json.zig");
const occurrence = @import("occurrence.zig");
pub const Digest = occurrence.Digest;
pub const TaskId = occurrence.TaskId;
pub const Name = contracts.Text(128);
pub const Reason = contracts.Text(256);
pub const Reference = struct { digest: Digest, bytes: u64 };
/// Declared host references are the shared source for archive closure and
/// Store retention. Opaque payloads need their registered application codec;
/// byte arrays and JSON never acquire reference meaning from their shape.
pub fn visitReferences(comptime T: type, value: T, collector: anytype) anyerror!void {
    return visitReferencesAs(T, Reference, value, collector);
}
/// Application codecs supply their exact nominal reference type. Matching
/// field names alone never makes an unrelated application value a reference.
pub fn visitReferencesAs(comptime T: type, comptime Ref: type, value: T, collector: anytype) anyerror!void {
    if (T == Ref) return collector.add(.{ .digest = value.digest, .bytes = value.bytes });
    if (T == occurrence.Acquired) try collector.reply(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| try visitReferencesAs(Field, Ref, @field(value, name), collector),
        .optional => |info| if (value) |child| try visitReferencesAs(info.child, Ref, child, collector),
        .@"union" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            if (std.mem.eql(u8, @tagName(value), name)) try visitReferencesAs(Field, Ref, @field(value, name), collector);
        },
        .pointer => |info| if (info.size == .slice and info.child != u8) {
            for (value) |child| try visitReferencesAs(info.child, Ref, child, collector);
        },
        .array => |info| if (info.child != u8) {
            for (value) |child| try visitReferencesAs(info.child, Ref, child, collector);
        },
        else => {},
    }
}
pub const Outcome = enum { progressed, yielded, requested, completed, failed, cancelled };
pub const Schedule = enum { queued, active, parked };
pub const Status = enum { queued, running, waiting_input, parked, cancelling, blocked, unknown, completed, failed, cancelled };
pub const RecordKind = enum { occurrence, question, message, artifact, capture, attempt, origin, reconciliation };
pub const Blocker = enum { missing_capability, denied, capacity, missing_artifact, incompatible_profile, unavailable_environment };

/// Growing task metadata retains immutable object identities without a count quota.
pub const Task = struct {
    id: TaskId,
    application_id: Name,
    input_schema_id: Name,
    output_schema_id: Name,
    failure_schema_id: Name,
    message_schema_id: Name,
    principal: Name,
    tenant: Name,
    profile_id: Name,
    profile: Reference,
    resources: contracts.Vector(Reference, null) = .{ .items = &.{} },
    image: Reference,
    runtime_identity: Digest,
    input: Reference,
    checkpoint: Reference,
    outcome: Reference,
    outcome_kind: Outcome,
    current_occurrence: ?Digest,
    revision: u64,
    execution_revision: u64,
    schedule: Schedule,
    cancellation: ?Reason,
    cancellation_applied: bool,
    blocker: ?Blocker,
    result: ?Reference,
    client_result: ?Reference,
    result_artifact: ?Digest,
    event_floor: u64,
    event_high: u64,
    next_message: u64,
    messages: contracts.Vector(Digest, null),
    inference_attempts: u64,
    inference_request_bytes: u64,
    inference_output_tokens: u64,
    evidence_bytes: u64,

    pub fn terminal(task: @This()) bool {
        return switch (task.outcome_kind) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const Method = enum { submit, message, respond, cancel, @"resume", import_checkpoint, reconcile };
pub const Disposition = enum { accepted, queued, answer_acquired, cancellation_requested, resumed, imported, reconciled };
pub const Receipt = struct {
    id: Digest,
    client_operation_id: Name,
    method: Method,
    request_digest: Digest,
    task: TaskId,
    revision: u64,
    disposition: Disposition,
    message: ?Digest = null,
    question: ?Digest = null,
    reconciliation: ?Digest = null,
};

pub const Question = struct {
    id: Digest,
    task: TaskId,
    occurrence: Digest,
    revision: u64,
    request_digest: Digest,
    pending_digest: Digest,
    answer_schema_id: Name,
    answer_schema_digest: Digest,
    request: Reference,
    prompt: Reference,
    answer: ?Reference,
    receipt: ?Receipt,
    retired: bool,
};

pub const MessageDisposition = enum { queued, acquired, consumed, not_consumed };
pub const Message = struct {
    id: Digest,
    task: TaskId,
    ordinal: u64,
    schema_id: Name,
    value: Reference,
    disposition: MessageDisposition,
    occurrence: ?Digest,
};

/// The immutable part of a question's public projection survives retirement.
/// The caller supplies the retained prompt object, never a current pending slot.
pub fn questionPromptReference(a: std.mem.Allocator, question: Question) !json.Value {
    var ref = json.object();
    const digest = try a.dupe(u8, &std.fmt.bytesToHex(question.prompt.digest, .lower));
    try json.put(a, &ref, "artifact_id", json.string(digest));
    try json.put(a, &ref, "sha256", json.string(digest));
    try json.put(a, &ref, "bytes", json.string(try std.fmt.allocPrint(a, "{d}", .{question.prompt.bytes})));
    try json.put(a, &ref, "media_type", json.string("application/json"));
    try json.put(a, &ref, "schema_id", json.string("agent-native-question-prompt.v1"));
    try json.put(a, &ref, "retention", json.string("state-namespace"));
    try json.put(a, &ref, "question_id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(question.id, .lower))));
    return ref;
}

pub fn questionData(a: std.mem.Allocator, question: Question, prompt: []const u8) !json.Value {
    var result = json.object();
    try json.put(a, &result, "question_id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(question.id, .lower))));
    try json.put(a, &result, "question_revision", json.string(try std.fmt.allocPrint(a, "{d}", .{question.revision})));
    try json.put(a, &result, "request_digest", json.string(try a.dupe(u8, &std.fmt.bytesToHex(question.request_digest, .lower))));
    try json.put(a, &result, "answer_schema_id", json.string(try a.dupe(u8, question.answer_schema_id.bytes)));
    // Prompt bytes come from the owner's canonical JSON presentation. Do not
    // materialize a second large value just to choose a bounded public view.
    if (prompt.len <= json.payload_limits.bytes) {
        const parsed = json.parse(a, prompt, json.payload_limits) catch |err| switch (err) {
            error.Capacity => null,
            else => return err,
        };
        if (parsed) |inline_prompt| {
            try json.put(a, &result, "prompt", inline_prompt.value);
            if (try json.fits(a, result, json.payload_limits)) return result;
            _ = result.object.swapRemove("prompt");
        }
    }
    try json.put(a, &result, "prompt_ref", try questionPromptReference(a, question));
    return result;
}

pub fn messageData(a: std.mem.Allocator, message: Message, disposition: MessageDisposition) !json.Value {
    var result = json.object();
    try json.put(a, &result, "message_id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(message.id, .lower))));
    try json.put(a, &result, "ordinal", json.string(try std.fmt.allocPrint(a, "{d}", .{message.ordinal})));
    try json.put(a, &result, "disposition", json.string(@tagName(disposition)));
    return result;
}

pub const EventType = enum {
    accepted,
    input_required,
    input_accepted,
    message_queued,
    message_consumed,
    message_not_consumed,
    cancellation_requested,
    parked,
    resumed,
    blocked,
    delivery_unknown,
    completed,
    failed,
    cancelled,
    imported,
    reconciled,
};
pub const Event = struct {
    task: TaskId,
    seq: u64,
    revision: u64,
    kind: EventType,
    /// An admitted public projection. Raw provider captures and checkpoints do
    /// not enter this field or acquire artifact-read permission by their digest.
    data: contracts.Bytes(48 * 1024),
};

pub const Artifact = struct {
    id: Digest,
    task: ?TaskId,
    value: Reference,
    media_type: contracts.Text(128),
    schema_id: ?Name,
};

pub const CaptureDisposition = enum { complete, definitely_not_sent, unknown };
pub const Attempt = struct {
    id: Digest,
    task: TaskId,
    occurrence: Digest,
    request: Reference,
    profile: Reference,
    capability: Name,
    inference: bool,
    prepared: ?Reference = null,
};
pub const Capture = struct {
    task: TaskId,
    occurrence: Digest,
    attempt: Digest,
    request: Reference,
    response: ?Reference,
    disposition: CaptureDisposition,
    /// Published with occurrence settlement. Archive traversal follows every
    /// replay object instead of guessing references inside opaque reply bytes.
    projection: ?struct {
        reply: Reference,
        objects: contracts.Vector(Reference, null),
        output_tokens: ?u64,
    } = null,
    reconciliation: ?Digest = null,
};

/// Recovery is a new observation about one original attempt. The original
/// ambiguous occurrence and every predecessor body remain private audit roots.
pub const RecoveryRequest = enum { rederive, lookup };
pub const Reconciliation = struct {
    version: u32 = 1,
    id: Digest,
    task: TaskId,
    client_operation_id: Name,
    request_digest: Digest,
    admission_revision: u64,
    occurrence: Digest,
    attempt: Digest,
    original_occurrence: Reference,
    original_attempt: Reference,
    original_capture: ?Reference = null,
    request: Reference,
    prepared: ?Reference,
    profile: Reference,
    resources: contracts.Vector(Reference, null),
    capability: Name,
    mechanism: Name,
    mechanism_version: u32,
    provenance: enum { none, rederived, authentic, authoritative },
    outcome: union(enum) {
        unresolved: enum { unsupported, unavailable, interrupted, inconclusive, rejected },
        capture_admitted: Reference,
        reply_settled: Reference,
        pending,
        not_sent: Reference,
    },
    previous: ?Reference = null,
    selection: RecoveryRequest = .rederive,
    owner_epoch: ?Digest = null,
    evidence: ?Reference = null,
};

/// Decode historical owners instead of trusting dependency rows or treating
/// their content hashes as sufficient proof of the retained closure.
pub fn visitReconciliationHistory(a: std.mem.Allocator, store: anytype, current: Reconciliation, collector: anytype) anyerror!void {
    if (current.version != 1 or current.admission_revision == 0) return error.CorruptState;
    const occurrence_bytes = try store.object(a, current.original_occurrence, null);
    defer a.free(occurrence_bytes);
    var original = try contracts.decodeOwned(occurrence.Occurrence, a, occurrence_bytes);
    defer original.deinit();
    if (!std.meta.eql(original.value.task, current.task) or !std.meta.eql(original.value.id, current.occurrence) or original.value.state != .unknown or !std.meta.eql(original.value.state.unknown.id, current.attempt) or !std.meta.eql(original.value.request_object, current.request)) return error.CorruptState;
    try collector.typed(occurrence.Occurrence, current.original_occurrence, original.value);
    const attempt_bytes = try store.object(a, current.original_attempt, null);
    defer a.free(attempt_bytes);
    var attempt = try contracts.decodeOwned(Attempt, a, attempt_bytes);
    defer attempt.deinit();
    if (!std.meta.eql(attempt.value.task, current.task) or !std.meta.eql(attempt.value.id, current.attempt) or !std.meta.eql(attempt.value.occurrence, current.occurrence) or !std.meta.eql(attempt.value.request, current.request) or !std.meta.eql(attempt.value.prepared, current.prepared) or !std.meta.eql(attempt.value.profile, current.profile) or !std.mem.eql(u8, attempt.value.capability.bytes, current.capability.bytes)) return error.CorruptState;
    try collector.typed(Attempt, current.original_attempt, attempt.value);
    if (current.original_capture) |ref| {
        const bytes = try store.object(a, ref, null);
        defer a.free(bytes);
        var captured = try contracts.decodeOwned(Capture, a, bytes);
        defer captured.deinit();
        if (!std.meta.eql(captured.value.task, current.task) or !std.meta.eql(captured.value.attempt, current.attempt) or !std.meta.eql(captured.value.occurrence, current.occurrence) or current.prepared == null or !std.meta.eql(captured.value.request, current.prepared.?) or captured.value.projection != null) return error.CorruptState;
        try collector.typed(Capture, ref, captured.value);
    }
    if (current.selection == .rederive and (current.owner_epoch != null or current.evidence != null)) return error.CorruptState;
    switch (current.outcome) {
        .pending => if (current.selection != .lookup or current.owner_epoch == null or current.provenance != .none or current.previous != null or current.evidence != null) return error.CorruptState,
        .unresolved => if (current.provenance != .none) return error.CorruptState,
        .capture_admitted, .reply_settled => {
            const provenance: @FieldType(Reconciliation, "provenance") = if (current.selection == .rederive) .rederived else .authentic;
            if (current.provenance != provenance) return error.CorruptState;
            if (current.outcome == .capture_admitted and current.prepared == null) return error.CorruptState;
            if (current.selection == .lookup and (current.evidence == null or current.owner_epoch == null)) return error.CorruptState;
        },
        .not_sent => |proof| if (current.selection != .lookup or current.provenance != .authoritative or current.evidence == null or !std.meta.eql(proof, current.evidence.?) or current.owner_epoch == null) return error.CorruptState,
    }
    if (current.outcome != .pending and current.owner_epoch != null and current.previous == null) return error.CorruptState;
    if (current.selection == .rederive and current.outcome != .reply_settled and current.previous != null) return error.CorruptState;
    if (current.previous) |ref| {
        const bytes = try store.object(a, ref, null);
        defer a.free(bytes);
        var prior = try contracts.decodeOwned(Reconciliation, a, bytes);
        defer prior.deinit();
        // The transition graph is acyclic: pending -> completed, and then
        // capture_admitted -> reply_settled. No history-depth quota is needed.
        if (prior.value.outcome == .pending) {
            if (current.outcome == .pending or current.outcome == .reply_settled) return error.CorruptState;
        } else if (prior.value.outcome == .capture_admitted) {
            if (current.outcome != .reply_settled or current.provenance != prior.value.provenance or !std.meta.eql(current.evidence, prior.value.evidence)) return error.CorruptState;
        } else return error.CorruptState;
        var normalized = current;
        normalized.outcome = prior.value.outcome;
        normalized.previous = prior.value.previous;
        normalized.provenance = prior.value.provenance;
        normalized.evidence = prior.value.evidence;
        const expected = try contracts.encodeOwned(Reconciliation, a, normalized);
        defer a.free(expected);
        if (!std.mem.eql(u8, expected, bytes)) return error.CorruptState;
        try collector.typed(Reconciliation, ref, prior.value);
        try visitReconciliationHistory(a, store, prior.value, collector);
    }
}

pub const Origin = struct {
    id: Digest,
    task: TaskId,
    build: Reference,
    native_identity: Digest,
    source_revision: u64,
};

/// Environmental archive metadata uses the existing ordinary Protean codec.
/// Its payload objects retain their canonical image/state/value bytes.
pub const ArchiveRecord = struct { kind: RecordKind, id: Digest, body: Reference };
pub const ArchiveEvent = struct { seq: u64, revision: u64, body: Reference };
pub const ArchiveOperation = struct { key: Name, request: Digest, body: Reference };
pub const ArchiveSchema = struct { name: Name, definition: Reference };
pub const Archive = struct {
    version: u32,
    classification: enum { private },
    profile: enum { offline_copy },
    task: Reference,
    build: Reference,
    schemas: contracts.Vector(ArchiveSchema, null),
    records: contracts.Vector(ArchiveRecord, null),
    events: contracts.Vector(ArchiveEvent, null),
    operations: contracts.Vector(ArchiveOperation, null),
    objects: contracts.Vector(Reference, null),
};

test "task metadata retains resource and input identities past former capacities" {
    const a = std.testing.allocator;
    const references: [65]Reference = @splat(.{ .digest = @splat(7), .bytes = 3 });
    const messages: [17]Digest = @splat(@splat(8));
    var task = std.mem.zeroes(Task);
    task.resources.items = &references;
    task.messages.items = &messages;
    const bytes = try contracts.encodeOwned(Task, a, task);
    defer a.free(bytes);
    var decoded = try contracts.decodeOwned(Task, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(task.resources, decoded.value.resources);
    try std.testing.expectEqualDeep(task.messages, decoded.value.messages);
}
