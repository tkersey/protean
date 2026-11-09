const std = @import("std");
const native = @import("protean_native");
const C = @import("protean_contracts");
const wc = C.workspace;
const Json = native.json;
const types = @import("application_types");
const Service = native.tasks.Service(types);

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

pub fn run(
    service: *Service,
    worker: *native.testing.Worker,
    a: std.mem.Allocator,
    task: [16]u8,
) !Json.Value {
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
    const stop = "{\"reason\":\"Native recurrence fixture complete.\"}";
    try acquire(service, a, pending, "stop", stop);
    return selected;
}
