const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const support = @import("workspace_test_support.zig");
const state = native.testing.state;
const archive = native.testing.archive;
const reuse = native.testing.reuse;
const Task = state.TaskId;

pub fn run(
    comptime Types: type,
    h: anytype,
    locator: contracts.workspace.RetainedLocator,
) !void {
    const task = try reader(h, locator);
    const valid = try path(h, "admission-reader.tar");
    _ = try h.service.exportCheckpoint(h.scratch, task, valid);
    try discard(h, task);
    try h.service.close(h.scratch);
    h.service_open = false;
    try h.namespace.close();
    h.namespace_open = false;
    defer support.expectCleanup(reopen(Types, h));
    const forged = try path(h, "admission-forged.tar");
    const rejected = try probeReader(Types, h, task, valid, forged, locator);
    const restored = try probeRestore(Types, h, forged);
    std.debug.print("passive submit admission rejected: reader={any}, restore={any}\n", .{
        rejected, restored,
    });
    try std.testing.expect(rejected and restored);
}

fn reader(h: anytype, locator: contracts.workspace.RetainedLocator) !Task {
    const task = (try h.service.submit(h.scratch, "admission-reader", {})).receipt.task;
    _ = try h.service.message(h.scratch, "admission-find", task, .{ .program = .{ .find = .{
        .scope = locator.scope,
        .query = .{ .bytes = "no matching admission witness" },
        .maximum = 64,
    } } });
    for (0..128) |_| {
        try std.testing.expect(try h.service.pump(h.scratch) != .work);
        var rows = try h.namespace.store.database.prepare(
            "SELECT count(*) FROM records WHERE task=? AND kind='workspace_reply'",
            &.{.{ .blob = &task }},
        );
        defer rows.deinit();
        try std.testing.expectEqual(.row, try rows.step());
        if (try rows.integer(0) == 1) return task;
    }
    return error.ExpectedPassiveRead;
}

fn probeReader(
    comptime Types: type,
    h: anytype,
    task: Task,
    valid: []const u8,
    forged: []const u8,
    locator: contracts.workspace.RetainedLocator,
) !bool {
    var namespace = try native.Namespace.open(h.a, h.io, try path(h, "admission-reader"));
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(Types).init(
        h.a,
        h.io,
        &namespace,
        h.assets,
        &h.application,
        h.handlers,
        h.profile,
    );
    defer support.expectCleanup(service.close(h.a));
    _ = try service.importCheckpoint(h.scratch, "import-admission-reader", valid);
    try forge(&namespace, h.scratch, task, locator);
    _ = try archive.write(
        h.a,
        h.io,
        &namespace.store,
        task,
        h.assets.manifest,
        forged,
        namespace.directory,
    );
    const validation = try rejects(service.validateWorkspace(h.scratch, task));
    const exported = try rejects(service.exportCheckpoint(
        h.scratch,
        task,
        try path(h, "admission-export.tar"),
    ));
    std.debug.print("passive submit admission validation={any}, export={any}\n", .{
        validation, exported,
    });
    return validation and exported;
}

fn probeRestore(comptime Types: type, h: anytype, forged: []const u8) !bool {
    var namespace = try native.Namespace.open(h.a, h.io, try path(h, "admission-restored"));
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(Types).init(
        h.a,
        h.io,
        &namespace,
        h.assets,
        &h.application,
        h.handlers,
        h.profile,
    );
    defer support.expectCleanup(service.close(h.a));
    return rejects(service.importCheckpoint(h.scratch, "restore-forged-admission", forged));
}

fn rejects(result: anytype) !bool {
    if (result) |_| return false else |err| {
        try std.testing.expectEqual(error.InvalidArchive, err);
        return true;
    }
}

fn forge(
    namespace: *native.Namespace,
    a: std.mem.Allocator,
    task: Task,
    locator: contracts.workspace.RetainedLocator,
) !void {
    const store = &namespace.store;
    var observed = try readObservation(namespace, a, task);
    defer observed.deinit();
    try std.testing.expect(observed.value.evidence == .read);
    try std.testing.expect(observed.value.evidence.read == .reuse);
    const selection = &observed.value.evidence.read.reuse.selection;
    try std.testing.expect(selection.* == .find);
    const definitions = try a.dupe(state.Reference, selection.find.definitions.items);
    selection.find.definitions.items = definitions;
    var target: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target, locator.id.bytes);
    const selected = for (definitions) |*reference| {
        if (std.mem.eql(u8, &reference.digest, &target)) break reference;
    } else return error.ExpectedNestedDefinition;
    const bytes = try store.object(a, selected.*, null);
    defer a.free(bytes);
    var definition = try contracts.decodeOwned(reuse.Definition, a, bytes);
    defer definition.deinit();
    try forgeSubmit(namespace, a, &definition.value.origin);
    var inspected = try archive.inspect(a, store, definition.value.origin, null);
    defer inspected.task.deinit();
    try reuse.validate(a, store, definition.value);
    const prepared = try store.prepareDefinition(a, definition.value);
    defer a.free(prepared.bytes);
    defer a.free(prepared.children);
    try store.begin();
    defer store.rollback();
    store.invalidateIntegrity();
    const reference = try store.retainDefinition(prepared);
    selected.* = reference;
    std.mem.sort(state.Reference, definitions, {}, lessReference);
    try store.database.run("DELETE FROM records WHERE kind='workspace_reply' AND task=?", &.{.{
        .blob = &task,
    }});
    try store.createRecord(
        native.workspace.ReplyObservation,
        "workspace_reply",
        observed.value.id,
        task,
        observed.value,
    );
    _ = try store.commit("test.forge-passive-admission");
}

fn forgeSubmit(namespace: *native.Namespace, a: std.mem.Allocator, origin: *state.Archive) !void {
    const store = &namespace.store;
    const operations = try a.dupe(state.ArchiveOperation, origin.operations.items);
    const objects = try a.alloc(state.Reference, origin.objects.items.len + 1);
    @memcpy(objects[0..origin.objects.items.len], origin.objects.items);
    origin.operations.items = operations;
    var changed = false;
    for (operations) |*row| {
        const bytes = try store.object(a, row.body, null);
        defer a.free(bytes);
        var receipt = try contracts.decodeOwned(state.Receipt, a, bytes);
        defer receipt.deinit();
        if (receipt.value.method != .submit) continue;
        try std.testing.expect(!changed);
        const old = row.body;
        try std.testing.expect(try receiptReferenced(store, origin.objects.items, old));
        receipt.value.request_digest[0] ^= 1;
        row.request = receipt.value.request_digest;
        const encoded = try contracts.encodeOwned(state.Receipt, a, receipt.value);
        defer a.free(encoded);
        try store.begin();
        defer store.rollback();
        row.body = try store.putObject(encoded);
        _ = try store.commit("test.forge-submit-receipt");
        objects[origin.objects.items.len] = row.body;
        changed = true;
    }
    try std.testing.expect(changed);
    origin.objects.items = objects;
    std.mem.sort(state.Reference, objects, {}, lessReference);
}

fn lessReference(_: void, left: state.Reference, right: state.Reference) bool {
    return std.mem.order(u8, &left.digest, &right.digest) == .lt;
}

fn receiptReferenced(
    store: *@FieldType(native.Namespace, "store"),
    objects: []const state.Reference,
    receipt: state.Reference,
) !bool {
    var rows = try store.database.prepare(
        "SELECT parent FROM dependencies WHERE child=?",
        &.{.{ .blob = &receipt.digest }},
    );
    defer rows.deinit();
    while (try rows.step() == .row) {
        const parent = try rows.bytes(0);
        for (objects) |object| {
            if (std.mem.eql(u8, parent, &object.digest)) return true;
        }
    }
    return false;
}

fn readObservation(
    namespace: *native.Namespace,
    a: std.mem.Allocator,
    task: Task,
) !contracts.Decoded(native.workspace.ReplyObservation) {
    var rows = try namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.kind='workspace_reply' AND r.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    try std.testing.expectEqual(.row, try rows.step());
    return contracts.decodeOwned(native.workspace.ReplyObservation, a, try rows.bytes(0));
}

fn path(h: anytype, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(h.scratch, "{s}/{s}", .{ h.path_buffer[0..h.length], name });
}

fn discard(h: anytype, task: Task) !void {
    _ = try h.service.requestCancel(h.scratch, "admission-cancel", task, "Read witness finished");
    for (0..128) |_| {
        var parent = try h.service.task(h.scratch, task);
        defer parent.deinit();
        if (try h.service.taskCleanupComplete(h.scratch, parent.value)) {
            try h.service.discardTask(h.scratch, task);
            return;
        }
        try std.testing.expect(try h.service.pump(h.scratch) != .work);
    }
    return error.AdmissionCleanupNotSettled;
}

fn reopen(comptime Types: type, h: anytype) !void {
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
