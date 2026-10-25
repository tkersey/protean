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
            std.debug.print("allocation failure: bytes={d} alignment={d} return_address={x} live={d} peak={d} required={d} budget_failed={}\n", .{
                len, alignment.toByteUnits(), ra, self.meter.live, self.meter.peak, self.meter.required, self.meter.failed,
            });
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
    try pumpGuardWitness(a, service, task, id, before.value.checkpoint);
    var agreed = try service.workspaceWork(a, task, id);
    defer agreed.deinit();
    try std.testing.expectEqual(@as(u64, 1), agreed.value.guard.?.agreed_segments);
    try std.testing.expectEqualDeep(before.value.runtime, agreed.value.runtime);
    const prior_continuation = agreed.value.guard.?.continuation.?;
    try retryGuardRestoreFailure(a, service, agreed.value);
    agreed.deinit();
    agreed = try service.workspaceWork(a, task, id);
    try std.testing.expectEqual(@as(u64, 2), agreed.value.guard.?.agreed_segments);
    try guardAgreementTamper(a, service, agreed.value, prior_continuation);
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

fn rewriteWorkspacePublication(a: std.mem.Allocator, service: anytype, work: native.workspace.Work) !void {
    try service.namespace.store.putRecord(native.workspace.Work, "workspace_work", work.id, work.task, work);
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
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?",
        &.{ .{ .blob = &work.task }, .{ .integer = @intCast(work.event_watermark) } },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
    defer event.deinit();
    const publications = try a.dupe(native.testing.state.WorkPublication, event.value.workspace_publications.items);
    defer a.free(publications);
    event.value.workspace_publications.items = publications;
    for (publications) |*publication| if (std.meta.eql(publication.work, work.id)) {
        publication.guard = work.guard;
        publication.observer = work.observer;
        publication.observation = observation.digest;
    };
    const encoded = try contracts.encodeOwned(native.testing.state.Event, a, event.value);
    defer a.free(encoded);
    const reference = try service.namespace.store.putObject(encoded);
    try service.namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{
        .{ .blob = &reference.digest }, .{ .blob = &work.task }, .{ .integer = @intCast(work.event_watermark) },
    });
    try rewritePublicationReceipts(a, service, work, observation);
}

fn rewritePublicationReceipts(a: std.mem.Allocator, service: anytype, work: native.workspace.Work, observation: native.testing.state.Reference) !void {
    var query = try service.namespace.store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &work.task }},
    );
    defer query.deinit();
    var replaced: usize = 0;
    while (try query.step() == .row) {
        var receipt = try contracts.decodeOwned(native.testing.state.Receipt, a, try query.bytes(1));
        defer receipt.deinit();
        if (receipt.value.workspace_kind != .work or
            !std.meta.eql(receipt.value.workspace, @as(?[32]u8, work.id))) continue;
        const bytes = try service.namespace.store.object(a, receipt.value.workspace_observation.?, null);
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

fn guardAgreementTamper(a: std.mem.Allocator, service: anytype, work: native.workspace.Work, earlier: native.testing.state.Reference) !void {
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try service.namespace.store.archiveIndex(a, work.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(service.allocator, work.task, index.records.items, &facts);
    try std.testing.expect(!std.meta.eql(earlier, work.guard.?.continuation.?));
    try service.namespace.store.begin();
    defer service.namespace.store.rollback();
    var forged = work;
    forged.guard.?.continuation = earlier;
    try rewriteWorkspacePublication(a, service, forged);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(service.allocator, work.task, index.records.items, &facts));
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

fn retryGuardRestoreFailure(a: std.mem.Allocator, service: anytype, initial: native.workspace.Work) !void {
    var failing: FailOneAllocationSize = .{
        .backing = a,
        .size = @intCast(initial.guard.?.continuation.?.bytes),
    };
    _ = try service.workspaceControl(failing.allocator(), "guard-restore-failure", initial.task, initial.id, initial.execution_revision, initial.control_revision, .advance);
    try std.testing.expect(failing.failed);
    var failed = try service.workspaceWork(a, initial.task, initial.id);
    defer failed.deinit();
    try std.testing.expectEqualStrings("OutOfMemory", failed.value.guard.?.failure.?.bytes);
    try std.testing.expect(failed.value.guard.?.pending_control != null);
    try std.testing.expectEqualDeep(initial.guard.?.continuation, failed.value.guard.?.continuation);
    try std.testing.expectEqualDeep(initial.checkpoint, failed.value.checkpoint);
    try restartGuardOwner(a, service);
    for (0..512) |index| {
        var current = try service.workspaceWork(a, initial.task, initial.id);
        defer current.deinit();
        _ = try service.workspacePump(a, try std.fmt.allocPrint(a, "guard-restore-retry-{d}", .{index}), initial.task, .{
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
            try std.testing.expectEqual(initial.guard.?.agreed_segments + 1, next.value.guard.?.agreed_segments);
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
        const command: @FieldType(contracts.workspace.Work, "pump") = .{
            .expected = .{
                .work = try workspaceRef(a, .work, id),
                .execution_revision = before.value.execution_revision,
                .control_revision = before.value.control_revision,
            },
            .base_quantum = if (index == 0 or
                (before.value.guard.?.candidate_segment != null and !reference_reopened)) 1 else 1048576,
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
        try std.testing.expectEqualDeep(before.value.current_occurrence, after.value.current_occurrence);
        try std.testing.expectEqual(
            before.value.execution_revision,
            after.value.execution_revision,
        );
        try std.testing.expect(after.value.guard.?.pending_control != null);
        if (index == 0 or (!reference_reopened and after.value.guard.?.reference_operation != null)) {
            if (after.value.guard.?.reference_operation) |pending| {
                try std.testing.expect(pending.dependencies.items.len != 0);
                try frozenGuardPayloadWitness(a, service, after.value);
                reference_reopened = true;
            }
            try restartGuardOwner(a, service);
            var reopened = try service.workspaceWork(a, task, id);
            defer reopened.deinit();
            try std.testing.expectEqual(
                after.value.guard.?.revision,
                reopened.value.guard.?.revision,
            );
            try std.testing.expectEqualDeep(
                after.value.guard.?.continuation,
                reopened.value.guard.?.continuation,
            );
            try std.testing.expectEqualDeep(
                after.value.guard.?.reference_operation,
                reopened.value.guard.?.reference_operation,
            );
            try std.testing.expectEqualDeep(
                after.value.guard.?.candidate_segment,
                reopened.value.guard.?.candidate_segment,
            );
            try std.testing.expectEqualDeep(
                after.value.guard.?.pending_control,
                reopened.value.guard.?.pending_control,
            );
        }
    }
    return error.GuardDidNotProgress;
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
    values[module.values.len] = .{ .schema = bytes, .expression = .{ .literal = module.constants.len } };
    const terms = try a.dupe(source.ast.Term, module.terms);
    var changed: usize = 0;
    for (module.terms) |term| {
        if (term != .match_sum or module.values[@intCast(term.match_sum.value)].schema != control) continue;
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
    const proposal = try native.source_records.encodeRecord(native.program_construction.CandidateDocument, a, .{
        .version = 1,
        .proposal = .{ .selected = try wrongAnswerSource(a, exported.value.selected.module), .steps = &.{} },
    });
    const response = try service.workspaceCommand(a, "guard-reply-derive", work.task, .{
        .program = .{ .derive = .{
            .ancestor = .{ .work = .{
                .expected = .{ .work = try workspaceRef(a, .work, work.id), .execution_revision = work.execution_revision, .control_revision = work.control_revision },
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

fn guardReplyOccurrence(a: std.mem.Allocator, service: anytype, work: native.workspace.Work) !contracts.Decoded(native.testing.occurrence.Occurrence) {
    const bytes = (try service.namespace.store.recordBytes(a, "occurrence", work.current_occurrence.?, work.task)).?;
    defer a.free(bytes);
    return contracts.decodeOwned(native.testing.occurrence.Occurrence, a, bytes);
}

fn acquireGuardReply(a: std.mem.Allocator, service: anytype, work: native.workspace.Work) !@FieldType(contracts.workspace.Work, "interact") {
    const bytes = try service.namespace.store.object(a, work.current_port.?, null);
    defer a.free(bytes);
    var port = try contracts.decodeOwned(native.workspace.Port, a, bytes);
    defer port.deinit();
    const interaction: @FieldType(contracts.workspace.Work, "interact") = .{
        .expected = .{ .work = try workspaceRef(a, .work, work.id), .execution_revision = work.execution_revision, .control_revision = work.control_revision },
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

fn pumpWrongReply(a: std.mem.Allocator, service: anytype, initial: native.workspace.Work, acquired: native.testing.occurrence.Acquired) !void {
    for (0..512) |index| {
        var before = try service.workspaceWork(a, initial.task, initial.id);
        defer before.deinit();
        _ = try service.workspacePump(a, try std.fmt.allocPrint(a, "guard-reply-pump-{d}", .{index}), initial.task, .{
            .expected = .{ .work = try workspaceRef(a, .work, initial.id), .execution_revision = before.value.execution_revision, .control_revision = before.value.control_revision },
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

fn assertWrongReplyState(a: std.mem.Allocator, service: anytype, initial: native.workspace.Work, reply: native.testing.state.Digest) !void {
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
        const retained = reference.takeCheckpoint(a) catch unreachable;
        a.free(retained);
    };
    var publication = try reference.publish(.{ .encoded = a }, .{ .reply = acquired }, .{ .quantum = 256, .checkpoint = .receipt });
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

fn finishGuardReplyCancellation(a: std.mem.Allocator, service: anytype, initial: native.workspace.Work, acquired: native.testing.occurrence.Acquired) !void {
    var current = try service.workspaceWork(a, initial.task, initial.id);
    defer current.deinit();
    _ = try service.workspaceControl(a, "guard-reply-cancel", initial.task, initial.id, current.value.execution_revision, current.value.control_revision, .{ .cancel = .{ .bytes = "discard wrong candidate" } });
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
            try std.testing.expectError(error.InvalidState, service.workspaceGuard(a, "guard-during-cleanup", initial.task, .{ .guard = .{
                .expected = .{
                    .work = try workspaceRef(a, .work, work.value.id),
                    .execution_revision = work.value.execution_revision,
                    .control_revision = work.value.control_revision,
                },
                .realization_revision = work.value.realization_revision,
                .candidate = try workspaceRef(a, .candidate, current.value.guard.?.candidate.digest),
            } }));
        }
        if (work.value.terminal()) {
            try std.testing.expectEqual(.cancelled, work.value.outcome_kind);
            try std.testing.expect(saw_cleanup);
            return;
        }
        _ = try service.workspaceControl(a, try std.fmt.allocPrint(a, "guard-reply-cleanup-{d}", .{index}), initial.task, initial.id, work.value.execution_revision, work.value.control_revision, .advance);
    }
    return error.GuardReplyCleanupDidNotComplete;
}

fn exerciseGuardReply(a: std.mem.Allocator, service: anytype, task: native.testing.state.TaskId) !void {
    var phase: []const u8 = "guest construction";
    errdefer std.debug.print("guard reply: {s}\n", .{phase});
    const program = try semanticGuestProgram(a, service, task, "guard-reply-build");
    const input = try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, a, .{ .yields = 0, .seed = 100 });
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
    const capture = (try service.namespace.store.recordBytes(a, "workspace_port_reply", acquired.attempt, task)).?;
    var artifact = try service.program.retainRuntime();
    defer artifact.deinit();
    const roots = [_]native.testing.state.Digest{kosmos.RuntimeCompiler.approvedRootIdentity(&artifact)};
    const policy = service.profile.semantic_construction;
    defer service.profile.semantic_construction = policy;
    service.profile.semantic_construction = .{ .roots = &roots, .checkers = &.{kosmos.RuntimeCompiler.checker_identity}, .guard = true };
    phase = "candidate derivation";
    const candidate = try guardReplyCandidate(a, service, answered.value, &artifact);
    phase = "guard admission";
    _ = try service.workspaceGuard(a, "guard-reply-enable", task, .{ .guard = .{
        .expected = .{ .work = try workspaceRef(a, .work, answered.value.id), .execution_revision = answered.value.execution_revision, .control_revision = answered.value.control_revision },
        .realization_revision = answered.value.realization_revision,
        .candidate = candidate,
    } });
    phase = "guarded reply execution";
    try pumpWrongReply(a, service, answered.value, acquired);
    phase = "independent state comparison";
    try assertWrongReplyState(a, service, answered.value, acquired.reply);
    phase = "owner restart";
    try restartGuardOwner(a, service);
    phase = "reply replay and cancellation";
    try std.testing.expect((try service.workspaceInteract(a, "guard-reply-capture", task, interaction)).replayed);
    try std.testing.expectEqual(count + 1, try guardReplyCount(service, task));
    try finishGuardReplyCancellation(a, service, answered.value, acquired);
    try std.testing.expect((try service.workspaceInteract(a, "guard-reply-capture", task, interaction)).replayed);
    try std.testing.expectEqual(count + 1, try guardReplyCount(service, task));
    const retained = (try service.namespace.store.recordBytes(a, "workspace_port_reply", acquired.attempt, task)).?;
    try std.testing.expectEqualSlices(u8, capture, retained);
    phase = "complete workspace validation";
    try service.validateWorkspace(a, task);
}

fn frozenGuardPayloadWitness(a: std.mem.Allocator, service: anytype, work: native.workspace.Work) !void {
    try std.testing.expect(work.guard.?.reference_operation.?.dependencies.items.len != 0);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var poisoned: support.PoisonFreedAllocator = .{ .backing = arena.allocator() };
    const operation_id = try std.fmt.allocPrint(a, "guard-payload-{s}-{d}", .{
        std.fmt.bytesToHex(work.id, .lower), work.guard.?.revision,
    });
    defer a.free(operation_id);
    const materialized = try service.workspaceCommand(poisoned.allocator(), operation_id, work.task, .{
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
    });
    try std.testing.expectEqual(.observed, materialized.disposition);
    const custody = try native.workspace.custodyId(a, work.task, try nativeIdentity(materialized.evidence.?));
    const bytes = (try service.namespace.store.recordBytes(a, "workspace_value", custody, work.task)).?;
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
    {
        var request = std.heap.ArenaAllocator.init(service.allocator);
        defer request.deinit();
        errdefer std.debug.print("divergent validation: scratch_capacity={d}\n", .{request.queryCapacity()});
        const frame = request.allocator();
        const inspected = try service.workspaceCommand(frame, "divergent-inspect", task, .{
            .work = .{ .inspect = .{ .work = try workspaceRef(frame, .work, id) } },
        });
        try std.testing.expectEqual(.observed, inspected.disposition);
        var observation = try native.json.parse(frame, inspected.observation_json.bytes, .{});
        defer observation.deinit();
        const guard = observation.value.object.get("guard") orelse return error.MissingGuardObservation;
        const inspected_guard = try native.values.fromJson(native.workspace.Guard, frame, guard);
        try std.testing.expectEqualDeep(divergent.value.guard.?, inspected_guard);
        var facts = try service.prepareWorkspaceValidation(task);
        defer facts.deinit();
        const prior = service.compiler_facts;
        service.compiler_facts = &facts;
        defer service.compiler_facts = prior;
        try service.validateWorkspace(frame, task);
    }
    try std.testing.expect(divergent.value.guard.?.initialized);
    try std.testing.expectEqualDeep(before.value.checkpoint, divergent.value.checkpoint);
    try std.testing.expectEqualDeep(
        before.value.current_occurrence,
        divergent.value.current_occurrence,
    );
    try std.testing.expectEqual(
        before.value.execution_revision,
        divergent.value.execution_revision,
    );
    try std.testing.expectError(error.GuardDiverged, service.workspaceControl(
        a,
        "divergent-no-fallback",
        task,
        id,
        divergent.value.execution_revision,
        divergent.value.control_revision,
        .advance,
    ));
    _ = try service.workspaceControl(a, "divergent-delegate", task, id, divergent.value.execution_revision, divergent.value.control_revision, .{
        .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal },
    });
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
    const program = try service.workspaceBuild(a, "controller-runtime-build", task_id, document, &diagnostic);
    stage = "specialize";
    const runtime = try service.workspaceSpecialize(a, "controller-runtime-specialize", task_id, program.receipt.workspace.?);
    const selected = try workspaceRef(a, .runtime, runtime.receipt.workspace.?);
    const command: @FieldType(contracts.workspace.Work, "realize_controller") = .{
        .expected = .{ .cut = .{ .epoch = original.value.controller_epoch, .execution_revision = original.value.execution_revision, .realization_revision = original.value.realization_revision } },
        .runtime = .{ .selected = selected },
    };
    stage = "denied policy";
    try std.testing.expectError(error.SemanticPolicyDenied, service.workspaceRealizeController(a, "controller-runtime-denied", task_id, command));
    stage = "read approved artifact";
    const runtime_record_bytes = try service.namespace.store.object(a, runtime.receipt.workspace_observation.?, null);
    defer a.free(runtime_record_bytes);
    var runtime_record = try contracts.decodeOwned(native.workspace.Runtime, a, runtime_record_bytes);
    defer runtime_record.deinit();
    const runtime_bytes = try service.namespace.store.object(a, runtime_record.value.artifact, null);
    defer a.free(runtime_bytes);
    var selected_artifact = try kosmos.RuntimeArtifact.init(a, runtime_bytes, runtime_record.value.artifact.digest);
    defer selected_artifact.deinit();
    const roots = [_][32]u8{kosmos.RuntimeCompiler.approvedRootIdentity(&selected_artifact)};
    const original_policy = service.profile.semantic_construction;
    service.profile.semantic_construction = .{ .roots = &roots, .checkers = &.{kosmos.RuntimeCompiler.checker_identity} };
    defer service.profile.semantic_construction = original_policy;
    stage = "select";
    const switched = try service.workspaceRealizeController(a, "controller-runtime-select", task_id, command);
    try std.testing.expect(!switched.replayed);
    var actual = try service.task(a, task_id);
    defer actual.deinit();
    try std.testing.expectEqualDeep(original.value.checkpoint, actual.value.checkpoint);
    try std.testing.expectEqual(original.value.execution_revision, actual.value.execution_revision);
    try std.testing.expectEqual(original.value.controller_epoch, actual.value.controller_epoch);
    try std.testing.expectEqualDeep(runtime.receipt.workspace.?, actual.value.controller_runtime.?.digest);
    try std.testing.expectEqual(original.value.realization_revision + 1, actual.value.realization_revision);
    stage = "placement";
    const placement_cut = try service.placementCut(a, .{ .task = task_id });
    try std.testing.expectEqual(actual.value.realization_revision, placement_cut.realization);
    try std.testing.expectEqualDeep(native.placement.ObjectIdentity.optional(actual.value.controller_runtime), placement_cut.runtime);
    _ = try service.placementCompatibility(a, .{ .task = task_id });

    stage = "revoked active policy";
    service.profile.semantic_construction = null;
    try std.testing.expectEqual(.idle, try service.pump(a));
    const independent = try service.submit(a, "policy-independent-task", .{ 25, 5 });
    try advanceControllerPast(a, service, independent.receipt.task, 0);
    var progressed = try service.task(a, independent.receipt.task);
    defer progressed.deinit();
    try std.testing.expect(progressed.value.execution_revision > 0);
    _ = try service.requestCancel(a, "policy-independent-cancel", independent.receipt.task, "ordinary control remains available");
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
    stage = "revoked restored policy";
    try service.park(a);
    var parked = try service.task(a, task_id);
    defer parked.deinit();
    _ = try service.resumeTask(a, "controller-runtime-resume", task_id, parked.value.revision);
    service.profile.semantic_construction = .{ .roots = &roots, .checkers = &.{} };
    try std.testing.expectEqual(.idle, try service.pump(a));
    var denied = try service.task(a, task_id);
    defer denied.deinit();
    try std.testing.expectEqual(actual.value.execution_revision, denied.value.execution_revision);
    try std.testing.expectEqualDeep(actual.value.checkpoint, denied.value.checkpoint);
    stage = "replay";
    try std.testing.expect((try service.workspaceRealizeController(a, "controller-runtime-select", task_id, command)).replayed);
    try std.testing.expectError(error.StaleRevision, service.workspaceRealizeController(a, "controller-runtime-stale", task_id, command));
    stage = "return packaged";
    _ = try service.workspaceRealizeController(a, "controller-runtime-packaged", task_id, .{ .expected = .{ .cut = .{ .epoch = actual.value.controller_epoch, .execution_revision = actual.value.execution_revision, .realization_revision = actual.value.realization_revision } }, .runtime = .{ .packaged = .{} } });
    var restored = try service.task(a, task_id);
    defer restored.deinit();
    try std.testing.expect(restored.value.controller_runtime == null);
    try std.testing.expectEqualDeep(original.value.checkpoint, restored.value.checkpoint);
    try std.testing.expectEqual(original.value.execution_revision, restored.value.execution_revision);
    stage = "historical controller cut";
    service.profile.semantic_construction = .{ .roots = &roots, .checkers = &.{kosmos.RuntimeCompiler.checker_identity} };
    try expectControllerRealizationCut(a, service, switched.receipt, original.value.execution_revision);
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
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.revision=?",
        &.{ .{ .blob = &receipt.task }, .{ .integer = @intCast(receipt.revision) } },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
    defer event.deinit();
    try std.testing.expectEqual(execution_revision, event.value.controller_read.?.execution_revision);
    try std.testing.expectEqual(event.value.seq - 1, event.value.controller_read.?.event_watermark);
    const bytes = try service.namespace.store.object(a, event.value.workspace_command.?, null);
    defer a.free(bytes);
    var command = try contracts.decodeOwned(native.workspace.PublicationCommand, a, bytes);
    defer command.deinit();
    try std.testing.expect(execution_revision > 0);
    stage = "mutations";
    for (0..5) |mutation| {
        errdefer std.debug.print("controller cut mutation: {d}\n", .{mutation});
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        var changed = event.value;
        var selected = command.value.realize_controller;
        switch (mutation) {
            0 => {
                selected.cut.execution_revision -= 1;
                selected.command.expected.cut.execution_revision -= 1;
            },
            1 => changed.controller_read.?.event_watermark -= 1,
            2 => changed.controller_read = null,
            3 => {
                selected.cut.execution_revision = parent.value.execution_revision;
                selected.command.expected.cut.execution_revision = parent.value.execution_revision;
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
            &facts,
        ));
    }
    try expectRootHistoryPrefixes(a, service, parent.value, index);
    try expectRootPublicationRejected(a, service, receipt.task, index, &facts);
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
                &.{ .{ .blob = &body.digest }, .{ .blob = &task }, .{ .integer = @intCast(changed.seq) } },
            );
            try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(a, task, index.records.items, facts));
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
        &.{ .{ .blob = &receipt.request_digest }, .{ .blob = &receipt_body.digest }, .{ .blob = &receipt.task }, .{ .blob = &original_receipt.request_digest } },
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
    const candidate = try scalarCandidate(b, transform, try b.reference(proposal), references, output);
    const transformed = try b.bind(proposal, try b.term(.{ .call = .{
        .function = layout,
        .arguments = &.{argument},
    } }), candidate);
    const untouched = try b.primitive(function.result, .product, &.{
        module,
        try producerLiteral(b, []const source.relation.RecordStep, &.{}),
        try producerLiteral(b, @FieldType(kosmos.RuntimeCompiler.RecordProposal, "interfaces"), null),
    }, 0);
    const normalized = try b.bind(proposal, try b.pure(untouched), candidate);
    const schemas = try producerField(b, module, std.meta.fieldIndex(source.Module, "schemas").?);
    const schema = try producerRequired(b, schemas, selected);
    const fields = try producerPayload(b, schema, std.meta.fieldIndex(data.program.Schema, "product").?);
    const first = try producerRequired(b, fields, try b.constant(u64, 0));
    const second = try producerRequired(b, fields, try b.constant(u64, 1));
    const reorder = try b.primitive(try b.scalar(bool), .less, &.{ second, first }, 0);
    const body = try b.term(.{ .conditional = .{
        .condition = reorder,
        .when_true = transformed,
        .when_false = normalized,
    } });
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

const ProducerExpression = @FieldType(source.ast.Value, "expression");
const ProducerPrimitive = @FieldType(ProducerExpression, "primitive");

fn producerFold(b: *source.Builder) !source.Module {
    const module_schema = try contracts.schema(source.Module, b);
    const users_schema = try contracts.schema([]const []const source.relation.Relocation.Reference, b);
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
    const ref_variable = try b.variable(try contracts.schema(source.relation.Relocation.Reference, b));
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
    ), try b.bind(row_variable, try b.pure(try producerRequired(b, values, index)), selected), miss);
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
    return producerPayload(b, try b.primitive(optional, .sequence_get, &.{ sequence, index }, 0), 1);
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
    var reference = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        value,
    );
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
            try std.testing.expectEqual(@as(usize, if (expected_layout) 2 else 1), result.value.proposal.steps.len);
            const steps = result.value.proposal.steps;
            try std.testing.expect(steps[steps.len - 1].rule == .scalar);
            if (expected_layout) try std.testing.expect(steps[0].rule == .product_layout);
            std.debug.print("generated transformer {s}: input={d} result={d} guest_work={d} publications={d} elapsed_ms={d} native_publication_ns={d}\n", .{
                label,
                current.value.input.bytes,
                current.value.result.?.bytes,
                guest_work,
                turn + 1,
                std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started_ms,
                current.value.native_publication_nanoseconds,
            });
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

fn runTransformer(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: contracts.workspace.Ref,
    ancestor: contracts.workspace.SemanticTarget,
    label: []const u8,
    expected_layout: bool,
) !struct { work: contracts.workspace.Ref, result: contracts.workspace.Ref } {
    const input = materialize: {
        var request = std.heap.ArenaAllocator.init(service.allocator);
        defer request.deinit();
        const scratch = request.allocator();
        const materialized = try service.workspaceCommand(
            scratch,
            try std.fmt.allocPrint(scratch, "{s}-semantic-source", .{label}),
            task,
            .{ .context = .{ .materialize = .{
                .input = .{ .semantic_source = .{
                    .subject = ancestor,
                    .module = .{ .selected = .{} },
                    .references = true,
                } },
                .sources = .{ .items = &.{} },
            } } },
        );
        const reference = try semanticReference(scratch, materialized, "value");
        if (expected_layout) try semanticContextWitness(scratch, service, task, reference, label);
        break :materialize try workspaceRef(a, reference.kind, try nativeIdentity(reference));
    };
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
    return .{ .work = work, .result = try finishTransformer(a, service, task, work, label, started_ms, expected_layout) };
}

fn semanticContextWitness(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    input: contracts.workspace.Ref,
    label: []const u8,
) !void {
    try std.testing.expect(service.compiler_facts == null);
    try std.testing.expectError(error.MissingArtifact, service.namespace.store.objectReference(@splat(0), null));
    {
        var facts: @TypeOf(service.*).CompilerFacts = .{ .allocator = a };
        defer facts.deinit();
        service.compiler_facts = &facts;
        defer service.compiler_facts = null;
        const rejected = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-missing-schema", .{label}), task, .{
            .context = .{ .materialize = .{
                .input = .{ .value = .{ .inline_json = .{
                    .schema = try workspaceRef(a, .schema, @splat(0)),
                    .json_text = .{ .bytes = "null" },
                } } },
                .sources = .{ .items = &.{} },
            } },
        });
        try std.testing.expectEqual(.rejected, rejected.disposition);
        var parsed = try native.json.parse(a, rejected.observation_json.bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("ArtifactUnavailable", parsed.value.object.get("error").?.string);
        try std.testing.expectEqual(@as(usize, 0), facts.entries.count());
        try std.testing.expectEqual(@as(usize, 0), facts.sources.count());
        try std.testing.expectEqual(@as(usize, 0), facts.values.count());
    }
    const materialized = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-source-reference", .{label}), task, .{
        .context = .{ .materialize = .{
            .input = .{ .value = .{ .reference = input } },
            .sources = .{ .items = &.{} },
        } },
    });
    try std.testing.expectEqual(.observed, materialized.disposition);
    try std.testing.expectEqualDeep(input, materialized.evidence.?);
    try std.testing.expect(service.compiler_facts == null);
    const selected = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-source-selection", .{label}), task, .{
        .context = .{ .select = .{ .values = .{ .items = &.{input} } } },
    });
    try std.testing.expectEqual(.observed, selected.disposition);
    try std.testing.expect(selected.selected_view != null);
    try std.testing.expect(service.compiler_facts == null);
    try semanticBasisShapeWitness(a, service, task, input);
}

fn semanticBasisShapeWitness(a: std.mem.Allocator, service: anytype, task: [16]u8, input: contracts.workspace.Ref) !void {
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
        forged.description.provenance = try service.namespace.store.putObject(try contracts.encodeOwned(native.workspace.Derivation, a, forged.derivation));
        forged.artifact = try service.namespace.store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, a, forged.description));
        forged.id = try native.workspace.custodyId(a, task, forged.artifact.digest);
        try service.namespace.store.createRecord(native.workspace.Value, "workspace_value", forged.id, task, forged);
        const body = try service.namespace.store.putObject(try contracts.encodeOwned(native.workspace.Value, a, forged));
        records[0] = .{ .kind = .workspace_value, .id = forged.id, .body = body };
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(a, task, records, &facts));
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
    const construction_ns = std.math.cast(u64, @max(0, std.Io.Clock.awake.now(std.testing.io).nanoseconds - construction_started.nanoseconds)) orelse std.math.maxInt(u64);
    phase = "construction timing";
    try expectCompilerTime(a, service, task, derived);
    phase = "reference guard";
    if (guard_input) |input| try exerciseGuard(a, service, task, program, input, candidate);
    phase = "independent validation";
    const validation_started = std.Io.Clock.awake.now(std.testing.io);
    const validated = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "{s}-validate", .{label}),
        task,
        .{ .program = .{ .validate = .{ .candidate = candidate } } },
    );
    const runtime = try semanticReference(a, validated, "runtime");
    const validation_ns = std.math.cast(u64, @max(0, std.Io.Clock.awake.now(std.testing.io).nanoseconds - validation_started.nanoseconds)) orelse std.math.maxInt(u64);
    phase = "validation timing";
    try expectCompilerTime(a, service, task, validated);
    phase = "runtime inspection";
    try expectRuntimeInspection(a, service, task, runtime, label);
    if (ancestor == .runtime)
        try std.testing.expect(!std.meta.eql(try nativeIdentity(ancestor.runtime), try nativeIdentity(runtime)));
    phase = "helper correspondence";
    try helperCorrespondence(a, service, task, ancestor, runtime, expected_layout);
    return .{
        .candidate = candidate,
        .runtime = runtime,
        .producer = producer,
        .result = result.result,
        .construction_ns = construction_ns,
        .validation_ns = validation_ns,
    };
}

fn expectRuntimeInspection(a: std.mem.Allocator, service: anytype, task: native.testing.state.TaskId, runtime: contracts.workspace.Ref, label: []const u8) !void {
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
    const reference = observation.value.object.get("runtime") orelse return error.MissingInspectedRuntime;
    const actual = try native.values.fromJson(contracts.workspace.Ref, a, reference);
    try std.testing.expectEqualDeep(runtime, actual);
}

fn expectCompilerTime(a: std.mem.Allocator, service: anytype, task: native.testing.state.TaskId, reply: contracts.workspace.Reply) !void {
    var observation = try native.json.parse(a, reply.observation_json.bytes, .{});
    defer observation.deinit();
    const measured = observation.value.object.get("compiler_nanoseconds") orelse return error.MissingCompilerTime;
    const elapsed = try native.json.numberInteger(u64, measured.number_string);
    var query = try service.namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq DESC", &.{.{ .blob = &task }});
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

fn semanticWork(a: std.mem.Allocator, work: native.workspace.Work) !contracts.workspace.SemanticTarget {
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
            var work = try service.workspaceWork(a, task, try nativeIdentity(selection.expected.work));
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
    var candidate = try service.workspaceCandidate(scratch, task, try nativeIdentity(generated.candidate));
    defer candidate.deinit();
    const ancestor = try service.namespace.store.object(scratch, candidate.value.description.ancestor, null);
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
    const descriptor = try contracts.encodeOwned(native.workspace.CandidateArtifact, scratch, description);
    var reference: native.testing.state.Reference = .{ .digest = undefined, .bytes = descriptor.len };
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
    for ([_]contracts.workspace.SemanticTarget{ before, .{ .runtime = after } }, &exports) |subject, *exported| {
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
    var document = try contracts.decodeOwned(native.program_construction.CandidateDocument, a, bytes);
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
    var parsed = try native.json.parseAsset(a, rejected.observation_json.bytes, rejected.observation_json.bytes.len);
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
    const document = try native.source_records.encode(a, try @import("workspace_sources.zig").semanticGuest(&builder));
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
    const input = try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, a, .{ .yields = 2, .seed = 100 });
    defer a.free(input);
    var outcome = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{ .initial_args = input } });
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
            .requested => |requested| blk: {
                var request = try data.invocation.decode(data.invocation.Request, a, requested.request);
                defer request.deinit();
                const identity = request.value.binding.semantic_identity;
                const value = if (std.mem.endsWith(u8, identity, "/0")) answer: {
                    questions += 1;
                    break :answer try contracts.encodeOwned(bool, a, true);
                } else if (std.mem.endsWith(u8, identity, "/1")) answer: {
                    prefixes += 1;
                    var prefix = try contracts.decodeOwned(u64, a, request.value.binding.payload);
                    defer prefix.deinit();
                    try std.testing.expectEqual(@as(u64, 101), prefix.value);
                    break :answer try contracts.encodeOwned(void, a, {});
                } else answer: {
                    try std.testing.expect(std.mem.endsWith(u8, identity, "/2"));
                    var observed = try contracts.decodeOwned(struct { void, ?u64 }, a, request.value.binding.payload);
                    defer observed.deinit();
                    try std.testing.expectEqual(@as(?u64, if (alternatives == 0) null else if (alternatives == 1) 111 else 121), observed.value[1]);
                    alternatives += 1;
                    const Command = union(enum) { instantiate: u64, finish: void };
                    break :answer try contracts.encodeOwned(Command, a, if (alternatives == 3)
                        .{ .finish = {} }
                    else
                        .{ .instantiate = if (alternatives == 1) 10 else 20 });
                };
                defer a.free(value);
                const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                    .request_identity = request.value.request_identity,
                    .value = value,
                });
                defer a.free(reply);
                break :blk try kosmos.invocation.invoke(a, .{
                    .image = image,
                    .instance = .{ .state = requested.state.? },
                    .control = .{ .reply = reply },
                });
            },
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
    return std.math.cast(u64, @max(0, std.Io.Clock.awake.now(std.testing.io).nanoseconds - started)) orelse std.math.maxInt(u64);
}

fn sharedReply(a: std.mem.Allocator, service: anytype, work: native.workspace.Work, label: []const u8) !void {
    const bytes = try service.namespace.store.object(a, work.current_port.?, null);
    defer a.free(bytes);
    var port = try contracts.decodeOwned(native.workspace.Port, a, bytes);
    defer port.deinit();
    _ = try service.workspaceInteract(a, try std.fmt.allocPrint(a, "shared-{s}-reply", .{label}), work.task, .{
        .expected = .{ .work = try workspaceRef(a, .work, work.id), .execution_revision = work.execution_revision, .control_revision = work.control_revision },
        .port = try workspaceRef(a, .port, port.value.id),
        .generation = port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{
            .schema = try workspaceRef(a, .schema, port.value.interface.argument.digest),
            .json_text = .{ .bytes = "true" },
        } } },
    });
}

fn sharedAdvance(a: std.mem.Allocator, service: anytype, work: native.workspace.Work, arm: SharedArm, cut: usize) !void {
    for (0..512) |turn| {
        var current = try service.workspaceWork(a, work.task, work.id);
        defer current.deinit();
        if (current.value.execution_revision != work.execution_revision) {
            try std.testing.expectEqual(work.execution_revision + 1, current.value.execution_revision);
            if (arm.candidate != null) {
                try std.testing.expectEqual(.agreed, current.value.guard.?.disposition);
                try std.testing.expectEqual(cut + 1, current.value.guard.?.agreed_segments);
            }
            return;
        }
        const operation_id = try std.fmt.allocPrint(a, "shared-{s}-cut-{d}-pump-{d}", .{ arm.label, cut, turn });
        if (arm.candidate != null) {
            try std.testing.expect(current.value.guard.?.disposition != .diverged);
            try std.testing.expect(current.value.guard.?.failure == null);
            _ = try service.workspacePump(a, operation_id, work.task, .{
                .expected = .{ .work = try workspaceRef(a, .work, work.id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
                .base_quantum = 1048576,
            });
        } else {
            _ = try service.workspaceControl(a, operation_id, work.task, work.id, current.value.execution_revision, current.value.control_revision, .advance);
        }
    }
    return error.SharedComparisonDidNotAdvance;
}

fn sharedCut(a: std.mem.Allocator, service: anytype, work: native.workspace.Work, cut: usize, result: *SharedArmResult) !void {
    try std.testing.expectEqual(if (cut < 2) native.testing.state.Outcome.yielded else .requested, work.outcome_kind);
    result.checkpoints[cut] = work.checkpoint;
    result.outcomes[cut] = work.outcome;
    result.checkpoint_bytes += work.checkpoint.bytes;
    result.outcome_bytes += work.outcome.bytes;
    result.guest_work += work.guest_work;
    if (work.runtime_trace) |trace| {
        const encoded = try contracts.encodeOwned(kosmos.RuntimeInstrumentation.Output, a, trace.output);
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

fn sharedPublicationCosts(a: std.mem.Allocator, service: anytype, work: native.workspace.Work, label: []const u8, result: *SharedArmResult) !void {
    const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    _ = try service.workspaceRequestCut(a, try std.fmt.allocPrint(a, "shared-{s}-checkpoint", .{label}), work.task, .{
        .expected = .{ .work = try workspaceRef(a, .work, work.id), .execution_revision = work.execution_revision, .control_revision = work.control_revision },
        .level = .guest_cut,
    });
    result.checkpoint_ns = sharedElapsed(started);
    var retained = try service.workspaceWork(a, work.task, work.id);
    defer retained.deinit();
    result.capsule_bytes = retained.value.runtime_capsule.?.bytes;
    const inspect_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const inspected = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "shared-{s}-inspect", .{label}), work.task, .{
        .work = .{ .inspect = .{ .work = try workspaceRef(a, .work, work.id) } },
    });
    result.inspection_ns = sharedElapsed(inspect_started);
    result.inspection_bytes = inspected.observation_json.bytes.len;
}

fn sharedArm(a: std.mem.Allocator, meter: *kosmos.AllocationBudget, service: anytype, task: native.testing.state.TaskId, program: native.testing.state.Digest, input: []const u8, arm: SharedArm) !SharedArmResult {
    const started = try service.workspaceStart(a, try std.fmt.allocPrint(a, "shared-{s}-start", .{arm.label}), task, program, input, .{});
    const id = started.receipt.workspace.?;
    var initial = try service.workspaceWork(a, task, id);
    defer initial.deinit();
    try std.testing.expectEqual(.requested, initial.value.outcome_kind);
    var result: SharedArmResult = .{ .initial = initial.value.checkpoint };
    const expected: contracts.workspace.Expected = .{ .work = try workspaceRef(a, .work, id), .execution_revision = initial.value.execution_revision, .control_revision = initial.value.control_revision };
    if (arm.runtime) |runtime| _ = try service.workspaceRealize(a, try std.fmt.allocPrint(a, "shared-{s}-select", .{arm.label}), task, .{
        .expected = expected,
        .realization_revision = initial.value.realization_revision,
        .runtime = .{ .selected = runtime },
    });
    if (arm.candidate) |candidate| _ = try service.workspaceGuard(a, try std.fmt.allocPrint(a, "shared-{s}-guard", .{arm.label}), task, .{ .guard = .{
        .expected = expected,
        .realization_revision = initial.value.realization_revision,
        .candidate = candidate,
    } });
    var selected = try service.workspaceWork(a, task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(result.initial, selected.value.checkpoint);
    try sharedReply(a, service, selected.value, arm.label);
    var pending = try guardReplyOccurrence(a, service, selected.value);
    defer pending.deinit();
    result.reply = pending.value.state.settled_reply.reply;
    {
        var settled = try service.workspaceWork(a, task, id);
        defer settled.deinit();
        const restart_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        try restartGuardOwner(a, service);
        result.owner_restart_ns = sharedElapsed(restart_started);
        var reopened = try service.workspaceWork(a, task, id);
        defer reopened.deinit();
        try std.testing.expectEqualDeep(settled.value.checkpoint, reopened.value.checkpoint);
        try std.testing.expectEqual(settled.value.execution_revision, reopened.value.execution_revision);
        try std.testing.expectEqual(settled.value.control_revision, reopened.value.control_revision);
        try std.testing.expectEqual(settled.value.realization_revision, reopened.value.realization_revision);
        try std.testing.expectEqualDeep(settled.value.runtime, reopened.value.runtime);
        try std.testing.expectEqualDeep(settled.value.runtime_capsule, reopened.value.runtime_capsule);
        try std.testing.expectEqualDeep(settled.value.guard, reopened.value.guard);
        try std.testing.expectEqualDeep(settled.value.current_occurrence, reopened.value.current_occurrence);
        var reopened_pending = try guardReplyOccurrence(a, service, reopened.value);
        defer reopened_pending.deinit();
        try std.testing.expectEqualDeep(pending.value.state.settled_reply, reopened_pending.value.state.settled_reply);
    }
    meter.resetObservation();
    result.requested_backing_live_baseline = meter.live;
    for (0..3) |cut| {
        var before = try service.workspaceWork(a, task, id);
        defer before.deinit();
        const continuation_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        try sharedAdvance(a, service, before.value, arm, cut);
        const continuation_ns = sharedElapsed(continuation_started);
        result.continuation_ns +|= continuation_ns;
        if (cut == 0) result.first_continuation_including_reconstruction_ns = continuation_ns else result.remaining_continuation_ns +|= continuation_ns;
        var after = try service.workspaceWork(a, task, id);
        defer after.deinit();
        try sharedCut(a, service, after.value, cut, &result);
    }
    result.requested_backing_peak = meter.peak;
    result.requested_backing_live_end = meter.live;
    result.requested_backing_peak_above_baseline = meter.peak - result.requested_backing_live_baseline;
    var final = try service.workspaceWork(a, task, id);
    defer final.deinit();
    try sharedPublicationCosts(a, service, final.value, arm.label, &result);
    try sharedCancel(a, service, task, id, arm.label);
    return result;
}

fn sharedCancel(a: std.mem.Allocator, service: anytype, task: native.testing.state.TaskId, id: native.testing.state.Digest, label: []const u8) !void {
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
        _ = try service.workspaceControl(a, try std.fmt.allocPrint(a, "shared-{s}-cleanup-{d}", .{ label, turn }), task, id, work.value.execution_revision, work.value.control_revision, if (turn == 0 and work.value.cancellation == null)
            .{ .cancel = .{ .bytes = "shared comparison complete" } }
        else
            .advance);
    }
    return error.SharedComparisonDidNotCancel;
}

fn sharedArtifactCosts(a: std.mem.Allocator, service: anytype, task: native.testing.state.TaskId, arm: SharedArm) !struct { artifact: usize, evidence: usize, proposal: u64 } {
    var generic = try service.program.retainRuntime();
    defer generic.deinit();
    if (arm.runtime == null and arm.candidate == null) {
        const bytes = try generic.encode(a);
        defer a.free(bytes);
        return .{ .artifact = bytes.len, .evidence = generic.content.value.evidence.len, .proposal = 0 };
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

fn sharedCompare(a: std.mem.Allocator, service: anytype, expected: SharedArmResult, actual: SharedArmResult) !void {
    try std.testing.expectEqualDeep(expected.initial, actual.initial);
    try std.testing.expectEqualDeep(expected.reply, actual.reply);
    try std.testing.expectEqual(expected.guest_work, actual.guest_work);
    for (expected.checkpoints, actual.checkpoints, expected.outcomes, actual.outcomes) |left, right, left_outcome, right_outcome| {
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
    const instrumented = try service.workspaceSpecializeWithHooks(a, "shared-instrument", task, program, .{ .control = true, .storage = true });
    const instrumentation_ns = sharedElapsed(instrumentation_started);
    const previous_roots = service.profile.semantic_construction.?.roots;
    const roots = [_][32]u8{
        previous_roots[0],
        previous_roots[1],
        kosmos.RuntimeCompiler.approvedRootIdentity(&service.runtime_cache.?.artifact),
    };
    service.profile.semantic_construction.?.roots = &roots;
    defer service.profile.semantic_construction.?.roots = previous_roots;
    const input = try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, a, .{ .yields = 0, .seed = 100 });
    defer a.free(input);
    const arms = [_]SharedArm{
        .{ .label = "generic" },
        .{ .label = "specialized", .runtime = specialized, .construction_validation_ns = specialization_ns },
        .{ .label = "generated", .runtime = generated.runtime },
        .{ .label = "instrumented", .runtime = try workspaceRef(a, .runtime, instrumented.receipt.workspace.?), .construction_validation_ns = instrumentation_ns },
        .{ .label = "guarded", .candidate = generated.candidate },
    };
    std.debug.print("shared comparison: scope=three-cuts-from-identical-retained-request-after-owner-restart controls=true,resume_yield,resume_yield expected=yielded,yielded,prefix101 includes=continuation-and-persistence excludes=initialization-selection-reply-acquisition-cleanup reconstruction=first-continuation-including-execution-and-publication-not-isolated-restore requested_memory=root-requested-Zig-backing-bytes memory_scope=three-cuts-and-cut-assertions memory_baseline=retained-owners-and-arenas memory_excludes=restart-publication-costs-cleanup-artifact-comparison-C-SQLite-OS-RSS allocator_resize_remap=disabled timing=instrumented-no-speedup-claim generated_construction_ns={d} generated_validation_ns={d} producer_build_ns={any} guard_agreement=finite-only byte_counts=logical-references-not-deduplicated-footprint\n", .{ generated.construction_ns, generated.validation_ns, generated.producer_build_ns });
    var baseline: ?SharedArmResult = null;
    for (arms) |arm| {
        const result = try sharedArm(a, meter, service, task, program, input, arm);
        if (baseline) |expected| try sharedCompare(a, service, expected, result) else baseline = result;
        const costs = try sharedArtifactCosts(a, service, task, arm);
        std.debug.print("shared arm={s} construction_validation_ns={any} owner_restart_ns={d} first_continuation_including_reconstruction_ns={d} remaining_continuation_ns={d} continuation_ns={d} requested_backing_live_baseline={d} requested_backing_peak={d} requested_backing_live_end={d} requested_backing_peak_above_baseline={d} guest_work={d} checkpoint_publication_ns={d} inspection_ns={d} artifact_bytes={d} evidence_bytes={d} candidate_proposal_bytes={d} published_guest_checkpoint_bytes={d} published_outcome_bytes={d} retained_capsule_bytes={d} inspection_bytes={d} trace_bytes={d} guard_reference_ns={d} guard_candidate_ns={d} guard_capsule_bytes={d}\n", .{
            arm.label,                         arm.construction_validation_ns,               result.owner_restart_ns,                result.first_continuation_including_reconstruction_ns,
            result.remaining_continuation_ns,  result.continuation_ns,                       result.requested_backing_live_baseline, result.requested_backing_peak,
            result.requested_backing_live_end, result.requested_backing_peak_above_baseline, result.guest_work,                      result.checkpoint_ns,
            result.inspection_ns,              costs.artifact,                               costs.evidence,                         costs.proposal,
            result.checkpoint_bytes,           result.outcome_bytes,                         result.capsule_bytes,                   result.inspection_bytes,
            result.trace_bytes,                result.guard_reference_ns,                    result.guard_candidate_ns,              result.guard_capsule_bytes,
        });
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
    const started = try service.workspaceStart(a, label, task, program, input, .{ .stop = .terminal });
    for (0..4096) |turn| {
        var current = try service.workspaceWork(a, task, started.receipt.workspace.?);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.completed, current.value.outcome_kind);
            const inspection = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-inspect", .{label}), task, .{
                .work = .{ .inspect = .{ .work = try workspaceRef(a, .work, current.value.id) } },
            });
            var observation = try native.json.parseAsset(a, inspection.observation_json.bytes, inspection.observation_json.bytes.len);
            defer observation.deinit();
            const evidence = observation.value.object.get("interpretation_evidence").?;
            try std.testing.expectEqualStrings("experimental", evidence.object.get("evidence_class").?.string);
            try std.testing.expectEqual(.null, std.meta.activeTag(evidence.object.get("analysis_checker").?));
            try std.testing.expectEqualDeep(program, try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, a, evidence.object.get("program").?)));
            try std.testing.expectEqualDeep(current.value.id, try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, a, evidence.object.get("work").?)));
            try std.testing.expectEqualDeep(current.value.input_value.?.digest, try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, a, evidence.object.get("input").?)));
            const bytes = try service.namespace.store.object(a, current.value.result.?, null);
            defer a.free(bytes);
            return contracts.decodeOwned(kosmos.RuntimeAnalysis.InterpretationOutput, a, bytes);
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

fn semanticGuestInterpretation(a: std.mem.Allocator, service: anytype, original: native.workspace.Work) !void {
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
    var unfinished = try runInterpretation(a, service, original.task, analysis, &.{}, "semantic-interpretation-missing");
    defer unfinished.deinit();
    try std.testing.expectEqual(.missing_assumption, unfinished.value.stopping);
    try std.testing.expectEqual(@as(u64, 0), unfinished.value.applied);
    try std.testing.expectEqualDeep(guest.identity(), unfinished.value.guest);
    phase = "resumed program construction";
    const resumed = try interpretationProgram(a, service, original.task, guest, unfinished.value.state, "semantic-interpretation-resume-build");
    phase = "true assumption execution";
    var positive = try runInterpretation(a, service, original.task, resumed, &.{&.{1}}, "semantic-interpretation-true");
    defer positive.deinit();
    phase = "false assumption execution";
    var negative = try runInterpretation(a, service, original.task, resumed, &.{&.{0}}, "semantic-interpretation-false");
    defer negative.deinit();
    phase = "branch provenance and original state";
    for ([_]kosmos.RuntimeAnalysis.InterpretationOutput{ positive.value, negative.value }) |result| {
        try std.testing.expectEqual(.yielded, result.stopping);
        try std.testing.expectEqual(@as(u64, 1), result.applied);
        try std.testing.expectEqual(@as(usize, 1), result.requests.len);
        try std.testing.expectEqualDeep(guest.identity(), result.guest);
    }
    try std.testing.expectEqualSlices(u8, &.{1}, positive.value.assumptions[0]);
    try std.testing.expectEqualSlices(u8, &.{0}, negative.value.assumptions[0]);
    const State = @FieldType(kosmos.RuntimeAnalysis.InterpretationOutput, "state");
    try std.testing.expect(!data.record.equal(State, positive.value.state, negative.value.state));
    var unchanged = try service.workspaceWork(a, original.task, original.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(original.checkpoint, unchanged.value.checkpoint);
    try std.testing.expectEqualDeep(original.current_occurrence, unchanged.value.current_occurrence);
    try std.testing.expectEqual(original.execution_revision, unchanged.value.execution_revision);
    try std.testing.expectEqual(original.control_revision, unchanged.value.control_revision);
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
    try expectValidationResourceOutcome(a, service, task, generated);
    try exerciseWrongCandidate(a, service, task, program, input, ancestor, generated.result);
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
    try std.testing.expect(!std.meta.eql(try nativeIdentity(generated.result), try nativeIdentity(reused.result)));
    const work = try workspaceRef(a, .work, id);
    _ = try service.workspaceRealize(a, "generated-select", task, .{
        .expected = .{
            .work = work,
            .execution_revision = before.value.execution_revision,
            .control_revision = before.value.control_revision,
        },
        .realization_revision = before.value.realization_revision,
        .runtime = .{ .selected = generated.runtime },
    });
    var selected = try service.workspaceWork(a, task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(before.value.checkpoint, selected.value.checkpoint);
    const inspected = try service.workspaceCommand(a, "generated-selected-source", task, .{
        .program = .{ .inspect = .{
            .target = .{ .semantic_source = .{
                .subject = .{ .work = .{
                    .expected = .{ .work = work, .execution_revision = selected.value.execution_revision, .control_revision = selected.value.control_revision },
                    .realization_revision = selected.value.realization_revision,
                } },
                .section = .{ .summary = .{} },
            } },
            .page = .{ .maximum = 128 },
        } },
    });
    try std.testing.expectEqualDeep(generated.runtime, try semanticReference(a, inspected, "runtime"));
    try advanceGeneratedOuter(a, service, selected.value, generated.runtime);
    var advanced = try service.workspaceWork(a, task, id);
    defer advanced.deinit();
    try std.testing.expect(advanced.value.execution_revision > selected.value.execution_revision);
    try std.testing.expectEqualDeep(try nativeIdentity(generated.runtime), advanced.value.runtime.?.digest);
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
    try std.testing.expectEqualStrings(&identity, parsed.value.object.get("runtime_identity").?.string);
    const returned = try native.values.fromJson(contracts.workspace.SemanticTarget, a, parsed.value.object.get("subject").?);
    try std.testing.expectEqualDeep(subject, returned);
    const again = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-returned", .{label}), task, .{ .program = .{ .inspect = .{
        .target = .{ .semantic_source = .{ .subject = returned, .section = .{ .summary = .{} } } },
        .page = .{},
    } } });
    try std.testing.expectEqual(.observed, again.disposition);
    try std.testing.expectEqualStrings(response.observation_json.bytes, again.observation_json.bytes);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var offset: u64 = 0;
    while (true) {
        const part = if (offset == 0) response else try service.workspaceCommand(a, try std.fmt.allocPrint(a, "{s}-page-{d}", .{ label, offset }), task, .{ .program = .{ .inspect = .{
            .target = .{ .semantic_source = .{ .subject = returned, .section = .{ .summary = .{} } } },
            .page = .{ .offset = offset },
        } } });
        try std.testing.expectEqual(.observed, part.disposition);
        var page = try native.json.parse(a, part.observation_json.bytes, .{});
        defer page.deinit();
        try text.appendSlice(a, page.value.object.get("text").?.string);
        if (page.value.object.get("eof").?.bool) break;
        const next = try native.json.numberInteger(u64, page.value.object.get("next_offset").?.number_string);
        try std.testing.expect(next > offset);
        offset = next;
    }
    var summary = try native.json.parse(a, text.items, .{});
    defer summary.deinit();
    try std.testing.expect(!summary.value.object.contains("runtime"));
    try std.testing.expectEqualStrings(&identity, summary.value.object.get("runtime_identity").?.string);
}

const CleanupTrace = struct {
    scans: usize = 0,
    work_reads: usize = 0,
    history_scans: usize = 0,
    extern "c" fn sqlite3_db_handle(?*anyopaque) ?*anyopaque;
    extern "c" fn sqlite3_expanded_sql(?*anyopaque) ?[*:0]u8;
    extern "c" fn sqlite3_free(?*anyopaque) void;
    extern "c" fn sqlite3_trace_v2(?*anyopaque, c_uint, ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_int;

    fn observe(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, sql: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(sql.?)));
        if (std.mem.eql(u8, text, "SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id")) self.scans += 1;
        if (std.mem.eql(u8, text, "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq")) self.history_scans += 1;
        if (std.mem.eql(u8, text, "SELECT body FROM records WHERE kind=? AND id=? AND task=?")) {
            const expanded = sqlite3_expanded_sql(statement) orelse return 0;
            defer sqlite3_free(expanded);
            if (std.mem.startsWith(u8, std.mem.span(expanded), "SELECT body FROM records WHERE kind='workspace_work'")) self.work_reads += 1;
        }
        return 0;
    }
};

test "scheduler bounds cleanup scans during productive scheduling and completes idle sweeps" {
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
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "scheduler-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "scheduler-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "scheduler-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "scheduler-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    var productive_scan_bound = true;
    for ([_]usize{ 8, 32 }) |count| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const path = try std.fmt.allocPrint(scratch, "{s}/tasks-{d}", .{ path_buffer[0..length], count });
        var namespace = try native.Namespace.open(a, io, path);
        defer namespace.close() catch unreachable;
        var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        defer service.close(a) catch unreachable;
        const ids = try scratch.alloc(native.testing.state.TaskId, count);
        for (ids, 0..) |*id, index| id.* = (try service.submit(scratch, try std.fmt.allocPrint(scratch, "task-{d}", .{index}), .{ 25, 5 })).receipt.task;
        var statement = try namespace.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace));
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        for (0..count) |_| try std.testing.expect(try service.pump(scratch) != .idle);
        std.debug.print("cleanup scans: owners={d} productive_pumps={d} scans={d}\n", .{ count, count, trace.scans });
        productive_scan_bound = productive_scan_bound and trace.scans == count;
        for (ids) |id| {
            var task = try service.task(scratch, id);
            defer task.deinit();
            try std.testing.expect(task.value.execution_revision > 0);
        }
        try service.park(scratch);
        trace.scans = 0;
        try std.testing.expectEqual(.idle, try service.pump(scratch));
        try std.testing.expectEqual(count, trace.scans);
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
        .control = .{ .policy = .{}, .schedule = .queued, .blocker = null, .cancellation = null, .cancellation_applied = false, .outcome = .progressed, .instrument = false, .port = false, .delivery = null },
        .observer = .{
            .selection = .{
                .program = try workspaceRef(a, .program, prefixIdentity(20000)),
                .accumulator = try workspaceRef(a, .value, prefixIdentity(20001)),
                .source = .{
                    .expected = .{ .work = try workspaceRef(a, .work, source_id), .execution_revision = 1, .control_revision = 1 },
                    .realization_revision = 0,
                    .nodes = .{ .all = .{} },
                    .level = if (index % 3 == 2) .guest_cut else .outer_execution,
                },
                .policy = .{ .delivery = if (index % 3 == 1) .sampled else .lossless },
                .previous = if (index < 3) null else try workspaceRef(a, .work, prefixIdentity(index - 3)),
            },
            .source = empty,
            .source_work = source_id,
            .source_revision = index / 3,
            .accumulator = empty,
        },
    };
}

fn expectPublicationPrefix(
    prefix: *native.testing.workspace_observers.PublicationPrefix,
    publications: []const native.testing.state.WorkPublication,
    scanned: *usize,
    indexed: *usize,
) !void {
    for (0..4) |source_index| {
        const source_id = prefixIdentity(10000 + source_index);
        var lossless: usize = 0;
        var outer = false;
        for (publications) |item| {
            scanned.* += 1;
            const observer = item.observer orelse continue;
            if (observer.stopped or !std.meta.eql(observer.source_work, source_id)) continue;
            const text = std.fmt.bytesToHex(item.work, .lower);
            const successor = for (publications) |other| {
                scanned.* += 1;
                const following = other.observer orelse continue;
                const previous = following.selection.previous orelse continue;
                if (std.mem.eql(u8, previous.id.bytes, &text)) break true;
            } else false;
            if (successor) continue;
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
            try expectPublicationPrefix(&prefix, publications[0 .. i + 1], &scanned, &indexed);
            item.observer.?.consumed_revision = item.observer.?.source_revision;
            try prefix.put(item.*, i * 2 + 1);
            try expectPublicationPrefix(&prefix, publications[0 .. i + 1], &scanned, &indexed);
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
        try expectPublicationPrefix(&prefix, publications, &scanned, &indexed);
        try std.testing.expect(indexed <= count * 4);
        try std.testing.expect(scanned > count * count);
        std.debug.print("publication prefixes: folds={d} reference_visits={d} active_visits={d}\n", .{ count, scanned, indexed });
        if (count == 10)
            try std.testing.checkAllAllocationFailures(a, allocatePublicationPrefix, .{publications});
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
        try expectPublicationPrefix(&parallel, independent, &scanned, &indexed);
        for (independent[0 .. count - 1], 0..) |*item, i| {
            item.observer.?.stopped = true;
            try parallel.put(item.*, count + i);
        }
        indexed = 0;
        for (0..count) |_| {
            for (parallel.lossless(source_id).?.keys()) |id| {
                try std.testing.expectEqualDeep(independent[count - 1].work, id);
                indexed += 1;
            }
        }
        try std.testing.expectEqual(count, indexed);
        try expectPublicationPrefix(&parallel, independent, &scanned, &indexed);
        std.debug.print("publication prefixes: parallel_peak={d} remaining=1 queried_visits={d}\n", .{ count, indexed - 1 });
    }
}

test "runtime selection switches exact guest cuts and retains carried artifacts through archive import" {
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
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "workspace-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "workspace-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "workspace-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    var semantic_roots: [2]native.testing.state.Digest = .{ @splat(0), @splat(0) };
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(42),
        .bytes = "workspace-test",
        .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" },
        .semantic_construction = .{
            .roots = &semantic_roots,
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
    defer if (namespace_open) namespace.close() catch unreachable;
    var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_open = true;
    defer if (service_open) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });
    var initial = try service.task(a, parent.receipt.task);
    defer initial.deinit();
    phase = "controller runtime selection";
    try exerciseControllerRealization(scratch, &service, parent.receipt.task, root_document);
    phase = "runtime source build";
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    // The request retains its receipt, not the compiler's completed proof
    // arenas. The service allocator still checks every temporary allocation.
    const specialization_request_memory = try a.alloc(u8, 1024 * 1024);
    defer a.free(specialization_request_memory);
    var specialization_request = std.heap.FixedBufferAllocator.init(specialization_request_memory);
    phase = "runtime specialization";
    const specialized = try service.workspaceSpecializeWithHooks(specialization_request.allocator(), "specialize", parent.receipt.task, program.receipt.workspace.?, .{ .control = true, .storage = true });
    var specialized_observation = try contracts.decodeOwned(native.workspace.Runtime, scratch, try namespace.store.object(scratch, specialized.receipt.workspace_observation.?, null));
    defer specialized_observation.deinit();
    try std.testing.expect(specialized_observation.value.validation == null);
    const validation_bytes = try contracts.encodeOwned(?native.workspace.ValidationFact, scratch, null);
    var validation_context: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(validation_bytes, &validation_context, .{});
    const RuntimeFact = @FieldType(@TypeOf(service.checked_workspace_runtimes).KV, "key");
    const runtime_fact: RuntimeFact = .{
        .kind = .runtime,
        .input = specialized_observation.value.artifact,
        .output = @as(native.testing.state.Reference, .{ .digest = @splat(0), .bytes = 0 }),
        .context = validation_context,
    };
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.checked_workspace_runtimes.get(runtime_fact).?);
    try std.testing.expectEqualDeep(specialized.receipt.workspace.?, service.runtime_cache.?.artifact.identity);
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.runtime_cache.?.epoch);
    const duplicate = try service.workspaceSpecializeWithHooks(scratch, "specialize", parent.receipt.task, program.receipt.workspace.?, .{ .control = true, .storage = true });
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualDeep(specialized.receipt.workspace, duplicate.receipt.workspace);
    phase = "runtime alias specialization";
    const alias_document = try std.fmt.allocPrint(scratch, "\n{s}\n", .{document});
    const alias_program = try service.workspaceBuild(scratch, "build-alias", parent.receipt.task, alias_document, &diagnostic);
    try std.testing.expect(!std.meta.eql(program.receipt.workspace.?, alias_program.receipt.workspace.?));
    const alias_specialized = try service.workspaceSpecializeWithHooks(scratch, "specialize-alias", parent.receipt.task, alias_program.receipt.workspace.?, .{ .control = true, .storage = true });
    try std.testing.expectEqualDeep(specialized.receipt.workspace, alias_specialized.receipt.workspace);
    var alias_observation = try contracts.decodeOwned(native.workspace.Runtime, scratch, try namespace.store.object(scratch, alias_specialized.receipt.workspace_observation.?, null));
    defer alias_observation.deinit();
    try std.testing.expectEqualDeep(program.receipt.workspace.?, alias_observation.value.program);
    const alias_command: contracts.workspace.Command = .{ .program = .{ .specialize = .{ .program = try workspaceRef(scratch, .program, alias_program.receipt.workspace.?), .hooks = .{ .control = true, .storage = true } } } };
    const alias_reply = try service.workspaceCommand(scratch, "specialize-alias", parent.receipt.task, alias_command);
    const alias_json = (try native.json.parseAsset(scratch, alias_reply.observation_json.bytes, alias_reply.observation_json.bytes.len)).value;
    try std.testing.expectEqualDeep(program.receipt.workspace.?, try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, scratch, alias_json.object.get("origin_program").?)));
    phase = "runtime alias origin rejection";
    {
        try namespace.store.begin();
        defer namespace.store.rollback();
        var false_origin = alias_observation.value;
        false_origin.program = alias_program.receipt.workspace.?;
        var false_receipt = alias_specialized.receipt;
        false_receipt.workspace_observation = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.Runtime, scratch, false_origin));
        const false_body = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, false_receipt));
        try namespace.store.database.run("UPDATE operations SET receipt=? WHERE request=? AND task=?", &.{ .{ .blob = &false_body.digest }, .{ .blob = &false_receipt.request_digest }, .{ .blob = &false_receipt.task } });
        try std.testing.expectError(error.InvalidRuntime, service.workspaceCommand(scratch, "specialize-alias", parent.receipt.task, alias_command));
    }
    phase = "runtime cache invalidation";
    var previous_runtime = try service.runtime_cache.?.artifact.clone();
    defer previous_runtime.deinit();
    const previous_epoch = namespace.store.integrity_epoch;
    namespace.store.invalidateIntegrity();
    try std.testing.expectEqual(previous_epoch, service.runtime_cache.?.epoch);
    try std.testing.expectEqual(previous_epoch + 1, namespace.store.integrity_epoch);
    const runtime = try workspaceRef(scratch, .runtime, specialized.receipt.workspace.?);
    semantic_roots[0] = kosmos.RuntimeCompiler.approvedRootIdentity(&previous_runtime);
    var generic_runtime = try service.program.retainRuntime();
    defer generic_runtime.deinit();
    semantic_roots[1] = kosmos.RuntimeCompiler.approvedRootIdentity(&generic_runtime);
    const input = try scratch.alloc(u8, 300 * 9 + 1);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const shared_program = try semanticGuestProgram(scratch, &service, parent.receipt.task, "semantic-guest-build");
    const shared_input = try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, scratch, .{ .yields = 300, .seed = 100 });
    try semanticGuestExecution(scratch, &service, parent.receipt.task, shared_program);
    phase = "guarded reply divergence and cleanup";
    try exerciseGuardReply(scratch, &service, parent.receipt.task);
    phase = "selected runtime realization";
    const started = try service.workspaceStart(scratch, "start", parent.receipt.task, alias_program.receipt.workspace.?, input, .{});
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(a, parent.receipt.task, id);
    defer before.deinit();
    try std.testing.expectEqualDeep(alias_program.receipt.workspace.?, before.value.program);
    try std.testing.expect(!before.value.terminal());
    const expected: contracts.workspace.Expected = .{ .work = try workspaceRef(scratch, .work, id), .execution_revision = before.value.execution_revision, .control_revision = before.value.control_revision };
    const selection: @FieldType(contracts.workspace.Work, "realize") = .{ .expected = expected, .realization_revision = 0, .runtime = .{ .selected = runtime } };
    const allowed_policy = service.profile.semantic_construction;
    service.profile.semantic_construction = null;
    try std.testing.expectError(error.SemanticPolicyDenied, service.workspaceRealize(scratch, "denied-select", parent.receipt.task, selection));
    const denied_start = try service.workspaceCommand(scratch, "denied-runtime-start", parent.receipt.task, .{ .work = .{ .start = .{
        .program = try workspaceRef(scratch, .program, alias_program.receipt.workspace.?),
        .input = .{ .reference = try workspaceRef(scratch, .value, before.value.input_value.?.digest) },
        .policy = .{},
        .runtime = .{ .selected = runtime },
    } } });
    try std.testing.expectEqual(.rejected, denied_start.disposition);
    try std.testing.expect(std.mem.indexOf(u8, denied_start.observation_json.bytes, "SemanticPolicyDenied") != null);
    service.profile.semantic_construction = allowed_policy;
    {
        var request_arena = std.heap.ArenaAllocator.init(a);
        defer request_arena.deinit();
        var commit_guard: AfterCommitAllocator = .{ .backing = request_arena.allocator(), .namespace = &namespace, .generation = namespace.store.head.generation };
        _ = try service.workspaceRealize(commit_guard.allocator(), "select", parent.receipt.task, selection);
        try std.testing.expectEqual(@as(usize, 0), commit_guard.rejected);
    }
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.checked_workspace_runtimes.get(runtime_fact).?);
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.runtime_cache.?.epoch);
    try std.testing.expect(previous_runtime.core != service.runtime_cache.?.artifact.core);
    const replay = try service.workspaceRealize(scratch, "select", parent.receipt.task, selection);
    try std.testing.expect(replay.replayed);
    try std.testing.expectError(error.StaleRevision, service.workspaceRealize(scratch, "stale-select", parent.receipt.task, selection));
    var selected = try service.workspaceWork(a, parent.receipt.task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(before.value.checkpoint, selected.value.checkpoint);
    try std.testing.expectEqual(before.value.execution_revision, selected.value.execution_revision);
    try std.testing.expectEqual(@as(u64, 1), selected.value.realization_revision);
    try std.testing.expect(selected.value.runtime != null and selected.value.runtime_capsule != null);
    const selected_pump: @FieldType(contracts.workspace.Work, "pump") = .{
        .expected = .{ .work = expected.work, .execution_revision = selected.value.execution_revision, .control_revision = selected.value.control_revision },
        .base_quantum = 1,
    };
    service.profile.semantic_construction = null;
    try std.testing.expectError(error.SemanticPolicyDenied, service.workspacePump(scratch, "denied-active-pump", parent.receipt.task, selected_pump));
    try std.testing.expect((try service.workspaceRealize(scratch, "select", parent.receipt.task, selection)).replayed);
    try service.park(scratch);
    var policy_parked_parent = try service.task(scratch, parent.receipt.task);
    defer policy_parked_parent.deinit();
    _ = try service.resumeTask(scratch, "selected-policy-resume", parent.receipt.task, policy_parked_parent.value.revision);
    try std.testing.expectError(error.SemanticPolicyDenied, service.workspacePump(scratch, "denied-restored-pump", parent.receipt.task, selected_pump));
    var denied_work = try service.workspaceWork(scratch, parent.receipt.task, id);
    defer denied_work.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, denied_work.value.checkpoint);
    try std.testing.expectEqual(selected.value.execution_revision, denied_work.value.execution_revision);
    service.profile.semantic_construction = allowed_policy;
    {
        var different_builder = source.Builder.init(a);
        defer different_builder.deinit();
        const different_document = try native.source_records.encode(scratch, try @import("workspace_sources.zig").listLengthWithYields(&different_builder, false));
        const different = try service.workspaceBuild(scratch, "build-different-image", parent.receipt.task, different_document, &diagnostic);
        const denied = try service.workspaceCommand(scratch, "mismatched-runtime", parent.receipt.task, .{ .work = .{ .start = .{
            .program = try workspaceRef(scratch, .program, different.receipt.workspace.?),
            .input = .{ .reference = try workspaceRef(scratch, .value, before.value.input_value.?.digest) },
            .policy = .{},
            .runtime = .{ .selected = runtime },
        } } });
        try std.testing.expectEqual(.rejected, denied.disposition);
    }
    phase = "guest view materialization";
    const view_command: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .guest_view = .{ .expected = .{ .work = expected.work, .execution_revision = selected.value.execution_revision, .control_revision = selected.value.control_revision }, .realization_revision = selected.value.realization_revision, .nodes = .{ .all = .{} } } },
        .sources = .{ .items = &.{} },
    } } };
    const viewed = try service.workspaceCommand(scratch, "guest-view", parent.receipt.task, view_command);
    if (viewed.disposition != .observed) std.debug.print("guest view: {s}\n", .{viewed.observation_json.bytes});
    try std.testing.expectEqual(.observed, viewed.disposition);
    const view_ref = viewed.evidence.?;
    const viewed_json = (try native.json.parseAsset(scratch, viewed.observation_json.bytes, viewed.observation_json.bytes.len)).value;
    try std.testing.expectEqualStrings("inspection", viewed_json.object.get("derivation").?.object.get("kind").?.string);
    const again = try service.workspaceCommand(scratch, "guest-view", parent.receipt.task, view_command);
    try std.testing.expectEqualDeep(view_ref, again.evidence.?);
    const view_id = try nativeIdentity(view_ref);
    var view_record = try contracts.decodeOwned(native.workspace.Value, a, (try namespace.store.recordBytes(scratch, "workspace_value", try native.workspace.custodyId(scratch, parent.receipt.task, view_id), parent.receipt.task)).?);
    defer view_record.deinit();
    const view_bytes = try namespace.store.object(scratch, view_record.value.description.value, null);
    const view_schema = try namespace.store.object(scratch, view_record.value.description.schema, null);
    var view_data = try native.dynamic_values.decode(a, view_schema, view_bytes);
    defer view_data.deinit();
    try std.testing.expect(view_data.value.array.items[1].bool);
    try std.testing.expect(view_data.value.array.items[2].array.items.len != 0);
    try disclosedViewWitness(&service, scratch, parent.receipt.task, view_command);
    for (0..3) |attack| {
        // Rehashing a plausible snapshot does not create a journal publication.
        // Keep all ordinary content references valid while changing its revision.
        try namespace.store.begin();
        defer namespace.store.rollback();
        var forged = view_record.value;
        const frozen = &forged.derivation.inspection.?.observation.work;
        switch (attack) {
            0 => frozen.execution_revision += 1,
            1 => frozen.outer_cursor.revision += 1,
            2 => frozen.outer_cursor.last = frozen.input.digest,
            else => unreachable,
        }
        forged.description.provenance = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.Derivation, scratch, forged.derivation));
        forged.artifact = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, scratch, forged.description));
        forged.id = try native.workspace.custodyId(scratch, parent.receipt.task, forged.artifact.digest);
        try namespace.store.createRecord(native.workspace.Value, "workspace_value", forged.id, parent.receipt.task, forged);
        const rejected = try service.workspaceCommand(scratch, "forged-view", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = try workspaceRef(scratch, .value, forged.artifact.digest), .page = .{} } } });
        try std.testing.expectEqual(.rejected, rejected.disposition);
    }
    {
        var partial = view_command;
        partial.context.materialize.input.guest_view.nodes = .{ .selected = .{ .items = &.{} } };
        const response = try service.workspaceCommand(scratch, "partial-view", parent.receipt.task, partial);
        try std.testing.expectEqual(.observed, response.disposition);
        const ref_id = try nativeIdentity(response.evidence.?);
        var value = try contracts.decodeOwned(native.workspace.Value, a, (try namespace.store.recordBytes(scratch, "workspace_value", try native.workspace.custodyId(scratch, parent.receipt.task, ref_id), parent.receipt.task)).?);
        defer value.deinit();
        var partial_data = try native.dynamic_values.decode(a, view_schema, try namespace.store.object(scratch, value.value.description.value, null));
        defer partial_data.deinit();
        try std.testing.expect(!partial_data.value.array.items[1].bool);
        try std.testing.expectEqual(@as(usize, 0), partial_data.value.array.items[2].array.items.len);
        try expectContextOutputBound(&service, scratch, parent.receipt.task, "guest-view", response.evidence.?, null);
        partial.context.materialize.input.guest_view.realization_revision = 0;
        const stale_view = try service.workspaceCommand(scratch, "stale-view", parent.receipt.task, partial);
        try std.testing.expectEqual(.rejected, stale_view.disposition);
        const other_parent = try service.submit(scratch, "other-view-task", .{ 25, 5 });
        const denied = try service.workspaceCommand(scratch, "foreign-view", other_parent.receipt.task, view_command);
        try std.testing.expectEqual(.rejected, denied.disposition);
        const other_program = try service.workspaceBuild(scratch, "other-build", other_parent.receipt.task, document, &diagnostic);
        const other_start = try service.workspaceStart(scratch, "other-start", other_parent.receipt.task, other_program.receipt.workspace.?, input, .{});
        var other_work = try service.workspaceWork(scratch, other_parent.receipt.task, other_start.receipt.workspace.?);
        defer other_work.deinit();
        const foreign_runtime = try service.workspaceCommand(scratch, "foreign-runtime", other_parent.receipt.task, .{ .work = .{ .realize = .{
            .expected = .{ .work = try workspaceRef(scratch, .work, other_work.value.id), .execution_revision = other_work.value.execution_revision, .control_revision = other_work.value.control_revision },
            .realization_revision = other_work.value.realization_revision,
            .runtime = .{ .selected = runtime },
        } } });
        try std.testing.expectEqual(.rejected, foreign_runtime.disposition);
    }
    {
        // Feed the acquired view to an ordinary generated query. The input
        // materialization preserves its inspection ancestry through the result.
        phase = "retention query build";
        const query_source = try native.program_construction.runtimeQuery(scratch, true);
        const query = try service.workspaceBuild(scratch, "retention-query", parent.receipt.task, query_source, &diagnostic);
        const query_id = query.receipt.workspace.?;
        var query_program = try contracts.decodeOwned(native.workspace.Program, a, (try namespace.store.recordBytes(scratch, "workspace_program", try native.workspace.custodyId(scratch, parent.receipt.task, query_id), parent.receipt.task)).?);
        defer query_program.deinit();
        var input_json: native.json.Value = .{ .array = .init(scratch) };
        try input_json.array.append(view_data.value);
        try input_json.array.append(view_data.value.array.items[3].array.items[0].array.items[0]);
        const query_input = try service.workspaceCommand(scratch, "retention-input", parent.receipt.task, .{ .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, query_program.value.description.input_schema.digest), .json_text = .{ .bytes = try native.json.canonical(scratch, input_json) } } } },
            .sources = .{ .items = &.{view_ref} },
        } } });
        try std.testing.expectEqual(.observed, query_input.disposition);
        const query_start = try service.workspaceCommand(scratch, "run-retention", parent.receipt.task, .{ .work = .{ .start = .{ .program = try workspaceRef(scratch, .program, query_id), .input = .{ .reference = query_input.evidence.? }, .policy = .{} } } });
        try std.testing.expectEqual(.observed, query_start.disposition);
        const started_json = (try native.json.parseAsset(scratch, query_start.observation_json.bytes, query_start.observation_json.bytes.len)).value;
        const query_work_id = try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, scratch, started_json.object.get("work").?));
        var turn: usize = 0;
        while (true) : (turn += 1) {
            var current = try service.workspaceWork(a, parent.receipt.task, query_work_id);
            defer current.deinit();
            if (current.value.terminal()) {
                try std.testing.expectEqual(.completed, current.value.outcome_kind);
                var result = try native.dynamic_values.decode(a, try namespace.store.object(scratch, query_program.value.description.result_schema, null), try namespace.store.object(scratch, current.value.result.?, null));
                defer result.deinit();
                try std.testing.expectEqual(@as(u32, 0), try native.values.fromJson(u32, scratch, result.value.array.items[1]));
                try std.testing.expectEqualDeep(query_input.evidence.?, try workspaceRef(scratch, .value, current.value.input_value.?.digest));
                break;
            }
            try std.testing.expect(turn < 200);
            _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "query-turn-{d}", .{turn}), parent.receipt.task, query_work_id, current.value.execution_revision, current.value.control_revision, .advance);
        }
    }
    phase = "traced runtime selection";
    var after_view = try service.workspaceWork(a, parent.receipt.task, id);
    defer after_view.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, after_view.value.checkpoint);
    try std.testing.expectEqual(selected.value.execution_revision, after_view.value.execution_revision);
    try std.testing.expectEqual(selected.value.control_revision, after_view.value.control_revision);
    var traced_id: [32]u8 = undefined;
    {
        var request_arena = std.heap.ArenaAllocator.init(a);
        defer request_arena.deinit();
        const selected_start = try service.workspaceCommand(request_arena.allocator(), "selected-start", parent.receipt.task, .{ .work = .{ .start = .{
            .program = try workspaceRef(scratch, .program, alias_program.receipt.workspace.?),
            .input = .{ .reference = try workspaceRef(scratch, .value, before.value.input_value.?.digest) },
            .policy = .{},
            .runtime = .{ .selected = runtime },
        } } });
        try std.testing.expectEqual(.observed, selected_start.disposition);
        const traced_json = (try native.json.parseAsset(scratch, selected_start.observation_json.bytes, selected_start.observation_json.bytes.len)).value;
        traced_id = try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, scratch, traced_json.object.get("work").?));
        var traced = try service.workspaceWork(a, parent.receipt.task, traced_id);
        defer traced.deinit();
        try std.testing.expect(traced.value.runtime_trace != null);
        try std.testing.expect(traced.value.runtime_trace.?.output.trace.control != null);
        try std.testing.expect(traced.value.runtime_trace.?.output.trace.storage.?.node_slots > 0);
        try std.testing.expectEqualDeep(before.value.checkpoint, traced.value.checkpoint);
    }
    {
        // Rehash the false trace and its retained publication/receipt. The
        // independent observer must still reject the invented storage count.
        var manifest_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
        const archive_index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
        var compiler_facts = try service.prepareWorkspaceValidation(parent.receipt.task);
        defer compiler_facts.deinit();
        try namespace.store.begin();
        defer namespace.store.rollback();
        var traced = try service.workspaceWork(a, parent.receipt.task, traced_id);
        defer traced.deinit();
        traced.value.runtime_trace.?.output.trace.storage.?.node_slots += 1;
        try namespace.store.putRecord(native.workspace.Work, "workspace_work", traced_id, parent.receipt.task, traced.value);
        const observation_bytes = try contracts.encodeOwned(native.workspace.WorkObservation, scratch, .{ .work = traced.value, .occurrence = null });
        const changed_observation = try namespace.store.putObject(observation_bytes);
        var query = try namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &parent.receipt.task }, .{ .integer = @intCast(traced.value.event_watermark) } });
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        var retained = try contracts.decodeOwned(native.testing.state.Event, scratch, try query.bytes(0));
        const publications = try scratch.dupe(native.testing.state.WorkPublication, retained.value.workspace_publications.items);
        retained.value.workspace_publications.items = publications;
        for (publications) |*publication| if (std.meta.eql(publication.work, traced_id)) {
            publication.observation = changed_observation.digest;
        };
        const changed_event = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, retained.value));
        try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &changed_event.digest }, .{ .blob = &parent.receipt.task }, .{ .integer = @intCast(traced.value.event_watermark) } });
        var receipts = try namespace.store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &parent.receipt.task }});
        defer receipts.deinit();
        while (try receipts.step() == .row) {
            var receipt = try contracts.decodeOwned(native.testing.state.Receipt, scratch, try receipts.bytes(1));
            if (receipt.value.workspace_kind != .work or !std.meta.eql(receipt.value.workspace, @as(?[32]u8, traced_id))) continue;
            receipt.value.workspace_observation = changed_observation;
            const changed_receipt = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, receipt.value));
            try namespace.store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &changed_receipt.digest }, .{ .text = try receipts.bytes(0) } });
        }
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(scratch, parent.receipt.task, archive_index.records.items, &compiler_facts));
    }
    phase = "outer cut suspension";
    var trace_before_pump = try service.workspaceWork(a, parent.receipt.task, traced_id);
    defer trace_before_pump.deinit();
    const pump_command: @FieldType(contracts.workspace.Work, "pump") = .{
        .expected = .{ .work = try workspaceRef(scratch, .work, traced_id), .execution_revision = trace_before_pump.value.execution_revision, .control_revision = trace_before_pump.value.control_revision },
        .base_quantum = 1,
    };
    _ = try service.workspacePump(scratch, "begin-bounded", parent.receipt.task, pump_command);
    try std.testing.expect((try service.workspacePump(scratch, "begin-bounded", parent.receipt.task, pump_command)).replayed);
    var suspended = try service.workspaceWork(a, parent.receipt.task, traced_id);
    defer suspended.deinit();
    try std.testing.expect(suspended.value.outer_operation != null);
    const suspended_observation = try service.workspaceCommand(scratch, "inspect-bounded", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = pump_command.expected.work } } });
    const suspended_json = try native.json.parseAsset(scratch, suspended_observation.observation_json.bytes, suspended_observation.observation_json.bytes.len);
    try std.testing.expectEqualStrings("outer_execution", suspended_json.value.object.get("available_cut").?.string);
    try std.testing.expectEqual(trace_before_pump.value.execution_revision, suspended.value.execution_revision);
    try std.testing.expectEqualDeep(trace_before_pump.value.checkpoint, suspended.value.checkpoint);
    const suspended_expected: contracts.workspace.Expected = .{ .work = pump_command.expected.work, .execution_revision = suspended.value.execution_revision, .control_revision = suspended.value.control_revision };
    try std.testing.expectError(error.GuestCutUnavailable, service.workspaceRequestCut(scratch, "premature-guest-cut", parent.receipt.task, .{ .expected = suspended_expected, .level = .guest_cut }));
    try std.testing.expectError(error.GuestCutUnavailable, service.workspaceRealize(scratch, "premature-switch", parent.receipt.task, .{ .expected = suspended_expected, .realization_revision = suspended.value.realization_revision, .runtime = .{ .packaged = .{} } }));
    try outerViewWitness(&service, scratch, parent.receipt.task, suspended.value);
    _ = try service.workspaceRequestCut(scratch, "pending-outer-cut", parent.receipt.task, .{ .expected = suspended_expected, .level = .outer_execution });
    const original_outer_bytes = try namespace.store.object(scratch, suspended.value.outer_operation.?.capsule, null);
    var original_outer = try kosmos.RuntimeCapsule.read(a, original_outer_bytes);
    defer original_outer.deinit();
    try std.testing.expectEqual(.advance, original_outer.value.record.operation.?);
    for ([_]@FieldType(@FieldType(contracts.workspace.Work, "request_cut"), "level"){ .guest_cut, .outer_execution }, 0..) |level, i| {
        var current = try service.workspaceWork(a, parent.receipt.task, id);
        defer current.deinit();
        _ = try service.workspaceRequestCut(scratch, if (i == 0) "guest-cut" else "outer-cut", parent.receipt.task, .{
            .expected = .{ .work = expected.work, .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
            .level = level,
        });
    }
    phase = "observer multiple cuts";
    const observer = try observerWitness(&service, scratch, parent.receipt.task, shared_program, shared_input);
    phase = "retention observer";
    try retentionObserverWitness(&service, scratch, parent.receipt.task, observer.selection);
    phase = "archive export";
    const archive_path = try std.fmt.allocPrint(scratch, "{s}/runtime.par", .{path_buffer[0..length]});
    _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
    try service.close(a);
    service_open = false;
    try namespace.close();
    namespace_open = false;
    const import_path = try std.fmt.allocPrint(scratch, "{s}/import", .{path_buffer[0..length]});
    var imported_namespace = try native.Namespace.open(a, io, import_path);
    defer imported_namespace.close() catch unreachable;
    var imported = try native.tasks.Service(OwnerTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
    defer imported.close(a) catch unreachable;
    phase = "archive import";
    _ = try imported.importCheckpoint(scratch, "import", archive_path);
    var restored_trace = try imported.workspaceWork(a, parent.receipt.task, traced_id);
    defer restored_trace.deinit();
    try std.testing.expect(restored_trace.value.runtime_trace != null);
    try std.testing.expect(restored_trace.value.outer_operation != null);
    try std.testing.expectEqualDeep(suspended.value.outer_operation.?.capsule, restored_trace.value.outer_operation.?.capsule);
    try std.testing.expectError(error.CustodyNotLocal, imported.workspacePump(scratch, "copy-cannot-pump", parent.receipt.task, .{ .expected = .{ .work = pump_command.expected.work, .execution_revision = restored_trace.value.execution_revision, .control_revision = restored_trace.value.control_revision }, .base_quantum = 1 }));
    try imported.close(a);
    {
        _ = try imported_namespace.store.auditRetention(handlers, application.image_identity);
        var rows = try imported_namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq", &.{.{ .blob = &parent.receipt.task }});
        defer rows.deinit();
        var source_capsule: ?native.testing.state.Reference = null;
        while (try rows.step() == .row) {
            var event = try contracts.decodeOwned(native.testing.state.Event, scratch, try rows.bytes(0));
            defer event.deinit();
            const command_ref = event.value.workspace_command orelse continue;
            var command = try contracts.decodeOwned(native.workspace.PublicationCommand, scratch, try imported_namespace.store.object(scratch, command_ref, null));
            defer command.deinit();
            if (command.value == .realize) {
                source_capsule = command.value.realize.source;
                break;
            }
        }
        const removed = source_capsule orelse return error.TestUnexpectedResult;
        try imported_namespace.store.database.run("DELETE FROM dependencies WHERE child=? OR parent=?", &.{ .{ .blob = &removed.digest }, .{ .blob = &removed.digest } });
        try imported_namespace.store.database.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &removed.digest }});
        imported_namespace.store.invalidateIntegrity();
        try std.testing.expectError(error.CorruptState, imported_namespace.store.auditRetention(handlers, application.image_identity));
    }
    try imported_namespace.close();
    imported_namespace = try native.Namespace.open(a, io, path);
    imported = try native.tasks.Service(OwnerTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
    phase = "observer replay after reopen";
    const observer_replay = try imported.workspaceObserve(scratch, "observe-second", parent.receipt.task, observer.selection);
    try std.testing.expect(observer_replay.replayed);
    try std.testing.expectEqualDeep(observer.receipt, observer_replay.receipt.id);
    var observer_work = try imported.workspaceWork(scratch, parent.receipt.task, observer.work);
    defer observer_work.deinit();
    _ = try imported.workspaceStopObserving(scratch, "observer-stop", parent.receipt.task, .{
        .work = try workspaceRef(scratch, .work, observer.work),
        .execution_revision = observer_work.value.execution_revision,
        .control_revision = observer_work.value.control_revision,
    });
    _ = try imported.workspacePump(scratch, "resume-outer-one", parent.receipt.task, .{ .expected = .{ .work = pump_command.expected.work, .execution_revision = restored_trace.value.execution_revision, .control_revision = restored_trace.value.control_revision }, .base_quantum = 1 });
    var continued = try imported.workspaceWork(a, parent.receipt.task, traced_id);
    defer continued.deinit();
    try std.testing.expect(continued.value.outer_operation != null);
    var continued_outer = try kosmos.RuntimeCapsule.read(a, try imported_namespace.store.object(scratch, continued.value.outer_operation.?.capsule, null));
    defer continued_outer.deinit();
    try std.testing.expect(continued_outer.value.record.outer_revision > original_outer.value.record.outer_revision);
    try std.testing.expectEqual(original_outer.value.record.guest_revision, continued_outer.value.record.guest_revision);
    try std.testing.expectEqualSlices(u8, original_outer.value.command, continued_outer.value.command);
    var pump_turn: usize = 0;
    while (true) : (pump_turn += 1) {
        var current = try imported.workspaceWork(a, parent.receipt.task, traced_id);
        defer current.deinit();
        if (current.value.outer_operation == null) {
            try std.testing.expectEqual(restored_trace.value.execution_revision + 1, current.value.execution_revision);
            break;
        }
        try std.testing.expect(pump_turn < 100);
        _ = try imported.workspacePump(scratch, try std.fmt.allocPrint(scratch, "finish-outer-{d}", .{pump_turn}), parent.receipt.task, .{ .expected = .{ .work = pump_command.expected.work, .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision }, .base_quantum = 1048576 });
    }

    const imported_view = try imported.workspaceCommand(scratch, "read-imported-view", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = view_ref, .page = .{} } } });
    try std.testing.expectEqual(.observed, imported_view.disposition);
    var restored = try imported.workspaceWork(a, parent.receipt.task, id);
    defer restored.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, restored.value.checkpoint);
    try std.testing.expectEqualDeep(selected.value.runtime, restored.value.runtime);
    _ = try imported.workspaceRealize(scratch, "return-generic", parent.receipt.task, .{
        .expected = .{ .work = expected.work, .execution_revision = restored.value.execution_revision, .control_revision = restored.value.control_revision },
        .realization_revision = restored.value.realization_revision,
        .runtime = .{ .packaged = .{} },
    });
    var generic = try imported.workspaceWork(a, parent.receipt.task, id);
    defer generic.deinit();
    try std.testing.expectEqualDeep(before.value.checkpoint, generic.value.checkpoint);
    try std.testing.expectEqual(@as(u64, 2), generic.value.realization_revision);
    try std.testing.expect(generic.value.runtime == null);
    _ = try imported.workspaceControl(scratch, "advance-generic", parent.receipt.task, id, generic.value.execution_revision, generic.value.control_revision, .advance);
    phase = "build yielding input request";
    var question_builder = source.Builder.init(a);
    defer question_builder.deinit();
    const question_module = try @import("workspace_sources.zig").binaryQuestion(&question_builder);
    question_builder.functions.items[@intCast(question_module.entry)].body = try question_builder.term(.{ .yield_then = question_builder.functions.items[@intCast(question_module.entry)].body.? });
    const question_document = try native.source_records.encode(scratch, question_builder.module(question_module.entry, question_module.failure));
    const question_program = try imported.workspaceCommand(scratch, "pending-cancel-program", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = question_document } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .input }} } } } });
    try std.testing.expectEqual(.observed, question_program.disposition);
    phase = "start yielding input request";
    const question_started = try imported.workspaceStart(scratch, "pending-cancel-start", parent.receipt.task, try nativeIdentity(question_program.program.?), &.{}, .{});
    const question_id = question_started.receipt.workspace.?;
    const question_ref = try workspaceRef(scratch, .work, question_id);
    var yielded_question = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
    defer yielded_question.deinit();
    try std.testing.expectEqual(.yielded, yielded_question.value.outcome_kind);
    phase = "suspend input request advance";
    _ = try imported.workspacePump(scratch, "pending-cancel-begin", parent.receipt.task, .{ .expected = .{ .work = question_ref, .execution_revision = yielded_question.value.execution_revision, .control_revision = yielded_question.value.control_revision }, .base_quantum = 1 });
    var pending_question = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
    defer pending_question.deinit();
    try std.testing.expect(pending_question.value.outer_operation != null);
    phase = "cancel suspended input request advance";
    _ = try imported.workspaceControl(scratch, "pending-cancel-request", parent.receipt.task, question_id, pending_question.value.execution_revision, pending_question.value.control_revision, .{ .cancel = .{ .bytes = "stop before question" } });
    var question_cancelled = false;
    var saw_pending_question = false;
    phase = "apply pending cancellation at the requested cut";
    for (0..512) |_| {
        var current = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            question_cancelled = true;
            break;
        }
        if (current.value.outcome_kind == .requested and !current.value.cancellation_applied) {
            saw_pending_question = true;
            try std.testing.expect(current.value.current_port != null);
            try std.testing.expectEqual(.queued, current.value.schedule);
            _ = try imported.workspaceControl(scratch, "pending-cancel-explicit", parent.receipt.task, question_id, current.value.execution_revision, current.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .explicit_only } });
            var explicit = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
            defer explicit.deinit();
            try std.testing.expectEqual(.parked, explicit.value.schedule);
            _ = try imported.workspaceControl(scratch, "pending-cancel-owner", parent.receipt.task, question_id, explicit.value.execution_revision, explicit.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } });
            var delegated = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
            defer delegated.deinit();
            try std.testing.expectEqual(.queued, delegated.value.schedule);
            try std.testing.expectEqualDeep(current.value.current_port, delegated.value.current_port);
            try imported.validateWorkspace(scratch, parent.receipt.task);
        }
        _ = try imported.pump(scratch);
    }
    try std.testing.expect(saw_pending_question and question_cancelled);
    phase = "resume retained observer scheduling";
    try std.testing.expectEqual(
        null,
        try observerSuccessor(&imported, scratch, parent.receipt.task, observer.scheduled.previous),
    );
    var parked_parent = try imported.task(scratch, parent.receipt.task);
    defer parked_parent.deinit();
    {
        var statement = try imported_namespace.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace));
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
    try scheduledObserverWitness(&imported, scratch, parent.receipt.task, observer.scheduled);
    phase = "export completed cancellation history";
    const completed_archive = try std.fmt.allocPrint(
        scratch,
        "{s}/pending-cancellation.par",
        .{path_buffer[0..length]},
    );
    _ = try imported.exportCheckpoint(scratch, parent.receipt.task, completed_archive);
    try observerArchiveRoundTrip(
        &imported,
        scratch,
        parent.receipt.task,
        observer.scheduled.previous,
        completed_archive,
        path,
        try std.fmt.allocPrint(scratch, "{s}/completed-observer-copy", .{path_buffer[0..length]}),
    );
    try cancelObserverTaskWitness(&imported, scratch, parent.receipt.task);
    {
        var statement = try imported_namespace.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace));
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        try std.testing.expect(try imported.associatedWorkDisposed(scratch, parent.receipt.task));
        std.debug.print("observer inventory scans: disposal={d}\n", .{trace.scans});
        try std.testing.expectEqual(@as(usize, 1), trace.scans);
    }
    try observerArchiveWitness(&imported, scratch, document, input);
}

test "native placement carries a suspended evaluator with exclusive per-work custody" {
    try placementCase(.work);
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

fn pendingCleanup(service: anytype, a: std.mem.Allocator, task_id: native.testing.state.TaskId) !?native.placement.Signed(native.placement.Control) {
    const p = native.placement;
    var query = try service.namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &task_id }});
    defer query.deinit();
    while (try query.step() == .row) {
        const saved = try contracts.decodeOwned(p.ControlRecord, a, try query.bytes(0));
        if (saved.value.report == null and std.mem.startsWith(u8, saved.value.control.value.operation.bytes, "cleanup-")) return saved.value.control;
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
    const text = try native.source_records.encode(a, try @import("workspace_sources.zig").cutObserver(&builder, false));
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(a, "placement-observer-program", task, text, &diagnostic);
    const observed = try service.workspaceObserve(a, if (scheduled) "placement-observer-scheduled" else "placement-observer-explicit", task, .{
        .program = try workspaceRef(a, .program, built.receipt.workspace.?),
        .source = .{ .expected = .{
            .work = try workspaceRef(a, .work, source_id),
            .execution_revision = source_work.value.execution_revision,
            .control_revision = source_work.value.control_revision,
        }, .realization_revision = source_work.value.realization_revision, .nodes = .{ .all = .{} } },
        .accumulator = try observerAccumulator(service, a, task, program),
        .policy = .{ .delivery = .lossless, .granularity = .one_guest_step, .continuation = if (scheduled) .owner_scheduled else .explicit_only },
    });
    try observerCompleted(service, a, task, observed.receipt.workspace.?);
    var complete = try service.workspaceWork(a, task, observed.receipt.workspace.?);
    defer complete.deinit();
    return .{ .work = try workspaceRef(a, .work, complete.value.id), .execution_revision = complete.value.execution_revision, .control_revision = complete.value.control_revision };
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

fn placementCase(comptime scenario: enum { work, queued, root, preoffer, onward, cancel_abort, cancel_refused, root_cancel_abort, root_cancel_refused, local_ack, remote_ack }) !void {
    const placement_started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    var phase: []const u8 = "setup";
    var attack_index: usize = 0;
    errdefer std.debug.print("placement {s}: {s} ({d})\n", .{ @tagName(scenario), phase, attack_index });
    var meter: kosmos.AllocationBudget = .{ .parent = std.testing.allocator, .limit = std.math.maxInt(usize) };
    var traced: AllocationFailureTrace = .{ .backing = meter.parent, .meter = &meter };
    meter.parent = traced.allocator();
    errdefer std.debug.print("placement allocation: peak={d} required={d} budget_failed={}\n", .{ meter.peak, meter.required, meter.failed });
    const a = if (scenario == .work) meter.allocator() else std.testing.allocator;
    const io = std.testing.io;
    const p = native.placement;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    const root_module = try gcd(&root_builder);
    const root_body = root_builder.functions.items[@intCast(root_module.entry)].body.?;
    root_builder.functions.items[@intCast(root_module.entry)].body = try root_builder.term(.{ .yield_then = try root_builder.term(.{ .yield_then = root_body }) });
    if (scenario == .work) {
        var unpack = root_builder.terms.items[@intCast(root_body)].unpack_product;
        const number = try root_builder.scalar(u64);
        var delayed = try root_builder.reference(unpack.variables[0]);
        for (0..256) |_| delayed = try root_builder.primitive(number, .integer_bit_xor, &.{ delayed, try root_builder.constant(u64, 1) }, 0);
        unpack.body = try root_builder.bind(try root_builder.variable(number), try root_builder.pure(delayed), try root_builder.term(.{ .yield_then = try root_builder.term(.{ .yield_then = unpack.body }) }));
        root_builder.functions.items[@intCast(root_module.entry)].body = try root_builder.term(.{ .unpack_product = unpack });
    }
    var root = try compile(a, &root_builder, root_builder.module(root_module.entry, root_module.failure));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "placement-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "placement-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "placement-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    var profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "placement-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.setPermissions(io, .fromMode(0o700));
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_path = try std.fmt.allocPrint(scratch, "{s}/source", .{path_buffer[0..length]});
    const destination_path = try std.fmt.allocPrint(scratch, "{s}/destination", .{path_buffer[0..length]});
    const successor_path = try std.fmt.allocPrint(scratch, "{s}/successor", .{path_buffer[0..length]});
    var untrusted_namespaces: [3]@FieldType(p.Site, "namespace") = undefined;
    if (scenario == .onward) for (&untrusted_namespaces, 0..) |*identity, attack| {
        var empty = try native.Namespace.open(a, io, try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}", .{ path_buffer[0..length], attack }));
        identity.* = empty.identity;
        try empty.close();
    };
    var successor_namespace = try native.Namespace.open(a, io, successor_path);
    const successor_identity = successor_namespace.identity;
    try successor_namespace.close();
    var destination_namespace = try native.Namespace.open(a, io, destination_path);
    const destination_identity = destination_namespace.identity;
    try destination_namespace.close();
    var destination_open = false;
    defer if (destination_open) destination_namespace.close() catch unreachable;
    var source_namespace = try native.Namespace.open(a, io, source_path);
    var source_open = true;
    defer if (source_open) source_namespace.close() catch unreachable;
    var sender_compiler_facts: native.tasks.Service(OwnerTypes).CompilerFacts = .{ .allocator = a };
    defer sender_compiler_facts.deinit();
    var receiver_compiler_facts: native.tasks.Service(OwnerTypes).CompilerFacts = .{ .allocator = a };
    defer receiver_compiler_facts.deinit();
    var controller_compiler_facts: native.tasks.Service(OwnerTypes).CompilerFacts = .{ .allocator = a };
    defer controller_compiler_facts.deinit();
    var sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, profile);
    var sender_open = true;
    defer if (sender_open) sender.close(a) catch unreachable;
    var receiver: native.tasks.Service(OwnerTypes) = undefined;
    var receiver_open = false;
    defer if (receiver_open) receiver.close(a) catch unreachable;
    const parent = try sender.submit(scratch, "parent", .{ 25, 5 });
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    const selected_program = if (scenario == .work)
        try semanticGuestProgram(scratch, &sender, parent.receipt.task, "placement-semantic-guest")
    else
        program.receipt.workspace.?;
    const specialized: ?native.tasks.Admission = if (scenario == .work)
        null
    else
        try sender.workspaceSpecialize(scratch, "specialize", parent.receipt.task, selected_program);
    const ancestor: ?contracts.workspace.Ref = if (specialized) |item|
        try workspaceRef(scratch, .runtime, item.receipt.workspace.?)
    else
        null;
    var packaged_runtime = try sender.program.retainRuntime();
    defer packaged_runtime.deinit();
    const semantic_roots = [_][32]u8{
        kosmos.RuntimeCompiler.approvedRootIdentity(&packaged_runtime),
        if (specialized != null) kosmos.RuntimeCompiler.approvedRootIdentity(&sender.runtime_cache.?.artifact) else kosmos.RuntimeCompiler.approvedRootIdentity(&packaged_runtime),
    };
    profile.semantic_construction = .{
        .roots = &semantic_roots,
        .checkers = &.{kosmos.RuntimeCompiler.checker_identity},
        .guard = true,
    };
    sender.profile.semantic_construction = profile.semantic_construction;
    receiver.profile.semantic_construction = profile.semantic_construction;
    const generated: ?GeneratedRuntime = if (scenario == .work) blk: {
        phase = "generated transformation and retained runtime continuation";
        var construction_live: usize = 0;
        const derived = construction: {
            var request = std.heap.ArenaAllocator.init(sender.allocator);
            defer request.deinit();
            const construction_allocator = request.allocator();
            var retained = try exerciseGenerated(
                construction_allocator,
                &sender,
                parent.receipt.task,
                selected_program,
                try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, construction_allocator, .{ .yields = 64, .seed = 100 }),
            );
            inline for (.{ "candidate", "runtime", "producer", "result" }) |field| {
                @field(retained, field).id.bytes = try scratch.dupe(u8, @field(retained, field).id.bytes);
            }
            construction_live = meter.live;
            break :construction retained;
        };
        std.debug.print("semantic placement: construction backing before_release={d} after_release={d}\n", .{ construction_live, meter.live });
        phase = "verify temporary construction work disposal";
        std.debug.print("semantic placement: disposal at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
        try std.testing.expect(try sender.associatedWorkDisposed(scratch, parent.receipt.task));
        break :blk derived;
    } else null;
    if (scenario == .work) sender.compiler_facts = &sender_compiler_facts;
    const runtime = if (generated) |derived| derived.runtime else ancestor.?;
    const input = if (scenario == .work)
        try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, scratch, .{ .yields = 64, .seed = 100 })
    else blk: {
        const bytes = try scratch.alloc(u8, 64 * 9 + 1);
        var writer: data.wire.Writer = .{ .output = bytes };
        for (0..64) |i| {
            try writer.natural(1);
            try writer.fixed(u64, @intCast(i));
        }
        try writer.natural(0);
        break :blk bytes;
    };
    var program_record = try sender.workspaceProgram(a, parent.receipt.task, selected_program);
    defer program_record.deinit();
    const input_schema = program_record.value.description.input_schema;
    var input_value = try native.dynamic_values.decode(a, try source_namespace.store.object(scratch, input_schema, null), input);
    defer input_value.deinit();
    const start_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = try workspaceRef(scratch, .program, selected_program),
        .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, input_schema.digest), .json_text = .{ .bytes = try native.json.canonical(scratch, input_value.value) } } },
        .policy = if (scenario == .root) .{ .stop = .terminal, .continuation = .owner_scheduled } else .{},
        .runtime = .{ .selected = runtime },
    } } };
    if (scenario == .work) std.debug.print("semantic placement: start selected work at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    const started = try sender.workspaceCommand(scratch, "start", parent.receipt.task, start_command);
    try std.testing.expectEqual(.observed, started.disposition);
    const start_observation = (try native.json.parseAsset(scratch, started.observation_json.bytes, started.observation_json.bytes.len)).value;
    const work_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, start_observation.object.get("work").?);
    const work_id = try nativeIdentity(work_ref);
    var work = try sender.workspaceWork(a, parent.receipt.task, work_id);
    defer work.deinit();
    try std.testing.expect(!work.value.terminal());
    _ = try sender.workspacePump(scratch, "begin-outer", parent.receipt.task, .{ .expected = .{ .work = work_ref, .execution_revision = work.value.execution_revision, .control_revision = work.value.control_revision }, .base_quantum = 1 });
    const subject: p.Subject = .{ .task = parent.receipt.task, .work = work_id };
    const cut = try sender.placementCut(scratch, subject);
    try std.testing.expect(cut.outer != null);
    const compatibility = try sender.placementCompatibility(scratch, subject);
    const resources = try profile.resourceIdentity(scratch, application.image_identity);
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(11));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(12));
    const successor_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(15));
    const source_site: p.Site = .{ .key = source_key.public_key.toBytes(), .namespace = source_namespace.identity };
    const destination_site: p.Site = .{ .key = destination_key.public_key.toBytes(), .namespace = destination_identity };
    const successor_site: p.Site = .{ .key = successor_key.public_key.toBytes(), .namespace = successor_identity };
    const Disclosure = struct {
        runtime: [32]u8,
        saw_runtime: bool = false,
        deny_runtime: bool = false,
        denied_dependency: ?[32]u8 = null,
        fn check(context: *anyopaque, _: p.Subject, objects: []const native.testing.state.Reference) !void {
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
    var disclosure: Disclosure = .{ .runtime = try nativeIdentity(runtime) };
    const successor_peer: p.Peer = .{ .name = "successor", .site = successor_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(13), .context = &disclosure, .disclose = Disclosure.check };
    var source_peers = [_]p.Peer{ .{ .name = "destination", .site = destination_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(13), .context = &disclosure, .disclose = Disclosure.check }, successor_peer };
    var destination_peers = [_]p.Peer{ .{ .name = "source", .site = source_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(13), .context = &disclosure, .disclose = Disclosure.check }, successor_peer };
    var successor_peers = [_]p.Peer{ source_peers[0], destination_peers[0] };
    const source_config: p.Configuration = .{ .signing_key = source_key, .peers = &source_peers, .transport_directory = path_buffer[0..length] };
    const destination_config: p.Configuration = .{ .signing_key = destination_key, .peers = &destination_peers };
    const successor_config: p.Configuration = .{ .signing_key = successor_key, .peers = &successor_peers };
    sender.profile.placement = &source_config;
    if (scenario == .work) {
        phase = "prepare placement observer";
        const observer = try placementObserver(&sender, scratch, subject.task, selected_program, work_id, true);
        const observer_subject: p.Subject = .{ .task = subject.task, .work = try nativeIdentity(observer.work) };
        const controller: p.Subject = .{ .task = subject.task };
        const before = source_namespace.store.head;
        try std.testing.expectError(error.ActiveObserverMobilityUnsupported, freezePlacement(&sender, subject, "destination", cut, @splat(101)));
        try std.testing.expectError(error.ActiveObserverMobilityUnsupported, freezePlacement(&sender, observer_subject, "destination", try sender.placementCut(scratch, observer_subject), @splat(102)));
        try std.testing.expectError(error.ScheduledObserverMobilityUnsupported, freezePlacement(&sender, controller, "successor", try sender.placementCut(scratch, controller), @splat(103)));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
        _ = try sender.workspaceStopObserving(scratch, "placement-observer-stop", subject.task, observer);
        _ = try sender.placementCompatibility(scratch, observer_subject);
        observerCustodyWitness(
            &sender,
            scratch,
            subject.task,
            selected_program,
            input,
            &source_peers[0],
        ) catch |err| {
            std.debug.print("observer custody: {s}\n", .{@errorName(err)});
            return err;
        };
    }
    if (scenario == .local_ack or scenario == .remote_ack) {
        var ack_source_profile = profile;
        ack_source_profile.placement = &source_config;
        var ack_destination_profile = profile;
        ack_destination_profile.placement = &destination_config;
        var ack_successor_profile = profile;
        ack_successor_profile.placement = &successor_config;
        if (scenario == .remote_ack) {
            _ = try freezePlacement(&sender, subject, "destination", cut, @splat(74));
            const work_archive = try std.fmt.allocPrint(scratch, "{s}/ack-work.par", .{path_buffer[0..length]});
            const work_offer = try offerPlacement(&sender, subject, "destination", work_archive);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var work_decision: p.Signed(p.Decision) = undefined;
            {
                var ns = try native.Namespace.open(a, io, destination_path);
                defer ns.close() catch unreachable;
                var executor = try native.tasks.Service(OwnerTypes).init(a, io, &ns, assets, &application, handlers, ack_destination_profile);
                defer executor.close(a) catch unreachable;
                work_decision = try acceptPlacement(&executor, "ack-work", "source", work_offer, work_archive);
            }
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, ack_source_profile);
            sender_open = true;
            try sender.placementApplyDecision(scratch, subject, work_decision);
            source_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "source" };
        }
        _ = try sender.requestCancel(scratch, "ack-parent-cancel", subject.task, "stop");
        if (scenario == .local_ack) {
            _ = try sender.pump(scratch);
            var cancelled = try sender.workspaceWork(scratch, subject.task, work_id);
            defer cancelled.deinit();
            try std.testing.expect(cancelled.value.cancellation != null and !cancelled.value.terminal());
            _ = try sender.workspaceControl(scratch, "ack-local-park", subject.task, work_id, cancelled.value.execution_revision, cancelled.value.control_revision, .park);
        } else {
            var acknowledged = false;
            for (0..4) |_| {
                _ = try sender.pump(scratch);
                const command = (try pendingCleanup(&sender, scratch, subject.task)).?;
                try sender.close(a);
                sender_open = false;
                try source_namespace.close();
                source_open = false;
                var report: p.Signed(p.Report) = undefined;
                {
                    var ns = try native.Namespace.open(a, io, destination_path);
                    defer ns.close() catch unreachable;
                    var executor = try native.tasks.Service(OwnerTypes).init(a, io, &ns, assets, &application, handlers, ack_destination_profile);
                    defer executor.close(a) catch unreachable;
                    report = (try contracts.decodeOwned(p.Signed(p.Report), scratch, try executor.placementExecuteControl(scratch, "source", command))).value;
                    try std.testing.expectEqual(.observed, report.value.reply.disposition);
                    if (command.value.command == .cancel) {
                        const current = report.value.work_state.?;
                        try std.testing.expect(current.cancellation != null and !current.cleanup_complete);
                        _ = try executor.workspaceControl(scratch, "ack-remote-park", subject.task, work_id, current.execution_revision, current.control_revision, .park);
                        acknowledged = true;
                    }
                }
                source_namespace = try native.Namespace.open(a, io, source_path);
                source_open = true;
                sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, ack_source_profile);
                sender_open = true;
                try sender.placementApplyReport(scratch, subject.task, p.controlId(command.value), report);
                if (acknowledged) break;
            }
            try std.testing.expect(acknowledged);
        }
        var parent_before_move = try sender.task(scratch, subject.task);
        defer parent_before_move.deinit();
        try std.testing.expect(!parent_before_move.value.terminal());
        const controller: p.Subject = .{ .task = subject.task };
        _ = try freezePlacement(&sender, controller, "successor", try sender.placementCut(scratch, controller), @splat(75));
        const controller_archive = try std.fmt.allocPrint(scratch, "{s}/ack-controller.par", .{path_buffer[0..length]});
        const controller_offer = try offerPlacement(&sender, controller, "successor", controller_archive);
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        var decision: p.Signed(p.Decision) = undefined;
        var inspection: p.Signed(p.Control) = undefined;
        {
            var ns = try native.Namespace.open(a, io, successor_path);
            defer ns.close() catch unreachable;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &ns, assets, &application, handlers, ack_successor_profile);
            defer successor.close(a) catch unreachable;
            decision = try acceptPlacement(&successor, "ack-controller", "source", controller_offer, controller_archive);
            inspection = (try contracts.decodeOwned(p.Signed(p.Control), scratch, try successor.placementControl(scratch, "ack-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }))).value;
        }
        {
            var ns = try native.Namespace.open(a, io, source_path);
            defer ns.close() catch unreachable;
            var former = try native.tasks.Service(OwnerTypes).init(a, io, &ns, assets, &application, handlers, ack_source_profile);
            defer former.close(a) catch unreachable;
            try former.placementApplyDecision(scratch, controller, decision);
        }
        var inspection_report: p.Signed(p.Report) = undefined;
        {
            var ns = try native.Namespace.open(a, io, if (scenario == .local_ack) source_path else destination_path);
            defer ns.close() catch unreachable;
            var executor = try native.tasks.Service(OwnerTypes).init(a, io, &ns, assets, &application, handlers, if (scenario == .local_ack) ack_source_profile else ack_destination_profile);
            defer executor.close(a) catch unreachable;
            if (scenario == .remote_ack) try executor.placementFollowController(scratch, "source", "successor", controller_offer, decision);
            inspection_report = (try contracts.decodeOwned(p.Signed(p.Report), scratch, try executor.placementExecuteControl(scratch, "successor", inspection))).value;
            try std.testing.expectEqual(.observed, inspection_report.value.reply.disposition);
            try std.testing.expect(inspection_report.value.work_state.?.explicitly_parked);
        }
        successor_peers[if (scenario == .local_ack) 1 else 0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "successor" };
        {
            var ns = try native.Namespace.open(a, io, successor_path);
            defer ns.close() catch unreachable;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &ns, assets, &application, handlers, ack_successor_profile);
            defer successor.close(a) catch unreachable;
            try successor.placementApplyReport(scratch, subject.task, p.controlId(inspection.value), inspection_report);
            var parent_cut = try successor.task(scratch, subject.task);
            defer parent_cut.deinit();
            _ = try successor.resumeTask(scratch, "ack-resume-controller", subject.task, parent_cut.value.revision);
            _ = try successor.pump(scratch);
            try std.testing.expectEqual(null, try pendingCleanup(&successor, scratch, subject.task));
            try std.testing.expect(try successor.shutdownIncomplete(scratch));
            _ = try successor.requestCancel(scratch, "ack-fresh-cancel", subject.task, "stop again");
            _ = try successor.pump(scratch);
            const fresh = (try pendingCleanup(&successor, scratch, subject.task)).?;
            try std.testing.expect(fresh.value.command == .cancel);
            try std.testing.expect(fresh.value.cleanup_request.? > parent_before_move.value.revision);
        }
        return;
    }
    if (scenario == .root_cancel_abort or scenario == .root_cancel_refused) {
        phase = "settle local child while cancelling controller is frozen";
        const controller: p.Subject = .{ .task = subject.task };
        _ = try sender.requestCancel(scratch, "cancel-controller", subject.task, "stop");
        _ = try freezePlacement(&sender, controller, "destination", try sender.placementCut(scratch, controller), @splat(71));
        var refusal: ?p.Signed(p.Decision) = null;
        if (scenario == .root_cancel_refused) {
            const frozen_path = try std.fmt.allocPrint(scratch, "{s}/cancelled-controller.par", .{path_buffer[0..length]});
            const frozen_offer = try offerPlacement(&sender, controller, "destination", frozen_path);
            refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = frozen_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, frozen_offer.value), .source = source_site, .destination = destination_site, .epoch = frozen_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
        }
        _ = try sender.workspaceControl(scratch, "settle-controller-child", subject.task, work_id, cut.execution, cut.control, .{ .cancel = .{ .bytes = "stop" } });
        var child_disposed = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.workspaceWork(scratch, subject.task, work_id);
            defer current.deinit();
            if (current.value.terminal()) {
                try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                child_disposed = true;
                break;
            }
        }
        try std.testing.expect(child_disposed);
        try std.testing.expectEqual(.frozen, (try sender.placementStatus(scratch, controller)).?.phase);
        try std.testing.expectEqual(@as(usize, 1), sender.owned.items.len);
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        if (refusal) |decision| try sender.placementApplyDecision(scratch, controller, decision) else try sender.placementAbortUnsent(scratch, controller, @splat(71));
        var root_disposed = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.task(scratch, subject.task);
            defer current.deinit();
            if (try sender.taskCleanupComplete(scratch, current.value)) {
                try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                root_disposed = true;
                break;
            }
        }
        try std.testing.expect(root_disposed);
        try std.testing.expect(!try sender.shutdownIncomplete(scratch));
        phase = "cancel shutdown observes a restored uncancelled controller";
        const shutdown_root = try sender.submit(scratch, "shutdown-controller", .{ 25, 5 });
        const shutdown_subject: p.Subject = .{ .task = shutdown_root.receipt.task };
        _ = try freezePlacement(&sender, shutdown_subject, "destination", try sender.placementCut(scratch, shutdown_subject), @splat(72));
        refusal = null;
        if (scenario == .root_cancel_refused) {
            const frozen_path = try std.fmt.allocPrint(scratch, "{s}/shutdown-controller.par", .{path_buffer[0..length]});
            const frozen_offer = try offerPlacement(&sender, shutdown_subject, "destination", frozen_path);
            refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = frozen_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, frozen_offer.value), .source = source_site, .destination = destination_site, .epoch = frozen_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
        }
        try sender.cancelOwned(scratch, "shutdown-probe", "stop");
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        if (refusal) |decision| try sender.placementApplyDecision(scratch, shutdown_subject, decision) else try sender.placementAbortUnsent(scratch, shutdown_subject, @splat(72));
        try sender.park(scratch);
        var parked = try sender.task(scratch, shutdown_subject.task);
        defer parked.deinit();
        try std.testing.expect(!parked.value.terminal());
        try std.testing.expect(parked.value.cancellation == null);
        try std.testing.expectEqual(.parked, parked.value.schedule);
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        return;
    }
    if (scenario == .queued) {
        source_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "source" };
        const queued_move = try sender.workspaceCommand(scratch, "queue-before-progress", subject.task, .{ .placement = .{ .move = .{ .operation = .{ .bytes = "queued-work" }, .subject = .{ .work = work_ref }, .site = .{ .bytes = "destination" }, .custody_epoch = 0 } } });
        try std.testing.expectEqual(.observed, queued_move.disposition);
        inline for (.{ "principal", "tenant" }) |field| {
            const authority = sender.profile.authority;
            defer sender.profile.authority = authority;
            const before = source_namespace.store.head;
            const pending_before = try scratch.dupe(@TypeOf(sender.placement_pending.items[0]), sender.placement_pending.items);
            @field(sender.profile.authority, field) = "foreign";
            try std.testing.expectError(error.Denied, sender.placementWithdraw(scratch, subject.task, p.operationId(source_site, subject.task, "queued-work", .move)));
            try std.testing.expectEqualDeep(before, source_namespace.store.head);
            try std.testing.expectEqualDeep(pending_before, sender.placement_pending.items);
            try std.testing.expect(sender.placement_job == null);
        }
        _ = try sender.workspacePump(scratch, "queued-work-progress", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control }, .base_quantum = 1 });
        const progressed_cut = try sender.placementCut(scratch, subject);
        try std.testing.expect(!std.meta.eql(cut, progressed_cut));
        try std.testing.expectEqual(.progressed, try sender.pump(scratch));
        const frozen = (try sender.placementStatus(scratch, subject)).?;
        try std.testing.expectEqual(.frozen, frozen.phase);
        try std.testing.expectEqualDeep(progressed_cut, frozen.intent.?.cut);
        try std.testing.expect(sender.placementActive());
        return;
    }
    if (scenario == .cancel_abort or scenario == .cancel_refused) {
        var cleanup_builder = source.Builder.init(a);
        defer cleanup_builder.deinit();
        const cleanup_document = try native.source_records.encode(scratch, try @import("workspace_sources.zig").yieldingCancellation(&cleanup_builder));
        const cleanup_program = try sender.workspaceBuild(scratch, "restored-cleanup-program", subject.task, cleanup_document, &diagnostic);
        try sender.park(scratch);
        for (0..2) |parked| {
            phase = "admit child cancellation before freeze";
            const operation = try std.fmt.allocPrint(scratch, "child-cleanup-{d}", .{parked});
            const child = try sender.workspaceStart(scratch, operation, subject.task, cleanup_program.receipt.workspace.?, &.{}, .{});
            const child_id = child.receipt.workspace.?;
            var initial = try sender.workspaceWork(scratch, subject.task, child_id);
            defer initial.deinit();
            _ = try sender.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "{s}-cancel", .{operation}), subject.task, child_id, initial.value.execution_revision, initial.value.control_revision, .{ .cancel = .{ .bytes = "stop" } });
            var cancelling = try sender.workspaceWork(scratch, subject.task, child_id);
            defer cancelling.deinit();
            try std.testing.expect(!cancelling.value.terminal());
            try std.testing.expectEqual(.queued, cancelling.value.schedule);
            if (parked == 1) _ = try sender.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "{s}-park", .{operation}), subject.task, child_id, cancelling.value.execution_revision, cancelling.value.control_revision, .park);
            const child_subject: p.Subject = .{ .task = subject.task, .work = child_id };
            const transfer: [32]u8 = @splat(@intCast(90 + parked));
            _ = try freezePlacement(&sender, child_subject, "destination", try sender.placementCut(scratch, child_subject), transfer);
            var refusal: ?p.Signed(p.Decision) = null;
            if (scenario == .cancel_refused) {
                const child_archive = try std.fmt.allocPrint(scratch, "{s}/{s}.par", .{ path_buffer[0..length], operation });
                const child_offer = try offerPlacement(&sender, child_subject, "destination", child_archive);
                refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = transfer, .offer_digest = try p.digest(p.Offer, scratch, child_offer.value), .source = source_site, .destination = destination_site, .epoch = child_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
            }
            if (refusal) |decision| try sender.placementApplyDecision(scratch, child_subject, decision) else try sender.placementAbortUnsent(scratch, child_subject, transfer);
            if (parked == 1) {
                for (0..4) |_| _ = try sender.pump(scratch);
                var still = try sender.workspaceWork(scratch, subject.task, child_id);
                defer still.deinit();
                try std.testing.expect(!still.value.terminal());
                try std.testing.expectEqual(.parked, still.value.schedule);
                _ = try sender.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "{s}-resume", .{operation}), subject.task, child_id, still.value.execution_revision, still.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } });
            }
            var child_disposed = false;
            for (0..512) |_| {
                _ = try sender.pump(scratch);
                var current = try sender.workspaceWork(scratch, subject.task, child_id);
                defer current.deinit();
                if (current.value.terminal()) {
                    try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                    child_disposed = true;
                    break;
                }
            }
            phase = "cancelled child restored to local custody";
            try std.testing.expect(child_disposed);
        }
        for (0..2) |parked| {
            const operation = try std.fmt.allocPrint(scratch, "root-cleanup-{d}", .{parked});
            const cancelled_root = try sender.submit(scratch, operation, .{ 25, 5 });
            const root_subject: p.Subject = .{ .task = cancelled_root.receipt.task };
            _ = try sender.requestCancel(scratch, try std.fmt.allocPrint(scratch, "{s}-cancel", .{operation}), root_subject.task, "stop");
            const root_cut = try sender.placementCut(scratch, root_subject);
            const transfer: [32]u8 = @splat(@intCast(80 + parked));
            _ = try freezePlacement(&sender, root_subject, "destination", root_cut, transfer);
            var refusal: ?p.Signed(p.Decision) = null;
            if (scenario == .cancel_refused) {
                const root_archive = try std.fmt.allocPrint(scratch, "{s}/{s}.par", .{ path_buffer[0..length], operation });
                const root_offer = try offerPlacement(&sender, root_subject, "destination", root_archive);
                refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = transfer, .offer_digest = try p.digest(p.Offer, scratch, root_offer.value), .source = source_site, .destination = destination_site, .epoch = root_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
            }
            if (parked == 1) try sender.park(scratch);
            if (refusal) |decision| try sender.placementApplyDecision(scratch, root_subject, decision) else try sender.placementAbortUnsent(scratch, root_subject, transfer);
            if (parked == 1) {
                for (0..4) |_| _ = try sender.pump(scratch);
                var still = try sender.task(scratch, root_subject.task);
                defer still.deinit();
                try std.testing.expect(!still.value.terminal());
                try std.testing.expectEqual(.parked, still.value.schedule);
                _ = try sender.requestCancel(scratch, try std.fmt.allocPrint(scratch, "{s}-recancel", .{operation}), root_subject.task, "stop");
            }
            var root_disposed = false;
            for (0..512) |_| {
                _ = try sender.pump(scratch);
                var current = try sender.task(scratch, root_subject.task);
                defer current.deinit();
                if (current.value.terminal()) {
                    try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                    root_disposed = true;
                    break;
                }
            }
            try std.testing.expect(root_disposed);
        }
    }
    const identified = try sender.placementRequest(scratch, .{ .identify = .{} });
    try std.testing.expect(identified == .object);
    const sites = try sender.workspaceCommand(scratch, "placement-sites", subject.task, .{ .placement = .{ .sites = .{} } });
    try std.testing.expectEqual(.observed, sites.disposition);
    const sites_head = source_namespace.store.head;
    const sites_replay = try sender.workspaceCommand(scratch, "placement-sites", subject.task, .{ .placement = .{ .sites = .{} } });
    try std.testing.expectEqualStrings(sites.observation_json.bytes, sites_replay.observation_json.bytes);
    try std.testing.expectEqualDeep(sites_head, source_namespace.store.head);
    // Withdrawal before publication closes the queued move without transferring
    // authority or leaving an unsettled record that blocks later root movement.
    source_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "source" };
    const queued = try sender.workspaceCommand(scratch, "placement-queue", subject.task, .{ .placement = .{ .move = .{ .operation = .{ .bytes = "withdraw-before-send" }, .subject = .{ .work = work_ref }, .site = .{ .bytes = "destination" }, .custody_epoch = 0 } } });
    if (queued.disposition != .observed) std.debug.print("placement queue rejection: {s}\n", .{queued.observation_json.bytes});
    try std.testing.expectEqual(.observed, queued.disposition);
    const withdrawn = try sender.workspaceCommand(scratch, "placement-withdraw", subject.task, .{ .placement = .{ .withdraw = .{ .operation = .{ .bytes = "withdraw-before-send" } } } });
    try std.testing.expectEqual(.observed, withdrawn.disposition);
    const withdrawn_state = try native.values.fromJson(p.Move, scratch, (try native.json.parseAsset(scratch, withdrawn.observation_json.bytes, withdrawn.observation_json.bytes.len)).value);
    try std.testing.expect(withdrawn_state.cancelled);
    try std.testing.expect(withdrawn_state.withdraw_requested);
    try std.testing.expect(withdrawn_state.decision == null);
    const retry_withdrawn = try sender.workspaceCommand(scratch, "placement-retry-withdrawn", subject.task, .{ .placement = .{ .retry = .{ .operation = .{ .bytes = "withdraw-before-send" } } } });
    try std.testing.expectEqual(.observed, retry_withdrawn.disposition);
    source_peers[0].channel = null;
    const executor_observer: ?contracts.workspace.Expected = if (scenario == .preoffer) blk: {
        const observed_source = try sender.workspaceStart(scratch, "executor-observer-source", subject.task, selected_program, input, .{});
        break :blk try placementObserver(&sender, scratch, subject.task, selected_program, observed_source.receipt.workspace.?, false);
    } else null;
    if (scenario == .root or scenario == .preoffer) {
        if (scenario == .preoffer) _ = try freezePlacement(&sender, subject, "destination", cut, @splat(14));
        const controller: p.Subject = .{ .task = subject.task };
        const controller_cut = try sender.placementCut(scratch, controller);
        _ = try freezePlacement(&sender, controller, "successor", controller_cut, @splat(98));
        const frozen_head = source_namespace.store.head;
        const frozen_runnable = try scratch.dupe(native.workspace.Subject, sender.runnable.items);
        const replayed_build = try sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
        try std.testing.expect(replayed_build.replayed);
        try std.testing.expectEqualDeep(program.receipt, replayed_build.receipt);
        const replayed_specialization = try sender.workspaceSpecialize(scratch, "specialize", parent.receipt.task, program.receipt.workspace.?);
        try std.testing.expect(replayed_specialization.replayed);
        try std.testing.expectEqualDeep(specialized.?.receipt, replayed_specialization.receipt);
        const replayed_start = try sender.workspaceCommand(scratch, "start", parent.receipt.task, start_command);
        try std.testing.expectEqual(.observed, replayed_start.disposition);
        const replayed_start_value = (try native.json.parseAsset(scratch, replayed_start.observation_json.bytes, replayed_start.observation_json.bytes.len)).value;
        try std.testing.expect(replayed_start_value.object.get("replayed").?.bool);
        try std.testing.expectEqualDeep(work_ref, try native.values.fromJson(contracts.workspace.Ref, scratch, replayed_start_value.object.get("work").?));
        const replayed_sites = try sender.workspaceCommand(scratch, "placement-sites", subject.task, .{ .placement = .{ .sites = .{} } });
        try std.testing.expectEqual(.observed, replayed_sites.disposition);
        try std.testing.expectEqualStrings(sites.observation_json.bytes, replayed_sites.observation_json.bytes);
        try std.testing.expectError(error.CustodyNotLocal, sender.workspaceBuild(scratch, "frozen-new-build", parent.receipt.task, document, &diagnostic));
        try std.testing.expectError(error.CustodyNotLocal, sender.workspaceSpecialize(scratch, "frozen-new-specialization", parent.receipt.task, program.receipt.workspace.?));
        try std.testing.expectEqual(.rejected, (try sender.workspaceCommand(scratch, "frozen-new-start", parent.receipt.task, start_command)).disposition);
        try std.testing.expectEqual(.rejected, (try sender.workspaceCommand(scratch, "frozen-new-sites", subject.task, .{ .placement = .{ .sites = .{} } })).disposition);
        try std.testing.expectError(error.OperationConflict, sender.workspaceBuild(scratch, "build", parent.receipt.task, try std.fmt.allocPrint(scratch, "\n{s}", .{document}), &diagnostic));
        {
            const authority = sender.profile.authority;
            defer sender.profile.authority = authority;
            sender.profile.authority.disclosure = false;
            try std.testing.expectError(error.Denied, sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic));
            sender.profile.authority = authority;
            sender.profile.authority.revoked = true;
            try std.testing.expectError(error.Denied, sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic));
            sender.profile.authority = authority;
            sender.profile.authority.principal = "other";
            try std.testing.expectError(error.Denied, sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic));
        }
        try std.testing.expectEqualDeep(frozen_head, source_namespace.store.head);
        try std.testing.expectEqualDeep(frozen_runnable, sender.runnable.items);
        try std.testing.expectEqualDeep(controller_cut, try sender.placementCut(scratch, controller));
        if (scenario == .root) _ = try sender.workspacePump(scratch, "independent-local-progress", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control }, .base_quantum = 1 });
        var progressed_parent = try sender.task(scratch, subject.task);
        defer progressed_parent.deinit();
        if (scenario == .root) try std.testing.expect(progressed_parent.value.revision > controller_cut.control);
        const snapshot_path = try std.fmt.allocPrint(scratch, "{s}/frozen-controller.par", .{path_buffer[0..length]});
        const snapshot_offer = try offerPlacement(&sender, controller, "successor", snapshot_path);
        try std.testing.expectEqualDeep(controller_cut, snapshot_offer.value.intent.cut);
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        {
            const copy_path = try std.fmt.allocPrint(scratch, "{s}/foreign-frozen-copy", .{path_buffer[0..length]});
            var copy_namespace = try native.Namespace.open(a, io, copy_path);
            defer copy_namespace.close() catch unreachable;
            var copy_profile = profile;
            // A copied namespace can share the signing key without sharing
            // the source namespace's actual custody or export obligation.
            copy_profile.placement = &source_config;
            var copied = try native.tasks.Service(OwnerTypes).init(a, io, &copy_namespace, assets, &application, handlers, copy_profile);
            defer copied.close(a) catch unreachable;
            var archive_arena = std.heap.ArenaAllocator.init(a);
            defer archive_arena.deinit();
            _ = try copied.importCheckpoint(archive_arena.allocator(), "copy-frozen", snapshot_path);
            const copied_head = copy_namespace.store.head;
            const copied_receipt = try copied.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
            try std.testing.expect(copied_receipt.replayed);
            try std.testing.expectEqualDeep(program.receipt, copied_receipt.receipt);
            try std.testing.expectError(error.CustodyNotLocal, copied.workspaceBuild(scratch, "copied-new-build", parent.receipt.task, document, &diagnostic));
            try std.testing.expectEqualDeep(copied_head, copy_namespace.store.head);
            try std.testing.expectError(error.InvalidTransfer, offerPlacement(&copied, controller, "successor", snapshot_path));
        }
        var snapshot_namespace = try native.Namespace.open(a, io, successor_path);
        var snapshot_profile = profile;
        snapshot_profile.placement = &successor_config;
        var snapshot_receiver = try native.tasks.Service(OwnerTypes).init(a, io, &snapshot_namespace, assets, &application, handlers, snapshot_profile);
        const decision = try acceptPlacement(&snapshot_receiver, "accept-frozen-controller", "source", snapshot_offer, snapshot_path);
        try std.testing.expectEqual(.local, (try snapshot_receiver.placementStatus(scratch, controller)).?.phase);
        try std.testing.expectEqual(.away, (try snapshot_receiver.placementStatus(scratch, subject)).?.phase);
        try snapshot_receiver.close(a);
        try snapshot_namespace.close();
        source_namespace = try native.Namespace.open(a, io, source_path);
        source_open = true;
        var source_profile = profile;
        source_profile.placement = &source_config;
        sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
        sender_open = true;
        try sender.placementApplyDecision(scratch, controller, decision);
        try std.testing.expectEqual(@as(@FieldType(p.Custody, "phase"), if (scenario == .root) .local else .frozen), (try sender.placementStatus(scratch, subject)).?.phase);
        if (scenario == .root) {
            phase = "normal controller completion parks the retained executor";
            var running_child = try sender.workspaceWork(scratch, subject.task, work_id);
            defer running_child.deinit();
            try std.testing.expectEqual(.queued, running_child.value.schedule);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            successor_peers[1].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "successor" };
            var completed = false;
            var parked = false;
            var incomplete_park = false;
            var refreshed_park = false;
            var inspection_reports: u64 = 0;
            var parked_task_watermark: u64 = 0;
            var prior_command: ?p.Signed(p.Control) = null;
            var prior_report: ?p.Signed(p.Report) = null;
            for (0..8) |_| {
                var selected_command: p.Signed(p.Control) = undefined;
                {
                    var closing_namespace = try native.Namespace.open(a, io, successor_path);
                    defer closing_namespace.close() catch unreachable;
                    var closing_controller = try native.tasks.Service(OwnerTypes).init(a, io, &closing_namespace, assets, &application, handlers, snapshot_profile);
                    defer closing_controller.close(a) catch unreachable;
                    phase = "apply remote close report";
                    if (prior_report) |reported| try closing_controller.placementApplyReport(scratch, subject.task, p.controlId(prior_command.?.value), reported);
                    if (!completed) {
                        for (0..512) |turn| {
                            var current = try closing_controller.task(scratch, subject.task);
                            defer current.deinit();
                            if (current.value.terminal()) {
                                try std.testing.expectEqual(.completed, current.value.outcome_kind);
                                try std.testing.expect(current.value.cancellation == null);
                                completed = true;
                                break;
                            }
                            if (current.value.schedule == .parked) _ = try closing_controller.resumeTask(scratch, try std.fmt.allocPrint(scratch, "complete-controller-{d}", .{turn}), subject.task, current.value.revision);
                            _ = try closing_controller.pump(scratch);
                        }
                        try std.testing.expect(completed);
                        try std.testing.expect(try closing_controller.shutdownIncomplete(scratch));
                    }
                    if (parked) {
                        phase = "settled remote park is quiescent";
                        try std.testing.expect(!try closing_controller.shutdownIncomplete(scratch));
                        _ = try closing_controller.pump(scratch);
                        var pending = try closing_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
                        defer pending.deinit();
                        while (try pending.step() == .row) {
                            var saved = try contracts.decodeOwned(p.ControlRecord, scratch, try pending.bytes(0));
                            defer saved.deinit();
                            try std.testing.expect(saved.value.report != null);
                        }
                        break;
                    }
                    phase = "refresh incomplete remote park";
                    if (incomplete_park) try std.testing.expect(try closing_controller.shutdownIncomplete(scratch));
                    _ = try closing_controller.pump(scratch);
                    var query = try closing_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
                    defer query.deinit();
                    var found = false;
                    while (try query.step() == .row) {
                        const saved = try contracts.decodeOwned(p.ControlRecord, scratch, try query.bytes(0));
                        if (saved.value.report == null) {
                            selected_command = saved.value.control;
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);
                    if (incomplete_park) try std.testing.expectEqual(.inspect, std.meta.activeTag(selected_command.value.command));
                }
                {
                    var executor_namespace = try native.Namespace.open(a, io, source_path);
                    defer executor_namespace.close() catch unreachable;
                    var closing_executor = try native.tasks.Service(OwnerTypes).init(a, io, &executor_namespace, assets, &application, handlers, source_profile);
                    defer closing_executor.close(a) catch unreachable;
                    phase = "execute remote close observation";
                    const result = try contracts.decodeOwned(p.Signed(p.Report), scratch, try closing_executor.placementExecuteControl(scratch, "successor", selected_command));
                    try std.testing.expectEqual(.observed, result.value.value.reply.disposition);
                    if (prior_report) |previous| try std.testing.expect(result.value.value.work_state.?.observed_at > previous.value.work_state.?.observed_at);
                    prior_report = result.value;
                    prior_command = selected_command;
                    if (selected_command.value.command == .park) {
                        try std.testing.expect(result.value.value.work_state.?.park_complete);
                        var parked_child = try closing_executor.workspaceWork(scratch, subject.task, work_id);
                        defer parked_child.deinit();
                        try std.testing.expectEqual(.parked, parked_child.value.schedule);
                        try std.testing.expect(parked_child.value.cancellation == null);
                        var incomplete = result.value.value;
                        incomplete.work_state.?.park_complete = false;
                        prior_report = try p.sign(p.Report, scratch, source_key, incomplete);
                        _ = try closing_executor.workspaceControl(scratch, "later-explicit-park", subject.task, work_id, parked_child.value.execution_revision, parked_child.value.control_revision, .park);
                        const later = try closing_executor.placementCut(scratch, subject);
                        try std.testing.expectEqual(parked_child.value.execution_revision, later.execution);
                        try std.testing.expectEqual(parked_child.value.control_revision + 1, later.control);
                        var observed_parent = try closing_executor.task(scratch, subject.task);
                        defer observed_parent.deinit();
                        parked_task_watermark = observed_parent.value.event_high;
                        incomplete_park = true;
                    } else if (incomplete_park) {
                        try std.testing.expect(result.value.value.work_state.?.parkSettled());
                        try std.testing.expectEqualDeep(work_ref, prior_command.?.value.command.inspect.work);
                        var observed_parent = try closing_executor.task(scratch, subject.task);
                        defer observed_parent.deinit();
                        try std.testing.expectEqual(parked_task_watermark, observed_parent.value.event_high);
                        inspection_reports += 1;
                        if (inspection_reports < 3) {
                            var incomplete = result.value.value;
                            incomplete.work_state.?.park_complete = false;
                            prior_report = try p.sign(p.Report, scratch, source_key, incomplete);
                        } else {
                            parked = true;
                            refreshed_park = true;
                        }
                    }
                }
            }
            try std.testing.expect(completed and parked and incomplete_park and refreshed_park);
            try std.testing.expectEqual(@as(u64, 3), inspection_reports);
            const last = prior_report.?.value.work_state.?;
            const expected: contracts.workspace.Expected = .{ .work = work_ref, .execution_revision = last.execution_revision, .control_revision = last.control_revision };
            const stopped_commands = [_]contracts.workspace.Work{
                .{ .advance = expected },
                .{ .delegate = .{ .expected = expected, .policy = .{} } },
                .{ .pump = .{ .expected = expected, .base_quantum = 1 } },
                .{ .request_cut = .{ .expected = expected, .level = .outer_execution } },
                .{ .realize = .{ .expected = expected, .realization_revision = running_child.value.realization_revision, .runtime = .{ .packaged = .{} } } },
            };
            var stopped_controls: [stopped_commands.len]p.Signed(p.Control) = undefined;
            {
                var closing_namespace = try native.Namespace.open(a, io, successor_path);
                defer closing_namespace.close() catch unreachable;
                var closing_controller = try native.tasks.Service(OwnerTypes).init(a, io, &closing_namespace, assets, &application, handlers, snapshot_profile);
                defer closing_controller.close(a) catch unreachable;
                var terminal_parent = try closing_controller.task(scratch, subject.task);
                defer terminal_parent.deinit();
                try std.testing.expect(terminal_parent.value.terminal());
                for (stopped_commands, &stopped_controls, 0..) |command, *signed, index| {
                    const operation_name = try std.fmt.allocPrint(scratch, "after-parent-completion-{d}", .{index});
                    const bytes = try closing_controller.placementControl(scratch, operation_name, subject.task, command);
                    const decoded = try contracts.decodeOwned(p.Signed(p.Control), scratch, bytes);
                    signed.* = decoded.value;
                    try std.testing.expect(signed.value.parent_stopped);
                    try std.testing.expectEqualSlices(u8, bytes, try closing_controller.placementControl(scratch, operation_name, subject.task, command));
                }
            }
            {
                var executor_namespace = try native.Namespace.open(a, io, source_path);
                defer executor_namespace.close() catch unreachable;
                var closing_executor = try native.tasks.Service(OwnerTypes).init(a, io, &executor_namespace, assets, &application, handlers, source_profile);
                defer closing_executor.close(a) catch unreachable;
                var retained_parent = try closing_executor.task(scratch, subject.task);
                defer retained_parent.deinit();
                try std.testing.expect(!retained_parent.value.terminal());
                const before = try closing_executor.placementCut(scratch, subject);
                for (stopped_controls) |control_value| {
                    const bytes = try closing_executor.placementExecuteControl(scratch, "successor", control_value);
                    const rejected = try contracts.decodeOwned(p.Signed(p.Report), scratch, bytes);
                    try std.testing.expectEqual(.rejected, rejected.value.value.reply.disposition);
                    const observation = (try native.json.parseAsset(scratch, rejected.value.value.reply.observation_json.bytes, rejected.value.value.reply.observation_json.bytes.len)).value;
                    try std.testing.expectEqualStrings("InvalidState", observation.object.get("error").?.string);
                    try std.testing.expectEqualDeep(before, try closing_executor.placementCut(scratch, subject));
                    try std.testing.expect(closing_executor.remote_stopped_parent == null);
                    try std.testing.expectEqualSlices(u8, bytes, try closing_executor.placementExecuteControl(scratch, "successor", control_value));
                }
            }
        }
        if (scenario == .preoffer) {
            const child_path = try std.fmt.allocPrint(scratch, "{s}/child-after-controller.par", .{path_buffer[0..length]});
            const child_offer = try offerPlacement(&sender, subject, "destination", child_path);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var child_decision: p.Signed(p.Decision) = undefined;
            {
                destination_namespace = try native.Namespace.open(a, io, destination_path);
                defer destination_namespace.close() catch unreachable;
                var child_profile = profile;
                child_profile.placement = &destination_config;
                var child_owner = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, child_profile);
                defer child_owner.close(a) catch unreachable;
                child_decision = try acceptPlacement(&child_owner, "accept-child-after-controller", "source", child_offer, child_path);
            }
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
            sender_open = true;
            try sender.placementApplyDecision(scratch, subject, child_decision);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var signed_control: p.Signed(p.Control) = undefined;
            {
                snapshot_namespace = try native.Namespace.open(a, io, successor_path);
                defer snapshot_namespace.close() catch unreachable;
                snapshot_receiver = try native.tasks.Service(OwnerTypes).init(a, io, &snapshot_namespace, assets, &application, handlers, snapshot_profile);
                defer snapshot_receiver.close(a) catch unreachable;
                const saved_control = try contracts.decodeOwned(p.Signed(p.Control), scratch, try snapshot_receiver.placementControl(scratch, "inspect-late-child", subject.task, .{ .inspect = .{ .work = work_ref } }));
                signed_control = saved_control.value;
            }
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
            sender_open = true;
            var next = try contracts.decodeOwned(p.ControlResolution, scratch, try sender.placementResolveControl(scratch, "successor", signed_control, &.{}));
            defer next.deinit();
            try std.testing.expect(next.value == .next);
            const route = [_]p.Succession{next.value.next};
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var result: p.Signed(p.Report) = undefined;
            {
                destination_namespace = try native.Namespace.open(a, io, destination_path);
                defer destination_namespace.close() catch unreachable;
                var child_profile = profile;
                child_profile.placement = &destination_config;
                var child_owner = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, child_profile);
                defer child_owner.close(a) catch unreachable;
                try child_owner.placementFollowController(scratch, "source", "successor", snapshot_offer, decision);
                const resolved = try contracts.decodeOwned(p.ControlResolution, scratch, try child_owner.placementResolveControl(scratch, "successor", signed_control, &route));
                result = resolved.value.report;
                try std.testing.expectEqual(.observed, result.value.reply.disposition);
            }
            {
                snapshot_namespace = try native.Namespace.open(a, io, successor_path);
                defer snapshot_namespace.close() catch unreachable;
                snapshot_receiver = try native.tasks.Service(OwnerTypes).init(a, io, &snapshot_namespace, assets, &application, handlers, snapshot_profile);
                defer snapshot_receiver.close(a) catch unreachable;
                try snapshot_receiver.placementFollowExecutor(scratch, subject.task, p.controlId(signed_control.value), route[0]);
                try snapshot_receiver.placementApplyReport(scratch, subject.task, p.controlId(signed_control.value), result);
                try std.testing.expectEqualDeep(destination_site, (try snapshot_receiver.placementStatus(scratch, subject)).?.owner);
            }
            phase = "cancel executor-local observer";
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
            sender_open = true;
            try executorObserverCancellation(&sender, scratch, subject.task, executor_observer.?);
        }
        return;
    }
    if (scenario == .work) {
        phase = "suspend controller before child freeze";
        std.debug.print("semantic placement: suspend controller at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
        var controller = try sender.task(scratch, subject.task);
        defer controller.deinit();
        _ = try sender.resumeTask(
            scratch,
            "resume-controller-before-child-freeze",
            subject.task,
            controller.value.revision,
        );
        try std.testing.expectEqual(.progressed, try sender.pump(scratch));
        try std.testing.expect(sender.active != null);
        try std.testing.expect(sender.active.?.subject == .root);
        try std.testing.expect(sender.active.?.root_control != null);
    }
    if (scenario == .work) std.debug.print("semantic placement: freeze child at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    _ = try freezePlacement(&sender, subject, "destination", cut, @splat(14));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.task(scratch, subject.task));
        try std.testing.expectError(error.Denied, sender.placementAbortUnsent(scratch, subject, @splat(14)));
        try std.testing.expectError(error.Denied, freezePlacement(&sender, subject, "destination", cut, @splat(14)));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    if (scenario == .work) {
        try std.testing.expect(sender.active != null);
        try std.testing.expect(sender.active.?.subject == .root);
        try std.testing.expect(sender.active.?.root_control != null);
    }
    if (scenario == .cancel_abort or scenario == .cancel_refused) {
        var refused: ?p.Signed(p.Decision) = null;
        if (scenario == .cancel_refused) {
            const refused_path = try std.fmt.allocPrint(scratch, "{s}/refused.par", .{path_buffer[0..length]});
            const refused_offer = try offerPlacement(&sender, subject, "destination", refused_path);
            refused = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = refused_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, refused_offer.value), .source = source_site, .destination = destination_site, .epoch = refused_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
        }
        sender.profile.semantic_construction = null;
        _ = try sender.requestCancel(scratch, "cancel-with-frozen-work", subject.task, "stop");
        var terminal = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.task(scratch, subject.task);
            defer current.deinit();
            if (current.value.terminal()) {
                terminal = true;
                break;
            }
        }
        try std.testing.expect(terminal);
        // Remove the terminal root's ordinary runnable entry. The retained
        // cancellation still owns the frozen child obligation.
        for (0..8) |_| if (try sender.pump(scratch) == .idle) break;
        try std.testing.expect(sender.owned.items.len != 0);
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        if (refused) |decision| {
            phase = "release refused transfer before identity retry";
            try sender.placementApplyDecision(scratch, subject, decision);
            try sender.placementApplyDecision(scratch, subject, decision);
        } else try sender.placementAbortUnsent(scratch, subject, @splat(14));
        var disposed = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.task(scratch, subject.task);
            defer current.deinit();
            if (try sender.taskCleanupComplete(scratch, current.value)) {
                disposed = true;
                break;
            }
        }
        try std.testing.expect(disposed);
        try std.testing.expect(!try sender.shutdownIncomplete(scratch));
        if (refused != null) {
            const changed_cut = try sender.placementCut(scratch, subject);
            try std.testing.expect(!std.meta.eql(cut, changed_cut));
            const released_head = source_namespace.store.head;
            try std.testing.expectError(error.OperationConflict, freezePlacement(&sender, subject, "destination", changed_cut, @splat(14)));
            try std.testing.expectEqualDeep(released_head, source_namespace.store.head);
            try std.testing.expectEqual(.local, (try sender.placementStatus(scratch, subject)).?.phase);
            phase = "fresh transfer after rejected identity reuse";
            const fresh_intent = try freezePlacement(&sender, subject, "destination", changed_cut, @splat(17));
            try std.testing.expectEqualDeep(fresh_intent, try freezePlacement(&sender, subject, "destination", changed_cut, @splat(17)));
            const other_subject: p.Subject = .{ .task = subject.task };
            const other_cut = try sender.placementCut(scratch, other_subject);
            try std.testing.expectError(error.OperationConflict, freezePlacement(&sender, other_subject, "destination", other_cut, @splat(17)));
            try std.testing.expectEqual(.local, (try sender.placementStatus(scratch, other_subject)).?.phase);
            try std.testing.expectEqual(.frozen, (try sender.placementStatus(scratch, subject)).?.phase);
            var conflicting_intent = fresh_intent;
            conflicting_intent.source = destination_site;
            conflicting_intent.destination = source_site;
            const conflicting_offer = try p.sign(p.Offer, scratch, destination_key, .{ .intent = conflicting_intent, .archive_digest = @splat(94), .archive_bytes = 0 });
            const frozen_head = source_namespace.store.head;
            try std.testing.expectError(error.OperationConflict, sender.placementRefuse(scratch, "destination", conflicting_offer, .withdrawn));
            try std.testing.expectEqualDeep(frozen_head, source_namespace.store.head);
            try sender.placementAbortUnsent(scratch, subject, @splat(17));
            try std.testing.expectEqualDeep(fresh_intent, try freezePlacement(&sender, subject, "destination", changed_cut, @splat(17)));
            const fresh_path = try std.fmt.allocPrint(scratch, "{s}/refused-again.par", .{path_buffer[0..length]});
            const fresh_offer = try offerPlacement(&sender, subject, "destination", fresh_path);
            const fresh_refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = fresh_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, fresh_offer.value), .source = source_site, .destination = destination_site, .epoch = fresh_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
            try sender.placementApplyDecision(scratch, subject, fresh_refusal);
            phase = "reopen retained transfer decisions";
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            var reopened_profile = profile;
            reopened_profile.placement = &source_config;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, reopened_profile);
            sender_open = true;
            phase = "reject old transfer identity after restart";
            try std.testing.expectError(error.OperationConflict, freezePlacement(&sender, subject, "destination", changed_cut, @splat(14)));
            const controller: p.Subject = .{ .task = subject.task };
            const controller_cut = try sender.placementCut(scratch, controller);
            try std.testing.expectError(error.OperationConflict, freezePlacement(&sender, controller, "destination", controller_cut, @splat(14)));
            try std.testing.expectEqual(.local, (try sender.placementStatus(scratch, controller)).?.phase);
            try std.testing.expect(!try sender.shutdownIncomplete(scratch));
        }
        return;
    }
    try std.testing.expectError(error.CustodyNotLocal, sender.workspaceControl(scratch, "source-must-stop", subject.task, work_id, cut.execution, cut.control, .advance));
    const archive_path = try std.fmt.allocPrint(scratch, "{s}/transfer.par", .{path_buffer[0..length]});
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, offerPlacement(&sender, subject, "destination", archive_path));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    // Leave the complete file without a published offer, as an interrupted
    // writer can. The retry must validate and durably reuse that exact file.
    disclosure.deny_runtime = true;
    if (scenario == .work) std.debug.print("semantic placement: denied runtime offer at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    try std.testing.expectError(error.DisclosureDenied, offerPlacement(&sender, subject, "destination", archive_path));
    try std.testing.expect((try sender.placementStatus(scratch, subject)).?.offer == null);
    disclosure.deny_runtime = false;
    if (generated) |derived| {
        disclosure.denied_dependency = try nativeIdentity(derived.candidate);
        std.debug.print("semantic placement: denied candidate offer at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
        try std.testing.expectError(error.DisclosureDenied, offerPlacement(&sender, subject, "destination", archive_path));
        try std.testing.expect((try sender.placementStatus(scratch, subject)).?.offer == null);
        disclosure.denied_dependency = null;
    }
    if (scenario == .work) std.debug.print("semantic placement: offer retry at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    const offer = try offerPlacement(&sender, subject, "destination", archive_path);
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, offerPlacement(&sender, subject, "destination", archive_path));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    try std.testing.expect(disclosure.saw_runtime);
    disclosure.deny_runtime = true;
    try std.testing.expectError(error.DisclosureDenied, offerPlacement(&sender, subject, "destination", archive_path));
    disclosure.deny_runtime = false;
    try std.testing.expectEqualDeep(offer, try offerPlacement(&sender, subject, "destination", archive_path));
    source_peers[0].disclosure_policy[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, offerPlacement(&sender, subject, "destination", archive_path));
    source_peers[0].disclosure_policy[0] ^= 1;
    sender.profile.runtime_identity[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, offerPlacement(&sender, subject, "destination", archive_path));
    sender.profile.runtime_identity[0] ^= 1;
    sender.profile.authority.disclosure = false;
    try std.testing.expectError(error.Denied, offerPlacement(&sender, subject, "destination", archive_path));
    sender.profile.authority.disclosure = true;
    try std.testing.expectError(error.InvalidTransfer, sender.placementAbortUnsent(scratch, subject, @splat(14)));
    if (scenario == .work or scenario == .onward) try sender.park(scratch);
    if (scenario == .onward) {
        phase = "untrusted copied custody";
        const controller: p.Subject = .{ .task = subject.task };
        const controller_cut = try sender.placementCut(scratch, controller);
        for (0..3) |attack| {
            phase = "untrusted custody preparation";
            attack_index = attack;
            const attacked_archive = try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}.par", .{ path_buffer[0..length], attack });
            const copied_site: p.Site = .{ .key = destination_key.public_key.toBytes(), .namespace = untrusted_namespaces[attack] };
            {
                try source_namespace.store.begin();
                defer source_namespace.store.rollback();
                if (attack < 2) {
                    try source_namespace.store.database.run("DELETE FROM records WHERE kind='placement_custody' AND task=?", &.{.{ .blob = &subject.task }});
                } else {
                    const forged = try p.Custody.initial(controller, copied_site).freeze(copied_site, .{ .transfer = @splat(71), .subject = controller, .source = copied_site, .destination = source_site, .source_native = profile.runtime_identity, .destination_native = profile.runtime_identity, .epoch = 0, .cut = controller_cut, .compatibility = compatibility, .resources = resources, .disclosure = @splat(13) });
                    try source_namespace.store.putRecord(p.Custody, "placement_custody", forged.id, forged.task, forged);
                }
                var archive_arena = std.heap.ArenaAllocator.init(a);
                defer archive_arena.deinit();
                _ = sender.exportCheckpoint(archive_arena.allocator(), subject.task, attacked_archive) catch |err| {
                    std.debug.print("untrusted archive export {d}: {s}\n", .{ attack, @errorName(err) });
                    return err;
                };
            }
        }
    }
    try sender.close(a);
    sender_open = false;
    try source_namespace.close();
    source_open = false;
    sender_compiler_facts.deinit();
    sender_compiler_facts = .{ .allocator = a };
    if (scenario == .onward) {
        const controller: p.Subject = .{ .task = subject.task };
        for (0..3) |attack| {
            phase = "untrusted custody import";
            attack_index = attack;
            const attacked_path = try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}", .{ path_buffer[0..length], attack });
            const attacked_archive = try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}.par", .{ path_buffer[0..length], attack });
            var copied_namespace = try native.Namespace.open(a, io, attacked_path);
            defer copied_namespace.close() catch unreachable;
            const copied_config: p.Configuration = .{ .signing_key = destination_key, .peers = &.{} };
            var copied_profile = profile;
            if (attack != 0) copied_profile.placement = &copied_config;
            var copied = try native.tasks.Service(OwnerTypes).init(a, io, &copied_namespace, assets, &application, handlers, copied_profile);
            defer copied.close(a) catch unreachable;
            var archive_arena = std.heap.ArenaAllocator.init(a);
            defer archive_arena.deinit();
            _ = copied.importCheckpoint(archive_arena.allocator(), "untrusted-copy", attacked_archive) catch |err| {
                std.debug.print("untrusted archive import {d}: {s}\n", .{ attack, @errorName(err) });
                return err;
            };
            if (attack == 2) {
                try std.testing.expectEqual(.away, (try copied.placementStatus(scratch, controller)).?.phase);
                try std.testing.expectError(error.InvalidTransfer, copied.placementAbortUnsent(scratch, controller, @splat(71)));
            }
            try std.testing.expectError(error.CustodyNotLocal, copied.resumeTask(scratch, "untrusted-resume", subject.task, 1));
            try std.testing.expectError(error.CustodyNotLocal, copied.requestCancel(scratch, "untrusted-cancel", subject.task, "stop"));
        }
    }
    if (scenario == .onward) {
        // Ordinary archive import is a data copy. Even a configured native
        // service cannot acquire this task or work merely by possessing it.
        const copied_path = try std.fmt.allocPrint(scratch, "{s}/copied", .{path_buffer[0..length]});
        var copied_namespace = try native.Namespace.open(a, io, copied_path);
        defer copied_namespace.close() catch unreachable;
        var copied = try native.tasks.Service(OwnerTypes).init(a, io, &copied_namespace, assets, &application, handlers, profile);
        defer copied.close(a) catch unreachable;
        var archive_arena = std.heap.ArenaAllocator.init(a);
        defer archive_arena.deinit();
        _ = try copied.importCheckpoint(archive_arena.allocator(), "copy", archive_path);
        try std.testing.expectError(error.CustodyNotLocal, copied.workspacePump(scratch, "copy-cannot-run", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control }, .base_quantum = 1 }));
        try std.testing.expectError(error.CustodyNotLocal, copied.resumeTask(scratch, "copy-cannot-control", subject.task, 1));
    }
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    phase = "accept child";
    if (scenario == .work) std.debug.print("semantic placement: accept child at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    destination_open = true;
    var resumed_profile = profile;
    resumed_profile.placement = &destination_config;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    if (scenario == .work) receiver.compiler_facts = &receiver_compiler_facts;
    // Refusing one transfer is durable history, not task occupancy.
    var unrelated_offer = offer.value;
    unrelated_offer.intent.transfer = @splat(99);
    const unrelated_signed = try p.sign(p.Offer, scratch, source_key, unrelated_offer);
    const prior_refusal = try receiver.placementRefuse(scratch, "source", unrelated_signed, .withdrawn);
    try std.testing.expect(prior_refusal.value.verdict == .refused);
    const receiver_head = destination_namespace.store.head;
    receiver.profile.authority.disclosure = false;
    try std.testing.expectError(error.Denied, acceptPlacement(&receiver, "accept", "source", offer, archive_path));
    try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
    receiver.profile.authority.disclosure = true;
    destination_peers[0].compatibility.admission[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, acceptPlacement(&receiver, "accept", "source", offer, archive_path));
    try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
    destination_peers[0].compatibility.admission[0] ^= 1;
    disclosure.deny_runtime = true;
    try std.testing.expectError(error.DisclosureDenied, acceptPlacement(&receiver, "accept", "source", offer, archive_path));
    try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
    disclosure.deny_runtime = false;
    if (generated != null) {
        const allowed_policy = receiver.profile.semantic_construction;
        defer receiver.profile.semantic_construction = allowed_policy;
        const wrong_roots = [_][32]u8{@splat(97)};
        receiver.profile.semantic_construction.?.roots = &wrong_roots;
        try std.testing.expectError(error.SemanticPolicyDenied, acceptPlacement(&receiver, "accept", "source", offer, archive_path));
        try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
        receiver.profile.semantic_construction = allowed_policy;
        receiver.profile.semantic_construction.?.checkers = &.{"different-checker"};
        try std.testing.expectError(error.SemanticPolicyDenied, acceptPlacement(&receiver, "accept", "source", offer, archive_path));
        try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
        try std.testing.expectError(error.UnknownTask, receiver.placementStatus(scratch, subject));
    }
    const accepted = try acceptPlacement(&receiver, "accept", "source", offer, archive_path);
    try std.testing.expectEqual(.accepted, accepted.value.verdict);
    if (scenario == .work) std.debug.print("semantic placement: child accepted at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    try std.testing.expectEqualDeep(prior_refusal, try receiver.placementRefuse(scratch, "source", unrelated_signed, .withdrawn));
    try std.testing.expectEqualDeep(accepted, try acceptPlacement(&receiver, "accept-again", "source", offer, archive_path));
    try std.testing.expectEqualDeep(accepted, try receiver.placementRefuse(scratch, "source", offer, .withdrawn));
    // Lose the acceptance reply and restart the destination. Only its work is
    // executable; its copied controller remains at the original namespace.
    try std.testing.expectError(error.CustodyNotLocal, receiver.resumeTask(scratch, "copied-controller", subject.task, 1));
    try receiver.close(a);
    receiver_open = false;
    receiver_compiler_facts.deinit();
    receiver_compiler_facts = .{ .allocator = a };
    try destination_namespace.close();
    destination_open = false;
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    destination_open = true;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    phase = "replay destination acceptance";
    try std.testing.expect(receiver.compiler_facts == null);
    try std.testing.expectEqualDeep(accepted, try acceptPlacement(&receiver, "recovered-acceptance", "source", offer, archive_path));
    var imported_work = try receiver.workspaceWork(a, subject.task, work_id);
    defer imported_work.deinit();
    try std.testing.expectEqualDeep(cut.outer, p.ObjectIdentity.optional(imported_work.value.outer_operation.?.capsule));
    try std.testing.expectEqualDeep(cut.checkpoint, p.ObjectIdentity.from(imported_work.value.checkpoint));
    try std.testing.expectEqualDeep(cut.runtime, p.ObjectIdentity.optional(imported_work.value.runtime));
    if (generated) |derived| {
        var inspection = std.heap.ArenaAllocator.init(a);
        defer inspection.deinit();
        const inspection_allocator = inspection.allocator();
        const candidate_bytes = (try destination_namespace.store.recordBytes(inspection_allocator, "workspace_candidate", try native.workspace.custodyId(inspection_allocator, subject.task, try nativeIdentity(derived.candidate)), subject.task)).?;
        var candidate = try contracts.decodeOwned(native.workspace.Candidate, inspection_allocator, candidate_bytes);
        defer candidate.deinit();
        for ([_]native.testing.state.Reference{ candidate.value.artifact, candidate.value.description.ancestor, candidate.value.description.guest, candidate.value.description.proposal, candidate.value.description.code, candidate.value.description.producer.? }) |ref| {
            try std.testing.expectEqualDeep(ref, try destination_namespace.store.objectReference(ref.digest, null));
        }
        try std.testing.expectEqualDeep(compatibility, try receiver.placementCompatibility(inspection_allocator, subject));
        try inspectGeneratedArchive(inspection_allocator, &receiver, subject.task, derived);
    }
    phase = "continue imported evaluator";
    _ = try receiver.workspacePump(scratch, "continue-outer", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = imported_work.value.execution_revision, .control_revision = imported_work.value.control_revision }, .base_quantum = 1 });
    var continued = try receiver.workspaceWork(a, subject.task, work_id);
    defer continued.deinit();
    try std.testing.expect(!std.meta.eql(continued.value.outer_operation.?.capsule, imported_work.value.outer_operation.?.capsule));
    try std.testing.expectEqual(imported_work.value.execution_revision, continued.value.execution_revision);
    if (scenario == .work) std.debug.print("semantic placement: cold restart continued at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    source_namespace = try native.Namespace.open(a, io, source_path);
    source_open = true;
    var source_profile = profile;
    source_profile.placement = &source_config;
    sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
    sender_open = true;
    try std.testing.expectError(error.CustodyNotLocal, sender.workspaceControl(scratch, "lost-ack", subject.task, work_id, cut.execution, cut.control, .advance));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementApplyDecision(scratch, subject, accepted));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    try sender.placementApplyDecision(scratch, subject, accepted);
    try sender.placementApplyDecision(scratch, subject, accepted);
    try std.testing.expectEqual(.away, (try sender.placementStatus(scratch, subject)).?.phase);
    try std.testing.expectError(error.CustodyNotLocal, sender.workspaceControl(scratch, "departed", subject.task, work_id, cut.execution, cut.control, .advance));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    phase = "remote controller inspection";
    const control_bytes = try sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } });
    var control = try contracts.decodeOwned(p.Signed(p.Control), scratch, control_bytes);
    defer control.deinit();
    try std.testing.expectEqualSlices(u8, control_bytes, try sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    try std.testing.expectError(error.OperationConflict, sender.placementControl(scratch, "remote-inspect", subject.task, .{ .park = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control } }));
    const controller_subject: p.Subject = .{ .task = subject.task };
    const controller_cut = try sender.placementCut(scratch, controller_subject);
    try std.testing.expectError(error.UnsettledRemoteControl, freezePlacement(&sender, controller_subject, "successor", controller_cut, @splat(16)));
    try sender.close(a);
    sender_open = false;
    try source_namespace.close();
    source_open = false;
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    destination_open = true;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = receiver.profile.authority;
        defer receiver.profile.authority = authority;
        const before = destination_namespace.store.head;
        @field(receiver.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, receiver.placementExecuteControl(scratch, "source", control.value));
        try std.testing.expectError(error.Denied, receiver.placementResolveControl(scratch, "source", control.value, &.{}));
        try std.testing.expectEqualDeep(before, destination_namespace.store.head);
    }
    const report_bytes = try receiver.placementExecuteControl(scratch, "source", control.value);
    try std.testing.expectEqualSlices(u8, report_bytes, try receiver.placementExecuteControl(scratch, "source", control.value));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = receiver.profile.authority;
        defer receiver.profile.authority = authority;
        const before = destination_namespace.store.head;
        @field(receiver.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, receiver.placementExecuteControl(scratch, "source", control.value));
        try std.testing.expectError(error.Denied, receiver.placementResolveControl(scratch, "source", control.value, &.{}));
        try std.testing.expectEqualDeep(before, destination_namespace.store.head);
    }
    var report = try contracts.decodeOwned(p.Signed(p.Report), scratch, report_bytes);
    defer report.deinit();
    try std.testing.expectEqual(.observed, report.value.value.reply.disposition);
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    source_namespace = try native.Namespace.open(a, io, source_path);
    source_open = true;
    sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
    sender_open = true;
    if (scenario == .work) sender.compiler_facts = &controller_compiler_facts;
    try sender.placementApplyReport(scratch, subject.task, p.controlId(control.value.value), report.value);
    try sender.placementApplyReport(scratch, subject.task, p.controlId(control.value.value), report.value);
    if (scenario == .onward) {
        const delayed_bytes = try sender.placementControl(scratch, "delayed-inspect", subject.task, .{ .inspect = .{ .work = work_ref } });
        var delayed = try contracts.decodeOwned(p.Signed(p.Control), scratch, delayed_bytes);
        defer delayed.deinit();
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        destination_namespace = try native.Namespace.open(a, io, destination_path);
        destination_open = true;
        receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
        receiver_open = true;
        const next_cut = try receiver.placementCut(scratch, subject);
        _ = try freezePlacement(&receiver, subject, "successor", next_cut, @splat(71));
        const next_path = try std.fmt.allocPrint(scratch, "{s}/onward.par", .{path_buffer[0..length]});
        const next_offer = try offerPlacement(&receiver, subject, "successor", next_path);
        try receiver.close(a);
        receiver_open = false;
        try destination_namespace.close();
        destination_open = false;
        var next_decision: p.Signed(p.Decision) = undefined;
        {
            successor_namespace = try native.Namespace.open(a, io, successor_path);
            defer successor_namespace.close() catch unreachable;
            var successor_profile = profile;
            successor_profile.placement = &successor_config;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
            defer successor.close(a) catch unreachable;
            next_decision = try acceptPlacement(&successor, "accept-onward", "destination", next_offer, next_path);
        }
        destination_namespace = try native.Namespace.open(a, io, destination_path);
        destination_open = true;
        receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
        receiver_open = true;
        try receiver.placementApplyDecision(scratch, subject, next_decision);
        var resolution = try contracts.decodeOwned(p.ControlResolution, scratch, try receiver.placementResolveControl(scratch, "source", delayed.value, &.{}));
        defer resolution.deinit();
        try std.testing.expect(resolution.value == .next);
        const route = [_]p.Succession{resolution.value.next};
        try std.testing.expectEqualDeep(next_decision, route[0].decision);
        try receiver.close(a);
        receiver_open = false;
        try destination_namespace.close();
        destination_open = false;
        source_namespace = try native.Namespace.open(a, io, source_path);
        source_open = true;
        sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
        sender_open = true;
        var forged = route[0];
        forged.offer.value.intent.epoch += 1;
        try std.testing.expectError(error.SignatureVerificationFailed, sender.placementFollowExecutor(scratch, subject.task, p.controlId(delayed.value.value), forged));
        inline for (.{ "principal", "tenant" }) |field| {
            const authority = sender.profile.authority;
            defer sender.profile.authority = authority;
            const before = source_namespace.store.head;
            const pending_before = try scratch.dupe(@TypeOf(sender.placement_pending.items[0]), sender.placement_pending.items);
            @field(sender.profile.authority, field) = "foreign";
            try std.testing.expectError(error.Denied, sender.placementFollowExecutor(scratch, subject.task, p.controlId(delayed.value.value), route[0]));
            try std.testing.expectEqualDeep(before, source_namespace.store.head);
            try std.testing.expectEqualDeep(pending_before, sender.placement_pending.items);
        }
        try sender.placementFollowExecutor(scratch, subject.task, p.controlId(delayed.value.value), route[0]);
        try std.testing.expectEqualDeep(successor_site, (try sender.placementStatus(scratch, subject)).?.owner);
        try std.testing.expectEqualSlices(u8, delayed_bytes, try sender.placementControl(scratch, "delayed-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        var delayed_report_bytes: []u8 = undefined;
        {
            successor_namespace = try native.Namespace.open(a, io, successor_path);
            defer successor_namespace.close() catch unreachable;
            var successor_profile = profile;
            successor_profile.placement = &successor_config;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
            defer successor.close(a) catch unreachable;
            const before = successor_namespace.store.head;
            var old_receipt = try contracts.decodeOwned(p.ControlResolution, scratch, try successor.placementResolveControl(scratch, "source", control.value, &route));
            defer old_receipt.deinit();
            try std.testing.expect(old_receipt.value == .report);
            try std.testing.expectEqualSlices(u8, report_bytes, try contracts.encodeOwned(p.Signed(p.Report), scratch, old_receipt.value.report));
            try std.testing.expectEqualDeep(before, successor_namespace.store.head);
            inline for (.{ "principal", "tenant" }) |field| {
                const authority = successor.profile.authority;
                defer successor.profile.authority = authority;
                @field(successor.profile.authority, field) = "foreign";
                try std.testing.expectError(error.Denied, successor.placementResolveControl(scratch, "source", control.value, &route));
                try std.testing.expectEqualDeep(before, successor_namespace.store.head);
            }
            disclosure.deny_runtime = true;
            try std.testing.expectError(error.DisclosureDenied, successor.placementResolveControl(scratch, "source", control.value, &route));
            disclosure.deny_runtime = false;
            const executed = try successor.placementResolveControl(scratch, "source", delayed.value, &route);
            var result = try contracts.decodeOwned(p.ControlResolution, scratch, executed);
            defer result.deinit();
            const delayed_report = result.value.report;
            delayed_report_bytes = try contracts.encodeOwned(p.Signed(p.Report), scratch, delayed_report);
            try std.testing.expectEqualDeep(successor_site, delayed_report.value.executor);
            try std.testing.expectEqual(next_decision.value.epoch, delayed_report.value.custody_epoch);
            const after = successor_namespace.store.head;
            try std.testing.expectEqualSlices(u8, executed, try successor.placementResolveControl(scratch, "source", delayed.value, &route));
            try std.testing.expectEqualDeep(after, successor_namespace.store.head);
            // This process owns the executor, while the copied controller is
            // still at A. Shutdown must cancel only its actual local work.
            const current_cut = try successor.placementCut(scratch, subject);
            _ = try successor.workspaceControl(scratch, "claim-onward-executor", subject.task, work_id, current_cut.execution, current_cut.control, .park);
            var before_cancel = try successor.workspaceWork(scratch, subject.task, work_id);
            defer before_cancel.deinit();
            try std.testing.expect(!before_cancel.value.terminal());
            try std.testing.expect(successor.owned.items.len != 0);
            const interrupt = "interrupt-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
            try std.testing.expectEqual(@as(usize, 74), interrupt.len);
            try successor.cancelOwned(scratch, interrupt, "stop local executor");
            var after_cancel = try successor.workspaceWork(scratch, subject.task, work_id);
            defer after_cancel.deinit();
            try std.testing.expect(after_cancel.value.cancellation != null);
            // Cancellation can finish synchronously. Unfinished local work is
            // incomplete; a remote controller copy is not a local obligation.
            try std.testing.expectEqual(!after_cancel.value.terminal(), try successor.shutdownIncomplete(scratch));
            var settled = false;
            for (0..512) |_| {
                _ = try successor.pump(scratch);
                if (!try successor.shutdownIncomplete(scratch)) {
                    settled = true;
                    break;
                }
            }
            try std.testing.expect(settled);
            var closed_work = try successor.workspaceWork(scratch, subject.task, work_id);
            defer closed_work.deinit();
            try std.testing.expect(closed_work.value.terminal());
            try std.testing.expectEqual(.away, (try successor.placementStatus(scratch, .{ .task = subject.task })).?.phase);
        }
        source_namespace = try native.Namespace.open(a, io, source_path);
        source_open = true;
        sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
        sender_open = true;
        var delayed_report = try contracts.decodeOwned(p.Signed(p.Report), scratch, delayed_report_bytes);
        defer delayed_report.deinit();
        try sender.placementApplyReport(scratch, subject.task, p.controlId(delayed.value.value), delayed_report.value);
        return;
    }
    // Advance the controller after its worker was exported. The worker has
    // never received this controller checkpoint, and a succession proof must
    // not require that private object to be retained locally.
    phase = "advance controller after export";
    _ = try sender.resumeTask(scratch, "advance-controller-after-export", subject.task, controller_cut.control);
    var advanced_controller = controller_cut;
    for (0..64) |_| {
        _ = try sender.pump(scratch);
        advanced_controller = try sender.placementCut(scratch, controller_subject);
        if (advanced_controller.execution > controller_cut.execution) break;
    }
    try std.testing.expect(advanced_controller.execution > controller_cut.execution);
    try std.testing.expect(!std.meta.eql(controller_cut.checkpoint, advanced_controller.checkpoint));
    phase = "prepare observer for controller transfer";
    const observed_source = try sender.workspaceStart(scratch, "placement-terminal-source", subject.task, program.receipt.workspace.?, &.{0}, .{});
    try observerCompleted(&sender, scratch, subject.task, observed_source.receipt.workspace.?);
    const remote_observer = try placementObserver(&sender, scratch, subject.task, program.receipt.workspace.?, observed_source.receipt.workspace.?, false);
    advanced_controller = try sender.placementCut(scratch, controller_subject);
    source_peers[1].compatibility = try sender.placementCompatibility(scratch, controller_subject);
    successor_peers[1].compatibility = source_peers[1].compatibility;
    phase = "transfer controller";
    if (scenario == .work) std.debug.print("semantic placement: transfer controller at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    _ = try freezePlacement(&sender, controller_subject, "successor", advanced_controller, @splat(16));
    const controller_archive = try std.fmt.allocPrint(scratch, "{s}/controller.par", .{path_buffer[0..length]});
    const controller_offer = try offerPlacement(&sender, controller_subject, "successor", controller_archive);
    try sender.close(a);
    sender_open = false;
    controller_compiler_facts.deinit();
    controller_compiler_facts = .{ .allocator = a };
    try source_namespace.close();
    source_open = false;
    var controller_decision: p.Signed(p.Decision) = undefined;
    var successor_control: contracts.Decoded(p.Signed(p.Control)) = undefined;
    {
        var compiler_facts: native.tasks.Service(OwnerTypes).CompilerFacts = .{ .allocator = a };
        defer compiler_facts.deinit();
        successor_namespace = try native.Namespace.open(a, io, successor_path);
        defer successor_namespace.close() catch unreachable;
        var successor_profile = profile;
        successor_profile.placement = &successor_config;
        var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
        defer successor.close(a) catch unreachable;
        if (scenario == .work) successor.compiler_facts = &compiler_facts;
        controller_decision = try acceptPlacement(&successor, "accept-controller", "source", controller_offer, controller_archive);
        try std.testing.expectEqual(.local, (try successor.placementStatus(scratch, controller_subject)).?.phase);
        try std.testing.expectEqual(.away, (try successor.placementStatus(scratch, subject)).?.phase);
        successor_control = try contracts.decodeOwned(p.Signed(p.Control), scratch, try successor.placementControl(scratch, "new-controller-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
    }
    if (scenario == .work) std.debug.print("semantic placement: controller accepted at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    defer successor_control.deinit();
    {
        var retained_namespace = try native.Namespace.open(a, io, source_path);
        defer retained_namespace.close() catch unreachable;
        var retained_owner = try native.tasks.Service(OwnerTypes).init(a, io, &retained_namespace, assets, &application, handlers, source_profile);
        defer retained_owner.close(a) catch unreachable;
        try retained_owner.placementApplyDecision(scratch, controller_subject, controller_decision);
    }
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    destination_open = true;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    try std.testing.expectError(error.MissingArtifact, receiver.namespace.store.objectReference(advanced_controller.checkpoint.digest, null));
    try std.testing.expectError(error.StaleController, receiver.placementExecuteControl(scratch, "successor", successor_control.value));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = receiver.profile.authority;
        defer receiver.profile.authority = authority;
        const before = destination_namespace.store.head;
        @field(receiver.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, receiver.placementFollowController(scratch, "source", "successor", controller_offer, controller_decision));
        try std.testing.expectEqualDeep(before, destination_namespace.store.head);
    }
    try receiver.placementFollowController(scratch, "source", "successor", controller_offer, controller_decision);
    try receiver.placementFollowController(scratch, "source", "successor", controller_offer, controller_decision);
    var stale_control = control.value.value;
    stale_control.operation = .{ .bytes = "late-old-controller" };
    try std.testing.expectError(error.StaleController, receiver.placementExecuteControl(scratch, "source", try p.sign(p.Control, scratch, source_key, stale_control)));
    const successor_report_bytes = try receiver.placementExecuteControl(scratch, "successor", successor_control.value);
    var successor_report = try contracts.decodeOwned(p.Signed(p.Report), scratch, successor_report_bytes);
    defer successor_report.deinit();
    try std.testing.expectEqual(.observed, successor_report.value.value.reply.disposition);
    try std.testing.expect(successor_report.value.value.work_state != null);
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    // Exercise the automatic parent-cancellation decision with real stores and
    // signed messages. This fixture carries the queued bytes between namespace
    // owners; the separate process fixture owns transport qualification.
    successor_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "successor" };
    successor_peers[1].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "successor" };
    var cleanup_control = successor_control.value;
    var cleanup_report = successor_report.value;
    var disposed = false;
    var parked_once = false;
    var observer_stopped = false;
    var resumed_after_park = false;
    phase = "cancel remote work and observer";
    if (scenario == .work) std.debug.print("semantic placement: remote cleanup at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    for (0..512) |iteration| {
        {
            var compiler_facts: native.tasks.Service(OwnerTypes).CompilerFacts = .{ .allocator = a };
            defer compiler_facts.deinit();
            successor_namespace = try native.Namespace.open(a, io, successor_path);
            defer successor_namespace.close() catch unreachable;
            var successor_profile = profile;
            successor_profile.placement = &successor_config;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
            defer successor.close(a) catch unreachable;
            if (scenario == .work) successor.compiler_facts = &compiler_facts;
            try successor.placementApplyReport(scratch, subject.task, p.controlId(cleanup_control.value), cleanup_report);
            attack_index = iteration;
            phase = "initial remote disposal state";
            if (iteration == 0) {
                try std.testing.expect(!try successor.associatedWorkDisposed(scratch, subject.task));
                if (generated) |derived| {
                    phase = "shared guest five-arm continuation comparison";
                    try sharedSuccessorComparison(
                        scratch,
                        &meter,
                        &successor,
                        subject.task,
                        selected_program,
                        derived,
                    );
                }
                _ = try successor.requestCancel(scratch, "cancel-with-remote-work", subject.task, "controller stopped");
                const replayed_control = try successor.placementControl(scratch, "new-controller-inspect", subject.task, .{ .inspect = .{ .work = work_ref } });
                try std.testing.expectEqualSlices(u8, try contracts.encodeOwned(p.Signed(p.Control), scratch, successor_control.value), replayed_control);
            }
            phase = "acknowledge explicit remote park";
            if (cleanup_report.value.work_state.?.explicitly_parked and !resumed_after_park) {
                try std.testing.expect(parked_once);
                _ = try successor.pump(scratch);
                var pending = try successor_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
                defer pending.deinit();
                while (try pending.step() == .row) {
                    var saved = try contracts.decodeOwned(p.ControlRecord, scratch, try pending.bytes(0));
                    defer saved.deinit();
                    try std.testing.expect(saved.value.report != null);
                }
                try std.testing.expect(try successor.shutdownIncomplete(scratch));
                _ = try successor.requestCancel(scratch, "fresh-cancel-after-remote-park", subject.task, "controller stopped");
                resumed_after_park = true;
            }
            phase = "finish controller after remote disposal";
            if (try successor.associatedWorkDisposed(scratch, subject.task)) {
                for (0..512) |_| {
                    _ = try successor.pump(scratch);
                    var task = try successor.task(scratch, subject.task);
                    defer task.deinit();
                    if (task.value.terminal()) {
                        try std.testing.expect(try successor.taskCleanupComplete(scratch, task.value));
                        disposed = true;
                        break;
                    }
                }
                break;
            }
            phase = "schedule remote cleanup control";
            try std.testing.expect(try successor.pump(scratch) != .work);
            var query = try successor_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
            defer query.deinit();
            var found = false;
            while (try query.step() == .row) {
                const saved = try contracts.decodeOwned(p.ControlRecord, scratch, try query.bytes(0));
                if (saved.value.report == null and std.mem.startsWith(u8, saved.value.control.value.operation.bytes, "cleanup-")) {
                    cleanup_control = saved.value.control;
                    found = true;
                    break;
                }
            }
            phase = "locate scheduled remote cleanup";
            try std.testing.expect(found);
        }
        {
            var compiler_facts: native.tasks.Service(OwnerTypes).CompilerFacts = .{ .allocator = a };
            defer compiler_facts.deinit();
            const at_source = std.meta.eql(cleanup_control.value.executor, source_site);
            var executor_namespace = try native.Namespace.open(a, io, if (at_source) source_path else destination_path);
            defer executor_namespace.close() catch unreachable;
            var executor = try native.tasks.Service(OwnerTypes).init(a, io, &executor_namespace, assets, &application, handlers, if (at_source) source_profile else resumed_profile);
            defer executor.close(a) catch unreachable;
            if (scenario == .work) executor.compiler_facts = &compiler_facts;
            const bytes = try executor.placementExecuteControl(scratch, "successor", cleanup_control);
            const decoded_report = try contracts.decodeOwned(p.Signed(p.Report), scratch, bytes);
            cleanup_report = decoded_report.value;
            phase = "check remote observer stop report";
            if (at_source) {
                try std.testing.expectEqualDeep(try nativeIdentity(remote_observer.work), cleanup_control.value.subject.work.?);
                const stopping = cleanup_control.value.command == .stop_observing;
                try std.testing.expectEqual(!stopping, cleanup_report.value.work_state.?.observer_active);
                observer_stopped = observer_stopped or stopping;
            }
            phase = "check remote cleanup disposition";
            if (cleanup_report.value.reply.disposition == .rejected) {
                try std.testing.expect(parked_once and !resumed_after_park);
                try std.testing.expect(cleanup_control.value.command == .pump);
                try std.testing.expect(cleanup_report.value.work_state.?.explicitly_parked);
            } else try std.testing.expectEqual(.observed, cleanup_report.value.reply.disposition);
            try std.testing.expectEqualSlices(u8, bytes, try executor.placementExecuteControl(scratch, "successor", cleanup_control));
            if (!parked_once and cleanup_control.value.command == .cancel) {
                const current = cleanup_report.value.work_state.?;
                _ = try executor.workspaceControl(scratch, "park-after-controller-cancel", subject.task, work_id, current.execution_revision, current.control_revision, .park);
                parked_once = true;
            }
        }
    }
    phase = "verify remote disposal completion";
    try std.testing.expect(disposed);
    if (scenario == .work) std.debug.print("semantic placement: remote cleanup completed at {d}ms\n", .{sharedElapsed(placement_started) / std.time.ns_per_ms});
    phase = "verify remote park and resume";
    try std.testing.expect(parked_once and resumed_after_park);
    phase = "verify remote observer stopped";
    try std.testing.expect(observer_stopped);
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
        std.debug.print("observer accumulator rejection: {s}\n", .{materialized.observation_json.bytes});
    try std.testing.expectEqual(.observed, materialized.disposition);
    var observed = try native.json.parse(a, materialized.observation_json.bytes, .{});
    defer observed.deinit();
    var reference = try native.values.fromJson(contracts.workspace.Ref, a, observed.value.object.get("value").?);
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
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "observer-owner-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "observer-owner-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "observer-owner-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "observer-owner-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var namespace = try native.Namespace.open(a, io, try std.fmt.allocPrint(scratch, "{s}/state", .{path_buffer[0..length]}));
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });
    const program = try semanticGuestProgram(scratch, &service, parent.receipt.task, "current-observer-program");
    const input = try contracts.encodeOwned(@import("workspace_sources.zig").SemanticGuestInput, scratch, .{ .yields = 300, .seed = 100 });
    const started = try service.workspaceStart(scratch, "current-observer-selection", parent.receipt.task, program, input, .{});
    var work = try service.workspaceWork(scratch, parent.receipt.task, started.receipt.workspace.?);
    defer work.deinit();
    const selection = try observerSelection(&service, scratch, parent.receipt.task, program, work.value);
    try observerCurrentOwnershipWitness(&service, scratch, parent.receipt.task, program, input, selection);
    try service.park(scratch);
    try outerObserverWitness(&service, scratch, parent.receipt.task, program, input, selection.accumulator);
}

fn observerCurrentOwnershipWitness(service: anytype, a: std.mem.Allocator, task: [16]u8, program: [32]u8, input: []const u8, original: contracts.workspace.Observe) !void {
    const started = try service.workspaceStart(a, "current-observer-source", task, program, input, .{});
    var current = try service.workspaceWork(a, task, started.receipt.workspace.?);
    defer current.deinit();
    var selection = original;
    selection.previous = null;
    var reads: [3]usize = undefined;
    for (0..16) |index| {
        selection.source.expected = .{
            .work = try workspaceRef(a, .work, current.value.id),
            .execution_revision = current.value.execution_revision,
            .control_revision = current.value.control_revision,
        };
        const observed = try service.workspaceObserve(a, try std.fmt.allocPrint(a, "current-observer-fold-{d}", .{index}), task, selection);
        try observerCompleted(service, a, task, observed.receipt.workspace.?);
        var unchanged = try service.workspaceWork(a, task, current.value.id);
        defer unchanged.deinit();
        try std.testing.expectEqualDeep(current.value, unchanged.value);
        var owner = try service.task(a, task);
        defer owner.deinit();
        try std.testing.expectEqual(@as(usize, 1), owner.value.observer_heads.items.len);
        try std.testing.expectEqualDeep(observed.receipt.workspace.?, owner.value.observer_heads.items[0]);
        if (selection.previous) |previous| {
            var prior = try service.workspaceWork(a, task, try nativeIdentity(previous));
            defer prior.deinit();
            try std.testing.expectEqual(@as(?[32]u8, observed.receipt.workspace.?), prior.value.observer.?.successor);
        }
        var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace));
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        try advanceObservedSource(service, a, current.value, try std.fmt.allocPrint(a, "current-observer-step-{d}", .{index}));
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 0, null, null));
        try std.testing.expectEqual(@as(usize, 0), trace.scans);
        if (index == 3 or index == 7 or index == 15) {
            const slot: usize = if (index == 3) 0 else if (index == 7) 1 else 2;
            reads[slot] = trace.work_reads;
            std.debug.print("current observer work reads: folds={d} reads={d} inventories={d}\n", .{ index + 1, trace.work_reads, trace.scans });
        }
        const next = try service.workspaceWork(a, task, current.value.id);
        current.deinit();
        current = next;
        selection.previous = try workspaceRef(a, .work, observed.receipt.workspace.?);
        if (index == 3 or index == 7 or index == 15)
            try currentObserverBatchWitness(service, a, task, current.value, true, try std.fmt.allocPrint(a, "folds-{d}", .{index + 1}));
    }
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
    selection.previous = null;
    selection.source.expected = .{
        .work = try workspaceRef(a, .work, current.value.id),
        .execution_revision = current.value.execution_revision,
        .control_revision = current.value.control_revision,
    };
    const older = try service.workspaceObserve(a, "parallel-observer-older", task, selection);
    try observerCompleted(service, a, task, older.receipt.workspace.?);
    try advanceObservedSource(service, a, current.value, "parallel-observer-source");
    const advanced = try service.workspaceWork(a, task, current.value.id);
    current.deinit();
    current = advanced;
    selection.source.expected.execution_revision = current.value.execution_revision;
    selection.source.expected.control_revision = current.value.control_revision;
    const newer = try service.workspaceObserve(a, "parallel-observer-newer", task, selection);
    try observerCompleted(service, a, task, newer.receipt.workspace.?);
    try currentObserverBatchWitness(service, a, task, current.value, true, "parallel-revisions");
    try std.testing.expectError(error.ObservationBlocked, advanceObservedSource(service, a, current.value, "parallel-observer-blocked"));
    for ([_][32]u8{ older.receipt.workspace.?, newer.receipt.workspace.? }, 0..) |id, i| {
        var observer = try service.workspaceWork(a, task, id);
        defer observer.deinit();
        _ = try service.workspaceStopObserving(a, try std.fmt.allocPrint(a, "parallel-observer-stop-{d}", .{i}), task, .{
            .work = try workspaceRef(a, .work, id),
            .execution_revision = observer.value.execution_revision,
            .control_revision = observer.value.control_revision,
        });
        try currentObserverBatchWitness(service, a, task, current.value, false, try std.fmt.allocPrint(a, "parallel-stop-{d}", .{i}));
    }
}

fn observerOwnershipTamper(service: anytype, a: std.mem.Allocator, work: native.workspace.Work) !void {
    var owner = try service.task(a, work.task);
    defer owner.deinit();
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &digest, .{});
    const manifest: native.testing.state.Reference = .{ .digest = digest, .bytes = service.assets.manifest.len };
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
        try service.namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{ .blob = &reference.digest }, .{ .blob = &work.task } });
        const index = try service.namespace.store.archiveIndex(a, work.task, manifest);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts));
    }
    {
        try service.namespace.store.begin();
        defer service.namespace.store.rollback();
        const previous = try nativeIdentity(work.observer.?.selection.previous.?);
        var prior = try service.workspaceWork(a, work.task, previous);
        defer prior.deinit();
        prior.value.observer.?.successor = null;
        try service.namespace.store.putRecord(native.workspace.Work, "workspace_work", previous, work.task, prior.value);
        const index = try service.namespace.store.archiveIndex(a, work.task, manifest);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts));
    }
}

fn staleObserverRetry(service: anytype, a: std.mem.Allocator, task: [16]u8, program: [32]u8, input: []const u8, original: contracts.workspace.Observe) !void {
    const started = try service.workspaceStart(a, "retry-observer-source", task, program, input, .{});
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
    try std.testing.expectError(error.OutOfMemory, service.workspaceObserve(failing.allocator(), "retry-observer", task, selection));
    try std.testing.expect(failing.rejected != 0);
    try advanceObservedSource(service, a, source_work.value, "retry-observer-advance-one");
    var middle = try service.workspaceWork(a, task, source_work.value.id);
    defer middle.deinit();
    try advanceObservedSource(service, a, middle.value, "retry-observer-advance-two");
    try std.testing.expectError(error.StaleRevision, service.workspaceObserve(a, "retry-observer", task, selection));
    var current = try service.workspaceWork(a, task, source_work.value.id);
    defer current.deinit();
    selection.source.expected.execution_revision = current.value.execution_revision;
    selection.source.expected.control_revision = current.value.control_revision;
    selection.policy.continuation = .owner_scheduled;
    const fresh = try service.workspaceObserve(a, "retry-observer-fresh", task, selection);
    try observerCompleted(service, a, task, fresh.receipt.workspace.?);
    var observed = try service.workspaceWork(a, task, fresh.receipt.workspace.?);
    defer observed.deinit();
    try std.testing.expectEqual(current.value.execution_revision, observed.value.observer.?.consumed_revision.?);
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

fn automaticObserverRetry(service: anytype, a: std.mem.Allocator, observer: native.workspace.Work, source_work: native.workspace.Work) ![32]u8 {
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
    try std.testing.expectEqual(null, try observerSuccessor(service, a, observer.task, observer.id));
    _ = try service.workspaceControl(a, "automatic-observer-source-park", advanced.value.task, advanced.value.id, advanced.value.execution_revision, advanced.value.control_revision, .park);
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
            try std.testing.expectEqual(advanced.value.execution_revision, completed.value.observer.?.consumed_revision.?);
            for (0..4) |_| _ = try service.pump(a);
            try std.testing.expectEqual(id, (try observerSuccessor(service, a, observer.task, observer.id)).?);
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
    observer.selection.source.disclosure.?.values = .{ .nodes = .{ .selected = .{ .items = &nodes } } };
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
    try observerArchiveTamper(service, a, folded.value);
    try observerCopyOwnership(folded.value.observer.?);
    try std.testing.expectEqual(
        advanced.value.execution_revision,
        folded.value.observer.?.consumed_revision.?,
    );
    try std.testing.expectEqual(null, folded.value.observer.?.gap_first);
    const replay = try service.workspaceCommand(a, "observed-source-step", task, advance);
    try std.testing.expectEqualStrings(blocked.observation_json.bytes, replay.observation_json.bytes);
    try observerFoldValue(service, a, folded.value, source_work.execution_revision +
        advanced.value.execution_revision);
    var unchanged = try service.workspaceWork(a, task, source_work.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(advanced.value.checkpoint, unchanged.value.checkpoint);
    try advanceObservedSource(service, a, unchanged.value, "observer-source-after-fold");
    const historical = try service.workspaceObserve(a, "observe-second", task, selection.*);
    try std.testing.expect(historical.replayed);
    try std.testing.expectEqualDeep(second.receipt.id, historical.receipt.id);
    try cancelObservedSourceWitness(service, a, task, source_work.id, folded.value.id);
    try incompleteObserverWitness(service, a, task, selection.*);
    try lateObserverWitness(service, a, task, program, input, selection.*);
    try outerObserverWitness(service, a, task, program, input, selection.accumulator);
    var scheduled = try sampledObserverWitness(service, a, task, program, input, selection.*);
    scheduled.parked_source = source_work.id;
    return .{
        .selection = selection.*,
        .work = folded.value.id,
        .receipt = second.receipt.id,
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
    _ = try service.workspaceControl(a, "park-observed-cancellation", task, id, after.value.execution_revision, after.value.control_revision, .park);
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
    const result = try builder.pure(try builder.primitive(number, .cell_get, &.{try builder.reference(allocated)}, 0));
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
    try std.testing.expectEqual(advanced.value.guest_work, decoded.value.selected.envelope.guest_work_delta.?);
}

fn finishLateObserverSource(service: anytype, a: std.mem.Allocator, initial: native.workspace.Work) !void {
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
    try std.testing.expectEqual(.explicit_only, observer.value.observer.?.selection.policy.continuation);
    try std.testing.expect(!observer.value.observer.?.stopped);
    try std.testing.expectEqual(.away, (try service.placementStatus(a, .{ .task = task })).?.phase);
    var source_work = try service.workspaceWork(a, task, observer.value.observer.?.source_work);
    defer source_work.deinit();
    _ = try service.workspaceControl(a, "claim-local-observer-source", task, source_work.value.id, source_work.value.execution_revision, source_work.value.control_revision, .park);
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
            try std.testing.expectEqual(null, try observerSuccessor(service, a, folded.task, folded.id));
            try std.testing.expectError(error.ActiveObserverMobilityUnsupported, service.placementCompatibility(a, .{
                .task = folded.task,
                .work = source_work.id,
            }));
            for (0..8) |_| _ = try service.pump(a);
            var stable = try service.workspaceWork(a, folded.task, folded.id);
            defer stable.deinit();
            try std.testing.expectEqual(current.value.event_watermark, stable.value.event_watermark);
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

fn incompleteObserverTamper(service: anytype, a: std.mem.Allocator, work: native.workspace.Work) !void {
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
                const custody = try native.workspace.custodyId(a, work.task, work.observer.?.source.digest);
                const encoded = (try service.namespace.store.recordBytes(a, "workspace_value", custody, work.task)).?;
                defer a.free(encoded);
                var value = try contracts.decodeOwned(native.workspace.Value, a, encoded);
                defer value.deinit();
                const snapshot = try contracts.encodeOwned(native.workspace.WorkObservation, a, value.value.derivation.inspection.?.observation);
                defer a.free(snapshot);
                forged.observer.?.incomplete.?.source = try service.namespace.store.putObject(snapshot);
            },
            else => unreachable,
        }
        try service.namespace.store.putRecord(native.workspace.Work, "workspace_work", work.id, work.task, forged);
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
        const publications = try a.dupe(native.testing.state.WorkPublication, event.value.workspace_publications.items);
        defer a.free(publications);
        event.value.workspace_publications.items = publications;
        for (publications) |*publication| if (std.meta.eql(publication.work, work.id)) {
            publication.observer = forged.observer;
            publication.observation = observation.digest;
        };
        const encoded = try contracts.encodeOwned(native.testing.state.Event, a, event.value);
        defer a.free(encoded);
        const reference = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &reference.digest }, .{ .blob = &work.task }, .{ .integer = @intCast(work.event_watermark) } });
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(a, work.task, index.records.items, &facts));
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
    _ = try service.workspaceControl(a, "fresh-observed-cancel", task, id, before.value.execution_revision, before.value.control_revision, .{ .cancel = .{ .bytes = "resume observed cancellation" } });
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
    var selection: contracts.workspace.Observe = .{
        .program = try workspaceRef(a, .program, built.receipt.workspace.?),
        .source = .{ .expected = .{
            .work = try workspaceRef(a, .work, source_work.value.id),
            .execution_revision = source_work.value.execution_revision,
            .control_revision = source_work.value.control_revision,
        }, .realization_revision = 0, .nodes = .{ .all = .{} }, .level = .outer_execution },
        .accumulator = accumulator,
        .policy = .{ .delivery = .lossless, .granularity = .one_guest_step, .continuation = .owner_scheduled },
    };
    const first = try service.workspaceObserve(a, "outer-observer-first", task, selection);
    try observerCompleted(service, a, task, first.receipt.workspace.?);
    try currentObserverBatchWitness(service, a, task, source_work.value, false, "outer-consumed");
    {
        var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
        const database = CleanupTrace.sqlite3_db_handle(statement.handle);
        statement.deinit();
        var trace: CleanupTrace = .{};
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 1, CleanupTrace.observe, &trace));
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        try advanceObservedSource(service, a, source_work.value, "outer-observed-advance");
        try std.testing.expectEqual(@as(usize, 0), trace.scans);
        try std.testing.expectEqual(@as(usize, 0), trace.history_scans);
        std.debug.print("live outer observer: inventory_scans={d} history_scans={d}\n", .{ trace.scans, trace.history_scans });
    }
    var advanced = try service.workspaceWork(a, task, source_work.value.id);
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
    for (0..128) |_| {
        _ = try service.pump(a);
        var current = try service.workspaceWork(a, task, folded.value.id);
        defer current.deinit();
        if (current.value.observer.?.incomplete) |incomplete| {
            try std.testing.expectEqual(.outer_cut_unavailable, incomplete.diagnostic);
            try std.testing.expectEqualDeep(folded.value.checkpoint, current.value.checkpoint);
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

fn observerArchiveRoundTrip(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    previous: [32]u8,
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
        source_namespace.* = native.Namespace.open(allocator, io, source_path) catch unreachable;
        service.* = native.tasks.Service(OwnerTypes).init(
            allocator,
            io,
            source_namespace,
            assets,
            application,
            handlers,
            profile,
        ) catch unreachable;
    }
    var namespace = try native.Namespace.open(allocator, io, copy_path);
    defer namespace.close() catch unreachable;
    var copied = try native.tasks.Service(OwnerTypes).init(
        allocator,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer copied.close(allocator) catch unreachable;
    _ = copied.importCheckpoint(a, "completed-observer-import", archive_path) catch |err| {
        std.debug.print("observer archive import: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqual(successor, (try observerSuccessor(&copied, a, task, previous)).?);
    var actual = try copied.workspaceWork(a, task, successor);
    defer actual.deinit();
    try std.testing.expectEqualDeep(expected.value, actual.value);
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

fn observerArchiveTamper(service: anytype, a: std.mem.Allocator, work: native.workspace.Work) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &digest, .{});
    const index = try service.namespace.store.archiveIndex(a, work.task, .{
        .digest = digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(work.task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(service.allocator, work.task, index.records.items, &facts);
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
            0 => observer.selection.accumulator = try workspaceRef(a, .value, observer.source.digest),
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

fn observerArchiveFields(original: native.workspace.Observer, forged: native.workspace.Observer) native.workspace.Observer {
    var value = original;
    value.selection = forged.selection;
    value.previous = forged.previous;
    return value;
}

fn rewriteObserverArchive(service: anytype, a: std.mem.Allocator, work: native.workspace.Work) !void {
    try service.namespace.store.putRecord(native.workspace.Work, "workspace_work", work.id, work.task, work);
    var query = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq",
        &.{.{ .blob = &work.task }},
    );
    defer query.deinit();
    var start_revision: ?u64 = null;
    while (try query.step() == .row) {
        var event = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
        defer event.deinit();
        var found = false;
        for (@constCast(event.value.workspace_publications.items)) |*publication| {
            if (!std.meta.eql(publication.work, work.id)) continue;
            var bytes = try service.namespace.store.database.prepare("SELECT body FROM objects WHERE digest=?", &.{.{ .blob = &publication.observation }});
            defer bytes.deinit();
            try std.testing.expect(try bytes.step() == .row);
            var snapshot = try contracts.decodeOwned(native.workspace.WorkObservation, a, try bytes.bytes(0));
            defer snapshot.deinit();
            snapshot.value.work.observer = observerArchiveFields(snapshot.value.work.observer.?, work.observer.?);
            publication.observer = observerArchiveFields(publication.observer.?, work.observer.?);
            const encoded = try contracts.encodeOwned(native.workspace.WorkObservation, a, snapshot.value);
            defer a.free(encoded);
            publication.observation = (try service.namespace.store.putObject(encoded)).digest;
            found = true;
        }
        if (!found) continue;
        if (event.value.workspace_command) |ref| {
            const bytes = try service.namespace.store.object(a, ref, null);
            defer a.free(bytes);
            var command = try contracts.decodeOwned(native.workspace.PublicationCommand, a, bytes);
            defer command.deinit();
            if (command.value == .start) {
                command.value.start.observer = observerArchiveFields(command.value.start.observer.?, work.observer.?);
                const encoded = try contracts.encodeOwned(native.workspace.PublicationCommand, a, command.value);
                defer a.free(encoded);
                event.value.workspace_command = try service.namespace.store.putObject(encoded);
                try std.testing.expectEqual(null, start_revision);
                start_revision = event.value.revision;
            }
        }
        const encoded = try contracts.encodeOwned(native.testing.state.Event, a, event.value);
        defer a.free(encoded);
        const ref = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{
            .{ .blob = &ref.digest }, .{ .blob = &work.task }, .{ .integer = @intCast(event.value.seq) },
        });
    }
    try rewriteObserverReceipts(service, a, work, start_revision orelse return error.MissingObserverStart);
}

fn rewriteObserverReceipts(service: anytype, a: std.mem.Allocator, work: native.workspace.Work, start_revision: u64) !void {
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
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &work.task }},
    );
    defer query.deinit();
    while (try query.step() == .row) {
        var receipt = try contracts.decodeOwned(native.testing.state.Receipt, a, try query.bytes(1));
        defer receipt.deinit();
        if (receipt.value.workspace_kind != .work or !std.meta.eql(receipt.value.workspace, @as(?[32]u8, work.id))) continue;
        const bytes = try service.namespace.store.object(a, receipt.value.workspace_observation.?, null);
        defer a.free(bytes);
        var observed = try contracts.decodeOwned(native.workspace.WorkObservation, a, bytes);
        defer observed.deinit();
        observed.value.work.observer = observerArchiveFields(observed.value.work.observer.?, work.observer.?);
        const snapshot = try contracts.encodeOwned(native.workspace.WorkObservation, a, observed.value);
        defer a.free(snapshot);
        receipt.value.workspace_observation = try service.namespace.store.putObject(snapshot);
        if (receipt.value.revision == start_revision) receipt.value.request_digest = digest;
        const encoded = try contracts.encodeOwned(native.testing.state.Receipt, a, receipt.value);
        defer a.free(encoded);
        const reference = try service.namespace.store.putObject(encoded);
        try service.namespace.store.database.run("UPDATE operations SET receipt=?,request=? WHERE id=?", &.{
            .{ .blob = &reference.digest }, .{ .blob = &receipt.value.request_digest }, .{ .text = try query.bytes(0) },
        });
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

fn stopDiscoveredObserver(service: anytype, a: std.mem.Allocator, work: native.workspace.Work) !void {
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
    if (current != null and previous != null and !std.meta.eql(current.?, previous.?)) revision += 1;
    return .{ .revision = revision, .last = if (current orelse previous) |capsule| capsule.digest else null };
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
        std.debug.print("outer cursors: publications={d} ordered_reference_visits={d} indexed_folds={d}\n", .{
            count, count * count, count,
        });
        if (count == 10) try std.testing.checkAllAllocationFailures(a, allocatePublicationPrefix, .{items});
    }
}

const HistoricalObserverTrace = struct {
    scans: usize = 0,
    rows: usize = 0,
    extern "c" fn sqlite3_sql(?*anyopaque) ?[*:0]const u8;

    fn observe(kind: c_uint, context: ?*anyopaque, statement: ?*anyopaque, sql: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const text = if (kind == 1)
            std.mem.span(@as([*:0]const u8, @ptrCast(sql.?)))
        else
            std.mem.span(sqlite3_sql(statement) orelse return 0);
        if (std.mem.eql(u8, text, "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq<=? ORDER BY e.seq")) {
            if (kind == 1) self.scans += 1 else if (kind == 4) self.rows += 1;
        }
        return 0;
    }
};

fn currentObserverBatchWitness(service: anytype, a: std.mem.Allocator, task: [16]u8, work: native.workspace.Work, blocked: bool, label: []const u8) !void {
    var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
    const database = CleanupTrace.sqlite3_db_handle(statement.handle);
    statement.deinit();
    const ref = try workspaceRef(a, .work, work.id);
    const refs: [4]contracts.workspace.Ref = @splat(ref);
    var parent = try service.task(a, task);
    defer parent.deinit();
    for (0..3) |kind| {
        var trace: HistoricalObserverTrace = .{};
        try std.testing.expectEqual(@as(c_int, 0), CleanupTrace.sqlite3_trace_v2(database, 1 | 4, HistoricalObserverTrace.observe, &trace));
        defer std.debug.assert(CleanupTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
        const command: contracts.workspace.Command = .{ .work = switch (kind) {
            0 => .{ .inspect = .{ .work = ref } },
            1 => .{ .collect = .{ .works = .{ .items = &refs } } },
            2 => .{ .wait = .{ .works = .{ .items = &refs }, .after = 0 } },
            else => unreachable,
        } };
        const reply = try service.workspaceCommand(a, try std.fmt.allocPrint(a, "observer-current-{s}-{d}", .{ label, kind }), task, command);
        try std.testing.expectEqual(.observed, reply.disposition);
        try std.testing.expectEqual(@as(usize, 0), trace.scans);
        try std.testing.expectEqual(@as(usize, 0), trace.rows);
        var observation = try native.json.parseAsset(a, reply.observation_json.bytes, reply.observation_json.bytes.len);
        defer observation.deinit();
        const items: []const native.json.Value = switch (kind) {
            0 => &.{observation.value},
            1 => observation.value.array.items,
            2 => observation.value.object.get("works").?.array.items,
            else => unreachable,
        };
        try std.testing.expectEqual(if (kind == 0) @as(usize, 1) else refs.len, items.len);
        for (items) |item| try std.testing.expectEqual(blocked, item.object.get("observation_blocked").?.bool);
        std.debug.print("current observer projection: case={s} kind={d} works={d} events={d} scans={d} decoded_event_rows={d}\n", .{
            label, kind, items.len, parent.value.event_high, trace.scans, trace.rows,
        });
    }
}
