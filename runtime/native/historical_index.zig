const std = @import("std");
const state = @import("state.zig");
const storage = @import("store.zig");

pub const HistoricalIndex = struct {
    store: *storage.Store,
    live: bool = true,
    retention_epoch: ?u64,
    retention_image: ?state.Digest,

    pub fn open(store: *storage.Store, origin: state.Archive, task: state.Task) !HistoricalIndex {
        var result: HistoricalIndex = .{
            .store = store,
            .retention_epoch = store.task_retention_epoch,
            .retention_image = store.task_retention_image,
        };
        store.task_retention_epoch = null;
        store.task_retention_image = null;
        errdefer result.close() catch store.fence();
        try store.database.exec(
            "CREATE TEMP TABLE tasks AS SELECT * FROM main.tasks WHERE 0;" ++
                "CREATE TEMP TABLE records AS SELECT * FROM main.records WHERE 0;" ++
                "CREATE TEMP TABLE events AS SELECT * FROM main.events WHERE 0;" ++
                "CREATE TEMP TABLE operations AS SELECT * FROM main.operations WHERE 0;" ++
                "CREATE TEMP TABLE retired_tasks AS SELECT * FROM main.retired_tasks WHERE 0;",
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

    pub fn close(self: *HistoricalIndex) !void {
        if (!self.live) return;
        try self.store.database.exec(
            "DROP TABLE IF EXISTS temp.retired_tasks;" ++
                "DROP TABLE IF EXISTS temp.operations;" ++
                "DROP TABLE IF EXISTS temp.events;" ++
                "DROP TABLE IF EXISTS temp.records;" ++
                "DROP TABLE IF EXISTS temp.tasks;",
        );
        self.store.task_retention_epoch = self.retention_epoch;
        self.store.task_retention_image = self.retention_image;
        self.live = false;
    }
};
