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

pub const Cut = enum {
    complete,
    build,
    consumer,
    acquisition,
    start,
    primary,
    selection,
    not_sent,
    joined,
};
const BuildMetrics = struct {
    build_commands: ?u32 = 0,
    rejected_build_commands: ?u32 = 0,
    elapsed_ns: ?u64 = 0,

    const uncertain: @This() = .{
        .build_commands = null,
        .rejected_build_commands = null,
        .elapsed_ns = null,
    };
    const admitted: @This() = .{ .build_commands = 1, .elapsed_ns = null };

    fn historical(observed: bool) @This() {
        return if (observed) admitted else uncertain;
    }

    fn json(self: @This(), a: Allocator) !Json.Value {
        var out = Json.object();
        try Json.put(a, &out, "build_commands", if (self.build_commands) |n|
            try Json.number(a, n)
        else
            .null);
        try Json.put(a, &out, "rejected_build_commands", if (self.rejected_build_commands) |n|
            try Json.number(a, n)
        else
            .null);
        try Json.put(a, &out, "build_elapsed_nanoseconds", if (self.elapsed_ns) |n|
            Json.string(try std.fmt.allocPrint(a, "{d}", .{n}))
        else
            .null);
        try Json.put(a, &out, "compiler_nanoseconds", if (self.build_commands == 0)
            Json.string("0")
        else
            .null);
        return out;
    }
};

pub const Session = struct {
    expected: ?[32]u8 = null,
    source_path: ?[]const u8 = null,
    task: ?[16]u8 = null,
    started: bool = false,
    ready: bool = false,
    metrics: ?BuildMetrics = null,
    observed_first_build: bool = true,
    fixture_used: bool = false,
    downstream_task: ?[16]u8 = null,
    selected: ?struct {
        task: [16]u8,
        view: [64]u8,
        input: [64]u8,
        program: [64]u8,
        result: [64]u8,
    } = null,

    pub fn admission(
        self: *const @This(),
        service: *Service,
        a: Allocator,
        params: Json.Value,
    ) !Json.Value {
        const expected = self.expected orelse return error.BootstrapNotEnabled;
        const descriptor = try Json.text(try field(params, "descriptor"));
        if (!std.meta.eql(expected, native.testing.digest(descriptor))) return error.ChangedPlan;
        var decoded = try Json.parseAsset(a, descriptor, descriptor.len);
        defer decoded.deinit();
        const plan = try native.values.fromJson(Plan, a, decoded.value);
        const env: *environment.State = @ptrCast(@alignCast(service.profile.environment orelse
            return error.MissingConfiguration));
        try validateSnapshot(a, plan, env);
        const bytes = service.profile.bytes;
        var profile = try Json.parseAsset(a, bytes, bytes.len);
        defer profile.deinit();
        const config = try Json.text(try field(profile.value, "configuration_digest"));
        var result = Json.object();
        try Json.put(a, &result, "configuration_digest", Json.string(try a.dupe(u8, config)));
        const id = std.fmt.bytesToHex(native.testing.digest(bytes), .lower);
        try Json.put(a, &result, "profile_sha256", Json.string(try a.dupe(u8, &id)));
        return result;
    }

    pub fn bootstrap(
        self: *@This(),
        service: *Service,
        worker: *native.testing.Worker,
        a: Allocator,
        params: Json.Value,
        cut: Cut,
    ) !Json.Value {
        const expected = self.expected orelse return error.BootstrapNotEnabled;
        const completed_only = if (Json.get(params, "completed_only")) |flag| blk: {
            if (flag != .bool or !flag.bool) return error.InvalidParams;
            break :blk true;
        } else false;
        const fields = @as(usize, 3) + @intFromBool(completed_only);
        if (params != .object or params.object.count() != fields)
            return error.InvalidParams;
        if (!completed_only and self.started) return error.InitialCutRequired;
        if (worker.future != null or service.work != null) return error.WorkerOutstanding;
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
        const submission = try originalSubmission(service, a, task, plan);
        if (completed_only) {
            if (cut != .complete) return error.InvalidParams;
            return self.completed(service, a, task, plan) catch |err|
                self.retainedFailure(a, task, plan, err);
        }
        const observed = self.observed_first_build and plan.condition != .ordinary;
        const remaining = try requireCut(service, a, task, plan, expected, submission, observed);
        self.started = true;
        self.task = task;
        self.metrics = .{};
        if (plan.phase == .downstream) self.downstream_task = task;
        var run: Bootstrap = .{
            .a = a,
            .service = service,
            .task = task,
            .snapshot = try snapshotRef(a, service.profile.bytes),
            .prefix = try progressPrefix(a, expected),
            .cut = cut,
            .remaining = remaining,
            .observed_first_build = observed,
        };
        var output = if (plan.condition == .ordinary)
            try self.ordinary(&run)
        else
            try self.projected(&run, worker, env, plan, source);
        try Json.put(a, &output, "build_metrics", try self.metrics.?.json(a));
        return output;
    }

    fn completed(
        self: *const @This(),
        service: *Service,
        a: Allocator,
        task: [16]u8,
        plan: Plan,
    ) !Json.Value {
        const digest = self.expected.?;
        const env: *environment.State = @ptrCast(@alignCast(service.profile.environment.?));
        var run: Bootstrap = .{
            .a = a,
            .service = service,
            .task = task,
            .snapshot = try snapshotRef(a, service.profile.bytes),
            .prefix = try progressPrefix(a, digest),
            .cut = .complete,
            .remaining = 0,
            .read_only = true,
            .observed_first_build = self.observed_first_build and plan.condition != .ordinary,
        };
        var copy = self.*;
        const ordinary_case = plan.condition == .ordinary;
        var output = if (ordinary_case) blk: {
            const key = try receiptKey(a, digest, "ordinary");
            _ = try retainedId(service, a, task, key, .value);
            break :blk try copy.ordinary(&run);
        } else blk: {
            run.consumer = try self.retainedConsumer(&run, plan.phase);
            const built = try run.builtReceipt(try run.nextOperation(a));
            break :blk copy.selectProgram(&run, env, plan, built) catch |err| {
                if (err == error.BootstrapEvidencePending and plan.program_sha256 != null and
                    !run.acquired_scan)
                    try run.admitProgram(try ref(a, built, "program"), plan);
                return err;
            };
        };
        const metrics = if (std.meta.eql(self.task, @as(?[16]u8, task)) and self.metrics != null)
            self.metrics.?
        else if (ordinary_case)
            BuildMetrics{}
        else
            BuildMetrics.admitted;
        try Json.put(a, &output, "build_metrics", try metrics.json(a));
        return output;
    }

    fn retainedConsumer(self: *const @This(), run: *Bootstrap, phase: Phase) !wc.Ref {
        const a = run.a;
        if (phase != .diagnostic) {
            const key = try receiptKey(a, self.expected.?, @tagName(phase));
            if (try run.service.operationLookup(a, key)) |receipt| {
                var saved = receipt;
                defer saved.deinit();
                const id = try receiptObject(saved.value, run.task, .view);
                var view = try retainedView(run.service, a, run.task, id);
                defer view.deinit();
                const projection = view.value.description.projection orelse
                    return error.InvalidBootstrapReceipt;
                const store = &run.service.namespace.store;
                const bytes = try store.object(a, projection.observation, null);
                var read = try C.decodeOwned(native.workspace.ReplyObservation, a, bytes);
                defer read.deinit();
                if (!std.meta.eql(read.value.task, run.task)) return error.InvalidBootstrapReceipt;
                return workspaceRef(a, .observation, read.value.id);
            }
        }
        const read = try observedConsumer(run.service, a, run.task) orelse
            return error.BootstrapEvidencePending;
        return read.reference;
    }

    fn retainedFailure(
        self: *const @This(),
        a: Allocator,
        task: [16]u8,
        plan: Plan,
        err: anyerror,
    ) !Json.Value {
        if (err == error.BootstrapEvidencePending) return .null;
        if (plan.program_sha256 == null) return err;
        switch (err) {
            error.ProjectionWorkFailed,
            error.ProjectionResultRejected,
            error.ProjectionInputRejected,
            error.ProjectionBuildRejected,
            => {},
            else => return err,
        }
        var outcome = Json.object();
        try Json.put(a, &outcome, "candidate_rejected", Json.string(@errorName(err)));
        try Json.put(a, &outcome, "build_metrics", try self.buildMetrics(a, task));
        return outcome;
    }

    pub fn buildMetrics(self: *const @This(), a: Allocator, task: [16]u8) !Json.Value {
        if (self.task == null or !std.meta.eql(self.task.?, task)) return .null;
        return if (self.metrics) |m| m.json(a) else .null;
    }

    fn ordinary(self: *@This(), run: *Bootstrap) !Json.Value {
        const a = run.a;
        const scan = try sources.acquireScan(a, run);
        var output = try run.evidence(scan);
        const absent = [_][]const u8{
            "program", "input_schema", "output_schema", "consumer", "input",
            "work",    "result",       "view",          "paired",
        };
        for (absent) |name| try Json.put(a, &output, name, .null);
        if (run.remaining != 0) return error.InitialCutRequired;
        const key = try receiptKey(a, self.expected.?, "ordinary");
        const manifest = try run.acquireAt("scan.json", key) orelse
            return error.MissingScanDeclaration;
        if (!std.mem.eql(u8, manifest.reference.id.bytes, scan.sources[0].id.bytes))
            return error.ChangedSnapshot;
        self.ready = true;
        return output;
    }

    fn projected(
        self: *@This(),
        run: *Bootstrap,
        worker: *native.testing.Worker,
        env: *environment.State,
        plan: Plan,
        source: []const u8,
    ) !Json.Value {
        const built = try run.build(source, &self.metrics.?);
        if (run.cut == .build) return error.FixtureCut;
        env.initial_selection = .{ .task = run.task };
        defer env.initial_selection = null;
        const read = try initialConsumer(run.service, worker, run.a, run.task, run.remaining);
        if (run.cut == .consumer) return error.FixtureCut;
        run.interface = read.interface;
        run.consumer = read.reference;
        var output = try self.selectProgram(run, env, plan, built);
        if (plan.phase != .diagnostic) {
            if (run.cut != .selection) try self.prepare(run.service, worker, run.a, run.cut);
            const handoff: Handoff = if (self.ready) .ready else .pending;
            try putPreparation(run.a, &output, handoff, plan.program_sha256 != null);
        }
        return output;
    }

    fn selectProgram(
        self: *@This(),
        run: *Bootstrap,
        env: *environment.State,
        plan: Plan,
        built: Json.Value,
    ) !Json.Value {
        const a = run.a;
        const program = try ref(a, built, "program");
        const schema = try ref(a, built, "input_schema");
        if (!run.read_only) try run.admitProgram(program, plan);
        var output = try run.project(program, schema, .primary);
        if (run.cut == .primary) return error.FixtureCut;
        try Json.put(a, &output, "program", try field(built, "program"));
        try Json.put(a, &output, "input_schema", try field(built, "input_schema"));
        try Json.put(a, &output, "output_schema", try field(built, "result_schema"));
        try Json.put(a, &output, "consumer", try native.values.toJson(wc.Ref, a, run.consumer.?));
        try Json.put(a, &output, "paired", if (plan.phase == .diagnostic)
            try run.project(program, schema, .paired)
        else
            .null);
        if (run.remaining != 0) return error.InitialCutRequired;
        try self.activate(run, env, plan, &output);
        return output;
    }

    fn activate(
        self: *@This(),
        run: *Bootstrap,
        env: *environment.State,
        plan: Plan,
        output: *Json.Value,
    ) !void {
        const phase = plan.phase;
        if (phase == .diagnostic) return Json.put(run.a, output, "view", .null);
        const result = try ref(run.a, output.*, "result");
        const key = try receiptKey(run.a, self.expected.?, @tagName(phase));
        if (run.read_only) {
            const view = try retainedId(run.service, run.a, run.task, key, .view);
            const handoff = try capturedInitialContext(run.service, run.a, run.task, view);
            try putPreparation(run.a, output, handoff, plan.program_sha256 != null);
            return putRef(run.a, output, "view", .view, view);
        }
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
        cut: Cut,
    ) !void {
        const selected = self.selected orelse return error.BootstrapRequired;
        const env: *environment.State = @ptrCast(@alignCast(service.profile.environment.?));
        const view = try native.client.identifier(32, Json.string(&selected.view));
        self.bind(env);
        defer env.initial_selection = null;
        var handoff = try capturedInitialContext(service, a, selected.task, view);
        if (handoff == .pending or handoff == .not_sent) {
            for (0..16384) |_| {
                if (try stepSetup(service, worker, a, selected.task, true, cut)) break;
            } else return error.InitialHandoffMissing;
            handoff = try capturedInitialContext(service, a, selected.task, view);
        }
        switch (handoff) {
            .ready => self.ready = true,
            .failed => return error.InitialPreparationFailed,
            .pending => return error.InitialHandoffMissing,
            .rejected => |reason| return preparationRejection(reason),
            .unknown => return error.InitialPreparationUnknown,
            .not_sent => return error.InitialPreparationNotSent,
        }
    }

    pub fn restore(self: *@This(), service: *Service, a: Allocator, task: [16]u8) !void {
        const digest = self.expected orelse return;
        self.task = task;
        const prefix = try progressPrefix(a, digest);
        var original = try service.operationLookup(a, try firstKey(a, prefix, true));
        defer if (original) |*receipt| receipt.deinit();
        self.observed_first_build = original != null;
        const ordinary_key = try receiptKey(a, digest, "ordinary");
        if (try service.operationLookup(a, ordinary_key)) |found| {
            var receipt = found;
            defer receipt.deinit();
            _ = try receiptObject(receipt.value, task, .value);
            self.metrics = .{};
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
            var view = try retainedView(service, a, task, id);
            defer view.deinit();
            const run = view.value.description.projection orelse
                return error.InvalidBootstrapReceipt;
            self.started = true;
            self.metrics = BuildMetrics.historical(self.observed_first_build);
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
        const key = try firstKey(a, prefix, self.observed_first_build);
        var first = (try service.operationLookup(a, key)) orelse return;
        defer first.deinit();
        if (!std.meta.eql(first.value.task, task) or first.value.method != .workspace)
            return error.InvalidBootstrapReceipt;
        const kind = first.value.workspace_kind orelse return error.InvalidBootstrapReceipt;
        self.metrics = switch (kind) {
            .program => BuildMetrics.historical(self.observed_first_build),
            .value => .{},
            else => return error.InvalidBootstrapReceipt,
        };
    }
};

fn retainedView(
    service: *Service,
    a: Allocator,
    task: [16]u8,
    id: [32]u8,
) !C.Decoded(native.workspace.View) {
    const custody = try native.workspace.custodyId(a, task, id);
    const store = &service.namespace.store;
    const record = (try store.recordBytes(a, "workspace_view", custody, task)) orelse
        return error.InvalidBootstrapReceipt;
    return C.decodeOwned(native.workspace.View, a, record);
}

fn retainedId(
    service: *Service,
    a: Allocator,
    task: [16]u8,
    key: []const u8,
    kind: @FieldType(wc.Ref, "kind"),
) ![32]u8 {
    var receipt = (try service.operationLookup(a, key)) orelse
        return error.BootstrapEvidencePending;
    defer receipt.deinit();
    return receiptObject(receipt.value, task, kind);
}

fn workspaceRef(a: Allocator, kind: @FieldType(wc.Ref, "kind"), id: [32]u8) !wc.Ref {
    return .{ .kind = kind, .id = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)) } };
}

fn putRef(
    a: Allocator,
    output: *Json.Value,
    name: []const u8,
    kind: @FieldType(wc.Ref, "kind"),
    id: [32]u8,
) !void {
    const value = try workspaceRef(a, kind, id);
    try Json.put(a, output, name, try native.values.toJson(wc.Ref, a, value));
}

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
    failed,
    ready,
    rejected: types.ProjectionRejectionCode,
    unknown,
    not_sent,
};

fn preparationRejection(reason: types.ProjectionRejectionCode) anyerror {
    return switch (reason) {
        .oversized => error.ProjectionPreparationOversized,
        .stale => error.ProjectionPreparationStale,
        .invalid => error.ProjectionPreparationInvalid,
        .unavailable => error.ProjectionPreparationUnavailable,
    };
}

fn putPreparation(a: Allocator, output: *Json.Value, handoff: Handoff, candidate: bool) !void {
    try Json.put(a, output, "preparation", Json.string(@tagName(handoff)));
    if (handoff == .rejected) {
        const reason = Json.string(@errorName(preparationRejection(handoff.rejected)));
        try Json.put(a, output, "preparation_rejection", reason);
        if (candidate) try Json.put(a, output, "candidate_rejected", reason);
    }
}

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
            .cancelled => return .failed,
        },
        .awaiting => return .failed,
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
        .rejected => return .failed,
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
    try validateSnapshot(a, plan, env);
}

fn validateSnapshot(a: Allocator, plan: Plan, env: *const environment.State) !void {
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

fn progressPrefix(a: Allocator, digest: [32]u8) ![]u8 {
    return std.fmt.allocPrint(a, "ir-{s}-", .{&std.fmt.bytesToHex(digest, .lower)});
}

const Submission = struct { id: [32]u8, revision: u64 };

fn originalSubmission(service: *Service, a: Allocator, task: [16]u8, plan: Plan) !Submission {
    const tasks = try service.namespace.store.taskIds(a, false);
    if (tasks.len != 1 or !std.meta.eql(tasks[0], task)) return error.InitialCutRequired;
    var submitted = (try service.operationLookup(a, plan.submission_id.bytes)) orelse
        return error.ChangedSubmission;
    defer submitted.deinit();
    var parent = try service.task(a, task);
    defer parent.deinit();
    if (submitted.value.method != .submit or !std.meta.eql(submitted.value.task, task))
        return error.InitialCutRequired;
    const bytes = try service.namespace.store.object(a, parent.value.input, null);
    var input = try C.decodeOwned(types.Input, a, bytes);
    defer input.deinit();
    const expected = try native.client.identifier(32, Json.string(plan.prompt_sha256.bytes));
    if (!std.meta.eql(native.testing.digest(input.value.task.bytes), expected))
        return error.ChangedSubmission;
    return .{ .id = submitted.value.id, .revision = submitted.value.revision };
}

fn firstKey(a: Allocator, prefix: []const u8, observed: bool) ![]const u8 {
    const first = if (observed) "1-observed" else "1";
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, first });
}

fn requireCut(
    service: *Service,
    a: Allocator,
    task: [16]u8,
    plan: Plan,
    digest: [32]u8,
    submission: Submission,
    observed: bool,
) !u64 {
    var parent = try service.task(a, task);
    defer parent.deinit();
    if (parent.value.inference_attempts != 0 or parent.value.terminal())
        return error.InitialCutRequired;
    if (submission.revision == parent.value.revision) return 0;
    const prefix = try progressPrefix(a, digest);
    const first = try firstKey(a, prefix, observed);
    const count = try setupOperations(service, a, task, prefix, submission);
    var started = (try service.operationLookup(a, first)) orelse {
        if (count != 0) return error.InitialCutRequired;
        try requireResumeOnly(service, a, task, submission.revision, parent.value.revision);
        return 0;
    };
    defer started.deinit();
    const kind: @FieldType(wc.Ref, "kind") = if (plan.condition == .ordinary) .value else .program;
    _ = try receiptObject(started.value, task, kind);
    if (started.value.revision <= submission.revision) return error.InitialCutRequired;
    try requireResumeOnly(service, a, task, submission.revision, started.value.revision - 1);
    return count;
}

fn requireResumeOnly(service: *Service, a: Allocator, task: [16]u8, from: u64, to: u64) !void {
    if (from == to) return;
    var events = try service.namespace.store.database.prepare(
        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
            "WHERE e.task=? AND e.revision>? AND e.revision<=? ORDER BY e.seq",
        &.{ .{ .blob = &task }, .{ .integer = @intCast(from) }, .{ .integer = @intCast(to) } },
    );
    defer events.deinit();
    var revision = from;
    while (try events.step() == .row) {
        var event = try C.decodeOwned(State.Event, a, try events.bytes(0));
        defer event.deinit();
        if (!std.meta.eql(event.value.task, task) or
            (event.value.kind != .parked and event.value.kind != .resumed) or
            event.value.revision != try std.math.add(u64, revision, 1))
            return error.InitialCutRequired;
        revision = event.value.revision;
    }
    if (revision != to) return error.InitialCutRequired;
}

fn setupOperations(
    service: *Service,
    a: Allocator,
    task: [16]u8,
    prefix: []const u8,
    submitted: Submission,
) !u64 {
    var count: u64 = 0;
    const store = &service.namespace.store;
    var rows = try store.database.prepare(
        "SELECT o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?",
        &.{.{ .blob = &task }},
    );
    defer rows.deinit();
    while (try rows.step() == .row) {
        var saved = try C.decodeOwned(State.Receipt, a, try rows.bytes(0));
        defer saved.deinit();
        const receipt = saved.value;
        if (!std.meta.eql(receipt.task, task)) return error.InvalidBootstrapReceipt;
        switch (receipt.method) {
            .submit => if (!std.meta.eql(receipt.id, submitted.id)) return error.InitialCutRequired,
            .@"resume" => {},
            .workspace => {
                if (!std.mem.startsWith(u8, receipt.client_operation_id.bytes, prefix))
                    return error.InitialCutRequired;
                count += 1;
            },
            else => return error.InitialCutRequired,
        }
    }
    return count;
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
    remaining: u64,
) !Consumer {
    for (0..16384) |_| {
        if (try observedConsumer(service, a, task)) |found| return found;
        if (remaining != 0) return error.InitialCutRequired;
        _ = try stepSetup(service, worker, a, task, false, .complete);
    }
    return error.MissingInitialConsumer;
}

fn stepSetup(
    service: *Service,
    worker: *native.testing.Worker,
    a: Allocator,
    task: [16]u8,
    accept_preparation: bool,
    cut: Cut,
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
    if (prepared and cut == .not_sent) {
        try service.notSent(a, work);
        return error.FixtureCut;
    }
    worker.start(work, service.profile.authority, service.profile.environment) catch |err| {
        try service.notSent(a, work);
        return err;
    };
    while (!worker.finished()) try service.io.sleep(.fromMilliseconds(1), .awake);
    try worker.join();
    const result = worker.result orelse return error.MissingWorkerResult;
    const failure: ?anyerror = switch (result) {
        .acquired => null,
        .failure => |err| err,
        .unknown => error.InitialPreparationUnknown,
        .not_sent, .not_sent_with_reason => error.InitialPreparationNotSent,
        .rederived => error.UnexpectedSetupWork,
    };
    try publishJoined(service, worker, a, prepared and cut == .joined);
    if (failure) |reason| return reason;
    return prepared;
}

pub fn publishJoined(
    service: *Service,
    worker: *native.testing.Worker,
    a: Allocator,
    interrupt_save: bool,
) !void {
    const result = worker.result orelse return error.MissingWorkerResult;
    const saved = if (interrupt_save)
        error.FixtureCut
    else
        service.completeWork(a, worker.work, result);
    saved catch |err| {
        if (service.work == null) try worker.release();
        return err;
    };
    try worker.release();
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
    const source = switch (d.source_kind) {
        .source_records, .source_derivation => try store.object(a, d.source, null),
        .component_recipe => "",
        .instrument_model, .instrument_snapshot => return false,
    };
    const image = if (d.source_kind == .component_recipe)
        try store.object(a, d.image, null)
    else
        "";
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
    prefix: []const u8,
    cut: Cut,
    remaining: u64,
    sequence: u64 = 0,
    read_only: bool = false,
    acquired_scan: bool = false,
    observed_first_build: bool,

    fn nextOperation(self: *@This(), a: Allocator) ![]const u8 {
        self.sequence += 1;
        if (self.sequence == 1) return firstKey(a, self.prefix, self.observed_first_build);
        return std.fmt.allocPrint(a, "{s}{d}", .{ self.prefix, self.sequence });
    }

    fn build(self: *@This(), source: []const u8, metrics: *BuildMetrics) !Json.Value {
        const resumed = self.remaining != 0;
        metrics.* = BuildMetrics.historical(self.observed_first_build);
        const started = std.Io.Clock.awake.now(self.service.io);
        defer if (!resumed and self.observed_first_build) {
            const now = std.Io.Clock.awake.now(self.service.io);
            const elapsed = now.nanoseconds - started.nanoseconds;
            metrics.elapsed_ns = std.math.cast(u64, elapsed);
        };
        return self.command(.{ .program = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = source } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{} },
        } } }) catch |err| {
            if (self.observed_first_build)
                metrics.rejected_build_commands = if (err == error.ProjectionBuildRejected)
                    1
                else
                    null;
            return err;
        };
    }

    fn expectReplay(self: *@This(), a: Allocator, operation: []const u8, missing: bool) !void {
        if (self.remaining == 0) return;
        var saved = (try self.service.operationLookup(a, operation)) orelse {
            if (missing) return;
            return error.InitialCutRequired;
        };
        defer saved.deinit();
        if (!std.meta.eql(saved.value.task, self.task) or saved.value.method != .workspace)
            return error.InitialCutRequired;
        self.remaining -= 1;
    }

    fn command(self: *@This(), operation: wc.Command) !Json.Value {
        const id_value = try self.nextOperation(self.a);
        if (self.read_only) {
            const work = operation == .work and operation.work == .start;
            if (!work and (operation != .context or operation.context != .materialize))
                return error.InvalidBootstrapReceipt;
            const kind: @FieldType(wc.Ref, "kind") = if (work) .work else .value;
            const id = try retainedId(self.service, self.a, self.task, id_value, kind);
            var result = Json.object();
            try putRef(self.a, &result, @tagName(kind), kind, id);
            return result;
        }
        try self.expectReplay(self.a, id_value, false);
        const reply = try self.service.workspaceCommand(self.a, id_value, self.task, operation);
        return observation(self.a, reply, operation);
    }

    fn builtReceipt(self: *@This(), key: []const u8) !Json.Value {
        const a = self.a;
        const id = try retainedId(self.service, a, self.task, key, .program);
        var program = try self.service.workspaceProgram(a, self.task, id);
        defer program.deinit();
        var output = Json.object();
        try putRef(a, &output, "program", .program, id);
        const built = program.value.description;
        try putRef(a, &output, "input_schema", .schema, built.input_schema.digest);
        try putRef(a, &output, "result_schema", .schema, built.result_schema.digest);
        return output;
    }

    pub fn acquireFile(self: *@This(), path: []const u8) !?sources.Acquired {
        const file = try self.acquireAt(path, try self.nextOperation(self.a));
        if (self.cut == .acquisition) return error.FixtureCut;
        return file;
    }

    fn acquireAt(self: *@This(), path: []const u8, operation: []const u8) !?sources.Acquired {
        const a = self.a;
        const env: *const environment.State =
            @ptrCast(@alignCast(self.service.profile.environment.?));
        if (self.read_only) {
            if (env.snapshot.get(path) == null) return null;
            const id = try retainedId(self.service, a, self.task, operation, .value);
            return try self.acquiredValue(try workspaceRef(a, .value, id));
        }
        if (self.remaining != 0) {
            try self.expectReplay(a, operation, env.snapshot.get(path) == null);
        }
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
        return try self.acquiredValue(try ref(a, observed, "value"));
    }

    fn acquiredValue(self: *@This(), value: wc.Ref) !sources.Acquired {
        const a = self.a;
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
        self.acquired_scan = true;
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
        if (self.cut == .start) return error.FixtureCut;
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

    fn workSnapshot(self: *@This(), receipt: State.Receipt, index: [32]u8) !State.Reference {
        if (!std.meta.eql(try receiptObject(receipt, self.task, .work), index))
            return error.InvalidBootstrapReceipt;
        return receipt.workspace_observation orelse error.InvalidBootstrapReceipt;
    }

    fn terminalReceipt(
        self: *@This(),
        start: State.Reference,
        index: [32]u8,
    ) !?State.Reference {
        const a = self.a;
        var latest = try self.service.workspaceWork(a, self.task, index);
        defer latest.deinit();
        if (!latest.value.terminal() and latest.value.current_port == null)
            return error.BootstrapEvidencePending;
        const store = &self.service.namespace.store;
        const bytes = try store.object(a, start, null);
        var origin = try C.decodeOwned(native.workspace.WorkObservation, a, bytes);
        defer origin.deinit();
        const revisions = std.math.sub(
            u64,
            latest.value.control_revision,
            origin.value.work.control_revision,
        ) catch return null;
        if (revisions == 0) return null;
        const ordinal = try std.math.add(u64, self.sequence, revisions);
        const key = try std.fmt.allocPrint(a, "{s}{d}", .{ self.prefix, ordinal });
        var receipt = (try self.service.operationLookup(a, key)) orelse return null;
        defer receipt.deinit();
        if (receipt.value.workspace_kind != .work or
            !std.meta.eql(receipt.value.workspace, @as(?[32]u8, index))) return null;
        const saved = try self.workSnapshot(receipt.value, index);
        const frozen = try store.object(a, saved, null);
        var observed = try C.decodeOwned(native.workspace.WorkObservation, a, frozen);
        defer observed.deinit();
        const work = observed.value.work;
        if (!std.meta.eql(work.task, self.task) or !std.meta.eql(work.id, index))
            return error.InvalidBootstrapReceipt;
        if (!work.terminal() and work.current_port == null) return null;
        self.sequence = ordinal;
        return saved;
    }

    fn complete(self: *@This(), work: wc.Ref) !wc.Ref {
        const key = try std.fmt.allocPrint(self.a, "{s}{d}", .{ self.prefix, self.sequence });
        var start = (try self.service.operationLookup(self.a, key)) orelse
            return error.InvalidBootstrapReceipt;
        defer start.deinit();
        const index = try native.client.identifier(32, Json.string(work.id.bytes));
        var frozen = try self.workSnapshot(start.value, index);
        if (self.read_only) frozen = try self.terminalReceipt(frozen, index) orelse frozen;
        while (true) { // tiger: event-loop
            var iteration = std.heap.ArenaAllocator.init(self.service.allocator);
            defer iteration.deinit();
            const a = iteration.allocator();
            const bytes = try self.service.namespace.store.object(a, frozen, null);
            var saved = try C.decodeOwned(native.workspace.WorkObservation, a, bytes);
            defer saved.deinit();
            const current = saved.value.work;
            if (!std.meta.eql(current.task, self.task) or !std.meta.eql(current.id, index))
                return error.InvalidBootstrapReceipt;
            if (current.outcome_kind == .completed) {
                const result = current.result_value orelse return error.MissingResult;
                return .{ .kind = .value, .id = .{
                    .bytes = try self.a.dupe(u8, &std.fmt.bytesToHex(result.digest, .lower)),
                } };
            }
            if (current.outcome_kind == .failed or current.current_port != null)
                return error.ProjectionWorkFailed;
            if (current.outcome_kind == .cancelled) return error.BootstrapWorkCancelled;
            const operation = try self.nextOperation(a);
            if (self.read_only) {
                var receipt = (try self.service.operationLookup(a, operation)) orelse
                    return error.BootstrapEvidencePending;
                defer receipt.deinit();
                frozen = try self.workSnapshot(receipt.value, index);
                continue;
            }
            try self.expectReplay(a, operation, false);
            const next = try self.service.workspacePump(a, operation, self.task, .{ .expected = .{
                .work = work,
                .execution_revision = current.execution_revision,
                .control_revision = current.control_revision,
            } });
            frozen = try self.workSnapshot(next.receipt, index);
        }
    }
};
