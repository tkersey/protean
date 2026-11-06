const std = @import("std");
const contracts = @import("protean_contracts");
const responses = @import("responses.zig");
const wire = @import("responses_contract.zig");
const json = @import("json.zig");
const configuration = @import("configuration.zig");
const repository = @import("repository.zig");
const Roots = @import("protected_roots.zig").Roots;
const registry = @import("registry.zig");
const siwc = @import("siwc.zig");

const plan: contracts.ResponsesContract = .{
    .route = .chatgpt_plan_sse,
    .binding = @as([32]u8, @splat(7)),
};

fn frozenProfile(a: std.mem.Allocator, contract: contracts.ResponsesContract) ![]const u8 {
    var value = json.object();
    try json.put(a, &value, "responses", try @import("values.zig").toJson(
        contracts.ResponsesContract,
        a,
        contract,
    ));
    return json.canonical(a, value);
}

fn settings(contract: contracts.ResponsesContract) responses.Settings {
    return .{
        .endpoint = .{ .bytes = wire.endpoint },
        .audience = .{ .bytes = "fixture" },
        .model = .{ .bytes = "approved" },
        .effort = .{ .bytes = "medium" },
        .max_output_tokens = null,
        .request_bytes = null,
        .response_bytes = null,
        .timeout_ms = null,
        .contract = contract,
    };
}

fn notSent(ctx: registry.Context, config: responses.Settings, expected: anyerror) !void {
    const acquired = try responses.acquireSettings(ctx, config, "{}");
    try std.testing.expect(acquired == .definitely_not_sent);
    try std.testing.expectEqual(expected, acquired.definitely_not_sent);
}

test "ChatGPT acquisition binds authority route and source before any helper lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selection = try siwc.Selection.init(a, std.testing.io, .{
        .account = "personal",
        .executable = "/nonexistent/protean-test-siwc",
        .auth_dir = "/nonexistent/protean-test-auth",
    });
    defer selection.deinit();
    var env: responses.Environment = .{
        .approved_endpoint = wire.endpoint,
        .source = .{ .chatgpt_plan = .{ .selection = selection, .binding = plan.binding.? } },
    };
    var authority: registry.Authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" };
    const ctx: registry.Context = .{
        .allocator = a,
        .io = std.testing.io,
        .authority = &authority,
        .task_id = "fixture",
        .profile = try frozenProfile(a, plan),
        .environment = &env,
    };
    var config = settings(plan);
    try notSent(ctx, config, error.Denied);
    authority.inference = true;
    config.endpoint.bytes = "https://unapproved.invalid/v1/responses";
    try notSent(ctx, config, error.Denied);
    env.approved_endpoint = config.endpoint.bytes;
    try notSent(ctx, config, error.InvalidInferenceDestination);
    env.approved_endpoint = wire.endpoint;
    config.endpoint.bytes = wire.endpoint;
    config.contract = .{};
    try notSent(ctx, config, error.CredentialBindingMismatch);
    config.contract = plan;
    env.source.chatgpt_plan.binding = @splat(9);
    try notSent(ctx, config, error.CredentialBindingMismatch);
    env.source = .{ .api_key_file = "/nonexistent/key" };
    try notSent(ctx, config, error.CredentialBindingMismatch);
    env.source = .{ .chatgpt_plan = .{ .selection = selection, .binding = plan.binding.? } };
    try notSent(ctx, config, error.SiwcExecutableUnavailable);
    try std.testing.expect(selection.resolved == null);
}

test "API acquisition rereads rotated keys and detects decoded credential inputs without a helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const filename = try temporary.dir.realPathFileAlloc(io, ".", a);
    const key = try std.fs.path.join(a, &.{ filename, "key" });
    var env: responses.Environment = .{
        .source = .{ .api_key_file = key },
        .approved_endpoint = "http://invalid.invalid",
    };
    const authority: registry.Authority = .{
        .grants = &.{},
        .principal = "test",
        .tenant = "test",
        .inference = true,
    };
    const ctx: registry.Context = .{
        .allocator = a,
        .io = io,
        .authority = &authority,
        .task_id = "fixture",
        .profile = "opaque embedding profile",
        .environment = &env,
    };
    var config = settings(.{});
    config.endpoint.bytes = env.approved_endpoint;
    for ([_][]const u8{ "synthetic-first", "synthetic-second" }) |token| {
        try temporary.dir.writeFile(io, .{
            .sub_path = "key",
            .data = token,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        const request = try std.fmt.allocPrint(a, "{{\"input\":\"{s}\"}}", .{token});
        const acquired = try responses.acquireSettings(ctx, config, request);
        try std.testing.expect(acquired == .definitely_not_sent);
        try std.testing.expectEqual(error.UnsafeCredentialFile, acquired.definitely_not_sent);
    }
    const escaped = try responses.acquireSettings(
        ctx,
        config,
        "{\"input\":\"synthetic-\\u0073econd\"}",
    );
    try std.testing.expectEqual(error.UnsafeCredentialFile, escaped.definitely_not_sent);
    var nested_bytes: []const u8 = "\"synthetic-\\u0073econd\"";
    for (0..40) |_| nested_bytes = try std.fmt.allocPrint(a, "[{s}]", .{nested_bytes});
    const nested = try responses.acquireSettings(ctx, config, nested_bytes);
    try std.testing.expectEqual(error.UnsafeCredentialFile, nested.definitely_not_sent);
    try notSent(ctx, config, error.InvalidConfiguration);
    var leaked_profile = ctx;
    leaked_profile.profile = "{\"input\":\"synthetic-\\u0073econd\"}";
    try notSent(leaked_profile, config, error.UnsafeCredentialFile);
}

fn raw(format: contracts.ResponseFormat, status: u16, body: []const u8) responses.Raw {
    return .{
        .status = status,
        .identity_encoding = true,
        .request_id = .{ .bytes = "fixture-request" },
        .body = .{ .bytes = body },
        .format = format,
        .media_type = .{ .bytes = if (format == .sse) "text/event-stream" else "application/json" },
    };
}

fn parsed(a: std.mem.Allocator, bytes: []const u8) !json.Value {
    return json.parseInto(a, bytes, .{});
}

fn expectJson(a: std.mem.Allocator, expected: []const u8, actual: json.Value) !void {
    try std.testing.expectEqualStrings(
        try json.canonical(a, try parsed(a, expected)),
        try json.canonical(a, actual),
    );
}

const completed_json =
    \\{"id":"r","status":"completed","error":null,"output":[{"type":"function_call","status":"completed","id":"f","call_id":"c","name":"choose","arguments":"{\"value\":17}"}],"usage":{"input_tokens":0}}
;
const completed_sse =
    \\: heartbeat
    \\data: {"type":"response.created","response":{"id":"r"},"sequence_number":4}
    \\
    \\data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","status":"completed","id":"f","call_id":"c","name":"choose","arguments":"{\"value\":17}"}}
    \\
    \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs","summary":[],"encrypted_content":"complete-opaque"}}
    \\
    \\data: {"type":"response.completed","sequence_number":9,"response":{"id":"r","status":"completed","error":null,"output":[{"type":"reasoning","id":"rs"},{"type":"function_call","id":"f","call_id":"c"}],"usage":{"input_tokens":0}}}
    \\
    \\
;

test "ChatGPT shared decoder selects frozen framing and preserves existing JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decoded = try responses.decode(a, .{}, raw(.json, 200, completed_json));
    try std.testing.expect(decoded.failure == null);
    try expectJson(a, completed_json, decoded.body);
    try std.testing.expectError(
        error.InvalidResponseFormat,
        responses.decode(a, plan, raw(.json, 200, completed_json)),
    );
    try std.testing.expectError(
        error.InvalidResponseFormat,
        responses.decode(a, .{}, raw(.sse, 200, completed_sse)),
    );
    var wrong_media = raw(.sse, 200, completed_sse);
    wrong_media.media_type = .{ .bytes = "application/json" };
    try std.testing.expectError(
        error.InvalidResponseMediaType,
        responses.decode(a, plan, wrong_media),
    );
    var old_capture = raw(.json, 200, completed_json);
    old_capture.version = 1;
    try std.testing.expectError(error.InvalidResponseFormat, responses.decode(a, .{}, old_capture));
}

test "ChatGPT shared decoder publishes complete ordered reasoning and exact typed call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try responses.decode(a, plan, raw(.sse, 200, completed_sse));
    try std.testing.expect(result.failure == null);
    try expectJson(a,
        \\[{"type":"reasoning","id":"rs","summary":[],"encrypted_content":"complete-opaque"},{"type":"function_call","status":"completed","id":"f","call_id":"c","name":"choose","arguments":"{\"value\":17}"}]
    , json.get(result.body, "output").?);
    try expectJson(a, "{\"input_tokens\":0}", json.get(result.body, "usage").?);
    const malformed =
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","status":"completed","id":"f","call_id":"c","name":"choose"}}
        \\
        \\data: {"type":"response.completed","response":{"id":"r","status":"completed","error":null,"output":[{"type":"function_call","id":"f"}]}}
        \\
        \\
    ;
    const rejected = try responses.decode(a, plan, raw(.sse, 200, malformed));
    try std.testing.expectEqual(.output, rejected.unsupported.?);
}

test "ChatGPT shared failure recovery is route bound and preserves terminal failure kind" {
    const cases = [_]struct { code: []const u8, recovery: contracts.ProviderRecovery }{
        .{ .code = "subscription_sharing_usage_limit_exceeded", .recovery = .usage_limit },
        .{ .code = "subscription_sharing_usage_unavailable", .recovery = .transient },
        .{ .code = "subscription_sharing_invalid_user", .recovery = .authentication },
        .{ .code = "subscription_sharing_unsupported_capability", .recovery = .none },
        .{ .code = "unrecognized", .recovery = .none },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (cases) |case| {
        const failure = try std.fmt.allocPrint(
            a,
            "{{\"id\":\"r\",\"status\":\"failed\",\"error\":{{\"code\":\"{s}\"}}}}",
            .{case.code},
        );
        const event = try std.fmt.allocPrint(
            a,
            "data: {{\"type\":\"response.failed\",\"response\":{s}}}\n\n",
            .{failure},
        );
        const streamed = try responses.decode(a, plan, raw(.sse, 200, event));
        try std.testing.expectEqual(
            contracts.ProviderFailureKind.response_failed,
            streamed.failure.?.kind,
        );
        try std.testing.expectEqual(case.recovery, streamed.failure.?.recovery);
        const api = try responses.decode(a, .{}, raw(.json, 200, failure));
        try std.testing.expectEqual(contracts.ProviderRecovery.none, api.failure.?.recovery);
        const standalone = try std.fmt.allocPrint(
            a,
            "data: {{\"type\":\"error\",\"code\":\"{s}\"}}\n\n",
            .{case.code},
        );
        const failed = try responses.decode(a, plan, raw(.sse, 200, standalone));
        try std.testing.expectEqual(
            contracts.ProviderFailureKind.stream_error,
            failed.failure.?.kind,
        );
        try std.testing.expectEqual(case.recovery, failed.failure.?.recovery);
    }
    for ([_]u16{ 401, 429, 503 }) |status| {
        const result = try responses.decode(a, plan, raw(.sse, status, "{\"detail\":\"denied\"}"));
        const expected: contracts.ProviderRecovery = if (status == 401)
            .authentication
        else
            .transient;
        try std.testing.expectEqual(expected, result.failure.?.recovery);
        try std.testing.expectEqual(status, result.failure.?.http_status);
        const api = try responses.decode(a, .{}, raw(.json, status, "not JSON"));
        try std.testing.expectEqual(contracts.ProviderRecovery.none, api.failure.?.recovery);
    }
}

fn envelope(a: std.mem.Allocator, selected: wire.Route) !wire.Envelope {
    return .{
        .route = selected,
        .model = "fixture-model",
        .effort = "medium",
        .reasoning_mode = "standard",
        .reasoning_context = "auto",
        .max_output_tokens = null,
        .input = try parsed(a,
            \\[{"role":"developer","content":"policy"},{"type":"reasoning","id":"rs","encrypted_content":"opaque","summary":[]},{"type":"function_call","call_id":"c","name":"choose","arguments":"{}"},{"type":"function_call_output","call_id":"c","output":"done"},{"type":"additional_tools","role":"developer","tools":[]}]
        ),
        .tools = try parsed(a,
            \\[{"type":"function","name":"choose","strict":true,"parameters":{"type":"object","properties":{},"additionalProperties":false}}]
        ),
    };
}

test "ChatGPT request core tools are a stable prefix preserving ordered local history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try envelope(a, .chatgpt_plan_sse);
    const first = try wire.envelope(a, spec);
    const second = try wire.envelope(a, spec);
    try std.testing.expectEqual(@as(usize, 5), spec.input.array.items.len);
    const input = json.get(first, "input").?;
    try std.testing.expectEqual(@as(usize, 6), input.array.items.len);
    try expectJson(a,
        \\{"type":"additional_tools","role":"developer","tools":[{"type":"function","name":"choose","strict":true,"parameters":{"type":"object","properties":{},"additionalProperties":false}}]}
    , input.array.items[0]);
    for (spec.input.array.items, input.array.items[1..]) |original, retained|
        try std.testing.expectEqualStrings(
            try json.canonical(a, original),
            try json.canonical(a, retained),
        );
    try std.testing.expectEqualStrings(try json.canonical(a, first), try json.canonical(a, second));
    try expectJson(a, "{\"effort\":\"medium\"}", json.get(first, "reasoning").?);
    try std.testing.expect(json.get(first, "stream").?.bool);
    try std.testing.expect(!json.get(first, "store").?.bool);
    try std.testing.expect(!json.get(first, "parallel_tool_calls").?.bool);
    for ([_][]const u8{ "tools", "background", "truncation", "max_output_tokens" }) |key|
        try std.testing.expect(json.get(first, key) == null);
}

test "ChatGPT unsupported limits and capabilities fail without changing API request dialect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try envelope(a, .api_key_json);
    spec.max_output_tokens = 128;
    const api = try wire.envelope(a, spec);
    try expectJson(a, "128", json.get(api, "max_output_tokens").?);
    try expectJson(
        a,
        "{\"effort\":\"medium\",\"mode\":\"standard\",\"context\":\"auto\"}",
        json.get(api, "reasoning").?,
    );
    try std.testing.expect(!json.get(api, "stream").?.bool);
    try std.testing.expect(json.get(api, "tools") != null);
    try std.testing.expectEqual(@as(usize, 5), json.get(api, "input").?.array.items.len);
    spec.route = .chatgpt_plan_sse;
    try std.testing.expectError(error.UnsupportedChatGPTCapability, wire.envelope(a, spec));
    spec.max_output_tokens = null;
    spec.input = try parsed(a, "[{\"role\":\"system\",\"content\":\"must not coerce\"}]");
    try std.testing.expectError(error.UnsupportedChatGPTCapability, wire.envelope(a, spec));
    const Profile = struct {
        max_output_tokens: ?u32 = null,
        reasoning_mode: enum { standard, pro } = .standard,
        reasoning_context: enum { auto, other } = .auto,
        explicit_cache: bool = false,
        cache_diagnostics: bool = false,
        effort_update: bool = false,
        additional_tools: bool = true,
    };
    try wire.admitProfile(.chatgpt_plan_sse, Profile{});
    const capabilities = .{
        "explicit_cache", "cache_diagnostics", "effort_update", "additional_tools",
    };
    inline for (capabilities) |key| {
        var profile: Profile = .{};
        @field(profile, key) = !@field(profile, key);
        try wire.admitProfile(.api_key_json, profile);
        try std.testing.expectError(
            error.UnsupportedChatGPTCapability,
            wire.admitProfile(.chatgpt_plan_sse, profile),
        );
    }
}

fn path(a: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ base, suffix });
}

fn expectProtected(a: std.mem.Allocator, roots: Roots, filename: []const u8) !void {
    try std.testing.expect(try roots.contains(a, filename));
    try std.testing.expectError(
        error.ProtectedAuthenticationInput,
        configuration.readProtectedFile(a, std.testing.io, filename, null, false, roots),
    );
}

test "ChatGPT default and custom roots protect file readers and repository snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ ".config/siwc", "vault", "vault-sibling" }) |directory|
        try temporary.dir.createDirPath(io, directory);
    for ([_][]const u8{ ".config/siwc/session.json", "vault/session.json" }) |filename|
        try temporary.dir.writeFile(io, .{ .sub_path = filename, .data = "synthetic-private" });
    try temporary.dir.writeFile(io, .{ .sub_path = "public.txt", .data = "public" });
    try temporary.dir.writeFile(io, .{
        .sub_path = "vault-sibling/public.txt",
        .data = "sibling is outside",
    });
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];
    const roots = try Roots.init(a, io, root, try path(a, root, "vault"));
    try expectProtected(a, roots, try path(a, root, ".config/siwc/session.json"));
    try expectProtected(a, roots, try path(a, root, "vault/session.json"));
    const sibling = try path(a, root, "vault-sibling/public.txt");
    try std.testing.expect(!try roots.contains(a, sibling));
    try std.testing.expectEqualStrings(
        "sibling is outside",
        try configuration.readProtectedFile(a, io, sibling, null, false, roots),
    );
    const bytes = try repository.captureProtected(a, std.testing.allocator, io, root, roots);
    var snapshot = try repository.Snapshot.open(a, bytes);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.files().len);
    try std.testing.expectEqual(@as(u64, 2), snapshot.decoded.value.excluded_entries);
    try std.testing.expectEqualStrings("public", snapshot.get("public.txt").?.contents.bytes);
    try std.testing.expectEqualStrings(
        "sibling is outside",
        snapshot.get("vault-sibling/public.txt").?.contents.bytes,
    );
    try std.testing.expect(snapshot.get("vault/session.json") == null);
    try std.testing.expect(snapshot.get(".config/siwc/session.json") == null);
    const sealed = try repository.captureProtected(
        a,
        std.testing.allocator,
        io,
        try path(a, root, "vault"),
        roots,
    );
    var private_snapshot = try repository.Snapshot.open(a, sealed);
    defer private_snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), private_snapshot.files().len);
    try std.testing.expectEqual(@as(u64, 1), private_snapshot.decoded.value.excluded_entries);
    try protectedAliases(a, temporary.dir, root, roots);
}

fn protectedAliases(
    a: std.mem.Allocator,
    directory: std.Io.Dir,
    root: []const u8,
    roots: Roots,
) !void {
    const io = std.testing.io;
    for ([_][]const u8{ "vault/session.json", "public.txt" }) |original| {
        try directory.hardLink(original, directory, "hard-alias", io, .{});
        try std.testing.expectError(
            error.HardLinkedModelInput,
            configuration.readProtectedFile(
                a,
                io,
                try path(a, root, "hard-alias"),
                null,
                false,
                roots,
            ),
        );
        try std.testing.expectError(
            error.HardLinkedModelInput,
            repository.captureProtected(a, std.testing.allocator, io, root, roots),
        );
        try directory.deleteFile(io, "hard-alias");
    }
    try directory.symLink(io, "vault", "alias", .{ .is_directory = true });
    try directory.symLink(io, "vault/session.json", "file-alias", .{});
    try expectProtected(a, roots, try path(a, root, "alias/session.json"));
    try expectProtected(a, roots, try path(a, root, "file-alias"));
    const selected_alias = try Roots.init(a, io, root, try path(a, root, "alias"));
    try expectProtected(a, selected_alias, try path(a, root, "vault/session.json"));
    try std.testing.expectError(
        error.UnsupportedSnapshotEntry,
        repository.captureProtected(a, std.testing.allocator, io, root, roots),
    );
}

test "ChatGPT missing protected stores remain absent and never block unrelated snapshot bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "input.txt", .data = "safe input" });
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];
    const missing = try path(a, root, "absent/nested/auth");
    const roots = try Roots.init(a, io, root, missing);
    try expectProtected(a, roots, try path(a, missing, "future-session"));
    try expectProtected(a, roots, try path(a, root, ".config/siwc/future-session"));
    const outside = try path(a, root, "input.txt");
    try std.testing.expectEqualStrings(
        "safe input",
        try configuration.readProtectedFile(a, io, outside, null, false, roots),
    );
    const bytes = try repository.captureProtected(a, std.testing.allocator, io, root, roots);
    var snapshot = try repository.Snapshot.open(a, bytes);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.files().len);
    try std.testing.expectEqual(@as(u64, 0), snapshot.decoded.value.excluded_entries);
    try std.testing.expectEqualStrings("safe input", snapshot.get("input.txt").?.contents.bytes);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, ".config", .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, "absent", .{}));
}
