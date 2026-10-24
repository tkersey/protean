const std = @import("std");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const c = @import("protean_contracts");
const w = c.workspace;
const views = kosmos.RuntimeViews;
const state = @import("state.zig");
const projection = @import("workspace_projection.zig");

pub const PublicationPrefix = struct {
    const Set = std.AutoHashMapUnmanaged(state.Digest, void);
    const Position = struct { publication: state.WorkPublication, seq: u64 };
    const Source = struct { lossless: Set = .empty, outer: Set = .empty };

    latest: std.AutoHashMap(state.Digest, Position),
    successors: Set = .empty,
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
        self.successors.deinit(a);
        self.latest.deinit();
    }

    fn remove(self: *PublicationPrefix, source: state.Digest, id: state.Digest) void {
        const group = self.sources.getPtr(source) orelse return;
        _ = group.lossless.remove(id);
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
        try self.latest.put(item.work, .{ .publication = item, .seq = seq });
    }

    pub fn hasOuter(self: *const PublicationPrefix, id: state.Digest) bool {
        const group = self.sources.get(id) orelse return false;
        return group.outer.count() != 0;
    }

    pub fn lossless(self: *PublicationPrefix, id: state.Digest) ?*Set {
        const group = self.sources.getPtr(id) orelse return null;
        return &group.lossless;
    }
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
