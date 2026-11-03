const std = @import("std");
const native = @import("protean_native");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const t = @import("adaptive_types");
const recovery = @import("projection_recovery.zig");
const cleanup = @import("native_test_support.zig").cleanup;
const Fixture = recovery.Fixture;
const ns = native.testing.state;
const wc = contracts.workspace;
const Snapshots = native.testing.workspace_snapshots.Operations(t, native.tasks.Service(t));
const amendment = "The current domain revision is eight. Keep the unresolved sibling.";

const Rejected = struct {
    event: ns.Event,
    prepared: []const u8,
    pending: t.PendingResults,
    request: []const u8,
    attempts: u64,
};

fn proposal(f: *Fixture) !wc.Ref {
    const program = try f.buildSource(
        try native.program_construction.projectionExample(f.permanent),
        &.{},
    );
    const consumer = try f.consumer();
    const input = try f.ownerMaterialize(program.input_schema, try f.json(
        wc.ProjectionInput(u64),
        .{ .consumer = consumer, .value = 73 },
    ), &.{});
    return (try f.ownerRun(program.program, input)).result;
}

fn lastEvent(f: *Fixture, sequence: u64) !ns.Event {
    const records = try f.namespace.store.eventsAfter(f.permanent, f.task, sequence - 1, 1);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    return (try contracts.decodeOwned(ns.Event, f.permanent, records[0])).value;
}

fn rejectAfterReady(f: *Fixture, selected: wc.Ref) !Rejected {
    try f.send(.{ .context = .{ .command = .{ .select = .{ .projected = selected } } } });
    var prepared: ?[]const u8 = null;
    var pending: t.PendingResults = undefined;
    var attempts: u64 = 0;
    for (0..4096) |_| {
        const step = try f.service.pump(f.permanent);
        if (step == .work) {
            try std.testing.expect(!step.work.entry.declaration.inference);
            const is_prepare = std.mem.eql(
                u8,
                step.work.entry.declaration.identity,
                t.prepare_identity,
            );
            const saved = if (is_prepare)
                try f.permanent.dupe(u8, step.work.prepared.?)
            else
                &.{};
            try f.complete(step.work);
            if (is_prepare and prepared == null) {
                const product = (try contracts.decodeOwned(
                    t.PreparationProduct,
                    f.permanent,
                    saved,
                )).value;
                if (product.result == .ready and
                    product.result.ready.request.plan.research != null)
                {
                    prepared = saved;
                    pending = product.result.ready.results;
                    attempts = (try f.service.task(f.permanent, f.task)).value.inference_attempts;
                    _ = try f.service.message(f.permanent, "late-projection-amendment", f.task, .{
                        .message = .{ .bytes = amendment },
                    });
                }
            }
        }
        const task = (try f.service.task(f.permanent, f.task)).value;
        try std.testing.expect(task.blocker == null);
        const event = try lastEvent(f, task.event_high);
        if (event.kind == .preparation_rejected) return .{
            .event = event,
            .prepared = prepared orelse return error.RejectedBeforeReady,
            .pending = pending,
            .attempts = attempts,
            .request = try f.namespace.store.object(
                f.permanent,
                event.preparation_rejection.?.occurrence.request_object,
                null,
            ),
        };
    }
    return error.LateProjectionRejectionDidNotArrive;
}

fn validateArchive(f: *Fixture) !void {
    var hash: ns.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.assets.manifest, &hash, .{});
    const index = try f.namespace.store.archiveIndex(f.permanent, f.task, .{
        .digest = hash,
        .bytes = f.assets.manifest.len,
    });
    const task = (try f.service.task(f.permanent, f.task)).value;
    try Snapshots.validateWorkspaceArchive(
        &f.service,
        f.permanent,
        task,
        index.records.items,
        .inspect,
    );
}

fn replyBytes(f: *Fixture, digest: ns.Digest) ![]u8 {
    return f.namespace.store.object(
        f.permanent,
        try f.namespace.store.objectReference(digest, null),
        null,
    );
}

fn requireLocalSettlement(f: *Fixture, rejected: Rejected) !void {
    const frozen = rejected.event.preparation_rejection.?.occurrence;
    const acquired = frozen.state.settled_reply;
    inline for (.{ "attempt", "capture" }) |kind| {
        try std.testing.expect((try f.namespace.store.recordBytes(
            f.permanent,
            kind,
            acquired.attempt,
            f.task,
        )) == null);
    }
    const task = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectEqual(rejected.attempts, task.inference_attempts);
    try std.testing.expectEqual(@as(usize, 1), rejected.pending.items.len);
    const bound = (try horos.data.invocation.decode(
        horos.data.invocation.Result,
        f.permanent,
        try replyBytes(f, acquired.reply),
    )).value;
    const reply = (try contracts.decodeOwned(t.P.AdaptiveResult, f.permanent, bound.value)).value;
    try std.testing.expectEqual(.stale, reply.result.preparation_rejected.code);
    try std.testing.expect(reply.replay == null and reply.usage == null);
    try std.testing.expectEqual(.unsupported, reply.replay_status);
}

fn rejectForgedDiagnostic(f: *Fixture, rejected: Rejected) !void {
    var event = rejected.event;
    const frozen = &event.preparation_rejection.?.occurrence;
    const acquired = frozen.state.settled_reply;
    const bound = (try horos.data.invocation.decode(
        horos.data.invocation.Result,
        f.permanent,
        try replyBytes(f, acquired.reply),
    )).value;
    var reply = (try contracts.decodeOwned(t.P.AdaptiveResult, f.permanent, bound.value)).value;
    reply.result.preparation_rejected.code = .invalid;
    var facts = try f.service.prepareWorkspaceValidation(f.task);
    defer facts.deinit();
    const prior = f.service.compiler_facts;
    f.service.compiler_facts = &facts;
    defer f.service.compiler_facts = prior;
    try f.namespace.store.begin();
    defer f.namespace.store.rollback();
    const altered_reply = try f.namespace.store.putObject(try horos.data.invocation.encodeOwned(
        horos.data.invocation.Result,
        f.permanent,
        .{
            .request_identity = bound.request_identity,
            .value = try contracts.encodeOwned(t.P.AdaptiveResult, f.permanent, reply),
        },
    ));
    frozen.state.settled_reply.reply = altered_reply.digest;
    const altered_occurrence = try f.namespace.store.putObject(try contracts.encodeOwned(
        native.testing.occurrence.Occurrence,
        f.permanent,
        frozen.*,
    ));
    const altered_event = try f.namespace.store.putObject(try contracts.encodeOwned(
        ns.Event,
        f.permanent,
        event,
    ));
    try f.namespace.store.database.run(
        "UPDATE records SET body=? WHERE kind='occurrence' AND id=? AND task=?",
        &.{
            .{ .blob = &altered_occurrence.digest },
            .{ .blob = &frozen.id },
            .{ .blob = &f.task },
        },
    );
    try f.namespace.store.database.run(
        "UPDATE events SET body=? WHERE task=? AND seq=?",
        &.{
            .{ .blob = &altered_event.digest },
            .{ .blob = &f.task },
            .{ .integer = @intCast(event.seq) },
        },
    );
    try std.testing.expectError(error.InvalidArchive, validateArchive(f));
}

fn importRejected(f: *Fixture) !void {
    const archive = try std.fmt.allocPrint(f.permanent, "{s}/late.agnx", .{f.directory});
    _ = try f.service.exportCheckpoint(f.permanent, f.task, archive);
    try f.service.close(f.a);
    try f.namespace.close();
    f.live = false;
    const destination = try std.fmt.allocPrint(f.permanent, "{s}/late-import", .{f.directory});
    f.namespace = try native.Namespace.open(f.a, f.io, destination);
    f.service = native.tasks.Service(t).init(
        f.a,
        f.io,
        &f.namespace,
        f.assets,
        &f.application,
        f.handlers,
        f.profile,
    ) catch |err| {
        cleanup("late imported namespace.close", f.namespace.close());
        return err;
    };
    f.live = true;
    const imported = try f.service.importCheckpoint(f.permanent, "late-import", archive);
    try std.testing.expectEqualDeep(f.task, imported.receipt.task);
    const copied = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectError(error.CustodyNotLocal, f.service.resumeTask(
        f.permanent,
        "late-import-resume",
        f.task,
        copied.revision,
    ));
    try recovery.reopen(f);
}

fn requireFallback(f: *Fixture, rejected: Rejected) !void {
    const prepared = (try contracts.decodeOwned(
        t.PreparationProduct,
        f.permanent,
        rejected.prepared,
    )).value.result.ready;
    try std.testing.expectEqualDeep(prepared.request.plan.prior, f.prepared.request.plan.prior);
    try std.testing.expect(f.prepared.selected_view == null);
    try std.testing.expect(f.prepared.request.plan.research == null);
    try std.testing.expectEqual(.projection_recovery, f.prepared.request.plan.reason);
    try std.testing.expectEqual(rejected.pending.items.len, f.prepared.request.results.items.len);
    try std.testing.expectEqualStrings(
        rejected.pending.items[0].call_id.bytes,
        f.prepared.request.results.items[0].call_id.bytes,
    );
    for ([_][]const u8{
        "Projection preparation rejected: stale.",
        amendment,
        "domain 41 revision 7",
        "An unavailable member is incomplete, never absent.",
    }) |text| try std.testing.expect(std.mem.indexOf(u8, f.prepared.body.bytes, text) != null);
    const frozen = rejected.event.preparation_rejection.?.occurrence;
    try std.testing.expectEqualSlices(
        u8,
        rejected.request,
        try f.namespace.store.object(f.permanent, frozen.request_object, null),
    );
    const task = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectEqual(rejected.attempts + 1, task.inference_attempts);
    try std.testing.expect(!task.terminal());
}

fn requirePriorState(f: *Fixture, rejected: Rejected) !void {
    var query = try f.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.kind='attempt' AND r.task=?",
        &.{.{ .blob = &f.task }},
    );
    defer query.deinit();
    var found: usize = 0;
    while (try query.step() == .row) {
        const attempt = (try contracts.decodeOwned(
            ns.Attempt,
            f.permanent,
            try query.bytes(0),
        )).value;
        if (!std.mem.eql(u8, attempt.capability.bytes, t.prepare_identity)) continue;
        const request = (try horos.data.invocation.decode(
            horos.data.invocation.Request,
            f.permanent,
            try f.namespace.store.object(f.permanent, attempt.request, null),
        )).value;
        const input = (try contracts.decodeOwned(
            t.Preparation,
            f.permanent,
            request.binding.payload,
        )).value;
        if (input.state.control.epoch_reason != .projection_recovery or
            input.state.model_calls != f.calls) continue;
        found += 1;
        try std.testing.expectEqualDeep(rejected.pending, input.state.results);
    }
    try std.testing.expectEqual(@as(usize, 1), found);
}

fn unknownRemainsUnknown(f: *Fixture, rejected: Rejected) !void {
    const request = f.pending;
    try f.service.completeWork(f.permanent, request, .unknown);
    var before = try f.service.task(f.permanent, f.task);
    defer before.deinit();
    try std.testing.expectError(error.UnsettledOccurrence, f.service.resumeTask(
        f.permanent,
        "late-unknown-resume",
        f.task,
        before.value.revision,
    ));
    for (0..3) |_| try std.testing.expect(try f.service.pump(f.permanent) != .work);
    const task = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectEqual(rejected.attempts + 1, task.inference_attempts);
    const saved = (try contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        f.permanent,
        (try f.namespace.store.recordBytes(
            f.permanent,
            "occurrence",
            request.occurrence,
            f.task,
        )).?,
    )).value;
    try std.testing.expectEqual(.unknown, std.meta.activeTag(saved.state));
}

pub fn assertSuccessorFallback(f: *Fixture, selected: wc.Ref) !void {
    const rejected = try rejectAfterReady(f, selected);
    try requireLocalSettlement(f, rejected);
    try recovery.reopen(f);
    try f.next();
    try requireFallback(f, rejected);
    try requirePriorState(f, rejected);
}

test "late projected preparation rejection survives archive and recovers without dispatch charge" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const sibling = try recovery.sibling(&f);
    const selected = try proposal(&f);
    const rejected = try rejectAfterReady(&f, selected);
    try requireLocalSettlement(&f, rejected);
    try recovery.requireSibling(&f, sibling);
    try validateArchive(&f);
    try rejectForgedDiagnostic(&f, rejected);
    try importRejected(&f);
    try f.next();
    try requireFallback(&f, rejected);
    try requirePriorState(&f, rejected);
    try recovery.requireSibling(&f, sibling);
    try unknownRemainsUnknown(&f, rejected);
}
