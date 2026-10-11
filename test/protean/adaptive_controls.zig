const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kronos = @import("kronos");
const controls = protean.adaptive_controls;
const contracts = protean.contracts;
const model = protean.model_invocation;

test "authored inference control proposes independent effort and model changes without changing skill authority" {
    const allocator = std.testing.allocator;
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const entry = try controls.defineInference(c, try b.constant(void, {}));
    try std.testing.expectEqual(entry, try controls.defineInference(c, try b.constant(void, {})));
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const image = try allocator.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer allocator.free(image);
    _ = try horos.data.program_image.encode(allocator, compiled.program, image);
    const profile: model.AdaptiveInferenceProfile = .{
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
    var other = profile;
    other.id.bytes = "reporting";
    other.model.bytes = "fixture-model-b";
    var profiles = [_]controls.ProfileChoice{ controls.profileChoice(profile, @splat(2)), controls.profileChoice(other, @splat(3)) };
    const state: controls.State = .{
        .selection = .{ .profile_id = profile.id, .profile_digest = @splat(2), .effective_effort = .medium, .control_revision = 5 },
        .top_effort = .medium,
        .epoch = 2,
        .epoch_reason = .model_change,
        .eviction_generation = 1,
        .skills = .{ .items = &.{.{ .resource = .{ .digest = @splat(7), .bytes = 100 }, .skill_id = .{ .bytes = "review" }, .version = .{ .bytes = "1" }, .residency = .resident, .active = true, .introduced_at = 1 }} },
    };
    var input: controls.InferenceInput = .{
        .state = state,
        .profiles = .{ .items = &profiles },
        .maximum_revision = 16,
        .command = .{ .profile_id = profile.id, .effort = .high, .expected_revision = 5, .reason = .{ .bytes = "Inspect a difficult invariant." } },
    };
    // The same image handles all cases; no host changes control state.
    for (0..7) |scenario| {
        input.command.profile_id = profile.id;
        input.command.effort = .high;
        input.command.expected_revision = 5;
        input.maximum_revision = 16;
        profiles[0].profile.effort_update = false;
        switch (scenario) {
            0 => {}, // Effort fallback creates a new lineage.
            1 => input.command.profile_id = other.id,
            2 => input.command.expected_revision = 4,
            3 => input.command.effort = .max,
            4 => input.command.profile_id.bytes = "unapproved",
            5 => {
                input.command.effort = .medium;
                input.maximum_revision = 5; // An idempotent selection costs no revision.
            },
            6 => profiles[0].profile.effort_update = true,
            else => unreachable,
        }
        const args = try contracts.encodeOwned(controls.InferenceInput, allocator, input);
        defer allocator.free(args);
        var output = try kronos.invocation.invoke(allocator, .{ .image = image, .instance = .{ .initial_args = args } });
        defer output.deinit();
        try std.testing.expect(output.record == .completed);
        var decoded = try contracts.decodeOwned(controls.Proposal, allocator, output.record.completed);
        defer decoded.deinit();
        const proposal = decoded.value;
        try std.testing.expectEqualDeep(state.skills, proposal.state.skills);
        try std.testing.expectEqual(state.eviction_generation, proposal.state.eviction_generation);
        switch (scenario) {
            0, 1 => {
                try std.testing.expectEqual(.proposed, proposal.disposition);
                try std.testing.expectEqual(6, proposal.state.selection.control_revision);
                try std.testing.expectEqual(3, proposal.state.epoch);
                try std.testing.expectEqual(.high, proposal.state.top_effort);
                try std.testing.expectEqualStrings(if (scenario == 0) "analysis" else "reporting", proposal.state.selection.profile_id.bytes);
                try std.testing.expectEqual(if (scenario == 0) model.EpochReason.effort_change else model.EpochReason.model_change, proposal.state.epoch_reason);
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
}

test "authored skill control preserves state on rejection and fences actual eviction" {
    const P = model.Profile(union(enum) { inference_set: controls.InferenceSet, skill_set: controls.SkillSet }, .{
        .{ .name = "inference_set", .description = "Select the next inference." },
        .{ .name = "skill_set", .description = "Select approved skill residency." },
    }, .{ .model_id_bytes = 128, .temperature_bytes = 32, .maximum_messages = 4, .message_bytes = 1024, .maximum_output_items = 8, .call_id_bytes = 64, .arguments_json_bytes = 4096, .result_text_bytes = 4096, .provider_response_bytes = 4096 });
    const Input = controls.SkillInput(P);
    const allocator = std.testing.allocator;
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var registry = protean.admission.Registry.init(b.allocator());
    defer registry.deinit();
    const c: protean.Context = .{ .builder = &b, .registry = &registry };
    const entry = try controls.defineSkill(P, c, try b.constant(void, {}));
    const module = b.module(entry, try b.scalar(void));
    try protean.admission.verify(allocator, module, &registry);
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const image = try allocator.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer allocator.free(image);
    _ = try horos.data.program_image.encode(allocator, compiled.program, image);
    const state: controls.State = .{
        .selection = .{ .profile_id = .{ .bytes = "analysis" }, .profile_digest = @splat(2), .effective_effort = .high, .control_revision = 5 },
        .top_effort = .medium,
        .epoch = 2,
        .epoch_reason = .model_change,
        .eviction_generation = 1,
        .skills = .{ .items = &.{} },
    };
    var catalog: [5]controls.Skill = undefined;
    var loaded: [5]model.SkillMaterialization = undefined;
    for ([_][]const u8{ "orientation", "review", "reporting", "fourth", "fifth" }, 0..) |name, i| {
        const reference: model.ArtifactReference = .{ .digest = @splat(@intCast(i + 1)), .bytes = 100 };
        catalog[i] = .{ .id = .{ .bytes = name }, .version = .{ .bytes = "1" }, .instructions = reference };
        loaded[i] = .{ .resource = reference, .skill_id = .{ .bytes = name }, .version = .{ .bytes = "1" }, .residency = .resident, .active = true, .introduced_at = 1 };
    }
    for (0..12) |scenario| {
        loaded[0].residency = .resident;
        var input: Input = .{
            .state = state,
            .catalog = .{ .skills = .{ .items = &catalog } },
            .watermark = 7,
            .maximum_revision = 16,
            .command = .{ .operation = .load, .skill_id = catalog[0].id, .version = .{ .bytes = "1" }, .residency = .resident, .expected_revision = 5, .reason = .{ .bytes = "Use approved guidance." } },
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
            8 => input.maximum_revision = 5,
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
        const args = try contracts.encodeOwned(Input, allocator, input);
        defer allocator.free(args);
        var output = try kronos.invocation.invoke(allocator, .{ .image = image, .instance = .{ .initial_args = args } });
        defer output.deinit();
        try std.testing.expect(output.record == .completed);
        var decoded = try contracts.decodeOwned(controls.Proposal, allocator, output.record.completed);
        defer decoded.deinit();
        const proposal = decoded.value;
        if (scenario >= 5) {
            try std.testing.expectEqual(.rejected, proposal.disposition);
            try std.testing.expectEqualDeep(input.state, proposal.state);
            try std.testing.expectEqual(switch (scenario) {
                5, 10 => controls.Rejection.invalid_operation,
                6 => .version_mismatch,
                7 => .stale_revision,
                8, 9 => .capacity,
                else => .unknown_skill,
            }, proposal.rejection);
        } else if (scenario == 1) {
            try std.testing.expectEqual(.unchanged, proposal.disposition);
            try std.testing.expectEqualDeep(input.state, proposal.state);
        } else {
            try std.testing.expectEqual(.proposed, proposal.disposition);
            try std.testing.expectEqual(6, proposal.state.selection.control_revision);
            try std.testing.expectEqualSlices(u8, &state.selection.profile_digest, &proposal.state.selection.profile_digest);
            try std.testing.expectEqual(.high, proposal.state.selection.effective_effort);
            try std.testing.expectEqual(@as(u64, if (scenario >= 3) 3 else 2), proposal.state.epoch);
            try std.testing.expectEqual(@as(u64, if (scenario >= 3) 2 else 1), proposal.state.eviction_generation);
            try std.testing.expectEqual(state.top_effort, proposal.state.top_effort);
            try std.testing.expectEqual(@as(usize, if (scenario == 3) 0 else 1), proposal.state.skills.items.len);
            if (scenario != 3) try std.testing.expectEqual(scenario == 0, proposal.state.skills.items[0].active);
            if (scenario == 0) try std.testing.expectEqual(7, proposal.state.skills.items[0].introduced_at);
        }
    }
}
