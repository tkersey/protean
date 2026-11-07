const std = @import("std");
const json = @import("json.zig");
const Allocator = std.mem.Allocator;
pub const issuer = "https://auth.openai.com";
pub const stdout_bytes_max = 128 * 1024;
pub const models_bytes_max = 1024 * 1024;
pub const bearer_bytes_max = 32_768;

pub const Phase = enum {
    pending,
    signed_out,
    ready,
    plan_usage_disabled,
    refresh_required,
    reauthentication_required,
};
pub const Status = struct { phase: Phase, binding: ?[32]u8 };
pub const Model = struct { slug: []const u8, display_name: []const u8 };
pub const Catalog = struct {
    allocator: Allocator,
    items: []Model,

    pub fn deinit(self: *Catalog) void {
        for (self.items) |item| {
            self.allocator.free(item.slug);
            self.allocator.free(item.display_name);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
    pub fn contains(self: Catalog, slug: []const u8) bool {
        for (self.items) |item| if (std.mem.eql(u8, item.slug, slug)) return true;
        return false;
    }
};
pub const Lease = struct {
    allocator: Allocator,
    token: []const u8,
    expires_at: i64,

    pub fn valid(self: Lease, now_seconds: i64) bool {
        return self.expires_at > now_seconds;
    }
    pub fn deinit(self: *Lease) void {
        std.crypto.secureZero(u8, @constCast(self.token));
        self.allocator.rawFree(@constCast(self.token), .@"1", @returnAddress());
        self.* = undefined;
    }
};

pub fn validLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 64) return false;
    if (!lowerAlphanumeric(label[0])) return false;
    for (label) |byte| if (!lowerAlphanumeric(byte) and byte != '_' and byte != '-')
        return false;
    return true;
}

fn lowerAlphanumeric(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9');
}

pub fn binding(client_id: []const u8, subject: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("protean.billing-binding.v1\x00");
    for ([_][]const u8{ "chatgpt_plan", issuer, client_id, subject }) |component| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(component.len), .big);
        hash.update(&length);
        hash.update(component);
    }
    return hash.finalResult();
}

pub fn version(bytes: []const u8) !void {
    for ([_][]const u8{ "0.1.1\n", "0.1.2\n", "0.1.3\n", "0.1.4\n", "0.1.5\n" }) |release|
        if (std.mem.eql(u8, bytes, release)) return;
    return error.UnsupportedSiwcVersion;
}

fn field(value: json.Value, name: []const u8) !json.Value {
    return json.get(value, name) orelse error.InvalidSiwcProtocol;
}
fn string(value: json.Value, name: []const u8) ![]const u8 {
    const item = try field(value, name);
    if (item != .string) return error.InvalidSiwcProtocol;
    return item.string;
}
fn nonempty(value: json.Value, name: []const u8) ![]const u8 {
    const result = try string(value, name);
    if (result.len == 0) return error.InvalidSiwcProtocol;
    return result;
}
fn exact(value: json.Value, name: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, try string(value, name), expected)) return error.InvalidSiwcProtocol;
}
fn integer(value: json.Value) !i64 {
    if (value != .number_string) return error.InvalidSiwcProtocol;
    return std.fmt.parseInt(i64, value.number_string, 10) catch error.InvalidSiwcProtocol;
}
fn nullableString(value: json.Value, name: []const u8) !?[]const u8 {
    const item = try field(value, name);
    if (item == .null) return null;
    if (item != .string) return error.InvalidSiwcProtocol;
    return item.string;
}
fn selected(value: json.Value, account: []const u8) !void {
    try exact(value, "app", "protean");
    try exact(value, "account", account);
}
fn parse(a: Allocator, bytes: []const u8, maximum: usize) !std.json.Parsed(json.Value) {
    return json.parse(a, bytes, .{ .bytes = maximum }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSiwcProtocol,
    };
}

pub fn status(a: Allocator, bytes: []const u8, account: []const u8) !Status {
    var wiping: WipingAllocator = .{ .parent = a };
    var parsed = try parse(wiping.allocator(), bytes, stdout_bytes_max);
    defer parsed.deinit();
    const value = parsed.value;
    try selected(value, account);
    const phase = std.meta.stringToEnum(Phase, try string(value, "phase")) orelse
        return error.InvalidSiwcProtocol;
    const client_id = try nullableString(value, "client_id");
    const subject = try nullableString(value, "subject");
    _ = try nullableString(value, "email");
    const expires = try field(value, "expires_at");
    if (expires != .null) _ = try integer(expires);
    const digest = if (client_id != null and subject != null and
        client_id.?.len > 0 and subject.?.len > 0)
        binding(client_id.?, subject.?)
    else
        null;
    return .{ .phase = phase, .binding = digest };
}

fn hasScope(scope: []const u8, required: []const u8) bool {
    var words = std.mem.splitScalar(u8, scope, ' ');
    while (words.next()) |word| if (std.mem.eql(u8, word, required)) return true;
    return false;
}

pub fn credential(
    a: Allocator,
    bytes: []const u8,
    account: []const u8,
    expected: [32]u8,
    now_seconds: i64,
) !Lease {
    var wiping: WipingAllocator = .{ .parent = a };
    var parsed = try parse(wiping.allocator(), bytes, stdout_bytes_max);
    defer parsed.deinit();
    const value = parsed.value;
    if (try integer(try field(value, "version")) != 1) return error.InvalidSiwcProtocol;
    try exact(value, "provider", "chatgpt");
    try selected(value, account);
    try exact(value, "issuer", issuer);
    try exact(value, "resource", "https://api.openai.com/v1");
    try exact(value, "token_type", "Bearer");
    const digest = binding(try nonempty(value, "client_id"), try nonempty(value, "subject"));
    if (!std.mem.eql(u8, &digest, &expected)) return error.SiwcBindingMismatch;
    const token = try nonempty(value, "access_token");
    if (token.len > bearer_bytes_max) return error.InvalidSiwcProtocol;
    for (token) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidSiwcProtocol;
    const scope = try string(value, "scope");
    if (!hasScope(scope, "resource.invoke") or !hasScope(scope, "chatgpt.tokens.use.direct"))
        return error.InvalidSiwcProtocol;
    const expires_at = try integer(try field(value, "expires_at"));
    if (expires_at <= now_seconds) return error.SiwcCredentialExpired;
    return .{ .allocator = a, .token = try a.dupe(u8, token), .expires_at = expires_at };
}

pub fn models(a: Allocator, bytes: []const u8) !Catalog {
    var wiping: WipingAllocator = .{ .parent = a };
    var parsed = try parse(wiping.allocator(), bytes, models_bytes_max);
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .array or value.array.items.len > 512) return error.InvalidSiwcProtocol;
    const items = try a.alloc(Model, value.array.items.len);
    var result: Catalog = .{ .allocator = a, .items = items[0..0] };
    errdefer {
        for (result.items) |item| {
            a.free(item.slug);
            a.free(item.display_name);
        }
        a.free(items);
    }
    for (value.array.items, 0..) |item, index| {
        const slug = try nonempty(item, "slug");
        const display = try nonempty(item, "display_name");
        if (std.mem.trim(u8, slug, " \t\r\n").len != slug.len)
            return error.InvalidSiwcProtocol;
        for (result.items) |prior| if (std.mem.eql(u8, prior.slug, slug))
            return error.InvalidSiwcProtocol;
        const owned_slug = try a.dupe(u8, slug);
        errdefer a.free(owned_slug);
        items[index] = .{ .slug = owned_slug, .display_name = try a.dupe(u8, display) };
        result.items = items[0 .. index + 1];
    }
    return result;
}

pub const WipingAllocator = struct {
    parent: Allocator,

    pub fn allocator(self: *WipingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn allocate(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawAlloc(len, alignment, ret);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, memory);
        self.parent.rawFree(memory, alignment, ret);
    }
};

const sample =
    \\{"version":1,"provider":"chatgpt","app":"protean","account":"personal",
    \\"issuer":"https://auth.openai.com","client_id":"client","subject":"subject",
    \\"access_token":"synthetic-token","token_type":"Bearer",
    \\"resource":"https://api.openai.com/v1",
    \\"scope":"resource.invoke chatgpt.tokens.use.direct","expires_at":200}
;

test "credential owns independent bearer and checks exact identity and expiry" {
    const a = std.testing.allocator;
    var lease = try credential(a, sample, "personal", binding("client", "subject"), 199);
    defer lease.deinit();
    try std.testing.expectEqualStrings("synthetic-token", lease.token);
    try std.testing.expect(lease.valid(199));
    try std.testing.expect(!lease.valid(200));
    try std.testing.expectError(
        error.SiwcCredentialExpired,
        credential(a, sample, "personal", binding("client", "subject"), 200),
    );
    try std.testing.expectError(
        error.SiwcBindingMismatch,
        credential(a, sample, "personal", binding("other", "subject"), 199),
    );
    try std.testing.expectError(
        error.InvalidSiwcProtocol,
        credential(a, sample, "other", binding("client", "subject"), 199),
    );
    try std.testing.expectError(
        error.InvalidSiwcProtocol,
        credential(a, sample ++ "{}", "personal", binding("client", "subject"), 199),
    );
}

test "status retains signed out registration and models preserve approved slugs" {
    const a = std.testing.allocator;
    const bytes =
        \\{"app":"protean","account":"personal","client_id":"client",
        \\"subject":"subject","email":null,"phase":"signed_out","expires_at":null}
    ;
    const result = try status(a, bytes, "personal");
    try std.testing.expectEqual(Phase.signed_out, result.phase);
    try std.testing.expectEqual(binding("client", "subject"), result.binding.?);
    var catalog = try models(a, "[{\"slug\":\"a\",\"display_name\":\"A\"}]");
    defer catalog.deinit();
    try std.testing.expect(catalog.contains("a"));
    try std.testing.expect(!catalog.contains("A"));
    try std.testing.expectError(
        error.InvalidSiwcProtocol,
        models(a, "[{\"slug\":\"a\",\"display_name\":\"A\"}," ++
            "{\"slug\":\"a\",\"display_name\":\"B\"}]"),
    );
}

test "qualified releases and upstream account labels reject ambiguous forms" {
    for ([_][]const u8{ "0.1.1\n", "0.1.2\n", "0.1.3\n", "0.1.4\n", "0.1.5\n" }) |release|
        try version(release);
    for ([_][]const u8{ "0.1.0\n", "0.1.6\n", "0.2.0\n", "0.1.3", "siwc 0.1.3\n" }) |release|
        try std.testing.expectError(error.UnsupportedSiwcVersion, version(release));
    for ([_][]const u8{ "", "Personal", "_personal", "a/b", ".", "a\x00b" }) |label|
        try std.testing.expect(!validLabel(label));
    try std.testing.expect(validLabel("personal-1_a"));
    try std.testing.expectEqualStrings(
        "a629ed4c6918af66faf89687cf07b8e9655b773ccfad1c511bfe19ad2f7daebb",
        &std.fmt.bytesToHex(binding("client", "subject"), .lower),
    );
    try std.testing.expect(!std.mem.eql(u8, &binding("ab", "c"), &binding("a", "bc")));
}

test "credential machine rejection includes duplicate keys scopes and token injection" {
    const a = std.testing.allocator;
    const Case = struct { old: []const u8, replacement: []const u8 };
    const cases = [_]Case{
        .{ .old = "\"version\":1", .replacement = "\"version\":1,\"version\":1" },
        .{ .old = "\"version\":1", .replacement = "\"version\":2" },
        .{ .old = "\"version\":1", .replacement = "\"schema_version\":1" },
        .{ .old = "\"version\":1", .replacement = "\"version\":1.0" },
        .{ .old = "chatgpt\"", .replacement = "other\"" },
        .{ .old = "auth.openai.com", .replacement = "auth.example.com" },
        .{ .old = "api.openai.com/v1", .replacement = "api.example.com/v1" },
        .{ .old = "Bearer", .replacement = "bearer" },
        .{ .old = "synthetic-token", .replacement = "" },
        .{ .old = "synthetic-token", .replacement = "a\\r\\nAuthorization: x" },
        .{ .old = "synthetic-token", .replacement = "雪" },
        .{ .old = "resource.invoke ", .replacement = "" },
        .{ .old = "chatgpt.tokens.use.direct", .replacement = "chatgpt.tokens.use.directly" },
        .{ .old = "200}", .replacement = "9223372036854775808}" },
        .{ .old = "200}", .replacement = "200.5}" },
    };
    for (cases) |case| {
        const changed = try std.mem.replaceOwned(u8, a, sample, case.old, case.replacement);
        defer a.free(changed);
        try std.testing.expectError(
            error.InvalidSiwcProtocol,
            credential(a, changed, "personal", binding("client", "subject"), 100),
        );
    }
}

test "bearer maximum is exact and rejected buffers never become leases" {
    const a = std.testing.allocator;
    const token = try a.alloc(u8, bearer_bytes_max + 1);
    defer a.free(token);
    @memset(token, 't');
    for ([_]usize{ bearer_bytes_max, bearer_bytes_max + 1 }) |length| {
        const bytes = try std.mem.replaceOwned(u8, a, sample, "synthetic-token", token[0..length]);
        defer a.free(bytes);
        if (length == bearer_bytes_max) {
            var lease = try credential(a, bytes, "personal", binding("client", "subject"), 100);
            defer lease.deinit();
            try std.testing.expectEqual(bearer_bytes_max, lease.token.len);
        } else {
            try std.testing.expectError(
                error.InvalidSiwcProtocol,
                credential(a, bytes, "personal", binding("client", "subject"), 100),
            );
        }
    }
    var memory: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var lease: Lease = .{
        .allocator = fixed.allocator(),
        .token = try fixed.allocator().dupe(u8, "synthetic-token"),
        .expires_at = 200,
    };
    lease.deinit();
    try std.testing.expect(std.mem.allEqual(u8, memory[0.."synthetic-token".len], 0));
}

fn allocationProbe(a: Allocator) !void {
    var lease = try credential(a, sample, "personal", binding("client", "subject"), 100);
    defer lease.deinit();
    var catalog = try models(a, "[{\"slug\":\"a\",\"display_name\":\"A\"}]");
    defer catalog.deinit();
}

test "protocol owners release every allocation on partial construction" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
