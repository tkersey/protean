//! The actual adaptive image at the captured-before-interpreted boundary.
//! Copied-product admission is covered separately by native_adaptive.mjs.
const std = @import("std");
const protean = @import("protean");
const native = @import("protean_native");
const horos = @import("horos");
const kronos = @import("kronos");
const t = @import("adaptive_types");
const environment = @import("adaptive_environment");
const protocol = horos.data.invocation;
const Ref = t.model.ArtifactReference;

fn constructionRecipe(a: std.mem.Allocator, stages: []const struct { component: []const u8, operation: ?[]const u8 = null }) ![]u8 {
    const wire = protean.contracts.tool_construction;
    var instances: std.ArrayList(@FieldType(wire.Recipe, "instances").Child) = .empty;
    var bindings: std.ArrayList(@FieldType(wire.Recipe, "bindings").Child) = .empty;
    for (stages, 0..) |stage, i| {
        const key = try std.fmt.allocPrint(a, "stage{d}", .{i});
        try instances.append(a, .{ .key = .{ .bytes = key }, .component_id = .{ .bytes = stage.component } });
        if (stage.operation) |operation| {
            const operation_key = try std.fmt.allocPrint(a, "operation{d}", .{i});
            try instances.append(a, .{ .key = .{ .bytes = operation_key }, .component_id = .{ .bytes = operation } });
            try bindings.append(a, .{ .required = .{ .instance = .{ .bytes = key }, .symbol = .{ .bytes = if (std.mem.eql(u8, stage.component, "map")) "row" else "keep" } }, .supplied = .{ .instance = .{ .bytes = operation_key }, .symbol = .{ .bytes = "apply" } } });
        }
        if (i + 1 < stages.len) {
            const composition = try std.fmt.allocPrint(a, "compose{d}", .{i});
            try instances.append(a, .{ .key = .{ .bytes = composition }, .component_id = .{ .bytes = "compose" } });
            try bindings.append(a, .{ .required = .{ .instance = .{ .bytes = composition }, .symbol = .{ .bytes = "first" } }, .supplied = .{ .instance = .{ .bytes = key }, .symbol = .{ .bytes = "apply" } } });
            const second = try std.fmt.allocPrint(a, "{s}{d}", .{ if (i + 2 == stages.len) "stage" else "compose", i + 1 });
            try bindings.append(a, .{ .required = .{ .instance = .{ .bytes = composition }, .symbol = .{ .bytes = "second" } }, .supplied = .{ .instance = .{ .bytes = second }, .symbol = .{ .bytes = "apply" } } });
        }
    }
    const recipe: wire.Recipe = .{ .instances = .{ .items = instances.items }, .bindings = .{ .items = bindings.items }, .entry = .{ .instance = .{ .bytes = if (stages.len == 1) "stage0" else "compose0" }, .symbol = .{ .bytes = "apply" } } };
    return native.json.canonical(a, try native.values.toJson(wire.Recipe, a, recipe));
}

fn auditRow(id: u64, key: u64, value: u64, group: u64) t.tool_types.Row {
    return .{ .id = id, .key = key, .value = value, .group = group, .matches = 0, .match_id = 0, .mismatches = 0, .status = 0 };
}

test "compiled catalog composes coverage and orphan grouping and reuses exact BPI3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wire = protean.contracts.tool_construction;
    const engine = native.tool_construction;
    const metadata = (try native.json.parse(a, @embedFile("adaptive_application"), .{ .bytes = 1024 * 1024 })).value;
    var encoded_catalog: ?[]const u8 = null;
    for ((native.json.get(metadata, "resources") orelse return error.MissingCatalog).array.items) |resource| {
        if (std.mem.eql(u8, try native.json.text(native.json.get(resource, "id").?), "tool-construction.catalog")) encoded_catalog = (try native.values.fromJson(protean.contracts.Bytes(128 * 1024), a, native.json.get(resource, "base64url").?)).bytes;
    }
    var catalog = try protean.contracts.decodeOwned(wire.Catalog, a, encoded_catalog orelse return error.MissingCatalog);
    defer catalog.deinit();
    try engine.validateCatalog(a, catalog.value);
    const coverage = try constructionRecipe(a, &.{ .{ .component = "filter", .operation = "selected" }, .{ .component = "map", .operation = "join" }, .{ .component = "map", .operation = "classify" } });
    var scratch: kronos.AllocationBudget = .{ .parent = a, .limit = 16 * 1024 * 1024 };
    const task: [16]u8 = @splat(17);
    const product = try engine.construct(a, scratch.allocator(), task, "frozen-policy", encoded_catalog.?, coverage);
    const tool = product.built;
    // Persistence round-trip keeps the exact image, recipe and task binding.
    var recovered = try protean.contracts.decodeOwned(wire.Program, a, try protean.contracts.encodeOwned(wire.Program, a, product));
    defer recovered.deinit();
    try std.testing.expectEqualSlices(u8, tool.image.bytes, recovered.value.built.image.bytes);
    const schema = try native.values.schemaBytes(t.tool_types.Table, a);
    const input: t.tool_types.Table = .{ .rows = .{ .items = &.{ auditRow(1, 10, 100, 1), auditRow(2, 20, 200, 1), auditRow(3, 30, 300, 2), auditRow(4, 40, 400, 2), auditRow(5, 50, 500, 3) } }, .relation = .{ .items = &.{ auditRow(11, 10, 100, 1), auditRow(12, 20, 201, 1), auditRow(13, 40, 400, 2), auditRow(14, 40, 401, 2), auditRow(15, 90, 1, 3), auditRow(16, 91, 1, 3), auditRow(17, 92, 1, 4) } }, .selected = .{ .items = &.{ 10, 20, 30, 40 } } };
    const admitted_input: wire.Input = .{ .schema = .{ .bytes = schema }, .value = .{ .bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, input) } };
    try std.testing.expectError(error.UnauthorizedProgram, engine.execute(a, a, std.testing.io, null, @splat(18), "frozen-policy", encoded_catalog.?, recovered.value, admitted_input, .{}));
    try std.testing.expectError(error.UnauthorizedProgram, engine.execute(a, a, std.testing.io, null, task, "changed-policy", encoded_catalog.?, recovered.value, admitted_input, .{}));
    const first = try engine.execute(a, a, std.testing.io, null, task, "frozen-policy", encoded_catalog.?, recovered.value, admitted_input, .{});
    var result = try protean.contracts.decodeOwned(t.tool_types.Table, a, first);
    defer result.deinit();
    try std.testing.expectEqual(4, result.value.rows.items.len);
    for (result.value.rows.items, [_]u64{ 1, 2, 3, 4 }, 1..) |row, status, id| {
        try std.testing.expectEqual(id, row.id);
        try std.testing.expectEqual(status, row.status);
    }
    const next: t.tool_types.Table = .{ .rows = .{ .items = &.{auditRow(80, 20, 201, 9)} }, .relation = input.relation, .selected = .{ .items = &.{20} } };
    var reused = try protean.contracts.decodeOwned(t.tool_types.Table, a, try engine.execute(a, a, std.testing.io, null, task, "frozen-policy", encoded_catalog.?, recovered.value, .{ .schema = .{ .bytes = schema }, .value = .{ .bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, next) } }, .{}));
    defer reused.deinit();
    try std.testing.expectEqual(1, reused.value.rows.items.len);
    try std.testing.expectEqual(80, reused.value.rows.items[0].id);
    try std.testing.expectEqual(1, reused.value.rows.items[0].status);
    const reverse = try constructionRecipe(a, &.{ .{ .component = "filter", .operation = "selected" }, .{ .component = "swap" }, .{ .component = "map", .operation = "join" }, .{ .component = "filter", .operation = "orphan" }, .{ .component = "group" } });
    const reverse_tool = try engine.build(a, scratch.allocator(), catalog.value, reverse);
    try std.testing.expect(!std.mem.eql(u8, tool.image.bytes, reverse_tool.image.bytes));
    var grouped = try protean.contracts.decodeOwned(t.tool_types.Table, a, try engine.run(a, a, std.testing.io, null, reverse_tool, schema, try protean.contracts.encodeOwned(t.tool_types.Table, a, input), .{}));
    defer grouped.deinit();
    try std.testing.expectEqual(2, grouped.value.rows.items.len);
    try std.testing.expectEqual(3, grouped.value.rows.items[0].group);
    try std.testing.expectEqual(2, grouped.value.rows.items[0].value);
    try std.testing.expectEqual(4, grouped.value.rows.items[1].group);
    try std.testing.expectEqual(1, grouped.value.rows.items[1].value);
    try std.testing.expectError(error.InvalidParams, engine.build(a, scratch.allocator(), catalog.value, "{\"instances\":[],\"bindings\":[],\"entry\":{\"instance\":\"x\",\"symbol\":\"apply\"},\"pure\":true}"));
    try std.testing.expectError(error.UnknownComponent, engine.build(a, scratch.allocator(), catalog.value, "{\"instances\":[{\"key\":\"x\",\"component_id\":\"not-approved\"}],\"bindings\":[],\"entry\":{\"instance\":\"x\",\"symbol\":\"apply\"}}"));
    try std.testing.expectError(error.IncompatibleInterface, engine.build(a, scratch.allocator(), catalog.value, try constructionRecipe(a, &.{.{ .component = "filter", .operation = "swap" }})));
    try std.testing.expectError(error.CyclicComposition, engine.build(a, scratch.allocator(), catalog.value, "{\"instances\":[{\"key\":\"x\",\"component_id\":\"compose\"}],\"bindings\":[{\"required\":{\"instance\":\"x\",\"symbol\":\"first\"},\"supplied\":{\"instance\":\"x\",\"symbol\":\"apply\"}}],\"entry\":{\"instance\":\"x\",\"symbol\":\"apply\"}}"));
    // Add a valid but unreachable external declaration to an actual component.
    // Pure admission rejects the declaration even though the entry never uses it.
    var component = try horos.data.component.decode(a, catalog.value.items[7].object.bytes);
    defer component.deinit();
    var forbidden = component.object;
    var unit: ?u64 = null;
    for (forbidden.program.schemas, 0..) |shape, i| if (shape == .unit) {
        unit = @intCast(i);
        break;
    };
    const external = [_]horos.data.program.Effect{.{ .identity = "forbidden.external", .payload = unit.?, .result = unit.?, .external = true }};
    forbidden.program.effects = &external;
    const forbidden_bytes = try a.alloc(u8, try horos.data.component.encodedLength(forbidden));
    _ = try horos.data.component.encode(a, forbidden, forbidden_bytes);
    try std.testing.expectError(error.ForbiddenEffect, engine.validateCatalog(a, .{ .items = &.{.{ .id = .{ .bytes = "swap" }, .object = .{ .bytes = forbidden_bytes } }} }));
    var substituted = recovered.value;
    const altered = try a.dupe(u8, substituted.built.image.bytes);
    altered[0] ^= 1;
    substituted.built.image.bytes = altered;
    try std.testing.expectError(error.InvalidDerivation, engine.execute(a, a, std.testing.io, null, task, "frozen-policy", encoded_catalog.?, substituted, admitted_input, .{}));
    try std.testing.expectError(error.IncompatibleInterface, engine.run(a, a, std.testing.io, null, tool, try native.values.schemaBytes(bool, a), admitted_input.value.bytes, .{}));
    try std.testing.expectError(error.OutOfMemory, engine.run(a, a, std.testing.io, null, tool, schema, admitted_input.value.bytes, .{ .working_bytes = 1 }));
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, engine.run(a, a, std.testing.io, &cancelled, tool, schema, admitted_input.value.bytes, .{}));
    try std.testing.expectError(error.FuelExhausted, engine.run(a, a, std.testing.io, null, tool, schema, try protean.contracts.encodeOwned(t.tool_types.Table, a, input), .{ .transitions = 1 }));
}
// Independent projection of the persisted capture record, including the
// acquired-but-not-interpreted discriminant exercised below.
const CaptureRecord = struct {
    task: [16]u8,
    occurrence: [32]u8,
    attempt: [32]u8,
    request: Ref,
    response: ?Ref,
    disposition: enum { complete, definitely_not_sent, unknown },
    projection: ?struct { reply: Ref, objects: protean.contracts.Vector(Ref, 16), output_tokens: ?u64 },
};

test "adaptive unload capture recovers under its original plan without another acquisition" {
    var budget: kronos.AllocationBudget = .{ .parent = std.testing.allocator, .limit = 64 * 1024 * 1024 };
    const a = budget.allocator();
    const io = std.testing.io;
    var profile_arena = std.heap.ArenaAllocator.init(a);
    defer profile_arena.deinit();
    const permanent = profile_arena.allocator();
    const image = @embedFile("adaptive_image");
    const metadata = @embedFile("adaptive_application");
    const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
    defer admitted_image.deinit();
    const manifest = try @import("native_tasks.zig").ownerManifest(permanent, image, admitted_image.identity(), metadata);
    const assets: native.discovery.Assets = .{ .image = image, .application = metadata, .manifest = manifest };
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "adaptive-unit", .image_identity = admitted_image.identity() };
    defer application.deinit();
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    var handlers = try native.Registry.init(a, &environment.handlers);
    defer handlers.deinit();
    const configured = try environment.configure(permanent, io, .{ .offline = true, .scratch_allocator = a }, null, assets);
    var grants: [environment.handlers.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = configured.id, .runtime_identity = @splat(73), .bytes = configured.bytes, .environment = configured.environment, .resources = configured.resources, .authority = .{ .grants = &grants, .principal = "adaptive-unit", .tenant = "local", .inference = true } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(application.image_identity) };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = try std.fmt.allocPrint(permanent, "{s}/adaptive", .{buffer[0..length]});
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) namespace.close() catch unreachable;
    var service = try native.tasks.Service(t).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_live = true;
    defer if (service_live) service.close(a) catch unreachable;
    // Large admitted task/input text must survive transcript continuation,
    // including captured-before-interpreted recovery.
    const long_task: [2048]u8 = @splat('T');
    const long_followup: [2048]u8 = @splat('F');
    const task = (try service.submit(permanent, "adaptive-recovery-submit", .{ .task = .{ .bytes = &long_task } })).receipt.task;
    _ = try service.message(permanent, "large-followup-one", task, .{ .message = .{ .bytes = &long_followup } });
    _ = try service.message(permanent, "large-followup-two", task, .{ .message = .{ .bytes = &long_followup } });
    var model_calls: usize = 0;
    var restarted = false;
    var witnessed = false;
    var finished = false;
    var maximum_state: u64 = 0;
    var maximum_prepared: usize = 0;
    var maximum_scratch: usize = 0;
    for (0..512) |_| {
        var scratch: kronos.AllocationBudget = .{ .parent = a, .limit = 64 * 1024 * 1024 };
        var arena = std.heap.ArenaAllocator.init(scratch.allocator());
        defer arena.deinit();
        defer maximum_scratch = @max(maximum_scratch, scratch.peak);
        const frame = arena.allocator();
        var saved = try service.task(frame, task);
        defer saved.deinit();
        maximum_state = @max(maximum_state, saved.value.checkpoint.bytes);
        if (saved.value.terminal()) {
            try std.testing.expect(saved.value.outcome_kind == .completed);
            const result = try namespace.store.object(frame, saved.value.result.?, 64 * 1024);
            var output = try protean.contracts.decodeOwned(t.Output, frame, result);
            defer output.deinit();
            try std.testing.expect(output.value.disposition == .report);
            try std.testing.expectEqual(14, output.value.model_calls);
            try std.testing.expectEqual(8, output.value.receipts.items.len);
            try std.testing.expectEqual(8, output.value.control.selection.control_revision);
            finished = true;
            break;
        }
        if (restarted and !witnessed and saved.value.outcome_kind == .requested) {
            const encoded = try namespace.store.object(frame, saved.value.outcome, 1024 * 1024);
            var outcome = try protocol.decode(protocol.Outcome, frame, encoded);
            defer outcome.deinit();
            var request = try protocol.decode(protocol.Request, frame, outcome.value.requested.request);
            defer request.deinit();
            if (std.mem.eql(u8, request.value.binding.semantic_identity, t.P.adaptive_identity)) {
                var adaptive = try protean.contracts.decodeOwned(t.P.AdaptiveRequest, frame, request.value.binding.payload);
                defer adaptive.deinit();
                if (adaptive.value.plan.watermark == 8) {
                    try std.testing.expectEqual(8, model_calls);
                    try std.testing.expectEqual(5, adaptive.value.selection.control_revision);
                    try std.testing.expectEqual(1, adaptive.value.plan.eviction_generation);
                    try std.testing.expectEqual(0, adaptive.value.plan.skills.items.len);
                    try std.testing.expect(!adaptive.value.offered[7] and !adaptive.value.materialized[7]);
                    try std.testing.expectEqual(8, saved.value.inference_attempts);
                    witnessed = true;
                }
            }
        }
        const step = try service.pump(frame);
        if (step == .work) {
            const work = step.work;
            var request = try protocol.decode(protocol.Request, frame, work.request);
            defer request.deinit();
            const context: native.Context = .{ .allocator = frame, .io = io, .authority = &profile.authority, .task_id = "adaptive-unit", .profile = profile.bytes, .environment = profile.environment };
            const reply = if (work.entry.declaration.capture) |adapter| blk: {
                maximum_prepared = @max(maximum_prepared, work.prepared.?.len);
                if (work.entry.declaration.inference and model_calls == 8) {
                    var prepared = try protean.contracts.decodeOwned(t.P.AdaptivePrepared, frame, work.prepared.?);
                    defer prepared.deinit();
                    const rendered = try native.json.parse(frame, prepared.value.body.bytes, .{});
                    var task_count: usize = 0;
                    var followup_count: usize = 0;
                    for (rendered.value.object.get("input").?.array.items) |item| {
                        const content = native.json.get(item, "content") orelse continue;
                        if (content != .array) continue;
                        for (content.array.items) |part| {
                            const text = native.json.get(part, "text") orelse continue;
                            if (text != .string) continue;
                            if (std.mem.eql(u8, text.string, &long_task)) task_count += 1;
                            if (std.mem.eql(u8, text.string, &long_followup)) followup_count += 1;
                        }
                    }
                    try std.testing.expect(prepared.value.body.bytes.len > 8192);
                    try std.testing.expectEqual(@as(usize, 1), task_count);
                    try std.testing.expectEqual(@as(usize, 2), followup_count);
                }
                const acquired = try adapter.acquire(context, work.prepared.?);
                if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
                break :blk acquired.captured;
            } else try work.entry.declaration.invoke.?(context, request.value.binding.payload);
            const inference = work.entry.declaration.inference;
            if (inference) model_calls += 1;
            try service.acquire(frame, work, reply);
            if (inference and model_calls == 8 and !restarted) {
                // No interpretation, receipt publication or Kronos successor has
                // run after the raw control response became durable.
                const raw = (try namespace.store.recordBytes(frame, "capture", work.attempt, task)) orelse return error.MissingCapture;
                var capture = try protean.contracts.decodeOwned(CaptureRecord, frame, raw);
                defer capture.deinit();
                try std.testing.expect(capture.value.projection == null);
                try service.close(frame);
                service_live = false;
                try namespace.close();
                namespace_live = false;
                namespace = try native.Namespace.open(a, io, path);
                namespace_live = true;
                service = try native.tasks.Service(t).init(a, io, &namespace, assets, &application, handlers, profile);
                service_live = true;
                var current = try service.task(frame, task);
                defer current.deinit();
                _ = try service.resumeTask(frame, "adaptive-capture-resume", task, current.value.revision);
                restarted = true;
            }
        } else if (step == .waiting) {
            var question = (try service.pendingQuestion(frame, task)) orelse return error.MissingQuestion;
            defer question.deinit();
            _ = try service.respond(frame, "adaptive-recovery-answer", task, question.value.id, question.value.revision, question.value.request_digest, question.value.answer_schema_id.bytes, try native.values.toJson(t.Answer, frame, environment.demo_answer));
        }
    }
    try std.testing.expect(witnessed and finished);
    try std.testing.expectEqual(14, model_calls);
    // Archive validation must release each replay's scratch memory even when
    // the CLI supplies an arena for the enclosing request.
    {
        const execution_limit = budget.limit;
        budget.limit = 32 * 1024 * 1024;
        defer budget.limit = execution_limit;
        var frame_arena = std.heap.ArenaAllocator.init(a);
        defer frame_arena.deinit();
        const archive_path = try std.fmt.allocPrint(permanent, "{s}/completed.archive", .{buffer[0..length]});
        const exported = try service.exportCheckpoint(frame_arena.allocator(), task, archive_path);
        try std.testing.expect(exported.bytes > 0);
    }
    std.debug.print("adaptive capture recovery: model_acquisitions={d} state_bytes_peak={d} prepared_bytes_peak={d} projection_and_step_scratch_peak={d} requested_memory_peak={d}\n", .{ model_calls, maximum_state, maximum_prepared, maximum_scratch, budget.peak });
    try service.close(a);
    service_live = false;
    try namespace.close();
    namespace_live = false;
    try narrowAttemptCeiling(a, io, assets, &application, handlers, configured, buffer[0..length]);
}

fn narrowAttemptCeiling(parent: std.mem.Allocator, io: std.Io, assets: native.discovery.Assets, application: *native.discovery.Application, handlers: native.Registry, original: native.configuration.Admitted, directory: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    var root = (try native.json.parse(a, original.bytes, .{ .bytes = 256 * 1024 })).value;
    try native.json.put(a, root.object.getPtr("adaptive").?, "model_attempts", try native.json.number(a, 1));
    const bytes = try native.json.canonical(a, root);
    const configured = try environment.configure(a, io, .{ .offline = true, .scratch_allocator = parent }, .{ .profile_id = original.id, .profile = bytes, .resources = original.resources }, assets);
    var grants: [environment.handlers.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = configured.id, .runtime_identity = @splat(73), .bytes = configured.bytes, .environment = configured.environment, .resources = configured.resources, .authority = .{ .grants = &grants, .principal = "adaptive-unit", .tenant = "local", .inference = true } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(application.image_identity) };
    const path = try std.fmt.allocPrint(a, "{s}/attempt-ceiling", .{directory});
    var namespace = try native.Namespace.open(parent, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(t).init(parent, io, &namespace, assets, application, handlers, profile);
    defer service.close(parent) catch unreachable;
    const task = (try service.submit(a, "one-attempt", environment.demo_input)).receipt.task;
    var unsent = false;
    for (0..128) |_| {
        var iteration = std.heap.ArenaAllocator.init(parent);
        defer iteration.deinit();
        const frame = iteration.allocator();
        var saved = try service.task(frame, task);
        defer saved.deinit();
        if (unsent and saved.value.blocker == .capacity) {
            try std.testing.expectEqual(1, saved.value.inference_attempts);
            return;
        }
        const step = try service.pump(frame);
        if (step != .work) continue;
        const work = step.work;
        if (work.entry.declaration.inference) {
            try std.testing.expect(!unsent);
            try service.notSent(frame, work);
            var stopped = try service.task(frame, task);
            defer stopped.deinit();
            _ = try service.resumeTask(frame, "retry-with-one-attempt-ceiling", task, stopped.value.revision);
            unsent = true;
        } else {
            var request = try protocol.decode(protocol.Request, frame, work.request);
            defer request.deinit();
            const ctx: native.Context = .{ .allocator = frame, .io = io, .authority = &profile.authority, .task_id = "one-attempt", .profile = profile.bytes, .environment = profile.environment };
            const reply = if (work.entry.declaration.capture) |adapter| (try adapter.acquire(ctx, work.prepared.?)).captured else try work.entry.declaration.invoke.?(ctx, request.value.binding.payload);
            try service.acquire(frame, work, reply);
        }
    }
    return error.MissingAttemptCeiling;
}
