const horos_authoring = @import("horos").authoring;
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const kosmos = @import("kosmos");
const expectCleanup = @import("workspace_test_support.zig").expectCleanup;

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
        const leaf = try horos_authoring.interop.operationId(
            c.author,
            try c.external(
                "task-owner.increment.v1",
                try horos_authoring.interop.schema(c.author, number),
                try horos_authoring.interop.schema(c.author, number),
                .read,
            ),
        );
        const question = try horos_authoring.interop.operationId(
            c.author,
            try c.external(
                "task-owner.question.v1",
                try horos_authoring.interop.schema(c.author, number),
                try horos_authoring.interop.schema(c.author, number),
                .read,
            ),
        );
        const inbox = try horos_authoring.interop.operationId(c.author, try Inbox.declare(c));
        const entry = try b.declare(&.{number}, output, &.{ leaf, question, inbox }, &.{});
        const incremented = try b.variable(number);
        const answer = try b.variable(number);
        const message = try b.variable(
            try horos_authoring.interop.schemaId(c.author, try c.schema(Inbox.Reply)),
        );
        const padding = try horos_authoring.interop.valueId(
            c.author,
            try c.literal(T.Padding, .{ .bytes = &@as([64 * 1024]u8, @splat('x')) }),
        );
        const result = try b.primitive(
            output,
            .product,
            &.{ try b.reference(answer), try b.reference(message), padding },
            0,
        );
        try b.define(
            entry,
            try b.bind(
                incremented,
                try b.term(.{ .perform = .{
                    .effect = leaf,
                    .payload = try b.reference(b.parameter(entry, 0)),
                } }),
                try b.bind(
                    answer,
                    try b.term(.{ .perform = .{
                        .effect = question,
                        .payload = try b.reference(incremented),
                    } }),
                    try b.bind(
                        message,
                        try b.term(.{ .perform = .{
                            .effect = inbox,
                            .payload = try b.constant(void, {}),
                        } }),
                        try b.term(.{ .yield_then = try b.pure(result) }),
                    ),
                ),
            ),
        );
        return b.module(entry, try horos_authoring.interop.schemaId(c.author, try c.schema(void)));
    }
};
fn increment(_: native.Context, input: u32) !u32 {
    return input + 1;
}
fn present(ctx: native.Context, input: u32) !native.json.Value {
    try std.testing.expectEqualStrings("fixed-profile", ctx.profile);
    const configured: *const u32 = @ptrCast(
        @alignCast(ctx.environment orelse return error.MissingConfiguration),
    );
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
    fn interpret(
        ctx: native.registry.ProjectionContext,
        payload: []const u8,
        rendered: []const u8,
        raw: []const u8,
    ) !native.registry.Projection {
        interpretations += 1;
        const expected_request = std.mem.eql(u8, rendered, "increment:20");
        const expected_response = std.mem.eql(u8, raw, "raw-response:21");
        if (!expected_request or !expected_response) return error.InvalidCapture;
        var value = try protean.contracts.decodeOwned(u32, ctx.allocator, payload);
        defer value.deinit();
        if (value.value != 20) return error.InvalidCapture;
        const replay = try ctx.allocator.alloc(u8, 2 * 1024 * 1024);
        @memset(replay, 'R');
        const objects = try ctx.allocator.alloc([]const u8, 1);
        objects[0] = replay;
        return .{
            .reply = try protean.contracts.encodeOwned(u32, ctx.allocator, 21),
            .objects = objects,
        };
    }
};

test "durable owner replays work, binds answers, and consumes queued input once" {
    const a = std.testing.allocator;
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = T.Input,
            .Result = T.Output,
            .Failure = T.Failure,
            .application = Application,
        }),
    );
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
const ArchiveFactChange = enum {
    cancellation_omitted,
    cancellation_reason,
    terminal_cancellation_omitted,
    terminal_cancellation_reason,
    checkpoint_cancellation_reason,
    checkpoint_cancellation_bytes,
    terminal_omitted,
    message_not_consumed,
};
fn omitArchiveFact(
    a: std.mem.Allocator,
    io: std.Io,
    shape: anytype,
    task: anytype,
    source: []const u8,
    destination: []const u8,
    change: ArchiveFactChange,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(16 * 1024 * 1024));
    const schema_length = std.mem.readInt(u32, bytes[8..12], .little);
    const manifest_length = std.mem.readInt(u32, bytes[12..16], .little);
    const start = 32 + schema_length;
    const decoded = try protean.contracts.decodeOwned(
        @TypeOf(shape),
        a,
        bytes[start..][0..manifest_length],
    );
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
    const replacement = switch (change) {
        .checkpoint_cancellation_reason,
        .checkpoint_cancellation_bytes,
        => try archiveCheckpointFact(a, &archive, task, &blobs, change),
        .cancellation_omitted,
        .cancellation_reason,
        .terminal_cancellation_omitted,
        .terminal_cancellation_reason,
        => try archiveCancellationFact(a, &archive, task, change),
        .terminal_omitted, .message_not_consumed => try archiveEventFact(
            a,
            &archive,
            task,
            &blobs,
            change,
        ),
    };
    try replaceArchiveBlob(a, &blobs, replacement);
    const references = try a.alloc(Reference, blobs.items.len);
    var body: std.ArrayList(u8) = .empty;
    for (blobs.items, references) |blob, *reference| {
        reference.* = blob.reference;
        try body.appendSlice(a, blob.bytes);
    }
    archive.objects.items = references;
    try writeArchive(a, io, archive, bytes, start, body.items, destination);
}

fn ArchiveReplacement(comptime Reference: type) type {
    return struct { target: *Reference, bytes: []const u8 };
}

const ArchiveWorkspacePublication = struct {
    work: [32]u8,
    execution_revision: u64,
    control_revision: u64,
    observation: [32]u8,
    control: struct {
        policy: struct { stop: enum {
            next_slice,
            next_exposed_event,
            terminal,
        }, continuation: enum {
            explicit_only,
            owner_scheduled,
        } },
        schedule: enum { queued, active, parked },
        blocker: ?enum {
            missing_capability,
            denied,
            capacity,
            missing_artifact,
            incompatible_profile,
            unavailable_environment,
        },
        cancellation: ?protean.contracts.Text(256),
        cancellation_applied: bool,
        outcome: enum { progressed, yielded, requested, completed, failed, cancelled },
        instrument: bool,
        port: bool,
        delivery: ?enum {
            ready,
            dispatching,
            awaiting,
            unknown,
            settled_reply,
            admitted,
            not_sent,
            captured,
        },
    },
};

fn ArchiveFactEvent(comptime Reference: type) type {
    return struct {
        task: [16]u8,
        seq: u64,
        revision: u64,
        kind: enum {
            accepted,
            input_required,
            input_accepted,
            message_queued,
            message_consumed,
            message_not_consumed,
            cancellation_requested,
            parked,
            resumed,
            blocked,
            delivery_unknown,
            completed,
            failed,
            cancelled,
            imported,
            reconciled,
            workspace,
            workspace_progress,
            workspace_read,
            controller,
            controller_requested,
            execution,
        },
        data: protean.contracts.Bytes(48 * 1024),
        workspace_publications: protean.contracts.Vector(ArchiveWorkspacePublication, null),
        workspace_command: ?Reference,
        residual_publications: protean.contracts.Vector(
            native.testing.state.ResidualPublication,
            null,
        ),
        controller_read: ?struct { event_watermark: u64, execution_revision: u64 },
        root_publication: ?struct {
            before: struct { controller: ?[32]u8, checkpoint: [32]u8 },
            after: struct { controller: ?[32]u8, checkpoint: [32]u8 },
        },
    };
}

fn archiveCheckpointFact(
    a: std.mem.Allocator,
    archive: anytype,
    task: anytype,
    blobs: anytype,
    change: ArchiveFactChange,
) !ArchiveReplacement(@TypeOf(archive.task)) {
    try std.testing.expect(
        !task.terminal() and task.cancellation_applied and task.cancellation != null,
    );
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
    nodes[
        @intCast(cursor.id)
    ].record.exit.cancellation = if (change == .checkpoint_cancellation_reason)
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
    return .{
        .bytes = try protean.contracts.encodeOwned(@TypeOf(task), a, changed),
        .target = &archive.task,
    };
}

fn archiveCancellationFact(
    a: std.mem.Allocator,
    archive: anytype,
    task: anytype,
    change: ArchiveFactChange,
) !ArchiveReplacement(@TypeOf(archive.task)) {
    const terminal = switch (change) {
        .terminal_cancellation_omitted, .terminal_cancellation_reason => true,
        else => false,
    };
    try std.testing.expect(
        task.terminal() == terminal and task.cancellation != null and
            task.cancellation_applied == terminal,
    );
    var changed = task;
    const omitted = change == .cancellation_omitted or change == .terminal_cancellation_omitted;
    changed.cancellation = if (omitted) null else .{ .bytes = "unacknowledged replacement" };
    if (terminal and omitted) changed.cancellation_applied = false;
    return .{
        .bytes = try protean.contracts.encodeOwned(@TypeOf(task), a, changed),
        .target = &archive.task,
    };
}

fn archiveEventFact(
    a: std.mem.Allocator,
    archive: anytype,
    task: anytype,
    blobs: anytype,
    change: ArchiveFactChange,
) !ArchiveReplacement(@TypeOf(archive.task)) {
    const Event = ArchiveFactEvent(@TypeOf(archive.task));
    const events = try a.dupe(@TypeOf(archive.events.items[0]), archive.events.items);
    archive.events.items = events;
    var selected: ?ArchiveReplacement(@TypeOf(archive.task)) = null;
    events_loop: for (events) |*row| {
        for (blobs.items) |blob| {
            if (!std.mem.eql(u8, &blob.reference.digest, &row.body.digest)) continue;
            var event = (try protean.contracts.decodeOwned(Event, a, blob.bytes)).value;
            try std.testing.expectEqual(@as(usize, 0), event.workspace_publications.items.len);
            try std.testing.expectEqual(@as(usize, 0), event.residual_publications.items.len);
            if (change == .message_not_consumed) {
                if (event.kind != .message_not_consumed) break;
            } else {
                const terminal = event.kind == .completed or
                    event.kind == .failed or event.kind == .cancelled;
                if (!terminal) break;
                try std.testing.expectEqualStrings(
                    @tagName(task.outcome_kind),
                    @tagName(event.kind),
                );
            }
            event.kind = .blocked;
            event.data.bytes = "{}";
            selected = .{
                .bytes = try protean.contracts.encodeOwned(Event, a, event),
                .target = &row.body,
            };
            break :events_loop;
        }
    }
    try std.testing.expect(selected != null);
    return selected.?;
}

fn replaceArchiveBlob(a: std.mem.Allocator, blobs: anytype, replacement: anytype) !void {
    _ = a;
    const Blob = @TypeOf(blobs.items[0]);
    const previous = replacement.target.*;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(replacement.bytes, &digest, .{});
    replacement.target.* = .{ .digest = digest, .bytes = replacement.bytes.len };
    var replaced = false;
    for (blobs.items) |*blob| if (std.mem.eql(u8, &blob.reference.digest, &previous.digest)) {
        blob.* = .{ .reference = replacement.target.*, .bytes = replacement.bytes };
        replaced = true;
    };
    try std.testing.expect(replaced);
    std.mem.sort(Blob, blobs.items, {}, struct {
        fn less(_: void, left: Blob, right: Blob) bool {
            return std.mem.order(u8, &left.reference.digest, &right.reference.digest) == .lt;
        }
    }.less);
}

fn writeArchive(
    a: std.mem.Allocator,
    io: std.Io,
    archive: anytype,
    bytes: []const u8,
    start: usize,
    body: []const u8,
    destination: []const u8,
) !void {
    const manifest = try protean.contracts.encodeOwned(@TypeOf(archive), a, archive);
    var header: [32]u8 = bytes[0..32].*;
    std.mem.writeInt(u32, header[12..16], @intCast(manifest.len), .little);
    std.mem.writeInt(u32, header[16..20], @intCast(archive.objects.items.len), .little);
    std.mem.writeInt(u64, header[24..32], body.len, .little);
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(a, &header);
    try output.appendSlice(a, bytes[32..start]);
    try output.appendSlice(a, manifest);
    try output.appendSlice(a, body);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = output.items, .flags = .{
        .permissions = .fromMode(0o600),
    } });
}

// Independently rewrite the ordinary archive envelope. This fixture's captured
// increment has one fixed replay object and two fixed adapter byte strings;
// retained canonical requests/replies stay in the object inventory.
fn omitIncrementEvidence(
    a: std.mem.Allocator,
    io: std.Io,
    shape: anytype,
    source: []const u8,
    destination: []const u8,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(64 * 1024 * 1024));
    const schema_length = std.mem.readInt(u32, bytes[8..12], .little);
    const manifest_length = std.mem.readInt(u32, bytes[12..16], .little);
    const start = 32 + schema_length;
    var decoded = try protean.contracts.decodeOwned(
        @TypeOf(shape),
        a,
        bytes[start..][0..manifest_length],
    );
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
    try writeArchive(a, io, archive, bytes, start, body.items, destination);
}

fn checkCaptureImport(
    a: std.mem.Allocator,
    frame: std.mem.Allocator,
    io: std.Io,
    service: *native.tasks.Service(T),
    namespace: *native.Namespace,
    service_live: *bool,
    namespace_live: *bool,
    source_path: []const u8,
    directory: []const u8,
    task_id: [16]u8,
    label: []const u8,
) !void {
    errdefer std.debug.print("capture archive boundary: {s}\n", .{label});
    const assets = service.assets;
    const application = service.application;
    const handlers = service.handlers;
    const profile = service.profile;
    const valid = try std.fmt.allocPrint(frame, "{s}/{s}.bundle", .{ directory, label });
    const invalid = try std.fmt.allocPrint(frame, "{s}/{s}-omitted.bundle", .{ directory, label });
    const target = try std.fmt.allocPrint(frame, "{s}/{s}-import", .{ directory, label });
    _ = try service.exportCheckpoint(frame, task_id, valid);
    const shape = try namespace.store.archiveIndex(frame, task_id, .{
        .digest = @splat(0),
        .bytes = 0,
    });
    try omitIncrementEvidence(frame, io, shape, valid, invalid);
    try service.close(frame);
    service_live.* = false;
    try namespace.close();
    namespace_live.* = false;
    try expectCapturedArchiveImport(
        a,
        frame,
        io,
        target,
        invalid,
        valid,
        assets,
        application,
        handlers,
        profile,
    );
    namespace.* = try native.Namespace.open(a, io, source_path);
    namespace_live.* = true;
    service.* = try native.tasks.Service(T).init(
        a,
        io,
        namespace,
        assets,
        application,
        handlers,
        profile,
    );
    service_live.* = true;
    var task = try service.task(frame, task_id);
    defer task.deinit();
    _ = try service.resumeTask(frame, label, task_id, task.value.revision);
}

fn expectCapturedArchiveImport(
    a: std.mem.Allocator,
    frame: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    invalid: []const u8,
    valid: []const u8,
    assets: native.discovery.Assets,
    application: *const native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
) !void {
    var destination = try native.Namespace.open(a, io, target);
    defer expectCleanup(destination.close());
    var imported = try native.tasks.Service(T).init(
        a,
        io,
        &destination,
        assets,
        application,
        handlers,
        profile,
    );
    defer expectCleanup(imported.close(frame));
    try std.testing.expectError(
        error.InvalidArchive,
        imported.importCheckpoint(frame, "import", invalid),
    );
    const admitted = try imported.importCheckpoint(frame, "import", valid);
    var task = try imported.task(frame, admitted.receipt.task);
    defer task.deinit();
    try std.testing.expectError(
        error.CustodyNotLocal,
        imported.resumeTask(frame, "resume-copied-capture", task.value.id, task.value.revision),
    );
    try std.testing.expectEqual(.idle, try imported.pump(frame));
}

fn rejectRequeuedHistory(
    a: std.mem.Allocator,
    service: *native.tasks.Service(T),
    namespace: *native.Namespace,
    value: anytype,
    message_id: [32]u8,
    directory: []const u8,
) !void {
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
    const message = try namespace.store.putObject(
        try protean.contracts.encodeOwned(Message, a, decoded.value),
    );
    const task = try namespace.store.putObject(
        try protean.contracts.encodeOwned(@TypeOf(value), a, requeued),
    );
    // This witness changes lifecycle facts, not reference closure. Keep the
    // exact original dependencies so export reaches the lifecycle validator.
    namespace.store.invalidateIntegrity();
    try copyArchiveDependencies(&namespace.store, original_message, message);
    try copyArchiveDependencies(&namespace.store, original_task, task);
    try namespace.store.database.run(
        "UPDATE records SET body=? WHERE kind='message' AND id=?",
        &.{ .{ .blob = &message.digest }, .{ .blob = &message_id } },
    );
    try namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{
        .blob = &task.digest,
    }, .{ .blob = &value.id } });
    // Export intentionally requires a settled transaction. Commit the synthetic
    // corruption, then restore the exact original references after the check.
    try namespace.commit("test.requeued-history");
    defer expectCleanup(
        restoreConsumedHistory(namespace, value.id, message_id, original_message, original_task),
    );
    try std.testing.expectError(error.InvalidArchive, service.exportCheckpoint(a, value.id, path));
}

fn copyArchiveDependencies(
    store: anytype,
    old: native.testing.state.Reference,
    new: native.testing.state.Reference,
) !void {
    try store.database.run(
        "INSERT OR IGNORE INTO dependencies SELECT ?,?,child,child_bytes " ++
            "FROM dependencies WHERE parent=?",
        &.{
            .{ .blob = &new.digest },
            .{ .integer = @intCast(new.bytes) },
            .{ .blob = &old.digest },
        },
    );
}

fn restoreConsumedHistory(
    namespace: *native.Namespace,
    task_id: [16]u8,
    message_id: [32]u8,
    original_message: native.testing.state.Reference,
    original_task: native.testing.state.Reference,
) !void {
    try namespace.store.begin();
    namespace.store.invalidateIntegrity();
    try namespace.store.database.run(
        "UPDATE records SET body=? WHERE kind='message' AND id=?",
        &.{ .{ .blob = &original_message.digest }, .{ .blob = &message_id } },
    );
    try namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{
        .blob = &original_task.digest,
    }, .{ .blob = &task_id } });
    try namespace.commit("test.restore-consumed-history");
}

fn ownerRecovery(captured: bool, image: []const u8) !void {
    var fixture: OwnerRecoveryFixture = .{ .captured = captured, .image = image };
    defer fixture.deinit();
    errdefer std.debug.print("owner recovery phase: {s}\n", .{fixture.phase});
    try fixture.initAssets();
    try fixture.initHandlers();
    try fixture.initProfile();
    try fixture.initOwner();
    try fixture.submit();
    try fixture.acquire();
    try fixture.restart();
    try fixture.resumeOwner();
    try fixture.captureBoundaries();
    try fixture.answer();
    try fixture.settleInbox();
    try fixture.completedValue();
    try fixture.answerReplay();
    try fixture.publicResult();
    try fixture.resultBytes();
    try fixture.publicHistory();
    try fixture.disclosure();
    try fixture.cancelUnsent();
    try fixture.cancelledArchive();
    try fixture.captureFailures();
    try fixture.eventPagination();
}

const OwnerRecoveryFixture = struct {
    captured: bool,
    image: []const u8,
    phase: []const u8 = "owner admission/restart",
    a: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    admitted_image: *horos.data.program_image.Admitted = undefined,
    manifest: []u8 = undefined,
    assets: native.discovery.Assets = undefined,
    application: native.discovery.Application = undefined,
    handlers: native.Registry = undefined,
    grants: [3]native.registry.Grant = undefined,
    configured: u32 = undefined,
    resource_set: [65][]const u8 = undefined,
    profile: native.tasks.Profile = undefined,
    temporary: std.testing.TmpDir = undefined,
    path_buffer: [4096]u8 = undefined,
    length: usize = undefined,
    path: []u8 = undefined,
    namespace: native.Namespace = undefined,
    namespace_live: bool = false,
    service: native.tasks.Service(T) = undefined,
    service_live: bool = false,
    arena: std.heap.ArenaAllocator = undefined,
    frame: std.mem.Allocator = undefined,
    accepted: native.tasks.Admission = undefined,
    queued_message: native.tasks.Admission = undefined,
    retried: bool = undefined,
    question: protean.contracts.Decoded(native.testing.state.Question) = undefined,
    answered: native.tasks.Admission = undefined,
    completed: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    decoded: protean.contracts.Decoded(T.Output) = undefined,
    client: native.client.Client(T) = undefined,
    params: native.json.Value = undefined,
    read_params: native.json.Value = undefined,
    result_reference: native.json.Value = undefined,
    history: []native.json.Value = undefined,
    no_send: native.tasks.Admission = undefined,
    cancelled: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    cancelled_archive: []const u8 = undefined,
    omitted_message: []const u8 = undefined,
    admitted_image_live: bool = false,
    manifest_live: bool = false,
    application_live: bool = false,
    handlers_live: bool = false,
    temporary_live: bool = false,
    path_live: bool = false,
    arena_live: bool = false,
    question_live: bool = false,
    completed_live: bool = false,
    decoded_live: bool = false,
    cancelled_live: bool = false,

    fn initAssets(self: *OwnerRecoveryFixture) !void {
        self.phase = "owner admission/restart";
        self.admitted_image = try horos.data.program_image.Admitted.decode(self.a, self.image);
        self.admitted_image_live = true;
        self.manifest = try ownerManifest(
            self.a,
            self.image,
            self.admitted_image.identity(),
            "owner-unit-test",
        );
        self.manifest_live = true;
        self.assets = .{
            .image = self.image,
            .application = "owner-unit-test",
            .manifest = self.manifest,
        };
        // Asset/discovery admission is independently tested by the subprocess peer.
        self.application = .{
            .arena = .init(self.a),
            .metadata = .null,
            .manifest = .null,
            .manifest_id = "unit",
            .image_identity = self.admitted_image.identity(),
        };
        self.application_live = true;
        self.application.manifest = (try native.json.parse(
            self.application.arena.allocator(),
            self.manifest,
            .{},
        )).value;
    }

    fn initHandlers(self: *OwnerRecoveryFixture) !void {
        var increment_declaration = native.leaf(
            u32,
            u32,
            .{ .identity = "task-owner.increment.v1", .resource_role = "local" },
            increment,
        );
        if (self.captured) {
            increment_declaration.background = true;
            increment_declaration.capture = .{
                .prepare = CapturingIncrement.prepare,
                .acquire = CapturingIncrement.invoke,
                .interpret = CapturingIncrement.interpret,
                .dependencies = native.registry.opaqueProjection,
            };
            increment_declaration.invoke = null;
        }
        self.handlers = try native.Registry.init(self.a, &.{
            increment_declaration,
            native.question(
                u32,
                u32,
                .{
                    .identity = "task-owner.question.v1",
                    .resource_role = "user",
                    .answer_schema_id = "task-owner.answer.v1",
                },
                present,
            ),
            native.inbox.declaration(u32),
        });
        self.handlers_live = true;
    }

    fn initProfile(self: *OwnerRecoveryFixture) !void {
        self.grants = undefined;
        for (&self.grants, self.handlers.entries) |*grant, entry| grant.* = .{
            .identity = entry.declaration.identity,
            .resource_role = entry.declaration.resource_role,
            .resource_identity = self.application.image_identity,
        };
        self.configured = 37;
        self.resource_set = @splat("immutable snapshot bytes");
        self.profile = .{
            .id = "offline",
            .runtime_identity = @splat(42),
            .bytes = "fixed-profile",
            .environment = &self.configured,
            .resources = &self.resource_set,
            .authority = .{ .grants = &self.grants, .principal = "test", .tenant = "test" },
        };
        const oversized_resources: [66][]const u8 = @splat("immutable snapshot bytes");
        var oversized_profile = self.profile;
        oversized_profile.resources = &oversized_resources;
        try std.testing.expect(
            !std.mem.eql(
                u8,
                &(try self.profile.resourceIdentity(self.a, self.application.image_identity)),
                &(try oversized_profile.resourceIdentity(self.a, self.application.image_identity)),
            ),
        );
        for (&self.grants) |*grant| grant.resource_identity = try self.profile.resourceIdentity(
            self.a,
            self.application.image_identity,
        );
    }

    fn initOwner(self: *OwnerRecoveryFixture) !void {
        self.temporary = std.testing.tmpDir(.{});
        self.temporary_live = true;
        self.path_buffer = undefined;
        self.length = try self.temporary.dir.realPath(self.io, &self.path_buffer);
        self.path = try std.fmt.allocPrint(
            self.a,
            "{s}/state",
            .{self.path_buffer[0..self.length]},
        );
        self.path_live = true;
        try self.openOwner();
        self.arena = std.heap.ArenaAllocator.init(self.a);
        self.arena_live = true;
        self.frame = self.arena.allocator();
    }

    fn submit(self: *OwnerRecoveryFixture) !void {
        self.accepted = try self.service.submit(self.frame, "submit", 20);
        const duplicate = try self.service.submit(self.frame, "submit", 20);
        try std.testing.expect(duplicate.replayed);
        try std.testing.expectEqualSlices(u8, &self.accepted.receipt.task, &duplicate.receipt.task);
        try std.testing.expectError(
            error.OperationConflict,
            self.service.submit(self.frame, "submit", 21),
        );
        // Queuing typed input does not execute under the current launch profile.
        // A compatible application can accept it before restoring the task profile.
        self.service.profile.bytes = "another launch profile";
        self.queued_message = try self.service.message(
            self.frame,
            "message",
            self.accepted.receipt.task,
            9,
        );
        self.service.profile.bytes = self.profile.bytes;
    }

    fn acquire(self: *OwnerRecoveryFixture) !void {
        var calls: usize = 0;
        self.retried = false;
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            if (step == .work) {
                if (!try self.acquireIncrement(step.work)) continue;
                calls += 1;
                break;
            }
        }
        try std.testing.expectEqual(1, calls);
        try std.testing.expectEqual(
            @as(u32, if (self.captured) 2 else 1),
            try self.namespace.store.capabilityAttempts(
                self.accepted.receipt.task,
                "task-owner.increment.v1",
            ),
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            try self.namespace.store.capabilityAttempts(
                self.accepted.receipt.task,
                "another-capability",
            ),
        );
    }

    fn acquireIncrement(self: *OwnerRecoveryFixture, work: native.tasks.Work) !bool {
        const ctx: native.Context = .{
            .allocator = self.frame,
            .io = self.io,
            .authority = &self.profile.authority,
            .task_id = "test",
            .profile = self.profile.bytes,
            .environment = self.profile.environment,
        };
        if (self.captured and !self.retried) {
            try self.service.notSent(self.frame, work);
            const archive_path = try std.fmt.allocPrint(
                self.frame,
                "{s}/not-sent.bundle",
                .{self.path_buffer[0..self.length]},
            );
            _ = try self.service.exportCheckpoint(
                self.frame,
                self.accepted.receipt.task,
                archive_path,
            );
            var stopped = try self.service.task(self.frame, self.accepted.receipt.task);
            defer stopped.deinit();
            _ = try self.service.resumeTask(
                self.frame,
                "retry-not-sent",
                self.accepted.receipt.task,
                stopped.value.revision,
            );
            self.retried = true;
            return false;
        }
        var request = try protocol.decode(protocol.Request, self.frame, work.request);
        defer request.deinit();
        const reply = if (work.entry.declaration.capture) |adapter| (try adapter.acquire(
            ctx,
            work.prepared.?,
        )).captured else try work.entry.declaration.invoke.?(
            ctx,
            request.value.binding.payload,
        );
        try self.service.acquire(self.frame, work, reply);
        if (self.captured) {
            const saved = (try self.namespace.store.recordBytes(
                self.frame,
                "capture",
                work.attempt,
                work.task,
            )) orelse return error.MissingRawCapture;
            try std.testing.expect(saved.len != 0);
        }
        return true;
    }

    fn restart(self: *OwnerRecoveryFixture) !void {
        // Restart at durable acquisition, before Kosmos consumes the reply.
        try self.closeOwner();
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        try std.testing.expectEqual(
            @as(u32, if (self.captured) 2 else 1),
            try self.namespace.store.capabilityAttempts(
                self.accepted.receipt.task,
                "task-owner.increment.v1",
            ),
        );
        // Both fixtures preserve the exact image and value types. Independently
        // changing either nominal application or message identity must still reject
        // new input, while retaining access to the old task and its queued message.
        inline for (.{
            MessageContract("another-application", T.message_schema_id),
            MessageContract(T.application_id, "another-message-schema"),
        }) |Other| {
            var other = try native.tasks.Service(Other).init(
                self.a,
                self.io,
                &self.namespace,
                self.assets,
                &self.application,
                self.handlers,
                self.profile,
            );
            defer expectCleanup(other.close(self.frame));
            var visible = try other.task(self.frame, self.accepted.receipt.task);
            defer visible.deinit();
            try std.testing.expectEqual(1, visible.value.messages.items.len);
            const generation = self.namespace.store.head.generation;
            try std.testing.expectError(
                error.IncompatibleProfile,
                other.message(self.frame, "foreign-message", self.accepted.receipt.task, 10),
            );
            try std.testing.expectEqual(generation, self.namespace.store.head.generation);
        }
        self.service = try native.tasks.Service(T).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
    }

    fn resumeOwner(self: *OwnerRecoveryFixture) !void {
        const frozen = try self.service.frozenInputs(self.frame, self.accepted.receipt.task);
        try std.testing.expectEqual(65, frozen.resources.len);
        try std.testing.expectEqualStrings(self.profile.bytes, frozen.profile);
        try std.testing.expectEqualStrings(self.profile.resources[0], frozen.resources[0]);
        try std.testing.expect(try self.service.pump(self.frame) == .idle);
        var status = try self.service.task(self.frame, self.accepted.receipt.task);
        defer status.deinit();
        self.service.profile.runtime_identity = @splat(43);
        try std.testing.expectError(
            error.IncompatibleProfile,
            self.service.resumeTask(
                self.frame,
                "resume",
                self.accepted.receipt.task,
                status.value.revision,
            ),
        );
        self.service.profile.runtime_identity = self.profile.runtime_identity;
        self.service.profile.resources = &.{"changed snapshot bytes"};
        try std.testing.expectError(
            error.IncompatibleProfile,
            self.service.resumeTask(
                self.frame,
                "resume",
                self.accepted.receipt.task,
                status.value.revision,
            ),
        );
        self.service.profile.resources = self.profile.resources;
        _ = try self.service.resumeTask(
            self.frame,
            "resume",
            self.accepted.receipt.task,
            status.value.revision,
        );
    }

    fn captureBoundaries(self: *OwnerRecoveryFixture) !void {
        if (self.captured) {
            // Recover/interpret the raw acquisition, then test the settled boundary
            // before Kosmos consumes it, using the non-inference adapter fixture.
            try std.testing.expect(try self.service.pump(self.frame) == .progressed);
            try checkCaptureImport(
                self.a,
                self.frame,
                self.io,
                &self.service,
                &self.namespace,
                &self.service_live,
                &self.namespace_live,
                self.path,
                self.path_buffer[0..self.length],
                self.accepted.receipt.task,
                "settled-capture",
            );
        }
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            try std.testing.expect(step != .work);
            if (step == .waiting) break;
        }
        if (self.captured) {
            try checkCaptureImport(
                self.a,
                self.frame,
                self.io,
                &self.service,
                &self.namespace,
                &self.service_live,
                &self.namespace_live,
                self.path,
                self.path_buffer[0..self.length],
                self.accepted.receipt.task,
                "historical-capture",
            );
        }
    }

    fn answer(self: *OwnerRecoveryFixture) !void {
        self.question = (try self.service.pendingQuestion(
            self.frame,
            self.accepted.receipt.task,
        )) orelse return error.ExpectedQuestion;
        self.question_live = true;
        try std.testing.expectError(
            error.StaleInteraction,
            self.service.respond(
                self.frame,
                "unknown-question",
                self.accepted.receipt.task,
                @splat(0),
                self.question.value.revision,
                self.question.value.request_digest,
                "task-owner.answer.v1",
                .{ .number_string = "7" },
            ),
        );
        self.answered = try self.service.respond(
            self.frame,
            "answer",
            self.accepted.receipt.task,
            self.question.value.id,
            self.question.value.revision,
            self.question.value.request_digest,
            "task-owner.answer.v1",
            .{ .number_string = "7" },
        );
        try std.testing.expect(!self.answered.replayed);
    }

    fn settleInbox(self: *OwnerRecoveryFixture) !void {
        var imported_inbox = false;
        var checked_consumed_history = false;
        var queue_client: native.client.Client(T) = .{ .service = &self.service };
        var queue_params = native.json.object();
        try native.json.put(
            self.frame,
            &queue_params,
            "task_id",
            native.json.string(
                try self.frame.dupe(u8, &std.fmt.bytesToHex(self.accepted.receipt.task, .lower)),
            ),
        );
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            try std.testing.expect(step != .work);
            if (!imported_inbox) {
                const queue = (try queue_client.call(
                    self.frame,
                    .@"task.status",
                    queue_params,
                )).object.get(
                    "pending_messages",
                ).?.array.items;
                if (queue.len != 0 and std.mem.eql(
                    u8,
                    queue[0].object.get("disposition").?.string,
                    "acquired",
                )) {
                    try self.importAcquiredInbox();
                    imported_inbox = true;
                }
            }
            if (!checked_consumed_history) {
                var saved = try self.service.task(self.frame, self.accepted.receipt.task);
                defer saved.deinit();
                if (saved.value.outcome_kind == .yielded) {
                    try rejectRequeuedHistory(
                        self.frame,
                        &self.service,
                        &self.namespace,
                        saved.value,
                        self.queued_message.receipt.message.?,
                        self.path_buffer[0..self.length],
                    );
                    checked_consumed_history = true;
                }
            }
            if (step == .idle) break;
        }
        try std.testing.expect(checked_consumed_history);
        try std.testing.expect(imported_inbox);
        try std.testing.expectEqual(self.captured, self.retried);
    }

    fn importAcquiredInbox(self: *OwnerRecoveryFixture) !void {
        self.phase = "export acquired inbox";
        const archive_path = try std.fmt.allocPrint(
            self.frame,
            "{s}/acquired-inbox.bundle",
            .{self.path_buffer[0..self.length]},
        );
        _ = try self.service.exportCheckpoint(
            self.frame,
            self.accepted.receipt.task,
            archive_path,
        );
        const imported_path = try std.fmt.allocPrint(
            self.frame,
            "{s}/imported-inbox",
            .{self.path_buffer[0..self.length]},
        );
        // The native SQLite heap admits one connection per process.
        // Park and close the source before opening the copied state.
        try self.closeOwner();
        try self.verifyImportedInbox(archive_path, imported_path);
        self.phase = "reopen original owner";
        try self.openOwner();
        var parked = try self.service.task(self.frame, self.accepted.receipt.task);
        defer parked.deinit();
        _ = try self.service.resumeTask(
            self.frame,
            "resume-after-inbox-export",
            self.accepted.receipt.task,
            parked.value.revision,
        );
        self.phase = "finish original owner";
    }

    fn verifyImportedInbox(
        self: *OwnerRecoveryFixture,
        archive_path: []const u8,
        imported_path: []const u8,
    ) !void {
        self.phase = "open acquired inbox destination";
        var imported_namespace = try native.Namespace.open(self.a, self.io, imported_path);
        defer expectCleanup(imported_namespace.close());
        var imported_service = try native.tasks.Service(T).init(
            self.a,
            self.io,
            &imported_namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        defer expectCleanup(imported_service.close(self.frame));
        self.phase = "import acquired inbox";
        const imported = try imported_service.importCheckpoint(
            self.frame,
            "import-acquired",
            archive_path,
        );
        var saved = try imported_service.task(self.frame, imported.receipt.task);
        defer saved.deinit();
        self.phase = "resume acquired inbox";
        try std.testing.expectError(
            error.CustodyNotLocal,
            imported_service.resumeTask(
                self.frame,
                "resume-imported",
                imported.receipt.task,
                saved.value.revision,
            ),
        );
        try std.testing.expectEqual(.idle, try imported_service.pump(self.frame));
        var copied_message = try protean.contracts.decodeOwned(
            native.testing.state.Message,
            self.frame,
            (try imported_namespace.store.recordBytes(
                self.frame,
                "message",
                self.queued_message.receipt.message.?,
                imported.receipt.task,
            )).?,
        );
        defer copied_message.deinit();
        try std.testing.expectEqual(.acquired, copied_message.value.disposition);
    }

    fn completedValue(self: *OwnerRecoveryFixture) !void {
        self.completed = try self.service.task(self.frame, self.accepted.receipt.task);
        self.completed_live = true;
        try std.testing.expect(self.completed.value.terminal());
        const result = try self.namespace.store.object(
            self.frame,
            self.completed.value.result.?,
            128 * 1024,
        );
        self.decoded = try protean.contracts.decodeOwned(T.Output, self.frame, result);
        self.decoded_live = true;
        try std.testing.expectEqual(7, self.decoded.value.answer);
        try std.testing.expect(self.decoded.value.inbox == .message);
        try std.testing.expectEqual(9, self.decoded.value.inbox.message.value);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(self.queued_message.receipt.message.?, .lower),
            self.decoded.value.inbox.message.id.bytes,
        );
    }

    fn answerReplay(self: *OwnerRecoveryFixture) !void {
        const replayed_answer = try self.service.respond(
            self.frame,
            "answer",
            self.accepted.receipt.task,
            self.question.value.id,
            self.question.value.revision,
            self.question.value.request_digest,
            "task-owner.answer.v1",
            .{ .number_string = "7" },
        );
        try std.testing.expect(replayed_answer.replayed);
        try std.testing.expectEqualSlices(
            u8,
            &self.answered.receipt.id,
            &replayed_answer.receipt.id,
        );
        try std.testing.expectError(
            error.AnswerConflict,
            self.service.respond(
                self.frame,
                "answer-conflict",
                self.accepted.receipt.task,
                self.question.value.id,
                self.question.value.revision,
                self.question.value.request_digest,
                "task-owner.answer.v1",
                .{ .number_string = "8" },
            ),
        );
        try std.testing.expect((try self.service.submit(self.frame, "submit", 20)).replayed);
        self.service.profile.bytes = "changed alias target";
        try std.testing.expect((try self.service.submit(self.frame, "submit", 20)).replayed);
        self.service.profile.bytes = self.profile.bytes;
        try std.testing.expectError(
            error.OperationConflict,
            self.service.requestCancel(self.frame, "submit", self.accepted.receipt.task, "cancel"),
        );
    }

    fn publicResult(self: *OwnerRecoveryFixture) !void {
        self.client = .{ .service = &self.service };
        self.params = native.json.object();
        try native.json.put(
            self.frame,
            &self.params,
            "task_id",
            native.json.string(
                try self.frame.dupe(u8, &std.fmt.bytesToHex(self.accepted.receipt.task, .lower)),
            ),
        );
        const public_result = try self.client.call(self.frame, .@"task.result", self.params);
        try std.testing.expect(public_result.object.get("ready").?.bool);
        try std.testing.expectEqualStrings(
            "completed",
            public_result.object.get("status").?.string,
        );
        const public_outcome = public_result.object.get("outcome").?;
        try std.testing.expect(public_outcome.object.get("value") == null);
        self.result_reference = public_outcome.object.get("value_ref").?;
    }

    fn resultBytes(self: *OwnerRecoveryFixture) !void {
        self.read_params = native.json.object();
        try native.json.put(
            self.frame,
            &self.read_params,
            "task_id",
            self.params.object.get("task_id").?,
        );
        try native.json.put(
            self.frame,
            &self.read_params,
            "artifact_id",
            self.result_reference.object.get("artifact_id").?,
        );
        try native.json.put(self.frame, &self.read_params, "length", native.json.string("32768"));
        var reconstructed: std.array_list.Managed(u8) = .init(self.frame);
        var complete = false;
        while (reconstructed.items.len < 128 * 1024) {
            try native.json.put(
                self.frame,
                &self.read_params,
                "offset",
                native.json.string(
                    try std.fmt.allocPrint(self.frame, "{d}", .{reconstructed.items.len}),
                ),
            );
            const chunk = try self.client.call(self.frame, .@"artifact.read", self.read_params);
            const encoded = chunk.object.get("data").?.string;
            const decoder = std.base64.url_safe_no_pad.Decoder;
            const bytes = try self.frame.alloc(u8, try decoder.calcSizeForSlice(encoded));
            try decoder.decode(bytes, encoded);
            try std.testing.expect(bytes.len > 0);
            try reconstructed.appendSlice(bytes);
            try std.testing.expect(reconstructed.items.len <= 128 * 1024);
            if (chunk.object.get("eof").?.bool) {
                complete = true;
                break;
            }
        }
        try std.testing.expect(complete);
        try std.testing.expectEqualSlices(
            u8,
            try native.json.canonical(
                self.frame,
                try native.values.toJson(T.Output, self.frame, self.decoded.value),
            ),
            reconstructed.items,
        );
    }

    fn publicHistory(self: *OwnerRecoveryFixture) !void {
        if (!self.captured) try largeArtifactBatch(&self.service, self.accepted.receipt.task);
        const events = try self.client.events(self.frame, self.accepted.receipt.task, 0, 128);
        self.history = events.object.get("events").?.array.items;
        var consumed: usize = 0;
        var completed_events: usize = 0;
        for (self.history) |event| {
            const kind = event.object.get("type").?.string;
            if (std.mem.eql(u8, kind, "message_consumed")) consumed += 1;
            if (std.mem.eql(u8, kind, "completed")) completed_events += 1;
        }
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(1, completed_events);
        try std.testing.expectError(
            error.InvalidParams,
            self.client.events(
                self.frame,
                self.accepted.receipt.task,
                self.completed.value.event_high + 1,
                128,
            ),
        );
    }

    fn disclosure(self: *OwnerRecoveryFixture) !void {
        self.service.profile.authority.disclosure = false;
        try std.testing.expectError(
            error.Denied,
            self.client.call(self.frame, .@"task.result", self.params),
        );
        try std.testing.expectError(
            error.Denied,
            self.client.call(self.frame, .@"artifact.read", self.read_params),
        );
        _ = self.read_params.object.swapRemove("task_id");
        try std.testing.expectError(
            error.Denied,
            self.client.call(self.frame, .@"artifact.read", self.read_params),
        );
        try std.testing.expectError(error.Denied, self.service.submit(self.frame, "submit", 20));
        self.service.profile.authority.disclosure = true;
    }

    fn cancelUnsent(self: *OwnerRecoveryFixture) !void {
        self.no_send = try self.service.submit(self.frame, "no-send", 20);
        var dispatched: ?native.tasks.Work = null;
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            if (step == .work) {
                dispatched = step.work;
                break;
            }
        }
        try std.testing.expect(dispatched != null);
        try self.service.notSent(self.frame, dispatched.?);
        _ = try self.service.message(
            self.frame,
            "message-before-cancel",
            self.no_send.receipt.task,
            11,
        );
        try self.checkOverflowQueue();
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-no-send",
            self.no_send.receipt.task,
            "stop before invocation",
        );
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            try std.testing.expect(step != .work);
            if (step == .idle) break;
        }
    }

    fn checkOverflowQueue(self: *OwnerRecoveryFixture) !void {
        for (0..16) |i| _ = try self.service.message(
            self.frame,
            try std.fmt.allocPrint(self.frame, "queued-beyond-old-limit-{d}", .{i}),
            self.no_send.receipt.task,
            @intCast(i),
        );
        var overflow_queue_params = native.json.object();
        try native.json.put(
            self.frame,
            &overflow_queue_params,
            "task_id",
            native.json.string(
                try self.frame.dupe(u8, &std.fmt.bytesToHex(self.no_send.receipt.task, .lower)),
            ),
        );
        const queue_status = try self.client.call(
            self.frame,
            .@"task.status",
            overflow_queue_params,
        );
        try std.testing.expectEqualStrings(
            "17",
            queue_status.object.get("pending_message_count").?.string,
        );
        try std.testing.expectEqual(
            16,
            queue_status.object.get("pending_messages").?.array.items.len,
        );
        try std.testing.expect(queue_status.object.get("pending_messages_truncated").?.bool);
        const queued_history = try self.client.events(
            self.frame,
            self.no_send.receipt.task,
            0,
            128,
        );
        var queue_events: usize = 0;
        for (queued_history.object.get("events").?.array.items) |event| {
            if (std.mem.eql(
                u8,
                event.object.get("type").?.string,
                "message_queued",
            )) queue_events += 1;
        }
        try std.testing.expectEqual(17, queue_events);
    }

    fn cancelledArchive(self: *OwnerRecoveryFixture) !void {
        self.cancelled = try self.service.task(self.frame, self.no_send.receipt.task);
        self.cancelled_live = true;
        try std.testing.expectEqual(.cancelled, self.cancelled.value.outcome_kind);
        self.cancelled_archive = try std.fmt.allocPrint(self.frame, "{s}/not-consumed.bundle", .{
            self.path_buffer[0..self.length],
        });
        _ = try self.service.exportCheckpoint(
            self.frame,
            self.no_send.receipt.task,
            self.cancelled_archive,
        );
        self.omitted_message = try std.fmt.allocPrint(
            self.frame,
            "{s}/not-consumed-omitted.bundle",
            .{self.path_buffer[0..self.length]},
        );
        const cancelled_shape = try self.namespace.store.archiveIndex(
            self.frame,
            self.no_send.receipt.task,
            .{ .digest = @splat(0), .bytes = 0 },
        );
        try omitArchiveFact(
            self.frame,
            self.io,
            cancelled_shape,
            self.cancelled.value,
            self.cancelled_archive,
            self.omitted_message,
            .message_not_consumed,
        );
        try self.closeOwner();
        {
            const target = try std.fmt.allocPrint(self.frame, "{s}/not-consumed-import", .{
                self.path_buffer[0..self.length],
            });
            var destination = try native.Namespace.open(self.a, self.io, target);
            defer expectCleanup(destination.close());
            var imported = try native.tasks.Service(T).init(
                self.a,
                self.io,
                &destination,
                self.assets,
                &self.application,
                self.handlers,
                self.profile,
            );
            defer expectCleanup(imported.close(self.frame));
            try std.testing.expectError(
                error.InvalidArchive,
                imported.importCheckpoint(self.frame, "import-settlement", self.omitted_message),
            );
            const admitted = try imported.importCheckpoint(
                self.frame,
                "import-settlement",
                self.cancelled_archive,
            );
            try std.testing.expectEqualSlices(
                u8,
                &self.no_send.receipt.task,
                &admitted.receipt.task,
            );
        }
        try self.openOwner();
    }

    fn captureFailures(self: *OwnerRecoveryFixture) !void {
        if (!self.captured) return;
        try self.uninterpretableCapture();
        try self.failedCapturePublication();
    }

    fn uninterpretableCapture(self: *OwnerRecoveryFixture) !void {
        const uninterpretable = try self.service.submit(
            self.frame,
            "uninterpretable-capture",
            20,
        );
        var captured_work: ?native.tasks.Work = null;
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            if (step == .work) {
                captured_work = step.work;
                break;
            }
        }
        try std.testing.expect(captured_work != null);
        const invalid_raw = "captured bytes that cannot be interpreted";
        const capture_id = captured_work.?.attempt;
        try self.service.acquire(self.frame, captured_work.?, invalid_raw);
        const interpretations = CapturingIncrement.interpretations;
        try self.closeOwner();
        try self.openOwner();
        try std.testing.expectEqual(interpretations, CapturingIncrement.interpretations);
        var pending_capture = try self.service.task(self.frame, uninterpretable.receipt.task);
        defer pending_capture.deinit();
        _ = try self.service.resumeTask(
            self.frame,
            "interpret-retained-capture",
            uninterpretable.receipt.task,
            pending_capture.value.revision,
        );
        try std.testing.expect(try self.service.pump(self.frame) == .waiting);
        const saved_capture = (try self.namespace.store.recordBytes(
            self.frame,
            "capture",
            capture_id,
            uninterpretable.receipt.task,
        )).?;
        const Ref = @TypeOf(pending_capture.value.profile);
        const Captured = struct {
            task: [16]u8,
            occurrence: [32]u8,
            attempt: [32]u8,
            request: Ref,
            response: ?Ref,
            disposition: enum { complete, definitely_not_sent, unknown },
            projection: ?struct {
                reply: Ref,
                objects: protean.contracts.Vector(Ref, null),
                output_tokens: ?u64,
            },
            reconciliation: ?[32]u8,
        };
        var decoded_capture = try protean.contracts.decodeOwned(
            Captured,
            self.frame,
            saved_capture,
        );
        defer decoded_capture.deinit();
        try std.testing.expect(decoded_capture.value.projection == null);
        try std.testing.expectEqualStrings(
            invalid_raw,
            try self.namespace.store.object(self.frame, decoded_capture.value.response.?, null),
        );
        _ = try self.namespace.store.auditRetention(
            self.handlers,
            self.application.image_identity,
        );
        try std.testing.expect(!self.namespace.store.fenced);
    }

    fn failedCapturePublication(self: *OwnerRecoveryFixture) !void {
        const failing = try self.service.submit(self.frame, "capture-publication-failure", 20);
        var pending: ?native.tasks.Work = null;
        for (0..32) |_| {
            const step = try self.service.pump(self.frame);
            if (step == .work) {
                pending = step.work;
                break;
            }
        }
        try std.testing.expect(pending != null);
        // Freeze the actual database at its current page count. A large raw
        // response needs more pages and must fail before it is acknowledged.
        try self.namespace.store.database.exec("PRAGMA max_page_count=1;");
        const raw = try self.frame.alloc(u8, 1024 * 1024);
        @memset(raw, 0x5a);
        try std.testing.expectError(
            error.Capacity,
            self.service.acquire(self.frame, pending.?, raw),
        );
        try std.testing.expect(self.namespace.store.fenced);
        try self.closeOwner();
        try self.openOwner();
        var unknown = try self.service.task(self.frame, failing.receipt.task);
        defer unknown.deinit();
        try std.testing.expectEqual(
            .unknown,
            try self.service.status(self.frame, unknown.value),
        );
        try std.testing.expectError(
            error.UnsettledOccurrence,
            self.service.resumeTask(
                self.frame,
                "must-not-reissue",
                failing.receipt.task,
                unknown.value.revision,
            ),
        );
        try std.testing.expectEqual(
            1,
            try self.namespace.store.capabilityAttempts(
                failing.receipt.task,
                "task-owner.increment.v1",
            ),
        );
    }

    fn eventPagination(self: *OwnerRecoveryFixture) !void {
        if (!self.captured) {
            try questionReferenceWitness(self.frame, &self.service);
            // Exercise the stored-event projection's byte domain without another
            // application image. Lifecycle production is exercised above; these
            // schema-shaped historical rows isolate pagination and batch framing.
            var large_data = found: {
                for (self.history) |event| {
                    if (std.mem.eql(
                        u8,
                        event.object.get("type").?.string,
                        "input_required",
                    )) break :found event.object.get("data").?;
                }
                return error.ExpectedQuestion;
            };
            const prompt = try self.frame.alloc(u8, 32 * 1024 - 2);
            @memset(prompt, 'q');
            try native.json.put(self.frame, &large_data, "prompt", native.json.string(prompt));
            const event_data = try native.json.canonical(self.frame, large_data);
            var paged = self.completed.value;
            paged.revision += 1;
            try self.namespace.store.begin();
            defer self.namespace.store.rollback();
            for (0..40) |_| {
                paged.event_high += 1;
                try self.namespace.store.putEvent(
                    .{
                        .task = paged.id,
                        .seq = paged.event_high,
                        .revision = paged.revision,
                        .kind = .input_required,
                        .data = .{ .bytes = event_data },
                    },
                );
            }
            try self.namespace.store.putTask(paged, self.completed.value.revision);
            try self.namespace.commit("pagination-domain");
            var cursor = self.completed.value.event_high;
            var seen: usize = 0;
            while (cursor < paged.event_high) {
                var page_arena = std.heap.ArenaAllocator.init(self.a);
                defer page_arena.deinit();
                const pa = page_arena.allocator();
                const page = try self.client.events(pa, paged.id, cursor, 128);
                const next = try native.json.decimal(u64, page.object.get("next_after_seq").?);
                try std.testing.expect(next > cursor);
                seen += page.object.get("events").?.array.items.len;
                var batch: native.json.Value = .{ .array = .init(pa) };
                var id: [128]u8 = @splat(1); // maximum-length, heavily escaped IDs
                for (0..16) |index| {
                    id[0] = @intCast(index + 32);
                    try batch.array.append(
                        try native.protocol.response(
                            pa,
                            native.json.string(try pa.dupe(u8, &id)),
                            page,
                        ),
                    );
                }
                try std.testing.expect(
                    (try native.json.canonical(pa, batch)).len + 1 <= 1024 * 1024,
                );
                cursor = next;
            }
            try std.testing.expectEqual(40, seen);
        }
    }

    fn closeOwner(self: *OwnerRecoveryFixture) !void {
        try self.service.close(self.frame);
        self.service_live = false;
        try self.namespace.close();
        self.namespace_live = false;
    }

    fn openOwner(self: *OwnerRecoveryFixture) !void {
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        self.service = try native.tasks.Service(T).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
    }

    fn deinit(self: *OwnerRecoveryFixture) void {
        if (self.cancelled_live) self.cancelled.deinit();
        if (self.decoded_live) self.decoded.deinit();
        if (self.completed_live) self.completed.deinit();
        if (self.question_live) self.question.deinit();
        if (self.arena_live) self.arena.deinit();
        if (self.service_live) expectCleanup(self.service.close(self.a));
        if (self.namespace_live) expectCleanup(self.namespace.close());
        if (self.path_live) self.a.free(self.path);
        if (self.temporary_live) self.temporary.cleanup();
        if (self.handlers_live) self.handlers.deinit();
        if (self.application_live) self.application.deinit();
        if (self.manifest_live) self.a.free(self.manifest);
        if (self.admitted_image_live) self.admitted_image.deinit();
    }
};

fn questionReferenceWitness(a: std.mem.Allocator, service: *native.tasks.Service(T)) !void {
    var client: native.client.Client(T) = .{ .service = service, .batch = true };
    for ([_]u32{ 41, 42, 43 }) |input| try questionReferenceInput(a, service, &client, input);
}

fn questionReferenceInput(
    a: std.mem.Allocator,
    service: *native.tasks.Service(T),
    client: *native.client.Client(T),
    input: u32,
) !void {
    const admitted = try service.submit(
        a,
        try std.fmt.allocPrint(a, "question-ref-{d}", .{input}),
        input,
    );
    try presentReferenceQuestion(a, service);
    var saved = (try service.pendingQuestion(
        a,
        admitted.receipt.task,
    )) orelse return error.ExpectedQuestion;
    defer saved.deinit();
    var params = native.json.object();
    try native.json.put(
        a,
        &params,
        "task_id",
        native.json.string(try a.dupe(u8, &std.fmt.bytesToHex(admitted.receipt.task, .lower))),
    );
    const status = try client.call(a, .@"task.status", params);
    const question = status.object.get("question").?;
    try std.testing.expect(question.object.get("prompt") == null);
    const ref = question.object.get("prompt_ref").?;
    try checkQuestionReferenceChannels(a, service, client, admitted.receipt.task, status, ref);
    try native.json.put(a, &params, "artifact_id", ref.object.get("artifact_id").?);
    try native.json.put(a, &params, "question_id", ref.object.get("question_id").?);
    try native.json.put(a, &params, "offset", native.json.string("0"));
    try native.json.put(a, &params, "length", native.json.string("32768"));
    try readQuestionReference(a, client, params, input);
    try native.json.put(
        a,
        &params,
        "artifact_id",
        native.json.string(
            try a.dupe(u8, &std.fmt.bytesToHex(saved.value.request.digest, .lower)),
        ),
    );
    try std.testing.expectError(
        error.ArtifactUnavailable,
        client.call(a, .@"artifact.read", params),
    );
    try native.json.put(a, &params, "artifact_id", ref.object.get("artifact_id").?);
    _ = params.object.swapRemove("question_id");
    try std.testing.expectError(
        error.ArtifactUnavailable,
        client.call(a, .@"artifact.read", params),
    );
    _ = try service.requestCancel(
        a,
        try std.fmt.allocPrint(a, "question-ref-cancel-{d}", .{input}),
        admitted.receipt.task,
        "finished witness",
    );
    for (0..16) |_| {
        const step = try service.pump(a);
        try std.testing.expect(step != .work);
        if (step == .idle) break;
    }
}

fn presentReferenceQuestion(a: std.mem.Allocator, service: *native.tasks.Service(T)) !void {
    var calls: usize = 0;
    for (0..16) |_| {
        const step = try service.pump(a);
        if (step == .work) {
            var request = try protocol.decode(protocol.Request, a, step.work.request);
            defer request.deinit();
            const ctx: native.Context = .{
                .allocator = a,
                .io = service.io,
                .authority = &service.profile.authority,
                .task_id = "test",
                .profile = service.profile.bytes,
                .environment = service.profile.environment,
            };
            const reply = try step.work.entry.declaration.invoke.?(
                ctx,
                request.value.binding.payload,
            );
            try service.acquire(a, step.work, reply);
            calls += 1;
        }
        if (step == .waiting or step == .idle) break;
    }
    try std.testing.expectEqual(1, calls);
}

fn checkQuestionReferenceChannels(
    a: std.mem.Allocator,
    service: *native.tasks.Service(T),
    client: *native.client.Client(T),
    task_id: [16]u8,
    status: native.json.Value,
    ref: native.json.Value,
) !void {
    const page = try client.events(a, task_id, 0, 128);
    var found = false;
    for (page.object.get("events").?.array.items) |event| {
        if (!std.mem.eql(u8, event.object.get("type").?.string, "input_required")) continue;
        found = true;
        const data_value = event.object.get("data").?;
        try std.testing.expect(data_value.object.get("prompt") == null);
        try std.testing.expectEqualStrings(
            try native.json.canonical(a, ref),
            try native.json.canonical(a, data_value.object.get("prompt_ref").?),
        );
    }
    try std.testing.expect(found);
    try std.testing.expect(!page.object.get("has_more").?.bool);
    var subscribed: native.client.Client(T) = .{ .service = service };
    subscribed.subscriptions[0] = .{ .id = @splat(9), .task = task_id, .after = 0 };
    var notified = false;
    while (try subscribed.notification(a)) |notification| {
        _ = try native.json.parse(a, try native.json.frame(a, notification), .{});
        const event = notification.object.get("params").?.object.get("event").?;
        if (std.mem.eql(u8, event.object.get("type").?.string, "input_required")) {
            notified = true;
            try std.testing.expectEqualStrings(
                try native.json.canonical(a, ref),
                try native.json.canonical(
                    a,
                    event.object.get("data").?.object.get("prompt_ref").?,
                ),
            );
        }
    }
    try std.testing.expect(notified);
    var replies: native.json.Value = .{ .array = .init(a) };
    for (0..16) |i| try replies.array.append(
        try native.protocol.response(
            a,
            try native.json.number(a, i),
            if (i % 2 == 0) status else page,
        ),
    );
    _ = try native.json.parse(a, try native.json.frame(a, replies), .{});
}

fn readQuestionReference(
    a: std.mem.Allocator,
    client: *native.client.Client(T),
    initial_params: native.json.Value,
    input: u32,
) !void {
    var params = initial_params;
    var decoded: std.ArrayList(u8) = .empty;
    var chunks: usize = 0;
    const chunks_expected: usize = if (input == 43) 5 else 1;
    for (0..chunks_expected) |chunk_index| {
        const chunk = try client.call(a, .@"artifact.read", params);
        const text = chunk.object.get("data").?.string;
        const bytes = try a.alloc(
            u8,
            try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text),
        );
        try std.base64.url_safe_no_pad.Decoder.decode(bytes, text);
        try decoded.appendSlice(a, bytes);
        chunks += 1;
        const eof = chunk.object.get("eof").?.bool;
        try std.testing.expectEqual(chunk_index + 1 == chunks_expected, eof);
        if (eof) break;
        try native.json.put(a, &params, "offset", chunk.object.get("next_offset").?);
    }
    try std.testing.expectEqual(@as(usize, if (input == 43) 5 else 1), chunks);
    // Build expected bytes independently of the JSON encoder/projection.
    const expected = try a.alloc(
        u8,
        if (input == 41) 20_001 else if (input == 42) 68 else 128 * 1024 + 2,
    );
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
    const installed = try installLargeArtifact(service, a, task_id, id, bytes, original_task);
    const reference = installed.reference;
    const original_reference = installed.original_reference;
    defer expectCleanup(removeLargeArtifact(service, task_id, id, original_reference));
    try publishLargeArtifact(service, a, task_id, id, task.value, reference);
    try checkLargeArtifactBudget(service, a, task_id, id, bytes, reference);
}

const ArtifactInstallation = struct {
    reference: native.testing.state.Reference,
    original_reference: native.testing.state.Reference,
};

fn installLargeArtifact(
    service: *native.tasks.Service(T),
    a: std.mem.Allocator,
    task_id: [16]u8,
    id: [32]u8,
    bytes: []const u8,
    original_task: []const u8,
) !ArtifactInstallation {
    const store = &service.namespace.store;
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
    const encoded = try protean.contracts.encodeOwned(
        Artifact,
        a,
        .{ .id = id, .task = task_id, .value = reference, .media_type = .{
            .bytes = "application/json",
        }, .schema_id = .{ .bytes = "artifact-test.json.v1" } },
    );
    defer a.free(encoded);
    const record = try store.putObject(encoded);
    store.invalidateIntegrity();
    try store.database.run("INSERT INTO records VALUES('artifact',?,?,?)", &.{ .{
        .blob = &id,
    }, .{ .blob = &task_id }, .{ .blob = &record.digest } });
    try service.namespace.commit("test.large-artifact");
    return .{ .reference = reference, .original_reference = original_reference };
}

fn removeLargeArtifact(
    service: *native.tasks.Service(T),
    task_id: [16]u8,
    id: [32]u8,
    original_reference: native.testing.state.Reference,
) !void {
    const store = &service.namespace.store;
    try store.begin();
    store.invalidateIntegrity();
    try store.database.run(
        "DELETE FROM records WHERE kind='artifact' AND id=? AND task=?",
        &.{ .{ .blob = &id }, .{ .blob = &task_id } },
    );
    try store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{
        .blob = &original_reference.digest,
    }, .{ .blob = &task_id } });
    try service.namespace.commit("test.remove-large-artifact");
}

fn publishLargeArtifact(
    service: *native.tasks.Service(T),
    a: std.mem.Allocator,
    task_id: [16]u8,
    id: [32]u8,
    task: anytype,
    reference: native.testing.state.Reference,
) !void {
    const store = &service.namespace.store;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const frame = scratch.allocator();
    var client: native.client.Client(T) = .{ .service = service };
    var params = native.json.object();
    try native.json.put(
        frame,
        &params,
        "task_id",
        native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task_id, .lower))),
    );
    try native.json.put(
        frame,
        &params,
        "artifact_id",
        native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
    );
    try native.json.put(frame, &params, "offset", native.json.string("0"));
    try native.json.put(frame, &params, "length", native.json.string("1"));
    try std.testing.expectError(
        error.ArtifactUnavailable,
        client.call(frame, .@"artifact.read", params),
    );
    // A record alone is not publication. This fixture explicitly supplies
    // the task-owned public root, then restores the original after reading.
    var published = task;
    published.result_artifact = id;
    published.client_result = reference;
    const body = try protean.contracts.encodeOwned(@TypeOf(published), frame, published);
    try store.begin();
    defer store.rollback();
    const stored = try store.putObject(body);
    try store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{
        .blob = &stored.digest,
    }, .{ .blob = &task_id } });
    try service.namespace.commit("test.publish-large-artifact");
}

fn checkLargeArtifactBudget(
    service: *native.tasks.Service(T),
    a: std.mem.Allocator,
    task_id: [16]u8,
    id: [32]u8,
    bytes: []const u8,
    reference: native.testing.state.Reference,
) !void {
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
    try readLargeArtifactBatch(service, frame, task_id, id, bytes, reference);
    try std.testing.expect(!budget.failed);
    try std.testing.expect(budget.peak < 48 * 1024 * 1024);
}

fn readLargeArtifactBatch(
    service: *native.tasks.Service(T),
    frame: std.mem.Allocator,
    task_id: [16]u8,
    id: [32]u8,
    bytes: []const u8,
    reference: native.testing.state.Reference,
) !void {
    var client: native.client.Client(T) = .{ .service = service, .batch = true };
    var responses: std.array_list.Managed(native.json.Value) = .init(frame);
    for (0..16) |i| {
        var params = native.json.object();
        try native.json.put(
            frame,
            &params,
            "task_id",
            native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task_id, .lower))),
        );
        try native.json.put(
            frame,
            &params,
            "artifact_id",
            native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
        );
        try native.json.put(
            frame,
            &params,
            "offset",
            native.json.string(try std.fmt.allocPrint(frame, "{d}", .{i * 32768})),
        );
        try native.json.put(frame, &params, "length", native.json.string("32768"));
        const chunk = try client.call(frame, .@"artifact.read", params);
        var decoded: [32768]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(&decoded, chunk.object.get("data").?.string);
        try std.testing.expectEqualSlices(u8, bytes[i * 32768 ..][0..32768], &decoded);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(reference.digest, .lower),
            chunk.object.get("sha256").?.string,
        );
        try std.testing.expectEqual(
            (i + 1) * 32768,
            try native.json.decimal(usize, chunk.object.get("next_offset").?),
        );
        try std.testing.expectEqual(
            bytes.len,
            try native.json.decimal(usize, chunk.object.get("total_bytes").?),
        );
        try std.testing.expect(!chunk.object.get("eof").?.bool);
        try responses.append(
            try native.protocol.response(frame, try native.json.number(frame, i), chunk),
        );
    }
    const wire = try native.json.canonical(frame, .{ .array = responses });
    try std.testing.expect(wire.len + 1 <= (native.protocol.Limits{}).frame_bytes);
}

test "an inbox identity cannot be redeclared with a different message contract" {
    const a = std.testing.allocator;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    var registry = protean.admission.Registry.init(a);
    defer registry.deinit();
    const ctx = try protean.Context.init(&b, &registry);
    try std.testing.expectEqual(
        try horos_authoring.interop.operationId(ctx.author, try Inbox.declare(ctx)),
        try horos_authoring.interop.operationId(ctx.author, try Inbox.declare(ctx)),
    );
    try std.testing.expectError(
        error.InvalidInboxContract,
        protean.inbox.Profile(u64).declare(ctx),
    );
}

fn LargeResultContract(comptime escaped: bool) type {
    return struct {
        pub const application_id = "large-result-test";
        pub const input_schema_id = "large-result.input.v1";
        pub const output_schema_id = "large-result.output.v1";
        pub const failure_schema_id = "large-result.failure.v1";
        pub const message_schema_id = "large-result.message.v1";
        pub const Input = bool;
        pub const Output = if (escaped) protean.contracts.Text(
            1024 * 1024,
        ) else protean.contracts.Bytes(1024 * 1024);
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
            const bytes = try horos_authoring.interop.schemaId(
                c.author,
                try c.schema(Types.Output),
            );
            const entry = try b.declare(&.{
                try horos_authoring.interop.schemaId(c.author, try c.schema(bool)),
            }, bytes, &.{}, &.{});
            const payload = try horos_authoring.interop.valueId(
                c.author,
                try c.literal(
                    Types.Output,
                    if (@hasDecl(Types, "dense"))
                        .{ .items = &Types.payload }
                    else
                        .{ .bytes = &Types.payload },
                ),
            );
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
    var compiled = try protean.compile(
        harness,
        protean.system(.{
            .InitialArgs = bool,
            .Result = Types.Output,
            .Failure = Types.Failure,
            .application = LargeResultProgram(Types),
        }),
    );
    defer compiled.deinit();
    const image = try harness.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer harness.free(image);
    _ = try compiled.encode(harness, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(harness, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(
        harness,
        image,
        admitted_image.identity(),
        "large-result-test",
    );
    defer harness.free(manifest);
    const encoded = try largeResultWire(Types, harness);
    defer harness.free(encoded);
    var expected_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &expected_digest, .{});
    try largeResultRuntime(
        Types,
        harness,
        image,
        manifest,
        admitted_image.identity(),
        encoded,
        expected_digest,
    );
}

fn largeResultWire(comptime Types: type, allocator: std.mem.Allocator) ![]u8 {
    // Independent wire oracle: canonical base64url or one six-byte JSON escape per NUL.
    const dense = @hasDecl(Types, "dense");
    const size = if (dense) Types.payload.len * 2 + 1 else if (Types.escaped_text)
        Types.payload.len * 6 + 2
    else
        std.base64.url_safe_no_pad.Encoder.calcSize(Types.payload.len) + 2;
    const encoded = try allocator.alloc(u8, size);
    errdefer allocator.free(encoded);
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
    } else _ = std.base64.url_safe_no_pad.Encoder.encode(
        encoded[1 .. encoded.len - 1],
        &Types.payload,
    );
    return encoded;
}

const LargeResultEnvironment = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
    path: []const u8,
    directory: []const u8,
    budget: *kosmos.AllocationBudget,
};

const LargeResults = struct { ids: [2][16]u8, artifacts: [2][32]u8 };

fn largeResultRuntime(
    comptime Types: type,
    harness: std.mem.Allocator,
    image: []const u8,
    manifest: []const u8,
    image_identity: [32]u8,
    encoded: []const u8,
    expected_digest: [32]u8,
) !void {
    // Authoring/image bytes above model build-time work and embedded read-only
    // assets. All runtime owners below share the real 64MiB allocation budget.
    var budget: kosmos.AllocationBudget = .{ .parent = harness, .limit = 64 * 1024 * 1024 };
    errdefer std.debug.print("large-result memory: live={d} peak={d} required={d} limit={d}\n", .{
        budget.live,
        budget.peak,
        budget.required,
        budget.limit,
    });
    const a = budget.allocator();
    const io = std.testing.io;
    // SQLite is charged by Namespace.open. Reserve only the absent process
    // worker and input framer, then actually admit the large resource set.
    const process_reservation = try a.alloc(u8, 17 * 1024 * 1024);
    defer a.free(process_reservation);
    const resource = try a.alloc(u8, 16 * 1024 * 1024);
    defer a.free(resource);
    @memset(resource, 'r');
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "large-result-test",
        .manifest = manifest,
    };
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "unit",
        .image_identity = image_identity,
    };
    defer application.deinit();
    const metadata_allocator = application.arena.allocator();
    application.manifest = (try native.json.parse(metadata_allocator, manifest, .{})).value;
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(43),
        .bytes = "large-result-profile",
        .resources = &.{resource},
        .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" },
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    try largeResultOwners(Types, .{
        .allocator = a,
        .io = io,
        .assets = assets,
        .application = &application,
        .handlers = handlers,
        .profile = profile,
        .path = path,
        .directory = path_buffer[0..length],
        .budget = &budget,
    }, encoded, expected_digest, resource.len);
}

fn largeResultOwners(
    comptime Types: type,
    env: LargeResultEnvironment,
    encoded: []const u8,
    expected_digest: [32]u8,
    resource_bytes: usize,
) !void {
    const a = env.allocator;
    const io = env.io;
    const path = env.path;
    const assets = env.assets;
    const application = env.application;
    const handlers = env.handlers;
    const profile = env.profile;
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) expectCleanup(namespace.close());
    var service = try native.tasks.Service(Types).init(
        a,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    var service_live = true;
    defer if (service_live) expectCleanup(service.close(a));
    const results = try largeResultAdmissions(
        Types,
        a,
        &service,
        encoded,
        expected_digest,
        resource_bytes,
    );
    try largeResultResponses(Types, a, &service, env.budget, results, encoded, expected_digest);
    if (Types.escaped_text or @hasDecl(Types, "dense")) try largeResultArchives(
        Types,
        env,
        &service,
        &namespace,
        &service_live,
        &namespace_live,
        results,
        encoded,
        expected_digest,
    );
    try std.testing.expect(!env.budget.failed);
    try std.testing.expect(env.budget.peak <= env.budget.limit);
}

fn largeResultAdmissions(
    comptime Types: type,
    a: std.mem.Allocator,
    service: *native.tasks.Service(Types),
    encoded: []const u8,
    expected_digest: [32]u8,
    resource_bytes: usize,
) !LargeResults {
    const dense = @hasDecl(Types, "dense");
    var ids: [2][16]u8 = undefined;
    var artifacts: [2][32]u8 = undefined;
    for (&ids, &artifacts, 0..) |*id, *artifact, index| {
        {
            var admission = std.heap.ArenaAllocator.init(a);
            defer admission.deinit();
            const submitted = try service.submit(
                admission.allocator(),
                if (index == 0) "complete" else "fail",
                index != 0,
            );
            id.* = submitted.receipt.task;
        }
        {
            var advance = std.heap.ArenaAllocator.init(a);
            defer advance.deinit();
            try std.testing.expect(try service.pump(advance.allocator()) == .progressed);
        }
        var terminal = try service.task(a, id.*);
        defer terminal.deinit();
        const expected: @TypeOf(
            terminal.value.outcome_kind,
        ) = if (index == 0) .completed else .failed;
        try std.testing.expectEqual(expected, terminal.value.outcome_kind);
        try std.testing.expect(terminal.value.checkpoint.bytes <= 1024 * 1024);
        try std.testing.expect(terminal.value.result.?.bytes >= Types.payload.len);
        try std.testing.expectEqual(resource_bytes, terminal.value.resources.items[0].bytes);
        try std.testing.expectEqualSlices(
            u8,
            &expected_digest,
            &terminal.value.client_result.?.digest,
        );
        try std.testing.expectEqual(encoded.len, terminal.value.client_result.?.bytes);
        if (dense) {
            try std.testing.expect(terminal.value.result_artifact == null);
            artifact.* = terminal.value.client_result.?.digest;
        } else artifact.* = terminal.value.result_artifact.?;
    }
    return .{ .ids = ids, .artifacts = artifacts };
}

fn largeResultResponses(
    comptime Types: type,
    a: std.mem.Allocator,
    service: *native.tasks.Service(Types),
    budget: *kosmos.AllocationBudget,
    results: LargeResults,
    encoded: []const u8,
    expected_digest: [32]u8,
) !void {
    var client: native.client.Client(Types) = .{ .service = service, .batch = true };
    var responses_arena = std.heap.ArenaAllocator.init(a);
    defer responses_arena.deinit();
    const frame = responses_arena.allocator();
    const baseline = budget.live;
    var responses: std.array_list.Managed(native.json.Value) = .init(frame);
    for (0..32) |i| {
        const index = i % 2;
        var params = native.json.object();
        try native.json.put(
            frame,
            &params,
            "task_id",
            native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(results.ids[index], .lower))),
        );
        const result = try client.call(frame, .@"task.result", params);
        try responses.append(
            try native.protocol.response(frame, try native.json.number(frame, i), result),
        );
        try std.testing.expect(budget.live - baseline < 512 * 1024);
    }
    // Check every retained response after subsequent calls have reclaimed
    // and reused temporary storage, including both failure and success.
    for (responses.items, 0..) |response, i|
        try expectLargeResultResponse(Types, response, i, results, encoded, expected_digest);
    try std.testing.expect(
        (try native.json.canonical(frame, .{
            .array = responses,
        })).len + 1 <= (native.protocol.Limits{}).frame_bytes,
    );
    _ = try native.json.parse(frame, try native.json.frame(frame, .{
        .array = responses,
    }), .{});
}

fn expectLargeResultResponse(
    comptime Types: type,
    response: native.json.Value,
    i: usize,
    results: LargeResults,
    encoded: []const u8,
    expected_digest: [32]u8,
) !void {
    const index = i % 2;
    const result = response.object.get("result").?;
    try std.testing.expect(result.object.get("ready").?.bool);
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(results.ids[index], .lower),
        result.object.get("task_id").?.string,
    );
    const outcome = result.object.get("outcome").?;
    try std.testing.expectEqualStrings(
        if (index == 0) "completed" else "failed",
        outcome.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        if (index == 0) Types.output_schema_id else Types.failure_schema_id,
        outcome.object.get("schema_id").?.string,
    );
    try std.testing.expect(outcome.object.get("value") == null);
    const reference = outcome.object.get("value_ref").?;
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(results.artifacts[index], .lower),
        reference.object.get("artifact_id").?.string,
    );
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(expected_digest, .lower),
        reference.object.get("sha256").?.string,
    );
    try std.testing.expectEqual(
        encoded.len,
        try native.json.decimal(usize, reference.object.get("bytes").?),
    );
    if (index == 1) try std.testing.expect(outcome.object.get("cleanup_complete").?.bool);
}

fn largeResultArchives(
    comptime Types: type,
    env: LargeResultEnvironment,
    service: *native.tasks.Service(Types),
    namespace: *native.Namespace,
    service_live: *bool,
    namespace_live: *bool,
    results: LargeResults,
    encoded: []const u8,
    expected_digest: [32]u8,
) !void {
    const a = env.allocator;
    const io = env.io;
    const path = env.path;
    const assets = env.assets;
    const application = env.application;
    const handlers = env.handlers;
    const profile = env.profile;
    const directory = env.directory;
    // Reopen the actual persisted terminal tasks before reading/exporting.
    try service.close(a);
    service_live.* = false;
    try namespace.close();
    namespace_live.* = false;
    namespace.* = try native.Namespace.open(a, io, path);
    namespace_live.* = true;
    service.* = try native.tasks.Service(Types).init(
        a,
        io,
        namespace,
        assets,
        application,
        handlers,
        profile,
    );
    service_live.* = true;
    for (results.ids, results.artifacts, 0..) |id, artifact, index| {
        try checkResultChunks(Types, a, service, id, artifact, encoded, expected_digest);
        var export_arena = std.heap.ArenaAllocator.init(a);
        defer export_arena.deinit();
        const archive_path = try std.fmt.allocPrint(
            export_arena.allocator(),
            "{s}/result-{d}.bundle",
            .{ directory, index },
        );
        _ = try service.exportCheckpoint(export_arena.allocator(), id, archive_path);
    }
    try service.close(a);
    service_live.* = false;
    try namespace.close();
    namespace_live.* = false;
    for (results.ids, results.artifacts, 0..) |id, artifact, index|
        try importLargeResult(Types, env, id, artifact, index, encoded, expected_digest);
}

fn importLargeResult(
    comptime Types: type,
    env: LargeResultEnvironment,
    id: [16]u8,
    artifact: [32]u8,
    index: usize,
    encoded: []const u8,
    expected_digest: [32]u8,
) !void {
    const a = env.allocator;
    const io = env.io;
    const directory = env.directory;
    const assets = env.assets;
    const application = env.application;
    const handlers = env.handlers;
    const profile = env.profile;
    var import_arena = std.heap.ArenaAllocator.init(a);
    defer import_arena.deinit();
    const scratch = import_arena.allocator();
    const archive_path = try std.fmt.allocPrint(scratch, "{s}/result-{d}.bundle", .{
        directory,
        index,
    });
    const destination = try std.fmt.allocPrint(scratch, "{s}/imported-{d}", .{
        directory,
        index,
    });
    var imported_namespace = try native.Namespace.open(a, io, destination);
    defer expectCleanup(imported_namespace.close());
    var imported_service = try native.tasks.Service(Types).init(
        a,
        io,
        &imported_namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer expectCleanup(imported_service.close(a));
    {
        var admission = std.heap.ArenaAllocator.init(a);
        defer admission.deinit();
        const receipt = try imported_service.importCheckpoint(
            admission.allocator(),
            "import-result",
            archive_path,
        );
        try std.testing.expectEqualSlices(u8, &id, &receipt.receipt.task);
    }
    try checkResultChunks(
        Types,
        a,
        &imported_service,
        id,
        artifact,
        encoded,
        expected_digest,
    );
}
fn checkResultChunks(
    comptime Types: type,
    a: std.mem.Allocator,
    service: *native.tasks.Service(Types),
    id: [16]u8,
    artifact: [32]u8,
    expected: []const u8,
    expected_digest: [32]u8,
) !void {
    var client: native.client.Client(Types) = .{ .service = service };
    var offset: usize = 0;
    var reached_eof = false;
    while (offset <= expected.len) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = arena.allocator();
        var params = native.json.object();
        try native.json.put(
            frame,
            &params,
            "task_id",
            native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
        );
        try native.json.put(
            frame,
            &params,
            "artifact_id",
            native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(artifact, .lower))),
        );
        try native.json.put(
            frame,
            &params,
            "offset",
            native.json.string(try std.fmt.allocPrint(frame, "{d}", .{offset})),
        );
        try native.json.put(frame, &params, "length", native.json.string("32768"));
        const response = try client.call(frame, .@"artifact.read", params);
        const text = response.object.get("data").?.string;
        const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text);
        var decoded: [32768]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(decoded[0..size], text);
        try std.testing.expectEqualSlices(u8, expected[offset..][0..size], decoded[0..size]);
        offset += size;
        try std.testing.expectEqual(
            offset,
            try native.json.decimal(usize, response.object.get("next_offset").?),
        );
        try std.testing.expectEqual(
            expected.len,
            try native.json.decimal(usize, response.object.get("total_bytes").?),
        );
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(expected_digest, .lower),
            response.object.get("sha256").?.string,
        );
        try std.testing.expect(
            (try native.json.canonical(
                frame,
                response,
            )).len + 1 <= (native.protocol.Limits{}).frame_bytes,
        );
        if (response.object.get("eof").?.bool) {
            reached_eof = true;
            break;
        }
        try std.testing.expect(size != 0);
    }
    try std.testing.expectEqual(expected.len, offset);
    try std.testing.expect(reached_eof);
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
        try b.define(
            body,
            try b.term(.{ .yield_then = try b.term(.{ .fail = try b.constant(void, {}) }) }),
        );
        const exit_info = try horos.source.library.cleanup.exitInfo(b, unit);
        const cleanup = try b.declare(&.{exit_info}, unit, &.{}, &.{});
        try b.define(cleanup, try b.term(.{ .yield_then = try b.term(.{ .conditional = .{
            .condition = try b.reference(b.parameter(entry, 0)),
            .when_true = try b.term(.{ .fail = try b.constant(void, {}) }),
            .when_false = try b.pure(try b.constant(void, {})),
        } }) }));
        const body_type = try b.schema(
            .{
                .internal = .{
                    .computation = .{ .parameters = &.{}, .result = unit, .effects = &.{} },
                },
            },
        );
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
            exit_info,
        }, .result = unit, .effects = &.{}, .capture_bound = &.{boolean} } } });
        try b.define(
            entry,
            try b.term(.{ .protect = .{
                .body = try b.lambda(body, body_type),
                .cleanup = try b.lambda(cleanup, cleanup_type),
            } }),
        );
        return b.module(entry, unit);
    }
};

test "applied cancellation awaits cleanup input without recreating runnable work" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try protean.compile(a, CleanupQuestionSystem);
    defer compiled.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    const image = try frame.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const manifest = try ownerManifest(frame, image, admitted.identity(), "cleanup-question");
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "cleanup-question",
        .manifest = manifest,
    };
    var application: native.discovery.Application = undefined;
    try prepareTestApplication(&application, a, manifest, admitted.identity());
    defer application.deinit();
    var handlers = try cleanupQuestionRegistry(a);
    defer handlers.deinit();
    var grants: [1]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "cleanup-question-profile", .authority = .{
        .grants = &grants,
        .principal = "test",
        .tenant = "test",
    } };
    grants[0] = .{
        .identity = handlers.entries[0].declaration.identity,
        .resource_role = "user",
        .resource_identity = try profile.resourceIdentity(frame, application.image_identity),
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(frame, "{s}/state", .{path_buffer[0..length]});
    var namespace = try native.Namespace.open(a, io, path);
    defer expectCleanup(namespace.close());
    var service = try native.tasks.Service(FairTypes).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer expectCleanup(service.close(frame));
    try exerciseCleanupQuestion(frame, &service);
}

const CleanupQuestionApplication = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const number = try b.scalar(u32);
        const unit = try b.scalar(void);
        const question = try horos_authoring.interop.operationId(
            c.author,
            try c.external("fair.question.v1", try c.schema(u32), try c.schema(u32), .read),
        );
        const entry = try b.declare(&.{number}, number, &.{question}, &.{});
        const body = try b.declare(&.{}, number, &.{question}, &.{});
        try b.define(
            body,
            try b.term(.{ .perform = .{
                .effect = question,
                .payload = try b.constant(u32, 1),
            } }),
        );
        const exit_info = try horos.source.library.cleanup.exitInfo(b, unit);
        const cleanup = try b.declare(&.{exit_info}, unit, &.{question}, &.{});
        const answer = try b.variable(number);
        try b.define(
            cleanup,
            try b.bind(
                answer,
                try b.term(.{ .perform = .{
                    .effect = question,
                    .payload = try b.constant(u32, 2),
                } }),
                try b.pure(try b.constant(void, {})),
            ),
        );
        const body_type = try b.schema(
            .{
                .internal = .{
                    .computation = .{ .parameters = &.{}, .result = number, .effects = &.{
                        question,
                    } },
                },
            },
        );
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
            exit_info,
        }, .result = unit, .effects = &.{question} } } });
        try b.define(
            entry,
            try b.term(.{ .protect = .{
                .body = try b.lambda(body, body_type),
                .cleanup = try b.lambda(cleanup, cleanup_type),
            } }),
        );
        return b.module(entry, unit);
    }
};
const CleanupQuestionSystem = protean.system(.{
    .InitialArgs = u32,
    .Result = u32,
    .Failure = void,
    .application = CleanupQuestionApplication,
});

fn cleanupQuestionRegistry(a: std.mem.Allocator) !native.Registry {
    return native.Registry.init(a, &.{
        native.question(
            u32,
            u32,
            .{
                .identity = "fair.question.v1",
                .resource_role = "user",
                .answer_schema_id = "fair.answer.v1",
            },
            FairCapture.present,
        ),
    });
}

fn exerciseCleanupQuestion(
    frame: std.mem.Allocator,
    service: *native.tasks.Service(FairTypes),
) !void {
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
    _ = try service.respond(
        frame,
        "cleanup-answer",
        submitted.receipt.task,
        cleanup.value.id,
        cleanup.value.revision,
        cleanup.value.request_digest,
        "fair.answer.v1",
        .{ .number_string = "7" },
    );
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

const CleanupArchiveOwners = struct {
    assets: native.discovery.Assets,
    application: *const native.discovery.Application,
    handlers: native.Registry,
    profile: native.tasks.Profile,
};

const CleanupArchives = struct {
    label: []const u8,
    valid: []const u8,
    invalid: []const u8,
    changed_reason: []const u8,
    erased_terminal: []const u8,
    terminal_control: bool,
};

fn checkCleanupArchiveFact(
    a: std.mem.Allocator,
    frame: std.mem.Allocator,
    io: std.Io,
    service: *native.tasks.Service(CleanupTypes),
    namespace: *native.Namespace,
    service_live: *bool,
    namespace_live: *bool,
    source: []const u8,
    directory: []const u8,
    id: [16]u8,
    pending: bool,
) !void {
    const owners: CleanupArchiveOwners = .{
        .assets = service.assets,
        .application = service.application,
        .handlers = service.handlers,
        .profile = service.profile,
    };
    if (pending) _ = try service.requestCancel(frame, "later-cancel", id, "different later reason");
    var task = try service.task(frame, id);
    defer task.deinit();
    const archives = try cleanupArchiveVariants(
        frame,
        io,
        service,
        namespace,
        task.value,
        directory,
        id,
        pending,
    );
    try service.close(frame);
    service_live.* = false;
    try namespace.close();
    namespace_live.* = false;
    try importCleanupArchiveFact(
        a,
        frame,
        io,
        owners,
        archives,
        task.value,
        directory,
        id,
        pending,
    );
    namespace.* = try native.Namespace.open(a, io, source);
    namespace_live.* = true;
    service.* = try native.tasks.Service(CleanupTypes).init(
        a,
        io,
        namespace,
        owners.assets,
        owners.application,
        owners.handlers,
        owners.profile,
    );
    service_live.* = true;
    if (pending) try resumePendingCleanupOriginal(frame, service, id);
}

fn cleanupArchiveVariants(
    frame: std.mem.Allocator,
    io: std.Io,
    service: *native.tasks.Service(CleanupTypes),
    namespace: *native.Namespace,
    original: anytype,
    directory: []const u8,
    id: [16]u8,
    pending: bool,
) !CleanupArchives {
    const label = if (pending) "pending-control" else @tagName(original.outcome_kind);
    const valid = try std.fmt.allocPrint(frame, "{s}/{s}-valid.bundle", .{ directory, label });
    const invalid = try std.fmt.allocPrint(frame, "{s}/{s}-omitted.bundle", .{ directory, label });
    _ = try service.exportCheckpoint(frame, id, valid);
    const shape = try namespace.store.archiveIndex(frame, id, .{ .digest = @splat(0), .bytes = 0 });
    try omitArchiveFact(
        frame,
        io,
        shape,
        original,
        valid,
        invalid,
        if (pending) .cancellation_omitted else .terminal_omitted,
    );
    const changed_reason = try std.fmt.allocPrint(frame, "{s}/{s}-reason.bundle", .{
        directory,
        label,
    });
    if (pending) try omitArchiveFact(
        frame,
        io,
        shape,
        original,
        valid,
        changed_reason,
        .cancellation_reason,
    );
    const erased_terminal = try std.fmt.allocPrint(frame, "{s}/{s}-erased-control.bundle", .{
        directory,
        label,
    });
    const terminal_control = original.terminal() and original.cancellation != null;
    if (terminal_control) try terminalCleanupVariants(
        frame,
        io,
        shape,
        original,
        valid,
        erased_terminal,
        changed_reason,
    );
    return .{
        .label = label,
        .valid = valid,
        .invalid = invalid,
        .changed_reason = changed_reason,
        .erased_terminal = erased_terminal,
        .terminal_control = terminal_control,
    };
}

fn terminalCleanupVariants(
    frame: std.mem.Allocator,
    io: std.Io,
    shape: anytype,
    original: anytype,
    valid: []const u8,
    erased_terminal: []const u8,
    changed_reason: []const u8,
) !void {
    try omitArchiveFact(
        frame,
        io,
        shape,
        original,
        valid,
        erased_terminal,
        .terminal_cancellation_omitted,
    );
    try omitArchiveFact(
        frame,
        io,
        shape,
        original,
        valid,
        changed_reason,
        .terminal_cancellation_reason,
    );
}

fn importCleanupArchiveFact(
    a: std.mem.Allocator,
    frame: std.mem.Allocator,
    io: std.Io,
    owners: CleanupArchiveOwners,
    archives: CleanupArchives,
    original: anytype,
    directory: []const u8,
    id: [16]u8,
    pending: bool,
) !void {
    const target = try std.fmt.allocPrint(
        frame,
        "{s}/{s}-admission",
        .{ directory, archives.label },
    );
    var destination = try native.Namespace.open(a, io, target);
    defer expectCleanup(destination.close());
    var imported = try native.tasks.Service(CleanupTypes).init(
        a,
        io,
        &destination,
        owners.assets,
        owners.application,
        owners.handlers,
        owners.profile,
    );
    defer expectCleanup(imported.close(frame));
    try rejectCleanupArchives(frame, &imported, archives, pending);
    // The failed admission publishes neither namespace state nor the
    // operation ID; the original copy must succeed in the same namespace.
    const admitted = try imported.importCheckpoint(frame, "import-fact", archives.valid);
    try std.testing.expectEqualSlices(u8, &id, &admitted.receipt.task);
    var restored = try imported.task(frame, id);
    defer restored.deinit();
    if (pending) {
        try expectPendingCleanupCopy(frame, &imported, &destination, restored.value, id);
    } else {
        try expectTerminalCleanupCopy(frame, &imported, original, restored.value, id);
    }
}

fn rejectCleanupArchives(
    frame: std.mem.Allocator,
    imported: *native.tasks.Service(CleanupTypes),
    archives: CleanupArchives,
    pending: bool,
) !void {
    try std.testing.expectError(
        error.InvalidArchive,
        imported.importCheckpoint(frame, "import-fact", archives.invalid),
    );
    if (pending) try std.testing.expectError(
        error.InvalidArchive,
        imported.importCheckpoint(frame, "import-fact", archives.changed_reason),
    );
    if (archives.terminal_control) {
        try std.testing.expectError(
            error.InvalidArchive,
            imported.importCheckpoint(frame, "import-fact", archives.erased_terminal),
        );
        try std.testing.expectError(
            error.InvalidArchive,
            imported.importCheckpoint(frame, "import-fact", archives.changed_reason),
        );
    }
}

fn expectPendingCleanupCopy(
    frame: std.mem.Allocator,
    imported: *native.tasks.Service(CleanupTypes),
    destination: *native.Namespace,
    restored: anytype,
    id: [16]u8,
) !void {
    try std.testing.expect(!restored.cancellation_applied);
    try std.testing.expectEqualStrings("test cancellation", restored.cancellation.?.bytes);
    const imported_head = destination.store.head;
    try std.testing.expect(
        (try imported.requestCancel(frame, "cancel-0", id, "test cancellation")).replayed,
    );
    try std.testing.expect(
        (try imported.requestCancel(
            frame,
            "later-cancel",
            id,
            "different later reason",
        )).replayed,
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        imported.requestCancel(frame, "copied-new-cancel", id, "test cancellation"),
    );
    try std.testing.expectError(
        error.OperationConflict,
        imported.requestCancel(frame, "cancel-0", id, "different reason"),
    );
    try std.testing.expectError(
        error.CustodyNotLocal,
        imported.resumeTask(frame, "resume-control", id, restored.revision),
    );
    try std.testing.expectEqual(.idle, try imported.pump(frame));
    try std.testing.expectEqualDeep(imported_head, destination.store.head);
}

fn expectTerminalCleanupCopy(
    frame: std.mem.Allocator,
    imported: *native.tasks.Service(CleanupTypes),
    original: anytype,
    restored: anytype,
    id: [16]u8,
) !void {
    try std.testing.expectEqual(original.outcome_kind, restored.outcome_kind);
    var client: native.client.Client(CleanupTypes) = .{ .service = imported };
    const events = try client.events(frame, id, 0, 128);
    var count: usize = 0;
    for (events.object.get("events").?.array.items) |event| {
        if (std.mem.eql(
            u8,
            @tagName(original.outcome_kind),
            event.object.get("type").?.string,
        )) count += 1;
    }
    try std.testing.expectEqual(1, count);
}

fn resumePendingCleanupOriginal(
    frame: std.mem.Allocator,
    service: *native.tasks.Service(CleanupTypes),
    id: [16]u8,
) !void {
    try std.testing.expect(
        (try service.requestCancel(frame, "cancel-0", id, "test cancellation")).replayed,
    );
    try std.testing.expect(
        (try service.requestCancel(
            frame,
            "later-cancel",
            id,
            "different later reason",
        )).replayed,
    );
    var current = try service.task(frame, id);
    defer current.deinit();
    _ = try service.resumeTask(frame, "resume-pending-original", id, current.value.revision);
}
test "terminal cleanup failures retain shutdown ownership without runnable work" {
    const a = std.testing.allocator;
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = bool,
            .Result = void,
            .Failure = void,
            .application = CleanupApplication,
        }),
    );
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(a, image, admitted_image.identity(), "cleanup-test");
    defer a.free(manifest);
    try terminalCleanupRuntime(a, image, manifest, admitted_image.identity());
}

fn terminalCleanupRuntime(
    a: std.mem.Allocator,
    image: []const u8,
    manifest: []const u8,
    image_identity: [32]u8,
) !void {
    const io = std.testing.io;
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "cleanup-test",
        .manifest = manifest,
    };
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "unit",
        .image_identity = image_identity,
    };
    defer application.deinit();
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "cleanup-profile", .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    var owner: TerminalCleanupOwner = .{
        .a = a,
        .io = io,
        .frame = frame,
        .path = path,
        .directory = path_buffer[0..length],
        .config = .{
            .assets = assets,
            .application = &application,
            .handlers = handlers,
            .profile = profile,
        },
    };
    defer owner.deinit();
    try frozenCleanupWitness(&owner);
    try owner.open();
    var client: native.client.Client(CleanupTypes) = .{ .service = &owner.service };
    // Successful cleanup releases ownership. Failed cleanup stays owned beyond
    // the former fixed sixteen-task quota without adding runnable work.
    for (0..22) |index| try terminalCleanupCase(&owner, &client, index);
    try retainedCleanupOwnership(&owner);
}

const TerminalCleanupOwner = struct {
    a: std.mem.Allocator,
    frame: std.mem.Allocator,
    io: std.Io,
    config: CleanupArchiveOwners,
    path: []const u8,
    directory: []const u8,
    namespace: native.Namespace = undefined,
    service: native.tasks.Service(CleanupTypes) = undefined,
    namespace_live: bool = false,
    service_live: bool = false,

    fn open(owner: *@This()) !void {
        owner.namespace = try native.Namespace.open(owner.a, owner.io, owner.path);
        owner.namespace_live = true;
        owner.service = try native.tasks.Service(CleanupTypes).init(
            owner.a,
            owner.io,
            &owner.namespace,
            owner.config.assets,
            owner.config.application,
            owner.config.handlers,
            owner.config.profile,
        );
        owner.service_live = true;
    }

    fn close(owner: *@This()) !void {
        try owner.service.close(owner.frame);
        owner.service_live = false;
        try owner.namespace.close();
        owner.namespace_live = false;
    }

    fn deinit(owner: *@This()) void {
        if (owner.service_live) expectCleanup(owner.service.close(owner.a));
        if (owner.namespace_live) expectCleanup(owner.namespace.close());
    }
};

fn frozenCleanupWitness(owner: *TerminalCleanupOwner) !void {
    const probe_path = try std.fmt.allocPrint(owner.frame, "{s}/frozen-cleanup", .{
        owner.directory,
    });
    var probe_namespace = try native.Namespace.open(owner.a, owner.io, probe_path);
    defer expectCleanup(probe_namespace.close());
    var probe = try native.tasks.Service(CleanupTypes).init(
        owner.a,
        owner.io,
        &probe_namespace,
        owner.config.assets,
        owner.config.application,
        owner.config.handlers,
        owner.config.profile,
    );
    defer expectCleanup(probe.close(owner.frame));
    const submitted = try probe.submit(owner.frame, "failed-cleanup", true);
    for (0..3) |_| try std.testing.expectEqual(.progressed, try probe.pump(owner.frame));
    var terminal = try probe.task(owner.frame, submitted.receipt.task);
    defer terminal.deinit();
    try std.testing.expectEqual(.failed, terminal.value.outcome_kind);
    try std.testing.expect(terminal.value.cancellation == null);
    try std.testing.expect(!try probe.taskCleanupComplete(owner.frame, terminal.value));
    try std.testing.expectEqual(@as(usize, 1), probe.owned.items.len);
    try std.testing.expectEqual(.idle, try probe.pump(owner.frame));
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(43));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(
        @splat(44),
    );
    const peer = try frozenCleanupPeer(
        owner,
        &probe,
        submitted.receipt.task,
        destination_key.public_key.bytes,
    );
    const config: native.placement.Configuration = .{
        .signing_key = source_key,
        .peers = &.{peer},
    };
    probe.profile.placement = &config;
    try frozenCleanupPlacement(owner, &probe, submitted.receipt.task, terminal.value);
}

fn frozenCleanupPeer(
    owner: *TerminalCleanupOwner,
    probe: *native.tasks.Service(CleanupTypes),
    id: [16]u8,
    destination_key: [32]u8,
) !native.placement.Peer {
    const p = native.placement;
    const subject: p.Subject = .{ .task = id };
    const Allow = struct {
        fn disclose(
            _: *anyopaque,
            _: p.Subject,
            _: []const native.testing.state.Reference,
        ) !void {}
    };
    return .{
        .name = "destination",
        .site = .{ .key = destination_key, .namespace = @splat(45) },
        .native_build = owner.config.profile.runtime_identity,
        .compatibility = try probe.placementCompatibility(owner.frame, subject),
        .resource_binding = try owner.config.profile.resourceIdentity(
            owner.frame,
            owner.config.application.image_identity,
        ),
        .disclosure_policy = @splat(46),
        .context = undefined,
        .disclose = Allow.disclose,
    };
}

fn frozenCleanupPlacement(
    owner: *TerminalCleanupOwner,
    probe: *native.tasks.Service(CleanupTypes),
    id: [16]u8,
    terminal: anytype,
) !void {
    const subject: native.placement.Subject = .{ .task = id };
    try std.testing.expect(try probe.shutdownIncomplete(owner.frame));
    _ = try probe.placementFreeze(
        owner.frame,
        subject,
        "destination",
        try probe.placementCut(owner.frame, subject),
        @splat(47),
    );
    try std.testing.expectEqual(.frozen, (try probe.placementStatus(owner.frame, subject)).?.phase);
    try std.testing.expect(try probe.shutdownIncomplete(owner.frame));
    try std.testing.expect(!try probe.taskCleanupComplete(owner.frame, terminal));
    try std.testing.expectEqual(.idle, try probe.pump(owner.frame));
    try probe.placementAbortUnsent(owner.frame, subject, @splat(47));
    try std.testing.expectEqual(.local, (try probe.placementStatus(owner.frame, subject)).?.phase);
    try std.testing.expect(try probe.shutdownIncomplete(owner.frame));
    try std.testing.expectEqual(.idle, try probe.pump(owner.frame));
}

fn terminalCleanupCase(
    owner: *TerminalCleanupOwner,
    client: *native.client.Client(CleanupTypes),
    index: usize,
) !void {
    const cleanup_fails = index >= 2;
    const cancel = index % 2 == 0;
    const operation = try std.fmt.allocPrint(owner.frame, "cleanup-{d}", .{index});
    const submitted = try owner.service.submit(owner.frame, operation, cleanup_fails);
    try std.testing.expect(try owner.service.pump(owner.frame) == .progressed);
    var yielded = try owner.service.task(owner.frame, submitted.receipt.task);
    defer yielded.deinit();
    try std.testing.expectEqual(.yielded, yielded.value.outcome_kind);
    if (cancel) _ = try owner.service.requestCancel(
        owner.frame,
        try std.fmt.allocPrint(owner.frame, "cancel-{d}", .{index}),
        submitted.receipt.task,
        "test cancellation",
    );
    if (index == 0) try checkCleanupArchiveFact(
        owner.a,
        owner.frame,
        owner.io,
        &owner.service,
        &owner.namespace,
        &owner.service_live,
        &owner.namespace_live,
        owner.path,
        owner.directory,
        submitted.receipt.task,
        true,
    );
    try std.testing.expect(try owner.service.pump(owner.frame) == .progressed);
    var cleaning = try owner.service.task(owner.frame, submitted.receipt.task);
    defer cleaning.deinit();
    try std.testing.expectEqual(.yielded, cleaning.value.outcome_kind);
    try std.testing.expectEqual(cancel, cleaning.value.cancellation_applied);
    if (index == 0) try appliedCleanupArchive(owner, submitted.receipt.task, cleaning.value);
    try std.testing.expect(try owner.service.pump(owner.frame) == .progressed);
    var terminal = try owner.service.task(owner.frame, submitted.receipt.task);
    defer terminal.deinit();
    try expectTerminalCleanup(
        owner,
        client,
        index,
        operation,
        submitted.receipt.task,
        terminal.value,
    );
}

fn appliedCleanupArchive(
    owner: *TerminalCleanupOwner,
    id: [16]u8,
    cleaning: anytype,
) !void {
    // Exercise a real applied-but-unfinished cancellation, not a flag
    // invented by the archive mutator. One SQLite owner at a time.
    const archive_path = try std.fmt.allocPrint(owner.frame, "{s}/cleanup.bundle", .{
        owner.directory,
    });
    _ = try owner.service.exportCheckpoint(owner.frame, id, archive_path);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(owner.config.assets.manifest, &manifest_digest, .{});
    const shape = try owner.namespace.store.archiveIndex(owner.frame, id, .{
        .digest = manifest_digest,
        .bytes = owner.config.assets.manifest.len,
    });
    var forged_archives: [2][]const u8 = undefined;
    for ([_]ArchiveFactChange{
        .checkpoint_cancellation_reason,
        .checkpoint_cancellation_bytes,
    }, &forged_archives) |change, *forged_path| {
        forged_path.* = try std.fmt.allocPrint(owner.frame, "{s}/{s}.bundle", .{
            owner.directory,
            @tagName(change),
        });
        try omitArchiveFact(
            owner.frame,
            owner.io,
            shape,
            cleaning,
            archive_path,
            forged_path.*,
            change,
        );
    }
    try owner.close();
    try importAppliedCleanup(owner, id, archive_path, forged_archives);
    try owner.open();
    _ = try owner.service.resumeTask(
        owner.frame,
        "resume-original-cleanup",
        id,
        cleaning.revision,
    );
}

fn importAppliedCleanup(
    owner: *TerminalCleanupOwner,
    id: [16]u8,
    archive_path: []const u8,
    forged_archives: [2][]const u8,
) !void {
    const destination = try std.fmt.allocPrint(owner.frame, "{s}/imported-cleanup", .{
        owner.directory,
    });
    var imported_namespace = try native.Namespace.open(owner.a, owner.io, destination);
    defer expectCleanup(imported_namespace.close());
    var imported_service = try native.tasks.Service(CleanupTypes).init(
        owner.a,
        owner.io,
        &imported_namespace,
        owner.config.assets,
        owner.config.application,
        owner.config.handlers,
        owner.config.profile,
    );
    defer expectCleanup(imported_service.close(owner.frame));
    for (forged_archives) |forged_path| try std.testing.expectError(
        error.InvalidArchive,
        imported_service.importCheckpoint(owner.frame, "import-cleanup", forged_path),
    );
    const admitted = try imported_service.importCheckpoint(
        owner.frame,
        "import-cleanup",
        archive_path,
    );
    try std.testing.expectEqualSlices(u8, &id, &admitted.receipt.task);
    var imported_task = try imported_service.task(owner.frame, admitted.receipt.task);
    defer imported_task.deinit();
    try std.testing.expect(imported_task.value.cancellation_applied);
    try std.testing.expectError(
        error.CustodyNotLocal,
        imported_service.resumeTask(
            owner.frame,
            "resume-cleanup",
            admitted.receipt.task,
            imported_task.value.revision,
        ),
    );
    try std.testing.expectEqual(.idle, try imported_service.pump(owner.frame));
    try std.testing.expect(
        !try imported_service.taskCleanupComplete(owner.frame, imported_task.value),
    );
}

fn expectTerminalCleanup(
    owner: *TerminalCleanupOwner,
    client: *native.client.Client(CleanupTypes),
    index: usize,
    operation: []const u8,
    id: [16]u8,
    terminal: anytype,
) !void {
    const cleanup_fails = index >= 2;
    const cancel = index % 2 == 0;
    const expected: @TypeOf(terminal.outcome_kind) = if (cancel) .cancelled else .failed;
    try std.testing.expectEqual(expected, terminal.outcome_kind);
    if (index < 2) {
        // Cancellation after a terminal failure is a historical receipt,
        // not a newly pending control. Preserve that valid null-intent case.
        if (!cancel) {
            _ = try owner.service.requestCancel(
                owner.frame,
                "cancel-after-terminal",
                id,
                "too late",
            );
            var after = try owner.service.task(owner.frame, id);
            defer after.deinit();
            try std.testing.expect(after.value.cancellation == null);
        }
        try checkCleanupArchiveFact(
            owner.a,
            owner.frame,
            owner.io,
            &owner.service,
            &owner.namespace,
            &owner.service_live,
            &owner.namespace_live,
            owner.path,
            owner.directory,
            id,
            false,
        );
    }
    try std.testing.expectEqual(
        !cleanup_fails,
        try owner.service.taskCleanupComplete(owner.frame, terminal),
    );
    try std.testing.expect(try owner.service.pump(owner.frame) == .idle);
    try std.testing.expectEqual(cleanup_fails, try owner.service.shutdownIncomplete(owner.frame));
    try std.testing.expectEqual(if (cleanup_fails) index - 1 else 0, owner.service.owned.items.len);
    var params = native.json.object();
    try native.json.put(
        owner.frame,
        &params,
        "task_id",
        native.json.string(try owner.frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
    );
    const result = try client.call(owner.frame, .@"task.result", params);
    try std.testing.expect(result.object.get("ready").?.bool);
    try std.testing.expectEqual(
        !cleanup_fails,
        result.object.get("outcome").?.object.get("cleanup_complete").?.bool,
    );
    try std.testing.expect(
        (try owner.service.submit(owner.frame, operation, cleanup_fails)).replayed,
    );
}

fn retainedCleanupOwnership(owner: *TerminalCleanupOwner) !void {
    _ = try owner.service.submit(owner.frame, "beyond-former-owned-quota", false);
    try owner.service.park(owner.frame);
    try std.testing.expect(try owner.service.shutdownIncomplete(owner.frame));
    // Reopening does not reacquire old work; its durable result stays honest.
    const retained_id = owner.service.owned.items[0];
    try owner.service.close(owner.frame);
    owner.service_live = false;
    owner.service = try native.tasks.Service(CleanupTypes).init(
        owner.a,
        owner.io,
        &owner.namespace,
        owner.config.assets,
        owner.config.application,
        owner.config.handlers,
        owner.config.profile,
    );
    owner.service_live = true;
    var retained = try owner.service.task(owner.frame, retained_id);
    defer retained.deinit();
    try std.testing.expect(!try owner.service.taskCleanupComplete(owner.frame, retained.value));
    try std.testing.expect(try owner.service.pump(owner.frame) == .idle);
}
test "completed result beyond the former wire-read ceiling remains publicly retrievable" {
    const parent = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    var compiled = try protean.compile(a, LargeUtf8System);
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try ownerManifest(a, image, admitted_image.identity(), "large-result-test");
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "large-result-test",
        .manifest = manifest,
    };
    var application: native.discovery.Application = undefined;
    try prepareTestApplication(&application, parent, manifest, admitted_image.identity());
    defer application.deinit();
    var handlers = try native.Registry.init(parent, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "large-result-profile", .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path);
    var namespace = try native.Namespace.open(
        parent,
        io,
        try std.fmt.allocPrint(a, "{s}/state", .{path[0..length]}),
    );
    defer expectCleanup(namespace.close());
    var service = try native.tasks.Service(LargeUtf8Types).init(
        parent,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer expectCleanup(service.close(a));
    try completeLargeUtf8Result(parent, a, &service);
}

const LargeUtf8Types = struct {
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
const LargeUtf8Identity = struct {
    pub fn emit(c: protean.Context) !horos.source.Module {
        const b = c.builder;
        const input_schema = try horos_authoring.interop.schemaId(
            c.author,
            try c.schema(LargeUtf8Types.Input),
        );
        const entry = try b.declare(&.{input_schema}, input_schema, &.{}, &.{});
        try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
        return b.module(
            entry,
            try horos_authoring.interop.schemaId(c.author, try c.schema(void)),
        );
    }
};
const LargeUtf8System = protean.system(.{
    .InitialArgs = LargeUtf8Types.Input,
    .Result = LargeUtf8Types.Output,
    .Failure = void,
    .application = LargeUtf8Identity,
});

fn prepareTestApplication(
    application: *native.discovery.Application,
    parent: std.mem.Allocator,
    manifest: []const u8,
    identity: [32]u8,
) !void {
    application.* = .{
        .arena = .init(parent),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "unit",
        .image_identity = identity,
    };
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
}

fn completeLargeUtf8Result(
    parent: std.mem.Allocator,
    a: std.mem.Allocator,
    service: *native.tasks.Service(LargeUtf8Types),
) !void {
    const text = try a.alloc(u8, 4 * 1024 * 1024 + 1);
    @memset(text, 'x');
    const accepted = try service.submit(a, "large-result", .{ .bytes = text });
    while (true) { // tiger: event-loop
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
    try inspectLargeUtf8Result(parent, a, service, accepted.receipt.task, text);
}

fn inspectLargeUtf8Result(
    parent: std.mem.Allocator,
    a: std.mem.Allocator,
    service: *native.tasks.Service(LargeUtf8Types),
    task_id: [16]u8,
    text: []const u8,
) !void {
    var client: native.client.Client(LargeUtf8Types) = .{ .service = service };
    var params = native.json.object();
    try native.json.put(
        a,
        &params,
        "task_id",
        native.json.string(try a.dupe(u8, &std.fmt.bytesToHex(task_id, .lower))),
    );
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
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(expected, .lower),
        ref.object.get("sha256").?.string,
    );
    try native.json.put(a, &params, "artifact_id", ref.object.get("artifact_id").?);
    try native.json.put(a, &params, "length", native.json.string("32768"));
    try readLargeUtf8Edges(a, &client, &params, text);
}

fn readLargeUtf8Edges(
    a: std.mem.Allocator,
    client: *native.client.Client(LargeUtf8Types),
    params: *native.json.Value,
    text: []const u8,
) !void {
    for ([_]usize{ 0, text.len + 2 - 32768 }) |offset| {
        try native.json.put(
            a,
            params,
            "offset",
            native.json.string(try std.fmt.allocPrint(a, "{d}", .{offset})),
        );
        const chunk = try client.call(a, .@"artifact.read", params.*);
        var decoded: [32768]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(&decoded, chunk.object.get("data").?.string);
        try std.testing.expectEqual(
            text.len + 2,
            try native.json.decimal(usize, chunk.object.get("total_bytes").?),
        );
        for (decoded, 0..) |byte, index| try std.testing.expectEqual(
            @as(u8, if (offset + index == 0 or offset + index == text.len + 1) '"' else 'x'),
            byte,
        );
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
        const leaf = try horos_authoring.interop.operationId(
            c.author,
            try c.external("fair.leaf.v1", try c.schema(u32), try c.schema(u32), .read),
        );
        const question = try horos_authoring.interop.operationId(
            c.author,
            try c.external("fair.question.v1", try c.schema(u32), try c.schema(u32), .read),
        );
        const inbox = try horos_authoring.interop.operationId(c.author, try Inbox.declare(c));
        const entry = try b.declare(&.{number}, number, &.{ leaf, question, inbox }, &.{});
        const input = try b.reference(b.parameter(entry, 0));
        var body = try b.term(.{ .yield_then = try b.pure(input) });
        const ignored = try b.variable(
            try horos_authoring.interop.schemaId(c.author, try c.schema(Inbox.Reply)),
        );
        const paths = [_]horos.data.program.Id{
            try b.term(.{
                .yield_then = try b.term(.{ .call = .{ .function = entry, .arguments = &.{
                    input,
                } } }),
            }),
            try b.term(.{ .perform = .{ .effect = leaf, .payload = input } }),
            try b.term(.{ .perform = .{ .effect = question, .payload = input } }),
            try b.bind(
                ignored,
                try b.term(.{ .perform = .{
                    .effect = inbox,
                    .payload = try b.constant(void, {}),
                } }),
                try b.pure(input),
            ),
        };
        for (paths, 0..) |path, selector| body = try b.term(.{ .conditional = .{
            .condition = try b.primitive(
                boolean,
                .equal,
                &.{ input, try b.constant(u32, @intCast(selector)) },
                0,
            ),
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
    fn interpret(
        ctx: native.registry.ProjectionContext,
        _: []const u8,
        _: []const u8,
        raw: []const u8,
    ) !native.registry.Projection {
        return .{ .reply = try ctx.allocator.dupe(u8, raw) };
    }
    fn present(ctx: native.Context, input: u32) !native.json.Value {
        return native.json.number(ctx.allocator, input);
    }
};

test "round robin progresses peers and cancellation while one worker is held" {
    var fixture: FairSchedulingFixture = .{};
    defer fixture.deinit();
    try fixture.initAssets();
    try fixture.initHandlers();
    try fixture.initOwner();
    try fixture.initialRound();
    try fixture.holdWorker();
    try fixture.queuePeers();
    try fixture.observePeers();
    try fixture.answerPeer();
    try fixture.finishWorker();
    try fixture.resumeRound();
    try fixture.recoverFenced();
}

const FairSchedulingFixture = struct {
    a: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    compiled: horos.source.Compiled = undefined,
    image: []u8 = undefined,
    admitted: *horos.data.program_image.Admitted = undefined,
    manifest: []u8 = undefined,
    assets: native.discovery.Assets = undefined,
    application: native.discovery.Application = undefined,
    leaf: native.registry.Declaration = undefined,
    handlers: native.Registry = undefined,
    grants: [3]native.registry.Grant = undefined,
    profile: native.tasks.Profile = undefined,
    temporary: std.testing.TmpDir = undefined,
    path_buffer: [4096]u8 = undefined,
    length: usize = undefined,
    path: []u8 = undefined,
    namespace: native.Namespace = undefined,
    namespace_live: bool = false,
    failing: std.testing.FailingAllocator = undefined,
    service: native.tasks.Service(FairTypes) = undefined,
    service_live: bool = false,
    arena: std.heap.ArenaAllocator = undefined,
    frame: std.mem.Allocator = undefined,
    first: native.tasks.Admission = undefined,
    second: native.tasks.Admission = undefined,
    second_turn: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    newcomer: native.tasks.Admission = undefined,
    still_queued: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    slow: native.tasks.Admission = undefined,
    held: native.tasks.Work = undefined,
    original_slow: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    client: native.client.Client(FairTypes) = undefined,
    slow_params: native.json.Value = undefined,
    queued: native.tasks.Admission = undefined,
    infinite: native.tasks.Admission = undefined,
    finite: native.tasks.Admission = undefined,
    question: native.tasks.Admission = undefined,
    inbox: native.tasks.Admission = undefined,
    cancelled: native.tasks.Admission = undefined,
    unchanged_slow: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    live: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    asked: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    active_question: protean.contracts.Decoded(native.testing.state.Question) = undefined,
    answered: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    raw: []u8 = undefined,
    finished: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    park_first: native.tasks.Admission = undefined,
    park_second: native.tasks.Admission = undefined,
    resumed_first: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    resumed_second: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    rollback: native.tasks.Admission = undefined,
    no_dispatch: native.tasks.Admission = undefined,
    recovered: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    compiled_ready: bool = false,
    image_ready: bool = false,
    admitted_ready: bool = false,
    manifest_ready: bool = false,
    application_ready: bool = false,
    handlers_ready: bool = false,
    temporary_ready: bool = false,
    path_ready: bool = false,
    arena_ready: bool = false,
    second_turn_ready: bool = false,
    still_queued_ready: bool = false,
    original_slow_ready: bool = false,
    unchanged_slow_ready: bool = false,
    live_ready: bool = false,
    asked_ready: bool = false,
    active_question_ready: bool = false,
    answered_ready: bool = false,
    finished_ready: bool = false,
    resumed_first_ready: bool = false,
    resumed_second_ready: bool = false,
    recovered_ready: bool = false,
    held_cleanup: bool = false,

    fn initAssets(self: *@This()) !void {
        FairCapture.preparations = 0;
        self.compiled = try protean.compile(
            self.a,
            protean.system(.{
                .InitialArgs = u32,
                .Result = u32,
                .Failure = void,
                .application = FairApplication,
            }),
        );
        self.compiled_ready = true;
        self.image = try self.a.alloc(
            u8,
            try horos.data.program_image.encodedLength(self.compiled.program),
        );
        self.image_ready = true;
        _ = try self.compiled.encode(self.a, self.image);
        self.admitted = try horos.data.program_image.Admitted.decode(self.a, self.image);
        self.admitted_ready = true;
        self.manifest = try ownerManifest(
            self.a,
            self.image,
            self.admitted.identity(),
            "fair-owner",
        );
        self.manifest_ready = true;
        self.assets = .{
            .image = self.image,
            .application = "fair-owner",
            .manifest = self.manifest,
        };
        self.application = .{
            .arena = .init(self.a),
            .metadata = .null,
            .manifest = .null,
            .manifest_id = "unit",
            .image_identity = self.admitted.identity(),
        };
        self.application_ready = true;
        self.application.manifest = (try native.json.parse(
            self.application.arena.allocator(),
            self.manifest,
            .{},
        )).value;
    }

    fn initHandlers(self: *@This()) !void {
        self.leaf = native.leaf(
            u32,
            u32,
            .{ .identity = "fair.leaf.v1", .resource_role = "local" },
            increment,
        );
        self.leaf.capture = .{
            .prepare = FairCapture.prepare,
            .acquire = FairCapture.acquire,
            .interpret = FairCapture.interpret,
            .dependencies = native.registry.opaqueProjection,
        };
        self.leaf.invoke = null;
        self.leaf.background = true;
        self.handlers = try native.Registry.init(self.a, &.{
            self.leaf,
            native.question(
                u32,
                u32,
                .{
                    .identity = "fair.question.v1",
                    .resource_role = "user",
                    .answer_schema_id = "fair.answer.v1",
                },
                FairCapture.present,
            ),
            native.inbox.declaration(u32),
        });
        self.handlers_ready = true;
        self.grants = undefined;
        self.profile = .{ .id = "offline", .runtime_identity = @splat(
            42,
        ), .bytes = "fair-profile", .authority = .{
            .grants = &self.grants,
            .principal = "test",
            .tenant = "test",
        } };
        for (&self.grants, self.handlers.entries) |*grant, entry| grant.* = .{
            .identity = entry.declaration.identity,
            .resource_role = entry.declaration.resource_role,
            .resource_identity = try self.profile.resourceIdentity(
                self.a,
                self.application.image_identity,
            ),
        };
    }

    fn initOwner(self: *@This()) !void {
        self.temporary = std.testing.tmpDir(.{});
        self.temporary_ready = true;
        self.path_buffer = undefined;
        self.length = try self.temporary.dir.realPath(self.io, &self.path_buffer);
        self.path = try std.fmt.allocPrint(
            self.a,
            "{s}/state",
            .{self.path_buffer[0..self.length]},
        );
        self.path_ready = true;
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        self.failing = std.testing.FailingAllocator.init(self.a, .{});
        self.service = try native.tasks.Service(FairTypes).init(
            self.failing.allocator(),
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
        self.arena = std.heap.ArenaAllocator.init(self.a);
        self.arena_ready = true;
        self.frame = self.arena.allocator();
    }

    fn initialRound(self: *@This()) !void {
        self.first = try self.service.submit(self.frame, "first-yielder", 0);
        self.second = try self.service.submit(self.frame, "second-yielder", 0);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        for ([_][16]u8{ self.first.receipt.task, self.second.receipt.task }) |id| {
            var task = try self.service.task(self.frame, id);
            defer task.deinit();
            try std.testing.expectEqual(1, task.value.execution_revision);
        }
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        self.second_turn = try self.service.task(self.frame, self.second.receipt.task);
        self.second_turn_ready = true;
        try std.testing.expectEqual(1, self.second_turn.value.execution_revision);
        // Admission appends behind already queued continuations, even across a
        // round boundary. A stream of newcomers cannot postpone an older peer.
        self.newcomer = try self.service.submit(self.frame, "new-yielder", 0);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        self.still_queued = try self.service.task(self.frame, self.newcomer.receipt.task);
        self.still_queued_ready = true;
        try std.testing.expectEqual(0, self.still_queued.value.execution_revision);
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-first",
            self.first.receipt.task,
            "stop",
        );
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-second",
            self.second.receipt.task,
            "stop",
        );
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-new",
            self.newcomer.receipt.task,
            "stop",
        );
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .idle);
    }

    fn holdWorker(self: *@This()) !void {
        self.slow = try self.service.submit(self.frame, "slow", 1);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        self.held = (try self.service.pump(self.frame)).work;
        self.original_slow = try self.service.task(self.frame, self.slow.receipt.task);
        self.original_slow_ready = true;
        // The held worker is released even when a later assertion fails.
        self.held_cleanup = true;
        self.client = .{ .service = &self.service };
        self.slow_params = native.json.object();
        try native.json.put(
            self.frame,
            &self.slow_params,
            "task_id",
            native.json.string(
                try self.frame.dupe(u8, &std.fmt.bytesToHex(self.slow.receipt.task, .lower)),
            ),
        );
        try std.testing.expectEqualStrings(
            "running",
            (try self.client.call(
                self.frame,
                .@"task.status",
                self.slow_params,
            )).object.get(
                "status",
            ).?.string,
        );
    }

    fn queuePeers(self: *@This()) !void {
        self.queued = try self.service.submit(self.frame, "queued-leaf", 1);
        {
            var task = try self.service.task(self.frame, self.queued.receipt.task);
            defer task.deinit();
            try std.testing.expectEqual(.queued, try self.service.status(self.frame, task.value));
        }
        self.infinite = try self.service.submit(self.frame, "yielding-forever", 0);
        self.finite = try self.service.submit(self.frame, "finite", 4);
        self.question = try self.service.submit(self.frame, "question", 2);
        self.inbox = try self.service.submit(self.frame, "inbox", 3);
        self.cancelled = try self.service.submit(self.frame, "cancelled", 4);
        _ = try self.service.message(self.frame, "slow-followup", self.slow.receipt.task, 11);
        _ = try self.service.message(self.frame, "inbox-message", self.inbox.receipt.task, 7);
        _ = try self.service.requestCancel(
            self.frame,
            "cancel",
            self.cancelled.receipt.task,
            "stop",
        );
        for (0..35) |_| try std.testing.expect(try self.service.pump(self.frame) != .work);
        try std.testing.expectEqual(1, FairCapture.preparations);
        try std.testing.expectEqual(
            0,
            try self.namespace.store.capabilityAttempts(self.queued.receipt.task, "fair.leaf.v1"),
        );
    }

    fn observePeers(self: *@This()) !void {
        self.unchanged_slow = try self.service.task(self.frame, self.slow.receipt.task);
        self.unchanged_slow_ready = true;
        try std.testing.expectEqualDeep(
            self.original_slow.value.checkpoint,
            self.unchanged_slow.value.checkpoint,
        );
        try std.testing.expectEqual(
            self.original_slow.value.execution_revision,
            self.unchanged_slow.value.execution_revision,
        );
        try std.testing.expect(
            self.unchanged_slow.value.revision > self.original_slow.value.revision,
        );
        try std.testing.expectEqualStrings(
            "running",
            (try self.client.call(
                self.frame,
                .@"task.status",
                self.slow_params,
            )).object.get(
                "status",
            ).?.string,
        );
        inline for (.{
            .{ self.finite.receipt.task, .completed },
            .{ self.inbox.receipt.task, .completed },
            .{ self.cancelled.receipt.task, .cancelled },
        }) |expected| {
            var task = try self.service.task(self.frame, expected[0]);
            defer task.deinit();
            try std.testing.expectEqual(expected[1], task.value.outcome_kind);
        }
        self.live = try self.service.task(self.frame, self.infinite.receipt.task);
        self.live_ready = true;
        try std.testing.expect(self.live.value.execution_revision > 1);
        self.asked = try self.service.task(self.frame, self.question.receipt.task);
        self.asked_ready = true;
        try std.testing.expectEqual(
            .waiting_input,
            try self.service.status(self.frame, self.asked.value),
        );
    }

    fn answerPeer(self: *@This()) !void {
        self.active_question = (try self.service.pendingQuestion(
            self.frame,
            self.question.receipt.task,
        )).?;
        self.active_question_ready = true;
        _ = try self.service.respond(
            self.frame,
            "answer",
            self.question.receipt.task,
            self.active_question.value.id,
            self.active_question.value.revision,
            self.active_question.value.request_digest,
            "fair.answer.v1",
            .{ .number_string = "73" },
        );
        for (0..8) |_| try std.testing.expect(try self.service.pump(self.frame) != .work);
        self.answered = try self.service.task(self.frame, self.question.receipt.task);
        self.answered_ready = true;
        try std.testing.expectEqual(.completed, self.answered.value.outcome_kind);
    }

    fn finishWorker(self: *@This()) !void {
        // Every callback dimension is checked before the current worker is touched.
        inline for (.{ "owner_epoch", "task", "occurrence", "attempt" }) |field| {
            var stale = self.held;
            @field(stale, field)[0] ^= 1;
            try std.testing.expectError(
                error.StaleOccurrence,
                self.service.acquire(self.frame, stale, &.{}),
            );
            try std.testing.expectEqualSlices(u8, &self.held.attempt, &self.service.work.?.attempt);
        }
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-infinite",
            self.infinite.receipt.task,
            "stop",
        );
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-queued",
            self.queued.receipt.task,
            "stop",
        );
        for (0..8) |_| try std.testing.expect(try self.service.pump(self.frame) != .work);
        self.raw = try protean.contracts.encodeOwned(u32, self.frame, 99);
        try self.service.acquire(self.frame, self.held, self.raw);
        try std.testing.expectError(
            error.StaleOccurrence,
            self.service.acquire(self.frame, self.held, self.raw),
        );
        for (0..8) |_| try std.testing.expect(try self.service.pump(self.frame) != .work);
        self.finished = try self.service.task(self.frame, self.slow.receipt.task);
        self.finished_ready = true;
        try std.testing.expectEqual(.completed, self.finished.value.outcome_kind);
        try std.testing.expectEqualStrings(
            "completed",
            (try self.client.call(
                self.frame,
                .@"task.status",
                self.slow_params,
            )).object.get(
                "status",
            ).?.string,
        );
        try std.testing.expectEqual(1, FairCapture.preparations);
        try std.testing.expectEqual(
            1,
            try self.namespace.store.capabilityAttempts(self.slow.receipt.task, "fair.leaf.v1"),
        );
        try std.testing.expect(try self.service.pump(self.frame) == .idle);
    }

    fn resumeRound(self: *@This()) !void {
        // Park across a partial round, then resume in the opposite order using the
        // same owner. Old scheduling position must not survive the empty queue.
        self.park_first = try self.service.submit(self.frame, "park-first", 0);
        self.park_second = try self.service.submit(self.frame, "park-second", 0);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try self.service.park(self.frame);
        inline for (.{
            .{ self.park_second.receipt.task, "resume-second" },
            .{ self.park_first.receipt.task, "resume-first" },
        }) |item| {
            var task = try self.service.task(self.frame, item[0]);
            defer task.deinit();
            _ = try self.service.resumeTask(self.frame, item[1], item[0], task.value.revision);
        }
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        self.resumed_first = try self.service.task(self.frame, self.park_first.receipt.task);
        self.resumed_first_ready = true;
        self.resumed_second = try self.service.task(self.frame, self.park_second.receipt.task);
        self.resumed_second_ready = true;
        try std.testing.expectEqual(1, self.resumed_first.value.execution_revision);
        try std.testing.expectEqual(1, self.resumed_second.value.execution_revision);
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-park-first",
            self.park_first.receipt.task,
            "stop",
        );
        _ = try self.service.requestCancel(
            self.frame,
            "cancel-park-second",
            self.park_second.receipt.task,
            "stop",
        );
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .progressed);
        try std.testing.expect(try self.service.pump(self.frame) == .idle);
    }

    fn recoverFenced(self: *@This()) !void {
        // Stop writes only after both admissions. A quantum may publish to Kosmos,
        // but its failed store publication must fence every task and retain custody.
        self.rollback = try self.service.submit(self.frame, "rollback-quantum", 4);
        self.no_dispatch = try self.service.submit(self.frame, "fenced-leaf", 1);
        try self.namespace.store.database.exec("PRAGMA query_only=ON;");
        try std.testing.expectError(error.StorageUnavailable, self.service.pump(self.frame));
        try std.testing.expect(self.namespace.store.fenced);
        try std.testing.expect(self.service.active != null);
        try std.testing.expectError(error.StorageUnavailable, self.service.pump(self.frame));
        try std.testing.expectEqual(1, FairCapture.preparations);
        try self.namespace.store.database.exec("PRAGMA query_only=OFF;");
        // Closing the fenced owner transfers its last receipt with no allocation.
        self.failing.fail_index = self.failing.alloc_index;
        self.failing.resize_fail_index = self.failing.resize_index;
        try self.service.close(self.frame);
        self.service_live = false;
        self.failing.fail_index = std.math.maxInt(usize);
        self.failing.resize_fail_index = std.math.maxInt(usize);
        try self.namespace.close();
        self.namespace_live = false;
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        self.service = try native.tasks.Service(FairTypes).init(
            self.failing.allocator(),
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
        self.recovered = try self.service.task(self.frame, self.rollback.receipt.task);
        self.recovered_ready = true;
        try std.testing.expectEqual(0, self.recovered.value.execution_revision);
        try std.testing.expectEqual(.progressed, self.recovered.value.outcome_kind);
        try std.testing.expectEqual(
            0,
            try self.namespace.store.capabilityAttempts(
                self.no_dispatch.receipt.task,
                "fair.leaf.v1",
            ),
        );
        try std.testing.expect(try self.service.pump(self.frame) == .idle);
    }
    fn deinit(self: *@This()) void {
        if (self.recovered_ready) self.recovered.deinit();
        if (self.resumed_second_ready) self.resumed_second.deinit();
        if (self.resumed_first_ready) self.resumed_first.deinit();
        if (self.finished_ready) self.finished.deinit();
        if (self.answered_ready) self.answered.deinit();
        if (self.active_question_ready) self.active_question.deinit();
        if (self.asked_ready) self.asked.deinit();
        if (self.live_ready) self.live.deinit();
        if (self.unchanged_slow_ready) self.unchanged_slow.deinit();
        if (self.held_cleanup and self.service_live) {
            if (self.service.work) |work| expectCleanup(self.service.notSent(self.frame, work));
        }
        if (self.original_slow_ready) self.original_slow.deinit();
        if (self.still_queued_ready) self.still_queued.deinit();
        if (self.second_turn_ready) self.second_turn.deinit();
        if (self.arena_ready) self.arena.deinit();
        if (self.service_live) expectCleanup(self.service.close(self.a));
        if (self.namespace_live) expectCleanup(self.namespace.close());
        if (self.path_ready) self.a.free(self.path);
        if (self.temporary_ready) self.temporary.cleanup();
        if (self.handlers_ready) self.handlers.deinit();
        if (self.application_ready) self.application.deinit();
        if (self.manifest_ready) self.a.free(self.manifest);
        if (self.admitted_ready) self.admitted.deinit();
        if (self.image_ready) self.a.free(self.image);
        if (self.compiled_ready) self.compiled.deinit();
    }
};

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
        const Bound = struct {
            task: [16]u8,
            occurrence: [32]u8,
            attempt: [32]u8,
            request_identity: [32]u8,
            request: State.Reference,
            prepared: ?State.Reference,
            profile: State.Reference,
            resources: C.Vector(State.Reference, null),
            capability: C.Text(128),
            inference: bool,
        };
        const bytes = try C.encodeOwned(Bound, a, .{
            .task = input.task,
            .occurrence = input.occurrence,
            .attempt = input.attempt,
            .request_identity = input.request_identity,
            .request = input.request,
            .prepared = input.prepared,
            .profile = input.profile,
            .resources = .{ .items = input.resources },
            .capability = .{ .bytes = input.capability },
            .inference = input.inference,
        });
        defer a.free(bytes);
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        return result;
    }
    fn sign(a: std.mem.Allocator, body: Body) ![32]u8 {
        const bytes = try C.encodeOwned(Body, a, body);
        defer a.free(bytes);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(
            &mac,
            bytes,
            "private synthetic receipt authority",
        );
        return mac;
    }
    pub fn receipt(a: std.mem.Allocator, input: native.registry.RecoveryInput, kind: Kind) ![]u8 {
        return receiptValue(a, input, kind, 99);
    }
    fn receiptValue(
        a: std.mem.Allocator,
        input: native.registry.RecoveryInput,
        kind: Kind,
        value: u32,
    ) ![]u8 {
        const raw = try C.encodeOwned(u32, a, value);
        defer a.free(raw);
        const body: Body = .{
            .binding = try binding(a, input),
            .kind = kind,
            .raw = .{ .bytes = raw },
        };
        return C.encodeOwned(Evidence, a, .{ .body = body, .signature = try sign(a, body) });
    }
    fn lookup(
        ctx: native.Context,
        input: native.registry.RecoveryInput,
        _: []const u8,
        _: ?[]const u8,
    ) ![]u8 {
        const self: *LookupFixture = @ptrCast(@alignCast(ctx.environment.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.started.store(true, .release);
        while (self.hold.load(.acquire)) {
            try ctx.checkCancellation();
            try ctx.io.sleep(.fromMilliseconds(1), .awake);
        }
        return receipt(ctx.allocator, input, self.kind);
    }
    const verification_failures = [_]anyerror{
        error.StorageUnavailable,
        error.CorruptState,
        error.Busy,
        error.InvalidState,
        error.OutOfMemory,
        error.Capacity,
        error.VerifierReadFailed,
    };

    pub fn verify(
        ctx: native.registry.ProjectionContext,
        input: native.registry.RecoveryInput,
        bytes: []const u8,
    ) !native.registry.RecoveryFinding {
        // Inject failures after the owner admitted the original bindings. The
        // final case deliberately has no special meaning to the task owner.
        for (verification_failures) |failure| if (std.mem.eql(
            u8,
            bytes,
            @errorName(failure),
        )) return failure;
        var decoded = C.decodeOwned(Evidence, ctx.allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory, error.Capacity => return err,
            else => return .rejected,
        };
        defer decoded.deinit();
        if (!std.meta.eql(
            decoded.value.signature,
            try sign(ctx.allocator, decoded.value.body),
        ) or !std.meta.eql(
            decoded.value.body.binding,
            try binding(ctx.allocator, input),
        )) return .rejected;
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
    pub fn interpret(
        ctx: native.registry.ProjectionContext,
        _: []const u8,
        _: []const u8,
        raw: []const u8,
    ) !native.registry.Projection {
        var value = try C.decodeOwned(u32, ctx.allocator, raw);
        defer value.deinit();
        if (value.value != 99) return error.InvalidCapture;
        return .{ .reply = try ctx.allocator.dupe(u8, raw), .output_tokens = 7 };
    }
};

fn lookupUnknown(
    service: *native.tasks.Service(FairTypes),
    a: std.mem.Allocator,
    id: []const u8,
) !native.tasks.Work {
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
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = u32,
            .Result = u32,
            .Failure = void,
            .application = FairApplication,
        }),
    );
    defer compiled.deinit();
    var successor = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = u32,
            .Result = u32,
            .Failure = void,
            .application = Successor,
        }),
    );
    defer successor.deinit();
    const old_image = try frame.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    _ = try compiled.encode(a, old_image);
    const new_image = try frame.alloc(
        u8,
        try horos.data.program_image.encodedLength(successor.program),
    );
    _ = try successor.encode(a, new_image);
    for ([_]RetainedCaptureCase{ .captured, .pure_reply, .verified_capture }) |scenario|
        try retainedCaptureScenario(a, io, frame, old_image, new_image, scenario);
}

const RetainedCaptureRecovery = struct {
    fn rederive(
        ctx: native.registry.RederivationContext,
        _: native.registry.RecoveryInput,
        payload: []const u8,
        _: ?[]const u8,
    ) !native.registry.RederivationFinding {
        var input = try protean.contracts.decodeOwned(u32, ctx.allocator, payload);
        defer input.deinit();
        return .{
            .result = try protean.contracts.encodeOwned(u32, ctx.allocator, input.value + 1),
        };
    }
};

const RetainedCaptureCase = enum { captured, pure_reply, verified_capture };
const RetainedCaptureObservation = struct {
    task_id: [16]u8 = undefined,
    params: native.json.Value = native.json.object(),
    original_status: []const u8 = undefined,
    original_result: []const u8 = undefined,
};

fn retainedCaptureHandlers(a: std.mem.Allocator, scenario: RetainedCaptureCase) !native.Registry {
    var leaf = native.leaf(
        u32,
        u32,
        .{ .identity = "fair.leaf.v1", .resource_role = "local" },
        increment,
    );
    if (scenario == .pure_reply) {
        leaf.recovery = .{
            .identity = "pure-increment.recovery.v1",
            .version = 1,
            .rederive = RetainedCaptureRecovery.rederive,
        };
    } else {
        leaf.capture = .{
            .prepare = FairCapture.prepare,
            .acquire = FairCapture.acquire,
            .interpret = FairCapture.interpret,
            .dependencies = native.registry.opaqueProjection,
        };
        leaf.invoke = null;
        leaf.background = true;
        if (scenario == .verified_capture) leaf.recovery = .{
            .identity = "signed-fixture-receipt.v1",
            .version = 1,
            .lookup = .{ .acquire = LookupFixture.lookup, .verify = LookupFixture.verify },
        };
    }
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
            FairCapture.present,
        ),
        native.inbox.declaration(u32),
    });
}

fn retainedCaptureScenario(
    a: std.mem.Allocator,
    io: std.Io,
    frame: std.mem.Allocator,
    old_image: []const u8,
    new_image: []const u8,
    scenario: RetainedCaptureCase,
) !void {
    var handlers = try retainedCaptureHandlers(a, scenario);
    defer handlers.deinit();
    var grants: [3]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "retained", .runtime_identity = @splat(
        42,
    ), .bytes = "retained-profile", .authority = .{
        .grants = &grants,
        .principal = "test",
        .tenant = "test",
    } };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(frame, "{s}/retained", .{buffer[0..length]});
    var observed: RetainedCaptureObservation = .{};
    for ([_][]const u8{ old_image, new_image }, 0..) |image, generation| {
        try retainedCaptureGeneration(
            a,
            io,
            frame,
            handlers,
            profile,
            path,
            image,
            generation,
            scenario,
            &grants,
            &observed,
        );
    }
}

fn retainedCaptureGeneration(
    a: std.mem.Allocator,
    io: std.Io,
    frame: std.mem.Allocator,
    handlers: native.Registry,
    profile: native.tasks.Profile,
    path: []const u8,
    image: []const u8,
    generation: usize,
    scenario: RetainedCaptureCase,
    grants: *[3]native.registry.Grant,
    observed: *RetainedCaptureObservation,
) !void {
    const admitted = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const manifest = try ownerManifest(frame, image, admitted.identity(), "retained-owner");
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "retained-owner",
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
    for (grants, handlers.entries) |*grant, entry| grant.* = .{
        .identity = entry.declaration.identity,
        .resource_role = entry.declaration.resource_role,
        .resource_identity = try profile.resourceIdentity(
            frame,
            application.image_identity,
        ),
    };
    var namespace = try native.Namespace.open(a, io, path);
    defer expectCleanup(namespace.close());
    var service = try native.tasks.Service(FairTypes).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer expectCleanup(service.close(frame));
    var client: native.client.Client(FairTypes) = .{ .service = &service };
    if (generation == 0) {
        try produceRetainedCapture(a, io, frame, &service, &client, profile, scenario, observed);
    } else {
        try checkRetainedCapture(frame, &service, &client, &namespace, observed);
    }
}

fn produceRetainedCapture(
    a: std.mem.Allocator,
    io: std.Io,
    frame: std.mem.Allocator,
    service: *native.tasks.Service(FairTypes),
    client: *native.client.Client(FairTypes),
    profile: native.tasks.Profile,
    scenario: RetainedCaptureCase,
    observed: *RetainedCaptureObservation,
) !void {
    observed.task_id = (try service.submit(frame, "original", 1)).receipt.task;
    try std.testing.expect(try service.pump(frame) == .progressed);
    const work = (try service.pump(frame)).work;
    if (scenario == .captured) {
        try service.acquire(frame, work, try protean.contracts.encodeOwned(u32, frame, 99));
    } else {
        try recoverRetainedCapture(
            a,
            io,
            frame,
            service,
            profile,
            scenario,
            observed.task_id,
            work,
        );
    }
    for (0..8) |_| try std.testing.expect(try service.pump(frame) != .work);
    var completed = try service.task(frame, observed.task_id);
    defer completed.deinit();
    try std.testing.expect(completed.value.outcome_kind == .completed);
    try native.json.put(
        frame,
        &observed.params,
        "task_id",
        native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(observed.task_id, .lower))),
    );
    observed.original_status = try native.json.canonical(
        frame,
        try client.call(frame, .@"task.status", observed.params),
    );
    observed.original_result = try native.json.canonical(
        frame,
        try client.call(frame, .@"task.result", observed.params),
    );
}

fn recoverRetainedCapture(
    a: std.mem.Allocator,
    io: std.Io,
    frame: std.mem.Allocator,
    service: *native.tasks.Service(FairTypes),
    profile: native.tasks.Profile,
    scenario: RetainedCaptureCase,
    task_id: [16]u8,
    work: native.tasks.Work,
) !void {
    try service.unknown(frame, work);
    var unknown = try service.task(frame, task_id);
    defer unknown.deinit();
    _ = try service.reconcile(
        frame,
        "recover",
        task_id,
        unknown.value.revision,
        work.occurrence,
        work.attempt,
        if (scenario == .pure_reply) .rederive else .lookup,
    );
    if (scenario == .pure_reply) try finishRetainedPure(a, io, frame, service, profile);
    if (scenario == .verified_capture) try finishRetainedCapture(frame, service);
}

fn finishRetainedPure(
    a: std.mem.Allocator,
    io: std.Io,
    frame: std.mem.Allocator,
    service: *native.tasks.Service(FairTypes),
    profile: native.tasks.Profile,
) !void {
    const computation = (try service.pump(frame)).work;
    const worker = try native.testing.Worker.init(a, io);
    defer expectCleanup(worker.deinit(a));
    try worker.start(computation, profile.authority, null);
    try awaitLookup(io, worker);
    defer expectCleanup(worker.release());
    try service.completeWork(frame, computation, worker.result.?);
}

fn finishRetainedCapture(
    frame: std.mem.Allocator,
    service: *native.tasks.Service(FairTypes),
) !void {
    const lookup = (try service.pump(frame)).work;
    var record = try protean.contracts.decodeOwned(
        native.testing.state.Reconciliation,
        frame,
        lookup.recovery.?.body,
    );
    defer record.deinit();
    var request = try protocol.decode(protocol.Request, frame, lookup.request);
    defer request.deinit();
    try service.acquire(
        frame,
        lookup,
        try LookupFixture.receipt(
            frame,
            native.registry.RecoveryInput.fromReconciliation(
                record.value,
                request.value.request_identity,
                false,
            ),
            .capture,
        ),
    );
}

fn checkRetainedCapture(
    frame: std.mem.Allocator,
    service: *native.tasks.Service(FairTypes),
    client: *native.client.Client(FairTypes),
    namespace: *native.Namespace,
    observed: *const RetainedCaptureObservation,
) !void {
    try std.testing.expectEqualStrings(
        observed.original_status,
        try native.json.canonical(
            frame,
            try client.call(frame, .@"task.status", observed.params),
        ),
    );
    try std.testing.expectEqualStrings(
        observed.original_result,
        try native.json.canonical(
            frame,
            try client.call(frame, .@"task.result", observed.params),
        ),
    );
    var retained = try service.task(frame, observed.task_id);
    defer retained.deinit();
    try std.testing.expectError(
        error.IncompatibleProfile,
        service.resumeTask(
            frame,
            "incompatible-resume",
            observed.task_id,
            retained.value.revision,
        ),
    );
    try std.testing.expect(!namespace.store.fenced);
}
test "pure recovery without a capture adapter settles the original typed binding after restart" {
    try pureRecovery(.valid);
}

test "pure recovery preserves unresolved derivations and resource or custody failures" {
    for ([_]PureRecoveryCase{
        .rejected,
        .malformed,
        .unsupported,
        .unavailable,
        .inconclusive,
        .cancelled,
        .capacity,
        .allocation,
        .corrupt,
        .storage,
        .busy,
        .invalid_state,
        .unexpected,
    }) |scenario| try pureRecovery(scenario);
}

test "pure recovery work preserves peer progress cancellation and interrupted admission" {
    for ([_]PureRecoveryCase{
        .held,
        .held_cancel,
        .prior_cancel,
        .pending_cancel,
        .pending_cancel_failure,
        .interrupted,
    }) |scenario| try pureRecovery(scenario);
}

const PureRecoveryCase = enum {
    valid,
    rejected,
    malformed,
    unsupported,
    unavailable,
    inconclusive,
    cancelled,
    capacity,
    allocation,
    corrupt,
    storage,
    busy,
    invalid_state,
    unexpected,
    held,
    held_cancel,
    prior_cancel,
    pending_cancel,
    pending_cancel_failure,
    interrupted,
};

fn pureRecovery(scenario: PureRecoveryCase) !void {
    var fixture: PureRecoveryFixture = .{ .scenario = scenario };
    defer fixture.deinit();
    errdefer std.debug.print("pure recovery scenario: {s}\n", .{@tagName(scenario)});
    try fixture.initImage();
    try fixture.initApplication();
    try fixture.initHandlers();
    try fixture.initProfile();
    try fixture.initOwner();
    try fixture.admit();
    if (scenario == .pending_cancel or scenario == .pending_cancel_failure or
        scenario == .interrupted)
    {
        try fixture.pendingInterruption();
        return;
    }
    try fixture.startWorker();
    try fixture.heldPeerProgress();
    if (try fixture.failureSettlement()) return;
    if (try fixture.settle()) return;
    try fixture.success();
}

const PureRecoveryFixture = struct {
    scenario: PureRecoveryCase,
    a: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    arena: std.heap.ArenaAllocator = undefined,
    frame: std.mem.Allocator = undefined,
    image: []u8 = undefined,
    admitted_image: *horos.data.program_image.Admitted = undefined,
    manifest: []u8 = undefined,
    assets: native.discovery.Assets = undefined,
    application: native.discovery.Application = undefined,
    handlers: native.Registry = undefined,
    grants: [3]native.registry.Grant = undefined,
    profile: native.tasks.Profile = undefined,
    temporary: std.testing.TmpDir = undefined,
    buffer: [4096]u8 = undefined,
    length: usize = undefined,
    path: []u8 = undefined,
    namespace: native.Namespace = undefined,
    service: native.tasks.Service(FairTypes) = undefined,
    original: native.tasks.Work = undefined,
    unknown: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    expected_revision: u64 = undefined,
    original_attempt: []const u8 = undefined,
    admitted: native.tasks.Admission = undefined,
    before: @FieldType(@FieldType(native.Namespace, "store"), "head") = undefined,
    work: native.tasks.Work = undefined,
    worker: *native.testing.Worker = undefined,
    recovery: protean.contracts.Decoded(native.testing.state.Reconciliation) = undefined,
    worker_started: bool = false,
    worker_releasable: bool = false,
    arena_live: bool = false,
    admitted_image_live: bool = false,
    application_live: bool = false,
    handlers_live: bool = false,
    temporary_live: bool = false,
    namespace_live: bool = false,
    service_live: bool = false,
    unknown_live: bool = false,
    worker_live: bool = false,
    recovery_live: bool = false,

    const Pure = struct {
        fn invoke(_: native.Context, _: u32) !u32 {
            return error.OriginalInvocationForbidden;
        }
        var derivations: std.atomic.Value(u32) = .init(0);
        var hold: std.atomic.Value(bool) = .init(false);
        fn rederive(
            ctx: native.registry.RederivationContext,
            _: native.registry.RecoveryInput,
            payload: []const u8,
            prepared: ?[]const u8,
        ) !native.registry.RederivationFinding {
            _ = derivations.fetchAdd(1, .acq_rel);
            try std.testing.expect(prepared == null);
            const selected = std.meta.stringToEnum(
                PureRecoveryCase,
                ctx.profile,
            ) orelse return error.InvalidProfile;
            while (hold.load(.acquire)) {
                try ctx.checkCancellation();
                std.atomic.spinLoopHint();
            }
            switch (selected) {
                .valid,
                .held,
                .held_cancel,
                .prior_cancel,
                .pending_cancel,
                .pending_cancel_failure,
                .interrupted,
                => {},
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
            return .{
                .result = try protean.contracts.encodeOwned(u32, ctx.allocator, input.value + 1),
            };
        }
    };

    fn initImage(self: *PureRecoveryFixture) !void {
        self.arena = std.heap.ArenaAllocator.init(self.a);
        self.arena_live = true;
        self.frame = self.arena.allocator();
        var compiled = try protean.compile(
            self.a,
            protean.system(.{
                .InitialArgs = u32,
                .Result = u32,
                .Failure = void,
                .application = FairApplication,
            }),
        );
        defer compiled.deinit();
        self.image = try self.frame.alloc(
            u8,
            try horos.data.program_image.encodedLength(compiled.program),
        );
        _ = try compiled.encode(self.a, self.image);
        self.admitted_image = try horos.data.program_image.Admitted.decode(self.a, self.image);
        self.admitted_image_live = true;
        self.manifest = try ownerManifest(
            self.frame,
            self.image,
            self.admitted_image.identity(),
            "pure-recovery-owner",
        );
        self.assets = .{
            .image = self.image,
            .application = "pure-recovery-owner",
            .manifest = self.manifest,
        };
    }

    fn initApplication(self: *PureRecoveryFixture) !void {
        self.application = .{
            .arena = .init(self.a),
            .metadata = .null,
            .manifest = .null,
            .manifest_id = "unit",
            .image_identity = self.admitted_image.identity(),
        };
        self.application_live = true;
        self.application.manifest = (try native.json.parse(
            self.application.arena.allocator(),
            self.manifest,
            .{},
        )).value;
    }

    fn initHandlers(self: *PureRecoveryFixture) !void {
        Pure.derivations.store(0, .release);
        Pure.hold.store(self.scenario == .held or self.scenario == .held_cancel, .release);
        var leaf = native.leaf(
            u32,
            u32,
            .{ .identity = "fair.leaf.v1", .resource_role = "local" },
            Pure.invoke,
        );
        leaf.recovery = .{
            .identity = "pure-increment.recovery.v1",
            .version = 1,
            .rederive = Pure.rederive,
        };
        self.handlers = try native.Registry.init(self.a, &.{
            leaf,
            native.question(
                u32,
                u32,
                .{
                    .identity = "fair.question.v1",
                    .resource_role = "user",
                    .answer_schema_id = "fair.answer.v1",
                },
                FairCapture.present,
            ),
            native.inbox.declaration(u32),
        });
        self.handlers_live = true;
    }

    fn initProfile(self: *PureRecoveryFixture) !void {
        self.grants = undefined;
        self.profile = .{
            .id = "pure",
            .runtime_identity = @splat(42),
            .bytes = @tagName(self.scenario),
            .authority = .{ .grants = &self.grants, .principal = "test", .tenant = "test" },
        };
        for (&self.grants, self.handlers.entries) |*grant, entry| grant.* = .{
            .identity = entry.declaration.identity,
            .resource_role = entry.declaration.resource_role,
            .resource_identity = try self.profile.resourceIdentity(
                self.frame,
                self.application.image_identity,
            ),
        };
    }

    fn initOwner(self: *PureRecoveryFixture) !void {
        self.temporary = std.testing.tmpDir(.{});
        self.temporary_live = true;
        self.buffer = undefined;
        self.length = try self.temporary.dir.realPath(self.io, &self.buffer);
        self.path = try std.fmt.allocPrint(self.frame, "{s}/pure", .{self.buffer[0..self.length]});
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        self.service = try native.tasks.Service(FairTypes).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
    }

    fn admit(self: *PureRecoveryFixture) !void {
        self.original = try lookupUnknown(&self.service, self.frame, "pure-original");
        try self.closeOwner();
        try self.openOwner();
        self.unknown = try self.service.task(self.frame, self.original.task);
        self.unknown_live = true;
        self.expected_revision = self.unknown.value.revision;
        if (self.scenario == .prior_cancel) {
            self.expected_revision = (try self.service.requestCancel(
                self.frame,
                "prior-cancel",
                self.original.task,
                "settle then cancel",
            )).receipt.revision;
        }
        self.original_attempt = (try self.namespace.store.recordBytes(
            self.frame,
            "attempt",
            self.original.attempt,
            self.original.task,
        )).?;
        self.admitted = try self.service.reconcile(
            self.frame,
            "pure-recover",
            self.original.task,
            self.expected_revision,
            self.original.occurrence,
            self.original.attempt,
            .rederive,
        );
        try std.testing.expectEqual(@as(u32, 0), Pure.derivations.load(.acquire));
        {
            var pending = try self.service.reconciliation(
                self.frame,
                self.original.task,
                self.admitted.receipt.reconciliation.?,
            );
            defer pending.deinit();
            try std.testing.expect(
                pending.value.outcome == .pending and pending.value.provenance == .none,
            );
        }
    }

    fn pendingInterruption(self: *PureRecoveryFixture) !void {
        if (self.scenario == .pending_cancel) {
            _ = try self.service.requestCancel(
                self.frame,
                "cancel-before-worker",
                self.original.task,
                "interrupt recovery",
            );
        } else if (self.scenario == .pending_cancel_failure) {
            try self.failCancellation();
        } else {
            try self.importInterrupted();
        }
        var stopped = try self.service.reconciliation(
            self.frame,
            self.original.task,
            self.admitted.receipt.reconciliation.?,
        );
        defer stopped.deinit();
        try std.testing.expect(
            stopped.value.outcome == .unresolved and stopped.value.provenance == .none,
        );
        const expected: @TypeOf(
            stopped.value.outcome.unresolved,
        ) = if (self.scenario == .pending_cancel) .unavailable else .interrupted;
        try std.testing.expectEqual(expected, stopped.value.outcome.unresolved);
        try std.testing.expectEqual(@as(u32, 0), Pure.derivations.load(.acquire));
        try std.testing.expect(try self.service.pump(self.frame) == .idle);
        const replay = try self.service.reconcile(
            self.frame,
            "pure-recover",
            self.original.task,
            self.expected_revision,
            self.original.occurrence,
            self.original.attempt,
            .rederive,
        );
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqualDeep(self.admitted.receipt, replay.receipt);
        _ = try self.namespace.store.auditRetention(
            self.handlers,
            self.application.image_identity,
        );
        return;
    }

    fn failCancellation(self: *PureRecoveryFixture) !void {
        // Advance allocation failure through admission until cancellation
        // commits. Earlier failures must roll back and remain retryable;
        // a failure after that commit must prevent recovery dispatch.
        const generation = self.namespace.store.head.generation;
        var fail_index: usize = 0;
        while (self.namespace.store.head.generation == generation) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(self.frame, .{
                .fail_index = fail_index,
            });
            _ = self.service.requestCancel(
                failing.allocator(),
                "cancel-before-worker",
                self.original.task,
                "interrupt recovery",
            ) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                if (self.namespace.store.head.generation == generation) {
                    try std.testing.expect(!self.namespace.store.fenced);
                    continue;
                }
                if (!self.namespace.store.fenced) std.debug.print(
                    "cancellation committed at allocation failure {d} " ++
                        "but recovery can still dispatch\n",
                    .{fail_index},
                );
                try std.testing.expect(self.namespace.store.fenced);
                try std.testing.expectError(
                    error.StorageUnavailable,
                    self.service.pump(self.frame),
                );
                try std.testing.expectError(
                    error.StorageUnavailable,
                    self.service.requestCancel(
                        self.frame,
                        "cancel-before-worker",
                        self.original.task,
                        "interrupt recovery",
                    ),
                );
                break;
            };
            return error.ExpectedAllocationFailureAfterCancellationCommit;
        }
        try self.closeOwner();
        try self.openOwner();
        const replay = try self.service.requestCancel(
            self.frame,
            "cancel-before-worker",
            self.original.task,
            "interrupt recovery",
        );
        try std.testing.expect(replay.replayed);
        var cancelled = try self.service.task(self.frame, self.original.task);
        defer cancelled.deinit();
        try std.testing.expectEqualStrings(
            "interrupt recovery",
            cancelled.value.cancellation.?.bytes,
        );
    }

    fn importInterrupted(self: *PureRecoveryFixture) !void {
        const archive = try std.fmt.allocPrint(self.frame, "{s}/pending-pure.agnx", .{
            self.buffer[0..self.length],
        });
        _ = try self.service.exportCheckpoint(self.frame, self.original.task, archive);
        try self.closeOwner();
        {
            const copy_path = try std.fmt.allocPrint(self.frame, "{s}/imported-pure", .{
                self.buffer[0..self.length],
            });
            var copy_namespace = try native.Namespace.open(self.a, self.io, copy_path);
            defer expectCleanup(copy_namespace.close());
            var copy = try native.tasks.Service(FairTypes).init(
                self.a,
                self.io,
                &copy_namespace,
                self.assets,
                &self.application,
                self.handlers,
                self.profile,
            );
            defer expectCleanup(copy.close(self.frame));
            _ = try copy.importCheckpoint(self.frame, "import-pure", archive);
            var copied = try copy.reconciliation(
                self.frame,
                self.original.task,
                self.admitted.receipt.reconciliation.?,
            );
            defer copied.deinit();
            try std.testing.expect(
                copied.value.outcome == .unresolved and
                    copied.value.outcome.unresolved == .interrupted,
            );
            try std.testing.expect(try copy.pump(self.frame) == .idle);
        }
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        var bootstrap = self.profile;
        bootstrap.bytes = "bootstrap-before-frozen-inputs";
        self.service = try native.tasks.Service(FairTypes).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            bootstrap,
        );
        self.service_live = true;
        var readable = try self.service.task(self.frame, self.original.task);
        defer readable.deinit();
        try std.testing.expectEqual(
            .unknown,
            try self.service.status(self.frame, readable.value),
        );
        self.service.profile = self.profile;
    }

    fn startWorker(self: *PureRecoveryFixture) !void {
        self.before = self.namespace.store.head;
        self.work = (try self.service.pump(self.frame)).work;
        self.worker = try native.testing.Worker.init(self.a, self.io);
        self.worker_live = true;
        try self.worker.start(self.work, self.profile.authority, null);
        self.worker_started = true;
        try std.testing.expect(!try self.service.shouldCancelWork(self.work));
    }

    fn heldPeerProgress(self: *PureRecoveryFixture) !void {
        if (self.scenario == .held or self.scenario == .held_cancel) {
            const deadline = std.Io.Clock.awake.now(self.io).toMilliseconds() + 5000;
            while (Pure.derivations.load(.acquire) == 0) {
                if (std.Io.Clock.awake.now(
                    self.io,
                ).toMilliseconds() >= deadline) return error.TestTimeout;
                try self.io.sleep(.fromMilliseconds(1), .awake);
            }
            try std.testing.expect(!self.worker.finished());
            const peer = try self.service.submit(self.frame, "pure-peer", 4);
            const cancelled_peer = try self.service.submit(self.frame, "cancelled-peer", 0);
            _ = try self.service.requestCancel(
                self.frame,
                "peer-cancel",
                cancelled_peer.receipt.task,
                "peer only",
            );
            _ = try self.service.message(self.frame, "recovery-message", self.original.task, 7);
            try std.testing.expect(!try self.service.shouldCancelWork(self.work));
            for (0..8) |_| try std.testing.expect(try self.service.pump(self.frame) != .work);
            try self.peerStatuses(peer, cancelled_peer);
            try std.testing.expect(
                (try self.service.reconcile(
                    self.frame,
                    "pure-recover",
                    self.original.task,
                    self.expected_revision,
                    self.original.occurrence,
                    self.original.attempt,
                    .rederive,
                )).replayed,
            );
            try std.testing.expectEqual(@as(u32, 1), Pure.derivations.load(.acquire));
            if (self.scenario == .held_cancel) {
                _ = try self.service.requestCancel(
                    self.frame,
                    "cancel-rederivation",
                    self.original.task,
                    "stop new computation",
                );
                try std.testing.expect(try self.service.shouldCancelWork(self.work));
                self.worker.cancel();
            } else Pure.hold.store(false, .release);
        }
    }

    fn peerStatuses(
        self: *PureRecoveryFixture,
        peer: native.tasks.Admission,
        cancelled_peer: native.tasks.Admission,
    ) !void {
        var client: native.client.Client(FairTypes) = .{ .service = &self.service };
        for ([_]struct {
            id: [16]u8,
            status: []const u8,
        }{
            .{ .id = self.original.task, .status = "unknown" },
            .{ .id = peer.receipt.task, .status = "completed" },
            .{ .id = cancelled_peer.receipt.task, .status = "cancelled" },
        }) |observation| {
            var params = native.json.object();
            try native.json.put(
                self.frame,
                &params,
                "task_id",
                native.json.string(
                    try self.frame.dupe(u8, &std.fmt.bytesToHex(observation.id, .lower)),
                ),
            );
            try std.testing.expectEqualStrings(
                observation.status,
                (try client.call(self.frame, .@"task.status", params)).object.get(
                    "status",
                ).?.string,
            );
        }
    }

    fn failureSettlement(self: *PureRecoveryFixture) !bool {
        try awaitLookup(self.io, self.worker);
        self.worker_releasable = true;
        const failed = switch (self.scenario) {
            .capacity, .allocation, .corrupt, .storage, .busy, .invalid_state, .unexpected => true,
            else => false,
        };
        if (failed) {
            const expected_error = switch (self.scenario) {
                .capacity => error.Capacity,
                .allocation => error.OutOfMemory,
                .corrupt => error.CorruptState,
                .storage => error.StorageUnavailable,
                .busy => error.Busy,
                .invalid_state => error.InvalidState,
                .unexpected => error.InjectedRederivationFailure,
                else => unreachable,
            };
            try std.testing.expectError(
                expected_error,
                self.service.completeWork(self.frame, self.work, self.worker.result.?),
            );
            try std.testing.expectEqualDeep(self.before, self.namespace.store.head);
            try std.testing.expect(self.namespace.store.fenced and self.service.work == null);
            try self.closeOwner();
            try self.openOwner();
            var interrupted = try self.service.reconciliation(
                self.frame,
                self.original.task,
                self.admitted.receipt.reconciliation.?,
            );
            defer interrupted.deinit();
            try std.testing.expect(
                interrupted.value.outcome == .unresolved and
                    interrupted.value.outcome.unresolved == .interrupted,
            );
            try std.testing.expectEqualStrings(
                self.original_attempt,
                (try self.namespace.store.recordBytes(
                    self.frame,
                    "attempt",
                    self.original.attempt,
                    self.original.task,
                )).?,
            );
            return true;
        }
        return false;
    }

    fn settle(self: *PureRecoveryFixture) !bool {
        try self.service.completeWork(self.frame, self.work, self.worker.result.?);
        self.recovery = try self.service.reconciliation(
            self.frame,
            self.original.task,
            self.admitted.receipt.reconciliation.?,
        );
        self.recovery_live = true;
        if (self.scenario != .valid and self.scenario != .held and self.scenario != .prior_cancel) {
            try self.unresolvedOutcome();
            try self.closeOwner();
            try self.openOwner();
            const sealed = self.namespace.store.head;
            const replay = try self.service.reconcile(
                self.frame,
                "pure-recover",
                self.original.task,
                self.expected_revision,
                self.original.occurrence,
                self.original.attempt,
                .rederive,
            );
            try std.testing.expect(replay.replayed);
            try std.testing.expectEqualDeep(self.admitted.receipt, replay.receipt);
            try std.testing.expectEqualDeep(sealed, self.namespace.store.head);
            try std.testing.expect(try self.service.pump(self.frame) == .idle);
            _ = try self.namespace.store.auditRetention(
                self.handlers,
                self.application.image_identity,
            );
            return true;
        }
        return false;
    }

    fn unresolvedOutcome(self: *PureRecoveryFixture) !void {
        try std.testing.expect(
            self.recovery.value.outcome == .unresolved and
                self.recovery.value.provenance == .none,
        );
        const expected: @TypeOf(
            self.recovery.value.outcome.unresolved,
        ) = switch (self.scenario) {
            .rejected, .malformed => .rejected,
            .unsupported => .unsupported,
            .unavailable, .cancelled, .held_cancel => .unavailable,
            .inconclusive => .inconclusive,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, self.recovery.value.outcome.unresolved);
        try std.testing.expectEqualStrings(
            self.original_attempt,
            (try self.namespace.store.recordBytes(
                self.frame,
                "attempt",
                self.original.attempt,
                self.original.task,
            )).?,
        );
        var unresolved = try self.service.task(self.frame, self.original.task);
        defer unresolved.deinit();
        try std.testing.expectEqual(
            .unknown,
            try self.service.status(self.frame, unresolved.value),
        );
        try std.testing.expectEqual(
            self.unknown.value.inference_attempts,
            unresolved.value.inference_attempts,
        );
        try std.testing.expectEqual(
            self.unknown.value.inference_request_bytes,
            unresolved.value.inference_request_bytes,
        );
        try std.testing.expectEqual(
            self.unknown.value.inference_output_tokens,
            unresolved.value.inference_output_tokens,
        );
        try std.testing.expectError(
            error.UnsettledOccurrence,
            self.service.resumeTask(
                self.frame,
                "cannot-reissue",
                self.original.task,
                unresolved.value.revision,
            ),
        );
    }

    fn success(self: *PureRecoveryFixture) !void {
        try std.testing.expect(
            self.recovery.value.outcome == .reply_settled and
                self.recovery.value.provenance == .rederived,
        );
        try std.testing.expect(
            self.recovery.value.prepared == null and self.recovery.value.original_capture == null,
        );
        var original_occurrence = try protean.contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            self.frame,
            try self.namespace.store.object(
                self.frame,
                self.recovery.value.original_occurrence,
                null,
            ),
        );
        defer original_occurrence.deinit();
        try std.testing.expect(original_occurrence.value.state == .unknown);
        var bound = try protocol.decode(
            protocol.Result,
            self.frame,
            try self.namespace.store.object(
                self.frame,
                self.recovery.value.outcome.reply_settled,
                null,
            ),
        );
        defer bound.deinit();
        try std.testing.expectEqualSlices(
            u8,
            &original_occurrence.value.request,
            &bound.value.request_identity,
        );
        try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, bound.value.value);
        for (0..8) |_| try std.testing.expect(try self.service.pump(self.frame) != .work);
        var completed = try self.service.task(self.frame, self.original.task);
        defer completed.deinit();
        if (self.scenario == .prior_cancel) {
            try std.testing.expect(
                completed.value.outcome_kind == .cancelled and completed.value.cancellation_applied,
            );
        } else {
            try std.testing.expect(completed.value.outcome_kind == .completed);
            try std.testing.expectEqualSlices(
                u8,
                bound.value.value,
                try self.namespace.store.object(self.frame, completed.value.result.?, null),
            );
        }
        try std.testing.expectEqual(
            1,
            try self.namespace.store.capabilityAttempts(self.original.task, "fair.leaf.v1"),
        );
        try std.testing.expect(
            (try self.service.reconcile(
                self.frame,
                "pure-recover",
                self.original.task,
                self.expected_revision,
                self.original.occurrence,
                self.original.attempt,
                .rederive,
            )).replayed,
        );
        _ = try self.namespace.store.auditRetention(self.handlers, self.application.image_identity);
    }

    fn closeOwner(self: *PureRecoveryFixture) !void {
        try self.service.close(self.frame);
        self.service_live = false;
        try self.namespace.close();
        self.namespace_live = false;
    }

    fn openOwner(self: *PureRecoveryFixture) !void {
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        self.service = try native.tasks.Service(FairTypes).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
    }

    fn deinit(self: *PureRecoveryFixture) void {
        if (self.recovery_live) self.recovery.deinit();
        if (self.worker_releasable) expectCleanup(self.worker.release());
        if (self.worker_started and self.worker.future != null) {
            Pure.hold.store(false, .release);
            self.worker.cancel();
            expectCleanup(awaitLookup(self.io, self.worker));
            if (self.service.work != null) expectCleanup(
                self.service.notSent(self.frame, self.work),
            );
            expectCleanup(self.worker.release());
        }
        if (self.worker_live) expectCleanup(self.worker.deinit(self.a));
        if (self.unknown_live) self.unknown.deinit();
        if (self.service_live) expectCleanup(self.service.close(self.frame));
        if (self.namespace_live) expectCleanup(self.namespace.close());
        if (self.temporary_live) self.temporary.cleanup();
        if (self.handlers_live) self.handlers.deinit();
        Pure.hold.store(false, .release);
        if (self.application_live) self.application.deinit();
        if (self.admitted_image_live) self.admitted_image.deinit();
        if (self.arena_live) self.arena.deinit();
    }
};
test "receipt lookup retains exclusive admission and verifies evidence through its worker" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var h: ReceiptLookupHarness = .{
        .a = a,
        .io = std.testing.io,
        .frame = arena.allocator(),
        .temporary = &temporary,
    };
    defer h.deinit();
    try h.prepareAssets();
    try h.prepareRegistry();
    try h.prepareOwner();
    const original = try h.admitOriginal();
    try h.exclusiveAdmission(original);
    try h.runHeldLookup(original);
    try h.settleOriginal(original);
    const interrupted = try h.exportInterrupted(original);
    try h.checkArchives(original, interrupted);
    try h.interruptedLookup(interrupted);
    try h.proveNotSent(interrupted);
    try h.rejectedLookups();
    try h.verificationFailures();
    try h.fencedLookup();
    try h.malformedCapture();
    try h.publicationFaults();
}

const LookupState = native.testing.state;
const LookupCase = struct {
    work: native.tasks.Work,
    revision: u64,
    admission: native.tasks.Admission,
    attempts: u64,
    request_bytes: u64,
};
const LookupArchives = struct {
    interrupted: LookupCase,
    pending: []const u8,
    settled: []const u8,
};
const LookupPublicationStage = enum { admission, capture, settlement };
const LookupPublicationFault = enum { write, commit, seal };
const LookupFaultWork = struct {
    recovery_id: ?LookupState.Digest = null,
    selected: ?native.tasks.Work = null,
    acquired: ?[]const u8 = null,
};
const ReceiptLookupHarness = struct {
    a: std.mem.Allocator,
    io: std.Io,
    frame: std.mem.Allocator,
    temporary: *std.testing.TmpDir,
    assets: native.discovery.Assets = undefined,
    application: native.discovery.Application = undefined,
    application_live: bool = false,
    leaf: native.Declaration = undefined,
    handlers: native.Registry = undefined,
    handlers_live: bool = false,
    fixture: LookupFixture = .{},
    grants: [3]native.registry.Grant = undefined,
    profile: native.tasks.Profile = undefined,
    directory: []const u8 = undefined,
    path: []const u8 = undefined,
    namespace: native.Namespace = undefined,
    namespace_live: bool = false,
    service: native.tasks.Service(FairTypes) = undefined,
    service_live: bool = false,
    worker: ?*native.testing.Worker = null,
    original_work: native.tasks.Work = undefined,

    fn deinit(h: *ReceiptLookupHarness) void {
        if (h.worker) |worker| {
            if (worker.future != null) {
                h.fixture.hold.store(false, .release);
                expectCleanup(awaitLookup(h.io, worker));
                expectCleanup(h.service.unknown(h.frame, h.original_work));
                expectCleanup(worker.release());
            }
            expectCleanup(worker.deinit(h.a));
        }
        if (h.service_live) expectCleanup(h.service.close(h.frame));
        if (h.namespace_live) expectCleanup(h.namespace.close());
        if (h.handlers_live) h.handlers.deinit();
        if (h.application_live) h.application.deinit();
    }
    fn closeOwner(h: *ReceiptLookupHarness) !void {
        try h.service.close(h.frame);
        h.service_live = false;
        try h.namespace.close();
        h.namespace_live = false;
    }
    fn openNamespace(h: *ReceiptLookupHarness) !void {
        h.namespace = try native.Namespace.open(h.a, h.io, h.path);
        h.namespace_live = true;
    }
    fn openService(h: *ReceiptLookupHarness) !void {
        h.service = try native.tasks.Service(FairTypes).init(
            h.a,
            h.io,
            &h.namespace,
            h.assets,
            &h.application,
            h.handlers,
            h.profile,
        );
        h.service_live = true;
    }
    fn prepareAssets(h: *ReceiptLookupHarness) !void {
        var compiled = try protean.compile(
            h.a,
            protean.system(.{
                .InitialArgs = u32,
                .Result = u32,
                .Failure = void,
                .application = FairApplication,
            }),
        );
        defer compiled.deinit();
        const image = try h.frame.alloc(
            u8,
            try horos.data.program_image.encodedLength(compiled.program),
        );
        _ = try compiled.encode(h.a, image);
        const admitted_image = try horos.data.program_image.Admitted.decode(h.a, image);
        defer admitted_image.deinit();
        const manifest = try ownerManifest(
            h.frame,
            image,
            admitted_image.identity(),
            "lookup-owner",
        );
        h.assets = .{
            .image = image,
            .application = "lookup-owner",
            .manifest = manifest,
        };
        h.application = .{
            .arena = .init(h.a),
            .metadata = .null,
            .manifest = .null,
            .manifest_id = "unit",
            .image_identity = admitted_image.identity(),
        };
        h.application_live = true;
        h.application.manifest = (try native.json.parse(
            h.application.arena.allocator(),
            manifest,
            .{},
        )).value;
    }

    fn prepareRegistry(h: *ReceiptLookupHarness) !void {
        h.leaf = native.leaf(
            u32,
            u32,
            .{ .identity = "fair.leaf.v1", .resource_role = "local", .inference = true },
            increment,
        );
        h.leaf.capture = .{
            .prepare = FairCapture.prepare,
            .acquire = LookupFixture.forbidden,
            .interpret = LookupFixture.interpret,
            .dependencies = native.registry.opaqueProjection,
        };
        h.leaf.invoke = null;
        h.leaf.background = true;
        h.leaf.recovery = .{ .identity = "signed-fixture-receipt.v1", .version = 1, .lookup = .{
            .acquire = LookupFixture.lookup,
            .verify = LookupFixture.verify,
        } };
        h.handlers = try native.Registry.init(h.a, &.{
            h.leaf,
            native.question(
                u32,
                u32,
                .{
                    .identity = "fair.question.v1",
                    .resource_role = "user",
                    .answer_schema_id = "fair.answer.v1",
                },
                FairCapture.present,
            ),
            native.inbox.declaration(u32),
        });
        h.handlers_live = true;
    }

    fn prepareOwner(h: *ReceiptLookupHarness) !void {
        h.profile = .{ .id = "lookup", .runtime_identity = @splat(
            42,
        ), .bytes = "frozen-profile", .environment = &h.fixture, .authority = .{
            .grants = &h.grants,
            .principal = "test",
            .tenant = "test",
            .inference = true,
        } };
        for (&h.grants, h.handlers.entries) |*grant, entry| grant.* = .{
            .identity = entry.declaration.identity,
            .resource_role = entry.declaration.resource_role,
            .resource_identity = try h.profile.resourceIdentity(
                h.frame,
                h.application.image_identity,
            ),
        };
        var buffer: [4096]u8 = undefined;
        const length = try h.temporary.dir.realPath(h.io, &buffer);
        h.directory = try h.frame.dupe(u8, buffer[0..length]);
        h.path = try std.fmt.allocPrint(h.frame, "{s}/lookup", .{h.directory});
        try h.openNamespace();
        try h.openService();
    }

    fn admitOriginal(h: *ReceiptLookupHarness) !LookupCase {
        // A real reopen drops the original worker; the original effect callback
        // is forbidden throughout this fixture.
        const original = try lookupUnknown(&h.service, h.frame, "original");
        try h.closeOwner();
        try h.openNamespace();
        try h.openService();
        var before = try h.service.task(h.frame, original.task);
        defer before.deinit();
        const revision = before.value.revision;
        h.service.profile.authority.grants = &.{};
        const head = h.namespace.store.head;
        try std.testing.expectError(
            error.Denied,
            h.service.reconcile(
                h.frame,
                "lookup",
                original.task,
                revision,
                original.occurrence,
                original.attempt,
                .lookup,
            ),
        );
        try std.testing.expectEqualDeep(head, h.namespace.store.head);
        h.service.profile.authority.grants = &h.grants;
        const admission = try h.service.reconcile(
            h.frame,
            "lookup",
            original.task,
            revision,
            original.occurrence,
            original.attempt,
            .lookup,
        );
        return .{
            .work = original,
            .revision = revision,
            .admission = admission,
            .attempts = before.value.inference_attempts,
            .request_bytes = before.value.inference_request_bytes,
        };
    }

    fn exclusiveAdmission(h: *ReceiptLookupHarness, original_case: LookupCase) !void {
        const original = original_case.work;
        const revision = original_case.revision;
        const admission = original_case.admission;
        const id = admission.receipt.reconciliation.?;
        var pending = try h.service.reconciliation(h.frame, original.task, id);
        defer pending.deinit();
        try std.testing.expect(pending.value.outcome == .pending);
        try std.testing.expectEqual(0, h.fixture.calls.load(.acquire));
        try std.testing.expect(
            (try h.service.reconcile(
                h.frame,
                "lookup",
                original.task,
                revision,
                original.occurrence,
                original.attempt,
                .lookup,
            )).replayed,
        );
        try std.testing.expectError(
            error.OperationConflict,
            h.service.reconcile(
                h.frame,
                "lookup",
                original.task,
                revision,
                original.occurrence,
                original.attempt,
                .rederive,
            ),
        );
        try std.testing.expectError(
            error.UnsettledOccurrence,
            h.service.reconcile(
                h.frame,
                "competitor",
                original.task,
                admission.receipt.revision,
                original.occurrence,
                original.attempt,
                .lookup,
            ),
        );
    }

    fn runHeldLookup(h: *ReceiptLookupHarness, original_case: LookupCase) !void {
        const original = original_case.work;
        const revision = original_case.revision;
        h.fixture.hold.store(true, .release);
        const work = (try h.service.pump(h.frame)).work;
        h.worker = try native.testing.Worker.init(h.a, h.io);
        h.original_work = work;
        try h.worker.?.start(work, h.service.profile.authority, &h.fixture);
        const deadline = std.Io.Clock.awake.now(h.io).toMilliseconds() + 5000;
        while (!h.fixture.started.load(.acquire)) {
            if (std.Io.Clock.awake.now(h.io).toMilliseconds() >= deadline) return error.TestTimeout;
            try h.io.sleep(.fromMilliseconds(1), .awake);
        }
        _ = try h.service.message(h.frame, "during-lookup", original.task, 11);
        _ = try h.service.requestCancel(h.frame, "cancel-during-lookup", original.task, "stop");
        const peer = try h.service.submit(h.frame, "lookup-peer", 4);
        for (0..6) |_| try std.testing.expect(try h.service.pump(h.frame) != .work);
        var peer_result = try h.service.task(h.frame, peer.receipt.task);
        defer peer_result.deinit();
        try std.testing.expect(peer_result.value.outcome_kind == .completed);
        try std.testing.expect(
            (try h.service.reconcile(
                h.frame,
                "lookup",
                original.task,
                revision,
                original.occurrence,
                original.attempt,
                .lookup,
            )).replayed,
        );
        try std.testing.expectEqual(1, h.fixture.calls.load(.acquire));
        h.fixture.hold.store(false, .release);
        try awaitLookup(h.io, h.worker.?);
        const evidence = (h.worker.?.result orelse return error.MissingEvidence).acquired;
        inline for (.{ "owner_epoch", "task", "occurrence", "attempt" }) |field| {
            var stale = work;
            @field(stale, field)[0] ^= 1;
            try std.testing.expectError(
                error.StaleOccurrence,
                h.service.acquire(h.frame, stale, evidence),
            );
        }
        var stale = work;
        stale.recovery.?.id[0] ^= 1;
        try std.testing.expectError(
            error.StaleOccurrence,
            h.service.acquire(h.frame, stale, evidence),
        );
        try h.service.acquire(h.frame, work, evidence);
        try h.worker.?.release();
        try std.testing.expectError(error.StaleOccurrence, h.service.acquire(h.frame, work, &.{}));
    }

    fn settleOriginal(h: *ReceiptLookupHarness, original_case: LookupCase) !void {
        const original = original_case.work;
        const revision = original_case.revision;
        const id = original_case.admission.receipt.reconciliation.?;
        var capture = try h.service.reconciliation(h.frame, original.task, id);
        defer capture.deinit();
        try std.testing.expect(
            capture.value.outcome == .capture_admitted and capture.value.provenance == .authentic,
        );
        try std.testing.expect(capture.value.evidence != null and capture.value.previous != null);
        try std.testing.expectError(
            error.ArtifactUnavailable,
            h.service.projectedArtifact(h.frame, original.task, capture.value.evidence.?.digest),
        );
        try std.testing.expectError(
            error.ArtifactUnavailable,
            h.service.projectedArtifact(
                h.frame,
                original.task,
                capture.value.outcome.capture_admitted.digest,
            ),
        );
        for (0..6) |_| try std.testing.expect(try h.service.pump(h.frame) != .work);
        var settled = try h.service.reconciliation(h.frame, original.task, id);
        defer settled.deinit();
        try std.testing.expect(settled.value.outcome == .reply_settled);
        var charged = try h.service.task(h.frame, original.task);
        defer charged.deinit();
        try std.testing.expectEqual(original_case.attempts, charged.value.inference_attempts);
        try std.testing.expectEqual(
            original_case.request_bytes,
            charged.value.inference_request_bytes,
        );
        try std.testing.expectEqual(7, charged.value.inference_output_tokens);
        try std.testing.expect(charged.value.cancellation != null);
        try std.testing.expect(
            (try h.service.reconcile(
                h.frame,
                "lookup",
                original.task,
                revision,
                original.occurrence,
                original.attempt,
                .lookup,
            )).replayed,
        );
        _ = try h.namespace.store.auditRetention(h.handlers, h.application.image_identity);
    }

    fn exportInterrupted(h: *ReceiptLookupHarness, original_case: LookupCase) !LookupArchives {
        const original = original_case.work;
        // Durable admission with no worker survives a restart as interrupted.
        const interrupted = try lookupUnknown(&h.service, h.frame, "interrupt-original");
        var interrupt_task = try h.service.task(h.frame, interrupted.task);
        defer interrupt_task.deinit();
        const admitted = try h.service.reconcile(
            h.frame,
            "interrupted-lookup",
            interrupted.task,
            interrupt_task.value.revision,
            interrupted.occurrence,
            interrupted.attempt,
            .lookup,
        );
        const pending_archive = try std.fmt.allocPrint(h.frame, "{s}/pending.agnx", .{h.directory});
        _ = try h.service.exportCheckpoint(h.frame, interrupted.task, pending_archive);
        const settled_archive = try std.fmt.allocPrint(h.frame, "{s}/settled.agnx", .{h.directory});
        _ = try h.service.exportCheckpoint(h.frame, original.task, settled_archive);
        try h.closeOwner();
        return .{
            .interrupted = .{
                .work = interrupted,
                .revision = interrupt_task.value.revision,
                .admission = admitted,
                .attempts = interrupt_task.value.inference_attempts,
                .request_bytes = interrupt_task.value.inference_request_bytes,
            },
            .pending = pending_archive,
            .settled = settled_archive,
        };
    }

    fn serviceAt(
        h: *ReceiptLookupHarness,
        ns: *native.Namespace,
        selected: native.Registry,
    ) !native.tasks.Service(
        FairTypes,
    ) {
        return native.tasks.Service(FairTypes).init(
            h.a,
            h.io,
            ns,
            h.assets,
            &h.application,
            selected,
            h.profile,
        );
    }

    fn rejectArchiveRegistry(
        h: *ReceiptLookupHarness,
        incompatible_handlers: native.Registry,
        archive_path: []const u8,
        index: usize,
    ) !void {
        const rejected_target = try std.fmt.allocPrint(h.frame, "{s}/rejected-{d}", .{
            h.directory,
            index,
        });
        var rejected_namespace = try native.Namespace.open(h.a, h.io, rejected_target);
        defer expectCleanup(rejected_namespace.close());
        var rejected = try h.serviceAt(&rejected_namespace, incompatible_handlers);
        defer expectCleanup(rejected.close(h.frame));
        const before_import = rejected_namespace.store.head;
        try std.testing.expectError(
            error.CorruptState,
            rejected.importCheckpoint(h.frame, "import-recovery", archive_path),
        );
        try std.testing.expectEqualDeep(before_import, rejected_namespace.store.head);
        _ = try rejected.submit(h.frame, "after-rejected-import", 4);
    }

    fn archiveOne(
        h: *ReceiptLookupHarness,
        original_case: LookupCase,
        archives: LookupArchives,
        archive_path: []const u8,
        index: usize,
    ) !void {
        var incompatible_leaf = h.leaf;
        incompatible_leaf.recovery.?.version += 1;
        var incompatible_handlers = try native.Registry.init(h.a, &.{
            incompatible_leaf,
            native.question(
                u32,
                u32,
                .{
                    .identity = "fair.question.v1",
                    .resource_role = "user",
                    .answer_schema_id = "fair.answer.v1",
                },
                FairCapture.present,
            ),
            native.inbox.declaration(u32),
        });
        defer incompatible_handlers.deinit();
        try h.rejectArchiveRegistry(incompatible_handlers, archive_path, index);
        try h.copyArchive(original_case, archives, incompatible_handlers, archive_path, index);
    }

    fn checkArchives(
        h: *ReceiptLookupHarness,
        original_case: LookupCase,
        archives: LookupArchives,
    ) !void {
        for ([_][]const u8{ archives.pending, archives.settled }, 0..) |archive_path, index| {
            try h.archiveOne(original_case, archives, archive_path, index);
        }
        try h.openNamespace();
        try h.openService();
    }

    fn copiedPending(
        h: *ReceiptLookupHarness,
        copied: anytype,
        recovery: anytype,
        task_id: LookupState.TaskId,
        archives: LookupArchives,
    ) !void {
        const interrupted = archives.interrupted.work;
        const admitted = archives.interrupted.admission;
        try std.testing.expect(
            recovery.value.outcome == .unresolved and
                recovery.value.outcome.unresolved == .interrupted,
        );
        const replayed = try copied.reconcile(
            h.frame,
            "interrupted-lookup",
            task_id,
            archives.interrupted.revision,
            interrupted.occurrence,
            interrupted.attempt,
            .lookup,
        );
        try std.testing.expect(replayed.replayed);
        try std.testing.expectEqualDeep(admitted.receipt, replayed.receipt);
        try std.testing.expectError(
            error.CustodyNotLocal,
            copied.reconcile(
                h.frame,
                "copied-new-lookup",
                task_id,
                archives.interrupted.revision,
                interrupted.occurrence,
                interrupted.attempt,
                .lookup,
            ),
        );
    }

    fn copiedSettled(
        h: *ReceiptLookupHarness,
        copied: anytype,
        recovery: anytype,
        task_id: LookupState.TaskId,
        original_case: LookupCase,
    ) !void {
        const original = original_case.work;
        const revision = original_case.revision;
        const admission = original_case.admission;
        try std.testing.expect(
            recovery.value.outcome == .reply_settled and recovery.value.provenance == .authentic,
        );
        try std.testing.expectError(
            error.ArtifactUnavailable,
            copied.projectedArtifact(h.frame, task_id, recovery.value.evidence.?.digest),
        );
        const replayed = try copied.reconcile(
            h.frame,
            "lookup",
            task_id,
            revision,
            original.occurrence,
            original.attempt,
            .lookup,
        );
        try std.testing.expect(replayed.replayed);
        try std.testing.expectEqualDeep(admission.receipt, replayed.receipt);
        try std.testing.expectError(
            error.CustodyNotLocal,
            copied.reconcile(
                h.frame,
                "copied-new-lookup",
                task_id,
                revision,
                original.occurrence,
                original.attempt,
                .lookup,
            ),
        );
    }

    fn copyArchive(
        h: *ReceiptLookupHarness,
        original_case: LookupCase,
        archives: LookupArchives,
        incompatible_handlers: native.Registry,
        archive_path: []const u8,
        index: usize,
    ) !void {
        const target = try std.fmt.allocPrint(h.frame, "{s}/import-{d}", .{
            h.directory,
            index,
        });
        var copied_namespace = try native.Namespace.open(h.a, h.io, target);
        defer expectCleanup(copied_namespace.close());
        var copied = try h.serviceAt(&copied_namespace, incompatible_handlers);
        defer expectCleanup(copied.close(h.frame));
        try std.testing.expectError(
            error.CorruptState,
            copied.importCheckpoint(h.frame, "import-recovery", archive_path),
        );
        // Select the compatible registry without reopening the rejected owner.
        // The failed operation ID must remain available for the valid retry.
        copied.handlers = h.handlers;
        _ = try copied.importCheckpoint(h.frame, "import-recovery", archive_path);
        try std.testing.expect(try copied.pump(h.frame) == .idle);
        const task_id = if (index == 0) archives.interrupted.work.task else original_case.work.task;
        const selected_admission = if (index == 0)
            archives.interrupted.admission
        else
            original_case.admission;
        const recovery_id = selected_admission.receipt.reconciliation.?;
        var recovery = try copied.reconciliation(h.frame, task_id, recovery_id);
        defer recovery.deinit();
        const copied_head = copied_namespace.store.head;
        if (index == 0) {
            try h.copiedPending(&copied, &recovery, task_id, archives);
        } else {
            try h.copiedSettled(&copied, &recovery, task_id, original_case);
        }
        try std.testing.expectEqualDeep(copied_head, copied_namespace.store.head);
        try @import("native_test_support.zig").expectRetainedReceipt(
            h.frame,
            &copied_namespace,
            selected_admission.receipt,
        );
        try std.testing.expectError(
            error.ArtifactUnavailable,
            copied.projectedArtifact(h.frame, task_id, recovery.value.original_occurrence.digest),
        );
        _ = try copied_namespace.store.auditRetention(h.handlers, h.application.image_identity);
        try std.testing.expectEqual(1, h.fixture.calls.load(.acquire));
    }

    fn interruptedLookup(h: *ReceiptLookupHarness, archives: LookupArchives) !void {
        const interrupted = archives.interrupted.work;
        const admitted = archives.interrupted.admission;
        var lost = try h.service.reconciliation(
            h.frame,
            interrupted.task,
            admitted.receipt.reconciliation.?,
        );
        defer lost.deinit();
        try std.testing.expect(
            lost.value.outcome == .unresolved and lost.value.outcome.unresolved == .interrupted,
        );
        try std.testing.expectEqual(1, h.fixture.calls.load(.acquire));
        try std.testing.expect(
            (try h.service.reconcile(
                h.frame,
                "interrupted-lookup",
                interrupted.task,
                archives.interrupted.revision,
                interrupted.occurrence,
                interrupted.attempt,
                .lookup,
            )).replayed,
        );
        try std.testing.expect(try h.service.pump(h.frame) == .idle);
    }

    fn proveNotSent(h: *ReceiptLookupHarness, archives: LookupArchives) !void {
        const interrupted = archives.interrupted.work;
        // A new explicit lookup can establish non-invocation. It does not dispatch
        // a new effect; only a later explicit resume could create another attempt.
        var resumed = try h.service.task(h.frame, interrupted.task);
        defer resumed.deinit();
        const proof_admission = try h.service.reconcile(
            h.frame,
            "proof-not-sent",
            interrupted.task,
            resumed.value.revision,
            interrupted.occurrence,
            interrupted.attempt,
            .lookup,
        );
        const proof_work = (try h.service.pump(h.frame)).work;
        h.fixture.kind = .not_sent;
        try h.worker.?.start(proof_work, h.service.profile.authority, &h.fixture);
        try awaitLookup(h.io, h.worker.?);
        try h.service.completeWork(h.frame, proof_work, h.worker.?.result.?);
        try h.worker.?.release();
        var proof = try h.service.reconciliation(
            h.frame,
            interrupted.task,
            proof_admission.receipt.reconciliation.?,
        );
        defer proof.deinit();
        try std.testing.expect(
            proof.value.outcome == .not_sent and proof.value.provenance == .authoritative,
        );
        try std.testing.expect(try h.service.pump(h.frame) == .idle);
        _ = try h.service.requestCancel(
            h.frame,
            "cancel-proven-not-sent",
            interrupted.task,
            "stop",
        );
        for (0..6) |_| try std.testing.expect(try h.service.pump(h.frame) != .work);
        var cancelled = try h.service.task(h.frame, interrupted.task);
        defer cancelled.deinit();
        try std.testing.expect(cancelled.value.outcome_kind == .cancelled);
        try std.testing.expectEqual(1, cancelled.value.inference_attempts);
        _ = try h.namespace.store.auditRetention(h.handlers, h.application.image_identity);
    }

    fn supplyRejectedLookup(h: *ReceiptLookupHarness, scenario: []const u8) !void {
        if (std.mem.eql(u8, scenario, "revoked")) {
            h.service.profile.authority.grants = &.{};
            try std.testing.expect(try h.service.pump(h.frame) == .progressed);
            h.service.profile.authority.grants = &h.grants;
        } else {
            const selected = (try h.service.pump(h.frame)).work;
            if (std.mem.eql(u8, scenario, "unavailable")) {
                // Failure to start/read the lookup is never historical proof
                // that the original invocation did not run.
                try h.service.notSent(h.frame, selected);
            } else {
                var record = try protean.contracts.decodeOwned(
                    LookupState.Reconciliation,
                    h.frame,
                    selected.recovery.?.body,
                );
                defer record.deinit();
                var request = try protocol.decode(protocol.Request, h.frame, selected.request);
                defer request.deinit();
                var input = native.registry.RecoveryInput.fromReconciliation(
                    record.value,
                    request.value.request_identity,
                    true,
                );
                if (std.mem.eql(u8, scenario, "foreign")) input.task[0] ^= 1;
                if (std.mem.eql(u8, scenario, "prepared")) input.prepared.?.digest[0] ^= 1;
                if (std.mem.eql(u8, scenario, "profile")) input.profile.digest[0] ^= 1;
                const kind: LookupFixture.Kind = if (std.mem.eql(
                    u8,
                    scenario,
                    "verifier-unavailable",
                )) .unavailable else std.meta.stringToEnum(
                    LookupFixture.Kind,
                    scenario,
                ) orelse .capture;
                const evidence_bytes = if (std.mem.eql(
                    u8,
                    scenario,
                    "fabricated",
                )) "fabricated receipt" else try LookupFixture.receipt(h.frame, input, kind);
                try h.service.acquire(h.frame, selected, evidence_bytes);
            }
        }
    }

    fn assertRejectedLookup(
        h: *ReceiptLookupHarness,
        scenario: []const u8,
        subject: native.tasks.Work,
        subject_task: anytype,
        operation_id: []const u8,
        accepted: native.tasks.Admission,
    ) !void {
        var result = try h.service.reconciliation(
            h.frame,
            subject.task,
            accepted.receipt.reconciliation.?,
        );
        defer result.deinit();
        try std.testing.expect(result.value.outcome == .unresolved);
        const reason = result.value.outcome.unresolved;
        if (std.mem.eql(
            u8,
            scenario,
            "unavailable",
        ) or std.mem.eql(
            u8,
            scenario,
            "verifier-unavailable",
        ) or std.mem.eql(
            u8,
            scenario,
            "revoked",
        )) {
            try std.testing.expect(reason == .unavailable);
        } else if (std.mem.eql(u8, scenario, "inconclusive")) {
            try std.testing.expect(reason == .inconclusive);
        } else try std.testing.expect(reason == .rejected);
        var unchanged = try h.service.task(h.frame, subject.task);
        defer unchanged.deinit();
        try std.testing.expectEqual(.unknown, try h.service.status(h.frame, unchanged.value));
        try std.testing.expectEqual(
            subject_task.value.inference_attempts,
            unchanged.value.inference_attempts,
        );
        try std.testing.expectEqual(
            subject_task.value.inference_request_bytes,
            unchanged.value.inference_request_bytes,
        );
        try std.testing.expectEqual(0, unchanged.value.inference_output_tokens);
        try std.testing.expect(
            (try h.service.reconcile(
                h.frame,
                operation_id,
                subject.task,
                subject_task.value.revision,
                subject.occurrence,
                subject.attempt,
                .lookup,
            )).replayed,
        );
        if (result.value.evidence) |proof_ref| try std.testing.expectError(
            error.ArtifactUnavailable,
            h.service.projectedArtifact(h.frame, subject.task, proof_ref.digest),
        );
    }

    fn rejectedLookup(h: *ReceiptLookupHarness, scenario: []const u8) !void {
        const subject = try lookupUnknown(&h.service, h.frame, scenario);
        var subject_task = try h.service.task(h.frame, subject.task);
        defer subject_task.deinit();
        const operation_id = try std.fmt.allocPrint(h.frame, "lookup-{s}", .{scenario});
        const accepted = try h.service.reconcile(
            h.frame,
            operation_id,
            subject.task,
            subject_task.value.revision,
            subject.occurrence,
            subject.attempt,
            .lookup,
        );
        try h.supplyRejectedLookup(scenario);
        try h.assertRejectedLookup(scenario, subject, &subject_task, operation_id, accepted);
    }

    fn rejectedLookups(h: *ReceiptLookupHarness) !void {
        for ([_][]const u8{
            "fabricated",
            "foreign",
            "prepared",
            "profile",
            "inconclusive",
            "verifier-unavailable",
            "rejected",
            "unavailable",
            "revoked",
        }) |scenario| {
            try h.rejectedLookup(scenario);
        }
        try std.testing.expectEqual(2, h.fixture.calls.load(.acquire));
        _ = try h.namespace.store.auditRetention(h.handlers, h.application.image_identity);
    }

    fn restoredVerificationFailure(
        h: *ReceiptLookupHarness,
        subject: native.tasks.Work,
        unknown: anytype,
        recovery_operation: []const u8,
        accepted: native.tasks.Admission,
    ) !void {
        var interrupted_result = try h.service.reconciliation(
            h.frame,
            subject.task,
            accepted.receipt.reconciliation.?,
        );
        defer interrupted_result.deinit();
        try std.testing.expect(
            interrupted_result.value.outcome == .unresolved and
                interrupted_result.value.outcome.unresolved == .interrupted,
        );
        var unchanged = try h.service.task(h.frame, subject.task);
        defer unchanged.deinit();
        try std.testing.expectEqual(.unknown, try h.service.status(h.frame, unchanged.value));
        try std.testing.expectEqual(
            unknown.value.inference_attempts,
            unchanged.value.inference_attempts,
        );
        try std.testing.expect(
            (try h.service.reconcile(
                h.frame,
                recovery_operation,
                subject.task,
                unknown.value.revision,
                subject.occurrence,
                subject.attempt,
                .lookup,
            )).replayed,
        );
        try std.testing.expect(try h.service.pump(h.frame) == .idle);
    }

    fn verificationFailure(h: *ReceiptLookupHarness, failure: anyerror) !void {
        const operation = try std.fmt.allocPrint(h.frame, "verify-{s}", .{@errorName(failure)});
        const subject = try lookupUnknown(&h.service, h.frame, operation);
        var unknown = try h.service.task(h.frame, subject.task);
        defer unknown.deinit();
        const recovery_operation = try std.fmt.allocPrint(h.frame, "recover-{s}", .{
            @errorName(failure),
        });
        const accepted = try h.service.reconcile(
            h.frame,
            recovery_operation,
            subject.task,
            unknown.value.revision,
            subject.occurrence,
            subject.attempt,
            .lookup,
        );
        const selected = (try h.service.pump(h.frame)).work;
        const before_failure = h.namespace.store.head;
        try std.testing.expectError(
            failure,
            h.service.acquire(h.frame, selected, @errorName(failure)),
        );
        try std.testing.expectEqualDeep(before_failure, h.namespace.store.head);
        try std.testing.expect(h.namespace.store.fenced);
        try std.testing.expect(h.service.work == null);
        try h.closeOwner();
        try h.openNamespace();
        // Before owner recovery, the failed verification has committed no
        // completed outcome. Reopen subsequently records interruption, never
        // evidence rejection or an automatic replacement lookup.
        var retained = try protean.contracts.decodeOwned(
            LookupState.Reconciliation,
            h.frame,
            (try h.namespace.store.recordBytes(
                h.frame,
                "reconciliation",
                accepted.receipt.reconciliation.?,
                subject.task,
            )).?,
        );
        defer retained.deinit();
        try std.testing.expect(retained.value.outcome == .pending);
        try h.openService();
        try h.restoredVerificationFailure(subject, &unknown, recovery_operation, accepted);
    }

    fn verificationFailures(h: *ReceiptLookupHarness) !void {
        for (LookupFixture.verification_failures) |failure| {
            try h.verificationFailure(failure);
        }
        try std.testing.expectEqual(2, h.fixture.calls.load(.acquire));
    }

    fn fencedLookup(h: *ReceiptLookupHarness) !void {
        const fenced = try lookupUnknown(&h.service, h.frame, "fenced-original");
        var fenced_task = try h.service.task(h.frame, fenced.task);
        defer fenced_task.deinit();
        const fenced_admission = try h.service.reconcile(
            h.frame,
            "fenced-lookup",
            fenced.task,
            fenced_task.value.revision,
            fenced.occurrence,
            fenced.attempt,
            .lookup,
        );
        const fenced_work = (try h.service.pump(h.frame)).work;
        const sealed = h.namespace.store.head;
        h.namespace.store.fence();
        try std.testing.expectError(
            error.StorageUnavailable,
            h.service.acquire(h.frame, fenced_work, "late evidence"),
        );
        try std.testing.expectEqualDeep(sealed, h.namespace.store.head);
        try h.closeOwner();
        try h.openNamespace();
        try h.openService();
        var abandoned = try h.service.reconciliation(
            h.frame,
            fenced.task,
            fenced_admission.receipt.reconciliation.?,
        );
        defer abandoned.deinit();
        try std.testing.expect(
            abandoned.value.outcome == .unresolved and
                abandoned.value.outcome.unresolved == .interrupted,
        );
        try std.testing.expectError(
            error.StaleOccurrence,
            h.service.acquire(h.frame, fenced_work, "late evidence"),
        );
        try std.testing.expectEqual(2, h.fixture.calls.load(.acquire));
    }

    fn invalidCaptureEvidence(h: *ReceiptLookupHarness, malformed_work: native.tasks.Work) ![]u8 {
        var malformed_record = try protean.contracts.decodeOwned(
            LookupState.Reconciliation,
            h.frame,
            malformed_work.recovery.?.body,
        );
        defer malformed_record.deinit();
        var malformed_request = try protocol.decode(
            protocol.Request,
            h.frame,
            malformed_work.request,
        );
        defer malformed_request.deinit();
        return LookupFixture.receiptValue(
            h.frame,
            native.registry.RecoveryInput.fromReconciliation(
                malformed_record.value,
                malformed_request.value.request_identity,
                true,
            ),
            .capture,
            98,
        );
    }

    fn retryMalformedCapture(
        h: *ReceiptLookupHarness,
        malformed: native.tasks.Work,
        malformed_admission: native.tasks.Admission,
        rejected_capture: anytype,
    ) !void {
        var retained_capture = try h.service.reconciliation(
            h.frame,
            malformed.task,
            malformed_admission.receipt.reconciliation.?,
        );
        defer retained_capture.deinit();
        try std.testing.expectEqualDeep(
            rejected_capture.value.outcome,
            retained_capture.value.outcome,
        );
        var retry_capture = try h.service.task(h.frame, malformed.task);
        defer retry_capture.deinit();
        _ = try h.service.resumeTask(
            h.frame,
            "retry-invalid-capture",
            malformed.task,
            retry_capture.value.revision,
        );
        try std.testing.expect(try h.service.pump(h.frame) == .waiting);
        var still_unsettled = try h.service.task(h.frame, malformed.task);
        defer still_unsettled.deinit();
        try std.testing.expectEqual(0, still_unsettled.value.inference_output_tokens);
        try std.testing.expectEqual(1, still_unsettled.value.inference_attempts);
        _ = try h.namespace.store.auditRetention(h.handlers, h.application.image_identity);
    }

    fn malformedCapture(h: *ReceiptLookupHarness) !void {
        // Authentication does not certify interpretation. Retain the authentic
        // bytes and admission even when the original interpreter rejects them.
        const malformed = try lookupUnknown(&h.service, h.frame, "authentic-invalid-capture");
        var malformed_task = try h.service.task(h.frame, malformed.task);
        defer malformed_task.deinit();
        const malformed_admission = try h.service.reconcile(
            h.frame,
            "lookup-invalid-capture",
            malformed.task,
            malformed_task.value.revision,
            malformed.occurrence,
            malformed.attempt,
            .lookup,
        );
        const malformed_work = (try h.service.pump(h.frame)).work;
        const malformed_evidence = try h.invalidCaptureEvidence(malformed_work);
        try h.service.acquire(h.frame, malformed_work, malformed_evidence);
        try std.testing.expect(try h.service.pump(h.frame) == .waiting);
        var rejected_capture = try h.service.reconciliation(
            h.frame,
            malformed.task,
            malformed_admission.receipt.reconciliation.?,
        );
        defer rejected_capture.deinit();
        try std.testing.expect(
            rejected_capture.value.outcome == .capture_admitted and
                rejected_capture.value.provenance == .authentic,
        );
        const rejected_archive = try std.fmt.allocPrint(h.frame, "{s}/authentic-invalid.agnx", .{
            h.directory,
        });
        _ = try h.service.exportCheckpoint(h.frame, malformed.task, rejected_archive);
        try h.closeOwner();
        try h.openNamespace();
        try h.openService();
        try h.retryMalformedCapture(malformed, malformed_admission, &rejected_capture);
    }

    fn preparePublication(
        h: *ReceiptLookupHarness,
        stage: LookupPublicationStage,
        subject: native.tasks.Work,
        revision: u64,
        operation_id: []const u8,
    ) !LookupFaultWork {
        var recovery_id: ?LookupState.Digest = null;
        var selected: ?native.tasks.Work = null;
        var acquired: ?[]const u8 = null;
        if (stage != .admission) {
            const accepted = try h.service.reconcile(
                h.frame,
                operation_id,
                subject.task,
                revision,
                subject.occurrence,
                subject.attempt,
                .lookup,
            );
            recovery_id = accepted.receipt.reconciliation.?;
            selected = (try h.service.pump(h.frame)).work;
            var record = try protean.contracts.decodeOwned(
                LookupState.Reconciliation,
                h.frame,
                selected.?.recovery.?.body,
            );
            defer record.deinit();
            var request = try protocol.decode(protocol.Request, h.frame, selected.?.request);
            defer request.deinit();
            acquired = try LookupFixture.receipt(
                h.frame,
                native.registry.RecoveryInput.fromReconciliation(
                    record.value,
                    request.value.request_identity,
                    true,
                ),
                .capture,
            );
            if (stage == .settlement) try h.service.acquire(h.frame, selected.?, acquired.?);
        }
        return .{ .recovery_id = recovery_id, .selected = selected, .acquired = acquired };
    }

    fn installPublicationFault(
        h: *ReceiptLookupHarness,
        stage: LookupPublicationStage,
        fault: LookupPublicationFault,
    ) !void {
        const seal_failure = fault == .seal;
        if (seal_failure) {
            try h.temporary.dir.createDir(h.io, "lookup/seal.next", .default_dir);
        } else if (fault == .commit) {
            // A deferred foreign-key violation permits every statement
            // and fails the actual COMMIT. The temporary trigger affects
            // only this connection; its insert rolls back with the operation.
            // Use a declared deferred constraint: read-snapshot rollback
            // during admission resets PRAGMA defer_foreign_keys.
            try h.namespace.store.database.exec(
                \\CREATE TEMP TABLE recovery_parent(id INTEGER PRIMARY KEY);
                \\CREATE TEMP TABLE recovery_child(parent INTEGER REFERENCES recovery_parent(id) DEFERRABLE INITIALLY DEFERRED);
            );
            if (stage == .admission) {
                try h.namespace.store.database.exec(
                    \\CREATE TEMP TRIGGER recovery_commit_failure AFTER INSERT ON operations BEGIN
                    \\INSERT INTO recovery_child VALUES(1);
                    \\END;
                );
            } else try h.namespace.store.database.exec(
                \\CREATE TEMP TRIGGER recovery_commit_failure AFTER UPDATE OF body ON records WHEN NEW.kind='reconciliation' BEGIN
                \\INSERT INTO recovery_child VALUES(1);
                \\END;
            );
        } else try h.namespace.store.database.exec("PRAGMA query_only=ON;");
    }

    fn assertPublicationFailure(
        h: *ReceiptLookupHarness,
        stage: LookupPublicationStage,
        fault: LookupPublicationFault,
        subject: native.tasks.Work,
        revision: u64,
        operation_id: []const u8,
        work: LookupFaultWork,
    ) !void {
        const expected_error = switch (fault) {
            .write => error.StorageUnavailable,
            .commit => error.Constraint,
            .seal => error.UnsafeStatePath,
        };
        switch (stage) {
            .admission => try std.testing.expectError(
                expected_error,
                h.service.reconcile(
                    h.frame,
                    operation_id,
                    subject.task,
                    revision,
                    subject.occurrence,
                    subject.attempt,
                    .lookup,
                ),
            ),
            .capture => try std.testing.expectError(
                expected_error,
                h.service.acquire(h.frame, work.selected.?, work.acquired.?),
            ),
            .settlement => try std.testing.expectError(expected_error, h.service.pump(h.frame)),
        }
        try std.testing.expect(h.service.work == null);
    }

    fn publicationHead(
        h: *ReceiptLookupHarness,
        fault: LookupPublicationFault,
        previous_head: anytype,
    ) !void {
        const seal_failure = fault == .seal;
        if (seal_failure) {
            try std.testing.expectEqual(
                previous_head.generation + 1,
                h.namespace.store.head.generation,
            );
            try std.testing.expect(h.namespace.store.fenced);
            try std.testing.expectError(error.StorageUnavailable, h.service.pump(h.frame));
            try h.temporary.dir.deleteTree(h.io, "lookup/seal.next");
        } else {
            try std.testing.expectEqualDeep(previous_head, h.namespace.store.head);
            if (fault == .commit) {
                try std.testing.expect(h.namespace.store.fenced);
                try std.testing.expectError(error.StorageUnavailable, h.service.pump(h.frame));
                try h.namespace.store.database.exec("DROP TRIGGER recovery_commit_failure;");
            } else try h.namespace.store.database.exec("PRAGMA query_only=OFF;");
        }
    }

    fn restoredOccurrence(
        h: *ReceiptLookupHarness,
        subject: native.tasks.Work,
        settled_reply: bool,
        captured_reply: bool,
    ) !void {
        const occurrence_bytes = (try h.namespace.store.recordBytes(
            h.frame,
            "occurrence",
            subject.occurrence,
            subject.task,
        )).?;
        var restored_occurrence = try protean.contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            h.frame,
            occurrence_bytes,
        );
        defer restored_occurrence.deinit();
        if (settled_reply) {
            try std.testing.expect(restored_occurrence.value.state == .settled_reply);
        } else if (captured_reply) {
            try std.testing.expect(restored_occurrence.value.state == .captured);
        } else try std.testing.expect(restored_occurrence.value.state == .unknown);
    }

    fn restoredReconciliation(
        h: *ReceiptLookupHarness,
        stage: LookupPublicationStage,
        fault: LookupPublicationFault,
        subject: native.tasks.Work,
        revision: u64,
        operation_id: []const u8,
        work: LookupFaultWork,
        settled_reply: bool,
        captured_reply: bool,
    ) !void {
        const seal_failure = fault == .seal;
        const replay = try h.service.reconcile(
            h.frame,
            operation_id,
            subject.task,
            revision,
            subject.occurrence,
            subject.attempt,
            .lookup,
        );
        try std.testing.expectEqual(stage != .admission or seal_failure, replay.replayed);
        if (work.recovery_id) |saved_id| try std.testing.expectEqualSlices(
            u8,
            &saved_id,
            &replay.receipt.reconciliation.?,
        );
        var restored_recovery = try h.service.reconciliation(
            h.frame,
            subject.task,
            replay.receipt.reconciliation.?,
        );
        defer restored_recovery.deinit();
        if (settled_reply) {
            try std.testing.expect(restored_recovery.value.outcome == .reply_settled);
        } else if (captured_reply) {
            try std.testing.expect(restored_recovery.value.outcome == .capture_admitted);
        } else if (replay.replayed) {
            try std.testing.expect(
                restored_recovery.value.outcome == .unresolved and
                    restored_recovery.value.outcome.unresolved == .interrupted,
            );
        } else {
            // The failed pre-commit admission left no receipt or work.
            // Its explicit retry is the first admitted lookup.
            try std.testing.expect(restored_recovery.value.outcome == .pending);
            try h.service.notSent(h.frame, (try h.service.pump(h.frame)).work);
        }
    }

    fn restoredPublication(
        h: *ReceiptLookupHarness,
        stage: LookupPublicationStage,
        fault: LookupPublicationFault,
        subject: native.tasks.Work,
        subject_task: anytype,
        operation_id: []const u8,
        work: LookupFaultWork,
    ) !void {
        const seal_failure = fault == .seal;
        try std.testing.expect(try h.service.pump(h.frame) == .idle);
        var restored_task = try h.service.task(h.frame, subject.task);
        defer restored_task.deinit();
        try std.testing.expectEqual(
            subject_task.value.inference_attempts,
            restored_task.value.inference_attempts,
        );
        try std.testing.expectEqual(
            subject_task.value.inference_request_bytes,
            restored_task.value.inference_request_bytes,
        );
        const settled_reply = stage == .settlement and seal_failure;
        const captured_reply = stage == .settlement or (stage == .capture and seal_failure);
        try std.testing.expectEqual(
            @as(u64, if (settled_reply) 7 else 0),
            restored_task.value.inference_output_tokens,
        );
        try h.restoredOccurrence(subject, settled_reply, captured_reply);
        try h.restoredReconciliation(
            stage,
            fault,
            subject,
            subject_task.value.revision,
            operation_id,
            work,
            settled_reply,
            captured_reply,
        );
        _ = try h.namespace.store.auditRetention(h.handlers, h.application.image_identity);
        try std.testing.expectEqual(2, h.fixture.calls.load(.acquire));
    }

    fn publicationFault(
        h: *ReceiptLookupHarness,
        stage: LookupPublicationStage,
        fault: LookupPublicationFault,
    ) !void {
        const label = try std.fmt.allocPrint(h.frame, "{s}-{s}", .{
            @tagName(stage),
            @tagName(fault),
        });
        const subject = try lookupUnknown(&h.service, h.frame, label);
        var subject_task = try h.service.task(h.frame, subject.task);
        defer subject_task.deinit();
        const operation_id = try std.fmt.allocPrint(h.frame, "lookup-{s}", .{label});
        const work = try h.preparePublication(
            stage,
            subject,
            subject_task.value.revision,
            operation_id,
        );
        const previous_head = h.namespace.store.head;
        try h.installPublicationFault(stage, fault);
        try h.assertPublicationFailure(
            stage,
            fault,
            subject,
            subject_task.value.revision,
            operation_id,
            work,
        );
        try h.publicationHead(fault, previous_head);
        try h.closeOwner();
        try h.openNamespace();
        try h.openService();
        try h.restoredPublication(stage, fault, subject, &subject_task, operation_id, work);
    }

    fn publicationFaults(h: *ReceiptLookupHarness) !void {
        for ([_]LookupPublicationStage{ .admission, .capture, .settlement }) |stage| {
            for ([_]LookupPublicationFault{ .write, .commit, .seal }) |fault| {
                try h.publicationFault(stage, fault);
            }
        }
    }
};

test "controller microprogress preserves park import and cancellation without a guest cut" {
    try controllerMicroprogress(false);
}

test "controller outer capsule moves without compatibility acquiring an execution obligation" {
    try controllerMicroprogress(true);
}

fn controllerMicroprogress(comptime moving: bool) !void {
    var fixture: ControllerMicroprogressFixture = .{ .moving = moving };
    defer fixture.deinit();
    try fixture.initImage();
    try fixture.initApplication();
    try fixture.initPaths();
    try fixture.initOwner();
    try fixture.captureProgress();
    try fixture.forgeRootOperation();
    try fixture.configurePlacement();
    try fixture.exportOwner();
    try fixture.importOwner();
    try fixture.admitTransfer();
    try fixture.cancelProgress();
    if (moving) return;
    try fixture.retryPublication();
    try fixture.deferredPublications();
}

const ControllerMicroprogressFixture = struct {
    const p = native.placement;
    moving: bool,
    a: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    arena: std.heap.ArenaAllocator = undefined,
    frame: std.mem.Allocator = undefined,
    image: []u8 = undefined,
    admitted: *horos.data.program_image.Admitted = undefined,
    manifest: []u8 = undefined,
    assets: native.discovery.Assets = undefined,
    application: native.discovery.Application = undefined,
    handlers: native.Registry = undefined,
    profile: native.tasks.Profile = undefined,
    temporary: std.testing.TmpDir = undefined,
    path_buffer: [4096]u8 = undefined,
    length: usize = undefined,
    path: []u8 = undefined,
    copy_path: []u8 = undefined,
    bundle: []u8 = undefined,
    destination_identity: [32]u8 = undefined,
    completed_path: []u8 = undefined,
    completed_destination_identity: [32]u8 = undefined,
    namespace: native.Namespace = undefined,
    namespace_live: bool = false,
    service: native.tasks.Service(FairTypes) = undefined,
    service_live: bool = false,
    submitted: native.tasks.Admission = undefined,
    original: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    partial: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    root_record: protean.contracts.Decoded(native.testing.state.RootOperation) = undefined,
    root_original: native.testing.state.RootOperation = undefined,
    source_key: std.crypto.sign.Ed25519.KeyPair = undefined,
    destination_key: std.crypto.sign.Ed25519.KeyPair = undefined,
    source_site: p.Site = undefined,
    destination_site: p.Site = undefined,
    subject: p.Subject = undefined,
    compatibility: p.Compatibility = undefined,
    resources: [32]u8 = undefined,
    source_peer: p.Peer = undefined,
    destination_peer: p.Peer = undefined,
    source_config: p.Configuration = undefined,
    destination_config: p.Configuration = undefined,
    offer: ?p.Signed(p.Offer) = undefined,
    destination: native.Namespace = undefined,
    failing: std.testing.FailingAllocator = undefined,
    destination_profile: native.tasks.Profile = undefined,
    imported: native.tasks.Service(FairTypes) = undefined,
    restored: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    retry: native.tasks.Admission = undefined,
    retried: protean.contracts.Decoded(native.testing.state.Task) = undefined,
    arena_live: bool = false,
    admitted_live: bool = false,
    application_live: bool = false,
    handlers_live: bool = false,
    temporary_live: bool = false,
    original_live: bool = false,
    partial_live: bool = false,
    root_record_live: bool = false,
    destination_live: bool = false,
    imported_live: bool = false,
    restored_live: bool = false,
    retried_live: bool = false,

    source_peers: [1]p.Peer = undefined,
    destination_peers: [1]p.Peer = undefined,
    completed_peers: [1]p.Peer = undefined,
    completed_source_config: p.Configuration = undefined,

    fn initImage(self: *ControllerMicroprogressFixture) !void {
        self.arena = std.heap.ArenaAllocator.init(self.a);
        self.arena_live = true;
        self.frame = self.arena.allocator();
        const Long = struct {
            pub fn emit(c: protean.Context) !horos.source.Module {
                const b = c.builder;
                const number = try b.scalar(u32);
                const entry = try b.declare(&.{number}, number, &.{}, &.{});
                var result = try b.reference(b.parameter(entry, 0));
                for (0..256) |_| result = try b.primitive(
                    number,
                    .integer_bit_xor,
                    &.{ result, try b.constant(u32, 1) },
                    0,
                );
                try b.define(entry, try b.pure(result));
                return b.module(entry, try b.scalar(void));
            }
        };
        var compiled = try protean.compile(
            self.a,
            protean.system(.{
                .InitialArgs = u32,
                .Result = u32,
                .Failure = void,
                .application = Long,
            }),
        );
        defer compiled.deinit();
        self.image = try self.frame.alloc(
            u8,
            try horos.data.program_image.encodedLength(compiled.program),
        );
        _ = try compiled.encode(self.a, self.image);
        self.admitted = try horos.data.program_image.Admitted.decode(self.a, self.image);
        self.admitted_live = true;
        self.manifest = try ownerManifest(
            self.frame,
            self.image,
            self.admitted.identity(),
            "controller-microprogress",
        );
        self.assets = .{
            .image = self.image,
            .application = "controller-microprogress",
            .manifest = self.manifest,
        };
    }

    fn initApplication(self: *ControllerMicroprogressFixture) !void {
        self.application = .{
            .arena = .init(self.a),
            .metadata = .null,
            .manifest = .null,
            .manifest_id = "unit",
            .image_identity = self.admitted.identity(),
        };
        self.application_live = true;
        self.application.manifest = (try native.json.parse(
            self.application.arena.allocator(),
            self.manifest,
            .{},
        )).value;
        self.handlers = try native.Registry.init(self.a, &.{});
        self.handlers_live = true;
        self.profile = .{ .id = "offline", .runtime_identity = @splat(
            42,
        ), .bytes = "controller-profile", .authority = .{
            .grants = &.{},
            .principal = "test",
            .tenant = "test",
        } };
    }

    fn initPaths(self: *ControllerMicroprogressFixture) !void {
        self.temporary = std.testing.tmpDir(.{});
        self.temporary_live = true;
        self.path_buffer = undefined;
        self.length = try self.temporary.dir.realPath(self.io, &self.path_buffer);
        self.path = try std.fmt.allocPrint(
            self.frame,
            "{s}/source",
            .{self.path_buffer[0..self.length]},
        );
        self.copy_path = try std.fmt.allocPrint(
            self.frame,
            "{s}/copy",
            .{self.path_buffer[0..self.length]},
        );
        self.bundle = try std.fmt.allocPrint(
            self.frame,
            "{s}/outer.bundle",
            .{self.path_buffer[0..self.length]},
        );
        var initial_destination = try native.Namespace.open(self.a, self.io, self.copy_path);
        self.destination_identity = initial_destination.identity;
        try initial_destination.close();
        self.completed_path = try std.fmt.allocPrint(self.frame, "{s}/completed-copy", .{
            self.path_buffer[0..self.length],
        });
        self.completed_destination_identity = if (!self.moving) identity: {
            var completed_destination = try native.Namespace.open(
                self.a,
                self.io,
                self.completed_path,
            );
            const result = completed_destination.identity;
            try completed_destination.close();
            break :identity result;
        } else self.destination_identity;
    }

    fn initOwner(self: *ControllerMicroprogressFixture) !void {
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_live = true;
        self.service = try native.tasks.Service(FairTypes).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_live = true;
    }

    fn captureProgress(self: *ControllerMicroprogressFixture) !void {
        self.submitted = try self.service.submit(self.frame, "long-controller", 10);
        self.original = try self.service.task(self.frame, self.submitted.receipt.task);
        self.original_live = true;
        try std.testing.expectEqual(.progressed, try self.service.pump(self.frame));
        self.partial = try self.service.task(self.frame, self.submitted.receipt.task);
        self.partial_live = true;
        try std.testing.expectEqual(
            self.original.value.execution_revision,
            self.partial.value.execution_revision,
        );
        try std.testing.expectEqualDeep(
            self.original.value.checkpoint,
            self.partial.value.checkpoint,
        );
        try self.service.park(self.frame);
        const root_rows = try self.namespace.store.archiveIndex(
            self.frame,
            self.submitted.receipt.task,
            .{ .digest = @splat(0), .bytes = 0 },
        );
        var outer_ref: ?@TypeOf(self.original.value.checkpoint) = null;
        for (root_rows.records.items) |row| if (row.kind == .root_operation) {
            outer_ref = row.body;
        };
        try std.testing.expect(outer_ref != null);
        const root_bytes = try self.namespace.store.object(self.frame, outer_ref.?, null);
        self.root_record = try protean.contracts.decodeOwned(
            native.testing.state.RootOperation,
            self.frame,
            root_bytes,
        );
        self.root_record_live = true;
        self.root_original = self.root_record.value;
        try std.testing.expect(self.root_original.pending != null);
    }

    fn forgeRootOperation(self: *ControllerMicroprogressFixture) !void {
        for (0..3) |mutation| {
            var forged = self.root_original;
            try self.namespace.store.begin();
            if (mutation == 0) {
                forged.pending.?.control = try self.namespace.store.putObject(
                    try protean.contracts.encodeOwned(protocol.Control, self.frame, .resume_yield),
                );
            } else if (mutation == 1) {
                forged.pending.?.guest_quantum += 1;
            } else {
                forged.pending.?.dependencies.items = &.{};
            }
            try self.namespace.store.putRecord(
                native.testing.state.RootOperation,
                "root_operation",
                forged.id,
                forged.task,
                forged,
            );
            try self.namespace.commit("test.forge-controller-operation");
            try std.testing.expectError(
                error.InvalidArchive,
                self.service.exportCheckpoint(self.frame, self.submitted.receipt.task, self.bundle),
            );
            try self.namespace.store.begin();
            try self.namespace.store.putRecord(
                native.testing.state.RootOperation,
                "root_operation",
                self.root_original.id,
                self.root_original.task,
                self.root_original,
            );
            try self.namespace.commit("test.restore-controller-operation");
        }
    }

    fn configurePlacement(self: *ControllerMicroprogressFixture) !void {
        self.source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(31));
        self.destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(
            @splat(32),
        );
        self.source_site = .{
            .key = self.source_key.public_key.bytes,
            .namespace = self.namespace.identity,
        };
        self.destination_site = .{
            .key = self.destination_key.public_key.bytes,
            .namespace = self.destination_identity,
        };
        self.subject = .{ .task = self.submitted.receipt.task };
        try std.testing.expect(self.service.active == null);
        self.compatibility = try self.service.placementCompatibility(self.frame, self.subject);
        try std.testing.expect(self.service.active == null);
        self.resources = try self.profile.resourceIdentity(
            self.frame,
            self.application.image_identity,
        );
        const Allow = struct {
            fn disclose(
                _: *anyopaque,
                _: p.Subject,
                _: []const native.testing.state.Reference,
            ) !void {}
        };
        self.source_peer = .{
            .name = "source",
            .site = self.source_site,
            .native_build = self.profile.runtime_identity,
            .compatibility = self.compatibility,
            .resource_binding = self.resources,
            .disclosure_policy = @splat(33),
            .context = undefined,
            .disclose = Allow.disclose,
        };
        self.destination_peer = .{
            .name = "destination",
            .site = self.destination_site,
            .native_build = self.profile.runtime_identity,
            .compatibility = self.compatibility,
            .resource_binding = self.resources,
            .disclosure_policy = @splat(33),
            .context = undefined,
            .disclose = Allow.disclose,
        };
        self.source_peers = .{self.source_peer};
        self.destination_peers = .{self.destination_peer};
        self.source_config = .{
            .signing_key = self.source_key,
            .peers = &self.destination_peers,
        };
        self.destination_config = .{
            .signing_key = self.destination_key,
            .peers = &self.source_peers,
        };
    }

    fn exportOwner(self: *ControllerMicroprogressFixture) !void {
        self.offer = null;
        if (self.moving) {
            self.service.profile.placement = &self.source_config;
            _ = try self.service.requestCancel(
                self.frame,
                "cancel-before-controller-transfer",
                self.submitted.receipt.task,
                "interrupted",
            );
            const cut = try self.service.placementCut(self.frame, self.subject);
            try std.testing.expect(cut.outer != null);
            _ = try self.service.placementFreeze(
                self.frame,
                self.subject,
                "destination",
                cut,
                @splat(34),
            );
            try std.testing.expect(try self.service.shutdownIncomplete(self.frame));
            self.offer = try self.service.placementOffer(
                self.frame,
                self.subject,
                "destination",
                self.bundle,
            );
        } else _ = try self.service.exportCheckpoint(
            self.frame,
            self.submitted.receipt.task,
            self.bundle,
        );
        try self.service.close(self.frame);
        self.service_live = false;
        try self.namespace.close();
        self.namespace_live = false;
    }

    fn importOwner(self: *ControllerMicroprogressFixture) !void {
        self.destination = try native.Namespace.open(self.a, self.io, self.copy_path);
        self.destination_live = true;
        self.failing = std.testing.FailingAllocator.init(self.a, .{});
        self.destination_profile = self.profile;
        if (self.moving) self.destination_profile.placement = &self.destination_config;
        self.imported = try native.tasks.Service(FairTypes).init(
            self.failing.allocator(),
            self.io,
            &self.destination,
            self.assets,
            &self.application,
            self.handlers,
            self.destination_profile,
        );
        self.imported_live = true;
    }

    fn admitTransfer(self: *ControllerMicroprogressFixture) !void {
        if (self.moving) {
            const decision = try self.imported.placementAccept(
                self.frame,
                "outer-accept",
                "source",
                self.offer.?,
                self.bundle,
            );
            try std.testing.expect(decision.value.verdict == .accepted);
            var accepted_cut = self.offer.?.value.intent.cut;
            // Admission records its native receipt without advancing the guest.
            accepted_cut.control += 1;
            try std.testing.expectEqualDeep(
                accepted_cut,
                try self.imported.placementCut(self.frame, self.subject),
            );
        } else {
            _ = try self.imported.importCheckpoint(self.frame, "outer-import", self.bundle);
            try std.testing.expectError(
                error.CustodyNotLocal,
                self.imported.requestCancel(
                    self.frame,
                    "copy-cannot-cancel",
                    self.submitted.receipt.task,
                    "interrupted",
                ),
            );
            try self.closeDestination();
            try self.openDestination(self.path, self.destination_profile);
        }
    }

    fn cancelProgress(self: *ControllerMicroprogressFixture) !void {
        self.restored = try self.imported.task(self.frame, self.submitted.receipt.task);
        self.restored_live = true;
        try std.testing.expectEqualDeep(
            self.original.value.checkpoint,
            self.restored.value.checkpoint,
        );
        _ = try self.imported.requestCancel(
            self.frame,
            "cancel-during-physical-progress",
            self.submitted.receipt.task,
            "interrupted",
        );
        // Cancellation waits for the already accepted advance, then applies once.
        // The budget bounds this witness, not the lifetime of an admitted task.
        var completed = false;
        for (0..2048) |_| {
            try std.testing.expect(try self.imported.pump(self.frame) != .work);
            var current = try self.imported.task(self.frame, self.submitted.receipt.task);
            defer current.deinit();
            if (current.value.terminal()) {
                try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                try std.testing.expect(current.value.cancellation_applied);
                completed = true;
                break;
            }
        }
        try std.testing.expect(completed);
        _ = try self.imported.exportCheckpoint(
            self.frame,
            self.submitted.receipt.task,
            try std.fmt.allocPrint(
                self.frame,
                "{s}/cancelled.bundle",
                .{self.path_buffer[0..self.length]},
            ),
        );
    }

    fn retryPublication(self: *ControllerMicroprogressFixture) !void {
        self.retry = try self.imported.submit(self.frame, "retry-cut-publication", 12);
        try std.testing.expectEqual(.progressed, try self.imported.pump(self.frame));
        try std.testing.expect(self.imported.active.?.root_control != null);
        // Stop at the owner boundary immediately after physical completion. The
        // next service turn must publish this cut without pumping the command again.
        try self.finishPhysicalCut();
        self.failing.fail_index = self.failing.alloc_index;
        self.failing.resize_fail_index = self.failing.resize_index;
        try std.testing.expectError(error.OutOfMemory, self.imported.pump(self.frame));
        try std.testing.expect(!self.destination.store.fenced);
        try std.testing.expect(self.imported.active.?.root_cut_ready);
        try std.testing.expect(self.imported.active.?.root_control != null);
        self.failing.fail_index = std.math.maxInt(usize);
        self.failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(.progressed, try self.imported.pump(self.frame));
        self.retried = try self.imported.task(self.frame, self.retry.receipt.task);
        self.retried_live = true;
        try std.testing.expectEqual(1, self.retried.value.execution_revision);
        if (self.imported.active) |active| {
            try std.testing.expect(active.root_control == null);
            try std.testing.expect(!active.root_cut_ready);
        }
    }

    fn deferredPublications(self: *ControllerMicroprogressFixture) !void {
        for (0..3) |scenario| try self.deferredPublication(scenario);
    }

    fn deferredPublication(self: *ControllerMicroprogressFixture, scenario: usize) !void {
        try self.imported.park(self.frame);
        const operation_id = try std.fmt.allocPrint(
            self.frame,
            "deferred-root-{d}",
            .{scenario},
        );
        const deferred = try self.imported.submit(self.frame, operation_id, 14);
        const program = try self.buildDeferredProgram(scenario, deferred.receipt.task);
        try self.deferPhysicalPublication(deferred.receipt.task);
        var before = try self.imported.task(self.frame, deferred.receipt.task);
        defer before.deinit();
        if (scenario == 2) {
            try self.transferDeferred(deferred.receipt.task, before.value);
            return;
        }
        if (scenario == 0) try self.runDeferredChild(
            deferred.receipt.task,
            program.receipt.workspace.?,
        );
        try self.parkDeferred(scenario, deferred.receipt.task, before.value);
        try self.closeDestination();
        try self.openDestination(self.path, self.destination_profile);
        var reopened = try self.imported.task(self.frame, deferred.receipt.task);
        defer reopened.deinit();
        _ = try self.imported.resumeTask(
            self.frame,
            try std.fmt.allocPrint(self.frame, "deferred-resume-{d}", .{scenario}),
            deferred.receipt.task,
            reopened.value.revision,
        );
        try std.testing.expectEqual(.progressed, try self.imported.pump(self.frame));
        var published = try self.imported.task(self.frame, deferred.receipt.task);
        defer published.deinit();
        try std.testing.expectEqual(
            before.value.execution_revision + 1,
            published.value.execution_revision,
        );
        try std.testing.expect(!self.destination.store.fenced);
    }

    fn finishPhysicalCut(self: *ControllerMicroprogressFixture) !void {
        try std.testing.expect(!self.imported.active.?.root_cut_ready);
        while (!self.imported.active.?.root_cut_ready) {
            var progress = try self.imported.active.?.driver.pump(65536);
            defer progress.deinit();
            if (progress == .suspended) continue;
            try std.testing.expect(progress == .event and progress.event.value == .cut);
            self.imported.active.?.root_cut_ready = true;
        }
    }

    fn closeDestination(self: *ControllerMicroprogressFixture) !void {
        try self.imported.close(self.frame);
        self.imported_live = false;
        try self.destination.close();
        self.destination_live = false;
    }

    fn openDestination(
        self: *ControllerMicroprogressFixture,
        path: []const u8,
        profile: native.tasks.Profile,
    ) !void {
        self.destination = try native.Namespace.open(self.a, self.io, path);
        self.destination_live = true;
        self.imported = try native.tasks.Service(FairTypes).init(
            self.failing.allocator(),
            self.io,
            &self.destination,
            self.assets,
            &self.application,
            self.handlers,
            profile,
        );
        self.imported_live = true;
    }

    fn buildDeferredProgram(
        self: *ControllerMicroprogressFixture,
        scenario: usize,
        task: [16]u8,
    ) !native.tasks.Admission {
        var builder = horos.source.Builder.init(self.a);
        defer builder.deinit();
        const number = try builder.scalar(u32);
        const entry = try builder.declare(&.{number}, number, &.{}, &.{});
        try builder.define(
            entry,
            try builder.pure(try builder.reference(builder.parameter(entry, 0))),
        );
        const document = try native.source_records.encode(
            self.frame,
            builder.module(entry, try builder.scalar(void)),
        );
        var diagnostic: native.program_construction.Diagnostic = .{};
        return self.imported.workspaceBuild(
            self.frame,
            try std.fmt.allocPrint(self.frame, "deferred-build-{d}", .{scenario}),
            task,
            document,
            &diagnostic,
        );
    }

    fn deferPhysicalPublication(self: *ControllerMicroprogressFixture, task: [16]u8) !void {
        while (self.imported.active == null or !std.meta.eql(
            self.imported.active.?.task,
            task,
        ) or self.imported.active.?.root_control == null) {
            try std.testing.expectEqual(.progressed, try self.imported.pump(self.frame));
        }
        try self.finishPhysicalCut();
        self.failing.fail_index = self.failing.alloc_index;
        self.failing.resize_fail_index = self.failing.resize_index;
        try std.testing.expectError(error.OutOfMemory, self.imported.pump(self.frame));
        try std.testing.expect(!self.destination.store.fenced);
        self.failing.fail_index = std.math.maxInt(usize);
        self.failing.resize_fail_index = std.math.maxInt(usize);
    }

    fn transferDeferred(
        self: *ControllerMicroprogressFixture,
        task: [16]u8,
        before: native.testing.state.Task,
    ) !void {
        self.completed_peers = .{self.destination_peer};
        self.completed_peers[0].site.namespace = self.completed_destination_identity;
        self.completed_source_config = .{
            .signing_key = self.source_key,
            .peers = &self.completed_peers,
        };
        self.imported.profile.placement = &self.completed_source_config;
        const moving_subject: p.Subject = .{ .task = task };
        const cut = try self.imported.placementCut(self.frame, moving_subject);
        try std.testing.expectEqual(before.execution_revision, cut.execution);
        try std.testing.expect(cut.outer != null);
        _ = try self.imported.placementFreeze(
            self.frame,
            moving_subject,
            "destination",
            cut,
            @splat(91),
        );
        const moved_path = try std.fmt.allocPrint(
            self.frame,
            "{s}/completed-outer.bundle",
            .{self.path_buffer[0..self.length]},
        );
        const moved_offer = try self.imported.placementOffer(
            self.frame,
            moving_subject,
            "destination",
            moved_path,
        );
        try std.testing.expectEqual(.idle, try self.imported.pump(self.frame));
        try self.closeDestination();
        try self.acceptDeferredTransfer(moving_subject, moved_offer, moved_path, before);
    }

    fn acceptDeferredTransfer(
        self: *ControllerMicroprogressFixture,
        moving_subject: p.Subject,
        moved_offer: p.Signed(p.Offer),
        moved_path: []const u8,
        before: native.testing.state.Task,
    ) !void {
        var receiver_profile = self.profile;
        receiver_profile.placement = &self.destination_config;
        try self.openDestination(self.completed_path, receiver_profile);
        const decision = try self.imported.placementAccept(
            self.frame,
            "completed-outer-accept",
            "source",
            moved_offer,
            moved_path,
        );
        try std.testing.expect(decision.value.verdict == .accepted);
        try std.testing.expectEqual(.idle, try self.imported.pump(self.frame));
        var admitted_task = try self.imported.task(self.frame, moving_subject.task);
        defer admitted_task.deinit();
        try std.testing.expectEqual(
            before.execution_revision,
            admitted_task.value.execution_revision,
        );
        _ = try self.imported.resumeTask(
            self.frame,
            "completed-outer-resume",
            moving_subject.task,
            admitted_task.value.revision,
        );
        try std.testing.expectEqual(.progressed, try self.imported.pump(self.frame));
        var received = try self.imported.task(self.frame, moving_subject.task);
        defer received.deinit();
        try std.testing.expectEqual(
            before.execution_revision + 1,
            received.value.execution_revision,
        );
        try std.testing.expect(!self.destination.store.fenced);
    }

    fn runDeferredChild(
        self: *ControllerMicroprogressFixture,
        task: [16]u8,
        program: [32]u8,
    ) !void {
        const child = try self.imported.workspaceStart(
            self.frame,
            "child-after-deferred-root",
            task,
            program,
            try protean.contracts.encodeOwned(u32, self.frame, 19),
            .{ .stop = .terminal, .continuation = .owner_scheduled },
        );
        var child_value = try self.imported.workspaceWork(
            self.frame,
            task,
            child.receipt.workspace.?,
        );
        defer child_value.deinit();
        try std.testing.expect(child_value.value.terminal());
    }

    fn parkDeferred(
        self: *ControllerMicroprogressFixture,
        scenario: usize,
        task: [16]u8,
        before: native.testing.state.Task,
    ) !void {
        try self.imported.park(self.frame);
        var parked = try self.imported.task(self.frame, task);
        defer parked.deinit();
        try std.testing.expectEqual(
            before.execution_revision,
            parked.value.execution_revision,
        );
        try std.testing.expectEqualDeep(before.checkpoint, parked.value.checkpoint);
        try std.testing.expectEqual(.parked, parked.value.schedule);
        try std.testing.expectEqual(.idle, try self.imported.pump(self.frame));
        _ = try self.imported.exportCheckpoint(
            self.frame,
            task,
            try std.fmt.allocPrint(self.frame, "{s}/deferred-{d}.bundle", .{
                self.path_buffer[0..self.length],
                scenario,
            }),
        );
    }

    fn deinit(self: *ControllerMicroprogressFixture) void {
        if (self.retried_live) self.retried.deinit();
        if (self.restored_live) self.restored.deinit();
        if (self.imported_live) expectCleanup(self.imported.close(self.frame));
        if (self.destination_live) expectCleanup(self.destination.close());
        if (self.root_record_live) self.root_record.deinit();
        if (self.partial_live) self.partial.deinit();
        if (self.original_live) self.original.deinit();
        if (self.service_live) expectCleanup(self.service.close(self.frame));
        if (self.namespace_live) expectCleanup(self.namespace.close());
        if (self.temporary_live) self.temporary.cleanup();
        if (self.handlers_live) self.handlers.deinit();
        if (self.application_live) self.application.deinit();
        if (self.admitted_live) self.admitted.deinit();
        if (self.arena_live) self.arena.deinit();
    }
};
