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
const expectCleanup = @import("native_test_support.zig").cleanup;

// Provider arguments use JSON integers; the client value codec deliberately
// renders full-width integers as strings. Preserve that contract distinction.
inline fn modelArguments(comptime T: type, a: std.mem.Allocator, value: T) !native.json.Value {
    if (@typeInfo(T) == .int) return native.json.number(a, value);
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "protean_value_kind")) {
        if (T.protean_value_kind == .vector) {
            var array: native.json.Value = .{ .array = .init(a) };
            for (value.items) |item| try array.array.append(try modelArguments(T.Child, a, item));
            return array;
        }
        return native.values.toJson(T, a, value);
    }
    var result = try native.values.toJson(T, a, value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Child| {
            try native.json.put(
                a,
                &result,
                name,
                try modelArguments(Child, a, @field(value, name)),
            );
        },
        .@"union" => switch (value) {
            inline else => |child| try native.json.put(
                a,
                &result,
                "value",
                try modelArguments(@TypeOf(child), a, child),
            ),
        },
        else => {},
    }
    return result;
}

const Stage = struct { component: []const u8, operation: ?[]const u8 = null };
fn constructionRecipe(a: std.mem.Allocator, stages: []const Stage) ![]u8 {
    var instances: std.ArrayList(@FieldType(wire.Recipe, "instances").Child) = .empty;
    var bindings: std.ArrayList(@FieldType(wire.Recipe, "bindings").Child) = .empty;
    for (stages, 0..) |stage, i| {
        const key = try std.fmt.allocPrint(a, "stage{d}", .{i});
        try instances.append(
            a,
            .{ .key = .{ .bytes = key }, .component_id = .{ .bytes = stage.component } },
        );
        if (stage.operation) |operation| {
            const operation_key = try std.fmt.allocPrint(a, "operation{d}", .{i});
            try instances.append(
                a,
                .{ .key = .{ .bytes = operation_key }, .component_id = .{ .bytes = operation } },
            );
            try bindings.append(
                a,
                .{
                    .required = .{
                        .instance = .{ .bytes = key },
                        .symbol = .{
                            .bytes = if (std.mem.eql(u8, stage.component, "map")) "row" else "keep",
                        },
                    },
                    .supplied = .{
                        .instance = .{ .bytes = operation_key },
                        .symbol = .{ .bytes = "apply" },
                    },
                },
            );
        }
        if (i + 1 < stages.len)
            try appendRecipeComposition(a, stages, i, key, &instances, &bindings);
    }
    const recipe: wire.Recipe = .{
        .instances = .{ .items = instances.items },
        .bindings = .{ .items = bindings.items },
        .entry = .{
            .instance = .{ .bytes = if (stages.len == 1) "stage0" else "compose0" },
            .symbol = .{ .bytes = "apply" },
        },
    };
    return native.json.canonical(a, try native.values.toJson(wire.Recipe, a, recipe));
}

fn auditRow(id: u64, key: u64, value: u64, group: u64) t.tool_types.Row {
    return .{
        .id = id,
        .key = key,
        .value = value,
        .group = group,
        .matches = 0,
        .match_id = 0,
        .mismatches = 0,
        .status = 0,
    };
}

const wire = protean.contracts.tool_construction;
const engine = native.tool_construction;
const catalog_task: [16]u8 = @splat(17);
const catalog_input: t.tool_types.Table = .{
    .rows = .{
        .items = &.{
            auditRow(1, 10, 100, 1),
            auditRow(2, 20, 200, 1),
            auditRow(3, 30, 300, 2),
            auditRow(4, 40, 400, 2),
            auditRow(5, 50, 500, 3),
        },
    },
    .relation = .{
        .items = &.{
            auditRow(11, 10, 100, 1),
            auditRow(12, 20, 201, 1),
            auditRow(13, 40, 400, 2),
            auditRow(14, 40, 401, 2),
            auditRow(15, 90, 1, 3),
            auditRow(16, 91, 1, 3),
            auditRow(17, 92, 1, 4),
        },
    },
    .selected = .{ .items = &.{ 10, 20, 30, 40 } },
};

fn catalogBytes(a: std.mem.Allocator) ![]const u8 {
    const metadata = (try native.json.parse(
        a,
        @embedFile("adaptive_application"),
        .{ .bytes = 1024 * 1024 },
    )).value;
    var encoded_catalog: ?[]const u8 = null;
    for ((native.json.get(
        metadata,
        "resources",
    ) orelse return error.MissingCatalog).array.items) |resource| {
        if (std.mem.eql(
            u8,
            try native.json.text(native.json.get(resource, "id").?),
            "tool-construction.catalog",
        )) encoded_catalog = (try native.values.fromJson(
            protean.contracts.Bytes(128 * 1024),
            a,
            native.json.get(resource, "base64url").?,
        )).bytes;
    }
    return encoded_catalog orelse error.MissingCatalog;
}

fn checkLargeRecipe(a: std.mem.Allocator, catalog: wire.Catalog) !wire.Built {
    // Composition size follows the frozen catalog and actual allocation, not
    // the old sixteen-instance matrix. Ten swaps compose to the identity.
    const swaps = try constructionRecipe(a, &(@as([10]Stage, @splat(.{ .component = "swap" }))));
    const many_instances = try engine.build(a, a, catalog, swaps);
    try std.testing.expect(swaps.len > 2700);
    const Model = protean.model(
        .{
            .name = "recipe-codec-fixture",
            .model = "fixture-model",
            .parameters = .{},
            .protocol = struct {
                pub const semantic_identity = t.model.protocol_identity;
            },
        },
    );
    var invocation = try t.P.templateValue(
        Model,
        .{ .items = &.{} },
        .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false },
    );
    invocation.tools = t.P.allDeclarations();
    const arguments = try std.json.Stringify.valueAlloc(
        a,
        .{
            .command = .{
                .tag = "build",
                .value = .{
                    .source = .{ .tag = "json_text", .value = swaps },
                    .source_kind = "component_recipe",
                    .exposures = .{},
                    .role = "computation",
                },
            },
        },
        .{},
    );
    const response = try std.json.Stringify.valueAlloc(
        a,
        .{
            .{
                .type = "function_call",
                .status = "completed",
                .call_id = "large-recipe",
                .name = "program",
                .arguments = arguments,
            },
        },
        .{},
    );
    const parsed = try native.json.parse(
        a,
        response,
        .{ .bytes = response.len, .tokens = response.len },
    );
    const normalized = try native.responses.OutputNormalizer(t.P).normalize(
        a,
        invocation,
        parsed.value,
    );
    const action = normalized.output.items.items[0].function_call.decoded_action.decoded;
    try std.testing.expectEqualStrings(swaps, action.program.command.build.source.json_text.bytes);

    return many_instances;
}

fn checkCatalogRejections(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    catalog: wire.Catalog,
) !void {
    try std.testing.expectError(
        error.InvalidParams,
        engine.build(
            a,
            scratch,
            catalog,
            "{\"instances\":[],\"bindings\":[],\"entry\":{\"instance\":\"x\"," ++
                "\"symbol\":\"apply\"},\"pure\":true}",
        ),
    );
    try std.testing.expectError(
        error.UnknownComponent,
        engine.build(
            a,
            scratch,
            catalog,
            "{\"instances\":[{\"key\":\"x\",\"component_id\":\"not-approved\"}" ++
                "],\"bindings\":[],\"entry\":{\"instance\":\"x\",\"symbol\":\"appl" ++
                "y\"}}",
        ),
    );
    try std.testing.expectError(
        error.IncompatibleInterface,
        engine.build(
            a,
            scratch,
            catalog,
            try constructionRecipe(a, &.{.{ .component = "filter", .operation = "swap" }}),
        ),
    );
    try std.testing.expectError(
        error.CyclicComposition,
        engine.build(
            a,
            scratch,
            catalog,
            "{\"instances\":[{\"key\":\"x\",\"component_id\":\"compose\"}],\"b" ++
                "indings\":[{\"required\":{\"instance\":\"x\",\"symbol\":\"first\"" ++
                "},\"supplied\":{\"instance\":\"x\",\"symbol\":\"apply\"}}],\"entr" ++
                "y\":{\"instance\":\"x\",\"symbol\":\"apply\"}}",
        ),
    );
}

fn checkForbiddenCatalog(a: std.mem.Allocator, catalog: wire.Catalog) !void {
    // Add a valid but unreachable external declaration to an actual component.
    // Pure admission rejects the declaration even though the entry never uses it.
    var component = try horos.data.component.decode(a, catalog.items[7].object.bytes);
    defer component.deinit();
    var forbidden = component.object;
    var unit: ?u64 = null;
    for (forbidden.program.schemas, 0..) |shape, i| if (shape == .unit) {
        unit = @intCast(i);
        break;
    };
    const external = [_]horos.data.program.Effect{
        .{
            .identity = "forbidden.external",
            .payload = unit.?,
            .result = unit.?,
            .external = true,
        },
    };
    forbidden.program.effects = &external;
    const forbidden_bytes = try a.alloc(u8, try horos.data.component.encodedLength(forbidden));
    _ = try horos.data.component.encode(a, forbidden, forbidden_bytes);
    try std.testing.expectError(
        error.ForbiddenEffect,
        engine.validateCatalog(
            a,
            .{
                .items = &.{
                    .{ .id = .{ .bytes = "swap" }, .object = .{ .bytes = forbidden_bytes } },
                },
            },
        ),
    );
}

fn checkExecutionFailures(
    a: std.mem.Allocator,
    encoded_catalog: []const u8,
    product: wire.Program,
    admitted_input: wire.Input,
    schema: []const u8,
    original_tool: wire.Built,
) !void {
    const task = catalog_task;
    const tool = original_tool;
    var substituted = product;
    const altered = try a.dupe(u8, substituted.built.image.bytes);
    altered[0] ^= 1;
    substituted.built.image.bytes = altered;
    try std.testing.expectError(
        error.InvalidDerivation,
        engine.execute(
            a,
            a,
            null,
            task,
            "frozen-policy",
            encoded_catalog,
            substituted,
            admitted_input,
        ),
    );
    try std.testing.expectError(
        error.IncompatibleInterface,
        engine.run(
            a,
            a,
            null,
            tool,
            try native.values.schemaBytes(bool, a),
            admitted_input.value.bytes,
        ),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        engine.run(
            a,
            std.testing.failing_allocator,
            null,
            tool,
            schema,
            admitted_input.value.bytes,
        ),
    );
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(
        error.Canceled,
        engine.run(a, a, &cancelled, tool, schema, admitted_input.value.bytes),
    );
}

fn checkReverseCatalog(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    catalog: wire.Catalog,
    original: wire.Built,
    schema: []const u8,
) !void {
    const reverse = try constructionRecipe(
        a,
        &.{
            .{ .component = "filter", .operation = "selected" },
            .{ .component = "swap" },
            .{ .component = "map", .operation = "join" },
            .{ .component = "filter", .operation = "orphan" },
            .{ .component = "group" },
        },
    );
    const reverse_tool = try engine.build(a, scratch, catalog, reverse);
    try std.testing.expect(!std.mem.eql(u8, original.image.bytes, reverse_tool.image.bytes));
    var grouped = try protean.contracts.decodeOwned(
        t.tool_types.Table,
        a,
        try engine.run(
            a,
            a,
            null,
            reverse_tool,
            schema,
            try protean.contracts.encodeOwned(t.tool_types.Table, a, catalog_input),
        ),
    );
    defer grouped.deinit();
    try std.testing.expectEqual(2, grouped.value.rows.items.len);
    try std.testing.expectEqual(3, grouped.value.rows.items[0].group);
    try std.testing.expectEqual(2, grouped.value.rows.items[0].value);
    try std.testing.expectEqual(4, grouped.value.rows.items[1].group);
    try std.testing.expectEqual(1, grouped.value.rows.items[1].value);
}

fn checkCatalogReuse(
    a: std.mem.Allocator,
    encoded_catalog: []const u8,
    product: wire.Program,
    schema: []const u8,
) !void {
    const task = catalog_task;
    const next: t.tool_types.Table = .{
        .rows = .{ .items = &.{auditRow(80, 20, 201, 9)} },
        .relation = catalog_input.relation,
        .selected = .{ .items = &.{20} },
    };
    var reused = try protean.contracts.decodeOwned(
        t.tool_types.Table,
        a,
        try engine.execute(
            a,
            a,
            null,
            task,
            "frozen-policy",
            encoded_catalog,
            product,
            .{
                .schema = .{ .bytes = schema },
                .value = .{
                    .bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, next),
                },
            },
        ),
    );
    defer reused.deinit();
    try std.testing.expectEqual(1, reused.value.rows.items.len);
    try std.testing.expectEqual(80, reused.value.rows.items[0].id);
    try std.testing.expectEqual(1, reused.value.rows.items[0].status);
}

fn checkCatalogExecution(
    a: std.mem.Allocator,
    encoded_catalog: []const u8,
    product: wire.Program,
    admitted_input: wire.Input,
    many_instances: wire.Built,
    schema: []const u8,
) !void {
    const task = catalog_task;
    try std.testing.expectError(
        error.UnauthorizedProgram,
        engine.execute(
            a,
            a,
            null,
            @splat(18),
            "frozen-policy",
            encoded_catalog,
            product,
            admitted_input,
        ),
    );
    try std.testing.expectError(
        error.UnauthorizedProgram,
        engine.execute(
            a,
            a,
            null,
            task,
            "changed-policy",
            encoded_catalog,
            product,
            admitted_input,
        ),
    );
    const first = try engine.execute(
        a,
        a,
        null,
        task,
        "frozen-policy",
        encoded_catalog,
        product,
        admitted_input,
    );
    var result = try protean.contracts.decodeOwned(t.tool_types.Table, a, first);
    defer result.deinit();
    try std.testing.expectEqual(4, result.value.rows.items.len);
    const large_rows = try a.alloc(t.tool_types.Row, 40);
    for (large_rows, 0..) |*row, i| row.* = auditRow(@intCast(i), 10, 100, 1);
    const large: t.tool_types.Table = .{
        .rows = .{ .items = large_rows },
        .relation = catalog_input.relation,
        .selected = catalog_input.selected,
    };
    const large_bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, large);
    const unchanged = try engine.run(a, a, null, many_instances, schema, large_bytes);
    try std.testing.expectEqualSlices(u8, large_bytes, unchanged);
    for (result.value.rows.items, [_]u64{ 1, 2, 3, 4 }, 1..) |row, status, id| {
        try std.testing.expectEqual(id, row.id);
        try std.testing.expectEqual(status, row.status);
    }
}

test "compiled catalog composes coverage and orphan grouping and reuses exact BPI3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoded_catalog = try catalogBytes(a);
    var catalog = try protean.contracts.decodeOwned(wire.Catalog, a, encoded_catalog);
    defer catalog.deinit();
    try engine.validateCatalog(a, catalog.value);
    const coverage = try constructionRecipe(a, &.{
        .{ .component = "filter", .operation = "selected" },
        .{ .component = "map", .operation = "join" },
        .{ .component = "map", .operation = "classify" },
    });
    var scratch: kosmos.AllocationBudget = .{ .parent = a, .limit = 16 * 1024 * 1024 };
    const product = try engine.construct(
        a,
        scratch.allocator(),
        catalog_task,
        "frozen-policy",
        encoded_catalog,
        coverage,
    );
    const many_instances = try checkLargeRecipe(a, catalog.value);
    var recovered = try protean.contracts.decodeOwned(
        wire.Program,
        a,
        try protean.contracts.encodeOwned(wire.Program, a, product),
    );
    defer recovered.deinit();
    try std.testing.expectEqualSlices(
        u8,
        product.built.image.bytes,
        recovered.value.built.image.bytes,
    );
    const schema = try native.values.schemaBytes(t.tool_types.Table, a);
    const admitted_input: wire.Input = .{
        .schema = .{ .bytes = schema },
        .value = .{
            .bytes = try protean.contracts.encodeOwned(t.tool_types.Table, a, catalog_input),
        },
    };
    try checkCatalogExecution(
        a,
        encoded_catalog,
        recovered.value,
        admitted_input,
        many_instances,
        schema,
    );
    try checkCatalogReuse(a, encoded_catalog, recovered.value, schema);
    try checkReverseCatalog(a, scratch.allocator(), catalog.value, product.built, schema);
    try checkCatalogRejections(a, scratch.allocator(), catalog.value);
    try checkForbiddenCatalog(a, catalog.value);
    try checkExecutionFailures(
        a,
        encoded_catalog,
        recovered.value,
        admitted_input,
        schema,
        product.built,
    );
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
    projection: ?struct {
        reply: Ref,
        objects: protean.contracts.Vector(Ref, 16),
        output_tokens: ?u64,
    },
    reconciliation: ?[32]u8,
};

test "adaptive snapshot reconciliation preserves unknown history and settles once after restart" {
    try adaptiveRecovery(false, .snapshot);
}

test "adaptive provider without receipt retrieval remains unresolved" {
    try adaptiveRecovery(false, .provider);
}

test "adaptive malformed capture remains private and portable without claiming settlement" {
    try adaptiveRecovery(false, .malformed);
}

test "adaptive workspace reconstructed controller cannot publish invalid output" {
    for ([_]OutputCheck{
        .foreign_value,
        .malformed,
        .origin_outer,
    }) |check| try workspaceRecovery(false, false, check);
}

const OutputCheck = enum {
    none,
    origin,
    citation,
    foreign_value,
    foreign_program,
    malformed,
    origin_outer,
};

const ReframeTrace = struct {
    const wc = protean.contracts.workspace;
    phase: usize = 0,
    abandoned: wc.Expected = undefined,
    program: wc.Ref = undefined,
    schema: wc.Ref = undefined,
    current: wc.Ref = undefined,
    raw: wc.Ref = undefined,
    first: wc.Ref = undefined,
    done: bool = false,

    fn build(a: std.mem.Allocator, comptime question: bool) !t.Action {
        var builder = horos.source.Builder.init(a);
        defer builder.deinit();
        const sources = @import("workspace_sources.zig");
        const module = if (question) try sources.binaryQuestion(
            &builder,
        ) else try sources.gcd(&builder);
        const text = try native.source_records.encode(a, module);
        return .{
            .program = .{
                .command = .{
                    .build = .{
                        .source = .{ .json_text = .{ .bytes = text } },
                        .source_kind = .source_records,
                        .exposures = .{
                            .items = if (question) &.{.{ .effect = 0, .class = .input }} else &.{},
                        },
                    },
                },
            },
        };
    }
    fn start(self: ReframeTrace, text: []const u8) t.Action {
        return .{
            .work = .{
                .command = .{
                    .start = .{
                        .program = self.program,
                        .input = .{
                            .inline_json = .{
                                .schema = self.schema,
                                .json_text = .{ .bytes = text },
                            },
                        },
                        .policy = .{
                            .stop = .next_exposed_event,
                            .continuation = .owner_scheduled,
                        },
                    },
                },
            },
        };
    }
    fn next(
        self: *ReframeTrace,
        a: std.mem.Allocator,
        observation: native.json.Value,
        request: t.P.AdaptiveRequest,
    ) !t.Action {
        // These are actual request-time offers from the authored controller,
        // including while its child is demanding a boolean.
        inline for (.{
            "list",
            "read",
            "ask",
            "stop",
            "inference_set",
            "skill_set",
            "program",
            "work",
            "context",
        }) |name|
            try std.testing.expect(request.offered[t.ordinal(name)]);
        const phase = self.phase;
        self.phase += 1;
        switch (phase) {
            0 => return build(a, true),
            1, 5 => {
                self.program = try native.values.fromJson(
                    wc.Ref,
                    a,
                    observation.object.get("program").?,
                );
                self.schema = try native.values.fromJson(
                    wc.Ref,
                    a,
                    observation.object.get("input_schema").?,
                );
                return self.start(if (phase == 1) "{}" else "[\"48\",\"18\"]");
            },
            2 => return reframeBroaderEvidence(self, a, observation),
            3 => {
                self.raw = try native.values.fromJson(wc.Ref, a, observation.object.get("value").?);
                return .{ .work = .{ .command = .{ .park = self.abandoned } } };
            },
            4 => return build(a, false),
            6, 7 => return reframeComputedResult(self, a, observation, phase),
            8 => return .{
                .context = .{ .command = .{ .expand = .{ .reference = self.raw, .page = .{} } } },
            },
            9 => {
                self.done = true;
                return .{
                    .stop = .{
                        .reason = .{
                            .bytes = reframing_result,
                        },
                    },
                };
            },
            else => return error.UnexpectedInference,
        }
    }
};

fn generatedToolConfiguration(
    a: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    dir: std.Io.Dir,
    path: []const u8,
    reconstruct: bool,
) !native.configuration.Admitted {
    const base = try environment.configure(a, io, .{ .offline = true }, null, assets);
    const policy = try native.adaptive_responses.Admission(t.P).policy(a, base.bytes);
    try dir.createDir(io, "snapshot", .default_dir);
    try dir.writeFile(
        io,
        .{ .sub_path = "snapshot/input.zig", .data = "pub const retained = true;\n" },
    );
    const config: t.ConfigurationV3 = .{
        .schema = .{ .bytes = "adaptive-agent.configuration.v3" },
        .adaptive = .{
            .workspace = .{ .bytes = "generated-recovery" },
            .snapshot_root = .{ .bytes = try std.fmt.allocPrint(a, "{s}/snapshot", .{path}) },
            .endpoint = .{ .bytes = "https://127.0.0.1:1/v1/responses" },
            .audience = .{ .bytes = "generated-recovery" },
            .profiles = policy.profiles,
            .initial_profile = .{ .bytes = "analysis" },
            .initial_effort = .medium,
            .skills = .{ .items = &.{} },
        },
        .tools = .{
            .build = true,
            .run = true,
            .reconstruct = reconstruct,
            .inputs = .{ .items = &.{.{
                .id = .{ .bytes = "retained-table" },
                .description = .{ .bytes = "Immutable generated-tool input" },
                .rows = .{ .items = &.{.{ .id = 1, .key = 10, .value = 100, .group = 1 }} },
                .relation = .{ .items = &.{.{ .id = 2, .key = 20, .value = 200, .group = 2 }} },
                .selected = .{ .items = &.{10} },
            }} },
        },
    };
    var config_json = try native.values.toJson(t.ConfigurationV3, a, config);
    if (!reconstruct) _ = config_json.object.getPtr("tools").?.object.swapRemove("reconstruct");
    try dir.writeFile(
        io,
        .{ .sub_path = "config.json", .data = try native.json.canonical(a, config_json) },
    );
    // Configuration admits local inputs normally. Provider acquisition is
    // forbidden by the test registry, so no TLS or network operation occurs.
    try dir.writeFile(
        io,
        .{ .sub_path = "unused-trust-root", .data = "unused by the synthetic provider" },
    );
    return environment.configure(a, io, .{
        .offline = false,
        .test_provider = true,
        .config_path = try std.fmt.allocPrint(a, "{s}/config.json", .{path}),
        .trust_root_path = try std.fmt.allocPrint(a, "{s}/unused-trust-root", .{path}),
    }, null, assets);
}

fn workspaceRecovery(
    comptime interrupted: bool,
    comptime reframing: bool,
    output_check: OutputCheck,
) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const permanent = arena.allocator();
    var admitted_image = try horos.data.program_image.Admitted.decode(
        a,
        @embedFile("adaptive_image"),
    );
    defer admitted_image.deinit();
    const assets = try imageAssets(permanent, admitted_image.identity());
    var handlers = try workspaceRecoveryHandlers(a);
    defer handlers.deinit();
    var application = try native.discovery.Application.init(t, a, assets, handlers);
    defer application.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const directory = buffer[0..try temporary.dir.realPath(io, &buffer)];
    const configured = try generatedToolConfiguration(
        permanent,
        io,
        assets,
        temporary.dir,
        directory,
        output_check != .none,
    );
    var grants: [environment.handlers.len]native.registry.Grant = undefined;
    const profile = try recoveryProfile(a, configured, handlers, &application, &grants);
    const path = try std.fmt.allocPrint(permanent, "{s}/workspace", .{directory});
    var namespace = try native.Namespace.open(a, io, path);
    defer expectCleanup("namespace.close", namespace.close());
    var service = try native.tasks.Service(t).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer expectCleanup("service.close", service.close(a));
    const task = try submitWorkspaceRecovery(&service, permanent, reframing);
    const recipe = try constructionRecipe(permanent, &.{.{ .component = "swap" }});
    const fixture = .{
        .a = a,
        .io = io,
        .permanent = permanent,
        .directory = directory,
        .profile = profile,
        .handlers = handlers,
        .application = &application,
        .namespace = &namespace,
        .service = &service,
        .assets = assets,
        .path = path,
    };
    var state: WorkspaceProgress = .{};
    try workspaceRecoveryLoop(interrupted, reframing, output_check, fixture, &state, task, recipe);
}

const WorkspaceProgress = struct {
    stage: usize = 0,
    build_dispatches: usize = 0,
    compiled_image: ?[]const u8 = null,
    restarted: bool = false,
    program: protean.contracts.workspace.Ref = undefined,
    input: protean.contracts.workspace.Ref = undefined,
    child: protean.contracts.workspace.Ref = undefined,
    inspected: bool = false,
    trace: ReframeTrace = .{},
};

fn workspaceRecoveryLoop(
    comptime interrupted: bool,
    comptime reframing: bool,
    output_check: OutputCheck,
    fixture: anytype,
    state: *WorkspaceProgress,
    task: [16]u8,
    recipe: []const u8,
) !void {
    const c = protean.contracts;
    // One native pump is a bounded base slice, not a complete guest transition.
    for (0..4096) |_| {
        var frame_arena = std.heap.ArenaAllocator.init(fixture.a);
        defer frame_arena.deinit();
        const frame = frame_arena.allocator();
        var parent = try fixture.service.task(frame, task);
        defer parent.deinit();
        if (parent.value.terminal()) {
            try checkWorkspaceCompleted(
                interrupted,
                reframing,
                fixture,
                state,
                frame,
                task,
                parent,
            );
            return;
        }
        const step = try fixture.service.pump(frame);
        if (step != .work) continue;
        const work = step.work;
        if (work.operation == .workspace_build) {
            try workspaceBuild(interrupted, reframing, fixture, state, frame, task, work);
            continue;
        }
        if (work.entry.declaration.inference) {
            var prepared = try c.decodeOwned(t.P.AdaptivePrepared, frame, work.prepared.?);
            defer prepared.deinit();
            if (output_check != .none) {
                try invalidWorkspaceOutput(
                    fixture,
                    frame,
                    task,
                    work,
                    prepared.value.request,
                    output_check,
                );
                return;
            }
            const action = try workspaceAction(
                reframing,
                fixture,
                state,
                frame,
                task,
                prepared.value.request,
                recipe,
            );
            try acquireWorkspaceAction(fixture, state, frame, work, action);
        } else {
            try acquireWorkspaceEffect(fixture, frame, task, work);
        }
    }
    return error.WorkspaceRecoveryDidNotComplete;
}

fn workspaceBuild(
    comptime interrupted: bool,
    comptime reframing: bool,
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
) !void {
    state.build_dispatches += 1;
    if (!interrupted or state.restarted) {
        try captureWorkspaceBuild(fixture, state, frame, work);
    } else try fixture.service.notSent(frame, work);
    if (!reframing and !state.restarted) {
        // Abandoning an in-flight pure compiler is known-not-sent;
        // a durable compiler capture is imported without recompiling.
        const archive_path = try std.fmt.allocPrint(
            frame,
            "{s}/captured.agnx",
            .{fixture.directory},
        );
        if (!interrupted) _ = try fixture.service.exportCheckpoint(frame, task, archive_path);
        try fixture.service.close(frame);
        try fixture.namespace.close();
        if (!interrupted) {
            const copied_path = try std.fmt.allocPrint(
                fixture.permanent,
                "{s}/imported",
                .{fixture.directory},
            );
            var copied_namespace = try native.Namespace.open(fixture.a, fixture.io, copied_path);
            defer expectCleanup("copied_namespace.close", copied_namespace.close());
            var copied = try recoveryService(fixture, &copied_namespace);
            defer expectCleanup("copied.close", copied.close(frame));
            _ = try copied.importCheckpoint(frame, "import-build", archive_path);
            try std.testing.expectError(
                error.CustodyNotLocal,
                copied.resumeTask(frame, "copy-build-resume", task, 1),
            );
            try std.testing.expectEqual(.idle, try copied.pump(frame));
        }
        (fixture.namespace.*) = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
        (fixture.service.*) = try recoveryService(fixture, fixture.namespace);
        try std.testing.expectEqual(.idle, try fixture.service.pump(frame));
        var recovered = try fixture.service.task(frame, task);
        defer recovered.deinit();
        try std.testing.expectEqual(@as(u64, 1), recovered.value.inference_attempts);
        _ = try fixture.service.resumeTask(frame, "resume-build", task, recovered.value.revision);
        state.restarted = true;
    }
}

fn workspaceAction(
    comptime reframing: bool,
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    task: [16]u8,
    request: t.P.AdaptiveRequest,
    recipe: []const u8,
) !t.Action {
    const wc = protean.contracts.workspace;
    var observation: native.json.Value = .null;
    if (state.stage > 0) {
        try std.testing.expectEqual(1, request.results.items.len);
        const prior = (try native.json.parse(
            fixture.permanent,
            request.results.items[0].output.bytes,
            .{},
        )).value;
        try std.testing.expect(
            !std.mem.eql(u8, "rejected", prior.object.get("disposition").?.string),
        );
        observation = prior.object.get("observation").?;
    }
    return if (reframing) try state.trace.next(
        fixture.permanent,
        observation,
        request,
    ) else switch (state.stage) {
        0 => .{
            .program = .{
                .command = .{
                    .build = .{
                        .source = .{ .json_text = .{ .bytes = recipe } },
                        .source_kind = .component_recipe,
                        .exposures = .{ .items = &.{} },
                    },
                },
            },
        },
        1 => try materializeRecoveredInput(fixture, state, frame, task, observation, recipe),
        2 => blk: {
            state.input = try native.values.fromJson(
                wc.Ref,
                fixture.permanent,
                observation.object.get("value").?,
            );
            break :blk .{
                .work = .{
                    .command = .{
                        .start = .{
                            .program = state.program,
                            .input = .{ .reference = state.input },
                            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
                        },
                    },
                },
            };
        },
        else => try inspectRecoveredWork(fixture, state, frame, observation),
    };
}

fn invalidWorkspaceOutput(
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    adaptive_request: t.P.AdaptiveRequest,
    output_check: OutputCheck,
) !void {
    var state: InvalidOutputProgress = .{};
    errdefer std.debug.print("invalid output {s} failed at {s}\n", .{
        @tagName(output_check), state.output_stage,
    });
    try fixture.service.notSent(frame, work);
    try installInvalidOutput(fixture.service, frame, task, adaptive_request, output_check);
    const context = .{
        .fixture = fixture,
        .frame = frame,
        .task = task,
        .output_check = output_check,
    };
    try rejectInvalidOutput(context, &state);
    try reopenInvalidOutput(context, &state);
    var retained = try fixture.service.task(frame, task);
    defer retained.deinit();
    try checkRetainedInvalidOutput(context, &state, retained);
    try cancelInvalidOutput(context, &state, retained);
}

fn installInvalidOutput(
    service: *native.tasks.Service(t),
    a: std.mem.Allocator,
    task: [16]u8,
    request: t.P.AdaptiveRequest,
    check: OutputCheck,
) !void {
    const c = protean.contracts;
    const uncited = check == .citation;
    const carry = try invalidOutputCarry(service, a, task);
    var claims: [1]InventedClaim = undefined;
    var output = inventedOutput(&claims, carry, uncited);
    if (check == .foreign_value or check == .foreign_program) {
        try installForeignOutput(service, a, &output, check);
    } else if (check == .malformed) {
        output.evidence = .{
            .items = &.{.{ .workspace = .{ .kind = .value, .id = .{ .bytes = "not-a-digest" } } }},
        };
    }
    var programs: [2]c.workspace.Ref = undefined;
    for (&programs, 0..) |*program, i| {
        program.* = try buildInventedProgram(service, a, task, request, output, i);
    }
    var current = try service.task(a, task);
    defer current.deinit();
    _ = try service.adoptController(
        a,
        "adopt-invented-output",
        task,
        current.value.revision,
        .{
            .successor = programs[0],
            .converter = programs[1],
            .expected_controller_epoch = current.value.controller_epoch,
            .expected_handoff_identity = .{
                .bytes = &std.fmt.bytesToHex(current.value.controller_interaction.?, .lower),
            },
            .reason = .{ .bytes = "Exercise native output reference admission" },
        },
    );
}

fn adaptiveRecovery(comptime correction: bool, comptime recovery_probe: RecoveryProbe) !void {
    var budget: kosmos.AllocationBudget = .{
        .parent = std.testing.allocator,
        .limit = 64 * 1024 * 1024,
    };
    const a = budget.allocator();
    const io = std.testing.io;
    var profile_arena = std.heap.ArenaAllocator.init(a);
    defer profile_arena.deinit();
    const permanent = profile_arena.allocator();
    const assets = try recoveryAssets(a, permanent);
    var handlers = try native.Registry.init(a, &environment.handlers);
    defer handlers.deinit();
    var application = try native.discovery.Application.init(t, a, assets, handlers);
    defer application.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const configured = try environment.configure(
        permanent,
        io,
        .{ .offline = true, .scratch_allocator = a },
        null,
        assets,
    );
    var grants: [environment.handlers.len]native.registry.Grant = undefined;
    const profile = try recoveryProfile(a, configured, handlers, &application, &grants);
    const path = try std.fmt.allocPrint(permanent, "{s}/adaptive", .{buffer[0..length]});
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_live = true;
    defer if (namespace_live) expectCleanup("namespace.close", namespace.close());
    var service = try native.tasks.Service(t).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    var service_live = true;
    defer if (service_live) expectCleanup("service.close", service.close(a));
    const task = try submitRecoveryTask(&service, permanent);
    const fixture = .{
        .a = a,
        .io = io,
        .permanent = permanent,
        .assets = assets,
        .application = &application,
        .handlers = handlers,
        .configured = configured,
        .profile = profile,
        .path = path,
        .namespace = &namespace,
        .service = &service,
        .namespace_live = &namespace_live,
        .service_live = &service_live,
        .budget = &budget,
        .directory = buffer[0..length],
    };
    var state: AdaptiveProgress = .{};
    try adaptiveRecoveryLoop(correction, recovery_probe, fixture, &state, task);
}

const long_task: [2048]u8 = @splat('T');
const long_followup: [2048]u8 = @splat('F');
const RecoveryProbe = enum { none, imported, snapshot, provider, malformed };
const RecoveryProgress = enum { next, completed, handled };
const CaptureRestart = struct { attempt: [32]u8, capture: []const u8, archive: ?[]const u8 };
const AdaptiveProgress = struct {
    model_calls: usize = 0,
    last_model_capture: ?[32]u8 = null,
    restarted: bool = false,
    witnessed: bool = false,
    finished: bool = false,
    maximum_state: u64 = 0,
    maximum_prepared: usize = 0,
    maximum_scratch: usize = 0,
};

fn checkAdaptiveCompletion(
    comptime correction: bool,
    fixture: anytype,
    state: *AdaptiveProgress,
    frame: std.mem.Allocator,
    task: [16]u8,
    saved: anytype,
) !void {
    try std.testing.expect(saved.value.outcome_kind == .completed);
    const result = try fixture.namespace.store.object(frame, saved.value.result.?, null);
    var output = try protean.contracts.decodeOwned(t.Output, frame, result);
    defer output.deinit();
    try std.testing.expect(output.value.result == .report);
    try std.testing.expectEqual(@as(u64, if (correction) 16 else 14), output.value.model_calls);
    if (correction) {
        try std.testing.expect(result.len > (native.protocol.Limits{}).inline_bytes);
        try std.testing.expectEqual(
            @as(usize, 70 * 1024),
            output.value.result.report.summary.bytes.len,
        );
        try std.testing.expectEqual(@as(usize, 2), output.value.evidence.items.len);
        try std.testing.expectEqual(@as(usize, 3), output.value.result.report.claims.items.len);
        try std.testing.expectEqualSlices(
            u64,
            &.{ 0, 1 },
            output.value.result.report.claims.items[0].evidence_indices.items,
        );
        try std.testing.expectEqual(@as(u64, 6), output.value.work_calls);
        try std.testing.expectEqualStrings(
            "src/main.zig",
            output.value.evidence.items[0].source.path.bytes,
        );
        try std.testing.expectEqualStrings(
            "src/main.zig",
            output.value.evidence.items[1].source.path.bytes,
        );
        try std.testing.expectEqual(@as(u64, 32), output.value.evidence.items[1].source.end);
        var client: native.client.Client(t) = .{ .service = fixture.service };
        var params = native.json.object();
        try native.json.put(
            frame,
            &params,
            "task_id",
            native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task, .lower))),
        );
        const exposed = try client.call(frame, .@"task.result", params);
        const outcome = native.json.get(exposed, "outcome").?;
        try std.testing.expect(native.json.get(outcome, "value") == null);
        try std.testing.expect(native.json.get(outcome, "value_ref") != null);
    }
    try std.testing.expectEqual(8, output.value.receipts.items.len);
    try std.testing.expectEqual(8, output.value.control.selection.control_revision);
    state.finished = true;
}

fn checkAdaptiveRestart(
    fixture: anytype,
    state: *AdaptiveProgress,
    frame: std.mem.Allocator,
    saved: anytype,
) !void {
    if (state.restarted and !state.witnessed and saved.value.outcome_kind == .requested) {
        const encoded = try fixture.namespace.store.object(frame, saved.value.outcome, 1024 * 1024);
        var outcome = try protocol.decode(protocol.Outcome, frame, encoded);
        defer outcome.deinit();
        var request = try protocol.decode(protocol.Request, frame, outcome.value.requested.request);
        defer request.deinit();
        if (std.mem.eql(
            u8,
            request.value.binding.semantic_identity,
            protean.contracts.controller.effect_prefix ++ "deliberate",
        )) {
            const entry = try fixture.handlers.resolve(
                request.value,
                fixture.application.image_identity,
            );
            var adaptive = try protean.contracts.decodeOwned(
                t.P.AdaptiveRequest,
                frame,
                try entry.payload(frame, request.value.binding.payload),
            );
            defer adaptive.deinit();
            if (adaptive.value.plan.watermark == 8) {
                try std.testing.expectEqual(8, state.model_calls);
                try std.testing.expectEqual(5, adaptive.value.selection.control_revision);
                try std.testing.expectEqual(1, adaptive.value.plan.eviction_generation);
                try std.testing.expectEqual(0, adaptive.value.plan.skills.items.len);
                try std.testing.expect(
                    !adaptive.value.offered[7] and !adaptive.value.materialized[7],
                );
                try std.testing.expectEqual(8, saved.value.inference_attempts);
                state.witnessed = true;
            }
        }
    }
}

fn adaptiveReply(
    comptime correction: bool,
    comptime recovery_probe: RecoveryProbe,
    fixture: anytype,
    state: *AdaptiveProgress,
    scratch: *kosmos.AllocationBudget,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    request: anytype,
    saved: anytype,
) ![]const u8 {
    const context: native.Context = .{
        .allocator = frame,
        .io = fixture.io,
        .authority = &fixture.profile.authority,
        .task_id = &std.fmt.bytesToHex(task, .lower),
        .profile = fixture.profile.bytes,
        .environment = fixture.profile.environment,
    };
    return if (work.entry.declaration.capture) |adapter| blk: {
        state.maximum_prepared = @max(state.maximum_prepared, work.prepared.?.len);
        if (recovery_probe == .imported and state.restarted and work.entry.declaration.inference)
            try checkImportedPreparation(
                fixture,
                state,
                scratch,
                frame,
                task,
                work,
                request,
                saved,
                adapter,
            );
        if (work.entry.declaration.inference and state.model_calls == 8)
            try checkLongRecoveryInput(frame, work);
        if (correction and work.entry.declaration.inference and state.model_calls >= 13)
            break :blk try correctedRecoveryReply(state, frame, work);
        const acquired = try adapter.acquire(context, work.prepared.?);
        if (acquired != .captured) return error.UnexpectedAcquisitionFailure;
        break :blk acquired.captured;
    } else try work.entry.declaration.invoke.?(context, request.value.binding.payload);
}

fn malformedCapture(fixture: anytype, frame: std.mem.Allocator, task: [16]u8, work: anytype) !void {
    const malformed = "invalid response framing";
    try fixture.service.acquire(frame, work, malformed);
    _ = try fixture.service.pump(frame);
    var rejected_task = try fixture.service.task(frame, task);
    defer rejected_task.deinit();
    try std.testing.expectEqual(
        native.tasks.Status.blocked,
        try fixture.service.status(frame, rejected_task.value),
    );
    const State = native.testing.state;
    var retained = try protean.contracts.decodeOwned(
        State.Capture,
        frame,
        (try fixture.namespace.store.recordBytes(frame, "capture", work.attempt, task)).?,
    );
    defer retained.deinit();
    try std.testing.expect(retained.value.projection == null);
    try std.testing.expectEqualSlices(
        u8,
        malformed,
        try fixture.namespace.store.object(frame, retained.value.response.?, null),
    );
    const archive_path = try std.fmt.allocPrint(frame, "{s}/malformed.agnx", .{fixture.directory});
    _ = try fixture.service.exportCheckpoint(frame, task, archive_path);
    try fixture.service.close(frame);
    (fixture.service_live.*) = false;
    try fixture.namespace.close();
    (fixture.namespace_live.*) = false;
    try checkMalformedImport(fixture, frame, task, work, rejected_task, retained, archive_path);
}

fn reconcileCapture(
    comptime recovery_probe: RecoveryProbe,
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    saved: anytype,
    inference: bool,
    reply: []const u8,
) !void {
    const occurrence_id = work.occurrence;
    const attempt_id = work.attempt;
    try fixture.service.unknown(frame, work);
    try closeRecoveryFixture(fixture, frame);
    try openRecoveryFixture(fixture);
    const before = fixture.namespace.store.head;
    try std.testing.expectEqualDeep(before, fixture.namespace.store.head);
    var unchanged = try fixture.service.task(frame, task);
    defer unchanged.deinit();
    try checkUnknownRecovery(
        fixture,
        frame,
        task,
        saved,
        unchanged,
        inference,
        occurrence_id,
        attempt_id,
    );
    const revision = unchanged.value.revision;
    const initial = .{
        .fixture = fixture,
        .frame = frame,
        .task = task,
        .occurrence_id = occurrence_id,
        .attempt_id = attempt_id,
        .revision = revision,
        .reply = reply,
    };
    const status_params = try admitPublicRecovery(recovery_probe, initial, before);
    const admitted = try checkRecoveryReplay(recovery_probe, initial);
    if (recovery_probe != .provider) try runRecoveryDerivation(recovery_probe, initial);

    try checkReconciledCapture(recovery_probe, initial, admitted, unchanged, status_params);
}

fn restartAdaptiveCapture(
    fixture: anytype,
    state: *AdaptiveProgress,
    scratch: *kosmos.AllocationBudget,
    task: [16]u8,
    pending: CaptureRestart,
) !void {
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());
    defer arena.deinit();
    const frame = arena.allocator();
    try fixture.service.close(frame);
    (fixture.service_live.*) = false;
    try fixture.namespace.close();
    (fixture.namespace_live.*) = false;
    if (pending.archive) |archive_path| {
        var capture = try protean.contracts.decodeOwned(CaptureRecord, frame, pending.capture);
        defer capture.deinit();
        const copied_path = try std.fmt.allocPrint(
            fixture.permanent,
            "{s}/imported",
            .{fixture.directory},
        );
        var copied_namespace = try native.Namespace.open(fixture.a, fixture.io, copied_path);
        defer expectCleanup("copied_namespace.close", copied_namespace.close());
        var copied = try recoveryService(fixture, &copied_namespace);
        defer expectCleanup("copied.close", copied.close(frame));
        _ = try copied.importCheckpoint(frame, "adaptive-capture-import", archive_path);
        var copied_capture = try protean.contracts.decodeOwned(
            CaptureRecord,
            frame,
            (try copied_namespace.store.recordBytes(frame, "capture", pending.attempt, task)).?,
        );
        defer copied_capture.deinit();
        try std.testing.expectEqualDeep(capture.value, copied_capture.value);
        try std.testing.expectError(
            error.CustodyNotLocal,
            copied.resumeTask(frame, "copy-capture-resume", task, 1),
        );
        try std.testing.expectEqual(.idle, try copied.pump(frame));
    }
    (fixture.namespace.*) = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    (fixture.namespace_live.*) = true;
    (fixture.service.*) = try recoveryService(fixture, fixture.namespace);
    (fixture.service_live.*) = true;
    var current = try fixture.service.task(frame, task);
    defer current.deinit();
    _ = try fixture.service.resumeTask(
        frame,
        "adaptive-capture-resume",
        task,
        current.value.revision,
    );
    state.restarted = true;
}

fn finishAdaptiveRecovery(
    comptime correction: bool,
    fixture: anytype,
    state: *AdaptiveProgress,
    task: [16]u8,
) !void {
    try std.testing.expect(state.witnessed and state.finished);
    try std.testing.expectEqual(@as(usize, if (correction) 16 else 14), state.model_calls);
    // Archive validation must release each replay's scratch memory even when
    // the CLI supplies an arena for the enclosing request.
    {
        const execution_limit = fixture.budget.limit;
        fixture.budget.limit = 32 * 1024 * 1024;
        defer fixture.budget.limit = execution_limit;
        var frame_arena = std.heap.ArenaAllocator.init(fixture.a);
        defer frame_arena.deinit();
        const archive_path = try std.fmt.allocPrint(
            fixture.permanent,
            "{s}/completed.archive",
            .{fixture.directory},
        );
        const exported = try fixture.service.exportCheckpoint(
            frame_arena.allocator(),
            task,
            archive_path,
        );
        try std.testing.expect(exported.bytes > 0);
    }
    std.debug.print(
        "adaptive capture recovery: model_acquisitions={d} state_bytes_pea" ++
            "k={d} prepared_bytes_peak={d} projection_and_step_scratch_peak={d" ++
            "} requested_memory_peak={d}\n",
        .{
            state.model_calls,
            state.maximum_state,
            state.maximum_prepared,
            state.maximum_scratch,
            fixture.budget.peak,
        },
    );
    try fixture.service.close(fixture.a);
    (fixture.service_live.*) = false;
    if (correction) try removeRetainedContextDependency(fixture, state, task);

    try fixture.namespace.close();
    (fixture.namespace_live.*) = false;
    if (correction) {
        (fixture.namespace.*) = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
        (fixture.namespace_live.*) = true;
        try std.testing.expectError(
            error.CorruptState,
            recoveryService(fixture, fixture.namespace),
        );
        try std.testing.expect(fixture.namespace.store.fenced);
    }
    if (!correction) try continuedAttemptAccounting(
        fixture.a,
        fixture.io,
        fixture.assets,
        fixture.application,
        fixture.handlers,
        fixture.configured,
        fixture.directory,
    );
}

fn adaptiveRecoveryFrame(
    comptime correction: bool,
    comptime recovery_probe: RecoveryProbe,
    fixture: anytype,
    state: *AdaptiveProgress,
    scratch: *kosmos.AllocationBudget,
    task: [16]u8,
    restart: *?CaptureRestart,
) !RecoveryProgress {
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());
    defer arena.deinit();
    const frame = arena.allocator();
    var saved = try fixture.service.task(frame, task);
    defer saved.deinit();
    state.maximum_state = @max(state.maximum_state, saved.value.checkpoint.bytes);
    if (saved.value.terminal()) {
        try checkAdaptiveCompletion(correction, fixture, state, frame, task, saved);
        return .completed;
    }
    try checkAdaptiveRestart(fixture, state, frame, saved);
    const step = try fixture.service.pump(frame);
    if (step == .work) {
        return acquireRecoveryWork(
            correction,
            recovery_probe,
            fixture,
            state,
            scratch,
            frame,
            task,
            restart,
            step.work,
            saved,
        );
    } else if (step == .waiting) {
        var question = (try fixture.service.pendingQuestion(
            frame,
            task,
        )) orelse return error.MissingQuestion;
        defer question.deinit();
        _ = try fixture.service.respond(
            frame,
            "adaptive-recovery-answer",
            task,
            question.value.id,
            question.value.revision,
            question.value.request_digest,
            question.value.answer_schema_id.bytes,
            try native.values.toJson(t.Answer, frame, environment.demo_answer),
        );
    }

    return .next;
}

fn adaptiveRecoveryLoop(
    comptime correction: bool,
    comptime recovery_probe: RecoveryProbe,
    fixture: anytype,
    state: *AdaptiveProgress,
    task: [16]u8,
) !void {
    errdefer std.debug.print(
        "adaptive recovery failure: calls={d} restarted={} witnessed={} fi" ++
            "nished={} state_bytes={d} scratch_bytes={d}\n",
        .{
            state.model_calls,
            state.restarted,
            state.witnessed,
            state.finished,
            state.maximum_state,
            state.maximum_scratch,
        },
    );
    // Preserve the complete recovery trace across evaluator micro-suspensions.
    for (0..4096) |_| {
        var restart: ?CaptureRestart = null;
        var scratch: kosmos.AllocationBudget = .{ .parent = fixture.a, .limit = 64 * 1024 * 1024 };
        defer state.maximum_scratch = @max(state.maximum_scratch, scratch.peak);
        switch (try adaptiveRecoveryFrame(
            correction,
            recovery_probe,
            fixture,
            state,
            &scratch,
            task,
            &restart,
        )) {
            .next => {},
            .completed => break,
            .handled => return,
        }
        if (restart) |pending| try restartAdaptiveCapture(fixture, state, &scratch, task, pending);
    }
    try finishAdaptiveRecovery(correction, fixture, state, task);
}

fn continuedAttemptAccounting(
    parent: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    application: *native.discovery.Application,
    handlers: native.Registry,
    original: native.configuration.Admitted,
    directory: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    const a = arena.allocator();
    const configured = try environment.configure(
        a,
        io,
        .{ .offline = true, .scratch_allocator = parent },
        .{ .profile_id = original.id, .profile = original.bytes, .resources = original.resources },
        assets,
    );
    var grants: [environment.handlers.len]native.registry.Grant = undefined;
    const profile = try recoveryProfile(a, configured, handlers, application, &grants);
    const path = try std.fmt.allocPrint(a, "{s}/attempt-accounting", .{directory});
    var namespace = try native.Namespace.open(parent, io, path);
    defer expectCleanup("namespace.close", namespace.close());
    var service = try native.tasks.Service(t).init(
        parent,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer expectCleanup("service.close", service.close(parent));
    const task = (try service.submit(a, "continued-attempts", environment.demo_input)).receipt.task;
    try continuedAttemptLoop(.{
        .parent = parent,
        .io = io,
        .service = &service,
        .namespace = &namespace,
        .profile = profile,
        .task = task,
    });
}

fn parkInvalidOutputCleanup(context: anytype, state: *InvalidOutputProgress) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const output_check = context.output_check;
    const c = protean.contracts;
    var query = try fixture.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
            "ERE r.task=? AND r.kind='controller_residual'",
        &.{.{ .blob = &task }},
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    const residual = (try c.decodeOwned(
        native.testing.state.ControllerResidual,
        frame,
        try query.bytes(0),
    )).value;
    try std.testing.expect(residual.outcome_kind != .cancelled);
    const parked = try fixture.service.workspaceCommand(
        frame,
        "park-output-predecessor-cleanup",
        task,
        .{
            .work = .{
                .park = .{
                    .work = .{
                        .kind = .residual,
                        .id = .{
                            .bytes = try std.fmt.allocPrint(
                                frame,
                                "{s}",
                                .{std.fmt.bytesToHex(residual.id, .lower)},
                            ),
                        },
                    },
                    .execution_revision = residual.execution_revision,
                    .control_revision = residual.control_revision,
                },
            },
        },
    );
    if (parked.disposition != .observed) std.debug.print(
        "invalid output {s} cleanup park: {s}\n",
        .{ @tagName(output_check), parked.observation_json.bytes },
    );
    try std.testing.expectEqual(.observed, parked.disposition);
    state.cleanup = (try c.decodeOwned(
        native.testing.state.ControllerResidual,
        frame,
        (try fixture.namespace.store.recordBytes(
            frame,
            "controller_residual",
            residual.id,
            task,
        )).?,
    )).value;
}

fn retainInvalidOutputHandoff(
    context: anytype,
    state: *InvalidOutputProgress,
    before: anytype,
) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const output_check = context.output_check;
    const c = protean.contracts;
    if (before.value.controller_epoch == 1) if (before.value.current_occurrence) |id| {
        const pending = (try c.decodeOwned(
            native.testing.occurrence.Occurrence,
            frame,
            (try fixture.namespace.store.recordBytes(frame, "occurrence", id, task)).?,
        )).value;
        if (pending.state == .settled_reply) {
            state.acquired = pending;
            if (output_check == .origin_outer and !state.captured_outer) {
                const request = (try protocol.decode(
                    protocol.Request,
                    frame,
                    try fixture.namespace.store.object(frame, pending.request_object, null),
                )).value;
                if (std.mem.eql(
                    u8,
                    request.binding.semantic_identity,
                    c.controller.handoff_identity,
                )) {
                    state.output_stage = "retain acquired handoff operation";
                    try std.testing.expect(fixture.service.active != null);
                    const active = &fixture.service.active.?;
                    try std.testing.expect(
                        active.subject == .root and std.meta.eql(active.task, task),
                    );
                    try std.testing.expect(
                        active.root_control == null and !active.root_cut_ready,
                    );
                    try std.testing.expectEqual(
                        before.value.execution_revision,
                        active.execution_revision,
                    );
                    const control: protocol.Control = .{
                        .reply = try fixture.namespace.store.object(
                            frame,
                            try fixture.namespace.store.objectReference(
                                pending.state.settled_reply.reply,
                                null,
                            ),
                            null,
                        ),
                    };
                    const encoded = try c.encodeOwned(
                        protocol.Control,
                        fixture.service.allocator,
                        control,
                    );
                    active.driver.beginAdvance(control, 256) catch |err| {
                        fixture.service.allocator.free(encoded);
                        return err;
                    };
                    active.root_control = encoded;
                    active.root_quantum = 256;
                    _ = try fixture.service.placementCut(frame, .{ .task = task });
                    state.captured_outer = true;
                }
            }
        }
    };
}

fn invalidOutputPending(context: anytype, state: *InvalidOutputProgress, before: anytype) !bool {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const c = protean.contracts;
    var pending_before = false;
    if (state.acquired) |saved| {
        state.preserved_acquisition = (try c.decodeOwned(
            native.testing.occurrence.Occurrence,
            frame,
            (try fixture.namespace.store.recordBytes(frame, "occurrence", saved.id, task)).?,
        )).value;
        var query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='root_operation'",
            &.{.{ .blob = &task }},
        );
        defer query.deinit();
        if (try query.step() == .row) {
            const operation = (try c.decodeOwned(
                native.testing.state.RootOperation,
                frame,
                try query.bytes(0),
            )).value;
            pending_before = operation.pending != null;
            if (pending_before) try std.testing.expectEqual(
                before.value.execution_revision,
                operation.execution_revision,
            );
        }
    }

    return pending_before;
}

fn advanceInvalidOutput(context: anytype, state: *InvalidOutputProgress) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const c = protean.contracts;
    state.output_stage = "advance invalid result";
    const progress = try fixture.service.pump(frame);
    if (progress == .work) {
        try std.testing.expectEqualDeep(task, progress.work.task);
        try std.testing.expect(progress.work.entry.declaration.inference);
        try std.testing.expectEqual(@as(usize, 0), state.model_replies);
        const response = try std.json.Stringify.valueAlloc(
            frame,
            .{
                .status = "completed",
                .@"error" = @as(?u8, null),
                .output = .{
                    .{
                        .type = "function_call",
                        .status = "completed",
                        .call_id = "invalid-output-stop",
                        .name = "stop",
                        .arguments = "{\"reason\":\"Return the reconstructed controller result.\"}",
                    },
                },
            },
            .{},
        );
        try fixture.service.acquire(
            frame,
            progress.work,
            try c.encodeOwned(
                native.responses.Raw,
                frame,
                .{
                    .status = 200,
                    .identity_encoding = true,
                    .request_id = null,
                    .body = .{ .bytes = response },
                },
            ),
        );
        state.model_replies += 1;
    }
}

fn checkInvalidOutputRejection(
    context: anytype,
    state: *InvalidOutputProgress,
    rejected: anytype,
    pending_before: bool,
) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const output_check = context.output_check;
    const c = protean.contracts;
    state.output_stage = "rejected authoritative cut";
    try std.testing.expectEqual(.parked, rejected.value.schedule);
    try std.testing.expect(!rejected.value.terminal() and !fixture.namespace.store.fenced);
    try std.testing.expect(
        state.accepted != null and state.acquired != null and state.cleanup != null,
    );
    try std.testing.expectEqual(@as(usize, 1), state.model_replies);
    try std.testing.expectEqual(output_check == .origin_outer, state.captured_outer);
    try std.testing.expectEqual(output_check == .origin_outer, pending_before);
    try std.testing.expectEqual(
        state.accepted.?.execution_revision,
        rejected.value.execution_revision,
    );
    try std.testing.expectEqualDeep(state.accepted.?.checkpoint, rejected.value.checkpoint);
    try std.testing.expectEqualDeep(state.accepted.?.outcome, rejected.value.outcome);
    try std.testing.expectEqualDeep(
        state.accepted.?.current_occurrence,
        rejected.value.current_occurrence,
    );
    try std.testing.expect(
        rejected.value.result == null and rejected.value.client_result == null,
    );
    try std.testing.expectEqualDeep(
        state.preserved_acquisition.?,
        (try c.decodeOwned(
            native.testing.occurrence.Occurrence,
            frame,
            (try fixture.namespace.store.recordBytes(
                frame,
                "occurrence",
                state.acquired.?.id,
                task,
            )).?,
        )).value,
    );
    try std.testing.expectEqualDeep(
        state.cleanup.?,
        (try c.decodeOwned(
            native.testing.state.ControllerResidual,
            frame,
            (try fixture.namespace.store.recordBytes(
                frame,
                "controller_residual",
                state.cleanup.?.id,
                task,
            )).?,
        )).value,
    );
    try std.testing.expect(!try fixture.service.taskCleanupComplete(frame, rejected.value));
    try checkInvalidOutputEvent(context, rejected);
}

fn reopenInvalidOutput(context: anytype, state: *InvalidOutputProgress) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    state.output_stage = "blocked export";
    var client: native.client.Client(t) = .{ .service = fixture.service };
    var params = native.json.object();
    try native.json.put(
        frame,
        &params,
        "task_id",
        native.json.string(
            try std.fmt.allocPrint(frame, "{s}", .{std.fmt.bytesToHex(task, .lower)}),
        ),
    );
    try std.testing.expect(
        !(try client.call(frame, .@"task.result", params)).object.get("ready").?.bool,
    );
    const independent = try fixture.service.submit(
        frame,
        "unrelated-after-invalid-output",
        .{ .task = .{ .bytes = "An unrelated task remains admissible." } },
    );
    try std.testing.expectEqual(.accepted, independent.receipt.disposition);
    _ = try fixture.service.requestCancel(
        frame,
        "cancel-unrelated-output-task",
        independent.receipt.task,
        "No provider work is needed",
    );
    try fixture.service.validateWorkspace(frame, task);
    _ = try fixture.service.exportCheckpoint(
        frame,
        task,
        try std.fmt.allocPrint(frame, "{s}/blocked-output.agnx", .{fixture.directory}),
    );
    try fixture.service.close(frame);
    try fixture.namespace.close();
    state.output_stage = "blocked reopen";
    (fixture.namespace.*) = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    (fixture.service.*) = try recoveryService(fixture, fixture.namespace);
}

fn checkRetainedInvalidOutput(
    context: anytype,
    state: *InvalidOutputProgress,
    retained: anytype,
) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const c = protean.contracts;
    try std.testing.expectEqual(@as(u64, 1), retained.value.controller_epoch);
    try std.testing.expect(!retained.value.terminal());
    try std.testing.expectEqual(.denied, retained.value.blocker.?);
    try std.testing.expect(retained.value.result == null and retained.value.client_result == null);
    try std.testing.expectEqualDeep(state.accepted.?.checkpoint, retained.value.checkpoint);
    try std.testing.expectEqual(
        state.accepted.?.execution_revision,
        retained.value.execution_revision,
    );
    try std.testing.expectEqualDeep(
        state.preserved_acquisition.?,
        (try c.decodeOwned(
            native.testing.occurrence.Occurrence,
            frame,
            (try fixture.namespace.store.recordBytes(
                frame,
                "occurrence",
                state.acquired.?.id,
                task,
            )).?,
        )).value,
    );
    try fixture.service.validateWorkspace(frame, task);
}

fn cancelInvalidOutput(context: anytype, state: *InvalidOutputProgress, retained: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const c = protean.contracts;
    state.output_stage = "cancel rejected result";
    _ = try fixture.service.requestCancel(
        frame,
        "cancel-invented-output",
        task,
        "Invalid evidence was not published",
    );
    for (0..4096) |_| {
        try std.testing.expect(try fixture.service.pump(frame) != .work);
        var cancelled = try fixture.service.task(frame, task);
        defer cancelled.deinit();
        if (cancelled.value.terminal() and try fixture.service.taskCleanupComplete(
            frame,
            cancelled.value,
        )) {
            try std.testing.expectEqual(.cancelled, cancelled.value.outcome_kind);
            try std.testing.expect(cancelled.value.client_result == null);
            try std.testing.expectEqual(
                retained.value.inference_attempts,
                cancelled.value.inference_attempts,
            );
            const consumed = (try c.decodeOwned(
                native.testing.occurrence.Occurrence,
                frame,
                (try fixture.namespace.store.recordBytes(
                    frame,
                    "occurrence",
                    state.acquired.?.id,
                    task,
                )).?,
            )).value;
            try std.testing.expect(
                consumed.state == .admitted and consumed.state.admitted == .reply,
            );
            try std.testing.expectEqualDeep(
                state.acquired.?.state.settled_reply,
                consumed.state.admitted.reply,
            );
            _ = try fixture.service.exportCheckpoint(
                frame,
                task,
                try std.fmt.allocPrint(frame, "{s}/rejected-output.agnx", .{fixture.directory}),
            );
            return;
        }
    }
    return error.RejectedOutputDidNotCancel;
}

fn rejectInvalidOutput(context: anytype, state: *InvalidOutputProgress) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    for (0..4096) |_| {
        var before = try fixture.service.task(frame, task);
        defer before.deinit();
        if (before.value.controller_epoch == 1 and state.cleanup == null)
            try parkInvalidOutputCleanup(context, state);
        try retainInvalidOutputHandoff(context, state, before);
        state.accepted = before.value;
        const pending_before = try invalidOutputPending(context, state, before);
        try advanceInvalidOutput(context, state);
        var rejected = try fixture.service.task(frame, task);
        defer rejected.deinit();
        if (rejected.value.blocker == .denied) {
            try checkInvalidOutputRejection(context, state, rejected, pending_before);
            break;
        }
    } else return error.InventedOutputWasNotRejected;
}

const InvalidOutputProgress = struct {
    output_stage: []const u8 = "install",
    accepted: ?native.testing.state.Task = null,
    acquired: ?native.testing.occurrence.Occurrence = null,
    preserved_acquisition: ?native.testing.occurrence.Occurrence = null,
    cleanup: ?native.testing.state.ControllerResidual = null,
    captured_outer: bool = false,
    model_replies: usize = 0,
};

fn closeRecoveryFixture(fixture: anytype, frame: std.mem.Allocator) !void {
    try fixture.service.close(frame);
    fixture.service_live.* = false;
    try fixture.namespace.close();
    fixture.namespace_live.* = false;
}
fn openRecoveryFixture(fixture: anytype) !void {
    fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    fixture.namespace_live.* = true;
    fixture.service.* = try recoveryService(fixture, fixture.namespace);
    fixture.service_live.* = true;
}

fn checkUnsettledImport(comptime recovery_probe: RecoveryProbe, context: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const unresolved_archive = try std.fmt.allocPrint(
        frame,
        "{s}/unsettled.agnx",
        .{fixture.directory},
    );
    _ = try fixture.service.exportCheckpoint(frame, task, unresolved_archive);
    try fixture.service.close(frame);
    (fixture.service_live.*) = false;
    try fixture.namespace.close();
    (fixture.namespace_live.*) = false;
    const copy_path = try std.fmt.allocPrint(
        frame,
        "{s}/unsettled-import",
        .{fixture.directory},
    );
    var copy_namespace = try native.Namespace.open(fixture.a, fixture.io, copy_path);
    defer expectCleanup("copy_namespace.close", copy_namespace.close());
    var copy = try recoveryService(fixture, &copy_namespace);
    defer expectCleanup("copy.close", copy.close(frame));
    _ = try copy.importCheckpoint(frame, "import-unsettled", unresolved_archive);
    try std.testing.expect((try copy.pump(frame)) == .idle);
    try checkImportedRecoveryAdmission(context, &copy_namespace, &copy);
    var copied = try copy.task(frame, task);
    defer copied.deinit();
    try std.testing.expect(copied.value.schedule == .parked);
    try std.testing.expectEqual(
        context.unchanged.inference_attempts,
        copied.value.inference_attempts,
    );
    try std.testing.expectEqual(
        context.unchanged.inference_request_bytes,
        copied.value.inference_request_bytes,
    );
    try checkUnsettledPrivacy(recovery_probe, context, &copy_namespace, &copy, copied);
}

fn settleRecoveredCapture(comptime _: RecoveryProbe, context: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const reconciliation_id = context.reconciliation_id;
    const reply = context.reply;
    const State = native.testing.state;
    try std.testing.expect(context.recorded.outcome == .capture_admitted);
    try std.testing.expectError(
        error.ArtifactUnavailable,
        fixture.service.projectedArtifact(
            frame,
            task,
            context.recorded.outcome.capture_admitted.digest,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        reply,
        try fixture.namespace.store.object(
            frame,
            context.recorded.outcome.capture_admitted,
            null,
        ),
    );
    var original_task = try fixture.service.task(frame, task);
    defer original_task.deinit();
    _ = try fixture.service.resumeTask(
        frame,
        "interpret-original",
        task,
        original_task.value.revision,
    );
    _ = try fixture.service.pump(frame);
    var settled = try protean.contracts.decodeOwned(
        State.Reconciliation,
        frame,
        (try fixture.namespace.store.recordBytes(
            frame,
            "reconciliation",
            reconciliation_id,
            task,
        )).?,
    );
    defer settled.deinit();
    try std.testing.expect(settled.value.outcome == .reply_settled);
    try std.testing.expect(settled.value.previous != null);
    try std.testing.expectEqualDeep(
        context.recorded.original_occurrence,
        settled.value.original_occurrence,
    );
    try checkSettledImport(context);
}

fn checkProviderReopen(comptime _: RecoveryProbe, context: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const occurrence_id = context.occurrence_id;
    const attempt_id = context.attempt_id;
    const revision = context.revision;
    try closeRecoveryFixture(fixture, frame);
    try openRecoveryFixture(fixture);
    try std.testing.expect(
        (try fixture.service.reconcile(
            frame,
            "recover-original",
            task,
            revision,
            occurrence_id,
            attempt_id,
            .rederive,
        )).replayed,
    );
    var recovered_task = try fixture.service.task(frame, task);
    defer recovered_task.deinit();
    try std.testing.expectEqual(
        context.unchanged.inference_attempts,
        recovered_task.value.inference_attempts,
    );
    try std.testing.expectEqual(
        context.unchanged.inference_request_bytes,
        recovered_task.value.inference_request_bytes,
    );
    return;
}

fn runRecoveryDerivation(comptime _: RecoveryProbe, context: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const reply = context.reply;
    const computation = (try fixture.service.pump(frame)).work;
    const worker = try native.testing.Worker.init(fixture.a, fixture.io);
    defer expectCleanup("worker.deinit", worker.deinit(fixture.a));
    try worker.start(computation, fixture.profile.authority, null);
    const deadline = std.Io.Clock.awake.now(fixture.io).toMilliseconds() + 5000;
    while (!worker.finished()) {
        if (std.Io.Clock.awake.now(
            fixture.io,
        ).toMilliseconds() >= deadline) return error.WorkerTimeout;
        try fixture.io.sleep(.fromMilliseconds(1), .awake);
    }
    try worker.join();
    defer expectCleanup("worker.release", worker.release());
    try std.testing.expect(worker.result.? == .rederived);
    try std.testing.expectEqualSlices(u8, reply, worker.result.?.rederived.result);
    try fixture.service.completeWork(frame, computation, worker.result.?);
}

fn checkRecoveryReplay(comptime _: RecoveryProbe, context: anytype) !native.tasks.Admission {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const occurrence_id = context.occurrence_id;
    const attempt_id = context.attempt_id;
    const revision = context.revision;
    const admitted = try fixture.service.reconcile(
        frame,
        "recover-original",
        task,
        revision,
        occurrence_id,
        attempt_id,
        .rederive,
    );
    const committed = fixture.namespace.store.head;
    const replayed = try fixture.service.reconcile(
        frame,
        "recover-original",
        task,
        revision,
        occurrence_id,
        attempt_id,
        .rederive,
    );
    try std.testing.expect(replayed.replayed);
    try std.testing.expectEqualDeep(admitted.receipt.id, replayed.receipt.id);
    try std.testing.expectEqualDeep(committed, fixture.namespace.store.head);
    try std.testing.expectError(
        error.OperationConflict,
        fixture.service.reconcile(
            frame,
            "recover-original",
            task,
            revision + 1,
            occurrence_id,
            attempt_id,
            .rederive,
        ),
    );

    return admitted;
}

fn admitPublicRecovery(
    comptime recovery_probe: RecoveryProbe,
    context: anytype,
    before: anytype,
) !native.json.Value {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const revision = context.revision;
    var client: native.client.Client(t) = .{ .service = fixture.service };
    var status_params = native.json.object();
    try native.json.put(
        frame,
        &status_params,
        "task_id",
        native.json.string(try frame.dupe(u8, &std.fmt.bytesToHex(task, .lower))),
    );
    const status = try client.call(frame, .@"task.status", status_params);
    const availability = status.object.get("recovery").?;
    try std.testing.expectEqual(
        if (recovery_probe == .provider) @as(usize, 0) else 1,
        availability.object.get("mechanisms").?.array.items.len,
    );
    const params = try reconcileParameters(frame, status_params, availability, revision);
    var forged = try native.json.copy(frame, params);
    try native.json.put(
        frame,
        forged.object.getPtr("recovery").?,
        "safe_to_retry",
        .{ .bool = true },
    );
    try std.testing.expectError(
        error.InvalidParams,
        client.call(frame, .@"task.reconcile", forged),
    );
    try std.testing.expectEqualDeep(before, fixture.namespace.store.head);
    const public_admission = try client.call(frame, .@"task.reconcile", params);
    try std.testing.expect(!public_admission.object.get("replayed").?.bool);
    const public_recovery = public_admission.object.get("reconciliation").?;
    try std.testing.expectEqualStrings(
        if (recovery_probe == .provider) "unresolved" else "pending",
        public_recovery.object.get("status").?.string,
    );
    try std.testing.expectEqual(8, public_recovery.object.count());
    return status_params;
}

fn recoveryAssets(a: std.mem.Allocator, permanent: std.mem.Allocator) !native.discovery.Assets {
    const image = @embedFile("adaptive_image");
    const image_identity = identity: {
        const admitted_image = try horos.data.program_image.Admitted.decode(a, image);
        defer admitted_image.deinit();
        break :identity admitted_image.identity();
    };
    return imageAssets(permanent, image_identity);
}

fn recoveryProfile(
    a: std.mem.Allocator,
    configured: native.configuration.Admitted,
    handlers: native.Registry,
    application: *native.discovery.Application,
    grants: []native.registry.Grant,
) !native.tasks.Profile {
    const profile: native.tasks.Profile = .{
        .id = configured.id,
        .runtime_identity = @splat(73),
        .bytes = configured.bytes,
        .environment = configured.environment,
        .resources = configured.resources,
        .authority = .{
            .grants = grants,
            .principal = "adaptive-unit",
            .tenant = "local",
            .inference = true,
        },
    };
    for (grants, handlers.entries) |*grant, entry| grant.* = .{
        .identity = entry.declaration.identity,
        .resource_role = entry.declaration.resource_role,
        .resource_identity = try profile.resourceIdentity(a, application.image_identity),
    };

    return profile;
}

fn submitRecoveryTask(service: *native.tasks.Service(t), permanent: std.mem.Allocator) ![16]u8 {
    // Large admitted task/input text must survive transcript continuation,
    // including captured-before-interpreted recovery.
    const task = (try service.submit(
        permanent,
        "adaptive-recovery-submit",
        .{ .task = .{ .bytes = &long_task } },
    )).receipt.task;
    _ = try service.message(
        permanent,
        "large-followup-one",
        task,
        .{ .message = .{ .bytes = &long_followup } },
    );
    _ = try service.message(
        permanent,
        "large-followup-two",
        task,
        .{ .message = .{ .bytes = &long_followup } },
    );

    return task;
}

fn checkImportedPreparation(
    fixture: anytype,
    state: *AdaptiveProgress,
    scratch: *kosmos.AllocationBudget,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    request: anytype,
    saved: anytype,
    adapter: native.registry.CaptureAdapter,
) !void {
    errdefer expectCleanup("fixture.service.unknown", fixture.service.unknown(frame, work));
    var probe_arena = std.heap.ArenaAllocator.init(scratch.allocator());
    defer probe_arena.deinit();
    const probe = probe_arena.allocator();
    const projection = struct {
        adapter: native.registry.CaptureAdapter,
        payload: []const u8,
        pub fn run(this: @This(), ctx: native.registry.ProjectionContext) ![]u8 {
            return this.adapter.prepare(ctx, this.payload);
        }
    }{ .adapter = adapter, .payload = try work.entry.payload(
        probe,
        request.value.binding.payload,
    ) };
    const binding: native.registry.ProjectionBinding = .{
        .task = task,
        .tenant = fixture.profile.authority.tenant,
        .profile = fixture.profile.bytes,
        .application = fixture.application.image_identity,
        .resources = saved.value.resources.items,
        .controller = work.controller_projection,
    };
    _ = try fixture.namespace.store.project(
        []u8,
        probe,
        fixture.handlers,
        binding,
        projection,
    );
    const cache = &fixture.namespace.store.context_cache;
    cache.hits = 0;
    cache.misses = 0;
    cache.ancestry_bytes = 0;
    cache.object_reads = 0;
    cache.object_bytes = 0;
    const repeated = try fixture.namespace.store.project(
        []u8,
        probe,
        fixture.handlers,
        binding,
        projection,
    );
    try std.testing.expectEqualSlices(u8, work.prepared.?, repeated);
    std.debug.print(
        "same-service import model_calls={d} hits={d} misses={d} ancestry_" ++
            "bytes={d} reads={d} bytes={d}\n",
        .{
            state.model_calls,
            cache.hits,
            cache.misses,
            cache.ancestry_bytes,
            cache.object_reads,
            cache.object_bytes,
        },
    );
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
    try std.testing.expectEqual(@as(u64, 0), cache.ancestry_bytes);
}

fn checkLongRecoveryInput(frame: std.mem.Allocator, work: anytype) !void {
    var prepared = try protean.contracts.decodeOwned(
        t.P.AdaptivePrepared,
        frame,
        work.prepared.?,
    );
    defer prepared.deinit();
    const rendered = try native.json.parseAsset(
        frame,
        prepared.value.body.bytes,
        prepared.value.body.bytes.len,
    );
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

fn correctedRecoveryReply(
    state: *AdaptiveProgress,
    frame: std.mem.Allocator,
    work: anytype,
) ![]const u8 {
    if (state.model_calls == 15) try checkReportRejection(frame, work);
    const name = if (state.model_calls == 13) "read" else "report";
    const arguments = try correctedReportArguments(frame, state.model_calls);
    const call = try std.fmt.allocPrint(frame, "report-{d}", .{state.model_calls});
    const provider = try std.json.Stringify.valueAlloc(
        frame,
        .{
            .id = call,
            .status = "completed",
            .@"error" = @as(?u8, null),
            .output = .{
                .{
                    .type = "function_call",
                    .status = "completed",
                    .call_id = call,
                    .name = name,
                    .arguments = arguments,
                },
            },
        },
        .{},
    );
    return try protean.contracts.encodeOwned(
        native.responses.Raw,
        frame,
        .{
            .status = 200,
            .identity_encoding = true,
            .request_id = null,
            .body = .{ .bytes = provider },
        },
    );
}

fn checkReportRejection(frame: std.mem.Allocator, work: anytype) !void {
    var prepared = try protean.contracts.decodeOwned(
        t.P.AdaptivePrepared,
        frame,
        work.prepared.?,
    );
    defer prepared.deinit();
    const prior = prepared.value.request.results.items;
    try std.testing.expectEqual(@as(usize, 1), prior.len);
    try std.testing.expectEqualStrings("report-14", prior[0].call_id.bytes);
    const rejection_json = (try native.json.parse(frame, prior[0].output.bytes, .{})).value;
    const rejection = try native.values.fromJson(t.ReportRejection, frame, rejection_json);
    try std.testing.expectEqualDeep(
        t.ReportRejection{
            .reason = .out_of_range,
            .claim_index = 0,
            .evidence_position = 1,
        },
        rejection,
    );
}

fn correctedReportArguments(frame: std.mem.Allocator, model_calls: usize) ![]const u8 {
    return if (model_calls == 13)
        "{\"path\":\"src/main.zig\",\"start\":0,\"maximum\":32}"
    else if (model_calls == 14)
        "{\"summary\":\"Invalid citation\",\"claims\":[{\"kind\":\"observa" ++
            "tion\",\"statement\":\"Observed\",\"reasoning\":\"\",\"evidence_i" ++
            "ndices\":[0,2]}],\"limitations\":[]}"
    else blk_args: {
        const summary = try frame.alloc(u8, 70 * 1024);
        @memset(summary, 'S');
        break :blk_args try std.json.Stringify.valueAlloc(
            frame,
            .{ .summary = summary, .claims = .{
                .{
                    .kind = "observation",
                    .statement = "Both ranges are retained.",
                    .reasoning = "",
                    .evidence_indices = .{ 0, 1 },
                },
                .{
                    .kind = "inference",
                    .statement = "The ranges overlap.",
                    .reasoning = "Both begin at offset zero.",
                    .evidence_indices = .{1},
                },
                .{
                    .kind = "hypothesis",
                    .statement = "Other files may differ.",
                    .reasoning = "They were not inspected.",
                    .evidence_indices = .{},
                },
            }, .limitations = .{"No entailment proof is claimed."} },
            .{},
        );
    };
}

fn removeRetainedContextDependency(fixture: anytype, state: *AdaptiveProgress, task: [16]u8) !void {
    // Keep every object byte intact while dropping one registered context
    // dependency. Reopen must reconstruct that edge from the exact codec,
    // rather than treating the truncated metadata as proof of closure.
    const raw = (try fixture.namespace.store.recordBytes(
        fixture.permanent,
        "capture",
        state.last_model_capture.?,
        task,
    )).?;
    var captured = try protean.contracts.decodeOwned(CaptureRecord, fixture.permanent, raw);
    defer captured.deinit();
    const objects = captured.value.projection.?.objects.items;
    const root = objects[objects.len - 1];
    var context = try protean.contracts.decodeOwned(
        t.P.AdaptiveContext,
        fixture.permanent,
        try fixture.namespace.store.object(
            fixture.permanent,
            .{ .digest = root.digest, .bytes = root.bytes },
            null,
        ),
    );
    defer context.deinit();
    try std.testing.expectEqualStrings(
        t.P.adaptive_context_identity,
        context.value.schema.bytes,
    );
    fixture.namespace.store.invalidateIntegrity();
    try fixture.namespace.store.begin();
    try fixture.namespace.store.database.run(
        "DELETE FROM dependencies WHERE parent=? AND child=?",
        &.{ .{ .blob = &root.digest }, .{ .blob = &context.value.source_capture.digest } },
    );
    try std.testing.expectEqual(1, try fixture.namespace.store.database.changes());
    try fixture.namespace.commit("test.missing-context-dependency");
}

fn invalidOutputCarry(
    service: *native.tasks.Service(t),
    a: std.mem.Allocator,
    task: [16]u8,
) !t.ControllerCarry {
    const c = protean.contracts;
    var parent = try service.task(a, task);
    defer parent.deinit();
    const interaction = (try c.decodeOwned(
        native.testing.state.ControllerInteraction,
        a,
        (try service.namespace.store.recordBytes(
            a,
            "controller_interaction",
            parent.value.controller_interaction.?,
            task,
        )).?,
    )).value;
    const carry = (try c.decodeOwned(
        t.ControllerCarry,
        a,
        try service.namespace.store.object(a, interaction.carry, null),
    )).value;

    return carry;
}

fn inventedOutput(claims: *[1]InventedClaim, carry: t.ControllerCarry, uncited: bool) t.Output {
    claims.* = .{
        .{
            .kind = if (uncited) .hypothesis else .observation,
            .statement = .{ .bytes = "The source might establish this claim" },
            .reasoning = .{
                .bytes = if (uncited) "A hypothesis without any cited claim" else "",
            },
            .evidence_indices = .{ .items = if (uncited) &.{} else &.{0} },
        },
    };
    return .{
        .result = .{
            .report = .{
                .summary = .{ .bytes = "Unsubstantiated result" },
                .claims = .{ .items = claims },
                .limitations = .{ .items = &.{} },
            },
        },
        .evidence = .{
            .items = if (uncited) &.{} else &.{
                .{
                    .source = .{
                        .object = .{ .digest = @splat(194), .bytes = 12 },
                        .snapshot = @splat(195),
                        .path = .{ .bytes = "unacquired.zig" },
                        .sha256 = .{ .bytes = &(@as([64]u8, @splat('a'))) },
                        .start = 0,
                        .end = 12,
                        .file_bytes = 12,
                    },
                },
            },
        },
        .programs = .{ .items = &.{} },
        .control = carry.state.control,
        .receipts = .{ .items = &.{} },
        .model_calls = 1,
        .work_calls = 0,
    };
}

fn installForeignOutput(
    service: *native.tasks.Service(t),
    a: std.mem.Allocator,
    output: *t.Output,
    check: OutputCheck,
) !void {
    const c = protean.contracts;
    const foreign = (try service.submit(
        a,
        "foreign-output-owner",
        .{ .task = .{ .bytes = "Own the output reference without sharing it." } },
    )).receipt.task;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const boolean = try c.schema(bool, &b);
    const entry = try b.declare(&.{boolean}, boolean, &.{}, &.{});
    try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
    const built = try service.workspaceCommand(
        a,
        "foreign-output-program",
        foreign,
        .{
            .program = .{
                .build = .{
                    .source = .{
                        .json_text = .{
                            .bytes = try native.source_records.encode(
                                a,
                                b.module(entry, try c.schema(void, &b)),
                            ),
                        },
                    },
                    .source_kind = .source_records,
                    .exposures = .{ .items = &.{} },
                },
            },
        },
    );
    if (built.disposition != .observed) std.debug.print(
        "invalid output {s} foreign program: {s}\n",
        .{ @tagName(check), built.observation_json.bytes },
    );
    try std.testing.expectEqual(.observed, built.disposition);
    const reference = if (check == .foreign_value)
        try foreignOutputValue(service, a, foreign, built, check)
    else
        built.program.?;
    if (check == .foreign_value) {
        output.*.evidence = .{
            .items = try a.dupe(t.EvidenceReference, &.{.{ .workspace = reference }}),
        };
    } else {
        output.*.result = .{
            .no_result = .{ .bytes = "A program reference requires its owning task." },
        };
        output.*.evidence = .{ .items = &.{} };
        output.*.programs = .{ .items = try a.dupe(c.workspace.Ref, &.{reference}) };
    }
    _ = try service.requestCancel(
        a,
        "cancel-foreign-output-owner",
        foreign,
        "Keep the reference without executing its owner",
    );
}

fn buildInventedProgram(
    service: *native.tasks.Service(t),
    a: std.mem.Allocator,
    task: [16]u8,
    request: t.P.AdaptiveRequest,
    output: t.Output,
    i: usize,
) !protean.contracts.workspace.Ref {
    const c = protean.contracts;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const boolean = try c.schema(bool, &b);
    const failure = try c.schema(t.Failure, &b);
    const module = if (i == 0)
        try inventedControllerModule(&b, a, request, output, boolean, failure)
    else
        try inventedConverterModule(&b, boolean);
    const built = try service.workspaceCommand(
        a,
        if (i == 0) "invented-controller" else "invented-converter",
        task,
        .{
            .program = .{
                .build = .{
                    .source = .{
                        .json_text = .{ .bytes = try native.source_records.encode(a, module) },
                    },
                    .source_kind = .source_records,
                    .exposures = .{ .items = &.{} },
                    .role = if (i == 0) .controller else .computation,
                },
            },
        },
    );
    if (built.disposition != .observed) std.debug.print(
        "invented output build {d}: {s}\n",
        .{ i, built.observation_json.bytes },
    );
    try std.testing.expectEqual(.observed, built.disposition);
    return built.program.?;
}

fn inventedControllerModule(
    b: *horos.source.Builder,
    a: std.mem.Allocator,
    request: t.P.AdaptiveRequest,
    output: t.Output,
    boolean: horos.source.Id,
    failure: horos.source.Id,
) !horos.source.Module {
    const c = protean.contracts;
    const input = try b.schema(
        .{ .product = &.{ try c.schema(c.controller.TaskAnchor, b), boolean } },
    );
    const unit = try c.schema(void, b);
    const payload = try b.schema(
        .{ .product = &.{ try c.schema(t.P.AdaptiveRequest, b), unit } },
    );
    const reply = try c.schema(c.controller.Reply(t.P.AdaptiveResult), b);
    const deliberate = try b.effect(
        .{
            .identity = "controller/1/deliberate",
            .payload = payload,
            .result = reply,
            .external = false,
        },
    );
    const entry = try b.declare(&.{input}, try c.schema(t.Output, b), &.{deliberate}, &.{});
    const result = try b.pure(
        try b.literal(
            .{
                .schema = try c.schema(t.Output, b),
                .bytes = try c.encodeOwned(t.Output, a, output),
            },
        ),
    );
    const request_value = try b.literal(
        .{
            .schema = try c.schema(t.P.AdaptiveRequest, b),
            .bytes = try c.encodeOwned(t.P.AdaptiveRequest, a, request),
        },
    );
    const call = try b.term(
        .{
            .perform = .{
                .effect = deliberate,
                .payload = try b.primitive(
                    payload,
                    .product,
                    &.{ request_value, try b.constant(void, {}) },
                    0,
                ),
            },
        },
    );
    try b.define(entry, try b.term(.{ .conditional = .{
        .condition = try b.primitive(
            boolean,
            .field,
            &.{try b.reference(b.parameter(entry, 0))},
            1,
        ),
        .when_true = try b.bind(try b.variable(reply), call, result),
        .when_false = result,
    } }));
    return b.module(entry, failure);
}

fn inventedConverterModule(
    b: *horos.source.Builder,
    boolean: horos.source.Id,
) !horos.source.Module {
    const c = protean.contracts;
    const input = try b.schema(
        .{
            .product = &.{
                try c.schema(t.ControllerCarry, b),
                try c.schema(c.controller.OwnerView, b),
            },
        },
    );
    const entry = try b.declare(&.{input}, boolean, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(bool, true)));
    return b.module(entry, try c.schema(void, b));
}

fn appendRecipeComposition(
    a: std.mem.Allocator,
    stages: []const Stage,
    i: usize,
    key: []const u8,
    instances: *std.ArrayList(@FieldType(wire.Recipe, "instances").Child),
    bindings: *std.ArrayList(@FieldType(wire.Recipe, "bindings").Child),
) !void {
    const composition = try std.fmt.allocPrint(a, "compose{d}", .{i});
    try instances.append(
        a,
        .{ .key = .{ .bytes = composition }, .component_id = .{ .bytes = "compose" } },
    );
    try bindings.append(
        a,
        .{
            .required = .{
                .instance = .{ .bytes = composition },
                .symbol = .{ .bytes = "first" },
            },
            .supplied = .{ .instance = .{ .bytes = key }, .symbol = .{ .bytes = "apply" } },
        },
    );
    const second = try std.fmt.allocPrint(
        a,
        "{s}{d}",
        .{ if (i + 2 == stages.len) "stage" else "compose", i + 1 },
    );
    try bindings.append(
        a,
        .{
            .required = .{
                .instance = .{ .bytes = composition },
                .symbol = .{ .bytes = "second" },
            },
            .supplied = .{
                .instance = .{ .bytes = second },
                .symbol = .{ .bytes = "apply" },
            },
        },
    );
}

fn checkWorkspaceCompleted(
    comptime interrupted: bool,
    comptime reframing: bool,
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    task: [16]u8,
    parent: anytype,
) !void {
    if (reframing) {
        if (!state.trace.done) std.debug.print(
            "reframing stopped phase={d} model_calls={d} outcome={s}\n",
            .{ state.trace.phase, state.stage, @tagName(parent.value.outcome_kind) },
        );
        try std.testing.expect(state.trace.done);
        var id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id, state.trace.abandoned.work.id.bytes);
        var abandoned = try fixture.service.workspaceWork(frame, task, id);
        defer abandoned.deinit();
        try std.testing.expectEqual(.requested, abandoned.value.outcome_kind);
        try std.testing.expectEqual(.parked, abandoned.value.schedule);
        try std.testing.expect(
            abandoned.value.current_port != null and abandoned.value.result == null,
        );
        try std.testing.expect(
            !try fixture.service.taskCleanupComplete(frame, parent.value),
        );
    } else try std.testing.expect(state.restarted and state.inspected);
    try std.testing.expectEqual(
        @as(usize, if (interrupted or reframing) 2 else 1),
        state.build_dispatches,
    );
    try std.testing.expectEqual(state.stage, parent.value.inference_attempts);
}

fn acquireWorkspaceAction(
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    work: anytype,
    action: t.Action,
) !void {
    const c = protean.contracts;
    const encoded = try modelArguments(t.Action, frame, action);
    const name = @tagName(action);
    const arguments = try native.json.canonical(frame, encoded.object.get("value").?);
    const response = try std.json.Stringify.valueAlloc(
        frame,
        .{
            .status = "completed",
            .@"error" = @as(?u8, null),
            .output = .{
                .{
                    .type = "function_call",
                    .status = "completed",
                    .call_id = try std.fmt.allocPrint(
                        frame,
                        "workspace-{d}",
                        .{state.stage},
                    ),
                    .name = name,
                    .arguments = arguments,
                },
            },
        },
        .{},
    );
    const raw = try c.encodeOwned(
        native.responses.Raw,
        frame,
        .{
            .status = 200,
            .identity_encoding = true,
            .request_id = null,
            .body = .{ .bytes = response },
        },
    );
    state.stage += 1;
    try fixture.service.acquire(frame, work, raw);
}

fn acquireWorkspaceEffect(
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
) !void {
    var request = try protocol.decode(protocol.Request, frame, work.request);
    defer request.deinit();
    const ctx: native.Context = .{
        .allocator = frame,
        .io = fixture.io,
        .authority = &fixture.profile.authority,
        .task_id = &std.fmt.bytesToHex(task, .lower),
        .profile = fixture.profile.bytes,
        .environment = fixture.profile.environment,
    };
    const reply = if (work.entry.declaration.capture) |adapter| blk: {
        const acquired = try adapter.acquire(ctx, work.prepared.?);
        try std.testing.expect(acquired == .captured);
        break :blk acquired.captured;
    } else try work.entry.declaration.invoke.?(ctx, request.value.binding.payload);
    try fixture.service.acquire(frame, work, reply);
}

fn captureWorkspaceBuild(
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    work: anytype,
) !void {
    const c = protean.contracts;
    const worker = try native.testing.Worker.init(fixture.a, fixture.io);
    defer expectCleanup("worker.deinit", worker.deinit(fixture.a));
    try worker.start(work, fixture.profile.authority, null);
    while (!worker.finished()) try fixture.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    defer expectCleanup("worker.release", worker.release());
    try std.testing.expect(worker.result.? == .acquired);
    // The capture carries actual compiled bytes, not a model result.
    const BuildOutput = struct {
        const Compiled = struct {
            image: c.Bytes(null),
            interface: c.tool_construction.Interface,
            ports: c.Vector(native.program_construction.PortInterface, null),
            controller: ?c.controller.Descriptor,
            compiler_nanoseconds: u64,
        };
        const Output = union(enum) { compiled: Compiled, rejected: struct {
            code: c.Utf8,
            phase: c.Utf8,
            function: ?u64,
            term: ?u64,
            value: ?u64,
            compiler_nanoseconds: u64,
        } };
    };
    var output = try c.decodeOwned(BuildOutput.Output, frame, worker.result.?.acquired);
    defer output.deinit();
    try std.testing.expect(output.value == .compiled);
    state.compiled_image = try fixture.permanent.dupe(u8, output.value.compiled.image.bytes);
    try fixture.service.completeWork(frame, work, worker.result.?);
}

fn materializeRecoveredInput(
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    task: [16]u8,
    observation: native.json.Value,
    recipe: []const u8,
) !t.Action {
    const wc = protean.contracts.workspace;
    state.program = try native.values.fromJson(
        wc.Ref,
        fixture.permanent,
        observation.object.get("program").?,
    );
    var id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id, state.program.id.bytes);
    var stored = try fixture.service.workspaceProgram(frame, task, id);
    defer stored.deinit();
    try std.testing.expectEqualSlices(
        u8,
        state.compiled_image.?,
        try fixture.namespace.store.object(frame, stored.value.description.image, null),
    );
    try std.testing.expectEqualStrings(
        recipe,
        try fixture.namespace.store.object(frame, stored.value.description.source, null),
    );
    return .{
        .context = .{
            .command = .{
                .materialize = .{
                    .input = .{ .authorized_input = .{ .bytes = "retained-table" } },
                    .sources = .{ .items = &.{} },
                },
            },
        },
    };
}

fn inspectRecoveredWork(
    fixture: anytype,
    state: *WorkspaceProgress,
    frame: std.mem.Allocator,
    observation: native.json.Value,
) !t.Action {
    const wc = protean.contracts.workspace;
    if (state.stage == 3) state.child = try native.values.fromJson(
        wc.Ref,
        fixture.permanent,
        observation.object.get("work").?,
    );
    if (!std.mem.eql(u8, observation.object.get("outcome").?.string, "completed")) {
        return .{ .work = .{ .command = .{ .inspect = .{ .work = state.child } } } };
    }
    const preview = observation.object.get("result_preview").?.object.get("text").?.string;
    const table = (try native.json.parse(frame, preview, .{})).value;
    try std.testing.expectEqualStrings(
        "2",
        table.array.items[0].array.items[0].array.items[0].string,
    );
    try std.testing.expectEqualStrings(
        "1",
        table.array.items[1].array.items[0].array.items[0].string,
    );
    state.inspected = true;
    return .{
        .stop = .{
            .reason = .{
                .bytes = "Retained program and inputs executed correctly after recovery.",
            },
        },
    };
}

fn reframeBroaderEvidence(
    self: *ReframeTrace,
    a: std.mem.Allocator,
    observation: native.json.Value,
) !t.Action {
    const wc = protean.contracts.workspace;
    try std.testing.expectEqualStrings(
        "requested",
        observation.object.get("outcome").?.string,
    );
    try std.testing.expect(observation.object.get("port_accepts_command").?.bool);
    self.abandoned = .{
        .work = try native.values.fromJson(wc.Ref, a, observation.object.get("work").?),
        .execution_revision = try native.json.numberInteger(
            u64,
            try native.json.canonical(a, observation.object.get("execution_revision").?),
        ),
        .control_revision = try native.json.numberInteger(
            u64,
            try native.json.canonical(a, observation.object.get("control_revision").?),
        ),
    };
    return .{
        .context = .{
            .command = .{
                .materialize = .{
                    .input = .{
                        .snapshot = .{
                            .path = .{ .bytes = "input.zig" },
                            .offset = 0,
                            .maximum = 4096,
                        },
                    },
                    .sources = .{ .items = &.{} },
                },
            },
        },
    };
}

fn reframeComputedResult(
    self: *ReframeTrace,
    a: std.mem.Allocator,
    observation: native.json.Value,
    phase: usize,
) !t.Action {
    const wc = protean.contracts.workspace;
    self.current = try native.values.fromJson(wc.Ref, a, observation.object.get("work").?);
    if (!std.mem.eql(u8, observation.object.get("outcome").?.string, "completed")) {
        self.phase -= 1;
        return .{ .work = .{ .command = .{ .inspect = .{ .work = self.current } } } };
    }
    const result = observation.object.get("result_preview").?.object.get("text").?.string;
    try std.testing.expectEqualStrings(if (phase == 6) "\"6\"" else "\"7\"", result);
    const ref = try native.values.fromJson(wc.Ref, a, observation.object.get("result").?);
    if (phase == 6) {
        self.first = ref;
        return self.start("[\"35\",\"14\"]");
    }
    const refs = try a.dupe(wc.Ref, &.{ self.first, ref });
    return .{ .context = .{ .command = .{ .select = .{ .values = .{ .items = refs } } } } };
}

fn recoveryService(fixture: anytype, namespace: *native.Namespace) !native.tasks.Service(t) {
    return native.tasks.Service(t).init(
        fixture.a,
        fixture.io,
        namespace,
        fixture.assets,
        fixture.application,
        fixture.handlers,
        fixture.profile,
    );
}

fn checkContradictoryCapture(
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    destination: *native.Namespace,
    imported: *native.tasks.Service(t),
) !void {
    const second_archive = try std.fmt.allocPrint(
        frame,
        "{s}/still-malformed.agnx",
        .{fixture.directory},
    );
    // The broader archive domain must still reject contradictory
    // occurrence/capture facts, even when every object hashes.
    var occurrence_record = try protean.contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        frame,
        (try destination.store.recordBytes(frame, "occurrence", work.occurrence, task)).?,
    );
    defer occurrence_record.deinit();
    var contradictory = occurrence_record.value;
    contradictory.state = .{ .unknown = .{ .id = work.attempt } };
    destination.store.invalidateIntegrity();
    try destination.store.begin();
    try destination.store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        work.occurrence,
        task,
        contradictory,
    );
    try destination.commit("test.contradictory-capture");
    try std.testing.expectError(
        error.CorruptState,
        imported.exportCheckpoint(frame, task, second_archive),
    );
    try destination.store.begin();
    try destination.store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        work.occurrence,
        task,
        occurrence_record.value,
    );
    try destination.commit("test.restore-captured-occurrence");
    _ = try imported.exportCheckpoint(frame, task, second_archive);
}

fn checkMalformedOwner(
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    destination: *native.Namespace,
    imported: *native.tasks.Service(t),
    rejected_task: anytype,
    retained: anytype,
) !void {
    const State = native.testing.state;
    var owned_task = try imported.task(frame, task);
    defer owned_task.deinit();
    _ = try imported.resumeTask(frame, "interpret-malformed", task, owned_task.value.revision);
    _ = try imported.pump(frame);
    var still_blocked = try imported.task(frame, task);
    defer still_blocked.deinit();
    try std.testing.expectEqual(
        native.tasks.Status.blocked,
        try imported.status(frame, still_blocked.value),
    );
    try std.testing.expectEqual(
        rejected_task.value.inference_attempts,
        still_blocked.value.inference_attempts,
    );
    try std.testing.expectEqual(
        rejected_task.value.inference_request_bytes,
        still_blocked.value.inference_request_bytes,
    );
    try std.testing.expectEqual(
        rejected_task.value.inference_output_tokens,
        still_blocked.value.inference_output_tokens,
    );
    var untouched = try protean.contracts.decodeOwned(
        State.Capture,
        frame,
        (try destination.store.recordBytes(frame, "capture", work.attempt, task)).?,
    );
    defer untouched.deinit();
    try std.testing.expectEqualDeep(retained.value, untouched.value);
    try std.testing.expectError(
        error.ArtifactUnavailable,
        imported.projectedArtifact(frame, task, retained.value.response.?.digest),
    );
    try checkContradictoryCapture(fixture, frame, task, work, destination, imported);
}

fn checkMalformedImport(
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    rejected_task: anytype,
    retained: anytype,
    archive_path: []const u8,
) !void {
    const target = try std.fmt.allocPrint(frame, "{s}/malformed-import", .{fixture.directory});
    var destination = try native.Namespace.open(fixture.a, fixture.io, target);
    defer expectCleanup("destination.close", destination.close());
    var imported = try recoveryService(fixture, &destination);
    defer expectCleanup("imported.close", imported.close(frame));
    _ = try imported.importCheckpoint(frame, "import-malformed", archive_path);
    try std.testing.expect((try imported.pump(frame)) == .idle);
    var copied_task = try imported.task(frame, task);
    defer copied_task.deinit();
    try std.testing.expectError(
        error.CustodyNotLocal,
        imported.resumeTask(frame, "copy-cannot-interpret", task, copied_task.value.revision),
    );
    try imported.close(frame);
    try destination.close();
    destination = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    imported = try recoveryService(fixture, &destination);
    try checkMalformedOwner(
        fixture,
        frame,
        task,
        work,
        &destination,
        &imported,
        rejected_task,
        retained,
    );
}

fn checkUnknownRecovery(
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    saved: anytype,
    unchanged: anytype,
    inference: bool,
    occurrence_id: [32]u8,
    attempt_id: [32]u8,
) !void {
    try std.testing.expectEqual(
        saved.value.inference_attempts + @intFromBool(inference),
        unchanged.value.inference_attempts,
    );
    try std.testing.expectError(
        error.UnsettledOccurrence,
        fixture.service.resumeTask(
            frame,
            "recovery-does-not-settle",
            task,
            unchanged.value.revision,
        ),
    );
    var stale = attempt_id;
    stale[0] ^= 1;
    try std.testing.expectError(
        error.StaleOccurrence,
        fixture.service.reconcile(
            frame,
            "stale-recovery",
            task,
            unchanged.value.revision,
            occurrence_id,
            stale,
            .rederive,
        ),
    );
}

fn retainCaptureRestart(
    comptime recovery_probe: RecoveryProbe,
    fixture: anytype,
    frame: std.mem.Allocator,
    task: [16]u8,
    work: anytype,
    restart: *?CaptureRestart,
) !void {
    // No interpretation, receipt publication or Kosmos successor has
    // run after the raw control response became durable.
    const raw = (try fixture.namespace.store.recordBytes(
        frame,
        "capture",
        work.attempt,
        task,
    )) orelse return error.MissingCapture;
    var capture = try protean.contracts.decodeOwned(CaptureRecord, frame, raw);
    defer capture.deinit();
    try std.testing.expect(capture.value.projection == null);
    const imported_archive: ?[]const u8 = if (recovery_probe == .imported) try std.fmt.allocPrint(
        fixture.permanent,
        "{s}/captured.agnx",
        .{fixture.directory},
    ) else null;
    if (imported_archive) |archive_path| {
        _ = try fixture.service.exportCheckpoint(frame, task, archive_path);
    }
    restart.* = .{
        .attempt = work.attempt,
        .capture = try fixture.permanent.dupe(u8, raw),
        .archive = imported_archive,
    };
}

fn checkImportedRecoveryAdmission(
    context: anytype,
    destination: *native.Namespace,
    imported: *native.tasks.Service(t),
) !void {
    const frame = context.frame;
    const task = context.task;
    const revision = context.revision;
    const occurrence_id = context.occurrence_id;
    const attempt_id = context.attempt_id;
    const admitted = context.admitted;
    const copied_head = destination.store.head;
    const copied_receipt = try imported.reconcile(
        frame,
        "recover-original",
        task,
        revision,
        occurrence_id,
        attempt_id,
        .rederive,
    );
    try std.testing.expect(copied_receipt.replayed);
    try std.testing.expectEqualDeep(admitted.receipt, copied_receipt.receipt);
    try std.testing.expectError(
        error.CustodyNotLocal,
        imported.reconcile(
            frame,
            "copied-new-recovery",
            task,
            revision,
            occurrence_id,
            attempt_id,
            .rederive,
        ),
    );
    try std.testing.expectEqualDeep(copied_head, destination.store.head);
    try @import("native_test_support.zig").expectRetainedReceipt(
        frame,
        destination,
        admitted.receipt,
    );
}

fn checkRetainedReconciliationRequired(context: anytype, destination: *native.Namespace) !void {
    const fixture = context.fixture;
    const reconciliation_id = context.reconciliation_id;
    // Retaining the reply and raw capture cannot excuse losing
    // the recovery operation and its original ambiguous history.
    destination.store.invalidateIntegrity();
    try destination.store.begin();
    try destination.store.database.run(
        "DELETE FROM records WHERE kind='reconciliation' AND id=?",
        &.{.{ .blob = &reconciliation_id }},
    );
    try std.testing.expectEqual(1, try destination.store.database.changes());
    try std.testing.expectError(
        error.CorruptState,
        destination.store.auditRetention(fixture.handlers, fixture.application.image_identity),
    );
    destination.store.rollback();
}

fn checkSettledImport(context: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const archive_path = try std.fmt.allocPrint(
        frame,
        "{s}/rederived.agnx",
        .{fixture.directory},
    );
    _ = try fixture.service.exportCheckpoint(frame, task, archive_path);
    try fixture.service.close(frame);
    (fixture.service_live.*) = false;
    try fixture.namespace.close();
    (fixture.namespace_live.*) = false;
    const target = try std.fmt.allocPrint(frame, "{s}/rederived-import", .{fixture.directory});
    var destination = try native.Namespace.open(fixture.a, fixture.io, target);
    defer expectCleanup("destination.close", destination.close());
    var imported = try recoveryService(fixture, &destination);
    defer expectCleanup("imported.close", imported.close(frame));
    _ = try imported.importCheckpoint(frame, "import-rederived", archive_path);
    try checkImportedRecoveryAdmission(context, &destination, &imported);
    var imported_task = try imported.task(frame, task);
    defer imported_task.deinit();
    try std.testing.expectEqual(
        context.unchanged.inference_attempts,
        imported_task.value.inference_attempts,
    );
    try std.testing.expectEqual(
        context.unchanged.inference_request_bytes,
        imported_task.value.inference_request_bytes,
    );
    try std.testing.expectError(
        error.ArtifactUnavailable,
        imported.projectedArtifact(frame, task, context.recorded.original_occurrence.digest),
    );
    try checkRetainedReconciliationRequired(context, &destination);
}

fn checkInvalidOutputEvent(context: anytype, rejected: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    const c = protean.contracts;
    {
        var query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='root_operation'",
            &.{.{ .blob = &task }},
        );
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        const operation = (try c.decodeOwned(
            native.testing.state.RootOperation,
            frame,
            try query.bytes(0),
        )).value;
        try std.testing.expect(operation.pending == null);
        try std.testing.expectEqual(
            rejected.value.execution_revision,
            operation.execution_revision,
        );
    }
    var query = try fixture.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
            "RE e.task=? AND e.seq=?",
        &.{ .{ .blob = &task }, .{ .integer = @intCast(rejected.value.event_high) } },
    );
    defer query.deinit();
    try std.testing.expect(try query.step() == .row);
    const event = (try c.decodeOwned(
        native.testing.state.Event,
        frame,
        try query.bytes(0),
    )).value;
    try std.testing.expectEqual(.blocked, event.kind);
    try std.testing.expectEqualStrings(
        "InvalidResultReference",
        (try native.json.parse(frame, event.data.bytes, .{})).value.object.get(
            "reason",
        ).?.string,
    );
}

fn foreignOutputValue(
    service: *native.tasks.Service(t),
    a: std.mem.Allocator,
    foreign: [16]u8,
    built: anytype,
    check: OutputCheck,
) !protean.contracts.workspace.Ref {
    const c = protean.contracts;
    const observation = (try native.json.parse(a, built.observation_json.bytes, .{})).value;
    const schema = try native.values.fromJson(
        c.workspace.Ref,
        a,
        observation.object.get("input_schema").?,
    );
    const materialized = try service.workspaceCommand(
        a,
        "foreign-output-value",
        foreign,
        .{
            .context = .{
                .materialize = .{
                    .input = .{
                        .value = .{
                            .inline_json = .{
                                .schema = schema,
                                .json_text = .{ .bytes = "true" },
                            },
                        },
                    },
                    .sources = .{ .items = &.{} },
                },
            },
        },
    );
    if (materialized.disposition != .observed) std.debug.print(
        "invalid output {s} foreign value: {s}\n",
        .{ @tagName(check), materialized.observation_json.bytes },
    );
    try std.testing.expectEqual(.observed, materialized.disposition);
    return materialized.evidence.?;
}

fn checkReconciledCapture(
    comptime recovery_probe: RecoveryProbe,
    initial: anytype,
    admitted: native.tasks.Admission,
    unchanged: anytype,
    status_params: native.json.Value,
) !void {
    const fixture = initial.fixture;
    const frame = initial.frame;
    const task = initial.task;
    const occurrence_id = initial.occurrence_id;
    const attempt_id = initial.attempt_id;
    const revision = initial.revision;
    const reply = initial.reply;
    const reconciliation_id = admitted.receipt.reconciliation.?;
    const State = native.testing.state;
    var recorded = try protean.contracts.decodeOwned(
        State.Reconciliation,
        frame,
        (try fixture.namespace.store.recordBytes(
            frame,
            "reconciliation",
            reconciliation_id,
            task,
        )).?,
    );
    defer recorded.deinit();
    try std.testing.expectError(
        error.ArtifactUnavailable,
        fixture.service.projectedArtifact(frame, task, recorded.value.original_occurrence.digest),
    );
    try std.testing.expectError(
        error.ArtifactUnavailable,
        fixture.service.projectedArtifact(frame, task, recorded.value.original_attempt.digest),
    );
    try std.testing.expect(
        recorded.value.provenance == (if (recovery_probe == .provider) .none else .rederived),
    );
    var history_params = try native.json.copy(frame, status_params);
    try native.json.put(frame, &history_params, "after_seq", native.json.string("0"));
    try native.json.put(frame, &history_params, "limit", try native.json.number(frame, 128));
    const context = .{
        .fixture = fixture,
        .frame = frame,
        .task = task,
        .occurrence_id = occurrence_id,
        .attempt_id = attempt_id,
        .revision = revision,
        .reply = reply,
        .recorded = recorded.value,
        .unchanged = unchanged.value,
        .admitted = admitted,
        .reconciliation_id = reconciliation_id,
    };
    try checkUnsettledImport(recovery_probe, context);

    try checkReconciledOutcome(recovery_probe, context);
}

fn acquireRecoveryWork(
    comptime correction: bool,
    comptime recovery_probe: RecoveryProbe,
    fixture: anytype,
    state: *AdaptiveProgress,
    scratch: *kosmos.AllocationBudget,
    frame: std.mem.Allocator,
    task: [16]u8,
    restart: *?CaptureRestart,
    work: anytype,
    saved: anytype,
) !RecoveryProgress {
    var request = try protocol.decode(protocol.Request, frame, work.request);
    defer request.deinit();
    const reply = try adaptiveReply(
        correction,
        recovery_probe,
        fixture,
        state,
        scratch,
        frame,
        task,
        work,
        request,
        saved,
    );
    const inference = work.entry.declaration.inference;
    if (recovery_probe == .malformed and inference) {
        try malformedCapture(fixture, frame, task, work);
        return .handled;
    }
    if ((recovery_probe == .snapshot and work.entry.declaration.recovery != null) or
        (recovery_probe == .provider and inference))
    {
        try reconcileCapture(
            recovery_probe,
            fixture,
            frame,
            task,
            work,
            saved,
            inference,
            reply,
        );
        return .handled;
    }
    if (inference) state.model_calls += 1;
    try fixture.service.acquire(frame, work, reply);
    if (inference) state.last_model_capture = work.attempt;
    if (inference and state.model_calls == 8 and !state.restarted)
        try retainCaptureRestart(recovery_probe, fixture, frame, task, work, restart);

    return .next;
}

fn continuedAttemptLoop(fixture: anytype) !void {
    const parent = fixture.parent;
    const io = fixture.io;
    const service = fixture.service;
    const namespace = fixture.namespace;
    const profile = fixture.profile;
    const task = fixture.task;
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
            try std.testing.expectEqual(
                unsent + 1,
                (try service.task(frame, task)).value.inference_attempts,
            );
            if (unsent == 17) {
                try std.testing.expectEqual(
                    18,
                    try namespace.store.capabilityAttempts(task, t.P.identity),
                );
                try service.notSent(frame, work);
                return;
            }
            try service.notSent(frame, work);
            var stopped = try service.task(frame, task);
            defer stopped.deinit();
            _ = try service.resumeTask(
                frame,
                try std.fmt.allocPrint(frame, "retry-{d}", .{unsent}),
                task,
                stopped.value.revision,
            );
            unsent += 1;
        } else {
            var request = try protocol.decode(protocol.Request, frame, work.request);
            defer request.deinit();
            const ctx: native.Context = .{
                .allocator = frame,
                .io = io,
                .authority = &profile.authority,
                .task_id = "continued-attempts",
                .profile = profile.bytes,
                .environment = profile.environment,
            };
            const reply = if (work.entry.declaration.capture) |adapter| (try adapter.acquire(
                ctx,
                work.prepared.?,
            )).captured else try work.entry.declaration.invoke.?(
                ctx,
                request.value.binding.payload,
            );
            try service.acquire(frame, work, reply);
        }
    }
    return error.MissingContinuedAttempts;
}

const InventedClaim = @FieldType(
    @FieldType(@FieldType(t.Output, "result"), "report"),
    "claims",
).Child;

fn checkUnsettledPrivacy(
    comptime recovery_probe: RecoveryProbe,
    context: anytype,
    destination: *native.Namespace,
    copy: *native.tasks.Service(t),
    copied: anytype,
) !void {
    const frame = context.frame;
    const task = context.task;
    const reconciliation_id = context.reconciliation_id;
    const reply = context.reply;
    var observation = try copy.reconciliation(frame, task, reconciliation_id);
    defer observation.deinit();
    try std.testing.expectEqualDeep(context.recorded, observation.value);
    try std.testing.expectError(
        error.ArtifactUnavailable,
        copy.projectedArtifact(frame, task, context.recorded.original_occurrence.digest),
    );
    try std.testing.expectError(
        error.ArtifactUnavailable,
        copy.projectedArtifact(frame, task, context.recorded.original_attempt.digest),
    );
    if (context.recorded.prepared) |prepared| try std.testing.expectError(
        error.ArtifactUnavailable,
        copy.projectedArtifact(frame, task, prepared.digest),
    );
    if (recovery_probe == .provider) {
        try std.testing.expectError(
            error.CustodyNotLocal,
            copy.resumeTask(frame, "cannot-retry-import", task, copied.value.revision),
        );
    } else {
        const capture = context.recorded.outcome.capture_admitted;
        try std.testing.expectError(
            error.ArtifactUnavailable,
            copy.projectedArtifact(frame, task, capture.digest),
        );
        try std.testing.expectEqualSlices(
            u8,
            reply,
            try destination.store.object(frame, capture, null),
        );
        try std.testing.expectError(
            error.CustodyNotLocal,
            copy.resumeTask(frame, "interpret-import", task, copied.value.revision),
        );
        try std.testing.expectEqual(.idle, try copy.pump(frame));
        var interpreted = try copy.reconciliation(frame, task, reconciliation_id);
        defer interpreted.deinit();
        try std.testing.expectEqualDeep(context.recorded, interpreted.value);
    }
}

fn workspaceRecoveryHandlers(a: std.mem.Allocator) !native.Registry {
    var declarations = environment.handlers;
    for (&declarations) |*entry| if (entry.inference) {
        entry.capture.?.acquire = struct {
            fn forbidden(_: native.Context, _: []const u8) !native.registry.Acquisition {
                return error.ProviderAcquisitionForbidden;
            }
        }.forbidden;
    };
    return native.Registry.init(a, &declarations);
}

const reframing_result = "The binary framing was insufficient. Broader evidence and a new " ++
    "algorithm supplied the useful result; the old question remains unanswered.";
const reframing_task = "Investigate the measurements. You may abandon the initial binary " ++
    "classification and choose a useful numeric comparison after reading broader evidence.";
const retained_program_task = "Build swap, retain and execute it on the authorized table.";

fn reconcileParameters(
    frame: std.mem.Allocator,
    status_params: native.json.Value,
    availability: native.json.Value,
    revision: u64,
) !native.json.Value {
    var params = try native.json.copy(frame, status_params);
    try native.json.put(
        frame,
        &params,
        "client_operation_id",
        native.json.string("recover-original"),
    );
    try native.json.put(
        frame,
        &params,
        "expected_revision",
        native.json.string(try std.fmt.allocPrint(frame, "{d}", .{revision})),
    );
    try native.json.put(
        frame,
        &params,
        "occurrence_id",
        availability.object.get("occurrence_id").?,
    );
    try native.json.put(frame, &params, "attempt_id", availability.object.get("attempt_id").?);
    try native.json.put(
        frame,
        &params,
        "recovery",
        (try native.json.parse(frame, "{\"mechanism\":\"rederive\"}", .{})).value,
    );

    return params;
}

fn checkReconciledOutcome(comptime recovery_probe: RecoveryProbe, context: anytype) !void {
    const fixture = context.fixture;
    const frame = context.frame;
    const task = context.task;
    try openRecoveryFixture(fixture);
    if (recovery_probe == .provider) {
        try std.testing.expect(context.recorded.outcome == .unresolved);
        try std.testing.expectError(
            error.UnsettledOccurrence,
            fixture.service.resumeTask(
                frame,
                "unresolved-cannot-resume",
                task,
                context.admitted.receipt.revision,
            ),
        );
    } else {
        try settleRecoveredCapture(recovery_probe, context);
        return;
    }
    try checkProviderReopen(recovery_probe, context);
}

fn imageAssets(permanent: std.mem.Allocator, image_identity: [32]u8) !native.discovery.Assets {
    const image = @embedFile("adaptive_image");
    const metadata = @embedFile("adaptive_application");
    const manifest = try @import("native_test_support.zig").ownerManifest(
        permanent,
        image,
        image_identity,
        metadata,
    );
    return .{ .image = image, .application = metadata, .manifest = manifest };
}

fn submitWorkspaceRecovery(
    service: *native.tasks.Service(t),
    permanent: std.mem.Allocator,
    comptime reframing: bool,
) ![16]u8 {
    return (try service.submit(
        permanent,
        "workspace-recovery",
        .{
            .task = .{
                .bytes = if (reframing) reframing_task else retained_program_task,
            },
        },
    )).receipt.task;
}
