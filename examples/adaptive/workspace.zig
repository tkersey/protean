//! Direct model-action authentication. Only the native owner executes commands.
const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const t = @import("application_types");
const work = @import("work.zig");
const resources = @import("tool_resources.zig");

fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    var request = try contracts.decodeOwned(t.WorkspaceRequest, ctx.allocator, bytes);
    defer request.deinit();
    const action: t.Action = switch (request.value.action) {
        .program => |v| .{ .program = .{ .command = v } },
        .work => |v| .{ .work = .{ .command = v } },
        .context => |v| .{ .context = .{ .command = v } },
    };
    try work.admitAction(ctx, request.value.context, request.value.call_id, action);
    // Descriptions and retained observations grant no new execution. Mutations
    // retain the user's explicit construction/execution permission separately.
    const command = request.value.action;
    var catalog: ?native.registry.ObjectReference = null;
    if (command == .program and command.program == .build) {
        const policy = try resources.policy(ctx);
        if (!policy.build) return error.Unauthorized;
        if (command.program.build.source_kind == .component_recipe) catalog = .{ .digest = policy.catalog.digest, .bytes = policy.catalog.bytes };
    }
    if (command == .program and command.program == .describe and command.program.describe.section == .components) {
        const policy = try resources.policy(ctx);
        catalog = .{ .digest = policy.catalog.digest, .bytes = policy.catalog.bytes };
    }
    if (command == .work) switch (command.work) {
        .start, .advance, .delegate, .interact => {
            const policy = try resources.policy(ctx);
            if (!policy.run) return error.Unauthorized;
        },
        else => {},
    };
    var snapshot: ?native.registry.ObjectReference = null;
    var input: ?native.registry.ObjectReference = null;
    var model: ?native.workspace.ModelBinding = null;
    const delegated = command == .work and command.work == .delegate;
    const reads_snapshot = delegated and command.work.delegate.interpretation == .snapshot;
    if (reads_snapshot or (command == .context and command.context == .materialize and command.context.materialize.input == .snapshot)) {
        const policy = try native.adaptive_responses.Admission(t.P).policy(ctx.allocator, ctx.profile);
        if (!policy.permitted_tools[t.ordinal("read")]) return error.Unauthorized;
        const root = (try native.json.parse(ctx.allocator, ctx.profile, .{ .bytes = ctx.profile.len, .tokens = ctx.profile.len, .members = ctx.profile.len })).value;
        snapshot = try native.values.fromJson(native.registry.ObjectReference, ctx.allocator, native.json.get(root, "snapshot") orelse return error.InvalidConfiguration);
    }
    if (delegated and command.work.delegate.interpretation == .model) {
        const selection = command.work.delegate.interpretation.model;
        const A = native.adaptive_responses.Admission(t.P);
        const policy = try A.policy(ctx.allocator, ctx.profile);
        for (policy.profiles.items) |profile| {
            if (!std.mem.eql(u8, profile.id.bytes, selection.profile_id.bytes)) continue;
            var supported = false;
            for (profile.efforts.items) |effort| supported = supported or std.mem.eql(u8, @tagName(effort), selection.effort.bytes);
            if (!supported) return error.UnsupportedEffort;
            model = .{ .profile_id = profile.id, .profile_digest = try A.profileDigest(ctx.allocator, profile), .settings = .{ .endpoint = policy.endpoint, .audience = policy.audience, .model = profile.model, .effort = selection.effort, .max_output_tokens = profile.max_output_tokens, .request_bytes = profile.request_bytes, .response_bytes = profile.response_bytes, .timeout_ms = profile.timeout_ms }, .reasoning_mode = .{ .bytes = @tagName(profile.reasoning_mode) }, .reasoning_context = .{ .bytes = @tagName(profile.reasoning_context) } };
            break;
        }
        if (model == null) return error.UnknownInferenceProfile;
    }
    if (command == .context and command.context == .materialize and command.context.materialize.input == .authorized_input) {
        const policy = try resources.policy(ctx);
        const requested = command.context.materialize.input.authorized_input.bytes;
        for (policy.inputs.items) |item| if (std.mem.eql(u8, item.id.bytes, requested)) {
            input = .{ .digest = item.object.digest, .bytes = item.object.bytes };
            break;
        };
        if (input == null) return error.UnauthorizedInput;
    }
    return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command, .snapshot = snapshot, .catalog = catalog, .input = input, .model = model });
}
pub fn declaration() native.Declaration {
    return .{ .identity = t.workspace_identity, .resource_role = "workspace", .kind = .workspace, .workspace = authorize, .payload_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.WorkspaceRequest, a);
        }
    }.schema, .resume_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(contracts.workspace.Reply, a);
        }
    }.schema };
}
