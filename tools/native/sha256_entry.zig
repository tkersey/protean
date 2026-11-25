const std = @import("std");
const Ast = std.zig.Ast;

const exempt_paths = [_][]const u8{
    "runtime/native/hash_accelerated.zig",
    "tools/native/dependencies.zig",
    "tools/native/emit.zig",
};
const oracle_directory = "test/";

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const inventory_path = arguments.next() orelse return error.ExpectedInventory;
    if (arguments.next() != null) return error.UnexpectedArgument;
    const directory = std.Io.Dir.cwd();
    const inventory = try directory.readFileAlloc(init.io, inventory_path, a, .limited(1 << 20));
    var bypasses: usize = 0;
    var paths = std.mem.tokenizeScalar(u8, inventory, '\n');
    while (paths.next()) |path| {
        if (exempt(path)) continue;
        const source = try directory.readFileAllocOptions(
            init.io,
            path,
            a,
            .limited(64 << 20),
            .of(u8),
            0,
        );
        const lines = try bypassLines(a, source);
        for (lines) |line| std.debug.print(
            "{s}:{d}: runtime SHA-256 must use hash_abi.Sha256, not std.crypto sha2\n",
            .{ path, line },
        );
        bypasses += lines.len;
    }
    if (bypasses != 0) return error.Sha256EntryBypassed;
}

fn exempt(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, oracle_directory)) return true;
    for (exempt_paths) |allowed| {
        if (std.mem.eql(u8, path, allowed)) return true;
    }
    return false;
}

fn bypassLines(gpa: std.mem.Allocator, source: [:0]const u8) ![]usize {
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.InvalidSource;
    var oracles: std.ArrayList([2]Ast.TokenIndex) = .empty;
    defer oracles.deinit(gpa);
    var lines: std.ArrayList(usize) = .empty;
    errdefer lines.deinit(gpa);
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (tree.nodeTag(node) != .test_decl) continue;
        try oracles.append(gpa, .{ tree.firstToken(node), tree.lastToken(node) });
    }
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (tree.nodeTag(node) != .field_access) continue;
        const field = tree.nodeData(node).node_and_token[1];
        if (!std.mem.eql(u8, tree.tokenSlice(field), "sha2")) continue;
        if (within(oracles.items, field)) continue;
        try lines.append(gpa, tree.tokenLocation(0, field).line + 1);
    }
    std.mem.sortUnstable(usize, lines.items, {}, std.sort.asc(usize));
    return lines.toOwnedSlice(gpa);
}

fn within(ranges: []const [2]Ast.TokenIndex, token: Ast.TokenIndex) bool {
    for (ranges) |range| {
        if (range[0] <= token and token <= range[1]) return true;
    }
    return false;
}

test "std sha2 references outside test declarations bypass the SHA-256 entry point" {
    const source =
        \\const std = @import("std");
        \\const sha2 = std.crypto.hash.sha2;
        \\const features = .{ .sha2, .sha3 };
        \\pub fn digest(bytes: []const u8) [32]u8 {
        \\    var out: [32]u8 = undefined;
        \\    std.crypto.hash
        \\        .sha2.Sha256.hash(bytes, &out, .{});
        \\    return out;
        \\}
        \\test "oracle" {
        \\    _ = std.crypto.hash.sha2.Sha256;
        \\}
        \\const Oracle = struct {
        \\    test {
        \\        _ = @import("std").crypto.hash.sha2.Sha224;
        \\    }
        \\};
        \\const hmac = std.crypto.auth.hmac.sha2.HmacSha256;
        \\const capability = std.os.linux.HWCAP.SHA2;
        \\const entry = @import("hash_abi.zig").Sha256;
    ;
    const lines = try bypassLines(std.testing.allocator, source);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 2, 7, 18 }, lines);
}

test "only test oracles and the documented hash owners are exempt" {
    for ([_][]const u8{
        "test/protean/native_tasks.zig",
        "runtime/native/hash_accelerated.zig",
        "tools/native/dependencies.zig",
        "tools/native/emit.zig",
    }) |path| try std.testing.expect(exempt(path));
    for ([_][]const u8{
        "runtime/native/store.zig",
        "runtime/native/hash.zig",
        "examples/adaptive/work.zig",
        "tools/evaluation/recurrence_driver.zig",
        "tools/native/build_entry.zig",
        "src/protean.zig",
        "build_protean.zig",
        "testing/runtime.zig",
    }) |path| try std.testing.expect(!exempt(path));
}

test "unparseable sources fail instead of passing unaudited" {
    try std.testing.expectError(
        error.InvalidSource,
        bypassLines(std.testing.allocator, "const broken = std.crypto.hash.sha2.;"),
    );
}
