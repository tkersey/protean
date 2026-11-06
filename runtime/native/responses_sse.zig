const std = @import("std");
const json = @import("json.zig");

pub const Format = enum { json, sse };
pub const Terminal = enum { completed, failed, incomplete, error_event };
pub const Decoded = struct { terminal: Terminal, response: json.Value };

pub const Framer = struct {
    offset: usize = 0,
    line_start: usize = 0,
    frame_start: usize = 0,

    pub fn next(self: *Framer, bytes: []const u8, eof: bool) ?[]const u8 {
        while (self.offset < bytes.len) {
            const byte = bytes[self.offset];
            if (byte != '\r' and byte != '\n') {
                self.offset += 1;
                continue;
            }
            if (byte == '\r' and self.offset + 1 == bytes.len and !eof) return null;
            const line_end = self.offset;
            self.offset += 1;
            if (byte == '\r' and self.offset < bytes.len and bytes[self.offset] == '\n')
                self.offset += 1;
            const empty = line_end == self.line_start;
            self.line_start = self.offset;
            if (empty) {
                const frame = bytes[self.frame_start..line_end];
                self.frame_start = self.offset;
                return frame;
            }
        }
        return null;
    }
};

const Event = struct {
    label: ?[]const u8 = null,
    conflicting_labels: bool = false,
    terminal_label: bool = false,
    data: std.ArrayList(u8) = .empty,

    fn deinit(self: *Event, a: std.mem.Allocator) void {
        self.data.deinit(a);
    }

    fn parse(a: std.mem.Allocator, frame: []const u8) !Event {
        var result: Event = .{};
        errdefer result.deinit(a);
        var lines = std.mem.tokenizeAny(u8, frame, "\r\n");
        while (lines.next()) |line| {
            if (line[0] == ':') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            const key = line[0..colon];
            var value = if (colon == line.len) "" else line[colon + 1 ..];
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            if (equal(key, "event")) {
                if (result.label) |previous| {
                    if (!equal(previous, value)) result.conflicting_labels = true;
                }
                result.terminal_label = result.terminal_label or terminalType(value) != null;
                result.label = value;
            } else if (equal(key, "data")) {
                try result.data.appendSlice(a, value);
                try result.data.append(a, '\n');
            }
        }
        if (result.data.items.len != 0) _ = result.data.pop();
        return result;
    }
};

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn terminalType(name: []const u8) ?Terminal {
    if (equal(name, "response.completed")) return .completed;
    if (equal(name, "response.failed")) return .failed;
    if (equal(name, "response.incomplete")) return .incomplete;
    if (equal(name, "error")) return .error_event;
    return null;
}

fn parsePayload(a: std.mem.Allocator, bytes: []const u8) !json.Value {
    return json.parseInto(a, bytes, .{
        .bytes = bytes.len,
        .depth = bytes.len,
        .tokens = bytes.len,
        .members = bytes.len,
    });
}

pub fn terminalFrame(a: std.mem.Allocator, frame: []const u8) !bool {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var event = try Event.parse(allocator, frame);
    defer event.deinit(allocator);
    if (event.terminal_label) return true;
    const value = parsePayload(allocator, event.data.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    const kind = json.get(value, "type") orelse return false;
    return kind == .string and terminalType(kind.string) != null;
}

pub fn eventStream(media_type: ?[]const u8) bool {
    const value = media_type orelse return false;
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), "text/event-stream");
}

fn field(value: json.Value, key: []const u8) !json.Value {
    return json.get(value, key) orelse error.InvalidResponse;
}

fn text(value: json.Value, key: []const u8) ![]const u8 {
    return json.text(try field(value, key)) catch error.InvalidResponse;
}

fn integer(value: json.Value) !u64 {
    if (value != .number_string) return error.InvalidResponse;
    return json.numberInteger(u64, value.number_string) catch error.InvalidResponse;
}

const Finalized = struct { index: u64, item: json.Value };
const State = struct {
    a: std.mem.Allocator,
    items: std.ArrayList(Finalized) = .empty,
    response_id: ?[]const u8 = null,
    sequence: ?u64 = null,

    fn identity(self: *State, value: json.Value, key: []const u8) !void {
        const id = json.get(value, key) orelse return;
        if (id != .string or id.string.len == 0) return error.InvalidResponse;
        if (self.response_id) |previous| {
            if (!equal(previous, id.string)) return error.ResponseIdentityMismatch;
        } else self.response_id = id.string;
    }

    fn observe(self: *State, value: json.Value) !void {
        if (json.get(value, "sequence_number")) |number| {
            const sequence = try integer(number);
            if (self.sequence) |previous| if (sequence <= previous)
                return error.InvalidEventOrder;
            self.sequence = sequence;
        }
        try self.identity(value, "response_id");
        if (json.get(value, "response")) |response| try self.identity(response, "id");
    }

    fn finalize(self: *State, value: json.Value) !void {
        const index = try integer(try field(value, "output_index"));
        const item = try field(value, "item");
        try finalizedItem(item);
        for (self.items.items) |previous| {
            if (previous.index == index) return error.DuplicateOutputIndex;
            try distinctItems(previous.item, item);
        }
        try self.items.append(self.a, .{ .index = index, .item = item });
    }

    fn finish(self: *State, value: json.Value, terminal: Terminal) !Decoded {
        if (terminal == .error_event) return .{ .terminal = terminal, .response = value };
        var response = try field(value, "response");
        if (response != .object) return error.InvalidResponse;
        const expected = switch (terminal) {
            .completed => "completed",
            .failed => "failed",
            .incomplete => "incomplete",
            .error_event => unreachable,
        };
        if (!equal(try text(response, "status"), expected)) return error.InvalidTerminalStatus;
        if ((try text(response, "id")).len == 0) return error.InvalidResponse;
        if (terminal == .completed) try self.reconcile(&response);
        return .{ .terminal = terminal, .response = response };
    }

    fn reconcile(self: *State, response: *json.Value) !void {
        const output = try field(response.*, "output");
        if (output != .array or output.array.items.len > self.items.items.len)
            return error.OutputMismatch;
        var ordered: json.Value = .{ .array = .init(self.a) };
        for (0..self.items.items.len) |index| {
            var finalized: ?json.Value = null;
            for (self.items.items) |entry| if (entry.index == index) {
                finalized = entry.item;
                break;
            };
            try ordered.array.append(finalized orelse return error.OutputMismatch);
        }
        var next: usize = 0;
        for (output.array.items, 0..) |projection, ordinal| {
            if (projection != .object) return error.OutputMismatch;
            const index = if (output.array.items.len == ordered.array.items.len)
                ordinal
            else
                try projectionIndex(ordered.array.items, projection);
            if (index < next) return error.OutputMismatch;
            next = index + 1;
            const item = &ordered.array.items[index];
            if (!equal(try text(item.*, "type"), try text(projection, "type")))
                return error.OutputMismatch;
            try mergeProjection(self.a, item, projection);
            try finalizedItem(item.*);
        }
        for (ordered.array.items, 0..) |item, index|
            for (ordered.array.items[0..index]) |previous| try distinctItems(previous, item);
        try json.put(self.a, response, "output", ordered);
    }
};

fn projectionIndex(items: []const json.Value, projection: json.Value) !usize {
    var found: ?usize = null;
    for (items, 0..) |item, index| {
        var matches = false;
        inline for (.{ "id", "call_id" }) |key| if (json.get(projection, key)) |identity| {
            const expected = try json.text(identity);
            if (json.get(item, key)) |actual|
                matches = matches or equal(expected, try json.text(actual));
        };
        if (matches) {
            if (found != null) return error.OutputMismatch;
            found = index;
        }
    }
    return found orelse error.OutputMismatch;
}

fn finalizedItem(item: json.Value) !void {
    const kind = try text(item, "type");
    if (!equal(kind, "reasoning") and !equal(kind, "function_call") and
        !equal(kind, "message")) return error.UnsupportedResponse;
    if (json.get(item, "status")) |status| {
        if (status != .string or !equal(status.string, "completed"))
            return error.UnfinalizedOutput;
    } else if (!equal(kind, "reasoning")) return error.UnfinalizedOutput;
    inline for (.{ "id", "call_id" }) |key| if (json.get(item, key)) |id| {
        if (id != .string or id.string.len == 0) return error.InvalidResponse;
    };
}

fn distinctItems(previous: json.Value, item: json.Value) !void {
    inline for (.{ "id", "call_id" }) |key| if (json.get(item, key)) |id| {
        if (json.get(previous, key)) |prior| {
            if (equal(try json.text(id), try json.text(prior)))
                return error.DuplicateOutputIdentity;
        }
    };
}

fn mergeProjection(a: std.mem.Allocator, target: *json.Value, projection: json.Value) !void {
    const Pair = struct { complete: *json.Value, partial: json.Value };
    var pending: std.ArrayList(Pair) = .empty;
    defer pending.deinit(a);
    try pending.append(a, .{ .complete = target, .partial = projection });
    while (pending.pop()) |pair| {
        if (pair.complete.* == .object and pair.partial == .object) {
            for (pair.partial.object.keys(), pair.partial.object.values()) |key, value| {
                if (!pair.complete.object.contains(key)) try json.put(a, pair.complete, key, value);
            }
            for (pair.partial.object.keys(), pair.partial.object.values()) |key, value| {
                const complete = pair.complete.object.getPtr(key) orelse
                    return error.OutputMismatch;
                try pending.append(a, .{ .complete = complete, .partial = value });
            }
        } else if (pair.complete.* == .array and pair.partial == .array) {
            if (pair.complete.array.items.len != pair.partial.array.items.len)
                return error.OutputMismatch;
            for (pair.complete.array.items, pair.partial.array.items) |*complete, partial|
                try pending.append(a, .{ .complete = complete, .partial = partial });
        } else {
            const complete = try json.canonical(a, pair.complete.*);
            defer a.free(complete);
            const partial = try json.canonical(a, pair.partial);
            defer a.free(partial);
            if (!equal(complete, partial)) return error.OutputMismatch;
        }
    }
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Decoded {
    var framer: Framer = .{};
    var state: State = .{ .a = a };
    defer state.items.deinit(a);
    while (framer.next(bytes, true)) |frame| {
        var event = try Event.parse(a, frame);
        defer event.deinit(a);
        if (event.conflicting_labels) return error.ConflictingEventType;
        if (event.data.items.len == 0) continue;
        if (equal(event.data.items, "[DONE]")) continue;
        const value = try parsePayload(a, event.data.items);
        const kind = try text(value, "type");
        if (event.label) |label| if (!equal(label, kind)) return error.ConflictingEventType;
        try state.observe(value);
        if (terminalType(kind)) |terminal| {
            if (framer.offset != bytes.len) return error.TrailingStreamBytes;
            return state.finish(value, terminal);
        }
        if (equal(kind, "response.output_item.done")) try state.finalize(value);
    }
    return error.MissingTerminalResponse;
}

const finalized_reasoning =
    \\event: response.output_item.done
    \\data: {"type":"response.output_item.done","sequence_number":7,"output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque"}}
    \\
    \\
;
const completed_reasoning =
    \\event: response.completed
    \\data: {"type":"response.completed","sequence_number":11,"response":{"id":"resp_1","status":"completed","output":[{"type":"reasoning","id":"rs_1"}],"usage":{"input_tokens":0}}}
    \\
    \\
;

test "SSE preserves finalized reasoning and absent usage fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), finalized_reasoning ++ completed_reasoning);
    try std.testing.expectEqual(Terminal.completed, decoded.terminal);
    const output = try field(decoded.response, "output");
    try std.testing.expectEqualStrings(
        "opaque",
        try text(output.array.items[0], "encrypted_content"),
    );
    const usage = try field(decoded.response, "usage");
    try std.testing.expectEqual(@as(u64, 0), try integer(try field(usage, "input_tokens")));
    try std.testing.expect(json.get(usage, "output_tokens") == null);
}

test "SSE framing handles every fragmented newline and Unicode cut" {
    const bytes = ": comment\r\nevent: error\r\ndata: {\"type\":\"error\",\r\n" ++
        "data: \"message\":\"雪\"}\r\n\r\n";
    for (0..bytes.len + 1) |cut| {
        var framer: Framer = .{};
        const first = framer.next(bytes[0..cut], false);
        const frame = first orelse framer.next(bytes, true) orelse return error.MissingFrame;
        try std.testing.expect(try terminalFrame(std.testing.allocator, frame));
        try std.testing.expectEqual(bytes.len, framer.offset);
    }
    for ([_][]const u8{
        "event: error\ndata: {\"type\":\"error\"}\n\n",
        "event: error\rdata: {\"type\":\"error\"}\r\r",
    }) |stream| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(
            Terminal.error_event,
            (try decode(arena.allocator(), stream)).terminal,
        );
    }
}

test "SSE captures recognized malformed terminal for pure protocol rejection" {
    try std.testing.expect(try terminalFrame(
        std.testing.allocator,
        "event: response.completed\ndata: {bad}\n",
    ));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidJson, decode(
        arena.allocator(),
        "event: response.completed\ndata: {bad}\n\n",
    ));
    try std.testing.expectError(error.ConflictingEventType, decode(
        arena.allocator(),
        "event: response.failed\ndata: {\"type\":\"error\"}\n\n",
    ));
}

test "SSE rejects duplicate finalized identities indices and conflicting terminal output" {
    const variants = [_][]const u8{
        finalized_reasoning ++ finalized_reasoning ++ completed_reasoning,
        finalized_reasoning ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":1," ++
            "\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\"}}\n\n" ++ completed_reasoning,
        finalized_reasoning ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\"," ++
            "\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\"," ++
            "\"id\":\"other\"}]}}\n\n",
        completed_reasoning,
    };
    for (variants) |bytes| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (decode(arena.allocator(), bytes)) |_| return error.AcceptedInvalidStream else |_| {}
    }
}

test "SSE retains failed incomplete and standalone error terminals without staged output" {
    for ([_][]const u8{ "failed", "incomplete" }) |status| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = try std.fmt.allocPrint(
            a,
            "{s}data: {{\"type\":\"response.{s}\",\"response\":{{\"id\":\"r\"," ++
                "\"status\":\"{s}\",\"error\":{{\"code\":\"fixture\"}}}}}}\n\n",
            .{ finalized_reasoning, status, status },
        );
        const decoded = try decode(a, bytes);
        try std.testing.expect(decoded.terminal == .failed or decoded.terminal == .incomplete);
        try std.testing.expect(json.get(decoded.response, "output") == null);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), finalized_reasoning ++
        "data: {\"type\":\"error\",\"code\":\"fixture\"}\n\n");
    try std.testing.expectEqual(Terminal.error_event, decoded.terminal);
    try std.testing.expectEqualStrings("fixture", try text(decoded.response, "code"));
    try std.testing.expectError(error.MissingTerminalResponse, decode(
        arena.allocator(),
        finalized_reasoning ++ "data: [DONE]\n\n",
    ));
}

test "SSE output index restores order and progress cannot replace final content" {
    const stream =
        \\data: {"type":"response.created","sequence_number":2,"response":{"id":"r"}}
        \\
        \\data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","status":"completed","id":"fc","call_id":"c","name":"act","arguments":"{\"x\":1}"}}
        \\
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs","summary":[],"encrypted_content":"complete"}}
        \\
        \\data: {"type":"response.output_item.added","item":{"type":"reasoning","id":"rs","encrypted_content":"partial"}}
        \\
        \\data: {"type":"response.completed","sequence_number":8,"response":{"id":"r","status":"completed","output":[{"type":"reasoning","id":"rs"},{"type":"function_call","id":"fc","call_id":"c"}]}}
        \\
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try decode(arena.allocator(), stream);
    const output = try field(result.response, "output");
    try std.testing.expectEqualStrings("reasoning", try text(output.array.items[0], "type"));
    try std.testing.expectEqualStrings(
        "complete",
        try text(output.array.items[0], "encrypted_content"),
    );
    try std.testing.expectEqualStrings("{\"x\":1}", try text(output.array.items[1], "arguments"));
}

test "SSE rejects identity ordering Unicode duplicate keys and incomplete boundaries" {
    const cases = [_]struct { bytes: []const u8, failure: anyerror }{
        .{
            .bytes = "data: {\"type\":\"response.created\",\"response\":{\"id\":\"wrong\"}}\n\n" ++
                finalized_reasoning ++ completed_reasoning,
            .failure = error.ResponseIdentityMismatch,
        },
        .{
            .bytes = finalized_reasoning ++
                "data: {\"type\":\"error\",\"sequence_number\":6}\n\n",
            .failure = error.InvalidEventOrder,
        },
        .{
            .bytes = "data: {\"type\":\"error\",\"code\":\"a\",\"code\":\"b\"}\n\n",
            .failure = error.DuplicateKey,
        },
        .{
            .bytes = "data: {\"type\":\"error\",\"message\":\"\\ud800\"}\n\n",
            .failure = error.InvalidJson,
        },
        .{
            .bytes = "data: {\"type\":\"error\"}\n",
            .failure = error.MissingTerminalResponse,
        },
        .{
            .bytes = "event: error\nevent: response.completed\ndata: {}\n\n",
            .failure = error.ConflictingEventType,
        },
        .{
            .bytes = "data: {\"type\":\"error\"}\n\nextra",
            .failure = error.TrailingStreamBytes,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(case.failure, decode(arena.allocator(), case.bytes));
    }
}

test "SSE terminal metadata enriches finalized items without replacing opaque reasoning" {
    const stream = finalized_reasoning ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\"," ++
        "\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\"," ++
        "\"status\":\"completed\"}]}}\n\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try decode(arena.allocator(), stream);
    const output = try field(result.response, "output");
    try std.testing.expectEqualStrings("completed", try text(output.array.items[0], "status"));
    try std.testing.expectEqualStrings(
        "opaque",
        try text(output.array.items[0], "encrypted_content"),
    );
    try std.testing.expectError(error.DuplicateOutputIndex, decode(
        arena.allocator(),
        finalized_reasoning ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0," ++
            "\"item\":{\"type\":\"reasoning\",\"id\":\"other\"}}\n\n" ++ completed_reasoning,
    ));
}

test "SSE repeated matching event labels preserve one meaning without sequence numbers" {
    const bytes = "event: error\nevent: error\ndata: {\"type\":\"error\",\"code\":\"fixture\"}\n\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), bytes);
    try std.testing.expectEqual(Terminal.error_event, decoded.terminal);
    try std.testing.expectEqualStrings("fixture", try text(decoded.response, "code"));
}

const finalized_subset =
    \\data: {"type":"response.output_item.done","output_index":2,"item":{"type":"reasoning","id":"r2","summary":[],"encrypted_content":"last"}}
    \\
    \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"r0","summary":[],"encrypted_content":"first"}}
    \\
    \\data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","status":"completed","id":"f1","call_id":"c1","name":"answer","arguments":"{}"}}
    \\
    \\
;

fn subsetStream(a: std.mem.Allocator, output: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        a,
        "{s}data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"r\"," ++
            "\"status\":\"completed\",\"output\":{s}}}}}\n\n",
        .{ finalized_subset, output },
    );
}

test "SSE finalized output survives empty and identified sparse terminal rosters" {
    for ([_][]const u8{
        "[]",
        "[{\"type\":\"function_call\",\"id\":\"f1\"}]",
        "[{\"type\":\"function_call\",\"call_id\":\"c1\"}]",
        "[{\"type\":\"reasoning\",\"id\":\"r2\"}]",
        "[{\"type\":\"reasoning\",\"id\":\"r0\"},{\"type\":\"reasoning\",\"id\":\"r2\"}]",
        "[{\"type\":\"reasoning\"},{\"type\":\"function_call\"},{\"type\":\"reasoning\"}]",
    }) |roster| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = try decode(a, try subsetStream(a, roster));
        const output = try field(result.response, "output");
        try std.testing.expectEqual(@as(usize, 3), output.array.items.len);
        try std.testing.expectEqualStrings(
            "first",
            try text(output.array.items[0], "encrypted_content"),
        );
        try std.testing.expectEqualStrings("{}", try text(output.array.items[1], "arguments"));
        try std.testing.expectEqualStrings(
            "last",
            try text(output.array.items[2], "encrypted_content"),
        );
    }
}

test "SSE sparse terminal rosters reject unknown ambiguous conflicting and reordered items" {
    for ([_][]const u8{
        "[{\"type\":\"reasoning\",\"id\":\"unknown\"}]",
        "[{\"type\":\"reasoning\"}]",
        "[{\"type\":\"function_call\",\"id\":\"f1\",\"call_id\":\"other\"}]",
        "[{\"type\":\"function_call\",\"id\":\"r0\",\"call_id\":\"c1\"}]",
        "[{\"type\":\"function_call\",\"id\":\"f1\",\"arguments\":\"different\"}]",
        "[{\"type\":\"reasoning\",\"id\":\"r2\"},{\"type\":\"reasoning\",\"id\":\"r0\"}]",
        "[{\"type\":\"reasoning\",\"id\":\"r0\"},{\"type\":\"reasoning\",\"id\":\"r0\"}]",
    }) |roster| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try std.testing.expectError(error.OutputMismatch, decode(a, try subsetStream(a, roster)));
    }
}

test "SSE empty terminal output still requires contiguous finalized indices" {
    const stream =
        \\data: {"type":"response.output_item.done","output_index":1,"item":{"type":"reasoning","id":"r1","summary":[],"encrypted_content":"complete"}}
        \\
        \\data: {"type":"response.completed","response":{"id":"r","status":"completed","output":[]}}
        \\
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.OutputMismatch, decode(arena.allocator(), stream));
}
