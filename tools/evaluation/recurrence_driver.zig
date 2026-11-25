const std = @import("std");
const native = @import("protean_native");
const environment = @import("environment");
const types = @import("application_types");
const C = @import("protean_contracts");
const State = native.testing.state;
const Worker = native.testing.Worker;
const Service = native.tasks.Service(types);
const Json = native.json;
const acquisition = @import("recurrence_acquisition.zig");
const presentation = @import("recurrence_presentation.zig");
const repair = @import("interface_repair_driver.zig");
const ordinary_assets: native.discovery.Assets = .{
    .image = @embedFile("native_image"),
    .application = @embedFile("native_application"),
    .manifest = @embedFile("native_manifest"),
};

const study_assets: native.discovery.Assets = .{
    .image = @embedFile("study_image"),
    .application = @embedFile("study_application"),
    .manifest = @embedFile("study_manifest"),
};

const Options = struct {
    state_path: []const u8,
    profile_task: ?[16]u8 = null,
    fixture_workspace: bool = false,
    bootstrap_digest: ?[32]u8 = null,
    bootstrap_source: ?[]const u8 = null,
    configuration: native.configuration.Options = .{ .offline = false },

    fn parse(init: std.process.Init) !Options {
        var result: Options = .{ .state_path = "" };
        result.configuration.scratch_allocator = init.gpa;
        result.configuration.home = init.environ_map.get("HOME");
        result.configuration.path = init.environ_map.get("PATH");
        var args = init.minimal.args.iterate();
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--offline")) {
                result.configuration.offline = true;
            } else if (std.mem.eql(u8, arg, "--fixture-workspace")) {
                result.fixture_workspace = true;
            } else if (std.mem.eql(u8, arg, "--authorize-inference")) {
                result.configuration.require_source = true;
            } else {
                const value = args.next() orelse return error.InvalidArguments;
                if (std.mem.eql(u8, arg, "--state-dir")) {
                    result.state_path = value;
                } else if (std.mem.eql(u8, arg, "--config")) {
                    result.configuration.config_path = value;
                } else if (std.mem.eql(u8, arg, "--credential-file")) {
                    result.configuration.credential_path = value;
                } else if (std.mem.eql(u8, arg, "--chatgpt-account")) {
                    result.configuration.chatgpt_account = value;
                } else if (std.mem.eql(u8, arg, "--siwc-bin")) {
                    result.configuration.siwc_bin = value;
                } else if (std.mem.eql(u8, arg, "--siwc-auth-dir")) {
                    result.configuration.siwc_auth_dir = value;
                } else if (std.mem.eql(u8, arg, "--profile-task")) {
                    result.profile_task = try native.client.identifier(16, Json.string(value));
                } else if (std.mem.eql(u8, arg, "--interface-repair-source")) {
                    result.bootstrap_source = value;
                } else if (std.mem.eql(u8, arg, "--interface-repair-bootstrap")) {
                    result.bootstrap_digest = try native.client.identifier(32, Json.string(value));
                } else return error.InvalidArguments;
            }
        }
        if (result.state_path.len == 0) return error.InvalidArguments;
        if (result.fixture_workspace) {
            if (!result.configuration.offline or result.configuration.config_path == null)
                return error.OfflineFixtureRequired;
            result.configuration.offline = false;
            result.configuration.test_provider = true;
            result.configuration.trust_root_path = result.configuration.config_path;
        }
        if (!result.configuration.offline and !result.configuration.require_source and
            !result.fixture_workspace)
            return error.InferenceNotAuthorized;
        return result;
    }
};

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    native.Sha256.hash(bytes, &result, .{});
    return result;
}

fn executableIdentity(a: std.mem.Allocator, io: std.Io) ![32]u8 {
    const file = try std.process.openExecutable(io, .{});
    defer file.close(io);
    const before = try file.stat(io);
    const bytes = try a.alloc(u8, std.math.cast(usize, before.size) orelse return error.Capacity);
    defer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try file.readStreaming(io, &.{bytes[offset..]});
        if (count == 0) return error.NativeArtifactChanged;
        offset += count;
    }
    const after = try file.stat(io);
    if (before.inode != after.inode or before.size != after.size or
        !std.meta.eql(before.mtime, after.mtime) or
        !std.meta.eql(before.ctime, after.ctime)) return error.NativeArtifactChanged;
    return native.testing.digest(bytes);
}

fn initialProfile(
    a: std.mem.Allocator,
    io: std.Io,
    handlers: native.Registry,
) !native.tasks.Profile {
    const grants = try a.alloc(native.registry.Grant, handlers.entries.len);
    for (grants, handlers.entries) |*grant, entry| grant.* = .{
        .identity = entry.declaration.identity,
        .resource_role = entry.declaration.resource_role,
        .resource_identity = @splat(0),
    };
    return .{
        .id = "offline",
        .runtime_identity = try executableIdentity(a, io),
        .bytes = "{}",
        .authority = .{ .grants = grants, .principal = "evaluation", .tenant = "local" },
    };
}

fn configure(
    a: std.mem.Allocator,
    io: std.Io,
    service: *Service,
    options: Options,
    application: *native.discovery.Application,
) !void {
    const frozen = if (options.profile_task) |task| try service.frozenInputs(a, task) else null;
    const admitted = try environment.configure(
        a,
        io,
        options.configuration,
        frozen,
        service.assets,
    );
    errdefer if (admitted.environment) |owner| environment.release(owner);
    if (frozen) |saved| {
        if (!std.mem.eql(u8, saved.profile, admitted.bytes) or
            !std.mem.eql(u8, saved.profile_id, admitted.id)) return error.IncompatibleProfile;
    }
    service.profile.id = admitted.id;
    service.profile.bytes = admitted.bytes;
    service.profile.resources = admitted.resources;
    service.profile.environment = admitted.environment;
    service.profile.semantic_construction = admitted.semantic_construction;
    service.profile.authority.inference = options.configuration.offline or
        options.configuration.require_source or options.fixture_workspace;
    const identity = try service.profile.resourceIdentity(a, application.image_identity);
    for (@constCast(service.profile.authority.grants)) |*grant| grant.resource_identity = identity;
    try service.profile.validate();
    application.execution_mode = if (options.configuration.offline or options.fixture_workspace)
        .offline
    else
        .live;
}

pub const std_options = @import("zig_test_runner").std_options;

pub fn main(init: std.process.Init) void {
    if (@import("builtin").test_functions.len == 1 and init.minimal.args.vector.len == 1) {
        if (init.environ_map.contains("PROTEAN_CRASH_MODE")) {
            return @import("zig_test_runner").main(init.minimal);
        }
    }
    run(init) catch |err| std.process.exit(native.reportFailure(err));
}

const Package = struct {
    assets: native.discovery.Assets,
    handlers: native.Registry,
    root: ?native.Registry,
    application: native.discovery.Application,

    fn open(a: std.mem.Allocator, study: bool) !Package {
        const assets = if (study) study_assets else ordinary_assets;
        var handlers = try native.Registry.init(a, &environment.handlers);
        errdefer handlers.deinit();
        var root = if (study)
            try native.Registry.init(a, &environment.studyDeclarations())
        else
            null;
        errdefer if (root) |*registry| registry.deinit();
        const application = try native.discovery.Application.init(
            types,
            a,
            assets,
            root orelse handlers,
        );
        if (root) |registry| handlers.admitted_root = .{
            .image = application.image_identity,
            .entries = registry.entries,
        };
        return .{
            .assets = assets,
            .handlers = handlers,
            .root = root,
            .application = application,
        };
    }
    fn close(self: *Package) void {
        self.application.deinit();
        if (self.root) |*registry| registry.deinit();
        self.handlers.deinit();
    }
};

fn preparationProfile(init: std.process.Init, a: std.mem.Allocator) !bool {
    var args = init.minimal.args.iterate();
    _ = args.next();
    if (!std.mem.eql(u8, args.next() orelse return false, "--interface-repair-profile"))
        return false;
    const path = args.next() orelse return error.InvalidArguments;
    const name = args.next() orelse return error.InvalidArguments;
    const route: native.responses_contract.Route = if (std.mem.eql(u8, name, "chatgpt"))
        .chatgpt_plan_sse
    else if (std.mem.eql(u8, name, "api-key")) .api_key_json else return error.InvalidArguments;
    const auth_dir = args.next();
    if (args.next() != null) return error.InvalidArguments;
    const roots = try native.configuration.ProtectedRoots.init(
        a,
        init.io,
        init.environ_map.get("HOME"),
        auth_dir,
    );
    const source = try environment.readConfiguration(a, init.io, path, roots);
    const c = source.value.adaptive;
    const tools = source.value.tools orelse return error.MissingConstructionPermission;
    if (!tools.build or !tools.run) return error.MissingConstructionPermission;
    var selected: ?types.model.AdaptiveInferenceProfile = null;
    for (c.profiles.items) |p| {
        if (!std.mem.eql(u8, p.id.bytes, c.initial_profile.bytes)) continue;
        if (selected != null) return error.InvalidConfiguration;
        try native.adaptive_responses.Admission(types.P).validateProfile(c.endpoint.bytes, p);
        try native.responses_contract.admitProfile(route, p);
        if (std.mem.indexOfScalar(
            @TypeOf(c.initial_effort),
            p.efforts.items,
            c.initial_effort,
        ) == null) return error.UnsupportedEffort;
        selected = p;
    }
    const profile = selected orelse return error.UnknownInferenceProfile;
    const output = .{
        .schema = source.value.schema,
        .adaptive = .{
            .workspace = c.workspace,
            .endpoint = c.endpoint,
            .audience = c.audience,
            .profiles = @as(@TypeOf(c.profiles), .{ .items = &.{profile} }),
            .initial_profile = c.initial_profile,
            .initial_effort = c.initial_effort,
        },
        .tools = .{ .build = tools.build, .run = tools.run },
    };
    try emit(init.io, try native.values.toJson(@TypeOf(output), a, output));
    return true;
}

fn run(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (try preparationProfile(init, a)) return;
    const options = try Options.parse(init);
    var package = try Package.open(init.gpa, options.bootstrap_digest != null);
    defer package.close();
    const application = &package.application;
    const handlers = package.handlers;
    var namespace = try native.Namespace.open(init.gpa, init.io, options.state_path);
    defer namespace.close() catch |err| std.debug.panic("namespace: {t}", .{err});
    var service = try Service.init(
        init.gpa,
        init.io,
        &namespace,
        package.assets,
        application,
        handlers,
        try initialProfile(a, init.io, handlers),
    );
    var environment_owner: ?*anyopaque = null;
    defer if (environment_owner) |owner| environment.release(owner);
    defer service.close(init.gpa) catch |err| std.debug.panic("service: {t}", .{err});
    try configure(a, init.io, &service, options, application);
    environment_owner = service.profile.environment;
    const worker = try Worker.init(init.gpa, init.io);
    defer worker.deinit(init.gpa) catch |err| std.debug.panic("worker: {t}", .{err});
    var driver: Driver = .{
        .service = &service,
        .client = .{ .service = &service },
        .worker = worker,
        .fixture_workspace = options.fixture_workspace,
        .repair_session = .{
            .expected = options.bootstrap_digest,
            .source_path = options.bootstrap_source,
        },
    };
    if (options.profile_task) |task| try driver.repair_session.restore(&service, a, task);
    try driver.serve(init.gpa, init.io);
}

fn jsonValue(a: std.mem.Allocator, input: anytype) !Json.Value {
    const bytes = try std.json.Stringify.valueAlloc(a, input, .{});
    return (try std.json.parseFromSlice(
        Json.Value,
        a,
        bytes,
        .{ .allocate = .alloc_always },
    )).value;
}

fn hexadecimal(a: std.mem.Allocator, bytes: anytype) !Json.Value {
    return Json.string(try a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower)));
}

fn field(input: Json.Value, name: []const u8) !Json.Value {
    return Json.get(input, name) orelse error.InvalidParams;
}

fn unsigned(input: Json.Value) !u64 {
    return switch (input) {
        .integer => |integer| std.math.cast(u64, integer) orelse error.InvalidParams,
        .number_string => |text| Json.numberInteger(u64, text),
        .string => Json.decimal(u64, input),
        else => error.InvalidParams,
    };
}

fn base64(a: std.mem.Allocator, bytes: []const u8) !Json.Value {
    const encoder = std.base64.standard.Encoder;
    const output = try a.alloc(u8, encoder.calcSize(bytes.len));
    return Json.string(encoder.encode(output, bytes));
}

const Driver = struct {
    const RecordIdentity = struct { kind: State.RecordKind, body: [32]u8, acquisition: bool };
    service: *Service,
    client: native.client.Client(types),
    worker: *Worker,
    fixture_workspace: bool = false,
    repair_session: repair.Session = .{},
    paused: bool = false,
    completed: ?struct { task: [16]u8, attempt: [32]u8 } = null,
    seen: std.AutoHashMapUnmanaged(RecordIdentity, void) = .empty,

    fn serve(self: *Driver, a: std.mem.Allocator, io: std.Io) !void {
        defer self.seen.deinit(a);
        const input_buffer = try a.alloc(u8, 1024 * 1024);
        defer a.free(input_buffer);
        var input = std.Io.File.stdin().reader(io, input_buffer);
        while (try input.interface.takeDelimiter('\n')) |line| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const frame = arena.allocator();
            const request = try Json.parse(frame, line, .{});
            const id = try field(request.value, "id");
            var reply = Json.object();
            try Json.put(frame, &reply, "id", id);
            const result = self.call(frame, request.value) catch |err| {
                try Json.put(frame, &reply, "error", try jsonValue(frame, .{
                    .message = @errorName(err),
                }));
                try emit(io, reply);
                continue;
            };
            try Json.put(frame, &reply, "result", result);
            try emit(io, reply);
        }
        if (self.worker.future == null and self.worker.result != null) _ = try self.finishWorker(a);
        if (self.worker.future != null or self.service.work != null) return error.WorkerOutstanding;
    }

    fn call(self: *Driver, a: std.mem.Allocator, request: Json.Value) !Json.Value {
        const method = try Json.text(try field(request, "method"));
        const params = Json.get(request, "params") orelse Json.object();
        if (std.mem.eql(u8, method, "evaluation.interface_repair.sources"))
            return self.preparationAssets(a, params, false);
        if (std.mem.eql(u8, method, "evaluation.interface_repair.assets"))
            return self.preparationAssets(a, params, true);
        if (std.mem.eql(u8, method, "evaluation.observe")) return self.observe(a, params);
        if (std.mem.eql(u8, method, "evaluation.export")) return self.exportTask(a, params);
        if (std.mem.eql(u8, method, "evaluation.pause")) return self.pause(a, params);
        if (self.paused) return error.EvaluationPaused;
        if (std.mem.eql(u8, method, "evaluation.interface_repair.admission"))
            return self.repair_session.admission(self.service, a, params);
        if (std.mem.eql(u8, method, "evaluation.interface_repair.bootstrap"))
            return self.repair_session.bootstrap(self.service, self.worker, a, params, .complete);
        if (std.mem.eql(u8, method, "evaluation.interface_repair.fixture_select")) {
            if (!self.fixture_workspace) return error.OfflineFixtureRequired;
            var input = params;
            if (input != .object) return error.InvalidParams;
            const cut: repair.Cut = if (input.object.fetchOrderedRemove("stop_after")) |item|
                try native.values.fromJson(repair.Cut, a, item.value)
            else
                .selection;
            return self.repair_session.bootstrap(self.service, self.worker, a, input, cut);
        }
        if (std.mem.eql(u8, method, "evaluation.interface_repair.fixture"))
            return self.repairFixture(a, params, false);
        if (std.mem.eql(u8, method, "evaluation.interface_repair.answer"))
            return self.repairFixture(a, params, true);
        if (std.mem.eql(u8, method, "evaluation.fixture")) {
            if (self.repair_session.expected != null) return error.OfflineFixtureRequired;
            if (self.service.application.execution_mode != .offline)
                return error.OfflineFixtureRequired;
            if (self.worker.future != null or self.service.work != null)
                return error.WorkerOutstanding;
            const task = try native.client.identifier(16, try field(params, "task_id"));
            return @import("recurrence_fixture.zig").run(
                self.service,
                self.worker,
                a,
                task,
                try self.fixtureOptions(a, params),
            );
        }
        if (std.mem.eql(u8, method, "evaluation.step")) return self.step(a);
        if (std.mem.eql(u8, method, "evaluation.drain")) return self.drain(a);
        if (std.mem.eql(u8, method, "describe")) return self.service.application.describe(
            a,
            params,
            .{
                .id = self.service.profile.id,
                .sha256 = digest(self.service.profile.bytes),
                .resource_identity = try self.service.profile.resourceIdentity(
                    a,
                    self.service.application.image_identity,
                ),
            },
        );
        const selected = std.meta.stringToEnum(native.protocol.Method, method) orelse
            return error.MethodNotFound;
        if (selected == .@"task.submit") try self.checkSubmission(a, params);
        return self.client.call(a, selected, params);
    }

    fn checkSubmission(self: *Driver, a: std.mem.Allocator, params: Json.Value) !void {
        const task = self.repair_session.task orelse return;
        const operation = try Json.text(try field(params, "client_operation_id"));
        var prior = (try self.service.operationLookup(a, operation)) orelse
            return error.PlannedTaskRequired;
        defer prior.deinit();
        if (prior.value.method != .submit or !std.meta.eql(prior.value.task, task))
            return error.PlannedTaskRequired;
    }

    fn exportTask(self: *Driver, a: std.mem.Allocator, params: Json.Value) !Json.Value {
        const task = try native.client.identifier(16, try field(params, "task_id"));
        const path = try Json.text(try field(params, "path"));
        const exported = try self.service.exportCheckpoint(a, task, path);
        var result = try self.boundary(a, "exported");
        try Json.put(a, &result, "sha256", try hexadecimal(a, exported.sha256));
        try Json.put(a, &result, "bytes", try Json.number(a, exported.bytes));
        return result;
    }

    fn repairFixture(
        self: *Driver,
        a: std.mem.Allocator,
        params: Json.Value,
        downstream: bool,
    ) !Json.Value {
        if (!self.fixture_workspace or self.service.application.execution_mode != .offline)
            return error.OfflineFixtureRequired;
        if (self.worker.future != null or self.service.work != null)
            return error.WorkerOutstanding;
        const controlled = @import("interface_repair_fixture.zig");
        if (!self.repair_session.ready) return error.BootstrapRequired;
        if (self.repair_session.fixture_used or params != .object or params.object.count() != 2)
            return error.InvalidParams;
        const task = try native.client.identifier(16, try field(params, "task_id"));
        var parent = try self.service.task(a, task);
        defer parent.deinit();
        if (parent.value.inference_attempts != 0) return error.InitialCutRequired;
        if (downstream) {
            if (!std.meta.eql(@as(?[16]u8, task), self.repair_session.downstream_task))
                return error.InvalidParams;
            const summary = try Json.text(try field(params, "summary"));
            self.repair_session.fixture_used = true;
            return controlled.answer(self.service, self.worker, a, task, summary);
        }
        const setup = self.repair_session.selected orelse return error.BootstrapRequired;
        if (self.repair_session.downstream_task != null) return error.InvalidParams;
        const input = try native.values.fromJson(C.workspace.Ref, a, try field(
            params,
            "canonical_input",
        ));
        if (!std.meta.eql(task, setup.task) or input.kind != .value or
            !std.mem.eql(u8, input.id.bytes, &setup.input)) return error.InvalidCanonicalInput;
        self.repair_session.fixture_used = true;
        return controlled.run(self.service, self.worker, a, task, input);
    }

    fn preparationAssets(
        self: *Driver,
        a: std.mem.Allocator,
        params: Json.Value,
        metadata: bool,
    ) !Json.Value {
        if (self.service.application.execution_mode != .offline)
            return error.OfflineFixtureRequired;
        if (params != .object or params.object.count() != 0) return error.InvalidParams;
        const tasks = try self.service.namespace.store.taskIds(a, false);
        defer a.free(tasks);
        if (tasks.len != 0) return error.PreparationNamespaceRequired;
        var result = Json.object();
        if (metadata) {
            if (self.repair_session.expected != null) return error.PreparationNamespaceRequired;
            var parsed = try Json.parseAsset(a, study_assets.manifest, study_assets.manifest.len);
            defer parsed.deinit();
            try Json.put(a, &result, "application", Json.string(study_assets.application));
            try Json.put(a, &result, "build", try Json.copy(a, parsed.value));
            return result;
        }
        const sources = @import("interface_repair_sources");
        inline for (.{ sources.Seed.lossy, .adequate }) |kind|
            try Json.put(a, &result, @tagName(kind), Json.string(try sources.seed(a, kind)));
        return result;
    }

    fn fixtureOptions(
        self: *Driver,
        a: std.mem.Allocator,
        params: Json.Value,
    ) !@import("recurrence_fixture.zig").Options {
        const delegated = if (Json.get(params, "delegated")) |value|
            try native.values.fromJson(bool, a, value)
        else
            false;
        if (delegated and !self.fixture_workspace) return error.OfflineFixtureRequired;
        if (Json.get(params, "value") != null and !delegated) return error.InvalidParams;
        return .{
            .delegated = delegated,
            .reject_action = if (Json.get(params, "reject_action")) |value|
                try native.values.fromJson(bool, a, value)
            else
                false,
            .value = if (Json.get(params, "value")) |value|
                try native.values.fromJson(C.workspace.Ref, a, value)
            else
                null,
            .packet = if (Json.get(params, "packet")) |value|
                try Json.text(value)
            else
                "Native delegated fixture packet.",
        };
    }

    fn boundary(self: *Driver, a: std.mem.Allocator, name: []const u8) !Json.Value {
        _ = try self.service.namespace.store.publicationEpoch();
        const head = self.service.namespace.store.head;
        var result = try jsonValue(a, .{
            .step = name,
            .worker_active = self.service.work != null,
            .epoch = head.generation,
        });
        var publication = Json.object();
        try Json.put(a, &publication, "generation", try Json.number(a, head.generation));
        try Json.put(a, &publication, "parent", try hexadecimal(a, head.parent));
        try Json.put(a, &publication, "digest", try hexadecimal(a, head.digest));
        try Json.put(a, &result, "head", publication);
        return result;
    }

    fn finishWorker(self: *Driver, a: std.mem.Allocator) !bool {
        if (self.worker.future != null) {
            if (try self.service.shouldCancelWork(self.worker.work)) self.worker.cancel();
            if (!self.worker.finished()) return false;
            try self.worker.join();
        } else if (self.worker.result == null) {
            if (self.service.work != null) return error.MissingWorkerResult;
            return false;
        }
        const work = self.worker.work;
        try repair.publishJoined(self.service, self.worker, a, false);
        self.completed = .{ .task = work.task, .attempt = work.attempt };
        return true;
    }

    fn drain(self: *Driver, a: std.mem.Allocator) !Json.Value {
        if (try self.finishWorker(a)) return self.boundary(a, "captured");
        return self.boundary(a, if (self.worker.future == null) "idle" else "pending");
    }

    fn step(self: *Driver, a: std.mem.Allocator) !Json.Value {
        if (try self.finishWorker(a)) return self.boundary(a, "captured");
        if (self.worker.future != null) return self.boundary(a, "pending");
        if (self.repair_session.expected != null and !self.repair_session.ready) {
            try self.repair_session.prepare(self.service, self.worker, a, .complete);
            return self.boundary(a, "bootstrap_ready");
        }
        const next = try self.service.pump(a);
        if (next == .work) {
            if (self.repair_session.task) |task| {
                if (!std.meta.eql(task, next.work.task)) {
                    try self.service.notSent(a, next.work);
                    return error.PlannedTaskRequired;
                }
            }
            if (self.fixture_workspace and next.work.entry.declaration.inference) {
                try self.service.notSent(a, next.work);
                return error.ScriptedFixtureOnly;
            }
            self.worker.start(
                next.work,
                self.service.profile.authority,
                self.service.profile.environment,
            ) catch |err| {
                try self.service.notSent(a, next.work);
                return err;
            };
            var result = try self.boundary(a, "dispatched");
            try Json.put(a, &result, "attempt", try hexadecimal(a, next.work.attempt));
            try Json.put(a, &result, "task", try hexadecimal(a, next.work.task));
            try Json.put(
                a,
                &result,
                "capability",
                Json.string(next.work.entry.declaration.identity),
            );
            return result;
        }
        return self.boundary(a, @tagName(next));
    }

    fn attempt(self: *Driver, a: std.mem.Allocator, task: [16]u8, id: [32]u8) !Json.Value {
        const store = &self.service.namespace.store;
        const bytes = (try store.recordBytes(a, "attempt", id, task)) orelse
            return error.MissingAttempt;
        const decoded = try C.decodeOwned(State.Attempt, a, bytes);
        var result = Json.object();
        try Json.put(a, &result, "attempt_b64", try base64(a, bytes));
        const occurrence_bytes = (try store.recordBytes(
            a,
            "occurrence",
            decoded.value.occurrence,
            task,
        )) orelse return error.MissingOccurrence;
        try Json.put(a, &result, "occurrence_b64", try base64(a, occurrence_bytes));
        if (decoded.value.prepared) |reference| {
            const prepared = try store.object(a, reference, null);
            try Json.put(a, &result, "prepared_b64", try base64(a, prepared));
            const delegated = std.mem.eql(
                u8,
                decoded.value.capability.bytes,
                native.workspace_instrument.model_identity,
            );
            if (delegated)
                try Json.put(a, &result, "prepared_context", try delegatedContext(a, prepared));
        }
        if (try store.recordBytes(a, "capture", id, task)) |capture_bytes| {
            const capture = try C.decodeOwned(State.Capture, a, capture_bytes);
            try Json.put(a, &result, "capture_b64", try base64(a, capture_bytes));
            if (capture.value.response) |reference|
                try Json.put(
                    a,
                    &result,
                    "response_b64",
                    try base64(a, try store.object(a, reference, null)),
                );
        }
        return result;
    }

    fn delegatedContext(a: std.mem.Allocator, bytes: []const u8) !Json.Value {
        var prepared = try C.decodeOwned(native.workspace_instrument.Prepared, a, bytes);
        defer prepared.deinit();
        var result = Json.object();
        try Json.put(a, &result, "body_b64", try base64(a, prepared.value.body.bytes));
        try Json.put(a, &result, "selected_view", if (prepared.value.selected_view) |view|
            try hexadecimal(a, view.digest)
        else
            .null);
        return result;
    }

    fn observe(self: *Driver, a: std.mem.Allocator, params: Json.Value) !Json.Value {
        const task = try native.client.identifier(16, try field(params, "task_id"));
        const after = if (Json.get(params, "after")) |v| try unsigned(v) else 0;
        const sources = if (Json.get(params, "acquisition")) |value|
            try native.values.fromJson(bool, a, value)
        else
            false;
        var events: std.array_list.Managed(Json.Value) = .init(a);
        var attempts: std.array_list.Managed(Json.Value) = .init(a);
        var cursor = after;
        const records = try self.service.namespace.store.eventsAfter(a, task, after, 128);
        for (records) |bytes| {
            const event = try C.decodeOwned(State.Event, a, bytes);
            cursor = event.value.seq;
            var event_record = Json.object();
            try Json.put(a, &event_record, "record_b64", try base64(a, bytes));
            try events.append(event_record);
            if (event.value.preparation_attempt) |reference| {
                const body = try self.service.namespace.store.object(a, reference, null);
                const attempt_value = try C.decodeOwned(State.Attempt, a, body);
                try attempts.append(try self.attempt(a, task, attempt_value.value.id));
            }
        }
        if (self.completed) |completed| {
            if (std.meta.eql(completed.task, task)) {
                try attempts.append(try self.attempt(a, task, completed.attempt));
                self.completed = null;
            }
        }
        var result = try self.boundary(a, "observed");
        if (self.repair_session.expected != null) try Json.put(
            a,
            &result,
            "bootstrap_build_metrics",
            try self.repair_session.buildMetrics(a, task),
        );
        try Json.put(a, &result, "events", .{ .array = events });
        try Json.put(a, &result, "attempts", .{ .array = attempts });
        try Json.put(a, &result, "cursor", try Json.number(a, cursor));
        try Json.put(a, &result, "records", try self.workspaceRecords(a, task, sources));
        if (sources) {
            try Json.put(a, &result, "acquisition_records_complete", .{ .bool = true });
            try Json.put(a, &result, "question_producer", try acquisition.questionProducer(
                self.service,
                a,
                task,
            ));
            try Json.put(a, &result, "report_producer", try acquisition.reportProducer(
                self.service,
                a,
                task,
            ));
        }
        return result;
    }

    fn workspaceRecords(
        self: *Driver,
        a: std.mem.Allocator,
        task: [16]u8,
        sources: bool,
    ) !Json.Value {
        const store = &self.service.namespace.store;
        var query = try store.database.prepare(
            "SELECT kind,id,body FROM records WHERE task=? AND kind IN " ++
                "('workspace_program','workspace_work','workspace_value','workspace_view'," ++
                "'controller_interaction') AND (kind <> 'controller_interaction' OR ?) " ++
                "ORDER BY kind,id",
            &.{ .{ .blob = &task }, .{ .integer = @intFromBool(sources) } },
        );
        defer query.deinit();
        var records: std.array_list.Managed(Json.Value) = .init(a);
        while (try query.step() == .row) {
            const kind = try a.dupe(u8, try query.bytes(0));
            const id = try query.bytes(1);
            const body = try query.bytes(2);
            if (id.len != 32 or body.len != 32) return error.CorruptState;
            const identity = body[0..32].*;
            const key: RecordIdentity = .{
                .kind = std.meta.stringToEnum(State.RecordKind, kind) orelse
                    return error.CorruptState,
                .body = identity,
                .acquisition = sources,
            };
            if (self.seen.contains(key)) continue;
            const bytes = try store.object(a, try store.objectReference(identity, null), null);
            var record = Json.object();
            try Json.put(a, &record, "kind", Json.string(kind));
            try Json.put(a, &record, "body", try hexadecimal(a, identity));
            try Json.put(a, &record, "record_b64", try base64(a, bytes));
            if (key.kind == .workspace_view)
                try Json.put(a, &record, "projection_blocks", try self.projectionBlocks(a, bytes));
            if (sources and key.kind == .workspace_program and
                self.repair_session.expected != null)
            {
                var program = try C.decodeOwned(native.workspace.Program, a, bytes);
                defer program.deinit();
                try Json.put(a, &record, "pure", .{
                    .bool = try repair.programPure(self.service, a, program.value.description),
                });
            }
            if (sources and key.kind == .workspace_value) {
                try Json.put(a, &record, "native_derivation", try acquisition.derivation(a, bytes));
                try Json.put(a, &record, "native_acquisition", try presentation.judgment(
                    self.service,
                    a,
                    bytes,
                ));
            }
            if (key.kind == .controller_interaction)
                try Json.put(a, &record, "acquisition", try acquisition.interaction(
                    self.service,
                    a,
                    bytes,
                ));
            try records.append(record);
            if (cacheRecord(record)) try self.seen.put(self.service.allocator, key, {});
        }
        return .{ .array = records };
    }

    fn cacheRecord(record: Json.Value) bool {
        if (Json.get(record, "acquisition")) |value| {
            const exposure = Json.get(value, "exposure") orelse return false;
            const status = Json.get(exposure, "status") orelse return false;
            if (status == .string and std.mem.eql(u8, status.string, "unknown")) return false;
        }
        if (Json.get(record, "native_acquisition")) |value| {
            if (value != .null) {
                const complete = Json.get(value, "complete") orelse return false;
                if (complete != .bool or !complete.bool) return false;
            }
        }
        return true;
    }

    fn projectionBlocks(self: *Driver, a: std.mem.Allocator, bytes: []const u8) !Json.Value {
        var view = try C.decodeOwned(native.workspace.View, a, bytes);
        defer view.deinit();
        const projection = view.value.description.projection orelse return .null;
        const store = &self.service.namespace.store;
        var result = try C.decodeOwned(
            native.workspace.ValueArtifact,
            a,
            try store.object(a, projection.result, null),
        );
        defer result.deinit();
        var decoded = try native.projection_proposal.decodeResult(
            a,
            try store.object(a, result.value.schema, null),
            try store.object(a, result.value.value, null),
        );
        defer decoded.deinit();
        return native.values.toJson(
            @TypeOf(decoded.header.blocks),
            a,
            decoded.header.blocks,
        );
    }

    fn pause(self: *Driver, a: std.mem.Allocator, params: Json.Value) !Json.Value {
        const expected = try unsigned(try field(params, "epoch"));
        _ = try self.service.namespace.store.publicationEpoch();
        if (expected != self.service.namespace.store.head.generation) return error.StaleBoundary;
        if (self.worker.future != null or self.service.work != null) return error.WorkerOutstanding;
        var query = try self.service.namespace.store.database.prepare(
            "SELECT r.id,r.task FROM records r WHERE r.kind='occurrence'",
            &.{},
        );
        defer query.deinit();
        while (try query.step() == .row) {
            const id = try query.bytes(0);
            const task = try query.bytes(1);
            if (id.len != 32 or task.len != 16) return error.CorruptState;
            const bytes = (try self.service.namespace.store.recordBytes(
                a,
                "occurrence",
                id[0..32].*,
                task[0..16].*,
            )) orelse return error.CorruptState;
            const occurrence = try C.decodeOwned(native.testing.occurrence.Occurrence, a, bytes);
            switch (occurrence.value.state) {
                .unknown, .dispatching => return error.UnsettledOccurrence,
                else => {},
            }
        }
        const result = try self.boundary(a, "sealed");
        self.paused = true;
        return result;
    }
};

fn emit(io: std.Io, reply: Json.Value) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try std.json.Stringify.value(reply, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
