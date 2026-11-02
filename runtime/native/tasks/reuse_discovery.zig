const std = @import("std");
const contracts = @import("protean_contracts");
const json = @import("../json.zig");
const state = @import("../state.zig");
const workspace = @import("../workspace_state.zig");
const retained = @import("../reuse_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const Observation = @FieldType(workspace.ReadObservation, "reuse");
const Selection = @FieldType(Observation, "selection");
const Find = @FieldType(Selection, "find");
const Inspect = @FieldType(Selection, "inspect");

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const store = @import("lifecycle.zig").Operations(Types, Self).store;

        pub fn capture(
            self: *Self,
            a: std.mem.Allocator,
            watermark: u64,
            command: wc.Program,
        ) !workspace.ReadObservation {
            const selection: Selection = switch (command) {
                .find => |request| .{ .find = try captureFind(self, a, request) },
                .inspect => |request| blk: {
                    if (request.target != .retained) return error.InvalidState;
                    const locator = request.target.retained;
                    try self.profile.reuse.authorize(
                        self.profile.authority,
                        locator.scope.bytes,
                        .read,
                    );
                    const id = try locatorIdentity(locator);
                    const bytes = try store(self).definitionBytes(a, locator.scope.bytes, id) orelse
                        return error.ArtifactUnavailable;
                    defer a.free(bytes);
                    const reference: state.Reference = .{ .digest = id, .bytes = bytes.len };
                    if (!try owned(self, a, reference)) return error.ArtifactUnavailable;
                    break :blk .{ .inspect = .{
                        .locator = locator,
                        .page = request.page,
                        .definition = reference,
                    } };
                },
                else => return error.InvalidState,
            };
            return .{ .reuse = .{ .selection = selection, .event_watermark = watermark } };
        }

        fn captureFind(self: *Self, a: std.mem.Allocator, request: wc.Find) !Find {
            try self.profile.reuse.authorize(self.profile.authority, request.scope.bytes, .read);
            try findLimits(request);
            try store(self).checkIntegrity();
            var cursor = try store(self).database.prepare(
                "SELECT body FROM reuse_definitions WHERE scope=? ORDER BY body LIMIT ?",
                &.{ .{ .text = request.scope.bytes }, .{ .integer = request.maximum } },
            );
            defer cursor.deinit();
            var definitions: std.ArrayList(state.Reference) = .empty;
            errdefer definitions.deinit(a);
            while (try cursor.step() == .row) {
                const bytes = try cursor.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                const reference = try store(self).objectReference(bytes[0..32].*, null);
                if (!try owned(self, a, reference)) continue;
                try definitions.append(a, reference);
            }
            return .{
                .request = request,
                .definitions = .{ .items = try definitions.toOwnedSlice(a) },
            };
        }

        pub fn find(
            self: *Self,
            a: std.mem.Allocator,
            scope: []const u8,
            query: []const u8,
            maximum: u32,
            page_bytes: u32,
            basis: ?workspace.ReadObservation,
        ) !json.Value {
            try self.profile.reuse.authorize(self.profile.authority, scope, .read);
            const command: wc.Program = .{ .find = .{
                .scope = .{ .bytes = scope },
                .query = .{ .bytes = query },
                .maximum = maximum,
                .page_bytes = page_bytes,
            } };
            const observation = basis orelse try capture(self, a, 0, command);
            if (observation != .reuse) return error.InvalidArchive;
            try binding(command, observation.reuse.selection);
            if (basis != null) try requireOwnedSelection(self, a, observation.reuse.selection);
            return renderFind(self, a, observation.reuse.selection.find);
        }

        fn renderFind(self: *Self, a: std.mem.Allocator, selected: Find) !json.Value {
            try validateFindSelection(selected);
            const request = selected.request;
            var result = try findResult(a, request);
            var limits = json.payload_limits;
            limits.bytes = request.page_bytes;
            if (!try json.fits(a, result, limits)) return error.Capacity;
            var scanned: u32 = 0;
            var results_limited = false;
            for (selected.definitions.items) |reference| {
                scanned += 1;
                const candidate = try matched(self, a, request, reference) orelse continue;
                try result.object.getPtr("records").?.array.append(candidate);
                if (!try json.fits(a, result, limits)) {
                    _ = result.object.getPtr("records").?.array.pop();
                    results_limited = true;
                    break;
                }
            }
            try json.put(a, &result, "scanned", try json.number(a, scanned));
            try json.put(a, &result, "results_limited", .{ .bool = results_limited });
            return result;
        }

        fn matched(
            self: *Self,
            a: std.mem.Allocator,
            request: wc.Find,
            reference: state.Reference,
        ) !?json.Value {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var definition = try load(self, scratch.allocator(), request.scope.bytes, reference);
            defer definition.deinit();
            const description = definition.value.description;
            if (std.mem.indexOf(u8, description.name.bytes, request.query.bytes) == null and
                std.mem.indexOf(u8, description.purpose.bytes, request.query.bytes) == null)
                return null;
            return try descriptor(a, request.scope.bytes, reference.digest, description);
        }

        pub fn inspect(
            self: *Self,
            a: std.mem.Allocator,
            locator: wc.RetainedLocator,
            page: wc.Page,
            basis: ?workspace.ReadObservation,
        ) !json.Value {
            try self.profile.reuse.authorize(self.profile.authority, locator.scope.bytes, .read);
            const command: wc.Program = .{ .inspect = .{
                .target = .{ .retained = locator },
                .page = page,
            } };
            const observation = basis orelse try capture(self, a, 0, command);
            if (observation != .reuse) return error.InvalidArchive;
            try binding(command, observation.reuse.selection);
            if (basis != null) try requireOwnedSelection(self, a, observation.reuse.selection);
            return renderInspect(self, a, observation.reuse.selection.inspect);
        }

        fn owned(self: *Self, a: std.mem.Allocator, reference: state.Reference) !bool {
            const bytes = try store(self).object(a, reference, null);
            defer a.free(bytes);
            var definition = try contracts.decodeOwned(retained.Definition, a, bytes);
            defer definition.deinit();
            return retained.sameOwner(
                a,
                store(self),
                definition.value,
                self.profile.authority.principal,
                self.profile.authority.tenant,
            );
        }

        fn requireOwnedSelection(self: *Self, a: std.mem.Allocator, selected: Selection) !void {
            switch (selected) {
                .find => |found| for (found.definitions.items) |reference| {
                    if (!try owned(self, a, reference)) return error.ArtifactUnavailable;
                },
                .inspect => |inspected| {
                    if (!try owned(self, a, inspected.definition)) return error.ArtifactUnavailable;
                },
            }
        }

        fn renderInspect(self: *Self, a: std.mem.Allocator, selected: Inspect) !json.Value {
            const scope = selected.locator.scope.bytes;
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var definition = try load(self, scratch.allocator(), scope, selected.definition);
            defer definition.deinit();
            const source = definition.value.artifact.source;
            const page = selected.page;
            if (page.maximum == 0 or page.maximum > json.payload_limits.bytes or
                page.offset > source.bytes) return error.InvalidRange;
            const length = @min(source.bytes - page.offset, @as(u64, page.maximum) + 1);
            const bytes = try scratch.allocator().alloc(u8, @intCast(length));
            try store(self).objectRange(source, @intCast(page.offset), bytes);
            var result = try descriptor(
                a,
                scope,
                selected.definition.digest,
                definition.value.description,
            );
            try json.put(a, &result, "source", try wp.window(a, bytes, page, source.bytes));
            try json.put(a, &result, "source_kind", json.string("source_records"));
            try json.put(a, &result, "history_disclosed", .{ .bool = false });
            return result;
        }

        pub fn historical(self: *Self, a: std.mem.Allocator, observed: Observation) !json.Value {
            return switch (observed.selection) {
                .find => |selected| renderFind(self, a, selected),
                .inspect => |selected| renderInspect(self, a, selected),
            };
        }

        pub fn validate(
            self: *Self,
            a: std.mem.Allocator,
            command: wc.Program,
            observed: Observation,
        ) !void {
            try binding(command, observed.selection);
            switch (observed.selection) {
                .find => |selected| {
                    try validateFindSelection(selected);
                    for (selected.definitions.items) |reference|
                        try validateDefinition(self, a, selected.request.scope.bytes, reference);
                },
                .inspect => |selected| try validateDefinition(
                    self,
                    a,
                    selected.locator.scope.bytes,
                    selected.definition,
                ),
            }
        }

        fn validateDefinition(
            self: *Self,
            a: std.mem.Allocator,
            scope: []const u8,
            reference: state.Reference,
        ) !void {
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            var definition = try load(self, scratch.allocator(), scope, reference);
            defer definition.deinit();
            if (!try retained.sameOwner(
                scratch.allocator(),
                store(self),
                definition.value,
                self.profile.authority.principal,
                self.profile.authority.tenant,
            )) return error.InvalidArchive;
            try retained.validate(scratch.allocator(), store(self), definition.value);
        }

        fn load(
            self: *Self,
            a: std.mem.Allocator,
            scope: []const u8,
            reference: state.Reference,
        ) !contracts.Decoded(retained.Definition) {
            const bytes = try store(self).object(a, reference, null);
            defer a.free(bytes);
            var definition = try contracts.decodeOwned(retained.Definition, a, bytes);
            errdefer definition.deinit();
            try store(self).checkDependencies(
                retained.Definition,
                state.Reference,
                reference,
                definition.value,
            );
            if (definition.value.version != 1 or
                definition.value.artifact.source_kind != .source_records)
                return error.UnsupportedCapability;
            if (!std.mem.eql(u8, definition.value.scope.bytes, scope)) return error.CorruptState;
            return definition;
        }
    };
}

fn findLimits(request: wc.Find) !void {
    if (request.maximum == 0 or request.maximum > json.payload_limits.members or
        request.query.bytes.len > 256 or request.page_bytes == 0 or
        request.page_bytes > json.payload_limits.bytes) return error.InvalidRange;
}

fn validateFindSelection(selected: Find) !void {
    try findLimits(selected.request);
    if (selected.definitions.items.len > selected.request.maximum) return error.InvalidArchive;
    for (selected.definitions.items, 0..) |reference, index| {
        if (index == 0) continue;
        const prior = selected.definitions.items[index - 1];
        if (std.mem.order(u8, &prior.digest, &reference.digest) != .lt) return error.InvalidArchive;
    }
}

fn binding(command: wc.Program, selected: Selection) !void {
    switch (selected) {
        .find => |saved| {
            if (command != .find) return error.InvalidArchive;
            const request = command.find;
            if (!std.mem.eql(u8, saved.request.scope.bytes, request.scope.bytes) or
                !std.mem.eql(u8, saved.request.query.bytes, request.query.bytes) or
                saved.request.maximum != request.maximum or
                saved.request.page_bytes != request.page_bytes) return error.InvalidArchive;
        },
        .inspect => |saved| {
            if (command != .inspect or command.inspect.target != .retained)
                return error.InvalidArchive;
            const locator = command.inspect.target.retained;
            if (!std.mem.eql(u8, saved.locator.scope.bytes, locator.scope.bytes) or
                !std.mem.eql(u8, saved.locator.id.bytes, locator.id.bytes) or
                !std.meta.eql(saved.page, command.inspect.page) or
                !std.meta.eql(saved.definition.digest, try locatorIdentity(locator)))
                return error.InvalidArchive;
        },
    }
}

fn findResult(a: std.mem.Allocator, request: wc.Find) !json.Value {
    var result = json.object();
    try json.put(a, &result, "scope", json.string(try a.dupe(u8, request.scope.bytes)));
    try json.put(a, &result, "query", json.string(try a.dupe(u8, request.query.bytes)));
    try json.put(a, &result, "records", .{ .array = .init(a) });
    try json.put(a, &result, "scanned", try json.number(a, request.maximum));
    try json.put(a, &result, "coverage", json.string("selected_snapshot"));
    try json.put(a, &result, "scan_limited", .{ .bool = true });
    try json.put(a, &result, "results_limited", .{ .bool = false });
    try json.put(a, &result, "truncated", .{ .bool = true });
    return result;
}

fn descriptor(
    a: std.mem.Allocator,
    scope: []const u8,
    id: state.Digest,
    description: retained.Description,
) !json.Value {
    var locator = json.object();
    try json.put(a, &locator, "scope", json.string(try a.dupe(u8, scope)));
    try json.put(a, &locator, "id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
    var authored = json.object();
    try json.put(a, &authored, "name", json.string(try a.dupe(u8, description.name.bytes)));
    try json.put(a, &authored, "purpose", json.string(try a.dupe(u8, description.purpose.bytes)));
    var result = json.object();
    try json.put(a, &result, "locator", locator);
    try json.put(a, &result, "description", authored);
    return result;
}

fn locatorIdentity(locator: wc.RetainedLocator) !state.Digest {
    if (locator.id.bytes.len != 64) return error.InvalidReference;
    var id: state.Digest = undefined;
    _ = std.fmt.hexToBytes(&id, locator.id.bytes) catch return error.InvalidReference;
    if (!std.mem.eql(u8, locator.id.bytes, &std.fmt.bytesToHex(id, .lower)))
        return error.InvalidReference;
    return id;
}

test "frozen reuse discovery binds query limits and strictly ordered definitions" {
    const request: wc.Find = .{
        .scope = .{ .bytes = "shared" },
        .query = .{ .bytes = "helper" },
        .maximum = 2,
        .page_bytes = 4096,
    };
    const refs = [_]state.Reference{
        .{ .digest = @splat(1), .bytes = 32 },
        .{ .digest = @splat(2), .bytes = 64 },
    };
    var selected: Find = .{ .request = request, .definitions = .{ .items = &refs } };
    try validateFindSelection(selected);
    try binding(.{ .find = request }, .{ .find = selected });
    var changed = request;
    changed.query.bytes = "different";
    try std.testing.expectError(error.InvalidArchive, binding(
        .{ .find = changed },
        .{ .find = selected },
    ));
    changed = request;
    changed.page_bytes -= 1;
    try std.testing.expectError(error.InvalidArchive, binding(
        .{ .find = changed },
        .{ .find = selected },
    ));
    selected.definitions.items = &.{ refs[1], refs[0] };
    try std.testing.expectError(error.InvalidArchive, validateFindSelection(selected));
    selected.definitions.items = &.{ refs[0], refs[0] };
    try std.testing.expectError(error.InvalidArchive, validateFindSelection(selected));
    selected.definitions.items = &refs;
    selected.request.maximum = 1;
    try std.testing.expectError(error.InvalidArchive, validateFindSelection(selected));
}

test "frozen retained inspection binds exact identity and page" {
    const id: state.Digest = @splat(3);
    const encoded = std.fmt.bytesToHex(id, .lower);
    const selected: Inspect = .{
        .locator = .{ .scope = .{ .bytes = "shared" }, .id = .{ .bytes = &encoded } },
        .page = .{ .offset = 7, .maximum = 128 },
        .definition = .{ .digest = id, .bytes = 4096 },
    };
    var command: wc.Program = .{ .inspect = .{
        .target = .{ .retained = selected.locator },
        .page = selected.page,
    } };
    try binding(command, .{ .inspect = selected });
    command.inspect.page.offset += 1;
    try std.testing.expectError(error.InvalidArchive, binding(command, .{ .inspect = selected }));
    command.inspect.page = selected.page;
    command.inspect.target.retained.scope.bytes = "different";
    try std.testing.expectError(error.InvalidArchive, binding(command, .{ .inspect = selected }));
}
