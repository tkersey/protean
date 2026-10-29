//! Opt-in measurement through the real task owner. Setup, commits and checks
//! are outside each timed idle scan; no timing threshold is a correctness gate.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const fixtures = @import("native_tasks.zig");

fn increment(_: native.Context, value: u32) !u32 {
    return value + 1;
}

fn present(ctx: native.Context, value: u32) !native.json.Value {
    return native.json.number(ctx.allocator, value);
}

test "native scheduler backlog benchmark" {
    const a = std.heap.smp_allocator;
    const io = std.testing.io;
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = u32,
            .Result = u32,
            .Failure = void,
            .application = fixtures.FairApplication,
        }),
    );
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const manifest = try fixtures.ownerManifest(
        a,
        image,
        admitted.identity(),
        "scheduler-benchmark",
    );
    defer a.free(manifest);
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "scheduler-benchmark",
        .manifest = manifest,
    };
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    var handlers = try schedulerHandlers(a);
    defer handlers.deinit();
    var grants: [3]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "scheduler-benchmark", .authority = .{
        .grants = &grants,
        .principal = "test",
        .tenant = "test",
    } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{
        .identity = entry.declaration.identity,
        .resource_role = entry.declaration.resource_role,
        .resource_identity = try profile.resourceIdentity(a, application.image_identity),
    };

    for ([_]usize{ 256, 1024, 4096, 16384 }) |count| {
        try schedulerCase(a, io, assets, &application, handlers, profile, count);
    }
}

fn schedulerHandlers(a: std.mem.Allocator) !native.Registry {
    var leaf = native.leaf(
        u32,
        u32,
        .{ .identity = "fair.leaf.v1", .resource_role = "local" },
        increment,
    );
    leaf.background = true;
    return native.Registry.init(a, &.{
        leaf,
        native.question(
            u32,
            u32,
            .{
                .identity = "fair.question.v1",
                .resource_role = "user",
                .answer_schema_id = "fair.answer.v1",
            },
            present,
        ),
        native.inbox.declaration(u32),
    });
}

fn schedulerCase(
    a: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
    count: usize,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer @import("native_test_support.zig").cleanup("namespace close", namespace.close());
    var service = try native.tasks.Service(fixtures.FairTypes).init(
        a,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer @import("native_test_support.zig").cleanup("service close", service.close(a));
    var setup = std.heap.ArenaAllocator.init(a);
    defer setup.deinit();
    const frame = setup.allocator();
    _ = try service.submit(frame, "held", 1);
    try std.testing.expect(try service.pump(frame) == .progressed);
    const held = (try service.pump(frame)).work;
    defer @import("native_test_support.zig").cleanup(
        "held work release",
        service.notSent(frame, held),
    );
    try measureScheduler(a, io, &service, &namespace, held, count);
}

fn measureScheduler(
    a: std.mem.Allocator,
    io: std.Io,
    service: *native.tasks.Service(fixtures.FairTypes),
    namespace: *native.Namespace,
    held: anytype,
    count: usize,
) !void {
    const ids = try a.alloc([16]u8, count);
    defer a.free(ids);
    for (ids, 0..) |*id, i| {
        var request = std.heap.ArenaAllocator.init(a);
        defer request.deinit();
        const operation = try std.fmt.allocPrint(request.allocator(), "waiting-{d}", .{i});
        id.* = (try service.submit(request.allocator(), operation, 1)).receipt.task;
    }
    for (0..count) |_| {
        var request = std.heap.ArenaAllocator.init(a);
        defer request.deinit();
        try std.testing.expect(try service.pump(request.allocator()) == .progressed);
    }
    const head = namespace.store.head;
    for (0..8) |sample| {
        var request = std.heap.ArenaAllocator.init(a);
        defer request.deinit();
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        const step = try service.pump(request.allocator());
        const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
        try std.testing.expect(step == .idle);
        try std.testing.expectEqualDeep(head, namespace.store.head);
        // Sample zero warms the same read path on both implementations.
        if (sample != 0) std.debug.print("scheduler_idle tasks={d} sample={d} ns={d}\n", .{
            count,
            sample,
            elapsed,
        });
    }
    try expectWaitingTasks(a, service, namespace, ids, held);
}

fn expectWaitingTasks(
    a: std.mem.Allocator,
    service: *native.tasks.Service(fixtures.FairTypes),
    namespace: *native.Namespace,
    ids: []const [16]u8,
    held: anytype,
) !void {
    for (ids) |id| {
        var request = std.heap.ArenaAllocator.init(a);
        defer request.deinit();
        var task = try service.task(request.allocator(), id);
        defer task.deinit();
        try std.testing.expectEqual(1, task.value.execution_revision);
        try std.testing.expectEqual(.requested, task.value.outcome_kind);
        try std.testing.expectEqual(
            0,
            try namespace.store.capabilityAttempts(id, "fair.leaf.v1"),
        );
    }
    try std.testing.expectEqualSlices(u8, &held.attempt, &service.work.?.attempt);
}
