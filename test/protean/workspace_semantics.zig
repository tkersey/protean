//! Emit new workspace programs for the retained independent source oracle and
//! provide the ordinary native invocation byte peer. Never linked into product.
const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const kosmos = @import("kosmos");
const c = @import("protean_contracts");
const sources = @import("workspace_sources.zig");
const driver = native.program_construction.driver;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.eql(u8, mode, "invoke")) {
        var input_buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &input_buffer);
        const bytes = try input.interface.allocRemaining(a, .unlimited);
        try output.interface.writeAll(try kosmos.invocation.invokeBytes(a, bytes));
    } else {
        var builder = horos.source.Builder.init(a);
        defer builder.deinit();
        const attachments = std.mem.eql(u8, mode, "attachments");
        const shallow = std.mem.eql(u8, mode, "shallow");
        const successor = std.mem.eql(u8, mode, "successor");
        const mutable = std.mem.eql(u8, mode, "mutable-alternatives");
        const alternative = mutable or std.mem.eql(u8, mode, "alternatives");
        const recursive = std.mem.eql(u8, mode, "recursive");
        const mobility = std.mem.eql(u8, mode, "mobility");
        if (!mobility and !attachments and !shallow and !successor and !alternative and !recursive and !std.mem.eql(u8, mode, "gcd")) return error.InvalidMode;
        const module = if (mobility) try @import("runtime_mobility_source.zig").build(&builder) else if (attachments) try sources.distinctAttachments(&builder) else if (shallow or successor) try sources.retainedHandlers(&builder, shallow) else if (mutable) try sources.mutableAlternatives(&builder) else if (alternative) try sources.alternatives(&builder, true) else if (recursive) try sources.listLength(&builder) else try sources.gcd(&builder);
        const transport = try native.source_records.encode(a, module);
        const exposures: []const c.workspace.Exposure = if (mobility) &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .input }, .{ .effect = 2, .class = .observation } } else if (attachments or shallow or successor) &.{.{ .effect = 0, .class = .input }} else if (alternative) &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } } else &.{};
        var diagnostic: native.program_construction.Diagnostic = .{};
        const started = std.Io.Clock.awake.now(init.io);
        var built = native.program_construction.buildExposed(a, transport, exposures, null, &diagnostic) catch |err| {
            std.debug.print("{s}: {any}\n", .{ mode, diagnostic });
            return err;
        };
        defer built.deinit();
        const compile_ns = std.Io.Clock.awake.now(init.io).nanoseconds - started.nanoseconds;
        var generated: ?driver.Generated = if (exposures.len != 0) try driver.generate(a, module, exposures) else null;
        defer if (generated) |*value| value.deinit();
        const interpreted = if (generated) |value| value.module else module;
        // The source given to the oracle must compile to the exact delivered
        // image; an independent source cannot merely share an expected answer.
        var compiled = try horos.source.lowerObserved(a, interpreted, .{ .contract = .structural });
        defer compiled.deinit();
        const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        _ = try compiled.encode(a, image);
        if (!std.mem.eql(u8, built.image, image)) return error.SourceImageMismatch;
        var document = native.json.object();
        try native.json.put(a, &document, "transport", native.json.string(transport));
        const raw_source = try std.json.Stringify.valueAlloc(a, interpreted, .{ .emit_strings_as_arrays = true });
        try native.json.put(a, &document, "source", (try native.json.parse(a, raw_source, .{ .bytes = raw_source.len, .tokens = raw_source.len, .members = raw_source.len })).value);
        try native.json.put(a, &document, "image", try native.values.toJson(c.Bytes(null), a, .{ .bytes = image }));
        try native.json.put(a, &document, "compile_ns", try native.json.number(a, compile_ns));
        try native.json.put(a, &document, "compiler_arena_bytes", try native.json.number(a, arena.queryCapacity()));
        var cases: native.json.Value = .{ .array = .init(a) };
        if (mobility) {
            const Command = union(enum) { instantiate: u64, finish: void };
            try cases.array.append(try example(a, try c.encodeOwned(struct { u64, u64 }, a, .{ 32, 100 }), &.{
                try c.encodeOwned(void, a, {}), try c.encodeOwned(Command, a, .{ .instantiate = 10 }), try c.encodeOwned(Command, a, .{ .instantiate = 20 }), try c.encodeOwned(Command, a, .{ .finish = {} }), try c.encodeOwned(void, a, {}),
            }, try c.encodeOwned(u64, a, 184)));
        } else if (attachments) {
            try cases.array.append(try example(a, &.{}, &.{}, try c.encodeOwned(u64, a, 42)));
        } else if (shallow or successor) {
            const expected = if (shallow) try c.encodeOwned([8]u64, a, .{ 99, 99, 99, 99, 42, 42, 42, 42 }) else try c.encodeOwned([2]u64, a, .{ 42, 37 });
            try cases.array.append(try example(a, try c.encodeOwned(void, a, {}), &.{}, expected));
        } else if (alternative) {
            const Command = union(enum) { instantiate: u64, finish: void };
            try cases.array.append(try example(a, try c.encodeOwned(u64, a, 100), &.{
                try c.encodeOwned(void, a, {}), try c.encodeOwned(Command, a, .{ .instantiate = 10 }), try c.encodeOwned(Command, a, .{ .instantiate = 20 }), try c.encodeOwned(Command, a, .{ .finish = {} }),
            }, try c.encodeOwned(u64, a, 121)));
        } else if (recursive) {
            var text: []const u8 = "{\"tag\":0,\"value\":{}}";
            for (0..300) |_| text = try std.fmt.allocPrint(a, "{{\"tag\":1,\"value\":[\"0\",{s}]}}", .{text});
            const parsed = try native.json.parse(a, text, .{ .bytes = text.len, .depth = text.len, .tokens = text.len, .members = text.len });
            try cases.array.append(try example(a, try native.dynamic_values.encode(a, built.interface.input.bytes, parsed.value), &.{}, try c.encodeOwned(u64, a, 300)));
        } else for ([_][3]u64{ .{ 48, 18, 6 }, .{ 35, 14, 7 } }) |pair| {
            try cases.array.append(try example(a, try c.encodeOwned(struct { u64, u64 }, a, .{ pair[0], pair[1] }), &.{}, try c.encodeOwned(u64, a, pair[2])));
        }
        try native.json.put(a, &document, "cases", cases);
        try output.interface.writeAll(try native.json.canonical(a, document));
    }
    try output.interface.flush();
}

fn example(a: std.mem.Allocator, input: []const u8, replies: []const []const u8, expected: []const u8) !native.json.Value {
    var value = native.json.object();
    try native.json.put(a, &value, "input", try native.values.toJson(c.Bytes(null), a, .{ .bytes = input }));
    var responses: native.json.Value = .{ .array = .init(a) };
    for (replies) |reply| try responses.array.append(try native.values.toJson(c.Bytes(null), a, .{ .bytes = reply }));
    try native.json.put(a, &value, "responses", responses);
    try native.json.put(a, &value, "expected", try native.values.toJson(c.Bytes(null), a, .{ .bytes = expected }));
    return value;
}
