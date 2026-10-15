//! Independent execution witnesses for the source-record transport. Algorithms
//! are authored records; no build-time result or native callback is supplied.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;

fn workspaceRef(a: std.mem.Allocator, kind: @FieldType(contracts.workspace.Ref, "kind"), id: [32]u8) !contracts.workspace.Ref {
    return .{ .kind = kind, .id = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)) } };
}

const gcd = @import("workspace_sources.zig").gcd;
const listLength = @import("workspace_sources.zig").listLength;
const alternatives = @import("workspace_sources.zig").alternatives;

/// Reject allocation after an actual store commit, without depending on an
/// allocation ordinal or adding a fault hook to the production owner.
const AfterCommitAllocator = struct {
    backing: std.mem.Allocator,
    namespace: *native.Namespace,
    generation: u64,
    rejected: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn blocked(self: *@This()) bool {
        if (self.namespace.store.head.generation == self.generation) return false;
        self.rejected += 1;
        return true;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.blocked()) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return false;
        return self.backing.rawResize(bytes, alignment, len, ra);
    }
    fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return null;
        return self.backing.rawRemap(bytes, alignment, len, ra);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

test "BUILD-07 source build allocation fault sweep releases partial owners and cancellation admits nothing" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(a, try gcd(&builder));
    defer a.free(text);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, document: []const u8) !void {
            var diagnostic: native.program_construction.Diagnostic = .{};
            var built = try native.program_construction.build(allocator, document, null, &diagnostic);
            defer built.deinit();
        }
    };
    var baseline = std.testing.FailingAllocator.init(a, .{});
    try Probe.run(baseline.allocator(), text);
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    // Compiler table traversal can vary its allocation count. Sweep the
    // observed allocation positions without asserting deterministic allocation
    // order or rejecting a lawful optional-allocation fallback.
    var induced: usize = 0;
    for (0..baseline.alloc_index) |position| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = position });
        Probe.run(failing.allocator(), text) catch |err| if (err != error.OutOfMemory) return err;
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        induced += @intFromBool(failing.has_induced_failure);
    }
    try std.testing.expect(induced > 1);
    var canceled = std.atomic.Value(bool).init(true);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectError(error.Canceled, native.program_construction.build(a, text, &canceled, &diagnostic));
}

test "WORK-06 WORK-07 generated driver reuses a template with isolated mutable aliases after one prefix" {
    const a = std.testing.allocator;
    for (0..3) |variant| {
        const multi = variant != 0;
        var builder = source.Builder.init(a);
        defer builder.deinit();
        const module = if (variant == 2) try @import("workspace_sources.zig").mutableAlternatives(&builder) else try alternatives(&builder, multi);
        const text = try native.source_records.encode(a, module);
        defer a.free(text);
        var diagnostic: native.program_construction.Diagnostic = .{};
        if (!multi) {
            // An operation declared single-use cannot become multi-shot by
            // requesting an alternative port. Conversion requires a multi
            // operation even when its handler initially owns a linear token.
            try std.testing.expectError(error.InvalidExposure, native.program_construction.buildExposed(a, text, &.{.{ .effect = 1, .class = .alternative }}, null, &diagnostic));
            continue;
        }
        var built = native.program_construction.buildExposed(a, text, &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } }, null, &diagnostic) catch |err| {
            std.debug.print("driver build {s}: phase={s}, function={?d}, term={?d}, value={?d}\n", .{ @errorName(err), @tagName(diagnostic.phase), diagnostic.source.function, diagnostic.source.term, diagnostic.source.value });
            return err;
        };
        defer built.deinit();
        try std.testing.expectEqual(@as(usize, 2), built.ports.len);
        const input = try contracts.encodeOwned(u64, a, 100);
        defer a.free(input);
        var outcome = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .initial_args = input } });
        defer outcome.deinit();
        const Command = union(enum) { instantiate: u64, finish: void };
        for (0..4) |i| {
            try std.testing.expectEqual(.requested, std.meta.activeTag(outcome.record));
            var request = try data.invocation.decode(data.invocation.Request, a, outcome.record.requested.request);
            defer request.deinit();
            if (i == 0) {
                try std.testing.expectEqualStrings("protean.workspace.control/1/0", request.value.binding.semantic_identity);
                var prefix = try contracts.decodeOwned(u64, a, request.value.binding.payload);
                defer prefix.deinit();
                try std.testing.expectEqual(@as(u64, 101), prefix.value);
            } else {
                try std.testing.expectEqualStrings("protean.workspace.control/1/1", request.value.binding.semantic_identity);
                var observed = try contracts.decodeOwned(struct { void, ?u64 }, a, request.value.binding.payload);
                defer observed.deinit();
                try std.testing.expectEqual(@as(?u64, if (i == 1) null else if (i == 2) 111 else 121), observed.value[1]);
            }
            const value = if (i == 0) try contracts.encodeOwned(void, a, {}) else try contracts.encodeOwned(Command, a, if (i == 3) .{ .finish = {} } else .{ .instantiate = if (i == 1) 10 else 20 });
            defer a.free(value);
            const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.value.request_identity, .value = value });
            defer a.free(reply);
            const next = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .state = outcome.record.requested.state.? }, .control = .{ .reply = reply } });
            outcome.deinit();
            outcome = next;
        }
        try std.testing.expectEqual(.completed, std.meta.activeTag(outcome.record));
        var result = try contracts.decodeOwned(u64, a, outcome.record.completed);
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 121), result.value);
    }
}

test "WORK-08 an exclusive resource cannot be captured by a generated alternative port" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(a, try @import("workspace_sources.zig").exclusiveAlternative(&builder));
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectError(error.InvalidOwnership, native.program_construction.buildExposed(a, text, &.{.{ .effect = 0, .class = .alternative }}, null, &diagnostic));
}

fn compile(a: std.mem.Allocator, b: *source.Builder, module: source.Module) !native.program_construction.Built {
    _ = b;
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    return native.program_construction.build(a, text, null, &diagnostic);
}

fn execute(a: std.mem.Allocator, prepared: *kosmos.Prepared, input: []const u8, expected: u64) !u64 {
    var session = try kosmos.Session.start(a, prepared, input);
    defer session.deinit();
    var quanta: u64 = 0;
    while (true) {
        quanta += 1;
        switch (try session.run(8)) {
            .progressed => {},
            .yielded => try session.resumeYield(),
            .completed => |value| {
                var result = try contracts.decodeOwned(u64, a, try session.bytes(&value));
                defer result.deinit();
                try std.testing.expectEqual(expected, result.value);
                return quanta;
            },
            else => return error.UnexpectedOutcome,
        }
    }
}

test "BUILD-01 concrete native execution reuses novel GCD source on independent inputs" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var built = try compile(a, &builder, try gcd(&builder));
    defer built.deinit();
    var prepared = try kosmos.Prepared.init(a, built.image);
    defer prepared.deinit();
    for ([_]struct { x: u64, y: u64, expected: u64 }{
        .{ .x = 1071, .y = 462, .expected = 21 },
        .{ .x = 97, .y = 89, .expected = 1 },
        .{ .x = 0, .y = 55, .expected = 55 },
        .{ .x = 123456, .y = 0, .expected = 123456 },
    }) |case| {
        const input = try contracts.encodeOwned(struct { u64, u64 }, a, .{ case.x, case.y });
        defer a.free(input);
        _ = try execute(a, &prepared, input, case.expected);
    }
}

test "BUILD-02 concrete native execution traverses recursive structured input over many quanta" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var built = try compile(a, &builder, try listLength(&builder));
    defer built.deinit();
    var prepared = try kosmos.Prepared.init(a, built.image);
    defer prepared.deinit();
    for ([_]usize{ 0, 3, 300 }) |length| {
        const input = try a.alloc(u8, length * 9 + 1);
        defer a.free(input);
        var writer: data.wire.Writer = .{ .output = input };
        for (0..length) |i| {
            try writer.natural(1);
            try writer.fixed(u64, @intCast(i * 7));
        }
        try writer.natural(0);
        const quanta = try execute(a, &prepared, input, length);
        if (length != 0) try std.testing.expect(quanta > length);
    }
}

const OwnerTypes = struct {
    pub const application_id = "workspace-owner-test";
    pub const input_schema_id = "workspace-owner.input/1";
    pub const output_schema_id = "workspace-owner.output/1";
    pub const failure_schema_id = "workspace-owner.failure/1";
    pub const message_schema_id = "workspace-owner.message/1";
    pub const Input = struct { u64, u64 };
    pub const Output = u64;
    pub const Failure = void;
    pub const Message = void;
};

test "WORK-01 retained work keeps controller state distinct and replays exact admissions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "workspace-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "workspace-unit", .manifest = "{}" };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "workspace-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });
    var initial = try service.task(a, parent.receipt.task);
    defer initial.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    const repeated = try service.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    try std.testing.expect(repeated.replayed);
    try std.testing.expectEqualDeep(program.receipt.workspace, repeated.receipt.workspace);
    const input = try a.alloc(u8, 300 * 9 + 1);
    defer a.free(input);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const started = try service.workspaceStart(scratch, "start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    const duplicate = try service.workspaceStart(scratch, "start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualDeep(started.receipt.workspace, duplicate.receipt.workspace);
    const id = started.receipt.workspace.?;
    var work = try service.workspaceWork(a, parent.receipt.task, id);
    defer work.deinit();
    try std.testing.expect(!work.value.terminal());
    try std.testing.expectEqual(.parked, work.value.schedule);
    _ = try service.workspaceControl(scratch, "advance", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance);
    const replayed = try service.workspaceControl(scratch, "advance", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance);
    try std.testing.expect(replayed.replayed);
    try std.testing.expectError(error.StaleRevision, service.workspaceControl(scratch, "stale", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance));
    var after = try service.task(a, parent.receipt.task);
    defer after.deinit();
    try std.testing.expectEqualDeep(initial.value.checkpoint, after.value.checkpoint);
    try std.testing.expectEqualDeep(initial.value.current_occurrence, after.value.current_occurrence);
    try std.testing.expectEqual(initial.value.execution_revision, after.value.execution_revision);
    try std.testing.expect(after.value.revision > initial.value.revision);
    const abandoned = try service.workspaceStart(scratch, "abandon-start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    var abandoned_work = try service.workspaceWork(a, parent.receipt.task, abandoned.receipt.workspace.?);
    defer abandoned_work.deinit();
    _ = try service.workspaceControl(scratch, "cancel", parent.receipt.task, abandoned_work.value.id, abandoned_work.value.execution_revision, abandoned_work.value.control_revision, .{ .cancel = .{ .bytes = "investigate another input" } });
    var cancelled = try service.workspaceWork(a, parent.receipt.task, abandoned_work.value.id);
    defer cancelled.deinit();
    try std.testing.expectEqual(.cancelled, cancelled.value.outcome_kind);
    try std.testing.expect(cancelled.value.cancellation_applied);
    try std.testing.expect(cancelled.value.result == null);
    try service.park(scratch);
    try service.close(scratch);
    service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    const recovered = try service.workspaceControl(scratch, "advance", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance);
    try std.testing.expect(recovered.replayed);
    var retained = try service.workspaceWork(a, parent.receipt.task, id);
    defer retained.deinit();
    _ = try service.workspaceControl(scratch, "delegate", parent.receipt.task, id, retained.value.execution_revision, retained.value.control_revision, .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } });
    var turns: usize = 0;
    while (turns < 1000) : (turns += 1) {
        const step = try service.pump(scratch);
        try std.testing.expect(step != .work);
        var observed = try service.workspaceWork(a, parent.receipt.task, id);
        defer observed.deinit();
        if (observed.value.terminal()) {
            try std.testing.expectEqual(.completed, observed.value.outcome_kind);
            const bytes = try namespace.store.object(a, observed.value.result.?, null);
            defer a.free(bytes);
            var result = try contracts.decodeOwned(u64, a, bytes);
            defer result.deinit();
            try std.testing.expectEqual(300, result.value);
            break;
        }
    }
    try std.testing.expect(turns < 1000);
    try std.testing.expect(turns > 200);
    var final_parent = try service.task(a, parent.receipt.task);
    defer final_parent.deinit();
    try std.testing.expectEqualDeep(initial.value.checkpoint, final_parent.value.checkpoint);
    try std.testing.expectEqual(initial.value.execution_revision, final_parent.value.execution_revision);
    const first_zero = try service.workspaceStart(scratch, "zero-one", parent.receipt.task, program.receipt.workspace.?, &.{0}, .{});
    const second_zero = try service.workspaceStart(scratch, "zero-two", parent.receipt.task, program.receipt.workspace.?, &.{0}, .{});
    var first = try service.workspaceWork(a, parent.receipt.task, first_zero.receipt.workspace.?);
    defer first.deinit();
    var second = try service.workspaceWork(a, parent.receipt.task, second_zero.receipt.workspace.?);
    defer second.deinit();
    try std.testing.expectEqualDeep(first.value.result.?, second.value.result.?);
    try std.testing.expect(!std.meta.eql(first.value.result_value.?, second.value.result_value.?));
    // WORK-11: independent subjects share neither execution nor the parent.
    // Collection preserves caller order, repetitions and explicit non-results.
    const pending_collection = try service.workspaceStart(scratch, "collection-pending", parent.receipt.task, program.receipt.workspace.?, input, .{});
    const collection_ids = [_][32]u8{ second.value.id, abandoned_work.value.id, @splat(0), pending_collection.receipt.workspace.?, first.value.id, second.value.id };
    var collection_refs: [collection_ids.len]contracts.workspace.Ref = undefined;
    for (collection_ids, &collection_refs) |collection_id, *ref| ref.* = try workspaceRef(scratch, .work, collection_id);
    const collected = try service.workspaceCommand(scratch, "ordered-collection", parent.receipt.task, .{ .work = .{ .collect = .{ .works = .{ .items = &collection_refs } } } });
    try std.testing.expectEqual(.observed, collected.disposition);
    var collection_json = try native.json.parse(a, collected.observation_json.bytes, .{});
    defer collection_json.deinit();
    try std.testing.expectEqual(collection_ids.len, collection_json.value.array.items.len);
    const expected_outcomes = [_][]const u8{ "completed", "cancelled", "unavailable", "yielded", "completed", "completed" };
    for (collection_json.value.array.items, collection_refs, expected_outcomes) |item, ref, expected| {
        try std.testing.expectEqualStrings(ref.id.bytes, item.object.get("work").?.object.get("id").?.string);
        try std.testing.expectEqualStrings(expected, item.object.get("outcome").?.string);
    }
    var collection_parent = try service.task(a, parent.receipt.task);
    defer collection_parent.deinit();
    try std.testing.expectEqualDeep(initial.value.checkpoint, collection_parent.value.checkpoint);
    try std.testing.expectEqual(initial.value.execution_revision, collection_parent.value.execution_revision);
    // AUT-08: no authored yields or ports are needed for whole-work controls.
    var noncooperative_builder = source.Builder.init(a);
    defer noncooperative_builder.deinit();
    const noncooperative_source = try native.source_records.encode(scratch, try @import("workspace_sources.zig").listLengthWithYields(&noncooperative_builder, false));
    const noncooperative_program = try service.workspaceBuild(scratch, "noncooperative-build", parent.receipt.task, noncooperative_source, &diagnostic);
    const noncooperative_start = try service.workspaceStart(scratch, "noncooperative-start", parent.receipt.task, noncooperative_program.receipt.workspace.?, input, .{});
    var noncooperative = try service.workspaceWork(scratch, parent.receipt.task, noncooperative_start.receipt.workspace.?);
    defer noncooperative.deinit();
    try std.testing.expectEqual(.progressed, noncooperative.value.outcome_kind);
    try std.testing.expectEqual(null, noncooperative.value.current_port);
    _ = try service.workspaceControl(scratch, "noncooperative-park", parent.receipt.task, noncooperative.value.id, noncooperative.value.execution_revision, noncooperative.value.control_revision, .park);
    var parked_noncooperative = try service.workspaceWork(scratch, parent.receipt.task, noncooperative.value.id);
    defer parked_noncooperative.deinit();
    _ = try service.workspaceControl(scratch, "noncooperative-cancel", parent.receipt.task, noncooperative.value.id, parked_noncooperative.value.execution_revision, parked_noncooperative.value.control_revision, .{ .cancel = .{ .bytes = "controller changed direction" } });
    var cancelled_noncooperative = try service.workspaceWork(scratch, parent.receipt.task, noncooperative.value.id);
    defer cancelled_noncooperative.deinit();
    try std.testing.expectEqual(.cancelled, cancelled_noncooperative.value.outcome_kind);
    const value_ref: contracts.workspace.Ref = .{ .kind = .value, .id = .{ .bytes = &std.fmt.bytesToHex(first.value.result_value.?.digest, .lower) } };
    const expanded = try service.workspaceCommand(scratch, "expand-zero", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = value_ref, .page = .{} } } });
    try std.testing.expectEqual(.observed, expanded.disposition);
    var expansion = try native.json.parse(a, expanded.observation_json.bytes, .{});
    defer expansion.deinit();
    try std.testing.expectEqualStrings("\"0\"", expansion.value.object.get("text").?.string);
    var stored_program = try service.workspaceProgram(a, parent.receipt.task, program.receipt.workspace.?);
    defer stored_program.deinit();
    const materialize: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .value = .{ .inline_json = .{ .schema = .{ .kind = .schema, .id = .{ .bytes = &std.fmt.bytesToHex(stored_program.value.description.result_schema.digest, .lower) } }, .json_text = .{ .bytes = "\"44\"" } } } },
        .sources = .{ .items = &.{value_ref} },
    } } };
    const judgment = try service.workspaceCommand(scratch, "context-judgment", parent.receipt.task, materialize);
    try std.testing.expectEqual(.observed, judgment.disposition);
    var judgment_json = try native.json.parse(a, judgment.observation_json.bytes, .{});
    defer judgment_json.deinit();
    const judgment_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, judgment_json.value.object.get("value").?);
    try std.testing.expectEqualStrings("judgment", judgment_json.value.object.get("derivation").?.object.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 1), judgment_json.value.object.get("derivation").?.object.get("sources").?.array.items.len);
    const selection: contracts.workspace.Command = .{ .context = .{ .select = .{ .values = .{ .items = &.{ judgment_ref, value_ref } } } } };
    const selected = try service.workspaceCommand(scratch, "context-select", parent.receipt.task, selection);
    try std.testing.expectEqual(.observed, selected.disposition);
    try std.testing.expectEqual(.view, selected.selected_view.?.kind);
    const repeated_selection = try service.workspaceCommand(scratch, "context-select", parent.receipt.task, selection);
    try std.testing.expectEqualStrings(selected.selected_view.?.id.bytes, repeated_selection.selected_view.?.id.bytes);
    const partial_view = try service.workspaceCommand(scratch, "view-page", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = selected.selected_view.?, .page = .{ .maximum = 30 } } } });
    var partial_json = try native.json.parse(a, partial_view.observation_json.bytes, .{});
    defer partial_json.deinit();
    try std.testing.expect(!partial_json.value.object.get("selection").?.object.get("complete").?.bool);
    try std.testing.expectEqualStrings("selected_values_only", partial_json.value.object.get("coverage").?.string);
    const later_view = try service.workspaceCommand(scratch, "view-later-page", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = selected.selected_view.?, .page = .{ .offset = 30, .maximum = 30 } } } });
    var later_json = try native.json.parse(a, later_view.observation_json.bytes, .{});
    defer later_json.deinit();
    try std.testing.expectEqualStrings("30", later_json.value.object.get("selection").?.object.get("offset").?.number_string);
    const unavailable = try service.workspaceCommand(scratch, "invalid-value", parent.receipt.task, .{ .context = .{ .select = .{ .values = .{ .items = &.{.{ .kind = .value, .id = .{ .bytes = "0000000000000000000000000000000000000000000000000000000000000000" } }} } } } });
    try std.testing.expectEqual(.rejected, unavailable.disposition);
    try std.testing.expectEqual(null, unavailable.selected_view);
    const replay_observation = try service.workspaceCommand(scratch, "advance", parent.receipt.task, .{ .work = .{ .advance = .{ .work = .{ .kind = .work, .id = .{ .bytes = &std.fmt.bytesToHex(id, .lower) } }, .execution_revision = work.value.execution_revision, .control_revision = work.value.control_revision } } });
    try std.testing.expectEqual(.observed, replay_observation.disposition);
    var replay_json = try native.json.parse(a, replay_observation.observation_json.bytes, .{});
    defer replay_json.deinit();
    try std.testing.expect(replay_json.value.object.get("replayed").?.bool);
    try std.testing.expect(!std.mem.eql(u8, replay_json.value.object.get("outcome").?.string, "completed"));

    // Real local ports survive service replacement, and the acknowledged
    // answer remains the only consumable reply after that replacement.
    var interactive_builder = source.Builder.init(a);
    defer interactive_builder.deinit();
    const interactive_source = try native.source_records.encode(a, try alternatives(&interactive_builder, true));
    defer a.free(interactive_source);
    const interactive_program = try service.workspaceCommand(scratch, "interactive-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = interactive_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } } } } } });
    try std.testing.expectEqual(.observed, interactive_program.disposition);
    var program_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&program_id, interactive_program.program.?.id.bytes);
    const interactive_input = try contracts.encodeOwned(u64, a, 100);
    defer a.free(interactive_input);
    const interactive_started = try service.workspaceStart(scratch, "interactive-start", parent.receipt.task, program_id, interactive_input, .{});
    const interactive_id = interactive_started.receipt.workspace.?;
    var interactive_artifact = try service.workspaceProgram(scratch, parent.receipt.task, program_id);
    defer interactive_artifact.deinit();
    const start_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = interactive_program.program.?,
        .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, interactive_artifact.value.description.input_schema.digest), .json_text = .{ .bytes = "\"100\"" } } },
        .policy = .{},
    } } };
    const original_observation = try service.workspaceCommand(scratch, "interactive-start", parent.receipt.task, start_command);
    for (0..4) |i| {
        var current = try service.workspaceWork(a, parent.receipt.task, interactive_id);
        defer current.deinit();
        const port_bytes = try namespace.store.object(a, current.value.current_port.?, null);
        defer a.free(port_bytes);
        var port = try contracts.decodeOwned(native.workspace.Port, a, port_bytes);
        defer port.deinit();
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), port.value.generation);
        const interaction: @FieldType(contracts.workspace.Work, "interact") = .{
            .expected = .{ .work = try workspaceRef(scratch, .work, interactive_id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
            .port = try workspaceRef(scratch, .port, port.value.id),
            .generation = port.value.generation,
            .command = if (i == 3) .{ .finish = .{} } else .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = if (i == 0) "{}" else if (i == 1) "\"10\"" else "\"20\"" } } } },
        };
        const operation_id = try std.fmt.allocPrint(scratch, "interact-{d}", .{i});
        const accepted = try service.workspaceInteract(scratch, operation_id, parent.receipt.task, interaction);
        const replay = try service.workspaceInteract(a, operation_id, parent.receipt.task, interaction);
        defer a.free(replay.receipt.client_operation_id.bytes);
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqualDeep(accepted.receipt, replay.receipt);
        const historical = try service.workspaceCommand(scratch, "interactive-start", parent.receipt.task, start_command);
        try std.testing.expectEqualStrings(original_observation.observation_json.bytes, historical.observation_json.bytes);
        const live = try service.workspaceCommand(scratch, "inspect-answered", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = interaction.expected.work } } });
        var live_json = try native.json.parse(a, live.observation_json.bytes, .{});
        defer live_json.deinit();
        try std.testing.expect(!live_json.value.object.get("port_accepts_command").?.bool);
        try std.testing.expectError(error.StaleRevision, service.workspaceInteract(scratch, "new-conflicting-answer", parent.receipt.task, interaction));
        try service.close(scratch);
        service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        const restored_observation = try service.workspaceCommand(scratch, "interactive-start", parent.receipt.task, start_command);
        try std.testing.expectEqualStrings(original_observation.observation_json.bytes, restored_observation.observation_json.bytes);
        var recovered_work = try service.workspaceWork(a, parent.receipt.task, interactive_id);
        defer recovered_work.deinit();
        _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "interactive-resume-{d}", .{i}), parent.receipt.task, interactive_id, recovered_work.value.execution_revision, recovered_work.value.control_revision, .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .next_exposed_event } });
        for (0..20) |_| {
            _ = try service.pump(scratch);
            var observed = try service.workspaceWork(a, parent.receipt.task, interactive_id);
            defer observed.deinit();
            if (observed.value.terminal() or observed.value.port_generation > port.value.generation) break;
        }
    }
    var interactive_completed = try service.workspaceWork(a, parent.receipt.task, interactive_id);
    defer interactive_completed.deinit();
    try std.testing.expectEqual(.completed, interactive_completed.value.outcome_kind);
    const interactive_result = try namespace.store.object(a, interactive_completed.value.result.?, null);
    defer a.free(interactive_result);
    var final_result = try contracts.decodeOwned(u64, a, interactive_result);
    defer final_result.deinit();
    try std.testing.expectEqual(@as(u64, 121), final_result.value);
    try service.validateWorkspace(scratch, parent.receipt.task);
    // A valid checkpoint does not certify unrelated native port metadata.
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
    const archive_index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
    try namespace.store.begin();
    var forged = interactive_completed.value;
    forged.port_generation += 1;
    try namespace.store.putRecord(native.workspace.Work, "workspace_work", forged.id, forged.task, forged);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, parent.receipt.task, archive_index.records.items));
    namespace.store.rollback();

    const cancel_started = try service.workspaceStart(scratch, "cancel-after-answer-start", parent.receipt.task, program_id, interactive_input, .{});
    var cancel_work = try service.workspaceWork(a, parent.receipt.task, cancel_started.receipt.workspace.?);
    defer cancel_work.deinit();
    const cancel_port_bytes = try namespace.store.object(a, cancel_work.value.current_port.?, null);
    defer a.free(cancel_port_bytes);
    var cancel_port = try contracts.decodeOwned(native.workspace.Port, a, cancel_port_bytes);
    defer cancel_port.deinit();
    _ = try service.workspaceInteract(scratch, "answer-before-cancel", parent.receipt.task, .{
        .expected = .{ .work = try workspaceRef(scratch, .work, cancel_work.value.id), .execution_revision = cancel_work.value.execution_revision, .control_revision = cancel_work.value.control_revision },
        .port = try workspaceRef(scratch, .port, cancel_port.value.id),
        .generation = cancel_port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, cancel_port.value.interface.argument.digest), .json_text = .{ .bytes = "{}" } } } },
    });
    var answered_work = try service.workspaceWork(a, parent.receipt.task, cancel_work.value.id);
    defer answered_work.deinit();
    _ = try service.workspaceControl(scratch, "cancel-after-answer", parent.receipt.task, cancel_work.value.id, answered_work.value.execution_revision, answered_work.value.control_revision, .{ .cancel = .{ .bytes = "stop exploring" } });
    for (0..20) |_| {
        _ = try service.pump(scratch);
        var observed = try service.workspaceWork(a, parent.receipt.task, cancel_work.value.id);
        defer observed.deinit();
        if (observed.value.terminal()) break;
    }
    var cancelled_after_answer = try service.workspaceWork(a, parent.receipt.task, cancel_work.value.id);
    defer cancelled_after_answer.deinit();
    try std.testing.expectEqual(.cancelled, cancelled_after_answer.value.outcome_kind);
    try std.testing.expect(cancelled_after_answer.value.cancellation_applied);
    // WORK-14: cancellation is applied before cleanup finishes. Cleanup may
    // yield and expose a real request without being reported disposed early.
    var disposal_builder = source.Builder.init(scratch);
    defer disposal_builder.deinit();
    const disposal_source = try native.source_records.encode(scratch, try @import("workspace_sources.zig").yieldingDisposal(&disposal_builder));
    const disposal_program = try service.workspaceCommand(scratch, "disposal-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = disposal_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .observation }} } } } });
    try std.testing.expectEqual(.observed, disposal_program.disposition);
    var disposal_program_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&disposal_program_id, disposal_program.program.?.id.bytes);
    const disposal_started = try service.workspaceStart(scratch, "disposal-start", parent.receipt.task, disposal_program_id, &.{}, .{});
    const disposal_id = disposal_started.receipt.workspace.?;
    var before_disposal = try service.workspaceWork(scratch, parent.receipt.task, disposal_id);
    defer before_disposal.deinit();
    try std.testing.expectEqual(.yielded, before_disposal.value.outcome_kind);
    _ = try service.workspaceControl(scratch, "disposal-cancel", parent.receipt.task, disposal_id, before_disposal.value.execution_revision, before_disposal.value.control_revision, .{ .cancel = .{ .bytes = "abandoned inquiry" } });
    var saw_cleanup_port = false;
    var disposal_complete = false;
    for (0..20) |_| {
        var current = try service.workspaceWork(scratch, parent.receipt.task, disposal_id);
        defer current.deinit();
        try std.testing.expect(current.value.cancellation_applied);
        const inspected = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "disposal-inspect-{d}", .{current.value.execution_revision}), parent.receipt.task, .{ .work = .{ .inspect = .{ .work = try workspaceRef(scratch, .work, disposal_id) } } });
        var observation = try native.json.parse(scratch, inspected.observation_json.bytes, .{});
        defer observation.deinit();
        try std.testing.expectEqual(current.value.terminal(), observation.value.object.get("cleanup_complete").?.bool);
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            disposal_complete = true;
            break;
        }
        if (current.value.current_port) |ref| {
            saw_cleanup_port = true;
            var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, ref, null));
            defer port.deinit();
            _ = try service.workspaceInteract(scratch, "disposal-answer", parent.receipt.task, .{
                .expected = .{ .work = try workspaceRef(scratch, .work, disposal_id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
                .port = try workspaceRef(scratch, .port, port.value.id),
                .generation = port.value.generation,
                .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = "{}" } } } },
            });
        }
        _ = try service.pump(scratch);
    }
    try std.testing.expect(saw_cleanup_port and disposal_complete);
    try service.validateWorkspace(scratch, parent.receipt.task);
    // OWN-08: a real SQLite write failure after the kernel publishes fences
    // the entire owner, including root and independent work dispatch.
    const fault_start = try service.workspaceStart(scratch, "fault-start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    var fault_work = try service.workspaceWork(scratch, parent.receipt.task, fault_start.receipt.workspace.?);
    defer fault_work.deinit();
    try namespace.store.database.exec("PRAGMA query_only=ON;");
    try std.testing.expectError(error.StorageUnavailable, service.workspaceControl(scratch, "fault-advance", parent.receipt.task, fault_work.value.id, fault_work.value.execution_revision, fault_work.value.control_revision, .advance));
    try std.testing.expect(namespace.store.fenced and service.active != null);
    try std.testing.expectError(error.StorageUnavailable, service.pump(scratch));
    try namespace.store.database.exec("PRAGMA query_only=OFF;");
}

test "workspace commands use the generated nested-sum schema and native model normalization" {
    const protean = @import("protean");
    const Action = union(enum) { program: struct { command: contracts.workspace.Program } };
    const Profile = protean.model_invocation.Profile(Action, .{.{ .name = "program", .description = "Construct or inspect Horos." }}, .{});
    const declaration = Profile.allDeclarations().items[0];
    try std.testing.expectEqual(.sum, declaration.argument_codec.items[0].field.kind);
    try std.testing.expect(std.mem.indexOf(u8, declaration.input_schema_json.bytes, "\"anyOf\"") != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Model = protean.model(.{ .name = "workspace-codec", .model = "fixture-model", .parameters = .{}, .protocol = struct {
        pub const semantic_identity = protean.model_invocation.protocol_identity;
    } });
    var invocation = try Profile.templateValue(Model, .{ .items = &.{} }, .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false });
    invocation.tools = Profile.allDeclarations();
    for ([_]struct { arguments: []const u8, valid: bool }{
        .{ .arguments = "{\"command\":{\"tag\":\"describe\",\"value\":{\"section\":\"source_records\",\"page\":{\"offset\":0,\"maximum\":16384}}}}", .valid = true },
        .{ .arguments = "{\"command\":{\"tag\":\"invoke_native_code\",\"value\":{}}}", .valid = false },
        .{ .arguments = "{\"command\":{\"tag\":\"describe\",\"value\":{\"section\":\"source_records\",\"page\":{\"offset\":0,\"maximum\":16384},\"authority\":true}}}", .valid = false },
    }) |case| {
        var function = native.json.object();
        try native.json.put(a, &function, "type", native.json.string("function_call"));
        try native.json.put(a, &function, "status", native.json.string("completed"));
        try native.json.put(a, &function, "call_id", native.json.string("command"));
        try native.json.put(a, &function, "name", native.json.string("program"));
        try native.json.put(a, &function, "arguments", native.json.string(case.arguments));
        var output: native.json.Value = .{ .array = .init(a) };
        try output.array.append(function);
        const normalized = try native.responses.OutputNormalizer(Profile).normalize(a, invocation, output);
        try std.testing.expectEqual(.output, std.meta.activeTag(normalized));
        const decoded = normalized.output.items.items[0].function_call.decoded_action;
        try std.testing.expectEqual(case.valid, decoded == .decoded);
        if (decoded == .decoded) try std.testing.expectEqual(.source_records, decoded.decoded.program.command.describe.section);
    }
}

const ContextTypes = struct {
    pub const application_id = "workspace-context-test";
    pub const input_schema_id = "workspace-context.input/1";
    pub const output_schema_id = "workspace-context.output/1";
    pub const failure_schema_id = "workspace-context.failure/1";
    pub const message_schema_id = "workspace-context.message/1";
    pub const Input = contracts.workspace.Command;
    pub const Output = contracts.workspace.Reply;
    pub const Failure = void;
    pub const Message = void;
};
const ContextApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const author = horos.authoring.interop;
        const input = try author.schemaId(c.author, try c.schema(ContextTypes.Input));
        const output = try author.schemaId(c.author, try c.schema(ContextTypes.Output));
        const effect = try author.operationId(c.author, try c.external("workspace-context", try c.schema(ContextTypes.Input), try c.schema(ContextTypes.Output), .read));
        const entry = try c.builder.declare(&.{input}, output, &.{effect}, &.{});
        try c.builder.define(entry, try c.builder.term(.{ .perform = .{ .effect = effect, .payload = try c.builder.reference(c.builder.parameter(entry, 0)) } }));
        return c.builder.module(entry, try author.schemaId(c.author, try c.schema(void)));
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(ContextTypes.Input, ctx.allocator, bytes);
        defer command.deinit();
        // This fixture's compiled application accepts the command as its root
        // input. The production adapter authenticates a captured model action.
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command.value, .snapshot = ctx.resources[0], .catalog = if (ctx.resources.len > 1) ctx.resources[1] else null });
    }
    fn payloadSchema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(ContextTypes.Input, a);
    }
    fn resultSchema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(ContextTypes.Output, a);
    }
};

test "CTX-01 snapshot materialization retains omitted source for a broader evidence pivot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const protean = @import("protean");
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = ContextTypes.Input, .Result = ContextTypes.Output, .Failure = void, .application = ContextApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "context-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const assets: native.discovery.Assets = .{ .image = image, .application = "context-unit", .manifest = "{}" };
    var handlers = try native.Registry.init(a, &.{.{ .identity = "workspace-context", .resource_role = "workspace", .kind = .workspace, .workspace = ContextApplication.authorize, .payload_schema = ContextApplication.payloadSchema, .resume_schema = ContextApplication.resultSchema }});
    defer handlers.deinit();
    const text = "ordinary rows agree\nrare exception: missing invoice\n";
    var file_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &file_digest, .{});
    const snapshot = try contracts.encodeOwned(contracts.RepositorySnapshot, a, .{ .version = 2, .excluded_entries = 3, .files = .{ .items = &.{.{ .path = .{ .bytes = "evidence.txt" }, .sha256 = file_digest, .contents = .{ .bytes = text } }} } });
    defer a.free(snapshot);
    var algorithm = source.Builder.init(a);
    defer algorithm.deinit();
    var gcd_program = try horos.source.lower(a, try gcd(&algorithm));
    defer gcd_program.deinit();
    const component: data.component.Object = .{ .program = gcd_program.program, .exports = &.{.{ .name = "apply", .reference = .{ .kind = .function, .id = gcd_program.program.roots.entry } }}, .borrows = &.{.{ .function = gcd_program.program.roots.entry }} };
    const component_bytes = try a.alloc(u8, try data.component.encodedLength(component));
    defer a.free(component_bytes);
    _ = try data.component.encode(a, component, component_bytes);
    const catalog = try contracts.encodeOwned(contracts.tool_construction.Catalog, a, .{ .items = &.{.{ .id = .{ .bytes = "gcd" }, .object = .{ .bytes = component_bytes } }} });
    defer a.free(catalog);
    var grants = [_]native.registry.Grant{.{ .identity = "workspace-context", .resource_role = "workspace", .resource_identity = undefined }};
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "context-test", .resources = &.{ snapshot, catalog }, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    grants[0].resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(ContextTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const command: contracts.workspace.Command = .{ .context = .{ .materialize = .{ .input = .{ .snapshot = .{ .path = .{ .bytes = "evidence.txt" }, .offset = 0, .maximum = 19 } }, .sources = .{ .items = &.{} } } } };
    const parent = try service.submit(scratch, "parent", command);
    for (0..32) |_| {
        const step = try service.pump(scratch);
        try std.testing.expect(step != .work);
        if (step == .idle or step == .waiting) break;
    }
    var finished = try service.task(a, parent.receipt.task);
    defer finished.deinit();
    try std.testing.expectEqual(.completed, finished.value.outcome_kind);
    const bytes = try namespace.store.object(a, finished.value.result.?, null);
    defer a.free(bytes);
    var reply = try contracts.decodeOwned(ContextTypes.Output, a, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(.observed, reply.value.disposition);
    var observation = try native.json.parse(a, reply.value.observation_json.bytes, .{});
    defer observation.deinit();
    const derivation = observation.value.object.get("derivation").?;
    try std.testing.expectEqualStrings("acquisition", derivation.object.get("kind").?.string);
    try std.testing.expect(!derivation.object.get("complete_file").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, observation.value.object.get("preview").?.object.get("text").?.string, "rare exception") == null);
    const source_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, observation.value.object.get("source").?);
    const expansion = try service.workspaceCommand(scratch, "expand-source", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = source_ref, .page = .{} } } });
    var expanded = try native.json.parse(a, expansion.observation_json.bytes, .{});
    defer expanded.deinit();
    try std.testing.expectEqualStrings(text, expanded.value.object.get("text").?.string);
    const other = try service.submit(scratch, "other-task", command);
    const forbidden = try service.workspaceCommand(scratch, "cross-task-source", other.receipt.task, .{ .context = .{ .expand = .{ .reference = source_ref, .page = .{} } } });
    try std.testing.expectEqual(.rejected, forbidden.disposition);
    const recipe = "{\"instances\":[{\"key\":\"algorithm\",\"component_id\":\"gcd\"}],\"bindings\":[],\"entry\":{\"instance\":\"algorithm\",\"symbol\":\"apply\"}}";
    const build_parent = try service.submit(scratch, "component-parent", .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = recipe } }, .source_kind = .component_recipe, .exposures = .{ .items = &.{} } } } });
    var built_id: ?[32]u8 = null;
    var compilation_seen = false;
    for (0..32) |_| {
        const step = try service.pump(scratch);
        if (step == .work) {
            try std.testing.expectEqual(.workspace_build, step.work.operation);
            try std.testing.expect(!compilation_seen);
            compilation_seen = true;
            const worker = try native.testing.Worker.init(a, io);
            defer worker.deinit(a) catch unreachable;
            try worker.start(step.work, profile.authority, null);
            // Control admission remains available while source compilation owns
            // the worker, and does not invalidate the in-flight attempt.
            var compiling = try service.task(a, build_parent.receipt.task);
            defer compiling.deinit();
            try std.testing.expect(compiling.value.current_occurrence != null);
            _ = try service.submit(scratch, "during-compilation", command);
            while (!worker.finished()) try io.sleep(.fromMilliseconds(1), .awake);
            try worker.join();
            try service.completeWork(scratch, step.work, worker.result.?);
            try worker.release();
            // A captured build survives owner replacement without a second
            // compilation dispatch; explicit resume only interprets it.
            try service.close(a);
            service = try native.tasks.Service(ContextTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            try std.testing.expectEqual(.idle, try service.pump(scratch));
            var captured = try service.task(a, build_parent.receipt.task);
            defer captured.deinit();
            _ = try service.resumeTask(scratch, "resume-build-capture", build_parent.receipt.task, captured.value.revision);
        }
        var query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='workspace_program'", &.{.{ .blob = &build_parent.receipt.task }});
        defer query.deinit();
        if (try query.step() == .row) {
            var built = try contracts.decodeOwned(native.workspace.Program, a, try query.bytes(0));
            defer built.deinit();
            try std.testing.expectEqual(.component_recipe, built.value.description.source_kind);
            built_id = built.value.artifact.digest;
            break;
        }
    }
    try std.testing.expect(compilation_seen);
    try std.testing.expect(built_id != null);
    const input = try contracts.encodeOwned(struct { u64, u64 }, a, .{ 1071, 462 });
    defer a.free(input);
    const started = try service.workspaceStart(scratch, "component-start", build_parent.receipt.task, built_id.?, input, .{});
    var child = try service.workspaceWork(a, build_parent.receipt.task, started.receipt.workspace.?);
    defer child.deinit();
    try std.testing.expectEqual(.completed, child.value.outcome_kind);
    const result_bytes = try namespace.store.object(a, child.value.result.?, null);
    defer a.free(result_bytes);
    var result = try contracts.decodeOwned(u64, a, result_bytes);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 21), result.value);
    const archive_path = try std.fmt.allocPrint(a, "{s}/build.par", .{path_buffer[0..length]});
    defer a.free(archive_path);
    _ = try service.exportCheckpoint(scratch, build_parent.receipt.task, archive_path);
}

const WaitTypes = struct {
    pub const application_id = "workspace-wait-test";
    pub const input_schema_id = "workspace-wait.input/1";
    pub const output_schema_id = "workspace-wait.output/1";
    pub const failure_schema_id = "workspace-wait.failure/1";
    pub const message_schema_id = "workspace-wait.message/1";
    pub const Input = void;
    pub const Output = contracts.workspace.Reply;
    pub const Failure = void;
    pub const Message = @FieldType(contracts.workspace.Work, "wait");
};
const WaitApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const interop = horos.authoring.interop;
        const b = c.builder;
        const unit = try b.scalar(void);
        const output = try interop.schemaId(c.author, try c.schema(WaitTypes.Output));
        const command = try interop.schemaId(c.author, try c.schema(contracts.workspace.Command));
        const work_command = try interop.schemaId(c.author, try c.schema(contracts.workspace.Work));
        const inbox = try interop.operationId(c.author, try @import("protean").inbox.Profile(WaitTypes.Message).declare(c));
        const workspace = try interop.operationId(c.author, try c.external("workspace-wait", try c.schema(contracts.workspace.Command), try c.schema(WaitTypes.Output), .read));
        const inbox_schema = b.effects.items[@intCast(inbox)].result;
        const message_schema = b.schemas.items[@intCast(inbox_schema)].sum[1];
        const message_fields = b.schemas.items[@intCast(message_schema)].product;
        const entry = try b.declare(&.{unit}, output, &.{ inbox, workspace }, &.{});
        const received = try b.variable(inbox_schema);
        const empty = try b.variable(unit);
        const message = try b.variable(message_schema);
        const id = try b.variable(message_fields[0]);
        const selection = try b.variable(message_fields[1]);
        const selected_work = try b.primitive(work_command, .variant, &.{try b.reference(selection)}, @backingInt(std.meta.Tag(contracts.workspace.Work).wait));
        const selected_command = try b.primitive(command, .variant, &.{selected_work}, @backingInt(std.meta.Tag(contracts.workspace.Command).work));
        const reply = try b.variable(output);
        const ignored = try b.variable(inbox_schema);
        const finish = try b.bind(ignored, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), try b.pure(try b.reference(reply)));
        const wait = try b.bind(reply, try b.term(.{ .perform = .{ .effect = workspace, .payload = selected_command } }), finish);
        const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(message), .variables = &.{ id, selection }, .body = wait } });
        const select = try b.term(.{ .match_sum = .{ .value = try b.reference(received), .cases = &.{ .{ .variable = empty, .body = try b.term(.{ .fail = try b.constant(void, {}) }) }, .{ .variable = message, .body = unpack } } } });
        try b.define(entry, try b.bind(received, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), select));
        return b.module(entry, unit);
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(contracts.workspace.Command, ctx.allocator, bytes);
        defer command.deinit();
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command.value });
    }
    fn schema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(contracts.workspace.Command, a);
    }
    fn result(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(WaitTypes.Output, a);
    }
};

test "AUT-07 OWN-11 concrete authored wait wakes for a user message or selected work without a worker" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const protean = @import("protean");
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = void, .Result = WaitTypes.Output, .Failure = void, .application = WaitApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "wait-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "wait-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = image, .application = "wait-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{ native.inbox.declaration(WaitTypes.Message), .{ .identity = "workspace-wait", .resource_role = "workspace", .kind = .workspace, .workspace = WaitApplication.authorize, .payload_schema = WaitApplication.schema, .resume_schema = WaitApplication.result } });
    defer handlers.deinit();
    var grants = [_]native.registry.Grant{ .{ .identity = "workspace-wait", .resource_role = "workspace", .resource_identity = undefined }, .{ .identity = native.inbox.identity, .resource_role = "user", .resource_identity = undefined } };
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "wait-test", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    for (&grants) |*grant| grant.resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_open = true;
    defer if (namespace_open) namespace.close() catch unreachable;
    var service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_open = true;
    defer if (service_open) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    const input = try a.alloc(u8, 300 * 9 + 1);
    defer a.free(input);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const WaitScenario = enum { imported_message, owned_message, selected_event, resumed_child, reopened_control };
    for (std.enums.values(WaitScenario), 0..) |scenario, index| {
        const interrupt = scenario == .imported_message or scenario == .owned_message;
        const prefix = try std.fmt.allocPrint(scratch, "wait-{d}", .{index});
        const parent = try service.submit(scratch, prefix, {});
        var diagnostic: native.program_construction.Diagnostic = .{};
        const program = try service.workspaceBuild(scratch, try std.fmt.allocPrint(scratch, "{s}-build", .{prefix}), parent.receipt.task, document, &diagnostic);
        const started = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "{s}-start", .{prefix}), parent.receipt.task, program.receipt.workspace.?, input, .{});
        var initial = try service.workspaceWork(a, parent.receipt.task, started.receipt.workspace.?);
        defer initial.deinit();
        const selection: WaitTypes.Message = .{ .works = .{ .items = &.{try workspaceRef(scratch, .work, initial.value.id)} }, .after = initial.value.event_watermark };
        _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "{s}-selection", .{prefix}), parent.receipt.task, selection);
        var waited = false;
        for (0..20) |_| {
            const step = try service.pump(scratch);
            try std.testing.expect(step != .work);
            if (step == .waiting) {
                waited = true;
                break;
            }
        }
        try std.testing.expect(waited);
        try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
        if (scenario == .imported_message) {
            const archive_path = try std.fmt.allocPrint(scratch, "{s}/waiting.par", .{path_buffer[0..length]});
            _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
            try service.close(scratch);
            service_open = false;
            try namespace.close();
            namespace_open = false;
            namespace = try native.Namespace.open(a, io, try std.fmt.allocPrint(scratch, "{s}/waiting-import", .{path_buffer[0..length]}));
            namespace_open = true;
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            service_open = true;
            _ = try service.importCheckpoint(scratch, "import-wait", archive_path);
            _ = try service.message(scratch, "wait-amendment", parent.receipt.task, selection);
            // Opening the namespace and appending input do not implicitly
            // resume old ownership; the explicit resume restores the wait.
            try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
            var paused = try service.task(a, parent.receipt.task);
            defer paused.deinit();
            _ = try service.resumeTask(scratch, "wait-resume", parent.receipt.task, paused.value.revision);
        } else if (scenario == .owned_message) {
            var guarded: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
            _ = try service.message(guarded.allocator(), "owned-wait-amendment", parent.receipt.task, selection);
            try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
            try std.testing.expect((try service.message(scratch, "owned-wait-amendment", parent.receipt.task, selection)).replayed);
        } else if (scenario == .reopened_control) {
            try service.close(scratch);
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
            _ = try service.workspaceControl(scratch, "reopen-and-advance", parent.receipt.task, initial.value.id, initial.value.execution_revision, initial.value.control_revision, .advance);
        } else {
            _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "wait-progress-{d}", .{index}), parent.receipt.task, initial.value.id, initial.value.execution_revision, initial.value.control_revision, .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } });
            if (scenario == .resumed_child) {
                try service.close(scratch);
                service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
                try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
                var paused = try service.task(scratch, parent.receipt.task);
                defer paused.deinit();
                var guarded: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
                _ = try service.resumeTask(guarded.allocator(), "restore-queued-child", parent.receipt.task, paused.value.revision);
                try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
                try std.testing.expect((try service.resumeTask(scratch, "restore-queued-child", parent.receipt.task, paused.value.revision)).replayed);
            }
        }
        for (0..30) |_| {
            const step = try service.pump(scratch);
            try std.testing.expect(step != .work);
            var current = try service.task(a, parent.receipt.task);
            defer current.deinit();
            if (current.value.terminal()) break;
        }
        var finished = try service.task(a, parent.receipt.task);
        defer finished.deinit();
        try std.testing.expectEqual(.completed, finished.value.outcome_kind);
        try std.testing.expectEqual(@as(usize, 0), finished.value.messages.items.len);
        const bytes = try namespace.store.object(a, finished.value.result.?, null);
        defer a.free(bytes);
        var reply = try contracts.decodeOwned(WaitTypes.Output, a, bytes);
        defer reply.deinit();
        var observation = try native.json.parse(a, reply.value.observation_json.bytes, .{});
        defer observation.deinit();
        try std.testing.expect(observation.value.object.get("ready").?.bool);
        try std.testing.expectEqual(interrupt, observation.value.object.get("interrupted").?.bool);
        var child = try service.workspaceWork(a, parent.receipt.task, initial.value.id);
        defer child.deinit();
        try std.testing.expect(!child.value.terminal());
        if (interrupt) try std.testing.expectEqual(initial.value.execution_revision, child.value.execution_revision) else try std.testing.expect(child.value.execution_revision > initial.value.execution_revision);
        try service.validateWorkspace(scratch, parent.receipt.task);
    }
}

const DelegateTypes = struct {
    pub const application_id = "workspace-delegation-test";
    pub const input_schema_id = "workspace-delegation.input/1";
    pub const output_schema_id = "workspace-delegation.output/1";
    pub const failure_schema_id = "workspace-delegation.failure/1";
    pub const message_schema_id = "workspace-delegation.message/1";
    pub const Input = void;
    pub const Output = void;
    pub const Failure = void;
    pub const Message = contracts.workspace.Command;
};
const DelegateApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const interop = horos.authoring.interop;
        const b = c.builder;
        const unit = try b.scalar(void);
        const output = try interop.schemaId(c.author, try c.schema(contracts.workspace.Reply));
        const inbox = try interop.operationId(c.author, try @import("protean").inbox.Profile(DelegateTypes.Message).declare(c));
        const workspace = try interop.operationId(c.author, try c.external("workspace-delegation", try c.schema(DelegateTypes.Message), try c.schema(contracts.workspace.Reply), .read));
        const inbox_schema = b.effects.items[@intCast(inbox)].result;
        const message_schema = b.schemas.items[@intCast(inbox_schema)].sum[1];
        const fields = b.schemas.items[@intCast(message_schema)].product;
        const entry = try b.declare(&.{unit}, unit, &.{ inbox, workspace }, &.{});
        const repeat = try b.term(.{ .yield_then = try b.term(.{ .call = .{ .function = entry, .arguments = &.{try b.constant(void, {})} } }) });
        const received = try b.variable(inbox_schema);
        const empty = try b.variable(unit);
        const message = try b.variable(message_schema);
        const id = try b.variable(fields[0]);
        const command = try b.variable(fields[1]);
        const ignored = try b.variable(output);
        const apply = try b.bind(ignored, try b.term(.{ .perform = .{ .effect = workspace, .payload = try b.reference(command) } }), repeat);
        const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(message), .variables = &.{ id, command }, .body = apply } });
        const select = try b.term(.{ .match_sum = .{ .value = try b.reference(received), .cases = &.{ .{ .variable = empty, .body = repeat }, .{ .variable = message, .body = unpack } } } });
        try b.define(entry, try b.bind(received, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), select));
        return b.module(entry, unit);
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(contracts.workspace.Command, ctx.allocator, bytes);
        defer command.deinit();
        var model: ?native.workspace.ModelBinding = null;
        if (command.value == .work and command.value.work == .delegate and command.value.work.delegate.interpretation == .model) {
            const selection = command.value.work.delegate.interpretation.model;
            if (!std.mem.eql(u8, selection.profile_id.bytes, "fixture") or !std.mem.eql(u8, selection.effort.bytes, "medium")) return error.Denied;
            model = .{ .profile_id = .{ .bytes = "fixture" }, .profile_digest = @splat(7), .settings = .{ .endpoint = .{ .bytes = "https://localhost/v1/responses" }, .audience = .{ .bytes = "fixture" }, .model = .{ .bytes = "fixture" }, .effort = .{ .bytes = "medium" }, .max_output_tokens = null, .request_bytes = null, .response_bytes = null, .timeout_ms = null }, .reasoning_mode = .{ .bytes = "standard" }, .reasoning_context = .{ .bytes = "auto" } };
        }
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command.value, .snapshot = ctx.resources[0], .model = model });
    }
};

fn inputPort(b: *source.Builder, text: bool) !source.Module {
    const unit = try b.scalar(void);
    const answer = if (text) try b.schema(.text) else try b.scalar(u64);
    const ask = try b.effect(.{ .identity = "example/input", .payload = unit, .result = answer, .external = false });
    const entry = try b.declare(&.{unit}, answer, &.{ask}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }));
    return b.module(entry, unit);
}

test "OWN-02 OWN-05 OWN-10 delegated typed answers use distinct real occurrences while root messages remain independent" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try @import("protean").compile(a, @import("protean").system(.{ .InitialArgs = void, .Result = void, .Failure = void, .application = DelegateApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "delegation-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "delegation-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = image, .application = "delegation-unit", .manifest = manifest };
    const declarations = [_]native.Declaration{ native.inbox.declaration(DelegateTypes.Message), .{ .identity = "workspace-delegation", .resource_role = "workspace", .kind = .workspace, .workspace = DelegateApplication.authorize, .payload_schema = WaitApplication.schema, .resume_schema = WaitApplication.result }, native.workspace_instrument.declaration(.model), native.workspace_instrument.declaration(.snapshot) };
    var handlers = try native.Registry.init(a, &declarations);
    defer handlers.deinit();
    const text = "actual frozen evidence";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const snapshot = try contracts.encodeOwned(contracts.RepositorySnapshot, a, .{ .version = 2, .excluded_entries = 0, .files = .{ .items = &.{.{ .path = .{ .bytes = "source.txt" }, .sha256 = digest, .contents = .{ .bytes = text } }} } });
    defer a.free(snapshot);
    var grants: [declarations.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "delegation-test", .resources = &.{snapshot}, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test", .inference = true } };
    for (declarations, &grants) |declaration, *grant| grant.* = .{ .identity = declaration.identity, .resource_role = declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_open = true;
    defer if (namespace_open) namespace.close() catch unreachable;
    var service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_open = true;
    defer if (service_open) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const Scenario = enum { model, snapshot, snapshot_empty, revoked, unknown, unknown_wait, not_sent_wait, cancel_capture, invalid_capture };
    for (std.enums.values(Scenario)) |scenario| {
        const snapshot_mode = scenario == .snapshot or scenario == .snapshot_empty;
        const successful = scenario == .model or snapshot_mode;
        const suffix = @tagName(scenario);
        const parent = try service.submit(scratch, try std.fmt.allocPrint(scratch, "parent-{s}", .{suffix}), {});
        var builder = source.Builder.init(a);
        defer builder.deinit();
        const source_text = try native.source_records.encode(scratch, try inputPort(&builder, snapshot_mode));
        const built_reply = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "build-{s}", .{suffix}), parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = source_text } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .input }} } } } });
        try std.testing.expect(built_reply.program != null);
        const target_start = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "start-{s}", .{suffix}), parent.receipt.task, try nativeIdentity(built_reply.program.?), &.{}, .{});
        const target_id = target_start.receipt.workspace.?;
        var target = try service.workspaceWork(scratch, parent.receipt.task, target_id);
        defer target.deinit();
        var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, target.value.current_port.?, null));
        defer port.deinit();
        const port_ref = try workspaceRef(scratch, .port, port.value.id);
        const interpretation: contracts.workspace.Interpretation = if (snapshot_mode) .{ .snapshot = .{ .port = port_ref, .generation = port.value.generation, .path = .{ .bytes = "source.txt" }, .offset = 0, .maximum = if (scenario == .snapshot_empty) 0 else text.len } } else .{ .model = .{ .port = port_ref, .generation = port.value.generation, .profile_id = .{ .bytes = "fixture" }, .effort = .{ .bytes = "medium" }, .subproblem = .{ .bytes = "Return forty-two as the selected hypothetical value." }, .inputs = .{ .items = &.{} } } };
        _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "delegate-{s}", .{suffix}), parent.receipt.task, .{ .work = .{ .delegate = .{ .expected = .{ .work = try workspaceRef(scratch, .work, target_id), .execution_revision = target.value.execution_revision, .control_revision = target.value.control_revision }, .policy = .{ .stop = .terminal, .continuation = .owner_scheduled }, .interpretation = interpretation } } });
        var dispatches: usize = 0;
        var instrument_id: ?[32]u8 = null;
        var resumed_handoff = false;
        for (0..256) |_| {
            if (instrument_id == null) {
                var rows = try namespace.store.database.prepare("SELECT body FROM records WHERE task=? AND kind='workspace_work'", &.{.{ .blob = &parent.receipt.task }});
                defer rows.deinit();
                while (try rows.step() == .row) {
                    const bytes = try rows.bytes(0);
                    const ref = try namespace.store.objectReference(bytes[0..32].*, null);
                    var candidate = try contracts.decodeOwned(native.workspace.Work, scratch, try namespace.store.object(scratch, ref, null));
                    defer candidate.deinit();
                    if (candidate.value.delegation != null) instrument_id = candidate.value.id;
                }
                if (scenario == .revoked and instrument_id != null) {
                    var current = try service.workspaceWork(scratch, parent.receipt.task, target_id);
                    defer current.deinit();
                    _ = try service.workspaceControl(scratch, "revoke-delegation", parent.receipt.task, target_id, current.value.execution_revision, current.value.control_revision, .park);
                }
            }
            const step = try service.pump(scratch);
            if (step == .work) {
                try std.testing.expect(scenario != .revoked);
                dispatches += 1;
                try std.testing.expectEqual(@as(usize, 1), dispatches);
                try std.testing.expect(step.work.subject_work != null);
                instrument_id = step.work.subject_work;
                var root = try service.task(scratch, parent.receipt.task);
                defer root.deinit();
                try std.testing.expect(!std.meta.eql(root.value.current_occurrence, step.work.occurrence));
                const wait_for_failure = scenario == .unknown_wait or scenario == .not_sent_wait or scenario == .cancel_capture;
                var waiting_revision: u64 = 0;
                if (wait_for_failure) {
                    var active_child = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                    defer active_child.deinit();
                    _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "wait-{s}", .{suffix}), parent.receipt.task, .{ .work = .{ .wait = .{
                        .works = .{ .items = &.{try workspaceRef(scratch, .work, instrument_id.?)} },
                        .after = active_child.value.event_watermark,
                    } } });
                    for (0..32) |_| {
                        const root_step = try service.pump(scratch);
                        try std.testing.expect(root_step != .work);
                        if (root_step == .idle) break;
                    }
                    var waiting_root = try service.task(scratch, parent.receipt.task);
                    defer waiting_root.deinit();
                    try std.testing.expectEqual(.parked, waiting_root.value.schedule);
                    waiting_revision = waiting_root.value.execution_revision;
                } else _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "amend-{s}", .{suffix}), parent.receipt.task, .{ .context = .{ .inspect = .{ .page = .{} } } });
                var wrong = step.work;
                wrong.subject_work = @splat(99);
                try std.testing.expectError(error.StaleOccurrence, service.acquire(scratch, wrong, ""));
                if (scenario == .unknown or scenario == .cancel_capture) {
                    var pending_child = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                    defer pending_child.deinit();
                    var guarded: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
                    _ = try service.workspaceControl(guarded.allocator(), try std.fmt.allocPrint(scratch, "cancel-{s}", .{suffix}), parent.receipt.task, instrument_id.?, pending_child.value.execution_revision, pending_child.value.control_revision, .{ .cancel = .{ .bytes = if (scenario == .unknown) "" else "cancel explicitly delegated judgment" } });
                    try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
                    try std.testing.expect(try service.shouldCancelWork(step.work));
                }
                if (scenario == .unknown) {
                    try service.unknown(scratch, step.work);
                    _ = try service.requestCancel(scratch, "cancel-parent-with-unknown-child", parent.receipt.task, "");
                } else if (scenario == .unknown_wait or scenario == .not_sent_wait) {
                    if (scenario == .unknown_wait) try service.unknown(scratch, step.work) else try service.notSent(scratch, step.work);
                    for (0..32) |_| {
                        const root_step = try service.pump(scratch);
                        try std.testing.expect(root_step != .work);
                        if (root_step == .idle) break;
                    }
                    var awakened = try service.task(scratch, parent.receipt.task);
                    defer awakened.deinit();
                    try std.testing.expect(awakened.value.execution_revision > waiting_revision);
                } else if (snapshot_mode) {
                    const worker = try native.testing.Worker.init(a, io);
                    defer worker.deinit(a) catch unreachable;
                    try worker.start(step.work, profile.authority, null);
                    while (!worker.finished()) try io.sleep(.fromMilliseconds(1), .awake);
                    try worker.join();
                    try service.completeWork(scratch, step.work, worker.result.?);
                    try worker.release();
                } else {
                    const raw = try contracts.encodeOwned(native.responses.Raw, scratch, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = "{\"output\":[{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"typed-answer\",\"name\":\"answer\",\"arguments\":\"{\\\"json_value\\\":\\\"\\\\\\\"42\\\\\\\"\\\"}\"}],\"usage\":{\"output_tokens\":7}}" } });
                    try service.acquire(scratch, step.work, if (scenario == .invalid_capture) "malformed controlled capture" else raw);
                }
            }
            var result = try service.workspaceWork(scratch, parent.receipt.task, target_id);
            defer result.deinit();
            if (scenario == .model and !resumed_handoff and instrument_id != null) {
                var completed = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                defer completed.deinit();
                if (completed.value.answer_value != null) {
                    try std.testing.expectEqual(.completed, completed.value.outcome_kind);
                    try std.testing.expectEqual(.requested, result.value.outcome_kind);
                    try service.close(scratch);
                    service_open = false;
                    try namespace.close();
                    namespace_open = false;
                    namespace = try native.Namespace.open(a, io, path);
                    namespace_open = true;
                    service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
                    service_open = true;
                    try std.testing.expectEqual(.idle, try service.pump(scratch));
                    var paused = try service.task(scratch, parent.receipt.task);
                    defer paused.deinit();
                    _ = try service.resumeTask(scratch, "resume-completed-answer", parent.receipt.task, paused.value.revision);
                    resumed_handoff = true;
                }
            }
            if (result.value.outcome_kind == .completed or (instrument_id != null and step == .idle)) break;
        }
        try std.testing.expectEqual(@as(usize, if (scenario == .revoked) 0 else 1), dispatches);
        if (scenario == .model) try std.testing.expect(resumed_handoff);
        var result = try service.workspaceWork(scratch, parent.receipt.task, target_id);
        defer result.deinit();
        var child = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
        defer child.deinit();
        if (!successful) {
            if (scenario == .unknown) {
                try std.testing.expectEqual(.cancelled, result.value.outcome_kind);
                var root = try service.task(scratch, parent.receipt.task);
                defer root.deinit();
                try std.testing.expect(root.value.terminal());
                try std.testing.expect(!try service.taskCleanupComplete(scratch, root.value));
            } else {
                try std.testing.expectEqual(.requested, result.value.outcome_kind);
                try std.testing.expectEqualDeep(target.value.current_port, result.value.current_port);
            }
            try std.testing.expect(child.value.answer_value == null);
            try std.testing.expect(!try service.associatedWorkDisposed(scratch, parent.receipt.task));
            if (scenario == .cancel_capture) {
                try std.testing.expectEqual(.cancelled, child.value.outcome_kind);
                try std.testing.expect(child.value.cancellation_applied);
            } else {
                const bytes = (try namespace.store.recordBytes(scratch, "occurrence", child.value.current_occurrence.?, parent.receipt.task)).?;
                var pending = try contracts.decodeOwned(native.testing.occurrence.Occurrence, scratch, bytes);
                defer pending.deinit();
                switch (scenario) {
                    .revoked => {
                        try std.testing.expectEqual(.ready, pending.value.state);
                        try std.testing.expectEqual(.denied, child.value.blocker.?);
                    },
                    .unknown => {
                        try std.testing.expect(pending.value.state == .unknown);
                        try std.testing.expect(try service.shutdownIncomplete(scratch));
                    },
                    .unknown_wait => try std.testing.expect(pending.value.state == .unknown),
                    .not_sent_wait => try std.testing.expect(pending.value.state == .not_sent),
                    .invalid_capture => try std.testing.expect(pending.value.state == .captured),
                    else => unreachable,
                }
            }
        } else {
            try std.testing.expectEqual(.completed, result.value.outcome_kind);
            try std.testing.expect(child.value.answer_value != null);
            var artifact = try contracts.decodeOwned(native.workspace.ValueArtifact, scratch, try namespace.store.object(scratch, child.value.answer_value.?, null));
            defer artifact.deinit();
            var derivation = try contracts.decodeOwned(native.workspace.Derivation, scratch, try namespace.store.object(scratch, artifact.value.provenance, null));
            defer derivation.deinit();
            try std.testing.expectEqual(@as(@TypeOf(derivation.value.kind), if (snapshot_mode) .acquisition else .judgment), derivation.value.kind);
            const result_bytes = try namespace.store.object(scratch, result.value.result.?, null);
            if (snapshot_mode) {
                var actual = try contracts.decodeOwned(contracts.Utf8, scratch, result_bytes);
                defer actual.deinit();
                try std.testing.expectEqualStrings(if (scenario == .snapshot_empty) "" else text, actual.value.bytes);
            } else {
                var actual = try contracts.decodeOwned(u64, scratch, result_bytes);
                defer actual.deinit();
                try std.testing.expectEqual(@as(u64, 42), actual.value);
                var root = try service.task(scratch, parent.receipt.task);
                defer root.deinit();
                try std.testing.expectEqual(@as(u64, 1), root.value.inference_attempts);
                try std.testing.expectEqual(@as(u64, 7), root.value.inference_output_tokens);
            }
        }
        if (scenario == .model) {
            // OWN-02/14: the identical typed request can be answered directly,
            // by a pure computation, or by the model above. Equal request bytes
            // do not make the two retained subjects share settlement authority.
            const direct_start = try service.workspaceStart(scratch, "answer-direct-start", parent.receipt.task, try nativeIdentity(built_reply.program.?), &.{}, .{});
            const computed_start = try service.workspaceStart(scratch, "answer-computed-start", parent.receipt.task, try nativeIdentity(built_reply.program.?), &.{}, .{});
            var direct = try service.workspaceWork(scratch, parent.receipt.task, direct_start.receipt.workspace.?);
            defer direct.deinit();
            var computed = try service.workspaceWork(scratch, parent.receipt.task, computed_start.receipt.workspace.?);
            defer computed.deinit();
            try std.testing.expect(!std.meta.eql(direct.value.current_occurrence, computed.value.current_occurrence));
            var direct_port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, direct.value.current_port.?, null));
            defer direct_port.deinit();
            var computed_port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, computed.value.current_port.?, null));
            defer computed_port.deinit();
            try std.testing.expectEqualDeep(direct_port.value.request, computed_port.value.request);
            var algorithm = source.Builder.init(a);
            defer algorithm.deinit();
            var diagnostic: native.program_construction.Diagnostic = .{};
            const pure_program = try service.workspaceBuild(scratch, "answer-pure-build", parent.receipt.task, try native.source_records.encode(scratch, try gcd(&algorithm)), &diagnostic);
            const pure_start = try service.workspaceStart(scratch, "answer-pure-start", parent.receipt.task, pure_program.receipt.workspace.?, try contracts.encodeOwned(struct { u64, u64 }, scratch, .{ 84, 42 }), .{});
            var pure = try service.workspaceWork(scratch, parent.receipt.task, pure_start.receipt.workspace.?);
            defer pure.deinit();
            try std.testing.expectEqual(.completed, pure.value.outcome_kind);
            for ([_]native.workspace.Work{ direct.value, computed.value }, [_]native.workspace.Port{ direct_port.value, computed_port.value }, 0..) |recipient, recipient_port, i| {
                const answer: contracts.workspace.ValueInput = if (i == 0) .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, recipient_port.interface.argument.digest), .json_text = .{ .bytes = "\"42\"" } } } else .{ .reference = try workspaceRef(scratch, .value, pure.value.result_value.?.digest) };
                _ = try service.workspaceInteract(scratch, if (i == 0) "answer-direct" else "answer-computed", parent.receipt.task, .{
                    .expected = .{ .work = try workspaceRef(scratch, .work, recipient.id), .execution_revision = recipient.execution_revision, .control_revision = recipient.control_revision },
                    .port = try workspaceRef(scratch, .port, recipient_port.id),
                    .generation = recipient_port.generation,
                    .command = .{ .resume_value = answer },
                });
                for (0..32) |_| {
                    _ = try service.pump(scratch);
                    var observed = try service.workspaceWork(scratch, parent.receipt.task, recipient.id);
                    defer observed.deinit();
                    if (observed.value.terminal()) break;
                }
                var answered = try service.workspaceWork(scratch, parent.receipt.task, recipient.id);
                defer answered.deinit();
                try std.testing.expectEqual(.completed, answered.value.outcome_kind);
                try std.testing.expectEqualDeep(result.value.result, answered.value.result);
                try std.testing.expect(!std.meta.eql(result.value.result_value, answered.value.result_value));
            }
            var root = try service.task(scratch, parent.receipt.task);
            defer root.deinit();
            try std.testing.expectEqual(@as(u64, 1), root.value.inference_attempts);
        }
        const archive_path = try std.fmt.allocPrint(scratch, "{s}/{s}.par", .{ path_buffer[0..length], suffix });
        _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
        const import_path = try std.fmt.allocPrint(scratch, "{s}/import-{s}", .{ path_buffer[0..length], suffix });
        try service.close(a);
        service_open = false;
        try namespace.close();
        namespace_open = false;
        {
            var imported_namespace = try native.Namespace.open(a, io, import_path);
            defer imported_namespace.close() catch unreachable;
            var imported = try native.tasks.Service(DelegateTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
            defer imported.close(a) catch unreachable;
            _ = try imported.importCheckpoint(scratch, "import", archive_path);
            try std.testing.expectEqual(.idle, try imported.pump(scratch));
            var retained = try imported.workspaceWork(scratch, parent.receipt.task, target_id);
            defer retained.deinit();
            try std.testing.expectEqualDeep(result.value.result, retained.value.result);
            var imported_child = try imported.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
            defer imported_child.deinit();
            try std.testing.expectEqualDeep(child.value, imported_child.value);
            var imported_parent = try imported.task(scratch, parent.receipt.task);
            defer imported_parent.deinit();
            try std.testing.expectEqual(@as(u64, if (scenario == .revoked or snapshot_mode) 0 else 1), imported_parent.value.inference_attempts);
        }
        namespace = try native.Namespace.open(a, io, path);
        namespace_open = true;
        service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        service_open = true;
        try std.testing.expectEqual(.idle, try service.pump(scratch));
    }
}

fn nativeIdentity(ref: contracts.workspace.Ref) ![32]u8 {
    var result: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, ref.id.bytes);
    return result;
}

fn fixtureManifest(a: std.mem.Allocator, image: []const u8, identity: [32]u8, application_bytes: []const u8) ![]u8 {
    var image_digest: [32]u8 = undefined;
    var assets_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &image_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(application_bytes, &assets_digest, .{});
    const image_hex = std.fmt.bytesToHex(image_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity, .lower);
    const assets_hex = std.fmt.bytesToHex(assets_digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{
        .native_host_contract = "unit-native-contract",
        .protocol = "agent-host/2.1",
        .client_mapping = "agent-client-values/1.1",
        .state_format = "agent-native-state/13",
        .optimize = "debug",
        .program_sha256 = @as([]const u8, &image_hex),
        .program_identity = @as([]const u8, &identity_hex),
        .application_assets_sha256 = @as([]const u8, &assets_hex),
        .dependencies = .{ .world = "unit-kosmos", .boundary = "unit-horos" },
        .compiler = .{ .version = "0.17.0" },
    }, .{});
}
