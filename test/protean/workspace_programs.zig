//! Independent execution witnesses for the source-record transport. Algorithms
//! are authored records; no build-time result or native callback is supplied.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;

fn workspaceRef(a: std.mem.Allocator, kind: @FieldType(contracts.workspace.Ref, "kind"), id: [32]u8) !contracts.workspace.Ref {
    return .{ .kind = kind, .id = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)) } };
}

const gcd = @import("workspace_sources.zig").gcd;
const listLength = @import("workspace_sources.zig").listLength;
const alternatives = @import("workspace_sources.zig").alternatives;

/// Reject allocation after an actual store commit, without depending on an
/// allocation ordinal or adding a fault hook to the production owner.
const AfterCommitAllocator = struct {
    backing: std.mem.Allocator,
    namespace: *native.Namespace,
    generation: u64,
    rejected: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn blocked(self: *@This()) bool {
        if (self.namespace.store.head.generation == self.generation) return false;
        self.rejected += 1;
        return true;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.blocked()) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return false;
        return self.backing.rawResize(bytes, alignment, len, ra);
    }
    fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return null;
        return self.backing.rawRemap(bytes, alignment, len, ra);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

/// Keep allocations in an outer arena, but destroy freed contents so an arena
/// cannot accidentally hide a projection borrowing a decoded record's storage.
const PoisonFreedAllocator = struct {
    backing: std.mem.Allocator,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        @memset(bytes, 'X');
    }
};

test "BUILD-07 source build allocation fault sweep releases partial owners and cancellation admits nothing" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(a, try gcd(&builder));
    defer a.free(text);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, document: []const u8) !void {
            var diagnostic: native.program_construction.Diagnostic = .{};
            var built = try native.program_construction.build(allocator, document, null, &diagnostic);
            defer built.deinit();
        }
    };
    var baseline = std.testing.FailingAllocator.init(a, .{});
    try Probe.run(baseline.allocator(), text);
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    // Compiler table traversal can vary its allocation count. Sweep the
    // observed allocation positions without asserting deterministic allocation
    // order or rejecting a lawful optional-allocation fallback.
    var induced: usize = 0;
    for (0..baseline.alloc_index) |position| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = position });
        Probe.run(failing.allocator(), text) catch |err| if (err != error.OutOfMemory) return err;
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        induced += @intFromBool(failing.has_induced_failure);
    }
    try std.testing.expect(induced > 1);
    var canceled = std.atomic.Value(bool).init(true);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectError(error.Canceled, native.program_construction.build(a, text, &canceled, &diagnostic));
}

test "WORK-06 WORK-07 generated driver reuses a template with isolated mutable aliases after one prefix" {
    const a = std.testing.allocator;
    for (0..5) |variant| {
        const multi = variant != 0;
        var builder = source.Builder.init(a);
        defer builder.deinit();
        var module = if (variant == 2 or variant == 3) try @import("workspace_sources.zig").mutableAlternatives(&builder) else try alternatives(&builder, multi);
        if (variant >= 3) {
            const sparse = try builder.allocator().dupe(Id, &.{std.math.maxInt(Id) - 1});
            for (builder.schemas.items) |*schema| if (schema.* == .internal) switch (schema.internal) {
                .region => |*id| id.* = sparse[0],
                .cell => |*cell| cell.region = sparse[0],
                .computation => |*computation| if (computation.regions.len != 0) {
                    computation.regions = sparse;
                },
                else => {},
            };
            for (builder.functions.items) |*function| if (function.regions.len != 0) {
                function.regions = sparse;
            };
            for (builder.terms.items) |*term| if (term.* == .with_region) {
                term.with_region.region = sparse[0];
            };
            builder.region_count = std.math.maxInt(Id);
            module = builder.module(module.entry, module.failure);
        }
        const text = try native.source_records.encode(a, module);
        defer a.free(text);
        var diagnostic: native.program_construction.Diagnostic = .{};
        if (!multi) {
            // An operation declared single-use cannot become multi-shot by
            // requesting an alternative port. Conversion requires a multi
            // operation even when its handler initially owns a linear token.
            try std.testing.expectError(error.InvalidExposure, native.program_construction.buildExposed(a, text, &.{.{ .effect = 1, .class = .alternative }}, null, &diagnostic));
            continue;
        }
        var built = native.program_construction.buildExposed(a, text, &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } }, null, &diagnostic) catch |err| {
            std.debug.print("driver build {s}: phase={s}, function={?d}, term={?d}, value={?d}\n", .{ @errorName(err), @tagName(diagnostic.phase), diagnostic.source.function, diagnostic.source.term, diagnostic.source.value });
            return err;
        };
        defer built.deinit();
        try std.testing.expectEqual(@as(usize, 2), built.ports.len);
        const input = try contracts.encodeOwned(u64, a, 100);
        defer a.free(input);
        var outcome = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .initial_args = input } });
        defer outcome.deinit();
        const Command = union(enum) { instantiate: u64, finish: void };
        for (0..4) |i| {
            try std.testing.expectEqual(.requested, std.meta.activeTag(outcome.record));
            var request = try data.invocation.decode(data.invocation.Request, a, outcome.record.requested.request);
            defer request.deinit();
            if (i == 0) {
                try std.testing.expectEqualStrings("protean.workspace.control/1/0", request.value.binding.semantic_identity);
                var prefix = try contracts.decodeOwned(u64, a, request.value.binding.payload);
                defer prefix.deinit();
                try std.testing.expectEqual(@as(u64, 101), prefix.value);
            } else {
                try std.testing.expectEqualStrings("protean.workspace.control/1/1", request.value.binding.semantic_identity);
                var observed = try contracts.decodeOwned(struct { void, ?u64 }, a, request.value.binding.payload);
                defer observed.deinit();
                try std.testing.expectEqual(@as(?u64, if (i == 1) null else if (i == 2) 111 else 121), observed.value[1]);
            }
            const value = if (i == 0) try contracts.encodeOwned(void, a, {}) else try contracts.encodeOwned(Command, a, if (i == 3) .{ .finish = {} } else .{ .instantiate = if (i == 1) 10 else 20 });
            defer a.free(value);
            const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.value.request_identity, .value = value });
            defer a.free(reply);
            const next = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .state = outcome.record.requested.state.? }, .control = .{ .reply = reply } });
            outcome.deinit();
            outcome = next;
        }
        try std.testing.expectEqual(.completed, std.meta.activeTag(outcome.record));
        var result = try contracts.decodeOwned(u64, a, outcome.record.completed);
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 121), result.value);
    }
}

test "WORK-08 an exclusive resource cannot be captured by a generated alternative port" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const text = try native.source_records.encode(a, try @import("workspace_sources.zig").exclusiveAlternative(&builder));
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    try std.testing.expectError(error.InvalidOwnership, native.program_construction.buildExposed(a, text, &.{.{ .effect = 0, .class = .alternative }}, null, &diagnostic));
}

test "exposure carries capabilities through closed handler returns clauses and shallow successors" {
    const a = std.testing.allocator;
    for (0..6) |variant| {
        const path_variant = if (variant == 5) 0 else variant;
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const u = try b.scalar(u64);
        const ask = try b.effect(.{ .identity = "example/handler-query", .payload = u, .result = u, .external = false });
        const second = if (variant == 5) try b.effect(.{ .identity = "example/second-query", .payload = u, .result = u, .external = false }) else ask;
        const asks: []const Id = if (variant == 5) &.{ ask, second } else &.{ask};
        const local = try b.effect(.{ .identity = "example/local", .payload = unit, .result = unit, .external = false });
        const cap = try b.schema(.{ .internal = .{ .capability = local } });
        const mode: data.program.Mode = if (path_variant == 2) .shallow else .deep;
        const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = local, .input = unit, .answer = if (mode == .deep) u else unit, .effects = if (variant == 5) &.{ ask, second, local } else &.{ ask, local }, .capture_bound = &.{ unit, u, cap }, .handled = &.{local}, .escaping = if (mode == .shallow) asks else &.{}, .mode = mode, .use = .linear } } });
        const helper = try b.declare(&.{u}, u, asks, &.{});
        try b.define(helper, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.reference(b.parameter(helper, 0)) } }));
        if (variant == 5) {
            const response = try b.variable(u);
            b.functions.items[@intCast(helper)].body = try b.bind(response, b.functions.items[@intCast(helper)].body.?, try b.term(.{ .perform = .{ .effect = second, .payload = try b.reference(response) } }));
        }
        const helper_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{u}, .result = u, .effects = asks } } });
        const returns = try b.declare(&.{ u, unit }, u, asks, &.{});
        const returned = try b.reference(b.parameter(returns, 0));
        try b.define(returns, if (path_variant == 0) try b.term(.{ .apply = .{ .computation = try b.lambda(helper, helper_type), .arguments = &.{returned} } }) else try b.pure(returned));
        const clause = try b.declare(&.{ u, unit, token }, u, if (variant == 5) &.{ ask, second, local } else &.{ ask, local }, &.{});
        const handler = try b.handler(.{ .mode = mode, .input = unit, .answer = u, .return_function = returns, .clauses = &.{.{ .effect = local, .function = clause, .resumption = token }}, .state = &.{u}, .effects = if (variant == 5) &.{ ask, second, local } else &.{ ask, local } });
        const answer = try b.variable(u);
        const resumed = if (mode == .shallow)
            try b.term(.{ .resume_with = .{ .resumption = try b.reference(b.parameter(clause, 2)), .argument = try b.constant(void, {}), .handler = handler, .state = &.{try b.reference(answer)} } })
        else
            try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 2)), .argument = try b.constant(void, {}) } });
        try b.define(clause, if (path_variant == 0 or path_variant >= 3) resumed else try b.bind(answer, try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(b.parameter(clause, 0))} } }), resumed));
        const resource = try b.resource(u);
        try b.resourceAuthority(resource, &.{ returns, clause }, &.{ returns, clause });
        for ([_]Id{ returns, clause }) |function| {
            const response = try b.variable(u);
            const owned = try b.variable(resource);
            b.functions.items[@intCast(function)].body = try b.bind(response, b.functions.items[@intCast(function)].body.?, try b.bind(owned, try b.pure(try b.primitive(resource, .resource_pack, &.{try b.reference(response)}, 0)), try b.pure(try b.primitive(u, .resource_unpack, &.{try b.reference(owned)}, 0))));
        }
        const body_effects: []const source.Id = if (path_variant >= 3) if (variant == 5) &.{ ask, second, local } else &.{ ask, local } else &.{local};
        const body = try b.declare(&.{cap}, unit, body_effects, &.{});
        const local_call = try b.term(.{ .perform = .{ .effect = local, .capability = try b.reference(b.parameter(body, 0)), .payload = try b.constant(void, {}) } });
        try b.define(body, if (path_variant >= 3) try b.bind(try b.variable(unit), local_call, try b.bind(try b.variable(u), try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.constant(u64, 17)} } }), try b.pure(try b.constant(void, {})))) else local_call);
        const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = unit, .effects = body_effects } } });
        const entry = try b.declare(&.{unit}, u, if (variant == 5) &.{ ask, second, local } else &.{ ask, local }, &.{});
        const body_value = try b.lambda(body, body_type);
        const stored_body = try b.variable(body_type);
        const handled = try b.term(.{ .handle = .{ .handler = handler, .body = if (path_variant == 4) try b.reference(stored_body) else body_value, .state = &.{try b.constant(u64, 17)} } });
        try b.define(entry, if (path_variant == 4) try b.bind(stored_body, try b.pure(body_value), handled) else handled);
        b.effects.items[@intCast(ask)].external = true;
        b.effects.items[@intCast(second)].external = true;
        var baseline = try source.lower(a, b.module(entry, unit));
        baseline.deinit();
        b.effects.items[@intCast(ask)].external = false;
        b.effects.items[@intCast(second)].external = false;
        const text = try native.source_records.encode(a, b.module(entry, unit));
        defer a.free(text);
        var diagnostic: native.program_construction.Diagnostic = .{};
        var built = native.program_construction.buildExposed(a, text, if (variant == 5) &.{ .{ .effect = ask, .class = .input }, .{ .effect = second, .class = .input } } else &.{.{ .effect = ask, .class = .input }}, null, &diagnostic) catch |err| {
            std.debug.print("handler variant {d}: {s} {any}\n", .{ variant, @errorName(err), diagnostic });
            return err;
        };
        defer built.deinit();
        var suspended = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .initial_args = &.{} } });
        defer suspended.deinit();
        try std.testing.expectEqual(.requested, std.meta.activeTag(suspended.record));
        var request = try data.invocation.decode(data.invocation.Request, a, suspended.record.requested.request);
        defer request.deinit();
        const expected = try contracts.encodeOwned(u64, a, 17);
        defer a.free(expected);
        try std.testing.expectEqualSlices(u8, expected, request.value.binding.payload);
        const value = try contracts.encodeOwned(u64, a, 42);
        defer a.free(value);
        const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.value.request_identity, .value = value });
        defer a.free(reply);
        var completed = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .state = suspended.record.requested.state.? }, .control = .{ .reply = reply } });
        defer completed.deinit();
        if (variant == 5) {
            try std.testing.expectEqual(.requested, std.meta.activeTag(completed.record));
            var next_request = try data.invocation.decode(data.invocation.Request, a, completed.record.requested.request);
            defer next_request.deinit();
            try std.testing.expectEqualSlices(u8, value, next_request.value.binding.payload);
            const next_reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = next_request.value.request_identity, .value = value });
            defer a.free(next_reply);
            const next = try kosmos.invocation.invoke(a, .{ .image = built.image, .instance = .{ .state = completed.record.requested.state.? }, .control = .{ .reply = next_reply } });
            completed.deinit();
            completed = next;
        }
        try std.testing.expectEqual(.completed, std.meta.activeTag(completed.record));
        try std.testing.expectEqualSlices(u8, if (path_variant == 1 or path_variant >= 3) expected else value, completed.record.completed);
        // Transporting authority must never invent authority for an invalid
        // original body, even when all its callers are generated handlers.
        const resource_id = b.schemas.items[@intCast(resource)].internal.abstract_resource;
        b.resources.items[@intCast(resource_id)].introducers = &.{};
        b.resources.items[@intCast(resource_id)].eliminators = &.{};
        const unauthorized = try native.source_records.encode(a, b.module(entry, unit));
        defer a.free(unauthorized);
        try std.testing.expectError(error.InvalidOwnership, native.program_construction.buildExposed(a, unauthorized, if (variant == 5) &.{ .{ .effect = ask, .class = .input }, .{ .effect = second, .class = .input } } else &.{.{ .effect = ask, .class = .input }}, null, &diagnostic));
    }
}

fn compile(a: std.mem.Allocator, b: *source.Builder, module: source.Module) !native.program_construction.Built {
    _ = b;
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    return native.program_construction.build(a, text, null, &diagnostic);
}

fn execute(a: std.mem.Allocator, prepared: *kosmos.Prepared, input: []const u8, expected: u64) !u64 {
    var session = try kosmos.Session.start(a, prepared, input);
    defer session.deinit();
    var quanta: u64 = 0;
    while (true) {
        quanta += 1;
        switch (try session.run(8)) {
            .progressed => {},
            .yielded => try session.resumeYield(),
            .completed => |value| {
                var result = try contracts.decodeOwned(u64, a, try session.bytes(&value));
                defer result.deinit();
                try std.testing.expectEqual(expected, result.value);
                return quanta;
            },
            else => return error.UnexpectedOutcome,
        }
    }
}

test "BUILD-01 concrete native execution reuses novel GCD source on independent inputs" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var built = try compile(a, &builder, try gcd(&builder));
    defer built.deinit();
    var prepared = try kosmos.Prepared.init(a, built.image);
    defer prepared.deinit();
    for ([_]struct { x: u64, y: u64, expected: u64 }{
        .{ .x = 1071, .y = 462, .expected = 21 },
        .{ .x = 97, .y = 89, .expected = 1 },
        .{ .x = 0, .y = 55, .expected = 55 },
        .{ .x = 123456, .y = 0, .expected = 123456 },
    }) |case| {
        const input = try contracts.encodeOwned(struct { u64, u64 }, a, .{ case.x, case.y });
        defer a.free(input);
        _ = try execute(a, &prepared, input, case.expected);
    }
}

test "BUILD-02 concrete native execution traverses recursive structured input over many quanta" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var built = try compile(a, &builder, try listLength(&builder));
    defer built.deinit();
    var prepared = try kosmos.Prepared.init(a, built.image);
    defer prepared.deinit();
    for ([_]usize{ 0, 3, 300 }) |length| {
        const input = try a.alloc(u8, length * 9 + 1);
        defer a.free(input);
        var writer: data.wire.Writer = .{ .output = input };
        for (0..length) |i| {
            try writer.natural(1);
            try writer.fixed(u64, @intCast(i * 7));
        }
        try writer.natural(0);
        const quanta = try execute(a, &prepared, input, length);
        if (length != 0) try std.testing.expect(quanta > length);
    }
}

const OwnerTypes = struct {
    pub const application_id = "workspace-owner-test";
    pub const input_schema_id = "workspace-owner.input/1";
    pub const output_schema_id = "workspace-owner.output/1";
    pub const failure_schema_id = "workspace-owner.failure/1";
    pub const message_schema_id = "workspace-owner.message/1";
    pub const Input = struct { u64, u64 };
    pub const Output = u64;
    pub const Failure = void;
    pub const Message = void;
};

fn expectContextOutputBound(service: anytype, a: std.mem.Allocator, task: native.testing.state.TaskId, operation_id: []const u8, replacement: contracts.workspace.Ref, replacement_reply: ?contracts.workspace.Reply) !void {
    const store = &service.namespace.store;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    try store.begin();
    defer store.rollback();
    var operations = try store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &task }});
    defer operations.deinit();
    var changed = false;
    var revision: u64 = 0;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(native.testing.state.Receipt, a, try operations.bytes(1))).value;
        if (!std.mem.eql(u8, receipt.client_operation_id.bytes, operation_id)) continue;
        revision = receipt.revision;
        try std.testing.expectEqual(replacement.kind, receipt.workspace_kind.?);
        receipt.workspace = try nativeIdentity(replacement);
        receipt.workspace_observation = try store.objectReference(receipt.workspace.?, null);
        const rewritten = try store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, a, receipt));
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &rewritten.digest }, .{ .text = try operations.bytes(0) } });
        var events = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.revision=?", &.{ .{ .blob = &task }, .{ .integer = @intCast(receipt.revision) } });
        defer events.deinit();
        try std.testing.expect(try events.step() == .row);
        var event_value = (try contracts.decodeOwned(native.testing.state.Event, a, try events.bytes(0))).value;
        event_value.data.bytes = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{replacement.id.bytes});
        const event_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, event_value));
        try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &task }, .{ .integer = @intCast(event_value.seq) } });
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    if (replacement_reply) |reply| {
        var id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id, operation_id);
        var pending = (try contracts.decodeOwned(native.testing.occurrence.Occurrence, a, (try store.recordBytes(a, "occurrence", id, task)).?)).value;
        var projected = reply;
        var observation = (try native.json.parse(a, reply.observation_json.bytes, .{})).value;
        try native.json.put(a, &observation, "receipt_revision", try native.json.number(a, revision));
        projected.observation_json.bytes = try native.json.canonical(a, observation);
        const payload = try contracts.encodeOwned(contracts.workspace.Reply, a, projected);
        const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = payload });
        pending.state.settled_reply.reply = (try store.putObject(bound)).digest;
        try store.putRecord(native.testing.occurrence.Occurrence, "occurrence", id, task, pending);
    }
    // All substituted objects remain legitimate task-owned artifacts; receipt,
    // event and optional acquired reply have coherent content hashes.
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(a, task, index.records.items));
}

fn expectWorkInputHistoryBound(service: anytype, a: std.mem.Allocator, task: native.testing.state.TaskId, work_id: [32]u8, inputs: []const native.testing.state.Reference) !void {
    const store = &service.namespace.store;
    var work = try service.workspaceWork(a, task, work_id);
    defer work.deinit();
    try std.testing.expect(work.value.result == null);
    const extra = inputs.len - work.value.inputs.items.len;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    try store.begin();
    defer store.rollback();
    work.value.inputs.items = inputs;
    try store.putRecord(native.workspace.Work, "workspace_work", work_id, task, work.value);
    var operations = try store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &task }});
    defer operations.deinit();
    var changed: usize = 0;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(native.testing.state.Receipt, a, try operations.bytes(1))).value;
        if (receipt.workspace_kind != .work or !std.meta.eql(receipt.workspace, work_id)) continue;
        var observation = (try contracts.decodeOwned(native.workspace.WorkObservation, a, try store.object(a, receipt.workspace_observation.?, null))).value;
        observation.work.inputs.items = inputs[0 .. observation.work.inputs.items.len + extra];
        const snapshot = try store.putObject(try contracts.encodeOwned(native.workspace.WorkObservation, a, observation));
        receipt.workspace_observation = snapshot;
        const rewritten = try store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, a, receipt));
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &rewritten.digest }, .{ .text = try operations.bytes(0) } });
        var events = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &task }, .{ .integer = @intCast(observation.work.event_watermark) } });
        defer events.deinit();
        try std.testing.expect(try events.step() == .row);
        var event_value = (try contracts.decodeOwned(native.testing.state.Event, a, try events.bytes(0))).value;
        const publications = try a.dupe(native.testing.state.WorkPublication, event_value.workspace_publications.items);
        for (publications) |*item| if (std.meta.eql(item.work, work_id)) {
            item.observation = snapshot.digest;
        };
        event_value.workspace_publications.items = publications;
        const event_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, event_value));
        try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &task }, .{ .integer = @intCast(event_value.seq) } });
        changed += 1;
    }
    try std.testing.expect(changed != 0);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(a, task, index.records.items));
}

fn expectWorkCancellationReasonBound(service: anytype, a: std.mem.Allocator, child: native.workspace.Work) !void {
    try std.testing.expect(child.cancellation_applied and !child.terminal() and child.current_occurrence == null);
    const store = &service.namespace.store;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, child.task, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    var graph = try data.state_image.decodeGraph(a, try store.object(a, child.checkpoint, null));
    defer graph.deinit();
    const nodes = try a.dupe(data.process_state.Node, graph.state.nodes);
    defer a.free(nodes);
    graph.state.nodes = nodes;
    var cursor = graph.state.roots.exit orelse return error.MissingCancellation;
    while (nodes[@intCast(cursor.id)].record.exit.outer) |outer| cursor = outer;
    nodes[@intCast(cursor.id)].record.exit.cancellation = .{ .text = "different kernel reason" };
    try store.begin();
    defer store.rollback();
    var forged = child;
    forged.checkpoint = try store.putObject(try data.state_image.emit(a, graph.state));
    try store.putRecord(native.workspace.Work, "workspace_work", child.id, child.task, forged);
    var operations = try store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &child.task }});
    defer operations.deinit();
    var changed: usize = 0;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(native.testing.state.Receipt, a, try operations.bytes(1))).value;
        if (receipt.workspace_kind != .work or !std.meta.eql(receipt.workspace, child.id)) continue;
        var observation = (try contracts.decodeOwned(native.workspace.WorkObservation, a, try store.object(a, receipt.workspace_observation.?, null))).value;
        if (observation.work.execution_revision != child.execution_revision) continue;
        observation.work.checkpoint = forged.checkpoint;
        const snapshot = try store.putObject(try contracts.encodeOwned(native.workspace.WorkObservation, a, observation));
        receipt.workspace_observation = snapshot;
        const rewritten = try store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, a, receipt));
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &rewritten.digest }, .{ .text = try operations.bytes(0) } });
        var events = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &child.task }, .{ .integer = @intCast(observation.work.event_watermark) } });
        defer events.deinit();
        try std.testing.expect(try events.step() == .row);
        var event_value = (try contracts.decodeOwned(native.testing.state.Event, a, try events.bytes(0))).value;
        const publications = try a.dupe(native.testing.state.WorkPublication, event_value.workspace_publications.items);
        for (publications) |*item| if (std.meta.eql(item.work, child.id)) {
            item.observation = snapshot.digest;
        };
        event_value.workspace_publications.items = publications;
        const event_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, event_value));
        try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &child.task }, .{ .integer = @intCast(event_value.seq) } });
        changed += 1;
    }
    try std.testing.expect(changed != 0);
    // Native reason, command, event control facts and operation identity stay
    // unchanged; only the kernel checkpoint and its content references differ.
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(a, child.task, index.records.items));
}

fn expectInteractionReplyBound(service: anytype, a: std.mem.Allocator, task: native.testing.state.TaskId, operation_id: []const u8) !void {
    const store = &service.namespace.store;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    try store.begin();
    defer store.rollback();
    var operations = try store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &task }});
    defer operations.deinit();
    var changed = false;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(native.testing.state.Receipt, a, try operations.bytes(1))).value;
        if (!std.mem.eql(u8, receipt.client_operation_id.bytes, operation_id)) continue;
        var events = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.revision=?", &.{ .{ .blob = &task }, .{ .integer = @intCast(receipt.revision) } });
        defer events.deinit();
        try std.testing.expect(try events.step() == .row);
        var event_value = (try contracts.decodeOwned(native.testing.state.Event, a, try events.bytes(0))).value;
        var declared = (try contracts.decodeOwned(native.workspace.PublicationCommand, a, try store.object(a, event_value.workspace_command.?, null))).value;
        try std.testing.expectEqualStrings("\"10\"", declared.interact.command.resume_value.inline_json.json_text.bytes);
        declared.interact.command.resume_value.inline_json.json_text.bytes = "\"20\"";
        event_value.workspace_command = try store.putObject(try contracts.encodeOwned(native.workspace.PublicationCommand, a, declared));
        const event_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, event_value));
        try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &task }, .{ .integer = @intCast(event_value.seq) } });
        const request = try contracts.encodeOwned(native.workspace.InteractionRequest, a, .{ .task = task, .interaction = declared.interact });
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("agent.native.operation.v1\x00");
        hash.update(request);
        hash.final(&receipt.request_digest);
        const receipt_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, a, receipt));
        try store.database.run("UPDATE operations SET receipt=?,request=? WHERE id=?", &.{ .{ .blob = &receipt_ref.digest }, .{ .blob = &receipt.request_digest }, .{ .text = try operations.bytes(0) } });
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    // Both 10 and 20 are valid inputs of the same work. Neither membership nor
    // a coherent request digest ties this command to its actual acquired reply.
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(a, task, index.records.items));
}

fn expectProgramProgressIsDerived(service: anytype, a: std.mem.Allocator, task_id: native.testing.state.TaskId) !void {
    const store = &service.namespace.store;
    var query = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq", &.{.{ .blob = &task_id }});
    defer query.deinit();
    var first: ?contracts.Decoded(native.testing.state.Event) = null;
    defer if (first) |*event_value| event_value.deinit();
    var bare_progress = false;
    while (try query.step() == .row) {
        var event_value = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
        defer event_value.deinit();
        if (first == null) first = try contracts.decodeOwned(native.testing.state.Event, a, try query.bytes(0));
        if (event_value.value.kind == .workspace_progress and event_value.value.workspace_publications.items.len == 0) bare_progress = true;
    }
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task_id, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    try service.validateWorkspaceRecords(a, task_id, index.records.items);
    // Neither successful compilation nor delegation authorizes an independent
    // program claim in the journal, even when its object digest is recomputed.
    try store.begin();
    defer store.rollback();
    var forged = first.?.value;
    forged.kind = .workspace_progress;
    forged.workspace_publications = .{ .items = &.{} };
    forged.data.bytes = "{\"workspace_id\":\"0000000000000000000000000000000000000000000000000000000000000000\"}";
    const reference = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, forged));
    try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &reference.digest }, .{ .blob = &task_id }, .{ .integer = @intCast(forged.seq) } });
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(a, task_id, index.records.items));
    try std.testing.expect(!bare_progress);
}

test "WORK-01 retained work keeps controller state distinct and replays exact admissions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "workspace-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "workspace-unit", .manifest = "{}" };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "workspace-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });
    var initial = try service.task(a, parent.receipt.task);
    defer initial.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    const repeated = try service.workspaceBuild(scratch, "build", parent.receipt.task, document, &diagnostic);
    try std.testing.expect(repeated.replayed);
    try std.testing.expectEqualDeep(program.receipt.workspace, repeated.receipt.workspace);
    const input = try a.alloc(u8, 300 * 9 + 1);
    defer a.free(input);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const started = try service.workspaceStart(scratch, "start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    const duplicate = try service.workspaceStart(scratch, "start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    try std.testing.expect(duplicate.replayed);
    try std.testing.expectEqualDeep(started.receipt.workspace, duplicate.receipt.workspace);
    const id = started.receipt.workspace.?;
    var work = try service.workspaceWork(a, parent.receipt.task, id);
    defer work.deinit();
    try std.testing.expect(!work.value.terminal());
    try std.testing.expectEqual(.parked, work.value.schedule);
    _ = try service.workspaceControl(scratch, "advance", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance);
    const replayed = try service.workspaceControl(scratch, "advance", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance);
    try std.testing.expect(replayed.replayed);
    try std.testing.expectError(error.StaleRevision, service.workspaceControl(scratch, "stale", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance));
    var after = try service.task(a, parent.receipt.task);
    defer after.deinit();
    try std.testing.expectEqualDeep(initial.value.checkpoint, after.value.checkpoint);
    try std.testing.expectEqualDeep(initial.value.current_occurrence, after.value.current_occurrence);
    try std.testing.expectEqual(initial.value.execution_revision, after.value.execution_revision);
    try std.testing.expect(after.value.revision > initial.value.revision);
    const abandoned = try service.workspaceStart(scratch, "abandon-start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    var abandoned_work = try service.workspaceWork(a, parent.receipt.task, abandoned.receipt.workspace.?);
    defer abandoned_work.deinit();
    _ = try service.workspaceControl(scratch, "cancel", parent.receipt.task, abandoned_work.value.id, abandoned_work.value.execution_revision, abandoned_work.value.control_revision, .{ .cancel = .{ .bytes = "investigate another input" } });
    var cancelled = try service.workspaceWork(a, parent.receipt.task, abandoned_work.value.id);
    defer cancelled.deinit();
    try std.testing.expectEqual(.cancelled, cancelled.value.outcome_kind);
    try std.testing.expect(cancelled.value.cancellation_applied);
    try std.testing.expect(cancelled.value.result == null);
    const foreign_cancel = try service.submit(scratch, "foreign-cancel-parent", .{ 25, 5 });
    const foreign_program = try service.workspaceBuild(scratch, "foreign-cancel-build", foreign_cancel.receipt.task, document, &diagnostic);
    const foreign_child = try service.workspaceStart(scratch, "foreign-cancel-child", foreign_cancel.receipt.task, foreign_program.receipt.workspace.?, input, .{});
    try service.park(scratch);
    try service.close(scratch);
    var observation_profile = profile;
    observation_profile.bytes = "different-launch-configuration";
    service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, observation_profile);
    var reader: native.client.Client(OwnerTypes) = .{ .service = &service };
    var status_params = native.json.object();
    try native.json.put(scratch, &status_params, "task_id", native.json.string(try std.fmt.allocPrint(scratch, "{s}", .{std.fmt.bytesToHex(parent.receipt.task, .lower)})));
    const reopened_status = try reader.call(scratch, .@"task.status", status_params);
    try std.testing.expect(!reopened_status.object.get("associated_work_disposed").?.bool);
    _ = try reader.call(scratch, .@"task.result", status_params);
    try std.testing.expectError(error.IncompatibleProfile, service.workspaceWork(scratch, parent.receipt.task, id));
    _ = try service.requestCancel(scratch, "foreign-cancel", foreign_cancel.receipt.task, "retain intent without execution authority");
    try std.testing.expectEqual(.idle, try service.pump(scratch));
    var blocked_cancel = try service.task(scratch, foreign_cancel.receipt.task);
    defer blocked_cancel.deinit();
    try std.testing.expectEqual(.blocked, try service.status(scratch, blocked_cancel.value));
    try std.testing.expectEqual(.incompatible_profile, blocked_cancel.value.blocker.?);
    try std.testing.expect(!try service.associatedWorkDisposed(scratch, foreign_cancel.receipt.task));
    const independent = try service.submit(scratch, "compatible-independent", .{ 25, 5 });
    for (0..32) |_| {
        _ = try service.pump(scratch);
        var independent_state = try service.task(scratch, independent.receipt.task);
        defer independent_state.deinit();
        if (independent_state.value.terminal()) break;
    }
    var independent_result = try service.task(scratch, independent.receipt.task);
    defer independent_result.deinit();
    try std.testing.expectEqual(.completed, independent_result.value.outcome_kind);
    try service.close(scratch);
    service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    _ = try service.requestCancel(scratch, "compatible-cancel", foreign_cancel.receipt.task, "retain intent without execution authority");
    for (0..32) |_| {
        _ = try service.pump(scratch);
        var current_cancel = try service.task(scratch, foreign_cancel.receipt.task);
        defer current_cancel.deinit();
        if (try service.taskCleanupComplete(scratch, current_cancel.value)) break;
    }
    var disposed_cancel = try service.task(scratch, foreign_cancel.receipt.task);
    defer disposed_cancel.deinit();
    try std.testing.expect(try service.taskCleanupComplete(scratch, disposed_cancel.value));
    try std.testing.expect(disposed_cancel.value.blocker == null);
    var disposed_child = try service.workspaceWork(scratch, foreign_cancel.receipt.task, foreign_child.receipt.workspace.?);
    defer disposed_child.deinit();
    try std.testing.expectEqual(.cancelled, disposed_child.value.outcome_kind);
    const recovered = try service.workspaceControl(scratch, "advance", parent.receipt.task, id, work.value.execution_revision, work.value.control_revision, .advance);
    try std.testing.expect(recovered.replayed);
    var retained = try service.workspaceWork(a, parent.receipt.task, id);
    defer retained.deinit();
    _ = try service.workspaceControl(scratch, "delegate", parent.receipt.task, id, retained.value.execution_revision, retained.value.control_revision, .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } });
    var turns: usize = 0;
    while (turns < 1000) : (turns += 1) {
        const step = try service.pump(scratch);
        try std.testing.expect(step != .work);
        var observed = try service.workspaceWork(a, parent.receipt.task, id);
        defer observed.deinit();
        if (observed.value.terminal()) {
            try std.testing.expectEqual(.completed, observed.value.outcome_kind);
            const bytes = try namespace.store.object(a, observed.value.result.?, null);
            defer a.free(bytes);
            var result = try contracts.decodeOwned(u64, a, bytes);
            defer result.deinit();
            try std.testing.expectEqual(300, result.value);
            break;
        }
    }
    try std.testing.expect(turns < 1000);
    try std.testing.expect(turns > 200);
    var final_parent = try service.task(a, parent.receipt.task);
    defer final_parent.deinit();
    try std.testing.expectEqualDeep(initial.value.checkpoint, final_parent.value.checkpoint);
    try std.testing.expectEqual(initial.value.execution_revision, final_parent.value.execution_revision);
    const first_zero = try service.workspaceStart(scratch, "zero-one", parent.receipt.task, program.receipt.workspace.?, &.{0}, .{});
    const second_zero = try service.workspaceStart(scratch, "zero-two", parent.receipt.task, program.receipt.workspace.?, &.{0}, .{});
    var first = try service.workspaceWork(a, parent.receipt.task, first_zero.receipt.workspace.?);
    defer first.deinit();
    var second = try service.workspaceWork(a, parent.receipt.task, second_zero.receipt.workspace.?);
    defer second.deinit();
    try std.testing.expectEqualDeep(first.value.result.?, second.value.result.?);
    try std.testing.expect(!std.meta.eql(first.value.result_value.?, second.value.result_value.?));
    // WORK-11: independent subjects share neither execution nor the parent.
    // Collection preserves caller order, repetitions and explicit non-results.
    const pending_collection = try service.workspaceStart(scratch, "collection-pending", parent.receipt.task, program.receipt.workspace.?, input, .{});
    const collection_ids = [_][32]u8{ second.value.id, abandoned_work.value.id, @splat(0), pending_collection.receipt.workspace.?, first.value.id, second.value.id };
    var collection_refs: [collection_ids.len]contracts.workspace.Ref = undefined;
    for (collection_ids, &collection_refs) |collection_id, *ref| ref.* = try workspaceRef(scratch, .work, collection_id);
    const collected = try service.workspaceCommand(scratch, "ordered-collection", parent.receipt.task, .{ .work = .{ .collect = .{ .works = .{ .items = &collection_refs } } } });
    try std.testing.expectEqual(.observed, collected.disposition);
    var collection_json = try native.json.parse(a, collected.observation_json.bytes, .{});
    defer collection_json.deinit();
    try std.testing.expectEqual(collection_ids.len, collection_json.value.array.items.len);
    const expected_outcomes = [_][]const u8{ "completed", "cancelled", "unavailable", "yielded", "completed", "completed" };
    for (collection_json.value.array.items, collection_refs, expected_outcomes) |item, ref, expected| {
        try std.testing.expectEqualStrings(ref.id.bytes, item.object.get("work").?.object.get("id").?.string);
        try std.testing.expectEqualStrings(expected, item.object.get("outcome").?.string);
    }
    // A controller can choose a collected value as report evidence without
    // inspecting retained work or creating a new judgment/provenance identity.
    const collected_value = try native.values.fromJson(contracts.workspace.Ref, scratch, collection_json.value.array.items[0].object.get("result").?);
    const cited = try service.workspaceCommand(scratch, "cite-collected-result", parent.receipt.task, .{ .context = .{ .materialize = .{ .input = .{ .value = .{ .reference = collected_value } }, .sources = .{ .items = &.{} } } } });
    try std.testing.expectEqualDeep(collected_value, cited.evidence.?);
    const cited_json = (try native.json.parse(scratch, cited.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("computation", cited_json.object.get("derivation").?.object.get("kind").?.string);
    var collection_parent = try service.task(a, parent.receipt.task);
    defer collection_parent.deinit();
    try std.testing.expectEqualDeep(initial.value.checkpoint, collection_parent.value.checkpoint);
    try std.testing.expectEqual(initial.value.execution_revision, collection_parent.value.execution_revision);
    // Context inspection serializes a page, not a JSON tree for all work.
    for (0..256) |i| _ = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "scope-work-{d}", .{i}), parent.receipt.task, program.receipt.workspace.?, &.{0}, .{});
    var expected_scope: native.json.Value = .{ .array = .init(scratch) };
    var scope_query = try namespace.store.database.prepare("SELECT id FROM records WHERE task=? AND kind='workspace_work' ORDER BY id", &.{.{ .blob = &parent.receipt.task }});
    while (try scope_query.step() == .row) {
        const scope_id = try scope_query.bytes(0);
        try expected_scope.array.append(try native.values.toJson(contracts.workspace.Ref, scratch, try workspaceRef(scratch, .work, scope_id[0..32].*)));
    }
    scope_query.deinit();
    const scope_text = try native.json.canonical(scratch, expected_scope);
    const scope_budget_bytes = try a.alloc(u8, 32 * 1024);
    defer a.free(scope_budget_bytes);
    for ([_]u64{ 0, 63, scope_text.len - 7, scope_text.len }) |offset| {
        var scope_budget = std.heap.FixedBufferAllocator.init(scope_budget_bytes);
        const page = try service.workspaceCommand(scope_budget.allocator(), "scope-page", parent.receipt.task, .{ .context = .{ .inspect = .{ .page = .{ .offset = offset, .maximum = 64 } } } });
        try std.testing.expectEqual(.observed, page.disposition);
        const rendered = (try native.json.parse(scratch, page.observation_json.bytes, .{})).value;
        try std.testing.expectEqualStrings(scope_text[@intCast(offset)..][0..@min(64, scope_text.len - offset)], rendered.object.get("text").?.string);
        try std.testing.expectEqual(scope_text.len, try native.json.numberInteger(usize, rendered.object.get("total_bytes").?.number_string));
    }
    // A scalar disposal observation need not retain all historical work while
    // scanning it. Exercise the actual client frame allocator at several sizes.
    const status_parent = try service.submit(scratch, "status-history-parent", .{ 25, 5 });
    const status_program = try service.workspaceBuild(scratch, "status-history-build", status_parent.receipt.task, document, &diagnostic);
    var history_params = native.json.object();
    try native.json.put(scratch, &history_params, "task_id", native.json.string(try std.fmt.allocPrint(scratch, "{s}", .{std.fmt.bytesToHex(status_parent.receipt.task, .lower)})));
    const status_memory = try a.alloc(u8, 64 * 1024);
    defer a.free(status_memory);
    var status_scratch_max: usize = 0;
    for (0..1024) |i| {
        _ = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "status-history-{d}", .{i}), status_parent.receipt.task, status_program.receipt.workspace.?, &.{0}, .{});
        if (i != 0 and i != 31 and i != 255 and i != 1023) continue;
        var status_budget = std.heap.FixedBufferAllocator.init(status_memory);
        var frame = std.heap.ArenaAllocator.init(status_budget.allocator());
        defer frame.deinit();
        var measured = std.testing.FailingAllocator.init(a, .{});
        const observed = observe: {
            const original_allocator = service.allocator;
            defer service.allocator = original_allocator;
            service.allocator = measured.allocator();
            break :observe try reader.call(frame.allocator(), .@"task.status", history_params);
        };
        try std.testing.expect(observed.object.get("associated_work_disposed").?.bool);
        try std.testing.expectEqual(measured.allocated_bytes, measured.freed_bytes);
        status_scratch_max = @max(status_scratch_max, measured.allocated_bytes);
        if (measured.allocated_bytes > 64 * 1024)
            std.debug.print("disposal status: {d} completed works, {d} scratch allocated bytes\n", .{ i + 1, measured.allocated_bytes });
    }
    try std.testing.expect(status_scratch_max <= 64 * 1024);
    // AUT-08: no authored yields or ports are needed for whole-work controls.
    var noncooperative_builder = source.Builder.init(a);
    defer noncooperative_builder.deinit();
    const noncooperative_source = try native.source_records.encode(scratch, try @import("workspace_sources.zig").listLengthWithYields(&noncooperative_builder, false));
    const noncooperative_program = try service.workspaceBuild(scratch, "noncooperative-build", parent.receipt.task, noncooperative_source, &diagnostic);
    const noncooperative_start = try service.workspaceStart(scratch, "noncooperative-start", parent.receipt.task, noncooperative_program.receipt.workspace.?, input, .{});
    var noncooperative = try service.workspaceWork(scratch, parent.receipt.task, noncooperative_start.receipt.workspace.?);
    defer noncooperative.deinit();
    try std.testing.expectEqual(.progressed, noncooperative.value.outcome_kind);
    try std.testing.expectEqual(null, noncooperative.value.current_port);
    _ = try service.workspaceControl(scratch, "noncooperative-park", parent.receipt.task, noncooperative.value.id, noncooperative.value.execution_revision, noncooperative.value.control_revision, .park);
    var parked_noncooperative = try service.workspaceWork(scratch, parent.receipt.task, noncooperative.value.id);
    defer parked_noncooperative.deinit();
    _ = try service.workspaceControl(scratch, "noncooperative-cancel", parent.receipt.task, noncooperative.value.id, parked_noncooperative.value.execution_revision, parked_noncooperative.value.control_revision, .{ .cancel = .{ .bytes = "controller changed direction" } });
    var cancelled_noncooperative = try service.workspaceWork(scratch, parent.receipt.task, noncooperative.value.id);
    defer cancelled_noncooperative.deinit();
    try std.testing.expectEqual(.cancelled, cancelled_noncooperative.value.outcome_kind);
    const value_ref: contracts.workspace.Ref = .{ .kind = .value, .id = .{ .bytes = &std.fmt.bytesToHex(first.value.result_value.?.digest, .lower) } };
    const expanded = try service.workspaceCommand(scratch, "expand-zero", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = value_ref, .page = .{} } } });
    try std.testing.expectEqual(.observed, expanded.disposition);
    var expansion = try native.json.parse(a, expanded.observation_json.bytes, .{});
    defer expansion.deinit();
    try std.testing.expectEqualStrings("\"0\"", expansion.value.object.get("text").?.string);
    var stored_program = try service.workspaceProgram(a, parent.receipt.task, program.receipt.workspace.?);
    defer stored_program.deinit();
    const materialize: contracts.workspace.Command = .{ .context = .{ .materialize = .{
        .input = .{ .value = .{ .inline_json = .{ .schema = .{ .kind = .schema, .id = .{ .bytes = &std.fmt.bytesToHex(stored_program.value.description.result_schema.digest, .lower) } }, .json_text = .{ .bytes = "\"44\"" } } } },
        .sources = .{ .items = &.{value_ref} },
    } } };
    const judgment = try service.workspaceCommand(scratch, "context-judgment", parent.receipt.task, materialize);
    try std.testing.expectEqual(.observed, judgment.disposition);
    var judgment_json = try native.json.parse(a, judgment.observation_json.bytes, .{});
    defer judgment_json.deinit();
    const judgment_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, judgment_json.value.object.get("value").?);
    try std.testing.expectEqualStrings("judgment", judgment_json.value.object.get("derivation").?.object.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 1), judgment_json.value.object.get("derivation").?.object.get("sources").?.array.items.len);
    const selection: contracts.workspace.Command = .{ .context = .{ .select = .{ .values = .{ .items = &.{ judgment_ref, value_ref } } } } };
    const selected = try service.workspaceCommand(scratch, "context-select", parent.receipt.task, selection);
    try std.testing.expectEqual(.observed, selected.disposition);
    try std.testing.expectEqual(.view, selected.selected_view.?.kind);
    const repeated_selection = try service.workspaceCommand(scratch, "context-select", parent.receipt.task, selection);
    try std.testing.expectEqualStrings(selected.selected_view.?.id.bytes, repeated_selection.selected_view.?.id.bytes);
    var hypothesis_command = materialize;
    hypothesis_command.context.materialize.sources.items = &.{};
    const equal_payload = try service.workspaceCommand(scratch, "context-equal-hypothesis", parent.receipt.task, hypothesis_command);
    const equal_json = (try native.json.parse(scratch, equal_payload.observation_json.bytes, .{})).value;
    const equal_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, equal_json.object.get("value").?);
    try expectContextOutputBound(&service, scratch, parent.receipt.task, "context-judgment", equal_ref, null);
    try expectContextOutputBound(&service, scratch, parent.receipt.task, "context-equal-hypothesis", value_ref, null);
    const alias = try service.workspaceCommand(scratch, "context-alias", parent.receipt.task, .{ .context = .{ .materialize = .{ .input = .{ .value = .{ .reference = judgment_ref } }, .sources = .{ .items = &.{} } } } });
    const alias_json = (try native.json.parse(scratch, alias.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings(judgment_ref.id.bytes, alias_json.object.get("value").?.object.get("id").?.string);
    try expectContextOutputBound(&service, scratch, parent.receipt.task, "context-alias", equal_ref, null);
    _ = try service.workspaceCommand(scratch, "context-sourced-reference", parent.receipt.task, .{ .context = .{ .materialize = .{ .input = .{ .value = .{ .reference = judgment_ref } }, .sources = .{ .items = &.{ value_ref, value_ref } } } } });
    try expectContextOutputBound(&service, scratch, parent.receipt.task, "context-sourced-reference", judgment_ref, null);
    for ([_][]const contracts.workspace.Ref{ &.{ value_ref, judgment_ref }, &.{judgment_ref}, &.{ judgment_ref, value_ref, value_ref } }, 0..) |refs, i| {
        const other_view = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "context-other-view-{d}", .{i}), parent.receipt.task, .{ .context = .{ .select = .{ .values = .{ .items = refs } } } });
        try expectContextOutputBound(&service, scratch, parent.receipt.task, "context-select", other_view.selected_view.?, null);
    }
    try service.validateWorkspace(scratch, parent.receipt.task);
    const partial_view = try service.workspaceCommand(scratch, "view-page", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = selected.selected_view.?, .page = .{ .maximum = 30 } } } });
    var partial_json = try native.json.parse(a, partial_view.observation_json.bytes, .{});
    defer partial_json.deinit();
    try std.testing.expect(!partial_json.value.object.get("selection").?.object.get("complete").?.bool);
    try std.testing.expectEqualStrings("selected_values_only", partial_json.value.object.get("coverage").?.string);
    const later_view = try service.workspaceCommand(scratch, "view-later-page", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = selected.selected_view.?, .page = .{ .offset = 30, .maximum = 30 } } } });
    var later_json = try native.json.parse(a, later_view.observation_json.bytes, .{});
    defer later_json.deinit();
    try std.testing.expectEqualStrings("30", later_json.value.object.get("selection").?.object.get("offset").?.number_string);
    const unavailable = try service.workspaceCommand(scratch, "invalid-value", parent.receipt.task, .{ .context = .{ .select = .{ .values = .{ .items = &.{.{ .kind = .value, .id = .{ .bytes = "0000000000000000000000000000000000000000000000000000000000000000" } }} } } } });
    try std.testing.expectEqual(.rejected, unavailable.disposition);
    try std.testing.expectEqual(null, unavailable.selected_view);
    const replay_observation = try service.workspaceCommand(scratch, "advance", parent.receipt.task, .{ .work = .{ .advance = .{ .work = .{ .kind = .work, .id = .{ .bytes = &std.fmt.bytesToHex(id, .lower) } }, .execution_revision = work.value.execution_revision, .control_revision = work.value.control_revision } } });
    try std.testing.expectEqual(.observed, replay_observation.disposition);
    var replay_json = try native.json.parse(a, replay_observation.observation_json.bytes, .{});
    defer replay_json.deinit();
    try std.testing.expect(replay_json.value.object.get("replayed").?.bool);
    try std.testing.expect(!std.mem.eql(u8, replay_json.value.object.get("outcome").?.string, "completed"));

    // Real local ports survive service replacement, and the acknowledged
    // answer remains the only consumable reply after that replacement.
    var interactive_builder = source.Builder.init(a);
    defer interactive_builder.deinit();
    const interactive_source = try native.source_records.encode(a, try alternatives(&interactive_builder, true));
    defer a.free(interactive_source);
    const interactive_program = try service.workspaceCommand(scratch, "interactive-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = interactive_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } } } } } });
    try std.testing.expectEqual(.observed, interactive_program.disposition);
    var program_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&program_id, interactive_program.program.?.id.bytes);
    const interactive_input = try contracts.encodeOwned(u64, a, 100);
    defer a.free(interactive_input);
    const interactive_started = try service.workspaceStart(scratch, "interactive-start", parent.receipt.task, program_id, interactive_input, .{});
    const interactive_id = interactive_started.receipt.workspace.?;
    var interactive_artifact = try service.workspaceProgram(scratch, parent.receipt.task, program_id);
    defer interactive_artifact.deinit();
    const start_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = interactive_program.program.?,
        .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, interactive_artifact.value.description.input_schema.digest), .json_text = .{ .bytes = "\"100\"" } } },
        .policy = .{},
    } } };
    const original_observation = try service.workspaceCommand(scratch, "interactive-start", parent.receipt.task, start_command);
    // Paging reaches complete payloads, including retained failures, rather
    // than paging an observation that has already truncated its preview.
    var payload_builder = source.Builder.init(a);
    defer payload_builder.deinit();
    const payload_type = try payload_builder.schema(.text);
    const payload_effect = try payload_builder.effect(.{ .identity = "example/large-payload", .payload = payload_type, .result = payload_type, .external = false });
    const payload_entry = try payload_builder.declare(&.{payload_type}, payload_type, &.{payload_effect}, &.{});
    const payload_result = try payload_builder.variable(payload_type);
    try payload_builder.define(payload_entry, try payload_builder.bind(payload_result, try payload_builder.term(.{ .perform = .{ .effect = payload_effect, .payload = try payload_builder.reference(payload_builder.parameter(payload_entry, 0)) } }), try payload_builder.term(.{ .fail = try payload_builder.reference(payload_result) })));
    const payload_source = try native.source_records.encode(scratch, payload_builder.module(payload_entry, payload_type));
    const payload_program = try service.workspaceCommand(scratch, "payload-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = payload_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = payload_effect, .class = .input }} } } } });
    try std.testing.expect(payload_program.program != null);
    const complete_payload = try scratch.alloc(u8, 20000);
    @memset(complete_payload, 'x');
    @memcpy(complete_payload[19996..], "TAIL");
    const payload_wire = try contracts.encodeOwned(contracts.Utf8, scratch, .{ .bytes = complete_payload });
    const payload_start = try service.workspaceStart(scratch, "payload-start", parent.receipt.task, try nativeIdentity(payload_program.program.?), payload_wire, .{});
    var payload_work = try service.workspaceWork(scratch, parent.receipt.task, payload_start.receipt.workspace.?);
    defer payload_work.deinit();
    var payload_port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, payload_work.value.current_port.?, null));
    defer payload_port.deinit();
    const payload_port_ref = try workspaceRef(scratch, .port, payload_port.value.id);
    const payload_work_ref = try workspaceRef(scratch, .work, payload_work.value.id);
    const payload_json = try native.json.canonical(scratch, native.json.string(complete_payload));
    const full_port = try service.workspaceCommand(scratch, "payload-expand", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = payload_port_ref, .page = .{ .maximum = 48 * 1024 } } } });
    var full_port_json = try native.json.parse(scratch, full_port.observation_json.bytes, .{ .bytes = 64 * 1024 });
    defer full_port_json.deinit();
    try std.testing.expectEqualStrings(payload_json, full_port_json.value.object.get("text").?.string);
    try std.testing.expect(full_port_json.value.object.get("complete").?.bool);
    _ = try service.workspaceInteract(scratch, "payload-answer", parent.receipt.task, .{ .expected = .{ .work = payload_work_ref, .execution_revision = payload_work.value.execution_revision, .control_revision = payload_work.value.control_revision }, .port = payload_port_ref, .generation = payload_port.value.generation, .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, payload_port.value.interface.argument.digest), .json_text = .{ .bytes = payload_json } } } } });
    for (0..16) |_| {
        _ = try service.pump(scratch);
        var current = try service.workspaceWork(scratch, parent.receipt.task, payload_work.value.id);
        defer current.deinit();
        if (current.value.terminal()) break;
    }
    var payload_failed = try service.workspaceWork(scratch, parent.receipt.task, payload_work.value.id);
    defer payload_failed.deinit();
    try std.testing.expectEqual(.failed, payload_failed.value.outcome_kind);
    var reconstructed: std.ArrayList(u8) = .empty;
    var payload_offset: u64 = 0;
    while (true) {
        const part = try service.workspaceCommand(scratch, "failure-expand", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = payload_work_ref, .page = .{ .offset = payload_offset, .maximum = 4096 } } } });
        var parsed_part = try native.json.parse(scratch, part.observation_json.bytes, .{});
        defer parsed_part.deinit();
        try reconstructed.appendSlice(scratch, parsed_part.value.object.get("text").?.string);
        if (parsed_part.value.object.get("eof").?.bool) break;
        payload_offset = try native.json.numberInteger(u64, parsed_part.value.object.get("next_offset").?.number_string);
    }
    try std.testing.expectEqualStrings(payload_json, reconstructed.items);
    for (0..4) |i| {
        var current = try service.workspaceWork(a, parent.receipt.task, interactive_id);
        defer current.deinit();
        const port_bytes = try namespace.store.object(a, current.value.current_port.?, null);
        defer a.free(port_bytes);
        var port = try contracts.decodeOwned(native.workspace.Port, a, port_bytes);
        defer port.deinit();
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), port.value.generation);
        const interaction: @FieldType(contracts.workspace.Work, "interact") = .{
            .expected = .{ .work = try workspaceRef(scratch, .work, interactive_id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
            .port = try workspaceRef(scratch, .port, port.value.id),
            .generation = port.value.generation,
            .command = if (i == 3) .{ .finish = .{} } else .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = if (i == 0) "{}" else if (i == 1) "\"10\"" else "\"20\"" } } } },
        };
        const operation_id = try std.fmt.allocPrint(scratch, "interact-{d}", .{i});
        const accepted = try service.workspaceInteract(scratch, operation_id, parent.receipt.task, interaction);
        if (i == 2) {
            var answered = try service.workspaceWork(scratch, parent.receipt.task, interactive_id);
            defer answered.deinit();
            try std.testing.expectEqual(@as(usize, 3), answered.value.inputs.items.len);
            const reordered = [_]native.testing.state.Reference{ answered.value.inputs.items[0], answered.value.inputs.items[2], answered.value.inputs.items[1] };
            try expectWorkInputHistoryBound(&service, scratch, parent.receipt.task, interactive_id, &reordered);
            try expectInteractionReplyBound(&service, scratch, parent.receipt.task, "interact-1");
            try service.validateWorkspace(scratch, parent.receipt.task);
        }
        const replay = try service.workspaceInteract(a, operation_id, parent.receipt.task, interaction);
        defer a.free(replay.receipt.client_operation_id.bytes);
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqualDeep(accepted.receipt, replay.receipt);
        const historical = try service.workspaceCommand(scratch, "interactive-start", parent.receipt.task, start_command);
        try std.testing.expectEqualStrings(original_observation.observation_json.bytes, historical.observation_json.bytes);
        const live = try service.workspaceCommand(scratch, "inspect-answered", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = interaction.expected.work } } });
        var live_json = try native.json.parse(a, live.observation_json.bytes, .{});
        defer live_json.deinit();
        try std.testing.expect(!live_json.value.object.get("port_accepts_command").?.bool);
        try std.testing.expectError(error.StaleRevision, service.workspaceInteract(scratch, "new-conflicting-answer", parent.receipt.task, interaction));
        try service.close(scratch);
        service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        const restored_observation = try service.workspaceCommand(scratch, "interactive-start", parent.receipt.task, start_command);
        try std.testing.expectEqualStrings(original_observation.observation_json.bytes, restored_observation.observation_json.bytes);
        var recovered_work = try service.workspaceWork(a, parent.receipt.task, interactive_id);
        defer recovered_work.deinit();
        _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "interactive-resume-{d}", .{i}), parent.receipt.task, interactive_id, recovered_work.value.execution_revision, recovered_work.value.control_revision, .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .next_exposed_event } });
        for (0..20) |_| {
            _ = try service.pump(scratch);
            var observed = try service.workspaceWork(a, parent.receipt.task, interactive_id);
            defer observed.deinit();
            if (observed.value.terminal() or observed.value.port_generation > port.value.generation) break;
        }
    }
    var interactive_completed = try service.workspaceWork(a, parent.receipt.task, interactive_id);
    defer interactive_completed.deinit();
    try std.testing.expectEqual(.completed, interactive_completed.value.outcome_kind);
    const interactive_result = try namespace.store.object(a, interactive_completed.value.result.?, null);
    defer a.free(interactive_result);
    var final_result = try contracts.decodeOwned(u64, a, interactive_result);
    defer final_result.deinit();
    try std.testing.expectEqual(@as(u64, 121), final_result.value);
    try service.validateWorkspace(scratch, parent.receipt.task);
    // A valid checkpoint does not certify unrelated native port metadata.
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
    const archive_index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
    try namespace.store.begin();
    var forged = interactive_completed.value;
    forged.port_generation += 1;
    try namespace.store.putRecord(native.workspace.Work, "workspace_work", forged.id, forged.task, forged);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, parent.receipt.task, archive_index.records.items));
    namespace.store.rollback();
    try namespace.store.begin();
    forged = interactive_completed.value;
    forged.cancellation = .{ .bytes = "forged applied cancellation" };
    forged.cancellation_applied = true;
    try namespace.store.putRecord(native.workspace.Work, "workspace_work", forged.id, forged.task, forged);
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, parent.receipt.task, archive_index.records.items));
    namespace.store.rollback();

    const cancel_started = try service.workspaceStart(scratch, "cancel-after-answer-start", parent.receipt.task, program_id, interactive_input, .{});
    var cancel_work = try service.workspaceWork(a, parent.receipt.task, cancel_started.receipt.workspace.?);
    defer cancel_work.deinit();
    const cancel_port_bytes = try namespace.store.object(a, cancel_work.value.current_port.?, null);
    defer a.free(cancel_port_bytes);
    var cancel_port = try contracts.decodeOwned(native.workspace.Port, a, cancel_port_bytes);
    defer cancel_port.deinit();
    _ = try service.workspaceInteract(scratch, "answer-before-cancel", parent.receipt.task, .{
        .expected = .{ .work = try workspaceRef(scratch, .work, cancel_work.value.id), .execution_revision = cancel_work.value.execution_revision, .control_revision = cancel_work.value.control_revision },
        .port = try workspaceRef(scratch, .port, cancel_port.value.id),
        .generation = cancel_port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, cancel_port.value.interface.argument.digest), .json_text = .{ .bytes = "{}" } } } },
    });
    var answered_work = try service.workspaceWork(a, parent.receipt.task, cancel_work.value.id);
    defer answered_work.deinit();
    _ = try service.workspaceControl(scratch, "cancel-after-answer", parent.receipt.task, cancel_work.value.id, answered_work.value.execution_revision, answered_work.value.control_revision, .{ .cancel = .{ .bytes = "stop exploring" } });
    // Explicit advance and the scheduled pump must apply the same pending
    // cancellation after consuming an already settled reply.
    for (0..2) |step| {
        var pending_cancel = try service.workspaceWork(scratch, parent.receipt.task, cancel_work.value.id);
        defer pending_cancel.deinit();
        if (pending_cancel.value.terminal()) break;
        _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "cancel-explicit-advance-{d}", .{step}), parent.receipt.task, cancel_work.value.id, pending_cancel.value.execution_revision, pending_cancel.value.control_revision, .advance);
    }
    for (0..20) |_| {
        _ = try service.pump(scratch);
        var observed = try service.workspaceWork(a, parent.receipt.task, cancel_work.value.id);
        defer observed.deinit();
        if (observed.value.terminal()) break;
    }
    var cancelled_after_answer = try service.workspaceWork(a, parent.receipt.task, cancel_work.value.id);
    defer cancelled_after_answer.deinit();
    try std.testing.expectEqual(.cancelled, cancelled_after_answer.value.outcome_kind);
    try std.testing.expect(cancelled_after_answer.value.cancellation_applied);
    // WORK-14: cancellation is applied before cleanup finishes. Cleanup may
    // yield and expose a real request without being reported disposed early.
    var disposal_builder = source.Builder.init(scratch);
    defer disposal_builder.deinit();
    const disposal_source = try native.source_records.encode(scratch, try @import("workspace_sources.zig").yieldingDisposal(&disposal_builder));
    const disposal_program = try service.workspaceCommand(scratch, "disposal-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = disposal_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .observation }} } } } });
    try std.testing.expectEqual(.observed, disposal_program.disposition);
    var disposal_program_id: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&disposal_program_id, disposal_program.program.?.id.bytes);
    const disposal_started = try service.workspaceStart(scratch, "disposal-start", parent.receipt.task, disposal_program_id, &.{}, .{});
    const disposal_id = disposal_started.receipt.workspace.?;
    var before_disposal = try service.workspaceWork(scratch, parent.receipt.task, disposal_id);
    defer before_disposal.deinit();
    try std.testing.expectEqual(.yielded, before_disposal.value.outcome_kind);
    _ = try service.workspaceControl(scratch, "disposal-cancel", parent.receipt.task, disposal_id, before_disposal.value.execution_revision, before_disposal.value.control_revision, .{ .cancel = .{ .bytes = "abandoned inquiry" } });
    var cancelling = try service.workspaceWork(scratch, parent.receipt.task, disposal_id);
    defer cancelling.deinit();
    try std.testing.expect(cancelling.value.cancellation_applied and !cancelling.value.terminal());
    try expectWorkCancellationReasonBound(&service, scratch, cancelling.value);
    _ = try service.workspaceControl(scratch, "disposal-cancel-again", parent.receipt.task, disposal_id, cancelling.value.execution_revision, cancelling.value.control_revision, .{ .cancel = .{ .bytes = "different reason" } });
    var saw_cleanup_port = false;
    var disposal_complete = false;
    for (0..20) |_| {
        var current = try service.workspaceWork(scratch, parent.receipt.task, disposal_id);
        defer current.deinit();
        try std.testing.expect(current.value.cancellation_applied);
        try std.testing.expectEqualStrings("abandoned inquiry", current.value.cancellation.?.bytes);
        const inspected = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "disposal-inspect-{d}", .{current.value.execution_revision}), parent.receipt.task, .{ .work = .{ .inspect = .{ .work = try workspaceRef(scratch, .work, disposal_id) } } });
        var observation = try native.json.parse(scratch, inspected.observation_json.bytes, .{});
        defer observation.deinit();
        try std.testing.expectEqual(current.value.terminal(), observation.value.object.get("cleanup_complete").?.bool);
        if (current.value.terminal()) {
            try std.testing.expectEqual(.cancelled, current.value.outcome_kind);
            disposal_complete = true;
            break;
        }
        if (current.value.current_port) |ref| {
            saw_cleanup_port = true;
            var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, ref, null));
            defer port.deinit();
            _ = try service.workspaceInteract(scratch, "disposal-answer", parent.receipt.task, .{
                .expected = .{ .work = try workspaceRef(scratch, .work, disposal_id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
                .port = try workspaceRef(scratch, .port, port.value.id),
                .generation = port.value.generation,
                .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = "{}" } } } },
            });
        }
        _ = try service.pump(scratch);
    }
    try std.testing.expect(saw_cleanup_port and disposal_complete);
    try service.validateWorkspace(scratch, parent.receipt.task);
    // OWN-08: a real SQLite write failure after the kernel publishes fences
    // the entire owner, including root and independent work dispatch.
    const fault_start = try service.workspaceStart(scratch, "fault-start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    var fault_work = try service.workspaceWork(scratch, parent.receipt.task, fault_start.receipt.workspace.?);
    defer fault_work.deinit();
    try namespace.store.database.exec("PRAGMA query_only=ON;");
    try std.testing.expectError(error.StorageUnavailable, service.workspaceControl(scratch, "fault-advance", parent.receipt.task, fault_work.value.id, fault_work.value.execution_revision, fault_work.value.control_revision, .advance));
    try std.testing.expect(namespace.store.fenced and service.active != null);
    try std.testing.expectError(error.StorageUnavailable, service.pump(scratch));
    try namespace.store.database.exec("PRAGMA query_only=OFF;");
}

test "workspace commands use the generated nested-sum schema and native model normalization" {
    const protean = @import("protean");
    const Action = union(enum) { program: struct { command: contracts.workspace.Program } };
    const Profile = protean.model_invocation.Profile(Action, .{.{ .name = "program", .description = "Construct or inspect Horos." }}, .{});
    const declaration = Profile.allDeclarations().items[0];
    try std.testing.expectEqual(.sum, declaration.argument_codec.items[0].field.kind);
    try std.testing.expect(std.mem.indexOf(u8, declaration.input_schema_json.bytes, "\"anyOf\"") != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Model = protean.model(.{ .name = "workspace-codec", .model = "fixture-model", .parameters = .{}, .protocol = struct {
        pub const semantic_identity = protean.model_invocation.protocol_identity;
    } });
    var invocation = try Profile.templateValue(Model, .{ .items = &.{} }, .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false });
    invocation.tools = Profile.allDeclarations();
    for ([_]struct { arguments: []const u8, valid: bool }{
        .{ .arguments = "{\"command\":{\"tag\":\"describe\",\"value\":{\"section\":\"source_records\",\"page\":{\"offset\":0,\"maximum\":16384}}}}", .valid = true },
        .{ .arguments = "{\"command\":{\"tag\":\"invoke_native_code\",\"value\":{}}}", .valid = false },
        .{ .arguments = "{\"command\":{\"tag\":\"describe\",\"value\":{\"section\":\"source_records\",\"page\":{\"offset\":0,\"maximum\":16384},\"authority\":true}}}", .valid = false },
    }) |case| {
        var function = native.json.object();
        try native.json.put(a, &function, "type", native.json.string("function_call"));
        try native.json.put(a, &function, "status", native.json.string("completed"));
        try native.json.put(a, &function, "call_id", native.json.string("command"));
        try native.json.put(a, &function, "name", native.json.string("program"));
        try native.json.put(a, &function, "arguments", native.json.string(case.arguments));
        var output: native.json.Value = .{ .array = .init(a) };
        try output.array.append(function);
        const normalized = try native.responses.OutputNormalizer(Profile).normalize(a, invocation, output);
        try std.testing.expectEqual(.output, std.meta.activeTag(normalized));
        const decoded = normalized.output.items.items[0].function_call.decoded_action;
        try std.testing.expectEqual(case.valid, decoded == .decoded);
        if (decoded == .decoded) try std.testing.expectEqual(.source_records, decoded.decoded.program.command.describe.section);
    }
}

const ContextTypes = struct {
    pub const application_id = "workspace-context-test";
    pub const input_schema_id = "workspace-context.input/1";
    pub const output_schema_id = "workspace-context.output/1";
    pub const failure_schema_id = "workspace-context.failure/1";
    pub const message_schema_id = "workspace-context.message/1";
    pub const Input = contracts.workspace.Command;
    pub const Output = contracts.workspace.Reply;
    pub const Failure = void;
    pub const Message = void;
};
const ContextApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const author = horos.authoring.interop;
        const input = try author.schemaId(c.author, try c.schema(ContextTypes.Input));
        const output = try author.schemaId(c.author, try c.schema(ContextTypes.Output));
        const effect = try author.operationId(c.author, try c.external("workspace-context", try c.schema(ContextTypes.Input), try c.schema(ContextTypes.Output), .read));
        const entry = try c.builder.declare(&.{input}, output, &.{effect}, &.{});
        try c.builder.define(entry, try c.builder.term(.{ .perform = .{ .effect = effect, .payload = try c.builder.reference(c.builder.parameter(entry, 0)) } }));
        return c.builder.module(entry, try author.schemaId(c.author, try c.schema(void)));
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(ContextTypes.Input, ctx.allocator, bytes);
        defer command.deinit();
        // This fixture's compiled application accepts the command as its root
        // input. The production adapter authenticates a captured model action.
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command.value, .snapshot = ctx.resources[0], .catalog = if (ctx.resources.len > 1) ctx.resources[1] else null, .input = if (ctx.resources.len > 2) ctx.resources[2] else null });
    }
    fn payloadSchema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(ContextTypes.Input, a);
    }
    fn resultSchema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(ContextTypes.Output, a);
    }
};

test "CTX-01 snapshot materialization retains omitted source for a broader evidence pivot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const protean = @import("protean");
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = ContextTypes.Input, .Result = ContextTypes.Output, .Failure = void, .application = ContextApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "context-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const assets: native.discovery.Assets = .{ .image = image, .application = "context-unit", .manifest = "{}" };
    var handlers = try native.Registry.init(a, &.{.{ .identity = "workspace-context", .resource_role = "workspace", .kind = .workspace, .workspace = ContextApplication.authorize, .payload_schema = ContextApplication.payloadSchema, .resume_schema = ContextApplication.resultSchema }});
    defer handlers.deinit();
    const text = "ordinary rows agree\nrare exception: missing invoice\n";
    var file_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &file_digest, .{});
    const snapshot = try contracts.encodeOwned(contracts.RepositorySnapshot, a, .{ .version = 2, .excluded_entries = 3, .files = .{ .items = &.{.{ .path = .{ .bytes = "evidence.txt" }, .sha256 = file_digest, .contents = .{ .bytes = text } }} } });
    defer a.free(snapshot);
    var algorithm = source.Builder.init(a);
    defer algorithm.deinit();
    var gcd_program = try horos.source.lower(a, try gcd(&algorithm));
    defer gcd_program.deinit();
    const component: data.component.Object = .{ .program = gcd_program.program, .exports = &.{.{ .name = "apply", .reference = .{ .kind = .function, .id = gcd_program.program.roots.entry } }}, .borrows = &.{.{ .function = gcd_program.program.roots.entry }} };
    const component_bytes = try a.alloc(u8, try data.component.encodedLength(component));
    defer a.free(component_bytes);
    _ = try data.component.encode(a, component, component_bytes);
    const catalog = try contracts.encodeOwned(contracts.tool_construction.Catalog, a, .{ .items = &.{.{ .id = .{ .bytes = "gcd" }, .object = .{ .bytes = component_bytes } }} });
    defer a.free(catalog);
    const compact_schema = try data.schema.encodeOwned(a, &.{ .{ .array = .{ .element = 1, .length = 1_000_000_000 } }, .unit }, 0);
    defer a.free(compact_schema);
    const frozen_input = try contracts.encodeOwned(contracts.tool_construction.Input, a, .{ .schema = .{ .bytes = compact_schema }, .value = .{ .bytes = "" } });
    defer a.free(frozen_input);
    var grants = [_]native.registry.Grant{.{ .identity = "workspace-context", .resource_role = "workspace", .resource_identity = undefined }};
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "context-test", .resources = &.{ snapshot, catalog, frozen_input }, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    grants[0].resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(ContextTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const command: contracts.workspace.Command = .{ .context = .{ .materialize = .{ .input = .{ .snapshot = .{ .path = .{ .bytes = "evidence.txt" }, .offset = 0, .maximum = 19 } }, .sources = .{ .items = &.{} } } } };
    const parent = try service.submit(scratch, "parent", command);
    for (0..32) |_| {
        const step = try service.pump(scratch);
        try std.testing.expect(step != .work);
        if (step == .idle or step == .waiting) break;
    }
    var finished = try service.task(a, parent.receipt.task);
    defer finished.deinit();
    try std.testing.expectEqual(.completed, finished.value.outcome_kind);
    const bytes = try namespace.store.object(a, finished.value.result.?, null);
    defer a.free(bytes);
    var reply = try contracts.decodeOwned(ContextTypes.Output, a, bytes);
    defer reply.deinit();
    try std.testing.expectEqual(.observed, reply.value.disposition);
    var observation = try native.json.parse(a, reply.value.observation_json.bytes, .{});
    defer observation.deinit();
    const derivation = observation.value.object.get("derivation").?;
    try std.testing.expectEqualStrings("acquisition", derivation.object.get("kind").?.string);
    try std.testing.expect(!derivation.object.get("complete_file").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, observation.value.object.get("preview").?.object.get("text").?.string, "rare exception") == null);
    const source_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, observation.value.object.get("source").?);
    const expansion = try service.workspaceCommand(scratch, "expand-source", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = source_ref, .page = .{} } } });
    var expanded = try native.json.parse(a, expansion.observation_json.bytes, .{});
    defer expanded.deinit();
    try std.testing.expectEqualStrings(text, expanded.value.object.get("text").?.string);
    const provenance_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, observation.value.object.get("provenance").?);
    var poisoned: PoisonFreedAllocator = .{ .backing = scratch };
    const provenance_reply = try service.workspaceCommand(poisoned.allocator(), "expand-provenance", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = provenance_ref, .page = .{} } } });
    var provenance_page = try native.json.parse(a, provenance_reply.observation_json.bytes, .{});
    defer provenance_page.deinit();
    var provenance = try native.json.parse(a, provenance_page.value.object.get("text").?.string, .{});
    defer provenance.deinit();
    try std.testing.expectEqualStrings("evidence.txt", provenance.value.object.get("acquisition").?.object.get("path").?.string);
    // Mutation replies re-project the original operation receipt, including
    // acquisition provenance, even after the controller has completed.
    try service.validateWorkspace(scratch, parent.receipt.task);

    // The source and value routes expose the same compact frozen input. A
    // tiny source window must not allocate its billion logical JSON nodes.
    const frozen_parent = try service.submit(scratch, "frozen-input-parent", .{ .context = .{ .materialize = .{ .input = .{ .authorized_input = .{ .bytes = "compact" } }, .sources = .{ .items = &.{} } } } });
    for (0..32) |_| {
        const step = try service.pump(scratch);
        try std.testing.expect(step != .work);
        if (step == .idle or step == .waiting) break;
    }
    var frozen_finished = try service.task(scratch, frozen_parent.receipt.task);
    defer frozen_finished.deinit();
    try std.testing.expectEqual(.completed, frozen_finished.value.outcome_kind);
    var frozen_reply = try contracts.decodeOwned(ContextTypes.Output, scratch, try namespace.store.object(scratch, frozen_finished.value.result.?, null));
    defer frozen_reply.deinit();
    try std.testing.expectEqual(.observed, frozen_reply.value.disposition);
    var frozen_observation = try native.json.parse(scratch, frozen_reply.value.observation_json.bytes, .{});
    defer frozen_observation.deinit();
    const frozen_source = try native.values.fromJson(contracts.workspace.Ref, scratch, frozen_observation.value.object.get("source").?);
    const page_buffer = try a.alloc(u8, 16 * 1024 * 1024);
    defer a.free(page_buffer);
    for ([_]u64{ 0, 2_999_999_998 }, [_][]const u8{ "[", "{}]" }) |offset, expected| {
        var bounded = std.heap.FixedBufferAllocator.init(page_buffer);
        const paged = try service.workspaceCommand(bounded.allocator(), "frozen-source-page", frozen_parent.receipt.task, .{ .context = .{ .expand = .{ .reference = frozen_source, .page = .{ .offset = offset, .maximum = @intCast(expected.len) } } } });
        try std.testing.expectEqual(.observed, paged.disposition);
        var parsed = try native.json.parse(scratch, paged.observation_json.bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expected, parsed.value.object.get("text").?.string);
        try std.testing.expectEqual(@as(u64, 3_000_000_001), try native.json.numberInteger(u64, parsed.value.object.get("total_bytes").?.number_string));
    }
    try service.validateWorkspace(scratch, frozen_parent.receipt.task);

    // A settled mutation cannot be rewritten into a rejection while its
    // committed receipt survives. A genuine rejection has no such receipt.
    for ([_]bool{ false, true }) |reject| {
        var mutation = command;
        if (reject) mutation.context.materialize.input.snapshot.path.bytes = "missing.txt";
        const mutation_parent = try service.submit(scratch, if (reject) "rejected-mutation" else "accepted-mutation", mutation);
        var observed: ?native.testing.occurrence.Occurrence = null;
        var evidence: native.workspace.ReplyObservation = undefined;
        for (0..32) |_| {
            _ = try service.pump(scratch);
            var query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='workspace_reply'", &.{.{ .blob = &mutation_parent.receipt.task }});
            defer query.deinit();
            if (try query.step() != .row) continue;
            evidence = (try contracts.decodeOwned(native.workspace.ReplyObservation, scratch, try query.bytes(0))).value;
            const pending_bytes = (try namespace.store.recordBytes(scratch, "occurrence", evidence.id, evidence.task)).?;
            observed = (try contracts.decodeOwned(native.testing.occurrence.Occurrence, scratch, pending_bytes)).value;
            break;
        }
        const settled = observed orelse return error.MissingMutationObservation;
        try std.testing.expect(settled.state == .settled_reply);
        try service.validateWorkspace(scratch, mutation_parent.receipt.task);
        if (reject) {
            try std.testing.expect(evidence.evidence == .rejected);
            continue;
        }
        try std.testing.expect(evidence.evidence == .admitted);
        const bound_original = try data.invocation.decode(data.invocation.Result, scratch, try namespace.store.object(scratch, try namespace.store.objectReference(settled.state.settled_reply.reply, null), null));
        const original_reply = (try contracts.decodeOwned(contracts.workspace.Reply, scratch, bound_original.value.value)).value;
        const original_json = (try native.json.parse(scratch, original_reply.observation_json.bytes, .{})).value;
        const schema_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, original_json.object.get("schema").?);
        const other = try service.workspaceCommand(scratch, "snapshot-substitute", mutation_parent.receipt.task, .{ .context = .{ .materialize = .{ .input = .{ .value = .{ .inline_json = .{ .schema = schema_ref, .json_text = .{ .bytes = "\"substitute\"" } } } }, .sources = .{ .items = &.{} } } } });
        const other_json = (try native.json.parse(scratch, other.observation_json.bytes, .{})).value;
        try expectContextOutputBound(&service, scratch, mutation_parent.receipt.task, &std.fmt.bytesToHex(settled.id, .lower), try native.values.fromJson(contracts.workspace.Ref, scratch, other_json.object.get("value").?), other);
        try service.validateWorkspace(scratch, mutation_parent.receipt.task);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(assets.manifest, &digest, .{});
        const mutation_index = try namespace.store.archiveIndex(scratch, mutation_parent.receipt.task, .{ .digest = digest, .bytes = assets.manifest.len });
        try namespace.store.begin();
        evidence.evidence = .{ .rejected = .{ .stage = .operation, .code = .{ .bytes = "Denied" } } };
        const forged = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.ReplyObservation, scratch, evidence));
        try namespace.store.database.run("UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?", &.{ .{ .blob = &forged.digest }, .{ .blob = &settled.id } });
        const failed_reply: contracts.workspace.Reply = .{ .disposition = .rejected, .observation_json = .{ .bytes = "{\"error\":\"Denied\"}" } };
        const payload = try contracts.encodeOwned(contracts.workspace.Reply, scratch, failed_reply);
        const bound = try data.invocation.encodeOwned(data.invocation.Result, scratch, .{ .request_identity = settled.request, .value = payload });
        var forged_occurrence = settled;
        forged_occurrence.state.settled_reply.reply = (try namespace.store.putObject(bound)).digest;
        try namespace.store.putRecord(native.testing.occurrence.Occurrence, "occurrence", settled.id, settled.task, forged_occurrence);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, settled.task, mutation_index.records.items));
        namespace.store.rollback();
        try service.validateWorkspace(scratch, settled.task);
    }

    const read_parent = try service.submit(scratch, "read-observation", .{ .program = .{ .describe = .{ .section = .source_records, .page = .{} } } });
    var read_occurrence: ?native.testing.occurrence.Occurrence = null;
    for (0..32) |_| {
        _ = try service.pump(scratch);
        var query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='occurrence'", &.{.{ .blob = &read_parent.receipt.task }});
        defer query.deinit();
        if (try query.step() != .row) continue;
        var pending = try contracts.decodeOwned(native.testing.occurrence.Occurrence, a, try query.bytes(0));
        defer pending.deinit();
        if (pending.value.state == .settled_reply) {
            read_occurrence = pending.value;
            break;
        }
    }
    const original = read_occurrence orelse return error.MissingReadObservation;
    try service.validateWorkspace(scratch, read_parent.receipt.task);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
    const index = try namespace.store.archiveIndex(scratch, read_parent.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
    // Rehashing an independently changed acquired reply must not turn it into
    // the result of the retained read. Test before the root consumes the reply.
    for (0..2) |variant| {
        try namespace.store.begin();
        const fake: contracts.workspace.Reply = .{
            .disposition = .observed,
            .observation_json = .{ .bytes = if (variant == 0) "{\"text\":\"fabricated schema\"}" else "{}" },
            .selected_view = if (variant == 1) .{ .kind = .view, .id = .{ .bytes = &(@as([64]u8, @splat('0'))) } } else null,
        };
        const payload = try contracts.encodeOwned(contracts.workspace.Reply, scratch, fake);
        const bound = try data.invocation.encodeOwned(data.invocation.Result, scratch, .{ .request_identity = original.request, .value = payload });
        var forged_reply = original;
        forged_reply.state.settled_reply.reply = (try namespace.store.putObject(bound)).digest;
        try namespace.store.putRecord(native.testing.occurrence.Occurrence, "occurrence", original.id, original.task, forged_reply);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, original.task, index.records.items));
        namespace.store.rollback();
    }
    const other = try service.submit(scratch, "other-task", command);
    const forbidden = try service.workspaceCommand(scratch, "cross-task-source", other.receipt.task, .{ .context = .{ .expand = .{ .reference = source_ref, .page = .{} } } });
    try std.testing.expectEqual(.rejected, forbidden.disposition);
    const recipe = "{\"instances\":[{\"key\":\"algorithm\",\"component_id\":\"gcd\"}],\"bindings\":[],\"entry\":{\"instance\":\"algorithm\",\"symbol\":\"apply\"}}";
    const build_parent = try service.submit(scratch, "component-parent", .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = recipe } }, .source_kind = .component_recipe, .exposures = .{ .items = &.{} } } } });
    var built_id: ?[32]u8 = null;
    var compilation_seen = false;
    for (0..32) |_| {
        const step = try service.pump(scratch);
        if (step == .work) {
            try std.testing.expectEqual(.workspace_build, step.work.operation);
            try std.testing.expect(!compilation_seen);
            compilation_seen = true;
            const worker = try native.testing.Worker.init(a, io);
            defer worker.deinit(a) catch unreachable;
            try worker.start(step.work, profile.authority, null);
            // Control admission remains available while source compilation owns
            // the worker, and does not invalidate the in-flight attempt.
            var compiling = try service.task(a, build_parent.receipt.task);
            defer compiling.deinit();
            try std.testing.expect(compiling.value.current_occurrence != null);
            _ = try service.submit(scratch, "during-compilation", command);
            while (!worker.finished()) try io.sleep(.fromMilliseconds(1), .awake);
            try worker.join();
            try service.completeWork(scratch, step.work, worker.result.?);
            try worker.release();
            // A captured build survives owner replacement without a second
            // compilation dispatch; explicit resume only interprets it.
            try service.close(a);
            service = try native.tasks.Service(ContextTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            try std.testing.expectEqual(.idle, try service.pump(scratch));
            var captured = try service.task(a, build_parent.receipt.task);
            defer captured.deinit();
            _ = try service.resumeTask(scratch, "resume-build-capture", build_parent.receipt.task, captured.value.revision);
        }
        var query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='workspace_program'", &.{.{ .blob = &build_parent.receipt.task }});
        defer query.deinit();
        if (try query.step() == .row) {
            var built = try contracts.decodeOwned(native.workspace.Program, a, try query.bytes(0));
            defer built.deinit();
            try std.testing.expectEqual(.component_recipe, built.value.description.source_kind);
            built_id = built.value.artifact.digest;
            break;
        }
    }
    try std.testing.expect(compilation_seen);
    try std.testing.expect(built_id != null);
    try expectProgramProgressIsDerived(&service, scratch, build_parent.receipt.task);
    const input = try contracts.encodeOwned(struct { u64, u64 }, a, .{ 1071, 462 });
    defer a.free(input);
    const started = try service.workspaceStart(scratch, "component-start", build_parent.receipt.task, built_id.?, input, .{});
    var child = try service.workspaceWork(a, build_parent.receipt.task, started.receipt.workspace.?);
    defer child.deinit();
    try std.testing.expectEqual(.completed, child.value.outcome_kind);
    const result_bytes = try namespace.store.object(a, child.value.result.?, null);
    defer a.free(result_bytes);
    var result = try contracts.decodeOwned(u64, a, result_bytes);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 21), result.value);
    const archive_path = try std.fmt.allocPrint(a, "{s}/build.par", .{path_buffer[0..length]});
    defer a.free(archive_path);
    _ = try service.exportCheckpoint(scratch, build_parent.receipt.task, archive_path);
}

const WaitTypes = struct {
    pub const application_id = "workspace-wait-test";
    pub const input_schema_id = "workspace-wait.input/1";
    pub const output_schema_id = "workspace-wait.output/1";
    pub const failure_schema_id = "workspace-wait.failure/1";
    pub const message_schema_id = "workspace-wait.message/1";
    pub const Input = void;
    pub const Output = contracts.workspace.Reply;
    pub const Failure = void;
    pub const Message = @FieldType(contracts.workspace.Work, "wait");
};
const WaitApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const interop = horos.authoring.interop;
        const b = c.builder;
        const unit = try b.scalar(void);
        const output = try interop.schemaId(c.author, try c.schema(WaitTypes.Output));
        const command = try interop.schemaId(c.author, try c.schema(contracts.workspace.Command));
        const work_command = try interop.schemaId(c.author, try c.schema(contracts.workspace.Work));
        const inbox = try interop.operationId(c.author, try @import("protean").inbox.Profile(WaitTypes.Message).declare(c));
        const workspace = try interop.operationId(c.author, try c.external("workspace-wait", try c.schema(contracts.workspace.Command), try c.schema(WaitTypes.Output), .read));
        const inbox_schema = b.effects.items[@intCast(inbox)].result;
        const message_schema = b.schemas.items[@intCast(inbox_schema)].sum[1];
        const message_fields = b.schemas.items[@intCast(message_schema)].product;
        const entry = try b.declare(&.{unit}, output, &.{ inbox, workspace }, &.{});
        const received = try b.variable(inbox_schema);
        const empty = try b.variable(unit);
        const message = try b.variable(message_schema);
        const id = try b.variable(message_fields[0]);
        const selection = try b.variable(message_fields[1]);
        const selected_work = try b.primitive(work_command, .variant, &.{try b.reference(selection)}, @backingInt(std.meta.Tag(contracts.workspace.Work).wait));
        const selected_command = try b.primitive(command, .variant, &.{selected_work}, @backingInt(std.meta.Tag(contracts.workspace.Command).work));
        const reply = try b.variable(output);
        const ignored = try b.variable(inbox_schema);
        const finish = try b.bind(ignored, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), try b.pure(try b.reference(reply)));
        const wait = try b.bind(reply, try b.term(.{ .perform = .{ .effect = workspace, .payload = selected_command } }), finish);
        const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(message), .variables = &.{ id, selection }, .body = wait } });
        const select = try b.term(.{ .match_sum = .{ .value = try b.reference(received), .cases = &.{ .{ .variable = empty, .body = try b.term(.{ .fail = try b.constant(void, {}) }) }, .{ .variable = message, .body = unpack } } } });
        try b.define(entry, try b.bind(received, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), select));
        return b.module(entry, unit);
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(contracts.workspace.Command, ctx.allocator, bytes);
        defer command.deinit();
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command.value });
    }
    fn schema(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(contracts.workspace.Command, a);
    }
    fn result(a: std.mem.Allocator) ![]u8 {
        return native.values.schemaBytes(WaitTypes.Output, a);
    }
};

test "AUT-07 OWN-11 concrete authored wait wakes for a user message or selected work without a worker" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const protean = @import("protean");
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = void, .Result = WaitTypes.Output, .Failure = void, .application = WaitApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "wait-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "wait-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = image, .application = "wait-unit", .manifest = manifest };
    var handlers = try native.Registry.init(a, &.{ native.inbox.declaration(WaitTypes.Message), .{ .identity = "workspace-wait", .resource_role = "workspace", .kind = .workspace, .workspace = WaitApplication.authorize, .payload_schema = WaitApplication.schema, .resume_schema = WaitApplication.result } });
    defer handlers.deinit();
    var grants = [_]native.registry.Grant{ .{ .identity = "workspace-wait", .resource_role = "workspace", .resource_identity = undefined }, .{ .identity = native.inbox.identity, .resource_role = "user", .resource_identity = undefined } };
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "wait-test", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    for (&grants) |*grant| grant.resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_open = true;
    defer if (namespace_open) namespace.close() catch unreachable;
    var service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_open = true;
    defer if (service_open) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const document = try native.source_records.encode(a, try listLength(&builder));
    defer a.free(document);
    const input = try a.alloc(u8, 300 * 9 + 1);
    defer a.free(input);
    var writer: data.wire.Writer = .{ .output = input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const WaitScenario = enum { imported_message, owned_message, selected_event, resumed_child, orderly_resumed_child, resumed_explicit_park, reopened_control, incompatible_wait };
    for (std.enums.values(WaitScenario), 0..) |scenario, index| {
        const interrupt = scenario == .imported_message or scenario == .owned_message;
        const prefix = try std.fmt.allocPrint(scratch, "wait-{d}", .{index});
        const parent = try service.submit(scratch, prefix, {});
        var cleanup_id: ?[32]u8 = null;
        var parked_port_id: ?[32]u8 = null;
        var port_start: contracts.workspace.Command = undefined;
        var port_receipt: contracts.workspace.Reply = undefined;
        if (scenario == .selected_event) {
            var ports = source.Builder.init(scratch);
            defer ports.deinit();
            const port_source = try native.source_records.encode(scratch, try alternatives(&ports, true));
            const built = try service.workspaceCommand(scratch, "parent-port-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = port_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{ .{ .effect = 0, .class = .observation }, .{ .effect = 1, .class = .alternative } } } } } });
            var program_id: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&program_id, built.program.?.id.bytes);
            var artifact = try service.workspaceProgram(scratch, parent.receipt.task, program_id);
            defer artifact.deinit();
            port_start = .{ .work = .{ .start = .{ .program = built.program.?, .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, artifact.value.description.input_schema.digest), .json_text = .{ .bytes = "\"100\"" } } }, .policy = .{} } } };
            _ = try service.workspaceCommand(scratch, "parent-port-start", parent.receipt.task, port_start);
            port_receipt = try service.workspaceCommand(scratch, "parent-port-start", parent.receipt.task, port_start);
            var observed = try native.json.parse(scratch, port_receipt.observation_json.bytes, .{});
            defer observed.deinit();
            try std.testing.expect(observed.value.object.get("port_accepts_command").?.bool);
            var work_id: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&work_id, observed.value.object.get("work").?.object.get("id").?.string);
            parked_port_id = work_id;
        }
        if (scenario == .orderly_resumed_child) {
            var disposal_builder = source.Builder.init(scratch);
            defer disposal_builder.deinit();
            const disposal_source = try native.source_records.encode(scratch, try @import("workspace_sources.zig").yieldingDisposal(&disposal_builder));
            const disposal_program = try service.workspaceCommand(scratch, "late-cleanup-build", parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = disposal_source } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .observation }} } } } });
            var program_id: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&program_id, disposal_program.program.?.id.bytes);
            cleanup_id = (try service.workspaceStart(scratch, "late-cleanup-start", parent.receipt.task, program_id, &.{}, .{})).receipt.workspace.?;
        }
        var diagnostic: native.program_construction.Diagnostic = .{};
        const program = try service.workspaceBuild(scratch, try std.fmt.allocPrint(scratch, "{s}-build", .{prefix}), parent.receipt.task, document, &diagnostic);
        const started = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "{s}-start", .{prefix}), parent.receipt.task, program.receipt.workspace.?, input, .{});
        var initial = try service.workspaceWork(a, parent.receipt.task, started.receipt.workspace.?);
        defer initial.deinit();
        const selection: WaitTypes.Message = .{ .works = .{ .items = &.{try workspaceRef(scratch, .work, initial.value.id)} }, .after = initial.value.event_watermark };
        _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "{s}-selection", .{prefix}), parent.receipt.task, selection);
        var waited = false;
        for (0..20) |_| {
            const step = try service.pump(scratch);
            try std.testing.expect(step != .work);
            if (step == .waiting) {
                waited = true;
                break;
            }
        }
        try std.testing.expect(waited);
        try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
        if (scenario == .incompatible_wait) {
            try service.close(scratch);
            var foreign_profile = profile;
            foreign_profile.bytes = "different-wait-launch";
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, foreign_profile);
            const first_cancel = try service.requestCancel(scratch, "foreign-wait-cancel", parent.receipt.task, "cancel retained wait");
            const replay = try service.requestCancel(scratch, "foreign-wait-cancel", parent.receipt.task, "cancel retained wait");
            try std.testing.expect(replay.replayed and std.meta.eql(first_cancel.receipt.id, replay.receipt.id));
            _ = try service.requestCancel(scratch, "foreign-wait-cancel-again", parent.receipt.task, "retain original cancellation");
            try std.testing.expectEqual(.idle, try service.pump(scratch));
            var blocked = try service.task(scratch, parent.receipt.task);
            defer blocked.deinit();
            try std.testing.expectEqual(.incompatible_profile, blocked.value.blocker.?);
            try std.testing.expectEqualStrings("cancel retained wait", blocked.value.cancellation.?.bytes);
            try std.testing.expect(!try service.associatedWorkDisposed(scratch, parent.receipt.task));
            try service.close(scratch);
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            _ = try service.requestCancel(scratch, "compatible-wait-cancel", parent.receipt.task, "cancel retained wait");
            for (0..64) |_| {
                _ = try service.pump(scratch);
                var current = try service.task(scratch, parent.receipt.task);
                defer current.deinit();
                if (try service.taskCleanupComplete(scratch, current.value)) break;
            }
            var disposed = try service.task(scratch, parent.receipt.task);
            defer disposed.deinit();
            try std.testing.expect(try service.taskCleanupComplete(scratch, disposed.value));
            try std.testing.expectEqual(.cancelled, disposed.value.outcome_kind);
            continue;
        }
        if (scenario == .imported_message) {
            const archive_path = try std.fmt.allocPrint(scratch, "{s}/waiting.par", .{path_buffer[0..length]});
            _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
            try service.close(scratch);
            service_open = false;
            try namespace.close();
            namespace_open = false;
            namespace = try native.Namespace.open(a, io, try std.fmt.allocPrint(scratch, "{s}/waiting-import", .{path_buffer[0..length]}));
            namespace_open = true;
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            service_open = true;
            _ = try service.importCheckpoint(scratch, "import-wait", archive_path);
            _ = try service.message(scratch, "wait-amendment", parent.receipt.task, selection);
            // Opening the namespace and appending input do not implicitly
            // resume old ownership; the explicit resume restores the wait.
            try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
            var paused = try service.task(a, parent.receipt.task);
            defer paused.deinit();
            _ = try service.resumeTask(scratch, "wait-resume", parent.receipt.task, paused.value.revision);
        } else if (scenario == .owned_message) {
            var guarded: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
            _ = try service.message(guarded.allocator(), "owned-wait-amendment", parent.receipt.task, selection);
            try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
            try std.testing.expect((try service.message(scratch, "owned-wait-amendment", parent.receipt.task, selection)).replayed);
        } else if (scenario == .reopened_control) {
            try service.close(scratch);
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
            _ = try service.workspaceControl(scratch, "reopen-and-advance", parent.receipt.task, initial.value.id, initial.value.execution_revision, initial.value.control_revision, .advance);
        } else {
            _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "wait-progress-{d}", .{index}), parent.receipt.task, initial.value.id, initial.value.execution_revision, initial.value.control_revision, .{ .delegate = .{ .continuation = .owner_scheduled, .stop = .terminal } });
            if (scenario == .resumed_child or scenario == .orderly_resumed_child or scenario == .resumed_explicit_park) {
                if (scenario == .resumed_explicit_park) {
                    var delegated = try service.workspaceWork(scratch, parent.receipt.task, initial.value.id);
                    defer delegated.deinit();
                    _ = try service.workspaceControl(scratch, "explicit-park-before-close", parent.receipt.task, initial.value.id, delegated.value.execution_revision, delegated.value.control_revision, .park);
                }
                if (scenario != .resumed_child) try service.park(scratch);
                try service.close(scratch);
                service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
                try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
                var paused = try service.task(scratch, parent.receipt.task);
                defer paused.deinit();
                var guarded: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
                const resume_id = try std.fmt.allocPrint(scratch, "restore-queued-child-{d}", .{index});
                _ = try service.resumeTask(guarded.allocator(), resume_id, parent.receipt.task, paused.value.revision);
                try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
                try std.testing.expect((try service.resumeTask(scratch, resume_id, parent.receipt.task, paused.value.revision)).replayed);
                if (scenario == .resumed_explicit_park) {
                    for (0..10) |_| _ = try service.pump(scratch);
                    var parked = try service.workspaceWork(scratch, parent.receipt.task, initial.value.id);
                    defer parked.deinit();
                    try std.testing.expectEqual(.parked, parked.value.schedule);
                    try std.testing.expectEqual(initial.value.execution_revision, parked.value.execution_revision);
                }
            }
        }
        for (0..30) |_| {
            const step = try service.pump(scratch);
            try std.testing.expect(step != .work);
            var current = try service.task(a, parent.receipt.task);
            defer current.deinit();
            if (current.value.terminal()) break;
        }
        var finished = try service.task(a, parent.receipt.task);
        defer finished.deinit();
        try std.testing.expectEqual(.completed, finished.value.outcome_kind);
        try std.testing.expectEqual(@as(usize, 0), finished.value.messages.items.len);
        const bytes = try namespace.store.object(a, finished.value.result.?, null);
        defer a.free(bytes);
        var reply = try contracts.decodeOwned(WaitTypes.Output, a, bytes);
        defer reply.deinit();
        var observation = try native.json.parse(a, reply.value.observation_json.bytes, .{});
        defer observation.deinit();
        try std.testing.expect(observation.value.object.get("ready").?.bool);
        try std.testing.expectEqual(interrupt, observation.value.object.get("interrupted").?.bool);
        var child = try service.workspaceWork(a, parent.receipt.task, initial.value.id);
        defer child.deinit();
        try std.testing.expect(!child.value.terminal());
        if (interrupt or scenario == .resumed_explicit_park) try std.testing.expectEqual(initial.value.execution_revision, child.value.execution_revision) else try std.testing.expect(child.value.execution_revision > initial.value.execution_revision);
        try service.validateWorkspace(scratch, parent.receipt.task);
        // Root completion retains unfinished children. The public task cancel
        // path must dispose them without replacing the already published result.
        if (parked_port_id) |work_id| {
            const live = try service.workspaceCommand(scratch, "terminal-parent-port", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = try workspaceRef(scratch, .work, work_id) } } });
            var observed = try native.json.parse(scratch, live.observation_json.bytes, .{});
            defer observed.deinit();
            try std.testing.expect(!observed.value.object.get("port_accepts_command").?.bool);
            const historical = try service.workspaceCommand(scratch, "parent-port-start", parent.receipt.task, port_start);
            try std.testing.expectEqualStrings(port_receipt.observation_json.bytes, historical.observation_json.bytes);
            var parked = try service.workspaceWork(scratch, parent.receipt.task, work_id);
            defer parked.deinit();
            var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, parked.value.current_port.?, null));
            defer port.deinit();
            try std.testing.expectError(error.InvalidState, service.workspaceInteract(scratch, "terminal-parent-answer", parent.receipt.task, .{
                .expected = .{ .work = try workspaceRef(scratch, .work, work_id), .execution_revision = parked.value.execution_revision, .control_revision = parked.value.control_revision },
                .port = try workspaceRef(scratch, .port, port.value.id),
                .generation = port.value.generation,
                .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = "{}" } } } },
            }));
        }
        if (scenario == .orderly_resumed_child) {
            try service.park(scratch);
            try service.close(scratch);
            var incompatible = profile;
            incompatible.bytes = "different-cleanup-launch";
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, incompatible);
            _ = try service.requestCancel(scratch, "incompatible-completed-root-cancel", parent.receipt.task, "dispose remaining work");
            try std.testing.expectEqual(.idle, try service.pump(scratch));
            var blocked = try service.task(scratch, parent.receipt.task);
            defer blocked.deinit();
            try std.testing.expectEqual(.completed, blocked.value.outcome_kind);
            try std.testing.expectEqual(.incompatible_profile, blocked.value.blocker.?);
            try std.testing.expect(!try service.associatedWorkDisposed(scratch, parent.receipt.task));
            try service.close(scratch);
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        }
        const cancel_id = try std.fmt.allocPrint(scratch, "cancel-unjoined-{d}", .{index});
        var cancel_guard: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
        const cancelled = try service.requestCancel(cancel_guard.allocator(), cancel_id, parent.receipt.task, "dispose remaining work");
        try std.testing.expectEqual(@as(usize, 0), cancel_guard.rejected);
        const replayed = try service.requestCancel(scratch, cancel_id, parent.receipt.task, "dispose remaining work");
        try std.testing.expect(replayed.replayed and std.meta.eql(cancelled.receipt.id, replayed.receipt.id));
        if (cleanup_id) |pending_id| {
            var started_cleanup = false;
            for (0..30) |_| {
                _ = try service.pump(scratch);
                var pending = try service.workspaceWork(scratch, parent.receipt.task, pending_id);
                defer pending.deinit();
                if (pending.value.cancellation_applied) {
                    try std.testing.expect(!pending.value.terminal());
                    try std.testing.expectEqual(.queued, pending.value.schedule);
                    started_cleanup = true;
                    break;
                }
            }
            try std.testing.expect(started_cleanup);
            var cleanup = try service.workspaceWork(scratch, parent.receipt.task, pending_id);
            defer cleanup.deinit();
            _ = try service.workspaceControl(scratch, "park-admitted-cleanup", parent.receipt.task, pending_id, cleanup.value.execution_revision, cleanup.value.control_revision, .park);
            for (0..30) |_| _ = try service.pump(scratch);
            var still_parked = try service.workspaceWork(scratch, parent.receipt.task, pending_id);
            defer still_parked.deinit();
            try std.testing.expectEqual(.parked, still_parked.value.schedule);
            try std.testing.expectEqual(cleanup.value.execution_revision, still_parked.value.execution_revision);
            try service.park(scratch);
            try service.close(scratch);
            var incompatible = profile;
            incompatible.bytes = "different-resumed-cleanup-launch";
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, incompatible);
            _ = try service.requestCancel(scratch, "incompatible-queued-cleanup-cancel", parent.receipt.task, "dispose remaining work");
            try std.testing.expectEqual(.idle, try service.pump(scratch));
            var blocked = try service.task(scratch, parent.receipt.task);
            defer blocked.deinit();
            try std.testing.expectEqual(.incompatible_profile, blocked.value.blocker.?);
            try std.testing.expect(!try service.associatedWorkDisposed(scratch, parent.receipt.task));
            try service.close(scratch);
            service = try native.tasks.Service(WaitTypes).init(a, io, &namespace, assets, &application, handlers, profile);
            try std.testing.expectEqual(.idle, std.meta.activeTag(try service.pump(scratch)));
            _ = try service.requestCancel(scratch, "continue-admitted-cleanup", parent.receipt.task, "dispose remaining work");
            var unblocked = try service.task(scratch, parent.receipt.task);
            defer unblocked.deinit();
            try std.testing.expect(unblocked.value.blocker == null);
            var answered_cleanup = false;
            for (0..30) |_| {
                _ = try service.pump(scratch);
                var pending = try service.workspaceWork(scratch, parent.receipt.task, pending_id);
                defer pending.deinit();
                if (pending.value.current_port) |ref| {
                    try std.testing.expect(!try service.associatedWorkDisposed(scratch, parent.receipt.task));
                    const live = try service.workspaceCommand(scratch, "late-cleanup-inspect", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = try workspaceRef(scratch, .work, pending_id) } } });
                    var observed = try native.json.parse(scratch, live.observation_json.bytes, .{});
                    defer observed.deinit();
                    try std.testing.expect(observed.value.object.get("port_accepts_command").?.bool);
                    var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, ref, null));
                    defer port.deinit();
                    _ = try service.workspaceInteract(scratch, "answer-late-cleanup", parent.receipt.task, .{
                        .expected = .{ .work = try workspaceRef(scratch, .work, pending_id), .execution_revision = pending.value.execution_revision, .control_revision = pending.value.control_revision },
                        .port = try workspaceRef(scratch, .port, port.value.id),
                        .generation = port.value.generation,
                        .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = "{}" } } } },
                    });
                    answered_cleanup = true;
                    break;
                }
            }
            try std.testing.expect(answered_cleanup);
        }
        for (0..30) |_| {
            _ = try service.pump(scratch);
            if (try service.associatedWorkDisposed(scratch, parent.receipt.task)) break;
        }
        try std.testing.expect(try service.associatedWorkDisposed(scratch, parent.receipt.task));
        var retained_result = try service.task(scratch, parent.receipt.task);
        defer retained_result.deinit();
        try std.testing.expectEqual(.completed, retained_result.value.outcome_kind);
        try std.testing.expectEqualDeep(finished.value.result, retained_result.value.result);
        try std.testing.expectEqualDeep(finished.value.outcome, retained_result.value.outcome);
        try std.testing.expect(!retained_result.value.cancellation_applied);
        const cancelled_archive = try std.fmt.allocPrint(scratch, "{s}/cancelled-children-{d}.par", .{ path_buffer[0..length], index });
        _ = try service.exportCheckpoint(scratch, parent.receipt.task, cancelled_archive);
    }
}

fn expectModelRequestBudget(service: anytype, a: std.mem.Allocator, child: native.workspace.Work) !void {
    const store = &service.namespace.store;
    const Reader = struct {
        fn read(pointer: *anyopaque, allocator: std.mem.Allocator, ref: native.testing.state.Reference, limit: usize) ![]u8 {
            const source_store: *@TypeOf(service.namespace.store) = @ptrCast(@alignCast(pointer));
            return source_store.object(allocator, ref, limit);
        }
    };
    var delegation = (try contracts.decodeOwned(native.workspace.Delegation, a, try store.object(a, child.delegation.?, null))).value;
    const original_port = (try contracts.decodeOwned(native.workspace.Port, a, try store.object(a, delegation.port, null))).value;
    try store.begin();
    defer store.rollback();
    const huge_schema = try store.putObject(try data.schema.encodeOwned(a, &.{ .{ .array = .{ .element = 1, .length = 1_000_000_000 } }, .unit }, 0));
    const empty = try store.putObject("");
    const artifact = try store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, a, .{ .schema = huge_schema, .value = empty, .provenance = empty }));
    const prepare = native.workspace_instrument.declaration(.model).capture.?.prepare;
    var context: native.registry.ProjectionContext = .{ .allocator = a, .task = child.task, .tenant = "test", .profile = "test", .objects = native.registry.ReadView.validating(store, Reader.read) };
    const unlimited = (try contracts.decodeOwned(native.workspace_instrument.Prepared, a, try prepare(context, try contracts.encodeOwned(native.workspace_instrument.Input, a, .{ .delegation = child.delegation.? })))).value;
    delegation.model.?.settings.request_bytes = 8 * 1024;
    const bounded_ref = try store.putObject(try contracts.encodeOwned(native.workspace.Delegation, a, delegation));
    const bounded = (try contracts.decodeOwned(native.workspace_instrument.Prepared, a, try prepare(context, try contracts.encodeOwned(native.workspace_instrument.Input, a, .{ .delegation = bounded_ref })))).value;
    try std.testing.expectEqualStrings(unlimited.body.bytes, bounded.body.bytes);
    for (0..2) |variant| {
        var port = original_port;
        if (variant == 0) {
            delegation.inputs.items = &.{artifact};
        } else {
            delegation.inputs.items = &.{};
            port.interface.payload = huge_schema;
            port.payload = empty;
        }
        delegation.port = try store.putObject(try contracts.encodeOwned(native.workspace.Port, a, port));
        const ref = try store.putObject(try contracts.encodeOwned(native.workspace.Delegation, a, delegation));
        const input = try contracts.encodeOwned(native.workspace_instrument.Input, a, .{ .delegation = ref });
        var buffer: [256 * 1024]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buffer);
        context.allocator = allocator.allocator();
        try std.testing.expectError(error.Capacity, prepare(context, input));
    }
}

fn expectInstrumentAnswerBound(service: anytype, a: std.mem.Allocator, child: native.workspace.Work) !void {
    const store = &service.namespace.store;
    try service.validateWorkspace(a, child.task);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, child.task, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    const old_result_id = try native.workspace.custodyId(a, child.task, child.result_value.?.digest);
    const old_answer_id = try native.workspace.custodyId(a, child.task, child.answer_value.?.digest);
    var original_result = try contracts.decodeOwned(native.workspace.Value, a, (try store.recordBytes(a, "workspace_value", old_result_id, child.task)).?);
    defer original_result.deinit();
    var original_answer = try contracts.decodeOwned(native.workspace.ValueArtifact, a, try store.object(a, child.answer_value.?, null));
    defer original_answer.deinit();
    for (0..3) |variant| {
        try store.begin();
        defer store.rollback();
        var forged = child;
        var records: std.ArrayList(native.testing.state.ArchiveRecord) = .empty;
        for (index.records.items) |row| if (!std.meta.eql(row.id, old_result_id) and !std.meta.eql(row.id, old_answer_id)) try records.append(a, row);
        try store.database.run("DELETE FROM records WHERE task=? AND kind='workspace_value' AND id=?", &.{ .{ .blob = &child.task }, .{ .blob = &old_answer_id } });
        if (variant == 0) {
            // Same typed bytes, but an unrelated hypothesis is not the answer's
            // selected acquisition or captured model judgment.
            var answer: native.workspace.Value = .{ .id = undefined, .task = child.task, .artifact = undefined, .description = original_answer.value, .derivation = .{ .kind = .hypothesis, .sources = .{ .items = &.{} } } };
            answer.description.provenance = try store.putObject(try contracts.encodeOwned(native.workspace.Derivation, a, answer.derivation));
            answer.artifact = try store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, a, answer.description));
            answer.id = try native.workspace.custodyId(a, child.task, answer.artifact.digest);
            try store.createRecord(native.workspace.Value, "workspace_value", answer.id, child.task, answer);
            try records.append(a, .{ .kind = .workspace_value, .id = answer.id, .body = try store.putObject(try contracts.encodeOwned(native.workspace.Value, a, answer)) });
            forged.answer_value = answer.artifact;
        } else forged.answer_value = null;
        forged.inputs.items = if (forged.answer_value) |ref| try a.dupe(native.testing.state.Reference, &.{ref}) else &.{};
        if (variant == 2) {
            // A real checkpoint of the SAME native program can return another
            // reply. It must not substitute for the actual captured reply.
            var program = try contracts.decodeOwned(native.workspace.ProgramArtifact, a, try store.object(a, try store.objectReference(child.program, null), null));
            defer program.deinit();
            var prepared = try kosmos.Prepared.init(a, try store.object(a, program.value.image, null));
            defer prepared.deinit();
            var resident = try kosmos.Resident.start(a, &prepared, try store.object(a, child.input, null));
            defer resident.close() catch unreachable;
            var requested = try resident.publish(.{ .encoded = a }, .none, .{ .quantum = 256, .checkpoint = .receipt });
            defer requested.takeCheckpoint().?.deinit();
            var initial = try data.invocation.decode(data.invocation.Outcome, a, requested.outcome.encoded);
            defer initial.deinit();
            var request = try data.invocation.decode(data.invocation.Request, a, initial.value.requested.request);
            defer request.deinit();
            const output = try contracts.encodeOwned(native.workspace_instrument.Output, a, .{ .unavailable = .{ .bytes = "invented alternative reply" } });
            const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.value.request_identity, .value = output });
            var published = try resident.publish(.{ .encoded = a }, .{ .reply = reply }, .{ .quantum = 256, .checkpoint = .receipt });
            const checkpoint = published.takeCheckpoint().?;
            defer checkpoint.deinit();
            var completed = try data.invocation.decode(data.invocation.Outcome, a, published.outcome.encoded);
            defer completed.deinit();
            try std.testing.expectEqual(.completed, std.meta.activeTag(completed.value));
            forged.checkpoint = try store.putObject(checkpoint.bytes());
            forged.outcome = try store.putObject(published.outcome.encoded);
            forged.result = try store.putObject(completed.value.completed);
        }
        var result = original_result.value;
        result.description.value = forged.result.?;
        const sources = try a.alloc(native.testing.state.Reference, 1 + forged.inputs.items.len);
        sources[0] = forged.input_value.?;
        @memcpy(sources[1..], forged.inputs.items);
        result.derivation.sources.items = sources;
        result.description.provenance = try store.putObject(try contracts.encodeOwned(native.workspace.Derivation, a, result.derivation));
        result.artifact = try store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, a, result.description));
        result.id = try native.workspace.custodyId(a, child.task, result.artifact.digest);
        try store.database.run("DELETE FROM records WHERE task=? AND kind='workspace_value' AND id=?", &.{ .{ .blob = &child.task }, .{ .blob = &old_result_id } });
        try store.createRecord(native.workspace.Value, "workspace_value", result.id, child.task, result);
        try records.append(a, .{ .kind = .workspace_value, .id = result.id, .body = try store.putObject(try contracts.encodeOwned(native.workspace.Value, a, result)) });
        forged.result_value = result.artifact;
        try store.putRecord(native.workspace.Work, "workspace_work", child.id, child.task, forged);
        var events = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &child.task }, .{ .integer = @intCast(child.event_watermark) } });
        defer events.deinit();
        try std.testing.expect(try events.step() == .row);
        var event_value = (try contracts.decodeOwned(native.testing.state.Event, a, try events.bytes(0))).value;
        const publications = try a.dupe(native.testing.state.WorkPublication, event_value.workspace_publications.items);
        const observation = try contracts.encodeOwned(native.workspace.WorkObservation, a, .{ .work = forged, .occurrence = null });
        for (publications) |*item| if (std.meta.eql(item.work, child.id)) {
            std.crypto.hash.sha2.Sha256.hash(observation, &item.observation, .{});
        };
        event_value.workspace_publications.items = publications;
        const event_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, event_value));
        try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &child.task }, .{ .integer = @intCast(child.event_watermark) } });
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(a, child.task, records.items));
    }
}

const DelegateTypes = struct {
    pub const application_id = "workspace-delegation-test";
    pub const input_schema_id = "workspace-delegation.input/1";
    pub const output_schema_id = "workspace-delegation.output/1";
    pub const failure_schema_id = "workspace-delegation.failure/1";
    pub const message_schema_id = "workspace-delegation.message/1";
    pub const Input = void;
    pub const Output = void;
    pub const Failure = void;
    pub const Message = contracts.workspace.Command;
};
const DelegateApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const interop = horos.authoring.interop;
        const b = c.builder;
        const unit = try b.scalar(void);
        const output = try interop.schemaId(c.author, try c.schema(contracts.workspace.Reply));
        const inbox = try interop.operationId(c.author, try @import("protean").inbox.Profile(DelegateTypes.Message).declare(c));
        const workspace = try interop.operationId(c.author, try c.external("workspace-delegation", try c.schema(DelegateTypes.Message), try c.schema(contracts.workspace.Reply), .read));
        const inbox_schema = b.effects.items[@intCast(inbox)].result;
        const message_schema = b.schemas.items[@intCast(inbox_schema)].sum[1];
        const fields = b.schemas.items[@intCast(message_schema)].product;
        const entry = try b.declare(&.{unit}, unit, &.{ inbox, workspace }, &.{});
        const repeat = try b.term(.{ .yield_then = try b.term(.{ .call = .{ .function = entry, .arguments = &.{try b.constant(void, {})} } }) });
        const received = try b.variable(inbox_schema);
        const empty = try b.variable(unit);
        const message = try b.variable(message_schema);
        const id = try b.variable(fields[0]);
        const command = try b.variable(fields[1]);
        const ignored = try b.variable(output);
        const apply = try b.bind(ignored, try b.term(.{ .perform = .{ .effect = workspace, .payload = try b.reference(command) } }), repeat);
        const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(message), .variables = &.{ id, command }, .body = apply } });
        const select = try b.term(.{ .match_sum = .{ .value = try b.reference(received), .cases = &.{ .{ .variable = empty, .body = repeat }, .{ .variable = message, .body = unpack } } } });
        try b.define(entry, try b.bind(received, try b.term(.{ .perform = .{ .effect = inbox, .payload = try b.constant(void, {}) } }), select));
        return b.module(entry, unit);
    }
    fn authorize(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
        var command = try contracts.decodeOwned(contracts.workspace.Command, ctx.allocator, bytes);
        defer command.deinit();
        var model: ?native.workspace.ModelBinding = null;
        if (command.value == .work and command.value.work == .delegate and command.value.work.delegate.interpretation == .model) {
            const selection = command.value.work.delegate.interpretation.model;
            if (!std.mem.eql(u8, selection.profile_id.bytes, "fixture") or !std.mem.eql(u8, selection.effort.bytes, "medium")) return error.Denied;
            model = .{ .profile_id = .{ .bytes = "fixture" }, .profile_digest = @splat(7), .settings = .{ .endpoint = .{ .bytes = "https://localhost/v1/responses" }, .audience = .{ .bytes = "fixture" }, .model = .{ .bytes = "fixture" }, .effort = .{ .bytes = "medium" }, .max_output_tokens = null, .request_bytes = null, .response_bytes = null, .timeout_ms = null }, .reasoning_mode = .{ .bytes = "standard" }, .reasoning_context = .{ .bytes = "auto" } };
        }
        return contracts.encodeOwned(native.workspace.Authorized, ctx.allocator, .{ .command = command.value, .snapshot = ctx.resources[0], .model = model });
    }
};

fn inputPort(b: *source.Builder, text: bool) !source.Module {
    const unit = try b.scalar(void);
    const answer = if (text) try b.schema(.text) else try b.scalar(u64);
    const ask = try b.effect(.{ .identity = "example/input", .payload = unit, .result = answer, .external = false });
    const entry = try b.declare(&.{unit}, answer, &.{ask}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }));
    return b.module(entry, unit);
}

test "OWN-02 OWN-05 OWN-10 delegated typed answers use distinct real occurrences while root messages remain independent" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try @import("protean").compile(a, @import("protean").system(.{ .InitialArgs = void, .Result = void, .Failure = void, .application = DelegateApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "delegation-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "delegation-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = image, .application = "delegation-unit", .manifest = manifest };
    const declarations = [_]native.Declaration{ native.inbox.declaration(DelegateTypes.Message), .{ .identity = "workspace-delegation", .resource_role = "workspace", .kind = .workspace, .workspace = DelegateApplication.authorize, .payload_schema = WaitApplication.schema, .resume_schema = WaitApplication.result }, native.workspace_instrument.declaration(.model), native.workspace_instrument.declaration(.snapshot) };
    var handlers = try native.Registry.init(a, &declarations);
    defer handlers.deinit();
    const text = "actual frozen evidence";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const snapshot = try contracts.encodeOwned(contracts.RepositorySnapshot, a, .{ .version = 2, .excluded_entries = 0, .files = .{ .items = &.{.{ .path = .{ .bytes = "source.txt" }, .sha256 = digest, .contents = .{ .bytes = text } }} } });
    defer a.free(snapshot);
    var grants: [declarations.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "delegation-test", .resources = &.{snapshot}, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test", .inference = true } };
    for (declarations, &grants) |declaration, *grant| grant.* = .{ .identity = declaration.identity, .resource_role = declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    var namespace_open = true;
    defer if (namespace_open) namespace.close() catch unreachable;
    var service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    var service_open = true;
    defer if (service_open) service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const Scenario = enum { model, snapshot, snapshot_empty, model_unavailable, revoked, unknown, unknown_wait, not_sent_wait, cancel_capture, invalid_capture, response_failed, response_incomplete, response_error };
    for (std.enums.values(Scenario)) |scenario| {
        const snapshot_mode = scenario == .snapshot or scenario == .snapshot_empty;
        const successful = scenario == .model or snapshot_mode;
        const suffix = @tagName(scenario);
        const parent = try service.submit(scratch, try std.fmt.allocPrint(scratch, "parent-{s}", .{suffix}), {});
        var builder = source.Builder.init(a);
        defer builder.deinit();
        const source_text = try native.source_records.encode(scratch, try inputPort(&builder, snapshot_mode));
        const built_reply = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "build-{s}", .{suffix}), parent.receipt.task, .{ .program = .{ .build = .{ .source = .{ .json_text = .{ .bytes = source_text } }, .source_kind = .source_records, .exposures = .{ .items = &.{.{ .effect = 0, .class = .input }} } } } });
        try std.testing.expect(built_reply.program != null);
        const target_start = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "start-{s}", .{suffix}), parent.receipt.task, try nativeIdentity(built_reply.program.?), &.{}, .{});
        const target_id = target_start.receipt.workspace.?;
        var target = try service.workspaceWork(scratch, parent.receipt.task, target_id);
        defer target.deinit();
        var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, target.value.current_port.?, null));
        defer port.deinit();
        const port_ref = try workspaceRef(scratch, .port, port.value.id);
        const interpretation: contracts.workspace.Interpretation = if (snapshot_mode) .{ .snapshot = .{ .port = port_ref, .generation = port.value.generation, .path = .{ .bytes = "source.txt" }, .offset = 0, .maximum = if (scenario == .snapshot_empty) 0 else text.len } } else .{ .model = .{ .port = port_ref, .generation = port.value.generation, .profile_id = .{ .bytes = "fixture" }, .effort = .{ .bytes = "medium" }, .subproblem = .{ .bytes = "Return forty-two as the selected hypothetical value." }, .inputs = .{ .items = &.{} } } };
        _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "delegate-{s}", .{suffix}), parent.receipt.task, .{ .work = .{ .delegate = .{ .expected = .{ .work = try workspaceRef(scratch, .work, target_id), .execution_revision = target.value.execution_revision, .control_revision = target.value.control_revision }, .policy = .{ .stop = .terminal, .continuation = .owner_scheduled }, .interpretation = interpretation } } });
        var dispatches: usize = 0;
        var instrument_id: ?[32]u8 = null;
        var resumed_handoff = false;
        for (0..256) |_| {
            if (instrument_id == null) {
                var rows = try namespace.store.database.prepare("SELECT body FROM records WHERE task=? AND kind='workspace_work'", &.{.{ .blob = &parent.receipt.task }});
                defer rows.deinit();
                while (try rows.step() == .row) {
                    const bytes = try rows.bytes(0);
                    const ref = try namespace.store.objectReference(bytes[0..32].*, null);
                    var candidate = try contracts.decodeOwned(native.workspace.Work, scratch, try namespace.store.object(scratch, ref, null));
                    defer candidate.deinit();
                    if (candidate.value.delegation != null) instrument_id = candidate.value.id;
                }
                if (scenario == .model and instrument_id != null) {
                    // Keep the admitted instrument but omit the other half of
                    // the same delegation, restoring its prior valid target.
                    var manifest_digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(manifest, &manifest_digest, .{});
                    const archive_index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = manifest.len });
                    try namespace.store.begin();
                    defer namespace.store.rollback();
                    var events = try namespace.store.database.prepare("SELECT seq,o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY seq DESC", &.{.{ .blob = &parent.receipt.task }});
                    defer events.deinit();
                    var changed = false;
                    while (try events.step() == .row) {
                        var event_value = try contracts.decodeOwned(native.testing.state.Event, scratch, try events.bytes(1));
                        const publications = event_value.value.workspace_publications.items;
                        if (publications.len != 2 or !std.meta.eql(publications[0].work, instrument_id.?)) continue;
                        try std.testing.expectEqualDeep(target_id, publications[1].work);
                        event_value.value.workspace_publications.items = publications[0..1];
                        const rewritten = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, event_value.value));
                        try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &rewritten.digest }, .{ .blob = &parent.receipt.task }, .{ .integer = try events.integer(0) } });
                        changed = true;
                        break;
                    }
                    try std.testing.expect(changed);
                    try namespace.store.putRecord(native.workspace.Work, "workspace_work", target_id, parent.receipt.task, target.value);
                    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, parent.receipt.task, archive_index.records.items));
                }
                if (scenario == .revoked and instrument_id != null) {
                    var current = try service.workspaceWork(scratch, parent.receipt.task, target_id);
                    defer current.deinit();
                    _ = try service.workspaceControl(scratch, "revoke-delegation", parent.receipt.task, target_id, current.value.execution_revision, current.value.control_revision, .park);
                }
            }
            const step = try service.pump(scratch);
            if (step == .work) {
                try std.testing.expect(scenario != .revoked);
                dispatches += 1;
                try std.testing.expectEqual(@as(usize, 1), dispatches);
                try std.testing.expect(step.work.subject_work != null);
                instrument_id = step.work.subject_work;
                if (successful) {
                    var active = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                    defer active.deinit();
                    const operation_id = try std.fmt.allocPrint(scratch, "refresh-in-flight-{s}", .{suffix});
                    const refreshed = try service.workspaceControl(scratch, operation_id, parent.receipt.task, instrument_id.?, active.value.execution_revision, active.value.control_revision, .{ .delegate = active.value.policy });
                    const replayed = try service.workspaceControl(scratch, operation_id, parent.receipt.task, instrument_id.?, active.value.execution_revision, active.value.control_revision, .{ .delegate = active.value.policy });
                    try std.testing.expectEqualDeep(refreshed.receipt, replayed.receipt);
                    var current = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                    defer current.deinit();
                    try std.testing.expectEqual(.active, current.value.schedule);
                    try std.testing.expectEqual(active.value.execution_revision, current.value.execution_revision);
                    try std.testing.expectEqual(active.value.control_revision + 1, current.value.control_revision);
                    if (scenario == .snapshot_empty) _ = try service.workspaceControl(scratch, "park-in-flight", parent.receipt.task, instrument_id.?, current.value.execution_revision, current.value.control_revision, .park);
                }
                var root = try service.task(scratch, parent.receipt.task);
                defer root.deinit();
                try std.testing.expect(!std.meta.eql(root.value.current_occurrence, step.work.occurrence));
                const wait_for_failure = scenario == .unknown_wait or scenario == .not_sent_wait or scenario == .cancel_capture;
                var waiting_revision: u64 = 0;
                if (wait_for_failure) {
                    var active_child = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                    defer active_child.deinit();
                    _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "wait-{s}", .{suffix}), parent.receipt.task, .{ .work = .{ .wait = .{
                        .works = .{ .items = &.{try workspaceRef(scratch, .work, instrument_id.?)} },
                        .after = active_child.value.event_watermark,
                    } } });
                    for (0..32) |_| {
                        const root_step = try service.pump(scratch);
                        try std.testing.expect(root_step != .work);
                        if (root_step == .idle) break;
                    }
                    var waiting_root = try service.task(scratch, parent.receipt.task);
                    defer waiting_root.deinit();
                    try std.testing.expectEqual(.parked, waiting_root.value.schedule);
                    waiting_revision = waiting_root.value.execution_revision;
                } else _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "amend-{s}", .{suffix}), parent.receipt.task, .{ .context = .{ .inspect = .{ .page = .{} } } });
                var wrong = step.work;
                wrong.subject_work = @splat(99);
                try std.testing.expectError(error.StaleOccurrence, service.acquire(scratch, wrong, ""));
                if (scenario == .unknown or scenario == .cancel_capture) {
                    var pending_child = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                    defer pending_child.deinit();
                    var guarded: AfterCommitAllocator = .{ .backing = scratch, .namespace = &namespace, .generation = namespace.store.head.generation };
                    _ = try service.workspaceControl(guarded.allocator(), try std.fmt.allocPrint(scratch, "cancel-{s}", .{suffix}), parent.receipt.task, instrument_id.?, pending_child.value.execution_revision, pending_child.value.control_revision, .{ .cancel = .{ .bytes = if (scenario == .unknown) "" else "cancel explicitly delegated judgment" } });
                    try std.testing.expectEqual(@as(usize, 0), guarded.rejected);
                    try std.testing.expect(try service.shouldCancelWork(step.work));
                }
                if (scenario == .unknown) {
                    try service.unknown(scratch, step.work);
                    _ = try service.requestCancel(scratch, "cancel-parent-with-unknown-child", parent.receipt.task, "");
                } else if (scenario == .unknown_wait or scenario == .not_sent_wait) {
                    if (scenario == .unknown_wait) try service.unknown(scratch, step.work) else try service.notSent(scratch, step.work);
                    for (0..32) |_| {
                        const root_step = try service.pump(scratch);
                        try std.testing.expect(root_step != .work);
                        if (root_step == .idle) break;
                    }
                    var awakened = try service.task(scratch, parent.receipt.task);
                    defer awakened.deinit();
                    try std.testing.expect(awakened.value.execution_revision > waiting_revision);
                } else if (snapshot_mode) {
                    const worker = try native.testing.Worker.init(a, io);
                    defer worker.deinit(a) catch unreachable;
                    try worker.start(step.work, profile.authority, null);
                    while (!worker.finished()) try io.sleep(.fromMilliseconds(1), .awake);
                    try worker.join();
                    try service.completeWork(scratch, step.work, worker.result.?);
                    try worker.release();
                    if (scenario == .snapshot_empty) {
                        var parked = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                        defer parked.deinit();
                        try std.testing.expectEqual(.parked, parked.value.schedule);
                        try std.testing.expect(parked.value.answer_value == null);
                        _ = try service.workspaceControl(scratch, "resume-after-capture", parent.receipt.task, instrument_id.?, parked.value.execution_revision, parked.value.control_revision, .{ .delegate = parked.value.policy });
                    }
                } else {
                    const raw = try contracts.encodeOwned(native.responses.Raw, scratch, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = "{\"output\":[{\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"typed-answer\",\"name\":\"answer\",\"arguments\":\"{\\\"json_value\\\":\\\"\\\\\\\"42\\\\\\\"\\\"}\"}],\"usage\":{\"output_tokens\":7}}" } });
                    var response = try contracts.decodeOwned(native.responses.Raw, scratch, raw);
                    defer response.deinit();
                    const envelope = try std.fmt.allocPrint(scratch, "{{\"status\":\"{s}\",\"error\":{s},{s}", .{
                        if (scenario == .response_failed) "failed" else if (scenario == .response_incomplete) "incomplete" else "completed",
                        if (scenario == .response_error) "{}" else "null",
                        response.value.body.bytes[1..],
                    });
                    response.value.body.bytes = envelope;
                    if (scenario == .model_unavailable) response.value.body.bytes = "{\"status\":\"completed\",\"error\":null,\"output\":[],\"usage\":{\"output_tokens\":0}}";
                    const captured = try contracts.encodeOwned(native.responses.Raw, scratch, response.value);
                    try service.acquire(scratch, step.work, if (scenario == .invalid_capture) "malformed controlled capture" else captured);
                }
            }
            var result = try service.workspaceWork(scratch, parent.receipt.task, target_id);
            defer result.deinit();
            if (successful and !resumed_handoff and instrument_id != null) {
                var completed = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
                defer completed.deinit();
                if (completed.value.answer_value != null) {
                    try std.testing.expectEqual(.completed, completed.value.outcome_kind);
                    try std.testing.expectEqual(.requested, result.value.outcome_kind);
                    if (scenario == .model) try expectModelRequestBudget(&service, scratch, completed.value);
                    try expectInstrumentAnswerBound(&service, scratch, completed.value);
                    try service.close(scratch);
                    service_open = false;
                    try namespace.close();
                    namespace_open = false;
                    namespace = try native.Namespace.open(a, io, path);
                    namespace_open = true;
                    service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
                    service_open = true;
                    try std.testing.expectEqual(.idle, try service.pump(scratch));
                    var paused = try service.task(scratch, parent.receipt.task);
                    defer paused.deinit();
                    _ = try service.resumeTask(scratch, try std.fmt.allocPrint(scratch, "resume-completed-answer-{s}", .{suffix}), parent.receipt.task, paused.value.revision);
                    resumed_handoff = true;
                }
            }
            if (result.value.outcome_kind == .completed or (instrument_id != null and step == .idle)) break;
        }
        try std.testing.expectEqual(@as(usize, if (scenario == .revoked) 0 else 1), dispatches);
        if (scenario == .model) try std.testing.expect(resumed_handoff);
        var result = try service.workspaceWork(scratch, parent.receipt.task, target_id);
        defer result.deinit();
        var child = try service.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
        defer child.deinit();
        if (!successful) {
            if (scenario == .unknown) {
                try std.testing.expectEqual(.cancelled, result.value.outcome_kind);
                var root = try service.task(scratch, parent.receipt.task);
                defer root.deinit();
                try std.testing.expect(root.value.terminal());
                try std.testing.expect(!try service.taskCleanupComplete(scratch, root.value));
            } else {
                try std.testing.expectEqual(.requested, result.value.outcome_kind);
                try std.testing.expectEqualDeep(target.value.current_port, result.value.current_port);
            }
            try std.testing.expect(child.value.answer_value == null);
            try std.testing.expect(!try service.associatedWorkDisposed(scratch, parent.receipt.task));
            if (scenario == .cancel_capture) {
                try std.testing.expectEqual(.cancelled, child.value.outcome_kind);
                try std.testing.expect(child.value.cancellation_applied);
            } else if (scenario == .model_unavailable) {
                try std.testing.expectEqual(.completed, child.value.outcome_kind);
                try std.testing.expect(child.value.current_occurrence == null);
            } else {
                const bytes = (try namespace.store.recordBytes(scratch, "occurrence", child.value.current_occurrence.?, parent.receipt.task)).?;
                var pending = try contracts.decodeOwned(native.testing.occurrence.Occurrence, scratch, bytes);
                defer pending.deinit();
                switch (scenario) {
                    .revoked => {
                        try std.testing.expectEqual(.ready, pending.value.state);
                        try std.testing.expectEqual(.denied, child.value.blocker.?);
                    },
                    .unknown => {
                        try std.testing.expect(pending.value.state == .unknown);
                        try std.testing.expect(try service.shutdownIncomplete(scratch));
                    },
                    .unknown_wait => try std.testing.expect(pending.value.state == .unknown),
                    .not_sent_wait => try std.testing.expect(pending.value.state == .not_sent),
                    .invalid_capture, .response_failed, .response_incomplete, .response_error => try std.testing.expect(pending.value.state == .captured),
                    else => unreachable,
                }
            }
        } else {
            try std.testing.expectEqual(.completed, result.value.outcome_kind);
            try std.testing.expect(child.value.answer_value != null);
            var artifact = try contracts.decodeOwned(native.workspace.ValueArtifact, scratch, try namespace.store.object(scratch, child.value.answer_value.?, null));
            defer artifact.deinit();
            var derivation = try contracts.decodeOwned(native.workspace.Derivation, scratch, try namespace.store.object(scratch, artifact.value.provenance, null));
            defer derivation.deinit();
            try std.testing.expectEqual(@as(@TypeOf(derivation.value.kind), if (snapshot_mode) .acquisition else .judgment), derivation.value.kind);
            const result_bytes = try namespace.store.object(scratch, result.value.result.?, null);
            if (snapshot_mode) {
                var actual = try contracts.decodeOwned(contracts.Utf8, scratch, result_bytes);
                defer actual.deinit();
                try std.testing.expectEqualStrings(if (scenario == .snapshot_empty) "" else text, actual.value.bytes);
            } else {
                var actual = try contracts.decodeOwned(u64, scratch, result_bytes);
                defer actual.deinit();
                try std.testing.expectEqual(@as(u64, 42), actual.value);
                var root = try service.task(scratch, parent.receipt.task);
                defer root.deinit();
                try std.testing.expectEqual(@as(u64, 1), root.value.inference_attempts);
                try std.testing.expectEqual(@as(u64, 7), root.value.inference_output_tokens);
            }
        }
        if (scenario == .model) {
            // OWN-02/14: the identical typed request can be answered directly,
            // by a pure computation, or by the model above. Equal request bytes
            // do not make the two retained subjects share settlement authority.
            const direct_start = try service.workspaceStart(scratch, "answer-direct-start", parent.receipt.task, try nativeIdentity(built_reply.program.?), &.{}, .{});
            const computed_start = try service.workspaceStart(scratch, "answer-computed-start", parent.receipt.task, try nativeIdentity(built_reply.program.?), &.{}, .{});
            var direct = try service.workspaceWork(scratch, parent.receipt.task, direct_start.receipt.workspace.?);
            defer direct.deinit();
            var computed = try service.workspaceWork(scratch, parent.receipt.task, computed_start.receipt.workspace.?);
            defer computed.deinit();
            try std.testing.expect(!std.meta.eql(direct.value.current_occurrence, computed.value.current_occurrence));
            var direct_port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, direct.value.current_port.?, null));
            defer direct_port.deinit();
            var computed_port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, computed.value.current_port.?, null));
            defer computed_port.deinit();
            try std.testing.expectEqualDeep(direct_port.value.request, computed_port.value.request);
            var algorithm = source.Builder.init(a);
            defer algorithm.deinit();
            var diagnostic: native.program_construction.Diagnostic = .{};
            const pure_program = try service.workspaceBuild(scratch, "answer-pure-build", parent.receipt.task, try native.source_records.encode(scratch, try gcd(&algorithm)), &diagnostic);
            const pure_start = try service.workspaceStart(scratch, "answer-pure-start", parent.receipt.task, pure_program.receipt.workspace.?, try contracts.encodeOwned(struct { u64, u64 }, scratch, .{ 84, 42 }), .{});
            var pure = try service.workspaceWork(scratch, parent.receipt.task, pure_start.receipt.workspace.?);
            defer pure.deinit();
            try std.testing.expectEqual(.completed, pure.value.outcome_kind);
            for ([_]native.workspace.Work{ direct.value, computed.value }, [_]native.workspace.Port{ direct_port.value, computed_port.value }, 0..) |recipient, recipient_port, i| {
                const answer: contracts.workspace.ValueInput = if (i == 0) .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, recipient_port.interface.argument.digest), .json_text = .{ .bytes = "\"42\"" } } } else .{ .reference = try workspaceRef(scratch, .value, pure.value.result_value.?.digest) };
                _ = try service.workspaceInteract(scratch, if (i == 0) "answer-direct" else "answer-computed", parent.receipt.task, .{
                    .expected = .{ .work = try workspaceRef(scratch, .work, recipient.id), .execution_revision = recipient.execution_revision, .control_revision = recipient.control_revision },
                    .port = try workspaceRef(scratch, .port, recipient_port.id),
                    .generation = recipient_port.generation,
                    .command = .{ .resume_value = answer },
                });
                for (0..32) |_| {
                    _ = try service.pump(scratch);
                    var observed = try service.workspaceWork(scratch, parent.receipt.task, recipient.id);
                    defer observed.deinit();
                    if (observed.value.terminal()) break;
                }
                var answered = try service.workspaceWork(scratch, parent.receipt.task, recipient.id);
                defer answered.deinit();
                try std.testing.expectEqual(.completed, answered.value.outcome_kind);
                try std.testing.expectEqualDeep(result.value.result, answered.value.result);
                try std.testing.expect(!std.meta.eql(result.value.result_value, answered.value.result_value));
            }
            var root = try service.task(scratch, parent.receipt.task);
            defer root.deinit();
            try std.testing.expectEqual(@as(u64, 1), root.value.inference_attempts);
        }
        if (scenario == .model) try expectProgramProgressIsDerived(&service, scratch, parent.receipt.task);
        const archive_path = try std.fmt.allocPrint(scratch, "{s}/{s}.par", .{ path_buffer[0..length], suffix });
        _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
        const import_path = try std.fmt.allocPrint(scratch, "{s}/import-{s}", .{ path_buffer[0..length], suffix });
        try service.close(a);
        service_open = false;
        try namespace.close();
        namespace_open = false;
        {
            var imported_namespace = try native.Namespace.open(a, io, import_path);
            defer imported_namespace.close() catch unreachable;
            var imported = try native.tasks.Service(DelegateTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
            defer imported.close(a) catch unreachable;
            _ = try imported.importCheckpoint(scratch, "import", archive_path);
            try std.testing.expectEqual(.idle, try imported.pump(scratch));
            var retained = try imported.workspaceWork(scratch, parent.receipt.task, target_id);
            defer retained.deinit();
            try std.testing.expectEqualDeep(result.value.result, retained.value.result);
            var imported_child = try imported.workspaceWork(scratch, parent.receipt.task, instrument_id.?);
            defer imported_child.deinit();
            try std.testing.expectEqualDeep(child.value, imported_child.value);
            var imported_parent = try imported.task(scratch, parent.receipt.task);
            defer imported_parent.deinit();
            try std.testing.expectEqual(@as(u64, if (scenario == .revoked or snapshot_mode) 0 else 1), imported_parent.value.inference_attempts);
        }
        namespace = try native.Namespace.open(a, io, path);
        namespace_open = true;
        service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        service_open = true;
        try std.testing.expectEqual(.idle, try service.pump(scratch));
    }
    // Exercise automatic result, failure, port, and value previews through the
    // actual controller occurrence, retained reply evidence, and archive replay.
    for ([_]enum { result, failure, port }{ .result, .failure, .port }) |kind| {
        const label = @tagName(kind);

        const parent = try service.submit(scratch, try std.fmt.allocPrint(scratch, "overflow-parent-{s}", .{label}), {});
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const huge = try b.schema(.{ .array = .{ .element = unit, .length = 10_000_000_000_000_000_000 } });
        const literal = try b.literal(.{ .schema = huge, .bytes = "" });
        const effect = try b.effect(.{ .identity = "overflow-payload", .payload = huge, .result = unit, .external = false });
        const entry = try b.declare(&.{unit}, if (kind == .result) huge else unit, if (kind == .port) &.{effect} else &.{}, &.{});
        try b.define(entry, switch (kind) {
            .result => try b.pure(literal),
            .failure => try b.term(.{ .fail = literal }),
            .port => try b.term(.{ .perform = .{ .effect = effect, .payload = literal } }),
        });
        const built = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "overflow-build-{s}", .{label}), parent.receipt.task, .{ .program = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = try native.source_records.encode(scratch, b.module(entry, if (kind == .failure) huge else unit)) } },
            .source_kind = .source_records,
            .exposures = .{ .items = if (kind == .port) &.{.{ .effect = effect, .class = .input }} else &.{} },
        } } });
        try std.testing.expect(built.program != null);
        var artifact = try service.workspaceProgram(scratch, parent.receipt.task, try nativeIdentity(built.program.?));
        defer artifact.deinit();

        _ = try service.message(scratch, try std.fmt.allocPrint(scratch, "overflow-message-{s}", .{label}), parent.receipt.task, .{ .work = .{ .start = .{
            .program = built.program.?,
            .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, artifact.value.description.input_schema.digest), .json_text = .{ .bytes = "{}" } } },
            .policy = .{},
        } } });
        var reply: ?contracts.workspace.Reply = null;
        for (0..32) |_| {
            _ = try service.pump(scratch);
            var query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='workspace_reply'", &.{.{ .blob = &parent.receipt.task }});
            defer query.deinit();
            if (try query.step() != .row) continue;
            const saved = (try contracts.decodeOwned(native.workspace.ReplyObservation, scratch, try query.bytes(0))).value;
            try std.testing.expect(saved.evidence == .admitted);
            const pending = (try contracts.decodeOwned(native.testing.occurrence.Occurrence, scratch, (try namespace.store.recordBytes(scratch, "occurrence", saved.id, saved.task)).?)).value;
            try std.testing.expect(pending.state == .settled_reply);

            var bound_reply = try data.invocation.decode(data.invocation.Result, scratch, try namespace.store.acquiredObject(scratch, pending.state.settled_reply.reply, null));
            defer bound_reply.deinit();
            reply = (try contracts.decodeOwned(contracts.workspace.Reply, scratch, bound_reply.value.value)).value;
            break;
        }
        const observed = reply orelse return error.MissingOverflowReply;
        try std.testing.expectEqual(.observed, observed.disposition);
        const value = (try native.json.parse(scratch, observed.observation_json.bytes, .{})).value;
        const preview = switch (kind) {
            .result => value.object.get("result_preview").?,
            .failure => value.object.get("failure_preview").?,
            .port => value.object.get("port").?.object.get("preview").?,
        };
        try std.testing.expectEqualStrings("Overflow", preview.object.get("error").?.string);
        try std.testing.expect(!preview.object.get("complete").?.bool);
        if (kind == .result) {
            const materialized = try service.workspaceCommand(scratch, "overflow-materialize", parent.receipt.task, .{ .context = .{ .materialize = .{ .input = .{ .value = .{ .reference = observed.evidence.? } }, .sources = .{ .items = &.{} } } } });
            try std.testing.expectEqual(.observed, materialized.disposition);
            const materialized_json = (try native.json.parse(scratch, materialized.observation_json.bytes, .{})).value;
            try std.testing.expectEqualStrings("Overflow", materialized_json.object.get("preview").?.object.get("error").?.string);
        }

        for (0..32) |_| if (try service.pump(scratch) == .idle) break;
        const archive_path = try std.fmt.allocPrint(scratch, "{s}/overflow-{s}.par", .{ path_buffer[0..length], label });

        _ = try service.exportCheckpoint(scratch, parent.receipt.task, archive_path);
        try service.close(a);
        service_open = false;
        try namespace.close();
        namespace_open = false;
        {
            var imported_namespace = try native.Namespace.open(a, io, try std.fmt.allocPrint(scratch, "{s}/overflow-import-{s}", .{ path_buffer[0..length], label }));
            defer imported_namespace.close() catch unreachable;
            var imported = try native.tasks.Service(DelegateTypes).init(a, io, &imported_namespace, assets, &application, handlers, profile);
            defer imported.close(a) catch unreachable;
            _ = try imported.importCheckpoint(scratch, "overflow-import", archive_path);
            try std.testing.expectEqual(.idle, try imported.pump(scratch));
            try imported.validateWorkspace(scratch, parent.receipt.task);
        }
        namespace = try native.Namespace.open(a, io, path);
        namespace_open = true;
        service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
        service_open = true;
        try std.testing.expectEqual(.idle, try service.pump(scratch));
    }
}

fn nativeIdentity(ref: contracts.workspace.Ref) ![32]u8 {
    var result: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, ref.id.bytes);
    return result;
}

fn fixtureManifest(a: std.mem.Allocator, image: []const u8, identity: [32]u8, application_bytes: []const u8) ![]u8 {
    var image_digest: [32]u8 = undefined;
    var assets_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &image_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(application_bytes, &assets_digest, .{});
    const image_hex = std.fmt.bytesToHex(image_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity, .lower);
    const assets_hex = std.fmt.bytesToHex(assets_digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{
        .native_host_contract = "unit-native-contract",
        .protocol = "agent-host/2.1",
        .client_mapping = "agent-client-values/1.1",
        .state_format = "agent-native-state/13",
        .optimize = "debug",
        .program_sha256 = @as([]const u8, &image_hex),
        .program_identity = @as([]const u8, &identity_hex),
        .application_assets_sha256 = @as([]const u8, &assets_hex),
        .dependencies = .{ .world = "unit-kosmos", .boundary = "unit-horos" },
        .compiler = .{ .version = "0.17.0" },
    }, .{});
}

test "deep recursive workspace values support input admission inspection expansion and port replies" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var root_builder = source.Builder.init(a);
    defer root_builder.deinit();
    var root = try compile(a, &root_builder, try gcd(&root_builder));
    defer root.deinit();
    const admitted = try data.program_image.Admitted.decode(a, root.image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "workspace-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const assets: native.discovery.Assets = .{ .image = root.image, .application = "workspace-unit", .manifest = "{}" };
    var handlers = try native.Registry.init(a, &.{});
    defer handlers.deinit();
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "workspace-test", .authority = .{ .grants = &.{}, .principal = "test", .tenant = "test" } };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(OwnerTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "parent", .{ 25, 5 });

    var b = source.Builder.init(a);
    defer b.deinit();
    const recursive = try b.reserveSchema();
    const unit = try b.scalar(void);
    try b.defineSchema(recursive, .{ .sum = &.{ unit, recursive } });
    const entry = try b.declare(&.{recursive}, recursive, &.{}, &.{});
    try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
    const text = try native.source_records.encode(scratch, b.module(entry, unit));
    var diagnostic: native.program_construction.Diagnostic = .{};
    const built = try service.workspaceBuild(scratch, "deep-build", parent.receipt.task, text, &diagnostic);
    var artifact = try service.workspaceProgram(scratch, parent.receipt.task, built.receipt.workspace.?);
    defer artifact.deinit();
    const schema_ref = try workspaceRef(scratch, .schema, artifact.value.description.input_schema.digest);
    var text_value: std.ArrayList(u8) = .empty;
    for (0..50000) |_| try text_value.appendSlice(scratch, "{\"tag\":1,\"value\":");
    try text_value.appendSlice(scratch, "{\"tag\":0,\"value\":{}}");
    try text_value.appendNTimes(scratch, '}', 50000);
    const started = try service.workspaceCommand(scratch, "deep-start", parent.receipt.task, .{ .work = .{ .start = .{
        .program = try workspaceRef(scratch, .program, built.receipt.workspace.?),
        .input = .{ .inline_json = .{ .schema = schema_ref, .json_text = .{ .bytes = text_value.items } } },
        .policy = .{},
    } } });
    try std.testing.expectEqual(.observed, started.disposition);
    var observation = try native.json.parse(scratch, started.observation_json.bytes, .{});
    defer observation.deinit();
    try std.testing.expectEqualStrings("completed", observation.value.object.get("outcome").?.string);
    const result_ref: contracts.workspace.Ref = .{ .kind = .value, .id = .{ .bytes = observation.value.object.get("result").?.object.get("id").?.string } };
    const expanded = try service.workspaceCommand(scratch, "deep-expand", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = result_ref, .page = .{} } } });
    var page = try native.json.parse(scratch, expanded.observation_json.bytes, .{});
    defer page.deinit();
    try std.testing.expect(!page.value.object.get("complete").?.bool);
    try std.testing.expectEqualStrings(text_value.items[0..16384], page.value.object.get("text").?.string);
    const unpageable = try b.schema(.{ .array = .{ .element = unit, .length = 10_000_000_000_000_000_000 } });
    const unpageable_entry = try b.declare(&.{unit}, unpageable, &.{}, &.{});
    try b.define(unpageable_entry, try b.pure(try b.literal(.{ .schema = unpageable, .bytes = "" })));
    const unpageable_program = try service.workspaceBuild(scratch, "unpageable-build", parent.receipt.task, try native.source_records.encode(scratch, b.module(unpageable_entry, unit)), &diagnostic);
    var unpageable_artifact = try service.workspaceProgram(scratch, parent.receipt.task, unpageable_program.receipt.workspace.?);
    defer unpageable_artifact.deinit();
    const unpageable_command: contracts.workspace.Command = .{ .work = .{ .start = .{
        .program = try workspaceRef(scratch, .program, unpageable_program.receipt.workspace.?),
        .input = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, unpageable_artifact.value.description.input_schema.digest), .json_text = .{ .bytes = "{}" } } },
        .policy = .{},
    } } };
    const unpageable_start = try service.workspaceCommand(scratch, "unpageable-start", parent.receipt.task, unpageable_command);
    try std.testing.expectEqual(.observed, unpageable_start.disposition);
    const unpageable_json = (try native.json.parse(scratch, unpageable_start.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("completed", unpageable_json.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("Overflow", unpageable_json.object.get("result_preview").?.object.get("error").?.string);
    try std.testing.expect(!unpageable_json.object.get("result_preview").?.object.get("complete").?.bool);
    const unpageable_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, unpageable_json.object.get("result").?);
    const unpageable_replay = try service.workspaceCommand(scratch, "unpageable-start", parent.receipt.task, unpageable_command);
    try std.testing.expectEqual(.observed, unpageable_replay.disposition);
    try std.testing.expectEqualDeep(unpageable_start.evidence, unpageable_replay.evidence);
    const unpageable_expand = try service.workspaceCommand(scratch, "unpageable-expand", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = unpageable_ref, .page = .{} } } });
    try std.testing.expectEqual(.rejected, unpageable_expand.disposition);
    try service.validateWorkspace(scratch, parent.receipt.task);
    const enormous = try b.schema(.{ .array = .{ .element = unit, .length = 1_000_000_000 } });
    const enormous_entry = try b.declare(&.{enormous}, enormous, &.{}, &.{});
    try b.define(enormous_entry, try b.pure(try b.reference(b.parameter(enormous_entry, 0))));
    const enormous_program = try service.workspaceBuild(scratch, "enormous-build", parent.receipt.task, try native.source_records.encode(scratch, b.module(enormous_entry, unit)), &diagnostic);
    const enormous_start = try service.workspaceStart(scratch, "enormous-start", parent.receipt.task, enormous_program.receipt.workspace.?, "", .{});
    const enormous_inspect = try service.workspaceCommand(scratch, "enormous-inspect", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = try workspaceRef(scratch, .work, enormous_start.receipt.workspace.?) } } });
    const enormous_json = (try native.json.parse(scratch, enormous_inspect.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("completed", enormous_json.object.get("outcome").?.string);
    try std.testing.expect(!enormous_json.object.get("result_preview").?.object.get("complete").?.bool);
    const enormous_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, enormous_json.object.get("result").?);
    const enormous_tail = try service.workspaceCommand(scratch, "enormous-tail", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = enormous_ref, .page = .{ .offset = 2_999_999_995, .maximum = 10 } } } });
    const enormous_tail_json = (try native.json.parse(scratch, enormous_tail.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("{},{}]", enormous_tail_json.object.get("text").?.string);
    try std.testing.expect(enormous_tail_json.object.get("eof").?.bool);
    // The same compact value must remain compact across input commands,
    // alternative commands, finish inspection, and retained archive checks.
    const memory = try a.alloc(u8, 16 * 1024 * 1024);
    defer a.free(memory);
    for ([_]@FieldType(contracts.workspace.Exposure, "class"){ .input, .alternative }) |class| {
        var cb = source.Builder.init(a);
        defer cb.deinit();
        const compact_unit = try cb.scalar(void);
        const compact_array = try cb.schema(.{ .array = .{ .element = compact_unit, .length = 1_000_000_000 } });
        const operation_name = @tagName(class);
        const compact_effect = try cb.effect(.{ .identity = operation_name, .payload = compact_unit, .result = compact_array, .external = false, .control_use = .multi });
        const compact_entry = try cb.declare(&.{compact_unit}, compact_array, &.{compact_effect}, &.{});
        try cb.define(compact_entry, try cb.term(.{ .perform = .{ .effect = compact_effect, .payload = try cb.constant(void, {}) } }));
        const compact_program = try service.workspaceCommand(scratch, try std.fmt.allocPrint(scratch, "compact-build-{s}", .{operation_name}), parent.receipt.task, .{ .program = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = try native.source_records.encode(scratch, cb.module(compact_entry, compact_unit)) } },
            .source_kind = .source_records,
            .exposures = .{ .items = &.{.{ .effect = compact_effect, .class = class }} },
        } } });
        if (compact_program.program == null) std.debug.print("compact {s}: {s}\n", .{ operation_name, compact_program.observation_json.bytes });
        try std.testing.expect(compact_program.program != null);
        const compact_start = try service.workspaceStart(scratch, try std.fmt.allocPrint(scratch, "compact-start-{s}", .{operation_name}), parent.receipt.task, try nativeIdentity(compact_program.program.?), "", .{});
        for (0..if (class == .alternative) @as(usize, 2) else 1) |turn| {
            var current = try service.workspaceWork(scratch, parent.receipt.task, compact_start.receipt.workspace.?);
            defer current.deinit();
            var exposed = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, current.value.current_port.?, null));
            defer exposed.deinit();
            var budget = std.heap.FixedBufferAllocator.init(memory);
            if (turn == 0) {
                try std.testing.expectError(if (class == .alternative) error.NoBranchResult else error.InvalidPortCommand, service.workspaceInteract(budget.allocator(), try std.fmt.allocPrint(scratch, "premature-finish-{s}", .{operation_name}), parent.receipt.task, .{
                    .expected = .{ .work = try workspaceRef(scratch, .work, current.value.id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
                    .port = try workspaceRef(scratch, .port, exposed.value.id),
                    .generation = exposed.value.generation,
                    .command = .{ .finish = .{} },
                }));
                budget.reset();
            }
            _ = try service.workspaceInteract(budget.allocator(), try std.fmt.allocPrint(scratch, "compact-reply-{s}-{d}", .{ operation_name, turn }), parent.receipt.task, .{
                .expected = .{ .work = try workspaceRef(scratch, .work, current.value.id), .execution_revision = current.value.execution_revision, .control_revision = current.value.control_revision },
                .port = try workspaceRef(scratch, .port, exposed.value.id),
                .generation = exposed.value.generation,
                .command = if (turn == 0) .{ .resume_value = .{ .reference = enormous_ref } } else .{ .finish = .{} },
            });
            for (0..8) |_| {
                var next = try service.workspaceWork(scratch, parent.receipt.task, current.value.id);
                defer next.deinit();
                if (next.value.terminal() or (next.value.current_port != null and !std.meta.eql(next.value.current_port, current.value.current_port))) break;
                _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "compact-advance-{s}-{d}", .{ operation_name, next.value.execution_revision }), parent.receipt.task, next.value.id, next.value.execution_revision, next.value.control_revision, .advance);
            }
        }
        var completed = try service.workspaceWork(scratch, parent.receipt.task, compact_start.receipt.workspace.?);
        defer completed.deinit();
        try std.testing.expectEqual(.completed, completed.value.outcome_kind);
        try std.testing.expectEqualSlices(u8, "", try namespace.store.object(scratch, completed.value.result.?, null));
    }
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(assets.manifest, &manifest_digest, .{});
    const index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = assets.manifest.len });
    try service.validateWorkspaceRecords(scratch, parent.receipt.task, index.records.items);

    // Repeated selected values preserve their exact order and multiplicity,
    // while the page uses less memory than the full 32 MiB preview array.
    const selected_refs = try scratch.alloc(contracts.workspace.Ref, 2048);
    @memset(selected_refs, enormous_ref);
    var selection_budget = std.heap.FixedBufferAllocator.init(memory);
    const selected_view = try service.workspaceCommand(selection_budget.allocator(), "compact-view", parent.receipt.task, .{ .context = .{ .select = .{ .values = .{ .items = selected_refs } } } });
    if (selected_view.disposition != .observed) std.debug.print("compact view: {s}\n", .{selected_view.observation_json.bytes});
    try std.testing.expectEqual(.observed, selected_view.disposition);
    const view_ref = try workspaceRef(scratch, .view, try nativeIdentity(selected_view.selected_view.?));
    const selected_json = (try native.json.parse(scratch, selected_view.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("2048", selected_json.object.get("value_count").?.number_string);
    const selected_page = selected_json.object.get("selection").?;
    const selected_total = try native.json.numberInteger(u64, selected_page.object.get("total_bytes").?.number_string);
    try std.testing.expect(selected_total > 32 * 1024 * 1024);
    selection_budget.reset();
    const selected_tail = try service.workspaceCommand(selection_budget.allocator(), "compact-view-tail", parent.receipt.task, .{ .context = .{ .expand = .{ .reference = view_ref, .page = .{ .offset = selected_total - 1, .maximum = 10 } } } });
    const selected_tail_json = (try native.json.parse(scratch, selected_tail.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("]", selected_tail_json.object.get("selection").?.object.get("text").?.string);
    const effect = try b.effect(.{ .identity = "example/deep-value", .payload = recursive, .result = recursive, .external = false });
    const port_entry = try b.declare(&.{recursive}, recursive, &.{effect}, &.{});
    try b.define(port_entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.reference(b.parameter(port_entry, 0)) } }));
    const port_program = try service.workspaceCommand(scratch, "deep-port-build", parent.receipt.task, .{ .program = .{ .build = .{
        .source = .{ .json_text = .{ .bytes = try native.source_records.encode(scratch, b.module(port_entry, unit)) } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{.{ .effect = effect, .class = .input }} },
    } } });
    try std.testing.expect(port_program.program != null);
    const wire = try scratch.alloc(u8, 50001);
    @memset(wire, 1);
    wire[50000] = 0;
    const suspended = try service.workspaceStart(scratch, "deep-port-start", parent.receipt.task, try nativeIdentity(port_program.program.?), wire, .{});
    var work = try service.workspaceWork(scratch, parent.receipt.task, suspended.receipt.workspace.?);
    defer work.deinit();
    var port = try contracts.decodeOwned(native.workspace.Port, scratch, try namespace.store.object(scratch, work.value.current_port.?, null));
    defer port.deinit();
    _ = try service.workspaceInteract(scratch, "deep-port-reply", parent.receipt.task, .{
        .expected = .{ .work = try workspaceRef(scratch, .work, work.value.id), .execution_revision = work.value.execution_revision, .control_revision = work.value.control_revision },
        .port = try workspaceRef(scratch, .port, port.value.id),
        .generation = port.value.generation,
        .command = .{ .resume_value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, port.value.interface.argument.digest), .json_text = .{ .bytes = text_value.items } } } },
    });
    for (0..8) |_| {
        var current = try service.workspaceWork(scratch, parent.receipt.task, work.value.id);
        defer current.deinit();
        if (current.value.terminal()) {
            try std.testing.expectEqualSlices(u8, wire, try namespace.store.object(scratch, current.value.result.?, null));
            return;
        }
        _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "deep-advance-{d}", .{current.value.execution_revision}), parent.receipt.task, current.value.id, current.value.execution_revision, current.value.control_revision, .advance);
    }
    return error.DidNotComplete;
}

test "collected history rejects rehashed result substitution and false absence" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var compiled = try @import("protean").compile(a, @import("protean").system(.{ .InitialArgs = void, .Result = void, .Failure = void, .application = DelegateApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "collection-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const manifest = try fixtureManifest(a, image, admitted.identity(), "collection-unit");
    defer a.free(manifest);
    application.manifest = (try native.json.parse(application.arena.allocator(), manifest, .{})).value;
    const assets: native.discovery.Assets = .{ .image = image, .application = "collection-unit", .manifest = manifest };
    const declarations = [_]native.Declaration{ native.inbox.declaration(DelegateTypes.Message), .{ .identity = "workspace-delegation", .resource_role = "workspace", .kind = .workspace, .workspace = WaitApplication.authorize, .payload_schema = WaitApplication.schema, .resume_schema = WaitApplication.result } };
    var handlers = try native.Registry.init(a, &declarations);
    defer handlers.deinit();
    var grants: [declarations.len]native.registry.Grant = undefined;
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "collection-test", .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    for (declarations, &grants) |declaration, *grant| grant.* = .{ .identity = declaration.identity, .resource_role = declaration.resource_role, .resource_identity = try profile.resourceIdentity(a, application.image_identity) };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(DelegateTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "collect-parent", {});
    var builder = source.Builder.init(scratch);
    defer builder.deinit();
    const document = try native.source_records.encode(scratch, try gcd(&builder));
    var diagnostic: native.program_construction.Diagnostic = .{};
    const program = try service.workspaceBuild(scratch, "collect-program", parent.receipt.task, document, &diagnostic);
    const input = try contracts.encodeOwned(struct { u64, u64 }, scratch, .{ 1071, 462 });
    const started = try service.workspaceStart(scratch, "collect-start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    var work = try service.workspaceWork(scratch, parent.receipt.task, started.receipt.workspace.?);
    defer work.deinit();
    try std.testing.expectEqual(.completed, work.value.outcome_kind);
    var artifact = try service.workspaceProgram(scratch, parent.receipt.task, program.receipt.workspace.?);
    defer artifact.deinit();
    const hypothesis = try service.workspaceCommand(scratch, "collect-hypothesis", parent.receipt.task, .{ .context = .{ .materialize = .{ .input = .{ .value = .{ .inline_json = .{ .schema = try workspaceRef(scratch, .schema, artifact.value.description.result_schema.digest), .json_text = .{ .bytes = "\"999\"" } } } }, .sources = .{ .items = &.{} } } } });
    var hypothesis_json = try native.json.parse(scratch, hypothesis.observation_json.bytes, .{});
    defer hypothesis_json.deinit();
    const hypothesis_ref = try native.values.fromJson(contracts.workspace.Ref, scratch, hypothesis_json.value.object.get("value").?);
    // Resolve the actual immutable artifact reference, including its byte count.
    var hypothesis_record: ?native.workspace.Value = null;
    var query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='workspace_value'", &.{.{ .blob = &parent.receipt.task }});
    defer query.deinit();
    while (try query.step() == .row) {
        const candidate = try contracts.decodeOwned(native.workspace.Value, scratch, try query.bytes(0));
        if (std.mem.eql(u8, &candidate.value.artifact.digest, &(try nativeIdentity(hypothesis_ref)))) hypothesis_record = candidate.value;
    }
    var slow_builder = source.Builder.init(scratch);
    defer slow_builder.deinit();
    const slow_program = try service.workspaceBuild(scratch, "collect-slow-build", parent.receipt.task, try native.source_records.encode(scratch, try listLength(&slow_builder)), &diagnostic);
    const slow_input = try scratch.alloc(u8, 300 * 9 + 1);
    var writer: data.wire.Writer = .{ .output = slow_input };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, @intCast(i));
    }
    try writer.natural(0);
    const slow_start = try service.workspaceStart(scratch, "collect-slow-start", parent.receipt.task, slow_program.receipt.workspace.?, slow_input, .{});
    try expectWorkInputHistoryBound(&service, scratch, parent.receipt.task, slow_start.receipt.workspace.?, &.{hypothesis_record.?.artifact});
    try service.validateWorkspace(scratch, parent.receipt.task);
    const refs = [_]contracts.workspace.Ref{ try workspaceRef(scratch, .work, work.value.id), try workspaceRef(scratch, .work, @splat(0)), try workspaceRef(scratch, .work, slow_start.receipt.workspace.?) };
    _ = try service.message(scratch, "collect-message", parent.receipt.task, .{ .work = .{ .collect = .{ .works = .{ .items = &refs } } } });
    var observed: ?native.testing.occurrence.Occurrence = null;
    for (0..64) |_| {
        _ = try service.pump(scratch);
        var pending_query = try namespace.store.database.prepare("SELECT o.body FROM records r JOIN objects o ON o.digest=r.body WHERE r.task=? AND r.kind='workspace_reply'", &.{.{ .blob = &parent.receipt.task }});
        defer pending_query.deinit();
        if (try pending_query.step() != .row) continue;
        const saved = try contracts.decodeOwned(native.workspace.ReplyObservation, scratch, try pending_query.bytes(0));
        const pending_bytes = (try namespace.store.recordBytes(scratch, "occurrence", saved.value.id, parent.receipt.task)).?;
        observed = (try contracts.decodeOwned(native.testing.occurrence.Occurrence, scratch, pending_bytes)).value;
        break;
    }
    const original = observed orelse return error.MissingReadObservation;
    try std.testing.expect(original.state == .settled_reply);
    try service.validateWorkspace(scratch, parent.receipt.task);
    const original_evidence = (try namespace.store.recordBytes(scratch, "workspace_reply", original.id, original.task)).?;
    const acquired_bytes = try namespace.store.object(scratch, try namespace.store.objectReference(original.state.settled_reply.reply, null), null);
    const acquired = try data.invocation.decode(data.invocation.Result, scratch, acquired_bytes);
    const original_reply = try contracts.decodeOwned(contracts.workspace.Reply, scratch, acquired.value.value);
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest, &manifest_digest, .{});
    {
        // Before root consumption, preserve the successful read journal entry
        // while coherently rewriting both retained evidence and acquired reply.
        const read_index = try namespace.store.archiveIndex(scratch, original.task, .{ .digest = manifest_digest, .bytes = manifest.len });
        try namespace.store.begin();
        var evidence = try contracts.decodeOwned(native.workspace.ReplyObservation, scratch, original_evidence);
        evidence.value.evidence = .{ .rejected = .{ .stage = .operation, .code = .{ .bytes = "Denied" } } };
        const forged = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.ReplyObservation, scratch, evidence.value));
        try namespace.store.database.run("UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?", &.{ .{ .blob = &forged.digest }, .{ .blob = &original.id } });
        const failed_reply: contracts.workspace.Reply = .{ .disposition = .rejected, .observation_json = .{ .bytes = "{\"error\":\"Denied\"}" } };
        const payload = try contracts.encodeOwned(contracts.workspace.Reply, scratch, failed_reply);
        const bound = try data.invocation.encodeOwned(data.invocation.Result, scratch, .{ .request_identity = original.request, .value = payload });
        var forged_occurrence = original;
        forged_occurrence.state.settled_reply.reply = (try namespace.store.putObject(bound)).digest;
        try namespace.store.putRecord(native.testing.occurrence.Occurrence, "occurrence", original.id, original.task, forged_occurrence);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, original.task, read_index.records.items));
        namespace.store.rollback();
        try service.validateWorkspace(scratch, original.task);
    }
    {
        var slow = try service.workspaceWork(scratch, parent.receipt.task, slow_start.receipt.workspace.?);
        defer slow.deinit();
        const parked = try service.workspaceControl(scratch, "collect-kind-park", parent.receipt.task, slow.value.id, slow.value.execution_revision, slow.value.control_revision, .park);
        {
            // The response kind cannot opt an admitted work command out of its
            // proof by presenting a genuine program artifact instead.
            const archive_index = try namespace.store.archiveIndex(scratch, parent.receipt.task, .{ .digest = manifest_digest, .bytes = manifest.len });
            try namespace.store.begin();
            defer namespace.store.rollback();
            var changed_receipt = parked.receipt;
            changed_receipt.workspace_kind = .program;
            changed_receipt.workspace = program.receipt.workspace;
            changed_receipt.workspace_observation = program.receipt.workspace_observation;
            const prior_receipt_ref = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, parked.receipt));
            const receipt_ref = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, changed_receipt));
            try namespace.store.database.run("UPDATE operations SET receipt=? WHERE receipt=?", &.{ .{ .blob = &receipt_ref.digest }, .{ .blob = &prior_receipt_ref.digest } });
            var event_query = try namespace.store.database.prepare("SELECT seq,o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.revision=?", &.{ .{ .blob = &parent.receipt.task }, .{ .integer = @intCast(parked.receipt.revision) } });
            defer event_query.deinit();
            try std.testing.expect(try event_query.step() == .row);
            var event_value = try contracts.decodeOwned(native.testing.state.Event, scratch, try event_query.bytes(1));
            event_value.value.workspace_publications.items = &.{};
            event_value.value.data = .{ .bytes = try std.fmt.allocPrint(scratch, "{{\"workspace_id\":\"{s}\"}}", .{std.fmt.bytesToHex(program.receipt.workspace.?, .lower)}) };
            const event_ref = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, event_value.value));
            try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &parent.receipt.task }, .{ .integer = try event_query.integer(0) } });
            try namespace.store.putRecord(native.workspace.Work, "workspace_work", slow.value.id, parent.receipt.task, slow.value);
            try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, parent.receipt.task, archive_index.records.items));
        }
        slow.deinit();
        slow = try service.workspaceWork(scratch, parent.receipt.task, slow_start.receipt.workspace.?);
        _ = try service.workspaceControl(scratch, "collect-slow-delegate", parent.receipt.task, slow.value.id, slow.value.execution_revision, slow.value.control_revision, .{ .delegate = .{ .stop = .terminal, .continuation = .owner_scheduled } });
        for (0..4) |_| _ = try service.pump(scratch);
    }
    for (0..1024) |step| {
        var slow = try service.workspaceWork(scratch, parent.receipt.task, slow_start.receipt.workspace.?);
        defer slow.deinit();
        if (slow.value.terminal()) break;
        _ = try service.workspaceControl(scratch, try std.fmt.allocPrint(scratch, "collect-slow-{d}", .{step}), parent.receipt.task, slow.value.id, slow.value.execution_revision, slow.value.control_revision, .advance);
    }
    var future = try service.workspaceWork(scratch, parent.receipt.task, slow_start.receipt.workspace.?);
    defer future.deinit();
    try std.testing.expectEqual(.completed, future.value.outcome_kind);
    const future_reply = try service.workspaceCommand(scratch, "collect-future", parent.receipt.task, .{ .work = .{ .inspect = .{ .work = refs[2] } } });
    try service.validateWorkspace(scratch, parent.receipt.task);
    const index = try namespace.store.archiveIndex(scratch, original.task, .{ .digest = manifest_digest, .bytes = manifest.len });
    // Display data and retained publication facts must name the same work.
    // Rehashing a swapped/erased display ID cannot alter historical scope.
    for ([_]native.testing.state.EventType{ .workspace, .workspace_progress }) |kind| {
        try namespace.store.begin();
        var event_query = try namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? ORDER BY e.seq", &.{.{ .blob = &original.task }});
        var changed = false;
        while (try event_query.step() == .row) {
            var event_value = try contracts.decodeOwned(native.testing.state.Event, scratch, try event_query.bytes(0));
            if (event_value.value.kind != kind or event_value.value.workspace_publications.items.len == 0) continue;
            event_value.value.data.bytes = "{\"workspace_id\":\"0000000000000000000000000000000000000000000000000000000000000000\"}";
            const rewritten = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, event_value.value));
            try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &rewritten.digest }, .{ .blob = &original.task }, .{ .integer = @intCast(event_value.value.seq) } });
            changed = true;
            break;
        }
        event_query.deinit();
        try std.testing.expect(changed);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, original.task, index.records.items));
        namespace.store.rollback();
    }
    for (0..9) |variant| {
        try namespace.store.begin();
        var evidence = try contracts.decodeOwned(native.workspace.ReplyObservation, scratch, original_evidence);
        const snapshots = try scratch.dupe(?native.workspace.WorkObservation, evidence.value.evidence.read.works.works.items);
        evidence.value.evidence.read.works.works.items = snapshots;
        var reply_json = try native.json.parse(scratch, original_reply.value.observation_json.bytes, .{});
        if (variant >= 5) {
            const historical = &snapshots[2].?.work;
            switch (variant) {
                5, 8 => historical.policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
                6 => historical.schedule = .queued,
                7 => historical.blocker = .incompatible_profile,
                else => unreachable,
            }
            if (variant == 6) try native.json.put(scratch, &reply_json.value.array.items[2], "schedule", native.json.string("queued"));
            if (variant == 7) try native.json.put(scratch, &reply_json.value.array.items[2], "blocker", native.json.string("incompatible_profile"));
            var event_query = try namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &original.task }, .{ .integer = @intCast(historical.event_watermark) } });
            defer event_query.deinit();
            try std.testing.expect(try event_query.step() == .row);
            var event_value = try contracts.decodeOwned(native.testing.state.Event, scratch, try event_query.bytes(0));
            const publications = try scratch.dupe(native.testing.state.WorkPublication, event_value.value.workspace_publications.items);
            event_value.value.workspace_publications.items = publications;
            for (publications) |*item| {
                if (std.meta.eql(item.work, historical.id)) {
                    item.control = native.workspace.ControlObservation.from(snapshots[2].?);
                    if (variant == 8) {
                        var declared = try contracts.decodeOwned(native.workspace.PublicationCommand, scratch, try namespace.store.object(scratch, event_value.value.workspace_command.?, null));
                        declared.value.start.policy = historical.policy;
                        event_value.value.workspace_command = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.PublicationCommand, scratch, declared.value));
                    }
                    std.crypto.hash.sha2.Sha256.hash(try contracts.encodeOwned(native.workspace.WorkObservation, scratch, snapshots[2].?), &item.observation, .{});
                }
            }
            const rewritten = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, event_value.value));
            try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &rewritten.digest }, .{ .blob = &original.task }, .{ .integer = @intCast(historical.event_watermark) } });
        } else if (variant >= 3) {
            const original_watermark = snapshots[2].?.work.event_watermark;
            try std.testing.expect(snapshots[2].?.work.outcome_kind == .yielded);
            snapshots[2].?.work = future.value;
            snapshots[2].?.work.event_watermark = original_watermark;
            snapshots[2].?.occurrence = null;
            var future_json = try native.json.parse(scratch, future_reply.observation_json.bytes, .{});
            try native.json.put(scratch, &future_json.value, "event_watermark", try native.json.number(scratch, evidence.value.evidence.read.works.event_watermark));
            reply_json.value.array.items[2] = future_json.value;
            if (variant == 4) {
                // Updating the event digest too must not hide a future revision
                // before its actual publication sequence.
                var event_query = try namespace.store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.seq=?", &.{ .{ .blob = &original.task }, .{ .integer = @intCast(original_watermark) } });
                defer event_query.deinit();
                try std.testing.expect(try event_query.step() == .row);
                var event_value = try contracts.decodeOwned(native.testing.state.Event, scratch, try event_query.bytes(0));
                const publications = try scratch.dupe(native.testing.state.WorkPublication, event_value.value.workspace_publications.items);
                event_value.value.workspace_publications.items = publications;
                for (publications) |*item| {
                    if (!std.meta.eql(item.work, future.value.id)) continue;
                    item.execution_revision = future.value.execution_revision;
                    item.control_revision = future.value.control_revision;
                    std.crypto.hash.sha2.Sha256.hash(try contracts.encodeOwned(native.workspace.WorkObservation, scratch, snapshots[2].?), &item.observation, .{});
                }
                const rewritten = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Event, scratch, event_value.value));
                try namespace.store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &rewritten.digest }, .{ .blob = &original.task }, .{ .integer = @intCast(original_watermark) } });
            }
        } else if (variant == 0) {
            snapshots[0].?.work.result_value = hypothesis_record.?.artifact;
            try native.json.put(scratch, &reply_json.value.array.items[0], "result", try native.values.toJson(contracts.workspace.Ref, scratch, hypothesis_ref));
        } else {
            snapshots[0] = null;
            if (variant == 2) evidence.value.evidence.read.works.event_watermark = 0;
            var missing = native.json.object();
            try native.json.put(scratch, &missing, "work", try native.values.toJson(contracts.workspace.Ref, scratch, refs[0]));
            try native.json.put(scratch, &missing, "outcome", native.json.string("unavailable"));
            reply_json.value.array.items[0] = missing;
        }
        const forged_evidence = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.ReplyObservation, scratch, evidence.value));
        // Simulate an archive attacker: rewrite both evidence and acquired reply
        // with correct content hashes, without changing the genuine work.
        try namespace.store.database.run("UPDATE records SET body=? WHERE kind='workspace_reply' AND id=?", &.{ .{ .blob = &forged_evidence.digest }, .{ .blob = &original.id } });
        var forged_reply = original_reply.value;
        forged_reply.observation_json.bytes = try native.json.canonical(scratch, reply_json.value);
        const payload = try contracts.encodeOwned(contracts.workspace.Reply, scratch, forged_reply);
        const bound = try data.invocation.encodeOwned(data.invocation.Result, scratch, .{ .request_identity = original.request, .value = payload });
        const current_occurrence = (try namespace.store.recordBytes(scratch, "occurrence", original.id, original.task)).?;
        var forged_occurrence = (try contracts.decodeOwned(native.testing.occurrence.Occurrence, scratch, current_occurrence)).value;
        const forged_digest = (try namespace.store.putObject(bound)).digest;
        switch (forged_occurrence.state) {
            .settled_reply => |*reply| reply.reply = forged_digest,
            .admitted => |*reply| reply.reply.reply = forged_digest,
            else => return error.UnexpectedReadState,
        }
        try namespace.store.putRecord(native.testing.occurrence.Occurrence, "occurrence", original.id, original.task, forged_occurrence);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, original.task, index.records.items));
        namespace.store.rollback();
    }
    // A direct native operation receipt is replayable even without a root
    // workspace_reply record; its historical snapshot needs the same checks.
    for (0..3) |variant| {
        try namespace.store.begin();
        var receipt_query = try namespace.store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &parent.receipt.task }});
        var changed = false;
        while (try receipt_query.step() == .row) {
            var saved = try contracts.decodeOwned(native.testing.state.Receipt, scratch, try receipt_query.bytes(1));
            if (!std.meta.eql(saved.value.id, slow_start.receipt.id)) continue;
            var historical = try contracts.decodeOwned(native.workspace.WorkObservation, scratch, try namespace.store.object(scratch, saved.value.workspace_observation.?, null));
            switch (variant) {
                0 => historical.value.work.schedule = .queued,
                1 => historical.value = (try contracts.decodeOwned(native.workspace.WorkObservation, scratch, try namespace.store.object(scratch, started.receipt.workspace_observation.?, null))).value,
                2 => historical.value = .{ .work = future.value, .occurrence = null },
                else => unreachable,
            }
            saved.value.workspace_observation = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.WorkObservation, scratch, historical.value));
            const rewritten = try namespace.store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, scratch, saved.value));
            try namespace.store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &rewritten.digest }, .{ .text = try receipt_query.bytes(0) } });
            changed = true;
            break;
        }
        receipt_query.deinit();
        try std.testing.expect(changed);
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, original.task, index.records.items));
        namespace.store.rollback();
    }
    // Later publications do not rewrite the earlier collection or invalidate
    // its genuinely missing member.
    _ = try service.workspaceStart(scratch, "collect-later-start", parent.receipt.task, program.receipt.workspace.?, input, .{});
    try service.validateWorkspace(scratch, parent.receipt.task);
    try std.testing.expectEqualStrings(original_evidence, (try namespace.store.recordBytes(scratch, "workspace_reply", original.id, original.task)).?);
    const judgment = try service.workspaceCommand(scratch, "sourced-judgment", parent.receipt.task, .{ .context = .{ .materialize = .{
        .input = .{ .value = .{ .reference = hypothesis_ref } },
        .sources = .{ .items = &.{hypothesis_ref} },
    } } });
    const judgment_json = (try native.json.parse(scratch, judgment.observation_json.bytes, .{})).value;
    try std.testing.expectEqualStrings("judgment", judgment_json.object.get("derivation").?.object.get("kind").?.string);
    try service.validateWorkspace(scratch, parent.receipt.task);
    const before_forgery = try namespace.store.archiveIndex(scratch, original.task, .{ .digest = manifest_digest, .bytes = manifest.len });
    for (0..2) |variant| {
        try namespace.store.begin();
        var forged = hypothesis_record.?;
        if (variant == 0) {
            forged.derivation.kind = .judgment;
        } else {
            forged.derivation.sources.items = &.{hypothesis_record.?.artifact};
        }
        forged.description.provenance = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.Derivation, scratch, forged.derivation));
        forged.artifact = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.ValueArtifact, scratch, forged.description));
        forged.id = try native.workspace.custodyId(scratch, forged.task, forged.artifact.digest);
        try namespace.store.createRecord(native.workspace.Value, "workspace_value", forged.id, forged.task, forged);
        const records = try scratch.alloc(native.testing.state.ArchiveRecord, before_forgery.records.items.len + 1);
        @memcpy(records[0..before_forgery.records.items.len], before_forgery.records.items);
        records[records.len - 1] = .{ .kind = .workspace_value, .id = forged.id, .body = try namespace.store.putObject(try contracts.encodeOwned(native.workspace.Value, scratch, forged)) };
        try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecords(scratch, original.task, records));
        const inspected = try service.workspaceCommand(scratch, "forged-derivation", original.task, .{ .context = .{ .expand = .{ .reference = try workspaceRef(scratch, .value, forged.artifact.digest), .page = .{} } } });
        try std.testing.expectEqual(.rejected, inspected.disposition);
        namespace.store.rollback();
    }
}

const WorkspaceCleanupApplication = struct {
    pub fn emit(c: @import("protean").Context) !source.Module {
        const author = horos.authoring.interop;
        const input = try author.schemaId(c.author, try c.schema(ContextTypes.Input));
        const output = try author.schemaId(c.author, try c.schema(ContextTypes.Output));
        const effect = try author.operationId(c.author, try c.external("workspace-context", try c.schema(ContextTypes.Input), try c.schema(ContextTypes.Output), .read));
        const b = c.builder;
        const unit = try b.scalar(void);
        const info = try horos.library.cleanup.exitInfo(b, unit);
        const body = try b.declare(&.{}, output, &.{}, &.{});
        try b.define(body, try b.term(.{ .yield_then = try b.pure(try b.literal(.{ .schema = output, .bytes = try contracts.encodeOwned(ContextTypes.Output, b.allocator(), .{ .disposition = .observed, .observation_json = .{ .bytes = "{}" } }) })) }));
        const cleanup = try b.declare(&.{info}, unit, &.{effect}, &.{});
        const request = try b.term(.{ .perform = .{ .effect = effect, .payload = try b.literal(.{ .schema = input, .bytes = try contracts.encodeOwned(ContextTypes.Input, b.allocator(), .{ .program = .{ .describe = .{ .section = .values, .page = .{} } } }) }) } });
        try b.define(cleanup, try b.bind(try b.variable(output), request, try b.pure(try b.constant(void, {}))));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = output } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = &.{effect} } } });
        const entry = try b.declare(&.{input}, output, &.{effect}, &.{});
        try b.define(entry, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(cleanup, cleanup_type) } }));
        return b.module(entry, unit);
    }
};

test "WORK-14 workspace reads settle inside root cancellation cleanup" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const protean = @import("protean");
    var compiled = try protean.compile(a, protean.system(.{ .InitialArgs = ContextTypes.Input, .Result = ContextTypes.Output, .Failure = void, .application = WorkspaceCleanupApplication }));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    var application: native.discovery.Application = .{ .arena = .init(a), .metadata = .null, .manifest = .null, .manifest_id = "context-unit", .image_identity = admitted.identity() };
    defer application.deinit();
    const assets: native.discovery.Assets = .{ .image = image, .application = "context-unit", .manifest = "{}" };
    var handlers = try native.Registry.init(a, &.{.{ .identity = "workspace-context", .resource_role = "workspace", .kind = .workspace, .workspace = ContextApplication.authorize, .payload_schema = ContextApplication.payloadSchema, .resume_schema = ContextApplication.resultSchema }});
    defer handlers.deinit();
    const text = "ordinary rows agree\nrare exception: missing invoice\n";
    var file_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &file_digest, .{});
    const snapshot = try contracts.encodeOwned(contracts.RepositorySnapshot, a, .{ .version = 2, .excluded_entries = 3, .files = .{ .items = &.{.{ .path = .{ .bytes = "evidence.txt" }, .sha256 = file_digest, .contents = .{ .bytes = text } }} } });
    defer a.free(snapshot);
    var algorithm = source.Builder.init(a);
    defer algorithm.deinit();
    var gcd_program = try horos.source.lower(a, try @import("workspace_sources.zig").gcd(&algorithm));
    defer gcd_program.deinit();
    const component: data.component.Object = .{ .program = gcd_program.program, .exports = &.{.{ .name = "apply", .reference = .{ .kind = .function, .id = gcd_program.program.roots.entry } }}, .borrows = &.{.{ .function = gcd_program.program.roots.entry }} };
    const component_bytes = try a.alloc(u8, try data.component.encodedLength(component));
    defer a.free(component_bytes);
    _ = try data.component.encode(a, component, component_bytes);
    const catalog = try contracts.encodeOwned(contracts.tool_construction.Catalog, a, .{ .items = &.{.{ .id = .{ .bytes = "gcd" }, .object = .{ .bytes = component_bytes } }} });
    defer a.free(catalog);
    var grants = [_]native.registry.Grant{.{ .identity = "workspace-context", .resource_role = "workspace", .resource_identity = undefined }};
    const profile: native.tasks.Profile = .{ .id = "offline", .runtime_identity = @splat(42), .bytes = "context-test", .resources = &.{ snapshot, catalog }, .authority = .{ .grants = &grants, .principal = "test", .tenant = "test" } };
    grants[0].resource_identity = try profile.resourceIdentity(a, application.image_identity);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer namespace.close() catch unreachable;
    var service = try native.tasks.Service(ContextTypes).init(a, io, &namespace, assets, &application, handlers, profile);
    defer service.close(a) catch unreachable;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parent = try service.submit(scratch, "parent", .{ .program = .{ .describe = .{ .section = .values, .page = .{} } } });
    _ = try service.pump(scratch);
    var paused = try service.task(scratch, parent.receipt.task);
    defer paused.deinit();
    try std.testing.expectEqual(.yielded, paused.value.outcome_kind);
    _ = try service.requestCancel(scratch, "cancel", parent.receipt.task, "cancel body");
    for (0..8) |_| _ = try service.pump(scratch);
    var done = try service.task(scratch, parent.receipt.task);
    defer done.deinit();
    try std.testing.expectEqual(.cancelled, done.value.outcome_kind);
}

/// Fail exactly one allocation; persistent failure can hide an erroneous
/// fallback because encoding that fallback also needs memory.
const OneShotAllocator = struct {
    backing: std.mem.Allocator,
    fail_at: usize = std.math.maxInt(usize),
    calls: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ordinal = self.calls;
        self.calls += 1;
        if (ordinal == self.fail_at) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

test "delegated model interpretation preserves transient allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prepared = try contracts.encodeOwned(native.workspace_instrument.Prepared, a, .{
        .schema = .{ .bytes = try native.values.schemaBytes(u64, a) },
        .body = .{ .bytes = "" },
        .model = .{ .profile_id = .{ .bytes = "fixture" }, .profile_digest = @splat(7), .settings = .{ .endpoint = .{ .bytes = "https://localhost/v1/responses" }, .audience = .{ .bytes = "fixture" }, .model = .{ .bytes = "fixture" }, .effort = .{ .bytes = "medium" }, .max_output_tokens = null, .request_bytes = null, .response_bytes = null, .timeout_ms = null }, .reasoning_mode = .{ .bytes = "standard" }, .reasoning_context = .{ .bytes = "auto" } },
    });
    const reader = struct {
        fn read(_: *anyopaque, _: std.mem.Allocator, _: native.registry.ObjectReference, _: usize) ![]u8 {
            return error.UnexpectedRead;
        }
    };
    var marker: u8 = 0;
    var context: native.registry.ProjectionContext = .{ .allocator = a, .task = @splat(0), .tenant = "fixture", .profile = "fixture", .objects = .validating(&marker, reader.read) };
    const adapter = native.workspace_instrument.declaration(.model).capture.?;
    for ([_][]const u8{
        "{\"json_value\":\"\\\"42\\\"\"}",
        "{\"json_\\u0076alue\":\"\\\"42\\\"\"}",
        "{\"json_value\":\"{\"}",
        "{\"json_value\":\"true\"}",
        "{}",
    }, 0..) |arguments, case| {
        const body = try std.json.Stringify.valueAlloc(a, .{ .status = "completed", .@"error" = @as(?u8, null), .output = .{.{ .type = "function_call", .status = "completed", .call_id = "fixture", .name = "answer", .arguments = arguments }} }, .{});
        const raw = try contracts.encodeOwned(native.responses.Raw, a, .{ .status = 200, .identity_encoding = true, .request_id = null, .body = .{ .bytes = body } });
        var counted: OneShotAllocator = .{ .backing = a };
        context.allocator = counted.allocator();
        const baseline = try adapter.interpret(context, "", prepared, raw);
        var decoded = try contracts.decodeOwned(native.workspace_instrument.Output, a, baseline.reply);
        defer decoded.deinit();
        try std.testing.expectEqual(case < 2, decoded.value == .answer);
        if (decoded.value == .answer) try std.testing.expectEqualStrings(try contracts.encodeOwned(u64, a, 42), decoded.value.answer.bytes);
        for (0..counted.calls) |ordinal| {
            var attempt = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer attempt.deinit();
            var fault: OneShotAllocator = .{ .backing = attempt.allocator(), .fail_at = ordinal };
            context.allocator = fault.allocator();
            const actual = adapter.interpret(context, "", prepared, raw) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            try std.testing.expectEqualStrings(baseline.reply, actual.reply);
        }
    }
}
