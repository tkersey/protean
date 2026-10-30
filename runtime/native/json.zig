//! Bounded JSON admission shared by client framing and native provider captures.
//! No number is rounded, and duplicate object names never become trusted data.
const std = @import("std");
pub const Value = std.json.Value;
pub const Limits = struct {
    bytes: usize = 1024 * 1024 - 1,
    depth: usize = 32,
    tokens: usize = 65_536,
    members: usize = 4096,
};
pub const Error = error{ InvalidJson, DuplicateKey, Capacity } || std.mem.Allocator.Error;

// Sixteen results plus their RPC envelopes fit the unchanged frame profile.
// Payload reserves also cover snapshot, question, event and notification wrappers.
pub const projection_limits: Limits = .{ .bytes = 60 * 1024, .depth = 29, .tokens = 3800 };
pub const payload_limits: Limits = .{ .bytes = 48 * 1024, .depth = 24, .tokens = 2048 };

/// Executable-linked generated assets are not peer frames. Their byte extent
/// and the host allocator bound admission; schema nesting is not value nesting.
pub fn parseAsset(
    a: std.mem.Allocator,
    bytes: []const u8,
    maximum: usize,
) Error!std.json.Parsed(Value) {
    return parse(a, bytes, .{
        .bytes = maximum,
        .depth = maximum,
        .tokens = maximum,
        .members = maximum,
    });
}

fn countStructure(
    allocator: std.mem.Allocator,
    value: Value,
    remaining: *usize,
    limits: Limits,
) Error!void {
    const Frame = struct { values: []const Value, depth: usize, index: usize = 0 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    const root = [_]Value{value};
    try stack.append(allocator, .{ .values = &root, .depth = 0 });
    while (stack.items.len != 0) {
        const cursor = &stack.items[stack.items.len - 1];
        if (cursor.index == cursor.values.len) {
            _ = stack.pop();
            continue;
        }
        const child = cursor.values[cursor.index];
        const depth = cursor.depth;
        cursor.index += 1;
        const container = child == .object or child == .array;
        if (container and depth >= limits.depth) return error.Capacity;
        const own: usize = if (child == .object)
            2 + child.object.count()
        else if (container)
            2
        else
            1;
        if (own > remaining.*) return error.Capacity;
        remaining.* -= own;
        const children: []const Value = switch (child) {
            .object => |map| blk: {
                if (map.count() > limits.members) return error.Capacity;
                break :blk map.values();
            },
            .array => |items| items.items,
            else => continue,
        };
        if (children.len != 0)
            try stack.append(allocator, .{ .values = children, .depth = depth + 1 });
    }
}

pub fn fits(a: std.mem.Allocator, value: Value, limits: Limits) !bool {
    var remaining = limits.tokens;
    countStructure(a, value, &remaining, limits) catch |err| switch (err) {
        error.Capacity => return false,
        else => return err,
    };
    var buffer: [4096]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    try writeCanonical(a, value, &counter.writer);
    return counter.fullCount() <= limits.bytes;
}

pub fn frame(a: std.mem.Allocator, value: Value) ![]u8 {
    if (!try fits(a, value, .{})) return error.Capacity;
    return canonicalBounded(a, value, (Limits{}).bytes);
}

test "outgoing structural accounting agrees with independent frame scanning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dense: Value = .{ .array = .init(a) };
    for (0..10_000) |_| try dense.array.append(.{ .integer = 0 });
    try std.testing.expect(try fits(a, dense, .{}));
    try std.testing.expect(!try fits(a, dense, payload_limits));
    var batch: Value = .{ .array = .init(a) };
    for (0..16) |_| try batch.array.append(dense);
    const encoded = try canonical(a, batch);
    try std.testing.expect(encoded.len < (Limits{}).bytes);
    try std.testing.expectError(error.Capacity, parse(a, encoded, .{}));
    try std.testing.expectError(error.Capacity, frame(a, batch));
    var nested: Value = .null;
    for (0..33) |_| {
        var parent = object();
        try put(a, &parent, "x", nested);
        nested = parent;
    }
    try std.testing.expect(!try fits(a, nested, .{}));
    try std.testing.expectError(error.Capacity, parse(a, try canonical(a, nested), .{}));
    const limits: Limits = .{ .tokens = 6 };
    const exact = (try parse(a, "{\"x\":[0]}", limits)).value;
    try std.testing.expect(try fits(a, exact, limits));
    try std.testing.expect(!try fits(a, exact, .{ .tokens = 5 }));
    try std.testing.expectError(error.Capacity, parse(a, "{\"x\":[0]}", .{ .tokens = 5 }));
}

fn scan(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!void {
    if (bytes.len > limits.bytes) return error.Capacity;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidJson;
    // Scan before tree allocation. Scanner stack allocation is also bounded by
    // stopping on the first over-depth opening token.
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    var scanning = true;
    while (scanning) {
        const token = scanner.next() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
        switch (token) {
            .end_of_document => scanning = false,
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.depth) return error.Capacity;
                tokens += 1;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
                tokens += 1;
            },
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            .partial_number,
            => {},
            else => tokens += 1,
        }
        if (tokens > limits.tokens) return error.Capacity;
    }
}

fn parseOptions(limits: Limits) std.json.ParseOptions {
    return .{
        .allocate = .alloc_always,
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.bytes,
    };
}

fn parseError(err: anyerror) Error {
    return switch (err) {
        error.DuplicateField => error.DuplicateKey,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) Error!std.json.Parsed(Value) {
    try scan(allocator, bytes, limits);
    var parsed = std.json.parseFromSlice(
        Value,
        allocator,
        bytes,
        parseOptions(limits),
    ) catch |err| return parseError(err);
    errdefer parsed.deinit();
    try memberBounds(allocator, parsed.value, limits.members);
    return parsed;
}

pub fn parseInto(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Value {
    try scan(allocator, bytes, limits);
    const value = std.json.parseFromSliceLeaky(
        Value,
        allocator,
        bytes,
        parseOptions(limits),
    ) catch |err| return parseError(err);
    try memberBounds(allocator, value, limits.members);
    return value;
}

test "owned and arena JSON parsing share admission" {
    const cases = [_]struct { bytes: []const u8, limits: Limits = .{}, failure: ?Error = null }{
        .{ .bytes = "{\"n\":18446744073709551615,\"s\":\"雪\",\"a\":[true,null]}" },
        .{ .bytes = "[[[]]]", .limits = .{ .depth = 3 } },
        .{ .bytes = "[[[]]]", .limits = .{ .depth = 2 }, .failure = error.Capacity },
        .{ .bytes = "{\"a\":1,\"a\":2}", .failure = error.DuplicateKey },
        .{ .bytes = "{\"a\":1,\"b\":2}", .limits = .{ .members = 1 }, .failure = error.Capacity },
        .{ .bytes = "[0,1,2]", .limits = .{ .tokens = 3 }, .failure = error.Capacity },
        .{ .bytes = "null", .limits = .{ .bytes = 3 }, .failure = error.Capacity },
        .{ .bytes = "\"\\ud800\"", .failure = error.InvalidJson },
        .{ .bytes = "\"\xff\"", .failure = error.InvalidJson },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (case.failure) |failure| {
            try std.testing.expectError(
                failure,
                parse(std.testing.allocator, case.bytes, case.limits),
            );
            try std.testing.expectError(
                failure,
                parseInto(arena.allocator(), case.bytes, case.limits),
            );
        } else {
            var owned = try parse(std.testing.allocator, case.bytes, case.limits);
            defer owned.deinit();
            const direct = try parseInto(arena.allocator(), case.bytes, case.limits);
            try std.testing.expectEqualStrings(
                try canonical(arena.allocator(), owned.value),
                try canonical(arena.allocator(), direct),
            );
        }
    }
}

fn memberBounds(allocator: std.mem.Allocator, value: Value, maximum: usize) Error!void {
    const Frame = struct { items: []const Value, index: usize = 0 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    const root = [_]Value{value};
    var cursor: Frame = .{ .items = &root };
    while (cursor.index != cursor.items.len or stack.items.len != 0) {
        if (cursor.index == cursor.items.len) {
            cursor = stack.pop() orelse return;
            continue;
        }
        const child = cursor.items[cursor.index];
        cursor.index += 1;
        const children: []const Value = switch (child) {
            .object => |map| blk: {
                if (map.count() > maximum) return error.Capacity;
                break :blk map.values();
            },
            .array => |array| array.items,
            else => continue,
        };
        if (children.len != 0) {
            try stack.append(allocator, cursor);
            cursor = .{ .items = children };
        }
    }
}

pub fn object() Value {
    return .{ .object = .empty };
}
pub fn put(allocator: std.mem.Allocator, value: *Value, key: []const u8, child: Value) !void {
    try value.object.put(allocator, key, child);
}
pub fn string(value: []const u8) Value {
    return .{ .string = value };
}

/// Retain only a JSON value when its producer's temporary storage is released.
pub fn copy(allocator: std.mem.Allocator, value: Value) std.mem.Allocator.Error!Value {
    var result: Value = .null;
    var stack: std.ArrayList(CopyFrame) = .empty;
    defer stack.deinit(allocator);
    try copyValue(allocator, .{ .source = value, .destination = &result }, &stack);
    while (stack.pop()) |cursor| {
        try copyValue(allocator, cursor, &stack);
    }
    return result;
}

const CopyFrame = struct { source: Value, destination: *Value };

fn copyValue(
    allocator: std.mem.Allocator,
    cursor: CopyFrame,
    stack: *std.ArrayList(CopyFrame),
) std.mem.Allocator.Error!void {
    cursor.destination.* = switch (cursor.source) {
        .string => |bytes| .{ .string = try allocator.dupe(u8, bytes) },
        .number_string => |bytes| .{ .number_string = try allocator.dupe(u8, bytes) },
        .array => |items| blk: {
            var result: std.array_list.Managed(Value) = .init(allocator);
            try result.resize(items.items.len);
            @memset(result.items, .null);
            for (items.items, result.items) |item, *target|
                try stack.append(allocator, .{ .source = item, .destination = target });
            break :blk .{ .array = result };
        },
        .object => |members| blk: {
            var result = object();
            try result.object.ensureTotalCapacity(allocator, members.count());
            for (members.keys()) |key|
                result.object.putAssumeCapacity(try allocator.dupe(u8, key), .null);
            for (members.values(), result.object.values()) |item, *target|
                try stack.append(allocator, .{ .source = item, .destination = target });
            break :blk result;
        },
        .null, .bool, .integer, .float => cursor.source,
    };
}

test "retained JSON survives release and overwrite of producer storage" {
    var backing: [32 * 1024]u8 = undefined;
    var producer = std.heap.FixedBufferAllocator.init(&backing);
    var parsed = try parse(
        producer.allocator(),
        "{\"text\":\"owned\",\"array\":[null,true,{\"number\":18446744073709551615}]," ++
            "\"empty\":{}}",
        .{},
    );
    var response = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer response.deinit();
    const retained = try copy(response.allocator(), parsed.value);
    parsed.deinit();
    @memset(&backing, 0xa5);
    try std.testing.expectEqualStrings(
        "{\"array\":[null,true,{\"number\":18446744073709551615}],\"empty\":{},\"text\":\"owned\"}",
        try canonical(response.allocator(), retained),
    );
}

pub fn number(allocator: std.mem.Allocator, value: anytype) !Value {
    return .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{value}) };
}
pub fn get(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn text(value: Value) error{InvalidParams}![]const u8 {
    return if (value == .string) value.string else error.InvalidParams;
}

/// Canonical decimal string, including exact range admission. JSON numbers
/// deliberately use a different helper: counters cannot arrive as numbers.
pub fn decimal(comptime T: type, value: Value) error{InvalidParams}!T {
    return integer(T, try text(value));
}
fn integer(comptime T: type, bytes: []const u8) error{InvalidParams}!T {
    if (bytes.len == 0 or bytes.len > 20) return error.InvalidParams;
    var digits = bytes;
    if (bytes[0] == '-') {
        if (@typeInfo(T).int.signedness != .signed or bytes.len < 2) return error.InvalidParams;
        digits = bytes[1..];
        if (std.mem.eql(u8, digits, "0")) return error.InvalidParams;
    }
    if (digits.len > 1 and digits[0] == '0') return error.InvalidParams;
    for (digits) |byte| if (byte < '0' or byte > '9') return error.InvalidParams;
    return std.fmt.parseInt(T, bytes, 10) catch error.InvalidParams;
}

/// Decode an already syntax-checked JSON number exactly, including integral
/// fractional/exponent spellings. Client decimal strings use integer() above.
pub fn numberInteger(comptime T: type, bytes: []const u8) error{InvalidParams}!T {
    comptime std.debug.assert(@typeInfo(T).int.bits <= 64);
    if (bytes.len == 0) return error.InvalidParams;
    const negative = bytes[0] == '-';
    const start: usize = @intFromBool(negative);
    const exponent_at = std.mem.indexOfAnyPos(u8, bytes, start, "eE") orelse bytes.len;
    var nonzero = false;
    for (bytes[start..exponent_at]) |byte| nonzero = nonzero or (byte != '0' and byte != '.');
    if (!nonzero) return 0;
    if (@typeInfo(T).int.signedness == .unsigned and negative) return error.InvalidParams;
    var exponent: i32 = 0;
    if (exponent_at != bytes.len) {
        exponent = std.fmt.parseInt(
            i32,
            bytes[exponent_at + 1 ..],
            10,
        ) catch return error.InvalidParams;
        if (exponent < -1_000_000 or exponent > 1_000_000) return error.InvalidParams;
    }
    const dot = std.mem.indexOfScalarPos(u8, bytes[0..exponent_at], start, '.');
    const fraction: i32 = if (dot) |i| std.math.cast(
        i32,
        exponent_at - i - 1,
    ) orelse return error.InvalidParams else 0;
    var shift = exponent - fraction;
    var end = exponent_at;
    while (shift < 0) : (shift += 1) {
        if (end <= start or bytes[end - 1] != '0') return error.InvalidParams;
        end -= 1;
        if (end > start and bytes[end - 1] == '.') end -= 1;
    }
    var result: u64 = 0;
    const maximum: u64 = @as(u64, @intCast(std.math.maxInt(T))) + @intFromBool(negative);
    for (bytes[start..end]) |byte| {
        if (byte == '.') continue;
        if (byte < '0' or byte > '9') return error.InvalidParams;
        result = std.math.mul(u64, result, 10) catch return error.InvalidParams;
        result = std.math.add(u64, result, byte - '0') catch return error.InvalidParams;
        if (result > maximum) return error.InvalidParams;
    }
    if (result == 0) return 0;
    if (shift > 20) return error.InvalidParams;
    while (shift > 0) : (shift -= 1) {
        result = std.math.mul(u64, result, 10) catch return error.InvalidParams;
        if (result > maximum) return error.InvalidParams;
    }
    if (@typeInfo(T).int.signedness == .signed and negative) {
        if (result == maximum) return std.math.minInt(T);
        return -@as(T, @intCast(result));
    }
    return @intCast(result);
}

/// Numeric RPC IDs additionally stay inside the interoperable safe range.
pub fn safeInteger(bytes: []const u8) error{InvalidParams}!i64 {
    const value = try numberInteger(i64, bytes);
    if (value < -9007199254740991 or value > 9007199254740991) return error.InvalidParams;
    return value;
}

/// Used only after typed admission, for deterministic manifests and request
/// bindings. Sorting does not itself grant authority or admit a schema.
pub fn canonical(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writeCanonical(allocator, value, &writer.writer);
    return writer.toOwnedSlice();
}

/// Terminal values can expand sixfold when escaped. Count before allocating so
/// an arena does not retain every buffer grown while encoding a large result.
pub fn canonicalOptional(allocator: std.mem.Allocator, value: Value, maximum: anytype) ![]u8 {
    return if (maximum) |limit| canonicalBounded(
        allocator,
        value,
        limit,
    ) else canonical(
        allocator,
        value,
    );
}

pub fn canonicalBounded(allocator: std.mem.Allocator, value: Value, maximum: usize) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&buffer);
    try writeCanonical(allocator, value, &counter.writer);
    if (counter.fullCount() > maximum) return error.Capacity;
    const bytes = try allocator.alloc(u8, @intCast(counter.fullCount()));
    errdefer allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try writeCanonical(allocator, value, &writer);
    std.debug.assert(writer.end == bytes.len);
    return bytes;
}
fn writeCanonical(allocator: std.mem.Allocator, value: Value, writer: *std.Io.Writer) !void {
    const Frame = struct { value: Value, index: usize = 0, keys: ?[][]const u8 = null };
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |cursor| if (cursor.keys) |keys| allocator.free(keys);
        stack.deinit(allocator);
    }
    var next: ?Value = value;
    while (next != null or stack.items.len != 0) {
        if (next) |item| {
            next = null;
            switch (item) {
                .object => |map| {
                    const keys = try allocator.dupe([]const u8, map.keys());
                    errdefer allocator.free(keys);
                    std.mem.sort([]const u8, keys, {}, struct {
                        fn less(_: void, a: []const u8, b: []const u8) bool {
                            return std.mem.lessThan(u8, a, b);
                        }
                    }.less);
                    try writer.writeByte('{');
                    try stack.append(allocator, .{ .value = item, .keys = keys });
                },
                .array => {
                    try writer.writeByte('[');
                    try stack.append(allocator, .{ .value = item });
                },
                else => try std.json.Stringify.value(item, .{}, writer),
            }
            continue;
        }
        const cursor = &stack.items[stack.items.len - 1];
        const length = if (cursor.keys) |keys| keys.len else cursor.value.array.items.len;
        if (cursor.index == length) {
            try writer.writeByte(if (cursor.keys != null) '}' else ']');
            if (stack.pop().?.keys) |keys| allocator.free(keys);
            continue;
        }
        if (cursor.index != 0) try writer.writeByte(',');
        if (cursor.keys) |keys| {
            const key = keys[cursor.index];
            try std.json.Stringify.value(key, .{}, writer);
            try writer.writeByte(':');
            next = cursor.value.object.get(key).?;
        } else next = cursor.value.array.items[cursor.index];
        cursor.index += 1;
    }
}

test "recursive JSON stays stack safe through parsing and canonical serialization" {
    const a = std.testing.allocator;
    const depth = 50_000;
    const Form = struct {
        prefix: []const u8,
        suffix: []const u8,
        canonical_prefix: []const u8,
        canonical_suffix: []const u8,
    };
    for ([_]Form{
        .{ .prefix = "[", .suffix = "]", .canonical_prefix = "[", .canonical_suffix = "]" },
        .{
            .prefix = "{\"value\":",
            .suffix = ",\"tag\":1}",
            .canonical_prefix = "{\"tag\":1,\"value\":",
            .canonical_suffix = "}",
        },
    }) |form| {
        const document = try a.alloc(u8, depth * (form.prefix.len + form.suffix.len) + 1);
        defer a.free(document);
        for (0..depth) |i| @memcpy(
            document[i * form.prefix.len ..][0..form.prefix.len],
            form.prefix,
        );
        const middle = depth * form.prefix.len;
        document[middle] = '0';
        for (0..depth) |i| @memcpy(
            document[middle + 1 + i * form.suffix.len ..][0..form.suffix.len],
            form.suffix,
        );
        var parsed = try parse(a, document, .{
            .bytes = document.len,
            .depth = depth,
            .tokens = document.len,
            .members = document.len,
        });
        defer parsed.deinit();
        const encoded = try canonicalBounded(a, parsed.value, document.len);
        defer a.free(encoded);
        try std.testing.expectEqual(document.len, encoded.len);
        for (0..depth) |i| try std.testing.expectEqualStrings(
            form.canonical_prefix,
            encoded[i * form.canonical_prefix.len ..][0..form.canonical_prefix.len],
        );
        const canonical_middle = depth * form.canonical_prefix.len;
        try std.testing.expectEqual(@as(u8, '0'), encoded[canonical_middle]);
        for (0..depth) |i| {
            const offset = canonical_middle + 1 + i * form.canonical_suffix.len;
            try std.testing.expectEqualStrings(
                form.canonical_suffix,
                encoded[offset..][0..form.canonical_suffix.len],
            );
        }
    }
}

fn canonicalAllocationProbe(a: std.mem.Allocator) !void {
    var parsed = try parse(a, "{\"z\":[{\"b\":2,\"a\":1}],\"a\":{\"q\":null}}", .{});
    defer parsed.deinit();
    const encoded = try canonicalBounded(a, parsed.value, 128);
    defer a.free(encoded);
    try std.testing.expectEqualStrings("{\"a\":{\"q\":null},\"z\":[{\"a\":1,\"b\":2}]}", encoded);
}

test "canonical traversal releases every owned key list on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        canonicalAllocationProbe,
        .{},
    );
}

test "strict JSON preserves integers and rejects duplicate keys unicode and resource excess" {
    const a = std.testing.allocator;
    const escaped = try canonicalBounded(a, string("\x00\x00"), 14);
    defer a.free(escaped);
    try std.testing.expectEqualStrings("\"\\u0000\\u0000\"", escaped);
    try std.testing.expectError(error.Capacity, canonicalBounded(a, string("\x00\x00"), 13));
    var exact = try parse(a, "{\"n\":18446744073709551615,\"s\":\"雪\"}", .{});
    defer exact.deinit();
    try std.testing.expectEqualStrings(
        "18446744073709551615",
        exact.value.object.get("n").?.number_string,
    );
    try std.testing.expectError(error.DuplicateKey, parse(a, "{\"a\":1,\"a\":2}", .{}));
    try std.testing.expectError(error.InvalidJson, parse(a, "\"\\ud800\"", .{}));
    try std.testing.expectError(error.InvalidJson, parse(a, "\"\xff\"", .{}));
    try std.testing.expectError(error.Capacity, parse(a, "[[[]]]", .{ .depth = 2 }));
    try std.testing.expectError(error.Capacity, parse(a, "[0,1,2]", .{ .tokens = 3 }));
    try std.testing.expectError(error.InvalidParams, decimal(u64, .{ .string = "01" }));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try decimal(u64, .{ .string = "18446744073709551615" }),
    );
    try std.testing.expectEqual(1, try safeInteger("1.0"));
    try std.testing.expectEqual(1, try safeInteger("10e-1"));
    try std.testing.expectEqual(9007199254740991, try safeInteger("9007199254740991.0"));
    try std.testing.expectError(error.InvalidParams, safeInteger("9007199254740992"));
    try std.testing.expectError(error.InvalidParams, safeInteger("1.1"));
}

test "JSON copy and structural admission traverse deep values without native recursion" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    var destination_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer destination_arena.deinit();
    const a = source_arena.allocator();
    const depth = 10_000;
    var value: Value = .{ .integer = 17 };
    for (0..depth) |_| {
        var parent: Value = .{ .array = .init(a) };
        try parent.array.append(value);
        value = parent;
    }
    const limits: Limits = .{ .depth = depth, .tokens = 2 * depth + 1, .bytes = 2 * depth + 2 };
    try std.testing.expect(try fits(a, value, limits));
    var retained = try copy(destination_arena.allocator(), value);
    for (0..depth) |_| {
        try std.testing.expectEqual(@as(usize, 1), retained.array.items.len);
        retained = retained.array.items[0];
    }
    try std.testing.expectEqual(@as(i64, 17), retained.integer);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, fits(failing.allocator(), value, limits));
}
