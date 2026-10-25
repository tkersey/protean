const std = @import("std");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const c = @import("protean_contracts");
const w = c.workspace;
const views = kosmos.RuntimeViews;
const state = @import("state.zig");
const projection = @import("workspace_projection.zig");

const OuterHistory = struct {
    const Entry = struct { seq: u64, capsule: state.Reference, revision: u64 };
    entries: std.AutoHashMapUnmanaged(state.Digest, std.ArrayList(Entry)) = .empty,

    fn deinit(self: *OuterHistory, a: std.mem.Allocator) void {
        var histories = self.entries.valueIterator();
        while (histories.next()) |history| history.deinit(a);
        self.entries.deinit(a);
    }

    fn put(
        self: *OuterHistory,
        a: std.mem.Allocator,
        id: state.Digest,
        seq: u64,
        capsule: state.Reference,
    ) !void {
        const entry = try self.entries.getOrPut(a, id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const history = entry.value_ptr;
        const last = history.getLastOrNull();
        if (last == null or !std.meta.eql(last.?.capsule, capsule))
            try history.append(a, .{
                .seq = seq,
                .capsule = capsule,
                .revision = if (last) |prior| try std.math.add(u64, prior.revision, 1) else 0,
            });
    }

    fn at(
        self: *const OuterHistory,
        id: state.Digest,
        watermark: u64,
    ) @import("workspace_state.zig").OuterCursor {
        const history = self.entries.get(id) orelse return .{};
        var low: usize = 0;
        var high = history.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (history.items[middle].seq <= watermark) low = middle + 1 else high = middle;
        }
        if (low == 0) return .{};
        const previous = history.items[low - 1];
        return .{ .revision = previous.revision, .last = previous.capsule.digest };
    }

    fn withCurrent(
        self: *const OuterHistory,
        id: state.Digest,
        watermark: u64,
        current: ?state.Reference,
    ) !@import("workspace_state.zig").OuterCursor {
        var cursor = self.at(id, watermark);
        if (current) |capsule| {
            if (cursor.last) |previous| if (!std.meta.eql(previous, capsule.digest)) {
                cursor.revision = try std.math.add(u64, cursor.revision, 1);
            };
            cursor.last = capsule.digest;
        }
        return cursor;
    }
};

pub const PublicationPrefix = struct {
    const Set = std.AutoHashMapUnmanaged(state.Digest, void);
    const Active = std.AutoArrayHashMapUnmanaged(state.Digest, void);
    const Position = struct { publication: state.WorkPublication, seq: u64 };
    const Source = struct { lossless: Active = .empty, outer: Set = .empty };

    latest: std.AutoHashMap(state.Digest, Position),
    successors: Set = .empty,
    outer_history: OuterHistory = .{},
    sources: std.AutoHashMapUnmanaged(state.Digest, Source) = .empty,

    pub fn init(a: std.mem.Allocator) PublicationPrefix {
        return .{ .latest = .init(a) };
    }

    pub fn deinit(self: *PublicationPrefix) void {
        const a = self.latest.allocator;
        var entries = self.sources.valueIterator();
        while (entries.next()) |entry| {
            entry.lossless.deinit(a);
            entry.outer.deinit(a);
        }
        self.sources.deinit(a);
        self.outer_history.deinit(a);
        self.successors.deinit(a);
        self.latest.deinit();
    }

    fn remove(self: *PublicationPrefix, source: state.Digest, id: state.Digest) void {
        const group = self.sources.getPtr(source) orelse return;
        _ = group.lossless.swapRemove(id);
        _ = group.outer.remove(id);
    }

    pub fn put(self: *PublicationPrefix, item: state.WorkPublication, seq: u64) !void {
        const a = self.latest.allocator;
        if (self.latest.get(item.work)) |before| if (before.publication.observer) |observer|
            self.remove(observer.source_work, item.work);
        if (item.observer) |observer| {
            if (observer.selection.previous) |previous| {
                const id = try projection.identity(previous, .work);
                try self.successors.put(a, id, {});
                if (self.latest.get(id)) |prior| if (prior.publication.observer) |predecessor|
                    self.remove(predecessor.source_work, id);
            }
            if (!observer.stopped and !self.successors.contains(item.work)) {
                const entry = try self.sources.getOrPut(a, observer.source_work);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (observer.selection.policy.delivery == .lossless)
                    try entry.value_ptr.lossless.put(a, item.work, {});
                if (observer.selection.source.level == .outer_execution)
                    try entry.value_ptr.outer.put(a, item.work, {});
            }
        }
        if (item.outer_operation orelse item.runtime_capsule) |capsule| {
            try self.outer_history.put(a, item.work, seq, capsule);
        }
        try self.latest.put(item.work, .{ .publication = item, .seq = seq });
    }

    pub fn outerCursorAt(self: *const PublicationPrefix, id: state.Digest, watermark: u64) @import("workspace_state.zig").OuterCursor {
        return self.outer_history.at(id, watermark);
    }

    pub fn outerCursor(self: *const PublicationPrefix, id: state.Digest, watermark: u64, current: ?state.Reference) !@import("workspace_state.zig").OuterCursor {
        return self.outer_history.withCurrent(id, watermark, current);
    }

    pub fn validateOuterCursor(self: *const PublicationPrefix, item: state.WorkPublication) !void {
        const expected = self.outerCursor(item.work, std.math.maxInt(u64), item.outer_operation orelse item.runtime_capsule) catch return error.InvalidArchive;
        if (!std.meta.eql(expected, item.outer_cursor)) return error.InvalidArchive;
    }

    pub fn outerRevision(self: *const PublicationPrefix, id: state.Digest, watermark: u64, current: ?state.Reference) !u64 {
        return (try self.outerCursor(id, watermark, current)).revision;
    }

    pub fn blocked(
        self: *PublicationPrefix,
        id: state.Digest,
        execution_revision: u64,
        watermark: u64,
        capsule: ?state.Reference,
    ) !bool {
        const active = self.lossless(id) orelse return false;
        var outer: ?u64 = null;
        for (active.keys()) |observer_id| {
            const observer = self.latest.get(observer_id).?.publication.observer.?;
            const revision = if (observer.selection.source.level == .guest_cut)
                execution_revision
            else value: {
                if (outer == null) outer = try self.outerRevision(id, watermark, capsule);
                break :value outer.?;
            };
            if (observer.consumed_revision == null or observer.consumed_revision.? != revision)
                return true;
        }
        return false;
    }

    pub fn hasOuter(self: *const PublicationPrefix, id: state.Digest) bool {
        const group = self.sources.get(id) orelse return false;
        return group.outer.count() != 0;
    }

    pub fn lossless(self: *PublicationPrefix, id: state.Digest) ?*Active {
        const group = self.sources.getPtr(id) orelse return null;
        return &group.lossless;
    }
};

pub const PublicationHistory = struct {
    const Level = @FieldType(w.GuestViewSelection, "level");
    const Key = struct { source: state.Digest, level: Level };
    const Requirement = union(enum) { unobserved, blocked, consumed: u64 };
    const Entry = struct { seq: u64, requirement: Requirement };

    allocator: std.mem.Allocator,
    requirements: std.AutoHashMapUnmanaged(Key, std.ArrayList(Entry)) = .empty,
    outer: OuterHistory = .{},

    pub fn init(a: std.mem.Allocator) PublicationHistory {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *PublicationHistory) void {
        var entries = self.requirements.valueIterator();
        while (entries.next()) |entry| entry.deinit(self.allocator);
        self.requirements.deinit(self.allocator);
        self.outer.deinit(self.allocator);
    }

    fn record(self: *PublicationHistory, key: Key, seq: u64, value: Requirement) !void {
        const entry = try self.requirements.getOrPut(self.allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const history = entry.value_ptr;
        if (history.items.len != 0) {
            const last = &history.items[history.items.len - 1];
            if (last.seq == seq) {
                last.requirement = value;
                return;
            }
            if (std.meta.eql(last.requirement, value)) return;
        }
        try history.append(self.allocator, .{ .seq = seq, .requirement = value });
    }

    fn requirementAt(self: *const PublicationHistory, key: Key, watermark: u64) Requirement {
        const history = self.requirements.get(key) orelse return .unobserved;
        var low: usize = 0;
        var high = history.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (history.items[middle].seq <= watermark) low = middle + 1 else high = middle;
        }
        return if (low == 0) .unobserved else history.items[low - 1].requirement;
    }

    pub fn outerCursorAt(
        self: *const PublicationHistory,
        id: state.Digest,
        watermark: u64,
    ) @import("workspace_state.zig").OuterCursor {
        return self.outer.at(id, watermark);
    }

    pub fn blocked(
        self: *const PublicationHistory,
        id: state.Digest,
        execution_revision: u64,
        source_watermark: u64,
        read_watermark: u64,
        capsule: ?state.Reference,
    ) !bool {
        for ([_]Level{ .guest_cut, .outer_execution }) |level| {
            const requirement = self.requirementAt(
                .{ .source = id, .level = level },
                read_watermark,
            );
            switch (requirement) {
                .unobserved => {},
                .blocked => return true,
                .consumed => |consumed| {
                    const revision = if (level == .guest_cut)
                        execution_revision
                    else
                        (try self.outer.withCurrent(id, source_watermark, capsule)).revision;
                    if (consumed != revision) return true;
                },
            }
        }
        return false;
    }

    pub const Builder = struct {
        const Member = struct { key: Key, consumed: ?u64 };
        const Counts = std.AutoArrayHashMapUnmanaged(?u64, usize);

        allocator: std.mem.Allocator,
        history: *PublicationHistory,
        members: std.AutoHashMapUnmanaged(state.Digest, Member) = .empty,
        successors: std.AutoHashMapUnmanaged(state.Digest, void) = .empty,
        groups: std.AutoHashMapUnmanaged(Key, Counts) = .empty,
        sequence: u64 = 0,

        pub fn init(a: std.mem.Allocator, history: *PublicationHistory) Builder {
            return .{ .allocator = a, .history = history };
        }

        pub fn deinit(self: *Builder) void {
            var groups = self.groups.valueIterator();
            while (groups.next()) |group| group.deinit(self.allocator);
            self.groups.deinit(self.allocator);
            self.members.deinit(self.allocator);
            self.successors.deinit(self.allocator);
        }

        pub fn put(self: *Builder, item: state.WorkPublication, seq: u64) !void {
            if (seq < self.sequence) return error.InvalidArchive;
            self.sequence = seq;
            try self.remove(item.work, seq);
            if (item.observer) |observer| {
                if (observer.selection.previous) |previous| {
                    const id = try projection.identity(previous, .work);
                    try self.successors.put(self.allocator, id, {});
                    try self.remove(id, seq);
                }
                if (!observer.stopped and !self.successors.contains(item.work) and
                    observer.selection.policy.delivery == .lossless)
                {
                    try self.add(item.work, .{
                        .key = .{
                            .source = observer.source_work,
                            .level = observer.selection.source.level,
                        },
                        .consumed = observer.consumed_revision,
                    }, seq);
                }
            }
            if (item.outer_operation orelse item.runtime_capsule) |capsule|
                try self.history.outer.put(self.history.allocator, item.work, seq, capsule);
        }

        fn add(self: *Builder, id: state.Digest, member: Member, seq: u64) !void {
            const entry = try self.groups.getOrPut(self.allocator, member.key);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            const group = entry.value_ptr;
            const count = try group.getOrPut(self.allocator, member.consumed);
            if (!count.found_existing) count.value_ptr.* = 0;
            count.value_ptr.* = try std.math.add(usize, count.value_ptr.*, 1);
            try self.members.put(self.allocator, id, member);
            try self.history.record(member.key, seq, summarize(group));
        }

        fn remove(self: *Builder, id: state.Digest, seq: u64) !void {
            const member = self.members.fetchRemove(id) orelse return;
            const group = self.groups.getPtr(member.value.key).?;
            const count = group.getPtr(member.value.consumed).?;
            std.debug.assert(count.* != 0);
            count.* -= 1;
            if (count.* == 0) {
                const removed = group.swapRemove(member.value.consumed);
                std.debug.assert(removed);
            }
            try self.history.record(member.value.key, seq, summarize(group));
        }

        fn summarize(group: *const Counts) Requirement {
            if (group.count() == 0) return .unobserved;
            if (group.count() != 1) return .blocked;
            return if (group.keys()[0]) |revision| .{ .consumed = revision } else .blocked;
        }
    };
};

pub fn validatePolicy(policy: w.ObserverPolicy) !void {
    if (policy.cadence == 0 or
        (policy.delivery == .lossless and policy.cadence != 1))
        return error.InvalidObserverPolicy;
}

pub const Disclosed = struct {
    value: views.Disclosure,
    values: ?[]bool = null,
    fields: []views.FieldSelection,
    blobs: []views.BlobRange,

    pub fn deinit(self: Disclosed, a: std.mem.Allocator) void {
        if (self.values) |mask| a.free(mask);
        a.free(self.fields);
        a.free(self.blobs);
    }
};

pub fn disclosure(
    a: std.mem.Allocator,
    count: usize,
    nodes: ?[]const bool,
    selected: w.Disclosure,
) !Disclosed {
    if (selected.snapshot and (nodes != null or selected.values != .nodes or
        selected.values.nodes != .all or selected.blobs.items.len != 0))
        return error.InvalidDisclosure;
    var result: Disclosed = .{
        .value = .{ .nodes = nodes, .snapshot = selected.snapshot },
        .fields = try a.alloc(views.FieldSelection, if (selected.values == .fields)
            selected.values.fields.items.len
        else
            0),
        .blobs = undefined,
    };
    errdefer a.free(result.fields);
    result.blobs = try a.alloc(views.BlobRange, selected.blobs.items.len);
    errdefer a.free(result.blobs);
    for (result.blobs, selected.blobs.items) |*target, item| target.* = .{
        .blob = item.blob,
        .offset = item.offset,
        .length = item.length,
    };
    result.value.blobs = result.blobs;
    switch (selected.values) {
        .none => {},
        .nodes => |scope| {
            const mask = try a.alloc(bool, count);
            errdefer a.free(mask);
            @memset(mask, scope == .all);
            if (scope == .selected) for (scope.selected.items) |node| {
                if (node >= count) return error.InvalidDisclosure;
                mask[@intCast(node)] = true;
            };
            result.values = mask;
            result.value.values = .{ .nodes = mask };
        },
        .fields => |fields| {
            for (result.fields, fields.items) |*target, item| target.* = .{
                .node = item.node,
                .field = item.field.bytes,
            };
            result.value.values = .{ .fields = result.fields };
        },
    }
    return result;
}

pub fn fieldSchema(a: std.mem.Allocator, encoded: []const u8, field: usize) ![]u8 {
    var schema = try data.schema.decode(a, encoded);
    defer schema.deinit();
    const root = schema.descriptor.types[@intCast(schema.descriptor.root)];
    if (root != .product or root.product.len != 2) return error.InvalidObserverInterface;
    return data.schema.encodeOwned(a, schema.descriptor.types, root.product[field]);
}

pub fn input(
    a: std.mem.Allocator,
    input_schema: []const u8,
    output_schema: []const u8,
    view_schema: []const u8,
    view: []const u8,
    envelope: []const u8,
    accumulator_schema: []const u8,
    accumulator: []const u8,
) ![]u8 {
    const expected_view = try fieldSchema(a, input_schema, 0);
    defer a.free(expected_view);
    const expected_envelope = try fieldSchema(a, expected_view, 0);
    defer a.free(expected_envelope);
    const expected_cut = try fieldSchema(a, expected_view, 1);
    defer a.free(expected_cut);
    const envelope_schema = try @import("values.zig").schemaBytes(
        @import("workspace_state.zig").ObserverEnvelope,
        a,
    );
    defer a.free(envelope_schema);
    const expected_accumulator = try fieldSchema(a, input_schema, 1);
    defer a.free(expected_accumulator);
    const next_accumulator = try fieldSchema(a, output_schema, 0);
    defer a.free(next_accumulator);
    if (!std.mem.eql(u8, envelope_schema, expected_envelope) or
        !std.mem.eql(u8, view_schema, expected_cut) or
        !std.mem.eql(u8, accumulator_schema, expected_accumulator) or
        !std.mem.eql(u8, expected_accumulator, next_accumulator))
        return error.InvalidObserverInterface;
    const bytes = try std.mem.concat(a, u8, &.{ envelope, view, accumulator });
    errdefer a.free(bytes);
    var schema = try data.schema.decode(a, input_schema);
    defer schema.deinit();
    try data.schema.validateValue(a, schema.descriptor, bytes);
    return bytes;
}

pub fn copyReference(a: std.mem.Allocator, ref: w.Ref) !w.Ref {
    return .{ .kind = ref.kind, .id = .{ .bytes = try a.dupe(u8, ref.id.bytes) } };
}

pub fn copyScope(a: std.mem.Allocator, scope: w.NodeScope) !w.NodeScope {
    return switch (scope) {
        .all => scope,
        .selected => |selected| .{ .selected = .{ .items = try a.dupe(u64, selected.items) } },
    };
}

pub fn copyDisclosure(a: std.mem.Allocator, selected: w.Disclosure) !w.Disclosure {
    var result = selected;
    result.blobs.items = try a.dupe(
        std.meta.Elem(@TypeOf(selected.blobs.items)),
        selected.blobs.items,
    );
    errdefer a.free(result.blobs.items);
    switch (selected.values) {
        .none => {},
        .nodes => |nodes| result.values = .{ .nodes = try copyScope(a, nodes) },
        .fields => |fields| {
            const copied = try a.dupe(std.meta.Elem(@TypeOf(fields.items)), fields.items);
            var initialized: usize = 0;
            errdefer {
                for (copied[0..initialized]) |field| a.free(field.field.bytes);
                a.free(copied);
            }
            for (copied) |*field| {
                field.field.bytes = try a.dupe(u8, field.field.bytes);
                initialized += 1;
            }
            result.values = .{ .fields = .{ .items = copied } };
        },
    }
    return result;
}

pub fn copyObserver(
    a: std.mem.Allocator,
    observer: @import("workspace_state.zig").Observer,
) !@import("workspace_state.zig").Observer {
    var result = observer;
    result.selection.program = try copyReference(a, observer.selection.program);
    errdefer a.free(result.selection.program.id.bytes);
    result.selection.accumulator = try copyReference(a, observer.selection.accumulator);
    errdefer a.free(result.selection.accumulator.id.bytes);
    if (observer.selection.previous) |previous|
        result.selection.previous = try copyReference(a, previous);
    errdefer if (result.selection.previous) |previous| a.free(previous.id.bytes);
    result.selection.source.expected.work = try copyReference(
        a,
        observer.selection.source.expected.work,
    );
    errdefer a.free(result.selection.source.expected.work.id.bytes);
    result.selection.source.nodes = try copyScope(a, observer.selection.source.nodes);
    errdefer freeScope(a, result.selection.source.nodes);
    if (observer.selection.source.disclosure) |selected|
        result.selection.source.disclosure = try copyDisclosure(a, selected);
    return result;
}

fn freeScope(a: std.mem.Allocator, scope: w.NodeScope) void {
    if (scope == .selected) a.free(scope.selected.items);
}

pub fn freeObserver(a: std.mem.Allocator, observer: @import("workspace_state.zig").Observer) void {
    const selection = observer.selection;
    a.free(selection.program.id.bytes);
    a.free(selection.accumulator.id.bytes);
    if (selection.previous) |previous| a.free(previous.id.bytes);
    a.free(selection.source.expected.work.id.bytes);
    freeScope(a, selection.source.nodes);
    if (selection.source.disclosure) |selected| {
        a.free(selected.blobs.items);
        switch (selected.values) {
            .none => {},
            .nodes => |nodes| freeScope(a, nodes),
            .fields => |fields| {
                for (fields.items) |field| a.free(field.field.bytes);
                a.free(fields.items);
            },
        }
    }
}
