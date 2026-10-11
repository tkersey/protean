const std = @import("std");
const protean = @import("protean");
const native = @import("protean_native");
const contracts = protean.contracts;
const P = protean.model_invocation.Profile(union(enum) { choose: struct { value: u64 } }, .{.{ .name = "choose", .description = "Choose an exact integer." }}, .{
    .model_id_bytes = 128,
    .temperature_bytes = 32,
    .maximum_messages = 4,
    .message_bytes = 256,
    .maximum_output_items = 8,
    .call_id_bytes = 64,
    .arguments_json_bytes = 256,
    .result_text_bytes = 256,
    .provider_response_bytes = 4096,
});
const Adapter = native.responses.Adapter(P);
const Q = protean.model_invocation.Profile(union(enum) { other: struct { flag: bool } }, .{.{ .name = "other", .description = "Choose a flag." }}, P.representation);
const PairInput = struct { first: P.ReferenceRequest, second: Q.ReferenceRequest };
const PairApplication = struct {
    pub fn emit(c: protean.Context) !@import("horos").source.Module {
        const b = c.builder;
        const unit = try c.schema(void);
        const first = try protean.responders.defineReferenceModelObserved(P, c, try b.constant(void, {}), false);
        const second = try protean.responders.defineReferenceModelObserved(Q, c, try b.constant(void, {}), false);
        const entry = try b.declare(&.{try c.schema(PairInput)}, unit, &.{ b.functions.items[first].effects[0], b.functions.items[second].effects[0] }, &.{});
        const input = try b.reference(b.parameter(entry, 0));
        const first_result = try b.variable(try c.schema(protean.responders.ReferenceModelObservation(P, false)));
        const second_result = try b.variable(try c.schema(protean.responders.ReferenceModelObservation(Q, false)));
        const offered = try c.literal([1]bool, .{true});
        const call_first = try b.term(.{ .call = .{ .function = first, .arguments = &.{ try b.primitive(try c.schema(P.ReferenceRequest), .field, &.{input}, 0), offered } } });
        const call_second = try b.term(.{ .call = .{ .function = second, .arguments = &.{ try b.primitive(try c.schema(Q.ReferenceRequest), .field, &.{input}, 1), offered } } });
        try b.define(entry, try b.bind(first_result, call_first, try b.bind(second_result, call_second, try b.pure(try b.constant(void, {})))));
        return b.module(entry, unit);
    }
};

test "native emitter binds authored model specializations to exact schemas and roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const System = protean.system(.{ .InitialArgs = PairInput, .Result = void, .Failure = void, .application = PairApplication });
    var compiled = try protean.compile(a, System);
    defer compiled.deinit();
    const emit = @import("native_asset_writer");
    const identity = protean.model_invocation.reference_semantic_identity;
    const first = .{ .identity = identity, .resource_role = "first-provider", .Payload = P.ReferenceRequest, .Reply = P.ReferenceResult };
    const second = .{ .identity = identity, .resource_role = "second-provider", .Payload = Q.ReferenceRequest, .Reply = Q.ReferenceResult };
    var first_handler = Adapter.declaration();
    first_handler.resource_role = first.resource_role;
    var second_handler = native.responses.Adapter(Q).declaration();
    second_handler.resource_role = second.resource_role;
    var handlers = try native.Registry.init(a, &.{ first_handler, second_handler });
    defer handlers.deinit();
    inline for (.{ .{ first, second }, .{ second, first } }) |declarations| {
        const metadata = try emit.capabilityMetadata(declarations, a, compiled.program);
        try std.testing.expectEqual(2, metadata.len);
        for (handlers.entries) |entry| {
            var matches: usize = 0;
            for (metadata) |item| if (std.mem.eql(u8, item.payload_sha256, &std.fmt.bytesToHex(digest(entry.payload_schema), .lower)) and std.mem.eql(u8, item.resume_sha256, &std.fmt.bytesToHex(digest(entry.resume_schema), .lower))) {
                try std.testing.expectEqualStrings(entry.declaration.identity, item.identity);
                try std.testing.expectEqualStrings(entry.declaration.resource_role, item.resource_role);
                matches += 1;
            };
            try std.testing.expectEqual(1, matches);
        }
    }
    const legacy = .{ .identity = identity, .resource_role = "shared-provider" };
    const shared = try emit.capabilityMetadata(.{ legacy, legacy }, a, compiled.program);
    try std.testing.expectEqual(2, shared.len);
    for (shared) |item| try std.testing.expectEqualStrings("shared-provider", item.resource_role);
    try std.testing.expectError(error.AmbiguousNativeCapability, emit.capabilityMetadata(.{ legacy, .{ .identity = identity, .resource_role = "other-provider" } }, a, compiled.program));
    try std.testing.expectError(error.UndeclaredNativeCapability, emit.capabilityMetadata(.{ first, first }, a, compiled.program));
}
const profile = "{\"responses\":{\"endpoint\":\"https://example.test/v1/responses\",\"audience\":\"openai-fixture\",\"model\":\"fixture-model\",\"effort\":\"medium\",\"max_output_tokens\":4096,\"request_bytes\":16384,\"response_bytes\":4096,\"timeout_ms\":1000}}";

test "Responses cancellation before transport is definitely not sent" {
    var cancelled = std.atomic.Value(bool).init(true);
    const authority: native.registry.Authority = .{ .grants = &.{}, .principal = "fixture", .tenant = "fixture", .inference = true };
    const ctx: native.registry.Context = .{ .allocator = std.testing.allocator, .io = std.testing.io, .authority = &authority, .task_id = "fixture", .profile = profile, .environment = null, .cancellation = &cancelled };
    const result = try Adapter.acquire(ctx, "{}");
    try std.testing.expect(result == .definitely_not_sent);
    try std.testing.expectEqual(error.Canceled, result.definitely_not_sent);
    const adaptive = try native.adaptive_responses.Adapter(P).acquire(ctx, "{}");
    try std.testing.expect(adaptive == .definitely_not_sent);
    try std.testing.expectEqual(error.Canceled, adaptive.definitely_not_sent);
}

fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
const Objects = struct {
    bytes: ?[]const u8 = null,
    raw: ?[]const u8 = null,
    fn read(owner: *anyopaque, a: std.mem.Allocator, ref: native.registry.ObjectReference, limit: usize) ![]u8 {
        const self: *Objects = @ptrCast(@alignCast(owner));
        for ([_]?[]const u8{ self.bytes, self.raw }) |candidate| if (candidate) |bytes| {
            if (bytes.len <= limit and bytes.len == ref.bytes and std.mem.eql(u8, &digest(bytes), &ref.digest)) return a.dupe(u8, bytes);
        };
        return error.MissingArtifact;
    }
};
fn request() P.ReferenceRequest {
    return .{ .profile = digest(profile), .replay = null, .results = .{ .items = &.{} }, .invocation = .{
        .protocol = .{ .bytes = protean.model_invocation.protocol_identity },
        .model = .{ .bytes = "fixture-model" },
        .parameters = .{ .max_output_tokens = 4096, .temperature = null, .reasoning = .{ .effort = .medium, .summary = null } },
        .messages = .{ .items = &.{.{ .role = .user, .content = .{ .bytes = "inspect 雪" } }} },
        .tools = P.allDeclarations(),
        .selection = .{ .minimum_calls = 0, .maximum_calls = 1, .parallel_calls = false },
        .response_policy = .{ .store = false, .stream = false, .background = false, .truncation = .disabled },
        .normalization_limits = P.normalizationLimits(),
        .maximum_provider_response_bytes = 4096,
    } };
}

test "adaptive admission binds selected profiles and skill permissions to the frozen policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Admission = native.adaptive_responses.Admission(P);
    const body = "Inspect the invariant with actual source evidence.";
    const resource: protean.model_invocation.ArtifactReference = .{ .digest = digest(body), .bytes = body.len };
    const catalog_bytes = try contracts.encodeOwned(P.AdaptiveCatalog, a, .{ .skills = .{ .items = &.{.{
        .id = .{ .bytes = "invariant-review" },
        .version = .{ .bytes = "1" },
        .description = .{ .bytes = "Review invariants." },
        .instructions = resource,
        .tools = .{true},
    }} } });
    var objects: Objects = .{ .bytes = catalog_bytes, .raw = body };
    const inference: protean.model_invocation.AdaptiveInferenceProfile = .{
        .id = .{ .bytes = "analysis" },
        .model = .{ .bytes = "fixture-model" },
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
    const policy: P.AdaptivePolicy = .{
        .schema = .{ .bytes = P.adaptive_policy_identity },
        .endpoint = .{ .bytes = "https://example.test/v1/responses" },
        .audience = .{ .bytes = "fixture" },
        .profiles = .{ .items = &.{inference} },
        .catalog = .{ .digest = digest(catalog_bytes), .bytes = catalog_bytes.len },
        .core_tools = .{false},
        .permitted_tools = .{true},
        .model_attempts = 16,
        .control_transitions = 16,
    };
    var frozen = native.json.object();
    try native.json.put(a, &frozen, "adaptive", try native.values.toJson(P.AdaptivePolicy, a, policy));
    const policy_bytes = try native.json.canonical(a, frozen);
    const ctx: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(7), .tenant = "fixture", .profile = policy_bytes, .objects = .{ .owner = &objects, .read = Objects.read } };
    const admitted = try Admission.policy(a, policy_bytes);
    var skills = try Admission.catalog(ctx, admitted);
    defer skills.deinit();
    try Admission.validateCatalog(admitted, skills.value);
    var denied = admitted;
    denied.permitted_tools = .{false};
    try std.testing.expectError(error.InvalidSkill, Admission.validateCatalog(denied, skills.value));
    try std.testing.expectError(error.InvalidSkill, Admission.catalog(ctx, denied));
    var materialization = [_]protean.model_invocation.SkillMaterialization{.{
        .resource = resource,
        .skill_id = .{ .bytes = "invariant-review" },
        .version = .{ .bytes = "1" },
        .residency = .resident,
        .active = true,
        .introduced_at = 1,
    }};
    var adaptive: P.AdaptiveRequest = .{
        .invocation = request().invocation,
        .policy = digest(policy_bytes),
        .selection = .{ .profile_id = inference.id, .profile_digest = try Admission.profileDigest(a, inference), .effective_effort = .medium, .control_revision = 1 },
        .plan = .{ .epoch = 0, .reason = .initial, .watermark = 1, .eviction_generation = 0, .prior = null, .catalog = policy.catalog, .skills = .{ .items = &materialization } },
        .materialized = .{true},
        .offered = .{true},
        .results = .{ .items = &.{} },
    };
    const selected = try Admission.bind(ctx, admitted, adaptive, skills.value);
    try std.testing.expectEqualStrings("fixture-model", selected.transport.model.bytes);
    // Valid effort-only selection changes neither the policy nor resource set.
    adaptive.selection.effective_effort = .high;
    adaptive.invocation.parameters.reasoning.?.effort = .high;
    _ = try Admission.bind(ctx, admitted, adaptive, skills.value);
    adaptive.selection.effective_effort = .max;
    try std.testing.expectError(error.UnsupportedEffort, Admission.bind(ctx, admitted, adaptive, skills.value));
    adaptive.selection.effective_effort = .high;
    adaptive.selection.profile_id.bytes = "unapproved";
    try std.testing.expectError(error.UnknownInferenceProfile, Admission.bind(ctx, admitted, adaptive, skills.value));
    adaptive.selection.profile_id = inference.id;
    adaptive.policy[0] ^= 1;
    try std.testing.expectError(error.IncompatibleProfile, Admission.bind(ctx, admitted, adaptive, skills.value));
    adaptive.policy = digest(policy_bytes);
    // Deactivation retains the definition but removes callable authority.
    materialization[0].active = false;
    try std.testing.expectError(error.InvalidDeclaration, Admission.bind(ctx, admitted, adaptive, skills.value));
    adaptive.offered = .{false};
    _ = try Admission.bind(ctx, admitted, adaptive, skills.value);
    // An unloaded skill cannot justify retaining its exclusive definition.
    adaptive.plan.skills.items = &.{};
    try std.testing.expectError(error.InvalidDeclaration, Admission.bind(ctx, admitted, adaptive, skills.value));
    adaptive.materialized = .{false};
    adaptive.invocation.tools.items = &.{};
    _ = try Admission.bind(ctx, admitted, adaptive, skills.value);
    adaptive.plan.skills.items = &materialization;
    adaptive.materialized = .{true};
    adaptive.invocation.tools = P.allDeclarations();
    objects.raw = "Changed at the old source path.";
    try std.testing.expectError(error.MissingArtifact, Admission.bind(ctx, admitted, adaptive, skills.value));
}

test "native Responses v1 independently specified capture corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var objects: Objects = .{};
    const ctx: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(7), .tenant = "fixture", .profile = profile, .objects = .{ .owner = &objects, .read = Objects.read } };
    var handlers = try native.Registry.init(a, &.{Adapter.declaration()});
    defer handlers.deinit();
    const req = try contracts.encodeOwned(P.ReferenceRequest, a, request());
    const rendered = try Adapter.prepare(ctx, req);
    const fixture = try native.json.parse(a, @embedFile("native-responses-v1.json"), .{});
    var compared: usize = 0;
    const cases = fixture.value.object.get("cases").?.array.items;
    for (cases) |case| {
        const name = case.object.get("name").?.string;
        const raw = try contracts.encodeOwned(native.responses.Raw, a, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = case.object.get("body").?.string } });
        const projection = try Adapter.interpret(ctx, req, rendered, raw);
        var result = try contracts.decodeOwned(P.ReferenceResult, a, projection.reply);
        defer result.deinit();
        try std.testing.expectEqualStrings(case.object.get("result").?.string, @tagName(result.value.result));
        try std.testing.expectEqualStrings(case.object.get("replay").?.string, @tagName(result.value.replay_status));
        if (case.object.get("reason")) |reason| try std.testing.expectEqualStrings(reason.string, @tagName(result.value.result.unsupported_response));
        if (case.object.get("usage")) |expected| {
            const available = result.value.usage orelse return error.MissingUsage;
            try std.testing.expectEqual(try native.json.numberInteger(u64, expected.object.get("input_tokens").?.number_string), available.input_tokens);
            try std.testing.expectEqual(try native.json.numberInteger(u64, expected.object.get("output_tokens").?.number_string), available.output_tokens);
            try std.testing.expectEqual(try native.json.numberInteger(u64, expected.object.get("cached_input_tokens").?.number_string), available.cached_input_tokens.?);
            try std.testing.expectEqual(@as(?u64, available.output_tokens), projection.output_tokens);
            try std.testing.expect(result.value.replay == null and projection.objects.len == 0);
        }
        if (case.object.get("usage_absent") != null) {
            try std.testing.expect(result.value.usage == null);
            try std.testing.expect(projection.output_tokens == null);
        }
        if (case.object.get("result_wire")) |expected| {
            const encoded = try contracts.encodeOwned(P.Result, a, result.value.result);
            const hex = expected.string;
            const expected_bytes = try a.alloc(u8, hex.len / 2);
            _ = try std.fmt.hexToBytes(expected_bytes, hex);
            try std.testing.expectEqualSlices(u8, expected_bytes, encoded);
            compared += 1;
        }
        if (std.mem.eql(u8, name, "reasoning and phase")) {
            try std.testing.expect(result.value.usage == null);
            var artifact = try contracts.decodeOwned(P.Context, a, projection.objects[0]);
            defer artifact.deinit();
            const replay = try native.json.parse(a, artifact.value.items.bytes, .{});
            try std.testing.expectEqualStrings("opaque+/=", replay.value.array.items[1].object.get("encrypted_content").?.string);
            try std.testing.expectEqualStrings("commentary", replay.value.array.items[2].object.get("phase").?.string);
        }
        // Two supplied fields exceed this profile's one-field bound before
        // duplicate-field decoding. The fixed wire fixture independently asserts it too.
        if (std.mem.eql(u8, name, "duplicate arguments")) try std.testing.expectEqual(.capacity, result.value.result.output.items.items[0].function_call.decoded_action.invalid);
        if (std.mem.eql(u8, name, "integral usage spellings")) {
            try std.testing.expectEqual(@as(u64, 12), result.value.usage.?.input_tokens);
            try std.testing.expectEqual(@as(u64, 7), result.value.usage.?.output_tokens);
            try std.testing.expectEqual(@as(?u64, 0), result.value.usage.?.cached_input_tokens);
            try std.testing.expectEqual(@as(?u64, 7), projection.output_tokens);
        }
        if (std.mem.eql(u8, name, "exact integer call")) {
            try std.testing.expectEqual(@as(u64, 9007199254740993), result.value.result.output.items.items[0].function_call.decoded_action.decoded.choose.value);
            try std.testing.expectEqual(@as(?u64, 0), result.value.usage.?.cached_input_tokens);
            objects.bytes = projection.objects[0];
            objects.raw = raw;
            var next = request();
            next.replay = result.value.replay;
            next.invocation.messages = .{ .items = &.{.{ .role = .user, .content = .{ .bytes = "follow up" } }} };
            const missing = try contracts.encodeOwned(P.ReferenceRequest, a, next);
            try std.testing.expectError(error.MissingCallResult, Adapter.prepare(ctx, missing));
            next.results = .{ .items = &.{.{ .call_id = .{ .bytes = "call_1" }, .output = .{ .bytes = "acquired evidence" } }} };
            const paired = try Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, next));
            const parsed = try native.json.parse(a, paired, .{});
            const input = parsed.value.object.get("input").?.array.items;
            try std.testing.expectEqual(4, input.len);
            try std.testing.expectEqualStrings("function_call_output", input[2].object.get("type").?.string);
            try std.testing.expectEqualStrings("follow up", input[3].object.get("content").?.string);
            next.profile[0] ^= 1;
            try std.testing.expectError(error.IncompatibleProfile, Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, next)));
            next.profile[0] ^= 1;
            next.replay.?.task[0] ^= 1;
            try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, next)));
            next.replay.?.task[0] ^= 1;
            objects.raw = null;
            try std.testing.expectError(error.MissingArtifact, Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, next)));
            objects.raw = raw;
            var artifact = try contracts.decodeOwned(P.Context, a, projection.objects[0]);
            defer artifact.deinit();
            artifact.value.task[0] ^= 1;
            const other_task = try contracts.encodeOwned(P.Context, a, artifact.value);
            objects.bytes = other_task;
            next.replay.?.digest = digest(other_task);
            next.replay.?.bytes = other_task.len;
            try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, next)));
            objects.bytes = null;
            try std.testing.expectError(error.MissingArtifact, Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, next)));
        }
    }
    try std.testing.expectEqual(cases.len - 3, compared);
    var bad = request();
    var tools = [_]P.ToolDeclaration{P.allDeclarations().items[0]};
    tools[0].strict = false;
    bad.invocation.tools = .{ .items = &tools };
    try std.testing.expectError(error.InvalidDeclaration, Adapter.prepare(ctx, try contracts.encodeOwned(P.ReferenceRequest, a, bad)));
    const too_small = try std.mem.replaceOwned(u8, a, profile, "16384", "1");
    var bounded = ctx;
    bounded.profile = too_small;
    bad = request();
    bad.profile = digest(too_small);
    try std.testing.expectError(error.Capacity, Adapter.prepare(bounded, try contracts.encodeOwned(P.ReferenceRequest, a, bad)));
    const throttled = try contracts.encodeOwned(native.responses.Raw, a, .{ .status = 429, .identity_encoding = true, .request_id = .{ .bytes = "http_429" }, .body = .{ .bytes = "{}" } });
    const failure = try Adapter.interpret(ctx, req, rendered, throttled);
    var http = try contracts.decodeOwned(P.ReferenceResult, a, failure.reply);
    defer http.deinit();
    try std.testing.expectEqual(.http_status, http.value.result.provider_failure.kind);
    try std.testing.expectEqual(429, http.value.result.provider_failure.http_status);
}
