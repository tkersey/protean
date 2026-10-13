//! Process-death fixture. The independent controller kills this test runner at
//! observable owner/adapter boundaries; no graceful close or test-only owner
//! mutation substitutes for losing the process and its worker.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const fixtures = @import("native_tasks.zig");
const C = protean.contracts;
const State = native.testing.state;
const Occurrence = native.testing.occurrence.Occurrence;
const Service = native.tasks.Service(fixtures.FairTypes);

const Witness = struct {
    task: [16]u8,
    occurrence: [32]u8,
    attempt: [32]u8 = @splat(0),
    recovery: ?[32]u8 = null,
    revision: u64 = 0,
    request_bytes: u64 = 0,
};
var witness: Witness = undefined;
var phase: []const u8 = undefined;
var process_io: std.Io = undefined;
var verifying = false;
var original_calls: usize = 0;
var lookup_calls: usize = 0;

fn emit(value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(process_io, &buffer);
    try std.json.Stringify.value(value, .{}, &out.interface);
    try out.interface.writeByte('\n');
    try out.interface.flush();
}
fn stopAt(point: []const u8) !void {
    if (verifying or !std.mem.eql(u8, phase, point)) return;
    try emit(.{ .cut = phase, .witness = witness });
    while (true) try process_io.sleep(.fromSeconds(1), .awake);
}
fn prepare(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    return ctx.allocator.dupe(u8, bytes);
}
fn original(ctx: native.Context, _: []const u8) !native.registry.Acquisition {
    original_calls += 1;
    if (verifying) return error.OriginalEffectMustNotRun;
    try emit(.{ .invoked = "original" });
    try stopAt("original-invoked");
    return .{ .captured = try C.encodeOwned(u32, ctx.allocator, 99) };
}
fn lookup(ctx: native.Context, input: native.registry.RecoveryInput, _: []const u8, _: ?[]const u8) ![]u8 {
    lookup_calls += 1;
    if (verifying) return error.LookupMustNotRestart;
    try emit(.{ .invoked = "lookup" });
    try stopAt("lookup-invoked");
    return fixtures.LookupFixture.receipt(ctx.allocator, input, .capture);
}
fn interpret(ctx: native.registry.ProjectionContext, payload: []const u8, prepared: []const u8, raw: []const u8) !native.registry.Projection {
    const result = try fixtures.LookupFixture.interpret(ctx, payload, prepared, raw);
    // The projection exists, but no owner transaction has published it yet.
    try stopAt(if (witness.recovery == null) "original-interpreted" else "lookup-interpreted");
    return result;
}
fn forbidden(_: native.Context, _: u32) !u32 {
    return error.OriginalEffectMustNotRun;
}
fn present(ctx: native.Context, input: u32) !native.json.Value {
    return native.json.number(ctx.allocator, input);
}
fn record(comptime T: type, a: std.mem.Allocator, namespace: *native.Namespace, comptime kind: []const u8, id: [32]u8) !C.Decoded(T) {
    const bytes = (try namespace.store.recordBytes(a, kind, id, witness.task)) orelse return error.MissingRecord;
    defer a.free(bytes);
    return C.decodeOwned(T, a, bytes);
}

test "process-crash-controller-only" {
    const io = std.testing.io;
    process_io = io;
    const env = std.testing.environ;
    const mode = env.getPosix("PROTEAN_CRASH_MODE") orelse return error.InvalidArguments;
    verifying = std.mem.eql(u8, mode, "verify");
    if (!verifying and !std.mem.eql(u8, mode, "crash")) return error.InvalidArguments;
    const path = env.getPosix("PROTEAN_CRASH_PATH") orelse return error.InvalidArguments;
    phase = env.getPosix("PROTEAN_CRASH_PHASE") orelse return error.InvalidArguments;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (verifying) witness = (try std.json.parseFromSlice(Witness, a, env.getPosix("PROTEAN_CRASH_WITNESS") orelse return error.InvalidArguments, .{})).value;
    var compiled = try protean.compile(std.testing.allocator, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = fixtures.FairApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(std.testing.allocator, image);
    const admitted = try horos.data.program_image.Admitted.decode(std.testing.allocator, image);
    defer admitted.deinit();
    const manifest = try fixtures.ownerManifest(a, image, admitted.identity(), "crash-owner");
    const assets: native.discovery.Assets = .{ .image = image, .application = "crash-owner", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(std.testing.allocator), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var leaf = native.leaf(u32, u32, .{ .identity = "fair.leaf.v1", .resource_role = "local", .inference = true }, forbidden);
    leaf.capture = .{ .prepare = prepare, .acquire = original, .interpret = interpret, .dependencies = native.registry.opaqueProjection };
    leaf.invoke = null;
    leaf.background = true;
    leaf.recovery = .{ .identity = "signed-fixture-receipt.v1", .version = 1, .lookup = .{ .acquire = lookup, .verify = fixtures.LookupFixture.verify } };
    var handlers = try native.Registry.init(std.testing.allocator, &.{ leaf, native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, present), native.inbox.declaration(u32) });
    defer handlers.deinit();
    var grants: [3]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "crash", .runtime_identity = @splat(42), .bytes = "frozen-profile", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test", .inference = true } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
    var namespace = try native.Namespace.open(std.testing.allocator, io, path);
    defer namespace.close() catch unreachable;
    var service = try Service.init(std.testing.allocator, io, &namespace, assets, &application, handlers, profile);
    // Crash branches never run these defers. A test error remains a failed run.
    defer service.close(a) catch unreachable;
    if (verifying) {
        try verify(a, &service, &namespace);
        _ = try namespace.store.auditRetention(handlers, application.image_identity);
        try emit(.{ .verified = phase });
        return;
    }
    const submitted = try service.submit(a, "original", 1);
    for (0..20) |_| {
        _ = try service.pump(a);
        var task = try service.task(a, submitted.receipt.task);
        defer task.deinit();
        if (task.value.current_occurrence) |id| {
            witness = .{ .task = submitted.receipt.task, .occurrence = id };
            break;
        }
    } else return error.MissingOccurrence;
    try stopAt("original-ready");
    var work = (try service.pump(a)).work;
    witness.attempt = work.attempt;
    var before = try service.task(a, witness.task);
    defer before.deinit();
    witness.request_bytes = before.value.inference_request_bytes;
    if (std.mem.startsWith(u8, phase, "lookup-")) {
        try service.unknown(a, work);
        var unknown = try service.task(a, witness.task);
        defer unknown.deinit();
        witness.revision = unknown.value.revision;
        const recovery = try service.reconcile(a, "recover", witness.task, witness.revision, witness.occurrence, witness.attempt, .lookup);
        witness.recovery = recovery.receipt.reconciliation.?;
        try stopAt("lookup-admitted");
        work = (try service.pump(a)).work;
        try stopAt("lookup-dispatched");
    } else try stopAt("original-dispatched");
    const worker = try native.testing.Worker.init(a, io);
    try worker.start(work, profile.authority, null);
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (!worker.finished()) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.WorkerTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try worker.join();
    try stopAt(if (witness.recovery == null) "original-acquired" else "lookup-acquired");
    try service.acquire(a, work, worker.reply orelse return error.MissingReply);
    try worker.release();
    try worker.deinit(a);
    try stopAt(if (witness.recovery == null) "original-captured" else "lookup-captured");
    _ = try service.pump(a);
    try stopAt(if (witness.recovery == null) "original-settled" else "lookup-settled");
    _ = try service.pump(a);
    try stopAt(if (witness.recovery == null) "original-completed" else "lookup-completed");
    return error.UnknownCut;
}

fn verify(a: std.mem.Allocator, service: *Service, namespace: *native.Namespace) !void {
    try std.testing.expect(try service.pump(a) == .idle);
    var task = try service.task(a, witness.task);
    defer task.deinit();
    var occurrence = try record(Occurrence, a, namespace, "occurrence", witness.occurrence);
    defer occurrence.deinit();
    const ready = std.mem.endsWith(u8, phase, "-ready");
    const captured = std.mem.endsWith(u8, phase, "-captured") or std.mem.endsWith(u8, phase, "-interpreted");
    const settled = std.mem.endsWith(u8, phase, "-settled");
    const completed = std.mem.endsWith(u8, phase, "-completed");
    const unknown = !ready and !captured and !settled and !completed;
    const expected: std.meta.Tag(@TypeOf(occurrence.value.state)) = if (ready) .ready else if (captured) .captured else if (settled) .settled_reply else if (completed) .admitted else .unknown;
    try std.testing.expectEqual(expected, std.meta.activeTag(occurrence.value.state));
    try std.testing.expectEqual(@as(u64, if (ready) 0 else 1), task.value.inference_attempts);
    try std.testing.expectEqual(witness.request_bytes, task.value.inference_request_bytes);
    try std.testing.expectEqual(@as(u64, if (settled or completed) 7 else 0), task.value.inference_output_tokens);
    try std.testing.expect((try service.submit(a, "original", 1)).replayed);
    if (captured or settled or completed) {
        var raw = try record(State.Capture, a, namespace, "capture", witness.attempt);
        defer raw.deinit();
        try std.testing.expect(raw.value.disposition == .complete);
        try std.testing.expectEqual(settled or completed, raw.value.projection != null);
        const bytes = try namespace.store.object(a, raw.value.response.?, null);
        try std.testing.expectEqualSlices(u8, try C.encodeOwned(u32, a, 99), bytes);
        try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(a, witness.task, raw.value.response.?.digest));
    }
    if (witness.recovery) |id| {
        var recovery = try service.reconciliation(a, witness.task, id);
        defer recovery.deinit();
        if (unknown) {
            try std.testing.expect(recovery.value.outcome == .unresolved and recovery.value.outcome.unresolved == .interrupted);
        } else if (captured) {
            try std.testing.expect(recovery.value.outcome == .capture_admitted);
        } else try std.testing.expect(recovery.value.outcome == .reply_settled);
        try std.testing.expect((try service.reconcile(a, "recover", witness.task, witness.revision, witness.occurrence, witness.attempt, .lookup)).replayed);
        try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(a, witness.task, recovery.value.original_occurrence.digest));
    }
    if (unknown) {
        try std.testing.expectError(error.UnsettledOccurrence, service.resumeTask(a, "resume", witness.task, task.value.revision));
    } else if (captured or settled) {
        _ = try service.resumeTask(a, "resume", witness.task, task.value.revision);
        for (0..6) |_| try std.testing.expect(try service.pump(a) != .work);
    }
    if (captured or settled or completed) {
        var final = try service.task(a, witness.task);
        defer final.deinit();
        try std.testing.expect(final.value.outcome_kind == .completed);
        try std.testing.expectEqual(7, final.value.inference_output_tokens);
        const result = try namespace.store.object(a, final.value.result.?, null);
        var decoded = try C.decodeOwned(u32, a, result);
        defer decoded.deinit();
        try std.testing.expectEqual(99, decoded.value);
    }
    try std.testing.expectEqual(0, original_calls);
    try std.testing.expectEqual(0, lookup_calls);
    try std.testing.expect(try service.pump(a) == .idle);
}
