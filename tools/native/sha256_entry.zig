const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

const exempt_paths = [_][]const u8{
    "runtime/native/hash_accelerated.zig",
    "tools/native/dependencies.zig",
    "tools/native/emit.zig",
};
const oracle_directory = "test/";
const allowed_crypto = [_][]const []const u8{
    &.{"secureZero"},
    &.{ "sign", "Ed25519" },
    &.{ "hash", "sha3", "Sha3_256" },
};

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
            "{s}:{d}: runtime SHA-256 must use hash_abi.Sha256; " ++
                "only allowlisted std.crypto members may be referenced\n",
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
    const audit = try Audit.init(arena.allocator(), &tree);
    var lines: std.ArrayList(usize) = .empty;
    errdefer lines.deinit(gpa);
    for (0..tree.nodes.len) |index| {
        const token = try audit.bypass(arena.allocator(), @fromBackingInt(@intCast(index))) orelse
            continue;
        if (within(audit.oracles, token)) continue;
        try lines.append(gpa, tree.tokenLocation(0, token).line + 1);
    }
    std.mem.sortUnstable(usize, lines.items, {}, std.sort.asc(usize));
    var distinct: usize = 0;
    for (lines.items) |line| {
        if (distinct != 0 and lines.items[distinct - 1] == line) continue;
        lines.items[distinct] = line;
        distinct += 1;
    }
    lines.shrinkRetainingCapacity(distinct);
    return lines.toOwnedSlice(gpa);
}

const Declaration = struct { name: []const u8, value: Node.Index };

const Audit = struct {
    tree: *const Ast,
    oracles: []const [2]Ast.TokenIndex,
    field_parent: []?Node.Index,
    std_use_permitted: []bool,
    std_roots: []const []const u8,

    fn init(a: std.mem.Allocator, tree: *const Ast) !Audit {
        var oracles: std.ArrayList([2]Ast.TokenIndex) = .empty;
        var declarations: std.ArrayList(Declaration) = .empty;
        const field_parent = try a.alloc(?Node.Index, tree.nodes.len);
        @memset(field_parent, null);
        const permitted = try a.alloc(bool, tree.nodes.len);
        @memset(permitted, false);
        for (0..tree.nodes.len) |index| {
            const node: Node.Index = @fromBackingInt(@intCast(index));
            if (tree.nodeTag(node) == .test_decl)
                try oracles.append(a, .{ tree.firstToken(node), tree.lastToken(node) });
            if (tree.nodeTag(node) == .field_access) {
                const object = tree.nodeData(node).node_and_token[0];
                field_parent[@backingInt(object)] = node;
                permitted[@backingInt(object)] = true;
            }
            var buffer: [2]Node.Index = undefined;
            if (builtinParams(tree, &buffer, node, "@field")) |params| {
                if (params.len != 0) permitted[@backingInt(params[0])] = true;
            }
            const declaration = tree.fullVarDecl(node) orelse continue;
            const value = declaration.ast.init_node.unwrap() orelse continue;
            permitted[@backingInt(value)] = true;
            const name = identifierName(tree.tokenSlice(declaration.ast.mut_token + 1));
            try declarations.append(a, .{ .name = name, .value = value });
        }
        return .{
            .tree = tree,
            .oracles = oracles.items,
            .field_parent = field_parent,
            .std_use_permitted = permitted,
            .std_roots = try stdRoots(a, tree, declarations.items),
        };
    }

    fn stdRoots(
        a: std.mem.Allocator,
        tree: *const Ast,
        declarations: []const Declaration,
    ) ![]const []const u8 {
        var roots: std.ArrayList([]const u8) = .empty;
        for (0..declarations.len + 1) |_| {
            const known = roots.items.len;
            for (declarations) |declaration| {
                if (contains(roots.items, declaration.name)) continue;
                if (stdRoot(tree, roots.items, declaration.value))
                    try roots.append(a, declaration.name);
            }
            if (roots.items.len == known) break;
        }
        return roots.items;
    }

    fn bypass(self: Audit, a: std.mem.Allocator, node: Node.Index) !?Ast.TokenIndex {
        const tree = self.tree;
        if (tree.nodeTag(node) == .field_access) {
            const field = tree.nodeData(node).node_and_token[1];
            if (!std.mem.eql(u8, tree.tokenSlice(field), "crypto")) return null;
            return if (self.allowedCrypto(node)) null else field;
        }
        var buffer: [2]Node.Index = undefined;
        if (builtinParams(tree, &buffer, node, "@field")) |params| {
            if (params.len != 2) return tree.nodeMainToken(node);
            if (tree.nodeTag(params[1]) == .string_literal) {
                const literal = tree.tokenSlice(tree.nodeMainToken(params[1]));
                const parsed = std.zig.string_literal.parseAlloc(a, literal);
                const name = parsed catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidLiteral => return tree.nodeMainToken(node),
                };
                return if (std.mem.eql(u8, name, "crypto")) tree.nodeMainToken(node) else null;
            }
            return if (stdRoot(tree, self.std_roots, params[0])) tree.nodeMainToken(node) else null;
        }
        if (stdRoot(tree, self.std_roots, node) and !self.std_use_permitted[@backingInt(node)])
            return tree.firstToken(node);
        return null;
    }

    fn allowedCrypto(self: Audit, crypto: Node.Index) bool {
        var members: [8][]const u8 = undefined;
        var count: usize = 0;
        var current = crypto;
        while (count < members.len) {
            const parent = self.field_parent[@backingInt(current)] orelse break;
            members[count] = self.tree.tokenSlice(self.tree.nodeData(parent).node_and_token[1]);
            count += 1;
            current = parent;
        }
        allowed: for (allowed_crypto) |path| {
            if (count < path.len) continue;
            for (path, members[0..path.len]) |expected, actual| {
                if (!std.mem.eql(u8, expected, actual)) continue :allowed;
            }
            return true;
        }
        return false;
    }
};

fn builtinParams(
    tree: *const Ast,
    buffer: *[2]Node.Index,
    node: Node.Index,
    name: []const u8,
) ?[]const Node.Index {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name)) return null;
    return tree.builtinCallParams(buffer, node);
}

fn stdRoot(tree: *const Ast, roots: []const []const u8, node: Node.Index) bool {
    if (tree.nodeTag(node) == .identifier)
        return contains(roots, identifierName(tree.tokenSlice(tree.nodeMainToken(node))));
    var buffer: [2]Node.Index = undefined;
    const params = builtinParams(tree, &buffer, node, "@import") orelse return false;
    if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(params[0])), "\"std\"");
}

fn identifierName(token: []const u8) []const u8 {
    if (std.mem.startsWith(u8, token, "@\"") and std.mem.endsWith(u8, token, "\""))
        return token[2 .. token.len - 1];
    return token;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn within(ranges: []const [2]Ast.TokenIndex, token: Ast.TokenIndex) bool {
    for (ranges) |range| {
        if (range[0] <= token and token <= range[1]) return true;
    }
    return false;
}

test "every std.crypto reference outside the allowlist bypasses the SHA-256 entry point" {
    const source =
        \\const std = @import("std");
        \\const sha2 = std.crypto.hash.sha2;
        \\const hkdf = std.crypto.kdf.hkdf.HkdfSha256;
        \\const hmac = std.crypto.auth.hmac.sha2.HmacSha256;
        \\const ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
        \\const reflected = @field(std.crypto.hash, "sha2");
        \\const named = @field(std, "crypto");
        \\const imported = @import("std").crypto;
        \\const alias = std;
        \\const aliased = alias.crypto.hash.sha2.Sha256;
        \\const computed = @field(alias, "cry" ++ "pto");
        \\const escaped = .{ .namespace = @import("std") };
        \\const grouped = (std.crypto).sign.Ed25519;
        \\pub fn digest(bytes: []const u8) [32]u8 {
        \\    var out: [32]u8 = undefined;
        \\    std.crypto.hash
        \\        .sha2.Sha256.hash(bytes, &out, .{});
        \\    return out;
        \\}
        \\const escaped_alias = [_]type{alias};
        \\const truncated = std.crypto.sign;
    ;
    const lines = try bypassLines(std.testing.allocator, source);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 16, 20, 21 },
        lines,
    );
}

test "allowlisted std.crypto members and test oracles remain available" {
    const source =
        \\const std = @import("std");
        \\const Ed25519 = std.crypto.sign.Ed25519;
        \\const KeyPair = std.crypto.sign.Ed25519.KeyPair;
        \\fn wipe(bytes: []u8) void {
        \\    std.crypto.secureZero(u8, bytes);
        \\}
        \\fn sha3(bytes: []const u8, out: *[32]u8) void {
        \\    std.crypto.hash.sha3.Sha3_256.hash(bytes, out, .{});
        \\}
        \\const features = .{ .sha2, .sha3 };
        \\const capability = std.os.linux.HWCAP.SHA2;
        \\const entry = @import("hash_abi.zig").Sha256;
        \\const memory = @field(std, "mem");
        \\fn field(value: anytype, comptime name: []const u8) void {
        \\    _ = @field(value, name);
        \\}
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
