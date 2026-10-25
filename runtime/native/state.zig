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
    if (T == @import("workspace_state.zig").Observer.Incomplete)
        try collector.observerSource(value.source);
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

pub fn visitObserverSource(a: std.mem.Allocator, store: anytype, ref: Reference, collector: anytype) anyerror!void {
    const bytes = try store.object(a, ref, null);
    defer a.free(bytes);
    const T = @import("workspace_state.zig").WorkObservation;
    var decoded = try contracts.decodeOwned(T, a, bytes);
    defer decoded.deinit();
    try collector.typed(T, ref, decoded.value);
}
pub const Outcome = enum { progressed, yielded, requested, completed, failed, cancelled };
pub const Schedule = enum { queued, active, parked };
pub const Status = enum { queued, running, waiting_input, parked, cancelling, blocked, unknown, completed, failed, cancelled };
/// Portable task records. Source-local retention records are not archive kinds.
pub const RecordKind = enum { occurrence, question, message, artifact, capture, attempt, origin, reconciliation, workspace_program, workspace_work, workspace_value, workspace_view, workspace_port, workspace_port_reply, execution_route, workspace_wait, workspace_delegation, workspace_reply, workspace_runtime, placement_custody, placement_control, placement_action, placement_move, placement_succession, root_operation, controller_binding, controller_interaction, controller_succession, controller_residual, placement_behavior, workspace_trial, workspace_candidate };
pub const Blocker = enum { missing_capability, denied, capacity, missing_artifact, incompatible_profile, unavailable_environment, waiting_workspace, observation_blocked };

/// Physical controller progress is independent of the last published guest cut.
/// This row is replaced on suspension and cleared atomically with the next cut.
pub const OuterOperation = struct {
    capsule: Reference,
    dependencies: contracts.Vector(Reference, null),
    control: Reference,
    guest_quantum: u64,
};
pub const RootOperation = struct {
    id: Digest,
    task: TaskId,
    execution_revision: u64,
    pending: ?OuterOperation,
};

/// Growing task metadata retains immutable object identities without a count quota.
pub const ControllerBinding = struct {
    id: Digest,
    task: TaskId,
    epoch: u64,
    activated_at: u64 = 1,
    program: Digest,
    image: Reference,
    program_identity: Digest,
    predecessor: ?Digest,
};

pub const ControllerInteraction = struct {
    id: Digest,
    task: TaskId,
    controller: Digest,
    epoch: u64,
    offered: Reference,
    carry: Reference,
    carry_schema: Reference,
    overlay: Reference,
    event_cut: u64,
    next_message: u64,
    policy: Reference,
    model: ?Digest = null,
    handoff: ?Digest = null,
};
pub const ControllerSuccession = struct {
    id: Digest,
    task: TaskId,
    command: Reference,
    predecessor: Digest,
    handoff: Digest,
    checkpoint: Reference,
    outcome: Reference,
    event_cut: u64,
    next_message: u64,
    policy: Reference,
    successor: ?Digest = null,
    converter: ?Digest = null,
    conversion_input: ?Reference = null,
    view_works: contracts.Vector(@import("workspace_state.zig").WorkObservation, null) = .{ .items = &.{} },
    conversion_work: ?Digest = null,
    converted: ?Reference = null,
    boot: ?struct { checkpoint: Reference, outcome: Reference } = null,
    phase: enum { preparing, ready, activated, rejected, aborted, blocked, failed },
    diagnostic: ?contracts.controller.Diagnostic = null,
    activation_event: ?u64 = null,
    activated_epoch: ?u64 = null,
    residual: ?Digest = null,
    operator_admission: ?struct { revision: u64, event: u64, occurrence: @import("occurrence.zig").Occurrence } = null,
};
pub const ControllerAdoptionRequest = struct {
    method: Method = .adopt,
    task: TaskId,
    revision: u64,
    command: contracts.workspace.Adoption,
};
pub const ControllerResidual = struct {
    id: Digest,
    task: TaskId,
    controller: Digest,
    succession: Digest,
    initial_checkpoint: Reference,
    checkpoint: Reference,
    outcome: Reference,
    outcome_kind: Outcome,
    current_occurrence: ?Digest,
    execution_revision: u64,
    control_revision: u64 = 1,
    cancellation_applied: bool = false,
    schedule: Schedule = .queued,
    blocker: ?Blocker = null,
    outer_operation: ?OuterOperation = null,
    runtime: ?Reference = null,
};

pub const ControllerResidualObservation = struct {
    id: Digest,
    task: TaskId,
    controller: Digest,
    succession: Digest,
    initial_checkpoint: Reference,
    checkpoint: Reference,
    outcome: Reference,
    outcome_kind: Outcome,
    current_occurrence: ?Digest,
    execution_revision: u64,
    control_revision: u64,
    cancellation_applied: bool,
    schedule: Schedule,
    blocker: ?Blocker,

    runtime: ?Reference = null,

    pub fn from(value: ControllerResidual) ControllerResidualObservation {
        var result: ControllerResidualObservation = undefined;
        inline for (@typeInfo(ControllerResidualObservation).@"struct".field_names) |field| @field(result, field) = @field(value, field);
        return result;
    }

    pub fn retained(value: ControllerResidualObservation) ControllerResidual {
        var result: ControllerResidual = undefined;
        inline for (@typeInfo(ControllerResidualObservation).@"struct".field_names) |field| @field(result, field) = @field(value, field);
        result.outer_operation = null;
        return result;
    }
};

pub const ResidualPublication = struct {
    value: ControllerResidualObservation,
    occurrence: ?@import("occurrence.zig").Occurrence,
};

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
    controller: ?Digest = null,
    controller_epoch: u64 = 0,
    controller_interaction: ?Digest = null,
    controller_succession: ?Digest = null,
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
    controller_runtime: ?Reference = null,
    realization_revision: u64 = 0,
    observers_present: bool = false,
    observer_heads: contracts.Vector(Digest, null) = .{ .items = &.{} },

    pub fn terminal(task: @This()) bool {
        return switch (task.outcome_kind) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const Method = enum { submit, message, respond, cancel, @"resume", import_checkpoint, reconcile, workspace, adopt };
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
    workspace: ?Digest = null,
    workspace_kind: ?@FieldType(contracts.workspace.Ref, "kind") = null,
    workspace_observation: ?Reference = null,
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
    workspace,
    workspace_progress,
    workspace_read,
    controller,
    controller_requested,
    execution,
};
pub const ControllerReadCut = struct {
    event_watermark: u64,
    execution_revision: u64,

    pub fn from(task: Task) ControllerReadCut {
        return .{ .event_watermark = task.event_high, .execution_revision = task.execution_revision };
    }
};

pub const Event = struct {
    task: TaskId,
    seq: u64,
    revision: u64,
    kind: EventType,
    /// An admitted public projection. Raw provider captures and checkpoints do
    /// not enter this field or acquire artifact-read permission by their digest.
    data: contracts.Bytes(48 * 1024),
    /// Native publication bindings, separate from the public event projection.
    /// Snapshots still require checkpoint, occurrence, and provenance validation.
    workspace_publications: contracts.Vector(WorkPublication, null) = .{ .items = &.{} },
    workspace_command: ?Reference = null,
    residual_publications: contracts.Vector(ResidualPublication, null) = .{ .items = &.{} },
    controller_read: ?ControllerReadCut = null,
    root_publication: ?RootPublication = null,
};

pub const RootCut = struct {
    controller: ?Digest,
    checkpoint: Digest,

    pub fn from(task: Task) RootCut {
        return .{ .controller = task.controller, .checkpoint = task.checkpoint.digest };
    }
};

pub const RootPublication = struct {
    before: RootCut,
    after: RootCut,
};

pub const RootHistory = struct {
    advances: u64 = 0,
    origin: ?u64,
    cut: ?RootCut = null,
    advance_revision: u64 = 0,
    previous_revision: u64 = 0,

    pub fn init(task: Task) RootHistory {
        return .{ .origin = if (task.event_floor == 1) 0 else null };
    }

    fn observeRevision(self: *RootHistory, execution_revision: u64) !void {
        const origin = std.math.sub(u64, execution_revision, self.advances) catch
            return error.InvalidArchive;
        if (self.origin) |expected| if (origin != expected) return error.InvalidArchive;
        self.origin = origin;
    }

    pub fn observeCut(self: *RootHistory, cut: RootCut) !void {
        if (self.cut) |expected| if (!std.meta.eql(expected, cut)) return error.InvalidArchive;
        self.cut = cut;
    }

    pub fn observe(self: *RootHistory, event: Event) !void {
        const advances = event.kind == .execution or event.kind == .controller;
        if (advances != (event.root_publication != null)) return error.InvalidArchive;
        if (event.controller_read) |read| {
            if (event.seq == 0 or read.event_watermark != event.seq - 1 or advances)
                return error.InvalidArchive;
            try self.observeRevision(read.execution_revision);
        }
        if (event.root_publication) |publication| {
            if (event.revision <= self.previous_revision) return error.InvalidArchive;
            const same_controller = std.meta.eql(publication.before.controller, publication.after.controller);
            if (same_controller != (event.kind == .execution)) return error.InvalidArchive;
            if (event.kind == .execution and (event.workspace_command != null or
                event.workspace_publications.items.len != 0 or
                event.residual_publications.items.len != 0)) return error.InvalidArchive;
            if (event.kind == .controller) {
                if (event.residual_publications.items.len != 1) return error.InvalidArchive;
                const residual = event.residual_publications.items[0].value;
                try self.observeRevision(residual.execution_revision);
                if (!std.meta.eql(publication.before.controller, @as(?Digest, residual.controller)) or
                    !std.meta.eql(publication.before.checkpoint, residual.initial_checkpoint.digest))
                    return error.InvalidArchive;
            }
            try self.observeCut(publication.before);
            self.cut = publication.after;
            self.advances = std.math.add(u64, self.advances, 1) catch
                return error.InvalidArchive;
            self.advance_revision = event.revision;
        } else if (event.revision == self.advance_revision) switch (event.kind) {
            .message_consumed, .message_not_consumed, .completed, .failed, .cancelled => {},
            else => return error.InvalidArchive,
        };
        self.previous_revision = event.revision;
    }

    pub fn finish(self: *RootHistory, task: Task) !void {
        try self.observeRevision(task.execution_revision);
        if (task.event_floor == 0 or self.origin.? > task.event_floor - 1)
            return error.InvalidArchive;
        try self.observeCut(.from(task));
    }
};

pub const WorkPublication = struct {
    work: Digest,
    execution_revision: u64,
    control_revision: u64,
    runtime: ?Reference = null,
    realization_revision: u64 = 0,
    runtime_capsule: ?Reference = null,
    runtime_trace: bool = false,
    outer_operation: ?Reference = null,
    checkpoint: ?Reference = null,
    observation: Digest,
    control: @import("workspace_state.zig").ControlObservation,
    observer: ?@import("workspace_state.zig").Observer = null,
    guard: ?@import("workspace_state.zig").Guard = null,
    guest_work: u64 = 0,
    outer_cursor: @import("workspace_state.zig").OuterCursor = .{},
};

pub const Artifact = struct {
    id: Digest,
    task: ?TaskId,
    value: Reference,
    media_type: contracts.Text(128),
    schema_id: ?Name,
};

pub const CaptureDisposition = enum { complete, definitely_not_sent, unknown };
pub const AttemptOperation = enum { environment, workspace_build };
pub const ControllerContext = struct {
    epoch: u64,
    event_cut: u64,
    next_message: u64,
    overlay: Reference,
};
pub const Attempt = struct {
    id: Digest,
    task: TaskId,
    occurrence: Digest,
    request: Reference,
    profile: Reference,
    capability: Name,
    inference: bool,
    prepared: ?Reference = null,
    operation: AttemptOperation = .environment,
    controller_context: ?ControllerContext = null,
    controller_read: ?ControllerReadCut = null,
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
    if (current.selection == .rederive and current.evidence != null) return error.CorruptState;
    switch (current.outcome) {
        .pending => if (current.owner_epoch == null or current.provenance != .none or current.previous != null or current.evidence != null) return error.CorruptState,
        .unresolved => if (current.provenance != .none) return error.CorruptState,
        .capture_admitted, .reply_settled => {
            const provenance: @FieldType(Reconciliation, "provenance") = if (current.selection == .rederive) .rederived else .authentic;
            if (current.provenance != provenance) return error.CorruptState;
            if (current.owner_epoch == null) return error.CorruptState;
            if (current.outcome == .capture_admitted and current.prepared == null) return error.CorruptState;
            if (current.selection == .lookup and (current.evidence == null or current.owner_epoch == null)) return error.CorruptState;
        },
        .not_sent => |proof| if (current.selection != .lookup or current.provenance != .authoritative or current.evidence == null or !std.meta.eql(proof, current.evidence.?) or current.owner_epoch == null) return error.CorruptState,
    }
    if (current.outcome != .pending and current.owner_epoch != null and current.previous == null) return error.CorruptState;
    if (current.previous) |ref| {
        const bytes = try store.object(a, ref, null);
        defer a.free(bytes);
        var prior = try contracts.decodeOwned(Reconciliation, a, bytes);
        defer prior.deinit();
        // The transition graph is acyclic: pending -> completed, and then
        // capture_admitted -> reply_settled. No history-depth quota is needed.
        if (prior.value.outcome == .pending) {
            if (current.outcome == .pending or (current.outcome == .reply_settled and current.selection != .rederive)) return error.CorruptState;
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

pub fn controllerExecutionIdentity(id: TaskId) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("protean.controller.outer.v1\x00");
    hash.update(&id);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// An operation receipt retains the exact observation returned at admission,
/// including historical work checkpoints superseded by later execution.
pub fn visitWorkspaceReceipt(a: std.mem.Allocator, store: anytype, receipt: Receipt, collector: anytype) anyerror!void {
    if (receipt.method != .workspace) {
        if (receipt.workspace != null or receipt.workspace_kind != null or receipt.workspace_observation != null) return error.CorruptState;
        return;
    }
    const id = receipt.workspace orelse return error.CorruptState;
    const ref = receipt.workspace_observation orelse return error.CorruptState;
    const kind = receipt.workspace_kind orelse return error.CorruptState;
    const bytes = try store.object(a, ref, null);
    defer a.free(bytes);
    const w = @import("workspace_state.zig");
    inline for (.{ .{ .program, w.ProgramArtifact }, .{ .work, w.WorkObservation }, .{ .value, w.ValueArtifact }, .{ .view, w.ViewArtifact }, .{ .runtime, w.Runtime }, .{ .residual, ControllerResidual }, .{ .controller, w.ControllerRealization }, .{ .candidate, w.SemanticObservation } }) |entry| {
        if (kind == entry[0]) {
            const T = entry[1];
            var decoded = try contracts.decodeOwned(T, a, bytes);
            defer decoded.deinit();
            if (T == w.WorkObservation) {
                const work = decoded.value.work;
                if (!std.meta.eql(work.id, id) or !std.meta.eql(work.task, receipt.task)) return error.CorruptState;
                if (decoded.value.occurrence) |pending| {
                    if (!std.meta.eql(work.current_occurrence, pending.id) or !std.meta.eql(pending.task, work.task) or !std.meta.eql(pending.work, work.id)) return error.CorruptState;
                } else if (work.current_occurrence != null) return error.CorruptState;
            } else if (T == ControllerResidual) {
                if (!std.meta.eql(decoded.value.id, id) or !std.meta.eql(decoded.value.task, receipt.task)) return error.CorruptState;
            } else if (T == w.Runtime) {
                if (!std.meta.eql(decoded.value.artifact.digest, id) or !std.meta.eql(decoded.value.task, receipt.task)) return error.CorruptState;
            } else if (T == w.ControllerRealization) {
                if (!std.meta.eql(controllerExecutionIdentity(receipt.task), id)) return error.CorruptState;
            } else if (T == w.SemanticObservation) {
                const expected = if (decoded.value.candidate) |candidate| candidate.digest else ref.digest;
                if (!std.meta.eql(expected, id)) return error.CorruptState;
            } else if (!std.meta.eql(ref.digest, id)) return error.CorruptState;
            try collector.typed(T, ref, decoded.value);
            return;
        }
    }
    return error.CorruptState;
}

pub fn visitWorkspaceCommand(a: std.mem.Allocator, store: anytype, event: Event, collector: anytype) anyerror!void {
    const ref = event.workspace_command orelse return;
    const bytes = try store.object(a, ref, null);
    defer a.free(bytes);
    const T = @import("workspace_state.zig").PublicationCommand;
    var decoded = try contracts.decodeOwned(T, a, bytes);
    defer decoded.deinit();
    try collector.typed(T, ref, decoded.value);
}

pub const Origin = struct {
    id: Digest,
    task: TaskId,
    build: Reference,
    native_identity: Digest,
    source_revision: u64,
    transfer: ?Digest = null,
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
