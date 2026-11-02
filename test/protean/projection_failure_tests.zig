const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const t = @import("adaptive_types");
const recovery = @import("projection_recovery.zig");
const support = @import("workspace_test_support.zig");
const wc = contracts.workspace;
const Fixture = recovery.Fixture;
const Commands = native.testing.workspace_commands.Operations(t, native.tasks.Service(t));
const ns = native.testing.state;
const cleanup = @import("native_test_support.zig").cleanup;

fn projector(a: std.mem.Allocator, doublings: usize) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const input = try contracts.schema(wc.ProjectionInput(u64), &b);
    const result = try contracts.schema(wc.ProjectionResult(u64), &b);
    const blocks_schema = try contracts.schema(contracts.Vector(wc.PresentationBlock, null), &b);
    const entry = try b.declare(&.{input}, result, &.{}, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    const consumer = try b.primitive(try contracts.schema(wc.Ref, &b), .field, &.{argument}, 0);
    const payload = try b.primitive(try b.scalar(u64), .field, &.{argument}, 1);
    var blocks = try b.literal(.{
        .schema = blocks_schema,
        .bytes = try contracts.encodeOwned(
            contracts.Vector(wc.PresentationBlock, null),
            b.allocator(),
            .{ .items = &.{.{ .computed = .{} }} },
        ),
    });
    const bindings = try b.allocator().alloc(horos.source.Id, doublings);
    const expressions = try b.allocator().alloc(horos.source.Id, doublings);
    for (bindings, expressions) |*variable, *expression| {
        variable.* = try b.variable(blocks_schema);
        expression.* = try b.primitive(blocks_schema, .sequence_concat, &.{ blocks, blocks }, 0);
        blocks = try b.reference(variable.*);
    }
    const proposal = try b.primitive(
        try contracts.schema(wc.ProjectionProposal, &b),
        .product,
        &.{ consumer, blocks },
        0,
    );
    var body = try b.pure(try b.primitive(result, .product, &.{ proposal, payload }, 0));
    var remaining = doublings;
    while (remaining > 0) {
        remaining -= 1;
        body = try b.bind(bindings[remaining], try b.pure(expressions[remaining]), body);
    }
    try b.define(entry, body);
    return native.source_records.encode(a, b.module(entry, try b.scalar(void)));
}

fn completed(f: *Fixture, doublings: usize) !recovery.Run {
    const program = try f.buildSource(try projector(f.permanent, doublings), &.{});
    const consumer = try f.consumer();
    const input = try f.materialize(program.input_schema, try f.json(wc.ProjectionInput(u64), .{
        .consumer = consumer,
        .value = 73,
    }), &.{});
    return f.run(program.program, input);
}

const PublicationFailure = struct {
    backing: std.mem.Allocator,
    namespace: *native.Namespace,
    triggered: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(pointer));
        if (self.namespace.store.transaction) {
            self.triggered = true;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(pointer: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(pointer));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn counts(f: *Fixture) ![3]i64 {
    var query = try f.namespace.store.database.prepare(
        "SELECT (SELECT count(*) FROM objects)," ++
            "(SELECT count(*) FROM records),(SELECT count(*) FROM operations)",
        &.{},
    );
    defer query.deinit();
    try std.testing.expectEqual(.row, try query.step());
    return .{ try query.integer(0), try query.integer(1), try query.integer(2) };
}

fn authorized(f: *Fixture, result: wc.Ref) !native.workspace.Authorized {
    const proposal = try f.decode(wc.ProjectionResult(u64), result);
    const reference = try recovery.refId(proposal.proposal.consumer);
    const bytes = (try f.namespace.store.recordBytes(
        f.permanent,
        "workspace_reply",
        reference,
        f.task,
    )) orelse return error.MissingConsumerObservation;
    var observed = try contracts.decodeOwned(native.workspace.ReplyObservation, f.permanent, bytes);
    defer observed.deinit();
    return .{
        .command = .{ .context = .{ .select = .{ .projected = result } } },
        .consumer = observed.value.evidence.read.consumer.interface,
    };
}

fn beforePublication(f: *Fixture, command: native.workspace.Authorized) !void {
    const before = try counts(f);
    const head = f.namespace.store.head;
    var parent = try f.service.task(f.permanent, f.task);
    defer parent.deinit();
    var failure: PublicationFailure = .{ .backing = f.permanent, .namespace = &f.namespace };
    try std.testing.expectError(error.OutOfMemory, Commands.workspaceCommandFrom(
        &f.service,
        failure.allocator(),
        "projection-rollback",
        f.task,
        command,
        null,
    ));
    try std.testing.expect(failure.triggered);
    try std.testing.expect(!f.namespace.store.transaction and !f.namespace.store.fenced);
    try std.testing.expectEqualDeep(before, try counts(f));
    try std.testing.expectEqualDeep(head, f.namespace.store.head);
    var after = try f.service.task(f.permanent, f.task);
    defer after.deinit();
    try std.testing.expectEqualDeep(parent.value, after.value);
}

fn afterPublication(f: *Fixture, command: native.workspace.Authorized) !void {
    var failure: support.AfterCommitAllocator = .{
        .backing = f.permanent,
        .namespace = &f.namespace,
        .generation = f.namespace.store.head.generation,
    };
    try std.testing.expectError(error.OutOfMemory, Commands.workspaceCommandFrom(
        &f.service,
        failure.allocator(),
        "projection-committed",
        f.task,
        command,
        null,
    ));
    try std.testing.expect(failure.rejected != 0);
    try std.testing.expectEqual(failure.generation + 1, f.namespace.store.head.generation);
    const before = try counts(f);
    const head = f.namespace.store.head;
    const replay = try f.service.workspaceCommand(
        f.permanent,
        "projection-committed",
        f.task,
        command.command,
    );
    try std.testing.expectEqual(.observed, replay.disposition);
    try std.testing.expect(replay.selected_view != null);
    const observation = try native.json.parse(f.permanent, replay.observation_json.bytes, .{});
    try std.testing.expect(observation.value.object.get("replayed").?.bool);
    try std.testing.expectEqualDeep(before, try counts(f));
    try std.testing.expectEqualDeep(head, f.namespace.store.head);
}

const MissingView = struct {
    var active: ?*MissingView = null;

    fixture: *Fixture,
    original: @FieldType(native.registry.CaptureAdapter, "prepare"),
    view: wc.Ref,
    record_id: ns.Digest,
    after: u64,
    observations: u64 = 0,

    fn prepare(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        const self = active orelse return error.MissingFaultFixture;
        var input = try contracts.decodeOwned(t.Preparation, ctx.allocator, bytes);
        defer input.deinit();
        const selected = input.value.state.selected_view orelse return self.original(ctx, bytes);
        const cut = ctx.consumer_cut orelse return self.original(ctx, bytes);
        if (cut.event_watermark <= self.after or
            !std.mem.eql(u8, selected.id.bytes, self.view.id.bytes))
            return self.original(ctx, bytes);
        const store = &self.fixture.namespace.store;
        try std.testing.expect(store.projecting);
        try store.database.exec("SAVEPOINT projection_missing_view;");
        defer cleanup("projection missing view rollback", store.database.exec(
            "ROLLBACK TO projection_missing_view; RELEASE projection_missing_view;",
        ));
        try store.database.run(
            "DELETE FROM records WHERE kind='workspace_view' AND id=? AND task=?",
            &.{ .{ .blob = &self.record_id }, .{ .blob = &self.fixture.task } },
        );
        try std.testing.expectEqual(1, try store.database.changes());
        self.observations += 1;
        return self.original(ctx, bytes);
    }
};

fn preparationEntry(f: *Fixture) !*native.registry.Entry {
    for (@constCast(f.handlers.entries)) |*entry| {
        if (std.mem.eql(u8, entry.declaration.identity, t.prepare_identity)) return entry;
    }
    return error.PreparationHandlerMissing;
}

fn missingDependency(f: *Fixture, result: wc.Ref) !void {
    _ = try f.perform(.{ .context = .{ .command = .{ .select = .{ .projected = result } } } });
    const selected = f.prepared.selected_view orelse return error.MissingProjectedRequest;
    const original = try f.permanent.dupe(u8, f.pending.prepared.?);
    const before = (try f.service.task(f.permanent, f.task)).value;
    const entry = try preparationEntry(f);
    var fault: MissingView = .{
        .fixture = f,
        .original = entry.declaration.capture.?.prepare,
        .view = try support.workspaceRef(f.permanent, .view, selected.digest),
        .record_id = try native.workspace.custodyId(f.permanent, f.task, selected.digest),
        .after = before.event_high,
    };
    MissingView.active = &fault;
    defer MissingView.active = null;
    entry.declaration.capture.?.prepare = MissingView.prepare;
    defer entry.declaration.capture.?.prepare = fault.original;
    const calls = f.calls;
    _ = try f.perform(.{ .context = .{ .command = .{ .inspect = .{ .page = .{} } } } });
    try std.testing.expect(fault.observations != 0);
    try std.testing.expectEqual(calls + 1, f.calls);
    try std.testing.expectEqual(.projection_recovery, f.prepared.request.plan.reason);
    try std.testing.expect(f.prepared.selected_view == null);
    try std.testing.expect(f.prepared.request.plan.research == null);
    for ([_][]const u8{
        "Projection preparation rejected: unavailable.",
        "domain 41 revision 7",
        "An unavailable member is incomplete, never absent.",
    }) |text| try std.testing.expect(std.mem.indexOf(u8, f.prepared.body.bytes, text) != null);
    try requireRetainedPrepared(f, original);
    try std.testing.expect((try f.namespace.store.recordBytes(
        f.permanent,
        "workspace_view",
        fault.record_id,
        f.task,
    )) != null);
    const after = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectEqual(before.inference_attempts + 1, after.inference_attempts);
    const attempt = f.pending.attempt;
    for (0..3) |_| {
        const step = try f.service.pump(f.permanent);
        try std.testing.expect(step != .work);
    }
    try std.testing.expectEqualDeep(attempt, f.pending.attempt);
    const unchanged = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectEqual(after.inference_attempts, unchanged.inference_attempts);
    try std.testing.expect(!unchanged.terminal());
}

fn requireRetainedPrepared(f: *Fixture, original: []const u8) !void {
    var digest: ns.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(original, &digest, .{});
    const saved = try f.namespace.store.object(f.permanent, .{
        .digest = digest,
        .bytes = original.len,
    }, null);
    try std.testing.expectEqualSlices(u8, original, saved);
}

test "projection publication preserves rollback and committed receipt under allocation failure" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const result = try completed(&f, 0);
    const original = try f.permanent.dupe(u8, f.pending.prepared.?);
    const command = try authorized(&f, result.result);
    try beforePublication(&f, command);
    try afterPublication(&f, command);
    try std.testing.expectEqualSlices(u8, original, f.pending.prepared.?);
    try missingDependency(&f, result.result);
    _ = try f.service.submit(f.permanent, "after-projection-fault", .{ .task = .{
        .bytes = "Independent task remains admissible after projection rollback.",
    } });
}

test "oversized expanded projection recovers once through an ordinary actual request" {
    var f: Fixture = undefined;
    try f.initOptions(.{ .request_bytes = 1024 * 1024 });
    defer f.deinit();
    const result = try completed(&f, 14);
    const before = f.calls;
    const observed = try f.perform(.{ .context = .{ .command = .{ .select = .{
        .projected = result.result,
    } } } });
    _ = try f.ref(observed, "view");
    try std.testing.expectEqual(before + 1, f.calls);
    try std.testing.expect(f.prepared.selected_view == null);
    try std.testing.expect(f.prepared.request.plan.research == null);
    try std.testing.expectEqual(.projection_recovery, f.prepared.request.plan.reason);
    try std.testing.expect(std.mem.indexOf(u8, f.prepared.body.bytes, "oversized") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        f.prepared.body.bytes,
        "domain 41 revision 7",
    ) != null);
    try std.testing.expect(f.prepared.body.bytes.len <= 1024 * 1024);
}

test "insufficient protected minimum parks without inference or fabricated completion" {
    var f: Fixture = undefined;
    try f.initOptions(.{ .request_bytes = 1, .begin = false });
    defer f.deinit();
    for (0..16384) |_| {
        var parent = try f.service.task(f.permanent, f.task);
        defer parent.deinit();
        try std.testing.expectEqual(@as(u64, 0), parent.value.inference_attempts);
        try std.testing.expect(!parent.value.terminal());
        if (try f.service.pendingQuestion(f.permanent, f.task)) |saved| {
            var question = saved;
            defer question.deinit();
            const prompt = try f.namespace.store.object(f.permanent, question.value.prompt, null);
            try std.testing.expect(std.mem.indexOf(u8, prompt, "request budget") != null);
            for (0..2) |_| {
                const idle = try f.service.pump(f.permanent);
                try std.testing.expect(idle == .waiting or idle == .idle);
            }
            var after = try f.service.task(f.permanent, f.task);
            defer after.deinit();
            try std.testing.expectEqual(@as(u64, 0), after.value.inference_attempts);
            return;
        }
        const step = try f.service.pump(f.permanent);
        if (step == .work) {
            try std.testing.expect(!step.work.entry.declaration.inference);
            try f.complete(step.work);
        }
    }
    return error.ProjectionMinimumDidNotPark;
}
