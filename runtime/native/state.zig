//! Ordinary, versioned environmental records. Kronos continuations remain the
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
pub const Outcome = enum { progressed, yielded, requested, completed, failed, cancelled };
pub const Schedule = enum { queued, active, parked };
pub const Status = enum { queued, running, waiting_input, parked, cancelling, blocked, unknown, completed, failed, cancelled };
pub const RecordKind = enum { occurrence, question, message, artifact, capture, attempt, origin };
pub const Blocker = enum { missing_capability, denied, capacity, missing_artifact, incompatible_profile, unavailable_environment };

/// Reference metadata is bounded independently of the unchanged payload quota.
pub const maximum_resources = 64;
pub const Task = TaskRecord(maximum_resources);
pub const LegacyTask = TaskRecord(16);

fn TaskRecord(comptime resource_limit: u64) type {
    return struct {
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
        resources: contracts.Vector(Reference, resource_limit) = .{ .items = &.{} },
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
        messages: contracts.Vector(Digest, 16),
        inference_attempts: u32,
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
}

pub const Method = enum { submit, message, respond, cancel, @"resume", import_checkpoint };
pub const Disposition = enum { accepted, queued, answer_acquired, cancellation_requested, resumed, imported };
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
pub fn questionData(a: std.mem.Allocator, question: Question, prompt: []const u8) !json.Value {
    var result = json.object();
    try json.put(a, &result, "question_id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(question.id, .lower))));
    try json.put(a, &result, "question_revision", json.string(try std.fmt.allocPrint(a, "{d}", .{question.revision})));
    try json.put(a, &result, "request_digest", json.string(try a.dupe(u8, &std.fmt.bytesToHex(question.request_digest, .lower))));
    try json.put(a, &result, "answer_schema_id", json.string(try a.dupe(u8, question.answer_schema_id.bytes)));
    try json.put(a, &result, "prompt", (try json.parse(a, prompt, .{ .bytes = 32 * 1024 })).value);
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
        objects: contracts.Vector(Reference, 16),
        output_tokens: ?u64,
    } = null,
};

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
pub const ArchiveReservation = struct { attempt: Digest, bytes: u64 };
pub const ArchiveSchema = struct { name: Name, definition: Reference };
pub const Archive = struct {
    version: u32,
    classification: enum { private },
    profile: enum { offline_copy },
    task: Reference,
    build: Reference,
    schemas: contracts.Vector(ArchiveSchema, 16),
    records: contracts.Vector(ArchiveRecord, 1024),
    events: contracts.Vector(ArchiveEvent, 2048),
    operations: contracts.Vector(ArchiveOperation, 2048),
    reservations: contracts.Vector(ArchiveReservation, 64),
    objects: contracts.Vector(Reference, 4096),
};

test "larger resource capacity preserves legacy task bytes" {
    const a = std.testing.allocator;
    const references: [maximum_resources + 1]Reference = @splat(.{ .digest = @splat(7), .bytes = 3 });
    var legacy = std.mem.zeroes(LegacyTask);
    legacy.resources.items = references[0..16];
    const old_bytes = try contracts.encodeOwned(LegacyTask, a, legacy);
    defer a.free(old_bytes);
    var current = try contracts.decodeOwned(Task, a, old_bytes);
    defer current.deinit();
    const same_bytes = try contracts.encodeOwned(Task, a, current.value);
    defer a.free(same_bytes);
    try std.testing.expectEqualSlices(u8, old_bytes, same_bytes);
    var larger = current.value;
    larger.resources.items = references[0..maximum_resources];
    const new_bytes = try contracts.encodeOwned(Task, a, larger);
    defer a.free(new_bytes);
    var decoded = try contracts.decodeOwned(Task, a, new_bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(maximum_resources, decoded.value.resources.items.len);
    try std.testing.expectError(error.InvalidValue, contracts.decodeOwned(LegacyTask, a, new_bytes));
    larger.resources.items = &references;
    try std.testing.expectError(error.InvalidValue, contracts.encodeOwned(Task, a, larger));
}
