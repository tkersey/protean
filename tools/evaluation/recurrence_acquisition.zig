const std = @import("std");
const native = @import("protean_native");
const C = @import("protean_contracts");
const t = @import("application_types");
const State = native.testing.state;
const Occurrence = native.testing.occurrence.Occurrence;
const Service = native.tasks.Service(t);
const Json = native.json;

fn hex(a: std.mem.Allocator, bytes: anytype) !Json.Value {
    return Json.string(try a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower)));
}

fn decimal(a: std.mem.Allocator, value: u64) !Json.Value {
    return Json.string(try std.fmt.allocPrint(a, "{d}", .{value}));
}

fn record(
    service: *Service,
    comptime T: type,
    a: std.mem.Allocator,
    comptime kind: []const u8,
    id: [32]u8,
    task: [16]u8,
) !C.Decoded(T) {
    const bytes = (try service.namespace.store.recordBytes(a, kind, id, task)) orelse
        return error.MissingAcquisitionRecord;
    defer a.free(bytes);
    return C.decodeOwned(T, a, bytes);
}

fn object(service: *Service, a: std.mem.Allocator, ref: anytype) ![]u8 {
    return service.namespace.store.object(a, .{ .digest = ref.digest, .bytes = ref.bytes }, null);
}

fn normalized(
    a: std.mem.Allocator,
    bytes: []const u8,
    request_identity: [32]u8,
) !C.Decoded(t.P.AdaptiveResult) {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], "ABL_ERS3") or
        std.mem.readInt(u64, bytes[12..20], .little) != bytes.len - 20)
        return error.InvalidAcquisitionReply;
    const Envelope = struct { request_identity: [32]u8, value: C.Bytes(null) };
    var envelope = try C.decodeOwned(Envelope, a, bytes[20..]);
    defer envelope.deinit();
    if (!std.meta.eql(envelope.value.request_identity, request_identity))
        return error.InvalidAcquisitionReply;
    return C.decodeOwned(t.P.AdaptiveResult, a, envelope.value.value.bytes);
}

fn acceptedCall(result: t.P.AdaptiveResult, request: t.P.AdaptiveRequest) ?t.P.FunctionCall {
    if (result.replay == null or result.replay_status != .complete or result.result != .output)
        return null;
    var chosen: ?t.P.FunctionCall = null;
    for (result.result.output.items.items) |item| {
        if (item != .function_call) continue;
        if (chosen != null) return null;
        chosen = item.function_call;
    }
    const call = chosen orelse return null;
    const ordinal = call.tool_ordinal_claim;
    if (ordinal >= t.P.declaration_count or !request.offered[ordinal] or
        call.decoded_action != .decoded or
        @backingInt(call.decoded_action.decoded) != ordinal) return null;
    for (request.invocation.tools.items) |tool| {
        if (tool.action_ordinal == ordinal and std.mem.eql(u8, tool.name.bytes, call.name.bytes))
            return call;
    }
    return null;
}

pub fn questionProducer(service: *Service, a: std.mem.Allocator, task_id: [16]u8) !Json.Value {
    var question = (try service.pendingQuestion(a, task_id)) orelse return .null;
    defer question.deinit();
    if (question.value.retired or question.value.answer != null) return .null;
    var task = try service.task(a, task_id);
    defer task.deinit();
    const id = task.value.controller_interaction orelse return .null;
    var offered = try record(
        service,
        State.ControllerInteraction,
        a,
        "controller_interaction",
        id,
        task_id,
    );
    defer offered.deinit();
    if (!std.meta.eql(offered.value.task, task_id) or
        !std.meta.eql(task.value.controller, offered.value.controller) or
        task.value.controller_epoch != offered.value.epoch) return .null;
    const model = offered.value.model orelse return .null;
    var occurrence = try record(service, Occurrence, a, "occurrence", model, task_id);
    defer occurrence.deinit();
    if (occurrence.value.work != null or occurrence.value.state != .admitted or
        occurrence.value.state.admitted != .reply) return .null;
    const reply = occurrence.value.state.admitted.reply;
    var attempt = try record(service, State.Attempt, a, "attempt", reply.attempt, task_id);
    defer attempt.deinit();
    var capture = try record(service, State.Capture, a, "capture", reply.attempt, task_id);
    defer capture.deinit();
    if (!producerCapture(task_id, occurrence.value, attempt.value, capture.value, reply.reply))
        return .null;
    const context = attempt.value.controller_context orelse return .null;
    if (context.epoch != offered.value.epoch or context.event_cut != offered.value.event_cut or
        !std.meta.eql(context.overlay, offered.value.overlay)) return .null;
    const prepared_ref = attempt.value.prepared orelse return .null;
    var prepared = try C.decodeOwned(t.P.AdaptivePrepared, a, try object(service, a, prepared_ref));
    defer prepared.deinit();
    var result = try normalized(
        a,
        try object(service, a, capture.value.projection.?.reply),
        occurrence.value.request,
    );
    defer result.deinit();
    const call = acceptedCall(result.value, prepared.value.request) orelse return .null;
    if (call.decoded_action.decoded != .ask) return .null;
    const prompt_bytes = try object(service, a, question.value.prompt);
    const prompt = try Json.parseAsset(a, prompt_bytes, prompt_bytes.len);
    const text = Json.get(prompt.value, "prompt") orelse return .null;
    if (!std.mem.eql(u8, try Json.text(text), call.decoded_action.decoded.ask.question.bytes))
        return .null;
    var output = try interactionIdentity(a, offered.value);
    try Json.put(a, &output, "question_id", try hex(a, question.value.id));
    try Json.put(a, &output, "question_revision", try decimal(a, question.value.revision));
    try Json.put(a, &output, "request_digest", try hex(a, question.value.request_digest));
    try Json.put(a, &output, "attempt_id", try hex(a, attempt.value.id));
    try Json.put(a, &output, "prepared_sha256", try hex(a, prepared_ref.digest));
    try Json.put(
        a,
        &output,
        "capture_projection_sha256",
        try hex(a, capture.value.projection.?.reply.digest),
    );
    return output;
}

fn producerCapture(
    task: [16]u8,
    occurrence: Occurrence,
    attempt: State.Attempt,
    capture: State.Capture,
    reply: [32]u8,
) bool {
    return std.meta.eql(occurrence.task, task) and std.meta.eql(attempt.task, task) and
        std.meta.eql(capture.task, task) and std.meta.eql(attempt.occurrence, occurrence.id) and
        std.meta.eql(capture.occurrence, occurrence.id) and
        std.meta.eql(attempt.id, capture.attempt) and
        attempt.prepared != null and std.meta.eql(attempt.prepared.?, capture.request) and
        std.meta.eql(attempt.request, occurrence.request_object) and
        std.mem.eql(u8, attempt.capability.bytes, t.P.identity) and
        capture.disposition == .complete and capture.projection != null and
        std.meta.eql(capture.projection.?.reply.digest, reply);
}

fn interactionIdentity(a: std.mem.Allocator, value: State.ControllerInteraction) !Json.Value {
    var result = Json.object();
    try Json.put(a, &result, "interaction_id", try hex(a, value.id));
    try Json.put(a, &result, "task_id", try hex(a, value.task));
    try Json.put(a, &result, "controller_id", try hex(a, value.controller));
    try Json.put(a, &result, "controller_epoch", try decimal(a, value.epoch));
    try Json.put(a, &result, "event_cut", try decimal(a, value.event_cut));
    return result;
}

pub fn interaction(service: *Service, a: std.mem.Allocator, bytes: []const u8) !Json.Value {
    var saved = try C.decodeOwned(State.ControllerInteraction, a, bytes);
    defer saved.deinit();
    var carry = try C.decodeOwned(t.ControllerCarry, a, try object(service, a, saved.value.carry));
    defer carry.deinit();
    var output = try interactionIdentity(a, saved.value);
    try Json.put(a, &output, "carry_sha256", try hex(a, saved.value.carry.digest));
    try Json.put(a, &output, "evidence", try native.values.toJson(
        t.EvidenceList,
        a,
        carry.value.state.evidence,
    ));
    try Json.put(a, &output, "results", try native.values.toJson(
        t.PendingResults,
        a,
        carry.value.state.results,
    ));
    try Json.put(a, &output, "selected_view", try native.values.toJson(
        ?C.workspace.Ref,
        a,
        carry.value.state.selected_view,
    ));
    try Json.put(a, &output, "source_artifacts", try sourceArtifacts(
        service,
        a,
        saved.value.task,
        carry.value.state.evidence,
    ));
    try Json.put(a, &output, "result_actions", try resultActions(service, a, carry.value.state));
    return output;
}

fn sourceArtifacts(
    service: *Service,
    a: std.mem.Allocator,
    task: [16]u8,
    evidence: t.EvidenceList,
) !Json.Value {
    var items: std.array_list.Managed(Json.Value) = .init(a);
    for (evidence.items) |item| {
        if (item != .source) continue;
        const source = item.source;
        var artifact = try C.decodeOwned(t.WorkArtifact, a, try object(service, a, source.object));
        defer artifact.deinit();
        if (artifact.value.version != 2 or !std.meta.eql(artifact.value.task, task))
            return error.InvalidAcquisitionSource;
        const value = artifact.value.evidence orelse return error.InvalidAcquisitionSource;
        const expected: t.SourceEvidenceReference = .{
            .object = source.object,
            .snapshot = value.snapshot,
            .path = value.path,
            .sha256 = value.sha256,
            .start = value.start,
            .end = value.end,
            .file_bytes = value.file_bytes,
        };
        if (!std.mem.eql(
            u8,
            try C.encodeOwned(t.SourceEvidenceReference, a, source),
            try C.encodeOwned(t.SourceEvidenceReference, a, expected),
        ))
            return error.InvalidAcquisitionSource;
        var projected = Json.object();
        try Json.put(a, &projected, "object", try native.values.toJson(
            t.model.ArtifactReference,
            a,
            source.object,
        ));
        try Json.put(a, &projected, "task_id", try hex(a, task));
        try Json.put(a, &projected, "evidence", try native.values.toJson(t.Evidence, a, value));
        try items.append(projected);
    }
    return .{ .array = items };
}

fn resultActions(service: *Service, a: std.mem.Allocator, state: t.State) !Json.Value {
    var items: std.array_list.Managed(Json.Value) = .init(a);
    const replay = state.replay orelse return .{ .array = items };
    const has_workspace = for (state.results.items) |pending| {
        if (pending.output == .workspace) break true;
    } else false;
    if (!has_workspace) return .{ .array = items };
    var context = try C.decodeOwned(t.P.AdaptiveContext, a, try object(service, a, replay.object));
    defer context.deinit();
    var prepared = try C.decodeOwned(
        t.P.AdaptivePrepared,
        a,
        try object(service, a, context.value.source_request),
    );
    defer prepared.deinit();
    var raw = try C.decodeOwned(
        native.responses.Raw,
        a,
        try object(service, a, context.value.source_capture),
    );
    defer raw.deinit();
    const response = try native.responses.decode(
        a,
        try native.responses_contract.read(a, service.profile.bytes),
        raw.value,
    );
    if (response.failure != null or response.unsupported != null)
        return error.InvalidAcquisitionReply;
    const output = try native.responses.OutputNormalizer(t.P).normalize(
        a,
        prepared.value.request.invocation,
        Json.get(response.body, "output").?,
    );
    const normalized_output: t.P.AdaptiveResult = .{
        .result = output,
        .replay = replay,
        .replay_status = .complete,
        .usage = null,
    };
    const call = acceptedCall(normalized_output, prepared.value.request) orelse
        return error.InvalidAcquisitionReply;
    for (state.results.items) |pending| {
        if (pending.output != .workspace) continue;
        if (!std.mem.eql(u8, pending.call_id.bytes, call.call_id.bytes))
            return error.InvalidAcquisitionReply;
        var item = Json.object();
        try Json.put(a, &item, "call_id", Json.string(try a.dupe(u8, call.call_id.bytes)));
        try Json.put(a, &item, "action", try native.values.toJson(
            t.Action,
            a,
            call.decoded_action.decoded,
        ));
        try items.append(item);
    }
    return .{ .array = items };
}

pub fn derivation(a: std.mem.Allocator, bytes: []const u8) !Json.Value {
    var value = try C.decodeOwned(native.workspace.Value, a, bytes);
    defer value.deinit();
    return native.values.toJson(@TypeOf(value.value.derivation), a, value.value.derivation);
}
