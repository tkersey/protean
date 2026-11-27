const std = @import("std");
const Ast = std.zig.Ast;

const exempt_paths = [_][]const u8{
    "runtime/native/crypto.zig",
    "runtime/native/hash_accelerated.zig",
    "tools/native/dependencies.zig",
    "tools/native/emit.zig",
    "tools/native/sha256_entry.zig",
};
const oracle_directory = "test/";
const forbidden_identifier = "crypto";
const forbidden_literals = [_][]const u8{ "crypto", "sha2" };

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
            "{s}:{d}: std.crypto is reachable only through runtime/native/crypto.zig\n",
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const oracles = try oracleRanges(arena.allocator(), &tree);
    var lines: std.ArrayList(usize) = .empty;
    errdefer lines.deinit(gpa);
    for (0..tree.tokens.len) |index| {
        const token: Ast.TokenIndex = @intCast(index);
        if (within(oracles, token)) continue;
        if (!try forbidden(arena.allocator(), &tree, token)) continue;
        const line = tree.tokenLocation(0, token).line + 1;
        if (lines.items.len == 0 or lines.getLast() != line) try lines.append(gpa, line);
    }
    return lines.toOwnedSlice(gpa);
}

fn oracleRanges(a: std.mem.Allocator, tree: *const Ast) ![]const [2]Ast.TokenIndex {
    var ranges: std.ArrayList([2]Ast.TokenIndex) = .empty;
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (tree.nodeTag(node) == .test_decl)
            try ranges.append(a, .{ tree.firstToken(node), tree.lastToken(node) });
    }
    return ranges.items;
}

fn forbidden(a: std.mem.Allocator, tree: *const Ast, token: Ast.TokenIndex) !bool {
    const slice = tree.tokenSlice(token);
    switch (tree.tokenTag(token)) {
        .identifier => {
            const name = if (slice[0] == '@') try decoded(a, slice[1..]) else slice;
            return std.mem.eql(u8, name, forbidden_identifier);
        },
        .string_literal => return forbiddenLiteral(try decoded(a, slice)),
        .multiline_string_literal_line => {
            if (multilineLine(tree, token -% 1) or multilineLine(tree, token + 1)) return false;
            return forbiddenLiteral(slice[2..]);
        },
        else => return false,
    }
}

fn decoded(a: std.mem.Allocator, literal: []const u8) ![]const u8 {
    return std.zig.string_literal.parseAlloc(a, literal) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLiteral => error.InvalidSource,
    };
}

fn multilineLine(tree: *const Ast, token: Ast.TokenIndex) bool {
    if (token >= tree.tokens.len) return false;
    return tree.tokenTag(token) == .multiline_string_literal_line;
}

fn forbiddenLiteral(value: []const u8) bool {
    for (forbidden_literals) |literal| {
        if (std.mem.eql(u8, value, literal)) return true;
    }
    return false;
}

fn within(ranges: []const [2]Ast.TokenIndex, token: Ast.TokenIndex) bool {
    for (ranges) |range| {
        if (range[0] <= token and token <= range[1]) return true;
    }
    return false;
}

test "each spelling of crypto or sha2 outside the facade is rejected" {
    const forms = [_][:0]const u8{
        "const direct = std.crypto.hash.sha2.Sha256;",
        "const quoted = std.@\"crypto\".hash.sha2.Sha256;",
        "const escaped = std.@\"\\x63rypto\".sign.Ed25519;",
        "const named = @field(std, \"crypto\");",
        "const escaped_name = @field(std, \"\\x63ry\\u{70}to\");",
        "const through = @field(@import(\"namespace.zig\").s, \"crypto\");",
        "const multiline = @field(@import(\"namespace.zig\").s,\n    \\\\crypto\n);",
        "const imported = @field(@import(\"\\x73td\"), \"crypto\");",
        "const nested = @field(@import(\"namespace.zig\").hash, \"sha2\");",
        "const declared = struct { const crypto = 0; };",
        "const literal = .crypto;",
    };
    const expected = [_]usize{ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1 };
    for (forms, expected) |form, line| {
        const lines = try bypassLines(std.testing.allocator, form);
        defer std.testing.allocator.free(lines);
        try std.testing.expectEqualSlices(usize, &.{line}, lines);
    }
}

test "the facade, sha2 identifiers, other literals and test oracles remain available" {
    const source =
        \\const std = @import("std");
        \\const facade = @import("crypto.zig");
        \\const Ed25519 = facade.Ed25519;
        \\const Sha3_256 = facade.Sha3_256;
        \\const Sha256 = facade.Sha256;
        \\fn wipe(bytes: []u8) void {
        \\    facade.secureZero(u8, bytes);
        \\}
        \\const features = .{ .sha2, .sha3 };
        \\const capability = std.os.linux.HWCAP.SHA2;
        \\const tag = @field(std.meta.Tag(union(enum) { crypto_free: u8 }), "crypto_free");
        \\const lines =
        \\    \\crypto
        \\    \\sha2
        \\;
        \\const words = .{ "crypto.zig", "sha256", "Crypto" };
        \\test "oracle" {
        \\    _ = std.crypto.hash.sha2.Sha256;
        \\    _ = @field(std, "crypto");
        \\}
        \\const Oracle = struct {
        \\    test {
        \\        _ = @import("std").crypto.hash.sha2.Sha224;
        \\    }
        \\};
    ;
    const lines = try bypassLines(std.testing.allocator, source);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{}, lines);
}

test "names computed at compile time are outside the audit" {
    const source =
        \\const std = @import("std");
        \\const computed = @field(std, "cry" ++ "pto");
    ;
    const lines = try bypassLines(std.testing.allocator, source);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{}, lines);
}

test "only test oracles, the facade and the documented hash owners are exempt" {
    for ([_][]const u8{
        "test/protean/native_tasks.zig",
        "runtime/native/crypto.zig",
        "runtime/native/hash_accelerated.zig",
        "tools/native/dependencies.zig",
        "tools/native/emit.zig",
        "tools/native/sha256_entry.zig",
    }) |path| try std.testing.expect(exempt(path));
    for ([_][]const u8{
        "runtime/native/store.zig",
        "runtime/native/hash.zig",
        "runtime/native/hash_abi.zig",
        "examples/adaptive/work.zig",
        "tools/evaluation/recurrence_driver.zig",
        "tools/native/build_entry.zig",
        "src/protean.zig",
        "build_protean.zig",
        "testing/runtime.zig",
    }) |path| try std.testing.expect(!exempt(path));
}

test "unparseable sources and undecodable literals fail instead of passing unaudited" {
    for ([_][:0]const u8{
        "const broken = std.crypto.hash.sha2.;",
        "const broken = \"\\q\";",
        "const broken = std.@\"\\q\";",
    }) |source| {
        const result = bypassLines(std.testing.allocator, source);
        try std.testing.expectError(error.InvalidSource, result);
    }
}
