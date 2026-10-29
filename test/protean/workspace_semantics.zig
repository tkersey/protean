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
        try invoke(a, init.io, &output.interface);
    } else if (std.mem.eql(u8, mode, "capsule-export")) {
        try exportCapsule(a, &output.interface);
    } else if (std.mem.eql(u8, mode, "capsule-import")) {
        try importCapsule(a, init.io, &output.interface);
    } else if (std.mem.eql(u8, mode, "capsule-phase")) {
        const runtime_path = args.next() orelse return error.MissingRuntime;
        const capsule_path = args.next() orelse return error.MissingCapsule;
        try @import("runtime_mobility_peer.zig").capsulePhase(
            a,
            init.io,
            runtime_path,
            capsule_path,
            &output.interface,
        );
    } else {
        try emitFixture(&arena, init.io, mode, &output.interface);
    }
    try output.interface.flush();
}

fn invoke(a: std.mem.Allocator, io: std.Io, output: *std.Io.Writer) !void {
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &input_buffer);
    const bytes = try input.interface.allocRemaining(a, .unlimited);
    try output.writeAll(try kosmos.invocation.invokeBytes(a, bytes));
}

fn exportCapsule(a: std.mem.Allocator, output: *std.Io.Writer) !void {
    // A synthetic, authority-free fixture for comparing exact outer bytes
    // across native platforms. Bilateral custody is qualified separately
    // by native_runtime.mjs against the actual process transport.
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    var compiled = try horos.source.lower(a, try horos.source.examples.cloned(&builder));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    var prepared = try kosmos.Prepared.init(a, image);
    defer prepared.deinit();
    var original = try kosmos.Session.start(a, &prepared, &.{});
    defer original.deinit();
    try findClonePhase(&original, &prepared);
    if (original.driver.checkpoint(a)) |_| return error.FalseGuestCut else |err| {
        if (err != error.GuestCutUnavailable) return err;
    }
    const capsule = try kosmos.RuntimeCapsule.publish(a, &original.driver, .outer_execution, .{
        .execution = @splat(31),
        .custody = @splat(32),
        .publication = null,
    });
    const packet: CapsulePacket = .{
        .image = image,
        .runtime = try prepared.runtime.encode(a),
        .capsule = capsule,
        .outer = try original.driver.outer.checkpoint(a),
    };
    try output.writeAll(
        try std.json.Stringify.valueAlloc(a, packet, .{ .emit_strings_as_arrays = true }),
    );
}

fn findClonePhase(original: *kosmos.Session, prepared: *kosmos.Prepared) !void {
    for (0..400) |_| {
        const yielded = original.driver.last_cut.?.status == .yielded;
        try original.driver.submit(.{ .advance = .{
            .control = if (yielded) .resume_yield else .none,
            .quantum = 1,
        } });
        while (true) { // tiger: event-loop
            var step = try original.driver.pump(16);
            if (step == .event) {
                step.event.deinit();
                break;
            }
            if (step != .suspended) return error.InvalidPhase;
            const current = original.driver.outer.roots.current orelse continue;
            const frame = try original.driver.outer.frames.get(current.id);
            if (frame.position == 0) continue;
            for (prepared.runtime.content.value.recovery.anchors) |anchor| {
                if (anchor.role == .clone_rebase and anchor.function == frame.function) return;
            }
        }
        if (original.driver.last_cut.?.status == .completed) return error.MissingClonePhase;
    }
    return error.MissingClonePhase;
}

fn importCapsule(a: std.mem.Allocator, io: std.Io, output: *std.Io.Writer) !void {
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &input_buffer);
    const bytes = try input.interface.allocRemaining(a, .unlimited);
    const packet = (try std.json.parseFromSlice(CapsulePacket, a, bytes, .{})).value;
    var selected = try kosmos.RuntimeArtifact.init(
        a,
        packet.runtime,
        kosmos.RuntimeCapsule.reference(packet.runtime).digest,
    );
    defer selected.deinit();
    try kosmos.RuntimeCompiler.validate(a, &selected);
    var prepared = try kosmos.Prepared.initWithRuntime(a, packet.image, &selected);
    defer prepared.deinit();
    var custody: CapsuleCustody = .{ .expected = kosmos.RuntimeCapsule.reference(packet.capsule) };
    var restored = try kosmos.RuntimeCapsule.restore(
        a,
        &prepared.guest,
        &selected,
        packet.capsule,
        custody.verifier(),
    );
    defer restored.deinit();
    if (!std.mem.eql(u8, packet.outer, try restored.outer.checkpoint(a)))
        return error.ChangedOuterState;
    if (kosmos.RuntimeCapsule.restore(
        a,
        &prepared.guest,
        &selected,
        packet.capsule,
        custody.verifier(),
    )) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ReusedCustody;
    } else |err| if (err != error.UnauthorizedCapsule) return err;
    var completed = try restored.pump(null);
    defer if (completed == .event) completed.event.deinit();
    if (completed != .event or completed.event.value != .cut) return error.InvalidPhase;
    try output.writeAll(try restored.checkpoint(a));
}

const Fixture = enum {
    gcd,
    attachments,
    shallow,
    successor,
    @"mutable-alternatives",
    alternatives,
    recursive,
    mobility,

    fn module(self: Fixture, builder: *horos.source.Builder) !horos.source.Module {
        return switch (self) {
            .gcd => sources.gcd(builder),
            .attachments => sources.distinctAttachments(builder),
            .shallow, .successor => sources.retainedHandlers(builder, self == .shallow),
            .@"mutable-alternatives" => sources.mutableAlternatives(builder),
            .alternatives => sources.alternatives(builder, true),
            .recursive => sources.listLength(builder),
            .mobility => @import("runtime_mobility_source.zig").build(builder),
        };
    }

    fn exposures(self: Fixture) []const c.workspace.Exposure {
        return switch (self) {
            .mobility => &.{
                .{ .effect = 0, .class = .observation },
                .{ .effect = 1, .class = .input },
                .{ .effect = 2, .class = .observation },
            },
            .attachments, .shallow, .successor => &.{.{ .effect = 0, .class = .input }},
            .alternatives, .@"mutable-alternatives" => &.{
                .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative },
            },
            .gcd, .recursive => &.{},
        };
    }
};

fn emitFixture(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    mode: []const u8,
    output: *std.Io.Writer,
) !void {
    const a = arena.allocator();
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const fixture = std.meta.stringToEnum(Fixture, mode) orelse return error.InvalidMode;
    const module = try fixture.module(&builder);
    const transport = try native.source_records.encode(a, module);
    const exposures = fixture.exposures();
    var diagnostic: native.program_construction.Diagnostic = .{};
    const started = std.Io.Clock.awake.now(io);
    var built = native.program_construction.buildExposed(
        a,
        transport,
        exposures,
        null,
        &diagnostic,
    ) catch |err| {
        std.debug.print("{s}: {any}\n", .{ mode, diagnostic });
        return err;
    };
    defer built.deinit();
    const compile_ns = std.Io.Clock.awake.now(io).nanoseconds - started.nanoseconds;
    var generated: ?driver.Generated = if (exposures.len != 0)
        try driver.generate(a, module, exposures)
    else
        null;
    defer if (generated) |*value| value.deinit();
    const interpreted = if (generated) |value| value.module else module;
    // The source given to the oracle must compile to the exact delivered
    // image; an independent source cannot merely share an expected answer.
    var compiled = try horos.source.lowerObserved(a, interpreted, .{ .contract = .structural });
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    if (!std.mem.eql(u8, built.image, image)) return error.SourceImageMismatch;
    var document = try fixtureDocument(a, transport, interpreted, image, compile_ns);
    try native.json.put(
        a,
        &document,
        "compiler_arena_bytes",
        try native.json.number(a, arena.queryCapacity()),
    );
    const cases = try fixtureCases(a, fixture, built.interface.input.bytes);
    try native.json.put(a, &document, "cases", cases);
    try output.writeAll(try native.json.canonical(a, document));
}

fn fixtureDocument(
    a: std.mem.Allocator,
    transport: []const u8,
    interpreted: horos.source.Module,
    image: []const u8,
    compile_ns: i96,
) !native.json.Value {
    var document = native.json.object();
    try native.json.put(a, &document, "transport", native.json.string(transport));
    const raw_source = try std.json.Stringify.valueAlloc(a, interpreted, .{
        .emit_strings_as_arrays = true,
    });
    try native.json.put(a, &document, "source", (try native.json.parse(a, raw_source, .{
        .bytes = raw_source.len,
        .tokens = raw_source.len,
        .members = raw_source.len,
    })).value);
    try native.json.put(
        a,
        &document,
        "image",
        try native.values.toJson(c.Bytes(null), a, .{ .bytes = image }),
    );
    try native.json.put(a, &document, "compile_ns", try native.json.number(a, compile_ns));
    return document;
}

fn fixtureCases(
    a: std.mem.Allocator,
    fixture: Fixture,
    input_schema: []const u8,
) !native.json.Value {
    var cases: native.json.Value = .{ .array = .init(a) };
    switch (fixture) {
        .mobility => try cases.array.append(try mobilityCase(a)),
        .attachments => try cases.array.append(
            try example(a, &.{}, &.{}, try c.encodeOwned(u64, a, 42)),
        ),
        .shallow, .successor => {
            const expected = if (fixture == .shallow)
                try c.encodeOwned([8]u64, a, .{ 99, 99, 99, 99, 42, 42, 42, 42 })
            else
                try c.encodeOwned([2]u64, a, .{ 42, 37 });
            try cases.array.append(try example(a, try c.encodeOwned(void, a, {}), &.{}, expected));
        },
        .alternatives, .@"mutable-alternatives" => try cases.array.append(try alternativesCase(a)),
        .recursive => try cases.array.append(try recursiveCase(a, input_schema)),
        .gcd => for ([_][3]u64{ .{ 48, 18, 6 }, .{ 35, 14, 7 } }) |pair| {
            try cases.array.append(try example(
                a,
                try c.encodeOwned(struct { u64, u64 }, a, .{ pair[0], pair[1] }),
                &.{},
                try c.encodeOwned(u64, a, pair[2]),
            ));
        },
    }
    return cases;
}

fn mobilityCase(a: std.mem.Allocator) !native.json.Value {
    const Command = union(enum) { instantiate: u64, finish: void };
    return example(a, try c.encodeOwned(struct { u64, u64 }, a, .{ 32, 100 }), &.{
        try c.encodeOwned(void, a, {}),
        try c.encodeOwned(Command, a, .{ .instantiate = 10 }),
        try c.encodeOwned(Command, a, .{ .instantiate = 20 }),
        try c.encodeOwned(Command, a, .{ .finish = {} }),
        try c.encodeOwned(void, a, {}),
    }, try c.encodeOwned(u64, a, 184));
}

fn alternativesCase(a: std.mem.Allocator) !native.json.Value {
    const Command = union(enum) { instantiate: u64, finish: void };
    return example(a, try c.encodeOwned(u64, a, 100), &.{
        try c.encodeOwned(void, a, {}),
        try c.encodeOwned(Command, a, .{ .instantiate = 10 }),
        try c.encodeOwned(Command, a, .{ .instantiate = 20 }),
        try c.encodeOwned(Command, a, .{ .finish = {} }),
    }, try c.encodeOwned(u64, a, 121));
}

fn recursiveCase(a: std.mem.Allocator, input_schema: []const u8) !native.json.Value {
    var text: []const u8 = "{\"tag\":0,\"value\":{}}";
    for (0..300) |_| text = try std.fmt.allocPrint(a, "{{\"tag\":1,\"value\":[\"0\",{s}]}}", .{
        text,
    });
    const parsed = try native.json.parse(a, text, .{
        .bytes = text.len,
        .depth = text.len,
        .tokens = text.len,
        .members = text.len,
    });
    return example(
        a,
        try native.dynamic_values.encode(a, input_schema, parsed.value),
        &.{},
        try c.encodeOwned(u64, a, 300),
    );
}

const CapsulePacket = struct {
    image: []const u8,
    runtime: []const u8,
    capsule: []const u8,
    outer: []const u8,
};
const CapsuleCustody = struct {
    expected: kosmos.RuntimeCapsule.Reference,
    consumed: bool = false,
    fn claim(
        context: *anyopaque,
        actual: kosmos.RuntimeCapsule.Reference,
        record: kosmos.RuntimeCapsule.Record,
        target: kosmos.RuntimeCapsule.Reference,
    ) !void {
        const self: *CapsuleCustody = @ptrCast(@alignCast(context));
        if (self.consumed or !std.meta.eql(self.expected, actual) or
            !std.meta.eql(record.provenance.execution, @as([32]u8, @splat(31))) or
            !std.meta.eql(record.provenance.custody, @as([32]u8, @splat(32))) or
            !std.meta.eql(record.artifact, target)) return error.UnauthorizedCapsule;
        self.consumed = true;
    }
    fn verifier(self: *CapsuleCustody) kosmos.RuntimeCapsule.Verifier {
        return .{ .context = self, .claim = claim };
    }
};

fn example(
    a: std.mem.Allocator,
    input: []const u8,
    replies: []const []const u8,
    expected: []const u8,
) !native.json.Value {
    var value = native.json.object();
    try native.json.put(
        a,
        &value,
        "input",
        try native.values.toJson(c.Bytes(null), a, .{ .bytes = input }),
    );
    var responses: native.json.Value = .{ .array = .init(a) };
    for (replies) |reply| try responses.array.append(
        try native.values.toJson(c.Bytes(null), a, .{ .bytes = reply }),
    );
    try native.json.put(a, &value, "responses", responses);
    try native.json.put(
        a,
        &value,
        "expected",
        try native.values.toJson(c.Bytes(null), a, .{ .bytes = expected }),
    );
    return value;
}
