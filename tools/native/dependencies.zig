//! Host-only dependency admission and build metadata. This bootstrap imports
//! only the selected Zig standard library, never an input it is admitting.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const max_file = 512 * 1024 * 1024;

comptime {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) @compileError("Zig 0.17.0 is required");
}

const Context = struct {
    a: Allocator,
    scratch: Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map = null,

    fn join(c: Context, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(c.a, parts);
    }
    fn read(c: Context, path: []const u8, limit: usize) ![]u8 {
        return c.readWithAllocator(c.a, path, limit);
    }
    fn readWithAllocator(c: Context, allocator: Allocator, path: []const u8, limit: usize) ![]u8 {
        var file = try Dir.cwd().openFile(c.io, path, .{ .follow_symlinks = false, .allow_directory = false });
        defer file.close(c.io);
        const before = try file.stat(c.io);
        if (before.kind != .file or before.size > limit) return error.InvalidFile;
        var reader = file.reader(c.io, &.{});
        const bytes = try reader.interface.allocRemaining(allocator, .limited(limit));
        errdefer allocator.free(bytes);
        const after = try file.stat(c.io);
        const named = try Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false });
        if (!stable(before, after) or !stable(after, named) or bytes.len != before.size) return error.InputChanged;
        return bytes;
    }
    fn json(c: Context, path: []const u8) !Value {
        const bytes = try c.read(path, 1024 * 1024);
        defer c.a.free(bytes);
        return std.json.parseFromSliceLeaky(Value, c.a, bytes, .{ .allocate = .alloc_always });
    }
    fn digest(c: Context, bytes: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        if (comptime @hasDecl(@import("root"), "native_hash")) {
            const optimized = @import("root").native_hash;
            var state: optimized.State = undefined;
            optimized.protean_native_sha256_init(&state);
            optimized.protean_native_sha256_update(&state, bytes.ptr, bytes.len);
            optimized.protean_native_sha256_final(&state, &hash);
        } else std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        return c.a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
    }
    fn fileDigest(c: Context, path: []const u8) ![]const u8 {
        const bytes = try c.readWithAllocator(c.scratch, path, max_file);
        defer c.scratch.free(bytes);
        return c.digest(bytes);
    }
    fn encode(c: Context, input: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(c.a, input, .{});
    }
    fn value(c: Context, input: anytype) !Value {
        return std.json.parseFromSliceLeaky(Value, c.a, try c.encode(input), .{ .allocate = .alloc_always });
    }
    fn put(c: Context, object: *Value, key: []const u8, input: anytype) !void {
        try object.object.put(c.a, key, try c.value(input));
    }
};

fn sha3(bytes: []const u8, output: *[32]u8) void {
    if (comptime @hasDecl(@import("root"), "native_hash")) {
        @import("root").native_hash.protean_native_sha3_256(bytes.ptr, bytes.len, output);
    } else std.crypto.hash.sha3.Sha3_256.hash(bytes, output, .{});
}

fn stable(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.kind == b.kind and
        a.permissions == b.permissions and std.meta.eql(a.mtime, b.mtime) and std.meta.eql(a.ctime, b.ctime);
}
fn field(v: Value, name: []const u8) !Value {
    if (v != .object) return error.InvalidMetadata;
    return v.object.get(name) orelse error.InvalidMetadata;
}
fn string(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidMetadata;
}
fn text(v: Value, name: []const u8) ![]const u8 {
    return string(try field(v, name));
}
fn number(v: Value) !u64 {
    if (v != .integer or v.integer < 0) return error.InvalidMetadata;
    return @intCast(v.integer);
}
fn equal(a: []const u8, b: []const u8) !void {
    if (!std.mem.eql(u8, a, b)) return error.IdentityMismatch;
}

const Inventory = struct {
    files: std.ArrayList(Value) = .empty,
    bytes: u64 = 0,
    maximum_entries: usize = 10000,

    fn walk(inventory: *Inventory, c: Context, root: Dir, relative: []const u8, depth: usize) anyerror!void {
        if (depth > 32) return error.Capacity;
        var dir = try root.openDir(c.io, if (relative.len == 0) "." else relative, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(c.io);
        const before = try dir.stat(c.io);
        var names: std.ArrayList([]const u8) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(c.io)) |entry| {
            if (names.items.len + inventory.files.items.len >= inventory.maximum_entries) return error.Capacity;
            if (std.mem.indexOfAny(u8, entry.name, "\\\x00\r\n") != null) return error.InvalidPath;
            try names.append(c.a, try c.a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            if (inventory.files.items.len >= inventory.maximum_entries) return error.Capacity;
            const path = if (relative.len == 0) name else try c.join(&.{ relative, name });
            const stat = try dir.statFile(c.io, name, .{ .follow_symlinks = false });
            const mode = stat.permissions.toMode() & 0o777;
            if (stat.kind == .directory) {
                try inventory.files.append(c.a, try c.value(.{ .path = path, .kind = "directory", .mode = mode }));
                try inventory.walk(c, root, path, depth + 1);
            } else if (stat.kind == .file) {
                var file = try dir.openFile(c.io, name, .{ .follow_symlinks = false, .allow_directory = false });
                defer file.close(c.io);
                if (!stable(stat, try file.stat(c.io)) or stat.size > max_file) return error.InvalidFile;
                var reader = file.reader(c.io, &.{});
                const bytes = try reader.interface.allocRemaining(c.scratch, .limited(max_file));
                defer c.scratch.free(bytes);
                if (!stable(stat, try file.stat(c.io)) or !stable(stat, try dir.statFile(c.io, name, .{ .follow_symlinks = false })) or bytes.len != stat.size) return error.InputChanged;
                inventory.bytes = try std.math.add(u64, inventory.bytes, bytes.len);
                if (inventory.bytes > 1024 * 1024 * 1024) return error.Capacity;
                try inventory.files.append(c.a, try c.value(.{ .path = path, .kind = "file", .mode = mode, .bytes = bytes.len, .sha256 = try c.digest(bytes) }));
            } else return error.InvalidFile;
        }
        if (!stable(before, try dir.stat(c.io))) return error.InputChanged;
    }
    fn load(c: Context, path: []const u8, maximum: usize) !Inventory {
        const named = try Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false });
        if (named.kind != .directory) return error.InvalidFile;
        var root = try Dir.cwd().openDir(c.io, path, .{ .follow_symlinks = false });
        defer root.close(c.io);
        if (!stable(named, try root.stat(c.io))) return error.InputChanged;
        var result: Inventory = .{ .maximum_entries = maximum };
        try result.walk(c, root, "", 0);
        if (!stable(named, try root.stat(c.io)) or !stable(named, try Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false }))) return error.InputChanged;
        return result;
    }
    fn identity(inventory: Inventory, c: Context) ![]const u8 {
        return c.digest(try c.encode(inventory.files.items));
    }
    // Preserve the established compiler-library identity projection. Source
    // inventories use the separate kind-tagged projection above.
    fn libraryIdentity(inventory: Inventory, c: Context) ![]const u8 {
        var rows: std.ArrayList(Value) = .empty;
        for (inventory.files.items) |row| {
            if (std.mem.eql(u8, try text(row, "kind"), "directory")) {
                try rows.append(c.a, try c.value(.{ .path = try text(row, "path"), .directory = true, .mode = try number(try field(row, "mode")) }));
            } else {
                try rows.append(c.a, try c.value(.{ .path = try text(row, "path"), .bytes = try number(try field(row, "bytes")), .mode = try number(try field(row, "mode")), .sha256 = try text(row, "sha256") }));
            }
        }
        return c.digest(try c.encode(rows.items));
    }
    fn verify(inventory: Inventory, c: Context, expected: Value) !void {
        try equal(try inventory.identity(c), try text(expected, "inventorySha256"));
        if (inventory.files.items.len != try number(try field(expected, "entries")) or inventory.bytes != try number(try field(expected, "bytes"))) return error.IdentityMismatch;
    }
};

fn lockAt(c: Context, path: []const u8) !Value {
    const lock = try c.json(path);
    try equal(try text(lock, "format"), "agent-native-source-lock/v2");
    const status = try text(lock, "status");
    if (!std.mem.eql(u8, status, "released-integration") and !std.mem.eql(u8, status, "development-integration")) return error.InvalidMetadata;
    inline for (.{ .{ "boundary", "horos" }, .{ "world", "kronos" } }) |binding| {
        const item = try field(lock, binding[0]);
        const repository = "tkersey/" ++ binding[1];
        try equal(try text(item, "repository"), repository);
        const commit = try text(item, "commit");
        if (commit.len != 40) return error.InvalidMetadata;
        var decoded: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&decoded, commit);
        try equal(try text(try field(item, "archive"), "url"), try std.fmt.allocPrint(c.a, "https://github.com/{s}/archive/{s}.tar.gz", .{ repository, commit }));
    }
    return lock;
}

fn verifySource(c: Context, path: []const u8, expected: Value, package: bool) !void {
    const inventory = try Inventory.load(c, path, 10000);
    if (package) {
        const profiles = try field(try field(expected, "package"), "profiles");
        inventory.verify(c, try field(profiles, "zig-managed")) catch {
            try inventory.verify(c, try field(profiles, "archive-extracted"));
        };
    } else try inventory.verify(c, try field(expected, "source"));
}

fn sqliteLicense(c: Context, header: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, header, "/*\n")) return error.InvalidLicense;
    const end = std.mem.indexOf(u8, header, "********************") orelse return error.InvalidLicense;
    var result: std.Io.Writer.Allocating = .init(c.a);
    var lines = std.mem.splitScalar(u8, header[3..end], '\n');
    while (lines.next()) |line| {
        const body = if (std.mem.startsWith(u8, line, "** ")) line[3..] else if (std.mem.startsWith(u8, line, "**")) line[2..] else line;
        try result.writer.print("{s}\n", .{body});
    }
    const notice = std.mem.trim(u8, result.written(), " \r\n\t");
    if (std.mem.indexOf(u8, notice, "The author disclaims copyright") == null) return error.InvalidLicense;
    return std.fmt.allocPrint(c.a, "{s}\n", .{notice});
}

fn verifySqlite(c: Context, path: []const u8, lock_path: []const u8) !Value {
    const lock = try c.json(lock_path);
    try equal(try text(lock, "format"), "agent-native-dependencies/v1");
    const sqlite = try field(lock, "sqlite");
    try equal(try text(sqlite, "license"), "public-domain");
    const inventory = try Inventory.load(c, path, 4);
    if (inventory.files.items.len != 3) return error.InvalidInventory;
    const files = try field(sqlite, "files");
    if (files != .object or files.object.count() != 2) return error.InvalidMetadata;
    inline for (.{ "sqlite3.c", "sqlite3.h" }) |name| {
        const bytes = try c.read(try c.join(&.{ path, name }), 16 * 1024 * 1024);
        defer c.a.free(bytes);
        const expected = try field(files, name);
        if (bytes.len != try number(try field(expected, "bytes"))) return error.IdentityMismatch;
        try equal(try c.digest(bytes), try text(expected, "sha256"));
        if (comptime std.mem.eql(u8, name, "sqlite3.c")) {
            var hash: [32]u8 = undefined;
            sha3(bytes, &hash);
            try equal(&std.fmt.bytesToHex(hash, .lower), try text(sqlite, "amalgamationSha3_256"));
        } else {
            const license = try c.read(try c.join(&.{ path, "LICENSE" }), 65536);
            defer c.a.free(license);
            try equal(license, try sqliteLicense(c, bytes));
            if (std.mem.indexOf(u8, bytes, try text(sqlite, "version")) == null or std.mem.indexOf(u8, bytes, try text(sqlite, "sourceId")) == null) return error.IdentityMismatch;
        }
    }
    return c.value(.{ .version = try text(sqlite, "version"), .sourceId = try text(sqlite, "sourceId"), .lockSha256 = try c.fileDigest(lock_path), .files = files });
}

fn manifest(c: Context, args: []const []const u8) !void {
    if (args.len != 17) return error.ExpectedManifestArguments;
    const compiler_digest = try c.fileDigest(args[15]);
    const image = try c.read(args[0], 16 * 1024 * 1024);
    // Embedded application assets have the native discovery owner's 16 MiB
    // extent, including up to 8 MiB of base64-encoded frozen resources.
    const application_bytes = try c.read(args[1], 16 * 1024 * 1024);
    const application = try std.json.parseFromSliceLeaky(Value, c.a, application_bytes, .{});
    const lock = try lockAt(c, args[2]);
    try equal(try text(application, "program_sha256"), try c.digest(image));
    const mapping = try text(application, "client_mapping");
    if (!std.mem.eql(u8, mapping, "agent-client-values/1.0") and !std.mem.eql(u8, mapping, "agent-client-values/1.1")) return error.InvalidMetadata;
    var sqlite = try verifySqlite(c, args[6], args[14]);
    const heap = try std.fmt.parseInt(u64, args[7], 10);
    const state = try std.fmt.parseInt(u64, args[9], 10);
    if (heap == 0 or heap > 16 * 1024 * 1024 or state <= 1024 * 1024 or state > 256 * 1024 * 1024 or state % 4096 != 0) return error.Capacity;
    if (!std.mem.startsWith(u8, args[10], "agent-native-state/") or try std.fmt.parseInt(u32, args[10][19..], 10) == 0) return error.InvalidMetadata;
    try c.put(&sqlite, "heap_bytes", heap);
    const flags = try std.json.parseFromSliceLeaky(Value, c.a, args[8], .{});
    if (flags != .array) return error.InvalidMetadata;
    try sqlite.object.put(c.a, "compile_flags", flags);
    const library_path = try Dir.cwd().realPathFileAlloc(c.io, args[16], c.a);
    const library = try Inventory.load(c, library_path, 100000);
    var licenses: std.ArrayList(Value) = .empty;
    inline for (.{ "Protean", "Kronos", "Horos" }, 3..) |component, index| {
        try licenses.append(c.a, try c.value(.{ .component = component, .text = try c.read(args[index], 1024 * 1024) }));
    }
    const exe_dir = std.fs.path.dirname(args[15]) orelse return error.InvalidPath;
    var zig_license: ?[]const u8 = null;
    for ([_][]const u8{ try c.join(&.{ exe_dir, "LICENSE" }), try c.join(&.{ exe_dir, "../LICENSE" }), try c.join(&.{ library_path, "../LICENSE" }), try c.join(&.{ library_path, "../../LICENSE" }) }) |path| {
        const bytes = c.read(path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (std.mem.indexOf(u8, bytes, "Copyright (c) Zig contributors") != null) {
            zig_license = bytes;
            break;
        }
    }
    try licenses.append(c.a, try c.value(.{ .component = "Zig standard library", .text = zig_license orelse return error.InvalidLicense }));
    try licenses.append(c.a, try c.value(.{ .component = "SQLite", .text = try c.read(try c.join(&.{ args[6], "LICENSE" }), 65536) }));
    const linux = std.mem.indexOf(u8, args[11], "linux") != null;
    if (linux) try licenses.append(c.a, try c.value(.{ .component = "musl libc", .text = try c.read(try c.join(&.{ library_path, "libc/musl/COPYRIGHT" }), 1024 * 1024) }));
    const result = .{
        .format = "agent-native-build/v1",
        .application_id = try text(application, "application_id"),
        .application_version = try text(application, "application_version"),
        .native_host_contract = "agent-native-host/1.0",
        .protocol = "agent-host/1.0",
        .client_mapping = mapping,
        .state_format = args[10],
        .state_database_bytes = state,
        .target = args[11],
        .optimize = args[12],
        .program_sha256 = try c.digest(image),
        .program_identity = try text(application, "program_identity"),
        .application_assets_sha256 = try c.digest(application_bytes),
        .dependencies = .{ .world = try text(try field(lock, "world"), "commit"), .boundary = try text(try field(lock, "boundary"), "commit"), .dependency_lock_sha256 = try c.fileDigest(args[2]), .sqlite = sqlite },
        .compiler = .{ .version = @import("builtin").zig_version_string, .executable_sha256 = compiler_digest, .library_inventory_sha256 = try library.libraryIdentity(c), .library_entries = library.files.items.len, .library_bytes = library.bytes },
        .runtime_dependencies = if (linux) @as([]const []const u8, &.{ "Linux kernel", "procfs executing artifact handle", "OS trust roots for HTTPS" }) else @as([]const []const u8, &.{ "macOS system libSystem", "readable executing artifact", "OS trust roots for HTTPS" }),
        .binary_identity = "Final executable SHA-256 is recorded externally; this manifest does not authenticate itself.",
        .signing = "unsigned or toolchain ad-hoc; no release signing or notarization claimed",
        .licenses = licenses.items,
    };
    try equal(compiler_digest, try c.fileDigest(args[15]));
    try equal(try library.identity(c), try (try Inventory.load(c, library_path, 100000)).identity(c));
    try Dir.cwd().writeFile(c.io, .{ .sub_path = args[13], .data = try c.encode(result) });
}

fn exists(c: Context, path: []const u8) !bool {
    _ = Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn command(c: Context, argv: []const []const u8, limit: usize) ![]const u8 {
    var environ = if (c.environ) |value| try value.clone(c.a) else std.process.Environ.Map.init(c.a);
    defer environ.deinit();
    _ = environ.swapRemove("TAR_OPTIONS");
    _ = environ.swapRemove("UNZIP");
    _ = environ.swapRemove("UNZIPOPT");
    _ = environ.swapRemove("ZIPINFO");
    _ = environ.swapRemove("ZIPINFOOPT");
    try environ.put("LC_ALL", "C");
    try environ.put("TZ", "UTC");
    const result = try std.process.run(c.a, c.io, .{ .argv = argv, .environ_map = &environ, .stdout_limit = .limited(limit), .stderr_limit = .limited(65536), .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } } });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}: {s}\n", .{ argv[0], result.stderr });
        return error.CommandFailed;
    }
    return result.stdout;
}

fn download(c: Context, first_url: []const u8, length: usize) anyerror![]u8 {
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    var url = first_url;
    for (0..4) |_| {
        if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
        var request = try client.request(.GET, try std.Uri.parse(url), .{ .redirect_behavior = .unhandled, .keep_alive = false });
        defer request.deinit();
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        if (response.head.status.class() == .redirect) {
            url = try c.a.dupe(u8, response.head.location orelse return error.InvalidDownload);
            continue;
        }
        if (response.head.status != .ok) return error.InvalidDownload;
        const bytes = try response.reader(&.{}).allocRemaining(c.a, .limited(length));
        if (bytes.len != length) return error.InvalidDownload;
        return bytes;
    }
    return error.TooManyRedirects;
}

fn downloadDeadline(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(120), .awake);
}

fn boundedDownload(c: Context, url: []const u8, length: usize) ![]u8 {
    const Event = union(enum) { response: anyerror![]u8, timer: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(c.io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.timer, downloadDeadline, .{c.io});
    try select.concurrent(.response, download, .{ c, url, length });
    return switch (try select.await()) {
        .response => |result| result,
        .timer => error.DownloadTimeout,
    };
}

fn archiveAt(c: Context, path: []const u8, expected: Value, offline: bool) ![]const u8 {
    const length = try number(try field(expected, "bytes"));
    if (length > 128 * 1024 * 1024) return error.Capacity;
    if (try exists(c, path)) {
        const bytes = try c.read(path, @intCast(length));
        if (bytes.len != length) return error.IdentityMismatch;
        try equal(try c.digest(bytes), try text(expected, "sha256"));
        return bytes;
    }
    if (offline) return error.MissingOfflineArchive;
    const url = try text(expected, "url");
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    const bytes = try boundedDownload(c, url, @intCast(length));
    try equal(try c.digest(bytes), try text(expected, "sha256"));
    var file = try Dir.cwd().createFile(c.io, path, .{ .exclusive = true });
    defer file.close(c.io);
    try file.writeStreamingAll(c.io, bytes);
    return bytes;
}

fn stageDirectory(c: Context, parent: []const u8) ![]const u8 {
    var random: [16]u8 = undefined;
    c.io.random(&random);
    const path = try c.join(&.{ parent, try std.fmt.allocPrint(c.a, ".stage-{s}", .{std.fmt.bytesToHex(random, .lower)}) });
    try Dir.cwd().createDir(c.io, path, .fromMode(0o700));
    return path;
}

fn extractionSnapshot(c: Context, stage: []const u8, bytes: []const u8) ![]const u8 {
    const path = try c.join(&.{ stage, "archive" });
    var file = try Dir.cwd().createFile(c.io, path, .{ .exclusive = true });
    defer file.close(c.io);
    try file.writeStreamingAll(c.io, bytes);
    try file.setPermissions(c.io, .fromMode(0o400));
    return path;
}

fn sourceAt(c: Context, parent: []const u8, name: []const u8, item: Value, offline: bool) ![]const u8 {
    const destination = try c.join(&.{ parent, name });
    if (try exists(c, destination)) {
        try verifySource(c, destination, item, false);
        return destination;
    }
    const transport = try c.join(&.{ parent, try std.fmt.allocPrint(c.a, "{s}-{s}.tar.gz", .{ name, try text(item, "commit") }) });
    const bytes = try archiveAt(c, transport, try field(item, "archive"), offline);
    const stage = try stageDirectory(c, parent);
    defer Dir.cwd().deleteTree(c.io, stage) catch {};
    const archive = try extractionSnapshot(c, stage, bytes);
    // Only the captured authenticated bytes reach the trusted extractor.
    // Validate its paths and kinds before extraction; no links or special files.
    const names = try command(c, &.{ "tar", "-tzf", archive }, 4 * 1024 * 1024);
    const prefix = try std.fmt.allocPrint(c.a, "{s}-{s}", .{ name, try text(item, "commit") });
    var lines = std.mem.tokenizeScalar(u8, names, '\n');
    var count: usize = 0;
    var seen: std.StringHashMap(void) = .init(c.a);
    while (lines.next()) |line| {
        const path = std.mem.trimEnd(u8, line, "/");
        count += 1;
        if (count > 10000 or std.mem.indexOfAny(u8, path, "\\\x00\r") != null or seen.contains(path)) return error.InvalidArchive;
        try seen.put(path, {});
        var parts = std.mem.splitScalar(u8, path, '/');
        try equal(parts.next() orelse return error.InvalidArchive, prefix);
        var depth: usize = 0;
        while (parts.next()) |part| {
            depth += 1;
            if (depth > 32 or part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArchive;
        }
    }
    const details = try command(c, &.{ "tar", "-tvzf", archive }, 4 * 1024 * 1024);
    lines = std.mem.tokenizeScalar(u8, details, '\n');
    var detail_count: usize = 0;
    while (lines.next()) |line| {
        detail_count += 1;
        if (line[0] != 'd' and line[0] != '-') return error.InvalidArchive;
    }
    if (count != detail_count) return error.InvalidArchive;
    const source = try c.join(&.{ stage, "source" });
    try Dir.cwd().createDir(c.io, source, .default_dir);
    _ = try command(c, &.{ "tar", "-xzf", archive, "--strip-components=1", "--no-same-owner", "-C", source }, 65536);
    // Archive transports may vary permission bits through the caller's umask.
    // Normalize to the locked source profile before checking its entire tree.
    const inventory = try Inventory.load(c, source, 10000);
    for (inventory.files.items) |row| {
        const path = try c.join(&.{ source, try text(row, "path") });
        const directory = std.mem.eql(u8, try text(row, "kind"), "directory");
        const executable = (try number(try field(row, "mode"))) & 0o111 != 0;
        if (directory) {
            // Linux path-only directory handles cannot service fchmod.
            var dir = try Dir.cwd().openDir(c.io, path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(c.io);
            try dir.setPermissions(c.io, .fromMode(0o755));
        } else {
            var file = try Dir.cwd().openFile(c.io, path, .{ .follow_symlinks = false });
            defer file.close(c.io);
            try file.setPermissions(c.io, .fromMode(if (executable) 0o755 else 0o644));
        }
    }
    try verifySource(c, source, item, false);
    try Dir.cwd().renamePreserve(source, .cwd(), destination, c.io);
    return destination;
}

fn sqliteAt(c: Context, parent: []const u8, lock_path: []const u8, offline: bool) !void {
    const destination = try c.join(&.{ parent, "sqlite" });
    if (try exists(c, destination)) {
        _ = try verifySqlite(c, destination, lock_path);
        return;
    }
    const selected = try field(try c.json(lock_path), "sqlite");
    const expected = try field(selected, "archive");
    const transport = try c.join(&.{ parent, try std.fmt.allocPrint(c.a, "{s}.zip", .{try text(expected, "root")}) });
    const archive_bytes = try archiveAt(c, transport, expected, offline);
    var hash: [32]u8 = undefined;
    sha3(archive_bytes, &hash);
    try equal(&std.fmt.bytesToHex(hash, .lower), try text(expected, "sha3_256"));
    const stage = try stageDirectory(c, parent);
    defer Dir.cwd().deleteTree(c.io, stage) catch {};
    const archive = try extractionSnapshot(c, stage, archive_bytes);
    const source = try c.join(&.{ stage, "source" });
    try Dir.cwd().createDir(c.io, source, .default_dir);
    inline for (.{ "sqlite3.c", "sqlite3.h" }) |name| {
        const bytes = try command(c, &.{ "unzip", "-p", archive, try c.join(&.{ try text(expected, "root"), name }) }, 16 * 1024 * 1024);
        try Dir.cwd().writeFile(c.io, .{ .sub_path = try c.join(&.{ source, name }), .data = bytes });
        if (comptime std.mem.eql(u8, name, "sqlite3.h")) try Dir.cwd().writeFile(c.io, .{ .sub_path = try c.join(&.{ source, "LICENSE" }), .data = try sqliteLicense(c, bytes) });
    }
    _ = try verifySqlite(c, source, lock_path);
    try Dir.cwd().renamePreserve(source, .cwd(), destination, c.io);
}

fn setup(c: Context, args: []const []const u8) !void {
    if (args.len < 4 or args.len > 6) return error.ExpectedSetupLockNativeLockDestinationZig;
    var offline = false;
    var authoring_only = false;
    for (args[4..]) |arg| {
        if (std.mem.eql(u8, arg, "--offline") and !offline) {
            offline = true;
        } else if (std.mem.eql(u8, arg, "--authoring-only") and !authoring_only) {
            authoring_only = true;
        } else return error.UnexpectedArgument;
    }
    const lock = try lockAt(c, args[0]);
    try equal(std.mem.trim(u8, try command(c, &.{ args[3], "version" }, 1024), "\r\n "), "0.17.0");
    try Dir.cwd().createDirPath(c.io, args[2]);
    const horos = try sourceAt(c, args[2], "horos", try field(lock, "boundary"), offline);
    if (!authoring_only) {
        _ = try sourceAt(c, args[2], "kronos", try field(lock, "world"), offline);
        try sqliteAt(c, args[2], args[1], offline);
    }
    // Seed Zig's normal package cache from an already authenticated source.
    // The public downstream module graph can then use its ordinary pinned package.
    const package_hash = try command(c, &.{ args[3], "fetch", horos }, 65536);
    try equal(std.mem.trim(u8, package_hash, "\r\n "), try text(try field(try field(lock, "boundary"), "package"), "zigHash"));
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .scratch = init.gpa, .io = init.io, .environ = init.environ_map };
    var iterator = init.minimal.args.iterate();
    _ = iterator.next();
    const operation = iterator.next() orelse return error.ExpectedCommand;
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(c.a, arg);
    if (std.mem.eql(u8, operation, "setup")) return setup(c, args.items);
    if (std.mem.eql(u8, operation, "manifest")) return manifest(c, args.items);
    if (std.mem.eql(u8, operation, "verify-horos")) {
        if (args.items.len != 3) return error.ExpectedVerificationArguments;
        const lock = try lockAt(c, args.items[0]);
        const package = std.mem.eql(u8, args.items[2], "package");
        if (!package) try equal(args.items[2], "source");
        return verifySource(c, args.items[1], try field(lock, "boundary"), package);
    }
    if (std.mem.eql(u8, operation, "verify-native")) {
        if (args.items.len != 4) return error.ExpectedVerificationArguments;
        const lock = try lockAt(c, args.items[0]);
        try verifySource(c, args.items[1], try field(lock, "world"), false);
        _ = try verifySqlite(c, args.items[2], args.items[3]);
        return;
    }
    return error.UnknownCommand;
}

test "source admission binds exact names bytes modes and complete inventory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .scratch = std.testing.allocator, .io = std.testing.io };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(c.io, ".", c.a);
    try temporary.dir.writeFile(c.io, .{ .sub_path = "a", .data = "a" });
    var file = try temporary.dir.openFile(c.io, "a", .{});
    try file.setPermissions(c.io, .fromMode(0o644));
    file.close(c.io);
    const inventory = try Inventory.load(c, path, 2);
    const canonical = "[{\"path\":\"a\",\"kind\":\"file\",\"mode\":420,\"bytes\":1,\"sha256\":\"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb\"}]";
    try std.testing.expectEqualStrings(canonical, try c.encode(inventory.files.items));
    const expected = try c.value(.{ .inventorySha256 = try c.digest(canonical), .entries = 1, .bytes = 1 });
    try inventory.verify(c, expected);
    try temporary.dir.writeFile(c.io, .{ .sub_path = "a", .data = "b" });
    try std.testing.expectError(error.IdentityMismatch, (try Inventory.load(c, path, 2)).verify(c, expected));
    try temporary.dir.writeFile(c.io, .{ .sub_path = "a", .data = "a" });
    file = try temporary.dir.openFile(c.io, "a", .{});
    try file.setPermissions(c.io, .fromMode(0o755));
    file.close(c.io);
    try std.testing.expectError(error.IdentityMismatch, (try Inventory.load(c, path, 2)).verify(c, expected));
    try temporary.dir.writeFile(c.io, .{ .sub_path = "extra", .data = "" });
    try std.testing.expectError(error.Capacity, Inventory.load(c, path, 1));
}

test "source and archive admission reject links and corrupt offline transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .scratch = std.testing.allocator, .io = std.testing.io };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(c.io, ".", c.a);
    try temporary.dir.writeFile(c.io, .{ .sub_path = "archive", .data = "a" });
    const archive = try c.join(&.{ path, "archive" });
    const expected = try c.value(.{ .bytes = 1, .sha256 = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb" });
    _ = try archiveAt(c, archive, expected, true);
    try temporary.dir.writeFile(c.io, .{ .sub_path = "archive", .data = "b" });
    try std.testing.expectError(error.IdentityMismatch, archiveAt(c, archive, expected, true));
    try std.testing.expectError(error.MissingOfflineArchive, archiveAt(c, try c.join(&.{ path, "missing" }), expected, true));
    try temporary.dir.symLink(c.io, "archive", "link", .{});
    try std.testing.expectError(error.InvalidFile, Inventory.load(c, path, 4));
}

test "native source lock cannot silently reinterpret the former delivery format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .scratch = std.testing.allocator, .io = std.testing.io };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(c.io, ".", c.a);
    try temporary.dir.writeFile(c.io, .{ .sub_path = "lock.json", .data = "{\"format\":\"agent4-dependency-lock/v1\",\"status\":\"released-integration\"}" });
    try std.testing.expectError(error.IdentityMismatch, lockAt(c, try c.join(&.{ path, "lock.json" })));
}
