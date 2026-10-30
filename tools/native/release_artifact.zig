const std = @import("std");
const native = @import("dependencies.zig");
const source = @import("release_source.zig");
const edit = @import("release_edit.zig");
const Context = native.Context;
const Dir = std.Io.Dir;
const Value = std.json.Value;
const text = native.text;
const field = native.field;
const equal = native.equal;
const lock_path = "conformance/protean/dependencies.lock.json";

const Facts = struct {
    manifest: struct {
        sha256: []const u8,
        version: []const u8,
        minimumCompiler: []const u8,
        horos: struct { url: []const u8, commit: []const u8, packageIdentity: []const u8 },
    },
    lockSha256: []const u8,
    nativeLockSha256: []const u8,
    dependencies: struct {
        horos: struct { commit: []const u8, tree: []const u8, packageIdentity: []const u8 },
        kosmos: struct { commit: []const u8, tree: []const u8 },
    },
};

fn facts(c: Context, root: []const u8) !Facts {
    const bytes = try c.read(try c.join(&.{ root, "build.zig.zon" }), 1024 * 1024);
    const manifest = try edit.manifest(c.a, try c.a.dupeSentinel(u8, bytes, 0));
    const lock = try native.lockAt(c, try c.join(&.{ root, lock_path }));
    const horos = try field(lock, "boundary");
    const kosmos = try field(lock, "world");
    const horos_commit = try text(horos, "commit");
    const horos_tree = try text(horos, "gitTree");
    const kosmos_commit = try text(kosmos, "commit");
    const kosmos_tree = try text(kosmos, "gitTree");
    const package_identity = try text(try field(horos, "package"), "zigHash");
    try equal(try edit.commit(manifest.dependencies.horos.url), horos_commit);
    try equal(manifest.dependencies.horos.hash, package_identity);
    for ([_][]const u8{ horos_commit, horos_tree, kosmos_commit, kosmos_tree }) |oid|
        try edit.hex(oid, 40);
    return .{
        .manifest = .{
            .sha256 = try c.digest(bytes),
            .version = manifest.version,
            .minimumCompiler = manifest.minimum_zig_version,
            .horos = .{
                .url = manifest.dependencies.horos.url,
                .commit = horos_commit,
                .packageIdentity = package_identity,
            },
        },
        .lockSha256 = try c.fileDigest(try c.join(&.{ root, lock_path })),
        .nativeLockSha256 = try c.fileDigest(try c.join(&.{
            root, "conformance/protean/native-dependencies.lock.json",
        })),
        .dependencies = .{
            .horos = .{
                .commit = horos_commit,
                .tree = horos_tree,
                .packageIdentity = package_identity,
            },
            .kosmos = .{ .commit = kosmos_commit, .tree = kosmos_tree },
        },
    };
}

pub fn describe(c: Context, args: []const []const u8) !void {
    if (args.len != 1) return error.ExpectedSourceRoot;
    try std.Io.File.stdout().writeStreamingAll(c.io, try c.encode(try facts(c, args[0])));
}

pub fn manifestVersion(c: Context, args: []const []const u8) !void {
    if (args.len != 1) return error.ExpectedManifestPath;
    const bytes = try c.read(args[0], 1024 * 1024);
    const header = try edit.header(c.a, try c.a.dupeSentinel(u8, bytes, 0));
    try std.Io.File.stdout().writeStreamingAll(c.io, try c.encode(.{
        .version = header.version,
        .minimumCompiler = header.minimum_zig_version,
        .sha256 = try c.digest(bytes),
    }));
}

fn clean(c: Context, root: []const u8, expected: ?[]const u8) ![]const u8 {
    const r = @import("refresh.zig").runner(c);
    const result = try r.run(&.{ "git", "rev-parse", "HEAD" }, root, true);
    const commit = std.mem.trim(u8, result.stdout, "\r\n");
    try edit.hex(commit, 40);
    if (expected) |value| try equal(commit, std.mem.trim(u8, value, "\r\n"));
    const status = try r.run(&.{
        "git", "status", "--porcelain", "--untracked-files=all",
    }, root, true);
    try equal(status.stdout, "");
    return commit;
}

fn packageIdentity(c: Context, root: []const u8, version: []const u8, zig: []const u8) ![]const u8 {
    const compiler = try native.command(c, &.{ zig, "version" }, 1024);
    try equal(std.mem.trim(u8, compiler, "\r\n"), "0.17.0");
    const fetched = try native.command(c, &.{ zig, "fetch", root }, 65536);
    const package = std.mem.trim(u8, fetched, "\r\n");
    const prefix = try std.fmt.allocPrint(c.a, "protean-{s}-", .{version});
    if (!std.mem.startsWith(u8, package, prefix) or package.len != prefix.len + 44)
        return error.InvalidPackageIdentity;
    for (package[prefix.len..]) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '_' and byte != '-') return error.InvalidPackageIdentity;
    return package;
}

const Compiler = struct {
    sha256: []const u8,
    platform: []const u8,

    fn observe(c: Context, zig: []const u8) !Compiler {
        return .{
            .sha256 = try source.compilerSha256(@import("refresh.zig").runner(c), zig),
            .platform = source.compilerPlatform(),
        };
    }
    fn declared(record: Value) !Compiler {
        const hash = try text(record, "compilerSha256");
        try edit.hex(hash, 64);
        const platform = try text(record, "compilerPlatform");
        if (platform.len == 0 or platform.len > 64 or
            std.mem.indexOfScalar(u8, platform, '-') == null) return error.InvalidCompilerPlatform;
        for (platform) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidCompilerPlatform;
        return .{ .sha256 = hash, .platform = platform };
    }
};

fn receipt(c: Context, snapshot: source.Snapshot, zig: []const u8, compiler: Compiler) ![]const u8 {
    const observed = try facts(c, snapshot.source);
    const package = try packageIdentity(c, snapshot.source, observed.manifest.version, zig);
    return c.encode(.{
        .commit = snapshot.commit,
        .tree = snapshot.tree,
        .archive = "source.tar",
        .sha256 = snapshot.sha256,
        .size = snapshot.size,
        .packageIdentity = package,
        .files = snapshot.files,
        .compiler = "0.17.0",
        .compilerSha256 = compiler.sha256,
        .compilerPlatform = compiler.platform,
        .manifest = observed.manifest,
        .lockSha256 = observed.lockSha256,
        .nativeLockSha256 = observed.nativeLockSha256,
        .dependencies = observed.dependencies,
    });
}

fn verifyRetained(c: Context, path: []const u8, bytes: []const u8) !void {
    const actual = source.readArchive(@import("refresh.zig").runner(c), path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    try equal(actual, bytes);
}

pub fn prepare(c: Context, args: []const []const u8, build_owned: bool) !void {
    if (args.len < 3 or args.len > 4) return error.ExpectedRootOutputZigCommit;
    if (!std.fs.path.isAbsolute(args[1]) or !std.fs.path.isAbsolute(args[2]))
        return error.ExpectedAbsolutePath;
    const r = @import("refresh.zig").runner(c);
    const owner = try source.BuildOutput.acquire(r, args[1]);
    defer owner.close(c.io);
    const commit = try clean(c, args[0], if (args.len == 4) args[3] else null);
    const parent = std.fs.path.dirname(args[1]) orelse return error.ExpectedAbsolutePath;
    const stage = try native.stageDirectory(c, parent);
    defer Dir.cwd().deleteTree(c.io, stage) catch |err|
        std.log.err("source staging cleanup failed: {s}", .{@errorName(err)});
    const snapshot = try source.prepare(r, args[0], stage);
    try equal(snapshot.commit, commit);
    var compiler = try source.CapturedCompiler.acquire(r, args[2], stage, c.environ);
    defer compiler.close(c.io);
    var selected = c;
    selected.environ = &compiler.env;
    const record = try receipt(selected, snapshot, compiler.path, .{
        .sha256 = compiler.sha256,
        .platform = source.compilerPlatform(),
    });
    const archive = try source.testedArchive(r, snapshot);
    _ = try clean(c, args[0], commit);
    if (build_owned) return owner.retain(c.io, archive, record);
    try Dir.cwd().createDirPath(c.io, args[1]);
    const archive_path = try c.join(&.{ args[1], "source.tar" });
    const record_path = try c.join(&.{ args[1], "source.json" });
    try verifyRetained(c, archive_path, archive);
    try verifyRetained(c, record_path, record);
    _ = try source.retain(r, archive_path, archive);
    _ = try source.retain(r, record_path, record);
}

fn admit(c: Context, args: []const []const u8) ![]const u8 {
    if (args.len != 5) return error.ExpectedRootArchiveReceiptOutputZig;
    if (!std.fs.path.isAbsolute(args[3]) or !std.fs.path.isAbsolute(args[4]))
        return error.ExpectedAbsolutePath;
    const bytes = source.readBounded(@import("refresh.zig").runner(c), args[2], 4 << 20) catch |err|
        switch (err) {
            error.InvalidSourceArchive => return error.InvalidFile,
            error.SourceChanged => return error.InputChanged,
            else => return err,
        };
    const record = try std.json.parseFromSliceLeaky(Value, c.a, bytes, .{});
    const commit = try clean(c, args[0], try text(record, "commit"));
    const snapshot = try source.verify(
        @import("refresh.zig").runner(c),
        args[0],
        commit,
        try text(record, "tree"),
        args[1],
        args[3],
    );
    errdefer Dir.cwd().deleteTree(c.io, args[3]) catch |err|
        std.log.err("rejected source cleanup failed: {s}", .{@errorName(err)});
    const parent = std.fs.path.dirname(args[3]) orelse return error.ExpectedAbsolutePath;
    const stage = try native.stageDirectory(c, parent);
    defer Dir.cwd().deleteTree(c.io, stage) catch |err|
        std.log.err("compiler staging cleanup failed: {s}", .{@errorName(err)});
    var compiler = try source.CapturedCompiler.acquire(
        @import("refresh.zig").runner(c),
        args[4],
        stage,
        c.environ,
    );
    defer compiler.close(c.io);
    var selected = c;
    selected.environ = &compiler.env;
    const actual = try receipt(selected, snapshot, compiler.path, try Compiler.declared(record));
    try equal(bytes, actual);
    _ = try clean(c, args[0], commit);
    return actual;
}

pub fn verify(c: Context, args: []const []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(c.io, try admit(c, args));
}

fn fixtureWrite(c: Context, root: []const u8, path: []const u8, bytes: []const u8) !void {
    const absolute = try c.join(&.{ root, path });
    if (std.fs.path.dirname(absolute)) |parent| try Dir.cwd().createDirPath(c.io, parent);
    try Dir.cwd().writeFile(c.io, .{ .sub_path = absolute, .data = bytes });
}

fn fixtureCommit(c: Context, root: []const u8) !void {
    const r = @import("refresh.zig").runner(c);
    _ = try r.run(&.{ "git", "init", "--quiet" }, root, true);
    _ = try r.run(&.{ "git", "add", "--force", "." }, root, true);
    _ = try r.run(&.{
        "git",                                "-c", "user.name=Fixture",    "-c",
        "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit",
        "--quiet",                            "-m", "fixture",
    }, root, true);
}

fn fixture(c: Context, root: []const u8) !struct { base: []const u8, zig: []const u8 } {
    const base = try c.join(&.{ root, "base" });
    const horos = "1111111111111111111111111111111111111111";
    const kosmos = "2222222222222222222222222222222222222222";
    const hash = "horos-8.0.0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try fixtureWrite(c, base, "build.zig.zon", try std.fmt.allocPrint(c.a,
        \\.{{ .name = .protean, .fingerprint = 0x50216bba84371874, .version = "8.0.0",
        \\.minimum_zig_version = "0.17.0", .paths = .{{"build.zig.zon","src","conformance"}},
        \\.dependencies = .{{.horos = .{{.url = "git+https://github.com/tkersey/horos#{s}",
        \\.hash = "{s}"}}}} }}
    , .{ horos, hash }));
    try fixtureWrite(c, base, "src/root.zig", "pub const version = 1;\n");
    const lock = try c.encode(.{
        .format = "agent-native-source-lock/v2",
        .status = "development-integration",
        .boundary = .{
            .repository = "tkersey/horos",
            .commit = horos,
            .gitTree = horos,
            .archive = .{
                .url = "https://github.com/tkersey/horos/archive/" ++ horos ++ ".tar.gz",
            },
            .package = .{ .zigHash = hash },
        },
        .world = .{
            .repository = "tkersey/kosmos",
            .commit = kosmos,
            .gitTree = kosmos,
            .archive = .{
                .url = "https://github.com/tkersey/kosmos/archive/" ++ kosmos ++ ".tar.gz",
            },
        },
    });
    try fixtureWrite(c, base, lock_path, lock);
    try fixtureWrite(c, base, "conformance/protean/native-dependencies.lock.json", "{}\n");
    try fixtureCommit(c, base);
    return .{
        .base = base,
        .zig = std.mem.trim(u8, try native.command(c, &.{ "which", "zig" }, 65536), "\r\n "),
    };
}

test "final source receipt binds native manifest lock and exact compiler package identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = try std.testing.environ.createMap(arena.allocator());
    const c: Context = .{
        .a = arena.allocator(),
        .scratch = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(c.io, ".", c.a);
    const f = try fixture(c, root);
    const output = try c.join(&.{ root, "output" });
    try prepare(c, &.{ f.base, output, f.zig }, false);
    try prepare(c, &.{ f.base, output, f.zig }, false);
    const receipt_path = try c.join(&.{ output, "source.json" });
    const archive = try c.join(&.{ output, "source.tar" });
    const original = try c.read(receipt_path, 4 << 20);
    const record = try c.json(receipt_path);
    const lock_digest = try c.fileDigest(try c.join(&.{ f.base, lock_path }));
    try equal(try text(record, "lockSha256"), lock_digest);
    try equal(try text(record, "compiler"), "0.17.0");
    const compiler = try Compiler.observe(c, f.zig);
    try equal(try text(record, "compilerSha256"), compiler.sha256);
    try equal(try text(record, "compilerPlatform"), compiler.platform);
    try equal(try text(try field(record, "manifest"), "version"), "8.0.0");
    const extracted = try c.join(&.{ root, "consumed" });
    try equal(original, try admit(c, &.{ f.base, archive, receipt_path, extracted, f.zig }));
    var cross_platform = try c.value(record);
    try c.put(
        &cross_platform,
        "compilerSha256",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    try c.put(&cross_platform, "compilerPlatform", "linux-x86_64");
    const cross_bytes = try c.encode(cross_platform);
    try fixtureWrite(c, output, "source.json", cross_bytes);
    try equal(cross_bytes, try admit(c, &.{
        f.base, archive, receipt_path, try c.join(&.{ root, "cross-platform" }), f.zig,
    }));
    try fixtureWrite(c, output, "source.json", try std.mem.concat(c.a, u8, &.{ original, "\n" }));
    const rejected = try c.join(&.{ root, "rejected" });
    try std.testing.expectError(error.IdentityMismatch, admit(c, &.{
        f.base, archive, receipt_path, rejected, f.zig,
    }));
    try std.testing.expect(!try native.exists(c, rejected));
}

test "build source replaces changed heads while immutable output preserves accepted bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = try std.testing.environ.createMap(arena.allocator());
    const c: Context = .{
        .a = arena.allocator(),
        .scratch = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(c.io, ".", c.a);
    const f = try fixture(c, root);
    const output = try c.join(&.{ root, "output" });
    try prepare(c, &.{ f.base, output, f.zig }, false);
    const path = try c.join(&.{ output, "source.tar" });
    const previous = try c.fileDigest(path);
    const old_commit = try clean(c, f.base, null);
    try fixtureWrite(c, f.base, "src/root.zig", "pub const version = 2;\n");
    try std.testing.expectError(error.IdentityMismatch, prepare(c, &.{
        f.base, output, f.zig,
    }, true));
    try equal(previous, try c.fileDigest(path));
    try fixtureCommit(c, f.base);
    try std.testing.expectError(error.IdentityMismatch, prepare(c, &.{
        f.base, output, f.zig,
    }, false));
    try equal(previous, try c.fileDigest(path));
    try prepare(c, &.{ f.base, output, f.zig }, true);
    try std.testing.expect(!std.mem.eql(u8, previous, try c.fileDigest(path)));
    const accepted = try c.fileDigest(path);
    try std.testing.expectError(error.IdentityMismatch, prepare(c, &.{
        f.base, output, f.zig, old_commit,
    }, true));
    try equal(accepted, try c.fileDigest(path));
}

test "external receipt FIFOs and oversized files fail before source admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{
        .a = arena.allocator(),
        .scratch = std.testing.allocator,
        .io = std.testing.io,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(c.io, ".", c.a);
    const receipt_path = try c.join(&.{ root, "receipt" });
    const output = try c.join(&.{ root, "output" });
    _ = try native.command(c, &.{ "mkfifo", receipt_path }, 1024);
    try std.testing.expectError(error.InvalidFile, admit(c, &.{
        root, "unused-archive", receipt_path, output, "/unused-compiler",
    }));
    try Dir.cwd().deleteFile(c.io, receipt_path);
    var file = try Dir.cwd().createFile(c.io, receipt_path, .{ .exclusive = true });
    defer file.close(c.io);
    try file.setLength(c.io, (4 << 20) + 1);
    try std.testing.expectError(error.InvalidFile, admit(c, &.{
        root, "unused-archive", receipt_path, output, "/unused-compiler",
    }));
    try std.testing.expect(!try native.exists(c, output));
}
