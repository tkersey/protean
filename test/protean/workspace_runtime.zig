//! Runtime selection, archive validation and bilateral workspace custody.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;
const support = @import("workspace_test_support.zig");
const workspaceRef = support.workspaceRef;
const AfterCommitAllocator = support.AfterCommitAllocator;
const compile = support.compile;
const OwnerTypes = support.OwnerTypes;
const expectContextOutputBound = support.expectContextOutputBound;
const nativeIdentity = support.nativeIdentity;
const fixtureManifest = support.fixtureManifest;
const gcd = @import("workspace_sources.zig").gcd;
const listLength = @import("workspace_sources.zig").listLength;

test "runtime selection switches exact guest cuts and retains carried artifacts through archive import" {
    var phase: []const u8 = "runtime selection and import";
    errdefer std.debug.print("runtime selection: {s}\n", .{phase});
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
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "workspace-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "workspace-unit", .manifest = manifest };
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
    var namespace_open = true;
    defer if (namespace_open) namespace.close() catch unreachable;
    var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_open = true;
    defer if (service_open) service.close(a) catch unreachable;
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
    // The request retains its receipt, not the compiler's completed proof
    // arenas. The service allocator still checks every temporary allocation.
    const specialization_request_memory = try a.alloc(u8, 1024 * 1024);
    defer a.free(specialization_request_memory);
    var specialization_request = std.heap.FixedBufferAllocator.init(specialization_request_memory);
    const specialized = try service.workspaceSpecializeWithHooks(specialization_request.allocator(), "specialize", parent.receipt.task, program.receipt.workspace.?, .{ .control = true, .storage = true });
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.checked_workspace_runtimes.get(specialized.receipt.workspace.?).?);
    try std.testing.expectEqualDeep(specialized.receipt.workspace.?, service.runtime_cache.?.artifact.identity);
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.runtime_cache.?.epoch);
    const duplicate = try service.workspaceSpecializeWithHooks(scratch, "specialize", parent.receipt.task, program.receipt.workspace.?, .{ .control = true, .storage = true });
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualDeep(specialized.receipt.workspace, duplicate.receipt.workspace);
    const alias_document = try std.fmt.allocPrint(scratch, "\n{s}\n", .{document});
    const alias_program = try service.workspaceBuild(scratch, "build-alias", parent.receipt.task, alias_document, &diagnostic);
    try std.testing.expect(!std.meta.eql(program.receipt.workspace.?, alias_program.receipt.workspace.?));
    const alias_specialized = try service.workspaceSpecializeWithHooks(scratch, "specialize-alias", parent.receipt.task, alias_program.receipt.workspace.?, .{ .control = true, .storage = true });
    try std.testing.expectEqualDeep(specialized.receipt.workspace, alias_specialized.receipt.workspace);
    var alias_observation = try contracts.decodeOwned(native.workspace.Runtime, scratch, try namespace.store.object(scratch, alias_specialized.receipt.workspace_observation.?, null));
    defer alias_observation.deinit();
    try std.testing.expectEqualDeep(program.receipt.workspace.?, alias_observation.value.program);
    const alias_command: contracts.workspace.Command = .{ .program = .{ .specialize = .{ .program = try workspaceRef(scratch, .program, alias_program.receipt.workspace.?), .hooks = .{ .control = true, .storage = true } } } };
    const alias_reply = try service.workspaceCommand(scratch, "specialize-alias", parent.receipt.task, alias_command);
    const alias_json = (try native.json.parseAsset(scratch, alias_reply.observation_json.bytes, alias_reply.observation_json.bytes.len)).value;
    try std.testing.expectEqualDeep(program.receipt.workspace.?, try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, scratch, alias_json.object.get("origin_program").?)));
    {
        try namespace.store.begin();
        defer namespace.store.rollback();
        var false_origin = alias_observation.value;
        false_origin.program = alias_program.receipt.workspace.?;
        var false_receipt = alias_specialized.receipt;
        false_receipt.workspace_observation = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.Runtime, scratch, false_origin));
        const false_body = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, false_receipt));
        try namespace.store.database.run("UPDATE operations SET receipt=? WHERE request=? AND task=?", &.{ .{ .blob = &false_body.digest }, .{ .blob = &false_receipt.request_digest }, .{ .blob = &false_receipt.task } });
        try std.testing.expectError(error.InvalidRuntime, service.workspaceCommand(scratch, "specialize-alias", parent.receipt.task, alias_command));
    }
    var previous_runtime = try service.runtime_cache.?.artifact.clone();
    defer previous_runtime.deinit();
    const previous_epoch = namespace.store.integrity_epoch;
    namespace.store.invalidateIntegrity();
    try std.testing.expectEqual(previous_epoch, service.runtime_cache.?.epoch);
    try std.testing.expectEqual(previous_epoch + 1, namespace.store.integrity_epoch);
    const runtime = try workspaceRef(scratch, .runtime, specialized.receipt.workspace.?);
    const input = try scratch.alloc(u8, 300 * 9 + 1);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const started = try service.workspaceStart(scratch, "start", parent.receipt.task, alias_program.receipt.workspace.?, input, .{});
    const id = started.receipt.workspace.?;
    var before = try service.workspaceWork(a, parent.receipt.task, id);
    defer before.deinit();
    try std.testing.expectEqualDeep(alias_program.receipt.workspace.?, before.value.program);
    try std.testing.expect(!before.value.terminal());
    const expected: contracts.workspace.Expected = .{ .work = try workspaceRef(scratch, .work, id), .execution_revision = before.value.execution_revision, .control_revision = before.value.control_revision };
    const selection: @FieldType(contracts.workspace.Work, "realize") = .{ .expected = expected, .realization_revision = 0, .runtime = .{ .selected = runtime } };
    {
        var request_arena = std.heap.ArenaAllocator.init(a);
        defer request_arena.deinit();
        var commit_guard: AfterCommitAllocator = .{ .backing = request_arena.allocator(), .namespace = &namespace, .generation = namespace.store.head.generation };
        _ = try service.workspaceRealize(commit_guard.allocator(), "select", parent.receipt.task, selection);
        try std.testing.expectEqual(@as(usize, 0), commit_guard.rejected);
    }
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.checked_workspace_runtimes.get(specialized.receipt.workspace.?).?);
    try std.testing.expectEqual(namespace.store.integrity_epoch, service.runtime_cache.?.epoch);
    try std.testing.expect(previous_runtime.core != service.runtime_cache.?.artifact.core);
    const replay = try service.workspaceRealize(scratch, "select", parent.receipt.task, selection);
    try std.testing.expect(replay.replayed);
    try std.testing.expectError(error.StaleRevision, service.workspaceRealize(scratch, "stale-select", parent.receipt.task, selection));
    var selected = try service.workspaceWork(a, parent.receipt.task, id);
    defer selected.deinit();
    try std.testing.expectEqualDeep(before.value.checkpoint, selected.value.checkpoint);
    try std.testing.expectEqual(before.value.execution_revision, selected.value.execution_revision);
    try std.testing.expectEqual(@as(u64, 1), selected.value.realization_revision);
    try std.testing.expect(selected.value.runtime != null and selected.value.runtime_capsule != null);
    {
        var different_builder = source.Builder.init(a);
        defer different_builder.deinit();
        const different_document = try native.source_records.encode(scratch, try @import("workspace_sources.zig").listLengthWithYields(&different_builder, false));
        const different = try service.workspaceBuild(scratch, "build-different-image", parent.receipt.task, different_document, &diagnostic);
        const denied = try service.workspaceCommand(scratch, "mismatched-runtime", parent.receipt.task, .{ .work = .{ .start = .{
            .program = try workspaceRef(scratch, .program, different.receipt.workspace.?),
            .input = .{ .reference = try workspaceRef(scratch, .value, before.value.input_value.?.digest) },
            .policy = .{},
            .runtime = .{ .selected = runtime },
        } } });
        try std.testing.expectEqual(.rejected, denied.disposition);
    }
    const view_command: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .guest_view = .{ .expected = .{ .work = expected.work, .execution_revision = selected.value.execution_revision, .control_revision = selected.value.control_revision }, .realization_revision = selected.value.realization_revision, .nodes = .{ .all = .{} } } },
        .sources = .{ .items = &.{} },
    } } };
    const viewed = try service.workspaceCommand(scratch, "guest-view", parent.receipt.task, view_command);
    if (viewed.disposition != .observed) std.debug.print("guest view: {s}\n", .{viewed.observation_json.bytes});
    try std.testing.expectEqual(.observed, viewed.disposition);
    const view_ref = viewed.evidence.?;
    const viewed_json = (try native.json.parseAsset(scratch, viewed.observation_json.bytes, viewed.observation_json.bytes.len)).value;
    try std.testing.expectEqualStrings("inspection", viewed_json.object.get("derivation").?.object.get("kind").?.string);
    const again = try service.workspaceCommand(scratch, "guest-view", parent.receipt.task, view_command);
    try std.testing.expectEqualDeep(view_ref, again.evidence.?);
    const view_id = try nativeIdentity(view_ref);
    var view_record = try contracts.decodeOwned(native.workspace.Value, a, (try namespace.store.recordBytes(scratch, "workspace_value", try native.workspace.custodyId(scratch, parent.receipt.task, view_id), parent.receipt.task)).?);
    defer view_record.deinit();
    const view_bytes = try namespace.store.object(scratch, view_record.value.description.value, null);
    const view_schema = try namespace.store.object(scratch, view_record.value.description.schema, null);
    var view_data = try native.dynamic_values.decode(a, view_schema, view_bytes);
    defer view_data.deinit();
    try std.testing.expect(view_data.value.array.items[1].bool);
    try std.testing.expect(view_data.value.array.items[2].array.items.len != 0);
    {
        // Rehashing a plausible snapshot does not create a journal publication.
        // Keep all ordinary content references valid while changing its revision.
        try namespace.store.begin();
        defer namespace.store.rollback();
        var forged = view_record.value;
        forged.derivation.inspection.?.observation.work.execution_revision += 1;
        forged.description.provenance = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.Derivation, scratch, forged.derivation));
        forged.artifact = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, scratch, forged.description));
        forged.id = try native.workspace.custodyId(scratch, parent.receipt.task, forged.artifact.digest);
        try namespace.store.createRecord(native.workspace.Value, "workspace_value", forged.id, parent.receipt.task, forged);
        const rejected = try service.workspaceCommand(scratch, "forged-view", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = try workspaceRef(scratch, .value, forged.artifact.digest), .page = .{} } } });
        try std.testing.expectEqual(.rejected, rejected.disposition);
    }
    {
        var partial = view_command;
        partial.context.materialize.input.guest_view.nodes = .{ .selected = .{ .items = &.{} } };
        const response = try service.workspaceCommand(scratch, "partial-view", parent.receipt.task, partial);
        try std.testing.expectEqual(.observed, response.disposition);
        const ref_id = try nativeIdentity(response.evidence.?);
        var value = try contracts.decodeOwned(native.workspace.Value, a, (try namespace.store.recordBytes(scratch, "workspace_value", try native.workspace.custodyId(scratch, parent.receipt.task, ref_id), parent.receipt.task)).?);
        defer value.deinit();
        var partial_data = try native.dynamic_values.decode(a, view_schema, try namespace.store.object(scratch, value.value.description.value, null));
        defer partial_data.deinit();
        try std.testing.expect(!partial_data.value.array.items[1].bool);
        try std.testing.expectEqual(@as(usize, 0), partial_data.value.array.items[2].array.items.len);
        try expectContextOutputBound(&service, scratch, parent.receipt.task, "guest-view", response.evidence.?, null);
        partial.context.materialize.input.guest_view.realization_revision = 0;
        const stale_view = try service.workspaceCommand(scratch, "stale-view", parent.receipt.task, partial);
        try std.testing.expectEqual(.rejected, stale_view.disposition);
        const other_parent = try service.submit(scratch, "other-view-task", .{ 25, 5 });
        const denied = try service.workspaceCommand(scratch, "foreign-view", other_parent.receipt.task, view_command);
        try std.testing.expectEqual(.rejected, denied.disposition);
        const other_program = try service.workspaceBuild(scratch, "other-build", other_parent.receipt.task, document, &diagnostic);
        const other_start = try service.workspaceStart(scratch, "other-start", other_parent.receipt.task, other_program.receipt.workspace.?, input, .{});
        var other_work = try service.workspaceWork(scratch, other_parent.receipt.task, other_start.receipt.workspace.?);
        defer other_work.deinit();
        const foreign_runtime = try service.workspaceCommand(scratch, "foreign-runtime", other_parent.receipt.task, .{ .work = .{ .realize = .{
            .expected = .{ .work = try workspaceRef(scratch, .work, other_work.value.id), .execution_revision = other_work.value.execution_revision, .control_revision = other_work.value.control_revision },
            .realization_revision = other_work.value.realization_revision,
            .runtime = .{ .selected = runtime },
        } } });
        try std.testing.expectEqual(.rejected, foreign_runtime.disposition);
    }
    {
        // Feed the acquired view to an ordinary generated query. The input
        // materialization preserves its inspection ancestry through the result.
        const query_source = try native.program_construction.runtimeQuery(scratch, true);
        const query = try service.workspaceBuild(scratch, "retention-query", parent.receipt.task, query_source, &diagnostic);
        const query_id = query.receipt.workspace.?;
        var query_program = try contracts.decodeOwned(native.workspace.Program, a, (try namespace.store.recordBytes(scratch, "workspace_program", try native.workspace.custodyId(scratch, parent.receipt.task, query_id), parent.receipt.task)).?);
        defer query_program.deinit();
        var input_json: native.json.Value = .{ .array = .init(scratch) };
        try input_json.array.append(view_data.value);
        try input_json.array.append(view_data.value.array.items[3].array.items[0].array.items[0]);
        const query_input = try service.workspaceCommand(scratch, "retention-input", parent.receipt.task, .{ .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, query_program.value.description.input_schema.digest), .json_text = .{ .bytes = try native.json.canonical(scratch, input_json) } } } },
            .sources = .{ .items = &.{view_ref} },
        } } });
        try std.testing.expectEqual(.observed, query_input.disposition);
        const query_start = try service.workspaceCommand(scratch, "run-retention", parent.receipt.task, .{ .work = .{ .start = .{ .program = try workspaceRef(scratch, .program, query_id), .input = .{ .reference = query_input.evidence.? }, .policy = .{} } } });
        try std.testing.expectEqual(.observed, query_start.disposition);
        const started_json = (try native.json.parseAsset(scratch, query_start.observation_json.bytes, query_start.observation_json.bytes.len)).value;
        const query_work_id = try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, scratch, started_json.object.get("work").?));
        var turn: usize = 0;
        while (true) : (turn += 1) {
            var current = try service.workspaceWork(a, parent.receipt.task, query_work_id);
            defer current.deinit();
            if (current.value.terminal()) {
                try std.testing.expectEqual(.completed, current.value.outcome_kind);
                var result = try native.dynamic_values.decode(a, try namespace.store.object(scratch, query_program.value.description.result_schema, null), try namespace.store.object(scratch, current.value.result.?, null));
                defer result.deinit();
                try std.testing.expectEqual(@as(u32, 0), try native.values.fromJson(u32, scratch, result.value.array.items[1]));
                try std.testing.expectEqualDeep(query_input.evidence.?, try workspaceRef(scratch, .value, current.value.input_value.?.digest));
                break;
            }
            try std.testing.expect(turn < 200);
            _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "query-turn-{d}", .{turn}), parent.receipt.task, query_work_id, current.value.execution_revision, current.value.control_revision, .advance);
        }
    }
    var after_view = try service.workspaceWork(a, parent.receipt.task, id);
    defer after_view.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, after_view.value.checkpoint);
    try std.testing.expectEqual(selected.value.execution_revision, after_view.value.execution_revision);
    try std.testing.expectEqual(selected.value.control_revision, after_view.value.control_revision);
    var traced_id: [32]u8 = undefined;
    {
        var request_arena = std.heap.ArenaAllocator.init(a);
        defer request_arena.deinit();
        const selected_start = try service.workspaceCommand(request_arena.allocator(), "selected-start", parent.receipt.task, .{ .work = .{ .start = .{
            .program = try workspaceRef(scratch, .program, alias_program.receipt.workspace.?),
            .input = .{ .reference = try workspaceRef(scratch, .value, before.value.input_value.?.digest) },
            .policy = .{},
            .runtime = .{ .selected = runtime },
        } } });
        try std.testing.expectEqual(.observed, selected_start.disposition);
        const traced_json = (try native.json.parseAsset(scratch, selected_start.observation_json.bytes, selected_start.observation_json.bytes.len)).value;
        traced_id = try nativeIdentity(try native.values.fromJson(contracts.workspace.Ref, scratch, traced_json.object.get("work").?));
        var traced = try service.workspaceWork(a, parent.receipt.task, traced_id);
        defer traced.deinit();
        try std.testing.expect(traced.value.runtime_trace != null);
        try std.testing.expect(traced.value.runtime_trace.?.output.trace.control != null);
        try std.testing.expect(traced.value.runtime_trace.?.output.trace.storage.?.node_slots > 0);
        try std.testing.expectEqualDeep(before.value.checkpoint, traced.value.checkpoint);
    }
    {
        // Rehash the false trace and its retained publication/receipt. The
        // independent observer must still reject the invented storage count.
        var manifest_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
        const archive_index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
        try namespace.store.begin();
        defer namespace.store.rollback();
        var traced = try service.workspaceWork(a, parent.receipt.task, traced_id);
        defer traced.deinit();
        traced.value.runtime_trace.?.output.trace.storage.?.node_slots += 1;
        try namespace.store.putRecord(native.workspace.Work, "workspace_work", traced_id, parent.receipt.task, traced.value);
        const observation_bytes = try contracts.encodeOwned(native.workspace.WorkObservation, scratch, .{ .work = traced.value, .occurrence = null });
        const changed_observation = try namespace.store.putObject(observation_bytes);
        var query = try namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &parent.receipt.task }, .{ .integer = @intCast(traced.value.event_watermark) } });
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        var retained = try contracts.decodeOwned(native.testing.state.Event, scratch, try query.bytes(0));
        const publications = try scratch.dupe(native.testing.state.WorkPublication, retained.value.workspace_publications.items);
        retained.value.workspace_publications.items = publications;
        for (publications) |*publication| if (std.meta.eql(publication.work, traced_id)) {
            publication.observation = changed_observation.digest;
        };
        const changed_event = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, retained.value));
        try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &changed_event.digest }, .{ .blob = &parent.receipt.task }, .{ .integer = @intCast(traced.value.event_watermark) } });
        var receipts = try namespace.store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &parent.receipt.task }});
        defer receipts.deinit();
        while (try receipts.step() == .row) {
            var receipt = try contracts.decodeOwned(native.testing.state.Receipt, scratch, try receipts.bytes(1));
            if (receipt.value.workspace_kind != .work or !std.meta.eql(receipt.value.workspace, @as(?[32]u8, traced_id))) continue;
            receipt.value.workspace_observation = changed_observation;
            const changed_receipt = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, receipt.value));
            try namespace.store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &changed_receipt.digest }, .{ .text = try receipts.bytes(0) } });
        }
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, parent.receipt.task, archive_index.records.items));
    }
    var trace_before_pump = try service.workspaceWork(a, parent.receipt.task, traced_id);
    defer trace_before_pump.deinit();
    const pump_command: @FieldType(contracts.workspace.Work, "pump") = .{
        .expected = .{ .work = try workspaceRef(scratch, .work, traced_id), .execution_revision = trace_before_pump.value.execution_revision, .control_revision = trace_before_pump.value.control_revision },
        .base_quantum = 1,
    };
    _ = try service.workspacePump(scratch, "begin-bounded", parent.receipt.task, pump_command);
    try std.testing.expect((try service.workspacePump(scratch, "begin-bounded", parent.receipt.task, pump_command)).replayed);
    var suspended = try service.workspaceWork(a, parent.receipt.task, traced_id);
    defer suspended.deinit();
    try std.testing.expect(suspended.value.outer_operation != null);
    const suspended_observation = try service.workspaceCommand(scratch, "inspect-bounded", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = pump_command.expected.work } } });
    const suspended_json = try native.json.parseAsset(scratch, suspended_observation.observation_json.bytes, suspended_observation.observation_json.bytes.len);
    try std.testing.expectEqualStrings("outer_execution", suspended_json.value.object.get("available_cut").?.string);
    try std.testing.expectEqual(trace_before_pump.value.execution_revision, suspended.value.execution_revision);
    try std.testing.expectEqualDeep(trace_before_pump.value.checkpoint, suspended.value.checkpoint);
    const suspended_expected: contracts.workspace.Expected = .{ .work = pump_command.expected.work, .execution_revision = suspended.value.execution_revision, .control_revision = suspended.value.control_revision };
    try std.testing.expectError(error.GuestCutUnavailable, service.workspaceRequestCut(scratch, "premature-guest-cut", parent.receipt.task, .{ .expected = suspended_expected, .level = .guest_cut }));
    try std.testing.expectError(error.GuestCutUnavailable, service.workspaceRealize(scratch, "premature-switch", parent.receipt.task, .{ .expected = suspended_expected, .realization_revision = suspended.value.realization_revision, .runtime = .{ .packaged = .{} } }));
    _ = try service.workspaceRequestCut(scratch, "pending-outer-cut", parent.receipt.task, .{ .expected = suspended_expected, .level = .outer_execution });
    const original_outer_bytes = try namespace.store.object(scratch, suspended.value.outer_operation.?.capsule, null);
    var original_outer = try kosmos.RuntimeCapsule.read(a, original_outer_bytes);
    defer original_outer.deinit();
    try std.testing.expectEqual(.advance, original_outer.value.record.operation.?);
    for ([_]@FieldType(@FieldType(contracts.workspace.Work, "request_cut"), "level"){ .guest_cut, .outer_execution }, 0..) |level, i| {
        var current = try service.workspaceWork(a, parent.receipt.task, id);
        defer current.deinit();
        _ = try service.workspaceRequestCut(scratch, if (i == 0) "guest-cut" else "outer-cut", parent.receipt.task, .{
            .expected = .{ .work = expected.work, .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
            .level = level,
        });
    }
    const archive_path = try std.fmt.allocPrint(scratch, "{s}/runtime.par", .{path_buffer[0..length]});
    _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
    try service.close(a);
    service_open = false;
    try namespace.close();
    namespace_open = false;
    const import_path = try std.fmt.allocPrint(scratch, "{s}/import", .{path_buffer[0..length]});
    var imported_namespace = try native.Namespace.open(a, io, import_path);
    defer imported_namespace.close() catch unreachable;
    var imported = try native.tasks.Service(OwnerTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
    defer imported.close(a) catch unreachable;
    _ = try imported.importCheckpoint(scratch, "import", archive_path);
    var restored_trace = try imported.workspaceWork(a, parent.receipt.task, traced_id);
    defer restored_trace.deinit();
    try std.testing.expect(restored_trace.value.runtime_trace != null);
    try std.testing.expect(restored_trace.value.outer_operation != null);
    try std.testing.expectEqualDeep(suspended.value.outer_operation.?.capsule, restored_trace.value.outer_operation.?.capsule);
    try std.testing.expectError(error.CustodyNotLocal, imported.workspacePump(scratch, "copy-cannot-pump", parent.receipt.task, .{ .expected = .{ .work = pump_command.expected.work, .execution_revision = restored_trace.value.execution_revision, .control_revision = restored_trace.value.control_revision }, .base_quantum = 1 }));
    try imported.close(a);
    {
        _ = try imported_namespace.store.auditRetention(handlers, application.image_identity);
        var rows = try imported_namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq", &.{.{ .blob = &parent.receipt.task }});
        defer rows.deinit();
        var source_capsule: ?native.testing.state.Reference = null;
        while (try rows.step() == .row) {
            var event = try contracts.decodeOwned(native.testing.state.Event, scratch, try rows.bytes(0));
            defer event.deinit();
            const command_ref = event.value.workspace_command orelse continue;
            var command = try contracts.decodeOwned(native.workspace.PublicationCommand, scratch, try imported_namespace.store.object(scratch, command_ref, null));
            defer command.deinit();
            if (command.value == .realize) {
                source_capsule = command.value.realize.source;
                break;
            }
        }
        const removed = source_capsule orelse return error.TestUnexpectedResult;
        try imported_namespace.store.database.run("DELETE FROM dependencies WHERE child=? OR parent=?", &.{ .{ .blob = &removed.digest }, .{ .blob = &removed.digest } });
        try imported_namespace.store.database.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &removed.digest }});
        imported_namespace.store.invalidateIntegrity();
        try std.testing.expectError(error.CorruptState, imported_namespace.store.auditRetention(handlers, application.image_identity));
    }
    try imported_namespace.close();
    imported_namespace = try native.Namespace.open(a, io, path);
    imported = try native.tasks.Service(OwnerTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
    _ = try imported.workspacePump(scratch, "resume-outer-one", parent.receipt.task, .{ .expected = .{ .work = pump_command.expected.work, .execution_revision = restored_trace.value.execution_revision, .control_revision = restored_trace.value.control_revision }, .base_quantum = 1 });
    var continued = try imported.workspaceWork(a, parent.receipt.task, traced_id);
    defer continued.deinit();
    try std.testing.expect(continued.value.outer_operation != null);
    var continued_outer = try kosmos.RuntimeCapsule.read(a, try imported_namespace.store.object(scratch, continued.value.outer_operation.?.capsule, null));
    defer continued_outer.deinit();
    try std.testing.expect(continued_outer.value.record.outer_revision > original_outer.value.record.outer_revision);
    try std.testing.expectEqual(original_outer.value.record.guest_revision, continued_outer.value.record.guest_revision);
    try std.testing.expectEqualSlices(u8, original_outer.value.command, continued_outer.value.command);
    var pump_turn: usize = 0;
    while (true) : (pump_turn += 1) {
        var current = try imported.workspaceWork(a, parent.receipt.task, traced_id);
        defer current.deinit();
        if (current.value.outer_operation == null) {
            try std.testing.expectEqual(restored_trace.value.execution_revision + 1, current.value.execution_revision);
            break;
        }
        try std.testing.expect(pump_turn < 100);
        _ = try imported.workspacePump(scratch, try std.fmt.allocPrint(scratch, "finish-outer-{d}", .{pump_turn}), parent.receipt.task, .{ .expected = .{ .work = pump_command.expected.work, .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision }, .base_quantum = 1048576 });
    }

    const imported_view = try imported.workspaceCommand(scratch, "read-imported-view", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = view_ref, .page = .{} } } });
    try std.testing.expectEqual(.observed, imported_view.disposition);
    var restored = try imported.workspaceWork(a, parent.receipt.task, id);
    defer restored.deinit();
    try std.testing.expectEqualDeep(selected.value.checkpoint, restored.value.checkpoint);
    try std.testing.expectEqualDeep(selected.value.runtime, restored.value.runtime);
    _ = try imported.workspaceRealize(scratch, "return-generic", parent.receipt.task, .{
        .expected = .{ .work = expected.work, .execution_revision = restored.value.execution_revision, .control_revision = restored.value.control_revision },
        .realization_revision = restored.value.realization_revision,
        .runtime = .{ .packaged = .{} },
    });
    var generic = try imported.workspaceWork(a, parent.receipt.task, id);
    defer generic.deinit();
    try std.testing.expectEqualDeep(before.value.checkpoint, generic.value.checkpoint);
    try std.testing.expectEqual(@as(u64, 2), generic.value.realization_revision);
    try std.testing.expect(generic.value.runtime == null);
    _ = try imported.workspaceControl(scratch, "advance-generic", parent.receipt.task, id, generic.value.execution_revision, generic.value.control_revision, .advance);
    phase = "build yielding input request";
    var question_builder = source.Builder.init(a);
    defer question_builder.deinit();
    const question_module = try @import("workspace_sources.zig").binaryQuestion(&question_builder);
    question_builder.functions.items[@intCast(question_module.entry)].body = try question_builder.term(.{ .yield_then = question_builder.functions.items[@intCast(question_module.entry)].body.? });
    const question_document = try native.source_records.encode(scratch, question_builder.module(question_module.entry, question_module.failure));
    const question_program = try imported.workspaceCommand(scratch, "pending-cancel-program", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = question_document } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .input }} } } } });
    try std.testing.expectEqual(.observed, question_program.disposition);
    phase = "start yielding input request";
    const question_started = try imported.workspaceStart(scratch, "pending-cancel-start", parent.receipt.task, try nativeIdentity(question_program.program.?), &.{}, .{});
    const question_id = question_started.receipt.workspace.?;
    const question_ref = try workspaceRef(scratch, .work, question_id);
    var yielded_question = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
    defer yielded_question.deinit();
    try std.testing.expectEqual(.yielded, yielded_question.value.outcome_kind);
    phase = "suspend input request advance";
    _ = try imported.workspacePump(scratch, "pending-cancel-begin", parent.receipt.task, .{ .expected = .{ .work = question_ref, .execution_revision = yielded_question.value.execution_revision, .control_revision = yielded_question.value.control_revision }, .base_quantum = 1 });
    var pending_question = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
    defer pending_question.deinit();
    try std.testing.expect(pending_question.value.outer_operation != null);
    phase = "cancel suspended input request advance";
    _ = try imported.workspaceControl(scratch, "pending-cancel-request", parent.receipt.task, question_id, pending_question.value.execution_revision, pending_question.value.control_revision, .{ .cancel = .{ .bytes = "stop before question" } });
    var question_cancelled = false;
    var saw_pending_question = false;
    phase = "apply pending cancellation at the requested cut";
    for (0..512) |_| {
        var current = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            question_cancelled = true;
            break;
        }
        if (current.value.outcome_kind == .requested and !current.value.cancellation_applied) {
            saw_pending_question = true;
            try std.testing.expect(current.value.current_port != null);
            try std.testing.expectEqual(.queued, current.value.schedule);
            _ = try imported.workspaceControl(scratch, "pending-cancel-explicit", parent.receipt.task, question_id, current.value.execution_revision, current.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .explicit_only } });
            var explicit = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
            defer explicit.deinit();
            try std.testing.expectEqual(.parked, explicit.value.schedule);
            _ = try imported.workspaceControl(scratch, "pending-cancel-owner", parent.receipt.task, question_id, explicit.value.execution_revision, explicit.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } });
            var delegated = try imported.workspaceWork(scratch, parent.receipt.task, question_id);
            defer delegated.deinit();
            try std.testing.expectEqual(.queued, delegated.value.schedule);
            try std.testing.expectEqualDeep(current.value.current_port, delegated.value.current_port);
            try imported.validateWorkspace(scratch, parent.receipt.task);
        }
        _ = try imported.pump(scratch);
    }
    try std.testing.expect(saw_pending_question and question_cancelled);
    phase = "export completed cancellation history";
    _ = try imported.exportCheckpoint(scratch, parent.receipt.task, try std.fmt.allocPrint(scratch, "{s}/pending-cancellation.par", .{path_buffer[0..length]}));
}

test "native placement carries a suspended evaluator with exclusive per-work custody" {
    try placementCase(.work);
}

test "native placement carries the current cut of a queued work move" {
    try placementCase(.queued);
}

test "frozen controller retains its exact cut while local work advances" {
    try placementCase(.root);
}

test "frozen controller retains cancellation and shutdown obligations after abort" {
    try placementCase(.root_cancel_abort);
}

test "frozen controller retains cancellation and shutdown obligations after refusal" {
    try placementCase(.root_cancel_refused);
}

test "controller succession precedes a frozen child's offer and follows its eventual executor" {
    try placementCase(.preoffer);
}

test "delayed controls follow executor succession and retain prior exact reports" {
    try placementCase(.onward);
}

test "terminal parent cancellation resumes after frozen work is aborted" {
    try placementCase(.cancel_abort);
}

test "terminal parent cancellation resumes after a signed refusal" {
    try placementCase(.cancel_refused);
}

fn placementCase(comptime scenario: enum { work, queued, root, preoffer, onward, cancel_abort, cancel_refused, root_cancel_abort, root_cancel_refused }) !void {
    var phase: []const u8 = "setup";
    var attack_index: usize = 0;
    errdefer std.debug.print("placement {s}: {s} ({d})\n", .{ @tagName(scenario), phase, attack_index });
    const a = std.testing.allocator;
    const io = std.testing.io;
    const p = native.placement;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    const root_module = try gcd(&root_builder);
    const root_body = root_builder.functions.items[@intCast(root_module.entry)].body.?;
    root_builder.functions.items[@intCast(root_module.entry)].body = try root_builder.term(.{ .yield_then = try root_builder.term(.{ .yield_then = root_body }) });
    if (scenario == .work) {
        var unpack = root_builder.terms.items[@intCast(root_body)].unpack_product;
        const number = try root_builder.scalar(u64);
        var delayed = try root_builder.reference(unpack.variables[0]);
        for (0..256) |_| delayed = try root_builder.primitive(number, .integer_bit_xor, &.{ delayed, try root_builder.constant(u64, 1) }, 0);
        unpack.body = try root_builder.bind(try root_builder.variable(number), try root_builder.pure(delayed), try root_builder.term(.{ .yield_then = try root_builder.term(.{ .yield_then = unpack.body }) }));
        root_builder.functions.items[@intCast(root_module.entry)].body = try root_builder.term(.{ .unpack_product = unpack });
    }
    var root = try compile(a, &root_builder, root_builder.module(root_module.entry, root_module.failure));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "placement-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, root.image, admitted.identity(), "placement-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "placement-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "placement-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.setPermissions(io, .fromMode(0o700));
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_path = try std.fmt.allocPrint(scratch, "{s}/source", .{path_buffer[0..length]});
    const destination_path = try std.fmt.allocPrint(scratch, "{s}/destination", .{path_buffer[0..length]});
    const successor_path = try std.fmt.allocPrint(scratch, "{s}/successor", .{path_buffer[0..length]});
    var untrusted_namespaces: [3]@FieldType(p.Site, "namespace") = undefined;
    if (scenario == .work) for (&untrusted_namespaces, 0..) |*identity, attack| {
        var empty = try native.Namespace.open(a, io, try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}", .{ path_buffer[0..length], attack }));
        identity.* = empty.identity;
        try empty.close();
    };
    var successor_namespace = try native.Namespace.open(a, io, successor_path);
    const successor_identity = successor_namespace.identity;
    try successor_namespace.close();
    var destination_namespace = try native.Namespace.open(a, io, destination_path);
    const destination_identity = destination_namespace.identity;
    try destination_namespace.close();
    var destination_open = false;
    defer if (destination_open) destination_namespace.close() catch unreachable;
    var source_namespace = try native.Namespace.open(a, io, source_path);
    var source_open = true;
    defer if (source_open) source_namespace.close() catch unreachable;
    var sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, profile);
    var sender_open = true;
    defer if (sender_open) sender.close(a) catch unreachable;
    var receiver: native.tasks.Service(OwnerTypes) = undefined;
    var receiver_open = false;
    defer if (receiver_open) receiver.close(a) catch unreachable;
    const parent = try sender.submit(scratch, "parent", .{ 25, 5 });
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    const specialized = try sender.workspaceSpecialize(scratch, "specialize", parent.receipt.task, program.receipt.workspace.?);
    const runtime = try workspaceRef(scratch, .runtime, specialized.receipt.workspace.?);
    const input = try scratch.alloc(u8, 64 * 9 + 1);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..64) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    var program_record = try sender.workspaceProgram(a, parent.receipt.task, program.receipt.workspace.?);
    defer program_record.deinit();
    const input_schema = program_record.value.description.input_schema;
    var input_value = try native.dynamic_values.decode(a, try source_namespace.store.object(scratch, input_schema, null), input);
    defer input_value.deinit();
    const start_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = try workspaceRef(scratch, .program, program.receipt.workspace.?),
        .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, input_schema.digest), .json_text = .{ .bytes = try native.json.canonical(scratch, input_value.value) } } },
        .policy = if (scenario == .root) .{ .stop = .terminal, .continuation = .owner_scheduled } else .{},
        .runtime = .{ .selected = runtime },
    } } };
    const started = try sender.workspaceCommand(scratch, "start", parent.receipt.task, start_command);
    try std.testing.expectEqual(.observed, started.disposition);
    const start_observation = (try native.json.parseAsset(scratch, started.observation_json.bytes, started.observation_json.bytes.len)).value;
    const work_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, start_observation.object.get("work").?);
    const work_id = try nativeIdentity(work_ref);
    var work = try sender.workspaceWork(a, parent.receipt.task, work_id);
    defer work.deinit();
    try std.testing.expect(!work.value.terminal());
    _ = try sender.workspacePump(scratch, "begin-outer", parent.receipt.task, .{ .expected = .{ .work = work_ref, .execution_revision = work.value.execution_revision, .control_revision = work.value.control_revision }, .base_quantum = 1 });
    const subject: p.Subject = .{ .task = parent.receipt.task, .work = work_id };
    const cut = try sender.placementCut(scratch, subject);
    try std.testing.expect(cut.outer != null);
    const compatibility = try sender.placementCompatibility(scratch, subject);
    const resources = try profile.resourceIdentity(scratch, application.image_identity);
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(11));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(12));
    const successor_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(15));
    const source_site: p.Site = .{ .key = source_key.public_key.toBytes(), .namespace = source_namespace.identity };
    const destination_site: p.Site = .{ .key = destination_key.public_key.toBytes(), .namespace = destination_identity };
    const successor_site: p.Site = .{ .key = successor_key.public_key.toBytes(), .namespace = successor_identity };
    const Disclosure = struct {
        runtime: [32]u8,
        saw_runtime: bool = false,
        deny_runtime: bool = false,
        fn check(context: *anyopaque, _: p.Subject, objects: []const native.testing.state.Reference) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (objects) |object| if (std.meta.eql(object.digest, self.runtime)) {
                self.saw_runtime = true;
                if (self.deny_runtime) return error.DisclosureDenied;
            };
        }
    };
    var disclosure: Disclosure = .{ .runtime = specialized.receipt.workspace.? };
    const successor_peer: p.Peer = .{ .name = "successor", .site = successor_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(13), .context = &disclosure, .disclose = Disclosure.check };
    var source_peers = [_]p.Peer{ .{ .name = "destination", .site = destination_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(13), .context = &disclosure, .disclose = Disclosure.check }, successor_peer };
    var destination_peers = [_]p.Peer{ .{ .name = "source", .site = source_site, .native_build = profile.runtime_identity, .compatibility = compatibility, .resource_binding = resources, .disclosure_policy = @splat(13), .context = &disclosure, .disclose = Disclosure.check }, successor_peer };
    var successor_peers = [_]p.Peer{ source_peers[0], destination_peers[0] };
    const source_config: p.Configuration = .{ .signing_key = source_key, .peers = &source_peers, .transport_directory = path_buffer[0..length] };
    const destination_config: p.Configuration = .{ .signing_key = destination_key, .peers = &destination_peers };
    const successor_config: p.Configuration = .{ .signing_key = successor_key, .peers = &successor_peers };
    sender.profile.placement = &source_config;
    if (scenario == .root_cancel_abort or scenario == .root_cancel_refused) {
        phase = "settle local child while cancelling controller is frozen";
        const controller: p.Subject = .{ .task = subject.task };
        _ = try sender.requestCancel(scratch, "cancel-controller", subject.task, "stop");
        _ = try sender.placementFreeze(scratch, controller, "destination", try sender.placementCut(scratch, controller), @splat(71));
        var refusal: ?p.Signed(p.Decision) = null;
        if (scenario == .root_cancel_refused) {
            const frozen_path = try std.fmt.allocPrint(scratch, "{s}/cancelled-controller.par", .{path_buffer[0..length]});
            const frozen_offer = try sender.placementOffer(scratch, controller, "destination", frozen_path);
            refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = frozen_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, frozen_offer.value), .source = source_site, .destination = destination_site, .epoch = frozen_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
        }
        _ = try sender.workspaceControl(scratch, "settle-controller-child", subject.task, work_id, cut.execution, cut.control, .{ .cancel = .{ .bytes = "stop" } });
        var child_disposed = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.workspaceWork(scratch, subject.task, work_id);
            defer current.deinit();
            if (current.value.terminal()) {
                try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                child_disposed = true;
                break;
            }
        }
        try std.testing.expect(child_disposed);
        try std.testing.expectEqual(.frozen, (try sender.placementStatus(scratch, controller)).?.phase);
        try std.testing.expectEqual(@as(usize, 1), sender.owned.items.len);
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        if (refusal) |decision| try sender.placementApplyDecision(scratch, controller, decision) else try sender.placementAbortUnsent(scratch, controller, @splat(71));
        var root_disposed = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.task(scratch, subject.task);
            defer current.deinit();
            if (try sender.taskCleanupComplete(scratch, current.value)) {
                try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                root_disposed = true;
                break;
            }
        }
        try std.testing.expect(root_disposed);
        try std.testing.expect(!try sender.shutdownIncomplete(scratch));
        phase = "cancel shutdown observes a restored uncancelled controller";
        const shutdown_root = try sender.submit(scratch, "shutdown-controller", .{ 25, 5 });
        const shutdown_subject: p.Subject = .{ .task = shutdown_root.receipt.task };
        _ = try sender.placementFreeze(scratch, shutdown_subject, "destination", try sender.placementCut(scratch, shutdown_subject), @splat(72));
        refusal = null;
        if (scenario == .root_cancel_refused) {
            const frozen_path = try std.fmt.allocPrint(scratch, "{s}/shutdown-controller.par", .{path_buffer[0..length]});
            const frozen_offer = try sender.placementOffer(scratch, shutdown_subject, "destination", frozen_path);
            refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = frozen_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, frozen_offer.value), .source = source_site, .destination = destination_site, .epoch = frozen_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
        }
        try sender.cancelOwned(scratch, "shutdown-probe", "stop");
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        if (refusal) |decision| try sender.placementApplyDecision(scratch, shutdown_subject, decision) else try sender.placementAbortUnsent(scratch, shutdown_subject, @splat(72));
        try sender.park(scratch);
        var parked = try sender.task(scratch, shutdown_subject.task);
        defer parked.deinit();
        try std.testing.expect(!parked.value.terminal());
        try std.testing.expect(parked.value.cancellation == null);
        try std.testing.expectEqual(.parked, parked.value.schedule);
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        return;
    }
    if (scenario == .queued) {
        source_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "source" };
        const queued_move = try sender.workspaceCommand(scratch, "queue-before-progress", subject.task, .{ .placement = .{ .move = .{ .operation = .{ .bytes = "queued-work" }, .subject = .{ .work = work_ref }, .site = .{ .bytes = "destination" }, .custody_epoch = 0 } } });
        try std.testing.expectEqual(.observed, queued_move.disposition);
        inline for (.{ "principal", "tenant" }) |field| {
            const authority = sender.profile.authority;
            defer sender.profile.authority = authority;
            const before = source_namespace.store.head;
            const pending_before = try scratch.dupe(@TypeOf(sender.placement_pending.items[0]), sender.placement_pending.items);
            @field(sender.profile.authority, field) = "foreign";
            try std.testing.expectError(error.Denied, sender.placementWithdraw(scratch, subject.task, p.operationId(source_site, subject.task, "queued-work", .move)));
            try std.testing.expectEqualDeep(before, source_namespace.store.head);
            try std.testing.expectEqualDeep(pending_before, sender.placement_pending.items);
            try std.testing.expect(sender.placement_job == null);
        }
        _ = try sender.workspacePump(scratch, "queued-work-progress", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control }, .base_quantum = 1 });
        const progressed_cut = try sender.placementCut(scratch, subject);
        try std.testing.expect(!std.meta.eql(cut, progressed_cut));
        try std.testing.expectEqual(.progressed, try sender.pump(scratch));
        const frozen = (try sender.placementStatus(scratch, subject)).?;
        try std.testing.expectEqual(.frozen, frozen.phase);
        try std.testing.expectEqualDeep(progressed_cut, frozen.intent.?.cut);
        try std.testing.expect(sender.placementActive());
        return;
    }
    if (scenario == .cancel_abort or scenario == .cancel_refused) {
        var cleanup_builder = source.Builder.init(a);
        defer cleanup_builder.deinit();
        const cleanup_document = try native.source_records.encode(scratch, try @import("workspace_sources.zig").yieldingCancellation(&cleanup_builder));
        const cleanup_program = try sender.workspaceBuild(scratch, "restored-cleanup-program", subject.task, cleanup_document, &diagnostic);
        try sender.park(scratch);
        for (0..2) |parked| {
            phase = "admit child cancellation before freeze";
            const operation = try std.fmt.allocPrint(scratch, "child-cleanup-{d}", .{parked});
            const child = try sender.workspaceStart(scratch, operation, subject.task, cleanup_program.receipt.workspace.?, &.{}, .{});
            const child_id = child.receipt.workspace.?;
            var initial = try sender.workspaceWork(scratch, subject.task, child_id);
            defer initial.deinit();
            _ = try sender.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "{s}-cancel", .{operation}), subject.task, child_id, initial.value.execution_revision, initial.value.control_revision, .{ .cancel = .{ .bytes = "stop" } });
            var cancelling = try sender.workspaceWork(scratch, subject.task, child_id);
            defer cancelling.deinit();
            try std.testing.expect(!cancelling.value.terminal());
            try std.testing.expectEqual(.queued, cancelling.value.schedule);
            if (parked == 1) _ = try sender.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "{s}-park", .{operation}), subject.task, child_id, cancelling.value.execution_revision, cancelling.value.control_revision, .park);
            const child_subject: p.Subject = .{ .task = subject.task, .work = child_id };
            const transfer: [32]u8 = @splat(@intCast(90 + parked));
            _ = try sender.placementFreeze(scratch, child_subject, "destination", try sender.placementCut(scratch, child_subject), transfer);
            var refusal: ?p.Signed(p.Decision) = null;
            if (scenario == .cancel_refused) {
                const child_archive = try std.fmt.allocPrint(scratch, "{s}/{s}.par", .{ path_buffer[0..length], operation });
                const child_offer = try sender.placementOffer(scratch, child_subject, "destination", child_archive);
                refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = transfer, .offer_digest = try p.digest(p.Offer, scratch, child_offer.value), .source = source_site, .destination = destination_site, .epoch = child_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
            }
            if (refusal) |decision| try sender.placementApplyDecision(scratch, child_subject, decision) else try sender.placementAbortUnsent(scratch, child_subject, transfer);
            if (parked == 1) {
                for (0..4) |_| _ = try sender.pump(scratch);
                var still = try sender.workspaceWork(scratch, subject.task, child_id);
                defer still.deinit();
                try std.testing.expect(!still.value.terminal());
                try std.testing.expectEqual(.parked, still.value.schedule);
                _ = try sender.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "{s}-resume", .{operation}), subject.task, child_id, still.value.execution_revision, still.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } });
            }
            var child_disposed = false;
            for (0..512) |_| {
                _ = try sender.pump(scratch);
                var current = try sender.workspaceWork(scratch, subject.task, child_id);
                defer current.deinit();
                if (current.value.terminal()) {
                    try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                    child_disposed = true;
                    break;
                }
            }
            phase = "cancelled child restored to local custody";
            try std.testing.expect(child_disposed);
        }
        for (0..2) |parked| {
            const operation = try std.fmt.allocPrint(scratch, "root-cleanup-{d}", .{parked});
            const cancelled_root = try sender.submit(scratch, operation, .{ 25, 5 });
            const root_subject: p.Subject = .{ .task = cancelled_root.receipt.task };
            _ = try sender.requestCancel(scratch, try std.fmt.allocPrint(scratch, "{s}-cancel", .{operation}), root_subject.task, "stop");
            const root_cut = try sender.placementCut(scratch, root_subject);
            const transfer: [32]u8 = @splat(@intCast(80 + parked));
            _ = try sender.placementFreeze(scratch, root_subject, "destination", root_cut, transfer);
            var refusal: ?p.Signed(p.Decision) = null;
            if (scenario == .cancel_refused) {
                const root_archive = try std.fmt.allocPrint(scratch, "{s}/{s}.par", .{ path_buffer[0..length], operation });
                const root_offer = try sender.placementOffer(scratch, root_subject, "destination", root_archive);
                refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = transfer, .offer_digest = try p.digest(p.Offer, scratch, root_offer.value), .source = source_site, .destination = destination_site, .epoch = root_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
            }
            if (parked == 1) try sender.park(scratch);
            if (refusal) |decision| try sender.placementApplyDecision(scratch, root_subject, decision) else try sender.placementAbortUnsent(scratch, root_subject, transfer);
            if (parked == 1) {
                for (0..4) |_| _ = try sender.pump(scratch);
                var still = try sender.task(scratch, root_subject.task);
                defer still.deinit();
                try std.testing.expect(!still.value.terminal());
                try std.testing.expectEqual(.parked, still.value.schedule);
                _ = try sender.requestCancel(scratch, try std.fmt.allocPrint(scratch, "{s}-recancel", .{operation}), root_subject.task, "stop");
            }
            var root_disposed = false;
            for (0..512) |_| {
                _ = try sender.pump(scratch);
                var current = try sender.task(scratch, root_subject.task);
                defer current.deinit();
                if (current.value.terminal()) {
                    try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
                    root_disposed = true;
                    break;
                }
            }
            try std.testing.expect(root_disposed);
        }
    }
    const identified = try sender.placementRequest(scratch, .{ .identify = .{} });
    try std.testing.expect(identified == .object);
    const sites = try sender.workspaceCommand(scratch, "placement-sites", subject.task, .{ .placement = .{ .sites = .{} } });
    try std.testing.expectEqual(.observed, sites.disposition);
    const sites_head = source_namespace.store.head;
    const sites_replay = try sender.workspaceCommand(scratch, "placement-sites", subject.task, .{ .placement = .{ .sites = .{} } });
    try std.testing.expectEqualStrings(sites.observation_json.bytes, sites_replay.observation_json.bytes);
    try std.testing.expectEqualDeep(sites_head, source_namespace.store.head);
    // Withdrawal before publication closes the queued move without transferring
    // authority or leaving an unsettled record that blocks later root movement.
    source_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "source" };
    const queued = try sender.workspaceCommand(scratch, "placement-queue", subject.task, .{ .placement = .{ .move = .{ .operation = .{ .bytes = "withdraw-before-send" }, .subject = .{ .work = work_ref }, .site = .{ .bytes = "destination" }, .custody_epoch = 0 } } });
    if (queued.disposition != .observed) std.debug.print("placement queue rejection: {s}\n", .{queued.observation_json.bytes});
    try std.testing.expectEqual(.observed, queued.disposition);
    const withdrawn = try sender.workspaceCommand(scratch, "placement-withdraw", subject.task, .{ .placement = .{ .withdraw = .{ .operation = .{ .bytes = "withdraw-before-send" } } } });
    try std.testing.expectEqual(.observed, withdrawn.disposition);
    const withdrawn_state = try native.values.fromJson(p.Move, scratch, (try native.json.parseAsset(scratch, withdrawn.observation_json.bytes, withdrawn.observation_json.bytes.len)).value);
    try std.testing.expect(withdrawn_state.cancelled);
    try std.testing.expect(withdrawn_state.withdraw_requested);
    try std.testing.expect(withdrawn_state.decision == null);
    const retry_withdrawn = try sender.workspaceCommand(scratch, "placement-retry-withdrawn", subject.task, .{ .placement = .{ .retry = .{ .operation = .{ .bytes = "withdraw-before-send" } } } });
    try std.testing.expectEqual(.observed, retry_withdrawn.disposition);
    source_peers[0].channel = null;
    if (scenario == .root or scenario == .preoffer) {
        if (scenario == .preoffer) _ = try sender.placementFreeze(scratch, subject, "destination", cut, @splat(14));
        const controller: p.Subject = .{ .task = subject.task };
        const controller_cut = try sender.placementCut(scratch, controller);
        _ = try sender.placementFreeze(scratch, controller, "successor", controller_cut, @splat(98));
        const frozen_head = source_namespace.store.head;
        const frozen_runnable = try scratch.dupe(native.workspace.Subject, sender.runnable.items);
        const replayed_build = try sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
        try std.testing.expect(replayed_build.replayed);
        try std.testing.expectEqualDeep(program.receipt, replayed_build.receipt);
        const replayed_specialization = try sender.workspaceSpecialize(scratch, "specialize", parent.receipt.task, program.receipt.workspace.?);
        try std.testing.expect(replayed_specialization.replayed);
        try std.testing.expectEqualDeep(specialized.receipt, replayed_specialization.receipt);
        const replayed_start = try sender.workspaceCommand(scratch, "start", parent.receipt.task, start_command);
        try std.testing.expectEqual(.observed, replayed_start.disposition);
        const replayed_start_value = (try native.json.parseAsset(scratch, replayed_start.observation_json.bytes, replayed_start.observation_json.bytes.len)).value;
        try std.testing.expect(replayed_start_value.object.get("replayed").?.bool);
        try std.testing.expectEqualDeep(work_ref, try native.values.fromJson(contracts.workspace.Ref, scratch, replayed_start_value.object.get("work").?));
        const replayed_sites = try sender.workspaceCommand(scratch, "placement-sites", subject.task, .{ .placement = .{ .sites = .{} } });
        try std.testing.expectEqual(.observed, replayed_sites.disposition);
        try std.testing.expectEqualStrings(sites.observation_json.bytes, replayed_sites.observation_json.bytes);
        try std.testing.expectError(error.CustodyNotLocal, sender.workspaceBuild(scratch, "frozen-new-build", parent.receipt.task, document, &diagnostic));
        try std.testing.expectError(error.CustodyNotLocal, sender.workspaceSpecialize(scratch, "frozen-new-specialization", parent.receipt.task, program.receipt.workspace.?));
        try std.testing.expectEqual(.rejected, (try sender.workspaceCommand(scratch, "frozen-new-start", parent.receipt.task, start_command)).disposition);
        try std.testing.expectEqual(.rejected, (try sender.workspaceCommand(scratch, "frozen-new-sites", subject.task, .{ .placement = .{ .sites = .{} } })).disposition);
        try std.testing.expectError(error.OperationConflict, sender.workspaceBuild(scratch, "build", parent.receipt.task, try std.fmt.allocPrint(scratch, "\n{s}", .{document}), &diagnostic));
        {
            const authority = sender.profile.authority;
            defer sender.profile.authority = authority;
            sender.profile.authority.disclosure = false;
            try std.testing.expectError(error.Denied, sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic));
            sender.profile.authority = authority;
            sender.profile.authority.revoked = true;
            try std.testing.expectError(error.Denied, sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic));
            sender.profile.authority = authority;
            sender.profile.authority.principal = "other";
            try std.testing.expectError(error.Denied, sender.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic));
        }
        try std.testing.expectEqualDeep(frozen_head, source_namespace.store.head);
        try std.testing.expectEqualDeep(frozen_runnable, sender.runnable.items);
        try std.testing.expectEqualDeep(controller_cut, try sender.placementCut(scratch, controller));
        if (scenario == .root) _ = try sender.workspacePump(scratch, "independent-local-progress", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control }, .base_quantum = 1 });
        var progressed_parent = try sender.task(scratch, subject.task);
        defer progressed_parent.deinit();
        if (scenario == .root) try std.testing.expect(progressed_parent.value.revision > controller_cut.control);
        const snapshot_path = try std.fmt.allocPrint(scratch, "{s}/frozen-controller.par", .{path_buffer[0..length]});
        const snapshot_offer = try sender.placementOffer(scratch, controller, "successor", snapshot_path);
        try std.testing.expectEqualDeep(controller_cut, snapshot_offer.value.intent.cut);
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        {
            const copy_path = try std.fmt.allocPrint(scratch, "{s}/foreign-frozen-copy", .{path_buffer[0..length]});
            var copy_namespace = try native.Namespace.open(a, io, copy_path);
            defer copy_namespace.close() catch unreachable;
            var copy_profile = profile;
            // A copied namespace can share the signing key without sharing
            // the source namespace's actual custody or export obligation.
            copy_profile.placement = &source_config;
            var copied = try native.tasks.Service(OwnerTypes).init(a, io, &copy_namespace, assets, &application, handlers, copy_profile);
            defer copied.close(a) catch unreachable;
            _ = try copied.importCheckpoint(scratch, "copy-frozen", snapshot_path);
            const copied_head = copy_namespace.store.head;
            const copied_receipt = try copied.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
            try std.testing.expect(copied_receipt.replayed);
            try std.testing.expectEqualDeep(program.receipt, copied_receipt.receipt);
            try std.testing.expectError(error.CustodyNotLocal, copied.workspaceBuild(scratch, "copied-new-build", parent.receipt.task, document, &diagnostic));
            try std.testing.expectEqualDeep(copied_head, copy_namespace.store.head);
            try std.testing.expectError(error.InvalidTransfer, copied.placementOffer(scratch, controller, "successor", snapshot_path));
        }
        var snapshot_namespace = try native.Namespace.open(a, io, successor_path);
        var snapshot_profile = profile;
        snapshot_profile.placement = &successor_config;
        var snapshot_receiver = try native.tasks.Service(OwnerTypes).init(a, io, &snapshot_namespace, assets, &application, handlers, snapshot_profile);
        const decision = try snapshot_receiver.placementAccept(scratch, "accept-frozen-controller", "source", snapshot_offer, snapshot_path);
        try std.testing.expectEqual(.local, (try snapshot_receiver.placementStatus(scratch, controller)).?.phase);
        try std.testing.expectEqual(.away, (try snapshot_receiver.placementStatus(scratch, subject)).?.phase);
        try snapshot_receiver.close(a);
        try snapshot_namespace.close();
        source_namespace = try native.Namespace.open(a, io, source_path);
        source_open = true;
        var source_profile = profile;
        source_profile.placement = &source_config;
        sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
        sender_open = true;
        try sender.placementApplyDecision(scratch, controller, decision);
        try std.testing.expectEqual(@as(@FieldType(p.Custody, "phase"), if (scenario == .root) .local else .frozen), (try sender.placementStatus(scratch, subject)).?.phase);
        if (scenario == .root) {
            phase = "normal controller completion parks the retained executor";
            var running_child = try sender.workspaceWork(scratch, subject.task, work_id);
            defer running_child.deinit();
            try std.testing.expectEqual(.queued, running_child.value.schedule);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            successor_peers[1].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "successor" };
            var completed = false;
            var parked = false;
            var incomplete_park = false;
            var refreshed_park = false;
            var inspection_reports: u64 = 0;
            var parked_task_watermark: u64 = 0;
            var prior_command: ?p.Signed(p.Control) = null;
            var prior_report: ?p.Signed(p.Report) = null;
            for (0..8) |_| {
                var selected_command: p.Signed(p.Control) = undefined;
                {
                    var closing_namespace = try native.Namespace.open(a, io, successor_path);
                    defer closing_namespace.close() catch unreachable;
                    var closing_controller = try native.tasks.Service(OwnerTypes).init(a, io, &closing_namespace, assets, &application, handlers, snapshot_profile);
                    defer closing_controller.close(a) catch unreachable;
                    phase = "apply remote close report";
                    if (prior_report) |reported| try closing_controller.placementApplyReport(scratch, subject.task, p.controlId(prior_command.?.value), reported);
                    if (!completed) {
                        for (0..512) |turn| {
                            var current = try closing_controller.task(scratch, subject.task);
                            defer current.deinit();
                            if (current.value.terminal()) {
                                try std.testing.expectEqual(.completed, current.value.outcome_kind);
                                try std.testing.expect(current.value.cancellation == null);
                                completed = true;
                                break;
                            }
                            if (current.value.schedule == .parked) _ = try closing_controller.resumeTask(scratch, try std.fmt.allocPrint(scratch, "complete-controller-{d}", .{turn}), subject.task, current.value.revision);
                            _ = try closing_controller.pump(scratch);
                        }
                        try std.testing.expect(completed);
                        try std.testing.expect(try closing_controller.shutdownIncomplete(scratch));
                    }
                    if (parked) {
                        phase = "settled remote park is quiescent";
                        try std.testing.expect(!try closing_controller.shutdownIncomplete(scratch));
                        _ = try closing_controller.pump(scratch);
                        var pending = try closing_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
                        defer pending.deinit();
                        while (try pending.step() == .row) {
                            var saved = try contracts.decodeOwned(p.ControlRecord, scratch, try pending.bytes(0));
                            defer saved.deinit();
                            try std.testing.expect(saved.value.report != null);
                        }
                        break;
                    }
                    phase = "refresh incomplete remote park";
                    if (incomplete_park) try std.testing.expect(try closing_controller.shutdownIncomplete(scratch));
                    _ = try closing_controller.pump(scratch);
                    var query = try closing_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
                    defer query.deinit();
                    var found = false;
                    while (try query.step() == .row) {
                        const saved = try contracts.decodeOwned(p.ControlRecord, scratch, try query.bytes(0));
                        if (saved.value.report == null) {
                            selected_command = saved.value.control;
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);
                    if (incomplete_park) try std.testing.expectEqual(.inspect, std.meta.activeTag(selected_command.value.command));
                }
                {
                    var executor_namespace = try native.Namespace.open(a, io, source_path);
                    defer executor_namespace.close() catch unreachable;
                    var closing_executor = try native.tasks.Service(OwnerTypes).init(a, io, &executor_namespace, assets, &application, handlers, source_profile);
                    defer closing_executor.close(a) catch unreachable;
                    phase = "execute remote close observation";
                    const result = try contracts.decodeOwned(p.Signed(p.Report), scratch, try closing_executor.placementExecuteControl(scratch, "successor", selected_command));
                    try std.testing.expectEqual(.observed, result.value.value.reply.disposition);
                    if (prior_report) |previous| try std.testing.expect(result.value.value.work_state.?.observed_at > previous.value.work_state.?.observed_at);
                    prior_report = result.value;
                    prior_command = selected_command;
                    if (selected_command.value.command == .park) {
                        try std.testing.expect(result.value.value.work_state.?.park_complete);
                        var parked_child = try closing_executor.workspaceWork(scratch, subject.task, work_id);
                        defer parked_child.deinit();
                        try std.testing.expectEqual(.parked, parked_child.value.schedule);
                        try std.testing.expect(parked_child.value.cancellation == null);
                        var incomplete = result.value.value;
                        incomplete.work_state.?.park_complete = false;
                        prior_report = try p.sign(p.Report, scratch, source_key, incomplete);
                        _ = try closing_executor.workspaceControl(scratch, "later-explicit-park", subject.task, work_id, parked_child.value.execution_revision, parked_child.value.control_revision, .park);
                        const later = try closing_executor.placementCut(scratch, subject);
                        try std.testing.expectEqual(parked_child.value.execution_revision, later.execution);
                        try std.testing.expectEqual(parked_child.value.control_revision + 1, later.control);
                        var observed_parent = try closing_executor.task(scratch, subject.task);
                        defer observed_parent.deinit();
                        parked_task_watermark = observed_parent.value.event_high;
                        incomplete_park = true;
                    } else if (incomplete_park) {
                        try std.testing.expect(result.value.value.work_state.?.parkSettled());
                        try std.testing.expectEqualDeep(work_ref, prior_command.?.value.command.inspect.work);
                        var observed_parent = try closing_executor.task(scratch, subject.task);
                        defer observed_parent.deinit();
                        try std.testing.expectEqual(parked_task_watermark, observed_parent.value.event_high);
                        inspection_reports += 1;
                        if (inspection_reports < 3) {
                            var incomplete = result.value.value;
                            incomplete.work_state.?.park_complete = false;
                            prior_report = try p.sign(p.Report, scratch, source_key, incomplete);
                        } else {
                            parked = true;
                            refreshed_park = true;
                        }
                    }
                }
            }
            try std.testing.expect(completed and parked and incomplete_park and refreshed_park);
            try std.testing.expectEqual(@as(u64, 3), inspection_reports);
            const last = prior_report.?.value.work_state.?;
            const expected: contracts.workspace.Expected = .{ .work = work_ref, .execution_revision = last.execution_revision, .control_revision = last.control_revision };
            const stopped_commands = [_]contracts.workspace.Work{
                .{ .advance = expected },
                .{ .delegate = .{ .expected = expected, .policy = .{} } },
                .{ .pump = .{ .expected = expected, .base_quantum = 1 } },
                .{ .request_cut = .{ .expected = expected, .level = .outer_execution } },
                .{ .realize = .{ .expected = expected, .realization_revision = running_child.value.realization_revision, .runtime = .{ .packaged = .{} } } },
            };
            var stopped_controls: [stopped_commands.len]p.Signed(p.Control) = undefined;
            {
                var closing_namespace = try native.Namespace.open(a, io, successor_path);
                defer closing_namespace.close() catch unreachable;
                var closing_controller = try native.tasks.Service(OwnerTypes).init(a, io, &closing_namespace, assets, &application, handlers, snapshot_profile);
                defer closing_controller.close(a) catch unreachable;
                var terminal_parent = try closing_controller.task(scratch, subject.task);
                defer terminal_parent.deinit();
                try std.testing.expect(terminal_parent.value.terminal());
                for (stopped_commands, &stopped_controls, 0..) |command, *signed, index| {
                    const operation_name = try std.fmt.allocPrint(scratch, "after-parent-completion-{d}", .{index});
                    const bytes = try closing_controller.placementControl(scratch, operation_name, subject.task, command);
                    const decoded = try contracts.decodeOwned(p.Signed(p.Control), scratch, bytes);
                    signed.* = decoded.value;
                    try std.testing.expect(signed.value.parent_stopped);
                    try std.testing.expectEqualSlices(u8, bytes, try closing_controller.placementControl(scratch, operation_name, subject.task, command));
                }
            }
            {
                var executor_namespace = try native.Namespace.open(a, io, source_path);
                defer executor_namespace.close() catch unreachable;
                var closing_executor = try native.tasks.Service(OwnerTypes).init(a, io, &executor_namespace, assets, &application, handlers, source_profile);
                defer closing_executor.close(a) catch unreachable;
                var retained_parent = try closing_executor.task(scratch, subject.task);
                defer retained_parent.deinit();
                try std.testing.expect(!retained_parent.value.terminal());
                const before = try closing_executor.placementCut(scratch, subject);
                for (stopped_controls) |control_value| {
                    const bytes = try closing_executor.placementExecuteControl(scratch, "successor", control_value);
                    const rejected = try contracts.decodeOwned(p.Signed(p.Report), scratch, bytes);
                    try std.testing.expectEqual(.rejected, rejected.value.value.reply.disposition);
                    const observation = (try native.json.parseAsset(scratch, rejected.value.value.reply.observation_json.bytes, rejected.value.value.reply.observation_json.bytes.len)).value;
                    try std.testing.expectEqualStrings("InvalidState", observation.object.get("error").?.string);
                    try std.testing.expectEqualDeep(before, try closing_executor.placementCut(scratch, subject));
                    try std.testing.expect(closing_executor.remote_stopped_parent == null);
                    try std.testing.expectEqualSlices(u8, bytes, try closing_executor.placementExecuteControl(scratch, "successor", control_value));
                }
            }
        }
        if (scenario == .preoffer) {
            const child_path = try std.fmt.allocPrint(scratch, "{s}/child-after-controller.par", .{path_buffer[0..length]});
            const child_offer = try sender.placementOffer(scratch, subject, "destination", child_path);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var child_decision: p.Signed(p.Decision) = undefined;
            {
                destination_namespace = try native.Namespace.open(a, io, destination_path);
                defer destination_namespace.close() catch unreachable;
                var child_profile = profile;
                child_profile.placement = &destination_config;
                var child_owner = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, child_profile);
                defer child_owner.close(a) catch unreachable;
                child_decision = try child_owner.placementAccept(scratch, "accept-child-after-controller", "source", child_offer, child_path);
            }
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
            sender_open = true;
            try sender.placementApplyDecision(scratch, subject, child_decision);
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var signed_control: p.Signed(p.Control) = undefined;
            {
                snapshot_namespace = try native.Namespace.open(a, io, successor_path);
                defer snapshot_namespace.close() catch unreachable;
                snapshot_receiver = try native.tasks.Service(OwnerTypes).init(a, io, &snapshot_namespace, assets, &application, handlers, snapshot_profile);
                defer snapshot_receiver.close(a) catch unreachable;
                const saved_control = try contracts.decodeOwned(p.Signed(p.Control), scratch, try snapshot_receiver.placementControl(scratch, "inspect-late-child", subject.task, .{ .inspect = .{ .work = work_ref } }));
                signed_control = saved_control.value;
            }
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
            sender_open = true;
            var next = try contracts.decodeOwned(p.ControlResolution, scratch, try sender.placementResolveControl(scratch, "successor", signed_control, &.{}));
            defer next.deinit();
            try std.testing.expect(next.value == .next);
            const route = [_]p.Succession{next.value.next};
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            var result: p.Signed(p.Report) = undefined;
            {
                destination_namespace = try native.Namespace.open(a, io, destination_path);
                defer destination_namespace.close() catch unreachable;
                var child_profile = profile;
                child_profile.placement = &destination_config;
                var child_owner = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, child_profile);
                defer child_owner.close(a) catch unreachable;
                try child_owner.placementFollowController(scratch, "source", "successor", snapshot_offer, decision);
                const resolved = try contracts.decodeOwned(p.ControlResolution, scratch, try child_owner.placementResolveControl(scratch, "successor", signed_control, &route));
                result = resolved.value.report;
                try std.testing.expectEqual(.observed, result.value.reply.disposition);
            }
            snapshot_namespace = try native.Namespace.open(a, io, successor_path);
            defer snapshot_namespace.close() catch unreachable;
            snapshot_receiver = try native.tasks.Service(OwnerTypes).init(a, io, &snapshot_namespace, assets, &application, handlers, snapshot_profile);
            defer snapshot_receiver.close(a) catch unreachable;
            try snapshot_receiver.placementFollowExecutor(scratch, subject.task, p.controlId(signed_control.value), route[0]);
            try snapshot_receiver.placementApplyReport(scratch, subject.task, p.controlId(signed_control.value), result);
            try std.testing.expectEqualDeep(destination_site, (try snapshot_receiver.placementStatus(scratch, subject)).?.owner);
        }
        return;
    }
    if (scenario == .work) {
        phase = "suspend controller before child freeze";
        try std.testing.expectEqual(.progressed, try sender.pump(scratch));
        try std.testing.expect(sender.active != null);
        try std.testing.expect(sender.active.?.work == null);
        try std.testing.expect(sender.active.?.root_control != null);
    }
    _ = try sender.placementFreeze(scratch, subject, "destination", cut, @splat(14));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.task(scratch, subject.task));
        try std.testing.expectError(error.Denied, sender.placementAbortUnsent(scratch, subject, @splat(14)));
        try std.testing.expectError(error.Denied, sender.placementFreeze(scratch, subject, "destination", cut, @splat(14)));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    if (scenario == .work) {
        try std.testing.expect(sender.active != null);
        try std.testing.expect(sender.active.?.work == null);
        try std.testing.expect(sender.active.?.root_control != null);
    }
    if (scenario == .cancel_abort or scenario == .cancel_refused) {
        var refused: ?p.Signed(p.Decision) = null;
        if (scenario == .cancel_refused) {
            const refused_path = try std.fmt.allocPrint(scratch, "{s}/refused.par", .{path_buffer[0..length]});
            const refused_offer = try sender.placementOffer(scratch, subject, "destination", refused_path);
            refused = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = refused_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, refused_offer.value), .source = source_site, .destination = destination_site, .epoch = refused_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
        }
        _ = try sender.requestCancel(scratch, "cancel-with-frozen-work", subject.task, "stop");
        var terminal = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.task(scratch, subject.task);
            defer current.deinit();
            if (current.value.terminal()) {
                terminal = true;
                break;
            }
        }
        try std.testing.expect(terminal);
        // Remove the terminal root's ordinary runnable entry. The retained
        // cancellation still owns the frozen child obligation.
        for (0..8) |_| if (try sender.pump(scratch) == .idle) break;
        try std.testing.expect(sender.owned.items.len != 0);
        try std.testing.expect(try sender.shutdownIncomplete(scratch));
        if (refused) |decision| {
            phase = "release refused transfer before identity retry";
            try sender.placementApplyDecision(scratch, subject, decision);
            try sender.placementApplyDecision(scratch, subject, decision);
        } else try sender.placementAbortUnsent(scratch, subject, @splat(14));
        var disposed = false;
        for (0..512) |_| {
            _ = try sender.pump(scratch);
            var current = try sender.task(scratch, subject.task);
            defer current.deinit();
            if (try sender.taskCleanupComplete(scratch, current.value)) {
                disposed = true;
                break;
            }
        }
        try std.testing.expect(disposed);
        try std.testing.expect(!try sender.shutdownIncomplete(scratch));
        if (refused != null) {
            const changed_cut = try sender.placementCut(scratch, subject);
            try std.testing.expect(!std.meta.eql(cut, changed_cut));
            const released_head = source_namespace.store.head;
            try std.testing.expectError(error.OperationConflict, sender.placementFreeze(scratch, subject, "destination", changed_cut, @splat(14)));
            try std.testing.expectEqualDeep(released_head, source_namespace.store.head);
            try std.testing.expectEqual(.local, (try sender.placementStatus(scratch, subject)).?.phase);
            phase = "fresh transfer after rejected identity reuse";
            const fresh_intent = try sender.placementFreeze(scratch, subject, "destination", changed_cut, @splat(17));
            try std.testing.expectEqualDeep(fresh_intent, try sender.placementFreeze(scratch, subject, "destination", changed_cut, @splat(17)));
            const other_subject: p.Subject = .{ .task = subject.task };
            const other_cut = try sender.placementCut(scratch, other_subject);
            try std.testing.expectError(error.OperationConflict, sender.placementFreeze(scratch, other_subject, "destination", other_cut, @splat(17)));
            try std.testing.expectEqual(.local, (try sender.placementStatus(scratch, other_subject)).?.phase);
            try std.testing.expectEqual(.frozen, (try sender.placementStatus(scratch, subject)).?.phase);
            var conflicting_intent = fresh_intent;
            conflicting_intent.source = destination_site;
            conflicting_intent.destination = source_site;
            const conflicting_offer = try p.sign(p.Offer, scratch, destination_key, .{ .intent = conflicting_intent, .archive_digest = @splat(94), .archive_bytes = 0 });
            const frozen_head = source_namespace.store.head;
            try std.testing.expectError(error.OperationConflict, sender.placementRefuse(scratch, "destination", conflicting_offer, .withdrawn));
            try std.testing.expectEqualDeep(frozen_head, source_namespace.store.head);
            try sender.placementAbortUnsent(scratch, subject, @splat(17));
            try std.testing.expectEqualDeep(fresh_intent, try sender.placementFreeze(scratch, subject, "destination", changed_cut, @splat(17)));
            const fresh_path = try std.fmt.allocPrint(scratch, "{s}/refused-again.par", .{path_buffer[0..length]});
            const fresh_offer = try sender.placementOffer(scratch, subject, "destination", fresh_path);
            const fresh_refusal = try p.sign(p.Decision, scratch, destination_key, .{ .transfer = fresh_offer.value.intent.transfer, .offer_digest = try p.digest(p.Offer, scratch, fresh_offer.value), .source = source_site, .destination = destination_site, .epoch = fresh_offer.value.intent.epoch + 1, .verdict = .{ .refused = .withdrawn } });
            try sender.placementApplyDecision(scratch, subject, fresh_refusal);
            phase = "reopen retained transfer decisions";
            try sender.close(a);
            sender_open = false;
            try source_namespace.close();
            source_open = false;
            source_namespace = try native.Namespace.open(a, io, source_path);
            source_open = true;
            var reopened_profile = profile;
            reopened_profile.placement = &source_config;
            sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, reopened_profile);
            sender_open = true;
            phase = "reject old transfer identity after restart";
            try std.testing.expectError(error.OperationConflict, sender.placementFreeze(scratch, subject, "destination", changed_cut, @splat(14)));
            const controller: p.Subject = .{ .task = subject.task };
            const controller_cut = try sender.placementCut(scratch, controller);
            try std.testing.expectError(error.OperationConflict, sender.placementFreeze(scratch, controller, "destination", controller_cut, @splat(14)));
            try std.testing.expectEqual(.local, (try sender.placementStatus(scratch, controller)).?.phase);
            try std.testing.expect(!try sender.shutdownIncomplete(scratch));
        }
        return;
    }
    try std.testing.expectError(error.CustodyNotLocal, sender.workspaceControl(scratch, "source-must-stop", subject.task, work_id, cut.execution, cut.control, .advance));
    const archive_path = try std.fmt.allocPrint(scratch, "{s}/transfer.par", .{path_buffer[0..length]});
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementOffer(scratch, subject, "destination", archive_path));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    // Leave the complete file without a published offer, as an interrupted
    // writer can. The retry must validate and durably reuse that exact file.
    disclosure.deny_runtime = true;
    try std.testing.expectError(error.DisclosureDenied, sender.placementOffer(scratch, subject, "destination", archive_path));
    try std.testing.expect((try sender.placementStatus(scratch, subject)).?.offer == null);
    disclosure.deny_runtime = false;
    const offer = try sender.placementOffer(scratch, subject, "destination", archive_path);
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementOffer(scratch, subject, "destination", archive_path));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    try std.testing.expect(disclosure.saw_runtime);
    disclosure.deny_runtime = true;
    try std.testing.expectError(error.DisclosureDenied, sender.placementOffer(scratch, subject, "destination", archive_path));
    disclosure.deny_runtime = false;
    try std.testing.expectEqualDeep(offer, try sender.placementOffer(scratch, subject, "destination", archive_path));
    source_peers[0].disclosure_policy[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, sender.placementOffer(scratch, subject, "destination", archive_path));
    source_peers[0].disclosure_policy[0] ^= 1;
    sender.profile.runtime_identity[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, sender.placementOffer(scratch, subject, "destination", archive_path));
    sender.profile.runtime_identity[0] ^= 1;
    sender.profile.authority.disclosure = false;
    try std.testing.expectError(error.Denied, sender.placementOffer(scratch, subject, "destination", archive_path));
    sender.profile.authority.disclosure = true;
    try std.testing.expectError(error.InvalidTransfer, sender.placementAbortUnsent(scratch, subject, @splat(14)));
    if (scenario == .work) {
        phase = "untrusted copied custody";
        try sender.park(scratch);
        const controller: p.Subject = .{ .task = subject.task };
        const controller_cut = try sender.placementCut(scratch, controller);
        for (0..3) |attack| {
            phase = "untrusted custody preparation";
            attack_index = attack;
            const attacked_archive = try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}.par", .{ path_buffer[0..length], attack });
            const copied_site: p.Site = .{ .key = destination_key.public_key.toBytes(), .namespace = untrusted_namespaces[attack] };
            {
                try source_namespace.store.begin();
                defer source_namespace.store.rollback();
                if (attack < 2) {
                    try source_namespace.store.database.run("DELETE FROM records WHERE kind='placement_custody' AND task=?", &.{.{ .blob = &subject.task }});
                } else {
                    const forged = try p.Custody.initial(controller, copied_site).freeze(copied_site, .{ .transfer = @splat(71), .subject = controller, .source = copied_site, .destination = source_site, .source_native = profile.runtime_identity, .destination_native = profile.runtime_identity, .epoch = 0, .cut = controller_cut, .compatibility = compatibility, .resources = resources, .disclosure = @splat(13) });
                    try source_namespace.store.putRecord(p.Custody, "placement_custody", forged.id, forged.task, forged);
                }
                _ = sender.exportCheckpoint(scratch, subject.task, attacked_archive) catch |err| {
                    std.debug.print("untrusted archive export {d}: {s}\n", .{ attack, @errorName(err) });
                    return err;
                };
            }
        }
    }
    try sender.close(a);
    sender_open = false;
    try source_namespace.close();
    source_open = false;
    if (scenario == .work) {
        const controller: p.Subject = .{ .task = subject.task };
        for (0..3) |attack| {
            phase = "untrusted custody import";
            attack_index = attack;
            const attacked_path = try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}", .{ path_buffer[0..length], attack });
            const attacked_archive = try std.fmt.allocPrint(scratch, "{s}/untrusted-{d}.par", .{ path_buffer[0..length], attack });
            var copied_namespace = try native.Namespace.open(a, io, attacked_path);
            defer copied_namespace.close() catch unreachable;
            const copied_config: p.Configuration = .{ .signing_key = destination_key, .peers = &.{} };
            var copied_profile = profile;
            if (attack != 0) copied_profile.placement = &copied_config;
            var copied = try native.tasks.Service(OwnerTypes).init(a, io, &copied_namespace, assets, &application, handlers, copied_profile);
            defer copied.close(a) catch unreachable;
            _ = copied.importCheckpoint(scratch, "untrusted-copy", attacked_archive) catch |err| {
                std.debug.print("untrusted archive import {d}: {s}\n", .{ attack, @errorName(err) });
                return err;
            };
            if (attack == 2) {
                try std.testing.expectEqual(.away, (try copied.placementStatus(scratch, controller)).?.phase);
                try std.testing.expectError(error.InvalidTransfer, copied.placementAbortUnsent(scratch, controller, @splat(71)));
            }
            try std.testing.expectError(error.CustodyNotLocal, copied.resumeTask(scratch, "untrusted-resume", subject.task, 1));
            try std.testing.expectError(error.CustodyNotLocal, copied.requestCancel(scratch, "untrusted-cancel", subject.task, "stop"));
        }
    }
    {
        // Ordinary archive import is a data copy. Even a configured native
        // service cannot acquire this task or work merely by possessing it.
        const copied_path = try std.fmt.allocPrint(scratch, "{s}/copied", .{path_buffer[0..length]});
        var copied_namespace = try native.Namespace.open(a, io, copied_path);
        defer copied_namespace.close() catch unreachable;
        var copied = try native.tasks.Service(OwnerTypes).init(a, io, &copied_namespace, assets, &application, handlers, profile);
        defer copied.close(a) catch unreachable;
        _ = try copied.importCheckpoint(scratch, "copy", archive_path);
        try std.testing.expectError(error.CustodyNotLocal, copied.workspacePump(scratch, "copy-cannot-run", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control }, .base_quantum = 1 }));
        try std.testing.expectError(error.CustodyNotLocal, copied.resumeTask(scratch, "copy-cannot-control", subject.task, 1));
    }
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    phase = "accept child";
    destination_open = true;
    var resumed_profile = profile;
    resumed_profile.placement = &destination_config;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    // Refusing one transfer is durable history, not task occupancy.
    var unrelated_offer = offer.value;
    unrelated_offer.intent.transfer = @splat(99);
    const unrelated_signed = try p.sign(p.Offer, scratch, source_key, unrelated_offer);
    const prior_refusal = try receiver.placementRefuse(scratch, "source", unrelated_signed, .withdrawn);
    try std.testing.expect(prior_refusal.value.verdict == .refused);
    const receiver_head = destination_namespace.store.head;
    destination_peers[0].compatibility.admission[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, receiver.placementAccept(scratch, "accept", "source", offer, archive_path));
    try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
    destination_peers[0].compatibility.admission[0] ^= 1;
    disclosure.deny_runtime = true;
    try std.testing.expectError(error.DisclosureDenied, receiver.placementAccept(scratch, "accept", "source", offer, archive_path));
    try std.testing.expectEqualDeep(receiver_head, destination_namespace.store.head);
    disclosure.deny_runtime = false;
    const accepted = try receiver.placementAccept(scratch, "accept", "source", offer, archive_path);
    try std.testing.expectEqual(.accepted, accepted.value.verdict);
    try std.testing.expectEqualDeep(prior_refusal, try receiver.placementRefuse(scratch, "source", unrelated_signed, .withdrawn));
    try std.testing.expectEqualDeep(accepted, try receiver.placementAccept(scratch, "accept-again", "source", offer, archive_path));
    try std.testing.expectEqualDeep(accepted, try receiver.placementRefuse(scratch, "source", offer, .withdrawn));
    // Lose the acceptance reply and restart the destination. Only its work is
    // executable; its copied controller remains at the original namespace.
    try std.testing.expectError(error.CustodyNotLocal, receiver.resumeTask(scratch, "copied-controller", subject.task, 1));
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    destination_open = true;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    try std.testing.expectEqualDeep(accepted, try receiver.placementAccept(scratch, "recovered-acceptance", "source", offer, archive_path));
    var imported_work = try receiver.workspaceWork(a, subject.task, work_id);
    defer imported_work.deinit();
    try std.testing.expectEqualDeep(cut.outer, p.ObjectIdentity.optional(imported_work.value.outer_operation.?.capsule));
    try std.testing.expectEqualDeep(cut.checkpoint, p.ObjectIdentity.from(imported_work.value.checkpoint));
    _ = try receiver.workspacePump(scratch, "continue-outer", subject.task, .{ .expected = .{ .work = work_ref, .execution_revision = imported_work.value.execution_revision, .control_revision = imported_work.value.control_revision }, .base_quantum = 1 });
    var continued = try receiver.workspaceWork(a, subject.task, work_id);
    defer continued.deinit();
    try std.testing.expect(!std.meta.eql(continued.value.outer_operation.?.capsule, imported_work.value.outer_operation.?.capsule));
    try std.testing.expectEqual(imported_work.value.execution_revision, continued.value.execution_revision);
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    source_namespace = try native.Namespace.open(a, io, source_path);
    source_open = true;
    var source_profile = profile;
    source_profile.placement = &source_config;
    sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
    sender_open = true;
    try std.testing.expectError(error.CustodyNotLocal, sender.workspaceControl(scratch, "lost-ack", subject.task, work_id, cut.execution, cut.control, .advance));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementApplyDecision(scratch, subject, accepted));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    try sender.placementApplyDecision(scratch, subject, accepted);
    try sender.placementApplyDecision(scratch, subject, accepted);
    try std.testing.expectEqual(.away, (try sender.placementStatus(scratch, subject)).?.phase);
    try std.testing.expectError(error.CustodyNotLocal, sender.workspaceControl(scratch, "departed", subject.task, work_id, cut.execution, cut.control, .advance));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    const control_bytes = try sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } });
    var control = try contracts.decodeOwned(p.Signed(p.Control), scratch, control_bytes);
    defer control.deinit();
    try std.testing.expectEqualSlices(u8, control_bytes, try sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = sender.profile.authority;
        defer sender.profile.authority = authority;
        const before = source_namespace.store.head;
        @field(sender.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, sender.placementControl(scratch, "remote-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
        try std.testing.expectEqualDeep(before, source_namespace.store.head);
    }
    try std.testing.expectError(error.OperationConflict, sender.placementControl(scratch, "remote-inspect", subject.task, .{ .park = .{ .work = work_ref, .execution_revision = cut.execution, .control_revision = cut.control } }));
    const controller_subject: p.Subject = .{ .task = subject.task };
    const controller_cut = try sender.placementCut(scratch, controller_subject);
    try std.testing.expectError(error.UnsettledRemoteControl, sender.placementFreeze(scratch, controller_subject, "successor", controller_cut, @splat(16)));
    try sender.close(a);
    sender_open = false;
    try source_namespace.close();
    source_open = false;
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    destination_open = true;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = receiver.profile.authority;
        defer receiver.profile.authority = authority;
        const before = destination_namespace.store.head;
        @field(receiver.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, receiver.placementExecuteControl(scratch, "source", control.value));
        try std.testing.expectError(error.Denied, receiver.placementResolveControl(scratch, "source", control.value, &.{}));
        try std.testing.expectEqualDeep(before, destination_namespace.store.head);
    }
    const report_bytes = try receiver.placementExecuteControl(scratch, "source", control.value);
    try std.testing.expectEqualSlices(u8, report_bytes, try receiver.placementExecuteControl(scratch, "source", control.value));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = receiver.profile.authority;
        defer receiver.profile.authority = authority;
        const before = destination_namespace.store.head;
        @field(receiver.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, receiver.placementExecuteControl(scratch, "source", control.value));
        try std.testing.expectError(error.Denied, receiver.placementResolveControl(scratch, "source", control.value, &.{}));
        try std.testing.expectEqualDeep(before, destination_namespace.store.head);
    }
    var report = try contracts.decodeOwned(p.Signed(p.Report), scratch, report_bytes);
    defer report.deinit();
    try std.testing.expectEqual(.observed, report.value.value.reply.disposition);
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    source_namespace = try native.Namespace.open(a, io, source_path);
    source_open = true;
    sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
    sender_open = true;
    try sender.placementApplyReport(scratch, subject.task, p.controlId(control.value.value), report.value);
    try sender.placementApplyReport(scratch, subject.task, p.controlId(control.value.value), report.value);
    if (scenario == .onward) {
        const delayed_bytes = try sender.placementControl(scratch, "delayed-inspect", subject.task, .{ .inspect = .{ .work = work_ref } });
        var delayed = try contracts.decodeOwned(p.Signed(p.Control), scratch, delayed_bytes);
        defer delayed.deinit();
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        destination_namespace = try native.Namespace.open(a, io, destination_path);
        destination_open = true;
        receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
        receiver_open = true;
        const next_cut = try receiver.placementCut(scratch, subject);
        _ = try receiver.placementFreeze(scratch, subject, "successor", next_cut, @splat(71));
        const next_path = try std.fmt.allocPrint(scratch, "{s}/onward.par", .{path_buffer[0..length]});
        const next_offer = try receiver.placementOffer(scratch, subject, "successor", next_path);
        try receiver.close(a);
        receiver_open = false;
        try destination_namespace.close();
        destination_open = false;
        var next_decision: p.Signed(p.Decision) = undefined;
        {
            successor_namespace = try native.Namespace.open(a, io, successor_path);
            defer successor_namespace.close() catch unreachable;
            var successor_profile = profile;
            successor_profile.placement = &successor_config;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
            defer successor.close(a) catch unreachable;
            next_decision = try successor.placementAccept(scratch, "accept-onward", "destination", next_offer, next_path);
        }
        destination_namespace = try native.Namespace.open(a, io, destination_path);
        destination_open = true;
        receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
        receiver_open = true;
        try receiver.placementApplyDecision(scratch, subject, next_decision);
        var resolution = try contracts.decodeOwned(p.ControlResolution, scratch, try receiver.placementResolveControl(scratch, "source", delayed.value, &.{}));
        defer resolution.deinit();
        try std.testing.expect(resolution.value == .next);
        const route = [_]p.Succession{resolution.value.next};
        try std.testing.expectEqualDeep(next_decision, route[0].decision);
        try receiver.close(a);
        receiver_open = false;
        try destination_namespace.close();
        destination_open = false;
        source_namespace = try native.Namespace.open(a, io, source_path);
        source_open = true;
        sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
        sender_open = true;
        var forged = route[0];
        forged.offer.value.intent.epoch += 1;
        try std.testing.expectError(error.SignatureVerificationFailed, sender.placementFollowExecutor(scratch, subject.task, p.controlId(delayed.value.value), forged));
        inline for (.{ "principal", "tenant" }) |field| {
            const authority = sender.profile.authority;
            defer sender.profile.authority = authority;
            const before = source_namespace.store.head;
            const pending_before = try scratch.dupe(@TypeOf(sender.placement_pending.items[0]), sender.placement_pending.items);
            @field(sender.profile.authority, field) = "foreign";
            try std.testing.expectError(error.Denied, sender.placementFollowExecutor(scratch, subject.task, p.controlId(delayed.value.value), route[0]));
            try std.testing.expectEqualDeep(before, source_namespace.store.head);
            try std.testing.expectEqualDeep(pending_before, sender.placement_pending.items);
        }
        try sender.placementFollowExecutor(scratch, subject.task, p.controlId(delayed.value.value), route[0]);
        try std.testing.expectEqualDeep(successor_site, (try sender.placementStatus(scratch, subject)).?.owner);
        try std.testing.expectEqualSlices(u8, delayed_bytes, try sender.placementControl(scratch, "delayed-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
        try sender.close(a);
        sender_open = false;
        try source_namespace.close();
        source_open = false;
        var delayed_report_bytes: []u8 = undefined;
        {
            successor_namespace = try native.Namespace.open(a, io, successor_path);
            defer successor_namespace.close() catch unreachable;
            var successor_profile = profile;
            successor_profile.placement = &successor_config;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
            defer successor.close(a) catch unreachable;
            const before = successor_namespace.store.head;
            var old_receipt = try contracts.decodeOwned(p.ControlResolution, scratch, try successor.placementResolveControl(scratch, "source", control.value, &route));
            defer old_receipt.deinit();
            try std.testing.expect(old_receipt.value == .report);
            try std.testing.expectEqualSlices(u8, report_bytes, try contracts.encodeOwned(p.Signed(p.Report), scratch, old_receipt.value.report));
            try std.testing.expectEqualDeep(before, successor_namespace.store.head);
            inline for (.{ "principal", "tenant" }) |field| {
                const authority = successor.profile.authority;
                defer successor.profile.authority = authority;
                @field(successor.profile.authority, field) = "foreign";
                try std.testing.expectError(error.Denied, successor.placementResolveControl(scratch, "source", control.value, &route));
                try std.testing.expectEqualDeep(before, successor_namespace.store.head);
            }
            disclosure.deny_runtime = true;
            try std.testing.expectError(error.DisclosureDenied, successor.placementResolveControl(scratch, "source", control.value, &route));
            disclosure.deny_runtime = false;
            const executed = try successor.placementResolveControl(scratch, "source", delayed.value, &route);
            var result = try contracts.decodeOwned(p.ControlResolution, scratch, executed);
            defer result.deinit();
            const delayed_report = result.value.report;
            delayed_report_bytes = try contracts.encodeOwned(p.Signed(p.Report), scratch, delayed_report);
            try std.testing.expectEqualDeep(successor_site, delayed_report.value.executor);
            try std.testing.expectEqual(next_decision.value.epoch, delayed_report.value.custody_epoch);
            const after = successor_namespace.store.head;
            try std.testing.expectEqualSlices(u8, executed, try successor.placementResolveControl(scratch, "source", delayed.value, &route));
            try std.testing.expectEqualDeep(after, successor_namespace.store.head);
            // This process owns the executor, while the copied controller is
            // still at A. Shutdown must cancel only its actual local work.
            const current_cut = try successor.placementCut(scratch, subject);
            _ = try successor.workspaceControl(scratch, "claim-onward-executor", subject.task, work_id, current_cut.execution, current_cut.control, .park);
            var before_cancel = try successor.workspaceWork(scratch, subject.task, work_id);
            defer before_cancel.deinit();
            try std.testing.expect(!before_cancel.value.terminal());
            try std.testing.expect(successor.owned.items.len != 0);
            const interrupt = "interrupt-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
            try std.testing.expectEqual(@as(usize, 74), interrupt.len);
            try successor.cancelOwned(scratch, interrupt, "stop local executor");
            var after_cancel = try successor.workspaceWork(scratch, subject.task, work_id);
            defer after_cancel.deinit();
            try std.testing.expect(after_cancel.value.cancellation != null);
            // Cancellation can finish synchronously. Unfinished local work is
            // incomplete; a remote controller copy is not a local obligation.
            try std.testing.expectEqual(!after_cancel.value.terminal(), try successor.shutdownIncomplete(scratch));
            var settled = false;
            for (0..512) |_| {
                _ = try successor.pump(scratch);
                if (!try successor.shutdownIncomplete(scratch)) {
                    settled = true;
                    break;
                }
            }
            try std.testing.expect(settled);
            var closed_work = try successor.workspaceWork(scratch, subject.task, work_id);
            defer closed_work.deinit();
            try std.testing.expect(closed_work.value.terminal());
            try std.testing.expectEqual(.away, (try successor.placementStatus(scratch, .{ .task = subject.task })).?.phase);
        }
        source_namespace = try native.Namespace.open(a, io, source_path);
        source_open = true;
        sender = try native.tasks.Service(OwnerTypes).init(a, io, &source_namespace, assets, &application, handlers, source_profile);
        sender_open = true;
        var delayed_report = try contracts.decodeOwned(p.Signed(p.Report), scratch, delayed_report_bytes);
        defer delayed_report.deinit();
        try sender.placementApplyReport(scratch, subject.task, p.controlId(delayed.value.value), delayed_report.value);
        return;
    }
    // Advance the controller after its worker was exported. The worker has
    // never received this controller checkpoint, and a succession proof must
    // not require that private object to be retained locally.
    _ = try sender.resumeTask(scratch, "advance-controller-after-export", subject.task, controller_cut.control);
    var advanced_controller = controller_cut;
    for (0..64) |_| {
        _ = try sender.pump(scratch);
        advanced_controller = try sender.placementCut(scratch, controller_subject);
        if (advanced_controller.execution > controller_cut.execution) break;
    }
    try std.testing.expect(advanced_controller.execution > controller_cut.execution);
    try std.testing.expect(!std.meta.eql(controller_cut.checkpoint, advanced_controller.checkpoint));
    _ = try sender.placementFreeze(scratch, controller_subject, "successor", advanced_controller, @splat(16));
    const controller_archive = try std.fmt.allocPrint(scratch, "{s}/controller.par", .{path_buffer[0..length]});
    const controller_offer = try sender.placementOffer(scratch, controller_subject, "successor", controller_archive);
    try sender.close(a);
    sender_open = false;
    try source_namespace.close();
    source_open = false;
    var controller_decision: p.Signed(p.Decision) = undefined;
    var successor_control: contracts.Decoded(p.Signed(p.Control)) = undefined;
    {
        successor_namespace = try native.Namespace.open(a, io, successor_path);
        defer successor_namespace.close() catch unreachable;
        var successor_profile = profile;
        successor_profile.placement = &successor_config;
        var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
        defer successor.close(a) catch unreachable;
        controller_decision = try successor.placementAccept(scratch, "accept-controller", "source", controller_offer, controller_archive);
        try std.testing.expectEqual(.local, (try successor.placementStatus(scratch, controller_subject)).?.phase);
        try std.testing.expectEqual(.away, (try successor.placementStatus(scratch, subject)).?.phase);
        successor_control = try contracts.decodeOwned(p.Signed(p.Control), scratch, try successor.placementControl(scratch, "new-controller-inspect", subject.task, .{ .inspect = .{ .work = work_ref } }));
    }
    defer successor_control.deinit();
    destination_namespace = try native.Namespace.open(a, io, destination_path);
    destination_open = true;
    receiver = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
    receiver_open = true;
    try std.testing.expectError(error.MissingArtifact, receiver.namespace.store.objectReference(advanced_controller.checkpoint.digest, null));
    try std.testing.expectError(error.StaleController, receiver.placementExecuteControl(scratch, "successor", successor_control.value));
    inline for (.{ "principal", "tenant" }) |field| {
        const authority = receiver.profile.authority;
        defer receiver.profile.authority = authority;
        const before = destination_namespace.store.head;
        @field(receiver.profile.authority, field) = "foreign";
        try std.testing.expectError(error.Denied, receiver.placementFollowController(scratch, "source", "successor", controller_offer, controller_decision));
        try std.testing.expectEqualDeep(before, destination_namespace.store.head);
    }
    try receiver.placementFollowController(scratch, "source", "successor", controller_offer, controller_decision);
    try receiver.placementFollowController(scratch, "source", "successor", controller_offer, controller_decision);
    var stale_control = control.value.value;
    stale_control.operation = .{ .bytes = "late-old-controller" };
    try std.testing.expectError(error.StaleController, receiver.placementExecuteControl(scratch, "source", try p.sign(p.Control, scratch, source_key, stale_control)));
    const successor_report_bytes = try receiver.placementExecuteControl(scratch, "successor", successor_control.value);
    var successor_report = try contracts.decodeOwned(p.Signed(p.Report), scratch, successor_report_bytes);
    defer successor_report.deinit();
    try std.testing.expectEqual(.observed, successor_report.value.value.reply.disposition);
    try std.testing.expect(successor_report.value.value.work_state != null);
    try receiver.close(a);
    receiver_open = false;
    try destination_namespace.close();
    destination_open = false;
    // Exercise the automatic parent-cancellation decision with real stores and
    // signed messages. This fixture carries the queued bytes between namespace
    // owners; the separate process fixture owns transport qualification.
    successor_peers[0].channel = .{ .argv = &.{"/usr/bin/false"}, .remote_name = "successor" };
    var cleanup_control = successor_control.value;
    var cleanup_report = successor_report.value;
    var disposed = false;
    var parked_once = false;
    var resumed_after_park = false;
    for (0..512) |iteration| {
        {
            successor_namespace = try native.Namespace.open(a, io, successor_path);
            defer successor_namespace.close() catch unreachable;
            var successor_profile = profile;
            successor_profile.placement = &successor_config;
            var successor = try native.tasks.Service(OwnerTypes).init(a, io, &successor_namespace, assets, &application, handlers, successor_profile);
            defer successor.close(a) catch unreachable;
            try successor.placementApplyReport(scratch, subject.task, p.controlId(cleanup_control.value), cleanup_report);
            if (iteration == 0) {
                try std.testing.expect(!try successor.associatedWorkDisposed(scratch, subject.task));
                _ = try successor.requestCancel(scratch, "cancel-with-remote-work", subject.task, "controller stopped");
                const replayed_control = try successor.placementControl(scratch, "new-controller-inspect", subject.task, .{ .inspect = .{ .work = work_ref } });
                try std.testing.expectEqualSlices(u8, try contracts.encodeOwned(p.Signed(p.Control), scratch, successor_control.value), replayed_control);
            }
            if (cleanup_report.value.work_state.?.explicitly_parked and !resumed_after_park) {
                try std.testing.expect(parked_once);
                _ = try successor.pump(scratch);
                var pending = try successor_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
                defer pending.deinit();
                while (try pending.step() == .row) {
                    var saved = try contracts.decodeOwned(p.ControlRecord, scratch, try pending.bytes(0));
                    defer saved.deinit();
                    try std.testing.expect(saved.value.report != null);
                }
                try std.testing.expect(try successor.shutdownIncomplete(scratch));
                _ = try successor.requestCancel(scratch, "fresh-cancel-after-remote-park", subject.task, "controller stopped");
                resumed_after_park = true;
            }
            if (try successor.associatedWorkDisposed(scratch, subject.task)) {
                for (0..512) |_| {
                    _ = try successor.pump(scratch);
                    var task = try successor.task(scratch, subject.task);
                    defer task.deinit();
                    if (task.value.terminal()) {
                        try std.testing.expect(try successor.taskCleanupComplete(scratch, task.value));
                        disposed = true;
                        break;
                    }
                }
                break;
            }
            try std.testing.expect(try successor.pump(scratch) != .work);
            var query = try successor_namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='placement_control'", &.{.{ .blob = &subject.task }});
            defer query.deinit();
            var found = false;
            while (try query.step() == .row) {
                const saved = try contracts.decodeOwned(p.ControlRecord, scratch, try query.bytes(0));
                if (saved.value.report == null and std.mem.startsWith(u8, saved.value.control.value.operation.bytes, "cleanup-")) {
                    cleanup_control = saved.value.control;
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        }
        {
            destination_namespace = try native.Namespace.open(a, io, destination_path);
            defer destination_namespace.close() catch unreachable;
            var executor = try native.tasks.Service(OwnerTypes).init(a, io, &destination_namespace, assets, &application, handlers, resumed_profile);
            defer executor.close(a) catch unreachable;
            const bytes = try executor.placementExecuteControl(scratch, "successor", cleanup_control);
            const decoded_report = try contracts.decodeOwned(p.Signed(p.Report), scratch, bytes);
            cleanup_report = decoded_report.value;
            if (cleanup_report.value.reply.disposition == .rejected) {
                try std.testing.expect(parked_once and !resumed_after_park);
                try std.testing.expect(cleanup_control.value.command == .pump);
                try std.testing.expect(cleanup_report.value.work_state.?.explicitly_parked);
            } else try std.testing.expectEqual(.observed, cleanup_report.value.reply.disposition);
            try std.testing.expectEqualSlices(u8, bytes, try executor.placementExecuteControl(scratch, "successor", cleanup_control));
            if (!parked_once and cleanup_control.value.command == .cancel) {
                const current = cleanup_report.value.work_state.?;
                _ = try executor.workspaceControl(scratch, "park-after-controller-cancel", subject.task, work_id, current.execution_revision, current.control_revision, .park);
                parked_once = true;
            }
        }
    }
    try std.testing.expect(disposed);
    try std.testing.expect(parked_once and resumed_after_park);
}
