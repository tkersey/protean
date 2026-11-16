const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const native = @import("protean_native");
const support = @import("native_test_support.zig");
const c = protean.contracts;
const identity = "attempt-view.capture.v1";
const Types = struct {
    pub const application_id = "attempt-view-test";
    pub const input_schema_id = "attempt-view.input.v1";
    pub const output_schema_id = "attempt-view.output.v1";
    pub const failure_schema_id = "attempt-view.failure.v1";
    pub const message_schema_id = "attempt-view.message.v1";
    pub const Input = u32;
    pub const Output = u32;
    pub const Failure = void;
    pub const Message = void;
};
const Service = native.tasks.Service(Types);
const Application = struct {
    pub fn emit(context: protean.Context) !horos.source.Module {
        const b = context.builder;
        const number = try b.scalar(u32);
        const effect = try horos.authoring.interop.operationId(
            context.author,
            try context.external(identity, try context.schema(u32), try context.schema(u32), .read),
        );
        const entry = try b.declare(&.{number}, number, &.{effect}, &.{});
        const result = try b.variable(number);
        try b.define(entry, try b.bind(
            result,
            try b.term(.{ .perform = .{
                .effect = effect,
                .payload = try b.reference(b.parameter(entry, 0)),
            } }),
            try b.term(.{ .yield_then = try b.pure(try b.reference(result)) }),
        ));
        return b.module(entry, try b.scalar(void));
    }
};
const Capture = struct {
    fn invoke(_: native.Context, value: u32) !u32 {
        return value;
    }

    fn prepare(context: native.registry.ProjectionContext, payload: []const u8) ![]u8 {
        return context.allocator.dupe(u8, payload);
    }

    fn acquire(context: native.Context, prepared: []const u8) !native.registry.Acquisition {
        return .{ .captured = try context.allocator.dupe(u8, prepared) };
    }

    fn interpret(
        context: native.registry.ProjectionContext,
        _: []const u8,
        prepared: []const u8,
        captured: []const u8,
    ) !native.registry.Projection {
        try std.testing.expectEqualSlices(u8, prepared, captured);
        return .{ .reply = try context.allocator.dupe(u8, captured), .output_tokens = 7 };
    }

    fn declaration() native.Declaration {
        var result = native.leaf(u32, u32, .{
            .identity = identity,
            .resource_role = "reader",
            .background = true,
        }, invoke);
        result.invoke = null;
        result.inference = true;
        result.capture = .{
            .prepare = prepare,
            .acquire = acquire,
            .interpret = interpret,
            .dependencies = native.registry.opaqueProjection,
        };
        return result;
    }
};
const Environment = struct {
    a: std.mem.Allocator,
    frame: std.mem.Allocator,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
    path: []const u8,

    fn open(env: Environment, namespace: *native.Namespace) !Service {
        return Service.init(
            env.a,
            std.testing.io,
            namespace,
            env.assets,
            env.application,
            env.handlers,
            env.profile,
        );
    }
};

test "retained attempt views bind revisions ownership and consumed capture bytes" {
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
    try runViews(a, image, admitted.identity());
}

fn runViews(a: std.mem.Allocator, image: []const u8, image_id: [32]u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const manifest = try support.ownerManifest(frame, image, image_id, Types.application_id);
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = (try native.json.parse(frame, manifest, .{})).value,
        .manifest_id = "unit",
        .image_identity = image_id,
    };
    defer application.deinit();
    var handlers = try native.Registry.init(a, &.{Capture.declaration()});
    defer handlers.deinit();
    var grants = [_]native.registry.Grant{.{
        .identity = identity,
        .resource_role = "reader",
        .resource_identity = image_id,
    }};
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(51),
        .bytes = "attempt-view-profile",
        .authority = .{
            .grants = &grants,
            .principal = "owner",
            .tenant = "test",
            .inference = true,
        },
    };
    grants[0].resource_identity = try profile.resourceIdentity(frame, image_id);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const env: Environment = .{
        .a = a,
        .frame = frame,
        .assets = .{ .image = image, .application = Types.application_id, .manifest = manifest },
        .application = &application,
        .handlers = handlers,
        .profile = profile,
        .path = try std.fmt.allocPrint(frame, "{s}/state", .{path_buffer[0..length]}),
    };
    const saved = try exerciseViews(env);
    try reopenedViews(env, saved);
}

const Saved = struct { task: [16]u8, attempt: [32]u8, response: [32]u8, reply: [32]u8 };

fn revision(env: Environment, service: *Service, task: [16]u8) !u64 {
    var value = try service.task(env.a, task);
    defer value.deinit();
    return value.value.revision;
}

fn nextWork(env: Environment, service: *Service) !native.tasks.Work {
    for (0..32) |_| {
        const step = try service.pump(env.frame);
        if (step == .work) return step.work;
    }
    return error.MissingWork;
}

fn exerciseViews(env: Environment) !Saved {
    var namespace = try native.Namespace.open(env.a, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var service = try env.open(&namespace);
    defer support.cleanup("service", service.close(env.frame));
    const admission = try service.submit(env.frame, "views", 42);
    const task = admission.receipt.task;
    var empty = try service.attemptPage(env.a, task, admission.receipt.revision, null, 1);
    defer empty.deinit();
    try std.testing.expectEqual(0, empty.attempts.len);
    const first = try nextWork(env, &service);
    try service.notSent(env.frame, first);
    const before = try revision(env, &service, task);
    var negative = try service.attemptPage(env.a, task, before, null, 1);
    defer negative.deinit();
    try std.testing.expectEqual(.definitely_not_sent, negative.attempts[0].capture.?.disposition);
    const absent = try service.attemptValue(env.a, task, before, first.attempt, .response);
    try std.testing.expect(absent == null);
    _ = try service.resumeTask(env.frame, "retry", task, before);
    try std.testing.expectError(
        error.StaleRevision,
        service.attemptPage(env.a, task, before, negative.next, 1),
    );
    const second = try nextWork(env, &service);
    try service.acquire(env.frame, second, second.prepared.?);
    try checkPages(env, &service, task, first.attempt, second.attempt);
    const captured = try revision(env, &service, task);
    var capture_bytes = (try service.attemptValue(
        env.a,
        task,
        captured,
        second.attempt,
        .response,
    )).?;
    defer capture_bytes.deinit();
    try std.testing.expectEqualSlices(
        u8,
        try c.encodeOwned(u32, env.frame, 42),
        capture_bytes.bytes,
    );
    const unprojected = try service.attemptValue(env.a, task, captured, second.attempt, .reply);
    try std.testing.expect(unprojected == null);
    try std.testing.expectEqual(.progressed, try service.pump(env.frame));
    const saved = try checkValues(env, &service, task, second.attempt);
    try rejectCaptureMismatch(env, &service, &namespace, task, second.attempt);
    try std.testing.expectError(
        error.StaleRevision,
        service.attemptValue(env.a, task, captured, second.attempt, .response),
    );
    try consumeReply(env, &service, task);
    _ = try checkValues(env, &service, task, second.attempt);
    try checkUnknown(env, &service, task, second.attempt);
    return saved;
}

fn checkPages(
    env: Environment,
    service: *Service,
    task: [16]u8,
    first: [32]u8,
    second: [32]u8,
) !void {
    const cut = try revision(env, service, task);
    var page = try service.attemptPage(env.a, task, cut, null, 1);
    defer page.deinit();
    try std.testing.expectEqual(1, page.attempts.len);
    try std.testing.expectEqualStrings(identity, page.attempts[0].capability);
    try std.testing.expect(page.attempts[0].inference);
    var next = try service.attemptPage(env.a, task, cut, page.next, 1);
    defer next.deinit();
    try std.testing.expectEqual(1, next.attempts.len);
    const ids = [_][32]u8{ page.attempts[0].id, next.attempts[0].id };
    try std.testing.expect(std.meta.eql(ids[0], first) or std.meta.eql(ids[1], first));
    try std.testing.expect(std.meta.eql(ids[0], second) or std.meta.eql(ids[1], second));
    try std.testing.expect(!std.meta.eql(ids[0], ids[1]));
    var end = try service.attemptPage(env.a, task, cut, next.next, 1);
    defer end.deinit();
    try std.testing.expectEqual(0, end.attempts.len);
    try std.testing.expect(end.next == null);
    try std.testing.expectError(
        error.InvalidParams,
        service.attemptPage(env.a, task, cut, null, 0),
    );
    const principal = service.profile.authority.principal;
    service.profile.authority.principal = "different";
    defer service.profile.authority.principal = principal;
    try std.testing.expectError(error.Denied, service.attemptPage(env.a, task, cut, null, 1));
    try std.testing.expectError(
        error.Denied,
        service.attemptValue(env.a, task, cut, second, .response),
    );
}

fn checkValues(env: Environment, service: *Service, task: [16]u8, attempt: [32]u8) !Saved {
    const cut = try revision(env, service, task);
    var response = (try service.attemptValue(env.a, task, cut, attempt, .response)).?;
    defer response.deinit();
    var reply = (try service.attemptValue(env.a, task, cut, attempt, .reply)).?;
    defer reply.deinit();
    var raw = try c.decodeOwned(u32, env.a, response.bytes);
    defer raw.deinit();
    try std.testing.expectEqual(42, raw.value);
    var bound = try horos.data.invocation.decode(horos.data.invocation.Result, env.a, reply.bytes);
    defer bound.deinit();
    var value = try c.decodeOwned(u32, env.a, bound.value.value);
    defer value.deinit();
    try std.testing.expectEqual(42, value.value);
    var page = try service.attemptPage(env.a, task, cut, null, 4);
    defer page.deinit();
    for (page.attempts) |item| {
        if (!std.meta.eql(item.id, attempt)) continue;
        try std.testing.expectEqualDeep(response.reference, item.capture.?.response.?);
        try std.testing.expectEqualDeep(reply.reference, item.capture.?.reply.?);
        try std.testing.expectEqual(7, item.capture.?.output_tokens.?);
    }
    return .{
        .task = task,
        .attempt = attempt,
        .response = response.reference.digest,
        .reply = reply.reference.digest,
    };
}

fn consumeReply(env: Environment, service: *Service, task: [16]u8) !void {
    for (0..32) |_| {
        try std.testing.expect(try service.pump(env.frame) != .work);
        var value = try service.task(env.a, task);
        defer value.deinit();
        if (value.value.current_occurrence == null) return;
    }
    return error.UnconsumedReply;
}

fn rejectCaptureMismatch(
    env: Environment,
    service: *Service,
    namespace: *native.Namespace,
    task: [16]u8,
    attempt: [32]u8,
) !void {
    const encoded = (try namespace.store.recordBytes(env.frame, "capture", attempt, task)).?;
    var original = try c.decodeOwned(native.testing.state.Capture, env.a, encoded);
    defer original.deinit();
    var bad = original.value;
    bad.task = @splat(0);
    const cut = try revision(env, service, task);
    try namespace.store.begin();
    defer namespace.store.rollback();
    try namespace.store.putRecord(native.testing.state.Capture, "capture", attempt, task, bad);
    try namespace.commit("test.capture-mismatch");
    try std.testing.expectError(
        error.CorruptState,
        service.attemptPage(env.a, task, cut, null, 2),
    );
    try std.testing.expectError(
        error.CorruptState,
        service.attemptValue(env.a, task, cut, attempt, .reply),
    );
    try namespace.store.begin();
    try namespace.store.putRecord(
        native.testing.state.Capture,
        "capture",
        attempt,
        task,
        original.value,
    );
    try namespace.commit("test.capture-restored");
}

fn checkUnknown(env: Environment, service: *Service, other: [16]u8, other_attempt: [32]u8) !void {
    const admission = try service.submit(env.frame, "unknown", 43);
    const work = try nextWork(env, service);
    try service.unknown(env.frame, work);
    const cut = try revision(env, service, admission.receipt.task);
    var page = try service.attemptPage(env.a, admission.receipt.task, cut, null, 2);
    defer page.deinit();
    try std.testing.expectEqual(1, page.attempts.len);
    try std.testing.expect(page.attempts[0].capture == null);
    try std.testing.expectError(
        error.CorruptState,
        service.attemptValue(env.a, admission.receipt.task, cut, other_attempt, .reply),
    );
    try std.testing.expect(!std.meta.eql(other, admission.receipt.task));
}

fn reopenedViews(env: Environment, saved: Saved) !void {
    var namespace = try native.Namespace.open(env.a, std.testing.io, env.path);
    defer support.cleanup("namespace", namespace.close());
    var changed = env;
    changed.profile.runtime_identity = @splat(52);
    var service = try changed.open(&namespace);
    defer support.cleanup("service", service.close(env.frame));
    const observed = try checkValues(env, &service, saved.task, saved.attempt);
    try std.testing.expectEqualDeep(saved, observed);
    const cut = try revision(env, &service, saved.task);
    try std.testing.checkAllAllocationFailures(env.a, allocatePage, .{ &service, saved.task, cut });
    try std.testing.checkAllAllocationFailures(
        env.a,
        allocateValue,
        .{ &service, saved.task, cut, saved.attempt },
    );
}

fn allocatePage(a: std.mem.Allocator, service: *Service, task: [16]u8, cut: u64) !void {
    var page = try service.attemptPage(a, task, cut, null, 2);
    defer page.deinit();
    try std.testing.expectEqual(2, page.attempts.len);
}

fn allocateValue(
    a: std.mem.Allocator,
    service: *Service,
    task: [16]u8,
    cut: u64,
    attempt: [32]u8,
) !void {
    var value = (try service.attemptValue(a, task, cut, attempt, .reply)).?;
    defer value.deinit();
    try std.testing.expect(value.bytes.len != 0);
}
