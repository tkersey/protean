const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const support = @import("workspace_test_support.zig");
const wc = contracts.workspace;
const Task = native.testing.state.TaskId;

pub fn run(comptime Types: type, h: anytype, locator: wc.RetainedLocator) !void {
    var failed = false;
    for ([_]bool{ false, true }) |operation_alias| {
        variant(Types, h, locator, operation_alias) catch |err| {
            std.debug.print("retain snapshot operation_alias={any}: {s}\n", .{
                operation_alias, @errorName(err),
            });
            failed = true;
        };
    }
    if (failed) return error.RetainSnapshotFailed;
}

const Mutation = struct {
    bytes: []u8,
    calls: u32 = 0,

    fn disclose(
        context: ?*anyopaque,
        _: native.registry.Authority,
        _: native.reuse_policy.Scope,
        _: native.reuse_policy.Frozen,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        @memset(self.bytes, 'x');
        self.calls += 1;
    }
};

fn variant(comptime Types: type, h: anytype, locator: wc.RetainedLocator, alias: bool) !void {
    const operation = if (alias) "snapshot-operation" else "snapshot-request";
    const submit = try std.fmt.allocPrint(h.scratch, "{s}-task", .{operation});
    const task = (try h.service.submit(h.scratch, submit, {})).receipt.task;
    defer support.expectCleanup(discard(h, task));
    const imported = try h.service.workspaceCommand(h.scratch, "snapshot-input", task, .{
        .program = .{ .import = .{ .locator = locator } },
    });
    try std.testing.expectEqual(.observed, imported.disposition);
    const original: wc.Retain = .{
        .program = imported.program orelse return error.ExpectedProgram,
        .scope = locator.scope,
        .description = .{
            .name = .{ .bytes = "snapshot name" },
            .purpose = .{ .bytes = "Preserve the invocation before disclosure callbacks" },
        },
    };
    const buffer = try h.scratch.dupe(
        u8,
        if (alias) operation else original.description.name.bytes,
    );
    defer h.scratch.free(buffer);
    var mutable = original;
    if (!alias) mutable.description.name.bytes = buffer;
    const observed = try mutate(h, task, if (alias) buffer else operation, mutable, buffer);
    try std.testing.expectEqual(@as(u8, 'x'), buffer[0]);
    try std.testing.expectEqual(.observed, observed.disposition);
    const receipt = try receiptDigest(h, task, operation);
    const generation = h.namespace.store.head.generation;
    const replayed = try h.service.workspaceCommand(h.scratch, operation, task, .{
        .program = .{ .retain = original },
    });
    try std.testing.expectEqual(.observed, replayed.disposition);
    try std.testing.expectEqual(generation, h.namespace.store.head.generation);
    try std.testing.expectEqualDeep(receipt, try receiptDigest(h, task, operation));
    try expectLocator(h, observed, replayed, original);
    try h.service.validateWorkspace(h.scratch, task);
    try exportRestore(Types, h, task, operation);
}

fn mutate(
    h: anytype,
    task: Task,
    operation: []const u8,
    request: wc.Retain,
    buffer: []u8,
) !wc.Reply {
    const policy = h.service.profile.reuse;
    defer h.service.profile.reuse = policy;
    var mutation: Mutation = .{ .bytes = buffer };
    h.service.profile.reuse.context = &mutation;
    h.service.profile.reuse.disclosure = Mutation.disclose;
    const reply = try h.service.workspaceCommand(h.scratch, operation, task, .{
        .program = .{ .retain = request },
    });
    try std.testing.expectEqual(@as(u32, 2), mutation.calls);
    return reply;
}

fn receiptDigest(h: anytype, task: Task, operation: []const u8) ![32]u8 {
    var rows = try h.namespace.store.database.prepare(
        "SELECT p.receipt,o.body FROM operations p JOIN objects o ON o.digest=p.receipt " ++
            "WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    var result: ?[32]u8 = null;
    while (try rows.step() == .row) {
        var receipt = try contracts.decodeOwned(
            native.testing.state.Receipt,
            h.scratch,
            try rows.bytes(1),
        );
        defer receipt.deinit();
        if (receipt.value.workspace_kind != .retained) continue;
        try std.testing.expect(result == null);
        try std.testing.expectEqualStrings(operation, receipt.value.client_operation_id.bytes);
        const digest = try rows.bytes(0);
        try std.testing.expectEqual(@as(usize, 32), digest.len);
        result = digest[0..32].*;
    }
    return result orelse error.ExpectedRetainReceipt;
}

fn expectLocator(h: anytype, first: wc.Reply, second: wc.Reply, request: wc.Retain) !void {
    var parsed_first = try native.json.parse(h.scratch, first.observation_json.bytes, .{});
    defer parsed_first.deinit();
    var parsed_second = try native.json.parse(h.scratch, second.observation_json.bytes, .{});
    defer parsed_second.deinit();
    try std.testing.expect(parsed_second.value.object.get("replayed").?.bool);
    const locator = try native.values.fromJson(
        wc.RetainedLocator,
        h.scratch,
        parsed_first.value.object.get("retained").?,
    );
    const replayed = try native.values.fromJson(
        wc.RetainedLocator,
        h.scratch,
        parsed_second.value.object.get("retained").?,
    );
    try std.testing.expectEqualStrings(locator.id.bytes, replayed.id.bytes);
    try std.testing.expectEqualStrings(request.scope.bytes, locator.scope.bytes);
    var id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id, locator.id.bytes);
    const bytes = try h.namespace.store.definitionBytes(h.scratch, locator.scope.bytes, id) orelse
        return error.ExpectedDefinition;
    defer h.scratch.free(bytes);
    var definition = try contracts.decodeOwned(native.testing.reuse.Definition, h.scratch, bytes);
    defer definition.deinit();
    try std.testing.expectEqualStrings(
        request.description.name.bytes,
        definition.value.description.name.bytes,
    );
    try std.testing.expectEqualStrings(
        request.description.purpose.bytes,
        definition.value.description.purpose.bytes,
    );
}

fn exportRestore(comptime Types: type, h: anytype, task: Task, operation: []const u8) !void {
    const path = try std.fmt.allocPrint(h.scratch, "{s}/{s}.tar", .{
        h.path_buffer[0..h.length], operation,
    });
    _ = try h.service.exportCheckpoint(h.scratch, task, path);
    try h.service.park(h.scratch);
    try h.service.close(h.scratch);
    h.service_open = false;
    try h.namespace.close();
    h.namespace_open = false;
    try inspectCopy(Types, h, task, path, operation);
    h.namespace = try native.Namespace.open(h.a, h.io, h.path);
    h.namespace_open = true;
    h.service = try native.tasks.Service(Types).init(
        h.a,
        h.io,
        &h.namespace,
        h.assets,
        &h.application,
        h.handlers,
        h.profile,
    );
    h.service_open = true;
}

fn inspectCopy(
    comptime Types: type,
    h: anytype,
    task: Task,
    path: []const u8,
    name: []const u8,
) !void {
    const target = try std.fmt.allocPrint(h.scratch, "{s}/{s}-restored", .{
        h.path_buffer[0..h.length], name,
    });
    var namespace = try native.Namespace.open(h.a, h.io, target);
    defer support.expectCleanup(namespace.close());
    var profile = h.profile;
    profile.reuse = .{};
    var service = try native.tasks.Service(Types).init(
        h.a,
        h.io,
        &namespace,
        h.assets,
        &h.application,
        h.handlers,
        profile,
    );
    defer support.expectCleanup(service.close(h.a));
    const restored = try service.importCheckpoint(h.scratch, "restore-snapshot", path);
    try std.testing.expectEqualDeep(task, restored.receipt.task);
    try service.validateWorkspace(h.scratch, task);
}

fn discard(h: anytype, task: Task) !void {
    _ = try h.service.requestCancel(
        h.scratch,
        "snapshot-cancel",
        task,
        "Snapshot witness finished",
    );
    for (0..128) |_| {
        var parent = try h.service.task(h.scratch, task);
        defer parent.deinit();
        if (try h.service.taskCleanupComplete(h.scratch, parent.value)) {
            try h.service.discardTask(h.scratch, task);
            return;
        }
        try std.testing.expect(try h.service.pump(h.scratch) != .work);
    }
    return error.SnapshotCleanupNotSettled;
}
