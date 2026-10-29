const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kosmos = @import("kosmos");
const controls = protean.adaptive_controls;
const contracts = protean.contracts;
const model = protean.model_invocation;

test "inference controls preserve skill authority across effort and model changes" {
    const allocator = std.testing.allocator;
    const image = try controlImage(void, allocator);
    defer allocator.free(image);
    const profile = inferenceProfile();
    var other = profile;
    other.id.bytes = "reporting";
    other.model.bytes = "fixture-model-b";
    var profiles = [_]controls.ProfileChoice{
        controls.profileChoice(profile, @splat(2)),
        controls.profileChoice(other, @splat(3)),
    };
    const state = inferenceState(profile);
    var input: controls.InferenceInput = .{
        .state = state,
        .profiles = .{ .items = &profiles },
        .command = .{
            .profile_id = profile.id,
            .effort = .high,
            .expected_revision = 5,
            .reason = .{ .bytes = "Inspect a difficult invariant." },
        },
    };
    for (0..7) |scenario| {
        selectInferenceScenario(&input, &profiles, profile, other, scenario);
        const args = try contracts.encodeOwned(controls.InferenceInput, allocator, input);
        defer allocator.free(args);
        var output = try kosmos.invocation.invoke(allocator, .{
            .image = image,
            .instance = .{ .initial_args = args },
        });
        defer output.deinit();
        try std.testing.expect(output.record == .completed);
        var decoded = try contracts.decodeOwned(
            controls.Proposal,
            allocator,
            output.record.completed,
        );
        defer decoded.deinit();
        try expectInferenceProposal(state, decoded.value, scenario);
    }
}

fn controlImage(comptime P: type, allocator: std.mem.Allocator) ![]u8 {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c = try protean.Context.init(&b, &registry);
    const unit = try c.literal(void, {});
    const entry = if (P == void)
        try controls.defineInference(c, unit)
    else
        try controls.defineSkill(P, c, unit);
    if (P == void) {
        try std.testing.expectEqual(
            entry,
            try controls.defineInference(c, try c.literal(void, {})),
        );
    }
    const module = try c.author.module(entry, try c.schema(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const image = try allocator.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    errdefer allocator.free(image);
    _ = try horos.data.program_image.encode(allocator, compiled.program, image);
    return image;
}

fn inferenceProfile() model.AdaptiveInferenceProfile {
    return .{
        .id = .{ .bytes = "analysis" },
        .model = .{ .bytes = "fixture-model-a" },
        .reasoning_mode = .standard,
        .reasoning_context = .current_turn,
        .efforts = .{ .items = &.{ .medium, .high } },
        .effort_update = false,
        .explicit_cache = true,
        .additional_tools = true,
        .cache_diagnostics = false,
        .opaque_family = .{ .bytes = "fixture" },
        .max_output_tokens = 4096,
        .request_bytes = 16384,
        .response_bytes = 4096,
        .timeout_ms = 1000,
    };
}

fn inferenceState(profile: model.AdaptiveInferenceProfile) controls.State {
    return .{
        .selection = .{
            .profile_id = profile.id,
            .profile_digest = @splat(2),
            .effective_effort = .medium,
            .control_revision = 5,
        },
        .top_effort = .medium,
        .epoch = 2,
        .epoch_reason = .model_change,
        .eviction_generation = 1,
        .skills = .{ .items = &.{.{
            .resource = .{ .digest = @splat(7), .bytes = 100 },
            .skill_id = .{ .bytes = "review" },
            .version = .{ .bytes = "1" },
            .residency = .resident,
            .active = true,
            .introduced_at = 1,
        }} },
    };
}

fn selectInferenceScenario(
    input: *controls.InferenceInput,
    profiles: *[2]controls.ProfileChoice,
    profile: model.AdaptiveInferenceProfile,
    other: model.AdaptiveInferenceProfile,
    scenario: usize,
) void {
    input.command.profile_id = profile.id;
    input.command.effort = .high;
    input.command.expected_revision = 5;
    profiles[0].profile.effort_update = false;
    switch (scenario) {
        0 => {}, // Effort fallback creates a new lineage.
        1 => input.command.profile_id = other.id,
        2 => input.command.expected_revision = 4,
        3 => input.command.effort = .max,
        4 => input.command.profile_id.bytes = "unapproved",
        5 => {
            input.command.effort = .medium;
        },
        6 => profiles[0].profile.effort_update = true,
        else => unreachable,
    }
}

fn expectInferenceProposal(
    state: controls.State,
    proposal: controls.Proposal,
    scenario: usize,
) !void {
    try std.testing.expectEqualDeep(state.skills, proposal.state.skills);
    try std.testing.expectEqual(state.eviction_generation, proposal.state.eviction_generation);
    switch (scenario) {
        0, 1 => {
            try std.testing.expectEqual(.proposed, proposal.disposition);
            try std.testing.expectEqual(6, proposal.state.selection.control_revision);
            try std.testing.expectEqual(3, proposal.state.epoch);
            try std.testing.expectEqual(.high, proposal.state.top_effort);
            try std.testing.expectEqualStrings(
                if (scenario == 0) "analysis" else "reporting",
                proposal.state.selection.profile_id.bytes,
            );
            try std.testing.expectEqual(
                if (scenario == 0)
                    model.EpochReason.effort_change
                else
                    model.EpochReason.model_change,
                proposal.state.epoch_reason,
            );
        },
        2, 3, 4 => {
            try std.testing.expectEqual(.rejected, proposal.disposition);
            try std.testing.expectEqualDeep(state, proposal.state);
            try std.testing.expectEqual(switch (scenario) {
                2 => controls.Rejection.stale_revision,
                3 => .unsupported_effort,
                else => .unknown_profile,
            }, proposal.rejection);
        },
        5 => {
            try std.testing.expectEqual(.unchanged, proposal.disposition);
            try std.testing.expectEqualDeep(state, proposal.state);
        },
        6 => {
            try std.testing.expectEqual(.proposed, proposal.disposition);
            try std.testing.expectEqual(.high, proposal.state.selection.effective_effort);
            try std.testing.expectEqual(.medium, proposal.state.top_effort);
            try std.testing.expectEqual(2, proposal.state.epoch);
        },
        else => unreachable,
    }
}

const SkillProfile = model.Profile(
    union(enum) { inference_set: controls.InferenceSet, skill_set: controls.SkillSet },
    .{
        .{ .name = "inference_set", .description = "Select the next inference." },
        .{ .name = "skill_set", .description = "Select approved skill residency." },
    },
    .{
        .model_id_bytes = 128,
        .temperature_bytes = 32,
        .maximum_messages = 4,
        .message_bytes = 1024,
        .maximum_output_items = 8,
        .call_id_bytes = 64,
        .arguments_json_bytes = 4096,
        .result_text_bytes = 4096,
        .provider_response_bytes = 4096,
    },
);

fn skillState() controls.State {
    return .{
        .selection = .{
            .profile_id = .{ .bytes = "analysis" },
            .profile_digest = @splat(2),
            .effective_effort = .high,
            .control_revision = 5,
        },
        .top_effort = .medium,
        .epoch = 2,
        .epoch_reason = .model_change,
        .eviction_generation = 1,
        .skills = .{ .items = &.{} },
    };
}

test "skill controls preserve rejected state and fence actual eviction" {
    const Input = controls.SkillInput(SkillProfile);
    const allocator = std.testing.allocator;
    const image = try controlImage(SkillProfile, allocator);
    defer allocator.free(image);
    const state = skillState();
    var catalog: [5]controls.Skill = undefined;
    var loaded: [5]model.SkillMaterialization = undefined;
    for ([_][]const u8{ "orientation", "review", "reporting", "fourth", "fifth" }, 0..) |name, i| {
        const reference: model.ArtifactReference = .{
            .digest = @splat(@intCast(i + 1)),
            .bytes = 100,
        };
        catalog[i] = .{
            .id = .{ .bytes = name },
            .version = .{ .bytes = "1" },
            .instructions = reference,
        };
        loaded[i] = .{
            .resource = reference,
            .skill_id = .{ .bytes = name },
            .version = .{ .bytes = "1" },
            .residency = .resident,
            .active = true,
            .introduced_at = 1,
        };
    }
    for (0..12) |scenario| {
        const input = skillInput(state, &catalog, &loaded, scenario);
        const args = try contracts.encodeOwned(Input, allocator, input);
        defer allocator.free(args);
        var output = try kosmos.invocation.invoke(allocator, .{
            .image = image,
            .instance = .{ .initial_args = args },
        });
        defer output.deinit();
        try std.testing.expect(output.record == .completed);
        var decoded = try contracts.decodeOwned(
            controls.Proposal,
            allocator,
            output.record.completed,
        );
        defer decoded.deinit();
        try expectSkillProposal(state, input, decoded.value, scenario);
    }
}

fn skillInput(
    state: controls.State,
    catalog: []const controls.Skill,
    loaded: []model.SkillMaterialization,
    scenario: usize,
) controls.SkillInput(SkillProfile) {
    const Input = controls.SkillInput(SkillProfile);
    loaded[0].residency = .resident;
    var input: Input = .{
        .state = state,
        .catalog = .{ .skills = .{ .items = catalog } },
        .watermark = 7,
        .command = .{ .operation = .load, .skill_id = catalog[0].id, .version = .{
            .bytes = "1",
        }, .residency = .resident, .expected_revision = 5, .reason = .{
            .bytes = "Use approved guidance.",
        } },
    };
    switch (scenario) {
        0 => {},
        1 => input.state.skills.items = loaded[0..1],
        2, 3, 4 => {
            input.state.skills.items = loaded[0..1];
            input.command.operation = if (scenario == 3) .unload else .deactivate;
            input.command.residency = .unchanged;
            if (scenario == 4) loaded[0].residency = .transient;
        },
        5 => input.command.residency = .unchanged,
        6 => input.command.version.bytes = "2",
        7 => input.command.expected_revision = 4,
        8 => {
            input.state.selection.control_revision = 17;
            input.command.expected_revision = 17;
        },
        9 => {
            input.state.skills.items = loaded[0..4];
            input.command.skill_id = catalog[4].id;
        },
        10 => {
            input.state.skills.items = loaded[0..1];
            input.command.residency = .transient;
        },
        11 => input.command.skill_id.bytes = "unapproved",
        else => unreachable,
    }
    return input;
}

fn expectSkillProposal(
    state: controls.State,
    input: controls.SkillInput(SkillProfile),
    proposal: controls.Proposal,
    scenario: usize,
) !void {
    if (scenario == 8 or scenario == 9) {
        try std.testing.expectEqual(.proposed, proposal.disposition);
        try std.testing.expectEqual(
            input.state.selection.control_revision + 1,
            proposal.state.selection.control_revision,
        );
        try std.testing.expectEqual(
            @as(usize, if (scenario == 9) 5 else 1),
            proposal.state.skills.items.len,
        );
    } else if (scenario >= 5) {
        try std.testing.expectEqual(.rejected, proposal.disposition);
        try std.testing.expectEqualDeep(input.state, proposal.state);
        try std.testing.expectEqual(switch (scenario) {
            5, 10 => controls.Rejection.invalid_operation,
            6 => .version_mismatch,
            7 => .stale_revision,
            else => .unknown_skill,
        }, proposal.rejection);
    } else if (scenario == 1) {
        try std.testing.expectEqual(.unchanged, proposal.disposition);
        try std.testing.expectEqualDeep(input.state, proposal.state);
    } else {
        try std.testing.expectEqual(.proposed, proposal.disposition);
        try std.testing.expectEqual(6, proposal.state.selection.control_revision);
        try std.testing.expectEqualSlices(
            u8,
            &state.selection.profile_digest,
            &proposal.state.selection.profile_digest,
        );
        try std.testing.expectEqual(.high, proposal.state.selection.effective_effort);
        try std.testing.expectEqual(@as(u64, if (scenario >= 3) 3 else 2), proposal.state.epoch);
        try std.testing.expectEqual(
            @as(u64, if (scenario >= 3) 2 else 1),
            proposal.state.eviction_generation,
        );
        try std.testing.expectEqual(state.top_effort, proposal.state.top_effort);
        try std.testing.expectEqual(
            @as(usize, if (scenario == 3) 0 else 1),
            proposal.state.skills.items.len,
        );
        if (scenario != 3) try std.testing.expectEqual(
            scenario == 0,
            proposal.state.skills.items[0].active,
        );
        if (scenario == 0) try std.testing.expectEqual(
            7,
            proposal.state.skills.items[0].introduced_at,
        );
    }
}
