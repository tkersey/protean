//! Private storage primitive for the standalone task owner. SQL is authored
//! here/in the store, never accepted from client or model data.
const std = @import("std");
const c = @import("native_c");
var in_use: std.atomic.Value(bool) = .init(false);
pub const Error = error{
    StorageUnavailable,
    CorruptState,
    Capacity,
    Constraint,
    AlreadyOpen,
    Closed,
    Busy,
} || std.mem.Allocator.Error;

fn result(code: c_int) Error!void {
    return switch (code & 0xff) {
        c.SQLITE_OK => {},
        c.SQLITE_NOMEM, c.SQLITE_TOOBIG, c.SQLITE_FULL => error.Capacity,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.CorruptState,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        else => error.StorageUnavailable,
    };
}

pub const Param = union(enum) { text: []const u8, blob: []const u8, integer: i64, null };

const Storage = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.sqlite3,
    released: bool = false,
};

pub const Database = opaque {
    fn owner(self: *Database) *Storage {
        return @ptrCast(@alignCast(self));
    }
    fn handle(self: *Database) Error!*c.sqlite3 {
        return self.owner().handle orelse error.Closed;
    }

    /// One connection per native process, using SQLite's system allocator. The caller
    /// must acquire the namespace's OS lock before opening its database.
    pub fn open(a: std.mem.Allocator, path: []const u8, create: bool) Error!*Database {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.StorageUnavailable;
        if (in_use.cmpxchgStrong(
            false,
            true,
            .acquire,
            .monotonic,
        ) != null) return error.AlreadyOpen;
        errdefer in_use.store(false, .release);
        const storage = try a.create(Storage);
        errdefer a.destroy(storage);
        errdefer _ = c.sqlite3_shutdown();
        try result(c.sqlite3_initialize());
        if (c.sqlite3_libversion_number() != 3053004) return error.StorageUnavailable;
        const name = try a.dupeSentinel(u8, path, 0);
        defer a.free(name);
        var db: ?*c.sqlite3 = null;
        const flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_FULLMUTEX | (if (create) @as(
            c_int,
            c.SQLITE_OPEN_CREATE,
        ) else 0);
        const opened = c.sqlite3_open_v2(name.ptr, &db, flags, null);
        errdefer if (db) |ptr| {
            _ = c.sqlite3_close(ptr);
        };
        try result(opened);
        const ptr = db orelse return error.StorageUnavailable;
        _ = c.sqlite3_extended_result_codes(ptr, 1);
        // Namespace authority excludes attaching other databases. Size and
        // allocation failures otherwise come from the actual SQLite/OS limits.
        _ = c.sqlite3_limit(ptr, c.SQLITE_LIMIT_ATTACHED, 0);
        storage.* = .{ .allocator = a, .handle = ptr };
        return @ptrCast(storage);
    }

    pub fn close(self: *Database) Error!void {
        const storage = self.owner();
        const db = try self.handle();
        // Reject live statements instead of deferring destruction past ownership.
        try result(c.sqlite3_close(db));
        storage.handle = null;
        try result(c.sqlite3_shutdown());
        storage.released = true;
        in_use.store(false, .release);
    }
    pub fn destroy(self: *Database) Error!void {
        const storage = self.owner();
        if (storage.handle != null or !storage.released) return error.Busy;
        storage.allocator.destroy(storage);
    }
    /// Query the linked SQLite library; this is not an application size policy.
    pub fn blobLimit(self: *Database) Error!usize {
        return @intCast(c.sqlite3_limit(try self.handle(), c.SQLITE_LIMIT_LENGTH, -1));
    }
    pub fn changes(self: *Database) Error!u64 {
        return @intCast(c.sqlite3_changes64(try self.handle()));
    }

    pub fn openBlob(
        self: *Database,
        comptime table: [:0]const u8,
        comptime column: [:0]const u8,
        row: i64,
        writable: bool,
    ) Error!Blob {
        var blob: ?*c.sqlite3_blob = null;
        try result(
            c.sqlite3_blob_open(
                try self.handle(),
                "main",
                table.ptr,
                column.ptr,
                row,
                @intFromBool(writable),
                &blob,
            ),
        );
        return .{ .handle = blob orelse return error.StorageUnavailable };
    }

    /// Only static owner SQL enters sqlite3_exec. Values use bound parameters.
    pub fn exec(self: *Database, comptime sql: [:0]const u8) Error!void {
        try result(c.sqlite3_exec(try self.handle(), sql.ptr, null, null, null));
    }
    pub fn prepare(
        self: *Database,
        comptime sql: [:0]const u8,
        params: []const Param,
    ) Error!Statement {
        var statement: ?*c.sqlite3_stmt = null;
        try result(
            c.sqlite3_prepare_v3(
                try self.handle(),
                sql.ptr,
                @intCast(sql.len),
                0,
                &statement,
                null,
            ),
        );
        const stmt = statement orelse return error.StorageUnavailable;
        errdefer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_parameter_count(stmt) != @as(c_int, @intCast(params.len)))
            return error.StorageUnavailable;
        for (params, 1..) |param, i| {
            const index: c_int = @intCast(i);
            try result(switch (param) {
                .text => |bytes| c.sqlite3_bind_text64(
                    stmt,
                    index,
                    if (bytes.len == 0) "" else bytes.ptr,
                    bytes.len,
                    c.SQLITE_STATIC,
                    c.SQLITE_UTF8,
                ),
                .blob => |bytes| if (bytes.len == 0) c.sqlite3_bind_zeroblob64(
                    stmt,
                    index,
                    0,
                ) else c.sqlite3_bind_blob64(
                    stmt,
                    index,
                    bytes.ptr,
                    bytes.len,
                    c.SQLITE_STATIC,
                ),
                .integer => |value| c.sqlite3_bind_int64(stmt, index, value),
                .null => c.sqlite3_bind_null(stmt, index),
            });
        }
        return .{ .handle = stmt };
    }
    pub fn run(self: *Database, comptime sql: [:0]const u8, params: []const Param) Error!void {
        var statement = try self.prepare(sql, params);
        defer statement.deinit();
        if (try statement.step() != .done) return error.StorageUnavailable;
    }
};

/// Incremental I/O avoids materializing a second complete payload in SQLite.
pub const Blob = struct {
    handle: *c.sqlite3_blob,

    pub fn close(self: *Blob) Error!void {
        const code = c.sqlite3_blob_close(self.handle);
        self.* = undefined;
        try result(code);
    }
    pub fn length(self: Blob) usize {
        return @intCast(c.sqlite3_blob_bytes(self.handle));
    }
    pub fn read(self: Blob, bytes: []u8, offset: usize) Error!void {
        if (offset > self.length() or bytes.len > self.length() - offset) return error.CorruptState;
        if (bytes.len != 0) try result(
            c.sqlite3_blob_read(self.handle, bytes.ptr, @intCast(bytes.len), @intCast(offset)),
        );
    }
    pub fn write(self: Blob, bytes: []const u8, offset: usize) Error!void {
        if (offset > self.length() or bytes.len > self.length() - offset) return error.CorruptState;
        if (bytes.len != 0) try result(
            c.sqlite3_blob_write(self.handle, bytes.ptr, @intCast(bytes.len), @intCast(offset)),
        );
    }
};

/// Parameters and returned column slices are borrowed until finalization or the
/// next step. The Store consumes/copies them synchronously under its owner.
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }
    pub fn step(self: *Statement) Error!enum { row, done } {
        const code = c.sqlite3_step(self.handle);
        switch (code) {
            c.SQLITE_ROW => return .row,
            c.SQLITE_DONE => return .done,
            else => {
                try result(code);
                return error.StorageUnavailable;
            },
        }
    }
    pub fn integer(self: Statement, index: c_int) Error!i64 {
        if (c.sqlite3_column_type(
            self.handle,
            index,
        ) != c.SQLITE_INTEGER) return error.CorruptState;
        return c.sqlite3_column_int64(self.handle, index);
    }
    pub fn bytes(self: Statement, index: c_int) Error![]const u8 {
        const kind = c.sqlite3_column_type(self.handle, index);
        if (kind != c.SQLITE_BLOB and kind != c.SQLITE_TEXT) return error.CorruptState;
        const length = c.sqlite3_column_bytes(self.handle, index);
        if (length < 0) return error.CorruptState;
        if (length == 0) return &.{};
        const ptr = c.sqlite3_column_blob(self.handle, index) orelse return error.CorruptState;
        return @as([*]const u8, @ptrCast(ptr))[0..@intCast(length)];
    }
    pub fn isNull(self: Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }
};
