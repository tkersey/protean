const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const native = @import("protean_native");
const kronos = @import("kronos");
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
        const number = try c.schema(u32);
        const output = try c.schema(T.Output);
        const leaf = try c.external("task-owner.increment.v1", number, number, .read);
        const question = try c.external("task-owner.question.v1", number, number, .read);
        const inbox = try Inbox.declare(c);
        const entry = try b.declare(&.{number}, output, &.{ leaf, question, inbox }, &.{});
        const incremented = try b.variable(number);
        const answer = try b.variable(number);
        const message = try b.variable(try c.schema(Inbox.Reply));
        const padding = try c.literal(T.Padding, .{ .bytes = &@as([64 * 1024]u8, @splat('x')) });
        const result = try b.primitive(output, .product, &.{ try b.reference(answer), try b.reference(message), padding }, 0);
        try b.define(entry, try b.bind(incremented, try b.term(.{ .perform = .{ .effect = leaf, .payload = try b.reference(b.parameter(entry, 0)) } }), try b.bind(answer, try b.term(.{ .perform = .{ .effect = question, .payload = try b.reference(incremented) } }), try b.bind(message, try Inbox.poll(c), try b.term(.{ .yield_then = try b.pure(result) })))));
        return b.module(entry, try c.schema(void));
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
    return native.json.number(ctx.allocator, input);
}
const CapturingIncrement = struct {
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

pub fn ownerManifest(a: std.mem.Allocator, image: []const u8, identity: [32]u8, application: []const u8) ![]u8 {
    var image_digest: [32]u8 = undefined;
    var assets_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &image_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(application, &assets_digest, .{});
    const image_hex = std.fmt.bytesToHex(image_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity, .lower);
    const assets_hex = std.fmt.bytesToHex(assets_digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{
        .native_host_contract = "unit-native-contract",
        .protocol = "agent-host/1.0",
        .client_mapping = "agent-client-values/1.0",
        .state_format = "agent-native-state/10",
        .optimize = "safe",
        .program_sha256 = @as([]const u8, &image_hex),
        .program_identity = @as([]const u8, &identity_hex),
        .application_assets_sha256 = @as([]const u8, &assets_hex),
        .dependencies = .{ .world = "unit-kronos", .boundary = "unit-horos" },
        .compiler = .{ .version = "0.17.0" },
    }, .{});
}

// Rehash a well-formed archive while removing one semantic fact. Keep every
// other object, sequence, revision and operation receipt unchanged.
const ArchiveFactChange = enum { cancellation_omitted, cancellation_reason, terminal_cancellation_omitted, terminal_cancellation_reason, terminal_omitted, message_not_consumed };
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
    if (change == .cancellation_omitted or change == .cancellation_reason or change == .terminal_cancellation_omitted or change == .terminal_cancellation_reason) {
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
            kind: enum { accepted, input_required, input_accepted, message_queued, message_consumed, message_not_consumed, cancellation_requested, parked, resumed, blocked, delivery_unknown, completed, failed, cancelled, imported },
            data: protean.contracts.Bytes(48 * 1024),
        };
        var found = false;
        const events = try a.dupe(@TypeOf(archive.events.items[0]), archive.events.items);
        archive.events.items = events;
        for (events) |*row| {
            for (blobs.items) |blob| {
                if (!std.mem.eql(u8, &blob.reference.digest, &row.body.digest)) continue;
                var event = (try protean.contracts.decodeOwned(Event, a, blob.bytes)).value;
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
    archive.reservations.items = &.{};
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
        _ = try imported.resumeTask(frame, "resume-copied-capture", task.value.id, task.value.revision);
        for (0..32) |_| {
            const step = try imported.pump(frame);
            try std.testing.expect(step != .work);
            if (step == .waiting or step == .idle) break;
        }
        var question = (try imported.pendingQuestion(frame, task_id)) orelse return error.ExpectedQuestion;
        defer question.deinit();
    }
    namespace.* = try native.Namespace.open(a, io, source_path);
    namespace_live.* = true;
    service.* = try native.tasks.Service(T).init(a, io, namespace, assets, application, handlers, profile);
    service_live.* = true;
    var task = try service.task(frame, task_id);
    defer task.deinit();
    _ = try service.resumeTask(frame, label, task_id, task.value.revision);
}

// Other admitted operations may consume all unreserved space while this
// capture waits. Use reservations as pressure rather than allocating a 256-MiB
// fixture. The pressure survives the real close/reopen below.
fn reserveRemainingCapacity(namespace: *native.Namespace) !void {
    const db = namespace.store.database;
    var query = try db.prepare("SELECT (SELECT page_count FROM pragma_page_count)*4096-(SELECT freelist_count FROM pragma_freelist_count)*4096+coalesce(sum(bytes),0) FROM reservations", &.{});
    const used: u64 = blk: {
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        break :blk @intCast(try query.integer(0));
    };
    var remaining = 256 * 1024 * 1024 - 1024 * 1024 - used - 512 * 1024;
    try namespace.store.begin();
    defer namespace.store.rollback();
    var index: u8 = 0;
    while (remaining != 0) : (index += 1) {
        var id: [32]u8 = @splat(250);
        id[0] = index;
        const bytes = @min(remaining, 16 * 1024 * 1024);
        try db.run("INSERT INTO reservations VALUES(?,?)", &.{ .{ .blob = &id }, .{ .integer = @intCast(bytes) } });
        remaining -= bytes;
    }
    try namespace.commit("test.intervening-capacity-pressure");
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
    try namespace.store.database.run("UPDATE records SET body=? WHERE kind='message' AND id=?", &.{ .{ .blob = &message.digest }, .{ .blob = &message_id } });
    try namespace.store.database.run("UPDATE tasks SET body=? WHERE id=?", &.{ .{ .blob = &task.digest }, .{ .blob = &value.id } });
    // Export intentionally requires a settled transaction. Commit the synthetic
    // corruption, then restore the exact original references after the check.
    try namespace.commit("test.requeued-history");
    defer {
        namespace.store.begin() catch unreachable;
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
    increment_declaration.attempt_limit = if (captured) 2 else 1;
    if (captured) {
        increment_declaration.background = true;
        increment_declaration.capture = .{ .prepare = CapturingIncrement.prepare, .acquire = CapturingIncrement.invoke, .interpret = CapturingIncrement.interpret };
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
    const resource_set: [native.tasks.maximum_resources][]const u8 = @splat("immutable snapshot bytes");
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "fixed-profile", .environment = &configured, .resources = &resource_set, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    const oversized_resources: [native.tasks.maximum_resources + 1][]const u8 = @splat("immutable snapshot bytes");
    var oversized_profile = profile;
    oversized_profile.resources = &oversized_resources;
    try std.testing.expectError(error.Capacity, oversized_profile.resourceIdentity(application.image_identity));
    for (&grants) |*grant| grant.resource_identity = try profile.resourceIdentity(application.image_identity);
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
            const ctx: native.Context = .{ .allocator = frame, .io = io, .authority = &profile.authority, .task_id = "test", .profile = profile.bytes, .environment = profile.environment, .exhausted_capabilities = step.work.exhausted_capabilities };
            try std.testing.expectEqual(!captured or retried, ctx.nextAttemptLimitExhausted("task-owner.increment.v1"));
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
                try reserveRemainingCapacity(&namespace);
            }
            break;
        }
    }
    try std.testing.expectEqual(1, calls);
    try std.testing.expectEqual(@as(u32, if (captured) 2 else 1), try namespace.store.capabilityAttempts(accepted.receipt.task, "task-owner.increment.v1"));
    try std.testing.expectEqual(@as(u32, 0), try namespace.store.capabilityAttempts(accepted.receipt.task, "another-capability"));
    // Restart at durable acquisition, before Kronos consumes the reply.
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
    try std.testing.expectEqual(native.tasks.maximum_resources, frozen.resources.len);
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
        // before Kronos consumes it, using the non-inference adapter fixture.
        try std.testing.expect(try service.pump(frame) == .progressed);
        try checkCaptureImport(a, frame, io, &service, &namespace, &service_live, &namespace_live, path, path_buffer[0..length], accepted.receipt.task, "settled-capture");
    }
    for (0..32) |_| {
        const step = try service.pump(frame);
        try std.testing.expect(step != .work);
        if (step == .waiting) break;
    }
    if (captured) {
        // Projection and its Kronos successor succeeded while pressure remained.
        // Release only this fixture's unrelated reservations for later cases.
        try namespace.store.begin();
        try namespace.store.database.run("DELETE FROM reservations WHERE substr(attempt,2)=?", &.{.{ .blob = &@as([31]u8, @splat(250)) }});
        try namespace.commit("test.release-capacity-pressure");
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
                    _ = try imported_service.resumeTask(frame, "resume-imported", imported.receipt.task, saved.value.revision);
                    for (0..32) |_| {
                        const imported_step = try imported_service.pump(frame);
                        try std.testing.expect(imported_step != .work);
                        if (imported_step == .idle) break;
                    }
                    var finished = try imported_service.task(frame, imported.receipt.task);
                    defer finished.deinit();
                    try std.testing.expect(finished.value.terminal());
                    const imported_bytes = try imported_namespace.store.object(frame, finished.value.result.?, 128 * 1024);
                    var imported_output = try protean.contracts.decodeOwned(T.Output, frame, imported_bytes);
                    defer imported_output.deinit();
                    phase = "check imported inbox result";
                    try std.testing.expectEqual(7, imported_output.value.answer);
                    try std.testing.expect(imported_output.value.inbox == .message);
                    try std.testing.expectEqual(9, imported_output.value.inbox.message.value);
                    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(queued_message.receipt.message.?, .lower), imported_output.value.inbox.message.id.bytes);
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
    for ([_]u32{ 41, 42 }) |input| {
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
        const chunk = try client.call(a, .@"artifact.read", params);
        const text = chunk.object.get("data").?.string;
        const decoded = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text));
        try std.base64.url_safe_no_pad.Decoder.decode(decoded, text);
        // Build expected bytes independently of the JSON encoder/projection.
        const expected = try a.alloc(u8, if (input == 41) 20_001 else 68);
        if (input == 41) {
            expected[0] = '[';
            for (0..10_000) |i| {
                expected[1 + i * 2] = '0';
                expected[2 + i * 2] = if (i == 9999) ']' else ',';
            }
        } else {
            @memset(expected[0..32], '[');
            @memcpy(expected[32..36], "null");
            @memset(expected[36..], ']');
        }
        try std.testing.expectEqualSlices(u8, expected, decoded);
        try std.testing.expect(chunk.object.get("eof").?.bool);
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
    try store.database.run("INSERT INTO records VALUES('artifact',?,?,?)", &.{ .{ .blob = &id }, .{ .blob = &task_id }, .{ .blob = &record.digest } });
    try service.namespace.commit("test.large-artifact");
    defer {
        store.begin() catch unreachable;
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

    // The fixture's existing SQLite is outside this allocator. Reserve its
    // 16MiB plus the production worker's 16MiB inside the same host-sized budget.
    var budget: kronos.AllocationBudget = .{ .parent = a, .limit = 64 * 1024 * 1024 };
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
    const ctx = protean.Context{ .builder = &b, .registry = &registry };
    try std.testing.expectEqual(try Inbox.declare(ctx), try Inbox.declare(ctx));
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
            const bytes = try c.schema(Types.Output);
            const entry = try b.declare(&.{try c.schema(bool)}, bytes, &.{}, &.{});
            const payload = try c.literal(Types.Output, if (@hasDecl(Types, "dense")) .{ .items = &Types.payload } else .{ .bytes = &Types.payload });
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
    var budget: kronos.AllocationBudget = .{ .parent = harness, .limit = 64 * 1024 * 1024 };
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
    // Completed-only, failed-only and mixed batches all use the real authored
    // outcomes. The mixed batch also exposes aliases to recycled call storage.
    for (0..3) |batch| {
        var responses_arena = std.heap.ArenaAllocator.init(a);
        defer responses_arena.deinit();
        const frame = responses_arena.allocator();
        const baseline = budget.live;
        var responses: std.array_list.Managed(native.json.Value) = .init(frame);
        for (0..16) |i| {
            const index = if (batch == 2) i % 2 else batch;
            var params = native.json.object();
            try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(ids[index], .lower))));
            const result = try client.call(frame, .@"task.result", params);
            try responses.append(try native.protocol.response(frame, try native.json.number(frame, i), result));
            try std.testing.expect(budget.live - baseline < 512 * 1024);
        }
        // Check every retained response after subsequent calls have reclaimed
        // and reused temporary storage, including both failure and success.
        for (responses.items, 0..) |response, i| {
            const index = if (batch == 2) i % 2 else batch;
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
        const unit = try c.schema(void);
        const boolean = try c.schema(bool);
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
            const replay = try imported.requestCancel(frame, "cancel-0", id, "test cancellation");
            try std.testing.expect(replay.replayed);
            const later = try imported.requestCancel(frame, "later-cancel", id, "different later reason");
            try std.testing.expect(later.replayed);
            _ = try imported.resumeTask(frame, "resume-control", id, restored.value.revision);
            for (0..8) |_| {
                const step = try imported.pump(frame);
                try std.testing.expect(step != .work);
                if (step == .idle) break;
            }
            var terminal = try imported.task(frame, id);
            defer terminal.deinit();
            try std.testing.expectEqual(.cancelled, terminal.value.outcome_kind);
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
        var current = try service.task(frame, id);
        defer current.deinit();
        _ = try service.resumeTask(frame, "resume-pending-original", id, current.value.revision);
    }
}

test "terminal cleanup failures retain bounded shutdown ownership without runnable work" {
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
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(CleanupTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    var client: native.client.Client(CleanupTypes) = .{ .service = &service };
    // Successful cleanup releases slots. Both terminal outcomes with failed
    // cleanup remain owned. Then fill every slot to test admission-before-ack.
    for (0..18) |index| {
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
                const admitted = try imported_service.importCheckpoint(frame, "import-cleanup", archive_path);
                try std.testing.expectEqualSlices(u8, &submitted.receipt.task, &admitted.receipt.task);
                var imported_task = try imported_service.task(frame, admitted.receipt.task);
                defer imported_task.deinit();
                try std.testing.expect(imported_task.value.cancellation_applied);
                _ = try imported_service.resumeTask(frame, "resume-cleanup", admitted.receipt.task, imported_task.value.revision);
                try std.testing.expect(try imported_service.pump(frame) == .progressed);
                var finished = try imported_service.task(frame, admitted.receipt.task);
                defer finished.deinit();
                try std.testing.expectEqual(.cancelled, finished.value.outcome_kind);
                try std.testing.expect(try imported_service.taskCleanupComplete(frame, finished.value));
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
        var count: usize = 0;
        for (service.owned) |id| if (id != null) {
            count += 1;
        };
        try std.testing.expectEqual(if (cleanup_fails) index - 1 else 0, count);
        var params = native.json.object();
        try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(submitted.receipt.task, .lower))));
        const result = try client.call(frame, .@"task.result", params);
        try std.testing.expect(result.object.get("ready").?.bool);
        try std.testing.expectEqual(!cleanup_fails, result.object.get("outcome").?.object.get("cleanup_complete").?.bool);
        try std.testing.expect((try service.submit(frame, operation, cleanup_fails)).replayed);
    }
    const generation = namespace.store.head.generation;
    try std.testing.expectError(error.Capacity, service.submit(frame, "overflow-owned", false));
    try std.testing.expectEqual(generation, namespace.store.head.generation);
    try service.park(frame);
    try std.testing.expect(try service.shutdownIncomplete(frame));
    // Reopening does not reacquire old work; its durable result stays honest.
    const retained_id = service.owned[0].?;
    try service.close(frame);
    service_live = false;
    service = try native.tasks.Service(CleanupTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    service_live = true;
    var retained = try service.task(frame, retained_id);
    defer retained.deinit();
    try std.testing.expect(!try service.taskCleanupComplete(frame, retained.value));
    try std.testing.expect(try service.pump(frame) == .idle);
}
