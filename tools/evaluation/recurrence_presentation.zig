const std = @import("std");
const native = @import("protean_native");
const C = @import("protean_contracts");
const t = @import("application_types");
const State = native.testing.state;
const W = native.workspace;
const I = native.workspace_instrument;
const Occurrence = native.testing.occurrence.Occurrence;
const Service = native.tasks.Service(t);
const Json = native.json;
const acquisition = @import("recurrence_acquisition.zig");
const record = acquisition.record;
const object = acquisition.object;

fn reference(
    a: std.mem.Allocator,
    kind: @FieldType(C.workspace.Ref, "kind"),
    ref: State.Reference,
) !Json.Value {
    return native.values.toJson(C.workspace.Ref, a, .{
        .kind = kind,
        .id = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(ref.digest, .lower)) },
    });
}

fn references(a: std.mem.Allocator, refs: []const State.Reference) !Json.Value {
    var result: std.array_list.Managed(Json.Value) = .init(a);
    for (refs) |ref| try result.append(try reference(a, .value, ref));
    return .{ .array = result };
}

fn empty(a: std.mem.Allocator) !Json.Value {
    var result = Json.object();
    try Json.put(a, &result, "complete", .{ .bool = false });
    try Json.put(a, &result, "inputs", try references(a, &.{}));
    try Json.put(a, &result, "selected_view", .null);
    try Json.put(a, &result, "port_inputs", try references(a, &.{}));
    return result;
}

pub fn judgment(service: *Service, a: std.mem.Allocator, bytes: []const u8) !Json.Value {
    var value = try C.decodeOwned(W.Value, a, bytes);
    defer value.deinit();
    const origin = value.value.derivation;
    if (origin.kind != .judgment) return .null;
    var output = try empty(a);
    const work_id = origin.work orelse return output;
    const delegation_ref = origin.delegation orelse return output;
    var work = (try record(
        service,
        W.Work,
        a,
        "workspace_work",
        work_id,
        value.value.task,
    )) orelse return output;
    defer work.deinit();
    if (work.value.outcome_kind != .completed or
        !std.meta.eql(work.value.delegation, origin.delegation) or
        !std.meta.eql(work.value.answer_value, value.value.artifact)) return output;
    var delegation = try C.decodeOwned(W.Delegation, a, try object(service, a, delegation_ref));
    defer delegation.deinit();
    if (delegation.value.selection != .model or
        !std.meta.eql(delegation.value.task, value.value.task) or
        !std.meta.eql(delegation.value.instrument, work_id)) return output;
    if (!try answerMatches(service, a, work.value, delegation.value, value.value)) return output;
    var prepared = (try preparation(service, a, work.value, origin)) orelse return output;
    defer prepared.deinit();
    if (!std.meta.eql(prepared.value.selected_view, delegation.value.context) or
        !try acquisition.valueEqual(
            ?W.ModelBinding,
            a,
            prepared.value.model,
            delegation.value.model,
        )) return output;
    if (prepared.value.selected_view) |selected| {
        try Json.put(a, &output, "selected_view", try reference(a, .view, selected));
    } else {
        try Json.put(a, &output, "inputs", try references(a, delegation.value.inputs.items));
    }
    const inputs = (try portInputs(service, a, delegation.value, delegation_ref)) orelse
        return output;
    try Json.put(a, &output, "port_inputs", inputs);
    try Json.put(a, &output, "complete", .{ .bool = true });
    return output;
}

fn answerMatches(
    service: *Service,
    a: std.mem.Allocator,
    work: W.Work,
    delegation: W.Delegation,
    value: W.Value,
) !bool {
    const result_ref = work.result orelse return false;
    var result = try C.decodeOwned(I.Output, a, try object(service, a, result_ref));
    defer result.deinit();
    if (result.value != .answer) return false;
    var port = try C.decodeOwned(W.Port, a, try object(service, a, delegation.port));
    defer port.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.value.answer.bytes, &digest, .{});
    return std.meta.eql(value.description.schema, port.value.interface.argument) and
        std.meta.eql(value.description.value, State.Reference{
            .digest = digest,
            .bytes = result.value.answer.bytes.len,
        });
}

fn preparation(
    service: *Service,
    a: std.mem.Allocator,
    work: W.Work,
    origin: W.Derivation,
) !?C.Decoded(I.Prepared) {
    const id = work.instrument_occurrence orelse return null;
    var pending = (try record(service, Occurrence, a, "occurrence", id, work.task)) orelse
        return null;
    defer pending.deinit();
    if (!std.meta.eql(pending.value.task, work.task) or
        !std.meta.eql(pending.value.work, work.id) or pending.value.state != .admitted or
        pending.value.state.admitted != .reply) return null;
    const reply = pending.value.state.admitted.reply;
    var attempt = (try record(
        service,
        State.Attempt,
        a,
        "attempt",
        reply.attempt,
        work.task,
    )) orelse return null;
    defer attempt.deinit();
    var capture = (try record(
        service,
        State.Capture,
        a,
        "capture",
        reply.attempt,
        work.task,
    )) orelse return null;
    defer capture.deinit();
    if (!std.meta.eql(attempt.value.task, work.task) or
        !std.meta.eql(capture.value.task, work.task) or origin.capture == null or
        !std.meta.eql(attempt.value.occurrence, id) or
        !std.meta.eql(capture.value.occurrence, id) or
        !std.meta.eql(attempt.value.id, capture.value.attempt) or
        !std.meta.eql(attempt.value.request, pending.value.request_object) or
        !std.meta.eql(attempt.value.prepared, capture.value.request) or
        !std.meta.eql(capture.value.response, origin.capture) or
        !std.mem.eql(u8, attempt.value.capability.bytes, I.model_identity) or
        capture.value.disposition != .complete or capture.value.projection == null or
        !std.meta.eql(capture.value.projection.?.reply.digest, reply.reply)) return null;
    const ref = attempt.value.prepared orelse return null;
    return try C.decodeOwned(I.Prepared, a, try object(service, a, ref));
}

fn portInputs(
    service: *Service,
    a: std.mem.Allocator,
    delegation: W.Delegation,
    delegation_ref: State.Reference,
) !?Json.Value {
    var port = try C.decodeOwned(W.Port, a, try object(service, a, delegation.port));
    defer port.deinit();
    if (!std.meta.eql(port.value.task, delegation.task) or
        !std.meta.eql(port.value.work, delegation.work) or
        !std.meta.eql(port.value.program, delegation.program) or
        port.value.generation != delegation.selection.model.generation) return null;
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? ORDER BY e.seq",
        &.{.{ .blob = &delegation.task }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        var event = try C.decodeOwned(State.Event, scratch, try query.bytes(0));
        defer event.deinit();
        const observed = (try delegatedObservation(
            service,
            scratch,
            event.value,
            delegation,
            delegation_ref,
        )) orelse continue;
        if (!std.meta.eql(observed.work.current_port, delegation.port) or
            observed.work.control_revision != delegation.control_revision or
            !std.meta.eql(observed.work.current_occurrence, port.value.occurrence) or
            observed.work.port_generation != port.value.generation) return null;
        const pending = observed.occurrence orelse return null;
        if (!std.meta.eql(pending.request_object, port.value.request) or
            !std.meta.eql(pending.request, port.value.request_identity)) return null;
        var refs: std.array_list.Managed(State.Reference) = .init(scratch);
        if (observed.work.input_value) |ref| try refs.append(ref);
        try refs.appendSlice(observed.work.inputs.items);
        return try references(a, refs.items);
    }
    return null;
}

fn delegatedObservation(
    service: *Service,
    a: std.mem.Allocator,
    event: State.Event,
    delegation: W.Delegation,
    delegation_ref: State.Reference,
) !?W.WorkObservation {
    const command_ref = event.workspace_command orelse return null;
    var command = try C.decodeOwned(W.PublicationCommand, a, try object(service, a, command_ref));
    defer command.deinit();
    if (command.value != .delegate) return null;
    const expected = command.value.delegate.expected;
    if (!std.meta.eql(event.task, delegation.task) or delegation.control_revision == 0 or
        expected.control_revision != delegation.control_revision - 1 or
        expected.work.kind != .work or !std.meta.eql(
        try native.client.identifier(32, Json.string(expected.work.id.bytes)),
        delegation.work,
    )) return null;
    var instrument: ?W.WorkObservation = null;
    var target: ?W.WorkObservation = null;
    for (event.workspace_publications.items) |publication| {
        if (!std.meta.eql(publication.work, delegation.instrument) and
            !std.meta.eql(publication.work, delegation.work)) continue;
        const ref = try service.namespace.store.objectReference(publication.observation, null);
        const decoded = try C.decodeOwned(W.WorkObservation, a, try object(service, a, ref));
        if (!std.meta.eql(decoded.value.work.task, delegation.task) or
            !std.meta.eql(decoded.value.work.id, publication.work) or
            decoded.value.work.control_revision != publication.control_revision) return null;
        if (std.meta.eql(publication.work, delegation.instrument)) instrument = decoded.value;
        if (std.meta.eql(publication.work, delegation.work)) target = decoded.value;
    }
    const child = instrument orelse return null;
    if (!std.meta.eql(child.work.delegation, delegation_ref)) return null;
    return target;
}
