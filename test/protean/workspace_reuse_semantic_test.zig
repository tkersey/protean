const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const support = @import("workspace_test_support.zig");
const wc = contracts.workspace;
const Task = native.testing.state.TaskId;

pub fn retain(
    service: anytype,
    a: std.mem.Allocator,
    captured: native.testing.state.Capture,
    approved: ?native.tasks.SemanticPolicy,
) !wc.RetainedLocator {
    const original = service.profile;
    defer service.profile = original;
    service.profile.semantic_construction = approved;
    @import("workspace_reuse_test.zig").configure(&service.profile);
    const bytes = try service.namespace.store.object(a, captured.request, null);
    defer a.free(bytes);
    var input = try contracts.decodeOwned(native.testing.workspace_build.Input, a, bytes);
    defer input.deinit();
    try std.testing.expect(input.value == .validate);
    {
        var rows = try service.namespace.store.database.prepare(
            "SELECT count(*) FROM records WHERE task=? AND kind='workspace_runtime'",
            &.{.{ .blob = &captured.task }},
        );
        defer rows.deinit();
        try std.testing.expectEqual(.row, try rows.step());
        try std.testing.expectEqual(@as(i64, 1), try rows.integer(0));
    }
    const reply = try service.workspaceCommand(a, "retain-semantic-history", captured.task, .{
        .program = .{ .retain = .{
            .program = try support.workspaceRef(a, .program, input.value.validate.program),
            .scope = .{ .bytes = "methods" },
            .description = .{
                .name = .{ .bytes = "semantic history" },
                .purpose = .{ .bytes = "Inspect frozen validated runtime history" },
            },
        } },
    });
    try std.testing.expectEqual(.observed, reply.disposition);
    var parsed = try native.json.parse(a, reply.observation_json.bytes, .{});
    defer parsed.deinit();
    return native.values.fromJson(wc.RetainedLocator, a, parsed.value.object.get("retained").?);
}

pub fn run(comptime Types: type, f: anytype, locator: wc.RetainedLocator) !void {
    const original = f.service.*.profile;
    var profile = original;
    profile.bytes = "reuse-semantic-reader";
    profile.semantic_construction = null;
    @import("workspace_reuse_test.zig").configure(&profile);
    const grants = try f.scratch.dupe(native.registry.Grant, profile.authority.grants);
    profile.authority.grants = grants;
    for (grants) |*grant| grant.resource_identity = try profile.resourceIdentity(
        f.scratch,
        f.application.*.image_identity,
    );
    try replaceService(Types, f, profile);
    defer support.expectCleanup(replaceService(Types, f, original));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(f.io, &path_buffer);
    const requests = [_]wc.Command{
        .{ .program = .{ .find = .{
            .scope = locator.scope,
            .query = .{ .bytes = "semantic history" },
        } } },
        .{ .program = .{ .inspect = .{ .target = .{ .retained = locator }, .page = .{} } } },
    };
    for (requests, 0..) |request, index| {
        const id = try std.fmt.allocPrint(f.scratch, "semantic-reader-{d}", .{index});
        const task = (try f.service.*.submit(f.scratch, id, request)).receipt.task;
        try incompatibleImport(f, task, locator);
        try finishRead(f, task, request.program == .find);
        const path = try std.fmt.allocPrint(f.scratch, "{s}/{d}.tar", .{
            path_buffer[0..length], index,
        });
        try roundTrip(Types, f, task, path, index);
    }
}

fn incompatibleImport(f: anytype, task: Task, locator: wc.RetainedLocator) !void {
    const generation = f.namespace.*.store.head.generation;
    const reply = try f.service.*.workspaceCommand(f.scratch, "semantic-reader-import", task, .{
        .program = .{ .import = .{ .locator = locator } },
    });
    try std.testing.expectEqual(.rejected, reply.disposition);
    try std.testing.expect(reply.program == null);
    var parsed = try native.json.parse(f.scratch, reply.observation_json.bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "IncompatibleProfile",
        parsed.value.object.get("error").?.string,
    );
    try std.testing.expectEqual(generation, f.namespace.*.store.head.generation);
}

fn finishRead(f: anytype, task: Task, find: bool) !void {
    for (0..128) |_| {
        try std.testing.expect(try f.service.*.pump(f.scratch) != .work);
        var parent = try f.service.*.task(f.scratch, task);
        defer parent.deinit();
        if (!parent.value.terminal()) continue;
        try std.testing.expectEqual(.completed, parent.value.outcome_kind);
        const bytes = try f.namespace.*.store.object(f.scratch, parent.value.result.?, null);
        defer f.scratch.free(bytes);
        var reply = try contracts.decodeOwned(wc.Reply, f.scratch, bytes);
        defer reply.deinit();
        try std.testing.expectEqual(.observed, reply.value.disposition);
        var parsed = try native.json.parse(f.scratch, reply.value.observation_json.bytes, .{});
        defer parsed.deinit();
        if (find) {
            try std.testing.expectEqual(
                @as(usize, 1),
                parsed.value.object.get("records").?.array.items.len,
            );
        } else try std.testing.expect(parsed.value.object.contains("source"));
        return;
    }
    return error.SemanticReaderNotSettled;
}

fn roundTrip(comptime Types: type, f: anytype, task: Task, path: []const u8, index: usize) !void {
    try std.testing.expect(f.service.*.profile.semantic_construction == null);
    try f.service.*.validateWorkspace(f.scratch, task);
    _ = try f.service.*.exportCheckpoint(f.scratch, task, path);
    try f.service.*.discardTask(f.scratch, task);
    const profile = f.service.*.profile;
    const directory: std.Io.Dir = .{ .handle = f.namespace.*.directory };
    var original_path: [4096]u8 = undefined;
    const length = try directory.realPath(f.io, &original_path);
    try f.service.*.close(f.a);
    try f.namespace.*.close();
    defer support.expectCleanup(reopenNamespace(Types, f, original_path[0..length], profile));
    const destination = try std.fmt.allocPrint(f.scratch, "{s}.restored", .{path});
    var namespace = try native.Namespace.open(f.a, f.io, destination);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(Types).init(
        f.a,
        f.io,
        &namespace,
        f.assets,
        &f.application.*,
        f.handlers.*,
        profile,
    );
    defer support.expectCleanup(service.close(f.a));
    const operation = try std.fmt.allocPrint(f.scratch, "restore-semantic-reader-{d}", .{index});
    const restored = try service.importCheckpoint(f.scratch, operation, path);
    try std.testing.expectEqualDeep(task, restored.receipt.task);
    try service.validateWorkspace(f.scratch, task);
}

fn reopenNamespace(
    comptime Types: type,
    f: anytype,
    path: []const u8,
    profile: native.tasks.Profile,
) !void {
    f.namespace.* = try native.Namespace.open(f.a, f.io, path);
    f.service.* = try native.tasks.Service(Types).init(
        f.a,
        f.io,
        &f.namespace.*,
        f.assets,
        &f.application.*,
        f.handlers.*,
        profile,
    );
}

fn replaceService(comptime Types: type, f: anytype, profile: native.tasks.Profile) !void {
    try f.service.*.close(f.a);
    f.service.* = try native.tasks.Service(Types).init(
        f.a,
        f.io,
        &f.namespace.*,
        f.assets,
        &f.application.*,
        f.handlers.*,
        profile,
    );
}
