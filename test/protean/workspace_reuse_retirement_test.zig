const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const state = native.testing.state;
const wc = contracts.workspace;
const Store = @FieldType(native.Namespace, "store");

pub fn parkSource(h: anytype, task: state.TaskId, work: state.Digest) !void {
    var current = try h.service.workspaceWork(h.scratch, task, work);
    defer current.deinit();
    _ = try h.service.workspaceControl(
        h.scratch,
        "source-retirement-park",
        task,
        work,
        current.value.execution_revision,
        current.value.control_revision,
        .park,
    );
}

pub fn source(
    h: anytype,
    submitted: state.Receipt,
    request: wc.Command,
    original: wc.Reply,
) !void {
    const head = h.namespace.store.head;
    const replayed = try h.service.submit(h.scratch, "reuse-source", {});
    try std.testing.expect(replayed.replayed);
    try std.testing.expectEqualDeep(submitted, replayed.receipt);
    const bytes = h.service.profile.bytes;
    h.service.profile.bytes = "retired submission alias now selects different bytes";
    defer h.service.profile.bytes = bytes;
    try std.testing.expectEqualDeep(
        submitted,
        (try h.service.submit(h.scratch, "reuse-source", {})).receipt,
    );
    try std.testing.expectError(error.OperationConflict, h.service.requestCancel(
        h.scratch,
        "reuse-source",
        submitted.task,
        "different operation",
    ));
    h.service.profile.bytes = bytes;
    try directWorkspace(h, submitted.task, request.program.retain.program);
    const replay = try h.service.workspaceCommand(
        h.scratch,
        "retain-original",
        submitted.task,
        request,
    );
    try sameReply(h.scratch, original, replay);
    var conflicting = request;
    conflicting.program.retain.description.name.bytes = "different retained description";
    const rejected = try h.service.workspaceCommand(
        h.scratch,
        "retain-original",
        submitted.task,
        conflicting,
    );
    try std.testing.expectEqual(.rejected, rejected.disposition);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rejected.observation_json.bytes,
        "OperationConflict",
    ) != null);
    try denied(h, submitted.task, "retain-original", request);
    var disclosure: Disclosure = .{ .store = &h.namespace.store, .task = submitted.task };
    const policy = h.service.profile.reuse;
    h.service.profile.reuse.context = &disclosure;
    h.service.profile.reuse.disclosure = Disclosure.deny;
    defer h.service.profile.reuse = policy;
    try std.testing.expectEqual(.rejected, (try h.service.workspaceCommand(
        h.scratch,
        "retain-original",
        submitted.task,
        request,
    )).disposition);
    try std.testing.expectEqual(@as(u32, 1), disclosure.calls);
    try absent(h, submitted.task);
    try noRestore(h, submitted.task);
    try std.testing.expectEqualDeep(head, h.namespace.store.head);
    try missingEvidence(&h.namespace.store, h.scratch, h.handlers, submitted.task, null);
}

pub fn destination(
    h: anytype,
    task: state.TaskId,
    locator: wc.RetainedLocator,
    before: wc.Reply,
) !void {
    const head = h.namespace.store.head;
    const request: wc.Command = .{ .program = .{ .import = .{ .locator = locator } } };
    const replay = try h.service.workspaceCommand(h.scratch, "import-original", task, request);
    try sameReply(h.scratch, before, replay);
    try denied(h, task, "import-original", request);
    try absent(h, task);
    try std.testing.expectEqualDeep(head, h.namespace.store.head);
}

fn sameReply(a: std.mem.Allocator, before: wc.Reply, after: wc.Reply) !void {
    try std.testing.expectEqual(.observed, after.disposition);
    try std.testing.expectEqualDeep(before.program, after.program);
    var expected = try native.json.parse(a, before.observation_json.bytes, .{});
    defer expected.deinit();
    try native.json.put(a, &expected.value, "replayed", .{ .bool = true });
    const expected_bytes = try native.json.canonical(a, expected.value);
    defer a.free(expected_bytes);
    try std.testing.expectEqualStrings(expected_bytes, after.observation_json.bytes);
}

fn directWorkspace(h: anytype, task: state.TaskId, program: wc.Ref) !void {
    var started = try savedReceipt(h, task, "reuse-source-start");
    defer started.deinit();
    const input = try contracts.encodeOwned(u64, h.scratch, 3);
    defer h.scratch.free(input);
    const replay = try h.service.workspaceStart(
        h.scratch,
        "reuse-source-start",
        task,
        try @import("workspace_test_support.zig").nativeIdentity(program),
        input,
        .{},
    );
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqualDeep(started.value, replay.receipt);
    const bytes = try h.namespace.store.object(
        h.scratch,
        started.value.workspace_observation.?,
        null,
    );
    defer h.scratch.free(bytes);
    var initial = try contracts.decodeOwned(native.workspace.WorkObservation, h.scratch, bytes);
    defer initial.deinit();
    var advanced = try savedReceipt(h, task, "source-retirement-park");
    defer advanced.deinit();
    const before = initial.value.work;
    const controlled = try h.service.workspaceControl(
        h.scratch,
        "source-retirement-park",
        task,
        before.id,
        before.execution_revision,
        before.control_revision,
        .park,
    );
    try std.testing.expect(controlled.replayed);
    try std.testing.expectEqualDeep(advanced.value, controlled.receipt);
    try std.testing.expectError(error.OperationConflict, h.service.workspaceControl(
        h.scratch,
        "source-retirement-park",
        task,
        before.id,
        before.execution_revision + 1,
        before.control_revision,
        .park,
    ));
}

fn savedReceipt(h: anytype, task: state.TaskId, id: []const u8) !contracts.Decoded(state.Receipt) {
    var rows = try h.namespace.store.database.prepare(
        "SELECT b.body FROM operations o JOIN objects b ON b.digest=o.receipt WHERE o.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try contracts.decodeOwned(state.Receipt, h.scratch, try rows.bytes(0));
        if (std.mem.eql(u8, saved.value.client_operation_id.bytes, id)) return saved;
        saved.deinit();
    }
    return error.ExpectedReceipt;
}

fn noRestore(h: anytype, task: state.TaskId) !void {
    const store = &h.namespace.store;
    var retired = (try store.retirement(h.scratch, task)) orelse return error.ExpectedRetirement;
    defer retired.deinit();
    const bytes = try store.object(h.scratch, retired.value.task, null);
    defer h.scratch.free(bytes);
    var saved = try contracts.decodeOwned(state.Task, h.scratch, bytes);
    defer saved.deinit();
    try store.begin();
    defer store.rollback();
    try std.testing.expectError(
        error.InvalidState,
        store.restoreArchiveIndex(h.scratch, retired.value, saved.value),
    );
    try std.testing.expectError(error.UnknownTask, h.service.task(h.scratch, task));
}

fn absent(h: anytype, task: state.TaskId) !void {
    try std.testing.expectError(error.UnknownTask, h.service.task(h.scratch, task));
    try std.testing.expect(!try h.namespace.store.locallyAdmitted(task));
    try std.testing.expect(h.service.work == null);
    var rows = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM records WHERE task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
}

fn denied(h: anytype, task: state.TaskId, id: []const u8, request: wc.Command) !void {
    const authority = h.service.profile.authority;
    const policy = h.service.profile.reuse;
    defer h.service.profile.authority = authority;
    defer h.service.profile.reuse = policy;
    h.service.profile.reuse = .{};
    try std.testing.expectEqual(.rejected, (try h.service.workspaceCommand(
        h.scratch,
        id,
        task,
        request,
    )).disposition);
    h.service.profile.reuse = policy;
    h.service.profile.authority.revoked = true;
    try std.testing.expectEqual(.rejected, (try h.service.workspaceCommand(
        h.scratch,
        id,
        task,
        request,
    )).disposition);
    h.service.profile.authority = authority;
    h.service.profile.authority.principal = "retirement-other-principal";
    try std.testing.expectEqual(.rejected, (try h.service.workspaceCommand(
        h.scratch,
        id,
        task,
        request,
    )).disposition);
    h.service.profile.authority = authority;
    h.service.profile.authority.tenant = "retirement-other-tenant";
    try std.testing.expectEqual(.rejected, (try h.service.workspaceCommand(
        h.scratch,
        id,
        task,
        request,
    )).disposition);
}

const Disclosure = struct {
    store: *Store,
    task: state.TaskId,
    calls: u32 = 0,

    fn deny(
        context: ?*anyopaque,
        _: native.registry.Authority,
        _: native.reuse_policy.Scope,
        _: native.reuse_policy.Frozen,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try std.testing.expectError(error.UnknownTask, self.store.taskBytes(
            std.testing.allocator,
            self.task,
        ));
        try std.testing.expect(!self.store.projecting);
        self.calls += 1;
        return error.Denied;
    }
};

pub fn primary(f: anytype) !void {
    const task = f.accepted.receipt.task;
    try f.service.discardTask(f.frame, task);
    try reopenOwner(f);
    const head = f.namespace.store.head;
    try std.testing.expectEqualDeep(f.accepted.receipt, (try f.service.submit(
        f.frame,
        "submit",
        20,
    )).receipt);
    try std.testing.expectError(error.OperationConflict, f.service.submit(f.frame, "submit", 21));
    try std.testing.expectEqualDeep(f.queued_message.receipt, (try f.service.message(
        f.frame,
        "message",
        task,
        9,
    )).receipt);
    try std.testing.expectError(error.OperationConflict, f.service.message(
        f.frame,
        "message",
        task,
        10,
    ));
    const answer = try f.service.respond(
        f.frame,
        "answer",
        task,
        f.question.value.id,
        f.question.value.revision,
        f.question.value.request_digest,
        "task-owner.answer.v1",
        .{ .number_string = "7" },
    );
    try std.testing.expect(answer.replayed);
    try std.testing.expectEqualDeep(f.answered.receipt, answer.receipt);
    try std.testing.expectError(error.OperationConflict, f.service.respond(
        f.frame,
        "answer",
        task,
        f.question.value.id,
        f.question.value.revision,
        f.question.value.request_digest,
        "task-owner.answer.v1",
        .{ .number_string = "8" },
    ));
    try std.testing.expectError(error.UnknownTask, f.service.task(f.frame, task));
    try std.testing.expectEqualDeep(head, f.namespace.store.head);
    _ = try f.namespace.store.auditRetention(f.handlers, f.application.image_identity);
}

pub fn recovery(f: anytype) !void {
    const task = f.original.task;
    try f.service.discardTask(f.frame, task);
    try reopenOwner(f);
    const head = f.namespace.store.head;
    const replay = try f.service.reconcile(
        f.frame,
        "pure-recover",
        task,
        f.expected_revision,
        f.original.occurrence,
        f.original.attempt,
        .rederive,
    );
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqualDeep(f.admitted.receipt, replay.receipt);
    try std.testing.expectError(error.UnknownTask, f.service.task(f.frame, task));
    try std.testing.expectEqualDeep(head, f.namespace.store.head);
    _ = try f.namespace.store.auditRetention(f.handlers, f.application.image_identity);
    try missingEvidence(
        &f.namespace.store,
        f.frame,
        f.handlers,
        task,
        f.admitted.receipt.reconciliation,
    );
}

fn reopenOwner(f: anytype) !void {
    try f.service.close(f.frame);
    f.service_live = false;
    try f.namespace.close();
    f.namespace_live = false;
    f.namespace = try native.Namespace.open(f.a, f.io, f.path);
    f.namespace_live = true;
    f.service = try @TypeOf(f.service).init(
        f.a,
        f.io,
        &f.namespace,
        f.assets,
        &f.application,
        f.handlers,
        f.profile,
    );
    f.service_live = true;
}

fn missingEvidence(
    store: *Store,
    a: std.mem.Allocator,
    handlers: native.Registry,
    task: state.TaskId,
    reconciliation: ?state.Digest,
) !void {
    try store.begin();
    defer store.rollback();
    store.invalidateIntegrity();
    var retired = (try store.retirement(a, task)) orelse return error.ExpectedRetirement;
    defer retired.deinit();
    const child = if (reconciliation) |id|
        native.testing.archive.record(retired.value, .reconciliation, id) orelse
            return error.ExpectedReconciliation
    else
        retired.value.task;
    try store.database.run(
        "DELETE FROM dependencies WHERE parent=(SELECT body FROM retired_tasks WHERE id=?)" ++
            " AND child=?",
        &.{ .{ .blob = &task }, .{ .blob = &child.digest } },
    );
    try std.testing.expectEqual(@as(u64, 1), try store.database.changes());
    try std.testing.expectError(
        error.CorruptState,
        native.testing.retention.verifyTasks(store, handlers),
    );
    try std.testing.expect(!store.fenced);
}
