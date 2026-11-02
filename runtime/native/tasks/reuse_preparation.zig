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

        pub fn validateDefinition(
            self: *Self,
            a: std.mem.Allocator,
            value: reuse.Definition,
        ) anyerror!void {
            try reuse.validate(a, Lifecycle.store(self), value);
            if (self.reuse_provenance_validation) return;
            var queue: reuse.Origins = .{ .a = a };
            defer queue.deinit();
            try validateOrigin(self, a, value.origin, &queue);
            try validateQueued(self, a, &queue);
        }

        pub fn validateArchiveOrigins(
            self: *Self,
            a: std.mem.Allocator,
            origin: state.Archive,
        ) anyerror!void {
            if (self.reuse_provenance_validation) return;
            var queue: reuse.Origins = .{ .a = a };
            defer queue.deinit();
            try queue.scanPublications(Lifecycle.store(self), origin);
            try validateQueued(self, a, &queue);
        }

        fn validateQueued(self: *Self, a: std.mem.Allocator, queue: *reuse.Origins) !void {
            var index: usize = 0;
            while (index < queue.references.count()) : (index += 1) {
                const ref = queue.references.keys()[index];
                const bytes = try Lifecycle.store(self).object(a, ref, null);
                defer a.free(bytes);
                var definition = try contracts.decodeOwned(reuse.Definition, a, bytes);
                defer definition.deinit();
                try reuse.validate(a, Lifecycle.store(self), definition.value);
                try validateOrigin(self, a, definition.value.origin, queue);
            }
        }

        fn validateOrigin(
            self: *Self,
            a: std.mem.Allocator,
            origin: state.Archive,
            queue: *reuse.Origins,
        ) !void {
            const store = Lifecycle.store(self);
            try queue.scanPublications(store, origin);
            const bytes = try store.object(a, origin.task, null);
            defer a.free(bytes);
            var parent = try contracts.decodeOwned(state.Task, a, bytes);
            defer parent.deinit();
            var view = try HistoricalIndex.open(store, origin, parent.value);
            defer view.close() catch store.fence();
            const previous = self.reuse_provenance_validation;
            self.reuse_provenance_validation = true;
            defer self.reuse_provenance_validation = previous;
            try Occurrences.validateArchiveAdmissions(self, a, parent.value, origin);
            try Snapshots.validateWorkspaceArchive(
                self,
                a,
                parent.value,
                origin,
                .inspect,
            );
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

const HistoricalIndex = struct {
    store: *storage.Store,
    live: bool = true,

    fn open(store: *storage.Store, origin: state.Archive, task: state.Task) !HistoricalIndex {
        var result: HistoricalIndex = .{ .store = store };
        errdefer result.close() catch store.fence();
        try store.database.exec(
            "CREATE TEMP TABLE tasks AS SELECT * FROM main.tasks WHERE 0;" ++
                "CREATE TEMP TABLE records AS SELECT * FROM main.records WHERE 0;" ++
                "CREATE TEMP TABLE events AS SELECT * FROM main.events WHERE 0;" ++
                "CREATE TEMP TABLE operations AS SELECT * FROM main.operations WHERE 0;",
        );
        try store.database.exec(
            "CREATE UNIQUE INDEX temp.historical_tasks ON tasks(id);" ++
                "CREATE UNIQUE INDEX temp.historical_records ON records(kind,id);" ++
                "CREATE UNIQUE INDEX temp.historical_events ON events(task,seq);" ++
                "CREATE UNIQUE INDEX temp.historical_operations ON operations(id);" ++
                "CREATE INDEX temp.historical_operation_tasks ON operations(task,id);",
        );
        try store.database.run("INSERT INTO temp.tasks VALUES(?,?,?,?)", &.{
            .{ .blob = &task.id },
            .{ .integer = std.math.cast(i64, task.revision) orelse return error.Capacity },
            .{ .integer = @intFromBool(task.terminal()) },
            .{ .blob = &origin.task.digest },
        });
        try result.populate(origin, task.id);
        return result;
    }

    fn populate(self: *HistoricalIndex, origin: state.Archive, task: state.TaskId) !void {
        const database = self.store.database;
        for (origin.records.items) |row| {
            try database.run("INSERT INTO temp.records VALUES(?,?,?,?)", &.{
                .{ .text = @tagName(row.kind) },
                .{ .blob = &row.id },
                .{ .blob = &task },
                .{ .blob = &row.body.digest },
            });
        }
        for (origin.events.items) |row| {
            try database.run("INSERT INTO temp.events VALUES(?,?,?,?)", &.{
                .{ .blob = &task },
                .{ .integer = std.math.cast(i64, row.seq) orelse return error.Capacity },
                .{ .integer = std.math.cast(i64, row.revision) orelse return error.Capacity },
                .{ .blob = &row.body.digest },
            });
        }
        for (origin.operations.items) |row| {
            try database.run("INSERT INTO temp.operations VALUES(?,?,?,?)", &.{
                .{ .text = row.key.bytes },
                .{ .blob = &row.request },
                .{ .blob = &row.body.digest },
                .{ .blob = &task },
            });
        }
    }

    fn close(self: *HistoricalIndex) !void {
        if (!self.live) return;
        try self.store.database.exec(
            "DROP TABLE IF EXISTS temp.operations;" ++
                "DROP TABLE IF EXISTS temp.events;" ++
                "DROP TABLE IF EXISTS temp.records;" ++
                "DROP TABLE IF EXISTS temp.tasks;",
        );
        self.live = false;
    }
};
