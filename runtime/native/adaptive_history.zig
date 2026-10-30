//! Immutable context history. Chunks pair each canonical item with its origin.
//! New suffixes are split into groups of at most 32 events; an event has no byte
//! quota, and a full chunk never limits the number of subsequent chunks.
const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const storage = @import("store.zig");
const json = @import("json.zig");
pub const identity = "agent.model.context.history.chunk.v1";

pub fn History(comptime P: type) type {
    return struct {
        const Projection = @import("adaptive_context.zig").Projection(P);
        const Plan = @FieldType(P.AdaptiveRequest, "plan");
        pub const Checkpoint = struct { reference: P.HistoryReference };
        pub const Loaded = struct {
            items: json.Value,
            origins: std.ArrayList(P.ContextOrigin),
            fingerprints: [][32]u8,
            checkpoints: []Checkpoint,
        };
        pub const Published = struct { root: ?P.HistoryReference, objects: []const []const u8 };
        pub const Reader = struct {
            ctx: registry.ProjectionContext,
            chunks: std.AutoHashMapUnmanaged([32]u8, struct {
                bytes: u64,
                value: contracts.Decoded(P.HistoryChunk),
            }) = .empty,

            pub fn deinit(self: *Reader) void {
                var entries = self.chunks.valueIterator();
                while (entries.next()) |entry| entry.value.deinit();
                self.chunks.deinit(self.ctx.allocator);
            }
            pub fn checkRetention(self: *Reader, store: *storage.Store) !void {
                var entries = self.chunks.iterator();
                while (entries.next()) |entry| {
                    try store.checkDependencies(
                        P.HistoryChunk,
                        @FieldType(P.HistoryReference, "object"),
                        .{ .digest = entry.key_ptr.*, .bytes = entry.value_ptr.bytes },
                        entry.value_ptr.value.value,
                    );
                }
            }
            fn chunk(self: *Reader, reference: P.HistoryReference) !P.HistoryChunk {
                const a = self.ctx.allocator;
                if (reference.event_count == 0 or
                    reference.object.bytes == 0)
                    return error.InvalidContext;
                if (self.chunks.get(reference.object.digest)) |cached| {
                    if (cached.bytes != reference.object.bytes) return error.InvalidContext;
                    try counts(cached.value.value, reference.event_count);
                    return cached.value.value;
                }
                const bytes = try self.ctx.object(
                    .{ .digest = reference.object.digest, .bytes = reference.object.bytes },
                    std.math.cast(usize, reference.object.bytes) orelse return error.Capacity,
                );
                defer a.free(bytes);
                self.ctx.objects.historyRead(bytes.len);
                if (bytes.len != reference.object.bytes or !std.mem.eql(
                    u8,
                    &storage.digest(bytes),
                    &reference.object.digest,
                )) return error.InvalidContext;
                var decoded = try contracts.decodeOwned(P.HistoryChunk, a, bytes);
                errdefer decoded.deinit();
                try counts(decoded.value, reference.event_count);
                for (decoded.value.events.items) |event| {
                    var parsed = try json.parseAsset(a, event.item.bytes, event.item.bytes.len);
                    defer parsed.deinit();
                    const canonical = try json.canonical(a, parsed.value);
                    defer a.free(canonical);
                    if (!std.mem.eql(u8, canonical, event.item.bytes)) return error.InvalidContext;
                }
                try self.chunks.put(a, reference.object.digest, .{
                    .bytes = reference.object.bytes,
                    .value = decoded,
                });
                return decoded.value;
            }
            pub fn validate(
                self: *Reader,
                root: ?P.HistoryReference,
                plan: Plan,
                catalog: P.AdaptiveCatalog,
            ) !void {
                const a = self.ctx.allocator;
                var reverse: std.ArrayList(P.HistoryReference) = .empty;
                defer reverse.deinit(a);
                var cursor = root;
                while (cursor) |reference| {
                    const value = try self.chunk(reference);
                    try reverse.append(a, reference);
                    cursor = value.previous;
                }
                var sequence = Projection.Sequence.init(a);
                defer sequence.deinit();
                var index = reverse.items.len;
                while (index != 0) {
                    index -= 1;
                    const value = try self.chunk(reverse.items[index]);
                    for (value.events.items) |event| {
                        try origin(event.origin, plan.watermark, catalog);
                        var parsed = try json.parseAsset(a, event.item.bytes, event.item.bytes.len);
                        defer parsed.deinit();
                        try sequence.push(parsed.value);
                        try Projection.eventOrigin(a, parsed.value, event.origin, plan, catalog);
                    }
                }
            }
            // Counts strictly decrease on every backward edge, excluding cycles
            // without recursion, a visited-depth quota, or trusted stored counts.
            pub fn load(
                self: *Reader,
                root: ?P.HistoryReference,
                plan: Plan,
                catalog: P.AdaptiveCatalog,
            ) !Loaded {
                const a = self.ctx.allocator;
                var reverse: std.ArrayList(Checkpoint) = .empty;
                defer reverse.deinit(a);
                var cursor = root;
                while (cursor) |reference| {
                    const value = try self.chunk(reference);
                    try reverse.append(a, .{ .reference = reference });
                    cursor = value.previous;
                }
                var result: Loaded = .{
                    .items = .{ .array = .init(a) },
                    .origins = .empty,
                    .fingerprints = &.{},
                    .checkpoints = try a.alloc(Checkpoint, reverse.items.len),
                };
                var hashes: std.ArrayList([32]u8) = .empty;
                var sequence = Projection.Sequence.init(a);
                defer sequence.deinit();
                for (result.checkpoints, 0..) |*checkpoint, index| {
                    checkpoint.* = reverse.items[reverse.items.len - 1 - index];
                    const value = try self.chunk(checkpoint.reference);
                    for (value.events.items) |event| {
                        try origin(event.origin, plan.watermark, catalog);
                        var parsed = try json.parseAsset(a, event.item.bytes, event.item.bytes.len);
                        defer parsed.deinit();
                        try sequence.push(parsed.value);
                        try Projection.eventOrigin(a, parsed.value, event.origin, plan, catalog);
                        try result.items.array.append(try json.copy(a, parsed.value));
                        var owned = event.origin;
                        owned.reasoning_skills.items = try a.dupe(
                            u64,
                            event.origin.reasoning_skills.items,
                        );
                        try result.origins.append(a, owned);
                        try hashes.append(a, try fingerprint(a, event));
                    }
                }
                result.fingerprints = try hashes.toOwnedSlice(a);
                if (result.items.array.items.len != (if (root) |ref| ref.event_count else 0))
                    return error.InvalidContext;
                return result;
            }
        };
        fn counts(chunk: P.HistoryChunk, expected: u64) !void {
            if (!std.mem.eql(
                u8,
                chunk.schema.bytes,
                identity,
            ) or chunk.events.items.len == 0) return error.InvalidContext;
            const prior = if (chunk.previous) |reference| reference.event_count else 0;
            if (chunk.first_ordinal != prior or try std.math.add(
                u64,
                prior,
                chunk.events.items.len,
            ) != expected or prior >= expected) return error.InvalidContext;
        }
        fn origin(value: P.ContextOrigin, watermark: u64, catalog: P.AdaptiveCatalog) !void {
            if (value.watermark > watermark) return error.InvalidContext;
            if (value.resident_skill) |index| if (index >= catalog.skills.items.len)
                return error.InvalidContext;
            var last: ?u64 = null;
            for (value.reasoning_skills.items) |index| {
                if (index >= catalog.skills.items.len or
                    (last != null and
                        index <= last.?))
                    return error.InvalidContext;
                last = index;
            }
        }
        fn fingerprint(a: std.mem.Allocator, event: P.ContextEvent) ![32]u8 {
            const bytes = try contracts.encodeOwned(P.ContextEvent, a, event);
            defer a.free(bytes);
            return storage.digest(bytes);
        }
        /// The caller supplies the pure projection's edited history. Reuse only
        /// complete chunks before the first changed item/origin pair. The loaded
        /// fingerprints are independent of mutable JSON objects in the projection.
        fn sharedRoot(
            a: std.mem.Allocator,
            prior: ?Loaded,
            unchanged_prefix: bool,
            items: json.Value,
            origins: []const P.ContextOrigin,
        ) !?P.HistoryReference {
            var root: ?P.HistoryReference = null;
            if (prior) |loaded| {
                var shared: usize = if (unchanged_prefix) loaded.fingerprints.len else 0;
                if (shared > origins.len) return error.InvalidContext;
                if (!unchanged_prefix) while (shared < origins.len and
                    shared < loaded.fingerprints.len) : (shared += 1)
                {
                    const item = try json.canonical(a, items.array.items[shared]);
                    defer a.free(item);
                    const event: P.ContextEvent = .{
                        .item = .{ .bytes = item },
                        .origin = origins[shared],
                    };
                    if (!std.mem.eql(
                        u8,
                        &try fingerprint(a, event),
                        &loaded.fingerprints[shared],
                    )) break;
                };
                for (loaded.checkpoints) |checkpoint| {
                    if (checkpoint.reference.event_count > shared) break;
                    root = checkpoint.reference;
                }
            }
            return root;
        }
        pub fn publish(
            ctx: registry.ProjectionContext,
            prior: ?Loaded,
            unchanged_prefix: bool,
            items: json.Value,
            origins: []const P.ContextOrigin,
            plan: Plan,
            catalog: P.AdaptiveCatalog,
        ) !Published {
            const a = ctx.allocator;
            if (items != .array or
                items.array.items.len != origins.len)
                return error.InvalidContext;
            var sequence = Projection.Sequence.init(a);
            defer sequence.deinit();
            for (items.array.items, origins) |item, provenance| {
                try sequence.push(item);
                try origin(provenance, plan.watermark, catalog);
                try Projection.eventOrigin(a, item, provenance, plan, catalog);
            }
            var root = try sharedRoot(a, prior, unchanged_prefix, items, origins);
            const base: usize = if (root) |reference| std.math.cast(
                usize,
                reference.event_count,
            ) orelse return error.Capacity else 0;
            const events = try a.alloc(P.ContextEvent, origins.len - base);
            for (events, items.array.items[base..], origins[base..]) |*event, item, provenance| {
                event.* = .{
                    .item = .{ .bytes = try json.canonical(a, item) },
                    .origin = provenance,
                };
            }
            var offset: usize = 0;
            var objects: std.ArrayList([]const u8) = .empty;
            while (offset < events.len) {
                const end = offset + @min(@as(usize, 32), events.len - offset);
                const bytes = try contracts.encodeOwned(P.HistoryChunk, a, .{ .schema = .{
                    .bytes = identity,
                }, .previous = root, .first_ordinal = try std.math.add(
                    u64,
                    base,
                    offset,
                ), .events = .{ .items = events[offset..end] } });
                try objects.append(a, bytes);
                root = .{
                    .object = .{ .digest = storage.digest(bytes), .bytes = bytes.len },
                    .event_count = try std.math.add(u64, base, end),
                };
                offset = end;
            }
            return .{ .root = root, .objects = try objects.toOwnedSlice(a) };
        }
    };
}
