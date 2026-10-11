//! One stdin reader and stdout writer; protocol admission grants no effects.
const std = @import("std");
const json = @import("json.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const discovery = @import("discovery.zig");
const client_api = @import("client.zig");
const tasks = @import("tasks.zig");
const Namespace = @import("namespace.zig").Namespace;
const transport_api = @import("transport.zig");
const Worker = @import("worker.zig").Worker;
const kronos = @import("kronos");
const c = @import("native_c");
const identity = @import("identity.zig");
const Shutdown = enum { park, cancel };

/// One bounded, nonblocking fatal diagnostic. Error names contain no request,
/// profile, credential, path or provider payload data.
pub fn reportFailure(err: anyerror) u8 {
    const flags = c.fcntl(c.STDERR_FILENO, c.F_GETFL);
    if (flags < 0 or c.fcntl(c.STDERR_FILENO, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return 74;
    defer _ = c.fcntl(c.STDERR_FILENO, c.F_SETFL, flags);
    var buffer: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "protean: {s}\n", .{@errorName(err)}) catch return 74;
    _ = c.write(c.STDERR_FILENO, message.ptr, message.len);
    return 74;
}

fn Connection(comptime Types: type) type {
    return struct {
        application: *const discovery.Application,
        instance: []const u8,
        artifact_identity: [32]u8,
        initialized: bool = false,
        closing: bool = false,
        shutdown: ?Shutdown = null,
        limits: protocol.Limits = .{},
        client: ?*client_api.Client(Types) = null,
        launch_profile: ?discovery.LaunchProfile = null,

        fn call(self: *@This(), a: std.mem.Allocator, request: protocol.Call) !json.Value {
            if (request.method == .initialize) {
                if (self.initialized) return protocol.failure(a, request.id, .ProtocolState, "correct_request");
                const versions = request.params.object.get("protocol_versions").?;
                if (versions != .array or versions.array.items.len == 0 or versions.array.items.len > 16)
                    return protocol.failure(a, request.id, .InvalidParams, "correct_request");
                var supported = false;
                for (versions.array.items) |version| {
                    if (version != .string or version.string.len > 128) return protocol.failure(a, request.id, .InvalidParams, "correct_request");
                    supported = supported or std.mem.eql(u8, version.string, protocol.version);
                }
                if (json.get(request.params, "client_info")) |info| {
                    protocol.closed(info, .{ .required = &.{ "name", "version" } }) catch
                        return protocol.failure(a, request.id, .InvalidParams, "correct_request");
                    for (info.object.values()) |value| if (value != .string or value.string.len > 128)
                        return protocol.failure(a, request.id, .InvalidParams, "correct_request");
                }
                if (!supported) {
                    self.closing = true;
                    var fault = try protocol.failure(a, request.id, .ProtocolState, "correct_request");
                    var versions_out: std.array_list.Managed(json.Value) = .init(a);
                    try versions_out.append(json.string(protocol.version));
                    const error_value = fault.object.getPtr("error").?;
                    try json.put(a, error_value.object.getPtr("data").?, "supported_versions", .{ .array = versions_out });
                    return fault;
                }
                self.initialized = true;
                var result = json.object();
                try json.put(a, &result, "protocol_version", json.string(protocol.version));
                try json.put(a, &result, "server_instance_id", json.string(self.instance));
                var info = json.object();
                try json.put(a, &info, "name", json.string("Protean native host"));
                try json.put(a, &info, "version", json.string("1.0.0-dev"));
                try json.put(a, &result, "server_info", info);
                try json.put(a, &result, "build_manifest_id", json.string(self.application.manifest_id));
                try json.put(a, &result, "native_artifact_sha256", json.string(try a.dupe(u8, &std.fmt.bytesToHex(self.artifact_identity, .lower))));
                const limits_bytes = try std.json.Stringify.valueAlloc(a, self.limits, .{});
                const limits = try json.parse(a, limits_bytes, .{});
                try json.put(a, &result, "limits", limits.value);
                var capabilities = json.object();
                var messages = false;
                if (self.client) |client| for (client.service.handlers.entries) |entry| {
                    messages = messages or entry.declaration.kind == .inbox;
                };
                try json.put(a, &capabilities, "task_events", .{ .bool = self.client != null });
                try json.put(a, &capabilities, "message_input", .{ .bool = messages });
                try json.put(a, &capabilities, "task_execution", .{ .bool = self.client != null });
                try json.put(a, &result, "capabilities", capabilities);
                return protocol.response(a, request.id, result);
            }
            if (!self.initialized) return protocol.failure(a, request.id, .ProtocolState, "correct_request");
            if (self.shutdown != null and (request.method == .@"task.submit" or request.method == .@"task.message" or request.method == .@"task.resume" or request.method == .@"task.respond"))
                return protocol.failure(a, request.id, .StateConflict, failureRecovery(.StateConflict));
            switch (request.method) {
                .shutdown => {
                    const text = json.text(request.params.object.get("mode").?) catch return protocol.failure(a, request.id, .InvalidParams, "correct_request");
                    const mode = std.meta.stringToEnum(Shutdown, text) orelse return protocol.failure(a, request.id, .InvalidParams, "correct_request");
                    if (self.shutdown != null and self.shutdown.? != mode) return protocol.failure(a, request.id, .StateConflict, failureRecovery(.StateConflict));
                    self.shutdown = mode;
                    var result = json.object();
                    try json.put(a, &result, "mode", json.string(@tagName(mode)));
                    try json.put(a, &result, "accepted", .{ .bool = true });
                    return protocol.response(a, request.id, result);
                },
                .ping => {
                    var result = json.object();
                    try json.put(a, &result, "server_instance_id", json.string(self.instance));
                    return protocol.response(a, request.id, result);
                },
                .describe => {
                    const launch = if (self.client) |client|
                        if (!client.service.profile.authority.revoked and client.service.profile.authority.disclosure) self.launch_profile else null
                    else
                        null;
                    const result = self.application.describe(a, request.params, launch) catch |err| return protocol.failure(a, request.id, failureKind(err), failureRecovery(failureKind(err)));
                    return protocol.response(a, request.id, result);
                },
                .@"artifact.read" => if (self.client == null and json.get(request.params, "task_id") == null) {
                    // Discovery-only launch authorizes only the same immutable
                    // public schemas as describe, never task/private artifacts.
                    const result = self.application.readSchemaArtifact(a, request.params) catch |err| return protocol.failure(a, request.id, failureKind(err), failureRecovery(failureKind(err)));
                    return protocol.response(a, request.id, result);
                },
                else => {},
            }
            const client = self.client orelse return protocol.failure(a, request.id, .UnsupportedCapability, "correct_request");
            const result = client.call(a, request.method, request.params) catch |err| {
                const kind = failureKind(err);
                if (kind == .CursorExpired) {
                    const range = client.cursorRange(a, request.params) catch |range_error| return protocol.failure(a, request.id, failureKind(range_error), failureRecovery(failureKind(range_error)));
                    var failure = try protocol.failure(a, request.id, kind, "read_status_or_result");
                    const details = failure.object.getPtr("error").?.object.getPtr("data").?;
                    try json.put(a, details, "earliest_available_seq", json.string(try std.fmt.allocPrint(a, "{d}", .{range.first})));
                    try json.put(a, details, "high_water_seq", json.string(try std.fmt.allocPrint(a, "{d}", .{range.last})));
                    return failure;
                }
                return protocol.failure(a, request.id, kind, failureRecovery(kind));
            };
            return protocol.response(a, request.id, result);
        }

        fn member(self: *@This(), a: std.mem.Allocator, value: json.Value, batch: bool) !?json.Value {
            return switch (protocol.admit(value, self.limits, batch)) {
                .notification => null,
                .failure => |fault| try protocol.failure(a, fault.id, fault.kind, "correct_request"),
                .call => |request| try self.call(a, request),
            };
        }

        fn frame(self: *@This(), a: std.mem.Allocator, value: json.Value) !?json.Value {
            if (self.client) |client| client.batch = value == .array;
            if (value != .array) return self.member(a, value, false);
            protocol.batchPreflight(value.array.items, self.limits) catch |err| {
                if (err == error.DuplicateId) self.closing = true;
                return try protocol.failure(a, .null, .InvalidRequest, "correct_request");
            };
            var results: std.array_list.Managed(json.Value) = .init(a);
            for (value.array.items) |item| if (try self.member(a, item, true)) |result| try results.append(result);
            return if (results.items.len == 0) null else .{ .array = results };
        }
    };
}

fn failureRecovery(kind: protocol.Kind) []const u8 {
    // Projection/encoding can fail after an admission has committed. Capacity
    // or internal failure is therefore not proof that a new operation is safe.
    return switch (kind) {
        .StorageUnavailable, .Overloaded, .InternalError => "retry_same_operation_or_inspect",
        else => "correct_request",
    };
}

fn failureKind(err: anyerror) protocol.Kind {
    return switch (err) {
        error.Denied, error.UnknownTask, error.NotFound => .NotFound,
        error.OperationConflict => .OperationConflict,
        error.StaleInteraction, error.QuestionMismatch => .StaleInteraction,
        error.AnswerConflict => .AnswerConflict,
        error.CursorExpired => .CursorExpired,
        error.Capacity, error.OutOfMemory, error.Overloaded => .Overloaded,
        error.TerminalTask, error.StaleRevision, error.UnsettledOccurrence, error.IncompatibleProfile, error.ShuttingDown, error.NonPortable, error.NonEmptyNamespace, error.AlreadyExists => .StateConflict,
        error.MissingArtifact, error.ArtifactUnavailable => .ArtifactUnavailable,
        error.UnsupportedCapability => .UnsupportedCapability,
        error.StorageUnavailable, error.CorruptState => .StorageUnavailable,
        error.InvalidParams, error.InvalidValue, error.InvalidJson, error.Overflow, error.InvalidCharacter, error.InvalidArchive, error.UnsafeStatePath => .InvalidParams,
        else => .InternalError,
    };
}

pub fn run(comptime Types: type, comptime Environment: type, init: std.process.Init, assets: discovery.Assets) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse "--help";
    if (std.mem.eql(u8, command, "--help")) {
        if (args.next() != null) return 64;
        if (comptime @hasDecl(Environment, "configure")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Configured application commands:\nvalidate --config FILE\nrun --config FILE --task TEXT --state-dir PATH --authorize-inference --credential-file FILE\nserve --transport stdio --config FILE --state-dir PATH [--authorize-inference --credential-file FILE]\nresume --state-dir PATH [--task-id ID] [--config FILE] [--authorize-inference --credential-file FILE]\nUse --profile-task ID with serve to restore that task's frozen profile and snapshot.\nAn explicit --trust-root DER_FILE selects a TLS trust root. Credentials are never discovered.\n--test-provider selects loopback HTTPS with a built-in non-secret token; it requires --trust-root and rejects --credential-file.\nStatus/result read saved task data without loading execution configuration.\nOffline mode uses embedded deterministic fixtures and requires --offline.\n\n");
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "Protean native application\n\n--help\ndescribe-build\nlicenses\ndemo --offline --state-dir PATH\nserve --transport stdio --offline [--state-dir PATH]\nstatus|result|resume|cancel --offline --state-dir PATH [--task-id ID]\nrun --offline --state-dir PATH --input-json JSON [--operation-id ID]\nrespond --offline --state-dir PATH --task-id ID --question-id ID --question-revision N --request-digest SHA256 --answer-json JSON [--operation-id ID]\nexport-checkpoint --offline --state-dir PATH [--task-id ID] --output FILE\nimport-checkpoint --offline --state-dir NEW_PATH --input FILE [--operation-id ID]\n\nA state directory enables durable tasks. Without it, serve provides discovery only.\nTask selection is required when more than one applicable task exists.\nWith --operation-id, resume/cancel/respond require --task-id; resume also requires --expected-revision. Preserve those parameters on retries.\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "describe-build") or std.mem.eql(u8, command, "licenses")) {
        if (args.next() != null) return 64;
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const artifact = try identity.executable(init.io);
        var manifest = (try json.parse(a, assets.manifest, .{ .bytes = 256 * 1024 })).value;
        try json.put(a, &manifest, "artifact_sha256", json.string(try a.dupe(u8, &std.fmt.bytesToHex(artifact.sha256, .lower))));
        try json.put(a, &manifest, "artifact_bytes", json.string(try std.fmt.allocPrint(a, "{d}", .{artifact.bytes})));
        try json.put(a, &manifest, "embedded_manifest_sha256", json.string(try discovery.digest(a, assets.manifest)));
        var handlers = try registry.Registry.init(a, &Environment.handlers);
        defer handlers.deinit();
        var application = try discovery.Application.init(Types, a, assets, handlers);
        defer application.deinit();
        try json.put(a, &manifest, "protocol_schema_sha256", json.string(application.protocol_schema_sha256));
        try std.Io.File.stdout().writeStreamingAll(init.io, try json.canonical(a, manifest));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    const demo = std.mem.eql(u8, command, "demo");
    const serving = std.mem.eql(u8, command, "serve");
    const validating = std.mem.eql(u8, command, "validate");
    const human = std.meta.stringToEnum(HumanCommand, command);
    if (!demo and !serving and !validating and human == null) return 64;
    var offline = false;
    var test_provider = false;
    var stdio = false;
    var state_path: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var credential_path: ?[]const u8 = null;
    var trust_root_path: ?[]const u8 = null;
    var profile_task: ?[]const u8 = null;
    var task_text: ?[]const u8 = null;
    var authorize_inference = false;
    var human_options: HumanOptions = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--offline") and !offline) offline = true else if (std.mem.eql(u8, arg, "--test-provider") and !test_provider) test_provider = true else if (std.mem.eql(u8, arg, "--transport") and !stdio and serving) {
            if (!std.mem.eql(u8, args.next() orelse return 64, "stdio")) return 64;
            stdio = true;
        } else if (std.mem.eql(u8, arg, "--state-dir") and state_path == null) {
            state_path = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--config") and config_path == null) {
            config_path = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--credential-file") and credential_path == null) {
            credential_path = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--trust-root") and trust_root_path == null) {
            trust_root_path = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--profile-task") and serving and profile_task == null) {
            profile_task = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--authorize-inference") and !authorize_inference) {
            authorize_inference = true;
        } else if (std.mem.eql(u8, arg, "--task") and human == .run and task_text == null) {
            task_text = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--task-id") and human != null and human.? != .run and human.? != .@"import-checkpoint" and human_options.task_id == null) {
            human_options.task_id = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--input-json") and human == .run and human_options.input_json == null) {
            human_options.input_json = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--operation-id") and human != null and human.? != .status and human.? != .result and human.? != .@"export-checkpoint" and human_options.operation_id == null) {
            human_options.operation_id = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--expected-revision") and human == .@"resume" and human_options.expected_revision == null) {
            human_options.expected_revision = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--answer-json") and human == .respond and human_options.answer.value == null) {
            human_options.answer.value = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--question-id") and human == .respond and human_options.answer.id == null) {
            human_options.answer.id = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--question-revision") and human == .respond and human_options.answer.revision == null) {
            human_options.answer.revision = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--request-digest") and human == .respond and human_options.answer.request == null) {
            human_options.answer.request = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--input") and human == .@"import-checkpoint" and human_options.checkpoint_input == null) {
            human_options.checkpoint_input = args.next() orelse return 64;
        } else if (std.mem.eql(u8, arg, "--output") and human == .@"export-checkpoint" and human_options.checkpoint_output == null) {
            human_options.checkpoint_output = args.next() orelse return 64;
        } else return 64;
    }
    if ((serving and !stdio) or (!serving and !validating and state_path == null) or (human == .run and human_options.input_json == null and task_text == null)) return 64;
    if ((demo and !offline) or (validating and state_path != null) or (offline and authorize_inference) or (task_text != null and human_options.input_json != null) or (profile_task != null and state_path == null)) return 64;
    if (test_provider and (offline or credential_path != null or trust_root_path == null)) return 64;
    if (comptime !@hasDecl(Environment, "configure")) {
        if (!offline or validating or config_path != null or credential_path != null or trust_root_path != null or profile_task != null or authorize_inference or test_provider) return 64;
    }
    if (human == .respond and (human_options.answer.value == null or human_options.answer.id == null or human_options.answer.revision == null or human_options.answer.request == null)) return 64;
    // A caller-named operation must not reselect mutable parameters on retry.
    if (human_options.operation_id != null and (human == .@"resume" or human == .cancel or human == .respond)) {
        if (human_options.task_id == null or (human == .@"resume" and human_options.expected_revision == null)) return 64;
    }
    if ((human == .@"import-checkpoint" and human_options.checkpoint_input == null) or (human == .@"export-checkpoint" and human_options.checkpoint_output == null)) return 64;

    // Main-thread allocations are reclaimable and bounded. Workers use their
    // own preallocated region, so this accounting never races with worker I/O.
    var budget: kronos.AllocationBudget = .{ .parent = init.gpa, .limit = 64 * 1024 * 1024 };
    const a = budget.allocator();
    var handlers = try registry.Registry.init(a, &Environment.handlers);
    defer handlers.deinit();
    var application = try discovery.Application.init(Types, a, assets, handlers);
    defer application.deinit();
    var instance_identity: [16]u8 = undefined;
    try init.io.randomSecure(&instance_identity);
    const instance = std.fmt.bytesToHex(instance_identity, .lower);
    const artifact_identity = try identity.executable(init.io);
    var namespace: ?Namespace = null;
    defer if (namespace) |*owner| owner.close() catch {};
    if (state_path) |path| namespace = Namespace.open(a, init.io, path) catch |err| return switch (err) {
        error.Busy => 75,
        error.UnsafeStatePath, error.ForeignNamespace => 64,
        else => 74,
    };
    var profile_arena = std.heap.ArenaAllocator.init(a);
    defer profile_arena.deinit();
    const profile_allocator = profile_arena.allocator();
    const grants = try profile_allocator.alloc(registry.Grant, handlers.entries.len);
    for (handlers.entries, grants) |entry, *grant| grant.* = .{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = @splat(0) };
    const profile_bytes = try std.json.Stringify.valueAlloc(profile_allocator, .{ .mode = "offline", .application = Types.application_id, .assets = try discovery.digest(profile_allocator, assets.application) }, .{});
    var profile: tasks.Profile = .{ .id = "offline", .runtime_identity = artifact_identity.sha256, .bytes = profile_bytes, .authority = .{ .grants = grants, .principal = try std.fmt.allocPrint(profile_allocator, "uid:{d}", .{c.geteuid()}), .tenant = "local" } };
    var service: ?tasks.Service(Types) = null;
    defer if (service) |*owner| owner.close(a) catch {};
    if (namespace) |*owner| service = try tasks.Service(Types).init(a, init.io, owner, assets, &application, handlers, profile);
    if (comptime @hasDecl(Environment, "configure")) {
        if (human != .status and human != .result) {
            var frozen: ?tasks.FrozenInputs = null;
            if (profile_task) |text| {
                const id = client_api.identifier(16, json.string(text)) catch return 64;
                frozen = service.?.frozenInputs(profile_allocator, id) catch return 64;
            } else if (human == .@"import-checkpoint") {
                frozen = service.?.frozenArchiveInputs(profile_allocator, human_options.checkpoint_input.?) catch return 64;
            } else if (human != null and human.? != .run) {
                const id = selectTask(Types, profile_allocator, &service.?, human_options.task_id, human == .@"resume" or human == .cancel) catch return 64;
                frozen = service.?.frozenInputs(profile_allocator, id) catch return 64;
            }
            const admitted = Environment.configure(profile_allocator, init.io, .{ .offline = offline, .scratch_allocator = a, .test_provider = test_provider, .config_path = config_path, .credential_path = credential_path, .trust_root_path = trust_root_path }, frozen, assets) catch |err| {
                _ = reportFailure(err);
                return 64;
            };
            if (admitted.bytes.len > 256 * 1024) return 64;
            if (frozen) |saved| {
                if (!std.mem.eql(u8, saved.profile, admitted.bytes) or !std.mem.eql(u8, saved.profile_id, admitted.id)) return 64;
            }
            profile.id = admitted.id;
            profile.bytes = admitted.bytes;
            profile.resources = admitted.resources;
            profile.environment = admitted.environment;
            profile.authority.inference = offline or authorize_inference;
            profile.validate() catch return 64;
            application.execution_mode = if (offline) .offline else .live;
            if (service) |*owner| owner.profile = profile;
        }
    }
    // Grant the finalized launch profile, including restored immutable inputs.
    // Task admission checks the same digest derived from its durable references.
    const resource_identity = try profile.resourceIdentity(application.image_identity);
    for (grants) |*grant| grant.resource_identity = resource_identity;
    if (task_text) |text| {
        if (comptime @hasDecl(Environment, "taskInput")) {
            const input = Environment.taskInput(profile_allocator, text) catch return 64;
            human_options.input_json = try json.canonical(profile_allocator, try @import("values.zig").toJson(Types.Input, profile_allocator, input));
        } else return 64;
    }
    if (validating) {
        var result = json.object();
        try json.put(profile_allocator, &result, "valid", .{ .bool = true });
        try json.put(profile_allocator, &result, "profile_id", json.string(profile.id));
        try json.put(profile_allocator, &result, "profile_sha256", json.string(try discovery.digest(profile_allocator, profile.bytes)));
        try std.Io.File.stdout().writeStreamingAll(init.io, try json.canonical(profile_allocator, result));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    var client: ?client_api.Client(Types) = null;
    if (service) |*owner| client = .{ .service = owner };
    if (human) |selected| return humanCommand(Types, a, &service.?, &client.?, selected, human_options, &instance) catch |err| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = arena.allocator();
        const kind = failureKind(err);
        var failure = json.object();
        try json.put(frame, &failure, "error", json.string(@tagName(kind)));
        try json.put(frame, &failure, "reason", json.string(@errorName(err)));
        try json.put(frame, &failure, "recovery", json.string(failureRecovery(kind)));
        try std.Io.File.stdout().writeStreamingAll(init.io, try json.canonical(frame, failure));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return switch (kind) {
            .StorageUnavailable, .InternalError => 74,
            .Overloaded => 75,
            else => 64,
        };
    };
    if (demo) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const result = try @import("demo.zig").run(Types, Environment, arena.allocator(), &service.?, &client.?, &instance);
        try std.Io.File.stdout().writeStreamingAll(init.io, try json.canonical(arena.allocator(), result));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return 0;
    }
    var connection: Connection(Types) = .{
        .application = &application,
        .instance = &instance,
        .artifact_identity = artifact_identity.sha256,
        .client = if (client) |*value| value else null,
        // Derive once from the finalized immutable launch inputs, using the
        // same resource identity that issued the capability grants above.
        .launch_profile = if (client != null) .{ .id = profile.id, .sha256 = @import("store.zig").digest(profile.bytes), .resource_identity = resource_identity } else null,
    };
    return serve(Types, init.io, a, &connection);
}

const HumanCommand = enum { run, status, result, @"resume", cancel, respond, @"export-checkpoint", @"import-checkpoint" };
const AnswerOptions = struct { value: ?[]const u8 = null, id: ?[]const u8 = null, revision: ?[]const u8 = null, request: ?[]const u8 = null };

const HumanOptions = struct {
    task_id: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    expected_revision: ?[]const u8 = null,
    answer: AnswerOptions = .{},
    checkpoint_input: ?[]const u8 = null,
    checkpoint_output: ?[]const u8 = null,
};

fn selectTask(comptime Types: type, a: std.mem.Allocator, service: *tasks.Service(Types), text: ?[]const u8, nonterminal: bool) ![16]u8 {
    if (text) |value| return client_api.identifier(16, json.string(value));
    const ids = try service.namespace.store.taskIds(a, nonterminal);
    defer a.free(ids);
    var selected: ?[16]u8 = null;
    for (ids) |candidate| {
        var task = service.task(a, candidate) catch |err| switch (err) {
            error.Denied => continue,
            else => return err,
        };
        task.deinit();
        if (selected != null) return error.AmbiguousTask;
        selected = candidate;
    }
    return selected orelse error.UnknownTask;
}

/// CLI selection and rendering only. All admissions and execution use the same
/// client mapping, task owner and isolated I/O slot as the protocol front end.
fn humanCommand(comptime Types: type, a: std.mem.Allocator, service: *tasks.Service(Types), client: *client_api.Client(Types), command: HumanCommand, options: HumanOptions, fallback_operation_id: []const u8) !u8 {
    const operation_id = options.operation_id orelse fallback_operation_id;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const frame = arena.allocator();
    var params = json.object();
    try json.put(frame, &params, "client_operation_id", json.string(operation_id));
    var id: [16]u8 = undefined;
    var imported: ?tasks.Admission = null;
    if (command == .@"import-checkpoint") {
        imported = try service.importCheckpoint(frame, operation_id, options.checkpoint_input.?);
        id = imported.?.receipt.task;
    } else if (command == .run) {
        try json.put(frame, &params, "application_id", json.string(Types.application_id));
        try json.put(frame, &params, "profile_id", json.string(service.profile.id));
        var typed_input = json.object();
        try json.put(frame, &typed_input, "schema_id", json.string(Types.input_schema_id));
        try json.put(frame, &typed_input, "value", (try json.parse(frame, options.input_json.?, .{ .bytes = 256 * 1024 })).value);
        try json.put(frame, &params, "input", typed_input);
        const accepted = try client.call(frame, .@"task.submit", params);
        id = try client_api.identifier(16, accepted.object.get("task_id").?);
    } else {
        id = selectTask(Types, frame, service, options.task_id, command == .@"resume" or command == .cancel) catch return 64;
        try json.put(frame, &params, "task_id", json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
        if (command == .@"export-checkpoint") {
            const exported = try service.exportCheckpoint(frame, id, options.checkpoint_output.?);
            var result = json.object();
            try json.put(frame, &result, "format", json.string("agent-native-checkpoint/1"));
            try json.put(frame, &result, "task_id", params.object.get("task_id").?);
            try json.put(frame, &result, "sha256", json.string(try frame.dupe(u8, &std.fmt.bytesToHex(exported.sha256, .lower))));
            try json.put(frame, &result, "bytes", json.string(try std.fmt.allocPrint(frame, "{d}", .{exported.bytes})));
            try std.Io.File.stdout().writeStreamingAll(service.io, try json.canonical(frame, result));
            try std.Io.File.stdout().writeStreamingAll(service.io, "\n");
            return 0;
        }
        if (command == .@"resume") {
            var current = try service.task(frame, id);
            defer current.deinit();
            try json.put(frame, &params, "expected_revision", json.string(options.expected_revision orelse try std.fmt.allocPrint(frame, "{d}", .{current.value.revision})));
            _ = try client.call(frame, .@"task.resume", params);
        } else if (command == .cancel) _ = try client.call(frame, .@"task.cancel", params) else if (command == .respond) {
            var answer = json.object();
            try json.put(frame, &answer, "schema_id", json.string(Types.answer_schema_id));
            try json.put(frame, &answer, "value", (try json.parse(frame, options.answer.value.?, .{ .bytes = 256 * 1024 })).value);
            try json.put(frame, &params, "answer", answer);
            try json.put(frame, &params, "question_id", json.string(options.answer.id.?));
            try json.put(frame, &params, "question_revision", json.string(options.answer.revision.?));
            try json.put(frame, &params, "request_digest", json.string(options.answer.request.?));
            _ = try client.call(frame, .@"task.respond", params);
        }
    }
    if (command == .run or command == .@"resume" or command == .cancel or command == .respond) try driveHuman(Types, a, service, id, operation_id);
    try json.put(frame, &params, "task_id", json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
    const result = if (imported) |admitted| try client.admission(frame, admitted) else try client.call(frame, if (command == .status) .@"task.status" else .@"task.result", params);
    try std.Io.File.stdout().writeStreamingAll(service.io, try json.canonical(frame, result));
    try std.Io.File.stdout().writeStreamingAll(service.io, "\n");
    if (command != .status and command != .result and command != .@"import-checkpoint") {
        return executionExit(result);
    }
    return 0;
}

fn executionExit(result: json.Value) u8 {
    // Waiting for input can be part of cancellation cleanup. Readiness and
    // cancellation intent, not the presentation status, determine settlement.
    if (result.object.get("cancellation")) |intent| if (intent != .null and !result.object.get("ready").?.bool) return 2;
    // A terminal application failure does not imply settled cleanup.
    if (result.object.get("outcome")) |outcome| if (json.get(outcome, "cleanup_complete")) |complete| if (!complete.bool) return 2;
    const status = result.object.get("status").?.string;
    if (std.mem.eql(u8, status, "failed")) return 1;
    for ([_][]const u8{ "unknown", "blocked", "cancelling", "parked" }) |unfinished| if (std.mem.eql(u8, status, unfinished)) return 2;
    return 0;
}

test "execution exit distinguishes application failure from incomplete cleanup" {
    const cases = .{
        .{ "{\"status\":\"failed\",\"outcome\":{\"cleanup_complete\":false}}", 2 },
        .{ "{\"status\":\"failed\",\"outcome\":{\"cleanup_complete\":true}}", 1 },
        .{ "{\"status\":\"cancelled\",\"outcome\":{\"cleanup_complete\":false}}", 2 },
        .{ "{\"status\":\"cancelled\",\"outcome\":{\"cleanup_complete\":true}}", 0 },
        .{ "{\"status\":\"completed\"}", 0 },
        .{ "{\"status\":\"waiting_input\"}", 0 },
        .{ "{\"status\":\"waiting_input\",\"ready\":false,\"cancellation\":null}", 0 },
        .{ "{\"status\":\"waiting_input\",\"ready\":false,\"cancellation\":\"requested\"}", 2 },
        .{ "{\"status\":\"waiting_input\",\"ready\":false,\"cancellation\":\"\"}", 2 },
        .{ "{\"status\":\"cancelled\",\"ready\":true,\"cancellation\":\"requested\",\"outcome\":{\"cleanup_complete\":true}}", 0 },
        .{ "{\"status\":\"unknown\"}", 2 },
        .{ "{\"status\":\"blocked\"}", 2 },
        .{ "{\"status\":\"cancelling\"}", 2 },
        .{ "{\"status\":\"parked\"}", 2 },
    };
    inline for (cases) |case| {
        var result = try json.parse(std.testing.allocator, case[0], .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, case[1]), executionExit(result.value));
    }
}

fn driveHuman(comptime Types: type, a: std.mem.Allocator, service: *tasks.Service(Types), id: [16]u8, operation_id: []const u8) !void {
    interrupts.store(0, .release);
    if (c.protean_native_signals_begin(interrupt) != 0) return error.IoUnavailable;
    defer c.protean_native_signals_end();
    const slot = try Worker.init(a, service.io);
    defer {
        if (slot.future != null) std.process.exit(2);
        slot.deinit(a) catch {};
    }
    var shutdown_at: ?i64 = null;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = arena.allocator();
        const signals = interrupts.load(.acquire);
        const time = std.Io.Clock.awake.now(service.io).toMilliseconds();
        if (signals > 1 or (shutdown_at != null and time - shutdown_at.? >= 5000)) std.process.exit(2);
        if (signals != 0 and shutdown_at == null) {
            shutdown_at = time;
            const digest = @import("store.zig").digest(operation_id);
            const operation = try std.fmt.allocPrint(frame, "interrupt-{s}", .{std.fmt.bytesToHex(digest, .lower)});
            _ = try service.requestCancel(frame, operation, id, "human requested cancellation");
        }
        if (slot.future != null) {
            var task = try service.task(frame, id);
            defer task.deinit();
            if (task.value.cancellation != null and !slot.work.cleanup) slot.cancel();
            if (!slot.finished()) {
                _ = c.poll(null, 0, 20);
                continue;
            }
            try slot.join();
            if (slot.reply) |reply| try service.acquire(frame, slot.work, reply) else if (!slot.invoked) try service.notSent(frame, slot.work) else try service.unknown(frame, slot.work);
            try slot.release();
        }
        switch (try service.pump(frame)) {
            .work => |work| slot.start(work, service.profile.authority, service.profile.environment) catch try service.notSent(frame, work),
            .progressed => {},
            .waiting, .idle => {
                try service.park(frame);
                return;
            },
        }
    }
}

var interrupts: std.atomic.Value(u32) = .init(0);
fn interrupt(_: c_int) callconv(.c) void {
    _ = interrupts.fetchAdd(1, .monotonic);
}

fn requestIds(value: json.Value, buffer: *[16]transport_api.Id) []const transport_api.Id {
    var count: usize = 0;
    if (value == .array) {
        if (value.array.items.len > 16) return &.{};
        for (value.array.items) |item| if (json.get(item, "id")) |id| {
            buffer[count] = transport_api.Id.from(id) catch continue;
            count += 1;
        };
    } else if (json.get(value, "id")) |id| {
        buffer[0] = transport_api.Id.from(id) catch return &.{};
        count = 1;
    }
    return buffer[0..count];
}

/// Queue pressure leaves orderly closure pending under the existing drain
/// deadline. Publish only after the writer can reserve a complete frame.
fn queueClosed(comptime Types: type, frame: std.mem.Allocator, connection: *Connection(Types), transport: *transport_api.Transport, mode: Shutdown, code: u8) !bool {
    if (!transport.canAdmit()) return false;
    var params = json.object();
    try json.put(frame, &params, "mode", json.string(@tagName(mode)));
    try json.put(frame, &params, "disposition", json.string(if (code == 2) "incomplete" else if (mode == .cancel) "cancelled" else "parked"));
    var pending: std.array_list.Managed(json.Value) = .init(frame);
    if (connection.client) |client| for (client.service.owned) |owned| if (owned) |id| {
        try pending.append(json.string(try frame.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
    };
    try json.put(frame, &params, "recovery_tasks", .{ .array = pending });
    try transport.enqueue(try json.frame(frame, try protocol.notification(frame, "server.closed", params)), &.{}, connection.client != null);
    return true;
}

/// Task settlement and complete protocol delivery are separate exit obligations.
fn shutdownDisposition(code: u8, settled: bool, delivery_pending: bool) u8 {
    if (code != 0 and code != 2) return code;
    if (delivery_pending) return 74;
    return if (code == 0 and !settled) 2 else code;
}

test "shutdown deadline preserves task and delivery failure distinctions" {
    for ([_]bool{ false, true }) |settled| {
        try std.testing.expectEqual(74, shutdownDisposition(0, settled, true));
        try std.testing.expectEqual(74, shutdownDisposition(2, settled, true));
        try std.testing.expectEqual(2, shutdownDisposition(2, settled, false));
        for ([_]bool{ false, true }) |pending| {
            try std.testing.expectEqual(64, shutdownDisposition(64, settled, pending));
            try std.testing.expectEqual(74, shutdownDisposition(74, settled, pending));
        }
    }
    try std.testing.expectEqual(0, shutdownDisposition(0, true, false));
    try std.testing.expectEqual(2, shutdownDisposition(0, false, false));
}

test "orderly close waits through full slot and byte queues without losing acknowledgments" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Types = struct {};
    // Use the real nonblocking writer, including EAGAIN and subsequent drain.
    // Restore stdout before the test runner reports any result.
    const saved = c.dup(1);
    try std.testing.expect(saved >= 0);
    defer _ = c.close(saved);
    defer _ = c.dup2(saved, 1);
    var pipes: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&pipes));
    defer _ = c.close(pipes[0]);
    defer _ = c.close(pipes[1]);
    for (pipes) |fd| try std.testing.expect(c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK) >= 0);
    try std.testing.expectEqual(1, c.dup2(pipes[1], 1));
    for ([_]bool{ false, true }) |byte_pressure| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = arena.allocator();
        var transport = try transport_api.Transport.init(a, io, .{ .frame_bytes = 1024, .outbound_bytes = 4096 });
        defer transport.deinit();
        var connection: Connection(Types) = .{ .application = undefined, .instance = "test", .artifact_identity = @splat(0) };
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(a);
        const count: usize = if (byte_pressure) 4 else 64;
        const ids = [_]transport_api.Id{try transport_api.Id.from(json.string("shutdown"))};
        for (0..count) |index| {
            const body = if (index + 1 == count) "{\"id\":\"shutdown\",\"result\":{}}" else "{\"method\":\"task.event\"}";
            var padded: [1023]u8 = @splat(' ');
            @memcpy(padded[0..body.len], body);
            const bytes = if (byte_pressure) &padded else body;
            try transport.enqueue(bytes, if (index + 1 == count) &ids else &.{}, false);
            try expected.appendSlice(a, bytes);
            try expected.append(a, '\n');
        }
        var buffer: [4096]u8 = @splat('x');
        while (true) {
            const written = c.write(1, &buffer, buffer.len);
            if (written < 0) {
                try std.testing.expectEqual(.AGAIN, std.c.errno(written));
                break;
            }
            try std.testing.expect(written > 0);
        }
        // A pipe may reject an atomic large write before its last byte fits.
        while (true) {
            const written = c.write(1, &buffer, 1);
            if (written < 0) {
                try std.testing.expectEqual(.AGAIN, std.c.errno(written));
                break;
            }
            try std.testing.expectEqual(1, written);
        }
        try transport.flush(true);
        try std.testing.expectEqual(count, transport.count);
        for (0..2) |_| try std.testing.expect(!try queueClosed(Types, frame, &connection, &transport, .park, 0));
        try std.testing.expectEqual(count, transport.count);
        try std.testing.expectEqual(expected.items.len, transport.queued_bytes);
        // The peer resumes within the unchanged deadline. Remove only the
        // pipe filler, then let Transport itself retire queued frames.
        while (true) {
            const read = c.read(pipes[0], &buffer, buffer.len);
            if (read < 0) {
                try std.testing.expectEqual(.AGAIN, std.c.errno(read));
                break;
            }
            try std.testing.expect(read > 0);
        }
        try transport.flush(true);
        if (!byte_pressure) {
            // Successful writes reset the stall clock without completing the
            // queue. A hard deadline here is still an I/O failure.
            try std.testing.expect(transport.count > 0 and transport.count < count);
            try std.testing.expect(transport.output_progress != null);
            try std.testing.expectEqual(74, shutdownDisposition(0, true, transport.count != 0));
        }
        try std.testing.expect(try queueClosed(Types, frame, &connection, &transport, .park, 0));
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(a);
        for (0..128) |_| {
            while (true) {
                const read = c.read(pipes[0], &buffer, buffer.len);
                if (read < 0) {
                    try std.testing.expectEqual(.AGAIN, std.c.errno(read));
                    break;
                }
                try std.testing.expect(read > 0);
                try received.appendSlice(a, buffer[0..@intCast(read)]);
            }
            if (transport.count == 0) break;
            try transport.flush(true);
        }
        try std.testing.expectEqual(0, transport.count);
        try std.testing.expectEqual(0, transport.queued_bytes);
        try std.testing.expectEqual(0, transport.outstanding);
        try std.testing.expectEqual(0, shutdownDisposition(0, true, transport.count != 0));
        try std.testing.expect(received.items.len > expected.items.len);
        try std.testing.expectEqualSlices(u8, expected.items, received.items[0..expected.items.len]);
        const last = received.items[expected.items.len..];
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, last, "\n"));
        var notice = try json.parse(a, last, .{});
        defer notice.deinit();
        try std.testing.expectEqualStrings("server.closed", notice.value.object.get("method").?.string);
        const params = notice.value.object.get("params").?;
        try std.testing.expectEqualStrings("park", params.object.get("mode").?.string);
        try std.testing.expectEqualStrings("parked", params.object.get("disposition").?.string);
        try std.testing.expectEqual(0, params.object.get("recovery_tasks").?.array.items.len);
    }
}

fn serve(comptime Types: type, io: std.Io, a: std.mem.Allocator, connection: *Connection(Types)) !u8 {
    var transport = try transport_api.Transport.init(a, io, connection.limits);
    defer transport.deinit();
    interrupts.store(0, .release);
    if (c.protean_native_signals_begin(interrupt) != 0) return error.IoUnavailable;
    defer c.protean_native_signals_end();
    const worker: ?*Worker = if (connection.client != null) try Worker.init(a, io) else null;
    defer if (worker) |slot| {
        // Unexpected failure with live I/O uses process-crash recovery. Never
        // release the namespace while a thread can still dispatch or publish.
        if (slot.future != null) std.process.exit(74);
        slot.deinit(a) catch {};
    };
    var shutdown_at: ?i64 = null;
    var code: u8 = 0;
    var writable = true;
    var cancelled_owned = false;
    var parked = false;
    var closed_notice = false;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frame = arena.allocator();
        var progressed = false;
        const time = transport.now();
        const signals = interrupts.load(.acquire);
        if (signals != 0 and shutdown_at == null) {
            shutdown_at = time;
            connection.shutdown = .cancel;
        }
        if (signals > 1) std.process.exit(2);
        transport.deadlines() catch |err| {
            if (shutdown_at == null) shutdown_at = time;
            if (err == error.FrameTimeout) {
                if (code != 64 and writable and transport.canAdmit()) try transport.enqueue(try json.frame(frame, try protocol.failure(frame, .null, .InvalidRequest, "reconnect")), &.{}, false);
                code = 64;
            } else {
                writable = false;
                // A stalled output channel is an I/O failure even with no task.
                code = 74;
            }
        };
        if (writable) transport.flush(if (connection.client) |client| !client.service.profile.authority.revoked and client.service.profile.authority.disclosure else true) catch {
            writable = false;
            code = 74;
            if (shutdown_at == null) shutdown_at = time;
        };
        // During explicit shutdown, bounded reads remain available while work
        // drains. Once parked, only queued output drains. Fatal framing and EOF
        // stop admissions immediately.
        if (!parked and !connection.closing and code == 0 and writable and !transport.eof and transport.canAdmit()) {
            const incoming = transport.next() catch |err| blk: {
                if (shutdown_at == null) shutdown_at = time;
                connection.closing = true;
                code = if (err == error.TruncatedFrame or err == error.FrameTooLarge) 64 else 74;
                if (err == error.FrameTooLarge and writable) try transport.enqueue(try json.frame(frame, try protocol.failure(frame, .null, .InvalidRequest, "reconnect")), &.{}, false);
                break :blk null;
            };
            if (incoming) |bytes| {
                const parsed: ?std.json.Parsed(json.Value) = json.parse(frame, bytes, .{}) catch |err| blk: {
                    if (err == error.Capacity or err == error.OutOfMemory) {
                        connection.closing = true;
                        code = 64;
                    }
                    const fault = try protocol.failure(frame, .null, if (err == error.DuplicateKey) .InvalidRequest else .ParseError, "correct_request");
                    if (writable) try transport.enqueue(try json.frame(frame, fault), &.{}, false);
                    transport.consumed();
                    progressed = true;
                    break :blk null;
                };
                if (parsed) |value| {
                    var id_buffer: [16]transport_api.Id = undefined;
                    const ids = requestIds(value.value, &id_buffer);
                    const admitted = blk: {
                        transport.preflight(ids) catch |err| {
                            if (err == error.DuplicateId) {
                                connection.closing = true;
                                code = 64;
                                const fault = try protocol.failure(frame, .null, .InvalidRequest, "reconnect");
                                if (writable) try transport.enqueue(try json.frame(frame, fault), &.{}, false);
                                transport.consumed();
                            }
                            break :blk false;
                        };
                        break :blk true;
                    };
                    if (admitted) {
                        if (try connection.frame(frame, value.value)) |response| {
                            const encoded = try json.frame(frame, response);
                            try transport.enqueue(encoded, ids, connection.client != null);
                        }
                        transport.consumed();
                        progressed = true;
                    }
                }
            }
        }
        if (transport.eof or connection.closing or !writable or connection.shutdown != null) {
            if (shutdown_at == null) shutdown_at = time;
        }
        if (connection.closing and code == 0) code = 64;
        if (shutdown_at != null and connection.shutdown == null) connection.shutdown = .park;
        const mode = connection.shutdown orelse .park;
        if (connection.client) |client| {
            const service = client.service;
            const slot = worker.?;
            if (shutdown_at != null and mode == .cancel and !cancelled_owned) {
                for (service.owned) |owned| if (owned) |id| {
                    const operation = try std.fmt.allocPrint(frame, "shutdown-{s}-{s}", .{ connection.instance, std.fmt.bytesToHex(id, .lower) });
                    _ = try service.requestCancel(frame, operation, id, "host requested cancellation");
                };
                cancelled_owned = true;
            }
            if (slot.future != null) {
                var task = try service.task(frame, slot.work.task);
                defer task.deinit();
                const deadline_near = if (shutdown_at) |start| time - start >= connection.limits.output_stall_ms - 100 else false;
                if ((task.value.cancellation != null and !slot.work.cleanup) or (shutdown_at != null and mode == .park) or deadline_near) slot.cancel();
                if (slot.finished()) {
                    try slot.join();
                    if (slot.reply) |reply| try service.acquire(frame, slot.work, reply) else if (!slot.invoked) {
                        try service.notSent(frame, slot.work);
                    } else {
                        try service.unknown(frame, slot.work);
                        if (shutdown_at != null and code == 0) code = 2;
                    }
                    try slot.release();
                    progressed = true;
                }
            }
            if (!parked and (shutdown_at == null or (mode == .cancel and code == 0))) {
                const step = service.pump(frame) catch |err| blk: {
                    if (shutdown_at == null) shutdown_at = time;
                    code = if (err == error.Denied) 2 else 74;
                    break :blk tasks.Step.idle;
                };
                switch (step) {
                    .work => |work| slot.start(work, service.profile.authority, service.profile.environment) catch {
                        try service.notSent(frame, work);
                    },
                    .progressed, .waiting => progressed = true,
                    .idle => {},
                }
            }
            if (writable and shutdown_at == null and !closed_notice and transport.canAdmit()) {
                if (try client.notification(frame)) |notification| {
                    try transport.enqueue(try json.frame(frame, notification), &.{}, true);
                    progressed = true;
                }
            }
            if (shutdown_at != null and !parked and slot.future == null and (mode == .park or service.runnable.items.len == 0 or code != 0)) {
                if (!service.namespace.store.fenced) try service.park(frame);
                parked = true;
                if (code == 0 and try service.shutdownIncomplete(frame)) code = 2;
            }
        } else if (shutdown_at != null) parked = true;
        if (shutdown_at) |start| {
            if (time - start >= connection.limits.output_stall_ms) {
                // A joined worker is the only ordinary path to releasing the
                // lock. At the hard deadline process exit terminates all native
                // threads together; durable DISPATCHING recovers as UNKNOWN.
                const worker_live = if (worker) |slot| slot.future != null else false;
                const notice_pending = parked and writable and connection.initialized and !closed_notice and (code == 0 or code == 2);
                const disposition = shutdownDisposition(code, parked and !worker_live, transport.count != 0 or notice_pending);
                if (worker_live) std.process.exit(disposition);
                return disposition;
            }
            if (parked) {
                if (!closed_notice and writable and connection.initialized and (code == 0 or code == 2)) {
                    closed_notice = try queueClosed(Types, frame, connection, &transport, mode, code);
                }
                if (!writable or transport.count == 0) return code;
            }
        }
        transport.wait(!parked and !connection.closing and transport.canAdmit(), if (progressed) 0 else 20) catch {
            writable = false;
            code = 74;
            if (shutdown_at == null) shutdown_at = transport.now();
        };
    }
}
