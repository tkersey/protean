//! Native bindings for the single authored adaptive application.
const std = @import("std");
const native = @import("protean_native");
const t = @import("application_types");
const contracts = @import("protean_contracts");
const context = @import("context.zig");
const work = @import("work.zig");
const workspace = @import("workspace.zig");
const tool_resources = @import("tool_resources.zig");
const Adapter = native.adaptive_responses.Adapter(t.P);
const Admission = native.adaptive_responses.Admission(t.P);
const digest = work.digest;
pub const demo_input: t.Input = .{ .task = .{
    .bytes = "Explain the fixture entry point using source evidence and " ++
        "exercise the approved adaptive controls.",
} };
pub const demo_answer: t.Answer = .{ .message = .{ .bytes = "Focus on observable behavior." } };
pub const State = struct {
    snapshot: native.repository.Snapshot,
    profile_identity: [32]u8,
    policy: t.P.AdaptivePolicy,
    catalog: t.P.AdaptiveCatalog,
    tools: ?t.ToolPolicy,
    initial: t.controls.State,
    provider: native.responses.Environment,
    offline: bool,
};
pub const handlers = [_]native.Declaration{
    native.registry.controllerImport(
        .task_view,
        native.leaf(
            void,
            t.Bindings,
            .{ .identity = t.bindings_identity, .resource_role = "snapshot" },
            bindings,
        ),
    ),
    native.registry.controllerImport(.context, context.declaration()),
    native.registry.controllerImport(.snapshot, work.declaration()),
    native.registry.controllerImport(.inspect, work.inspectionDeclaration()),
    native.registry.controllerImport(.workspace, workspace.declaration()),
    instrumentDeclaration(),
    native.workspace_instrument.declaration(.snapshot),
    native.registry.controllerImport(
        .question,
        native.question(
            t.Question,
            t.Answer,
            .{
                .identity = t.question_identity,
                .resource_role = "user",
                .answer_schema_id = t.answer_schema_id,
            },
            present,
        ),
    ),
    native.registry.controllerImport(.inbox, native.inbox.declaration(t.Message)),
    native.registry.controllerImport(.deliberate, providerDeclaration()),
};
fn state(ctx: native.Context) !*const State {
    const value: *const State = @ptrCast(
        @alignCast(ctx.environment orelse return error.MissingConfiguration),
    );
    if (!std.mem.eql(
        u8,
        &digest(ctx.profile),
        &value.profile_identity,
    )) return error.IncompatibleProfile;
    return value;
}
fn bindings(ctx: native.Context, _: void) !t.Bindings {
    const frozen = try state(ctx);
    const choices = try ctx.allocator.alloc(
        t.controls.ProfileChoice,
        frozen.policy.profiles.items.len,
    );
    for (choices, frozen.policy.profiles.items) |*out, profile| out.* = t.controls.profileChoice(
        profile,
        try Admission.profileDigest(ctx.allocator, profile),
    );
    const catalog = try ctx.allocator.alloc(t.controls.Skill, frozen.catalog.skills.items.len);
    for (catalog, frozen.catalog.skills.items) |*out, skill| out.* = .{
        .id = skill.id,
        .version = skill.version,
        .instructions = skill.instructions,
    };
    var inputs: native.json.Value = .{ .array = .init(ctx.allocator) };
    if (frozen.tools) |policy| for (policy.inputs.items) |input| {
        var value = native.json.object();
        try native.json.put(ctx.allocator, &value, "id", native.json.string(input.id.bytes));
        try native.json.put(
            ctx.allocator,
            &value,
            "description",
            native.json.string(input.description.bytes),
        );
        try inputs.array.append(value);
    };
    return .{
        .policy = frozen.profile_identity,
        .snapshot = frozen.snapshot.identity,
        .files = @intCast(frozen.snapshot.files().len),
        .excluded_entries = frozen.snapshot.decoded.value.excluded_entries,
        .profiles = .{ .items = choices },
        .catalog = .{ .skills = .{ .items = catalog } },
        .initial = frozen.initial,
        .instructions = try context.instructions(
            ctx.allocator,
            frozen.policy,
            frozen.catalog,
        ),
        .status = .{
            .bytes = try std.fmt.allocPrint(
                ctx.allocator,
                "Initial profile: {s}; effort: {s}; control revision: 0. " ++
                    "Snapshot: {d} files, {d} excluded entries. Authorized typed " ++
                    "Table inputs: {s}",
                .{
                    frozen.initial.selection.profile_id.bytes,
                    @tagName(frozen.initial.selection.effective_effort),
                    frozen.snapshot.files().len,
                    frozen.snapshot.decoded.value.excluded_entries,
                    try native.json.canonical(ctx.allocator, inputs),
                },
            ),
        },
    };
}
fn present(ctx: native.Context, question: t.Question) !native.json.Value {
    var value = native.json.object();
    try native.json.put(ctx.allocator, &value, "prompt", native.json.string(question.prompt.bytes));
    return value;
}
fn providerDeclaration() native.Declaration {
    var value = Adapter.declaration();
    value.capture.?.acquire = acquire;
    value.controller_offer = controllerOffer;
    value.controller_choice = controllerChoice;
    value.controller_permission = controllerPermission;
    return value;
}
fn controllerOffer(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    return Adapter.offerGeneral(
        ctx,
        bytes,
        t.toolMask(.{ "list", "read", "ask", "stop", "program", "work", "context", "placement" }),
    );
}
fn controllerChoice(
    ctx: native.registry.ProjectionContext,
    bytes: []const u8,
) !?contracts.workspace.Adoption {
    var response = try contracts.decodeOwned(t.P.AdaptiveResult, ctx.allocator, bytes);
    defer response.deinit();
    if (response.value.result != .output or response.value.replay_status != .complete) return null;
    const replay = response.value.replay orelse return null;
    var selected: ?contracts.workspace.Adoption = null;
    var calls: usize = 0;
    for (response.value.result.output.items.items) |item| {
        if (item != .function_call) continue;
        calls += 1;
        const call = item.function_call;
        if (call.decoded_action != .decoded) continue;
        const action = call.decoded_action.decoded;
        if (action != .program or action.program.command != .adopt) continue;
        try work.admitAction(ctx, replay, call.call_id, action);
        selected = action.program.command.adopt;
    }
    if (calls != 1 or selected == null) return null;
    return try native.values.fromJson(
        contracts.workspace.Adoption,
        ctx.allocator,
        try native.values.toJson(contracts.workspace.Adoption, ctx.allocator, selected.?),
    );
}
fn controllerPermission(ctx: native.registry.ProjectionContext) !bool {
    return (try tool_resources.policy(ctx)).reconstruct;
}
fn instrumentDeclaration() native.Declaration {
    var value = native.workspace_instrument.declaration(.model);
    value.capture.?.acquire = acquireInstrument;
    return value;
}
fn acquireInstrument(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    const frozen = state(ctx) catch |err| return .{ .definitely_not_sent = err };
    if (frozen.offline) return .{ .definitely_not_sent = error.OfflineInferenceUnavailable };
    var provider = ctx;
    provider.environment = @ptrCast(@constCast(&frozen.provider));
    return native.workspace_instrument.acquire(provider, bytes);
}
fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    const frozen = state(ctx) catch |err| return .{ .definitely_not_sent = err };
    if (frozen.offline) return offlineAcquire(ctx, bytes);
    var provider = ctx;
    provider.environment = @ptrCast(@constCast(&frozen.provider));
    return Adapter.acquire(provider, bytes);
}
const Config = t.Configuration;
fn configuredTools(bits: [8]bool) [t.P.declaration_count]bool {
    var result: [t.P.declaration_count]bool = @splat(false);
    inline for (.{
        "list",
        "read",
        "ask",
        "report",
        "stop",
        "inference_set",
        "skill_set",
        "inspect",
    }, 0..) |name, index| result[
        t.ordinal(name)
    ] = bits[index];
    return result;
}
fn componentCatalog(a: std.mem.Allocator, assets: native.discovery.Assets) ![]const u8 {
    const metadata = (try native.json.parseAsset(
        a,
        assets.application,
        assets.application.len,
    )).value;
    const values = native.json.get(metadata, "resources") orelse return error.MissingArtifact;
    for (values.array.items) |resource| {
        if (std.mem.eql(
            u8,
            try native.json.text(native.json.get(resource, "id") orelse return error.InvalidAssets),
            "tool-construction.catalog",
        ))
            return (try native.values.fromJson(
                contracts.Bytes(null),
                a,
                native.json.get(resource, "base64url") orelse return error.InvalidAssets,
            )).bytes;
    }
    return error.MissingArtifact;
}
fn resourceBytes(resources: []const []const u8, ref: t.model.ArtifactReference) ![]const u8 {
    for (resources) |bytes| if (bytes.len == ref.bytes and std.mem.eql(
        u8,
        &digest(bytes),
        &ref.digest,
    )) return bytes;
    return error.MissingArtifact;
}
fn hex(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(digest(bytes), .lower));
}
fn containsCredential(
    allocator: std.mem.Allocator,
    value: native.json.Value,
    token: []const u8,
) !bool {
    const Frame = struct {
        values: []const native.json.Value,
        keys: ?[]const []const u8 = null,
        index: usize = 0,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    const root = [_]native.json.Value{value};
    try stack.append(allocator, .{ .values = &root });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (frame.index == frame.values.len) {
            _ = stack.pop();
            continue;
        }
        const child = frame.values[frame.index];
        if (frame.keys) |keys| {
            if (std.mem.indexOf(u8, keys[frame.index], token) != null) return true;
        }
        frame.index += 1;
        switch (child) {
            .string => |text| if (std.mem.indexOf(u8, text, token) != null) {
                return true;
            },
            .array => |items| try stack.append(allocator, .{ .values = items.items }),
            .object => |fields| try stack.append(allocator, .{
                .values = fields.values(),
                .keys = fields.keys(),
            }),
            else => {},
        }
    }
    return false;
}
pub fn taskInput(a: std.mem.Allocator, text: []const u8) !t.Input {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidParams;
    return .{ .task = .{ .bytes = try a.dupe(u8, text) } };
}

fn testEndpoint(endpoint: []const u8) bool {
    // The explicit test profile has a non-secret built-in token and only a
    // canonical loopback HTTPS Responses URL. It cannot receive credentials.
    for ([_][]const u8{ "https://127.0.0.1:", "https://[::1]:", "https://localhost:" }) |prefix| {
        if (!std.mem.startsWith(u8, endpoint, prefix)) continue;
        const rest = endpoint[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        if (slash == 0 or !std.mem.eql(u8, rest[slash..], "/v1/responses")) return false;
        for (rest[0..slash]) |byte| if (byte < '0' or byte > '9') return false;
        return (std.fmt.parseInt(u16, rest[0..slash], 10) catch return false) != 0;
    }
    return false;
}

fn fixtureProfile(id: []const u8, model: []const u8) t.model.AdaptiveInferenceProfile {
    return .{
        .id = .{ .bytes = id },
        .model = .{ .bytes = model },
        .reasoning_mode = .standard,
        .reasoning_context = .auto,
        .efforts = .{ .items = &.{ .medium, .high } },
        .effort_update = false,
        .explicit_cache = true,
        .additional_tools = true,
        .cache_diagnostics = true,
        .opaque_family = .{ .bytes = "fixture" },
        .max_output_tokens = null,
        .request_bytes = null,
        .response_bytes = null,
        .timeout_ms = null,
    };
}
pub fn configure(
    a: std.mem.Allocator,
    io: std.Io,
    options: native.configuration.Options,
    frozen: ?native.tasks.FrozenInputs,
    assets: native.discovery.Assets,
) !native.configuration.Admitted {
    var admission: ConfigurationAdmission = .{
        .a = a,
        .io = io,
        .options = options,
        .frozen = frozen,
        .assets = assets,
    };
    try admission.validateOptions();
    try admission.loadConfiguration();
    try admission.profile();
    try admission.validateIdentity();
    try admission.validatePolicy();
    try admission.validateResources();
    try admission.validateToolCatalog();
    try admission.validateToolInputs();
    try admission.selectProfile();
    try admission.credentials();
    return admission.finish();
}

const ConfigurationAdmission = struct {
    a: std.mem.Allocator,
    io: std.Io,
    options: native.configuration.Options,
    frozen: ?native.tasks.FrozenInputs,
    assets: native.discovery.Assets,
    mode: []const u8 = undefined,
    profile_bytes: []const u8 = undefined,
    snapshot: []const u8 = undefined,
    catalog_bytes: []const u8 = undefined,
    token: []const u8 = undefined,
    config: ?Config = null,
    tool_config: ?t.ToolConfiguration = null,
    semantic_config: ?t.SemanticConfiguration = null,
    semantic_policy: ?native.configuration.SemanticPolicy = null,
    reuse_policy: native.configuration.ReusePolicy = .{},
    configuration_digest: ?[]const u8 = null,
    resources: std.ArrayList([]const u8) = .empty,
    skills: std.ArrayList(t.P.AdaptiveSkill) = .empty,
    tool_policy: ?t.ToolPolicy = null,
    policy: t.P.AdaptivePolicy = undefined,
    root: native.json.Value = undefined,
    catalog: contracts.Decoded(t.P.AdaptiveCatalog) = undefined,
    initial: t.model.AdaptiveInferenceProfile = undefined,
    effort: @FieldType(t.model.AdaptiveSelection, "effective_effort") = undefined,
    trust_root: ?[]const u8 = undefined,

    fn profile(s: *ConfigurationAdmission) !void {
        if (s.frozen) |saved| {
            s.profile_bytes = saved.profile;
            try s.resources.appendSlice(s.a, saved.resources);
        } else {
            try s.captureSnapshot();
            try s.loadSkills();
            try s.toolPolicy();
            try s.catalogPolicy();
            try s.profileIdentity();
            try s.profilePolicy();
        }
    }

    fn validateOptions(s: *ConfigurationAdmission) !void {
        if (s.options.test_provider and
            (s.options.offline or s.options.credential_path != null or
                s.options.trust_root_path == null)) return error.InvalidConfiguration;
        if (s.options.offline and
            (s.options.config_path != null or s.options.credential_path != null or
                s.options.trust_root_path != null)) return error.InvalidConfiguration;
        const live_mode = if (s.options.test_provider) "controlled-test" else "live";
        s.mode = if (s.options.offline) "offline" else live_mode;
    }

    fn loadConfiguration(s: *ConfigurationAdmission) !void {
        if (s.options.config_path) |path| {
            const bytes = try native.configuration.readFile(s.a, s.io, path, null, false);
            var parsed = try native.json.parse(s.a, bytes, .{
                .bytes = bytes.len,
                .tokens = bytes.len,
                .members = bytes.len,
            });
            if (parsed.value == .object and !parsed.value.object.contains("semantic_construction"))
                try native.json.put(s.a, &parsed.value, "semantic_construction", .null);
            if (parsed.value == .object and !parsed.value.object.contains("reuse_scopes"))
                try native.json.put(s.a, &parsed.value, "reuse_scopes", .null);
            if (parsed.value == .object) if (parsed.value.object.getPtr("tools")) |tools| {
                if (tools.* == .object and !tools.object.contains(
                    "reconstruct",
                )) try native.json.put(s.a, tools, "reconstruct", .{ .bool = false });
            };
            const value = try native.values.fromJson(t.ConfigurationV3, s.a, parsed.value);
            if (!std.mem.eql(
                u8,
                value.schema.bytes,
                "adaptive-agent.configuration.v3",
            )) return error.InvalidConfiguration;
            s.config = value.adaptive;
            s.tool_config = value.tools;
            s.semantic_config = value.semantic_construction;
            s.semantic_policy = try native.configuration.semanticPolicy(
                s.a,
                parsed.value.object.get("semantic_construction").?,
            );
            s.reuse_policy = try native.configuration.reusePolicy(
                s.a,
                parsed.value.object.get("reuse_scopes").?,
            );
            _ = parsed.value.object.swapRemove("reuse_scopes");
            if (s.frozen) |saved| {
                const saved_profile = try native.json.parse(s.a, saved.profile, .{
                    .bytes = saved.profile.len,
                    .tokens = saved.profile.len,
                    .members = saved.profile.len,
                });
                try native.json.put(s.a, &parsed.value, "semantic_construction", native.json.get(
                    saved_profile.value,
                    "semantic_construction",
                ) orelse .null);
            }
            s.configuration_digest = try hex(s.a, try native.json.canonical(s.a, parsed.value));
        }
    }

    fn captureSnapshot(s: *ConfigurationAdmission) !void {
        if (!s.options.offline and s.config == null) return error.MissingConfiguration;
        s.snapshot = if (s.config) |value| try native.repository.captureWithScratch(
            s.a,
            s.options.scratch_allocator orelse s.a,
            s.io,
            value.snapshot_root.bytes,
        ) else blk: {
            const contents = "pub fn main() void {\n    // The offline fixture has no " ++
                "external effects.\n}\n";
            break :blk try contracts.encodeOwned(
                native.repository.Record,
                s.a,
                .{ .version = 2, .excluded_entries = 0, .files = .{ .items = &.{.{ .path = .{
                    .bytes = "src/main.zig",
                }, .sha256 = digest(contents), .contents = .{ .bytes = contents } }} } },
            );
        };
        try s.resources.append(s.a, s.snapshot);
    }

    fn loadSkills(s: *ConfigurationAdmission) !void {
        if (s.config) |value| {
            for (value.skills.items) |skill| {
                const body = try native.configuration.readFile(
                    s.a,
                    s.io,
                    skill.markdown.bytes,
                    null,
                    false,
                );
                if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidSkill;
                try s.resources.append(s.a, body);
                if (std.mem.eql(u8, skill.id.bytes, "tool-construction")) return error.InvalidSkill;
                try s.skills.append(s.a, .{
                    .id = skill.id,
                    .version = skill.version,
                    .description = skill.description,
                    .instructions = work.reference(body),
                    .tools = configuredTools(skill.tools),
                });
            }
        } else {
            const bodies = [_][]const u8{
                @embedFile("skills/orientation.md"),
                @embedFile("skills/invariant-review.md"),
                @embedFile("skills/technical-reporting.md"),
            };
            const names = [_][]const u8{
                "repository-orientation",
                "invariant-review",
                "technical-reporting",
            };
            for (bodies, names, 0..) |body, name, i| {
                try s.resources.append(s.a, body);
                var tools: [t.P.declaration_count]bool = @splat(false);
                if (i == 1) tools[t.ordinal("inspect")] = true;
                try s.skills.append(s.a, .{
                    .id = .{ .bytes = name },
                    .version = .{ .bytes = "1" },
                    .description = .{ .bytes = name },
                    .instructions = work.reference(body),
                    .tools = tools,
                });
            }
        }
    }

    fn toolPolicy(s: *ConfigurationAdmission) !void {
        if (s.tool_config) |value| {
            const components = try componentCatalog(s.a, s.assets);
            const body = try tool_resources.skillBody(s.a, components);
            try s.resources.append(s.a, body);
            var tools = t.toolMask(.{"program"});
            tools[t.ordinal("program")] = value.build;
            try s.skills.append(s.a, .{
                .id = .{ .bytes = "tool-construction" },
                .version = .{ .bytes = "1" },
                .description = .{
                    .bytes = "Construct general retained computations or reuse the frozen " ++
                        "component catalog and authorized Table values.",
                },
                .instructions = work.reference(body),
                .tools = tools,
            });
            try s.resources.append(s.a, components);
            const inputs = try s.a.alloc(t.ToolInputReference, value.inputs.items.len);
            for (value.inputs.items, inputs, 0..) |input, *out, i| {
                if (input.id.bytes.len == 0) return error.InvalidConfiguration;
                for (value.inputs.items[0..i]) |prior| if (std.mem.eql(
                    u8,
                    prior.id.bytes,
                    input.id.bytes,
                )) return error.InvalidConfiguration;
                const bytes = try tool_resources.inputBytes(s.a, input);
                try s.resources.append(s.a, bytes);
                out.* = .{
                    .id = input.id,
                    .description = input.description,
                    .object = work.reference(bytes),
                };
            }
            s.tool_policy = .{
                .build = value.build,
                .run = value.run,
                .reconstruct = value.reconstruct,
                .catalog = work.reference(components),
                .inputs = .{ .items = inputs },
            };
        }
    }

    fn catalogPolicy(s: *ConfigurationAdmission) !void {
        s.catalog_bytes = try contracts.encodeOwned(t.P.AdaptiveCatalog, s.a, .{ .skills = .{
            .items = s.skills.items,
        } });
        try s.resources.append(s.a, s.catalog_bytes);
        const profiles = if (s.config) |value| value.profiles else blk: {
            const items = try s.a.alloc(t.model.AdaptiveInferenceProfile, 2);
            items[0] = fixtureProfile("analysis", "fixture-model-a");
            items[1] = fixtureProfile("deep", "fixture-model-b");
            break :blk @as(@FieldType(t.P.AdaptivePolicy, "profiles"), .{ .items = items });
        };
        const core = t.toolMask(.{
            "list",
            "read",
            "ask",
            "report",
            "stop",
            "inference_set",
            "skill_set",
            "program",
            "work",
            "context",
            "placement",
        });
        var permitted: [t.P.declaration_count]bool = @splat(true);
        permitted[t.ordinal("program")] = true;
        permitted[t.ordinal("work")] = true;
        permitted[t.ordinal("context")] = true;
        permitted[t.ordinal("placement")] = true;
        s.policy = .{
            .schema = .{ .bytes = t.P.adaptive_policy_identity },
            .endpoint = if (s.config) |value| value.endpoint else .{
                .bytes = "https://offline.invalid/v1/responses",
            },
            .audience = if (s.config) |value| value.audience else .{ .bytes = "offline-fixture" },
            .profiles = profiles,
            .catalog = work.reference(s.catalog_bytes),
            .core_tools = core,
            .permitted_tools = permitted,
        };
    }

    fn profileIdentity(s: *ConfigurationAdmission) !void {
        s.root = native.json.object();
        try native.json.put(s.a, &s.root, "mode", native.json.string(s.mode));
        try native.json.put(s.a, &s.root, "application", native.json.string(t.application_id));
        try native.json.put(
            s.a,
            &s.root,
            "assets",
            native.json.string(try hex(s.a, s.assets.application)),
        );
        try native.json.put(
            s.a,
            &s.root,
            "configuration_digest",
            native.json.string(
                s.configuration_digest orelse try hex(s.a, "adaptive-agent.offline.v1"),
            ),
        );
        try native.json.put(
            s.a,
            &s.root,
            "workspace",
            native.json.string(if (s.config) |value| value.workspace.bytes else "offline-fixture"),
        );
        try native.json.put(
            s.a,
            &s.root,
            "snapshot",
            try native.values.toJson(native.registry.ObjectReference, s.a, .{
                .digest = digest(s.snapshot),
                .bytes = s.snapshot.len,
            }),
        );
    }

    fn profilePolicy(s: *ConfigurationAdmission) !void {
        try native.json.put(
            s.a,
            &s.root,
            "adaptive",
            try native.values.toJson(t.P.AdaptivePolicy, s.a, s.policy),
        );
        if (s.tool_policy) |value| try native.json.put(
            s.a,
            &s.root,
            "tool_construction",
            try native.values.toJson(t.ToolPolicy, s.a, value),
        );
        try native.json.put(s.a, &s.root, "semantic_construction", try native.values.toJson(
            ?t.SemanticConfiguration,
            s.a,
            s.semantic_config,
        ));
        try native.json.put(
            s.a,
            &s.root,
            "initial_profile",
            native.json.string(if (s.config) |value| value.initial_profile.bytes else "analysis"),
        );
        try native.json.put(
            s.a,
            &s.root,
            "initial_effort",
            native.json.string(if (s.config) |value| @tagName(value.initial_effort) else "medium"),
        );
        s.profile_bytes = try native.json.canonical(s.a, s.root);
    }

    fn validateIdentity(s: *ConfigurationAdmission) !void {
        s.root = (try native.json.parse(s.a, s.profile_bytes, .{
            .bytes = s.profile_bytes.len,
            .tokens = s.profile_bytes.len,
            .members = s.profile_bytes.len,
        })).value;
        if (!std.mem.eql(
            u8,
            try native.json.text(
                native.json.get(s.root, "mode") orelse return error.InvalidConfiguration,
            ),
            s.mode,
        ) or
            !std.mem.eql(
                u8,
                try native.json.text(
                    native.json.get(s.root, "application") orelse return error.InvalidConfiguration,
                ),
                t.application_id,
            ) or
            !std.mem.eql(
                u8,
                try native.json.text(
                    native.json.get(s.root, "assets") orelse return error.InvalidConfiguration,
                ),
                try hex(s.a, s.assets.application),
            )) return error.IncompatibleProfile;
        if (s.configuration_digest) |expected| if (!std.mem.eql(
            u8,
            expected,
            try native.json.text(
                native.json.get(
                    s.root,
                    "configuration_digest",
                ) orelse return error.InvalidConfiguration,
            ),
        )) return error.IncompatibleProfile;
    }

    fn validatePolicy(s: *ConfigurationAdmission) !void {
        s.policy = try Admission.policy(s.a, s.profile_bytes);
        if (!s.options.offline) {
            if (s.options.test_provider) {
                if (!testEndpoint(s.policy.endpoint.bytes)) return error.InvalidConfiguration;
            } else if (!std.mem.eql(
                u8,
                s.policy.endpoint.bytes,
                "https://api.openai.com/v1/responses",
            )) return error.InvalidConfiguration;
        }
    }

    fn validateResources(s: *ConfigurationAdmission) !void {
        if (s.resources.items.len < 2) return error.MissingArtifact;
        const snapshot_ref = try native.values.fromJson(
            native.registry.ObjectReference,
            s.a,
            native.json.get(s.root, "snapshot") orelse return error.InvalidConfiguration,
        );
        if (snapshot_ref.bytes != s.resources.items[0].len or !std.mem.eql(
            u8,
            &snapshot_ref.digest,
            &digest(s.resources.items[0]),
        )) return error.InvalidSnapshot;
        s.catalog_bytes = s.resources.items[s.resources.items.len - 1];
        if (s.policy.catalog.bytes != s.catalog_bytes.len or !std.mem.eql(
            u8,
            &s.policy.catalog.digest,
            &digest(s.catalog_bytes),
        )) return error.InvalidSkill;
        s.catalog = try contracts.decodeOwned(t.P.AdaptiveCatalog, s.a, s.catalog_bytes);
        try Admission.validateCatalog(s.policy, s.catalog.value);
        s.tool_policy = if (native.json.get(
            s.root,
            "tool_construction",
        )) |value| try native.values.fromJson(t.ToolPolicy, s.a, value) else null;
        const extra: usize = if (s.tool_policy) |value| 1 + value.inputs.items.len else 0;
        if (s.catalog.value.skills.items.len + 2 + extra != s.resources.items.len)
            return error.MissingArtifact;
        for (s.catalog.value.skills.items) |skill| {
            const body = try resourceBytes(s.resources.items, skill.instructions);
            if (!std.unicode.utf8ValidateSlice(
                body,
            ) or skill.instructions.bytes != body.len or !std.mem.eql(
                u8,
                &skill.instructions.digest,
                &digest(body),
            )) return error.InvalidSkill;
        }
    }

    fn selectProfile(s: *ConfigurationAdmission) !void {
        if (!s.policy.core_tools[
            t.ordinal("program")
        ] or !s.policy.core_tools[
            t.ordinal("work")
        ] or !s.policy.core_tools[
            t.ordinal("context")
        ]) return error.InvalidConfiguration;
        const initial_id = try native.json.text(
            native.json.get(s.root, "initial_profile") orelse return error.InvalidConfiguration,
        );
        s.effort = std.meta.stringToEnum(
            @FieldType(t.model.AdaptiveSelection, "effective_effort"),
            try native.json.text(
                native.json.get(s.root, "initial_effort") orelse return error.InvalidConfiguration,
            ),
        ) orelse return error.InvalidConfiguration;
        var selected: ?t.model.AdaptiveInferenceProfile = null;
        for (s.policy.profiles.items) |entry| if (std.mem.eql(u8, entry.id.bytes, initial_id)) {
            selected = entry;
        };
        s.initial = selected orelse return error.UnknownInferenceProfile;
        var supported = false;
        for (s.initial.efforts.items) |item| supported = supported or item == s.effort;
        if (!supported) return error.UnsupportedEffort;
    }

    fn credentials(s: *ConfigurationAdmission) !void {
        s.token = if (s.options.test_provider) "qualification-only" else "";
        if (s.options.credential_path) |path| s.token = std.mem.trim(
            u8,
            try native.configuration.readFile(s.a, s.io, path, null, true),
            "\r\n",
        );
        s.trust_root = if (s.options.trust_root_path) |path| try native.configuration.readFile(
            s.a,
            s.io,
            path,
            null,
            false,
        ) else null;
        // Frozen bodies as well as the snapshot must not embed the transport secret.
        if (s.options.credential_path != null) {
            if (s.token.len == 0) return error.InvalidCredential;
            for (s.token) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidCredential;
            if (try containsCredential(s.a, s.root, s.token)) return error.UnsafeCredentialFile;
            for (s.resources.items) |resource| if (std.mem.indexOf(
                u8,
                resource,
                s.token,
            ) != null) return error.UnsafeCredentialFile;
        }
    }

    fn finish(s: *ConfigurationAdmission) !native.configuration.Admitted {
        const owner = try s.a.create(State);
        owner.* = .{
            .snapshot = try native.repository.Snapshot.openBorrowed(s.a, s.resources.items[0]),
            .profile_identity = digest(s.profile_bytes),
            .policy = s.policy,
            .catalog = s.catalog.value,
            .tools = s.tool_policy,
            .initial = .{
                .selection = .{
                    .profile_id = s.initial.id,
                    .profile_digest = try Admission.profileDigest(s.a, s.initial),
                    .effective_effort = s.effort,
                    .control_revision = 0,
                },
                .top_effort = s.effort,
                .epoch = 0,
                .epoch_reason = .initial,
                .eviction_generation = 0,
                .skills = .{
                    .items = &.{},
                },
            },
            .provider = .{
                .token = s.token,
                .approved_endpoint = s.policy.endpoint.bytes,
                .trust_root = s.trust_root,
            },
            .offline = s.options.offline,
        };
        // Fail admission before dispatch if catalog metadata cannot fit core input.
        _ = try context.instructions(s.a, s.policy, s.catalog.value);
        return .{
            .id = if (s.options.offline or s.options.test_provider) s.mode else "adaptive",
            .bytes = s.profile_bytes,
            .resources = s.resources.items,
            .environment = owner,
            .semantic_construction = s.semantic_policy,
            .reuse = s.reuse_policy,
        };
    }

    fn validateToolCatalog(s: *ConfigurationAdmission) !void {
        const value = s.tool_policy orelse return;
        const components = try resourceBytes(s.resources.items, value.catalog);
        if (!std.mem.eql(
            u8,
            components,
            try componentCatalog(s.a, s.assets),
        )) return error.InvalidCatalog;
        const expected_body = try tool_resources.skillBody(s.a, components);
        var found = false;
        for (s.catalog.value.skills.items) |skill| if (std.mem.eql(
            u8,
            skill.id.bytes,
            "tool-construction",
        )) {
            if (found or !std.mem.eql(u8, skill.version.bytes, "1") or !std.mem.eql(
                u8,
                try resourceBytes(s.resources.items, skill.instructions),
                expected_body,
            )) return error.InvalidSkill;
            var mask: [t.P.declaration_count]bool = @splat(false);
            mask[t.ordinal("program")] = value.build;
            if (!std.meta.eql(mask, skill.tools)) return error.InvalidSkill;
            found = true;
        };
        if (!found or !s.policy.permitted_tools[
            t.ordinal("program")
        ] or !s.policy.core_tools[
            t.ordinal("program")
        ] or !s.policy.permitted_tools[
            t.ordinal("work")
        ] or !s.policy.core_tools[
            t.ordinal("work")
        ]) return error.InvalidConfiguration;
    }

    fn validateToolInputs(s: *ConfigurationAdmission) !void {
        const value = s.tool_policy orelse return;
        for (value.inputs.items) |input| {
            var admitted = try contracts.decodeOwned(
                contracts.tool_construction.Input,
                s.a,
                try resourceBytes(s.resources.items, input.object),
            );
            defer admitted.deinit();
            if (!std.mem.eql(
                u8,
                admitted.value.schema.bytes,
                try native.values.schemaBytes(t.tool_types.Table, s.a),
            )) return error.InvalidConfiguration;
            var table = try contracts.decodeOwned(
                t.tool_types.Table,
                s.a,
                admitted.value.value.bytes,
            );
            table.deinit();
        }
    }
};

/// Recorded provider scenario, selected only by the explicit offline launch.
/// Watermark belongs to immutable requests, so eviction and restart cannot reset it.
fn offlineAcquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    var prepared = try contracts.decodeOwned(Adapter.Prepared, ctx.allocator, bytes);
    defer prepared.deinit();
    const step = prepared.value.request.plan.watermark;
    const a = ctx.allocator;
    const fixture = try native.json.parse(
        a,
        @embedFile("offline-responses.json"),
        .{ .bytes = 64 * 1024 },
    );
    if (fixture.value != .array or step >= fixture.value.array.items.len) return .{
        .definitely_not_sent = error.InvalidPreparedRequest,
    };
    const response = fixture.value.array.items[@intCast(step)];
    return .{
        .captured = try contracts.encodeOwned(
            native.responses.Raw,
            a,
            .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{
                .bytes = try native.json.canonical(a, response),
            } },
        ),
    };
}
