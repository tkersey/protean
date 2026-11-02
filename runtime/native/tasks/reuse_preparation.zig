const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const workspace = @import("../workspace_state.zig");
const archive = @import("../archive.zig");
const reuse = @import("../reuse_state.zig");
const policy = @import("../reuse_policy.zig");
const storage = @import("../store.zig");

pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    parent: state.Task,
    definition: reuse.Definition,
    disclosure: policy.Frozen,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);

        const Validation = enum { historical, executable };

        pub fn validateDefinition(
            self: *Self,
            a: std.mem.Allocator,
            value: reuse.Definition,
        ) anyerror!void {
            try reuse.validate(a, Lifecycle.store(self), value);
            if (self.reuse_provenance_validation) return;
            for ([_]Validation{ .historical, .executable }) |validation| {
                var queue: reuse.Origins = .{ .a = a };
                defer queue.deinit();
                try validateOrigin(self, a, value.origin, &queue, validation);
                try validateQueued(self, a, &queue, validation);
            }
        }

        pub fn validateArchiveOrigins(
            self: *Self,
            a: std.mem.Allocator,
            origin: state.Archive,
        ) anyerror!void {
            if (self.reuse_provenance_validation) return;
            for ([_]Validation{ .historical, .executable }) |validation| {
                var queue: reuse.Origins = .{ .a = a };
                defer queue.deinit();
                try scanOrigins(Lifecycle.store(self), origin, &queue, validation);
                try validateQueued(self, a, &queue, validation);
            }
        }

        fn scanOrigins(
            store: *storage.Store,
            origin: state.Archive,
            queue: *reuse.Origins,
            validation: Validation,
        ) !void {
            switch (validation) {
                .historical => try queue.scan(store, origin),
                .executable => try queue.scanPublications(store, origin),
            }
        }

        fn validateQueued(
            self: *Self,
            a: std.mem.Allocator,
            queue: *reuse.Origins,
            validation: Validation,
        ) !void {
            var index: usize = 0;
            while (index < queue.references.count()) : (index += 1) {
                const ref = queue.references.keys()[index];
                const bytes = try Lifecycle.store(self).object(a, ref, null);
                defer a.free(bytes);
                var definition = try contracts.decodeOwned(reuse.Definition, a, bytes);
                defer definition.deinit();
                try reuse.validate(a, Lifecycle.store(self), definition.value);
                try validateOrigin(self, a, definition.value.origin, queue, validation);
            }
        }

        fn validateOrigin(
            self: *Self,
            a: std.mem.Allocator,
            origin: state.Archive,
            queue: *reuse.Origins,
            validation: Validation,
        ) !void {
            const store = Lifecycle.store(self);
            try scanOrigins(store, origin, queue, validation);
            const bytes = try store.object(a, origin.task, null);
            defer a.free(bytes);
            var parent = try contracts.decodeOwned(state.Task, a, bytes);
            defer parent.deinit();
            if (!std.mem.eql(u8, parent.value.principal.bytes, self.profile.authority.principal) or
                !std.mem.eql(u8, parent.value.tenant.bytes, self.profile.authority.tenant))
                return error.InvalidArchive;
            var view = try HistoricalIndex.open(store, origin, parent.value);
            defer view.close() catch store.fence();
            const previous = self.reuse_provenance_validation;
            self.reuse_provenance_validation = true;
            defer self.reuse_provenance_validation = previous;
            switch (validation) {
                .historical => try Occurrences.validateHistoricalAdmissions(
                    self,
                    a,
                    parent.value,
                    origin,
                ),
                .executable => {
                    try Occurrences.validateArchiveAdmissions(self, a, parent.value, origin);
                    try Snapshots.validateWorkspaceArchive(self, a, parent.value, origin, .inspect);
                },
            }
            try view.close();
        }

        pub fn prepare(
            self: *Self,
            task_id: state.TaskId,
            program_id: state.Digest,
            scope: []const u8,
            description: reuse.Description,
        ) !Prepared {
            try Lifecycle.allowed(self);
            const store = Lifecycle.store(self);
            if (store.transaction) return error.CompilerPreparationRequired;
            try self.profile.reuse.authorize(self.profile.authority, scope, .retain);
            try Lifecycle.requireCustody(self, self.allocator, task_id, null);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const parent = try self.task(a, task_id);
            const program = try Programs.workspaceProgram(self, a, task_id, program_id);
            const artifact = program.value.description;
            if (artifact.source_kind != .source_records or artifact.catalog != null or
                artifact.controller != null) return error.UnsupportedCapability;
            const origin = try archive.prepare(a, store, task_id, self.assets.manifest);
            try Occurrences.validateArchiveAdmissions(self, a, parent.value, origin);
            try Snapshots.validateWorkspaceArchive(
                self,
                a,
                parent.value,
                origin,
                .inspect,
            );
            const definition: reuse.Definition = .{
                .scope = .{ .bytes = try a.dupe(u8, scope) },
                .description = .{
                    .name = .{ .bytes = try a.dupe(u8, description.name.bytes) },
                    .purpose = .{ .bytes = try a.dupe(u8, description.purpose.bytes) },
                },
                .source_task = task_id,
                .program = program.value.artifact,
                .artifact = artifact,
                .origin = origin,
            };
            try reuse.validateConstruction(a, definition);
            try reuse.validatePublication(a, store, definition);
            const frozen = try freezeDisclosure(a, store, definition, self.assets.manifest);
            try self.profile.reuse.disclose(self.profile.authority, scope, frozen);
            return .{
                .arena = arena,
                .parent = parent.value,
                .definition = definition,
                .disclosure = frozen,
            };
        }
    };
}

pub fn freezeDisclosure(
    a: std.mem.Allocator,
    store: *@import("../store.zig").Store,
    definition: reuse.Definition,
    build: []const u8,
) !policy.Frozen {
    var collector: References = .{ .a = a };
    try state.visitReferences(workspace.ProgramArtifact, definition.artifact, &collector);
    try collector.add(definition.program);
    const artifacts = try a.alloc(policy.Object, collector.refs.count());
    for (collector.refs.keys(), artifacts) |ref, *object| object.* = .{
        .reference = ref,
        .bytes = try store.object(a, ref, null),
    };
    const history = try a.alloc(policy.Object, definition.origin.objects.items.len);
    for (definition.origin.objects.items, history) |ref, *object| object.* = .{
        .reference = ref,
        .bytes = try historyBytes(a, store, definition.origin, ref, build),
    };
    return .{
        .artifacts = artifacts,
        .history = history,
        .description = try contracts.encodeOwned(reuse.Description, a, definition.description),
    };
}

fn historyBytes(
    a: std.mem.Allocator,
    store: *@import("../store.zig").Store,
    origin: state.Archive,
    ref: state.Reference,
    build: []const u8,
) ![]const u8 {
    if (std.meta.eql(ref, origin.build)) return a.dupe(u8, build);
    for (origin.schemas.items) |schema| {
        if (std.meta.eql(ref, schema.definition)) return archive.schemaBytes(a, schema.name.bytes);
    }
    return store.object(a, ref, null);
}

const References = struct {
    a: std.mem.Allocator,
    refs: std.AutoArrayHashMapUnmanaged(state.Reference, void) = .empty,

    pub fn add(self: *References, ref: state.Reference) !void {
        try self.refs.put(self.a, ref, {});
    }
};

const HistoricalIndex = @import("../historical_index.zig").HistoricalIndex;
