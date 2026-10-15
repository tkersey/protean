const std = @import("std");
const protean = @import("protean");
const native = @import("protean_native");
const contracts = protean.contracts;
const model = protean.model_invocation;
const CurrentProfile = model.Profile(union(enum) { finish: struct { value: u64 }, inspect: struct { value: u64 } }, .{
    .{ .name = "finish", .description = "Finish with evidence." },
    .{ .name = "inspect", .description = "Inspect an invariant." },
}, .{ .model_id_bytes = 128, .temperature_bytes = 32, .maximum_messages = 4, .message_bytes = 1024, .maximum_output_items = 8, .call_id_bytes = 64, .arguments_json_bytes = 256, .result_text_bytes = 1024, .provider_response_bytes = 4096, .maximum_adaptive_reply_bytes = 1024 });
const Ref = model.ArtifactReference;
const Objects = struct {
    items: std.ArrayList([]const u8) = .empty,
    denied: ?[32]u8 = null,
    reads: usize = 0,
    read_bytes: usize = 0,
    fn add(self: *Objects, a: std.mem.Allocator, bytes: []const u8) !Ref {
        try self.items.append(a, bytes);
        return .{ .digest = digest(bytes), .bytes = bytes.len };
    }
    fn read(owner: *anyopaque, a: std.mem.Allocator, ref: native.registry.ObjectReference, limit: usize) ![]u8 {
        const self: *Objects = @ptrCast(@alignCast(owner));
        if (self.denied) |denied| if (std.mem.eql(u8, &ref.digest, &denied)) return error.MissingArtifact;
        for (self.items.items) |bytes| if (bytes.len == ref.bytes and bytes.len <= limit and std.mem.eql(u8, &digest(bytes), &ref.digest)) {
            self.reads += 1;
            self.read_bytes += bytes.len;
            return a.dupe(u8, bytes);
        };
        return error.MissingArtifact;
    }
};
fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
test "chunked adaptive projection preserves history and appends without prefixes" {
    try Fixture(CurrentProfile).preservation();
    try Fixture(CurrentProfile).scaling(false);
}
test "owned adaptive projection reuses checked ancestry in one integrity epoch" {
    try Fixture(CurrentProfile).scaling(true);
}

fn Fixture(comptime P: type) type {
    return struct {
        const Adapter = native.adaptive_responses.Adapter(P);
        const Admission = native.adaptive_responses.Admission(P);
        fn expectDependency(edges: []const native.registry.Dependency, bytes: []const u8, child: Ref) !void {
            for (edges) |edge| {
                if (std.mem.eql(u8, &edge.parent.digest, &digest(bytes)) and edge.parent.bytes == bytes.len and
                    std.mem.eql(u8, &edge.child.digest, &child.digest) and edge.child.bytes == child.bytes) return;
            }
            return error.MissingProjectionDependency;
        }
        fn checkDependencies(a: std.mem.Allocator, projection: native.registry.Projection) !void {
            const codec = Adapter.declaration().capture.?.dependencies;
            const edges = try codec(a, projection.objects);
            defer a.free(edges);
            if (projection.objects.len == 0) {
                try std.testing.expectEqual(@as(usize, 0), edges.len);
                return;
            }
            const bytes = projection.objects[projection.objects.len - 1];
            var root = try contracts.decodeOwned(P.AdaptiveContext, a, bytes);
            defer root.deinit();
            try expectDependency(edges, bytes, root.value.source_capture);
            try expectDependency(edges, bytes, root.value.source_request);
            try expectDependency(edges, bytes, root.value.plan.catalog);
            if (root.value.plan.prior) |prior| try expectDependency(edges, bytes, prior.object);
            if (root.value.history) |history| try expectDependency(edges, bytes, history.object);
            for (projection.objects[0 .. projection.objects.len - 1]) |chunk_bytes| {
                var chunk = try contracts.decodeOwned(P.HistoryChunk, a, chunk_bytes);
                defer chunk.deinit();
                if (chunk.value.previous) |previous| try expectDependency(edges, chunk_bytes, previous.object);
            }
            root.value.schema.bytes = "agent.model.context.responses.adaptive.v5";
            const wrong_schema = try contracts.encodeOwned(P.AdaptiveContext, a, root.value);
            defer a.free(wrong_schema);
            try std.testing.expectError(error.InvalidProjection, codec(a, &.{wrong_schema}));
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
            try checkDependencies(a, projection);
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

        pub fn preservation() !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var objects: Objects = .{};
            const skill_body = "UNIQUE-SKILL-PAYLOAD: inspect state-transition preservation.";
            const skill = try objects.add(a, skill_body);
            // The exercised skill lies beyond the former catalog/bitmask boundary.
            // Every existing load, transient, round-trip and eviction assertion below
            // must still track its actual ownership, independently of matching text.
            const entries = try a.alloc(P.AdaptiveSkill, 33);
            for (entries[0..32], 0..) |*entry, i| entry.* = .{
                .id = .{ .bytes = try std.fmt.allocPrint(a, "unused-{d}", .{i}) },
                .version = .{ .bytes = "1" },
                .description = .{ .bytes = "Approved but never loaded." },
                .instructions = skill,
                .tools = .{ false, false },
            };
            entries[32] = .{
                .id = .{ .bytes = "invariant" },
                .version = .{ .bytes = "1" },
                .description = .{ .bytes = "Inspect invariants." },
                .instructions = skill,
                .tools = .{ false, true },
            };
            const catalog = try objects.add(a, try contracts.encodeOwned(P.AdaptiveCatalog, a, .{ .skills = .{ .items = entries } }));
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
            };
            var frozen = native.json.object();
            try native.json.put(a, &frozen, "adaptive", try native.values.toJson(P.AdaptivePolicy, a, policy));
            const profile_bytes = try native.json.canonical(a, frozen);
            const ctx: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(7), .tenant = "fixture", .profile = profile_bytes, .objects = .validating(&objects, Objects.read) };
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
            try skillOriginRejections(ctx, &objects, request);
            // CTX-05/06/07: an explicit view replaces research exchanges while
            // preserving policy, user amendments, current tools, and skills.
            var viewing = request;
            viewing.plan.epoch += 1;
            viewing.plan.reason = .view_change;
            viewing.plan.research = .{ .view = .{ .kind = .view, .id = .{ .bytes = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" } }, .selected_at = viewing.plan.watermark };
            viewing.results.items = &.{.{ .call_id = .{ .bytes = "call-2" }, .output = .{ .bytes = "SELECTED-VIEW: partial evidence; expand retained sources for omitted items." } }};
            viewing.invocation.messages.items = &.{.{ .role = .user, .content = .{ .bytes = "LATEST-USER-AMENDMENT: include the rare exception." } }};
            const view_prepared = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, viewing));
            const view_http = try http(a, view_prepared);
            const view_text = try native.json.canonical(a, view_http);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "call-1") == null);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "call-2") != null);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "OPAQUE-") == null);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "SELECTED-VIEW") != null);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "LATEST-USER-AMENDMENT") != null);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "Use actual evidence and approved tools.") != null);
            try std.testing.expect(std.mem.indexOf(u8, view_text, "Inspect the snapshot.") != null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, view_text, skill_body));
            try std.testing.expectEqual(@as(usize, 2), view_http.object.get("tool_choice").?.object.get("tools").?.array.items.len);
            var bad_view = viewing;
            bad_view.plan.epoch = request.plan.epoch;
            try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, bad_view)));
            bad_view = viewing;
            bad_view.plan.research.?.selected_at -= 1;
            try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, bad_view)));
            try advance(ctx, &objects, &viewing, "after-view", "OPAQUE-AFTER-VIEW");
            viewing.invocation.messages.items = &.{};
            viewing.plan.epoch += 1;
            viewing.plan.reason = .model_change;
            viewing.plan.eviction_generation += 1;
            viewing.plan.skills.items = &.{};
            viewing.materialized = .{ true, false };
            viewing.offered = .{ true, false };
            viewing.invocation.tools.items = P.allDeclarations().items[0..1];
            viewing.invocation.model = other.model;
            viewing.invocation.parameters.reasoning.?.effort = .medium;
            viewing.selection = .{ .profile_id = other.id, .profile_digest = try Admission.profileDigest(a, other), .effective_effort = .medium, .control_revision = 2 };
            const changed_view = try native.json.canonical(a, try http(a, try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, viewing))));
            try std.testing.expect(std.mem.indexOf(u8, changed_view, "SELECTED-VIEW") != null);
            try std.testing.expect(std.mem.indexOf(u8, changed_view, "LATEST-USER-AMENDMENT") != null);
            try std.testing.expect(std.mem.indexOf(u8, changed_view, "OPAQUE-AFTER-VIEW") == null);
            try std.testing.expect(std.mem.indexOf(u8, changed_view, skill_body) == null);
            var frozen_predecessor = try contracts.decodeOwned(Adapter.Prepared, a, loaded_bytes);
            defer frozen_predecessor.deinit();
            try std.testing.expectEqualSlices(u8, loaded_bytes, try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, frozen_predecessor.value.request)));

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
            graft.plan.prior.?.schema.bytes = "agent.model.context.responses.v1";
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

        fn prepare(ns: ?*native.Namespace, ctx: native.registry.ProjectionContext, payload: []const u8) ![]u8 {
            const owner = ns orelse return Adapter.prepare(ctx, payload);
            var handlers = try native.Registry.init(ctx.allocator, &.{Adapter.declaration()});
            defer handlers.deinit();
            return owner.store.project([]u8, ctx.allocator, handlers, .{ .task = ctx.task, .tenant = ctx.tenant, .profile = ctx.profile, .application = @splat(8) }, struct {
                payload: []const u8,
                pub fn run(this: @This(), view: native.registry.ProjectionContext) ![]u8 {
                    return Adapter.prepare(view, this.payload);
                }
            }{ .payload = payload });
        }
        fn interpret(ns: ?*native.Namespace, ctx: native.registry.ProjectionContext, payload: []const u8, prepared: []const u8, raw: []const u8) !native.registry.Projection {
            const owner = ns orelse return Adapter.interpret(ctx, payload, prepared, raw);
            var handlers = try native.Registry.init(ctx.allocator, &.{Adapter.declaration()});
            defer handlers.deinit();
            return owner.store.project(native.registry.Projection, ctx.allocator, handlers, .{ .task = ctx.task, .tenant = ctx.tenant, .profile = ctx.profile, .application = @splat(8) }, struct {
                payload: []const u8,
                prepared: []const u8,
                raw: []const u8,
                pub fn run(this: @This(), view: native.registry.ProjectionContext) !native.registry.Projection {
                    return Adapter.interpret(view, this.payload, this.prepared, this.raw);
                }
            }{ .payload = payload, .prepared = prepared, .raw = raw });
        }

        pub fn scaling(comptime owned: bool) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            var path_buffer: [4096]u8 = undefined;
            const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
            const path = try std.fmt.allocPrint(a, "{s}/owned", .{path_buffer[0..path_length]});
            var namespace: ?native.Namespace = if (owned) try native.Namespace.open(std.testing.allocator, std.testing.io, path) else null;
            defer if (namespace) |*ns| ns.close() catch unreachable;
            const ns = if (namespace) |*value| value else null;
            var objects: Objects = .{};
            const catalog = try objects.add(a, try contracts.encodeOwned(P.AdaptiveCatalog, a, .{ .skills = .{ .items = &.{} } }));
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
                .request_bytes = 4 * 1024 * 1024,
                .response_bytes = 4096,
                .timeout_ms = 1000,
            };
            const policy: P.AdaptivePolicy = .{
                .schema = .{ .bytes = P.adaptive_policy_identity },
                .endpoint = .{ .bytes = "https://example.test/v1/responses" },
                .audience = .{ .bytes = "fixture" },
                .profiles = .{ .items = &.{inference} },
                .catalog = catalog,
                .core_tools = .{ true, false },
                .permitted_tools = .{ true, true },
            };
            var frozen = native.json.object();
            try native.json.put(a, &frozen, "adaptive", try native.values.toJson(P.AdaptivePolicy, a, policy));
            const profile = try native.json.canonical(a, frozen);
            var ctx: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(7), .tenant = "fixture", .profile = profile, .objects = .validating(&objects, Objects.read) };
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
                .policy = digest(profile),
                .selection = .{ .profile_id = inference.id, .profile_digest = try Admission.profileDigest(a, inference), .effective_effort = .medium, .control_revision = 0 },
                .plan = .{ .epoch = 0, .reason = .initial, .watermark = 0, .eviction_generation = 0, .prior = null, .catalog = catalog, .skills = .{ .items = &.{} } },
                .materialized = .{ true, false },
                .offered = .{ true, false },
                .results = .{ .items = &.{} },
            };
            // Frozen before changing the v5 projection owner (Protean f79da40).
            // These count returned bytes, not disk I/O or latency. The in-memory object
            // lookup deliberately makes no production performance claim.
            const points = [_]usize{ 1, 8, 16, 32, 64, 128 };
            // Historical v5 read bytes: 2555, 42749, 131122, 444178, 1615626, 6141317.
            const expected_body_bytes = [_]usize{ 1271, 3616, 6308, 11700, 22484, 44108 };
            const expected_body_hashes = [_][]const u8{
                "6ae7cd9e95eb22ae14dfac797dfb456b6146ac05045a25e1c8c188ccbbd788fd",
                "7e5ab5d46b927d4d4ed3d97188183007af69f2f0ff0f9c5f3d8adc540ed36108",
                "5a6f393ce5faa38508d0dc2e4ecb94a1955a9bcf79188a6227a5cc8c5ed9d114",
                "878cc18afbaece11a73c4a2e2d2b8cd1557b5320cf7f3179b7cf87240a7595df",
                "108da51cb912abf586ce48db30046f02098fd25570116208e3dec0d0dc8973d2",
                "7a37c855db4eb9979457a5d36201cea9edfd4d54260d6a758bf0a264f7058ff7",
            };
            try std.testing.expectEqualStrings("e3d9173da4bc09371f08de6633fecc77714cfa16e1ed9d5bf83b85be8b1110c1", &std.fmt.bytesToHex(digest(profile), .lower));
            try std.testing.expectEqualStrings("6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d", &std.fmt.bytesToHex(catalog.digest, .lower));
            std.debug.print("context baseline profile_sha256={s} catalog_sha256={s}\n", .{ std.fmt.bytesToHex(digest(profile), .lower), std.fmt.bytesToHex(catalog.digest, .lower) });
            if (ns) |owner| {
                try owner.store.begin();
                _ = try owner.store.putObject(objects.items.items[0]);
                try owner.commit("catalog");
                var handlers = try native.Registry.init(a, &.{Adapter.declaration()});
                defer handlers.deinit();
                _ = try owner.store.auditRetention(handlers, @splat(8));
            }
            var retained_objects: usize = objects.items.items.len;
            var history_bytes: usize = 0;
            var previous_history: ?P.HistoryReference = null;
            var first_root: ?@TypeOf(catalog) = null;
            for (0..128) |turn| {
                var step = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer step.deinit();
                ctx.allocator = step.allocator();
                const encoded = try contracts.encodeOwned(P.AdaptiveRequest, ctx.allocator, request);
                const prepared = try prepare(ns, ctx, encoded);
                _ = try objects.add(a, try a.dupe(u8, prepared));
                const call_id = try std.fmt.allocPrint(a, "probe-{d}", .{turn});
                const body = try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"completed\",\"error\":null,\"output\":[{{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque\"}},{{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"{s}\",\"name\":\"finish\",\"arguments\":\"{{\\\"value\\\":1}}\"}}]}}", .{call_id});
                const raw = try contracts.encodeOwned(native.responses.Raw, ctx.allocator, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = body } });
                _ = try objects.add(a, try a.dupe(u8, raw));
                const before_interpret = objects.reads;
                const ancestry_before = if (ns) |owner| owner.store.context_cache.ancestry_bytes else 0;
                const projection = try interpret(ns, ctx, encoded, prepared, raw);
                try checkDependencies(ctx.allocator, projection);
                // Interpretation derives the prepared body and retained history once.
                // The predecessor made two catalog reads and two ancestry traversals.
                if (ns) |owner| {
                    try std.testing.expectEqual(ancestry_before, owner.store.context_cache.ancestry_bytes);
                } else try std.testing.expectEqual(1 + @as(usize, 4) * turn, objects.reads - before_interpret);
                if (turn == 0) {
                    const forged = try ctx.allocator.dupe(u8, prepared);
                    forged[forged.len - 1] ^= 1;
                    try std.testing.expectError(error.InvalidCapture, interpret(ns, ctx, encoded, forged, raw));
                }
                {
                    try std.testing.expectEqual(@as(usize, 2), projection.objects.len);
                    var root = try contracts.decodeOwned(P.AdaptiveContext, ctx.allocator, projection.objects[1]);
                    defer root.deinit();
                    var chunk = try contracts.decodeOwned(P.HistoryChunk, ctx.allocator, projection.objects[0]);
                    defer chunk.deinit();
                    try std.testing.expectEqual(4 + 3 * turn, root.value.history.?.event_count);
                    try std.testing.expectEqual(@as(usize, if (turn == 0) 4 else 3), chunk.value.events.items.len);
                    try std.testing.expectEqual(@as(usize, if (turn == 0) 0 else 4 + 3 * (turn - 1)), chunk.value.first_ordinal);
                    try std.testing.expectEqual(chunk.value.first_ordinal, if (chunk.value.previous) |previous| previous.event_count else 0);
                    try std.testing.expectEqualDeep(previous_history, chunk.value.previous);
                    previous_history = root.value.history;
                }
                for (projection.objects) |object| _ = try objects.add(a, try a.dupe(u8, object));
                history_bytes += projection.objects[0].len;
                if (ns) |owner| {
                    if (turn == 1) try publicationFailures(owner, temporary.dir, path, ctx, encoded, objects.items.items[retained_objects..], projection.objects);
                    try owner.store.begin();
                    for (objects.items.items[retained_objects..]) |bytes| _ = try owner.store.putObject(bytes);
                    try owner.store.retainProjection(Adapter.declaration().capture.?.dependencies, projection.objects);
                    try owner.commit("context");
                    retained_objects = objects.items.items.len;
                }
                const result = try contracts.decodeOwned(P.AdaptiveResult, a, projection.reply);
                try std.testing.expectEqual(.complete, result.value.replay_status);
                request.plan.prior = result.value.replay;
                request.plan.watermark = result.value.replay.?.watermark;
                if (turn == 0) first_root = result.value.replay.?.object;
                request.invocation.messages.items = &.{};
                const settled = try a.alloc(P.ToolResult, 1);
                settled[0] = .{ .call_id = .{ .bytes = call_id }, .output = .{ .bytes = "Observation retained." } };
                request.results.items = settled;
                if (owned and turn == 2) {
                    const owner = ns.?;
                    const entries = owner.store.context_cache.entries.count();
                    const allocator = owner.store.allocator;
                    owner.store.allocator = std.testing.failing_allocator;
                    {
                        defer owner.store.allocator = allocator;
                        try std.testing.expectError(error.OutOfMemory, prepare(ns, ctx, try contracts.encodeOwned(P.AdaptiveRequest, ctx.allocator, request)));
                    }
                    try std.testing.expectEqual(entries, owner.store.context_cache.entries.count());
                    try std.testing.expect(!owner.store.fenced and !owner.store.projecting);
                }
                if (std.mem.indexOfScalar(usize, &points, turn + 1)) |point| {
                    objects.reads = 0;
                    objects.read_bytes = 0;
                    const next = try contracts.encodeOwned(P.AdaptiveRequest, ctx.allocator, request);
                    if (ns) |owner| {
                        if (turn == 7 or turn == 15) {
                            // Import's cold audit runs before publication. It
                            // must not mint a lease inside that transaction,
                            // but the next sealed projection must become warm.
                            owner.store.invalidateIntegrity();
                            try owner.store.begin();
                            var handlers = try native.Registry.init(a, &.{Adapter.declaration()});
                            defer handlers.deinit();
                            _ = try owner.store.auditRetention(handlers, @splat(8));
                            _ = try prepare(ns, ctx, next);
                            try std.testing.expectEqual(@as(u32, 0), owner.store.context_cache.entries.count());
                            if (turn == 15) {
                                // A rejected import can roll back, followed by
                                // a normal owner publication in the same epoch.
                                owner.store.rollback();
                                try owner.store.begin();
                            }
                            try owner.commit("cold validation handoff");
                        }
                        _ = try prepare(ns, ctx, next);
                        owner.store.context_cache.ancestry_bytes = 0;
                        owner.store.context_cache.history_bytes = 0;
                        owner.store.context_cache.hits = 0;
                        owner.store.context_cache.misses = 0;
                        owner.store.context_cache.object_reads = 0;
                        owner.store.context_cache.object_bytes = 0;
                    }
                    const measured = try prepare(ns, ctx, next);
                    const decoded = try contracts.decodeOwned(Adapter.Prepared, ctx.allocator, measured);
                    if (ns) |owner| {
                        const cache = &owner.store.context_cache;
                        try std.testing.expectEqual(@as(u64, 0), cache.ancestry_bytes);
                        try std.testing.expectEqual(@as(u64, 0), cache.misses);
                        try std.testing.expectEqual(@as(u64, 1), cache.hits);
                        try std.testing.expectEqual(history_bytes, cache.history_bytes);
                        try std.testing.expectEqual(2 + turn, cache.object_reads);
                        try std.testing.expectEqual(catalog.bytes + history_bytes, cache.object_bytes);
                        std.debug.print("owned context turns={d} ancestry_bytes={d} history_bytes={d} hits={d} misses={d}\n", .{ turn + 1, cache.ancestry_bytes, cache.history_bytes, cache.hits, cache.misses });
                    } else try std.testing.expectEqual(1 + @as(usize, 4) * (turn + 1), objects.reads);
                    try std.testing.expectEqual(expected_body_bytes[point], decoded.value.body.bytes.len);
                    try std.testing.expectEqualStrings(expected_body_hashes[point], &std.fmt.bytesToHex(digest(decoded.value.body.bytes), .lower));
                    std.debug.print("context v{d} turns={d} reads={d} bytes={d} body_bytes={d} body_sha256={s}\n", .{ P.adaptive_context_version, turn + 1, if (ns) |owner| owner.store.context_cache.object_reads else objects.reads, if (ns) |owner| owner.store.context_cache.object_bytes else objects.read_bytes, decoded.value.body.bytes.len, std.fmt.bytesToHex(digest(decoded.value.body.bytes), .lower) });
                }
                if (owned and turn == 127) {
                    const owner = ns.?;
                    const next = try contracts.encodeOwned(P.AdaptiveRequest, ctx.allocator, request);
                    const entries = owner.store.context_cache.entries.count();
                    // All incoming reference fields remain checked on hits.
                    // A failed proposed descendant cannot discard good facts.
                    for (0..10) |case| {
                        var bad = request;
                        const prior = &bad.plan.prior.?;
                        switch (case) {
                            0 => prior.object.bytes += 1,
                            1 => prior.schema.bytes = "foreign.context",
                            2 => prior.task[0] ^= 1,
                            3 => prior.tenant.bytes = "another tenant",
                            4 => prior.audience.bytes = "another audience",
                            5 => prior.policy[0] ^= 1,
                            6 => prior.selection[0] ^= 1,
                            7 => prior.epoch += 1,
                            8 => prior.eviction_generation += 1,
                            9 => prior.watermark += 1,
                            else => unreachable,
                        }
                        if (prepare(ns, ctx, try contracts.encodeOwned(P.AdaptiveRequest, ctx.allocator, bad))) |_| {
                            return error.InvalidReferenceAccepted;
                        } else |err| switch (err) {
                            error.InvalidContext, error.CorruptState, error.IncompatibleProfile => {},
                            else => return err,
                        }
                        try std.testing.expectEqual(entries, owner.store.context_cache.entries.count());
                        const before = owner.store.context_cache.ancestry_bytes;
                        _ = try prepare(ns, ctx, next);
                        try std.testing.expectEqual(before, owner.store.context_cache.ancestry_bytes);
                    }
                    try owner.store.begin();
                    try std.testing.expectError(error.Constraint, owner.store.database.run("DELETE FROM objects WHERE digest=?", &.{.{ .blob = &first_root.?.digest }}));
                    owner.store.rollback();
                    const before = owner.store.context_cache.ancestry_bytes;
                    _ = try prepare(ns, ctx, next);
                    try std.testing.expectEqual(before, owner.store.context_cache.ancestry_bytes);

                    // The same bytes do not carry semantic authority across
                    // codecs whose declaration indexes mean different tools.
                    const Other = model.Profile(union(enum) { inspect: struct { value: u64 }, finish: struct { value: u64 } }, .{
                        .{ .name = "inspect", .description = "Inspect an invariant." },
                        .{ .name = "finish", .description = "Finish with evidence." },
                    }, P.representation);
                    const prior_hits = owner.store.context_cache.hits;
                    const prior_reads = owner.store.context_cache.object_reads;
                    var view_handlers = try native.Registry.init(a, &.{Adapter.declaration()});
                    defer view_handlers.deinit();
                    const different = owner.store.project(void, ctx.allocator, view_handlers, .{ .task = ctx.task, .tenant = ctx.tenant, .profile = ctx.profile, .application = @splat(8) }, struct {
                        reference: model.AdaptiveContextReference,
                        pub fn run(this: @This(), view: native.registry.ProjectionContext) !void {
                            var reader: native.testing.adaptive_history.History(Other).Reader = .{ .ctx = view };
                            defer reader.deinit();
                            const validated = try view.objects.context(Other, view, this.reference, "fixture", .{ .skills = .{ .items = &.{} } }, &reader);
                            defer validated.deinit();
                        }
                    }{ .reference = request.plan.prior.? });
                    different catch |err| switch (err) {
                        error.InvalidContext, error.IncompatibleProfile => {},
                        else => return err,
                    };
                    try std.testing.expectEqual(prior_hits, owner.store.context_cache.hits);
                    try std.testing.expect(owner.store.context_cache.object_reads > prior_reads);

                    // Reopen starts with no process-local semantic facts.
                    try owner.close();
                    owner.* = try native.Namespace.open(std.testing.allocator, std.testing.io, path);
                    try std.testing.expectEqual(@as(u32, 0), owner.store.context_cache.entries.count());
                    var handlers = try native.Registry.init(a, &.{Adapter.declaration()});
                    defer handlers.deinit();
                    _ = try owner.store.auditRetention(handlers, @splat(8));
                    _ = try prepare(ns, ctx, next);
                    try std.testing.expect(owner.store.context_cache.ancestry_bytes > 0);
                    try std.testing.expectEqual(entries, owner.store.context_cache.entries.count());

                    // A supported corruption hook revokes every fact. Even an
                    // unindexed requested root must prove its derived edges
                    // before the validator can mint another lease.
                    owner.store.invalidateIntegrity();
                    try owner.store.begin();
                    try owner.store.database.run("DELETE FROM dependencies WHERE parent=?", &.{.{ .blob = &first_root.?.digest }});
                    try owner.commit("corrupt retention fixture");
                    _ = try owner.store.auditRetention(handlers, @splat(8));
                    // The missing edge fences the owner; the scope's final
                    // integrity check reports that storage is unavailable.
                    try std.testing.expectError(error.StorageUnavailable, prepare(ns, ctx, next));
                    try std.testing.expect(owner.store.fenced);
                    try std.testing.expectEqual(@as(u32, 0), owner.store.context_cache.entries.count());
                }
                if (turn == 127 and !owned) {
                    try chunkRejections(ctx, &objects, request);
                    const initial_bytes = try ctx.object(.{ .digest = first_root.?.digest, .bytes = first_root.?.bytes }, @intCast(first_root.?.bytes));
                    var initial = try contracts.decodeOwned(P.AdaptiveContext, ctx.allocator, initial_bytes);
                    defer initial.deinit();
                    // Complete audit retention includes the first root and its
                    // opaque prepared/captured bytes, as well as visible chunks.
                    for ([_][32]u8{ first_root.?.digest, initial.value.source_capture.digest, initial.value.source_request.digest, initial.value.history.?.object.digest }) |missing| {
                        objects.denied = missing;
                        try std.testing.expectError(error.MissingArtifact, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, ctx.allocator, request)));
                        objects.denied = null;
                    }
                }
            }
        }
        fn publicationFailures(owner: *native.Namespace, directory: std.Io.Dir, path: []const u8, ctx: native.registry.ProjectionContext, request: []const u8, unpublished: []const []const u8, projected: []const []const u8) !void {
            const Fault = enum { chunk, root, allocation, dependency, commit, seal };
            const root: native.testing.state.Reference = .{ .digest = digest(projected[1]), .bytes = projected[1].len };
            for ([_]Fault{ .chunk, .root, .allocation, .dependency, .commit, .seal }) |fault| {
                const previous = owner.store.head;
                const entries = owner.store.context_cache.entries.count();
                if (fault == .chunk or fault == .root) {
                    const rejected = digest(projected[if (fault == .chunk) 0 else 1]);
                    try owner.store.database.exec("CREATE TEMP TABLE context_rejected(digest BLOB);");
                    try owner.store.database.run("INSERT INTO context_rejected VALUES(?)", &.{.{ .blob = &rejected }});
                    try owner.store.database.exec("CREATE TEMP TRIGGER context_write_failure BEFORE INSERT ON objects WHEN NEW.digest IN(SELECT digest FROM context_rejected) BEGIN SELECT RAISE(ABORT,'context object fault'); END;");
                } else if (fault == .dependency) {
                    try owner.store.database.exec("CREATE TEMP TRIGGER context_write_failure BEFORE INSERT ON dependencies BEGIN SELECT RAISE(ABORT,'context dependency fault'); END;");
                } else if (fault == .commit) {
                    try owner.store.database.exec(
                        \\CREATE TEMP TABLE context_parent(id INTEGER PRIMARY KEY);
                        \\CREATE TEMP TABLE context_child(parent INTEGER REFERENCES context_parent(id) DEFERRABLE INITIALLY DEFERRED);
                        \\CREATE TEMP TRIGGER context_commit_failure AFTER UPDATE ON meta BEGIN INSERT INTO context_child VALUES(1); END;
                    );
                } else if (fault == .seal) try directory.createDir(std.testing.io, "owned/seal.next", .default_dir);

                const operation = struct {
                    fn run(ns: *native.Namespace, objects: []const []const u8, projection: []const []const u8, allocation: bool) !void {
                        try ns.store.begin();
                        for (objects) |bytes| _ = try ns.store.putObject(bytes);
                        const original = ns.store.allocator;
                        defer ns.store.allocator = original;
                        if (allocation) ns.store.allocator = std.testing.failing_allocator;
                        try ns.store.retainProjection(Adapter.declaration().capture.?.dependencies, projection);
                        try ns.commit("context fault fixture");
                    }
                };
                try std.testing.expectError(switch (fault) {
                    .chunk, .root, .dependency, .commit => error.Constraint,
                    .allocation => error.OutOfMemory,
                    .seal => error.UnsafeStatePath,
                }, operation.run(owner, unpublished, projected, fault == .allocation));
                owner.store.rollback();
                if (fault == .commit or fault == .seal) {
                    try std.testing.expect(owner.store.fenced);
                    try std.testing.expectEqual(@as(u32, 0), owner.store.context_cache.entries.count());
                    try std.testing.expectError(error.StorageUnavailable, prepare(owner, ctx, request));
                    if (fault == .seal) {
                        try std.testing.expectEqual(previous.generation + 1, owner.store.head.generation);
                        try directory.deleteTree(std.testing.io, "owned/seal.next");
                    } else try std.testing.expectEqualDeep(previous, owner.store.head);
                    try owner.close();
                    owner.* = try native.Namespace.open(std.testing.allocator, std.testing.io, path);
                    try std.testing.expectEqual(@as(u32, 0), owner.store.context_cache.entries.count());
                    var handlers = try native.Registry.init(ctx.allocator, &.{Adapter.declaration()});
                    defer handlers.deinit();
                    _ = try owner.store.auditRetention(handlers, @splat(8));
                } else {
                    try std.testing.expectEqualDeep(previous, owner.store.head);
                    try std.testing.expect(!owner.store.fenced);
                    try std.testing.expectEqual(entries, owner.store.context_cache.entries.count());
                    if (fault != .allocation) try owner.store.database.exec("DROP TRIGGER context_write_failure;");
                    if (fault == .chunk or fault == .root) try owner.store.database.exec("DROP TABLE context_rejected;");
                }
                if (fault == .seal) {
                    // The SQL commit is complete: reopen repairs its seal, and
                    // the full chunk/root closure survives without a cached lease.
                    const bytes = try owner.store.object(ctx.allocator, root, null);
                    try std.testing.expectEqualSlices(u8, projected[1], bytes);
                    var value = try contracts.decodeOwned(P.AdaptiveContext, ctx.allocator, bytes);
                    defer value.deinit();
                    try owner.store.checkDependencies(P.AdaptiveContext, Ref, root, value.value);
                } else {
                    for (projected) |bytes| try std.testing.expectError(error.MissingArtifact, owner.store.object(ctx.allocator, .{ .digest = digest(bytes), .bytes = bytes.len }, null));
                }
                // Rejected descendants do not poison the committed ancestor.
                _ = try prepare(owner, ctx, request);
            }
        }

        fn skillOriginRejections(ctx: native.registry.ProjectionContext, objects: *Objects, request: P.AdaptiveRequest) !void {
            const a = ctx.allocator;
            const reference = request.plan.prior.?;
            var root = try contracts.decodeOwned(P.AdaptiveContext, a, try ctx.object(.{ .digest = reference.object.digest, .bytes = reference.object.bytes }, @intCast(reference.object.bytes)));
            defer root.deinit();
            const history = root.value.history.?;
            const bytes = try ctx.object(.{ .digest = history.object.digest, .bytes = history.object.bytes }, @intCast(history.object.bytes));
            for (0..6) |case| {
                var chunk = try contracts.decodeOwned(P.HistoryChunk, a, bytes);
                defer chunk.deinit();
                const events = try a.dupe(P.ContextEvent, chunk.value.events.items);
                chunk.value.events.items = events;
                var changed = false;
                for (events) |*event| {
                    var parsed = try native.json.parseAsset(a, event.item.bytes, event.item.bytes.len);
                    defer parsed.deinit();
                    if (case < 4 and event.origin.resident_skill != null) {
                        switch (case) {
                            0 => event.origin.resident_skill = 0, // Valid catalog index, never loaded.
                            1 => event.origin.watermark = 0, // Different introduction.
                            2 => {
                                var item = try native.json.copy(a, parsed.value);
                                try native.json.put(a, &item.object.getPtr("content").?.array.items[0], "text", native.json.string("forged instruction"));
                                event.item.bytes = try native.json.canonical(a, item);
                            },
                            3 => event.origin.reasoning_tools[1] = true,
                            else => unreachable,
                        }
                        changed = true;
                        break;
                    }
                    if (case == 4 and event.origin.reasoning_skills.items.len != 0) {
                        event.origin.reasoning_skills.items = &.{0}; // No exposure to this unloaded skill.
                        changed = true;
                        break;
                    }
                    if (case == 5 and native.json.get(parsed.value, "tools") != null) {
                        var item = try native.json.copy(a, parsed.value);
                        try native.json.put(a, &item.object.getPtr("tools").?.array.items[0], "description", native.json.string("forged declaration"));
                        event.item.bytes = try native.json.canonical(a, item);
                        changed = true;
                        break;
                    }
                }
                try std.testing.expect(changed);
                root.value.history.?.object = try objects.add(a, try contracts.encodeOwned(P.HistoryChunk, a, chunk.value));
                var forged = request;
                forged.plan.prior.?.object = try objects.add(a, try contracts.encodeOwned(P.AdaptiveContext, a, root.value));
                try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, forged)));
            }
        }
        fn chunkRejections(ctx: native.registry.ProjectionContext, objects: *Objects, request: P.AdaptiveRequest) !void {
            const a = ctx.allocator;
            const reference = request.plan.prior.?;
            const root_bytes = try ctx.object(.{ .digest = reference.object.digest, .bytes = reference.object.bytes }, @intCast(reference.object.bytes));
            var root = try contracts.decodeOwned(P.AdaptiveContext, a, root_bytes);
            defer root.deinit();
            const original = root.value.history.?;
            const chunk_bytes = try ctx.object(.{ .digest = original.object.digest, .bytes = original.object.bytes }, @intCast(original.object.bytes));
            const original_root = root.value;
            for (0..13) |case| {
                var chunk = try contracts.decodeOwned(P.HistoryChunk, a, chunk_bytes);
                defer chunk.deinit();
                root.value = original_root;
                switch (case) {
                    0 => chunk.value.first_ordinal += 1,
                    1 => chunk.value.events.items = &.{},
                    2 => root.value.history.?.event_count += 1,
                    3 => chunk.value.previous.?.event_count = original.event_count,
                    4 => {
                        const events = try a.dupe(P.ContextEvent, chunk.value.events.items);
                        events[0].item.bytes = try std.fmt.allocPrint(a, " {s}", .{events[0].item.bytes});
                        chunk.value.events.items = events;
                    },
                    5 => {
                        const events = try a.dupe(P.ContextEvent, chunk.value.events.items);
                        events[0].origin.watermark = root.value.watermark;
                        chunk.value.events.items = events;
                    },
                    6, 7, 8, 9 => {
                        const events = try a.dupe(P.ContextEvent, chunk.value.events.items);
                        switch (case) {
                            6 => events[0].origin.reasoning_tools[0] = true,
                            7 => events[0].origin.resident_skill = 0,
                            8 => events[0].origin.reasoning_skills.items = &.{0},
                            9 => events[0].item.bytes = "null",
                            else => unreachable,
                        }
                        chunk.value.events.items = events;
                    },
                    10 => root.value.plan.catalog.digest[0] ^= 1,
                    11 => root.value.top_effort = .high,
                    12 => root.value.plan.reason = .model_change,
                    else => unreachable,
                }
                const changed_chunk = try contracts.encodeOwned(P.HistoryChunk, a, chunk.value);
                root.value.history.?.object = try objects.add(a, changed_chunk);
                var forged = request;
                forged.plan.prior.?.object = try objects.add(a, try contracts.encodeOwned(P.AdaptiveContext, a, root.value));
                try std.testing.expectError(error.InvalidContext, Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, forged)));
            }
        }
    };
}

test "history chunks share unchanged prefixes and span large events and call pairs" {
    const P = CurrentProfile;
    const History = native.testing.adaptive_history.History(P);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var objects: Objects = .{};
    const ctx: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(7), .tenant = "fixture", .profile = "", .objects = .validating(&objects, Objects.read) };
    const catalog: P.AdaptiveCatalog = .{ .skills = .{ .items = &.{} } };
    const plan: model.AdaptivePlan = .{ .epoch = 0, .reason = .initial, .watermark = 0, .eviction_generation = 0, .prior = null, .catalog = .{ .digest = @splat(0), .bytes = 1 }, .skills = .{ .items = &.{} } };
    const message = (try native.json.parse(a, "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"retained\"}]}", .{})).value;
    const call = (try native.json.parse(a, "{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"cross-chunk\",\"name\":\"finish\",\"arguments\":\"{\\\"value\\\":1}\"}", .{})).value;
    const output = (try native.json.parse(a, "{\"type\":\"function_call_output\",\"call_id\":\"cross-chunk\",\"output\":\"retained\"}", .{})).value;
    var items: native.json.Value = .{ .array = .init(a) };
    for (0..65) |_| try items.array.append(message);
    const large_text = try a.alloc(u8, 1024 * 1024);
    @memset(large_text, 'x');
    items.array.items[0] = try native.json.copy(a, message);
    try native.json.put(a, &items.array.items[0].object.getPtr("content").?.array.items[0], "text", native.json.string(large_text));
    // A pending call crosses the physical 32-event chunk boundary.
    items.array.items[31] = call;
    items.array.items[32] = output;
    const origins = try a.alloc(P.ContextOrigin, 66);
    @memset(origins, .{ .watermark = 0 });
    const published = try History.publish(ctx, null, false, items, origins[0..65], plan, catalog);
    try std.testing.expectEqual(@as(usize, 3), published.objects.len);
    try std.testing.expectEqual(@as(u64, 65), published.root.?.event_count);
    for (published.objects, 0..) |bytes, index| {
        _ = try objects.add(a, bytes);
        var chunk = try contracts.decodeOwned(P.HistoryChunk, a, bytes);
        defer chunk.deinit();
        try std.testing.expectEqual(index * 32, chunk.value.first_ordinal);
        try std.testing.expectEqual(@as(usize, if (index == 2) 1 else 32), chunk.value.events.items.len);
    }
    var reader: History.Reader = .{ .ctx = ctx };
    defer reader.deinit();
    var loaded = try reader.load(published.root, plan, catalog);
    try std.testing.expectEqualStrings(large_text, loaded.items.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
    try reader.validate(published.root, plan, catalog);
    const unchanged = try History.publish(ctx, loaded, false, loaded.items, loaded.origins.items, plan, catalog);
    try std.testing.expectEqual(@as(usize, 0), unchanged.objects.len);
    try std.testing.expectEqualDeep(published.root, unchanged.root);
    // A late epoch edit shares the complete first chunk, including the large
    // event. It replaces only the suffix from the first changed chunk onward.
    loaded.items.array.items[40] = (try native.json.parse(a, "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"revised\"}]}", .{})).value;
    const revised = try History.publish(ctx, loaded, false, loaded.items, loaded.origins.items, plan, catalog);
    try std.testing.expectEqual(@as(usize, 2), revised.objects.len);
    var replacement = try contracts.decodeOwned(P.HistoryChunk, a, revised.objects[0]);
    defer replacement.deinit();
    try std.testing.expectEqualDeep(loaded.checkpoints[0].reference, replacement.value.previous.?);
    try std.testing.expectEqual(@as(u64, 32), replacement.value.first_ordinal);
    for (revised.objects) |bytes| _ = try objects.add(a, bytes);
    var revised_history = try reader.load(revised.root, plan, catalog);
    try revised_history.items.array.append(message);
    try revised_history.origins.append(a, .{ .watermark = 0 });
    const appended = try History.publish(ctx, revised_history, true, revised_history.items, revised_history.origins.items, plan, catalog);
    try std.testing.expectEqual(@as(usize, 1), appended.objects.len);
    var suffix = try contracts.decodeOwned(P.HistoryChunk, a, appended.objects[0]);
    defer suffix.deinit();
    try std.testing.expectEqualDeep(revised.root, suffix.value.previous);
    try std.testing.expectEqual(@as(u64, 66), appended.root.?.event_count);
    for (appended.objects) |bytes| _ = try objects.add(a, bytes);
    try reader.validate(appended.root, plan, catalog);
    // Construction checks grammar before returning any publishable objects.
    items.array.items[0] = output;
    try std.testing.expectError(error.CallPairMismatch, History.publish(ctx, null, false, items, origins[0..65], plan, catalog));
}

test "incremental transcript validator owns call IDs across parser lifetimes" {
    const Sequence = native.adaptive_responses.Adapter(CurrentProfile).Context.Sequence;
    const a = std.testing.allocator;
    var sequence = Sequence.init(a);
    defer sequence.deinit();
    {
        var parsed = try native.json.parse(a, "{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"separate-lifetime\",\"name\":\"finish\",\"arguments\":\"{}\"}", .{});
        defer parsed.deinit();
        try sequence.push(parsed.value);
        try std.testing.expectError(error.InvalidContext, sequence.push(parsed.value));
    }
    try std.testing.expectEqual(@as(u32, 1), sequence.count());
    {
        var parsed = try native.json.parse(a, "{\"type\":\"function_call_output\",\"call_id\":\"separate-lifetime\",\"output\":\"retained\"}", .{});
        defer parsed.deinit();
        try sequence.push(parsed.value);
        try std.testing.expectError(error.CallPairMismatch, sequence.push(parsed.value));
    }
    try std.testing.expectEqual(@as(u32, 0), sequence.count());
}
