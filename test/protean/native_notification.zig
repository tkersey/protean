const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const native = @import("protean_native");
const support = @import("native_test_support.zig");
const contracts = protean.contracts;
const identity = protean.notification.identity_prefix ++ "owner-dm";
const Request = protean.notification.Request(contracts.Utf8, u64, contracts.Utf8);
const Reply = struct { key: u64, receipt: u64 };
const Types = struct {
    pub const application_id = "notification-test";
    pub const input_schema_id = "notification.input.v1";
    pub const output_schema_id = "notification.output.v1";
    pub const failure_schema_id = "notification.failure.v1";
    pub const message_schema_id = "notification.message.v1";
    pub const Input = union(enum) { inspect: void, delivery: Request };
    pub const Output = union(enum) { inspect: void, delivery: Reply };
    pub const Failure = void;
    pub const Message = void;
};
const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const input = try horos.authoring.interop.schemaId(c.author, try c.schema(Types.Input));
        const output = try horos.authoring.interop.schemaId(c.author, try c.schema(Types.Output));
        const failure = try b.scalar(void);
        const ordinary = try b.declare(&.{input}, output, &.{}, &.{});
        try b.define(ordinary, try b.pure(try b.primitive(
            output,
            .variant,
            &.{try b.constant(void, {})},
            0,
        )));
        const entry = try protean.notification.Dispatcher(Types.Input, Types.Output).emit(
            c,
            "owner-dm",
            ordinary,
        );
        return b.module(entry, failure);
    }
};
const Sender = struct {
    acquisitions: u32 = 0,

    fn unavailable(_: native.Context, _: Request) !Reply {
        return error.CaptureRequired;
    }

    fn prepare(ctx: native.registry.ProjectionContext, payload: []const u8) ![]u8 {
        var request = try contracts.decodeOwned(Request, ctx.allocator, payload);
        defer request.deinit();
        try expectRequest(request.value);
        return ctx.allocator.dupe(u8, payload);
    }

    fn acquire(ctx: native.Context, prepared: []const u8) !native.registry.Acquisition {
        const sender: *Sender = @ptrCast(@alignCast(ctx.environment.?));
        var request = try contracts.decodeOwned(Request, ctx.allocator, prepared);
        defer request.deinit();
        try expectRequest(request.value);
        sender.acquisitions += 1;
        return .{ .captured = try ctx.allocator.dupe(u8, "delivered:42") };
    }

    fn interpret(
        ctx: native.registry.ProjectionContext,
        payload: []const u8,
        prepared: []const u8,
        captured: []const u8,
    ) !native.registry.Projection {
        try std.testing.expectEqualSlices(u8, payload, prepared);
        try std.testing.expectEqualStrings("delivered:42", captured);
        var request = try contracts.decodeOwned(Request, ctx.allocator, payload);
        defer request.deinit();
        try expectRequest(request.value);
        return .{ .reply = try contracts.encodeOwned(Reply, ctx.allocator, .{
            .key = request.value.key,
            .receipt = 42,
        }) };
    }
};

fn requestInput() Types.Input {
    return .{ .delivery = .{
        .destination = .{ .bytes = "owner-dm" },
        .key = 19,
        .payload = .{ .bytes = "Commit digest" },
    } };
}

fn expectRequest(request: Request) !void {
    try std.testing.expectEqualStrings("owner-dm", request.destination.bytes);
    try std.testing.expectEqual(19, request.key);
    try std.testing.expectEqualStrings("Commit digest", request.payload.bytes);
}

fn notificationDeclaration() native.Declaration {
    var declaration = native.leaf(Request, Reply, .{
        .identity = identity,
        .resource_role = "notification",
        .background = true,
    }, Sender.unavailable);
    declaration.invoke = null;
    declaration.capture = .{
        .prepare = Sender.prepare,
        .acquire = Sender.acquire,
        .interpret = Sender.interpret,
        .dependencies = native.registry.opaqueProjection,
    };
    return declaration;
}

const Environment = struct {
    allocator: std.mem.Allocator,
    frame: std.mem.Allocator,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
    path: []const u8,
};

test "notification capture survives reopening without a second send" {
    try notificationTrace(false);
}

test "notification history survives consumed reply before terminal publication" {
    try notificationTrace(true);
}

fn notificationTrace(cancel_after_reply: bool) !void {
    const a = std.testing.allocator;
    var compiled = try protean.compile(a, protean.system(.{
        .InitialArgs = Types.Input,
        .Result = Types.Output,
        .Failure = Types.Failure,
        .application = Application,
    }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    try captureRecovery(a, image, admitted.identity(), cancel_after_reply);
}

fn captureRecovery(
    a: std.mem.Allocator,
    image: []const u8,
    image_id: [32]u8,
    cancel_after_reply: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const manifest = try support.ownerManifest(frame, image, image_id, "notification-test");
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "unit",
        .image_identity = image_id,
    };
    defer application.deinit();
    application.manifest = (try native.json.parse(frame, manifest, .{})).value;
    var handlers = try native.Registry.init(a, &.{notificationDeclaration()});
    defer handlers.deinit();
    var sender: Sender = .{};
    var grants = [_]native.registry.Grant{.{
        .identity = identity,
        .resource_role = "notification",
        .resource_identity = image_id,
    }};
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(51),
        .bytes = "notification-profile",
        .environment = &sender,
        .authority = .{ .grants = &grants, .principal = "owner", .tenant = "test" },
    };
    grants[0].resource_identity = try profile.resourceIdentity(frame, image_id);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const env: Environment = .{
        .allocator = a,
        .frame = frame,
        .assets = .{ .image = image, .application = "notification-test", .manifest = manifest },
        .application = &application,
        .handlers = handlers,
        .profile = profile,
        .path = try std.fmt.allocPrint(frame, "{s}/state", .{path_buffer[0..length]}),
    };
    try historyDispositions(env);
    const task = try captureBeforeOutcome(env);
    try std.testing.expectEqual(1, sender.acquisitions);
    if (cancel_after_reply) {
        try consumeBeforeTerminal(env, task);
        try reopenConsumed(env, task);
    } else {
        try resumeCapture(env, task);
        try auditApplicationReadability(env);
    }
    try std.testing.expectEqual(1, sender.acquisitions);
}

fn auditApplicationReadability(env: Environment) !void {
    try std.testing.expectError(error.UnsupportedApplicationSchema, native.Namespace.audit(
        env.allocator,
        std.testing.io,
        env.path,
        env.handlers,
        .{ .validate = rejectAuditValue },
    ));
    var count: u32 = 0;
    const report = try native.Namespace.audit(
        env.allocator,
        std.testing.io,
        env.path,
        env.handlers,
        .{ .context = &count, .validate = acceptAuditValue },
    );
    try std.testing.expectEqual(5, count);
    try std.testing.expectEqual(3, report.tasks);
    try std.testing.expectEqual(2, report.nonterminal_tasks);
    try std.testing.expectEqual(.verified, report.application_readability);
    try std.testing.expectEqual(.not_assessed, report.continuation_compatibility);
}

fn rejectAuditValue(_: ?*anyopaque, _: native.NamespaceApplicationValue) !void {
    return error.UnsupportedApplicationSchema;
}

fn acceptAuditValue(context: ?*anyopaque, value: native.NamespaceApplicationValue) !void {
    const count: *u32 = @ptrCast(@alignCast(context.?));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(Types.application_id, value.application_id);
    if (value.kind == .input) {
        try std.testing.expectEqualStrings(Types.input_schema_id, value.schema_id);
        var input = try contracts.decodeOwned(Types.Input, a, value.bytes);
        defer input.deinit();
        try expectRequest(input.value.delivery);
    } else {
        try std.testing.expectEqualStrings(Types.output_schema_id, value.schema_id);
        const output = if (value.encoding == .contract) blk: {
            const decoded = try contracts.decodeOwned(Types.Output, a, value.bytes);
            break :blk decoded.value;
        } else try native.values.fromJson(
            Types.Output,
            a,
            (try native.json.parse(a, value.bytes, .{})).value,
        );
        try std.testing.expectEqual(42, output.delivery.receipt);
    }
    count.* += 1;
}

fn openService(env: Environment, namespace: *native.Namespace) !native.tasks.Service(Types) {
    return native.tasks.Service(Types).init(
        env.allocator,
        std.testing.io,
        namespace,
        env.assets,
        env.application,
        env.handlers,
        env.profile,
    );
}

fn captureBeforeOutcome(env: Environment) ![16]u8 {
    var namespace = try native.Namespace.open(env.allocator, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var service = try openService(env, &namespace);
    defer support.cleanup("service", service.close(env.frame));
    const admitted = try service.submit(env.frame, "notification-submit", requestInput());
    const empty = try service.notificationHistory(env.frame, admitted.receipt.task, identity);
    try std.testing.expectEqual(0, empty.attempts);
    try std.testing.expect(empty.transmissionExcluded());
    for (0..32) |_| {
        const step = try service.pump(env.frame);
        if (step != .work) continue;
        const work = step.work;
        try std.testing.expectEqualStrings(identity, work.entry.declaration.identity);
        const acquisition = try work.entry.declaration.capture.?.acquire(.{
            .allocator = env.frame,
            .io = std.testing.io,
            .authority = &env.profile.authority,
            .task_id = "notification-test",
            .profile = env.profile.bytes,
            .environment = env.profile.environment,
        }, work.prepared.?);
        try service.acquire(env.frame, work, acquisition.captured);
        const history = try expectCapturedHistory(env, &service, admitted.receipt.task, false);
        try std.testing.expectEqualSlices(u8, &work.attempt, &history.captured.?.attempt);
        const bytes = (try namespace.store.recordBytes(
            env.frame,
            "capture",
            work.attempt,
            admitted.receipt.task,
        )).?;
        var capture = try contracts.decodeOwned(native.testing.state.Capture, env.frame, bytes);
        defer capture.deinit();
        try std.testing.expect(capture.value.projection == null);
        try std.testing.expectEqualStrings(
            "delivered:42",
            try namespace.store.object(env.frame, capture.value.response.?, null),
        );
        var task = try service.task(env.frame, admitted.receipt.task);
        defer task.deinit();
        try std.testing.expect(!task.value.terminal());
        try std.testing.expect(task.value.client_result == null);
        return admitted.receipt.task;
    }
    return error.NotificationNotDispatched;
}

fn resumeCapture(env: Environment, task_id: [16]u8) !void {
    var namespace = try native.Namespace.open(env.allocator, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var service = try openService(env, &namespace);
    defer support.cleanup("service", service.close(env.frame));
    const replay = try service.submit(env.frame, "notification-submit", requestInput());
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqualSlices(u8, &task_id, &replay.receipt.task);
    try std.testing.expectEqual(.idle, try service.pump(env.frame));
    var saved = try service.task(env.frame, task_id);
    defer saved.deinit();
    _ = try service.resumeTask(env.frame, "notification-resume", task_id, saved.value.revision);
    var session = try native.Session(Types).init(&service);
    defer support.cleanup("session", session.deinit());
    for (0..32) |_| {
        _ = try session.tick(env.frame);
        try std.testing.expect(!session.busy());
        var task = try service.task(env.frame, task_id);
        defer task.deinit();
        if (!task.value.terminal()) continue;
        try std.testing.expectEqual(.completed, task.value.outcome_kind);
        try expectOutput(env.frame, &service, task_id);
        _ = try expectCapturedHistory(env, &service, task_id, true);
        try std.testing.expectEqual(1, try namespace.store.capabilityAttempts(task_id, identity));
        return;
    }
    return error.NotificationRecoveryIncomplete;
}

fn expectCapturedHistory(
    env: Environment,
    service: *native.tasks.Service(Types),
    task: [16]u8,
    interpreted: bool,
) !native.tasks.NotificationHistory {
    const history = try service.notificationHistory(env.frame, task, identity);
    try std.testing.expectEqual(1, history.attempts);
    try std.testing.expectEqual(0, history.definitely_not_sent);
    try std.testing.expectEqual(1, history.complete_captures);
    try std.testing.expectEqual(0, history.unresolved);
    try std.testing.expect(!history.transmissionExcluded());
    try std.testing.expect(history.captured != null);
    try std.testing.expect(history.captured.?.response != null);
    try std.testing.expectEqual(interpreted, history.captured.?.reply != null);
    return history;
}

fn historyDispositions(env: Environment) !void {
    var namespace = try native.Namespace.open(env.allocator, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var service = try openService(env, &namespace);
    defer support.cleanup("service", service.close(env.frame));
    const not_sent = try service.submit(env.frame, "notification-not-sent", requestInput());
    const first = try nextWork(env, &service);
    try std.testing.expectEqualSlices(u8, &not_sent.receipt.task, &first.task);
    const pending = try service.notificationHistory(env.frame, first.task, identity);
    try std.testing.expectEqual(1, pending.unresolved);
    try std.testing.expect(!pending.transmissionExcluded());
    try service.notSent(env.frame, first);
    const excluded = try service.notificationHistory(env.frame, first.task, identity);
    try std.testing.expectEqual(1, excluded.attempts);
    try std.testing.expectEqual(1, excluded.definitely_not_sent);
    try std.testing.expectEqual(0, excluded.complete_captures);
    try std.testing.expectEqual(0, excluded.unresolved);
    try std.testing.expect(excluded.transmissionExcluded());
    const unknown = try service.submit(env.frame, "notification-unknown", requestInput());
    const second = try nextWork(env, &service);
    try std.testing.expectEqualSlices(u8, &unknown.receipt.task, &second.task);
    try service.unknown(env.frame, second);
    const unresolved = try service.notificationHistory(env.frame, second.task, identity);
    try std.testing.expectEqual(1, unresolved.attempts);
    try std.testing.expectEqual(1, unresolved.unresolved);
    try std.testing.expectEqual(0, unresolved.definitely_not_sent);
    try std.testing.expect(!unresolved.transmissionExcluded());
    try std.testing.expect(unresolved.captured == null);
    try std.testing.expectError(
        error.InvalidCapability,
        service.notificationHistory(env.frame, first.task, "unrelated.read"),
    );
    try std.testing.expectError(
        error.UnsupportedCapability,
        service.notificationHistory(env.frame, first.task, identity ++ ".unregistered"),
    );
}

fn nextWork(env: Environment, service: *native.tasks.Service(Types)) !native.tasks.Work {
    for (0..32) |_| {
        const step = try service.pump(env.frame);
        if (step == .work) return step.work;
    }
    return error.NotificationNotDispatched;
}

fn consumeBeforeTerminal(env: Environment, task_id: [16]u8) !void {
    var namespace = try native.Namespace.open(env.allocator, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var service = try openService(env, &namespace);
    defer support.cleanup("service", service.close(env.frame));
    var saved = try service.task(env.frame, task_id);
    defer saved.deinit();
    _ = try service.resumeTask(env.frame, "notification-settle", task_id, saved.value.revision);
    try std.testing.expectEqual(.progressed, try service.pump(env.frame));
    _ = try expectCapturedHistory(env, &service, task_id, true);
    _ = try service.requestCancel(env.frame, "notification-cancel", task_id, "Owner paused");
    for (0..32) |_| {
        try std.testing.expect(try service.pump(env.frame) != .work);
        var task = try service.task(env.frame, task_id);
        defer task.deinit();
        if (task.value.terminal()) return error.ConsumedPreterminalCutMissing;
        if (task.value.current_occurrence != null) continue;
        try expectConsumedCut(env, &service, &namespace, task_id);
        return;
    }
    return error.ConsumedPreterminalCutMissing;
}

fn expectConsumedCut(
    env: Environment,
    service: *native.tasks.Service(Types),
    namespace: *native.Namespace,
    task_id: [16]u8,
) !void {
    var task = try service.task(env.frame, task_id);
    defer task.deinit();
    try std.testing.expect(!task.value.terminal());
    try std.testing.expect(task.value.current_occurrence == null);
    try std.testing.expect(task.value.client_result == null);
    try std.testing.expect(task.value.cancellation != null);
    try std.testing.expect(!task.value.cancellation_applied);
    const history = try expectCapturedHistory(env, service, task_id, true);
    const bytes = (try namespace.store.recordBytes(
        env.frame,
        "occurrence",
        history.captured.?.occurrence,
        task_id,
    )).?;
    var occurrence = try contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        env.frame,
        bytes,
    );
    defer occurrence.deinit();
    try std.testing.expect(occurrence.value.state == .admitted);
    try std.testing.expect(occurrence.value.state.admitted == .reply);
    try std.testing.expectEqualSlices(
        u8,
        &history.captured.?.attempt,
        &occurrence.value.state.admitted.reply.attempt,
    );
}

fn reopenConsumed(env: Environment, task_id: [16]u8) !void {
    var namespace = try native.Namespace.open(env.allocator, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var service = try openService(env, &namespace);
    defer support.cleanup("service", service.close(env.frame));
    try expectConsumedCut(env, &service, &namespace, task_id);
    try std.testing.expectEqual(.idle, try service.pump(env.frame));
}

fn expectOutput(a: std.mem.Allocator, service: *native.tasks.Service(Types), task: [16]u8) !void {
    var output = (try service.applicationValue(a, task, .result)).?;
    defer output.deinit();
    try std.testing.expectEqualStrings(Types.output_schema_id, output.schema_id);
    try std.testing.expectEqual(.json, output.encoding);
    const parsed = try native.json.parse(a, output.bytes, .{});
    defer parsed.deinit();
    const result = try native.values.fromJson(Types.Output, a, parsed.value);
    try std.testing.expect(result == .delivery);
    try std.testing.expectEqual(19, result.delivery.key);
    try std.testing.expectEqual(42, result.delivery.receipt);
}
