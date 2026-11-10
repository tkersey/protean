const std = @import("std");
const native = @import("protean_native");
const C = @import("protean_contracts");
const wc = C.workspace;
const Json = native.json;
const types = @import("application_types");
const Service = native.tasks.Service(types);
pub const Options = struct {
    delegated: bool = false,
    reject_action: bool = false,
    value: ?wc.Ref = null,
    packet: []const u8 = "Native delegated fixture packet.",
};
const Question = struct { expected: wc.Expected, port: wc.Ref, generation: u64 };

fn command(
    service: anytype,
    a: std.mem.Allocator,
    task: [16]u8,
    name: []const u8,
    operation: wc.Command,
) !Json.Value {
    const reply = try service.workspaceCommand(a, name, task, operation);
    if (reply.disposition == .rejected) {
        std.debug.print("{s}: {s}\n", .{ name, reply.observation_json.bytes });
        return error.RecurrenceFixtureRejected;
    }
    return (try Json.parse(a, reply.observation_json.bytes, .{})).value;
}

fn reference(a: std.mem.Allocator, observed: Json.Value, name: []const u8) !wc.Ref {
    return native.values.fromJson(
        wc.Ref,
        a,
        Json.get(observed, name) orelse return error.MissingFixtureReference,
    );
}

fn complete(service: anytype, a: std.mem.Allocator, task: [16]u8, work: wc.Ref) !wc.Ref {
    const id = try native.client.identifier(32, Json.string(work.id.bytes));
    for (0..128) |turn| {
        var current = try service.workspaceWork(a, task, id);
        defer current.deinit();
        if (current.value.outcome_kind == .completed) return .{
            .kind = .value,
            .id = .{ .bytes = try a.dupe(
                u8,
                &std.fmt.bytesToHex(current.value.result_value.?.digest, .lower),
            ) },
        };
        if (current.value.terminal()) return error.RecurrenceFixtureWorkFailed;
        const operation = try std.fmt.allocPrint(a, "recurrence-fixture-pump-{d}", .{turn});
        _ = try service.workspacePump(a, operation, task, .{
            .expected = .{
                .work = work,
                .execution_revision = current.value.execution_revision,
                .control_revision = current.value.control_revision,
            },
        });
    }
    return error.RecurrenceFixtureWorkIncomplete;
}

fn next(
    service: *Service,
    worker: *native.testing.Worker,
    a: std.mem.Allocator,
) !native.tasks.Work {
    for (0..16384) |_| {
        const step = try service.pump(a);
        if (step != .work) continue;
        if (step.work.entry.declaration.inference) return step.work;
        try worker.start(step.work, service.profile.authority, service.profile.environment);
        for (0..30_000) |_| {
            if (worker.finished()) break;
            try service.io.sleep(.fromMilliseconds(1), .awake);
        }
        const timed_out = !worker.finished();
        if (timed_out) worker.cancel();
        try worker.join();
        defer worker.release() catch |err| std.debug.panic("fixture worker: {t}", .{err});
        if (timed_out) return error.RecurrenceFixtureWorkerTimeout;
        try service.completeWork(a, step.work, worker.result.?);
    }
    return error.RecurrenceFixtureInferenceMissing;
}

fn acquire(
    service: *Service,
    a: std.mem.Allocator,
    pending: native.tasks.Work,
    name: []const u8,
    arguments: []const u8,
) !void {
    const body = try std.json.Stringify.valueAlloc(a, .{
        .status = "completed",
        .@"error" = @as(?u8, null),
        .usage = .{ .input_tokens = 7, .output_tokens = 3, .total_tokens = 10 },
        .output = .{.{
            .type = "function_call",
            .status = "completed",
            .call_id = &std.fmt.bytesToHex(pending.attempt, .lower),
            .name = name,
            .arguments = arguments,
        }},
    }, .{});
    const raw = try C.encodeOwned(native.responses.Raw, a, .{
        .status = 200,
        .identity_encoding = true,
        .request_id = null,
        .body = .{ .bytes = body },
    });
    try service.acquire(a, pending, raw);
}

fn context(
    service: *Service,
    worker: *native.testing.Worker,
    a: std.mem.Allocator,
    pending: *native.tasks.Work,
    operation: wc.Context,
) !Json.Value {
    const arguments = try native.values.toJson(@FieldType(types.Action, "context"), a, .{
        .command = operation,
    });
    if (operation == .inspect) {
        const value = arguments.object.getPtr("command").?.object.getPtr("value").?;
        try Json.put(a, value.object.getPtr("page").?, "offset", try Json.number(a, 0));
    }
    try acquire(service, a, pending.*, "context", try Json.canonical(a, arguments));
    pending.* = try next(service, worker, a);
    var prepared = try C.decodeOwned(types.P.AdaptivePrepared, a, pending.prepared.?);
    defer prepared.deinit();
    const results = prepared.value.request.results.items;
    if (results.len != 1) return error.RecurrenceFixtureResultMissing;
    const reply = (try Json.parse(a, results[0].output.bytes, .{})).value;
    if (std.mem.eql(u8, reply.object.get("disposition").?.string, "rejected")) {
        std.debug.print("fixture context: {s}\n", .{results[0].output.bytes});
        return error.RecurrenceFixtureRejected;
    }
    return reply.object.get("observation") orelse error.RecurrenceFixtureResultMissing;
}

fn questionSource(a: std.mem.Allocator) ![]u8 {
    return native.source_records.encode(a, .{
        .entry = 0,
        .failure = 0,
        .schemas = &.{ .unit, .boolean },
        .constants = &.{.{ .schema = 0, .bytes = "" }},
        .effects = &.{.{
            .identity = "example/binary-question",
            .payload = 0,
            .result = 1,
            .external = false,
        }},
        .handlers = &.{},
        .region_count = 0,
        .variables = &.{0},
        .values = &.{.{ .schema = 0, .expression = .{ .literal = 0 } }},
        .terms = &.{.{ .perform = .{ .effect = 0, .payload = 0 } }},
        .functions = &.{.{ .parameters = &.{0}, .result = 1, .effects = &.{0}, .body = 0 }},
    });
}

fn question(service: *Service, a: std.mem.Allocator, task: [16]u8) !Question {
    var parent = try service.task(a, task);
    defer parent.deinit();
    const prefix = try std.fmt.allocPrint(a, "recurrence-question-{d}", .{
        parent.value.inference_attempts,
    });
    const built = try command(service, a, task, prefix, .{ .program = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = try questionSource(a) } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{.{ .effect = 0, .class = .input }} },
    } } });
    const start_id = try std.fmt.allocPrint(a, "{s}-start", .{prefix});
    const started = try command(service, a, task, start_id, .{ .work = .{ .start = .{
        .program = try reference(a, built, "program"),
        .input = .{ .inline_json = .{
            .schema = try reference(a, built, "input_schema"),
            .json_text = .{ .bytes = "{}" },
        } },
        .policy = .{ .stop = .next_exposed_event, .continuation = .owner_scheduled },
    } } });
    const work = try reference(a, started, "work");
    const id = try native.client.identifier(32, Json.string(work.id.bytes));
    for (0..128) |turn| {
        var current = try service.workspaceWork(a, task, id);
        defer current.deinit();
        const expected: wc.Expected = .{
            .work = work,
            .execution_revision = current.value.execution_revision,
            .control_revision = current.value.control_revision,
        };
        if (current.value.current_port) |port_ref| {
            var port = try C.decodeOwned(
                native.workspace.Port,
                a,
                try service.namespace.store.object(a, port_ref, null),
            );
            defer port.deinit();
            return .{
                .expected = expected,
                .port = .{ .kind = .port, .id = .{
                    .bytes = try a.dupe(u8, &std.fmt.bytesToHex(port.value.id, .lower)),
                } },
                .generation = port.value.generation,
            };
        }
        const operation = try std.fmt.allocPrint(a, "{s}-pump-{d}", .{ prefix, turn });
        _ = try service.workspacePump(a, operation, task, .{ .expected = expected });
    }
    return error.RecurrenceFixturePortMissing;
}

fn delegationArguments(
    a: std.mem.Allocator,
    target: Question,
    value: wc.Ref,
    packet: []const u8,
) ![]u8 {
    const arguments = try native.values.toJson(@FieldType(types.Action, "work"), a, .{
        .command = .{ .delegate = .{
            .expected = target.expected,
            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
            .interpretation = .{ .model = .{
                .port = target.port,
                .generation = target.generation,
                .profile_id = .{ .bytes = "analysis" },
                .effort = .{ .bytes = "medium" },
                .subproblem = .{ .bytes = packet },
                .context = .{ .values = .{ .items = &.{value} } },
            } },
        } },
    });
    const selected = arguments.object.getPtr("command").?.object.getPtr("value").?;
    const expected = selected.object.getPtr("expected").?;
    try Json.put(
        a,
        expected,
        "execution_revision",
        try Json.number(a, target.expected.execution_revision),
    );
    try Json.put(a, expected, "control_revision", try Json.number(
        a,
        target.expected.control_revision,
    ));
    const interpretation = selected.object.getPtr("interpretation").?.object.getPtr("value").?;
    try Json.put(a, interpretation, "generation", try Json.number(a, target.generation));
    return Json.canonical(a, arguments);
}

fn delegated(
    service: *Service,
    worker: *native.testing.Worker,
    a: std.mem.Allocator,
    task: [16]u8,
    pending: native.tasks.Work,
    value: wc.Ref,
    packet: []const u8,
) !Json.Value {
    const target = try question(service, a, task);
    try acquire(service, a, pending, "work", try delegationArguments(a, target, value, packet));
    for (0..128) |_| {
        const work = try next(service, worker, a);
        if (work.subject_work != null) {
            if (!std.mem.eql(
                u8,
                work.entry.declaration.identity,
                native.workspace_instrument.model_identity,
            )) return error.InvalidFixtureInference;
            var prepared = try C.decodeOwned(
                native.workspace_instrument.Prepared,
                a,
                work.prepared.?,
            );
            defer prepared.deinit();
            try acquire(service, a, work, "answer", "{\"json_value\":\"true\"}");
            var result = Json.object();
            try Json.put(a, &result, "value", try native.values.toJson(wc.Ref, a, value));
            const view_id = std.fmt.bytesToHex(prepared.value.selected_view.?.digest, .lower);
            try Json.put(a, &result, "view", Json.string(try a.dupe(u8, &view_id)));
            const attempt_id = std.fmt.bytesToHex(work.attempt, .lower);
            try Json.put(a, &result, "attempt", Json.string(try a.dupe(u8, &attempt_id)));
            return result;
        }
        var controller = try C.decodeOwned(types.P.AdaptivePrepared, a, work.prepared.?);
        defer controller.deinit();
        for (controller.value.request.results.items) |entry| {
            const reply = (try Json.parse(a, entry.output.bytes, .{})).value;
            if (Json.get(reply, "disposition")) |disposition|
                if (std.mem.eql(u8, disposition.string, "rejected")) {
                    std.debug.print("fixture delegation: {s}\n", .{entry.output.bytes});
                    return error.RecurrenceFixtureRejected;
                };
        }
        var parent = try service.task(a, task);
        defer parent.deinit();
        const wait = try std.json.Stringify.valueAlloc(a, .{ .command = .{
            .tag = "wait",
            .value = .{
                .works = .{.{ .kind = "work", .id = target.expected.work.id.bytes }},
                .after = parent.value.event_high,
            },
        } }, .{});
        try acquire(service, a, work, "work", wait);
    }
    return error.RecurrenceDelegatedFixtureMissing;
}

pub fn run(
    service: *Service,
    worker: *native.testing.Worker,
    a: std.mem.Allocator,
    task: [16]u8,
    options: Options,
) !Json.Value {
    if (options.value) |value| return delegated(
        service,
        worker,
        a,
        task,
        try next(service, worker, a),
        value,
        options.packet,
    );
    const built = try command(service, a, task, "recurrence-fixture-build", .{
        .program = .{ .build = .{
            .source = .{ .json_text = .{
                .bytes = try native.program_construction.projectionExample(a),
            } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{} },
        } },
    });
    var pending = try next(service, worker, a);
    const consumer = try context(service, worker, a, &pending, .{ .inspect = .{
        .page = .{},
        .consumer = .{ .target = .{ .controller = .{} } },
    } });
    const Payload = wc.ProjectionInput(u64);
    const payload_bytes = try C.encodeOwned(Payload, a, .{
        .consumer = try reference(a, consumer, "consumer"),
        .value = 73,
    });
    var payload = try native.dynamic_values.decode(
        a,
        try native.values.schemaBytes(Payload, a),
        payload_bytes,
    );
    defer payload.deinit();
    const input = try command(service, a, task, "recurrence-fixture-input", .{
        .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{
                .schema = try reference(a, built, "input_schema"),
                .json_text = .{ .bytes = try Json.canonical(a, payload.value) },
            } } },
            .sources = .{ .items = &.{} },
        } },
    });
    const started = try command(service, a, task, "recurrence-fixture-start", .{
        .work = .{ .start = .{
            .program = try reference(a, built, "program"),
            .input = .{ .reference = try reference(a, input, "value") },
            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
        } },
    });
    const result = try complete(service, a, task, try reference(a, started, "work"));
    const selected = try context(service, worker, a, &pending, .{
        .select = .{ .projected = result },
    });
    if (options.delegated)
        return delegated(service, worker, a, task, pending, result, options.packet);
    const stop = "{\"reason\":\"Native recurrence fixture complete.\"}";
    try acquire(service, a, pending, "stop", if (options.reject_action) "{}" else stop);
    return selected;
}
