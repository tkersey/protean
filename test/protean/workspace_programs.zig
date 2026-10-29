//! Independent execution witnesses for the source-record transport. Algorithms
//! are authored records; no build-time result or native callback is supplied.
const support = @import("workspace_test_support.zig");
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;

const workspaceRef = support.workspaceRef;

const gcd = @import("workspace_sources.zig").gcd;
const listLength = @import("workspace_sources.zig").listLength;
const alternatives = @import("workspace_sources.zig").alternatives;

const RawPair = struct { value: Id, schema: Id, generator: Id };

fn rawPair(b: *source.Builder, captured: bool, values: [2]u64, effect: ?Id) !RawPair {
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const effects: []const Id = if (effect) |id| try b.allocator().dupe(Id, &.{id}) else &.{};
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = pair,
        .effects = effects,
        .capture_bound = if (captured) &.{word} else &.{},
    } } });
    const generator = try b.declare(&.{ word, word }, computation, &.{}, &.{});
    const target = try b.declare(&.{}, pair, effects, &.{});
    const first = if (captured) try b.reference(
        b.parameter(generator, 0),
    ) else try b.constant(u64, values[0]);
    const second = if (captured) try b.reference(
        b.parameter(generator, 1),
    ) else try b.constant(u64, values[1]);
    var body = try b.pure(try b.primitive(pair, .product, &.{ first, second }, 0));
    if (effect) |id| body = try b.bind(try b.variable(
        try b.scalar(void),
    ), try b.term(.{ .perform = .{
        .effect = id,
        .payload = try b.constant(void, {}),
    } }), body);
    try b.define(target, body);
    try b.define(generator, try b.pure(try b.lambda(target, computation)));
    const operands: []const Id = if (captured) try b.allocator().dupe(Id, &.{
        try b.constant(u64, values[0]),
        try b.constant(u64, values[1]),
    }) else &.{};
    return .{
        .value = try b.primitive(computation, .computation, operands, 0),
        .schema = pair,
        .generator = generator,
    };
}

test "BUILD-S01 unused semantic bridge declarations grant no construction authority" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const original = try gcd(&b);
    const unit = try b.scalar(void);
    _ = try b.effect(.{
        .identity = "kosmos.semantic-service/1",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const text = try native.source_records.encode(a, b.module(original.entry, original.failure));
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectError(
        error.ForbiddenEffect,
        native.program_construction.build(a, text, null, &diagnostic),
    );
    try std.testing.expectEqual(.authority, diagnostic.phase);
    const descriptor = try data.schema.encodeOwned(a, b.schemas.items, unit);
    defer a.free(descriptor);
    const contract: contracts.controller.Contract = .{
        .result = .{ .bytes = descriptor },
        .failure = .{ .bytes = descriptor },
        .imports = .{ .items = &.{} },
    };
    try std.testing.expectError(
        error.ForbiddenEffect,
        native.program_construction.buildController(a, text, contract, null, &diagnostic),
    );
    try std.testing.expectEqual(.authority, diagnostic.phase);
}

test "BUILD-S02 pure slices execute captured raw computation through native construction" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const pair = try rawPair(&b, true, .{ 11, 29 }, null);
    const bridge = try b.effect(.{
        .identity = "kosmos.semantic-service/1",
        .payload = unit,
        .result = unit,
        .external = true,
    });
    const generator = &b.functions.items[@intCast(pair.generator)];
    generator.effects = try b.allocator().dupe(Id, &.{bridge});
    generator.body = try b.bind(try b.variable(unit), try b.term(.{ .perform = .{
        .effect = bridge,
        .payload = try b.constant(void, {}),
    } }), generator.body.?);
    const entry = try b.declare(&.{unit}, pair.schema, &.{}, &.{});
    try b.define(
        entry,
        try b.term(.{ .apply = .{ .computation = pair.value, .arguments = &.{} } }),
    );
    var selected = try source.slice.extract(a, b.module(entry, unit), .{
        .entry = entry,
        .require_pure = true,
    });
    defer selected.deinit();
    try std.testing.expectEqual(@as(?Id, null), selected.maps.functions[@intCast(pair.generator)]);
    try std.testing.expectEqual(@as(usize, 0), selected.module().effects.len);
    const text = try native.source_records.encode(a, selected.module());
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    var built = try native.program_construction.build(a, text, null, &diagnostic);
    defer built.deinit();
    try std.testing.expectEqual(.complete, diagnostic.phase);
    var prepared = try kosmos.Prepared.init(a, built.image);
    defer prepared.deinit();
    const input = try contracts.encodeOwned(void, a, {});
    defer a.free(input);
    var session = try kosmos.Session.start(a, &prepared, input);
    defer session.deinit();
    while (true) switch (try session.run(8)) { // tiger: event-loop
        .progressed => {},
        .yielded => try session.resumeYield(),
        .completed => |value| {
            var result = try contracts.decodeOwned(
                struct { u64, u64 },
                a,
                try session.bytes(&value),
            );
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, 11), result.value[0]);
            try std.testing.expectEqual(@as(u64, 29), result.value[1]);
            break;
        },
        else => return error.UnexpectedOutcome,
    };
}

test "BUILD-S03 exposures preserve raw constructor captures and reject wrapper repair" {
    const a = std.testing.allocator;
    for (0..3) |variant| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const effect = try b.effect(.{
            .identity = "example/raw-pair",
            .payload = unit,
            .result = unit,
            .external = false,
        });
        const pair = try rawPair(&b, variant != 0, .{ 11, 29 }, if (variant == 2) effect else null);
        const entry = try b.declare(&.{unit}, pair.schema, &.{effect}, &.{});
        const apply = try b.term(.{ .apply = .{ .computation = pair.value, .arguments = &.{} } });
        try b.define(entry, try b.bind(try b.variable(unit), try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.constant(void, {}),
        } }), apply));
        const module = b.module(entry, unit);
        const text = try native.source_records.encode(a, module);
        defer a.free(text);
        const exposures = [_]contracts.workspace.Exposure{.{
            .effect = effect,
            .class = .observation,
        }};
        var diagnostic: native.program_construction.Diagnostic = .{};
        if (variant == 2) {
            try std.testing.expectError(
                error.TypeMismatch,
                native.program_construction.buildExposed(a, text, &exposures, null, &diagnostic),
            );
            continue;
        }
        var built = try native.program_construction.buildExposed(
            a,
            text,
            &exposures,
            null,
            &diagnostic,
        );
        defer built.deinit();
        try expectExposedRawPair(a, built.image);
        var generated = try native.program_construction.driver.generate(a, module, &exposures);
        defer generated.deinit();
        var work: u64 = 1_000_000;
        const added = try source.constructor_bindings.admit(
            a,
            b.allocator(),
            generated.module,
            &work,
        );
        try std.testing.expect(added.len > 1);
        b.values.items[@intCast(pair.value)].expression.primitive.immediate = 1;
        const forged = try native.source_records.encode(a, module);
        defer a.free(forged);
        try std.testing.expectError(
            error.InvalidReference,
            native.program_construction.buildExposed(a, forged, &exposures, null, &diagnostic),
        );
    }
}

fn expectExposedRawPair(a: std.mem.Allocator, image: []const u8) !void {
    var suspended = try kosmos.invocation.invoke(
        a,
        .{ .image = image, .instance = .{ .initial_args = &.{} } },
    );
    defer suspended.deinit();
    try std.testing.expect(suspended.record == .requested);
    var request = try data.invocation.decode(
        data.invocation.Request,
        a,
        suspended.record.requested.request,
    );
    defer request.deinit();
    try std.testing.expectEqualStrings(
        "protean.workspace.control/1/0",
        request.value.binding.semantic_identity,
    );
    const reply = try data.invocation.encodeOwned(
        data.invocation.Result,
        a,
        .{ .request_identity = request.value.request_identity, .value = &.{} },
    );
    defer a.free(reply);
    var completed = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = suspended.record.requested.state.?,
    }, .control = .{ .reply = reply } });
    defer completed.deinit();
    try std.testing.expect(completed.record == .completed);
    var result = try contracts.decodeOwned(struct { u64, u64 }, a, completed.record.completed);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 11), result.value[0]);
    try std.testing.expectEqual(@as(u64, 29), result.value[1]);
}

fn rawController(b: *source.Builder, original: source.Module) !source.Module {
    const pair = try rawPair(b, true, .{ 41, 29 }, null);
    const result = try b.variable(pair.schema);
    const proposal = try b.primitive(try b.scalar(u64), .field, &.{try b.reference(result)}, 0);
    for (b.terms.items) |*term| {
        if (term.* != .perform or term.perform.effect != 0) continue;
        const request = b.values.items[@intCast(term.perform.payload)];
        term.perform.payload = try b.primitive(request.schema, .product, &.{
            proposal,
            request.expression.primitive.operands[1],
        }, 0);
    }
    const entry = &b.functions.items[@intCast(original.entry)];
    entry.body = try b.bind(result, try b.term(.{ .apply = .{
        .computation = pair.value,
        .arguments = &.{},
    } }), entry.body.?);
    return b.module(original.entry, original.failure);
}

test "BUILD-C02 controller construction binds exact imports and publishes inert boot before carry" {
    const a = std.testing.allocator;
    const construction = native.program_construction;
    const controller = construction.controller;
    var schema_builder = source.Builder.init(a);
    defer schema_builder.deinit();
    const number = try schema_builder.scalar(u64);
    const unit = try schema_builder.scalar(void);
    const number_bytes = try data.schema.encodeOwned(a, schema_builder.schemas.items, number);
    defer a.free(number_bytes);
    const unit_bytes = try data.schema.encodeOwned(a, schema_builder.schemas.items, unit);
    defer a.free(unit_bytes);
    const controller_reply = try controller.replySchema(a, number_bytes);
    defer a.free(controller_reply);
    const contract: controller.Contract = .{
        .result = .{ .bytes = number_bytes },
        .failure = .{ .bytes = unit_bytes },
        .imports = .{ .items = &.{
            .{
                .import = .deliberate,
                .payload = .{ .bytes = number_bytes },
                .result = .{ .bytes = controller_reply },
                .native_result = .{ .bytes = number_bytes },
            },
            .{
                .import = .snapshot,
                .payload = .{ .bytes = number_bytes },
                .result = .{ .bytes = unit_bytes },
            },
        } },
    };
    try controllerConstructionOwner(a, contract, number_bytes, unit_bytes);
}

/// Reject allocation after an actual store commit, without depending on an
/// allocation ordinal or adding a fault hook to the production owner.
const AfterCommitAllocator = support.AfterCommitAllocator;

/// Keep allocations in an outer arena, but destroy freed contents so an arena
/// cannot accidentally hide a projection borrowing a decoded record's storage.
const PoisonFreedAllocator = support.PoisonFreedAllocator;

test "BUILD-07 source allocation faults release owners and cancellation admits nothing" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(a, try gcd(&builder));
    defer a.free(text);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, document: []const u8) !void {
            var diagnostic: native.program_construction.Diagnostic = .{};
            var built = try native.program_construction.build(
                allocator,
                document,
                null,
                &diagnostic,
            );
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
    try std.testing.expectError(
        error.Canceled,
        native.program_construction.build(a, text, &canceled, &diagnostic),
    );
}

test "WORK-06 WORK-07 generated drivers isolate aliases after one shared prefix" {
    for (0..5) |variant| try alternativeDriverVariant(std.testing.allocator, variant);
}

test "WORK-08 an exclusive resource cannot be captured by a generated alternative port" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(
        a,
        try @import("workspace_sources.zig").exclusiveAlternative(&builder),
    );
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidOwnership,
        native.program_construction.buildExposed(
            a,
            text,
            &.{.{ .effect = 0, .class = .alternative }},
            null,
            &diagnostic,
        ),
    );
}

test "exposure carries capabilities through closed handler returns clauses and shallow successors" {
    const a = std.testing.allocator;
    for (0..6) |variant| {
        var builder = source.Builder.init(a);
        defer builder.deinit();
        const shape = try handlerExposureShape(&builder, variant);
        const generated = try handlerExposureModule(&builder, shape);
        var built = try buildHandlerExposure(a, &builder, shape, generated);
        defer built.deinit();
        try runHandlerExposure(a, built.image, shape);
        try rejectUnauthorizedHandlerExposure(a, &builder, shape, generated);
    }
}

const compile = support.compile;

fn consumerProgram(b: *source.Builder) !source.Module {
    const original = try source.examples.consumerComposition(b);
    const function = b.functions.items[@intCast(original.entry)];
    const fields = try b.allocator().alloc(Id, function.parameters.len);
    for (function.parameters, fields) |parameter, *field|
        field.* = b.variables.items[@intCast(parameter)];
    const input = try b.schema(.{ .product = fields });
    const entry = try b.declare(&.{input}, function.result, &.{}, &.{});
    const value = try b.reference(b.parameter(entry, 0));
    const arguments = try b.allocator().alloc(Id, fields.len);
    for (fields, arguments, 0..) |schema, *argument, index|
        argument.* = try b.primitive(schema, .field, &.{value}, index);
    try b.define(entry, try b.term(.{ .call = .{
        .function = original.entry,
        .arguments = arguments,
    } }));
    return b.module(entry, original.failure);
}

fn consumerSite(a: std.mem.Allocator, module: source.Module) !source.consumer.Site {
    for (module.functions, 0..) |function, id| {
        const body = function.body orelse continue;
        if (module.terms[@intCast(body)] != .bind) continue;
        const site: source.consumer.Site = .{ .function = id, .binding = body };
        var inspection = try source.consumer.inspect(a, module, site, .{});
        defer inspection.deinit();
        if (inspection.outcome == .boundary and inspection.outcome.boundary.blocker == null)
            return site;
    }
    return error.MissingConsumerBoundary;
}

fn generatedConsumer(
    a: std.mem.Allocator,
    module: source.Module,
    site: source.consumer.Site,
) !contracts.Decoded(kosmos.RuntimeCompiler.RecordProposal) {
    var b = source.Builder.init(a);
    defer b.deinit();
    var built = try compile(a, &b, try kosmos.RuntimeTransformation.consumer(&b));
    defer built.deinit();
    var prepared = try kosmos.Prepared.init(a, built.image);
    defer prepared.deinit();
    const input = try contracts.encodeOwned(kosmos.RuntimeTransformation.ConsumerInput, a, .{
        .module = module,
        .site = site,
    });
    defer a.free(input);
    var session = try kosmos.Session.start(a, &prepared, input);
    defer session.deinit();
    for (0..64) |_| switch (try session.run(1024)) {
        .progressed => {},
        .completed => |value| return contracts.decodeOwned(
            kosmos.RuntimeCompiler.RecordProposal,
            a,
            try session.bytes(&value),
        ),
        else => return error.UnexpectedConsumerConstruction,
    };
    return error.ConsumerConstructionLimit;
}

fn consumerBuild(text: []const u8, derived: bool) contracts.workspace.Command {
    return .{ .program = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = text } },
        .source_kind = if (derived) .source_derivation else .source_records,
        .exposures = .{ .items = &.{} },
    } } };
}

fn inspectConsumerProgram(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: contracts.workspace.Ref,
    module: source.Module,
    operation: []const u8,
) !void {
    const site = try consumerSite(a, module);
    const inspected = try service.workspaceCommand(a, operation, task, .{ .program = .{
        .inspect = .{
            .target = .{ .consumer = .{
                .program = program,
                .function = site.function,
                .binding = site.binding,
            } },
            .page = .{},
        },
    } });
    try std.testing.expectEqual(.observed, inspected.disposition);
    var rendered = try native.json.parse(a, inspected.observation_json.bytes, .{});
    defer rendered.deinit();
    const Description = struct {
        version: u32,
        subject: [32]u8,
        outcome: @FieldType(source.consumer.Inspection, "outcome"),
    };
    var decoded = try native.source_records.decodeRecord(
        Description,
        a,
        rendered.value.object.get("text").?.string,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(try source.relation.identity(module), decoded.value.subject);
    const boundary = decoded.value.outcome.boundary;
    try std.testing.expect(boundary.blocker == null);
    try std.testing.expectEqual(boundary.producer_result, boundary.consumer_input);
    try std.testing.expect(boundary.producer_result != boundary.answer);
}

fn runConsumerProgram(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    program: contracts.workspace.Ref,
    label: []const u8,
) !void {
    for ([_]bool{ false, true }) |first| {
        const input = try contracts.encodeOwned(struct {
            u64,
            u64,
            u64,
            bool,
        }, a, .{ 7, 3, 5, first });
        defer a.free(input);
        const operation = try std.fmt.allocPrint(a, "{s}-{any}", .{ label, first });
        defer a.free(operation);
        const started = try service.workspaceStart(a, operation, task, try nativeIdentity(
            program,
        ), input, .{});
        for (0..32) |turn| {
            var work = try service.workspaceWork(a, task, started.receipt.workspace.?);
            defer work.deinit();
            if (work.value.terminal()) {
                try std.testing.expectEqual(.completed, work.value.outcome_kind);
                const result = try service.namespace.store.object(a, work.value.result.?, null);
                defer a.free(result);
                try std.testing.expectEqualSlices(u8, &.{@intFromBool(first)}, result);
                break;
            }
            const advance = try std.fmt.allocPrint(a, "{s}-{d}", .{ operation, turn });
            defer a.free(advance);
            _ = try service.workspaceControl(
                a,
                advance,
                task,
                work.value.id,
                work.value.execution_revision,
                work.value.control_revision,
                .advance,
            );
        } else return error.ConsumerExecutionLimit;
    }
}

fn rejectConsumerProgram(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    document: native.source_records.DerivationDocument,
) !void {
    var forged = document;
    forged.candidate = try source.own(source.Module, a, document.candidate);
    var changed = false;
    for (@constCast(forged.candidate.values)) |*value| {
        if (value.expression != .primitive or value.expression.primitive.opcode != .less) continue;
        value.expression.primitive.opcode = .equal;
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    const steps = try a.dupe(source.relation.RecordStep, document.steps);
    steps[steps.len - 1].successor = forged.candidate;
    forged.steps = steps;
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, forged.candidate, &work);
    const text = try native.source_records.encodeRecord(
        native.source_records.DerivationDocument,
        a,
        forged,
    );
    defer a.free(text);
    const rejected = try service.workspaceCommand(
        a,
        "consumer-hostile",
        task,
        consumerBuild(text, true),
    );
    try std.testing.expectEqual(.rejected, rejected.disposition);
    try std.testing.expect(rejected.program == null);
    var failure = try native.json.parse(a, rejected.observation_json.bytes, .{});
    defer failure.deinit();
    try std.testing.expectEqualStrings(
        "InvalidRelation",
        failure.value.object.get("error").?.string,
    );
    try std.testing.expectEqualStrings("relation", failure.value.object.get("phase").?.string);
}

fn retainConsumerSchemas(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const author = try horos.authoring.Context.init(&b);
    const input = try horos.authoring.interop.schemaId(
        author,
        try author.schema(native.source_records.DerivationDocument),
    );
    const failure = try horos.authoring.interop.schemaId(
        author,
        try author.schema(native.source_records.Document),
    );
    const entry = try b.declare(&.{input}, input, &.{}, &.{});
    try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
    const text = try native.source_records.encode(a, b.module(entry, failure));
    defer a.free(text);
    const built = try service.workspaceCommand(
        a,
        "consumer-schemas",
        task,
        consumerBuild(text, false),
    );
    try std.testing.expectEqual(.observed, built.disposition);
}

fn buildTypedConsumer(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    document: native.source_records.DerivationDocument,
    expected: contracts.workspace.Ref,
) !void {
    try retainConsumerSchemas(a, service, task);
    const retained = try reconstructionValue(
        @TypeOf(document),
        service,
        a,
        task,
        "consumer-typed-document",
        document,
    );
    var command = consumerBuild("", true);
    command.program.build.source = .{ .reference = retained };
    const built = try service.workspaceCommand(a, "consumer-typed-build", task, command);
    try std.testing.expectEqual(.observed, built.disposition);
    try std.testing.expectEqualDeep(expected, built.program.?);
    const ordinary = try reconstructionValue(
        native.source_records.Document,
        service,
        a,
        task,
        "consumer-ordinary-document",
        .{ .version = 1, .module = document.original },
    );
    const scalar = try reconstructionValue(bool, service, a, task, "consumer-scalar", true);
    for ([_]contracts.workspace.Ref{ ordinary, scalar }, 0..) |wrong, index| {
        command.program.build.source = .{ .reference = wrong };
        const operation = try std.fmt.allocPrint(a, "consumer-wrong-schema-{d}", .{index});
        defer a.free(operation);
        const rejected = try service.workspaceCommand(a, operation, task, command);
        try std.testing.expectEqual(.rejected, rejected.disposition);
        try std.testing.expect(rejected.program == null);
        var observation = try native.json.parse(a, rejected.observation_json.bytes, .{});
        defer observation.deinit();
        try std.testing.expectEqualStrings(
            "SchemaMismatch",
            observation.value.object.get("error").?.string,
        );
    }
}

const ConsumerFailureAllocator = struct {
    backing: std.mem.Allocator,
    diagnostic: ?*native.program_construction.Diagnostic = null,
    phase: @FieldType(native.program_construction.Diagnostic, "phase") = .transport,
    cancellation: ?*std.atomic.Value(bool) = null,
    namespace: ?*native.Namespace = null,
    triggered: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const selected = if (self.namespace) |namespace|
            namespace.store.transaction
        else
            self.diagnostic.?.phase == self.phase;
        if (selected) {
            self.triggered = true;
            if (self.cancellation) |flag| flag.store(true, .release) else return null;
        }
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn failConsumerConstruction(text: []const u8, expected_image: []const u8) !void {
    const construction = native.program_construction;
    const a = std.testing.allocator;
    var diagnostic: construction.Diagnostic = .{};
    for ([_]@FieldType(construction.Diagnostic, "phase"){
        .transport, .relation, .interface,
    }) |phase| for ([_]bool{ false, true }) |cancel| {
        var counted = std.testing.FailingAllocator.init(a, .{});
        var cancellation = std.atomic.Value(bool).init(false);
        var fault: ConsumerFailureAllocator = .{
            .backing = counted.allocator(),
            .diagnostic = &diagnostic,
            .phase = phase,
            .cancellation = if (cancel) &cancellation else null,
        };
        const expected = if (cancel) error.Canceled else error.OutOfMemory;
        try std.testing.expectError(expected, construction.buildDerived(
            fault.allocator(),
            text,
            &.{},
            &cancellation,
            &diagnostic,
        ));
        try std.testing.expect(fault.triggered);
        try std.testing.expectEqual(expected, diagnostic.code.?);
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    };
    var recovered = try construction.buildDerived(a, text, &.{}, null, &diagnostic);
    defer recovered.deinit();
    try std.testing.expectEqual(.complete, diagnostic.phase);
    try std.testing.expect(diagnostic.code == null);
    try std.testing.expectEqualSlices(u8, expected_image, recovered.image);
}

fn consumerPublicationCounts(service: anytype) ![3]i64 {
    var query = try service.namespace.store.database.prepare(
        "SELECT (SELECT count(*) FROM objects)," ++
            "(SELECT count(*) FROM records),(SELECT count(*) FROM operations)",
        &.{},
    );
    defer query.deinit();
    try std.testing.expectEqual(.row, try query.step());
    return .{ try query.integer(0), try query.integer(1), try query.integer(2) };
}

fn failConsumerPublication(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    command: contracts.workspace.Command,
) !void {
    const head = service.namespace.store.head;
    const counts = try consumerPublicationCounts(service);
    var parent = try service.task(a, task);
    defer parent.deinit();
    var fault: ConsumerFailureAllocator = .{ .backing = a, .namespace = service.namespace };
    try std.testing.expectError(error.OutOfMemory, service.workspaceCommand(
        fault.allocator(),
        "consumer-derived",
        task,
        command,
    ));
    try std.testing.expect(fault.triggered);
    try std.testing.expect(!service.namespace.store.transaction);
    try std.testing.expect(!service.namespace.store.fenced);
    try std.testing.expectEqualDeep(head, service.namespace.store.head);
    try std.testing.expectEqualDeep(counts, try consumerPublicationCounts(service));
    var preserved = try service.task(a, task);
    defer preserved.deinit();
    try std.testing.expectEqualDeep(parent.value, preserved.value);
}

fn replayConsumerPublication(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
    command: contracts.workspace.Command,
    expected: contracts.workspace.Ref,
) !void {
    var guarded: AfterCommitAllocator = .{
        .backing = a,
        .namespace = service.namespace,
        .generation = service.namespace.store.head.generation,
    };
    try std.testing.expectError(error.OutOfMemory, service.workspaceCommand(
        guarded.allocator(),
        "consumer-publication",
        task,
        command,
    ));
    try std.testing.expect(guarded.rejected != 0);
    try std.testing.expectEqual(guarded.generation + 1, service.namespace.store.head.generation);
    try std.testing.expect(!service.namespace.store.fenced);
    const head = service.namespace.store.head;
    const counts = try consumerPublicationCounts(service);
    const replay = try service.workspaceCommand(a, "consumer-publication", task, command);
    try std.testing.expectEqual(.observed, replay.disposition);
    try std.testing.expectEqualDeep(expected, replay.program.?);
    var observation = try native.json.parse(a, replay.observation_json.bytes, .{});
    defer observation.deinit();
    try std.testing.expect(observation.value.object.get("replayed").?.bool);
    try std.testing.expectEqualDeep(head, service.namespace.store.head);
    try std.testing.expectEqualDeep(counts, try consumerPublicationCounts(service));
}

fn exerciseConsumerPrograms(
    a: std.mem.Allocator,
    service: anytype,
    task: native.testing.state.TaskId,
) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try consumerProgram(&b);
    const source_text = try native.source_records.encode(a, module);
    defer a.free(source_text);
    const original = try service.workspaceCommand(
        a,
        "consumer-original",
        task,
        consumerBuild(source_text, false),
    );
    try std.testing.expectEqual(.observed, original.disposition);
    try inspectConsumerProgram(a, service, task, original.program.?, module, "consumer-inspect");
    var generated = try generatedConsumer(a, module, try consumerSite(a, module));
    defer generated.deinit();
    try std.testing.expectEqual(@as(usize, 2), generated.value.steps.len);
    const document: native.source_records.DerivationDocument = .{
        .version = 1,
        .predecessor = try source.relation.identity(module),
        .original = module,
        .candidate = generated.value.selected,
        .steps = generated.value.steps,
    };
    const text = try native.source_records.encodeRecord(@TypeOf(document), a, document);
    defer a.free(text);
    const command = consumerBuild(text, true);
    try failConsumerPublication(a, service, task, command);
    const built = try service.workspaceCommand(a, "consumer-derived", task, command);
    try std.testing.expectEqual(.observed, built.disposition);
    try std.testing.expect(!std.meta.eql(original.program, built.program));
    try inspectConsumerProgram(
        a,
        service,
        task,
        built.program.?,
        document.candidate,
        "consumer-derived-inspect",
    );
    var prior = try service.workspaceProgram(a, task, try nativeIdentity(original.program.?));
    defer prior.deinit();
    var accepted = try service.workspaceProgram(a, task, try nativeIdentity(built.program.?));
    defer accepted.deinit();
    try std.testing.expectEqual(.source_derivation, accepted.value.description.source_kind);
    const image = try service.namespace.store.object(a, accepted.value.description.image, null);
    defer a.free(image);
    try failConsumerConstruction(text, image);
    try replayConsumerPublication(a, service, task, command, built.program.?);
    try buildTypedConsumer(a, service, task, document, built.program.?);
    try rejectConsumerProgram(a, service, task, document);
    var unchanged = try service.workspaceProgram(a, task, try nativeIdentity(original.program.?));
    defer unchanged.deinit();
    var preserved = try service.workspaceProgram(a, task, try nativeIdentity(built.program.?));
    defer preserved.deinit();
    try std.testing.expectEqualDeep(prior.value, unchanged.value);
    try std.testing.expectEqualDeep(accepted.value, preserved.value);
    const replay = try service.workspaceCommand(a, "consumer-derived", task, command);
    try std.testing.expectEqualDeep(built.program, replay.program);
    var observation = try native.json.parse(a, replay.observation_json.bytes, .{});
    defer observation.deinit();
    try std.testing.expect(observation.value.object.get("replayed").?.bool);
    try runConsumerProgram(a, service, task, original.program.?, "consumer-before");
    try runConsumerProgram(a, service, task, built.program.?, "consumer-after");
    try service.validateWorkspace(a, task);
}

test "BUILD-CONSUMER generated finite composition publishes a new program and rejects false proof" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "consumer-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = "consumer-unit",
        .manifest = "{}",
    };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(42),
        .bytes = "consumer-test",
        .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" },
    };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const task = (try service.submit(scratch, "consumer-parent", .{ 25, 5 })).receipt.task;
    var before = try service.task(a, task);
    defer before.deinit();
    try exerciseConsumerPrograms(scratch, &service, task);
    var after = try service.task(a, task);
    defer after.deinit();
    try std.testing.expectEqualDeep(before.value.checkpoint, after.value.checkpoint);
    try std.testing.expectEqual(before.value.execution_revision, after.value.execution_revision);
}

fn execute(
    a: std.mem.Allocator,
    prepared: *kosmos.Prepared,
    input: []const u8,
    expected: u64,
) !u64 {
    var session = try kosmos.Session.start(a, prepared, input);
    defer session.deinit();
    var quanta: u64 = 0;
    while (true) { // tiger: event-loop
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
    for ([_]usize{ 0, 3, 32 }) |length| {
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

const OwnerTypes = support.OwnerTypes;

const expectContextOutputBound = support.expectContextOutputBound;

fn expectWorkInputHistoryBound(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    work_id: [32]u8,
    inputs: []const native.testing.state.Reference,
) !void {
    const store = &service.namespace.store;
    var work = try service.workspaceWork(a, task, work_id);
    defer work.deinit();
    try std.testing.expect(work.value.result == null);
    const extra = inputs.len - work.value.inputs.items.len;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var compiler_facts = try service.prepareWorkspaceValidation(task);
    defer compiler_facts.deinit();
    try store.begin();
    defer store.rollback();
    work.value.inputs.items = inputs;
    try store.putRecord(native.workspace.Work, "workspace_work", work_id, task, work.value);
    try rewriteWorkInputs(store, a, task, work_id, inputs, extra);
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &compiler_facts),
    );
}

fn expectWorkInputProvenanceBound(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    work_id: [32]u8,
) !void {
    const store = &service.namespace.store;
    var work = try service.workspaceWork(a, task, work_id);
    defer work.deinit();
    const artifact_bytes = try judgmentInputBytes(service, a, task, work.value);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var compiler_facts = try service.prepareWorkspaceValidation(task);
    defer compiler_facts.deinit();
    try service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &compiler_facts);
    try store.begin();
    defer store.rollback();
    const replacement = try store.putObject(artifact_bytes);
    work.value.input_value = replacement;
    try store.putRecord(native.workspace.Work, "workspace_work", work_id, task, work.value);
    try rewriteInputProvenanceEvents(store, a, task, work_id, replacement);
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &compiler_facts),
    );
}

fn expectWorkCancellationReasonBound(
    service: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
) !void {
    try std.testing.expect(
        child.cancellation_applied and !child.terminal() and child.current_occurrence == null,
    );
    const store = &service.namespace.store;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, child.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var graph = try data.state_image.decodeGraph(a, try store.object(a, child.checkpoint, null));
    defer graph.deinit();
    const nodes = try a.dupe(data.process_state.Node, graph.state.nodes);
    defer a.free(nodes);
    graph.state.nodes = nodes;
    var cursor = graph.state.roots.exit orelse return error.MissingCancellation;
    while (nodes[@intCast(cursor.id)].record.exit.outer) |outer| cursor = outer;
    nodes[@intCast(cursor.id)].record.exit.cancellation = .{ .text = "different kernel reason" };
    var compiler_facts = try service.prepareWorkspaceValidation(child.task);
    defer compiler_facts.deinit();
    try store.begin();
    defer store.rollback();
    var forged = child;
    forged.checkpoint = try store.putObject(try data.state_image.emit(a, graph.state));
    try store.putRecord(native.workspace.Work, "workspace_work", child.id, child.task, forged);
    try rewriteCancellationCheckpoint(store, a, child, forged.checkpoint);
    // Native reason, command, event control facts and operation identity stay
    // unchanged; only the kernel checkpoint and its content references differ.
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(
            a,
            child.task,
            index.records.items,
            &compiler_facts,
        ),
    );
}

fn expectInteractionReplyBound(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    operation_id: []const u8,
) !void {
    const store = &service.namespace.store;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var compiler_facts = try service.prepareWorkspaceValidation(task);
    defer compiler_facts.deinit();
    try store.begin();
    defer store.rollback();
    var operations = try store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p" ++
            ".receipt WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer operations.deinit();
    var changed = false;
    while (try operations.step() == .row) {
        const receipt = (try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try operations.bytes(1),
        )).value;
        if (!std.mem.eql(u8, receipt.client_operation_id.bytes, operation_id)) continue;
        try rewriteInteractionReceipt(store, a, task, receipt, try operations.bytes(0));
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    // Both 10 and 20 are valid inputs of the same work. Neither membership nor
    // a coherent request digest ties this command to its actual acquired reply.
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &compiler_facts),
    );
}

fn expectProgramProgressIsDerived(
    service: anytype,
    a: std.mem.Allocator,
    task_id: native.testing.state.TaskId,
) !void {
    const store = &service.namespace.store;
    var query = try store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
            "RE e.task=? ORDER BY e.seq",
        &.{.{ .blob = &task_id }},
    );
    defer query.deinit();
    var first: ?contracts.Decoded(native.testing.state.Event) = null;
    defer if (first) |*event_value| event_value.deinit();
    var bare_progress = false;
    while (try query.step() == .row) {
        var event_value = try contracts.decodeOwned(
            native.testing.state.Event,
            a,
            try query.bytes(0),
        );
        defer event_value.deinit();
        if (first == null) first = try contracts.decodeOwned(
            native.testing.state.Event,
            a,
            try query.bytes(0),
        );
        if (event_value.value.kind == .workspace_progress and
            event_value.value.workspace_publications.items.len == 0) bare_progress = true;
    }
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task_id, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var compiler_facts = try service.prepareWorkspaceValidation(task_id);
    defer compiler_facts.deinit();
    try service.validateWorkspaceRecordsPrepared(a, task_id, index.records.items, &compiler_facts);
    // Neither successful compilation nor delegation authorizes an independent
    // program claim in the journal, even when its object digest is recomputed.
    try store.begin();
    defer store.rollback();
    var forged = first.?.value;
    forged.kind = .workspace_progress;
    forged.workspace_publications = .{ .items = &.{} };
    forged.data.bytes = "{\"workspace_id\":\"000000000000000000000000000000000000000000000" ++
        "0000000000000000000\"}";
    const reference = try store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, a, forged),
    );
    try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{
        .blob = &reference.digest,
    }, .{ .blob = &task_id }, .{ .integer = @intCast(forged.seq) } });
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task_id, index.records.items, &compiler_facts),
    );
    try std.testing.expect(!bare_progress);
}
test "WORK-01 retained work keeps controller state distinct and replays exact admissions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "workspace-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = "workspace-unit",
        .manifest = "{}",
    };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "workspace-test", .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    try retainedWorkArena(.{
        .a = a,
        .io = io,
        .application = &application,
        .assets = assets,
        .handlers = &handlers,
        .profile = profile,
        .namespace = &namespace,
        .service = &service,
    });
}

fn retainedWorkArena(fixture: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(fixture.a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try retainedWorkBuildAdmissions(fixture, scratch);
}

fn retainedWorkBuildAdmissions(fixture: anytype, scratch: std.mem.Allocator) !void {
    const parent = try fixture.service.*.submit(scratch, "parent", .{ 25, 5 });
    var initial = try fixture.service.*.task(fixture.a, parent.receipt.task);
    defer initial.deinit();
    var builder = source.Builder.init(fixture.a);
    defer builder.deinit();
    const document = try native.source_records.encode(fixture.a, try listLength(&builder));
    defer fixture.a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try fixture.service.*.workspaceBuild(
        scratch,
        "build",
        parent.receipt.task,
        document,
        &diagnostic,
    );
    const repeated = try fixture.service.*.workspaceBuild(
        scratch,
        "build",
        parent.receipt.task,
        document,
        &diagnostic,
    );
    try std.testing.expect(repeated.replayed);
    try std.testing.expectEqualDeep(program.receipt.workspace, repeated.receipt.workspace);
    var source_program = try fixture.service.*.workspaceProgram(
        scratch,
        parent.receipt.task,
        program.receipt.workspace.?,
    );
    defer source_program.deinit();
    const rebuilt_source = try fixture.service.*.workspaceCommand(
        scratch,
        "build-source-reference",
        parent.receipt.task,
        .{ .program = .{ .build = .{
            .source = .{
                .reference = try workspaceRef(
                    scratch,
                    .source,
                    source_program.value.description.source.digest,
                ),
            },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{} },
        } } },
    );
    try std.testing.expectEqual(.observed, rebuilt_source.disposition);
    try std.testing.expectEqualDeep(
        program.receipt.workspace.?,
        try nativeIdentity(rebuilt_source.program.?),
    );
    try retainedWorkStartReplay(fixture, scratch, .{
        .parent = parent,
        .initial = &initial,
        .document = document,
        .diagnostic = &diagnostic,
        .program = program,
    });
}

fn retainedWorkStartReplay(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const input = try fixture.a.alloc(u8, 32 * 9 + 1);
    defer fixture.a.free(input);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..32) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const started = try fixture.service.*.workspaceStart(
        scratch,
        "start",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        input,
        .{},
    );
    const duplicate = try fixture.service.*.workspaceStart(
        scratch,
        "start",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        input,
        .{},
    );
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualDeep(started.receipt.workspace, duplicate.receipt.workspace);
    const id = started.receipt.workspace.?;
    var work = try fixture.service.*.workspaceWork(fixture.a, subject.parent.receipt.task, id);
    defer work.deinit();
    try std.testing.expect(!work.value.terminal());
    try std.testing.expectEqual(.parked, work.value.schedule);
    try retainedWorkAdvanceAdmission(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = input,
        .id = id,
        .work = &work,
    });
}

fn retainedWorkAdvanceAdmission(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "advance",
        subject.parent.receipt.task,
        subject.id,
        subject.work.*.value.execution_revision,
        subject.work.*.value.control_revision,
        .advance,
    );
    const replayed = try fixture.service.*.workspaceControl(
        scratch,
        "advance",
        subject.parent.receipt.task,
        subject.id,
        subject.work.*.value.execution_revision,
        subject.work.*.value.control_revision,
        .advance,
    );
    try std.testing.expect(replayed.replayed);
    try std.testing.expectError(
        error.StaleRevision,
        fixture.service.*.workspaceControl(
            scratch,
            "stale",
            subject.parent.receipt.task,
            subject.id,
            subject.work.*.value.execution_revision,
            subject.work.*.value.control_revision,
            .advance,
        ),
    );
    var after = try fixture.service.*.task(fixture.a, subject.parent.receipt.task);
    defer after.deinit();
    try std.testing.expectEqualDeep(subject.initial.*.value.checkpoint, after.value.checkpoint);
    try std.testing.expectEqualDeep(
        subject.initial.*.value.current_occurrence,
        after.value.current_occurrence,
    );
    try std.testing.expectEqual(
        subject.initial.*.value.execution_revision,
        after.value.execution_revision,
    );
    try std.testing.expect(after.value.revision > subject.initial.*.value.revision);
    try expectWorkInputProvenanceBound(
        &fixture.service.*,
        scratch,
        subject.parent.receipt.task,
        subject.id,
    );
    try retainedWorkCancellation(fixture, scratch, subject);
}

fn retainedWorkCancellation(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const abandoned = try fixture.service.*.workspaceStart(
        scratch,
        "abandon-start",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        subject.input,
        .{},
    );
    var abandoned_work = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        abandoned.receipt.workspace.?,
    );
    defer abandoned_work.deinit();
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "cancel",
        subject.parent.receipt.task,
        abandoned_work.value.id,
        abandoned_work.value.execution_revision,
        abandoned_work.value.control_revision,
        .{ .cancel = .{ .bytes = "investigate another input" } },
    );
    var cancelled = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        abandoned_work.value.id,
    );
    defer cancelled.deinit();
    try std.testing.expectEqual(.cancelled, cancelled.value.outcome_kind);
    try std.testing.expect(cancelled.value.cancellation_applied);
    try std.testing.expect(cancelled.value.result == null);
    try retainedWorkForeignCancellation(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .abandoned_work = &abandoned_work,
    });
}

fn retainedWorkForeignCancellation(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const foreign_cancel = try fixture.service.*.submit(
        scratch,
        "foreign-cancel-parent",
        .{ 25, 5 },
    );
    const foreign_program = try fixture.service.*.workspaceBuild(
        scratch,
        "foreign-cancel-build",
        foreign_cancel.receipt.task,
        subject.document,
        &subject.diagnostic.*,
    );
    const foreign_child = try fixture.service.*.workspaceStart(
        scratch,
        "foreign-cancel-child",
        foreign_cancel.receipt.task,
        foreign_program.receipt.workspace.?,
        subject.input,
        .{},
    );
    try fixture.service.*.park(scratch);
    try fixture.service.*.close(scratch);
    var observation_profile = fixture.profile;
    observation_profile.bytes = "different-launch-configuration";
    fixture.service.* = try native.tasks.Service(OwnerTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        observation_profile,
    );
    try retainedWorkProfileObservation(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .abandoned_work = subject.abandoned_work,
        .foreign_cancel = foreign_cancel,
        .foreign_child = foreign_child,
    });
}

fn retainedWorkProfileObservation(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var reader: native.client.Client(OwnerTypes) = .{ .service = &fixture.service.* };
    var status_params = native.json.object();
    try native.json.put(
        scratch,
        &status_params,
        "task_id",
        native.json.string(
            try std.fmt.allocPrint(scratch, "{s}", .{
                std.fmt.bytesToHex(subject.parent.receipt.task, .lower),
            }),
        ),
    );
    const reopened_status = try reader.call(scratch, .@"task.status", status_params);
    try std.testing.expect(!reopened_status.object.get("associated_work_disposed").?.bool);
    _ = try reader.call(scratch, .@"task.result", status_params);
    try std.testing.expectError(
        error.IncompatibleProfile,
        fixture.service.*.workspaceWork(scratch, subject.parent.receipt.task, subject.id),
    );
    _ = try fixture.service.*.requestCancel(
        scratch,
        "foreign-cancel",
        subject.foreign_cancel.receipt.task,
        "retain intent without execution authority",
    );
    try std.testing.expectEqual(.idle, try fixture.service.*.pump(scratch));
    var blocked_cancel = try fixture.service.*.task(scratch, subject.foreign_cancel.receipt.task);
    defer blocked_cancel.deinit();
    try std.testing.expectEqual(
        .blocked,
        try fixture.service.*.status(scratch, blocked_cancel.value),
    );
    try std.testing.expectEqual(.incompatible_profile, blocked_cancel.value.blocker.?);
    try std.testing.expect(
        !try fixture.service.*.associatedWorkDisposed(scratch, subject.foreign_cancel.receipt.task),
    );
    try retainedWorkIndependentOwner(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .abandoned_work = subject.abandoned_work,
        .foreign_cancel = subject.foreign_cancel,
        .foreign_child = subject.foreign_child,
        .reader = &reader,
    });
}

fn retainedWorkIndependentOwner(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const independent = try fixture.service.*.submit(scratch, "compatible-independent", .{ 25, 5 });
    for (0..32) |_| {
        _ = try fixture.service.*.pump(scratch);
        var independent_state = try fixture.service.*.task(scratch, independent.receipt.task);
        defer independent_state.deinit();
        if (independent_state.value.terminal()) break;
    }
    var independent_result = try fixture.service.*.task(scratch, independent.receipt.task);
    defer independent_result.deinit();
    try std.testing.expectEqual(.completed, independent_result.value.outcome_kind);
    try fixture.service.*.close(scratch);
    fixture.service.* = try native.tasks.Service(OwnerTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile,
    );
    try retainedWorkRestoreCancellation(fixture, scratch, subject);
}

fn retainedWorkRestoreCancellation(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    _ = try fixture.service.*.requestCancel(
        scratch,
        "compatible-cancel",
        subject.foreign_cancel.receipt.task,
        "retain intent without execution authority",
    );
    for (0..32) |_| {
        _ = try fixture.service.*.pump(scratch);
        var current_cancel = try fixture.service.*.task(
            scratch,
            subject.foreign_cancel.receipt.task,
        );
        defer current_cancel.deinit();
        if (try fixture.service.*.taskCleanupComplete(scratch, current_cancel.value)) break;
    }
    var disposed_cancel = try fixture.service.*.task(scratch, subject.foreign_cancel.receipt.task);
    defer disposed_cancel.deinit();
    try std.testing.expect(
        try fixture.service.*.taskCleanupComplete(scratch, disposed_cancel.value),
    );
    try std.testing.expect(disposed_cancel.value.blocker == null);
    var disposed_child = try fixture.service.*.workspaceWork(
        scratch,
        subject.foreign_cancel.receipt.task,
        subject.foreign_child.receipt.workspace.?,
    );
    defer disposed_child.deinit();
    try std.testing.expectEqual(.cancelled, disposed_child.value.outcome_kind);
    try retainedWorkDelegateRecovery(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .abandoned_work = subject.abandoned_work,
        .reader = subject.reader,
    });
}

fn retainedWorkDelegateRecovery(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const recovered = try fixture.service.*.workspaceControl(
        scratch,
        "advance",
        subject.parent.receipt.task,
        subject.id,
        subject.work.*.value.execution_revision,
        subject.work.*.value.control_revision,
        .advance,
    );
    try std.testing.expect(recovered.replayed);
    var retained = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        subject.id,
    );
    defer retained.deinit();
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "delegate",
        subject.parent.receipt.task,
        subject.id,
        retained.value.execution_revision,
        retained.value.control_revision,
        .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } },
    );
    var turns: usize = 0;
    while (turns < 1000) : (turns += 1) {
        const step = try fixture.service.*.pump(scratch);
        try std.testing.expect(step != .work);
        var observed = try fixture.service.*.workspaceWork(
            fixture.a,
            subject.parent.receipt.task,
            subject.id,
        );
        defer observed.deinit();
        if (observed.value.terminal()) {
            try std.testing.expectEqual(.completed, observed.value.outcome_kind);
            const bytes = try fixture.namespace.*.store.object(
                fixture.a,
                observed.value.result.?,
                null,
            );
            defer fixture.a.free(bytes);
            var result = try contracts.decodeOwned(u64, fixture.a, bytes);
            defer result.deinit();
            try std.testing.expectEqual(32, result.value);
            break;
        }
    }
    try std.testing.expect(turns < 1000);
    try std.testing.expect(turns > 1);
    try retainedWorkDistinctResults(fixture, scratch, subject);
}

fn retainedWorkDistinctResults(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var final_parent = try fixture.service.*.task(fixture.a, subject.parent.receipt.task);
    defer final_parent.deinit();
    try std.testing.expectEqualDeep(
        subject.initial.*.value.checkpoint,
        final_parent.value.checkpoint,
    );
    try std.testing.expectEqual(
        subject.initial.*.value.execution_revision,
        final_parent.value.execution_revision,
    );
    try retainedWorkZeroResults(fixture, scratch, subject);
}
fn retainedWorkZeroResults(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const first_zero = try fixture.service.*.workspaceStart(
        scratch,
        "zero-one",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        &.{0},
        .{},
    );
    const second_zero = try fixture.service.*.workspaceStart(
        scratch,
        "zero-two",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        &.{0},
        .{},
    );
    var first = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        first_zero.receipt.workspace.?,
    );
    defer first.deinit();
    var second = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        second_zero.receipt.workspace.?,
    );
    defer second.deinit();
    try std.testing.expectEqualDeep(first.value.result.?, second.value.result.?);
    try std.testing.expect(!std.meta.eql(first.value.result_value.?, second.value.result_value.?));
    // WORK-11: independent subjects share neither execution nor the parent.
    // Collection preserves caller order, repetitions and explicit non-results.
    const pending_collection = try fixture.service.*.workspaceStart(
        scratch,
        "collection-pending",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        subject.input,
        .{},
    );
    try retainedWorkOrderedCollection(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .abandoned_work = subject.abandoned_work,
        .reader = subject.reader,
        .first = &first,
        .second = &second,
        .pending_collection = pending_collection,
    });
}

fn retainedWorkOrderedCollection(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const collection_ids = [_][32]u8{
        subject.second.*.value.id,
        subject.abandoned_work.*.value.id,
        @splat(0),
        subject.pending_collection.receipt.workspace.?,
        subject.first.*.value.id,
        subject.second.*.value.id,
    };
    var collection_refs: [collection_ids.len]contracts.workspace.Ref = undefined;
    for (collection_ids, &collection_refs) |collection_id, *ref| ref.* = try workspaceRef(
        scratch,
        .work,
        collection_id,
    );
    const collected = try fixture.service.*.workspaceCommand(
        scratch,
        "ordered-collection",
        subject.parent.receipt.task,
        .{ .work = .{ .collect = .{ .works = .{ .items = &collection_refs } } } },
    );
    try std.testing.expectEqual(.observed, collected.disposition);
    var collected_json = try native.json.parse(fixture.a, collected.observation_json.bytes, .{});
    defer collected_json.deinit();
    try std.testing.expectEqual(collection_ids.len, collected_json.value.array.items.len);
    const outcomes = [_][]const u8{
        "completed",
        "cancelled",
        "unavailable",
        "yielded",
        "completed",
        "completed",
    };
    for (collected_json.value.array.items, collection_refs, outcomes) |item, ref, expected| {
        try std.testing.expectEqualStrings(
            ref.id.bytes,
            item.object.get("work").?.object.get("id").?.string,
        );
        try std.testing.expectEqualStrings(expected, item.object.get("outcome").?.string);
    }
    // A controller can choose a collected value as report evidence without
    // inspecting retained work or creating a new judgment/provenance identity.
    try retainedWorkCollectedEvidence(fixture, scratch, .{
        .parent = subject.parent,
        .initial = subject.initial,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .reader = subject.reader,
        .first = subject.first,
        .collected_json = &collected_json,
    });
}

fn retainedWorkCollectedEvidence(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const collected_value = try native.values.fromJson(
        contracts.workspace.Ref,
        scratch,
        subject.collected_json.*.value.array.items[0].object.get("result").?,
    );
    const cited = try fixture.service.*.workspaceCommand(
        scratch,
        "cite-collected-result",
        subject.parent.receipt.task,
        .{ .context = .{ .materialize = .{ .input = .{ .value = .{
            .reference = collected_value,
        } }, .sources = .{ .items = &.{} } } } },
    );
    try std.testing.expectEqualDeep(collected_value, cited.evidence.?);
    const cited_json = (try native.json.parse(scratch, cited.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings(
        "computation",
        cited_json.object.get("derivation").?.object.get("kind").?.string,
    );
    const cited_provenance = try native.values.fromJson(
        contracts.workspace.Ref,
        scratch,
        cited_json.object.get("provenance").?,
    );
    const cited_expansion = try fixture.service.*.workspaceCommand(
        scratch,
        "expand-computation-provenance",
        subject.parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = cited_provenance, .page = .{} } } },
    );
    try std.testing.expectEqual(.observed, cited_expansion.disposition);
    const cited_page = (try native.json.parse(
        scratch,
        cited_expansion.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings(
        try native.json.canonical(scratch, cited_json.object.get("derivation").?),
        cited_page.object.get("text").?.string,
    );
    try std.testing.expect(cited_page.object.get("complete").?.bool);
    var collection_parent = try fixture.service.*.task(fixture.a, subject.parent.receipt.task);
    defer collection_parent.deinit();
    try std.testing.expectEqualDeep(
        subject.initial.*.value.checkpoint,
        collection_parent.value.checkpoint,
    );
    try std.testing.expectEqual(
        subject.initial.*.value.execution_revision,
        collection_parent.value.execution_revision,
    );
    // Context inspection serializes a page, not a JSON tree for all work.
    try retainedWorkScopePages(fixture, scratch, .{
        .parent = subject.parent,
        .document = subject.document,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .reader = subject.reader,
        .first = subject.first,
    });
}

fn retainedWorkScopePages(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    for (0..32) |i| _ = try fixture.service.*.workspaceStart(
        scratch,
        try std.fmt.allocPrint(scratch, "scope-work-{d}", .{i}),
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        &.{0},
        .{},
    );
    var expected_scope: native.json.Value = .{ .array = .init(scratch) };
    var scope_query = try fixture.namespace.*.store.database.prepare(
        "SELECT id FROM records WHERE task=? AND kind='workspace_work' ORD" ++
            "ER BY id",
        &.{.{ .blob = &subject.parent.receipt.task }},
    );
    while (try scope_query.step() == .row) {
        const scope_id = try scope_query.bytes(0);
        try expected_scope.array.append(
            try native.values.toJson(
                contracts.workspace.Ref,
                scratch,
                try workspaceRef(scratch, .work, scope_id[0..32].*),
            ),
        );
    }
    scope_query.deinit();
    const scope_text = try native.json.canonical(scratch, expected_scope);
    const scope_budget_bytes = try fixture.a.alloc(u8, 32 * 1024);
    defer fixture.a.free(scope_budget_bytes);
    for ([_]u64{ 0, 63, scope_text.len - 7, scope_text.len }) |offset| {
        var scope_budget = std.heap.FixedBufferAllocator.init(scope_budget_bytes);
        const page = try fixture.service.*.workspaceCommand(
            scope_budget.allocator(),
            "scope-page",
            subject.parent.receipt.task,
            .{ .context = .{ .inspect = .{ .page = .{ .offset = offset, .maximum = 64 } } } },
        );
        try std.testing.expectEqual(.observed, page.disposition);
        const rendered = (try native.json.parse(scratch, page.observation_json.bytes, .{})).value;
        try std.testing.expectEqualStrings(
            scope_text[@intCast(offset)..][0..@min(64, scope_text.len - offset)],
            rendered.object.get("text").?.string,
        );
        try std.testing.expectEqual(
            scope_text.len,
            try native.json.numberInteger(
                usize,
                rendered.object.get("total_bytes").?.number_string,
            ),
        );
    }
    // A scalar disposal observation need not retain all historical work while
    // scanning it. Exercise the actual client frame allocator at several sizes.
    try retainedWorkStatusHistory(fixture, scratch, subject);
}

fn retainedWorkStatusHistory(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const status_parent = try fixture.service.*.submit(
        scratch,
        "status-history-parent",
        .{ 25, 5 },
    );
    const status_program = try fixture.service.*.workspaceBuild(
        scratch,
        "status-history-build",
        status_parent.receipt.task,
        subject.document,
        &subject.diagnostic.*,
    );
    var history_params = native.json.object();
    try native.json.put(
        scratch,
        &history_params,
        "task_id",
        native.json.string(
            try std.fmt.allocPrint(scratch, "{s}", .{
                std.fmt.bytesToHex(status_parent.receipt.task, .lower),
            }),
        ),
    );
    const status_memory = try fixture.a.alloc(u8, 64 * 1024);
    defer fixture.a.free(status_memory);
    var status_scratch_max: usize = 0;
    for (0..32) |i| {
        _ = try fixture.service.*.workspaceStart(
            scratch,
            try std.fmt.allocPrint(scratch, "status-history-{d}", .{i}),
            status_parent.receipt.task,
            status_program.receipt.workspace.?,
            &.{0},
            .{},
        );
        if (i != 0 and i != 7 and i != 31) continue;
        try retainedWorkStatusSample(
            fixture,
            subject,
            status_memory,
            history_params,
            &status_scratch_max,
            i,
        );
    }
    try std.testing.expect(status_scratch_max <= 64 * 1024);
    // AUT-08: no authored yields or ports are needed for whole-work controls.
    try retainedWorkNoncooperativeProgram(fixture, scratch, .{
        .parent = subject.parent,
        .diagnostic = subject.diagnostic,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .first = subject.first,
    });
}
fn retainedWorkStatusSample(
    fixture: anytype,
    subject: anytype,
    status_memory: anytype,
    history_params: anytype,
    status_scratch_max: anytype,
    i: anytype,
) !void {
    var status_budget = std.heap.FixedBufferAllocator.init(status_memory);
    var frame = std.heap.ArenaAllocator.init(status_budget.allocator());
    defer frame.deinit();
    var measured = std.testing.FailingAllocator.init(fixture.a, .{});
    const observed = observe: {
        const original_allocator = fixture.service.*.allocator;
        defer fixture.service.*.allocator = original_allocator;
        fixture.service.*.allocator = measured.allocator();
        break :observe try subject.reader.*.call(
            frame.allocator(),
            .@"task.status",
            history_params,
        );
    };
    try std.testing.expect(observed.object.get("associated_work_disposed").?.bool);
    try std.testing.expectEqual(measured.allocated_bytes, measured.freed_bytes);
    status_scratch_max.* = @max(status_scratch_max.*, measured.allocated_bytes);
    if (measured.allocated_bytes > 64 * 1024)
        std.debug.print(
            "disposal status: {d} completed works, {d} scratch allocated bytes\n",
            .{ i + 1, measured.allocated_bytes },
        );
}

fn retainedWorkNoncooperativeProgram(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var noncooperative_builder = source.Builder.init(fixture.a);
    defer noncooperative_builder.deinit();
    const noncooperative_source = try native.source_records.encode(
        scratch,
        try @import("workspace_sources.zig").listLengthWithYields(&noncooperative_builder, false),
    );
    const noncooperative_program = try fixture.service.*.workspaceBuild(
        scratch,
        "noncooperative-build",
        subject.parent.receipt.task,
        noncooperative_source,
        &subject.diagnostic.*,
    );
    const noncooperative_input = try scratch.alloc(u8, 300 * 9 + 1);
    var noncooperative_writer: data.wire.Writer = .{ .output = noncooperative_input };
    for (0..300) |i| {
        try noncooperative_writer.natural(1);
        try noncooperative_writer.fixed(u64, @intCast(i));
    }
    try noncooperative_writer.natural(0);
    try retainedWorkNoncooperativeControl(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .first = subject.first,
        .noncooperative_program = noncooperative_program,
        .noncooperative_input = noncooperative_input,
    });
}

fn retainedWorkNoncooperativeControl(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const noncooperative_start = try fixture.service.*.workspaceStart(
        scratch,
        "noncooperative-start",
        subject.parent.receipt.task,
        subject.noncooperative_program.receipt.workspace.?,
        subject.noncooperative_input,
        .{},
    );
    var noncooperative = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        noncooperative_start.receipt.workspace.?,
    );
    defer noncooperative.deinit();
    try std.testing.expectEqual(.progressed, noncooperative.value.outcome_kind);
    try std.testing.expectEqual(null, noncooperative.value.current_port);
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "noncooperative-park",
        subject.parent.receipt.task,
        noncooperative.value.id,
        noncooperative.value.execution_revision,
        noncooperative.value.control_revision,
        .park,
    );
    var parked_noncooperative = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        noncooperative.value.id,
    );
    defer parked_noncooperative.deinit();
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "noncooperative-cancel",
        subject.parent.receipt.task,
        noncooperative.value.id,
        parked_noncooperative.value.execution_revision,
        parked_noncooperative.value.control_revision,
        .{ .cancel = .{ .bytes = "controller changed direction" } },
    );
    var cancelled_noncooperative = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        noncooperative.value.id,
    );
    defer cancelled_noncooperative.deinit();
    try std.testing.expectEqual(.cancelled, cancelled_noncooperative.value.outcome_kind);
    try retainedWorkJudgment(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .first = subject.first,
    });
}

fn retainedWorkJudgment(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const value_ref: contracts.workspace.Ref = .{ .kind = .value, .id = .{
        .bytes = &std.fmt.bytesToHex(subject.first.*.value.result_value.?.digest, .lower),
    } };
    const expanded = try fixture.service.*.workspaceCommand(
        scratch,
        "expand-zero",
        subject.parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = value_ref, .page = .{} } } },
    );
    try std.testing.expectEqual(.observed, expanded.disposition);
    var expansion = try native.json.parse(fixture.a, expanded.observation_json.bytes, .{});
    defer expansion.deinit();
    try std.testing.expectEqualStrings("\"0\"", expansion.value.object.get("text").?.string);
    var stored_program = try fixture.service.*.workspaceProgram(
        fixture.a,
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
    );
    defer stored_program.deinit();
    const materialize: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .value = .{ .inline_json = .{ .schema = .{ .kind = .schema, .id = .{
            .bytes = &std.fmt.bytesToHex(
                stored_program.value.description.result_schema.digest,
                .lower,
            ),
        } }, .json_text = .{ .bytes = "\"44\"" } } } },
        .sources = .{ .items = &.{value_ref} },
    } } };
    const judgment = try fixture.service.*.workspaceCommand(
        scratch,
        "context-judgment",
        subject.parent.receipt.task,
        materialize,
    );
    try std.testing.expectEqual(.observed, judgment.disposition);
    var judgment_json = try native.json.parse(fixture.a, judgment.observation_json.bytes, .{});
    defer judgment_json.deinit();
    const judgment_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        scratch,
        judgment_json.value.object.get("value").?,
    );
    try retainedWorkJudgmentProvenance(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .value_ref = value_ref,
        .materialize = materialize,
        .judgment_json = &judgment_json,
        .judgment_ref = judgment_ref,
    });
}

fn retainedWorkJudgmentProvenance(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    try std.testing.expectEqualStrings(
        "judgment",
        subject.judgment_json.*.value.object.get("derivation").?.object.get("kind").?.string,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        subject.judgment_json.*.value.object.get("derivation").?.object.get(
            "sources",
        ).?.array.items.len,
    );
    // A small provenance page must not retain the expanded JSON for every
    // antecedent. Preserve duplicates and order, using the complete ordinary
    // observation as an independent byte oracle for the paged projection.
    const provenance_memory = try fixture.a.alloc(u8, 8 * 1024 * 1024);
    defer fixture.a.free(provenance_memory);
    for ([_]usize{ 1, 32 }) |count| {
        try retainedWorkProvenanceSources(fixture, scratch, subject, count, provenance_memory);
    }
    try retainedWorkSelectedViews(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .value_ref = subject.value_ref,
        .materialize = subject.materialize,
        .judgment_ref = subject.judgment_ref,
    });
}
fn retainedWorkProvenanceSources(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    count: anytype,
    provenance_memory: anytype,
) !void {
    const antecedents = try scratch.alloc(contracts.workspace.Ref, count);
    for (antecedents, 0..) |*ref, i| {
        ref.* = if (i % 3 == 1) subject.judgment_ref else subject.value_ref;
    }
    var many_sources = subject.materialize;
    many_sources.context.materialize.sources.items = antecedents;
    const derived = try fixture.service.*.workspaceCommand(
        scratch,
        try std.fmt.allocPrint(scratch, "provenance-sources-{d}", .{count}),
        subject.parent.receipt.task,
        many_sources,
    );
    if (derived.disposition != .observed) std.debug.print(
        "provenance materialize {d}: {s}\n",
        .{ count, derived.observation_json.bytes },
    );
    try std.testing.expectEqual(.observed, derived.disposition);
    const complete = (try native.json.parseAsset(
        scratch,
        derived.observation_json.bytes,
        derived.observation_json.bytes.len,
    )).value;
    const provenance_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        scratch,
        complete.object.get("provenance").?,
    );
    const expected = try native.json.canonical(scratch, complete.object.get("derivation").?);
    try retainedWorkProvenancePages(
        fixture,
        scratch,
        subject,
        count,
        provenance_memory,
        expected,
        provenance_ref,
    );
}

fn retainedWorkProvenancePages(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    count: anytype,
    provenance_memory: anytype,
    expected: anytype,
    provenance_ref: anytype,
) !void {
    for ([_]u64{ 0, expected.len / 2, expected.len - 7, expected.len }) |offset| {
        var budget = std.heap.FixedBufferAllocator.init(provenance_memory);
        const maximum: u32 = if (offset == 0) 1 else 31;
        const page = try fixture.service.*.workspaceCommand(
            budget.allocator(),
            "provenance-page",
            subject.parent.receipt.task,
            .{ .context = .{ .expand = .{ .reference = provenance_ref, .page = .{
                .offset = offset,
                .maximum = maximum,
            } } } },
        );
        if (page.disposition != .observed) std.debug.print("provenance page {d}/{d}: {s}\n", .{
            count,
            offset,
            page.observation_json.bytes,
        });
        try std.testing.expectEqual(.observed, page.disposition);
        const observed = (try native.json.parse(
            scratch,
            page.observation_json.bytes,
            .{},
        )).value;
        const end = @min(expected.len, offset + maximum);
        try std.testing.expectEqualStrings(
            expected[@intCast(offset)..@intCast(end)],
            observed.object.get("text").?.string,
        );
        try std.testing.expectEqual(
            expected.len,
            try native.json.numberInteger(
                usize,
                observed.object.get("total_bytes").?.number_string,
            ),
        );
        try std.testing.expectEqual(
            end,
            try native.json.numberInteger(
                u64,
                observed.object.get("next_offset").?.number_string,
            ),
        );
        try std.testing.expectEqual(end == expected.len, observed.object.get("eof").?.bool);
    }
}

fn retainedWorkSelectedViews(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const selection: contracts.workspace.Command = .{
        .context = .{
            .select = .{ .values = .{ .items = &.{ subject.judgment_ref, subject.value_ref } } },
        },
    };
    const selected = try fixture.service.*.workspaceCommand(
        scratch,
        "context-select",
        subject.parent.receipt.task,
        selection,
    );
    try std.testing.expectEqual(.observed, selected.disposition);
    try std.testing.expectEqual(.view, selected.selected_view.?.kind);
    const repeated_selection = try fixture.service.*.workspaceCommand(
        scratch,
        "context-select",
        subject.parent.receipt.task,
        selection,
    );
    try std.testing.expectEqualStrings(
        selected.selected_view.?.id.bytes,
        repeated_selection.selected_view.?.id.bytes,
    );
    var hypothesis_command = subject.materialize;
    hypothesis_command.context.materialize.sources.items = &.{};
    const equal_payload = try fixture.service.*.workspaceCommand(
        scratch,
        "context-equal-hypothesis",
        subject.parent.receipt.task,
        hypothesis_command,
    );
    const equal_json = (try native.json.parse(
        scratch,
        equal_payload.observation_json.bytes,
        .{},
    )).value;
    const equal_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        scratch,
        equal_json.object.get("value").?,
    );
    try expectContextOutputBound(
        &fixture.service.*,
        scratch,
        subject.parent.receipt.task,
        "context-judgment",
        equal_ref,
        null,
    );
    try expectContextOutputBound(
        &fixture.service.*,
        scratch,
        subject.parent.receipt.task,
        "context-equal-hypothesis",
        subject.value_ref,
        null,
    );
    try retainedWorkReferenceAliases(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .value_ref = subject.value_ref,
        .judgment_ref = subject.judgment_ref,
        .selected = selected,
        .equal_ref = equal_ref,
    });
}

fn retainedWorkReferenceAliases(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const alias = try fixture.service.*.workspaceCommand(
        scratch,
        "context-alias",
        subject.parent.receipt.task,
        .{ .context = .{ .materialize = .{ .input = .{ .value = .{
            .reference = subject.judgment_ref,
        } }, .sources = .{ .items = &.{} } } } },
    );
    const alias_json = (try native.json.parse(scratch, alias.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings(
        subject.judgment_ref.id.bytes,
        alias_json.object.get("value").?.object.get("id").?.string,
    );
    try expectContextOutputBound(
        &fixture.service.*,
        scratch,
        subject.parent.receipt.task,
        "context-alias",
        subject.equal_ref,
        null,
    );
    _ = try fixture.service.*.workspaceCommand(
        scratch,
        "context-sourced-reference",
        subject.parent.receipt.task,
        .{ .context = .{ .materialize = .{ .input = .{ .value = .{
            .reference = subject.judgment_ref,
        } }, .sources = .{ .items = &.{ subject.value_ref, subject.value_ref } } } } },
    );
    try expectContextOutputBound(
        &fixture.service.*,
        scratch,
        subject.parent.receipt.task,
        "context-sourced-reference",
        subject.judgment_ref,
        null,
    );
    try retainedWorkOtherViews(fixture, scratch, subject);
}
fn retainedWorkOtherViews(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    for ([_][]const contracts.workspace.Ref{
        &.{ subject.value_ref, subject.judgment_ref },
        &.{subject.judgment_ref},
        &.{ subject.judgment_ref, subject.value_ref, subject.value_ref },
    }, 0..) |refs, i| {
        const other_view = try fixture.service.*.workspaceCommand(
            scratch,
            try std.fmt.allocPrint(scratch, "context-other-view-{d}", .{i}),
            subject.parent.receipt.task,
            .{ .context = .{ .select = .{ .values = .{ .items = refs } } } },
        );
        try expectContextOutputBound(
            &fixture.service.*,
            scratch,
            subject.parent.receipt.task,
            "context-select",
            other_view.selected_view.?,
            null,
        );
    }
    try fixture.service.*.validateWorkspace(scratch, subject.parent.receipt.task);
    try retainedWorkViewPages(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
        .selected = subject.selected,
    });
}

fn retainedWorkViewPages(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const partial_view = try fixture.service.*.workspaceCommand(
        scratch,
        "view-page",
        subject.parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = subject.selected.selected_view.?, .page = .{
            .maximum = 30,
        } } } },
    );
    var partial_json = try native.json.parse(fixture.a, partial_view.observation_json.bytes, .{});
    defer partial_json.deinit();
    try std.testing.expect(
        !partial_json.value.object.get("selection").?.object.get("complete").?.bool,
    );
    try std.testing.expectEqualStrings(
        "selected_values_only",
        partial_json.value.object.get("coverage").?.string,
    );
    const later_view = try fixture.service.*.workspaceCommand(
        scratch,
        "view-later-page",
        subject.parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = subject.selected.selected_view.?, .page = .{
            .offset = 30,
            .maximum = 30,
        } } } },
    );
    var later_json = try native.json.parse(fixture.a, later_view.observation_json.bytes, .{});
    defer later_json.deinit();
    try std.testing.expectEqualStrings(
        "30",
        later_json.value.object.get("selection").?.object.get("offset").?.number_string,
    );
    const unavailable = try fixture.service.*.workspaceCommand(
        scratch,
        "invalid-value",
        subject.parent.receipt.task,
        .{ .context = .{ .select = .{ .values = .{ .items = &.{.{ .kind = .value, .id = .{
            .bytes = "0000000000000000000000000000000000000000000000000000000000000000",
        } }} } } } },
    );
    try std.testing.expectEqual(.rejected, unavailable.disposition);
    try std.testing.expectEqual(null, unavailable.selected_view);
    try retainedWorkHistoricalAdvance(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .id = subject.id,
        .work = subject.work,
    });
}

fn retainedWorkHistoricalAdvance(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const replay_observation = try fixture.service.*.workspaceCommand(
        scratch,
        "advance",
        subject.parent.receipt.task,
        .{ .work = .{ .advance = .{
            .work = .{ .kind = .work, .id = .{ .bytes = &std.fmt.bytesToHex(subject.id, .lower) } },
            .execution_revision = subject.work.*.value.execution_revision,
            .control_revision = subject.work.*.value.control_revision,
        } } },
    );
    try std.testing.expectEqual(.observed, replay_observation.disposition);
    var replay_json = try native.json.parse(
        fixture.a,
        replay_observation.observation_json.bytes,
        .{},
    );
    defer replay_json.deinit();
    try std.testing.expect(replay_json.value.object.get("replayed").?.bool);
    try std.testing.expect(
        !std.mem.eql(u8, replay_json.value.object.get("outcome").?.string, "completed"),
    );

    // Real local ports survive service replacement, and the acknowledged
    // answer remains the only consumable reply after that replacement.
    var interactive_builder = source.Builder.init(fixture.a);
    defer interactive_builder.deinit();
    const interactive_source = try native.source_records.encode(
        fixture.a,
        try alternatives(&interactive_builder, true),
    );
    defer fixture.a.free(interactive_source);
    const interactive_program = try fixture.service.*.workspaceCommand(
        scratch,
        "interactive-build",
        subject.parent.receipt.task,
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = interactive_source,
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{ .{
            .effect = 0,
            .class = .observation,
        }, .{ .effect = 1, .class = .alternative } } } } } },
    );
    try std.testing.expectEqual(.observed, interactive_program.disposition);
    try retainedWorkInteractiveStart(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .interactive_program = interactive_program,
    });
}

fn retainedWorkInteractiveStart(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var program_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&program_id, subject.interactive_program.program.?.id.bytes);
    const interactive_input = try contracts.encodeOwned(u64, fixture.a, 100);
    defer fixture.a.free(interactive_input);
    const interactive_started = try fixture.service.*.workspaceStart(
        scratch,
        "interactive-start",
        subject.parent.receipt.task,
        program_id,
        interactive_input,
        .{},
    );
    const interactive_id = interactive_started.receipt.workspace.?;
    var interactive_artifact = try fixture.service.*.workspaceProgram(
        scratch,
        subject.parent.receipt.task,
        program_id,
    );
    defer interactive_artifact.deinit();
    const start_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = subject.interactive_program.program.?,
        .input = .{ .inline_json = .{ .schema = try workspaceRef(
            scratch,
            .schema,
            interactive_artifact.value.description.input_schema.digest,
        ), .json_text = .{ .bytes = "\"100\"" } } },
        .policy = .{},
    } } };
    const original_observation = try fixture.service.*.workspaceCommand(
        scratch,
        "interactive-start",
        subject.parent.receipt.task,
        start_command,
    );
    // Paging reaches complete payloads, including retained failures, rather
    // than paging an observation that has already truncated its preview.
    try retainedWorkPayloadProgram(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = &program_id,
        .interactive_input = interactive_input,
        .interactive_id = interactive_id,
        .start_command = start_command,
        .original_observation = original_observation,
    });
}

fn retainedWorkPayloadProgram(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var payload_builder = source.Builder.init(fixture.a);
    defer payload_builder.deinit();
    const payload_type = try payload_builder.schema(.text);
    const payload_effect = try payload_builder.effect(.{
        .identity = "example/large-payload",
        .payload = payload_type,
        .result = payload_type,
        .external = false,
    });
    const payload_entry = try payload_builder.declare(
        &.{payload_type},
        payload_type,
        &.{payload_effect},
        &.{},
    );
    const payload_result = try payload_builder.variable(payload_type);
    try payload_builder.define(
        payload_entry,
        try payload_builder.bind(
            payload_result,
            try payload_builder.term(.{ .perform = .{
                .effect = payload_effect,
                .payload = try payload_builder.reference(
                    payload_builder.parameter(payload_entry, 0),
                ),
            } }),
            try payload_builder.term(.{ .fail = try payload_builder.reference(payload_result) }),
        ),
    );
    const payload_source = try native.source_records.encode(
        scratch,
        payload_builder.module(payload_entry, payload_type),
    );
    const payload_program = try fixture.service.*.workspaceCommand(
        scratch,
        "payload-build",
        subject.parent.receipt.task,
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = payload_source,
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{
            .effect = payload_effect,
            .class = .input,
        }} } } } },
    );
    try std.testing.expect(payload_program.program != null);
    try retainedWorkPayloadStart(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
        .interactive_id = subject.interactive_id,
        .start_command = subject.start_command,
        .original_observation = subject.original_observation,
        .payload_program = payload_program,
    });
}

fn retainedWorkPayloadStart(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const complete_payload = try scratch.alloc(u8, 20000);
    @memset(complete_payload, 'x');
    @memcpy(complete_payload[19996..], "TAIL");
    const payload_wire = try contracts.encodeOwned(contracts.Utf8, scratch, .{
        .bytes = complete_payload,
    });
    const payload_start = try fixture.service.*.workspaceStart(
        scratch,
        "payload-start",
        subject.parent.receipt.task,
        try nativeIdentity(subject.payload_program.program.?),
        payload_wire,
        .{},
    );
    var payload_work = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        payload_start.receipt.workspace.?,
    );
    defer payload_work.deinit();
    var payload_port = try contracts.decodeOwned(
        native.workspace.Port,
        scratch,
        try fixture.namespace.*.store.object(scratch, payload_work.value.current_port.?, null),
    );
    defer payload_port.deinit();
    try retainedWorkPayloadInspection(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
        .interactive_id = subject.interactive_id,
        .start_command = subject.start_command,
        .original_observation = subject.original_observation,
        .complete_payload = complete_payload,
        .payload_work = &payload_work,
        .payload_port = &payload_port,
    });
}

fn retainedWorkPayloadInspection(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const payload_port_ref = try workspaceRef(scratch, .port, subject.payload_port.*.value.id);
    const payload_work_ref = try workspaceRef(scratch, .work, subject.payload_work.*.value.id);
    const payload_json = try native.json.canonical(
        scratch,
        native.json.string(subject.complete_payload),
    );
    const full_port = try fixture.service.*.workspaceCommand(
        scratch,
        "payload-expand",
        subject.parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = payload_port_ref, .page = .{
            .maximum = 48 * 1024,
        } } } },
    );
    var full_port_json = try native.json.parse(scratch, full_port.observation_json.bytes, .{
        .bytes = 64 * 1024,
    });
    defer full_port_json.deinit();
    try std.testing.expectEqualStrings(
        payload_json,
        full_port_json.value.object.get("text").?.string,
    );
    try std.testing.expect(full_port_json.value.object.get("complete").?.bool);
    const generation = subject.payload_port.*.value.generation;
    _ = try fixture.service.*.workspaceInteract(
        scratch,
        "payload-answer",
        subject.parent.receipt.task,
        .{ .expected = .{
            .work = payload_work_ref,
            .execution_revision = subject.payload_work.*.value.execution_revision,
            .control_revision = subject.payload_work.*.value.control_revision,
        }, .port = payload_port_ref, .generation = generation, .command = .{
            .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                scratch,
                .schema,
                subject.payload_port.*.value.interface.argument.digest,
            ), .json_text = .{ .bytes = payload_json } } },
        } },
    );
    try retainedWorkPayloadFailure(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
        .interactive_id = subject.interactive_id,
        .start_command = subject.start_command,
        .original_observation = subject.original_observation,
        .payload_work = subject.payload_work,
        .payload_work_ref = payload_work_ref,
        .payload_json = payload_json,
    });
}

fn retainedWorkPayloadFailure(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    for (0..16) |_| {
        _ = try fixture.service.*.pump(scratch);
        var current = try fixture.service.*.workspaceWork(
            scratch,
            subject.parent.receipt.task,
            subject.payload_work.*.value.id,
        );
        defer current.deinit();
        if (current.value.terminal()) break;
    }
    var payload_failed = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        subject.payload_work.*.value.id,
    );
    defer payload_failed.deinit();
    try std.testing.expectEqual(.failed, payload_failed.value.outcome_kind);
    var reconstructed: std.ArrayList(u8) = .empty;
    var payload_offset: u64 = 0;
    while (payload_offset < subject.payload_json.len) {
        const part = try fixture.service.*.workspaceCommand(
            scratch,
            "failure-expand",
            subject.parent.receipt.task,
            .{ .context = .{ .expand = .{ .reference = subject.payload_work_ref, .page = .{
                .offset = payload_offset,
                .maximum = 4096,
            } } } },
        );
        var parsed_part = try native.json.parse(scratch, part.observation_json.bytes, .{});
        defer parsed_part.deinit();
        try reconstructed.appendSlice(scratch, parsed_part.value.object.get("text").?.string);
        if (parsed_part.value.object.get("eof").?.bool) break;
        const next_offset = try native.json.numberInteger(
            u64,
            parsed_part.value.object.get("next_offset").?.number_string,
        );
        try std.testing.expect(next_offset > payload_offset);
        payload_offset = next_offset;
    }
    try std.testing.expectEqualStrings(subject.payload_json, reconstructed.items);
    try retainedWorkInteractiveReplies(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
        .interactive_id = subject.interactive_id,
        .start_command = subject.start_command,
        .original_observation = subject.original_observation,
    });
}

fn retainedWorkInteractiveReplies(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    for (0..4) |i| {
        try retainedWorkInteractiveReply(fixture, scratch, subject, i);
    }
    try retainedWorkInteractiveResult(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
        .interactive_id = subject.interactive_id,
    });
}
fn retainedWorkInteractiveReply(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    i: anytype,
) !void {
    var current = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        subject.interactive_id,
    );
    defer current.deinit();
    const port_bytes = try fixture.namespace.*.store.object(
        fixture.a,
        current.value.current_port.?,
        null,
    );
    defer fixture.a.free(port_bytes);
    var port = try contracts.decodeOwned(native.workspace.Port, fixture.a, port_bytes);
    defer port.deinit();
    try std.testing.expectEqual(@as(u64, @intCast(i + 1)), port.value.generation);
    const interaction: @FieldType(contracts.workspace.Work, "interact") = .{
        .expected = .{
            .work = try workspaceRef(scratch, .work, subject.interactive_id),
            .execution_revision = current.value.execution_revision,
            .control_revision = current.value.control_revision,
        },
        .port = try workspaceRef(scratch, .port, port.value.id),
        .generation = port.value.generation,
        .command = if (i == 3) .{ .finish = .{} } else .{
            .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                scratch,
                .schema,
                port.value.interface.argument.digest,
            ), .json_text = .{
                .bytes = if (i == 0) "{}" else if (i == 1) "\"10\"" else "\"20\"",
            } } },
        },
    };
    const operation_id = try std.fmt.allocPrint(scratch, "interact-{d}", .{i});
    const accepted = try fixture.service.*.workspaceInteract(
        scratch,
        operation_id,
        subject.parent.receipt.task,
        interaction,
    );
    try retainedWorkRejectReorderedReplies(fixture, scratch, subject, i);
    try retainedWorkReplayInteraction(
        fixture,
        scratch,
        subject,
        i,
        &port,
        interaction,
        operation_id,
        accepted,
    );
}

fn retainedWorkRejectReorderedReplies(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    i: usize,
) !void {
    if (i == 2) {
        var answered = try fixture.service.*.workspaceWork(
            scratch,
            subject.parent.receipt.task,
            subject.interactive_id,
        );
        defer answered.deinit();
        try std.testing.expectEqual(@as(usize, 3), answered.value.inputs.items.len);
        const reordered = [_]native.testing.state.Reference{
            answered.value.inputs.items[0],
            answered.value.inputs.items[2],
            answered.value.inputs.items[1],
        };
        try expectWorkInputHistoryBound(
            &fixture.service.*,
            scratch,
            subject.parent.receipt.task,
            subject.interactive_id,
            &reordered,
        );
        try expectInteractionReplyBound(
            &fixture.service.*,
            scratch,
            subject.parent.receipt.task,
            "interact-1",
        );
        try fixture.service.*.validateWorkspace(scratch, subject.parent.receipt.task);
    }
}

fn retainedWorkReplayInteraction(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    i: anytype,
    port: anytype,
    interaction: anytype,
    operation_id: anytype,
    accepted: anytype,
) !void {
    const replay = try fixture.service.*.workspaceInteract(
        fixture.a,
        operation_id,
        subject.parent.receipt.task,
        interaction,
    );
    defer fixture.a.free(replay.receipt.client_operation_id.bytes);
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqualDeep(accepted.receipt, replay.receipt);
    const historical = try fixture.service.*.workspaceCommand(
        scratch,
        "interactive-start",
        subject.parent.receipt.task,
        subject.start_command,
    );
    try std.testing.expectEqualStrings(
        subject.original_observation.observation_json.bytes,
        historical.observation_json.bytes,
    );
    const live = try fixture.service.*.workspaceCommand(
        scratch,
        "inspect-answered",
        subject.parent.receipt.task,
        .{ .work = .{ .inspect = .{ .work = interaction.expected.work } } },
    );
    var live_json = try native.json.parse(fixture.a, live.observation_json.bytes, .{});
    defer live_json.deinit();
    try std.testing.expect(!live_json.value.object.get("port_accepts_command").?.bool);
    try std.testing.expectError(
        error.StaleRevision,
        fixture.service.*.workspaceInteract(
            scratch,
            "new-conflicting-answer",
            subject.parent.receipt.task,
            interaction,
        ),
    );
    try retainedWorkRestoreInteraction(fixture, scratch, subject, i, port);
}

fn retainedWorkRestoreInteraction(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    i: anytype,
    port: anytype,
) !void {
    try fixture.service.*.close(scratch);
    fixture.service.* = try native.tasks.Service(OwnerTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile,
    );
    const restored_observation = try fixture.service.*.workspaceCommand(
        scratch,
        "interactive-start",
        subject.parent.receipt.task,
        subject.start_command,
    );
    try std.testing.expectEqualStrings(
        subject.original_observation.observation_json.bytes,
        restored_observation.observation_json.bytes,
    );
    var recovered_work = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        subject.interactive_id,
    );
    defer recovered_work.deinit();
    _ = try fixture.service.*.workspaceControl(
        scratch,
        try std.fmt.allocPrint(scratch, "interactive-resume-{d}", .{i}),
        subject.parent.receipt.task,
        subject.interactive_id,
        recovered_work.value.execution_revision,
        recovered_work.value.control_revision,
        .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .next_exposed_event } },
    );
    for (0..20) |_| {
        _ = try fixture.service.*.pump(scratch);
        var observed = try fixture.service.*.workspaceWork(
            fixture.a,
            subject.parent.receipt.task,
            subject.interactive_id,
        );
        defer observed.deinit();
        if (observed.value.terminal() or
            observed.value.port_generation > port.*.value.generation) break;
    }
}

fn retainedWorkInteractiveResult(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var interactive_completed = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        subject.interactive_id,
    );
    defer interactive_completed.deinit();
    try std.testing.expectEqual(.completed, interactive_completed.value.outcome_kind);
    const interactive_result = try fixture.namespace.*.store.object(
        fixture.a,
        interactive_completed.value.result.?,
        null,
    );
    defer fixture.a.free(interactive_result);
    var final_result = try contracts.decodeOwned(u64, fixture.a, interactive_result);
    defer final_result.deinit();
    try std.testing.expectEqual(@as(u64, 121), final_result.value);
    try fixture.service.*.validateWorkspace(scratch, subject.parent.receipt.task);
    // A valid checkpoint does not certify unrelated native port metadata.
    try retainedWorkPortMetadata(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
        .interactive_completed = &interactive_completed,
    });
}

fn retainedWorkPortMetadata(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture.assets.manifest, &manifest_digest, .{});
    const archive_index = try fixture.namespace.*.store.archiveIndex(
        scratch,
        subject.parent.receipt.task,
        .{ .digest = manifest_digest, .bytes = fixture.assets.manifest.len },
    );
    var compiler_facts = try fixture.service.*.prepareWorkspaceValidation(
        subject.parent.receipt.task,
    );
    defer compiler_facts.deinit();
    try fixture.namespace.*.store.begin();
    var forged = subject.interactive_completed.*.value;
    forged.port_generation += 1;
    try fixture.namespace.*.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        forged.id,
        forged.task,
        forged,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        fixture.service.*.validateWorkspaceRecordsPrepared(
            scratch,
            subject.parent.receipt.task,
            archive_index.records.items,
            &compiler_facts,
        ),
    );
    fixture.namespace.*.store.rollback();
    try fixture.namespace.*.store.begin();
    forged = subject.interactive_completed.*.value;
    forged.cancellation = .{ .bytes = "forged applied cancellation" };
    forged.cancellation_applied = true;
    try fixture.namespace.*.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        forged.id,
        forged.task,
        forged,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        fixture.service.*.validateWorkspaceRecordsPrepared(
            scratch,
            subject.parent.receipt.task,
            archive_index.records.items,
            &compiler_facts,
        ),
    );
    fixture.namespace.*.store.rollback();
    try retainedWorkCancelAfterAnswer(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .program_id = subject.program_id,
        .interactive_input = subject.interactive_input,
    });
}

fn retainedWorkCancelAfterAnswer(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    const cancel_started = try fixture.service.*.workspaceStart(
        scratch,
        "cancel-after-answer-start",
        subject.parent.receipt.task,
        subject.program_id.*,
        subject.interactive_input,
        .{},
    );
    var cancel_work = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        cancel_started.receipt.workspace.?,
    );
    defer cancel_work.deinit();
    const cancel_port_bytes = try fixture.namespace.*.store.object(
        fixture.a,
        cancel_work.value.current_port.?,
        null,
    );
    defer fixture.a.free(cancel_port_bytes);
    var cancel_port = try contracts.decodeOwned(
        native.workspace.Port,
        fixture.a,
        cancel_port_bytes,
    );
    defer cancel_port.deinit();
    _ = try fixture.service.*.workspaceInteract(
        scratch,
        "answer-before-cancel",
        subject.parent.receipt.task,
        .{
            .expected = .{
                .work = try workspaceRef(scratch, .work, cancel_work.value.id),
                .execution_revision = cancel_work.value.execution_revision,
                .control_revision = cancel_work.value.control_revision,
            },
            .port = try workspaceRef(scratch, .port, cancel_port.value.id),
            .generation = cancel_port.value.generation,
            .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                scratch,
                .schema,
                cancel_port.value.interface.argument.digest,
            ), .json_text = .{ .bytes = "{}" } } } },
        },
    );
    try retainedWorkApplyCancellation(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .cancel_work = &cancel_work,
    });
}

fn retainedWorkApplyCancellation(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var answered_work = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        subject.cancel_work.*.value.id,
    );
    defer answered_work.deinit();
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "cancel-after-answer",
        subject.parent.receipt.task,
        subject.cancel_work.*.value.id,
        answered_work.value.execution_revision,
        answered_work.value.control_revision,
        .{ .cancel = .{ .bytes = "stop exploring" } },
    );
    // Explicit advance and the scheduled pump must apply the same pending
    // cancellation after consuming an already settled reply.
    for (0..2) |step| {
        var pending_cancel = try fixture.service.*.workspaceWork(
            scratch,
            subject.parent.receipt.task,
            subject.cancel_work.*.value.id,
        );
        defer pending_cancel.deinit();
        if (pending_cancel.value.terminal()) break;
        _ = try fixture.service.*.workspaceControl(
            scratch,
            try std.fmt.allocPrint(scratch, "cancel-explicit-advance-{d}", .{step}),
            subject.parent.receipt.task,
            subject.cancel_work.*.value.id,
            pending_cancel.value.execution_revision,
            pending_cancel.value.control_revision,
            .advance,
        );
    }
    for (0..20) |_| {
        _ = try fixture.service.*.pump(scratch);
        var observed = try fixture.service.*.workspaceWork(
            fixture.a,
            subject.parent.receipt.task,
            subject.cancel_work.*.value.id,
        );
        defer observed.deinit();
        if (observed.value.terminal()) break;
    }
    var cancelled_after_answer = try fixture.service.*.workspaceWork(
        fixture.a,
        subject.parent.receipt.task,
        subject.cancel_work.*.value.id,
    );
    defer cancelled_after_answer.deinit();
    try std.testing.expectEqual(.cancelled, cancelled_after_answer.value.outcome_kind);
    try std.testing.expect(cancelled_after_answer.value.cancellation_applied);
    // WORK-14: cancellation is applied before cleanup finishes. Cleanup may
    // yield and expose a real request without being reported disposed early.
    try retainedWorkDisposalProgram(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
    });
}

fn retainedWorkDisposalProgram(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var disposal_builder = source.Builder.init(scratch);
    defer disposal_builder.deinit();
    const disposal_source = try native.source_records.encode(
        scratch,
        try @import("workspace_sources.zig").yieldingDisposal(&disposal_builder),
    );
    const disposal_program = try fixture.service.*.workspaceCommand(
        scratch,
        "disposal-build",
        subject.parent.receipt.task,
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = disposal_source,
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{
            .effect = 0,
            .class = .observation,
        }} } } } },
    );
    try std.testing.expectEqual(.observed, disposal_program.disposition);
    var disposal_program_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&disposal_program_id, disposal_program.program.?.id.bytes);
    const disposal_started = try fixture.service.*.workspaceStart(
        scratch,
        "disposal-start",
        subject.parent.receipt.task,
        disposal_program_id,
        &.{},
        .{},
    );
    const disposal_id = disposal_started.receipt.workspace.?;
    var before_disposal = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        disposal_id,
    );
    defer before_disposal.deinit();
    try std.testing.expectEqual(.yielded, before_disposal.value.outcome_kind);
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "disposal-cancel",
        subject.parent.receipt.task,
        disposal_id,
        before_disposal.value.execution_revision,
        before_disposal.value.control_revision,
        .{ .cancel = .{ .bytes = "abandoned inquiry" } },
    );
    try retainedWorkDisposalCancellation(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
        .disposal_id = disposal_id,
    });
}

fn retainedWorkDisposalCancellation(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var cancelling = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        subject.disposal_id,
    );
    defer cancelling.deinit();
    try std.testing.expect(cancelling.value.cancellation_applied and !cancelling.value.terminal());
    try expectWorkCancellationReasonBound(&fixture.service.*, scratch, cancelling.value);
    _ = try fixture.service.*.workspaceControl(
        scratch,
        "disposal-cancel-again",
        subject.parent.receipt.task,
        subject.disposal_id,
        cancelling.value.execution_revision,
        cancelling.value.control_revision,
        .{ .cancel = .{ .bytes = "different reason" } },
    );
    try retainedWorkDisposalProgress(fixture, scratch, subject);
}
fn retainedWorkDisposalProgress(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
) !void {
    var saw_cleanup_port = false;
    var disposal_complete = false;
    for (0..20) |_| {
        var current = try fixture.service.*.workspaceWork(
            scratch,
            subject.parent.receipt.task,
            subject.disposal_id,
        );
        defer current.deinit();
        try std.testing.expect(current.value.cancellation_applied);
        try std.testing.expectEqualStrings("abandoned inquiry", current.value.cancellation.?.bytes);
        const inspected = try fixture.service.*.workspaceCommand(
            scratch,
            try std.fmt.allocPrint(scratch, "disposal-inspect-{d}", .{
                current.value.execution_revision,
            }),
            subject.parent.receipt.task,
            .{ .work = .{ .inspect = .{
                .work = try workspaceRef(scratch, .work, subject.disposal_id),
            } } },
        );
        var observation = try native.json.parse(scratch, inspected.observation_json.bytes, .{});
        defer observation.deinit();
        try std.testing.expectEqual(
            current.value.terminal(),
            observation.value.object.get("cleanup_complete").?.bool,
        );
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            disposal_complete = true;
            break;
        }
        if (current.value.current_port) |ref| {
            saw_cleanup_port = true;
            try retainedWorkDisposalReply(fixture, scratch, subject, &current, ref);
        }
        _ = try fixture.service.*.pump(scratch);
    }
    try std.testing.expect(saw_cleanup_port and disposal_complete);
    try fixture.service.*.validateWorkspace(scratch, subject.parent.receipt.task);
    // OWN-08: a real SQLite write failure after the kernel publishes fences
    // the entire owner, including root and independent work dispatch.
    try retainedWorkStorageFence(fixture, scratch, .{
        .parent = subject.parent,
        .program = subject.program,
        .input = subject.input,
    });
}

fn retainedWorkDisposalReply(
    fixture: anytype,
    scratch: std.mem.Allocator,
    subject: anytype,
    current: anytype,
    ref: anytype,
) !void {
    var port = try contracts.decodeOwned(
        native.workspace.Port,
        scratch,
        try fixture.namespace.*.store.object(scratch, ref, null),
    );
    defer port.deinit();
    _ = try fixture.service.*.workspaceInteract(
        scratch,
        "disposal-answer",
        subject.parent.receipt.task,
        .{
            .expected = .{
                .work = try workspaceRef(scratch, .work, subject.disposal_id),
                .execution_revision = current.*.value.execution_revision,
                .control_revision = current.*.value.control_revision,
            },
            .port = try workspaceRef(scratch, .port, port.value.id),
            .generation = port.value.generation,
            .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                scratch,
                .schema,
                port.value.interface.argument.digest,
            ), .json_text = .{ .bytes = "{}" } } } },
        },
    );
}

fn retainedWorkStorageFence(fixture: anytype, scratch: std.mem.Allocator, subject: anytype) !void {
    const fault_start = try fixture.service.*.workspaceStart(
        scratch,
        "fault-start",
        subject.parent.receipt.task,
        subject.program.receipt.workspace.?,
        subject.input,
        .{},
    );
    var fault_work = try fixture.service.*.workspaceWork(
        scratch,
        subject.parent.receipt.task,
        fault_start.receipt.workspace.?,
    );
    defer fault_work.deinit();
    try fixture.namespace.*.store.database.exec("PRAGMA query_only=ON;");
    try std.testing.expectError(
        error.StorageUnavailable,
        fixture.service.*.workspaceControl(
            scratch,
            "fault-advance",
            subject.parent.receipt.task,
            fault_work.value.id,
            fault_work.value.execution_revision,
            fault_work.value.control_revision,
            .advance,
        ),
    );
    try std.testing.expect(fixture.namespace.*.store.fenced and fixture.service.*.active != null);
    try std.testing.expectError(error.StorageUnavailable, fixture.service.*.pump(scratch));
    try fixture.namespace.*.store.database.exec("PRAGMA query_only=OFF;");
}

test "workspace commands use the generated nested-sum schema and native model normalization" {
    const protean = @import("protean");
    const Action = union(enum) { program: struct { command: contracts.workspace.Program } };
    const Profile = protean.model_invocation.Profile(Action, .{.{
        .name = "program",
        .description = "Construct or inspect Horos.",
    }}, .{});
    const declaration = Profile.allDeclarations().items[0];
    try std.testing.expectEqual(.sum, declaration.argument_codec.items[0].field.kind);
    try std.testing.expect(
        std.mem.indexOf(u8, declaration.input_schema_json.bytes, "\"anyOf\"") != null,
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Model = protean.model(
        .{
            .name = "workspace-codec",
            .model = "fixture-model",
            .parameters = .{},
            .protocol = struct {
                pub const semantic_identity = protean.model_invocation.protocol_identity;
            },
        },
    );
    var invocation = try Profile.templateValue(Model, .{ .items = &.{} }, .{
        .minimum_calls = 1,
        .maximum_calls = 1,
        .parallel_calls = false,
    });
    invocation.tools = Profile.allDeclarations();
    for ([_]struct { arguments: []const u8, valid: bool }{
        .{
            .arguments = "{\"command\":{\"tag\":\"describe\",\"value\":{\"section\":\"sourc" ++
                "e_records\",\"page\":{\"offset\":0,\"maximum\":16384}}}}",
            .valid = true,
        },
        .{
            .arguments = "{\"command\":{\"tag\":\"invoke_native_code\",\"value\":{}}}",
            .valid = false,
        },
        .{
            .arguments = "{\"command\":{\"tag\":\"describe\",\"value\":{\"section\":\"sourc" ++
                "e_records\",\"page\":{\"offset\":0,\"maximum\":16384},\"authority" ++
                "\":true}}}",
            .valid = false,
        },
    }) |case| {
        var function = native.json.object();
        try native.json.put(a, &function, "type", native.json.string("function_call"));
        try native.json.put(a, &function, "status", native.json.string("completed"));
        try native.json.put(a, &function, "call_id", native.json.string("command"));
        try native.json.put(a, &function, "name", native.json.string("program"));
        try native.json.put(a, &function, "arguments", native.json.string(case.arguments));
        var output: native.json.Value = .{ .array = .init(a) };
        try output.array.append(function);
        const normalized = try native.responses.OutputNormalizer(Profile).normalize(
            a,
            invocation,
            output,
        );
        try std.testing.expectEqual(.output, std.meta.activeTag(normalized));
        const decoded = normalized.output.items.items[0].function_call.decoded_action;
        try std.testing.expectEqual(case.valid, decoded == .decoded);
        if (decoded == .decoded) try std.testing.expectEqual(
            .source_records,
            decoded.decoded.program.command.describe.section,
        );
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
        const effect = try author.operationId(
            c.author,
            try c.external(
                "workspace-context",
                try c.schema(ContextTypes.Input),
                try c.schema(ContextTypes.Output),
                .read,
            ),
        );
        const entry = try c.builder.declare(&.{input}, output, &.{effect}, &.{});
        try c.builder.define(
            entry,
            try c.builder.term(.{ .perform = .{
                .effect = effect,
                .payload = try c.builder.reference(c.builder.parameter(entry, 0)),
            } }),
        );
        return c.builder.module(entry, try author.schemaId(c.author, try c.schema(void)));
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(ContextTypes.Input, ctx.allocator, bytes);
        defer command.deinit();
        // This fixture's compiled application accepts the command as its root
        // input. The production adapter authenticates a captured model action.
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{
            .command = command.value,
            .snapshot = ctx.resources[0],
            .catalog = if (ctx.resources.len > 1) ctx.resources[1] else null,
            .input = if (ctx.resources.len > 2) ctx.resources[2] else null,
        });
    }
    fn payloadSchema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(ContextTypes.Input, a);
    }
    fn resultSchema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(ContextTypes.Output, a);
    }
};

fn expectBuildCaptureOutputBound(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    attempt: [32]u8,
    archive_path: []const u8,
) !void {
    const store = &service.namespace.store;
    const bytes = (try store.recordBytes(a, "capture", attempt, task)).?;
    defer a.free(bytes);
    var captured = try contracts.decodeOwned(native.testing.state.Capture, a, bytes);
    defer captured.deinit();
    try std.testing.expect(captured.value.projection == null);
    const request = try store.object(a, captured.value.request, null);
    defer a.free(request);
    var input = try contracts.decodeOwned(native.testing.workspace_build.Input, a, request);
    defer input.deinit();
    try std.testing.expect(input.value == .program);
    _ = try service.exportCheckpoint(a, task, archive_path);
    for ([_]contracts.workspace.ValidationOutcome{
        .resource_exhausted,
        .interrupted,
        .unavailable_dependency,
    }) |outcome| {
        const output = try contracts.encodeOwned(
            native.testing.workspace_build.Output,
            a,
            .{ .validation = .{
                .outcome = outcome,
                .code = .{ .bytes = "TransientCompilerFailure" },
            } },
        );
        defer a.free(output);
        try store.begin();
        defer store.rollback();
        var forged = captured.value;
        forged.response = try store.putObject(output);
        try store.putRecord(native.testing.state.Capture, "capture", attempt, task, forged);
        try service.namespace.commit("test.forge-build-capture-output");
        const forged_path = try std.fmt.allocPrint(a, "{s}-{s}", .{
            archive_path,
            @tagName(outcome),
        });
        defer a.free(forged_path);
        try std.testing.expectError(
            error.InvalidArchive,
            service.exportCheckpoint(a, task, forged_path),
        );
        try store.begin();
        try store.putRecord(native.testing.state.Capture, "capture", attempt, task, captured.value);
        try service.namespace.commit("test.restore-build-capture-output");
    }
    const restored_path = try std.fmt.allocPrint(a, "{s}-restored", .{archive_path});
    defer a.free(restored_path);
    _ = try service.exportCheckpoint(a, task, restored_path);
}

fn expectDirectDeriveOwnerBound(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    input: native.testing.workspace_build.DeriveInput,
    archive_path: []const u8,
) !void {
    var before = try service.task(a, task);
    defer before.deinit();
    const reply = try service.workspaceCommand(
        a,
        "direct-derive-owner-cut",
        task,
        .{ .program = .{ .derive = .{
            .ancestor = input.subject,
            .program = try workspaceRef(a, .program, input.program),
            .proposal = .{ .json_text = .{ .bytes = input.proposal.bytes } },
        } } },
    );
    try std.testing.expectEqual(.rejected, reply.disposition);
    var after = try service.task(a, task);
    defer after.deinit();
    try std.testing.expectEqual(before.value.event_high + 1, after.value.event_high);
    try std.testing.expectEqual(before.value.revision + 1, after.value.revision);
    const store = &service.namespace.store;
    const event_bytes = blk: {
        var query = try store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? AND e.seq=? AND e.revision=?",
            &.{
                .{ .blob = &task },
                .{ .integer = @intCast(after.value.event_high) },
                .{ .integer = @intCast(after.value.revision) },
            },
        );
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        break :blk try a.dupe(u8, try query.bytes(0));
    };
    defer a.free(event_bytes);
    var event = try contracts.decodeOwned(native.testing.state.Event, a, event_bytes);
    defer event.deinit();
    try std.testing.expectEqual(.workspace, event.value.kind);
    const command_bytes = try store.object(a, event.value.workspace_command.?, null);
    defer a.free(command_bytes);
    var command = try contracts.decodeOwned(native.workspace.PublicationCommand, a, command_bytes);
    defer command.deinit();
    try std.testing.expect(
        command.value == .semantic and command.value.semantic.command == .derive,
    );
    const frozen_bytes = try store.object(a, command.value.semantic.input, null);
    defer a.free(frozen_bytes);
    var frozen = try contracts.decodeOwned(native.testing.workspace_build.Input, a, frozen_bytes);
    defer frozen.deinit();
    try std.testing.expect(frozen.value == .derive and frozen.value.derive.basis == .controller);
    const owner = event.value.controller_read orelse return error.MissingControllerReadCut;
    try std.testing.expectEqual(
        frozen.value.derive.basis.controller.event_watermark,
        owner.event_watermark,
    );
    try std.testing.expectEqual(
        frozen.value.derive.basis.controller.execution_revision,
        owner.execution_revision,
    );
    try expectDirectDeriveOwnerCorruption(service, a, task, archive_path, &event.value, owner);
}

fn expectDeriveCaptureOwnerBound(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    attempt: [32]u8,
    archive_path: []const u8,
) !void {
    const store = &service.namespace.store;
    const capture_bytes = (try store.recordBytes(a, "capture", attempt, task)).?;
    defer a.free(capture_bytes);
    var captured = try contracts.decodeOwned(native.testing.state.Capture, a, capture_bytes);
    defer captured.deinit();
    try std.testing.expect(captured.value.projection == null);
    const request = try store.object(a, captured.value.request, null);
    defer a.free(request);
    var input = try contracts.decodeOwned(native.testing.workspace_build.Input, a, request);
    defer input.deinit();
    try std.testing.expect(input.value == .derive and input.value.derive.basis == .controller);
    const response = try store.object(a, captured.value.response.?, null);
    defer a.free(response);
    var output = try contracts.decodeOwned(native.testing.workspace_build.Output, a, response);
    defer output.deinit();
    try std.testing.expect(output.value == .rejected);
    const attempt_bytes = (try store.recordBytes(a, "attempt", attempt, task)).?;
    defer a.free(attempt_bytes);
    var saved = try contracts.decodeOwned(native.testing.state.Attempt, a, attempt_bytes);
    defer saved.deinit();
    const owner = saved.value.controller_read orelse return error.MissingControllerReadCut;
    try std.testing.expectEqual(
        input.value.derive.basis.controller.event_watermark,
        owner.event_watermark,
    );
    try std.testing.expectEqual(
        input.value.derive.basis.controller.execution_revision,
        owner.execution_revision,
    );
    try expectDeriveCaptureOwnerCorruption(
        service,
        a,
        task,
        attempt,
        archive_path,
        &saved.value,
        owner,
    );
    try expectDeriveCapturePrefixBound(
        service,
        a,
        saved.value,
        captured.value,
        input.value,
        archive_path,
    );
    const direct_path = try std.fmt.allocPrint(a, "{s}-direct", .{archive_path});
    defer a.free(direct_path);
    try expectDirectDeriveOwnerBound(service, a, task, input.value.derive, direct_path);
}

fn expectDeriveCapturePrefixBound(
    service: anytype,
    a: std.mem.Allocator,
    saved: native.testing.state.Attempt,
    captured: native.testing.state.Capture,
    input: native.testing.workspace_build.Input,
    archive_path: []const u8,
) !void {
    const store = &service.namespace.store;
    const task = saved.task;
    const attempt = saved.id;
    const owner = saved.controller_read orelse return error.MissingControllerReadCut;
    try std.testing.expect(owner.event_watermark > 0 and owner.execution_revision > 0);
    var forged_input = input;
    forged_input.derive.basis.controller.event_watermark = 0;
    const forged_bytes = try contracts.encodeOwned(
        native.testing.workspace_build.Input,
        a,
        forged_input,
    );
    defer a.free(forged_bytes);
    try store.begin();
    defer store.rollback();
    var forged_attempt = saved;
    forged_attempt.controller_read.?.event_watermark = 0;
    forged_attempt.prepared = try store.putObject(forged_bytes);
    var forged_capture = captured;
    forged_capture.request = forged_attempt.prepared.?;
    try store.database.run(
        "DELETE FROM records WHERE kind='attempt' AND id=? AND task=?",
        &.{ .{ .blob = &attempt }, .{ .blob = &task } },
    );
    try store.createRecord(native.testing.state.Attempt, "attempt", attempt, task, forged_attempt);
    try store.putRecord(native.testing.state.Capture, "capture", attempt, task, forged_capture);
    try service.namespace.commit("test.forge-derive-capture-prefix");
    const prefix_path = try std.fmt.allocPrint(a, "{s}-prefix", .{archive_path});
    defer a.free(prefix_path);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspace(a, task));
    try std.testing.expectError(
        error.InvalidArchive,
        service.exportCheckpoint(a, task, prefix_path),
    );
    try store.begin();
    try store.database.run(
        "DELETE FROM records WHERE kind='attempt' AND id=? AND task=?",
        &.{ .{ .blob = &attempt }, .{ .blob = &task } },
    );
    try store.createRecord(native.testing.state.Attempt, "attempt", attempt, task, saved);
    try store.putRecord(native.testing.state.Capture, "capture", attempt, task, captured);
    try service.namespace.commit("test.restore-derive-capture-prefix");
    try service.validateWorkspace(a, task);
    _ = try service.exportCheckpoint(a, task, prefix_path);
}

fn expectWorkDeriveDispatchBound(
    service: anytype,
    allocator: std.mem.Allocator,
    program_document: []const u8,
    program_id: [32]u8,
    proposal: []const u8,
    archive_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const S = native.testing.state;
    const work_id: S.Digest = @splat(73);
    const parent = try service.submit(a, "work-derive-dispatch", .{ .program = .{ .derive = .{
        .ancestor = .{ .work = .{
            .expected = .{
                .work = try workspaceRef(a, .work, work_id),
                .execution_revision = 1,
                .control_revision = 1,
            },
            .realization_revision = 0,
        } },
        .program = try workspaceRef(a, .program, program_id),
        .proposal = .{ .json_text = .{ .bytes = proposal } },
    } } });
    const task = parent.receipt.task;
    var diagnostic: native.program_construction.Diagnostic = .{};
    _ = try service.workspaceBuild(a, "work-derive-guest", task, program_document, &diagnostic);
    var builder = source.Builder.init(allocator);
    defer builder.deinit();
    const module = try gcd(&builder);
    const entry = &builder.functions.items[@intCast(module.entry)];
    for (0..32) |_| entry.body = try builder.term(.{ .yield_then = entry.body.? });
    const document = try native.source_records.encode(
        a,
        builder.module(module.entry, module.failure),
    );
    const source_program = try service.workspaceBuild(
        a,
        "work-derive-source",
        task,
        document,
        &diagnostic,
    );
    try startDeriveDispatchWork(service, a, task, source_program, work_id);
    const before_request = try service.task(a, task);
    try std.testing.expect(before_request.value.current_occurrence == null);
    try std.testing.expectEqual(@as(u64, 0), before_request.value.execution_revision);
    const earlier = before_request.value.event_high;
    try observeDeriveDispatch(service, allocator, a, task, work_id, earlier, archive_path);
}

fn startDeriveDispatchWork(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    source_program: anytype,
    work_id: [32]u8,
) !void {
    {
        const WorkIdentity = struct {
            var assigned = false;
            fn random(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
                if (!assigned and buffer.len == 32) {
                    @memset(buffer, 73);
                    assigned = true;
                } else try std.testing.io.randomSecure(buffer);
            }
        };
        WorkIdentity.assigned = false;
        const original = service.io;
        defer service.io = original;
        var vtable = original.vtable.*;
        vtable.randomSecure = WorkIdentity.random;
        service.io.vtable = &vtable;
        const started = try service.workspaceStart(
            a,
            "work-derive-source-start",
            task,
            source_program.receipt.workspace.?,
            try contracts.encodeOwned(struct {
                u64,
                u64,
            }, a, .{ 1071, 462 }),
            .{},
        );
        try std.testing.expectEqualDeep(work_id, started.receipt.workspace.?);
    }
}

fn forgeDeriveDispatch(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    attempt_id: [32]u8,
    earlier: u64,
    archive_path: []const u8,
    input: native.testing.workspace_build.Input,
    saved: native.testing.state.Attempt,
    captured: native.testing.state.Capture,
) !void {
    const store = &service.namespace.store;
    var forged_input = input;
    forged_input.derive.basis.works.event_watermark = earlier;
    const forged_bytes = try contracts.encodeOwned(
        native.testing.workspace_build.Input,
        a,
        forged_input,
    );
    try store.begin();
    defer store.rollback();
    var forged_attempt = saved;
    forged_attempt.prepared = try store.putObject(forged_bytes);
    var forged_capture = captured;
    forged_capture.request = forged_attempt.prepared.?;
    try store.database.run(
        "DELETE FROM records WHERE kind='attempt' AND id=? AND task=?",
        &.{ .{ .blob = &attempt_id }, .{ .blob = &task } },
    );
    try store.createRecord(
        native.testing.state.Attempt,
        "attempt",
        attempt_id,
        task,
        forged_attempt,
    );
    try store.putRecord(native.testing.state.Capture, "capture", attempt_id, task, forged_capture);
    try service.namespace.commit("test.forge-work-derive-dispatch");
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspace(a, task));
    try std.testing.expectError(
        error.InvalidArchive,
        service.exportCheckpoint(
            a,
            task,
            try std.fmt.allocPrint(a, "{s}-forged", .{archive_path}),
        ),
    );
    return forgeDeriveDispatchEvents(
        service,
        a,
        task,
        attempt_id,
        earlier,
        archive_path,
        input,
        saved,
        captured,
        forged_attempt,
    );
}

fn observeDeriveDispatch(
    service: anytype,
    allocator: std.mem.Allocator,
    a: std.mem.Allocator,
    task: [16]u8,
    work_id: [32]u8,
    earlier: u64,
    archive_path: []const u8,
) !void {
    const store = &service.namespace.store;
    for (0..64) |_| {
        const step = try service.pump(a);
        if (step != .work) continue;
        try std.testing.expectEqual(.workspace_build, step.work.operation);
        try std.testing.expectEqualDeep(task, step.work.task);
        const attempt_id = step.work.attempt;
        const saved = (try contracts.decodeOwned(
            native.testing.state.Attempt,
            a,
            (try store.recordBytes(a, "attempt", attempt_id, task)).?,
        )).value;
        const input = (try contracts.decodeOwned(
            native.testing.workspace_build.Input,
            a,
            try store.object(a, saved.prepared.?, null),
        )).value;
        try std.testing.expect(input == .derive and input.derive.basis == .works);
        try std.testing.expect(input.derive.basis.works.event_watermark > earlier);
        try std.testing.expectEqual(
            earlier,
            input.derive.basis.works.works.items[0].?.work.event_watermark,
        );
        const worker = try native.testing.Worker.init(allocator, service.io);
        defer support.expectCleanup(worker.deinit(allocator));
        try worker.start(step.work, service.profile.authority, null);
        try advanceDeriveDispatchSource(service, a, task, work_id, worker, step);
        const captured = (try contracts.decodeOwned(
            native.testing.state.Capture,
            a,
            (try store.recordBytes(a, "capture", attempt_id, task)).?,
        )).value;
        const output = (try contracts.decodeOwned(
            native.testing.workspace_build.Output,
            a,
            try store.object(a, captured.response.?, null),
        )).value;
        try std.testing.expect(output == .derived);
        _ = try service.exportCheckpoint(a, task, archive_path);
        return forgeDeriveDispatch(
            service,
            a,
            task,
            attempt_id,
            earlier,
            archive_path,
            input,
            saved,
            captured,
        );
    }
    return error.MissingSemanticCapture;
}

fn forgeDeriveDispatchEvents(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    attempt_id: [32]u8,
    earlier: u64,
    archive_path: []const u8,
    input: native.testing.workspace_build.Input,
    saved: native.testing.state.Attempt,
    captured: native.testing.state.Capture,
    original_attempt: native.testing.state.Attempt,
) !void {
    const store = &service.namespace.store;
    const forged_attempt = original_attempt;
    var events: [2]native.testing.state.Event = undefined;
    const positions = [_]u64{ earlier + 1, input.derive.basis.works.event_watermark + 1 };
    for (positions, &events) |seq, *event| {
        var query = try store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? AND e.seq=?",
            &.{ .{ .blob = &task }, .{ .integer = @intCast(seq) } },
        );
        defer query.deinit();
        try std.testing.expect(try query.step() == .row);
        event.* = (try contracts.decodeOwned(
            native.testing.state.Event,
            a,
            try query.bytes(0),
        )).value;
    }
    try std.testing.expectEqual(.execution, events[0].kind);
    try std.testing.expectEqual(.workspace_read, events[1].kind);
    try std.testing.expect(events[0].seq < events[1].seq);
    try store.begin();
    for (events, 0..) |event, i| {
        var moved = events[1 - i];
        moved.seq = event.seq;
        moved.revision = event.revision;
        try store.database.run("DELETE FROM events WHERE task=? AND seq=?", &.{ .{
            .blob = &task,
        }, .{ .integer = @intCast(event.seq) } });
        try store.putEvent(moved);
    }
    try service.namespace.commit("test.move-work-derive-before-request");
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspace(a, task));
    try std.testing.expectError(
        error.InvalidArchive,
        service.exportCheckpoint(
            a,
            task,
            try std.fmt.allocPrint(a, "{s}-moved", .{archive_path}),
        ),
    );
    return forgeDeriveDispatchCheckpoint(
        service,
        a,
        task,
        attempt_id,
        archive_path,
        saved,
        captured,
        forged_attempt,
        events,
    );
}

fn forgeDeriveDispatchCheckpoint(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    attempt_id: [32]u8,
    archive_path: []const u8,
    saved: native.testing.state.Attempt,
    captured: native.testing.state.Capture,
    original_attempt: native.testing.state.Attempt,
    events: [2]native.testing.state.Event,
) !void {
    const store = &service.namespace.store;
    var forged_attempt = original_attempt;
    try store.begin();
    forged_attempt.dispatch_checkpoint = try store.objectReference(
        events[0].root_publication.?.before.checkpoint,
        null,
    );
    try store.database.run(
        "DELETE FROM records WHERE kind='attempt' AND id=? AND task=?",
        &.{ .{ .blob = &attempt_id }, .{ .blob = &task } },
    );
    try store.createRecord(
        native.testing.state.Attempt,
        "attempt",
        attempt_id,
        task,
        forged_attempt,
    );
    try service.namespace.commit("test.forge-work-derive-dispatch-checkpoint");
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspace(a, task));
    try std.testing.expectError(
        error.InvalidArchive,
        service.exportCheckpoint(
            a,
            task,
            try std.fmt.allocPrint(a, "{s}-checkpoint", .{archive_path}),
        ),
    );
    try store.begin();
    for (events) |event| {
        try store.database.run("DELETE FROM events WHERE task=? AND seq=?", &.{ .{
            .blob = &task,
        }, .{ .integer = @intCast(event.seq) } });
        try store.putEvent(event);
    }
    try store.database.run(
        "DELETE FROM records WHERE kind='attempt' AND id=? AND task=?",
        &.{ .{ .blob = &attempt_id }, .{ .blob = &task } },
    );
    try store.createRecord(native.testing.state.Attempt, "attempt", attempt_id, task, saved);
    try store.putRecord(native.testing.state.Capture, "capture", attempt_id, task, captured);
    try service.namespace.commit("test.restore-work-derive-dispatch");
    for (0..64) |_| {
        try std.testing.expect(try service.pump(a) != .work);
        const current = try service.task(a, task);
        if (!current.value.terminal()) continue;
        try std.testing.expectEqual(.completed, current.value.outcome_kind);
        try service.validateWorkspace(a, task);
        _ = try service.exportCheckpoint(
            a,
            task,
            try std.fmt.allocPrint(a, "{s}-completed", .{archive_path}),
        );
        return;
    }
    return error.UnsettledSemanticCapture;
}

fn captureSemanticSuccess(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    validation: bool,
) !native.testing.state.Capture {
    for (0..64) |_| {
        const step = try service.pump(a);
        if (step != .work) continue;
        try std.testing.expectEqual(.workspace_build, step.work.operation);
        try std.testing.expectEqualDeep(task, step.work.task);
        const worker = try native.testing.Worker.init(a, service.io);
        defer support.expectCleanup(worker.deinit(a));
        try worker.start(step.work, service.profile.authority, null);
        while (!worker.finished()) try service.io.sleep(.fromMilliseconds(1), .awake);
        try worker.join();
        try service.completeWork(a, step.work, worker.result.?);
        try worker.release();
        const store = &service.namespace.store;
        const bytes = (try store.recordBytes(a, "capture", step.work.attempt, task)).?;
        defer a.free(bytes);
        var captured = try contracts.decodeOwned(native.testing.state.Capture, a, bytes);
        defer captured.deinit();
        try std.testing.expect(captured.value.projection == null);
        try std.testing.expectEqual(.complete, captured.value.disposition);
        const response = try store.object(a, captured.value.response.?, null);
        defer a.free(response);
        var output = try contracts.decodeOwned(native.testing.workspace_build.Output, a, response);
        defer output.deinit();
        if (output.value == .rejected)
            std.debug.print("semantic capture rejected: {s}\n", .{
                output.value.rejected.code.bytes,
            });
        if (validation) {
            try std.testing.expect(output.value == .validation);
            if (output.value.validation.outcome != .validated)
                std.debug.print("semantic validation: {s}\n", .{
                    output.value.validation.code.bytes,
                });
            try std.testing.expectEqual(.validated, output.value.validation.outcome);
        } else try std.testing.expect(output.value == .derived);
        return captured.value;
    }
    return error.MissingSemanticCapture;
}

fn expectSemanticCaptureSettled(
    service: anytype,
    a: std.mem.Allocator,
    captured: native.testing.state.Capture,
    cancellation: bool,
) !contracts.Decoded(contracts.workspace.Reply) {
    const store = &service.namespace.store;
    var acquired = false;
    var consumed = false;
    var terminal = false;
    for (0..64) |_| {
        try std.testing.expect(try service.pump(a) != .work);
        const bytes = (try store.recordBytes(
            a,
            "occurrence",
            captured.occurrence,
            captured.task,
        )).?;
        defer a.free(bytes);
        var pending = try contracts.decodeOwned(native.testing.occurrence.Occurrence, a, bytes);
        defer pending.deinit();
        if (pending.value.state == .settled_reply) {
            try std.testing.expect(!consumed);
            if (!acquired and !cancellation) try expectSemanticActivationDenied(
                service,
                a,
                captured,
            );
            acquired = true;
            try std.testing.expectEqualDeep(
                captured.attempt,
                pending.value.state.settled_reply.attempt,
            );
        }
        if (pending.value.state == .admitted) {
            try std.testing.expect(acquired and pending.value.state.admitted == .reply);
            consumed = true;
        }
        var current = try service.task(a, captured.task);
        defer current.deinit();
        if (!current.value.terminal()) continue;
        try std.testing.expectEqual(
            @as(native.testing.state.Outcome, if (cancellation) .cancelled else .completed),
            current.value.outcome_kind,
        );
        if (cancellation) try std.testing.expect(current.value.cancellation_applied);
        terminal = true;
        break;
    }
    try std.testing.expect(acquired and consumed and terminal);
    const bytes = (try store.recordBytes(a, "capture", captured.attempt, captured.task)).?;
    defer a.free(bytes);
    var settled = try contracts.decodeOwned(native.testing.state.Capture, a, bytes);
    defer settled.deinit();
    var original = settled.value;
    original.projection = null;
    try std.testing.expectEqualDeep(captured, original);
    const bound = try store.object(a, settled.value.projection.?.reply, null);
    defer a.free(bound);
    var result = try data.invocation.decode(data.invocation.Result, a, bound);
    defer result.deinit();
    return contracts.decodeOwned(contracts.workspace.Reply, a, result.value.value);
}

fn expectSemanticActivationDenied(
    service: anytype,
    a: std.mem.Allocator,
    captured: native.testing.state.Capture,
) !void {
    var phase: []const u8 = "decode capture";
    errdefer std.debug.print("semantic activation failed at {s}\n", .{phase});
    const store = &service.namespace.store;
    const request = try store.object(a, captured.request, null);
    defer a.free(request);
    var input = try contracts.decodeOwned(native.testing.workspace_build.Input, a, request);
    defer input.deinit();
    try std.testing.expect(input.value == .validate);
    const selected = input.value.validate;
    phase = "fresh validation";
    const denied = try service.workspaceCommand(a, "revoked-validate", captured.task, .{
        .program = .{ .validate = .{
            .candidate = try workspaceRef(a, .candidate, selected.candidate_ref.digest),
        } },
    });
    const validation_denied = std.mem.indexOf(
        u8,
        denied.observation_json.bytes,
        "SemanticPolicyDenied",
    ) != null;
    if (!validation_denied)
        std.debug.print("revoked validation: {s}\n", .{denied.observation_json.bytes});
    try std.testing.expectEqual(.rejected, denied.disposition);
    try std.testing.expect(validation_denied);
    phase = "runtime input";
    var candidate = try service.workspaceCandidate(a, captured.task, selected.candidate_ref.digest);
    defer candidate.deinit();
    var program = try service.workspaceProgram(a, captured.task, selected.program);
    defer program.deinit();
    const input_json = try native.json.canonical(
        a,
        try native.values.toJson([2]u64, a, .{ 1071, 462 }),
    );
    defer a.free(input_json);
    phase = "runtime start";
    const start = try service.workspaceCommand(a, "revoked-runtime-start", captured.task, .{
        .work = .{ .start = .{
            .program = try workspaceRef(a, .program, selected.program),
            .input = .{ .inline_json = .{
                .schema = try workspaceRef(
                    a,
                    .schema,
                    program.value.description.input_schema.digest,
                ),
                .json_text = .{ .bytes = input_json },
            } },
            .policy = .{},
            .runtime = .{ .selected = try workspaceRef(
                a,
                .runtime,
                candidate.value.description.code.digest,
            ) },
        } },
    });
    const runtime_denied = std.mem.indexOf(
        u8,
        start.observation_json.bytes,
        "SemanticPolicyDenied",
    ) != null;
    if (!runtime_denied)
        std.debug.print("revoked runtime start: {s}\n", .{start.observation_json.bytes});
    try std.testing.expectEqual(.rejected, start.disposition);
    try std.testing.expect(runtime_denied);
}

fn expectSemanticFactsRetained(
    service: anytype,
    a: std.mem.Allocator,
    captured: native.testing.state.Capture,
    validation: bool,
) !void {
    const store = &service.namespace.store;
    var query = try store.database.prepare(
        "SELECT kind,id,body FROM records WHERE task=? AND kind IN " ++
            "('workspace_candidate','workspace_runtime','capture','attempt','o" ++
            "ccurrence')",
        &.{.{ .blob = &captured.task }},
    );
    defer query.deinit();
    const Record = struct { kind: []const u8, id: [32]u8, body: [32]u8 };
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(a);
    var candidates: usize = 0;
    var runtimes: usize = 0;
    while (try query.step() == .row) {
        const kind = try a.dupe(u8, try query.bytes(0));
        const id = (try query.bytes(1))[0..32].*;
        const body = (try query.bytes(2))[0..32].*;
        try records.append(a, .{ .kind = kind, .id = id, .body = body });
        candidates += @intFromBool(std.mem.eql(u8, kind, "workspace_candidate"));
        runtimes += @intFromBool(std.mem.eql(u8, kind, "workspace_runtime"));
    }
    try std.testing.expectEqual(@as(usize, 1), candidates);
    try std.testing.expectEqual(@as(usize, @intFromBool(validation)), runtimes);
    for (0..3) |_| try std.testing.expect(try service.pump(a) != .work);
    for (records.items) |record| {
        defer a.free(record.kind);
        var retained = try store.database.prepare(
            "SELECT body FROM records WHERE kind=? AND id=? AND task=?",
            &.{ .{ .text = record.kind }, .{ .blob = &record.id }, .{ .blob = &captured.task } },
        );
        defer retained.deinit();
        try std.testing.expectEqual(.row, try retained.step());
        try std.testing.expectEqualSlices(u8, &record.body, try retained.bytes(0));
    }
}
test "CTX-01 snapshot materialization retains omitted source for a broader evidence pivot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const protean = @import("protean");
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = ContextTypes.Input,
            .Result = ContextTypes.Output,
            .Failure = void,
            .application = ContextApplication,
        }),
    );
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "context-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const manifest = try support.fixtureManifest(a, image, admitted.identity(), "context-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "context-unit",
        .manifest = manifest,
    };
    var handlers = try native.Registry.init(a, &.{.{
        .identity = "workspace-context",
        .resource_role = "workspace",
        .kind = .workspace,
        .workspace = ContextApplication.authorize,
        .payload_schema = ContextApplication.payloadSchema,
        .resume_schema = ContextApplication.resultSchema,
    }});
    defer handlers.deinit();
    try snapshotContextEvidence(.{
        .a = a,
        .io = io,
        .application = &application,
        .assets = assets,
        .handlers = &handlers,
    });
}

fn snapshotContextEvidence(fixture: anytype) !void {
    const text = "ordinary rows agree\nrare exception: missing invoice\n";
    var file_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &file_digest, .{});
    const snapshot = try contracts.encodeOwned(
        contracts.RepositorySnapshot,
        fixture.a,
        .{ .version = 2, .excluded_entries = 3, .files = .{ .items = &.{.{ .path = .{
            .bytes = "evidence.txt",
        }, .sha256 = file_digest, .contents = .{ .bytes = text } }} } },
    );
    defer fixture.a.free(snapshot);
    var algorithm = source.Builder.init(fixture.a);
    defer algorithm.deinit();
    const gcd_module = try gcd(&algorithm);
    var gcd_program = try horos.source.lower(fixture.a, gcd_module);
    defer gcd_program.deinit();
    const component: data.component.Object = .{
        .program = gcd_program.program,
        .exports = &.{.{ .name = "apply", .reference = .{
            .kind = .function,
            .id = gcd_program.program.roots.entry,
        } }},
        .borrows = &.{.{ .function = gcd_program.program.roots.entry }},
    };
    const component_bytes = try fixture.a.alloc(u8, try data.component.encodedLength(component));
    defer fixture.a.free(component_bytes);
    _ = try data.component.encode(fixture.a, component, component_bytes);
    const catalog = try contracts.encodeOwned(
        contracts.tool_construction.Catalog,
        fixture.a,
        .{ .items = &.{.{ .id = .{ .bytes = "gcd" }, .object = .{ .bytes = component_bytes } }} },
    );
    defer fixture.a.free(catalog);
    try snapshotContextFrozenInput(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .text = text,
        .snapshot = snapshot,
        .gcd_module = gcd_module,
        .catalog = catalog,
    });
}

fn snapshotContextFrozenInput(fixture: anytype) !void {
    const compact_schema = try data.schema.encodeOwned(
        fixture.a,
        &.{ .{ .array = .{ .element = 1, .length = 1_000_000_000 } }, .unit },
        0,
    );
    defer fixture.a.free(compact_schema);
    const frozen_input = try contracts.encodeOwned(
        contracts.tool_construction.Input,
        fixture.a,
        .{ .schema = .{ .bytes = compact_schema }, .value = .{ .bytes = "" } },
    );
    defer fixture.a.free(frozen_input);
    var grants = [_]native.registry.Grant{.{
        .identity = "workspace-context",
        .resource_role = "workspace",
        .resource_identity = undefined,
    }};
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(42),
        .bytes = "context-test",
        .resources = &.{ fixture.snapshot, fixture.catalog, frozen_input },
        .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" },
    };
    grants[0].resource_identity = try profile.resourceIdentity(
        fixture.a,
        fixture.application.*.image_identity,
    );
    try snapshotContextOwner(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .text = fixture.text,
        .gcd_module = fixture.gcd_module,
        .profile = profile,
    });
}

fn snapshotContextOwner(fixture: anytype) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(fixture.io, &path_buffer);
    const path = try std.fmt.allocPrint(fixture.a, "{s}/state", .{path_buffer[0..length]});
    defer fixture.a.free(path);
    var namespace = try native.Namespace.open(fixture.a, fixture.io, path);
    var namespace_open = true;
    defer if (namespace_open) support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(ContextTypes).init(
        fixture.a,
        fixture.io,
        &namespace,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile,
    );
    var service_open = true;
    defer if (service_open) support.expectCleanup(service.close(fixture.a));
    var arena = std.heap.ArenaAllocator.init(fixture.a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try snapshotContextRun(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .text = fixture.text,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = &path_buffer,
        .length = length,
        .path = path,
        .namespace = &namespace,
        .namespace_open = &namespace_open,
        .service = &service,
        .service_open = &service_open,
        .scratch = scratch,
    });
}

fn snapshotContextRun(fixture: anytype) !void {
    const command: contracts.workspace.Command = .{
        .context = .{ .materialize = .{ .input = .{ .snapshot = .{
            .path = .{ .bytes = "evidence.txt" },
            .offset = 0,
            .maximum = 19,
        } }, .sources = .{ .items = &.{} } } },
    };
    const parent = try fixture.service.*.submit(fixture.scratch, "parent", command);
    for (0..32) |_| {
        const step = try fixture.service.*.pump(fixture.scratch);
        try std.testing.expect(step != .work);
        if (step == .idle or step == .waiting) break;
    }
    var finished = try fixture.service.*.task(fixture.a, parent.receipt.task);
    defer finished.deinit();
    try std.testing.expectEqual(.completed, finished.value.outcome_kind);
    const bytes = try fixture.namespace.*.store.object(fixture.a, finished.value.result.?, null);
    defer fixture.a.free(bytes);
    var reply = try contracts.decodeOwned(ContextTypes.Output, fixture.a, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(.observed, reply.value.disposition);
    var observation = try native.json.parse(fixture.a, reply.value.observation_json.bytes, .{});
    defer observation.deinit();
    const derivation = observation.value.object.get("derivation").?;
    try std.testing.expectEqualStrings("acquisition", derivation.object.get("kind").?.string);
    try std.testing.expect(!derivation.object.get("complete_file").?.bool);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            observation.value.object.get("preview").?.object.get("text").?.string,
            "rare exception",
        ) == null,
    );
    const source_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        fixture.scratch,
        observation.value.object.get("source").?,
    );
    const expansion = try fixture.service.*.workspaceCommand(
        fixture.scratch,
        "expand-source",
        parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = source_ref, .page = .{} } } },
    );
    var expanded = try native.json.parse(fixture.a, expansion.observation_json.bytes, .{});
    defer expanded.deinit();
    try std.testing.expectEqualStrings(fixture.text, expanded.value.object.get("text").?.string);
    try snapshotContextProvenance(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .path = fixture.path,
        .namespace = fixture.namespace,
        .namespace_open = fixture.namespace_open,
        .service = fixture.service,
        .service_open = fixture.service_open,
        .scratch = fixture.scratch,
        .command = command,
        .parent = parent,
        .observation = &observation,
        .source_ref = source_ref,
    });
}

fn snapshotContextProvenance(fixture: anytype) !void {
    const provenance_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        fixture.scratch,
        fixture.observation.*.value.object.get("provenance").?,
    );
    var poisoned: PoisonFreedAllocator = .{ .backing = fixture.scratch };
    const provenance_reply = try fixture.service.*.workspaceCommand(
        poisoned.allocator(),
        "expand-provenance",
        fixture.parent.receipt.task,
        .{ .context = .{ .expand = .{ .reference = provenance_ref, .page = .{} } } },
    );
    var provenance_page = try native.json.parse(
        fixture.a,
        provenance_reply.observation_json.bytes,
        .{},
    );
    defer provenance_page.deinit();
    var provenance = try native.json.parse(fixture.a, provenance_page.value.object.get(
        "text",
    ).?.string, .{});
    defer provenance.deinit();
    try std.testing.expectEqualStrings(
        "evidence.txt",
        provenance.value.object.get("acquisition").?.object.get("path").?.string,
    );
    // Mutation replies re-project the original operation receipt, including
    // acquisition provenance, even after the controller has completed.
    try fixture.service.*.validateWorkspace(fixture.scratch, fixture.parent.receipt.task);

    // The source and value routes expose the same compact frozen input. A
    // tiny source window must not allocate its billion logical JSON nodes.
    try snapshotContextFrozenSource(fixture);
}

fn snapshotContextFrozenSource(fixture: anytype) !void {
    const frozen_parent = try fixture.service.*.submit(
        fixture.scratch,
        "frozen-input-parent",
        .{ .context = .{ .materialize = .{ .input = .{ .authorized_input = .{
            .bytes = "compact",
        } }, .sources = .{ .items = &.{} } } } },
    );
    for (0..32) |_| {
        const step = try fixture.service.*.pump(fixture.scratch);
        try std.testing.expect(step != .work);
        if (step == .idle or step == .waiting) break;
    }
    var frozen_finished = try fixture.service.*.task(fixture.scratch, frozen_parent.receipt.task);
    defer frozen_finished.deinit();
    try std.testing.expectEqual(.completed, frozen_finished.value.outcome_kind);
    var frozen_reply = try contracts.decodeOwned(
        ContextTypes.Output,
        fixture.scratch,
        try fixture.namespace.*.store.object(fixture.scratch, frozen_finished.value.result.?, null),
    );
    defer frozen_reply.deinit();
    try std.testing.expectEqual(.observed, frozen_reply.value.disposition);
    var frozen_observation = try native.json.parse(
        fixture.scratch,
        frozen_reply.value.observation_json.bytes,
        .{},
    );
    defer frozen_observation.deinit();
    const frozen_source = try native.values.fromJson(
        contracts.workspace.Ref,
        fixture.scratch,
        frozen_observation.value.object.get("source").?,
    );
    try snapshotContextSourcePages(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .path = fixture.path,
        .namespace = fixture.namespace,
        .namespace_open = fixture.namespace_open,
        .service = fixture.service,
        .service_open = fixture.service_open,
        .scratch = fixture.scratch,
        .command = fixture.command,
        .source_ref = fixture.source_ref,
        .frozen_parent = frozen_parent,
        .frozen_source = frozen_source,
    });
}

fn snapshotContextSourcePages(fixture: anytype) !void {
    const page_buffer = try fixture.a.alloc(u8, 16 * 1024 * 1024);
    defer fixture.a.free(page_buffer);
    for ([_]u64{ 0, 2_999_999_998 }, [_][]const u8{ "[", "{}]" }) |offset, expected| {
        var bounded = std.heap.FixedBufferAllocator.init(page_buffer);
        const paged = try fixture.service.*.workspaceCommand(
            bounded.allocator(),
            "frozen-source-page",
            fixture.frozen_parent.receipt.task,
            .{ .context = .{ .expand = .{ .reference = fixture.frozen_source, .page = .{
                .offset = offset,
                .maximum = @intCast(expected.len),
            } } } },
        );
        try std.testing.expectEqual(.observed, paged.disposition);
        var parsed = try native.json.parse(fixture.scratch, paged.observation_json.bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expected, parsed.value.object.get("text").?.string);
        try std.testing.expectEqual(
            @as(u64, 3_000_000_001),
            try native.json.numberInteger(
                u64,
                parsed.value.object.get("total_bytes").?.number_string,
            ),
        );
    }
    try fixture.service.*.validateWorkspace(fixture.scratch, fixture.frozen_parent.receipt.task);
    try snapshotContextDeniedPreparation(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .path = fixture.path,
        .namespace = fixture.namespace,
        .namespace_open = fixture.namespace_open,
        .service = fixture.service,
        .service_open = fixture.service_open,
        .scratch = fixture.scratch,
        .command = fixture.command,
        .source_ref = fixture.source_ref,
        .frozen_parent = fixture.frozen_parent,
        .frozen_source = fixture.frozen_source,
        .page_buffer = page_buffer,
    });
}

fn snapshotContextDeniedPreparation(fixture: anytype) !void {
    const denied_derivation = try fixture.service.*.submit(
        fixture.scratch,
        "denied-semantic-preparation",
        .{
            .program = .{ .derive = .{
                .ancestor = .{ .controller = .{ .cut = .{ .epoch = 0, .execution_revision = 1 } } },
                .program = try workspaceRef(fixture.scratch, .program, @splat(0)),
                .proposal = .{ .json_text = .{ .bytes = "{}" } },
            } },
        },
    );
    var rejected_preparation = false;
    for (0..32) |_| {
        const step = try fixture.service.*.pump(fixture.scratch);
        try std.testing.expect(step != .work);
        var query = try fixture.namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='workspace_reply'",
            &.{.{ .blob = &denied_derivation.receipt.task }},
        );
        defer query.deinit();
        if (try query.step() != .row) continue;
        var evidence = try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            try query.bytes(0),
        );
        defer evidence.deinit();
        try std.testing.expect(evidence.value.evidence == .rejected);
        try std.testing.expectEqual(.preparation, evidence.value.evidence.rejected.stage);
        try std.testing.expectEqualStrings(
            "SemanticPolicyDenied",
            evidence.value.evidence.rejected.code.bytes,
        );
        rejected_preparation = true;
        break;
    }
    try std.testing.expect(rejected_preparation);
    try fixture.service.*.validateWorkspace(fixture.scratch, denied_derivation.receipt.task);
    for (0..32) |_| {
        const step = try fixture.service.*.pump(fixture.scratch);
        try std.testing.expect(step != .work);
        var current = try fixture.service.*.task(fixture.scratch, denied_derivation.receipt.task);
        defer current.deinit();
        if (current.value.terminal()) break;
    }
    var denied_finished = try fixture.service.*.task(
        fixture.scratch,
        denied_derivation.receipt.task,
    );
    defer denied_finished.deinit();
    try std.testing.expectEqual(.completed, denied_finished.value.outcome_kind);
    try std.testing.expect(denied_finished.value.execution_revision > 1);
    try fixture.service.*.validateWorkspace(fixture.scratch, denied_derivation.receipt.task);
    try snapshotContextTypedSource(fixture);
}

fn snapshotContextTypedSource(fixture: anytype) !void {
    // Runtime value JSON is not either construction-document grammar. Reject
    // the compact value before expanding its billion logical elements, while
    // retaining its independently tested source-page inspection above.
    for ([_]contracts.workspace.SourceKind{ .source_records, .component_recipe }) |kind| {
        var bounded = std.heap.FixedBufferAllocator.init(fixture.page_buffer);
        const rejected = fixture.service.*.workspaceCommand(
            bounded.allocator(),
            "reject-typed-source",
            fixture.frozen_parent.receipt.task,
            .{ .program = .{ .build = .{
                .source = .{ .reference = fixture.frozen_source },
                .source_kind = kind,
                .exposures = .{ .items = &.{} },
            } } },
        ) catch |err| {
            std.debug.print("typed source {s}: {s}\n", .{ @tagName(kind), @errorName(err) });
            return err;
        };
        try std.testing.expectEqual(.rejected, rejected.disposition);
        try std.testing.expect(rejected.program == null);
        const failure = (try native.json.parse(
            fixture.scratch,
            rejected.observation_json.bytes,
            .{},
        )).value;
        try std.testing.expectEqualStrings("SchemaMismatch", failure.object.get("error").?.string);
    }
    try fixture.service.*.validateWorkspace(fixture.scratch, fixture.frozen_parent.receipt.task);
    try snapshotContextMutations(fixture);
}

fn snapshotContextMutations(fixture: anytype) !void {
    // A settled mutation cannot be rewritten into a rejection while its
    // committed receipt survives. A genuine rejection has no such receipt.
    for ([_]bool{ false, true }) |reject| {
        try snapshotContextMutation(fixture, reject);
    }
    try snapshotContextReadRuntime(fixture);
}
fn snapshotContextMutation(fixture: anytype, reject: anytype) !void {
    var mutation = fixture.command;
    if (reject) mutation.context.materialize.input.snapshot.path.bytes = "missing.txt";
    const mutation_parent = try fixture.service.*.submit(
        fixture.scratch,
        if (reject) "rejected-mutation" else "accepted-mutation",
        mutation,
    );
    var observed: ?native.testing.occurrence.Occurrence = null;
    var evidence: native.workspace.ReplyObservation = undefined;
    for (0..32) |_| {
        _ = try fixture.service.*.pump(fixture.scratch);
        var query = try fixture.namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='workspace_reply'",
            &.{.{ .blob = &mutation_parent.receipt.task }},
        );
        defer query.deinit();
        if (try query.step() != .row) continue;
        evidence = (try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            try query.bytes(0),
        )).value;
        const pending_bytes = (try fixture.namespace.*.store.recordBytes(
            fixture.scratch,
            "occurrence",
            evidence.id,
            evidence.task,
        )).?;
        observed = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            fixture.scratch,
            pending_bytes,
        )).value;
        break;
    }
    const settled = observed orelse return error.MissingMutationObservation;
    try std.testing.expect(settled.state == .settled_reply);
    try fixture.service.*.validateWorkspace(fixture.scratch, mutation_parent.receipt.task);
    if (reject) {
        try std.testing.expect(evidence.evidence == .rejected);
        return;
    }
    try std.testing.expect(evidence.evidence == .admitted);
    try snapshotContextMutationSubstitution(fixture, mutation_parent, &evidence, settled);
}
fn snapshotContextMutationSubstitution(
    fixture: anytype,
    mutation_parent: anytype,
    evidence: anytype,
    settled: anytype,
) !void {
    const bound_original = try data.invocation.decode(
        data.invocation.Result,
        fixture.scratch,
        try fixture.namespace.*.store.object(
            fixture.scratch,
            try fixture.namespace.*.store.objectReference(
                settled.state.settled_reply.reply,
                null,
            ),
            null,
        ),
    );
    const original_reply = (try contracts.decodeOwned(
        contracts.workspace.Reply,
        fixture.scratch,
        bound_original.value.value,
    )).value;
    const original_json = (try native.json.parse(
        fixture.scratch,
        original_reply.observation_json.bytes,
        .{},
    )).value;
    const schema_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        fixture.scratch,
        original_json.object.get("schema").?,
    );
    const other = try fixture.service.*.workspaceCommand(
        fixture.scratch,
        "snapshot-substitute",
        mutation_parent.receipt.task,
        .{
            .context = .{
                .materialize = .{
                    .input = .{
                        .value = .{ .inline_json = .{ .schema = schema_ref, .json_text = .{
                            .bytes = "\"substitute\"",
                        } } },
                    },
                    .sources = .{ .items = &.{} },
                },
            },
        },
    );
    const other_json = (try native.json.parse(
        fixture.scratch,
        other.observation_json.bytes,
        .{},
    )).value;
    try expectContextOutputBound(
        &fixture.service.*,
        fixture.scratch,
        mutation_parent.receipt.task,
        &std.fmt.bytesToHex(settled.id, .lower),
        try native.values.fromJson(
            contracts.workspace.Ref,
            fixture.scratch,
            other_json.object.get("value").?,
        ),
        other,
    );
    try fixture.service.*.validateWorkspace(fixture.scratch, mutation_parent.receipt.task);
    try snapshotContextMutationRejection(fixture, mutation_parent, evidence, settled);
}
fn snapshotContextMutationRejection(
    fixture: anytype,
    mutation_parent: anytype,
    evidence: anytype,
    settled: anytype,
) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture.assets.manifest, &digest, .{});
    const mutation_index = try fixture.namespace.*.store.archiveIndex(
        fixture.scratch,
        mutation_parent.receipt.task,
        .{ .digest = digest, .bytes = fixture.assets.manifest.len },
    );
    var compiler_facts = try fixture.service.*.prepareWorkspaceValidation(settled.task);
    defer compiler_facts.deinit();
    try fixture.namespace.*.store.begin();
    evidence.*.evidence = .{ .rejected = .{ .stage = .operation, .code = .{
        .bytes = "Denied",
    } } };
    const forged = try fixture.namespace.*.store.putObject(
        try contracts.encodeOwned(native.workspace.ReplyObservation, fixture.scratch, evidence.*),
    );
    try fixture.namespace.*.store.database.run(
        "UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?",
        &.{ .{ .blob = &forged.digest }, .{ .blob = &settled.id } },
    );
    const failed_reply: contracts.workspace.Reply = .{
        .disposition = .rejected,
        .observation_json = .{ .bytes = "{\"error\":\"Denied\"}" },
    };
    const payload = try contracts.encodeOwned(
        contracts.workspace.Reply,
        fixture.scratch,
        failed_reply,
    );
    const bound = try data.invocation.encodeOwned(data.invocation.Result, fixture.scratch, .{
        .request_identity = settled.request,
        .value = payload,
    });
    var forged_occurrence = settled;
    forged_occurrence.state.settled_reply.reply = (try fixture.namespace.*.store.putObject(
        bound,
    )).digest;
    try fixture.namespace.*.store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        settled.id,
        settled.task,
        forged_occurrence,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        fixture.service.*.validateWorkspaceRecordsPrepared(
            fixture.scratch,
            settled.task,
            mutation_index.records.items,
            &compiler_facts,
        ),
    );
    fixture.namespace.*.store.rollback();
    try fixture.service.*.validateWorkspace(fixture.scratch, settled.task);
}

fn snapshotContextReadRuntime(fixture: anytype) !void {
    var read_runtime = try fixture.service.*.program.retainRuntime();
    defer read_runtime.deinit();
    var read_source = try kosmos.RuntimeCompiler.exportSource(fixture.a, &read_runtime);
    defer read_source.deinit();
    const read_controller: contracts.workspace.SemanticTarget = .{ .controller = .{
        .cut = .{ .epoch = 0, .execution_revision = 1 },
    } };
    const read_commands = [_]contracts.workspace.Command{
        .{ .program = .{ .describe = .{ .section = .source_records, .page = .{} } } },
        .{ .program = .{ .inspect = .{
            .target = .{
                .semantic_source = .{ .subject = read_controller, .section = .{ .summary = .{} } },
            },
            .page = .{ .maximum = 128 },
        } } },
        .{ .program = .{ .inspect = .{
            .target = .{ .semantic_source = .{ .subject = read_controller, .section = .{ .slice = .{
                .function = read_source.value.generic_pure_entries[0].function,
            } } } },
            .page = .{ .maximum = 128 },
        } } },
        .{ .program = .{ .describe = .{
            .section = .semantic_candidates,
            .page = .{ .maximum = 128 },
        } } },
        .{ .program = .{ .describe = .{
            .section = .semantic_candidates,
            .page = .{ .offset = 128, .maximum = 128 },
        } } },
    };
    const description_roots = [_][32]u8{@splat(23)};
    var description_archives: std.ArrayList(struct {
        task: native.testing.state.TaskId,
        path: []const u8,
    }) = .empty;
    defer description_archives.deinit(fixture.scratch);
    try snapshotContextReadCommands(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .path = fixture.path,
        .namespace = fixture.namespace,
        .namespace_open = fixture.namespace_open,
        .service = fixture.service,
        .service_open = fixture.service_open,
        .scratch = fixture.scratch,
        .command = fixture.command,
        .source_ref = fixture.source_ref,
        .read_source = &read_source,
        .read_commands = read_commands,
        .description_roots = &description_roots,
        .description_archives = &description_archives,
    });
}

fn snapshotContextReadCommands(fixture: anytype) !void {
    for (fixture.read_commands, 0..) |read_command, read_case| {
        try snapshotContextReadCommand(fixture, read_command, read_case);
    }
    try snapshotContextReadImports(fixture);
}
fn snapshotContextReadCommand(fixture: anytype, read_command: anytype, read_case: anytype) !void {
    var read_stage: []const u8 = "capture";
    errdefer std.debug.print("historical read {d}: {s}\n", .{ read_case, read_stage });
    const policy_description = read_command.program == .describe and
        read_command.program.describe.section == .semantic_candidates;
    const saved_policy = fixture.service.*.profile.semantic_construction;
    defer fixture.service.*.profile.semantic_construction = saved_policy;
    if (policy_description) {
        fixture.service.*.profile.semantic_construction = if (read_case % 2 == 0)
            .{
                .roots = fixture.description_roots,
                .checkers = &.{"recorded-checker"},
                .guard = true,
            }
        else
            null;
    }
    const operation = try std.fmt.allocPrint(
        fixture.scratch,
        "read-observation-{d}",
        .{read_case},
    );
    const read_parent = try fixture.service.*.submit(fixture.scratch, operation, read_command);
    var read_occurrence: ?native.testing.occurrence.Occurrence = null;
    for (0..32) |_| {
        _ = try fixture.service.*.pump(fixture.scratch);
        var query = try fixture.namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='occurrence'",
            &.{.{ .blob = &read_parent.receipt.task }},
        );
        defer query.deinit();
        if (try query.step() != .row) continue;
        var pending = try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            fixture.a,
            try query.bytes(0),
        );
        defer pending.deinit();
        if (pending.value.state == .settled_reply) {
            read_occurrence = pending.value;
            break;
        }
    }
    try snapshotContextReadPolicy(
        fixture,
        read_command,
        read_case,
        &read_stage,
        policy_description,
        read_parent,
        &read_occurrence,
    );
}
fn snapshotContextReadPolicy(
    fixture: anytype,
    read_command: anytype,
    read_case: anytype,
    read_stage: anytype,
    policy_description: anytype,
    read_parent: anytype,
    read_occurrence: anytype,
) !void {
    const original = read_occurrence.* orelse return error.MissingReadObservation;
    if (policy_description) {
        fixture.service.*.profile.semantic_construction = if (read_case % 2 == 0)
            null
        else
            .{ .roots = fixture.description_roots, .checkers = &.{"new-checker"} };
        const fresh = try fixture.service.*.workspaceCommand(
            fixture.scratch,
            "current-semantic-description",
            original.task,
            read_command,
        );
        const bound = try data.invocation.decode(
            data.invocation.Result,
            fixture.scratch,
            try fixture.namespace.*.store.object(
                fixture.scratch,
                try fixture.namespace.*.store.objectReference(
                    original.state.settled_reply.reply,
                    null,
                ),
                null,
            ),
        );
        const retained = try contracts.decodeOwned(
            contracts.workspace.Reply,
            fixture.scratch,
            bound.value.value,
        );
        try std.testing.expect(
            !std.mem.eql(
                u8,
                retained.value.observation_json.bytes,
                fresh.observation_json.bytes,
            ),
        );
    }
    try snapshotContextReadEvidence(
        fixture,
        read_case,
        read_stage,
        policy_description,
        read_parent,
        original,
    );
}
fn snapshotContextReadEvidence(
    fixture: anytype,
    read_case: anytype,
    read_stage: anytype,
    policy_description: anytype,
    read_parent: anytype,
    original: anytype,
) !void {
    read_stage.* = "validate retained reply";
    try fixture.service.*.validateWorkspace(fixture.scratch, read_parent.receipt.task);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture.assets.manifest, &manifest_digest, .{});
    const index = try fixture.namespace.*.store.archiveIndex(
        fixture.scratch,
        read_parent.receipt.task,
        .{ .digest = manifest_digest, .bytes = fixture.assets.manifest.len },
    );
    var read_compiler_facts = try fixture.service.*.prepareWorkspaceValidation(
        read_parent.receipt.task,
    );
    defer read_compiler_facts.deinit();
    const observed_bytes = (try fixture.namespace.*.store.recordBytes(
        fixture.scratch,
        "workspace_reply",
        original.id,
        original.task,
    )).?;
    const observed_reply = (try contracts.decodeOwned(
        native.workspace.ReplyObservation,
        fixture.scratch,
        observed_bytes,
    )).value;
    try std.testing.expect(observed_reply.evidence == .read);
    try fixture.namespace.*.store.begin();
    try fixture.service.*.validateWorkspaceRecordsPrepared(
        fixture.scratch,
        original.task,
        index.records.items,
        &read_compiler_facts,
    );
    fixture.namespace.*.store.rollback();
    for (0..2) |variant| {
        try snapshotContextReadForgery(fixture, variant, original, index, &read_compiler_facts);
    }
    if (policy_description) {
        read_stage.* = "export retained description";
        const archive_path = try std.fmt.allocPrint(
            fixture.scratch,
            "{s}/semantic-description-{d}.par",
            .{ fixture.path_buffer.*[0..fixture.length], read_case },
        );
        _ = try fixture.service.*.exportCheckpoint(
            fixture.scratch,
            original.task,
            archive_path,
        );
        try fixture.description_archives.*.append(fixture.scratch, .{
            .task = original.task,
            .path = archive_path,
        });
    }
}
fn snapshotContextReadForgery(
    fixture: anytype,
    variant: anytype,
    original: anytype,
    index: anytype,
    read_compiler_facts: anytype,
) !void {
    try fixture.namespace.*.store.begin();
    const fake: contracts.workspace.Reply = .{
        .disposition = .observed,
        .observation_json = .{
            .bytes = if (variant == 0) "{\"text\":\"fabricated schema\"}" else "{}",
        },
        .selected_view = if (variant == 1) .{ .kind = .view, .id = .{
            .bytes = &(@as([64]u8, @splat('0'))),
        } } else null,
    };
    const payload = try contracts.encodeOwned(
        contracts.workspace.Reply,
        fixture.scratch,
        fake,
    );
    const bound = try data.invocation.encodeOwned(
        data.invocation.Result,
        fixture.scratch,
        .{ .request_identity = original.request, .value = payload },
    );
    var forged_reply = original;
    forged_reply.state.settled_reply.reply = (try fixture.namespace.*.store.putObject(
        bound,
    )).digest;
    try fixture.namespace.*.store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        original.id,
        original.task,
        forged_reply,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        fixture.service.*.validateWorkspaceRecordsPrepared(
            fixture.scratch,
            original.task,
            index.records.items,
            &read_compiler_facts.*,
        ),
    );
    fixture.namespace.*.store.rollback();
}

fn snapshotContextReadImports(fixture: anytype) !void {
    try fixture.service.*.close(fixture.a);
    fixture.service_open.* = false;
    try fixture.namespace.*.close();
    fixture.namespace_open.* = false;
    for (fixture.description_archives.*.items, 0..) |archived, index| {
        const imported_path = try std.fmt.allocPrint(
            fixture.scratch,
            "{s}/semantic-description-{d}",
            .{ fixture.path_buffer.*[0..fixture.length], index },
        );
        var imported_namespace = try native.Namespace.open(fixture.a, fixture.io, imported_path);
        defer support.expectCleanup(imported_namespace.close());
        var imported = try native.tasks.Service(ContextTypes).init(
            fixture.a,
            fixture.io,
            &imported_namespace,
            fixture.assets,
            &fixture.application.*,
            fixture.handlers.*,
            fixture.profile,
        );
        defer support.expectCleanup(imported.close(fixture.a));
        const receipt = try imported.importCheckpoint(
            fixture.scratch,
            "import-semantic-description",
            archived.path,
        );
        try std.testing.expectEqualDeep(archived.task, receipt.receipt.task);
        try imported.validateWorkspace(fixture.scratch, archived.task);
    }
    fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    fixture.namespace_open.* = true;
    fixture.service.* = try native.tasks.Service(ContextTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile,
    );
    fixture.service_open.* = true;
    try snapshotContextBuild(fixture);
}

fn snapshotContextBuild(fixture: anytype) !void {
    const other = try fixture.service.*.submit(fixture.scratch, "other-task", fixture.command);
    const forbidden = try fixture.service.*.workspaceCommand(
        fixture.scratch,
        "cross-task-source",
        other.receipt.task,
        .{ .context = .{ .expand = .{ .reference = fixture.source_ref, .page = .{} } } },
    );
    try std.testing.expectEqual(.rejected, forbidden.disposition);
    const recipe = "{\"instances\":[{\"key\":\"algorithm\",\"component_id\":\"gcd\"}]" ++
        ",\"bindings\":[],\"entry\":{\"instance\":\"algorithm\",\"symbol\"" ++
        ":\"apply\"}}";
    const build_parent = try fixture.service.*.submit(
        fixture.scratch,
        "component-parent",
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = recipe,
        } }, .source_kind = .component_recipe, .exposures = .{ .items = &.{} } } } },
    );
    try snapshotContextBuildProgress(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .namespace = fixture.namespace,
        .service = fixture.service,
        .scratch = fixture.scratch,
        .command = fixture.command,
        .read_source = fixture.read_source,
        .build_parent = build_parent,
    });
}

fn snapshotContextBuildProgress(fixture: anytype) !void {
    var built_id: ?[32]u8 = null;
    var compilation_seen = false;
    for (0..32) |_| {
        const step = try fixture.service.*.pump(fixture.scratch);
        if (step == .work) {
            try snapshotContextBuildCapture(fixture, step, &compilation_seen);
        }
        var query = try fixture.namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='workspace_program'",
            &.{.{ .blob = &fixture.build_parent.receipt.task }},
        );
        defer query.deinit();
        if (try query.step() == .row) {
            var built = try contracts.decodeOwned(
                native.workspace.Program,
                fixture.a,
                try query.bytes(0),
            );
            defer built.deinit();
            try std.testing.expectEqual(.component_recipe, built.value.description.source_kind);
            built_id = built.value.artifact.digest;
            break;
        }
    }
    try std.testing.expect(compilation_seen);
    try std.testing.expect(built_id != null);
    try expectProgramProgressIsDerived(
        &fixture.service.*,
        fixture.scratch,
        fixture.build_parent.receipt.task,
    );
    try snapshotContextBuildResult(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .gcd_module = fixture.gcd_module,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .namespace = fixture.namespace,
        .service = fixture.service,
        .scratch = fixture.scratch,
        .command = fixture.command,
        .read_source = fixture.read_source,
        .build_parent = fixture.build_parent,
        .built_id = &built_id,
    });
}
fn snapshotContextBuildCapture(fixture: anytype, step: anytype, compilation_seen: anytype) !void {
    try std.testing.expectEqual(.workspace_build, step.work.operation);
    try std.testing.expect(!compilation_seen.*);
    compilation_seen.* = true;
    const worker = try native.testing.Worker.init(fixture.a, fixture.io);
    defer support.expectCleanup(worker.deinit(fixture.a));
    try worker.start(step.work, fixture.profile.authority, null);
    // Control admission remains available while source compilation owns
    // the worker, and does not invalidate the in-flight attempt.
    var compiling = try fixture.service.*.task(
        fixture.a,
        fixture.build_parent.receipt.task,
    );
    defer compiling.deinit();
    try std.testing.expect(compiling.value.current_occurrence != null);
    _ = try fixture.service.*.submit(
        fixture.scratch,
        "during-compilation",
        fixture.command,
    );
    while (!worker.finished()) try fixture.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    try fixture.service.*.completeWork(fixture.scratch, step.work, worker.result.?);
    try worker.release();
    try expectBuildCaptureOutputBound(
        &fixture.service.*,
        fixture.scratch,
        fixture.build_parent.receipt.task,
        step.work.attempt,
        try std.fmt.allocPrint(
            fixture.scratch,
            "{s}/build-capture.par",
            .{fixture.path_buffer.*[0..fixture.length]},
        ),
    );
    // A captured build survives owner replacement without a second
    // compilation dispatch; explicit resume only interprets it.
    try snapshotContextBuildRestore(fixture);
}
fn snapshotContextBuildRestore(fixture: anytype) !void {
    try fixture.service.*.close(fixture.a);
    fixture.service.* = try native.tasks.Service(ContextTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile,
    );
    try std.testing.expectEqual(.idle, try fixture.service.*.pump(fixture.scratch));
    var captured = try fixture.service.*.task(fixture.a, fixture.build_parent.receipt.task);
    defer captured.deinit();
    _ = try fixture.service.*.resumeTask(
        fixture.scratch,
        "resume-build-capture",
        fixture.build_parent.receipt.task,
        captured.value.revision,
    );
}

fn snapshotContextBuildResult(fixture: anytype) !void {
    const input = try contracts.encodeOwned(struct { u64, u64 }, fixture.a, .{ 1071, 462 });
    defer fixture.a.free(input);
    const started = try fixture.service.*.workspaceStart(
        fixture.scratch,
        "component-start",
        fixture.build_parent.receipt.task,
        fixture.built_id.*.?,
        input,
        .{},
    );
    var child = try fixture.service.*.workspaceWork(
        fixture.a,
        fixture.build_parent.receipt.task,
        started.receipt.workspace.?,
    );
    defer child.deinit();
    try std.testing.expectEqual(.completed, child.value.outcome_kind);
    const result_bytes = try fixture.namespace.*.store.object(
        fixture.a,
        child.value.result.?,
        null,
    );
    defer fixture.a.free(result_bytes);
    var result = try contracts.decodeOwned(u64, fixture.a, result_bytes);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 21), result.value);
    const archive_path = try std.fmt.allocPrint(
        fixture.a,
        "{s}/build.par",
        .{fixture.path_buffer.*[0..fixture.length]},
    );
    defer fixture.a.free(archive_path);
    _ = try fixture.service.*.exportCheckpoint(
        fixture.scratch,
        fixture.build_parent.receipt.task,
        archive_path,
    );
    try snapshotContextDerive(fixture);
}

fn snapshotContextDerive(fixture: anytype) !void {
    const document = try native.source_records.encode(fixture.scratch, fixture.gcd_module);
    const seed = try fixture.service.*.submit(fixture.scratch, "derive-seed", fixture.command);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const seed_program = try fixture.service.*.workspaceBuild(
        fixture.scratch,
        "derive-seed-program",
        seed.receipt.task,
        document,
        &diagnostic,
    );
    var packaged_runtime = try fixture.service.*.program.retainRuntime();
    defer packaged_runtime.deinit();
    const roots = [_][32]u8{kosmos.RuntimeCompiler.approvedRootIdentity(&packaged_runtime)};
    const previous_policy = fixture.service.*.profile.semantic_construction;
    defer fixture.service.*.profile.semantic_construction = previous_policy;
    fixture.service.*.profile.semantic_construction = .{ .roots = &roots, .checkers = &.{
        kosmos.RuntimeCompiler.checker_identity,
    } };
    const derive_parent = try fixture.service.*.submit(
        fixture.scratch,
        "derive-parent",
        .{ .program = .{ .derive = .{
            .ancestor = .{ .controller = .{ .cut = .{ .epoch = 0, .execution_revision = 1 } } },
            .program = try workspaceRef(
                fixture.scratch,
                .program,
                seed_program.receipt.workspace.?,
            ),
            .proposal = .{ .json_text = .{ .bytes = "{}" } },
        } } },
    );
    const derive_program = try fixture.service.*.workspaceBuild(
        fixture.scratch,
        "derive-parent-program",
        derive_parent.receipt.task,
        document,
        &diagnostic,
    );
    try std.testing.expectEqualDeep(
        seed_program.receipt.workspace,
        derive_program.receipt.workspace,
    );
    try snapshotContextDeriveProgress(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .namespace = fixture.namespace,
        .service = fixture.service,
        .scratch = fixture.scratch,
        .read_source = fixture.read_source,
        .document = document,
        .diagnostic = &diagnostic,
        .seed_program = seed_program,
        .roots = roots,
        .derive_parent = derive_parent,
    });
}

fn snapshotContextDeriveProgress(fixture: anytype) !void {
    var derivation_seen = false;
    for (0..64) |_| {
        const step = try fixture.service.*.pump(fixture.scratch);
        if (step == .work) {
            try std.testing.expectEqual(.workspace_build, step.work.operation);
            try std.testing.expectEqualDeep(fixture.derive_parent.receipt.task, step.work.task);
            try std.testing.expect(!derivation_seen);
            derivation_seen = true;
            const worker = try native.testing.Worker.init(fixture.a, fixture.io);
            defer support.expectCleanup(worker.deinit(fixture.a));
            try worker.start(step.work, fixture.profile.authority, null);
            while (!worker.finished()) try fixture.io.sleep(.fromMilliseconds(1), .awake);
            try worker.join();
            try fixture.service.*.completeWork(fixture.scratch, step.work, worker.result.?);
            try worker.release();
            try expectDeriveCaptureOwnerBound(
                &fixture.service.*,
                fixture.scratch,
                fixture.derive_parent.receipt.task,
                step.work.attempt,
                try std.fmt.allocPrint(fixture.scratch, "{s}/derive-capture.par", .{
                    fixture.path_buffer.*[0..fixture.length],
                }),
            );
            const active_profile = fixture.service.*.profile;
            try fixture.service.*.close(fixture.a);
            fixture.service.* = try native.tasks.Service(ContextTypes).init(
                fixture.a,
                fixture.io,
                &fixture.namespace.*,
                fixture.assets,
                &fixture.application.*,
                fixture.handlers.*,
                active_profile,
            );
            var captured = try fixture.service.*.task(
                fixture.a,
                fixture.derive_parent.receipt.task,
            );
            defer captured.deinit();
            _ = try fixture.service.*.resumeTask(
                fixture.scratch,
                "resume-derive-capture",
                fixture.derive_parent.receipt.task,
                captured.value.revision,
            );
        }
        var derived = try fixture.service.*.task(fixture.a, fixture.derive_parent.receipt.task);
        defer derived.deinit();
        if (derived.value.terminal()) {
            try std.testing.expectEqual(.completed, derived.value.outcome_kind);
            break;
        }
    }
    try std.testing.expect(derivation_seen);
    try snapshotContextDeriveSuccess(fixture);
}

fn snapshotContextDeriveSuccess(fixture: anytype) !void {
    var derived = try fixture.service.*.task(fixture.a, fixture.derive_parent.receipt.task);
    defer derived.deinit();
    try std.testing.expectEqual(.completed, derived.value.outcome_kind);
    try fixture.service.*.validateWorkspace(fixture.scratch, fixture.derive_parent.receipt.task);
    const proposal = try native.source_records.encodeRecord(
        native.program_construction.CandidateDocument,
        fixture.scratch,
        .{ .version = 1, .proposal = .{
            .selected = fixture.read_source.*.value.selected.module,
            .steps = &.{},
        } },
    );
    try expectWorkDeriveDispatchBound(
        &fixture.service.*,
        fixture.a,
        fixture.document,
        fixture.seed_program.receipt.workspace.?,
        proposal,
        try std.fmt.allocPrint(
            fixture.scratch,
            "{s}/work-derive-dispatch.par",
            .{fixture.path_buffer.*[0..fixture.length]},
        ),
    );
    const successful_derive: contracts.workspace.Command = .{ .program = .{ .derive = .{
        .ancestor = .{ .controller = .{ .cut = .{ .epoch = 0, .execution_revision = 1 } } },
        .program = try workspaceRef(
            fixture.scratch,
            .program,
            fixture.seed_program.receipt.workspace.?,
        ),
        .proposal = .{ .json_text = .{ .bytes = proposal } },
    } } };
    const approved_policy = fixture.service.*.profile.semantic_construction;
    var candidate_ref: ?contracts.workspace.Ref = null;
    try snapshotContextRetainedCaptures(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .profile = fixture.profile,
        .namespace = fixture.namespace,
        .service = fixture.service,
        .scratch = fixture.scratch,
        .document = fixture.document,
        .diagnostic = fixture.diagnostic,
        .roots = fixture.roots,
        .successful_derive = successful_derive,
        .approved_policy = approved_policy,
        .candidate_ref = &candidate_ref,
    });
}

fn snapshotContextRetainedCaptures(fixture: anytype) !void {
    for ([_]bool{ false, true }) |validation| {
        try snapshotContextRetainedCapture(fixture, validation);
    }
}
fn snapshotContextRetainedCapture(fixture: anytype, validation: anytype) !void {
    const label = if (validation) "retained-validation" else "cancelled-derivation";
    var phase: []const u8 = "prepare";
    errdefer std.debug.print("semantic {s} failed at {s}\n", .{ label, phase });
    fixture.service.*.profile.semantic_construction = fixture.approved_policy;
    const selected_command: contracts.workspace.Command = if (validation)
        .{ .program = .{ .validate = .{ .candidate = fixture.candidate_ref.*.? } } }
    else
        fixture.successful_derive;
    const captured_parent = try fixture.service.*.submit(
        fixture.scratch,
        label,
        selected_command,
    );
    const task_id = captured_parent.receipt.task;
    _ = try fixture.service.*.workspaceBuild(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "{s}-program", .{label}),
        task_id,
        fixture.document,
        &fixture.diagnostic.*,
    );
    if (validation) {
        var initial = try fixture.service.*.task(fixture.scratch, task_id);
        defer initial.deinit();
        var preparation = fixture.successful_derive;
        preparation.program.derive.ancestor.controller.cut = .{
            .epoch = initial.value.controller_epoch,
            .execution_revision = initial.value.execution_revision,
        };
        const prepared = try fixture.service.*.workspaceCommand(
            fixture.scratch,
            "validation-candidate",
            task_id,
            preparation,
        );
        if (prepared.disposition != .observed)
            std.debug.print("validation candidate: {s}\n", .{prepared.observation_json.bytes});
        try std.testing.expectEqual(.observed, prepared.disposition);
        try std.testing.expectEqualStrings(
            fixture.candidate_ref.*.?.id.bytes,
            prepared.evidence.?.id.bytes,
        );
    }
    try snapshotContextRetainedAcquisition(fixture, validation, label, &phase, task_id);
}
fn snapshotContextRetainedAcquisition(
    fixture: anytype,
    validation: anytype,
    label: anytype,
    phase: anytype,
    task_id: anytype,
) !void {
    phase.* = "capture";
    const captured = try captureSemanticSuccess(
        &fixture.service.*,
        fixture.a,
        task_id,
        validation,
    );
    const attempt_bytes = (try fixture.namespace.*.store.recordBytes(
        fixture.scratch,
        "attempt",
        captured.attempt,
        task_id,
    )).?;
    var attempt = try contracts.decodeOwned(
        native.testing.state.Attempt,
        fixture.scratch,
        attempt_bytes,
    );
    defer attempt.deinit();
    const frozen_profile = try fixture.namespace.*.store.object(
        fixture.scratch,
        attempt.value.profile,
        null,
    );
    try std.testing.expectEqualStrings(fixture.profile.bytes, frozen_profile);
    var revoked = fixture.service.*.profile;
    revoked.semantic_construction = if (validation)
        .{ .roots = &fixture.roots, .checkers = &.{} }
    else
        .{ .roots = &.{}, .checkers = &.{kosmos.RuntimeCompiler.checker_identity} };
    phase.* = "reopen captured";
    try fixture.service.*.close(fixture.a);
    fixture.service.* = try native.tasks.Service(ContextTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        revoked,
    );
    try snapshotContextRetainedResumption(
        fixture,
        validation,
        label,
        phase,
        task_id,
        captured,
        attempt_bytes,
        &attempt,
        frozen_profile,
        &revoked,
    );
}
fn snapshotContextRetainedResumption(
    fixture: anytype,
    validation: anytype,
    label: anytype,
    phase: anytype,
    task_id: anytype,
    captured: anytype,
    attempt_bytes: anytype,
    attempt: anytype,
    frozen_profile: anytype,
    revoked: anytype,
) !void {
    try std.testing.expectEqualStrings(frozen_profile, fixture.service.*.profile.bytes);
    try std.testing.expectEqualSlices(
        u8,
        attempt_bytes,
        (try fixture.namespace.*.store.recordBytes(
            fixture.scratch,
            "attempt",
            captured.attempt,
            task_id,
        )).?,
    );
    try std.testing.expectEqual(.idle, try fixture.service.*.pump(fixture.scratch));
    var retained = try fixture.service.*.task(fixture.scratch, task_id);
    defer retained.deinit();
    try std.testing.expectEqualDeep(attempt.*.value.profile, retained.value.profile);
    phase.* = "resume or cancel";
    if (validation) {
        _ = try fixture.service.*.resumeTask(
            fixture.scratch,
            "resume-retained-validation",
            task_id,
            retained.value.revision,
        );
    } else {
        var denied_command = fixture.successful_derive;
        denied_command.program.derive.ancestor.controller.cut.execution_revision =
            retained.value.execution_revision;
        const denied = try fixture.service.*.workspaceCommand(
            fixture.scratch,
            "revoked-derive",
            task_id,
            denied_command,
        );
        try std.testing.expectEqual(.rejected, denied.disposition);
        try std.testing.expect(
            std.mem.indexOf(u8, denied.observation_json.bytes, "SemanticPolicyDenied") != null,
        );
        _ = try fixture.service.*.requestCancel(
            fixture.scratch,
            "cancel-retained-derivation",
            task_id,
            "settle compiler capture before cancellation",
        );
    }
    try snapshotContextRetainedSettlement(
        fixture,
        validation,
        label,
        phase,
        task_id,
        captured,
        revoked,
    );
}
fn snapshotContextRetainedSettlement(
    fixture: anytype,
    validation: anytype,
    label: anytype,
    phase: anytype,
    task_id: anytype,
    captured: anytype,
    revoked: anytype,
) !void {
    phase.* = "settle";
    var settled = expectSemanticCaptureSettled(
        &fixture.service.*,
        fixture.scratch,
        captured,
        !validation,
    ) catch |err| {
        std.debug.print("semantic settlement: {s}\n", .{@errorName(err)});
        return err;
    };
    defer settled.deinit();
    if (settled.value.disposition != .admitted)
        std.debug.print("{s}: {s}\n", .{ label, settled.value.observation_json.bytes });
    try std.testing.expectEqual(.admitted, settled.value.disposition);
    if (validation) {
        var observed = try native.json.parse(
            fixture.scratch,
            settled.value.observation_json.bytes,
            .{},
        );
        defer observed.deinit();
        try std.testing.expect(observed.value.object.get("runtime_authority").?.bool);
        try std.testing.expectEqualStrings(
            "validated",
            observed.value.object.get("validation").?.string,
        );
    } else {
        fixture.candidate_ref.* = settled.value.evidence.?;
        fixture.candidate_ref.*.?.id.bytes = try fixture.scratch.dupe(
            u8,
            fixture.candidate_ref.*.?.id.bytes,
        );
    }
    phase.* = "retain facts";
    try expectSemanticFactsRetained(&fixture.service.*, fixture.scratch, captured, validation);
    try fixture.service.*.close(fixture.a);
    fixture.service.* = try native.tasks.Service(ContextTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        revoked.*,
    );
    try expectSemanticFactsRetained(&fixture.service.*, fixture.scratch, captured, validation);
    phase.* = "canonical validation";
    fixture.service.*.profile.semantic_construction = fixture.approved_policy;
    try fixture.service.*.validateWorkspace(fixture.scratch, task_id);
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
        const inbox = try interop.operationId(
            c.author,
            try @import("protean").inbox.Profile(WaitTypes.Message).declare(c),
        );
        const workspace = try interop.operationId(
            c.author,
            try c.external(
                "workspace-wait",
                try c.schema(contracts.workspace.Command),
                try c.schema(WaitTypes.Output),
                .read,
            ),
        );
        const inbox_schema = b.effects.items[@intCast(inbox)].result;
        const message_schema = b.schemas.items[@intCast(inbox_schema)].sum[1];
        const message_fields = b.schemas.items[@intCast(message_schema)].product;
        const entry = try b.declare(&.{unit}, output, &.{ inbox, workspace }, &.{});
        return emitWaitBody(
            b,
            unit,
            output,
            command,
            work_command,
            inbox,
            workspace,
            inbox_schema,
            message_schema,
            entry,
            message_fields[0],
            message_fields[1],
        );
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(contracts.workspace.Command, ctx.allocator, bytes);
        defer command.deinit();
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{
            .command = command.value,
        });
    }
    fn schema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(contracts.workspace.Command, a);
    }
    fn result(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(WaitTypes.Output, a);
    }
};
test "AUT-07 OWN-11 authored wait wakes for messages or selected work without a worker" {
    const a = std.testing.allocator;
    const protean = @import("protean");
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = void,
            .Result = WaitTypes.Output,
            .Failure = void,
            .application = WaitApplication,
        }),
    );
    defer compiled.deinit();
    var fixture: AuthoredWaitFixture = .{};
    defer fixture.deinit();
    try fixture.initImage(&compiled);
    try fixture.initHandlers();
    try fixture.initProfile();
    try fixture.initOwner();
    try fixture.initSource();
    for (std.enums.values(WaitScenario), 0..) |scenario, index| {
        var selected: AuthoredWaitCase = .{
            .fixture = &fixture,
            .scenario = scenario,
            .index = index,
        };
        defer selected.deinit();
        try selected.run();
    }
}

const WaitScenario = enum {
    imported_message,
    owned_message,
    selected_event,
    resumed_child,
    orderly_resumed_child,
    resumed_explicit_park,
    reopened_control,
    incompatible_wait,
};

const AuthoredWaitFixture = struct {
    a: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    image: []u8 = undefined,
    admitted: *data.program_image.Admitted = undefined,
    application: native.discovery.Application = undefined,
    manifest: []u8 = undefined,
    assets: native.discovery.Assets = undefined,
    handlers: native.Registry = undefined,
    grants: [2]native.registry.Grant = undefined,
    profile: native.tasks.Profile = undefined,
    temp: std.testing.TmpDir = undefined,
    path_buffer: [4096]u8 = undefined,
    length: usize = undefined,
    path: []u8 = undefined,
    namespace: native.Namespace = undefined,
    namespace_open: bool = false,
    service: native.tasks.Service(WaitTypes) = undefined,
    service_open: bool = false,
    arena: std.heap.ArenaAllocator = undefined,
    scratch: std.mem.Allocator = undefined,
    builder: source.Builder = undefined,
    document: []u8 = undefined,
    input: []u8 = undefined,
    image_live: bool = false,
    admitted_live: bool = false,
    application_live: bool = false,
    manifest_live: bool = false,
    handlers_live: bool = false,
    temp_live: bool = false,
    path_live: bool = false,
    arena_live: bool = false,
    builder_live: bool = false,
    document_live: bool = false,
    input_live: bool = false,
    fn initImage(self: *AuthoredWaitFixture, compiled: anytype) !void {
        self.image = try self.a.alloc(u8, try data.program_image.encodedLength(compiled.program));
        self.image_live = true;
        _ = try compiled.encode(self.a, self.image);
        self.admitted = try data.program_image.Admitted.decode(self.a, self.image);
        self.admitted_live = true;
        self.application = .{
            .arena = .init(self.a),
            .metadata = .null,
            .manifest = .null,
            .manifest_id = "wait-unit",
            .image_identity = self.admitted.identity(),
        };
        self.application_live = true;
        self.manifest = try fixtureManifest(
            self.a,
            self.image,
            self.admitted.identity(),
            "wait-unit",
        );
        self.manifest_live = true;
        self.application.manifest = (try native.json.parse(
            self.application.arena.allocator(),
            self.manifest,
            .{},
        )).value;
        self.assets = .{
            .image = self.image,
            .application = "wait-unit",
            .manifest = self.manifest,
        };
    }
    fn initHandlers(self: *AuthoredWaitFixture) !void {
        self.handlers = try native.Registry.init(self.a, &.{ native.inbox.declaration(
            WaitTypes.Message,
        ), .{
            .identity = "workspace-wait",
            .resource_role = "workspace",
            .kind = .workspace,
            .workspace = WaitApplication.authorize,
            .payload_schema = WaitApplication.schema,
            .resume_schema = WaitApplication.result,
        } });
        self.handlers_live = true;
    }
    fn initProfile(self: *AuthoredWaitFixture) !void {
        self.grants = [_]native.registry.Grant{ .{
            .identity = "workspace-wait",
            .resource_role = "workspace",
            .resource_identity = undefined,
        }, .{
            .identity = native.inbox.identity,
            .resource_role = "user",
            .resource_identity = undefined,
        } };
        self.profile = .{ .id = "offline", .runtime_identity = @splat(
            42,
        ), .bytes = "wait-test", .authority = .{
            .grants = &self.grants,
            .principal = "test",
            .tenant = "test",
        } };
        for (&self.grants) |*grant| grant.resource_identity = try self.profile.resourceIdentity(
            self.a,
            self.application.image_identity,
        );
    }
    fn initOwner(self: *AuthoredWaitFixture) !void {
        self.temp = std.testing.tmpDir(.{});
        self.temp_live = true;
        self.path_buffer = undefined;
        self.length = try self.temp.dir.realPath(self.io, &self.path_buffer);
        self.path = try std.fmt.allocPrint(
            self.a,
            "{s}/state",
            .{self.path_buffer[0..self.length]},
        );
        self.path_live = true;
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        self.namespace_open = true;
        self.service = try native.tasks.Service(WaitTypes).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        self.service_open = true;
        self.arena = std.heap.ArenaAllocator.init(self.a);
        self.arena_live = true;
        self.scratch = self.arena.allocator();
    }
    fn initSource(self: *AuthoredWaitFixture) !void {
        self.builder = source.Builder.init(self.a);
        self.builder_live = true;
        self.document = try native.source_records.encode(self.a, try listLength(&self.builder));
        self.document_live = true;
        self.input = try self.a.alloc(u8, 300 * 9 + 1);
        self.input_live = true;
        var writer: data.wire.Writer = .{ .output = self.input };
        for (0..300) |i| {
            try writer.natural(1);
            try writer.fixed(u64, @intCast(i));
        }
        try writer.natural(0);
    }
    fn deinit(self: *AuthoredWaitFixture) void {
        if (self.input_live) self.a.free(self.input);
        if (self.document_live) self.a.free(self.document);
        if (self.builder_live) self.builder.deinit();
        if (self.arena_live) self.arena.deinit();
        if (self.service_open) support.expectCleanup(self.service.close(self.a));
        if (self.namespace_open) support.expectCleanup(self.namespace.close());
        if (self.path_live) self.a.free(self.path);
        if (self.temp_live) self.temp.cleanup();
        if (self.handlers_live) self.handlers.deinit();
        if (self.manifest_live) self.a.free(self.manifest);
        if (self.application_live) self.application.deinit();
        if (self.admitted_live) self.admitted.deinit();
        if (self.image_live) self.a.free(self.image);
    }
};
const AuthoredWaitCase = struct {
    fixture: *AuthoredWaitFixture,
    scenario: WaitScenario,
    index: usize,
    interrupt: bool = undefined,
    prefix: []const u8 = undefined,
    parent: native.tasks.Admission = undefined,
    cleanup_id: ?[32]u8 = undefined,
    parked_port_id: ?[32]u8 = undefined,
    port_start: contracts.workspace.Command = undefined,
    port_receipt: contracts.workspace.Reply = undefined,
    initial: contracts.Decoded(native.workspace.Work) = undefined,
    selection: WaitTypes.Message = undefined,
    finished: contracts.Decoded(native.testing.state.Task) = undefined,
    bytes: []u8 = undefined,
    reply: contracts.Decoded(WaitTypes.Output) = undefined,
    observation: std.json.Parsed(native.json.Value) = undefined,
    child: contracts.Decoded(native.workspace.Work) = undefined,
    selection_work: [1]contracts.workspace.Ref = undefined,
    initial_live: bool = false,
    finished_live: bool = false,
    bytes_live: bool = false,
    reply_live: bool = false,
    observation_live: bool = false,
    child_live: bool = false,
    fn run(self: *AuthoredWaitCase) !void {
        try self.submit();
        try self.selectAndWait();
        if (self.scenario == .incompatible_wait) {
            try self.cancelIncompatibleWait();
            return;
        }
        try self.wake();
        try self.observeCompletion();
        try self.cancelChildren();
        try self.observeDisposal();
    }
    fn startSelectedPort(self: *AuthoredWaitCase) !void {
        var ports = source.Builder.init(self.fixture.scratch);
        defer ports.deinit();
        const port_source = try native.source_records.encode(
            self.fixture.scratch,
            try alternatives(&ports, true),
        );
        const built = try self.fixture.service.workspaceCommand(
            self.fixture.scratch,
            "parent-port-build",
            self.parent.receipt.task,
            .{ .program = .{ .build = .{ .source = .{ .json_text = .{
                .bytes = port_source,
            } }, .source_kind = .source_records, .exposures = .{ .items = &.{ .{
                .effect = 0,
                .class = .observation,
            }, .{ .effect = 1, .class = .alternative } } } } } },
        );
        var program_id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&program_id, built.program.?.id.bytes);
        var artifact = try self.fixture.service.workspaceProgram(
            self.fixture.scratch,
            self.parent.receipt.task,
            program_id,
        );
        defer artifact.deinit();
        self.port_start = .{
            .work = .{
                .start = .{
                    .program = built.program.?,
                    .input = .{ .inline_json = .{ .schema = try workspaceRef(
                        self.fixture.scratch,
                        .schema,
                        artifact.value.description.input_schema.digest,
                    ), .json_text = .{ .bytes = "\"100\"" } } },
                    .policy = .{},
                },
            },
        };
        _ = try self.fixture.service.workspaceCommand(
            self.fixture.scratch,
            "parent-port-start",
            self.parent.receipt.task,
            self.port_start,
        );
        self.port_receipt = try self.fixture.service.workspaceCommand(
            self.fixture.scratch,
            "parent-port-start",
            self.parent.receipt.task,
            self.port_start,
        );
        var observed = try native.json.parse(
            self.fixture.scratch,
            self.port_receipt.observation_json.bytes,
            .{},
        );
        defer observed.deinit();
        try std.testing.expect(observed.value.object.get("port_accepts_command").?.bool);
        var work_id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(
            &work_id,
            observed.value.object.get("work").?.object.get("id").?.string,
        );
        self.parked_port_id = work_id;
    }
    fn startDisposalWork(self: *AuthoredWaitCase) !void {
        var disposal_builder = source.Builder.init(self.fixture.scratch);
        defer disposal_builder.deinit();
        const disposal_source = try native.source_records.encode(
            self.fixture.scratch,
            try @import("workspace_sources.zig").yieldingDisposal(&disposal_builder),
        );
        const disposal_program = try self.fixture.service.workspaceCommand(
            self.fixture.scratch,
            "late-cleanup-build",
            self.parent.receipt.task,
            .{ .program = .{ .build = .{ .source = .{ .json_text = .{
                .bytes = disposal_source,
            } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{
                .effect = 0,
                .class = .observation,
            }} } } } },
        );
        var program_id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&program_id, disposal_program.program.?.id.bytes);
        self.cleanup_id = (try self.fixture.service.workspaceStart(
            self.fixture.scratch,
            "late-cleanup-start",
            self.parent.receipt.task,
            program_id,
            &.{},
            .{},
        )).receipt.workspace.?;
    }
    fn cancelIncompatibleWait(self: *AuthoredWaitCase) !void {
        try self.fixture.service.close(self.fixture.scratch);
        var foreign_profile = self.fixture.profile;
        foreign_profile.bytes = "different-wait-launch";
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            foreign_profile,
        );
        const first_cancel = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "foreign-wait-cancel",
            self.parent.receipt.task,
            "cancel retained wait",
        );
        const replay = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "foreign-wait-cancel",
            self.parent.receipt.task,
            "cancel retained wait",
        );
        try std.testing.expect(
            replay.replayed and std.meta.eql(first_cancel.receipt.id, replay.receipt.id),
        );
        _ = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "foreign-wait-cancel-again",
            self.parent.receipt.task,
            "retain original cancellation",
        );
        try std.testing.expectEqual(.idle, try self.fixture.service.pump(self.fixture.scratch));
        var blocked = try self.fixture.service.task(self.fixture.scratch, self.parent.receipt.task);
        defer blocked.deinit();
        try std.testing.expectEqual(.incompatible_profile, blocked.value.blocker.?);
        try std.testing.expectEqualStrings(
            "cancel retained wait",
            blocked.value.cancellation.?.bytes,
        );
        try std.testing.expect(
            !try self.fixture.service.associatedWorkDisposed(
                self.fixture.scratch,
                self.parent.receipt.task,
            ),
        );
        try self.cancelCompatibleWait();
    }
    fn importWaitingCopy(self: *AuthoredWaitCase) !void {
        const archive_path = try std.fmt.allocPrint(self.fixture.scratch, "{s}/waiting.par", .{
            self.fixture.path_buffer[0..self.fixture.length],
        });
        _ = try self.fixture.service.exportCheckpoint(
            self.fixture.scratch,
            self.parent.receipt.task,
            archive_path,
        );
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service_open = false;
        try self.fixture.namespace.close();
        self.fixture.namespace_open = false;
        self.fixture.namespace = try native.Namespace.open(
            self.fixture.a,
            self.fixture.io,
            try std.fmt.allocPrint(
                self.fixture.scratch,
                "{s}/waiting-import",
                .{self.fixture.path_buffer[0..self.fixture.length]},
            ),
        );
        self.fixture.namespace_open = true;
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
        self.fixture.service_open = true;
        _ = try self.fixture.service.importCheckpoint(
            self.fixture.scratch,
            "import-wait",
            archive_path,
        );
        try std.testing.expectError(
            error.CustodyNotLocal,
            self.fixture.service.message(
                self.fixture.scratch,
                "copy-wait-amendment",
                self.parent.receipt.task,
                self.selection,
            ),
        );
        try std.testing.expectError(
            error.CustodyNotLocal,
            self.fixture.service.resumeTask(
                self.fixture.scratch,
                "copy-wait-resume",
                self.parent.receipt.task,
                1,
            ),
        );
        try std.testing.expectEqual(
            .idle,
            std.meta.activeTag(try self.fixture.service.pump(self.fixture.scratch)),
        );
        try self.restoreWaitingOwner();
    }
    fn amendOwnedWait(self: *AuthoredWaitCase) !void {
        var guarded: AfterCommitAllocator = .{
            .backing = self.fixture.scratch,
            .namespace = &self.fixture.namespace,
            .generation = self.fixture.namespace.store.head.generation,
        };
        _ = try self.fixture.service.message(
            guarded.allocator(),
            "owned-wait-amendment",
            self.parent.receipt.task,
            self.selection,
        );
        try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
        try std.testing.expect(
            (try self.fixture.service.message(
                self.fixture.scratch,
                "owned-wait-amendment",
                self.parent.receipt.task,
                self.selection,
            )).replayed,
        );
    }
    fn reopenControl(self: *AuthoredWaitCase) !void {
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
        try std.testing.expectEqual(
            .idle,
            std.meta.activeTag(try self.fixture.service.pump(self.fixture.scratch)),
        );
        _ = try self.fixture.service.workspaceControl(
            self.fixture.scratch,
            "reopen-and-advance",
            self.parent.receipt.task,
            self.initial.value.id,
            self.initial.value.execution_revision,
            self.initial.value.control_revision,
            .advance,
        );
    }
    fn parkChildExplicitly(self: *AuthoredWaitCase) !void {
        var delegated = try self.fixture.service.workspaceWork(
            self.fixture.scratch,
            self.parent.receipt.task,
            self.initial.value.id,
        );
        defer delegated.deinit();
        _ = try self.fixture.service.workspaceControl(
            self.fixture.scratch,
            "explicit-park-before-close",
            self.parent.receipt.task,
            self.initial.value.id,
            delegated.value.execution_revision,
            delegated.value.control_revision,
            .park,
        );
    }
    fn restoreChild(self: *AuthoredWaitCase) !void {
        if (self.scenario == .resumed_explicit_park) {
            try self.parkChildExplicitly();
        }
        if (self.scenario != .resumed_child) try self.fixture.service.park(self.fixture.scratch);
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
        try std.testing.expectEqual(
            .idle,
            std.meta.activeTag(try self.fixture.service.pump(self.fixture.scratch)),
        );
        var paused = try self.fixture.service.task(self.fixture.scratch, self.parent.receipt.task);
        defer paused.deinit();
        var guarded: AfterCommitAllocator = .{
            .backing = self.fixture.scratch,
            .namespace = &self.fixture.namespace,
            .generation = self.fixture.namespace.store.head.generation,
        };
        const resume_id = try std.fmt.allocPrint(
            self.fixture.scratch,
            "restore-queued-child-{d}",
            .{
                self.index,
            },
        );
        _ = try self.fixture.service.resumeTask(
            guarded.allocator(),
            resume_id,
            self.parent.receipt.task,
            paused.value.revision,
        );
        try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
        try std.testing.expect(
            (try self.fixture.service.resumeTask(
                self.fixture.scratch,
                resume_id,
                self.parent.receipt.task,
                paused.value.revision,
            )).replayed,
        );
        try self.observeExplicitPark();
    }
    fn observeTerminalPort(self: *AuthoredWaitCase, work_id: [32]u8) !void {
        const live = try self.fixture.service.workspaceCommand(
            self.fixture.scratch,
            "terminal-parent-port",
            self.parent.receipt.task,
            .{ .work = .{ .inspect = .{
                .work = try workspaceRef(self.fixture.scratch, .work, work_id),
            } } },
        );
        var observed = try native.json.parse(
            self.fixture.scratch,
            live.observation_json.bytes,
            .{},
        );
        defer observed.deinit();
        try std.testing.expect(!observed.value.object.get("port_accepts_command").?.bool);
        const historical = try self.fixture.service.workspaceCommand(
            self.fixture.scratch,
            "parent-port-start",
            self.parent.receipt.task,
            self.port_start,
        );
        try std.testing.expectEqualStrings(
            self.port_receipt.observation_json.bytes,
            historical.observation_json.bytes,
        );
        var parked = try self.fixture.service.workspaceWork(
            self.fixture.scratch,
            self.parent.receipt.task,
            work_id,
        );
        defer parked.deinit();
        var port = try contracts.decodeOwned(
            native.workspace.Port,
            self.fixture.scratch,
            try self.fixture.namespace.store.object(
                self.fixture.scratch,
                parked.value.current_port.?,
                null,
            ),
        );
        defer port.deinit();
        try std.testing.expectError(
            error.InvalidState,
            self.fixture.service.workspaceInteract(
                self.fixture.scratch,
                "terminal-parent-answer",
                self.parent.receipt.task,
                .{
                    .expected = .{
                        .work = try workspaceRef(self.fixture.scratch, .work, work_id),
                        .execution_revision = parked.value.execution_revision,
                        .control_revision = parked.value.control_revision,
                    },
                    .port = try workspaceRef(self.fixture.scratch, .port, port.value.id),
                    .generation = port.value.generation,
                    .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                        self.fixture.scratch,
                        .schema,
                        port.value.interface.argument.digest,
                    ), .json_text = .{ .bytes = "{}" } } } },
                },
            ),
        );
    }
    fn cancelWithForeignProfile(self: *AuthoredWaitCase) !void {
        try self.fixture.service.park(self.fixture.scratch);
        try self.fixture.service.close(self.fixture.scratch);
        var incompatible = self.fixture.profile;
        incompatible.bytes = "different-cleanup-launch";
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            incompatible,
        );
        _ = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "incompatible-completed-root-cancel",
            self.parent.receipt.task,
            "dispose remaining work",
        );
        try std.testing.expectEqual(.idle, try self.fixture.service.pump(self.fixture.scratch));
        var blocked = try self.fixture.service.task(self.fixture.scratch, self.parent.receipt.task);
        defer blocked.deinit();
        try std.testing.expectEqual(.completed, blocked.value.outcome_kind);
        try std.testing.expectEqual(.incompatible_profile, blocked.value.blocker.?);
        try std.testing.expect(
            !try self.fixture.service.associatedWorkDisposed(
                self.fixture.scratch,
                self.parent.receipt.task,
            ),
        );
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
    }
    fn disposeYieldingChild(self: *AuthoredWaitCase, pending_id: [32]u8) !void {
        var started_cleanup = false;
        for (0..30) |_| {
            _ = try self.fixture.service.pump(self.fixture.scratch);
            var pending = try self.fixture.service.workspaceWork(
                self.fixture.scratch,
                self.parent.receipt.task,
                pending_id,
            );
            defer pending.deinit();
            if (pending.value.cancellation_applied) {
                try std.testing.expect(!pending.value.terminal());
                try std.testing.expectEqual(.queued, pending.value.schedule);
                started_cleanup = true;
                break;
            }
        }
        try std.testing.expect(started_cleanup);
        var cleanup = try self.fixture.service.workspaceWork(
            self.fixture.scratch,
            self.parent.receipt.task,
            pending_id,
        );
        defer cleanup.deinit();
        _ = try self.fixture.service.workspaceControl(
            self.fixture.scratch,
            "park-admitted-cleanup",
            self.parent.receipt.task,
            pending_id,
            cleanup.value.execution_revision,
            cleanup.value.control_revision,
            .park,
        );
        for (0..30) |_| _ = try self.fixture.service.pump(self.fixture.scratch);
        var still_parked = try self.fixture.service.workspaceWork(
            self.fixture.scratch,
            self.parent.receipt.task,
            pending_id,
        );
        defer still_parked.deinit();
        try std.testing.expectEqual(.parked, still_parked.value.schedule);
        try std.testing.expectEqual(
            cleanup.value.execution_revision,
            still_parked.value.execution_revision,
        );
        try self.reopenCleanupForeign(pending_id);
    }
    fn submit(self: *AuthoredWaitCase) !void {
        self.interrupt = self.scenario == .imported_message or self.scenario == .owned_message;
        self.prefix = try std.fmt.allocPrint(self.fixture.scratch, "wait-{d}", .{self.index});
        self.parent = try self.fixture.service.submit(self.fixture.scratch, self.prefix, {});
        self.cleanup_id = null;
        self.parked_port_id = null;
        self.port_start = undefined;
        self.port_receipt = undefined;
        if (self.scenario == .selected_event) {
            try self.startSelectedPort();
        }
        if (self.scenario == .orderly_resumed_child) {
            try self.startDisposalWork();
        }
    }
    fn selectAndWait(self: *AuthoredWaitCase) !void {
        var diagnostic: native.program_construction.Diagnostic = .{};
        const program = try self.fixture.service.workspaceBuild(
            self.fixture.scratch,
            try std.fmt.allocPrint(self.fixture.scratch, "{s}-build", .{self.prefix}),
            self.parent.receipt.task,
            self.fixture.document,
            &diagnostic,
        );
        const started = try self.fixture.service.workspaceStart(
            self.fixture.scratch,
            try std.fmt.allocPrint(self.fixture.scratch, "{s}-start", .{self.prefix}),
            self.parent.receipt.task,
            program.receipt.workspace.?,
            self.fixture.input,
            .{},
        );
        self.initial = try self.fixture.service.workspaceWork(
            self.fixture.a,
            self.parent.receipt.task,
            started.receipt.workspace.?,
        );
        self.initial_live = true;
        self.selection_work[0] = try workspaceRef(
            self.fixture.scratch,
            .work,
            self.initial.value.id,
        );
        self.selection = .{
            .works = .{ .items = &self.selection_work },
            .after = self.initial.value.event_watermark,
        };
        _ = try self.fixture.service.message(
            self.fixture.scratch,
            try std.fmt.allocPrint(self.fixture.scratch, "{s}-selection", .{self.prefix}),
            self.parent.receipt.task,
            self.selection,
        );
        var waited = false;
        for (0..20) |_| {
            const step = try self.fixture.service.pump(self.fixture.scratch);
            try std.testing.expect(step != .work);
            if (step == .waiting) {
                waited = true;
                break;
            }
        }
        try std.testing.expect(waited);
        try std.testing.expectEqual(
            .idle,
            std.meta.activeTag(try self.fixture.service.pump(self.fixture.scratch)),
        );
    }
    fn wake(self: *AuthoredWaitCase) !void {
        if (self.scenario == .imported_message) {
            try self.importWaitingCopy();
        } else if (self.scenario == .owned_message) {
            try self.amendOwnedWait();
        } else if (self.scenario == .reopened_control) {
            try self.reopenControl();
        } else {
            _ = try self.fixture.service.workspaceControl(
                self.fixture.scratch,
                try std.fmt.allocPrint(self.fixture.scratch, "wait-progress-{d}", .{self.index}),
                self.parent.receipt.task,
                self.initial.value.id,
                self.initial.value.execution_revision,
                self.initial.value.control_revision,
                .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } },
            );
            if (self.scenario == .resumed_child or self.scenario == .orderly_resumed_child or
                self.scenario == .resumed_explicit_park)
            {
                try self.restoreChild();
            }
        }
    }
    fn observeCompletion(self: *AuthoredWaitCase) !void {
        for (0..30) |_| {
            const step = try self.fixture.service.pump(self.fixture.scratch);
            try std.testing.expect(step != .work);
            var current = try self.fixture.service.task(self.fixture.a, self.parent.receipt.task);
            defer current.deinit();
            if (current.value.terminal()) break;
        }
        self.finished = try self.fixture.service.task(self.fixture.a, self.parent.receipt.task);
        self.finished_live = true;
        try std.testing.expectEqual(.completed, self.finished.value.outcome_kind);
        try std.testing.expectEqual(@as(usize, 0), self.finished.value.messages.items.len);
        self.bytes = try self.fixture.namespace.store.object(
            self.fixture.a,
            self.finished.value.result.?,
            null,
        );
        self.bytes_live = true;
        self.reply = try contracts.decodeOwned(WaitTypes.Output, self.fixture.a, self.bytes);
        self.reply_live = true;
        self.observation = try native.json.parse(
            self.fixture.a,
            self.reply.value.observation_json.bytes,
            .{},
        );
        self.observation_live = true;
        try std.testing.expect(self.observation.value.object.get("ready").?.bool);
        try std.testing.expectEqual(
            self.interrupt,
            self.observation.value.object.get("interrupted").?.bool,
        );
        self.child = try self.fixture.service.workspaceWork(
            self.fixture.a,
            self.parent.receipt.task,
            self.initial.value.id,
        );
        self.child_live = true;
        try std.testing.expect(!self.child.value.terminal());
        if (self.interrupt or self.scenario == .resumed_explicit_park) try std.testing.expectEqual(
            self.initial.value.execution_revision,
            self.child.value.execution_revision,
        ) else try std.testing.expect(
            self.child.value.execution_revision > self.initial.value.execution_revision,
        );
        try self.fixture.service.validateWorkspace(self.fixture.scratch, self.parent.receipt.task);
    }
    fn cancelChildren(self: *AuthoredWaitCase) !void {
        // Root completion retains unfinished children. The public task cancel
        // path must dispose them without replacing the already published result.
        if (self.parked_port_id) |work_id| {
            try self.observeTerminalPort(work_id);
        }
        if (self.scenario == .orderly_resumed_child) {
            try self.cancelWithForeignProfile();
        }
        const cancel_id = try std.fmt.allocPrint(
            self.fixture.scratch,
            "cancel-unjoined-{d}",
            .{self.index},
        );
        var cancel_guard: AfterCommitAllocator = .{
            .backing = self.fixture.scratch,
            .namespace = &self.fixture.namespace,
            .generation = self.fixture.namespace.store.head.generation,
        };
        const cancelled = try self.fixture.service.requestCancel(
            cancel_guard.allocator(),
            cancel_id,
            self.parent.receipt.task,
            "dispose remaining work",
        );
        try std.testing.expectEqual(@as(usize, 0), cancel_guard.rejected);
        const replayed = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            cancel_id,
            self.parent.receipt.task,
            "dispose remaining work",
        );
        try std.testing.expect(
            replayed.replayed and std.meta.eql(cancelled.receipt.id, replayed.receipt.id),
        );
        if (self.cleanup_id) |pending_id| {
            try self.disposeYieldingChild(pending_id);
        }
    }
    fn observeDisposal(self: *AuthoredWaitCase) !void {
        for (0..30) |_| {
            _ = try self.fixture.service.pump(self.fixture.scratch);
            if (try self.fixture.service.associatedWorkDisposed(
                self.fixture.scratch,
                self.parent.receipt.task,
            )) break;
        }
        try std.testing.expect(
            try self.fixture.service.associatedWorkDisposed(
                self.fixture.scratch,
                self.parent.receipt.task,
            ),
        );
        var retained_result = try self.fixture.service.task(
            self.fixture.scratch,
            self.parent.receipt.task,
        );
        defer retained_result.deinit();
        try std.testing.expectEqual(.completed, retained_result.value.outcome_kind);
        try std.testing.expectEqualDeep(self.finished.value.result, retained_result.value.result);
        try std.testing.expectEqualDeep(self.finished.value.outcome, retained_result.value.outcome);
        try std.testing.expect(!retained_result.value.cancellation_applied);
        const cancelled_archive = try std.fmt.allocPrint(
            self.fixture.scratch,
            "{s}/cancelled-children-{d}.par",
            .{ self.fixture.path_buffer[0..self.fixture.length], self.index },
        );
        _ = try self.fixture.service.exportCheckpoint(
            self.fixture.scratch,
            self.parent.receipt.task,
            cancelled_archive,
        );
    }
    fn cancelCompatibleWait(self: *AuthoredWaitCase) !void {
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
        _ = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "compatible-wait-cancel",
            self.parent.receipt.task,
            "cancel retained wait",
        );
        for (0..64) |_| {
            _ = try self.fixture.service.pump(self.fixture.scratch);
            var current = try self.fixture.service.task(
                self.fixture.scratch,
                self.parent.receipt.task,
            );
            defer current.deinit();
            if (try self.fixture.service.taskCleanupComplete(
                self.fixture.scratch,
                current.value,
            )) break;
        }
        var disposed = try self.fixture.service.task(
            self.fixture.scratch,
            self.parent.receipt.task,
        );
        defer disposed.deinit();
        try std.testing.expect(
            try self.fixture.service.taskCleanupComplete(self.fixture.scratch, disposed.value),
        );
        try std.testing.expectEqual(.cancelled, disposed.value.outcome_kind);
    }
    fn restoreWaitingOwner(self: *AuthoredWaitCase) !void {
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service_open = false;
        try self.fixture.namespace.close();
        self.fixture.namespace_open = false;
        self.fixture.namespace = try native.Namespace.open(
            self.fixture.a,
            self.fixture.io,
            self.fixture.path,
        );
        self.fixture.namespace_open = true;
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
        self.fixture.service_open = true;
        _ = try self.fixture.service.message(
            self.fixture.scratch,
            "wait-amendment",
            self.parent.receipt.task,
            self.selection,
        );
        // Opening the namespace and appending input do not implicitly
        // resume old ownership; the explicit resume restores the wait.
        try std.testing.expectEqual(
            .idle,
            std.meta.activeTag(try self.fixture.service.pump(self.fixture.scratch)),
        );
        var paused = try self.fixture.service.task(self.fixture.a, self.parent.receipt.task);
        defer paused.deinit();
        _ = try self.fixture.service.resumeTask(
            self.fixture.scratch,
            "wait-resume",
            self.parent.receipt.task,
            paused.value.revision,
        );
    }
    fn observeExplicitPark(self: *AuthoredWaitCase) !void {
        if (self.scenario == .resumed_explicit_park) {
            for (0..10) |_| _ = try self.fixture.service.pump(self.fixture.scratch);
            var parked = try self.fixture.service.workspaceWork(
                self.fixture.scratch,
                self.parent.receipt.task,
                self.initial.value.id,
            );
            defer parked.deinit();
            try std.testing.expectEqual(.parked, parked.value.schedule);
            try std.testing.expectEqual(
                self.initial.value.execution_revision,
                parked.value.execution_revision,
            );
        }
    }
    fn reopenCleanupForeign(self: *AuthoredWaitCase, pending_id: [32]u8) !void {
        try self.fixture.service.park(self.fixture.scratch);
        try self.fixture.service.close(self.fixture.scratch);
        var incompatible = self.fixture.profile;
        incompatible.bytes = "different-resumed-cleanup-launch";
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            incompatible,
        );
        _ = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "incompatible-queued-cleanup-cancel",
            self.parent.receipt.task,
            "dispose remaining work",
        );
        try std.testing.expectEqual(.idle, try self.fixture.service.pump(self.fixture.scratch));
        var blocked = try self.fixture.service.task(self.fixture.scratch, self.parent.receipt.task);
        defer blocked.deinit();
        try std.testing.expectEqual(.incompatible_profile, blocked.value.blocker.?);
        try std.testing.expect(
            !try self.fixture.service.associatedWorkDisposed(
                self.fixture.scratch,
                self.parent.receipt.task,
            ),
        );
        try self.fixture.service.close(self.fixture.scratch);
        self.fixture.service = try native.tasks.Service(WaitTypes).init(
            self.fixture.a,
            self.fixture.io,
            &self.fixture.namespace,
            self.fixture.assets,
            &self.fixture.application,
            self.fixture.handlers,
            self.fixture.profile,
        );
        try std.testing.expectEqual(
            .idle,
            std.meta.activeTag(try self.fixture.service.pump(self.fixture.scratch)),
        );
        _ = try self.fixture.service.requestCancel(
            self.fixture.scratch,
            "continue-admitted-cleanup",
            self.parent.receipt.task,
            "dispose remaining work",
        );
        var unblocked = try self.fixture.service.task(
            self.fixture.scratch,
            self.parent.receipt.task,
        );
        defer unblocked.deinit();
        try std.testing.expect(unblocked.value.blocker == null);
        try self.answerCleanup(pending_id);
    }
    fn answerCleanup(self: *AuthoredWaitCase, pending_id: [32]u8) !void {
        var answered_cleanup = false;
        for (0..30) |_| {
            _ = try self.fixture.service.pump(self.fixture.scratch);
            var pending = try self.fixture.service.workspaceWork(
                self.fixture.scratch,
                self.parent.receipt.task,
                pending_id,
            );
            defer pending.deinit();
            if (pending.value.current_port) |ref| {
                try std.testing.expect(
                    !try self.fixture.service.associatedWorkDisposed(
                        self.fixture.scratch,
                        self.parent.receipt.task,
                    ),
                );
                const live = try self.fixture.service.workspaceCommand(
                    self.fixture.scratch,
                    "late-cleanup-inspect",
                    self.parent.receipt.task,
                    .{ .work = .{ .inspect = .{
                        .work = try workspaceRef(self.fixture.scratch, .work, pending_id),
                    } } },
                );
                var observed = try native.json.parse(
                    self.fixture.scratch,
                    live.observation_json.bytes,
                    .{},
                );
                defer observed.deinit();
                try std.testing.expect(
                    observed.value.object.get("port_accepts_command").?.bool,
                );
                var port = try contracts.decodeOwned(
                    native.workspace.Port,
                    self.fixture.scratch,
                    try self.fixture.namespace.store.object(self.fixture.scratch, ref, null),
                );
                defer port.deinit();
                _ = try self.fixture.service.workspaceInteract(
                    self.fixture.scratch,
                    "answer-late-cleanup",
                    self.parent.receipt.task,
                    .{
                        .expected = .{
                            .work = try workspaceRef(self.fixture.scratch, .work, pending_id),
                            .execution_revision = pending.value.execution_revision,
                            .control_revision = pending.value.control_revision,
                        },
                        .port = try workspaceRef(self.fixture.scratch, .port, port.value.id),
                        .generation = port.value.generation,
                        .command = .{
                            .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                                self.fixture.scratch,
                                .schema,
                                port.value.interface.argument.digest,
                            ), .json_text = .{ .bytes = "{}" } } },
                        },
                    },
                );
                answered_cleanup = true;
                break;
            }
        }
        try std.testing.expect(answered_cleanup);
    }
    fn deinit(self: *AuthoredWaitCase) void {
        if (self.child_live) self.child.deinit();
        if (self.observation_live) self.observation.deinit();
        if (self.reply_live) self.reply.deinit();
        if (self.bytes_live) self.fixture.a.free(self.bytes);
        if (self.finished_live) self.finished.deinit();
        if (self.initial_live) self.initial.deinit();
    }
};
fn expectModelRequestBudget(
    service: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
) !void {
    const store = &service.namespace.store;
    const Reader = struct {
        fn read(
            pointer: *anyopaque,
            allocator: std.mem.Allocator,
            ref: native.testing.state.Reference,
            limit: usize,
        ) ![]u8 {
            const source_store: *@TypeOf(service.namespace.store) = @ptrCast(@alignCast(pointer));
            return source_store.object(allocator, ref, limit);
        }
    };
    var delegation = (try contracts.decodeOwned(
        native.workspace.Delegation,
        a,
        try store.object(a, child.delegation.?, null),
    )).value;
    const original_port = (try contracts.decodeOwned(
        native.workspace.Port,
        a,
        try store.object(a, delegation.port, null),
    )).value;
    try store.begin();
    defer store.rollback();
    const huge_schema = try store.putObject(
        try data.schema.encodeOwned(
            a,
            &.{ .{ .array = .{ .element = 1, .length = 1_000_000_000 } }, .unit },
            0,
        ),
    );
    const empty = try store.putObject("");
    const artifact = try store.putObject(
        try contracts.encodeOwned(native.workspace.ValueArtifact, a, .{
            .schema = huge_schema,
            .value = empty,
            .provenance = empty,
        }),
    );
    const context: native.registry.ProjectionContext = .{
        .allocator = a,
        .task = child.task,
        .tenant = "test",
        .profile = "test",
        .objects = native.registry.ReadView.validating(store, Reader.read),
    };
    try expectBoundedModelBody(store, a, child, context, &delegation);
    try expectModelSchemaBudget(
        store,
        a,
        context,
        delegation,
        original_port,
        artifact,
        huge_schema,
        empty,
    );
}

fn expectInstrumentAnswerBound(
    service: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
) !void {
    const store = &service.namespace.store;
    try service.validateWorkspace(a, child.task);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, child.task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    const old_result_id = try native.workspace.custodyId(
        a,
        child.task,
        child.result_value.?.digest,
    );
    const old_answer_id = try native.workspace.custodyId(
        a,
        child.task,
        child.answer_value.?.digest,
    );
    var original_result = try contracts.decodeOwned(
        native.workspace.Value,
        a,
        (try store.recordBytes(a, "workspace_value", old_result_id, child.task)).?,
    );
    defer original_result.deinit();
    var original_answer = try contracts.decodeOwned(
        native.workspace.ValueArtifact,
        a,
        try store.object(a, child.answer_value.?, null),
    );
    defer original_answer.deinit();
    var compiler_facts = try service.prepareWorkspaceValidation(child.task);
    defer compiler_facts.deinit();
    for (0..3) |variant| {
        try expectInstrumentAnswerVariant(
            service,
            a,
            child,
            variant,
            index.records.items,
            old_result_id,
            old_answer_id,
            original_result.value,
            original_answer.value,
            &compiler_facts,
        );
    }
}

fn forgeAlternativeInstrumentCheckpoint(
    store: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    forged: *native.workspace.Work,
) !void {
    // A real checkpoint of the SAME native program can return another
    // reply. It must not substitute for the actual captured reply.
    var program = try contracts.decodeOwned(
        native.workspace.ProgramArtifact,
        a,
        try store.object(a, try store.objectReference(child.program, null), null),
    );
    defer program.deinit();
    var prepared = try kosmos.Prepared.init(
        a,
        try store.object(a, program.value.image, null),
    );
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(
        a,
        &prepared,
        try store.object(a, child.input, null),
    );
    defer support.expectCleanup(resident.close());
    var requested = try resident.publish(
        .{ .encoded = a },
        .none,
        .{ .quantum = 256, .checkpoint = .receipt },
    );
    defer requested.takeCheckpoint().?.deinit();
    var initial = try data.invocation.decode(
        data.invocation.Outcome,
        a,
        requested.outcome.encoded,
    );
    defer initial.deinit();
    var request = try data.invocation.decode(
        data.invocation.Request,
        a,
        initial.value.requested.request,
    );
    defer request.deinit();
    try publishAlternativeInstrumentCheckpoint(
        store,
        a,
        &resident,
        request.value.request_identity,
        forged,
    );
}

fn forgeHypothesisInstrumentAnswer(
    store: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    original_answer: native.workspace.ValueArtifact,
    records: *std.ArrayList(native.testing.state.ArchiveRecord),
    forged: *native.workspace.Work,
) !void {
    // Same typed bytes, but an unrelated hypothesis is not the answer's
    // selected acquisition or captured model judgment.
    var answer: native.workspace.Value = .{
        .id = undefined,
        .task = child.task,
        .artifact = undefined,
        .description = original_answer,
        .derivation = .{ .kind = .hypothesis, .sources = .{ .items = &.{} } },
    };
    answer.description.provenance = try store.putObject(
        try contracts.encodeOwned(native.workspace.Derivation, a, answer.derivation),
    );
    answer.artifact = try store.putObject(
        try contracts.encodeOwned(native.workspace.ValueArtifact, a, answer.description),
    );
    answer.id = try native.workspace.custodyId(a, child.task, answer.artifact.digest);
    try store.createRecord(
        native.workspace.Value,
        "workspace_value",
        answer.id,
        child.task,
        answer,
    );
    try records.append(a, .{
        .kind = .workspace_value,
        .id = answer.id,
        .body = try store.putObject(
            try contracts.encodeOwned(native.workspace.Value, a, answer),
        ),
    });
    forged.answer_value = answer.artifact;
}

fn forgeInstrumentResult(
    store: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    original_result: native.workspace.Value,
    old_result_id: [32]u8,
    records: *std.ArrayList(native.testing.state.ArchiveRecord),
    forged: *native.workspace.Work,
) !void {
    var result = original_result;
    result.description.value = forged.result.?;
    const sources = try a.alloc(native.testing.state.Reference, 1 + forged.inputs.items.len);
    sources[0] = forged.input_value.?;
    @memcpy(sources[1..], forged.inputs.items);
    result.derivation.sources.items = sources;
    result.description.provenance = try store.putObject(
        try contracts.encodeOwned(native.workspace.Derivation, a, result.derivation),
    );
    result.artifact = try store.putObject(
        try contracts.encodeOwned(native.workspace.ValueArtifact, a, result.description),
    );
    result.id = try native.workspace.custodyId(a, child.task, result.artifact.digest);
    try store.database.run(
        "DELETE FROM records WHERE task=? AND kind='workspace_value' AND i" ++
            "d=?",
        &.{ .{ .blob = &child.task }, .{ .blob = &old_result_id } },
    );
    try store.createRecord(
        native.workspace.Value,
        "workspace_value",
        result.id,
        child.task,
        result,
    );
    try records.append(a, .{
        .kind = .workspace_value,
        .id = result.id,
        .body = try store.putObject(
            try contracts.encodeOwned(native.workspace.Value, a, result),
        ),
    });
    forged.result_value = result.artifact;
}

fn forgeInstrumentPublication(
    store: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    forged: native.workspace.Work,
) !void {
    var events = try store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
            "RE e.task=? AND e.seq=?",
        &.{ .{ .blob = &child.task }, .{ .integer = @intCast(child.event_watermark) } },
    );
    defer events.deinit();
    try std.testing.expect(try events.step() == .row);
    var event_value = (try contracts.decodeOwned(
        native.testing.state.Event,
        a,
        try events.bytes(0),
    )).value;
    const publications = try a.dupe(
        native.testing.state.WorkPublication,
        event_value.workspace_publications.items,
    );
    const observation = try store.putObject(try contracts.encodeOwned(
        native.workspace.WorkObservation,
        a,
        .{ .work = forged, .occurrence = null },
    ));
    for (publications) |*item| if (std.meta.eql(item.work, child.id)) {
        item.observation = observation.digest;
        item.checkpoint = forged.checkpoint;
        item.guest_work = forged.guest_work;
    };
    event_value.workspace_publications.items = publications;
    const event_ref = try store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, a, event_value),
    );
    try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{
        .blob = &event_ref.digest,
    }, .{ .blob = &child.task }, .{ .integer = @intCast(child.event_watermark) } });
}

fn expectInstrumentAnswerVariant(
    service: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    variant: usize,
    archive_records: []const native.testing.state.ArchiveRecord,
    old_result_id: [32]u8,
    old_answer_id: [32]u8,
    original_result: native.workspace.Value,
    original_answer: native.workspace.ValueArtifact,
    compiler_facts: anytype,
) !void {
    const store = &service.namespace.store;
    try store.begin();
    defer store.rollback();
    var forged = child;
    var records: std.ArrayList(native.testing.state.ArchiveRecord) = .empty;
    for (archive_records) |row| if (!std.meta.eql(
        row.id,
        old_result_id,
    ) and !std.meta.eql(row.id, old_answer_id)) try records.append(a, row);
    try store.database.run(
        "DELETE FROM records WHERE task=? AND kind='workspace_value' AND i" ++
            "d=?",
        &.{ .{ .blob = &child.task }, .{ .blob = &old_answer_id } },
    );
    if (variant == 0) {
        try forgeHypothesisInstrumentAnswer(store, a, child, original_answer, &records, &forged);
    } else forged.answer_value = null;
    forged.inputs.items = if (forged.answer_value) |ref| try a.dupe(
        native.testing.state.Reference,
        &.{ref},
    ) else &.{};
    if (variant == 2) {
        try forgeAlternativeInstrumentCheckpoint(store, a, child, &forged);
    }
    try forgeInstrumentResult(store, a, child, original_result, old_result_id, &records, &forged);
    try store.putRecord(native.workspace.Work, "workspace_work", child.id, child.task, forged);
    try forgeInstrumentPublication(store, a, child, forged);
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, child.task, records.items, compiler_facts),
    );
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
        const inbox = try interop.operationId(
            c.author,
            try @import("protean").inbox.Profile(DelegateTypes.Message).declare(c),
        );
        const workspace = try interop.operationId(
            c.author,
            try c.external(
                "workspace-delegation",
                try c.schema(DelegateTypes.Message),
                try c.schema(contracts.workspace.Reply),
                .read,
            ),
        );
        const inbox_schema = b.effects.items[@intCast(inbox)].result;
        const message_schema = b.schemas.items[@intCast(inbox_schema)].sum[1];
        const fields = b.schemas.items[@intCast(message_schema)].product;
        const entry = try b.declare(&.{unit}, unit, &.{ inbox, workspace }, &.{});
        const repeat = try b.term(.{
            .yield_then = try b.term(.{ .call = .{ .function = entry, .arguments = &.{
                try b.constant(void, {}),
            } } }),
        });
        const received = try b.variable(inbox_schema);
        const empty = try b.variable(unit);
        const message = try b.variable(message_schema);
        const id = try b.variable(fields[0]);
        const command = try b.variable(fields[1]);
        const ignored = try b.variable(output);
        const apply = try b.bind(
            ignored,
            try b.term(.{ .perform = .{
                .effect = workspace,
                .payload = try b.reference(command),
            } }),
            repeat,
        );
        const unpack = try b.term(.{ .unpack_product = .{
            .value = try b.reference(message),
            .variables = &.{ id, command },
            .body = apply,
        } });
        const select = try b.term(.{ .match_sum = .{ .value = try b.reference(
            received,
        ), .cases = &.{
            .{ .variable = empty, .body = repeat },
            .{ .variable = message, .body = unpack },
        } } });
        try b.define(
            entry,
            try b.bind(
                received,
                try b.term(.{ .perform = .{
                    .effect = inbox,
                    .payload = try b.constant(void, {}),
                } }),
                select,
            ),
        );
        return b.module(entry, unit);
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(contracts.workspace.Command, ctx.allocator, bytes);
        defer command.deinit();
        var model: ?native.workspace.ModelBinding = null;
        if (command.value == .work and command.value.work == .delegate and
            command.value.work.delegate.interpretation == .model)
        {
            const selection = command.value.work.delegate.interpretation.model;
            if (!std.mem.eql(u8, selection.profile_id.bytes, "fixture") or
                !std.mem.eql(u8, selection.effort.bytes, "medium")) return error.Denied;
            model = .{
                .profile_id = .{ .bytes = "fixture" },
                .profile_digest = @splat(7),
                .settings = .{
                    .endpoint = .{ .bytes = "https://localhost/v1/responses" },
                    .audience = .{ .bytes = "fixture" },
                    .model = .{ .bytes = "fixture" },
                    .effort = .{ .bytes = "medium" },
                    .max_output_tokens = null,
                    .request_bytes = null,
                    .response_bytes = null,
                    .timeout_ms = null,
                },
                .reasoning_mode = .{ .bytes = "standard" },
                .reasoning_context = .{ .bytes = "auto" },
            };
        }
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{
            .command = command.value,
            .snapshot = ctx.resources[0],
            .model = model,
        });
    }
};

fn inputPort(b: *source.Builder, text: bool) !source.Module {
    const unit = try b.scalar(void);
    const answer = if (text) try b.schema(.text) else try b.scalar(u64);
    const ask = try b.effect(.{
        .identity = "example/input",
        .payload = unit,
        .result = answer,
        .external = false,
    });
    const entry = try b.declare(&.{unit}, answer, &.{ask}, &.{});
    try b.define(
        entry,
        try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }),
    );
    return b.module(entry, unit);
}

fn expectDelegationMoveBlocked(
    service: anytype,
    a: std.mem.Allocator,
    task: native.testing.state.TaskId,
    target: [32]u8,
    instrument: [32]u8,
) !void {
    for ([_][32]u8{ target, instrument }) |id| {
        const subject: native.placement.Subject = .{ .task = task, .work = id };
        const head = service.namespace.store.head;
        const cut = try service.placementCut(a, subject);
        try std.testing.expectError(
            error.UnsettledOccurrence,
            service.placementFreeze(a, subject, "destination", cut, @splat(75)),
        );
        try std.testing.expectEqualDeep(head, service.namespace.store.head);
        try std.testing.expectEqualDeep(cut, try service.placementCut(a, subject));
    }
}

fn expectDelegationMoveAvailable(
    service: anytype,
    a: std.mem.Allocator,
    subject: native.placement.Subject,
) !void {
    const cut = try service.placementCut(a, subject);
    var transfer: [32]u8 = undefined;
    try service.io.randomSecure(&transfer);
    _ = try service.placementFreeze(a, subject, "destination", cut, transfer);
    try std.testing.expectEqual(.frozen, (try service.placementStatus(a, subject)).?.phase);
    try service.placementAbortUnsent(a, subject, transfer);
    try std.testing.expectEqual(.local, (try service.placementStatus(a, subject)).?.phase);
    try std.testing.expectEqualDeep(cut, try service.placementCut(a, subject));
}
test "OWN-02 OWN-05 OWN-10 typed answers preserve occurrence and root message independence" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try @import("protean").compile(
        a,
        @import("protean").system(.{
            .InitialArgs = void,
            .Result = void,
            .Failure = void,
            .application = DelegateApplication,
        }),
    );
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "delegation-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "delegation-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "delegation-unit",
        .manifest = manifest,
    };
    const declarations = [_]native.Declaration{
        native.inbox.declaration(DelegateTypes.Message),
        .{
            .identity = "workspace-delegation",
            .resource_role = "workspace",
            .kind = .workspace,
            .workspace = DelegateApplication.authorize,
            .payload_schema = WaitApplication.schema,
            .resume_schema = WaitApplication.result,
        },
        native.workspace_instrument.declaration(.model),
        native.workspace_instrument.declaration(.snapshot),
    };
    var handlers = try native.Registry.init(a, &declarations);
    defer handlers.deinit();
    try delegatedAnswerResources(.{
        .a = a,
        .io = io,
        .application = &application,
        .manifest = manifest,
        .assets = assets,
        .declarations = declarations,
        .handlers = &handlers,
    });
}

fn delegatedAnswerResources(fixture: anytype) !void {
    const text = "actual frozen evidence";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const snapshot = try contracts.encodeOwned(
        contracts.RepositorySnapshot,
        fixture.a,
        .{ .version = 2, .excluded_entries = 0, .files = .{ .items = &.{.{ .path = .{
            .bytes = "source.txt",
        }, .sha256 = digest, .contents = .{ .bytes = text } }} } },
    );
    defer fixture.a.free(snapshot);
    var grants: [fixture.declarations.len]native.registry.Grant = undefined;
    var profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "delegation-test", .resources = &.{snapshot}, .authority = .{
        .grants = &grants,
        .principal = "test",
        .tenant = "test",
        .inference = true,
    } };
    for (fixture.declarations, &grants) |declaration, *grant| grant.* = .{
        .identity = declaration.identity,
        .resource_role = declaration.resource_role,
        .resource_identity = try profile.resourceIdentity(
            fixture.a,
            fixture.application.*.image_identity,
        ),
    };
    try delegatedAnswerOwner(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .manifest = fixture.manifest,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .text = text,
        .snapshot = snapshot,
        .profile = &profile,
    });
}

fn delegatedAnswerOwner(fixture: anytype) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(fixture.io, &path_buffer);
    const path = try std.fmt.allocPrint(fixture.a, "{s}/state", .{path_buffer[0..length]});
    defer fixture.a.free(path);
    var namespace = try native.Namespace.open(fixture.a, fixture.io, path);
    var namespace_open = true;
    defer if (namespace_open) support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(DelegateTypes).init(
        fixture.a,
        fixture.io,
        &namespace,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile.*,
    );
    var service_open = true;
    defer if (service_open) support.expectCleanup(service.close(fixture.a));
    var arena = std.heap.ArenaAllocator.init(fixture.a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try delegatedAnswerPlacement(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .manifest = fixture.manifest,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .text = fixture.text,
        .snapshot = fixture.snapshot,
        .profile = fixture.profile,
        .path_buffer = &path_buffer,
        .length = length,
        .path = path,
        .namespace = &namespace,
        .namespace_open = &namespace_open,
        .service = &service,
        .service_open = &service_open,
        .scratch = scratch,
    });
}

fn delegatedAnswerPlacement(fixture: anytype) !void {
    const Scenario = enum {
        model,
        snapshot,
        snapshot_empty,
        model_unavailable,
        revoked,
        unknown,
        unknown_wait,
        not_sent_wait,
        cancel_capture,
        cancel_not_sent,
        cancel_park_not_sent,
        park_cancel_not_sent,
        invalid_capture,
        response_failed,
        response_incomplete,
        response_error,
    };
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(73));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(74));
    const Disclosure = struct {
        fn check(
            _: *anyopaque,
            _: native.placement.Subject,
            _: []const native.testing.state.Reference,
        ) !void {}
    };
    var disclosure: u8 = 0;
    var peers = [_]native.placement.Peer{.{
        .name = "destination",
        .site = .{ .key = destination_key.public_key.toBytes(), .namespace = @splat(74) },
        .native_build = fixture.profile.*.runtime_identity,
        .compatibility = .{
            .base = @splat(0),
            .admission = @splat(0),
            .bridge = @splat(0),
            .semantics = @splat(0),
            .private_state = @splat(0),
        },
        .resource_binding = try fixture.profile.*.resourceIdentity(
            fixture.scratch,
            fixture.application.*.image_identity,
        ),
        .disclosure_policy = @splat(74),
        .context = &disclosure,
        .disclose = Disclosure.check,
    }};
    const placement: native.placement.Configuration = .{
        .signing_key = source_key,
        .peers = &peers,
    };
    fixture.profile.*.placement = &placement;
    fixture.service.*.profile.placement = &placement;
    try delegatedAnswerCases(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .manifest = fixture.manifest,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .text = fixture.text,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .path = fixture.path,
        .namespace = fixture.namespace,
        .namespace_open = fixture.namespace_open,
        .service = fixture.service,
        .service_open = fixture.service_open,
        .scratch = fixture.scratch,
        .Scenario = Scenario,
        .peers = &peers,
    });
}

fn delegatedAnswerCases(fixture: anytype) !void {
    for (std.enums.values(fixture.Scenario)) |scenario| {
        try delegatedAnswerCase(fixture, scenario);
    }
    try delegatedAnswerPreviews(.{
        .a = fixture.a,
        .io = fixture.io,
        .application = fixture.application,
        .assets = fixture.assets,
        .handlers = fixture.handlers,
        .profile = fixture.profile,
        .path_buffer = fixture.path_buffer,
        .length = fixture.length,
        .path = fixture.path,
        .namespace = fixture.namespace,
        .namespace_open = fixture.namespace_open,
        .service = fixture.service,
        .service_open = fixture.service_open,
        .scratch = fixture.scratch,
    });
}
fn delegatedAnswerCase(fixture: anytype, scenario: anytype) !void {
    const snapshot_mode = scenario == .snapshot or scenario == .snapshot_empty;
    const successful = scenario == .model or snapshot_mode;
    const cancel_not_sent = switch (scenario) {
        .cancel_not_sent, .cancel_park_not_sent, .park_cancel_not_sent => true,
        else => false,
    };
    const suffix = @tagName(scenario);
    const parent = try fixture.service.*.submit(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "parent-{s}", .{suffix}),
        {},
    );
    var builder = source.Builder.init(fixture.a);
    defer builder.deinit();
    const source_text = try native.source_records.encode(
        fixture.scratch,
        try inputPort(&builder, snapshot_mode),
    );
    const built_reply = try fixture.service.*.workspaceCommand(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "build-{s}", .{suffix}),
        parent.receipt.task,
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = source_text,
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{
            .effect = 0,
            .class = .input,
        }} } } } },
    );
    try std.testing.expect(built_reply.program != null);
    const target_start = try fixture.service.*.workspaceStart(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "start-{s}", .{suffix}),
        parent.receipt.task,
        try nativeIdentity(built_reply.program.?),
        &.{},
        .{},
    );
    const target_id = target_start.receipt.workspace.?;
    fixture.peers.*[0].compatibility = try fixture.service.*.placementCompatibility(
        fixture.scratch,
        .{ .task = parent.receipt.task, .work = target_id },
    );
    if (scenario == .model) try expectDelegationMoveAvailable(
        &fixture.service.*,
        fixture.scratch,
        .{ .task = parent.receipt.task, .work = target_id },
    );
    try delegatedAnswerInterpretation(
        fixture,
        scenario,
        snapshot_mode,
        successful,
        cancel_not_sent,
        suffix,
        parent,
        built_reply,
        target_id,
    );
}
fn delegatedAnswerInterpretation(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    successful: anytype,
    cancel_not_sent: anytype,
    suffix: anytype,
    parent: anytype,
    built_reply: anytype,
    target_id: anytype,
) !void {
    var target = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        target_id,
    );
    defer target.deinit();
    var port = try contracts.decodeOwned(
        native.workspace.Port,
        fixture.scratch,
        try fixture.namespace.*.store.object(
            fixture.scratch,
            target.value.current_port.?,
            null,
        ),
    );
    defer port.deinit();
    const port_ref = try workspaceRef(fixture.scratch, .port, port.value.id);
    const interpretation: contracts.workspace.Interpretation = if (snapshot_mode) .{
        .snapshot = .{
            .port = port_ref,
            .generation = port.value.generation,
            .path = .{ .bytes = "source.txt" },
            .offset = 0,
            .maximum = if (scenario == .snapshot_empty) 0 else fixture.text.len,
        },
    } else .{
        .model = .{ .port = port_ref, .generation = port.value.generation, .profile_id = .{
            .bytes = "fixture",
        }, .effort = .{ .bytes = "medium" }, .subproblem = .{
            .bytes = "Return forty-two as the selected hypothetical value.",
        }, .inputs = .{ .items = &.{} } },
    };
    _ = try fixture.service.*.message(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "delegate-{s}", .{suffix}),
        parent.receipt.task,
        .{ .work = .{ .delegate = .{
            .expected = .{
                .work = try workspaceRef(fixture.scratch, .work, target_id),
                .execution_revision = target.value.execution_revision,
                .control_revision = target.value.control_revision,
            },
            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
            .interpretation = interpretation,
        } } },
    );
    try delegatedAnswerDrive(
        fixture,
        scenario,
        snapshot_mode,
        successful,
        cancel_not_sent,
        suffix,
        parent,
        built_reply,
        target_id,
        &target,
    );
}
fn delegatedAnswerDrive(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    successful: anytype,
    cancel_not_sent: anytype,
    suffix: anytype,
    parent: anytype,
    built_reply: anytype,
    target_id: anytype,
    target: anytype,
) !void {
    var dispatches: usize = 0;
    var instrument_id: ?[32]u8 = null;
    var resumed_handoff = false;
    for (0..256) |_| {
        try delegatedAnswerFindInstrument(
            fixture,
            scenario,
            successful,
            parent,
            target_id,
            target,
            &instrument_id,
        );
        const step = try fixture.service.*.pump(fixture.scratch);
        if (step == .work) {
            try delegatedAnswerDispatch(
                fixture,
                scenario,
                snapshot_mode,
                successful,
                cancel_not_sent,
                suffix,
                parent,
                &dispatches,
                &instrument_id,
                step,
            );
        }
        if (try delegatedAnswerDriveResult(
            fixture,
            scenario,
            successful,
            suffix,
            parent,
            target_id,
            &instrument_id,
            &resumed_handoff,
            step,
        )) break;
    }
    try delegatedAnswerResults(
        fixture,
        scenario,
        snapshot_mode,
        successful,
        suffix,
        parent,
        built_reply,
        target_id,
        target,
        &dispatches,
        &instrument_id,
        &resumed_handoff,
    );
}
fn delegatedAnswerDriveResult(
    fixture: anytype,
    scenario: anytype,
    successful: anytype,
    suffix: anytype,
    parent: anytype,
    target_id: anytype,
    instrument_id: anytype,
    resumed_handoff: anytype,
    step: anytype,
) !bool {
    var result = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        target_id,
    );
    defer result.deinit();
    try delegatedAnswerRestoreHandoff(
        fixture,
        scenario,
        successful,
        suffix,
        parent,
        target_id,
        &instrument_id.*,
        &resumed_handoff.*,
        result,
    );
    return result.value.outcome_kind == .completed or (instrument_id.* != null and step == .idle);
}

fn delegatedAnswerFindInstrument(
    fixture: anytype,
    scenario: anytype,
    successful: anytype,
    parent: anytype,
    target_id: anytype,
    target: anytype,
    instrument_id: anytype,
) !void {
    if (instrument_id.* == null) {
        var rows = try fixture.namespace.*.store.database.prepare(
            "SELECT body FROM records WHERE task=? AND kind='workspace_work'",
            &.{.{ .blob = &parent.receipt.task }},
        );
        defer rows.deinit();
        while (try rows.step() == .row) {
            const bytes = try rows.bytes(0);
            const ref = try fixture.namespace.*.store.objectReference(bytes[0..32].*, null);
            var candidate = try contracts.decodeOwned(
                native.workspace.Work,
                fixture.scratch,
                try fixture.namespace.*.store.object(fixture.scratch, ref, null),
            );
            defer candidate.deinit();
            if (candidate.value.delegation != null) instrument_id.* = candidate.value.id;
        }
        if (successful and instrument_id.* != null) try expectDelegationMoveBlocked(
            &fixture.service.*,
            fixture.scratch,
            parent.receipt.task,
            target_id,
            instrument_id.*.?,
        );
        if (scenario == .model and instrument_id.* != null) {
            try delegatedAnswerRejectMissingTarget(
                fixture,
                parent,
                target_id,
                target,
                instrument_id,
            );
        }
        if (scenario == .revoked and instrument_id.* != null) {
            var current = try fixture.service.*.workspaceWork(
                fixture.scratch,
                parent.receipt.task,
                target_id,
            );
            defer current.deinit();
            _ = try fixture.service.*.workspaceControl(
                fixture.scratch,
                "revoke-delegation",
                parent.receipt.task,
                target_id,
                current.value.execution_revision,
                current.value.control_revision,
                .park,
            );
        }
    }
}
fn delegatedAnswerRestoreHandoff(
    fixture: anytype,
    scenario: anytype,
    successful: anytype,
    suffix: anytype,
    parent: anytype,
    target_id: anytype,
    instrument_id: anytype,
    resumed_handoff: anytype,
    result: anytype,
) !void {
    if (successful and !resumed_handoff.* and instrument_id.* != null) {
        var completed = try fixture.service.*.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            instrument_id.*.?,
        );
        defer completed.deinit();
        if (completed.value.answer_value != null) {
            try std.testing.expectEqual(.completed, completed.value.outcome_kind);
            try std.testing.expectEqual(.requested, result.value.outcome_kind);
            try expectDelegationMoveBlocked(
                &fixture.service.*,
                fixture.scratch,
                parent.receipt.task,
                target_id,
                instrument_id.*.?,
            );
            if (scenario == .model) try expectModelRequestBudget(
                &fixture.service.*,
                fixture.scratch,
                completed.value,
            );
            try expectInstrumentAnswerBound(
                &fixture.service.*,
                fixture.scratch,
                completed.value,
            );
            try delegatedAnswerReopenHandoff(fixture, suffix, parent, resumed_handoff);
        }
    }
}
fn delegatedAnswerReopenHandoff(
    fixture: anytype,
    suffix: anytype,
    parent: anytype,
    resumed_handoff: anytype,
) !void {
    try fixture.service.*.close(fixture.scratch);
    fixture.service_open.* = false;
    try fixture.namespace.*.close();
    fixture.namespace_open.* = false;
    fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    fixture.namespace_open.* = true;
    fixture.service.* = try native.tasks.Service(DelegateTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile.*,
    );
    fixture.service_open.* = true;
    try std.testing.expectEqual(.idle, try fixture.service.*.pump(fixture.scratch));
    var paused = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
    defer paused.deinit();
    _ = try fixture.service.*.resumeTask(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "resume-completed-answer-{s}", .{suffix}),
        parent.receipt.task,
        paused.value.revision,
    );
    resumed_handoff.* = true;
}

fn delegatedAnswerRejectMissingTarget(
    fixture: anytype,
    parent: anytype,
    target_id: anytype,
    target: anytype,
    instrument_id: anytype,
) !void {
    // Keep the admitted instrument but omit the other half of
    // the same delegation, restoring its prior valid target.
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture.manifest, &manifest_digest, .{});
    const archive_index = try fixture.namespace.*.store.archiveIndex(
        fixture.scratch,
        parent.receipt.task,
        .{ .digest = manifest_digest, .bytes = fixture.manifest.len },
    );
    var compiler_facts = try fixture.service.*.prepareWorkspaceValidation(
        parent.receipt.task,
    );
    defer compiler_facts.deinit();
    try fixture.namespace.*.store.begin();
    defer fixture.namespace.*.store.rollback();
    var events = try fixture.namespace.*.store.database.prepare(
        "SELECT seq,o.body FROM events e JOIN objects o ON o.digest=e.body" ++
            " WHERE e.task=? ORDER BY seq DESC",
        &.{.{ .blob = &parent.receipt.task }},
    );
    defer events.deinit();
    var changed = false;
    while (try events.step() == .row) {
        try delegatedAnswerRemovePublication(
            fixture,
            &events,
            instrument_id,
            target_id,
            parent,
            &changed,
        );
        if (changed) break;
    }
    try std.testing.expect(changed);
    try fixture.namespace.*.store.putRecord(
        native.workspace.Work,
        "workspace_work",
        target_id,
        parent.receipt.task,
        target.*.value,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        fixture.service.*.validateWorkspaceRecordsPrepared(
            fixture.scratch,
            parent.receipt.task,
            archive_index.records.items,
            &compiler_facts,
        ),
    );
}
fn delegatedAnswerRemovePublication(
    fixture: anytype,
    events: anytype,
    instrument_id: anytype,
    target_id: anytype,
    parent: anytype,
    changed: anytype,
) !void {
    var event_value = try contracts.decodeOwned(
        native.testing.state.Event,
        fixture.scratch,
        try events.*.bytes(1),
    );
    const publications = event_value.value.workspace_publications.items;
    if (publications.len != 2 or !std.meta.eql(
        publications[0].work,
        instrument_id.*.?,
    )) return;
    try std.testing.expectEqualDeep(target_id, publications[1].work);
    event_value.value.workspace_publications.items = publications[0..1];
    const rewritten = try fixture.namespace.*.store.putObject(
        try contracts.encodeOwned(
            native.testing.state.Event,
            fixture.scratch,
            event_value.value,
        ),
    );
    try fixture.namespace.*.store.database.run(
        "UPDATE events SET body=? WHERE task=? AND seq=?",
        &.{
            .{ .blob = &rewritten.digest },
            .{ .blob = &parent.receipt.task },
            .{ .integer = try events.*.integer(0) },
        },
    );
    changed.* = true;
}

fn delegatedAnswerDispatch(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    successful: anytype,
    cancel_not_sent: anytype,
    suffix: anytype,
    parent: anytype,
    dispatches: anytype,
    instrument_id: anytype,
    step: anytype,
) !void {
    try std.testing.expect(scenario != .revoked);
    dispatches.* += 1;
    try std.testing.expectEqual(@as(usize, 1), dispatches.*);
    try std.testing.expect(step.work.subject_work != null);
    instrument_id.* = step.work.subject_work;
    if (successful) {
        try delegatedAnswerRefreshActive(fixture, scenario, suffix, parent, instrument_id);
    }
    var root = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
    defer root.deinit();
    try std.testing.expect(
        !std.meta.eql(root.value.current_occurrence, step.work.occurrence),
    );
    const wait_for_failure = switch (scenario) {
        .unknown_wait, .not_sent_wait, .cancel_capture => true,
        else => false,
    };
    var waiting_revision: u64 = 0;
    if (wait_for_failure) {
        try delegatedAnswerWaitForFailure(
            fixture,
            suffix,
            parent,
            instrument_id,
            &waiting_revision,
        );
    } else _ = try fixture.service.*.message(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "amend-{s}", .{suffix}),
        parent.receipt.task,
        .{ .context = .{ .inspect = .{ .page = .{} } } },
    );
    try delegatedAnswerCancellation(
        fixture,
        scenario,
        snapshot_mode,
        cancel_not_sent,
        suffix,
        parent,
        instrument_id,
        step,
        &waiting_revision,
    );
}
fn delegatedAnswerWaitForFailure(
    fixture: anytype,
    suffix: anytype,
    parent: anytype,
    instrument_id: anytype,
    waiting_revision: anytype,
) !void {
    var active_child = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer active_child.deinit();
    _ = try fixture.service.*.message(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "wait-{s}", .{suffix}),
        parent.receipt.task,
        .{ .work = .{ .wait = .{
            .works = .{ .items = &.{
                try workspaceRef(fixture.scratch, .work, instrument_id.*.?),
            } },
            .after = active_child.value.event_watermark,
        } } },
    );
    for (0..32) |_| {
        const root_step = try fixture.service.*.pump(fixture.scratch);
        try std.testing.expect(root_step != .work);
        if (root_step == .idle) break;
    }
    var waiting_root = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
    defer waiting_root.deinit();
    try std.testing.expectEqual(.parked, waiting_root.value.schedule);
    waiting_revision.* = waiting_root.value.execution_revision;
}

fn delegatedAnswerCancellation(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    cancel_not_sent: anytype,
    suffix: anytype,
    parent: anytype,
    instrument_id: anytype,
    step: anytype,
    waiting_revision: anytype,
) !void {
    var wrong = step.work;
    wrong.subject_work = @splat(99);
    try std.testing.expectError(
        error.StaleOccurrence,
        fixture.service.*.acquire(fixture.scratch, wrong, ""),
    );
    if (scenario == .park_cancel_not_sent) {
        var active = try fixture.service.*.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            instrument_id.*.?,
        );
        defer active.deinit();
        _ = try fixture.service.*.workspaceControl(
            fixture.scratch,
            "park-before-cancel",
            parent.receipt.task,
            instrument_id.*.?,
            active.value.execution_revision,
            active.value.control_revision,
            .park,
        );
    }
    if (scenario == .unknown or scenario == .cancel_capture or cancel_not_sent) {
        try delegatedAnswerCancelPending(fixture, scenario, suffix, parent, instrument_id, step);
    }
    if (scenario == .cancel_park_not_sent) {
        var cancelling = try fixture.service.*.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            instrument_id.*.?,
        );
        defer cancelling.deinit();
        _ = try fixture.service.*.workspaceControl(
            fixture.scratch,
            "park-after-cancel",
            parent.receipt.task,
            instrument_id.*.?,
            cancelling.value.execution_revision,
            cancelling.value.control_revision,
            .park,
        );
    }
    try delegatedAnswerSettlement(
        fixture,
        scenario,
        snapshot_mode,
        cancel_not_sent,
        parent,
        instrument_id,
        step,
        waiting_revision,
    );
}
fn delegatedAnswerSettlement(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    cancel_not_sent: anytype,
    parent: anytype,
    instrument_id: anytype,
    step: anytype,
    waiting_revision: anytype,
) !void {
    if (cancel_not_sent) {
        try delegatedAnswerNotSent(fixture, scenario, parent, instrument_id, step);
    } else if (scenario == .unknown) {
        try fixture.service.*.unknown(fixture.scratch, step.work);
        _ = try fixture.service.*.requestCancel(
            fixture.scratch,
            "cancel-parent-with-unknown-child",
            parent.receipt.task,
            "",
        );
    } else if (scenario == .unknown_wait or scenario == .not_sent_wait) {
        if (scenario == .unknown_wait) try fixture.service.*.unknown(
            fixture.scratch,
            step.work,
        ) else try fixture.service.*.notSent(fixture.scratch, step.work);
        for (0..32) |_| {
            const root_step = try fixture.service.*.pump(fixture.scratch);
            try std.testing.expect(root_step != .work);
            if (root_step == .idle) break;
        }
        var awakened = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
        defer awakened.deinit();
        try std.testing.expect(awakened.value.execution_revision > waiting_revision.*);
    } else if (snapshot_mode) {
        const worker = try native.testing.Worker.init(fixture.a, fixture.io);
        defer support.expectCleanup(worker.deinit(fixture.a));
        try worker.start(step.work, fixture.profile.*.authority, null);
        while (!worker.finished()) try fixture.io.sleep(.fromMilliseconds(1), .awake);
        try worker.join();
        try fixture.service.*.completeWork(fixture.scratch, step.work, worker.result.?);
        try worker.release();
        if (scenario == .snapshot_empty) {
            var parked = try fixture.service.*.workspaceWork(
                fixture.scratch,
                parent.receipt.task,
                instrument_id.*.?,
            );
            defer parked.deinit();
            try std.testing.expectEqual(.parked, parked.value.schedule);
            try std.testing.expect(parked.value.answer_value == null);
            _ = try fixture.service.*.workspaceControl(
                fixture.scratch,
                "resume-after-capture",
                parent.receipt.task,
                instrument_id.*.?,
                parked.value.execution_revision,
                parked.value.control_revision,
                .{ .delegate = parked.value.policy },
            );
        }
    } else {
        try delegatedAnswerModelCapture(fixture, scenario, step);
    }
}
fn delegatedAnswerModelCapture(fixture: anytype, scenario: anytype, step: anytype) !void {
    const raw = try contracts.encodeOwned(
        native.responses.Raw,
        fixture.scratch,
        .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{
            .bytes = "{\"output\":[{\"type\":\"function_call\",\"status\":\"completed\"" ++
                ",\"call_id\":\"typed-answer\",\"name\":\"answer\",\"arguments\":" ++
                "\"{\\\"json_value\\\":\\\"\\\\\\\"42\\\\\\\"\\\"}\"}],\"usage\":{" ++
                "\"output_tokens\":7}}",
        } },
    );
    var response = try contracts.decodeOwned(native.responses.Raw, fixture.scratch, raw);
    defer response.deinit();
    const envelope = try std.fmt.allocPrint(
        fixture.scratch,
        "{{\"status\":\"{s}\",\"error\":{s},{s}",
        .{
            switch (scenario) {
                .response_failed => "failed",
                .response_incomplete => "incomplete",
                else => "completed",
            },
            if (scenario == .response_error) "{}" else "null",
            response.value.body.bytes[1..],
        },
    );
    response.value.body.bytes = envelope;
    if (scenario == .model_unavailable) {
        response.value.body.bytes = "{\"status\":\"completed\",\"error\":null," ++
            "\"output\":[],\"usage\":" ++
            "{\"output_tokens\":0}}";
    }
    const captured = try contracts.encodeOwned(
        native.responses.Raw,
        fixture.scratch,
        response.value,
    );
    try fixture.service.*.acquire(
        fixture.scratch,
        step.work,
        if (scenario == .invalid_capture) "malformed controlled capture" else captured,
    );
}

fn delegatedAnswerNotSent(
    fixture: anytype,
    scenario: anytype,
    parent: anytype,
    instrument_id: anytype,
    step: anytype,
) !void {
    var before = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer before.deinit();
    try fixture.service.*.notSent(fixture.scratch, step.work);
    var after_completion = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer after_completion.deinit();
    try std.testing.expectEqualDeep(
        before.value.checkpoint,
        after_completion.value.checkpoint,
    );
    try std.testing.expectEqual(
        before.value.execution_revision,
        after_completion.value.execution_revision,
    );
    try std.testing.expectEqual(
        before.value.control_revision,
        after_completion.value.control_revision,
    );
    try std.testing.expectEqual(
        @as(
            native.testing.state.Schedule,
            if (scenario == .cancel_park_not_sent) .parked else .queued,
        ),
        after_completion.value.schedule,
    );
    try delegatedAnswerSuspendCancellation(
        fixture,
        scenario,
        parent,
        instrument_id,
        &after_completion,
    );
}
fn delegatedAnswerSuspendCancellation(
    fixture: anytype,
    scenario: anytype,
    parent: anytype,
    instrument_id: anytype,
    after_completion: anytype,
) !void {
    if (scenario == .cancel_not_sent) {
        _ = try fixture.service.*.workspacePump(
            fixture.scratch,
            "suspend-instrument-cancel",
            parent.receipt.task,
            .{
                .expected = .{
                    .work = try workspaceRef(fixture.scratch, .work, instrument_id.*.?),
                    .execution_revision = after_completion.*.value.execution_revision,
                    .control_revision = after_completion.*.value.control_revision,
                },
                .base_quantum = 1,
            },
        );
        var suspended = try fixture.service.*.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            instrument_id.*.?,
        );
        defer suspended.deinit();
        try std.testing.expect(suspended.value.outer_operation != null);
        try fixture.service.*.validateWorkspace(fixture.scratch, parent.receipt.task);
        for ([_]@FieldType(contracts.workspace.Policy, "continuation"){
            .explicit_only,
            .owner_scheduled,
        }) |continuation| {
            try delegatedAnswerRetainedContinuation(
                fixture,
                parent,
                instrument_id,
                continuation,
                suspended,
            );
        }
    }
}

fn delegatedAnswerRetainedContinuation(
    fixture: anytype,
    parent: anytype,
    instrument_id: anytype,
    continuation: anytype,
    suspended: anytype,
) !void {
    var before_delegate = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer before_delegate.deinit();
    _ = try fixture.service.*.workspaceControl(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "delegate-suspended-{s}", .{
            @tagName(continuation),
        }),
        parent.receipt.task,
        instrument_id.*.?,
        before_delegate.value.execution_revision,
        before_delegate.value.control_revision,
        .{ .delegate = .{ .stop = .terminal, .continuation = continuation } },
    );
    var delegated = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer delegated.deinit();
    try std.testing.expectEqualDeep(
        suspended.value.outer_operation,
        delegated.value.outer_operation,
    );
    try std.testing.expectEqual(
        suspended.value.execution_revision,
        delegated.value.execution_revision,
    );
    try std.testing.expectEqual(
        @as(
            native.testing.state.Schedule,
            if (continuation == .explicit_only) .parked else .queued,
        ),
        delegated.value.schedule,
    );
    const occurrence_bytes = (try fixture.namespace.*.store.recordBytes(
        fixture.scratch,
        "occurrence",
        delegated.value.current_occurrence.?,
        parent.receipt.task,
    )).?;
    var pending = try contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        fixture.scratch,
        occurrence_bytes,
    );
    defer pending.deinit();
    try std.testing.expect(pending.value.state == .not_sent);
    try fixture.service.*.validateWorkspace(fixture.scratch, parent.receipt.task);
}

fn delegatedAnswerCancelPending(
    fixture: anytype,
    scenario: anytype,
    suffix: anytype,
    parent: anytype,
    instrument_id: anytype,
    step: anytype,
) !void {
    var pending_child = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer pending_child.deinit();
    var guarded: AfterCommitAllocator = .{
        .backing = fixture.scratch,
        .namespace = &fixture.namespace.*,
        .generation = fixture.namespace.*.store.head.generation,
    };
    _ = try fixture.service.*.workspaceControl(
        guarded.allocator(),
        try std.fmt.allocPrint(fixture.scratch, "cancel-{s}", .{suffix}),
        parent.receipt.task,
        instrument_id.*.?,
        pending_child.value.execution_revision,
        pending_child.value.control_revision,
        .{ .cancel = .{
            .bytes = if (scenario == .unknown) "" else "cancel explicitly delegated judgment",
        } },
    );
    try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
    try std.testing.expect(try fixture.service.*.shouldCancelWork(step.work));
}

fn delegatedAnswerRefreshActive(
    fixture: anytype,
    scenario: anytype,
    suffix: anytype,
    parent: anytype,
    instrument_id: anytype,
) !void {
    var active = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer active.deinit();
    const operation_id = try std.fmt.allocPrint(
        fixture.scratch,
        "refresh-in-flight-{s}",
        .{suffix},
    );
    const refreshed = try fixture.service.*.workspaceControl(
        fixture.scratch,
        operation_id,
        parent.receipt.task,
        instrument_id.*.?,
        active.value.execution_revision,
        active.value.control_revision,
        .{ .delegate = active.value.policy },
    );
    const replayed = try fixture.service.*.workspaceControl(
        fixture.scratch,
        operation_id,
        parent.receipt.task,
        instrument_id.*.?,
        active.value.execution_revision,
        active.value.control_revision,
        .{ .delegate = active.value.policy },
    );
    try std.testing.expectEqualDeep(refreshed.receipt, replayed.receipt);
    var current = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer current.deinit();
    try std.testing.expectEqual(.active, current.value.schedule);
    try std.testing.expectEqual(
        active.value.execution_revision,
        current.value.execution_revision,
    );
    try std.testing.expectEqual(
        active.value.control_revision + 1,
        current.value.control_revision,
    );
    if (scenario == .snapshot_empty) _ = try fixture.service.*.workspaceControl(
        fixture.scratch,
        "park-in-flight",
        parent.receipt.task,
        instrument_id.*.?,
        current.value.execution_revision,
        current.value.control_revision,
        .park,
    );
}

fn delegatedAnswerResults(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    successful: anytype,
    suffix: anytype,
    parent: anytype,
    built_reply: anytype,
    target_id: anytype,
    target: anytype,
    dispatches: anytype,
    instrument_id: anytype,
    resumed_handoff: anytype,
) !void {
    try std.testing.expectEqual(@as(usize, if (scenario == .revoked) 0 else 1), dispatches.*);
    if (scenario == .model) try std.testing.expect(resumed_handoff.*);
    var result = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        target_id,
    );
    defer result.deinit();
    var child = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer child.deinit();
    if (!successful) {
        try delegatedAnswerFailedResult(fixture, scenario, parent, target, result, child);
    } else {
        try delegatedAnswerSuccessfulResult(
            fixture,
            scenario,
            snapshot_mode,
            parent,
            result,
            child,
        );
    }
    try delegatedAnswerIndependentSubjects(
        fixture,
        scenario,
        snapshot_mode,
        successful,
        suffix,
        parent,
        built_reply,
        target_id,
        instrument_id,
        &result,
        &child,
    );
}
fn delegatedAnswerFailedResult(
    fixture: anytype,
    scenario: anytype,
    parent: anytype,
    target: anytype,
    result: anytype,
    child: anytype,
) !void {
    if (scenario == .unknown) {
        try std.testing.expectEqual(.cancelled, result.value.outcome_kind);
        var root = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
        defer root.deinit();
        try std.testing.expect(root.value.terminal());
        try std.testing.expect(
            !try fixture.service.*.taskCleanupComplete(fixture.scratch, root.value),
        );
    } else {
        try std.testing.expectEqual(.requested, result.value.outcome_kind);
        try std.testing.expectEqualDeep(
            target.*.value.current_port,
            result.value.current_port,
        );
    }
    try std.testing.expect(child.value.answer_value == null);
    try std.testing.expect(
        !try fixture.service.*.associatedWorkDisposed(fixture.scratch, parent.receipt.task),
    );
    if (scenario == .cancel_capture or scenario == .cancel_not_sent or
        scenario == .park_cancel_not_sent)
    {
        try std.testing.expectEqual(.cancelled, child.value.outcome_kind);
        try std.testing.expect(child.value.cancellation_applied);
    } else if (scenario == .model_unavailable) {
        try std.testing.expectEqual(.completed, child.value.outcome_kind);
        try std.testing.expect(child.value.current_occurrence == null);
    } else {
        try delegatedAnswerPendingFailure(fixture, scenario, parent, child);
    }
}
fn delegatedAnswerPendingFailure(
    fixture: anytype,
    scenario: anytype,
    parent: anytype,
    child: anytype,
) !void {
    const bytes = (try fixture.namespace.*.store.recordBytes(
        fixture.scratch,
        "occurrence",
        child.value.current_occurrence.?,
        parent.receipt.task,
    )).?;
    var pending = try contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        fixture.scratch,
        bytes,
    );
    defer pending.deinit();
    switch (scenario) {
        .revoked => {
            try std.testing.expectEqual(.ready, pending.value.state);
            try std.testing.expectEqual(.denied, child.value.blocker.?);
        },
        .unknown => {
            try std.testing.expect(pending.value.state == .unknown);
            try std.testing.expect(
                try fixture.service.*.shutdownIncomplete(fixture.scratch),
            );
        },
        .unknown_wait => try std.testing.expect(pending.value.state == .unknown),
        .not_sent_wait => try std.testing.expect(pending.value.state == .not_sent),
        .cancel_park_not_sent => {
            try std.testing.expect(pending.value.state == .not_sent);
            try std.testing.expectEqual(.parked, child.value.schedule);
            try std.testing.expect(
                child.value.cancellation != null and !child.value.cancellation_applied,
            );
        },
        .invalid_capture, .response_failed, .response_incomplete, .response_error => {
            try std.testing.expect(pending.value.state == .captured);
        },
        else => unreachable,
    }
}

fn delegatedAnswerSuccessfulResult(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    parent: anytype,
    result: anytype,
    child: anytype,
) !void {
    try std.testing.expectEqual(.completed, result.value.outcome_kind);
    try std.testing.expect(child.value.answer_value != null);
    var artifact = try contracts.decodeOwned(
        native.workspace.ValueArtifact,
        fixture.scratch,
        try fixture.namespace.*.store.object(
            fixture.scratch,
            child.value.answer_value.?,
            null,
        ),
    );
    defer artifact.deinit();
    var derivation = try contracts.decodeOwned(
        native.workspace.Derivation,
        fixture.scratch,
        try fixture.namespace.*.store.object(
            fixture.scratch,
            artifact.value.provenance,
            null,
        ),
    );
    defer derivation.deinit();
    try std.testing.expectEqual(
        @as(@TypeOf(derivation.value.kind), if (snapshot_mode) .acquisition else .judgment),
        derivation.value.kind,
    );
    const result_bytes = try fixture.namespace.*.store.object(
        fixture.scratch,
        result.value.result.?,
        null,
    );
    if (snapshot_mode) {
        var actual = try contracts.decodeOwned(
            contracts.Utf8,
            fixture.scratch,
            result_bytes,
        );
        defer actual.deinit();
        try std.testing.expectEqualStrings(
            if (scenario == .snapshot_empty) "" else fixture.text,
            actual.value.bytes,
        );
    } else {
        var actual = try contracts.decodeOwned(u64, fixture.scratch, result_bytes);
        defer actual.deinit();
        try std.testing.expectEqual(@as(u64, 42), actual.value);
        var root = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
        defer root.deinit();
        try std.testing.expectEqual(@as(u64, 1), root.value.inference_attempts);
        try std.testing.expectEqual(@as(u64, 7), root.value.inference_output_tokens);
    }
}

fn delegatedAnswerIndependentSubjects(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    successful: anytype,
    suffix: anytype,
    parent: anytype,
    built_reply: anytype,
    target_id: anytype,
    instrument_id: anytype,
    result: anytype,
    child: anytype,
) !void {
    if (scenario == .model) {
        try delegatedAnswerEquivalentInputs(fixture, parent, built_reply, result);
    }
    try delegatedAnswerArchives(
        fixture,
        scenario,
        snapshot_mode,
        successful,
        suffix,
        parent,
        target_id,
        instrument_id,
        result,
        child,
    );
}
fn delegatedAnswerEquivalentInputs(
    fixture: anytype,
    parent: anytype,
    built_reply: anytype,
    result: anytype,
) !void {
    // OWN-02/14: the identical typed request can be answered directly,
    // by a pure computation, or by the model above. Equal request bytes
    // do not make the two retained subjects share settlement authority.
    const direct_start = try fixture.service.*.workspaceStart(
        fixture.scratch,
        "answer-direct-start",
        parent.receipt.task,
        try nativeIdentity(built_reply.program.?),
        &.{},
        .{},
    );
    const computed_start = try fixture.service.*.workspaceStart(
        fixture.scratch,
        "answer-computed-start",
        parent.receipt.task,
        try nativeIdentity(built_reply.program.?),
        &.{},
        .{},
    );
    var direct = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        direct_start.receipt.workspace.?,
    );
    defer direct.deinit();
    var computed = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        computed_start.receipt.workspace.?,
    );
    defer computed.deinit();
    try std.testing.expect(
        !std.meta.eql(direct.value.current_occurrence, computed.value.current_occurrence),
    );
    try delegatedAnswerIndependentPorts(fixture, parent, result, &direct, &computed);
}
fn delegatedAnswerIndependentPorts(
    fixture: anytype,
    parent: anytype,
    result: anytype,
    direct: anytype,
    computed: anytype,
) !void {
    var direct_port = try contracts.decodeOwned(
        native.workspace.Port,
        fixture.scratch,
        try fixture.namespace.*.store.object(
            fixture.scratch,
            direct.*.value.current_port.?,
            null,
        ),
    );
    defer direct_port.deinit();
    var computed_port = try contracts.decodeOwned(
        native.workspace.Port,
        fixture.scratch,
        try fixture.namespace.*.store.object(
            fixture.scratch,
            computed.*.value.current_port.?,
            null,
        ),
    );
    defer computed_port.deinit();
    try std.testing.expectEqualDeep(direct_port.value.request, computed_port.value.request);
    try delegatedAnswerPureComputation(
        fixture,
        parent,
        result,
        &direct.*,
        &computed.*,
        &direct_port,
        &computed_port,
    );
}

fn delegatedAnswerPureComputation(
    fixture: anytype,
    parent: anytype,
    result: anytype,
    direct: anytype,
    computed: anytype,
    direct_port: anytype,
    computed_port: anytype,
) !void {
    var algorithm = source.Builder.init(fixture.a);
    defer algorithm.deinit();
    var diagnostic: native.program_construction.Diagnostic = .{};
    const pure_program = try fixture.service.*.workspaceBuild(
        fixture.scratch,
        "answer-pure-build",
        parent.receipt.task,
        try native.source_records.encode(fixture.scratch, try gcd(&algorithm)),
        &diagnostic,
    );
    const pure_start = try fixture.service.*.workspaceStart(
        fixture.scratch,
        "answer-pure-start",
        parent.receipt.task,
        pure_program.receipt.workspace.?,
        try contracts.encodeOwned(struct {
            u64,
            u64,
        }, fixture.scratch, .{ 84, 42 }),
        .{},
    );
    var pure = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        pure_start.receipt.workspace.?,
    );
    defer pure.deinit();
    try std.testing.expectEqual(.completed, pure.value.outcome_kind);
    try delegatedAnswerEquivalentResults(
        fixture,
        parent,
        result,
        direct,
        computed,
        direct_port,
        computed_port,
        &pure,
    );
}
fn delegatedAnswerEquivalentResults(
    fixture: anytype,
    parent: anytype,
    result: anytype,
    direct: anytype,
    computed: anytype,
    direct_port: anytype,
    computed_port: anytype,
    pure: anytype,
) !void {
    for ([_]native.workspace.Work{
        direct.*.value,
        computed.*.value,
    }, [_]native.workspace.Port{
        direct_port.*.value,
        computed_port.*.value,
    }, 0..) |recipient, recipient_port, i| {
        try delegatedAnswerEquivalentResult(
            fixture,
            parent,
            pure,
            recipient,
            recipient_port,
            i,
            result,
        );
    }
    var root = try fixture.service.*.task(fixture.scratch, parent.receipt.task);
    defer root.deinit();
    try std.testing.expectEqual(@as(u64, 1), root.value.inference_attempts);
}
fn delegatedAnswerEquivalentResult(
    fixture: anytype,
    parent: anytype,
    pure: anytype,
    recipient: anytype,
    recipient_port: anytype,
    i: anytype,
    result: anytype,
) !void {
    const answer: contracts.workspace.ValueInput = if (i == 0) .{
        .inline_json = .{ .schema = try workspaceRef(
            fixture.scratch,
            .schema,
            recipient_port.interface.argument.digest,
        ), .json_text = .{ .bytes = "\"42\"" } },
    } else .{
        .reference = try workspaceRef(
            fixture.scratch,
            .value,
            pure.*.value.result_value.?.digest,
        ),
    };
    _ = try fixture.service.*.workspaceInteract(
        fixture.scratch,
        if (i == 0) "answer-direct" else "answer-computed",
        parent.receipt.task,
        .{
            .expected = .{
                .work = try workspaceRef(fixture.scratch, .work, recipient.id),
                .execution_revision = recipient.execution_revision,
                .control_revision = recipient.control_revision,
            },
            .port = try workspaceRef(fixture.scratch, .port, recipient_port.id),
            .generation = recipient_port.generation,
            .command = .{ .resume_value = answer },
        },
    );
    for (0..32) |_| {
        _ = try fixture.service.*.pump(fixture.scratch);
        var observed = try fixture.service.*.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            recipient.id,
        );
        defer observed.deinit();
        if (observed.value.terminal()) break;
    }
    var answered = try fixture.service.*.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        recipient.id,
    );
    defer answered.deinit();
    try std.testing.expectEqual(.completed, answered.value.outcome_kind);
    try std.testing.expectEqualDeep(result.*.value.result, answered.value.result);
    try std.testing.expect(
        !std.meta.eql(result.*.value.result_value, answered.value.result_value),
    );
}

fn delegatedAnswerArchives(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    successful: anytype,
    suffix: anytype,
    parent: anytype,
    target_id: anytype,
    instrument_id: anytype,
    result: anytype,
    child: anytype,
) !void {
    if (scenario == .model) try expectProgramProgressIsDerived(
        &fixture.service.*,
        fixture.scratch,
        parent.receipt.task,
    );
    if (successful or scenario == .revoked or scenario == .model_unavailable) {
        for ([_][32]u8{
            target_id,
            instrument_id.*.?,
        }) |id| try expectDelegationMoveAvailable(&fixture.service.*, fixture.scratch, .{
            .task = parent.receipt.task,
            .work = id,
        });
    }
    try delegatedAnswerArchiveReplay(
        fixture,
        scenario,
        snapshot_mode,
        suffix,
        parent,
        target_id,
        instrument_id,
        result,
        child,
    );
}
fn delegatedAnswerArchiveReplay(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    suffix: anytype,
    parent: anytype,
    target_id: anytype,
    instrument_id: anytype,
    result: anytype,
    child: anytype,
) !void {
    const archive_path = try std.fmt.allocPrint(fixture.scratch, "{s}/{s}.par", .{
        fixture.path_buffer.*[0..fixture.length],
        suffix,
    });
    _ = try fixture.service.*.exportCheckpoint(
        fixture.scratch,
        parent.receipt.task,
        archive_path,
    );
    const import_path = try std.fmt.allocPrint(fixture.scratch, "{s}/import-{s}", .{
        fixture.path_buffer.*[0..fixture.length],
        suffix,
    });
    try fixture.service.*.close(fixture.a);
    fixture.service_open.* = false;
    try fixture.namespace.*.close();
    fixture.namespace_open.* = false;
    {
        try delegatedAnswerArchiveImport(
            fixture,
            scenario,
            snapshot_mode,
            parent,
            target_id,
            instrument_id,
            result,
            child,
            archive_path,
            import_path,
        );
    }
    fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    fixture.namespace_open.* = true;
    fixture.service.* = try native.tasks.Service(DelegateTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile.*,
    );
    fixture.service_open.* = true;
    try std.testing.expectEqual(.idle, try fixture.service.*.pump(fixture.scratch));
}
fn delegatedAnswerArchiveImport(
    fixture: anytype,
    scenario: anytype,
    snapshot_mode: anytype,
    parent: anytype,
    target_id: anytype,
    instrument_id: anytype,
    result: anytype,
    child: anytype,
    archive_path: anytype,
    import_path: anytype,
) !void {
    var imported_namespace = try native.Namespace.open(fixture.a, fixture.io, import_path);
    defer support.expectCleanup(imported_namespace.close());
    var imported = try native.tasks.Service(DelegateTypes).init(
        fixture.a,
        fixture.io,
        &imported_namespace,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile.*,
    );
    defer support.expectCleanup(imported.close(fixture.a));
    _ = try imported.importCheckpoint(fixture.scratch, "import", archive_path);
    try std.testing.expectEqual(.idle, try imported.pump(fixture.scratch));
    var retained = try imported.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        target_id,
    );
    defer retained.deinit();
    try std.testing.expectEqualDeep(result.*.value.result, retained.value.result);
    var imported_child = try imported.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        instrument_id.*.?,
    );
    defer imported_child.deinit();
    try std.testing.expectEqualDeep(child.*.value, imported_child.value);
    var imported_parent = try imported.task(fixture.scratch, parent.receipt.task);
    defer imported_parent.deinit();
    try std.testing.expectEqual(
        @as(u64, if (scenario == .revoked or snapshot_mode) 0 else 1),
        imported_parent.value.inference_attempts,
    );
}

fn delegatedAnswerPreviews(fixture: anytype) !void {
    // Exercise automatic result, failure, port, and value previews through the
    // actual controller occurrence, retained reply evidence, and archive replay.
    for ([_]enum { result, failure, port }{ .result, .failure, .port }) |kind| {
        try delegatedAnswerPreviewCase(fixture, kind);
    }
}
fn delegatedAnswerPreviewCase(fixture: anytype, kind: anytype) !void {
    const label = @tagName(kind);

    const parent = try fixture.service.*.submit(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "overflow-parent-{s}", .{label}),
        {},
    );
    var b = source.Builder.init(fixture.a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const huge = try b.schema(.{ .array = .{
        .element = unit,
        .length = 10_000_000_000_000_000_000,
    } });
    const literal = try b.literal(.{ .schema = huge, .bytes = "" });
    const effect = try b.effect(.{
        .identity = "overflow-payload",
        .payload = huge,
        .result = unit,
        .external = false,
    });
    const entry = try b.declare(&.{
        unit,
    }, if (kind == .result) huge else unit, if (kind == .port) &.{effect} else &.{}, &.{});
    try b.define(entry, switch (kind) {
        .result => try b.pure(literal),
        .failure => try b.term(.{ .fail = literal }),
        .port => try b.term(.{ .perform = .{ .effect = effect, .payload = literal } }),
    });
    const built = try fixture.service.*.workspaceCommand(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "overflow-build-{s}", .{label}),
        parent.receipt.task,
        .{ .program = .{ .build = .{
            .source = .{ .json_text = .{
                .bytes = try native.source_records.encode(
                    fixture.scratch,
                    b.module(entry, if (kind == .failure) huge else unit),
                ),
            } },
            .source_kind = .source_records,
            .exposures = .{ .items = if (kind == .port) &.{.{
                .effect = effect,
                .class = .input,
            }} else &.{} },
        } } },
    );
    try std.testing.expect(built.program != null);
    try delegatedAnswerPreviewArtifact(fixture, kind, label, parent, built);
}
fn delegatedAnswerPreviewArtifact(
    fixture: anytype,
    kind: anytype,
    label: anytype,
    parent: anytype,
    built: anytype,
) !void {
    var artifact = try fixture.service.*.workspaceProgram(
        fixture.scratch,
        parent.receipt.task,
        try nativeIdentity(built.program.?),
    );
    defer artifact.deinit();

    _ = try fixture.service.*.message(
        fixture.scratch,
        try std.fmt.allocPrint(fixture.scratch, "overflow-message-{s}", .{label}),
        parent.receipt.task,
        .{ .work = .{ .start = .{
            .program = built.program.?,
            .input = .{ .inline_json = .{ .schema = try workspaceRef(
                fixture.scratch,
                .schema,
                artifact.value.description.input_schema.digest,
            ), .json_text = .{ .bytes = "{}" } } },
            .policy = .{},
        } } },
    );
    try delegatedAnswerPreviewReply(fixture, kind, label, parent);
}
fn delegatedAnswerPreviewReply(
    fixture: anytype,
    kind: anytype,
    label: anytype,
    parent: anytype,
) !void {
    var reply: ?contracts.workspace.Reply = null;
    for (0..32) |_| {
        _ = try fixture.service.*.pump(fixture.scratch);
        var query = try fixture.namespace.*.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='workspace_reply'",
            &.{.{ .blob = &parent.receipt.task }},
        );
        defer query.deinit();
        if (try query.step() != .row) continue;
        const saved = (try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            try query.bytes(0),
        )).value;
        try std.testing.expect(saved.evidence == .admitted);
        const pending = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            fixture.scratch,
            (try fixture.namespace.*.store.recordBytes(
                fixture.scratch,
                "occurrence",
                saved.id,
                saved.task,
            )).?,
        )).value;
        try std.testing.expect(pending.state == .settled_reply);

        var bound_reply = try data.invocation.decode(
            data.invocation.Result,
            fixture.scratch,
            try fixture.namespace.*.store.acquiredObject(
                fixture.scratch,
                pending.state.settled_reply.reply,
                null,
            ),
        );
        defer bound_reply.deinit();
        reply = (try contracts.decodeOwned(
            contracts.workspace.Reply,
            fixture.scratch,
            bound_reply.value.value,
        )).value;
        break;
    }
    try delegatedAnswerPreviewEvidence(fixture, kind, label, parent, &reply);
}
fn delegatedAnswerPreviewEvidence(
    fixture: anytype,
    kind: anytype,
    label: anytype,
    parent: anytype,
    reply: anytype,
) !void {
    const observed = reply.* orelse return error.MissingOverflowReply;
    try std.testing.expectEqual(.observed, observed.disposition);
    const value = (try native.json.parse(
        fixture.scratch,
        observed.observation_json.bytes,
        .{},
    )).value;
    const preview = switch (kind) {
        .result => value.object.get("result_preview").?,
        .failure => value.object.get("failure_preview").?,
        .port => value.object.get("port").?.object.get("preview").?,
    };
    try std.testing.expectEqualStrings("Overflow", preview.object.get("error").?.string);
    try std.testing.expect(!preview.object.get("complete").?.bool);
    if (kind == .result) {
        const materialized = try fixture.service.*.workspaceCommand(
            fixture.scratch,
            "overflow-materialize",
            parent.receipt.task,
            .{ .context = .{ .materialize = .{ .input = .{ .value = .{
                .reference = observed.evidence.?,
            } }, .sources = .{ .items = &.{} } } } },
        );
        try std.testing.expectEqual(.observed, materialized.disposition);
        const materialized_json = (try native.json.parse(
            fixture.scratch,
            materialized.observation_json.bytes,
            .{},
        )).value;
        try std.testing.expectEqualStrings(
            "Overflow",
            materialized_json.object.get("preview").?.object.get("error").?.string,
        );
    }

    try delegatedAnswerPreviewArchive(fixture, label, parent);
}
fn delegatedAnswerPreviewArchive(fixture: anytype, label: anytype, parent: anytype) !void {
    for (0..32) |_| if (try fixture.service.*.pump(fixture.scratch) == .idle) break;
    const archive_path = try std.fmt.allocPrint(fixture.scratch, "{s}/overflow-{s}.par", .{
        fixture.path_buffer.*[0..fixture.length],
        label,
    });

    _ = try fixture.service.*.exportCheckpoint(
        fixture.scratch,
        parent.receipt.task,
        archive_path,
    );
    try fixture.service.*.close(fixture.a);
    fixture.service_open.* = false;
    try fixture.namespace.*.close();
    fixture.namespace_open.* = false;
    {
        var imported_namespace = try native.Namespace.open(
            fixture.a,
            fixture.io,
            try std.fmt.allocPrint(fixture.scratch, "{s}/overflow-import-{s}", .{
                fixture.path_buffer.*[0..fixture.length],
                label,
            }),
        );
        defer support.expectCleanup(imported_namespace.close());
        var imported = try native.tasks.Service(DelegateTypes).init(
            fixture.a,
            fixture.io,
            &imported_namespace,
            fixture.assets,
            &fixture.application.*,
            fixture.handlers.*,
            fixture.profile.*,
        );
        defer support.expectCleanup(imported.close(fixture.a));
        _ = try imported.importCheckpoint(fixture.scratch, "overflow-import", archive_path);
        try std.testing.expectEqual(.idle, try imported.pump(fixture.scratch));
        try imported.validateWorkspace(fixture.scratch, parent.receipt.task);
    }
    fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    fixture.namespace_open.* = true;
    fixture.service.* = try native.tasks.Service(DelegateTypes).init(
        fixture.a,
        fixture.io,
        &fixture.namespace.*,
        fixture.assets,
        &fixture.application.*,
        fixture.handlers.*,
        fixture.profile.*,
    );
    fixture.service_open.* = true;
    try std.testing.expectEqual(.idle, try fixture.service.*.pump(fixture.scratch));
}

const nativeIdentity = support.nativeIdentity;
const fixtureManifest = support.fixtureManifest;

test "deep recursive workspace values support admission inspection expansion and replies" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "workspace-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = "workspace-unit",
        .manifest = "{}",
    };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "workspace-test", .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });

    try runDeepValueCase(
        .{
            .allocator = a,
            .scratch = scratch,
            .service = &service,
            .namespace = &namespace,
            .task = parent.receipt.task,
            .manifest = assets.manifest,
        },
    );
}

const DeepValueCase = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    service: *native.tasks.Service(OwnerTypes),
    namespace: *native.Namespace,
    task: [16]u8,
    manifest: []const u8,
};
const DeepValueProgram = struct { recursive: Id, unit: Id, program: [32]u8 };
const EnormousValueRun = struct {
    program: native.tasks.Admission,
    started: native.tasks.Admission,
    observation: native.json.Value,
};
fn runDeepValueCase(c: DeepValueCase) !void {
    var b = source.Builder.init(c.allocator);
    defer b.deinit();
    var diagnostic: native.program_construction.Diagnostic = .{};
    const deep = try buildDeepValueProgram(c, &b, &diagnostic);
    var artifact = try c.service.workspaceProgram(c.scratch, c.task, deep.program);
    defer artifact.deinit();
    const schema_ref = try workspaceRef(
        c.scratch,
        .schema,
        artifact.value.description.input_schema.digest,
    );
    const text_value = try deepValueText(c);
    var observation = try startDeepValue(c, deep.program, schema_ref, text_value);
    defer observation.deinit();
    var page = try expandDeepValue(c, observation.value, text_value);
    defer page.deinit();
    const unpageable = try buildUnpageableValue(c, &b, deep.unit, &diagnostic);
    var unpageable_artifact = try c.service.workspaceProgram(c.scratch, c.task, unpageable);
    defer unpageable_artifact.deinit();
    try expectUnpageableValue(c, unpageable, unpageable_artifact.value);
    const enormous = try startEnormousValue(c, &b, deep.unit, &diagnostic);
    var enormous_work = try c.service.workspaceWork(
        c.scratch,
        c.task,
        enormous.started.receipt.workspace.?,
    );
    defer enormous_work.deinit();
    const enormous_ref = try expectEnormousTail(c, enormous.observation, enormous_work.value);
    // The same compact value must remain compact across input commands,
    // alternative commands, finish inspection, and retained archive checks.
    const memory = try c.allocator.alloc(u8, 16 * 1024 * 1024);
    defer c.allocator.free(memory);
    for ([_]@FieldType(contracts.workspace.Exposure, "class"){ .input, .alternative }) |class|
        try exerciseCompactValue(c, class, enormous_ref, memory);
    try validateCompactArchive(c);
    try expectCompactSelection(c, enormous_ref, memory);
    const port_program = try buildDeepValuePort(c, &b, deep.recursive, deep.unit);
    const wire = try c.scratch.alloc(u8, 2049);
    @memset(wire, 1);
    wire[2048] = 0;
    const suspended = try c.service.workspaceStart(
        c.scratch,
        "deep-port-start",
        c.task,
        try nativeIdentity(port_program),
        wire,
        .{},
    );
    var work = try c.service.workspaceWork(c.scratch, c.task, suspended.receipt.workspace.?);
    defer work.deinit();
    var port = try contracts.decodeOwned(
        native.workspace.Port,
        c.scratch,
        try c.namespace.store.object(c.scratch, work.value.current_port.?, null),
    );
    defer port.deinit();
    try replyDeepValuePort(c, work.value, port.value, text_value);
    try expectDeepValueCompletion(c, work.value, wire);
}
fn buildDeepValueProgram(
    c: DeepValueCase,
    b: *source.Builder,
    diagnostic: *native.program_construction.Diagnostic,
) !DeepValueProgram {
    const recursive = try b.reserveSchema();
    const unit = try b.scalar(void);
    try b.defineSchema(recursive, .{ .sum = &.{ unit, recursive } });
    const entry = try b.declare(&.{recursive}, recursive, &.{}, &.{});
    try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
    const text = try native.source_records.encode(c.scratch, b.module(entry, unit));
    const built = try c.service.workspaceBuild(
        c.scratch,
        "deep-build",
        c.task,
        text,
        diagnostic,
    );
    return .{ .recursive = recursive, .unit = unit, .program = built.receipt.workspace.? };
}

fn deepValueText(c: DeepValueCase) ![]const u8 {
    var text_value: std.ArrayList(u8) = .empty;
    for (0..2048) |_| try text_value.appendSlice(c.scratch, "{\"tag\":1,\"value\":");
    try text_value.appendSlice(c.scratch, "{\"tag\":0,\"value\":{}}");
    try text_value.appendNTimes(c.scratch, '}', 2048);
    return text_value.items;
}

fn startDeepValue(
    c: DeepValueCase,
    built: [32]u8,
    schema_ref: contracts.workspace.Ref,
    text_value: []const u8,
) !std.json.Parsed(
    native.json.Value,
) {
    const started = try c.service.workspaceCommand(
        c.scratch,
        "deep-start",
        c.task,
        .{ .work = .{ .start = .{
            .program = try workspaceRef(c.scratch, .program, built),
            .input = .{ .inline_json = .{ .schema = schema_ref, .json_text = .{
                .bytes = text_value,
            } } },
            .policy = .{},
        } } },
    );
    try std.testing.expectEqual(.observed, started.disposition);
    var observation = try native.json.parse(c.scratch, started.observation_json.bytes, .{});
    errdefer observation.deinit();
    try std.testing.expectEqualStrings(
        "completed",
        observation.value.object.get("outcome").?.string,
    );
    return observation;
}

fn expandDeepValue(
    c: DeepValueCase,
    observation: native.json.Value,
    text_value: []const u8,
) !std.json.Parsed(
    native.json.Value,
) {
    const result_ref: contracts.workspace.Ref = .{ .kind = .value, .id = .{
        .bytes = observation.object.get("result").?.object.get("id").?.string,
    } };
    const expanded = try c.service.workspaceCommand(
        c.scratch,
        "deep-expand",
        c.task,
        .{ .context = .{ .expand = .{ .reference = result_ref, .page = .{} } } },
    );
    var page = try native.json.parse(c.scratch, expanded.observation_json.bytes, .{});
    errdefer page.deinit();
    try std.testing.expect(!page.value.object.get("complete").?.bool);
    try std.testing.expectEqualStrings(
        text_value[0..16384],
        page.value.object.get("text").?.string,
    );
    return page;
}

fn buildUnpageableValue(
    c: DeepValueCase,
    b: *source.Builder,
    unit: Id,
    diagnostic: *native.program_construction.Diagnostic,
) ![32]u8 {
    const unpageable = try b.schema(.{ .array = .{
        .element = unit,
        .length = 10_000_000_000_000_000_000,
    } });
    const unpageable_entry = try b.declare(&.{unit}, unpageable, &.{}, &.{});
    try b.define(
        unpageable_entry,
        try b.pure(try b.literal(.{ .schema = unpageable, .bytes = "" })),
    );
    const unpageable_program = try c.service.workspaceBuild(
        c.scratch,
        "unpageable-build",
        c.task,
        try native.source_records.encode(c.scratch, b.module(unpageable_entry, unit)),
        diagnostic,
    );
    return unpageable_program.receipt.workspace.?;
}

fn expectUnpageableValue(
    c: DeepValueCase,
    unpageable_program: [32]u8,
    unpageable_artifact: native.workspace.Program,
) !void {
    const unpageable_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = try workspaceRef(c.scratch, .program, unpageable_program),
        .input = .{ .inline_json = .{ .schema = try workspaceRef(
            c.scratch,
            .schema,
            unpageable_artifact.description.input_schema.digest,
        ), .json_text = .{ .bytes = "{}" } } },
        .policy = .{},
    } } };
    const unpageable_start = try c.service.workspaceCommand(
        c.scratch,
        "unpageable-start",
        c.task,
        unpageable_command,
    );
    try std.testing.expectEqual(.observed, unpageable_start.disposition);
    const unpageable_json = (try native.json.parse(
        c.scratch,
        unpageable_start.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings("completed", unpageable_json.object.get("outcome").?.string);
    try std.testing.expectEqualStrings(
        "Overflow",
        unpageable_json.object.get("result_preview").?.object.get("error").?.string,
    );
    try std.testing.expect(
        !unpageable_json.object.get("result_preview").?.object.get("complete").?.bool,
    );
    const unpageable_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        c.scratch,
        unpageable_json.object.get("result").?,
    );
    const unpageable_replay = try c.service.workspaceCommand(
        c.scratch,
        "unpageable-start",
        c.task,
        unpageable_command,
    );
    try std.testing.expectEqual(.observed, unpageable_replay.disposition);
    try std.testing.expectEqualDeep(unpageable_start.evidence, unpageable_replay.evidence);
    const unpageable_expand = try c.service.workspaceCommand(
        c.scratch,
        "unpageable-expand",
        c.task,
        .{ .context = .{ .expand = .{ .reference = unpageable_ref, .page = .{} } } },
    );
    try std.testing.expectEqual(.rejected, unpageable_expand.disposition);
    try c.service.validateWorkspace(c.scratch, c.task);
}

fn startEnormousValue(
    c: DeepValueCase,
    b: *source.Builder,
    unit: Id,
    diagnostic: *native.program_construction.Diagnostic,
) !EnormousValueRun {
    const enormous = try b.schema(.{ .array = .{ .element = unit, .length = 1_000_000_000 } });
    const enormous_entry = try b.declare(&.{enormous}, enormous, &.{}, &.{});
    try b.define(enormous_entry, try b.pure(try b.reference(b.parameter(enormous_entry, 0))));
    const enormous_program = try c.service.workspaceBuild(
        c.scratch,
        "enormous-build",
        c.task,
        try native.source_records.encode(c.scratch, b.module(enormous_entry, unit)),
        diagnostic,
    );
    const enormous_start = try c.service.workspaceStart(
        c.scratch,
        "enormous-start",
        c.task,
        enormous_program.receipt.workspace.?,
        "",
        .{},
    );
    const enormous_inspect = try c.service.workspaceCommand(
        c.scratch,
        "enormous-inspect",
        c.task,
        .{ .work = .{ .inspect = .{
            .work = try workspaceRef(c.scratch, .work, enormous_start.receipt.workspace.?),
        } } },
    );
    const enormous_json = (try native.json.parse(
        c.scratch,
        enormous_inspect.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings("completed", enormous_json.object.get("outcome").?.string);
    try expectEnormousInterpretation(c, enormous_program, enormous_start, enormous_json);
    return .{
        .program = enormous_program,
        .started = enormous_start,
        .observation = enormous_json,
    };
}

fn expectEnormousTail(
    c: DeepValueCase,
    enormous_json: native.json.Value,
    enormous_work: native.workspace.Work,
) !contracts.workspace.Ref {
    try std.testing.expectEqualDeep(
        enormous_work.input_value.?.digest,
        try nativeIdentity(
            try native.values.fromJson(
                contracts.workspace.Ref,
                c.scratch,
                enormous_json.object.get("interpretation_evidence").?.object.get("input").?,
            ),
        ),
    );
    try std.testing.expect(
        !enormous_json.object.get("result_preview").?.object.get("complete").?.bool,
    );
    const enormous_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        c.scratch,
        enormous_json.object.get("result").?,
    );
    const enormous_tail = try c.service.workspaceCommand(
        c.scratch,
        "enormous-tail",
        c.task,
        .{ .context = .{ .expand = .{ .reference = enormous_ref, .page = .{
            .offset = 2_999_999_995,
            .maximum = 10,
        } } } },
    );
    const enormous_tail_json = (try native.json.parse(
        c.scratch,
        enormous_tail.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings("{},{}]", enormous_tail_json.object.get("text").?.string);
    try std.testing.expect(enormous_tail_json.object.get("eof").?.bool);
    return enormous_ref;
}

fn exerciseCompactValue(
    c: DeepValueCase,
    class: @FieldType(contracts.workspace.Exposure, "class"),
    enormous_ref: contracts.workspace.Ref,
    memory: []u8,
) !void {
    var cb = source.Builder.init(c.allocator);
    defer cb.deinit();
    const operation_name = @tagName(class);
    const compact_program = try buildCompactExposure(c, &cb, class);
    const compact_start = try c.service.workspaceStart(
        c.scratch,
        try std.fmt.allocPrint(c.scratch, "compact-start-{s}", .{operation_name}),
        c.task,
        try nativeIdentity(compact_program.program.?),
        "",
        .{},
    );
    for (0..if (class == .alternative) @as(usize, 2) else 1) |turn| {
        try replyCompactValue(c, class, operation_name, compact_start, enormous_ref, memory, turn);
    }
    var completed = try c.service.workspaceWork(
        c.scratch,
        c.task,
        compact_start.receipt.workspace.?,
    );
    defer completed.deinit();
    try std.testing.expectEqual(.completed, completed.value.outcome_kind);
    try std.testing.expectEqualSlices(
        u8,
        "",
        try c.namespace.store.object(c.scratch, completed.value.result.?, null),
    );
}

fn rejectPrematureCompactFinish(
    c: DeepValueCase,
    class: @FieldType(contracts.workspace.Exposure, "class"),
    operation_name: []const u8,
    current: native.workspace.Work,
    exposed: native.workspace.Port,
    budget: *std.heap.FixedBufferAllocator,
) !void {
    try std.testing.expectError(
        if (class == .alternative) error.NoBranchResult else error.InvalidPortCommand,
        c.service.workspaceInteract(
            budget.allocator(),
            try std.fmt.allocPrint(c.scratch, "premature-finish-{s}", .{
                operation_name,
            }),
            c.task,
            .{
                .expected = .{
                    .work = try workspaceRef(c.scratch, .work, current.id),
                    .execution_revision = current.execution_revision,
                    .control_revision = current.control_revision,
                },
                .port = try workspaceRef(c.scratch, .port, exposed.id),
                .generation = exposed.generation,
                .command = .{ .finish = .{} },
            },
        ),
    );
    budget.reset();
}

fn replyCompactValue(
    c: DeepValueCase,
    class: @FieldType(contracts.workspace.Exposure, "class"),
    operation_name: []const u8,
    compact_start: native.tasks.Admission,
    enormous_ref: contracts.workspace.Ref,
    memory: []u8,
    turn: usize,
) !void {
    var current = try c.service.workspaceWork(
        c.scratch,
        c.task,
        compact_start.receipt.workspace.?,
    );
    defer current.deinit();
    var exposed = try contracts.decodeOwned(
        native.workspace.Port,
        c.scratch,
        try c.namespace.store.object(c.scratch, current.value.current_port.?, null),
    );
    defer exposed.deinit();
    var budget = std.heap.FixedBufferAllocator.init(memory);
    if (turn == 0) {
        try rejectPrematureCompactFinish(
            c,
            class,
            operation_name,
            current.value,
            exposed.value,
            &budget,
        );
    }
    _ = try c.service.workspaceInteract(
        budget.allocator(),
        try std.fmt.allocPrint(c.scratch, "compact-reply-{s}-{d}", .{
            operation_name,
            turn,
        }),
        c.task,
        .{
            .expected = .{
                .work = try workspaceRef(c.scratch, .work, current.value.id),
                .execution_revision = current.value.execution_revision,
                .control_revision = current.value.control_revision,
            },
            .port = try workspaceRef(c.scratch, .port, exposed.value.id),
            .generation = exposed.value.generation,
            .command = if (turn == 0) .{ .resume_value = .{
                .reference = enormous_ref,
            } } else .{ .finish = .{} },
        },
    );
    try advanceCompactValue(c, operation_name, current.value);
}

fn advanceCompactValue(
    c: DeepValueCase,
    operation_name: []const u8,
    current: native.workspace.Work,
) !void {
    for (0..8) |_| {
        var next = try c.service.workspaceWork(
            c.scratch,
            c.task,
            current.id,
        );
        defer next.deinit();
        if (next.value.terminal() or (next.value.current_port != null and !std.meta.eql(
            next.value.current_port,
            current.current_port,
        ))) break;
        _ = try c.service.workspaceControl(
            c.scratch,
            try std.fmt.allocPrint(c.scratch, "compact-advance-{s}-{d}", .{
                operation_name,
                next.value.execution_revision,
            }),
            c.task,
            next.value.id,
            next.value.execution_revision,
            next.value.control_revision,
            .advance,
        );
    }
}

fn validateCompactArchive(c: DeepValueCase) !void {
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(c.manifest, &manifest_digest, .{});
    const index = try c.namespace.store.archiveIndex(c.scratch, c.task, .{
        .digest = manifest_digest,
        .bytes = c.manifest.len,
    });
    try c.service.validateWorkspaceRecords(c.scratch, c.task, index.records.items);
}

fn expectCompactSelection(
    c: DeepValueCase,
    enormous_ref: contracts.workspace.Ref,
    memory: []u8,
) !void {
    // Repeated selected values preserve their exact order and multiplicity,
    // while the page uses less memory than the full 32 MiB preview array.
    const selected_refs = try c.scratch.alloc(contracts.workspace.Ref, 2048);
    @memset(selected_refs, enormous_ref);
    var selection_budget = std.heap.FixedBufferAllocator.init(memory);
    const selected_view = try c.service.workspaceCommand(
        selection_budget.allocator(),
        "compact-view",
        c.task,
        .{ .context = .{ .select = .{ .values = .{ .items = selected_refs } } } },
    );
    if (selected_view.disposition != .observed) std.debug.print("compact view: {s}\n", .{
        selected_view.observation_json.bytes,
    });
    try std.testing.expectEqual(.observed, selected_view.disposition);
    const view_ref = try workspaceRef(
        c.scratch,
        .view,
        try nativeIdentity(selected_view.selected_view.?),
    );
    const selected_json = (try native.json.parse(
        c.scratch,
        selected_view.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings(
        "2048",
        selected_json.object.get("value_count").?.number_string,
    );
    const selected_page = selected_json.object.get("selection").?;
    const selected_total = try native.json.numberInteger(
        u64,
        selected_page.object.get("total_bytes").?.number_string,
    );
    try std.testing.expect(selected_total > 32 * 1024 * 1024);
    selection_budget.reset();
    const selected_tail = try c.service.workspaceCommand(
        selection_budget.allocator(),
        "compact-view-tail",
        c.task,
        .{ .context = .{ .expand = .{ .reference = view_ref, .page = .{
            .offset = selected_total - 1,
            .maximum = 10,
        } } } },
    );
    const selected_tail_json = (try native.json.parse(
        c.scratch,
        selected_tail.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings(
        "]",
        selected_tail_json.object.get("selection").?.object.get("text").?.string,
    );
}

fn buildDeepValuePort(
    c: DeepValueCase,
    b: *source.Builder,
    recursive: Id,
    unit: Id,
) !contracts.workspace.Ref {
    const effect = try b.effect(.{
        .identity = "example/deep-value",
        .payload = recursive,
        .result = recursive,
        .external = false,
    });
    const port_entry = try b.declare(&.{recursive}, recursive, &.{effect}, &.{});
    try b.define(
        port_entry,
        try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.reference(b.parameter(port_entry, 0)),
        } }),
    );
    const port_program = try c.service.workspaceCommand(
        c.scratch,
        "deep-port-build",
        c.task,
        .{ .program = .{ .build = .{
            .source = .{ .json_text = .{
                .bytes = try native.source_records.encode(c.scratch, b.module(port_entry, unit)),
            } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{.{ .effect = effect, .class = .input }} },
        } } },
    );
    try std.testing.expect(port_program.program != null);
    return port_program.program.?;
}

fn replyDeepValuePort(
    c: DeepValueCase,
    work: native.workspace.Work,
    port: native.workspace.Port,
    text_value: []const u8,
) !void {
    _ = try c.service.workspaceInteract(c.scratch, "deep-port-reply", c.task, .{
        .expected = .{
            .work = try workspaceRef(c.scratch, .work, work.id),
            .execution_revision = work.execution_revision,
            .control_revision = work.control_revision,
        },
        .port = try workspaceRef(c.scratch, .port, port.id),
        .generation = port.generation,
        .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
            c.scratch,
            .schema,
            port.interface.argument.digest,
        ), .json_text = .{ .bytes = text_value } } } },
    });
}

fn expectDeepValueCompletion(
    c: DeepValueCase,
    work: native.workspace.Work,
    wire: []const u8,
) !void {
    for (0..8) |_| {
        var current = try c.service.workspaceWork(c.scratch, c.task, work.id);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqualSlices(
                u8,
                wire,
                try c.namespace.store.object(c.scratch, current.value.result.?, null),
            );
            return;
        }
        _ = try c.service.workspaceControl(
            c.scratch,
            try std.fmt.allocPrint(c.scratch, "deep-advance-{d}", .{
                current.value.execution_revision,
            }),
            c.task,
            current.value.id,
            current.value.execution_revision,
            current.value.control_revision,
            .advance,
        );
    }
    return error.DidNotComplete;
}

fn expectEnormousInterpretation(
    c: DeepValueCase,
    enormous_program: native.tasks.Admission,
    enormous_start: native.tasks.Admission,
    enormous_json: native.json.Value,
) !void {
    const interpretation = enormous_json.object.get("interpretation_evidence").?;
    try std.testing.expectEqualStrings(
        "experimental",
        interpretation.object.get("evidence_class").?.string,
    );
    try std.testing.expectEqual(
        .null,
        std.meta.activeTag(interpretation.object.get("analysis_checker").?),
    );
    try std.testing.expectEqualDeep(
        enormous_program.receipt.workspace.?,
        try nativeIdentity(
            try native.values.fromJson(
                contracts.workspace.Ref,
                c.scratch,
                interpretation.object.get("program").?,
            ),
        ),
    );
    try std.testing.expectEqualDeep(
        enormous_start.receipt.workspace.?,
        try nativeIdentity(
            try native.values.fromJson(
                contracts.workspace.Ref,
                c.scratch,
                interpretation.object.get("work").?,
            ),
        ),
    );
}

fn buildCompactExposure(
    c: DeepValueCase,
    cb: *source.Builder,
    class: @FieldType(contracts.workspace.Exposure, "class"),
) !contracts.workspace.Reply {
    const compact_unit = try cb.scalar(void);
    const compact_array = try cb.schema(.{ .array = .{
        .element = compact_unit,
        .length = 1_000_000_000,
    } });
    const operation_name = @tagName(class);
    const compact_effect = try cb.effect(.{
        .identity = operation_name,
        .payload = compact_unit,
        .result = compact_array,
        .external = false,
        .control_use = .multi,
    });
    const compact_entry = try cb.declare(
        &.{compact_unit},
        compact_array,
        &.{compact_effect},
        &.{},
    );
    try cb.define(
        compact_entry,
        try cb.term(.{ .perform = .{
            .effect = compact_effect,
            .payload = try cb.constant(void, {}),
        } }),
    );
    const compact_program = try c.service.workspaceCommand(
        c.scratch,
        try std.fmt.allocPrint(c.scratch, "compact-build-{s}", .{operation_name}),
        c.task,
        .{ .program = .{ .build = .{
            .source = .{ .json_text = .{
                .bytes = try native.source_records.encode(
                    c.scratch,
                    cb.module(compact_entry, compact_unit),
                ),
            } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{.{ .effect = compact_effect, .class = class }} },
        } } },
    );
    if (compact_program.program == null) std.debug.print("compact {s}: {s}\n", .{
        operation_name,
        compact_program.observation_json.bytes,
    });
    try std.testing.expect(compact_program.program != null);
    return compact_program;
}

test "collected history rejects rehashed result substitution and false absence" {
    var meter: kosmos.AllocationBudget = .{
        .parent = std.testing.allocator,
        .limit = std.math.maxInt(usize),
    };
    const a = meter.allocator();
    const io = std.testing.io;
    var compiled = try @import("protean").compile(
        a,
        @import("protean").system(.{
            .InitialArgs = void,
            .Result = void,
            .Failure = void,
            .application = DelegateApplication,
        }),
    );
    defer compiled.deinit();
    try collectionImage(a, io, &meter, &compiled);
}
fn collectionScenario(fixture: CollectedHistoryFixture) !void {
    const parent = try fixture.service.submit(fixture.scratch, "collect-parent", {});
    var builder = source.Builder.init(fixture.scratch);
    defer builder.deinit();
    const document = try native.source_records.encode(fixture.scratch, try gcd(&builder));
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try fixture.service.workspaceBuild(
        fixture.scratch,
        "collect-program",
        parent.receipt.task,
        document,
        &diagnostic,
    );
    const input = try contracts.encodeOwned(struct { u64, u64 }, fixture.scratch, .{ 1071, 462 });
    const started = try fixture.service.workspaceStart(
        fixture.scratch,
        "collect-start",
        parent.receipt.task,
        program.receipt.workspace.?,
        input,
        .{},
    );
    var work = try fixture.service.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        started.receipt.workspace.?,
    );
    defer work.deinit();
    try std.testing.expectEqual(.completed, work.value.outcome_kind);
    var artifact = try fixture.service.workspaceProgram(
        fixture.scratch,
        parent.receipt.task,
        program.receipt.workspace.?,
    );
    defer artifact.deinit();
    try collectionHypothesis(
        fixture,
        parent,
        program,
        input,
        &work,
        &artifact,
        started,
        &diagnostic,
    );
}

fn collectionService(
    a: anytype,
    io: anytype,
    meter: anytype,
    application: anytype,
    assets: anytype,
    manifest: anytype,
) !void {
    const declarations = [_]native.Declaration{ native.inbox.declaration(
        DelegateTypes.Message,
    ), .{
        .identity = "workspace-delegation",
        .resource_role = "workspace",
        .kind = .workspace,
        .workspace = WaitApplication.authorize,
        .payload_schema = WaitApplication.schema,
        .resume_schema = WaitApplication.result,
    } };
    var handlers = try native.Registry.init(a, &declarations);
    defer handlers.deinit();
    var grants: [declarations.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "collection-test", .authority = .{
        .grants = &grants,
        .principal = "test",
        .tenant = "test",
    } };
    for (declarations, &grants) |declaration, *grant| grant.* = .{
        .identity = declaration.identity,
        .resource_role = declaration.resource_role,
        .resource_identity = try profile.resourceIdentity(a, application.image_identity),
    };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(DelegateTypes).init(
        a,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const fixture: CollectedHistoryFixture = .{
        .meter = meter,
        .namespace = &namespace,
        .service = &service,
        .scratch = scratch,
        .manifest = manifest,
    };
    try collectionScenario(fixture);
}

fn collectionImage(a: anytype, io: anytype, meter: anytype, compiled: anytype) !void {
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "collection-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "collection-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(
        application.arena.allocator(),
        manifest,
        .{},
    )).value;
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "collection-unit",
        .manifest = manifest,
    };
    try collectionService(a, io, meter, &application, assets, manifest);
}

fn collectionObservedHistory(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    hypothesis_ref: anytype,
    hypothesis_record: anytype,
    started: anytype,
    diagnostic: *native.program_construction.Diagnostic,
) !void {
    var slow_builder = source.Builder.init(fixture.scratch);
    defer slow_builder.deinit();
    const slow_program = try fixture.service.workspaceBuild(
        fixture.scratch,
        "collect-slow-build",
        parent.receipt.task,
        try native.source_records.encode(fixture.scratch, try listLength(&slow_builder)),
        diagnostic,
    );
    const slow_input = try fixture.scratch.alloc(u8, 32 * 9 + 1);
    var writer: data.wire.Writer = .{ .output = slow_input };
    for (0..32) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const slow_start = try fixture.service.workspaceStart(
        fixture.scratch,
        "collect-slow-start",
        parent.receipt.task,
        slow_program.receipt.workspace.?,
        slow_input,
        .{},
    );
    try expectWorkInputHistoryBound(
        fixture.service,
        fixture.scratch,
        parent.receipt.task,
        slow_start.receipt.workspace.?,
        &.{hypothesis_record.?.artifact},
    );
    try fixture.service.validateWorkspace(fixture.scratch, parent.receipt.task);
    try collectionReadHistory(
        fixture,
        parent,
        program,
        input,
        work,
        hypothesis_ref,
        hypothesis_record,
        slow_start,
        started,
    );
}

fn collectionHypothesis(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    artifact: anytype,
    started: anytype,
    diagnostic: *native.program_construction.Diagnostic,
) !void {
    const hypothesis = try fixture.service.workspaceCommand(
        fixture.scratch,
        "collect-hypothesis",
        parent.receipt.task,
        .{
            .context = .{
                .materialize = .{
                    .input = .{ .value = .{ .inline_json = .{ .schema = try workspaceRef(
                        fixture.scratch,
                        .schema,
                        artifact.value.description.result_schema.digest,
                    ), .json_text = .{ .bytes = "\"999\"" } } } },
                    .sources = .{ .items = &.{} },
                },
            },
        },
    );
    var hypothesis_json = try native.json.parse(
        fixture.scratch,
        hypothesis.observation_json.bytes,
        .{},
    );
    defer hypothesis_json.deinit();
    const hypothesis_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        fixture.scratch,
        hypothesis_json.value.object.get("value").?,
    );
    var query = try fixture.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
            "ERE r.task=? AND r.kind='workspace_value'",
        &.{.{ .blob = &parent.receipt.task }},
    );
    defer query.deinit();
    const hypothesis_record = try collectionHypothesisRecord(fixture, &query, hypothesis_ref);
    try collectionObservedHistory(
        fixture,
        parent,
        program,
        input,
        work,
        hypothesis_ref,
        hypothesis_record,
        started,
        diagnostic,
    );
}

fn collectionHypothesisRecord(
    fixture: CollectedHistoryFixture,
    query: anytype,
    hypothesis_ref: anytype,
) !?native.workspace.Value {
    // Resolve the actual immutable artifact reference, including its byte count.
    var hypothesis_record: ?native.workspace.Value = null;
    while (try query.step() == .row) {
        const candidate = try contracts.decodeOwned(
            native.workspace.Value,
            fixture.scratch,
            try query.bytes(0),
        );
        if (std.mem.eql(
            u8,
            &candidate.value.artifact.digest,
            &(try nativeIdentity(hypothesis_ref)),
        )) hypothesis_record = candidate.value;
    }
    return hypothesis_record;
}

fn collectionReadHistory(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    hypothesis_ref: anytype,
    hypothesis_record: anytype,
    slow_start: anytype,
    started: anytype,
) !void {
    const refs = [_]contracts.workspace.Ref{
        try workspaceRef(fixture.scratch, .work, work.value.id),
        try workspaceRef(fixture.scratch, .work, @splat(0)),
        try workspaceRef(fixture.scratch, .work, slow_start.receipt.workspace.?),
    };
    _ = try fixture.service.message(
        fixture.scratch,
        "collect-message",
        parent.receipt.task,
        .{ .work = .{ .collect = .{ .works = .{ .items = &refs } } } },
    );
    const original = try collectionReadOccurrence(fixture, parent);
    try std.testing.expect(original.state == .settled_reply);
    try collectionReadForgery(
        fixture,
        parent,
        program,
        input,
        work,
        hypothesis_ref,
        hypothesis_record,
        slow_start,
        &refs,
        original,
        started,
    );
}

fn collectionReadOccurrence(
    fixture: CollectedHistoryFixture,
    parent: anytype,
) !native.testing.occurrence.Occurrence {
    var observed: ?native.testing.occurrence.Occurrence = null;
    for (0..64) |_| {
        _ = try fixture.service.pump(fixture.scratch);
        var pending_query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='workspace_reply'",
            &.{.{ .blob = &parent.receipt.task }},
        );
        defer pending_query.deinit();
        if (try pending_query.step() != .row) continue;
        const saved = try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            try pending_query.bytes(0),
        );
        const pending_bytes = (try fixture.namespace.store.recordBytes(
            fixture.scratch,
            "occurrence",
            saved.value.id,
            parent.receipt.task,
        )).?;
        observed = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            fixture.scratch,
            pending_bytes,
        )).value;
        break;
    }
    return observed orelse error.MissingReadObservation;
}

fn collectionReadForgery(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    hypothesis_ref: anytype,
    hypothesis_record: anytype,
    slow_start: anytype,
    refs: anytype,
    original: anytype,
    started: anytype,
) !void {
    const current_history_reads = try archiveHistoryReads(
        fixture.service,
        fixture.scratch,
        parent.receipt.task,
        fixture.meter,
    );
    const original_evidence = (try fixture.namespace.store.recordBytes(
        fixture.scratch,
        "workspace_reply",
        original.id,
        original.task,
    )).?;
    const acquired_bytes = try fixture.namespace.store.object(
        fixture.scratch,
        try fixture.namespace.store.objectReference(original.state.settled_reply.reply, null),
        null,
    );
    const acquired = try data.invocation.decode(
        data.invocation.Result,
        fixture.scratch,
        acquired_bytes,
    );
    const original_reply = try contracts.decodeOwned(
        contracts.workspace.Reply,
        fixture.scratch,
        acquired.value.value,
    );
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture.manifest, &manifest_digest, .{});
    try expectCollectedReadRejection(fixture, manifest_digest, original, original_evidence);
    try collectionParkedKind(fixture, manifest_digest, parent, program, slow_start);
    try collectionFutureHistory(
        fixture,
        manifest_digest,
        parent,
        program,
        input,
        work,
        hypothesis_ref,
        hypothesis_record,
        slow_start,
        refs,
        original,
        original_evidence,
        original_reply,
        current_history_reads,
        started,
    );
}

fn expectCollectedReadRejection(
    fixture: CollectedHistoryFixture,
    manifest_digest: anytype,
    original: anytype,
    original_evidence: anytype,
) !void {
    {
        // Before root consumption, preserve the successful read journal entry
        // while coherently rewriting both retained evidence and acquired reply.
        const read_index = try fixture.namespace.store.archiveIndex(
            fixture.scratch,
            original.task,
            .{ .digest = manifest_digest, .bytes = fixture.manifest.len },
        );
        var read_compiler_facts = try fixture.service.prepareWorkspaceValidation(original.task);
        defer read_compiler_facts.deinit();
        try fixture.namespace.store.begin();
        try forgeCollectedRejectedReply(fixture, original, original_evidence);
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspaceRecordsPrepared(
                fixture.scratch,
                original.task,
                read_index.records.items,
                &read_compiler_facts,
            ),
        );
        fixture.namespace.store.rollback();
        try fixture.service.validateWorkspace(fixture.scratch, original.task);
    }
}

fn collectionParkedKind(
    fixture: CollectedHistoryFixture,
    manifest_digest: anytype,
    parent: anytype,
    program: anytype,
    slow_start: anytype,
) !void {
    {
        var slow = try fixture.service.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            slow_start.receipt.workspace.?,
        );
        defer slow.deinit();
        const parked = try fixture.service.workspaceControl(
            fixture.scratch,
            "collect-kind-park",
            parent.receipt.task,
            slow.value.id,
            slow.value.execution_revision,
            slow.value.control_revision,
            .park,
        );
        try expectCollectedKindRejection(fixture, manifest_digest, parent, program, parked, &slow);
        slow.deinit();
        slow = try fixture.service.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            slow_start.receipt.workspace.?,
        );
        _ = try fixture.service.workspaceControl(
            fixture.scratch,
            "collect-slow-delegate",
            parent.receipt.task,
            slow.value.id,
            slow.value.execution_revision,
            slow.value.control_revision,
            .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } },
        );
        for (0..4) |_| _ = try fixture.service.pump(fixture.scratch);
    }
}

fn expectCollectedKindRejection(
    fixture: CollectedHistoryFixture,
    manifest_digest: anytype,
    parent: anytype,
    program: anytype,
    parked: anytype,
    slow: anytype,
) !void {
    {
        // The response kind cannot opt an admitted work command out of its
        // proof by presenting a genuine program artifact instead.
        const archive_index = try fixture.namespace.store.archiveIndex(
            fixture.scratch,
            parent.receipt.task,
            .{ .digest = manifest_digest, .bytes = fixture.manifest.len },
        );
        var kind_compiler_facts = try fixture.service.prepareWorkspaceValidation(
            parent.receipt.task,
        );
        defer kind_compiler_facts.deinit();
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        var changed_receipt = parked.receipt;
        changed_receipt.workspace_kind = .program;
        changed_receipt.workspace = program.receipt.workspace;
        changed_receipt.workspace_observation = program.receipt.workspace_observation;
        const prior_receipt_ref = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(
                native.testing.state.Receipt,
                fixture.scratch,
                parked.receipt,
            ),
        );
        const receipt_ref = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(
                native.testing.state.Receipt,
                fixture.scratch,
                changed_receipt,
            ),
        );
        try fixture.namespace.store.database.run(
            "UPDATE operations SET receipt=? WHERE receipt=?",
            &.{ .{ .blob = &receipt_ref.digest }, .{ .blob = &prior_receipt_ref.digest } },
        );
        try forgeCollectedKindEvent(fixture, parent, program, parked);
        try fixture.namespace.store.putRecord(
            native.workspace.Work,
            "workspace_work",
            slow.value.id,
            parent.receipt.task,
            slow.value,
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspaceRecordsPrepared(
                fixture.scratch,
                parent.receipt.task,
                archive_index.records.items,
                &kind_compiler_facts,
            ),
        );
    }
}

fn forgeCollectedKindEvent(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    program: anytype,
    parked: anytype,
) !void {
    var event_query = try fixture.namespace.store.database.prepare(
        "SELECT seq,o.body FROM events e JOIN objects o ON o.digest=e.body" ++
            " WHERE e.task=? AND e.revision=?",
        &.{
            .{ .blob = &parent.receipt.task },
            .{ .integer = @intCast(parked.receipt.revision) },
        },
    );
    defer event_query.deinit();
    try std.testing.expect(try event_query.step() == .row);
    var event_value = try contracts.decodeOwned(
        native.testing.state.Event,
        fixture.scratch,
        try event_query.bytes(1),
    );
    event_value.value.workspace_publications.items = &.{};
    event_value.value.data = .{
        .bytes = try std.fmt.allocPrint(fixture.scratch, "{{\"workspace_id\":\"{s}\"}}", .{
            std.fmt.bytesToHex(program.receipt.workspace.?, .lower),
        }),
    };
    const event_ref = try fixture.namespace.store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, fixture.scratch, event_value.value),
    );
    try fixture.namespace.store.database.run(
        "UPDATE events SET body=? WHERE task=? AND seq=?",
        &.{
            .{ .blob = &event_ref.digest },
            .{ .blob = &parent.receipt.task },
            .{ .integer = try event_query.integer(0) },
        },
    );
}

fn collectionFutureHistory(
    fixture: CollectedHistoryFixture,
    manifest_digest: anytype,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    hypothesis_ref: anytype,
    hypothesis_record: anytype,
    slow_start: anytype,
    refs: anytype,
    original: anytype,
    original_evidence: anytype,
    original_reply: anytype,
    current_history_reads: anytype,
    started: anytype,
) !void {
    for (0..1024) |step| {
        var slow = try fixture.service.workspaceWork(
            fixture.scratch,
            parent.receipt.task,
            slow_start.receipt.workspace.?,
        );
        defer slow.deinit();
        if (slow.value.terminal()) break;
        _ = try fixture.service.workspaceControl(
            fixture.scratch,
            try std.fmt.allocPrint(fixture.scratch, "collect-slow-{d}", .{step}),
            parent.receipt.task,
            slow.value.id,
            slow.value.execution_revision,
            slow.value.control_revision,
            .advance,
        );
    }
    var future = try fixture.service.workspaceWork(
        fixture.scratch,
        parent.receipt.task,
        slow_start.receipt.workspace.?,
    );
    defer future.deinit();
    try std.testing.expectEqual(.completed, future.value.outcome_kind);
    const future_reply = try fixture.service.workspaceCommand(
        fixture.scratch,
        "collect-future",
        parent.receipt.task,
        .{ .work = .{ .inspect = .{ .work = refs[2] } } },
    );
    try fixture.service.validateWorkspace(fixture.scratch, parent.receipt.task);
    try collectionHistoryAttacks(
        fixture,
        manifest_digest,
        parent,
        program,
        input,
        work,
        hypothesis_ref,
        hypothesis_record,
        slow_start,
        refs,
        original,
        original_evidence,
        original_reply,
        current_history_reads,
        &future,
        future_reply,
        started,
    );
}

fn collectionHistoryAttacks(
    fixture: CollectedHistoryFixture,
    manifest_digest: anytype,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    hypothesis_ref: anytype,
    hypothesis_record: anytype,
    slow_start: anytype,
    refs: anytype,
    original: anytype,
    original_evidence: anytype,
    original_reply: anytype,
    current_history_reads: anytype,
    future: anytype,
    future_reply: anytype,
    started: anytype,
) !void {
    const index = try fixture.namespace.store.archiveIndex(fixture.scratch, original.task, .{
        .digest = manifest_digest,
        .bytes = fixture.manifest.len,
    });
    // Display data and retained publication facts must name the same work.
    // Rehashing a swapped/erased display ID cannot alter historical scope.
    var history_compiler_facts = try fixture.service.prepareWorkspaceValidation(original.task);
    defer history_compiler_facts.deinit();
    try expectCollectedDisplayForgery(fixture, original, index, &history_compiler_facts);
    try expectCollectedSnapshotForgeries(
        fixture,
        original,
        original_evidence,
        original_reply,
        index,
        &history_compiler_facts,
        hypothesis_record,
        hypothesis_ref,
        refs,
        future,
        future_reply,
    );
    try expectCollectedReceiptForgeries(
        fixture,
        parent,
        original,
        index,
        &history_compiler_facts,
        slow_start,
        started,
        future,
    );
    try collectionLaterHistory(
        fixture,
        manifest_digest,
        parent,
        program,
        input,
        work,
        hypothesis_ref,
        hypothesis_record,
        refs,
        original,
        original_evidence,
        current_history_reads,
    );
}

fn expectCollectedDisplayForgery(
    fixture: CollectedHistoryFixture,
    original: anytype,
    index: anytype,
    history_compiler_facts: anytype,
) !void {
    for ([_]native.testing.state.EventType{ .workspace, .workspace_progress }) |kind| {
        try fixture.namespace.store.begin();
        var event_query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? ORDER BY e.seq",
            &.{.{ .blob = &original.task }},
        );
        var changed = false;
        while (try event_query.step() == .row) {
            var event_value = try contracts.decodeOwned(
                native.testing.state.Event,
                fixture.scratch,
                try event_query.bytes(0),
            );
            if (event_value.value.kind != kind or
                event_value.value.workspace_publications.items.len == 0) continue;
            event_value.value.data.bytes =
                "{\"workspace_id\":\"000000000000000000000000000000000000000000000" ++
                "0000000000000000000\"}";
            const rewritten = try fixture.namespace.store.putObject(
                try contracts.encodeOwned(
                    native.testing.state.Event,
                    fixture.scratch,
                    event_value.value,
                ),
            );
            try fixture.namespace.store.database.run(
                "UPDATE events SET body=? WHERE task=? AND seq=?",
                &.{
                    .{ .blob = &rewritten.digest },
                    .{ .blob = &original.task },
                    .{ .integer = @intCast(event_value.value.seq) },
                },
            );
            changed = true;
            break;
        }
        event_query.deinit();
        try std.testing.expect(changed);
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspaceRecordsPrepared(
                fixture.scratch,
                original.task,
                index.records.items,
                history_compiler_facts,
            ),
        );
        fixture.namespace.store.rollback();
    }
}

fn expectCollectedSnapshotForgeries(
    fixture: CollectedHistoryFixture,
    original: anytype,
    original_evidence: anytype,
    original_reply: anytype,
    index: anytype,
    history_compiler_facts: anytype,
    hypothesis_record: anytype,
    hypothesis_ref: anytype,
    refs: anytype,
    future: anytype,
    future_reply: anytype,
) !void {
    for (0..9) |variant| {
        try fixture.namespace.store.begin();
        var evidence = try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            original_evidence,
        );
        const snapshots = try fixture.scratch.dupe(
            ?native.workspace.WorkObservation,
            evidence.value.evidence.read.works.works.items,
        );
        evidence.value.evidence.read.works.works.items = snapshots;
        var reply_json = try native.json.parse(
            fixture.scratch,
            original_reply.value.observation_json.bytes,
            .{},
        );
        try forgeCollectedSnapshots(
            fixture,
            original,
            &evidence,
            snapshots,
            &reply_json,
            variant,
            future,
            future_reply,
            hypothesis_record,
            hypothesis_ref,
            refs,
        );
        try publishCollectedSnapshotForgery(
            fixture,
            original,
            &evidence,
            &reply_json,
            original_reply,
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspaceRecordsPrepared(
                fixture.scratch,
                original.task,
                index.records.items,
                history_compiler_facts,
            ),
        );
        fixture.namespace.store.rollback();
    }
}

fn expectCollectedReceiptForgeries(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    original: anytype,
    index: anytype,
    history_compiler_facts: anytype,
    slow_start: anytype,
    started: anytype,
    future: anytype,
) !void {
    // A direct native operation receipt is replayable even without a root
    // workspace_reply record; its historical snapshot needs the same checks.
    for (0..3) |variant| {
        try fixture.namespace.store.begin();
        var receipt_query = try fixture.namespace.store.database.prepare(
            "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p" ++
                ".receipt WHERE p.task=?",
            &.{.{ .blob = &parent.receipt.task }},
        );
        const changed = try forgeCollectedReceipt(
            fixture,
            &receipt_query,
            slow_start,
            started,
            future,
            variant,
        );
        receipt_query.deinit();
        try std.testing.expect(changed);
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspaceRecordsPrepared(
                fixture.scratch,
                original.task,
                index.records.items,
                history_compiler_facts,
            ),
        );
        fixture.namespace.store.rollback();
    }
}

fn collectionLaterHistory(
    fixture: CollectedHistoryFixture,
    manifest_digest: anytype,
    parent: anytype,
    program: anytype,
    input: anytype,
    work: anytype,
    hypothesis_ref: anytype,
    hypothesis_record: anytype,
    refs: anytype,
    original: anytype,
    original_evidence: anytype,
    current_history_reads: anytype,
) !void {
    // Later publications do not rewrite the earlier collection or invalidate
    // its genuinely missing member.
    _ = try fixture.service.workspaceStart(
        fixture.scratch,
        "collect-later-start",
        parent.receipt.task,
        program.receipt.workspace.?,
        input,
        .{},
    );
    try fixture.service.validateWorkspace(fixture.scratch, parent.receipt.task);
    try std.testing.expectEqualStrings(
        original_evidence,
        (try fixture.namespace.store.recordBytes(
            fixture.scratch,
            "workspace_reply",
            original.id,
            original.task,
        )).?,
    );
    try expectCollectedJudgment(fixture, parent, hypothesis_ref);
    const before_forgery = try fixture.namespace.store.archiveIndex(
        fixture.scratch,
        original.task,
        .{ .digest = manifest_digest, .bytes = fixture.manifest.len },
    );
    var final_compiler_facts = try fixture.service.prepareWorkspaceValidation(original.task);
    defer final_compiler_facts.deinit();
    try expectCollectedDerivationForgeries(
        fixture,
        before_forgery,
        &final_compiler_facts,
        original,
        hypothesis_record,
    );
    try expectCollectedHistoryReadCosts(fixture, parent, refs, current_history_reads);
    try observerHistoricalReadScaling(
        fixture.service,
        fixture.scratch,
        parent.receipt.task,
        work.value,
        hypothesis_ref,
        fixture.meter,
    );
}

fn expectCollectedDerivationForgeries(
    fixture: CollectedHistoryFixture,
    before_forgery: anytype,
    final_compiler_facts: anytype,
    original: anytype,
    hypothesis_record: anytype,
) !void {
    for (0..2) |variant| {
        try fixture.namespace.store.begin();
        var forged = hypothesis_record.?;
        if (variant == 0) {
            forged.derivation.kind = .judgment;
        } else {
            forged.derivation.sources.items = &.{hypothesis_record.?.artifact};
        }
        try publishCollectedDerivation(fixture, &forged);
        const records = try fixture.scratch.alloc(
            native.testing.state.ArchiveRecord,
            before_forgery.records.items.len + 1,
        );
        @memcpy(records[0..before_forgery.records.items.len], before_forgery.records.items);
        records[records.len - 1] = .{
            .kind = .workspace_value,
            .id = forged.id,
            .body = try fixture.namespace.store.putObject(
                try contracts.encodeOwned(native.workspace.Value, fixture.scratch, forged),
            ),
        };
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspaceRecordsPrepared(
                fixture.scratch,
                original.task,
                records,
                final_compiler_facts,
            ),
        );
        const inspected = try fixture.service.workspaceCommand(
            fixture.scratch,
            "forged-derivation",
            original.task,
            .{ .context = .{ .expand = .{ .reference = try workspaceRef(
                fixture.scratch,
                .value,
                forged.artifact.digest,
            ), .page = .{} } } },
        );
        try std.testing.expectEqual(.rejected, inspected.disposition);
        fixture.namespace.store.rollback();
    }
}

fn expectCollectedHistoryReadCosts(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    refs: anytype,
    current_history_reads: anytype,
) !void {
    for (0..3) |read| {
        const command: contracts.workspace.Command = .{ .work = if (read % 2 == 0)
            .{ .inspect = .{ .work = refs[0] } }
        else
            .{ .collect = .{ .works = .{ .items = refs } } } };
        _ = try fixture.service.message(
            fixture.scratch,
            try std.fmt.allocPrint(fixture.scratch, "archive-history-read-{d}", .{read}),
            parent.receipt.task,
            command,
        );
        var captured = false;
        for (0..64) |_| {
            _ = try fixture.service.pump(fixture.scratch);
            var replies = try fixture.namespace.store.database.prepare(
                "SELECT count(*) FROM records WHERE task=? AND kind='workspace_rep" ++
                    "ly'",
                &.{.{ .blob = &parent.receipt.task }},
            );
            defer replies.deinit();
            try std.testing.expect(try replies.step() == .row);
            if (try replies.integer(0) != read + 2) continue;
            captured = true;
            break;
        }
        try std.testing.expect(captured);
        if (read != 1) {
            const current = try archiveHistoryReads(
                fixture.service,
                fixture.scratch,
                parent.receipt.task,
                fixture.meter,
            );
            try std.testing.expectEqual(current_history_reads.current_scans, current.current_scans);
        }
    }
}

fn forgeCollectedSnapshots(
    fixture: CollectedHistoryFixture,
    original: anytype,
    evidence: anytype,
    snapshots: anytype,
    reply_json: anytype,
    variant: anytype,
    future: anytype,
    future_reply: anytype,
    hypothesis_record: anytype,
    hypothesis_ref: anytype,
    refs: anytype,
) !void {
    if (variant >= 5) {
        try forgeCollectedControlSnapshot(fixture, original, snapshots, reply_json, variant);
    } else if (variant >= 3) {
        try forgeCollectedFutureSnapshot(
            fixture,
            original,
            evidence,
            snapshots,
            reply_json,
            variant,
            future,
            future_reply,
        );
    } else if (variant == 0) {
        snapshots[0].?.work.result_value = hypothesis_record.?.artifact;
        try native.json.put(
            fixture.scratch,
            &reply_json.value.array.items[0],
            "result",
            try native.values.toJson(contracts.workspace.Ref, fixture.scratch, hypothesis_ref),
        );
    } else {
        snapshots[0] = null;
        if (variant == 2) evidence.value.evidence.read.works.event_watermark = 0;
        var missing = native.json.object();
        try native.json.put(
            fixture.scratch,
            &missing,
            "work",
            try native.values.toJson(contracts.workspace.Ref, fixture.scratch, refs[0]),
        );
        try native.json.put(
            fixture.scratch,
            &missing,
            "outcome",
            native.json.string("unavailable"),
        );
        reply_json.value.array.items[0] = missing;
    }
}

fn publishCollectedSnapshotForgery(
    fixture: CollectedHistoryFixture,
    original: anytype,
    evidence: anytype,
    reply_json: anytype,
    original_reply: anytype,
) !void {
    const forged_evidence = try fixture.namespace.store.putObject(
        try contracts.encodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            evidence.value,
        ),
    );
    // Simulate an archive attacker: rewrite both evidence and acquired reply
    // with correct content hashes, without changing the genuine work.
    try fixture.namespace.store.database.run(
        "UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?",
        &.{ .{ .blob = &forged_evidence.digest }, .{ .blob = &original.id } },
    );
    var forged_reply = original_reply.value;
    forged_reply.observation_json.bytes = try native.json.canonical(
        fixture.scratch,
        reply_json.value,
    );
    const payload = try contracts.encodeOwned(
        contracts.workspace.Reply,
        fixture.scratch,
        forged_reply,
    );
    const bound = try data.invocation.encodeOwned(data.invocation.Result, fixture.scratch, .{
        .request_identity = original.request,
        .value = payload,
    });
    const current_occurrence = (try fixture.namespace.store.recordBytes(
        fixture.scratch,
        "occurrence",
        original.id,
        original.task,
    )).?;
    var forged_occurrence = (try contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        fixture.scratch,
        current_occurrence,
    )).value;
    const forged_digest = (try fixture.namespace.store.putObject(bound)).digest;
    switch (forged_occurrence.state) {
        .settled_reply => |*reply| reply.reply = forged_digest,
        .admitted => |*reply| reply.reply.reply = forged_digest,
        else => return error.UnexpectedReadState,
    }
    try fixture.namespace.store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        original.id,
        original.task,
        forged_occurrence,
    );
}

fn forgeCollectedControlSnapshot(
    fixture: CollectedHistoryFixture,
    original: anytype,
    snapshots: anytype,
    reply_json: anytype,
    variant: anytype,
) !void {
    const historical = &snapshots[2].?.work;
    switch (variant) {
        5, 8 => historical.policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
        6 => historical.schedule = .queued,
        7 => historical.blocker = .incompatible_profile,
        else => unreachable,
    }
    if (variant == 6) try native.json.put(
        fixture.scratch,
        &reply_json.value.array.items[2],
        "schedule",
        native.json.string("queued"),
    );
    if (variant == 7) try native.json.put(
        fixture.scratch,
        &reply_json.value.array.items[2],
        "blocker",
        native.json.string("incompatible_profile"),
    );
    try forgeCollectedControlEvent(fixture, original, snapshots, variant, historical);
}

fn forgeCollectedFutureSnapshot(
    fixture: CollectedHistoryFixture,
    original: anytype,
    evidence: anytype,
    snapshots: anytype,
    reply_json: anytype,
    variant: anytype,
    future: anytype,
    future_reply: anytype,
) !void {
    const original_watermark = snapshots[2].?.work.event_watermark;
    try std.testing.expect(snapshots[2].?.work.outcome_kind == .yielded);
    snapshots[2].?.work = future.value;
    snapshots[2].?.work.event_watermark = original_watermark;
    snapshots[2].?.occurrence = null;
    var future_json = try native.json.parse(
        fixture.scratch,
        future_reply.observation_json.bytes,
        .{},
    );
    try native.json.put(
        fixture.scratch,
        &future_json.value,
        "event_watermark",
        try native.json.number(fixture.scratch, evidence.value.evidence.read.works.event_watermark),
    );
    reply_json.value.array.items[2] = future_json.value;
    try forgeCollectedFutureEvent(
        fixture,
        original,
        snapshots,
        variant,
        future,
        original_watermark,
    );
}

fn forgeCollectedControlEvent(
    fixture: CollectedHistoryFixture,
    original: anytype,
    snapshots: anytype,
    variant: anytype,
    historical: anytype,
) !void {
    var event_query = try fixture.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
            "RE e.task=? AND e.seq=?",
        &.{
            .{ .blob = &original.task },
            .{ .integer = @intCast(historical.event_watermark) },
        },
    );
    defer event_query.deinit();
    try std.testing.expect(try event_query.step() == .row);
    var event_value = try contracts.decodeOwned(
        native.testing.state.Event,
        fixture.scratch,
        try event_query.bytes(0),
    );
    const publications = try fixture.scratch.dupe(
        native.testing.state.WorkPublication,
        event_value.value.workspace_publications.items,
    );
    event_value.value.workspace_publications.items = publications;
    for (publications) |*item| {
        if (std.meta.eql(item.work, historical.id)) {
            item.control = native.workspace.ControlObservation.from(snapshots[2].?);
            try forgeCollectedStartPolicy(fixture, &event_value, historical, variant);
            std.crypto.hash.sha2.Sha256.hash(try contracts.encodeOwned(
                native.workspace.WorkObservation,
                fixture.scratch,
                snapshots[2].?,
            ), &item.observation, .{});
        }
    }
    const rewritten = try fixture.namespace.store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, fixture.scratch, event_value.value),
    );
    try fixture.namespace.store.database.run(
        "UPDATE events SET body=? WHERE task=? AND seq=?",
        &.{
            .{ .blob = &rewritten.digest },
            .{ .blob = &original.task },
            .{ .integer = @intCast(historical.event_watermark) },
        },
    );
}

fn forgeCollectedStartPolicy(
    fixture: CollectedHistoryFixture,
    event_value: anytype,
    historical: anytype,
    variant: anytype,
) !void {
    if (variant == 8) {
        var declared = try contracts.decodeOwned(
            native.workspace.PublicationCommand,
            fixture.scratch,
            try fixture.namespace.store.object(
                fixture.scratch,
                event_value.value.workspace_command.?,
                null,
            ),
        );
        declared.value.start.policy = historical.policy;
        event_value.value.workspace_command = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(
                native.workspace.PublicationCommand,
                fixture.scratch,
                declared.value,
            ),
        );
    }
}

fn forgeCollectedFutureEvent(
    fixture: CollectedHistoryFixture,
    original: anytype,
    snapshots: anytype,
    variant: anytype,
    future: anytype,
    original_watermark: anytype,
) !void {
    if (variant == 4) {
        // Updating the event digest too must not hide a future revision
        // before its actual publication sequence.
        var event_query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? AND e.seq=?",
            &.{ .{ .blob = &original.task }, .{ .integer = @intCast(original_watermark) } },
        );
        defer event_query.deinit();
        try std.testing.expect(try event_query.step() == .row);
        var event_value = try contracts.decodeOwned(
            native.testing.state.Event,
            fixture.scratch,
            try event_query.bytes(0),
        );
        const publications = try fixture.scratch.dupe(
            native.testing.state.WorkPublication,
            event_value.value.workspace_publications.items,
        );
        event_value.value.workspace_publications.items = publications;
        for (publications) |*item| {
            if (!std.meta.eql(item.work, future.value.id)) continue;
            item.execution_revision = future.value.execution_revision;
            item.control_revision = future.value.control_revision;
            std.crypto.hash.sha2.Sha256.hash(try contracts.encodeOwned(
                native.workspace.WorkObservation,
                fixture.scratch,
                snapshots[2].?,
            ), &item.observation, .{});
        }
        const rewritten = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(
                native.testing.state.Event,
                fixture.scratch,
                event_value.value,
            ),
        );
        try fixture.namespace.store.database.run(
            "UPDATE events SET body=? WHERE task=? AND seq=?",
            &.{
                .{ .blob = &rewritten.digest },
                .{ .blob = &original.task },
                .{ .integer = @intCast(original_watermark) },
            },
        );
    }
}

fn forgeCollectedReceipt(
    fixture: CollectedHistoryFixture,
    receipt_query: anytype,
    slow_start: anytype,
    started: anytype,
    future: anytype,
    variant: anytype,
) !bool {
    while (try receipt_query.step() == .row) {
        var saved = try contracts.decodeOwned(
            native.testing.state.Receipt,
            fixture.scratch,
            try receipt_query.bytes(1),
        );
        if (!std.meta.eql(saved.value.id, slow_start.receipt.id)) continue;
        var historical = try contracts.decodeOwned(
            native.workspace.WorkObservation,
            fixture.scratch,
            try fixture.namespace.store.object(
                fixture.scratch,
                saved.value.workspace_observation.?,
                null,
            ),
        );
        switch (variant) {
            0 => historical.value.work.schedule = .queued,
            1 => historical.value = (try contracts.decodeOwned(
                native.workspace.WorkObservation,
                fixture.scratch,
                try fixture.namespace.store.object(
                    fixture.scratch,
                    started.receipt.workspace_observation.?,
                    null,
                ),
            )).value,
            2 => historical.value = .{ .work = future.value, .occurrence = null },
            else => unreachable,
        }
        saved.value.workspace_observation = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(
                native.workspace.WorkObservation,
                fixture.scratch,
                historical.value,
            ),
        );
        const rewritten = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(native.testing.state.Receipt, fixture.scratch, saved.value),
        );
        try fixture.namespace.store.database.run(
            "UPDATE operations SET receipt=? WHERE id=?",
            &.{ .{ .blob = &rewritten.digest }, .{ .text = try receipt_query.bytes(0) } },
        );
        return true;
    }
    return false;
}

const CollectedHistoryFixture = struct {
    meter: *kosmos.AllocationBudget,
    namespace: *native.Namespace,
    service: *native.tasks.Service(DelegateTypes),
    scratch: std.mem.Allocator,
    manifest: []const u8,
};

fn forgeCollectedRejectedReply(
    fixture: CollectedHistoryFixture,
    original: anytype,
    original_evidence: anytype,
) !void {
    var evidence = try contracts.decodeOwned(
        native.workspace.ReplyObservation,
        fixture.scratch,
        original_evidence,
    );
    evidence.value.evidence = .{ .rejected = .{ .stage = .operation, .code = .{
        .bytes = "Denied",
    } } };
    const forged = try fixture.namespace.store.putObject(
        try contracts.encodeOwned(
            native.workspace.ReplyObservation,
            fixture.scratch,
            evidence.value,
        ),
    );
    try fixture.namespace.store.database.run(
        "UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?",
        &.{ .{ .blob = &forged.digest }, .{ .blob = &original.id } },
    );
    const failed_reply: contracts.workspace.Reply = .{
        .disposition = .rejected,
        .observation_json = .{ .bytes = "{\"error\":\"Denied\"}" },
    };
    const payload = try contracts.encodeOwned(
        contracts.workspace.Reply,
        fixture.scratch,
        failed_reply,
    );
    const bound = try data.invocation.encodeOwned(data.invocation.Result, fixture.scratch, .{
        .request_identity = original.request,
        .value = payload,
    });
    var forged_occurrence = original;
    forged_occurrence.state.settled_reply.reply = (try fixture.namespace.store.putObject(
        bound,
    )).digest;
    try fixture.namespace.store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        original.id,
        original.task,
        forged_occurrence,
    );
}

fn publishCollectedDerivation(fixture: CollectedHistoryFixture, forged: anytype) !void {
    forged.description.provenance = try fixture.namespace.store.putObject(
        try contracts.encodeOwned(
            native.workspace.Derivation,
            fixture.scratch,
            forged.derivation,
        ),
    );
    forged.artifact = try fixture.namespace.store.putObject(
        try contracts.encodeOwned(
            native.workspace.ValueArtifact,
            fixture.scratch,
            forged.description,
        ),
    );
    forged.id = try native.workspace.custodyId(
        fixture.scratch,
        forged.task,
        forged.artifact.digest,
    );
    try fixture.namespace.store.createRecord(
        native.workspace.Value,
        "workspace_value",
        forged.id,
        forged.task,
        forged.*,
    );
}

fn expectCollectedJudgment(
    fixture: CollectedHistoryFixture,
    parent: anytype,
    hypothesis_ref: anytype,
) !void {
    const judgment = try fixture.service.workspaceCommand(
        fixture.scratch,
        "sourced-judgment",
        parent.receipt.task,
        .{ .context = .{ .materialize = .{
            .input = .{ .value = .{ .reference = hypothesis_ref } },
            .sources = .{ .items = &.{hypothesis_ref} },
        } } },
    );
    const judgment_json = (try native.json.parse(
        fixture.scratch,
        judgment.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expectEqualStrings(
        "judgment",
        judgment_json.object.get("derivation").?.object.get("kind").?.string,
    );
    try fixture.service.validateWorkspace(fixture.scratch, parent.receipt.task);
}

const WorkspaceCleanupApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const author = horos.authoring.interop;
        const input = try author.schemaId(c.author, try c.schema(ContextTypes.Input));
        const output = try author.schemaId(c.author, try c.schema(ContextTypes.Output));
        const effect = try author.operationId(
            c.author,
            try c.external(
                "workspace-context",
                try c.schema(ContextTypes.Input),
                try c.schema(ContextTypes.Output),
                .read,
            ),
        );
        const b = c.builder;
        const unit = try b.scalar(void);
        const info = try horos.source.library.cleanup.exitInfo(b, unit);
        const body = try b.declare(&.{}, output, &.{}, &.{});
        try b.define(
            body,
            try b.term(.{
                .yield_then = try b.pure(
                    try b.literal(.{
                        .schema = output,
                        .bytes = try contracts.encodeOwned(
                            ContextTypes.Output,
                            b.allocator(),
                            .{ .disposition = .observed, .observation_json = .{
                                .bytes = "{}",
                            } },
                        ),
                    }),
                ),
            }),
        );
        const cleanup = try b.declare(&.{info}, unit, &.{effect}, &.{});
        const request = try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.literal(.{
                .schema = input,
                .bytes = try contracts.encodeOwned(
                    ContextTypes.Input,
                    b.allocator(),
                    .{ .program = .{ .describe = .{ .section = .values, .page = .{} } } },
                ),
            }),
        } });
        try b.define(
            cleanup,
            try b.bind(try b.variable(output), request, try b.pure(try b.constant(void, {}))),
        );
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = output,
        } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
            info,
        }, .result = unit, .effects = &.{effect} } } });
        const entry = try b.declare(&.{input}, output, &.{effect}, &.{});
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

test "WORK-14 workspace reads settle inside root cancellation cleanup" {
    const a = std.testing.allocator;
    const protean = @import("protean");
    var compiled = try protean.compile(
        a,
        protean.system(.{
            .InitialArgs = ContextTypes.Input,
            .Result = ContextTypes.Output,
            .Failure = void,
            .application = WorkspaceCleanupApplication,
        }),
    );
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "context-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const assets: native.discovery.Assets = .{
        .image = image,
        .application = "context-unit",
        .manifest = "{}",
    };
    var handlers = try native.Registry.init(a, &.{.{
        .identity = "workspace-context",
        .resource_role = "workspace",
        .kind = .workspace,
        .workspace = ContextApplication.authorize,
        .payload_schema = ContextApplication.payloadSchema,
        .resume_schema = ContextApplication.resultSchema,
    }});
    defer handlers.deinit();
    try workspaceCleanupResources(a, &application, assets, handlers);
}

/// Fail exactly one allocation; persistent failure can hide an erroneous
/// fallback because encoding that fallback also needs memory.
const OneShotAllocator = struct {
    backing: std.mem.Allocator,
    fail_at: usize = std.math.maxInt(usize),
    calls: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ordinal = self.calls;
        self.calls += 1;
        if (ordinal == self.fail_at) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

test "delegated model interpretation preserves transient allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prepared = try preparedModelInterpretation(a);
    const reader = struct {
        fn read(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: native.registry.ObjectReference,
            _: usize,
        ) ![]u8 {
            return error.UnexpectedRead;
        }
    };
    var marker: u8 = 0;
    const context: native.registry.ProjectionContext = .{
        .allocator = a,
        .task = @splat(0),
        .tenant = "fixture",
        .profile = "fixture",
        .objects = .validating(&marker, reader.read),
    };
    for ([_][]const u8{
        "{\"json_value\":\"\\\"42\\\"\"}",
        "{\"json_\\u0076alue\":\"\\\"42\\\"\"}",
        "{\"json_value\":\"{\"}",
        "{\"json_value\":\"true\"}",
        "{}",
    }, 0..) |arguments, case| {
        try expectModelAllocationCase(a, context, prepared, arguments, case);
    }
}

const Reconstruction = @import("workspace_sources.zig").Reconstruction;
const ReconstructionModel = struct {
    fn invoke(_: native.Context, _: Reconstruction.Proposal) !Reconstruction.Response {
        return .{ .next = {} };
    }
    fn cleanup(_: native.Context, _: u64) !void {}
    fn rederiveCleanup(
        ctx: native.registry.RederivationContext,
        _: native.registry.RecoveryInput,
        _: []const u8,
        _: ?[]const u8,
    ) !native.registry.RederivationFinding {
        try ctx.checkCancellation();
        return .{ .result = try contracts.encodeOwned(void, ctx.allocator, {}) };
    }
    fn lookupCleanup(
        ctx: native.Context,
        input: native.registry.RecoveryInput,
        _: []const u8,
        _: ?[]const u8,
    ) ![]u8 {
        return std.mem.concat(ctx.allocator, u8, &.{ &input.attempt, &input.request_identity });
    }
    fn verifyCleanup(
        _: native.registry.ProjectionContext,
        input: native.registry.RecoveryInput,
        bytes: []const u8,
    ) !native.registry.RecoveryFinding {
        if (bytes.len != 64 or !std.mem.eql(
            u8,
            bytes[0..32],
            &input.attempt,
        ) or !std.mem.eql(u8, bytes[32..], &input.request_identity)) return .rejected;
        return .not_sent;
    }
    fn selection(
        ctx: native.registry.ProjectionContext,
        bytes: []const u8,
    ) !?contracts.workspace.Adoption {
        var response = try contracts.decodeOwned(Reconstruction.Response, ctx.allocator, bytes);
        defer response.deinit();
        if (response.value != .adopt) return null;
        return try native.values.fromJson(
            contracts.workspace.Adoption,
            ctx.allocator,
            try native.values.toJson(
                contracts.workspace.Adoption,
                ctx.allocator,
                response.value.adopt,
            ),
        );
    }
    fn permission(_: native.registry.ProjectionContext) !bool {
        return true;
    }
    fn offer(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var proposed = try contracts.decodeOwned(Reconstruction.Proposal, ctx.allocator, bytes);
        defer proposed.deinit();
        if (proposed.value.value == 4) return error.Denied;
        return ctx.allocator.dupe(u8, bytes);
    }
    fn prepare(ctx: native.registry.ProjectionContext, payload: []const u8) ![]u8 {
        return contracts.encodeOwned(struct {
            payload: contracts.Bytes(null),
            controller: ?native.registry.ControllerProjection,
            trial: ?native.registry.TrialProjection,
        }, ctx.allocator, .{
            .payload = .{ .bytes = payload },
            .controller = ctx.controller,
            .trial = ctx.trial,
        });
    }
    fn acquire(ctx: native.Context, _: []const u8) !native.registry.Acquisition {
        return .{
            .captured = try contracts.encodeOwned(
                Reconstruction.Response,
                ctx.allocator,
                .{ .next = {} },
            ),
        };
    }
    fn interpret(
        ctx: native.registry.ProjectionContext,
        payload: []const u8,
        prepared: []const u8,
        response: []const u8,
    ) !native.registry.Projection {
        const expected = try prepare(ctx, payload);
        defer ctx.allocator.free(expected);
        if (!std.mem.eql(u8, prepared, expected)) return error.InvalidProjection;
        return .{ .reply = try ctx.allocator.dupe(u8, response) };
    }
    fn declaration() native.Declaration {
        var model = native.registry.controllerImport(
            .deliberate,
            native.leaf(
                Reconstruction.Proposal,
                Reconstruction.Response,
                .{
                    .identity = "fixture.reconstruction.model",
                    .resource_role = "inference",
                    .inference = true,
                },
                invoke,
            ),
        );
        model.controller_choice = selection;
        model.controller_permission = permission;
        model.controller_offer = offer;
        model.invoke = null;
        model.background = true;
        model.capture = .{
            .dependencies = native.registry.opaqueProjection,
            .prepare = prepare,
            .acquire = acquire,
            .interpret = interpret,
        };
        return model;
    }
};

const ControllerOverlayTrace = struct {
    scans: usize = 0,
    rows: usize = 0,
    observer_scans: usize = 0,
    observer_rows: usize = 0,
    current_watermark: ?u64 = null,
    current_scans: usize = 0,
    extern "c" fn sqlite3_db_handle(?*anyopaque) ?*anyopaque;
    extern "c" fn sqlite3_sql(?*anyopaque) ?[*:0]const u8;
    extern "c" fn sqlite3_expanded_sql(?*anyopaque) ?[*:0]u8;
    extern "c" fn sqlite3_free(?*anyopaque) void;
    extern "c" fn sqlite3_trace_v2(
        ?*anyopaque,
        c_uint,
        ?*const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
        ?*anyopaque,
    ) c_int;

    fn observe(
        kind: c_uint,
        context: ?*anyopaque,
        statement: ?*anyopaque,
        sql: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const text = if (kind == 1)
            std.mem.span(@as([*:0]const u8, @ptrCast(sql.?)))
        else
            std.mem.span(sqlite3_sql(statement) orelse return 0);
        if (std.mem.eql(u8, text, "SELECT e.seq, o.body FROM events e " ++
            "JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? AND e.seq<=? ORDER BY e.seq"))
        {
            if (kind == 1) self.observer_scans += 1 else if (kind == 4) self.observer_rows += 1;
        }
        if (std.mem.eql(
            u8,
            text,
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? AND e.seq<=? ORDER BY e.seq",
        )) {
            if (kind == 1) self.scans += 1 else if (kind == 4) self.rows += 1;
            if (kind == 1) if (self.current_watermark) |watermark| {
                const expanded = sqlite3_expanded_sql(statement) orelse return 0;
                defer sqlite3_free(expanded);
                var buffer: [80]u8 = undefined;
                const suffix = std.fmt.bufPrint(&buffer, " AND e.seq<={d} ORDER BY e.seq", .{
                    watermark,
                }) catch |err| {
                    std.debug.panic(
                        "bounded SQL watermark formatting failed: {s}",
                        .{@errorName(err)},
                    );
                };
                if (std.mem.endsWith(u8, std.mem.span(expanded), suffix)) self.current_scans += 1;
            };
        }
        return 0;
    }
};

fn archiveReadObserver(
    service: anytype,
    a: std.mem.Allocator,
    source_work: native.workspace.Work,
    accumulator: contracts.workspace.Ref,
) ![32]u8 {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").cutObserver(&builder, false);
    const document = try native.source_records.encode(a, module);
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(
        a,
        "history-observer-program",
        source_work.task,
        document,
        &diagnostic,
    );
    const observed = try service.workspaceObserve(a, "history-observer-start", source_work.task, .{
        .program = try workspaceRef(a, .program, built.receipt.workspace.?),
        .source = .{ .expected = .{
            .work = try workspaceRef(a, .work, source_work.id),
            .execution_revision = source_work.execution_revision,
            .control_revision = source_work.control_revision,
        }, .realization_revision = source_work.realization_revision, .nodes = .{ .all = .{} } },
        .accumulator = accumulator,
        .policy = .{ .delivery = .lossless, .granularity = .one_guest_step },
    });
    return observed.receipt.workspace.?;
}

fn observerHistoricalReadScaling(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    source_work: native.workspace.Work,
    accumulator: contracts.workspace.Ref,
    meter: *kosmos.AllocationBudget,
) !void {
    const observer = try archiveReadObserver(service, a, source_work, accumulator);
    const source_ref = try workspaceRef(a, .work, source_work.id);
    var bounded = true;
    for (0..16) |read| {
        const operation_id = try std.fmt.allocPrint(a, "observer-history-read-{d}", .{read});
        _ = try service.message(a, operation_id, task, .{
            .work = .{ .inspect = .{ .work = source_ref } },
        });
        var captured = false;
        for (0..64) |_| {
            _ = try service.pump(a);
            var replies = try service.namespace.store.database.prepare(
                "SELECT count(*) FROM records WHERE task=? AND kind='workspace_rep" ++
                    "ly'",
                &.{.{ .blob = &task }},
            );
            defer replies.deinit();
            try std.testing.expect(try replies.step() == .row);
            if (try replies.integer(0) != read + 5) continue;
            captured = true;
            break;
        }
        try std.testing.expect(captured);
        if (read == 3 or read == 7 or read == 15) {
            std.debug.print("observer history growth: captured_reads={d}\n", .{read + 1});
            const profile = try archiveHistoryReads(service, a, task, meter);
            var parent = try service.task(a, task);
            defer parent.deinit();
            bounded = bounded and profile.observer_scans == 1 and
                profile.observer_rows == parent.value.event_high - parent.value.event_floor + 1;
        }
        if (read == 7) {
            var work = try service.workspaceWork(a, task, observer);
            defer work.deinit();
            try std.testing.expectEqual(.completed, work.value.outcome_kind);
            _ = try service.workspaceStopObserving(a, "history-observer-stop", task, .{
                .work = try workspaceRef(a, .work, observer),
                .execution_revision = work.value.execution_revision,
                .control_revision = work.value.control_revision,
            });
        }
    }
    var unchanged = try service.workspaceWork(a, task, source_work.id);
    defer unchanged.deinit();
    try std.testing.expectEqualDeep(source_work, unchanged.value);
    try std.testing.expect(bounded);
}

fn archiveHistoryReads(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    meter: *kosmos.AllocationBudget,
) !ControllerOverlayTrace {
    var parent = try service.task(a, task);
    defer parent.deinit();
    var statement = try service.namespace.store.database.prepare(
        "SELECT count(*) FROM records WHERE task=? AND kind='workspace_rep" ++
            "ly'",
        &.{.{ .blob = &task }},
    );
    defer statement.deinit();
    try std.testing.expect(try statement.step() == .row);
    const replies = try statement.integer(0);
    const database = ControllerOverlayTrace.sqlite3_db_handle(statement.handle);
    var trace: ControllerOverlayTrace = .{ .current_watermark = parent.value.event_high };
    try std.testing.expectEqual(
        @as(c_int, 0),
        ControllerOverlayTrace.sqlite3_trace_v2(
            database,
            1 | 4,
            ControllerOverlayTrace.observe,
            &trace,
        ),
    );
    defer std.debug.assert(ControllerOverlayTrace.sqlite3_trace_v2(database, 0, null, null) == 0);
    const initial_live = meter.live;
    meter.peak = initial_live;
    try service.validateWorkspace(service.allocator, task);
    std.debug.print("archive history queries: replies={d} events={d} current_scans={d} " ++
        "total_scans={d} decoded_event_rows={d} observer_scans={d} observe" ++
        "r_rows={d} " ++
        "validation_peak_bytes={d}\n", .{
        replies,    parent.value.event_high, trace.current_scans, trace.scans,
        trace.rows, trace.observer_scans,    trace.observer_rows, meter.peak - initial_live,
    });
    try std.testing.expect(trace.current_scans > 0);
    return trace;
}

fn reconstructionRuntimeAction(service: anytype, a: std.mem.Allocator) !void {
    const task = (try service.submit(a, "runtime-controller-task", .{ .items = &.{
        2,
        3,
    } })).receipt.task;
    var statement = try service.namespace.store.database.prepare("SELECT 1", &.{});
    const database = ControllerOverlayTrace.sqlite3_db_handle(statement.handle);
    statement.deinit();
    var state: RuntimeReconstructionState = .{};
    for (0..256) |_| {
        var before = try service.task(a, task);
        defer before.deinit();
        if (before.value.terminal()) {
            try expectRuntimeControllerTerminal(service, a, task, database, &state);
            return;
        }
        if (try switchRuntimeControllerBeforeDispatch(service, a, task, before, &state)) continue;
        var trace: ControllerOverlayTrace = .{};
        const progress = progress: {
            try std.testing.expectEqual(
                @as(c_int, 0),
                ControllerOverlayTrace.sqlite3_trace_v2(
                    database,
                    1 | 4,
                    ControllerOverlayTrace.observe,
                    &trace,
                ),
            );
            defer std.debug.assert(
                ControllerOverlayTrace.sqlite3_trace_v2(database, 0, null, null) == 0,
            );
            break :progress try service.pump(a);
        };
        try acquireRuntimeControllerWork(service, a, task, progress, &state);
        var after = try service.task(a, task);
        defer after.deinit();
        try expectRuntimeControllerTransition(service, a, task, before, after, trace, &state);
    }
    return error.ControllerRealizationDidNotComplete;
}

const RuntimeReconstructionState = struct {
    requested: ?@FieldType(contracts.workspace.Work, "realize_controller") = null,
    operator_switched: bool = false,
    switched: bool = false,
    calls: usize = 0,
    live_offers: usize = 0,
};

fn expectRuntimeControllerTerminal(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    database: anytype,
    state: *RuntimeReconstructionState,
) !void {
    if (!state.operator_switched or !state.switched) return error.ControllerRealizationNotObserved;
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expect(state.live_offers > 0);
    var trace: ControllerOverlayTrace = .{};
    try std.testing.expectEqual(
        @as(c_int, 0),
        ControllerOverlayTrace.sqlite3_trace_v2(
            database,
            1 | 4,
            ControllerOverlayTrace.observe,
            &trace,
        ),
    );
    defer std.debug.assert(
        ControllerOverlayTrace.sqlite3_trace_v2(database, 0, null, null) == 0,
    );
    try service.validateWorkspace(a, task);
    try std.testing.expect(trace.scans > 0);
    try std.testing.expect(trace.rows > 0);
    return;
}

fn switchRuntimeControllerBeforeDispatch(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    before: anytype,
    state: *RuntimeReconstructionState,
) !bool {
    if (!state.operator_switched and before.value.controller_interaction != null) {
        const id = before.value.controller_interaction.?;
        var interaction = try contracts.decodeOwned(
            native.testing.state.ControllerInteraction,
            a,
            (try service.namespace.store.recordBytes(a, "controller_interaction", id, task)).?,
        );
        defer interaction.deinit();
        if (interaction.value.model != null and
            std.meta.eql(interaction.value.model, before.value.current_occurrence))
        {
            const pending_bytes = (try service.namespace.store.recordBytes(
                a,
                "occurrence",
                before.value.current_occurrence.?,
                task,
            )).?;
            defer a.free(pending_bytes);
            var pending = try contracts.decodeOwned(
                native.testing.occurrence.Occurrence,
                a,
                pending_bytes,
            );
            defer pending.deinit();
            try std.testing.expectEqual(.ready, std.meta.activeTag(pending.value.state));
            try std.testing.expectEqual(@as(usize, 0), state.calls);
            _ = try service.workspaceRealizeController(
                a,
                "operator-runtime-switch-before-dispatch",
                task,
                .{ .expected = .{ .cut = .{
                    .epoch = before.value.controller_epoch,
                    .execution_revision = before.value.execution_revision,
                    .realization_revision = before.value.realization_revision,
                } }, .runtime = .{ .packaged = .{} } },
            );
            try expectOperatorRuntimePreserved(service, a, task, before, pending_bytes);
            state.operator_switched = true;
            return true;
        }
    }
    return false;
}

fn acquireRuntimeControllerWork(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    progress: anytype,
    state: *RuntimeReconstructionState,
) !void {
    if (progress == .work) {
        if (!progress.work.entry.declaration.inference) {
            try service.acquire(a, progress.work, &.{});
        } else {
            state.calls += 1;
            var current = try service.task(a, task);
            defer current.deinit();
            if (state.requested == null) {
                const target = try runtimeControllerTarget(
                    service,
                    a,
                    task,
                    current,
                    state.operator_switched,
                );
                state.requested = .{ .expected = target, .runtime = .{ .packaged = .{} } };
                try service.acquire(
                    a,
                    progress.work,
                    try contracts.encodeOwned(Reconstruction.Response, a, .{
                        .realize = state.requested.?,
                    }),
                );
            } else try service.acquire(
                a,
                progress.work,
                try contracts.encodeOwned(Reconstruction.Response, a, .{ .next = {} }),
            );
        }
    }
}

fn expectRuntimeControllerTransition(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    before: anytype,
    after: anytype,
    trace: ControllerOverlayTrace,
    state: *RuntimeReconstructionState,
) !void {
    if (before.value.realization_revision != 0 and after.value.controller_interaction != null and
        !std.meta.eql(before.value.controller_interaction, after.value.controller_interaction))
    {
        state.live_offers += 1;
        std.debug.print("controller live overlay: events={d} history_scans={d} history_row" ++
            "s={d}\n", .{ before.value.event_high, trace.scans, trace.rows });
        try std.testing.expectEqual(@as(usize, 0), trace.scans);
        try std.testing.expectEqual(@as(usize, 0), trace.rows);
    }
    if (after.value.realization_revision != before.value.realization_revision) {
        try std.testing.expect(!state.switched);
        try std.testing.expectEqual(
            before.value.realization_revision + 1,
            after.value.realization_revision,
        );
        try std.testing.expectEqual(
            before.value.controller_epoch,
            after.value.controller_epoch,
        );
        try std.testing.expectEqual(
            before.value.execution_revision,
            after.value.execution_revision,
        );
        try std.testing.expectEqualDeep(before.value.checkpoint, after.value.checkpoint);
        try std.testing.expectEqualDeep(
            before.value.current_occurrence,
            after.value.current_occurrence,
        );
        try std.testing.expectEqualDeep(before.value.controller, after.value.controller);
        const operation = std.fmt.bytesToHex(before.value.current_occurrence.?, .lower);
        try std.testing.expect(
            (try service.workspaceRealizeController(
                a,
                &operation,
                task,
                state.requested.?,
            )).replayed,
        );
        try std.testing.expectError(
            error.StaleController,
            service.workspaceRealizeController(
                a,
                "stale-controller-action",
                task,
                state.requested.?,
            ),
        );
        var changed = state.requested.?;
        changed.expected.action.epoch += 1;
        try std.testing.expectError(
            error.OperationConflict,
            service.workspaceRealizeController(a, &operation, task, changed),
        );
        try service.validateWorkspace(a, task);
        state.switched = true;
    }
}

fn reconstructionSource(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    epoch: u64,
    program: contracts.workspace.Ref,
    expected_source: []const u8,
) !void {
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(a);
    var next_offset: ?usize = 0;
    while (next_offset) |_| {
        const observed = try service.workspaceCommand(
            a,
            try std.fmt.allocPrint(a, "controller-inspect-{d}-{d}", .{
                epoch,
                parts.items.len,
            }),
            task,
            .{ .program = .{ .describe = .{ .section = .current_controller, .page = .{
                .offset = parts.items.len,
                .maximum = 48 * 1024,
            } } } },
        );
        try std.testing.expectEqual(.observed, observed.disposition);
        var page = try native.json.parse(a, observed.observation_json.bytes, .{});
        defer page.deinit();
        const fragment = native.json.get(page.value, "text").?.string;
        try parts.appendSlice(a, fragment);
        next_offset = if (native.json.get(page.value, "eof").?.bool) null else parts.items.len;
        if (next_offset != null) try std.testing.expect(fragment.len != 0);
    }
    var description = try native.json.parse(a, parts.items, .{});
    defer description.deinit();
    const actual_program = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        native.json.get(description.value, "program").?,
    );
    try std.testing.expectEqualStrings(program.id.bytes, actual_program.id.bytes);
    const source_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        native.json.get(description.value, "source").?,
    );
    var source_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(expected_source, &source_digest, .{});
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(source_digest, .lower),
        source_ref.id.bytes,
    );
    try reconstructionSourceBytes(service, a, task, epoch, source_ref, expected_source);
}

fn reconstructionValue(
    comptime T: type,
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    id: []const u8,
    value: T,
) !contracts.workspace.Ref {
    const schema = try native.values.schemaBytes(T, a);
    var projected = try native.dynamic_values.decode(
        a,
        schema,
        try contracts.encodeOwned(T, a, value),
    );
    defer projected.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(schema, &digest, .{});
    const reply = try service.workspaceCommand(
        a,
        id,
        task,
        .{
            .context = .{
                .materialize = .{
                    .input = .{ .value = .{ .inline_json = .{ .schema = try workspaceRef(
                        a,
                        .schema,
                        digest,
                    ), .json_text = .{
                        .bytes = try native.json.canonical(a, projected.value),
                    } } } },
                    .sources = .{ .items = &.{} },
                },
            },
        },
    );
    if (reply.disposition != .observed) std.debug.print("trial value {s}: {s}\n", .{
        id,
        reply.observation_json.bytes,
    });
    try std.testing.expectEqual(.observed, reply.disposition);
    return reply.evidence.?;
}

fn reconstructionTrials(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    original: contracts.workspace.Ref,
    successor: contracts.workspace.Ref,
    converter: contracts.workspace.Ref,
) !void {
    try service.park(a);
    var before = try service.task(a, task);
    defer before.deinit();
    const payload = try reconstructionTrialPayload(service, a, task);
    const response = reconstructionTrialResponse(successor, converter);
    const response_ref = try reconstructionValue(
        Reconstruction.Response,
        service,
        a,
        task,
        "trial-response",
        response,
    );
    const cleanup_payload = try reconstructionValue(u64, service, a, task, "trial-cleanup", 7);
    const unit = try reconstructionValue(void, service, a, task, "trial-unit", {});
    const Response = std.meta.Elem(
        @FieldType(
            @FieldType(@FieldType(contracts.workspace.Trial, "synthetic"), "responses"),
            "items",
        ),
    );
    const responses = [_]Response{
        .{
            .identity = .{ .bytes = contracts.controller.effect_prefix ++ "deliberate" },
            .payload = payload,
            .response = response_ref,
        },
        .{
            .identity = .{ .bytes = contracts.controller.effect_prefix ++ "snapshot" },
            .payload = cleanup_payload,
            .response = unit,
        },
    };
    var first_trial: ?[32]u8 = null;
    for (0..18) |case| {
        try reconstructionTrialCase(
            .{
                .service = service,
                .a = a,
                .task = task,
                .original = original,
                .response = response,
                .responses = responses,
                .unit = unit,
                .before = before,
            },
            case,
            &first_trial,
        );
    }
    var current = try service.task(a, task);
    defer current.deinit();
    _ = try service.resumeTask(a, "after-trials", task, current.value.revision);
}

const ReconstructionTrialDrive = struct {
    bounded_trial_pump: bool = false,
    cleanup_admitted: bool = false,
};

fn reconstructionTrialPayload(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
) !contracts.workspace.Ref {
    const proposal: Reconstruction.Proposal = .{
        .position = 0,
        .value = 2,
        .total = 2,
        .covered = 1,
        .indexed = false,
        .instruction_cut = 1,
    };
    const carry: Reconstruction.Direct = .{
        .records = .{ .items = &.{2} },
        .position = 1,
        .total = 2,
        .covered = 1,
        .instruction_cut = 1,
        .revisit = false,
    };
    const Payload = struct { proposal: Reconstruction.Proposal, carry: Reconstruction.Direct };
    const payload = try reconstructionValue(Payload, service, a, task, "trial-proposal", .{
        .proposal = proposal,
        .carry = carry,
    });
    return payload;
}

fn reconstructionTrialCase(fixture: anytype, case: usize, first_trial: *?[32]u8) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    const original = fixture.original;
    const responses = fixture.responses;
    const unit = fixture.unit;
    const before = fixture.before;
    errdefer std.debug.print("controller trial case {d}\n", .{case});
    const input = try reconstructionValue(
        Reconstruction.Types.ControllerInput,
        service,
        a,
        task,
        try std.fmt.allocPrint(a, "trial-input-{d}", .{case}),
        .{ .anchor = .{
            .task = task,
        }, .private = .{ .initial = .{ .items = if (case == 1) &.{
            3,
        } else if (case == 7) &.{4} else &.{2} } } },
    );
    try rejectInvalidTrialResponses(fixture, case, input);
    var selected_responses = responses;
    if (case == 6) selected_responses[0].response = unit;
    const cancelled = case == 16 or case == 17;
    const explicit = case == 3 or case == 4 or case == 5 or cancelled;
    if (case == 0) service.checked_workspace_programs.clearRetainingCapacity();
    const started = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "trial-start-{d}", .{case}),
        task,
        .{ .work = .{ .start = .{ .program = original, .input = .{
            .reference = input,
        }, .policy = .{
            .stop = .terminal,
            .continuation = if (explicit) .explicit_only else .owner_scheduled,
        }, .trial = .{ .synthetic = .{
            .responses = .{
                .items = if (case == 2) selected_responses[1..] else &selected_responses,
            },
            .live_inference = case == 2,
        } } } } },
    );
    try std.testing.expectEqual(.observed, started.disposition);
    const started_json = (try native.json.parse(a, started.observation_json.bytes, .{})).value;
    const work_ref = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        native.json.get(started_json, "work").?,
    );
    const id = try nativeIdentity(work_ref);
    if (case == 0) first_trial.* = id;
    try rejectChangedTrialProvenance(fixture, case, id, first_trial.*);
    try driveReconstructionTrial(fixture, case, id, work_ref, cancelled, explicit);
    var after = try service.task(a, task);
    defer after.deinit();
    try std.testing.expectEqualDeep(before.value.controller, after.value.controller);
    try std.testing.expectEqual(@as(u64, 0), after.value.controller_epoch);
    try std.testing.expectEqual(
        @as(u64, if (case >= 2) 1 else 0),
        after.value.inference_attempts,
    );
    try std.testing.expect(after.value.controller_succession == null);
}

fn rejectInvalidTrialResponses(
    fixture: anytype,
    case: usize,
    input: contracts.workspace.Ref,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    const original = fixture.original;
    const responses = fixture.responses;
    if (case == 0) {
        for (0..2) |invalid| {
            var invalid_responses = [_]@TypeOf(responses[0]){ responses[0], responses[0] };
            if (invalid == 1) invalid_responses[0].response = try workspaceRef(
                a,
                .value,
                @splat(83),
            );
            const rejected = try service.workspaceCommand(
                a,
                try std.fmt.allocPrint(a, "trial-invalid-{d}", .{invalid}),
                task,
                .{ .work = .{ .start = .{ .program = original, .input = .{
                    .reference = input,
                }, .policy = .{}, .trial = .{ .synthetic = .{ .responses = .{
                    .items = &invalid_responses,
                } } } } } },
            );
            try std.testing.expectEqual(.rejected, rejected.disposition);
            try std.testing.expect(!service.namespace.store.fenced);
            var available = try service.task(a, task);
            available.deinit();
        }
    }
}

fn rejectChangedTrialProvenance(
    fixture: anytype,
    case: usize,
    id: [32]u8,
    first_trial: ?[32]u8,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    if (case == 1 or case == 2) {
        const store = &service.namespace.store;
        var saved_trial = try contracts.decodeOwned(
            native.workspace.Trial,
            a,
            (try store.recordBytes(a, "workspace_trial", id, task)).?,
        );
        defer saved_trial.deinit();
        var prior_trial = try contracts.decodeOwned(
            native.workspace.Trial,
            a,
            (try store.recordBytes(a, "workspace_trial", first_trial.?, task)).?,
        );
        defer prior_trial.deinit();
        for (0..@as(usize, if (case == 1) 2 else 1)) |variant| {
            var altered = saved_trial.value;
            if (variant == 0) {
                const live = &altered.selection.synthetic.live_inference;
                live.* = !live.*;
            } else {
                altered.view = prior_trial.value.view;
                altered.view_works = prior_trial.value.view_works;
            }
            try store.begin();
            defer store.rollback();
            try store.putRecord(native.workspace.Trial, "workspace_trial", id, task, altered);
            try std.testing.expectError(
                error.InvalidArchive,
                service.validateWorkspace(a, task),
            );
            store.rollback();
        }
    }
}

fn driveReconstructionTrial(
    fixture: anytype,
    case: usize,
    id: [32]u8,
    work_ref: contracts.workspace.Ref,
    cancelled: bool,
    explicit: bool,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    var state: ReconstructionTrialDrive = .{};
    for (0..128) |_| {
        var work = try service.workspaceWork(a, task, id);
        defer work.deinit();
        if (work.value.terminal()) {
            try expectReconstructionTrialTerminal(
                fixture,
                case,
                work,
                cancelled,
                state.cleanup_admitted,
            );
            break;
        }
        if (work.value.blocker != null) {
            try stopUnavailableReconstructionTrial(fixture, case, work, id, work_ref);
            break;
        }
        if (explicit and work.value.schedule == .parked) {
            try advanceExplicitReconstructionTrial(
                fixture,
                case,
                work,
                id,
                work_ref,
                cancelled,
                &state,
            );
            continue;
        }
        try pumpReconstructionTrial(fixture, case, id);
    } else return error.TrialDidNotSettle;
    if (case == 4) try std.testing.expect(state.bounded_trial_pump);
}

fn expectReconstructionTrialTerminal(
    fixture: anytype,
    case: usize,
    work: anytype,
    cancelled: bool,
    cleanup_admitted: bool,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    try std.testing.expect(case != 1 and case != 6 and case != 7);
    if (cancelled) {
        try std.testing.expect(cleanup_admitted);
        try std.testing.expect(work.value.cancellation_applied);
        try std.testing.expectEqual(.cancelled, work.value.outcome_kind);
        try service.validateWorkspace(a, task);
        return;
    }
    try std.testing.expectEqual(.completed, work.value.outcome_kind);
    const result = (try contracts.decodeOwned(
        Reconstruction.Output,
        a,
        try service.namespace.store.object(a, work.value.result.?, null),
    )).value;
    try std.testing.expectEqualDeep(
        Reconstruction.Output{ .total = 2, .covered = 1, .instruction_cut = 1 },
        result,
    );
    const value = (try contracts.decodeOwned(
        native.workspace.ValueArtifact,
        a,
        try service.namespace.store.object(a, work.value.result_value.?, null),
    )).value;
    const derivation = (try contracts.decodeOwned(
        native.workspace.Derivation,
        a,
        try service.namespace.store.object(a, value.provenance, null),
    )).value;
    try std.testing.expectEqual(.trial, derivation.kind);
    const retained = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "trial-retain-{d}", .{case}),
        task,
        .{ .context = .{ .materialize = .{ .input = .{ .value = .{
            .reference = try workspaceRef(a, .value, work.value.result_value.?.digest),
        } }, .sources = .{ .items = &.{} } } } },
    );
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(work.value.result_value.?.digest, .lower),
        retained.evidence.?.id.bytes,
    );
}

fn stopUnavailableReconstructionTrial(
    fixture: anytype,
    case: usize,
    work: anytype,
    id: [32]u8,
    work_ref: contracts.workspace.Ref,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    try std.testing.expect(case == 1 or case == 6 or case == 7);
    try std.testing.expectEqual(
        @as(
            ?native.testing.state.Blocker,
            switch (case) {
                1 => .unavailable_environment,
                7 => .denied,
                else => .incompatible_profile,
            },
        ),
        work.value.blocker,
    );
    const inspected = try service.workspaceCommand(
        a,
        try std.fmt.allocPrint(a, "trial-unavailable-{d}", .{case}),
        task,
        .{ .work = .{ .inspect = .{ .work = work_ref } } },
    );
    try std.testing.expect(
        std.mem.indexOf(u8, inspected.observation_json.bytes, "trial_proposal") != null,
    );
    _ = try service.workspaceControl(a, try std.fmt.allocPrint(a, "trial-stop-{d}", .{
        case,
    }), task, id, work.value.execution_revision, work.value.control_revision, .{
        .cancel = .{ .bytes = "No usable trial answer" },
    });
    for (0..32) |_| {
        var stopped = try service.workspaceWork(a, task, id);
        defer stopped.deinit();
        if (stopped.value.terminal()) break;
        _ = try service.pump(a);
    } else return error.TrialDidNotStop;
}

fn advanceExplicitReconstructionTrial(
    fixture: anytype,
    case: usize,
    work: anytype,
    id: [32]u8,
    work_ref: contracts.workspace.Ref,
    cancelled: bool,
    state: *ReconstructionTrialDrive,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    if (try cancelReconstructionTrial(fixture, case, work, id, cancelled, state)) return;
    if (try pumpBoundedReconstructionTrial(fixture, case, work, id, work_ref, state)) return;
    const operation_id = try std.fmt.allocPrint(a, "trial-explicit-{d}-{d}-{d}", .{
        case,
        work.value.execution_revision,
        work.value.control_revision,
    });
    const expected: contracts.workspace.Expected = .{
        .work = work_ref,
        .execution_revision = work.value.execution_revision,
        .control_revision = work.value.control_revision,
    };
    const command: contracts.workspace.Command = .{
        .work = if (case == 4 or case == 17) .{ .pump = .{
            .expected = expected,
            .base_quantum = 65536,
        } } else if (case == 5) .{ .delegate = .{ .expected = expected, .policy = .{
            .stop = .terminal,
            .continuation = .owner_scheduled,
        }, .interpretation = .{ .none = .{} } } } else .{ .advance = expected },
    };
    const advanced = try service.workspaceCommand(a, operation_id, task, command);
    try std.testing.expectEqual(.observed, advanced.disposition);
    if (cancelled and state.cleanup_admitted) {
        var queued = try service.workspaceWork(a, task, id);
        defer queued.deinit();
        try std.testing.expectEqual(.queued, queued.value.schedule);
        try std.testing.expectEqual(
            work.value.execution_revision,
            queued.value.execution_revision,
        );
        try std.testing.expectEqualDeep(
            work.value.current_occurrence,
            queued.value.current_occurrence,
        );
        try service.validateWorkspace(a, task);
    }
    const replayed = try service.workspaceCommand(a, operation_id, task, command);
    const observation = (try native.json.parse(
        a,
        replayed.observation_json.bytes,
        .{},
    )).value;
    try std.testing.expect(native.json.get(observation, "replayed").?.bool);
    return;
}

fn pumpReconstructionTrial(fixture: anytype, case: usize, id: [32]u8) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    const response = fixture.response;
    const step = try service.pump(a);
    if (case == 0) {
        var after_step = try service.workspaceWork(a, task, id);
        defer after_step.deinit();
        if (after_step.value.current_occurrence) |occurrence_id| {
            const bytes = (try service.namespace.store.recordBytes(
                a,
                "occurrence",
                occurrence_id,
                task,
            )).?;
            const pending = (try contracts.decodeOwned(
                native.testing.occurrence.Occurrence,
                a,
                bytes,
            )).value;
            if (pending.state == .settled_reply) try service.validateWorkspace(a, task);
        }
    }
    if (step == .work) {
        try std.testing.expectEqual(@as(usize, 2), case);
        try std.testing.expectEqualDeep(id, step.work.subject_work.?);
        try service.acquire(
            a,
            step.work,
            try contracts.encodeOwned(Reconstruction.Response, a, response),
        );
    }
}

fn cancelReconstructionTrial(
    fixture: anytype,
    case: usize,
    work: anytype,
    id: [32]u8,
    cancelled: bool,
    state: *ReconstructionTrialDrive,
) !bool {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    if (cancelled and work.value.current_occurrence != null) {
        const pending = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            a,
            (try service.namespace.store.recordBytes(
                a,
                "occurrence",
                work.value.current_occurrence.?,
                task,
            )).?,
        )).value;
        var request = try data.invocation.decode(
            data.invocation.Request,
            a,
            try service.namespace.store.object(a, pending.request_object, null),
        );
        defer request.deinit();
        if (work.value.cancellation == null and std.mem.eql(
            u8,
            request.value.binding.semantic_identity,
            contracts.controller.effect_prefix ++ "deliberate",
        )) {
            try std.testing.expectEqual(.ready, std.meta.activeTag(pending.state));
            _ = try service.workspaceControl(
                a,
                try std.fmt.allocPrint(a, "trial-cancel-{d}", .{case}),
                task,
                id,
                work.value.execution_revision,
                work.value.control_revision,
                .{ .cancel = .{ .bytes = "Cancel synthetic trial" } },
            );
            return true;
        }
        if (work.value.cancellation != null) {
            try std.testing.expectEqual(.ready, std.meta.activeTag(pending.state));
            try std.testing.expect(work.value.cancellation_applied);
            try std.testing.expectEqualStrings(
                contracts.controller.effect_prefix ++ "snapshot",
                request.value.binding.semantic_identity,
            );
            state.cleanup_admitted = true;
        }
    }
    return false;
}

fn pumpBoundedReconstructionTrial(
    fixture: anytype,
    case: usize,
    work: anytype,
    id: [32]u8,
    work_ref: contracts.workspace.Ref,
    state: *ReconstructionTrialDrive,
) !bool {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    if (case == 4 and !state.bounded_trial_pump and work.value.current_occurrence != null) {
        const pending = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            a,
            (try service.namespace.store.recordBytes(
                a,
                "occurrence",
                work.value.current_occurrence.?,
                task,
            )).?,
        )).value;
        try std.testing.expectEqual(.ready, std.meta.activeTag(pending.state));
        const expected: contracts.workspace.Expected = .{
            .work = work_ref,
            .execution_revision = work.value.execution_revision,
            .control_revision = work.value.control_revision,
        };
        _ = try service.workspacePump(a, "trial-queue-bounded-pump", task, .{
            .expected = expected,
            .base_quantum = 1,
        });
        for (0..16) |_| {
            const progress = try service.pump(a);
            try std.testing.expect(progress != .work);
            var settled = try service.workspaceWork(a, task, id);
            defer settled.deinit();
            try std.testing.expectEqual(
                work.value.execution_revision,
                settled.value.execution_revision,
            );
            try std.testing.expect(settled.value.outer_operation == null);
            if (settled.value.schedule == .parked) break;
        } else return error.ExplicitTrialReplyDidNotPark;
        var settled = try service.workspaceWork(a, task, id);
        defer settled.deinit();
        const reply = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            a,
            (try service.namespace.store.recordBytes(
                a,
                "occurrence",
                settled.value.current_occurrence.?,
                task,
            )).?,
        )).value;
        try std.testing.expectEqual(.settled_reply, std.meta.activeTag(reply.state));
        try service.validateWorkspace(a, task);
        try consumeBoundedReconstructionTrial(fixture, id, work_ref, settled);
        state.bounded_trial_pump = true;
        return true;
    }
    return false;
}

pub const ReconstructionProcess = struct {
    path: []const u8,
    phase: []const u8,
    verifying: bool,
    task: [16]u8 = @splat(0),
    operation: [32]u8 = @splat(0),
    stop: *const fn ([]const u8, [16]u8, [32]u8) anyerror!void,
};
fn expectControllerReadBound(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    occurrence_id: [32]u8,
) !bool {
    const store = &service.namespace.store;
    const evidence_bytes = (try store.recordBytes(
        a,
        "workspace_reply",
        occurrence_id,
        task,
    )) orelse return false;
    var evidence = try contracts.decodeOwned(native.workspace.ReplyObservation, a, evidence_bytes);
    defer evidence.deinit();
    if (evidence.value.evidence != .read or
        evidence.value.evidence.read != .controller) return false;
    var pending = try contracts.decodeOwned(
        native.testing.occurrence.Occurrence,
        a,
        (try store.recordBytes(a, "occurrence", occurrence_id, task)).?,
    );
    defer pending.deinit();
    try std.testing.expect(pending.value.state == .settled_reply);
    try std.testing.expect(evidence.value.evidence.read.controller.execution_revision > 0);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &facts);
    const forged_bound = try forgedControllerReadReply(store, a, pending.value);
    try store.begin();
    defer store.rollback();
    var forged_evidence = evidence.value;
    forged_evidence.evidence.read.controller.execution_revision = 0;
    const forged_evidence_body = try store.putObject(
        try contracts.encodeOwned(native.workspace.ReplyObservation, a, forged_evidence),
    );
    try store.database.run("UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?", &.{ .{
        .blob = &forged_evidence_body.digest,
    }, .{ .blob = &occurrence_id } });
    var forged_occurrence = pending.value;
    forged_occurrence.state.settled_reply.reply = (try store.putObject(forged_bound)).digest;
    try store.putRecord(
        native.testing.occurrence.Occurrence,
        "occurrence",
        occurrence_id,
        task,
        forged_occurrence,
    );
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &facts),
    );
    store.rollback();
    try service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &facts);
    return true;
}

fn expectControllerValueBound(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    ref: contracts.workspace.Ref,
) !void {
    const store = &service.namespace.store;
    const identity = try native.workspace.custodyId(a, task, try nativeIdentity(ref));
    var saved = try contracts.decodeOwned(
        native.workspace.Value,
        a,
        (try store.recordBytes(a, "workspace_value", identity, task)).?,
    );
    defer saved.deinit();
    const origin = saved.value.derivation.semantic_source.?;
    try std.testing.expect(origin.basis == .controller and origin.selection.subject == .controller);
    try std.testing.expect(origin.basis.controller.execution_revision > 0);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{
        .digest = manifest_digest,
        .bytes = service.assets.manifest.len,
    });
    var facts = try service.prepareWorkspaceValidation(task);
    defer facts.deinit();
    try service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &facts);
    const records = try a.alloc(native.testing.state.ArchiveRecord, index.records.items.len + 1);
    @memcpy(records[1..], index.records.items);
    try store.begin();
    defer store.rollback();
    var forged = saved.value;
    forged.derivation.semantic_source.?.basis.controller.execution_revision -= 1;
    forged.derivation.semantic_source.?.selection.subject.controller.cut.execution_revision -= 1;
    forged.description.provenance = try store.putObject(
        try contracts.encodeOwned(native.workspace.Derivation, a, forged.derivation),
    );
    forged.artifact = try store.putObject(
        try contracts.encodeOwned(native.workspace.ValueArtifact, a, forged.description),
    );
    forged.id = try native.workspace.custodyId(a, task, forged.artifact.digest);
    try store.createRecord(native.workspace.Value, "workspace_value", forged.id, task, forged);
    records[0] = .{
        .kind = .workspace_value,
        .id = forged.id,
        .body = try store.putObject(try contracts.encodeOwned(native.workspace.Value, a, forged)),
    };
    try std.testing.expectError(
        error.InvalidArchive,
        service.validateWorkspaceRecordsPrepared(a, task, records, &facts),
    );
    store.rollback();
    try service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &facts);
}

fn reconstructionModelMove(
    service: anytype,
    a: std.mem.Allocator,
    root: []const u8,
    task: [16]u8,
    work: native.tasks.Work,
    destination_identity: [32]u8,
    service_open: *bool,
    namespace_open: *bool,
) !void {
    try materializeModelMoveSource(service, a, task, work);
    const io = service.io;
    const assets = service.assets;
    const application = service.application;
    const handlers = service.handlers;
    const source_namespace = service.namespace;
    const p = native.placement;
    const source_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(81));
    const destination_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(82));
    var disclosure: u8 = 0;
    const destination_peer = try reconstructionDestinationPeer(
        service,
        a,
        task,
        destination_identity,
        destination_key,
        &disclosure,
    );
    var source_peer = destination_peer;
    source_peer.name = "source";
    source_peer.site = .{
        .key = source_key.public_key.toBytes(),
        .namespace = service.namespace.identity,
    };
    const source_config: p.Configuration = .{ .signing_key = source_key, .peers = &.{
        destination_peer,
    } };
    const destination_config: p.Configuration = .{ .signing_key = destination_key, .peers = &.{
        source_peer,
    } };
    const prior_placement = service.profile.placement;
    defer if (service_open.*) {
        service.profile.placement = prior_placement;
    };
    service.profile.placement = &source_config;
    var profile = service.profile;
    profile.placement = &destination_config;
    try moveReconstructionModel(
        service,
        a,
        root,
        task,
        service_open,
        namespace_open,
        .{
            .io = io,
            .assets = assets,
            .application = application,
            .handlers = handlers,
            .source_namespace = source_namespace,
            .profile = profile,
        },
    );
}

fn reconstructionDestinationPeer(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    destination_identity: [32]u8,
    destination_key: std.crypto.sign.Ed25519.KeyPair,
    disclosure: *u8,
) !native.placement.Peer {
    const p = native.placement;
    return .{
        .name = "destination",
        .site = .{
            .key = destination_key.public_key.toBytes(),
            .namespace = destination_identity,
        },
        .native_build = service.profile.runtime_identity,
        .compatibility = try service.placementCompatibility(a, .{ .task = task }),
        .resource_binding = try service.profile.resourceIdentity(
            a,
            service.application.image_identity,
        ),
        .disclosure_policy = @splat(83),
        .context = disclosure,
        .disclose = struct {
            fn check(
                _: *anyopaque,
                _: p.Subject,
                _: []const native.testing.state.Reference,
            ) !void {}
        }.check,
    };
}

pub const ReconstructionCase = enum {
    round_trip,
    conversion_failure,
    conversion_schema,
    conversion_interrupt,
    instructions,
    cancellation,
    held_cleanup,
    recovery_cleanup,
    residual_read,
    residual_history,
    residual_wait,
    residual_wait_park,
    residual_wait_complete,
    residual_mutation,
    residual_cancel,
    residual_custody,
    residual_outer,
    late_placement,
    model_mobility,
    invalid_offer,
    operator,
    operator_unrearmed,
    operator_unrearmed_cancel,
    operator_failure,
    operator_failure_plain,
    operator_cancel,
};

test "WORK-C03 reconstruction indexes records and returns through current facts" {
    try reconstructionContinuity(null, .round_trip);
}

test "WORK-C07 C08 C09 interleavings preserve predecessor and residual obligations" {
    var failures: usize = 0;
    for ([_]ReconstructionCase{
        .conversion_failure,
        .conversion_schema,
        .conversion_interrupt,
        .instructions,
        .cancellation,
        .held_cleanup,
        .recovery_cleanup,
        .residual_read,
        .residual_history,
        .residual_wait,
        .residual_wait_park,
        .residual_wait_complete,
        .residual_mutation,
        .residual_cancel,
        .residual_custody,
        .residual_outer,
        .late_placement,
        .model_mobility,
        .invalid_offer,
        .operator,
        .operator_unrearmed,
        .operator_unrearmed_cancel,
        .operator_failure,
        .operator_failure_plain,
        .operator_cancel,
    }) |case| reconstructionContinuity(null, case) catch |err| {
        std.debug.print("reconstruction {s}: {s}\n", .{ @tagName(case), @errorName(err) });
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        failures += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn replaceWorkPublicationEvent(
    store: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work_id: [32]u8,
    watermark: u64,
    snapshot: native.testing.state.Reference,
) !void {
    var events = try store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
            "RE e.task=? AND e.seq=?",
        &.{ .{ .blob = &task }, .{ .integer = @intCast(watermark) } },
    );
    defer events.deinit();
    try std.testing.expect(try events.step() == .row);
    var event_value = (try contracts.decodeOwned(
        native.testing.state.Event,
        a,
        try events.bytes(0),
    )).value;
    const publications = try a.dupe(
        native.testing.state.WorkPublication,
        event_value.workspace_publications.items,
    );
    for (publications) |*item| if (std.meta.eql(item.work, work_id)) {
        item.observation = snapshot.digest;
    };
    event_value.workspace_publications.items = publications;
    const event_ref = try store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, a, event_value),
    );
    try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{
        .blob = &event_ref.digest,
    }, .{ .blob = &task }, .{ .integer = @intCast(event_value.seq) } });
}

fn rewriteWorkInputs(
    store: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work_id: [32]u8,
    inputs: []const native.testing.state.Reference,
    extra: usize,
) !void {
    var operations = try store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p" ++
            ".receipt WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer operations.deinit();
    var changed: usize = 0;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try operations.bytes(1),
        )).value;
        if (receipt.workspace_kind != .work or !std.meta.eql(receipt.workspace, work_id)) continue;
        var observation = (try contracts.decodeOwned(
            native.workspace.WorkObservation,
            a,
            try store.object(a, receipt.workspace_observation.?, null),
        )).value;
        observation.work.inputs.items = inputs[0 .. observation.work.inputs.items.len + extra];
        const snapshot = try store.putObject(
            try contracts.encodeOwned(native.workspace.WorkObservation, a, observation),
        );
        receipt.workspace_observation = snapshot;
        const rewritten = try store.putObject(
            try contracts.encodeOwned(native.testing.state.Receipt, a, receipt),
        );
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{
            .blob = &rewritten.digest,
        }, .{ .text = try operations.bytes(0) } });
        try replaceWorkPublicationEvent(
            store,
            a,
            task,
            work_id,
            observation.work.event_watermark,
            snapshot,
        );
        changed += 1;
    }
    try std.testing.expect(changed != 0);
}

fn rewriteCancellationCheckpoint(
    store: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    checkpoint: native.testing.state.Reference,
) !void {
    var operations = try store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p" ++
            ".receipt WHERE p.task=?",
        &.{.{ .blob = &child.task }},
    );
    defer operations.deinit();
    var changed: usize = 0;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try operations.bytes(1),
        )).value;
        if (receipt.workspace_kind != .work or !std.meta.eql(receipt.workspace, child.id)) continue;
        var observation = (try contracts.decodeOwned(
            native.workspace.WorkObservation,
            a,
            try store.object(a, receipt.workspace_observation.?, null),
        )).value;
        if (observation.work.execution_revision != child.execution_revision) continue;
        observation.work.checkpoint = checkpoint;
        const snapshot = try store.putObject(
            try contracts.encodeOwned(native.workspace.WorkObservation, a, observation),
        );
        receipt.workspace_observation = snapshot;
        const rewritten = try store.putObject(
            try contracts.encodeOwned(native.testing.state.Receipt, a, receipt),
        );
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{
            .blob = &rewritten.digest,
        }, .{ .text = try operations.bytes(0) } });
        try replaceWorkPublicationEvent(
            store,
            a,
            child.task,
            child.id,
            observation.work.event_watermark,
            snapshot,
        );
        changed += 1;
    }
    try std.testing.expect(changed != 0);
}

fn replaceObservationReceipts(
    store: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    old: [32]u8,
    rewritten: native.testing.state.Reference,
) !void {
    var operations = try store.database.prepare(
        "SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p" ++
            ".receipt WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer operations.deinit();
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(
            native.testing.state.Receipt,
            a,
            try operations.bytes(1),
        )).value;
        if (receipt.workspace_observation == null or !std.meta.eql(
            receipt.workspace_observation.?.digest,
            old,
        )) continue;
        receipt.workspace_observation = rewritten;
        const ref = try store.putObject(
            try contracts.encodeOwned(native.testing.state.Receipt, a, receipt),
        );
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{
            .blob = &ref.digest,
        }, .{ .text = try operations.bytes(0) } });
    }
}

fn rewriteInputProvenanceEvents(
    store: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work_id: [32]u8,
    replacement: native.testing.state.Reference,
) !void {
    var changed: usize = 0;
    var events = try store.database.prepare(
        "SELECT e.seq,o.body FROM events e JOIN objects o ON o.digest=e.bo" ++
            "dy WHERE e.task=? ORDER BY e.seq",
        &.{.{ .blob = &task }},
    );
    defer events.deinit();
    while (try events.step() == .row) {
        var event_value = (try contracts.decodeOwned(
            native.testing.state.Event,
            a,
            try events.bytes(1),
        )).value;
        const publications = try a.dupe(
            native.testing.state.WorkPublication,
            event_value.workspace_publications.items,
        );
        var touched = false;
        for (publications) |*item| if (std.meta.eql(item.work, work_id)) {
            const old = item.observation;
            var snapshot = (try contracts.decodeOwned(
                native.workspace.WorkObservation,
                a,
                try store.acquiredObject(a, old, null),
            )).value;
            snapshot.work.input_value = replacement;
            const rewritten = try store.putObject(
                try contracts.encodeOwned(native.workspace.WorkObservation, a, snapshot),
            );
            item.observation = rewritten.digest;
            try replaceObservationReceipts(store, a, task, old, rewritten);
            changed += 1;
            touched = true;
        };
        if (touched) {
            event_value.workspace_publications.items = publications;
            const ref = try store.putObject(
                try contracts.encodeOwned(native.testing.state.Event, a, event_value),
            );
            try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{
                .blob = &ref.digest,
            }, .{ .blob = &task }, .{ .integer = try events.integer(0) } });
        }
    }
    try std.testing.expect(changed != 0);
}

fn judgmentInputBytes(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work: native.workspace.Work,
) ![]const u8 {
    const store = &service.namespace.store;
    const original = try workspaceRef(a, .value, work.input_value.?.digest);
    const materialized = try service.workspaceCommand(
        a,
        "input-provenance-substitute",
        task,
        .{ .context = .{ .materialize = .{
            .input = .{ .value = .{ .reference = original } },
            .sources = .{ .items = &.{original} },
        } } },
    );
    const observation = (try native.json.parse(a, materialized.observation_json.bytes, .{})).value;
    const substitute = try native.values.fromJson(
        contracts.workspace.Ref,
        a,
        observation.object.get("value").?,
    );
    try std.testing.expectEqualStrings(
        "judgment",
        observation.object.get("derivation").?.object.get("kind").?.string,
    );
    const artifact_bytes = try store.acquiredObject(a, try nativeIdentity(substitute), null);
    const artifact = (try contracts.decodeOwned(
        native.workspace.ValueArtifact,
        a,
        artifact_bytes,
    )).value;
    try std.testing.expectEqualDeep(work.input, artifact.value);
    // An explicitly selected judgment remains a valid input with its ancestry.
    const explicit = try service.workspaceCommand(
        a,
        "input-provenance-explicit",
        task,
        .{ .work = .{ .start = .{
            .program = try workspaceRef(a, .program, work.program),
            .input = .{ .reference = substitute },
            .policy = .{},
        } } },
    );
    try std.testing.expectEqual(.observed, explicit.disposition);
    return artifact_bytes;
}

fn rewriteInteractionReceipt(
    store: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    original: native.testing.state.Receipt,
    operation_id: []const u8,
) !void {
    var receipt = original;
    var events = try store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
            "RE e.task=? AND e.revision=?",
        &.{ .{ .blob = &task }, .{ .integer = @intCast(receipt.revision) } },
    );
    defer events.deinit();
    try std.testing.expect(try events.step() == .row);
    var event_value = (try contracts.decodeOwned(
        native.testing.state.Event,
        a,
        try events.bytes(0),
    )).value;
    var declared = (try contracts.decodeOwned(
        native.workspace.PublicationCommand,
        a,
        try store.object(a, event_value.workspace_command.?, null),
    )).value;
    try std.testing.expectEqualStrings(
        "\"10\"",
        declared.interact.command.resume_value.inline_json.json_text.bytes,
    );
    declared.interact.command.resume_value.inline_json.json_text.bytes = "\"20\"";
    event_value.workspace_command = try store.putObject(
        try contracts.encodeOwned(native.workspace.PublicationCommand, a, declared),
    );
    const event_ref = try store.putObject(
        try contracts.encodeOwned(native.testing.state.Event, a, event_value),
    );
    try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{
        .blob = &event_ref.digest,
    }, .{ .blob = &task }, .{ .integer = @intCast(event_value.seq) } });
    const request = try contracts.encodeOwned(native.workspace.InteractionRequest, a, .{
        .task = task,
        .interaction = declared.interact,
    });
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(request);
    hash.final(&receipt.request_digest);
    const receipt_ref = try store.putObject(
        try contracts.encodeOwned(native.testing.state.Receipt, a, receipt),
    );
    try store.database.run("UPDATE operations SET receipt=?,request=? WHERE id=?", &.{ .{
        .blob = &receipt_ref.digest,
    }, .{ .blob = &receipt.request_digest }, .{ .text = operation_id } });
}

fn controllerConstructionVariant(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    service: anytype,
    namespace: *native.Namespace,
    handlers: native.Registry,
    contract: contracts.controller.Contract,
    number_bytes: []const u8,
    unit_bytes: []const u8,
    task: [16]u8,
    variant: usize,
) !void {
    const indexed = variant == 1;
    var b = source.Builder.init(a);
    defer b.deinit();
    const sources = @import("workspace_sources.zig");
    var module = switch (variant) {
        2, 3 => try sources.controllerWithHandler(&b, variant == 3),
        4 => try sources.controllerWithUnusedImport(&b),
        else => try sources.controller(&b, indexed),
    };
    if (variant == 5) module = try rawController(&b, module);
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    const command = controllerConstructionCommand(text);
    const operation_id = controller_construction_operations[variant];
    const reply_value = try service.workspaceCommand(scratch, operation_id, task, command);
    if (reply_value.disposition != .observed) std.debug.print(
        "controller construction: {s}\n",
        .{reply_value.observation_json.bytes},
    );
    try std.testing.expectEqual(.observed, reply_value.disposition);
    const program_id = try nativeIdentity(reply_value.program.?);
    var program = try service.workspaceProgram(a, task, program_id);
    defer program.deinit();
    const image = try namespace.store.object(a, program.value.description.image, null);
    defer a.free(image);
    const built = .{ .image = image, .controller = program.value.description.controller };
    try expectControllerDescriptor(
        service,
        scratch,
        operation_id,
        task,
        command,
        reply_value,
        built,
    );
    try expectControllerImports(a, built, variant);
    if (variant == 4) try rejectUnusedControllerImports(
        a,
        &b,
        module,
        built,
        text,
        contract,
        number_bytes,
    );
    try expectControllerInvocation(
        a,
        scratch,
        service,
        handlers,
        task,
        program_id,
        built,
        indexed,
        unit_bytes,
    );
    try rejectControllerSourceChanges(a, &b, module, text, contract, unit_bytes, variant);
}

fn controllerConstructionHandlers(a: std.mem.Allocator) !native.Registry {
    const Echo = struct {
        fn invoke(_: native.Context, value: u64) !u64 {
            return value;
        }
        fn snapshot(_: native.Context, _: u64) !void {}
    };
    return native.Registry.init(a, &.{
        native.registry.controllerImport(
            .deliberate,
            native.leaf(
                u64,
                u64,
                .{ .identity = "fixture.model", .resource_role = "inference", .inference = true },
                Echo.invoke,
            ),
        ),
        native.registry.controllerImport(
            .snapshot,
            native.leaf(
                u64,
                void,
                .{ .identity = "fixture.snapshot", .resource_role = "snapshot" },
                Echo.snapshot,
            ),
        ),
    });
}

fn controllerConstructionNamespace(
    a: std.mem.Allocator,
    handlers: native.Registry,
    application: *native.discovery.Application,
    assets: native.discovery.Assets,
    profile: native.tasks.Profile,
    contract: contracts.controller.Contract,
    number_bytes: []const u8,
    unit_bytes: []const u8,
) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, std.testing.io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(OwnerTypes).init(
        a,
        std.testing.io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const task = (try service.submit(scratch, "controller-parent", .{ 25, 5 })).receipt.task;
    for (0..6) |variant| {
        try controllerConstructionVariant(
            a,
            scratch,
            &service,
            &namespace,
            handlers,
            contract,
            number_bytes,
            unit_bytes,
            task,
            variant,
        );
    }
}

fn controllerConstructionOwner(
    a: std.mem.Allocator,
    contract: contracts.controller.Contract,
    number_bytes: []const u8,
    unit_bytes: []const u8,
) !void {
    var handlers = try controllerConstructionHandlers(a);
    defer handlers.deinit();
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{
        .arena = .init(a),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "controller-unit",
        .image_identity = admitted.identity(),
    };
    defer application.deinit();
    const assets: native.discovery.Assets = .{
        .image = root.image,
        .application = "controller-unit",
        .manifest = "{}",
    };
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "controller-test", .authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
    } };
    try controllerConstructionNamespace(
        a,
        handlers,
        &application,
        assets,
        profile,
        contract,
        number_bytes,
        unit_bytes,
    );
}

fn expectControllerImports(a: std.mem.Allocator, built: anytype, variant: usize) !void {
    const compiled = try data.program_image.Admitted.decode(a, built.image);
    defer compiled.deinit();
    try std.testing.expectEqual(
        @as(usize, if (variant == 4) 2 else 1),
        built.controller.?.imports.items.len,
    );
    for (built.controller.?.imports.items) |binding| {
        const effect = for (compiled.program().effects) |effect| {
            if (std.mem.eql(u8, effect.identity, binding.identity.bytes)) break effect;
        } else return error.MissingControllerImport;
        const payload = try data.schema.encodeOwned(
            a,
            compiled.program().schemas,
            effect.payload,
        );
        defer a.free(payload);
        const result = try data.schema.encodeOwned(
            a,
            compiled.program().schemas,
            effect.result,
        );
        defer a.free(result);
        try std.testing.expectEqualStrings(binding.payload.bytes, payload);
        try std.testing.expectEqualStrings(binding.result.bytes, result);
    }
}

fn rejectUnusedControllerImports(
    a: std.mem.Allocator,
    b: *source.Builder,
    module: source.Module,
    built: anytype,
    text: []const u8,
    contract: contracts.controller.Contract,
    number_bytes: []const u8,
) !void {
    const construction = native.program_construction;
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectEqual(.snapshot, built.controller.?.imports.items[1].import);
    var unavailable = contract;
    unavailable.imports.items = contract.imports.items[0..1];
    try std.testing.expectError(
        error.UnavailableControllerImport,
        construction.buildController(a, text, unavailable, null, &diagnostic),
    );
    var signatures = [_]@TypeOf(contract.imports.items[0]){
        contract.imports.items[0],
        contract.imports.items[1],
    };
    signatures[1].result.bytes = number_bytes;
    var wrong_signature = contract;
    wrong_signature.imports.items = &signatures;
    try std.testing.expectError(
        error.InvalidControllerInterface,
        construction.buildController(a, text, wrong_signature, null, &diagnostic),
    );
    var redundant = contract;
    redundant.imports.items = &.{
        contract.imports.items[0],
        contract.imports.items[1],
        contract.imports.items[1],
    };
    try std.testing.expectError(
        error.DuplicateControllerImport,
        construction.buildController(a, text, redundant, null, &diagnostic),
    );
    _ = try b.effect(b.effects.items[1]);
    const duplicate = try native.source_records.encode(
        a,
        b.module(module.entry, module.failure),
    );
    defer a.free(duplicate);
    try std.testing.expectError(
        error.DuplicateControllerImport,
        construction.buildController(a, duplicate, contract, null, &diagnostic),
    );
    b.effects.items.len -= 1;
}

fn expectControllerInvocation(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    service: anytype,
    handlers: native.Registry,
    task: [16]u8,
    program_id: [32]u8,
    built: anytype,
    indexed: bool,
    unit_bytes: []const u8,
) !void {
    const construction = native.program_construction;
    const controller = construction.controller;
    const Input = struct { anchor: controller.TaskAnchor, private: u64 };
    const IndexedInput = struct { anchor: controller.TaskAnchor, private: struct {
        first: u64,
        second: u64,
    } };
    const input = if (indexed)
        try contracts.encodeOwned(IndexedInput, a, .{ .anchor = .{
            .task = @splat(7),
        }, .private = .{ .first = 41, .second = 99 } })
    else
        try contracts.encodeOwned(Input, a, .{
            .anchor = .{ .task = @splat(7) },
            .private = 41,
        });
    defer a.free(input);
    try std.testing.expectError(
        error.ControllerTrialRequired,
        service.workspaceStart(scratch, "not-a-trial", task, program_id, input, .{}),
    );
    var boot = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{
        .initial_args = input,
    } });
    defer boot.deinit();
    try std.testing.expect(boot.record == .requested);
    var boot_request = try data.invocation.decode(
        data.invocation.Request,
        a,
        boot.record.requested.request,
    );
    defer boot_request.deinit();
    try std.testing.expectEqualStrings(
        controller.boot_identity,
        boot_request.value.binding.semantic_identity,
    );
    try std.testing.expectEqualStrings(input, boot_request.value.binding.payload);
    const ready = try data.invocation.encodeOwned(
        data.invocation.Result,
        a,
        .{ .request_identity = boot_request.value.request_identity, .value = &.{} },
    );
    defer a.free(ready);
    try expectControllerOffer(
        a,
        built.image,
        boot.record.requested.state.?,
        ready,
        handlers,
        unit_bytes,
    );
}

fn rejectControllerSourceChanges(
    a: std.mem.Allocator,
    b: *source.Builder,
    module: source.Module,
    text: []const u8,
    contract: contracts.controller.Contract,
    unit_bytes: []const u8,
    variant: usize,
) !void {
    const construction = native.program_construction;
    var diagnostic: native.program_construction.Diagnostic = .{};
    if (variant == 5) {
        const raw = for (b.values.items) |*value| {
            if (source.constructor_bindings.raw(value.*) != null) break value;
        } else return error.MissingRawConstructor;
        raw.expression.primitive.immediate = 1;
        const wrapper_only = try native.source_records.encode(a, module);
        defer a.free(wrapper_only);
        try std.testing.expectError(
            error.InvalidReference,
            construction.buildController(a, wrapper_only, contract, null, &diagnostic),
        );
        raw.expression.primitive.immediate = 0;
    }
    b.effects.items[0].identity = "protean.controller/1/deliberate";
    const forged = try native.source_records.encode(a, b.module(module.entry, module.failure));
    defer a.free(forged);
    try std.testing.expectError(
        error.ForbiddenEffect,
        construction.buildController(a, forged, contract, null, &diagnostic),
    );
    b.effects.items[0].identity = "controller/1/unknown";
    const unknown = try native.source_records.encode(a, b.module(module.entry, module.failure));
    defer a.free(unknown);
    try std.testing.expectError(
        error.UnknownControllerImport,
        construction.buildController(a, unknown, contract, null, &diagnostic),
    );
    b.effects.items[0].identity = "controller/1/deliberate";
    var wrong = contract;
    wrong.result = .{ .bytes = unit_bytes };
    try std.testing.expectError(
        error.InvalidControllerInterface,
        construction.buildController(a, text, wrong, null, &diagnostic),
    );
    b.effects.items[0].external = true;
    const widened = try native.source_records.encode(a, b.module(module.entry, module.failure));
    defer a.free(widened);
    try std.testing.expectError(
        error.UnboundEffect,
        construction.buildController(a, widened, contract, null, &diagnostic),
    );
    b.effects.items[0].external = false;
    const capability = try b.schema(.{ .internal = .{ .capability = 0 } });
    const proposal_schema = b.schemas.items[@intCast(b.effects.items[0].payload)].product[0];
    b.effects.items[0].payload = try b.schema(.{ .product = &.{
        proposal_schema,
        capability,
    } });
    const nonexportable = try native.source_records.encode(
        a,
        b.module(module.entry, module.failure),
    );
    defer a.free(nonexportable);
    try std.testing.expectError(
        error.InvalidSchema,
        construction.buildController(a, nonexportable, contract, null, &diagnostic),
    );
}

fn expectControllerOffer(
    a: std.mem.Allocator,
    image: []const u8,
    state: []const u8,
    ready: []const u8,
    handlers: native.Registry,
    unit_bytes: []const u8,
) !void {
    var offered = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = state,
    }, .control = .{ .reply = ready } });
    defer offered.deinit();
    try std.testing.expect(offered.record == .requested);
    var offer_request = try data.invocation.decode(
        data.invocation.Request,
        a,
        offered.record.requested.request,
    );
    defer offer_request.deinit();
    try std.testing.expectEqualStrings(
        contracts.controller.offer_identity,
        offer_request.value.binding.semantic_identity,
    );
    const offer_reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = offer_request.value.request_identity,
        .value = offer_request.value.binding.payload,
    });
    defer a.free(offer_reply);
    try expectControllerInteraction(
        a,
        image,
        offered.record.requested.state.?,
        offer_reply,
        handlers,
        unit_bytes,
    );
}

fn expectControllerInteraction(
    a: std.mem.Allocator,
    image: []const u8,
    state: []const u8,
    offer_reply: []const u8,
    handlers: native.Registry,
    unit_bytes: []const u8,
) !void {
    const construction = native.program_construction;
    const controller = construction.controller;
    var interaction = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = state,
    }, .control = .{ .reply = offer_reply } });
    defer interaction.deinit();
    try std.testing.expect(interaction.record == .requested);
    var request = try data.invocation.decode(
        data.invocation.Request,
        a,
        interaction.record.requested.request,
    );
    defer request.deinit();
    try std.testing.expectEqualStrings(
        controller.effect_prefix ++ "deliberate",
        request.value.binding.semantic_identity,
    );
    try expectControllerAdmission(a, handlers, request.value, unit_bytes);
    const response = try contracts.encodeOwned(u64, a, 42);
    defer a.free(response);
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request.value.request_identity,
        .value = response,
    });
    defer a.free(reply);
    try expectControllerHandoff(
        a,
        image,
        interaction.record.requested.state.?,
        reply,
        request.value.binding.payload,
        response,
    );
}

fn expectControllerAdmission(
    a: std.mem.Allocator,
    handlers: native.Registry,
    request: data.invocation.Request,
    unit_bytes: []const u8,
) !void {
    const image_identity = request.binding.program_identity;
    const resource_identity: [32]u8 = @splat(9);
    const authority: native.registry.Authority = .{
        .principal = "test",
        .tenant = "test",
        .inference = true,
        .grants = &.{.{
            .identity = "fixture.model",
            .resource_role = "inference",
            .resource_identity = resource_identity,
        }},
    };
    const entry = try handlers.admit(request, authority, image_identity, resource_identity);
    const proposal = try entry.payload(a, request.binding.payload);
    var decoded_proposal = try contracts.decodeOwned(u64, a, proposal);
    defer decoded_proposal.deinit();
    try std.testing.expectEqual(@as(u64, 41), decoded_proposal.value);
    try std.testing.expect(request.binding.payload.len > proposal.len);
    var denied = authority;
    denied.inference = false;
    try std.testing.expectError(
        error.Denied,
        handlers.admit(request, denied, image_identity, resource_identity),
    );
    try std.testing.expectError(
        error.Denied,
        handlers.admit(request, authority, @splat(0), resource_identity),
    );
    var mismatched = request;
    mismatched.binding.resume_schema = unit_bytes;
    try std.testing.expectError(
        error.CapabilitySchemaMismatch,
        handlers.resolve(mismatched, image_identity),
    );
}

fn expectControllerHandoff(
    a: std.mem.Allocator,
    image: []const u8,
    state: []const u8,
    reply: []const u8,
    payload: []const u8,
    response: []const u8,
) !void {
    var handoff = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = state,
    }, .control = .{ .reply = reply } });
    defer handoff.deinit();
    try std.testing.expect(handoff.record == .requested);
    var handoff_request = try data.invocation.decode(
        data.invocation.Request,
        a,
        handoff.record.requested.request,
    );
    defer handoff_request.deinit();
    try std.testing.expectEqualStrings(
        contracts.controller.handoff_identity,
        handoff_request.value.binding.semantic_identity,
    );
    const expected_handoff = try std.mem.concat(a, u8, &.{ payload, response });
    defer a.free(expected_handoff);
    try std.testing.expectEqualStrings(expected_handoff, handoff_request.value.binding.payload);
    const response_with_control = try contracts.encodeOwned(contracts.controller.Reply(
        u64,
    ), a, .{ .response = 42 });
    defer a.free(response_with_control);
    const handoff_reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = handoff_request.value.request_identity,
        .value = response_with_control,
    });
    defer a.free(handoff_reply);
    var completed = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = handoff.record.requested.state.?,
    }, .control = .{ .reply = handoff_reply } });
    defer completed.deinit();
    try std.testing.expect(completed.record == .completed);
    try std.testing.expectEqualStrings(response, completed.record.completed);
}
fn preparedModelInterpretation(a: std.mem.Allocator) ![]u8 {
    return contracts.encodeOwned(native.workspace_instrument.Prepared, a, .{
        .schema = .{ .bytes = try native.values.schemaBytes(u64, a) },
        .body = .{ .bytes = "" },
        .model = .{
            .profile_id = .{ .bytes = "fixture" },
            .profile_digest = @splat(7),
            .settings = .{
                .endpoint = .{ .bytes = "https://localhost/v1/responses" },
                .audience = .{ .bytes = "fixture" },
                .model = .{ .bytes = "fixture" },
                .effort = .{ .bytes = "medium" },
                .max_output_tokens = null,
                .request_bytes = null,
                .response_bytes = null,
                .timeout_ms = null,
            },
            .reasoning_mode = .{ .bytes = "standard" },
            .reasoning_context = .{ .bytes = "auto" },
        },
    });
}

fn expectModelAllocationCase(
    a: std.mem.Allocator,
    original_context: native.registry.ProjectionContext,
    prepared: []const u8,
    arguments: []const u8,
    case: usize,
) !void {
    var context = original_context;
    const adapter = native.workspace_instrument.declaration(.model).capture.?;
    const body = try std.json.Stringify.valueAlloc(a, .{ .status = "completed", .@"error" = @as(
        ?u8,
        null,
    ), .output = .{.{
        .type = "function_call",
        .status = "completed",
        .call_id = "fixture",
        .name = "answer",
        .arguments = arguments,
    }} }, .{});
    const raw = try contracts.encodeOwned(
        native.responses.Raw,
        a,
        .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{
            .bytes = body,
        } },
    );
    var counted: OneShotAllocator = .{ .backing = a };
    context.allocator = counted.allocator();
    const baseline = try adapter.interpret(context, "", prepared, raw);
    var decoded = try contracts.decodeOwned(
        native.workspace_instrument.Output,
        a,
        baseline.reply,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(case < 2, decoded.value == .answer);
    if (decoded.value == .answer) try std.testing.expectEqualStrings(
        try contracts.encodeOwned(u64, a, 42),
        decoded.value.answer.bytes,
    );
    for (0..counted.calls) |ordinal| {
        var attempt = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer attempt.deinit();
        var fault: OneShotAllocator = .{ .backing = attempt.allocator(), .fail_at = ordinal };
        context.allocator = fault.allocator();
        const actual = adapter.interpret(context, "", prepared, raw) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try std.testing.expectEqualStrings(baseline.reply, actual.reply);
    }
}

fn workspaceCleanupResources(
    a: std.mem.Allocator,
    application: *native.discovery.Application,
    assets: native.discovery.Assets,
    handlers: native.Registry,
) !void {
    const text = "ordinary rows agree\nrare exception: missing invoice\n";
    var file_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &file_digest, .{});
    const snapshot = try contracts.encodeOwned(
        contracts.RepositorySnapshot,
        a,
        .{ .version = 2, .excluded_entries = 3, .files = .{ .items = &.{.{ .path = .{
            .bytes = "evidence.txt",
        }, .sha256 = file_digest, .contents = .{ .bytes = text } }} } },
    );
    defer a.free(snapshot);
    var algorithm = source.Builder.init(a);
    defer algorithm.deinit();
    var gcd_program = try horos.source.lower(
        a,
        try @import("workspace_sources.zig").gcd(&algorithm),
    );
    defer gcd_program.deinit();
    const component: data.component.Object = .{
        .program = gcd_program.program,
        .exports = &.{.{ .name = "apply", .reference = .{
            .kind = .function,
            .id = gcd_program.program.roots.entry,
        } }},
        .borrows = &.{.{ .function = gcd_program.program.roots.entry }},
    };
    const component_bytes = try a.alloc(u8, try data.component.encodedLength(component));
    defer a.free(component_bytes);
    _ = try data.component.encode(a, component, component_bytes);
    const catalog = try contracts.encodeOwned(
        contracts.tool_construction.Catalog,
        a,
        .{ .items = &.{.{ .id = .{ .bytes = "gcd" }, .object = .{ .bytes = component_bytes } }} },
    );
    defer a.free(catalog);
    try workspaceCleanupOwner(a, application, assets, handlers, snapshot, catalog);
}

fn workspaceCleanupOwner(
    a: std.mem.Allocator,
    application: *native.discovery.Application,
    assets: native.discovery.Assets,
    handlers: native.Registry,
    snapshot: []const u8,
    catalog: []const u8,
) !void {
    const io = std.testing.io;
    var grants = [_]native.registry.Grant{.{
        .identity = "workspace-context",
        .resource_role = "workspace",
        .resource_identity = undefined,
    }};
    const profile: native.tasks.Profile = .{
        .id = "offline",
        .runtime_identity = @splat(42),
        .bytes = "context-test",
        .resources = &.{ snapshot, catalog },
        .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" },
    };
    grants[0].resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer support.expectCleanup(namespace.close());
    var service = try native.tasks.Service(ContextTypes).init(
        a,
        io,
        &namespace,
        assets,
        application,
        handlers,
        profile,
    );
    defer support.expectCleanup(service.close(a));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(
        scratch,
        "parent",
        .{ .program = .{ .describe = .{ .section = .values, .page = .{} } } },
    );
    _ = try service.pump(scratch);
    var paused = try service.task(scratch, parent.receipt.task);
    defer paused.deinit();
    try std.testing.expectEqual(.yielded, paused.value.outcome_kind);
    _ = try service.requestCancel(scratch, "cancel", parent.receipt.task, "cancel body");
    for (0..8) |_| _ = try service.pump(scratch);
    var done = try service.task(scratch, parent.receipt.task);
    defer done.deinit();
    try std.testing.expectEqual(.cancelled, done.value.outcome_kind);
}

fn forgedControllerReadReply(
    store: anytype,
    a: std.mem.Allocator,
    pending: native.testing.occurrence.Occurrence,
) ![]u8 {
    const bound = (try data.invocation.decode(
        data.invocation.Result,
        a,
        try store.acquiredObject(a, pending.state.settled_reply.reply, null),
    )).value;
    const original_reply = (try contracts.decodeOwned(
        contracts.workspace.Reply,
        a,
        bound.value,
    )).value;
    var page = (try native.json.parse(a, original_reply.observation_json.bytes, .{})).value;
    try std.testing.expect(page.object.get("complete").?.bool);
    var description = (try native.json.parse(a, page.object.get("text").?.string, .{})).value;
    try native.json.put(
        a,
        &description,
        "execution_revision",
        try native.json.number(a, @as(u64, 0)),
    );
    const text = try native.json.canonical(a, description);
    try native.json.put(a, &page, "text", native.json.string(text));
    try native.json.put(a, &page, "next_offset", try native.json.number(a, text.len));
    try native.json.put(a, &page, "total_bytes", try native.json.number(a, text.len));
    var forged_reply = original_reply;
    forged_reply.observation_json.bytes = try native.json.canonical(a, page);
    const payload = try contracts.encodeOwned(contracts.workspace.Reply, a, forged_reply);
    return data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request,
        .value = payload,
    });
}

fn controllerConstructionCommand(text: []const u8) contracts.workspace.Command {
    return .{ .program = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = text } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{} },
        .role = .controller,
    } } };
}

const controller_construction_operations = [_][]const u8{
    "controller-A",
    "controller-B",
    "controller-deep",
    "controller-shallow",
    "controller-unused-import",
    "controller-raw-captures",
};
fn alternativeDriverVariant(a: std.mem.Allocator, variant: usize) !void {
    const multi = variant != 0;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var module = if (variant == 2 or variant == 3) try @import(
        "workspace_sources.zig",
    ).mutableAlternatives(
        &builder,
    ) else try alternatives(&builder, multi);
    if (variant >= 3) {
        try sparsifyAlternativeRegions(&builder);
        module = builder.module(module.entry, module.failure);
    }
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    if (!multi) {
        // An operation declared single-use cannot become multi-shot by
        // requesting an alternative port. Conversion requires a multi
        // operation even when its handler initially owns a linear token.
        try std.testing.expectError(
            error.InvalidExposure,
            native.program_construction.buildExposed(
                a,
                text,
                &.{.{ .effect = 1, .class = .alternative }},
                null,
                &diagnostic,
            ),
        );
        return;
    }
    var built = native.program_construction.buildExposed(
        a,
        text,
        &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } },
        null,
        &diagnostic,
    ) catch |err| {
        std.debug.print(
            "driver build {s}: phase={s}, function={?d}, term={?d}, value={?d}\n",
            .{
                @errorName(err),
                @tagName(diagnostic.phase),
                diagnostic.source.function,
                diagnostic.source.term,
                diagnostic.source.value,
            },
        );
        return err;
    };
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 2), built.ports.len);
    try runAlternativeImage(a, built.image);
}

fn sparsifyAlternativeRegions(builder: *source.Builder) !void {
    const sparse = try builder.allocator().dupe(Id, &.{std.math.maxInt(Id) - 1});
    for (builder.schemas.items) |*schema| if (schema.* == .internal) switch (schema.internal) {
        .region => |*id| id.* = sparse[0],
        .cell => |*cell| cell.region = sparse[0],
        .computation => |*computation| if (computation.regions.len != 0) {
            computation.regions = sparse;
        },
        else => {},
    };
    for (builder.functions.items) |*function| if (function.regions.len != 0) {
        function.regions = sparse;
    };
    for (builder.terms.items) |*term| if (term.* == .with_region) {
        term.with_region.region = sparse[0];
    };
    builder.region_count = std.math.maxInt(Id);
}

fn runAlternativeImage(a: std.mem.Allocator, image: []const u8) !void {
    const input = try contracts.encodeOwned(u64, a, 100);
    defer a.free(input);
    var outcome = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .initial_args = input,
    } });
    defer outcome.deinit();
    for (0..4) |i| try continueAlternative(a, image, &outcome, i);
    try std.testing.expectEqual(.completed, std.meta.activeTag(outcome.record));
    var result = try contracts.decodeOwned(u64, a, outcome.record.completed);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 121), result.value);
}

fn continueAlternative(
    a: std.mem.Allocator,
    image: []const u8,
    outcome: anytype,
    i: usize,
) !void {
    const Command = union(enum) { instantiate: u64, finish: void };
    try std.testing.expectEqual(.requested, std.meta.activeTag(outcome.record));
    var request = try data.invocation.decode(
        data.invocation.Request,
        a,
        outcome.record.requested.request,
    );
    defer request.deinit();
    try expectAlternativePayload(a, request.value, i);
    const value = if (i == 0) try contracts.encodeOwned(
        void,
        a,
        {},
    ) else try contracts.encodeOwned(
        Command,
        a,
        if (i == 3) .{ .finish = {} } else .{ .instantiate = if (i == 1) 10 else 20 },
    );
    defer a.free(value);
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request.value.request_identity,
        .value = value,
    });
    defer a.free(reply);
    const next = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = outcome.record.requested.state.?,
    }, .control = .{ .reply = reply } });
    outcome.deinit();
    outcome.* = next;
}

fn expectAlternativePayload(
    a: std.mem.Allocator,
    request: data.invocation.Request,
    i: usize,
) !void {
    if (i == 0) {
        try std.testing.expectEqualStrings(
            "protean.workspace.control/1/0",
            request.binding.semantic_identity,
        );
        var prefix = try contracts.decodeOwned(u64, a, request.binding.payload);
        defer prefix.deinit();
        try std.testing.expectEqual(@as(u64, 101), prefix.value);
    } else {
        try std.testing.expectEqualStrings(
            "protean.workspace.control/1/1",
            request.binding.semantic_identity,
        );
        var observed = try contracts.decodeOwned(
            struct { void, ?u64 },
            a,
            request.binding.payload,
        );
        defer observed.deinit();
        try std.testing.expectEqual(
            @as(?u64, if (i == 1) null else if (i == 2) 111 else 121),
            observed.value[1],
        );
    }
}
const HandlerExposureShape = struct {
    unit: Id,
    u: Id,
    ask: Id,
    second: Id,
    local: Id,
    cap: Id,
    mode: data.program.Mode,
    token: Id,
    variant: usize,
    path_variant: usize,
};
const HandlerExposureCallee = struct { function: Id, schema: Id };
const HandlerExposureHandler = struct { returns: Id, clause: Id, id: Id };
const HandlerExposureBody = struct { function: Id, schema: Id };
const HandlerExposureModule = struct { module: source.Module, resource: Id };

fn handlerExposureShape(b: *source.Builder, variant: usize) !HandlerExposureShape {
    const path_variant = if (variant == 5) 0 else variant;
    const unit = try b.scalar(void);
    const u = try b.scalar(u64);
    const ask = try b.effect(.{
        .identity = "example/handler-query",
        .payload = u,
        .result = u,
        .external = false,
    });
    const second = if (variant == 5) try b.effect(.{
        .identity = "example/second-query",
        .payload = u,
        .result = u,
        .external = false,
    }) else ask;
    const asks: []const Id = if (variant == 5) &.{ ask, second } else &.{ask};
    const local = try b.effect(.{
        .identity = "example/local",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = local } });
    const mode: data.program.Mode = if (path_variant == 2) .shallow else .deep;
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = local,
        .input = unit,
        .answer = if (mode == .deep) u else unit,
        .effects = if (variant == 5) &.{ ask, second, local } else &.{ ask, local },
        .capture_bound = &.{ unit, u, cap },
        .handled = &.{local},
        .escaping = if (mode == .shallow) asks else &.{},
        .mode = mode,
        .use = .linear,
    } } });
    return .{
        .unit = unit,
        .u = u,
        .ask = ask,
        .second = second,
        .local = local,
        .cap = cap,
        .mode = mode,
        .token = token,
        .variant = variant,
        .path_variant = path_variant,
    };
}

fn handlerExposureCallee(b: *source.Builder, shape: HandlerExposureShape) !HandlerExposureCallee {
    const ask_storage = [_]Id{ shape.ask, shape.second };
    const asks = ask_storage[0..@as(usize, if (shape.variant == 5) 2 else 1)];
    const helper = try b.declare(&.{shape.u}, shape.u, asks, &.{});
    try b.define(
        helper,
        try b.term(.{ .perform = .{
            .effect = shape.ask,
            .payload = try b.reference(b.parameter(helper, 0)),
        } }),
    );
    if (shape.variant == 5) {
        const response = try b.variable(shape.u);
        b.functions.items[
            @intCast(helper)
        ].body = try b.bind(
            response,
            b.functions.items[@intCast(helper)].body.?,
            try b.term(.{ .perform = .{
                .effect = shape.second,
                .payload = try b.reference(response),
            } }),
        );
    }
    const helper_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{shape.u},
        .result = shape.u,
        .effects = asks,
    } } });
    return .{ .function = helper, .schema = helper_type };
}

fn handlerExposureHandler(
    b: *source.Builder,
    shape: HandlerExposureShape,
    callee: HandlerExposureCallee,
) !HandlerExposureHandler {
    const ask_storage = [_]Id{ shape.ask, shape.second };
    const asks = ask_storage[0..@as(usize, if (shape.variant == 5) 2 else 1)];
    const returns = try b.declare(&.{ shape.u, shape.unit }, shape.u, asks, &.{});
    const returned = try b.reference(b.parameter(returns, 0));
    try b.define(
        returns,
        if (shape.path_variant == 0) try b.term(.{ .apply = .{ .computation = try b.lambda(
            callee.function,
            callee.schema,
        ), .arguments = &.{returned} } }) else try b.pure(returned),
    );
    const clause = try b.declare(
        &.{ shape.u, shape.unit, shape.token },
        shape.u,
        if (shape.variant == 5) &.{
            shape.ask, shape.second, shape.local,
        } else &.{ shape.ask, shape.local },
        &.{},
    );
    const handler = try b.handler(
        .{
            .mode = shape.mode,
            .input = shape.unit,
            .answer = shape.u,
            .return_function = returns,
            .clauses = &.{
                .{ .effect = shape.local, .function = clause, .resumption = shape.token },
            },
            .state = &.{shape.u},
            .effects = if (shape.variant == 5) &.{
                shape.ask,
                shape.second,
                shape.local,
            } else &.{ shape.ask, shape.local },
        },
    );
    return .{ .returns = returns, .clause = clause, .id = handler };
}

fn defineHandlerExposureClause(
    b: *source.Builder,
    shape: HandlerExposureShape,
    callee: HandlerExposureCallee,
    handler: HandlerExposureHandler,
) !void {
    const answer = try b.variable(shape.u);
    const resumed = if (shape.mode == .shallow)
        try b.term(.{ .resume_with = .{ .resumption = try b.reference(
            b.parameter(handler.clause, 2),
        ), .argument = try b.constant(void, {}), .handler = handler.id, .state = &.{
            try b.reference(answer),
        } } })
    else
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(handler.clause, 2)),
            .argument = try b.constant(void, {}),
        } });
    try b.define(
        handler.clause,
        if (shape.path_variant == 0 or shape.path_variant >= 3) resumed else try b.bind(
            answer,
            try b.term(.{ .call = .{ .function = callee.function, .arguments = &.{
                try b.reference(b.parameter(handler.clause, 0)),
            } } }),
            resumed,
        ),
    );
}

fn handlerExposureResource(
    b: *source.Builder,
    shape: HandlerExposureShape,
    handler: HandlerExposureHandler,
) !Id {
    const resource = try b.resource(shape.u);
    try b.resourceAuthority(
        resource,
        &.{ handler.returns, handler.clause },
        &.{ handler.returns, handler.clause },
    );
    for ([_]Id{ handler.returns, handler.clause }) |function| {
        const response = try b.variable(shape.u);
        const owned = try b.variable(resource);
        b.functions.items[
            @intCast(function)
        ].body = try b.bind(
            response,
            b.functions.items[@intCast(function)].body.?,
            try b.bind(
                owned,
                try b.pure(
                    try b.primitive(resource, .resource_pack, &.{try b.reference(response)}, 0),
                ),
                try b.pure(
                    try b.primitive(shape.u, .resource_unpack, &.{try b.reference(owned)}, 0),
                ),
            ),
        );
    }
    return resource;
}

fn handlerExposureBody(
    b: *source.Builder,
    shape: HandlerExposureShape,
    callee: HandlerExposureCallee,
) !HandlerExposureBody {
    const body_effects: []const source.Id = if (shape.path_variant >= 3) if (shape.variant == 5) &.{
        shape.ask,
        shape.second,
        shape.local,
    } else &.{ shape.ask, shape.local } else &.{shape.local};
    const body = try b.declare(&.{shape.cap}, shape.unit, body_effects, &.{});
    const local_call = try b.term(.{ .perform = .{
        .effect = shape.local,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(
        body,
        if (shape.path_variant >= 3) try b.bind(
            try b.variable(shape.unit),
            local_call,
            try b.bind(
                try b.variable(shape.u),
                try b.term(.{ .call = .{ .function = callee.function, .arguments = &.{
                    try b.constant(u64, 17),
                } } }),
                try b.pure(try b.constant(void, {})),
            ),
        ) else local_call,
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{shape.cap},
        .result = shape.unit,
        .effects = body_effects,
    } } });
    return .{ .function = body, .schema = body_type };
}

fn handlerExposureEntry(
    b: *source.Builder,
    shape: HandlerExposureShape,
    handler: HandlerExposureHandler,
    body: HandlerExposureBody,
) !source.Module {
    const entry = try b.declare(
        &.{shape.unit},
        shape.u,
        if (shape.variant == 5) &.{
            shape.ask, shape.second, shape.local,
        } else &.{ shape.ask, shape.local },
        &.{},
    );
    const body_value = try b.lambda(body.function, body.schema);
    const stored_body = try b.variable(body.schema);
    const handled = try b.term(
        .{ .handle = .{ .handler = handler.id, .body = if (shape.path_variant == 4) try b.reference(
            stored_body,
        ) else body_value, .state = &.{try b.constant(u64, 17)} } },
    );
    try b.define(
        entry,
        if (shape.path_variant == 4) try b.bind(
            stored_body,
            try b.pure(body_value),
            handled,
        ) else handled,
    );
    return b.module(entry, shape.unit);
}

fn handlerExposureModule(b: *source.Builder, shape: HandlerExposureShape) !HandlerExposureModule {
    const callee = try handlerExposureCallee(b, shape);
    const handler = try handlerExposureHandler(b, shape, callee);
    try defineHandlerExposureClause(b, shape, callee, handler);
    const resource = try handlerExposureResource(b, shape, handler);
    const body = try handlerExposureBody(b, shape, callee);
    return .{ .module = try handlerExposureEntry(b, shape, handler, body), .resource = resource };
}

fn buildHandlerExposure(
    a: std.mem.Allocator,
    b: *source.Builder,
    shape: HandlerExposureShape,
    generated: HandlerExposureModule,
) !native.program_construction.Built {
    b.effects.items[@intCast(shape.ask)].external = true;
    b.effects.items[@intCast(shape.second)].external = true;
    var baseline = try source.lower(a, generated.module);
    baseline.deinit();
    b.effects.items[@intCast(shape.ask)].external = false;
    b.effects.items[@intCast(shape.second)].external = false;
    const text = try native.source_records.encode(a, generated.module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = native.program_construction.buildExposed(
        a,
        text,
        if (shape.variant == 5) &.{
            .{ .effect = shape.ask, .class = .input },
            .{ .effect = shape.second, .class = .input },
        } else &.{.{ .effect = shape.ask, .class = .input }},
        null,
        &diagnostic,
    ) catch |err| {
        std.debug.print("handler variant {d}: {s} {any}\n", .{
            shape.variant,
            @errorName(err),
            diagnostic,
        });
        return err;
    };
    return built;
}

fn runHandlerExposure(
    a: std.mem.Allocator,
    image: []const u8,
    shape: HandlerExposureShape,
) !void {
    var suspended = try kosmos.invocation.invoke(
        a,
        .{ .image = image, .instance = .{ .initial_args = &.{} } },
    );
    defer suspended.deinit();
    try std.testing.expectEqual(.requested, std.meta.activeTag(suspended.record));
    var request = try data.invocation.decode(
        data.invocation.Request,
        a,
        suspended.record.requested.request,
    );
    defer request.deinit();
    const expected = try contracts.encodeOwned(u64, a, 17);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, request.value.binding.payload);
    const value = try contracts.encodeOwned(u64, a, 42);
    defer a.free(value);
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request.value.request_identity,
        .value = value,
    });
    defer a.free(reply);
    var completed = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = suspended.record.requested.state.?,
    }, .control = .{ .reply = reply } });
    defer completed.deinit();
    if (shape.variant == 5) try completeSecondExposure(a, image, &completed, value);
    try std.testing.expectEqual(.completed, std.meta.activeTag(completed.record));
    try std.testing.expectEqualSlices(
        u8,
        if (shape.path_variant == 1 or shape.path_variant >= 3) expected else value,
        completed.record.completed,
    );
}

fn completeSecondExposure(
    a: std.mem.Allocator,
    image: []const u8,
    completed: anytype,
    value: []const u8,
) !void {
    try std.testing.expectEqual(.requested, std.meta.activeTag(completed.record));
    var next_request = try data.invocation.decode(
        data.invocation.Request,
        a,
        completed.record.requested.request,
    );
    defer next_request.deinit();
    try std.testing.expectEqualSlices(u8, value, next_request.value.binding.payload);
    const next_reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = next_request.value.request_identity,
        .value = value,
    });
    defer a.free(next_reply);
    const next = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
        .state = completed.record.requested.state.?,
    }, .control = .{ .reply = next_reply } });
    completed.deinit();
    completed.* = next;
}

fn rejectUnauthorizedHandlerExposure(
    a: std.mem.Allocator,
    b: *source.Builder,
    shape: HandlerExposureShape,
    generated: HandlerExposureModule,
) !void {
    var diagnostic: native.program_construction.Diagnostic = .{};
    // Transporting authority must never invent authority for an invalid
    // original body, even when all its callers are generated handlers.
    const resource_id = b.schemas.items[@intCast(generated.resource)].internal.abstract_resource;
    b.resources.items[@intCast(resource_id)].introducers = &.{};
    b.resources.items[@intCast(resource_id)].eliminators = &.{};
    const unauthorized = try native.source_records.encode(a, generated.module);
    defer a.free(unauthorized);
    try std.testing.expectError(
        error.InvalidOwnership,
        native.program_construction.buildExposed(
            a,
            unauthorized,
            if (shape.variant == 5) &.{
                .{ .effect = shape.ask, .class = .input },
                .{ .effect = shape.second, .class = .input },
            } else &.{.{ .effect = shape.ask, .class = .input }},
            null,
            &diagnostic,
        ),
    );
}
fn reconstructionSourceBytes(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    epoch: u64,
    source_ref: contracts.workspace.Ref,
    expected_source: []const u8,
) !void {
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(a);
    var next_offset: ?usize = 0;
    while (next_offset) |_| {
        const observed = try service.workspaceCommand(
            a,
            try std.fmt.allocPrint(a, "controller-source-{d}-{d}", .{
                epoch,
                parts.items.len,
            }),
            task,
            .{ .context = .{ .expand = .{ .reference = source_ref, .page = .{
                .offset = parts.items.len,
                .maximum = 48 * 1024,
            } } } },
        );
        try std.testing.expectEqual(.observed, observed.disposition);
        var page = try native.json.parse(a, observed.observation_json.bytes, .{});
        defer page.deinit();
        const fragment = native.json.get(page.value, "text").?.string;
        try parts.appendSlice(a, fragment);
        next_offset = if (native.json.get(page.value, "eof").?.bool) null else parts.items.len;
        if (next_offset != null) try std.testing.expect(fragment.len != 0);
    }
    try std.testing.expectEqualStrings(expected_source, parts.items);
}

fn expectControllerDescriptor(
    service: anytype,
    scratch: std.mem.Allocator,
    operation_id: []const u8,
    task: [16]u8,
    command: contracts.workspace.Command,
    reply_value: anytype,
    built: anytype,
) !void {
    const repeated = try service.workspaceCommand(scratch, operation_id, task, command);
    try std.testing.expectEqualDeep(reply_value.program, repeated.program);
    try std.testing.expectEqualStrings(
        contracts.controller.identity,
        built.controller.?.contract.bytes,
    );
    try std.testing.expectEqualStrings(
        built.controller.?.private_input.bytes,
        built.controller.?.carry.bytes,
    );
}

fn expectDirectDeriveOwnerCorruption(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    archive_path: []const u8,
    event: *native.testing.state.Event,
    owner: anytype,
) !void {
    const store = &service.namespace.store;
    _ = try service.exportCheckpoint(a, task, archive_path);
    try store.begin();
    defer store.rollback();
    event.*.controller_read.?.execution_revision += 1;
    try store.database.run("DELETE FROM events WHERE task=? AND seq=?", &.{ .{
        .blob = &task,
    }, .{ .integer = @intCast(event.*.seq) } });
    try store.putEvent(event.*);
    try service.namespace.commit("test.forge-direct-derive-owner");
    const forged_path = try std.fmt.allocPrint(a, "{s}-forged", .{archive_path});
    defer a.free(forged_path);
    try std.testing.expectError(
        error.InvalidArchive,
        service.exportCheckpoint(a, task, forged_path),
    );
    try store.begin();
    event.*.controller_read = owner;
    try store.database.run("DELETE FROM events WHERE task=? AND seq=?", &.{ .{
        .blob = &task,
    }, .{ .integer = @intCast(event.*.seq) } });
    try store.putEvent(event.*);
    try service.namespace.commit("test.restore-direct-derive-owner");
    const restored_path = try std.fmt.allocPrint(a, "{s}-restored", .{archive_path});
    defer a.free(restored_path);
    _ = try service.exportCheckpoint(a, task, restored_path);
}

fn expectDeriveCaptureOwnerCorruption(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    attempt: [32]u8,
    archive_path: []const u8,
    saved: *native.testing.state.Attempt,
    owner: anytype,
) !void {
    const store = &service.namespace.store;
    _ = try service.exportCheckpoint(a, task, archive_path);
    try store.begin();
    defer store.rollback();
    saved.*.controller_read.?.execution_revision += 1;
    try store.database.run("DELETE FROM records WHERE kind='attempt' AND id=? AND task=?", &.{ .{
        .blob = &attempt,
    }, .{ .blob = &task } });
    try store.createRecord(native.testing.state.Attempt, "attempt", attempt, task, saved.*);
    try service.namespace.commit("test.forge-derive-capture-owner");
    const forged_path = try std.fmt.allocPrint(a, "{s}-forged", .{archive_path});
    defer a.free(forged_path);
    try std.testing.expectError(
        error.InvalidArchive,
        service.exportCheckpoint(a, task, forged_path),
    );
    try store.begin();
    saved.*.controller_read = owner;
    try store.database.run("DELETE FROM records WHERE kind='attempt' AND id=? AND task=?", &.{ .{
        .blob = &attempt,
    }, .{ .blob = &task } });
    try store.createRecord(native.testing.state.Attempt, "attempt", attempt, task, saved.*);
    try service.namespace.commit("test.restore-derive-capture-owner");
    const restored_path = try std.fmt.allocPrint(a, "{s}-restored", .{archive_path});
    defer a.free(restored_path);
    _ = try service.exportCheckpoint(a, task, restored_path);
}

fn expectModelSchemaBudget(
    store: anytype,
    a: std.mem.Allocator,
    original_context: native.registry.ProjectionContext,
    original_delegation: native.workspace.Delegation,
    original_port: native.workspace.Port,
    artifact: native.testing.state.Reference,
    huge_schema: native.testing.state.Reference,
    empty: native.testing.state.Reference,
) !void {
    var context = original_context;
    var delegation = original_delegation;
    const prepare = native.workspace_instrument.declaration(.model).capture.?.prepare;
    for (0..2) |variant| {
        var port = original_port;
        if (variant == 0) {
            delegation.inputs.items = &.{artifact};
        } else {
            delegation.inputs.items = &.{};
            port.interface.payload = huge_schema;
            port.payload = empty;
        }
        delegation.port = try store.putObject(
            try contracts.encodeOwned(native.workspace.Port, a, port),
        );
        const ref = try store.putObject(
            try contracts.encodeOwned(native.workspace.Delegation, a, delegation),
        );
        const input = try contracts.encodeOwned(native.workspace_instrument.Input, a, .{
            .delegation = ref,
        });
        var buffer: [256 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buffer);
        context.allocator = allocator.allocator();
        try std.testing.expectError(error.Capacity, prepare(context, input));
    }
}
fn expectOperatorRuntimePreserved(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    before: anytype,
    pending_bytes: []const u8,
) !void {
    var realized = try service.task(a, task);
    defer realized.deinit();
    try std.testing.expectEqual(
        before.value.realization_revision + 1,
        realized.value.realization_revision,
    );
    inline for (.{
        "image",
        "controller_epoch",
        "execution_revision",
        "checkpoint",
        "current_occurrence",
        "controller",
        "controller_interaction",
    }) |field|
        try std.testing.expectEqualDeep(
            @field(before.value, field),
            @field(realized.value, field),
        );
    const retained = (try service.namespace.store.recordBytes(
        a,
        "occurrence",
        before.value.current_occurrence.?,
        task,
    )).?;
    defer a.free(retained);
    try std.testing.expectEqualSlices(u8, pending_bytes, retained);
}

fn runtimeControllerTarget(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    current: anytype,
    operator_switched: bool,
) !contracts.workspace.ControllerTarget {
    const id = current.value.controller_interaction orelse
        return error.MissingControllerInteraction;
    var interaction = try contracts.decodeOwned(
        native.testing.state.ControllerInteraction,
        a,
        (try service.namespace.store.recordBytes(a, "controller_interaction", id, task)).?,
    );
    defer interaction.deinit();
    const bytes = try service.namespace.store.object(a, interaction.value.overlay, null);
    defer a.free(bytes);
    var overlay = try native.json.parse(a, bytes, .{});
    defer overlay.deinit();
    const target = try native.values.fromJson(
        contracts.workspace.ControllerTarget,
        a,
        native.json.get(
            native.json.get(overlay.value, "control").?,
            "realization_target",
        ).?,
    );
    try std.testing.expectEqual(.action, std.meta.activeTag(target));
    try std.testing.expect(operator_switched);
    try std.testing.expectEqual(
        current.value.realization_revision,
        target.action.realization_revision,
    );
    return target;
}

fn moveReconstructionModel(
    service: anytype,
    a: std.mem.Allocator,
    root: []const u8,
    task: [16]u8,
    service_open: *bool,
    namespace_open: *bool,
    fixture: anytype,
) !void {
    const backing = std.testing.allocator;
    const p = native.placement;
    const subject: p.Subject = .{ .task = task };
    _ = try service.placementFreeze(
        a,
        subject,
        "destination",
        try service.placementCut(a, subject),
        @splat(84),
    );
    const path = try std.fmt.allocPrint(a, "{s}/model-move.archive", .{root});
    const offer = try service.placementOffer(a, subject, "destination", path);
    try service.close(backing);
    service_open.* = false;
    try fixture.source_namespace.close();
    namespace_open.* = false;
    var namespace = try native.Namespace.open(
        backing,
        fixture.io,
        try std.fmt.allocPrint(a, "{s}/model-destination", .{root}),
    );
    defer support.expectCleanup(namespace.close());
    var destination = try @TypeOf(service.*).init(
        backing,
        fixture.io,
        &namespace,
        fixture.assets,
        fixture.application,
        fixture.handlers,
        fixture.profile,
    );
    defer support.expectCleanup(destination.close(backing));
    try resumeReconstructionModel(&destination, &namespace, a, root, task, offer, path);
}

fn resumeReconstructionModel(
    destination: anytype,
    namespace: *native.Namespace,
    a: std.mem.Allocator,
    root: []const u8,
    task: [16]u8,
    offer: anytype,
    path: []const u8,
) !void {
    const decision = try destination.placementAccept(a, "model-move", "source", offer, path);
    try std.testing.expectEqual(.accepted, decision.value.verdict);
    try std.testing.expect(try destination.pump(a) == .idle);
    _ = try destination.message(a, "after-model-move", task, .{
        .bytes = "Use the new controller authority and current instructions.",
    });
    var admitted = try destination.task(a, task);
    defer admitted.deinit();
    try std.testing.expectEqual(@as(u64, 1), admitted.value.controller_epoch);
    _ = try destination.resumeTask(a, "resume-moved-model", task, admitted.value.revision);
    for (0..64) |_| {
        const step = try destination.pump(a);
        if (step != .work) continue;
        try destination.notSent(a, step.work);
        try std.testing.expect(
            step.work.subject_work == null and step.work.subject_residual == null,
        );
        try std.testing.expect(step.work.entry.declaration.inference);
        var current = try destination.task(a, task);
        defer current.deinit();
        const interaction = (try contracts.decodeOwned(
            native.testing.state.ControllerInteraction,
            a,
            (try namespace.store.recordBytes(
                a,
                "controller_interaction",
                current.value.controller_interaction.?,
                task,
            )).?,
        )).value;
        try std.testing.expectEqual(current.value.controller_epoch, interaction.epoch);
        try std.testing.expectEqual(current.value.next_message, interaction.next_message);
        _ = try destination.exportCheckpoint(
            a,
            task,
            try std.fmt.allocPrint(a, "{s}/moved-model-refreshed.archive", .{root}),
        );
        return;
    }
    return error.MovedModelDidNotResume;
}

fn materializeModelMoveSource(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work: native.tasks.Work,
) !void {
    var before = try service.task(a, task);
    defer before.deinit();
    const source_read = try service.workspaceCommand(
        a,
        "model-before-move-source",
        task,
        .{ .context = .{ .materialize = .{
            .input = .{ .semantic_source = .{
                .subject = .{ .controller = .{ .cut = .{
                    .epoch = before.value.controller_epoch,
                    .execution_revision = before.value.execution_revision,
                    .realization_revision = before.value.realization_revision,
                } } },
                .module = .{ .selected = .{} },
            } },
            .sources = .{ .items = &.{} },
        } } },
    );
    try std.testing.expectEqual(.observed, source_read.disposition);
    try service.notSent(a, work);
    try expectControllerValueBound(service, a, task, source_read.evidence.?);
}

fn emitWaitBody(
    b: *source.Builder,
    unit: Id,
    output: Id,
    command: Id,
    work_command: Id,
    inbox: Id,
    workspace: Id,
    inbox_schema: Id,
    message_schema: Id,
    entry: Id,
    message_id_schema: Id,
    selection_schema: Id,
) !source.Module {
    const received = try b.variable(inbox_schema);
    const empty = try b.variable(unit);
    const message = try b.variable(message_schema);
    const id = try b.variable(message_id_schema);
    const selection = try b.variable(selection_schema);
    const selected_work = try b.primitive(
        work_command,
        .variant,
        &.{try b.reference(selection)},
        @backingInt(std.meta.Tag(contracts.workspace.Work).wait),
    );
    const selected_command = try b.primitive(
        command,
        .variant,
        &.{selected_work},
        @backingInt(std.meta.Tag(contracts.workspace.Command).work),
    );
    const reply = try b.variable(output);
    const ignored = try b.variable(inbox_schema);
    const finish = try b.bind(
        ignored,
        try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }),
        try b.pure(try b.reference(reply)),
    );
    const wait = try b.bind(
        reply,
        try b.term(.{ .perform = .{ .effect = workspace, .payload = selected_command } }),
        finish,
    );
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(message),
        .variables = &.{ id, selection },
        .body = wait,
    } });
    const select = try b.term(.{ .match_sum = .{ .value = try b.reference(
        received,
    ), .cases = &.{ .{
        .variable = empty,
        .body = try b.term(.{ .fail = try b.constant(void, {}) }),
    }, .{ .variable = message, .body = unpack } } } });
    try b.define(
        entry,
        try b.bind(
            received,
            try b.term(.{ .perform = .{
                .effect = inbox,
                .payload = try b.constant(void, {}),
            } }),
            select,
        ),
    );
    return b.module(entry, unit);
}
fn advanceDeriveDispatchSource(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    work_id: [32]u8,
    worker: anytype,
    step: anytype,
) !void {
    _ = try service.workspaceControl(
        a,
        "work-derive-source-advance",
        task,
        work_id,
        1,
        1,
        .advance,
    );
    const advanced = try service.workspaceWork(a, task, work_id);
    try std.testing.expect(advanced.value.execution_revision > 1);
    while (!worker.finished()) try service.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    try service.completeWork(a, step.work, worker.result.?);
    try worker.release();
}

fn expectBoundedModelBody(
    store: anytype,
    a: std.mem.Allocator,
    child: native.workspace.Work,
    context: native.registry.ProjectionContext,
    delegation: *native.workspace.Delegation,
) !void {
    const prepare = native.workspace_instrument.declaration(.model).capture.?.prepare;
    const unlimited = (try contracts.decodeOwned(
        native.workspace_instrument.Prepared,
        a,
        try prepare(
            context,
            try contracts.encodeOwned(native.workspace_instrument.Input, a, .{
                .delegation = child.delegation.?,
            }),
        ),
    )).value;
    delegation.model.?.settings.request_bytes = 8 * 1024;
    const bounded_ref = try store.putObject(
        try contracts.encodeOwned(native.workspace.Delegation, a, delegation.*),
    );
    const bounded = (try contracts.decodeOwned(
        native.workspace_instrument.Prepared,
        a,
        try prepare(
            context,
            try contracts.encodeOwned(native.workspace_instrument.Input, a, .{
                .delegation = bounded_ref,
            }),
        ),
    )).value;
    try std.testing.expectEqualStrings(unlimited.body.bytes, bounded.body.bytes);
}

fn publishAlternativeInstrumentCheckpoint(
    store: anytype,
    a: std.mem.Allocator,
    resident: *kosmos.Resident,
    request_identity: [32]u8,
    forged: *native.workspace.Work,
) !void {
    const output = try contracts.encodeOwned(
        native.workspace_instrument.Output,
        a,
        .{ .unavailable = .{ .bytes = "invented alternative reply" } },
    );
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request_identity,
        .value = output,
    });
    var published = try resident.publish(
        .{ .encoded = a },
        .{ .reply = reply },
        .{ .quantum = 256, .checkpoint = .receipt },
    );
    const checkpoint = published.takeCheckpoint().?;
    defer checkpoint.deinit();
    var completed = try data.invocation.decode(
        data.invocation.Outcome,
        a,
        published.outcome.encoded,
    );
    defer completed.deinit();
    try std.testing.expectEqual(.completed, std.meta.activeTag(completed.value));
    forged.checkpoint = try store.putObject(checkpoint.bytes());
    forged.outcome = try store.putObject(published.outcome.encoded);
    forged.result = try store.putObject(completed.value.completed);
    forged.guest_work = published.guest_work;
}

fn reconstructionTrialResponse(
    successor: contracts.workspace.Ref,
    converter: contracts.workspace.Ref,
) Reconstruction.Response {
    return .{
        .adopt = .{
            .successor = successor,
            .converter = converter,
            .expected_controller_epoch = 0,
            .expected_handoff_identity = .{
                .bytes = "0000000000000000000000000000000000000000000000000000000000000000",
            },
            .reason = .{ .bytes = "Trial proposal only" },
        },
    };
}

fn consumeBoundedReconstructionTrial(
    fixture: anytype,
    id: [32]u8,
    work_ref: contracts.workspace.Ref,
    settled: anytype,
) !void {
    const service = fixture.service;
    const a = fixture.a;
    const task = fixture.task;
    const small: @FieldType(contracts.workspace.Work, "pump") = .{
        .expected = .{
            .work = work_ref,
            .execution_revision = settled.value.execution_revision,
            .control_revision = settled.value.control_revision,
        },
        .base_quantum = 1,
    };
    _ = try service.workspacePump(a, "trial-consume-bounded-pump", task, small);
    var suspended = try service.workspaceWork(a, task, id);
    defer suspended.deinit();
    try std.testing.expect(suspended.value.outer_operation != null);
    try std.testing.expectEqual(.parked, suspended.value.schedule);
    try std.testing.expectEqual(
        settled.value.execution_revision,
        suspended.value.execution_revision,
    );
    try std.testing.expect(
        (try service.workspacePump(a, "trial-consume-bounded-pump", task, small)).replayed,
    );
    try service.validateWorkspace(a, task);
}
pub fn reconstructionContinuity(
    process: ?ReconstructionProcess,
    scenario: ReconstructionCase,
) !void {
    const operator_failure = scenario == .operator_failure or scenario == .operator_failure_plain;
    const operator_unrearmed = scenario == .operator_unrearmed or
        scenario == .operator_unrearmed_cancel;
    const operator = scenario == .operator or
        operator_failure or
        operator_unrearmed or
        scenario == .operator_cancel;
    const held_cleanup = scenario == .held_cleanup or scenario == .recovery_cleanup;
    const residual_wait = scenario == .residual_wait or
        scenario == .residual_wait_park or
        scenario == .residual_wait_complete;
    const cleanup_command: ?contracts.workspace.Command = if (residual_wait) .{
        .work = .{ .wait = .{ .works = .{ .items = &.{} }, .after = std.math.maxInt(u64) } },
    } else if (scenario == .residual_read) .{
        .program = .{ .describe = .{ .section = .current_controller, .page = .{} } },
    } else if (scenario == .residual_mutation) .{
        .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = "{}",
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{} } } },
    } else null;
    var stage: []const u8 = "setup";
    errdefer std.debug.print("reconstruction {s} failure at {s}\n", .{ @tagName(scenario), stage });
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try reconstructionRegistryOwner(.{
        .operator_failure = &operator_failure,
        .operator_unrearmed = &operator_unrearmed,
        .operator = &operator,
        .held_cleanup = &held_cleanup,
        .residual_wait = &residual_wait,
        .cleanup_command = &cleanup_command,
        .stage = &stage,
        .a = &a,
        .io = &io,
        .scratch = &scratch,
        .process = &process,
        .scenario = &scenario,
    });
}

fn reconstructionRegistry(a: std.mem.Allocator, scenario: ReconstructionCase) !native.Registry {
    var cleanup_declaration = native.registry.controllerImport(
        .snapshot,
        native.leaf(
            u64,
            void,
            .{ .identity = "fixture.reconstruction.cleanup", .resource_role = "cleanup" },
            ReconstructionModel.cleanup,
        ),
    );
    if (scenario == .recovery_cleanup) cleanup_declaration.recovery = .{
        .identity = "fixture.cleanup.recovery",
        .version = 1,
        .rederive = ReconstructionModel.rederiveCleanup,
        .lookup = .{
            .acquire = ReconstructionModel.lookupCleanup,
            .verify = ReconstructionModel.verifyCleanup,
        },
    };
    const handlers = try native.Registry.init(a, &.{
        ReconstructionModel.declaration(),
        cleanup_declaration,
        native.inbox.declaration(Reconstruction.Types.Message),
        native.registry.controllerImport(.workspace, .{
            .identity = "fixture.reconstruction.workspace",
            .resource_role = "workspace",
            .kind = .workspace,
            .workspace = WaitApplication.authorize,
            .payload_schema = WaitApplication.schema,
            .resume_schema = WaitApplication.result,
        }),
    });
    return handlers;
}

fn reconstructionContract(scratch: std.mem.Allocator) !contracts.controller.Contract {
    const reply_schema = try native.program_construction.controller.replySchema(
        scratch,
        try native.values.schemaBytes(Reconstruction.Response, scratch),
    );
    const contract: contracts.controller.Contract = .{
        .result = .{ .bytes = try native.values.schemaBytes(Reconstruction.Output, scratch) },
        .failure = .{ .bytes = try native.values.schemaBytes(void, scratch) },
        .imports = .{ .items = &.{
            .{ .import = .deliberate, .payload = .{
                .bytes = try native.values.schemaBytes(Reconstruction.Proposal, scratch),
            }, .result = .{ .bytes = reply_schema }, .native_result = .{
                .bytes = try native.values.schemaBytes(Reconstruction.Response, scratch),
            } },
            .{ .import = .snapshot, .payload = .{
                .bytes = try native.values.schemaBytes(u64, scratch),
            }, .result = .{ .bytes = try native.values.schemaBytes(void, scratch) } },
            .{ .import = .workspace, .payload = .{
                .bytes = try native.values.schemaBytes(contracts.workspace.Command, scratch),
            }, .result = .{
                .bytes = try native.values.schemaBytes(contracts.workspace.Reply, scratch),
            } },
        } },
    };
    return contract;
}

fn reconstructionBuild(
    a: std.mem.Allocator,
    original_source: []const u8,
    contract: contracts.controller.Contract,
) !native.program_construction.Built {
    var diagnostic: native.program_construction.Diagnostic = .{};
    const original = native.program_construction.buildController(
        a,
        original_source,
        contract,
        null,
        &diagnostic,
    ) catch |err| {
        std.debug.print("fixture seed {s}: {s} function={?d} term={?d} value={?d}\n", .{
            @errorName(err),
            @tagName(diagnostic.phase),
            diagnostic.source.function,
            diagnostic.source.term,
            diagnostic.source.value,
        });
        return err;
    };
    return original;
}

fn reconstructionProfile(
    scratch: std.mem.Allocator,
    grants: *[4]native.registry.Grant,
    handlers: native.Registry,
    image_identity: [32]u8,
) !native.tasks.Profile {
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(
        42,
    ), .bytes = "controller-test", .authority = .{
        .grants = grants,
        .principal = "test",
        .tenant = "test",
        .inference = true,
    } };
    for (grants, handlers.entries) |*grant, entry| grant.* = .{
        .identity = entry.declaration.identity,
        .resource_role = entry.declaration.resource_role,
        .resource_identity = try profile.resourceIdentity(scratch, image_identity),
    };
    return profile;
}

fn reconstructionContractFailures(
    a: std.mem.Allocator,
    service: *native.tasks.Service(Reconstruction.Types),
) !void {
    var contract_allocator = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(
        contract_allocator.allocator(),
        struct {
            fn run(allocator: std.mem.Allocator, owner: @TypeOf(service)) !void {
                const value = try owner.controllerContract(allocator);
                defer allocator.free(value.result.bytes);
                defer allocator.free(value.failure.bytes);
                defer allocator.free(value.imports.items);
                defer for (value.imports.items) |item|
                    if (item.native_result != null) allocator.free(
                        item.result.bytes,
                    );
            }
        }.run,
        .{service},
    );
}

fn reconstructionInitialSource(
    scratch: std.mem.Allocator,
    source_builder: *source.Builder,
    scenario: ReconstructionCase,
    cleanup_command: ?contracts.workspace.Command,
) ![]const u8 {
    const original_source = try native.source_records.encode(
        scratch,
        try Reconstruction.controllerWithActions(
            source_builder,
            false,
            true,
            cleanup_command,
            if (scenario == .residual_outer) 256 else 0,
            scenario == .conversion_failure or scenario == .residual_history,
            scenario == .round_trip,
        ),
    );
    return original_source;
}

fn reconstructionApplication(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original_source: []const u8,
    original: *const native.program_construction.Built,
    image_identity: [32]u8,
) !native.discovery.Application {
    const application: native.discovery.Application = .{
        .arena = .init(
            a,
        ),
        .metadata = .null,
        .manifest = .null,
        .manifest_id = "controller-unit",
        .image_identity = image_identity,
        .controller = .{
            .source = original_source,
            .descriptor = try contracts.encodeOwned(
                contracts.controller.Descriptor,
                scratch,
                original.controller.?,
            ),
        },
    };
    return application;
}

fn reconstructionExecution(fixture: anytype) !bool {
    for (0..4096) |_| {
        var frame_arena = std.heap.ArenaAllocator.init(fixture.a);
        defer frame_arena.deinit();
        const frame = frame_arena.allocator();
        var current = try fixture.service.task(frame, fixture.task);
        defer current.deinit();
        try std.testing.expect(
            current.value.event_high >= fixture.progress.last_event and
                current.value.inference_attempts >= fixture.progress.last_attempts,
        );
        fixture.progress.last_event = current.value.event_high;
        fixture.progress.last_attempts = current.value.inference_attempts;
        try reconstructionLatePlacement(fixture, frame, &current);
        if (try reconstructionInvalidOffer(fixture, frame, &current)) return true;
        if (try reconstructionPreparation(fixture, frame, &current)) continue;
        if (try reconstructionRejectedCandidate(fixture, frame, &current)) return true;
        try reconstructionProcessCrash(fixture, frame, &current);
        if (try reconstructionEpochAdvance(fixture, frame, &current)) return true;
        if (try reconstructionTerminalCleanup(fixture, frame, &current)) break;
        const step = try reconstructionPump(fixture, frame, &current);
        if (step != .work) continue;
        const work = step.work;
        if (try reconstructionAcquisition(fixture, frame, &current, work)) return true;
    }
    return false;
}

fn reconstructionLatePlacement(fixture: anytype, frame: std.mem.Allocator, current: anytype) !void {
    if (fixture.scenario == .late_placement and
        current.value.controller_epoch == 1 and
        !fixture.progress.interleaved)
    {
        fixture.stage.* = "late placement admission";
        try std.testing.expect(fixture.service.profile.placement == null);
        fixture.service.profile.placement = &fixture.placement.*;
        try std.testing.expect(
            try fixture.service.placementStatus(frame, .{ .task = fixture.task }) == null,
        );
        const moved = try fixture.service.workspaceCommand(
            frame,
            "first-placement-move",
            fixture.task,
            .{ .placement = .{ .move = .{
                .subject = .{ .controller = .{} },
                .site = .{ .bytes = fixture.placement_peer.*.name },
                .operation = .{ .bytes = "late-controller-move" },
                .custody_epoch = 1,
            } } },
        );
        if (moved.disposition != .observed) std.debug.print("late placement: {s}\n", .{
            moved.observation_json.bytes,
        });
        try std.testing.expectEqual(.observed, moved.disposition);
        try std.testing.expectEqual(
            @as(u64, 1),
            (try fixture.service.placementStatus(frame, .{ .task = fixture.task })).?.epoch,
        );
        const withdrawn = try fixture.service.workspaceCommand(
            frame,
            "withdraw-first-placement",
            fixture.task,
            .{ .placement = .{ .withdraw = .{ .operation = .{
                .bytes = "late-controller-move",
            } } } },
        );
        try std.testing.expectEqual(.observed, withdrawn.disposition);
        fixture.progress.interleaved = true;
    }
}

fn reconstructionInvalidOffer(fixture: anytype, frame: std.mem.Allocator, current: anytype) !bool {
    if (fixture.scenario == .invalid_offer and current.value.blocker != null) {
        try std.testing.expectEqual(.denied, current.value.blocker.?);
        try std.testing.expectEqual(@as(u64, 0), current.value.inference_attempts);
        try std.testing.expect(!fixture.namespace.store.fenced);
        _ = try fixture.service.submit(frame, "after-invalid-controller", .{ .items = &.{2} });
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/invalid-offer.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        return true;
    }
    return false;
}

fn reconstructionPreparation(fixture: anytype, frame: std.mem.Allocator, current: anytype) !bool {
    if (current.value.controller_succession) |operation_id| {
        const operation_value = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            operation_id,
        );
        if (try reconstructionParkPreparingChild(fixture, frame, operation_value)) return true;
        if (!fixture.progress.interleaved and operation_value.phase == .preparing) {
            if (fixture.scenario == .instructions) {
                _ = try fixture.service.message(
                    frame,
                    "instructions-during-preparation",
                    fixture.task,
                    .{ .bytes = "Revise the task before adopting a new method." },
                );
                fixture.progress.interleaved = true;
                return true;
            }
            if (fixture.scenario == .cancellation or fixture.scenario == .operator_cancel) {
                _ = try fixture.service.requestCancel(
                    frame,
                    "cancel-during-preparation",
                    fixture.task,
                    "Stop before activation",
                );
                fixture.progress.interleaved = true;
                return true;
            }
            if (try reconstructionInterruptConversion(fixture, frame, operation_value)) return true;
        }
    }
    return false;
}

fn reconstructionRejectedCandidate(
    fixture: anytype,
    frame: std.mem.Allocator,
    current: anytype,
) !bool {
    if (switch (fixture.scenario) {
        .conversion_failure,
        .conversion_schema,
        .conversion_interrupt,
        .instructions,
        .cancellation,
        .operator_failure,
        .operator_failure_plain,
        .operator_cancel,
        => true,
        else => false,
    }) if (fixture.progress.first_handoff) |handoff| {
        const id = fixture.progress.first_succession.?;
        if (try fixture.namespace.store.recordBytes(
            frame,
            "controller_succession",
            id,
            fixture.task,
        )) |bytes| {
            const rejected = (try contracts.decodeOwned(
                native.testing.state.ControllerSuccession,
                frame,
                bytes,
            )).value;
            if (rejected.diagnostic != null) {
                try std.testing.expectEqual(@as(u64, 0), current.value.controller_epoch);
                try std.testing.expectEqualDeep(
                    fixture.initial.*.value.controller,
                    current.value.controller,
                );
                try std.testing.expect(
                    current.value.controller_succession == null and
                        rejected.converted == null and
                        rejected.boot == null and
                        rejected.residual == null,
                );
                try std.testing.expectEqual(@as(@TypeOf(rejected.phase), switch (fixture.scenario) {
                    .conversion_schema => .rejected,
                    .instructions, .cancellation, .operator_cancel => .aborted,
                    else => .failed,
                }), rejected.phase);
                try reconstructionFailedAdoptionReceipt(fixture, frame, handoff);
                try reconstructionRejectedSchemaCut(fixture, frame, rejected, id);
                try reconstructionFailedOperator(fixture, frame, current, handoff, rejected, id);
                try reconstructionStopRejected(fixture, frame);
                return true;
            }
        }
    };
    return false;
}

fn reconstructionProcessCrash(fixture: anytype, frame: std.mem.Allocator, current: anytype) !void {
    if (fixture.process) |p|
        if (current.value.controller_epoch == 0)
            if (current.value.controller_succession) |operation_id| {
                const operation_value = try reconstructionRecord(
                    native.testing.state.ControllerSuccession,
                    fixture,
                    frame,
                    "controller_succession",
                    operation_id,
                );
                if (operation_value.phase == .ready) {
                    if (std.mem.eql(u8, p.phase, "controller-ready")) try p.stop(
                        p.phase,
                        fixture.task,
                        operation_id,
                    );
                    const seal = std.mem.eql(u8, p.phase, "controller-seal");
                    const commit = std.mem.eql(u8, p.phase, "controller-commit");
                    if (seal or commit) {
                        const seal_path = try std.fmt.allocPrint(
                            frame,
                            "{s}/seal.next",
                            .{fixture.path},
                        );
                        if (seal) {
                            try std.Io.Dir.cwd().createDir(fixture.io, seal_path, .default_dir);
                        } else try fixture.namespace.store.database.exec(
                            \\CREATE TEMP TABLE controller_parent(id INTEGER PRIMARY KEY);
                            \\CREATE TEMP TABLE controller_child(parent INTEGER REFERENCES controller_parent(id) DEFERRABLE INITIALLY DEFERRED);
                            \\CREATE TEMP TRIGGER controller_commit_failure AFTER INSERT ON records WHEN NEW.kind='controller_binding' BEGIN
                            \\INSERT INTO controller_child VALUES(1);
                            \\END;
                        );
                        for (0..32) |_| {
                            _ = fixture.service.pump(frame) catch |err| {
                                try std.testing.expectEqual(
                                    if (seal) error.UnsafeStatePath else error.Constraint,
                                    err,
                                );
                                try std.testing.expect(fixture.namespace.store.fenced);
                                if (seal) try std.Io.Dir.cwd().deleteDir(fixture.io, seal_path);
                                try p.stop(p.phase, fixture.task, operation_id);
                                return error.ExpectedProcessDeath;
                            };
                        }
                        return error.MissingPublicationFailure;
                    }
                }
            };
}

fn reconstructionEpochAdvance(fixture: anytype, frame: std.mem.Allocator, current: anytype) !bool {
    if (current.value.controller_epoch > fixture.progress.epochs) {
        try reconstructionEpochIdentity(fixture, frame, current);
        if (fixture.progress.epochs == 1) {
            try reconstructionParkHistoricalResidual(fixture, frame);
            try std.testing.expectError(
                error.StaleOccurrence,
                fixture.service.acquire(frame, fixture.progress.first_work.?, &.{}),
            );
            try reconstructionReplayOperator(fixture, frame);
            if (try reconstructionResidualWorkspace(fixture, frame)) return true;
            if (try reconstructionResidualCustody(fixture, frame)) return true;
            if (try reconstructionResidualCancellation(fixture, frame)) return true;
            try reconstructionRetiredController(fixture, frame);
            try reconstructionRejectStaleController(fixture, frame);
            try reconstructionAnswerHeldChild(fixture, frame);
            fixture.progress.held = false;
        }
    }
    return false;
}

fn reconstructionTerminalCleanup(
    fixture: anytype,
    frame: std.mem.Allocator,
    current: anytype,
) !bool {
    if (current.value.terminal()) {
        try std.testing.expectEqual(.completed, current.value.outcome_kind);
        var output = try contracts.decodeOwned(
            Reconstruction.Output,
            frame,
            try fixture.namespace.store.object(frame, current.value.result.?, null),
        );
        defer output.deinit();
        try std.testing.expectEqualDeep(
            Reconstruction.Output{
                .total = 117,
                .covered = 4,
                .instruction_cut = if (fixture.amended) 3 else 2,
            },
            output.value,
        );
        if (fixture.scenario == .residual_history and !fixture.progress.history_advanced) {
            const residual = try reconstructionRecord(
                native.testing.state.ControllerResidual,
                fixture,
                frame,
                "controller_residual",
                fixture.progress.history_residual.?,
            );
            try std.testing.expect(
                residual.outcome_kind != .completed and
                    residual.outcome_kind != .failed and
                    residual.outcome_kind != .cancelled,
            );
            try std.testing.expectEqual(.parked, residual.schedule);
            const advanced = try fixture.service.workspaceCommand(
                frame,
                "advance-residual-history",
                fixture.task,
                .{ .work = .{ .advance = .{
                    .work = try workspaceRef(frame, .residual, residual.id),
                    .execution_revision = residual.execution_revision,
                    .control_revision = residual.control_revision,
                } } },
            );
            try std.testing.expectEqual(.observed, advanced.disposition);
            fixture.progress.history_advanced = true;
        }
        if (fixture.held_cleanup) {
            try std.testing.expect(!try fixture.service.taskCleanupComplete(frame, current.value));
            return true;
        }
        if (try fixture.service.taskCleanupComplete(frame, current.value)) return true;
    }
    return false;
}

fn reconstructionPump(
    fixture: anytype,
    frame: std.mem.Allocator,
    current: anytype,
) !@typeInfo(@TypeOf(fixture.service.pump(frame))).error_union.payload {
    const step = fixture.service.pump(frame) catch |err| {
        std.debug.print("reconstruction pump {s} epoch={d} revision={d} outcome={s} calls=" ++
            "{d} cleanup={d}\n", .{
            @errorName(err),
            current.value.controller_epoch,
            current.value.revision,
            @tagName(current.value.outcome_kind),
            fixture.progress.calls,
            fixture.progress.cleanups,
        });
        return err;
    };
    try reconstructionOuterResidual(fixture, frame);
    return step;
}

fn reconstructionAcquisition(
    fixture: anytype,
    frame: std.mem.Allocator,
    current: anytype,
    work: native.tasks.Work,
) !bool {
    if (work.entry.declaration.inference) {
        if (try reconstructionRetryAmended(fixture, frame, work)) return false;
        try reconstructionExpectedProposal(fixture, frame, work);
        const response = try reconstructionResponse(fixture, frame, current);
        if (fixture.progress.calls == 0) fixture.progress.first_work = work;
        if (fixture.scenario == .model_mobility) {
            try reconstructionModelMove(
                fixture.service,
                frame,
                fixture.path_buffer.*[0..fixture.length],
                fixture.task,
                work,
                fixture.destination_identity.?,
                &fixture.service_open.*,
                &fixture.namespace_open.*,
            );
            return true;
        }
        if (fixture.operator and fixture.progress.calls == 0) {
            try reconstructionOperatorAdmission(fixture, frame, work, response);
            return false;
        }
        try fixture.service.acquire(
            frame,
            work,
            try contracts.encodeOwned(Reconstruction.Response, frame, response),
        );
        try reconstructionFreezeCaptured(fixture, frame);
        fixture.progress.calls += 1;
    } else {
        try std.testing.expectEqualStrings(
            "fixture.reconstruction.cleanup",
            work.entry.declaration.identity,
        );
        if (fixture.held_cleanup and
            work.subject_residual != null and
            fixture.progress.held_residual == null)
        {
            fixture.progress.held_residual = work.subject_residual;
            try fixture.service.unknown(frame, work);
        } else try fixture.service.acquire(frame, work, &.{});
        fixture.progress.cleanups += 1;
    }
    return false;
}

const ReconstructionProgress = struct {
    first_work: ?native.tasks.Work = null,
    calls: usize = 0,
    epochs: usize = 0,
    cleanups: usize = 0,
    held: bool = true,
    interleaved: bool = false,
    child_parked: bool = false,
    held_residual: ?[32]u8 = null,
    history_residual: ?[32]u8 = null,
    history_advanced: bool = false,
    first_handoff: ?contracts.workspace.Adoption = null,
    first_succession: ?[32]u8 = null,
    operator_params: ?native.json.Value = null,
    last_event: u64 = 0,
    last_attempts: u64 = 0,
    retried: bool = false,
    outer_cancel: bool = false,
    outer_reply: bool = false,
};

fn reconstructionParkPreparingChild(
    fixture: anytype,
    frame: std.mem.Allocator,
    operation_value: native.testing.state.ControllerSuccession,
) !bool {
    if (operation_value.phase == .preparing and !fixture.progress.child_parked) {
        if (fixture.service.profile.placement != null) try std.testing.expectError(
            error.UnsettledController,
            fixture.service.placementFreeze(
                frame,
                .{ .task = fixture.task },
                fixture.placement_peer.*.name,
                try fixture.service.placementCut(frame, .{ .task = fixture.task }),
                @splat(75),
            ),
        );
        _ = try fixture.service.workspaceControl(
            frame,
            "child-during-preparation",
            fixture.task,
            fixture.child_id,
            fixture.child.value.execution_revision,
            fixture.child.value.control_revision,
            .park,
        );
        fixture.child.deinit();
        fixture.child.* = try fixture.service.workspaceWork(
            fixture.a,
            fixture.task,
            fixture.child_id,
        );
        try std.testing.expect(
            fixture.child.value.current_port != null and !fixture.child.value.terminal(),
        );
        fixture.progress.child_parked = true;
        return true;
    }
    return false;
}

fn reconstructionInterruptConversion(
    fixture: anytype,
    frame: std.mem.Allocator,
    operation_value: native.testing.state.ControllerSuccession,
) !bool {
    if (fixture.scenario == .conversion_interrupt) if (operation_value.conversion_work) |id| {
        var conversion = try fixture.service.workspaceWork(frame, fixture.task, id);
        defer conversion.deinit();
        try std.testing.expect(!conversion.value.terminal());
        try reconstructionDenyConversionMove(fixture, frame, id);
        const independent: native.placement.Subject = .{
            .task = fixture.task,
            .work = fixture.child_id,
        };
        _ = try fixture.service.placementFreeze(
            frame,
            independent,
            fixture.placement_peer.*.name,
            try fixture.service.placementCut(frame, independent),
            @splat(82),
        );
        try fixture.service.placementAbortUnsent(frame, independent, @splat(82));
        _ = try fixture.service.workspaceControl(
            frame,
            "interrupt-divergent-converter",
            fixture.task,
            id,
            conversion.value.execution_revision,
            conversion.value.control_revision,
            .{ .cancel = .{ .bytes = "Interrupt divergent conversion" } },
        );
        fixture.progress.interleaved = true;
        return true;
    };
    return false;
}

fn reconstructionDenyConversionMove(fixture: anytype, frame: std.mem.Allocator, id: [32]u8) !void {
    const subject: native.placement.Subject = .{ .task = fixture.task, .work = id };
    try std.testing.expectError(
        error.UnsettledController,
        fixture.service.placementFreeze(
            frame,
            subject,
            fixture.placement_peer.*.name,
            try fixture.service.placementCut(frame, subject),
            @splat(81),
        ),
    );
    const denied = try fixture.service.workspaceCommand(
        frame,
        "move-preparing-converter",
        fixture.task,
        .{ .placement = .{ .move = .{
            .subject = .{ .work = try workspaceRef(frame, .work, id) },
            .site = .{ .bytes = fixture.placement_peer.*.name },
            .operation = .{ .bytes = "converter-move" },
            .custody_epoch = 0,
        } } },
    );
    try std.testing.expectEqual(.rejected, denied.disposition);
    if (std.mem.indexOf(
        u8,
        denied.observation_json.bytes,
        "UnsettledController",
    ) == null) std.debug.print("converter placement: {s}\n", .{
        denied.observation_json.bytes,
    });
    try std.testing.expect(
        std.mem.indexOf(u8, denied.observation_json.bytes, "UnsettledController") != null,
    );
}

fn reconstructionFailedAdoptionReceipt(
    fixture: anytype,
    frame: std.mem.Allocator,
    handoff: contracts.workspace.Adoption,
) !void {
    if (fixture.scenario == .conversion_failure) {
        const replay = try fixture.service.workspaceCommand(
            frame,
            "failed-adoption-receipt",
            fixture.task,
            .{ .program = .{ .adopt = handoff } },
        );
        try std.testing.expectEqual(.observed, replay.disposition);
        for (0..128) |_| {
            const progress = try fixture.service.pump(frame);
            try std.testing.expect(progress != .work);
            var query = try fixture.namespace.store.database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                    "ERE r.kind='workspace_reply' AND r.task=?",
                &.{.{ .blob = &fixture.task }},
            );
            defer query.deinit();
            if (try query.step() != .row) continue;
            const evidence = (try contracts.decodeOwned(
                native.workspace.ReplyObservation,
                frame,
                try query.bytes(0),
            )).value;
            try std.testing.expectEqual(.rejected, std.meta.activeTag(evidence.evidence));
            try std.testing.expectEqual(.authorization, evidence.evidence.rejected.stage);
            try std.testing.expectEqualStrings(
                "ControllerHandoffRequired",
                evidence.evidence.rejected.code.bytes,
            );
            const request = (try data.invocation.decode(
                data.invocation.Request,
                frame,
                try fixture.namespace.store.object(frame, evidence.request, null),
            )).value;
            const command = (try contracts.decodeOwned(
                contracts.workspace.Command,
                frame,
                request.binding.payload,
            )).value;
            try std.testing.expectEqualDeep(handoff, command.program.adopt);
            try fixture.service.validateWorkspace(frame, fixture.task);
            break;
        } else return error.AuthoredAdoptionDidNotSettle;
    }
}

fn reconstructionRejectedSchemaCut(
    fixture: anytype,
    frame: std.mem.Allocator,
    rejected: native.testing.state.ControllerSuccession,
    id: [32]u8,
) !void {
    if (fixture.scenario == .conversion_schema) {
        var forged = rejected;
        forged.event_cut = fixture.initial_binding.activated_at;
        forged.next_message = 1;
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        try fixture.namespace.store.putRecord(
            native.testing.state.ControllerSuccession,
            "controller_succession",
            id,
            fixture.task,
            forged,
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspace(frame, fixture.task),
        );
        fixture.namespace.store.rollback();
    }
}

fn reconstructionFailedOperator(
    fixture: anytype,
    frame: std.mem.Allocator,
    current: anytype,
    handoff: contracts.workspace.Adoption,
    rejected: native.testing.state.ControllerSuccession,
    id: [32]u8,
) !void {
    if (fixture.operator_failure) {
        try std.testing.expectEqual(.parked, current.value.schedule);
        for (0..8) |_| try std.testing.expect(try fixture.service.pump(frame) != .work);
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/operator-failed.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        try reconstructionRetryFailedOperator(fixture, frame, handoff, id);
        try reconstructionResumeFailedOperator(fixture, frame, handoff);
        var forged = rejected;
        forged.next_message += 1;
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        try fixture.namespace.store.putRecord(
            native.testing.state.ControllerSuccession,
            "controller_succession",
            id,
            fixture.task,
            forged,
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspace(frame, fixture.task),
        );
        fixture.namespace.store.rollback();
    }
}

fn reconstructionStopRejected(fixture: anytype, frame: std.mem.Allocator) !void {
    _ = try fixture.service.requestCancel(
        frame,
        "stop-rejected-controller",
        fixture.task,
        "Finish the rejected-controller fixture",
    );
    for (0..128) |_| {
        var stopped = try fixture.service.task(frame, fixture.task);
        defer stopped.deinit();
        if (stopped.value.terminal() and try fixture.service.taskCleanupComplete(
            frame,
            stopped.value,
        )) break;
        const progress = try fixture.service.pump(frame);
        if (progress == .work) {
            try std.testing.expect(!progress.work.entry.declaration.inference);
            try fixture.service.acquire(frame, progress.work, &.{});
        }
    } else return error.PredecessorDidNotStop;
    _ = try fixture.service.exportCheckpoint(
        frame,
        fixture.task,
        try std.fmt.allocPrint(frame, "{s}/rejected.archive", .{
            fixture.path_buffer.*[0..fixture.length],
        }),
    );
}

fn reconstructionRetryFailedOperator(
    fixture: anytype,
    frame: std.mem.Allocator,
    handoff: contracts.workspace.Adoption,
    id: [32]u8,
) !void {
    if (fixture.scenario == .operator_failure_plain) {
        var retry_command = handoff;
        retry_command.reason = .{
            .bytes = "A separate operator attempt at the same handoff",
        };
        var stopped = try fixture.service.task(frame, fixture.task);
        defer stopped.deinit();
        _ = try fixture.service.adoptController(
            frame,
            "separate-operator-retry",
            fixture.task,
            stopped.value.revision,
            retry_command,
        );
        var retry = try fixture.service.task(frame, fixture.task);
        defer retry.deinit();
        const retry_id = retry.value.controller_succession.?;
        try std.testing.expect(!std.meta.eql(id, retry_id));
        try std.testing.expectEqualDeep(
            stopped.value.controller_interaction,
            retry.value.controller_interaction,
        );
        for (0..128) |_| {
            _ = try fixture.service.pump(frame);
            var after = try fixture.service.task(frame, fixture.task);
            defer after.deinit();
            if (after.value.controller_succession == null) break;
        } else return error.OperatorRetryDidNotFinish;
        const retried_operation = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            retry_id,
        );
        try std.testing.expectEqual(.failed, retried_operation.phase);
        try std.testing.expect(retried_operation.diagnostic != null);
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/operator-retried.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
    }
}

fn reconstructionResumeFailedOperator(
    fixture: anytype,
    frame: std.mem.Allocator,
    handoff: contracts.workspace.Adoption,
) !void {
    if (fixture.scenario == .operator_failure) _ = try fixture.service.message(
        frame,
        "after-failed-adoption",
        fixture.task,
        .{ .bytes = "Continue the original controller with current instructions." },
    );
    var stopped = try fixture.service.task(frame, fixture.task);
    defer stopped.deinit();
    _ = try fixture.service.resumeTask(
        frame,
        "resume-after-failed-adoption",
        fixture.task,
        stopped.value.revision,
    );
    var responses: usize = 0;
    for (0..128) |_| {
        const progress = try fixture.service.pump(frame);
        if (progress != .work) continue;
        try std.testing.expect(progress.work.entry.declaration.inference);
        if (responses == 0) {
            var next_command = handoff;
            next_command.reason = .{ .bytes = "Retry from the captured model operation" };
            try fixture.service.acquire(
                frame,
                progress.work,
                try contracts.encodeOwned(
                    Reconstruction.Response,
                    frame,
                    if (fixture.scenario == .operator_failure_plain) .{
                        .adopt = next_command,
                    } else .{ .next = {} },
                ),
            );
            responses += 1;
        } else {
            try fixture.service.notSent(frame, progress.work);
            break;
        }
    } else return error.FailedOperatorDidNotResume;
    _ = try fixture.service.exportCheckpoint(
        frame,
        fixture.task,
        try std.fmt.allocPrint(frame, "{s}/operator-resumed.archive", .{
            fixture.path_buffer.*[0..fixture.length],
        }),
    );
}

fn reconstructionRetryAmended(
    fixture: anytype,
    frame: std.mem.Allocator,
    work: native.tasks.Work,
) !bool {
    if (fixture.amended_retry and fixture.progress.calls == 0 and !fixture.progress.retried) {
        try fixture.service.notSent(frame, work);
        _ = try fixture.service.message(frame, "amend-before-retry", fixture.task, .{
            .bytes = "Preserve this instruction when retrying the request.",
        });
        var stopped = try fixture.service.task(frame, fixture.task);
        defer stopped.deinit();
        _ = try fixture.service.resumeTask(
            frame,
            "retry-amended-model",
            fixture.task,
            stopped.value.revision,
        );
        fixture.progress.retried = true;
        return true;
    }
    return false;
}

fn reconstructionExpectedProposal(
    fixture: anytype,
    frame: std.mem.Allocator,
    work: native.tasks.Work,
) !void {
    var request = try data.invocation.decode(data.invocation.Request, frame, work.request);
    defer request.deinit();
    var proposal = try contracts.decodeOwned(
        Reconstruction.Proposal,
        frame,
        try work.entry.payload(frame, request.value.binding.payload),
    );
    defer proposal.deinit();
    const expected = [_]Reconstruction.Proposal{
        .{
            .position = 0,
            .value = 2,
            .total = 2,
            .covered = 1,
            .indexed = false,
            .instruction_cut = 1,
        },
        .{
            .position = 2,
            .value = 107,
            .total = 117,
            .covered = 4,
            .indexed = true,
            .instruction_cut = if (fixture.amended) 2 else 1,
        },
        .{
            .position = 2,
            .value = 107,
            .total = 117,
            .covered = 4,
            .indexed = false,
            .instruction_cut = if (fixture.amended) 3 else 2,
        },
    };
    try std.testing.expect(fixture.progress.calls < expected.len);
    try std.testing.expectEqualDeep(expected[fixture.progress.calls], proposal.value);
}

fn reconstructionResponse(
    fixture: anytype,
    frame: std.mem.Allocator,
    current: anytype,
) !Reconstruction.Response {
    const response: Reconstruction.Response = if (fixture.progress.calls < 2) blk: {
        const id = current.value.controller_interaction.?;
        const adoption: contracts.workspace.Adoption = .{
            .successor = if (fixture.progress.calls == 0) fixture.programs.*[0] else fixture.a_ref,
            .converter = fixture.programs.*[fixture.progress.calls + 1],
            .expected_controller_epoch = current.value.controller_epoch,
            .expected_handoff_identity = .{
                .bytes = try fixture.scratch.dupe(u8, &std.fmt.bytesToHex(id, .lower)),
            },
            .reason = .{ .bytes = "Change the executable evidence traversal" },
        };
        if (fixture.progress.calls == 0) {
            fixture.progress.first_handoff = adoption;
            fixture.progress.first_succession = id;
        }
        break :blk .{ .adopt = adoption };
    } else if (fixture.scenario == .residual_history) .{
        .inspect = try workspaceRef(frame, .residual, fixture.progress.history_residual.?),
    } else .{ .next = {} };
    return response;
}

fn reconstructionOperatorAdmission(
    fixture: anytype,
    frame: std.mem.Allocator,
    work: native.tasks.Work,
    response: Reconstruction.Response,
) !void {
    if (fixture.operator and fixture.progress.calls == 0) {
        fixture.stage.* = "operator admission";
        const command = response.adopt;
        try reconstructionOperatorCustody(fixture, frame, work, command);
        const params = try reconstructionOperatorCommand(fixture, frame, command);
        var preparing = try fixture.service.task(frame, fixture.task);
        defer preparing.deinit();
        fixture.progress.first_succession = preparing.value.controller_succession.?;
        try std.testing.expect(
            !std.meta.eql(
                fixture.progress.first_succession.?,
                preparing.value.controller_interaction.?,
            ),
        );
        fixture.progress.operator_params = params;
        fixture.stage.* = "operator preparing export";
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/operator-preparing.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        try reconstructionOperatorAdmissionForgery(fixture, frame);
        try reconstructionOperatorReopen(fixture, frame);
        fixture.stage.* = "operator execution";
        fixture.progress.calls += 1;
        return;
    }
}

fn reconstructionFreezeCaptured(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.progress.calls == 0 and fixture.service.profile.placement != null) {
        const root_subject: native.placement.Subject = .{ .task = fixture.task };
        const cut = try fixture.service.placementCut(frame, root_subject);
        _ = try fixture.service.placementFreeze(
            frame,
            root_subject,
            fixture.placement_peer.*.name,
            cut,
            @splat(76),
        );
        for (0..8) |_| _ = try fixture.service.pump(frame);
        var frozen = try fixture.service.task(frame, fixture.task);
        defer frozen.deinit();
        try std.testing.expectEqual(@as(u64, 0), frozen.value.controller_epoch);
        try std.testing.expect(frozen.value.controller_succession == null);
        try std.testing.expectEqualDeep(
            cut,
            try fixture.service.placementCut(frame, root_subject),
        );
        try std.testing.expectError(
            error.CustodyNotLocal,
            fixture.service.resumeTask(
                frame,
                "frozen-no-activation",
                fixture.task,
                frozen.value.revision,
            ),
        );
        try fixture.service.placementAbortUnsent(frame, root_subject, @splat(76));
        _ = try fixture.service.resumeTask(
            frame,
            "after-frozen-exclusion",
            fixture.task,
            frozen.value.revision,
        );
    }
}

fn reconstructionOperatorCustody(
    fixture: anytype,
    frame: std.mem.Allocator,
    work: native.tasks.Work,
    command: contracts.workspace.Adoption,
) !void {
    var dispatched = try fixture.service.task(frame, fixture.task);
    defer dispatched.deinit();
    try std.testing.expectError(
        error.UnsettledOccurrence,
        fixture.service.adoptController(
            frame,
            "operator-while-dispatched",
            fixture.task,
            dispatched.value.revision,
            command,
        ),
    );
    try fixture.service.notSent(frame, work);
    if (fixture.scenario != .operator_failure_plain) _ = try fixture.service.message(
        frame,
        "operator-current-instructions",
        fixture.task,
        .{ .bytes = "Recover using the current evidence and instructions." },
    );
    const subject: native.placement.Subject = .{ .task = fixture.task };
    const cut = try fixture.service.placementCut(frame, subject);
    _ = try fixture.service.placementFreeze(
        frame,
        subject,
        fixture.placement_peer.*.name,
        cut,
        @splat(78),
    );
    var frozen = try fixture.service.task(frame, fixture.task);
    defer frozen.deinit();
    try std.testing.expectError(
        error.CustodyNotLocal,
        fixture.service.adoptController(
            frame,
            "operator-without-custody",
            fixture.task,
            frozen.value.revision,
            command,
        ),
    );
    try fixture.service.placementAbortUnsent(frame, subject, @splat(78));
}

fn reconstructionOperatorCommand(
    fixture: anytype,
    _: std.mem.Allocator,
    command: contracts.workspace.Adoption,
) !native.json.Value {
    var client: native.client.Client(Reconstruction.Types) = .{ .service = fixture.service };
    var params = native.json.object();
    try native.json.put(
        fixture.scratch,
        &params,
        "task_id",
        native.json.string(
            try fixture.scratch.dupe(u8, &std.fmt.bytesToHex(fixture.task, .lower)),
        ),
    );
    const status = try client.call(fixture.scratch, .@"task.status", params);
    try std.testing.expectEqualStrings(
        command.expected_handoff_identity.bytes,
        status.object.get("controller_handoff").?.string,
    );
    try native.json.put(
        fixture.scratch,
        &params,
        "client_operation_id",
        native.json.string("operator-adopt"),
    );
    try native.json.put(
        fixture.scratch,
        &params,
        "expected_revision",
        status.object.get("revision").?,
    );
    try native.json.put(
        fixture.scratch,
        &params,
        "adoption",
        try native.values.toJson(contracts.workspace.Adoption, fixture.scratch, command),
    );
    const adoption_result = try client.call(fixture.scratch, .@"task.adopt", params);
    try std.testing.expect(!adoption_result.object.get("replayed").?.bool);
    return params;
}

fn reconstructionOperatorAdmissionForgery(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.scenario == .operator) for (0..2) |variant| {
        const id = fixture.progress.first_succession.?;
        var altered = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            id,
        );
        if (variant == 0) {
            const not_sent = altered.operator_admission.?.occurrence.state.not_sent;
            altered.operator_admission.?.occurrence.state = .{ .unknown = not_sent };
        } else altered.operator_admission.?.revision += 1;
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        try fixture.namespace.store.putRecord(
            native.testing.state.ControllerSuccession,
            "controller_succession",
            id,
            fixture.task,
            altered,
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspace(frame, fixture.task),
        );
        fixture.namespace.store.rollback();
    };
}

fn reconstructionOperatorReopen(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.scenario == .operator) {
        fixture.stage.* = "operator reopen";
        const reopened_profile = fixture.service.profile;
        try fixture.service.close(fixture.a);
        fixture.service_open.* = false;
        fixture.service.* = try native.tasks.Service(Reconstruction.Types).init(
            fixture.a,
            fixture.io,
            fixture.namespace,
            fixture.assets,
            fixture.application,
            fixture.handlers.*,
            reopened_profile,
        );
        fixture.service_open.* = true;
        try std.testing.expect(try fixture.service.pump(frame) == .idle);
        var reopened = try fixture.service.task(frame, fixture.task);
        defer reopened.deinit();
        try std.testing.expect(reopened.value.controller_succession != null);
        _ = try fixture.service.resumeTask(
            frame,
            "operator-resume-conversion",
            fixture.task,
            reopened.value.revision,
        );
    }
}

fn reconstructionEpochIdentity(fixture: anytype, frame: std.mem.Allocator, current: anytype) !void {
    fixture.progress.epochs = @intCast(current.value.controller_epoch);
    try std.testing.expect(fixture.progress.epochs <= 2);
    const binding = try reconstructionRecord(
        native.testing.state.ControllerBinding,
        fixture,
        frame,
        "controller_binding",
        current.value.controller.?,
    );
    try std.testing.expectEqualDeep(
        try nativeIdentity(
            if (fixture.progress.epochs == 1) fixture.programs.*[0] else fixture.a_ref,
        ),
        binding.program,
    );
    try std.testing.expectEqualDeep(fixture.task, current.value.id);
    try std.testing.expectEqualDeep(fixture.initial.*.value.input, current.value.input);
    try std.testing.expectEqualDeep(fixture.initial.*.value.image, current.value.image);
    if (fixture.process) |p| if (fixture.progress.epochs == 1 and std.mem.eql(
        u8,
        p.phase,
        "controller-activated",
    )) {
        try p.stop(p.phase, fixture.task, fixture.progress.first_succession.?);
    };
    try reconstructionSource(
        fixture.service,
        frame,
        fixture.task,
        fixture.progress.epochs,
        if (fixture.progress.epochs == 1) fixture.programs.*[0] else fixture.a_ref,
        if (fixture.progress.epochs == 1) fixture.indexed_source.* else fixture.original_source,
    );
    if (!fixture.operator) {
        const replayed = try fixture.service.workspaceCommand(
            frame,
            "replay-after-epoch",
            fixture.task,
            .{ .program = .{ .adopt = fixture.progress.first_handoff.? } },
        );
        try std.testing.expectEqual(.observed, replayed.disposition);
        const observation = (try native.json.parse(
            frame,
            replayed.observation_json.bytes,
            .{},
        )).value;
        try std.testing.expectEqualStrings(
            "activated",
            native.json.get(observation, "phase").?.string,
        );
    }
}

fn reconstructionParkHistoricalResidual(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.scenario == .residual_history) {
        const succession = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            fixture.progress.first_succession.?,
        );
        fixture.progress.history_residual = succession.residual.?;
        const residual = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            fixture.progress.history_residual.?,
        );
        const parked = try fixture.service.workspaceCommand(
            frame,
            "park-residual-history",
            fixture.task,
            .{ .work = .{ .park = .{
                .work = try workspaceRef(frame, .residual, residual.id),
                .execution_revision = residual.execution_revision,
                .control_revision = residual.control_revision,
            } } },
        );
        try std.testing.expectEqual(.observed, parked.disposition);
    }
}

fn reconstructionReplayOperator(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.progress.operator_params) |params| {
        var client: native.client.Client(Reconstruction.Types) = .{ .service = fixture.service };
        const replay = try client.call(frame, .@"task.adopt", params);
        try std.testing.expect(replay.object.get("replayed").?.bool);
        try std.testing.expectEqualStrings(
            "1",
            replay.object.get("controller_epoch").?.string,
        );
        var changed = (try native.json.parse(frame, try native.json.canonical(
            frame,
            params,
        ), .{})).value;
        var command = fixture.progress.first_handoff.?;
        command.reason = .{ .bytes = "Different bytes for the same operator operation" };
        try native.json.put(
            frame,
            &changed,
            "adoption",
            try native.values.toJson(contracts.workspace.Adoption, frame, command),
        );
        try std.testing.expectError(
            error.OperationConflict,
            client.call(frame, .@"task.adopt", changed),
        );
    }
}

fn reconstructionResidualWorkspace(fixture: anytype, frame: std.mem.Allocator) !bool {
    if (fixture.cleanup_command != null) {
        const succession_id = fixture.progress.first_succession.?;
        const succession = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            succession_id,
        );
        const residual_id = succession.residual.?;
        try reconstructionPumpResidualRead(fixture, frame, residual_id);
        fixture.stage.* = "export residual workspace";
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/residual-workspace.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        return true;
    }
    return false;
}

fn reconstructionResidualCustody(fixture: anytype, frame: std.mem.Allocator) !bool {
    if (fixture.scenario == .residual_custody) {
        const succession_id = fixture.progress.first_succession.?;
        const succession = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            succession_id,
        );
        const residual_id = succession.residual.?;
        const residual = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            residual_id,
        );
        try std.testing.expectEqual(.queued, residual.schedule);
        const subject: native.placement.Subject = .{ .task = fixture.task };
        const cut = try fixture.service.placementCut(frame, subject);
        _ = try fixture.service.placementFreeze(
            frame,
            subject,
            fixture.placement_peer.*.name,
            cut,
            @splat(77),
        );
        for (0..16) |_| try std.testing.expect(try fixture.service.pump(frame) != .work);
        for (fixture.service.runnable.items) |queued| try std.testing.expect(
            !std.meta.eql(queued.residual, residual_id),
        );
        try fixture.service.placementAbortUnsent(frame, subject, @splat(77));
        var observed: usize = 0;
        for (0..128) |_| {
            const progress = try fixture.service.pump(frame);
            if (progress == .work) {
                try std.testing.expectEqualDeep(
                    residual_id,
                    progress.work.subject_residual.?,
                );
                try fixture.service.acquire(frame, progress.work, &.{});
                observed += 1;
            }
            const stopped = try reconstructionRecord(
                native.testing.state.ControllerResidual,
                fixture,
                frame,
                "controller_residual",
                residual_id,
            );
            if (stopped.outcome_kind == .cancelled) break;
        } else return error.ResidualDidNotResume;
        try std.testing.expectEqual(@as(usize, 1), observed);
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/restored-residual.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        return true;
    }
    return false;
}

fn reconstructionResidualCancellation(fixture: anytype, frame: std.mem.Allocator) !bool {
    if (fixture.scenario == .residual_cancel or fixture.operator_unrearmed) {
        const succession_id = fixture.progress.first_succession.?;
        const succession = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            succession_id,
        );
        const residual_id = succession.residual.?;
        var residual = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            residual_id,
        );
        try reconstructionParkCancelledResidual(fixture, frame, &residual, residual_id);
        _ = try fixture.service.requestCancel(
            frame,
            "cancel-before-explicit-park",
            fixture.task,
            "Cancel current and retained work",
        );
        _ = try fixture.service.workspaceCommand(
            frame,
            "residual-after-cancel",
            fixture.task,
            .{ .work = .{ .park = .{
                .work = try workspaceRef(frame, .residual, residual_id),
                .execution_revision = residual.execution_revision,
                .control_revision = residual.control_revision + 1,
            } } },
        );
        for (0..32) |_| {
            const progress = try fixture.service.pump(frame);
            try std.testing.expect(progress != .work);
        }
        residual = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            residual_id,
        );
        try std.testing.expectEqual(.parked, residual.schedule);
        try std.testing.expect(!residual.cancellation_applied);
        _ = try fixture.service.requestCancel(
            frame,
            "cancel-after-explicit-park",
            fixture.task,
            "Continue retained cleanup",
        );
        try reconstructionDrainCancelledResidual(fixture, frame, residual_id);
        _ = try fixture.service.exportCheckpoint(
            frame,
            fixture.task,
            try std.fmt.allocPrint(frame, "{s}/cancelled-residual.archive", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        return true;
    }
    return false;
}

fn reconstructionRetiredController(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.scenario == .round_trip and fixture.process == null) {
        const succession_id = fixture.progress.first_succession.?;
        const succession = try reconstructionRecord(
            native.testing.state.ControllerSuccession,
            fixture,
            frame,
            "controller_succession",
            succession_id,
        );
        const residual = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            succession.residual.?,
        );
        var expected: contracts.workspace.Expected = .{
            .work = try workspaceRef(frame, .residual, residual.id),
            .execution_revision = residual.execution_revision,
            .control_revision = residual.control_revision,
        };
        const parked = try fixture.service.workspaceCommand(
            frame,
            "park-retired-controller",
            fixture.task,
            .{ .work = .{ .park = expected } },
        );
        try std.testing.expectEqual(.observed, parked.disposition);
        expected.control_revision += 1;
        const advanced = try fixture.service.workspaceCommand(
            frame,
            "advance-retired-cleanup",
            fixture.task,
            .{ .work = .{ .advance = expected } },
        );
        try std.testing.expectEqual(.observed, advanced.disposition);
        expected.control_revision -= 1;
        const replay = try fixture.service.workspaceCommand(
            frame,
            "park-retired-controller",
            fixture.task,
            .{ .work = .{ .park = expected } },
        );
        var original_observation = (try native.json.parse(
            frame,
            parked.observation_json.bytes,
            .{},
        )).value;
        const repeated_observation = (try native.json.parse(
            frame,
            replay.observation_json.bytes,
            .{},
        )).value;
        try std.testing.expect(repeated_observation.object.get("replayed").?.bool);
        try native.json.put(frame, &original_observation, "replayed", .{ .bool = true });
        try std.testing.expectEqualStrings(
            try native.json.canonical(frame, original_observation),
            try native.json.canonical(frame, repeated_observation),
        );
    }
}

fn reconstructionRejectStaleController(fixture: anytype, frame: std.mem.Allocator) !void {
    if (!fixture.operator) {
        var stale = fixture.progress.first_handoff.?;
        stale.reason = .{ .bytes = "An unadmitted old command" };
        const denied = try fixture.service.workspaceCommand(
            frame,
            "old-controller-command",
            fixture.task,
            .{ .program = .{ .adopt = stale } },
        );
        try std.testing.expectEqual(.rejected, denied.disposition);
        try std.testing.expect(
            std.mem.indexOf(u8, denied.observation_json.bytes, "OperationConflict") != null,
        );
    }
}

fn reconstructionAnswerHeldChild(fixture: anytype, frame: std.mem.Allocator) !void {
    _ = try fixture.service.message(frame, "reconstruction-amendment", fixture.task, .{
        .bytes = "Recheck the exceptional record directly using current facts.",
    });
    const port = (try contracts.decodeOwned(
        native.workspace.Port,
        frame,
        try fixture.namespace.store.object(frame, fixture.child.value.current_port.?, null),
    )).value;
    _ = try fixture.service.workspaceInteract(
        frame,
        "late-child-answer",
        fixture.task,
        .{ .expected = .{
            .work = try workspaceRef(frame, .work, fixture.child_id),
            .execution_revision = fixture.child.value.execution_revision,
            .control_revision = fixture.child.value.control_revision,
        }, .port = try workspaceRef(
            frame,
            .port,
            port.id,
        ), .generation = port.generation, .command = .{
            .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(
                frame,
                .schema,
                port.interface.argument.digest,
            ), .json_text = .{ .bytes = "true" } } },
        } },
    );
}

fn reconstructionRecord(
    comptime T: type,
    fixture: anytype,
    allocator: std.mem.Allocator,
    comptime kind: []const u8,
    id: [32]u8,
) !T {
    const bytes = (try fixture.namespace.store.recordBytes(allocator, kind, id, fixture.task)).?;
    return (try contracts.decodeOwned(T, allocator, bytes)).value;
}

fn reconstructionFinished(fixture: anytype) !void {
    try std.testing.expectEqual(@as(usize, 3), fixture.progress.calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.progress.epochs);
    try std.testing.expectEqual(@as(usize, 2), fixture.progress.cleanups);
    if (fixture.scenario == .residual_outer) try std.testing.expect(
        fixture.progress.outer_cancel and fixture.progress.outer_reply,
    );
    try std.testing.expect(!fixture.progress.held);
    var final_task = try fixture.service.task(fixture.a, fixture.task);
    defer final_task.deinit();
    try std.testing.expect(final_task.value.terminal());
    try std.testing.expectEqual(
        @as(u64, if (fixture.amended_retry) 5 else 3),
        final_task.value.inference_attempts,
    );
    try reconstructionHistoricalResidual(fixture, &final_task);
    try reconstructionHeldRecovery(fixture);
    var completed_child = try fixture.service.workspaceWork(
        fixture.a,
        fixture.task,
        fixture.child_id,
    );
    defer completed_child.deinit();
    try std.testing.expectEqual(.completed, completed_child.value.outcome_kind);
    fixture.stage.* = "export";
    const exported = try fixture.service.exportCheckpoint(
        fixture.scratch,
        fixture.task,
        try std.fmt.allocPrint(
            fixture.scratch,
            "{s}/reconstructed.archive",
            .{fixture.path_buffer.*[0..fixture.length]},
        ),
    );
    try std.testing.expect(exported.bytes > 0);
    try reconstructionHistoryReopen(fixture);
}

fn reconstructionHistoricalResidual(fixture: anytype, final_task: anytype) !void {
    if (fixture.scenario == .residual_history) {
        fixture.stage.* = "residual historical read";
        try std.testing.expect(fixture.progress.history_advanced);
        const residual = (try contracts.decodeOwned(
            native.testing.state.ControllerResidual,
            fixture.scratch,
            (try fixture.namespace.store.recordBytes(
                fixture.scratch,
                "controller_residual",
                fixture.progress.history_residual.?,
                fixture.task,
            )).?,
        )).value;
        try std.testing.expectEqual(.cancelled, residual.outcome_kind);
        const later = native.testing.state.ControllerResidualObservation.from(residual);
        const later_reply = try fixture.service.workspaceCommand(
            fixture.scratch,
            "inspect-terminal-residual",
            fixture.task,
            .{ .work = .{ .inspect = .{
                .work = try workspaceRef(fixture.scratch, .residual, residual.id),
            } } },
        );
        try std.testing.expectEqual(.observed, later_reply.disposition);
        const earlier = try reconstructionPriorResidualRead(fixture, residual);
        const observed = earlier.evidence.read.residual;
        try std.testing.expectEqual(.parked, observed.value.schedule);
        try std.testing.expect(
            observed.value.outcome_kind != .completed and
                observed.value.outcome_kind != .failed and
                observed.value.outcome_kind != .cancelled,
        );
        try std.testing.expect(observed.value.execution_revision < later.execution_revision);
        try std.testing.expect(observed.event_watermark < final_task.value.event_high);
        const occurrence = (try contracts.decodeOwned(
            native.testing.occurrence.Occurrence,
            fixture.scratch,
            (try fixture.namespace.store.recordBytes(
                fixture.scratch,
                "occurrence",
                earlier.id,
                fixture.task,
            )).?,
        )).value;
        try std.testing.expect(occurrence.state == .admitted);
        try fixture.service.validateWorkspace(fixture.scratch, fixture.task);
        try reconstructionRejectResidualTime(
            fixture,
            residual,
            earlier,
            later,
            observed,
            occurrence,
            later_reply,
        );
        try reconstructionRejectCleanupTime(fixture, residual);
    }
}

fn reconstructionHeldRecovery(fixture: anytype) !void {
    if (fixture.progress.held_residual) |id| {
        try reconstructionForeignRecovery(fixture);
        const residual = (try contracts.decodeOwned(
            native.testing.state.ControllerResidual,
            fixture.scratch,
            (try fixture.namespace.store.recordBytes(
                fixture.scratch,
                "controller_residual",
                id,
                fixture.task,
            )).?,
        )).value;
        try reconstructionRejectUnknownAdvance(fixture, id, residual);
        var client: native.client.Client(Reconstruction.Types) = .{ .service = fixture.service };
        var params = native.json.object();
        try native.json.put(
            fixture.scratch,
            &params,
            "task_id",
            native.json.string(
                try fixture.scratch.dupe(u8, &std.fmt.bytesToHex(fixture.task, .lower)),
            ),
        );
        try native.json.put(
            fixture.scratch,
            &params,
            "residual_id",
            native.json.string(try fixture.scratch.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
        );
        const status = try client.call(fixture.scratch, .@"task.status", params);
        const available = status.object.get("recovery").?;
        try std.testing.expectEqual(
            @as(usize, if (fixture.scenario == .recovery_cleanup) 2 else 0),
            available.object.get("mechanisms").?.array.items.len,
        );
        var occurrence_id: [32]u8 = undefined;
        var attempt_id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&occurrence_id, available.object.get("occurrence_id").?.string);
        _ = try std.fmt.hexToBytes(&attempt_id, available.object.get("attempt_id").?.string);
        try std.testing.expectEqualDeep(residual.current_occurrence.?, occurrence_id);
        const recovery = try fixture.service.reconcile(
            fixture.scratch,
            "recover-retired-cleanup",
            fixture.task,
            try native.json.decimal(u64, status.object.get("revision").?),
            occurrence_id,
            attempt_id,
            .rederive,
        );
        try std.testing.expectEqual(.reconciled, recovery.receipt.disposition);
        try reconstructionCleanupRecovery(fixture, id, occurrence_id, attempt_id, recovery);
        var altered = residual;
        altered.control_revision += 1;
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        try fixture.namespace.store.putRecord(
            native.testing.state.ControllerResidual,
            "controller_residual",
            id,
            fixture.task,
            altered,
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspace(fixture.scratch, fixture.task),
        );
        fixture.namespace.store.rollback();
    }
}

fn reconstructionHistoryReopen(fixture: anytype) !void {
    if (fixture.scenario == .residual_history) {
        fixture.stage.* = "residual history reopen";
        try fixture.service.close(fixture.a);
        fixture.service_open.* = false;
        try fixture.namespace.close();
        fixture.namespace_open.* = false;
        fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
        fixture.namespace_open.* = true;
        fixture.service.* = try native.tasks.Service(Reconstruction.Types).init(
            fixture.a,
            fixture.io,
            fixture.namespace,
            fixture.assets,
            fixture.application,
            fixture.handlers.*,
            fixture.profile,
        );
        fixture.service_open.* = true;
        try fixture.service.validateWorkspace(fixture.scratch, fixture.task);
        var reopened = try fixture.service.task(fixture.scratch, fixture.task);
        defer reopened.deinit();
        try std.testing.expect(
            try fixture.service.taskCleanupComplete(fixture.scratch, reopened.value),
        );
        fixture.stage.* = "residual history import";
        try fixture.service.close(fixture.a);
        fixture.service_open.* = false;
        try fixture.namespace.close();
        fixture.namespace_open.* = false;
        var destination_namespace = try native.Namespace.open(
            fixture.a,
            fixture.io,
            try std.fmt.allocPrint(
                fixture.scratch,
                "{s}/history-destination",
                .{fixture.path_buffer.*[0..fixture.length]},
            ),
        );
        defer support.expectCleanup(destination_namespace.close());
        var destination = try native.tasks.Service(Reconstruction.Types).init(
            fixture.a,
            fixture.io,
            &destination_namespace,
            fixture.assets,
            fixture.application,
            fixture.handlers.*,
            fixture.profile,
        );
        defer support.expectCleanup(destination.close(fixture.a));
        _ = try destination.importCheckpoint(
            fixture.scratch,
            "import-residual-history",
            try std.fmt.allocPrint(
                fixture.scratch,
                "{s}/reconstructed.archive",
                .{fixture.path_buffer.*[0..fixture.length]},
            ),
        );
        try destination.validateWorkspace(fixture.scratch, fixture.task);
    }
}

fn reconstructionRegistryOwner(environment: anytype) !void {
    var handlers = try reconstructionRegistry(environment.a.*, environment.scenario.*);
    defer handlers.deinit();
    const contract = try reconstructionContract(environment.scratch.*);
    try reconstructionSourceOwner(.{
        .handlers = &handlers,
        .contract = &contract,
        .environment = &environment,
    });
}

fn reconstructionSourceOwner(registry: anytype) !void {
    const environment = registry.environment.*;
    const a = environment.a.*;
    const scratch = environment.scratch.*;
    const scenario = environment.scenario.*;
    const cleanup_command = environment.cleanup_command.*;
    var source_builder = source.Builder.init(a);
    defer source_builder.deinit();
    const original_source = try reconstructionInitialSource(
        scratch,
        &source_builder,
        scenario,
        cleanup_command,
    );
    var original = try reconstructionBuild(a, original_source, registry.contract.*);
    defer original.deinit();
    const admitted = try data.program_image.Admitted.decode(a, original.image);
    defer admitted.deinit();
    var application = try reconstructionApplication(
        a,
        scratch,
        original_source,
        &original,
        admitted.identity(),
    );
    defer application.deinit();
    const metadata = "{}";
    const manifest = try @import("native_test_support.zig").ownerManifest(
        scratch,
        original.image,
        admitted.identity(),
        metadata,
    );
    application.manifest = (try native.json.parse(scratch, manifest, .{})).value;
    const assets: native.discovery.Assets = .{
        .image = original.image,
        .application = metadata,
        .manifest = manifest,
    };
    var grants: [4]native.registry.Grant = undefined;
    const profile = try reconstructionProfile(
        scratch,
        &grants,
        registry.handlers.*,
        application.image_identity,
    );
    try reconstructionNamespaceOwner(.{
        .original_source = &original_source,
        .application = &application,
        .assets = &assets,
        .profile = &profile,
        .registry = &registry,
    });
}

fn reconstructionNamespaceOwner(source_owner: anytype) !void {
    const environment = source_owner.registry.*.environment.*;
    const a = environment.a.*;
    const io = environment.io.*;
    const scratch = environment.scratch.*;
    const process = environment.process.*;
    const scenario = environment.scenario.*;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = if (process) |p| p.path else try std.fmt.allocPrint(scratch, "{s}/state", .{
        path_buffer[0..length],
    });
    const destination_identity: ?[32]u8 = if (scenario == .model_mobility) identity: {
        var destination = try native.Namespace.open(
            a,
            io,
            try std.fmt.allocPrint(scratch, "{s}/model-destination", .{path_buffer[0..length]}),
        );
        defer support.expectCleanup(destination.close());
        break :identity destination.identity;
    } else null;
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_open = true;
    defer if (namespace_open) support.expectCleanup(namespace.close());
    try reconstructionServiceOwner(.{
        .path_buffer = &path_buffer,
        .length = &length,
        .path = &path,
        .destination_identity = &destination_identity,
        .namespace = &namespace,
        .namespace_open = &namespace_open,
        .source_owner = &source_owner,
    });
}

fn reconstructionServiceOwner(namespace_owner: anytype) !void {
    const environment = namespace_owner.source_owner.*.registry.*.environment.*;
    const registry = namespace_owner.source_owner.*.registry.*;
    const source_owner = namespace_owner.source_owner.*;
    const a = environment.a.*;
    const io = environment.io.*;
    const scratch = environment.scratch.*;
    const process = environment.process.*;
    const scenario = environment.scenario.*;
    const operator_failure = environment.operator_failure.*;
    const operator_unrearmed = environment.operator_unrearmed.*;
    const operator = environment.operator.*;
    const held_cleanup = environment.held_cleanup.*;
    const residual_wait = environment.residual_wait.*;
    const cleanup_command = environment.cleanup_command.*;
    const stage = environment.stage;
    var service = try native.tasks.Service(Reconstruction.Types).init(
        a,
        io,
        &namespace_owner.namespace.*,
        source_owner.assets.*,
        &source_owner.application.*,
        registry.handlers.*,
        source_owner.profile.*,
    );
    var service_open = true;
    defer if (service_open) support.expectCleanup(service.close(a));
    if (process == null and scenario == .round_trip) try reconstructionContractFailures(
        a,
        &service,
    );
    if (process) |process_value| if (process_value.verifying) {
        try reconstructionVerifyProcess(namespace_owner, &service, a, scratch, process);
        return;
    };
    try reconstructionTaskOwner(.{
        .registry = &registry,
        .source_owner = &source_owner,
        .a = &a,
        .io = &io,
        .scratch = &scratch,
        .process = &process,
        .scenario = &scenario,
        .operator_failure = &operator_failure,
        .operator_unrearmed = &operator_unrearmed,
        .operator = &operator,
        .held_cleanup = &held_cleanup,
        .residual_wait = &residual_wait,
        .cleanup_command = &cleanup_command,
        .stage = &stage,
        .service = &service,
        .service_open = &service_open,
        .namespace_owner = &namespace_owner,
    });
}

fn reconstructionWakeResidual(
    fixture: anytype,
    frame: std.mem.Allocator,
    residual: anytype,
    residual_id: [32]u8,
) !void {
    try std.testing.expect(residual.cancellation_applied);
    fixture.stage.* = "parked residual read";
    try reconstructionPumpParkedResidual(fixture, frame);
    const expected: contracts.workspace.Expected = .{
        .work = try workspaceRef(frame, .residual, residual_id),
        .execution_revision = residual.execution_revision,
        .control_revision = residual.control_revision,
    };
    if (fixture.scenario == .residual_wait_park) {
        const parked = try fixture.service.workspaceCommand(
            frame,
            "park-waiting-residual",
            fixture.task,
            .{ .work = .{ .park = expected } },
        );
        try std.testing.expectEqual(.observed, parked.disposition);
    }
    if (fixture.scenario == .residual_wait_complete) {
        fixture.stage.* = "wake residual read after root completion";
        var done = try fixture.service.task(frame, fixture.task);
        defer done.deinit();
        try std.testing.expect(done.value.terminal());
        _ = try fixture.service.requestCancel(
            frame,
            "wake-completed-cleanup",
            fixture.task,
            "Continue the retained read after root completion",
        );
    } else _ = try fixture.service.message(
        frame,
        "wake-cleanup-read",
        fixture.task,
        .{ .bytes = "Wake the retained read under its original binding." },
    );
    try reconstructionResumeParkedResidual(fixture, frame, expected, residual_id);
}

fn reconstructionPumpParkedResidual(fixture: anytype, frame: std.mem.Allocator) !void {
    for (0..@as(usize, if (fixture.scenario == .residual_wait_complete) 128 else 8)) |_| {
        const progress = try fixture.service.pump(frame);
        if (progress == .work) {
            try std.testing.expect(progress.work.entry.declaration.inference);
            if (fixture.scenario == .residual_wait_complete) try fixture.service.acquire(
                frame,
                progress.work,
                try contracts.encodeOwned(Reconstruction.Response, frame, .{ .next = {} }),
            ) else try fixture.service.notSent(frame, progress.work);
        }
        if (fixture.scenario == .residual_wait_complete) {
            var done = try fixture.service.task(frame, fixture.task);
            defer done.deinit();
            if (done.value.terminal()) break;
        }
    }
}

fn reconstructionResumeParkedResidual(
    fixture: anytype,
    frame: std.mem.Allocator,
    expected: contracts.workspace.Expected,
    residual_id: [32]u8,
) !void {
    if (fixture.scenario == .residual_wait_park) {
        for (0..8) |_| try std.testing.expect(try fixture.service.pump(frame) != .work);
        const still = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            residual_id,
        );
        try std.testing.expectEqual(.parked, still.schedule);
        var selected = expected;
        selected.control_revision += 1;
        const advanced = try fixture.service.workspaceCommand(
            frame,
            "resume-parked-read",
            fixture.task,
            .{ .work = .{ .advance = selected } },
        );
        try std.testing.expectEqual(.observed, advanced.disposition);
    }
}

fn reconstructionResidualReplies(
    fixture: anytype,
    frame: std.mem.Allocator,
    residual_id: [32]u8,
) !void {
    var replies = try fixture.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
            "ERE r.task=? AND r.kind='workspace_reply'",
        &.{.{ .blob = &fixture.task }},
    );
    defer replies.deinit();
    var count: usize = 0;
    while (try replies.step() == .row) {
        const observed = (try contracts.decodeOwned(
            native.workspace.ReplyObservation,
            frame,
            try replies.bytes(0),
        )).value;
        const pending = try reconstructionRecord(
            native.testing.occurrence.Occurrence,
            fixture,
            frame,
            "occurrence",
            observed.id,
        );
        if (!std.meta.eql(pending.residual, residual_id)) continue;
        try std.testing.expect(
            pending.state == .admitted and pending.state.admitted == .reply,
        );
        const bound = (try data.invocation.decode(
            data.invocation.Result,
            frame,
            try fixture.namespace.store.acquiredObject(
                frame,
                pending.state.admitted.reply.reply,
                null,
            ),
        )).value;
        const reply = (try contracts.decodeOwned(
            contracts.workspace.Reply,
            frame,
            bound.value,
        )).value;
        try std.testing.expectEqual(
            @as(
                @TypeOf(reply.disposition),
                if (fixture.scenario == .residual_mutation) .rejected else .observed,
            ),
            reply.disposition,
        );
        if (fixture.scenario == .residual_mutation) try std.testing.expect(
            std.mem.indexOf(u8, reply.observation_json.bytes, "Denied") != null,
        );
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

fn reconstructionPumpResidualRead(
    fixture: anytype,
    frame: std.mem.Allocator,
    residual_id: [32]u8,
) !void {
    var woke = !fixture.residual_wait;
    var controller_read_checked = false;
    var completed: usize = 0;
    for (0..128) |_| {
        const residual = try reconstructionRecord(
            native.testing.state.ControllerResidual,
            fixture,
            frame,
            "controller_residual",
            residual_id,
        );
        if (residual.outcome_kind == .cancelled) break;
        if (fixture.scenario == .residual_read and !controller_read_checked) {
            if (residual.current_occurrence) |current_occurrence|
                controller_read_checked = try expectControllerReadBound(
                    fixture.service,
                    frame,
                    fixture.task,
                    current_occurrence,
                );
        }
        if (!woke and residual.schedule == .parked) {
            try reconstructionWakeResidual(fixture, frame, residual, residual_id);
            woke = true;
        }
        const progress = try fixture.service.pump(frame);
        if (progress == .work) {
            if (progress.work.subject_residual != null) {
                try std.testing.expectEqualDeep(
                    residual_id,
                    progress.work.subject_residual.?,
                );
                try fixture.service.acquire(frame, progress.work, &.{});
                completed += 1;
            } else if (fixture.scenario == .residual_wait_complete) try fixture.service.acquire(
                frame,
                progress.work,
                try contracts.encodeOwned(Reconstruction.Response, frame, .{ .next = {} }),
            ) else try fixture.service.notSent(frame, progress.work);
        }
    } else return error.ResidualReadDidNotFinish;
    try std.testing.expectEqual(@as(usize, 1), completed);
    if (fixture.scenario == .residual_read) try std.testing.expect(controller_read_checked);
    try reconstructionResidualReplies(fixture, frame, residual_id);
}

fn reconstructionParkCancelledResidual(
    fixture: anytype,
    frame: std.mem.Allocator,
    residual: *native.testing.state.ControllerResidual,
    residual_id: [32]u8,
) !void {
    if (fixture.operator_unrearmed) {
        const pending = try reconstructionRecord(
            native.testing.occurrence.Occurrence,
            fixture,
            frame,
            "occurrence",
            residual.current_occurrence.?,
        );
        try std.testing.expect(pending.state == .not_sent);
        try std.testing.expect(pending.residual == null);
    }
    _ = try fixture.service.workspaceCommand(
        frame,
        "residual-before-cancel",
        fixture.task,
        .{ .work = .{ .park = .{
            .work = try workspaceRef(frame, .residual, residual_id),
            .execution_revision = residual.execution_revision,
            .control_revision = residual.control_revision,
        } } },
    );
    if (fixture.scenario == .operator_unrearmed) {
        const advanced = try fixture.service.workspaceCommand(
            frame,
            "advance-original-occurrence",
            fixture.task,
            .{ .work = .{ .advance = .{
                .work = try workspaceRef(frame, .residual, residual_id),
                .execution_revision = residual.execution_revision,
                .control_revision = residual.control_revision + 1,
            } } },
        );
        try std.testing.expectEqual(.observed, advanced.disposition);
        residual.control_revision += 1;
    }
}

fn reconstructionDrainCancelledResidual(
    fixture: anytype,
    frame: std.mem.Allocator,
    residual_id: [32]u8,
) !void {
    for (0..128) |_| {
        const progress = try fixture.service.pump(frame);
        if (progress == .work) {
            try std.testing.expectEqualDeep(residual_id, progress.work.subject_residual.?);
            try fixture.service.acquire(frame, progress.work, &.{});
        }
        var stopped = try fixture.service.task(frame, fixture.task);
        defer stopped.deinit();
        if (try fixture.service.taskCleanupComplete(frame, stopped.value)) break;
    } else return error.ResidualDidNotCancel;
}

fn reconstructionPriorResidualRead(
    fixture: anytype,
    residual: anytype,
) !native.workspace.ReplyObservation {
    var retained: ?native.workspace.ReplyObservation = null;
    {
        var query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WH" ++
                "ERE r.task=? AND r.kind='workspace_reply'",
            &.{.{ .blob = &fixture.task }},
        );
        defer query.deinit();
        while (try query.step() == .row) {
            const candidate = (try contracts.decodeOwned(
                native.workspace.ReplyObservation,
                fixture.scratch,
                try query.bytes(0),
            )).value;
            if (candidate.evidence != .read or candidate.evidence.read != .residual) continue;
            if (!std.meta.eql(candidate.evidence.read.residual.value.id, residual.id)) continue;
            try std.testing.expect(retained == null);
            retained = candidate;
        }
    }
    const earlier = retained orelse return error.MissingResidualReadObservation;
    return earlier;
}

fn reconstructionRejectResidualTime(
    fixture: anytype,
    residual: anytype,
    earlier: anytype,
    later: anytype,
    observed: anytype,
    occurrence: anytype,
    later_reply: anytype,
) !void {
    for (0..2) |variant| {
        if (variant == 0) {
            fixture.stage.* = "reject residual time substitution";
        } else {
            fixture.stage.* = "reject coordinated residual publication substitution";
        }
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        var forged = earlier;
        forged.evidence.read.residual.value = later;
        try std.testing.expectEqual(
            observed.event_watermark,
            forged.evidence.read.residual.event_watermark,
        );
        const forged_evidence = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(
                native.workspace.ReplyObservation,
                fixture.scratch,
                forged,
            ),
        );
        try fixture.namespace.store.database.run(
            "UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?",
            &.{ .{ .blob = &forged_evidence.digest }, .{ .blob = &earlier.id } },
        );
        const payload = try contracts.encodeOwned(
            contracts.workspace.Reply,
            fixture.scratch,
            later_reply,
        );
        const bound = try data.invocation.encodeOwned(
            data.invocation.Result,
            fixture.scratch,
            .{ .request_identity = occurrence.request, .value = payload },
        );
        var acquired = occurrence;
        acquired.state.admitted.reply.reply = (try fixture.namespace.store.putObject(
            bound,
        )).digest;
        try fixture.namespace.store.putRecord(
            native.testing.occurrence.Occurrence,
            "occurrence",
            earlier.id,
            fixture.task,
            acquired,
        );
        try reconstructionForgeResidualPublication(fixture, residual, later, observed, variant);
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspace(fixture.scratch, fixture.task),
        );
        fixture.namespace.store.rollback();
        try fixture.service.validateWorkspace(fixture.scratch, fixture.task);
    }
}

fn reconstructionForgeResidualPublication(
    fixture: anytype,
    residual: anytype,
    later: anytype,
    observed: anytype,
    variant: usize,
) !void {
    if (variant == 1) {
        var query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? AND e.seq<=? ORDER BY e.seq DESC",
            &.{
                .{ .blob = &fixture.task },
                .{ .integer = @intCast(observed.event_watermark) },
            },
        );
        defer query.deinit();
        var replaced = false;
        while (try query.step() == .row) {
            var event = (try contracts.decodeOwned(
                native.testing.state.Event,
                fixture.scratch,
                try query.bytes(0),
            )).value;
            const publications = try fixture.scratch.dupe(
                native.testing.state.ResidualPublication,
                event.residual_publications.items,
            );
            for (publications) |*publication| {
                if (!std.meta.eql(publication.value.id, residual.id)) continue;
                publication.value = later;
                publication.occurrence = null;
                replaced = true;
            }
            if (!replaced) continue;
            event.residual_publications.items = publications;
            const rewritten = try fixture.namespace.store.putObject(
                try contracts.encodeOwned(
                    native.testing.state.Event,
                    fixture.scratch,
                    event,
                ),
            );
            try fixture.namespace.store.database.run(
                "UPDATE events SET body=? WHERE task=? AND seq=?",
                &.{
                    .{ .blob = &rewritten.digest },
                    .{ .blob = &fixture.task },
                    .{ .integer = @intCast(event.seq) },
                },
            );
            break;
        }
        try std.testing.expect(replaced);
    }
}

fn reconstructionRejectCleanupTime(fixture: anytype, residual: anytype) !void {
    {
        fixture.stage.* = "reject residual cleanup occurrence time substitution";
        const history = try reconstructionCleanupPublications(fixture, residual);
        const dispatch = history.dispatch;
        const settled = history.settled;
        var forged = dispatch orelse return error.MissingResidualCleanupDispatch;
        const replacement = settled orelse return error.MissingResidualCleanupReply;
        const publications = try fixture.scratch.dupe(
            native.testing.state.ResidualPublication,
            forged.residual_publications.items,
        );
        forged.residual_publications.items = publications;
        for (publications) |*publication| {
            if (!std.meta.eql(publication.value.id, residual.id)) continue;
            try std.testing.expectEqualDeep(
                publication.occurrence.?.id,
                replacement.occurrence.?.id,
            );
            publication.* = replacement;
        }
        try fixture.namespace.store.begin();
        defer fixture.namespace.store.rollback();
        const rewritten = try fixture.namespace.store.putObject(
            try contracts.encodeOwned(native.testing.state.Event, fixture.scratch, forged),
        );
        try fixture.namespace.store.database.run(
            "UPDATE events SET body=? WHERE task=? AND seq=?",
            &.{
                .{ .blob = &rewritten.digest },
                .{ .blob = &fixture.task },
                .{ .integer = @intCast(forged.seq) },
            },
        );
        try std.testing.expectError(
            error.InvalidArchive,
            fixture.service.validateWorkspace(fixture.scratch, fixture.task),
        );
        fixture.namespace.store.rollback();
        try fixture.service.validateWorkspace(fixture.scratch, fixture.task);
    }
}

fn reconstructionCleanupPublications(
    fixture: anytype,
    residual: anytype,
) !struct {
    dispatch: ?native.testing.state.Event,
    settled: ?native.testing.state.ResidualPublication,
} {
    var dispatch: ?native.testing.state.Event = null;
    var settled: ?native.testing.state.ResidualPublication = null;
    var cleanup_occurrence: ?[32]u8 = null;
    {
        var query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? ORDER BY e.seq",
            &.{.{ .blob = &fixture.task }},
        );
        defer query.deinit();
        while (try query.step() == .row) {
            const event = (try contracts.decodeOwned(
                native.testing.state.Event,
                fixture.scratch,
                try query.bytes(0),
            )).value;
            for (event.residual_publications.items) |publication| {
                if (!std.meta.eql(publication.value.id, residual.id)) continue;
                const pending = publication.occurrence orelse continue;
                if (pending.state == .ready) cleanup_occurrence = pending.id;
                if (cleanup_occurrence == null or !std.meta.eql(
                    cleanup_occurrence.?,
                    pending.id,
                )) continue;
                if (pending.state == .dispatching) {
                    try std.testing.expectEqual(.active, publication.value.schedule);
                    try std.testing.expect(dispatch == null);
                    dispatch = event;
                } else if (pending.state == .settled_reply and dispatch != null) {
                    try std.testing.expectEqual(.queued, publication.value.schedule);
                    try std.testing.expect(event.seq > dispatch.?.seq);
                    settled = publication;
                }
            }
        }
    }
    return .{ .dispatch = dispatch, .settled = settled };
}

fn reconstructionForeignRecovery(fixture: anytype) !void {
    for (0..2) |foreign_identity| {
        var foreign_profile = fixture.profile;
        if (foreign_identity == 0) {
            foreign_profile.authority.principal = "foreign";
        } else {
            foreign_profile.authority.tenant = "foreign";
        }
        const head = fixture.namespace.store.head;
        var foreign = try native.tasks.Service(Reconstruction.Types).init(
            fixture.a,
            fixture.io,
            fixture.namespace,
            fixture.assets,
            fixture.application,
            fixture.handlers.*,
            foreign_profile,
        );
        try foreign.close(fixture.a);
        try std.testing.expectEqualDeep(head, fixture.namespace.store.head);
    }
}

fn reconstructionRejectUnknownAdvance(fixture: anytype, id: [32]u8, residual: anytype) !void {
    const expected: contracts.workspace.Expected = .{
        .work = try workspaceRef(fixture.scratch, .residual, id),
        .execution_revision = residual.execution_revision,
        .control_revision = residual.control_revision,
    };
    const refused = try fixture.service.workspaceCommand(
        fixture.scratch,
        "cannot-advance-unknown-cleanup",
        fixture.task,
        .{ .work = .{ .advance = expected } },
    );
    try std.testing.expectEqual(.rejected, refused.disposition);
    try std.testing.expect(
        std.mem.indexOf(u8, refused.observation_json.bytes, "UnsettledOccurrence") != null,
    );
}

fn reconstructionCleanupRecovery(
    fixture: anytype,
    id: [32]u8,
    occurrence_id: [32]u8,
    attempt_id: [32]u8,
    recovery: anytype,
) !void {
    if (fixture.scenario == .recovery_cleanup) {
        try reconstructionCancelQueuedRecovery(fixture, recovery);
        var current = try fixture.service.task(fixture.scratch, fixture.task);
        defer current.deinit();
        try reconstructionCancelRunningRecovery(fixture, current, occurrence_id, attempt_id);
        current.deinit();
        current = try fixture.service.task(fixture.scratch, fixture.task);
        const pending = try fixture.service.reconcile(
            fixture.scratch,
            "pending-recovery-mobility",
            fixture.task,
            current.value.revision,
            occurrence_id,
            attempt_id,
            .rederive,
        );
        try reconstructionPendingRecoveryMobility(fixture, pending);
        current.deinit();
        current = try fixture.service.task(fixture.scratch, fixture.task);
        try reconstructionLookupUnsentCleanup(fixture, current, occurrence_id, attempt_id);
        try reconstructionRearmUnsentCleanup(fixture, id);
        var retried_cleanup = false;
        for (0..32) |_| {
            const progress = try fixture.service.pump(fixture.scratch);
            if (progress == .work) {
                try std.testing.expect(
                    progress.work.recovery == null and progress.work.cleanup,
                );
                if (!retried_cleanup) {
                    try fixture.service.notSent(fixture.scratch, progress.work);
                    for (0..8) |_| try std.testing.expect(
                        try fixture.service.pump(fixture.scratch) == .idle,
                    );
                    _ = try fixture.service.requestCancel(
                        fixture.scratch,
                        "fresh-cancel-unsent-cleanup",
                        fixture.task,
                        "Explicitly retry known-unsent cleanup",
                    );
                    retried_cleanup = true;
                } else {
                    try reconstructionRederiveCleanup(fixture, id, progress);
                }
            }
            var parent = try fixture.service.task(fixture.scratch, fixture.task);
            defer parent.deinit();
            if (try fixture.service.taskCleanupComplete(fixture.scratch, parent.value)) break;
        } else return error.RecoveredCleanupDidNotFinish;
    }
}

fn reconstructionCancelQueuedRecovery(fixture: anytype, recovery: anytype) !void {
    _ = try fixture.service.requestCancel(
        fixture.scratch,
        "cancel-queued-recovery",
        fixture.task,
        "Stop newly admitted recovery",
    );
    var interrupted = try fixture.service.reconciliation(
        fixture.scratch,
        fixture.task,
        recovery.receipt.reconciliation.?,
    );
    defer interrupted.deinit();
    try std.testing.expect(
        interrupted.value.outcome == .unresolved and
            interrupted.value.outcome.unresolved == .unavailable,
    );
    for (0..8) |_| try std.testing.expect(
        try fixture.service.pump(fixture.scratch) != .work,
    );
}

fn reconstructionCancelRunningRecovery(
    fixture: anytype,
    current: anytype,
    occurrence_id: [32]u8,
    attempt_id: [32]u8,
) !void {
    _ = try fixture.service.reconcile(
        fixture.scratch,
        "recovery-after-earlier-cancel",
        fixture.task,
        current.value.revision,
        occurrence_id,
        attempt_id,
        .rederive,
    );
    const running = blk: {
        for (0..16) |_| {
            const progress = try fixture.service.pump(fixture.scratch);
            if (progress == .work) break :blk progress.work;
        }
        return error.RecoveryDidNotStart;
    };
    try std.testing.expect(running.recovery != null and running.cleanup);
    try std.testing.expect(!try fixture.service.shouldCancelWork(running));
    _ = try fixture.service.requestCancel(
        fixture.scratch,
        "cancel-running-recovery",
        fixture.task,
        "Interrupt recovery computation",
    );
    try std.testing.expect(try fixture.service.shouldCancelWork(running));
    try fixture.service.notSent(fixture.scratch, running);
}

fn reconstructionPendingRecoveryMobility(fixture: anytype, pending: anytype) !void {
    const archive_path = try std.fmt.allocPrint(
        fixture.scratch,
        "{s}/pending-residual-recovery.archive",
        .{fixture.path_buffer.*[0..fixture.length]},
    );
    _ = try fixture.service.exportCheckpoint(fixture.scratch, fixture.task, archive_path);
    try fixture.service.close(fixture.a);
    fixture.service_open.* = false;
    try fixture.namespace.close();
    fixture.namespace_open.* = false;
    try reconstructionImportPendingRecovery(fixture, pending, archive_path);
    fixture.namespace.* = try native.Namespace.open(fixture.a, fixture.io, fixture.path);
    fixture.namespace_open.* = true;
    var bootstrap = fixture.profile;
    bootstrap.bytes = "bootstrap-profile";
    fixture.service.* = try native.tasks.Service(Reconstruction.Types).init(
        fixture.a,
        fixture.io,
        fixture.namespace,
        fixture.assets,
        fixture.application,
        fixture.handlers.*,
        bootstrap,
    );
    fixture.service_open.* = true;
    var reopened = try fixture.service.reconciliation(
        fixture.scratch,
        fixture.task,
        pending.receipt.reconciliation.?,
    );
    defer reopened.deinit();
    try std.testing.expect(
        reopened.value.outcome == .unresolved and reopened.value.outcome.unresolved == .interrupted,
    );
    try std.testing.expect(try fixture.service.pump(fixture.scratch) == .idle);
    fixture.service.profile = fixture.profile;
}

fn reconstructionImportPendingRecovery(
    fixture: anytype,
    pending: anytype,
    archive_path: []const u8,
) !void {
    {
        var destination_namespace = try native.Namespace.open(
            fixture.a,
            fixture.io,
            try std.fmt.allocPrint(fixture.scratch, "{s}/recovery-destination", .{
                fixture.path_buffer.*[0..fixture.length],
            }),
        );
        defer support.expectCleanup(destination_namespace.close());
        var destination = try native.tasks.Service(Reconstruction.Types).init(
            fixture.a,
            fixture.io,
            &destination_namespace,
            fixture.assets,
            fixture.application,
            fixture.handlers.*,
            fixture.profile,
        );
        defer support.expectCleanup(destination.close(fixture.a));
        _ = try destination.importCheckpoint(
            fixture.scratch,
            "import-pending-cleanup",
            archive_path,
        );
        var imported = try destination.reconciliation(
            fixture.scratch,
            fixture.task,
            pending.receipt.reconciliation.?,
        );
        defer imported.deinit();
        try std.testing.expect(
            imported.value.outcome == .unresolved and
                imported.value.outcome.unresolved == .interrupted,
        );
        try std.testing.expect(try destination.pump(fixture.scratch) == .idle);
        try std.testing.expectError(
            error.CustodyNotLocal,
            destination.requestCancel(
                fixture.scratch,
                "cancel-imported-recovery",
                fixture.task,
                "Keep original unknown delivery",
            ),
        );
        for (0..8) |_| try std.testing.expect(
            try destination.pump(fixture.scratch) != .work,
        );
    }
}

fn reconstructionLookupUnsentCleanup(
    fixture: anytype,
    current: anytype,
    occurrence_id: [32]u8,
    attempt_id: [32]u8,
) !void {
    _ = try fixture.service.reconcile(
        fixture.scratch,
        "lookup-unsent-cleanup",
        fixture.task,
        current.value.revision,
        occurrence_id,
        attempt_id,
        .lookup,
    );
    const lookup = blk: {
        for (0..16) |_| {
            const progress = try fixture.service.pump(fixture.scratch);
            if (progress == .work) break :blk progress.work;
        }
        return error.LookupDidNotStart;
    };
    var request = try data.invocation.decode(
        data.invocation.Request,
        fixture.scratch,
        lookup.request,
    );
    defer request.deinit();
    try fixture.service.acquire(
        fixture.scratch,
        lookup,
        try std.mem.concat(
            fixture.scratch,
            u8,
            &.{ &attempt_id, &request.value.request_identity },
        ),
    );
    for (0..8) |_| try std.testing.expect(
        try fixture.service.pump(fixture.scratch) == .idle,
    );
}

fn reconstructionRearmUnsentCleanup(fixture: anytype, id: [32]u8) !void {
    const stopped = (try contracts.decodeOwned(
        native.testing.state.ControllerResidual,
        fixture.scratch,
        (try fixture.namespace.store.recordBytes(
            fixture.scratch,
            "controller_residual",
            id,
            fixture.task,
        )).?,
    )).value;
    try std.testing.expectEqual(.parked, stopped.schedule);
    for (fixture.service.runnable.items) |queued| try std.testing.expect(
        !std.meta.eql(queued.residual, id),
    );
    const advanced = try fixture.service.workspaceCommand(
        fixture.scratch,
        "rearm-known-unsent-cleanup",
        fixture.task,
        .{ .work = .{ .advance = .{
            .work = try workspaceRef(fixture.scratch, .residual, id),
            .execution_revision = stopped.execution_revision,
            .control_revision = stopped.control_revision,
        } } },
    );
    try std.testing.expectEqual(.observed, advanced.disposition);
}

fn reconstructionRederiveCleanup(fixture: anytype, id: [32]u8, progress: anytype) !void {
    fixture.stage.* = "rederive retried residual cleanup";
    try fixture.service.unknown(fixture.scratch, progress.work);
    var unknown = try fixture.service.task(fixture.scratch, fixture.task);
    defer unknown.deinit();
    const admitted_recovery = try fixture.service.reconcile(
        fixture.scratch,
        "rederive-retried-cleanup",
        fixture.task,
        unknown.value.revision,
        progress.work.occurrence,
        progress.work.attempt,
        .rederive,
    );
    const computation = blk: {
        for (0..16) |_| {
            const next = try fixture.service.pump(fixture.scratch);
            if (next == .work) break :blk next.work;
        }
        return error.RetriedCleanupRecoveryDidNotStart;
    };
    try std.testing.expect(computation.recovery != null and computation.cleanup);
    const worker = try native.testing.Worker.init(fixture.a, fixture.io);
    defer support.expectCleanup(worker.deinit(fixture.a));
    try worker.start(computation, fixture.profile.authority, null);
    while (!worker.finished()) try fixture.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    defer support.expectCleanup(worker.release());
    try fixture.service.completeWork(fixture.scratch, computation, worker.result.?);
    var recovered = try fixture.service.reconciliation(
        fixture.scratch,
        fixture.task,
        admitted_recovery.receipt.reconciliation.?,
    );
    defer recovered.deinit();
    try std.testing.expect(recovered.value.outcome == .reply_settled);
    try std.testing.expectEqual(.rederived, recovered.value.provenance);
    const previous = (try contracts.decodeOwned(
        native.testing.state.Reconciliation,
        fixture.scratch,
        try fixture.namespace.store.object(
            fixture.scratch,
            recovered.value.previous.?,
            null,
        ),
    )).value;
    try std.testing.expect(previous.outcome == .pending);
    try fixture.service.validateWorkspace(fixture.scratch, fixture.task);
    try reconstructionRejectRecoveryCapture(fixture, id, progress, admitted_recovery);
}

fn reconstructionRejectRecoveryCapture(
    fixture: anytype,
    id: [32]u8,
    progress: anytype,
    admitted_recovery: anytype,
) !void {
    fixture.stage.* = "reject invented residual recovery capture";
    try fixture.namespace.store.begin();
    defer fixture.namespace.store.rollback();
    const replaced = try reconstructionForgeRecoveryCapture(
        fixture,
        id,
        progress,
        admitted_recovery,
    );
    try std.testing.expect(replaced);
    try std.testing.expectError(
        error.InvalidArchive,
        fixture.service.validateWorkspace(fixture.scratch, fixture.task),
    );
    fixture.namespace.store.rollback();
    try fixture.service.validateWorkspace(fixture.scratch, fixture.task);
}

fn reconstructionForgeRecoveryCapture(
    fixture: anytype,
    id: [32]u8,
    progress: anytype,
    admitted_recovery: anytype,
) !bool {
    var replaced = false;
    {
        var query = try fixture.namespace.store.database.prepare(
            "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHE" ++
                "RE e.task=? ORDER BY e.seq",
            &.{.{ .blob = &fixture.task }},
        );
        defer query.deinit();
        while (try query.step() == .row) {
            var event = (try contracts.decodeOwned(
                native.testing.state.Event,
                fixture.scratch,
                try query.bytes(0),
            )).value;
            if (event.revision != admitted_recovery.receipt.revision) continue;
            const publications = try fixture.scratch.dupe(
                native.testing.state.ResidualPublication,
                event.residual_publications.items,
            );
            replaced = try reconstructionCapturedPublications(publications, id, progress);
            if (!replaced) continue;
            event.residual_publications.items = publications;
            const forged = try fixture.namespace.store.putObject(
                try contracts.encodeOwned(
                    native.testing.state.Event,
                    fixture.scratch,
                    event,
                ),
            );
            try fixture.namespace.store.database.run(
                "UPDATE events SET body=? WHERE task=? AND seq=?",
                &.{
                    .{ .blob = &forged.digest },
                    .{ .blob = &fixture.task },
                    .{ .integer = @intCast(event.seq) },
                },
            );
            break;
        }
    }
    return replaced;
}

fn reconstructionCapturedPublications(
    publications: []native.testing.state.ResidualPublication,
    id: [32]u8,
    progress: anytype,
) !bool {
    var replaced = false;
    for (publications) |*publication| {
        if (!std.meta.eql(publication.value.id, id)) continue;
        const pending_occurrence = publication.occurrence orelse continue;
        try std.testing.expectEqualDeep(progress.work.occurrence, pending_occurrence.id);
        try std.testing.expect(pending_occurrence.state == .unknown);
        try std.testing.expectEqualDeep(
            progress.work.attempt,
            pending_occurrence.state.unknown.id,
        );
        publication.occurrence.?.state = .{ .captured = .{ .id = progress.work.attempt } };
        replaced = true;
    }
    return replaced;
}

fn reconstructionVerifyProcess(
    namespace_owner: anytype,
    service: anytype,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    process: anytype,
) !void {
    if (process) |p| if (p.verifying) {
        try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
        var current = try service.task(scratch, p.task);
        defer current.deinit();
        try std.testing.expectEqual(@as(u64, 1), current.value.inference_attempts);
        const before = std.mem.eql(u8, p.phase, "controller-ready") or
            std.mem.eql(u8, p.phase, "controller-commit");
        try std.testing.expectEqual(@as(u64, if (before) 0 else 1), current.value.controller_epoch);
        const operation_value = (try contracts.decodeOwned(
            native.testing.state.ControllerSuccession,
            scratch,
            (try namespace_owner.namespace.*.store.recordBytes(
                scratch,
                "controller_succession",
                p.operation,
                p.task,
            )).?,
        )).value;
        try std.testing.expectEqual(
            @as(@TypeOf(operation_value.phase), if (before) .ready else .activated),
            operation_value.phase,
        );
        if (before) {
            _ = try service.resumeTask(
                scratch,
                "reconstruction-crash-resume",
                p.task,
                current.value.revision,
            );
            for (0..32) |_| {
                _ = try service.pump(scratch);
                var next = try service.task(scratch, p.task);
                defer next.deinit();
                if (next.value.controller_epoch == 1) break;
            } else return error.ActivationDidNotResume;
        }
        try reconstructionVerifyActivatedProcess(
            namespace_owner,
            service,
            a,
            scratch,
            p,
            operation_value,
        );
        return;
    };
}

fn reconstructionVerifyActivatedProcess(
    namespace_owner: anytype,
    service: anytype,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    p: anytype,
    operation_value: anytype,
) !void {
    var final = try service.task(scratch, p.task);
    defer final.deinit();
    try std.testing.expectEqual(@as(u64, 1), final.value.controller_epoch);
    try std.testing.expectEqual(@as(u64, 1), final.value.inference_attempts);
    var indexed_builder = source.Builder.init(a);
    defer indexed_builder.deinit();
    const indexed = try native.source_records.encode(
        scratch,
        try Reconstruction.controller(&indexed_builder, true, false),
    );
    try reconstructionSource(
        service,
        scratch,
        p.task,
        1,
        try workspaceRef(scratch, .program, operation_value.successor.?),
        indexed,
    );
    const command_bytes = try namespace_owner.namespace.*.store.object(
        scratch,
        operation_value.command,
        null,
    );
    const command = (try contracts.decodeOwned(
        contracts.workspace.Adoption,
        scratch,
        command_bytes,
    )).value;
    const replay = try service.workspaceCommand(
        scratch,
        "crash-adoption-replay",
        p.task,
        .{ .program = .{ .adopt = command } },
    );
    try std.testing.expectEqual(.observed, replay.disposition);
    _ = try service.exportCheckpoint(
        scratch,
        p.task,
        try std.fmt.allocPrint(
            scratch,
            "{s}/restored.archive",
            .{namespace_owner.path_buffer.*[0..namespace_owner.length.*]},
        ),
    );
}

fn reconstructionPrograms(
    service: anytype,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    scenario: ReconstructionCase,
    operator_failure: bool,
    task: [16]u8,
    programs: *[3]contracts.workspace.Ref,
    indexed_source: *[]const u8,
) !void {
    for (programs, 0..) |*out, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const variant: @typeInfo(
            @TypeOf(Reconstruction.converter),
        ).@"fn".param_types[2].? =
            if (i == 1 and
            (scenario == .conversion_failure or
                operator_failure)) .fail else if (i == 1 and
            (scenario == .conversion_interrupt or
                scenario == .cancellation or
                scenario == .operator_cancel)) .diverge else .valid;
        const module = if (i == 0) try Reconstruction.controller(
            &b,
            true,
            false,
        ) else try Reconstruction.converter(
            &b,
            i == 1 and scenario != .conversion_schema,
            variant,
        );
        const text = try native.source_records.encode(scratch, module);
        if (i == 0) indexed_source.* = text;
        const built = try service.workspaceCommand(
            scratch,
            try std.fmt.allocPrint(scratch, "reconstruction-build-{d}", .{i}),
            task,
            .{ .program = .{ .build = .{
                .source = .{ .json_text = .{ .bytes = text } },
                .source_kind = .source_records,
                .exposures = .{ .items = &.{} },
                .role = if (i == 0) .controller else .computation,
            } } },
        );
        if (built.disposition != .observed) std.debug.print("fixture build {d}: {s}\n", .{
            i,
            built.observation_json.bytes,
        });
        try std.testing.expectEqual(.observed, built.disposition);
        out.* = built.program.?;
    }
}

fn reconstructionRejectInitialBinding(
    service: anytype,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    process: anytype,
    scenario: ReconstructionCase,
    namespace_owner: anytype,
    task: [16]u8,
    programs: anytype,
    initial_binding: anytype,
    a_ref: contracts.workspace.Ref,
) !void {
    if (process == null and scenario == .round_trip) {
        var candidate = try service.workspaceProgram(
            scratch,
            task,
            try nativeIdentity(programs[0]),
        );
        defer candidate.deinit();
        var forged = initial_binding;
        forged.program = candidate.value.artifact.digest;
        forged.image = candidate.value.description.image;
        var image = try data.program_image.decode(
            a,
            try namespace_owner.namespace.*.store.object(scratch, forged.image, null),
        );
        defer image.deinit();
        forged.program_identity = image.identity;
        try namespace_owner.namespace.*.store.begin();
        defer namespace_owner.namespace.*.store.rollback();
        try namespace_owner.namespace.*.store.putRecord(
            native.testing.state.ControllerBinding,
            "controller_binding",
            forged.id,
            task,
            forged,
        );
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspace(scratch, task));
        namespace_owner.namespace.*.store.rollback();
        var parent = try service.task(scratch, task);
        defer parent.deinit();
        var missing = parent.value;
        missing.controller = null;
        missing.revision += 1;
        try namespace_owner.namespace.*.store.begin();
        try namespace_owner.namespace.*.store.putTask(missing, parent.value.revision);
        try std.testing.expectError(
            error.IncompatibleProfile,
            service.validateWorkspace(scratch, task),
        );
        namespace_owner.namespace.*.store.rollback();
        try reconstructionTrials(service, scratch, task, a_ref, programs[0], programs[1]);
    }
}

fn reconstructionStartChild(
    service: anytype,
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    task: [16]u8,
) ![32]u8 {
    var child_builder = source.Builder.init(a);
    defer child_builder.deinit();
    const child_source = try native.source_records.encode(
        scratch,
        try @import("workspace_sources.zig").binaryQuestion(&child_builder),
    );
    const built_child = try service.workspaceCommand(
        scratch,
        "held-child-build",
        task,
        .{ .program = .{ .build = .{ .source = .{ .json_text = .{
            .bytes = child_source,
        } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{
            .effect = 0,
            .class = .input,
        }} } } } },
    );
    try std.testing.expectEqual(.observed, built_child.disposition);
    const child_id = (try service.workspaceStart(scratch, "held-child", task, try nativeIdentity(
        built_child.program.?,
    ), &.{}, .{ .stop = .terminal, .continuation = .owner_scheduled })).receipt.workspace.?;
    return child_id;
}

fn reconstructionTaskOwner(service_owner: anytype) !void {
    if (service_owner.process.* == null and service_owner.scenario.* == .round_trip) {
        service_owner.stage.*.* = "controller runtime action";
        try reconstructionRuntimeAction(&service_owner.service.*, service_owner.scratch.*);
    }
    service_owner.stage.*.* = "submit";
    const task = (try service_owner.service.*.submit(
        service_owner.scratch.*,
        "reconstruction-task",
        .{ .items = if (service_owner.scenario.* == .invalid_offer) &.{4} else &.{ 2, 3, 107, 5 } },
    )).receipt.task;
    var initial = try service_owner.service.*.task(service_owner.a.*, task);
    defer initial.deinit();
    const initial_binding = (try contracts.decodeOwned(
        native.testing.state.ControllerBinding,
        service_owner.scratch.*,
        (try service_owner.namespace_owner.*.namespace.*.store.recordBytes(
            service_owner.scratch.*,
            "controller_binding",
            initial.value.controller.?,
            task,
        )).?,
    )).value;
    const a_ref = try workspaceRef(service_owner.scratch.*, .program, initial_binding.program);
    try reconstructionSource(
        &service_owner.service.*,
        service_owner.scratch.*,
        task,
        0,
        a_ref,
        service_owner.source_owner.*.original_source.*,
    );
    try reconstructionProgramsOwner(.{
        .task = &task,
        .initial = &initial,
        .initial_binding = &initial_binding,
        .a_ref = &a_ref,
        .service_owner = &service_owner,
    });
}

fn reconstructionProgramsOwner(task_owner: anytype) !void {
    const service_owner = task_owner.service_owner.*;

    service_owner.stage.*.* = "build";
    var programs: [3]contracts.workspace.Ref = undefined;
    var indexed_source: []const u8 = undefined;
    try reconstructionPrograms(
        &service_owner.service.*,
        service_owner.a.*,
        service_owner.scratch.*,
        service_owner.scenario.*,
        service_owner.operator_failure.*,
        task_owner.task.*,
        &programs,
        &indexed_source,
    );
    try reconstructionRejectInitialBinding(
        &service_owner.service.*,
        service_owner.a.*,
        service_owner.scratch.*,
        service_owner.process.*,
        service_owner.scenario.*,
        service_owner.namespace_owner.*,
        task_owner.task.*,
        &programs,
        task_owner.initial_binding.*,
        task_owner.a_ref.*,
    );
    service_owner.stage.*.* = "child";
    const child_id = try reconstructionStartChild(
        &service_owner.service.*,
        service_owner.a.*,
        service_owner.scratch.*,
        task_owner.task.*,
    );
    var child = try service_owner.service.*.workspaceWork(
        service_owner.a.*,
        task_owner.task.*,
        child_id,
    );
    defer child.deinit();
    try std.testing.expect(child.value.current_port != null);
    try reconstructionPlacementOwner(.{
        .programs = &programs,
        .indexed_source = &indexed_source,
        .child_id = &child_id,
        .child = &child,
        .task_owner = &task_owner,
    });
}

fn reconstructionPlacementOwner(programs_owner: anytype) !void {
    const task_owner = programs_owner.task_owner.*;
    const service_owner = task_owner.service_owner.*;
    const source_owner = service_owner.source_owner.*;
    const namespace_owner = service_owner.namespace_owner.*;
    const scenario = service_owner.scenario.*;
    const scratch = service_owner.scratch.*;

    const placement_key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(71));
    var disclosure: u8 = 0;
    const placement_peer: native.placement.Peer = .{
        .name = "unused-destination",
        .site = .{
            .key = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(
                @splat(72),
            )).public_key.toBytes(),
            .namespace = @splat(73),
        },
        .native_build = source_owner.profile.*.runtime_identity,
        .compatibility = try service_owner.service.*.placementCompatibility(
            scratch,
            .{ .task = task_owner.task.* },
        ),
        .resource_binding = try source_owner.profile.*.resourceIdentity(
            scratch,
            source_owner.application.*.image_identity,
        ),
        .disclosure_policy = @splat(74),
        .context = &disclosure,
        .disclose = struct {
            fn check(
                _: *anyopaque,
                _: native.placement.Subject,
                _: []const native.testing.state.Reference,
            ) !void {}
        }.check,
        .channel = if (scenario == .late_placement or scenario == .conversion_interrupt) .{
            .argv = &.{"/usr/bin/false"},
            .remote_name = "source",
        } else null,
    };
    const transport_directory = if (scenario == .late_placement or
        scenario == .conversion_interrupt)
        try std.fmt.allocPrint(
            scratch,
            "{s}/transport",
            .{namespace_owner.path_buffer.*[0..namespace_owner.length.*]},
        )
    else
        null;
    if (transport_directory) |directory| try std.Io.Dir.cwd().createDir(
        service_owner.io.*,
        directory,
        .fromMode(0o700),
    );
    const placement: native.placement.Configuration = .{
        .signing_key = placement_key,
        .peers = &.{placement_peer},
        .transport_directory = transport_directory,
    };
    if (service_owner.process.* == null and
        (scenario == .round_trip or
            scenario == .residual_custody or
            scenario == .conversion_interrupt or
            service_owner.operator.*))
        service_owner.service.*.profile.placement = &placement;
    try reconstructionExecutionOwner(.{
        .placement_peer = &placement_peer,
        .placement = &placement,
        .programs_owner = &programs_owner,
    });
}

fn reconstructionExecutionOwner(placement_owner: anytype) !void {
    const programs_owner = placement_owner.programs_owner.*;
    const task_owner = programs_owner.task_owner.*;
    const service_owner = task_owner.service_owner.*;
    const source_owner = service_owner.source_owner.*;
    const namespace_owner = service_owner.namespace_owner.*;

    var progress: ReconstructionProgress = .{ .last_event = task_owner.initial.*.value.event_high };
    const amended_retry = service_owner.process.* == null and
        service_owner.scenario.* == .round_trip;
    const amended = amended_retry or service_owner.operator.*;
    service_owner.stage.*.* = "execution";
    const fixture = .{
        .progress = &progress,
        .operator_failure = service_owner.operator_failure.*,
        .operator_unrearmed = service_owner.operator_unrearmed.*,
        .operator = service_owner.operator.*,
        .held_cleanup = service_owner.held_cleanup.*,
        .residual_wait = service_owner.residual_wait.*,
        .cleanup_command = service_owner.cleanup_command.*,
        .stage = &service_owner.stage.*.*,
        .a = service_owner.a.*,
        .io = service_owner.io.*,
        .scratch = service_owner.scratch.*,
        .handlers = &service_owner.registry.*.handlers.*,
        .original_source = source_owner.original_source.*,
        .application = &source_owner.application.*,
        .assets = source_owner.assets.*,
        .profile = source_owner.profile.*,
        .path_buffer = &namespace_owner.path_buffer.*,
        .length = namespace_owner.length.*,
        .path = namespace_owner.path.*,
        .destination_identity = namespace_owner.destination_identity.*,
        .namespace = &namespace_owner.namespace.*,
        .namespace_open = &namespace_owner.namespace_open.*,
        .service = &service_owner.service.*,
        .service_open = &service_owner.service_open.*,
        .task = task_owner.task.*,
        .initial = &task_owner.initial.*,
        .initial_binding = task_owner.initial_binding.*,
        .a_ref = task_owner.a_ref.*,
        .programs = &programs_owner.programs.*,
        .indexed_source = &programs_owner.indexed_source.*,
        .child_id = programs_owner.child_id.*,
        .child = &programs_owner.child.*,
        .placement_peer = &placement_owner.placement_peer.*,
        .placement = &placement_owner.placement.*,
        .amended_retry = amended_retry,
        .amended = amended,
        .process = service_owner.process.*,
        .scenario = service_owner.scenario.*,
    };
    if (try reconstructionExecution(fixture)) return;
    try reconstructionFinished(fixture);
}

fn reconstructionOuterResidual(fixture: anytype, frame: std.mem.Allocator) !void {
    if (fixture.scenario == .residual_outer) if (fixture.service.active) |active| {
        if (active.subject == .residual) if (active.root_control) |bytes| {
            var control = try contracts.decodeOwned(data.invocation.Control, frame, bytes);
            defer control.deinit();
            const snapshot = (control.value == .cancel and
                !fixture.progress.outer_cancel) or
                (control.value == .reply and
                    !fixture.progress.outer_reply);
            if (snapshot) {
                _ = try fixture.service.placementCut(frame, .{ .task = fixture.task });
                const id = active.subject.residual;
                const residual = try reconstructionRecord(
                    native.testing.state.ControllerResidual,
                    fixture,
                    frame,
                    "controller_residual",
                    id,
                );
                try std.testing.expect(residual.outer_operation != null);
                const expected: contracts.workspace.Expected = .{
                    .work = try workspaceRef(frame, .residual, id),
                    .execution_revision = residual.execution_revision,
                    .control_revision = residual.control_revision,
                };
                const parked = try fixture.service.workspaceCommand(
                    frame,
                    try std.fmt.allocPrint(frame, "outer-park-{s}", .{
                        @tagName(control.value),
                    }),
                    fixture.task,
                    .{ .work = .{ .park = expected } },
                );
                try std.testing.expectEqual(.observed, parked.disposition);
                var next = expected;
                next.control_revision += 1;
                const resumed = try fixture.service.workspaceCommand(
                    frame,
                    try std.fmt.allocPrint(frame, "outer-advance-{s}", .{
                        @tagName(control.value),
                    }),
                    fixture.task,
                    .{ .work = .{ .advance = next } },
                );
                try std.testing.expectEqual(.observed, resumed.disposition);
                if (control.value == .cancel) {
                    fixture.progress.outer_cancel = true;
                } else {
                    fixture.progress.outer_reply = true;
                }
            }
        };
    };
}
