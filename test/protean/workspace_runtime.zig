//! Runtime selection, archive validation and bilateral workspace custody.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;
const support = @import("workspace_test_support.zig");
const workspaceRef = support.workspaceRef;
const AfterCommitAllocator = support.AfterCommitAllocator;
const compile = support.compile;
const OwnerTypes = support.OwnerTypes;
const expectContextOutputBound = support.expectContextOutputBound;
const nativeIdentity = support.nativeIdentity;
const fixtureManifest = support.fixtureManifest;
const gcd = @import("workspace_sources.zig").gcd;
const listLength = @import("workspace_sources.zig").listLength;

const AllocationFailureTrace = struct {
    backing: std.mem.Allocator,
    meter: *kosmos.AllocationBudget,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra) orelse {
            std.debug.print(
                "allocation failure: bytes={d} alignment={d} return_address={x} " ++
                    "live={d} peak={d} required={d} budget_failed={}\n",
                .{
                    len,
                    alignment.toByteUnits(),
                    ra,
                    self.meter.live,
                    self.meter.peak,
                    self.meter.required,
                    self.meter.failed,
                },
            );
            return null;
        };
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn exerciseGuard(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    input: []const u8,
    candidate: contracts.workspace.Ref,
) !void {
    const started = try service.workspaceStart(a, "guard-start", task, program, input, .{});
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    const command: @FieldType(contracts.workspace.Work, "guard") = .{
        .expected = .{
            .work = try workspaceRef(a, .work, id),
            .execution_revision = before.value.execution_revision,
            .control_revision = before.value.control_revision,
        },
        .realization_revision = before.value.realization_revision,
        .candidate = candidate,
    };
    {
        const policy = service.profile.semantic_construction;
        defer service.profile.semantic_construction = policy;
        service.profile.semantic_construction.?.guard = false;
        try std.testing.expectError(error.GuardPolicyDenied, service.workspaceGuard(
            a,
            "guard-policy-denied",
            task,
            .{ .guard = command },
        ));
    }
    _ = try service.workspaceGuard(a, "guard-enable", task, .{ .guard = command });
    const replay = try service.workspaceGuard(a, "guard-enable", task, .{ .guard = command });
    try std.testing.expect(replay.replayed);
    try std.testing.expectError(error.StaleRevision, service.workspaceGuard(
        a,
        "guard-stale",
        task,
        .{ .guard = command },
    ));
    {
        var initial = try service.workspaceWork(a, task, id);
        defer initial.deinit();
        var forged = initial.value.guard.?;
        forged.agreed_segments = 41;
        try guardEvidenceTamper(a, service, initial.value, forged);
    }
    try exerciseGuardContinuation(a, service, before.value, command, candidate);
}

fn exerciseGuardContinuation(
    a: std.mem.Allocator,
    service: anytype,
    before: native.workspace.Work,
    command: @FieldType(contracts.workspace.Work, "guard"),
    candidate: contracts.workspace.Ref,
) !void {
    const task = before.task;
    const id = before.id;
    try pumpGuardWitness(a, service, task, id, before.checkpoint);
    var agreed = try service.workspaceWork(a, task, id);
    defer agreed.deinit();
    try std.testing.expectEqual(@as(u64, 1), agreed.value.guard.?.agreed_segments);
    try std.testing.expectEqualDeep(before.runtime, agreed.value.runtime);
    const prior_continuation = agreed.value.guard.?.continuation.?;
    try retryGuardRestoreFailure(a, service, agreed.value);
    agreed.deinit();
    agreed = try service.workspaceWork(a, task, id);
    try std.testing.expectEqual(@as(u64, 2), agreed.value.guard.?.agreed_segments);
    try std.testing.expect(!std.meta.eql(prior_continuation, agreed.value.guard.?.continuation.?));
    var forged = agreed.value.guard.?;
    forged.continuation = prior_continuation;
    try guardEvidenceTamper(a, service, agreed.value, forged);
    const remove: @FieldType(contracts.workspace.Work, "unguard") = .{
        .expected = .{
            .work = command.expected.work,
            .execution_revision = agreed.value.execution_revision,
            .control_revision = agreed.value.control_revision,
        },
        .guard_revision = agreed.value.guard.?.revision,
    };
    _ = try service.workspaceGuard(a, "guard-remove", task, .{ .unguard = remove });
    try std.testing.expect((try service.workspaceGuard(
        a,
        "guard-remove",
        task,
        .{ .unguard = remove },
    )).replayed);
    var unguarded = try service.workspaceWork(a, task, id);
    defer unguarded.deinit();
    try std.testing.expect(unguarded.value.guard == null);
    try std.testing.expectEqualDeep(agreed.value.checkpoint, unguarded.value.checkpoint);
    try assertGuardNotRuntime(a, service, unguarded.value, candidate);
    try cancelGuardWitness(a, service, unguarded.value, candidate);
}

fn rewriteWorkspacePublication(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
) !void {
    try service.namespace.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        work.id,
        work.task,
        work,
    );
    var pending: ?contracts.Decoded(native.testing.occurrence.Occurrence) = null;
    defer if (pending) |*value| value.deinit();
    if (work.current_occurrence) |id| {
        const bytes = (try service.namespace.store.recordBytes(a, "occurrence", id, work.task)).?;
        defer a.free(bytes);
        pending = try contracts.decodeOwned(native.testing.occurrence.Occurrence, a, bytes);
    }
    const bytes = try contracts.encodeOwned(native.workspace.WorkObservation, a, .{
        .work = work,
        .occurrence = if (pending) |value| value.value else null,
    });
    defer a.free(bytes);
    const observation = try service.namespace.store.putObject(bytes);
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? AND e.seq=?",
        &.{ .{ .blob = &work.task }, .{ .integer = @intCast(work.event_watermark) } },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
    defer event.deinit();
    const publications = try a.dupe(
        native.testing.state.WorkPublication,
        event.value.workspace_publications.items,
    );
    defer a.free(publications);
    event.value.workspace_publications.items = publications;
    for (publications) |*publication| if (std.meta.eql(publication.work, work.id)) {
        publication.guard = work.guard;
        publication.observer = work.observer;
        publication.guest_work = work.guest_work;
        publication.observation = observation.digest;
    };
    const encoded = try contracts.encodeOwned(native.testing.state.Event, a, event.value);
    defer a.free(encoded);
    const reference = try service.namespace.store.putObject(encoded);
    try service.namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{
        .{ .blob = &reference.digest },
        .{ .blob = &work.task },
        .{ .integer = @intCast(work.event_watermark) },
    });
    try rewritePublicationReceipts(a, service, work, observation);
}

fn rewritePublicationReceipts(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    observation: native.testing.state.Reference,
) !void {
    var query = try service.namespace.store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON " ++
            "o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &work.task }},
    );
    defer query.deinit();
    var replaced: usize = 0;
    while (try query.step() == .row) {
        var receipt = try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try query.bytes(1),
        );
        defer receipt.deinit();
        if (receipt.value.workspace_kind != .work or
            !std.meta.eql(receipt.value.workspace, @as(?[32]u8, work.id))) continue;
        const bytes = try service.namespace.store.object(
            a,
            receipt.value.workspace_observation.?,
            null,
        );
        defer a.free(bytes);
        var snapshot = try contracts.decodeOwned(native.workspace.WorkObservation, a, bytes);
        defer snapshot.deinit();
        if (snapshot.value.work.event_watermark != work.event_watermark) continue;
        receipt.value.workspace_observation = observation;
        const encoded = try contracts.encodeOwned(native.testing.state.Receipt, a, receipt.value);
        defer a.free(encoded);
        const reference = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{
            .{ .blob = &reference.digest }, .{ .text = try query.bytes(0) },
        });
        replaced += 1;
    }
    try std.testing.expect(replaced != 0);
}

fn guardEvidenceTamper(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    guard: native.workspace.Guard,
) !void {
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try service.namespace.store.archiveIndex(a, work.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(
        service.allocator,
        work.task,
        index.records.items,
        &facts,
    );
    try service.namespace.store.begin();
    defer service.namespace.store.rollback();
    var forged = work;
    forged.guard = guard;
    try rewriteWorkspacePublication(a, service, forged);
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(
            service.allocator,
            work.task,
            index.records.items,
            &facts,
        ),
    );
}

fn guestWorkTamper(a: std.mem.Allocator, service: anytype, work: native.workspace.Work) !void {
    try std.testing.expect(work.guest_work > 1);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try service.namespace.store.archiveIndex(a, work.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(
        service.allocator,
        work.task,
        index.records.items,
        &facts,
    );
    for ([_]u64{ 1, work.guest_work + 1 }) |count| {
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        var forged = work;
        forged.guest_work = count;
        try rewriteWorkspacePublication(a, service, forged);
        try std.testing.expectError(
            error.InvalidArchive,
            service.validateWorkspaceRecordsPrepared(
                service.allocator,
                work.task,
                index.records.items,
                &facts,
            ),
        );
    }
}

const FailOneAllocationSize = struct {
    backing: std.mem.Allocator,
    size: usize,
    failed: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (!self.failed and len == self.size) {
            self.failed = true;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn retryGuardRestoreFailure(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
) !void {
    var failing: FailOneAllocationSize = .{
        .backing = a,
        .size = @intCast(initial.guard.?.continuation.?.bytes),
    };
    _ = try service.workspaceControl(
        failing.allocator(),
        "guard-restore-failure",
        initial.task,
        initial.id,
        initial.execution_revision,
        initial.control_revision,
        .advance,
    );
    try std.testing.expect(failing.failed);
    var failed = try service.workspaceWork(a, initial.task, initial.id);
    defer failed.deinit();
    try std.testing.expectEqualStrings("OutOfMemory", failed.value.guard.?.failure.?.bytes);
    try std.testing.expect(failed.value.guard.?.pending_control != null);
    try std.testing.expectEqualDeep(
        initial.guard.?.continuation,
        failed.value.guard.?.continuation,
    );
    try std.testing.expectEqualDeep(initial.checkpoint, failed.value.checkpoint);
    try restartGuardOwner(a, service);
    for (0..512) |index| {
        var current = try service.workspaceWork(a, initial.task, initial.id);
        defer current.deinit();
        _ = try service.workspacePump(a, try std.fmt.allocPrint(a, "guard-restore-retry-{d}", .{
            index,
        }), initial.task, .{
            .expected = .{
                .work = try workspaceRef(a, .work, initial.id),
                .execution_revision = current.value.execution_revision,
                .control_revision = current.value.control_revision,
            },
            .base_quantum = 1048576,
        });
        var next = try service.workspaceWork(a, initial.task, initial.id);
        defer next.deinit();
        try std.testing.expect(next.value.guard.?.failure == null);
        if (next.value.guard.?.disposition == .agreed) {
            try std.testing.expect(next.value.guard.?.pending_control == null);
            try std.testing.expectEqual(
                initial.guard.?.agreed_segments + 1,
                next.value.guard.?.agreed_segments,
            );
            return;
        }
    }
    return error.GuardRetryDidNotComplete;
}

fn assertGuardNotRuntime(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    candidate: contracts.workspace.Ref,
) !void {
    try std.testing.expectError(error.InvalidReference, service.workspaceRealize(
        a,
        "guard-is-not-validation",
        work.task,
        .{
            .expected = .{
                .work = try workspaceRef(a, .work, work.id),
                .execution_revision = work.execution_revision,
                .control_revision = work.control_revision,
            },
            .realization_revision = work.realization_revision,
            .runtime = .{ .selected = candidate },
        },
    ));
}

fn cancelGuardWitness(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
    candidate: contracts.workspace.Ref,
) !void {
    _ = try service.workspaceGuard(a, "guard-cancel-enable", initial.task, .{ .guard = .{
        .expected = .{
            .work = try workspaceRef(a, .work, initial.id),
            .execution_revision = initial.execution_revision,
            .control_revision = initial.control_revision,
        },
        .realization_revision = initial.realization_revision,
        .candidate = candidate,
    } });
    var enabled = try service.workspaceWork(a, initial.task, initial.id);
    defer enabled.deinit();
    _ = try service.workspacePump(a, "guard-cancel-pump", initial.task, .{
        .expected = .{
            .work = try workspaceRef(a, .work, initial.id),
            .execution_revision = enabled.value.execution_revision,
            .control_revision = enabled.value.control_revision,
        },
        .base_quantum = 1,
    });
    var pending = try service.workspaceWork(a, initial.task, initial.id);
    defer pending.deinit();
    try std.testing.expectEqual(.incomplete, pending.value.guard.?.disposition);
    const policy = service.profile.semantic_construction;
    defer service.profile.semantic_construction = policy;
    service.profile.semantic_construction = null;
    try restartGuardOwner(a, service);
    _ = try service.workspaceControl(
        a,
        "guard-cleanup",
        initial.task,
        initial.id,
        pending.value.execution_revision,
        pending.value.control_revision,
        .{ .cancel = .{ .bytes = "guard witness complete" } },
    );
    var cancelled = try service.workspaceWork(a, initial.task, initial.id);
    defer cancelled.deinit();
    try std.testing.expect(cancelled.value.guard == null);
    try std.testing.expect(cancelled.value.cancellation != null);
    try std.testing.expect(cancelled.value.execution_revision > initial.execution_revision);
    try sharedCancel(a, service, initial.task, initial.id, "guard-witness");
}

fn pumpGuardWitness(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    id: native.testing.state.Digest,
    checkpoint: native.testing.state.Reference,
) !void {
    var reference_reopened = false;
    for (0..512) |index| {
        var before = try service.workspaceWork(a, task, id);
        defer before.deinit();
        const bounded = index == 0 or
            (before.value.guard.?.candidate_segment != null and !reference_reopened);
        const command: @FieldType(contracts.workspace.Work, "pump") = .{
            .expected = .{
                .work = try workspaceRef(a, .work, id),
                .execution_revision = before.value.execution_revision,
                .control_revision = before.value.control_revision,
            },
            .base_quantum = if (bounded) 1 else 1048576,
        };
        const operation_id = try std.fmt.allocPrint(a, "guard-pump-{d}", .{index});
        defer a.free(operation_id);
        const admission = try service.workspacePump(a, operation_id, task, command);
        const replay = try service.workspacePump(a, operation_id, task, command);
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqualDeep(admission.receipt.id, replay.receipt.id);
        var after = try service.workspaceWork(a, task, id);
        defer after.deinit();
        if (after.value.guard.?.disposition == .agreed) {
            try std.testing.expect(reference_reopened);
            return;
        }
        try std.testing.expectEqual(.incomplete, after.value.guard.?.disposition);
        try std.testing.expect(after.value.guard.?.failure == null);
        try std.testing.expectEqualDeep(checkpoint, after.value.checkpoint);
        try std.testing.expectEqualDeep(
            before.value.current_occurrence,
            after.value.current_occurrence,
        );
        try std.testing.expectEqual(
            before.value.execution_revision,
            after.value.execution_revision,
        );
        try std.testing.expect(after.value.guard.?.pending_control != null);
        const reopen_reference = !reference_reopened and
            after.value.guard.?.reference_operation != null;
        if (index == 0 or reopen_reference) {
            if (after.value.guard.?.reference_operation) |pending| {
                try std.testing.expect(pending.dependencies.items.len != 0);
                try frozenGuardPayloadWitness(a, service, after.value);
                reference_reopened = true;
            }
            try assertReopenedGuard(a, service, after.value);
        }
    }
    return error.GuardDidNotProgress;
}

fn assertReopenedGuard(
    a: std.mem.Allocator,
    service: anytype,
    after: native.workspace.Work,
) !void {
    try restartGuardOwner(a, service);
    var reopened = try service.workspaceWork(a, after.task, after.id);
    defer reopened.deinit();
    try std.testing.expectEqual(after.guard.?.revision, reopened.value.guard.?.revision);
    try std.testing.expectEqualDeep(
        after.guard.?.continuation,
        reopened.value.guard.?.continuation,
    );
    try std.testing.expectEqualDeep(
        after.guard.?.reference_operation,
        reopened.value.guard.?.reference_operation,
    );
    try std.testing.expectEqualDeep(
        after.guard.?.candidate_segment,
        reopened.value.guard.?.candidate_segment,
    );
    try std.testing.expectEqualDeep(
        after.guard.?.pending_control,
        reopened.value.guard.?.pending_control,
    );
}

fn restartGuardOwner(a: std.mem.Allocator, service: anytype) !void {
    const allocator = service.allocator;
    const io = service.io;
    const namespace = service.namespace;
    const assets = service.assets;
    const application = service.application;
    const handlers = service.handlers;
    const profile = service.profile;
    try service.close(a);
    service.* = try @TypeOf(service.*).init(
        allocator,
        io,
        namespace,
        assets,
        application,
        handlers,
        profile,
    );
}

fn wrongAnswerSource(a: std.mem.Allocator, module: source.Module) !source.Module {
    const control = for (module.effects) |effect| {
        if (std.mem.startsWith(u8, effect.identity, "kosmos.semantic-service/")) {
            const advance = module.schemas[@intCast(effect.result)].sum[0];
            break module.schemas[@intCast(advance)].product[0];
        }
    } else return error.MissingServiceBridge;
    const bytes = module.schemas[@intCast(control)].sum[1];
    try std.testing.expect(module.schemas[@intCast(bytes)] == .bytes);
    const constants = try a.alloc(data.program.Literal, module.constants.len + 1);
    @memcpy(constants[0..module.constants.len], module.constants);
    constants[module.constants.len] = .{ .schema = bytes, .bytes = &.{ 1, 0 } };
    const values = try a.alloc(source.ast.Value, module.values.len + 1);
    @memcpy(values[0..module.values.len], module.values);
    values[module.values.len] = .{ .schema = bytes, .expression = .{
        .literal = module.constants.len,
    } };
    const terms = try a.dupe(source.ast.Term, module.terms);
    var changed: usize = 0;
    for (module.terms) |term| {
        if (term != .match_sum or module.values[
            @intCast(term.match_sum.value)
        ].schema != control) continue;
        try std.testing.expectEqual(@as(usize, 4), term.match_sum.cases.len);
        const body = term.match_sum.cases[1].body;
        const call = terms[@intCast(body)].call;
        try std.testing.expectEqual(@as(usize, 2), call.arguments.len);
        const arguments = try a.dupe(Id, call.arguments);
        arguments[1] = module.values.len;
        terms[@intCast(body)] = .{ .call = .{ .function = call.function, .arguments = arguments } };
        changed += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), changed);
    var result = module;
    result.values = values;
    result.constants = constants;
    result.terms = terms;
    return result;
}

fn guardReplyCandidate(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    artifact: *const kosmos.RuntimeArtifact,
) !contracts.workspace.Ref {
    var exported = try kosmos.RuntimeCompiler.exportSource(a, artifact);
    defer exported.deinit();
    const proposal = try native.source_records.encodeRecord(
        native.program_construction.CandidateDocument,
        a,
        .{
            .version = 1,
            .proposal = .{ .selected = try wrongAnswerSource(
                a,
                exported.value.selected.module,
            ), .steps = &.{} },
        },
    );
    const response = try service.workspaceCommand(a, "guard-reply-derive", work.task, .{
        .program = .{ .derive = .{
            .ancestor = .{ .work = .{
                .expected = .{
                    .work = try workspaceRef(a, .work, work.id),
                    .execution_revision = work.execution_revision,
                    .control_revision = work.control_revision,
                },
                .realization_revision = work.realization_revision,
            } },
            .program = try workspaceRef(a, .program, work.program),
            .proposal = .{ .json_text = .{ .bytes = proposal } },
        } },
    });
    return semanticReference(a, response, "candidate");
}

fn guardReplyCount(service: anytype, task: native.testing.state.TaskId) !i64 {
    var query = try service.namespace.store.database.prepare(
        "SELECT count(*) FROM records WHERE task=? AND kind='workspace_port_reply'",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    try std.testing.expectEqual(.row, try query.step());
    return query.integer(0);
}

fn guardReplyOccurrence(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
) !contracts.Decoded(native.testing.occurrence.Occurrence) {
    const bytes = (try service.namespace.store.recordBytes(
        a,
        "occurrence",
        work.current_occurrence.?,
        work.task,
    )).?;
    defer a.free(bytes);
    return contracts.decodeOwned(native.testing.occurrence.Occurrence, a, bytes);
}

fn acquireGuardReply(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
) !@FieldType(contracts.workspace.Work, "interact") {
    const bytes = try service.namespace.store.object(a, work.current_port.?, null);
    defer a.free(bytes);
    var port = try contracts.decodeOwned(native.workspace.Port, a, bytes);
    defer port.deinit();
    const interaction: @FieldType(contracts.workspace.Work, "interact") = .{
        .expected = .{
            .work = try workspaceRef(a, .work, work.id),
            .execution_revision = work.execution_revision,
            .control_revision = work.control_revision,
        },
        .port = try workspaceRef(a, .port, port.value.id),
        .generation = port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{
            .schema = try workspaceRef(a, .schema, port.value.interface.argument.digest),
            .json_text = .{ .bytes = "true" },
        } } },
    };
    _ = try service.workspaceInteract(a, "guard-reply-capture", work.task, interaction);
    return interaction;
}

fn pumpWrongReply(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
    acquired: native.testing.occurrence.Acquired,
) !void {
    for (0..512) |index| {
        var before = try service.workspaceWork(a, initial.task, initial.id);
        defer before.deinit();
        _ = try service.workspacePump(a, try std.fmt.allocPrint(a, "guard-reply-pump-{d}", .{
            index,
        }), initial.task, .{
            .expected = .{
                .work = try workspaceRef(a, .work, initial.id),
                .execution_revision = before.value.execution_revision,
                .control_revision = before.value.control_revision,
            },
            .base_quantum = if (index == 0) 1 else 1048576,
        });
        var after = try service.workspaceWork(a, initial.task, initial.id);
        defer after.deinit();
        try std.testing.expectEqualDeep(initial.checkpoint, after.value.checkpoint);
        try std.testing.expectEqual(initial.execution_revision, after.value.execution_revision);
        try std.testing.expectEqualDeep(initial.current_occurrence, after.value.current_occurrence);
        var pending = try guardReplyOccurrence(a, service, after.value);
        defer pending.deinit();
        try std.testing.expectEqualDeep(acquired, pending.value.state.settled_reply);
        if (index == 0) try restartGuardOwner(a, service);
        if (after.value.guard.?.disposition == .diverged) return;
        try std.testing.expect(after.value.guard.?.failure == null);
        try std.testing.expectEqual(.incomplete, after.value.guard.?.disposition);
    }
    return error.GuardReplyDidNotDiverge;
}

fn assertWrongReplyState(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
    reply: native.testing.state.Digest,
) !void {
    var work = try service.workspaceWork(a, initial.task, initial.id);
    defer work.deinit();
    try std.testing.expect(work.value.guard.?.initialized);
    const segment = work.value.guard.?.candidate_segment.?;
    try std.testing.expect(segment.guest_work > 0);
    const candidate_state = try service.namespace.store.object(a, segment.checkpoint, null);
    const candidate_observation = try service.namespace.store.object(a, segment.observation, null);
    var program = try service.workspaceProgram(a, initial.task, initial.program);
    defer program.deinit();
    const image = try service.namespace.store.object(a, program.value.description.image, null);
    const checkpoint = try service.namespace.store.object(a, initial.checkpoint, null);
    const acquired = try service.namespace.store.acquiredObject(a, reply, null);
    var bound = try data.invocation.decode(data.invocation.Result, a, acquired);
    defer bound.deinit();
    try std.testing.expectEqualSlices(u8, &.{1}, bound.value.value);
    var prepared = try kosmos.Prepared.init(a, image);
    defer prepared.deinit();
    var reference = try kosmos.Resident.restore(a, &prepared, checkpoint);
    defer if (reference.live) {
        const retained = support.expectCleanupValue(reference.takeCheckpoint(a));
        a.free(retained);
    };
    var publication = try reference.publish(
        .{ .encoded = a },
        .{ .reply = acquired },
        .{ .quantum = 256, .checkpoint = .receipt },
    );
    defer publication.deinit();
    var observation = try reference.runtimeObservation(a);
    defer observation.deinit();
    try std.testing.expectEqualSlices(u8, candidate_observation, observation.observation);
    try std.testing.expectEqual(publication.guest_work, segment.guest_work);
    try std.testing.expect(!std.mem.eql(u8, publication.checkpoint.?.bytes(), candidate_state));
    var canonical = try data.state_image.decodeGraphBorrowed(a, candidate_state, .{});
    defer canonical.deinit();
    try data.state_admission.validateAdmitted(a, prepared.guest.core.?.admitted(), canonical.state);
    try std.testing.expectEqual(.yielded, canonical.state.status);
}

fn finishGuardReplyCancellation(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
    acquired: native.testing.occurrence.Acquired,
) !void {
    var current = try service.workspaceWork(a, initial.task, initial.id);
    defer current.deinit();
    _ = try service.workspaceControl(
        a,
        "guard-reply-cancel",
        initial.task,
        initial.id,
        current.value.execution_revision,
        current.value.control_revision,
        .{ .cancel = .{ .bytes = "discard wrong candidate" } },
    );
    var saw_cleanup = false;
    for (0..32) |index| {
        var work = try service.workspaceWork(a, initial.task, initial.id);
        defer work.deinit();
        try std.testing.expect(work.value.guard == null);
        var pending = try guardReplyOccurrence(a, service, initial);
        defer pending.deinit();
        try std.testing.expectEqualDeep(acquired, pending.value.state.admitted.reply);
        if (work.value.cancellation_applied and work.value.outcome_kind == .yielded) {
            saw_cleanup = true;
            try std.testing.expectError(
                error.InvalidState,
                service.workspaceGuard(a, "guard-during-cleanup", initial.task, .{ .guard = .{
                    .expected = .{
                        .work = try workspaceRef(a, .work, work.value.id),
                        .execution_revision = work.value.execution_revision,
                        .control_revision = work.value.control_revision,
                    },
                    .realization_revision = work.value.realization_revision,
                    .candidate = try workspaceRef(
                        a,
                        .candidate,
                        current.value.guard.?.candidate.digest,
                    ),
                } }),
            );
        }
        if (work.value.terminal()) {
            try std.testing.expectEqual(.cancelled, work.value.outcome_kind);
            try std.testing.expect(saw_cleanup);
            return;
        }
        _ = try service.workspaceControl(
            a,
            try std.fmt.allocPrint(a, "guard-reply-cleanup-{d}", .{index}),
            initial.task,
            initial.id,
            work.value.execution_revision,
            work.value.control_revision,
            .advance,
        );
    }
    return error.GuardReplyCleanupDidNotComplete;
}

fn exerciseGuardReply(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
) !void {
    var phase: []const u8 = "guest construction";
    errdefer std.debug.print("guard reply: {s}\n", .{phase});
    const program = try semanticGuestProgram(a, service, task, "guard-reply-build");
    const input = try contracts.encodeOwned(@import(
        "workspace_sources.zig",
    ).SemanticGuestInput, a, .{ .yields = 0, .seed = 100 });
    const started = try service.workspaceStart(a, "guard-reply-start", task, program, input, .{});
    var before = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer before.deinit();
    try std.testing.expectEqual(.requested, before.value.outcome_kind);
    phase = "isolated interpretation";
    try semanticGuestInterpretation(a, service, before.value);
    phase = "reply acquisition";
    const count = try guardReplyCount(service, task);
    const interaction = try acquireGuardReply(a, service, before.value);
    var answered = try service.workspaceWork(a, task, before.value.id);
    defer answered.deinit();
    var pending = try guardReplyOccurrence(a, service, answered.value);
    defer pending.deinit();
    const acquired = pending.value.state.settled_reply;
    const capture = (try service.namespace.store.recordBytes(
        a,
        "workspace_port_reply",
        acquired.attempt,
        task,
    )).?;
    var artifact = try service.program.retainRuntime();
    defer artifact.deinit();
    const roots = [_]native.testing.state.Digest{
        kosmos.RuntimeCompiler.approvedRootIdentity(&artifact),
    };
    const policy = service.profile.semantic_construction;
    defer service.profile.semantic_construction = policy;
    service.profile.semantic_construction = .{
        .roots = &roots,
        .checkers = &.{kosmos.RuntimeCompiler.checker_identity},
        .guard = true,
    };
    try finishGuardedReply(
        a,
        service,
        answered.value,
        acquired,
        &artifact,
        interaction,
        capture,
        count,
        &phase,
    );
}
fn finishGuardedReply(
    a: std.mem.Allocator,
    service: anytype,
    answered: native.workspace.Work,
    acquired: native.testing.occurrence.Acquired,
    artifact: *kosmos.RuntimeArtifact,
    interaction: anytype,
    capture: []const u8,
    count: i64,
    phase: *[]const u8,
) !void {
    const task = answered.task;
    phase.* = "candidate derivation";
    const candidate = try guardReplyCandidate(a, service, answered, artifact);
    phase.* = "guard admission";
    _ = try service.workspaceGuard(a, "guard-reply-enable", task, .{ .guard = .{
        .expected = .{
            .work = try workspaceRef(a, .work, answered.id),
            .execution_revision = answered.execution_revision,
            .control_revision = answered.control_revision,
        },
        .realization_revision = answered.realization_revision,
        .candidate = candidate,
    } });
    phase.* = "guarded reply execution";
    try pumpWrongReply(a, service, answered, acquired);
    phase.* = "independent state comparison";
    try assertWrongReplyState(a, service, answered, acquired.reply);
    phase.* = "owner restart";
    try restartGuardOwner(a, service);
    phase.* = "reply replay and cancellation";
    try std.testing.expect(
        (try service.workspaceInteract(a, "guard-reply-capture", task, interaction)).replayed,
    );
    try std.testing.expectEqual(count + 1, try guardReplyCount(service, task));
    try finishGuardReplyCancellation(a, service, answered, acquired);
    try std.testing.expect(
        (try service.workspaceInteract(a, "guard-reply-capture", task, interaction)).replayed,
    );
    try std.testing.expectEqual(count + 1, try guardReplyCount(service, task));
    const retained = (try service.namespace.store.recordBytes(
        a,
        "workspace_port_reply",
        acquired.attempt,
        task,
    )).?;
    try std.testing.expectEqualSlices(u8, capture, retained);
    phase.* = "complete workspace validation";
    try service.validateWorkspace(a, task);
}

fn frozenGuardPayloadWitness(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
) !void {
    try std.testing.expect(work.guard.?.reference_operation.?.dependencies.items.len != 0);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var poisoned: support.PoisonFreedAllocator = .{ .backing = arena.allocator() };
    const operation_id = try std.fmt.allocPrint(a, "guard-payload-{s}-{d}", .{
        std.fmt.bytesToHex(work.id, .lower), work.guard.?.revision,
    });
    defer a.free(operation_id);
    const materialized = try service.workspaceCommand(
        poisoned.allocator(),
        operation_id,
        work.task,
        .{
            .context = .{ .materialize = .{
                .input = .{ .guest_view = .{
                    .expected = .{
                        .work = try workspaceRef(a, .work, work.id),
                        .execution_revision = work.execution_revision,
                        .control_revision = work.control_revision,
                    },
                    .realization_revision = work.realization_revision,
                    .nodes = .{ .selected = .{ .items = &.{} } },
                } },
                .sources = .{ .items = &.{} },
            } },
        },
    );
    try std.testing.expectEqual(.observed, materialized.disposition);
    const custody = try native.workspace.custodyId(
        a,
        work.task,
        try nativeIdentity(materialized.evidence.?),
    );
    const bytes = (try service.namespace.store.recordBytes(
        a,
        "workspace_value",
        custody,
        work.task,
    )).?;
    defer a.free(bytes);
    var retained = try contracts.decodeOwned(native.workspace.Value, a, bytes);
    defer retained.deinit();
    const frozen = retained.value.derivation.inspection.?.observation.work;
    try std.testing.expectEqualDeep(work.guard.?, frozen.guard.?);
}

fn exerciseDivergentGuard(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    input: []const u8,
    candidate: contracts.workspace.Ref,
) !void {
    const started = try service.workspaceStart(a, "divergent-start", task, program, input, .{});
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    _ = try service.workspaceGuard(a, "divergent-enable", task, .{ .guard = .{
        .expected = .{
            .work = try workspaceRef(a, .work, id),
            .execution_revision = before.value.execution_revision,
            .control_revision = before.value.control_revision,
        },
        .realization_revision = before.value.realization_revision,
        .candidate = candidate,
    } });
    try pumpDivergentGuard(a, service, before.value);
    var divergent = try service.workspaceWork(a, task, id);
    defer divergent.deinit();
    try validateDivergentGuard(service, task, id, divergent.value);
    try assertDivergentState(a, service, before.value, divergent.value);
    _ = try service.workspaceControl(
        a,
        "divergent-delegate",
        task,
        id,
        divergent.value.execution_revision,
        divergent.value.control_revision,
        .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } },
    );
    divergent.deinit();
    divergent = try service.workspaceWork(a, task, id);
    try std.testing.expectEqual(.parked, divergent.value.schedule);
    try std.testing.expectEqual(.diverged, divergent.value.guard.?.disposition);
    try std.testing.expectEqualDeep(before.value.checkpoint, divergent.value.checkpoint);
    _ = try service.pump(a);
    _ = try service.workspaceControl(
        a,
        "divergent-cancel",
        task,
        id,
        divergent.value.execution_revision,
        divergent.value.control_revision,
        .{ .cancel = .{ .bytes = "divergent candidate disposed" } },
    );
    var cancelled = try service.workspaceWork(a, task, id);
    defer cancelled.deinit();
    try std.testing.expect(cancelled.value.guard == null);
    try std.testing.expect(cancelled.value.cancellation_applied);
    try std.testing.expect(cancelled.value.execution_revision > before.value.execution_revision);
    try sharedCancel(a, service, task, id, "divergent-witness");
}

fn assertDivergentState(
    a: std.mem.Allocator,
    service: anytype,
    before: native.workspace.Work,
    divergent: native.workspace.Work,
) !void {
    try std.testing.expect(divergent.guard.?.initialized);
    try std.testing.expectEqualDeep(before.checkpoint, divergent.checkpoint);
    try std.testing.expectEqualDeep(
        before.current_occurrence,
        divergent.current_occurrence,
    );
    try std.testing.expectEqual(before.execution_revision, divergent.execution_revision);
    try std.testing.expectError(error.GuardDiverged, service.workspaceControl(
        a,
        "divergent-no-fallback",
        before.task,
        before.id,
        divergent.execution_revision,
        divergent.control_revision,
        .advance,
    ));
}

fn validateDivergentGuard(
    service: anytype,
    task: [16]u8,
    id: [32]u8,
    divergent: native.workspace.Work,
) !void {
    {
        var request = std.heap.ArenaAllocator.init(service.allocator);
        defer request.deinit();
        errdefer std.debug.print("divergent validation: scratch_capacity={d}\n", .{
            request.queryCapacity(),
        });
        const frame = request.allocator();
        const inspected = try service.workspaceCommand(frame, "divergent-inspect", task, .{
            .work = .{ .inspect = .{ .work = try workspaceRef(frame, .work, id) } },
        });
        try std.testing.expectEqual(.observed, inspected.disposition);
        var observation = try native.json.parse(frame, inspected.observation_json.bytes, .{});
        defer observation.deinit();
        const guard = observation.value.object.get(
            "guard",
        ) orelse return error.MissingGuardObservation;
        const inspected_guard = try native.values.fromJson(native.workspace.Guard, frame, guard);
        try std.testing.expectEqualDeep(divergent.guard.?, inspected_guard);
        var facts = try service.prepareWorkspaceValidation(task);
        defer facts.deinit();
        const prior = service.compiler_facts;
        service.compiler_facts = &facts;
        defer service.compiler_facts = prior;
        try service.validateWorkspace(frame, task);
    }
}

fn pumpDivergentGuard(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
) !void {
    for (0..512) |index| {
        var work = try service.workspaceWork(a, initial.task, initial.id);
        defer work.deinit();
        const operation_id = try std.fmt.allocPrint(a, "divergent-pump-{d}", .{index});
        defer a.free(operation_id);
        _ = try service.workspacePump(a, operation_id, initial.task, .{
            .expected = .{
                .work = try workspaceRef(a, .work, initial.id),
                .execution_revision = work.value.execution_revision,
                .control_revision = work.value.control_revision,
            },
            .base_quantum = 1048576,
        });
        var after = try service.workspaceWork(a, initial.task, initial.id);
        defer after.deinit();
        if (after.value.guard.?.disposition == .diverged) return;
        try std.testing.expectEqual(.incomplete, after.value.guard.?.disposition);
        try std.testing.expect(after.value.guard.?.failure == null);
        try std.testing.expectEqualDeep(initial.checkpoint, after.value.checkpoint);
    }
    return error.DivergenceNotDetected;
}

fn exerciseControllerRealization(
    a: std.mem.Allocator,
    service: anytype,
    task_id: native.testing.state.TaskId,
    document: []const u8,
) !void {
    var stage: []const u8 = "build";
    errdefer std.debug.print("controller realization: {s}\n", .{stage});
    try advanceControllerPast(a, service, task_id, 0);
    var original = try service.task(a, task_id);
    defer original.deinit();
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(
        a,
        "controller-runtime-build",
        task_id,
        document,
        &diagnostic,
    );
    stage = "specialize";
    const runtime = try service.workspaceSpecialize(
        a,
        "controller-runtime-specialize",
        task_id,
        program.receipt.workspace.?,
    );
    const selected = try workspaceRef(a, .runtime, runtime.receipt.workspace.?);
    const command: @FieldType(contracts.workspace.Work, "realize_controller") = .{
        .expected = .{ .cut = .{
            .epoch = original.value.controller_epoch,
            .execution_revision = original.value.execution_revision,
            .realization_revision = original.value.realization_revision,
        } },
        .runtime = .{ .selected = selected },
    };
    stage = "denied policy";
    try std.testing.expectError(
        error.SemanticPolicyDenied,
        service.workspaceRealizeController(a, "controller-runtime-denied", task_id, command),
    );
    try realizeControllerArtifact(a, service, task_id, original.value, runtime, command, &stage);
}

fn realizeControllerArtifact(
    a: std.mem.Allocator,
    service: anytype,
    task_id: [16]u8,
    original: anytype,
    runtime: anytype,
    command: anytype,
    stage: *[]const u8,
) !void {
    stage.* = "read approved artifact";
    const runtime_record_bytes = try service.namespace.store.object(
        a,
        runtime.receipt.workspace_observation.?,
        null,
    );
    defer a.free(runtime_record_bytes);
    var runtime_record = try contracts.decodeOwned(
        native.workspace.Runtime,
        a,
        runtime_record_bytes,
    );
    defer runtime_record.deinit();
    const runtime_bytes = try service.namespace.store.object(
        a,
        runtime_record.value.artifact,
        null,
    );
    defer a.free(runtime_bytes);
    var selected_artifact = try kosmos.RuntimeArtifact.init(
        a,
        runtime_bytes,
        runtime_record.value.artifact.digest,
    );
    defer selected_artifact.deinit();
    const roots = [_][32]u8{kosmos.RuntimeCompiler.approvedRootIdentity(&selected_artifact)};
    const original_policy = service.profile.semantic_construction;
    service.profile.semantic_construction = .{ .roots = &roots, .checkers = &.{
        kosmos.RuntimeCompiler.checker_identity,
    } };
    defer service.profile.semantic_construction = original_policy;
    stage.* = "select";
    const switched = try service.workspaceRealizeController(
        a,
        "controller-runtime-select",
        task_id,
        command,
    );
    try std.testing.expect(!switched.replayed);
    var actual = try service.task(a, task_id);
    defer actual.deinit();
    try assertControllerRealization(
        a,
        service,
        original,
        actual.value,
        runtime.receipt.workspace.?,
        stage,
    );
    try exerciseControllerPolicy(
        a,
        service,
        task_id,
        original,
        actual.value,
        &roots,
        command,
        switched,
        stage,
    );
}

fn assertControllerRealization(
    a: std.mem.Allocator,
    service: anytype,
    original: native.testing.state.Task,
    actual: native.testing.state.Task,
    runtime: [32]u8,
    stage: *[]const u8,
) !void {
    try std.testing.expectEqualDeep(original.checkpoint, actual.checkpoint);
    try std.testing.expectEqual(original.execution_revision, actual.execution_revision);
    try std.testing.expectEqual(original.controller_epoch, actual.controller_epoch);
    try std.testing.expectEqualDeep(runtime, actual.controller_runtime.?.digest);
    try std.testing.expectEqual(
        original.realization_revision + 1,
        actual.realization_revision,
    );
    stage.* = "placement";
    const placement_cut = try service.placementCut(a, .{ .task = actual.id });
    try std.testing.expectEqual(actual.realization_revision, placement_cut.realization);
    try std.testing.expectEqualDeep(
        native.placement.ObjectIdentity.optional(actual.controller_runtime),
        placement_cut.runtime,
    );
    _ = try service.placementCompatibility(a, .{ .task = actual.id });
}

fn exerciseControllerPolicy(
    a: std.mem.Allocator,
    service: anytype,
    task_id: [16]u8,
    original: anytype,
    actual: anytype,
    roots: []const [32]u8,
    command: anytype,
    switched: anytype,
    stage: *[]const u8,
) !void {
    stage.* = "revoked active policy";
    service.profile.semantic_construction = null;
    try std.testing.expectEqual(.idle, try service.pump(a));
    const independent = try service.submit(a, "policy-independent-task", .{ 25, 5 });
    try advanceControllerPast(a, service, independent.receipt.task, 0);
    var progressed = try service.task(a, independent.receipt.task);
    defer progressed.deinit();
    try std.testing.expect(progressed.value.execution_revision > 0);
    _ = try service.requestCancel(
        a,
        "policy-independent-cancel",
        independent.receipt.task,
        "ordinary control remains available",
    );
    for (0..8) |_| {
        var current = try service.task(a, independent.receipt.task);
        defer current.deinit();
        if (current.value.terminal()) break;
        _ = try service.pump(a);
    }
    var cancelled = try service.task(a, independent.receipt.task);
    defer cancelled.deinit();
    try std.testing.expect(cancelled.value.terminal());
    try std.testing.expect(cancelled.value.cancellation_applied);
    stage.* = "revoked restored policy";
    try service.park(a);
    var parked = try service.task(a, task_id);
    defer parked.deinit();
    _ = try service.resumeTask(a, "controller-runtime-resume", task_id, parked.value.revision);
    service.profile.semantic_construction = .{ .roots = roots, .checkers = &.{} };
    try std.testing.expectEqual(.idle, try service.pump(a));
    var denied = try service.task(a, task_id);
    defer denied.deinit();
    try std.testing.expectEqual(actual.execution_revision, denied.value.execution_revision);
    try std.testing.expectEqualDeep(actual.checkpoint, denied.value.checkpoint);
    try restorePackagedController(
        a,
        service,
        task_id,
        original,
        actual,
        roots,
        command,
        switched,
        stage,
    );
}

fn restorePackagedController(
    a: std.mem.Allocator,
    service: anytype,
    task_id: [16]u8,
    original: anytype,
    actual: anytype,
    roots: []const [32]u8,
    command: anytype,
    switched: anytype,
    stage: *[]const u8,
) !void {
    stage.* = "replay";
    try std.testing.expect(
        (try service.workspaceRealizeController(
            a,
            "controller-runtime-select",
            task_id,
            command,
        )).replayed,
    );
    try std.testing.expectError(
        error.StaleRevision,
        service.workspaceRealizeController(a, "controller-runtime-stale", task_id, command),
    );
    stage.* = "return packaged";
    _ = try service.workspaceRealizeController(
        a,
        "controller-runtime-packaged",
        task_id,
        .{ .expected = .{ .cut = .{
            .epoch = actual.controller_epoch,
            .execution_revision = actual.execution_revision,
            .realization_revision = actual.realization_revision,
        } }, .runtime = .{ .packaged = .{} } },
    );
    var restored = try service.task(a, task_id);
    defer restored.deinit();
    try std.testing.expect(restored.value.controller_runtime == null);
    try std.testing.expectEqualDeep(original.checkpoint, restored.value.checkpoint);
    try std.testing.expectEqual(
        original.execution_revision,
        restored.value.execution_revision,
    );
    stage.* = "historical controller cut";
    service.profile.semantic_construction = .{ .roots = roots, .checkers = &.{
        kosmos.RuntimeCompiler.checker_identity,
    } };
    try expectControllerRealizationCut(
        a,
        service,
        switched.receipt,
        original.execution_revision,
    );
}

fn advanceControllerPast(
    a: std.mem.Allocator,
    service: anytype,
    task_id: native.testing.state.TaskId,
    execution_revision: u64,
) !void {
    for (0..64) |_| {
        var parent = try service.task(a, task_id);
        defer parent.deinit();
        if (parent.value.execution_revision > execution_revision) return;
        _ = try service.pump(a);
    }
    return error.UnfinishedControllerAdvance;
}

fn expectControllerRealizationCut(
    a: std.mem.Allocator,
    service: anytype,
    receipt: native.testing.state.Receipt,
    execution_revision: u64,
) !void {
    var stage: []const u8 = "advance";
    errdefer std.debug.print("historical controller cut: {s}\n", .{stage});
    try advanceControllerPast(a, service, receipt.task, execution_revision);
    var parent = try service.task(a, receipt.task);
    defer parent.deinit();
    try std.testing.expect(parent.value.execution_revision > execution_revision);
    stage = "retained validation";
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try service.namespace.store.archiveIndex(a, receipt.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(receipt.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(a, receipt.task, index.records.items, &facts);
    stage = "publication";
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? AND e.revision=?",
        &.{ .{ .blob = &receipt.task }, .{ .integer = @intCast(receipt.revision) } },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
    defer event.deinit();
    try std.testing.expectEqual(
        execution_revision,
        event.value.controller_read.?.execution_revision,
    );
    try std.testing.expectEqual(event.value.seq - 1, event.value.controller_read.?.event_watermark);
    const bytes = try service.namespace.store.object(a, event.value.workspace_command.?, null);
    defer a.free(bytes);
    var command = try contracts.decodeOwned(native.workspace.PublicationCommand, a, bytes);
    defer command.deinit();
    try std.testing.expect(execution_revision > 0);
    stage = "mutations";
    try rejectControllerCutMutations(
        a,
        service,
        receipt,
        event.value,
        command.value,
        parent.value,
        index,
        &facts,
    );
    try expectRootHistoryPrefixes(a, service, parent.value, index);
    try expectRootPublicationRejected(a, service, receipt.task, index, &facts);
}

fn rejectControllerCutMutations(
    a: std.mem.Allocator,
    service: anytype,
    receipt: native.testing.state.Receipt,
    event: native.testing.state.Event,
    command: native.workspace.PublicationCommand,
    parent: native.testing.state.Task,
    index: native.testing.state.Archive,
    facts: anytype,
) !void {
    for (0..5) |mutation| {
        errdefer std.debug.print("controller cut mutation: {d}\n", .{mutation});
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        var changed = event;
        var selected = command.realize_controller;
        switch (mutation) {
            0 => {
                selected.cut.execution_revision -= 1;
                selected.command.expected.cut.execution_revision -= 1;
            },
            1 => changed.controller_read.?.event_watermark -= 1,
            2 => changed.controller_read = null,
            3 => {
                selected.cut.execution_revision = parent.execution_revision;
                selected.command.expected.cut.execution_revision = parent.execution_revision;
            },
            4 => {
                selected.cut.execution_revision -= 1;
                selected.command.expected.cut.execution_revision -= 1;
                changed.controller_read.?.execution_revision -= 1;
            },
            else => unreachable,
        }
        try rewriteControllerRealization(a, service, changed, selected, receipt);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(
            a,
            receipt.task,
            index.records.items,
            facts,
        ));
    }
}

fn expectRootHistoryPrefixes(
    a: std.mem.Allocator,
    service: anytype,
    parent: native.testing.state.Task,
    index: native.testing.state.Archive,
) !void {
    const S = native.testing.state;
    const events = try a.alloc(contracts.Decoded(S.Event), index.events.items.len);
    defer a.free(events);
    var initialized: usize = 0;
    defer for (events[0..initialized]) |*event| event.deinit();
    for (index.events.items, events) |row, *event| {
        const bytes = try service.namespace.store.object(a, row.body, null);
        defer a.free(bytes);
        event.* = try contracts.decodeOwned(S.Event, a, bytes);
        initialized += 1;
    }
    for (events, 0..) |first, offset| {
        var suffix = parent;
        suffix.event_floor = first.value.seq;
        var history: S.RootHistory = .init(suffix);
        for (events[offset..]) |event| try history.observe(event.value);
        try history.finish(suffix);
        const read: S.ControllerReadCut = .from(suffix);
        for (0..2) |_| try history.observeRead(read);
        var changed = read;
        changed.event_watermark += 1;
        try std.testing.expectError(error.InvalidArchive, history.observeRead(changed));
        changed = read;
        changed.execution_revision += 1;
        try std.testing.expectError(error.InvalidArchive, history.observeRead(changed));
        try history.finish(suffix);
    }
    var history: S.RootHistory = .init(parent);
    for (events) |event| try history.observe(event.value);
    var repeated = parent;
    for (0..2) |_| {
        repeated.revision += 1;
        repeated.execution_revision += 1;
        repeated.event_high += 1;
        try history.observe(.{
            .task = parent.id,
            .seq = repeated.event_high,
            .revision = repeated.revision,
            .kind = .execution,
            .data = .{ .bytes = "{}" },
            .root_publication = .{ .before = .from(parent), .after = .from(parent) },
        });
    }
    try history.finish(repeated);
    try std.testing.expectError(error.InvalidArchive, history.finish(parent));
}

fn expectRootPublicationRejected(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    index: native.testing.state.Archive,
    facts: anytype,
) !void {
    const S = native.testing.state;
    for (index.events.items) |row| {
        const bytes = try service.namespace.store.object(a, row.body, null);
        defer a.free(bytes);
        var event = try contracts.decodeOwned(S.Event, a, bytes);
        defer event.deinit();
        if (event.value.kind != .execution) continue;
        for (0..4) |mutation| {
            try service.namespace.store.begin();
            defer service.namespace.store.rollback();
            var changed = event.value;
            switch (mutation) {
                0 => changed.root_publication = null,
                1 => changed.root_publication.?.after.checkpoint[0] ^= 1,
                2 => changed.root_publication.?.after.controller = @splat(1),
                3 => {
                    changed.kind = .blocked;
                    changed.root_publication = null;
                },
                else => unreachable,
            }
            const encoded = try contracts.encodeOwned(S.Event, a, changed);
            defer a.free(encoded);
            const body = try service.namespace.store.putObject(encoded);
            try service.namespace.store.database.run(
                "UPDATE events SET body=? WHERE task=? AND seq=?",
                &.{
                    .{ .blob = &body.digest },
                    .{ .blob = &task },
                    .{ .integer = @intCast(changed.seq) },
                },
            );
            try std.testing.expectError(
                error.InvalidArchive,
                service.validateWorkspaceRecordsPrepared(a, task, index.records.items, facts),
            );
        }
        return;
    }
    return error.MissingRootPublication;
}

fn rewriteControllerRealization(
    a: std.mem.Allocator,
    service: anytype,
    original: native.testing.state.Event,
    selected: native.workspace.ControllerRealization,
    original_receipt: native.testing.state.Receipt,
) !void {
    var receipt = original_receipt;
    receipt.workspace_observation = try service.namespace.store.putObject(
        try contracts.encodeOwned(native.workspace.ControllerRealization, a, selected),
    );
    const request = try contracts.encodeOwned(native.workspace.ControllerRealizeRequest, a, .{
        .task = receipt.task,
        .command = selected.command,
    });
    defer a.free(request);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(request);
    hash.final(&receipt.request_digest);
    var event = original;
    event.workspace_command = try service.namespace.store.putObject(
        try contracts.encodeOwned(native.workspace.PublicationCommand, a, .{
            .realize_controller = selected,
        }),
    );
    const body = try service.namespace.store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, a, event),
    );
    try service.namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{
        .{ .blob = &body.digest }, .{ .blob = &event.task }, .{ .integer = @intCast(event.seq) },
    });
    const receipt_body = try service.namespace.store.putObject(
        try contracts.encodeOwned(native.testing.state.Receipt, a, receipt),
    );
    try service.namespace.store.database.run(
        "UPDATE operations SET request=?,receipt=? WHERE task=? AND request=?",
        &.{
            .{ .blob = &receipt.request_digest },
            .{ .blob = &receipt_body.digest },
            .{ .blob = &receipt.task },
            .{ .blob = &original_receipt.request_digest },
        },
    );
    try std.testing.expectEqual(@as(u64, 1), try service.namespace.store.database.changes());
}

const GeneratedRuntime = struct {
    candidate: contracts.workspace.Ref,
    runtime: contracts.workspace.Ref,
    producer: contracts.workspace.Ref,
    result: contracts.workspace.Ref,
    construction_ns: u64,
    validation_ns: u64,
    producer_build_ns: ?u64 = null,
};

fn transformerDocument(b: *source.Builder) !source.Module {
    const transform = try producerFold(b);
    const layout = try kosmos.RuntimeTransformation.indexedLayout(b);
    const function = b.functions.items[@intCast(layout)];
    const argument_schema = b.variables.items[@intCast(function.parameters[0])];
    const input = try contracts.schema(native.source_records.IndexedDocument, b);
    const output = try contracts.schema(native.program_construction.CandidateDocument, b);
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const document = try b.reference(b.parameter(entry, 0));
    const body_entry = try b.declare(&.{
        try contracts.schema(source.Module, b),
        try contracts.schema(kosmos.RuntimeCompiler.SourceReferences, b),
    }, output, &.{}, &.{});
    const module = try b.reference(b.parameter(body_entry, 0));
    const references = try b.reference(b.parameter(body_entry, 1));
    const functions = try producerField(
        b,
        module,
        std.meta.fieldIndex(source.Module, "functions").?,
    );
    const entry_id = try producerField(b, module, std.meta.fieldIndex(source.Module, "entry").?);
    const selected_function = try producerRequired(b, functions, entry_id);
    const selected_variable = try b.variable(try b.scalar(u64));
    const selected = try b.reference(selected_variable);
    const argument = try layoutInput(b, module, references, selected, argument_schema);
    const proposal = try b.variable(function.result);
    const candidate = try scalarCandidate(
        b,
        transform,
        try b.reference(proposal),
        references,
        output,
    );
    const transformed = try b.bind(proposal, try b.term(.{ .call = .{
        .function = layout,
        .arguments = &.{argument},
    } }), candidate);
    const untouched = try b.primitive(function.result, .product, &.{
        module,
        try producerLiteral(b, []const source.relation.RecordStep, &.{}),
        try producerLiteral(
            b,
            @FieldType(kosmos.RuntimeCompiler.RecordProposal, "interfaces"),
            null,
        ),
    }, 0);
    const normalized = try b.bind(proposal, try b.pure(untouched), candidate);
    const body = try transformerChoice(b, module, selected, transformed, normalized);
    try b.define(body_entry, try b.bind(selected_variable, try b.pure(try producerField(
        b,
        selected_function,
        std.meta.fieldIndex(source.ast.Function, "result").?,
    )), body));
    try b.define(entry, try b.term(.{ .call = .{
        .function = body_entry,
        .arguments = &.{ try producerField(b, document, 1), try producerField(b, document, 2) },
    } }));
    return b.module(entry, transform.failure);
}

fn transformerChoice(
    b: *source.Builder,
    module: Id,
    selected: Id,
    transformed: Id,
    normalized: Id,
) !Id {
    const schemas = try producerField(b, module, std.meta.fieldIndex(source.Module, "schemas").?);
    const schema = try producerRequired(b, schemas, selected);
    const fields = try producerPayload(
        b,
        schema,
        std.meta.fieldIndex(data.program.Schema, "product").?,
    );
    const first = try producerRequired(b, fields, try b.constant(u64, 0));
    const second = try producerRequired(b, fields, try b.constant(u64, 1));
    const reorder = try b.primitive(try b.scalar(bool), .less, &.{ second, first }, 0);
    return b.term(.{ .conditional = .{
        .condition = reorder,
        .when_true = transformed,
        .when_false = normalized,
    } });
}

const ProducerExpression = @FieldType(source.ast.Value, "expression");
const ProducerPrimitive = @FieldType(ProducerExpression, "primitive");

fn producerFold(b: *source.Builder) !source.Module {
    const module_schema = try contracts.schema(source.Module, b);
    const users_schema = try contracts.schema(
        []const []const source.relation.Relocation.Reference,
        b,
    );
    const output = try contracts.schema(kosmos.RuntimeCompiler.RecordProposal, b);
    const integer = try b.scalar(u64);
    const schemas = try b.declare(&.{ module_schema, users_schema, integer }, output, &.{}, &.{});
    const candidates = try b.declare(&.{
        module_schema, users_schema, integer, integer,
    }, output, &.{}, &.{});
    try producerFoldSchemas(b, schemas, candidates);
    try producerFoldCandidates(b, schemas, candidates);
    return b.module(schemas, try b.scalar(void));
}

fn producerNext(b: *source.Builder, index: Id) !Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ index, try b.constant(u64, 1) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}

fn producerFoldSchemas(b: *source.Builder, scan: Id, candidates: Id) !void {
    const module = try b.reference(b.parameter(scan, 0));
    const users = try b.reference(b.parameter(scan, 1));
    const index = try b.reference(b.parameter(scan, 2));
    const miss = try b.term(.{ .call = .{
        .function = scan,
        .arguments = &.{ module, users, try producerNext(b, index) },
    } });
    const schema_variable = try b.variable(try contracts.schema(data.program.Schema, b));
    const fields_variable = try b.variable(try contracts.schema([]const Id, b));
    const selected = try b.term(.{ .call = .{
        .function = candidates,
        .arguments = &.{ module, users, index, try b.constant(u64, 0) },
    } });
    const product = try producerMatch(
        b,
        try b.reference(schema_variable),
        std.meta.fieldIndex(data.program.Schema, "product").?,
        fields_variable,
        try producerWhen(b, try producerEquals(
            b,
            try producerLength(b, try b.reference(fields_variable)),
            try b.constant(u64, 2),
        ), selected, miss),
        miss,
    );
    const schemas = try producerField(b, module, std.meta.fieldIndex(source.Module, "schemas").?);
    const optional_schema = try b.schema(.{ .sum = &.{
        try b.scalar(void), try contracts.schema(data.program.Schema, b),
    } });
    try b.define(scan, try producerMatch(
        b,
        try b.primitive(optional_schema, .sequence_get, &.{ schemas, index }, 0),
        1,
        schema_variable,
        product,
        try b.term(.{ .fail = try b.constant(void, {}) }),
    ));
}

fn producerFoldCandidates(b: *source.Builder, schemas: Id, scan: Id) !void {
    const module = try b.reference(b.parameter(scan, 0));
    const users = try b.reference(b.parameter(scan, 1));
    const schema_index = try b.reference(b.parameter(scan, 2));
    const cursor = try b.reference(b.parameter(scan, 3));
    const refs = try producerRequired(b, users, schema_index);
    const ref_variable = try b.variable(
        try contracts.schema(source.relation.Relocation.Reference, b),
    );
    const ref = try b.reference(ref_variable);
    const index = try producerField(b, ref, 1);
    const values = try producerField(b, module, std.meta.fieldIndex(source.Module, "values").?);
    const miss = try b.term(.{ .call = .{
        .function = scan,
        .arguments = &.{ module, users, schema_index, try producerNext(b, cursor) },
    } });
    const row_variable = try b.variable(try contracts.schema(source.ast.Value, b));
    const row = try b.reference(row_variable);
    const primitive_variable = try b.variable(try contracts.schema(ProducerPrimitive, b));
    const primitive = try b.reference(primitive_variable);
    const candidate = try producerFoldOperands(
        b,
        module,
        values,
        index,
        row,
        primitive,
        miss,
    );
    const selected = try producerMatch(
        b,
        try producerField(b, row, 1),
        std.meta.fieldIndex(ProducerExpression, "primitive").?,
        primitive_variable,
        try producerPrimitiveGuard(b, primitive, .product, 2, candidate, miss),
        miss,
    );
    const kind = try b.primitive(try b.scalar(u32), .enum_tag, &.{try producerField(b, ref, 0)}, 0);
    const value = try producerWhen(b, try producerEquals(
        b,
        kind,
        try b.constant(u32, @backingInt(source.relation.Relocation.Kind.value)),
    ), try b.bind(
        row_variable,
        try b.pure(try producerRequired(b, values, index)),
        selected,
    ), miss);
    const exhausted = try b.term(.{ .call = .{
        .function = schemas,
        .arguments = &.{ module, users, try producerNext(b, schema_index) },
    } });
    const optional_ref = try b.schema(.{ .sum = &.{
        try b.scalar(void),
        b.values.items[@intCast(ref)].schema,
    } });
    try b.define(scan, try producerMatch(
        b,
        try b.primitive(optional_ref, .sequence_get, &.{ refs, cursor }, 0),
        1,
        ref_variable,
        value,
        exhausted,
    ));
}

fn producerFoldOperands(
    b: *source.Builder,
    module: Id,
    values: Id,
    index: Id,
    row: Id,
    primitive: Id,
    miss: Id,
) !Id {
    const constants_schema = try contracts.schema([]const data.program.Literal, b);
    const constants_variable = try b.variable(constants_schema);
    const constants = try b.reference(constants_variable);
    const operands = try producerField(b, primitive, 1);
    var literals: [2]Id = undefined;
    var references: [2]Id = undefined;
    for (&literals, &references) |*literal, *reference| {
        literal.* = try b.variable(try contracts.schema(data.program.Literal, b));
        reference.* = try b.reference(literal.*);
    }
    var body = try producerFoldProposal(
        b,
        module,
        values,
        constants,
        index,
        try producerField(b, row, 0),
        references,
    );
    for (0..2) |offset| {
        const position = 1 - offset;
        const literal_id = try b.variable(try b.scalar(u64));
        const operand = try producerRequired(b, values, try producerRequired(
            b,
            operands,
            try b.constant(u64, position),
        ));
        const read = try b.bind(literals[position], try b.pure(try producerRequired(
            b,
            constants,
            try b.reference(literal_id),
        )), body);
        body = try producerMatch(
            b,
            try producerField(b, operand, 1),
            std.meta.fieldIndex(ProducerExpression, "literal").?,
            literal_id,
            read,
            miss,
        );
    }
    return b.bind(constants_variable, try b.pure(try producerField(
        b,
        module,
        std.meta.fieldIndex(source.Module, "constants").?,
    )), body);
}

fn producerFoldProposal(
    b: *source.Builder,
    module: Id,
    values: Id,
    constants: Id,
    index: Id,
    schema: Id,
    literals: [2]Id,
) !Id {
    const bytes = try b.value(.{ .schema = try b.schema(.bytes), .expression = .{ .primitive = .{
        .opcode = .blob_concat,
        .operands = &.{
            try producerField(b, literals[0], 1), try producerField(b, literals[1], 1),
        },
        .failures = &.{.{
            .kind = .capacity_exceeded,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
    const literal = try b.primitive(try contracts.schema(data.program.Literal, b), .product, &.{
        schema, bytes,
    }, 0);
    const changed_constants = try b.primitive(
        b.values.items[@intCast(constants)].schema,
        .sequence_append,
        &.{ constants, literal },
        0,
    );
    const expression = try b.primitive(try contracts.schema(ProducerExpression, b), .variant, &.{
        try producerLength(b, constants),
    }, std.meta.fieldIndex(ProducerExpression, "literal").?);
    const replacement = try b.primitive(try contracts.schema(source.ast.Value, b), .product, &.{
        schema, expression,
    }, 0);
    return producerFoldModule(b, module, values, index, replacement, changed_constants);
}

fn producerFoldModule(
    b: *source.Builder,
    module: Id,
    values: Id,
    index: Id,
    replacement: Id,
    constants: Id,
) !Id {
    const changed_values = try b.value(.{
        .schema = b.values.items[@intCast(values)].schema,
        .expression = .{ .primitive = .{
            .opcode = .sequence_set,
            .operands = &.{ values, index, replacement },
            .failures = &.{.{
                .kind = .invalid_index,
                .value = try b.failureLiteral(try b.constant(void, {})),
            }},
        } },
    });
    const module_schema = b.values.items[@intCast(module)].schema;
    const fields = b.schemas.items[@intCast(module_schema)].product;
    const changed_fields = try b.allocator().alloc(Id, fields.len);
    for (changed_fields, 0..) |*field, i| field.* = switch (i) {
        std.meta.fieldIndex(source.Module, "values").? => changed_values,
        std.meta.fieldIndex(source.Module, "constants").? => constants,
        else => try producerField(b, module, i),
    };
    const selected_variable = try b.variable(module_schema);
    const selected = try b.reference(selected_variable);
    const scalar = try b.primitive(try contracts.schema(source.relation.Scalar, b), .product, &.{
        index,
        try producerLiteral(b, @FieldType(source.relation.Scalar, "rule"), .fold),
    }, 0);
    const rule = try b.primitive(try contracts.schema(source.relation.RecordRule, b), .variant, &.{
        scalar,
    }, std.meta.fieldIndex(source.relation.RecordRule, "scalar").?);
    const step = try b.primitive(try contracts.schema(source.relation.RecordStep, b), .product, &.{
        selected, rule,
    }, 0);
    const steps = try b.primitive(
        try contracts.schema([]const source.relation.RecordStep, b),
        .sequence,
        &.{step},
        0,
    );
    const proposal = try b.primitive(
        try contracts.schema(kosmos.RuntimeCompiler.RecordProposal, b),
        .product,
        &.{ selected, steps, try producerLiteral(
            b,
            @FieldType(kosmos.RuntimeCompiler.RecordProposal, "interfaces"),
            null,
        ) },
        0,
    );
    return b.bind(selected_variable, try b.pure(try b.primitive(
        module_schema,
        .product,
        changed_fields,
        0,
    )), try b.pure(proposal));
}

fn producerPrimitiveGuard(
    b: *source.Builder,
    primitive: Id,
    opcode: data.program.Opcode,
    arity: u64,
    yes: Id,
    no: Id,
) !Id {
    const code = try b.primitive(try b.scalar(u32), .enum_tag, &.{
        try producerField(b, primitive, 0),
    }, 0);
    var body = yes;
    body = try producerWhen(b, try producerEquals(
        b,
        try producerLength(b, try producerField(b, primitive, 3)),
        try b.constant(u64, 0),
    ), body, no);
    body = try producerWhen(b, try producerEquals(
        b,
        try producerLength(b, try producerField(b, primitive, 1)),
        try b.constant(u64, arity),
    ), body, no);
    return producerWhen(b, try producerEquals(
        b,
        code,
        try b.constant(u32, @backingInt(opcode)),
    ), body, no);
}

fn producerMatch(b: *source.Builder, value: Id, tag: usize, variable: Id, yes: Id, no: Id) !Id {
    const schema = b.values.items[@intCast(value)].schema;
    const variants = b.schemas.items[@intCast(schema)].sum;
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    const cases = try b.allocator().alloc(Case, variants.len);
    for (variants, cases, 0..) |payload, *case, i| case.* = .{
        .variable = if (i == tag) variable else try b.variable(payload),
        .body = if (i == tag) yes else no,
    };
    return b.term(.{ .match_sum = .{ .value = value, .cases = cases } });
}

fn producerWhen(b: *source.Builder, condition: Id, yes: Id, no: Id) !Id {
    return b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = yes,
        .when_false = no,
    } });
}

fn producerEquals(b: *source.Builder, left: Id, right: Id) !Id {
    return b.primitive(try b.scalar(bool), .equal, &.{ left, right }, 0);
}

fn producerLength(b: *source.Builder, value: Id) !Id {
    return b.primitive(try b.scalar(u64), .sequence_length, &.{value}, 0);
}

fn producerLiteral(b: *source.Builder, comptime T: type, value: T) !Id {
    return b.literal(.{
        .schema = try contracts.schema(T, b),
        .bytes = try contracts.encodeOwned(T, b.allocator(), value),
    });
}

fn producerField(b: *source.Builder, value: Id, index: usize) !Id {
    const schema = b.values.items[@intCast(value)].schema;
    return b.primitive(b.schemas.items[@intCast(schema)].product[index], .field, &.{value}, index);
}

fn producerPayload(b: *source.Builder, value: Id, index: usize) !Id {
    const schema = b.values.items[@intCast(value)].schema;
    return b.value(.{
        .schema = b.schemas.items[@intCast(schema)].sum[index],
        .expression = .{ .primitive = .{
            .opcode = .variant_payload,
            .operands = &.{value},
            .immediate = index,
            .failures = &.{.{
                .kind = .invalid_variant,
                .value = try b.failureLiteral(try b.constant(void, {})),
            }},
        } },
    });
}

fn producerRequired(b: *source.Builder, sequence: Id, index: Id) !Id {
    const schema = b.values.items[@intCast(sequence)].schema;
    const optional = try b.schema(.{ .sum = &.{
        try b.scalar(void),
        b.schemas.items[@intCast(schema)].seq,
    } });
    return producerPayload(
        b,
        try b.primitive(optional, .sequence_get, &.{ sequence, index }, 0),
        1,
    );
}

fn layoutInput(b: *source.Builder, module: Id, references: Id, result: Id, schema: Id) !Id {
    const layout_schema = b.schemas.items[@intCast(schema)].product[1];
    const coordinates_schema = b.schemas.items[@intCast(layout_schema)].product[1];
    const coordinates = try b.literal(.{
        .schema = coordinates_schema,
        .bytes = try contracts.encodeOwned([]const Id, b.allocator(), &.{ 1, 0 }),
    });
    const layout = try b.primitive(layout_schema, .product, &.{ result, coordinates }, 0);
    return b.primitive(schema, .product, &.{ module, layout, references }, 0);
}

fn scalarCandidate(
    b: *source.Builder,
    scalar: source.Module,
    proposal: Id,
    references: Id,
    output: Id,
) !Id {
    const function = b.functions.items[@intCast(scalar.entry)];
    const users = try producerRequired(b, try producerField(b, references, 1), try b.constant(
        u64,
        @backingInt(source.relation.Relocation.Kind.schema),
    ));
    const result = try b.variable(function.result);
    const returned = try b.reference(result);
    const steps = try producerField(b, proposal, 1);
    const combined = try b.primitive(b.values.items[@intCast(steps)].schema, .sequence_concat, &.{
        steps, try producerField(b, returned, 1),
    }, 0);
    const final = try b.primitive(function.result, .product, &.{
        try producerField(b, returned, 0), combined, try producerField(b, returned, 2),
    }, 0);
    const document = try b.primitive(output, .product, &.{ try b.constant(u32, 1), final }, 0);
    return b.bind(result, try b.term(.{ .call = .{
        .function = scalar.entry,
        .arguments = &.{ try producerField(b, proposal, 0), users, try b.constant(u64, 0) },
    } }), try b.pure(document));
}

fn semanticReference(
    a: std.mem.Allocator,
    response: contracts.workspace.Reply,
    field: []const u8,
) !contracts.workspace.Ref {
    if (response.disposition == .rejected)
        std.debug.print("semantic {s}: {s}\n", .{ field, response.observation_json.bytes });
    try std.testing.expectEqual(.observed, response.disposition);
    var parsed = try native.json.parseAsset(
        a,
        response.observation_json.bytes,
        response.observation_json.bytes.len,
    );
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse {
        std.debug.print("missing semantic {s}: {s}\n", .{ field, response.observation_json.bytes });
        return error.MissingSemanticReference;
    };
    var reference = try native.values.fromJson(contracts.workspace.Ref, a, value);
    reference.id.bytes = try a.dupe(u8, reference.id.bytes);
    return reference;
}

fn finishTransformer(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    work: contracts.workspace.Ref,
    label: []const u8,
    started_ms: i64,
    expected_layout: bool,
) !contracts.workspace.Ref {
    const id = try nativeIdentity(work);
    var guest_work: u64 = 0;
    for (0..4096) |turn| {
        var request = std.heap.ArenaAllocator.init(service.allocator);
        defer request.deinit();
        const scratch = request.allocator();
        var current = try service.workspaceWork(scratch, task, id);
        defer current.deinit();
        guest_work += current.value.guest_work;
        if (current.value.terminal()) {
            try std.testing.expectEqual(.completed, current.value.outcome_kind);
            const bytes = try service.namespace.store.object(scratch, current.value.result.?, null);
            var result = try contracts.decodeOwned(
                native.program_construction.CandidateDocument,
                scratch,
                bytes,
            );
            defer result.deinit();
            try std.testing.expectEqual(@as(u32, 1), result.value.version);
            try std.testing.expectEqual(
                @as(usize, if (expected_layout) 2 else 1),
                result.value.proposal.steps.len,
            );
            const steps = result.value.proposal.steps;
            try std.testing.expect(steps[steps.len - 1].rule == .scalar);
            if (expected_layout) try std.testing.expect(steps[0].rule == .product_layout);
            std.debug.print(
                "generated transformer {s}: input={d} result={d} guest_work={d} " ++
                    "publications={d} elapsed_ms={d} native_publication_ns={d}\n",
                .{
                    label,
                    current.value.input.bytes,
                    current.value.result.?.bytes,
                    guest_work,
                    turn + 1,
                    std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started_ms,
                    current.value.native_publication_nanoseconds,
                },
            );
            return workspaceRef(a, .value, current.value.result_value.?.digest);
        }
        _ = try service.workspaceControl(
            scratch,
            try std.fmt.allocPrint(scratch, "{s}-transform-{d}", .{ label, turn }),
            task,
            id,
            current.value.execution_revision,
            current.value.control_revision,
            .advance,
        );
    }
    return error.TransformerDidNotComplete;
}

fn materializeTransformerInput(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    ancestor: contracts.workspace.SemanticTarget,
    label: []const u8,
    expected_layout: bool,
) !contracts.workspace.Ref {
    var request = std.heap.ArenaAllocator.init(service.allocator);
    defer request.deinit();
    const scratch = request.allocator();
    const operation_id = try std.fmt.allocPrint(scratch, "{s}-semantic-source", .{label});
    const command: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .semantic_source = .{
            .subject = ancestor,
            .module = .{ .selected = .{} },
            .references = true,
        } },
        .sources = .{ .items = &.{} },
    } } };
    const materialized = try service.workspaceCommand(scratch, operation_id, task, command);
    const reference = try semanticReference(scratch, materialized, "value");
    if (expected_layout) {
        try semanticContextWitness(scratch, service, task, reference, label);
        const replay = try service.workspaceCommand(scratch, operation_id, task, command);
        try std.testing.expectEqualDeep(
            reference,
            try semanticReference(scratch, replay, "value"),
        );
        if (ancestor == .work) {
            const current = try service.workspaceCommand(
                scratch,
                try std.fmt.allocPrint(scratch, "{s}-semantic-source-current", .{label}),
                task,
                command,
            );
            try std.testing.expect(
                !std.meta.eql(
                    try nativeIdentity(reference),
                    try nativeIdentity(try semanticReference(scratch, current, "value")),
                ),
            );
            try expectSemanticAdmissionPosition(scratch, service, task, operation_id);
        }
    }
    return workspaceRef(a, reference.kind, try nativeIdentity(reference));
}

fn runTransformer(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: contracts.workspace.Ref,
    ancestor: contracts.workspace.SemanticTarget,
    label: []const u8,
    expected_layout: bool,
) !struct { work: contracts.workspace.Ref, result: contracts.workspace.Ref } {
    const input = try materializeTransformerInput(
        a,
        service,
        task,
        ancestor,
        label,
        expected_layout,
    );
    const started_ms = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const work = start: {
        var request = std.heap.ArenaAllocator.init(service.allocator);
        defer request.deinit();
        const scratch = request.allocator();
        const started = try service.workspaceCommand(
            scratch,
            try std.fmt.allocPrint(scratch, "{s}-transform-start", .{label}),
            task,
            .{ .work = .{ .start = .{
                .program = program,
                .input = .{ .reference = input },
                .runtime = .{ .packaged = .{} },
                .policy = .{ .stop = .terminal },
            } } },
        );
        const reference = try semanticReference(scratch, started, "work");
        break :start try workspaceRef(a, reference.kind, try nativeIdentity(reference));
    };
    return .{
        .work = work,
        .result = try finishTransformer(a, service, task, work, label, started_ms, expected_layout),
    };
}

fn semanticContextWitness(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    input: contracts.workspace.Ref,
    label: []const u8,
) !void {
    try std.testing.expect(service.compiler_facts == null);
    try std.testing.expectError(
        error.MissingArtifact,
        service.namespace.store.objectReference(@splat(0), null),
    );
    {
        var facts: @TypeOf(service.*).CompilerFacts = .{ .allocator = a };
        defer facts.deinit();
        service.compiler_facts = &facts;
        defer service.compiler_facts = null;
        const rejected = try service.workspaceCommand(
            a,
            try std.fmt.allocPrint(a, "{s}-missing-schema", .{label}),
            task,
            .{
                .context = .{ .materialize = .{
                    .input = .{ .value = .{ .inline_json = .{
                        .schema = try workspaceRef(a, .schema, @splat(0)),
                        .json_text = .{ .bytes = "null" },
                    } } },
                    .sources = .{ .items = &.{} },
                } },
            },
        );
        try std.testing.expectEqual(.rejected, rejected.disposition);
        var parsed = try native.json.parse(a, rejected.observation_json.bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            "ArtifactUnavailable",
            parsed.value.object.get("error").?.string,
        );
        try std.testing.expectEqual(@as(usize, 0), facts.entries.count());
        try std.testing.expectEqual(@as(usize, 0), facts.sources.count());
        try std.testing.expectEqual(@as(usize, 0), facts.values.count());
    }
    const materialized = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "{s}-source-reference", .{label}),
        task,
        .{
            .context = .{ .materialize = .{
                .input = .{ .value = .{ .reference = input } },
                .sources = .{ .items = &.{} },
            } },
        },
    );
    try std.testing.expectEqual(.observed, materialized.disposition);
    try std.testing.expectEqualDeep(input, materialized.evidence.?);
    try std.testing.expect(service.compiler_facts == null);
    const selected = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "{s}-source-selection", .{label}),
        task,
        .{ .context = .{ .select = .{ .values = .{ .items = &.{input} } } } },
    );
    try std.testing.expectEqual(.observed, selected.disposition);
    try std.testing.expect(selected.selected_view != null);
    try std.testing.expect(service.compiler_facts == null);
    try semanticBasisShapeWitness(a, service, task, input);
}

fn semanticAdmissionReceipt(
    a: std.mem.Allocator,
    store: anytype,
    task: [16]u8,
    operation_id: []const u8,
) !native.testing.state.Receipt {
    var query = try store.database.prepare(
        "SELECT o.body FROM operations p JOIN objects o ON " ++
            "o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        const decoded = try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try query.bytes(0),
        );
        if (std.mem.eql(
            u8,
            decoded.value.client_operation_id.bytes,
            operation_id,
        )) return decoded.value;
    }
    return error.MissingAdmission;
}

fn expectSemanticAdmissionPosition(
    allocator: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    operation_id: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const S = native.testing.state;
    const store = &service.namespace.store;
    const original = try semanticAdmissionReceipt(a, store, task, operation_id);
    const event = event: {
        var query = try store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                "WHERE e.task=? AND e.revision=?",
            &.{ .{ .blob = &task }, .{ .integer = @intCast(original.revision) } },
        );
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        break :event (try contracts.decodeOwned(S.Event, a, try query.bytes(0))).value;
    };
    var current = try service.task(a, task);
    defer current.deinit();
    var forged_task = current.value;
    forged_task.revision += 1;
    forged_task.event_high += 1;
    var appended = event;
    appended.seq = forged_task.event_high;
    appended.revision = forged_task.revision;
    var receipt = original;
    receipt.id = @splat(123);
    receipt.client_operation_id.bytes = "semantic-admission-position-forged";
    receipt.revision = forged_task.revision;
    const Key = struct { principal: S.Name, tenant: S.Name, operation_id: S.Name };
    const key_bytes = try contracts.encodeOwned(Key, a, .{
        .principal = .{ .bytes = service.profile.authority.principal },
        .tenant = .{ .bytes = service.profile.authority.tenant },
        .operation_id = receipt.client_operation_id,
    });
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(key_bytes);
    hash.final(&digest);
    var facts = try service.prepareWorkspaceValidation(task);
    defer facts.deinit();
    try store.begin();
    defer store.rollback();
    try store.putTask(forged_task, current.value.revision);
    try store.putEvent(appended);
    try store.putReceipt(
        &std.fmt.bytesToHex(digest, .lower),
        receipt.request_digest,
        try contracts.encodeOwned(S.Receipt, a, receipt),
    );
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &digest, .{});
    const index = try store.archiveIndex(a, task, .{
        .digest = digest,
        .bytes = service.assets.manifest.len,
    });
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &facts),
    );
}

fn semanticBasisShapeWitness(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    input: contracts.workspace.Ref,
) !void {
    const id = try native.workspace.custodyId(a, task, try nativeIdentity(input));
    const bytes = (try service.namespace.store.recordBytes(a, "workspace_value", id, task)).?;
    var saved = try contracts.decodeOwned(native.workspace.Value, a, bytes);
    defer saved.deinit();
    if (saved.value.derivation.semantic_source.?.selection.subject != .work) return;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try service.namespace.store.archiveIndex(a, task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(task);
    defer facts.deinit();
    const records = try a.alloc(native.testing.state.ArchiveRecord, index.records.items.len + 1);
    defer a.free(records);
    @memcpy(records[1..], index.records.items);
    for (0..3) |variant| {
        var forged = saved.value;
        const origin = &forged.derivation.semantic_source.?;
        origin.basis = if (variant == 1)
            .{ .works = .{ .works = .{ .items = &.{} }, .event_watermark = 0 } }
        else
            .immutable;
        if (variant == 2) origin.selection.subject = .{ .controller = .{ .cut = .{
            .epoch = 0,
            .execution_revision = 1,
        } } };
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        forged.description.provenance = try service.namespace.store.putObject(
            try contracts.encodeOwned(native.workspace.Derivation, a, forged.derivation),
        );
        forged.artifact = try service.namespace.store.putObject(
            try contracts.encodeOwned(native.workspace.ValueArtifact, a, forged.description),
        );
        forged.id = try native.workspace.custodyId(a, task, forged.artifact.digest);
        try service.namespace.store.createRecord(
            native.workspace.Value,
            "workspace_value",
            forged.id,
            task,
            forged,
        );
        const body = try service.namespace.store.putObject(
            try contracts.encodeOwned(native.workspace.Value, a, forged),
        );
        records[0] = .{ .kind = .workspace_value, .id = forged.id, .body = body };
        try std.testing.expectError(
            error.InvalidArchive,
            service.validateWorkspaceRecordsPrepared(a, task, records, &facts),
        );
    }
}

fn generatedRuntime(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    ancestor: contracts.workspace.SemanticTarget,
    label: []const u8,
    guard_input: ?[]const u8,
) !GeneratedRuntime {
    const producer_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try transformerDocument(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(
        a,
        try std.fmt.allocPrint(a, "{s}-transformer-build", .{label}),
        task,
        document,
        &diagnostic,
    );
    const producer = try workspaceRef(a, .program, built.receipt.workspace.?);
    const producer_build_ns = sharedElapsed(producer_started);
    var generated = try generatedFromProducer(
        a,
        service,
        task,
        program,
        ancestor,
        producer,
        label,
        guard_input,
        true,
    );
    generated.producer_build_ns = producer_build_ns;
    return generated;
}

fn validateGeneratedRuntime(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    ancestor: contracts.workspace.SemanticTarget,
    candidate: contracts.workspace.Ref,
    label: []const u8,
    expected_layout: bool,
    phase: *[]const u8,
) !struct { runtime: contracts.workspace.Ref, validation_ns: u64 } {
    phase.* = "independent validation";
    const validation_started = std.Io.Clock.awake.now(std.testing.io);
    const validated = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "{s}-validate", .{label}),
        task,
        .{ .program = .{ .validate = .{ .candidate = candidate } } },
    );
    const runtime = try semanticReference(a, validated, "runtime");
    const validation_ns = std.math.cast(
        u64,
        @max(
            0,
            std.Io.Clock.awake.now(std.testing.io).nanoseconds - validation_started.nanoseconds,
        ),
    ) orelse std.math.maxInt(u64);
    phase.* = "validation timing";
    try expectCompilerTime(a, service, task, validated);
    phase.* = "runtime inspection";
    try expectRuntimeInspection(a, service, task, runtime, label);
    if (ancestor == .runtime)
        try std.testing.expect(
            !std.meta.eql(try nativeIdentity(ancestor.runtime), try nativeIdentity(runtime)),
        );
    phase.* = "helper correspondence";
    {
        var scratch = std.heap.ArenaAllocator.init(service.allocator);
        defer scratch.deinit();
        try helperCorrespondence(
            scratch.allocator(),
            service,
            task,
            ancestor,
            runtime,
            expected_layout,
        );
    }
    return .{ .runtime = runtime, .validation_ns = validation_ns };
}

fn generatedFromProducer(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    ancestor: contracts.workspace.SemanticTarget,
    producer: contracts.workspace.Ref,
    label: []const u8,
    guard_input: ?[]const u8,
    expected_layout: bool,
) !GeneratedRuntime {
    var phase: []const u8 = "producer execution";
    errdefer std.debug.print("generated runtime {s}: {s}\n", .{ label, phase });
    const construction_started = std.Io.Clock.awake.now(std.testing.io);
    const result = try runTransformer(a, service, task, producer, ancestor, label, expected_layout);
    phase = "candidate construction";
    const derived = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "{s}-derive", .{label}),
        task,
        .{ .program = .{ .derive = .{
            .ancestor = ancestor,
            .program = try workspaceRef(a, .program, program),
            .proposal = .{ .reference = result.result },
        } } },
    );
    const candidate = try semanticReference(a, derived, "candidate");
    if (expected_layout and ancestor == .work) try expectSemanticAdmissionPosition(
        a,
        service,
        task,
        try std.fmt.allocPrint(a, "{s}-derive", .{label}),
    );
    const construction_ns = std.math.cast(
        u64,
        @max(
            0,
            std.Io.Clock.awake.now(std.testing.io).nanoseconds - construction_started.nanoseconds,
        ),
    ) orelse std.math.maxInt(u64);
    phase = "construction timing";
    try expectCompilerTime(a, service, task, derived);
    phase = "reference guard";
    if (guard_input) |input| {
        var scratch = std.heap.ArenaAllocator.init(service.allocator);
        defer scratch.deinit();
        try exerciseGuard(scratch.allocator(), service, task, program, input, candidate);
    }
    const validated = try validateGeneratedRuntime(
        a,
        service,
        task,
        ancestor,
        candidate,
        label,
        expected_layout,
        &phase,
    );
    return .{
        .candidate = candidate,
        .runtime = validated.runtime,
        .producer = producer,
        .result = result.result,
        .construction_ns = construction_ns,
        .validation_ns = validated.validation_ns,
    };
}

fn expectRuntimeInspection(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    runtime: contracts.workspace.Ref,
    label: []const u8,
) !void {
    const operation_id = try std.fmt.allocPrint(a, "{s}-inspect-runtime", .{label});
    defer a.free(operation_id);
    const inspected = try service.workspaceCommand(a, operation_id, task, .{
        .program = .{ .inspect = .{ .target = .{ .program = runtime }, .page = .{} } },
    });
    try std.testing.expectEqual(.observed, inspected.disposition);
    var page = try native.json.parse(a, inspected.observation_json.bytes, .{});
    defer page.deinit();
    const text = page.value.object.get("text") orelse return error.MissingRuntimeInspectionPage;
    var observation = try native.json.parse(a, text.string, .{});
    defer observation.deinit();
    const reference = observation.value.object.get(
        "runtime",
    ) orelse return error.MissingInspectedRuntime;
    const actual = try native.values.fromJson(contracts.workspace.Ref, a, reference);
    try std.testing.expectEqualDeep(runtime, actual);
}

fn expectCompilerTime(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    reply: contracts.workspace.Reply,
) !void {
    var observation = try native.json.parse(a, reply.observation_json.bytes, .{});
    defer observation.deinit();
    const measured = observation.value.object.get(
        "compiler_nanoseconds",
    ) orelse return error.MissingCompilerTime;
    const elapsed = try native.json.numberInteger(u64, measured.number_string);
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? ORDER BY e.seq DESC",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
        defer event.deinit();
        const reference = event.value.workspace_command orelse continue;
        const bytes = try service.namespace.store.object(a, reference, null);
        defer a.free(bytes);
        var command = try contracts.decodeOwned(native.workspace.PublicationCommand, a, bytes);
        defer command.deinit();
        if (command.value != .semantic) continue;
        const output = try service.namespace.store.object(a, command.value.semantic.output, null);
        defer a.free(output);
        var built = try contracts.decodeOwned(native.testing.workspace_build.Output, a, output);
        defer built.deinit();
        const recorded = switch (built.value) {
            inline else => |value| value.compiler_nanoseconds,
        };
        try std.testing.expectEqual(recorded, elapsed);
        return;
    }
    return error.MissingCompilerPublication;
}

fn semanticWork(
    a: std.mem.Allocator,
    work: native.workspace.Work,
) !contracts.workspace.SemanticTarget {
    return .{ .work = .{
        .expected = .{
            .work = try workspaceRef(a, .work, work.id),
            .execution_revision = work.execution_revision,
            .control_revision = work.control_revision,
        },
        .realization_revision = work.realization_revision,
    } };
}

fn semanticArtifact(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    subject: contracts.workspace.SemanticTarget,
) !kosmos.RuntimeArtifact {
    const reference = switch (subject) {
        .runtime => |runtime_ref| runtime_ref,
        .work => |selection| blk: {
            var work = try service.workspaceWork(
                a,
                task,
                try nativeIdentity(selection.expected.work),
            );
            defer work.deinit();
            if (work.value.runtime) |runtime|
                break :blk try workspaceRef(a, .runtime, runtime.digest);
            return service.program.retainRuntime();
        },
        .controller => return error.InvalidSemanticFixture,
    };
    const id = try nativeIdentity(reference);
    const record = (try service.namespace.store.recordBytes(
        a,
        "workspace_runtime",
        try native.workspace.custodyId(a, task, id),
        task,
    )).?;
    var runtime = try contracts.decodeOwned(native.workspace.Runtime, a, record);
    defer runtime.deinit();
    const bytes = try service.namespace.store.object(a, runtime.value.artifact, null);
    return kosmos.RuntimeArtifact.init(a, bytes, id);
}

fn expectValidationResourceOutcome(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    generated: GeneratedRuntime,
) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var candidate = try service.workspaceCandidate(
        scratch,
        task,
        try nativeIdentity(generated.candidate),
    );
    defer candidate.deinit();
    const ancestor = try service.namespace.store.object(
        scratch,
        candidate.value.description.ancestor,
        null,
    );
    var artifact = try semanticArtifact(scratch, service, task, .{ .runtime = generated.runtime });
    defer artifact.deinit();
    const count = (kosmos.RuntimeCompiler.ValidationPolicy{}).work / @sizeOf(u64) + 1;
    const evidence = try scratch.alloc(u8, @intCast(count + 32));
    @memset(evidence, 0);
    var writer: data.wire.Writer = .{ .output = evidence };
    try writer.bytes(&.{});
    try writer.bytes(&.{});
    try writer.natural(0);
    try writer.natural(count);
    var bundle = artifact.content.value;
    bundle.evidence = evidence;
    const bytes = try contracts.encodeOwned(@TypeOf(bundle), scratch, bundle);
    var description = candidate.value.description;
    std.crypto.hash.sha2.Sha256.hash(bytes, &description.code.digest, .{});
    description.code.bytes = bytes.len;
    const descriptor = try contracts.encodeOwned(
        native.workspace.CandidateArtifact,
        scratch,
        description,
    );
    var reference: native.testing.state.Reference = .{
        .digest = undefined,
        .bytes = descriptor.len,
    };
    std.crypto.hash.sha2.Sha256.hash(descriptor, &reference.digest, .{});
    const build = native.testing.workspace_build;
    const input = try contracts.encodeOwned(build.Input, scratch, .{ .validate = .{
        .ancestor = .{ .bytes = ancestor },
        .candidate = .{ .bytes = bytes },
        .candidate_ref = reference,
        .program = candidate.value.program,
        .guest = description.guest,
        .root = description.root,
        .checker = description.checker,
    } });
    try expectValidationCapacity(scratch, service, task, input);
}
fn expectValidationCapacity(
    scratch: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    input: []const u8,
) !void {
    const build = native.testing.workspace_build;
    const task_name = std.fmt.bytesToHex(task, .lower);
    const output = try build.run(.{
        .allocator = scratch,
        .io = service.io,
        .authority = &service.profile.authority,
        .task_id = &task_name,
        .profile = service.profile.bytes,
        .environment = null,
    }, input);
    var result = try contracts.decodeOwned(build.Output, scratch, output);
    defer result.deinit();
    try std.testing.expect(result.value == .validation);
    try std.testing.expectEqualStrings("Capacity", result.value.validation.code.bytes);
    try std.testing.expectEqual(.resource_exhausted, result.value.validation.outcome);
}

fn helperCorrespondence(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    before: contracts.workspace.SemanticTarget,
    after: contracts.workspace.Ref,
    expected_layout: bool,
) !void {
    var exports: [2]kosmos.RuntimeCompiler.ExportedSource = undefined;
    var count: usize = 0;
    defer for (exports[0..count]) |*owned| owned.deinit();
    for ([_]contracts.workspace.SemanticTarget{ before, .{
        .runtime = after,
    } }, &exports) |subject, *exported| {
        var artifact = try semanticArtifact(a, service, task, subject);
        defer artifact.deinit();
        exported.* = try kosmos.RuntimeCompiler.exportSource(a, &artifact);
        count += 1;
    }
    try std.testing.expect(exports[1].value.construction != null);
    try std.testing.expect(!std.meta.eql(exports[0].value.image, exports[1].value.image));
    try std.testing.expectEqual(
        @as(Id, 0),
        exports[1].value.construction.?.interfaces.layout.machine_program,
    );
    try std.testing.expectEqual(
        @as(Id, if (expected_layout) 0 else 1),
        if (exports[0].value.construction) |construction|
            construction.interfaces.layout.service_machine
        else
            @as(Id, 0),
    );
    try std.testing.expectEqual(
        @as(Id, 1),
        exports[1].value.construction.?.interfaces.layout.service_machine,
    );
    for (exports[0].value.helpers, exports[1].value.helpers) |original, candidate| {
        try std.testing.expectEqual(original.role, candidate.role);
        try std.testing.expectEqual(original.source.module.entry, candidate.source.module.entry);
        const entry = @as(usize, @intCast(original.source.module.entry));
        try std.testing.expect(data.record.equal(
            source.ast.Function,
            original.source.module.functions[entry],
            candidate.source.module.functions[entry],
        ));
    }
}

fn wrongCutAccounting(a: std.mem.Allocator, module: source.Module) !source.Module {
    const cut = for (module.effects) |effect| {
        if (std.mem.startsWith(u8, effect.identity, "kosmos.semantic-service/"))
            break module.schemas[@intCast(effect.payload)].sum[0];
    } else return error.MissingServiceBridge;
    const word = module.schemas[@intCast(cut)].product[1];
    const zero: Id = for (module.values, 0..) |value, id| {
        if (value.schema != word or value.expression != .literal) continue;
        const literal = module.constants[@intCast(value.expression.literal)];
        if (std.mem.eql(u8, literal.bytes, &@as([8]u8, @splat(0))))
            break @intCast(id);
    } else return error.MissingAccountingZero;
    const values = try a.dupe(source.ast.Value, module.values);
    var changed: usize = 0;
    for (values, 0..) |*value, id| {
        if (value.schema != cut or value.expression != .primitive) continue;
        var primitive = value.expression.primitive;
        if (primitive.opcode != .product) continue;
        try std.testing.expect(zero < id);
        try std.testing.expectEqual(@as(usize, 3), primitive.operands.len);
        const operands = try a.dupe(Id, primitive.operands);
        operands[1] = zero;
        primitive.operands = operands;
        value.expression = .{ .primitive = primitive };
        changed += 1;
    }
    try std.testing.expect(changed != 0);
    var result = module;
    result.values = values;
    return result;
}

fn divergentProposal(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    produced: contracts.workspace.Ref,
) ![]u8 {
    const id = try nativeIdentity(produced);
    const record = (try service.namespace.store.recordBytes(
        a,
        "workspace_value",
        try native.workspace.custodyId(a, task, id),
        task,
    )).?;
    var value = try contracts.decodeOwned(native.workspace.Value, a, record);
    defer value.deinit();
    const bytes = try service.namespace.store.object(a, value.value.description.value, null);
    var document = try contracts.decodeOwned(
        native.program_construction.CandidateDocument,
        a,
        bytes,
    );
    defer document.deinit();
    document.value.proposal.selected = try wrongCutAccounting(a, document.value.proposal.selected);
    return native.source_records.encodeRecord(
        native.program_construction.CandidateDocument,
        a,
        document.value,
    );
}

fn exerciseWrongCandidate(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    input: []const u8,
    ancestor: contracts.workspace.SemanticTarget,
    produced: contracts.workspace.Ref,
) !void {
    var phase: []const u8 = "divergent source construction";
    errdefer std.debug.print("wrong candidate: {s}\n", .{phase});
    const proposal = try divergentProposal(a, service, task, produced);
    phase = "structurally valid candidate derivation";
    const response = try service.workspaceCommand(a, "generated-wrong-derive", task, .{
        .program = .{ .derive = .{
            .ancestor = ancestor,
            .program = try workspaceRef(a, .program, program),
            .proposal = .{ .json_text = .{ .bytes = proposal } },
        } },
    });
    const candidate = try semanticReference(a, response, "candidate");
    phase = "independent rejection";
    const rejected = try service.workspaceCommand(a, "generated-wrong-validate", task, .{
        .program = .{ .validate = .{ .candidate = candidate } },
    });
    try std.testing.expectEqual(.observed, rejected.disposition);
    var parsed = try native.json.parseAsset(
        a,
        rejected.observation_json.bytes,
        rejected.observation_json.bytes.len,
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("rejected", parsed.value.object.get("validation").?.string);
    try std.testing.expect(!parsed.value.object.contains("runtime"));
    phase = "guard divergence";
    try exerciseDivergentGuard(a, service, task, program, input, candidate);
}

fn advanceGeneratedOuter(
    a: std.mem.Allocator,
    service: anytype,
    initial: native.workspace.Work,
    runtime: contracts.workspace.Ref,
) !void {
    const work = try workspaceRef(a, .work, initial.id);
    for (0..512) |turn| {
        var current = try service.workspaceWork(a, initial.task, initial.id);
        defer current.deinit();
        _ = try service.workspacePump(
            a,
            try std.fmt.allocPrint(a, "generated-outer-{d}", .{turn}),
            initial.task,
            .{
                .expected = .{
                    .work = work,
                    .execution_revision = current.value.execution_revision,
                    .control_revision = current.value.control_revision,
                },
                .base_quantum = if (turn == 0) 1 else 1048576,
            },
        );
        var after = try service.workspaceWork(a, initial.task, initial.id);
        defer after.deinit();
        if (turn != 0 and after.value.outer_operation == null) return;
        try std.testing.expect(after.value.outer_operation != null);
        try std.testing.expectEqualDeep(initial.checkpoint, after.value.checkpoint);
        if (turn == 0) {
            const reference = after.value.outer_operation.?.capsule;
            const bytes = try service.namespace.store.object(a, reference, null);
            var capsule = try kosmos.RuntimeCapsule.read(a, bytes);
            defer capsule.deinit();
            try std.testing.expectEqual(.outer_execution, capsule.value.record.kind);
            try std.testing.expectEqualDeep(
                try nativeIdentity(runtime),
                capsule.value.record.artifact.digest,
            );
            try std.testing.expect(capsule.value.record.dependencies.len != 0);
            try restartGuardOwner(a, service);
            var restored = try service.workspaceWork(a, initial.task, initial.id);
            defer restored.deinit();
            try std.testing.expectEqualDeep(reference, restored.value.outer_operation.?.capsule);
        }
    }
    return error.GeneratedOuterDidNotComplete;
}

fn semanticGuestProgram(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    label: []const u8,
) !native.testing.state.Digest {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(
        a,
        try @import("workspace_sources.zig").semanticGuest(&builder),
    );
    defer a.free(document);
    const built = try service.workspaceCommand(a, label, task, .{ .program = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = document } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{
            .{ .effect = 0, .class = .input },
            .{ .effect = 1, .class = .observation },
            .{ .effect = 2, .class = .alternative },
        } },
    } } });
    return nativeIdentity(built.program.?);
}

fn semanticGuestReply(
    a: std.mem.Allocator,
    image: []const u8,
    requested: anytype,
    questions: *usize,
    prefixes: *usize,
    alternatives: *usize,
) !kosmos.invocation.Outcome {
    var request = try data.invocation.decode(data.invocation.Request, a, requested.request);
    defer request.deinit();
    const identity = request.value.binding.semantic_identity;
    const value = if (std.mem.endsWith(u8, identity, "/0")) answer: {
        questions.* += 1;
        break :answer try contracts.encodeOwned(bool, a, true);
    } else if (std.mem.endsWith(u8, identity, "/1")) answer: {
        prefixes.* += 1;
        var prefix = try contracts.decodeOwned(u64, a, request.value.binding.payload);
        defer prefix.deinit();
        try std.testing.expectEqual(@as(u64, 101), prefix.value);
        break :answer try contracts.encodeOwned(void, a, {});
    } else answer: {
        try std.testing.expect(std.mem.endsWith(u8, identity, "/2"));
        var observed = try contracts.decodeOwned(
            struct { void, ?u64 },
            a,
            request.value.binding.payload,
        );
        defer observed.deinit();
        try std.testing.expectEqual(
            @as(
                ?u64,
                if (alternatives.* == 0) null else if (alternatives.* == 1) 111 else 121,
            ),
            observed.value[1],
        );
        alternatives.* += 1;
        const Command = union(enum) { instantiate: u64, finish: void };
        break :answer try contracts.encodeOwned(Command, a, if (alternatives.* == 3)
            .{ .finish = {} }
        else
            .{ .instantiate = if (alternatives.* == 1) 10 else 20 });
    };
    defer a.free(value);
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request.value.request_identity,
        .value = value,
    });
    defer a.free(reply);
    return kosmos.invocation.invoke(a, .{
        .image = image,
        .instance = .{ .state = requested.state.? },
        .control = .{ .reply = reply },
    });
}

fn semanticGuestExecution(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
) !void {
    var built = try service.workspaceProgram(a, task, program);
    defer built.deinit();
    const image = try service.namespace.store.object(a, built.value.description.image, null);
    defer a.free(image);
    const input = try contracts.encodeOwned(@import(
        "workspace_sources.zig",
    ).SemanticGuestInput, a, .{ .yields = 2, .seed = 100 });
    defer a.free(input);
    var outcome = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .initial_args = input,
    } });
    defer outcome.deinit();
    var yields: usize = 0;
    var questions: usize = 0;
    var prefixes: usize = 0;
    var alternatives: usize = 0;
    for (0..64) |_| {
        const next = switch (outcome.record) {
            .yielded => |state| blk: {
                yields += 1;
                break :blk try kosmos.invocation.invoke(a, .{
                    .image = image,
                    .instance = .{ .state = state.? },
                    .control = .resume_yield,
                });
            },
            .requested => |requested| try semanticGuestReply(
                a,
                image,
                requested,
                &questions,
                &prefixes,
                &alternatives,
            ),
            .completed => |result| {
                var decoded = try contracts.decodeOwned(u64, a, result);
                defer decoded.deinit();
                try std.testing.expectEqual(@as(u64, 121), decoded.value);
                try std.testing.expectEqual(@as(usize, 4), yields);
                try std.testing.expectEqual(@as(usize, 1), questions);
                try std.testing.expectEqual(@as(usize, 1), prefixes);
                try std.testing.expectEqual(@as(usize, 3), alternatives);
                return;
            },
            else => return error.SemanticGuestDidNotComplete,
        };
        outcome.deinit();
        outcome = next;
    }
    return error.SemanticGuestDidNotComplete;
}

const SharedArm = struct {
    label: []const u8,
    runtime: ?contracts.workspace.Ref = null,
    candidate: ?contracts.workspace.Ref = null,
    construction_validation_ns: ?u64 = null,
};

const SharedArmResult = struct {
    initial: native.testing.state.Reference,
    reply: native.testing.state.Digest = undefined,
    checkpoints: [3]native.testing.state.Reference = undefined,
    outcomes: [3]native.testing.state.Reference = undefined,
    guest_work: u64 = 0,
    owner_restart_ns: u64 = 0,
    first_continuation_including_reconstruction_ns: u64 = 0,
    remaining_continuation_ns: u64 = 0,
    continuation_ns: u64 = 0,
    requested_backing_live_baseline: usize = 0,
    requested_backing_peak: usize = 0,
    requested_backing_live_end: usize = 0,
    requested_backing_peak_above_baseline: usize = 0,
    checkpoint_ns: u64 = 0,
    inspection_ns: u64 = 0,
    checkpoint_bytes: u64 = 0,
    outcome_bytes: u64 = 0,
    inspection_bytes: usize = 0,
    capsule_bytes: u64 = 0,
    trace_bytes: usize = 0,
    guard_reference_ns: u64 = 0,
    guard_candidate_ns: u64 = 0,
    guard_capsule_bytes: u64 = 0,
};

fn sharedElapsed(started: i96) u64 {
    return std.math.cast(
        u64,
        @max(0, std.Io.Clock.awake.now(std.testing.io).nanoseconds - started),
    ) orelse std.math.maxInt(u64);
}

fn sharedReply(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    label: []const u8,
) !void {
    const bytes = try service.namespace.store.object(a, work.current_port.?, null);
    defer a.free(bytes);
    var port = try contracts.decodeOwned(native.workspace.Port, a, bytes);
    defer port.deinit();
    _ = try service.workspaceInteract(a, try std.fmt.allocPrint(a, "shared-{s}-reply", .{
        label,
    }), work.task, .{
        .expected = .{
            .work = try workspaceRef(a, .work, work.id),
            .execution_revision = work.execution_revision,
            .control_revision = work.control_revision,
        },
        .port = try workspaceRef(a, .port, port.value.id),
        .generation = port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{
            .schema = try workspaceRef(a, .schema, port.value.interface.argument.digest),
            .json_text = .{ .bytes = "true" },
        } } },
    });
}

fn sharedAdvance(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    arm: SharedArm,
    cut: usize,
) !void {
    for (0..512) |turn| {
        var current = try service.workspaceWork(a, work.task, work.id);
        defer current.deinit();
        if (current.value.execution_revision != work.execution_revision) {
            try std.testing.expectEqual(
                work.execution_revision + 1,
                current.value.execution_revision,
            );
            if (arm.candidate != null) {
                try std.testing.expectEqual(.agreed, current.value.guard.?.disposition);
                try std.testing.expectEqual(cut + 1, current.value.guard.?.agreed_segments);
            }
            return;
        }
        const operation_id = try std.fmt.allocPrint(a, "shared-{s}-cut-{d}-pump-{d}", .{
            arm.label,
            cut,
            turn,
        });
        if (arm.candidate != null) {
            try std.testing.expect(current.value.guard.?.disposition != .diverged);
            try std.testing.expect(current.value.guard.?.failure == null);
            _ = try service.workspacePump(a, operation_id, work.task, .{
                .expected = .{
                    .work = try workspaceRef(a, .work, work.id),
                    .execution_revision = current.value.execution_revision,
                    .control_revision = current.value.control_revision,
                },
                .base_quantum = 1048576,
            });
        } else {
            _ = try service.workspaceControl(
                a,
                operation_id,
                work.task,
                work.id,
                current.value.execution_revision,
                current.value.control_revision,
                .advance,
            );
        }
    }
    return error.SharedComparisonDidNotAdvance;
}

fn sharedCut(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    cut: usize,
    result: *SharedArmResult,
) !void {
    try std.testing.expectEqual(
        if (cut < 2) native.testing.state.Outcome.yielded else .requested,
        work.outcome_kind,
    );
    result.checkpoints[cut] = work.checkpoint;
    result.outcomes[cut] = work.outcome;
    result.checkpoint_bytes += work.checkpoint.bytes;
    result.outcome_bytes += work.outcome.bytes;
    result.guest_work += work.guest_work;
    if (work.runtime_trace) |trace| {
        const encoded = try contracts.encodeOwned(
            kosmos.RuntimeInstrumentation.Output,
            a,
            trace.output,
        );
        defer a.free(encoded);
        result.trace_bytes += encoded.len;
    }
    if (cut != 2) return;
    var pending = try guardReplyOccurrence(a, service, work);
    defer pending.deinit();
    const bytes = try service.namespace.store.object(a, pending.value.request_object, null);
    defer a.free(bytes);
    var request = try data.invocation.decode(data.invocation.Request, a, bytes);
    defer request.deinit();
    try std.testing.expect(std.mem.endsWith(u8, request.value.binding.semantic_identity, "/1"));
    var payload = try contracts.decodeOwned(u64, a, request.value.binding.payload);
    defer payload.deinit();
    try std.testing.expectEqual(@as(u64, 101), payload.value);
    if (work.guard) |guard| {
        result.guard_reference_ns = guard.reference_nanoseconds;
        result.guard_candidate_ns = guard.candidate_nanoseconds;
        result.guard_capsule_bytes = guard.continuation.?.bytes;
    }
}

fn sharedPublicationCosts(
    a: std.mem.Allocator,
    service: anytype,
    work: native.workspace.Work,
    label: []const u8,
    result: *SharedArmResult,
) !void {
    const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    _ = try service.workspaceRequestCut(a, try std.fmt.allocPrint(a, "shared-{s}-checkpoint", .{
        label,
    }), work.task, .{
        .expected = .{
            .work = try workspaceRef(a, .work, work.id),
            .execution_revision = work.execution_revision,
            .control_revision = work.control_revision,
        },
        .level = .guest_cut,
    });
    result.checkpoint_ns = sharedElapsed(started);
    var retained = try service.workspaceWork(a, work.task, work.id);
    defer retained.deinit();
    result.capsule_bytes = retained.value.runtime_capsule.?.bytes;
    const inspect_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const inspected = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "shared-{s}-inspect", .{label}),
        work.task,
        .{ .work = .{ .inspect = .{ .work = try workspaceRef(a, .work, work.id) } } },
    );
    result.inspection_ns = sharedElapsed(inspect_started);
    result.inspection_bytes = inspected.observation_json.bytes.len;
}

fn sharedOwnerRestart(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    id: [32]u8,
    pending: anytype,
) !u64 {
    var settled = try service.workspaceWork(a, task, id);
    defer settled.deinit();
    const restart_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try restartGuardOwner(a, service);
    const elapsed = sharedElapsed(restart_started);
    var reopened = try service.workspaceWork(a, task, id);
    defer reopened.deinit();
    try std.testing.expectEqualDeep(settled.value.checkpoint, reopened.value.checkpoint);
    try std.testing.expectEqual(
        settled.value.execution_revision,
        reopened.value.execution_revision,
    );
    try std.testing.expectEqual(
        settled.value.control_revision,
        reopened.value.control_revision,
    );
    try std.testing.expectEqual(
        settled.value.realization_revision,
        reopened.value.realization_revision,
    );
    try std.testing.expectEqualDeep(settled.value.runtime, reopened.value.runtime);
    try std.testing.expectEqualDeep(
        settled.value.runtime_capsule,
        reopened.value.runtime_capsule,
    );
    try std.testing.expectEqualDeep(settled.value.guard, reopened.value.guard);
    try std.testing.expectEqualDeep(
        settled.value.current_occurrence,
        reopened.value.current_occurrence,
    );
    var reopened_pending = try guardReplyOccurrence(a, service, reopened.value);
    defer reopened_pending.deinit();
    try std.testing.expectEqualDeep(pending, reopened_pending.value.state.settled_reply);
    return elapsed;
}

fn finishSharedArm(
    a: std.mem.Allocator,
    meter: *kosmos.AllocationBudget,
    service: anytype,
    task: [16]u8,
    id: [32]u8,
    arm: SharedArm,
    result: *SharedArmResult,
) !void {
    meter.resetObservation();
    result.requested_backing_live_baseline = meter.live;
    for (0..3) |cut| {
        var before = try service.workspaceWork(a, task, id);
        defer before.deinit();
        const continuation_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        try sharedAdvance(a, service, before.value, arm, cut);
        const continuation_ns = sharedElapsed(continuation_started);
        result.continuation_ns +|= continuation_ns;
        if (cut == 0) {
            result.first_continuation_including_reconstruction_ns = continuation_ns;
        } else {
            result.remaining_continuation_ns +|= continuation_ns;
        }
        var after = try service.workspaceWork(a, task, id);
        defer after.deinit();
        try sharedCut(a, service, after.value, cut, result);
    }
    result.requested_backing_peak = meter.peak;
    result.requested_backing_live_end = meter.live;
    const baseline = result.requested_backing_live_baseline;
    result.requested_backing_peak_above_baseline = meter.peak - baseline;
    var final = try service.workspaceWork(a, task, id);
    defer final.deinit();
    try sharedPublicationCosts(a, service, final.value, arm.label, result);
    try sharedCancel(a, service, task, id, arm.label);
}

fn sharedArm(
    a: std.mem.Allocator,
    meter: *kosmos.AllocationBudget,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    input: []const u8,
    arm: SharedArm,
) !SharedArmResult {
    const started = try service.workspaceStart(a, try std.fmt.allocPrint(a, "shared-{s}-start", .{
        arm.label,
    }), task, program, input, .{});
    const id = started.receipt.workspace.?;
    var initial = try service.workspaceWork(a, task, id);
    defer initial.deinit();
    try std.testing.expectEqual(.requested, initial.value.outcome_kind);
    var result: SharedArmResult = .{ .initial = initial.value.checkpoint };
    const expected: contracts.workspace.Expected = .{
        .work = try workspaceRef(a, .work, id),
        .execution_revision = initial.value.execution_revision,
        .control_revision = initial.value.control_revision,
    };
    if (arm.runtime) |runtime| _ = try service.workspaceRealize(
        a,
        try std.fmt.allocPrint(a, "shared-{s}-select", .{arm.label}),
        task,
        .{
            .expected = expected,
            .realization_revision = initial.value.realization_revision,
            .runtime = .{ .selected = runtime },
        },
    );
    if (arm.candidate) |candidate| _ = try service.workspaceGuard(
        a,
        try std.fmt.allocPrint(a, "shared-{s}-guard", .{arm.label}),
        task,
        .{ .guard = .{
            .expected = expected,
            .realization_revision = initial.value.realization_revision,
            .candidate = candidate,
        } },
    );
    var selected = try service.workspaceWork(a, task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(result.initial, selected.value.checkpoint);
    try sharedReply(a, service, selected.value, arm.label);
    var pending = try guardReplyOccurrence(a, service, selected.value);
    defer pending.deinit();
    result.reply = pending.value.state.settled_reply.reply;
    result.owner_restart_ns = try sharedOwnerRestart(
        a,
        service,
        task,
        id,
        pending.value.state.settled_reply,
    );
    try finishSharedArm(a, meter, service, task, id, arm, &result);
    return result;
}

fn sharedCancel(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    id: native.testing.state.Digest,
    label: []const u8,
) !void {
    for (0..32) |turn| {
        var work = try service.workspaceWork(a, task, id);
        defer work.deinit();
        if (work.value.terminal()) {
            try std.testing.expectEqual(.cancelled, work.value.outcome_kind);
            try std.testing.expect(work.value.guard == null);
            const bytes = try service.namespace.store.object(a, work.value.outcome, null);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            try std.testing.expect(native.tasks.cleanupComplete(outcome.value));
            return;
        }
        _ = try service.workspaceControl(
            a,
            try std.fmt.allocPrint(a, "shared-{s}-cleanup-{d}", .{ label, turn }),
            task,
            id,
            work.value.execution_revision,
            work.value.control_revision,
            if (turn == 0 and work.value.cancellation == null)
                .{ .cancel = .{ .bytes = "shared comparison complete" } }
            else
                .advance,
        );
    }
    return error.SharedComparisonDidNotCancel;
}

fn sharedArtifactCosts(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    arm: SharedArm,
) !struct {
    artifact: usize,
    evidence: usize,
    proposal: u64,
} {
    var generic = try service.program.retainRuntime();
    defer generic.deinit();
    if (arm.runtime == null and arm.candidate == null) {
        const bytes = try generic.encode(a);
        defer a.free(bytes);
        return .{
            .artifact = bytes.len,
            .evidence = generic.content.value.evidence.len,
            .proposal = 0,
        };
    }
    var proposal: u64 = 0;
    const reference = if (arm.runtime) |runtime|
        try service.namespace.store.objectReference(try nativeIdentity(runtime), null)
    else candidate: {
        var selected = try service.workspaceCandidate(a, task, try nativeIdentity(arm.candidate.?));
        defer selected.deinit();
        proposal = selected.value.description.proposal.bytes;
        break :candidate selected.value.description.code;
    };
    const bytes = try service.namespace.store.object(a, reference, null);
    defer a.free(bytes);
    var artifact = try kosmos.RuntimeArtifact.init(a, bytes, reference.digest);
    defer artifact.deinit();
    var total = bytes.len;
    var evidence = artifact.content.value.evidence.len;
    if (arm.candidate != null) {
        const packaged = try generic.encode(a);
        defer a.free(packaged);
        total += packaged.len;
        evidence += generic.content.value.evidence.len;
    }
    return .{ .artifact = total, .evidence = evidence, .proposal = proposal };
}

fn sharedCompare(
    a: std.mem.Allocator,
    service: anytype,
    expected: SharedArmResult,
    actual: SharedArmResult,
) !void {
    try std.testing.expectEqualDeep(expected.initial, actual.initial);
    try std.testing.expectEqualDeep(expected.reply, actual.reply);
    try std.testing.expectEqual(expected.guest_work, actual.guest_work);
    for (
        expected.checkpoints,
        actual.checkpoints,
        expected.outcomes,
        actual.outcomes,
    ) |left, right, left_outcome, right_outcome| {
        const state_before = try service.namespace.store.object(a, left, null);
        defer a.free(state_before);
        const state_after = try service.namespace.store.object(a, right, null);
        defer a.free(state_after);
        try std.testing.expectEqualSlices(u8, state_before, state_after);
        const outcome_before = try service.namespace.store.object(a, left_outcome, null);
        defer a.free(outcome_before);
        const outcome_after = try service.namespace.store.object(a, right_outcome, null);
        defer a.free(outcome_after);
        try std.testing.expectEqualSlices(u8, outcome_before, outcome_after);
    }
}

fn printSharedComparison(generated: GeneratedRuntime) void {
    std.debug.print(
        "shared comparison: " ++
            "scope=three-cuts-from-identical-retained-request-after-owner-rest" ++
            "art controls=true,resume_yield,resume_yield " ++
            "expected=yielded,yielded,prefix101 " ++
            "includes=continuation-and-persistence " ++
            "excludes=initialization-selection-reply-acquisition-cleanup " ++
            "reconstruction=first-continuation-including-execution-and-publica" ++
            "tion-not-isolated-restore " ++
            "requested_memory=root-requested-Zig-backing-bytes " ++
            "memory_scope=three-cuts-and-cut-assertions " ++
            "memory_baseline=retained-owners-and-arenas " ++
            "memory_excludes=restart-publication-costs-cleanup-artifact-compar" ++
            "ison-C-SQLite-OS-RSS allocator_resize_remap=disabled " ++
            "timing=instrumented-no-speedup-claim " ++
            "generated_construction_ns={d} generated_validation_ns={d} " ++
            "producer_build_ns={any} guard_agreement=finite-only " ++
            "byte_counts=logical-references-not-deduplicated-footprint\n",
        .{ generated.construction_ns, generated.validation_ns, generated.producer_build_ns },
    );
}

fn printSharedArm(arm: SharedArm, result: SharedArmResult, costs: anytype) void {
    std.debug.print(
        "shared arm={s} construction_validation_ns={any} " ++
            "owner_restart_ns={d} " ++
            "first_continuation_including_reconstruction_ns={d} " ++
            "remaining_continuation_ns={d} continuation_ns={d} " ++
            "requested_backing_live_baseline={d} requested_backing_peak={d} " ++
            "requested_backing_live_end={d} " ++
            "requested_backing_peak_above_baseline={d} guest_work={d} " ++
            "checkpoint_publication_ns={d} inspection_ns={d} " ++
            "artifact_bytes={d} evidence_bytes={d} " ++
            "candidate_proposal_bytes={d} " ++
            "published_guest_checkpoint_bytes={d} published_outcome_bytes={d} " ++
            "retained_capsule_bytes={d} inspection_bytes={d} trace_bytes={d} " ++
            "guard_reference_ns={d} guard_candidate_ns={d} " ++
            "guard_capsule_bytes={d}\n",
        .{
            arm.label,
            arm.construction_validation_ns,
            result.owner_restart_ns,
            result.first_continuation_including_reconstruction_ns,
            result.remaining_continuation_ns,
            result.continuation_ns,
            result.requested_backing_live_baseline,
            result.requested_backing_peak,
            result.requested_backing_live_end,
            result.requested_backing_peak_above_baseline,
            result.guest_work,
            result.checkpoint_ns,
            result.inspection_ns,
            costs.artifact,
            costs.evidence,
            costs.proposal,
            result.checkpoint_bytes,
            result.outcome_bytes,
            result.capsule_bytes,
            result.inspection_bytes,
            result.trace_bytes,
            result.guard_reference_ns,
            result.guard_candidate_ns,
            result.guard_capsule_bytes,
        },
    );
}

fn sharedComparison(
    a: std.mem.Allocator,
    meter: *kosmos.AllocationBudget,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    generated: GeneratedRuntime,
    specialized: contracts.workspace.Ref,
    specialization_ns: u64,
) !void {
    const instrumentation_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const instrumented = try service.workspaceSpecializeWithHooks(
        a,
        "shared-instrument",
        task,
        program,
        .{ .control = true, .storage = true },
    );
    const instrumentation_ns = sharedElapsed(instrumentation_started);
    const previous_roots = service.profile.semantic_construction.?.roots;
    const roots = [_][32]u8{
        previous_roots[0],
        previous_roots[1],
        kosmos.RuntimeCompiler.approvedRootIdentity(&service.runtime_cache.?.artifact),
    };
    service.profile.semantic_construction.?.roots = &roots;
    defer service.profile.semantic_construction.?.roots = previous_roots;
    const input = try contracts.encodeOwned(@import(
        "workspace_sources.zig",
    ).SemanticGuestInput, a, .{ .yields = 0, .seed = 100 });
    defer a.free(input);
    const arms = [_]SharedArm{
        .{ .label = "generic" },
        .{
            .label = "specialized",
            .runtime = specialized,
            .construction_validation_ns = specialization_ns,
        },
        .{ .label = "generated", .runtime = generated.runtime },
        .{
            .label = "instrumented",
            .runtime = try workspaceRef(a, .runtime, instrumented.receipt.workspace.?),
            .construction_validation_ns = instrumentation_ns,
        },
        .{ .label = "guarded", .candidate = generated.candidate },
    };
    printSharedComparison(generated);
    var baseline: ?SharedArmResult = null;
    for (arms) |arm| {
        const result = try sharedArm(a, meter, service, task, program, input, arm);
        if (baseline) |expected| try sharedCompare(
            a,
            service,
            expected,
            result,
        ) else baseline = result;
        const costs = try sharedArtifactCosts(a, service, task, arm);
        printSharedArm(arm, result, costs);
    }
}

fn sharedSuccessorComparison(
    a: std.mem.Allocator,
    meter: *kosmos.AllocationBudget,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    generated: GeneratedRuntime,
) !void {
    const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const specialized = try service.workspaceSpecialize(a, "specialize", task, program);
    const specialization_ns = sharedElapsed(started);
    const previous_roots = service.profile.semantic_construction.?.roots;
    const roots = [_][32]u8{
        previous_roots[0],
        kosmos.RuntimeCompiler.approvedRootIdentity(&service.runtime_cache.?.artifact),
    };
    service.profile.semantic_construction.?.roots = &roots;
    defer service.profile.semantic_construction.?.roots = previous_roots;
    try sharedComparison(
        a,
        meter,
        service,
        task,
        program,
        generated,
        try workspaceRef(a, .runtime, specialized.receipt.workspace.?),
        specialization_ns,
    );
}

fn interpretationProgram(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    guest: *const data.program_image.Admitted,
    snapshot: @FieldType(kosmos.RuntimeAnalysis.InterpretationOutput, "state"),
    label: []const u8,
) !native.testing.state.Digest {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try kosmos.RuntimeAnalysis.interpretation(&builder, guest, snapshot);
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(a, label, task, text, &diagnostic);
    return built.receipt.workspace.?;
}

fn expectInterpretationIdentity(
    a: std.mem.Allocator,
    evidence: native.json.Value,
    field: []const u8,
    expected: [32]u8,
) !void {
    const reference = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        evidence.object.get(field).?,
    );
    try std.testing.expectEqualDeep(expected, try nativeIdentity(reference));
}

fn inspectInterpretation(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    program: [32]u8,
    label: []const u8,
    current: native.workspace.Work,
) !contracts.Decoded(kosmos.RuntimeAnalysis.InterpretationOutput) {
    try std.testing.expectEqual(.completed, current.outcome_kind);
    const inspection = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "{s}-inspect", .{label}),
        task,
        .{ .work = .{ .inspect = .{ .work = try workspaceRef(a, .work, current.id) } } },
    );
    var observation = try native.json.parseAsset(
        a,
        inspection.observation_json.bytes,
        inspection.observation_json.bytes.len,
    );
    defer observation.deinit();
    const evidence = observation.value.object.get("interpretation_evidence").?;
    try std.testing.expectEqualStrings(
        "experimental",
        evidence.object.get("evidence_class").?.string,
    );
    try std.testing.expectEqual(
        .null,
        std.meta.activeTag(evidence.object.get("analysis_checker").?),
    );
    try expectInterpretationIdentity(a, evidence, "program", program);
    try expectInterpretationIdentity(a, evidence, "work", current.id);
    try expectInterpretationIdentity(a, evidence, "input", current.input_value.?.digest);
    const bytes = try service.namespace.store.object(a, current.result.?, null);
    defer a.free(bytes);
    return contracts.decodeOwned(kosmos.RuntimeAnalysis.InterpretationOutput, a, bytes);
}

fn runInterpretation(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    assumptions: []const []const u8,
    label: []const u8,
) !contracts.Decoded(kosmos.RuntimeAnalysis.InterpretationOutput) {
    const input = try contracts.encodeOwned(kosmos.RuntimeAnalysis.InterpretationInput, a, .{
        .arguments = &.{},
        .assumptions = assumptions,
        .guest_quantum = 256,
    });
    defer a.free(input);
    const started = try service.workspaceStart(a, label, task, program, input, .{
        .stop = .terminal,
    });
    for (0..4096) |turn| {
        var current = try service.workspaceWork(a, task, started.receipt.workspace.?);
        defer current.deinit();
        if (current.value.terminal()) {
            return inspectInterpretation(a, service, task, program, label, current.value);
        }
        _ = try service.workspaceControl(
            a,
            try std.fmt.allocPrint(a, "{s}-advance-{d}", .{ label, turn }),
            task,
            current.value.id,
            current.value.execution_revision,
            current.value.control_revision,
            .advance,
        );
    }
    return error.InterpretationDidNotComplete;
}

fn assertInterpretationBranches(
    a: std.mem.Allocator,
    service: anytype,
    original: native.workspace.Work,
    guest: [32]u8,
    positive: kosmos.RuntimeAnalysis.InterpretationOutput,
    negative: kosmos.RuntimeAnalysis.InterpretationOutput,
) !void {
    for ([_]kosmos.RuntimeAnalysis.InterpretationOutput{ positive, negative }) |result| {
        try std.testing.expectEqual(.yielded, result.stopping);
        try std.testing.expectEqual(@as(u64, 1), result.applied);
        try std.testing.expectEqual(@as(usize, 1), result.requests.len);
        try std.testing.expectEqualDeep(guest, result.guest);
    }
    try std.testing.expectEqualSlices(u8, &.{1}, positive.assumptions[0]);
    try std.testing.expectEqualSlices(u8, &.{0}, negative.assumptions[0]);
    const State = @FieldType(kosmos.RuntimeAnalysis.InterpretationOutput, "state");
    try std.testing.expect(!data.record.equal(State, positive.state, negative.state));
    var unchanged = try service.workspaceWork(a, original.task, original.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(original.checkpoint, unchanged.value.checkpoint);
    try std.testing.expectEqualDeep(
        original.current_occurrence,
        unchanged.value.current_occurrence,
    );
    try std.testing.expectEqual(original.execution_revision, unchanged.value.execution_revision);
    try std.testing.expectEqual(original.control_revision, unchanged.value.control_revision);
}

fn exerciseInterpretationBranches(
    a: std.mem.Allocator,
    service: anytype,
    original: native.workspace.Work,
    guest: *const data.program_image.Admitted,
    resumed: [32]u8,
    phase: *[]const u8,
) !void {
    phase.* = "true assumption execution";
    var positive = try runInterpretation(
        a,
        service,
        original.task,
        resumed,
        &.{&.{1}},
        "semantic-interpretation-true",
    );
    defer positive.deinit();
    phase.* = "false assumption execution";
    var negative = try runInterpretation(
        a,
        service,
        original.task,
        resumed,
        &.{&.{0}},
        "semantic-interpretation-false",
    );
    defer negative.deinit();
    phase.* = "branch provenance and original state";
    try assertInterpretationBranches(
        a,
        service,
        original,
        guest.identity(),
        positive.value,
        negative.value,
    );
}

fn semanticGuestInterpretation(
    a: std.mem.Allocator,
    service: anytype,
    original: native.workspace.Work,
) !void {
    var phase: []const u8 = "guest snapshot";
    errdefer std.debug.print("semantic interpretation: {s}\n", .{phase});
    var program = try service.workspaceProgram(a, original.task, original.program);
    defer program.deinit();
    const image = try service.namespace.store.object(a, program.value.description.image, null);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var snapshot = try semanticGuestSnapshot(a, service, original);
    defer snapshot.deinit();
    phase = "initial program construction";
    const analysis = try interpretationProgram(
        a,
        service,
        original.task,
        guest,
        snapshot.value.snapshot.?,
        "semantic-interpretation-build",
    );
    phase = "missing assumption execution";
    var unfinished = try runInterpretation(
        a,
        service,
        original.task,
        analysis,
        &.{},
        "semantic-interpretation-missing",
    );
    defer unfinished.deinit();
    try std.testing.expectEqual(.missing_assumption, unfinished.value.stopping);
    try std.testing.expectEqual(@as(u64, 0), unfinished.value.applied);
    try std.testing.expectEqualDeep(guest.identity(), unfinished.value.guest);
    phase = "resumed program construction";
    const resumed = try interpretationProgram(
        a,
        service,
        original.task,
        guest,
        unfinished.value.state,
        "semantic-interpretation-resume-build",
    );
    try exerciseInterpretationBranches(a, service, original, guest, resumed, &phase);
}

fn semanticGuestSnapshot(
    a: std.mem.Allocator,
    service: anytype,
    original: native.workspace.Work,
) !contracts.Decoded(kosmos.RuntimeViews.DetailedView) {
    const selection: contracts.workspace.GuestViewSelection = .{
        .expected = .{
            .work = try workspaceRef(a, .work, original.id),
            .execution_revision = original.execution_revision,
            .control_revision = original.control_revision,
        },
        .realization_revision = original.realization_revision,
        .nodes = .{ .all = .{} },
        .disclosure = .{ .snapshot = true, .values = .{ .nodes = .{ .all = .{} } } },
    };
    try rejectPartialSnapshots(a, service, original.task, selection);
    const response = try service.workspaceCommand(a, "semantic-snapshot", original.task, .{
        .context = .{ .materialize = .{
            .input = .{ .guest_view = selection },
            .sources = .{ .items = &.{} },
        } },
    });
    if (response.disposition != .observed)
        std.debug.print("semantic snapshot: {s}\n", .{response.observation_json.bytes});
    try std.testing.expectEqual(.observed, response.disposition);
    const value_id = try nativeIdentity(response.evidence.?);
    const custody = try native.workspace.custodyId(a, original.task, value_id);
    const record = (try service.namespace.store.recordBytes(
        a,
        "workspace_value",
        custody,
        original.task,
    )).?;
    defer a.free(record);
    var value = try contracts.decodeOwned(native.workspace.Value, a, record);
    defer value.deinit();
    const origin = value.value.derivation.inspection.?;
    try std.testing.expect(origin.disclosure.?.snapshot);
    try std.testing.expectEqualDeep(original.checkpoint, origin.observation.work.checkpoint);
    const bytes = try service.namespace.store.object(a, value.value.description.value, null);
    defer a.free(bytes);
    var disclosed = try contracts.decodeOwned(kosmos.RuntimeViews.DetailedView, a, bytes);
    errdefer disclosed.deinit();
    const bound = disclosed.value.metadata.binding;
    try std.testing.expectEqualDeep(original.id, bound.execution);
    try std.testing.expectEqualDeep(original.checkpoint.digest, bound.checkpoint);
    const checkpoint = try data.state_image.emit(a, disclosed.value.snapshot.?);
    defer a.free(checkpoint);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(checkpoint, &digest, .{});
    try std.testing.expectEqualDeep(original.checkpoint.digest, digest);
    try std.testing.expectEqual(original.checkpoint.bytes, checkpoint.len);
    return disclosed;
}

fn rejectPartialSnapshots(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    original: contracts.workspace.GuestViewSelection,
) !void {
    for (0..2) |index| {
        var selected = original;
        if (index == 0) selected.nodes = .{ .selected = .{ .items = &.{} } } else {
            selected.level = .outer_execution;
        }
        const operation_id = if (index == 0)
            "semantic-partial-snapshot"
        else
            "semantic-outer-snapshot";
        const response = try service.workspaceCommand(a, operation_id, task, .{
            .context = .{ .materialize = .{
                .input = .{ .guest_view = selected },
                .sources = .{ .items = &.{} },
            } },
        });
        try std.testing.expectEqual(.rejected, response.disposition);
    }
}

fn replaceGeneratedRuntime(
    a: std.mem.Allocator,
    service: anytype,
    selected: native.workspace.Work,
    work: contracts.workspace.Ref,
    generated: GeneratedRuntime,
    reused: GeneratedRuntime,
) !void {
    const task = selected.task;
    const id = selected.id;
    try advanceGeneratedOuter(a, service, selected, generated.runtime);
    var advanced = try service.workspaceWork(a, task, id);
    defer advanced.deinit();
    try std.testing.expect(advanced.value.execution_revision > selected.execution_revision);
    try std.testing.expectEqualDeep(
        try nativeIdentity(generated.runtime),
        advanced.value.runtime.?.digest,
    );
    _ = try service.workspaceRealize(a, "generated-reused-select", task, .{
        .expected = .{
            .work = work,
            .execution_revision = advanced.value.execution_revision,
            .control_revision = advanced.value.control_revision,
        },
        .realization_revision = advanced.value.realization_revision,
        .runtime = .{ .selected = reused.runtime },
    });
    var reselected = try service.workspaceWork(a, task, id);
    defer reselected.deinit();
    try std.testing.expectEqualDeep(advanced.value.checkpoint, reselected.value.checkpoint);
    _ = try service.workspaceRealize(a, "generated-return", task, .{
        .expected = .{
            .work = work,
            .execution_revision = reselected.value.execution_revision,
            .control_revision = reselected.value.control_revision,
        },
        .realization_revision = reselected.value.realization_revision,
        .runtime = .{ .packaged = .{} },
    });
    var returned = try service.workspaceWork(a, task, id);
    defer returned.deinit();
    try std.testing.expectEqualDeep(advanced.value.checkpoint, returned.value.checkpoint);
    try std.testing.expect(returned.value.runtime == null);
    try sharedCancel(a, service, task, id, "generated-retained");
}

fn realizeGeneratedRuntime(
    a: std.mem.Allocator,
    service: anytype,
    before: native.workspace.Work,
    generated: GeneratedRuntime,
    reused: GeneratedRuntime,
) !void {
    const task = before.task;
    const id = before.id;
    const work = try workspaceRef(a, .work, id);
    _ = try service.workspaceRealize(a, "generated-select", task, .{
        .expected = .{
            .work = work,
            .execution_revision = before.execution_revision,
            .control_revision = before.control_revision,
        },
        .realization_revision = before.realization_revision,
        .runtime = .{ .selected = generated.runtime },
    });
    var selected = try service.workspaceWork(a, task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(before.checkpoint, selected.value.checkpoint);
    const inspected = try service.workspaceCommand(a, "generated-selected-source", task, .{
        .program = .{ .inspect = .{
            .target = .{ .semantic_source = .{
                .subject = .{ .work = .{
                    .expected = .{
                        .work = work,
                        .execution_revision = selected.value.execution_revision,
                        .control_revision = selected.value.control_revision,
                    },
                    .realization_revision = selected.value.realization_revision,
                } },
                .section = .{ .summary = .{} },
            } },
            .page = .{ .maximum = 128 },
        } },
    });
    try std.testing.expectEqualDeep(
        generated.runtime,
        try semanticReference(a, inspected, "runtime"),
    );
    try replaceGeneratedRuntime(a, service, selected.value, work, generated, reused);
}

fn exerciseGenerated(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: native.testing.state.Digest,
    input: []const u8,
) !GeneratedRuntime {
    const started = try service.workspaceStart(a, "generated-retain", task, program, input, .{});
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    try std.testing.expect(!before.value.terminal());
    try std.testing.expect(before.value.runtime == null);
    const ancestor = try semanticWork(a, before.value);
    try expectPackagedSemanticInspection(a, service, task, ancestor, "packaged-work");
    var parent = try service.task(a, task);
    defer parent.deinit();
    try expectPackagedSemanticInspection(a, service, task, .{ .controller = .{ .cut = .{
        .epoch = parent.value.controller_epoch,
        .execution_revision = parent.value.execution_revision,
        .realization_revision = parent.value.realization_revision,
    } } }, "packaged-controller");
    const generated = try generatedRuntime(a, service, task, program, ancestor, "generated", input);
    {
        var scratch = std.heap.ArenaAllocator.init(service.allocator);
        defer scratch.deinit();
        try expectValidationResourceOutcome(scratch.allocator(), service, task, generated);
    }
    {
        var scratch = std.heap.ArenaAllocator.init(service.allocator);
        defer scratch.deinit();
        try exerciseWrongCandidate(
            scratch.allocator(),
            service,
            task,
            program,
            input,
            ancestor,
            generated.result,
        );
    }
    const reused = try generatedFromProducer(
        a,
        service,
        task,
        program,
        .{ .runtime = generated.runtime },
        generated.producer,
        "generated-reused",
        null,
        false,
    );
    try std.testing.expectEqualDeep(generated.producer, reused.producer);
    try std.testing.expect(
        !std.meta.eql(try nativeIdentity(generated.result), try nativeIdentity(reused.result)),
    );
    try realizeGeneratedRuntime(a, service, before.value, generated, reused);
    return generated;
}

fn inspectGeneratedArchive(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    generated: GeneratedRuntime,
) !void {
    const runtime = try service.workspaceCommand(a, "generated-imported-runtime", task, .{
        .program = .{ .inspect = .{
            .target = .{ .semantic_source = .{
                .subject = .{ .runtime = generated.runtime },
                .section = .{ .summary = .{} },
            } },
            .page = .{ .maximum = 4096 },
        } },
    });
    try std.testing.expectEqual(.observed, runtime.disposition);
    const result = try service.workspaceCommand(a, "generated-imported-result", task, .{
        .context = .{ .expand = .{
            .reference = generated.result,
            .page = .{ .maximum = 128 },
        } },
    });
    try std.testing.expectEqual(.observed, result.disposition);
    const producer = try service.workspaceCommand(a, "generated-imported-producer", task, .{
        .program = .{ .inspect = .{
            .target = .{ .program = generated.producer },
            .page = .{ .maximum = 128 },
        } },
    });
    try std.testing.expectEqual(.observed, producer.disposition);
}

fn inspectPackagedPages(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    label: []const u8,
    response: contracts.workspace.Reply,
    returned: contracts.workspace.SemanticTarget,
    identity: []const u8,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var next_offset: ?u64 = 0;
    while (next_offset) |offset| {
        const part = if (offset == 0) response else try service.workspaceCommand(
            a,
            try std.fmt.allocPrint(a, "{s}-page-{d}", .{ label, offset }),
            task,
            .{ .program = .{ .inspect = .{
                .target = .{
                    .semantic_source = .{ .subject = returned, .section = .{ .summary = .{} } },
                },
                .page = .{ .offset = offset },
            } } },
        );
        try std.testing.expectEqual(.observed, part.disposition);
        var page = try native.json.parse(a, part.observation_json.bytes, .{});
        defer page.deinit();
        try text.appendSlice(a, page.value.object.get("text").?.string);
        if (page.value.object.get("eof").?.bool) break;
        const next = try native.json.numberInteger(
            u64,
            page.value.object.get("next_offset").?.number_string,
        );
        try std.testing.expect(next > offset);
        next_offset = next;
    }
    var summary = try native.json.parse(a, text.items, .{});
    defer summary.deinit();
    try std.testing.expect(!summary.value.object.contains("runtime"));
    try std.testing.expectEqualStrings(
        identity,
        summary.value.object.get("runtime_identity").?.string,
    );
}

fn expectPackagedSemanticInspection(
    a: std.mem.Allocator,
    service: anytype,
    task: [16]u8,
    subject: contracts.workspace.SemanticTarget,
    label: []const u8,
) !void {
    errdefer std.debug.print("packaged semantic inspection: {s}\n", .{label});
    const response = try service.workspaceCommand(a, label, task, .{ .program = .{ .inspect = .{
        .target = .{ .semantic_source = .{ .subject = subject, .section = .{ .summary = .{} } } },
        .page = .{},
    } } });
    try std.testing.expectEqual(.observed, response.disposition);
    var parsed = try native.json.parse(a, response.observation_json.bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.contains("runtime"));
    var packaged = try service.program.retainRuntime();
    defer packaged.deinit();
    const identity = std.fmt.bytesToHex(packaged.identity, .lower);
    try std.testing.expectEqualStrings(
        &identity,
        parsed.value.object.get("runtime_identity").?.string,
    );
    const returned = try native.values.fromJson(
        contracts.workspace.SemanticTarget,
        a,
        parsed.value.object.get("subject").?,
    );
    try std.testing.expectEqualDeep(subject, returned);
    const again = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-returned", .{
        label,
    }), task, .{ .program = .{ .inspect = .{
        .target = .{ .semantic_source = .{ .subject = returned, .section = .{ .summary = .{} } } },
        .page = .{},
    } } });
    try std.testing.expectEqual(.observed, again.disposition);
    try std.testing.expectEqualStrings(
        response.observation_json.bytes,
        again.observation_json.bytes,
    );
    try inspectPackagedPages(a, service, task, label, response, returned, &identity);
}

const CleanupTrace = struct {
    scans: usize = 0,
    work_reads: usize = 0,
    history_scans: usize = 0,
    extern "c" fn sqlite3_db_handle(?*anyopaque) ?*anyopaque;
    extern "c" fn sqlite3_expanded_sql(?*anyopaque) ?[*:0]u8;
    extern "c" fn sqlite3_free(?*anyopaque) void;
    extern "c" fn sqlite3_trace_v2(
        ?*anyopaque,
        c_uint,
        ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
        ?*anyopaque,
    ) c_int;

    fn observe(
        _: c_uint,
        context: ?*anyopaque,
        statement: ?*anyopaque,
        sql: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(sql.?)));
        if (std.mem.eql(
            u8,
            text,
            "SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id",
        )) self.scans += 1;
        if (std.mem.eql(
            u8,
            text,
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                "WHERE e.task=? AND e.seq<=? ORDER BY e.seq",
        )) self.history_scans += 1;
        if (std.mem.eql(u8, text, "SELECT body FROM records WHERE kind=? AND id=? AND task=?")) {
            const expanded = sqlite3_expanded_sql(statement) orelse return 0;
            defer sqlite3_free(expanded);
            if (std.mem.startsWith(
                u8,
                std.mem.span(expanded),
                "SELECT body FROM records WHERE kind='workspace_work'",
            )) self.work_reads += 1;
        }
        return 0;
    }
};

fn withWorkspaceFixture(
    identity: []const u8,
    profile_text: []const u8,
    comptime exercise: anytype,
) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try gcd(&builder);
    const entry = &builder.functions.items[@intCast(module.entry)];
    for (0..2) |_| entry.body = try builder.term(.{ .yield_then = entry.body.? });
    var root = try compile(a, &builder, builder.module(module.entry, module.failure));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = identity,
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), identity);
    defer a.free(manifest);
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = identity,
        .manifest = manifest,
    };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = profile_text, .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    try exercise(a, io, assets, &application, handlers, profile);
}

test "scheduler bounds cleanup scans during productive scheduling and completes idle sweeps" {
    try withWorkspaceFixture("scheduler-unit", "scheduler-test", exerciseSchedulerSweeps);
}

fn observeSchedulerSweeps(
    scratch: std.mem.Allocator,
    service: anytype,
    namespace: *native.Namespace,
    count: usize,
    ids: []const native.testing.state.TaskId,
) !bool {
    var statement = try namespace.store.database.prepare("SELECT 1", &.{});
    const database = CleanupTrace.sqlite3_db_handle(statement.handle);
    statement.deinit();
    var trace: CleanupTrace = .{};
    try std.testing.expectEqual(
        @as(c_int, 0),
        CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace),
    );
    defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
    for (0..count) |_| try std.testing.expect(try service.pump(scratch) != .idle);
    std.debug.print("cleanup scans: owners={d} productive_pumps={d} scans={d}\n", .{
        count,
        count,
        trace.scans,
    });
    const productive_scan_bound = trace.scans == count;
    for (ids) |id| {
        var task = try service.task(scratch, id);
        defer task.deinit();
        try std.testing.expect(task.value.execution_revision > 0);
    }
    try service.park(scratch);
    trace.scans = 0;
    try std.testing.expectEqual(.idle, try service.pump(scratch));
    try std.testing.expectEqual(count, trace.scans);
    return productive_scan_bound;
}

fn measureSchedulerSweeps(
    a: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
    directory: []const u8,
    count: usize,
) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const path = try std.fmt.allocPrint(scratch, "{s}/tasks-{d}", .{ directory, count });
    var namespace = try native.Namespace.open(a, io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    const ids = try scratch.alloc(native.testing.state.TaskId, count);
    for (ids, 0..) |*id, index| id.* = (try service.submit(
        scratch,
        try std.fmt.allocPrint(scratch, "task-{d}", .{index}),
        .{ 25, 5 },
    )).receipt.task;
    return observeSchedulerSweeps(scratch, &service, &namespace, count, ids);
}

fn exerciseSchedulerSweeps(
    a: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    var productive_scan_bound = true;
    for ([_]usize{ 8, 32 }) |count| {
        const within_bound = try measureSchedulerSweeps(
            a,
            io,
            assets,
            application,
            handlers,
            profile,
            path_buffer[0..length],
            count,
        );
        productive_scan_bound = productive_scan_bound and within_bound;
    }
    try std.testing.expect(productive_scan_bound);
}

fn prefixIdentity(value: usize) [32]u8 {
    var id: [32]u8 = @splat(0);
    std.mem.writeInt(u64, id[0..8], @intCast(value), .little);
    return id;
}

fn prefixPublication(a: std.mem.Allocator, index: usize) !native.testing.state.WorkPublication {
    const id = prefixIdentity(index);
    const source_id = prefixIdentity(10000 + index % 3);
    const empty: native.testing.state.Reference = .{ .digest = @splat(0), .bytes = 0 };
    return .{
        .work = id,
        .execution_revision = 1,
        .control_revision = 1,
        .observation = id,
        .control = .{
            .policy = .{},
            .schedule = .queued,
            .blocker = null,
            .cancellation = null,
            .cancellation_applied = false,
            .outcome = .progressed,
            .instrument = false,
            .port = false,
            .delivery = null,
        },
        .observer = .{
            .selection = .{
                .program = try workspaceRef(a, .program, prefixIdentity(20000)),
                .accumulator = try workspaceRef(a, .value, prefixIdentity(20001)),
                .source = .{
                    .expected = .{
                        .work = try workspaceRef(a, .work, source_id),
                        .execution_revision = 1,
                        .control_revision = 1,
                    },
                    .realization_revision = 0,
                    .nodes = .{ .all = .{} },
                    .level = if (index % 3 == 2) .guest_cut else .outer_execution,
                },
                .policy = .{
                    .delivery = if (index % 3 == 1) .sampled else .lossless,
                    .granularity = if (index % 2 == 0) .one_guest_step else .publication,
                },
                .previous = if (index < 3) null else try workspaceRef(
                    a,
                    .work,
                    prefixIdentity(index - 3),
                ),
            },
            .source = empty,
            .source_work = source_id,
            .source_revision = index / 3,
            .accumulator = empty,
        },
    };
}

fn expectPublicationPrefix(
    a: std.mem.Allocator,
    prefix: *native.testing.workspace_observers.PublicationPrefix,
    publications: []const native.testing.state.WorkPublication,
    scanned: *usize,
    indexed: *usize,
) !void {
    var predecessors: std.StringHashMapUnmanaged(void) = .empty;
    defer predecessors.deinit(a);
    for (publications) |item| {
        scanned.* += 1;
        const observer = item.observer orelse continue;
        const previous = observer.selection.previous orelse continue;
        try predecessors.put(a, previous.id.bytes, {});
    }
    for (0..4) |source_index| {
        const source_id = prefixIdentity(10000 + source_index);
        var lossless: usize = 0;
        var outer = false;
        var quantum: u64 = 256;
        for (publications) |item| {
            scanned.* += 1;
            const observer = item.observer orelse continue;
            if (observer.stopped or !std.meta.eql(observer.source_work, source_id)) continue;
            const text = std.fmt.bytesToHex(item.work, .lower);
            if (predecessors.contains(&text)) continue;
            if (observer.selection.policy.granularity == .one_guest_step) quantum = 1;
            if (observer.selection.source.level == .outer_execution) outer = true;
            if (observer.selection.policy.delivery == .lossless) {
                lossless += 1;
                try std.testing.expect(prefix.lossless(source_id).?.contains(item.work));
                try std.testing.expectEqual(
                    observer.consumed_revision,
                    prefix.latest.get(item.work).?.publication.observer.?.consumed_revision,
                );
            }
        }
        try std.testing.expectEqual(outer, prefix.hasOuter(source_id));
        try std.testing.expectEqual(quantum, prefix.guestQuantum(source_id));
        const active = prefix.lossless(source_id);
        try std.testing.expectEqual(lossless, if (active) |set| set.count() else 0);
        if (active) |set| {
            for (set.keys()) |_| indexed.* += 1;
        }
    }
}

fn allocatePublicationPrefix(
    a: std.mem.Allocator,
    publications: []const native.testing.state.WorkPublication,
) !void {
    var prefix: native.testing.workspace_observers.PublicationPrefix = .init(a);
    defer prefix.deinit();
    for (publications, 0..) |item, i| try prefix.put(item, i);
}

fn temporalPublications(a: std.mem.Allocator) ![]native.testing.state.WorkPublication {
    const items = try a.alloc(native.testing.state.WorkPublication, 13);
    errdefer a.free(items);
    const source_id = prefixIdentity(10000);
    const first: native.testing.state.Reference = .{ .digest = prefixIdentity(30000), .bytes = 8 };
    items[0] = try prefixPublication(a, 0);
    items[0].work = source_id;
    items[0].observer = null;
    items[0].runtime_capsule = first;
    items[1] = try prefixPublication(a, 0);
    items[1].observer.?.consumed_revision = 0;
    items[2] = items[0];
    items[2].runtime_capsule.?.digest = prefixIdentity(30001);
    items[3] = items[1];
    items[3].work = prefixIdentity(1);
    items[4] = items[3];
    items[4].observer.?.consumed_revision = 1;
    items[5] = items[4];
    items[5].observer.?.consumed_revision = null;
    items[6] = items[5];
    items[6].observer.?.stopped = true;
    items[7] = items[1];
    items[7].work = prefixIdentity(2);
    items[7].observer.?.consumed_revision = 1;
    items[7].observer.?.selection.previous = try workspaceRef(a, .work, items[1].work);
    items[8] = items[1];
    items[8].work = prefixIdentity(3);
    items[8].observer.?.consumed_revision = null;
    items[8].observer.?.selection.policy.delivery = .sampled;
    items[9] = items[7];
    items[9].observer.?.stopped = true;
    items[10] = items[1];
    items[10].work = prefixIdentity(4);
    items[10].observer.?.selection.source.level = .guest_cut;
    items[10].observer.?.consumed_revision = 2;
    items[11] = items[10];
    items[11].observer.?.consumed_revision = 3;
    items[12] = items[0];
    return items;
}

fn allocatePublicationHistory(
    a: std.mem.Allocator,
    publications: []const native.testing.state.WorkPublication,
) !void {
    var history: native.testing.workspace_observers.PublicationHistory = .init(a);
    defer history.deinit();
    var builder = native.testing.workspace_observers.PublicationHistory.Builder.init(a, &history);
    defer builder.deinit();
    for (publications, 1..) |item, seq| try builder.put(item, seq);
}

fn expectTemporalHistory(
    a: std.mem.Allocator,
    history: *const native.testing.workspace_observers.PublicationHistory,
    items: []const native.testing.state.WorkPublication,
) !void {
    const source_id = items[0].work;
    var visits: usize = 0;
    for ([_]usize{ 12, 4, 8, 0, 6, 10, 2, 5, 9, 7, 11, 3, 1, 13 }) |cut| {
        var prefix: native.testing.workspace_observers.PublicationPrefix = .init(a);
        defer prefix.deinit();
        for (items[0..cut], 1..) |item, seq| try prefix.put(item, seq);
        for ([_]usize{ 0, @min(cut, 1), @min(cut, 3), cut }) |source_cut| {
            const capsule = if (source_cut == 0) null else if (source_cut < 3)
                items[0].runtime_capsule
            else if (source_cut < 13)
                items[2].runtime_capsule
            else
                items[12].runtime_capsule;
            try std.testing.expectEqual(
                try prefix.blocked(source_id, 3, source_cut, capsule),
                try history.blocked(source_id, 3, source_cut, cut, capsule),
            );
            try std.testing.expectEqualDeep(
                try scannedOuterCursor(items, source_id, source_cut, null, &visits),
                history.outerCursorAt(source_id, source_cut),
            );
        }
    }
    const Case = struct { source_cut: u64, read_cut: u64, blocked: bool };
    const cases = [_]Case{
        .{ .source_cut = 1, .read_cut = 4, .blocked = false },
        .{ .source_cut = 3, .read_cut = 4, .blocked = true },
        .{ .source_cut = 1, .read_cut = 5, .blocked = true },
        .{ .source_cut = 1, .read_cut = 6, .blocked = true },
        .{ .source_cut = 1, .read_cut = 7, .blocked = false },
        .{ .source_cut = 3, .read_cut = 8, .blocked = false },
        .{ .source_cut = 1, .read_cut = 8, .blocked = true },
        .{ .source_cut = 3, .read_cut = 9, .blocked = false },
        .{ .source_cut = 3, .read_cut = 10, .blocked = false },
        .{ .source_cut = 3, .read_cut = 11, .blocked = true },
        .{ .source_cut = 3, .read_cut = 12, .blocked = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.blocked, try history.blocked(
        source_id,
        3,
        case.source_cut,
        case.read_cut,
        if (case.source_cut == 1) items[0].runtime_capsule else items[2].runtime_capsule,
    ));
}

fn publicationHistoryWitness(a: std.mem.Allocator, scratch: std.mem.Allocator) !void {
    const items = try temporalPublications(scratch);
    var history: native.testing.workspace_observers.PublicationHistory = .init(a);
    defer history.deinit();
    {
        var builder = native.testing.workspace_observers.PublicationHistory.Builder.init(
            a,
            &history,
        );
        defer builder.deinit();
        for (items, 1..) |item, seq| try builder.put(item, seq);
    }
    try expectTemporalHistory(a, &history, items);
    try std.testing.checkAllAllocationFailures(a, allocatePublicationHistory, .{items});
}

fn expectParallelPublicationPrefix(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    publications: []const native.testing.state.WorkPublication,
    scanned: *usize,
    indexed: *usize,
) !void {
    const count = publications.len;
    var parallel: native.testing.workspace_observers.PublicationPrefix = .init(a);
    defer parallel.deinit();
    const independent = try scratch.dupe(native.testing.state.WorkPublication, publications);
    const source_id = publications[0].observer.?.source_work;
    for (independent, 0..) |*item, i| {
        item.observer.?.stopped = false;
        item.observer.?.source_work = source_id;
        item.observer.?.selection.source = publications[0].observer.?.selection.source;
        item.observer.?.selection.previous = null;
        item.observer.?.selection.policy.delivery = .lossless;
        try parallel.put(item.*, i);
    }
    try expectPublicationPrefix(a, &parallel, independent, scanned, indexed);
    for (independent[0 .. count - 1], 0..) |*item, i| {
        item.observer.?.stopped = true;
        try parallel.put(item.*, count + i);
    }
    indexed.* = 0;
    for (0..count) |_| {
        for (parallel.lossless(source_id).?.keys()) |id| {
            try std.testing.expectEqualDeep(independent[count - 1].work, id);
            indexed.* += 1;
        }
    }
    try std.testing.expectEqual(count, indexed.*);
    try expectPublicationPrefix(a, &parallel, independent, scanned, indexed);
    std.debug.print(
        "publication prefixes: parallel_peak={d} remaining=1 queried_visits={d}\n",
        .{ count, indexed.* - 1 },
    );
}

test "runtime selection publication prefixes preserve active observers without historical rescans" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try publicationHistoryWitness(a, scratch);
    for ([_]usize{ 10, 100, 1000 }) |count| {
        var prefix: native.testing.workspace_observers.PublicationPrefix = .init(a);
        defer prefix.deinit();
        const publications = try scratch.alloc(native.testing.state.WorkPublication, count);
        var scanned: usize = 0;
        var indexed: usize = 0;
        for (publications, 0..) |*item, i| {
            item.* = try prefixPublication(scratch, i);
            try prefix.put(item.*, i * 2);
            try expectPublicationPrefix(a, &prefix, publications[0 .. i + 1], &scanned, &indexed);
            item.observer.?.consumed_revision = item.observer.?.source_revision;
            try prefix.put(item.*, i * 2 + 1);
            try expectPublicationPrefix(a, &prefix, publications[0 .. i + 1], &scanned, &indexed);
        }
        for (publications[count - 3 ..], 0..) |*item, i| {
            item.observer.?.stopped = true;
            try prefix.put(item.*, count * 2 + i);
        }
        for (0..count) |i| {
            try prefix.put(publications[0], count * 3 + i);
            for (0..3) |source_index| {
                const id = prefixIdentity(10000 + source_index);
                try std.testing.expect(!prefix.hasOuter(id));
                try std.testing.expectEqual(@as(u32, 0), prefix.lossless(id).?.count());
            }
        }
        try expectPublicationPrefix(a, &prefix, publications, &scanned, &indexed);
        try std.testing.expect(indexed <= count * 4);
        try std.testing.expect(scanned > count * count);
        std.debug.print(
            "publication prefixes: folds={d} reference_visits={d} active_visits={d}\n",
            .{ count, scanned, indexed },
        );
        if (count == 10)
            try std.testing.checkAllAllocationFailures(a, allocatePublicationPrefix, .{
                publications,
            });
        try expectParallelPublicationPrefix(a, scratch, publications, &scanned, &indexed);
    }
}
test "runtime selection preserves guest cuts and retained artifacts across archive import" {
    var phase: []const u8 = "runtime selection and import";
    errdefer std.debug.print("runtime selection: {s}\n", .{phase});
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    const root_definition = try gcd(&root_builder);
    const root_entry = &root_builder.functions.items[@intCast(root_definition.entry)];
    for (0..32) |_| root_entry.body = try root_builder.term(.{
        .yield_then = root_entry.body.?,
    });
    const root_module = root_builder.module(root_definition.entry, root_definition.failure);
    const root_document = try native.source_records.encode(a, root_module);
    defer a.free(root_document);
    var root = try compile(a, &root_builder, root_module);
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "workspace-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "workspace-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = "workspace-unit",
        .manifest = manifest,
    };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    var semantic_roots: [2]native.testing.state.Digest = .{ @splat(0), @splat(0) };
    try runtimeSelectionOpenOwner(.{
        .phase = &phase,
        .a = &a,
        .io = &io,
        .root_document = &root_document,
        .application = &application,
        .assets = &assets,
        .handlers = &handlers,
        .semantic_roots = &semantic_roots,
    });
}

fn runtimeSelectionOpenOwner(capture: anytype) !void {
    const a = capture.a.*;
    const io = capture.io.*;
    const application = capture.application;
    const assets = capture.assets.*;
    const handlers = capture.handlers;
    const semantic_roots = capture.semantic_roots;
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(42),
        .bytes = "workspace-test",
        .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" },
        .semantic_construction = .{
            .roots = &semantic_roots.*,
            .checkers = &.{kosmos.RuntimeCompiler.checker_identity},
            .guard = true,
        },
    };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_open = true;
    defer if (namespace_open) support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &namespace,
        assets,
        &application.*,
        handlers.*,
        profile,
    );
    var service_open = true;
    defer if (service_open) support.expectCleanup(service.close(a));
    var arena = std.heap.ArenaAllocator.init(a);
    try runtimeSelectionWithOwner(.{
        .phase = capture.phase,
        .a = capture.a,
        .io = capture.io,
        .root_document = capture.root_document,
        .application = capture.application,
        .assets = capture.assets,
        .handlers = capture.handlers,
        .semantic_roots = capture.semantic_roots,
        .profile = &profile,
        .path_buffer = &path_buffer,
        .length = &length,
        .path = &path,
        .namespace = &namespace,
        .namespace_open = &namespace_open,
        .service = &service,
        .service_open = &service_open,
        .arena = &arena,
    });
}

fn runtimeSelectionWithOwner(capture: anytype) !void {
    const phase = capture.phase;
    const a = capture.a.*;
    const io = capture.io.*;
    const root_document = capture.root_document.*;
    const application = capture.application;
    const assets = capture.assets.*;
    const handlers = capture.handlers;
    const semantic_roots = capture.semantic_roots;
    const profile = capture.profile.*;
    const path_buffer = capture.path_buffer;
    const length = capture.length.*;
    const path = capture.path.*;
    const namespace = capture.namespace;
    const namespace_open = capture.namespace_open;
    const service = capture.service;
    const service_open = capture.service_open;
    const arena = capture.arena;
    defer arena.*.deinit();
    const scratch = arena.*.allocator();
    const parent = try service.*.submit(scratch, "parent", .{ 25, 5 });
    var initial = try service.*.task(a, parent.receipt.task);
    defer initial.deinit();
    const fixture = .{
        .phase = &phase.*,
        .a = &a,
        .io = &io,
        .application = &application.*,
        .assets = &assets,
        .handlers = &handlers.*,
        .semantic_roots = &semantic_roots.*,
        .profile = &profile,
        .path_buffer = &path_buffer.*,
        .length = &length,
        .path = &path,
        .namespace = &namespace.*,
        .namespace_open = &namespace_open.*,
        .service = &service.*,
        .service_open = &service_open.*,
        .scratch = &scratch,
        .parent = &parent,
    };

    fixture.phase.* = "controller runtime selection";
    try exerciseControllerRealization(
        fixture.scratch.*,
        &fixture.service.*,
        fixture.parent.*.receipt.task,
        root_document,
    );
    fixture.phase.* = "runtime source build";
    var builder = source.Builder.init(fixture.a.*);
    defer builder.deinit();
    const document = try native.source_records.encode(fixture.a.*, try listLength(&builder));
    defer fixture.a.*.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try runtimeSelectionSpecializeProgram(.{
        .fixture = &fixture,
        .document = &document,
        .diagnostic = &diagnostic,
    });
}

fn runtimeSelectionSpecializeProgram(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const a = fixture.a.*;
    const namespace = fixture.namespace;
    const document = capture.document.*;
    const diagnostic = capture.diagnostic;
    const program = try service.workspaceBuild(
        scratch,
        "build",
        parent.receipt.task,
        document,
        &diagnostic.*,
    );
    // The request retains its receipt, not the compiler's completed proof
    // arenas. The service allocator still checks every temporary allocation.
    const specialization_request_memory = try a.alloc(u8, 1024 * 1024);
    defer a.free(specialization_request_memory);
    var specialization_request = std.heap.FixedBufferAllocator.init(specialization_request_memory);
    fixture.phase.* = "runtime specialization";
    const specialized = try service.workspaceSpecializeWithHooks(
        specialization_request.allocator(),
        "specialize",
        parent.receipt.task,
        program.receipt.workspace.?,
        .{ .control = true, .storage = true },
    );
    var specialized_observation = try contracts.decodeOwned(
        native.workspace.Runtime,
        scratch,
        try namespace.store.object(scratch, specialized.receipt.workspace_observation.?, null),
    );
    defer specialized_observation.deinit();
    try std.testing.expect(specialized_observation.value.validation == null);
    const validation_bytes = try contracts.encodeOwned(
        ?native.workspace.ValidationFact,
        scratch,
        null,
    );
    var validation_context: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(validation_bytes, &validation_context, .{});
    const RuntimeFact = @FieldType(@TypeOf(service.checked_workspace_runtimes).KV, "key");
    const runtime_fact: RuntimeFact = .{
        .kind = .runtime,
        .input = specialized_observation.value.artifact,
        .output = @as(native.testing.state.Reference, .{ .digest = @splat(0), .bytes = 0 }),
        .context = validation_context,
    };
    try std.testing.expectEqual(
        namespace.store.integrity_epoch,
        service.checked_workspace_runtimes.get(runtime_fact).?,
    );
    try runtimeSelectionSpecializeAlias(.{
        .fixture = capture.fixture,
        .document = capture.document,
        .diagnostic = capture.diagnostic,
        .program = &program,
        .specialized = &specialized,
        .runtime_fact = &runtime_fact,
    });
}

fn runtimeSelectionSpecializeAlias(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const document = capture.document.*;
    const diagnostic = capture.diagnostic;
    const program = capture.program.*;
    const specialized = capture.specialized.*;
    try std.testing.expectEqualDeep(
        specialized.receipt.workspace.?,
        service.runtime_cache.?.artifact.identity,
    );
    try std.testing.expectEqual(
        fixture.namespace.*.store.integrity_epoch,
        service.runtime_cache.?.epoch,
    );
    const duplicate = try service.workspaceSpecializeWithHooks(
        scratch,
        "specialize",
        parent.receipt.task,
        program.receipt.workspace.?,
        .{ .control = true, .storage = true },
    );
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualDeep(specialized.receipt.workspace, duplicate.receipt.workspace);
    fixture.phase.* = "runtime alias specialization";
    const alias_document = try std.fmt.allocPrint(scratch, "\n{s}\n", .{document});
    const alias_program = try service.workspaceBuild(
        scratch,
        "build-alias",
        parent.receipt.task,
        alias_document,
        &diagnostic.*,
    );
    try std.testing.expect(
        !std.meta.eql(program.receipt.workspace.?, alias_program.receipt.workspace.?),
    );
    const alias_specialized = try service.workspaceSpecializeWithHooks(
        scratch,
        "specialize-alias",
        parent.receipt.task,
        alias_program.receipt.workspace.?,
        .{ .control = true, .storage = true },
    );
    try std.testing.expect(!alias_specialized.replayed);
    try std.testing.expectEqualDeep(
        specialized.receipt.workspace,
        alias_specialized.receipt.workspace,
    );
    try runtimeSelectionAliasObservation(.{
        .fixture = capture.fixture,
        .document = capture.document,
        .diagnostic = capture.diagnostic,
        .program = capture.program,
        .specialized = capture.specialized,
        .runtime_fact = capture.runtime_fact,
        .alias_program = &alias_program,
        .alias_specialized = &alias_specialized,
    });
}

fn runtimeSelectionAliasObservation(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const scratch = fixture.scratch.*;
    const program = capture.program.*;
    const alias_program = capture.alias_program.*;
    const alias_specialized = capture.alias_specialized.*;
    var alias_observation = try contracts.decodeOwned(
        native.workspace.Runtime,
        scratch,
        try fixture.namespace.*.store.object(
            scratch,
            alias_specialized.receipt.workspace_observation.?,
            null,
        ),
    );
    defer alias_observation.deinit();
    try std.testing.expectEqualDeep(program.receipt.workspace.?, alias_observation.value.program);
    const alias_command: contracts.workspace.Command = .{
        .program = .{ .specialize = .{ .program = try workspaceRef(
            scratch,
            .program,
            alias_program.receipt.workspace.?,
        ), .hooks = .{ .control = true, .storage = true } } },
    };
    const alias_reply = try fixture.service.*.workspaceCommand(
        scratch,
        "specialize-alias",
        fixture.parent.*.receipt.task,
        alias_command,
    );
    const alias_json = (try native.json.parseAsset(
        scratch,
        alias_reply.observation_json.bytes,
        alias_reply.observation_json.bytes.len,
    )).value;
    try std.testing.expectEqualDeep(
        program.receipt.workspace.?,
        try nativeIdentity(
            try native.values.fromJson(
                contracts.workspace.Ref,
                scratch,
                alias_json.object.get("origin_program").?,
            ),
        ),
    );
    fixture.phase.* = "runtime alias origin rejection";
    try runtimeSelectionRejectAliasOrigin(.{
        .fixture = capture.fixture,
        .document = capture.document,
        .diagnostic = capture.diagnostic,
        .specialized = capture.specialized,
        .runtime_fact = capture.runtime_fact,
        .alias_program = capture.alias_program,
        .alias_specialized = capture.alias_specialized,
        .alias_observation = &alias_observation,
        .alias_command = &alias_command,
    });
}

fn runtimeSelectionRejectAliasOrigin(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const namespace = fixture.namespace;
    const scratch = fixture.scratch.*;
    const service = fixture.service;
    const semantic_roots = fixture.semantic_roots;
    const specialized = capture.specialized.*;
    const alias_program = capture.alias_program.*;
    const alias_specialized = capture.alias_specialized.*;
    const alias_observation = capture.alias_observation;
    const alias_command = capture.alias_command.*;
    {
        try namespace.store.begin();
        defer namespace.store.rollback();
        var false_origin = alias_observation.*.value;
        false_origin.program = alias_program.receipt.workspace.?;
        var false_receipt = alias_specialized.receipt;
        false_receipt.workspace_observation = try namespace.store.putObject(
            try contracts.encodeOwned(native.workspace.Runtime, scratch, false_origin),
        );
        const false_body = try namespace.store.putObject(
            try contracts.encodeOwned(native.testing.state.Receipt, scratch, false_receipt),
        );
        try namespace.store.database.run(
            "UPDATE operations SET receipt=? WHERE request=? AND task=?",
            &.{
                .{ .blob = &false_body.digest },
                .{ .blob = &false_receipt.request_digest },
                .{ .blob = &false_receipt.task },
            },
        );
        try std.testing.expectError(
            error.InvalidRuntime,
            service.workspaceCommand(
                scratch,
                "specialize-alias",
                fixture.parent.*.receipt.task,
                alias_command,
            ),
        );
    }
    fixture.phase.* = "runtime cache invalidation";
    var previous_runtime = try service.runtime_cache.?.artifact.clone();
    defer previous_runtime.deinit();
    const previous_epoch = namespace.store.integrity_epoch;
    namespace.store.invalidateIntegrity();
    try std.testing.expectEqual(previous_epoch, service.runtime_cache.?.epoch);
    try std.testing.expectEqual(previous_epoch + 1, namespace.store.integrity_epoch);
    const runtime = try workspaceRef(scratch, .runtime, specialized.receipt.workspace.?);
    semantic_roots.*[0] = kosmos.RuntimeCompiler.approvedRootIdentity(&previous_runtime);
    var generic_runtime = try service.program.retainRuntime();
    defer generic_runtime.deinit();
    semantic_roots.*[1] = kosmos.RuntimeCompiler.approvedRootIdentity(&generic_runtime);
    const input = try scratch.alloc(u8, 3 * 9 + 1);
    var writer: data.wire.Writer = .{ .output = input };
    try runtimeSelectionPrepareExecution(.{
        .fixture = capture.fixture,
        .document = capture.document,
        .diagnostic = capture.diagnostic,
        .runtime_fact = capture.runtime_fact,
        .alias_program = capture.alias_program,
        .previous_runtime = &previous_runtime,
        .runtime = &runtime,
        .input = &input,
        .writer = &writer,
    });
}

fn runtimeSelectionPrepareExecution(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const scratch = fixture.scratch.*;
    const service = fixture.service;
    const parent = fixture.parent.*;
    const phase = fixture.phase;
    const document = capture.document.*;
    const diagnostic = capture.diagnostic;
    const runtime_fact = capture.runtime_fact.*;
    const alias_program = capture.alias_program.*;
    const previous_runtime = capture.previous_runtime;
    const runtime = capture.runtime.*;
    const input = capture.input.*;
    const writer = capture.writer;
    for (0..3) |i| {
        try writer.*.natural(1);
        try writer.*.fixed(u64, @intCast(i));
    }
    try writer.*.natural(0);
    const shared_program = try semanticGuestProgram(
        scratch,
        service,
        parent.receipt.task,
        "semantic-guest-build",
    );
    const shared_input = try contracts.encodeOwned(@import(
        "workspace_sources.zig",
    ).SemanticGuestInput, scratch, .{ .yields = 300, .seed = 100 });
    try semanticGuestExecution(scratch, service, parent.receipt.task, shared_program);
    const programs = .{
        .document = &document,
        .diagnostic = &diagnostic.*,
        .runtime_fact = &runtime_fact,
        .alias_program = &alias_program,
        .runtime = &runtime,
        .input = &input,
        .shared_program = &shared_program,
        .shared_input = &shared_input,
        .previous_runtime = &previous_runtime.*,
    };

    phase.* = "guarded reply divergence and cleanup";
    try exerciseGuardReply(scratch, service, parent.receipt.task);
    phase.* = "selected runtime realization";
    const started = try service.workspaceStart(
        scratch,
        "start",
        parent.receipt.task,
        programs.alias_program.*.receipt.workspace.?,
        programs.input.*,
        .{},
    );
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(fixture.a.*, parent.receipt.task, id);
    defer before.deinit();
    try std.testing.expectEqualDeep(
        programs.alias_program.*.receipt.workspace.?,
        before.value.program,
    );
    try runtimeSelectionCheckSelectionPolicy(.{
        .fixture = capture.fixture,
        .programs = &programs,
        .id = &id,
        .before = &before,
    });
}

fn runtimeSelectionCheckSelectionPolicy(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const scratch = fixture.scratch.*;
    const service = fixture.service;
    const parent = fixture.parent.*;
    const programs = capture.programs.*;
    const runtime = programs.runtime.*;
    const id = capture.id.*;
    const before = capture.before;
    try std.testing.expect(!before.*.value.terminal());
    const expected: contracts.workspace.Expected = .{
        .work = try workspaceRef(scratch, .work, id),
        .execution_revision = before.*.value.execution_revision,
        .control_revision = before.*.value.control_revision,
    };
    const selection: @FieldType(
        contracts.workspace.Work,
        "realize",
    ) = .{ .expected = expected, .realization_revision = 0, .runtime = .{
        .selected = runtime,
    } };
    const allowed_policy = service.profile.semantic_construction;
    service.profile.semantic_construction = null;
    try std.testing.expectError(
        error.SemanticPolicyDenied,
        service.workspaceRealize(scratch, "denied-select", parent.receipt.task, selection),
    );
    const denied_start = try service.workspaceCommand(
        scratch,
        "denied-runtime-start",
        parent.receipt.task,
        .{ .work = .{ .start = .{
            .program = try workspaceRef(
                scratch,
                .program,
                programs.alias_program.*.receipt.workspace.?,
            ),
            .input = .{
                .reference = try workspaceRef(scratch, .value, before.*.value.input_value.?.digest),
            },
            .policy = .{},
            .runtime = .{ .selected = runtime },
        } } },
    );
    try std.testing.expectEqual(.rejected, denied_start.disposition);
    try std.testing.expect(
        std.mem.indexOf(u8, denied_start.observation_json.bytes, "SemanticPolicyDenied") != null,
    );
    service.profile.semantic_construction = allowed_policy;
    try runtimeSelectionPublishSelection(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .id = capture.id,
        .before = capture.before,
        .expected = &expected,
        .selection = &selection,
        .allowed_policy = &allowed_policy,
    });
}

fn runtimeSelectionPublishSelection(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const a = fixture.a.*;
    const namespace = fixture.namespace;
    const service = fixture.service;
    const parent = fixture.parent.*;
    const scratch = fixture.scratch.*;
    const programs = capture.programs.*;
    const id = capture.id.*;
    const before = capture.before;
    const selection = capture.selection.*;
    {
        var request_arena = std.heap.ArenaAllocator.init(a);
        defer request_arena.deinit();
        var commit_guard: AfterCommitAllocator = .{
            .backing = request_arena.allocator(),
            .namespace = namespace,
            .generation = namespace.store.head.generation,
        };
        _ = try service.workspaceRealize(
            commit_guard.allocator(),
            "select",
            parent.receipt.task,
            selection,
        );
        try std.testing.expectEqual(@as(usize, 0), commit_guard.rejected);
    }
    try std.testing.expectEqual(
        namespace.store.integrity_epoch,
        service.checked_workspace_runtimes.get(programs.runtime_fact.*).?,
    );
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.runtime_cache.?.epoch);
    try std.testing.expect(
        programs.previous_runtime.*.core != service.runtime_cache.?.artifact.core,
    );
    const replay = try service.workspaceRealize(scratch, "select", parent.receipt.task, selection);
    try std.testing.expect(replay.replayed);
    try std.testing.expectError(
        error.StaleRevision,
        service.workspaceRealize(scratch, "stale-select", parent.receipt.task, selection),
    );
    var selected = try service.workspaceWork(a, parent.receipt.task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(before.*.value.checkpoint, selected.value.checkpoint);
    try std.testing.expectEqual(
        before.*.value.execution_revision,
        selected.value.execution_revision,
    );
    try std.testing.expectEqual(@as(u64, 1), selected.value.realization_revision);
    try std.testing.expect(
        selected.value.runtime != null and selected.value.runtime_capsule != null,
    );
    try runtimeSelectionPrepareSelectedPump(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .id = capture.id,
        .before = capture.before,
        .expected = capture.expected,
        .selection = capture.selection,
        .allowed_policy = capture.allowed_policy,
        .selected = &selected,
    });
}

fn runtimeSelectionPrepareSelectedPump(capture: anytype) !void {
    const id = capture.id.*;
    const before = capture.before;
    const expected = capture.expected.*;
    const selection = capture.selection.*;
    const allowed_policy = capture.allowed_policy.*;
    const selected = capture.selected;
    const selected_pump: @FieldType(contracts.workspace.Work, "pump") = .{
        .expected = .{
            .work = expected.work,
            .execution_revision = selected.*.value.execution_revision,
            .control_revision = selected.*.value.control_revision,
        },
        .base_quantum = 1,
    };
    const selection_state = .{
        .id = &id,
        .before = &before.*,
        .expected = &expected,
        .selection = &selection,
        .allowed_policy = &allowed_policy,
        .selected = &selected.*,
        .selected_pump = &selected_pump,
    };

    try runtimeSelectionDeniedActivePolicy(capture, selection_state);
}

fn runtimeSelectionDeniedActivePolicy(capture: anytype, selection_state: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    service.profile.semantic_construction = null;
    try std.testing.expectError(
        error.SemanticPolicyDenied,
        service.workspacePump(
            scratch,
            "denied-active-pump",
            parent.receipt.task,
            selection_state.selected_pump.*,
        ),
    );
    try std.testing.expect(
        (try service.workspaceRealize(
            scratch,
            "select",
            parent.receipt.task,
            selection_state.selection.*,
        )).replayed,
    );
    try service.park(scratch);
    var policy_parked_parent = try service.task(scratch, parent.receipt.task);
    defer policy_parked_parent.deinit();
    _ = try service.resumeTask(
        scratch,
        "selected-policy-resume",
        parent.receipt.task,
        policy_parked_parent.value.revision,
    );
    try std.testing.expectError(
        error.SemanticPolicyDenied,
        service.workspacePump(
            scratch,
            "denied-restored-pump",
            parent.receipt.task,
            selection_state.selected_pump.*,
        ),
    );
    var denied_work = try service.workspaceWork(scratch, parent.receipt.task, selection_state.id.*);
    defer denied_work.deinit();
    try std.testing.expectEqualDeep(
        selection_state.selected.*.value.checkpoint,
        denied_work.value.checkpoint,
    );
    try runtimeSelectionCheckRestoredPolicy(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = &selection_state,
        .denied_work = &denied_work,
    });
}

fn runtimeSelectionCheckRestoredPolicy(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const programs = capture.programs.*;
    const selection_state = capture.selection_state.*;
    const denied_work = capture.denied_work;
    try std.testing.expectEqual(
        selection_state.selected.*.value.execution_revision,
        denied_work.*.value.execution_revision,
    );
    service.profile.semantic_construction = selection_state.allowed_policy.*;
    {
        var different_builder = source.Builder.init(fixture.a.*);
        defer different_builder.deinit();
        const different_document = try native.source_records.encode(
            scratch,
            try @import("workspace_sources.zig").listLengthWithYields(&different_builder, false),
        );
        const different = try service.workspaceBuild(
            scratch,
            "build-different-image",
            parent.receipt.task,
            different_document,
            &programs.diagnostic.*,
        );
        const denied = try service.workspaceCommand(
            scratch,
            "mismatched-runtime",
            parent.receipt.task,
            .{ .work = .{ .start = .{
                .program = try workspaceRef(scratch, .program, different.receipt.workspace.?),
                .input = .{
                    .reference = try workspaceRef(
                        scratch,
                        .value,
                        selection_state.before.*.value.input_value.?.digest,
                    ),
                },
                .policy = .{},
                .runtime = .{ .selected = programs.runtime.* },
            } } },
        );
        try std.testing.expectEqual(.rejected, denied.disposition);
    }
    fixture.phase.* = "guest view materialization";
    try runtimeSelectionMaterializeView(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
    });
}

fn runtimeSelectionMaterializeView(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const selection_state = capture.selection_state.*;
    const selected = selection_state.selected;
    const view_command: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .guest_view = .{ .expected = .{
            .work = selection_state.expected.*.work,
            .execution_revision = selected.value.execution_revision,
            .control_revision = selected.value.control_revision,
        }, .realization_revision = selected.value.realization_revision, .nodes = .{
            .all = .{},
        } } },
        .sources = .{ .items = &.{} },
    } } };
    const viewed = try service.workspaceCommand(
        scratch,
        "guest-view",
        parent.receipt.task,
        view_command,
    );
    if (viewed.disposition != .observed) std.debug.print("guest view: {s}\n", .{
        viewed.observation_json.bytes,
    });
    try std.testing.expectEqual(.observed, viewed.disposition);
    const view_ref = viewed.evidence.?;
    const viewed_json = (try native.json.parseAsset(
        scratch,
        viewed.observation_json.bytes,
        viewed.observation_json.bytes.len,
    )).value;
    try std.testing.expectEqualStrings(
        "inspection",
        viewed_json.object.get("derivation").?.object.get("kind").?.string,
    );
    const again = try service.workspaceCommand(
        scratch,
        "guest-view",
        parent.receipt.task,
        view_command,
    );
    try std.testing.expectEqualDeep(view_ref, again.evidence.?);
    const view_id = try nativeIdentity(view_ref);
    try runtimeSelectionRetainView(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view_command = &view_command,
        .view_ref = &view_ref,
        .view_id = &view_id,
    });
}

fn runtimeSelectionRetainView(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const a = fixture.a.*;
    const namespace = fixture.namespace;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const view_command = capture.view_command.*;
    const view_ref = capture.view_ref.*;
    const view_id = capture.view_id.*;
    var view_record = try contracts.decodeOwned(
        native.workspace.Value,
        a,
        (try namespace.store.recordBytes(
            scratch,
            "workspace_value",
            try native.workspace.custodyId(scratch, parent.receipt.task, view_id),
            parent.receipt.task,
        )).?,
    );
    defer view_record.deinit();
    const view_bytes = try namespace.store.object(
        scratch,
        view_record.value.description.value,
        null,
    );
    const view_schema = try namespace.store.object(
        scratch,
        view_record.value.description.schema,
        null,
    );
    var view_data = try native.dynamic_values.decode(a, view_schema, view_bytes);
    defer view_data.deinit();
    try std.testing.expect(view_data.value.array.items[1].bool);
    try std.testing.expect(view_data.value.array.items[2].array.items.len != 0);
    try disclosedViewWitness(&fixture.service.*, scratch, parent.receipt.task, view_command);
    const view = .{
        .view_command = &view_command,
        .view_ref = &view_ref,
        .view_record = &view_record,
        .view_schema = &view_schema,
        .view_data = &view_data,
    };
    try runtimeSelectionRejectForgedViews(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = &view,
    });
}

fn runtimeSelectionRejectForgedViews(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const namespace = fixture.namespace;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const programs = capture.programs.*;
    const view = capture.view.*;

    for (0..3) |attack| {
        // Rehashing a plausible snapshot does not create a journal publication.
        // Keep all ordinary content references valid while changing its revision.
        try namespace.store.begin();
        defer namespace.store.rollback();
        var forged = view.view_record.*.value;
        const frozen = &forged.derivation.inspection.?.observation.work;
        switch (attack) {
            0 => frozen.execution_revision += 1,
            1 => frozen.outer_cursor.revision += 1,
            2 => frozen.outer_cursor.last = frozen.input.digest,
            else => unreachable,
        }
        forged.description.provenance = try namespace.store.putObject(
            try contracts.encodeOwned(native.workspace.Derivation, scratch, forged.derivation),
        );
        forged.artifact = try namespace.store.putObject(
            try contracts.encodeOwned(native.workspace.ValueArtifact, scratch, forged.description),
        );
        forged.id = try native.workspace.custodyId(
            scratch,
            parent.receipt.task,
            forged.artifact.digest,
        );
        try namespace.store.createRecord(
            native.workspace.Value,
            "workspace_value",
            forged.id,
            parent.receipt.task,
            forged,
        );
        const rejected = try fixture.service.*.workspaceCommand(
            scratch,
            "forged-view",
            parent.receipt.task,
            .{ .context = .{ .expand = .{ .reference = try workspaceRef(
                scratch,
                .value,
                forged.artifact.digest,
            ), .page = .{} } } },
        );
        try std.testing.expectEqual(.rejected, rejected.disposition);
    }
    try runtimeSelectionPartialViews(.{
        .fixture = &fixture,
        .programs = &programs,
        .view = &view,
    });
    try runtimeSelectionInspectAfterQuery(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
    });
}

fn runtimeSelectionInspectAfterQuery(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const programs = capture.programs.*;
    const selection_state = capture.selection_state.*;
    const selected = selection_state.selected;
    const view = capture.view.*;

    try runtimeSelectionRetentionQuery(.{
        .fixture = &fixture,
        .programs = &programs,
        .view = &view,
    });

    fixture.phase.* = "traced runtime selection";
    var after_view = try fixture.service.*.workspaceWork(
        fixture.a.*,
        fixture.parent.*.receipt.task,
        selection_state.id.*,
    );
    defer after_view.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, after_view.value.checkpoint);
    try std.testing.expectEqual(
        selected.value.execution_revision,
        after_view.value.execution_revision,
    );
    try std.testing.expectEqual(selected.value.control_revision, after_view.value.control_revision);
    var traced_id: [32]u8 = undefined;
    try runtimeSelectionStartTrace(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .traced_id = &traced_id,
    });
}

fn runtimeSelectionStartTrace(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const a = fixture.a.*;
    const service = fixture.service;
    const parent = fixture.parent.*;
    const scratch = fixture.scratch.*;
    const programs = capture.programs.*;
    const selection_state = capture.selection_state.*;
    const before = selection_state.before;
    const traced_id = capture.traced_id;
    {
        var request_arena = std.heap.ArenaAllocator.init(a);
        defer request_arena.deinit();
        const selected_start = try service.workspaceCommand(
            request_arena.allocator(),
            "selected-start",
            parent.receipt.task,
            .{ .work = .{ .start = .{
                .program = try workspaceRef(
                    scratch,
                    .program,
                    programs.alias_program.*.receipt.workspace.?,
                ),
                .input = .{
                    .reference = try workspaceRef(
                        scratch,
                        .value,
                        before.value.input_value.?.digest,
                    ),
                },
                .policy = .{},
                .runtime = .{ .selected = programs.runtime.* },
            } } },
        );
        try std.testing.expectEqual(.observed, selected_start.disposition);
        const traced_json = (try native.json.parseAsset(
            scratch,
            selected_start.observation_json.bytes,
            selected_start.observation_json.bytes.len,
        )).value;
        traced_id.* = try nativeIdentity(
            try native.values.fromJson(
                contracts.workspace.Ref,
                scratch,
                traced_json.object.get("work").?,
            ),
        );
        var traced = try service.workspaceWork(a, parent.receipt.task, traced_id.*);
        defer traced.deinit();
        try std.testing.expect(traced.value.runtime_trace != null);
        try std.testing.expect(traced.value.runtime_trace.?.output.trace.control != null);
        try std.testing.expect(traced.value.runtime_trace.?.output.trace.storage.?.node_slots > 0);
        try std.testing.expectEqualDeep(before.value.checkpoint, traced.value.checkpoint);
    }
    try runtimeSelectionFalseTrace(.{ .fixture = &fixture, .traced_id = &traced_id.* });

    fixture.phase.* = "outer cut suspension";
    try runtimeSelectionSuspendTrace(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .traced_id = capture.traced_id,
    });
}

fn runtimeSelectionSuspendTrace(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const a = fixture.a.*;
    const parent = fixture.parent.*;
    const scratch = fixture.scratch.*;
    const traced_id = capture.traced_id;
    var trace_before_pump = try service.workspaceWork(a, parent.receipt.task, traced_id.*);
    defer trace_before_pump.deinit();
    const pump_command: @FieldType(contracts.workspace.Work, "pump") = .{
        .expected = .{
            .work = try workspaceRef(scratch, .work, traced_id.*),
            .execution_revision = trace_before_pump.value.execution_revision,
            .control_revision = trace_before_pump.value.control_revision,
        },
        .base_quantum = 1,
    };
    _ = try service.workspacePump(scratch, "begin-bounded", parent.receipt.task, pump_command);
    try std.testing.expect(
        (try service.workspacePump(
            scratch,
            "begin-bounded",
            parent.receipt.task,
            pump_command,
        )).replayed,
    );
    var suspended = try service.workspaceWork(a, parent.receipt.task, traced_id.*);
    defer suspended.deinit();
    try std.testing.expect(suspended.value.outer_operation != null);
    const suspended_observation = try service.workspaceCommand(
        scratch,
        "inspect-bounded",
        parent.receipt.task,
        .{ .work = .{ .inspect = .{ .work = pump_command.expected.work } } },
    );
    const suspended_json = try native.json.parseAsset(
        scratch,
        suspended_observation.observation_json.bytes,
        suspended_observation.observation_json.bytes.len,
    );
    try std.testing.expectEqualStrings(
        "outer_execution",
        suspended_json.value.object.get("available_cut").?.string,
    );
    try std.testing.expectEqual(
        trace_before_pump.value.execution_revision,
        suspended.value.execution_revision,
    );
    try std.testing.expectEqualDeep(trace_before_pump.value.checkpoint, suspended.value.checkpoint);
    try runtimeSelectionCheckSuspendedCut(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .traced_id = capture.traced_id,
        .pump_command = &pump_command,
        .suspended = &suspended,
    });
}

fn runtimeSelectionCheckSuspendedCut(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const pump_command = capture.pump_command.*;
    const suspended = capture.suspended;
    const suspended_expected: contracts.workspace.Expected = .{
        .work = pump_command.expected.work,
        .execution_revision = suspended.*.value.execution_revision,
        .control_revision = suspended.*.value.control_revision,
    };
    try std.testing.expectError(
        error.GuestCutUnavailable,
        service.workspaceRequestCut(scratch, "premature-guest-cut", parent.receipt.task, .{
            .expected = suspended_expected,
            .level = .guest_cut,
        }),
    );
    try std.testing.expectError(
        error.GuestCutUnavailable,
        service.workspaceRealize(
            scratch,
            "premature-switch",
            parent.receipt.task,
            .{
                .expected = suspended_expected,
                .realization_revision = suspended.*.value.realization_revision,
                .runtime = .{ .packaged = .{} },
            },
        ),
    );
    try outerViewWitness(service, scratch, parent.receipt.task, suspended.*.value);
    _ = try service.workspaceRequestCut(scratch, "pending-outer-cut", parent.receipt.task, .{
        .expected = suspended_expected,
        .level = .outer_execution,
    });
    const original_outer_bytes = try fixture.namespace.*.store.object(
        scratch,
        suspended.*.value.outer_operation.?.capsule,
        null,
    );
    var original_outer = try kosmos.RuntimeCapsule.read(fixture.a.*, original_outer_bytes);
    defer original_outer.deinit();
    try std.testing.expectEqual(.advance, original_outer.value.record.operation.?);
    try runtimeSelectionObserveCutsBeforeReopen(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .traced_id = capture.traced_id,
        .pump_command = capture.pump_command,
        .suspended = capture.suspended,
        .original_outer = &original_outer,
    });
}

fn runtimeSelectionObserveCutsBeforeReopen(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const service = fixture.service;
    const a = fixture.a.*;
    const parent = fixture.parent.*;
    const scratch = fixture.scratch.*;
    const phase = fixture.phase;
    const programs = capture.programs.*;
    const selection_state = capture.selection_state.*;
    const traced_id = capture.traced_id;
    const pump_command = capture.pump_command.*;
    const suspended = capture.suspended;
    const original_outer = capture.original_outer;
    for ([_]@FieldType(@FieldType(contracts.workspace.Work, "request_cut"), "level"){
        .guest_cut,
        .outer_execution,
    }, 0..) |level, i| {
        var current = try service.workspaceWork(a, parent.receipt.task, selection_state.id.*);
        defer current.deinit();
        _ = try service.workspaceRequestCut(
            scratch,
            if (i == 0) "guest-cut" else "outer-cut",
            parent.receipt.task,
            .{
                .expected = .{
                    .work = selection_state.expected.*.work,
                    .execution_revision = current.value.execution_revision,
                    .control_revision = current.value.control_revision,
                },
                .level = level,
            },
        );
    }
    phase.* = "observer multiple cuts";
    const observer = try observerWitness(
        service,
        scratch,
        parent.receipt.task,
        programs.shared_program.*,
        programs.shared_input.*,
    );
    phase.* = "retention observer";
    try retentionObserverWitness(service, scratch, parent.receipt.task, observer.selection);
    const trace_state = .{
        .traced_id = &traced_id.*,
        .pump_command = &pump_command,
        .suspended = &suspended.*,
        .original_outer = &original_outer.*,
        .observer = &observer,
    };

    phase.* = "reopen original owner";
    try service.close(a);
    fixture.service_open.* = false;
    try fixture.namespace.*.close();
    fixture.namespace_open.* = false;
    try runtimeSelectionReopenOwner(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = &trace_state,
    });
}

fn runtimeSelectionReopenOwner(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const a = fixture.a.*;
    const io = fixture.io.*;
    const parent = fixture.parent.*;
    const trace_state = capture.trace_state.*;
    var imported_namespace = try native.Namespace.open(a, io, fixture.path.*);
    defer support.expectCleanup(imported_namespace.close());
    var imported = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &imported_namespace,
        fixture.assets.*,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile.*,
    );
    defer support.expectCleanup(imported.close(a));
    var restored_trace = try imported.workspaceWork(
        a,
        parent.receipt.task,
        trace_state.traced_id.*,
    );
    defer restored_trace.deinit();
    const reopened = .{
        .imported_namespace = &imported_namespace,
        .imported = &imported,
        .restored_trace = &restored_trace,
    };

    try runtimeSelectionResumeObserver(capture, reopened);
}

fn runtimeSelectionResumeObserver(capture: anytype, reopened: anytype) !void {
    const fixture = capture.fixture.*;
    const a = fixture.a.*;
    const parent = fixture.parent.*;
    const phase = fixture.phase;
    const scratch = fixture.scratch.*;
    const observer = capture.trace_state.*.observer.*;
    phase.* = "observer replay after reopen";
    const observer_replay = try reopened.imported.*.workspaceObserve(
        scratch,
        "observe-second",
        parent.receipt.task,
        observer.selection,
    );
    try std.testing.expect(observer_replay.replayed);
    try std.testing.expectEqualDeep(observer.receipt, observer_replay.receipt.id);
    var observer_work = try reopened.imported.*.workspaceWork(
        scratch,
        parent.receipt.task,
        observer.work,
    );
    defer observer_work.deinit();
    _ = try reopened.imported.*.workspaceStopObserving(
        scratch,
        "observer-stop",
        parent.receipt.task,
        .{
            .work = try workspaceRef(scratch, .work, observer.work),
            .execution_revision = observer_work.value.execution_revision,
            .control_revision = observer_work.value.control_revision,
        },
    );
    phase.* = "build yielding input request";
    var question_builder = source.Builder.init(a);
    defer question_builder.deinit();
    const question_module = try @import("workspace_sources.zig").binaryQuestion(&question_builder);
    question_builder.functions.items[
        @intCast(question_module.entry)
    ].body = try question_builder.term(.{
        .yield_then = question_builder.functions.items[@intCast(question_module.entry)].body.?,
    });
    try runtimeSelectionPublishQuestion(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = capture.trace_state,
        .reopened = &reopened,
        .question_builder = &question_builder,
        .question_module = &question_module,
    });
}

fn runtimeSelectionPublishQuestion(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const phase = fixture.phase;
    const reopened = capture.reopened.*;
    const imported = reopened.imported;
    const question_builder = capture.question_builder;
    const question_module = capture.question_module.*;
    const question_document = try native.source_records.encode(
        scratch,
        question_builder.*.module(question_module.entry, question_module.failure),
    );
    const question_program = try imported.workspaceCommand(
        scratch,
        "pending-cancel-program",
        parent.receipt.task,
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = question_document,
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{
            .effect = 0,
            .class = .input,
        }} } } } },
    );
    try std.testing.expectEqual(.observed, question_program.disposition);
    phase.* = "start yielding input request";
    const question_started = try imported.workspaceStart(
        scratch,
        "pending-cancel-start",
        parent.receipt.task,
        try nativeIdentity(question_program.program.?),
        &.{},
        .{},
    );
    const question_id = question_started.receipt.workspace.?;
    const question_ref = try workspaceRef(scratch, .work, question_id);
    var yielded_question = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
    defer yielded_question.deinit();
    try std.testing.expectEqual(.yielded, yielded_question.value.outcome_kind);
    phase.* = "suspend input request advance";
    _ = try imported.workspacePump(scratch, "pending-cancel-begin", parent.receipt.task, .{
        .expected = .{
            .work = question_ref,
            .execution_revision = yielded_question.value.execution_revision,
            .control_revision = yielded_question.value.control_revision,
        },
        .base_quantum = 1,
    });
    var pending_question = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
    defer pending_question.deinit();
    try std.testing.expect(pending_question.value.outer_operation != null);
    phase.* = "cancel suspended input request advance";
    try runtimeSelectionCancelSuspendedQuestion(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = capture.trace_state,
        .reopened = capture.reopened,
        .question_id = &question_id,
        .pending_question = &pending_question,
    });
}

fn runtimeSelectionCancelSuspendedQuestion(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const reopened = capture.reopened.*;
    const question_id = capture.question_id.*;
    const pending_question = capture.pending_question;
    _ = try reopened.imported.*.workspaceControl(
        fixture.scratch.*,
        "pending-cancel-request",
        fixture.parent.*.receipt.task,
        question_id,
        pending_question.*.value.execution_revision,
        pending_question.*.value.control_revision,
        .{ .cancel = .{ .bytes = "stop before question" } },
    );
    var question_cancelled = false;
    var saw_pending_question = false;
    fixture.phase.* = "apply pending cancellation at the requested cut";
    try runtimeSelectionFinishPendingCancellation(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = capture.trace_state,
        .reopened = capture.reopened,
        .question_id = capture.question_id,
        .question_cancelled = &question_cancelled,
        .saw_pending_question = &saw_pending_question,
    });
}

fn runtimeSelectionFinishPendingCancellation(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const reopened = capture.reopened.*;
    const imported = reopened.imported;
    const question_id = capture.question_id.*;
    const question_cancelled = capture.question_cancelled;
    const saw_pending_question = capture.saw_pending_question;
    for (0..512) |_| {
        var current = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            question_cancelled.* = true;
            break;
        }
        if (current.value.outcome_kind == .requested and !current.value.cancellation_applied) {
            saw_pending_question.* = true;
            try std.testing.expect(current.value.current_port != null);
            try std.testing.expectEqual(.queued, current.value.schedule);
            _ = try imported.workspaceControl(
                scratch,
                "pending-cancel-explicit",
                parent.receipt.task,
                question_id,
                current.value.execution_revision,
                current.value.control_revision,
                .{ .delegate = .{ .stop = .terminal, .continuation = .explicit_only } },
            );
            var explicit = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
            defer explicit.deinit();
            try std.testing.expectEqual(.parked, explicit.value.schedule);
            _ = try imported.workspaceControl(
                scratch,
                "pending-cancel-owner",
                parent.receipt.task,
                question_id,
                explicit.value.execution_revision,
                explicit.value.control_revision,
                .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } },
            );
            var delegated = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
            defer delegated.deinit();
            try std.testing.expectEqual(.queued, delegated.value.schedule);
            try std.testing.expectEqualDeep(
                current.value.current_port,
                delegated.value.current_port,
            );
            try imported.validateWorkspace(scratch, parent.receipt.task);
        }
        _ = try imported.pump(scratch);
    }
    try runtimeSelectionResumeObservers(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = capture.trace_state,
        .reopened = capture.reopened,
        .question_cancelled = capture.question_cancelled,
        .saw_pending_question = capture.saw_pending_question,
    });
}

fn runtimeSelectionResumeObservers(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const phase = fixture.phase;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const trace_state = capture.trace_state.*;
    const observer = trace_state.observer.*;
    const reopened = capture.reopened.*;
    const imported = reopened.imported;
    const question_cancelled = capture.question_cancelled;
    const saw_pending_question = capture.saw_pending_question;
    try std.testing.expect(saw_pending_question.* and question_cancelled.*);
    phase.* = "resume retained observer scheduling";
    try std.testing.expectEqual(
        null,
        try observerSuccessor(imported, scratch, parent.receipt.task, observer.scheduled.previous),
    );
    var parked_parent = try imported.task(scratch, parent.receipt.task);
    defer parked_parent.deinit();
    {
        var statement = try reopened.imported_namespace.*.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(
            @as(c_int, 0),
            CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace),
        );
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        _ = try imported.resumeTask(
            scratch,
            "resume-observer-owner",
            parent.receipt.task,
            parked_parent.value.revision,
        );
        std.debug.print("observer inventory scans: resume={d}\n", .{trace.scans});
        try std.testing.expectEqual(@as(usize, 1), trace.scans);
    }
    try scheduledObserverWitness(imported, scratch, parent.receipt.task, observer.scheduled);
    phase.* = "export completed cancellation history";
    const completed_archive = try std.fmt.allocPrint(
        scratch,
        "{s}/pending-cancellation.par",
        .{fixture.path_buffer.*[0..fixture.length.*]},
    );
    _ = try imported.exportCheckpoint(scratch, parent.receipt.task, completed_archive);
    try runtimeSelectionRetainOuterThroughArchive(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = capture.trace_state,
        .reopened = capture.reopened,
        .completed_archive = &completed_archive,
    });
}

fn runtimeSelectionRetainOuterThroughArchive(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const scratch = fixture.scratch.*;
    const parent = fixture.parent.*;
    const a = fixture.a.*;
    const trace_state = capture.trace_state.*;
    const original_outer = trace_state.original_outer;
    const reopened = capture.reopened.*;
    const imported = reopened.imported;
    const restored_trace = reopened.restored_trace;
    const completed_archive = capture.completed_archive.*;
    try observerArchiveRoundTrip(
        imported,
        scratch,
        parent.receipt.task,
        trace_state.observer.*.scheduled.previous,
        trace_state.suspended.*.value,
        completed_archive,
        fixture.path.*,
        try std.fmt.allocPrint(
            scratch,
            "{s}/completed-observer-copy",
            .{fixture.path_buffer.*[0..fixture.length.*]},
        ),
    );
    fixture.phase.* = "resume retained outer execution";
    _ = try imported.workspacePump(scratch, "resume-outer-one", parent.receipt.task, .{
        .expected = .{
            .work = trace_state.pump_command.*.expected.work,
            .execution_revision = restored_trace.value.execution_revision,
            .control_revision = restored_trace.value.control_revision,
        },
        .base_quantum = 1,
    });
    var continued = try imported.workspaceWork(a, parent.receipt.task, trace_state.traced_id.*);
    defer continued.deinit();
    try std.testing.expect(continued.value.outer_operation != null);
    var continued_outer = try kosmos.RuntimeCapsule.read(
        a,
        try reopened.imported_namespace.*.store.object(
            scratch,
            continued.value.outer_operation.?.capsule,
            null,
        ),
    );
    defer continued_outer.deinit();
    try std.testing.expect(
        continued_outer.value.record.outer_revision > original_outer.value.record.outer_revision,
    );
    try std.testing.expectEqual(
        original_outer.value.record.guest_revision,
        continued_outer.value.record.guest_revision,
    );
    try std.testing.expectEqualSlices(
        u8,
        original_outer.value.command,
        continued_outer.value.command,
    );
    try runtimeSelectionFinishOuter(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .view = capture.view,
        .trace_state = capture.trace_state,
        .reopened = capture.reopened,
    });
}

fn runtimeSelectionFinishOuter(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const a = fixture.a.*;
    const parent = fixture.parent.*;
    const scratch = fixture.scratch.*;
    const selection_state = capture.selection_state.*;
    const selected = selection_state.selected;
    const view = capture.view.*;
    const trace_state = capture.trace_state.*;
    const reopened = capture.reopened.*;
    const imported = reopened.imported;
    for (0..101) |pump_turn| {
        var current = try imported.workspaceWork(a, parent.receipt.task, trace_state.traced_id.*);
        defer current.deinit();
        if (current.value.outer_operation == null) {
            try std.testing.expectEqual(
                reopened.restored_trace.*.value.execution_revision + 1,
                current.value.execution_revision,
            );
            break;
        }
        try std.testing.expect(pump_turn < 100);
        _ = try imported.workspacePump(
            scratch,
            try std.fmt.allocPrint(scratch, "finish-outer-{d}", .{pump_turn}),
            parent.receipt.task,
            .{
                .expected = .{
                    .work = trace_state.pump_command.*.expected.work,
                    .execution_revision = current.value.execution_revision,
                    .control_revision = current.value.control_revision,
                },
                .base_quantum = 1048576,
            },
        );
    }

    const imported_view = try imported.workspaceCommand(
        scratch,
        "read-imported-view",
        parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = view.view_ref.*, .page = .{} } } },
    );
    try std.testing.expectEqual(.observed, imported_view.disposition);
    var restored = try imported.workspaceWork(a, parent.receipt.task, selection_state.id.*);
    defer restored.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, restored.value.checkpoint);
    try std.testing.expectEqualDeep(selected.value.runtime, restored.value.runtime);
    _ = try imported.workspaceRealize(scratch, "return-generic", parent.receipt.task, .{
        .expected = .{
            .work = selection_state.expected.*.work,
            .execution_revision = restored.value.execution_revision,
            .control_revision = restored.value.control_revision,
        },
        .realization_revision = restored.value.realization_revision,
        .runtime = .{ .packaged = .{} },
    });
    try runtimeSelectionRestorePackagedRuntime(.{
        .fixture = capture.fixture,
        .programs = capture.programs,
        .selection_state = capture.selection_state,
        .reopened = capture.reopened,
    });
}

fn runtimeSelectionRestorePackagedRuntime(capture: anytype) !void {
    const fixture = capture.fixture.*;
    const parent = fixture.parent.*;
    const scratch = fixture.scratch.*;
    const programs = capture.programs.*;
    const selection_state = capture.selection_state.*;
    const id = selection_state.id.*;
    const reopened = capture.reopened.*;
    const imported = reopened.imported;
    var generic = try imported.workspaceWork(fixture.a.*, parent.receipt.task, id);
    defer generic.deinit();
    try std.testing.expectEqualDeep(
        selection_state.before.*.value.checkpoint,
        generic.value.checkpoint,
    );
    try std.testing.expectEqual(@as(u64, 2), generic.value.realization_revision);
    try std.testing.expect(generic.value.runtime == null);
    _ = try imported.workspaceControl(
        scratch,
        "advance-generic",
        parent.receipt.task,
        id,
        generic.value.execution_revision,
        generic.value.control_revision,
        .advance,
    );
    try cancelObserverTaskWitness(imported, scratch, parent.receipt.task);
    {
        var statement = try reopened.imported_namespace.*.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(
            @as(c_int, 0),
            CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace),
        );
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        try std.testing.expect(try imported.associatedWorkDisposed(scratch, parent.receipt.task));
        std.debug.print("observer inventory scans: disposal={d}\n", .{trace.scans});
        try std.testing.expectEqual(@as(usize, 1), trace.scans);
    }
    try observerArchiveWitness(imported, scratch, programs.document.*, programs.input.*);
}

fn runtimeSelectionPartialViews(scope: anytype) !void {
    var partial = scope.view.*.view_command.*;
    partial.context.materialize.input.guest_view.nodes = .{ .selected = .{ .items = &.{} } };
    const response = try scope.fixture.*.service.*.workspaceCommand(
        scope.fixture.*.scratch.*,
        "partial-view",
        scope.fixture.*.parent.*.receipt.task,
        partial,
    );
    try std.testing.expectEqual(.observed, response.disposition);
    const ref_id = try nativeIdentity(response.evidence.?);
    var value = try contracts.decodeOwned(
        native.workspace.Value,
        scope.fixture.*.a.*,
        (try scope.fixture.*.namespace.*.store.recordBytes(
            scope.fixture.*.scratch.*,
            "workspace_value",
            try native.workspace.custodyId(
                scope.fixture.*.scratch.*,
                scope.fixture.*.parent.*.receipt.task,
                ref_id,
            ),
            scope.fixture.*.parent.*.receipt.task,
        )).?,
    );
    defer value.deinit();
    var partial_data = try native.dynamic_values.decode(
        scope.fixture.*.a.*,
        scope.view.*.view_schema.*,
        try scope.fixture.*.namespace.*.store.object(
            scope.fixture.*.scratch.*,
            value.value.description.value,
            null,
        ),
    );
    defer partial_data.deinit();
    try std.testing.expect(!partial_data.value.array.items[1].bool);
    try std.testing.expectEqual(
        @as(usize, 0),
        partial_data.value.array.items[2].array.items.len,
    );
    try expectContextOutputBound(
        &scope.fixture.*.service.*,
        scope.fixture.*.scratch.*,
        scope.fixture.*.parent.*.receipt.task,
        "guest-view",
        response.evidence.?,
        null,
    );
    partial.context.materialize.input.guest_view.realization_revision = 0;
    const stale_view = try scope.fixture.*.service.*.workspaceCommand(
        scope.fixture.*.scratch.*,
        "stale-view",
        scope.fixture.*.parent.*.receipt.task,
        partial,
    );
    try std.testing.expectEqual(.rejected, stale_view.disposition);
    const other_parent = try scope.fixture.*.service.*.submit(
        scope.fixture.*.scratch.*,
        "other-view-task",
        .{ 25, 5 },
    );
    try runtimeSelectionPartialViewsDenied(.{
        .scope = &scope,
        .other_parent = &other_parent,
    });
}

fn runtimeSelectionPartialViewsDenied(capture: anytype) !void {
    const scope = capture.scope.*;
    const other_parent = capture.other_parent.*;
    const denied = try scope.fixture.*.service.*.workspaceCommand(
        scope.fixture.*.scratch.*,
        "foreign-view",
        other_parent.receipt.task,
        scope.view.*.view_command.*,
    );
    try std.testing.expectEqual(.rejected, denied.disposition);
    const other_program = try scope.fixture.*.service.*.workspaceBuild(
        scope.fixture.*.scratch.*,
        "other-build",
        other_parent.receipt.task,
        scope.programs.*.document.*,
        &scope.programs.*.diagnostic.*,
    );
    const other_start = try scope.fixture.*.service.*.workspaceStart(
        scope.fixture.*.scratch.*,
        "other-start",
        other_parent.receipt.task,
        other_program.receipt.workspace.?,
        scope.programs.*.input.*,
        .{},
    );
    var other_work = try scope.fixture.*.service.*.workspaceWork(
        scope.fixture.*.scratch.*,
        other_parent.receipt.task,
        other_start.receipt.workspace.?,
    );
    defer other_work.deinit();
    const foreign_runtime = try scope.fixture.*.service.*.workspaceCommand(
        scope.fixture.*.scratch.*,
        "foreign-runtime",
        other_parent.receipt.task,
        .{ .work = .{ .realize = .{
            .expected = .{
                .work = try workspaceRef(scope.fixture.*.scratch.*, .work, other_work.value.id),
                .execution_revision = other_work.value.execution_revision,
                .control_revision = other_work.value.control_revision,
            },
            .realization_revision = other_work.value.realization_revision,
            .runtime = .{ .selected = scope.programs.*.runtime.* },
        } } },
    );
    try std.testing.expectEqual(.rejected, foreign_runtime.disposition);
}

fn runtimeSelectionRetentionQuery(scope: anytype) !void {

    // Feed the acquired view to an ordinary generated query. The input
    // materialization preserves its inspection ancestry through the result.
    scope.fixture.*.phase.* = "retention query build";
    const query_source = try native.program_construction.runtimeQuery(
        scope.fixture.*.scratch.*,
        true,
    );
    const query = try scope.fixture.*.service.*.workspaceBuild(
        scope.fixture.*.scratch.*,
        "retention-query",
        scope.fixture.*.parent.*.receipt.task,
        query_source,
        &scope.programs.*.diagnostic.*,
    );
    const query_id = query.receipt.workspace.?;
    var query_program = try contracts.decodeOwned(
        native.workspace.Program,
        scope.fixture.*.a.*,
        (try scope.fixture.*.namespace.*.store.recordBytes(
            scope.fixture.*.scratch.*,
            "workspace_program",
            try native.workspace.custodyId(
                scope.fixture.*.scratch.*,
                scope.fixture.*.parent.*.receipt.task,
                query_id,
            ),
            scope.fixture.*.parent.*.receipt.task,
        )).?,
    );
    defer query_program.deinit();
    var input_json: native.json.Value = .{ .array = .init(scope.fixture.*.scratch.*) };
    try input_json.array.append(scope.view.*.view_data.*.value);
    try input_json.array.append(
        scope.view.*.view_data.*.value.array.items[3].array.items[0].array.items[0],
    );
    const query_input = try scope.fixture.*.service.*.workspaceCommand(
        scope.fixture.*.scratch.*,
        "retention-input",
        scope.fixture.*.parent.*.receipt.task,
        .{ .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{ .schema = try workspaceRef(
                scope.fixture.*.scratch.*,
                .schema,
                query_program.value.description.input_schema.digest,
            ), .json_text = .{
                .bytes = try native.json.canonical(scope.fixture.*.scratch.*, input_json),
            } } } },
            .sources = .{ .items = &.{scope.view.*.view_ref.*} },
        } } },
    );
    try std.testing.expectEqual(.observed, query_input.disposition);
    try runtimeSelectionRetentionQueryQueryStart(.{
        .scope = &scope,
        .query_id = &query_id,
        .query_program = &query_program,
        .query_input = &query_input,
    });
}

fn runtimeSelectionRetentionQueryQueryStart(capture: anytype) !void {
    const scope = capture.scope.*;
    const query_id = capture.query_id.*;
    const query_input = capture.query_input.*;
    const query_start = try scope.fixture.*.service.*.workspaceCommand(
        scope.fixture.*.scratch.*,
        "run-retention",
        scope.fixture.*.parent.*.receipt.task,
        .{ .work = .{ .start = .{ .program = try workspaceRef(
            scope.fixture.*.scratch.*,
            .program,
            query_id,
        ), .input = .{ .reference = query_input.evidence.? }, .policy = .{} } } },
    );
    try std.testing.expectEqual(.observed, query_start.disposition);
    const started_json = (try native.json.parseAsset(
        scope.fixture.*.scratch.*,
        query_start.observation_json.bytes,
        query_start.observation_json.bytes.len,
    )).value;
    const query_work_id = try nativeIdentity(
        try native.values.fromJson(
            contracts.workspace.Ref,
            scope.fixture.*.scratch.*,
            started_json.object.get("work").?,
        ),
    );
    try runtimeSelectionRetentionQueryWorkspaceWork(.{
        .scope = capture.scope,
        .query_program = capture.query_program,
        .query_input = capture.query_input,
        .query_work_id = &query_work_id,
    });
}

fn runtimeSelectionRetentionQueryWorkspaceWork(capture: anytype) !void {
    const scope = capture.scope.*;
    const query_program = capture.query_program;
    const query_input = capture.query_input.*;
    const query_work_id = capture.query_work_id.*;
    for (0..201) |turn| {
        var current = try scope.fixture.*.service.*.workspaceWork(
            scope.fixture.*.a.*,
            scope.fixture.*.parent.*.receipt.task,
            query_work_id,
        );
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.completed, current.value.outcome_kind);
            var result = try native.dynamic_values.decode(
                scope.fixture.*.a.*,
                try scope.fixture.*.namespace.*.store.object(
                    scope.fixture.*.scratch.*,
                    query_program.*.value.description.result_schema,
                    null,
                ),
                try scope.fixture.*.namespace.*.store.object(
                    scope.fixture.*.scratch.*,
                    current.value.result.?,
                    null,
                ),
            );
            defer result.deinit();
            try std.testing.expectEqual(
                @as(u32, 0),
                try native.values.fromJson(
                    u32,
                    scope.fixture.*.scratch.*,
                    result.value.array.items[1],
                ),
            );
            try std.testing.expectEqualDeep(
                query_input.evidence.?,
                try workspaceRef(
                    scope.fixture.*.scratch.*,
                    .value,
                    current.value.input_value.?.digest,
                ),
            );
            break;
        }
        try std.testing.expect(turn < 200);
        _ = try scope.fixture.*.service.*.workspaceControl(
            scope.fixture.*.scratch.*,
            try std.fmt.allocPrint(scope.fixture.*.scratch.*, "query-turn-{d}", .{turn}),
            scope.fixture.*.parent.*.receipt.task,
            query_work_id,
            current.value.execution_revision,
            current.value.control_revision,
            .advance,
        );
    }
}

fn runtimeSelectionFalseTrace(scope: anytype) !void {

    // Rehash the false trace and its retained publication/receipt. The
    // independent observer must still reject the invented storage count.
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(scope.fixture.*.assets.*.manifest, &manifest_digest, .{});
    const archive_index = try scope.fixture.*.namespace.*.store.archiveIndex(
        scope.fixture.*.scratch.*,
        scope.fixture.*.parent.*.receipt.task,
        .{ .digest = manifest_digest, .bytes = scope.fixture.*.assets.*.manifest.len },
    );
    var compiler_facts = try scope.fixture.*.service.*.prepareWorkspaceValidation(
        scope.fixture.*.parent.*.receipt.task,
    );
    defer compiler_facts.deinit();
    try scope.fixture.*.namespace.*.store.begin();
    defer scope.fixture.*.namespace.*.store.rollback();
    var traced = try scope.fixture.*.service.*.workspaceWork(
        scope.fixture.*.a.*,
        scope.fixture.*.parent.*.receipt.task,
        scope.traced_id.*,
    );
    defer traced.deinit();
    traced.value.runtime_trace.?.output.trace.storage.?.node_slots += 1;
    try scope.fixture.*.namespace.*.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        scope.traced_id.*,
        scope.fixture.*.parent.*.receipt.task,
        traced.value,
    );
    const observation_bytes = try contracts.encodeOwned(
        native.workspace.WorkObservation,
        scope.fixture.*.scratch.*,
        .{ .work = traced.value, .occurrence = null },
    );
    const changed_observation = try scope.fixture.*.namespace.*.store.putObject(observation_bytes);
    var query = try scope.fixture.*.namespace.*.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?",
        &.{
            .{ .blob = &scope.fixture.*.parent.*.receipt.task },
            .{ .integer = @intCast(traced.value.event_watermark) },
        },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    var retained = try contracts.decodeOwned(
        native.testing.state.Event,
        scope.fixture.*.scratch.*,
        try query.bytes(0),
    );
    const publications = try scope.fixture.*.scratch.*.dupe(
        native.testing.state.WorkPublication,
        retained.value.workspace_publications.items,
    );
    retained.value.workspace_publications.items = publications;
    for (publications) |*publication| if (std.meta.eql(publication.work, scope.traced_id.*)) {
        publication.observation = changed_observation.digest;
    };
    try runtimeSelectionFalseTraceChangedEvent(.{
        .scope = &scope,
        .archive_index = &archive_index,
        .compiler_facts = &compiler_facts,
        .traced = &traced,
        .changed_observation = &changed_observation,
        .retained = &retained,
    });
}

fn runtimeSelectionFalseTraceChangedEvent(capture: anytype) !void {
    const scope = capture.scope.*;
    const archive_index = capture.archive_index.*;
    const compiler_facts = capture.compiler_facts;
    const traced = capture.traced;
    const changed_observation = capture.changed_observation.*;
    const retained = capture.retained;
    const changed_event = try scope.fixture.*.namespace.*.store.putObject(
        try contracts.encodeOwned(
            native.testing.state.Event,
            scope.fixture.*.scratch.*,
            retained.*.value,
        ),
    );
    try scope.fixture.*.namespace.*.store.database.run(
        "UPDATE events SET body=? WHERE task=? AND seq=?",
        &.{
            .{ .blob = &changed_event.digest },
            .{ .blob = &scope.fixture.*.parent.*.receipt.task },
            .{ .integer = @intCast(traced.*.value.event_watermark) },
        },
    );
    var receipts = try scope.fixture.*.namespace.*.store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &scope.fixture.*.parent.*.receipt.task }},
    );
    defer receipts.deinit();
    while (try receipts.step() == .row) {
        var receipt = try contracts.decodeOwned(
            native.testing.state.Receipt,
            scope.fixture.*.scratch.*,
            try receipts.bytes(1),
        );
        if (receipt.value.workspace_kind != .work or !std.meta.eql(
            receipt.value.workspace,
            @as(?[32]u8, scope.traced_id.*),
        )) continue;
        receipt.value.workspace_observation = changed_observation;
        const changed_receipt = try scope.fixture.*.namespace.*.store.putObject(
            try contracts.encodeOwned(
                native.testing.state.Receipt,
                scope.fixture.*.scratch.*,
                receipt.value,
            ),
        );
        try scope.fixture.*.namespace.*.store.database.run(
            "UPDATE operations SET receipt=? WHERE id=?",
            &.{ .{ .blob = &changed_receipt.digest }, .{ .text = try receipts.bytes(0) } },
        );
    }
    try std.testing.expectError(
        error.InvalidArchive,
        scope.fixture.*.service.*.validateWorkspaceRecordsPrepared(
            scope.fixture.*.scratch.*,
            scope.fixture.*.parent.*.receipt.task,
            archive_index.records.items,
            &compiler_facts.*,
        ),
    );
}

test "native placement carries the current cut of a queued work move" {
    try placementCase(.queued);
}

test "frozen controller retains its exact cut while local work advances" {
    try placementCase(.root);
}

test "frozen controller retains cancellation and shutdown obligations after abort" {
    try placementCase(.root_cancel_abort);
}

test "frozen controller retains cancellation and shutdown obligations after refusal" {
    try placementCase(.root_cancel_refused);
}

test "controller succession precedes a frozen child's offer and follows its eventual executor" {
    try placementCase(.preoffer);
}

test "delayed controls follow executor succession and retain prior exact reports" {
    try placementCase(.onward);
}

test "terminal parent cancellation resumes after frozen work is aborted" {
    try placementCase(.cancel_abort);
}

test "terminal parent cancellation resumes after a signed refusal" {
    try placementCase(.cancel_refused);
}

test "controller succession preserves local cancellation acknowledgement and later park" {
    try placementCase(.local_ack);
}

test "controller succession preserves remote cancellation acknowledgement and later park" {
    try placementCase(.remote_ack);
}

fn pendingCleanup(
    service: anytype,
    a: std.mem.Allocator,
    task_id: native.testing.state.TaskId,
) !?native.placement.Signed(native.placement.Control) {
    const p = native.placement;
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.task=? AND r.kind='placement_control'",
        &.{.{ .blob = &task_id }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        const saved = try contracts.decodeOwned(p.ControlRecord, a, try query.bytes(0));
        if (saved.value.report == null and std.mem.startsWith(
            u8,
            saved.value.control.value.operation.bytes,
            "cleanup-",
        )) return saved.value.control;
    }
    return null;
}

fn placementObserver(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    source_id: [32]u8,
    scheduled: bool,
) !contracts.workspace.Expected {
    var source_work = try service.workspaceWork(a, task, source_id);
    defer source_work.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(
        a,
        try @import("workspace_sources.zig").cutObserver(&builder, false),
    );
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(
        a,
        "placement-observer-program",
        task,
        text,
        &diagnostic,
    );
    const observed = try service.workspaceObserve(
        a,
        if (scheduled) "placement-observer-scheduled" else "placement-observer-explicit",
        task,
        .{
            .program = try workspaceRef(a, .program, built.receipt.workspace.?),
            .source = .{
                .expected = .{
                    .work = try workspaceRef(a, .work, source_id),
                    .execution_revision = source_work.value.execution_revision,
                    .control_revision = source_work.value.control_revision,
                },
                .realization_revision = source_work.value.realization_revision,
                .nodes = .{ .all = .{} },
            },
            .accumulator = try observerAccumulator(service, a, task, program),
            .policy = .{
                .delivery = .lossless,
                .granularity = .one_guest_step,
                .continuation = if (scheduled) .owner_scheduled else .explicit_only,
            },
        },
    );
    try observerCompleted(service, a, task, observed.receipt.workspace.?);
    var complete = try service.workspaceWork(a, task, observed.receipt.workspace.?);
    defer complete.deinit();
    return .{
        .work = try workspaceRef(a, .work, complete.value.id),
        .execution_revision = complete.value.execution_revision,
        .control_revision = complete.value.control_revision,
    };
}

fn observerCustodyWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    peer: *native.placement.Peer,
) !void {
    const started = try service.workspaceStart(
        a,
        "custody-observer-source",
        task,
        program,
        input,
        .{},
    );
    var source_work = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer source_work.deinit();
    var selection = try observerSelection(service, a, task, program, source_work.value);
    const first = try service.workspaceObserve(a, "custody-observer-first", task, selection);
    try observerCompleted(service, a, task, first.receipt.workspace.?);
    var completed = try service.workspaceWork(a, task, first.receipt.workspace.?);
    defer completed.deinit();
    try stopDiscoveredObserver(service, a, completed.value);
    try advanceObservedSource(service, a, source_work.value, "custody-observer-advance");
    var advanced = try service.workspaceWork(a, task, source_work.value.id);
    defer advanced.deinit();
    selection.source.expected.execution_revision = advanced.value.execution_revision;
    selection.source.expected.control_revision = advanced.value.control_revision;
    selection.previous = try workspaceRef(a, .work, completed.value.id);
    const subject: native.placement.Subject = .{ .task = task, .work = completed.value.id };
    const compatibility = peer.compatibility;
    peer.compatibility = try service.placementCompatibility(a, subject);
    defer peer.compatibility = compatibility;
    _ = try freezePlacement(
        service,
        subject,
        "destination",
        try service.placementCut(a, subject),
        @splat(106),
    );
    var before = try service.workspaceWork(a, task, completed.value.id);
    defer before.deinit();
    const custody = try service.placementStatus(a, subject);
    try std.testing.expectEqual(.frozen, custody.?.phase);
    try std.testing.expectError(error.CustodyNotLocal, service.workspaceObserve(
        a,
        "custody-observer-next",
        task,
        selection,
    ));
    var unchanged = try service.workspaceWork(a, task, completed.value.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(before.value, unchanged.value);
    try std.testing.expectEqualDeep(custody, try service.placementStatus(a, subject));
    try service.placementAbortUnsent(a, subject, @splat(106));
    const next = try service.workspaceObserve(a, "custody-observer-next", task, selection);
    try observerCompleted(service, a, task, next.receipt.workspace.?);
    var successor = try service.workspaceWork(a, task, next.receipt.workspace.?);
    defer successor.deinit();
    try std.testing.expectEqualDeep(
        selection.previous,
        successor.value.observer.?.selection.previous,
    );
    try stopDiscoveredObserver(service, a, successor.value);
    try sharedCancel(a, service, task, source_work.value.id, "custody-observer-source");
}

fn freezePlacement(
    service: anytype,
    subject: native.placement.Subject,
    peer: []const u8,
    cut: native.placement.Cut,
    transfer: native.testing.state.Digest,
) !native.placement.Intent {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return service.placementFreeze(arena.allocator(), subject, peer, cut, transfer);
}

fn offerPlacement(
    service: anytype,
    subject: native.placement.Subject,
    peer: []const u8,
    path: []const u8,
) !native.placement.Signed(native.placement.Offer) {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return service.placementOffer(arena.allocator(), subject, peer, path);
}

fn acceptPlacement(
    service: anytype,
    operation: []const u8,
    peer: []const u8,
    offer: native.placement.Signed(native.placement.Offer),
    path: []const u8,
) !native.placement.Signed(native.placement.Decision) {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return service.placementAccept(arena.allocator(), operation, peer, offer, path);
}
fn placementCase(comptime scenario: enum {
    work,
    queued,
    root,
    preoffer,
    onward,
    cancel_abort,
    cancel_refused,
    root_cancel_abort,
    root_cancel_refused,
    local_ack,
    remote_ack,
}) !void {
    const placement_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    var phase: []const u8 = "setup";
    var attack_index: usize = 0;
    errdefer std.debug.print("placement {s}: {s} ({d})\n", .{
        @tagName(scenario),
        phase,
        attack_index,
    });
    var meter: kosmos.AllocationBudget = .{
        .parent = std.testing.allocator,
        .limit = std.math.maxInt(usize),
    };
    var traced: AllocationFailureTrace = .{ .backing = meter.parent, .meter = &meter };
    meter.parent = traced.allocator();
    errdefer std.debug.print("placement allocation: peak={d} required={d} budget_failed={}\n", .{
        meter.peak,
        meter.required,
        meter.failed,
    });
    const a = if (scenario == .work) meter.allocator() else std.testing.allocator;
    const io = std.testing.io;
    return placementBuildRoot(scenario, .{
        .setup = .{
            .a = &a,
            .attack_index = &attack_index,
            .io = &io,
            .meter = &meter,
            .phase = &phase,
            .placement_started = &placement_started,
        },
    });
}

fn placementCancellationAcknowledgement(comptime scenario: anytype, borrow: anytype) !bool {
    if (!(scenario == .local_ack or scenario == .remote_ack)) return false;
    var ack_source_profile = borrow.fixture.profile.*;
    ack_source_profile.placement = &borrow.fixture.source_config.*;
    var ack_destination_profile = borrow.fixture.profile.*;
    ack_destination_profile.placement = &borrow.fixture.destination_config.*;
    var ack_successor_profile = borrow.fixture.profile.*;
    ack_successor_profile.placement = &borrow.fixture.successor_config.*;
    return placementMoveAckExecutor(scenario, .{
        .ack = .{
            .ack_destination_profile = &ack_destination_profile,
            .ack_source_profile = &ack_source_profile,
            .ack_successor_profile = &ack_successor_profile,
        },
        .fixture = borrow.fixture,
    });
}

fn placementFrozenRootCancellation(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    if (!(scenario == .root_cancel_abort or scenario == .root_cancel_refused)) return false;
    borrow.fixture.phase.* = "settle local child while cancelling controller is frozen";
    const controller: p.Subject = .{ .task = borrow.fixture.subject.*.task };
    _ = try borrow.fixture.sender.*.requestCancel(
        borrow.fixture.scratch.*,
        "cancel-controller",
        borrow.fixture.subject.*.task,
        "stop",
    );
    _ = try freezePlacement(
        &borrow.fixture.sender.*,
        controller,
        "destination",
        try borrow.fixture.sender.*.placementCut(borrow.fixture.scratch.*, controller),
        @splat(71),
    );
    var refusal: ?p.Signed(p.Decision) = null;

    try placementRefuseFrozenRoot(scenario, .{
        .borrow = &borrow,
        .controller = &controller,
        .refusal = &refusal,
    });

    _ = try borrow.fixture.sender.*.workspaceControl(
        borrow.fixture.scratch.*,
        "settle-controller-child",
        borrow.fixture.subject.*.task,
        borrow.fixture.work_id.*,
        borrow.fixture.cut.*.execution,
        borrow.fixture.cut.*.control,
        .{ .cancel = .{
            .bytes = "stop",
        } },
    );
    return placementDisposeFrozenChild(scenario, .{
        .frozen = .{
            .controller = &controller,
            .refusal = &refusal,
        },
        .fixture = borrow.fixture,
    });
}

fn placementRootSuccession(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    if (!(scenario == .root or scenario == .preoffer)) return false;
    if (scenario == .preoffer) _ = try freezePlacement(
        &borrow.fixture.sender.*,
        borrow.fixture.subject.*,
        "destination",
        borrow.fixture.cut.*,
        @splat(14),
    );
    const controller: p.Subject = .{ .task = borrow.fixture.subject.*.task };
    const controller_cut = try borrow.fixture.sender.*.placementCut(
        borrow.fixture.scratch.*,
        controller,
    );
    _ = try freezePlacement(
        &borrow.fixture.sender.*,
        controller,
        "successor",
        controller_cut,
        @splat(98),
    );
    const frozen_head = borrow.fixture.source_namespace.*.store.head;
    const frozen_runnable = try borrow.fixture.scratch.*.dupe(
        native.workspace.Subject,
        borrow.fixture.sender.*.runnable.items,
    );
    return placementReplayFrozenBuild(scenario, .{
        .frozen = .{
            .controller = &controller,
            .controller_cut = &controller_cut,
            .frozen_head = &frozen_head,
            .frozen_runnable = &frozen_runnable,
        },
        .fixture = borrow.fixture,
    });
}

fn placementBuildRoot(comptime scenario: anytype, borrow: anytype) !void {
    var root_builder = source.Builder.init(borrow.setup.a.*);
    defer root_builder.deinit();
    const root_module = try gcd(&root_builder);
    const root_body = root_builder.functions.items[@intCast(root_module.entry)].body.?;
    root_builder.functions.items[
        @intCast(root_module.entry)
    ].body = try root_builder.term(.{
        .yield_then = try root_builder.term(.{ .yield_then = root_body }),
    });
    if (scenario == .work) {
        var unpack = root_builder.terms.items[@intCast(root_body)].unpack_product;
        const number = try root_builder.scalar(u64);
        var delayed = try root_builder.reference(unpack.variables[0]);
        for (0..256) |_| delayed = try root_builder.primitive(
            number,
            .integer_bit_xor,
            &.{ delayed, try root_builder.constant(u64, 1) },
            0,
        );
        unpack.body = try root_builder.bind(
            try root_builder.variable(number),
            try root_builder.pure(delayed),
            try root_builder.term(.{
                .yield_then = try root_builder.term(.{ .yield_then = unpack.body }),
            }),
        );
        root_builder.functions.items[
            @intCast(root_module.entry)
        ].body = try root_builder.term(.{ .unpack_product = unpack });
    }
    return placementConfigureApplication(scenario, .{
        .root = .{
            .root_builder = &root_builder,
            .root_module = &root_module,
        },
        .setup = borrow.setup,
    });
}

fn placementConfigureApplication(comptime scenario: anytype, borrow: anytype) !void {
    var root = try compile(
        borrow.setup.a.*,
        &borrow.root.root_builder.*,
        borrow.root.root_builder.*.module(
            borrow.root.root_module.*.entry,
            borrow.root.root_module.*.failure,
        ),
    );
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(borrow.setup.a.*, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(borrow.setup.a.*),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "placement-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const manifest = try fixtureManifest(
        borrow.setup.a.*,
        root.image,
        admitted.identity(),
        "placement-unit",
    );
    defer borrow.setup.a.*.free(manifest);
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = "placement-unit",
        .manifest = manifest,
    };
    var handlers = try native.Registry.init(borrow.setup.a.*, &.{});
    defer handlers.deinit();
    var profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "placement-test", .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    return placementOpenNamespaces(scenario, .{
        .application = .{
            .application = &application,
            .assets = &assets,
            .handlers = &handlers,
            .profile = &profile,
        },
        .setup = borrow.setup,
    });
}

fn placementOpenNamespaces(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.setPermissions(borrow.setup.io.*, .fromMode(0o700));
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(borrow.setup.io.*, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(borrow.setup.a.*);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_path = try std.fmt.allocPrint(scratch, "{s}/source", .{path_buffer[0..length]});
    const destination_path = try std.fmt.allocPrint(scratch, "{s}/destination", .{
        path_buffer[0..length],
    });
    const successor_path = try std.fmt.allocPrint(scratch, "{s}/successor", .{
        path_buffer[0..length],
    });
    var untrusted_namespaces: [3]@FieldType(p.Site, "namespace") = undefined;
    if (scenario == .onward) for (&untrusted_namespaces, 0..) |*identity, attack| {
        var empty = try native.Namespace.open(
            borrow.setup.a.*,
            borrow.setup.io.*,
            try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}", .{
                path_buffer[0..length],
                attack,
            }),
        );
        identity.* = empty.identity;
        try empty.close();
    };
    return placementIdentifyNamespaces(scenario, .{
        .paths = .{
            .destination_path = &destination_path,
            .length = &length,
            .path_buffer = &path_buffer,
            .scratch = &scratch,
            .source_path = &source_path,
            .successor_path = &successor_path,
            .untrusted_namespaces = &untrusted_namespaces,
        },
        .application = borrow.application,
        .setup = borrow.setup,
    });
}

fn placementOpenServices(comptime scenario: anytype, borrow: anytype) !void {
    var sender_compiler_facts: native.tasks.Service(
        OwnerTypes,
    ).CompilerFacts = .{
        .allocator = borrow.setup.a.*,
    };
    defer sender_compiler_facts.deinit();
    var receiver_compiler_facts: native.tasks.Service(
        OwnerTypes,
    ).CompilerFacts = .{
        .allocator = borrow.setup.a.*,
    };
    defer receiver_compiler_facts.deinit();
    var controller_compiler_facts: native.tasks.Service(
        OwnerTypes,
    ).CompilerFacts = .{
        .allocator = borrow.setup.a.*,
    };
    defer controller_compiler_facts.deinit();
    var sender = try native.tasks.Service(OwnerTypes).init(
        borrow.setup.a.*,
        borrow.setup.io.*,
        &borrow.namespaces.source_namespace.*,
        borrow.application.assets.*,
        &borrow.application.application.*,
        borrow.application.handlers.*,
        borrow.application.profile.*,
    );
    var sender_open = true;
    defer if (sender_open) support.expectCleanup(sender.close(borrow.setup.a.*));
    var receiver: native.tasks.Service(OwnerTypes) = undefined;
    var receiver_open = false;
    defer if (receiver_open) support.expectCleanup(receiver.close(borrow.setup.a.*));
    return placementBuildChild(scenario, .{
        .services = .{
            .controller_compiler_facts = &controller_compiler_facts,
            .receiver = &receiver,
            .receiver_compiler_facts = &receiver_compiler_facts,
            .receiver_open = &receiver_open,
            .sender = &sender,
            .sender_compiler_facts = &sender_compiler_facts,
            .sender_open = &sender_open,
        },
        .application = borrow.application,
        .namespaces = borrow.namespaces,
        .setup = borrow.setup,
    });
}

fn placementBuildChild(comptime scenario: anytype, borrow: anytype) !void {
    const parent = try borrow.services.sender.*.submit(
        borrow.namespaces.scratch.*,
        "parent",
        .{ 25, 5 },
    );
    var builder = source.Builder.init(borrow.setup.a.*);
    defer builder.deinit();
    const document = try native.source_records.encode(borrow.setup.a.*, try listLength(&builder));
    defer borrow.setup.a.*.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try borrow.services.sender.*.workspaceBuild(
        borrow.namespaces.scratch.*,
        "build",
        parent.receipt.task,
        document,
        &diagnostic,
    );
    const selected_program = if (scenario == .work)
        try semanticGuestProgram(
            borrow.namespaces.scratch.*,
            &borrow.services.sender.*,
            parent.receipt.task,
            "placement-semantic-guest",
        )
    else
        program.receipt.workspace.?;
    const specialized: ?native.tasks.Admission = if (scenario == .work)
        null
    else
        try borrow.services.sender.*.workspaceSpecialize(
            borrow.namespaces.scratch.*,
            "specialize",
            parent.receipt.task,
            selected_program,
        );
    const ancestor: ?contracts.workspace.Ref = if (specialized) |item|
        try workspaceRef(borrow.namespaces.scratch.*, .runtime, item.receipt.workspace.?)
    else
        null;
    return placementSelectRuntime(scenario, .{
        .child = .{
            .ancestor = &ancestor,
            .diagnostic = &diagnostic,
            .document = &document,
            .parent = &parent,
            .program = &program,
            .selected_program = &selected_program,
            .specialized = &specialized,
        },
        .application = borrow.application,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
    });
}

fn placementSelectRuntime(comptime scenario: anytype, borrow: anytype) !void {
    const state_profile = &borrow.application.profile;
    const state_profile_current = &borrow.services.sender.*.profile;
    const state_profile_current_current = &borrow.services.receiver.*.profile;

    var packaged_runtime = try borrow.services.sender.*.program.retainRuntime();
    defer packaged_runtime.deinit();
    const semantic_roots = [_][32]u8{
        kosmos.RuntimeCompiler.approvedRootIdentity(&packaged_runtime),
        if (borrow.child.specialized.* != null) kosmos.RuntimeCompiler.approvedRootIdentity(
            &borrow.services.sender.*.runtime_cache.?.artifact,
        ) else kosmos.RuntimeCompiler.approvedRootIdentity(&packaged_runtime),
    };
    state_profile.*.*.semantic_construction = .{
        .roots = &semantic_roots,
        .checkers = &.{kosmos.RuntimeCompiler.checker_identity},
        .guard = true,
    };
    state_profile_current.*.semantic_construction = state_profile.*.*.semantic_construction;
    state_profile_current_current.*.semantic_construction = state_profile.*.*.semantic_construction;
    return placementGenerateRuntime(scenario, .{
        .application = borrow.application,
        .child = borrow.child,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
    });
}

fn placementGenerateRuntime(comptime scenario: anytype, borrow: anytype) !void {
    const state_sender_compiler_facts = &borrow.services.sender_compiler_facts;
    const state_compiler_facts = &borrow.services.sender.*.compiler_facts;

    const generated: ?GeneratedRuntime = if (scenario == .work) blk: {
        borrow.setup.phase.* = "generated transformation and retained runtime continuation";
        var construction_live: usize = 0;
        const derived = construction: {
            var request = std.heap.ArenaAllocator.init(borrow.services.sender.*.allocator);
            defer request.deinit();
            const construction_allocator = request.allocator();
            var retained = try exerciseGenerated(
                construction_allocator,
                &borrow.services.sender.*,
                borrow.child.parent.*.receipt.task,
                borrow.child.selected_program.*,
                try contracts.encodeOwned(@import(
                    "workspace_sources.zig",
                ).SemanticGuestInput, construction_allocator, .{ .yields = 64, .seed = 100 }),
            );
            inline for (.{ "candidate", "runtime", "producer", "result" }) |field| {
                @field(
                    retained,
                    field,
                ).id.bytes = try borrow.namespaces.scratch.*.dupe(
                    u8,
                    @field(retained, field).id.bytes,
                );
            }
            construction_live = borrow.setup.meter.*.live;
            break :construction retained;
        };
        std.debug.print(
            "semantic placement: construction backing before_release={d} after_release={d}\n",
            .{
                construction_live,
                borrow.setup.meter.*.live,
            },
        );
        borrow.setup.phase.* = "verify temporary construction work disposal";
        std.debug.print("semantic placement: disposal at {d}ms\n", .{
            sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
        });
        try std.testing.expect(
            try borrow.services.sender.*.associatedWorkDisposed(
                borrow.namespaces.scratch.*,
                borrow.child.parent.*.receipt.task,
            ),
        );
        break :blk derived;
    } else null;
    if (scenario == .work) state_compiler_facts.* = &state_sender_compiler_facts.*.*;
    return placementPrepareInput(scenario, .{
        .generated = .{
            .generated = &generated,
        },
        .application = borrow.application,
        .child = borrow.child,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
    });
}

fn placementPrepareInput(comptime scenario: anytype, borrow: anytype) !void {
    const state_generated = &borrow.generated.generated;

    const runtime = if (state_generated.*.*) |derived|
        derived.runtime
    else
        borrow.child.ancestor.*.?;
    const input = if (scenario == .work)
        try contracts.encodeOwned(@import(
            "workspace_sources.zig",
        ).SemanticGuestInput, borrow.namespaces.scratch.*, .{ .yields = 64, .seed = 100 })
    else blk: {
        const bytes = try borrow.namespaces.scratch.*.alloc(u8, 64 * 9 + 1);
        var writer: data.wire.Writer = .{ .output = bytes };
        for (0..64) |i| {
            try writer.natural(1);
            try writer.fixed(u64, @intCast(i));
        }
        try writer.natural(0);
        break :blk bytes;
    };
    return placementStartChild(scenario, .{
        .input = .{
            .input = &input,
            .runtime = &runtime,
        },
        .application = borrow.application,
        .child = borrow.child,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
    });
}

fn placementStartChild(comptime scenario: anytype, borrow: anytype) !void {
    var program_record = try borrow.services.sender.*.workspaceProgram(
        borrow.setup.a.*,
        borrow.child.parent.*.receipt.task,
        borrow.child.selected_program.*,
    );
    defer program_record.deinit();
    const input_schema = program_record.value.description.input_schema;
    var input_value = try native.dynamic_values.decode(
        borrow.setup.a.*,
        try borrow.namespaces.source_namespace.*.store.object(
            borrow.namespaces.scratch.*,
            input_schema,
            null,
        ),
        borrow.input.input.*,
    );
    defer input_value.deinit();
    const start_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = try workspaceRef(
            borrow.namespaces.scratch.*,
            .program,
            borrow.child.selected_program.*,
        ),
        .input = .{ .inline_json = .{ .schema = try workspaceRef(
            borrow.namespaces.scratch.*,
            .schema,
            input_schema.digest,
        ), .json_text = .{
            .bytes = try native.json.canonical(borrow.namespaces.scratch.*, input_value.value),
        } } },
        .policy = if (scenario == .root) .{
            .stop = .terminal,
            .continuation = .owner_scheduled,
        } else .{},
        .runtime = .{ .selected = borrow.input.runtime.* },
    } } };
    if (scenario == .work) std.debug.print("semantic placement: start selected work at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    return placementObserveChild(scenario, .{
        .start = .{
            .start_command = &start_command,
        },
        .application = borrow.application,
        .child = borrow.child,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
    });
}

fn placementObserveChild(comptime scenario: anytype, borrow: anytype) !void {
    const started = try borrow.services.sender.*.workspaceCommand(
        borrow.namespaces.scratch.*,
        "start",
        borrow.child.parent.*.receipt.task,
        borrow.start.start_command.*,
    );
    try std.testing.expectEqual(.observed, started.disposition);
    const start_observation = (try native.json.parseAsset(
        borrow.namespaces.scratch.*,
        started.observation_json.bytes,
        started.observation_json.bytes.len,
    )).value;
    const work_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        borrow.namespaces.scratch.*,
        start_observation.object.get("work").?,
    );
    const work_id = try nativeIdentity(work_ref);
    var work = try borrow.services.sender.*.workspaceWork(
        borrow.setup.a.*,
        borrow.child.parent.*.receipt.task,
        work_id,
    );
    defer work.deinit();
    try std.testing.expect(!work.value.terminal());
    _ = try borrow.services.sender.*.workspacePump(
        borrow.namespaces.scratch.*,
        "begin-outer",
        borrow.child.parent.*.receipt.task,
        .{
            .expected = .{
                .work = work_ref,
                .execution_revision = work.value.execution_revision,
                .control_revision = work.value.control_revision,
            },
            .base_quantum = 1,
        },
    );
    return placementIdentifySites(scenario, .{
        .work = .{
            .work_id = &work_id,
            .work_ref = &work_ref,
        },
        .application = borrow.application,
        .child = borrow.child,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
        .start = borrow.start,
    });
}

fn placementIdentifySites(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    const subject: p.Subject = .{
        .task = borrow.child.parent.*.receipt.task,
        .work = borrow.work.work_id.*,
    };
    const cut = try borrow.services.sender.*.placementCut(borrow.namespaces.scratch.*, subject);
    try std.testing.expect(cut.outer != null);
    const compatibility = try borrow.services.sender.*.placementCompatibility(
        borrow.namespaces.scratch.*,
        subject,
    );
    const resources = try borrow.application.profile.*.resourceIdentity(
        borrow.namespaces.scratch.*,
        borrow.application.application.*.image_identity,
    );
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(11));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(12));
    const successor_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(15));
    const source_site: p.Site = .{
        .key = source_key.public_key.toBytes(),
        .namespace = borrow.namespaces.source_namespace.*.identity,
    };
    const destination_site: p.Site = .{
        .key = destination_key.public_key.toBytes(),
        .namespace = borrow.namespaces.destination_identity.*,
    };
    const successor_site: p.Site = .{
        .key = successor_key.public_key.toBytes(),
        .namespace = borrow.namespaces.successor_identity.*,
    };
    return placementConfigureDisclosure(scenario, .{
        .sites = .{
            .compatibility = &compatibility,
            .cut = &cut,
            .destination_key = &destination_key,
            .destination_site = &destination_site,
            .resources = &resources,
            .source_key = &source_key,
            .source_site = &source_site,
            .subject = &subject,
            .successor_key = &successor_key,
            .successor_site = &successor_site,
        },
        .application = borrow.application,
        .child = borrow.child,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
        .start = borrow.start,
        .work = borrow.work,
    });
}

fn placementConfigureDisclosure(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    const Disclosure = struct {
        runtime: [32]u8,
        saw_runtime: bool = false,
        deny_runtime: bool = false,
        denied_dependency: ?[32]u8 = null,
        fn check(
            context: *anyopaque,
            _: p.Subject,
            objects: []const native.testing.state.Reference,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.denied_dependency) |denied| for (objects) |object| {
                if (std.meta.eql(object.digest, denied)) return error.DisclosureDenied;
            };
            for (objects) |object| if (std.meta.eql(object.digest, self.runtime)) {
                self.saw_runtime = true;
                if (self.deny_runtime) return error.DisclosureDenied;
            };
        }
    };
    var disclosure: Disclosure = .{ .runtime = try nativeIdentity(borrow.input.runtime.*) };
    const successor_peer: p.Peer = .{
        .name = "successor",
        .site = borrow.sites.successor_site.*,
        .native_build = borrow.application.profile.*.runtime_identity,
        .compatibility = borrow.sites.compatibility.*,
        .resource_binding = borrow.sites.resources.*,
        .disclosure_policy = @splat(13),
        .context = &disclosure,
        .disclose = Disclosure.check,
    };
    return placementConfigurePeers(scenario, .{
        .disclosure = .{
            .Disclosure = Disclosure,
            .disclosure = &disclosure,
            .successor_peer = &successor_peer,
        },
        .application = borrow.application,
        .child = borrow.child,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .start = borrow.start,
        .work = borrow.work,
    });
}

fn placementConfigurePeers(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var source_peers = [_]p.Peer{
        .{
            .name = "destination",
            .site = borrow.sites.destination_site.*,
            .native_build = borrow.application.profile.*.runtime_identity,
            .compatibility = borrow.sites.compatibility.*,
            .resource_binding = borrow.sites.resources.*,
            .disclosure_policy = @splat(13),
            .context = &borrow.disclosure.disclosure.*,
            .disclose = borrow.disclosure.Disclosure.check,
        },
        borrow.disclosure.successor_peer.*,
    };
    var destination_peers = [_]p.Peer{
        .{
            .name = "source",
            .site = borrow.sites.source_site.*,
            .native_build = borrow.application.profile.*.runtime_identity,
            .compatibility = borrow.sites.compatibility.*,
            .resource_binding = borrow.sites.resources.*,
            .disclosure_policy = @splat(13),
            .context = &borrow.disclosure.disclosure.*,
            .disclose = borrow.disclosure.Disclosure.check,
        },
        borrow.disclosure.successor_peer.*,
    };
    var successor_peers = [_]p.Peer{ source_peers[0], destination_peers[0] };
    return placementConfigureChannels(scenario, .{
        .peers = .{
            .destination_peers = &destination_peers,
            .source_peers = &source_peers,
            .successor_peers = &successor_peers,
        },
        .application = borrow.application,
        .child = borrow.child,
        .disclosure = borrow.disclosure,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .start = borrow.start,
        .work = borrow.work,
    });
}

fn placementConfigureChannels(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    const source_config: p.Configuration = .{
        .signing_key = borrow.sites.source_key.*,
        .peers = &borrow.peers.source_peers.*,
        .transport_directory = borrow.namespaces.path_buffer.*[0..borrow.namespaces.length.*],
    };
    const destination_config: p.Configuration = .{
        .signing_key = borrow.sites.destination_key.*,
        .peers = &borrow.peers.destination_peers.*,
    };
    const successor_config: p.Configuration = .{
        .signing_key = borrow.sites.successor_key.*,
        .peers = &borrow.peers.successor_peers.*,
    };
    return placementCheckMobility(scenario, .{
        .channels = .{
            .destination_config = &destination_config,
            .source_config = &source_config,
            .successor_config = &successor_config,
        },
        .application = borrow.application,
        .child = borrow.child,
        .disclosure = borrow.disclosure,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .start = borrow.start,
        .work = borrow.work,
    });
}

fn placementCheckMobility(comptime scenario: anytype, borrow: anytype) !void {
    borrow.services.sender.*.profile.placement = &borrow.channels.source_config.*;

    try placementObserveBeforeTransfer(scenario, .{
        .borrow = &borrow,
    });

    if (try placementCancellationAcknowledgement(scenario, .{
        .fixture = .{
            .a = &borrow.setup.a.*,
            .application = &borrow.application.application.*,
            .assets = &borrow.application.assets.*,
            .cut = &borrow.sites.cut.*,
            .destination_config = &borrow.channels.destination_config.*,
            .destination_path = &borrow.namespaces.destination_path.*,
            .handlers = &borrow.application.handlers.*,
            .io = &borrow.setup.io.*,
            .length = &borrow.namespaces.length.*,
            .path_buffer = &borrow.namespaces.path_buffer.*,
            .profile = &borrow.application.profile.*,
            .scratch = &borrow.namespaces.scratch.*,
            .sender = &borrow.services.sender.*,
            .sender_open = &borrow.services.sender_open.*,
            .source_config = &borrow.channels.source_config.*,
            .source_namespace = &borrow.namespaces.source_namespace.*,
            .source_open = &borrow.namespaces.source_open.*,
            .source_path = &borrow.namespaces.source_path.*,
            .source_peers = &borrow.peers.source_peers.*,
            .subject = &borrow.sites.subject.*,
            .successor_config = &borrow.channels.successor_config.*,
            .successor_path = &borrow.namespaces.successor_path.*,
            .successor_peers = &borrow.peers.successor_peers.*,
            .work_id = &borrow.work.work_id.*,
            .work_ref = &borrow.work.work_ref.*,
        },
    })) return;

    if (try placementFrozenRootCancellation(scenario, .{
        .fixture = .{
            .cut = &borrow.sites.cut.*,
            .destination_key = &borrow.sites.destination_key.*,
            .destination_site = &borrow.sites.destination_site.*,
            .length = &borrow.namespaces.length.*,
            .path_buffer = &borrow.namespaces.path_buffer.*,
            .phase = &borrow.setup.phase.*,
            .scratch = &borrow.namespaces.scratch.*,
            .sender = &borrow.services.sender.*,
            .source_site = &borrow.sites.source_site.*,
            .subject = &borrow.sites.subject.*,
            .work_id = &borrow.work.work_id.*,
        },
    })) return;

    return placementCheckQueuedCut(scenario, .{
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .disclosure = borrow.disclosure,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .start = borrow.start,
        .work = borrow.work,
    });
}

fn placementObserveBeforeTransfer(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (!(scenario == .work)) return;
    borrow.borrow.*.setup.phase.* = "prepare placement observer";
    const observer = try placementObserver(
        &borrow.borrow.*.services.sender.*,
        borrow.borrow.*.namespaces.scratch.*,
        borrow.borrow.*.sites.subject.*.task,
        borrow.borrow.*.child.selected_program.*,
        borrow.borrow.*.work.work_id.*,
        true,
    );
    const observer_subject: p.Subject = .{
        .task = borrow.borrow.*.sites.subject.*.task,
        .work = try nativeIdentity(observer.work),
    };
    const controller: p.Subject = .{ .task = borrow.borrow.*.sites.subject.*.task };
    const before = borrow.borrow.*.namespaces.source_namespace.*.store.head;
    return placementRejectObserverMobility(scenario, .{
        .rejectobservermobility = .{
            .before = &before,
            .controller = &controller,
            .observer = &observer,
            .observer_subject = &observer_subject,
        },
        .borrow = borrow.borrow,
    });
}

fn placementCheckQueuedCut(comptime scenario: anytype, borrow: anytype) !void {
    if (try placementQueuedCutWitness(scenario, .{
        .borrow = &borrow,
    })) return;

    try placementPendingCancellationWitness(scenario, .{
        .borrow = &borrow,
    });

    return placementCheckCapabilities(scenario, .{
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .disclosure = borrow.disclosure,
        .generated = borrow.generated,
        .input = borrow.input,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .start = borrow.start,
        .work = borrow.work,
    });
}

fn placementQueuedCutWitness(comptime scenario: anytype, borrow: anytype) !bool {
    if (!(scenario == .queued)) return false;
    borrow.borrow.*.peers.source_peers.*[0].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "source",
    };
    const queued_move = try borrow.borrow.*.services.sender.*.workspaceCommand(
        borrow.borrow.*.namespaces.scratch.*,
        "queue-before-progress",
        borrow.borrow.*.sites.subject.*.task,
        .{ .placement = .{ .move = .{
            .operation = .{ .bytes = "queued-work" },
            .subject = .{ .work = borrow.borrow.*.work.work_ref.* },
            .site = .{ .bytes = "destination" },
            .custody_epoch = 0,
        } } },
    );
    try std.testing.expectEqual(.observed, queued_move.disposition);
    return placementQueuedCutAuthority(scenario, .{
        .prior = &borrow,
    });
}

fn placementPendingCancellationWitness(comptime scenario: anytype, borrow: anytype) !void {
    if (!(scenario == .cancel_abort or scenario == .cancel_refused)) return;
    var cleanup_builder = source.Builder.init(borrow.borrow.*.setup.a.*);
    defer cleanup_builder.deinit();
    const cleanup_document = try native.source_records.encode(
        borrow.borrow.*.namespaces.scratch.*,
        try @import("workspace_sources.zig").yieldingCancellation(&cleanup_builder),
    );
    const cleanup_program = try borrow.borrow.*.services.sender.*.workspaceBuild(
        borrow.borrow.*.namespaces.scratch.*,
        "restored-cleanup-program",
        borrow.borrow.*.sites.subject.*.task,
        cleanup_document,
        &borrow.borrow.*.child.diagnostic.*,
    );
    try borrow.borrow.*.services.sender.*.park(borrow.borrow.*.namespaces.scratch.*);
    for (0..2) |parked| {
        if (try placementCancelledChildWitness(scenario, .{
            .borrow = &borrow,
            .cleanup_program = &cleanup_program,
            .parked = &parked,
        })) break;
    }
    for (0..2) |parked| {
        if (try placementCancelledRootWitness(scenario, .{
            .borrow = &borrow,
            .parked = &parked,
        })) break;
    }
}

fn placementCheckCapabilities(comptime scenario: anytype, borrow: anytype) !void {
    const identified = try borrow.services.sender.*.placementRequest(
        borrow.namespaces.scratch.*,
        .{ .identify = .{} },
    );
    try std.testing.expect(identified == .object);
    const sites = try borrow.services.sender.*.workspaceCommand(
        borrow.namespaces.scratch.*,
        "placement-sites",
        borrow.sites.subject.*.task,
        .{ .placement = .{ .sites = .{} } },
    );
    try std.testing.expectEqual(.observed, sites.disposition);
    const sites_head = borrow.namespaces.source_namespace.*.store.head;
    const sites_replay = try borrow.services.sender.*.workspaceCommand(
        borrow.namespaces.scratch.*,
        "placement-sites",
        borrow.sites.subject.*.task,
        .{ .placement = .{ .sites = .{} } },
    );
    try std.testing.expectEqualStrings(
        sites.observation_json.bytes,
        sites_replay.observation_json.bytes,
    );
    try std.testing.expectEqualDeep(sites_head, borrow.namespaces.source_namespace.*.store.head);
    // Withdrawal before publication closes the queued move without transferring
    // authority or leaving an unsettled record that blocks later root movement.
    borrow.peers.source_peers.*[0].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "source",
    };
    return placementQueueExecutor(scenario, .{
        .state = .{
            .sites = &sites,
        },
        .prior = &borrow,
    });
}

fn placementPrepareExecutorObserver(comptime scenario: anytype, borrow: anytype) !void {
    const executor_observer: ?contracts.workspace.Expected = if (scenario == .preoffer) blk: {
        const observed_source = try borrow.services.sender.*.workspaceStart(
            borrow.namespaces.scratch.*,
            "executor-observer-source",
            borrow.sites.subject.*.task,
            borrow.child.selected_program.*,
            borrow.input.input.*,
            .{},
        );
        break :blk try placementObserver(
            &borrow.services.sender.*,
            borrow.namespaces.scratch.*,
            borrow.sites.subject.*.task,
            borrow.child.selected_program.*,
            observed_source.receipt.workspace.?,
            false,
        );
    } else null;

    return placementFinishExecutorObserver(scenario, .{
        .state = .{
            .executor_observer = &executor_observer,
        },
        .prior = &borrow,
    });
}

fn placementFreezeChild(comptime scenario: anytype, borrow: anytype) !void {
    if (scenario == .work) {
        borrow.setup.phase.* = "suspend controller before child freeze";
        std.debug.print("semantic placement: suspend controller at {d}ms\n", .{
            sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
        });
        var controller = try borrow.services.sender.*.task(
            borrow.namespaces.scratch.*,
            borrow.sites.subject.*.task,
        );
        defer controller.deinit();
        _ = try borrow.services.sender.*.resumeTask(
            borrow.namespaces.scratch.*,
            "resume-controller-before-child-freeze",
            borrow.sites.subject.*.task,
            controller.value.revision,
        );
        try std.testing.expectEqual(
            .progressed,
            try borrow.services.sender.*.pump(borrow.namespaces.scratch.*),
        );
        try std.testing.expect(borrow.services.sender.*.active != null);
        try std.testing.expect(borrow.services.sender.*.active.?.subject == .root);
        try std.testing.expect(borrow.services.sender.*.active.?.root_control != null);
    }
    if (scenario == .work) std.debug.print("semantic placement: freeze child at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    _ = try freezePlacement(
        &borrow.services.sender.*,
        borrow.sites.subject.*,
        "destination",
        borrow.sites.cut.*,
        @splat(14),
    );
    return placementFreezeAuthority(scenario, .{
        .prior = &borrow,
    });
}

fn placementAbortedChildCancellation(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    if (!(scenario == .cancel_abort or scenario == .cancel_refused)) return false;
    var refused: ?p.Signed(p.Decision) = null;
    if (scenario == .cancel_refused) {
        const refused_path = try std.fmt.allocPrint(
            borrow.borrow.*.namespaces.scratch.*,
            "{s}/refused.par",
            .{
                borrow.borrow.*.namespaces.path_buffer.*[0..borrow.borrow.*.namespaces.length.*],
            },
        );
        const refused_offer = try offerPlacement(
            &borrow.borrow.*.services.sender.*,
            borrow.borrow.*.sites.subject.*,
            "destination",
            refused_path,
        );
        refused = try p.sign(
            p.Decision,
            borrow.borrow.*.namespaces.scratch.*,
            borrow.borrow.*.sites.destination_key.*,
            .{
                .transfer = refused_offer.value.intent.transfer,
                .offer_digest = try p.digest(
                    p.Offer,
                    borrow.borrow.*.namespaces.scratch.*,
                    refused_offer.value,
                ),
                .source = borrow.borrow.*.sites.source_site.*,
                .destination = borrow.borrow.*.sites.destination_site.*,
                .epoch = refused_offer.value.intent.epoch + 1,
                .verdict = .{
                    .refused = .withdrawn,
                },
            },
        );
    }
    borrow.borrow.*.services.sender.*.profile.semantic_construction = null;
    _ = try borrow.borrow.*.services.sender.*.requestCancel(
        borrow.borrow.*.namespaces.scratch.*,
        "cancel-with-frozen-work",
        borrow.borrow.*.sites.subject.*.task,
        "stop",
    );
    var terminal = false;
    return placementAwaitAbortedChild(scenario, .{
        .state = .{
            .refused = &refused,
            .terminal = &terminal,
        },
        .prior = &borrow,
    });
}

fn placementCheckDisclosedOffer(comptime scenario: anytype, borrow: anytype) !void {
    const archive_path = try std.fmt.allocPrint(borrow.namespaces.scratch.*, "{s}/transfer.par", .{
        borrow.namespaces.path_buffer.*[0..borrow.namespaces.length.*],
    });
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.services.sender.*.profile.authority;
        defer borrow.services.sender.*.profile.authority = authority;
        const before = borrow.namespaces.source_namespace.*.store.head;
        @field(borrow.services.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            offerPlacement(
                &borrow.services.sender.*,
                borrow.sites.subject.*,
                "destination",
                archive_path,
            ),
        );
        try std.testing.expectEqualDeep(before, borrow.namespaces.source_namespace.*.store.head);
    }
    // Leave the complete file without a published offer, as an interrupted
    // writer can. The retry must validate and durably reuse that exact file.
    borrow.disclosure.disclosure.*.deny_runtime = true;
    if (scenario == .work) std.debug.print("semantic placement: denied runtime offer at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    try std.testing.expectError(
        error.DisclosureDenied,
        offerPlacement(
            &borrow.services.sender.*,
            borrow.sites.subject.*,
            "destination",
            archive_path,
        ),
    );
    return placementCheckDisclosedGrant(scenario, .{
        .state = .{
            .archive_path = &archive_path,
        },
        .prior = &borrow,
    });
}

fn placementInspectOffer(comptime scenario: anytype, borrow: anytype) !void {
    const offer = try offerPlacement(
        &borrow.services.sender.*,
        borrow.sites.subject.*,
        "destination",
        borrow.offered.archive_path.*,
    );
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.services.sender.*.profile.authority;
        defer borrow.services.sender.*.profile.authority = authority;
        const before = borrow.namespaces.source_namespace.*.store.head;
        @field(borrow.services.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            offerPlacement(
                &borrow.services.sender.*,
                borrow.sites.subject.*,
                "destination",
                borrow.offered.archive_path.*,
            ),
        );
        try std.testing.expectEqualDeep(before, borrow.namespaces.source_namespace.*.store.head);
    }
    try std.testing.expect(borrow.disclosure.disclosure.*.saw_runtime);
    borrow.disclosure.disclosure.*.deny_runtime = true;
    try std.testing.expectError(
        error.DisclosureDenied,
        offerPlacement(
            &borrow.services.sender.*,
            borrow.sites.subject.*,
            "destination",
            borrow.offered.archive_path.*,
        ),
    );
    borrow.disclosure.disclosure.*.deny_runtime = false;
    return placementInspectOfferIdentity(scenario, .{
        .state = .{
            .offer = &offer,
        },
        .prior = &borrow,
    });
}

fn placementOpenReceiver(comptime scenario: anytype, borrow: anytype) !void {
    const state_receiver_compiler_facts = &borrow.services.receiver_compiler_facts;
    const state_compiler_facts = &borrow.services.receiver.*.compiler_facts;

    const p = native.placement;
    borrow.setup.phase.* = "accept child";
    if (scenario == .work) std.debug.print("semantic placement: accept child at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    borrow.namespaces.destination_open.* = true;
    var resumed_profile = borrow.application.profile.*;
    resumed_profile.placement = &borrow.channels.destination_config.*;
    borrow.services.receiver.* = try native.tasks.Service(OwnerTypes).init(
        borrow.setup.a.*,
        borrow.setup.io.*,
        &borrow.namespaces.destination_namespace.*,
        borrow.application.assets.*,
        &borrow.application.application.*,
        borrow.application.handlers.*,
        resumed_profile,
    );
    borrow.services.receiver_open.* = true;
    if (scenario == .work) state_compiler_facts.* = &state_receiver_compiler_facts.*.*;
    // Refusing one transfer is durable history, not task occupancy.
    var unrelated_offer = borrow.transfer.offer.*.value;
    unrelated_offer.intent.transfer = @splat(99);
    const unrelated_signed = try p.sign(
        p.Offer,
        borrow.namespaces.scratch.*,
        borrow.sites.source_key.*,
        unrelated_offer,
    );
    const prior_refusal = try borrow.services.receiver.*.placementRefuse(
        borrow.namespaces.scratch.*,
        "source",
        unrelated_signed,
        .withdrawn,
    );
    try std.testing.expect(prior_refusal.value.verdict == .refused);
    const receiver_head = borrow.namespaces.destination_namespace.*.store.head;
    borrow.services.receiver.*.profile.authority.disclosure = false;
    return placementRejectReceiverReplay(scenario, .{
        .state = .{
            .prior_refusal = &prior_refusal,
            .receiver_head = &receiver_head,
            .resumed_profile = &resumed_profile,
            .unrelated_signed = &unrelated_signed,
        },
        .prior = &borrow,
    });
}

fn placementAcceptChild(comptime scenario: anytype, borrow: anytype) !void {
    const accepted = try acceptPlacement(
        &borrow.services.receiver.*,
        "accept",
        "source",
        borrow.transfer.offer.*,
        borrow.offered.archive_path.*,
    );
    try std.testing.expectEqual(.accepted, accepted.value.verdict);
    if (scenario == .work) std.debug.print("semantic placement: child accepted at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    try std.testing.expectEqualDeep(
        borrow.receiver.prior_refusal.*,
        try borrow.services.receiver.*.placementRefuse(
            borrow.namespaces.scratch.*,
            "source",
            borrow.receiver.unrelated_signed.*,
            .withdrawn,
        ),
    );
    try std.testing.expectEqualDeep(
        accepted,
        try acceptPlacement(
            &borrow.services.receiver.*,
            "accept-again",
            "source",
            borrow.transfer.offer.*,
            borrow.offered.archive_path.*,
        ),
    );
    return placementInspectAcceptedChild(scenario, .{
        .state = .{
            .accepted = &accepted,
        },
        .prior = &borrow,
    });
}

fn placementInspectImportedWork(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var imported_work = try borrow.services.receiver.*.workspaceWork(
        borrow.setup.a.*,
        borrow.sites.subject.*.task,
        borrow.work.work_id.*,
    );
    defer imported_work.deinit();
    try std.testing.expectEqualDeep(
        borrow.sites.cut.*.outer,
        p.ObjectIdentity.optional(imported_work.value.outer_operation.?.capsule),
    );
    try std.testing.expectEqualDeep(
        borrow.sites.cut.*.checkpoint,
        p.ObjectIdentity.from(imported_work.value.checkpoint),
    );
    try std.testing.expectEqualDeep(
        borrow.sites.cut.*.runtime,
        p.ObjectIdentity.optional(imported_work.value.runtime),
    );

    try placementImportedRuntimeWitness(scenario, .{
        .borrow = &borrow,
    });

    return placementContinueImportedWork(scenario, .{
        .imported = .{
            .imported_work = &imported_work,
        },
        .acceptance = borrow.acceptance,
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .disclosure = borrow.disclosure,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .receiver = borrow.receiver,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .work = borrow.work,
    });
}

fn placementContinueImportedWork(comptime scenario: anytype, borrow: anytype) !void {
    borrow.setup.phase.* = "continue imported evaluator";
    _ = try borrow.services.receiver.*.workspacePump(
        borrow.namespaces.scratch.*,
        "continue-outer",
        borrow.sites.subject.*.task,
        .{
            .expected = .{
                .work = borrow.work.work_ref.*,
                .execution_revision = borrow.imported.imported_work.*.value.execution_revision,
                .control_revision = borrow.imported.imported_work.*.value.control_revision,
            },
            .base_quantum = 1,
        },
    );
    var continued = try borrow.services.receiver.*.workspaceWork(
        borrow.setup.a.*,
        borrow.sites.subject.*.task,
        borrow.work.work_id.*,
    );
    defer continued.deinit();
    try std.testing.expect(
        !std.meta.eql(
            continued.value.outer_operation.?.capsule,
            borrow.imported.imported_work.*.value.outer_operation.?.capsule,
        ),
    );
    try std.testing.expectEqual(
        borrow.imported.imported_work.*.value.execution_revision,
        continued.value.execution_revision,
    );
    if (scenario == .work) std.debug.print(
        "semantic placement: cold restart continued at {d}ms\n",
        .{
            sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
        },
    );
    try borrow.services.receiver.*.close(borrow.setup.a.*);
    borrow.services.receiver_open.* = false;
    try borrow.namespaces.destination_namespace.*.close();
    borrow.namespaces.destination_open.* = false;
    borrow.namespaces.source_namespace.* = try native.Namespace.open(
        borrow.setup.a.*,
        borrow.setup.io.*,
        borrow.namespaces.source_path.*,
    );
    borrow.namespaces.source_open.* = true;
    return placementReopenController(scenario, .{
        .acceptance = borrow.acceptance,
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .disclosure = borrow.disclosure,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .receiver = borrow.receiver,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .work = borrow.work,
    });
}

fn placementReopenController(comptime scenario: anytype, borrow: anytype) !void {
    var source_profile = borrow.application.profile.*;
    source_profile.placement = &borrow.channels.source_config.*;
    borrow.services.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.setup.a.*,
        borrow.setup.io.*,
        &borrow.namespaces.source_namespace.*,
        borrow.application.assets.*,
        &borrow.application.application.*,
        borrow.application.handlers.*,
        source_profile,
    );
    borrow.services.sender_open.* = true;
    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.services.sender.*.workspaceControl(
            borrow.namespaces.scratch.*,
            "lost-ack",
            borrow.sites.subject.*.task,
            borrow.work.work_id.*,
            borrow.sites.cut.*.execution,
            borrow.sites.cut.*.control,
            .advance,
        ),
    );
    return placementControllerAuthority(scenario, .{
        .state = .{
            .source_profile = &source_profile,
        },
        .prior = &borrow,
    });
}

fn placementInspectRemoteController(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    borrow.setup.phase.* = "remote controller inspection";
    const control_bytes = try borrow.services.sender.*.placementControl(
        borrow.namespaces.scratch.*,
        "remote-inspect",
        borrow.sites.subject.*.task,
        .{ .inspect = .{
            .work = borrow.work.work_ref.*,
        } },
    );
    var control = try contracts.decodeOwned(
        p.Signed(p.Control),
        borrow.namespaces.scratch.*,
        control_bytes,
    );
    defer control.deinit();
    try std.testing.expectEqualSlices(
        u8,
        control_bytes,
        try borrow.services.sender.*.placementControl(
            borrow.namespaces.scratch.*,
            "remote-inspect",
            borrow.sites.subject.*.task,
            .{ .inspect = .{
                .work = borrow.work.work_ref.*,
            } },
        ),
    );
    return placementRemoteControllerAuthority(scenario, .{
        .state = .{
            .control = &control,
        },
        .prior = &borrow,
    });
}

fn placementAdvanceController(comptime scenario: anytype, borrow: anytype) !void {
    borrow.setup.phase.* = "advance controller after export";
    _ = try borrow.services.sender.*.resumeTask(
        borrow.namespaces.scratch.*,
        "advance-controller-after-export",
        borrow.sites.subject.*.task,
        borrow.report.controller_cut.*.control,
    );
    var advanced_controller = borrow.report.controller_cut.*;
    for (0..64) |_| {
        _ = try borrow.services.sender.*.pump(borrow.namespaces.scratch.*);
        advanced_controller = try borrow.services.sender.*.placementCut(
            borrow.namespaces.scratch.*,
            borrow.report.controller_subject.*,
        );
        if (advanced_controller.execution > borrow.report.controller_cut.*.execution) break;
    }
    try std.testing.expect(
        advanced_controller.execution > borrow.report.controller_cut.*.execution,
    );
    try std.testing.expect(
        !std.meta.eql(borrow.report.controller_cut.*.checkpoint, advanced_controller.checkpoint),
    );
    return placementPrepareControllerTransfer(scenario, .{
        .advanced = .{
            .advanced_controller = &advanced_controller,
        },
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .controller = borrow.controller,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .receiver = borrow.receiver,
        .report = borrow.report,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .work = borrow.work,
    });
}

fn placementPrepareControllerTransfer(comptime scenario: anytype, borrow: anytype) !void {
    const sender = borrow.services.sender;

    borrow.setup.phase.* = "prepare observer for controller transfer";
    const observed_source = try borrow.services.sender.*.workspaceStart(
        borrow.namespaces.scratch.*,
        "placement-terminal-source",
        borrow.sites.subject.*.task,
        borrow.child.program.*.receipt.workspace.?,
        &.{
            0,
        },
        .{},
    );
    try observerCompleted(
        &borrow.services.sender.*,
        borrow.namespaces.scratch.*,
        borrow.sites.subject.*.task,
        observed_source.receipt.workspace.?,
    );
    const remote_observer = try placementObserver(
        &borrow.services.sender.*,
        borrow.namespaces.scratch.*,
        borrow.sites.subject.*.task,
        borrow.child.program.*.receipt.workspace.?,
        observed_source.receipt.workspace.?,
        false,
    );
    borrow.advanced.advanced_controller.* = try borrow.services.sender.*.placementCut(
        borrow.namespaces.scratch.*,
        borrow.report.controller_subject.*,
    );
    borrow.peers.source_peers.*[1].compatibility = try sender.placementCompatibility(
        borrow.namespaces.scratch.*,
        borrow.report.controller_subject.*,
    );
    borrow.peers.successor_peers.*[1].compatibility = borrow.peers.source_peers.*[1].compatibility;
    borrow.setup.phase.* = "transfer controller";
    if (scenario == .work) std.debug.print("semantic placement: transfer controller at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    _ = try freezePlacement(
        &borrow.services.sender.*,
        borrow.report.controller_subject.*,
        "successor",
        borrow.advanced.advanced_controller.*,
        @splat(16),
    );
    return placementOfferController(scenario, .{
        .observer = .{
            .remote_observer = &remote_observer,
        },
        .advanced = borrow.advanced,
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .controller = borrow.controller,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .peers = borrow.peers,
        .receiver = borrow.receiver,
        .report = borrow.report,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .work = borrow.work,
    });
}

fn placementOfferController(comptime scenario: anytype, borrow: anytype) !void {
    const controller_archive = try std.fmt.allocPrint(
        borrow.namespaces.scratch.*,
        "{s}/controller.par",
        .{
            borrow.namespaces.path_buffer.*[0..borrow.namespaces.length.*],
        },
    );
    const controller_offer = try offerPlacement(
        &borrow.services.sender.*,
        borrow.report.controller_subject.*,
        "successor",
        controller_archive,
    );
    try borrow.services.sender.*.close(borrow.setup.a.*);
    borrow.services.sender_open.* = false;
    borrow.services.controller_compiler_facts.*.deinit();
    borrow.services.controller_compiler_facts.* = .{ .allocator = borrow.setup.a.* };
    try borrow.namespaces.source_namespace.*.close();
    borrow.namespaces.source_open.* = false;
    return placementAcceptController(scenario, .{
        .controller_offer = .{
            .controller_archive = &controller_archive,
            .controller_offer = &controller_offer,
        },
        .advanced = borrow.advanced,
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .controller = borrow.controller,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .observer = borrow.observer,
        .peers = borrow.peers,
        .receiver = borrow.receiver,
        .report = borrow.report,
        .services = borrow.services,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .work = borrow.work,
    });
}

fn placementAcceptController(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var controller_decision: p.Signed(p.Decision) = undefined;
    var successor_control: contracts.Decoded(p.Signed(p.Control)) = undefined;

    try placementControllerAdmission(scenario, .{
        .borrow = &borrow,
        .controller_decision = &controller_decision,
        .successor_control = &successor_control,
    });

    if (scenario == .work) std.debug.print("semantic placement: controller accepted at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    defer successor_control.deinit();
    {
        var retained_namespace = try native.Namespace.open(
            borrow.setup.a.*,
            borrow.setup.io.*,
            borrow.namespaces.source_path.*,
        );
        defer support.expectCleanup(retained_namespace.close());
        var retained_owner = try native.tasks.Service(OwnerTypes).init(
            borrow.setup.a.*,
            borrow.setup.io.*,
            &retained_namespace,
            borrow.application.assets.*,
            &borrow.application.application.*,
            borrow.application.handlers.*,
            borrow.controller.source_profile.*,
        );
        defer support.expectCleanup(retained_owner.close(borrow.setup.a.*));
        try retained_owner.placementApplyDecision(
            borrow.namespaces.scratch.*,
            borrow.report.controller_subject.*,
            controller_decision,
        );
    }
    return placementReopenAcceptedController(scenario, .{
        .state = .{
            .controller_decision = &controller_decision,
            .successor_control = &successor_control,
        },
        .prior = &borrow,
    });
}

fn placementRejectStaleControl(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var stale_control = borrow.report.control.*.value.value;
    stale_control.operation = .{ .bytes = "late-old-controller" };
    try std.testing.expectError(
        error.StaleController,
        borrow.services.receiver.*.placementExecuteControl(
            borrow.namespaces.scratch.*,
            "source",
            try p.sign(
                p.Control,
                borrow.namespaces.scratch.*,
                borrow.sites.source_key.*,
                stale_control,
            ),
        ),
    );
    const successor_report_bytes = try borrow.services.receiver.*.placementExecuteControl(
        borrow.namespaces.scratch.*,
        "successor",
        borrow.controller_acceptance.successor_control.*.value,
    );
    var successor_report = try contracts.decodeOwned(
        p.Signed(p.Report),
        borrow.namespaces.scratch.*,
        successor_report_bytes,
    );
    defer successor_report.deinit();
    try std.testing.expectEqual(.observed, successor_report.value.value.reply.disposition);
    try std.testing.expect(successor_report.value.value.work_state != null);
    try borrow.services.receiver.*.close(borrow.setup.a.*);
    borrow.services.receiver_open.* = false;
    try borrow.namespaces.destination_namespace.*.close();
    borrow.namespaces.destination_open.* = false;
    // Exercise the automatic parent-cancellation decision with real stores and
    // signed messages. This fixture carries the queued bytes between namespace
    // owners; the separate process fixture owns transport qualification.
    borrow.peers.successor_peers.*[0].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "successor",
    };
    borrow.peers.successor_peers.*[1].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "successor",
    };
    return placementDisposeRemoteWork(scenario, .{
        .successor_report = .{
            .successor_report = &successor_report,
        },
        .application = borrow.application,
        .channels = borrow.channels,
        .child = borrow.child,
        .controller = borrow.controller,
        .controller_acceptance = borrow.controller_acceptance,
        .generated = borrow.generated,
        .namespaces = borrow.namespaces,
        .observer = borrow.observer,
        .receiver = borrow.receiver,
        .setup = borrow.setup,
        .sites = borrow.sites,
        .work = borrow.work,
    });
}

fn placementDisposeRemoteWork(comptime scenario: anytype, borrow: anytype) !void {
    var cleanup_control = borrow.controller_acceptance.successor_control.*.value;
    var cleanup_report = borrow.successor_report.successor_report.*.value;
    var disposed = false;
    var parked_once = false;
    var observer_stopped = false;
    var resumed_after_park = false;
    borrow.setup.phase.* = "cancel remote work and observer";
    if (scenario == .work) std.debug.print("semantic placement: remote cleanup at {d}ms\n", .{
        sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
    });
    for (0..512) |iteration| {
        if (try placementRemoteDisposalTurn(scenario, .{
            .borrow = &borrow,
            .cleanup_control = &cleanup_control,
            .cleanup_report = &cleanup_report,
            .disposed = &disposed,
            .iteration = &iteration,
            .observer_stopped = &observer_stopped,
            .parked_once = &parked_once,
            .resumed_after_park = &resumed_after_park,
        })) break;
    }
    borrow.setup.phase.* = "verify remote disposal completion";
    try std.testing.expect(disposed);
    if (scenario == .work) std.debug.print(
        "semantic placement: remote cleanup completed at {d}ms\n",
        .{
            sharedElapsed(borrow.setup.placement_started.*) / std.time.ns_per_ms,
        },
    );
    borrow.setup.phase.* = "verify remote park and resume";
    try std.testing.expect(parked_once and resumed_after_park);
    borrow.setup.phase.* = "verify remote observer stopped";
    try std.testing.expect(observer_stopped);
}

fn placementIdentifyNamespaces(comptime scenario: anytype, borrow: anytype) !void {
    var successor_namespace = try native.Namespace.open(
        borrow.setup.a.*,
        borrow.setup.io.*,
        borrow.paths.successor_path.*,
    );
    const successor_identity = successor_namespace.identity;
    try successor_namespace.close();
    var destination_namespace = try native.Namespace.open(
        borrow.setup.a.*,
        borrow.setup.io.*,
        borrow.paths.destination_path.*,
    );
    const destination_identity = destination_namespace.identity;
    try destination_namespace.close();
    var destination_open = false;
    defer if (destination_open) support.expectCleanup(destination_namespace.close());
    var source_namespace = try native.Namespace.open(
        borrow.setup.a.*,
        borrow.setup.io.*,
        borrow.paths.source_path.*,
    );
    var source_open = true;
    defer if (source_open) support.expectCleanup(source_namespace.close());
    return placementOpenServices(scenario, .{
        .namespaces = .{
            .destination_identity = &destination_identity,
            .destination_namespace = &destination_namespace,
            .destination_open = &destination_open,
            .destination_path = &borrow.paths.destination_path.*,
            .length = &borrow.paths.length.*,
            .path_buffer = &borrow.paths.path_buffer.*,
            .scratch = &borrow.paths.scratch.*,
            .source_namespace = &source_namespace,
            .source_open = &source_open,
            .source_path = &borrow.paths.source_path.*,
            .successor_identity = &successor_identity,
            .successor_namespace = &successor_namespace,
            .successor_path = &borrow.paths.successor_path.*,
            .untrusted_namespaces = &borrow.paths.untrusted_namespaces.*,
        },
        .application = borrow.application,
        .setup = borrow.setup,
    });
}

fn placementMoveAckExecutor(comptime scenario: anytype, borrow: anytype) !bool {
    try placementRemoteAcknowledgement(scenario, .{
        .borrow = &borrow,
    });

    _ = try borrow.fixture.sender.*.requestCancel(
        borrow.fixture.scratch.*,
        "ack-parent-cancel",
        borrow.fixture.subject.*.task,
        "stop",
    );
    return placementParkAckExecutor(scenario, .{
        .ack = borrow.ack,
        .fixture = borrow.fixture,
    });
}

fn placementParkAckExecutor(comptime scenario: anytype, borrow: anytype) !bool {
    try placementAcknowledgementParking(scenario, .{
        .borrow = &borrow,
    });

    return placementMoveAckController(scenario, .{
        .ack = borrow.ack,
        .fixture = borrow.fixture,
    });
}

fn placementMoveAckController(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    var parent_before_move = try borrow.fixture.sender.*.task(
        borrow.fixture.scratch.*,
        borrow.fixture.subject.*.task,
    );
    defer parent_before_move.deinit();
    try std.testing.expect(!parent_before_move.value.terminal());
    const controller: p.Subject = .{ .task = borrow.fixture.subject.*.task };
    _ = try freezePlacement(
        &borrow.fixture.sender.*,
        controller,
        "successor",
        try borrow.fixture.sender.*.placementCut(borrow.fixture.scratch.*, controller),
        @splat(75),
    );
    const controller_archive = try std.fmt.allocPrint(
        borrow.fixture.scratch.*,
        "{s}/ack-controller.par",
        .{
            borrow.fixture.path_buffer.*[0..borrow.fixture.length.*],
        },
    );
    const controller_offer = try offerPlacement(
        &borrow.fixture.sender.*,
        controller,
        "successor",
        controller_archive,
    );
    try borrow.fixture.sender.*.close(borrow.fixture.a.*);
    borrow.fixture.sender_open.* = false;
    try borrow.fixture.source_namespace.*.close();
    borrow.fixture.source_open.* = false;
    return placementInspectAckController(scenario, .{
        .offered = .{
            .controller = &controller,
            .controller_archive = &controller_archive,
            .controller_offer = &controller_offer,
            .parent_before_move = &parent_before_move,
        },
        .ack = borrow.ack,
        .fixture = borrow.fixture,
    });
}

fn placementInspectAckController(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    var decision: p.Signed(p.Decision) = undefined;
    var inspection: p.Signed(p.Control) = undefined;

    try placementAckSuccessorAdmission(scenario, .{
        .borrow = &borrow,
        .decision = &decision,
        .inspection = &inspection,
    });

    try placementAckFormerAdmission(scenario, .{
        .borrow = &borrow,
        .decision = &decision,
    });

    var inspection_report: p.Signed(p.Report) = undefined;

    try placementAckExecutorInspection(scenario, .{
        .borrow = &borrow,
        .decision = &decision,
        .inspection = &inspection,
        .inspection_report = &inspection_report,
    });

    borrow.fixture.successor_peers.*[if (scenario == .local_ack) 1 else 0].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "successor",
    };

    try placementAckSuccessorReport(scenario, .{
        .borrow = &borrow,
        .inspection = &inspection,
        .inspection_report = &inspection_report,
    });

    return true;
}

fn placementDisposeFrozenChild(comptime scenario: anytype, borrow: anytype) !bool {
    var child_disposed = false;
    for (0..512) |_| {
        _ = try borrow.fixture.sender.*.pump(borrow.fixture.scratch.*);
        var current = try borrow.fixture.sender.*.workspaceWork(
            borrow.fixture.scratch.*,
            borrow.fixture.subject.*.task,
            borrow.fixture.work_id.*,
        );
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            child_disposed = true;
            break;
        }
    }
    try std.testing.expect(child_disposed);
    try std.testing.expectEqual(
        .frozen,
        (try borrow.fixture.sender.*.placementStatus(
            borrow.fixture.scratch.*,
            borrow.frozen.controller.*,
        )).?.phase,
    );
    try std.testing.expectEqual(@as(usize, 1), borrow.fixture.sender.*.owned.items.len);
    try std.testing.expect(
        try borrow.fixture.sender.*.shutdownIncomplete(borrow.fixture.scratch.*),
    );
    if (borrow.frozen.refusal.*) |decision| try borrow.fixture.sender.*.placementApplyDecision(
        borrow.fixture.scratch.*,
        borrow.frozen.controller.*,
        decision,
    ) else try borrow.fixture.sender.*.placementAbortUnsent(
        borrow.fixture.scratch.*,
        borrow.frozen.controller.*,
        @splat(71),
    );
    var root_disposed = false;
    for (0..512) |_| {
        _ = try borrow.fixture.sender.*.pump(borrow.fixture.scratch.*);
        var current = try borrow.fixture.sender.*.task(
            borrow.fixture.scratch.*,
            borrow.fixture.subject.*.task,
        );
        defer current.deinit();
        if (try borrow.fixture.sender.*.taskCleanupComplete(
            borrow.fixture.scratch.*,
            current.value,
        )) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            root_disposed = true;
            break;
        }
    }
    try std.testing.expect(root_disposed);
    try std.testing.expect(
        !try borrow.fixture.sender.*.shutdownIncomplete(borrow.fixture.scratch.*),
    );
    return placementFrozenShutdown(scenario, .{
        .fixture = borrow.fixture,
        .frozen = borrow.frozen,
    });
}

fn placementFrozenShutdown(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    borrow.fixture.phase.* = "cancel shutdown observes a restored uncancelled controller";
    const shutdown_root = try borrow.fixture.sender.*.submit(
        borrow.fixture.scratch.*,
        "shutdown-controller",
        .{ 25, 5 },
    );
    const shutdown_subject: p.Subject = .{ .task = shutdown_root.receipt.task };
    _ = try freezePlacement(
        &borrow.fixture.sender.*,
        shutdown_subject,
        "destination",
        try borrow.fixture.sender.*.placementCut(borrow.fixture.scratch.*, shutdown_subject),
        @splat(72),
    );
    borrow.frozen.refusal.* = null;

    try placementRefuseFrozenShutdown(scenario, .{
        .borrow = &borrow,
        .shutdown_subject = &shutdown_subject,
    });

    try borrow.fixture.sender.*.cancelOwned(borrow.fixture.scratch.*, "shutdown-probe", "stop");
    try std.testing.expect(
        try borrow.fixture.sender.*.shutdownIncomplete(borrow.fixture.scratch.*),
    );
    if (borrow.frozen.refusal.*) |decision| try borrow.fixture.sender.*.placementApplyDecision(
        borrow.fixture.scratch.*,
        shutdown_subject,
        decision,
    ) else try borrow.fixture.sender.*.placementAbortUnsent(
        borrow.fixture.scratch.*,
        shutdown_subject,
        @splat(72),
    );
    try borrow.fixture.sender.*.park(borrow.fixture.scratch.*);
    var parked = try borrow.fixture.sender.*.task(borrow.fixture.scratch.*, shutdown_subject.task);
    defer parked.deinit();
    try std.testing.expect(!parked.value.terminal());
    try std.testing.expect(parked.value.cancellation == null);
    try std.testing.expectEqual(.parked, parked.value.schedule);
    try std.testing.expect(
        try borrow.fixture.sender.*.shutdownIncomplete(borrow.fixture.scratch.*),
    );
    return true;
}

fn placementReplayFrozenBuild(comptime scenario: anytype, borrow: anytype) !bool {
    const replayed_build = try borrow.fixture.sender.*.workspaceBuild(
        borrow.fixture.scratch.*,
        "build",
        borrow.fixture.parent.*.receipt.task,
        borrow.fixture.document.*,
        &borrow.fixture.diagnostic.*,
    );
    try std.testing.expect(replayed_build.replayed);
    try std.testing.expectEqualDeep(borrow.fixture.program.*.receipt, replayed_build.receipt);
    const replayed_specialization = try borrow.fixture.sender.*.workspaceSpecialize(
        borrow.fixture.scratch.*,
        "specialize",
        borrow.fixture.parent.*.receipt.task,
        borrow.fixture.program.*.receipt.workspace.?,
    );
    try std.testing.expect(replayed_specialization.replayed);
    try std.testing.expectEqualDeep(
        borrow.fixture.specialized.*.?.receipt,
        replayed_specialization.receipt,
    );
    return placementReplayFrozenStart(scenario, .{
        .fixture = borrow.fixture,
        .frozen = borrow.frozen,
    });
}

fn placementReplayFrozenStart(comptime scenario: anytype, borrow: anytype) !bool {
    const replayed_start = try borrow.fixture.sender.*.workspaceCommand(
        borrow.fixture.scratch.*,
        "start",
        borrow.fixture.parent.*.receipt.task,
        borrow.fixture.start_command.*,
    );
    try std.testing.expectEqual(.observed, replayed_start.disposition);
    const replayed_start_value = (try native.json.parseAsset(
        borrow.fixture.scratch.*,
        replayed_start.observation_json.bytes,
        replayed_start.observation_json.bytes.len,
    )).value;
    try std.testing.expect(replayed_start_value.object.get("replayed").?.bool);
    try std.testing.expectEqualDeep(
        borrow.fixture.work_ref.*,
        try native.values.fromJson(
            contracts.workspace.Ref,
            borrow.fixture.scratch.*,
            replayed_start_value.object.get("work").?,
        ),
    );
    const replayed_sites = try borrow.fixture.sender.*.workspaceCommand(
        borrow.fixture.scratch.*,
        "placement-sites",
        borrow.fixture.subject.*.task,
        .{ .placement = .{ .sites = .{} } },
    );
    try std.testing.expectEqual(.observed, replayed_sites.disposition);
    try std.testing.expectEqualStrings(
        borrow.fixture.sites.*.observation_json.bytes,
        replayed_sites.observation_json.bytes,
    );
    return placementRejectFrozenStart(scenario, .{
        .prior = &borrow,
    });
}

fn placementInspectFrozenParent(comptime scenario: anytype, borrow: anytype) !bool {
    var progressed_parent = try borrow.fixture.sender.*.task(
        borrow.fixture.scratch.*,
        borrow.fixture.subject.*.task,
    );
    defer progressed_parent.deinit();
    if (scenario == .root) try std.testing.expect(
        progressed_parent.value.revision > borrow.frozen.controller_cut.*.control,
    );
    return placementOfferFrozenParent(scenario, .{
        .fixture = borrow.fixture,
        .frozen = borrow.frozen,
    });
}

fn placementOfferFrozenParent(comptime scenario: anytype, borrow: anytype) !bool {
    const snapshot_path = try std.fmt.allocPrint(
        borrow.fixture.scratch.*,
        "{s}/frozen-controller.par",
        .{
            borrow.fixture.path_buffer.*[0..borrow.fixture.length.*],
        },
    );
    const snapshot_offer = try offerPlacement(
        &borrow.fixture.sender.*,
        borrow.frozen.controller.*,
        "successor",
        snapshot_path,
    );
    try std.testing.expectEqualDeep(
        borrow.frozen.controller_cut.*,
        snapshot_offer.value.intent.cut,
    );
    try borrow.fixture.sender.*.close(borrow.fixture.a.*);
    borrow.fixture.sender_open.* = false;
    try borrow.fixture.source_namespace.*.close();
    borrow.fixture.source_open.* = false;

    try placementRejectedFrozenPump(scenario, .{
        .borrow = &borrow,
        .snapshot_path = &snapshot_path,
    });

    return placementAcceptFrozenParent(scenario, .{
        .offered = .{
            .snapshot_offer = &snapshot_offer,
            .snapshot_path = &snapshot_path,
        },
        .fixture = borrow.fixture,
        .frozen = borrow.frozen,
    });
}

fn placementAcceptFrozenParent(comptime scenario: anytype, borrow: anytype) !bool {
    var snapshot_namespace = try native.Namespace.open(
        borrow.fixture.a.*,
        borrow.fixture.io.*,
        borrow.fixture.successor_path.*,
    );
    var snapshot_profile = borrow.fixture.profile.*;
    snapshot_profile.placement = &borrow.fixture.successor_config.*;
    var snapshot_receiver = try native.tasks.Service(OwnerTypes).init(
        borrow.fixture.a.*,
        borrow.fixture.io.*,
        &snapshot_namespace,
        borrow.fixture.assets.*,
        &borrow.fixture.application.*,
        borrow.fixture.handlers.*,
        snapshot_profile,
    );
    const decision = try acceptPlacement(
        &snapshot_receiver,
        "accept-frozen-controller",
        "source",
        borrow.offered.snapshot_offer.*,
        borrow.offered.snapshot_path.*,
    );
    try std.testing.expectEqual(
        .local,
        (try snapshot_receiver.placementStatus(
            borrow.fixture.scratch.*,
            borrow.frozen.controller.*,
        )).?.phase,
    );
    try std.testing.expectEqual(
        .away,
        (try snapshot_receiver.placementStatus(
            borrow.fixture.scratch.*,
            borrow.fixture.subject.*,
        )).?.phase,
    );
    try snapshot_receiver.close(borrow.fixture.a.*);
    try snapshot_namespace.close();
    borrow.fixture.source_namespace.* = try native.Namespace.open(
        borrow.fixture.a.*,
        borrow.fixture.io.*,
        borrow.fixture.source_path.*,
    );
    borrow.fixture.source_open.* = true;
    return placementResumeFrozenParent(scenario, .{
        .accepted = .{
            .decision = &decision,
            .snapshot_namespace = &snapshot_namespace,
            .snapshot_profile = &snapshot_profile,
            .snapshot_receiver = &snapshot_receiver,
        },
        .fixture = borrow.fixture,
        .frozen = borrow.frozen,
        .offered = borrow.offered,
    });
}

fn placementResumeFrozenParent(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    var source_profile = borrow.fixture.profile.*;
    source_profile.placement = &borrow.fixture.source_config.*;
    borrow.fixture.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.fixture.a.*,
        borrow.fixture.io.*,
        &borrow.fixture.source_namespace.*,
        borrow.fixture.assets.*,
        &borrow.fixture.application.*,
        borrow.fixture.handlers.*,
        source_profile,
    );
    borrow.fixture.sender_open.* = true;
    try borrow.fixture.sender.*.placementApplyDecision(
        borrow.fixture.scratch.*,
        borrow.frozen.controller.*,
        borrow.accepted.decision.*,
    );
    try std.testing.expectEqual(
        @as(@FieldType(p.Custody, "phase"), if (scenario == .root) .local else .frozen),
        (try borrow.fixture.sender.*.placementStatus(
            borrow.fixture.scratch.*,
            borrow.fixture.subject.*,
        )).?.phase,
    );

    try placementRootCompletionWitness(scenario, .{
        .borrow = &borrow,
        .source_profile = &source_profile,
    });

    try placementPreofferWitness(scenario, .{
        .borrow = &borrow,
        .source_profile = &source_profile,
    });

    return true;
}

fn placementRootCompletionWitness(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (!(scenario == .root)) return;
    borrow.borrow.*.fixture.phase.* = "normal controller completion parks the retained executor";
    var running_child = try borrow.borrow.*.fixture.sender.*.workspaceWork(
        borrow.borrow.*.fixture.scratch.*,
        borrow.borrow.*.fixture.subject.*.task,
        borrow.borrow.*.fixture.work_id.*,
    );
    defer running_child.deinit();
    try std.testing.expectEqual(.queued, running_child.value.schedule);
    try borrow.borrow.*.fixture.sender.*.close(borrow.borrow.*.fixture.a.*);
    borrow.borrow.*.fixture.sender_open.* = false;
    try borrow.borrow.*.fixture.source_namespace.*.close();
    borrow.borrow.*.fixture.source_open.* = false;
    borrow.borrow.*.fixture.successor_peers.*[1].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "successor",
    };
    var completed = false;
    var parked = false;
    var incomplete_park = false;
    var refreshed_park = false;
    var inspection_reports: u64 = 0;
    var parked_task_watermark: u64 = 0;
    var prior_command: ?p.Signed(p.Control) = null;
    var prior_report: ?p.Signed(p.Report) = null;
    return placementAwaitRootCompletion(scenario, .{
        .state = .{
            .completed = &completed,
            .incomplete_park = &incomplete_park,
            .inspection_reports = &inspection_reports,
            .parked = &parked,
            .parked_task_watermark = &parked_task_watermark,
            .prior_command = &prior_command,
            .prior_report = &prior_report,
            .refreshed_park = &refreshed_park,
            .running_child = &running_child,
        },
        .prior = &borrow,
    });
}

fn placementPreofferWitness(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (!(scenario == .preoffer)) return;
    const child_path = try std.fmt.allocPrint(
        borrow.borrow.*.fixture.scratch.*,
        "{s}/child-after-controller.par",
        .{
            borrow.borrow.*.fixture.path_buffer.*[0..borrow.borrow.*.fixture.length.*],
        },
    );
    const child_offer = try offerPlacement(
        &borrow.borrow.*.fixture.sender.*,
        borrow.borrow.*.fixture.subject.*,
        "destination",
        child_path,
    );
    try borrow.borrow.*.fixture.sender.*.close(borrow.borrow.*.fixture.a.*);
    borrow.borrow.*.fixture.sender_open.* = false;
    try borrow.borrow.*.fixture.source_namespace.*.close();
    borrow.borrow.*.fixture.source_open.* = false;
    var child_decision: p.Signed(p.Decision) = undefined;
    {
        borrow.borrow.*.fixture.destination_namespace.* = try native.Namespace.open(
            borrow.borrow.*.fixture.a.*,
            borrow.borrow.*.fixture.io.*,
            borrow.borrow.*.fixture.destination_path.*,
        );
        defer support.expectCleanup(borrow.borrow.*.fixture.destination_namespace.*.close());
        var child_profile = borrow.borrow.*.fixture.profile.*;
        child_profile.placement = &borrow.borrow.*.fixture.destination_config.*;
        var child_owner = try native.tasks.Service(OwnerTypes).init(
            borrow.borrow.*.fixture.a.*,
            borrow.borrow.*.fixture.io.*,
            &borrow.borrow.*.fixture.destination_namespace.*,
            borrow.borrow.*.fixture.assets.*,
            &borrow.borrow.*.fixture.application.*,
            borrow.borrow.*.fixture.handlers.*,
            child_profile,
        );
        defer support.expectCleanup(child_owner.close(borrow.borrow.*.fixture.a.*));
        child_decision = try acceptPlacement(
            &child_owner,
            "accept-child-after-controller",
            "source",
            child_offer,
            child_path,
        );
    }
    return placementPreofferResolveChild(scenario, .{
        .child = .{
            .child_decision = &child_decision,
        },
        .borrow = borrow.borrow,
        .source_profile = borrow.source_profile,
    });
}

fn placementAckSuccessorAdmission(comptime scenario: anytype, borrow: anytype) !void {
    _ = scenario;
    const p = native.placement;
    var ns = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        borrow.borrow.*.fixture.successor_path.*,
    );
    defer support.expectCleanup(ns.close());
    var successor = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &ns,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        borrow.borrow.*.ack.ack_successor_profile.*,
    );
    defer support.expectCleanup(successor.close(borrow.borrow.*.fixture.a.*));
    borrow.decision.* = try acceptPlacement(
        &successor,
        "ack-controller",
        "source",
        borrow.borrow.*.offered.controller_offer.*,
        borrow.borrow.*.offered.controller_archive.*,
    );
    borrow.inspection.* = (try contracts.decodeOwned(
        p.Signed(p.Control),
        borrow.borrow.*.fixture.scratch.*,
        try successor.placementControl(
            borrow.borrow.*.fixture.scratch.*,
            "ack-inspect",
            borrow.borrow.*.fixture.subject.*.task,
            .{ .inspect = .{
                .work = borrow.borrow.*.fixture.work_ref.*,
            } },
        ),
    )).value;
}

fn placementAckFormerAdmission(comptime scenario: anytype, borrow: anytype) !void {
    _ = scenario;
    var ns = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        borrow.borrow.*.fixture.source_path.*,
    );
    defer support.expectCleanup(ns.close());
    var former = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &ns,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        borrow.borrow.*.ack.ack_source_profile.*,
    );
    defer support.expectCleanup(former.close(borrow.borrow.*.fixture.a.*));
    try former.placementApplyDecision(
        borrow.borrow.*.fixture.scratch.*,
        borrow.borrow.*.offered.controller.*,
        borrow.decision.*,
    );
}

fn placementAckExecutorInspection(comptime scenario: anytype, borrow: anytype) !void {
    const state_ack_destination_profile = &borrow.borrow.*.ack.ack_destination_profile;
    const state_ack_source_profile = &borrow.borrow.*.ack.ack_source_profile;
    const state_destination_path = &borrow.borrow.*.fixture.destination_path;
    const state_source_path = &borrow.borrow.*.fixture.source_path;

    const p = native.placement;
    var ns = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        if (scenario == .local_ack) state_source_path.*.* else state_destination_path.*.*,
    );
    defer support.expectCleanup(ns.close());
    var executor = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &ns,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        if (scenario == .local_ack)
            state_ack_source_profile.*.*
        else
            state_ack_destination_profile.*.*,
    );
    defer support.expectCleanup(executor.close(borrow.borrow.*.fixture.a.*));
    if (scenario == .remote_ack) try executor.placementFollowController(
        borrow.borrow.*.fixture.scratch.*,
        "source",
        "successor",
        borrow.borrow.*.offered.controller_offer.*,
        borrow.decision.*,
    );
    borrow.inspection_report.* = (try contracts.decodeOwned(
        p.Signed(p.Report),
        borrow.borrow.*.fixture.scratch.*,
        try executor.placementExecuteControl(
            borrow.borrow.*.fixture.scratch.*,
            "successor",
            borrow.inspection.*,
        ),
    )).value;
    try std.testing.expectEqual(.observed, borrow.inspection_report.*.value.reply.disposition);
    try std.testing.expect(borrow.inspection_report.*.value.work_state.?.explicitly_parked);
}

fn placementAckSuccessorReport(comptime scenario: anytype, borrow: anytype) !void {
    try placementAcknowledgedControllerState(scenario, .{
        .borrow = &borrow,
    });
}

fn placementRootCompletionTurn(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    var selected_command: p.Signed(p.Control) = undefined;

    if (try placementRootCloseReport(scenario, .{
        .borrow = &borrow,
        .selected_command = &selected_command,
    })) return true;

    try placementRootCloseExecution(scenario, .{
        .borrow = &borrow,
        .selected_command = &selected_command,
    });

    return false;
}

fn placementRemoteDisposalTurn(comptime scenario: anytype, borrow: anytype) !bool {
    if (try placementRemoteDisposalSchedule(scenario, .{
        .borrow = &borrow,
    })) return true;

    try placementRemoteDisposalExecution(scenario, .{
        .borrow = &borrow,
    });

    return false;
}

fn placementCancelledChildWitness(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.borrow.*.borrow.*.services;
    const sites_view = &borrow.borrow.*.borrow.*.sites;
    borrow.borrow.*.borrow.*.setup.phase.* = "admit child cancellation before freeze";
    const operation = try std.fmt.allocPrint(
        namespaces_view.*.scratch.*,
        "child-cleanup-{d}",
        .{borrow.parked.*},
    );
    const child = try services_view.*.sender.*.workspaceStart(
        namespaces_view.*.scratch.*,
        operation,
        sites_view.*.subject.*.task,
        borrow.cleanup_program.*.receipt.workspace.?,
        &.{},
        .{},
    );
    const child_id = child.receipt.workspace.?;
    var initial = try services_view.*.sender.*.workspaceWork(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*.task,
        child_id,
    );
    defer initial.deinit();
    _ = try services_view.*.sender.*.workspaceControl(
        namespaces_view.*.scratch.*,
        try std.fmt.allocPrint(namespaces_view.*.scratch.*, "{s}-cancel", .{
            operation,
        }),
        sites_view.*.subject.*.task,
        child_id,
        initial.value.execution_revision,
        initial.value.control_revision,
        .{ .cancel = .{
            .bytes = "stop",
        } },
    );
    return placementAwaitChildCancellation(scenario, .{
        .state = .{
            .child_id = &child_id,
            .operation = &operation,
        },
        .prior = &borrow,
    });
}

fn placementCancelledRootWitness(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.borrow.*.borrow.*.services;
    const p = native.placement;
    const operation = try std.fmt.allocPrint(
        namespaces_view.*.scratch.*,
        "root-cleanup-{d}",
        .{borrow.parked.*},
    );
    const cancelled_root = try services_view.*.sender.*.submit(
        namespaces_view.*.scratch.*,
        operation,
        .{ 25, 5 },
    );
    const root_subject: p.Subject = .{ .task = cancelled_root.receipt.task };
    _ = try services_view.*.sender.*.requestCancel(
        namespaces_view.*.scratch.*,
        try std.fmt.allocPrint(
            namespaces_view.*.scratch.*,
            "{s}-cancel",
            .{operation},
        ),
        root_subject.task,
        "stop",
    );
    const root_cut = try services_view.*.sender.*.placementCut(
        namespaces_view.*.scratch.*,
        root_subject,
    );
    const transfer: [32]u8 = @splat(@intCast(80 + borrow.parked.*));
    _ = try freezePlacement(
        &services_view.*.sender.*,
        root_subject,
        "destination",
        root_cut,
        transfer,
    );
    var refusal: ?p.Signed(p.Decision) = null;
    return placementInspectCancelledRoot(scenario, .{
        .state = .{
            .operation = &operation,
            .refusal = &refusal,
            .root_subject = &root_subject,
            .transfer = &transfer,
        },
        .prior = &borrow,
    });
}

fn placementRefusedChildWitness(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.borrow.*.borrow.*.services;
    const sites_view = &borrow.borrow.*.borrow.*.sites;
    if (!(borrow.refused.* != null)) return;
    const changed_cut = try services_view.*.sender.*.placementCut(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*,
    );
    try std.testing.expect(!std.meta.eql(sites_view.*.cut.*, changed_cut));
    const released_head = namespaces_view.*.source_namespace.*.store.head;
    try std.testing.expectError(
        error.OperationConflict,
        freezePlacement(
            &services_view.*.sender.*,
            sites_view.*.subject.*,
            "destination",
            changed_cut,
            @splat(14),
        ),
    );
    try std.testing.expectEqualDeep(
        released_head,
        namespaces_view.*.source_namespace.*.store.head,
    );
    try std.testing.expectEqual(
        .local,
        (try services_view.*.sender.*.placementStatus(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*,
        )).?.phase,
    );
    borrow.borrow.*.borrow.*.setup.phase.* = "fresh transfer after rejected identity reuse";
    const fresh_intent = try freezePlacement(
        &services_view.*.sender.*,
        sites_view.*.subject.*,
        "destination",
        changed_cut,
        @splat(17),
    );
    return placementInspectRefusedChild(scenario, .{
        .state = .{
            .changed_cut = &changed_cut,
            .fresh_intent = &fresh_intent,
        },
        .prior = &borrow,
    });
}

fn placementOnwardSourceWitness(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (!(scenario == .onward)) return;
    borrow.borrow.*.setup.phase.* = "untrusted copied custody";
    const controller: p.Subject = .{ .task = borrow.borrow.*.sites.subject.*.task };
    const controller_cut = try borrow.borrow.*.services.sender.*.placementCut(
        borrow.borrow.*.namespaces.scratch.*,
        controller,
    );
    for (0..3) |attack| {
        if (try placementPrepareCopiedCustody(scenario, .{
            .attack = &attack,
            .borrow = &borrow,
            .controller = &controller,
            .controller_cut = &controller_cut,
        })) break;
    }
}

fn placementOnwardDestinationWitness(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (!(scenario == .onward)) return;
    const controller: p.Subject = .{ .task = borrow.borrow.*.sites.subject.*.task };
    for (0..3) |attack| {
        if (try placementImportCopiedCustody(scenario, .{
            .attack = &attack,
            .borrow = &borrow,
            .controller = &controller,
        })) break;
    }
}

fn placementOnwardRefusalWitness(comptime scenario: anytype, borrow: anytype) !void {
    if (!(scenario == .onward)) return;
    // Ordinary archive import is a data copy. Even a configured native
    // service cannot acquire this task or work merely by possessing it.
    const copied_path = try std.fmt.allocPrint(
        borrow.borrow.*.namespaces.scratch.*,
        "{s}/copied",
        .{
            borrow.borrow.*.namespaces.path_buffer.*[0..borrow.borrow.*.namespaces.length.*],
        },
    );
    var copied_namespace = try native.Namespace.open(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        copied_path,
    );
    defer support.expectCleanup(copied_namespace.close());
    var copied = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        &copied_namespace,
        borrow.borrow.*.application.assets.*,
        &borrow.borrow.*.application.application.*,
        borrow.borrow.*.application.handlers.*,
        borrow.borrow.*.application.profile.*,
    );
    defer support.expectCleanup(copied.close(borrow.borrow.*.setup.a.*));
    var archive_arena = std.heap.ArenaAllocator.init(borrow.borrow.*.setup.a.*);
    defer archive_arena.deinit();
    _ = try copied.importCheckpoint(
        archive_arena.allocator(),
        "copy",
        borrow.borrow.*.offered.archive_path.*,
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        copied.workspacePump(
            borrow.borrow.*.namespaces.scratch.*,
            "copy-cannot-run",
            borrow.borrow.*.sites.subject.*.task,
            .{
                .expected = .{
                    .work = borrow.borrow.*.work.work_ref.*,
                    .execution_revision = borrow.borrow.*.sites.cut.*.execution,
                    .control_revision = borrow.borrow.*.sites.cut.*.control,
                },
                .base_quantum = 1,
            },
        ),
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        copied.resumeTask(
            borrow.borrow.*.namespaces.scratch.*,
            "copy-cannot-control",
            borrow.borrow.*.sites.subject.*.task,
            1,
        ),
    );
}

fn placementImportedRuntimeWitness(comptime scenario: anytype, borrow: anytype) !void {
    const state_namespaces = &borrow.borrow.*.namespaces;

    _ = scenario;
    if (borrow.borrow.*.generated.generated.*) |derived| {
        var inspection = std.heap.ArenaAllocator.init(borrow.borrow.*.setup.a.*);
        defer inspection.deinit();
        const inspection_allocator = inspection.allocator();
        const candidate_bytes = (try state_namespaces.*.destination_namespace.*.store.recordBytes(
            inspection_allocator,
            "workspace_candidate",
            try native.workspace.custodyId(
                inspection_allocator,
                borrow.borrow.*.sites.subject.*.task,
                try nativeIdentity(derived.candidate),
            ),
            borrow.borrow.*.sites.subject.*.task,
        )).?;
        var candidate = try contracts.decodeOwned(
            native.workspace.Candidate,
            inspection_allocator,
            candidate_bytes,
        );
        defer candidate.deinit();
        for ([_]native.testing.state.Reference{
            candidate.value.artifact,
            candidate.value.description.ancestor,
            candidate.value.description.guest,
            candidate.value.description.proposal,
            candidate.value.description.code,
            candidate.value.description.producer.?,
        }) |ref| {
            try std.testing.expectEqualDeep(
                ref,
                try state_namespaces.*.destination_namespace.*.store.objectReference(
                    ref.digest,
                    null,
                ),
            );
        }
        try std.testing.expectEqualDeep(
            borrow.borrow.*.sites.compatibility.*,
            try borrow.borrow.*.services.receiver.*.placementCompatibility(
                inspection_allocator,
                borrow.borrow.*.sites.subject.*,
            ),
        );
        try inspectGeneratedArchive(
            inspection_allocator,
            &borrow.borrow.*.services.receiver.*,
            borrow.borrow.*.sites.subject.*.task,
            derived,
        );
    }
}

fn placementOnwardControllerWitness(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    if (!(scenario == .onward)) return false;
    const delayed_bytes = try borrow.borrow.*.services.sender.*.placementControl(
        borrow.borrow.*.namespaces.scratch.*,
        "delayed-inspect",
        borrow.borrow.*.sites.subject.*.task,
        .{ .inspect = .{
            .work = borrow.borrow.*.work.work_ref.*,
        } },
    );
    var delayed = try contracts.decodeOwned(
        p.Signed(p.Control),
        borrow.borrow.*.namespaces.scratch.*,
        delayed_bytes,
    );
    defer delayed.deinit();
    try borrow.borrow.*.services.sender.*.close(borrow.borrow.*.setup.a.*);
    borrow.borrow.*.services.sender_open.* = false;
    try borrow.borrow.*.namespaces.source_namespace.*.close();
    borrow.borrow.*.namespaces.source_open.* = false;
    borrow.borrow.*.namespaces.destination_namespace.* = try native.Namespace.open(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        borrow.borrow.*.namespaces.destination_path.*,
    );
    borrow.borrow.*.namespaces.destination_open.* = true;
    borrow.borrow.*.services.receiver.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        &borrow.borrow.*.namespaces.destination_namespace.*,
        borrow.borrow.*.application.assets.*,
        &borrow.borrow.*.application.application.*,
        borrow.borrow.*.application.handlers.*,
        borrow.borrow.*.receiver.resumed_profile.*,
    );
    borrow.borrow.*.services.receiver_open.* = true;
    return placementOnwardOfferSuccessor(scenario, .{
        .control = borrow.control,
        .report_bytes = borrow.report_bytes,
        .delayed = .{
            .delayed = &delayed,
            .delayed_bytes = &delayed_bytes,
        },
        .borrow = borrow.borrow,
    });
}

fn placementControllerAdmission(comptime scenario: anytype, borrow: anytype) !void {
    const context_controller_offer = &borrow.borrow.*.controller_offer;
    const p = native.placement;
    var compiler_facts: native.tasks.Service(
        OwnerTypes,
    ).CompilerFacts = .{
        .allocator = borrow.borrow.*.setup.a.*,
    };
    defer compiler_facts.deinit();
    borrow.borrow.*.namespaces.successor_namespace.* = try native.Namespace.open(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        borrow.borrow.*.namespaces.successor_path.*,
    );
    defer support.expectCleanup(borrow.borrow.*.namespaces.successor_namespace.*.close());
    var successor_profile = borrow.borrow.*.application.profile.*;
    successor_profile.placement = &borrow.borrow.*.channels.successor_config.*;
    var successor = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        &borrow.borrow.*.namespaces.successor_namespace.*,
        borrow.borrow.*.application.assets.*,
        &borrow.borrow.*.application.application.*,
        borrow.borrow.*.application.handlers.*,
        successor_profile,
    );
    defer support.expectCleanup(successor.close(borrow.borrow.*.setup.a.*));
    if (scenario == .work) successor.compiler_facts = &compiler_facts;
    borrow.controller_decision.* = try acceptPlacement(
        &successor,
        "accept-controller",
        "source",
        context_controller_offer.*.controller_offer.*,
        context_controller_offer.*.controller_archive.*,
    );
    try std.testing.expectEqual(
        .local,
        (try successor.placementStatus(
            borrow.borrow.*.namespaces.scratch.*,
            borrow.borrow.*.report.controller_subject.*,
        )).?.phase,
    );
    try std.testing.expectEqual(
        .away,
        (try successor.placementStatus(
            borrow.borrow.*.namespaces.scratch.*,
            borrow.borrow.*.sites.subject.*,
        )).?.phase,
    );
    borrow.successor_control.* = try contracts.decodeOwned(
        p.Signed(p.Control),
        borrow.borrow.*.namespaces.scratch.*,
        try successor.placementControl(
            borrow.borrow.*.namespaces.scratch.*,
            "new-controller-inspect",
            borrow.borrow.*.sites.subject.*.task,
            .{ .inspect = .{
                .work = borrow.borrow.*.work.work_ref.*,
            } },
        ),
    );
}

fn placementRemoteAcknowledgement(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (!(scenario == .remote_ack)) return;
    _ = try freezePlacement(
        &borrow.borrow.*.fixture.sender.*,
        borrow.borrow.*.fixture.subject.*,
        "destination",
        borrow.borrow.*.fixture.cut.*,
        @splat(74),
    );
    const work_archive = try std.fmt.allocPrint(
        borrow.borrow.*.fixture.scratch.*,
        "{s}/ack-work.par",
        .{
            borrow.borrow.*.fixture.path_buffer.*[0..borrow.borrow.*.fixture.length.*],
        },
    );
    const work_offer = try offerPlacement(
        &borrow.borrow.*.fixture.sender.*,
        borrow.borrow.*.fixture.subject.*,
        "destination",
        work_archive,
    );
    try borrow.borrow.*.fixture.sender.*.close(borrow.borrow.*.fixture.a.*);
    borrow.borrow.*.fixture.sender_open.* = false;
    try borrow.borrow.*.fixture.source_namespace.*.close();
    borrow.borrow.*.fixture.source_open.* = false;
    var work_decision: p.Signed(p.Decision) = undefined;
    return placementReopenAcknowledgedController(scenario, .{
        .state = .{
            .work_archive = &work_archive,
            .work_decision = &work_decision,
            .work_offer = &work_offer,
        },
        .prior = &borrow,
    });
}

fn placementAcknowledgementParking(comptime scenario: anytype, borrow: anytype) !void {
    if (scenario == .local_ack) {
        _ = try borrow.borrow.*.fixture.sender.*.pump(borrow.borrow.*.fixture.scratch.*);
        var cancelled = try borrow.borrow.*.fixture.sender.*.workspaceWork(
            borrow.borrow.*.fixture.scratch.*,
            borrow.borrow.*.fixture.subject.*.task,
            borrow.borrow.*.fixture.work_id.*,
        );
        defer cancelled.deinit();
        try std.testing.expect(
            cancelled.value.cancellation != null and !cancelled.value.terminal(),
        );
        _ = try borrow.borrow.*.fixture.sender.*.workspaceControl(
            borrow.borrow.*.fixture.scratch.*,
            "ack-local-park",
            borrow.borrow.*.fixture.subject.*.task,
            borrow.borrow.*.fixture.work_id.*,
            cancelled.value.execution_revision,
            cancelled.value.control_revision,
            .park,
        );
    } else {
        try placementParkRemoteAcknowledgement(scenario, .{
            .borrow = &borrow,
        });
    }
}

fn placementRejectedFrozenPump(comptime scenario: anytype, borrow: anytype) !void {
    _ = scenario;
    const copy_path = try std.fmt.allocPrint(
        borrow.borrow.*.fixture.scratch.*,
        "{s}/foreign-frozen-copy",
        .{
            borrow.borrow.*.fixture.path_buffer.*[0..borrow.borrow.*.fixture.length.*],
        },
    );
    var copy_namespace = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        copy_path,
    );
    defer support.expectCleanup(copy_namespace.close());
    var copy_profile = borrow.borrow.*.fixture.profile.*;
    // A copied namespace can share the signing key without sharing
    // the source namespace's actual custody or export obligation.
    copy_profile.placement = &borrow.borrow.*.fixture.source_config.*;
    var copied = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &copy_namespace,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        copy_profile,
    );
    defer support.expectCleanup(copied.close(borrow.borrow.*.fixture.a.*));
    var archive_arena = std.heap.ArenaAllocator.init(borrow.borrow.*.fixture.a.*);
    defer archive_arena.deinit();
    _ = try copied.importCheckpoint(
        archive_arena.allocator(),
        "copy-frozen",
        borrow.snapshot_path.*,
    );
    const copied_head = copy_namespace.store.head;
    const copied_receipt = try copied.workspaceBuild(
        borrow.borrow.*.fixture.scratch.*,
        "build",
        borrow.borrow.*.fixture.parent.*.receipt.task,
        borrow.borrow.*.fixture.document.*,
        &borrow.borrow.*.fixture.diagnostic.*,
    );
    try std.testing.expect(copied_receipt.replayed);
    try std.testing.expectEqualDeep(
        borrow.borrow.*.fixture.program.*.receipt,
        copied_receipt.receipt,
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        copied.workspaceBuild(
            borrow.borrow.*.fixture.scratch.*,
            "copied-new-build",
            borrow.borrow.*.fixture.parent.*.receipt.task,
            borrow.borrow.*.fixture.document.*,
            &borrow.borrow.*.fixture.diagnostic.*,
        ),
    );
    try std.testing.expectEqualDeep(copied_head, copy_namespace.store.head);
    try std.testing.expectError(
        error.InvalidTransfer,
        offerPlacement(
            &copied,
            borrow.borrow.*.frozen.controller.*,
            "successor",
            borrow.snapshot_path.*,
        ),
    );
}

fn placementStoppedControllerCommands(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    var closing_namespace = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.successor_path.*,
    );
    defer support.expectCleanup(closing_namespace.close());
    var closing_controller = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &closing_namespace,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.borrow.*.accepted.snapshot_profile.*,
    );
    defer support.expectCleanup(closing_controller.close(fixture_view.*.a.*));
    var terminal_parent = try closing_controller.task(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
    );
    defer terminal_parent.deinit();
    try std.testing.expect(terminal_parent.value.terminal());
    for (borrow.stopped_commands.*, &borrow.stopped_controls.*, 0..) |command, *signed, index| {
        const operation_name = try std.fmt.allocPrint(
            fixture_view.*.scratch.*,
            "after-parent-completion-{d}",
            .{
                index,
            },
        );
        const bytes = try closing_controller.placementControl(
            fixture_view.*.scratch.*,
            operation_name,
            fixture_view.*.subject.*.task,
            command,
        );
        const decoded = try contracts.decodeOwned(
            p.Signed(p.Control),
            fixture_view.*.scratch.*,
            bytes,
        );
        signed.* = decoded.value;
        try std.testing.expect(signed.value.parent_stopped);
        try std.testing.expectEqualSlices(
            u8,
            bytes,
            try closing_controller.placementControl(
                fixture_view.*.scratch.*,
                operation_name,
                fixture_view.*.subject.*.task,
                command,
            ),
        );
    }
}

fn placementStoppedControllerReports(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    var executor_namespace = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.source_path.*,
    );
    defer support.expectCleanup(executor_namespace.close());
    var closing_executor = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &executor_namespace,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.source_profile.*,
    );
    defer support.expectCleanup(closing_executor.close(fixture_view.*.a.*));
    var retained_parent = try closing_executor.task(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
    );
    defer retained_parent.deinit();
    try std.testing.expect(!retained_parent.value.terminal());
    const before = try closing_executor.placementCut(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*,
    );
    for (borrow.stopped_controls.*) |control_value| {
        const bytes = try closing_executor.placementExecuteControl(
            fixture_view.*.scratch.*,
            "successor",
            control_value,
        );
        const rejected = try contracts.decodeOwned(
            p.Signed(p.Report),
            fixture_view.*.scratch.*,
            bytes,
        );
        try std.testing.expectEqual(.rejected, rejected.value.value.reply.disposition);
        const observation = (try native.json.parseAsset(
            fixture_view.*.scratch.*,
            rejected.value.value.reply.observation_json.bytes,
            rejected.value.value.reply.observation_json.bytes.len,
        )).value;
        try std.testing.expectEqualStrings(
            "InvalidState",
            observation.object.get("error").?.string,
        );
        try std.testing.expectEqualDeep(
            before,
            try closing_executor.placementCut(
                fixture_view.*.scratch.*,
                fixture_view.*.subject.*,
            ),
        );
        try std.testing.expect(closing_executor.remote_stopped_parent == null);
        try std.testing.expectEqualSlices(
            u8,
            bytes,
            try closing_executor.placementExecuteControl(
                fixture_view.*.scratch.*,
                "successor",
                control_value,
            ),
        );
    }
}

fn placementAcknowledgedControllerState(comptime scenario: anytype, borrow: anytype) !void {
    const state_offered = &borrow.borrow.*.borrow.*.offered;

    const fixture_view = &borrow.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    var ns = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.successor_path.*,
    );
    defer support.expectCleanup(ns.close());
    var successor = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &ns,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.borrow.*.ack.ack_successor_profile.*,
    );
    defer support.expectCleanup(successor.close(fixture_view.*.a.*));
    try successor.placementApplyReport(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
        p.controlId(borrow.borrow.*.inspection.*.value),
        borrow.borrow.*.inspection_report.*,
    );
    var parent_cut = try successor.task(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
    );
    defer parent_cut.deinit();
    _ = try successor.resumeTask(
        fixture_view.*.scratch.*,
        "ack-resume-controller",
        fixture_view.*.subject.*.task,
        parent_cut.value.revision,
    );
    _ = try successor.pump(fixture_view.*.scratch.*);
    try std.testing.expectEqual(
        null,
        try pendingCleanup(
            &successor,
            fixture_view.*.scratch.*,
            fixture_view.*.subject.*.task,
        ),
    );
    try std.testing.expect(
        try successor.shutdownIncomplete(fixture_view.*.scratch.*),
    );
    _ = try successor.requestCancel(
        fixture_view.*.scratch.*,
        "ack-fresh-cancel",
        fixture_view.*.subject.*.task,
        "stop again",
    );
    _ = try successor.pump(fixture_view.*.scratch.*);
    const fresh = (try pendingCleanup(
        &successor,
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
    )).?;
    try std.testing.expect(fresh.value.command == .cancel);
    try std.testing.expect(
        fresh.value.cleanup_request.? > state_offered.*.parent_before_move.*.value.revision,
    );
}

fn placementRootCloseReport(comptime scenario: anytype, borrow: anytype) !bool {
    const fixture_view = &borrow.borrow.*.borrow.*.borrow.*.fixture;
    const p = native.placement;
    var closing_namespace = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.successor_path.*,
    );
    defer support.expectCleanup(closing_namespace.close());
    var closing_controller = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &closing_namespace,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.borrow.*.borrow.*.accepted.snapshot_profile.*,
    );
    defer support.expectCleanup(
        closing_controller.close(fixture_view.*.a.*),
    );
    fixture_view.*.phase.* = "apply remote close report";
    if (borrow.borrow.*.prior_report.*) |reported| try closing_controller.placementApplyReport(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
        p.controlId(borrow.borrow.*.prior_command.*.?.value),
        reported,
    );
    return placementSelectRootCloseCommand(scenario, .{
        .state = .{
            .closing_controller = &closing_controller,
            .closing_namespace = &closing_namespace,
        },
        .prior = &borrow,
    });
}

fn placementRootCloseExecution(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.borrow.*.borrow.*.borrow.*.fixture;
    const p = native.placement;
    var executor_namespace = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.source_path.*,
    );
    defer support.expectCleanup(executor_namespace.close());
    var closing_executor = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &executor_namespace,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.borrow.*.source_profile.*,
    );
    defer support.expectCleanup(
        closing_executor.close(fixture_view.*.a.*),
    );
    fixture_view.*.phase.* = "execute remote close observation";
    const result = try contracts.decodeOwned(
        p.Signed(p.Report),
        fixture_view.*.scratch.*,
        try closing_executor.placementExecuteControl(
            fixture_view.*.scratch.*,
            "successor",
            borrow.selected_command.*,
        ),
    );
    try std.testing.expectEqual(.observed, result.value.value.reply.disposition);
    if (borrow.borrow.*.prior_report.*) |previous| try std.testing.expect(
        result.value.value.work_state.?.observed_at > previous.value.work_state.?.observed_at,
    );
    borrow.borrow.*.prior_report.* = result.value;
    borrow.borrow.*.prior_command.* = borrow.selected_command.*;
    return placementExecuteRootCloseCommand(scenario, .{
        .state = .{
            .closing_executor = &closing_executor,
            .result = &result,
        },
        .prior = &borrow,
    });
}

fn placementRemoteDisposalSchedule(comptime scenario: anytype, borrow: anytype) !bool {
    const context_application = &borrow.borrow.*.borrow.*.application;
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const setup_view = &borrow.borrow.*.borrow.*.setup;
    const p = native.placement;
    var compiler_facts: native.tasks.Service(
        OwnerTypes,
    ).CompilerFacts = .{
        .allocator = setup_view.*.a.*,
    };
    defer compiler_facts.deinit();
    namespaces_view.*.successor_namespace.* = try native.Namespace.open(
        setup_view.*.a.*,
        setup_view.*.io.*,
        namespaces_view.*.successor_path.*,
    );
    defer support.expectCleanup(
        namespaces_view.*.successor_namespace.*.close(),
    );
    var successor_profile = context_application.*.profile.*;
    successor_profile.placement = &borrow.borrow.*.borrow.*.channels.successor_config.*;
    var successor = try native.tasks.Service(OwnerTypes).init(
        setup_view.*.a.*,
        setup_view.*.io.*,
        &namespaces_view.*.successor_namespace.*,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        successor_profile,
    );
    defer support.expectCleanup(successor.close(setup_view.*.a.*));
    if (scenario == .work) successor.compiler_facts = &compiler_facts;
    try successor.placementApplyReport(
        namespaces_view.*.scratch.*,
        borrow.borrow.*.borrow.*.sites.subject.*.task,
        p.controlId(borrow.borrow.*.cleanup_control.*.value),
        borrow.borrow.*.cleanup_report.*,
    );
    setup_view.*.attack_index.* = borrow.borrow.*.iteration.*;
    setup_view.*.phase.* = "initial remote disposal state";
    return placementCompareRemoteDisposal(scenario, .{
        .state = .{
            .successor = &successor,
        },
        .prior = &borrow,
    });
}

fn placementRemoteDisposalExecution(comptime scenario: anytype, borrow: anytype) !void {
    const state_controller = &borrow.borrow.*.borrow.*.controller;
    const state_receiver = &borrow.borrow.*.borrow.*.receiver;

    const context_application = &borrow.borrow.*.borrow.*.application;
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const cleanup_control_view = &borrow.borrow.*.cleanup_control;
    const setup_view = &borrow.borrow.*.borrow.*.setup;
    const p = native.placement;
    var compiler_facts: native.tasks.Service(
        OwnerTypes,
    ).CompilerFacts = .{
        .allocator = setup_view.*.a.*,
    };
    defer compiler_facts.deinit();
    const at_source = std.meta.eql(
        cleanup_control_view.*.*.value.executor,
        borrow.borrow.*.borrow.*.sites.source_site.*,
    );
    var executor_namespace = try native.Namespace.open(
        setup_view.*.a.*,
        setup_view.*.io.*,
        if (at_source) namespaces_view.*.source_path.* else namespaces_view.*.destination_path.*,
    );
    defer support.expectCleanup(executor_namespace.close());
    var executor = try native.tasks.Service(OwnerTypes).init(
        setup_view.*.a.*,
        setup_view.*.io.*,
        &executor_namespace,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        if (at_source) state_controller.*.source_profile.* else state_receiver.*.resumed_profile.*,
    );
    defer support.expectCleanup(executor.close(setup_view.*.a.*));
    if (scenario == .work) executor.compiler_facts = &compiler_facts;
    const bytes = try executor.placementExecuteControl(
        namespaces_view.*.scratch.*,
        "successor",
        cleanup_control_view.*.*,
    );
    const decoded_report = try contracts.decodeOwned(
        p.Signed(p.Report),
        namespaces_view.*.scratch.*,
        bytes,
    );
    return placementInspectRemoteDisposal(scenario, .{
        .state = .{
            .at_source = &at_source,
            .bytes = &bytes,
            .decoded_report = &decoded_report,
            .executor = &executor,
        },
        .prior = &borrow,
    });
}

fn placementRejectObserverMobility(comptime scenario: anytype, borrow: anytype) !void {
    _ = scenario;
    try std.testing.expectError(
        error.ActiveObserverMobilityUnsupported,
        freezePlacement(
            &borrow.borrow.*.services.sender.*,
            borrow.borrow.*.sites.subject.*,
            "destination",
            borrow.borrow.*.sites.cut.*,
            @splat(101),
        ),
    );
    try std.testing.expectError(
        error.ActiveObserverMobilityUnsupported,
        freezePlacement(
            &borrow.borrow.*.services.sender.*,
            borrow.rejectobservermobility.observer_subject.*,
            "destination",
            try borrow.borrow.*.services.sender.*.placementCut(
                borrow.borrow.*.namespaces.scratch.*,
                borrow.rejectobservermobility.observer_subject.*,
            ),
            @splat(102),
        ),
    );
    try std.testing.expectError(
        error.ScheduledObserverMobilityUnsupported,
        freezePlacement(
            &borrow.borrow.*.services.sender.*,
            borrow.rejectobservermobility.controller.*,
            "successor",
            try borrow.borrow.*.services.sender.*.placementCut(
                borrow.borrow.*.namespaces.scratch.*,
                borrow.rejectobservermobility.controller.*,
            ),
            @splat(103),
        ),
    );
    try std.testing.expectEqualDeep(
        borrow.rejectobservermobility.before.*,
        borrow.borrow.*.namespaces.source_namespace.*.store.head,
    );
    _ = try borrow.borrow.*.services.sender.*.workspaceStopObserving(
        borrow.borrow.*.namespaces.scratch.*,
        "placement-observer-stop",
        borrow.borrow.*.sites.subject.*.task,
        borrow.rejectobservermobility.observer.*,
    );
    _ = try borrow.borrow.*.services.sender.*.placementCompatibility(
        borrow.borrow.*.namespaces.scratch.*,
        borrow.rejectobservermobility.observer_subject.*,
    );
    observerCustodyWitness(
        &borrow.borrow.*.services.sender.*,
        borrow.borrow.*.namespaces.scratch.*,
        borrow.borrow.*.sites.subject.*.task,
        borrow.borrow.*.child.selected_program.*,
        borrow.borrow.*.input.input.*,
        &borrow.borrow.*.peers.source_peers.*[0],
    ) catch |err| {
        std.debug.print("observer custody: {s}\n", .{@errorName(err)});
        return err;
    };
}

fn placementOnwardSuccessorExecution(comptime scenario: anytype, borrow: anytype) !void {
    const context_application = &borrow.borrow.*.borrow.*.application;
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const setup_view = &borrow.borrow.*.borrow.*.setup;
    const p = native.placement;
    namespaces_view.*.successor_namespace.* = try native.Namespace.open(
        setup_view.*.a.*,
        setup_view.*.io.*,
        namespaces_view.*.successor_path.*,
    );
    defer support.expectCleanup(
        namespaces_view.*.successor_namespace.*.close(),
    );
    var successor_profile = context_application.*.profile.*;
    successor_profile.placement = &borrow.borrow.*.borrow.*.channels.successor_config.*;
    var successor = try native.tasks.Service(OwnerTypes).init(
        setup_view.*.a.*,
        setup_view.*.io.*,
        &namespaces_view.*.successor_namespace.*,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        successor_profile,
    );
    defer support.expectCleanup(successor.close(setup_view.*.a.*));
    const before = namespaces_view.*.successor_namespace.*.store.head;
    var old_receipt = try contracts.decodeOwned(
        p.ControlResolution,
        namespaces_view.*.scratch.*,
        try successor.placementResolveControl(
            namespaces_view.*.scratch.*,
            "source",
            borrow.borrow.*.control.*.value,
            &borrow.route.*,
        ),
    );
    defer old_receipt.deinit();
    try std.testing.expect(old_receipt.value == .report);
    try std.testing.expectEqualSlices(
        u8,
        borrow.borrow.*.report_bytes.*,
        try contracts.encodeOwned(
            p.Signed(p.Report),
            namespaces_view.*.scratch.*,
            old_receipt.value.report,
        ),
    );
    try std.testing.expectEqualDeep(
        before,
        namespaces_view.*.successor_namespace.*.store.head,
    );
    return placementOnwardRejectAuthority(scenario, .{
        .successor = .{
            .before = &before,
            .successor = &successor,
        },
        .borrow = borrow.borrow,
        .delayed = borrow.delayed,
        .delayed_report_bytes = borrow.delayed_report_bytes,
        .next_decision = borrow.next_decision,
        .route = borrow.route,
    });
}

fn placementPreofferResolveChild(comptime scenario: anytype, borrow: anytype) !void {
    borrow.borrow.*.fixture.source_namespace.* = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        borrow.borrow.*.fixture.source_path.*,
    );
    borrow.borrow.*.fixture.source_open.* = true;
    borrow.borrow.*.fixture.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &borrow.borrow.*.fixture.source_namespace.*,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        borrow.source_profile.*,
    );
    borrow.borrow.*.fixture.sender_open.* = true;
    try borrow.borrow.*.fixture.sender.*.placementApplyDecision(
        borrow.borrow.*.fixture.scratch.*,
        borrow.borrow.*.fixture.subject.*,
        borrow.child.child_decision.*,
    );
    try borrow.borrow.*.fixture.sender.*.close(borrow.borrow.*.fixture.a.*);
    borrow.borrow.*.fixture.sender_open.* = false;
    try borrow.borrow.*.fixture.source_namespace.*.close();
    borrow.borrow.*.fixture.source_open.* = false;
    return placementPreofferInspectSuccessor(scenario, .{
        .borrow = borrow.borrow,
        .source_profile = borrow.source_profile,
    });
}

fn placementPreofferInspectSuccessor(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var signed_control: p.Signed(p.Control) = undefined;
    {
        borrow.borrow.*.accepted.snapshot_namespace.* = try native.Namespace.open(
            borrow.borrow.*.fixture.a.*,
            borrow.borrow.*.fixture.io.*,
            borrow.borrow.*.fixture.successor_path.*,
        );
        defer support.expectCleanup(borrow.borrow.*.accepted.snapshot_namespace.*.close());
        borrow.borrow.*.accepted.snapshot_receiver.* = try native.tasks.Service(OwnerTypes).init(
            borrow.borrow.*.fixture.a.*,
            borrow.borrow.*.fixture.io.*,
            &borrow.borrow.*.accepted.snapshot_namespace.*,
            borrow.borrow.*.fixture.assets.*,
            &borrow.borrow.*.fixture.application.*,
            borrow.borrow.*.fixture.handlers.*,
            borrow.borrow.*.accepted.snapshot_profile.*,
        );
        defer support.expectCleanup(
            borrow.borrow.*.accepted.snapshot_receiver.*.close(borrow.borrow.*.fixture.a.*),
        );
        const saved_control = try contracts.decodeOwned(
            p.Signed(p.Control),
            borrow.borrow.*.fixture.scratch.*,
            try borrow.borrow.*.accepted.snapshot_receiver.*.placementControl(
                borrow.borrow.*.fixture.scratch.*,
                "inspect-late-child",
                borrow.borrow.*.fixture.subject.*.task,
                .{ .inspect = .{
                    .work = borrow.borrow.*.fixture.work_ref.*,
                } },
            ),
        );
        signed_control = saved_control.value;
    }
    return placementPreofferRouteControl(scenario, .{
        .control = .{
            .signed_control = &signed_control,
        },
        .borrow = borrow.borrow,
        .source_profile = borrow.source_profile,
    });
}

fn placementPreofferRouteControl(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    borrow.borrow.*.fixture.source_namespace.* = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        borrow.borrow.*.fixture.source_path.*,
    );
    borrow.borrow.*.fixture.source_open.* = true;
    borrow.borrow.*.fixture.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &borrow.borrow.*.fixture.source_namespace.*,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        borrow.source_profile.*,
    );
    borrow.borrow.*.fixture.sender_open.* = true;
    var next = try contracts.decodeOwned(
        p.ControlResolution,
        borrow.borrow.*.fixture.scratch.*,
        try borrow.borrow.*.fixture.sender.*.placementResolveControl(
            borrow.borrow.*.fixture.scratch.*,
            "successor",
            borrow.control.signed_control.*,
            &.{},
        ),
    );
    defer next.deinit();
    try std.testing.expect(next.value == .next);
    const route = [_]p.Succession{next.value.next};
    try borrow.borrow.*.fixture.sender.*.close(borrow.borrow.*.fixture.a.*);
    borrow.borrow.*.fixture.sender_open.* = false;
    try borrow.borrow.*.fixture.source_namespace.*.close();
    borrow.borrow.*.fixture.source_open.* = false;
    return placementPreofferResolveDestination(scenario, .{
        .route = .{
            .route = &route,
        },
        .borrow = borrow.borrow,
        .control = borrow.control,
        .source_profile = borrow.source_profile,
    });
}

fn placementPreofferResolveDestination(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    var result: p.Signed(p.Report) = undefined;

    try placementPreofferExecuteControl(scenario, .{
        .borrow = &borrow,
        .result = &result,
    });

    try placementPreofferAcceptReport(scenario, .{
        .borrow = &borrow,
        .result = &result,
    });

    borrow.borrow.*.fixture.phase.* = "cancel executor-local observer";
    borrow.borrow.*.fixture.source_namespace.* = try native.Namespace.open(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        borrow.borrow.*.fixture.source_path.*,
    );
    borrow.borrow.*.fixture.source_open.* = true;
    borrow.borrow.*.fixture.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.fixture.a.*,
        borrow.borrow.*.fixture.io.*,
        &borrow.borrow.*.fixture.source_namespace.*,
        borrow.borrow.*.fixture.assets.*,
        &borrow.borrow.*.fixture.application.*,
        borrow.borrow.*.fixture.handlers.*,
        borrow.source_profile.*,
    );
    borrow.borrow.*.fixture.sender_open.* = true;
    try executorObserverCancellation(
        &borrow.borrow.*.fixture.sender.*,
        borrow.borrow.*.fixture.scratch.*,
        borrow.borrow.*.fixture.subject.*.task,
        borrow.borrow.*.fixture.executor_observer.*.?,
    );
}

fn placementPreofferExecuteControl(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    fixture_view.*.destination_namespace.* = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.destination_path.*,
    );
    defer support.expectCleanup(
        fixture_view.*.destination_namespace.*.close(),
    );
    var child_profile = fixture_view.*.profile.*;
    child_profile.placement = &fixture_view.*.destination_config.*;
    var child_owner = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &fixture_view.*.destination_namespace.*,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        child_profile,
    );
    defer support.expectCleanup(child_owner.close(fixture_view.*.a.*));
    try child_owner.placementFollowController(
        fixture_view.*.scratch.*,
        "source",
        "successor",
        borrow.borrow.*.borrow.*.offered.snapshot_offer.*,
        borrow.borrow.*.borrow.*.accepted.decision.*,
    );
    const resolved = try contracts.decodeOwned(
        p.ControlResolution,
        fixture_view.*.scratch.*,
        try child_owner.placementResolveControl(
            fixture_view.*.scratch.*,
            "successor",
            borrow.borrow.*.control.signed_control.*,
            &borrow.borrow.*.route.route.*,
        ),
    );
    borrow.result.* = resolved.value.report;
    try std.testing.expectEqual(.observed, borrow.result.*.value.reply.disposition);
}

fn placementPreofferAcceptReport(comptime scenario: anytype, borrow: anytype) !void {
    const accepted_view = &borrow.borrow.*.borrow.*.accepted;
    const fixture_view = &borrow.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    accepted_view.*.snapshot_namespace.* = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.successor_path.*,
    );
    defer support.expectCleanup(accepted_view.*.snapshot_namespace.*.close());
    accepted_view.*.snapshot_receiver.* = try native.tasks.Service(
        OwnerTypes,
    ).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &accepted_view.*.snapshot_namespace.*,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        accepted_view.*.snapshot_profile.*,
    );
    defer support.expectCleanup(
        accepted_view.*.snapshot_receiver.*.close(
            fixture_view.*.a.*,
        ),
    );
    try accepted_view.*.snapshot_receiver.*.placementFollowExecutor(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
        p.controlId(borrow.borrow.*.control.signed_control.*.value),
        borrow.borrow.*.route.route.*[0],
    );
    try accepted_view.*.snapshot_receiver.*.placementApplyReport(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
        p.controlId(borrow.borrow.*.control.signed_control.*.value),
        borrow.result.*,
    );
    try std.testing.expectEqualDeep(
        fixture_view.*.destination_site.*,
        (try accepted_view.*.snapshot_receiver.*.placementStatus(
            fixture_view.*.scratch.*,
            fixture_view.*.subject.*,
        )).?.owner,
    );
}

fn placementOnwardOfferSuccessor(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    const next_cut = try borrow.borrow.*.services.receiver.*.placementCut(
        borrow.borrow.*.namespaces.scratch.*,
        borrow.borrow.*.sites.subject.*,
    );
    _ = try freezePlacement(
        &borrow.borrow.*.services.receiver.*,
        borrow.borrow.*.sites.subject.*,
        "successor",
        next_cut,
        @splat(71),
    );
    const next_path = try std.fmt.allocPrint(
        borrow.borrow.*.namespaces.scratch.*,
        "{s}/onward.par",
        .{
            borrow.borrow.*.namespaces.path_buffer.*[0..borrow.borrow.*.namespaces.length.*],
        },
    );
    const next_offer = try offerPlacement(
        &borrow.borrow.*.services.receiver.*,
        borrow.borrow.*.sites.subject.*,
        "successor",
        next_path,
    );
    try borrow.borrow.*.services.receiver.*.close(borrow.borrow.*.setup.a.*);
    borrow.borrow.*.services.receiver_open.* = false;
    try borrow.borrow.*.namespaces.destination_namespace.*.close();
    borrow.borrow.*.namespaces.destination_open.* = false;
    var next_decision: p.Signed(p.Decision) = undefined;
    {
        borrow.borrow.*.namespaces.successor_namespace.* = try native.Namespace.open(
            borrow.borrow.*.setup.a.*,
            borrow.borrow.*.setup.io.*,
            borrow.borrow.*.namespaces.successor_path.*,
        );
        defer support.expectCleanup(borrow.borrow.*.namespaces.successor_namespace.*.close());
        var successor_profile = borrow.borrow.*.application.profile.*;
        successor_profile.placement = &borrow.borrow.*.channels.successor_config.*;
        var successor = try native.tasks.Service(OwnerTypes).init(
            borrow.borrow.*.setup.a.*,
            borrow.borrow.*.setup.io.*,
            &borrow.borrow.*.namespaces.successor_namespace.*,
            borrow.borrow.*.application.assets.*,
            &borrow.borrow.*.application.application.*,
            borrow.borrow.*.application.handlers.*,
            successor_profile,
        );
        defer support.expectCleanup(successor.close(borrow.borrow.*.setup.a.*));
        next_decision = try acceptPlacement(
            &successor,
            "accept-onward",
            "destination",
            next_offer,
            next_path,
        );
    }
    return placementOnwardResolveFormer(scenario, .{
        .control = borrow.control,
        .report_bytes = borrow.report_bytes,
        .offered = .{
            .next_decision = &next_decision,
        },
        .borrow = borrow.borrow,
        .delayed = borrow.delayed,
    });
}

fn placementOnwardResolveFormer(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    borrow.borrow.*.namespaces.destination_namespace.* = try native.Namespace.open(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        borrow.borrow.*.namespaces.destination_path.*,
    );
    borrow.borrow.*.namespaces.destination_open.* = true;
    borrow.borrow.*.services.receiver.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        &borrow.borrow.*.namespaces.destination_namespace.*,
        borrow.borrow.*.application.assets.*,
        &borrow.borrow.*.application.application.*,
        borrow.borrow.*.application.handlers.*,
        borrow.borrow.*.receiver.resumed_profile.*,
    );
    borrow.borrow.*.services.receiver_open.* = true;
    try borrow.borrow.*.services.receiver.*.placementApplyDecision(
        borrow.borrow.*.namespaces.scratch.*,
        borrow.borrow.*.sites.subject.*,
        borrow.offered.next_decision.*,
    );
    var resolution = try contracts.decodeOwned(
        p.ControlResolution,
        borrow.borrow.*.namespaces.scratch.*,
        try borrow.borrow.*.services.receiver.*.placementResolveControl(
            borrow.borrow.*.namespaces.scratch.*,
            "source",
            borrow.delayed.delayed.*.value,
            &.{},
        ),
    );
    defer resolution.deinit();
    try std.testing.expect(resolution.value == .next);
    const route = [_]p.Succession{resolution.value.next};
    try std.testing.expectEqualDeep(borrow.offered.next_decision.*, route[0].decision);
    try borrow.borrow.*.services.receiver.*.close(borrow.borrow.*.setup.a.*);
    borrow.borrow.*.services.receiver_open.* = false;
    try borrow.borrow.*.namespaces.destination_namespace.*.close();
    borrow.borrow.*.namespaces.destination_open.* = false;
    return placementOnwardFollowSuccessor(scenario, .{
        .control = borrow.control,
        .report_bytes = borrow.report_bytes,
        .route = .{
            .route = &route,
        },
        .borrow = borrow.borrow,
        .delayed = borrow.delayed,
        .offered = borrow.offered,
    });
}

fn placementOnwardFollowSuccessor(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    borrow.borrow.*.namespaces.source_namespace.* = try native.Namespace.open(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        borrow.borrow.*.namespaces.source_path.*,
    );
    borrow.borrow.*.namespaces.source_open.* = true;
    borrow.borrow.*.services.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        &borrow.borrow.*.namespaces.source_namespace.*,
        borrow.borrow.*.application.assets.*,
        &borrow.borrow.*.application.application.*,
        borrow.borrow.*.application.handlers.*,
        borrow.borrow.*.controller.source_profile.*,
    );
    borrow.borrow.*.services.sender_open.* = true;
    var forged = borrow.route.route.*[0];
    forged.offer.value.intent.epoch += 1;
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        borrow.borrow.*.services.sender.*.placementFollowExecutor(
            borrow.borrow.*.namespaces.scratch.*,
            borrow.borrow.*.sites.subject.*.task,
            p.controlId(borrow.delayed.delayed.*.value.value),
            forged,
        ),
    );
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.borrow.*.services.sender.*.profile.authority;
        defer borrow.borrow.*.services.sender.*.profile.authority = authority;
        const before = borrow.borrow.*.namespaces.source_namespace.*.store.head;
        const pending_before = try borrow.borrow.*.namespaces.scratch.*.dupe(
            @TypeOf(borrow.borrow.*.services.sender.*.placement_pending.items[0]),
            borrow.borrow.*.services.sender.*.placement_pending.items,
        );
        @field(borrow.borrow.*.services.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            borrow.borrow.*.services.sender.*.placementFollowExecutor(
                borrow.borrow.*.namespaces.scratch.*,
                borrow.borrow.*.sites.subject.*.task,
                p.controlId(borrow.delayed.delayed.*.value.value),
                borrow.route.route.*[0],
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            borrow.borrow.*.namespaces.source_namespace.*.store.head,
        );
        try std.testing.expectEqualDeep(
            pending_before,
            borrow.borrow.*.services.sender.*.placement_pending.items,
        );
    }
    return placementOnwardApplySuccession(scenario, .{
        .control = borrow.control,
        .report_bytes = borrow.report_bytes,
        .borrow = borrow.borrow,
        .delayed = borrow.delayed,
        .offered = borrow.offered,
        .route = borrow.route,
    });
}

fn placementOnwardApplySuccession(comptime scenario: anytype, borrow: anytype) !bool {
    const p = native.placement;
    try borrow.borrow.*.services.sender.*.placementFollowExecutor(
        borrow.borrow.*.namespaces.scratch.*,
        borrow.borrow.*.sites.subject.*.task,
        p.controlId(borrow.delayed.delayed.*.value.value),
        borrow.route.route.*[0],
    );
    try std.testing.expectEqualDeep(
        borrow.borrow.*.sites.successor_site.*,
        (try borrow.borrow.*.services.sender.*.placementStatus(
            borrow.borrow.*.namespaces.scratch.*,
            borrow.borrow.*.sites.subject.*,
        )).?.owner,
    );
    try std.testing.expectEqualSlices(
        u8,
        borrow.delayed.delayed_bytes.*,
        try borrow.borrow.*.services.sender.*.placementControl(
            borrow.borrow.*.namespaces.scratch.*,
            "delayed-inspect",
            borrow.borrow.*.sites.subject.*.task,
            .{ .inspect = .{
                .work = borrow.borrow.*.work.work_ref.*,
            } },
        ),
    );
    try borrow.borrow.*.services.sender.*.close(borrow.borrow.*.setup.a.*);
    borrow.borrow.*.services.sender_open.* = false;
    try borrow.borrow.*.namespaces.source_namespace.*.close();
    borrow.borrow.*.namespaces.source_open.* = false;
    var delayed_report_bytes: []u8 = undefined;

    try placementOnwardSuccessorExecution(scenario, .{
        .borrow = &.{
            .borrow = borrow.borrow,
            .control = borrow.control,
            .report_bytes = borrow.report_bytes,
        },
        .delayed = &borrow.delayed.delayed.*,
        .delayed_report_bytes = &delayed_report_bytes,
        .next_decision = &borrow.offered.next_decision.*,
        .route = &borrow.route.route.*,
    });

    return placementOnwardApplyDelayedReport(scenario, .{
        .report = .{
            .delayed_report_bytes = &delayed_report_bytes,
        },
        .borrow = borrow.borrow,
        .delayed = borrow.delayed,
    });
}

fn placementOnwardRejectAuthority(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.successor.successor.*.profile.authority;
        defer borrow.successor.successor.*.profile.authority = authority;
        @field(borrow.successor.successor.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            borrow.successor.successor.*.placementResolveControl(
                namespaces_view.*.scratch.*,
                "source",
                borrow.borrow.*.control.*.value,
                &borrow.route.*,
            ),
        );
        try std.testing.expectEqualDeep(
            borrow.successor.before.*,
            namespaces_view.*.successor_namespace.*.store.head,
        );
    }
    return placementOnwardResolveDelayed(scenario, .{
        .borrow = borrow.borrow,
        .delayed = borrow.delayed,
        .delayed_report_bytes = borrow.delayed_report_bytes,
        .next_decision = borrow.next_decision,
        .route = borrow.route,
        .successor = borrow.successor,
    });
}

fn placementOnwardResolveDelayed(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const context_disclosure = &borrow.borrow.*.borrow.*.disclosure;
    const p = native.placement;
    context_disclosure.*.disclosure.*.deny_runtime = true;
    try std.testing.expectError(
        error.DisclosureDenied,
        borrow.successor.successor.*.placementResolveControl(
            namespaces_view.*.scratch.*,
            "source",
            borrow.borrow.*.control.*.value,
            &borrow.route.*,
        ),
    );
    context_disclosure.*.disclosure.*.deny_runtime = false;
    const executed = try borrow.successor.successor.*.placementResolveControl(
        namespaces_view.*.scratch.*,
        "source",
        borrow.delayed.*.value,
        &borrow.route.*,
    );
    var result = try contracts.decodeOwned(
        p.ControlResolution,
        namespaces_view.*.scratch.*,
        executed,
    );
    defer result.deinit();
    const delayed_report = result.value.report;
    borrow.delayed_report_bytes.* = try contracts.encodeOwned(
        p.Signed(p.Report),
        namespaces_view.*.scratch.*,
        delayed_report,
    );
    try std.testing.expectEqualDeep(
        borrow.borrow.*.borrow.*.sites.successor_site.*,
        delayed_report.value.executor,
    );
    try std.testing.expectEqual(
        borrow.next_decision.*.value.epoch,
        delayed_report.value.custody_epoch,
    );
    const after = namespaces_view.*.successor_namespace.*.store.head;
    try std.testing.expectEqualSlices(
        u8,
        executed,
        try borrow.successor.successor.*.placementResolveControl(
            namespaces_view.*.scratch.*,
            "source",
            borrow.delayed.*.value,
            &borrow.route.*,
        ),
    );
    try std.testing.expectEqualDeep(
        after,
        namespaces_view.*.successor_namespace.*.store.head,
    );
    return placementOnwardCancelLocalExecutor(scenario, .{
        .borrow = borrow.borrow,
        .successor = borrow.successor,
    });
}

fn placementOnwardApplyDelayedReport(comptime scenario: anytype, borrow: anytype) !bool {
    _ = scenario;
    const p = native.placement;
    borrow.borrow.*.namespaces.source_namespace.* = try native.Namespace.open(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        borrow.borrow.*.namespaces.source_path.*,
    );
    borrow.borrow.*.namespaces.source_open.* = true;
    borrow.borrow.*.services.sender.* = try native.tasks.Service(OwnerTypes).init(
        borrow.borrow.*.setup.a.*,
        borrow.borrow.*.setup.io.*,
        &borrow.borrow.*.namespaces.source_namespace.*,
        borrow.borrow.*.application.assets.*,
        &borrow.borrow.*.application.application.*,
        borrow.borrow.*.application.handlers.*,
        borrow.borrow.*.controller.source_profile.*,
    );
    borrow.borrow.*.services.sender_open.* = true;
    var delayed_report = try contracts.decodeOwned(
        p.Signed(p.Report),
        borrow.borrow.*.namespaces.scratch.*,
        borrow.report.delayed_report_bytes.*,
    );
    defer delayed_report.deinit();
    try borrow.borrow.*.services.sender.*.placementApplyReport(
        borrow.borrow.*.namespaces.scratch.*,
        borrow.borrow.*.sites.subject.*.task,
        p.controlId(borrow.delayed.delayed.*.value.value),
        delayed_report.value,
    );
    return true;
}

fn placementOnwardCancelLocalExecutor(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const sites_view = &borrow.borrow.*.borrow.*.sites;
    // This process owns the executor, while the copied controller is
    // still at A. Shutdown must cancel only its actual local work.
    const current_cut = try borrow.successor.successor.*.placementCut(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*,
    );
    _ = try borrow.successor.successor.*.workspaceControl(
        namespaces_view.*.scratch.*,
        "claim-onward-executor",
        sites_view.*.subject.*.task,
        borrow.borrow.*.borrow.*.work.work_id.*,
        current_cut.execution,
        current_cut.control,
        .park,
    );
    var before_cancel = try borrow.successor.successor.*.workspaceWork(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*.task,
        borrow.borrow.*.borrow.*.work.work_id.*,
    );
    defer before_cancel.deinit();
    try std.testing.expect(!before_cancel.value.terminal());
    try std.testing.expect(borrow.successor.successor.*.owned.items.len != 0);
    const interrupt = "interrupt-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqual(@as(usize, 74), interrupt.len);
    try borrow.successor.successor.*.cancelOwned(
        namespaces_view.*.scratch.*,
        interrupt,
        "stop local executor",
    );
    return placementOnwardSettleLocalExecutor(scenario, .{
        .borrow = borrow.borrow,
        .successor = borrow.successor,
    });
}

fn placementOnwardSettleLocalExecutor(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const sites_view = &borrow.borrow.*.borrow.*.sites;
    _ = scenario;
    var after_cancel = try borrow.successor.successor.*.workspaceWork(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*.task,
        borrow.borrow.*.borrow.*.work.work_id.*,
    );
    defer after_cancel.deinit();
    try std.testing.expect(after_cancel.value.cancellation != null);
    // Cancellation can finish synchronously. Unfinished local work is
    // incomplete; a remote controller copy is not a local obligation.
    try std.testing.expectEqual(
        !after_cancel.value.terminal(),
        try borrow.successor.successor.*.shutdownIncomplete(
            namespaces_view.*.scratch.*,
        ),
    );
    var settled = false;
    for (0..512) |_| {
        _ = try borrow.successor.successor.*.pump(namespaces_view.*.scratch.*);
        if (!try borrow.successor.successor.*.shutdownIncomplete(
            namespaces_view.*.scratch.*,
        )) {
            settled = true;
            break;
        }
    }
    try std.testing.expect(settled);
    var closed_work = try borrow.successor.successor.*.workspaceWork(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*.task,
        borrow.borrow.*.borrow.*.work.work_id.*,
    );
    defer closed_work.deinit();
    try std.testing.expect(closed_work.value.terminal());
    try std.testing.expectEqual(
        .away,
        (try borrow.successor.successor.*.placementStatus(
            namespaces_view.*.scratch.*,
            .{ .task = sites_view.*.subject.*.task },
        )).?.phase,
    );
}

fn placementQueuedCutAuthority(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.borrow.*.services;
    _ = scenario;
    const p = native.placement;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = services_view.*.sender.*.profile.authority;
        defer services_view.*.sender.*.profile.authority = authority;
        const before = namespaces_view.*.source_namespace.*.store.head;
        const pending_before = try namespaces_view.*.scratch.*.dupe(
            @TypeOf(services_view.*.sender.*.placement_pending.items[0]),
            services_view.*.sender.*.placement_pending.items,
        );
        @field(services_view.*.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            services_view.*.sender.*.placementWithdraw(
                namespaces_view.*.scratch.*,
                borrow.prior.*.borrow.*.sites.subject.*.task,
                p.operationId(
                    borrow.prior.*.borrow.*.sites.source_site.*,
                    borrow.prior.*.borrow.*.sites.subject.*.task,
                    "queued-work",
                    .move,
                ),
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            namespaces_view.*.source_namespace.*.store.head,
        );
        try std.testing.expectEqualDeep(
            pending_before,
            services_view.*.sender.*.placement_pending.items,
        );
        try std.testing.expect(services_view.*.sender.*.placement_job == null);
    }
    _ = try services_view.*.sender.*.workspacePump(
        namespaces_view.*.scratch.*,
        "queued-work-progress",
        borrow.prior.*.borrow.*.sites.subject.*.task,
        .{
            .expected = .{
                .work = borrow.prior.*.borrow.*.work.work_ref.*,
                .execution_revision = borrow.prior.*.borrow.*.sites.cut.*.execution,
                .control_revision = borrow.prior.*.borrow.*.sites.cut.*.control,
            },
            .base_quantum = 1,
        },
    );
    const progressed_cut = try services_view.*.sender.*.placementCut(
        namespaces_view.*.scratch.*,
        borrow.prior.*.borrow.*.sites.subject.*,
    );
    try std.testing.expect(!std.meta.eql(borrow.prior.*.borrow.*.sites.cut.*, progressed_cut));
    try std.testing.expectEqual(
        .progressed,
        try services_view.*.sender.*.pump(namespaces_view.*.scratch.*),
    );
    const frozen = (try services_view.*.sender.*.placementStatus(
        namespaces_view.*.scratch.*,
        borrow.prior.*.borrow.*.sites.subject.*,
    )).?;
    try std.testing.expectEqual(.frozen, frozen.phase);
    try std.testing.expectEqualDeep(progressed_cut, frozen.intent.?.cut);
    try std.testing.expect(services_view.*.sender.*.placementActive());
    return true;
}

fn placementQueueExecutor(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    const queued = try borrow.prior.*.services.sender.*.workspaceCommand(
        borrow.prior.*.namespaces.scratch.*,
        "placement-queue",
        borrow.prior.*.sites.subject.*.task,
        .{ .placement = .{ .move = .{
            .operation = .{ .bytes = "withdraw-before-send" },
            .subject = .{ .work = borrow.prior.*.work.work_ref.* },
            .site = .{ .bytes = "destination" },
            .custody_epoch = 0,
        } } },
    );
    if (queued.disposition != .observed) std.debug.print("placement queue rejection: {s}\n", .{
        queued.observation_json.bytes,
    });
    try std.testing.expectEqual(.observed, queued.disposition);
    const withdrawn = try borrow.prior.*.services.sender.*.workspaceCommand(
        borrow.prior.*.namespaces.scratch.*,
        "placement-withdraw",
        borrow.prior.*.sites.subject.*.task,
        .{ .placement = .{ .withdraw = .{ .operation = .{
            .bytes = "withdraw-before-send",
        } } } },
    );
    try std.testing.expectEqual(.observed, withdrawn.disposition);
    const withdrawn_state = try native.values.fromJson(
        p.Move,
        borrow.prior.*.namespaces.scratch.*,
        (try native.json.parseAsset(
            borrow.prior.*.namespaces.scratch.*,
            withdrawn.observation_json.bytes,
            withdrawn.observation_json.bytes.len,
        )).value,
    );
    try std.testing.expect(withdrawn_state.cancelled);
    try std.testing.expect(withdrawn_state.withdraw_requested);
    try std.testing.expect(withdrawn_state.decision == null);
    const retry_withdrawn = try borrow.prior.*.services.sender.*.workspaceCommand(
        borrow.prior.*.namespaces.scratch.*,
        "placement-retry-withdrawn",
        borrow.prior.*.sites.subject.*.task,
        .{ .placement = .{ .retry = .{ .operation = .{
            .bytes = "withdraw-before-send",
        } } } },
    );
    try std.testing.expectEqual(.observed, retry_withdrawn.disposition);
    borrow.prior.*.peers.source_peers.*[0].channel = null;
    return placementPrepareExecutorObserver(scenario, .{
        .capabilities = .{
            .sites = &borrow.state.sites.*,
        },
        .application = borrow.prior.*.application,
        .channels = borrow.prior.*.channels,
        .child = borrow.prior.*.child,
        .disclosure = borrow.prior.*.disclosure,
        .generated = borrow.prior.*.generated,
        .input = borrow.prior.*.input,
        .namespaces = borrow.prior.*.namespaces,
        .peers = borrow.prior.*.peers,
        .services = borrow.prior.*.services,
        .setup = borrow.prior.*.setup,
        .sites = borrow.prior.*.sites,
        .start = borrow.prior.*.start,
        .work = borrow.prior.*.work,
    });
}

fn placementFinishExecutorObserver(comptime scenario: anytype, borrow: anytype) !void {
    if (try placementRootSuccession(scenario, .{
        .fixture = .{
            .a = &borrow.prior.*.setup.a.*,
            .application = &borrow.prior.*.application.application.*,
            .assets = &borrow.prior.*.application.assets.*,
            .cut = &borrow.prior.*.sites.cut.*,
            .destination_config = &borrow.prior.*.channels.destination_config.*,
            .destination_namespace = &borrow.prior.*.namespaces.destination_namespace.*,
            .destination_path = &borrow.prior.*.namespaces.destination_path.*,
            .destination_site = &borrow.prior.*.sites.destination_site.*,
            .diagnostic = &borrow.prior.*.child.diagnostic.*,
            .document = &borrow.prior.*.child.document.*,
            .executor_observer = &borrow.state.executor_observer.*,
            .handlers = &borrow.prior.*.application.handlers.*,
            .io = &borrow.prior.*.setup.io.*,
            .length = &borrow.prior.*.namespaces.length.*,
            .parent = &borrow.prior.*.child.parent.*,
            .path_buffer = &borrow.prior.*.namespaces.path_buffer.*,
            .phase = &borrow.prior.*.setup.phase.*,
            .profile = &borrow.prior.*.application.profile.*,
            .program = &borrow.prior.*.child.program.*,
            .scratch = &borrow.prior.*.namespaces.scratch.*,
            .sender = &borrow.prior.*.services.sender.*,
            .sender_open = &borrow.prior.*.services.sender_open.*,
            .sites = &borrow.prior.*.capabilities.sites.*,
            .source_config = &borrow.prior.*.channels.source_config.*,
            .source_key = &borrow.prior.*.sites.source_key.*,
            .source_namespace = &borrow.prior.*.namespaces.source_namespace.*,
            .source_open = &borrow.prior.*.namespaces.source_open.*,
            .source_path = &borrow.prior.*.namespaces.source_path.*,
            .specialized = &borrow.prior.*.child.specialized.*,
            .start_command = &borrow.prior.*.start.start_command.*,
            .subject = &borrow.prior.*.sites.subject.*,
            .successor_config = &borrow.prior.*.channels.successor_config.*,
            .successor_path = &borrow.prior.*.namespaces.successor_path.*,
            .successor_peers = &borrow.prior.*.peers.successor_peers.*,
            .work_id = &borrow.prior.*.work.work_id.*,
            .work_ref = &borrow.prior.*.work.work_ref.*,
        },
    })) return;

    return placementFreezeChild(scenario, .{
        .application = borrow.prior.*.application,
        .channels = borrow.prior.*.channels,
        .child = borrow.prior.*.child,
        .disclosure = borrow.prior.*.disclosure,
        .generated = borrow.prior.*.generated,
        .namespaces = borrow.prior.*.namespaces,
        .peers = borrow.prior.*.peers,
        .services = borrow.prior.*.services,
        .setup = borrow.prior.*.setup,
        .sites = borrow.prior.*.sites,
        .work = borrow.prior.*.work,
    });
}

fn placementFreezeAuthority(comptime scenario: anytype, borrow: anytype) !void {
    try placementRejectForeignFreeze(scenario, .{
        .borrow = &borrow,
    });

    if (scenario == .work) {
        try std.testing.expect(borrow.prior.*.services.sender.*.active != null);
        try std.testing.expect(borrow.prior.*.services.sender.*.active.?.subject == .root);
        try std.testing.expect(borrow.prior.*.services.sender.*.active.?.root_control != null);
    }

    if (try placementAbortedChildCancellation(scenario, .{
        .borrow = &borrow.prior.*,
    })) return;

    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.prior.*.services.sender.*.workspaceControl(
            borrow.prior.*.namespaces.scratch.*,
            "source-must-stop",
            borrow.prior.*.sites.subject.*.task,
            borrow.prior.*.work.work_id.*,
            borrow.prior.*.sites.cut.*.execution,
            borrow.prior.*.sites.cut.*.control,
            .advance,
        ),
    );
    return placementCheckDisclosedOffer(scenario, .{
        .application = borrow.prior.*.application,
        .channels = borrow.prior.*.channels,
        .child = borrow.prior.*.child,
        .disclosure = borrow.prior.*.disclosure,
        .generated = borrow.prior.*.generated,
        .namespaces = borrow.prior.*.namespaces,
        .peers = borrow.prior.*.peers,
        .services = borrow.prior.*.services,
        .setup = borrow.prior.*.setup,
        .sites = borrow.prior.*.sites,
        .work = borrow.prior.*.work,
    });
}

fn placementAwaitAbortedChild(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.borrow.*.services;
    for (0..512) |_| {
        _ = try services_view.*.sender.*.pump(namespaces_view.*.scratch.*);
        var current = try services_view.*.sender.*.task(
            namespaces_view.*.scratch.*,
            borrow.prior.*.borrow.*.sites.subject.*.task,
        );
        defer current.deinit();
        if (current.value.terminal()) {
            borrow.state.terminal.* = true;
            break;
        }
    }
    try std.testing.expect(borrow.state.terminal.*);
    // Remove the terminal root's ordinary runnable entry. The retained
    // cancellation still owns the frozen child obligation.
    for (0..8) |_| if (try services_view.*.sender.*.pump(
        namespaces_view.*.scratch.*,
    ) == .idle) break;
    try std.testing.expect(services_view.*.sender.*.owned.items.len != 0);
    try std.testing.expect(
        try services_view.*.sender.*.shutdownIncomplete(
            namespaces_view.*.scratch.*,
        ),
    );
    return placementReleaseRefusedTransfer(scenario, .{
        .prior = &borrow,
    });
}

fn placementCheckDisclosedGrant(comptime scenario: anytype, borrow: anytype) !void {
    try std.testing.expect(
        (try borrow.prior.*.services.sender.*.placementStatus(
            borrow.prior.*.namespaces.scratch.*,
            borrow.prior.*.sites.subject.*,
        )).?.offer == null,
    );
    borrow.prior.*.disclosure.disclosure.*.deny_runtime = false;
    if (borrow.prior.*.generated.generated.*) |derived| {
        borrow.prior.*.disclosure.disclosure.*.denied_dependency = try nativeIdentity(
            derived.candidate,
        );
        std.debug.print("semantic placement: denied candidate offer at {d}ms\n", .{
            sharedElapsed(borrow.prior.*.setup.placement_started.*) / std.time.ns_per_ms,
        });
        try std.testing.expectError(
            error.DisclosureDenied,
            offerPlacement(
                &borrow.prior.*.services.sender.*,
                borrow.prior.*.sites.subject.*,
                "destination",
                borrow.state.archive_path.*,
            ),
        );
        try std.testing.expect(
            (try borrow.prior.*.services.sender.*.placementStatus(
                borrow.prior.*.namespaces.scratch.*,
                borrow.prior.*.sites.subject.*,
            )).?.offer == null,
        );
        borrow.prior.*.disclosure.disclosure.*.denied_dependency = null;
    }
    if (scenario == .work) std.debug.print("semantic placement: offer retry at {d}ms\n", .{
        sharedElapsed(borrow.prior.*.setup.placement_started.*) / std.time.ns_per_ms,
    });
    return placementInspectOffer(scenario, .{
        .offered = .{
            .archive_path = &borrow.state.archive_path.*,
        },
        .application = borrow.prior.*.application,
        .channels = borrow.prior.*.channels,
        .child = borrow.prior.*.child,
        .disclosure = borrow.prior.*.disclosure,
        .generated = borrow.prior.*.generated,
        .namespaces = borrow.prior.*.namespaces,
        .peers = borrow.prior.*.peers,
        .services = borrow.prior.*.services,
        .setup = borrow.prior.*.setup,
        .sites = borrow.prior.*.sites,
        .work = borrow.prior.*.work,
    });
}

fn placementInspectOfferIdentity(comptime scenario: anytype, borrow: anytype) !void {
    try std.testing.expectEqualDeep(
        borrow.state.offer.*,
        try offerPlacement(
            &borrow.prior.*.services.sender.*,
            borrow.prior.*.sites.subject.*,
            "destination",
            borrow.prior.*.offered.archive_path.*,
        ),
    );
    borrow.prior.*.peers.source_peers.*[0].disclosure_policy[0] ^= 1;
    try std.testing.expectError(
        error.IncompatibleProfile,
        offerPlacement(
            &borrow.prior.*.services.sender.*,
            borrow.prior.*.sites.subject.*,
            "destination",
            borrow.prior.*.offered.archive_path.*,
        ),
    );
    borrow.prior.*.peers.source_peers.*[0].disclosure_policy[0] ^= 1;
    borrow.prior.*.services.sender.*.profile.runtime_identity[0] ^= 1;
    try std.testing.expectError(
        error.IncompatibleProfile,
        offerPlacement(
            &borrow.prior.*.services.sender.*,
            borrow.prior.*.sites.subject.*,
            "destination",
            borrow.prior.*.offered.archive_path.*,
        ),
    );
    borrow.prior.*.services.sender.*.profile.runtime_identity[0] ^= 1;
    borrow.prior.*.services.sender.*.profile.authority.disclosure = false;
    return placementInspectOfferProfile(scenario, .{
        .prior = &borrow,
    });
}

fn placementRejectReceiverReplay(comptime scenario: anytype, borrow: anytype) !void {
    try std.testing.expectError(
        error.Denied,
        acceptPlacement(
            &borrow.prior.*.services.receiver.*,
            "accept",
            "source",
            borrow.prior.*.transfer.offer.*,
            borrow.prior.*.offered.archive_path.*,
        ),
    );
    try std.testing.expectEqualDeep(
        borrow.state.receiver_head.*,
        borrow.prior.*.namespaces.destination_namespace.*.store.head,
    );
    borrow.prior.*.services.receiver.*.profile.authority.disclosure = true;
    borrow.prior.*.peers.destination_peers.*[0].compatibility.admission[0] ^= 1;
    try std.testing.expectError(
        error.IncompatibleProfile,
        acceptPlacement(
            &borrow.prior.*.services.receiver.*,
            "accept",
            "source",
            borrow.prior.*.transfer.offer.*,
            borrow.prior.*.offered.archive_path.*,
        ),
    );
    try std.testing.expectEqualDeep(
        borrow.state.receiver_head.*,
        borrow.prior.*.namespaces.destination_namespace.*.store.head,
    );
    borrow.prior.*.peers.destination_peers.*[0].compatibility.admission[0] ^= 1;
    borrow.prior.*.disclosure.disclosure.*.deny_runtime = true;
    return placementRejectAlteredOffer(scenario, .{
        .prior = &borrow,
    });
}

fn placementInspectAcceptedChild(comptime scenario: anytype, borrow: anytype) !void {
    try std.testing.expectEqualDeep(
        borrow.state.accepted.*,
        try borrow.prior.*.services.receiver.*.placementRefuse(
            borrow.prior.*.namespaces.scratch.*,
            "source",
            borrow.prior.*.transfer.offer.*,
            .withdrawn,
        ),
    );
    // Lose the acceptance reply and restart the destination. Only its work is
    // executable; its copied controller remains at the original namespace.
    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.prior.*.services.receiver.*.resumeTask(
            borrow.prior.*.namespaces.scratch.*,
            "copied-controller",
            borrow.prior.*.sites.subject.*.task,
            1,
        ),
    );
    try borrow.prior.*.services.receiver.*.close(borrow.prior.*.setup.a.*);
    borrow.prior.*.services.receiver_open.* = false;
    borrow.prior.*.services.receiver_compiler_facts.*.deinit();
    borrow.prior.*.services.receiver_compiler_facts.* = .{ .allocator = borrow.prior.*.setup.a.* };
    try borrow.prior.*.namespaces.destination_namespace.*.close();
    borrow.prior.*.namespaces.destination_open.* = false;
    borrow.prior.*.namespaces.destination_namespace.* = try native.Namespace.open(
        borrow.prior.*.setup.a.*,
        borrow.prior.*.setup.io.*,
        borrow.prior.*.namespaces.destination_path.*,
    );
    borrow.prior.*.namespaces.destination_open.* = true;
    return placementResumeAcceptedChild(scenario, .{
        .prior = &borrow,
    });
}

fn placementControllerAuthority(comptime scenario: anytype, borrow: anytype) !void {
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.prior.*.services.sender.*.profile.authority;
        defer borrow.prior.*.services.sender.*.profile.authority = authority;
        const before = borrow.prior.*.namespaces.source_namespace.*.store.head;
        @field(borrow.prior.*.services.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            borrow.prior.*.services.sender.*.placementApplyDecision(
                borrow.prior.*.namespaces.scratch.*,
                borrow.prior.*.sites.subject.*,
                borrow.prior.*.acceptance.accepted.*,
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            borrow.prior.*.namespaces.source_namespace.*.store.head,
        );
    }
    try borrow.prior.*.services.sender.*.placementApplyDecision(
        borrow.prior.*.namespaces.scratch.*,
        borrow.prior.*.sites.subject.*,
        borrow.prior.*.acceptance.accepted.*,
    );
    try borrow.prior.*.services.sender.*.placementApplyDecision(
        borrow.prior.*.namespaces.scratch.*,
        borrow.prior.*.sites.subject.*,
        borrow.prior.*.acceptance.accepted.*,
    );
    try std.testing.expectEqual(
        .away,
        (try borrow.prior.*.services.sender.*.placementStatus(
            borrow.prior.*.namespaces.scratch.*,
            borrow.prior.*.sites.subject.*,
        )).?.phase,
    );
    return placementControllerPolicy(scenario, .{
        .prior = &borrow,
    });
}

fn placementRemoteControllerAuthority(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.prior.*.services.sender.*.profile.authority;
        defer borrow.prior.*.services.sender.*.profile.authority = authority;
        const before = borrow.prior.*.namespaces.source_namespace.*.store.head;
        @field(borrow.prior.*.services.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            borrow.prior.*.services.sender.*.placementControl(
                borrow.prior.*.namespaces.scratch.*,
                "remote-inspect",
                borrow.prior.*.sites.subject.*.task,
                .{ .inspect = .{
                    .work = borrow.prior.*.work.work_ref.*,
                } },
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            borrow.prior.*.namespaces.source_namespace.*.store.head,
        );
    }
    try std.testing.expectError(
        error.OperationConflict,
        borrow.prior.*.services.sender.*.placementControl(
            borrow.prior.*.namespaces.scratch.*,
            "remote-inspect",
            borrow.prior.*.sites.subject.*.task,
            .{ .park = .{
                .work = borrow.prior.*.work.work_ref.*,
                .execution_revision = borrow.prior.*.sites.cut.*.execution,
                .control_revision = borrow.prior.*.sites.cut.*.control,
            } },
        ),
    );
    const controller_subject: p.Subject = .{ .task = borrow.prior.*.sites.subject.*.task };
    const controller_cut = try borrow.prior.*.services.sender.*.placementCut(
        borrow.prior.*.namespaces.scratch.*,
        controller_subject,
    );
    return placementRemoteControllerPolicy(scenario, .{
        .state = .{
            .controller_cut = &controller_cut,
            .controller_subject = &controller_subject,
        },
        .prior = &borrow,
    });
}

fn placementReopenAcceptedController(comptime scenario: anytype, borrow: anytype) !void {
    borrow.prior.*.namespaces.destination_namespace.* = try native.Namespace.open(
        borrow.prior.*.setup.a.*,
        borrow.prior.*.setup.io.*,
        borrow.prior.*.namespaces.destination_path.*,
    );
    borrow.prior.*.namespaces.destination_open.* = true;
    borrow.prior.*.services.receiver.* = try native.tasks.Service(OwnerTypes).init(
        borrow.prior.*.setup.a.*,
        borrow.prior.*.setup.io.*,
        &borrow.prior.*.namespaces.destination_namespace.*,
        borrow.prior.*.application.assets.*,
        &borrow.prior.*.application.application.*,
        borrow.prior.*.application.handlers.*,
        borrow.prior.*.receiver.resumed_profile.*,
    );
    borrow.prior.*.services.receiver_open.* = true;
    try std.testing.expectError(
        error.MissingArtifact,
        borrow.prior.*.services.receiver.*.namespace.store.objectReference(
            borrow.prior.*.advanced.advanced_controller.*.checkpoint.digest,
            null,
        ),
    );
    try std.testing.expectError(
        error.StaleController,
        borrow.prior.*.services.receiver.*.placementExecuteControl(
            borrow.prior.*.namespaces.scratch.*,
            "successor",
            borrow.state.successor_control.*.value,
        ),
    );
    return placementAcceptedControllerAuthority(scenario, .{
        .prior = &borrow,
    });
}

fn placementRejectFrozenStart(comptime scenario: anytype, borrow: anytype) !bool {
    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.prior.*.fixture.sender.*.workspaceBuild(
            borrow.prior.*.fixture.scratch.*,
            "frozen-new-build",
            borrow.prior.*.fixture.parent.*.receipt.task,
            borrow.prior.*.fixture.document.*,
            &borrow.prior.*.fixture.diagnostic.*,
        ),
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.prior.*.fixture.sender.*.workspaceSpecialize(
            borrow.prior.*.fixture.scratch.*,
            "frozen-new-specialization",
            borrow.prior.*.fixture.parent.*.receipt.task,
            borrow.prior.*.fixture.program.*.receipt.workspace.?,
        ),
    );
    try std.testing.expectEqual(
        .rejected,
        (try borrow.prior.*.fixture.sender.*.workspaceCommand(
            borrow.prior.*.fixture.scratch.*,
            "frozen-new-start",
            borrow.prior.*.fixture.parent.*.receipt.task,
            borrow.prior.*.fixture.start_command.*,
        )).disposition,
    );
    try std.testing.expectEqual(
        .rejected,
        (try borrow.prior.*.fixture.sender.*.workspaceCommand(
            borrow.prior.*.fixture.scratch.*,
            "frozen-new-sites",
            borrow.prior.*.fixture.subject.*.task,
            .{ .placement = .{ .sites = .{} } },
        )).disposition,
    );
    return placementRejectFrozenCommands(scenario, .{
        .prior = &borrow,
    });
}

fn placementAwaitRootCompletion(comptime scenario: anytype, borrow: anytype) !void {
    const state_incomplete_park = &borrow.state.incomplete_park;
    const state_refreshed_park = &borrow.state.refreshed_park;

    const p = native.placement;
    for (0..8) |_| {
        if (try placementRootCompletionTurn(scenario, .{
            .borrow = &borrow.prior.*,
            .completed = &borrow.state.completed.*,
            .incomplete_park = &state_incomplete_park.*.*,
            .inspection_reports = &borrow.state.inspection_reports.*,
            .parked = &borrow.state.parked.*,
            .parked_task_watermark = &borrow.state.parked_task_watermark.*,
            .prior_command = &borrow.state.prior_command.*,
            .prior_report = &borrow.state.prior_report.*,
            .refreshed_park = &state_refreshed_park.*.*,
        })) break;
    }
    try std.testing.expect(
        borrow.state.completed.* and borrow.state.parked.* and
            state_incomplete_park.*.* and state_refreshed_park.*.*,
    );
    try std.testing.expectEqual(@as(u64, 3), borrow.state.inspection_reports.*);
    const last = borrow.state.prior_report.*.?.value.work_state.?;
    const expected: contracts.workspace.Expected = .{
        .work = borrow.prior.*.borrow.*.fixture.work_ref.*,
        .execution_revision = last.execution_revision,
        .control_revision = last.control_revision,
    };
    const stopped_commands = [_]contracts.workspace.Work{
        .{ .advance = expected },
        .{ .delegate = .{ .expected = expected, .policy = .{} } },
        .{ .pump = .{ .expected = expected, .base_quantum = 1 } },
        .{ .request_cut = .{ .expected = expected, .level = .outer_execution } },
        .{
            .realize = .{
                .expected = expected,
                .realization_revision = borrow.state.running_child.*.value.realization_revision,
                .runtime = .{ .packaged = .{} },
            },
        },
    };
    var stopped_controls: [stopped_commands.len]p.Signed(p.Control) = undefined;

    try placementStoppedControllerCommands(scenario, .{
        .borrow = &borrow.prior.*,
        .stopped_commands = &stopped_commands,
        .stopped_controls = &stopped_controls,
    });

    try placementStoppedControllerReports(scenario, .{
        .borrow = &borrow.prior.*,
        .stopped_controls = &stopped_controls,
    });
}

fn placementAwaitChildCancellation(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.borrow.*.borrow.*.sites;
    const p = native.placement;
    var cancelling = try services_view.*.sender.*.workspaceWork(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*.task,
        borrow.state.child_id.*,
    );
    defer cancelling.deinit();
    try std.testing.expect(!cancelling.value.terminal());
    try std.testing.expectEqual(.queued, cancelling.value.schedule);
    if (borrow.prior.*.parked.* == 1) _ = try services_view.*.sender.*.workspaceControl(
        namespaces_view.*.scratch.*,
        try std.fmt.allocPrint(
            namespaces_view.*.scratch.*,
            "{s}-park",
            .{borrow.state.operation.*},
        ),
        sites_view.*.subject.*.task,
        borrow.state.child_id.*,
        cancelling.value.execution_revision,
        cancelling.value.control_revision,
        .park,
    );
    const child_subject: p.Subject = .{
        .task = sites_view.*.subject.*.task,
        .work = borrow.state.child_id.*,
    };
    const transfer: [32]u8 = @splat(@intCast(90 + borrow.prior.*.parked.*));
    _ = try freezePlacement(
        &services_view.*.sender.*,
        child_subject,
        "destination",
        try services_view.*.sender.*.placementCut(
            namespaces_view.*.scratch.*,
            child_subject,
        ),
        transfer,
    );
    var refusal: ?p.Signed(p.Decision) = null;
    return placementInspectChildCancellation(scenario, .{
        .state = .{
            .child_subject = &child_subject,
            .refusal = &refusal,
            .transfer = &transfer,
        },
        .prior = &borrow,
    });
}

fn placementInspectCancelledRoot(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.borrow.*.borrow.*.sites;
    const p = native.placement;
    if (scenario == .cancel_refused) {
        const root_archive = try std.fmt.allocPrint(
            namespaces_view.*.scratch.*,
            "{s}/{s}.par",
            .{
                namespaces_view.*.path_buffer.*[0..namespaces_view.*.length.*],
                borrow.state.operation.*,
            },
        );
        const root_offer = try offerPlacement(
            &services_view.*.sender.*,
            borrow.state.root_subject.*,
            "destination",
            root_archive,
        );
        borrow.state.refusal.* = try p.sign(
            p.Decision,
            namespaces_view.*.scratch.*,
            sites_view.*.destination_key.*,
            .{
                .transfer = borrow.state.transfer.*,
                .offer_digest = try p.digest(
                    p.Offer,
                    namespaces_view.*.scratch.*,
                    root_offer.value,
                ),
                .source = sites_view.*.source_site.*,
                .destination = sites_view.*.destination_site.*,
                .epoch = root_offer.value.intent.epoch + 1,
                .verdict = .{
                    .refused = .withdrawn,
                },
            },
        );
    }
    if (borrow.prior.*.parked.* == 1) try services_view.*.sender.*.park(
        namespaces_view.*.scratch.*,
    );
    return placementReleaseCancelledRoot(scenario, .{
        .prior = &borrow,
    });
}

fn placementInspectRefusedChild(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.borrow.*.borrow.*.sites;
    const p = native.placement;
    try std.testing.expectEqualDeep(
        borrow.state.fresh_intent.*,
        try freezePlacement(
            &services_view.*.sender.*,
            sites_view.*.subject.*,
            "destination",
            borrow.state.changed_cut.*,
            @splat(17),
        ),
    );
    const other_subject: p.Subject = .{ .task = sites_view.*.subject.*.task };
    const other_cut = try services_view.*.sender.*.placementCut(
        namespaces_view.*.scratch.*,
        other_subject,
    );
    try std.testing.expectError(
        error.OperationConflict,
        freezePlacement(
            &services_view.*.sender.*,
            other_subject,
            "destination",
            other_cut,
            @splat(17),
        ),
    );
    try std.testing.expectEqual(
        .local,
        (try services_view.*.sender.*.placementStatus(
            namespaces_view.*.scratch.*,
            other_subject,
        )).?.phase,
    );
    return placementRejectUnrelatedRefusal(scenario, .{
        .prior = &borrow,
    });
}

fn placementReopenAcknowledgedController(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.prior.*.borrow.*.fixture;
    _ = scenario;
    {
        var ns = try native.Namespace.open(
            fixture_view.*.a.*,
            fixture_view.*.io.*,
            fixture_view.*.destination_path.*,
        );
        defer support.expectCleanup(ns.close());
        var executor = try native.tasks.Service(OwnerTypes).init(
            fixture_view.*.a.*,
            fixture_view.*.io.*,
            &ns,
            fixture_view.*.assets.*,
            &fixture_view.*.application.*,
            fixture_view.*.handlers.*,
            borrow.prior.*.borrow.*.ack.ack_destination_profile.*,
        );
        defer support.expectCleanup(executor.close(fixture_view.*.a.*));
        borrow.state.work_decision.* = try acceptPlacement(
            &executor,
            "ack-work",
            "source",
            borrow.state.work_offer.*,
            borrow.state.work_archive.*,
        );
    }
    fixture_view.*.source_namespace.* = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.source_path.*,
    );
    fixture_view.*.source_open.* = true;
    fixture_view.*.sender.* = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &fixture_view.*.source_namespace.*,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.prior.*.borrow.*.ack.ack_source_profile.*,
    );
    fixture_view.*.sender_open.* = true;
    try fixture_view.*.sender.*.placementApplyDecision(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*,
        borrow.state.work_decision.*,
    );
    fixture_view.*.source_peers.*[0].channel = .{
        .argv = &.{"/usr/bin/false"},
        .remote_name = "source",
    };
}

fn placementSelectRootCloseCommand(comptime scenario: anytype, borrow: anytype) !bool {
    const state_closing_controller = &borrow.state.closing_controller;

    const fixture_view = &borrow.prior.*.borrow.*.borrow.*.borrow.*.fixture;
    const context_completed = &borrow.prior.*.borrow.*.completed;
    if (!context_completed.*.*) {
        for (0..512) |turn| {
            var current = try state_closing_controller.*.*.task(
                fixture_view.*.scratch.*,
                fixture_view.*.subject.*.task,
            );
            defer current.deinit();
            if (current.value.terminal()) {
                try std.testing.expectEqual(.completed, current.value.outcome_kind);
                try std.testing.expect(current.value.cancellation == null);
                context_completed.*.* = true;
                break;
            }
            if (current.value.schedule == .parked) _ = try state_closing_controller.*.*.resumeTask(
                fixture_view.*.scratch.*,
                try std.fmt.allocPrint(
                    fixture_view.*.scratch.*,
                    "complete-controller-{d}",
                    .{turn},
                ),
                fixture_view.*.subject.*.task,
                current.value.revision,
            );
            _ = try state_closing_controller.*.*.pump(
                fixture_view.*.scratch.*,
            );
        }
        try std.testing.expect(context_completed.*.*);
        try std.testing.expect(
            try state_closing_controller.*.*.shutdownIncomplete(
                fixture_view.*.scratch.*,
            ),
        );
    }
    return placementSelectRootSettlement(scenario, .{
        .prior = &borrow,
    });
}

fn placementExecuteRootCloseCommand(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.prior.*.borrow.*.borrow.*.borrow.*.fixture;
    const inspection_reports_view = &borrow.prior.*.borrow.*.inspection_reports;
    const parked_view = &borrow.prior.*.borrow.*.parked;
    const p = native.placement;
    if (borrow.prior.*.selected_command.*.value.command == .park) {
        try placementObserveParkCommand(scenario, .{
            .borrow = &borrow,
        });
    } else if (borrow.prior.*.borrow.*.incomplete_park.*) {
        try std.testing.expect(borrow.state.result.*.value.value.work_state.?.parkSettled());
        try std.testing.expectEqualDeep(
            fixture_view.*.work_ref.*,
            borrow.prior.*.borrow.*.prior_command.*.?.value.command.inspect.work,
        );
        var observed_parent = try borrow.state.closing_executor.*.task(
            fixture_view.*.scratch.*,
            fixture_view.*.subject.*.task,
        );
        defer observed_parent.deinit();
        try std.testing.expectEqual(
            borrow.prior.*.borrow.*.parked_task_watermark.*,
            observed_parent.value.event_high,
        );
        inspection_reports_view.*.* += 1;
        if (inspection_reports_view.*.* < 3) {
            var incomplete = borrow.state.result.*.value.value;
            incomplete.work_state.?.park_complete = false;
            borrow.prior.*.borrow.*.prior_report.* = try p.sign(
                p.Report,
                fixture_view.*.scratch.*,
                fixture_view.*.source_key.*,
                incomplete,
            );
        } else {
            parked_view.*.* = true;
            borrow.prior.*.borrow.*.refreshed_park.* = true;
        }
    }
}

fn placementCompareRemoteDisposal(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.borrow.*.borrow.*.namespaces;
    const sites_view = &borrow.prior.*.borrow.*.borrow.*.sites;
    const setup_view = &borrow.prior.*.borrow.*.borrow.*.setup;
    const p = native.placement;
    if (borrow.prior.*.borrow.*.iteration.* == 0) {
        try std.testing.expect(
            !try borrow.state.successor.*.associatedWorkDisposed(
                namespaces_view.*.scratch.*,
                sites_view.*.subject.*.task,
            ),
        );
        if (borrow.prior.*.borrow.*.borrow.*.generated.generated.*) |derived| {
            setup_view.*.phase.* = "shared guest five-arm continuation comparison";
            try sharedSuccessorComparison(
                namespaces_view.*.scratch.*,
                &setup_view.*.meter.*,
                &borrow.state.successor.*,
                sites_view.*.subject.*.task,
                borrow.prior.*.borrow.*.borrow.*.child.selected_program.*,
                derived,
            );
        }
        _ = try borrow.state.successor.*.requestCancel(
            namespaces_view.*.scratch.*,
            "cancel-with-remote-work",
            sites_view.*.subject.*.task,
            "controller stopped",
        );
        const replayed_control = try borrow.state.successor.*.placementControl(
            namespaces_view.*.scratch.*,
            "new-controller-inspect",
            sites_view.*.subject.*.task,
            .{ .inspect = .{
                .work = borrow.prior.*.borrow.*.borrow.*.work.work_ref.*,
            } },
        );
        try std.testing.expectEqualSlices(
            u8,
            try contracts.encodeOwned(
                p.Signed(p.Control),
                namespaces_view.*.scratch.*,
                borrow.prior.*.borrow.*.borrow.*.controller_acceptance.successor_control.*.value,
            ),
            replayed_control,
        );
    }
    setup_view.*.phase.* = "acknowledge explicit remote park";
    return placementAcknowledgeRemoteDisposal(scenario, .{
        .prior = &borrow,
    });
}

fn placementInspectRemoteDisposal(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.prior.*.borrow.*.borrow.*.namespaces;
    const observer_stopped_view = &borrow.prior.*.borrow.*.observer_stopped;
    const cleanup_control_view = &borrow.prior.*.borrow.*.cleanup_control;
    const cleanup_report_view = &borrow.prior.*.borrow.*.cleanup_report;
    const setup_view = &borrow.prior.*.borrow.*.borrow.*.setup;
    const parked_once_view = &borrow.prior.*.borrow.*.parked_once;
    _ = scenario;
    cleanup_report_view.*.* = borrow.state.decoded_report.*.value;
    setup_view.*.phase.* = "check remote observer stop report";
    if (borrow.state.at_source.*) {
        try std.testing.expectEqualDeep(
            try nativeIdentity(borrow.prior.*.borrow.*.borrow.*.observer.remote_observer.*.work),
            cleanup_control_view.*.*.value.subject.work.?,
        );
        const stopping = cleanup_control_view.*.*.value.command == .stop_observing;
        try std.testing.expectEqual(
            !stopping,
            cleanup_report_view.*.*.value.work_state.?.observer_active,
        );
        observer_stopped_view.*.* = observer_stopped_view.*.* or stopping;
    }
    setup_view.*.phase.* = "check remote cleanup disposition";
    if (cleanup_report_view.*.*.value.reply.disposition == .rejected) {
        try std.testing.expect(
            parked_once_view.*.* and !borrow.prior.*.borrow.*.resumed_after_park.*,
        );
        try std.testing.expect(cleanup_control_view.*.*.value.command == .pump);
        try std.testing.expect(
            cleanup_report_view.*.*.value.work_state.?.explicitly_parked,
        );
    } else try std.testing.expectEqual(
        .observed,
        cleanup_report_view.*.*.value.reply.disposition,
    );
    try std.testing.expectEqualSlices(
        u8,
        borrow.state.bytes.*,
        try borrow.state.executor.*.placementExecuteControl(
            namespaces_view.*.scratch.*,
            "successor",
            cleanup_control_view.*.*,
        ),
    );
    if (!parked_once_view.*.* and cleanup_control_view.*.*.value.command == .cancel) {
        const current = cleanup_report_view.*.*.value.work_state.?;
        _ = try borrow.state.executor.*.workspaceControl(
            namespaces_view.*.scratch.*,
            "park-after-controller-cancel",
            borrow.prior.*.borrow.*.borrow.*.sites.subject.*.task,
            borrow.prior.*.borrow.*.borrow.*.work.work_id.*,
            current.execution_revision,
            current.control_revision,
            .park,
        );
        parked_once_view.*.* = true;
    }
}

fn placementReleaseRefusedTransfer(comptime scenario: anytype, borrow: anytype) !bool {
    const state_setup = &borrow.prior.*.prior.*.borrow.*.setup;

    const namespaces_view = &borrow.prior.*.prior.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.borrow.*.services;
    const sites_view = &borrow.prior.*.prior.*.borrow.*.sites;
    if (borrow.prior.*.state.refused.*) |decision| {
        state_setup.*.phase.* = "release refused transfer before identity retry";
        try services_view.*.sender.*.placementApplyDecision(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*,
            decision,
        );
        try services_view.*.sender.*.placementApplyDecision(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*,
            decision,
        );
    } else try services_view.*.sender.*.placementAbortUnsent(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*,
        @splat(14),
    );
    var disposed = false;
    for (0..512) |_| {
        _ = try services_view.*.sender.*.pump(namespaces_view.*.scratch.*);
        var current = try services_view.*.sender.*.task(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*.task,
        );
        defer current.deinit();
        if (try services_view.*.sender.*.taskCleanupComplete(
            namespaces_view.*.scratch.*,
            current.value,
        )) {
            disposed = true;
            break;
        }
    }
    try std.testing.expect(disposed);
    try std.testing.expect(
        !try services_view.*.sender.*.shutdownIncomplete(
            namespaces_view.*.scratch.*,
        ),
    );

    try placementRefusedChildWitness(scenario, .{
        .borrow = &borrow.prior.*.prior.*,
        .refused = &borrow.prior.*.state.refused.*,
    });

    return true;
}

fn placementInspectOfferProfile(comptime scenario: anytype, borrow: anytype) !void {
    const context_namespaces = &borrow.prior.*.prior.*.namespaces;
    const context_services = &borrow.prior.*.prior.*.services;
    const context_offered = &borrow.prior.*.prior.*.offered;
    try std.testing.expectError(
        error.Denied,
        offerPlacement(
            &context_services.*.sender.*,
            borrow.prior.*.prior.*.sites.subject.*,
            "destination",
            context_offered.*.archive_path.*,
        ),
    );
    context_services.*.sender.*.profile.authority.disclosure = true;
    try std.testing.expectError(
        error.InvalidTransfer,
        context_services.*.sender.*.placementAbortUnsent(
            context_namespaces.*.scratch.*,
            borrow.prior.*.prior.*.sites.subject.*,
            @splat(14),
        ),
    );
    if (scenario == .work or scenario == .onward) try context_services.*.sender.*.park(
        context_namespaces.*.scratch.*,
    );

    try placementOnwardSourceWitness(scenario, .{
        .borrow = &borrow.prior.*.prior.*,
    });

    try context_services.*.sender.*.close(borrow.prior.*.prior.*.setup.a.*);
    context_services.*.sender_open.* = false;
    try context_namespaces.*.source_namespace.*.close();
    context_namespaces.*.source_open.* = false;
    context_services.*.sender_compiler_facts.*.deinit();
    context_services.*.sender_compiler_facts.* = .{ .allocator = borrow.prior.*.prior.*.setup.a.* };

    try placementOnwardDestinationWitness(scenario, .{
        .borrow = &borrow.prior.*.prior.*,
    });

    try placementOnwardRefusalWitness(scenario, .{
        .borrow = &borrow.prior.*.prior.*,
    });

    context_namespaces.*.destination_namespace.* = try native.Namespace.open(
        borrow.prior.*.prior.*.setup.a.*,
        borrow.prior.*.prior.*.setup.io.*,
        context_namespaces.*.destination_path.*,
    );
    return placementOpenReceiver(scenario, .{
        .transfer = .{
            .offer = &borrow.prior.*.state.offer.*,
        },
        .application = borrow.prior.*.prior.*.application,
        .channels = borrow.prior.*.prior.*.channels,
        .child = borrow.prior.*.prior.*.child,
        .disclosure = borrow.prior.*.prior.*.disclosure,
        .generated = borrow.prior.*.prior.*.generated,
        .namespaces = context_namespaces.*,
        .offered = context_offered.*,
        .peers = borrow.prior.*.prior.*.peers,
        .services = context_services.*,
        .setup = borrow.prior.*.prior.*.setup,
        .sites = borrow.prior.*.prior.*.sites,
        .work = borrow.prior.*.prior.*.work,
    });
}

fn placementRejectAlteredOffer(comptime scenario: anytype, borrow: anytype) !void {
    try std.testing.expectError(
        error.DisclosureDenied,
        acceptPlacement(
            &borrow.prior.*.prior.*.services.receiver.*,
            "accept",
            "source",
            borrow.prior.*.prior.*.transfer.offer.*,
            borrow.prior.*.prior.*.offered.archive_path.*,
        ),
    );
    try std.testing.expectEqualDeep(
        borrow.prior.*.state.receiver_head.*,
        borrow.prior.*.prior.*.namespaces.destination_namespace.*.store.head,
    );
    borrow.prior.*.prior.*.disclosure.disclosure.*.deny_runtime = false;
    return placementRejectGeneratedOwner(scenario, .{
        .prior = &borrow,
    });
}

fn placementResumeAcceptedChild(comptime scenario: anytype, borrow: anytype) !void {
    const context_application = &borrow.prior.*.prior.*.application;
    const context_namespaces = &borrow.prior.*.prior.*.namespaces;
    const context_receiver = &borrow.prior.*.prior.*.receiver;
    const context_services = &borrow.prior.*.prior.*.services;
    context_services.*.receiver.* = try native.tasks.Service(OwnerTypes).init(
        borrow.prior.*.prior.*.setup.a.*,
        borrow.prior.*.prior.*.setup.io.*,
        &context_namespaces.*.destination_namespace.*,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        context_receiver.*.resumed_profile.*,
    );
    context_services.*.receiver_open.* = true;
    borrow.prior.*.prior.*.setup.phase.* = "replay destination acceptance";
    try std.testing.expect(context_services.*.receiver.*.compiler_facts == null);
    try std.testing.expectEqualDeep(
        borrow.prior.*.state.accepted.*,
        try acceptPlacement(
            &context_services.*.receiver.*,
            "recovered-acceptance",
            "source",
            borrow.prior.*.prior.*.transfer.offer.*,
            borrow.prior.*.prior.*.offered.archive_path.*,
        ),
    );
    return placementInspectImportedWork(scenario, .{
        .acceptance = .{
            .accepted = &borrow.prior.*.state.accepted.*,
        },
        .application = context_application.*,
        .channels = borrow.prior.*.prior.*.channels,
        .child = borrow.prior.*.prior.*.child,
        .disclosure = borrow.prior.*.prior.*.disclosure,
        .generated = borrow.prior.*.prior.*.generated,
        .namespaces = context_namespaces.*,
        .peers = borrow.prior.*.prior.*.peers,
        .receiver = context_receiver.*,
        .services = context_services.*,
        .setup = borrow.prior.*.prior.*.setup,
        .sites = borrow.prior.*.prior.*.sites,
        .work = borrow.prior.*.prior.*.work,
    });
}

fn placementControllerPolicy(comptime scenario: anytype, borrow: anytype) !void {
    const context_namespaces = &borrow.prior.*.prior.*.namespaces;
    const context_services = &borrow.prior.*.prior.*.services;
    try std.testing.expectError(
        error.CustodyNotLocal,
        context_services.*.sender.*.workspaceControl(
            context_namespaces.*.scratch.*,
            "departed",
            borrow.prior.*.prior.*.sites.subject.*.task,
            borrow.prior.*.prior.*.work.work_id.*,
            borrow.prior.*.prior.*.sites.cut.*.execution,
            borrow.prior.*.prior.*.sites.cut.*.control,
            .advance,
        ),
    );
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = context_services.*.sender.*.profile.authority;
        defer context_services.*.sender.*.profile.authority = authority;
        const before = context_namespaces.*.source_namespace.*.store.head;
        @field(context_services.*.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            context_services.*.sender.*.placementControl(
                context_namespaces.*.scratch.*,
                "remote-inspect",
                borrow.prior.*.prior.*.sites.subject.*.task,
                .{ .inspect = .{
                    .work = borrow.prior.*.prior.*.work.work_ref.*,
                } },
            ),
        );
        try std.testing.expectEqualDeep(before, context_namespaces.*.source_namespace.*.store.head);
    }
    return placementInspectRemoteController(scenario, .{
        .controller = .{
            .source_profile = &borrow.prior.*.state.source_profile.*,
        },
        .application = borrow.prior.*.prior.*.application,
        .channels = borrow.prior.*.prior.*.channels,
        .child = borrow.prior.*.prior.*.child,
        .disclosure = borrow.prior.*.prior.*.disclosure,
        .generated = borrow.prior.*.prior.*.generated,
        .namespaces = context_namespaces.*,
        .peers = borrow.prior.*.prior.*.peers,
        .receiver = borrow.prior.*.prior.*.receiver,
        .services = context_services.*,
        .setup = borrow.prior.*.prior.*.setup,
        .sites = borrow.prior.*.prior.*.sites,
        .work = borrow.prior.*.prior.*.work,
    });
}

fn placementRemoteControllerPolicy(comptime scenario: anytype, borrow: anytype) !void {
    const context_application = &borrow.prior.*.prior.*.application;
    const namespaces_view = &borrow.prior.*.prior.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.services;
    try std.testing.expectError(
        error.UnsettledRemoteControl,
        freezePlacement(
            &services_view.*.sender.*,
            borrow.state.controller_subject.*,
            "successor",
            borrow.state.controller_cut.*,
            @splat(16),
        ),
    );
    try services_view.*.sender.*.close(borrow.prior.*.prior.*.setup.a.*);
    services_view.*.sender_open.* = false;
    try namespaces_view.*.source_namespace.*.close();
    namespaces_view.*.source_open.* = false;
    namespaces_view.*.destination_namespace.* = try native.Namespace.open(
        borrow.prior.*.prior.*.setup.a.*,
        borrow.prior.*.prior.*.setup.io.*,
        namespaces_view.*.destination_path.*,
    );
    namespaces_view.*.destination_open.* = true;
    services_view.*.receiver.* = try native.tasks.Service(OwnerTypes).init(
        borrow.prior.*.prior.*.setup.a.*,
        borrow.prior.*.prior.*.setup.io.*,
        &namespaces_view.*.destination_namespace.*,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        borrow.prior.*.prior.*.receiver.resumed_profile.*,
    );
    services_view.*.receiver_open.* = true;
    return placementRemoteControllerExecution(scenario, .{
        .prior = &borrow,
    });
}

fn placementAcceptedControllerAuthority(comptime scenario: anytype, borrow: anytype) !void {
    const context_controller_offer = &borrow.prior.*.prior.*.controller_offer;
    const context_namespaces = &borrow.prior.*.prior.*.namespaces;
    const context_services = &borrow.prior.*.prior.*.services;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = context_services.*.receiver.*.profile.authority;
        defer context_services.*.receiver.*.profile.authority = authority;
        const before = context_namespaces.*.destination_namespace.*.store.head;
        @field(context_services.*.receiver.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            context_services.*.receiver.*.placementFollowController(
                context_namespaces.*.scratch.*,
                "source",
                "successor",
                context_controller_offer.*.controller_offer.*,
                borrow.prior.*.state.controller_decision.*,
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            context_namespaces.*.destination_namespace.*.store.head,
        );
    }
    try context_services.*.receiver.*.placementFollowController(
        context_namespaces.*.scratch.*,
        "source",
        "successor",
        context_controller_offer.*.controller_offer.*,
        borrow.prior.*.state.controller_decision.*,
    );
    try context_services.*.receiver.*.placementFollowController(
        context_namespaces.*.scratch.*,
        "source",
        "successor",
        context_controller_offer.*.controller_offer.*,
        borrow.prior.*.state.controller_decision.*,
    );
    return placementRejectStaleControl(scenario, .{
        .controller_acceptance = .{
            .successor_control = &borrow.prior.*.state.successor_control.*,
        },
        .application = borrow.prior.*.prior.*.application,
        .channels = borrow.prior.*.prior.*.channels,
        .child = borrow.prior.*.prior.*.child,
        .controller = borrow.prior.*.prior.*.controller,
        .generated = borrow.prior.*.prior.*.generated,
        .namespaces = context_namespaces.*,
        .observer = borrow.prior.*.prior.*.observer,
        .peers = borrow.prior.*.prior.*.peers,
        .receiver = borrow.prior.*.prior.*.receiver,
        .report = borrow.prior.*.prior.*.report,
        .services = context_services.*,
        .setup = borrow.prior.*.prior.*.setup,
        .sites = borrow.prior.*.prior.*.sites,
        .work = borrow.prior.*.prior.*.work,
    });
}

fn placementRejectFrozenCommands(comptime scenario: anytype, borrow: anytype) !bool {
    const fixture_view = &borrow.prior.*.prior.*.fixture;
    try std.testing.expectError(
        error.OperationConflict,
        fixture_view.*.sender.*.workspaceBuild(
            fixture_view.*.scratch.*,
            "build",
            fixture_view.*.parent.*.receipt.task,
            try std.fmt.allocPrint(fixture_view.*.scratch.*, "\n{s}", .{fixture_view.*.document.*}),
            &fixture_view.*.diagnostic.*,
        ),
    );
    return placementInspectFrozenCommandState(scenario, .{
        .prior = &borrow,
    });
}

fn placementInspectChildCancellation(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.sites;
    const p = native.placement;
    if (scenario == .cancel_refused) {
        const child_archive = try std.fmt.allocPrint(
            namespaces_view.*.scratch.*,
            "{s}/{s}.par",
            .{
                namespaces_view.*.path_buffer.*[0..namespaces_view.*.length.*],
                borrow.prior.*.state.operation.*,
            },
        );
        const child_offer = try offerPlacement(
            &services_view.*.sender.*,
            borrow.state.child_subject.*,
            "destination",
            child_archive,
        );
        borrow.state.refusal.* = try p.sign(
            p.Decision,
            namespaces_view.*.scratch.*,
            sites_view.*.destination_key.*,
            .{
                .transfer = borrow.state.transfer.*,
                .offer_digest = try p.digest(
                    p.Offer,
                    namespaces_view.*.scratch.*,
                    child_offer.value,
                ),
                .source = sites_view.*.source_site.*,
                .destination = sites_view.*.destination_site.*,
                .epoch = child_offer.value.intent.epoch + 1,
                .verdict = .{
                    .refused = .withdrawn,
                },
            },
        );
    }
    if (borrow.state.refusal.*) |decision| try services_view.*.sender.*.placementApplyDecision(
        namespaces_view.*.scratch.*,
        borrow.state.child_subject.*,
        decision,
    ) else try services_view.*.sender.*.placementAbortUnsent(
        namespaces_view.*.scratch.*,
        borrow.state.child_subject.*,
        borrow.state.transfer.*,
    );
    return placementAwaitDisposedChild(scenario, .{
        .prior = &borrow,
    });
}

fn placementReleaseCancelledRoot(comptime scenario: anytype, borrow: anytype) !bool {
    const state_refusal = &borrow.prior.*.state.refusal;

    const namespaces_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.services;
    _ = scenario;
    if (state_refusal.*.*) |decision| try services_view.*.sender.*.placementApplyDecision(
        namespaces_view.*.scratch.*,
        borrow.prior.*.state.root_subject.*,
        decision,
    ) else try services_view.*.sender.*.placementAbortUnsent(
        namespaces_view.*.scratch.*,
        borrow.prior.*.state.root_subject.*,
        borrow.prior.*.state.transfer.*,
    );
    if (borrow.prior.*.prior.*.parked.* == 1) {
        for (0..4) |_| _ = try services_view.*.sender.*.pump(
            namespaces_view.*.scratch.*,
        );
        var still = try services_view.*.sender.*.task(
            namespaces_view.*.scratch.*,
            borrow.prior.*.state.root_subject.*.task,
        );
        defer still.deinit();
        try std.testing.expect(!still.value.terminal());
        try std.testing.expectEqual(.parked, still.value.schedule);
        _ = try services_view.*.sender.*.requestCancel(
            namespaces_view.*.scratch.*,
            try std.fmt.allocPrint(
                namespaces_view.*.scratch.*,
                "{s}-recancel",
                .{borrow.prior.*.state.operation.*},
            ),
            borrow.prior.*.state.root_subject.*.task,
            "stop",
        );
    }
    var root_disposed = false;
    for (0..512) |_| {
        _ = try services_view.*.sender.*.pump(
            namespaces_view.*.scratch.*,
        );
        var current = try services_view.*.sender.*.task(
            namespaces_view.*.scratch.*,
            borrow.prior.*.state.root_subject.*.task,
        );
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            root_disposed = true;
            break;
        }
    }
    try std.testing.expect(root_disposed);

    return false;
}

fn placementRejectUnrelatedRefusal(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.sites;
    const p = native.placement;
    try std.testing.expectEqual(
        .frozen,
        (try services_view.*.sender.*.placementStatus(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*,
        )).?.phase,
    );
    var conflicting_intent = borrow.prior.*.state.fresh_intent.*;
    conflicting_intent.source = sites_view.*.destination_site.*;
    conflicting_intent.destination = sites_view.*.source_site.*;
    const conflicting_offer = try p.sign(
        p.Offer,
        namespaces_view.*.scratch.*,
        sites_view.*.destination_key.*,
        .{
            .intent = conflicting_intent,
            .archive_digest = @splat(94),
            .archive_bytes = 0,
        },
    );
    const frozen_head = namespaces_view.*.source_namespace.*.store.head;
    try std.testing.expectError(
        error.OperationConflict,
        services_view.*.sender.*.placementRefuse(
            namespaces_view.*.scratch.*,
            "destination",
            conflicting_offer,
            .withdrawn,
        ),
    );
    try std.testing.expectEqualDeep(
        frozen_head,
        namespaces_view.*.source_namespace.*.store.head,
    );
    try services_view.*.sender.*.placementAbortUnsent(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*,
        @splat(17),
    );
    return placementRetainTransferDecisions(scenario, .{
        .prior = &borrow,
    });
}

fn placementSelectRootSettlement(comptime scenario: anytype, borrow: anytype) !bool {
    const fixture_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.borrow.*.fixture;
    const incomplete_park_view = &borrow.prior.*.prior.*.borrow.*.incomplete_park;
    const selected_command_view = &borrow.prior.*.prior.*.selected_command;
    _ = scenario;
    const p = native.placement;
    if (borrow.prior.*.prior.*.borrow.*.parked.*) {
        fixture_view.*.phase.* = "settled remote park is quiescent";
        try std.testing.expect(
            !try borrow.prior.*.state.closing_controller.*.shutdownIncomplete(
                fixture_view.*.scratch.*,
            ),
        );
        _ = try borrow.prior.*.state.closing_controller.*.pump(fixture_view.*.scratch.*);
        var pending = try borrow.prior.*.state.closing_namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
                "WHERE r.task=? AND r.kind='placement_control'",
            &.{.{
                .blob = &fixture_view.*.subject.*.task,
            }},
        );
        defer pending.deinit();
        while (try pending.step() == .row) {
            var saved = try contracts.decodeOwned(
                p.ControlRecord,
                fixture_view.*.scratch.*,
                try pending.bytes(0),
            );
            defer saved.deinit();
            try std.testing.expect(saved.value.report != null);
        }
        return true;
    }
    fixture_view.*.phase.* = "refresh incomplete remote park";
    if (incomplete_park_view.*.*) try std.testing.expect(
        try borrow.prior.*.state.closing_controller.*.shutdownIncomplete(
            fixture_view.*.scratch.*,
        ),
    );
    _ = try borrow.prior.*.state.closing_controller.*.pump(fixture_view.*.scratch.*);
    var query = try borrow.prior.*.state.closing_namespace.*.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.task=? AND r.kind='placement_control'",
        &.{.{
            .blob = &fixture_view.*.subject.*.task,
        }},
    );
    defer query.deinit();
    var found = false;
    while (try query.step() == .row) {
        const saved = try contracts.decodeOwned(
            p.ControlRecord,
            fixture_view.*.scratch.*,
            try query.bytes(0),
        );
        if (saved.value.report == null) {
            selected_command_view.*.* = saved.value.control;
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    if (incomplete_park_view.*.*) try std.testing.expectEqual(
        .inspect,
        std.meta.activeTag(selected_command_view.*.*.value.command),
    );
    return false;
}

fn placementObserveParkCommand(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.borrow.*.prior.*.borrow.*.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    try std.testing.expect(borrow.borrow.*.state.result.*.value.value.work_state.?.park_complete);
    var parked_child = try borrow.borrow.*.state.closing_executor.*.workspaceWork(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
        fixture_view.*.work_id.*,
    );
    defer parked_child.deinit();
    try std.testing.expectEqual(.parked, parked_child.value.schedule);
    try std.testing.expect(parked_child.value.cancellation == null);
    var incomplete = borrow.borrow.*.state.result.*.value.value;
    incomplete.work_state.?.park_complete = false;
    borrow.borrow.*.prior.*.borrow.*.prior_report.* = try p.sign(
        p.Report,
        fixture_view.*.scratch.*,
        fixture_view.*.source_key.*,
        incomplete,
    );
    _ = try borrow.borrow.*.state.closing_executor.*.workspaceControl(
        fixture_view.*.scratch.*,
        "later-explicit-park",
        fixture_view.*.subject.*.task,
        fixture_view.*.work_id.*,
        parked_child.value.execution_revision,
        parked_child.value.control_revision,
        .park,
    );
    const later = try borrow.borrow.*.state.closing_executor.*.placementCut(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*,
    );
    try std.testing.expectEqual(
        parked_child.value.execution_revision,
        later.execution,
    );
    try std.testing.expectEqual(
        parked_child.value.control_revision + 1,
        later.control,
    );
    var observed_parent = try borrow.borrow.*.state.closing_executor.*.task(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
    );
    defer observed_parent.deinit();
    borrow.borrow.*.prior.*.borrow.*.parked_task_watermark.* = observed_parent.value.event_high;
    borrow.borrow.*.prior.*.borrow.*.incomplete_park.* = true;
}

fn placementAcknowledgeRemoteDisposal(comptime scenario: anytype, borrow: anytype) !bool {
    const state_setup = &borrow.prior.*.prior.*.borrow.*.borrow.*.setup;
    const state_cleanup_report = &borrow.prior.*.prior.*.borrow.*.cleanup_report;

    const namespaces_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const resumed_after_park_view = &borrow.prior.*.prior.*.borrow.*.resumed_after_park;
    const sites_view = &borrow.prior.*.prior.*.borrow.*.borrow.*.sites;
    const p = native.placement;
    if (state_cleanup_report.*.*.value.work_state.?.explicitly_parked and
        !resumed_after_park_view.*.*)
    {
        try std.testing.expect(borrow.prior.*.prior.*.borrow.*.parked_once.*);
        _ = try borrow.prior.*.state.successor.*.pump(namespaces_view.*.scratch.*);
        var pending = try namespaces_view.*.successor_namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
                "WHERE r.task=? AND r.kind='placement_control'",
            &.{.{
                .blob = &sites_view.*.subject.*.task,
            }},
        );
        defer pending.deinit();
        while (try pending.step() == .row) {
            var saved = try contracts.decodeOwned(
                p.ControlRecord,
                namespaces_view.*.scratch.*,
                try pending.bytes(0),
            );
            defer saved.deinit();
            try std.testing.expect(saved.value.report != null);
        }
        try std.testing.expect(
            try borrow.prior.*.state.successor.*.shutdownIncomplete(namespaces_view.*.scratch.*),
        );
        _ = try borrow.prior.*.state.successor.*.requestCancel(
            namespaces_view.*.scratch.*,
            "fresh-cancel-after-remote-park",
            sites_view.*.subject.*.task,
            "controller stopped",
        );
        resumed_after_park_view.*.* = true;
    }
    state_setup.*.phase.* = "finish controller after remote disposal";
    return placementFinishRemoteDisposal(scenario, .{
        .prior = &borrow,
    });
}

fn placementRejectGeneratedOwner(comptime scenario: anytype, borrow: anytype) !void {
    const context_namespaces = &borrow.prior.*.prior.*.prior.*.namespaces;
    const context_generated = &borrow.prior.*.prior.*.prior.*.generated;
    const context_services = &borrow.prior.*.prior.*.prior.*.services;
    const context_transfer = &borrow.prior.*.prior.*.prior.*.transfer;
    const context_offered = &borrow.prior.*.prior.*.prior.*.offered;
    const context_sites = &borrow.prior.*.prior.*.prior.*.sites;

    try placementRejectGeneratedPolicy(scenario, .{
        .borrow = &borrow,
        .context_generated = context_generated.*,
        .context_namespaces = &context_namespaces,
        .context_offered = &context_offered,
        .context_services = &context_services,
        .context_sites = &context_sites,
        .context_transfer = &context_transfer,
    });

    return placementAcceptChild(scenario, .{
        .receiver = .{
            .prior_refusal = &borrow.prior.*.prior.*.state.prior_refusal.*,
            .resumed_profile = &borrow.prior.*.prior.*.state.resumed_profile.*,
            .unrelated_signed = &borrow.prior.*.prior.*.state.unrelated_signed.*,
        },
        .application = borrow.prior.*.prior.*.prior.*.application,
        .channels = borrow.prior.*.prior.*.prior.*.channels,
        .child = borrow.prior.*.prior.*.prior.*.child,
        .disclosure = borrow.prior.*.prior.*.prior.*.disclosure,
        .generated = context_generated.*,
        .namespaces = context_namespaces.*,
        .offered = context_offered.*,
        .peers = borrow.prior.*.prior.*.prior.*.peers,
        .services = context_services.*,
        .setup = borrow.prior.*.prior.*.prior.*.setup,
        .sites = context_sites.*,
        .transfer = context_transfer.*,
        .work = borrow.prior.*.prior.*.prior.*.work,
    });
}

fn placementRemoteControllerExecution(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.prior.*.prior.*.prior.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.prior.*.services;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = services_view.*.receiver.*.profile.authority;
        defer services_view.*.receiver.*.profile.authority = authority;
        const before = namespaces_view.*.destination_namespace.*.store.head;
        @field(services_view.*.receiver.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            services_view.*.receiver.*.placementExecuteControl(
                namespaces_view.*.scratch.*,
                "source",
                borrow.prior.*.prior.*.state.control.*.value,
            ),
        );
        try std.testing.expectError(
            error.Denied,
            services_view.*.receiver.*.placementResolveControl(
                namespaces_view.*.scratch.*,
                "source",
                borrow.prior.*.prior.*.state.control.*.value,
                &.{},
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            namespaces_view.*.destination_namespace.*.store.head,
        );
    }
    const report_bytes = try services_view.*.receiver.*.placementExecuteControl(
        namespaces_view.*.scratch.*,
        "source",
        borrow.prior.*.prior.*.state.control.*.value,
    );
    try std.testing.expectEqualSlices(
        u8,
        report_bytes,
        try services_view.*.receiver.*.placementExecuteControl(
            namespaces_view.*.scratch.*,
            "source",
            borrow.prior.*.prior.*.state.control.*.value,
        ),
    );
    return placementInspectRemoteReport(scenario, .{
        .state = .{
            .report_bytes = &report_bytes,
        },
        .prior = &borrow,
    });
}

fn placementInspectFrozenCommandState(comptime scenario: anytype, borrow: anytype) !bool {
    const fixture_view = &borrow.prior.*.prior.*.prior.*.fixture;
    const frozen_view = &borrow.prior.*.prior.*.prior.*.frozen;
    {
        const authority = fixture_view.*.sender.*.profile.authority;
        defer fixture_view.*.sender.*.profile.authority = authority;
        fixture_view.*.sender.*.profile.authority.disclosure = false;
        try std.testing.expectError(
            error.Denied,
            fixture_view.*.sender.*.workspaceBuild(
                fixture_view.*.scratch.*,
                "build",
                fixture_view.*.parent.*.receipt.task,
                fixture_view.*.document.*,
                &fixture_view.*.diagnostic.*,
            ),
        );
        fixture_view.*.sender.*.profile.authority = authority;
        fixture_view.*.sender.*.profile.authority.revoked = true;
        try std.testing.expectError(
            error.Denied,
            fixture_view.*.sender.*.workspaceBuild(
                fixture_view.*.scratch.*,
                "build",
                fixture_view.*.parent.*.receipt.task,
                fixture_view.*.document.*,
                &fixture_view.*.diagnostic.*,
            ),
        );
        fixture_view.*.sender.*.profile.authority = authority;
        fixture_view.*.sender.*.profile.authority.principal = "other";
        try std.testing.expectError(
            error.Denied,
            fixture_view.*.sender.*.workspaceBuild(
                fixture_view.*.scratch.*,
                "build",
                fixture_view.*.parent.*.receipt.task,
                fixture_view.*.document.*,
                &fixture_view.*.diagnostic.*,
            ),
        );
    }
    try std.testing.expectEqualDeep(
        frozen_view.*.frozen_head.*,
        fixture_view.*.source_namespace.*.store.head,
    );
    try std.testing.expectEqualDeep(
        frozen_view.*.frozen_runnable.*,
        fixture_view.*.sender.*.runnable.items,
    );
    return placementCheckFrozenCommandCut(scenario, .{
        .prior = &borrow,
    });
}

fn placementAwaitDisposedChild(comptime scenario: anytype, borrow: anytype) !bool {
    const state_setup = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.setup;

    const namespaces_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.sites;
    _ = scenario;
    if (borrow.prior.*.prior.*.prior.*.parked.* == 1) {
        for (0..4) |_| _ = try services_view.*.sender.*.pump(
            namespaces_view.*.scratch.*,
        );
        var still = try services_view.*.sender.*.workspaceWork(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*.task,
            borrow.prior.*.prior.*.state.child_id.*,
        );
        defer still.deinit();
        try std.testing.expect(!still.value.terminal());
        try std.testing.expectEqual(.parked, still.value.schedule);
        _ = try services_view.*.sender.*.workspaceControl(
            namespaces_view.*.scratch.*,
            try std.fmt.allocPrint(namespaces_view.*.scratch.*, "{s}-resume", .{
                borrow.prior.*.prior.*.state.operation.*,
            }),
            sites_view.*.subject.*.task,
            borrow.prior.*.prior.*.state.child_id.*,
            still.value.execution_revision,
            still.value.control_revision,
            .{ .delegate = .{
                .stop = .terminal,
                .continuation = .owner_scheduled,
            } },
        );
    }
    var child_disposed = false;
    for (0..512) |_| {
        _ = try services_view.*.sender.*.pump(
            namespaces_view.*.scratch.*,
        );
        var current = try services_view.*.sender.*.workspaceWork(
            namespaces_view.*.scratch.*,
            sites_view.*.subject.*.task,
            borrow.prior.*.prior.*.state.child_id.*,
        );
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            child_disposed = true;
            break;
        }
    }
    state_setup.*.phase.* = "cancelled child restored to local custody";
    try std.testing.expect(child_disposed);

    return false;
}

fn placementRetainTransferDecisions(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.services;
    const sites_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.sites;
    const setup_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.setup;
    const p = native.placement;
    try std.testing.expectEqualDeep(
        borrow.prior.*.prior.*.state.fresh_intent.*,
        try freezePlacement(
            &services_view.*.sender.*,
            sites_view.*.subject.*,
            "destination",
            borrow.prior.*.prior.*.state.changed_cut.*,
            @splat(17),
        ),
    );
    const fresh_path = try std.fmt.allocPrint(
        namespaces_view.*.scratch.*,
        "{s}/refused-again.par",
        .{
            namespaces_view.*.path_buffer.*[0..namespaces_view.*.length.*],
        },
    );
    const fresh_offer = try offerPlacement(
        &services_view.*.sender.*,
        sites_view.*.subject.*,
        "destination",
        fresh_path,
    );
    const fresh_refusal = try p.sign(
        p.Decision,
        namespaces_view.*.scratch.*,
        sites_view.*.destination_key.*,
        .{
            .transfer = fresh_offer.value.intent.transfer,
            .offer_digest = try p.digest(
                p.Offer,
                namespaces_view.*.scratch.*,
                fresh_offer.value,
            ),
            .source = sites_view.*.source_site.*,
            .destination = sites_view.*.destination_site.*,
            .epoch = fresh_offer.value.intent.epoch + 1,
            .verdict = .{
                .refused = .withdrawn,
            },
        },
    );
    try services_view.*.sender.*.placementApplyDecision(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*,
        fresh_refusal,
    );
    setup_view.*.phase.* = "reopen retained transfer decisions";
    try services_view.*.sender.*.close(setup_view.*.a.*);
    services_view.*.sender_open.* = false;
    try namespaces_view.*.source_namespace.*.close();
    namespaces_view.*.source_open.* = false;
    return placementReopenTransferDecisions(scenario, .{
        .prior = &borrow,
    });
}

fn placementFinishRemoteDisposal(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const sites_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.sites;
    const setup_view = &borrow.prior.*.prior.*.prior.*.borrow.*.borrow.*.setup;
    _ = scenario;
    const p = native.placement;
    if (try borrow.prior.*.prior.*.state.successor.*.associatedWorkDisposed(
        namespaces_view.*.scratch.*,
        sites_view.*.subject.*.task,
    )) {
        for (0..512) |_| {
            _ = try borrow.prior.*.prior.*.state.successor.*.pump(namespaces_view.*.scratch.*);
            var task = try borrow.prior.*.prior.*.state.successor.*.task(
                namespaces_view.*.scratch.*,
                sites_view.*.subject.*.task,
            );
            defer task.deinit();
            if (task.value.terminal()) {
                try std.testing.expect(
                    try borrow.prior.*.prior.*.state.successor.*.taskCleanupComplete(
                        namespaces_view.*.scratch.*,
                        task.value,
                    ),
                );
                borrow.prior.*.prior.*.prior.*.borrow.*.disposed.* = true;
                break;
            }
        }
        return true;
    }
    setup_view.*.phase.* = "schedule remote cleanup control";
    try std.testing.expect(
        try borrow.prior.*.prior.*.state.successor.*.pump(namespaces_view.*.scratch.*) != .work,
    );
    var query = try namespaces_view.*.successor_namespace.*.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.task=? AND r.kind='placement_control'",
        &.{.{
            .blob = &sites_view.*.subject.*.task,
        }},
    );
    defer query.deinit();
    var found = false;
    while (try query.step() == .row) {
        const saved = try contracts.decodeOwned(
            p.ControlRecord,
            namespaces_view.*.scratch.*,
            try query.bytes(0),
        );
        if (saved.value.report == null and std.mem.startsWith(
            u8,
            saved.value.control.value.operation.bytes,
            "cleanup-",
        )) {
            borrow.prior.*.prior.*.prior.*.borrow.*.cleanup_control.* = saved.value.control;
            found = true;
            break;
        }
    }
    setup_view.*.phase.* = "locate scheduled remote cleanup";
    try std.testing.expect(found);
    return false;
}

fn placementInspectRemoteReport(comptime scenario: anytype, borrow: anytype) !void {
    const namespaces_view = &borrow.prior.*.prior.*.prior.*.prior.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.prior.*.prior.*.services;
    const setup_view = &borrow.prior.*.prior.*.prior.*.prior.*.setup;
    const context_state = &borrow.prior.*.prior.*.prior.*.state;
    const p = native.placement;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = services_view.*.receiver.*.profile.authority;
        defer services_view.*.receiver.*.profile.authority = authority;
        const before = namespaces_view.*.destination_namespace.*.store.head;
        @field(services_view.*.receiver.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            services_view.*.receiver.*.placementExecuteControl(
                namespaces_view.*.scratch.*,
                "source",
                context_state.*.control.*.value,
            ),
        );
        try std.testing.expectError(
            error.Denied,
            services_view.*.receiver.*.placementResolveControl(
                namespaces_view.*.scratch.*,
                "source",
                context_state.*.control.*.value,
                &.{},
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            namespaces_view.*.destination_namespace.*.store.head,
        );
    }
    var report = try contracts.decodeOwned(
        p.Signed(p.Report),
        namespaces_view.*.scratch.*,
        borrow.state.report_bytes.*,
    );
    defer report.deinit();
    try std.testing.expectEqual(.observed, report.value.value.reply.disposition);
    try services_view.*.receiver.*.close(setup_view.*.a.*);
    services_view.*.receiver_open.* = false;
    try namespaces_view.*.destination_namespace.*.close();
    namespaces_view.*.destination_open.* = false;
    namespaces_view.*.source_namespace.* = try native.Namespace.open(
        setup_view.*.a.*,
        setup_view.*.io.*,
        namespaces_view.*.source_path.*,
    );
    namespaces_view.*.source_open.* = true;
    return placementReopenReportedController(scenario, .{
        .state = .{
            .report = &report,
        },
        .prior = &borrow,
    });
}

fn placementReopenTransferDecisions(comptime scenario: anytype, borrow: anytype) !void {
    const origin = borrow.prior.*.prior.*.prior.*.prior.*.borrow.*.borrow;
    const context_application = &origin.*.application;
    const namespaces_view = &borrow.prior.*.prior.*.prior.*.prior.*.borrow.*.borrow.*.namespaces;
    const services_view = &borrow.prior.*.prior.*.prior.*.prior.*.borrow.*.borrow.*.services;
    const setup_view = &borrow.prior.*.prior.*.prior.*.prior.*.borrow.*.borrow.*.setup;
    const sites_view = &borrow.prior.*.prior.*.prior.*.prior.*.borrow.*.borrow.*.sites;
    _ = scenario;
    const p = native.placement;
    namespaces_view.*.source_namespace.* = try native.Namespace.open(
        setup_view.*.a.*,
        setup_view.*.io.*,
        namespaces_view.*.source_path.*,
    );
    namespaces_view.*.source_open.* = true;
    var reopened_profile = context_application.*.profile.*;
    reopened_profile.placement = &origin.*.channels.source_config.*;
    services_view.*.sender.* = try native.tasks.Service(OwnerTypes).init(
        setup_view.*.a.*,
        setup_view.*.io.*,
        &namespaces_view.*.source_namespace.*,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        reopened_profile,
    );
    services_view.*.sender_open.* = true;
    setup_view.*.phase.* = "reject old transfer identity after restart";
    try std.testing.expectError(
        error.OperationConflict,
        freezePlacement(
            &services_view.*.sender.*,
            sites_view.*.subject.*,
            "destination",
            borrow.prior.*.prior.*.prior.*.state.changed_cut.*,
            @splat(14),
        ),
    );
    const controller: p.Subject = .{ .task = sites_view.*.subject.*.task };
    const controller_cut = try services_view.*.sender.*.placementCut(
        namespaces_view.*.scratch.*,
        controller,
    );
    try std.testing.expectError(
        error.OperationConflict,
        freezePlacement(
            &services_view.*.sender.*,
            controller,
            "destination",
            controller_cut,
            @splat(14),
        ),
    );
    try std.testing.expectEqual(
        .local,
        (try services_view.*.sender.*.placementStatus(
            namespaces_view.*.scratch.*,
            controller,
        )).?.phase,
    );
    try std.testing.expect(
        !try services_view.*.sender.*.shutdownIncomplete(
            namespaces_view.*.scratch.*,
        ),
    );
}

fn placementPrepareCopiedCustody(comptime scenario: anytype, borrow: anytype) !bool {
    const context = borrow.borrow.*.borrow;
    const p = native.placement;
    context.setup.phase.* = "untrusted custody preparation";
    context.setup.attack_index.* = borrow.attack.*;
    const attacked_archive = try std.fmt.allocPrint(
        context.namespaces.scratch.*,
        "{s}/untrusted-{d}.par",
        .{
            context.namespaces.path_buffer.*[0..context.namespaces.length.*],
            borrow.attack.*,
        },
    );
    const copied_site: p.Site = .{
        .key = context.sites.destination_key.*.public_key.toBytes(),
        .namespace = context.namespaces.untrusted_namespaces.*[borrow.attack.*],
    };

    try placementExportCopiedCustody(scenario, .{
        .attacked_archive = &attacked_archive,
        .borrow = &borrow,
        .copied_site = &copied_site,
    });

    return false;
}

fn placementExportCopiedCustody(comptime scenario: anytype, borrow: anytype) !void {
    const context = borrow.borrow.*.borrow.*.borrow;
    _ = scenario;
    const p = native.placement;
    try context.namespaces.source_namespace.*.store.begin();
    defer context.namespaces.source_namespace.*.store.rollback();
    if (borrow.borrow.*.attack.* < 2) {
        try context.namespaces.source_namespace.*.store.database.run(
            "DELETE FROM records WHERE kind='placement_custody' AND task=?",
            &.{.{
                .blob = &context.sites.subject.*.task,
            }},
        );
    } else {
        const forged = try p.Custody.initial(
            borrow.borrow.*.controller.*,
            borrow.copied_site.*,
        ).freeze(borrow.copied_site.*, .{
            .transfer = @splat(71),
            .subject = borrow.borrow.*.controller.*,
            .source = borrow.copied_site.*,
            .destination = context.sites.source_site.*,
            .source_native = context.application.profile.*.runtime_identity,
            .destination_native = context.application.profile.*.runtime_identity,
            .epoch = 0,
            .cut = borrow.borrow.*.controller_cut.*,
            .compatibility = context.sites.compatibility.*,
            .resources = context.sites.resources.*,
            .disclosure = @splat(13),
        });
        try context.namespaces.source_namespace.*.store.putRecord(
            p.Custody,
            "placement_custody",
            forged.id,
            forged.task,
            forged,
        );
    }
    var archive_arena = std.heap.ArenaAllocator.init(
        context.setup.a.*,
    );
    defer archive_arena.deinit();
    _ = context.services.sender.*.exportCheckpoint(
        archive_arena.allocator(),
        context.sites.subject.*.task,
        borrow.attacked_archive.*,
    ) catch |err| {
        std.debug.print("untrusted archive export {d}: {s}\n", .{
            borrow.borrow.*.attack.*,
            @errorName(err),
        });
        return err;
    };
}

fn placementImportCopiedCustody(comptime scenario: anytype, borrow: anytype) !bool {
    const context = borrow.borrow.*.borrow;
    const p = native.placement;
    context.setup.phase.* = "untrusted custody import";
    context.setup.attack_index.* = borrow.attack.*;
    const attacked_path = try std.fmt.allocPrint(
        context.namespaces.scratch.*,
        "{s}/untrusted-{d}",
        .{
            context.namespaces.path_buffer.*[0..context.namespaces.length.*],
            borrow.attack.*,
        },
    );
    const attacked_archive = try std.fmt.allocPrint(
        context.namespaces.scratch.*,
        "{s}/untrusted-{d}.par",
        .{
            context.namespaces.path_buffer.*[0..context.namespaces.length.*],
            borrow.attack.*,
        },
    );
    var copied_namespace = try native.Namespace.open(
        context.setup.a.*,
        context.setup.io.*,
        attacked_path,
    );
    defer support.expectCleanup(copied_namespace.close());
    const copied_config: p.Configuration = .{
        .signing_key = context.sites.destination_key.*,
        .peers = &.{},
    };
    var copied_profile = context.application.profile.*;
    if (borrow.attack.* != 0) copied_profile.placement = &copied_config;
    var copied = try native.tasks.Service(OwnerTypes).init(
        context.setup.a.*,
        context.setup.io.*,
        &copied_namespace,
        context.application.assets.*,
        &context.application.application.*,
        context.application.handlers.*,
        copied_profile,
    );
    defer support.expectCleanup(copied.close(context.setup.a.*));
    var archive_arena = std.heap.ArenaAllocator.init(context.setup.a.*);
    defer archive_arena.deinit();
    _ = copied.importCheckpoint(
        archive_arena.allocator(),
        "untrusted-copy",
        attacked_archive,
    ) catch |err| {
        std.debug.print("untrusted archive import {d}: {s}\n", .{
            borrow.attack.*,
            @errorName(err),
        });
        return err;
    };
    return placementRejectCopiedCustody(scenario, .{
        .imported = .{
            .copied = &copied,
        },
        .attack = borrow.attack,
        .borrow = borrow.borrow,
        .controller = borrow.controller,
    });
}

fn placementRejectCopiedCustody(comptime scenario: anytype, borrow: anytype) !bool {
    const namespaces_view = &borrow.borrow.*.borrow.*.namespaces;
    const sites_view = &borrow.borrow.*.borrow.*.sites;
    _ = scenario;
    if (borrow.attack.* == 2) {
        try std.testing.expectEqual(
            .away,
            (try borrow.imported.copied.*.placementStatus(
                namespaces_view.*.scratch.*,
                borrow.controller.*,
            )).?.phase,
        );
        try std.testing.expectError(
            error.InvalidTransfer,
            borrow.imported.copied.*.placementAbortUnsent(
                namespaces_view.*.scratch.*,
                borrow.controller.*,
                @splat(71),
            ),
        );
    }
    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.imported.copied.*.resumeTask(
            namespaces_view.*.scratch.*,
            "untrusted-resume",
            sites_view.*.subject.*.task,
            1,
        ),
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        borrow.imported.copied.*.requestCancel(
            namespaces_view.*.scratch.*,
            "untrusted-cancel",
            sites_view.*.subject.*.task,
            "stop",
        ),
    );

    return false;
}

fn placementParkRemoteAcknowledgement(comptime scenario: anytype, borrow: anytype) !void {
    var acknowledged = false;
    for (0..4) |_| {
        if (try placementAdvanceRemoteAcknowledgement(scenario, .{
            .acknowledged = &acknowledged,
            .borrow = &borrow,
        })) break;
    }
    try std.testing.expect(acknowledged);
}

fn placementAdvanceRemoteAcknowledgement(comptime scenario: anytype, borrow: anytype) !bool {
    const fixture_view = &borrow.borrow.*.borrow.*.borrow.*.fixture;
    const p = native.placement;
    _ = try fixture_view.*.sender.*.pump(
        fixture_view.*.scratch.*,
    );
    const command = (try pendingCleanup(
        &fixture_view.*.sender.*,
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
    )).?;
    try fixture_view.*.sender.*.close(
        fixture_view.*.a.*,
    );
    fixture_view.*.sender_open.* = false;
    try fixture_view.*.source_namespace.*.close();
    fixture_view.*.source_open.* = false;
    var report: p.Signed(p.Report) = undefined;

    try placementExecuteRemoteAcknowledgement(scenario, .{
        .borrow = &borrow,
        .command = &command,
        .report = &report,
    });

    fixture_view.*.source_namespace.* = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.source_path.*,
    );
    fixture_view.*.source_open.* = true;
    fixture_view.*.sender.* = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &fixture_view.*.source_namespace.*,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.borrow.*.borrow.*.ack.ack_source_profile.*,
    );
    fixture_view.*.sender_open.* = true;
    try fixture_view.*.sender.*.placementApplyReport(
        fixture_view.*.scratch.*,
        fixture_view.*.subject.*.task,
        p.controlId(command.value),
        report,
    );
    if (borrow.acknowledged.*) return true;

    return false;
}

fn placementExecuteRemoteAcknowledgement(comptime scenario: anytype, borrow: anytype) !void {
    const fixture_view = &borrow.borrow.*.borrow.*.borrow.*.borrow.*.fixture;
    _ = scenario;
    const p = native.placement;
    var ns = try native.Namespace.open(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        fixture_view.*.destination_path.*,
    );
    defer support.expectCleanup(ns.close());
    var executor = try native.tasks.Service(OwnerTypes).init(
        fixture_view.*.a.*,
        fixture_view.*.io.*,
        &ns,
        fixture_view.*.assets.*,
        &fixture_view.*.application.*,
        fixture_view.*.handlers.*,
        borrow.borrow.*.borrow.*.borrow.*.borrow.*.ack.ack_destination_profile.*,
    );
    defer support.expectCleanup(
        executor.close(fixture_view.*.a.*),
    );
    borrow.report.* = (try contracts.decodeOwned(
        p.Signed(p.Report),
        fixture_view.*.scratch.*,
        try executor.placementExecuteControl(
            fixture_view.*.scratch.*,
            "source",
            borrow.command.*,
        ),
    )).value;
    try std.testing.expectEqual(.observed, borrow.report.*.value.reply.disposition);
    if (borrow.command.*.value.command == .cancel) {
        const current = borrow.report.*.value.work_state.?;
        try std.testing.expect(
            current.cancellation != null and !current.cleanup_complete,
        );
        _ = try executor.workspaceControl(
            fixture_view.*.scratch.*,
            "ack-remote-park",
            fixture_view.*.subject.*.task,
            fixture_view.*.work_id.*,
            current.execution_revision,
            current.control_revision,
            .park,
        );
        borrow.borrow.*.acknowledged.* = true;
    }
}

fn placementCheckFrozenCommandCut(comptime scenario: anytype, borrow: anytype) !bool {
    const context_fixture = &borrow.prior.*.prior.*.prior.*.prior.*.fixture;
    const context_frozen = &borrow.prior.*.prior.*.prior.*.prior.*.frozen;
    try std.testing.expectEqualDeep(
        context_frozen.*.controller_cut.*,
        try context_fixture.*.sender.*.placementCut(
            context_fixture.*.scratch.*,
            context_frozen.*.controller.*,
        ),
    );
    if (scenario == .root) _ = try context_fixture.*.sender.*.workspacePump(
        context_fixture.*.scratch.*,
        "independent-local-progress",
        context_fixture.*.subject.*.task,
        .{
            .expected = .{
                .work = context_fixture.*.work_ref.*,
                .execution_revision = context_fixture.*.cut.*.execution,
                .control_revision = context_fixture.*.cut.*.control,
            },
            .base_quantum = 1,
        },
    );
    return placementInspectFrozenParent(scenario, .{
        .fixture = context_fixture.*,
        .frozen = context_frozen.*,
    });
}

fn placementReopenReportedController(comptime scenario: anytype, borrow: anytype) !void {
    const context_application = &borrow.prior.*.prior.*.prior.*.prior.*.prior.*.application;
    const context_namespaces = &borrow.prior.*.prior.*.prior.*.prior.*.prior.*.namespaces;
    const context_controller = &borrow.prior.*.prior.*.prior.*.prior.*.prior.*.controller;
    const context_services = &borrow.prior.*.prior.*.prior.*.prior.*.prior.*.services;
    const context_setup = &borrow.prior.*.prior.*.prior.*.prior.*.prior.*.setup;
    const context_sites = &borrow.prior.*.prior.*.prior.*.prior.*.prior.*.sites;
    const context_state = &borrow.prior.*.prior.*.prior.*.prior.*.state;
    const context_prior = &borrow.prior.*.prior.*.prior.*.prior.*.prior;
    const context_state_view = &borrow.prior.*.prior.*.prior.*.state;
    const p = native.placement;
    context_services.*.sender.* = try native.tasks.Service(OwnerTypes).init(
        context_setup.*.a.*,
        context_setup.*.io.*,
        &context_namespaces.*.source_namespace.*,
        context_application.*.assets.*,
        &context_application.*.application.*,
        context_application.*.handlers.*,
        context_controller.*.source_profile.*,
    );
    context_services.*.sender_open.* = true;
    if (scenario == .work) {
        const compiler_facts = context_services.*.controller_compiler_facts;
        context_services.*.sender.*.compiler_facts = compiler_facts;
    }
    try context_services.*.sender.*.placementApplyReport(
        context_namespaces.*.scratch.*,
        context_sites.*.subject.*.task,
        p.controlId(context_state.*.control.*.value.value),
        borrow.state.report.*.value,
    );
    try context_services.*.sender.*.placementApplyReport(
        context_namespaces.*.scratch.*,
        context_sites.*.subject.*.task,
        p.controlId(context_state.*.control.*.value.value),
        borrow.state.report.*.value,
    );

    if (try placementOnwardControllerWitness(scenario, .{
        .borrow = &context_prior.*.*,
        .control = &context_state.*.control.*,
        .report_bytes = &borrow.prior.*.state.report_bytes.*,
    })) return;

    // Advance the controller after its worker was exported. The worker has
    // never received this controller checkpoint, and a succession proof must
    // not require that private object to be retained locally.
    return placementAdvanceController(scenario, .{
        .report = .{
            .control = &context_state.*.control.*,
            .controller_cut = &context_state_view.*.controller_cut.*,
            .controller_subject = &context_state_view.*.controller_subject.*,
        },
        .application = context_application.*,
        .channels = context_prior.*.*.channels,
        .child = context_prior.*.*.child,
        .controller = context_controller.*,
        .generated = context_prior.*.*.generated,
        .namespaces = context_namespaces.*,
        .peers = context_prior.*.*.peers,
        .receiver = context_prior.*.*.receiver,
        .services = context_services.*,
        .setup = context_setup.*,
        .sites = context_sites.*,
        .work = context_prior.*.*.work,
    });
}

fn placementRefuseFrozenRoot(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (scenario == .root_cancel_refused) {
        const frozen_path = try std.fmt.allocPrint(
            borrow.borrow.*.fixture.scratch.*,
            "{s}/cancelled-controller.par",
            .{
                borrow.borrow.*.fixture.path_buffer.*[0..borrow.borrow.*.fixture.length.*],
            },
        );
        const frozen_offer = try offerPlacement(
            &borrow.borrow.*.fixture.sender.*,
            borrow.controller.*,
            "destination",
            frozen_path,
        );
        borrow.refusal.* = try p.sign(
            p.Decision,
            borrow.borrow.*.fixture.scratch.*,
            borrow.borrow.*.fixture.destination_key.*,
            .{
                .transfer = frozen_offer.value.intent.transfer,
                .offer_digest = try p.digest(
                    p.Offer,
                    borrow.borrow.*.fixture.scratch.*,
                    frozen_offer.value,
                ),
                .source = borrow.borrow.*.fixture.source_site.*,
                .destination = borrow.borrow.*.fixture.destination_site.*,
                .epoch = frozen_offer.value.intent.epoch + 1,
                .verdict = .{
                    .refused = .withdrawn,
                },
            },
        );
    }
}

fn placementRefuseFrozenShutdown(comptime scenario: anytype, borrow: anytype) !void {
    const p = native.placement;
    if (scenario == .root_cancel_refused) {
        const frozen_path = try std.fmt.allocPrint(
            borrow.borrow.*.fixture.scratch.*,
            "{s}/shutdown-controller.par",
            .{
                borrow.borrow.*.fixture.path_buffer.*[0..borrow.borrow.*.fixture.length.*],
            },
        );
        const frozen_offer = try offerPlacement(
            &borrow.borrow.*.fixture.sender.*,
            borrow.shutdown_subject.*,
            "destination",
            frozen_path,
        );
        borrow.borrow.*.frozen.refusal.* = try p.sign(
            p.Decision,
            borrow.borrow.*.fixture.scratch.*,
            borrow.borrow.*.fixture.destination_key.*,
            .{
                .transfer = frozen_offer.value.intent.transfer,
                .offer_digest = try p.digest(
                    p.Offer,
                    borrow.borrow.*.fixture.scratch.*,
                    frozen_offer.value,
                ),
                .source = borrow.borrow.*.fixture.source_site.*,
                .destination = borrow.borrow.*.fixture.destination_site.*,
                .epoch = frozen_offer.value.intent.epoch + 1,
                .verdict = .{
                    .refused = .withdrawn,
                },
            },
        );
    }
}

fn placementRejectForeignFreeze(comptime scenario: anytype, borrow: anytype) !void {
    _ = scenario;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = borrow.borrow.*.prior.*.services.sender.*.profile.authority;
        defer borrow.borrow.*.prior.*.services.sender.*.profile.authority = authority;
        const before = borrow.borrow.*.prior.*.namespaces.source_namespace.*.store.head;
        @field(borrow.borrow.*.prior.*.services.sender.*.profile.authority, field) = "foreign";
        try std.testing.expectError(
            error.Denied,
            borrow.borrow.*.prior.*.services.sender.*.task(
                borrow.borrow.*.prior.*.namespaces.scratch.*,
                borrow.borrow.*.prior.*.sites.subject.*.task,
            ),
        );
        try std.testing.expectError(
            error.Denied,
            borrow.borrow.*.prior.*.services.sender.*.placementAbortUnsent(
                borrow.borrow.*.prior.*.namespaces.scratch.*,
                borrow.borrow.*.prior.*.sites.subject.*,
                @splat(14),
            ),
        );
        try std.testing.expectError(
            error.Denied,
            freezePlacement(
                &borrow.borrow.*.prior.*.services.sender.*,
                borrow.borrow.*.prior.*.sites.subject.*,
                "destination",
                borrow.borrow.*.prior.*.sites.cut.*,
                @splat(14),
            ),
        );
        try std.testing.expectEqualDeep(
            before,
            borrow.borrow.*.prior.*.namespaces.source_namespace.*.store.head,
        );
    }
}

fn placementRejectGeneratedPolicy(comptime scenario: anytype, borrow: anytype) !void {
    _ = scenario;
    if (borrow.context_generated.generated.* != null) {
        const allowed_policy = borrow.context_services.*.*.receiver.*.profile.semantic_construction;
        defer borrow.context_services.*.*.receiver.*.profile.semantic_construction = allowed_policy;
        const wrong_roots = [_][32]u8{@splat(97)};
        borrow.context_services.*.*.receiver.*.profile.semantic_construction.?.roots = &wrong_roots;
        try std.testing.expectError(
            error.SemanticPolicyDenied,
            acceptPlacement(
                &borrow.context_services.*.*.receiver.*,
                "accept",
                "source",
                borrow.context_transfer.*.*.offer.*,
                borrow.context_offered.*.*.archive_path.*,
            ),
        );
        try std.testing.expectEqualDeep(
            borrow.borrow.*.prior.*.prior.*.state.receiver_head.*,
            borrow.context_namespaces.*.*.destination_namespace.*.store.head,
        );
        borrow.context_services.*.*.receiver.*.profile.semantic_construction = allowed_policy;
        borrow.context_services.*.*.receiver.*.profile.semantic_construction.?.checkers = &.{
            "different-checker",
        };
        try std.testing.expectError(
            error.SemanticPolicyDenied,
            acceptPlacement(
                &borrow.context_services.*.*.receiver.*,
                "accept",
                "source",
                borrow.context_transfer.*.*.offer.*,
                borrow.context_offered.*.*.archive_path.*,
            ),
        );
        try std.testing.expectEqualDeep(
            borrow.borrow.*.prior.*.prior.*.state.receiver_head.*,
            borrow.context_namespaces.*.*.destination_namespace.*.store.head,
        );
        try std.testing.expectError(
            error.UnknownTask,
            borrow.context_services.*.*.receiver.*.placementStatus(
                borrow.context_namespaces.*.*.scratch.*,
                borrow.context_sites.*.*.subject.*,
            ),
        );
    }
}

const ObserverWitness = struct {
    selection: contracts.workspace.Observe,
    work: [32]u8,
    receipt: [32]u8,
    scheduled: ScheduledObserverWitness,
};

const ScheduledObserverWitness = struct {
    previous: [32]u8,
    cursor: u64,
    accumulated: u64,
    parked_source: ?[32]u8 = null,
};
fn disclosedViewWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    original: contracts.workspace.Command,
) !void {
    for ([_]bool{ false, true }) |values| {
        var command = original;
        command.context.materialize.input.guest_view.disclosure = .{
            .values = if (values) .{ .nodes = .{ .all = .{} } } else .{ .none = .{} },
        };
        const operation_id = if (values) "disclosed-values" else "undisclosed-values";
        const response = try service.workspaceCommand(a, operation_id, task, command);
        try std.testing.expectEqual(.observed, response.disposition);
        const id = try nativeIdentity(response.evidence.?);
        const custody = try native.workspace.custodyId(a, task, id);
        const bytes = (try service.namespace.store.recordBytes(
            a,
            "workspace_value",
            custody,
            task,
        )).?;
        defer a.free(bytes);
        var record = try contracts.decodeOwned(native.workspace.Value, a, bytes);
        defer record.deinit();
        const value = try service.namespace.store.object(a, record.value.description.value, null);
        defer a.free(value);
        var view = try contracts.decodeOwned(kosmos.RuntimeViews.DetailedView, a, value);
        defer view.deinit();
        try std.testing.expect(view.value.metadata.complete_graph);
        const coverage: kosmos.RuntimeViews.Coverage = if (values) .complete else .not_requested;
        try std.testing.expectEqual(coverage, view.value.value_coverage);
        if (values) {
            try std.testing.expect(view.value.values.len != 0);
        } else try std.testing.expectEqual(@as(usize, 0), view.value.values.len);
        try std.testing.expectEqual(@as(usize, 0), view.value.blobs.len);
    }
}

fn outerViewWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work: native.workspace.Work,
) !void {
    const response = try service.workspaceCommand(a, "outer-view", task, .{
        .context = .{ .materialize = .{
            .input = .{ .guest_view = .{
                .level = .outer_execution,
                .expected = .{
                    .work = try workspaceRef(a, .work, work.id),
                    .execution_revision = work.execution_revision,
                    .control_revision = work.control_revision,
                },
                .realization_revision = work.realization_revision,
                .nodes = .{ .selected = .{ .items = &.{} } },
            } },
            .sources = .{ .items = &.{} },
        } },
    });
    try std.testing.expectEqual(.observed, response.disposition);
    const value_id = try nativeIdentity(response.evidence.?);
    const custody = try native.workspace.custodyId(a, task, value_id);
    const bytes = (try service.namespace.store.recordBytes(a, "workspace_value", custody, task)).?;
    defer a.free(bytes);
    var record = try contracts.decodeOwned(native.workspace.Value, a, bytes);
    defer record.deinit();
    const encoded = try service.namespace.store.object(a, record.value.description.value, null);
    defer a.free(encoded);
    var outer = try contracts.decodeOwned(kosmos.RuntimeCapsule.OuterView, a, encoded);
    defer outer.deinit();
    try std.testing.expectEqual(.advance, outer.value.capsule.operation.?);
    try std.testing.expect(!outer.value.state.metadata.complete_graph);
    try std.testing.expectEqual(.not_requested, outer.value.state.value_coverage);
    try std.testing.expectEqual(@as(usize, 0), outer.value.state.values.len);
}

fn observerAccumulator(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
) !contracts.workspace.Ref {
    var admitted = try service.workspaceProgram(a, task, program);
    defer admitted.deinit();
    const operation_id = try std.fmt.allocPrint(a, "observer-accumulator-{s}", .{
        std.fmt.bytesToHex(task, .lower),
    });
    defer a.free(operation_id);
    const materialized = try service.workspaceCommand(a, operation_id, task, .{
        .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{
                .schema = try workspaceRef(
                    a,
                    .schema,
                    admitted.value.description.result_schema.digest,
                ),
                .json_text = .{ .bytes = "\"0\"" },
            } } },
            .sources = .{ .items = &.{} },
        } },
    });
    if (materialized.disposition != .observed)
        std.debug.print("observer accumulator rejection: {s}\n", .{
            materialized.observation_json.bytes,
        });
    try std.testing.expectEqual(.observed, materialized.disposition);
    var observed = try native.json.parse(a, materialized.observation_json.bytes, .{});
    defer observed.deinit();
    var reference = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        observed.value.object.get("value").?,
    );
    reference.id.bytes = try a.dupe(u8, reference.id.bytes);
    return reference;
}

fn observerWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
) !ObserverWitness {
    const started = try service.workspaceStart(a, "observer-source", task, program, input, .{});
    var source_work = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer source_work.deinit();
    var selection = try observerSelection(service, a, task, program, source_work.value);
    try staleObserverRetry(service, a, task, program, input, selection);
    return observerFoldWitness(service, a, task, program, input, source_work.value, &selection);
}

test "runtime selection current observer ownership bounds retained fold reads" {
    try withWorkspaceFixture(
        "observer-owner-unit",
        "observer-owner-test",
        exerciseCurrentObserverOwnership,
    );
}

fn observeCurrentOwner(
    service: anytype,
    scratch: std.mem.Allocator,
    task: [16]u8,
) !void {
    const program = try semanticGuestProgram(
        scratch,
        service,
        task,
        "current-observer-program",
    );
    const input = try contracts.encodeOwned(@import(
        "workspace_sources.zig",
    ).SemanticGuestInput, scratch, .{ .yields = 300, .seed = 100 });
    const started = try service.workspaceStart(
        scratch,
        "current-observer-selection",
        task,
        program,
        input,
        .{},
    );
    var work = try service.workspaceWork(scratch, task, started.receipt.workspace.?);
    defer work.deinit();
    try guestWorkTamper(scratch, service, work.value);
    const selection = try observerSelection(service, scratch, task, program, work.value);
    try observerCurrentOwnershipWitness(service, scratch, task, program, input, selection);
    try service.park(scratch);
    try outerObserverWitness(service, scratch, task, program, input, selection.accumulator);
    try logicalObserverWitness(service, scratch, task);
}

fn exerciseCurrentObserverOwnership(
    a: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var namespace = try native.Namespace.open(
        a,
        io,
        try std.fmt.allocPrint(scratch, "{s}/state", .{path_buffer[0..length]}),
    );
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });
    try observeCurrentOwner(&service, scratch, parent.receipt.task);
}

fn traceObservedAdvance(
    service: anytype,
    a: std.mem.Allocator,
    current: native.workspace.Work,
    index: usize,
) !CleanupTrace {
    var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
    const database = CleanupTrace.sqlite3_db_handle(statement.handle);
    statement.deinit();
    var trace: CleanupTrace = .{};
    try std.testing.expectEqual(
        @as(c_int, 0),
        CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace),
    );
    defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
    try advanceObservedSource(
        service,
        a,
        current,
        try std.fmt.allocPrint(a, "current-observer-step-{d}", .{index}),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        CleanupTrace.sqlite3_trace_v2(database, 0, null, null),
    );
    try std.testing.expectEqual(@as(usize, 0), trace.scans);
    return trace;
}

fn stepCurrentObserver(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    current: anytype,
    selection: *contracts.workspace.Observe,
    reads: *[3]usize,
    index: usize,
) !void {
    selection.source.expected = .{
        .work = try workspaceRef(a, .work, current.value.id),
        .execution_revision = current.value.execution_revision,
        .control_revision = current.value.control_revision,
    };
    const observed = try service.workspaceObserve(
        a,
        try std.fmt.allocPrint(a, "current-observer-fold-{d}", .{index}),
        task,
        selection.*,
    );
    try observerCompleted(service, a, task, observed.receipt.workspace.?);
    var unchanged = try service.workspaceWork(a, task, current.value.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(current.value, unchanged.value);
    var owner = try service.task(a, task);
    defer owner.deinit();
    try std.testing.expectEqual(@as(usize, 1), owner.value.observer_heads.items.len);
    try std.testing.expectEqualDeep(
        observed.receipt.workspace.?,
        owner.value.observer_heads.items[0],
    );
    if (selection.previous) |previous| {
        var prior = try service.workspaceWork(a, task, try nativeIdentity(previous));
        defer prior.deinit();
        try std.testing.expectEqual(
            @as(?[32]u8, observed.receipt.workspace.?),
            prior.value.observer.?.successor,
        );
    }
    const trace = try traceObservedAdvance(service, a, current.value, index);
    if (index == 3 or index == 7 or index == 15) {
        const slot: usize = if (index == 3) 0 else if (index == 7) 1 else 2;
        reads[slot] = trace.work_reads;
        std.debug.print("current observer work reads: folds={d} reads={d} inventories={d}\n", .{
            index + 1,
            trace.work_reads,
            trace.scans,
        });
    }
    const next = try service.workspaceWork(a, task, current.value.id);
    current.deinit();
    current.* = next;
    selection.previous = try workspaceRef(a, .work, observed.receipt.workspace.?);
    if (index == 3 or index == 7 or index == 15)
        try currentObserverBatchWitness(
            service,
            a,
            task,
            current.value,
            true,
            try std.fmt.allocPrint(a, "folds-{d}", .{index + 1}),
        );
}

fn parallelObserverRevisions(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    current: anytype,
    selection: *contracts.workspace.Observe,
) !void {
    selection.previous = null;
    selection.source.expected = .{
        .work = try workspaceRef(a, .work, current.value.id),
        .execution_revision = current.value.execution_revision,
        .control_revision = current.value.control_revision,
    };
    const older = try service.workspaceObserve(a, "parallel-observer-older", task, selection.*);
    try observerCompleted(service, a, task, older.receipt.workspace.?);
    try advanceObservedSource(service, a, current.value, "parallel-observer-source");
    const advanced = try service.workspaceWork(a, task, current.value.id);
    current.deinit();
    current.* = advanced;
    selection.source.expected.execution_revision = current.value.execution_revision;
    selection.source.expected.control_revision = current.value.control_revision;
    const newer = try service.workspaceObserve(a, "parallel-observer-newer", task, selection.*);
    try observerCompleted(service, a, task, newer.receipt.workspace.?);
    try currentObserverBatchWitness(service, a, task, current.value, true, "parallel-revisions");
    try std.testing.expectError(
        error.ObservationBlocked,
        advanceObservedSource(service, a, current.value, "parallel-observer-blocked"),
    );
    for ([_][32]u8{ older.receipt.workspace.?, newer.receipt.workspace.? }, 0..) |id, i| {
        var observer = try service.workspaceWork(a, task, id);
        defer observer.deinit();
        _ = try service.workspaceStopObserving(
            a,
            try std.fmt.allocPrint(a, "parallel-observer-stop-{d}", .{i}),
            task,
            .{
                .work = try workspaceRef(a, .work, id),
                .execution_revision = observer.value.execution_revision,
                .control_revision = observer.value.control_revision,
            },
        );
        try currentObserverBatchWitness(
            service,
            a,
            task,
            current.value,
            false,
            try std.fmt.allocPrint(a, "parallel-stop-{d}", .{i}),
        );
    }
}

fn finishCurrentObserver(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    current: anytype,
    selection: *contracts.workspace.Observe,
    reads: [3]usize,
) !void {
    var last = try service.workspaceWork(a, task, try nativeIdentity(selection.previous.?));
    defer last.deinit();
    try observerOwnershipTamper(service, a, last.value);
    _ = try service.workspaceStopObserving(a, "current-observer-stop", task, .{
        .work = selection.previous.?,
        .execution_revision = last.value.execution_revision,
        .control_revision = last.value.control_revision,
    });
    for (reads) |count| try std.testing.expect(count > 0 and count <= 8);
    var owner = try service.task(a, task);
    defer owner.deinit();
    try std.testing.expectEqual(@as(usize, 0), owner.value.observer_heads.items.len);
    try currentObserverBatchWitness(service, a, task, current.value, false, "stopped");
    try parallelObserverRevisions(service, a, task, current, selection);
}

fn observerCurrentOwnershipWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    original: contracts.workspace.Observe,
) !void {
    const started = try service.workspaceStart(
        a,
        "current-observer-source",
        task,
        program,
        input,
        .{},
    );
    var current = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer current.deinit();
    var selection = original;
    selection.previous = null;
    var reads: [3]usize = undefined;
    for (0..16) |index| {
        try stepCurrentObserver(service, a, task, &current, &selection, &reads, index);
    }
    try finishCurrentObserver(service, a, task, &current, &selection, reads);
}

fn observerOwnershipTamper(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
) !void {
    var owner = try service.task(a, work.task);
    defer owner.deinit();
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &digest, .{});
    const manifest: native.testing.state.Reference = .{
        .digest = digest,
        .bytes = service.assets.manifest.len,
    };
    const valid = try service.namespace.store.archiveIndex(a, work.task, manifest);
    try service.validateWorkspaceRecordsPrepared(a, work.task, valid.records.items, &facts);
    for (0..3) |attack| {
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        var changed = owner.value;
        const duplicate = [_][32]u8{ work.id, work.id };
        const previous = try nativeIdentity(work.observer.?.selection.previous.?);
        changed.observer_heads.items = switch (attack) {
            0 => &.{},
            1 => &duplicate,
            2 => &.{previous},
            else => unreachable,
        };
        const encoded = try contracts.encodeOwned(native.testing.state.Task, a, changed);
        defer a.free(encoded);
        const reference = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{
            .blob = &reference.digest,
        }, .{ .blob = &work.task } });
        const index = try service.namespace.store.archiveIndex(a, work.task, manifest);
        try std.testing.expectError(
            error.InvalidArchive,
            service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts),
        );
    }
    {
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        const previous = try nativeIdentity(work.observer.?.selection.previous.?);
        var prior = try service.workspaceWork(a, work.task, previous);
        defer prior.deinit();
        prior.value.observer.?.successor = null;
        try service.namespace.store.putRecord(
            native.workspace.Work,
            "workspace_work",
            previous,
            work.task,
            prior.value,
        );
        const index = try service.namespace.store.archiveIndex(a, work.task, manifest);
        try std.testing.expectError(
            error.InvalidArchive,
            service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts),
        );
    }
}

fn staleObserverRetry(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    original: contracts.workspace.Observe,
) !void {
    const started = try service.workspaceStart(
        a,
        "retry-observer-source",
        task,
        program,
        input,
        .{},
    );
    var source_work = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer source_work.deinit();
    var selection = original;
    selection.source.expected = .{
        .work = try workspaceRef(a, .work, source_work.value.id),
        .execution_revision = source_work.value.execution_revision,
        .control_revision = source_work.value.control_revision,
    };
    var failing: AfterCommitAllocator = .{
        .backing = a,
        .namespace = service.namespace,
        .generation = service.namespace.store.head.generation,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        service.workspaceObserve(failing.allocator(), "retry-observer", task, selection),
    );
    try std.testing.expect(failing.rejected != 0);
    try advanceObservedSource(service, a, source_work.value, "retry-observer-advance-one");
    var middle = try service.workspaceWork(a, task, source_work.value.id);
    defer middle.deinit();
    try advanceObservedSource(service, a, middle.value, "retry-observer-advance-two");
    try std.testing.expectError(
        error.StaleRevision,
        service.workspaceObserve(a, "retry-observer", task, selection),
    );
    var current = try service.workspaceWork(a, task, source_work.value.id);
    defer current.deinit();
    selection.source.expected.execution_revision = current.value.execution_revision;
    selection.source.expected.control_revision = current.value.control_revision;
    selection.policy.continuation = .owner_scheduled;
    const fresh = try service.workspaceObserve(a, "retry-observer-fresh", task, selection);
    try observerCompleted(service, a, task, fresh.receipt.workspace.?);
    var observed = try service.workspaceWork(a, task, fresh.receipt.workspace.?);
    defer observed.deinit();
    try std.testing.expectEqual(
        current.value.execution_revision,
        observed.value.observer.?.consumed_revision.?,
    );
    const successor = try automaticObserverRetry(service, a, observed.value, current.value);
    observed.deinit();
    observed = try service.workspaceWork(a, task, successor);
    _ = try service.workspaceStopObserving(a, "retry-observer-stop", task, .{
        .work = try workspaceRef(a, .work, observed.value.id),
        .execution_revision = observed.value.execution_revision,
        .control_revision = observed.value.control_revision,
    });
    try sharedCancel(a, service, task, current.value.id, "retry-observer-cancel");
}

fn automaticObserverRetry(
    service: anytype,
    a: std.mem.Allocator,
    observer: native.workspace.Work,
    source_work: native.workspace.Work,
) ![32]u8 {
    try advanceObservedSource(service, a, source_work, "automatic-observer-source-step");
    var advanced = try service.workspaceWork(a, source_work.task, source_work.id);
    defer advanced.deinit();
    var failing: AfterCommitAllocator = .{
        .backing = a,
        .namespace = service.namespace,
        .generation = service.namespace.store.head.generation,
    };
    var failed = false;
    for (0..128) |_| {
        _ = service.pump(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed = true;
            break;
        };
    }
    try std.testing.expect(failed and failing.rejected != 0);
    try std.testing.expectEqual(
        null,
        try observerSuccessor(service, a, observer.task, observer.id),
    );
    _ = try service.workspaceControl(
        a,
        "automatic-observer-source-park",
        advanced.value.task,
        advanced.value.id,
        advanced.value.execution_revision,
        advanced.value.control_revision,
        .park,
    );
    var parked = try service.workspaceWork(a, source_work.task, source_work.id);
    defer parked.deinit();
    try std.testing.expectEqualDeep(advanced.value.checkpoint, parked.value.checkpoint);
    try std.testing.expectEqual(advanced.value.execution_revision, parked.value.execution_revision);
    for (0..128) |_| {
        _ = try service.pump(a);
        if (try observerSuccessor(service, a, observer.task, observer.id)) |id| {
            try observerCompleted(service, a, observer.task, id);
            var completed = try service.workspaceWork(a, observer.task, id);
            defer completed.deinit();
            try std.testing.expectEqual(
                advanced.value.execution_revision,
                completed.value.observer.?.consumed_revision.?,
            );
            for (0..4) |_| _ = try service.pump(a);
            try std.testing.expectEqual(
                id,
                (try observerSuccessor(service, a, observer.task, observer.id)).?,
            );
            try std.testing.expectEqual(null, try observerSuccessor(service, a, observer.task, id));
            return id;
        }
    }
    return error.AutomaticObserverRetryDidNotComplete;
}

fn observerCopyOwnership(original: native.workspace.Observer) !void {
    const nodes = [_]u64{ 0, 2 };
    var observer = original;
    observer.selection.source.nodes = .{ .selected = .{ .items = &nodes } };
    observer.selection.source.disclosure = .{
        .values = .{ .fields = .{ .items = &.{
            .{ .node = 0, .field = .{ .bytes = "first" } },
            .{ .node = 2, .field = .{ .bytes = "second" } },
        } } },
        .blobs = .{ .items = &.{.{ .blob = 1, .offset = 2, .length = 3 }} },
    };
    const Check = struct {
        fn run(a: std.mem.Allocator, value: native.workspace.Observer) !void {
            const copied = try native.testing.workspace_observers.copyObserver(a, value);
            defer native.testing.workspace_observers.freeObserver(a, copied);
            try std.testing.expectEqualDeep(value, copied);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{observer});
    observer.selection.source.disclosure.?.values = .{ .nodes = .{ .selected = .{
        .items = &nodes,
    } } };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{observer});
}

fn observerSelection(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    work: native.workspace.Work,
) !contracts.workspace.Observe {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").cutObserver(&builder, false);
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(a, "observer-program", task, text, &diagnostic);
    return .{
        .program = try workspaceRef(a, .program, built.receipt.workspace.?),
        .source = .{ .expected = .{
            .work = try workspaceRef(a, .work, work.id),
            .execution_revision = work.execution_revision,
            .control_revision = work.control_revision,
        }, .realization_revision = 0, .nodes = .{ .all = .{} } },
        .accumulator = try observerAccumulator(service, a, task, program),
        .policy = .{ .delivery = .lossless, .granularity = .one_guest_step },
    };
}

fn exerciseObserverContinuations(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    source_id: [32]u8,
    folded_id: [32]u8,
    selection: contracts.workspace.Observe,
) !ScheduledObserverWitness {
    try cancelObservedSourceWitness(service, a, task, source_id, folded_id);
    try incompleteObserverWitness(service, a, task, selection);
    try lateObserverWitness(service, a, task, program, input, selection);
    try outerObserverWitness(service, a, task, program, input, selection.accumulator);
    var scheduled = try sampledObserverWitness(service, a, task, program, input, selection);
    scheduled.parked_source = source_id;
    return scheduled;
}

fn assertObserverFold(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    source_work: native.workspace.Work,
    advanced: native.workspace.Work,
    folded: native.workspace.Work,
    advance: contracts.workspace.Command,
    blocked: contracts.workspace.Reply,
) !void {
    try observerArchiveTamper(service, a, folded);
    try observerCopyOwnership(folded.observer.?);
    try std.testing.expectEqual(
        advanced.execution_revision,
        folded.observer.?.consumed_revision.?,
    );
    try std.testing.expectEqual(null, folded.observer.?.gap_first);
    const replay = try service.workspaceCommand(a, "observed-source-step", task, advance);
    try std.testing.expectEqualStrings(
        blocked.observation_json.bytes,
        replay.observation_json.bytes,
    );
    try observerFoldValue(service, a, folded, source_work.execution_revision +
        advanced.execution_revision);
}

fn observerFoldWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    source_work: native.workspace.Work,
    selection: *contracts.workspace.Observe,
) !ObserverWitness {
    const first = try service.workspaceObserve(a, "observe-first", task, selection.*);
    try observerCompleted(service, a, task, first.receipt.workspace.?);
    try advanceObservedSource(service, a, source_work, "observed-source-step");
    var advanced = try service.workspaceWork(a, task, source_work.id);
    defer advanced.deinit();
    try std.testing.expect(advanced.value.guest_work <= 1);
    try currentObserverBatchWitness(service, a, task, advanced.value, true, "guest-cut");
    try std.testing.expectError(
        error.ObservationBlocked,
        advanceObservedSource(service, a, advanced.value, "observed-source-blocked"),
    );
    const advance: contracts.workspace.Command = .{ .work = .{ .advance = .{
        .work = selection.source.expected.work,
        .execution_revision = source_work.execution_revision,
        .control_revision = source_work.control_revision,
    } } };
    const blocked = try service.workspaceCommand(a, "observed-source-step", task, advance);
    try std.testing.expectEqual(.observed, blocked.disposition);
    selection.source.expected.execution_revision = advanced.value.execution_revision;
    selection.source.expected.control_revision = advanced.value.control_revision;
    selection.previous = try workspaceRef(a, .work, first.receipt.workspace.?);
    const second = try service.workspaceObserve(a, "observe-second", task, selection.*);
    try observerCompleted(service, a, task, second.receipt.workspace.?);
    const repeated = try service.workspaceObserve(a, "observe-second", task, selection.*);
    try std.testing.expect(repeated.replayed);
    try std.testing.expectEqualDeep(second.receipt.id, repeated.receipt.id);
    var folded = try service.workspaceWork(a, task, second.receipt.workspace.?);
    defer folded.deinit();
    try assertObserverFold(
        service,
        a,
        task,
        source_work,
        advanced.value,
        folded.value,
        advance,
        blocked,
    );
    return finishObserverFold(service, a, task, program, input, selection, .{
        .source = source_work.id,
        .checkpoint = advanced.value.checkpoint,
        .receipt = second.receipt.id,
        .folded = folded.value.id,
    });
}

fn finishObserverFold(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    selection: *contracts.workspace.Observe,
    witness: anytype,
) !ObserverWitness {
    var unchanged = try service.workspaceWork(a, task, witness.source);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(witness.checkpoint, unchanged.value.checkpoint);
    try advanceObservedSource(service, a, unchanged.value, "observer-source-after-fold");
    const historical = try service.workspaceObserve(a, "observe-second", task, selection.*);
    try std.testing.expect(historical.replayed);
    try std.testing.expectEqualDeep(witness.receipt, historical.receipt.id);
    const scheduled = try exerciseObserverContinuations(
        service,
        a,
        task,
        program,
        input,
        witness.source,
        witness.folded,
        selection.*,
    );
    return .{
        .selection = selection.*,
        .work = witness.folded,
        .receipt = witness.receipt,
        .scheduled = scheduled,
    };
}

fn advanceObservedSource(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
    operation_id: []const u8,
) !void {
    _ = try service.workspaceControl(
        a,
        operation_id,
        work.task,
        work.id,
        work.execution_revision,
        work.control_revision,
        .advance,
    );
}

fn cancelObservedSourceWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    id: [32]u8,
    observer_id: [32]u8,
) !void {
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    _ = try service.workspaceControl(
        a,
        "cancel-observed-source",
        task,
        id,
        before.value.execution_revision,
        before.value.control_revision,
        .{ .cancel = .{ .bytes = "cancel after pinned cut" } },
    );
    var after = try service.workspaceWork(a, task, id);
    defer after.deinit();
    try std.testing.expect(after.value.cancellation != null);
    try std.testing.expect(!after.value.cancellation_applied);
    try std.testing.expectEqual(.queued, after.value.schedule);
    try std.testing.expectEqual(.observation_blocked, after.value.blocker.?);
    try std.testing.expectEqual(before.value.execution_revision, after.value.execution_revision);
    try std.testing.expectEqualDeep(before.value.checkpoint, after.value.checkpoint);
    _ = try service.workspaceControl(
        a,
        "park-observed-cancellation",
        task,
        id,
        after.value.execution_revision,
        after.value.control_revision,
        .park,
    );
    var observer = try service.workspaceWork(a, task, observer_id);
    defer observer.deinit();
    _ = try service.workspaceStopObserving(a, "stop-after-observed-park", task, .{
        .work = try workspaceRef(a, .work, observer_id),
        .execution_revision = observer.value.execution_revision,
        .control_revision = observer.value.control_revision,
    });
    try observedParkHolds(service, a, task, id);
}

fn observedParkHolds(service: anytype, a: std.mem.Allocator, task: [16]u8, id: [32]u8) !void {
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    try std.testing.expectEqual(.parked, before.value.schedule);
    try std.testing.expect(before.value.cancellation != null);
    try std.testing.expect(!before.value.cancellation_applied);
    for (0..8) |_| _ = try service.pump(a);
    var after = try service.workspaceWork(a, task, id);
    defer after.deinit();
    try std.testing.expectEqual(.parked, after.value.schedule);
    try std.testing.expectEqual(before.value.execution_revision, after.value.execution_revision);
    try std.testing.expectEqualDeep(before.value.checkpoint, after.value.checkpoint);
    try std.testing.expect(!after.value.cancellation_applied);
}

fn incompleteObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    original: contracts.workspace.Observe,
) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try observerRegionSource(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(a, "vanishing-source", task, document, &diagnostic);
    const input = try contracts.encodeOwned(u64, a, 42);
    defer a.free(input);
    const started = try service.workspaceStart(
        a,
        "vanishing-start",
        task,
        program.receipt.workspace.?,
        input,
        .{},
    );
    var initial = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer initial.deinit();
    const checkpoint = try service.namespace.store.object(a, initial.value.checkpoint, null);
    defer a.free(checkpoint);
    var graph = try data.state_image.decodeGraphBorrowed(a, checkpoint, .{});
    defer graph.deinit();
    try std.testing.expectEqual(.yielded, initial.value.outcome_kind);
    try std.testing.expect(graph.state.nodes.len > 1);
    const node = [_]u64{graph.state.nodes.len - 1};
    try std.testing.expect(node[0] < graph.state.nodes.len);
    var selection = original;
    selection.previous = null;
    selection.source.expected = .{
        .work = try workspaceRef(a, .work, initial.value.id),
        .execution_revision = initial.value.execution_revision,
        .control_revision = initial.value.control_revision,
    };
    selection.source.nodes = .{ .selected = .{ .items = &node } };
    selection.policy = .{ .delivery = .lossless, .continuation = .owner_scheduled };
    const observed = try service.workspaceObserve(a, "vanishing-observe", task, selection);
    try observerCompleted(service, a, task, observed.receipt.workspace.?);
    var folded = try service.workspaceWork(a, task, observed.receipt.workspace.?);
    defer folded.deinit();
    try advanceObservedSource(service, a, initial.value, "vanishing-advance");
    var advanced = try service.workspaceWork(a, task, initial.value.id);
    defer advanced.deinit();
    try std.testing.expectEqual(.completed, advanced.value.outcome_kind);
    const released = try service.namespace.store.object(a, advanced.value.checkpoint, null);
    defer a.free(released);
    var after = try data.state_image.decodeGraphBorrowed(a, released, .{});
    defer after.deinit();
    try std.testing.expect(node[0] >= after.state.nodes.len);
    try incompleteObserverRetained(service, a, folded.value, advanced.value);
}

fn observerRegionSource(builder: *source.Builder) !source.Module {
    const number = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const region_id = builder.region();
    const region = try builder.schema(.{ .internal = .{ .region = region_id } });
    const cell = try builder.schema(.{ .internal = .{ .cell = .{
        .element = number,
        .region = region_id,
    } } });
    const entry = try builder.declare(&.{number}, number, &.{}, &.{});
    const inside = try builder.declare(&.{ region, number }, number, &.{}, &.{region_id});
    const allocated = try builder.variable(cell);
    const result = try builder.pure(
        try builder.primitive(number, .cell_get, &.{try builder.reference(allocated)}, 0),
    );
    const yielding = try builder.term(.{ .yield_then = result });
    const created = try builder.pure(try builder.primitive(cell, .cell_new, &.{
        try builder.reference(builder.parameter(inside, 0)),
        try builder.reference(builder.parameter(inside, 1)),
    }, 0));
    try builder.define(inside, try builder.bind(allocated, created, yielding));
    const body = try builder.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ region, number },
        .result = number,
        .effects = &.{},
        .regions = &.{region_id},
    } } });
    try builder.define(entry, try builder.term(.{ .with_region = .{
        .region = region_id,
        .body = try builder.lambda(inside, body),
        .arguments = &.{try builder.reference(builder.parameter(entry, 0))},
    } }));
    return builder.module(entry, unit);
}

fn lateObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    original: contracts.workspace.Observe,
) !void {
    const started = try service.workspaceStart(a, "late-source", task, program, input, .{});
    var initial = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer initial.deinit();
    const reference = try workspaceRef(a, .work, initial.value.id);
    _ = try service.workspacePump(a, "late-source-begin", task, .{ .expected = .{
        .work = reference,
        .execution_revision = initial.value.execution_revision,
        .control_revision = initial.value.control_revision,
    }, .base_quantum = 1 });
    var pending = try service.workspaceWork(a, task, initial.value.id);
    defer pending.deinit();
    try std.testing.expect(pending.value.outer_operation != null);
    var selection = original;
    selection.previous = null;
    selection.source.expected = .{
        .work = reference,
        .execution_revision = pending.value.execution_revision,
        .control_revision = pending.value.control_revision,
    };
    const first = try service.workspaceObserve(a, "late-observer-first", task, selection);
    try observerCompleted(service, a, task, first.receipt.workspace.?);
    try finishLateObserverSource(service, a, pending.value);
    var advanced = try service.workspaceWork(a, task, initial.value.id);
    defer advanced.deinit();
    try std.testing.expect(advanced.value.guest_work > 1);
    selection.source.expected.execution_revision = advanced.value.execution_revision;
    selection.source.expected.control_revision = advanced.value.control_revision;
    selection.previous = try workspaceRef(a, .work, first.receipt.workspace.?);
    const second = try service.workspaceObserve(a, "late-observer-second", task, selection);
    try observerCompleted(service, a, task, second.receipt.workspace.?);
    var folded = try service.workspaceWork(a, task, second.receipt.workspace.?);
    defer folded.deinit();
    const bytes = try service.namespace.store.object(a, folded.value.input, null);
    defer a.free(bytes);
    var decoded = try contracts.decodeOwned(struct {
        selected: struct {
            envelope: native.workspace.ObserverEnvelope,
            cut: kosmos.RuntimeViews.GuestView,
        },
        accumulator: u64,
    }, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(.publication, decoded.value.selected.envelope.granularity);
    try std.testing.expectEqual(
        advanced.value.guest_work,
        decoded.value.selected.envelope.guest_work_delta.?,
    );
}

fn finishLateObserverSource(
    service: anytype,
    a: std.mem.Allocator,
    initial: native.workspace.Work,
) !void {
    for (0..128) |index| {
        var current = try service.workspaceWork(a, initial.task, initial.id);
        defer current.deinit();
        if (current.value.execution_revision != initial.execution_revision) return;
        const operation_id = try std.fmt.allocPrint(a, "late-source-finish-{d}", .{index});
        defer a.free(operation_id);
        _ = try service.workspacePump(a, operation_id, initial.task, .{ .expected = .{
            .work = try workspaceRef(a, .work, initial.id),
            .execution_revision = current.value.execution_revision,
            .control_revision = current.value.control_revision,
        } });
    }
    return error.LateObserverSourceDidNotAdvance;
}

fn executorObserverCancellation(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    expected: contracts.workspace.Expected,
) !void {
    const id = try nativeIdentity(expected.work);
    var observer = try service.workspaceWork(a, task, id);
    defer observer.deinit();
    try std.testing.expectEqual(.completed, observer.value.outcome_kind);
    try std.testing.expectEqual(
        .explicit_only,
        observer.value.observer.?.selection.policy.continuation,
    );
    try std.testing.expect(!observer.value.observer.?.stopped);
    try std.testing.expectEqual(.away, (try service.placementStatus(a, .{ .task = task })).?.phase);
    var source_work = try service.workspaceWork(a, task, observer.value.observer.?.source_work);
    defer source_work.deinit();
    _ = try service.workspaceControl(
        a,
        "claim-local-observer-source",
        task,
        source_work.value.id,
        source_work.value.execution_revision,
        source_work.value.control_revision,
        .park,
    );
    const remote_before = try observerRemoteControlCount(service, task);
    try service.cancelOwned(a, "executor-observer-shutdown", "stop local subscriptions");
    for (0..512) |_| {
        _ = try service.pump(a);
        if (!try service.shutdownIncomplete(a)) break;
    }
    try std.testing.expect(!try service.shutdownIncomplete(a));
    var stopped = try service.workspaceWork(a, task, id);
    defer stopped.deinit();
    try std.testing.expect(stopped.value.observer.?.stopped);
    try std.testing.expectEqualDeep(observer.value.result, stopped.value.result);
    try std.testing.expectEqualDeep(observer.value.checkpoint, stopped.value.checkpoint);
    try std.testing.expectEqual(remote_before, try observerRemoteControlCount(service, task));
}

fn observerRemoteControlCount(service: anytype, task: [16]u8) !i64 {
    var query = try service.namespace.store.database.prepare(
        "SELECT count(*) FROM records WHERE task=? AND kind='placement_control'",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    return query.integer(0);
}

fn incompleteObserverRetained(
    service: anytype,
    a: std.mem.Allocator,
    folded: native.workspace.Work,
    source_work: native.workspace.Work,
) !void {
    for (0..128) |_| {
        var current = try service.workspaceWork(a, folded.task, folded.id);
        defer current.deinit();
        if (current.value.observer.?.incomplete) |incomplete| {
            try std.testing.expectEqual(.invalid_disclosure, incomplete.diagnostic);
            try std.testing.expectEqual(source_work.event_watermark, incomplete.publication);
            try std.testing.expectEqual(source_work.execution_revision, incomplete.revision);
            try std.testing.expectEqual(.completed, current.value.outcome_kind);
            try std.testing.expect(!current.value.observer.?.stopped);
            var expected = folded.observer.?;
            expected.incomplete = incomplete;
            try std.testing.expectEqualDeep(expected, current.value.observer.?);
            try std.testing.expectEqualDeep(folded.checkpoint, current.value.checkpoint);
            try std.testing.expectEqualDeep(folded.result, current.value.result);
            try std.testing.expectEqualDeep(folded.result_value, current.value.result_value);
            try std.testing.expectEqual(
                null,
                try observerSuccessor(service, a, folded.task, folded.id),
            );
            try std.testing.expectError(
                error.ActiveObserverMobilityUnsupported,
                service.placementCompatibility(a, .{
                    .task = folded.task,
                    .work = source_work.id,
                }),
            );
            for (0..8) |_| _ = try service.pump(a);
            var stable = try service.workspaceWork(a, folded.task, folded.id);
            defer stable.deinit();
            try std.testing.expectEqual(
                current.value.event_watermark,
                stable.value.event_watermark,
            );
            var source_after = try service.workspaceWork(a, folded.task, source_work.id);
            defer source_after.deinit();
            try std.testing.expectEqualDeep(source_work, source_after.value);
            try incompleteObserverTamper(service, a, stable.value);
            return;
        }
        _ = try service.pump(a);
    }
    return error.ObserverPreparationDidNotFail;
}

fn rewriteIncompleteObserverPublication(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
    forged: native.workspace.Work,
) !void {
    try service.namespace.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        work.id,
        work.task,
        forged,
    );
    const observation = try service.namespace.store.putObject(
        try contracts.encodeOwned(native.workspace.WorkObservation, a, .{
            .work = forged,
            .occurrence = null,
        }),
    );
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? AND e.seq=?",
        &.{ .{ .blob = &work.task }, .{ .integer = @intCast(work.event_watermark) } },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
    defer event.deinit();
    const publications = try a.dupe(
        native.testing.state.WorkPublication,
        event.value.workspace_publications.items,
    );
    defer a.free(publications);
    event.value.workspace_publications.items = publications;
    for (publications) |*publication| if (std.meta.eql(publication.work, work.id)) {
        publication.observer = forged.observer;
        publication.observation = observation.digest;
    };
    const encoded = try contracts.encodeOwned(native.testing.state.Event, a, event.value);
    defer a.free(encoded);
    const reference = try service.namespace.store.putObject(encoded);
    try service.namespace.store.database.run(
        "UPDATE events SET body=? WHERE task=? AND seq=?",
        &.{
            .{ .blob = &reference.digest },
            .{ .blob = &work.task },
            .{ .integer = @intCast(work.event_watermark) },
        },
    );
}

fn incompleteObserverTamper(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
) !void {
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try service.namespace.store.archiveIndex(a, work.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts);
    for (0..4) |attack| {
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        var forged = work;
        switch (attack) {
            0 => forged.observer.?.incomplete.?.revision += 1,
            1 => forged.observer.?.incomplete.?.runtime_code = work.observer.?.source,
            2 => forged.observer.?.incomplete.?.diagnostic = .outer_cut_unavailable,
            3 => {
                const custody = try native.workspace.custodyId(
                    a,
                    work.task,
                    work.observer.?.source.digest,
                );
                const encoded = (try service.namespace.store.recordBytes(
                    a,
                    "workspace_value",
                    custody,
                    work.task,
                )).?;
                defer a.free(encoded);
                var value = try contracts.decodeOwned(native.workspace.Value, a, encoded);
                defer value.deinit();
                const snapshot = try contracts.encodeOwned(
                    native.workspace.WorkObservation,
                    a,
                    value.value.derivation.inspection.?.observation,
                );
                defer a.free(snapshot);
                forged.observer.?.incomplete.?.source = try service.namespace.store.putObject(
                    snapshot,
                );
            },
            else => unreachable,
        }
        try rewriteIncompleteObserverPublication(service, a, work, forged);
        try std.testing.expectError(
            error.InvalidArchive,
            service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts),
        );
    }
}

fn resumeObservedCancellation(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    id: [32]u8,
) !void {
    try observedParkHolds(service, a, task, id);
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    _ = try service.workspaceControl(
        a,
        "fresh-observed-cancel",
        task,
        id,
        before.value.execution_revision,
        before.value.control_revision,
        .{ .cancel = .{ .bytes = "resume observed cancellation" } },
    );
    var after = try service.workspaceWork(a, task, id);
    defer after.deinit();
    try std.testing.expect(after.value.execution_revision > before.value.execution_revision);
    try std.testing.expect(after.value.cancellation_applied);
}

fn cancelObserverTaskWitness(service: anytype, a: std.mem.Allocator, task: [16]u8) !void {
    _ = try service.requestCancel(a, "cancel-observer-task", task, "end subscriptions");
    var disposed = false;
    for (0..4096) |_| {
        _ = try service.pump(a);
        var current = try service.task(a, task);
        defer current.deinit();
        if (try service.taskCleanupComplete(a, current.value)) {
            disposed = true;
            break;
        }
    }
    try std.testing.expect(disposed);
    var stopped: usize = 0;
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.task=? AND r.kind='workspace_work'",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        var work = try contracts.decodeOwned(native.workspace.Work, a, try query.bytes(0));
        defer work.deinit();
        if (work.value.observer) |observer| {
            if (observer.stopped) stopped += 1;
        }
    }
    try std.testing.expect(stopped >= 3);
    try service.validateWorkspace(a, task);
}

fn observerFoldValue(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
    expected: u64,
) !void {
    const bytes = try service.namespace.store.object(a, work.result.?, null);
    defer a.free(bytes);
    var result = try contracts.decodeOwned(struct { sum: u64, nodes: u64 }, a, bytes);
    defer result.deinit();
    try std.testing.expectEqual(expected, result.value.sum);
    try std.testing.expect(result.value.nodes != 0);
    const input = try service.namespace.store.object(a, work.input, null);
    defer a.free(input);
    var observed = try contracts.decodeOwned(struct {
        selected: struct {
            envelope: native.workspace.ObserverEnvelope,
            cut: kosmos.RuntimeViews.GuestView,
        },
        accumulator: u64,
    }, a, input);
    defer observed.deinit();
    try std.testing.expectEqual(@as(u64, 1), observed.value.selected.envelope.guest_work_delta.?);
    try std.testing.expectEqual(
        work.observer.?.gap_first,
        observed.value.selected.envelope.gap_first,
    );
}

fn retentionObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    original: contracts.workspace.Observe,
) !void {
    var source_work = try service.workspaceWork(
        a,
        task,
        try nativeIdentity(original.source.expected.work),
    );
    defer source_work.deinit();
    var selection = original;
    selection.source.expected.execution_revision = source_work.value.execution_revision;
    selection.source.expected.control_revision = source_work.value.control_revision;
    selection.previous = null;
    selection.policy.delivery = .sampled;
    var disclosed = try retentionObserverView(service, a, task, selection.source);
    defer disclosed.view.deinit();
    const target = try retentionTarget(disclosed.view.value);
    selection.accumulator = try retentionTargetValue(service, a, task, .{
        .program = source_work.value.program,
        .view = disclosed.reference,
        .target = target,
    });
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").retentionObserver(&builder);
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(a, "retention-observer", task, text, &diagnostic);
    selection.program = try workspaceRef(a, .program, program.receipt.workspace.?);
    selection.source.nodes = .{ .selected = .{ .items = &.{} } };
    var partial = try retentionObserverFold(service, a, task, "retention-partial", selection);
    defer partial.deinit();
    try std.testing.expectEqual(.unknown_partial, partial.value.emitted.relation.conclusion);
    try std.testing.expectEqual(null, partial.value.emitted.relation.root);
    try std.testing.expectEqual(@as(usize, 0), partial.value.emitted.relation.path.len);
    try std.testing.expect(partial.value.emitted.request_all_nodes);
    if (partial.value.emitted.request_all_nodes) selection.source.nodes = .{ .all = .{} };
    var complete = try retentionObserverFold(service, a, task, "retention-complete", selection);
    defer complete.deinit();
    try std.testing.expectEqual(target, complete.value.target);
    try std.testing.expectEqual(.reachable, complete.value.emitted.relation.conclusion);
    try std.testing.expect(!complete.value.emitted.request_all_nodes);
    const relation = complete.value.emitted.relation;
    try std.testing.expectEqualDeep(disclosed.view.value.binding, relation.binding);
    const partial_binding = partial.value.emitted.relation.binding;
    try std.testing.expectEqualDeep(partial_binding.checkpoint, relation.binding.checkpoint);
    try std.testing.expect(!std.meta.eql(partial_binding.disclosure, relation.binding.disclosure));
    try std.testing.expectEqual(@as(usize, 1), relation.path.len);
    try std.testing.expectEqual(relation.root.?.node, relation.path[0].from);
    try std.testing.expectEqual(target, relation.path[0].to);
    var unchanged = try service.workspaceWork(a, task, source_work.value.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(source_work.value.checkpoint, unchanged.value.checkpoint);
    try std.testing.expectEqual(
        source_work.value.execution_revision,
        unchanged.value.execution_revision,
    );
}

fn retentionTarget(view: kosmos.RuntimeViews.GuestView) !u64 {
    for (view.roots) |root| for (view.edges) |edge| {
        if (edge.from != root.node) continue;
        const rooted = for (view.roots) |candidate| {
            if (candidate.node == edge.to) break true;
        } else false;
        if (!rooted) return edge.to;
    };
    return error.NoRetainedChild;
}

fn retentionObserverView(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    selection: contracts.workspace.GuestViewSelection,
) !struct {
    reference: contracts.workspace.Ref,
    view: contracts.Decoded(kosmos.RuntimeViews.GuestView),
} {
    const response = try service.workspaceCommand(a, "retention-selected-view", task, .{
        .context = .{ .materialize = .{
            .input = .{ .guest_view = selection },
            .sources = .{ .items = &.{} },
        } },
    });
    try std.testing.expectEqual(.observed, response.disposition);
    const id = try nativeIdentity(response.evidence.?);
    const custody = try native.workspace.custodyId(a, task, id);
    const record = (try service.namespace.store.recordBytes(a, "workspace_value", custody, task)).?;
    defer a.free(record);
    var value = try contracts.decodeOwned(native.workspace.Value, a, record);
    defer value.deinit();
    const bytes = try service.namespace.store.object(a, value.value.description.value, null);
    defer a.free(bytes);
    return .{
        .reference = response.evidence.?,
        .view = try contracts.decodeOwned(kosmos.RuntimeViews.GuestView, a, bytes),
    };
}

fn retentionTargetValue(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    selected: struct { program: [32]u8, view: contracts.workspace.Ref, target: u64 },
) !contracts.workspace.Ref {
    var program = try service.workspaceProgram(a, task, selected.program);
    defer program.deinit();
    const text = try std.fmt.allocPrint(a, "\"{d}\"", .{selected.target});
    defer a.free(text);
    const response = try service.workspaceCommand(a, "retention-selected-target", task, .{
        .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{
                .schema = try workspaceRef(
                    a,
                    .schema,
                    program.value.description.result_schema.digest,
                ),
                .json_text = .{ .bytes = text },
            } } },
            .sources = .{ .items = &.{selected.view} },
        } },
    });
    try std.testing.expectEqual(.observed, response.disposition);
    return response.evidence.?;
}

fn retentionObserverFold(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    operation_id: []const u8,
    selection: contracts.workspace.Observe,
) !contracts.Decoded(@import("workspace_sources.zig").RetentionObservation) {
    const started = try service.workspaceObserve(a, operation_id, task, selection);
    try observerCompleted(service, a, task, started.receipt.workspace.?);
    var work = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer work.deinit();
    const input = try service.namespace.store.object(a, work.value.input, null);
    defer a.free(input);
    var observed = try contracts.decodeOwned(struct {
        selected: struct {
            envelope: native.workspace.ObserverEnvelope,
            cut: kosmos.RuntimeViews.GuestView,
        },
        target: u64,
    }, a, input);
    defer observed.deinit();
    try std.testing.expectEqual(
        selection.source.nodes == .all,
        observed.value.selected.cut.complete_graph,
    );
    const value_id = work.value.result_value.?.digest;
    const custody = try native.workspace.custodyId(a, task, value_id);
    const record = (try service.namespace.store.recordBytes(a, "workspace_value", custody, task)).?;
    defer a.free(record);
    var value = try contracts.decodeOwned(native.workspace.Value, a, record);
    defer value.deinit();
    try std.testing.expectEqualDeep(
        work.value.input_value.?,
        value.value.derivation.sources.items[0],
    );
    try std.testing.expectEqualDeep(
        work.value.observer.?.source,
        value.value.derivation.sources.items[1],
    );
    try std.testing.expectEqualDeep(
        selection.source.nodes,
        observed.value.selected.envelope.selection.nodes,
    );
    const bytes = try service.namespace.store.object(a, work.value.result.?, null);
    defer a.free(bytes);
    var result = try contracts.decodeOwned(
        @import("workspace_sources.zig").RetentionObservation,
        a,
        bytes,
    );
    errdefer result.deinit();
    try std.testing.expectEqual(observed.value.target, result.value.target);
    try std.testing.expectEqualDeep(
        observed.value.selected.cut.binding,
        result.value.emitted.relation.binding,
    );
    return result;
}

fn scheduledObserverProgram(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
) ![32]u8 {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").cutObserver(&builder, false);
    builder.functions.items[@intCast(module.entry)].body = try builder.term(.{
        .yield_then = builder.functions.items[@intCast(module.entry)].body.?,
    });
    const document = try native.source_records.encode(
        a,
        builder.module(module.entry, module.failure),
    );
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const scheduled_program = try service.workspaceBuild(
        a,
        "scheduled-observer-program",
        task,
        document,
        &diagnostic,
    );
    return scheduled_program.receipt.workspace.?;
}

fn sampledObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    original: contracts.workspace.Observe,
) !ScheduledObserverWitness {
    const scheduled_program = try scheduledObserverProgram(service, a, task);
    const started = try service.workspaceStart(a, "sample-source", task, program, input, .{});
    var initial = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer initial.deinit();
    var selection = original;
    selection.program = try workspaceRef(a, .program, scheduled_program);
    selection.source.expected = .{
        .work = try workspaceRef(a, .work, initial.value.id),
        .execution_revision = initial.value.execution_revision,
        .control_revision = initial.value.control_revision,
    };
    selection.policy.delivery = .sampled;
    selection.previous = null;
    const first = try service.workspaceObserve(a, "sample-first", task, selection);
    try observerCompleted(service, a, task, first.receipt.workspace.?);
    for (0..2) |step| {
        var current = try service.workspaceWork(a, task, initial.value.id);
        defer current.deinit();
        const operation_id = try std.fmt.allocPrint(a, "sample-step-{d}", .{step});
        defer a.free(operation_id);
        try advanceObservedSource(service, a, current.value, operation_id);
    }
    var advanced = try service.workspaceWork(a, task, initial.value.id);
    defer advanced.deinit();
    selection.source.expected.execution_revision = advanced.value.execution_revision;
    selection.source.expected.control_revision = advanced.value.control_revision;
    selection.previous = try workspaceRef(a, .work, first.receipt.workspace.?);
    selection.policy.continuation = .owner_scheduled;
    const second = try service.workspaceObserve(a, "sample-second", task, selection);
    try observerCompleted(service, a, task, second.receipt.workspace.?);
    var folded = try service.workspaceWork(a, task, second.receipt.workspace.?);
    defer folded.deinit();
    try std.testing.expectEqual(
        initial.value.execution_revision + 1,
        folded.value.observer.?.gap_first.?,
    );
    try std.testing.expectEqual(
        advanced.value.execution_revision - 1,
        folded.value.observer.?.gap_last.?,
    );
    try observerFoldValue(service, a, folded.value, initial.value.execution_revision +
        advanced.value.execution_revision);
    try failedObserverWitness(service, a, task, selection, advanced.value);
    try advanceObservedSource(service, a, advanced.value, "sample-before-reopen");
    var latest = try service.workspaceWork(a, task, advanced.value.id);
    defer latest.deinit();
    return .{
        .previous = folded.value.id,
        .cursor = latest.value.execution_revision,
        .accumulated = initial.value.execution_revision + advanced.value.execution_revision +
            latest.value.execution_revision,
    };
}

fn traceOuterObserverAdvance(
    service: anytype,
    a: std.mem.Allocator,
    source_work: native.workspace.Work,
) !void {
    {
        var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(
            @as(c_int, 0),
            CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace),
        );
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        try advanceObservedSource(service, a, source_work, "outer-observed-advance");
        try std.testing.expectEqual(@as(usize, 0), trace.scans);
        try std.testing.expectEqual(@as(usize, 0), trace.history_scans);
        std.debug.print("live outer observer: inventory_scans={d} history_scans={d}\n", .{
            trace.scans,
            trace.history_scans,
        });
    }
}

fn awaitUnavailableOuterCut(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    folded: native.workspace.Work,
) !void {
    for (0..128) |_| {
        _ = try service.pump(a);
        var current = try service.workspaceWork(a, task, folded.id);
        defer current.deinit();
        if (current.value.observer.?.incomplete) |incomplete| {
            try std.testing.expectEqual(.outer_cut_unavailable, incomplete.diagnostic);
            try std.testing.expectEqualDeep(folded.checkpoint, current.value.checkpoint);
            _ = try service.workspaceStopObserving(a, "outer-observer-stop", task, .{
                .work = try workspaceRef(a, .work, current.value.id),
                .execution_revision = current.value.execution_revision,
                .control_revision = current.value.control_revision,
            });
            return;
        }
    }
    return error.MissingOuterCutDiagnostic;
}

fn foldOuterObserver(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    source_work: native.workspace.Work,
    initial_selection: contracts.workspace.Observe,
) !void {
    var selection = initial_selection;
    const first = try service.workspaceObserve(a, "outer-observer-first", task, selection);
    try observerCompleted(service, a, task, first.receipt.workspace.?);
    try currentObserverBatchWitness(service, a, task, source_work, false, "outer-consumed");
    try traceOuterObserverAdvance(service, a, source_work);
    var advanced = try service.workspaceWork(a, task, source_work.id);
    defer advanced.deinit();
    try std.testing.expect(advanced.value.runtime_capsule != null);
    try currentObserverBatchWitness(service, a, task, advanced.value, true, "outer-unconsumed");
    selection.source.expected.execution_revision = advanced.value.execution_revision;
    selection.source.expected.control_revision = advanced.value.control_revision;
    selection.previous = try workspaceRef(a, .work, first.receipt.workspace.?);
    const second = try service.workspaceObserve(a, "outer-observer-second", task, selection);
    try observerCompleted(service, a, task, second.receipt.workspace.?);
    var folded = try service.workspaceWork(a, task, second.receipt.workspace.?);
    defer folded.deinit();
    try std.testing.expectEqual(@as(?u64, 1), folded.value.observer.?.consumed_revision);
    const bytes = try service.namespace.store.object(a, folded.value.result.?, null);
    defer a.free(bytes);
    var result = try contracts.decodeOwned(struct { accum: u64, emitted: u64 }, a, bytes);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 1), result.value.accum);
    try std.testing.expectEqual(@as(u64, 1), result.value.emitted);
    _ = try service.workspaceRequestCut(a, "outer-observer-guest-cut", task, .{
        .expected = selection.source.expected,
        .level = .guest_cut,
    });
    try awaitUnavailableOuterCut(service, a, task, folded.value);
}

fn outerObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    program: [32]u8,
    input: []const u8,
    accumulator: contracts.workspace.Ref,
) !void {
    const started = try service.workspaceStart(
        a,
        "outer-observed-source",
        task,
        program,
        input,
        .{},
    );
    var initial = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer initial.deinit();
    _ = try service.workspaceRequestCut(a, "outer-observed-cut", task, .{
        .expected = .{
            .work = try workspaceRef(a, .work, initial.value.id),
            .execution_revision = initial.value.execution_revision,
            .control_revision = initial.value.control_revision,
        },
        .level = .outer_execution,
    });
    var source_work = try service.workspaceWork(a, task, initial.value.id);
    defer source_work.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").outerCutObserver(&builder);
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(a, "outer-observer-program", task, text, &diagnostic);
    const selection: contracts.workspace.Observe = .{
        .program = try workspaceRef(a, .program, built.receipt.workspace.?),
        .source = .{ .expected = .{
            .work = try workspaceRef(a, .work, source_work.value.id),
            .execution_revision = source_work.value.execution_revision,
            .control_revision = source_work.value.control_revision,
        }, .realization_revision = 0, .nodes = .{ .all = .{} }, .level = .outer_execution },
        .accumulator = accumulator,
        .policy = .{
            .delivery = .lossless,
            .granularity = .one_guest_step,
            .continuation = .owner_scheduled,
        },
    };
    try foldOuterObserver(service, a, task, source_work.value, selection);
}

fn failedObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    original: contracts.workspace.Observe,
    source_work: native.workspace.Work,
) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").cutObserver(&builder, true);
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(a, "failed-observer-program", task, text, &diagnostic);
    var selection = original;
    selection.program = try workspaceRef(a, .program, built.receipt.workspace.?);
    selection.previous = null;
    selection.policy.continuation = .explicit_only;
    const started = try service.workspaceObserve(a, "failed-observer", task, selection);
    for (0..64) |index| {
        var current = try service.workspaceWork(a, task, started.receipt.workspace.?);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.failed, current.value.outcome_kind);
            try std.testing.expectEqual(null, current.value.observer.?.consumed_revision);
            var unchanged = try service.workspaceWork(a, task, source_work.id);
            defer unchanged.deinit();
            try std.testing.expectEqualDeep(source_work.checkpoint, unchanged.value.checkpoint);
            return;
        }
        const operation_id = try std.fmt.allocPrint(a, "failed-observer-pump-{d}", .{index});
        defer a.free(operation_id);
        _ = try service.workspacePump(a, operation_id, task, .{ .expected = .{
            .work = try workspaceRef(a, .work, current.value.id),
            .execution_revision = current.value.execution_revision,
            .control_revision = current.value.control_revision,
        } });
    }
    return error.ObserverDidNotFinish;
}

fn scheduledObserverWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    expected: ScheduledObserverWitness,
) !void {
    if (expected.parked_source) |id| try resumeObservedCancellation(service, a, task, id);
    for (0..128) |_| {
        if (try observerSuccessor(service, a, task, expected.previous)) |id| {
            var work = try service.workspaceWork(a, task, id);
            defer work.deinit();
            if (work.value.terminal()) {
                try std.testing.expectEqual(.completed, work.value.outcome_kind);
                try std.testing.expectEqual(
                    expected.cursor,
                    work.value.observer.?.consumed_revision.?,
                );
                try observerFoldValue(service, a, work.value, expected.accumulated);
                for (0..4) |_| _ = try service.pump(a);
                try std.testing.expectEqual(
                    id,
                    (try observerSuccessor(service, a, task, expected.previous)).?,
                );
                try std.testing.expectEqual(null, try observerSuccessor(service, a, task, id));
                var stable = try service.workspaceWork(a, task, id);
                defer stable.deinit();
                try std.testing.expectEqualDeep(work.value.result_value, stable.value.result_value);
                try scheduledObserverContinuation(service, a, stable.value);
                return;
            }
        }
        _ = try service.pump(a);
    }
    return error.ScheduledObserverDidNotComplete;
}

fn scheduledObserverContinuation(
    service: anytype,
    a: std.mem.Allocator,
    previous: native.workspace.Work,
) !void {
    try std.testing.expect(previous.execution_revision > 1);
    var source_work = try service.workspaceWork(a, previous.task, previous.observer.?.source_work);
    defer source_work.deinit();
    try advanceObservedSource(service, a, source_work.value, "scheduled-observer-next-cut");
    for (0..128) |_| {
        if (try observerSuccessor(service, a, previous.task, previous.id)) |id| {
            var successor = try service.workspaceWork(a, previous.task, id);
            defer successor.deinit();
            if (successor.value.terminal()) {
                try std.testing.expectEqual(.completed, successor.value.outcome_kind);
                try std.testing.expect(successor.value.execution_revision > 1);
                try std.testing.expectEqual(
                    source_work.value.execution_revision + 1,
                    successor.value.observer.?.consumed_revision.?,
                );
                try stopDiscoveredObserver(service, a, successor.value);
                return;
            }
        }
        _ = try service.pump(a);
    }
    return error.ScheduledObserverDidNotContinue;
}

fn rejectMissingObserverCapsule(
    a: std.mem.Allocator,
    namespace: *native.Namespace,
    task: [16]u8,
    handlers: native.Registry,
    application: *const native.discovery.Application,
) !void {
    {
        _ = try namespace.store.auditRetention(handlers, application.image_identity);
        var rows = try namespace.store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                "WHERE e.task=? ORDER BY e.seq",
            &.{.{ .blob = &task }},
        );
        defer rows.deinit();
        var source_capsule: ?native.testing.state.Reference = null;
        while (try rows.step() == .row) {
            var event = try contracts.decodeOwned(native.testing.state.Event, a, try rows.bytes(0));
            defer event.deinit();
            const command_ref = event.value.workspace_command orelse continue;
            var command = try contracts.decodeOwned(
                native.workspace.PublicationCommand,
                a,
                try namespace.store.object(a, command_ref, null),
            );
            defer command.deinit();
            if (command.value == .realize) {
                source_capsule = command.value.realize.source;
                break;
            }
        }
        const removed = source_capsule orelse return error.TestUnexpectedResult;
        try namespace.store.database.run(
            "DELETE FROM dependencies WHERE child=? OR parent=?",
            &.{ .{ .blob = &removed.digest }, .{ .blob = &removed.digest } },
        );
        try namespace.store.database.run("DELETE FROM objects WHERE digest=?", &.{.{
            .blob = &removed.digest,
        }});
        namespace.store.invalidateIntegrity();
        try std.testing.expectError(
            error.CorruptState,
            namespace.store.auditRetention(handlers, application.image_identity),
        );
    }
}

fn inspectObserverCopy(
    a: std.mem.Allocator,
    copied: anytype,
    namespace: *native.Namespace,
    expected: native.workspace.Work,
    previous: [32]u8,
    suspended: native.workspace.Work,
    copied_open: *bool,
) !void {
    const handlers = copied.handlers;
    const application = copied.application;
    const task = expected.task;
    const successor = expected.id;
    try std.testing.expectEqual(successor, (try observerSuccessor(copied, a, task, previous)).?);
    var actual = try copied.workspaceWork(a, task, successor);
    defer actual.deinit();
    try std.testing.expectEqualDeep(expected, actual.value);
    var restored_trace = try copied.workspaceWork(a, task, suspended.id);
    defer restored_trace.deinit();
    try std.testing.expect(restored_trace.value.runtime_trace != null);
    try std.testing.expect(restored_trace.value.outer_operation != null);
    try std.testing.expectEqualDeep(
        suspended.outer_operation.?.capsule,
        restored_trace.value.outer_operation.?.capsule,
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        copied.workspacePump(a, "copy-cannot-pump", task, .{
            .expected = .{
                .work = try workspaceRef(a, .work, suspended.id),
                .execution_revision = restored_trace.value.execution_revision,
                .control_revision = restored_trace.value.control_revision,
            },
            .base_quantum = 1,
        }),
    );
    try copied.close(copied.allocator);
    copied_open.* = false;
    try rejectMissingObserverCapsule(a, namespace, task, handlers, application);
}

fn observerArchiveRoundTrip(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    previous: [32]u8,
    suspended: native.workspace.Work,
    archive_path: []const u8,
    source_path: []const u8,
    copy_path: []const u8,
) !void {
    const successor = (try observerSuccessor(service, a, task, previous)).?;
    var expected = try service.workspaceWork(a, task, successor);
    defer expected.deinit();
    const allocator = service.allocator;
    const io = service.io;
    const source_namespace = service.namespace;
    const assets = service.assets;
    const application = service.application;
    const handlers = service.handlers;
    const profile = service.profile;
    try service.close(allocator);
    try source_namespace.close();
    defer {
        source_namespace.* = support.expectCleanupValue(
            native.Namespace.open(allocator, io, source_path),
        );
        service.* = support.expectCleanupValue(native.tasks.Service(OwnerTypes).init(
            allocator,
            io,
            source_namespace,
            assets,
            application,
            handlers,
            profile,
        ));
    }
    var namespace = try native.Namespace.open(allocator, io, copy_path);
    defer support.expectCleanup(namespace.close());
    var copied = try native.tasks.Service(OwnerTypes).init(
        allocator,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    var copied_open = true;
    defer if (copied_open) support.expectCleanup(copied.close(allocator));
    _ = copied.importCheckpoint(a, "completed-observer-import", archive_path) catch |err| {
        std.debug.print("observer archive import: {s}\n", .{@errorName(err)});
        return err;
    };
    try inspectObserverCopy(
        a,
        &copied,
        &namespace,
        expected.value,
        previous,
        suspended,
        &copied_open,
    );
}

fn observerArchiveWitness(
    service: anytype,
    a: std.mem.Allocator,
    document: []const u8,
    input: []const u8,
) !void {
    const parent = try service.submit(a, "observer-audit-parent", .{ 25, 5 });
    const task = parent.receipt.task;
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(
        a,
        "observer-audit-source",
        task,
        document,
        &diagnostic,
    );
    const started = try service.workspaceStart(
        a,
        "observer-audit-start",
        task,
        built.receipt.workspace.?,
        input,
        .{},
    );
    const observed = try placementObserver(
        service,
        a,
        task,
        built.receipt.workspace.?,
        started.receipt.workspace.?,
        false,
    );
    var source_work = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer source_work.deinit();
    try advanceObservedSource(service, a, source_work.value, "observer-audit-consumed");
    var advanced = try service.workspaceWork(a, task, source_work.value.id);
    defer advanced.deinit();
    var observer = try service.workspaceWork(a, task, try nativeIdentity(observed.work));
    defer observer.deinit();
    try observerArchiveTamper(service, a, observer.value);
    var forged = observer.value;
    forged.observer.?.selection.policy.delivery = .sampled;
    try replaceObserverRecord(service, task, forged);
    try advanceObservedSource(service, a, advanced.value, "observer-audit-forged");
    try replaceObserverRecord(service, task, observer.value);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspace(a, task));
}

fn observerArchiveTamper(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &digest, .{});
    const index = try service.namespace.store.archiveIndex(a, work.task, .{
        .digest = digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(
        service.allocator,
        work.task,
        index.records.items,
        &facts,
    );
    const successor = work.observer.?.previous != null;
    for (0..@as(usize, if (successor) 3 else 5)) |attack| {
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        var forged = work;
        const observer = &forged.observer.?;
        if (successor) {
            const bytes = try service.namespace.store.object(a, observer.previous.?, null);
            defer a.free(bytes);
            var predecessor = try contracts.decodeOwned(native.workspace.Work, a, bytes);
            defer predecessor.deinit();
            switch (attack) {
                0 => predecessor.value.control_revision += 1,
                1 => predecessor.value.outer_cursor.revision += 1,
                2 => predecessor.value.outer_cursor.last = work.input.digest,
                else => unreachable,
            }
            const changed = try contracts.encodeOwned(native.workspace.Work, a, predecessor.value);
            defer a.free(changed);
            observer.previous = try service.namespace.store.putObject(changed);
        } else switch (attack) {
            0 => observer.selection.accumulator = try workspaceRef(
                a,
                .value,
                observer.source.digest,
            ),
            1 => observer.selection.policy.cadence = 0,
            2 => observer.selection.policy.cadence = 2,
            3 => forged.outer_cursor.revision += 1,
            4 => forged.outer_cursor.last = work.input.digest,
            else => unreachable,
        }
        try rewriteObserverArchive(service, a, forged);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(
            service.allocator,
            work.task,
            index.records.items,
            &facts,
        ));
    }
}

fn observerArchiveFields(
    original: native.workspace.Observer,
    forged: native.workspace.Observer,
) native.workspace.Observer {
    var value = original;
    value.selection = forged.selection;
    value.previous = forged.previous;
    return value;
}

fn rewriteObserverPublication(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
    publication: *native.testing.state.WorkPublication,
) !bool {
    if (!std.meta.eql(publication.work, work.id)) return false;
    var bytes = try service.namespace.store.database.prepare(
        "SELECT body FROM objects WHERE digest=?",
        &.{.{ .blob = &publication.observation }},
    );
    defer bytes.deinit();
    try std.testing.expect(try bytes.step() == .row);
    var snapshot = try contracts.decodeOwned(
        native.workspace.WorkObservation,
        a,
        try bytes.bytes(0),
    );
    defer snapshot.deinit();
    snapshot.value.work.observer = observerArchiveFields(
        snapshot.value.work.observer.?,
        work.observer.?,
    );
    publication.observer = observerArchiveFields(publication.observer.?, work.observer.?);
    const encoded = try contracts.encodeOwned(
        native.workspace.WorkObservation,
        a,
        snapshot.value,
    );
    defer a.free(encoded);
    publication.observation = (try service.namespace.store.putObject(encoded)).digest;
    return true;
}

fn rewriteObserverArchive(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
) !void {
    try service.namespace.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        work.id,
        work.task,
        work,
    );
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? ORDER BY e.seq",
        &.{.{ .blob = &work.task }},
    );
    defer query.deinit();
    var start_revision: ?u64 = null;
    while (try query.step() == .row) {
        var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
        defer event.deinit();
        var found = false;
        for (@constCast(event.value.workspace_publications.items)) |*publication| {
            if (try rewriteObserverPublication(service, a, work, publication)) found = true;
        }
        if (!found) continue;
        if (event.value.workspace_command) |ref| {
            const bytes = try service.namespace.store.object(a, ref, null);
            defer a.free(bytes);
            var command = try contracts.decodeOwned(native.workspace.PublicationCommand, a, bytes);
            defer command.deinit();
            if (command.value == .start) {
                command.value.start.observer = observerArchiveFields(
                    command.value.start.observer.?,
                    work.observer.?,
                );
                const encoded = try contracts.encodeOwned(
                    native.workspace.PublicationCommand,
                    a,
                    command.value,
                );
                defer a.free(encoded);
                event.value.workspace_command = try service.namespace.store.putObject(encoded);
                try std.testing.expectEqual(null, start_revision);
                start_revision = event.value.revision;
            }
        }
        const encoded = try contracts.encodeOwned(native.testing.state.Event, a, event.value);
        defer a.free(encoded);
        const ref = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run(
            "UPDATE events SET body=? WHERE task=? AND seq=?",
            &.{
                .{ .blob = &ref.digest },
                .{ .blob = &work.task },
                .{ .integer = @intCast(event.value.seq) },
            },
        );
    }
    try rewriteObserverReceipts(
        service,
        a,
        work,
        start_revision orelse return error.MissingObserverStart,
    );
}

fn rewriteObserverReceipts(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
    start_revision: u64,
) !void {
    const request = try contracts.encodeOwned(native.workspace.ObserveRequest, a, .{
        .task = work.task,
        .selection = work.observer.?.selection,
    });
    defer a.free(request);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(request);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var query = try service.namespace.store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON " ++
            "o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &work.task }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        var receipt = try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try query.bytes(1),
        );
        defer receipt.deinit();
        if (receipt.value.workspace_kind != .work or !std.meta.eql(
            receipt.value.workspace,
            @as(?[32]u8, work.id),
        )) continue;
        const bytes = try service.namespace.store.object(
            a,
            receipt.value.workspace_observation.?,
            null,
        );
        defer a.free(bytes);
        var observed = try contracts.decodeOwned(native.workspace.WorkObservation, a, bytes);
        defer observed.deinit();
        observed.value.work.observer = observerArchiveFields(
            observed.value.work.observer.?,
            work.observer.?,
        );
        const snapshot = try contracts.encodeOwned(
            native.workspace.WorkObservation,
            a,
            observed.value,
        );
        defer a.free(snapshot);
        receipt.value.workspace_observation = try service.namespace.store.putObject(snapshot);
        if (receipt.value.revision == start_revision) receipt.value.request_digest = digest;
        const encoded = try contracts.encodeOwned(native.testing.state.Receipt, a, receipt.value);
        defer a.free(encoded);
        const reference = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run(
            "UPDATE operations SET receipt=?,request=? WHERE id=?",
            &.{
                .{ .blob = &reference.digest },
                .{ .blob = &receipt.value.request_digest },
                .{ .text = try query.bytes(0) },
            },
        );
    }
}

fn replaceObserverRecord(service: anytype, task: [16]u8, work: native.workspace.Work) !void {
    try service.namespace.store.begin();
    defer service.namespace.store.rollback();
    try service.namespace.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        work.id,
        task,
        work,
    );
    try service.namespace.commit("observer-archive-fixture");
}

fn observerSuccessor(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    previous: [32]u8,
) !?[32]u8 {
    var query = try service.namespace.store.database.prepare(
        "SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    var found: ?[32]u8 = null;
    while (try query.step() == .row) {
        const id = (try query.bytes(0))[0..32].*;
        var work = try service.workspaceWork(a, task, id);
        defer work.deinit();
        const observer = work.value.observer orelse continue;
        const predecessor = observer.selection.previous orelse continue;
        if (!std.meta.eql(try nativeIdentity(predecessor), previous)) continue;
        try std.testing.expectEqual(null, found);
        found = id;
    }
    const reply = try service.workspaceCommand(a, "observer-lineage-inspect", task, .{
        .work = .{ .inspect = .{ .work = try workspaceRef(a, .work, previous) } },
    });
    var observed = try native.json.parse(a, reply.observation_json.bytes, .{});
    defer observed.deinit();
    const observer = observed.value.object.get("observer").?;
    const successor = try native.values.fromJson(
        ?contracts.workspace.Ref,
        a,
        observer.object.get("successor") orelse return error.MissingObserverSuccessor,
    );
    const projected = if (successor) |ref| try nativeIdentity(ref) else null;
    try std.testing.expectEqual(found, projected);
    return projected;
}

fn stopDiscoveredObserver(
    service: anytype,
    a: std.mem.Allocator,
    work: native.workspace.Work,
) !void {
    var before = try service.workspaceWork(a, work.task, work.observer.?.source_work);
    defer before.deinit();
    var owner_before = try service.task(a, work.task);
    defer owner_before.deinit();
    const reply = try service.workspaceCommand(a, "observer-head-inspect", work.task, .{
        .work = .{ .inspect = .{ .work = try workspaceRef(a, .work, work.id) } },
    });
    var observed = try native.json.parse(a, reply.observation_json.bytes, .{});
    defer observed.deinit();
    const observer = observed.value.object.get("observer").?;
    const previous = try native.values.fromJson(
        ?contracts.workspace.Ref,
        a,
        observer.object.get("previous") orelse return error.MissingObserverPredecessor,
    );
    try std.testing.expectEqualDeep(work.observer.?.selection.previous, previous);
    try std.testing.expect(!observer.object.get("stopped").?.bool);
    const operation_id = try std.fmt.allocPrint(a, "stop-discovered-observer-{s}", .{
        std.fmt.bytesToHex(work.id, .lower),
    });
    defer a.free(operation_id);
    const stopped_reply = try service.workspaceCommand(a, operation_id, work.task, .{
        .work = .{ .stop_observing = .{
            .work = try native.values.fromJson(
                contracts.workspace.Ref,
                a,
                observed.value.object.get("work").?,
            ),
            .execution_revision = try native.json.numberInteger(
                u64,
                observed.value.object.get("execution_revision").?.number_string,
            ),
            .control_revision = try native.json.numberInteger(
                u64,
                observed.value.object.get("control_revision").?.number_string,
            ),
        } },
    });
    try std.testing.expectEqual(.observed, stopped_reply.disposition);
    var stopped = try service.workspaceWork(a, work.task, work.id);
    defer stopped.deinit();
    try std.testing.expect(stopped.value.observer.?.stopped);
    var after = try service.workspaceWork(a, work.task, work.observer.?.source_work);
    defer after.deinit();
    try std.testing.expectEqualDeep(before.value, after.value);
    var owner_after = try service.task(a, work.task);
    defer owner_after.deinit();
    try std.testing.expectEqual(
        owner_before.value.observer_heads.items.len - 1,
        owner_after.value.observer_heads.items.len,
    );
    for (owner_after.value.observer_heads.items) |head| {
        try std.testing.expect(!std.meta.eql(head, work.id));
        const retained = for (owner_before.value.observer_heads.items) |prior| {
            if (std.meta.eql(prior, head)) break true;
        } else false;
        try std.testing.expect(retained);
    }
}

fn observerCompleted(service: anytype, a: std.mem.Allocator, task: [16]u8, id: [32]u8) !void {
    for (0..64) |index| {
        var work = try service.workspaceWork(a, task, id);
        defer work.deinit();
        if (work.value.terminal()) {
            try std.testing.expectEqual(.completed, work.value.outcome_kind);
            return;
        }
        const operation_id = try std.fmt.allocPrint(a, "observer-pump-{s}-{d}", .{
            std.fmt.bytesToHex(id, .lower), index,
        });
        defer a.free(operation_id);
        _ = try service.workspacePump(a, operation_id, task, .{ .expected = .{
            .work = try workspaceRef(a, .work, id),
            .execution_revision = work.value.execution_revision,
            .control_revision = work.value.control_revision,
        } });
    }
    return error.ObserverDidNotComplete;
}

fn scannedOuterCursor(
    publications: []const native.testing.state.WorkPublication,
    id: [32]u8,
    watermark: u64,
    current: ?native.testing.state.Reference,
    visits: *usize,
) !native.workspace.OuterCursor {
    var previous: ?native.testing.state.Reference = null;
    var revision: u64 = 0;
    for (publications, 1..) |item, seq| {
        if (seq > watermark) break;
        visits.* += 1;
        if (!std.meta.eql(item.work, id)) continue;
        const capsule = item.outer_operation orelse item.runtime_capsule orelse continue;
        if (previous != null and !std.meta.eql(previous.?, capsule)) revision += 1;
        previous = capsule;
    }
    if (current != null and previous != null and !std.meta.eql(
        current.?,
        previous.?,
    )) revision += 1;
    return .{
        .revision = revision,
        .last = if (current orelse previous) |capsule| capsule.digest else null,
    };
}

fn scannedOuterRevision(
    publications: []const native.testing.state.WorkPublication,
    id: [32]u8,
    watermark: u64,
    current: ?native.testing.state.Reference,
    visits: *usize,
) !u64 {
    return (try scannedOuterCursor(publications, id, watermark, current, visits)).revision;
}

test "runtime selection outer publication cursors fold exact historical capsule transitions" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    for ([_]usize{ 10, 100, 1000 }) |count| {
        const items = try scratch.alloc(native.testing.state.WorkPublication, count);
        for (items, 0..) |*item, i| {
            item.* = try prefixPublication(scratch, i);
            item.work = prefixIdentity(10000 + i % 3);
            item.observer = null;
            const capsule: native.testing.state.Reference = .{
                .digest = prefixIdentity((i / 3) % 5),
                .bytes = 8,
            };
            if (i % 7 != 0) {
                if (i % 2 == 0) item.outer_operation = capsule else item.runtime_capsule = capsule;
            }
        }
        var prefix: native.testing.workspace_observers.PublicationPrefix = .init(a);
        defer prefix.deinit();
        var visits: usize = 0;
        for (items, 0..) |item, i| {
            const current = item.outer_operation orelse item.runtime_capsule;
            const before = try scannedOuterCursor(items, item.work, i, current, &visits);
            try std.testing.expectEqualDeep(before, try prefix.outerCursor(item.work, i, current));
            var published = item;
            published.outer_cursor = before;
            try prefix.validateOuterCursor(published);
            var forged = published;
            forged.outer_cursor.revision += 1;
            try std.testing.expectError(error.InvalidArchive, prefix.validateOuterCursor(forged));
            forged = published;
            forged.outer_cursor.last = prefixIdentity(999999);
            try std.testing.expectError(error.InvalidArchive, prefix.validateOuterCursor(forged));
            try prefix.put(published, i + 1);
            const after = try scannedOuterRevision(items, item.work, i + 1, current, &visits);
            try std.testing.expectEqual(after, try prefix.outerRevision(item.work, i + 1, current));
        }
        try std.testing.expectEqual(count * count, visits);
        for ([_]usize{ 0, count / 2, count }) |watermark| {
            for (items[count - 3 ..]) |item| {
                const current = item.outer_operation orelse item.runtime_capsule;
                try std.testing.expectEqualDeep(
                    try scannedOuterCursor(items, item.work, watermark, current, &visits),
                    try prefix.outerCursor(item.work, watermark, current),
                );
                try std.testing.expectEqualDeep(
                    try scannedOuterCursor(items, item.work, watermark, null, &visits),
                    prefix.outerCursorAt(item.work, watermark),
                );
            }
        }
        std.debug.print(
            "outer cursors: publications={d} ordered_reference_visits={d} " ++
                "indexed_folds={d}\n",
            .{ count, count * count, count },
        );
        if (count == 10) try std.testing.checkAllAllocationFailures(a, allocatePublicationPrefix, .{
            items,
        });
    }
}

const HistoricalObserverTrace = struct {
    scans: usize = 0,
    rows: usize = 0,
    extern "c" fn sqlite3_sql(?*anyopaque) ?[*:0]const u8;

    fn observe(
        kind: c_uint,
        context: ?*anyopaque,
        statement: ?*anyopaque,
        sql: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const text = if (kind == 1)
            std.mem.span(@as([*:0]const u8, @ptrCast(sql.?)))
        else
            std.mem.span(sqlite3_sql(statement) orelse return 0);
        if (std.mem.eql(
            u8,
            text,
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                "WHERE e.task=? AND e.seq<=? ORDER BY e.seq",
        )) {
            if (kind == 1) self.scans += 1 else if (kind == 4) self.rows += 1;
        }
        return 0;
    }
};

fn currentObserverBatchWitness(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work: native.workspace.Work,
    blocked: bool,
    label: []const u8,
) !void {
    var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
    const database = CleanupTrace.sqlite3_db_handle(statement.handle);
    statement.deinit();
    const ref = try workspaceRef(a, .work, work.id);
    const refs: [4]contracts.workspace.Ref = @splat(ref);
    var parent = try service.task(a, task);
    defer parent.deinit();
    for (0..3) |kind| {
        var trace: HistoricalObserverTrace = .{};
        try std.testing.expectEqual(
            @as(c_int, 0),
            CleanupTrace.sqlite3_trace_v2(database, 1 | 4, HistoricalObserverTrace.observe, &trace),
        );
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        const command: contracts.workspace.Command = .{ .work = switch (kind) {
            0 => .{ .inspect = .{ .work = ref } },
            1 => .{ .collect = .{ .works = .{ .items = &refs } } },
            2 => .{ .wait = .{ .works = .{ .items = &refs }, .after = 0 } },
            else => unreachable,
        } };
        const reply = try service.workspaceCommand(
            a,
            try std.fmt.allocPrint(a, "observer-current-{s}-{d}", .{ label, kind }),
            task,
            command,
        );
        try std.testing.expectEqual(.observed, reply.disposition);
        try std.testing.expectEqual(@as(usize, 0), trace.scans);
        try std.testing.expectEqual(@as(usize, 0), trace.rows);
        var observation = try native.json.parseAsset(
            a,
            reply.observation_json.bytes,
            reply.observation_json.bytes.len,
        );
        defer observation.deinit();
        const items: []const native.json.Value = switch (kind) {
            0 => &.{observation.value},
            1 => observation.value.array.items,
            2 => observation.value.object.get("works").?.array.items,
            else => unreachable,
        };
        try std.testing.expectEqual(if (kind == 0) @as(usize, 1) else refs.len, items.len);
        for (items) |item| try std.testing.expectEqual(
            blocked,
            item.object.get("observation_blocked").?.bool,
        );
        std.debug.print(
            "current observer projection: case={s} kind={d} works={d} " ++
                "events={d} scans={d} decoded_event_rows={d}\n",
            .{ label, kind, items.len, parent.value.event_high, trace.scans, trace.rows },
        );
    }
}

const LogicalFrame = struct { domain: u64, key: u64, metadata: u64 };
const LogicalObservation = struct {
    frames: []const LogicalFrame,
    emitted: union(enum) {
        omitted: void,
        answer: union(enum) { absent: void, present: u64 },
    },
};

fn logicalObserverSource(b: *source.Builder, fails: bool) !source.Module {
    const query = try source.examples.logicalQuery(b);
    const function = b.functions.items[@intCast(query.entry)];
    const frames = b.variables.items[@intCast(function.parameters[0])];
    const view = try contracts.schema(kosmos.RuntimeViews.GuestView, b);
    const envelope = try contracts.schema(native.workspace.ObserverEnvelope, b);
    const selected_schema = try b.schema(.{ .product = &.{ envelope, view } });
    const input = try b.schema(.{ .product = &.{ selected_schema, frames } });
    const output = try contracts.schema(LogicalObservation, b);
    const emitted = b.schemas.items[@intCast(output)].product[1];
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    const selected = try b.primitive(selected_schema, .field, &.{argument}, 0);
    const cut = try b.primitive(view, .field, &.{selected}, 1);
    const complete = try b.primitive(try b.scalar(bool), .field, &.{cut}, 1);
    const snapshot = try b.primitive(frames, .field, &.{argument}, 1);
    const result = try b.variable(function.result);
    const found = try b.primitive(emitted, .variant, &.{try b.reference(result)}, 1);
    const observed = try b.primitive(output, .product, &.{ snapshot, found }, 0);
    const checked = try b.bind(result, try b.term(.{ .call = .{
        .function = query.entry,
        .arguments = &.{ snapshot, try b.constant(u64, 1), try b.constant(u64, 7) },
    } }), try b.pure(observed));
    const omitted = try b.primitive(emitted, .variant, &.{try b.constant(void, {})}, 0);
    const partial = try b.pure(try b.primitive(output, .product, &.{ snapshot, omitted }, 0));
    const body = if (fails)
        try b.term(.{ .fail = try b.constant(void, {}) })
    else
        try b.term(.{ .conditional = .{
            .condition = complete,
            .when_true = checked,
            .when_false = partial,
        } });
    try b.define(entry, try b.term(.{ .yield_then = body }));
    return b.module(entry, query.failure);
}

fn logicalObserverWitness(service: anytype, a: std.mem.Allocator, task: [16]u8) !void {
    const id = try logicalContextWork(service, a, task);
    var source_work = try service.workspaceWork(a, task, id);
    defer source_work.deinit();
    try std.testing.expect(source_work.value.current_port != null);
    const bytes = try service.namespace.store.object(a, source_work.value.current_port.?, null);
    defer a.free(bytes);
    var port = try contracts.decodeOwned(native.workspace.Port, a, bytes);
    defer port.deinit();
    var selection: contracts.workspace.Observe = .{
        .program = try workspaceRef(
            a,
            .program,
            try logicalObserverProgram(service, a, task, false),
        ),
        .source = .{
            .expected = .{
                .work = try workspaceRef(a, .work, id),
                .execution_revision = source_work.value.execution_revision,
                .control_revision = source_work.value.control_revision,
            },
            .realization_revision = source_work.value.realization_revision,
            .nodes = .{ .all = .{} },
        },
        .accumulator = undefined,
        .policy = .{ .delivery = .sampled, .continuation = .owner_scheduled },
    };
    selection.accumulator = try logicalSnapshotValue(
        service,
        a,
        task,
        selection.source,
        port.value,
    );
    const occurrence = (try service.namespace.store.recordBytes(
        a,
        "occurrence",
        source_work.value.current_occurrence.?,
        task,
    )).?;
    defer a.free(occurrence);
    selection.source.nodes = .{ .selected = .{ .items = &.{} } };
    try logicalObserverFold(service, a, task, "logical-partial", selection, false);
    selection.source.nodes = .{ .all = .{} };
    try logicalObserverFold(service, a, task, "logical-complete", selection, true);
    try logicalObserverPark(service, a, task, selection, source_work.value, occurrence);
    selection.program = try workspaceRef(
        a,
        .program,
        try logicalObserverProgram(service, a, task, true),
    );
    const failed = try service.workspaceObserve(a, "logical-failed", task, selection);
    try logicalObserverFailure(service, a, task, failed.receipt.workspace.?);
    try logicalSourceUnchanged(service, a, source_work.value, occurrence);
    try logicalObserverStop(service, a, task, failed.receipt.workspace.?, "logical-failed-stop");
    _ = try service.workspaceInteract(a, "logical-cleanup-answer", task, .{
        .expected = selection.source.expected,
        .port = try workspaceRef(a, .port, port.value.id),
        .generation = port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{
            .schema = try workspaceRef(a, .schema, port.value.interface.argument.digest),
            .json_text = .{ .bytes = "{}" },
        } } },
    });
}

fn logicalContextWork(service: anytype, a: std.mem.Allocator, task: [16]u8) ![32]u8 {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try source.examples.logicalContext(&builder);
    const cleanup: Id = for (builder.effects.items, 0..) |*effect, index| {
        if (!std.mem.eql(u8, effect.identity, "logical-context/cleanup")) continue;
        effect.external = false;
        break @intCast(index);
    } else return error.MissingLogicalCleanup;
    const document = try native.source_records.encode(
        a,
        builder.module(module.entry, module.failure),
    );
    defer a.free(document);
    const built = try service.workspaceCommand(a, "logical-context-build", task, .{
        .program = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = document } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{.{ .effect = cleanup, .class = .input }} },
        } },
    });
    try std.testing.expectEqual(.observed, built.disposition);
    const input = try contracts.encodeOwned(u64, a, 37);
    defer a.free(input);
    const started = try service.workspaceStart(
        a,
        "logical-context-start",
        task,
        try nativeIdentity(built.program.?),
        input,
        .{},
    );
    const id = started.receipt.workspace.?;
    for (0..32) |index| {
        var current = try service.workspaceWork(a, task, id);
        defer current.deinit();
        if (current.value.current_port != null) return id;
        const operation = try std.fmt.allocPrint(a, "logical-context-advance-{d}", .{index});
        defer a.free(operation);
        try advanceObservedSource(service, a, current.value, operation);
    }
    return error.MissingLogicalContextPort;
}

fn logicalSnapshotValue(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    selection: contracts.workspace.GuestViewSelection,
    port: native.workspace.Port,
) !contracts.workspace.Ref {
    const disclosed = try service.workspaceCommand(a, "logical-context-view", task, .{
        .context = .{ .materialize = .{
            .input = .{ .guest_view = selection },
            .sources = .{ .items = &.{} },
        } },
    });
    try std.testing.expectEqual(.observed, disclosed.disposition);
    const expanded = try service.workspaceCommand(a, "logical-context-payload", task, .{
        .context = .{ .expand = .{
            .reference = try workspaceRef(a, .port, port.id),
            .page = .{},
        } },
    });
    var projection = try native.json.parse(a, expanded.observation_json.bytes, .{});
    defer projection.deinit();
    try std.testing.expect(projection.value.object.get("complete").?.bool);
    const payload = try service.namespace.store.object(a, port.payload, null);
    defer a.free(payload);
    var frames = try contracts.decodeOwned([]const LogicalFrame, a, payload);
    defer frames.deinit();
    try std.testing.expectEqual(@as(usize, 2), frames.value.len);
    try std.testing.expectEqual(@as(u64, 37), frames.value[0].metadata);
    try std.testing.expectEqual(@as(u64, 20), frames.value[1].metadata);
    const retained = try service.workspaceCommand(a, "logical-context-snapshot", task, .{
        .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{
                .schema = try workspaceRef(a, .schema, port.interface.payload.digest),
                .json_text = .{ .bytes = projection.value.object.get("text").?.string },
            } } },
            .sources = .{ .items = &.{disclosed.evidence.?} },
        } },
    });
    try std.testing.expectEqual(.observed, retained.disposition);
    return retained.evidence.?;
}

fn logicalObserverProgram(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    fails: bool,
) ![32]u8 {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(
        a,
        try logicalObserverSource(&builder, fails),
    );
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(
        a,
        if (fails) "logical-observer-failing-program" else "logical-observer-program",
        task,
        document,
        &diagnostic,
    );
    return built.receipt.workspace.?;
}

fn logicalObserverFold(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    operation: []const u8,
    selection: contracts.workspace.Observe,
    complete: bool,
) !void {
    const started = try service.workspaceObserve(a, operation, task, selection);
    const id = started.receipt.workspace.?;
    try observerCompleted(service, a, task, id);
    var work = try service.workspaceWork(a, task, id);
    defer work.deinit();
    const bytes = try service.namespace.store.object(a, work.value.result.?, null);
    defer a.free(bytes);
    var result = try contracts.decodeOwned(LogicalObservation, a, bytes);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.frames.len);
    if (complete) {
        try std.testing.expect(result.value.emitted == .answer);
        try std.testing.expect(result.value.emitted.answer == .present);
        try std.testing.expectEqual(@as(u64, 20), result.value.emitted.answer.present);
    } else try std.testing.expect(result.value.emitted == .omitted);
    const stop = try std.fmt.allocPrint(a, "{s}-stop", .{operation});
    defer a.free(stop);
    try logicalObserverStop(service, a, task, id, stop);
}

fn logicalObserverPark(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    selection: contracts.workspace.Observe,
    source_work: native.workspace.Work,
    occurrence: []const u8,
) !void {
    const started = try service.workspaceObserve(a, "logical-observer-park", task, selection);
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(a, task, id);
    defer before.deinit();
    _ = try service.workspaceControl(
        a,
        "logical-observer-park-control",
        task,
        id,
        before.value.execution_revision,
        before.value.control_revision,
        .park,
    );
    for (0..4) |_| _ = try service.pump(a);
    var parked = try service.workspaceWork(a, task, id);
    defer parked.deinit();
    try std.testing.expectEqual(.parked, parked.value.schedule);
    try std.testing.expect(!parked.value.terminal());
    try logicalSourceUnchanged(service, a, source_work, occurrence);
    try logicalObserverStop(service, a, task, id, "logical-observer-park-stop");
}

fn logicalObserverFailure(service: anytype, a: std.mem.Allocator, task: [16]u8, id: [32]u8) !void {
    for (0..64) |index| {
        var work = try service.workspaceWork(a, task, id);
        defer work.deinit();
        if (work.value.terminal()) {
            try std.testing.expectEqual(.failed, work.value.outcome_kind);
            try std.testing.expectEqual(null, work.value.observer.?.consumed_revision);
            return;
        }
        const operation = try std.fmt.allocPrint(a, "logical-observer-failure-pump-{d}", .{index});
        defer a.free(operation);
        try advanceObservedSource(service, a, work.value, operation);
    }
    return error.LogicalObserverDidNotFail;
}

fn logicalObserverStop(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    id: [32]u8,
    operation: []const u8,
) !void {
    var work = try service.workspaceWork(a, task, id);
    defer work.deinit();
    _ = try service.workspaceStopObserving(a, operation, task, .{
        .work = try workspaceRef(a, .work, id),
        .execution_revision = work.value.execution_revision,
        .control_revision = work.value.control_revision,
    });
}

fn logicalSourceUnchanged(
    service: anytype,
    a: std.mem.Allocator,
    source_work: native.workspace.Work,
    occurrence: []const u8,
) !void {
    var unchanged = try service.workspaceWork(a, source_work.task, source_work.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(source_work.checkpoint, unchanged.value.checkpoint);
    try std.testing.expectEqualDeep(source_work.current_port, unchanged.value.current_port);
    try std.testing.expectEqual(source_work.execution_revision, unchanged.value.execution_revision);
    try std.testing.expectEqual(source_work.control_revision, unchanged.value.control_revision);
    const pending = (try service.namespace.store.recordBytes(
        a,
        "occurrence",
        source_work.current_occurrence.?,
        source_work.task,
    )).?;
    defer a.free(pending);
    try std.testing.expectEqualSlices(u8, occurrence, pending);
}
