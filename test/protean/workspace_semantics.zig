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
    } else if (std.mem.eql(u8, mode, "capsule-export")) {
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
        var found = false;
        for (0..400) |_| {
            try original.driver.submit(.{ .advance = .{ .control = if (original.driver.last_cut.?.status == .yielded) .resume_yield else .none, .quantum = 1 } });
            while (true) {
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
                    if (anchor.role == .clone_rebase and anchor.function == frame.function) found = true;
                }
                if (found) break;
            }
            if (found) break;
            if (original.driver.last_cut.?.status == .completed) return error.MissingClonePhase;
        }
        if (!found) return error.MissingClonePhase;
        if (original.driver.checkpoint(a)) |_| return error.FalseGuestCut else |err| {
            if (err != error.GuestCutUnavailable) return err;
        }
        const capsule = try kosmos.RuntimeCapsule.publish(a, &original.driver, .outer_execution, .{ .execution = @splat(31), .custody = @splat(32), .publication = null });
        const packet: CapsulePacket = .{ .image = image, .runtime = try prepared.runtime.encode(a), .capsule = capsule, .outer = try original.driver.outer.checkpoint(a) };
        try output.interface.writeAll(try std.json.Stringify.valueAlloc(a, packet, .{ .emit_strings_as_arrays = true }));
    } else if (std.mem.eql(u8, mode, "capsule-import")) {
        var input_buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &input_buffer);
        const bytes = try input.interface.allocRemaining(a, .unlimited);
        const packet = (try std.json.parseFromSlice(CapsulePacket, a, bytes, .{})).value;
        var selected = try kosmos.RuntimeArtifact.init(a, packet.runtime, kosmos.RuntimeCapsule.reference(packet.runtime).digest);
        defer selected.deinit();
        try kosmos.RuntimeCompiler.validate(a, &selected);
        var prepared = try kosmos.Prepared.initWithRuntime(a, packet.image, &selected);
        defer prepared.deinit();
        var custody: CapsuleCustody = .{ .expected = kosmos.RuntimeCapsule.reference(packet.capsule) };
        var restored = try kosmos.RuntimeCapsule.restore(a, &prepared.guest, &selected, packet.capsule, custody.verifier());
        defer restored.deinit();
        if (!std.mem.eql(u8, packet.outer, try restored.outer.checkpoint(a))) return error.ChangedOuterState;
        if (kosmos.RuntimeCapsule.restore(a, &prepared.guest, &selected, packet.capsule, custody.verifier())) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ReusedCustody;
        } else |err| if (err != error.UnauthorizedCapsule) return err;
        var completed = try restored.pump(null);
        defer if (completed == .event) completed.event.deinit();
        if (completed != .event or completed.event.value != .cut) return error.InvalidPhase;
        try output.interface.writeAll(try restored.checkpoint(a));
    } else if (std.mem.eql(u8, mode, "capsule-phase")) {
        // Fixture-only observation of immutable, already published objects.
        // No restore verifier or execution authority is supplied here.
        const runtime_path = args.next() orelse return error.MissingRuntime;
        const capsule_path = args.next() orelse return error.MissingCapsule;
        const runtime_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, runtime_path, a, .unlimited);
        const capsule_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, capsule_path, a, .unlimited);
        var selected = try kosmos.RuntimeArtifact.init(a, runtime_bytes, kosmos.RuntimeCapsule.reference(runtime_bytes).digest);
        defer selected.deinit();
        var envelope = try kosmos.RuntimeCapsule.read(a, capsule_bytes);
        defer envelope.deinit();
        if (envelope.value.record.kind != .outer_execution or envelope.value.record.operation == null or
            !std.meta.eql(envelope.value.record.artifact, kosmos.RuntimeCapsule.reference(runtime_bytes))) return error.InvalidPhase;
        var state = try horos.data.state_image.decodeGraph(a, envelope.value.checkpoint);
        defer state.deinit();
        try horos.data.state_admission.validateAdmitted(a, selected.program, state.state);
        var clone_frames: usize = 0;
        var clone_bindings: usize = 0;
        var active_clone_frames: usize = 0;
        for (state.state.nodes) |node| {
            const block = switch (node.record) {
                .control => |control| control.block,
                .continuation => |continuation| continuation.source_block,
                else => continue,
            };
            const function = selected.program.program().blocks[@intCast(block)].function;
            for (selected.content.value.recovery.anchors) |anchor| {
                if ((anchor.role != .clone_rebase and anchor.role != .clone_context) or anchor.function != function) continue;
                active_clone_frames += 1;
                const frame = node.activation orelse return error.MissingActivation;
                // Lowering can retire entry parameters after their last use.
                // The live continuation locals carry the updated cursor/map.
                // Require execution beyond entry and actual retained locals;
                // a matching declaration alone is not a mid-operation witness.
                if (frame.position == 0 or frame.bindings.len == 0) continue;
                clone_frames += 1;
                clone_bindings += frame.bindings.len;
            }
        }
        try output.interface.print("{{\"clone_frames\":{d},\"clone_bindings\":{d},\"active_clone_frames\":{d},\"outer_revision\":\"{d}\"}}", .{ clone_frames, clone_bindings, active_clone_frames, envelope.value.record.outer_revision });
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

const CapsulePacket = struct { image: []const u8, runtime: []const u8, capsule: []const u8, outer: []const u8 };
const CapsuleCustody = struct {
    expected: kosmos.RuntimeCapsule.Reference,
    consumed: bool = false,
    fn claim(context: *anyopaque, actual: kosmos.RuntimeCapsule.Reference, record: kosmos.RuntimeCapsule.Record, target: kosmos.RuntimeCapsule.Reference) !void {
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

fn example(a: std.mem.Allocator, input: []const u8, replies: []const []const u8, expected: []const u8) !native.json.Value {
    var value = native.json.object();
    try native.json.put(a, &value, "input", try native.values.toJson(c.Bytes(null), a, .{ .bytes = input }));
    var responses: native.json.Value = .{ .array = .init(a) };
    for (replies) |reply| try responses.array.append(try native.values.toJson(c.Bytes(null), a, .{ .bytes = reply }));
    try native.json.put(a, &value, "responses", responses);
    try native.json.put(a, &value, "expected", try native.values.toJson(c.Bytes(null), a, .{ .bytes = expected }));
    return value;
}
