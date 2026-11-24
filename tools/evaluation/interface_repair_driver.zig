const std = @import("std");
const native = @import("protean_native");
const environment = @import("environment");
const C = @import("protean_contracts");
const types = @import("application_types");
const sources = @import("interface_repair_sources");
const Service = native.tasks.Service(types);
const Commands = native.testing.workspace_commands.Operations(types, Service);
const Consumers = native.testing.workspace_consumers.Operations(types, Service);
const wc = C.workspace;
const Json = native.json;
const State = native.testing.state;
const Allocator = std.mem.Allocator;
const Phase = enum { author, downstream, diagnostic };
const Condition = enum { repair, @"fixed-adequate", @"fixed-lossy", ordinary };
const Plan = struct {
    version: u32,
    plan_sha256: C.Text(64),
    submission_id: C.Text(128),
    prompt_sha256: C.Text(64),
    phase: Phase,
    condition: Condition,
    files: C.Vector(struct { path: C.Utf8, sha256: C.Text(64) }, null),
    source_sha256: C.Text(64),
};

pub const Session = struct {
    expected: ?[32]u8 = null,
    started: bool = false,
    ready: bool = false,
    fixture_used: bool = false,
    downstream_task: ?[16]u8 = null,
    selected: ?struct {
        task: [16]u8,
        view: [64]u8,
        input: [64]u8,
        program: [64]u8,
        result: [64]u8,
    } = null,

    pub fn bootstrap(
        self: *@This(),
        service: *Service,
        worker: *native.testing.Worker,
        a: Allocator,
        params: Json.Value,
    ) !Json.Value {
        const expected = self.expected orelse return error.BootstrapNotEnabled;
        if (self.started) return error.InitialCutRequired;
        if (worker.future != null or service.work != null) return error.WorkerOutstanding;
        if (params != .object or params.object.count() != 3) return error.InvalidParams;
        const task = try native.client.identifier(16, try field(params, "task_id"));
        const descriptor = try Json.text(try field(params, "descriptor"));
        if (!std.meta.eql(expected, native.testing.digest(descriptor))) return error.ChangedPlan;
        const source = try Json.text(try field(params, "source"));
        var decoded = try Json.parseAsset(a, descriptor, descriptor.len);
        defer decoded.deinit();
        const plan = try native.values.fromJson(Plan, a, decoded.value);
        const env: *environment.State = @ptrCast(@alignCast(service.profile.environment orelse
            return error.MissingConfiguration));
        try validatePlan(a, plan, source, env);
        try requireCut(service, a, task, plan);
        self.started = true;
        if (plan.phase == .downstream) self.downstream_task = task;
        if (plan.condition == .ordinary) {
            var ordinary: Bootstrap = .{
                .a = a,
                .service = service,
                .task = task,
                .snapshot = try snapshotRef(a, service.profile.bytes),
            };
            const scan = try sources.acquireScan(a, &ordinary);
            var output = try ordinary.evidence(scan);
            const absent = [_][]const u8{
                "program", "input_schema", "output_schema", "consumer", "input",
                "work",    "result",       "view",          "paired",
            };
            for (absent) |name| try Json.put(a, &output, name, .null);
            self.ready = true;
            return output;
        }
        env.initial_selection = .{ .task = task };
        errdefer env.initial_selection = null;
        const read = try initialConsumer(service, worker, a, task);
        var run: Bootstrap = .{
            .a = a,
            .service = service,
            .task = task,
            .snapshot = try snapshotRef(a, service.profile.bytes),
            .interface = read.interface,
            .consumer = read.reference,
        };
        const output = try self.buildAndSelect(&run, env, plan.phase, source);
        if (plan.phase != .diagnostic) {
            for (0..16384) |_| {
                if (try stepSetup(service, worker, a, task, true)) {
                    env.initial_selection = null;
                    self.ready = true;
                    return output;
                }
            }
            return error.InitialHandoffMissing;
        }
        return output;
    }

    fn buildAndSelect(
        self: *@This(),
        run: *Bootstrap,
        env: *environment.State,
        phase: Phase,
        source: []const u8,
    ) !Json.Value {
        const a = run.a;
        const built = try run.command(.{ .program = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = source } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{} },
        } } });
        const program = try ref(a, built, "program");
        const schema = try ref(a, built, "input_schema");
        var output = try run.project(program, schema, .primary);
        try Json.put(a, &output, "program", try field(built, "program"));
        try Json.put(a, &output, "input_schema", try field(built, "input_schema"));
        try Json.put(a, &output, "output_schema", try field(built, "result_schema"));
        try Json.put(a, &output, "consumer", try native.values.toJson(wc.Ref, a, run.consumer.?));
        try Json.put(a, &output, "paired", if (phase == .diagnostic)
            try run.project(program, schema, .paired)
        else
            .null);
        try self.activate(run, env, phase, &output);
        return output;
    }

    fn activate(
        self: *@This(),
        run: *Bootstrap,
        env: *environment.State,
        phase: Phase,
        output: *Json.Value,
    ) !void {
        if (phase == .diagnostic) return Json.put(run.a, output, "view", .null);
        const result = try ref(run.a, output.*, "result");
        const key = try selectionKey(run.a, self.expected.?, phase);
        const authorized: native.workspace.Authorized = .{
            .command = .{ .context = .{ .select = .{ .projected = result } } },
            .consumer = run.interface,
        };
        const reply = try Commands.workspaceCommandFrom(
            run.service,
            run.a,
            key,
            run.task,
            authorized,
            null,
        );
        if (reply.disposition == .rejected) return error.ProjectionSelectionRejected;
        const bytes = reply.observation_json.bytes;
        const selected = (try Json.parseAsset(run.a, bytes, bytes.len)).value;
        const view = try ref(run.a, selected, "view");
        const input = try ref(run.a, output.*, "input");
        const program = try ref(run.a, output.*, "program");
        self.selected = .{
            .task = run.task,
            .view = view.id.bytes[0..64].*,
            .input = input.id.bytes[0..64].*,
            .program = program.id.bytes[0..64].*,
            .result = result.id.bytes[0..64].*,
        };
        const bound = &self.selected.?;
        env.initial_selection = .{
            .task = run.task,
            .view = .{ .kind = .view, .id = .{ .bytes = &bound.view } },
            .program = .{ .kind = .program, .id = .{ .bytes = &bound.program } },
            .result = .{ .kind = .value, .id = .{ .bytes = &bound.result } },
        };
        try Json.put(run.a, output, "view", try field(selected, "view"));
    }

    pub fn restore(self: *@This(), service: *Service, a: Allocator, task: [16]u8) !void {
        const digest = self.expected orelse return;
        var parent = try service.task(a, task);
        defer parent.deinit();
        if (parent.value.inference_attempts != 0 or parent.value.terminal()) return;
        for ([_]Phase{ .author, .downstream }) |phase| {
            const key = try selectionKey(a, digest, phase);
            var receipt = (try service.operationLookup(a, key)) orelse continue;
            defer receipt.deinit();
            if (!std.meta.eql(receipt.value.task, task) or receipt.value.method != .workspace or
                receipt.value.workspace_kind != .view) return error.InvalidBootstrapReceipt;
            const id = receipt.value.workspace orelse return error.InvalidBootstrapReceipt;
            const store = &service.namespace.store;
            const custody = try native.workspace.custodyId(a, task, id);
            const record = (try store.recordBytes(a, "workspace_view", custody, task)) orelse
                return error.InvalidBootstrapReceipt;
            var view = try C.decodeOwned(native.workspace.View, a, record);
            defer view.deinit();
            const run = view.value.description.projection orelse
                return error.InvalidBootstrapReceipt;
            if (!try capturedInitialContext(service, a, task, id)) return;
            self.started = true;
            self.ready = true;
            if (phase == .downstream) self.downstream_task = task;
            self.selected = .{
                .task = task,
                .view = std.fmt.bytesToHex(id, .lower),
                .input = std.fmt.bytesToHex(run.input.digest, .lower),
                .program = std.fmt.bytesToHex(run.program.digest, .lower),
                .result = std.fmt.bytesToHex(run.result.digest, .lower),
            };
            return;
        }
    }
};

fn selectionKey(a: Allocator, digest: [32]u8, phase: Phase) ![]u8 {
    return std.fmt.allocPrint(a, "interface-repair-{s}-{s}", .{
        @tagName(phase), &std.fmt.bytesToHex(digest, .lower),
    });
}

fn capturedInitialContext(service: *Service, a: Allocator, task: [16]u8, view: [32]u8) !bool {
    const store = &service.namespace.store;
    var rows = try store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.kind='attempt' AND r.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    const expected = std.fmt.bytesToHex(view, .lower);
    while (try rows.step() == .row) {
        var attempt = try C.decodeOwned(State.Attempt, a, try rows.bytes(0));
        defer attempt.deinit();
        if (!std.mem.eql(u8, attempt.value.capability.bytes, types.prepare_identity)) continue;
        const captured = (try store.recordBytes(a, "capture", attempt.value.id, task)) orelse
            continue;
        var capture = try C.decodeOwned(State.Capture, a, captured);
        defer capture.deinit();
        const prepared = attempt.value.prepared orelse continue;
        if (!std.meta.eql(prepared, capture.value.request) or capture.value.response == null or
            capture.value.disposition != .complete) continue;
        const bytes = try store.object(a, prepared, null);
        var product = try C.decodeOwned(types.PreparationProduct, a, bytes);
        defer product.deinit();
        const bound = switch (product.value.result) {
            .ready => |ready| if (ready.request.plan.research) |r| r.view else continue,
            .projection_rejected => |rejected| rejected.view,
            .rejected => continue,
        };
        if (bound.kind == .view and std.mem.eql(u8, bound.id.bytes, &expected)) return true;
    }
    return false;
}

fn field(value: Json.Value, name: []const u8) !Json.Value {
    return Json.get(value, name) orelse error.InvalidParams;
}

fn ref(a: Allocator, value: Json.Value, name: []const u8) !wc.Ref {
    return native.values.fromJson(wc.Ref, a, try field(value, name));
}

fn snapshotRef(a: Allocator, bytes: []const u8) !State.Reference {
    var parsed = try Json.parseAsset(a, bytes, bytes.len);
    defer parsed.deinit();
    return native.values.fromJson(State.Reference, a, try field(parsed.value, "snapshot"));
}

fn validatePlan(
    a: Allocator,
    plan: Plan,
    source: []const u8,
    env: *const environment.State,
) !void {
    _ = try native.client.identifier(32, Json.string(plan.plan_sha256.bytes));
    if (plan.version != 1 or
        (plan.phase != .downstream and plan.condition != .repair)) return error.InvalidPlan;
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(
        native.testing.digest(source),
        .lower,
    ), plan.source_sha256.bytes)) return error.ChangedProgram;
    if (plan.condition == .ordinary and source.len != 0) return error.ConditionViolation;
    const fixed = plan.phase == .author;
    const intrinsic: ?sources.Seed = if (fixed) .lossy else switch (plan.condition) {
        .@"fixed-lossy" => .lossy,
        .@"fixed-adequate" => .adequate,
        .repair, .ordinary => null,
    };
    if (intrinsic) |kind| {
        const bytes = try sources.seed(a, kind);
        defer a.free(bytes);
        if (!std.mem.eql(u8, bytes, source)) return error.ConditionViolation;
    }
    const files = env.snapshot.files();
    if (files.len != plan.files.items.len or env.snapshot.decoded.value.excluded_entries != 0)
        return error.ChangedSnapshot;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (plan.files.items) |item| {
        if ((try seen.getOrPut(a, item.path.bytes)).found_existing) return error.ChangedSnapshot;
        const file = env.snapshot.get(item.path.bytes) orelse return error.ChangedSnapshot;
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(file.sha256, .lower), item.sha256.bytes))
            return error.ChangedSnapshot;
    }
}

fn requireCut(service: *Service, a: Allocator, task: [16]u8, plan: Plan) !void {
    const tasks = try service.namespace.store.taskIds(a, false);
    if (tasks.len != 1 or !std.meta.eql(tasks[0], task)) return error.InitialCutRequired;
    var receipt = (try service.operationLookup(a, plan.submission_id.bytes)) orelse
        return error.ChangedSubmission;
    defer receipt.deinit();
    var parent = try service.task(a, task);
    defer parent.deinit();
    if (receipt.value.method != .submit or !std.meta.eql(receipt.value.task, task) or
        receipt.value.revision != parent.value.revision or parent.value.inference_attempts != 0 or
        parent.value.terminal()) return error.InitialCutRequired;
    const bytes = try service.namespace.store.object(a, parent.value.input, null);
    var input = try C.decodeOwned(types.Input, a, bytes);
    defer input.deinit();
    const expected = try native.client.identifier(32, Json.string(plan.prompt_sha256.bytes));
    if (!std.meta.eql(native.testing.digest(input.value.task.bytes), expected))
        return error.ChangedSubmission;
}

const Consumer = struct { reference: wc.Ref, interface: native.workspace.ConsumerInterface };

fn observedConsumer(service: *Service, a: Allocator, task: [16]u8) !?Consumer {
    var rows = try service.namespace.store.database.prepare(
        "SELECT id FROM records WHERE kind='workspace_reply' AND task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    if (try rows.step() != .row) return null;
    const bytes = try rows.bytes(0);
    if (bytes.len != 32) return error.InvalidConsumer;
    const reference: wc.Ref = .{ .kind = .observation, .id = .{
        .bytes = try a.dupe(u8, &std.fmt.bytesToHex(bytes[0..32].*, .lower)),
    } };
    if (try rows.step() == .row) return error.InitialCutRequired;
    var opened = try Consumers.open(service, a, task, reference);
    defer opened.deinit();
    const observed = opened.value.evidence.read.consumer;
    if (observed.selection.target != .controller or observed.controller.epoch != 0)
        return error.InitialCutRequired;
    return .{ .reference = reference, .interface = observed.interface };
}

fn initialConsumer(
    service: *Service,
    worker: *native.testing.Worker,
    a: Allocator,
    task: [16]u8,
) !Consumer {
    for (0..16384) |_| {
        if (try observedConsumer(service, a, task)) |found| return found;
        _ = try stepSetup(service, worker, a, task, false);
    }
    return error.MissingInitialConsumer;
}

fn stepSetup(
    service: *Service,
    worker: *native.testing.Worker,
    a: Allocator,
    task: [16]u8,
    accept_preparation: bool,
) !bool {
    const next = try service.pump(a);
    if (next != .work) return false;
    const work = next.work;
    const name = work.entry.declaration.identity;
    const prepared = accept_preparation and std.mem.eql(u8, name, types.prepare_identity);
    if (!std.meta.eql(work.task, task) or work.entry.declaration.inference or
        (!prepared and !std.mem.eql(u8, name, types.bindings_identity)))
    {
        try service.notSent(a, work);
        return error.UnexpectedSetupWork;
    }
    try worker.start(work, service.profile.authority, service.profile.environment);
    while (!worker.finished()) try service.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    defer worker.release() catch |err| std.debug.panic("bootstrap worker: {t}", .{err});
    try service.completeWork(a, work, worker.result orelse return error.MissingWorkerResult);
    return prepared;
}

const Bootstrap = struct {
    a: Allocator,
    service: *Service,
    task: [16]u8,
    snapshot: State.Reference,
    interface: ?native.workspace.ConsumerInterface = null,
    consumer: ?wc.Ref = null,
    sequence: u64 = 0,

    fn id(self: *@This(), a: Allocator) ![]const u8 {
        self.sequence += 1;
        return std.fmt.allocPrint(a, "interface-repair-{s}-{d}", .{
            &std.fmt.bytesToHex(self.task, .lower), self.sequence,
        });
    }

    fn command(self: *@This(), operation: wc.Command) !Json.Value {
        const id_value = try self.id(self.a);
        const reply = try self.service.workspaceCommand(self.a, id_value, self.task, operation);
        if (reply.disposition == .rejected) return switch (operation) {
            .program => error.ProjectionBuildRejected,
            .work => error.ProjectionStartRejected,
            .context => |ctx| if (ctx == .select)
                error.ProjectionSelectionRejected
            else
                error.ProjectionInputRejected,
            .placement => unreachable,
        };
        return (try Json.parseAsset(
            self.a,
            reply.observation_json.bytes,
            reply.observation_json.bytes.len,
        )).value;
    }

    pub fn acquireFile(self: *@This(), path: []const u8) !?sources.Acquired {
        const a = self.a;
        const operation = try self.id(self.a);
        const reply = try Commands.workspaceCommandFrom(self.service, a, operation, self.task, .{
            .command = .{ .context = .{ .materialize = .{
                .input = .{ .snapshot = .{
                    .path = .{ .bytes = path },
                    .offset = 0,
                    .maximum = std.math.maxInt(u64),
                } },
                .sources = .{ .items = &.{} },
            } } },
            .snapshot = self.snapshot,
        }, null);
        const bytes = reply.observation_json.bytes;
        const observed = (try Json.parseAsset(a, bytes, bytes.len)).value;
        if (reply.disposition == .rejected) {
            if (std.mem.eql(u8, try Json.text(try field(observed, "error")), "SourceMissing"))
                return null;
            return error.BootstrapAcquisitionRejected;
        }
        const value = try ref(a, observed, "value");
        const digest = try native.client.identifier(32, Json.string(value.id.bytes));
        const store = &self.service.namespace.store;
        const key = try native.workspace.custodyId(a, self.task, digest);
        const record = (try store.recordBytes(a, "workspace_value", key, self.task)) orelse
            return error.ValueUnavailable;
        var retained = try C.decodeOwned(native.workspace.Value, a, record);
        defer retained.deinit();
        if (retained.value.derivation.kind != .acquisition) return error.InvalidAcquisition;
        const contents = try store.object(a, retained.value.description.value, null);
        return .{
            .reference = value,
            .bytes = (try C.decodeOwned(C.Utf8, a, contents)).value.bytes,
        };
    }

    fn project(
        self: *@This(),
        program: wc.Ref,
        schema: wc.Ref,
        manifest: sources.ManifestSelection,
    ) !Json.Value {
        const scan = try sources.acquireScanAt(self.a, self, manifest);
        const materialized = try self.command(.{ .context = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{
                .schema = schema,
                .json_text = .{ .bytes = try sources.projectionInput(
                    self.a,
                    self.consumer.?,
                    scan.evidence,
                ) },
            } } },
            .sources = .{ .items = scan.sources },
        } } });
        const input = try ref(self.a, materialized, "value");
        const started = try self.command(.{ .work = .{ .start = .{
            .program = program,
            .input = .{ .reference = input },
            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
        } } });
        const work = try ref(self.a, started, "work");
        const result = try self.complete(work);
        var output = try self.evidence(scan);
        try Json.put(self.a, &output, "input", try native.values.toJson(wc.Ref, self.a, input));
        try Json.put(self.a, &output, "work", try native.values.toJson(wc.Ref, self.a, work));
        try Json.put(self.a, &output, "result", try native.values.toJson(wc.Ref, self.a, result));
        return output;
    }

    fn evidence(self: *@This(), scan: sources.Scan) !Json.Value {
        var visits: std.array_list.Managed(Json.Value) = .init(self.a);
        for (scan.evidence.visits.items) |visit| try visits.append(if (visit.available)
            try native.values.toJson(wc.Ref, self.a, visit.evidence)
        else
            .null);
        var output = Json.object();
        try Json.put(self.a, &output, "manifest", try native.values.toJson(
            wc.Ref,
            self.a,
            scan.sources[0],
        ));
        try Json.put(self.a, &output, "visits", .{ .array = visits });
        return output;
    }

    fn complete(self: *@This(), work: wc.Ref) !wc.Ref {
        const index = try native.client.identifier(32, Json.string(work.id.bytes));
        while (true) { // tiger: event-loop
            var iteration = std.heap.ArenaAllocator.init(self.service.allocator);
            defer iteration.deinit();
            const scratch = iteration.allocator();
            var current = try self.service.workspaceWork(scratch, self.task, index);
            defer current.deinit();
            if (current.value.outcome_kind == .completed) return .{ .kind = .value, .id = .{
                .bytes = try self.a.dupe(u8, &std.fmt.bytesToHex(
                    (current.value.result_value orelse return error.MissingResult).digest,
                    .lower,
                )),
            } };
            if (current.value.terminal() or current.value.current_port != null)
                return error.ProjectionWorkFailed;
            _ = try self.service.workspacePump(scratch, try self.id(scratch), self.task, .{
                .expected = .{
                    .work = work,
                    .execution_revision = current.value.execution_revision,
                    .control_revision = current.value.control_revision,
                },
            });
        }
    }
};
