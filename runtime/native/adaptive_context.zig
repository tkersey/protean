//! Deterministic input projection. Original captures remain immutable; epochs
//! preserve ordered replay while revising only incompatible or evicted material.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const json = @import("json.zig");
const responses = @import("responses.zig");
const storage = @import("store.zig");

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn same(left: anytype, right: anytype) bool {
    return std.meta.eql(left, right);
}
fn encodedEqual(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    const lhs = try contracts.encodeOwned(T, a, left);
    defer a.free(lhs);
    const rhs = try contracts.encodeOwned(T, a, right);
    defer a.free(rhs);
    return equal(lhs, rhs);
}
fn field(item: json.Value, key: []const u8) !json.Value {
    return json.get(item, key) orelse error.InvalidContext;
}
fn kind(item: json.Value, expected: []const u8) bool {
    const value = json.get(item, "type") orelse return false;
    return value == .string and equal(value.string, expected);
}
fn list(a: std.mem.Allocator) json.Value {
    return .{ .array = .init(a) };
}
fn only(value: json.Value, keys: []const []const u8) !void {
    if (value != .object) return error.InvalidContext;
    for (value.object.keys()) |key| {
        var allowed = false;
        for (keys) |candidate| allowed = allowed or equal(key, candidate);
        if (!allowed) return error.InvalidContext;
    }
}
fn inputPart(part: json.Value) !void {
    try only(part, &.{ "type", "text", "prompt_cache_breakpoint" });
    if (!kind(part, "input_text")) return error.InvalidContext;
    _ = try json.text(try field(part, "text"));
    if (json.get(part, "prompt_cache_breakpoint")) |marker| {
        try only(marker, &.{"mode"});
        if (!equal(try json.text(try field(marker, "mode")), "explicit")) return error.InvalidContext;
    }
}
fn read(ctx: registry.ProjectionContext, reference: anytype, limit: usize) ![]u8 {
    if (reference.bytes == 0 or reference.bytes > limit) return error.Capacity;
    const bytes = try ctx.object(.{ .digest = reference.digest, .bytes = reference.bytes }, limit);
    errdefer ctx.allocator.free(bytes);
    if (bytes.len != reference.bytes or !equal(&storage.digest(bytes), &reference.digest)) return error.InvalidContext;
    return bytes;
}

pub fn Projection(comptime P: type) type {
    return struct {
        const Admission = @import("adaptive_responses.zig").Admission(P);
        const Ref = @typeInfo(@FieldType(P.AdaptiveResult, "replay")).optional.child;
        pub const Rendered = struct {
            /// Committed events, without the transient material of this call.
            history: json.Value,
            origins: std.ArrayList(P.ContextOrigin),
            reasoning_skills: u32,
            /// Exact chronological provider input, including transient suffix.
            input: json.Value,
            core_tools: json.Value,
            prior_response_id: ?[]const u8,
            prior_request: ?@FieldType(P.AdaptiveContext, "source_request"),
        };

        pub fn open(ctx: registry.ProjectionContext, reference: Ref, audience: []const u8) !contracts.Decoded(P.AdaptiveContext) {
            if (!equal(reference.schema.bytes, P.adaptive_context_identity) or !equal(&reference.policy, &storage.digest(ctx.profile)) or
                !equal(&reference.task, &ctx.task) or !equal(reference.tenant.bytes, ctx.tenant) or !equal(reference.audience.bytes, audience)) return error.InvalidContext;
            const bytes = try read(ctx, reference.object, 2 * 1024 * 1024);
            defer ctx.allocator.free(bytes);
            var decoded = try contracts.decodeOwned(P.AdaptiveContext, ctx.allocator, bytes);
            errdefer decoded.deinit();
            const value = decoded.value;
            if (!equal(value.schema.bytes, reference.schema.bytes) or !equal(&value.policy, &reference.policy) or
                !equal(&value.task, &reference.task) or !equal(value.tenant.bytes, reference.tenant.bytes) or !equal(value.audience.bytes, reference.audience.bytes) or
                !equal(&value.selection.profile_digest, &reference.selection) or value.plan.epoch != reference.epoch or value.watermark != reference.watermark or
                value.plan.eviction_generation != reference.eviction_generation or value.plan.watermark == std.math.maxInt(u64) or value.watermark != value.plan.watermark + 1) return error.InvalidContext;
            // These reads make loss of audit dependencies an error even when
            // an epoch deliberately does not replay their prompt material.
            const raw = try read(ctx, value.source_capture, 4 * 1024 * 1024);
            ctx.allocator.free(raw);
            const prepared = try read(ctx, value.source_request, 2 * 1024 * 1024);
            ctx.allocator.free(prepared);
            return decoded;
        }

        fn tool(a: std.mem.Allocator, declaration: P.ToolDeclaration) !json.Value {
            var item = json.object();
            try json.put(a, &item, "type", json.string("function"));
            try json.put(a, &item, "name", json.string(declaration.name.bytes));
            try json.put(a, &item, "description", json.string(declaration.description.bytes));
            try json.put(a, &item, "parameters", (try json.parse(a, declaration.input_schema_json.bytes, .{})).value);
            try json.put(a, &item, "strict", .{ .bool = true });
            return item;
        }

        fn message(a: std.mem.Allocator, role: []const u8, text: []const u8, marked: bool) !json.Value {
            var part = json.object();
            try json.put(a, &part, "type", json.string("input_text"));
            try json.put(a, &part, "text", json.string(text));
            if (marked) {
                var marker = json.object();
                try json.put(a, &marker, "mode", json.string("explicit"));
                try json.put(a, &part, "prompt_cache_breakpoint", marker);
            }
            var content = list(a);
            try content.array.append(part);
            var item = json.object();
            try json.put(a, &item, "role", json.string(role));
            try json.put(a, &item, "content", content);
            return item;
        }

        fn sameSkill(left: anytype, right: anytype) bool {
            return equal(left.skill_id.bytes, right.skill_id.bytes) and equal(left.version.bytes, right.version.bytes) and
                same(left.resource, right.resource) and left.residency == right.residency and left.introduced_at == right.introduced_at;
        }

        fn excluded(prior: P.AdaptiveContext, request: P.AdaptiveRequest) bool {
            for (prior.plan.skills.items) |old| {
                var retained = false;
                for (request.plan.skills.items) |current| if (sameSkill(old, current)) {
                    retained = !(old.residency == .transient and old.active and !current.active);
                };
                if (!retained) return true;
            }
            return false;
        }

        /// Check call/result pairing independently of normalization. Call IDs
        /// scope an unsettled exchange; an ID reused after settlement is not an
        /// idempotency key for a later acquired response.
        pub fn pending(a: std.mem.Allocator, items: json.Value) !std.StringHashMap(void) {
            if (items != .array or items.array.items.len > 8192) return error.Capacity;
            var calls = std.StringHashMap(void).init(a);
            errdefer calls.deinit();
            var previous_update = false;
            for (items.array.items) |item| {
                if (item != .object) return error.InvalidContext;
                if (kind(item, "function_call")) {
                    _ = try responses.replayItem(a, item);
                    const id = try json.text(try field(item, "call_id"));
                    if ((try calls.getOrPut(id)).found_existing) return error.InvalidContext;
                } else if (kind(item, "function_call_output")) {
                    try only(item, &.{ "type", "call_id", "output" });
                    const output = try field(item, "output");
                    if (output == .array) {
                        if (output.array.items.len != 1) return error.InvalidContext;
                        try inputPart(output.array.items[0]);
                    } else _ = try json.text(output);
                    if (!calls.remove(try json.text(try field(item, "call_id")))) return error.CallPairMismatch;
                } else if (kind(item, "additional_tools") or kind(item, "configuration_update") or json.get(item, "type") == null) {
                    if (calls.count() != 0) return error.MissingCallResult;
                    if (kind(item, "additional_tools")) {
                        try only(item, &.{ "type", "role", "tools" });
                        if (!equal(try json.text(try field(item, "role")), "developer")) return error.InvalidContext;
                        const tools = try field(item, "tools");
                        if (tools != .array or tools.array.items.len == 0 or tools.array.items.len > P.declaration_count) return error.InvalidContext;
                        for (tools.array.items) |declaration| {
                            try only(declaration, &.{ "type", "name", "description", "parameters", "strict" });
                            if (!kind(declaration, "function") or (try field(declaration, "parameters")) != .object or
                                (try field(declaration, "strict")) != .bool or !(try field(declaration, "strict")).bool) return error.InvalidContext;
                            _ = try json.text(try field(declaration, "name"));
                            _ = try json.text(try field(declaration, "description"));
                        }
                    } else if (kind(item, "configuration_update")) {
                        if (previous_update) return error.InvalidContext;
                        try only(item, &.{ "type", "reasoning" });
                        const reasoning = try field(item, "reasoning");
                        try only(reasoning, &.{"effort"});
                        _ = std.meta.stringToEnum(@FieldType(@FieldType(P.AdaptiveRequest, "selection"), "effective_effort"), try json.text(try field(reasoning, "effort"))) orelse return error.InvalidContext;
                    } else {
                        try only(item, &.{ "role", "content" });
                        const role = try json.text(try field(item, "role"));
                        if (!equal(role, "system") and !equal(role, "developer") and !equal(role, "user") and !equal(role, "assistant")) return error.InvalidContext;
                        const content = try field(item, "content");
                        if (content != .array or content.array.items.len != 1) return error.InvalidContext;
                        try inputPart(content.array.items[0]);
                    }
                } else {
                    _ = try responses.replayItem(a, item);
                }
                previous_update = kind(item, "configuration_update");
            }
            return calls;
        }

        fn ordinal(name: []const u8) !usize {
            for (P.allDeclarations().items, 0..) |declaration, index| if (equal(name, declaration.name.bytes)) return index;
            return error.InvalidContext;
        }

        fn fillOrigins(a: std.mem.Allocator, origins: *std.ArrayList(P.ContextOrigin), count: usize, watermark: u64) !void {
            while (origins.items.len < count) try origins.append(a, .{ .watermark = watermark });
        }

        pub fn effectiveEffort(input: json.Value, top: @FieldType(@FieldType(P.AdaptiveRequest, "selection"), "effective_effort")) !@TypeOf(top) {
            if (input != .array) return error.InvalidContext;
            var effective = top;
            for (input.array.items) |item| if (kind(item, "configuration_update")) {
                effective = std.meta.stringToEnum(@TypeOf(top), try json.text(try field(try field(item, "reasoning"), "effort"))) orelse return error.InvalidContext;
            };
            return effective;
        }

        fn stripMarker(item: *json.Value) void {
            const key: []const u8 = if (kind(item.*, "function_call_output")) "output" else "content";
            if (item.object.getPtr(key)) |parts| if (parts.* == .array) {
                for (parts.array.items) |*part| if (part.* == .object) {
                    _ = part.object.swapRemove("prompt_cache_breakpoint");
                };
            };
        }

        /// Retain ordinary history and complete exchanges. Ownership metadata
        /// identifies injected bodies; equal text in acquired evidence is not
        /// an injection. Only opaque output that could have seen an evicted
        /// skill is excluded. A profile switch excludes all old opaque output
        /// and effort updates, without relabeling either for the new profile.
        fn revise(ctx: registry.ProjectionContext, history: *json.Value, origins: *std.ArrayList(P.ContextOrigin), old: P.AdaptiveContext, request: P.AdaptiveRequest, catalog: P.AdaptiveCatalog, explicit_cache: bool) !void {
            const a = ctx.allocator;
            const changed_profile = !equal(&old.selection.profile_digest, &request.selection.profile_digest);
            var removed_skills: u32 = 0;
            for (old.plan.skills.items) |skill| {
                var retained = false;
                for (request.plan.skills.items) |next| if (sameSkill(skill, next)) {
                    retained = !(skill.residency == .transient and skill.active and !next.active);
                };
                if (!retained) for (catalog.skills.items, 0..) |entry, index| {
                    if (equal(entry.id.bytes, skill.skill_id.bytes)) removed_skills |= @as(u32, 1) << @intCast(index);
                };
            }
            var kept = list(a);
            var kept_origins: std.ArrayList(P.ContextOrigin) = .empty;
            var changed = false;
            for (history.array.items, origins.items) |value, origin| {
                var item = value;
                var retain = true;
                if (origin.resident_skill) |index| {
                    if (index >= catalog.skills.items.len) return error.InvalidContext;
                    retain = false;
                    for (request.plan.skills.items) |skill| if (skill.residency == .resident and
                        equal(skill.skill_id.bytes, catalog.skills.items[index].id.bytes) and skill.introduced_at == origin.watermark)
                    {
                        retain = true;
                    };
                }
                var removed_definition = false;
                for (origin.reasoning_tools, request.materialized) |seen, defined| removed_definition = removed_definition or (seen and !defined);
                if (kind(item, "reasoning") and (changed_profile or origin.reasoning_skills & removed_skills != 0 or removed_definition)) retain = false;
                if (kind(item, "configuration_update") and changed_profile) retain = false;
                if (kind(item, "additional_tools")) {
                    const original = try field(item, "tools");
                    var tools = list(a);
                    for (original.array.items) |definition| if (request.materialized[try ordinal(try json.text(try field(definition, "name")))]) {
                        try tools.array.append(definition);
                    };
                    if (tools.array.items.len != original.array.items.len) {
                        changed = true;
                        if (tools.array.items.len == 0) retain = false else try json.put(a, &item, "tools", tools);
                    }
                }
                if (!retain) {
                    changed = true;
                    continue;
                }
                // After a necessary edit, old suffix breakpoints describe new
                // prefixes. Keep eligible markers before the edit and select
                // one current suffix boundary below instead of rewriting all.
                if (changed or !explicit_cache) stripMarker(&item);
                try kept.array.append(item);
                try kept_origins.append(a, origin);
            }
            history.* = kept;
            origins.* = kept_origins;
        }

        pub fn render(ctx: registry.ProjectionContext, request: P.AdaptiveRequest, frozen: P.AdaptivePolicy, selected: Admission.Selected, catalog: P.AdaptiveCatalog) !Rendered {
            const a = ctx.allocator;
            var history = list(a);
            var origins: std.ArrayList(P.ContextOrigin) = .empty;
            var previous: ?contracts.Decoded(P.AdaptiveContext) = null;
            defer if (previous) |*saved| saved.deinit();
            var same_epoch = false;
            var same_profile = false;
            var new_start: usize = 0;
            if (request.plan.prior) |ref| {
                previous = try open(ctx, ref, frozen.audience.bytes);
                var parent = previous.?.value.plan.prior;
                var watermark = previous.?.value.plan.watermark;
                var depth: usize = 1;
                while (parent) |ancestor| {
                    if (depth == 64) return error.Capacity;
                    if (ancestor.watermark != watermark) return error.InvalidContext;
                    var saved = try open(ctx, ancestor, frozen.audience.bytes);
                    defer saved.deinit();
                    parent = saved.value.plan.prior;
                    if (parent) |*next| {
                        next.schema.bytes = try a.dupe(u8, next.schema.bytes);
                        next.tenant.bytes = try a.dupe(u8, next.tenant.bytes);
                        next.audience.bytes = try a.dupe(u8, next.audience.bytes);
                    }
                    watermark = saved.value.plan.watermark;
                    depth += 1;
                }
                const old = previous.?.value;
                if (request.plan.watermark != old.watermark or request.selection.control_revision < old.selection.control_revision) return error.InvalidContext;
                same_epoch = request.plan.epoch == old.plan.epoch;
                same_profile = equal(&request.selection.profile_digest, &old.selection.profile_digest);
                const removing = excluded(old, request);
                if (same_epoch) {
                    if (removing or request.plan.eviction_generation != old.plan.eviction_generation or !same_profile or
                        request.invocation.parameters.reasoning.?.effort.? != old.top_effort or
                        request.plan.reason != old.plan.reason) return error.InvalidContext;
                } else {
                    if (request.plan.epoch != try std.math.add(u64, old.plan.epoch, 1) or
                        request.plan.eviction_generation != try std.math.add(u64, old.plan.eviction_generation, @intFromBool(removing))) return error.InvalidContext;
                    if (same_profile and request.plan.reason == .eviction and request.invocation.parameters.reasoning.?.effort.? != old.top_effort) return error.InvalidContext;
                }
                history = (try json.parse(a, old.items.bytes, .{ .bytes = 2 * 1024 * 1024 })).value;
                if (old.origins.items.len != history.array.items.len) return error.InvalidContext;
                for (old.origins.items) |origin| if (origin.watermark > old.plan.watermark) return error.InvalidContext;
                try origins.appendSlice(a, old.origins.items);
                new_start = history.array.items.len;
                try settle(a, &history, request, selected.profile.explicit_cache);
                try fillOrigins(a, &origins, history.array.items.len, request.plan.watermark);
                if (!same_epoch) {
                    try revise(ctx, &history, &origins, old, request, catalog, selected.profile.explicit_cache);
                    new_start = 0;
                    while (new_start < origins.items.len and origins.items[new_start].watermark < request.plan.watermark) new_start += 1;
                }
            } else {
                if (request.plan.epoch != 0 or request.plan.watermark != 0 or request.plan.eviction_generation != 0 or request.plan.reason != .initial) return error.InvalidContext;
                try settle(a, &history, request, selected.profile.explicit_cache);
                try fillOrigins(a, &origins, history.array.items.len, request.plan.watermark);
            }
            if (same_epoch and request.selection.effective_effort != previous.?.value.selection.effective_effort) {
                if (!selected.profile.effort_update) return error.IncompatibleProfile;
                if (history.array.items.len != 0 and kind(history.array.items[history.array.items.len - 1], "configuration_update")) return error.InvalidContext;
                var update = json.object();
                var reasoning = json.object();
                try json.put(a, &reasoning, "effort", json.string(@tagName(request.selection.effective_effort)));
                try json.put(a, &update, "type", json.string("configuration_update"));
                try json.put(a, &update, "reasoning", reasoning);
                try history.array.append(update);
            }
            const effective = try effectiveEffort(history, request.invocation.parameters.reasoning.?.effort.?);
            if (effective != request.selection.effective_effort) return error.IncompatibleProfile;
            for (request.invocation.messages.items, 0..) |item, index| try history.array.append(try message(a, @tagName(item.role), item.content.bytes, selected.profile.explicit_cache and previous == null and index == 0));
            try fillOrigins(a, &origins, history.array.items.len, request.plan.watermark);
            var defined = frozen.core_tools;
            var core = list(a);
            for (frozen.core_tools, P.allDeclarations().items) |enabled, declaration| if (enabled) try core.array.append(try tool(a, declaration));
            for (history.array.items) |item| if (kind(item, "additional_tools")) {
                if (!selected.profile.additional_tools) return error.IncompatibleProfile;
                for ((try field(item, "tools")).array.items) |definition| defined[try ordinal(try json.text(try field(definition, "name")))] = true;
            };
            for (request.plan.skills.items) |loaded| {
                var index: ?u8 = null;
                for (catalog.skills.items, 0..) |entry, i| if (equal(loaded.skill_id.bytes, entry.id.bytes)) {
                    index = @intCast(i);
                };
                const skill_index = index orelse return error.InvalidContext;
                var additions = list(a);
                for (catalog.skills.items[skill_index].tools, 0..) |enabled, i| {
                    if (enabled and !defined[i]) try additions.array.append(try tool(a, P.allDeclarations().items[i]));
                    defined[i] = defined[i] or enabled;
                }
                if (additions.array.items.len != 0) {
                    if (!selected.profile.additional_tools) return error.IncompatibleProfile;
                    var addition = json.object();
                    try json.put(a, &addition, "type", json.string("additional_tools"));
                    try json.put(a, &addition, "role", json.string("developer"));
                    try json.put(a, &addition, "tools", additions);
                    try history.array.append(addition);
                    try fillOrigins(a, &origins, history.array.items.len, request.plan.watermark);
                }
                var retained = false;
                for (origins.items) |origin| if (origin.resident_skill == skill_index and origin.watermark == loaded.introduced_at) {
                    retained = true;
                };
                if (loaded.residency == .resident and !retained) {
                    const body = try read(ctx, loaded.resource, 32 * 1024);
                    try history.array.append(try message(a, "developer", body, false));
                    try origins.append(a, .{ .watermark = loaded.introduced_at, .resident_skill = skill_index });
                }
            }
            if (selected.profile.explicit_cache) try markLatest(a, &history, new_start);
            var input = list(a);
            try input.array.appendSlice(history.array.items);
            for (request.plan.skills.items) |loaded| if (loaded.residency == .transient and loaded.active) {
                const body = try read(ctx, loaded.resource, 32 * 1024);
                try input.array.append(try message(a, "developer", body, false));
            };
            var reasoning_skills: u32 = 0;
            for (origins.items) |origin| reasoning_skills |= origin.reasoning_skills;
            for (request.plan.skills.items) |loaded| if (loaded.residency == .resident or loaded.active) {
                for (catalog.skills.items, 0..) |entry, index| if (equal(entry.id.bytes, loaded.skill_id.bytes)) {
                    reasoning_skills |= @as(u32, 1) << @intCast(index);
                };
            };
            if (input.array.items.len > 8192) return error.Capacity;
            return .{ .history = history, .origins = origins, .reasoning_skills = reasoning_skills, .input = input, .core_tools = core, .prior_response_id = if (same_profile) if (previous.?.value.response_id) |id| try a.dupe(u8, id.bytes) else null else null, .prior_request = if (previous) |saved| saved.value.source_request else null };
        }

        fn markLatest(a: std.mem.Allocator, history: *json.Value, start: usize) !void {
            var index = history.array.items.len;
            while (index > start) {
                index -= 1;
                const item = &history.array.items[index];
                if (item.* != .object) return error.InvalidContext;
                const key: []const u8 = if (kind(item.*, "function_call_output")) "output" else if (json.get(item.*, "type") == null) "content" else continue;
                const parts = item.object.getPtr(key) orelse continue;
                if (parts.* != .array or parts.array.items.len == 0) continue;
                const part = &parts.array.items[parts.array.items.len - 1];
                if (!kind(part.*, "input_text")) continue;
                var marker = json.object();
                try json.put(a, &marker, "mode", json.string("explicit"));
                try json.put(a, part, "prompt_cache_breakpoint", marker);
                return;
            }
        }

        fn settle(a: std.mem.Allocator, history: *json.Value, request: P.AdaptiveRequest, explicit_cache: bool) !void {
            var calls = try pending(a, history.*);
            defer calls.deinit();
            for (request.results.items) |result| {
                if (!calls.remove(result.call_id.bytes)) return error.CallPairMismatch;
                var item = json.object();
                try json.put(a, &item, "type", json.string("function_call_output"));
                try json.put(a, &item, "call_id", json.string(result.call_id.bytes));
                const output = if (explicit_cache) blk: {
                    var part = json.object();
                    try json.put(a, &part, "type", json.string("input_text"));
                    try json.put(a, &part, "text", json.string(result.output.bytes));
                    var parts = list(a);
                    try parts.array.append(part);
                    break :blk parts;
                } else json.string(result.output.bytes);
                try json.put(a, &item, "output", output);
                try history.array.append(item);
            }
            if (calls.count() != 0) return error.MissingCallResult;
        }
    };
}
