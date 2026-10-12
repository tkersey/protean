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
    if (T == Reference) return collector.add(value);
    if (T == occurrence.Acquired) try collector.reply(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| try visitReferences(Field, @field(value, name), collector),
        .optional => |info| if (value) |child| try visitReferences(info.child, child, collector),
        .@"union" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            if (std.mem.eql(u8, @tagName(value), name)) try visitReferences(Field, @field(value, name), collector);
        },
        .pointer => |info| if (info.size == .slice and info.child != u8) {
            for (value) |child| try visitReferences(info.child, child, collector);
        },
        .array => |info| if (info.child != u8) {
            for (value) |child| try visitReferences(info.child, child, collector);
        },
        else => {},
    }
}
pub const Outcome = enum { progressed, yielded, requested, completed, failed, cancelled };
pub const Schedule = enum { queued, active, parked };
pub const Status = enum { queued, running, waiting_input, parked, cancelling, blocked, unknown, completed, failed, cancelled };
pub const RecordKind = enum { occurrence, question, message, artifact, capture, attempt, origin };
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
