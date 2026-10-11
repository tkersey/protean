const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const source = horos.source;
const data = horos.data;
const a = std.testing.allocator;
const Answer = union(enum(u32)) { contribute: struct { value: u64 } = 1 };
pub const P = protean.model_invocation.Profile(Answer, .{
    .{ .name = "contribute", .description = "Supply the requested contribution." },
}, .{
    .model_id_bytes = 32,
    .temperature_bytes = 8,
    .maximum_messages = 4,
    .message_bytes = 256,
    .maximum_output_items = 4,
    .call_id_bytes = 32,
    .arguments_json_bytes = 128,
    .result_text_bytes = 128,
    .provider_response_bytes = 4096,
});
pub const Input = struct { request: P.Request, offered: [1]bool };

fn producer(allocator: std.mem.Allocator, direct: bool) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const request = try protean.contracts.schema(P.Request, &b);
    const offered = try protean.contracts.schema([1]bool, &b);
    const result = try protean.contracts.schema(P.Interpretation, &b);
    const effect = try P.declare(&b);
    const helper = try b.declare(&.{ request, offered }, result, &.{effect}, &.{});
    const entry = try b.declare(&.{ request, offered }, result, &.{effect}, &.{});
    const call = try b.term(.{ .call = .{ .function = helper, .arguments = &.{
        try b.reference(b.parameter(entry, 0)), try b.reference(b.parameter(entry, 1)),
    } } });
    const answer = try b.variable(result);
    var body = try b.bind(answer, call, try b.pure(try b.reference(answer)));
    if (direct) {
        const response = try b.variable(try protean.contracts.schema(P.Result, &b));
        body = try b.bind(response, try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.reference(b.parameter(entry, 0)),
        } }), body);
    }
    try b.define(entry, body);
    var object = try source.component.compile(allocator, b.module(entry, unit), .{
        .borrows = &.{.{ .function = helper }},
        .imports = &.{
            .{ .name = "model", .reference = .{ .kind = .effect, .id = effect } },
            .{ .name = "respond", .reference = .{ .kind = .function, .id = helper } },
        },
        .exports = &.{.{ .name = "contribute", .reference = .{ .kind = .function, .id = entry } }},
    });
    defer object.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(object.object));
    errdefer allocator.free(bytes);
    _ = try object.encode(allocator, bytes);
    return bytes;
}

const Application = struct {
    var bytes: []const u8 = &.{};
    var assessment = false;
    var allow_model = true;
    var completion = false;
    var wrong_result = false;
    var mutate_object = false;
    pub fn emit(c: protean.Context) !source.Module {
        const b = c.builder;
        const unit = try b.scalar(void);
        const request = try c.schema(P.Request);
        const offered = try c.schema([1]bool);
        const result = try c.schema(P.Interpretation);
        const helper = try protean.responders.defineModel(P, c, try c.literal(void, {}), false);
        const model = try P.declare(b);
        const bound = if (completion) try completionHelper(c, request, offered, result) else if (wrong_result)
            try wrongHelper(c, request, offered)
        else
            helper;
        const participant = try protean.participant.declare(c, .{
            .instance = "producer",
            .object = bytes,
            .entry = "contribute",
            .parameters = &.{ request, offered },
            .result = result,
            .residual = &.{model},
            .effects = &.{.{ .symbol = "model", .effect = model }},
            .functions = &.{.{ .symbol = "respond", .function = bound }},
        });
        if (mutate_object) @memset(@constCast(bytes), 0xff);
        if (assessment) try c.registry.speculate(participant, if (allow_model) &.{model} else &.{});
        const entry = try b.declare(&.{try c.schema(Input)}, result, &.{model}, &.{});
        const input = try b.reference(b.parameter(entry, 0));
        try b.define(entry, try b.term(.{ .call = .{ .function = participant, .arguments = &.{
            try b.primitive(request, .field, &.{input}, 0),
            try b.primitive(offered, .field, &.{input}, 1),
        } } }));
        return b.module(entry, unit);
    }
};

fn wrongHelper(c: protean.Context, request: source.Id, offered: source.Id) !source.Id {
    const b = c.builder;
    const helper = try b.declare(&.{ request, offered }, try b.scalar(bool), &.{}, &.{});
    try b.define(helper, try b.pure(try b.constant(bool, true)));
    return helper;
}

fn completionHelper(c: protean.Context, request: source.Id, offered: source.Id, result: source.Id) !source.Id {
    const b = c.builder;
    const write = try c.external("fixture/target-write", try b.scalar(void), result, .write);
    const helper = try b.declare(&.{ request, offered }, result, &.{write}, &.{});
    const operation = try b.term(.{ .perform = .{
        .effect = write,
        .payload = try c.literal(void, {}),
    } });
    // A trusted real completion site that would write if invoked. Assessment
    // must reject this binding even when ordinary source admission permits it.
    try c.registry.protectSite(helper, operation, write);
    try b.define(helper, operation);
    return helper;
}
const System = protean.system(.{
    .InitialArgs = Input,
    .Result = P.Interpretation,
    .Failure = void,
    .application = Application,
});

test "compiled participant final link rejects an invalid optimization profile" {
    Application.bytes = try producer(a, false);
    defer a.free(Application.bytes);
    try std.testing.expectError(error.InvalidOptimizationProfile, protean.compileObserved(a, System, .{ .horos_options = .{ .profile = .{ .record = .{
        .version = 0,
        .image_identity = @splat(0),
        .block_counts = &.{},
        .total = 0,
    } } } }));
}

test "compiled participant uses the actual checked model responder through normal compilation" {
    const bytes = try producer(a, false);
    defer a.free(bytes);
    Application.bytes = bytes;
    var compiled = try protean.compile(a, System);
    defer compiled.deinit();
    try std.testing.expectEqual(1, compiled.program.effects.len);
    try std.testing.expectEqualStrings("agent.model.invoke.v3", compiled.program.effects[0].identity);
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var decoded = try data.program_image.decode(a, image);
    defer decoded.deinit();
}

test "compiled assessment permits its model policy but rejects missing allowance" {
    const bytes = try producer(a, false);
    defer a.free(bytes);
    Application.bytes = bytes;
    Application.assessment = true;
    defer Application.assessment = false;
    var compiled = try protean.compile(a, System);
    defer compiled.deinit();
    Application.allow_model = false;
    defer Application.allow_model = true;
    try std.testing.expectError(error.SpeculativeEffect, protean.compile(a, System));
}

test "compiled participant cannot directly emit a protected model operation" {
    const bytes = try producer(a, true);
    defer a.free(bytes);
    Application.bytes = bytes;
    try std.testing.expectError(error.ProtectedEffectBypass, protean.compile(a, System));
}

test "compiled assessment cannot acquire target writing through a helper substitution" {
    const bytes = try producer(a, false);
    defer a.free(bytes);
    Application.bytes = bytes;
    Application.assessment = true;
    defer Application.assessment = false;
    Application.completion = true;
    defer Application.completion = false;
    try std.testing.expectError(error.SpeculativeEffect, protean.compile(a, System));
}

test "participant binding checks the actual helper result at the source-free linker" {
    const bytes = try producer(a, false);
    defer a.free(bytes);
    Application.bytes = bytes;
    Application.wrong_result = true;
    defer Application.wrong_result = false;
    try std.testing.expectError(error.IncompatibleInterface, protean.compile(a, System));
}

test "participant admission owns the exact component bytes before caller mutation" {
    const bytes = try producer(a, false);
    defer a.free(bytes);
    Application.bytes = bytes;
    Application.mutate_object = true;
    defer Application.mutate_object = false;
    var compiled = try protean.compile(a, System);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u8, 0xff), bytes[0]);
    try std.testing.expectEqualStrings("agent.model.invoke.v3", compiled.program.effects[0].identity);
}

fn incomingOwnerType(b: *source.Builder, wrapped: bool) !struct { effect: source.Id, owner: source.Id, input: source.Id } {
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "assessment/incoming-owner", .payload = unit, .result = unit, .external = false });
    const owner = try b.schema(.{ .internal = .{ .resumption = .{ .effect = effect, .input = unit, .answer = unit, .handled = &.{effect}, .mode = .deep, .use = .linear, .obligations = true } } });
    return .{ .effect = effect, .owner = owner, .input = if (wrapped) try b.schema(.{ .product = &.{owner} }) else owner };
}
fn incomingOwner(allocator: std.mem.Allocator, wrapped: bool) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const t = try incomingOwnerType(&b, wrapped);
    const entry = try b.declare(&.{t.input}, try b.scalar(void), &.{}, &.{});
    const value = try b.reference(b.parameter(entry, 0));
    const owner = try b.variable(t.owner);
    const dispose = try b.term(.{ .dispose = if (wrapped) try b.reference(owner) else value });
    try b.define(entry, if (wrapped) try b.term(.{ .unpack_product = .{ .value = value, .variables = &.{owner}, .body = dispose } }) else dispose);
    var compiled = try source.component.compile(allocator, b.module(entry, try b.scalar(void)), .{
        .imports = &.{.{ .name = "demand", .reference = .{ .kind = .effect, .id = t.effect } }},
        .exports = &.{.{ .name = "dispose", .reference = .{ .kind = .function, .id = entry } }},
    });
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}
const IncomingOwner = struct {
    var object: []const u8 = &.{};
    var wrapped = false;
    var assessment = true;
    pub fn emit(c: protean.Context) !source.Module {
        const b = c.builder;
        const t = try incomingOwnerType(b, wrapped);
        try c.registry.classify(t.effect, .internal);
        const unit = try b.scalar(void);
        const imported = try protean.participant.declare(c, .{ .instance = "incoming", .object = object, .entry = "dispose", .parameters = &.{t.input}, .result = unit, .effects = &.{.{ .symbol = "demand", .effect = t.effect }} });
        if (assessment) try c.registry.speculate(imported, &.{});
        const entry = try b.declare(&.{unit}, unit, &.{}, &.{});
        try b.define(entry, try b.pure(try b.constant(void, {})));
        return b.module(entry, unit);
    }
};
test "compiled assessment rejects incoming cleanup owners directly and through aggregates" {
    const OwnerSystem = protean.system(.{ .InitialArgs = void, .Result = void, .Failure = void, .application = IncomingOwner });
    for ([_]bool{ false, true }) |wrapped| {
        const bytes = try incomingOwner(a, wrapped);
        defer a.free(bytes);
        IncomingOwner.object = bytes;
        IncomingOwner.wrapped = wrapped;
        IncomingOwner.assessment = false;
        var valid = try protean.compile(a, OwnerSystem);
        valid.deinit();
        IncomingOwner.assessment = true;
        try std.testing.expectError(error.SpeculativeCapture, protean.compile(a, OwnerSystem));
    }
}

fn inspectIncomingAllocation(allocator: std.mem.Allocator, object: data.component.Object) !void {
    var registry = protean.admission.Registry.init(allocator);
    defer registry.deinit();
    const item: protean.admission.CompiledImport = .{ .function = 0, .instance = "incoming", .object = &.{}, .entry = "dispose", .effects = &.{}, .participant = true };
    protean.participant.inspect(allocator, object, item, &registry, &.{}) catch |err| {
        if (err == error.SpeculativeCapture) return;
        return err;
    };
    return error.ExpectedRejection;
}
test "assessment interface graph inspection releases partial allocations" {
    const bytes = try incomingOwner(a, true);
    defer a.free(bytes);
    var decoded = try data.component.decode(a, bytes);
    defer decoded.deinit();
    try std.testing.checkAllAllocationFailures(a, inspectIncomingAllocation, .{decoded.object});
}
