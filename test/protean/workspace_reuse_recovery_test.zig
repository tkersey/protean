const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const support = @import("workspace_test_support.zig");
const wc = contracts.workspace;
const state = native.testing.state;
const Task = state.TaskId;
const Kind = @FieldType(wc.Ref, "kind");
const Occurrence = native.testing.occurrence.Occurrence;

pub fn run(comptime Types: type, h: anytype, locator: wc.RetainedLocator) !void {
    try authoredImport(Types, h, locator);
    try authoredRetain(Types, h, locator);
    var rows = try h.namespace.store.database.prepare("SELECT count(*) FROM tasks", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 0), try rows.integer(0));
}

fn authoredImport(comptime Types: type, h: anytype, locator: wc.RetainedLocator) !void {
    const task = (try h.service.submit(h.scratch, "authored-import-recovery", {})).receipt.task;
    const request: wc.Command = .{ .program = .{ .import = .{ .locator = locator } } };
    const committed = try interruptReply(h, task, "authored-import-message", request, .imported);
    try reopen(Types, h);
    const saved = try resumePending(h, task, .imported, committed, "resume-authored-import");
    const original = h.service.profile.reuse;
    defer h.service.profile.reuse = original;
    var scopes = [_]native.reuse_policy.Scope{original.scopes[0]};
    scopes[0].import = false;
    h.service.profile.reuse.scopes = &scopes;
    try std.testing.expectError(error.Denied, h.service.pump(h.scratch));
    try expectPreserved(h, task, .imported, saved, false);
    h.service.profile.reuse = original;
    try settleReply(h, task, .imported, saved);
    try discard(h, task, "discard-authored-import");
}

fn authoredRetain(comptime Types: type, h: anytype, locator: wc.RetainedLocator) !void {
    const task = (try h.service.submit(h.scratch, "authored-retain-recovery", {})).receipt.task;
    const imported = try h.service.workspaceCommand(h.scratch, "retain-recovery-input", task, .{
        .program = .{ .import = .{ .locator = locator } },
    });
    try std.testing.expectEqual(.observed, imported.disposition);
    const request: wc.Command = .{ .program = .{ .retain = .{
        .program = imported.program orelse return error.ExpectedProgram,
        .scope = locator.scope,
        .description = .{
            .name = .{ .bytes = "recovery witness" },
            .purpose = .{ .bytes = "Preserve committed publication across lost reply recovery" },
        },
    } } };
    const committed = try interruptReply(h, task, "authored-retain-message", request, .retained);
    try reopen(Types, h);
    const saved = try resumePending(h, task, .retained, committed, "resume-authored-retain");
    const original = h.service.profile.reuse;
    defer h.service.profile.reuse = original;
    var disclosure: DeniedDisclosure = .{};
    h.service.profile.reuse.context = &disclosure;
    h.service.profile.reuse.disclosure = DeniedDisclosure.check;
    try std.testing.expect(h.service.profile.reuse.scopes[0].retain);
    try std.testing.expectError(error.Denied, h.service.pump(h.scratch));
    try std.testing.expectEqual(@as(u32, 1), disclosure.calls);
    try expectPreserved(h, task, .retained, saved, false);
    h.service.profile.reuse = original;
    try revokedRetainReplay(h, task, request, saved);
    try settleReply(h, task, .retained, saved);
    try discard(h, task, "discard-authored-retain");
}

const DeniedDisclosure = struct {
    calls: u32 = 0,

    fn check(
        context: ?*anyopaque,
        _: native.registry.Authority,
        scope: native.reuse_policy.Scope,
        frozen: native.reuse_policy.Frozen,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try std.testing.expect(scope.retain);
        try std.testing.expect(frozen.artifacts.len != 0);
        try std.testing.expect(frozen.history.len != 0);
        try std.testing.expect(frozen.description.len != 0);
        self.calls += 1;
        return error.Denied;
    }
};

const RevokingDisclosure = struct {
    revoked: *bool,
    calls: u32 = 0,

    fn check(
        context: ?*anyopaque,
        _: native.registry.Authority,
        scope: native.reuse_policy.Scope,
        frozen: native.reuse_policy.Frozen,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        try std.testing.expect(scope.retain);
        try std.testing.expect(frozen.artifacts.len != 0);
        try std.testing.expect(frozen.history.len != 0);
        try std.testing.expect(frozen.description.len != 0);
        self.calls += 1;
        self.revoked.* = true;
    }
};

fn revokedRetainReplay(h: anytype, task: Task, request: wc.Command, saved: Saved) !void {
    const authority = h.service.profile.authority;
    const policy = h.service.profile.reuse;
    defer h.service.profile.authority = authority;
    defer h.service.profile.reuse = policy;
    var disclosure: RevokingDisclosure = .{ .revoked = &h.service.profile.authority.revoked };
    h.service.profile.reuse.context = &disclosure;
    h.service.profile.reuse.disclosure = RevokingDisclosure.check;
    const operation = std.fmt.bytesToHex(saved.receipt.occurrence, .lower);
    const reply = try h.service.workspaceCommand(h.scratch, &operation, task, request);
    try std.testing.expectEqual(@as(u32, 1), disclosure.calls);
    try std.testing.expect(h.service.profile.authority.revoked);
    try std.testing.expectEqual(.rejected, reply.disposition);
    try std.testing.expect(reply.program == null);
    const locator = std.fmt.bytesToHex(saved.receipt.workspace, .lower);
    try std.testing.expect(std.mem.indexOf(u8, reply.observation_json.bytes, &locator) == null);
    var parsed = try native.json.parse(h.scratch, reply.observation_json.bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.contains("retained"));
    h.service.profile.authority = authority;
    h.service.profile.reuse = policy;
    try expectPreserved(h, task, .retained, saved, false);
}

const ReceiptCut = struct {
    digest: state.Digest,
    occurrence: state.Digest,
    workspace: state.Digest,
    observation: state.Reference,
    revision: u64,
};

fn receiptCut(
    namespace: *native.Namespace,
    a: std.mem.Allocator,
    task: Task,
    kind: Kind,
) !?ReceiptCut {
    var rows = try namespace.store.database.prepare(
        "SELECT p.receipt,o.body FROM operations p JOIN objects o ON o.digest=p.receipt " ++
            "WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    var found: ?ReceiptCut = null;
    while (try rows.step() == .row) {
        var decoded = try contracts.decodeOwned(state.Receipt, a, try rows.bytes(1));
        defer decoded.deinit();
        const receipt = decoded.value;
        if (receipt.workspace_kind != kind) continue;
        if (found != null) return error.DuplicateReuseReceipt;
        try std.testing.expectEqual(.accepted, receipt.disposition);
        var occurrence_id: state.Digest = undefined;
        _ = try std.fmt.hexToBytes(&occurrence_id, receipt.client_operation_id.bytes);
        const digest = try rows.bytes(0);
        try std.testing.expectEqual(@as(usize, 32), digest.len);
        found = .{
            .digest = digest[0..32].*,
            .occurrence = occurrence_id,
            .workspace = receipt.workspace orelse return error.ExpectedReuseIdentity,
            .observation = receipt.workspace_observation orelse return error.ExpectedObservation,
            .revision = receipt.revision,
        };
    }
    return found;
}

const AfterReuseCommitAllocator = struct {
    backing: std.mem.Allocator,
    namespace: *native.Namespace,
    task: Task,
    kind: Kind,
    generation: u64,
    committed: bool = false,
    rejected: usize = 0,
    probe_error: ?anyerror = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn blocked(self: *@This()) bool {
        const store = &self.namespace.store;
        if (!store.transaction and store.head.generation != self.generation) {
            self.generation = store.head.generation;
            const cut = receiptCut(self.namespace, self.backing, self.task, self.kind) catch |err| {
                self.probe_error = err;
                return true;
            };
            self.committed = cut != null;
        }
        if (!self.committed) return false;
        self.rejected += 1;
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.blocked()) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(
        ctx: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return false;
        return self.backing.rawResize(bytes, alignment, len, ra);
    }

    fn remap(
        ctx: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return null;
        return self.backing.rawRemap(bytes, alignment, len, ra);
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

const Saved = struct {
    receipt: ReceiptCut,
    custody: state.Digest,
    operations: i64,
    definitions: i64,
};

fn resumePending(
    h: anytype,
    task: Task,
    kind: Kind,
    committed: Saved,
    operation: []const u8,
) !Saved {
    try expectPreserved(h, task, kind, committed, false);
    var parent = try h.service.task(h.scratch, task);
    defer parent.deinit();
    try std.testing.expectEqual(.parked, parent.value.schedule);
    const resumed = try h.service.resumeTask(h.scratch, operation, task, parent.value.revision);
    try std.testing.expect(!resumed.replayed);
    try std.testing.expectEqual(.@"resume", resumed.receipt.method);
    var saved = committed;
    saved.operations += 1;
    try expectPreserved(h, task, kind, saved, false);
    return saved;
}

fn interruptReply(
    h: anytype,
    task: Task,
    message: []const u8,
    request: wc.Command,
    kind: Kind,
) !Saved {
    _ = try h.service.message(h.scratch, message, task, request);
    var fault: AfterReuseCommitAllocator = .{
        .backing = h.scratch,
        .namespace = &h.namespace,
        .task = task,
        .kind = kind,
        .generation = h.namespace.store.head.generation,
    };
    for (0..128) |_| {
        const step = h.service.pump(fault.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (fault.probe_error) |probe_error| return probe_error;
            try std.testing.expect(fault.committed and fault.rejected > 0);
            const saved = try snapshot(h, task, kind);
            try expectPreserved(h, task, kind, saved, false);
            return saved;
        };
        try std.testing.expect(step != .work);
    }
    return error.ReuseCommitNotInterrupted;
}

fn snapshot(h: anytype, task: Task, kind: Kind) !Saved {
    const receipt = try receiptCut(&h.namespace, h.scratch, task, kind) orelse
        return error.ExpectedCommittedReceipt;
    var custody = try h.namespace.store.database.prepare(
        "SELECT body FROM records WHERE task=? AND kind='workspace_program'",
        &.{.{ .blob = &task }},
    );
    defer custody.deinit();
    try std.testing.expectEqual(.row, try custody.step());
    const bytes = try custody.bytes(0);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    const digest = bytes[0..32].*;
    try std.testing.expectEqual(.done, try custody.step());
    var definitions = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM reuse_definitions",
        &.{},
    );
    defer definitions.deinit();
    try std.testing.expectEqual(.row, try definitions.step());
    return .{
        .receipt = receipt,
        .custody = digest,
        .operations = try count(h, task, "operations", ""),
        .definitions = try definitions.integer(0),
    };
}

fn count(h: anytype, task: Task, comptime table: []const u8, comptime extra: []const u8) !i64 {
    var rows = try h.namespace.store.database.prepare(
        "SELECT count(*) FROM " ++ table ++ " WHERE task=?" ++ extra,
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    return rows.integer(0);
}

fn expectPreserved(h: anytype, task: Task, kind: Kind, saved: Saved, settled: bool) !void {
    try std.testing.expectEqualDeep(saved, try snapshot(h, task, kind));
    try std.testing.expectEqual(@as(i64, 0), try count(
        h,
        task,
        "records",
        " AND kind='workspace_work'",
    ));
    try std.testing.expectEqual(@as(i64, @intFromBool(settled)), try count(
        h,
        task,
        "records",
        " AND kind='workspace_reply'",
    ));
    var pending = try occurrence(h, task, saved.receipt.occurrence);
    defer pending.deinit();
    if (settled) {
        try std.testing.expect(pending.value.state == .settled_reply);
    } else {
        try std.testing.expect(pending.value.state == .ready);
        var parent = try h.service.task(h.scratch, task);
        defer parent.deinit();
        try std.testing.expectEqualDeep(
            saved.receipt.occurrence,
            parent.value.current_occurrence.?,
        );
    }
}

fn occurrence(h: anytype, task: Task, id: state.Digest) !contracts.Decoded(Occurrence) {
    const bytes = try h.namespace.store.recordBytes(h.scratch, "occurrence", id, task) orelse
        return error.ExpectedOccurrence;
    defer h.scratch.free(bytes);
    return contracts.decodeOwned(Occurrence, h.scratch, bytes);
}

fn settleReply(h: anytype, task: Task, kind: Kind, saved: Saved) !void {
    try std.testing.expectEqual(.progressed, try h.service.pump(h.scratch));
    try expectPreserved(h, task, kind, saved, true);
    const id = saved.receipt.occurrence;
    const bytes = try h.namespace.store.recordBytes(h.scratch, "workspace_reply", id, task) orelse
        return error.ExpectedWorkspaceReply;
    defer h.scratch.free(bytes);
    var observed = try contracts.decodeOwned(native.workspace.ReplyObservation, h.scratch, bytes);
    defer observed.deinit();
    try std.testing.expect(observed.value.evidence == .admitted);
    try std.testing.expect(observed.value.evidence.admitted.replayed);
    var pending = try occurrence(h, task, id);
    defer pending.deinit();
    const bound = try h.namespace.store.acquiredObject(
        h.scratch,
        pending.value.state.settled_reply.reply,
        null,
    );
    defer h.scratch.free(bound);
    var result = try data.invocation.decode(data.invocation.Result, h.scratch, bound);
    defer result.deinit();
    var reply = try contracts.decodeOwned(wc.Reply, h.scratch, result.value.value);
    defer reply.deinit();
    try std.testing.expectEqual(.observed, reply.value.disposition);
    try expectOriginalResult(h, kind, saved.receipt, reply.value);
}

fn expectOriginalResult(h: anytype, kind: Kind, saved: ReceiptCut, reply: wc.Reply) !void {
    const bytes = try h.namespace.store.object(h.scratch, saved.observation, null);
    defer h.scratch.free(bytes);
    if (kind == .imported) {
        var imported = try contracts.decodeOwned(native.testing.reuse.Import, h.scratch, bytes);
        defer imported.deinit();
        const program = reply.program orelse return error.ExpectedProgram;
        try std.testing.expectEqualDeep(imported.value.program.digest, try support.nativeIdentity(
            program,
        ));
        return;
    }
    var parsed = try native.json.parse(h.scratch, reply.observation_json.bytes, .{});
    defer parsed.deinit();
    const retained = try native.values.fromJson(
        wc.RetainedLocator,
        h.scratch,
        parsed.value.object.get("retained") orelse return error.ExpectedRetainedLocator,
    );
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(saved.workspace, .lower),
        retained.id.bytes,
    );
}

fn discard(h: anytype, task: Task, operation: []const u8) !void {
    _ = try h.service.requestCancel(h.scratch, operation, task, "Recovery witness finished");
    for (0..128) |_| {
        var parent = try h.service.task(h.scratch, task);
        defer parent.deinit();
        if (try h.service.taskCleanupComplete(h.scratch, parent.value)) {
            try h.service.discardTask(h.scratch, task);
            inline for (.{ "records", "events", "operations" }) |table|
                try std.testing.expectEqual(@as(i64, 0), try count(h, task, table, ""));
            return;
        }
        try std.testing.expect(try h.service.pump(h.scratch) != .work);
    }
    return error.RecoveryCleanupNotSettled;
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
