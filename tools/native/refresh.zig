const std = @import("std");
const builtin = @import("builtin");
const native = @import("dependencies.zig");
const source = @import("release_source.zig");
const edit = @import("release_edit.zig");
const Dir = std.Io.Dir;
const Value = std.json.Value;
const Context = native.Context;
const Inventory = native.Inventory;
const text = native.text;
const field = native.field;
const number = native.number;
const equal = native.equal;
const lock_path = "conformance/protean/dependencies.lock.json";

comptime {
    _ = source;
    _ = @import("release_artifact.zig");
}

const Input = struct {
    schema: []const u8,
    baseCommit: []const u8,
    baseTree: []const u8,
    version: []const u8,
    kosmos: struct { record: []const u8, archive: []const u8, repository: []const u8 },
    upstreamDirectory: []const u8,
};

const Runner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    c: Context,

    pub fn run(
        r: Runner,
        argv: []const []const u8,
        cwd: []const u8,
        success: bool,
    ) !std.process.RunResult {
        var arguments: std.ArrayList([]const u8) = .empty;
        try arguments.appendSlice(r.a, &.{ "git", "-C", cwd });
        try arguments.appendSlice(r.a, argv[1..]);
        if (!success or !std.mem.eql(u8, argv[0], "git")) return error.UnexpectedCommand;
        return .{
            .stdout = @constCast(try native.command(r.c, arguments.items, 64 << 20)),
            .stderr = try r.a.alloc(u8, 0),
            .term = .{ .exited = 0 },
        };
    }
    pub fn path(r: Runner, parts: []const []const u8) ![]const u8 {
        return r.c.join(parts);
    }
    pub fn write(r: Runner, path_name: []const u8, bytes: []const u8) !void {
        try Dir.cwd().writeFile(r.io, .{ .sub_path = path_name, .data = bytes });
    }
};

pub fn runner(c: Context) Runner {
    return .{ .a = c.a, .io = c.io, .c = c };
}

fn manifestAt(c: Context, root: []const u8) !edit.Manifest {
    const bytes = try c.read(try c.join(&.{ root, "build.zig.zon" }), 1024 * 1024);
    return edit.manifest(c.a, try c.a.dupeSentinel(u8, bytes, 0));
}

fn headerAt(c: Context, root: []const u8) !edit.Header {
    const bytes = try c.read(try c.join(&.{ root, "build.zig.zon" }), 1024 * 1024);
    return edit.header(c.a, try c.a.dupeSentinel(u8, bytes, 0));
}

fn git(c: Context, root: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ "git", "-C", root, "--no-replace-objects" });
    try argv.appendSlice(c.a, args);
    return std.mem.trimEnd(u8, try native.command(c, argv.items, 64 << 20), "\r\n");
}

fn cleanBase(c: Context, root: []const u8, input: Input) !void {
    try edit.hex(input.baseCommit, 40);
    try edit.hex(input.baseTree, 40);
    try equal(try git(c, root, &.{ "rev-parse", "HEAD" }), input.baseCommit);
    try equal(try git(c, root, &.{ "rev-parse", "HEAD^{tree}" }), input.baseTree);
    try equal(try git(c, root, &.{ "status", "--porcelain", "--untracked-files=all" }), "");
}

const Admitted = struct {
    record: Value,
    record_sha256: []const u8,
    snapshot: source.Snapshot,
};

fn admit(
    c: Context,
    name: []const u8,
    record_path: []const u8,
    archive: []const u8,
    repository: []const u8,
    destination: []const u8,
) !Admitted {
    const record_bytes = try c.read(record_path, 1024 * 1024);
    const record = try std.json.parseFromSliceLeaky(Value, c.a, record_bytes, .{});
    try equal(try text(record, "schema"), "repository-release/v1");
    const identity = try field(record, "repository");
    try equal(try text(identity, "name"), name);
    const expected_id: u64 = if (std.mem.eql(u8, name, "tkersey/horos")) 1176152390 else 1251308461;
    if (try number(try field(identity, "id")) != expected_id) return error.IdentityMismatch;
    const selected = try field(record, "source");
    const snapshot = try source.verify(
        runner(c),
        repository,
        try text(selected, "commit"),
        try text(selected, "tree"),
        archive,
        destination,
    );
    const artifacts = try field(record, "artifacts");
    if (artifacts != .array) return error.InvalidMetadata;
    var matches: usize = 0;
    for (artifacts.array.items) |artifact| {
        if (!std.mem.eql(u8, try text(artifact, "name"), "source.tar")) continue;
        matches += 1;
        try equal(try text(artifact, "role"), "source");
        try equal(try text(artifact, "sha256"), snapshot.sha256);
        if (try number(try field(artifact, "bytes")) != snapshot.size)
            return error.IdentityMismatch;
    }
    if (matches != 1) return error.InvalidMetadata;
    try equal(try c.fileDigest(try c.join(&.{
        destination,
        "build.zig.zon",
    })), try text(selected, "manifestSha256"));
    try edit.version(try text(selected, "version"));
    try equal(try text(record, "tag"), try std.fmt.allocPrint(c.a, "v{s}", .{
        try text(selected, "version"),
    }));
    return .{ .record = record, .record_sha256 = try c.digest(record_bytes), .snapshot = snapshot };
}

fn derivedHoros(c: Context, kosmos: Admitted, input: Input, parent: []const u8) !Admitted {
    const dependencies = try field(kosmos.record, "dependencies");
    if (dependencies != .array or dependencies.array.items.len != 1) return error.InvalidMetadata;
    const dependency = dependencies.array.items[0];
    try equal(try text(try field(dependency, "repository"), "name"), "tkersey/horos");
    const release = try field(dependency, "release");
    const digest = try text(release, "recordSha256");
    try edit.hex(digest, 64);
    const directory = try c.join(&.{ input.upstreamDirectory, digest });
    const record_path = try c.join(&.{ directory, "release.json" });
    try equal(try c.fileDigest(record_path), digest);
    const result = try admit(
        c,
        "tkersey/horos",
        record_path,
        try c.join(&.{ directory, "source.tar" }),
        try c.join(&.{ directory, "repository.git" }),
        try c.join(&.{ parent, "horos" }),
    );
    try equal(result.record_sha256, digest);

    const selected = try field(result.record, "source");
    inline for (.{ "commit", "tree", "version", "packageIdentity", "manifestSha256" }) |key| {
        try equal(try text(selected, key), try text(try field(dependency, "source"), key));
    }
    try equal(try text(result.record, "tag"), try text(release, "tag"));
    const manifest = try manifestAt(c, kosmos.snapshot.source);
    try transitiveBinding(manifest, result.snapshot.commit, try text(selected, "packageIdentity"));
    try equal(manifest.version, try text(try field(kosmos.record, "source"), "version"));
    return result;
}

fn transitiveBinding(manifest: edit.Manifest, commit: []const u8, identity: []const u8) !void {
    try equal(try edit.commit(manifest.dependencies.horos.url), commit);
    try equal(manifest.dependencies.horos.hash, identity);
}

fn inventoryValue(c: Context, inventory: Inventory) !Value {
    return c.value(.{
        .inventorySha256 = try inventory.identity(c),
        .entries = inventory.files.items.len,
        .bytes = inventory.bytes,
    });
}

fn managedExecutable(c: Context, path: []const u8) !bool {
    const bytes = try c.readWithAllocator(c.scratch, path, 64 << 20);
    defer c.scratch.free(bytes);
    if (std.mem.startsWith(u8, bytes, "#!") or std.mem.startsWith(u8, bytes, std.elf.MAGIC))
        return true;
    if (bytes.len < 4) return false;
    return switch (std.mem.readInt(u32, bytes[0..4], .little)) {
        std.macho.MH_MAGIC,
        std.macho.MH_MAGIC_64,
        std.macho.FAT_MAGIC,
        std.macho.FAT_MAGIC_64,
        std.macho.MH_CIGAM,
        std.macho.MH_CIGAM_64,
        std.macho.FAT_CIGAM,
        std.macho.FAT_CIGAM_64,
        => true,
        else => false,
    };
}

fn normalized(c: Context, path: []const u8, managed_profile: bool) !Inventory {
    const inventory = try Inventory.load(c, path, 10000);
    for (inventory.files.items) |row| {
        const name = try c.join(&.{ path, try text(row, "path") });
        const directory = std.mem.eql(u8, try text(row, "kind"), "directory");
        if (directory) {
            var dir = try Dir.cwd().openDir(c.io, name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer dir.close(c.io);
            try dir.setPermissions(c.io, .fromMode(0o755));
        } else {
            const executable = if (managed_profile)
                try managedExecutable(c, name)
            else
                try number(try field(row, "mode")) & 0o111 != 0;
            var file = try Dir.cwd().openFile(c.io, name, .{ .follow_symlinks = false });
            defer file.close(c.io);
            const mode: u32 = if (executable) 0o755 else 0o644;
            try file.setPermissions(
                c.io,
                .fromMode(@intCast(if (managed_profile and executable) 0o777 else mode)),
            );
        }
    }
    return Inventory.load(c, path, 10000);
}

const Package = struct {
    identity: []const u8,
    archive: Value,
    extracted: Inventory,
    managed: Inventory,
};

fn canonicalPackage(
    c: Context,
    root: []const u8,
    inventory: Inventory,
    identity: []const u8,
) ![]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (inventory.files.items) |row| {
        if (std.mem.eql(u8, try text(row, "kind"), "file"))
            try paths.append(c.a, try text(row, "path"));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    var buffer = try std.Io.Writer.Allocating.initCapacity(c.a, 4096);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&buffer.writer, &window, .gzip, .level_9);
    var writer: std.tar.Writer = .{ .underlying_writer = &compressor.writer, .prefix = identity };
    for (paths.items) |path| {
        const bytes = try c.readWithAllocator(c.scratch, try c.join(&.{ root, path }), 64 << 20);
        defer c.scratch.free(bytes);
        try writer.writeFileBytes(path, bytes, .{});
    }
    try compressor.finish();
    return buffer.toOwnedSlice();
}

fn fetchPackage(c: Context, root: []const u8, parent: []const u8, zig: []const u8) !Package {
    const identity = std.mem.trim(
        u8,
        try native.command(c, &.{ zig, "fetch", root }, 65536),
        "\r\n ",
    );
    try edit.packageIdentity(identity);
    const environment = try native.command(c, &.{ zig, "env" }, 65536);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const paths = try std.zon.parse.fromSlice(struct { global_cache_dir: []const u8 }, .{
        .gpa = c.scratch,
        .arena = c.a,
        .source = try c.a.dupeSentinel(u8, environment, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    const archive_path = try c.join(&.{
        paths.global_cache_dir,                                 "p",
        try std.fmt.allocPrint(c.a, "{s}.tar.gz", .{identity}),
    });
    const bytes = try c.read(archive_path, 64 << 20);
    const snapshot = try c.join(&.{ parent, "package.tar.gz" });
    _ = try source.retain(runner(c), snapshot, bytes);
    const observed = std.mem.trim(
        u8,
        try native.command(c, &.{ zig, "fetch", snapshot }, 65536),
        "\r\n ",
    );
    try equal(identity, observed);
    try native.validateTar(c, snapshot, identity, false);
    const extracted_root = try c.join(&.{ parent, "package" });
    try Dir.cwd().createDir(c.io, extracted_root, .default_dir);
    _ = try native.command(
        c,
        &.{
            "tar",             "-xzpf", snapshot,       "--strip-components=1",
            "--no-same-owner", "-C",    extracted_root,
        },
        65536,
    );
    const extracted = try normalized(c, extracted_root, false);
    try equal(bytes, try canonicalPackage(c, extracted_root, extracted, identity));
    const managed = try normalized(c, extracted_root, true);
    return .{ .identity = identity, .archive = try c.value(.{
        .sha256 = try c.digest(bytes),
        .bytes = bytes.len,
    }), .extracted = extracted, .managed = managed };
}

fn package(c: Context, horos: Admitted, parent: []const u8, zig: []const u8) !Value {
    const admitted = try fetchPackage(c, horos.snapshot.source, parent, zig);
    const selected = try field(horos.record, "source");
    try equal(admitted.identity, try text(selected, "packageIdentity"));
    try equal((try headerAt(c, horos.snapshot.source)).version, try text(selected, "version"));
    const prefix = try std.fmt.allocPrint(c.a, "horos-{s}-", .{try text(selected, "version")});
    if (!std.mem.startsWith(u8, admitted.identity, prefix)) return error.IdentityMismatch;
    return c.value(.{
        .zigHash = admitted.identity,
        .defaultProfile = "zig-managed",
        .profiles = .{
            .@"zig-managed" = try inventoryValue(c, admitted.managed),
            .@"archive-extracted" = try inventoryValue(c, admitted.extracted),
        },
        .archive = admitted.archive,
    });
}

fn sourceItem(c: Context, previous: Value, admitted: Admitted) !Value {
    var result = previous;
    const selected = try field(admitted.record, "source");
    try c.put(&result, "commit", admitted.snapshot.commit);
    try c.put(&result, "gitTree", admitted.snapshot.tree);
    try c.put(&result, "version", try text(selected, "version"));
    const inventory = try normalized(c, admitted.snapshot.source, false);
    try result.object.put(c.a, "source", try inventoryValue(c, inventory));
    try c.put(&result, "archive", .{
        .format = "repository-source-tar/v1",
        .url = try std.fmt.allocPrint(
            c.a,
            "https://github.com/{s}/releases/download/{s}/source.tar",
            .{
                try text(try field(admitted.record, "repository"), "name"),
                try text(admitted.record, "tag"),
            },
        ),
        .sha256 = admitted.snapshot.sha256,
        .bytes = admitted.snapshot.size,
        .origin = "Repository release source authenticated against the complete Git tree.",
    });
    return result;
}

fn apiFiles(c: Context, item: *Value, root: []const u8) !void {
    var api = try field(item.*, "api");
    const files = try field(api, "files");
    if (files != .array or files.array.items.len == 0) return error.InvalidMetadata;
    var updated: std.ArrayList(Value) = .empty;
    for (files.array.items) |row| {
        const path = try text(row, "path");
        try safeRelative(path);
        try updated.append(c.a, try c.value(.{
            .path = path,
            .sha256 = try c.fileDigest(try c.join(&.{ root, path })),
        }));
    }
    try c.put(&api, "files", updated.items);
    try item.object.put(c.a, "api", api);
}

fn safeRelative(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00\r\n") != null)
        return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidPath;
    }
}

fn compiler(c: Context, zig: []const u8) !Value {
    try equal(std.mem.trim(u8, try native.command(c, &.{
        zig,
        "version",
    }, 1024), "\r\n "), "0.17.0");
    const path = try Dir.cwd().realPathFileAlloc(c.io, zig, c.a);
    return c.value(.{
        .zig = .{ .version = "0.17.0", .executableSha256 = try c.fileDigest(path) },
        .platform = if (builtin.os.tag == .macos) "darwin" else @tagName(builtin.os.tag),
        .architecture = if (builtin.cpu.arch == .aarch64) "arm64" else @tagName(builtin.cpu.arch),
    });
}

fn projectManifest(c: Context, root: []const u8, version: []const u8, horos: Value) !void {
    const path = try c.join(&.{ root, "build.zig.zon" });
    var bytes: []const u8 = try c.read(path, 1024 * 1024);
    const values = [_][]const u8{
        version,
        try std.fmt.allocPrint(c.a, "git+https://github.com/tkersey/horos#{s}", .{
            try text(horos, "commit"),
        }),
        try text(try field(horos, "package"), "zigHash"),
    };
    const paths = [_][]const []const u8{
        &.{"version"}, &.{ "dependencies", "horos", "url" }, &.{ "dependencies", "horos", "hash" },
    };
    for (paths, values) |keys, value| bytes = try edit.zon(
        c.a,
        try c.a.dupeSentinel(u8, bytes, 0),
        keys,
        value,
    );
    try Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = bytes });
}

const Generated = struct {
    lock: Value,
    horos_record_sha256: []const u8,
    kosmos_record_sha256: []const u8,
};

fn generatedLock(
    c: Context,
    root: []const u8,
    input: Input,
    stage: []const u8,
    zig: []const u8,
) !Generated {
    var lock = try native.lockAt(c, try c.join(&.{ root, lock_path }));
    const upstream = try c.join(&.{ stage, "sources" });
    try Dir.cwd().createDir(c.io, upstream, .default_dir);
    const kosmos = try admit(
        c,
        "tkersey/kosmos",
        input.kosmos.record,
        input.kosmos.archive,
        input.kosmos.repository,
        try c.join(&.{ upstream, "kosmos" }),
    );

    const horos = try derivedHoros(c, kosmos, input, upstream);
    var boundary = try sourceItem(c, try field(lock, "boundary"), horos);
    try boundary.object.put(c.a, "package", try package(c, horos, stage, zig));
    try apiFiles(c, &boundary, horos.snapshot.source);
    try lock.object.put(c.a, "boundary", boundary);
    try lock.object.put(c.a, "world", try sourceItem(c, try field(lock, "world"), kosmos));
    try lock.object.put(c.a, "toolchain", try compiler(c, zig));
    try c.put(&lock, "status", "released-integration");
    const dependencies = try field(kosmos.record, "dependencies");
    try c.put(&lock, "publicationObservation", .{
        .compatiblePublishedReleaseObserved = true,
        .releases = .{
            try std.fmt.allocPrint(c.a, "https://github.com/tkersey/horos/releases/tag/{s}", .{
                try text(try field(dependencies.array.items[0], "release"), "tag"),
            }),
            try std.fmt.allocPrint(c.a, "https://github.com/tkersey/kosmos/releases/tag/{s}", .{
                try text(kosmos.record, "tag"),
            }),
        },
        .pullRequests = [0][]const u8{},
    });
    return .{
        .lock = lock,
        .horos_record_sha256 = horos.record_sha256,
        .kosmos_record_sha256 = kosmos.record_sha256,
    };
}

fn writeCandidate(
    c: Context,
    root: []const u8,
    input: Input,
    stage: []const u8,
    lock: Value,
) !void {
    const output = try c.join(&.{ stage, "source" });
    _ = try source.prepare(runner(c), root, stage);
    const bytes = try std.json.Stringify.valueAlloc(c.a, lock, .{ .whitespace = .indent_2 });
    try Dir.cwd().writeFile(c.io, .{
        .sub_path = try c.join(&.{ output, lock_path }),
        .data = try std.mem.concat(c.a, u8, &.{ bytes, "\n" }),
    });
    try projectManifest(c, output, input.version, try field(lock, "boundary"));
}

pub fn prepare(c: Context, args: []const []const u8) !void {
    if (args.len != 4) return error.ExpectedRootInputOutputZig;
    const input = try std.json.parseFromSliceLeaky(Input, c.a, try c.read(args[1], 1024 * 1024), .{
        .allocate = .alloc_always,
    });
    try equal(input.schema, "protean-refresh/v1");
    try edit.version(input.version);
    for ([_][]const u8{
        input.kosmos.record,
        input.kosmos.archive,
        input.kosmos.repository,
        input.upstreamDirectory,
        args[2],
    }) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.ExpectedAbsolutePath;
    }
    try cleanBase(c, args[0], input);
    const previous_version = try std.SemanticVersion.parse((try manifestAt(c, args[0])).version);
    if ((try std.SemanticVersion.parse(input.version)).order(previous_version) == .lt)
        return error.VersionDowngrade;
    const stage = try native.stageDirectory(c, std.fs.path.dirname(args[2]) orelse ".");
    defer Dir.cwd().deleteTree(c.io, stage) catch |err| {
        std.log.err("refresh staging cleanup failed: {s}", .{@errorName(err)});
    };
    const generated = try generatedLock(c, args[0], input, stage, args[3]);
    try writeCandidate(c, args[0], input, stage, generated.lock);
    try check(c, &.{
        try c.join(&.{ stage, "source" }),
        try c.join(&.{ stage, "sources" }),
        args[3],
    });
    const inventory = try Inventory.load(c, try c.join(&.{ stage, "source" }), 10000);
    const result = try c.encode(.{
        .schema = "protean-refresh-result/v1",
        .baseCommit = input.baseCommit,
        .baseTree = input.baseTree,
        .version = input.version,
        .horosRecordSha256 = generated.horos_record_sha256,
        .kosmosRecordSha256 = generated.kosmos_record_sha256,
        .source = try inventoryValue(c, inventory),
        .lockSha256 = try c.fileDigest(try c.join(&.{ stage, "source", lock_path })),
    });
    try Dir.cwd().writeFile(c.io, .{
        .sub_path = try c.join(&.{ stage, "result.json" }),
        .data = result,
    });
    try cleanBase(c, args[0], input);
    if (try native.exists(c, args[2])) {
        try equal(result, try c.read(try c.join(&.{ args[2], "result.json" }), 1024 * 1024));
        const expected = try Inventory.load(c, stage, 10000);
        const retained = try Inventory.load(c, args[2], 10000);
        try retained.verify(c, try inventoryValue(c, expected));
        return;
    }
    try Dir.cwd().renamePreserve(stage, .cwd(), args[2], c.io);
}

fn checkApi(c: Context, boundary: Value, root: []const u8) !void {
    const files = try field(try field(boundary, "api"), "files");
    if (files != .array or files.array.items.len == 0) return error.InvalidMetadata;
    for (files.array.items) |row| {
        const path = try text(row, "path");
        try safeRelative(path);
        try equal(try text(row, "sha256"), try c.fileDigest(try c.join(&.{ root, path })));
    }
}

fn objectHash(kind: []const u8, bytes: []const u8) [20]u8 {
    var state = std.crypto.hash.Sha1.init(.{});
    var buffer: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buffer, "{s} {d}\x00", .{ kind, bytes.len }) catch
        @panic("object header exceeds fixed capacity");
    state.update(header);
    state.update(bytes);
    return state.finalResult();
}

const TreeEntry = struct { path: []const u8, mode: []const u8, digest: [20]u8, directory: bool };

fn treeOrder(_: void, left: TreeEntry, right: TreeEntry) bool {
    const a = std.fs.path.basename(left.path);
    const b = std.fs.path.basename(right.path);
    const common = @min(a.len, b.len);
    const order = std.mem.order(u8, a[0..common], b[0..common]);
    if (order != .eq) return order == .lt;
    const ac: u8 = if (a.len == common) (if (left.directory) '/' else 0) else a[common];
    const bc: u8 = if (b.len == common) (if (right.directory) '/' else 0) else b[common];
    return ac < bc;
}

fn directoryHash(c: Context, entries: []const TreeEntry, parent: []const u8) ![20]u8 {
    var selected: std.ArrayList(TreeEntry) = .empty;
    for (entries) |entry| {
        if (std.mem.eql(u8, std.fs.path.dirname(entry.path) orelse "", parent))
            try selected.append(c.a, entry);
    }
    std.mem.sort(TreeEntry, selected.items, {}, treeOrder);
    var bytes = std.Io.Writer.Allocating.init(c.a);
    for (selected.items) |entry| {
        try bytes.writer.print("{s} {s}\x00", .{ entry.mode, std.fs.path.basename(entry.path) });
        try bytes.writer.writeAll(&entry.digest);
    }
    return objectHash("tree", bytes.written());
}

fn gitTree(c: Context, root: []const u8) ![]const u8 {
    const inventory = try Inventory.load(c, root, 10000);
    var entries: std.ArrayList(TreeEntry) = .empty;
    var index = inventory.files.items.len;
    while (index > 0) {
        index -= 1;
        const row = inventory.files.items[index];
        const path = try text(row, "path");
        const directory = std.mem.eql(u8, try text(row, "kind"), "directory");
        const mode = try number(try field(row, "mode"));
        const digest = if (directory)
            try directoryHash(c, entries.items, path)
        else
            objectHash("blob", try c.read(try c.join(&.{ root, path }), 64 << 20));

        try entries.append(c.a, .{
            .path = path,
            .directory = directory,
            .digest = digest,
            .mode = if (directory) "40000" else if (mode & 0o111 != 0) "100755" else "100644",
        });
    }
    return c.a.dupe(u8, &std.fmt.bytesToHex(try directoryHash(c, entries.items, ""), .lower));
}

pub fn check(c: Context, args: []const []const u8) !void {
    if (args.len != 3) return error.ExpectedRootSourcesZig;
    const lock = try native.lockAt(c, try c.join(&.{ args[0], lock_path }));
    const boundary = try field(lock, "boundary");
    const world = try field(lock, "world");
    const horos = try c.join(&.{ args[1], "horos" });
    const kosmos = try c.join(&.{ args[1], "kosmos" });
    try native.verifySource(c, horos, boundary, false);
    try native.verifySource(c, kosmos, world, false);
    try equal(try gitTree(c, horos), try text(boundary, "gitTree"));
    try equal(try gitTree(c, kosmos), try text(world, "gitTree"));
    const manifest = try manifestAt(c, args[0]);
    const transitive = try manifestAt(c, kosmos);
    try equal(try edit.commit(manifest.dependencies.horos.url), try text(boundary, "commit"));
    try equal(
        manifest.dependencies.horos.hash,
        try text(try field(boundary, "package"), "zigHash"),
    );
    try equal(manifest.dependencies.horos.url, transitive.dependencies.horos.url);
    try equal(manifest.dependencies.horos.hash, transitive.dependencies.horos.hash);
    try equal(transitive.version, try text(world, "version"));
    try equal((try headerAt(c, horos)).version, try text(boundary, "version"));
    try equal(try text(try field(try field(lock, "toolchain"), "zig"), "version"), "0.17.0");
    _ = try compiler(c, args[2]);
    try checkApi(c, boundary, horos);
    const temporary = try native.stageDirectory(c, args[1]);
    defer Dir.cwd().deleteTree(c.io, temporary) catch |err| {
        std.log.err("coherence package cleanup failed: {s}", .{@errorName(err)});
    };
    const admitted = try fetchPackage(c, horos, temporary, args[2]);
    try equal(admitted.identity, manifest.dependencies.horos.hash);
    const expected = try field(boundary, "package");
    const profiles = try field(expected, "profiles");
    try admitted.managed.verify(c, try field(profiles, "zig-managed"));
    try admitted.extracted.verify(c, try field(profiles, "archive-extracted"));
    try equal(
        try text(admitted.archive, "sha256"),
        try text(try field(expected, "archive"), "sha256"),
    );
    if (try number(try field(admitted.archive, "bytes")) !=
        try number(try field(try field(expected, "archive"), "bytes")))
        return error.IdentityMismatch;
}

test "refresh input cannot independently override Horos or omit a frozen base" {
    const bytes =
        \\{"schema":"protean-refresh/v1","baseCommit":"a","baseTree":"b","version":"8.0.1",
        \\ "kosmos":{"record":"/record","archive":"/archive","repository":"/git"},
        \\ "upstreamDirectory":"/upstream","horos":{"commit":"override"}}
    ;
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(
        Input,
        std.testing.allocator,
        bytes,
        .{},
    ));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(
        Input,
        std.testing.allocator,
        "{\"schema\":\"protean-refresh/v1\"}",
        .{},
    ));
}

test "transitive binding rejects parseable wrong commit and wrong package hash" {
    const manifest: edit.Manifest = .{
        .version = "9.1.0",
        .minimum_zig_version = "0.17.0",
        .dependencies = .{ .horos = .{
            .url = "git+https://github.com/tkersey/horos#7d34f2c72e818665be4d519fde4f2cef9c986048",
            .hash = "horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU",
        } },
    };
    const commit = "7d34f2c72e818665be4d519fde4f2cef9c986048";
    try transitiveBinding(manifest, commit, manifest.dependencies.horos.hash);
    try std.testing.expectError(
        error.IdentityMismatch,
        transitiveBinding(
            manifest,
            "0000000000000000000000000000000000000000",
            manifest.dependencies.horos.hash,
        ),
    );
    try std.testing.expectError(
        error.IdentityMismatch,
        transitiveBinding(
            manifest,
            commit,
            "horos-8.0.0-flclaGr2VwCq00YsrM9GGVhbXljmSK1p_V9FwCp8iLOk",
        ),
    );
}

test "source coherence recomputes actual Git tree including directory sort and executable bits" {
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
    const tree = try c.join(&.{ root, "tree" });
    try Dir.cwd().createDir(c.io, tree, .default_dir);
    try Dir.cwd().createDirPath(c.io, try c.join(&.{ tree, "a" }));
    try Dir.cwd().writeFile(c.io, .{
        .sub_path = try c.join(&.{ tree, "a", "child" }),
        .data = "a",
    });
    try Dir.cwd().writeFile(c.io, .{ .sub_path = try c.join(&.{ tree, "a.c" }), .data = "b" });
    const before = try gitTree(c, tree);
    _ = try git(c, tree, &.{ "init", "--quiet" });
    _ = try git(c, tree, &.{ "add", "--force", "." });
    const expected = try git(c, tree, &.{"write-tree"});
    try equal(before, expected);
    try Dir.cwd().deleteTree(c.io, try c.join(&.{ tree, ".git" }));
    var file = try Dir.cwd().openFile(c.io, try c.join(&.{ tree, "a.c" }), .{});
    try file.setPermissions(c.io, .fromMode(0o755));
    file.close(c.io);
    try std.testing.expect(!std.mem.eql(u8, before, try gitTree(c, tree)));
}

test "package profiles preserve complete file selection and independently distinguish permissions" {
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
    try temporary.dir.writeFile(c.io, .{ .sub_path = "ordinary", .data = "#!/bin/sh\n" });
    var executable = try temporary.dir.openFile(c.io, "ordinary", .{});
    try executable.setPermissions(c.io, .fromMode(0o755));
    executable.close(c.io);
    const managed = try normalized(c, root, true);
    const extracted = try normalized(c, root, false);
    try std.testing.expectEqual(
        @as(u64, 0o777),
        try number(try field(managed.files.items[0], "mode")),
    );
    try std.testing.expectEqual(
        @as(u64, 0o755),
        try number(try field(extracted.files.items[0], "mode")),
    );
    try std.testing.expectEqual(managed.bytes, extracted.bytes);
    try std.testing.expectError(
        error.IdentityMismatch,
        extracted.verify(c, try inventoryValue(c, managed)),
    );
}

const Fixture = struct {
    root: []const u8,
    zig: []const u8,
    input: []const u8,
    base: []const u8,
    horos: Value,
    kosmos: Value,
    upstream: []const u8,
};

fn fixtureWrite(c: Context, root: []const u8, path: []const u8, bytes: []const u8) !void {
    const absolute = try c.join(&.{ root, path });
    if (std.fs.path.dirname(absolute)) |parent| try Dir.cwd().createDirPath(c.io, parent);
    try Dir.cwd().writeFile(c.io, .{ .sub_path = absolute, .data = bytes });
}

fn fixtureCommit(c: Context, root: []const u8) !void {
    _ = try git(c, root, &.{ "init", "--quiet" });
    _ = try git(c, root, &.{ "add", "--force", "." });
    _ = try git(c, root, &.{
        "-c", "user.name=Fixture",    "-c",     "user.email=fixture@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "--quiet",
        "-m", "fixture",
    });
}

fn fixtureRecord(
    c: Context,
    root: []const u8,
    output: []const u8,
    name: []const u8,
    id: u64,
    version: []const u8,
    identity: ?[]const u8,
) !Value {
    try Dir.cwd().createDirPath(c.io, output);
    const snapshot = try source.prepare(runner(c), root, output);
    return c.value(.{
        .schema = "repository-release/v1",
        .repository = .{ .id = id, .name = name },
        .source = .{
            .commit = snapshot.commit,
            .tree = snapshot.tree,
            .version = version,
            .packageIdentity = identity,
            .lockSha256 = null,
            .manifestSha256 = try c.fileDigest(try c.join(&.{ root, "build.zig.zon" })),
        },
        .tag = try std.fmt.allocPrint(c.a, "v{s}", .{version}),
        .dependencies = [0]Value{},
        .artifacts = .{.{
            .name = "source.tar",
            .role = "source",
            .platform = null,
            .sha256 = snapshot.sha256,
            .bytes = snapshot.size,
        }},
    });
}

fn fixtureHoros(c: Context, root: []const u8, zig: []const u8) !Value {
    const repository = try c.join(&.{ root, "horos" });
    try fixtureWrite(c, repository, "build.zig.zon",
        \\.{ .name=.horos, .version="8.0.0", .fingerprint=0x7039c7146825577e,
        \\ .minimum_zig_version="0.17.0", .paths=.{"build.zig.zon","src","script"} }
    );
    try fixtureWrite(c, repository, "src/root.zig", "pub const value = 1;\n");
    try fixtureWrite(c, repository, "script", "#!/bin/sh\nexit 0\n");
    try fixtureCommit(c, repository);
    const output = try c.join(&.{ root, "horos-output" });
    var result = try fixtureRecord(
        c,
        repository,
        output,
        "tkersey/horos",
        1176152390,
        "8.0.0",
        null,
    );
    const identity = std.mem.trim(u8, try native.command(c, &.{
        zig, "fetch", try c.join(&.{ output, "source" }),
    }, 65536), "\r\n ");
    var selected = try field(result, "source");
    try c.put(&selected, "packageIdentity", identity);
    try result.object.put(c.a, "source", selected);
    return result;
}

fn fixtureManifest(c: Context, version: []const u8, horos: Value) ![]const u8 {
    const selected = try field(horos, "source");
    return std.fmt.allocPrint(c.a,
        \\.{{ .version="{s}", .minimum_zig_version="0.17.0", .dependencies=.{{ .horos=.{{
        \\ .url="git+https://github.com/tkersey/horos#{s}", .hash="{s}" }} }} }}
    , .{ version, try text(selected, "commit"), try text(selected, "packageIdentity") });
}

fn fixtureKosmos(c: Context, root: []const u8, horos: Value) !Value {
    const repository = try c.join(&.{ root, "kosmos" });
    try fixtureWrite(c, repository, "build.zig.zon", try fixtureManifest(c, "9.1.0", horos));
    try fixtureCommit(c, repository);
    var result = try fixtureRecord(
        c,
        repository,
        try c.join(&.{ root, "kosmos-output" }),
        "tkersey/kosmos",
        1251308461,
        "9.1.0",
        null,
    );
    try c.put(&result, "dependencies", .{.{
        .repository = try field(horos, "repository"),
        .source = try field(horos, "source"),
        .release = .{ .id = 1, .tag = "v8.0.0", .recordSha256 = try c.digest(try c.encode(horos)) },
    }});
    return result;
}

fn fixtureBase(c: Context, root: []const u8, horos: Value, kosmos: Value) ![]const u8 {
    const base = try c.join(&.{ root, "base" });
    try fixtureWrite(c, base, "build.zig.zon", try fixtureManifest(c, "8.0.0", horos));
    var lock = try c.value(.{
        .format = "agent-native-source-lock/v2",
        .status = "development-integration",
        .notes = .{"preserved"},
    });
    const records = [_]Value{ horos, kosmos };
    for ([_][]const u8{ "boundary", "world" }, records) |name, record| {
        const repository = try text(try field(record, "repository"), "name");
        const commit = try text(try field(record, "source"), "commit");
        var item = try c.value(.{
            .repository = repository,
            .commit = commit,
            .archive = .{ .url = try std.fmt.allocPrint(
                c.a,
                "https://github.com/{s}/archive/{s}.tar.gz",
                .{ repository, commit },
            ) },
        });
        if (std.mem.eql(u8, name, "boundary")) try c.put(&item, "api", .{
            .files = .{.{ .path = "src/root.zig", .sha256 = "to-regenerate" }},
        });
        try lock.object.put(c.a, name, item);
    }
    try fixtureWrite(c, base, lock_path, try c.encode(lock));
    try fixtureWrite(
        c,
        base,
        "conformance/protean/native-dependencies.lock.json",
        "unchanged SQLite",
    );
    try fixtureCommit(c, base);
    return base;
}

fn fixture(c: Context, root: []const u8) !Fixture {
    const zig = try source.testCompiler(c.a);
    const horos = try fixtureHoros(c, root, zig);
    const kosmos = try fixtureKosmos(c, root, horos);
    const base = try fixtureBase(c, root, horos, kosmos);
    const upstream = try c.join(&.{ root, "upstream" });
    const selected = try c.join(&.{ upstream, try c.digest(try c.encode(horos)) });
    try fixtureWrite(c, selected, "release.json", try c.encode(horos));
    try fixtureWrite(
        c,
        selected,
        "source.tar",
        try c.read(try c.join(&.{ root, "horos-output/source.tar" }), 64 << 20),
    );
    const repository_path = try c.join(&.{ root, "horos" });
    const destination = try c.join(&.{ selected, "repository.git" });
    _ = try native.command(c, &.{
        "git", "clone", "--bare", "--quiet", "--shared", repository_path, destination,
    }, 65536);
    const record_path = try c.join(&.{ root, "kosmos.json" });
    try fixtureWrite(c, root, "kosmos.json", try c.encode(kosmos));
    const input = try c.join(&.{ root, "input.json" });
    try fixtureWrite(c, root, "input.json", try c.encode(.{
        .schema = "protean-refresh/v1",
        .baseCommit = try git(c, base, &.{ "rev-parse", "HEAD" }),
        .baseTree = try git(c, base, &.{ "rev-parse", "HEAD^{tree}" }),
        .version = "8.0.1",
        .kosmos = .{
            .record = record_path,
            .archive = try c.join(&.{ root, "kosmos-output/source.tar" }),
            .repository = try c.join(&.{ root, "kosmos" }),
        },
        .upstreamDirectory = upstream,
    }));
    return .{
        .root = root,
        .zig = zig,
        .input = input,
        .base = base,
        .horos = horos,
        .kosmos = kosmos,
        .upstream = upstream,
    };
}

test "complete refresh is deterministic transactional and preserves unrelated native selections" {
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
    const f = try fixture(c, try temporary.dir.realPathFileAlloc(c.io, ".", c.a));
    const one = try c.join(&.{ f.root, "one" });
    const two = try c.join(&.{ f.root, "two" });
    try prepare(c, &.{ f.base, f.input, one, f.zig });
    const initial = try c.read(try c.join(&.{ one, "result.json" }), 1024 * 1024);
    try prepare(c, &.{ f.base, f.input, one, f.zig });
    try prepare(c, &.{ f.base, f.input, two, f.zig });
    try equal(initial, try c.read(try c.join(&.{ two, "result.json" }), 1024 * 1024));
    const generated = try native.lockAt(c, try c.join(&.{ one, "source", lock_path }));
    const boundary = try field(generated, "boundary");
    try equal(try text(boundary, "commit"), try text(try field(f.horos, "source"), "commit"));
    try equal(
        try text(try field(generated, "world"), "commit"),
        try text(try field(f.kosmos, "source"), "commit"),
    );
    const profiles = try field(try field(boundary, "package"), "profiles");
    try std.testing.expect(!std.mem.eql(
        u8,
        try text(try field(profiles, "zig-managed"), "inventorySha256"),
        try text(try field(profiles, "archive-extracted"), "inventorySha256"),
    ));
    try equal("unchanged SQLite", try c.read(try c.join(&.{
        one,                                                 "source",
        "conformance/protean/native-dependencies.lock.json",
    }), 1024));
    try equal("", try git(c, f.base, &.{ "status", "--porcelain" }));
    try fixtureWrite(c, f.root, "kosmos-output/source.tar", "corrupt");
    const rejected = try c.join(&.{ f.root, "rejected" });
    if (prepare(c, &.{ f.base, f.input, rejected, f.zig })) |_| {
        return error.ExpectedRejection;
    } else |_| {}
    try std.testing.expect(!try native.exists(c, rejected));
    try equal(initial, try c.read(try c.join(&.{ one, "result.json" }), 1024 * 1024));
}

test "refresh rejects independently authenticated Kosmos with an incorrect transitive manifest" {
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
    const f = try fixture(c, try temporary.dir.realPathFileAlloc(c.io, ".", c.a));
    const kosmos_path = try c.join(&.{ f.root, "kosmos" });
    const before = try c.read(try c.join(&.{ kosmos_path, "build.zig.zon" }), 1024 * 1024);
    const wrong = try edit.zon(
        c.a,
        try c.a.dupeSentinel(u8, before, 0),
        &.{ "dependencies", "horos", "hash" },
        "horos-8.0.0-flclaGr2VwCq00YsrM9GGVhbXljmSK1p_V9FwCp8iLOk",
    );
    try fixtureWrite(c, kosmos_path, "build.zig.zon", wrong);
    try fixtureCommit(c, kosmos_path);
    const output = try c.join(&.{ f.root, "wrong-output" });
    var record = try fixtureRecord(
        c,
        kosmos_path,
        output,
        "tkersey/kosmos",
        1251308461,
        "9.1.0",
        null,
    );
    try record.object.put(c.a, "dependencies", try field(f.kosmos, "dependencies"));
    try fixtureWrite(c, f.root, "kosmos.json", try c.encode(record));
    var input = try c.json(f.input);
    var selected = try field(input, "kosmos");
    try c.put(&selected, "archive", try c.join(&.{ output, "source.tar" }));
    try input.object.put(c.a, "kosmos", selected);
    try fixtureWrite(c, f.root, "input.json", try c.encode(input));
    const rejected = try c.join(&.{ f.root, "rejected" });
    try std.testing.expectError(
        error.IdentityMismatch,
        prepare(c, &.{ f.base, f.input, rejected, f.zig }),
    );
    try std.testing.expect(!try native.exists(c, rejected));
    try c.put(&input, "version", "7.0.0");
    try fixtureWrite(c, f.root, "input.json", try c.encode(input));
    try std.testing.expectError(
        error.VersionDowngrade,
        prepare(c, &.{ f.base, f.input, rejected, f.zig }),
    );
}
