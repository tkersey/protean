//! Native bindings for the single authored adaptive application.
const std = @import("std");
const native = @import("protean_native");
const t = @import("application_types");
const contracts = @import("protean_contracts");
const context = @import("context.zig");
const work = @import("work.zig");
const tool_work = @import("tool_work.zig");
const tool_resources = @import("tool_resources.zig");
const Adapter = native.adaptive_responses.Adapter(t.P);
const Admission = native.adaptive_responses.Admission(t.P);
const digest = work.digest;
pub const demo_input: t.Input = .{ .task = .{ .bytes = "Explain the fixture entry point using source evidence and exercise the approved adaptive controls." } };
pub const demo_answer: t.Answer = .{ .message = .{ .bytes = "Focus on observable behavior." } };
pub const State = struct { snapshot: native.repository.Snapshot, profile_identity: [32]u8, policy: t.P.AdaptivePolicy, catalog: t.P.AdaptiveCatalog, tools: ?t.ToolPolicy, initial: t.controls.State, provider: native.responses.Environment, offline: bool };
pub const handlers = [_]native.Declaration{
    native.leaf(void, t.Bindings, .{ .identity = t.bindings_identity, .resource_role = "snapshot" }, bindings),
    context.declaration(),
    work.declaration(),
    work.inspectionDeclaration(),
    tool_work.declaration(true),
    tool_work.declaration(false),
    native.question(t.Question, t.Answer, .{ .identity = t.question_identity, .resource_role = "user", .answer_schema_id = t.answer_schema_id }, present),
    native.inbox.declaration(t.Message),
    providerDeclaration(),
};
fn state(ctx: native.Context) !*const State {
    const value: *const State = @ptrCast(@alignCast(ctx.environment orelse return error.MissingConfiguration));
    if (!std.mem.eql(u8, &digest(ctx.profile), &value.profile_identity)) return error.IncompatibleProfile;
    return value;
}
fn bindings(ctx: native.Context, _: void) !t.Bindings {
    const frozen = try state(ctx);
    const choices = try ctx.allocator.alloc(t.controls.ProfileChoice, frozen.policy.profiles.items.len);
    for (choices, frozen.policy.profiles.items) |*out, profile| out.* = t.controls.profileChoice(profile, try Admission.profileDigest(ctx.allocator, profile));
    const catalog = try ctx.allocator.alloc(t.controls.Skill, frozen.catalog.skills.items.len);
    for (catalog, frozen.catalog.skills.items) |*out, skill| out.* = .{ .id = skill.id, .version = skill.version, .instructions = skill.instructions };
    var inputs: native.json.Value = .{ .array = .init(ctx.allocator) };
    if (frozen.tools) |policy| for (policy.inputs.items) |input| {
        var value = native.json.object();
        try native.json.put(ctx.allocator, &value, "id", native.json.string(input.id.bytes));
        try native.json.put(ctx.allocator, &value, "description", native.json.string(input.description.bytes));
        try native.json.put(ctx.allocator, &value, "input_ref", native.json.string(try tool_resources.referenceText(ctx.allocator, input.object)));
        try inputs.array.append(value);
    };
    return .{ .policy = frozen.profile_identity, .snapshot = frozen.snapshot.identity, .files = @intCast(frozen.snapshot.files().len), .excluded_entries = frozen.snapshot.decoded.value.excluded_entries, .profiles = .{ .items = choices }, .catalog = .{ .skills = .{ .items = catalog } }, .initial = frozen.initial, .maximum_model_calls = frozen.policy.model_attempts, .maximum_revision = frozen.policy.control_transitions, .instructions = try context.instructions(ctx.allocator, frozen.policy, frozen.catalog), .status = .{ .bytes = try std.fmt.allocPrint(ctx.allocator, "Initial profile: {s}; effort: {s}; control revision: 0. Snapshot: {d} files, {d} excluded entries. Read-only work allowance: 12; inference allowance: {d}. Tool construction permits at most 4 physical attempts; execution at most 8, subject to that shared work allowance. Authorized typed Table inputs: {s}", .{ frozen.initial.selection.profile_id.bytes, @tagName(frozen.initial.selection.effective_effort), frozen.snapshot.files().len, frozen.snapshot.decoded.value.excluded_entries, frozen.policy.model_attempts, try native.json.canonical(ctx.allocator, inputs) }) } };
}
fn present(ctx: native.Context, question: t.Question) !native.json.Value {
    var value = native.json.object();
    try native.json.put(ctx.allocator, &value, "prompt", native.json.string(question.prompt.bytes));
    return value;
}
fn providerDeclaration() native.Declaration {
    var value = Adapter.declaration();
    value.capture.?.acquire = acquire;
    return value;
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
    inline for (.{ "list", "read", "ask", "report", "stop", "inference_set", "skill_set", "inspect" }, 0..) |name, index| result[t.ordinal(name)] = bits[index];
    return result;
}
fn componentCatalog(a: std.mem.Allocator, assets: native.discovery.Assets) ![]const u8 {
    const metadata = (try native.json.parseAsset(a, assets.application, 1024 * 1024)).value;
    const values = native.json.get(metadata, "resources") orelse return error.MissingArtifact;
    for (values.array.items) |resource| {
        if (std.mem.eql(u8, try native.json.text(native.json.get(resource, "id") orelse return error.InvalidAssets), "tool-construction.catalog"))
            return (try native.values.fromJson(contracts.Bytes(128 * 1024), a, native.json.get(resource, "base64url") orelse return error.InvalidAssets)).bytes;
    }
    return error.MissingArtifact;
}
fn resourceBytes(resources: []const []const u8, ref: t.model.ArtifactReference) ![]const u8 {
    for (resources) |bytes| if (bytes.len == ref.bytes and std.mem.eql(u8, &digest(bytes), &ref.digest)) return bytes;
    return error.MissingArtifact;
}
fn hex(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(digest(bytes), .lower));
}
fn containsCredential(value: native.json.Value, token: []const u8) bool {
    return switch (value) {
        .string => |text| std.mem.indexOf(u8, text, token) != null,
        .array => |items| blk: {
            for (items.items) |item| if (containsCredential(item, token)) break :blk true;
            break :blk false;
        },
        .object => |fields| blk: {
            for (fields.keys(), fields.values()) |key, child| if (std.mem.indexOf(u8, key, token) != null or containsCredential(child, token)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}
pub fn taskInput(a: std.mem.Allocator, text: []const u8) !t.Input {
    if (text.len > 2048 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidParams;
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
    return .{ .id = .{ .bytes = id }, .model = .{ .bytes = model }, .reasoning_mode = .standard, .reasoning_context = .auto, .efforts = .{ .items = &.{ .medium, .high } }, .effort_update = false, .explicit_cache = true, .additional_tools = true, .cache_diagnostics = true, .opaque_family = .{ .bytes = "fixture" }, .max_output_tokens = 4096, .request_bytes = 256 * 1024, .response_bytes = 512 * 1024, .timeout_ms = 1000 };
}
pub fn configure(a: std.mem.Allocator, io: std.Io, options: native.configuration.Options, frozen: ?native.tasks.FrozenInputs, assets: native.discovery.Assets) !native.configuration.Admitted {
    if (options.test_provider and (options.offline or options.credential_path != null or options.trust_root_path == null)) return error.InvalidConfiguration;
    if (options.offline and (options.config_path != null or options.credential_path != null or options.trust_root_path != null)) return error.InvalidConfiguration;
    const mode = if (options.offline) "offline" else if (options.test_provider) "controlled-test" else "live";
    var config: ?Config = null;
    var tool_config: ?t.ToolConfiguration = null;
    var configuration_digest: ?[]const u8 = null;
    if (options.config_path) |path| {
        const bytes = try native.configuration.readFile(a, io, path, 256 * 1024, false);
        const parsed = try native.json.parse(a, bytes, .{ .bytes = 256 * 1024 });
        if (native.json.get(parsed.value, "schema") != null) {
            const value = try native.values.fromJson(t.ConfigurationV2, a, parsed.value);
            if (!std.mem.eql(u8, value.schema.bytes, "adaptive-agent.configuration.v2")) return error.InvalidConfiguration;
            config = value.adaptive;
            tool_config = value.tools;
        } else config = try native.values.fromJson(Config, a, parsed.value);
        configuration_digest = try hex(a, try native.json.canonical(a, parsed.value));
    }
    var resources: std.ArrayList([]const u8) = .empty;
    var profile_bytes: []const u8 = undefined;
    if (frozen) |saved| {
        profile_bytes = saved.profile;
        try resources.appendSlice(a, saved.resources);
    } else {
        if (!options.offline and config == null) return error.MissingConfiguration;
        const snapshot = if (config) |value| try native.repository.captureWithScratch(a, options.scratch_allocator orelse a, io, value.snapshot_root.bytes) else blk: {
            const contents = "pub fn main() void {\n    // The offline fixture has no external effects.\n}\n";
            break :blk try contracts.encodeOwned(native.repository.Record, a, .{ .version = 1, .excluded_entries = 0, .files = .{ .items = &.{.{ .path = .{ .bytes = "src/main.zig" }, .sha256 = digest(contents), .contents = .{ .bytes = contents } }} } });
        };
        try resources.append(a, snapshot);
        var skills: std.ArrayList(t.P.AdaptiveSkill) = .empty;
        if (config) |value| {
            for (value.skills.items) |skill| {
                const body = try native.configuration.readFile(a, io, skill.markdown.bytes, 32 * 1024, false);
                if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidSkill;
                try resources.append(a, body);
                if (std.mem.eql(u8, skill.id.bytes, "tool-construction")) return error.InvalidSkill;
                try skills.append(a, .{ .id = skill.id, .version = skill.version, .description = skill.description, .instructions = work.reference(body), .tools = configuredTools(skill.tools) });
            }
        } else {
            const bodies = [_][]const u8{ @embedFile("skills/orientation.md"), @embedFile("skills/invariant-review.md"), @embedFile("skills/technical-reporting.md") };
            const names = [_][]const u8{ "repository-orientation", "invariant-review", "technical-reporting" };
            for (bodies, names, 0..) |body, name, i| {
                try resources.append(a, body);
                var tools: [t.P.declaration_count]bool = @splat(false);
                if (i == 1) tools[t.ordinal("inspect")] = true;
                try skills.append(a, .{ .id = .{ .bytes = name }, .version = .{ .bytes = "1" }, .description = .{ .bytes = name }, .instructions = work.reference(body), .tools = tools });
            }
        }
        var tool_policy: ?t.ToolPolicy = null;
        if (tool_config) |value| {
            const components = try componentCatalog(a, assets);
            const body = try tool_resources.skillBody(a, components);
            try resources.append(a, body);
            var tools = t.toolMask(.{"tool_build"});
            tools[t.ordinal("tool_build")] = value.build;
            try skills.append(a, .{ .id = .{ .bytes = "tool-construction" }, .version = .{ .bytes = "1" }, .description = .{ .bytes = "Construct reusable, effect-free computations over the frozen component catalog and authorized Table values." }, .instructions = work.reference(body), .tools = tools });
            try resources.append(a, components);
            const inputs = try a.alloc(t.ToolInputReference, value.inputs.items.len);
            for (value.inputs.items, inputs, 0..) |input, *out, i| {
                if (input.id.bytes.len == 0) return error.InvalidConfiguration;
                for (value.inputs.items[0..i]) |prior| if (std.mem.eql(u8, prior.id.bytes, input.id.bytes)) return error.InvalidConfiguration;
                const bytes = try tool_resources.inputBytes(a, input);
                try resources.append(a, bytes);
                out.* = .{ .id = input.id, .description = input.description, .object = work.reference(bytes) };
            }
            tool_policy = .{ .build = value.build, .run = value.run, .catalog = work.reference(components), .inputs = .{ .items = inputs } };
        }
        const catalog = try contracts.encodeOwned(t.P.AdaptiveCatalog, a, .{ .skills = .{ .items = skills.items } });
        try resources.append(a, catalog);
        const profiles = if (config) |value| value.profiles else blk: {
            const items = try a.alloc(t.model.AdaptiveInferenceProfile, 2);
            items[0] = fixtureProfile("analysis", "fixture-model-a");
            items[1] = fixtureProfile("deep", "fixture-model-b");
            break :blk @as(@FieldType(t.P.AdaptivePolicy, "profiles"), .{ .items = items });
        };
        var core = t.toolMask(.{ "list", "read", "ask", "report", "stop", "inference_set", "skill_set", "tool_run" });
        var permitted: [t.P.declaration_count]bool = @splat(true);
        core[t.ordinal("tool_run")] = if (tool_policy) |value| value.run else false;
        permitted[t.ordinal("tool_build")] = if (tool_policy) |value| value.build else false;
        permitted[t.ordinal("tool_run")] = core[t.ordinal("tool_run")];
        const policy: t.P.AdaptivePolicy = .{ .schema = .{ .bytes = t.P.adaptive_policy_identity }, .endpoint = if (config) |value| value.endpoint else .{ .bytes = "https://offline.invalid/v1/responses" }, .audience = if (config) |value| value.audience else .{ .bytes = "offline-fixture" }, .profiles = profiles, .catalog = work.reference(catalog), .core_tools = core, .permitted_tools = permitted, .model_attempts = if (config) |value| value.maximum_model_calls else 16, .control_transitions = if (config) |value| value.maximum_control_revision else 16 };
        var root = native.json.object();
        try native.json.put(a, &root, "mode", native.json.string(mode));
        try native.json.put(a, &root, "application", native.json.string(t.application_id));
        try native.json.put(a, &root, "assets", native.json.string(try hex(a, assets.application)));
        try native.json.put(a, &root, "configuration_digest", native.json.string(configuration_digest orelse try hex(a, "adaptive-agent.offline.v1")));
        try native.json.put(a, &root, "workspace", native.json.string(if (config) |value| value.workspace.bytes else "offline-fixture"));
        try native.json.put(a, &root, "snapshot", try native.values.toJson(native.registry.ObjectReference, a, .{ .digest = digest(snapshot), .bytes = snapshot.len }));
        try native.json.put(a, &root, "adaptive", try native.values.toJson(t.P.AdaptivePolicy, a, policy));
        if (tool_policy) |value| try native.json.put(a, &root, "tool_construction", try native.values.toJson(t.ToolPolicy, a, value));
        try native.json.put(a, &root, "initial_profile", native.json.string(if (config) |value| value.initial_profile.bytes else "analysis"));
        try native.json.put(a, &root, "initial_effort", native.json.string(if (config) |value| @tagName(value.initial_effort) else "medium"));
        profile_bytes = try native.json.canonical(a, root);
    }
    const root = (try native.json.parse(a, profile_bytes, .{ .bytes = 256 * 1024 })).value;
    if (!std.mem.eql(u8, try native.json.text(native.json.get(root, "mode") orelse return error.InvalidConfiguration), mode) or
        !std.mem.eql(u8, try native.json.text(native.json.get(root, "application") orelse return error.InvalidConfiguration), t.application_id) or
        !std.mem.eql(u8, try native.json.text(native.json.get(root, "assets") orelse return error.InvalidConfiguration), try hex(a, assets.application))) return error.IncompatibleProfile;
    if (configuration_digest) |expected| if (!std.mem.eql(u8, expected, try native.json.text(native.json.get(root, "configuration_digest") orelse return error.InvalidConfiguration))) return error.IncompatibleProfile;
    const policy = try Admission.policy(a, profile_bytes);
    if (policy.model_attempts > 16 or policy.control_transitions > 16) return error.InvalidConfiguration;
    if (!options.offline) {
        if (options.test_provider) {
            if (!testEndpoint(policy.endpoint.bytes)) return error.InvalidConfiguration;
        } else if (!std.mem.eql(u8, policy.endpoint.bytes, "https://api.openai.com/v1/responses")) return error.InvalidConfiguration;
    }
    if (resources.items.len < 2) return error.MissingArtifact;
    if (resources.items.len > native.tasks.maximum_resources) return error.Capacity;
    var resource_bytes: usize = 0;
    for (resources.items) |bytes| {
        resource_bytes = try std.math.add(usize, resource_bytes, bytes.len);
        if (resource_bytes > 16 * 1024 * 1024) return error.Capacity;
    }
    const snapshot_ref = try native.values.fromJson(native.registry.ObjectReference, a, native.json.get(root, "snapshot") orelse return error.InvalidConfiguration);
    if (snapshot_ref.bytes != resources.items[0].len or !std.mem.eql(u8, &snapshot_ref.digest, &digest(resources.items[0]))) return error.InvalidSnapshot;
    const catalog_bytes = resources.items[resources.items.len - 1];
    if (policy.catalog.bytes != catalog_bytes.len or !std.mem.eql(u8, &policy.catalog.digest, &digest(catalog_bytes))) return error.InvalidSkill;
    const catalog = try contracts.decodeOwned(t.P.AdaptiveCatalog, a, catalog_bytes);
    try Admission.validateCatalog(policy, catalog.value);
    if (catalog.value.skills.items.len > 32) return error.Capacity;
    const tool_policy = if (native.json.get(root, "tool_construction")) |value| try native.values.fromJson(t.ToolPolicy, a, value) else null;
    const extra: usize = if (tool_policy) |value| 1 + value.inputs.items.len else 0;
    if (catalog.value.skills.items.len + 2 + extra != resources.items.len) return error.MissingArtifact;
    for (catalog.value.skills.items) |skill| {
        const body = try resourceBytes(resources.items, skill.instructions);
        if (!std.unicode.utf8ValidateSlice(body) or skill.instructions.bytes != body.len or !std.mem.eql(u8, &skill.instructions.digest, &digest(body))) return error.InvalidSkill;
    }
    if (tool_policy) |value| {
        const components = try resourceBytes(resources.items, value.catalog);
        if (!std.mem.eql(u8, components, try componentCatalog(a, assets))) return error.InvalidCatalog;
        const expected_body = try tool_resources.skillBody(a, components);
        var found = false;
        for (catalog.value.skills.items) |skill| if (std.mem.eql(u8, skill.id.bytes, "tool-construction")) {
            if (found or !std.mem.eql(u8, skill.version.bytes, "1") or !std.mem.eql(u8, try resourceBytes(resources.items, skill.instructions), expected_body)) return error.InvalidSkill;
            var mask: [t.P.declaration_count]bool = @splat(false);
            mask[t.ordinal("tool_build")] = value.build;
            if (!std.meta.eql(mask, skill.tools)) return error.InvalidSkill;
            found = true;
        };
        if (!found or policy.permitted_tools[t.ordinal("tool_build")] != value.build or policy.core_tools[t.ordinal("tool_build")] or policy.permitted_tools[t.ordinal("tool_run")] != value.run or policy.core_tools[t.ordinal("tool_run")] != value.run) return error.InvalidConfiguration;
        for (value.inputs.items) |input| {
            var admitted = try contracts.decodeOwned(contracts.tool_construction.Input, a, try resourceBytes(resources.items, input.object));
            defer admitted.deinit();
            if (!std.mem.eql(u8, admitted.value.schema.bytes, try native.values.schemaBytes(t.tool_types.Table, a))) return error.InvalidConfiguration;
            var table = try contracts.decodeOwned(t.tool_types.Table, a, admitted.value.value.bytes);
            table.deinit();
        }
    } else if (policy.permitted_tools[t.ordinal("tool_build")] or policy.permitted_tools[t.ordinal("tool_run")]) return error.InvalidConfiguration;
    const initial_id = try native.json.text(native.json.get(root, "initial_profile") orelse return error.InvalidConfiguration);
    const effort = std.meta.stringToEnum(@FieldType(t.model.AdaptiveSelection, "effective_effort"), try native.json.text(native.json.get(root, "initial_effort") orelse return error.InvalidConfiguration)) orelse return error.InvalidConfiguration;
    var selected: ?t.model.AdaptiveInferenceProfile = null;
    for (policy.profiles.items) |profile| if (std.mem.eql(u8, profile.id.bytes, initial_id)) {
        selected = profile;
    };
    const initial = selected orelse return error.UnknownInferenceProfile;
    var supported = false;
    for (initial.efforts.items) |item| supported = supported or item == effort;
    if (!supported) return error.UnsupportedEffort;
    var token: []const u8 = if (options.test_provider) "qualification-only" else "";
    if (options.credential_path) |path| token = std.mem.trim(u8, try native.configuration.readFile(a, io, path, 16 * 1024, true), "\r\n");
    const trust_root = if (options.trust_root_path) |path| try native.configuration.readFile(a, io, path, 256 * 1024, false) else null;
    // Frozen bodies as well as the snapshot must not embed the transport secret.
    if (options.credential_path != null) {
        if (token.len == 0 or token.len > 4096) return error.InvalidCredential;
        for (token) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidCredential;
        if (containsCredential(root, token)) return error.UnsafeCredentialFile;
        for (resources.items) |resource| if (std.mem.indexOf(u8, resource, token) != null) return error.UnsafeCredentialFile;
    }
    const owner = try a.create(State);
    owner.* = .{ .snapshot = try native.repository.Snapshot.openBorrowed(a, resources.items[0]), .profile_identity = digest(profile_bytes), .policy = policy, .catalog = catalog.value, .tools = tool_policy, .initial = .{ .selection = .{ .profile_id = initial.id, .profile_digest = try Admission.profileDigest(a, initial), .effective_effort = effort, .control_revision = 0 }, .top_effort = effort, .epoch = 0, .epoch_reason = .initial, .eviction_generation = 0, .skills = .{ .items = &.{} } }, .provider = .{ .token = token, .approved_endpoint = policy.endpoint.bytes, .trust_root = trust_root }, .offline = options.offline };
    // Fail admission before dispatch if catalog metadata cannot fit core input.
    _ = try context.instructions(a, policy, catalog.value);
    return .{ .id = if (options.offline) "offline" else if (options.test_provider) "controlled-test" else "adaptive", .bytes = profile_bytes, .resources = resources.items, .environment = owner };
}

/// Recorded provider scenario, selected only by the explicit offline launch.
/// Watermark belongs to immutable requests, so eviction and restart cannot reset it.
fn offlineAcquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    var prepared = try contracts.decodeOwned(Adapter.Prepared, ctx.allocator, bytes);
    defer prepared.deinit();
    const step = prepared.value.request.plan.watermark;
    const a = ctx.allocator;
    const fixture = try native.json.parse(a, @embedFile("offline-responses.json"), .{ .bytes = 64 * 1024 });
    if (fixture.value != .array or step >= fixture.value.array.items.len) return .{ .definitely_not_sent = error.InvalidPreparedRequest };
    const response = fixture.value.array.items[@intCast(step)];
    return .{ .captured = try contracts.encodeOwned(native.responses.Raw, a, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = try native.json.canonical(a, response) } }) };
}
