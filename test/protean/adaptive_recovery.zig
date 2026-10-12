//! The actual adaptive image at the captured-before-interpreted boundary.
//! Copied-product admission is covered separately by native_adaptive.mjs.
const std = @import("std");
const protean = @import("protean");
const native = @import("protean_native");
const horos = @import("horos");
const kosmos = @import("kosmos");
const t = @import("adaptive_types");
const environment = @import("adaptive_environment");
const protocol = horos.data.invocation;
const Ref = t.model.ArtifactReference;

const Stage = struct { component: []const u8, operation: ?[]const u8 = null };
fn constructionRecipe(a: std.mem.Allocator, stages: []const Stage) ![]u8 {
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
    var scratch: kosmos.AllocationBudget = .{ .parent = a, .limit = 16 * 1024 * 1024 };
    const task: [16]u8 = @splat(17);
    const product = try engine.construct(a, scratch.allocator(), task, "frozen-policy", encoded_catalog.?, coverage);
    const tool = product.built;
    // Composition size follows the frozen catalog and actual allocation, not
    // the old sixteen-instance matrix. Ten swaps compose to the identity.
    const swaps = try constructionRecipe(a, &(@as([10]Stage, @splat(.{ .component = "swap" }))));
    const many_instances = try engine.build(a, a, catalog.value, swaps);
    try std.testing.expect(swaps.len > 2700);
    const Model = protean.model(.{ .name = "recipe-codec-fixture", .model = "fixture-model", .parameters = .{}, .protocol = struct {
        pub const semantic_identity = t.model.protocol_identity;
    } });
    var invocation = try t.P.templateValue(Model, .{ .items = &.{} }, .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false });
    invocation.tools = t.P.allDeclarations();
    const arguments = try std.json.Stringify.valueAlloc(a, .{ .proposal_json = swaps }, .{});
    const response = try std.json.Stringify.valueAlloc(a, .{.{ .type = "function_call", .status = "completed", .call_id = "large-recipe", .name = "tool_build", .arguments = arguments }}, .{});
    const parsed = try native.json.parse(a, response, .{ .bytes = response.len, .tokens = response.len });
    const normalized = try native.responses.Adapter(t.P).normalize(a, invocation, parsed.value);
    try std.testing.expectEqualStrings(swaps, normalized.output.items.items[0].function_call.decoded_action.decoded.tool_build.proposal_json.bytes);

    // Persistence round-trip keeps the exact image, recipe and task binding.
    var recovered = try protean.contracts.decodeOwned(wire.Program, a, try protean.contracts.encodeOwned(wire.Program, a, product));
    defer recovered.deinit();
    try std.testing.expectEqualSlices(u8, tool.image.bytes, recovered.value.built.image.bytes);
    const schema = try native.values.schemaBytes(t.tool_types.Table, a);
    const input: t.tool_types.Table = .{ .rows = .{ .items = &.{ auditRow(1, 10, 100, 1), auditRow(2, 20, 200, 1), auditRow(3, 30, 300, 2), auditRow(4, 40, 400, 2), auditRow(5, 50, 500, 3) } }, .relation = .{ .items = &.{ auditRow(11, 10, 100, 1), auditRow(12, 20, 201, 1), auditRow(13, 40, 400, 2), auditRow(14, 40, 401, 2), auditRow(15, 90, 1, 3), auditRow(16, 91, 1, 3), auditRow(17, 92, 1, 4) } }, .selected = .{ .items = &.{ 10, 20, 30, 40 } } };
    const admitted_input: wire.Input = .{ .schema = .{ .bytes = schema }, .value = .{ .bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, input) } };
    try std.testing.expectError(error.UnauthorizedProgram, engine.execute(a, a, null, @splat(18), "frozen-policy", encoded_catalog.?, recovered.value, admitted_input));
    try std.testing.expectError(error.UnauthorizedProgram, engine.execute(a, a, null, task, "changed-policy", encoded_catalog.?, recovered.value, admitted_input));
    const first = try engine.execute(a, a, null, task, "frozen-policy", encoded_catalog.?, recovered.value, admitted_input);
    var result = try protean.contracts.decodeOwned(t.tool_types.Table, a, first);
    defer result.deinit();
    try std.testing.expectEqual(4, result.value.rows.items.len);
    const large_rows = try a.alloc(t.tool_types.Row, 40);
    for (large_rows, 0..) |*row, i| row.* = auditRow(@intCast(i), 10, 100, 1);
    const large: t.tool_types.Table = .{ .rows = .{ .items = large_rows }, .relation = input.relation, .selected = input.selected };
    const large_bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, large);
    const unchanged = try engine.run(a, a, null, many_instances, schema, large_bytes);
    try std.testing.expectEqualSlices(u8, large_bytes, unchanged);
    for (result.value.rows.items, [_]u64{ 1, 2, 3, 4 }, 1..) |row, status, id| {
        try std.testing.expectEqual(id, row.id);
        try std.testing.expectEqual(status, row.status);
    }
    const next: t.tool_types.Table = .{ .rows = .{ .items = &.{auditRow(80, 20, 201, 9)} }, .relation = input.relation, .selected = .{ .items = &.{20} } };
    var reused = try protean.contracts.decodeOwned(t.tool_types.Table, a, try engine.execute(a, a, null, task, "frozen-policy", encoded_catalog.?, recovered.value, .{ .schema = .{ .bytes = schema }, .value = .{ .bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, next) } }));
    defer reused.deinit();
    try std.testing.expectEqual(1, reused.value.rows.items.len);
    try std.testing.expectEqual(80, reused.value.rows.items[0].id);
    try std.testing.expectEqual(1, reused.value.rows.items[0].status);
    const reverse = try constructionRecipe(a, &.{ .{ .component = "filter", .operation = "selected" }, .{ .component = "swap" }, .{ .component = "map", .operation = "join" }, .{ .component = "filter", .operation = "orphan" }, .{ .component = "group" } });
    const reverse_tool = try engine.build(a, scratch.allocator(), catalog.value, reverse);
    try std.testing.expect(!std.mem.eql(u8, tool.image.bytes, reverse_tool.image.bytes));
    var grouped = try protean.contracts.decodeOwned(t.tool_types.Table, a, try engine.run(a, a, null, reverse_tool, schema, try protean.contracts.encodeOwned(t.tool_types.Table, a, input)));
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
    try std.testing.expectError(error.InvalidDerivation, engine.execute(a, a, null, task, "frozen-policy", encoded_catalog.?, substituted, admitted_input));
    try std.testing.expectError(error.IncompatibleInterface, engine.run(a, a, null, tool, try native.values.schemaBytes(bool, a), admitted_input.value.bytes));
    try std.testing.expectError(error.OutOfMemory, engine.run(a, std.testing.failing_allocator, null, tool, schema, admitted_input.value.bytes));
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, engine.run(a, a, &cancelled, tool, schema, admitted_input.value.bytes));
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
    reconciliation: ?[32]u8,
};

test "adaptive unload capture recovers under its original plan without another acquisition" {
    try adaptiveRecovery(false, .none);
}

test "adaptive report correction preserves acquired evidence and retains a large complete report" {
    try adaptiveRecovery(true, .none);
}

test "adaptive snapshot reconciliation preserves unknown history and settles once after restart" {
    try adaptiveRecovery(false, .snapshot);
}

test "adaptive provider without receipt retrieval remains unresolved" {
    try adaptiveRecovery(false, .provider);
}

test "adaptive malformed capture remains private and portable without claiming settlement" {
    try adaptiveRecovery(false, .malformed);
}

fn adaptiveRecovery(comptime correction: bool, comptime recovery_probe: enum { none, snapshot, provider, malformed }) !void {
    var budget: kosmos.AllocationBudget = .{ .parent = std.testing.allocator, .limit = 64 * 1024 * 1024 };
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
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
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
    var last_model_capture: ?[32]u8 = null;
    var restarted = false;
    var witnessed = false;
    var finished = false;
    var maximum_state: u64 = 0;
    var maximum_prepared: usize = 0;
    var maximum_scratch: usize = 0;
    for (0..512) |_| {
        var scratch: kosmos.AllocationBudget = .{ .parent = a, .limit = 64 * 1024 * 1024 };
        var arena = std.heap.ArenaAllocator.init(scratch.allocator());
        defer arena.deinit();
        defer maximum_scratch = @max(maximum_scratch, scratch.peak);
        const frame = arena.allocator();
        var saved = try service.task(frame, task);
        defer saved.deinit();
        maximum_state = @max(maximum_state, saved.value.checkpoint.bytes);
        if (saved.value.terminal()) {
            try std.testing.expect(saved.value.outcome_kind == .completed);
            const result = try namespace.store.object(frame, saved.value.result.?, null);
            var output = try protean.contracts.decodeOwned(t.Output, frame, result);
            defer output.deinit();
            try std.testing.expect(output.value.result == .report);
            try std.testing.expectEqual(@as(u64, if (correction) 16 else 14), output.value.model_calls);
            if (correction) {
                try std.testing.expect(result.len > (native.protocol.Limits{}).inline_bytes);
                try std.testing.expectEqual(@as(usize, 70 * 1024), output.value.result.report.summary.bytes.len);
                try std.testing.expectEqual(@as(usize, 2), output.value.evidence.items.len);
                try std.testing.expectEqual(@as(usize, 3), output.value.result.report.claims.items.len);
                try std.testing.expectEqualSlices(u64, &.{ 0, 1 }, output.value.result.report.claims.items[0].evidence_indices.items);
                try std.testing.expectEqual(@as(u64, 6), output.value.work_calls);
                try std.testing.expectEqualStrings("src/main.zig", output.value.evidence.items[0].source.path.bytes);
                try std.testing.expectEqualStrings("src/main.zig", output.value.evidence.items[1].source.path.bytes);
                try std.testing.expectEqual(@as(u64, 32), output.value.evidence.items[1].source.end);
                var client: native.client.Client(t) = .{ .service = &service };
                var params = native.json.object();
                try native.json.put(frame, &params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task, .lower))));
                const exposed = try client.call(frame, .@"task.result", params);
                const outcome = native.json.get(exposed, "outcome").?;
                try std.testing.expect(native.json.get(outcome, "value") == null);
                try std.testing.expect(native.json.get(outcome, "value_ref") != null);
            }
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
                if (correction and work.entry.declaration.inference and model_calls >= 13) {
                    if (model_calls == 15) {
                        var prepared = try protean.contracts.decodeOwned(t.P.AdaptivePrepared, frame, work.prepared.?);
                        defer prepared.deinit();
                        const prior = prepared.value.request.results.items;
                        try std.testing.expectEqual(@as(usize, 1), prior.len);
                        try std.testing.expectEqualStrings("report-14", prior[0].call_id.bytes);
                        const rejection_json = (try native.json.parse(frame, prior[0].output.bytes, .{})).value;
                        const rejection = try native.values.fromJson(t.ReportRejection, frame, rejection_json);
                        try std.testing.expectEqualDeep(t.ReportRejection{ .reason = .out_of_range, .claim_index = 0, .evidence_position = 1 }, rejection);
                    }
                    const name = if (model_calls == 13) "read" else "report";
                    const arguments = if (model_calls == 13)
                        "{\"path\":\"src/main.zig\",\"start\":0,\"maximum\":32}"
                    else if (model_calls == 14)
                        "{\"summary\":\"Invalid citation\",\"claims\":[{\"kind\":\"observation\",\"statement\":\"Observed\",\"reasoning\":\"\",\"evidence_indices\":[0,2]}],\"limitations\":[]}"
                    else blk_args: {
                        const summary = try frame.alloc(u8, 70 * 1024);
                        @memset(summary, 'S');
                        break :blk_args try std.json.Stringify.valueAlloc(frame, .{ .summary = summary, .claims = .{
                            .{ .kind = "observation", .statement = "Both ranges are retained.", .reasoning = "", .evidence_indices = .{ 0, 1 } },
                            .{ .kind = "inference", .statement = "The ranges overlap.", .reasoning = "Both begin at offset zero.", .evidence_indices = .{1} },
                            .{ .kind = "hypothesis", .statement = "Other files may differ.", .reasoning = "They were not inspected.", .evidence_indices = .{} },
                        }, .limitations = .{"No entailment proof is claimed."} }, .{});
                    };
                    const call = try std.fmt.allocPrint(frame, "report-{d}", .{model_calls});
                    const provider = try std.json.Stringify.valueAlloc(frame, .{ .id = call, .status = "completed", .@"error" = @as(?u8, null), .output = .{.{ .type = "function_call", .status = "completed", .call_id = call, .name = name, .arguments = arguments }} }, .{});
                    break :blk try protean.contracts.encodeOwned(native.responses.Raw, frame, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = provider } });
                }
                const acquired = try adapter.acquire(context, work.prepared.?);
                if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
                break :blk acquired.captured;
            } else try work.entry.declaration.invoke.?(context, request.value.binding.payload);
            const inference = work.entry.declaration.inference;
            if (recovery_probe == .malformed and inference) {
                const malformed = "invalid response framing";
                try service.acquire(frame, work, malformed);
                _ = try service.pump(frame);
                var rejected_task = try service.task(frame, task);
                defer rejected_task.deinit();
                try std.testing.expectEqual(native.tasks.Status.blocked, try service.status(frame, rejected_task.value));
                const State = native.testing.state;
                var retained = try protean.contracts.decodeOwned(State.Capture, frame, (try namespace.store.recordBytes(frame, "capture", work.attempt, task)).?);
                defer retained.deinit();
                try std.testing.expect(retained.value.projection == null);
                try std.testing.expectEqualSlices(u8, malformed, try namespace.store.object(frame, retained.value.response.?, null));
                const archive_path = try std.fmt.allocPrint(frame, "{s}/malformed.agnx", .{buffer[0..length]});
                _ = try service.exportCheckpoint(frame, task, archive_path);
                try service.close(frame);
                service_live = false;
                try namespace.close();
                namespace_live = false;
                const target = try std.fmt.allocPrint(frame, "{s}/malformed-import", .{buffer[0..length]});
                var destination = try native.Namespace.open(a, io, target);
                defer destination.close() catch unreachable;
                var imported = try native.tasks.Service(t).init(a, io, &destination, assets, &application, handlers, profile);
                defer imported.close(frame) catch unreachable;
                _ = try imported.importCheckpoint(frame, "import-malformed", archive_path);
                try std.testing.expect((try imported.pump(frame)) == .idle);
                var copied_task = try imported.task(frame, task);
                defer copied_task.deinit();
                _ = try imported.resumeTask(frame, "interpret-malformed", task, copied_task.value.revision);
                _ = try imported.pump(frame);
                var still_blocked = try imported.task(frame, task);
                defer still_blocked.deinit();
                try std.testing.expectEqual(native.tasks.Status.blocked, try imported.status(frame, still_blocked.value));
                try std.testing.expectEqual(rejected_task.value.inference_attempts, still_blocked.value.inference_attempts);
                try std.testing.expectEqual(rejected_task.value.inference_request_bytes, still_blocked.value.inference_request_bytes);
                try std.testing.expectEqual(rejected_task.value.inference_output_tokens, still_blocked.value.inference_output_tokens);
                var untouched = try protean.contracts.decodeOwned(State.Capture, frame, (try destination.store.recordBytes(frame, "capture", work.attempt, task)).?);
                defer untouched.deinit();
                try std.testing.expectEqualDeep(retained.value, untouched.value);
                try std.testing.expectError(error.ArtifactUnavailable, imported.projectedArtifact(frame, task, retained.value.response.?.digest));
                const second_archive = try std.fmt.allocPrint(frame, "{s}/still-malformed.agnx", .{buffer[0..length]});
                // The broader archive domain must still reject contradictory
                // occurrence/capture facts, even when every object hashes.
                var occurrence_record = try protean.contracts.decodeOwned(native.testing.occurrence.Occurrence, frame, (try destination.store.recordBytes(frame, "occurrence", work.occurrence, task)).?);
                defer occurrence_record.deinit();
                var contradictory = occurrence_record.value;
                contradictory.state = .{ .unknown = .{ .id = work.attempt } };
                destination.store.invalidateIntegrity();
                try destination.store.begin();
                try destination.store.putRecord(native.testing.occurrence.Occurrence, "occurrence", work.occurrence, task, contradictory);
                try destination.commit("test.contradictory-capture");
                try std.testing.expectError(error.CorruptState, imported.exportCheckpoint(frame, task, second_archive));
                try destination.store.begin();
                try destination.store.putRecord(native.testing.occurrence.Occurrence, "occurrence", work.occurrence, task, occurrence_record.value);
                try destination.commit("test.restore-captured-occurrence");
                _ = try imported.exportCheckpoint(frame, task, second_archive);
                return;
            }
            if ((recovery_probe == .snapshot and work.entry.declaration.recovery != null) or (recovery_probe == .provider and inference)) {
                const occurrence_id = work.occurrence;
                const attempt_id = work.attempt;
                try service.unknown(frame, work);
                try service.close(frame);
                service_live = false;
                try namespace.close();
                namespace_live = false;
                namespace = try native.Namespace.open(a, io, path);
                namespace_live = true;
                service = try native.tasks.Service(t).init(a, io, &namespace, assets, &application, handlers, profile);
                service_live = true;
                const before = namespace.store.head;
                if (recovery_probe == .provider) {
                    try std.testing.expectError(error.UnsupportedRecovery, service.rederiveUnknown(frame, task, occurrence_id, attempt_id));
                } else {
                    const derived = try service.rederiveUnknown(frame, task, occurrence_id, attempt_id);
                    try std.testing.expect(derived == .capture);
                    try std.testing.expectEqualSlices(u8, reply, derived.capture);
                }
                try std.testing.expectEqualDeep(before, namespace.store.head);
                var unchanged = try service.task(frame, task);
                defer unchanged.deinit();
                try std.testing.expectEqual(saved.value.inference_attempts + @intFromBool(inference), unchanged.value.inference_attempts);
                try std.testing.expectError(error.UnsettledOccurrence, service.resumeTask(frame, "recovery-does-not-settle", task, unchanged.value.revision));
                var stale = attempt_id;
                stale[0] ^= 1;
                try std.testing.expectError(error.StaleOccurrence, service.rederiveUnknown(frame, task, occurrence_id, stale));
                const revision = unchanged.value.revision;
                var client: native.client.Client(t) = .{ .service = &service };
                var legacy_client: native.client.Client(t) = .{ .service = &service, .protocol_version = .v2_0 };
                var status_params = native.json.object();
                try native.json.put(frame, &status_params, "task_id", native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task, .lower))));
                const status = try client.call(frame, .@"task.status", status_params);
                const availability = status.object.get("recovery").?;
                try std.testing.expectEqual(if (recovery_probe == .provider) @as(usize, 0) else 1, availability.object.get("mechanisms").?.array.items.len);
                try std.testing.expect(!(try legacy_client.call(frame, .@"task.status", status_params)).object.contains("recovery"));
                var params = try native.json.copy(frame, status_params);
                try native.json.put(frame, &params, "client_operation_id", native.json.string("recover-original"));
                try native.json.put(frame, &params, "expected_revision", native.json.string(try std.fmt.allocPrint(frame, "{d}", .{revision})));
                try native.json.put(frame, &params, "occurrence_id", availability.object.get("occurrence_id").?);
                try native.json.put(frame, &params, "attempt_id", availability.object.get("attempt_id").?);
                try native.json.put(frame, &params, "recovery", (try native.json.parse(frame, "{\"mechanism\":\"rederive\"}", .{})).value);
                try std.testing.expectError(error.UnsupportedCapability, legacy_client.call(frame, .@"task.reconcile", params));
                var forged = try native.json.copy(frame, params);
                try native.json.put(frame, forged.object.getPtr("recovery").?, "safe_to_retry", .{ .bool = true });
                try std.testing.expectError(error.InvalidParams, client.call(frame, .@"task.reconcile", forged));
                try std.testing.expectEqualDeep(before, namespace.store.head);
                const public_admission = try client.call(frame, .@"task.reconcile", params);
                try std.testing.expect(!public_admission.object.get("replayed").?.bool);
                const public_recovery = public_admission.object.get("reconciliation").?;
                try std.testing.expectEqualStrings(if (recovery_probe == .provider) "unresolved" else "capture_admitted", public_recovery.object.get("status").?.string);
                try std.testing.expectEqual(8, public_recovery.object.count());
                const admitted = try service.reconcile(frame, "recover-original", task, revision, occurrence_id, attempt_id, .rederive);
                const reconciliation_id = admitted.receipt.reconciliation.?;
                const committed = namespace.store.head;
                const replayed = try service.reconcile(frame, "recover-original", task, revision, occurrence_id, attempt_id, .rederive);
                try std.testing.expect(replayed.replayed);
                try std.testing.expectEqualDeep(admitted.receipt.id, replayed.receipt.id);
                try std.testing.expectEqualDeep(committed, namespace.store.head);
                try std.testing.expectError(error.OperationConflict, service.reconcile(frame, "recover-original", task, revision + 1, occurrence_id, attempt_id, .rederive));
                const State = native.testing.state;
                var recorded = try protean.contracts.decodeOwned(State.Reconciliation, frame, (try namespace.store.recordBytes(frame, "reconciliation", reconciliation_id, task)).?);
                defer recorded.deinit();
                try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(frame, task, recorded.value.original_occurrence.digest));
                try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(frame, task, recorded.value.original_attempt.digest));
                try std.testing.expect(recorded.value.provenance == (if (recovery_probe == .provider) .none else .rederived));
                var history_params = try native.json.copy(frame, status_params);
                try native.json.put(frame, &history_params, "after_seq", native.json.string("0"));
                try std.testing.expectError(error.UnsupportedCapability, legacy_client.call(frame, .@"task.subscribe", history_params));
                try native.json.put(frame, &history_params, "limit", try native.json.number(frame, 128));
                try std.testing.expectError(error.UnsupportedCapability, legacy_client.call(frame, .@"task.events", history_params));
                // Export at the actual unresolved/capture-admitted boundary.
                // Import preserves private evidence and stays parked; it never
                // acquires again or claims an uninterpreted response is settled.
                {
                    const unresolved_archive = try std.fmt.allocPrint(frame, "{s}/unsettled.agnx", .{buffer[0..length]});
                    _ = try service.exportCheckpoint(frame, task, unresolved_archive);
                    try service.close(frame);
                    service_live = false;
                    try namespace.close();
                    namespace_live = false;
                    const copy_path = try std.fmt.allocPrint(frame, "{s}/unsettled-import", .{buffer[0..length]});
                    var copy_namespace = try native.Namespace.open(a, io, copy_path);
                    defer copy_namespace.close() catch unreachable;
                    var copy = try native.tasks.Service(t).init(a, io, &copy_namespace, assets, &application, handlers, profile);
                    defer copy.close(frame) catch unreachable;
                    _ = try copy.importCheckpoint(frame, "import-unsettled", unresolved_archive);
                    try std.testing.expect((try copy.pump(frame)) == .idle);
                    const replay = try copy.reconcile(frame, "recover-original", task, revision, occurrence_id, attempt_id, .rederive);
                    try std.testing.expect(replay.replayed);
                    try std.testing.expectEqualDeep(admitted.receipt, replay.receipt);
                    var copied = try copy.task(frame, task);
                    defer copied.deinit();
                    try std.testing.expect(copied.value.schedule == .parked);
                    try std.testing.expectEqual(unchanged.value.inference_attempts, copied.value.inference_attempts);
                    try std.testing.expectEqual(unchanged.value.inference_request_bytes, copied.value.inference_request_bytes);
                    var observation = try copy.reconciliation(frame, task, reconciliation_id);
                    defer observation.deinit();
                    try std.testing.expectEqualDeep(recorded.value, observation.value);
                    try std.testing.expectError(error.ArtifactUnavailable, copy.projectedArtifact(frame, task, recorded.value.original_occurrence.digest));
                    try std.testing.expectError(error.ArtifactUnavailable, copy.projectedArtifact(frame, task, recorded.value.original_attempt.digest));
                    if (recorded.value.prepared) |prepared| try std.testing.expectError(error.ArtifactUnavailable, copy.projectedArtifact(frame, task, prepared.digest));
                    if (recovery_probe == .provider) {
                        try std.testing.expectError(error.UnsettledOccurrence, copy.resumeTask(frame, "cannot-retry-import", task, copied.value.revision));
                    } else {
                        const capture = recorded.value.outcome.capture_admitted;
                        try std.testing.expectError(error.ArtifactUnavailable, copy.projectedArtifact(frame, task, capture.digest));
                        try std.testing.expectEqualSlices(u8, reply, try copy_namespace.store.object(frame, capture, null));
                        _ = try copy.resumeTask(frame, "interpret-import", task, copied.value.revision);
                        try std.testing.expect((try copy.pump(frame)) == .progressed);
                        var interpreted = try copy.reconciliation(frame, task, reconciliation_id);
                        defer interpreted.deinit();
                        try std.testing.expect(interpreted.value.outcome == .reply_settled);
                        try std.testing.expect(interpreted.value.previous != null);
                    }
                }
                namespace = try native.Namespace.open(a, io, path);
                namespace_live = true;
                service = try native.tasks.Service(t).init(a, io, &namespace, assets, &application, handlers, profile);
                service_live = true;
                if (recovery_probe == .provider) {
                    try std.testing.expect(recorded.value.outcome == .unresolved);
                    try std.testing.expectError(error.UnsettledOccurrence, service.resumeTask(frame, "unresolved-cannot-resume", task, admitted.receipt.revision));
                } else {
                    try std.testing.expect(recorded.value.outcome == .capture_admitted);
                    try std.testing.expectError(error.ArtifactUnavailable, service.projectedArtifact(frame, task, recorded.value.outcome.capture_admitted.digest));
                    try std.testing.expectEqualSlices(u8, reply, try namespace.store.object(frame, recorded.value.outcome.capture_admitted, null));
                    var original_task = try service.task(frame, task);
                    defer original_task.deinit();
                    _ = try service.resumeTask(frame, "interpret-original", task, original_task.value.revision);
                    _ = try service.pump(frame);
                    var settled = try protean.contracts.decodeOwned(State.Reconciliation, frame, (try namespace.store.recordBytes(frame, "reconciliation", reconciliation_id, task)).?);
                    defer settled.deinit();
                    try std.testing.expect(settled.value.outcome == .reply_settled);
                    try std.testing.expect(settled.value.previous != null);
                    try std.testing.expectEqualDeep(recorded.value.original_occurrence, settled.value.original_occurrence);
                    const archive_path = try std.fmt.allocPrint(frame, "{s}/rederived.agnx", .{buffer[0..length]});
                    _ = try service.exportCheckpoint(frame, task, archive_path);
                    try service.close(frame);
                    service_live = false;
                    try namespace.close();
                    namespace_live = false;
                    const target = try std.fmt.allocPrint(frame, "{s}/rederived-import", .{buffer[0..length]});
                    var destination = try native.Namespace.open(a, io, target);
                    defer destination.close() catch unreachable;
                    var imported = try native.tasks.Service(t).init(a, io, &destination, assets, &application, handlers, profile);
                    defer imported.close(frame) catch unreachable;
                    _ = try imported.importCheckpoint(frame, "import-rederived", archive_path);
                    try std.testing.expect((try imported.reconcile(frame, "recover-original", task, revision, occurrence_id, attempt_id, .rederive)).replayed);
                    var imported_task = try imported.task(frame, task);
                    defer imported_task.deinit();
                    try std.testing.expectEqual(unchanged.value.inference_attempts, imported_task.value.inference_attempts);
                    try std.testing.expectEqual(unchanged.value.inference_request_bytes, imported_task.value.inference_request_bytes);
                    try std.testing.expectError(error.ArtifactUnavailable, imported.projectedArtifact(frame, task, recorded.value.original_occurrence.digest));
                    // Retaining the reply and raw capture cannot excuse losing
                    // the recovery operation and its original ambiguous history.
                    destination.store.invalidateIntegrity();
                    try destination.store.begin();
                    try destination.store.database.run("DELETE FROM records WHERE kind='reconciliation' AND id=?", &.{.{ .blob = &reconciliation_id }});
                    try std.testing.expectEqual(1, try destination.store.database.changes());
                    try std.testing.expectError(error.CorruptState, destination.store.auditRetention(handlers, application.image_identity));
                    destination.store.rollback();
                    return;
                }
                try service.close(frame);
                service_live = false;
                try namespace.close();
                namespace_live = false;
                namespace = try native.Namespace.open(a, io, path);
                namespace_live = true;
                service = try native.tasks.Service(t).init(a, io, &namespace, assets, &application, handlers, profile);
                service_live = true;
                try std.testing.expect((try service.reconcile(frame, "recover-original", task, revision, occurrence_id, attempt_id, .rederive)).replayed);
                var recovered_task = try service.task(frame, task);
                defer recovered_task.deinit();
                try std.testing.expectEqual(unchanged.value.inference_attempts, recovered_task.value.inference_attempts);
                try std.testing.expectEqual(unchanged.value.inference_request_bytes, recovered_task.value.inference_request_bytes);
                return;
            }
            if (inference) model_calls += 1;
            try service.acquire(frame, work, reply);
            if (inference) last_model_capture = work.attempt;
            if (inference and model_calls == 8 and !restarted) {
                // No interpretation, receipt publication or Kosmos successor has
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
    try std.testing.expectEqual(@as(usize, if (correction) 16 else 14), model_calls);
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
    if (correction) {
        // Keep every object byte intact while dropping one registered context
        // dependency. Reopen must reconstruct that edge from the exact codec,
        // rather than treating the truncated metadata as proof of closure.
        const raw = (try namespace.store.recordBytes(permanent, "capture", last_model_capture.?, task)).?;
        var captured = try protean.contracts.decodeOwned(CaptureRecord, permanent, raw);
        defer captured.deinit();
        const objects = captured.value.projection.?.objects.items;
        const root = objects[objects.len - 1];
        var context = try protean.contracts.decodeOwned(t.P.AdaptiveContext, permanent, try namespace.store.object(permanent, .{ .digest = root.digest, .bytes = root.bytes }, null));
        defer context.deinit();
        try std.testing.expectEqualStrings(t.P.adaptive_context_identity, context.value.schema.bytes);
        namespace.store.invalidateIntegrity();
        try namespace.store.begin();
        try namespace.store.database.run("DELETE FROM dependencies WHERE parent=? AND child=?", &.{ .{ .blob = &root.digest }, .{ .blob = &context.value.source_capture.digest } });
        try std.testing.expectEqual(1, try namespace.store.database.changes());
        try namespace.commit("test.missing-context-dependency");
    }
    try namespace.close();
    namespace_live = false;
    if (correction) {
        namespace = try native.Namespace.open(a, io, path);
        namespace_live = true;
        try std.testing.expectError(error.CorruptState, native.tasks.Service(t).init(a, io, &namespace, assets, &application, handlers, profile));
        try std.testing.expect(namespace.store.fenced);
    }
    if (!correction) try continuedAttemptAccounting(a, io, assets, &application, handlers, configured, buffer[0..length]);
}

fn continuedAttemptAccounting(parent: std.mem.Allocator, io: std.Io, assets: native.discovery.Assets, application: *native.discovery.Application, handlers: native.Registry, original: native.configuration.Admitted, directory: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    const configured = try environment.configure(a, io, .{ .offline = true, .scratch_allocator = parent }, .{ .profile_id = original.id, .profile = original.bytes, .resources = original.resources }, assets);
    var grants: [environment.handlers.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = configured.id, .runtime_identity = @splat(73), .bytes = configured.bytes, .environment = configured.environment, .resources = configured.resources, .authority = .{ .grants = &grants, .principal = "adaptive-unit", .tenant = "local", .inference = true } };
    for (&grants, handlers.entries) |*grant, entry| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
    const path = try std.fmt.allocPrint(a, "{s}/attempt-accounting", .{directory});
    var namespace = try native.Namespace.open(parent, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(t).init(parent, io, &namespace, assets, application, handlers, profile);
    defer service.close(parent) catch unreachable;
    const task = (try service.submit(a, "continued-attempts", environment.demo_input)).receipt.task;
    var unsent: u64 = 0;
    for (0..128) |_| {
        var iteration = std.heap.ArenaAllocator.init(parent);
        defer iteration.deinit();
        const frame = iteration.allocator();
        var saved = try service.task(frame, task);
        defer saved.deinit();
        const step = try service.pump(frame);
        if (step != .work) continue;
        const work = step.work;
        if (work.entry.declaration.inference) {
            try std.testing.expectEqual(unsent + 1, (try service.task(frame, task)).value.inference_attempts);
            if (unsent == 17) {
                try std.testing.expectEqual(18, try namespace.store.capabilityAttempts(task, t.P.adaptive_identity));
                try service.notSent(frame, work);
                return;
            }
            try service.notSent(frame, work);
            var stopped = try service.task(frame, task);
            defer stopped.deinit();
            _ = try service.resumeTask(frame, try std.fmt.allocPrint(frame, "retry-{d}", .{unsent}), task, stopped.value.revision);
            unsent += 1;
        } else {
            var request = try protocol.decode(protocol.Request, frame, work.request);
            defer request.deinit();
            const ctx: native.Context = .{ .allocator = frame, .io = io, .authority = &profile.authority, .task_id = "continued-attempts", .profile = profile.bytes, .environment = profile.environment };
            const reply = if (work.entry.declaration.capture) |adapter| (try adapter.acquire(ctx, work.prepared.?)).captured else try work.entry.declaration.invoke.?(ctx, request.value.binding.payload);
            try service.acquire(frame, work, reply);
        }
    }
    return error.MissingContinuedAttempts;
}
