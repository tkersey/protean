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
    program_sha256: ?C.Text(64),
};

pub const Session = struct {
    expected: ?[32]u8 = null,
    source_path: ?[]const u8 = null,
    task: ?[16]u8 = null,
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
        selection_only: bool,
    ) !Json.Value {
        const expected = self.expected orelse return error.BootstrapNotEnabled;
        if (self.started) return error.InitialCutRequired;
        if (worker.future != null or service.work != null) return error.WorkerOutstanding;
        if (params != .object or params.object.count() != 3) return error.InvalidParams;
        const task = try native.client.identifier(16, try field(params, "task_id"));
        const descriptor = try Json.text(try field(params, "descriptor"));
        if (!std.meta.eql(expected, native.testing.digest(descriptor))) return error.ChangedPlan;
        const supplied = try field(params, "source");
        const source = if (self.source_path) |path| blk: {
            if (supplied != .null) return error.ChangedProgram;
            break :blk try std.Io.Dir.cwd().readFileAlloc(service.io, path, a, .unlimited);
        } else try Json.text(supplied);
        var decoded = try Json.parseAsset(a, descriptor, descriptor.len);
        defer decoded.deinit();
        const plan = try native.values.fromJson(Plan, a, decoded.value);
        const env: *environment.State = @ptrCast(@alignCast(service.profile.environment orelse
            return error.MissingConfiguration));
        try validatePlan(a, plan, source, env);
        try requireCut(service, a, task, plan);
        self.started = true;
        self.task = task;
        if (plan.phase == .downstream) self.downstream_task = task;
        if (plan.condition == .ordinary) return self.ordinary(service, a, task);
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
        const output = try self.buildAndSelect(&run, env, plan, source);
        if (plan.phase != .diagnostic and !selection_only)
            try self.prepare(service, worker, a);
        return output;
    }

    fn ordinary(self: *@This(), service: *Service, a: Allocator, task: [16]u8) !Json.Value {
        var run: Bootstrap = .{
            .a = a,
            .service = service,
            .task = task,
            .snapshot = try snapshotRef(a, service.profile.bytes),
        };
        const scan = try sources.acquireScan(a, &run);
        var output = try run.evidence(scan);
        const absent = [_][]const u8{
            "program", "input_schema", "output_schema", "consumer", "input",
            "work",    "result",       "view",          "paired",
        };
        for (absent) |name| try Json.put(a, &output, name, .null);
        const key = try receiptKey(a, self.expected.?, "ordinary");
        const manifest = try run.acquireAt("scan.json", key) orelse
            return error.MissingScanDeclaration;
        if (!std.mem.eql(u8, manifest.reference.id.bytes, scan.sources[0].id.bytes))
            return error.ChangedSnapshot;
        self.ready = true;
        return output;
    }

    fn buildAndSelect(
        self: *@This(),
        run: *Bootstrap,
        env: *environment.State,
        plan: Plan,
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
        try run.admitProgram(program, plan);
        var output = try run.project(program, schema, .primary);
        try Json.put(a, &output, "program", try field(built, "program"));
        try Json.put(a, &output, "input_schema", try field(built, "input_schema"));
        try Json.put(a, &output, "output_schema", try field(built, "result_schema"));
        try Json.put(a, &output, "consumer", try native.values.toJson(wc.Ref, a, run.consumer.?));
        try Json.put(a, &output, "paired", if (plan.phase == .diagnostic)
            try run.project(program, schema, .paired)
        else
            .null);
        try self.activate(run, env, plan.phase, &output);
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
        const key = try receiptKey(run.a, self.expected.?, @tagName(phase));
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
        const selected = try observation(run.a, reply, authorized.command);
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
        self.bind(env);
        try Json.put(run.a, output, "view", try field(selected, "view"));
    }

    fn bind(self: *@This(), env: *environment.State) void {
        const bound = &self.selected.?;
        env.initial_selection = .{
            .task = bound.task,
            .view = .{ .kind = .view, .id = .{ .bytes = &bound.view } },
            .program = .{ .kind = .program, .id = .{ .bytes = &bound.program } },
            .result = .{ .kind = .value, .id = .{ .bytes = &bound.result } },
        };
    }

    pub fn prepare(
        self: *@This(),
        service: *Service,
        worker: *native.testing.Worker,
        a: Allocator,
    ) !void {
        const selected = self.selected orelse return error.BootstrapRequired;
        const env: *environment.State = @ptrCast(@alignCast(service.profile.environment.?));
        const view = try native.client.identifier(32, Json.string(&selected.view));
        self.bind(env);
        defer env.initial_selection = null;
        var handoff = try capturedInitialContext(service, a, selected.task, view);
        if (handoff == .pending or handoff == .not_sent) {
            for (0..16384) |_| {
                if (try stepSetup(service, worker, a, selected.task, true)) break;
            } else return error.InitialHandoffMissing;
            handoff = try capturedInitialContext(service, a, selected.task, view);
        }
        switch (handoff) {
            .ready => self.ready = true,
            .pending => return error.InitialHandoffMissing,
            .rejected => |reason| return switch (reason) {
                .oversized => error.ProjectionPreparationOversized,
                .stale => error.ProjectionPreparationStale,
                .invalid => error.ProjectionPreparationInvalid,
                .unavailable => error.ProjectionPreparationUnavailable,
            },
            .unknown => return error.InitialPreparationUnknown,
            .not_sent => return error.InitialPreparationNotSent,
        }
    }

    pub fn restore(self: *@This(), service: *Service, a: Allocator, task: [16]u8) !void {
        const digest = self.expected orelse return;
        self.task = task;
        const ordinary_key = try receiptKey(a, digest, "ordinary");
        if (try service.operationLookup(a, ordinary_key)) |found| {
            var receipt = found;
            defer receipt.deinit();
            _ = try receiptObject(receipt.value, task, .value);
            self.started = true;
            self.downstream_task = task;
            self.ready = true;
            return;
        }
        for ([_]Phase{ .author, .downstream }) |phase| {
            const key = try receiptKey(a, digest, @tagName(phase));
            var receipt = (try service.operationLookup(a, key)) orelse continue;
            defer receipt.deinit();
            const id = try receiptObject(receipt.value, task, .view);
            const store = &service.namespace.store;
            const custody = try native.workspace.custodyId(a, task, id);
            const record = (try store.recordBytes(a, "workspace_view", custody, task)) orelse
                return error.InvalidBootstrapReceipt;
            var view = try C.decodeOwned(native.workspace.View, a, record);
            defer view.deinit();
            const run = view.value.description.projection orelse
                return error.InvalidBootstrapReceipt;
            self.started = true;
            self.ready = try capturedInitialContext(service, a, task, id) == .ready;
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

fn receiptObject(
    receipt: State.Receipt,
    task: [16]u8,
    kind: @FieldType(wc.Ref, "kind"),
) ![32]u8 {
    if (!std.meta.eql(receipt.task, task) or receipt.method != .workspace or
        receipt.workspace_kind != kind) return error.InvalidBootstrapReceipt;
    return receipt.workspace orelse error.InvalidBootstrapReceipt;
}

fn receiptKey(a: Allocator, digest: [32]u8, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "interface-repair-{s}-{s}", .{
        label, &std.fmt.bytesToHex(digest, .lower),
    });
}

const Handoff = union(enum) {
    pending,
    ready,
    rejected: types.ProjectionRejectionCode,
    unknown,
    not_sent,
};

fn capturedInitialContext(service: *Service, a: Allocator, task: [16]u8, view: [32]u8) !Handoff {
    const store = &service.namespace.store;
    var rows = try store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.kind='attempt' AND r.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    const expected = std.fmt.bytesToHex(view, .lower);
    var first: ?struct { cut: u64, occurrence: [32]u8 } = null;
    while (try rows.step() == .row) {
        var attempt = try C.decodeOwned(State.Attempt, a, try rows.bytes(0));
        defer attempt.deinit();
        if (!std.mem.eql(u8, attempt.value.capability.bytes, types.prepare_identity)) continue;
        const cut = attempt.value.preparation_cut orelse return error.InvalidBootstrapReceipt;
        if (first) |prior| if (cut >= prior.cut) continue;
        first = .{ .cut = cut, .occurrence = attempt.value.occurrence };
    }
    const initial = first orelse return .pending;
    const retained = (try store.recordBytes(a, "occurrence", initial.occurrence, task)) orelse
        return error.InvalidBootstrapReceipt;
    var occurrence = try C.decodeOwned(native.testing.occurrence.Occurrence, a, retained);
    defer occurrence.deinit();
    const id = switch (occurrence.value.state) {
        .ready => return .pending,
        .dispatching, .unknown => return .unknown,
        .not_sent => return .not_sent,
        .captured => |v| v.id,
        .settled_reply => |v| v.attempt,
        .admitted => |v| switch (v) {
            .reply => |reply| reply.attempt,
            .cancelled => return error.InitialPreparationFailed,
        },
        .awaiting => return error.InitialPreparationFailed,
    };
    const bytes = (try store.recordBytes(a, "attempt", id, task)) orelse
        return error.InvalidBootstrapReceipt;
    var attempt = try C.decodeOwned(State.Attempt, a, bytes);
    defer attempt.deinit();
    if (!std.meta.eql(attempt.value.occurrence, initial.occurrence))
        return error.InvalidBootstrapReceipt;
    return captureOutcome(service, a, task, id, attempt.value.prepared, &expected);
}

fn captureOutcome(
    service: *Service,
    a: Allocator,
    task: [16]u8,
    attempt: [32]u8,
    request: ?State.Reference,
    expected: []const u8,
) !Handoff {
    const store = &service.namespace.store;
    const captured = (try store.recordBytes(a, "capture", attempt, task)) orelse return .pending;
    var capture = try C.decodeOwned(State.Capture, a, captured);
    defer capture.deinit();
    switch (capture.value.disposition) {
        .unknown => return .unknown,
        .definitely_not_sent => return .not_sent,
        .complete => {},
    }
    const prepared = request orelse return error.InvalidBootstrapReceipt;
    const response = capture.value.response orelse return error.InvalidBootstrapReceipt;
    if (!std.meta.eql(prepared, capture.value.request)) return error.InvalidBootstrapReceipt;
    const proof = try store.object(a, response, null);
    var checked = try C.decodeOwned(types.PreparationCapture, a, proof);
    defer checked.deinit();
    if (!std.meta.eql(prepared.digest, checked.value.prepared))
        return error.InvalidBootstrapReceipt;
    const bytes = try store.object(a, prepared, null);
    var product = try C.decodeOwned(types.PreparationProduct, a, bytes);
    defer product.deinit();
    const bound = switch (product.value.result) {
        .ready => |ready| blk: {
            if (ready.request.plan.prior != null) return error.InvalidBootstrapReceipt;
            const research = ready.request.plan.research orelse
                return error.InvalidBootstrapReceipt;
            break :blk research.view;
        },
        .projection_rejected => |rejected| rejected.view,
        .rejected => return error.InitialPreparationFailed,
    };
    if (bound.kind != .view or !std.mem.eql(u8, bound.id.bytes, expected))
        return error.InvalidBootstrapReceipt;
    return if (product.value.result == .ready)
        .ready
    else
        .{ .rejected = product.value.result.projection_rejected.code };
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
    const candidate = plan.phase != .author and plan.condition == .repair;
    if (candidate != (plan.program_sha256 != null)) return error.ChangedExecutable;
    if (plan.program_sha256) |id| _ = try native.client.identifier(32, Json.string(id.bytes));
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
    switch (next) {
        .work => {},
        .progressed => return false,
        .idle, .waiting => return error.InitialSetupBlocked,
    }
    const work = next.work;
    const name = work.entry.declaration.identity;
    const prepared = accept_preparation and std.mem.eql(u8, name, types.prepare_identity);
    if (!std.meta.eql(work.task, task) or work.entry.declaration.inference or
        (!prepared and !std.mem.eql(u8, name, types.bindings_identity)))
    {
        try service.notSent(a, work);
        return error.UnexpectedSetupWork;
    }
    worker.start(work, service.profile.authority, service.profile.environment) catch |err| {
        try service.notSent(a, work);
        return err;
    };
    while (!worker.finished()) try service.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    defer worker.release() catch |err| std.debug.panic("bootstrap worker: {t}", .{err});
    const result = worker.result orelse return error.MissingWorkerResult;
    try service.completeWork(a, work, result);
    switch (result) {
        .acquired => {},
        .failure => |err| return err,
        .unknown => return error.InitialPreparationUnknown,
        .not_sent, .not_sent_with_reason => return error.InitialPreparationNotSent,
        .rederived => return error.UnexpectedSetupWork,
    }
    return prepared;
}

fn observation(a: Allocator, reply: wc.Reply, command: wc.Command) !Json.Value {
    const bytes = reply.observation_json.bytes;
    const value = (try Json.parseAsset(a, bytes, bytes.len)).value;
    if (reply.disposition != .rejected) return value;
    const code = try Json.text(try field(value, "error"));
    switch (command) {
        .program => {
            if (Json.get(value, "phase")) |phase| {
                const stages = enum { preflight, authority, compilation, interface, relation };
                if (std.meta.stringToEnum(stages, try Json.text(phase)) != null)
                    return error.ProjectionBuildRejected;
            }
        },
        .work => {
            const invalid = enum { InvalidRuntime, InvalidInput, InvalidValue };
            if (std.meta.stringToEnum(invalid, code) != null) return error.ProjectionStartRejected;
        },
        .context => |context| if (context == .select) {
            const invalid = enum {
                InvalidProjection,
                InvalidProjectionSchema,
                InvalidSourceSlice,
                InvalidConsumer,
                ConsumerMismatch,
                StaleConsumer,
            };
            if (std.meta.stringToEnum(invalid, code) != null)
                return error.ProjectionSelectionRejected;
        },
        .placement => unreachable,
    }
    std.debug.print("bootstrap {t}: {s}\n", .{ std.meta.activeTag(command), code });
    return error.BootstrapOwnerRejected;
}

pub fn programPure(service: *Service, a: Allocator, d: native.workspace.ProgramArtifact) !bool {
    if (d.controller != null or d.exposures.items.len != 0 or d.ports.items.len != 0) return false;
    const store = &service.namespace.store;
    const source = try store.object(a, d.source, null);
    const image = try store.object(a, d.image, null);
    native.program_construction.requirePure(a, d.source_kind, source, image) catch |err| {
        if (err == error.ImpureSlice or err == error.ImpureProjection) return false;
        return err;
    };
    return true;
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
        return observation(self.a, reply, operation);
    }

    pub fn acquireFile(self: *@This(), path: []const u8) !?sources.Acquired {
        return self.acquireAt(path, try self.id(self.a));
    }

    fn acquireAt(self: *@This(), path: []const u8, operation: []const u8) !?sources.Acquired {
        const a = self.a;
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

    fn admitProgram(self: *@This(), ref_value: wc.Ref, plan: Plan) !void {
        const a = self.a;
        const program_id = try native.client.identifier(32, Json.string(ref_value.id.bytes));
        if (plan.program_sha256) |expected| {
            if (!std.mem.eql(u8, expected.bytes, ref_value.id.bytes))
                return error.ChangedExecutable;
        }
        var program = try self.service.workspaceProgram(a, self.task, program_id);
        defer program.deinit();
        const d = program.value.description;
        if (d.source_kind != .source_records) return error.ProjectionBuildRejected;
        const store = &self.service.namespace.store;
        if (!try programPure(self.service, a, d)) return error.ProjectionBuildRejected;
        const input = try native.values.schemaBytes(wc.ProjectionInput(sources.ScanEvidence), a);
        if (!std.meta.eql(d.input_schema.digest, native.testing.digest(input)))
            return error.ProjectionInputRejected;
        const output = try store.object(a, d.result_schema, null);
        const header = native.testing.workspace_observers.fieldSchema(a, output, 0) catch |err| {
            if (err == error.InvalidObserverInterface) return error.ProjectionResultRejected;
            return err;
        };
        const expected = try native.values.schemaBytes(wc.ProjectionProposal, a);
        if (!std.mem.eql(u8, header, expected)) return error.ProjectionResultRejected;
    }

    fn checkResult(self: *@This(), result: wc.Ref) !void {
        const a = self.a;
        const store = &self.service.namespace.store;
        const result_id = try native.client.identifier(32, Json.string(result.id.bytes));
        const object = try store.object(a, try store.objectReference(result_id, null), null);
        var artifact = try C.decodeOwned(native.workspace.ValueArtifact, a, object);
        defer artifact.deinit();
        const schema = try store.object(a, artifact.value.schema, null);
        const bytes = try store.object(a, artifact.value.value, null);
        try sources.requireComputed(a, self.consumer.?, schema, bytes);
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
        try self.checkResult(result);
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
            if (current.value.outcome_kind == .failed or current.value.current_port != null)
                return error.ProjectionWorkFailed;
            if (current.value.outcome_kind == .cancelled) return error.BootstrapWorkCancelled;
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
