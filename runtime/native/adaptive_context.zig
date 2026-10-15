//! Deterministic input projection. Original captures remain immutable; epochs
//! preserve ordered replay while revising only incompatible or evicted material.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const json = @import("json.zig");
const responses = @import("responses.zig");
const storage = @import("store.zig");

/// Process-local semantic facts, owned and retired by Store. Only the pure
/// validator below inserts entries; portable records never encode this cache.
pub const Cache = struct {
    const Key = struct { validator: *const u8, binding: [32]u8, reference: [32]u8 };
    const Entry = struct { root: registry.ObjectReference, epoch: u64, bytes: []u8 };
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    hits: u64 = 0,
    misses: u64 = 0,
    ancestry_bytes: u64 = 0,
    history_bytes: u64 = 0,
    object_reads: u64 = 0,
    object_bytes: u64 = 0,

    pub fn deinit(self: *Cache, a: std.mem.Allocator) void {
        var values = self.entries.valueIterator();
        while (values.next()) |entry| a.free(entry.bytes);
        self.entries.deinit(a);
        self.* = .{};
    }
};

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
fn read(ctx: registry.ProjectionContext, reference: anytype) ![]u8 {
    if (reference.bytes == 0) return error.InvalidContext;
    const limit = std.math.cast(usize, reference.bytes) orelse return error.Capacity;
    const bytes = try ctx.object(.{ .digest = reference.digest, .bytes = reference.bytes }, limit);
    errdefer ctx.allocator.free(bytes);
    if (bytes.len != reference.bytes or !equal(&storage.digest(bytes), &reference.digest)) return error.InvalidContext;
    return bytes;
}

pub fn Projection(comptime P: type) type {
    return struct {
        const History = @import("adaptive_history.zig").History(P);
        const Admission = @import("adaptive_responses.zig").Admission(P);
        const Ref = @typeInfo(@FieldType(P.AdaptiveResult, "replay")).optional.child;
        // Address identity is unique to this exact P instantiation, including
        // declaration order and codec meaning. It is never serialized.
        var validator_identity: u8 = 0;
        const Validation = struct { allocator: std.mem.Allocator, decoded: contracts.Decoded(P.AdaptiveContext), root: registry.ObjectReference, epoch: ?u64 };
        pub const ValidatedContext = opaque {
            pub fn value(self: *const ValidatedContext) P.AdaptiveContext {
                const owned: *const Validation = @ptrCast(@alignCast(self));
                return owned.decoded.value;
            }
            pub fn deinit(self: *ValidatedContext) void {
                const owned: *Validation = @ptrCast(@alignCast(self));
                const a = owned.allocator;
                owned.decoded.deinit();
                a.destroy(owned);
            }
        };
        pub const Rendered = struct {
            history_base: ?History.Loaded,
            unchanged_prefix: bool,
            /// Committed events, without the transient material of this call.
            history: json.Value,
            origins: std.ArrayList(P.ContextOrigin),
            reasoning_skills: P.ReasoningSkills,
            /// Exact chronological provider input, including transient suffix.
            input: json.Value,
            core_tools: json.Value,
            prior_response_id: ?[]const u8,
            prior_request: ?@FieldType(P.AdaptiveContext, "source_request"),
        };

        fn binding(ctx: registry.ProjectionContext, reference: Ref, audience: []const u8) !void {
            if (!equal(reference.schema.bytes, P.adaptive_context_identity) or !equal(&reference.policy, &storage.digest(ctx.profile)) or
                !equal(&reference.task, &ctx.task) or !equal(reference.tenant.bytes, ctx.tenant) or !equal(reference.audience.bytes, audience)) return error.InvalidContext;
        }

        pub fn open(ctx: registry.ProjectionContext, reference: Ref, audience: []const u8) !contracts.Decoded(P.AdaptiveContext) {
            try binding(ctx, reference, audience);
            const bytes = try read(ctx, reference.object);
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
            const raw = try read(ctx, value.source_capture);
            defer ctx.allocator.free(raw);
            const prepared = try read(ctx, value.source_request);
            defer ctx.allocator.free(prepared);
            // A root cannot select a different catalog, epoch, or profile
            // from the exact request retained as its source evidence.
            var source = try contracts.decodeOwned(P.AdaptivePrepared, ctx.allocator, prepared);
            defer source.deinit();
            const request = source.value.request;
            const frozen = try Admission.policy(ctx.allocator, ctx.profile);
            if (source.value.version != 1 or !equal(&request.policy, &value.policy) or
                !same(request.plan.catalog, frozen.catalog) or
                !try encodedEqual(ctx.allocator, @TypeOf(value.plan), value.plan, request.plan) or
                !try encodedEqual(ctx.allocator, @TypeOf(value.selection), value.selection, request.selection) or
                request.invocation.parameters.reasoning == null or
                request.invocation.parameters.reasoning.?.effort != value.top_effort) return error.InvalidContext;
            _ = try Admission.select(ctx.allocator, frozen, request);
            return decoded;
        }

        fn validationKey(ctx: registry.ProjectionContext, reference: Ref, audience: []const u8, catalog_digest: [32]u8) !Cache.Key {
            try binding(ctx, reference, audience);
            const encoded = try contracts.encodeOwned(Ref, ctx.allocator, reference);
            defer ctx.allocator.free(encoded);
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(&ctx.task);
            hash.update(&storage.digest(ctx.tenant));
            hash.update(&storage.digest(ctx.profile));
            hash.update(&storage.digest(audience));
            hash.update(&catalog_digest);
            if (ctx.application) |application| hash.update(&application);
            var bound: [32]u8 = undefined;
            hash.final(&bound);
            return .{ .validator = &validator_identity, .binding = bound, .reference = storage.digest(encoded) };
        }

        /// The ReadView supplies an owner only after checking its snapshot,
        /// seal, cold retention audit, application and integrity epoch. All
        /// semantic admission lives here; no caller can assert a cached result.
        pub fn validate(ctx: registry.ProjectionContext, reference: Ref, audience: []const u8, catalog: P.AdaptiveCatalog, reader: *History.Reader, owner: ?*storage.Store) !*ValidatedContext {
            const a = ctx.allocator;
            const catalog_bytes = try contracts.encodeOwned(P.AdaptiveCatalog, a, catalog);
            defer a.free(catalog_bytes);
            const catalog_digest = storage.digest(catalog_bytes);
            const frozen = try Admission.policy(a, ctx.profile);
            if (catalog_bytes.len != frozen.catalog.bytes or !equal(&catalog_digest, &frozen.catalog.digest) or
                !equal(audience, frozen.audience.bytes)) return error.InvalidContext;
            const Pending = struct { key: Cache.Key, root: registry.ObjectReference, bytes: []u8 };
            var staged: std.ArrayList(Pending) = .empty;
            defer {
                for (staged.items) |entry| a.free(entry.bytes);
                staged.deinit(a);
            }
            var first: ?contracts.Decoded(P.AdaptiveContext) = null;
            errdefer if (first) |*decoded| decoded.deinit();
            var links = std.heap.ArenaAllocator.init(a);
            defer links.deinit();
            var cursor: ?Ref = reference;
            while (cursor) |current| {
                const key = try validationKey(ctx, current, audience, catalog_digest);
                if (owner) |store| {
                    if (store.context_cache.entries.get(key)) |entry| {
                        if (entry.epoch != store.integrity_epoch or entry.root.bytes != current.object.bytes or !equal(&entry.root.digest, &current.object.digest)) return error.InvalidState;
                        store.context_cache.hits +|= 1;
                        if (first == null) first = try contracts.decodeOwned(P.AdaptiveContext, a, entry.bytes);
                        break;
                    }
                    store.context_cache.misses +|= 1;
                }
                var decoded = try open(ctx, current, audience);
                var transferred = false;
                defer if (!transferred) decoded.deinit();
                const value = decoded.value;
                try reader.validate(value.history, value.plan, catalog);
                if (owner) |store| {
                    store.context_cache.ancestry_bytes +|= current.object.bytes +| value.source_capture.bytes +| value.source_request.bytes;
                    try store.checkDependencies(P.AdaptiveContext, @TypeOf(current.object), .{ .digest = current.object.digest, .bytes = current.object.bytes }, value);
                    const bytes = try contracts.encodeOwned(P.AdaptiveContext, a, value);
                    errdefer a.free(bytes);
                    try staged.append(a, .{ .key = key, .root = .{ .digest = current.object.digest, .bytes = current.object.bytes }, .bytes = bytes });
                }
                cursor = value.plan.prior;
                if (cursor) |*parent| {
                    if (parent.watermark != value.plan.watermark) return error.InvalidContext;
                    // Ancestor decoders are released as we walk, so own the
                    // incoming reference's variable fields for the next step.
                    parent.schema.bytes = try links.allocator().dupe(u8, parent.schema.bytes);
                    parent.tenant.bytes = try links.allocator().dupe(u8, parent.tenant.bytes);
                    parent.audience.bytes = try links.allocator().dupe(u8, parent.audience.bytes);
                }
                if (first == null) {
                    first = decoded;
                    transferred = true;
                }
            }
            const result = try a.create(Validation);
            errdefer a.destroy(result);
            if (owner) |store| {
                try reader.checkRetention(store);
                // Prepare every allocation before publishing any new fact.
                // Failure preserves pre-existing ancestor entries and leaves
                // no reusable partial verification of this chain.
                var owned: std.ArrayList(Pending) = .empty;
                defer owned.deinit(a);
                errdefer for (owned.items) |entry| store.allocator.free(entry.bytes);
                for (staged.items) |entry| {
                    const bytes = try store.allocator.dupe(u8, entry.bytes);
                    errdefer store.allocator.free(bytes);
                    try owned.append(a, .{ .key = entry.key, .root = entry.root, .bytes = bytes });
                }
                try store.context_cache.entries.ensureUnusedCapacity(store.allocator, std.math.cast(u32, owned.items.len) orelse return error.Capacity);
                for (owned.items) |entry| store.context_cache.entries.putAssumeCapacityNoClobber(entry.key, .{ .root = entry.root, .epoch = store.integrity_epoch, .bytes = entry.bytes });
            }
            result.* = .{ .allocator = a, .decoded = first.?, .root = .{ .digest = reference.object.digest, .bytes = reference.object.bytes }, .epoch = if (owner) |store| store.integrity_epoch else null };
            return @ptrCast(result);
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
        /// Incremental grammar validation retains only unresolved call IDs.
        /// It owns those IDs so chunk parsers can release each item immediately.
        pub const Sequence = struct {
            calls: std.StringHashMap(void),
            previous_update: bool = false,

            pub fn init(a: std.mem.Allocator) Sequence {
                return .{ .calls = std.StringHashMap(void).init(a) };
            }
            pub fn deinit(self: *Sequence) void {
                var keys = self.calls.keyIterator();
                while (keys.next()) |key| self.calls.allocator.free(key.*);
                self.calls.deinit();
            }
            pub fn count(self: Sequence) u32 {
                return self.calls.count();
            }
            pub fn remove(self: *Sequence, id: []const u8) bool {
                const entry = self.calls.fetchRemove(id) orelse return false;
                self.calls.allocator.free(entry.key);
                return true;
            }
            pub fn push(self: *Sequence, item: json.Value) !void {
                const a = self.calls.allocator;
                if (item != .object) return error.InvalidContext;
                if (kind(item, "function_call")) {
                    _ = try responses.replayItem(a, item);
                    const id = try json.text(try field(item, "call_id"));
                    if (self.calls.contains(id)) return error.InvalidContext;
                    const owned = try a.dupe(u8, id);
                    errdefer a.free(owned);
                    try self.calls.put(owned, {});
                } else if (kind(item, "function_call_output")) {
                    try only(item, &.{ "type", "call_id", "output" });
                    const output = try field(item, "output");
                    if (output == .array) {
                        if (output.array.items.len != 1) return error.InvalidContext;
                        try inputPart(output.array.items[0]);
                    } else _ = try json.text(output);
                    if (!self.remove(try json.text(try field(item, "call_id")))) return error.CallPairMismatch;
                } else if (kind(item, "additional_tools") or kind(item, "configuration_update") or json.get(item, "type") == null) {
                    if (self.calls.count() != 0) return error.MissingCallResult;
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
                        if (self.previous_update) return error.InvalidContext;
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
                self.previous_update = kind(item, "configuration_update");
            }
        };

        pub fn pending(a: std.mem.Allocator, items: json.Value) !Sequence {
            if (items != .array) return error.InvalidContext;
            var sequence = Sequence.init(a);
            errdefer sequence.deinit();
            for (items.array.items) |item| try sequence.push(item);
            return sequence;
        }

        /// Origin is an explicit owner claim. Text equality can verify that
        /// claim, but never creates it for an ordinary acquired message.
        pub fn eventOrigin(a: std.mem.Allocator, item: json.Value, origin: P.ContextOrigin, plan: @FieldType(P.AdaptiveRequest, "plan"), catalog: P.AdaptiveCatalog) !void {
            const reasoning = kind(item, "reasoning");
            if (!reasoning) {
                if (origin.reasoning_skills.items.len != 0) return error.InvalidContext;
                for (origin.reasoning_tools) |seen| if (seen) return error.InvalidContext;
            }
            if (origin.resident_skill) |index| {
                if (index >= catalog.skills.items.len or json.get(item, "type") != null or
                    !equal(try json.text(try field(item, "role")), "developer")) return error.InvalidContext;
                const skill = catalog.skills.items[@intCast(index)];
                var admitted = false;
                for (plan.skills.items) |loaded| {
                    if (loaded.residency == .resident and loaded.introduced_at == origin.watermark and
                        equal(loaded.skill_id.bytes, skill.id.bytes) and equal(loaded.version.bytes, skill.version.bytes) and
                        same(loaded.resource, skill.instructions)) admitted = true;
                }
                if (!admitted) return error.InvalidContext;
                const content = try field(item, "content");
                if (content != .array or content.array.items.len != 1) return error.InvalidContext;
                try inputPart(content.array.items[0]);
                const text = try json.text(try field(content.array.items[0], "text"));
                if (text.len != skill.instructions.bytes or !equal(&storage.digest(text), &skill.instructions.digest)) return error.InvalidContext;
            }
            for (origin.reasoning_skills.items) |index| {
                if (index >= catalog.skills.items.len) return error.InvalidContext;
                const skill = catalog.skills.items[@intCast(index)];
                var exposed = false;
                for (plan.skills.items) |loaded| {
                    if ((loaded.residency == .resident or loaded.active) and loaded.introduced_at <= origin.watermark and
                        equal(loaded.skill_id.bytes, skill.id.bytes) and equal(loaded.version.bytes, skill.version.bytes) and
                        same(loaded.resource, skill.instructions)) exposed = true;
                }
                if (!exposed) return error.InvalidContext;
            }
            if (kind(item, "additional_tools")) {
                const definitions = try field(item, "tools");
                if (definitions != .array) return error.InvalidContext;
                var seen: [P.declaration_count]bool = @splat(false);
                for (definitions.array.items) |definition| {
                    const index = try ordinal(try json.text(try field(definition, "name")));
                    if (seen[index]) return error.InvalidContext;
                    seen[index] = true;
                    var materialized = false;
                    for (plan.skills.items) |loaded| for (catalog.skills.items) |skill| {
                        if (skill.tools[index] and equal(loaded.skill_id.bytes, skill.id.bytes) and
                            equal(loaded.version.bytes, skill.version.bytes) and same(loaded.resource, skill.instructions)) materialized = true;
                    };
                    if (!materialized) return error.InvalidContext;
                    const expected = try json.canonical(a, try tool(a, P.allDeclarations().items[index]));
                    defer a.free(expected);
                    const actual = try json.canonical(a, definition);
                    defer a.free(actual);
                    if (!equal(expected, actual)) return error.InvalidContext;
                }
            }
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
            const removed_skills = try a.alloc(bool, catalog.skills.items.len);
            @memset(removed_skills, false);
            for (old.plan.skills.items) |skill| {
                var retained = false;
                for (request.plan.skills.items) |next| if (sameSkill(skill, next)) {
                    retained = !(skill.residency == .transient and skill.active and !next.active);
                };
                if (!retained) for (catalog.skills.items, 0..) |entry, index| {
                    if (equal(entry.id.bytes, skill.skill_id.bytes)) removed_skills[index] = true;
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
                var removed_reasoning_skill = false;
                for (origin.reasoning_skills.items) |index| {
                    if (index >= removed_skills.len) return error.InvalidContext;
                    removed_reasoning_skill = removed_reasoning_skill or removed_skills[@intCast(index)];
                }
                if (kind(item, "reasoning") and (changed_profile or removed_reasoning_skill or removed_definition)) retain = false;
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

        /// Remove completed research exchanges as pairs. Current policy, all
        /// user messages, skill bodies and declarations remain independently
        /// owned. Opaque reasoning is invalid after its evidence prefix changes.
        fn selectResearch(a: std.mem.Allocator, history: *json.Value, origins: *std.ArrayList(P.ContextOrigin), selected_at: u64) !void {
            var calls: std.StringHashMap(bool) = .init(a);
            defer calls.deinit();
            var kept = list(a);
            var kept_origins: std.ArrayList(P.ContextOrigin) = .empty;
            for (history.array.items, origins.items) |value, origin| {
                var item = value;
                var retain = true;
                if (kind(item, "function_call")) {
                    retain = origin.watermark >= selected_at - 1;
                    const id = try json.text(try field(item, "call_id"));
                    if (calls.contains(id)) return error.CallPairMismatch;
                    try calls.put(id, retain);
                } else if (kind(item, "function_call_output")) {
                    const pair = calls.fetchRemove(try json.text(try field(item, "call_id"))) orelse return error.CallPairMismatch;
                    retain = pair.value;
                } else if (kind(item, "reasoning")) {
                    retain = false;
                } else if (json.get(item, "role")) |role| {
                    if (equal(try json.text(role), "assistant")) retain = origin.watermark >= selected_at - 1;
                }
                if (!retain) continue;
                stripMarker(&item);
                try kept.array.append(item);
                try kept_origins.append(a, origin);
            }
            if (calls.count() != 0) return error.MissingCallResult;
            history.* = kept;
            origins.* = kept_origins;
        }

        pub fn render(ctx: registry.ProjectionContext, request: P.AdaptiveRequest, frozen: P.AdaptivePolicy, selected: Admission.Selected, catalog: P.AdaptiveCatalog) !Rendered {
            const a = ctx.allocator;
            var history = list(a);
            var origins: std.ArrayList(P.ContextOrigin) = .empty;
            var history_base: ?History.Loaded = null;
            var reader: History.Reader = .{ .ctx = ctx };
            defer reader.deinit();
            var previous: ?*ValidatedContext = null;
            defer if (previous) |saved| saved.deinit();
            var same_epoch = false;
            var same_profile = false;
            var new_start: usize = 0;
            if (request.plan.prior) |ref| {
                previous = try ctx.objects.context(P, ctx, ref, frozen.audience.bytes, catalog, &reader);
                const old = previous.?.value();
                if (request.plan.watermark != old.watermark or request.selection.control_revision < old.selection.control_revision) return error.InvalidContext;
                same_epoch = request.plan.epoch == old.plan.epoch;
                same_profile = equal(&request.selection.profile_digest, &old.selection.profile_digest);
                const removing = excluded(old, request);
                const changed_view = !try encodedEqual(a, @TypeOf(request.plan.research), old.plan.research, request.plan.research);
                if (changed_view) {
                    const selection = request.plan.research orelse return error.InvalidContext;
                    if (same_epoch or request.plan.reason != .view_change or selection.selected_at != request.plan.watermark or selection.selected_at == 0 or selection.view.kind != .view or selection.view.id.bytes.len != 64) return error.InvalidContext;
                    var identity: [32]u8 = undefined;
                    _ = std.fmt.hexToBytes(&identity, selection.view.id.bytes) catch return error.InvalidContext;
                } else if (!same_epoch and request.plan.reason == .view_change) return error.InvalidContext;
                if (same_epoch) {
                    if (removing or request.plan.eviction_generation != old.plan.eviction_generation or !same_profile or
                        request.invocation.parameters.reasoning.?.effort.? != old.top_effort or
                        request.plan.reason != old.plan.reason) return error.InvalidContext;
                } else {
                    if (request.plan.epoch != try std.math.add(u64, old.plan.epoch, 1) or
                        request.plan.eviction_generation != try std.math.add(u64, old.plan.eviction_generation, @intFromBool(removing))) return error.InvalidContext;
                    if (same_profile and request.plan.reason == .eviction and request.invocation.parameters.reasoning.?.effort.? != old.top_effort) return error.InvalidContext;
                }
                history_base = try reader.load(old.history, old.plan, catalog);
                history = history_base.?.items;
                origins = history_base.?.origins;
                new_start = history.array.items.len;
                try settle(a, &history, request, selected.profile.explicit_cache);
                try fillOrigins(a, &origins, history.array.items.len, request.plan.watermark);
                if (!same_epoch) {
                    if (changed_view) try selectResearch(a, &history, &origins, request.plan.research.?.selected_at);
                    try revise(ctx, &history, &origins, old, request, catalog, selected.profile.explicit_cache);
                    new_start = 0;
                    while (new_start < origins.items.len and origins.items[new_start].watermark < request.plan.watermark) new_start += 1;
                }
            } else {
                if (request.plan.epoch != 0 or request.plan.watermark != 0 or request.plan.eviction_generation != 0 or request.plan.reason != .initial or request.plan.research != null) return error.InvalidContext;
                try settle(a, &history, request, selected.profile.explicit_cache);
                try fillOrigins(a, &origins, history.array.items.len, request.plan.watermark);
            }
            if (same_epoch and request.selection.effective_effort != previous.?.value().selection.effective_effort) {
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
                var index: ?u64 = null;
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
                    const body = try read(ctx, loaded.resource);
                    try history.array.append(try message(a, "developer", body, false));
                    try origins.append(a, .{ .watermark = loaded.introduced_at, .resident_skill = skill_index });
                }
            }
            if (selected.profile.explicit_cache) try markLatest(a, &history, new_start);
            var input = list(a);
            try input.array.appendSlice(history.array.items);
            for (request.plan.skills.items) |loaded| if (loaded.residency == .transient and loaded.active) {
                const body = try read(ctx, loaded.resource);
                try input.array.append(try message(a, "developer", body, false));
            };
            const exposed = try a.alloc(bool, catalog.skills.items.len);
            @memset(exposed, false);
            for (origins.items) |origin| for (origin.reasoning_skills.items) |index| {
                if (index >= exposed.len) return error.InvalidContext;
                exposed[@intCast(index)] = true;
            };
            for (request.plan.skills.items) |loaded| if (loaded.residency == .resident or loaded.active) {
                for (catalog.skills.items, 0..) |entry, index| if (equal(entry.id.bytes, loaded.skill_id.bytes)) {
                    exposed[index] = true;
                };
            };
            var observed_skills: std.ArrayList(u64) = .empty;
            for (exposed, 0..) |seen, index| if (seen) try observed_skills.append(a, @intCast(index));
            const reasoning_skills: P.ReasoningSkills = .{ .items = observed_skills.items };
            return .{ .history_base = history_base, .unchanged_prefix = same_epoch, .history = history, .origins = origins, .reasoning_skills = reasoning_skills, .input = input, .core_tools = core, .prior_response_id = if (same_profile) if (previous.?.value().response_id) |id| try a.dupe(u8, id.bytes) else null else null, .prior_request = if (previous) |saved| saved.value().source_request else null };
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
