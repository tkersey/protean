const horos_authoring = @import("horos").authoring;
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const kosmos = @import("kosmos");

test "recursive participant native execution restores repeated typed demand" {
    try @import("recursive_participant.zig").nativeExecution(kosmos);
}

const protocol = horos.data.invocation;
const Inbox = protean.inbox.Profile(u32);
const T = struct {
    pub const application_id = "task-owner-test";
    pub const input_schema_id = "task-owner.input.v1";
    pub const output_schema_id = "task-owner.output.v1";
    pub const failure_schema_id = "task-owner.failure.v1";
    pub const message_schema_id = "task-owner.message.v1";
    pub const Input = u32;
    pub const Padding = protean.contracts.Bytes(64 * 1024);
    pub const Output = struct { answer: u32, inbox: Inbox.Reply, padding: Padding };
    pub const Failure = void;
    pub const Message = u32;
};
fn MessageContract(comptime application: []const u8, comptime message: []const u8) type {
    return struct {
        pub const application_id = application;
        pub const input_schema_id = T.input_schema_id;
        pub const output_schema_id = T.output_schema_id;
        pub const failure_schema_id = T.failure_schema_id;
        pub const message_schema_id = message;
        pub const Input = T.Input;
        pub const Output = T.Output;
        pub const Failure = T.Failure;
        pub const Message = T.Message;
    };
}
const Application = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const number = try horos_authoring.interop.schemaId(c.author, try c.schema(u32));
        const output = try horos_authoring.interop.schemaId(c.author, try c.schema(T.Output));
        const leaf = try horos_authoring.interop.operationId(c.author, try c.external("task-owner.increment.v1", try horos_authoring.interop.schema(c.author, number), try horos_authoring.interop.schema(c.author, number), .read));
        const question = try horos_authoring.interop.operationId(c.author, try c.external("task-owner.question.v1", try horos_authoring.interop.schema(c.author, number), try horos_authoring.interop.schema(c.author, number), .read));
        const inbox = try horos_authoring.interop.operationId(c.author, try Inbox.declare(c));
        const entry = try b.declare(&.{number}, output, &.{ leaf, question, inbox }, &.{});
        const incremented = try b.variable(number);
        const answer = try b.variable(number);
        const message = try b.variable(try horos_authoring.interop.schemaId(c.author, try c.schema(Inbox.Reply)));
        const padding = try horos_authoring.interop.valueId(c.author, try c.literal(T.Padding, .{ .bytes = &@as([64 * 1024]u8, @splat('x')) }));
        const result = try b.primitive(output, .product, &.{ try b.reference(answer), try b.reference(message), padding }, 0);
        try b.define(entry, try b.bind(incremented, try b.term(.{ .perform = .{ .effect = leaf, .payload = try b.reference(b.parameter(entry, 0)) } }), try b.bind(answer, try b.term(.{ .perform = .{ .effect = question, .payload = try b.reference(incremented) } }), try b.bind(message, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), try b.term(.{ .yield_then = try b.pure(result) })))));
        return b.module(entry, try horos_authoring.interop.schemaId(c.author, try c.schema(void)));
    }
};
fn increment(_: native.Context, input: u32) !u32 {
    return input + 1;
}
fn present(ctx: native.Context, input: u32) !native.json.Value {
    try std.testing.expectEqualStrings("fixed-profile", ctx.profile);
    const configured: *const u32 = @ptrCast(@alignCast(ctx.environment orelse return error.MissingConfiguration));
    try std.testing.expectEqual(37, configured.*);
    if (input == 42) {
        var dense: native.json.Value = .{ .array = .init(ctx.allocator) };
        for (0..10_000) |_| try dense.array.append(.{ .integer = 0 });
        return dense;
    }
    if (input == 43) {
        var deep: native.json.Value = .null;
        for (0..32) |_| {
            var parent: native.json.Value = .{ .array = .init(ctx.allocator) };
            try parent.array.append(deep);
            deep = parent;
        }
        return deep;
    }
    if (input == 44) {
        const text = try ctx.allocator.alloc(u8, 128 * 1024);
        @memset(text, 'q');
        return native.json.string(text);
    }
    return native.json.number(ctx.allocator, input);
}
const CapturingIncrement = struct {
    var interpretations: usize = 0;
    fn prepare(ctx: native.registry.ProjectionContext, payload: []const u8) ![]u8 {
        var value = try protean.contracts.decodeOwned(u32, ctx.allocator, payload);
        defer value.deinit();
        return std.fmt.allocPrint(ctx.allocator, "increment:{d}", .{value.value});
    }
    fn invoke(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
        if (!std.mem.eql(u8, bytes, "increment:20")) return error.InvalidPreparedRequest;
        return .{ .captured = try ctx.allocator.dupe(u8, "raw-response:21") };
    }
    fn interpret(ctx: native.registry.ProjectionContext, payload: []const u8, rendered: []const u8, raw: []const u8) !native.registry.Projection {
        interpretations += 1;
        if (!std.mem.eql(u8, rendered, "increment:20") or !std.mem.eql(u8, raw, "raw-response:21")) return error.InvalidCapture;
        var value = try protean.contracts.decodeOwned(u32, ctx.allocator, payload);
        defer value.deinit();
        if (value.value != 20) return error.InvalidCapture;
        const replay = try ctx.allocator.alloc(u8, 2 * 1024 * 1024);
        @memset(replay, 'R');
        const objects = try ctx.allocator.alloc([]const u8, 1);
        objects[0] = replay;
        return .{ .reply = try protean.contracts.encodeOwned(u32, ctx.allocator, 21), .objects = objects };
    }
};

test "durable owner replays admissions and acquired work, binds answers, and consumes queued input once" {
    const a = std.testing.allocator;
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = T.Input, .Result = T.Output, .Failure = T.Failure, .application = Application }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    ownerRecovery(false, image) catch |err| {
        std.debug.print("direct owner recovery: {s}\n", .{@errorName(err)});
        return err;
    };
    ownerRecovery(true, image) catch |err| {
        std.debug.print("captured owner recovery: {s}\n", .{@errorName(err)});
        return err;
    };
}

pub const ownerManifest = @import("native_test_support.zig").ownerManifest;

// Rehash a well-formed archive while removing one semantic fact. Keep every
// other object, sequence, revision and operation receipt unchanged.
const ArchiveFactChange = enum { cancellation_omitted, cancellation_reason, terminal_cancellation_omitted, terminal_cancellation_reason, checkpoint_cancellation_reason, checkpoint_cancellation_bytes, terminal_omitted, message_not_consumed };
fn omitArchiveFact(a: std.mem.Allocator, io: std.Io, shape: anytype, task: anytype, source: []const u8, destination: []const u8, change: ArchiveFactChange) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(16 * 1024 * 1024));
    const schema_length = std.mem.readInt(u32, bytes[8..12], .little);
    const manifest_length = std.mem.readInt(u32, bytes[12..16], .little);
    const start = 32 + schema_length;
    const decoded = try protean.contracts.decodeOwned(@TypeOf(shape), a, bytes[start..][0..manifest_length]);
    var archive = decoded.value;
    const Reference = @TypeOf(archive.task);
    const Blob = struct { reference: Reference, bytes: []const u8 };
    var blobs: std.ArrayList(Blob) = .empty;
    var offset: usize = start + manifest_length;
    for (archive.objects.items) |reference| {
        const length: usize = @intCast(reference.bytes);
        try blobs.append(a, .{ .reference = reference, .bytes = bytes[offset..][0..length] });
        offset += length;
    }
    var target: *Reference = undefined;
    var replacement: []const u8 = undefined;
    if (change == .checkpoint_cancellation_reason or change == .checkpoint_cancellation_bytes) {
        try std.testing.expect(!task.terminal() and task.cancellation_applied and task.cancellation != null);
        const checkpoint = for (blobs.items) |blob| {
            if (std.meta.eql(blob.reference, task.checkpoint)) break blob.bytes;
        } else return error.MissingCheckpoint;
        var graph = try horos.data.state_image.decodeGraph(a, checkpoint);
        defer graph.deinit();
        const nodes = try a.dupe(horos.data.process_state.Node, graph.state.nodes);
        defer a.free(nodes);
        graph.state.nodes = nodes;
        var cursor = graph.state.roots.exit orelse return error.MissingCancellation;
        while (nodes[@intCast(cursor.id)].record.exit.outer) |outer| cursor = outer;
        nodes[@intCast(cursor.id)].record.exit.cancellation = if (change == .checkpoint_cancellation_reason)
            .{ .text = "different kernel reason" }
        else
            .{ .bytes = task.cancellation.?.bytes };
        const changed_checkpoint = try horos.data.state_image.emit(a, graph.state);
        var changed = task;
        std.crypto.hash.sha2.Sha256.hash(changed_checkpoint, &changed.checkpoint.digest, .{});
        changed.checkpoint.bytes = changed_checkpoint.len;
        for (blobs.items) |*blob| if (std.meta.eql(blob.reference, task.checkpoint)) {
            blob.* = .{ .reference = changed.checkpoint, .bytes = changed_checkpoint };
        };
        replacement = try protean.contracts.encodeOwned(@TypeOf(task), a, changed);
        target = &archive.task;
    } else if (change == .cancellation_omitted or change == .cancellation_reason or change == .terminal_cancellation_omitted or change == .terminal_cancellation_reason) {
        const terminal = change == .terminal_cancellation_omitted or change == .terminal_cancellation_reason;
        try std.testing.expect(task.terminal() == terminal and task.cancellation != null and task.cancellation_applied == terminal);
        var changed = task;
        const omitted = change == .cancellation_omitted or change == .terminal_cancellation_omitted;
        changed.cancellation = if (omitted) null else .{ .bytes = "unacknowledged replacement" };
        if (terminal and omitted) changed.cancellation_applied = false;
        replacement = try protean.contracts.encodeOwned(@TypeOf(task), a, changed);
        target = &archive.task;
    } else {
        // This independent wire shape deliberately replaces a terminal event
        // with a legal historical kind rather than corrupting its encoding.
        const Event = struct {
            task: [16]u8,
            seq: u64,
            revision: u64,
            kind: enum { accepted, input_required, input_accepted, message_queued, message_consumed, message_not_consumed, cancellation_requested, parked, resumed, blocked, delivery_unknown, completed, failed, cancelled, imported, reconciled, workspace, workspace_progress, workspace_read, controller, controller_requested, execution },
            data: protean.contracts.Bytes(48 * 1024),
            workspace_publications: protean.contracts.Vector(struct {
                work: [32]u8,
                execution_revision: u64,
                control_revision: u64,
                observation: [32]u8,
                control: struct {
                    policy: struct { stop: enum { next_slice, next_exposed_event, terminal }, continuation: enum { explicit_only, owner_scheduled } },
                    schedule: enum { queued, active, parked },
                    blocker: ?enum { missing_capability, denied, capacity, missing_artifact, incompatible_profile, unavailable_environment },
                    cancellation: ?protean.contracts.Text(256),
                    cancellation_applied: bool,
                    outcome: enum { progressed, yielded, requested, completed, failed, cancelled },
                    instrument: bool,
                    port: bool,
                    delivery: ?enum { ready, dispatching, awaiting, unknown, settled_reply, admitted, not_sent, captured },
                },
            }, null),
            workspace_command: ?Reference,
            residual_publications: protean.contracts.Vector(native.testing.state.ResidualPublication, null),
            controller_read: ?struct { event_watermark: u64, execution_revision: u64 },
            root_publication: ?struct {
                before: struct { controller: ?[32]u8, checkpoint: [32]u8 },
                after: struct { controller: ?[32]u8, checkpoint: [32]u8 },
            },
        };
        var found = false;
        const events = try a.dupe(@TypeOf(archive.events.items[0]), archive.events.items);
        archive.events.items = events;
        for (events) |*row| {
            for (blobs.items) |blob| {
                if (!std.mem.eql(u8, &blob.reference.digest, &row.body.digest)) continue;
                var event = (try protean.contracts.decodeOwned(Event, a, blob.bytes)).value;
                try std.testing.expectEqual(@as(usize, 0), event.workspace_publications.items.len);
                try std.testing.expectEqual(@as(usize, 0), event.residual_publications.items.len);
                if (change == .message_not_consumed) {
                    if (event.kind != .message_not_consumed) break;
                } else {
                    if (event.kind != .completed and event.kind != .failed and event.kind != .cancelled) break;
                    try std.testing.expectEqualStrings(@tagName(task.outcome_kind), @tagName(event.kind));
                }
                event.kind = .blocked;
                event.data.bytes = "{}";
                replacement = try protean.contracts.encodeOwned(Event, a, event);
                target = &row.body;
                found = true;
                break;
            }
            if (found) break;
        }
        try std.testing.expect(found);
    }
    const previous = target.*;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(replacement, &digest, .{});
    target.* = .{ .digest = digest, .bytes = replacement.len };
    var replaced = false;
    for (blobs.items) |*blob| if (std.mem.eql(u8, &blob.reference.digest, &previous.digest)) {
        blob.* = .{ .reference = target.*, .bytes = replacement };
        replaced = true;
    };
    try std.testing.expect(replaced);
    std.mem.sort(Blob, blobs.items, {}, struct {
        fn less(_: void, left: Blob, right: Blob) bool {
            return std.mem.order(u8, &left.reference.digest, &right.reference.digest) == .lt;
        }
    }.less);
    const references = try a.alloc(Reference, blobs.items.len);
    var body: std.ArrayList(u8) = .empty;
    for (blobs.items, references) |blob, *reference| {
        reference.* = blob.reference;
        try body.appendSlice(a, blob.bytes);
    }
    archive.objects.items = references;
    const manifest = try protean.contracts.encodeOwned(@TypeOf(shape), a, archive);
    var header: [32]u8 = bytes[0..32].*;
    std.mem.writeInt(u32, header[12..16], @intCast(manifest.len), .little);
    std.mem.writeInt(u32, header[16..20], @intCast(blobs.items.len), .little);
    std.mem.writeInt(u64, header[24..32], body.items.len, .little);
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, &header);
    try output.appendSlice(a, bytes[32..start]);
    try output.appendSlice(a, manifest);
    try output.appendSlice(a, body.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = output.items, .flags = .{ .permissions = .fromMode(0o600) } });
}

// Independently rewrite the ordinary archive envelope. This fixture's captured
// increment has one fixed replay object and two fixed adapter byte strings;
// retained canonical requests/replies stay in the object inventory.
fn omitIncrementEvidence(a: std.mem.Allocator, io: std.Io, shape: anytype, source: []const u8, destination: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(64 * 1024 * 1024));
    const schema_length = std.mem.readInt(u32, bytes[8..12], .little);
    const manifest_length = std.mem.readInt(u32, bytes[12..16], .little);
    const start = 32 + schema_length;
    var decoded = try protean.contracts.decodeOwned(@TypeOf(shape), a, bytes[start..][0..manifest_length]);
    defer decoded.deinit();
    var archive = decoded.value;
    var removed: std.ArrayList([32]u8) = .empty;
    for ([_][]const u8{ "increment:20", "raw-response:21" }) |raw| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        try removed.append(a, digest);
    }
    const replay = try a.alloc(u8, 2 * 1024 * 1024);
    @memset(replay, 'R');
    var replay_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(replay, &replay_digest, .{});
    try removed.append(a, replay_digest);
    var records: std.ArrayList(@TypeOf(archive.records.items[0])) = .empty;
    var count: usize = 0;
    for (archive.records.items) |row| {
        if (row.kind == .attempt or row.kind == .capture) {
            try removed.append(a, row.body.digest);
            count += @intFromBool(row.kind == .capture);
        } else try records.append(a, row);
    }
    try std.testing.expectEqual(1, count);
    archive.records.items = records.items;
    var objects: std.ArrayList(@TypeOf(archive.objects.items[0])) = .empty;
    var body: std.ArrayList(u8) = .empty;
    var offset: usize = start + manifest_length;
    for (archive.objects.items) |reference| {
        const length: usize = @intCast(reference.bytes);
        var keep = true;
        for (removed.items) |digest| if (std.mem.eql(u8, &digest, &reference.digest)) {
            keep = false;
            break;
        };
        if (keep) {
            try objects.append(a, reference);
            try body.appendSlice(a, bytes[offset..][0..length]);
        }
        offset += length;
    }
    archive.objects.items = objects.items;
    const manifest = try protean.contracts.encodeOwned(@TypeOf(shape), a, archive);
    var header: [32]u8 = bytes[0..32].*;
    std.mem.writeInt(u32, header[12..16], @intCast(manifest.len), .little);
    std.mem.writeInt(u32, header[16..20], @intCast(objects.items.len), .little);
    std.mem.writeInt(u64, header[24..32], body.items.len, .little);
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, &header);
    try output.appendSlice(a, bytes[32..start]);
    try output.appendSlice(a, manifest);
    try output.appendSlice(a, body.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = output.items, .flags = .{ .permissions = .fromMode(0o600) } });
}

fn checkCaptureImport(a: std.mem.Allocator, frame: std.mem.Allocator, io: std.Io, service: *native.tasks.Service(T), namespace: *native.Namespace, service_live: *bool, namespace_live: *bool, source_path: []const u8, directory: []const u8, task_id: [16]u8, label: []const u8) !void {
    errdefer std.debug.print("capture archive boundary: {s}\n", .{label});
    const assets = service.assets;
    const application = service.application;
    const handlers = service.handlers;
    const profile = service.profile;
    const valid = try std.fmt.allocPrint(frame, "{s}/{s}.bundle", .{ directory, label });
    const invalid = try std.fmt.allocPrint(frame, "{s}/{s}-omitted.bundle", .{ directory, label });
    const target = try std.fmt.allocPrint(frame, "{s}/{s}-import", .{ directory, label });
    _ = try service.exportCheckpoint(frame, task_id, valid);
    const shape = try namespace.store.archiveIndex(frame, task_id, .{ .digest = @splat(0), .bytes = 0 });
    try omitIncrementEvidence(frame, io, shape, valid, invalid);
    try service.close(frame);
    service_live.* = false;
    try namespace.close();
    namespace_live.* = false;
    {
        var destination = try native.Namespace.open(a, io, target);
        defer destination.close() catch unreachable;
        var imported = try native.tasks.Service(T).init(a, io, &destination, assets, application, handlers, profile);
        defer imported.close(frame) catch unreachable;
        try std.testing.expectError(error.InvalidArchive, imported.importCheckpoint(frame, "import", invalid));
        const admitted = try imported.importCheckpoint(frame, "import", valid);
        var task = try imported.task(frame, admitted.receipt.task);
        defer task.deinit();
        try std.testing.expectError(error.CustodyNotLocal, imported.resumeTask(frame, "resume-copied-capture", task.value.id, task.value.revision));
        try std.testing.expectEqual(.idle, try imported.pump(frame));
    }
    namespace.* = try native.Namespace.open(a, io, source_path);
    namespace_live.* = true;
    service.* = try native.tasks.Service(T).init(a, io, namespace, assets, application, handlers, profile);
    service_live.* = true;
    var task = try service.task(frame, task_id);
    defer task.deinit();
    _ = try service.resumeTask(frame, label, task_id, task.value.revision);
}

fn rejectRequeuedHistory(a: std.mem.Allocator, service: *native.tasks.Service(T), namespace: *native.Namespace, value: anytype, message_id: [32]u8, directory: []const u8) !void {
    try std.testing.expectEqual(.yielded, value.outcome_kind);
    const path = try std.fmt.allocPrint(a, "{s}/consumed-yield.bundle", .{directory});
    _ = try service.exportCheckpoint(a, value.id, path);
    // Independent wire record shape; deliberately bypass the producer to model
    // an internally inconsistent but rehashed archive at a nonterminal boundary.
    const Message = struct {
        id: [32]u8,
        task: [16]u8,
        ordinal: u64,
        schema_id: @TypeOf(value.message_schema_id),
        value: @TypeOf(value.input),
        disposition: enum { queued, acquired, consumed, not_consumed },
        occurrence: ?[32]u8,
    };
    const bytes = (try namespace.store.recordBytes(a, "message", message_id, value.id)).?;
    var decoded = try protean.contracts.decodeOwned(Message, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(.consumed, decoded.value.disposition);
    decoded.value.disposition = .queued;
    decoded.value.occurrence = null;
    var requeued = value;
    requeued.messages.items = &.{message_id};
    const original_task_bytes = try namespace.store.taskBytes(a, value.id);
    try namespace.store.begin();
    defer namespace.store.rollback();
    const original_message = try namespace.store.putObject(bytes);
    const original_task = try namespace.store.putObject(original_task_bytes);
    const message = try namespace.store.putObject(try protean.contracts.encodeOwned(Message, a, decoded.value));
    const task = try namespace.store.putObject(try protean.contracts.encodeOwned(@TypeOf(value), a, requeued));
    // This witness changes lifecycle facts, not reference closure. Keep the
    // exact original dependencies so export reaches the lifecycle validator.
    namespace.store.invalidateIntegrity();
    for ([_]struct { old: @TypeOf(task), new: @TypeOf(task) }{ .{ .old = original_message, .new = message }, .{ .old = original_task, .new = task } }) |pair| {
        try namespace.store.database.run("INSERT OR IGNORE INTO dependencies SELECT ?,?,child,child_bytes FROM dependencies WHERE parent=?", &.{ .{ .blob = &pair.new.digest }, .{ .integer = @intCast(pair.new.bytes) }, .{ .blob = &pair.old.digest } });
    }
    try namespace.store.database.run("UPDATE records SET body=? WHERE kind='message' AND id=?", &.{ .{ .blob = &message.digest }, .{ .blob = &message_id } });
    try namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{ .blob = &task.digest }, .{ .blob = &value.id } });
    // Export intentionally requires a settled transaction. Commit the synthetic
    // corruption, then restore the exact original references after the check.
    try namespace.commit("test.requeued-history");
    defer {
        namespace.store.begin() catch unreachable;
        namespace.store.invalidateIntegrity();
        namespace.store.database.run("UPDATE records SET body=? WHERE kind='message' AND id=?", &.{ .{ .blob = &original_message.digest }, .{ .blob = &message_id } }) catch unreachable;
        namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{ .blob = &original_task.digest }, .{ .blob = &value.id } }) catch unreachable;
        namespace.commit("test.restore-consumed-history") catch unreachable;
    }
    try std.testing.expectError(error.InvalidArchive, service.exportCheckpoint(a, value.id, path));
}

fn ownerRecovery(captured: bool, image: []const u8) !void {
    var phase: []const u8 = "owner admission/restart";
    errdefer std.debug.print("owner recovery phase: {s}\n", .{phase});
    const a = std.testing.allocator;
    const io = std.testing.io;
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(a, image, admitted_image.identity(), "owner-unit-test");
    defer a.free(manifest);
    const assets: native.discovery.Assets = .{ .image = image, .application = "owner-unit-test", .manifest = manifest };
    // Asset/discovery admission is independently tested by the subprocess peer.
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var increment_declaration = native.leaf(u32, u32, .{ .identity = "task-owner.increment.v1", .resource_role = "local" }, increment);
    if (captured) {
        increment_declaration.background = true;
        increment_declaration.capture = .{ .prepare = CapturingIncrement.prepare, .acquire = CapturingIncrement.invoke, .interpret = CapturingIncrement.interpret, .dependencies = native.registry.opaqueProjection };
        increment_declaration.invoke = null;
    }
    var handlers = try native.Registry.init(a, &.{
        increment_declaration,
        native.question(u32, u32, .{ .identity = "task-owner.question.v1", .resource_role = "user", .answer_schema_id = "task-owner.answer.v1" }, present),
        native.inbox.declaration(u32),
    });
    defer handlers.deinit();
    var grants: [3]native.registry.Grant = undefined;
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = application.image_identity };
    var configured: u32 = 37;
    const resource_set: [65][]const u8 = @splat("immutable snapshot bytes");
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "fixed-profile", .environment = &configured, .resources = &resource_set, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    const oversized_resources: [66][]const u8 = @splat("immutable snapshot bytes");
    var oversized_profile = profile;
    oversized_profile.resources = &oversized_resources;
    try std.testing.expect(!std.mem.eql(u8, &(try profile.resourceIdentity(a, application.image_identity)), &(try oversized_profile.resourceIdentity(a, application.image_identity))));
    for (&grants) |*grant| grant.resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(T).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const accepted = try service.submit(frame, "submit", 20);
    const duplicate = try service.submit(frame, "submit", 20);
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualSlices(u8, &accepted.receipt.task, &duplicate.receipt.task);
    try std.testing.expectError(error.OperationConflict, service.submit(frame, "submit", 21));
    // Queuing typed input does not execute under the current launch profile.
    // A compatible application can accept it before restoring the task profile.
    service.profile.bytes = "another launch profile";
    const queued_message = try service.message(frame, "message", accepted.receipt.task, 9);
    service.profile.bytes = profile.bytes;
    var calls: usize = 0;
    var retried = false;
    for (0..32) |_| {
        const step = try service.pump(frame);
        if (step == .work) {
            const ctx: native.Context = .{ .allocator = frame, .io = io, .authority = &profile.authority, .task_id = "test", .profile = profile.bytes, .environment = profile.environment };
            if (captured and !retried) {
                try service.notSent(frame, step.work);
                const archive_path = try std.fmt.allocPrint(frame, "{s}/not-sent.bundle", .{path_buffer[0..length]});
                _ = try service.exportCheckpoint(frame, accepted.receipt.task, archive_path);
                var stopped = try service.task(frame, accepted.receipt.task);
                defer stopped.deinit();
                _ = try service.resumeTask(frame, "retry-not-sent", accepted.receipt.task, stopped.value.revision);
                retried = true;
                continue;
            }
            var request = try protocol.decode(protocol.Request, frame, step.work.request);
            defer request.deinit();
            const reply = if (step.work.entry.declaration.capture) |adapter| (try adapter.acquire(ctx, step.work.prepared.?)).captured else try step.work.entry.declaration.invoke.?(ctx, request.value.binding.payload);
            calls += 1;
            try service.acquire(frame, step.work, reply);
            if (captured) {
                const saved = (try namespace.store.recordBytes(frame, "capture", step.work.attempt, step.work.task)) orelse return error.MissingRawCapture;
                try std.testing.expect(saved.len != 0);
            }
            break;
        }
    }
    try std.testing.expectEqual(1, calls);
    try std.testing.expectEqual(@as(u32, if (captured) 2 else 1), try namespace.store.capabilityAttempts(accepted.receipt.task, "task-owner.increment.v1"));
    try std.testing.expectEqual(@as(u32, 0), try namespace.store.capabilityAttempts(accepted.receipt.task, "another-capability"));
    // Restart at durable acquisition, before Kosmos consumes the reply.
    try service.close(frame);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    try std.testing.expectEqual(@as(u32, if (captured) 2 else 1), try namespace.store.capabilityAttempts(accepted.receipt.task, "task-owner.increment.v1"));
    // Both fixtures preserve the exact image and value types. Independently
    // changing either nominal application or message identity must still reject
    // new input, while retaining access to the old task and its queued message.
    inline for (.{ MessageContract("another-application", T.message_schema_id), MessageContract(T.application_id, "another-message-schema") }) |Other| {
        var other = try native.tasks.Service(Other).init(a, io, &namespace, assets, &application, handlers, profile);
        defer other.close(frame) catch unreachable;
        var visible = try other.task(frame, accepted.receipt.task);
        defer visible.deinit();
        try std.testing.expectEqual(1, visible.value.messages.items.len);
        const generation = namespace.store.head.generation;
        try std.testing.expectError(error.IncompatibleProfile, other.message(frame, "foreign-message", accepted.receipt.task, 10));
        try std.testing.expectEqual(generation, namespace.store.head.generation);
    }
    service = try native.tasks.Service(T).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    const frozen = try service.frozenInputs(frame, accepted.receipt.task);
    try std.testing.expectEqual(65, frozen.resources.len);
    try std.testing.expectEqualStrings(profile.bytes, frozen.profile);
    try std.testing.expectEqualStrings(profile.resources[0], frozen.resources[0]);
    try std.testing.expect(try service.pump(frame) == .idle);
    var status = try service.task(frame, accepted.receipt.task);
    defer status.deinit();
    service.profile.runtime_identity = @splat(43);
    try std.testing.expectError(error.IncompatibleProfile, service.resumeTask(frame, "resume", accepted.receipt.task, status.value.revision));
    service.profile.runtime_identity = profile.runtime_identity;
    service.profile.resources = &.{"changed snapshot bytes"};
    try std.testing.expectError(error.IncompatibleProfile, service.resumeTask(frame, "resume", accepted.receipt.task, status.value.revision));
    service.profile.resources = profile.resources;
    _ = try service.resumeTask(frame, "resume", accepted.receipt.task, status.value.revision);
    if (captured) {
        // Recover/interpret the raw acquisition, then test the settled boundary
        // before Kosmos consumes it, using the non-inference adapter fixture.
        try std.testing.expect(try service.pump(frame) == .progressed);
        try checkCaptureImport(a, frame, io, &service, &namespace, &service_live, &namespace_live, path, path_buffer[0..length], accepted.receipt.task, "settled-capture");
    }
    for (0..32) |_| {
        const step = try service.pump(frame);
        try std.testing.expect(step != .work);
        if (step == .waiting) break;
    }
    if (captured) {
        try checkCaptureImport(a, frame, io, &service, &namespace, &service_live, &namespace_live, path, path_buffer[0..length], accepted.receipt.task, "historical-capture");
    }
    var question = (try service.pendingQuestion(frame, accepted.receipt.task)) orelse return error.ExpectedQuestion;
    defer question.deinit();
    try std.testing.expectError(error.StaleInteraction, service.respond(frame, "unknown-question", accepted.receipt.task, @splat(0), question.value.revision, question.value.request_digest, "task-owner.answer.v1", .{ .number_string = "7" }));
    const answered = try service.respond(frame, "answer", accepted.receipt.task, question.value.id, question.value.revision, question.value.request_digest, "task-owner.answer.v1", .{ .number_string = "7" });
    try std.testing.expect(!answered.replayed);
    var imported_inbox = false;
    var checked_consumed_history = false;
    var queue_client: native.client.Client(T) = .{ .service = &service };
    var queue_params = native.json.object();
    try native.json.put(frame, &queue_params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(accepted.receipt.task, .lower))));
    for (0..32) |_| {
        const step = try service.pump(frame);
        try std.testing.expect(step != .work);
        if (!imported_inbox) {
            const queue = (try queue_client.call(frame, .@"task.status", queue_params)).object.get("pending_messages").?.array.items;
            if (queue.len != 0 and std.mem.eql(u8, queue[0].object.get("disposition").?.string, "acquired")) {
                phase = "export acquired inbox";
                const archive_path = try std.fmt.allocPrint(frame, "{s}/acquired-inbox.bundle", .{path_buffer[0..length]});
                _ = try service.exportCheckpoint(frame, accepted.receipt.task, archive_path);
                const imported_path = try std.fmt.allocPrint(frame, "{s}/imported-inbox", .{path_buffer[0..length]});
                // The native SQLite heap admits one connection per process.
                // Park and close the source before opening the copied state.
                try service.close(frame);
                service_live = false;
                try namespace.close();
                namespace_live = false;
                {
                    phase = "open acquired inbox destination";
                    var imported_namespace = try native.Namespace.open(a, io, imported_path);
                    defer imported_namespace.close() catch unreachable;
                    var imported_service = try native.tasks.Service(T).init(a, io, &imported_namespace, assets, &application, handlers, profile);
                    defer imported_service.close(frame) catch unreachable;
                    phase = "import acquired inbox";
                    const imported = try imported_service.importCheckpoint(frame, "import-acquired", archive_path);
                    var saved = try imported_service.task(frame, imported.receipt.task);
                    defer saved.deinit();
                    phase = "resume acquired inbox";
                    try std.testing.expectError(error.CustodyNotLocal, imported_service.resumeTask(frame, "resume-imported", imported.receipt.task, saved.value.revision));
                    try std.testing.expectEqual(.idle, try imported_service.pump(frame));
                    var copied_message = try protean.contracts.decodeOwned(native.testing.state.Message, frame, (try imported_namespace.store.recordBytes(frame, "message", queued_message.receipt.message.?, imported.receipt.task)).?);
                    defer copied_message.deinit();
                    try std.testing.expectEqual(.acquired, copied_message.value.disposition);
                }
                phase = "reopen original owner";
                namespace = try native.Namespace.open(a, io, path);
                namespace_live = true;
                service = try native.tasks.Service(T).init(a, io, &namespace, assets, &application, handlers, profile);
                service_live = true;
                var parked = try service.task(frame, accepted.receipt.task);
                defer parked.deinit();
                _ = try service.resumeTask(frame, "resume-after-inbox-export", accepted.receipt.task, parked.value.revision);
                imported_inbox = true;
                phase = "finish original owner";
            }
        }
        if (!checked_consumed_history) {
            var saved = try service.task(frame, accepted.receipt.task);
            defer saved.deinit();
            if (saved.value.outcome_kind == .yielded) {
                try rejectRequeuedHistory(frame, &service, &namespace, saved.value, queued_message.receipt.message.?, path_buffer[0..length]);
                checked_consumed_history = true;
            }
        }
        if (step == .idle) break;
    }
    try std.testing.expect(checked_consumed_history);
    try std.testing.expect(imported_inbox);
    try std.testing.expectEqual(captured, retried);
    var completed = try service.task(frame, accepted.receipt.task);
    defer completed.deinit();
    try std.testing.expect(completed.value.terminal());
    const result = try namespace.store.object(frame, completed.value.result.?, 128 * 1024);
    var decoded = try protean.contracts.decodeOwned(T.Output, frame, result);
    defer decoded.deinit();
    try std.testing.expectEqual(7, decoded.value.answer);
    try std.testing.expect(decoded.value.inbox == .message);
    try std.testing.expectEqual(9, decoded.value.inbox.message.value);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(queued_message.receipt.message.?, .lower), decoded.value.inbox.message.id.bytes);
    const replayed_answer = try service.respond(frame, "answer", accepted.receipt.task, question.value.id, question.value.revision, question.value.request_digest, "task-owner.answer.v1", .{ .number_string = "7" });
    try std.testing.expect(replayed_answer.replayed);
    try std.testing.expectEqualSlices(u8, &answered.receipt.id, &replayed_answer.receipt.id);
    try std.testing.expectError(error.AnswerConflict, service.respond(frame, "answer-conflict", accepted.receipt.task, question.value.id, question.value.revision, question.value.request_digest, "task-owner.answer.v1", .{ .number_string = "8" }));
    try std.testing.expect((try service.submit(frame, "submit", 20)).replayed);
    service.profile.bytes = "changed alias target";
    try std.testing.expect((try service.submit(frame, "submit", 20)).replayed);
    service.profile.bytes = profile.bytes;
    try std.testing.expectError(error.OperationConflict, service.requestCancel(frame, "submit", accepted.receipt.task, "cancel"));
    var client: native.client.Client(T) = .{ .service = &service };
    var params = native.json.object();
    try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(accepted.receipt.task, .lower))));
    const public_result = try client.call(frame, .@"task.result", params);
    try std.testing.expect(public_result.object.get("ready").?.bool);
    try std.testing.expectEqualStrings("completed", public_result.object.get("status").?.string);
    const public_outcome = public_result.object.get("outcome").?;
    try std.testing.expect(public_outcome.object.get("value") == null);
    const result_reference = public_outcome.object.get("value_ref").?;
    var read_params = native.json.object();
    try native.json.put(frame, &read_params, "task_id", params.object.get("task_id").?);
    try native.json.put(frame, &read_params, "artifact_id", result_reference.object.get("artifact_id").?);
    try native.json.put(frame, &read_params, "length", native.json.string("32768"));
    var reconstructed: std.array_list.Managed(u8) = .init(frame);
    while (true) {
        try native.json.put(frame, &read_params, "offset", native.json.string(try std.fmt.allocPrint(frame, "{d}", .{reconstructed.items.len})));
        const chunk = try client.call(frame, .@"artifact.read", read_params);
        const encoded = chunk.object.get("data").?.string;
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const bytes = try frame.alloc(u8, try decoder.calcSizeForSlice(encoded));
        try decoder.decode(bytes, encoded);
        try std.testing.expect(bytes.len > 0);
        try reconstructed.appendSlice(bytes);
        try std.testing.expect(reconstructed.items.len <= 128 * 1024);
        if (chunk.object.get("eof").?.bool) break;
    }
    try std.testing.expectEqualSlices(u8, try native.json.canonical(frame, try native.values.toJson(T.Output, frame, decoded.value)), reconstructed.items);
    if (!captured) try largeArtifactBatch(&service, accepted.receipt.task);
    const events = try client.events(frame, accepted.receipt.task, 0, 128);
    const history = events.object.get("events").?.array.items;
    var consumed: usize = 0;
    var completed_events: usize = 0;
    for (history) |event| {
        const kind = event.object.get("type").?.string;
        if (std.mem.eql(u8, kind, "message_consumed")) consumed += 1;
        if (std.mem.eql(u8, kind, "completed")) completed_events += 1;
    }
    try std.testing.expectEqual(1, consumed);
    try std.testing.expectEqual(1, completed_events);
    try std.testing.expectError(error.InvalidParams, client.events(frame, accepted.receipt.task, completed.value.event_high + 1, 128));
    service.profile.authority.disclosure = false;
    try std.testing.expectError(error.Denied, client.call(frame, .@"task.result", params));
    try std.testing.expectError(error.Denied, client.call(frame, .@"artifact.read", read_params));
    _ = read_params.object.swapRemove("task_id");
    try std.testing.expectError(error.Denied, client.call(frame, .@"artifact.read", read_params));
    try std.testing.expectError(error.Denied, service.submit(frame, "submit", 20));
    service.profile.authority.disclosure = true;
    const no_send = try service.submit(frame, "no-send", 20);
    var dispatched: ?native.tasks.Work = null;
    for (0..32) |_| {
        const step = try service.pump(frame);
        if (step == .work) {
            dispatched = step.work;
            break;
        }
    }
    try std.testing.expect(dispatched != null);
    try service.notSent(frame, dispatched.?);
    _ = try service.message(frame, "message-before-cancel", no_send.receipt.task, 11);
    {
        for (0..16) |i| _ = try service.message(frame, try std.fmt.allocPrint(frame, "queued-beyond-old-limit-{d}", .{i}), no_send.receipt.task, @intCast(i));
        var overflow_queue_params = native.json.object();
        try native.json.put(frame, &overflow_queue_params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(no_send.receipt.task, .lower))));
        const queue_status = try client.call(frame, .@"task.status", overflow_queue_params);
        try std.testing.expectEqualStrings("17", queue_status.object.get("pending_message_count").?.string);
        try std.testing.expectEqual(16, queue_status.object.get("pending_messages").?.array.items.len);
        try std.testing.expect(queue_status.object.get("pending_messages_truncated").?.bool);
        const queued_history = try client.events(frame, no_send.receipt.task, 0, 128);
        var queue_events: usize = 0;
        for (queued_history.object.get("events").?.array.items) |event| {
            if (std.mem.eql(u8, event.object.get("type").?.string, "message_queued")) queue_events += 1;
        }
        try std.testing.expectEqual(17, queue_events);
    }
    _ = try service.requestCancel(frame, "cancel-no-send", no_send.receipt.task, "stop before invocation");
    for (0..32) |_| {
        const step = try service.pump(frame);
        try std.testing.expect(step != .work);
        if (step == .idle) break;
    }
    var cancelled = try service.task(frame, no_send.receipt.task);
    defer cancelled.deinit();
    try std.testing.expectEqual(.cancelled, cancelled.value.outcome_kind);
    const cancelled_archive = try std.fmt.allocPrint(frame, "{s}/not-consumed.bundle", .{path_buffer[0..length]});
    _ = try service.exportCheckpoint(frame, no_send.receipt.task, cancelled_archive);
    const omitted_message = try std.fmt.allocPrint(frame, "{s}/not-consumed-omitted.bundle", .{path_buffer[0..length]});
    const cancelled_shape = try namespace.store.archiveIndex(frame, no_send.receipt.task, .{ .digest = @splat(0), .bytes = 0 });
    try omitArchiveFact(frame, io, cancelled_shape, cancelled.value, cancelled_archive, omitted_message, .message_not_consumed);
    try service.close(frame);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    {
        const target = try std.fmt.allocPrint(frame, "{s}/not-consumed-import", .{path_buffer[0..length]});
        var destination = try native.Namespace.open(a, io, target);
        defer destination.close() catch unreachable;
        var imported = try native.tasks.Service(T).init(a, io, &destination, assets, &application, handlers, profile);
        defer imported.close(frame) catch unreachable;
        try std.testing.expectError(error.InvalidArchive, imported.importCheckpoint(frame, "import-settlement", omitted_message));
        const admitted = try imported.importCheckpoint(frame, "import-settlement", cancelled_archive);
        try std.testing.expectEqualSlices(u8, &no_send.receipt.task, &admitted.receipt.task);
    }
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    service = try native.tasks.Service(T).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;

    if (captured) {
        const uninterpretable = try service.submit(frame, "uninterpretable-capture", 20);
        var captured_work: ?native.tasks.Work = null;
        for (0..32) |_| {
            const step = try service.pump(frame);
            if (step == .work) {
                captured_work = step.work;
                break;
            }
        }
        try std.testing.expect(captured_work != null);
        const invalid_raw = "captured bytes that cannot be interpreted";
        const capture_id = captured_work.?.attempt;
        try service.acquire(frame, captured_work.?, invalid_raw);
        const interpretations = CapturingIncrement.interpretations;
        try service.close(frame);
        service_live = false;
        try namespace.close();
        namespace_live = false;
        namespace = try native.Namespace.open(a, io, path);
        namespace_live = true;
        service = try native.tasks.Service(T).init(a, io, &namespace, assets, &application, handlers, profile);
        service_live = true;
        try std.testing.expectEqual(interpretations, CapturingIncrement.interpretations);
        var pending_capture = try service.task(frame, uninterpretable.receipt.task);
        defer pending_capture.deinit();
        _ = try service.resumeTask(frame, "interpret-retained-capture", uninterpretable.receipt.task, pending_capture.value.revision);
        try std.testing.expect(try service.pump(frame) == .waiting);
        const saved_capture = (try namespace.store.recordBytes(frame, "capture", capture_id, uninterpretable.receipt.task)).?;
        const Ref = @TypeOf(pending_capture.value.profile);
        const Captured = struct {
            task: [16]u8,
            occurrence: [32]u8,
            attempt: [32]u8,
            request: Ref,
            response: ?Ref,
            disposition: enum { complete, definitely_not_sent, unknown },
            projection: ?struct { reply: Ref, objects: protean.contracts.Vector(Ref, null), output_tokens: ?u64 },
            reconciliation: ?[32]u8,
        };
        var decoded_capture = try protean.contracts.decodeOwned(Captured, frame, saved_capture);
        defer decoded_capture.deinit();
        try std.testing.expect(decoded_capture.value.projection == null);
        try std.testing.expectEqualStrings(invalid_raw, try namespace.store.object(frame, decoded_capture.value.response.?, null));
        _ = try namespace.store.auditRetention(handlers, application.image_identity);
        try std.testing.expect(!namespace.store.fenced);

        const failing = try service.submit(frame, "capture-publication-failure", 20);
        var pending: ?native.tasks.Work = null;
        for (0..32) |_| {
            const step = try service.pump(frame);
            if (step == .work) {
                pending = step.work;
                break;
            }
        }
        try std.testing.expect(pending != null);
        // Freeze the actual database at its current page count. A large raw
        // response needs more pages and must fail before it is acknowledged.
        try namespace.store.database.exec("PRAGMA max_page_count=1;");
        const raw = try frame.alloc(u8, 1024 * 1024);
        @memset(raw, 0x5a);
        try std.testing.expectError(error.Capacity, service.acquire(frame, pending.?, raw));
        try std.testing.expect(namespace.store.fenced);
        try service.close(frame);
        service_live = false;
        try namespace.close();
        namespace_live = false;
        namespace = try native.Namespace.open(a, io, path);
        namespace_live = true;
        service = try native.tasks.Service(T).init(a, io, &namespace, assets, &application, handlers, profile);
        service_live = true;
        var unknown = try service.task(frame, failing.receipt.task);
        defer unknown.deinit();
        try std.testing.expectEqual(.unknown, try service.status(frame, unknown.value));
        try std.testing.expectError(error.UnsettledOccurrence, service.resumeTask(frame, "must-not-reissue", failing.receipt.task, unknown.value.revision));
        try std.testing.expectEqual(1, try namespace.store.capabilityAttempts(failing.receipt.task, "task-owner.increment.v1"));
    }
    if (!captured) {
        try questionReferenceWitness(frame, &service);
        // Exercise the stored-event projection's byte domain without another
        // application image. Lifecycle production is exercised above; these
        // schema-shaped historical rows isolate pagination and batch framing.
        var large_data = found: {
            for (history) |event| {
                if (std.mem.eql(u8, event.object.get("type").?.string, "input_required")) break :found event.object.get("data").?;
            }
            return error.ExpectedQuestion;
        };
        const prompt = try frame.alloc(u8, 32 * 1024 - 2);
        @memset(prompt, 'q');
        try native.json.put(frame, &large_data, "prompt", native.json.string(prompt));
        const event_data = try native.json.canonical(frame, large_data);
        var paged = completed.value;
        paged.revision += 1;
        try namespace.store.begin();
        defer namespace.store.rollback();
        for (0..40) |_| {
            paged.event_high += 1;
            try namespace.store.putEvent(.{ .task = paged.id, .seq = paged.event_high, .revision = paged.revision, .kind = .input_required, .data = .{ .bytes = event_data } });
        }
        try namespace.store.putTask(paged, completed.value.revision);
        try namespace.commit("pagination-domain");
        var cursor = completed.value.event_high;
        var seen: usize = 0;
        while (cursor < paged.event_high) {
            var page_arena = std.heap.ArenaAllocator.init(a);
            defer page_arena.deinit();
            const pa = page_arena.allocator();
            const page = try client.events(pa, paged.id, cursor, 128);
            const next = try native.json.decimal(u64, page.object.get("next_after_seq").?);
            try std.testing.expect(next > cursor);
            seen += page.object.get("events").?.array.items.len;
            var batch: native.json.Value = .{ .array = .init(pa) };
            var id: [128]u8 = @splat(1); // maximum-length, heavily escaped IDs
            for (0..16) |index| {
                id[0] = @intCast(index + 32);
                try batch.array.append(try native.protocol.response(pa, native.json.string(try pa.dupe(u8, &id)), page));
            }
            try std.testing.expect((try native.json.canonical(pa, batch)).len + 1 <= 1024 * 1024);
            cursor = next;
        }
        try std.testing.expectEqual(40, seen);
    }
}

fn questionReferenceWitness(a: std.mem.Allocator, service: *native.tasks.Service(T)) !void {
    var client: native.client.Client(T) = .{ .service = service, .batch = true };
    for ([_]u32{ 41, 42, 43 }) |input| {
        const admitted = try service.submit(a, try std.fmt.allocPrint(a, "question-ref-{d}", .{input}), input);
        var calls: usize = 0;
        for (0..16) |_| {
            const step = try service.pump(a);
            if (step == .work) {
                var request = try protocol.decode(protocol.Request, a, step.work.request);
                defer request.deinit();
                const ctx: native.Context = .{ .allocator = a, .io = service.io, .authority = &service.profile.authority, .task_id = "test", .profile = service.profile.bytes, .environment = service.profile.environment };
                const reply = try step.work.entry.declaration.invoke.?(ctx, request.value.binding.payload);
                try service.acquire(a, step.work, reply);
                calls += 1;
            }
            if (step == .waiting or step == .idle) break;
        }
        try std.testing.expectEqual(1, calls);
        var saved = (try service.pendingQuestion(a, admitted.receipt.task)) orelse return error.ExpectedQuestion;
        defer saved.deinit();
        var params = native.json.object();
        try native.json.put(a, &params, "task_id", native.json.string(try a.dupe(u8, &std.fmt.bytesToHex(admitted.receipt.task, .lower))));
        const status = try client.call(a, .@"task.status", params);
        const question = status.object.get("question").?;
        try std.testing.expect(question.object.get("prompt") == null);
        const ref = question.object.get("prompt_ref").?;
        const page = try client.events(a, admitted.receipt.task, 0, 128);
        var found = false;
        for (page.object.get("events").?.array.items) |event| {
            if (!std.mem.eql(u8, event.object.get("type").?.string, "input_required")) continue;
            found = true;
            const data_value = event.object.get("data").?;
            try std.testing.expect(data_value.object.get("prompt") == null);
            try std.testing.expectEqualStrings(try native.json.canonical(a, ref), try native.json.canonical(a, data_value.object.get("prompt_ref").?));
        }
        try std.testing.expect(found);
        try std.testing.expect(!page.object.get("has_more").?.bool);
        var subscribed: native.client.Client(T) = .{ .service = service };
        subscribed.subscriptions[0] = .{ .id = @splat(9), .task = admitted.receipt.task, .after = 0 };
        var notified = false;
        while (try subscribed.notification(a)) |notification| {
            _ = try native.json.parse(a, try native.json.frame(a, notification), .{});
            const event = notification.object.get("params").?.object.get("event").?;
            if (std.mem.eql(u8, event.object.get("type").?.string, "input_required")) {
                notified = true;
                try std.testing.expectEqualStrings(try native.json.canonical(a, ref), try native.json.canonical(a, event.object.get("data").?.object.get("prompt_ref").?));
            }
        }
        try std.testing.expect(notified);
        var replies: native.json.Value = .{ .array = .init(a) };
        for (0..16) |i| try replies.array.append(try native.protocol.response(a, try native.json.number(a, i), if (i % 2 == 0) status else page));
        _ = try native.json.parse(a, try native.json.frame(a, replies), .{});
        try native.json.put(a, &params, "artifact_id", ref.object.get("artifact_id").?);
        try native.json.put(a, &params, "question_id", ref.object.get("question_id").?);
        try native.json.put(a, &params, "offset", native.json.string("0"));
        try native.json.put(a, &params, "length", native.json.string("32768"));
        var decoded: std.ArrayList(u8) = .empty;
        var chunks: usize = 0;
        while (true) {
            const chunk = try client.call(a, .@"artifact.read", params);
            const text = chunk.object.get("data").?.string;
            const bytes = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text));
            try std.base64.url_safe_no_pad.Decoder.decode(bytes, text);
            try decoded.appendSlice(a, bytes);
            chunks += 1;
            if (chunk.object.get("eof").?.bool) break;
            try native.json.put(a, &params, "offset", chunk.object.get("next_offset").?);
        }
        try std.testing.expectEqual(@as(usize, if (input == 43) 5 else 1), chunks);
        // Build expected bytes independently of the JSON encoder/projection.
        const expected = try a.alloc(u8, if (input == 41) 20_001 else if (input == 42) 68 else 128 * 1024 + 2);
        if (input == 41) {
            expected[0] = '[';
            for (0..10_000) |i| {
                expected[1 + i * 2] = '0';
                expected[2 + i * 2] = if (i == 9999) ']' else ',';
            }
        } else if (input == 42) {
            @memset(expected[0..32], '[');
            @memcpy(expected[32..36], "null");
            @memset(expected[36..], ']');
        } else {
            expected[0] = '"';
            @memset(expected[1 .. expected.len - 1], 'q');
            expected[expected.len - 1] = '"';
        }
        try std.testing.expectEqualSlices(u8, expected, decoded.items);
        try native.json.put(a, &params, "artifact_id", native.json.string(try a.dupe(u8, &std.fmt.bytesToHex(saved.value.request.digest, .lower))));
        try std.testing.expectError(error.ArtifactUnavailable, client.call(a, .@"artifact.read", params));
        try native.json.put(a, &params, "artifact_id", ref.object.get("artifact_id").?);
        _ = params.object.swapRemove("question_id");
        try std.testing.expectError(error.ArtifactUnavailable, client.call(a, .@"artifact.read", params));
        _ = try service.requestCancel(a, try std.fmt.allocPrint(a, "question-ref-cancel-{d}", .{input}), admitted.receipt.task, "finished witness");
        for (0..16) |_| {
            const step = try service.pump(a);
            try std.testing.expect(step != .work);
            if (step == .idle) break;
        }
    }
}

fn largeArtifactBatch(service: *native.tasks.Service(T), task_id: [16]u8) !void {
    const a = std.testing.allocator;
    const store = &service.namespace.store;
    const bytes = try a.alloc(u8, 3 * 1024 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'x');
    bytes[0] = '"';
    bytes[bytes.len - 1] = '"';
    const id: [32]u8 = @splat(173);
    // Isolate the reader's allocation domain with an independently encoded
    // synthetic publication. Real authored large results are qualified below.
    var task = try service.task(a, task_id);
    defer task.deinit();
    const original_task = try store.taskBytes(a, task_id);
    defer a.free(original_task);
    try store.begin();
    defer store.rollback();
    const reference = try store.putObject(bytes);
    const original_reference = try store.putObject(original_task);
    const Artifact = struct {
        id: [32]u8,
        task: ?[16]u8,
        value: @TypeOf(reference),
        media_type: protean.contracts.Text(128),
        schema_id: ?protean.contracts.Text(128),
    };
    const encoded = try protean.contracts.encodeOwned(Artifact, a, .{ .id = id, .task = task_id, .value = reference, .media_type = .{ .bytes = "application/json" }, .schema_id = .{ .bytes = "artifact-test.json.v1" } });
    defer a.free(encoded);
    const record = try store.putObject(encoded);
    store.invalidateIntegrity();
    try store.database.run("INSERT INTO records VALUES('artifact',?,?,?)", &.{ .{ .blob = &id }, .{ .blob = &task_id }, .{ .blob = &record.digest } });
    try service.namespace.commit("test.large-artifact");
    defer {
        store.begin() catch unreachable;
        store.invalidateIntegrity();
        store.database.run("DELETE FROM records WHERE kind='artifact' AND id=? AND task=?", &.{ .{ .blob = &id }, .{ .blob = &task_id } }) catch unreachable;
        store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{ .blob = &original_reference.digest }, .{ .blob = &task_id } }) catch unreachable;
        service.namespace.commit("test.remove-large-artifact") catch unreachable;
    }

    {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const frame = scratch.allocator();
        var client: native.client.Client(T) = .{ .service = service };
        var params = native.json.object();
        try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task_id, .lower))));
        try native.json.put(frame, &params, "artifact_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
        try native.json.put(frame, &params, "offset", native.json.string("0"));
        try native.json.put(frame, &params, "length", native.json.string("1"));
        try std.testing.expectError(error.ArtifactUnavailable, client.call(frame, .@"artifact.read", params));
        // A record alone is not publication. This fixture explicitly supplies
        // the task-owned public root, then restores the original after reading.
        var published = task.value;
        published.result_artifact = id;
        published.client_result = reference;
        const body = try protean.contracts.encodeOwned(@TypeOf(published), frame, published);
        try store.begin();
        defer store.rollback();
        const stored = try store.putObject(body);
        try store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{ .blob = &stored.digest }, .{ .blob = &task_id } });
        try service.namespace.commit("test.publish-large-artifact");
    }

    // Test-local allocation pressure proves bounded chunk reads. These bytes
    // are not a production SQLite, worker, or host heap policy.
    var budget: kosmos.AllocationBudget = .{ .parent = a, .limit = 64 * 1024 * 1024 };
    const bounded = budget.allocator();
    const reservation = try bounded.alloc(u8, 32 * 1024 * 1024);
    defer bounded.free(reservation);
    const original_allocator = service.allocator;
    service.allocator = bounded;
    defer service.allocator = original_allocator;
    var arena = std.heap.ArenaAllocator.init(bounded);
    defer arena.deinit();
    const frame = arena.allocator();
    var client: native.client.Client(T) = .{ .service = service, .batch = true };
    var responses: std.array_list.Managed(native.json.Value) = .init(frame);
    for (0..16) |i| {
        var params = native.json.object();
        try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task_id, .lower))));
        try native.json.put(frame, &params, "artifact_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
        try native.json.put(frame, &params, "offset", native.json.string(try std.fmt.allocPrint(frame, "{d}", .{i * 32768})));
        try native.json.put(frame, &params, "length", native.json.string("32768"));
        const chunk = try client.call(frame, .@"artifact.read", params);
        var decoded: [32768]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(&decoded, chunk.object.get("data").?.string);
        try std.testing.expectEqualSlices(u8, bytes[i * 32768 ..][0..32768], &decoded);
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(reference.digest, .lower), chunk.object.get("sha256").?.string);
        try std.testing.expectEqual((i + 1) * 32768, try native.json.decimal(usize, chunk.object.get("next_offset").?));
        try std.testing.expectEqual(bytes.len, try native.json.decimal(usize, chunk.object.get("total_bytes").?));
        try std.testing.expect(!chunk.object.get("eof").?.bool);
        try responses.append(try native.protocol.response(frame, try native.json.number(frame, i), chunk));
    }
    const wire = try native.json.canonical(frame, .{ .array = responses });
    try std.testing.expect(wire.len + 1 <= (native.protocol.Limits{}).frame_bytes);
    try std.testing.expect(!budget.failed);
    try std.testing.expect(budget.peak < 48 * 1024 * 1024);
}

test "an inbox identity cannot be redeclared with a different message contract" {
    const a = std.testing.allocator;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    var registry = protean.admission.Registry.init(a);
    defer registry.deinit();
    const ctx = try protean.Context.init(&b, &registry);
    try std.testing.expectEqual(try horos_authoring.interop.operationId(ctx.author, try Inbox.declare(ctx)), try horos_authoring.interop.operationId(ctx.author, try Inbox.declare(ctx)));
    try std.testing.expectError(error.InvalidInboxContract, protean.inbox.Profile(u64).declare(ctx));
}

fn LargeResultContract(comptime escaped: bool) type {
    return struct {
        pub const application_id = "large-result-test";
        pub const input_schema_id = "large-result.input.v1";
        pub const output_schema_id = "large-result.output.v1";
        pub const failure_schema_id = "large-result.failure.v1";
        pub const message_schema_id = "large-result.message.v1";
        pub const Input = bool;
        pub const Output = if (escaped) protean.contracts.Text(1024 * 1024) else protean.contracts.Bytes(1024 * 1024);
        pub const Failure = Output;
        pub const Message = void;
        pub const escaped_text = escaped;
        pub const payload = @as([900 * 1024]u8, @splat(if (escaped) 0 else 'x'));
    };
}
fn LargeResultProgram(comptime Types: type) type {
    return struct {
        pub fn emit(c: protean.Context) !horos.source.Module {
            const b = c.builder;
            const bytes = try horos_authoring.interop.schemaId(c.author, try c.schema(Types.Output));
            const entry = try b.declare(&.{try horos_authoring.interop.schemaId(c.author, try c.schema(bool))}, bytes, &.{}, &.{});
            const payload = try horos_authoring.interop.valueId(c.author, try c.literal(Types.Output, if (@hasDecl(Types, "dense")) .{ .items = &Types.payload } else .{ .bytes = &Types.payload }));
            try b.define(entry, try b.term(.{ .conditional = .{
                .condition = try b.reference(b.parameter(entry, 0)),
                .when_true = try b.term(.{ .fail = payload }),
                .when_false = try b.pure(payload),
            } }));
            return b.module(entry, bytes);
        }
    };
}

test "large completed and failed result batches retain responses without payload scratch" {
    try largeResultWitness(LargeResultContract(false));
}

test "escaped terminal text survives publication reads restart and import within the host budget" {
    try largeResultWitness(LargeResultContract(true));
}

test "dense short results use exact references across batches restart and import" {
    const Dense = struct {
        pub const application_id = "dense-result-test";
        pub const input_schema_id = "dense-result.input.v1";
        pub const output_schema_id = "dense-result.output.v1";
        pub const failure_schema_id = "dense-result.failure.v1";
        pub const message_schema_id = "dense-result.message.v1";
        pub const Input = bool;
        pub const Output = protean.contracts.Vector(u8, 10_000);
        pub const Failure = Output;
        pub const Message = void;
        pub const escaped_text = false;
        pub const dense = true;
        pub const payload = @as([10_000]u8, @splat(0));
    };
    try largeResultWitness(Dense);
}

fn largeResultWitness(comptime Types: type) !void {
    const harness = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try protean.compile(harness, protean.system(.{ .InitialArgs = bool, .Result = Types.Output, .Failure = Types.Failure, .application = LargeResultProgram(Types) }));
    defer compiled.deinit();
    const image = try harness.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer harness.free(image);
    _ = try compiled.encode(harness, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(harness, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(harness, image, admitted_image.identity(), "large-result-test");
    defer harness.free(manifest);
    // Independent wire oracle: canonical base64url or one six-byte JSON escape per NUL.
    const dense = @hasDecl(Types, "dense");
    const encoded = try harness.alloc(u8, if (dense) Types.payload.len * 2 + 1 else (if (Types.escaped_text) Types.payload.len * 6 else std.base64.url_safe_no_pad.Encoder.calcSize(Types.payload.len)) + 2);
    defer harness.free(encoded);
    encoded[0] = '"';
    encoded[encoded.len - 1] = '"';
    if (dense) {
        encoded[0] = '[';
        for (0..Types.payload.len) |i| {
            encoded[1 + i * 2] = '0';
            encoded[2 + i * 2] = if (i + 1 == Types.payload.len) ']' else ',';
        }
        try std.testing.expect(encoded.len < 60 * 1024);
    } else if (Types.escaped_text) {
        for (0..Types.payload.len) |i| @memcpy(encoded[1 + i * 6 ..][0..6], "\\u0000");
        try std.testing.expect(encoded.len > 4 * 1024 * 1024);
    } else _ = std.base64.url_safe_no_pad.Encoder.encode(encoded[1 .. encoded.len - 1], &Types.payload);
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &expected_digest, .{});

    // Authoring/image bytes above model build-time work and embedded read-only
    // assets. All runtime owners below share the real 64MiB allocation budget.
    var budget: kosmos.AllocationBudget = .{ .parent = harness, .limit = 64 * 1024 * 1024 };
    errdefer std.debug.print("large-result memory: live={d} peak={d} required={d} limit={d}\n", .{ budget.live, budget.peak, budget.required, budget.limit });
    const a = budget.allocator();
    // SQLite is charged by Namespace.open. Reserve only the absent process
    // worker and input framer, then actually admit the large resource set.
    const process_reservation = try a.alloc(u8, 17 * 1024 * 1024);
    defer a.free(process_reservation);
    const resource = try a.alloc(u8, 16 * 1024 * 1024);
    defer a.free(resource);
    @memset(resource, 'r');
    const assets: native.discovery.Assets = .{ .image = image, .application = "large-result-test", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(43), .bytes = "large-result-profile", .resources = &.{resource}, .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(Types).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(a) catch unreachable;
    var ids: [2][16]u8 = undefined;
    var artifacts: [2][32]u8 = undefined;
    for (&ids, &artifacts, 0..) |*id, *artifact, index| {
        {
            var admission = std.heap.ArenaAllocator.init(a);
            defer admission.deinit();
            const submitted = try service.submit(admission.allocator(), if (index == 0) "complete" else "fail", index != 0);
            id.* = submitted.receipt.task;
        }
        {
            var advance = std.heap.ArenaAllocator.init(a);
            defer advance.deinit();
            try std.testing.expect(try service.pump(advance.allocator()) == .progressed);
        }
        var terminal = try service.task(a, id.*);
        defer terminal.deinit();
        const expected: @TypeOf(terminal.value.outcome_kind) = if (index == 0) .completed else .failed;
        try std.testing.expectEqual(expected, terminal.value.outcome_kind);
        try std.testing.expect(terminal.value.checkpoint.bytes <= 1024 * 1024);
        try std.testing.expect(terminal.value.result.?.bytes >= Types.payload.len);
        try std.testing.expectEqual(resource.len, terminal.value.resources.items[0].bytes);
        try std.testing.expectEqualSlices(u8, &expected_digest, &terminal.value.client_result.?.digest);
        try std.testing.expectEqual(encoded.len, terminal.value.client_result.?.bytes);
        if (dense) {
            try std.testing.expect(terminal.value.result_artifact == null);
            artifact.* = terminal.value.client_result.?.digest;
        } else artifact.* = terminal.value.result_artifact.?;
    }
    var client: native.client.Client(Types) = .{ .service = &service, .batch = true };
    {
        var responses_arena = std.heap.ArenaAllocator.init(a);
        defer responses_arena.deinit();
        const frame = responses_arena.allocator();
        const baseline = budget.live;
        var responses: std.array_list.Managed(native.json.Value) = .init(frame);
        for (0..32) |i| {
            const index = i % 2;
            var params = native.json.object();
            try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(ids[index], .lower))));
            const result = try client.call(frame, .@"task.result", params);
            try responses.append(try native.protocol.response(frame, try native.json.number(frame, i), result));
            try std.testing.expect(budget.live - baseline < 512 * 1024);
        }
        // Check every retained response after subsequent calls have reclaimed
        // and reused temporary storage, including both failure and success.
        for (responses.items, 0..) |response, i| {
            const index = i % 2;
            const result = response.object.get("result").?;
            try std.testing.expect(result.object.get("ready").?.bool);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(ids[index], .lower), result.object.get("task_id").?.string);
            const outcome = result.object.get("outcome").?;
            try std.testing.expectEqualStrings(if (index == 0) "completed" else "failed", outcome.object.get("type").?.string);
            try std.testing.expectEqualStrings(if (index == 0) Types.output_schema_id else Types.failure_schema_id, outcome.object.get("schema_id").?.string);
            try std.testing.expect(outcome.object.get("value") == null);
            const reference = outcome.object.get("value_ref").?;
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(artifacts[index], .lower), reference.object.get("artifact_id").?.string);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(expected_digest, .lower), reference.object.get("sha256").?.string);
            try std.testing.expectEqual(encoded.len, try native.json.decimal(usize, reference.object.get("bytes").?));
            if (index == 1) try std.testing.expect(outcome.object.get("cleanup_complete").?.bool);
        }
        try std.testing.expect((try native.json.canonical(frame, .{ .array = responses })).len + 1 <= (native.protocol.Limits{}).frame_bytes);
        _ = try native.json.parse(frame, try native.json.frame(frame, .{ .array = responses }), .{});
    }
    if (Types.escaped_text or dense) {
        // Reopen the actual persisted terminal tasks before reading/exporting.
        try service.close(a);
        service_live = false;
        try namespace.close();
        namespace_live = false;
        namespace = try native.Namespace.open(a, io, path);
        namespace_live = true;
        service = try native.tasks.Service(Types).init(a, io, &namespace, assets, &application, handlers, profile);
        service_live = true;
        for (ids, artifacts, 0..) |id, artifact, index| {
            try checkResultChunks(Types, a, &service, id, artifact, encoded, expected_digest);
            var export_arena = std.heap.ArenaAllocator.init(a);
            defer export_arena.deinit();
            const archive_path = try std.fmt.allocPrint(export_arena.allocator(), "{s}/result-{d}.bundle", .{ path_buffer[0..length], index });
            _ = try service.exportCheckpoint(export_arena.allocator(), id, archive_path);
        }
        try service.close(a);
        service_live = false;
        try namespace.close();
        namespace_live = false;
        for (ids, artifacts, 0..) |id, artifact, index| {
            var import_arena = std.heap.ArenaAllocator.init(a);
            defer import_arena.deinit();
            const scratch = import_arena.allocator();
            const archive_path = try std.fmt.allocPrint(scratch, "{s}/result-{d}.bundle", .{ path_buffer[0..length], index });
            const destination = try std.fmt.allocPrint(scratch, "{s}/imported-{d}", .{ path_buffer[0..length], index });
            var imported_namespace = try native.Namespace.open(a, io, destination);
            defer imported_namespace.close() catch unreachable;
            var imported_service = try native.tasks.Service(Types).init(a, io, &imported_namespace, assets, &application, handlers, profile);
            defer imported_service.close(a) catch unreachable;
            {
                var admission = std.heap.ArenaAllocator.init(a);
                defer admission.deinit();
                const receipt = try imported_service.importCheckpoint(admission.allocator(), "import-result", archive_path);
                try std.testing.expectEqualSlices(u8, &id, &receipt.receipt.task);
            }
            try checkResultChunks(Types, a, &imported_service, id, artifact, encoded, expected_digest);
        }
    }
    try std.testing.expect(!budget.failed);
    try std.testing.expect(budget.peak <= budget.limit);
}

fn checkResultChunks(comptime Types: type, a: std.mem.Allocator, service: *native.tasks.Service(Types), id: [16]u8, artifact: [32]u8, expected: []const u8, expected_digest: [32]u8) !void {
    var client: native.client.Client(Types) = .{ .service = service };
    var offset: usize = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = arena.allocator();
        var params = native.json.object();
        try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
        try native.json.put(frame, &params, "artifact_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(artifact, .lower))));
        try native.json.put(frame, &params, "offset", native.json.string(try std.fmt.allocPrint(frame, "{d}", .{offset})));
        try native.json.put(frame, &params, "length", native.json.string("32768"));
        const response = try client.call(frame, .@"artifact.read", params);
        const text = response.object.get("data").?.string;
        const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text);
        var decoded: [32768]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(decoded[0..size], text);
        try std.testing.expectEqualSlices(u8, expected[offset..][0..size], decoded[0..size]);
        offset += size;
        try std.testing.expectEqual(offset, try native.json.decimal(usize, response.object.get("next_offset").?));
        try std.testing.expectEqual(expected.len, try native.json.decimal(usize, response.object.get("total_bytes").?));
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(expected_digest, .lower), response.object.get("sha256").?.string);
        try std.testing.expect((try native.json.canonical(frame, response)).len + 1 <= (native.protocol.Limits{}).frame_bytes);
        if (response.object.get("eof").?.bool) break;
        try std.testing.expect(size != 0);
    }
    try std.testing.expectEqual(expected.len, offset);
}

const CleanupTypes = struct {
    pub const application_id = "cleanup-owner-test";
    pub const input_schema_id = "cleanup.input.v1";
    pub const output_schema_id = "cleanup.output.v1";
    pub const failure_schema_id = "cleanup.failure.v1";
    pub const message_schema_id = "cleanup.message.v1";
    pub const Input = bool;
    pub const Output = void;
    pub const Failure = void;
    pub const Message = void;
};
const CleanupApplication = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const unit = try horos_authoring.interop.schemaId(c.author, try c.schema(void));
        const boolean = try horos_authoring.interop.schemaId(c.author, try c.schema(bool));
        const entry = try b.declare(&.{boolean}, unit, &.{}, &.{});
        const body = try b.declare(&.{}, unit, &.{}, &.{});
        // Stop inside protect before selecting failure versus cancellation.
        try b.define(body, try b.term(.{ .yield_then = try b.term(.{ .fail = try b.constant(void, {}) }) }));
        const exit_info = try horos.library.cleanup.exitInfo(b, unit);
        const cleanup = try b.declare(&.{exit_info}, unit, &.{}, &.{});
        try b.define(cleanup, try b.term(.{ .yield_then = try b.term(.{ .conditional = .{
            .condition = try b.reference(b.parameter(entry, 0)),
            .when_true = try b.term(.{ .fail = try b.constant(void, {}) }),
            .when_false = try b.pure(try b.constant(void, {})),
        } }) }));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = unit, .effects = &.{} } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{exit_info}, .result = unit, .effects = &.{}, .capture_bound = &.{boolean} } } });
        try b.define(entry, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(cleanup, cleanup_type) } }));
        return b.module(entry, unit);
    }
};

test "applied cancellation awaits cleanup input without recreating runnable work" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Asking = struct {
        pub fn emit(c: protean.Context) !horos.source.Module {
            const b = c.builder;
            const number = try b.scalar(u32);
            const unit = try b.scalar(void);
            const question = try horos_authoring.interop.operationId(c.author, try c.external("fair.question.v1", try c.schema(u32), try c.schema(u32), .read));
            const entry = try b.declare(&.{number}, number, &.{question}, &.{});
            const body = try b.declare(&.{}, number, &.{question}, &.{});
            try b.define(body, try b.term(.{ .perform = .{ .effect = question, .payload = try b.constant(u32, 1) } }));
            const exit_info = try horos.library.cleanup.exitInfo(b, unit);
            const cleanup = try b.declare(&.{exit_info}, unit, &.{question}, &.{});
            const answer = try b.variable(number);
            try b.define(cleanup, try b.bind(answer, try b.term(.{ .perform = .{ .effect = question, .payload = try b.constant(u32, 2) } }), try b.pure(try b.constant(void, {}))));
            const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = number, .effects = &.{question} } } });
            const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{exit_info}, .result = unit, .effects = &.{question} } } });
            try b.define(entry, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(cleanup, cleanup_type) } }));
            return b.module(entry, unit);
        }
    };
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = Asking }));
    defer compiled.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const image = try frame.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const manifest = try ownerManifest(frame, image, admitted.identity(), "cleanup-question");
    const assets: native.discovery.Assets = .{ .image = image, .application = "cleanup-question", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var handlers = try native.Registry.init(a, &.{native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, FairCapture.present)});
    defer handlers.deinit();
    var grants: [1]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "cleanup-question-profile", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    grants[0] = .{ .identity = handlers.entries[0].declaration.identity, .resource_role = "user", .resource_identity = try profile.resourceIdentity(frame, application.image_identity) };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(frame, "{s}/state", .{path_buffer[0..length]});
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(frame) catch unreachable;
    const submitted = try service.submit(frame, "asking", 11);
    for (0..64) |_| {
        if (try service.pump(frame) == .waiting) break;
    } else return error.QuestionNotReached;
    var ordinary = (try service.pendingQuestion(frame, submitted.receipt.task)).?;
    defer ordinary.deinit();
    _ = try service.requestCancel(frame, "cancel-asking", submitted.receipt.task, "stop");
    for (0..64) |_| {
        if (try service.pump(frame) == .waiting) break;
    } else return error.CleanupQuestionNotReached;
    var cleanup = (try service.pendingQuestion(frame, submitted.receipt.task)).?;
    defer cleanup.deinit();
    try std.testing.expect(!std.meta.eql(ordinary.value.id, cleanup.value.id));
    var waiting = try service.task(frame, submitted.receipt.task);
    defer waiting.deinit();
    try std.testing.expect(waiting.value.cancellation_applied);
    try std.testing.expectEqual(.active, waiting.value.schedule);
    try std.testing.expectEqual(.waiting_input, try service.status(frame, waiting.value));
    for (0..4) |_| {
        try std.testing.expectEqual(.idle, try service.pump(frame));
        try std.testing.expectEqual(0, service.runnable.items.len);
        try std.testing.expectEqual(1, service.owned.items.len);
        try std.testing.expect(try service.shutdownIncomplete(frame));
    }
    try service.park(frame);
    _ = try service.respond(frame, "cleanup-answer", submitted.receipt.task, cleanup.value.id, cleanup.value.revision, cleanup.value.request_digest, "fair.answer.v1", .{ .number_string = "7" });
    for (0..64) |_| {
        _ = try service.pump(frame);
        var current = try service.task(frame, submitted.receipt.task);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            try std.testing.expect(try service.taskCleanupComplete(frame, current.value));
            break;
        }
    } else return error.CleanupNotCompleted;
    try std.testing.expectEqual(.idle, try service.pump(frame));
    try std.testing.expect(!try service.shutdownIncomplete(frame));
}

fn checkCleanupArchiveFact(a: std.mem.Allocator, frame: std.mem.Allocator, io: std.Io, service: *native.tasks.Service(CleanupTypes), namespace: *native.Namespace, service_live: *bool, namespace_live: *bool, source: []const u8, directory: []const u8, id: [16]u8, pending: bool) !void {
    const assets = service.assets;
    const application = service.application;
    const handlers = service.handlers;
    const profile = service.profile;
    if (pending) _ = try service.requestCancel(frame, "later-cancel", id, "different later reason");
    var task = try service.task(frame, id);
    defer task.deinit();
    const label = if (pending) "pending-control" else @tagName(task.value.outcome_kind);
    const valid = try std.fmt.allocPrint(frame, "{s}/{s}-valid.bundle", .{ directory, label });
    const invalid = try std.fmt.allocPrint(frame, "{s}/{s}-omitted.bundle", .{ directory, label });
    _ = try service.exportCheckpoint(frame, id, valid);
    const shape = try namespace.store.archiveIndex(frame, id, .{ .digest = @splat(0), .bytes = 0 });
    try omitArchiveFact(frame, io, shape, task.value, valid, invalid, if (pending) .cancellation_omitted else .terminal_omitted);
    const changed_reason = try std.fmt.allocPrint(frame, "{s}/{s}-reason.bundle", .{ directory, label });
    if (pending) try omitArchiveFact(frame, io, shape, task.value, valid, changed_reason, .cancellation_reason);
    const erased_terminal = try std.fmt.allocPrint(frame, "{s}/{s}-erased-control.bundle", .{ directory, label });
    const terminal_control = task.value.terminal() and task.value.cancellation != null;
    if (terminal_control) {
        try omitArchiveFact(frame, io, shape, task.value, valid, erased_terminal, .terminal_cancellation_omitted);
        try omitArchiveFact(frame, io, shape, task.value, valid, changed_reason, .terminal_cancellation_reason);
    }
    try service.close(frame);
    service_live.* = false;
    try namespace.close();
    namespace_live.* = false;
    {
        const target = try std.fmt.allocPrint(frame, "{s}/{s}-admission", .{ directory, label });
        var destination = try native.Namespace.open(a, io, target);
        defer destination.close() catch unreachable;
        var imported = try native.tasks.Service(CleanupTypes).init(a, io, &destination, assets, application, handlers, profile);
        defer imported.close(frame) catch unreachable;
        try std.testing.expectError(error.InvalidArchive, imported.importCheckpoint(frame, "import-fact", invalid));
        if (pending) try std.testing.expectError(error.InvalidArchive, imported.importCheckpoint(frame, "import-fact", changed_reason));
        if (terminal_control) {
            try std.testing.expectError(error.InvalidArchive, imported.importCheckpoint(frame, "import-fact", erased_terminal));
            try std.testing.expectError(error.InvalidArchive, imported.importCheckpoint(frame, "import-fact", changed_reason));
        }
        // The failed admission publishes neither namespace state nor the
        // operation ID; the original copy must succeed in the same namespace.
        const admitted = try imported.importCheckpoint(frame, "import-fact", valid);
        try std.testing.expectEqualSlices(u8, &id, &admitted.receipt.task);
        var restored = try imported.task(frame, id);
        defer restored.deinit();
        if (pending) {
            try std.testing.expect(!restored.value.cancellation_applied);
            try std.testing.expectEqualStrings("test cancellation", restored.value.cancellation.?.bytes);
            const imported_head = destination.store.head;
            try std.testing.expect((try imported.requestCancel(frame, "cancel-0", id, "test cancellation")).replayed);
            try std.testing.expect((try imported.requestCancel(frame, "later-cancel", id, "different later reason")).replayed);
            try std.testing.expectError(error.CustodyNotLocal, imported.requestCancel(frame, "copied-new-cancel", id, "test cancellation"));
            try std.testing.expectError(error.OperationConflict, imported.requestCancel(frame, "cancel-0", id, "different reason"));
            try std.testing.expectError(error.CustodyNotLocal, imported.resumeTask(frame, "resume-control", id, restored.value.revision));
            try std.testing.expectEqual(.idle, try imported.pump(frame));
            try std.testing.expectEqualDeep(imported_head, destination.store.head);
        } else {
            try std.testing.expectEqual(task.value.outcome_kind, restored.value.outcome_kind);
            var client: native.client.Client(CleanupTypes) = .{ .service = &imported };
            const events = try client.events(frame, id, 0, 128);
            var count: usize = 0;
            for (events.object.get("events").?.array.items) |event| {
                if (std.mem.eql(u8, @tagName(task.value.outcome_kind), event.object.get("type").?.string)) count += 1;
            }
            try std.testing.expectEqual(1, count);
        }
    }
    namespace.* = try native.Namespace.open(a, io, source);
    namespace_live.* = true;
    service.* = try native.tasks.Service(CleanupTypes).init(a, io, namespace, assets, application, handlers, profile);
    service_live.* = true;
    if (pending) {
        try std.testing.expect((try service.requestCancel(frame, "cancel-0", id, "test cancellation")).replayed);
        try std.testing.expect((try service.requestCancel(frame, "later-cancel", id, "different later reason")).replayed);
        var current = try service.task(frame, id);
        defer current.deinit();
        _ = try service.resumeTask(frame, "resume-pending-original", id, current.value.revision);
    }
}

test "terminal cleanup failures retain allocator-governed shutdown ownership without runnable work" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = bool, .Result = void, .Failure = void, .application = CleanupApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(a, image, admitted_image.identity(), "cleanup-test");
    defer a.free(manifest);
    const assets: native.discovery.Assets = .{ .image = image, .application = "cleanup-test", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "cleanup-profile", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    {
        const p = native.placement;
        const probe_path = try std.fmt.allocPrint(frame, "{s}/frozen-cleanup", .{path_buffer[0..length]});
        var probe_namespace = try native.Namespace.open(a, io, probe_path);
        defer probe_namespace.close() catch unreachable;
        var probe = try native.tasks.Service(CleanupTypes).init(a, io, &probe_namespace, assets, &application, handlers, profile);
        defer probe.close(frame) catch unreachable;
        const submitted = try probe.submit(frame, "failed-cleanup", true);
        for (0..3) |_| try std.testing.expectEqual(.progressed, try probe.pump(frame));
        var terminal = try probe.task(frame, submitted.receipt.task);
        defer terminal.deinit();
        try std.testing.expectEqual(.failed, terminal.value.outcome_kind);
        try std.testing.expect(terminal.value.cancellation == null);
        try std.testing.expect(!try probe.taskCleanupComplete(frame, terminal.value));
        try std.testing.expectEqual(@as(usize, 1), probe.owned.items.len);
        try std.testing.expectEqual(.idle, try probe.pump(frame));
        const subject: p.Subject = .{ .task = submitted.receipt.task };
        const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(43));
        const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(44));
        const Allow = struct {
            fn disclose(_: *anyopaque, _: p.Subject, _: []const native.testing.state.Reference) !void {}
        };
        const peer: p.Peer = .{ .name = "destination", .site = .{ .key = destination_key.public_key.bytes, .namespace = @splat(45) }, .native_build = profile.runtime_identity, .compatibility = try probe.placementCompatibility(frame, subject), .resource_binding = try profile.resourceIdentity(frame, application.image_identity), .disclosure_policy = @splat(46), .context = undefined, .disclose = Allow.disclose };
        const config: p.Configuration = .{ .signing_key = source_key, .peers = &.{peer} };
        probe.profile.placement = &config;
        try std.testing.expect(try probe.shutdownIncomplete(frame));
        _ = try probe.placementFreeze(frame, subject, "destination", try probe.placementCut(frame, subject), @splat(47));
        try std.testing.expectEqual(.frozen, (try probe.placementStatus(frame, subject)).?.phase);
        try std.testing.expect(try probe.shutdownIncomplete(frame));
        try std.testing.expect(!try probe.taskCleanupComplete(frame, terminal.value));
        try std.testing.expectEqual(.idle, try probe.pump(frame));
        try probe.placementAbortUnsent(frame, subject, @splat(47));
        try std.testing.expectEqual(.local, (try probe.placementStatus(frame, subject)).?.phase);
        try std.testing.expect(try probe.shutdownIncomplete(frame));
        try std.testing.expectEqual(.idle, try probe.pump(frame));
    }
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(CleanupTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(a) catch unreachable;
    var client: native.client.Client(CleanupTypes) = .{ .service = &service };
    // Successful cleanup releases ownership. Failed cleanup stays owned beyond
    // the former fixed sixteen-task quota without adding runnable work.
    for (0..22) |index| {
        const cleanup_fails = index >= 2;
        const cancel = index % 2 == 0;
        const operation = try std.fmt.allocPrint(frame, "cleanup-{d}", .{index});
        const submitted = try service.submit(frame, operation, cleanup_fails);
        try std.testing.expect(try service.pump(frame) == .progressed);
        var yielded = try service.task(frame, submitted.receipt.task);
        defer yielded.deinit();
        try std.testing.expectEqual(.yielded, yielded.value.outcome_kind);
        if (cancel) _ = try service.requestCancel(frame, try std.fmt.allocPrint(frame, "cancel-{d}", .{index}), submitted.receipt.task, "test cancellation");
        if (index == 0) try checkCleanupArchiveFact(a, frame, io, &service, &namespace, &service_live, &namespace_live, path, path_buffer[0..length], submitted.receipt.task, true);
        try std.testing.expect(try service.pump(frame) == .progressed);
        var cleaning = try service.task(frame, submitted.receipt.task);
        defer cleaning.deinit();
        try std.testing.expectEqual(.yielded, cleaning.value.outcome_kind);
        try std.testing.expectEqual(cancel, cleaning.value.cancellation_applied);
        if (index == 0) {
            // Exercise a real applied-but-unfinished cancellation, not a flag
            // invented by the archive mutator. One SQLite owner at a time.
            const archive_path = try std.fmt.allocPrint(frame, "{s}/cleanup.bundle", .{path_buffer[0..length]});
            _ = try service.exportCheckpoint(frame, submitted.receipt.task, archive_path);
            var manifest_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
            const shape = try namespace.store.archiveIndex(frame, submitted.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
            var forged_archives: [2][]const u8 = undefined;
            for ([_]ArchiveFactChange{ .checkpoint_cancellation_reason, .checkpoint_cancellation_bytes }, &forged_archives) |change, *forged_path| {
                forged_path.* = try std.fmt.allocPrint(frame, "{s}/{s}.bundle", .{ path_buffer[0..length], @tagName(change) });
                try omitArchiveFact(frame, io, shape, cleaning.value, archive_path, forged_path.*, change);
            }
            try service.close(frame);
            service_live = false;
            try namespace.close();
            namespace_live = false;
            {
                const destination = try std.fmt.allocPrint(frame, "{s}/imported-cleanup", .{path_buffer[0..length]});
                var imported_namespace = try native.Namespace.open(a, io, destination);
                defer imported_namespace.close() catch unreachable;
                var imported_service = try native.tasks.Service(CleanupTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
                defer imported_service.close(frame) catch unreachable;
                for (forged_archives) |forged_path| try std.testing.expectError(error.InvalidArchive, imported_service.importCheckpoint(frame, "import-cleanup", forged_path));
                const admitted = try imported_service.importCheckpoint(frame, "import-cleanup", archive_path);
                try std.testing.expectEqualSlices(u8, &submitted.receipt.task, &admitted.receipt.task);
                var imported_task = try imported_service.task(frame, admitted.receipt.task);
                defer imported_task.deinit();
                try std.testing.expect(imported_task.value.cancellation_applied);
                try std.testing.expectError(error.CustodyNotLocal, imported_service.resumeTask(frame, "resume-cleanup", admitted.receipt.task, imported_task.value.revision));
                try std.testing.expectEqual(.idle, try imported_service.pump(frame));
                try std.testing.expect(!try imported_service.taskCleanupComplete(frame, imported_task.value));
            }
            namespace = try native.Namespace.open(a, io, path);
            namespace_live = true;
            service = try native.tasks.Service(CleanupTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            service_live = true;
            _ = try service.resumeTask(frame, "resume-original-cleanup", submitted.receipt.task, cleaning.value.revision);
        }
        try std.testing.expect(try service.pump(frame) == .progressed);
        var terminal = try service.task(frame, submitted.receipt.task);
        defer terminal.deinit();
        const expected: @TypeOf(terminal.value.outcome_kind) = if (cancel) .cancelled else .failed;
        try std.testing.expectEqual(expected, terminal.value.outcome_kind);
        if (index < 2) {
            // Cancellation after a terminal failure is a historical receipt,
            // not a newly pending control. Preserve that valid null-intent case.
            if (!cancel) {
                _ = try service.requestCancel(frame, "cancel-after-terminal", submitted.receipt.task, "too late");
                var after = try service.task(frame, submitted.receipt.task);
                defer after.deinit();
                try std.testing.expect(after.value.cancellation == null);
            }
            try checkCleanupArchiveFact(a, frame, io, &service, &namespace, &service_live, &namespace_live, path, path_buffer[0..length], submitted.receipt.task, false);
        }
        try std.testing.expectEqual(!cleanup_fails, try service.taskCleanupComplete(frame, terminal.value));
        try std.testing.expect(try service.pump(frame) == .idle);
        try std.testing.expectEqual(cleanup_fails, try service.shutdownIncomplete(frame));
        try std.testing.expectEqual(if (cleanup_fails) index - 1 else 0, service.owned.items.len);
        var params = native.json.object();
        try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(submitted.receipt.task, .lower))));
        const result = try client.call(frame, .@"task.result", params);
        try std.testing.expect(result.object.get("ready").?.bool);
        try std.testing.expectEqual(!cleanup_fails, result.object.get("outcome").?.object.get("cleanup_complete").?.bool);
        try std.testing.expect((try service.submit(frame, operation, cleanup_fails)).replayed);
    }
    _ = try service.submit(frame, "beyond-former-owned-quota", false);
    try service.park(frame);
    try std.testing.expect(try service.shutdownIncomplete(frame));
    // Reopening does not reacquire old work; its durable result stays honest.
    const retained_id = service.owned.items[0];
    try service.close(frame);
    service_live = false;
    service = try native.tasks.Service(CleanupTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var retained = try service.task(frame, retained_id);
    defer retained.deinit();
    try std.testing.expect(!try service.taskCleanupComplete(frame, retained.value));
    try std.testing.expect(try service.pump(frame) == .idle);
}

test "completed result beyond the former wire-read ceiling remains publicly retrievable" {
    const Large = struct {
        pub const application_id = "large-result-test";
        pub const input_schema_id = "large-result.input.v1";
        pub const output_schema_id = "large-result.output.v1";
        pub const failure_schema_id = "large-result.failure.v1";
        pub const message_schema_id = "large-result.message.v1";
        pub const Input = protean.contracts.Utf8;
        pub const Output = Input;
        pub const Failure = void;
        pub const Message = void;
    };
    const Identity = struct {
        pub fn emit(c: protean.Context) !horos.source.Module {
            const b = c.builder;
            const input_schema = try horos_authoring.interop.schemaId(c.author, try c.schema(Large.Input));
            const entry = try b.declare(&.{input_schema}, input_schema, &.{}, &.{});
            try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
            return b.module(entry, try horos_authoring.interop.schemaId(c.author, try c.schema(void)));
        }
    };
    const parent = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = Large.Input, .Result = Large.Output, .Failure = void, .application = Identity }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(a, image, admitted_image.identity(), "large-result-test");
    const assets: native.discovery.Assets = .{ .image = image, .application = "large-result-test", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(parent), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var handlers = try native.Registry.init(parent, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "large-result-profile", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path);
    var namespace = try native.Namespace.open(parent, io, try std.fmt.allocPrint(a, "{s}/state", .{path[0..length]}));
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(Large).init(parent, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    const text = try a.alloc(u8, 4 * 1024 * 1024 + 1);
    @memset(text, 'x');
    const accepted = try service.submit(a, "large-result", .{ .bytes = text });
    while (true) {
        var frame = std.heap.ArenaAllocator.init(parent);
        defer frame.deinit();
        const step = try service.pump(frame.allocator());
        try std.testing.expect(step != .work);
        var task = try service.task(frame.allocator(), accepted.receipt.task);
        defer task.deinit();
        if (task.value.terminal()) {
            try std.testing.expect(task.value.result.?.bytes > 4 * 1024 * 1024);
            break;
        }
    }
    var client: native.client.Client(Large) = .{ .service = &service };
    var params = native.json.object();
    try native.json.put(a, &params, "task_id", native.json.string(try a.dupe(u8, &std.fmt.bytesToHex(accepted.receipt.task, .lower))));
    // The response view must fit independently of the multi-megabyte wire value.
    var response_budget: kosmos.AllocationBudget = .{ .parent = parent, .limit = 256 * 1024 };
    var response_arena = std.heap.ArenaAllocator.init(response_budget.allocator());
    defer response_arena.deinit();
    const result = try client.call(response_arena.allocator(), .@"task.result", params);
    try std.testing.expect(result.object.get("ready").?.bool);
    const outcome = result.object.get("outcome").?;
    try std.testing.expect(outcome.object.get("value") == null);
    const ref = outcome.object.get("value_ref").?;
    var expected_hash = std.crypto.hash.sha2.Sha256.init(.{});
    expected_hash.update("\"");
    expected_hash.update(text);
    expected_hash.update("\"");
    var expected: [32]u8 = undefined;
    expected_hash.final(&expected);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(expected, .lower), ref.object.get("sha256").?.string);
    try native.json.put(a, &params, "artifact_id", ref.object.get("artifact_id").?);
    try native.json.put(a, &params, "length", native.json.string("32768"));
    for ([_]usize{ 0, text.len + 2 - 32768 }) |offset| {
        try native.json.put(a, &params, "offset", native.json.string(try std.fmt.allocPrint(a, "{d}", .{offset})));
        const chunk = try client.call(a, .@"artifact.read", params);
        var decoded: [32768]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(&decoded, chunk.object.get("data").?.string);
        try std.testing.expectEqual(text.len + 2, try native.json.decimal(usize, chunk.object.get("total_bytes").?));
        for (decoded, 0..) |byte, index| try std.testing.expectEqual(@as(u8, if (offset + index == 0 or offset + index == text.len + 1) '"' else 'x'), byte);
    }
}

pub const FairTypes = struct {
    pub const application_id = "fair-owner-test";
    pub const input_schema_id = "fair.input.v1";
    pub const output_schema_id = "fair.output.v1";
    pub const failure_schema_id = "fair.failure.v1";
    pub const message_schema_id = "fair.message.v1";
    pub const Input = u32;
    pub const Output = u32;
    pub const Failure = void;
    pub const Message = u32;
};
pub const FairApplication = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const number = try b.scalar(u32);
        const boolean = try b.scalar(bool);
        const unit = try b.scalar(void);
        const leaf = try horos_authoring.interop.operationId(c.author, try c.external("fair.leaf.v1", try c.schema(u32), try c.schema(u32), .read));
        const question = try horos_authoring.interop.operationId(c.author, try c.external("fair.question.v1", try c.schema(u32), try c.schema(u32), .read));
        const inbox = try horos_authoring.interop.operationId(c.author, try Inbox.declare(c));
        const entry = try b.declare(&.{number}, number, &.{ leaf, question, inbox }, &.{});
        const input = try b.reference(b.parameter(entry, 0));
        var body = try b.term(.{ .yield_then = try b.pure(input) });
        const ignored = try b.variable(try horos_authoring.interop.schemaId(c.author, try c.schema(Inbox.Reply)));
        const paths = [_]horos.data.program.Id{
            try b.term(.{ .yield_then = try b.term(.{ .call = .{ .function = entry, .arguments = &.{input} } }) }),
            try b.term(.{ .perform = .{ .effect = leaf, .payload = input } }),
            try b.term(.{ .perform = .{ .effect = question, .payload = input } }),
            try b.bind(ignored, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), try b.pure(input)),
        };
        for (paths, 0..) |path, selector| body = try b.term(.{ .conditional = .{
            .condition = try b.primitive(boolean, .equal, &.{ input, try b.constant(u32, @intCast(selector)) }, 0),
            .when_true = path,
            .when_false = body,
        } });
        try b.define(entry, body);
        return b.module(entry, unit);
    }
};
const FairCapture = struct {
    var preparations: usize = 0;
    fn prepare(ctx: native.registry.ProjectionContext, payload: []const u8) ![]u8 {
        preparations += 1;
        return ctx.allocator.dupe(u8, payload);
    }
    fn acquire(ctx: native.Context, _: []const u8) !native.registry.Acquisition {
        return .{ .captured = try protean.contracts.encodeOwned(u32, ctx.allocator, 99) };
    }
    fn interpret(ctx: native.registry.ProjectionContext, _: []const u8, _: []const u8, raw: []const u8) !native.registry.Projection {
        return .{ .reply = try ctx.allocator.dupe(u8, raw) };
    }
    fn present(ctx: native.Context, input: u32) !native.json.Value {
        return native.json.number(ctx.allocator, input);
    }
};

test "eligible round robin progresses pure question inbox cancellation and replies while one worker is held" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    FairCapture.preparations = 0;
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = FairApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const manifest = try ownerManifest(a, image, admitted.identity(), "fair-owner");
    defer a.free(manifest);
    const assets: native.discovery.Assets = .{ .image = image, .application = "fair-owner", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var leaf = native.leaf(u32, u32, .{ .identity = "fair.leaf.v1", .resource_role = "local" }, increment);
    leaf.capture = .{ .prepare = FairCapture.prepare, .acquire = FairCapture.acquire, .interpret = FairCapture.interpret, .dependencies = native.registry.opaqueProjection };
    leaf.invoke = null;
    leaf.background = true;
    var handlers = try native.Registry.init(a, &.{
        leaf,
        native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, FairCapture.present),
        native.inbox.declaration(u32),
    });
    defer handlers.deinit();
    var grants: [3]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "fair-profile", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(a, .{});
    var service = try native.tasks.Service(FairTypes).init(failing.allocator(), io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const first = try service.submit(frame, "first-yielder", 0);
    const second = try service.submit(frame, "second-yielder", 0);
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .progressed);
    for ([_][16]u8{ first.receipt.task, second.receipt.task }) |id| {
        var task = try service.task(frame, id);
        defer task.deinit();
        try std.testing.expectEqual(1, task.value.execution_revision);
    }
    try std.testing.expect(try service.pump(frame) == .progressed);
    var second_turn = try service.task(frame, second.receipt.task);
    defer second_turn.deinit();
    try std.testing.expectEqual(1, second_turn.value.execution_revision);
    // Admission appends behind already queued continuations, even across a
    // round boundary. A stream of newcomers cannot postpone an older peer.
    const newcomer = try service.submit(frame, "new-yielder", 0);
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .progressed);
    var still_queued = try service.task(frame, newcomer.receipt.task);
    defer still_queued.deinit();
    try std.testing.expectEqual(0, still_queued.value.execution_revision);
    _ = try service.requestCancel(frame, "cancel-first", first.receipt.task, "stop");
    _ = try service.requestCancel(frame, "cancel-second", second.receipt.task, "stop");
    _ = try service.requestCancel(frame, "cancel-new", newcomer.receipt.task, "stop");
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .idle);
    const slow = try service.submit(frame, "slow", 1);
    try std.testing.expect(try service.pump(frame) == .progressed);
    const held = (try service.pump(frame)).work;
    var original_slow = try service.task(frame, slow.receipt.task);
    defer original_slow.deinit();
    // The held worker is released even when a later assertion fails.
    defer if (service_live) {
        if (service.work) |work| service.notSent(frame, work) catch unreachable;
    };
    var client: native.client.Client(FairTypes) = .{ .service = &service };
    var slow_params = native.json.object();
    try native.json.put(frame, &slow_params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(slow.receipt.task, .lower))));
    try std.testing.expectEqualStrings("running", (try client.call(frame, .@"task.status", slow_params)).object.get("status").?.string);
    const queued = try service.submit(frame, "queued-leaf", 1);
    {
        var task = try service.task(frame, queued.receipt.task);
        defer task.deinit();
        try std.testing.expectEqual(.queued, try service.status(frame, task.value));
    }
    const infinite = try service.submit(frame, "yielding-forever", 0);
    const finite = try service.submit(frame, "finite", 4);
    const question = try service.submit(frame, "question", 2);
    const inbox = try service.submit(frame, "inbox", 3);
    const cancelled = try service.submit(frame, "cancelled", 4);
    _ = try service.message(frame, "slow-followup", slow.receipt.task, 11);
    _ = try service.message(frame, "inbox-message", inbox.receipt.task, 7);
    _ = try service.requestCancel(frame, "cancel", cancelled.receipt.task, "stop");
    for (0..35) |_| try std.testing.expect(try service.pump(frame) != .work);
    try std.testing.expectEqual(1, FairCapture.preparations);
    try std.testing.expectEqual(0, try namespace.store.capabilityAttempts(queued.receipt.task, "fair.leaf.v1"));
    var unchanged_slow = try service.task(frame, slow.receipt.task);
    defer unchanged_slow.deinit();
    try std.testing.expectEqualDeep(original_slow.value.checkpoint, unchanged_slow.value.checkpoint);
    try std.testing.expectEqual(original_slow.value.execution_revision, unchanged_slow.value.execution_revision);
    try std.testing.expect(unchanged_slow.value.revision > original_slow.value.revision);
    try std.testing.expectEqualStrings("running", (try client.call(frame, .@"task.status", slow_params)).object.get("status").?.string);
    inline for (.{ .{ finite.receipt.task, .completed }, .{ inbox.receipt.task, .completed }, .{ cancelled.receipt.task, .cancelled } }) |expected| {
        var task = try service.task(frame, expected[0]);
        defer task.deinit();
        try std.testing.expectEqual(expected[1], task.value.outcome_kind);
    }
    var live = try service.task(frame, infinite.receipt.task);
    defer live.deinit();
    try std.testing.expect(live.value.execution_revision > 1);
    var asked = try service.task(frame, question.receipt.task);
    defer asked.deinit();
    try std.testing.expectEqual(.waiting_input, try service.status(frame, asked.value));
    var active_question = (try service.pendingQuestion(frame, question.receipt.task)).?;
    defer active_question.deinit();
    _ = try service.respond(frame, "answer", question.receipt.task, active_question.value.id, active_question.value.revision, active_question.value.request_digest, "fair.answer.v1", .{ .number_string = "73" });
    for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
    var answered = try service.task(frame, question.receipt.task);
    defer answered.deinit();
    try std.testing.expectEqual(.completed, answered.value.outcome_kind);
    // Every callback dimension is checked before the current worker is touched.
    inline for (.{ "owner_epoch", "task", "occurrence", "attempt" }) |field| {
        var stale = held;
        @field(stale, field)[0] ^= 1;
        try std.testing.expectError(error.StaleOccurrence, service.acquire(frame, stale, &.{}));
        try std.testing.expectEqualSlices(u8, &held.attempt, &service.work.?.attempt);
    }
    _ = try service.requestCancel(frame, "cancel-infinite", infinite.receipt.task, "stop");
    _ = try service.requestCancel(frame, "cancel-queued", queued.receipt.task, "stop");
    for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
    const raw = try protean.contracts.encodeOwned(u32, frame, 99);
    try service.acquire(frame, held, raw);
    try std.testing.expectError(error.StaleOccurrence, service.acquire(frame, held, raw));
    for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
    var finished = try service.task(frame, slow.receipt.task);
    defer finished.deinit();
    try std.testing.expectEqual(.completed, finished.value.outcome_kind);
    try std.testing.expectEqualStrings("completed", (try client.call(frame, .@"task.status", slow_params)).object.get("status").?.string);
    try std.testing.expectEqual(1, FairCapture.preparations);
    try std.testing.expectEqual(1, try namespace.store.capabilityAttempts(slow.receipt.task, "fair.leaf.v1"));
    try std.testing.expect(try service.pump(frame) == .idle);
    // Park across a partial round, then resume in the opposite order using the
    // same owner. Old scheduling position must not survive the empty queue.
    const park_first = try service.submit(frame, "park-first", 0);
    const park_second = try service.submit(frame, "park-second", 0);
    try std.testing.expect(try service.pump(frame) == .progressed);
    try service.park(frame);
    inline for (.{ .{ park_second.receipt.task, "resume-second" }, .{ park_first.receipt.task, "resume-first" } }) |item| {
        var task = try service.task(frame, item[0]);
        defer task.deinit();
        _ = try service.resumeTask(frame, item[1], item[0], task.value.revision);
    }
    try std.testing.expect(try service.pump(frame) == .progressed);
    var resumed_first = try service.task(frame, park_first.receipt.task);
    defer resumed_first.deinit();
    var resumed_second = try service.task(frame, park_second.receipt.task);
    defer resumed_second.deinit();
    try std.testing.expectEqual(1, resumed_first.value.execution_revision);
    try std.testing.expectEqual(1, resumed_second.value.execution_revision);
    _ = try service.requestCancel(frame, "cancel-park-first", park_first.receipt.task, "stop");
    _ = try service.requestCancel(frame, "cancel-park-second", park_second.receipt.task, "stop");
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .progressed);
    try std.testing.expect(try service.pump(frame) == .idle);
    // Stop writes only after both admissions. A quantum may publish to Kosmos,
    // but its failed store publication must fence every task and retain custody.
    const rollback = try service.submit(frame, "rollback-quantum", 4);
    const no_dispatch = try service.submit(frame, "fenced-leaf", 1);
    try namespace.store.database.exec("PRAGMA query_only=ON;");
    try std.testing.expectError(error.StorageUnavailable, service.pump(frame));
    try std.testing.expect(namespace.store.fenced);
    try std.testing.expect(service.active != null);
    try std.testing.expectError(error.StorageUnavailable, service.pump(frame));
    try std.testing.expectEqual(1, FairCapture.preparations);
    try namespace.store.database.exec("PRAGMA query_only=OFF;");
    // Closing the fenced owner transfers its last receipt with no allocation.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try service.close(frame);
    service_live = false;
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try namespace.close();
    namespace_live = false;
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    service = try native.tasks.Service(FairTypes).init(failing.allocator(), io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var recovered = try service.task(frame, rollback.receipt.task);
    defer recovered.deinit();
    try std.testing.expectEqual(0, recovered.value.execution_revision);
    try std.testing.expectEqual(.progressed, recovered.value.outcome_kind);
    try std.testing.expectEqual(0, try namespace.store.capabilityAttempts(no_dispatch.receipt.task, "fair.leaf.v1"));
    try std.testing.expect(try service.pump(frame) == .idle);
}

pub const LookupFixture = struct {
    const C = protean.contracts;
    const State = native.testing.state;
    const Kind = enum { capture, not_sent, inconclusive, unavailable, rejected };
    const Body = struct { binding: [32]u8, kind: Kind, raw: C.Bytes(null) };
    const Evidence = struct { body: Body, signature: [32]u8 };
    hold: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),
    kind: Kind = .capture,

    fn binding(a: std.mem.Allocator, input: native.registry.RecoveryInput) ![32]u8 {
        const Bound = struct { task: [16]u8, occurrence: [32]u8, attempt: [32]u8, request_identity: [32]u8, request: State.Reference, prepared: ?State.Reference, profile: State.Reference, resources: C.Vector(State.Reference, null), capability: C.Text(128), inference: bool };
        const bytes = try C.encodeOwned(Bound, a, .{ .task = input.task, .occurrence = input.occurrence, .attempt = input.attempt, .request_identity = input.request_identity, .request = input.request, .prepared = input.prepared, .profile = input.profile, .resources = .{ .items = input.resources }, .capability = .{ .bytes = input.capability }, .inference = input.inference });
        defer a.free(bytes);
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        return result;
    }
    fn sign(a: std.mem.Allocator, body: Body) ![32]u8 {
        const bytes = try C.encodeOwned(Body, a, body);
        defer a.free(bytes);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, bytes, "private synthetic receipt authority");
        return mac;
    }
    pub fn receipt(a: std.mem.Allocator, input: native.registry.RecoveryInput, kind: Kind) ![]u8 {
        return receiptValue(a, input, kind, 99);
    }
    fn receiptValue(a: std.mem.Allocator, input: native.registry.RecoveryInput, kind: Kind, value: u32) ![]u8 {
        const raw = try C.encodeOwned(u32, a, value);
        defer a.free(raw);
        const body: Body = .{ .binding = try binding(a, input), .kind = kind, .raw = .{ .bytes = raw } };
        return C.encodeOwned(Evidence, a, .{ .body = body, .signature = try sign(a, body) });
    }
    fn lookup(ctx: native.Context, input: native.registry.RecoveryInput, _: []const u8, _: ?[]const u8) ![]u8 {
        const self: *LookupFixture = @ptrCast(@alignCast(ctx.environment.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.started.store(true, .release);
        while (self.hold.load(.acquire)) {
            try ctx.checkCancellation();
            try ctx.io.sleep(.fromMilliseconds(1), .awake);
        }
        return receipt(ctx.allocator, input, self.kind);
    }
    const verification_failures = [_]anyerror{ error.StorageUnavailable, error.CorruptState, error.Busy, error.InvalidState, error.OutOfMemory, error.Capacity, error.VerifierReadFailed };

    pub fn verify(ctx: native.registry.ProjectionContext, input: native.registry.RecoveryInput, bytes: []const u8) !native.registry.RecoveryFinding {
        // Inject failures after the owner admitted the original bindings. The
        // final case deliberately has no special meaning to the task owner.
        for (verification_failures) |failure| if (std.mem.eql(u8, bytes, @errorName(failure))) return failure;
        var decoded = C.decodeOwned(Evidence, ctx.allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory, error.Capacity => return err,
            else => return .rejected,
        };
        defer decoded.deinit();
        if (!std.meta.eql(decoded.value.signature, try sign(ctx.allocator, decoded.value.body)) or !std.meta.eql(decoded.value.body.binding, try binding(ctx.allocator, input))) return .rejected;
        return switch (decoded.value.body.kind) {
            .capture => .{ .capture = try ctx.allocator.dupe(u8, decoded.value.body.raw.bytes) },
            .not_sent => .not_sent,
            .inconclusive => .inconclusive,
            .unavailable => .unavailable,
            .rejected => .rejected,
        };
    }
    fn forbidden(_: native.Context, _: []const u8) !native.registry.Acquisition {
        return error.OriginalEffectMustNotRun;
    }
    pub fn interpret(ctx: native.registry.ProjectionContext, _: []const u8, _: []const u8, raw: []const u8) !native.registry.Projection {
        var value = try C.decodeOwned(u32, ctx.allocator, raw);
        defer value.deinit();
        if (value.value != 99) return error.InvalidCapture;
        return .{ .reply = try ctx.allocator.dupe(u8, raw), .output_tokens = 7 };
    }
};

fn lookupUnknown(service: *native.tasks.Service(FairTypes), a: std.mem.Allocator, id: []const u8) !native.tasks.Work {
    _ = try service.submit(a, id, 1);
    for (0..20) |_| {
        const step = try service.pump(a);
        if (step == .work) {
            // Return only stable IDs; the service owns and releases all bytes.
            var work = step.work;
            try service.unknown(a, work);
            work.request = &.{};
            work.prepared = null;
            work.profile = &.{};
            return work;
        }
    }
    return error.MissingWork;
}

fn awaitLookup(io: std.Io, worker: *native.testing.Worker) !void {
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (!worker.finished()) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try worker.join();
}

test "retained captures and recovery remain readable under a different current image" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const Successor = struct {
        pub fn emit(c: protean.Context) !horos.source.Module {
            const b = c.builder;
            const number = try b.scalar(u32);
            const entry = try b.declare(&.{number}, number, &.{}, &.{});
            try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
            return b.module(entry, try b.scalar(void));
        }
    };
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = FairApplication }));
    defer compiled.deinit();
    var successor = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = Successor }));
    defer successor.deinit();
    const old_image = try frame.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, old_image);
    const new_image = try frame.alloc(u8, try horos.data.program_image.encodedLength(successor.program));
    _ = try successor.encode(a, new_image);
    const Pure = struct {
        fn rederive(ctx: native.registry.RederivationContext, _: native.registry.RecoveryInput, payload: []const u8, _: ?[]const u8) !native.registry.RederivationFinding {
            var input = try protean.contracts.decodeOwned(u32, ctx.allocator, payload);
            defer input.deinit();
            return .{ .result = try protean.contracts.encodeOwned(u32, ctx.allocator, input.value + 1) };
        }
    };
    const Case = enum { captured, pure_reply, verified_capture };
    for ([_]Case{ .captured, .pure_reply, .verified_capture }) |scenario| {
        var leaf = native.leaf(u32, u32, .{ .identity = "fair.leaf.v1", .resource_role = "local" }, increment);
        if (scenario == .pure_reply) {
            leaf.recovery = .{ .identity = "pure-increment.recovery.v1", .version = 1, .rederive = Pure.rederive };
        } else {
            leaf.capture = .{ .prepare = FairCapture.prepare, .acquire = FairCapture.acquire, .interpret = FairCapture.interpret, .dependencies = native.registry.opaqueProjection };
            leaf.invoke = null;
            leaf.background = true;
            if (scenario == .verified_capture) leaf.recovery = .{ .identity = "signed-fixture-receipt.v1", .version = 1, .lookup = .{ .acquire = LookupFixture.lookup, .verify = LookupFixture.verify } };
        }
        var handlers = try native.Registry.init(a, &.{ leaf, native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, FairCapture.present), native.inbox.declaration(u32) });
        defer handlers.deinit();
        var grants: [3]native.registry.Grant = undefined;
        const profile: native.tasks.Profile = .{ .id = "retained", .runtime_identity = @splat(42), .bytes = "retained-profile", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var buffer: [4096]u8 = undefined;
        const length = try temporary.dir.realPath(io, &buffer);
        const path = try std.fmt.allocPrint(frame, "{s}/retained", .{buffer[0..length]});
        var task_id: [16]u8 = undefined;
        var params = native.json.object();
        var original_status: []const u8 = undefined;
        var original_result: []const u8 = undefined;
        for ([_][]const u8{ old_image, new_image }, 0..) |image, generation| {
            const admitted = try horos.data.program_image.Admitted.decode(a, image);
            defer admitted.deinit();
            const manifest = try ownerManifest(frame, image, admitted.identity(), "retained-owner");
            const assets: native.discovery.Assets = .{ .image = image, .application = "retained-owner", .manifest = manifest };
            var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted.identity() };
            defer application.deinit();
            application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
            for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(frame, application.image_identity) };
            var namespace = try native.Namespace.open(a, io, path);
            defer namespace.close() catch unreachable;
            var service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            defer service.close(frame) catch unreachable;
            var client: native.client.Client(FairTypes) = .{ .service = &service };
            if (generation == 0) {
                task_id = (try service.submit(frame, "original", 1)).receipt.task;
                try std.testing.expect(try service.pump(frame) == .progressed);
                const work = (try service.pump(frame)).work;
                if (scenario == .captured) {
                    try service.acquire(frame, work, try protean.contracts.encodeOwned(u32, frame, 99));
                } else {
                    try service.unknown(frame, work);
                    var unknown = try service.task(frame, task_id);
                    defer unknown.deinit();
                    _ = try service.reconcile(frame, "recover", task_id, unknown.value.revision, work.occurrence, work.attempt, if (scenario == .pure_reply) .rederive else .lookup);
                    if (scenario == .pure_reply) {
                        const computation = (try service.pump(frame)).work;
                        const worker = try native.testing.Worker.init(a, io);
                        defer worker.deinit(a) catch unreachable;
                        try worker.start(computation, profile.authority, null);
                        try awaitLookup(io, worker);
                        defer worker.release() catch unreachable;
                        try service.completeWork(frame, computation, worker.result.?);
                    }
                    if (scenario == .verified_capture) {
                        const lookup = (try service.pump(frame)).work;
                        var record = try protean.contracts.decodeOwned(native.testing.state.Reconciliation, frame, lookup.recovery.?.body);
                        defer record.deinit();
                        var request = try protocol.decode(protocol.Request, frame, lookup.request);
                        defer request.deinit();
                        try service.acquire(frame, lookup, try LookupFixture.receipt(frame, native.registry.RecoveryInput.fromReconciliation(record.value, request.value.request_identity, false), .capture));
                    }
                }
                for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
                var completed = try service.task(frame, task_id);
                defer completed.deinit();
                try std.testing.expect(completed.value.outcome_kind == .completed);
                try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task_id, .lower))));
                original_status = try native.json.canonical(frame, try client.call(frame, .@"task.status", params));
                original_result = try native.json.canonical(frame, try client.call(frame, .@"task.result", params));
            } else {
                try std.testing.expectEqualStrings(original_status, try native.json.canonical(frame, try client.call(frame, .@"task.status", params)));
                try std.testing.expectEqualStrings(original_result, try native.json.canonical(frame, try client.call(frame, .@"task.result", params)));
                var retained = try service.task(frame, task_id);
                defer retained.deinit();
                try std.testing.expectError(error.IncompatibleProfile, service.resumeTask(frame, "incompatible-resume", task_id, retained.value.revision));
                try std.testing.expect(!namespace.store.fenced);
            }
        }
    }
}

test "pure recovery without a capture adapter settles the original typed binding after restart" {
    try pureRecovery(.valid);
}

test "pure recovery retains unresolved derivations without swallowing resource or custody failures" {
    for ([_]PureRecoveryCase{ .rejected, .malformed, .unsupported, .unavailable, .inconclusive, .cancelled, .capacity, .allocation, .corrupt, .storage, .busy, .invalid_state, .unexpected }) |scenario| try pureRecovery(scenario);
}

test "pure recovery work preserves peer progress cancellation and interrupted admission" {
    for ([_]PureRecoveryCase{ .held, .held_cancel, .prior_cancel, .pending_cancel, .pending_cancel_failure, .interrupted }) |scenario| try pureRecovery(scenario);
}

const PureRecoveryCase = enum { valid, rejected, malformed, unsupported, unavailable, inconclusive, cancelled, capacity, allocation, corrupt, storage, busy, invalid_state, unexpected, held, held_cancel, prior_cancel, pending_cancel, pending_cancel_failure, interrupted };

fn pureRecovery(scenario: PureRecoveryCase) !void {
    errdefer std.debug.print("pure recovery scenario: {s}\n", .{@tagName(scenario)});
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = FairApplication }));
    defer compiled.deinit();
    const image = try frame.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(frame, image, admitted_image.identity(), "pure-recovery-owner");
    const assets: native.discovery.Assets = .{ .image = image, .application = "pure-recovery-owner", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const Pure = struct {
        fn invoke(_: native.Context, _: u32) !u32 {
            return error.OriginalInvocationForbidden;
        }
        var derivations: std.atomic.Value(u32) = .init(0);
        var hold: std.atomic.Value(bool) = .init(false);
        fn rederive(ctx: native.registry.RederivationContext, _: native.registry.RecoveryInput, payload: []const u8, prepared: ?[]const u8) !native.registry.RederivationFinding {
            _ = derivations.fetchAdd(1, .acq_rel);
            try std.testing.expect(prepared == null);
            const selected = std.meta.stringToEnum(PureRecoveryCase, ctx.profile) orelse return error.InvalidProfile;
            while (hold.load(.acquire)) {
                try ctx.checkCancellation();
                std.atomic.spinLoopHint();
            }
            switch (selected) {
                .valid, .held, .held_cancel, .prior_cancel, .pending_cancel, .pending_cancel_failure, .interrupted => {},
                .rejected => return .rejected,
                .malformed => return .{ .result = try ctx.allocator.dupe(u8, &.{0}) },
                .unsupported => return .unsupported,
                .unavailable => return .unavailable,
                .inconclusive => return .inconclusive,
                .cancelled => return error.Canceled,
                .capacity => return error.Capacity,
                .allocation => return error.OutOfMemory,
                .corrupt => return error.CorruptState,
                .storage => return error.StorageUnavailable,
                .busy => return error.Busy,
                .invalid_state => return error.InvalidState,
                .unexpected => return error.InjectedRederivationFailure,
            }
            var input = try protean.contracts.decodeOwned(u32, ctx.allocator, payload);
            defer input.deinit();
            return .{ .result = try protean.contracts.encodeOwned(u32, ctx.allocator, input.value + 1) };
        }
    };
    Pure.derivations.store(0, .release);
    Pure.hold.store(scenario == .held or scenario == .held_cancel, .release);
    defer Pure.hold.store(false, .release);
    var leaf = native.leaf(u32, u32, .{ .identity = "fair.leaf.v1", .resource_role = "local" }, Pure.invoke);
    leaf.recovery = .{ .identity = "pure-increment.recovery.v1", .version = 1, .rederive = Pure.rederive };
    var handlers = try native.Registry.init(a, &.{ leaf, native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, FairCapture.present), native.inbox.declaration(u32) });
    defer handlers.deinit();
    var grants: [3]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "pure", .runtime_identity = @splat(42), .bytes = @tagName(scenario), .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(frame, application.image_identity) };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(frame, "{s}/pure", .{buffer[0..length]});
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(frame) catch unreachable;
    const original = try lookupUnknown(&service, frame, "pure-original");
    try service.close(frame);
    try namespace.close();
    namespace = try native.Namespace.open(a, io, path);
    service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var unknown = try service.task(frame, original.task);
    defer unknown.deinit();
    const expected_revision = if (scenario == .prior_cancel) (try service.requestCancel(frame, "prior-cancel", original.task, "settle then cancel")).receipt.revision else unknown.value.revision;
    const original_attempt = (try namespace.store.recordBytes(frame, "attempt", original.attempt, original.task)).?;
    const admitted = try service.reconcile(frame, "pure-recover", original.task, expected_revision, original.occurrence, original.attempt, .rederive);
    try std.testing.expectEqual(@as(u32, 0), Pure.derivations.load(.acquire));
    {
        var pending = try service.reconciliation(frame, original.task, admitted.receipt.reconciliation.?);
        defer pending.deinit();
        try std.testing.expect(pending.value.outcome == .pending and pending.value.provenance == .none);
    }
    if (scenario == .pending_cancel or scenario == .pending_cancel_failure or scenario == .interrupted) {
        if (scenario == .pending_cancel) {
            _ = try service.requestCancel(frame, "cancel-before-worker", original.task, "interrupt recovery");
        } else if (scenario == .pending_cancel_failure) {
            // Advance allocation failure through admission until cancellation
            // commits. Earlier failures must roll back and remain retryable;
            // a failure after that commit must prevent recovery dispatch.
            const before_cancel = namespace.store.head;
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var failing = std.testing.FailingAllocator.init(frame, .{ .fail_index = fail_index });
                _ = service.requestCancel(failing.allocator(), "cancel-before-worker", original.task, "interrupt recovery") catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    if (namespace.store.head.generation == before_cancel.generation) {
                        try std.testing.expect(!namespace.store.fenced);
                        continue;
                    }
                    if (!namespace.store.fenced) std.debug.print("cancellation committed at allocation failure {d} but recovery can still dispatch\n", .{fail_index});
                    try std.testing.expect(namespace.store.fenced);
                    try std.testing.expectError(error.StorageUnavailable, service.pump(frame));
                    try std.testing.expectError(error.StorageUnavailable, service.requestCancel(frame, "cancel-before-worker", original.task, "interrupt recovery"));
                    break;
                };
                return error.ExpectedAllocationFailureAfterCancellationCommit;
            }
            try service.close(frame);
            try namespace.close();
            namespace = try native.Namespace.open(a, io, path);
            service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            const replay = try service.requestCancel(frame, "cancel-before-worker", original.task, "interrupt recovery");
            try std.testing.expect(replay.replayed);
            var cancelled = try service.task(frame, original.task);
            defer cancelled.deinit();
            try std.testing.expectEqualStrings("interrupt recovery", cancelled.value.cancellation.?.bytes);
        } else {
            const archive = try std.fmt.allocPrint(frame, "{s}/pending-pure.agnx", .{buffer[0..length]});
            _ = try service.exportCheckpoint(frame, original.task, archive);
            try service.close(frame);
            try namespace.close();
            {
                const copy_path = try std.fmt.allocPrint(frame, "{s}/imported-pure", .{buffer[0..length]});
                var copy_namespace = try native.Namespace.open(a, io, copy_path);
                defer copy_namespace.close() catch unreachable;
                var copy = try native.tasks.Service(FairTypes).init(a, io, &copy_namespace, assets, &application, handlers, profile);
                defer copy.close(frame) catch unreachable;
                _ = try copy.importCheckpoint(frame, "import-pure", archive);
                var copied = try copy.reconciliation(frame, original.task, admitted.receipt.reconciliation.?);
                defer copied.deinit();
                try std.testing.expect(copied.value.outcome == .unresolved and copied.value.outcome.unresolved == .interrupted);
                try std.testing.expect(try copy.pump(frame) == .idle);
            }
            namespace = try native.Namespace.open(a, io, path);
            var bootstrap = profile;
            bootstrap.bytes = "bootstrap-before-frozen-inputs";
            service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, bootstrap);
            var readable = try service.task(frame, original.task);
            defer readable.deinit();
            try std.testing.expectEqual(.unknown, try service.status(frame, readable.value));
            service.profile = profile;
        }
        var stopped = try service.reconciliation(frame, original.task, admitted.receipt.reconciliation.?);
        defer stopped.deinit();
        try std.testing.expect(stopped.value.outcome == .unresolved and stopped.value.provenance == .none);
        const expected: @TypeOf(stopped.value.outcome.unresolved) = if (scenario == .pending_cancel) .unavailable else .interrupted;
        try std.testing.expectEqual(expected, stopped.value.outcome.unresolved);
        try std.testing.expectEqual(@as(u32, 0), Pure.derivations.load(.acquire));
        try std.testing.expect(try service.pump(frame) == .idle);
        const replay = try service.reconcile(frame, "pure-recover", original.task, expected_revision, original.occurrence, original.attempt, .rederive);
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqualDeep(admitted.receipt, replay.receipt);
        _ = try namespace.store.auditRetention(handlers, application.image_identity);
        return;
    }
    const before = namespace.store.head;
    const work = (try service.pump(frame)).work;
    const worker = try native.testing.Worker.init(a, io);
    defer worker.deinit(a) catch unreachable;
    try worker.start(work, profile.authority, null);
    defer if (worker.future != null) {
        Pure.hold.store(false, .release);
        worker.cancel();
        awaitLookup(io, worker) catch unreachable;
        service.notSent(frame, work) catch {};
        worker.release() catch unreachable;
    };
    try std.testing.expect(!try service.shouldCancelWork(work));
    if (scenario == .held or scenario == .held_cancel) {
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
        while (Pure.derivations.load(.acquire) == 0) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.TestTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(!worker.finished());
        const peer = try service.submit(frame, "pure-peer", 4);
        const cancelled_peer = try service.submit(frame, "cancelled-peer", 0);
        _ = try service.requestCancel(frame, "peer-cancel", cancelled_peer.receipt.task, "peer only");
        _ = try service.message(frame, "recovery-message", original.task, 7);
        try std.testing.expect(!try service.shouldCancelWork(work));
        for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
        var client: native.client.Client(FairTypes) = .{ .service = &service };
        for ([_]struct { id: [16]u8, status: []const u8 }{ .{ .id = original.task, .status = "unknown" }, .{ .id = peer.receipt.task, .status = "completed" }, .{ .id = cancelled_peer.receipt.task, .status = "cancelled" } }) |observation| {
            var params = native.json.object();
            try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(observation.id, .lower))));
            try std.testing.expectEqualStrings(observation.status, (try client.call(frame, .@"task.status", params)).object.get("status").?.string);
        }
        try std.testing.expect((try service.reconcile(frame, "pure-recover", original.task, expected_revision, original.occurrence, original.attempt, .rederive)).replayed);
        try std.testing.expectEqual(@as(u32, 1), Pure.derivations.load(.acquire));
        if (scenario == .held_cancel) {
            _ = try service.requestCancel(frame, "cancel-rederivation", original.task, "stop new computation");
            try std.testing.expect(try service.shouldCancelWork(work));
            worker.cancel();
        } else Pure.hold.store(false, .release);
    }
    try awaitLookup(io, worker);
    defer worker.release() catch unreachable;
    if (scenario == .capacity or scenario == .allocation or scenario == .corrupt or scenario == .storage or scenario == .busy or scenario == .invalid_state or scenario == .unexpected) {
        const expected_error = switch (scenario) {
            .capacity => error.Capacity,
            .allocation => error.OutOfMemory,
            .corrupt => error.CorruptState,
            .storage => error.StorageUnavailable,
            .busy => error.Busy,
            .invalid_state => error.InvalidState,
            .unexpected => error.InjectedRederivationFailure,
            else => unreachable,
        };
        try std.testing.expectError(expected_error, service.completeWork(frame, work, worker.result.?));
        try std.testing.expectEqualDeep(before, namespace.store.head);
        try std.testing.expect(namespace.store.fenced and service.work == null);
        try service.close(frame);
        try namespace.close();
        namespace = try native.Namespace.open(a, io, path);
        service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        var interrupted = try service.reconciliation(frame, original.task, admitted.receipt.reconciliation.?);
        defer interrupted.deinit();
        try std.testing.expect(interrupted.value.outcome == .unresolved and interrupted.value.outcome.unresolved == .interrupted);
        try std.testing.expectEqualStrings(original_attempt, (try namespace.store.recordBytes(frame, "attempt", original.attempt, original.task)).?);
        return;
    }
    try service.completeWork(frame, work, worker.result.?);
    var recovery = try service.reconciliation(frame, original.task, admitted.receipt.reconciliation.?);
    defer recovery.deinit();
    if (scenario != .valid and scenario != .held and scenario != .prior_cancel) {
        try std.testing.expect(recovery.value.outcome == .unresolved and recovery.value.provenance == .none);
        const expected: @TypeOf(recovery.value.outcome.unresolved) = switch (scenario) {
            .rejected, .malformed => .rejected,
            .unsupported => .unsupported,
            .unavailable, .cancelled, .held_cancel => .unavailable,
            .inconclusive => .inconclusive,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, recovery.value.outcome.unresolved);
        try std.testing.expectEqualStrings(original_attempt, (try namespace.store.recordBytes(frame, "attempt", original.attempt, original.task)).?);
        var unresolved = try service.task(frame, original.task);
        defer unresolved.deinit();
        try std.testing.expectEqual(.unknown, try service.status(frame, unresolved.value));
        try std.testing.expectEqual(unknown.value.inference_attempts, unresolved.value.inference_attempts);
        try std.testing.expectEqual(unknown.value.inference_request_bytes, unresolved.value.inference_request_bytes);
        try std.testing.expectEqual(unknown.value.inference_output_tokens, unresolved.value.inference_output_tokens);
        try std.testing.expectError(error.UnsettledOccurrence, service.resumeTask(frame, "cannot-reissue", original.task, unresolved.value.revision));
        try service.close(frame);
        try namespace.close();
        namespace = try native.Namespace.open(a, io, path);
        service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        const sealed = namespace.store.head;
        const replay = try service.reconcile(frame, "pure-recover", original.task, expected_revision, original.occurrence, original.attempt, .rederive);
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqualDeep(admitted.receipt, replay.receipt);
        try std.testing.expectEqualDeep(sealed, namespace.store.head);
        try std.testing.expect(try service.pump(frame) == .idle);
        _ = try namespace.store.auditRetention(handlers, application.image_identity);
        return;
    }
    try std.testing.expect(recovery.value.outcome == .reply_settled and recovery.value.provenance == .rederived);
    try std.testing.expect(recovery.value.prepared == null and recovery.value.original_capture == null);
    var original_occurrence = try protean.contracts.decodeOwned(native.testing.occurrence.Occurrence, frame, try namespace.store.object(frame, recovery.value.original_occurrence, null));
    defer original_occurrence.deinit();
    try std.testing.expect(original_occurrence.value.state == .unknown);
    var bound = try protocol.decode(protocol.Result, frame, try namespace.store.object(frame, recovery.value.outcome.reply_settled, null));
    defer bound.deinit();
    try std.testing.expectEqualSlices(u8, &original_occurrence.value.request, &bound.value.request_identity);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, bound.value.value);
    for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
    var completed = try service.task(frame, original.task);
    defer completed.deinit();
    if (scenario == .prior_cancel) {
        try std.testing.expect(completed.value.outcome_kind == .cancelled and completed.value.cancellation_applied);
    } else {
        try std.testing.expect(completed.value.outcome_kind == .completed);
        try std.testing.expectEqualSlices(u8, bound.value.value, try namespace.store.object(frame, completed.value.result.?, null));
    }
    try std.testing.expectEqual(1, try namespace.store.capabilityAttempts(original.task, "fair.leaf.v1"));
    try std.testing.expect((try service.reconcile(frame, "pure-recover", original.task, expected_revision, original.occurrence, original.attempt, .rederive)).replayed);
    _ = try namespace.store.auditRetention(handlers, application.image_identity);
}

test "receipt lookup retains exclusive admission and verifies evidence through the existing worker" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const State = native.testing.state;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = FairApplication }));
    defer compiled.deinit();
    const image = try frame.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(frame, image, admitted_image.identity(), "lookup-owner");
    const assets: native.discovery.Assets = .{ .image = image, .application = "lookup-owner", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var leaf = native.leaf(u32, u32, .{ .identity = "fair.leaf.v1", .resource_role = "local", .inference = true }, increment);
    leaf.capture = .{ .prepare = FairCapture.prepare, .acquire = LookupFixture.forbidden, .interpret = LookupFixture.interpret, .dependencies = native.registry.opaqueProjection };
    leaf.invoke = null;
    leaf.background = true;
    leaf.recovery = .{ .identity = "signed-fixture-receipt.v1", .version = 1, .lookup = .{ .acquire = LookupFixture.lookup, .verify = LookupFixture.verify } };
    var handlers = try native.Registry.init(a, &.{ leaf, native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, FairCapture.present), native.inbox.declaration(u32) });
    defer handlers.deinit();
    var fixture: LookupFixture = .{};
    var grants: [3]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "lookup", .runtime_identity = @splat(42), .bytes = "frozen-profile", .environment = &fixture, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test", .inference = true } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(frame, application.image_identity) };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(frame, "{s}/lookup", .{buffer[0..length]});
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(frame) catch unreachable;
    // A real reopen drops the original worker; the original effect callback
    // is forbidden throughout this fixture.
    const original = try lookupUnknown(&service, frame, "original");
    try service.close(frame);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var before = try service.task(frame, original.task);
    defer before.deinit();
    const revision = before.value.revision;
    service.profile.authority.grants = &.{};
    const head = namespace.store.head;
    try std.testing.expectError(error.Denied, service.reconcile(frame, "lookup", original.task, revision, original.occurrence, original.attempt, .lookup));
    try std.testing.expectEqualDeep(head, namespace.store.head);
    service.profile.authority.grants = &grants;
    const admission = try service.reconcile(frame, "lookup", original.task, revision, original.occurrence, original.attempt, .lookup);
    const id = admission.receipt.reconciliation.?;
    var pending = try service.reconciliation(frame, original.task, id);
    defer pending.deinit();
    try std.testing.expect(pending.value.outcome == .pending);
    try std.testing.expectEqual(0, fixture.calls.load(.acquire));
    try std.testing.expect((try service.reconcile(frame, "lookup", original.task, revision, original.occurrence, original.attempt, .lookup)).replayed);
    try std.testing.expectError(error.OperationConflict, service.reconcile(frame, "lookup", original.task, revision, original.occurrence, original.attempt, .rederive));
    try std.testing.expectError(error.UnsettledOccurrence, service.reconcile(frame, "competitor", original.task, admission.receipt.revision, original.occurrence, original.attempt, .lookup));
    fixture.hold.store(true, .release);
    const work = (try service.pump(frame)).work;
    const worker = try native.testing.Worker.init(a, io);
    defer worker.deinit(a) catch unreachable;
    try worker.start(work, service.profile.authority, &fixture);
    defer if (worker.future != null) {
        fixture.hold.store(false, .release);
        awaitLookup(io, worker) catch unreachable;
        service.unknown(frame, work) catch unreachable;
        worker.release() catch unreachable;
    };
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (!fixture.started.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    _ = try service.message(frame, "during-lookup", original.task, 11);
    _ = try service.requestCancel(frame, "cancel-during-lookup", original.task, "stop");
    const peer = try service.submit(frame, "lookup-peer", 4);
    for (0..6) |_| try std.testing.expect(try service.pump(frame) != .work);
    var peer_result = try service.task(frame, peer.receipt.task);
    defer peer_result.deinit();
    try std.testing.expect(peer_result.value.outcome_kind == .completed);
    try std.testing.expect((try service.reconcile(frame, "lookup", original.task, revision, original.occurrence, original.attempt, .lookup)).replayed);
    try std.testing.expectEqual(1, fixture.calls.load(.acquire));
    fixture.hold.store(false, .release);
    try awaitLookup(io, worker);
    const evidence = (worker.result orelse return error.MissingEvidence).acquired;
    inline for (.{ "owner_epoch", "task", "occurrence", "attempt" }) |field| {
        var stale = work;
        @field(stale, field)[0] ^= 1;
        try std.testing.expectError(error.StaleOccurrence, service.acquire(frame, stale, evidence));
    }
    var stale = work;
    stale.recovery.?.id[0] ^= 1;
    try std.testing.expectError(error.StaleOccurrence, service.acquire(frame, stale, evidence));
    try service.acquire(frame, work, evidence);
    try worker.release();
    try std.testing.expectError(error.StaleOccurrence, service.acquire(frame, work, &.{}));
    var capture = try service.reconciliation(frame, original.task, id);
    defer capture.deinit();
    try std.testing.expect(capture.value.outcome == .capture_admitted and capture.value.provenance == .authentic);
    try std.testing.expect(capture.value.evidence != null and capture.value.previous != null);
    try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(frame, original.task, capture.value.evidence.?.digest));
    try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(frame, original.task, capture.value.outcome.capture_admitted.digest));
    for (0..6) |_| try std.testing.expect(try service.pump(frame) != .work);
    var settled = try service.reconciliation(frame, original.task, id);
    defer settled.deinit();
    try std.testing.expect(settled.value.outcome == .reply_settled);
    var charged = try service.task(frame, original.task);
    defer charged.deinit();
    try std.testing.expectEqual(before.value.inference_attempts, charged.value.inference_attempts);
    try std.testing.expectEqual(before.value.inference_request_bytes, charged.value.inference_request_bytes);
    try std.testing.expectEqual(7, charged.value.inference_output_tokens);
    try std.testing.expect(charged.value.cancellation != null);
    try std.testing.expect((try service.reconcile(frame, "lookup", original.task, revision, original.occurrence, original.attempt, .lookup)).replayed);
    _ = try namespace.store.auditRetention(handlers, application.image_identity);
    // Durable admission with no worker survives a restart as interrupted.
    const interrupted = try lookupUnknown(&service, frame, "interrupt-original");
    var interrupt_task = try service.task(frame, interrupted.task);
    defer interrupt_task.deinit();
    const admitted = try service.reconcile(frame, "interrupted-lookup", interrupted.task, interrupt_task.value.revision, interrupted.occurrence, interrupted.attempt, .lookup);
    const pending_archive = try std.fmt.allocPrint(frame, "{s}/pending.agnx", .{buffer[0..length]});
    _ = try service.exportCheckpoint(frame, interrupted.task, pending_archive);
    const settled_archive = try std.fmt.allocPrint(frame, "{s}/settled.agnx", .{buffer[0..length]});
    _ = try service.exportCheckpoint(frame, original.task, settled_archive);
    try service.close(frame);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    for ([_][]const u8{ pending_archive, settled_archive }, 0..) |archive_path, index| {
        var incompatible_leaf = leaf;
        incompatible_leaf.recovery.?.version += 1;
        var incompatible_handlers = try native.Registry.init(a, &.{ incompatible_leaf, native.question(u32, u32, .{ .identity = "fair.question.v1", .resource_role = "user", .answer_schema_id = "fair.answer.v1" }, FairCapture.present), native.inbox.declaration(u32) });
        defer incompatible_handlers.deinit();
        // Rejection concerns unpublished archive data, not this clean owner.
        // Keep the same registry while proving ordinary work remains admitted.
        {
            const rejected_target = try std.fmt.allocPrint(frame, "{s}/rejected-{d}", .{ buffer[0..length], index });
            var rejected_namespace = try native.Namespace.open(a, io, rejected_target);
            defer rejected_namespace.close() catch unreachable;
            var rejected = try native.tasks.Service(FairTypes).init(a, io, &rejected_namespace, assets, &application, incompatible_handlers, profile);
            defer rejected.close(frame) catch unreachable;
            const before_import = rejected_namespace.store.head;
            try std.testing.expectError(error.CorruptState, rejected.importCheckpoint(frame, "import-recovery", archive_path));
            try std.testing.expectEqualDeep(before_import, rejected_namespace.store.head);
            _ = try rejected.submit(frame, "after-rejected-import", 4);
        }
        const target = try std.fmt.allocPrint(frame, "{s}/import-{d}", .{ buffer[0..length], index });
        var copied_namespace = try native.Namespace.open(a, io, target);
        defer copied_namespace.close() catch unreachable;
        var copied = try native.tasks.Service(FairTypes).init(a, io, &copied_namespace, assets, &application, incompatible_handlers, profile);
        defer copied.close(frame) catch unreachable;
        try std.testing.expectError(error.CorruptState, copied.importCheckpoint(frame, "import-recovery", archive_path));
        // Select the compatible registry without reopening the rejected owner.
        // The failed operation ID must remain available for the valid retry.
        copied.handlers = handlers;
        _ = try copied.importCheckpoint(frame, "import-recovery", archive_path);
        try std.testing.expect(try copied.pump(frame) == .idle);
        const task_id = if (index == 0) interrupted.task else original.task;
        const recovery_id = if (index == 0) admitted.receipt.reconciliation.? else id;
        var recovery = try copied.reconciliation(frame, task_id, recovery_id);
        defer recovery.deinit();
        const copied_head = copied_namespace.store.head;
        if (index == 0) {
            try std.testing.expect(recovery.value.outcome == .unresolved and recovery.value.outcome.unresolved == .interrupted);
            const replayed = try copied.reconcile(frame, "interrupted-lookup", task_id, interrupt_task.value.revision, interrupted.occurrence, interrupted.attempt, .lookup);
            try std.testing.expect(replayed.replayed);
            try std.testing.expectEqualDeep(admitted.receipt, replayed.receipt);
            try std.testing.expectError(error.CustodyNotLocal, copied.reconcile(frame, "copied-new-lookup", task_id, interrupt_task.value.revision, interrupted.occurrence, interrupted.attempt, .lookup));
        } else {
            try std.testing.expect(recovery.value.outcome == .reply_settled and recovery.value.provenance == .authentic);
            try std.testing.expectError(error.ArtifactUnavailable, copied.projectedArtifact(frame, task_id, recovery.value.evidence.?.digest));
            const replayed = try copied.reconcile(frame, "lookup", task_id, revision, original.occurrence, original.attempt, .lookup);
            try std.testing.expect(replayed.replayed);
            try std.testing.expectEqualDeep(admission.receipt, replayed.receipt);
            try std.testing.expectError(error.CustodyNotLocal, copied.reconcile(frame, "copied-new-lookup", task_id, revision, original.occurrence, original.attempt, .lookup));
        }
        try std.testing.expectEqualDeep(copied_head, copied_namespace.store.head);
        try @import("native_test_support.zig").expectRetainedReceipt(frame, &copied_namespace, if (index == 0) admitted.receipt else admission.receipt);
        try std.testing.expectError(error.ArtifactUnavailable, copied.projectedArtifact(frame, task_id, recovery.value.original_occurrence.digest));
        _ = try copied_namespace.store.auditRetention(handlers, application.image_identity);
        try std.testing.expectEqual(1, fixture.calls.load(.acquire));
    }
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var lost = try service.reconciliation(frame, interrupted.task, admitted.receipt.reconciliation.?);
    defer lost.deinit();
    try std.testing.expect(lost.value.outcome == .unresolved and lost.value.outcome.unresolved == .interrupted);
    try std.testing.expectEqual(1, fixture.calls.load(.acquire));
    try std.testing.expect((try service.reconcile(frame, "interrupted-lookup", interrupted.task, interrupt_task.value.revision, interrupted.occurrence, interrupted.attempt, .lookup)).replayed);
    try std.testing.expect(try service.pump(frame) == .idle);
    // A new explicit lookup can establish non-invocation. It does not dispatch
    // a new effect; only a later explicit resume could create another attempt.
    var resumed = try service.task(frame, interrupted.task);
    defer resumed.deinit();
    const proof_admission = try service.reconcile(frame, "proof-not-sent", interrupted.task, resumed.value.revision, interrupted.occurrence, interrupted.attempt, .lookup);
    const proof_work = (try service.pump(frame)).work;
    fixture.kind = .not_sent;
    try worker.start(proof_work, service.profile.authority, &fixture);
    try awaitLookup(io, worker);
    try service.completeWork(frame, proof_work, worker.result.?);
    try worker.release();
    var proof = try service.reconciliation(frame, interrupted.task, proof_admission.receipt.reconciliation.?);
    defer proof.deinit();
    try std.testing.expect(proof.value.outcome == .not_sent and proof.value.provenance == .authoritative);
    try std.testing.expect(try service.pump(frame) == .idle);
    _ = try service.requestCancel(frame, "cancel-proven-not-sent", interrupted.task, "stop");
    for (0..6) |_| try std.testing.expect(try service.pump(frame) != .work);
    var cancelled = try service.task(frame, interrupted.task);
    defer cancelled.deinit();
    try std.testing.expect(cancelled.value.outcome_kind == .cancelled);
    try std.testing.expectEqual(1, cancelled.value.inference_attempts);
    _ = try namespace.store.auditRetention(handlers, application.image_identity);
    for ([_][]const u8{ "fabricated", "foreign", "prepared", "profile", "inconclusive", "verifier-unavailable", "rejected", "unavailable", "revoked" }) |scenario| {
        const subject = try lookupUnknown(&service, frame, scenario);
        var subject_task = try service.task(frame, subject.task);
        defer subject_task.deinit();
        const operation_id = try std.fmt.allocPrint(frame, "lookup-{s}", .{scenario});
        const accepted = try service.reconcile(frame, operation_id, subject.task, subject_task.value.revision, subject.occurrence, subject.attempt, .lookup);
        if (std.mem.eql(u8, scenario, "revoked")) {
            service.profile.authority.grants = &.{};
            try std.testing.expect(try service.pump(frame) == .progressed);
            service.profile.authority.grants = &grants;
        } else {
            const selected = (try service.pump(frame)).work;
            if (std.mem.eql(u8, scenario, "unavailable")) {
                // Failure to start/read the lookup is never historical proof
                // that the original invocation did not run.
                try service.notSent(frame, selected);
            } else {
                var record = try protean.contracts.decodeOwned(State.Reconciliation, frame, selected.recovery.?.body);
                defer record.deinit();
                var request = try protocol.decode(protocol.Request, frame, selected.request);
                defer request.deinit();
                var input = native.registry.RecoveryInput.fromReconciliation(record.value, request.value.request_identity, true);
                if (std.mem.eql(u8, scenario, "foreign")) input.task[0] ^= 1;
                if (std.mem.eql(u8, scenario, "prepared")) input.prepared.?.digest[0] ^= 1;
                if (std.mem.eql(u8, scenario, "profile")) input.profile.digest[0] ^= 1;
                const kind: LookupFixture.Kind = if (std.mem.eql(u8, scenario, "verifier-unavailable")) .unavailable else std.meta.stringToEnum(LookupFixture.Kind, scenario) orelse .capture;
                const evidence_bytes = if (std.mem.eql(u8, scenario, "fabricated")) "fabricated receipt" else try LookupFixture.receipt(frame, input, kind);
                try service.acquire(frame, selected, evidence_bytes);
            }
        }
        var result = try service.reconciliation(frame, subject.task, accepted.receipt.reconciliation.?);
        defer result.deinit();
        try std.testing.expect(result.value.outcome == .unresolved);
        const reason = result.value.outcome.unresolved;
        if (std.mem.eql(u8, scenario, "unavailable") or std.mem.eql(u8, scenario, "verifier-unavailable") or std.mem.eql(u8, scenario, "revoked")) {
            try std.testing.expect(reason == .unavailable);
        } else if (std.mem.eql(u8, scenario, "inconclusive")) {
            try std.testing.expect(reason == .inconclusive);
        } else try std.testing.expect(reason == .rejected);
        var unchanged = try service.task(frame, subject.task);
        defer unchanged.deinit();
        try std.testing.expectEqual(.unknown, try service.status(frame, unchanged.value));
        try std.testing.expectEqual(subject_task.value.inference_attempts, unchanged.value.inference_attempts);
        try std.testing.expectEqual(subject_task.value.inference_request_bytes, unchanged.value.inference_request_bytes);
        try std.testing.expectEqual(0, unchanged.value.inference_output_tokens);
        try std.testing.expect((try service.reconcile(frame, operation_id, subject.task, subject_task.value.revision, subject.occurrence, subject.attempt, .lookup)).replayed);
        if (result.value.evidence) |proof_ref| try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(frame, subject.task, proof_ref.digest));
    }
    try std.testing.expectEqual(2, fixture.calls.load(.acquire));
    _ = try namespace.store.auditRetention(handlers, application.image_identity);
    for (LookupFixture.verification_failures) |failure| {
        const operation = try std.fmt.allocPrint(frame, "verify-{s}", .{@errorName(failure)});
        const subject = try lookupUnknown(&service, frame, operation);
        var unknown = try service.task(frame, subject.task);
        defer unknown.deinit();
        const recovery_operation = try std.fmt.allocPrint(frame, "recover-{s}", .{@errorName(failure)});
        const accepted = try service.reconcile(frame, recovery_operation, subject.task, unknown.value.revision, subject.occurrence, subject.attempt, .lookup);
        const selected = (try service.pump(frame)).work;
        const before_failure = namespace.store.head;
        try std.testing.expectError(failure, service.acquire(frame, selected, @errorName(failure)));
        try std.testing.expectEqualDeep(before_failure, namespace.store.head);
        try std.testing.expect(namespace.store.fenced);
        try std.testing.expect(service.work == null);
        try service.close(frame);
        service_live = false;
        try namespace.close();
        namespace_live = false;
        namespace = try native.Namespace.open(a, io, path);
        namespace_live = true;
        // Before owner recovery, the failed verification has committed no
        // completed outcome. Reopen subsequently records interruption, never
        // evidence rejection or an automatic replacement lookup.
        var retained = try protean.contracts.decodeOwned(State.Reconciliation, frame, (try namespace.store.recordBytes(frame, "reconciliation", accepted.receipt.reconciliation.?, subject.task)).?);
        defer retained.deinit();
        try std.testing.expect(retained.value.outcome == .pending);
        service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        service_live = true;
        var interrupted_result = try service.reconciliation(frame, subject.task, accepted.receipt.reconciliation.?);
        defer interrupted_result.deinit();
        try std.testing.expect(interrupted_result.value.outcome == .unresolved and interrupted_result.value.outcome.unresolved == .interrupted);
        var unchanged = try service.task(frame, subject.task);
        defer unchanged.deinit();
        try std.testing.expectEqual(.unknown, try service.status(frame, unchanged.value));
        try std.testing.expectEqual(unknown.value.inference_attempts, unchanged.value.inference_attempts);
        try std.testing.expect((try service.reconcile(frame, recovery_operation, subject.task, unknown.value.revision, subject.occurrence, subject.attempt, .lookup)).replayed);
        try std.testing.expect(try service.pump(frame) == .idle);
    }
    try std.testing.expectEqual(2, fixture.calls.load(.acquire));
    const fenced = try lookupUnknown(&service, frame, "fenced-original");
    var fenced_task = try service.task(frame, fenced.task);
    defer fenced_task.deinit();
    const fenced_admission = try service.reconcile(frame, "fenced-lookup", fenced.task, fenced_task.value.revision, fenced.occurrence, fenced.attempt, .lookup);
    const fenced_work = (try service.pump(frame)).work;
    const sealed = namespace.store.head;
    namespace.store.fence();
    try std.testing.expectError(error.StorageUnavailable, service.acquire(frame, fenced_work, "late evidence"));
    try std.testing.expectEqualDeep(sealed, namespace.store.head);
    try service.close(frame);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var abandoned = try service.reconciliation(frame, fenced.task, fenced_admission.receipt.reconciliation.?);
    defer abandoned.deinit();
    try std.testing.expect(abandoned.value.outcome == .unresolved and abandoned.value.outcome.unresolved == .interrupted);
    try std.testing.expectError(error.StaleOccurrence, service.acquire(frame, fenced_work, "late evidence"));
    try std.testing.expectEqual(2, fixture.calls.load(.acquire));

    // Authentication does not certify interpretation. Retain the authentic
    // bytes and admission even when the original interpreter rejects them.
    const malformed = try lookupUnknown(&service, frame, "authentic-invalid-capture");
    var malformed_task = try service.task(frame, malformed.task);
    defer malformed_task.deinit();
    const malformed_admission = try service.reconcile(frame, "lookup-invalid-capture", malformed.task, malformed_task.value.revision, malformed.occurrence, malformed.attempt, .lookup);
    const malformed_work = (try service.pump(frame)).work;
    var malformed_record = try protean.contracts.decodeOwned(State.Reconciliation, frame, malformed_work.recovery.?.body);
    defer malformed_record.deinit();
    var malformed_request = try protocol.decode(protocol.Request, frame, malformed_work.request);
    defer malformed_request.deinit();
    const malformed_evidence = try LookupFixture.receiptValue(frame, native.registry.RecoveryInput.fromReconciliation(malformed_record.value, malformed_request.value.request_identity, true), .capture, 98);
    try service.acquire(frame, malformed_work, malformed_evidence);
    try std.testing.expect(try service.pump(frame) == .waiting);
    var rejected_capture = try service.reconciliation(frame, malformed.task, malformed_admission.receipt.reconciliation.?);
    defer rejected_capture.deinit();
    try std.testing.expect(rejected_capture.value.outcome == .capture_admitted and rejected_capture.value.provenance == .authentic);
    const rejected_archive = try std.fmt.allocPrint(frame, "{s}/authentic-invalid.agnx", .{buffer[0..length]});
    _ = try service.exportCheckpoint(frame, malformed.task, rejected_archive);
    try service.close(frame);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    namespace = try native.Namespace.open(a, io, path);
    namespace_live = true;
    service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var retained_capture = try service.reconciliation(frame, malformed.task, malformed_admission.receipt.reconciliation.?);
    defer retained_capture.deinit();
    try std.testing.expectEqualDeep(rejected_capture.value.outcome, retained_capture.value.outcome);
    var retry_capture = try service.task(frame, malformed.task);
    defer retry_capture.deinit();
    _ = try service.resumeTask(frame, "retry-invalid-capture", malformed.task, retry_capture.value.revision);
    try std.testing.expect(try service.pump(frame) == .waiting);
    var still_unsettled = try service.task(frame, malformed.task);
    defer still_unsettled.deinit();
    try std.testing.expectEqual(0, still_unsettled.value.inference_output_tokens);
    try std.testing.expectEqual(1, still_unsettled.value.inference_attempts);
    _ = try namespace.store.auditRetention(handlers, application.image_identity);

    // Exercise both sides of the durable boundary at each recovery publication.
    // A rejected write leaves the previous record; a failed seal leaves the
    // entire committed successor, which reopen must recover without new I/O.
    const Stage = enum { admission, capture, settlement };
    const Fault = enum { write, commit, seal };
    for ([_]Stage{ .admission, .capture, .settlement }) |stage| {
        for ([_]Fault{ .write, .commit, .seal }) |fault| {
            const seal_failure = fault == .seal;
            const label = try std.fmt.allocPrint(frame, "{s}-{s}", .{ @tagName(stage), @tagName(fault) });
            const subject = try lookupUnknown(&service, frame, label);
            var subject_task = try service.task(frame, subject.task);
            defer subject_task.deinit();
            const operation_id = try std.fmt.allocPrint(frame, "lookup-{s}", .{label});
            var recovery_id: ?State.Digest = null;
            var selected: ?native.tasks.Work = null;
            var acquired: ?[]const u8 = null;
            if (stage != .admission) {
                const accepted = try service.reconcile(frame, operation_id, subject.task, subject_task.value.revision, subject.occurrence, subject.attempt, .lookup);
                recovery_id = accepted.receipt.reconciliation.?;
                selected = (try service.pump(frame)).work;
                var record = try protean.contracts.decodeOwned(State.Reconciliation, frame, selected.?.recovery.?.body);
                defer record.deinit();
                var request = try protocol.decode(protocol.Request, frame, selected.?.request);
                defer request.deinit();
                acquired = try LookupFixture.receipt(frame, native.registry.RecoveryInput.fromReconciliation(record.value, request.value.request_identity, true), .capture);
                if (stage == .settlement) try service.acquire(frame, selected.?, acquired.?);
            }
            const previous_head = namespace.store.head;
            if (seal_failure) {
                try temporary.dir.createDir(io, "lookup/seal.next", .default_dir);
            } else if (fault == .commit) {
                // A deferred foreign-key violation permits every statement
                // and fails the actual COMMIT. The temporary trigger affects
                // only this connection; its insert rolls back with the operation.
                // Use a declared deferred constraint: read-snapshot rollback
                // during admission resets PRAGMA defer_foreign_keys.
                try namespace.store.database.exec(
                    \\CREATE TEMP TABLE recovery_parent(id INTEGER PRIMARY KEY);
                    \\CREATE TEMP TABLE recovery_child(parent INTEGER REFERENCES recovery_parent(id) DEFERRABLE INITIALLY DEFERRED);
                );
                if (stage == .admission) {
                    try namespace.store.database.exec(
                        \\CREATE TEMP TRIGGER recovery_commit_failure AFTER INSERT ON operations BEGIN
                        \\INSERT INTO recovery_child VALUES(1);
                        \\END;
                    );
                } else try namespace.store.database.exec(
                    \\CREATE TEMP TRIGGER recovery_commit_failure AFTER UPDATE OF body ON records WHEN NEW.kind='reconciliation' BEGIN
                    \\INSERT INTO recovery_child VALUES(1);
                    \\END;
                );
            } else try namespace.store.database.exec("PRAGMA query_only=ON;");
            const expected_error = switch (fault) {
                .write => error.StorageUnavailable,
                .commit => error.Constraint,
                .seal => error.UnsafeStatePath,
            };
            switch (stage) {
                .admission => try std.testing.expectError(expected_error, service.reconcile(frame, operation_id, subject.task, subject_task.value.revision, subject.occurrence, subject.attempt, .lookup)),
                .capture => try std.testing.expectError(expected_error, service.acquire(frame, selected.?, acquired.?)),
                .settlement => try std.testing.expectError(expected_error, service.pump(frame)),
            }
            try std.testing.expect(service.work == null);
            if (seal_failure) {
                try std.testing.expectEqual(previous_head.generation + 1, namespace.store.head.generation);
                try std.testing.expect(namespace.store.fenced);
                try std.testing.expectError(error.StorageUnavailable, service.pump(frame));
                try temporary.dir.deleteTree(io, "lookup/seal.next");
            } else {
                try std.testing.expectEqualDeep(previous_head, namespace.store.head);
                if (fault == .commit) {
                    try std.testing.expect(namespace.store.fenced);
                    try std.testing.expectError(error.StorageUnavailable, service.pump(frame));
                    try namespace.store.database.exec("DROP TRIGGER recovery_commit_failure;");
                } else try namespace.store.database.exec("PRAGMA query_only=OFF;");
            }
            try service.close(frame);
            service_live = false;
            try namespace.close();
            namespace_live = false;
            namespace = try native.Namespace.open(a, io, path);
            namespace_live = true;
            service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            service_live = true;
            try std.testing.expect(try service.pump(frame) == .idle);
            var restored_task = try service.task(frame, subject.task);
            defer restored_task.deinit();
            try std.testing.expectEqual(subject_task.value.inference_attempts, restored_task.value.inference_attempts);
            try std.testing.expectEqual(subject_task.value.inference_request_bytes, restored_task.value.inference_request_bytes);
            const settled_reply = stage == .settlement and seal_failure;
            const captured_reply = stage == .settlement or (stage == .capture and seal_failure);
            try std.testing.expectEqual(@as(u64, if (settled_reply) 7 else 0), restored_task.value.inference_output_tokens);
            const occurrence_bytes = (try namespace.store.recordBytes(frame, "occurrence", subject.occurrence, subject.task)).?;
            var restored_occurrence = try protean.contracts.decodeOwned(native.testing.occurrence.Occurrence, frame, occurrence_bytes);
            defer restored_occurrence.deinit();
            if (settled_reply) {
                try std.testing.expect(restored_occurrence.value.state == .settled_reply);
            } else if (captured_reply) {
                try std.testing.expect(restored_occurrence.value.state == .captured);
            } else try std.testing.expect(restored_occurrence.value.state == .unknown);
            const replay = try service.reconcile(frame, operation_id, subject.task, subject_task.value.revision, subject.occurrence, subject.attempt, .lookup);
            try std.testing.expectEqual(stage != .admission or seal_failure, replay.replayed);
            if (recovery_id) |saved_id| try std.testing.expectEqualSlices(u8, &saved_id, &replay.receipt.reconciliation.?);
            var restored_recovery = try service.reconciliation(frame, subject.task, replay.receipt.reconciliation.?);
            defer restored_recovery.deinit();
            if (settled_reply) {
                try std.testing.expect(restored_recovery.value.outcome == .reply_settled);
            } else if (captured_reply) {
                try std.testing.expect(restored_recovery.value.outcome == .capture_admitted);
            } else if (replay.replayed) {
                try std.testing.expect(restored_recovery.value.outcome == .unresolved and restored_recovery.value.outcome.unresolved == .interrupted);
            } else {
                // The failed pre-commit admission left no receipt or work.
                // Its explicit retry is the first admitted lookup.
                try std.testing.expect(restored_recovery.value.outcome == .pending);
                try service.notSent(frame, (try service.pump(frame)).work);
            }
            _ = try namespace.store.auditRetention(handlers, application.image_identity);
            try std.testing.expectEqual(2, fixture.calls.load(.acquire));
        }
    }
}

test "controller microprogress survives park export import and cancellation without publishing a guest cut" {
    try controllerMicroprogress(false);
}

test "controller outer capsule moves without compatibility acquiring an execution obligation" {
    try controllerMicroprogress(true);
}

fn controllerMicroprogress(comptime moving: bool) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const Long = struct {
        pub fn emit(c: protean.Context) !horos.source.Module {
            const b = c.builder;
            const number = try b.scalar(u32);
            const entry = try b.declare(&.{number}, number, &.{}, &.{});
            var result = try b.reference(b.parameter(entry, 0));
            for (0..256) |_| result = try b.primitive(number, .integer_bit_xor, &.{ result, try b.constant(u32, 1) }, 0);
            try b.define(entry, try b.pure(result));
            return b.module(entry, try b.scalar(void));
        }
    };
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = u32, .Result = u32, .Failure = void, .application = Long }));
    defer compiled.deinit();
    const image = try frame.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const manifest = try ownerManifest(frame, image, admitted.identity(), "controller-microprogress");
    const assets: native.discovery.Assets = .{ .image = image, .application = "controller-microprogress", .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "unit", .image_identity = admitted.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "controller-profile", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(frame, "{s}/source", .{path_buffer[0..length]});
    const copy_path = try std.fmt.allocPrint(frame, "{s}/copy", .{path_buffer[0..length]});
    const bundle = try std.fmt.allocPrint(frame, "{s}/outer.bundle", .{path_buffer[0..length]});
    var initial_destination = try native.Namespace.open(a, io, copy_path);
    const destination_identity = initial_destination.identity;
    try initial_destination.close();
    const completed_path = try std.fmt.allocPrint(frame, "{s}/completed-copy", .{path_buffer[0..length]});
    const completed_destination_identity = if (!moving) identity: {
        var completed_destination = try native.Namespace.open(a, io, completed_path);
        const result = completed_destination.identity;
        try completed_destination.close();
        break :identity result;
    } else destination_identity;
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(FairTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var live = true;
    defer if (live) service.close(frame) catch unreachable;
    const submitted = try service.submit(frame, "long-controller", 10);
    var original = try service.task(frame, submitted.receipt.task);
    defer original.deinit();
    try std.testing.expectEqual(.progressed, try service.pump(frame));
    var partial = try service.task(frame, submitted.receipt.task);
    defer partial.deinit();
    try std.testing.expectEqual(original.value.execution_revision, partial.value.execution_revision);
    try std.testing.expectEqualDeep(original.value.checkpoint, partial.value.checkpoint);
    try service.park(frame);
    const root_rows = try namespace.store.archiveIndex(frame, submitted.receipt.task, .{ .digest = @splat(0), .bytes = 0 });
    var outer_ref: ?@TypeOf(original.value.checkpoint) = null;
    for (root_rows.records.items) |row| if (row.kind == .root_operation) {
        outer_ref = row.body;
    };
    try std.testing.expect(outer_ref != null);
    const root_bytes = try namespace.store.object(frame, outer_ref.?, null);
    var root_record = try protean.contracts.decodeOwned(native.testing.state.RootOperation, frame, root_bytes);
    defer root_record.deinit();
    const root_original = root_record.value;
    try std.testing.expect(root_original.pending != null);
    for (0..3) |mutation| {
        var forged = root_original;
        try namespace.store.begin();
        if (mutation == 0) {
            forged.pending.?.control = try namespace.store.putObject(try protean.contracts.encodeOwned(protocol.Control, frame, .resume_yield));
        } else if (mutation == 1) {
            forged.pending.?.guest_quantum += 1;
        } else {
            forged.pending.?.dependencies.items = &.{};
        }
        try namespace.store.putRecord(native.testing.state.RootOperation, "root_operation", forged.id, forged.task, forged);
        try namespace.commit("test.forge-controller-operation");
        try std.testing.expectError(error.InvalidArchive, service.exportCheckpoint(frame, submitted.receipt.task, bundle));
        try namespace.store.begin();
        try namespace.store.putRecord(native.testing.state.RootOperation, "root_operation", root_original.id, root_original.task, root_original);
        try namespace.commit("test.restore-controller-operation");
    }
    const p = native.placement;
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(31));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(32));
    const source_site: p.Site = .{ .key = source_key.public_key.bytes, .namespace = namespace.identity };
    const destination_site: p.Site = .{ .key = destination_key.public_key.bytes, .namespace = destination_identity };
    const subject: p.Subject = .{ .task = submitted.receipt.task };
    try std.testing.expect(service.active == null);
    const compatibility = try service.placementCompatibility(frame, subject);
    try std.testing.expect(service.active == null);
    const resources = try profile.resourceIdentity(frame, application.image_identity);
    const Allow = struct {
        fn disclose(_: *anyopaque, _: p.Subject, _: []const native.testing.state.Reference) !void {}
    };
    const source_peer: p.Peer = .{ .name = "source", .site = source_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(33), .context = undefined, .disclose = Allow.disclose };
    const destination_peer: p.Peer = .{ .name = "destination", .site = destination_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(33), .context = undefined, .disclose = Allow.disclose };
    const source_config: p.Configuration = .{ .signing_key = source_key, .peers = &.{destination_peer} };
    const destination_config: p.Configuration = .{ .signing_key = destination_key, .peers = &.{source_peer} };
    var offer: ?p.Signed(p.Offer) = null;
    if (moving) {
        service.profile.placement = &source_config;
        _ = try service.requestCancel(frame, "cancel-before-controller-transfer", submitted.receipt.task, "interrupted");
        const cut = try service.placementCut(frame, subject);
        try std.testing.expect(cut.outer != null);
        _ = try service.placementFreeze(frame, subject, "destination", cut, @splat(34));
        try std.testing.expect(try service.shutdownIncomplete(frame));
        offer = try service.placementOffer(frame, subject, "destination", bundle);
    } else _ = try service.exportCheckpoint(frame, submitted.receipt.task, bundle);
    try service.close(frame);
    live = false;
    try namespace.close();
    namespace_live = false;
    var destination = try native.Namespace.open(a, io, copy_path);
    defer destination.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(a, .{});
    var destination_profile = profile;
    if (moving) destination_profile.placement = &destination_config;
    var imported = try native.tasks.Service(FairTypes).init(failing.allocator(), io, &destination, assets, &application, handlers, destination_profile);
    defer imported.close(frame) catch unreachable;
    if (moving) {
        const decision = try imported.placementAccept(frame, "outer-accept", "source", offer.?, bundle);
        try std.testing.expect(decision.value.verdict == .accepted);
        var accepted_cut = offer.?.value.intent.cut;
        // Admission records its native receipt without advancing the guest.
        accepted_cut.control += 1;
        try std.testing.expectEqualDeep(accepted_cut, try imported.placementCut(frame, subject));
    } else {
        _ = try imported.importCheckpoint(frame, "outer-import", bundle);
        try std.testing.expectError(error.CustodyNotLocal, imported.requestCancel(frame, "copy-cannot-cancel", submitted.receipt.task, "interrupted"));
        try imported.close(frame);
        try destination.close();
        destination = try native.Namespace.open(a, io, path);
        imported = try native.tasks.Service(FairTypes).init(failing.allocator(), io, &destination, assets, &application, handlers, destination_profile);
    }
    var restored = try imported.task(frame, submitted.receipt.task);
    defer restored.deinit();
    try std.testing.expectEqualDeep(original.value.checkpoint, restored.value.checkpoint);
    _ = try imported.requestCancel(frame, "cancel-during-physical-progress", submitted.receipt.task, "interrupted");
    // Cancellation waits for the already accepted advance, then applies once.
    // The budget bounds this witness, not the lifetime of an admitted task.
    var completed = false;
    for (0..2048) |_| {
        try std.testing.expect(try imported.pump(frame) != .work);
        var current = try imported.task(frame, submitted.receipt.task);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            try std.testing.expect(current.value.cancellation_applied);
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
    _ = try imported.exportCheckpoint(frame, submitted.receipt.task, try std.fmt.allocPrint(frame, "{s}/cancelled.bundle", .{path_buffer[0..length]}));
    if (moving) return;
    const retry = try imported.submit(frame, "retry-cut-publication", 12);
    try std.testing.expectEqual(.progressed, try imported.pump(frame));
    try std.testing.expect(imported.active.?.root_control != null);
    // Stop at the owner boundary immediately after physical completion. The
    // next service turn must publish this cut without pumping the command again.
    while (true) {
        var progress = try imported.active.?.driver.pump(65536);
        defer progress.deinit();
        if (progress == .suspended) continue;
        try std.testing.expect(progress == .event and progress.event.value == .cut);
        break;
    }
    imported.active.?.root_cut_ready = true;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, imported.pump(frame));
    try std.testing.expect(!destination.store.fenced);
    try std.testing.expect(imported.active.?.root_cut_ready);
    try std.testing.expect(imported.active.?.root_control != null);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(.progressed, try imported.pump(frame));
    var retried = try imported.task(frame, retry.receipt.task);
    defer retried.deinit();
    try std.testing.expectEqual(1, retried.value.execution_revision);
    if (imported.active) |active| {
        try std.testing.expect(active.root_control == null);
        try std.testing.expect(!active.root_cut_ready);
    }
    for (0..3) |scenario| {
        try imported.park(frame);
        const operation_id = try std.fmt.allocPrint(frame, "deferred-root-{d}", .{scenario});
        const deferred = try imported.submit(frame, operation_id, 14);
        var builder = horos.source.Builder.init(a);
        defer builder.deinit();
        const number = try builder.scalar(u32);
        const entry = try builder.declare(&.{number}, number, &.{}, &.{});
        try builder.define(entry, try builder.pure(try builder.reference(builder.parameter(entry, 0))));
        const document = try native.source_records.encode(frame, builder.module(entry, try builder.scalar(void)));
        var diagnostic: native.program_construction.Diagnostic = .{};
        const program = try imported.workspaceBuild(frame, try std.fmt.allocPrint(frame, "deferred-build-{d}", .{scenario}), deferred.receipt.task, document, &diagnostic);
        while (imported.active == null or !std.meta.eql(imported.active.?.task, deferred.receipt.task) or imported.active.?.root_control == null) {
            try std.testing.expectEqual(.progressed, try imported.pump(frame));
        }
        while (true) {
            var progress = try imported.active.?.driver.pump(65536);
            defer progress.deinit();
            if (progress == .suspended) continue;
            try std.testing.expect(progress == .event and progress.event.value == .cut);
            break;
        }
        imported.active.?.root_cut_ready = true;
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        try std.testing.expectError(error.OutOfMemory, imported.pump(frame));
        try std.testing.expect(!destination.store.fenced);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        var before = try imported.task(frame, deferred.receipt.task);
        defer before.deinit();
        if (scenario == 2) {
            var completed_peer = destination_peer;
            completed_peer.site.namespace = completed_destination_identity;
            const completed_source_config: p.Configuration = .{ .signing_key = source_key, .peers = &.{completed_peer} };
            imported.profile.placement = &completed_source_config;
            const moving_subject: p.Subject = .{ .task = deferred.receipt.task };
            const cut = try imported.placementCut(frame, moving_subject);
            try std.testing.expectEqual(before.value.execution_revision, cut.execution);
            try std.testing.expect(cut.outer != null);
            _ = try imported.placementFreeze(frame, moving_subject, "destination", cut, @splat(91));
            const moved_path = try std.fmt.allocPrint(frame, "{s}/completed-outer.bundle", .{path_buffer[0..length]});
            const moved_offer = try imported.placementOffer(frame, moving_subject, "destination", moved_path);
            try std.testing.expectEqual(.idle, try imported.pump(frame));
            try imported.close(frame);
            try destination.close();
            destination = try native.Namespace.open(a, io, completed_path);
            var receiver_profile = profile;
            receiver_profile.placement = &destination_config;
            imported = try native.tasks.Service(FairTypes).init(failing.allocator(), io, &destination, assets, &application, handlers, receiver_profile);
            const decision = try imported.placementAccept(frame, "completed-outer-accept", "source", moved_offer, moved_path);
            try std.testing.expect(decision.value.verdict == .accepted);
            try std.testing.expectEqual(.idle, try imported.pump(frame));
            var admitted_task = try imported.task(frame, moving_subject.task);
            defer admitted_task.deinit();
            try std.testing.expectEqual(before.value.execution_revision, admitted_task.value.execution_revision);
            _ = try imported.resumeTask(frame, "completed-outer-resume", moving_subject.task, admitted_task.value.revision);
            try std.testing.expectEqual(.progressed, try imported.pump(frame));
            var received = try imported.task(frame, moving_subject.task);
            defer received.deinit();
            try std.testing.expectEqual(before.value.execution_revision + 1, received.value.execution_revision);
            try std.testing.expect(!destination.store.fenced);
            continue;
        }
        if (scenario == 0) {
            const child = try imported.workspaceStart(frame, "child-after-deferred-root", deferred.receipt.task, program.receipt.workspace.?, try protean.contracts.encodeOwned(u32, frame, 19), .{ .stop = .terminal, .continuation = .owner_scheduled });
            var child_value = try imported.workspaceWork(frame, deferred.receipt.task, child.receipt.workspace.?);
            defer child_value.deinit();
            try std.testing.expect(child_value.value.terminal());
        }
        try imported.park(frame);
        var parked = try imported.task(frame, deferred.receipt.task);
        defer parked.deinit();
        try std.testing.expectEqual(before.value.execution_revision, parked.value.execution_revision);
        try std.testing.expectEqualDeep(before.value.checkpoint, parked.value.checkpoint);
        try std.testing.expectEqual(.parked, parked.value.schedule);
        try std.testing.expectEqual(.idle, try imported.pump(frame));
        _ = try imported.exportCheckpoint(frame, deferred.receipt.task, try std.fmt.allocPrint(frame, "{s}/deferred-{d}.bundle", .{ path_buffer[0..length], scenario }));
        try imported.close(frame);
        try destination.close();
        destination = try native.Namespace.open(a, io, path);
        imported = try native.tasks.Service(FairTypes).init(failing.allocator(), io, &destination, assets, &application, handlers, destination_profile);
        var reopened = try imported.task(frame, deferred.receipt.task);
        defer reopened.deinit();
        _ = try imported.resumeTask(frame, try std.fmt.allocPrint(frame, "deferred-resume-{d}", .{scenario}), deferred.receipt.task, reopened.value.revision);
        try std.testing.expectEqual(.progressed, try imported.pump(frame));
        var published = try imported.task(frame, deferred.receipt.task);
        defer published.deinit();
        try std.testing.expectEqual(before.value.execution_revision + 1, published.value.execution_revision);
        try std.testing.expect(!destination.store.fenced);
    }
}
