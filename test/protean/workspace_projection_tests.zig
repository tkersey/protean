const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const recovery = @import("projection_recovery.zig");
const support = @import("workspace_test_support.zig");
const cleanup = @import("native_test_support.zig").cleanup;
const t = @import("adaptive_types");
const wc = contracts.workspace;
const Fixture = recovery.Fixture;
const Snapshots = native.testing.workspace_snapshots.Operations(t, native.tasks.Service(t));
const Aggregate = struct { total: u64, missing: contracts.Vector(u64, null) };
const Input = wc.ProjectionInput(Aggregate);
const Result = wc.ProjectionResult(Aggregate);
const Presentation = struct {
    blocks: contracts.Vector(wc.PresentationBlock, null),
    value: Aggregate,
};
const PresentedInput = wc.ProjectionInput(Presentation);
const Mode = enum { projected, wrong_schema, impure, presented };
const aggregate: Aggregate = .{ .total = 73, .missing = .{ .items = &.{ 5, 11 } } };

fn source(a: std.mem.Allocator, mode: Mode) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const input_schema = if (mode == .presented)
        try contracts.schema(PresentedInput, &b)
    else
        try contracts.schema(Input, &b);
    const result_schema = try contracts.schema(Result, &b);
    const unit = try b.scalar(void);
    const effects: []const horos.source.Id = if (mode == .impure) &.{try b.effect(.{
        .identity = "projection/boundary-input",
        .payload = unit,
        .result = unit,
        .external = false,
    })} else &.{};
    const entry = try b.declare(
        &.{input_schema},
        if (mode == .wrong_schema) input_schema else result_schema,
        effects,
        &.{},
    );
    const input = try b.reference(b.parameter(entry, 0));
    const consumer = try b.primitive(try contracts.schema(wc.Ref, &b), .field, &.{input}, 0);
    const argument = try b.primitive(if (mode == .presented)
        try contracts.schema(Presentation, &b)
    else
        try contracts.schema(Aggregate, &b), .field, &.{input}, 1);
    const payload = if (mode == .presented)
        try b.primitive(try contracts.schema(Aggregate, &b), .field, &.{argument}, 1)
    else
        argument;
    const blocks = if (mode == .presented) try b.primitive(
        try contracts.schema(contracts.Vector(wc.PresentationBlock, null), &b),
        .field,
        &.{argument},
        0,
    ) else try b.literal(.{
        .schema = try contracts.schema(contracts.Vector(wc.PresentationBlock, null), &b),
        .bytes = try contracts.encodeOwned(contracts.Vector(wc.PresentationBlock, null), a, .{
            .items = &.{.{ .computed = .{} }},
        }),
    });
    const proposal = try b.primitive(
        try contracts.schema(wc.ProjectionProposal, &b),
        .product,
        &.{ consumer, blocks },
        0,
    );
    const result = try b.primitive(result_schema, .product, &.{ proposal, payload }, 0);
    try b.define(entry, try b.pure(if (mode == .wrong_schema) input else result));
    return native.source_records.encode(a, b.module(entry, unit));
}

fn build(f: *Fixture, mode: Mode) !recovery.Program {
    return f.buildSource(try source(f.permanent, mode), if (mode == .impure)
        &.{.{ .effect = 0, .class = .input }}
    else
        &.{});
}

fn project(f: *Fixture, program: recovery.Program, consumer: wc.Ref) !recovery.Run {
    const input = try f.materialize(program.input_schema, try f.json(Input, .{
        .consumer = consumer,
        .value = aggregate,
    }), &.{});
    return f.run(program.program, input);
}

fn select(f: *Fixture, id: []const u8, result: wc.Ref) !wc.Reply {
    return f.service.workspaceCommand(f.permanent, id, f.task, .{
        .context = .{ .select = .{ .projected = result } },
    });
}

fn rejected(reply: wc.Reply) !void {
    try std.testing.expectEqual(.rejected, reply.disposition);
    try std.testing.expect(reply.selected_view == null);
}

fn assertWorkBinding(f: *Fixture, run: recovery.Run, mutation: enum {
    incomplete,
    failed,
    cancelled,
    result,
}) !void {
    var saved = try f.service.workspaceWork(f.permanent, f.task, try recovery.refId(run.work));
    defer saved.deinit();
    var altered = saved.value;
    switch (mutation) {
        .incomplete => altered.outcome_kind = .yielded,
        .failed => altered.outcome_kind = .failed,
        .cancelled => altered.outcome_kind = .cancelled,
        .result => altered.result_value = altered.input_value,
    }
    try f.namespace.store.begin();
    defer f.namespace.store.rollback();
    try f.namespace.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        altered.id,
        f.task,
        altered,
    );
    const reply = try select(f, @tagName(mutation), run.result);
    try rejected(reply);
    const parsed = try native.json.parse(f.permanent, reply.observation_json.bytes, .{});
    try std.testing.expectEqualStrings(
        "InvalidProjection",
        parsed.value.object.get("error").?.string,
    );
}

fn assertPrepared(f: *Fixture, result: wc.Ref) !void {
    _ = try f.perform(.{ .context = .{ .command = .{ .select = .{ .projected = result } } } });
    try std.testing.expect(f.prepared.selected_view != null);
    try assertRenderedAggregate(f, f.prepared.body.bytes, result);
    const decoded = try f.decode(Result, result);
    try std.testing.expectEqual(aggregate.total, decoded.value.total);
    try std.testing.expectEqualSlices(u64, aggregate.missing.items, decoded.value.missing.items);
}

fn assertRenderedAggregate(f: *Fixture, body: []const u8, result: wc.Ref) !void {
    const block = try recovery.computedBlock(f.permanent, body);
    const reference = try f.ref(block, "result");
    try std.testing.expectEqualDeep(result, reference);
    const schema = try native.values.schemaBytes(Aggregate, f.permanent);
    const payload = try native.dynamic_values.encode(
        f.permanent,
        schema,
        block.object.get("value").?,
    );
    const expected = try contracts.encodeOwned(Aggregate, f.permanent, aggregate);
    try std.testing.expectEqualSlices(u8, expected, payload);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(schema, &digest, .{});
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(digest, .lower),
        block.object.get("schema_identity").?.string,
    );
}

test "projection owner authenticates observations schemas completion and result linkage" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const program = try build(&f, .projected);
    const consumer = try f.consumer();
    const valid = try project(&f, program, consumer);
    try assertWorkBinding(&f, valid, .incomplete);
    try assertWorkBinding(&f, valid, .failed);
    try assertWorkBinding(&f, valid, .cancelled);
    try assertWorkBinding(&f, valid, .result);
    const lookalike = try project(&f, program, .{
        .kind = .observation,
        .id = valid.result.id,
    });
    try rejectAction(&f, lookalike.result, "CorruptState");
    const wrong = try project(&f, try build(&f, .wrong_schema), consumer);
    try rejectAction(&f, wrong.result, "InvalidProjectionSchema");
    const raw = try f.value(valid.result);
    const schema = try support.workspaceRef(f.permanent, .schema, raw.description.schema.digest);
    const hypothetical = try f.materialize(
        schema,
        try f.json(Result, try f.decode(Result, valid.result)),
        &.{},
    );
    const hypothesis = try f.value(hypothetical);
    try std.testing.expectEqualDeep(raw.description.value, hypothesis.description.value);
    try std.testing.expectEqual(.hypothesis, hypothesis.derivation.kind);
    try std.testing.expectEqual(.computation, raw.derivation.kind);
    try rejectAction(&f, hypothetical, "InvalidProjection");
    const impure = try project(&f, try build(&f, .impure), consumer);
    try rejectAction(&f, impure.result, "ImpureSlice");
    try assertPrepared(&f, valid.result);
    try presentationBoundary(&f, valid.result);
}

fn selectionOperation(f: *Fixture, selected: wc.Ref) ![]const u8 {
    var operations = try f.namespace.store.database.prepare(
        "SELECT o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &f.task }},
    );
    defer operations.deinit();
    const wanted = try recovery.refId(selected);
    while (try operations.step() == .row) {
        const receipt = try contracts.decodeOwned(
            native.testing.state.Receipt,
            f.permanent,
            try operations.bytes(0),
        );
        if (receipt.value.workspace_kind != .view) continue;
        if (std.meta.eql(receipt.value.workspace.?, wanted))
            return receipt.value.client_operation_id.bytes;
    }
    return error.ProjectionSelectionReceiptMissing;
}

fn receiptReplay(f: *Fixture, result: wc.Ref, selected: wc.Ref, operation: []const u8) !void {
    const generation = f.namespace.store.head.generation;
    const attempt = f.pending.attempt;
    const body = try f.permanent.dupe(u8, f.prepared.body.bytes);
    const again = try select(f, operation, result);
    try std.testing.expectEqual(.observed, again.disposition);
    try std.testing.expectEqualDeep(selected, again.selected_view.?);
    try std.testing.expectEqual(generation, f.namespace.store.head.generation);
    try std.testing.expectEqualSlices(u8, &attempt, &f.pending.attempt);
    try std.testing.expectEqualSlices(u8, body, f.prepared.body.bytes);
}

fn assertForeignTask(f: *Fixture, result: wc.Ref) !void {
    const foreign = (try f.service.submit(f.permanent, "projection-foreign-task", .{
        .task = .{ .bytes = "Independent task with independent disclosure authority." },
    })).receipt.task;
    const response = try f.service.workspaceCommand(f.permanent, "foreign-selection", foreign, .{
        .context = .{ .select = .{ .projected = result } },
    });
    try rejected(response);
    const parsed = try native.json.parse(f.permanent, response.observation_json.bytes, .{});
    try std.testing.expectEqualStrings("CorruptState", parsed.value.object.get("error").?.string);
}

const RealizedProjector = struct {
    work: wc.Ref,
    historical: []const u8,
    current: []const u8,
    view: []const u8,
};

fn realizeProjector(f: *Fixture, run: recovery.Run) !RealizedProjector {
    const selected = f.prepared.selected_view orelse return error.MissingProjectedRequest;
    const view = try f.namespace.store.object(f.permanent, .{
        .digest = selected.digest,
        .bytes = selected.bytes,
    }, null);
    var before = try f.service.workspaceWork(f.permanent, f.task, try recovery.refId(run.work));
    defer before.deinit();
    try std.testing.expectEqual(.completed, before.value.outcome_kind);
    const historical = try contracts.encodeOwned(native.workspace.Work, f.permanent, before.value);
    const artifact = try contracts.decodeOwned(native.workspace.ViewArtifact, f.permanent, view);
    try std.testing.expectEqualSlices(u8, historical, try f.namespace.store.object(
        f.permanent,
        artifact.value.projection.?.work,
        null,
    ));
    _ = try f.perform(.{ .work = .{ .command = .{ .realize = .{
        .expected = .{
            .work = run.work,
            .execution_revision = before.value.execution_revision,
            .control_revision = before.value.control_revision,
        },
        .realization_revision = before.value.realization_revision,
        .runtime = .{ .packaged = .{} },
    } } } });
    var after = try f.service.workspaceWork(f.permanent, f.task, try recovery.refId(run.work));
    defer after.deinit();
    try std.testing.expectEqual(
        before.value.realization_revision + 1,
        after.value.realization_revision,
    );
    try std.testing.expectEqual(before.value.control_revision + 1, after.value.control_revision);
    try std.testing.expectEqual(before.value.execution_revision, after.value.execution_revision);
    try std.testing.expectEqual(.completed, after.value.outcome_kind);
    try std.testing.expectEqualDeep(before.value.result_value, after.value.result_value);
    try std.testing.expectEqualDeep(selected, f.prepared.selected_view.?);
    try assertRenderedAggregate(f, f.prepared.body.bytes, run.result);
    try unpublishedRetainedWork(f, before.value, after.value.control_revision);
    return .{
        .work = run.work,
        .historical = historical,
        .current = try contracts.encodeOwned(native.workspace.Work, f.permanent, after.value),
        .view = view,
    };
}

fn unpublishedRetainedWork(f: *Fixture, retained: native.workspace.Work, revision: u64) !void {
    try Snapshots.validateWorkspacePublication(&f.service, f.permanent, f.task, .{
        .work = retained,
        .occurrence = null,
    });
    var altered = retained;
    altered.control_revision = try std.math.add(u64, revision, 1);
    try std.testing.expectError(
        error.InvalidArchive,
        Snapshots.validateWorkspacePublication(&f.service, f.permanent, f.task, .{
            .work = altered,
            .occurrence = null,
        }),
    );
}

fn archiveProjection(
    f: *Fixture,
    projected: wc.Ref,
    prepared: []const u8,
    realized: RealizedProjector,
) !void {
    try f.service.completeWork(f.permanent, f.pending, .not_sent);
    const path = try std.fmt.allocPrint(f.permanent, "{s}/projection.agnx", .{f.directory});
    _ = try f.service.exportCheckpoint(f.permanent, f.task, path);
    try f.service.close(f.a);
    try f.namespace.close();
    f.live = false;
    const destination = try std.fmt.allocPrint(f.permanent, "{s}/imported", .{f.directory});
    var namespace = try native.Namespace.open(f.a, f.io, destination);
    defer cleanup("projection imported namespace.close", namespace.close());
    var service = try native.tasks.Service(t).init(
        f.a,
        f.io,
        &namespace,
        f.assets,
        &f.application,
        f.handlers,
        f.profile,
    );
    defer cleanup("projection imported service.close", service.close(f.a));
    const imported = try service.importCheckpoint(f.permanent, "projection-import", path);
    try std.testing.expectEqualSlices(u8, &f.task, &imported.receipt.task);
    const identity = try recovery.refId(projected);
    const key = try native.workspace.custodyId(f.permanent, f.task, identity);
    const bytes = (try namespace.store.recordBytes(
        f.permanent,
        "workspace_view",
        key,
        f.task,
    )) orelse return error.ImportedProjectionMissing;
    const view = try contracts.decodeOwned(native.workspace.View, f.permanent, bytes);
    try std.testing.expect(view.value.description.projection != null);
    try importedRealization(f, &service, &namespace, view.value, realized);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared, &digest, .{});
    const retained = try namespace.store.object(f.permanent, .{
        .digest = digest,
        .bytes = prepared.len,
    }, null);
    try std.testing.expectEqualSlices(u8, prepared, retained);
}

fn importedRealization(
    f: *Fixture,
    service: *native.tasks.Service(t),
    namespace: *native.Namespace,
    view: native.workspace.View,
    realized: RealizedProjector,
) !void {
    const artifact = try namespace.store.object(f.permanent, view.artifact, null);
    try std.testing.expectEqualSlices(u8, realized.view, artifact);
    const historical = try namespace.store.object(
        f.permanent,
        view.description.projection.?.work,
        null,
    );
    try std.testing.expectEqualSlices(u8, realized.historical, historical);
    var current = try service.workspaceWork(f.permanent, f.task, try recovery.refId(realized.work));
    defer current.deinit();
    const bytes = try contracts.encodeOwned(native.workspace.Work, f.permanent, current.value);
    try std.testing.expectEqualSlices(u8, realized.current, bytes);
    try std.testing.expect(!std.mem.eql(u8, historical, bytes));
}

fn amendmentRecovery(f: *Fixture) !void {
    try f.send(.{ .context = .{ .command = .{ .inspect = .{ .page = .{} } } } });
    try f.next();
    try std.testing.expect(f.prepared.selected_view == null);
    try std.testing.expectEqual(.projection_recovery, f.prepared.request.plan.reason);
    try std.testing.expect(std.mem.indexOf(
        u8,
        f.prepared.body.bytes,
        "The required source revision is now eight.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        f.prepared.body.bytes,
        "Projection preparation rejected: stale.",
    ) != null);
}

fn missingConsumerArchive(f: *Fixture, consumer: wc.Ref) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.assets.manifest, &digest, .{});
    const index = try f.namespace.store.archiveIndex(f.permanent, f.task, .{
        .digest = digest,
        .bytes = f.assets.manifest.len,
    });
    const missing = try recovery.refId(consumer);
    var retained: std.ArrayList(native.testing.state.ArchiveRecord) = .empty;
    for (index.records.items) |record| {
        if (record.kind == .workspace_reply and std.meta.eql(record.id, missing)) continue;
        try retained.append(f.permanent, record);
    }
    try std.testing.expectEqual(index.records.items.len - 1, retained.items.len);
    var facts = try f.service.prepareWorkspaceValidation(f.task);
    defer facts.deinit();
    try f.service.validateWorkspaceRecordsPrepared(
        f.permanent,
        f.task,
        index.records.items,
        &facts,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        f.service.validateWorkspaceRecordsPrepared(f.permanent, f.task, retained.items, &facts),
    );
}

fn validateArchive(f: *Fixture) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.assets.manifest, &digest, .{});
    const index = try f.namespace.store.archiveIndex(f.permanent, f.task, .{
        .digest = digest,
        .bytes = f.assets.manifest.len,
    });
    var facts = try f.service.prepareWorkspaceValidation(f.task);
    defer facts.deinit();
    try f.service.validateWorkspaceRecordsPrepared(
        f.permanent,
        f.task,
        index.records.items,
        &facts,
    );
}

fn resumeInference(f: *Fixture) !void {
    var parent = try f.service.task(f.permanent, f.task);
    defer parent.deinit();
    _ = try f.service.resumeTask(
        f.permanent,
        "projection-archive-resume",
        f.task,
        parent.value.revision,
    );
    try f.next();
}

fn preparationCutTamper(f: *Fixture) !void {
    const State = native.testing.state;
    var digest: State.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.assets.manifest, &digest, .{});
    const index = try f.namespace.store.archiveIndex(f.permanent, f.task, .{
        .digest = digest,
        .bytes = f.assets.manifest.len,
    });
    const records = try f.permanent.dupe(State.ArchiveRecord, index.records.items);
    const bytes = (try f.namespace.store.recordBytes(
        f.permanent,
        "attempt",
        f.pending.attempt,
        f.task,
    )) orelse return error.MissingProjectionAttempt;
    var attempt = try contracts.decodeOwned(State.Attempt, f.permanent, bytes);
    defer attempt.deinit();
    attempt.value.preparation_cut = try std.math.add(u64, attempt.value.preparation_cut.?, 1);
    var facts = try f.service.prepareWorkspaceValidation(f.task);
    defer facts.deinit();
    const previous_facts = f.service.compiler_facts;
    f.service.compiler_facts = &facts;
    defer f.service.compiler_facts = previous_facts;
    var parent = try f.service.task(f.permanent, f.task);
    defer parent.deinit();
    try Snapshots.validateWorkspaceArchive(
        &f.service,
        f.permanent,
        parent.value,
        records,
        .inspect,
    );
    try f.namespace.store.begin();
    defer f.namespace.store.rollback();
    const changed = try f.namespace.store.putObject(
        try contracts.encodeOwned(State.Attempt, f.permanent, attempt.value),
    );
    try f.namespace.store.database.run(
        "UPDATE records SET body=? WHERE kind='attempt' AND id=? AND task=?",
        &.{
            .{ .blob = &changed.digest },
            .{ .blob = &attempt.value.id },
            .{ .blob = &f.task },
        },
    );
    try std.testing.expectEqual(1, try f.namespace.store.database.changes());
    var replaced = false;
    for (records) |*record| {
        if (record.kind != .attempt or !std.meta.eql(record.id, attempt.value.id)) continue;
        record.body = changed;
        replaced = true;
    }
    try std.testing.expect(replaced);
    try std.testing.expectError(
        error.InvalidArchive,
        Snapshots.validateWorkspaceArchive(
            &f.service,
            f.permanent,
            parent.value,
            records,
            .inspect,
        ),
    );
}

test "projection receipts preserve exact requests and reject substituted archive relationships" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const program = try build(&f, .projected);
    const consumer = try f.consumer();
    const valid = try project(&f, program, consumer);
    try assertPrepared(&f, valid.result);
    const projected = try support.workspaceRef(
        f.permanent,
        .view,
        f.prepared.selected_view.?.digest,
    );
    const original_prepared = try f.permanent.dupe(u8, f.pending.prepared.?);
    const operation = try selectionOperation(&f, projected);
    try receiptReplay(&f, valid.result, projected, operation);
    const realized = try realizeProjector(&f, valid);
    try f.service.completeWork(f.permanent, f.pending, .not_sent);
    try missingConsumerArchive(&f, consumer);
    const ordinary = try f.service.workspaceCommand(f.permanent, "ordinary-view", f.task, .{
        .context = .{ .select = .{ .values = .{ .items = &.{valid.result} } } },
    });
    try std.testing.expectEqual(.observed, ordinary.disposition);
    try std.testing.expect(!std.mem.eql(u8, projected.id.bytes, ordinary.selected_view.?.id.bytes));
    try validateArchive(&f);
    try preparationCutTamper(&f);
    try support.expectContextOutputBound(
        &f.service,
        f.permanent,
        f.task,
        operation,
        ordinary.selected_view.?,
        null,
    );
    try resumeInference(&f);
    _ = try f.service.message(f.permanent, "projection-amendment", f.task, .{
        .message = .{ .bytes = "The required source revision is now eight." },
    });
    const replayed = try select(&f, operation, valid.result);
    try std.testing.expectEqualDeep(projected, replayed.selected_view.?);
    try rejected(try select(&f, "fresh-stale-selection", valid.result));
    try amendmentRecovery(&f);
    try assertForeignTask(&f, valid.result);
    try archiveProjection(&f, projected, original_prepared, realized);
}

const Pending = struct { expected: wc.Expected, port: wc.Ref, generation: u64 };

fn pendingQuestion(f: *Fixture) !Pending {
    var b = horos.source.Builder.init(f.permanent);
    defer b.deinit();
    const module = try @import("workspace_sources.zig").binaryQuestion(&b);
    const program = try f.buildSource(
        try native.source_records.encode(f.permanent, module),
        &.{.{ .effect = 0, .class = .input }},
    );
    const observed = try f.perform(.{ .work = .{ .command = .{ .start = .{
        .program = program.program,
        .input = .{ .inline_json = .{
            .schema = program.input_schema,
            .json_text = .{ .bytes = "{}" },
        } },
        .policy = .{ .stop = .next_exposed_event, .continuation = .owner_scheduled },
    } } } });
    const reference = try f.ref(observed, "work");
    for (0..128) |_| {
        var saved = try f.service.workspaceWork(f.permanent, f.task, try recovery.refId(reference));
        defer saved.deinit();
        if (saved.value.current_port) |port_ref| {
            var port = try contracts.decodeOwned(
                native.workspace.Port,
                f.permanent,
                try f.namespace.store.object(f.permanent, port_ref, null),
            );
            defer port.deinit();
            return .{
                .expected = .{
                    .work = reference,
                    .execution_revision = saved.value.execution_revision,
                    .control_revision = saved.value.control_revision,
                },
                .port = try support.workspaceRef(f.permanent, .port, port.value.id),
                .generation = port.value.generation,
            };
        }
        _ = try f.perform(.{ .work = .{ .command = .{ .inspect = .{ .work = reference } } } });
    }
    return error.ProjectionPendingPortDidNotArrive;
}

fn observe(f: *Fixture, target: wc.ConsumerTarget, current: []const wc.Expected) !wc.Ref {
    return f.ref(try f.perform(.{ .context = .{ .command = .{ .inspect = .{
        .page = .{},
        .consumer = .{ .target = target, .required_current = .{ .items = current } },
    } } } }), "consumer");
}

fn rejectAction(f: *Fixture, result: wc.Ref, expected: []const u8) !void {
    const reply = try f.attempt(.{ .context = .{ .command = .{ .select = .{
        .projected = result,
    } } } });
    try std.testing.expectEqualStrings("rejected", reply.object.get("disposition").?.string);
    try std.testing.expectEqualStrings(
        expected,
        reply.object.get("observation").?.object.get("error").?.string,
    );
}

test "projection required-current work changes invalidate while unrelated progress remains valid" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const pending = try pendingQuestion(&f);
    const program = try build(&f, .projected);
    const consumer = try observe(&f, .{ .controller = .{} }, &.{pending.expected});
    const projected = try project(&f, program, consumer);
    _ = try project(&f, program, consumer);
    try assertPrepared(&f, projected.result);
    _ = try f.perform(.{ .work = .{ .command = .{ .park = pending.expected } } });
    try rejectAction(&f, projected.result, "StaleConsumer");
}

test "projection selection rechecks the actual protected inference profile" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const program = try build(&f, .projected);
    const projected = try project(&f, program, try f.consumer());
    const selection = f.prepared.request.selection;
    try f.send(.{ .inference_set = .{
        .profile_id = selection.profile_id,
        .effort = .high,
        .expected_revision = selection.control_revision,
        .reason = .{ .bytes = "Exercise the protected request binding after an effort change." },
    } });
    try f.next();
    try std.testing.expectEqual(.high, f.prepared.request.selection.effective_effort);
    try rejectAction(&f, projected.result, "StaleConsumer");
}

fn delegatedCapture(f: *Fixture, pending: Pending, result: wc.Ref) !void {
    try f.send(.{ .work = .{ .command = .{ .delegate = .{
        .expected = pending.expected,
        .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
        .interpretation = .{ .model = .{
            .port = pending.port,
            .generation = pending.generation,
            .profile_id = .{ .bytes = "analysis" },
            .effort = .{ .bytes = "medium" },
            .subproblem = .{ .bytes = "Return true after inspecting the missing-input aggregate." },
            .context = .{ .projected = result },
        } },
    } } } });
    for (0..16384) |_| {
        const step = try f.service.pump(f.permanent);
        if (step != .work) continue;
        if (!step.work.entry.declaration.inference) {
            try f.complete(step.work);
            continue;
        }
        if (step.work.subject_work == null) {
            f.pending = step.work;
            try waitForDelegation(f, pending);
            continue;
        }
        try assertDelegationBinding(f, pending, step.work);
        var prepared = try contracts.decodeOwned(
            native.workspace_instrument.Prepared,
            f.permanent,
            step.work.prepared.?,
        );
        defer prepared.deinit();
        try std.testing.expect(prepared.value.selected_view != null);
        try assertRenderedAggregate(f, prepared.value.body.bytes, result);
        return;
    }
    return error.ProjectedDelegationDidNotArrive;
}

fn waitForDelegation(f: *Fixture, pending: Pending) !void {
    var prepared = try contracts.decodeOwned(
        t.P.AdaptivePrepared,
        f.permanent,
        f.pending.prepared.?,
    );
    defer prepared.deinit();
    for (prepared.value.request.results.items) |result| {
        const reply = try native.json.parseAsset(
            f.permanent,
            result.output.bytes,
            result.output.bytes.len,
        );
        const disposition = reply.value.object.get("disposition") orelse continue;
        if (std.mem.eql(u8, disposition.string, "rejected")) {
            std.debug.print("delegated action rejected: {s}\n", .{result.output.bytes});
            return error.DelegationActionRejected;
        }
    }
    var parent = try f.service.task(f.permanent, f.task);
    defer parent.deinit();
    try f.send(.{ .work = .{ .command = .{ .wait = .{
        .works = .{ .items = &.{pending.expected.work} },
        .after = parent.value.event_high,
    } } } });
}

fn assertDelegationBinding(f: *Fixture, pending: Pending, work: native.tasks.Work) !void {
    const instrument = work.subject_work orelse return error.MissingDelegatedInstrument;
    const original = try recovery.refId(pending.expected.work);
    try std.testing.expect(!std.meta.eql(original, instrument));
    var child = try f.service.workspaceWork(f.permanent, f.task, instrument);
    defer child.deinit();
    const reference = child.value.delegation orelse return error.MissingDelegation;
    var delegation = try contracts.decodeOwned(
        native.workspace.Delegation,
        f.permanent,
        try f.namespace.store.object(f.permanent, reference, null),
    );
    defer delegation.deinit();
    try std.testing.expectEqualDeep(instrument, delegation.value.instrument);
    try std.testing.expectEqualDeep(original, delegation.value.work);
    var port = try contracts.decodeOwned(
        native.workspace.Port,
        f.permanent,
        try f.namespace.store.object(f.permanent, delegation.value.port, null),
    );
    defer port.deinit();
    try std.testing.expectEqualDeep(try recovery.refId(pending.port), port.value.id);
    try std.testing.expectEqualDeep(original, port.value.work);
    try std.testing.expectEqual(pending.generation, port.value.generation);
    try std.testing.expectEqualDeep(f.task, delegation.value.task);
}

test "delegated projection binds the actual port and reaches its protected model request" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const pending = try pendingQuestion(&f);
    const program = try build(&f, .projected);
    const target: wc.ConsumerTarget = .{ .model = .{
        .expected = pending.expected,
        .port = pending.port,
        .generation = pending.generation,
        .profile_id = .{ .bytes = "analysis" },
        .effort = .{ .bytes = "medium" },
    } };
    const consumer = try observe(&f, target, &.{});
    const projected = try project(&f, program, consumer);
    try rejectAction(&f, projected.result, "ConsumerMismatch");
    var stale = target;
    stale.model.generation += 1;
    const reply = try f.attempt(.{ .context = .{ .command = .{ .inspect = .{
        .page = .{},
        .consumer = .{ .target = stale },
    } } } });
    try std.testing.expectEqualStrings("rejected", reply.object.get("disposition").?.string);
    try std.testing.expectEqualStrings(
        "StaleConsumer",
        reply.object.get("observation").?.object.get("error").?.string,
    );
    try delegatedCapture(&f, pending, projected.result);
}

fn successorConverter(a: std.mem.Allocator) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const Conversion = struct { carry: t.ControllerCarry, owner: contracts.controller.OwnerView };
    const input_schema = try contracts.schema(Conversion, &b);
    const output_schema = try contracts.schema(t.ControllerPrivate, &b);
    const entry = try b.declare(&.{input_schema}, output_schema, &.{}, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const carry = try b.primitive(
        try contracts.schema(t.ControllerCarry, &b),
        .field,
        &.{input},
        0,
    );
    const resumed = try b.primitive(
        output_schema,
        .variant,
        &.{carry},
        @backingInt(@as(std.meta.Tag(t.ControllerPrivate), .@"resume")),
    );
    try b.define(entry, try b.pure(resumed));
    return native.source_records.encode(a, b.module(entry, try b.scalar(void)));
}

fn buildSuccessor(f: *Fixture) !struct { controller: wc.Ref, converter: wc.Ref } {
    const retained = f.application.controller orelse return error.MissingSeedControllerSource;
    const observed = try f.perform(.{ .program = .{ .command = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = retained.source } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{} },
        .role = .controller,
    } } } });
    const controller = try f.ref(observed, "program");
    const converter = try f.buildSource(try successorConverter(f.permanent), &.{});
    return .{ .controller = controller, .converter = converter.program };
}

fn adoptSuccessor(f: *Fixture, successor: anytype) !u64 {
    var before = try f.service.task(f.permanent, f.task);
    defer before.deinit();
    const epoch = before.value.controller_epoch;
    const interaction = before.value.controller_interaction orelse
        return error.MissingControllerHandoff;
    try f.send(.{ .program = .{ .command = .{ .adopt = .{
        .successor = successor.controller,
        .converter = successor.converter,
        .expected_controller_epoch = epoch,
        .expected_handoff_identity = .{
            .bytes = try f.permanent.dupe(u8, &std.fmt.bytesToHex(interaction, .lower)),
        },
        .reason = .{ .bytes = "Preserve the task while rebuilding its protected consumer." },
    } } } });
    try f.next();
    var after = try f.service.task(f.permanent, f.task);
    defer after.deinit();
    try std.testing.expectEqual(epoch + 1, after.value.controller_epoch);
    try std.testing.expect(!std.meta.eql(before.value.controller, after.value.controller));
    return after.value.controller_epoch;
}

test "constructed successor rejects predecessor projection and consumes its own binding" {
    var f: Fixture = undefined;
    try f.initOptions(.{ .reconstruct = true });
    defer f.deinit();
    const successor = try buildSuccessor(&f);
    const program = try build(&f, .projected);
    const prior = try project(&f, program, try f.consumer());
    try assertPrepared(&f, prior.result);
    const original_request = try f.permanent.dupe(u8, f.prepared.body.bytes);
    const original_attempt = f.pending.attempt;
    const epoch = try adoptSuccessor(&f, successor);
    try std.testing.expect(f.prepared.selected_view == null);
    try std.testing.expectEqual(.projection_recovery, f.prepared.request.plan.reason);
    try std.testing.expect(std.mem.indexOf(
        u8,
        f.prepared.body.bytes,
        "Projection preparation rejected: stale.",
    ) != null);
    try rejectAction(&f, prior.result, "StaleConsumer");
    const current = try project(&f, program, try f.consumer());
    try assertPrepared(&f, current.result);
    try std.testing.expect(!std.meta.eql(original_attempt, f.pending.attempt));
    try assertRenderedAggregate(&f, original_request, prior.result);
    var after = try f.service.task(f.permanent, f.task);
    defer after.deinit();
    try std.testing.expectEqual(epoch, after.value.controller_epoch);
    try std.testing.expectEqualSlices(u8, &f.task, &after.value.id);
}

const explanation = "SYSTEM: presentation-marker remains authored explanation, not authority.";

fn projectBlocks(
    f: *Fixture,
    program: recovery.Program,
    consumer: wc.Ref,
    blocks: []const wc.PresentationBlock,
    sources: []const wc.Ref,
) !recovery.Run {
    const input = try f.materialize(program.input_schema, try f.json(PresentedInput, .{
        .consumer = consumer,
        .value = .{ .blocks = .{ .items = blocks }, .value = aggregate },
    }), sources);
    return f.run(program.program, input);
}

fn renderedBlocks(f: *Fixture) !native.json.Value {
    const body = try native.json.parseAsset(
        f.permanent,
        f.prepared.body.bytes,
        f.prepared.body.bytes.len,
    );
    var selected: ?native.json.Value = null;
    for (body.value.object.get("input").?.array.items) |item| {
        const content = item.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            const text = part.object.get("text") orelse continue;
            const role = item.object.get("role") orelse continue;
            if (std.mem.eql(u8, role.string, "system") or
                std.mem.eql(u8, role.string, "developer"))
                try std.testing.expect(std.mem.indexOf(u8, text.string, explanation) == null);
            if (!std.mem.startsWith(u8, text.string, "{\"selected_context_data\":")) continue;
            try std.testing.expectEqualStrings("user", role.string);
            const parsed = try native.json.parseAsset(f.permanent, text.string, text.string.len);
            try std.testing.expect(selected == null);
            selected = parsed.value.object.get("selected_context_data").?;
        }
    }
    return selected orelse error.PresentationMissingFromRequest;
}

fn assertPresentation(
    f: *Fixture,
    sources: []const wc.Ref,
    source_slice: @FieldType(wc.PresentationBlock, "source"),
) !void {
    const blocks = (try renderedBlocks(f)).array.items;
    try std.testing.expectEqual(@as(usize, 7), blocks.len);
    const kinds = [_][]const u8{
        "acquisition", "hypothesis", "judgment",             "computation",
        "acquisition", "computed",   "authored_explanation",
    };
    for (blocks, kinds) |block, kind|
        try std.testing.expectEqualStrings(kind, block.object.get("kind").?.string);
    for (blocks[0..4], sources) |block, reference| {
        try std.testing.expectEqualDeep(reference, try f.ref(block, "value_reference"));
        const origin = try f.value(reference);
        const provenance = try support.workspaceRef(
            f.permanent,
            .provenance,
            origin.description.provenance.digest,
        );
        try std.testing.expectEqualDeep(provenance, try f.ref(block, "provenance"));
    }
    const text = try f.decode(contracts.Utf8, sources[0]);
    for (blocks[0..3]) |block|
        try std.testing.expectEqualStrings(text.bytes, block.object.get("value").?.string);
    const actual_slice = try native.values.fromJson(
        @TypeOf(source_slice),
        f.permanent,
        blocks[4].object.get("slice").?,
    );
    try std.testing.expectEqualDeep(source_slice, actual_slice);
    try std.testing.expectEqualStrings("41", blocks[4].object.get("value").?.string);
    try std.testing.expectEqualDeep(sources[0], try f.ref(blocks[4], "value_reference"));
    try std.testing.expectEqualDeep(
        try f.ref(blocks[0], "provenance"),
        try f.ref(blocks[4], "provenance"),
    );
    try std.testing.expectEqualStrings(explanation, blocks[6].object.get("text").?.string);
    try std.testing.expect(!blocks[6].object.contains("role"));
    var selected = try contracts.decodeOwned(
        native.workspace.ViewArtifact,
        f.permanent,
        try f.namespace.store.object(f.permanent, .{
            .digest = f.prepared.selected_view.?.digest,
            .bytes = f.prepared.selected_view.?.bytes,
        }, null),
    );
    defer selected.deinit();
    try std.testing.expectEqual(.selected_values_only, selected.value.coverage);
    const retained = selected.value.projection.?.values.items;
    try std.testing.expectEqual(@as(usize, 5), retained.len);
    for (retained[0..4], sources) |actual, expected|
        try std.testing.expectEqualDeep(try recovery.refId(expected), actual.digest);
    try std.testing.expectEqualDeep(try recovery.refId(sources[0]), retained[4].digest);
}

fn rejectSourceSlices(
    f: *Fixture,
    program: recovery.Program,
    consumer: wc.Ref,
    sources: []const wc.Ref,
    length: usize,
) !void {
    const prior = f.prepared.selected_view;
    const slices = [_]@FieldType(wc.PresentationBlock, "source"){
        .{ .value = sources[1], .offset = 0, .length = 1 },
        .{ .value = sources[2], .offset = 0, .length = 1 },
        .{ .value = sources[3], .offset = 0, .length = 1 },
        .{ .value = sources[0], .offset = length, .length = 1 },
        .{ .value = sources[0], .offset = std.math.maxInt(u64), .length = 1 },
        .{ .value = sources[0], .offset = 1, .length = std.math.maxInt(u64) },
    };
    for (slices) |slice| {
        const projected = try projectBlocks(
            f,
            program,
            consumer,
            &.{.{ .source = slice }},
            sources,
        );
        try rejectAction(f, projected.result, "InvalidSourceSlice");
        try std.testing.expectEqualDeep(prior, f.prepared.selected_view);
    }
}

fn presentationBoundary(f: *Fixture, computed: wc.Ref) !void {
    const program = try build(f, .presented);
    const acquired = try f.ref(try f.perform(.{ .context = .{ .command = .{ .materialize = .{
        .input = .{ .snapshot = .{
            .path = .{ .bytes = "domain.json" },
            .offset = 0,
            .maximum = 4096,
        } },
        .sources = .{ .items = &.{} },
    } } } }), "value");
    const actual = try f.value(acquired);
    const text = try f.decode(contracts.Utf8, acquired);
    const schema = try support.workspaceRef(f.permanent, .schema, actual.description.schema.digest);
    const hypothetical = try f.materialize(schema, try f.json(contracts.Utf8, text), &.{});
    const judgment = try f.materialize(schema, try f.json(contracts.Utf8, text), &.{acquired});
    const hypothesis = try f.value(hypothetical);
    const judged = try f.value(judgment);
    try std.testing.expectEqualDeep(actual.description.value, hypothesis.description.value);
    try std.testing.expectEqualDeep(actual.description.value, judged.description.value);
    try std.testing.expectEqual(.acquisition, actual.derivation.kind);
    try std.testing.expectEqual(.hypothesis, hypothesis.derivation.kind);
    try std.testing.expectEqual(.judgment, judged.derivation.kind);
    try std.testing.expectEqual(@as(usize, 1), judged.derivation.sources.items.len);
    try std.testing.expectEqualDeep(actual.artifact, judged.derivation.sources.items[0]);
    const coverage = actual.derivation.acquisition orelse return error.MissingSnapshotCoverage;
    try std.testing.expectEqualStrings("domain.json", coverage.path.bytes);
    try std.testing.expectEqual(@as(u64, 0), coverage.start);
    try std.testing.expectEqual(text.bytes.len, coverage.end);
    try std.testing.expectEqual(text.bytes.len, coverage.file_bytes);
    const slice: @FieldType(wc.PresentationBlock, "source") = .{
        .value = acquired,
        .offset = std.mem.indexOf(u8, text.bytes, "41") orelse return error.MissingDomainIdentity,
        .length = 2,
    };
    const consumer = try f.consumer();
    const sources = [_]wc.Ref{ acquired, hypothetical, judgment, computed };
    const projected = try projectBlocks(f, program, consumer, &.{
        .{ .value = acquired },
        .{ .value = hypothetical },
        .{ .value = judgment },
        .{ .value = computed },
        .{ .source = slice },
        .{ .computed = .{} },
        .{ .explanation = .{ .bytes = explanation } },
    }, &sources);
    try assertPrepared(f, projected.result);
    try assertPresentation(f, &sources, slice);
    try rejectSourceSlices(f, program, consumer, &sources, text.bytes.len);
}
