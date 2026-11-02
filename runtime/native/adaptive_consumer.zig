const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const state = @import("state.zig");
const storage = @import("store.zig");
const values = @import("values.zig");
const workspace = @import("workspace_state.zig");
const json = @import("json.zig");

const Instruction = struct {
    role: enum { system, developer },
    content: contracts.Vector(contracts.Utf8, null),
};

fn encodeInstruction(a: std.mem.Allocator, item: json.Value) !?[]u8 {
    if (item != .object) return error.InvalidContext;
    const role = json.get(item, "role") orelse return null;
    if (role != .string) return error.InvalidContext;
    const selected = std.meta.stringToEnum(
        @FieldType(Instruction, "role"),
        role.string,
    ) orelse return null;
    if (json.get(item, "type")) |kind| {
        if (kind == .string and std.mem.eql(u8, kind.string, "additional_tools")) return null;
        return error.InvalidContext;
    }
    const content = json.get(item, "content") orelse return error.InvalidContext;
    if (content != .array) return error.InvalidContext;
    const parts = try a.alloc(contracts.Utf8, content.array.items.len);
    defer a.free(parts);
    for (content.array.items, parts) |part, *out| {
        if (part != .object) return error.InvalidContext;
        const kind = json.get(part, "type") orelse return error.InvalidContext;
        const text = json.get(part, "text") orelse return error.InvalidContext;
        if (kind != .string or !std.mem.eql(u8, kind.string, "input_text") or text != .string)
            return error.InvalidContext;
        out.* = .{ .bytes = text.string };
    }
    return try contracts.encodeOwned(Instruction, a, .{
        .role = selected,
        .content = .{ .items = parts },
    });
}

pub fn Protection(comptime P: type) type {
    return struct {
        const Adapter = @import("adaptive_responses.zig").Adapter(P);
        const Admission = @import("adaptive_responses.zig").Admission(P);
        const ContextReference = @typeInfo(@FieldType(P.AdaptiveResult, "replay")).optional.child;
        const Plan = @FieldType(P.AdaptiveRequest, "plan");
        const Skill = @FieldType(Plan, "skills").Child;
        const ProtectedSkill = struct {
            resource: @FieldType(Skill, "resource"),
            skill_id: @FieldType(Skill, "skill_id"),
            version: @FieldType(Skill, "version"),
            residency: @FieldType(Skill, "residency"),
            active: bool,
        };
        const ProtectedInvocation = struct {
            protocol: @FieldType(P.Request, "protocol"),
            model: @FieldType(P.Request, "model"),
            parameters: @FieldType(P.Request, "parameters"),
            tools: P.Tools,
            selection: @FieldType(P.Request, "selection"),
            response_policy: @FieldType(P.Request, "response_policy"),
            normalization_limits: @FieldType(P.Request, "normalization_limits"),
            maximum_provider_response_bytes: ?u32,
        };
        const Binding = struct {
            context_identity: contracts.Utf8,
            policy: state.Digest,
            profile_id: @FieldType(@FieldType(P.AdaptiveRequest, "selection"), "profile_id"),
            profile_digest: state.Digest,
            effective_effort: @FieldType(
                @FieldType(P.AdaptiveRequest, "selection"),
                "effective_effort",
            ),
            invocation: ProtectedInvocation,
            catalog: @FieldType(Plan, "catalog"),
            skills: contracts.Vector(ProtectedSkill, null),
            materialized: [P.declaration_count]bool,
            declarations: P.Tools,
            answer_schema: state.Digest,
        };

        pub fn identity(a: std.mem.Allocator, request: P.AdaptiveRequest) !state.Digest {
            const invocation = request.invocation;
            const skills = try a.alloc(ProtectedSkill, request.plan.skills.items.len);
            defer a.free(skills);
            for (skills, request.plan.skills.items) |*out, skill| out.* = .{
                .resource = skill.resource,
                .skill_id = skill.skill_id,
                .version = skill.version,
                .residency = skill.residency,
                .active = skill.active,
            };
            const answer_schema = try values.schemaBytes(P.AnswerType, a);
            defer a.free(answer_schema);
            const bytes = try contracts.encodeOwned(Binding, a, .{
                .context_identity = .{ .bytes = P.adaptive_context_identity },
                .policy = request.policy,
                .profile_id = request.selection.profile_id,
                .profile_digest = request.selection.profile_digest,
                .effective_effort = request.selection.effective_effort,
                .invocation = .{
                    .protocol = invocation.protocol,
                    .model = invocation.model,
                    .parameters = invocation.parameters,
                    .tools = invocation.tools,
                    .selection = invocation.selection,
                    .response_policy = invocation.response_policy,
                    .normalization_limits = invocation.normalization_limits,
                    .maximum_provider_response_bytes = invocation.maximum_provider_response_bytes,
                },
                .catalog = request.plan.catalog,
                .skills = .{ .items = skills },
                .materialized = request.materialized,
                .declarations = P.allDeclarations(),
                .answer_schema = storage.digest(answer_schema),
            });
            defer a.free(bytes);
            return storage.digest(bytes);
        }

        pub fn boundIdentity(
            a: std.mem.Allocator,
            request: P.AdaptiveRequest,
            items: []const json.Value,
            origins: []const P.ContextOrigin,
        ) !state.Digest {
            if (items.len != origins.len) return error.InvalidContext;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update("protean.consumer.protected-instructions.v1");
            const metadata = try identity(a, request);
            hash.update(&metadata);
            for (items, origins) |item, origin| {
                if (origin.resident_skill != null) continue;
                const instruction = (try encodeInstruction(a, item)) orelse continue;
                defer a.free(instruction);
                var length: [8]u8 = undefined;
                std.mem.writeInt(u64, &length, @intCast(instruction.len), .little);
                hash.update(&length);
                hash.update(instruction);
            }
            var digest: state.Digest = undefined;
            hash.final(&digest);
            return digest;
        }

        pub fn observe(
            ctx: registry.ProjectionContext,
            reference: ContextReference,
        ) !workspace.ConsumerInterface {
            var arena = std.heap.ArenaAllocator.init(ctx.allocator);
            defer arena.deinit();
            var scoped = ctx;
            scoped.allocator = arena.allocator();
            const policy = try Admission.policy(scoped.allocator, scoped.profile);
            var context = try Adapter.Context.open(scoped, reference, policy.audience.bytes);
            defer context.deinit();
            const source = context.value.source_request;
            const bytes = try scoped.object(
                .{ .digest = source.digest, .bytes = source.bytes },
                std.math.cast(usize, source.bytes) orelse return error.Capacity,
            );
            if (bytes.len != source.bytes or
                !std.meta.eql(storage.digest(bytes), source.digest)) return error.InvalidContext;
            var prepared = try contracts.decodeOwned(Adapter.Prepared, scoped.allocator, bytes);
            defer prepared.deinit();
            var catalog = try Admission.catalog(scoped, policy);
            defer catalog.deinit();
            var reader: @import("adaptive_history.zig").History(P).Reader = .{ .ctx = scoped };
            defer reader.deinit();
            const history = try reader.load(
                context.value.history,
                context.value.plan,
                catalog.value,
            );
            return .{
                .request = .{ .digest = source.digest, .bytes = source.bytes },
                .protected_identity = try boundIdentity(
                    scoped.allocator,
                    prepared.value.request,
                    history.items.array.items,
                    history.origins.items,
                ),
                .model_profile = prepared.value.request.selection.profile_digest,
            };
        }
    };
}

const testing_model = @import("protean").model_invocation;
const TestingProfile = testing_model.Profile(union(enum) { choose: struct { value: u64 } }, .{
    .{ .name = "choose", .description = "Choose a value." },
}, .{});
const testing_skill: testing_model.SkillMaterialization = .{
    .resource = .{ .digest = @splat(3), .bytes = 7 },
    .skill_id = .{ .bytes = "skill" },
    .version = .{ .bytes = "1" },
    .residency = .resident,
    .active = true,
    .introduced_at = 2,
};

fn testingRequest() TestingProfile.AdaptiveRequest {
    return .{
        .invocation = .{
            .protocol = .{ .bytes = testing_model.protocol_identity },
            .model = .{ .bytes = "test-model" },
            .parameters = .{
                .max_output_tokens = 512,
                .temperature = null,
                .reasoning = .{ .effort = .low, .summary = null },
            },
            .messages = .{ .items = &.{.{
                .role = .user,
                .content = .{ .bytes = "Continue the original task." },
            }} },
            .tools = TestingProfile.allDeclarations(),
            .selection = .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false },
            .response_policy = .{
                .store = false,
                .stream = false,
                .background = false,
                .truncation = .disabled,
            },
            .normalization_limits = TestingProfile.normalizationLimits(),
            .maximum_provider_response_bytes = 4096,
        },
        .policy = @splat(4),
        .selection = .{
            .profile_id = .{ .bytes = "profile" },
            .profile_digest = @splat(5),
            .effective_effort = .low,
            .control_revision = 0,
        },
        .plan = .{
            .epoch = 0,
            .reason = .initial,
            .watermark = 0,
            .eviction_generation = 0,
            .prior = null,
            .catalog = .{ .digest = @splat(6), .bytes = 7 },
            .skills = .{ .items = &.{testing_skill} },
        },
        .materialized = .{true},
        .offered = .{true},
        .results = .{ .items = &.{} },
    };
}

test "consumer protection ignores progress and retains the actual interface" {
    const a = std.testing.allocator;
    const baseline = try Protection(TestingProfile).identity(a, testingRequest());
    var advanced = testingRequest();
    advanced.selection.control_revision = 99;
    advanced.plan.epoch = 70;
    advanced.plan.watermark = 91;
    advanced.plan.eviction_generation = 3;
    advanced.plan.reason = .view_change;
    advanced.invocation.messages = .{ .items = &.{} };
    advanced.offered[0] = false;
    advanced.plan.research = .{
        .view = .{ .kind = .view, .id = .{ .bytes = "selected" } },
        .selected_at = 90,
    };
    advanced.results = .{ .items = &.{.{
        .call_id = .{ .bytes = "completed-work" },
        .output = .{ .bytes = "Retained actual result." },
    }} };
    var skill = testing_skill;
    skill.introduced_at = 88;
    advanced.plan.skills = .{ .items = &.{skill} };
    const current = try Protection(TestingProfile).identity(a, advanced);
    try std.testing.expectEqualSlices(u8, &baseline, &current);
}

test "consumer protection distinguishes policy profile materialized interface and skills" {
    const a = std.testing.allocator;
    const baseline = try Protection(TestingProfile).identity(a, testingRequest());
    for (0..7) |change| {
        var changed = testingRequest();
        var skill = testing_skill;
        switch (change) {
            0 => changed.policy[0] ^= 1,
            1 => changed.selection.profile_digest[0] ^= 1,
            2 => changed.selection.effective_effort = .high,
            3 => changed.materialized[0] = false,
            4 => changed.plan.catalog.digest[0] ^= 1,
            5 => {
                skill.resource.digest[0] ^= 1;
                changed.plan.skills = .{ .items = &.{skill} };
            },
            6 => changed.invocation.parameters.max_output_tokens = 513,
            else => unreachable,
        }
        const current = try Protection(TestingProfile).identity(a, changed);
        try std.testing.expect(!std.mem.eql(u8, &baseline, &current));
    }
}

const testing_instructions =
    "[{\"role\":\"system\",\"content\":[" ++
    "{\"type\":\"input_text\",\"text\":\"Original policy.\"}]}," ++
    "{\"role\":\"developer\",\"content\":[" ++
    "{\"type\":\"input_text\",\"text\":\"Examine all inputs.\"}]}]";

fn testingMessage(a: std.mem.Allocator, role: []const u8, text: []const u8) !json.Value {
    var part = json.object();
    try json.put(a, &part, "type", json.string("input_text"));
    try json.put(a, &part, "text", json.string(text));
    var content: json.Value = .{ .array = .init(a) };
    try content.array.append(part);
    var item = json.object();
    try json.put(a, &item, "role", json.string(role));
    try json.put(a, &item, "content", content);
    return item;
}

fn instructionText(item: *json.Value) *json.Value {
    return item.object.getPtr("content").?.array.items[0].object.getPtr("text").?;
}

test "consumer protection binds cumulative instruction contents roles order and additions" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const original = try json.parse(scratch, testing_instructions, .{});
    const origins: [3]TestingProfile.ContextOrigin = @splat(.{ .watermark = 0 });
    const baseline = try Protection(TestingProfile).boundIdentity(
        a,
        testingRequest(),
        original.value.array.items,
        origins[0..2],
    );
    for (0..5) |change| {
        var changed = (try json.parse(scratch, testing_instructions, .{})).value;
        switch (change) {
            0 => instructionText(&changed.array.items[0]).* = json.string("Changed policy."),
            1 => instructionText(&changed.array.items[1]).* = json.string("Examine some inputs."),
            2 => changed.array.items[1].object.getPtr("role").?.* = json.string("system"),
            3 => std.mem.swap(json.Value, &changed.array.items[0], &changed.array.items[1]),
            4 => try changed.array.append(try testingMessage(scratch, "developer", "New rule.")),
            else => unreachable,
        }
        const actual = try Protection(TestingProfile).boundIdentity(
            a,
            testingRequest(),
            changed.array.items,
            origins[0..changed.array.items.len],
        );
        try std.testing.expect(!std.meta.eql(baseline, actual));
    }
}

fn progressHistory(a: std.mem.Allocator, original: json.Value) !json.Value {
    var history = try json.copy(a, original);
    const part = &history.array.items[0].object.getPtr("content").?.array.items[0];
    var marker = json.object();
    try json.put(a, &marker, "mode", json.string("explicit"));
    try json.put(a, part, "prompt_cache_breakpoint", marker);
    try history.array.append(try testingMessage(a, "user", "Current task input."));
    try history.array.append(try testingMessage(a, "assistant", "Ordinary progress."));
    try history.array.append(try testingMessage(a, "developer", "Pinned resident skill."));
    var declarations = json.object();
    try json.put(a, &declarations, "type", json.string("additional_tools"));
    try json.put(a, &declarations, "role", json.string("developer"));
    try json.put(a, &declarations, "tools", .{ .array = .init(a) });
    try history.array.append(declarations);
    return history;
}

test "consumer instruction binding ignores progress markers and independently bound skills" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const original = try json.parse(scratch, testing_instructions, .{});
    const initial: [2]TestingProfile.ContextOrigin = @splat(.{ .watermark = 0 });
    const baseline = try Protection(TestingProfile).boundIdentity(
        a,
        testingRequest(),
        original.value.array.items,
        &initial,
    );
    const history = try progressHistory(scratch, original.value);
    var origins: [6]TestingProfile.ContextOrigin = @splat(.{ .watermark = 99 });
    origins[4].resident_skill = 0;
    var request = testingRequest();
    request.invocation.messages = .{ .items = &.{} };
    request.plan.watermark = 99;
    request.selection.control_revision = 8;
    const actual = try Protection(TestingProfile).boundIdentity(
        a,
        request,
        history.array.items,
        &origins,
    );
    try std.testing.expectEqualSlices(u8, &baseline, &actual);
    origins[4].resident_skill = null;
    const authored = try Protection(TestingProfile).boundIdentity(
        a,
        request,
        history.array.items,
        &origins,
    );
    try std.testing.expect(!std.meta.eql(baseline, authored));
    try std.testing.expectError(error.InvalidContext, Protection(TestingProfile).boundIdentity(
        a,
        request,
        history.array.items,
        origins[0..5],
    ));
}

fn instructionAllocation(a: std.mem.Allocator) !void {
    var history = try json.parse(a, testing_instructions, .{});
    defer history.deinit();
    const origins: [2]TestingProfile.ContextOrigin = @splat(.{ .watermark = 0 });
    _ = try Protection(TestingProfile).boundIdentity(
        a,
        testingRequest(),
        history.value.array.items,
        &origins,
    );
}

test "consumer instruction identity releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, instructionAllocation, .{});
}
