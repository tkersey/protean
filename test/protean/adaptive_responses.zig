const std = @import("std");
const protean = @import("protean");
const native = @import("protean_native");
const contracts = protean.contracts;
const model = protean.model_invocation;
const P = model.Profile(union(enum) { finish: struct { value: u64 }, inspect: struct { value: u64 } }, .{
    .{ .name = "finish", .description = "Finish with evidence." },
    .{ .name = "inspect", .description = "Inspect an invariant." },
}, .{ .model_id_bytes = 128, .temperature_bytes = 32, .maximum_messages = 4, .message_bytes = 1024, .maximum_output_items = 8, .call_id_bytes = 64, .arguments_json_bytes = 256, .result_text_bytes = 1024, .provider_response_bytes = 4096, .maximum_adaptive_reply_bytes = 1024 });
const Adapter = native.adaptive_responses.Adapter(P);
const Admission = native.adaptive_responses.Admission(P);
const Ref = model.ArtifactReference;
const Objects = struct {
    items: std.ArrayList([]const u8) = .empty,
    denied: ?[32]u8 = null,
    fn add(self: *Objects, a: std.mem.Allocator, bytes: []const u8) !Ref {
        try self.items.append(a, bytes);
        return .{ .digest = digest(bytes), .bytes = bytes.len };
    }
    fn read(owner: *anyopaque, a: std.mem.Allocator, ref: native.registry.ObjectReference, limit: usize) ![]u8 {
        const self: *Objects = @ptrCast(@alignCast(owner));
        if (self.denied) |denied| if (std.mem.eql(u8, &ref.digest, &denied)) return error.MissingArtifact;
        for (self.items.items) |bytes| if (bytes.len == ref.bytes and bytes.len <= limit and std.mem.eql(u8, &digest(bytes), &ref.digest)) return a.dupe(u8, bytes);
        return error.MissingArtifact;
    }
};
fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
fn http(a: std.mem.Allocator, prepared: []const u8) !native.json.Value {
    var decoded = try contracts.decodeOwned(Adapter.Prepared, a, prepared);
    defer decoded.deinit();
    return (try native.json.parse(a, decoded.value.body.bytes, .{})).value;
}
fn capture(ctx: native.registry.ProjectionContext, objects: *Objects, request: P.AdaptiveRequest, call: []const u8) !P.AdaptiveResult {
    const a = ctx.allocator;
    const encoded = try contracts.encodeOwned(P.AdaptiveRequest, a, request);
    const prepared = try Adapter.prepare(ctx, encoded);
    _ = try objects.add(a, prepared);
    const raw = try contracts.encodeOwned(native.responses.Raw, a, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = call } });
    _ = try objects.add(a, raw);
    const projection = try Adapter.interpret(ctx, encoded, prepared, raw);
    for (projection.objects) |object| _ = try objects.add(a, object);
    const decoded = try contracts.decodeOwned(P.AdaptiveResult, a, projection.reply);
    return decoded.value; // The fixture's arena owns all returned slices.
}

fn advance(ctx: native.registry.ProjectionContext, objects: *Objects, request: *P.AdaptiveRequest, call_id: []const u8, opaque_text: []const u8) !void {
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"completed\",\"error\":null,\"output\":[{{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"{s}\"}},{{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"{s}\",\"name\":\"finish\",\"arguments\":\"{{\\\"value\\\":1}}\"}}]}}", .{ opaque_text, call_id });
    const result = try capture(ctx, objects, request.*, body);
    try std.testing.expectEqual(.complete, result.replay_status);
    request.plan.prior = result.replay;
    request.plan.watermark = result.replay.?.watermark;
    const settled = try ctx.allocator.alloc(P.ToolResult, 1);
    settled[0] = .{ .call_id = .{ .bytes = call_id }, .output = .{ .bytes = "Observation retained." } };
    request.results.items = settled;
}

test "adaptive projection preserves history and owns skill and opaque eviction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var objects: Objects = .{};
    const skill_body = "UNIQUE-SKILL-PAYLOAD: inspect state-transition preservation.";
    const skill = try objects.add(a, skill_body);
    const catalog = try objects.add(a, try contracts.encodeOwned(P.AdaptiveCatalog, a, .{ .skills = .{ .items = &.{.{
        .id = .{ .bytes = "invariant" },
        .version = .{ .bytes = "1" },
        .description = .{ .bytes = "Inspect invariants." },
        .instructions = skill,
        .tools = .{ false, true },
    }} } }));
    const inference: model.AdaptiveInferenceProfile = .{
        .id = .{ .bytes = "analysis" },
        .model = .{ .bytes = "fixture-model-a" },
        .reasoning_mode = .standard,
        .reasoning_context = .current_turn,
        .efforts = .{ .items = &.{ .medium, .high } },
        .effort_update = true,
        .explicit_cache = true,
        .additional_tools = true,
        .cache_diagnostics = true,
        .opaque_family = .{ .bytes = "fixture-a" },
        .max_output_tokens = 4096,
        .request_bytes = 16384,
        .response_bytes = 4096,
        .timeout_ms = 1000,
    };
    var other = inference;
    other.id.bytes = "other";
    other.model.bytes = "fixture-model-b";
    var no_additions = other;
    no_additions.id.bytes = "without-additions";
    no_additions.additional_tools = false;
    var no_cache = other;
    no_cache.id.bytes = "without-cache";
    no_cache.explicit_cache = false;
    no_cache.cache_diagnostics = false;
    const policy: P.AdaptivePolicy = .{
        .schema = .{ .bytes = P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://example.test/v1/responses" },
        .audience = .{ .bytes = "fixture" },
        .profiles = .{ .items = &.{ inference, other, no_additions, no_cache } },
        .catalog = catalog,
        .core_tools = .{ true, false },
        .permitted_tools = .{ true, true },
        .model_attempts = 16,
        .control_transitions = 16,
    };
    var frozen = native.json.object();
    try native.json.put(a, &frozen, "adaptive", try native.values.toJson(P.AdaptivePolicy, a, policy));
    const profile_bytes = try native.json.canonical(a, frozen);
    const ctx: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(7), .tenant = "fixture", .profile = profile_bytes, .objects = .{ .owner = &objects, .read = Objects.read } };
    var handlers = try native.Registry.init(a, &.{Adapter.declaration()});
    defer handlers.deinit();
    const Model = protean.model(.{ .name = "adaptive-fixture", .model = "fixture-model-a", .parameters = .{ .max_output_tokens = @as(u32, 4096), .reasoning = .{ .effort = .medium } }, .protocol = struct {
        pub const semantic_identity = model.protocol_identity;
    } });
    var invocation = try P.templateValue(Model, .{ .items = &.{
        .{ .role = .developer, .content = .{ .bytes = "Use actual evidence and approved tools." } },
        .{ .role = .user, .content = .{ .bytes = "Inspect the snapshot." } },
    } }, .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false });
    invocation.tools.items = P.allDeclarations().items[0..1];
    var request: P.AdaptiveRequest = .{
        .invocation = invocation,
        .policy = digest(profile_bytes),
        .selection = .{ .profile_id = inference.id, .profile_digest = try Admission.profileDigest(a, inference), .effective_effort = .medium, .control_revision = 0 },
        .plan = .{ .epoch = 0, .reason = .initial, .watermark = 0, .eviction_generation = 0, .prior = null, .catalog = catalog, .skills = .{ .items = &.{} } },
        .materialized = .{ true, false },
        .offered = .{ true, false },
        .results = .{ .items = &.{} },
    };
    const corpus = try native.json.parse(a, @embedFile("adaptive-responses-v1.json"), .{ .bytes = 64 * 1024 });
    for (corpus.value.object.get("cases").?.array.items) |entry| {
        const result = try capture(ctx, &objects, request, entry.object.get("body").?.string);
        try std.testing.expectEqualStrings(entry.object.get("result").?.string, @tagName(result.result));
        if (entry.object.get("failure")) |failure| {
            const actual = switch (result.result) {
                .unsupported_response => |reason| try native.values.toJson(@TypeOf(reason), a, reason),
                .provider_failure => |value| try native.values.toJson(@TypeOf(value), a, value),
                else => return error.ExpectedFailure,
            };
            try std.testing.expectEqualStrings(try native.json.canonical(a, failure), try native.json.canonical(a, actual));
        }
        try std.testing.expectEqualStrings(entry.object.get("replay").?.string, @tagName(result.replay_status));
        const observed = try native.json.canonical(a, try native.values.toJson(@TypeOf(result.usage), a, result.usage));
        const expected = try native.json.canonical(a, entry.object.get("usage").?);
        try std.testing.expectEqualStrings(expected, observed);
    }
    inline for (.{ .{ "18446744073709551615", std.math.maxInt(u64) }, .{ "9007199254740993", @as(u64, 9007199254740993) }, .{ "1e0", @as(u64, 1) }, .{ "1.0", @as(u64, 1) } }) |case| {
        const body = try std.fmt.allocPrint(a, "{{\"status\":\"completed\",\"error\":null,\"output\":[{{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"exact\",\"name\":\"finish\",\"arguments\":\"{{\\\"value\\\":{s}}}\"}}]}}", .{case[0]});
        const exact = try capture(ctx, &objects, request, body);
        try std.testing.expect(exact.result == .output);
        const call = exact.result.output.items.items[0].function_call;
        try std.testing.expect(call.decoded_action == .decoded);
        try std.testing.expectEqual(case[1], call.decoded_action.decoded.finish.value);
    }
    for ([_][]const u8{
        "[1]",
        "[{\"role\":\"developer\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"https://unapproved.invalid\"}]}]",
        "[{\"type\":\"configuration_update\",\"reasoning\":{\"effort\":\"high\"}},{\"type\":\"configuration_update\",\"reasoning\":{\"effort\":\"medium\"}}]",
    }) |invalid| try std.testing.expectError(error.InvalidContext, Adapter.Context.pending(a, (try native.json.parse(a, invalid, .{})).value));
    const long_text: [900]u8 = @splat('x');
    const oversized = try std.fmt.allocPrint(a, "{{\"status\":\"completed\",\"error\":null,\"output\":[{{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}\",\"annotations\":[]}}]}}],\"usage\":{{\"output_tokens\":9}}}}", .{long_text});
    const limited = try capture(ctx, &objects, request, oversized);
    try std.testing.expect(limited.replay_status == .capacity and limited.replay == null);
    try std.testing.expectEqual(@as(?u64, 9), limited.usage.?.output_tokens);
    const initial_http = try http(a, try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request)));
    const first = try capture(ctx, &objects, request, "{\"id\":\"response-1\",\"status\":\"completed\",\"error\":null,\"output\":[{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"OPAQUE-BEFORE-SKILL\"},{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call-1\",\"name\":\"finish\",\"arguments\":\"{\\\"value\\\":1}\"}]}");
    try std.testing.expect(first.replay_status == .complete and first.usage == null);
    request.plan.prior = first.replay;
    request.plan.watermark = first.replay.?.watermark;
    request.invocation.messages.items = &.{};
    request.results.items = &.{.{ .call_id = .{ .bytes = "call-1" }, .output = .{ .bytes = skill_body } }};
    request.selection.control_revision = 1;
    var loaded = [_]model.SkillMaterialization{.{ .resource = skill, .skill_id = .{ .bytes = "invariant" }, .version = .{ .bytes = "1" }, .residency = .resident, .active = true, .introduced_at = 1 }};
    request.plan.skills.items = &loaded;
    request.materialized = .{ true, true };
    request.offered = .{ true, true };
    request.invocation.tools = P.allDeclarations();
    request.selection.effective_effort = .high;
    const loaded_bytes = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    const loaded_http = try http(a, loaded_bytes);
    const original_input = initial_http.object.get("input").?.array.items;
    const continued_input = loaded_http.object.get("input").?.array.items;
    for (original_input, continued_input[0..original_input.len]) |original, continued| {
        try std.testing.expectEqualStrings(try native.json.canonical(a, original), try native.json.canonical(a, continued));
    }
    var altered = try contracts.decodeOwned(Adapter.Prepared, a, loaded_bytes);
    defer altered.deinit();
    altered.value.body.bytes = try std.mem.replaceOwned(u8, a, altered.value.body.bytes, "\"effort\":\"high\"", "\"effort\":\"medium\"");
    const authority: native.registry.Authority = .{ .grants = &.{}, .principal = "fixture", .tenant = "fixture", .inference = true };
    const acquisition_context: native.Context = .{ .allocator = a, .io = std.testing.io, .authority = &authority, .task_id = "fixture", .profile = profile_bytes, .environment = null };
    const denied_update = try Adapter.acquire(acquisition_context, try contracts.encodeOwned(Adapter.Prepared, a, altered.value));
    try std.testing.expect(denied_update == .definitely_not_sent);
    try std.testing.expectEqual(error.InvalidPreparedRequest, denied_update.definitely_not_sent);
    try std.testing.expectEqualStrings("medium", loaded_http.object.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expect(std.mem.indexOf(u8, loaded_bytes, "configuration_update") != null);
    try std.testing.expectEqual(1, loaded_http.object.get("tools").?.array.items.len);
    try std.testing.expectEqual(2, loaded_http.object.get("tool_choice").?.object.get("tools").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, loaded_bytes, skill_body) != null);
    const second = try capture(ctx, &objects, request, "{\"id\":\"response-2\",\"status\":\"completed\",\"error\":null,\"output\":[{\"type\":\"reasoning\",\"summary\":[],\"content\":[],\"encrypted_content\":\"OPAQUE-WITH-SKILL\"},{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call-2\",\"name\":\"inspect\",\"arguments\":\"{\\\"value\\\":2}\"}],\"usage\":{\"input_tokens\":100,\"output_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":40,\"cache_write_tokens\":20},\"output_tokens_details\":{\"reasoning_tokens\":5}}}");
    try std.testing.expectEqual(@as(?u64, 20), second.usage.?.cache_write_tokens);
    request.plan.prior = second.replay;
    request.plan.watermark = second.replay.?.watermark;
    request.results.items = &.{.{ .call_id = .{ .bytes = "call-2" }, .output = .{ .bytes = "Observed invariant retained." } }};
    loaded[0].active = false;
    request.offered = .{ true, false };
    request.selection.control_revision = 2;
    const inactive = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    try std.testing.expect(std.mem.indexOf(u8, inactive, skill_body) != null);
    const replayed = (try http(a, inactive)).object.get("input").?.array.items;
    var retained_reasoning = false;
    for (replayed) |item| {
        const kind = native.json.get(item, "type") orelse continue;
        if (kind == .string and std.mem.eql(u8, kind.string, "reasoning")) {
            if (!std.mem.eql(u8, "OPAQUE-WITH-SKILL", item.object.get("encrypted_content").?.string)) continue;
            try std.testing.expectEqual(@as(usize, 0), item.object.get("content").?.array.items.len);
            retained_reasoning = true;
        }
    }
    try std.testing.expect(retained_reasoning);
    try std.testing.expectEqual(1, (try http(a, inactive)).object.get("tool_choice").?.object.get("tools").?.array.items.len);
    // Previously materialized extensions remain subject to destination approval.
    var restricted = request;
    restricted.plan.epoch += 1;
    restricted.plan.reason = .model_change;
    restricted.invocation.model = no_additions.model;
    restricted.invocation.parameters.reasoning.?.effort = .medium;
    restricted.selection = .{ .profile_id = no_additions.id, .profile_digest = try Admission.profileDigest(a, no_additions), .effective_effort = .medium, .control_revision = 3 };
    try std.testing.expectError(error.IncompatibleProfile, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, restricted)));
    restricted.selection.profile_id = no_cache.id;
    restricted.selection.profile_digest = try Admission.profileDigest(a, no_cache);
    const uncached = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, restricted));
    const uncached_http = try native.json.canonical(a, try http(a, uncached));
    try std.testing.expect(std.mem.indexOf(u8, uncached_http, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, uncached_http, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, uncached_http, "additional_tools") != null);
    // Eviction must advance its fence, but does not replace the transcript.
    request.plan.skills.items = &.{};
    request.materialized = .{ true, false };
    request.invocation.tools.items = P.allDeclarations().items[0..1];
    try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request)));
    request.plan.epoch = 1;
    request.plan.reason = .eviction;
    request.plan.eviction_generation = 1;
    const evicted = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    const evicted_http = try native.json.canonical(a, try http(a, evicted));
    var retained_evidence = false;
    for ((try http(a, evicted)).object.get("input").?.array.items) |item| {
        if (native.json.get(item, "output")) |output| if (output == .array) for (output.array.items) |part| {
            if (native.json.get(part, "text")) |text| if (text == .string and std.mem.eql(u8, text.string, skill_body)) {
                retained_evidence = true;
            };
        };
        if (native.json.get(item, "content")) |content| if (content == .array) for (content.array.items) |part| {
            if (native.json.get(part, "text")) |text| if (text == .string) try std.testing.expect(!std.mem.eql(u8, text.string, skill_body));
        };
    }
    try std.testing.expect(retained_evidence);
    try std.testing.expect(std.mem.indexOf(u8, evicted_http, "OPAQUE-WITH-SKILL") == null);
    try std.testing.expect(std.mem.indexOf(u8, evicted_http, "OPAQUE-BEFORE-SKILL") != null);
    try std.testing.expect(std.mem.indexOf(u8, evicted_http, "Observed invariant retained.") != null);
    try std.testing.expect(std.mem.indexOf(u8, evicted_http, "configuration_update") != null);
    try std.testing.expectEqualStrings("medium", (try http(a, evicted)).object.get("reasoning").?.object.get("effort").?.string);
    for ((try http(a, evicted)).object.get("input").?.array.items) |item| {
        if (native.json.get(item, "tools")) |definitions| for (definitions.array.items) |definition| {
            try std.testing.expect(!std.mem.eql(u8, definition.object.get("name").?.string, "inspect"));
        };
    }
    // Original captures and the original projection remain byte-identical.
    try std.testing.expect(std.mem.indexOf(u8, loaded_bytes, skill_body) != null);
    var graft = request;
    graft.plan.prior.?.task[0] ^= 1;
    try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, graft)));
    graft = request;
    graft.plan.prior.?.schema.bytes = model.context_semantic_identity;
    try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, graft)));
    objects.denied = request.plan.prior.?.object.digest;
    try std.testing.expectError(error.MissingArtifact, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request)));
    objects.denied = null;
    try std.testing.expectEqualSlices(u8, evicted, try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request)));
    // A new model receives the original visible transcript and settled calls,
    // while prior opaque output and prior-profile effort updates stay excluded.
    const third = try capture(ctx, &objects, request, "{\"id\":\"response-3\",\"status\":\"completed\",\"error\":null,\"output\":[{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call-3\",\"name\":\"finish\",\"arguments\":\"{\\\"value\\\":3}\"}]}");
    request.plan.prior = third.replay;
    request.plan.watermark = third.replay.?.watermark;
    request.plan.epoch = 2;
    request.plan.reason = .model_change;
    request.selection = .{ .profile_id = other.id, .profile_digest = try Admission.profileDigest(a, other), .effective_effort = .medium, .control_revision = 3 };
    request.invocation.model = other.model;
    request.invocation.parameters.reasoning.?.effort = .medium;
    request.results.items = &.{.{ .call_id = .{ .bytes = "call-3" }, .output = .{ .bytes = "Last old-model observation." } }};
    const switched = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    const switched_http = try native.json.canonical(a, try http(a, switched));
    try std.testing.expect(std.mem.indexOf(u8, switched_http, "OPAQUE-BEFORE-SKILL") == null);
    try std.testing.expect(std.mem.indexOf(u8, switched_http, "OPAQUE-WITH-SKILL") == null);
    try std.testing.expect(std.mem.indexOf(u8, switched_http, "configuration_update") == null);
    try std.testing.expect(std.mem.indexOf(u8, switched_http, "Observed invariant retained.") != null);
    try std.testing.expect(std.mem.indexOf(u8, switched_http, "Last old-model observation.") != null);
    const switched_input = (try http(a, switched)).object.get("input").?;
    var settled = try Adapter.Context.pending(a, switched_input);
    defer settled.deinit();
    try std.testing.expectEqual(@as(u32, 0), settled.count());
    // Reactivation must not erase opaque output produced while the transient
    // skill was absent. A single introduced-at cutoff cannot distinguish this.
    try advance(ctx, &objects, &request, "switched", "CLEAN-OPAQUE");
    loaded[0].residency = .transient;
    loaded[0].active = true;
    loaded[0].introduced_at = request.plan.watermark;
    request.plan.skills.items = &loaded;
    request.invocation.tools = P.allDeclarations();
    request.materialized = .{ true, true };
    request.offered = .{ true, true };
    request.selection.control_revision += 1;
    try advance(ctx, &objects, &request, "transient-one", "FIRST-TRANSIENT-OPAQUE");
    loaded[0].active = false;
    request.offered = .{ true, false };
    request.plan.epoch += 1;
    request.plan.eviction_generation += 1;
    request.plan.reason = .eviction;
    request.selection.control_revision += 1;
    try advance(ctx, &objects, &request, "inactive", "INACTIVE-OPAQUE");
    loaded[0].active = true;
    request.offered = .{ true, true };
    request.selection.control_revision += 1;
    try advance(ctx, &objects, &request, "transient-two", "SECOND-TRANSIENT-OPAQUE");
    loaded[0].active = false;
    request.offered = .{ true, false };
    request.plan.epoch += 1;
    request.plan.eviction_generation += 1;
    request.selection.control_revision += 1;
    const reevicted = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    const reevicted_http = try native.json.canonical(a, try http(a, reevicted));
    try std.testing.expect(std.mem.indexOf(u8, reevicted_http, "CLEAN-OPAQUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, reevicted_http, "INACTIVE-OPAQUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, reevicted_http, "FIRST-TRANSIENT-OPAQUE") == null);
    try std.testing.expect(std.mem.indexOf(u8, reevicted_http, "SECOND-TRANSIENT-OPAQUE") == null);
    // Inactive transient bodies are absent, but their definitions remain.
    // Unload must now remove opaque output that saw those exclusive definitions.
    try advance(ctx, &objects, &request, "deactivated-again", "AFTER-DEACTIVATION-OPAQUE");
    request.plan.skills.items = &.{};
    request.invocation.tools.items = P.allDeclarations().items[0..1];
    request.materialized = .{ true, false };
    request.plan.epoch += 1;
    request.plan.eviction_generation += 1;
    request.selection.control_revision += 1;
    const unloaded = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    const unloaded_http = try native.json.canonical(a, try http(a, unloaded));
    try std.testing.expect(std.mem.indexOf(u8, unloaded_http, "CLEAN-OPAQUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, unloaded_http, "INACTIVE-OPAQUE") == null);
    try std.testing.expect(std.mem.indexOf(u8, unloaded_http, "AFTER-DEACTIVATION-OPAQUE") == null);
}
