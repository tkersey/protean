//! Admission for adaptive Responses occurrences under an immutable task policy.
//! The authored program selects profiles and skills; this owner only verifies
//! that the exact request remains inside the frozen resource/feature universe.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const values = @import("values.zig");
const json = @import("json.zig");
const responses = @import("responses.zig");
const https = @import("https.zig");
const storage = @import("store.zig");

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn identifier(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}
fn sameReference(left: anytype, right: anytype) bool {
    return left.bytes == right.bytes and equal(&left.digest, &right.digest);
}
fn object(ctx: registry.ProjectionContext, ref: anytype, limit: usize) ![]u8 {
    if (ref.bytes == 0 or ref.bytes > limit) return error.Capacity;
    const bytes = try ctx.object(.{ .digest = ref.digest, .bytes = ref.bytes }, limit);
    errdefer ctx.allocator.free(bytes);
    if (bytes.len != ref.bytes or !equal(&storage.digest(bytes), &ref.digest)) return error.InvalidArtifact;
    return bytes;
}

pub fn Admission(comptime P: type) type {
    return struct {
        pub const Policy = P.AdaptivePolicy;
        pub const Profile = @FieldType(Policy, "profiles").Child;
        pub const Selected = struct { profile: Profile, transport: responses.Settings };

        pub fn policy(a: std.mem.Allocator, bytes: []const u8) !Policy {
            const parsed = try json.parse(a, bytes, .{ .bytes = 256 * 1024 });
            const value = try values.fromJson(Policy, a, json.get(parsed.value, "adaptive") orelse return error.InvalidConfiguration);
            if (!equal(value.schema.bytes, P.adaptive_policy_identity) or value.audience.bytes.len == 0 or
                value.profiles.items.len == 0 or value.model_attempts == 0 or value.model_attempts > 64 or value.control_transitions > 32 or
                value.catalog.bytes == 0 or value.catalog.bytes > 64 * 1024) return error.InvalidConfiguration;
            for (value.core_tools, value.permitted_tools) |core, permitted| if (core and !permitted) return error.InvalidConfiguration;
            for (value.profiles.items, 0..) |entry, index| {
                if (!identifier(entry.id.bytes) or entry.model.bytes.len == 0 or entry.model.bytes.len > P.representation.model_id_bytes or
                    !identifier(entry.opaque_family.bytes) or entry.efforts.items.len == 0 or
                    entry.max_output_tokens == 0 or entry.max_output_tokens > 32768 or
                    entry.request_bytes > @FieldType(P.AdaptivePrepared, "body").max_length.? or entry.response_bytes > 512 * 1024 or entry.response_bytes > P.representation.provider_response_bytes or
                    (entry.effort_update and entry.reasoning_mode != .standard)) return error.InvalidConfiguration;
                for (value.profiles.items[0..index]) |earlier| if (equal(earlier.id.bytes, entry.id.bytes)) return error.InvalidConfiguration;
                for (entry.efforts.items, 0..) |effort, n| for (entry.efforts.items[0..n]) |earlier| if (effort == earlier) return error.InvalidConfiguration;
                _ = try (https.Config{ .endpoint = value.endpoint.bytes, .token = "validation", .request_limit = entry.request_bytes, .response_limit = entry.response_bytes, .timeout_ms = entry.timeout_ms }).validate();
            }
            return value;
        }

        pub fn profileDigest(a: std.mem.Allocator, profile: Profile) ![32]u8 {
            const encoded = try contracts.encodeOwned(Profile, a, profile);
            defer a.free(encoded);
            return storage.digest(encoded);
        }

        pub fn select(a: std.mem.Allocator, frozen: Policy, request: P.AdaptiveRequest) !Selected {
            var selected: ?Profile = null;
            for (frozen.profiles.items) |entry| if (equal(entry.id.bytes, request.selection.profile_id.bytes)) {
                selected = entry;
            };
            const entry = selected orelse return error.UnknownInferenceProfile;
            const selected_digest = try profileDigest(a, entry);
            if (!equal(&request.selection.profile_digest, &selected_digest)) return error.IncompatibleProfile;
            var supported = false;
            for (entry.efforts.items) |effort| supported = supported or effort == request.selection.effective_effort;
            if (!supported) return error.UnsupportedEffort;
            const invocation = request.invocation;
            const reasoning = invocation.parameters.reasoning orelse return error.IncompatibleProfile;
            const top_effort = reasoning.effort orelse return error.IncompatibleProfile;
            supported = false;
            for (entry.efforts.items) |effort| supported = supported or effort == top_effort;
            if (!supported or (!entry.effort_update and top_effort != request.selection.effective_effort) or reasoning.summary != null or
                !equal(invocation.model.bytes, entry.model.bytes) or invocation.parameters.max_output_tokens != entry.max_output_tokens or invocation.parameters.temperature != null or
                !equal(invocation.protocol.bytes, "agent.model.protocol.openai-responses-v2") or
                invocation.response_policy.store or invocation.response_policy.stream or invocation.response_policy.background or
                invocation.selection.parallel_calls or invocation.selection.maximum_calls > 1 or invocation.selection.minimum_calls > invocation.selection.maximum_calls or
                invocation.maximum_provider_response_bytes != entry.response_bytes or !std.meta.eql(invocation.normalization_limits, P.normalizationLimits())) return error.IncompatibleProfile;
            return .{ .profile = entry, .transport = .{
                .endpoint = frozen.endpoint,
                .audience = frozen.audience,
                .model = entry.model,
                .effort = .{ .bytes = @tagName(top_effort) },
                .max_output_tokens = entry.max_output_tokens,
                .request_bytes = entry.request_bytes,
                .response_bytes = entry.response_bytes,
                .timeout_ms = entry.timeout_ms,
            } };
        }

        pub fn catalog(ctx: registry.ProjectionContext, frozen: Policy) !contracts.Decoded(P.AdaptiveCatalog) {
            const bytes = try object(ctx, frozen.catalog, 64 * 1024);
            defer ctx.allocator.free(bytes);
            var decoded = try contracts.decodeOwned(P.AdaptiveCatalog, ctx.allocator, bytes);
            errdefer decoded.deinit();
            try validateCatalog(frozen, decoded.value);
            return decoded;
        }

        /// Shared semantic admission for configuration and captured occurrences.
        /// Callers separately establish resource integrity and deployment limits.
        pub fn validateCatalog(frozen: Policy, value: P.AdaptiveCatalog) !void {
            const entries = value.skills.items;
            var admitted_bytes: u64 = 0;
            for (entries, 0..) |entry, index| {
                if (!identifier(entry.id.bytes) or !identifier(entry.version.bytes) or entry.instructions.bytes == 0 or entry.instructions.bytes > 32 * 1024) return error.InvalidSkill;
                admitted_bytes += entry.instructions.bytes;
                if (admitted_bytes > 128 * 1024) return error.Capacity;
                for (entries[0..index]) |earlier| if (equal(entry.id.bytes, earlier.id.bytes)) return error.InvalidSkill;
                for (entry.tools, frozen.permitted_tools) |enabled, permitted| if (enabled and !permitted) return error.InvalidSkill;
            }
        }

        pub fn bind(ctx: registry.ProjectionContext, frozen: Policy, request: P.AdaptiveRequest, skills: P.AdaptiveCatalog) !Selected {
            if (!equal(&request.policy, &storage.digest(ctx.profile)) or !sameReference(request.plan.catalog, frozen.catalog) or
                request.selection.control_revision > frozen.control_transitions) return error.IncompatibleProfile;
            const selected = try select(ctx.allocator, frozen, request);
            var materialized = frozen.core_tools;
            var permitted = frozen.core_tools;
            var active: usize = 0;
            var body_bytes: u64 = 0;
            for (request.plan.skills.items, 0..) |loaded, index| {
                var found: ?P.AdaptiveSkill = null;
                for (skills.skills.items) |entry| if (equal(entry.id.bytes, loaded.skill_id.bytes) and equal(entry.version.bytes, loaded.version.bytes)) {
                    found = entry;
                };
                const entry = found orelse return error.UnknownSkill;
                if (!sameReference(entry.instructions, loaded.resource) or loaded.introduced_at > request.plan.watermark) return error.InvalidSkill;
                for (request.plan.skills.items[0..index]) |earlier| if (equal(earlier.skill_id.bytes, loaded.skill_id.bytes)) return error.InvalidSkill;
                active += @intFromBool(loaded.active);
                body_bytes += entry.instructions.bytes;
                if (active > 4 or body_bytes > 128 * 1024) return error.Capacity;
                const body = try object(ctx, entry.instructions, 32 * 1024);
                defer ctx.allocator.free(body);
                if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidSkill;
                for (entry.tools, 0..) |enabled, ordinal| {
                    materialized[ordinal] = materialized[ordinal] or enabled;
                    permitted[ordinal] = permitted[ordinal] or (enabled and loaded.active);
                }
            }
            var tool_index: usize = 0;
            const declarations = P.allDeclarations().items;
            for (materialized, permitted, request.materialized, request.offered, 0..) |defined, allowed, claimed, offered, ordinal| {
                if (defined != claimed or (offered and !allowed)) return error.InvalidDeclaration;
                if (defined) {
                    if (tool_index == request.invocation.tools.items.len) return error.InvalidDeclaration;
                    const expected = try contracts.encodeOwned(P.ToolDeclaration, ctx.allocator, declarations[ordinal]);
                    defer ctx.allocator.free(expected);
                    const actual = try contracts.encodeOwned(P.ToolDeclaration, ctx.allocator, request.invocation.tools.items[tool_index]);
                    defer ctx.allocator.free(actual);
                    if (!equal(expected, actual)) return error.InvalidDeclaration;
                    tool_index += 1;
                }
            }
            if (tool_index != request.invocation.tools.items.len) return error.InvalidDeclaration;
            return selected;
        }
    };
}

/// The same native acquisition lifecycle as v5, with separately admitted
/// inference selection and explicit context epochs. No mutable profile or
/// transcript state is retained by this adapter.
pub fn Adapter(comptime P: type) type {
    return struct {
        const A = Admission(P);
        pub const Context = @import("adaptive_context.zig").Projection(P);
        pub const Prepared = P.AdaptivePrepared;
        pub fn declaration() registry.Declaration {
            return .{ .identity = P.adaptive_identity, .resource_role = "inference", .kind = .leaf, .inference = true, .inference_attempt_limit = attemptLimit, .background = true, .payload_schema = struct {
                fn schema(a: std.mem.Allocator) ![]u8 {
                    return values.schemaBytes(P.AdaptiveRequest, a);
                }
            }.schema, .resume_schema = struct {
                fn schema(a: std.mem.Allocator) ![]u8 {
                    return values.schemaBytes(P.AdaptiveResult, a);
                }
            }.schema, .capture = .{ .prepare = prepare, .acquire = acquire, .interpret = interpret } };
        }

        fn attemptLimit(a: std.mem.Allocator, profile: []const u8) !u32 {
            return (try A.policy(a, profile)).model_attempts;
        }

        pub fn prepare(ctx: registry.ProjectionContext, bytes: []const u8) ![]u8 {
            var request = try contracts.decodeOwned(P.AdaptiveRequest, ctx.allocator, bytes);
            defer request.deinit();
            const policy = try A.policy(ctx.allocator, ctx.profile);
            var catalog = try A.catalog(ctx, policy);
            defer catalog.deinit();
            const selected = try A.bind(ctx, policy, request.value, catalog.value);
            const projected = try Context.render(ctx, request.value, policy, selected, catalog.value);
            const a = ctx.allocator;
            var body = json.object();
            try json.put(a, &body, "model", json.string(selected.transport.model.bytes));
            try json.put(a, &body, "input", projected.input);
            try json.put(a, &body, "tools", projected.core_tools);
            try json.put(a, &body, "max_output_tokens", try json.number(a, selected.transport.max_output_tokens));
            var reasoning = json.object();
            try json.put(a, &reasoning, "effort", json.string(selected.transport.effort.bytes));
            try json.put(a, &reasoning, "mode", json.string(@tagName(selected.profile.reasoning_mode)));
            try json.put(a, &reasoning, "context", json.string(@tagName(selected.profile.reasoning_context)));
            try json.put(a, &body, "reasoning", reasoning);
            var allowed: json.Value = .{ .array = .init(a) };
            for (request.value.offered, P.allDeclarations().items) |offered, tool| if (offered) {
                var item = json.object();
                try json.put(a, &item, "type", json.string("function"));
                try json.put(a, &item, "name", json.string(tool.name.bytes));
                try allowed.array.append(item);
            };
            const selection = request.value.invocation.selection;
            if (selection.maximum_calls == 0 or allowed.array.items.len == 0) {
                if (selection.minimum_calls != 0) return error.InvalidDeclaration;
                try json.put(a, &body, "tool_choice", json.string("none"));
            } else {
                var choice = json.object();
                try json.put(a, &choice, "type", json.string("allowed_tools"));
                try json.put(a, &choice, "mode", json.string(if (selection.minimum_calls == 1) "required" else "auto"));
                try json.put(a, &choice, "tools", allowed);
                try json.put(a, &body, "tool_choice", choice);
            }
            inline for (.{ "parallel_tool_calls", "store", "stream", "background" }) |key| try json.put(a, &body, key, .{ .bool = false });
            try json.put(a, &body, "truncation", json.string("disabled"));
            if (selected.profile.explicit_cache) {
                var cache = json.object();
                try json.put(a, &cache, "mode", json.string("explicit"));
                try json.put(a, &cache, "ttl", json.string("30m"));
                if (selected.profile.cache_diagnostics) if (projected.prior_response_id) |id| try json.put(a, &cache, "comparison_response_id", json.string(id));
                try json.put(a, &body, "prompt_cache_options", cache);
            }
            const rendered = try json.canonicalBounded(a, body, selected.transport.request_bytes);
            return contracts.encodeOwned(Prepared, a, .{ .version = 1, .request = request.value, .body = .{ .bytes = rendered } });
        }

        pub fn acquire(ctx: registry.Context, bytes: []const u8) !registry.Acquisition {
            ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
            var prepared = contracts.decodeOwned(Prepared, ctx.allocator, bytes) catch |err| return .{ .definitely_not_sent = err };
            defer prepared.deinit();
            if (prepared.value.version != 1 or !equal(&prepared.value.request.policy, &storage.digest(ctx.profile))) return .{ .definitely_not_sent = error.IncompatibleProfile };
            const policy = A.policy(ctx.allocator, ctx.profile) catch |err| return .{ .definitely_not_sent = err };
            const selected = A.select(ctx.allocator, policy, prepared.value.request) catch |err| return .{ .definitely_not_sent = err };
            // Selection is re-admitted under the frozen catalog at acquisition,
            // rather than reading the newest mutable launch configuration.
            const body = json.parse(ctx.allocator, prepared.value.body.bytes, .{ .bytes = selected.transport.request_bytes }) catch |err| return .{ .definitely_not_sent = err };
            const reasoning = json.get(body.value, "reasoning") orelse return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            const maximum = json.get(body.value, "max_output_tokens") orelse return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            if (!jsonTextEquals(body.value, "model", selected.transport.model.bytes) or
                !jsonTextEquals(reasoning, "effort", selected.transport.effort.bytes) or
                !jsonTextEquals(reasoning, "mode", @tagName(selected.profile.reasoning_mode)) or
                !jsonTextEquals(reasoning, "context", @tagName(selected.profile.reasoning_context)) or
                !jsonTextEquals(body.value, "truncation", "disabled") or maximum != .number_string) return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            const maximum_tokens = json.numberInteger(u32, maximum.number_string) catch return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            if (maximum_tokens != selected.transport.max_output_tokens) return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            const input = json.get(body.value, "input") orelse return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            const effective = Context.effectiveEffort(input, prepared.value.request.invocation.parameters.reasoning.?.effort.?) catch return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            if (effective != prepared.value.request.selection.effective_effort) return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            inline for (.{ "parallel_tool_calls", "store", "stream", "background" }) |key| {
                const flag = json.get(body.value, key) orelse return .{ .definitely_not_sent = error.InvalidPreparedRequest };
                if (flag != .bool or flag.bool) return .{ .definitely_not_sent = error.InvalidPreparedRequest };
            }
            return responses.acquireSettings(ctx, selected.transport, prepared.value.body.bytes);
        }

        fn jsonTextEquals(value: json.Value, key: []const u8, expected: []const u8) bool {
            const child = json.get(value, key) orelse return false;
            return child == .string and equal(child.string, expected);
        }
        const Usage = @typeInfo(@FieldType(P.AdaptiveResult, "usage")).optional.child;
        const UsageObservation = struct { value: ?Usage, valid: bool };
        fn optionalCount(value: ?json.Value, valid: *bool) ?u64 {
            const item = value orelse return null;
            if (item == .null) return null;
            if (item != .number_string) {
                valid.* = false;
                return null;
            }
            return json.numberInteger(u64, item.number_string) catch {
                valid.* = false;
                return null;
            };
        }
        fn detail(value: json.Value, key: []const u8, name: []const u8, valid: *bool) ?u64 {
            const details = json.get(value, key) orelse return null;
            if (details == .null) return null;
            if (details != .object) {
                valid.* = false;
                return null;
            }
            return optionalCount(json.get(details, name), valid);
        }
        fn usage(body: json.Value) UsageObservation {
            const value = json.get(body, "usage") orelse return .{ .value = null, .valid = true };
            if (value == .null) return .{ .value = null, .valid = true };
            if (value != .object) return .{ .value = null, .valid = false };
            var valid = true;
            const observed: Usage = .{
                .input_tokens = optionalCount(json.get(value, "input_tokens"), &valid),
                .output_tokens = optionalCount(json.get(value, "output_tokens"), &valid),
                .cached_input_tokens = detail(value, "input_tokens_details", "cached_tokens", &valid),
                .cache_write_tokens = detail(value, "input_tokens_details", "cache_write_tokens", &valid),
                .reasoning_tokens = detail(value, "output_tokens_details", "reasoning_tokens", &valid),
            };
            if (observed.input_tokens) |input| {
                const cached = observed.cached_input_tokens orelse 0;
                const written = observed.cache_write_tokens orelse 0;
                if (cached > input or written > input -| cached) valid = false;
            }
            if (observed.output_tokens) |output| if ((observed.reasoning_tokens orelse 0) > output) {
                valid = false;
            };
            return .{ .value = observed, .valid = valid };
        }
        fn encode(ctx: registry.ProjectionContext, result: P.AdaptiveResult, objects: []const []const u8) !registry.Projection {
            const bytes = try contracts.encodeOwned(P.AdaptiveResult, ctx.allocator, result);
            const tokens = if (result.usage) |available| available.output_tokens else null;
            if (bytes.len > P.representation.maximum_adaptive_reply_bytes) {
                ctx.allocator.free(bytes);
                return .{ .reply = try contracts.encodeOwned(P.AdaptiveResult, ctx.allocator, .{
                    .result = .{ .unsupported_response = .normalization_limit },
                    .replay = null,
                    .replay_status = .capacity,
                    .usage = result.usage,
                }), .objects = &.{}, .output_tokens = tokens };
            }
            return .{ .reply = bytes, .objects = objects, .output_tokens = tokens };
        }
        fn unsupported(ctx: registry.ProjectionContext, reason: @FieldType(P.Result, "unsupported_response"), observed: ?Usage) !registry.Projection {
            return encode(ctx, .{ .result = .{ .unsupported_response = reason }, .replay = null, .replay_status = if (reason == .normalization_limit) .capacity else .unsupported, .usage = observed }, &.{});
        }

        pub fn interpret(ctx: registry.ProjectionContext, request_bytes: []const u8, prepared_bytes: []const u8, captured: []const u8) !registry.Projection {
            if (!equal(try prepare(ctx, request_bytes), prepared_bytes)) return error.InvalidCapture;
            var request = try contracts.decodeOwned(P.AdaptiveRequest, ctx.allocator, request_bytes);
            defer request.deinit();
            const policy = try A.policy(ctx.allocator, ctx.profile);
            var catalog = try A.catalog(ctx, policy);
            defer catalog.deinit();
            const selected = try A.bind(ctx, policy, request.value, catalog.value);
            var raw = try contracts.decodeOwned(responses.Raw, ctx.allocator, captured);
            defer raw.deinit();
            if (raw.value.status < 200 or raw.value.status >= 300) return encode(ctx, .{ .result = .{ .provider_failure = .{ .kind = .http_status, .http_status = raw.value.status } }, .replay = null, .replay_status = .unsupported, .usage = null }, &.{});
            if (!raw.value.identity_encoding) return unsupported(ctx, .unsupported_output_item, null);
            if (!std.unicode.utf8ValidateSlice(raw.value.body.bytes)) return unsupported(ctx, .invalid_utf8, null);
            const parsed = json.parse(ctx.allocator, raw.value.body.bytes, .{ .bytes = selected.transport.response_bytes }) catch |err| return unsupported(ctx, if (err == error.Capacity) .normalization_limit else .malformed_json, null);
            const body = parsed.value;
            const observed = usage(body);
            if (jsonTextEquals(body, "status", "failed") or jsonTextEquals(body, "status", "incomplete")) return encode(ctx, .{ .result = .{ .provider_failure = .{ .kind = if (jsonTextEquals(body, "status", "failed")) .response_failed else .response_incomplete, .http_status = 0 } }, .replay = null, .replay_status = .unsupported, .usage = observed.value }, &.{});
            if (!jsonTextEquals(body, "status", "completed") or (json.get(body, "error") orelse return unsupported(ctx, .unsupported_status, observed.value)) != .null) return unsupported(ctx, .unsupported_status, observed.value);
            const output = json.get(body, "output") orelse return unsupported(ctx, .unsupported_status, observed.value);
            if (output != .array) return unsupported(ctx, .unsupported_output_item, observed.value);
            if (output.array.items.len > P.representation.maximum_output_items) return unsupported(ctx, .normalization_limit, observed.value);
            const normalized = responses.Adapter(P).normalize(ctx.allocator, request.value.invocation, output) catch |err| return unsupported(ctx, if (err == error.Capacity) .normalization_limit else if (err == error.MixedRefusal) .mixed_refusal else .unsupported_output_item, observed.value);
            if (!observed.valid) return unsupported(ctx, .unsupported_output_item, observed.value);
            var projected = try Context.render(ctx, request.value, policy, selected, catalog.value);
            for (output.array.items) |item| {
                try projected.history.array.append(try responses.replayItem(ctx.allocator, item));
                const reasoning_item = jsonTextEquals(item, "type", "reasoning");
                try projected.origins.append(ctx.allocator, .{ .watermark = request.value.plan.watermark, .reasoning_skills = if (reasoning_item) projected.reasoning_skills else 0, .reasoning_tools = if (reasoning_item) request.value.materialized else @splat(false) });
            }
            var pending = Context.pending(ctx.allocator, projected.history) catch return unsupported(ctx, .unsupported_output_item, observed.value);
            pending.deinit();
            const items = json.canonicalBounded(ctx.allocator, projected.history, 2 * 1024 * 1024) catch return unsupported(ctx, .normalization_limit, observed.value);
            var response_id: ?contracts.Text(256) = null;
            if (json.get(body, "id")) |id| {
                if (id != .string or id.string.len == 0 or id.string.len > 256) return unsupported(ctx, .unsupported_output_item, observed.value);
                response_id = .{ .bytes = id.string };
            }
            const watermark = try std.math.add(u64, request.value.plan.watermark, 1);
            const artifact = try contracts.encodeOwned(P.AdaptiveContext, ctx.allocator, .{
                .schema = .{ .bytes = P.adaptive_context_identity },
                .policy = request.value.policy,
                .task = ctx.task,
                .tenant = .{ .bytes = ctx.tenant },
                .audience = policy.audience,
                .selection = request.value.selection,
                .top_effort = request.value.invocation.parameters.reasoning.?.effort.?,
                .plan = request.value.plan,
                .watermark = watermark,
                .source_capture = .{ .digest = storage.digest(captured), .bytes = captured.len },
                .source_request = .{ .digest = storage.digest(prepared_bytes), .bytes = prepared_bytes.len },
                .response_id = response_id,
                .items = .{ .bytes = items },
                .origins = .{ .items = projected.origins.items },
            });
            if (artifact.len > 2 * 1024 * 1024) return unsupported(ctx, .normalization_limit, observed.value);
            const objects = try ctx.allocator.alloc([]const u8, 1);
            objects[0] = artifact;
            return encode(ctx, .{ .result = normalized, .replay_status = .complete, .usage = observed.value, .replay = .{
                .object = .{ .digest = storage.digest(artifact), .bytes = artifact.len },
                .schema = .{ .bytes = P.adaptive_context_identity },
                .policy = request.value.policy,
                .selection = request.value.selection.profile_digest,
                .task = ctx.task,
                .tenant = .{ .bytes = ctx.tenant },
                .audience = policy.audience,
                .epoch = request.value.plan.epoch,
                .watermark = watermark,
                .eviction_generation = request.value.plan.eviction_generation,
            } }, objects);
        }
    };
}
