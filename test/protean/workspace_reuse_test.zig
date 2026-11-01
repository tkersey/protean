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
    try invalidRetain(h, task_a, program_a);
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
    try auditCatalog(Types, h);
    try foreignOwners(Types, h, locator);
    const task_b = (try h.service.submit(a, "reuse-destination", {})).receipt.task;
    try discover(h, task_b, locator);
    try authoredDiscovery(h, task_b, locator);
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
    const revision = try revise(h, task_b, locator);
    try answer(h, task_b, work_b, "destination-answer", 5);
    try expectResult(h, task_b, work_b, "destination-result", 32);
    var finished = try h.service.workspaceWork(a, task_b, work_b);
    defer finished.deinit();
    try std.testing.expectEqualDeep(try support.nativeIdentity(program_b), finished.value.program);
    try validateAndExport(h, task_b);
    try settle(h, task_b, "settle-destination");
    try h.service.discardTask(a, task_b);
    try reopen(Types, h);
    try expectAbsent(h, task_b);
    try auditCatalog(Types, h);
    try restoreRevision(Types, h, revision);
}

fn auditCatalog(comptime Types: type, h: anytype) !void {
    const store = &h.namespace.store;
    const task_only = try store.auditTaskRetention(h.handlers, h.application.image_identity);
    try std.testing.expectEqual(@as(u64, 0), task_only.objects);
    const full = try store.auditRetention(h.handlers, h.application.image_identity);
    try std.testing.expect(full.objects > 0 and full.edges > 0);
    {
        try store.begin();
        defer store.rollback();
        store.invalidateIntegrity();
        try store.database.exec(
            "DELETE FROM dependencies WHERE parent=" ++
                "(SELECT body FROM reuse_definitions ORDER BY body LIMIT 1)",
        );
        const unaffected = try native.testing.retention.verifyTasks(store, h.handlers);
        try std.testing.expectEqual(@as(u64, 0), unaffected.objects);
        try std.testing.expectError(
            error.CorruptState,
            native.testing.retention.verify(store, h.handlers),
        );
        try std.testing.expect(!store.fenced);
    }
    try duplicateCatalogRecord(h);
    try reopen(Types, h);
}

fn duplicateCatalogRecord(h: anytype) !void {
    const store = &h.namespace.store;
    var definition = definition: {
        var rows = try store.database.prepare(
            "SELECT o.body FROM reuse_definitions d JOIN objects o ON o.digest=d.body " ++
                "ORDER BY d.body LIMIT 1",
            &.{},
        );
        defer rows.deinit();
        try std.testing.expectEqual(.row, try rows.step());
        break :definition try contracts.decodeOwned(
            native.testing.reuse.Definition,
            h.scratch,
            try rows.bytes(0),
        );
    };
    defer definition.deinit();
    const original = definition.value.origin.records.items;
    try std.testing.expect(original.len > 0);
    const records = try h.scratch.alloc(native.testing.state.ArchiveRecord, original.len + 1);
    defer h.scratch.free(records);
    @memcpy(records[0..original.len], original);
    records[original.len] = original[0];
    var malformed = definition.value;
    malformed.origin.records.items = records;
    const prepared = try store.prepareDefinition(h.scratch, malformed);
    defer h.scratch.free(prepared.bytes);
    defer h.scratch.free(prepared.children);
    try store.begin();
    defer store.rollback();
    store.invalidateIntegrity();
    _ = try store.retainDefinition(prepared);
    try std.testing.expectError(
        error.CorruptState,
        native.testing.retention.verify(store, h.handlers),
    );
    try std.testing.expect(!store.fenced);
}

fn authoredDiscovery(h: anytype, task: Task, locator: wc.RetainedLocator) !void {
    _ = try h.service.message(h.scratch, "authored-discovery", task, .{ .program = .{ .find = .{
        .scope = locator.scope,
        .query = .{ .bytes = "adjust" },
    } } });
    for (0..128) |_| {
        const step = try h.service.pump(h.scratch);
        try std.testing.expect(step != .work);
        var rows = try h.namespace.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
                "WHERE r.kind='workspace_reply' AND r.task=?",
            &.{.{ .blob = &task }},
        );
        defer rows.deinit();
        if (try rows.step() != .row) continue;
        var saved = try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            h.scratch,
            try rows.bytes(0),
        );
        defer saved.deinit();
        try std.testing.expect(saved.value.evidence == .read);
        try std.testing.expect(saved.value.evidence.read == .reuse);
        const selected = saved.value.evidence.read.reuse.selection;
        try std.testing.expect(selected == .find);
        try std.testing.expectEqual(@as(usize, 1), selected.find.definitions.items.len);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, locator.id.bytes);
        try std.testing.expectEqualDeep(expected, selected.find.definitions.items[0].digest);
        return;
    }
    return error.ExpectedAuthoredDiscovery;
}

fn validateAndExport(h: anytype, task: Task) !void {
    try h.service.validateWorkspace(h.scratch, task);
    const path = try std.fmt.allocPrint(
        h.scratch,
        "{s}/reuse.tar",
        .{h.path_buffer[0..h.length]},
    );
    _ = try h.service.exportCheckpoint(h.scratch, task, path);
    var tables = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM sqlite_temp_master WHERE type='table' AND " ++
            "name IN ('tasks','records','events','operations')",
        &.{},
    );
    defer tables.deinit();
    try std.testing.expectEqual(.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 0), try tables.integer(0));
}

fn restoreRevision(comptime Types: type, h: anytype, locator: wc.RetainedLocator) !void {
    var phase: []const u8 = "import nested definition";
    errdefer std.debug.print("reuse restoration: {s}\n", .{phase});
    const task = (try h.service.submit(h.scratch, "reuse-third-task", {})).receipt.task;
    const imported = try command(h, task, "import-nested", .{ .program = .{ .import = .{
        .locator = locator,
    } } });
    const program = imported.program orelse return error.ExpectedProgram;
    const path = try std.fmt.allocPrint(
        h.scratch,
        "{s}/nested-reuse.tar",
        .{h.path_buffer[0..h.length]},
    );
    phase = "export destination";
    _ = try h.service.exportCheckpoint(h.scratch, task, path);
    phase = "restore destination";
    try inspectRestored(Types, h, path, task);
    phase = "execute nested definition";
    const work = try start(h, task, program, "nested-start", 4);
    try waitForQuestion(h, task, work, "nested-progress");
    try answer(h, task, work, "nested-answer", 6);
    try expectResult(h, task, work, "nested-result", 110);
    try settle(h, task, "settle-third-task");
    try h.service.discardTask(h.scratch, task);
}

fn inspectRestored(comptime Types: type, h: anytype, path: []const u8, task: Task) !void {
    try closeFixture(h);
    try inspectCopy(Types, h, path, task);
    try openFixture(Types, h);
}

fn inspectCopy(comptime Types: type, h: anytype, path: []const u8, task: Task) !void {
    const target = try std.fmt.allocPrint(
        h.scratch,
        "{s}/nested-restored",
        .{h.path_buffer[0..h.length]},
    );
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
    const restored = try service.importCheckpoint(h.scratch, "restore-nested", path);
    try std.testing.expectEqualDeep(task, restored.receipt.task);
    try service.validateWorkspace(h.scratch, task);
    try std.testing.expectEqual(.idle, try service.pump(h.scratch));
    var rows = try namespace.store.database.prepare("SELECT count(*) FROM reuse_definitions", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
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

fn foreignOwners(comptime Types: type, h: anytype, locator: wc.RetainedLocator) !void {
    const original_profile = h.profile;
    const original_grants = h.grants;
    defer {
        h.profile = original_profile;
        h.grants = original_grants;
    }
    for (0..2) |axis| {
        h.profile = original_profile;
        h.grants = original_grants;
        if (axis == 0) {
            h.profile.authority.principal = "foreign";
        } else {
            h.profile.authority.tenant = "foreign";
        }
        const scopes = try h.scratch.dupe(
            @TypeOf(h.profile.reuse.scopes[0]),
            h.profile.reuse.scopes,
        );
        for (scopes) |*scope| {
            scope.principal = h.profile.authority.principal;
            scope.tenant = h.profile.authority.tenant;
        }
        h.profile.reuse.scopes = scopes;
        for (&h.grants) |*grant| grant.resource_identity = try h.profile.resourceIdentity(
            h.scratch,
            h.application.image_identity,
        );
        try reopen(Types, h);
        const task = (try h.service.submit(h.scratch, "foreign-owner", {})).receipt.task;
        try foreignAccess(h, task, locator);
        try settle(h, task, "settle-foreign");
        try h.service.discardTask(h.scratch, task);
    }
    h.profile = original_profile;
    h.grants = original_grants;
    try reopen(Types, h);
}

fn foreignAccess(h: anytype, task: Task, locator: wc.RetainedLocator) !void {
    const found = try command(h, task, "foreign-find", .{ .program = .{ .find = .{
        .scope = locator.scope,
        .query = .{ .bytes = "adjust" },
    } } });
    var result = try native.json.parse(h.scratch, found.observation_json.bytes, .{});
    defer result.deinit();
    const records = result.value.object.get("records").?.array.items;
    try std.testing.expectEqual(@as(usize, 0), records.len);
    try std.testing.expectEqualStrings("0", result.value.object.get("scanned").?.number_string);
    const missing_id: [64]u8 = @splat('0');
    const missing: wc.RetainedLocator = .{
        .scope = locator.scope,
        .id = .{ .bytes = &missing_id },
    };
    const requests = [_]wc.Command{
        .{ .program = .{ .inspect = .{ .target = .{ .retained = locator }, .page = .{} } } },
        .{ .program = .{ .inspect = .{ .target = .{ .retained = missing }, .page = .{} } } },
        .{ .program = .{ .import = .{ .locator = locator } } },
        .{ .program = .{ .import = .{ .locator = missing } } },
    };
    var observed: [requests.len]wc.Reply = undefined;
    for (requests, &observed, 0..) |request, *reply, index| {
        reply.* = try h.service.workspaceCommand(
            h.scratch,
            try std.fmt.allocPrint(h.scratch, "foreign-{d}", .{index}),
            task,
            request,
        );
        try std.testing.expectEqual(.rejected, reply.disposition);
    }
    try std.testing.expectEqualStrings(
        observed[0].observation_json.bytes,
        observed[1].observation_json.bytes,
    );
    try std.testing.expectEqualStrings(
        observed[2].observation_json.bytes,
        observed[3].observation_json.bytes,
    );
}

fn invalidRetain(h: anytype, task: Task, program: wc.Ref) !void {
    const generation = h.namespace.store.head.generation;
    const reply = try h.service.workspaceCommand(h.scratch, "invalid-retain", task, .{
        .program = .{ .retain = .{
            .program = program,
            .scope = .{ .bytes = "methods" },
            .description = .{
                .name = .{ .bytes = "" },
                .purpose = .{ .bytes = "An empty name cannot become an importable definition" },
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

fn revise(h: anytype, task: Task, original: wc.RetainedLocator) !wc.RetainedLocator {
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
    const second = try command(h, task, "retain-revision-again", .{ .program = .{ .retain = .{
        .program = program,
        .scope = original.scope,
        .description = .{
            .name = .{ .bytes = "adjust" },
            .purpose = .{ .bytes = "Same code with a later immutable history" },
        },
    } } });
    return retainedLocator(h.scratch, second);
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
    try closeFixture(h);
    try openFixture(Types, h);
}

fn closeFixture(h: anytype) !void {
    try h.service.park(h.scratch);
    try h.service.close(h.scratch);
    h.service_open = false;
    try h.namespace.close();
    h.namespace_open = false;
}

fn openFixture(comptime Types: type, h: anytype) !void {
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
