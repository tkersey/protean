const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = @import("horos").source;
const support = @import("workspace_test_support.zig");
const wc = contracts.workspace;
const Task = native.testing.state.TaskId;

pub fn configure(profile: *native.tasks.Profile) void {
    profile.reuse = .{ .scopes = &.{.{
        .name = "methods",
        .principal = "test",
        .tenant = "test",
        .read = true,
        .retain = true,
        .import = true,
        .disclose_all = true,
    }} };
}

pub fn run(comptime Types: type, h: anytype) !void {
    const a = h.scratch;
    const task_a = (try h.service.submit(a, "reuse-source", {})).receipt.task;
    const program_a = try build(h, task_a, "reuse-build", 7);
    const work_a = try start(h, task_a, program_a, "reuse-source-start", 3);
    try waitForQuestion(h, task_a, work_a, "source-progress");
    try answer(h, task_a, work_a, "source-answer", 2);
    try expectResult(h, task_a, work_a, "source-result", 12);
    try deniedRetain(h, task_a, program_a);
    try interruptedRetain(h, task_a, program_a);
    const retained = try command(h, task_a, "retain-original", .{ .program = .{ .retain = .{
        .program = program_a,
        .scope = .{ .bytes = "methods" },
        .description = .{ .name = .{ .bytes = "adjust" }, .purpose = .{
            .bytes = "Add the immutable helper increment and a current typed adjustment.",
        } },
    } } });
    const locator = try retainedLocator(a, retained);
    try settle(h, task_a, "settle-source");
    try h.service.discardTask(a, task_a);
    try expectAbsent(h, task_a);
    try reopen(Types, h);
    try expectAbsent(h, task_a);
    const task_b = (try h.service.submit(a, "reuse-destination", {})).receipt.task;
    try discover(h, task_b, locator);
    try deniedAccess(h, task_b, locator);
    const imported = try lostImportReply(Types, h, task_b, locator);
    const program_b = imported.program orelse return error.ExpectedProgram;
    try expectImport(h, task_a, task_b, program_a, program_b, locator);
    try revokedReplay(h, task_b, locator);
    const replayed = try command(h, task_b, "import-original", .{ .program = .{ .import = .{
        .locator = locator,
    } } });
    try std.testing.expectEqualStrings(program_b.id.bytes, replayed.program.?.id.bytes);
    const work_b = try start(h, task_b, program_b, "destination-start", 20);
    try waitForQuestion(h, task_b, work_b, "destination-progress");
    try reopen(Types, h);
    try expectAbsent(h, task_a);
    try revise(h, task_b, locator);
    try answer(h, task_b, work_b, "destination-answer", 5);
    try expectResult(h, task_b, work_b, "destination-result", 32);
    var finished = try h.service.workspaceWork(a, task_b, work_b);
    defer finished.deinit();
    try std.testing.expectEqualDeep(try support.nativeIdentity(program_b), finished.value.program);
    try settle(h, task_b, "settle-destination");
    try h.service.discardTask(a, task_b);
    try reopen(Types, h);
    try expectAbsent(h, task_b);
}

fn lostImportReply(
    comptime Types: type,
    h: anytype,
    task: Task,
    locator: wc.RetainedLocator,
) !wc.Reply {
    var failed_reply: support.AfterCommitAllocator = .{
        .backing = h.scratch,
        .namespace = &h.namespace,
        .generation = h.namespace.store.head.generation,
    };
    const request: wc.Command = .{ .program = .{ .import = .{ .locator = locator } } };
    try std.testing.expectError(error.OutOfMemory, h.service.workspaceCommand(
        failed_reply.allocator(),
        "import-original",
        task,
        request,
    ));
    try std.testing.expect(failed_reply.rejected != 0);
    try reopen(Types, h);
    const generation = h.namespace.store.head.generation;
    const reply = try command(h, task, "import-original", request);
    try std.testing.expectEqual(generation, h.namespace.store.head.generation);
    return reply;
}

fn deniedAccess(h: anytype, task: Task, locator: wc.RetainedLocator) !void {
    const original = h.service.profile.reuse;
    defer h.service.profile.reuse = original;
    h.service.profile.reuse = .{};
    const commands = [_]wc.Command{
        .{ .program = .{ .find = .{
            .scope = locator.scope,
            .query = .{ .bytes = "adjust" },
        } } },
        .{ .program = .{ .inspect = .{
            .target = .{ .retained = locator },
            .page = .{},
        } } },
        .{ .program = .{ .import = .{ .locator = locator } } },
    };
    const generation = h.namespace.store.head.generation;
    for (commands, 0..) |value, index| {
        const reply = try h.service.workspaceCommand(
            h.scratch,
            try std.fmt.allocPrint(h.scratch, "denied-{d}", .{index}),
            task,
            value,
        );
        try std.testing.expectEqual(.rejected, reply.disposition);
        try std.testing.expect(std.mem.indexOf(u8, reply.observation_json.bytes, "adjust") == null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            reply.observation_json.bytes,
            locator.id.bytes,
        ) == null);
    }
    try std.testing.expectEqual(generation, h.namespace.store.head.generation);
}

fn deniedRetain(h: anytype, task: Task, program: wc.Ref) !void {
    const original = h.service.profile.reuse;
    defer h.service.profile.reuse = original;
    var scopes = [_]@TypeOf(original.scopes[0]){original.scopes[0]};
    scopes[0].disclose_all = false;
    h.service.profile.reuse.scopes = &scopes;
    const generation = h.namespace.store.head.generation;
    const reply = try h.service.workspaceCommand(h.scratch, "denied-retain", task, .{
        .program = .{ .retain = .{
            .program = program,
            .scope = .{ .bytes = "methods" },
            .description = .{
                .name = .{ .bytes = "private description" },
                .purpose = .{ .bytes = "private source and evidence" },
            },
        } },
    });
    try std.testing.expectEqual(.rejected, reply.disposition);
    try std.testing.expectEqual(generation, h.namespace.store.head.generation);
    var rows = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM reuse_definitions",
        &.{},
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
}

const PublicationInterruption = struct {
    revoked: *bool,
    exhaust: bool,
    calls: u32 = 0,

    fn disclose(
        context: ?*anyopaque,
        _: native.registry.Authority,
        _: native.reuse_policy.Scope,
        frozen: native.reuse_policy.Frozen,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try std.testing.expect(frozen.artifacts.len != 0);
        try std.testing.expect(frozen.history.len != 0);
        try std.testing.expect(frozen.description.len != 0);
        self.calls += 1;
        if (self.calls != 2) return;
        if (self.exhaust) return error.OutOfMemory;
        self.revoked.* = true;
    }
};

fn interruptedRetain(h: anytype, task: Task, program: wc.Ref) !void {
    const original = h.service.profile.reuse;
    const authority = h.service.profile.authority;
    defer h.service.profile.reuse = original;
    defer h.service.profile.authority = authority;
    const generation = h.namespace.store.head.generation;
    for ([_]bool{ false, true }, 0..) |exhaust, index| {
        h.service.profile.authority = authority;
        var interruption: PublicationInterruption = .{
            .revoked = &h.service.profile.authority.revoked,
            .exhaust = exhaust,
        };
        h.service.profile.reuse.context = &interruption;
        h.service.profile.reuse.disclosure = PublicationInterruption.disclose;
        const result = h.service.workspaceCommand(
            h.scratch,
            try std.fmt.allocPrint(h.scratch, "interrupted-retain-{d}", .{index}),
            task,
            .{ .program = .{ .retain = .{
                .program = program,
                .scope = .{ .bytes = "methods" },
                .description = .{
                    .name = .{ .bytes = "unpublished" },
                    .purpose = .{ .bytes = "Interrupted before publication" },
                },
            } } },
        );
        if (exhaust) {
            try std.testing.expectError(error.OutOfMemory, result);
        } else {
            try std.testing.expectEqual(.rejected, (try result).disposition);
        }
        try std.testing.expectEqual(@as(u32, 2), interruption.calls);
        try std.testing.expectEqual(generation, h.namespace.store.head.generation);
        var rows = try h.namespace.store.database.prepare(
            "SELECT count(*) FROM reuse_definitions",
            &.{},
        );
        defer rows.deinit();
        try std.testing.expectEqual(.row, try rows.step());
        try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
    }
}

fn revokedReplay(h: anytype, task: Task, locator: wc.RetainedLocator) !void {
    const original = h.service.profile.reuse;
    defer h.service.profile.reuse = original;
    h.service.profile.reuse = .{};
    const generation = h.namespace.store.head.generation;
    const reply = try h.service.workspaceCommand(h.scratch, "import-original", task, .{
        .program = .{ .import = .{ .locator = locator } },
    });
    try std.testing.expectEqual(.rejected, reply.disposition);
    try std.testing.expect(reply.program == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        reply.observation_json.bytes,
        locator.id.bytes,
    ) == null);
    try std.testing.expectEqual(generation, h.namespace.store.head.generation);
}

fn command(h: anytype, task: Task, id: []const u8, value: wc.Command) !wc.Reply {
    const reply = try h.service.workspaceCommand(h.scratch, id, task, value);
    if (reply.disposition != .observed) {
        std.debug.print("reuse operation {s}: {s}\n", .{ id, reply.observation_json.bytes });
        return error.ReuseOperationRejected;
    }
    return reply;
}

fn build(h: anytype, task: Task, id: []const u8, increment: u64) !wc.Ref {
    var builder = source.Builder.init(h.a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").reusableQuestion(&builder, increment);
    const document = try native.source_records.encode(h.scratch, module);
    const reply = try command(h, task, id, .{ .program = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = document } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{.{ .effect = 0, .class = .input }} },
    } } });
    return reply.program orelse error.ExpectedProgram;
}

fn start(h: anytype, task: Task, program: wc.Ref, id: []const u8, input: u64) ![32]u8 {
    const encoded = try contracts.encodeOwned(u64, h.scratch, input);
    return (try h.service.workspaceStart(
        h.scratch,
        id,
        task,
        try support.nativeIdentity(program),
        encoded,
        .{},
    )).receipt.workspace.?;
}

fn waitForQuestion(h: anytype, task: Task, id: [32]u8, prefix: []const u8) !void {
    for (0..32) |turn| {
        var work = try h.service.workspaceWork(h.scratch, task, id);
        defer work.deinit();
        if (work.value.current_port != null) {
            try std.testing.expect(!work.value.terminal());
            return;
        }
        try std.testing.expect(!work.value.terminal());
        _ = try h.service.workspaceControl(
            h.scratch,
            try std.fmt.allocPrint(h.scratch, "{s}-{d}", .{ prefix, turn }),
            task,
            id,
            work.value.execution_revision,
            work.value.control_revision,
            .advance,
        );
    }
    return error.QuestionNotReached;
}

fn answer(h: anytype, task: Task, id: [32]u8, operation: []const u8, response: u64) !void {
    const a = h.scratch;
    var work = try h.service.workspaceWork(a, task, id);
    defer work.deinit();
    const bytes = try h.namespace.store.object(a, work.value.current_port.?, null);
    var port = try contracts.decodeOwned(native.workspace.Port, a, bytes);
    defer port.deinit();
    _ = try h.service.workspaceInteract(a, operation, task, .{
        .expected = .{
            .work = try support.workspaceRef(a, .work, id),
            .execution_revision = work.value.execution_revision,
            .control_revision = work.value.control_revision,
        },
        .port = try support.workspaceRef(a, .port, port.value.id),
        .generation = port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{
            .schema = try support.workspaceRef(a, .schema, port.value.interface.argument.digest),
            .json_text = .{ .bytes = try native.json.canonical(
                a,
                try native.values.toJson(u64, a, response),
            ) },
        } } },
    });
}

fn expectResult(h: anytype, task: Task, id: [32]u8, prefix: []const u8, expected: u64) !void {
    for (0..32) |turn| {
        var work = try h.service.workspaceWork(h.scratch, task, id);
        defer work.deinit();
        if (work.value.terminal()) {
            try std.testing.expectEqual(.completed, work.value.outcome_kind);
            const bytes = try h.namespace.store.object(h.scratch, work.value.result.?, null);
            var result = try contracts.decodeOwned(u64, h.scratch, bytes);
            defer result.deinit();
            try std.testing.expectEqual(expected, result.value);
            return;
        }
        _ = try h.service.workspaceControl(
            h.scratch,
            try std.fmt.allocPrint(h.scratch, "{s}-{d}", .{ prefix, turn }),
            task,
            id,
            work.value.execution_revision,
            work.value.control_revision,
            .advance,
        );
    }
    return error.ResultNotReached;
}

fn retainedLocator(a: std.mem.Allocator, reply: wc.Reply) !wc.RetainedLocator {
    const observed = try native.json.parse(a, reply.observation_json.bytes, .{});
    return native.values.fromJson(wc.RetainedLocator, a, observed.value.object.get("retained").?);
}

fn discover(h: anytype, task: Task, locator: wc.RetainedLocator) !void {
    const reply = try command(h, task, "find-original", .{ .program = .{ .find = .{
        .scope = locator.scope,
        .query = .{ .bytes = "adjust" },
    } } });
    const parsed = try native.json.parse(h.scratch, reply.observation_json.bytes, .{});
    const records = parsed.value.object.get("records").?.array.items;
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    const found = try native.values.fromJson(
        wc.RetainedLocator,
        h.scratch,
        records[0].object.get("locator").?,
    );
    try std.testing.expectEqualStrings(locator.id.bytes, found.id.bytes);
    const inspected = try command(h, task, "inspect-original", .{ .program = .{ .inspect = .{
        .target = .{ .retained = locator },
        .page = .{ .offset = 0, .maximum = 4096 },
    } } });
    try std.testing.expect(std.mem.indexOf(u8, inspected.observation_json.bytes, "source") != null);
}

fn expectImport(
    h: anytype,
    old: Task,
    task: Task,
    original: wc.Ref,
    imported: wc.Ref,
    locator: wc.RetainedLocator,
) !void {
    try std.testing.expect(!std.meta.eql(old, task));
    try std.testing.expectEqualStrings(original.id.bytes, imported.id.bytes);
    var saved = try h.service.workspaceProgram(
        h.scratch,
        task,
        try support.nativeIdentity(imported),
    );
    defer saved.deinit();
    try std.testing.expectEqualDeep(task, saved.value.task);
    var rows = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM records WHERE task=? AND kind='workspace_work'",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
    try std.testing.expect(locator.id.bytes.len == 64);
}

fn revise(h: anytype, task: Task, original: wc.RetainedLocator) !void {
    const program = try build(h, task, "build-revision", 100);
    const reply = try command(h, task, "retain-revision", .{ .program = .{ .retain = .{
        .program = program,
        .scope = original.scope,
        .description = .{
            .name = .{ .bytes = "adjust" },
            .purpose = .{ .bytes = "New increment" },
        },
    } } });
    const revision = try retainedLocator(h.scratch, reply);
    try std.testing.expect(!std.mem.eql(u8, revision.id.bytes, original.id.bytes));
    const generation = h.namespace.store.head.generation;
    const conflict = try h.service.workspaceCommand(h.scratch, "import-original", task, .{
        .program = .{ .import = .{ .locator = revision } },
    });
    try std.testing.expectEqual(.rejected, conflict.disposition);
    try std.testing.expectEqual(generation, h.namespace.store.head.generation);
}

fn settle(h: anytype, task: Task, id: []const u8) !void {
    _ = try h.service.requestCancel(h.scratch, id, task, "Disposable reuse witness finished");
    for (0..128) |_| {
        var current = try h.service.task(h.scratch, task);
        defer current.deinit();
        if (try h.service.taskCleanupComplete(h.scratch, current.value)) return;
        const step = try h.service.pump(h.scratch);
        try std.testing.expect(step != .work);
    }
    return error.CleanupNotSettled;
}

fn expectAbsent(h: anytype, task: Task) !void {
    var rows = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM tasks WHERE id=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
    inline for (.{ "records", "events", "operations" }) |table| {
        var indexed = try h.namespace.store.database.prepare(
            "SELECT count(*) FROM " ++ table ++ " WHERE task=?",
            &.{.{ .blob = &task }},
        );
        defer indexed.deinit();
        try std.testing.expectEqual(.row, try indexed.step());
        try std.testing.expectEqual(@as(i64, 0), try indexed.integer(0));
    }
}

fn reopen(comptime Types: type, h: anytype) !void {
    try h.service.park(h.scratch);
    try h.service.close(h.scratch);
    h.service_open = false;
    try h.namespace.close();
    h.namespace_open = false;
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
