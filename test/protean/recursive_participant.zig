//! Compiled participants over suspended task-valued hyperfunction endpoints.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const source = horos.source;
const a = horos.authoring;
const hyper = horos.library.hyper;
const generator = horos.library.generator;
const data = horos.data;
const native = data.schema.native;
const fixture = @import("participant.zig");
const P = fixture.P;
const Input = fixture.Input;
const State = struct { input: Input, successor: bool };
const Empty = native.Fields(&.{}, &.{});
const Integer = a.Shape(u64);
const Task = a.Internal(.{ .callable = a.Signature(Empty, Integer) });
const Sample = a.Function(a.Signature(native.Fields(&.{"input"}, &.{a.Shape(Input)}), Integer));
const Endpoint = hyper.Hyper(Task, Task);
const Maker = a.Function(a.Signature(native.Fields(&.{"state"}, &.{a.Shape(State)}), Endpoint));
const Model = a.Operation(a.OperationSignature(
    a.Shape(P.AdaptiveRequest),
    a.Shape(P.AdaptiveResult),
    Empty,
));
const Read = a.Operation(a.OperationSignature(Integer, Integer, Empty));
const Types = struct {
    input: *const a.Schema(a.Shape(Input)),
    state: *const a.Schema(a.Shape(State)),
    integer: *const a.Schema(Integer),
    task: *const a.Schema(Task),
    pair: *const hyper.Pair(Task, Task),
    model: *const Model,
    read: *const Read,
    sample: *const Sample,
};

fn types(c: *a.Context) !Types {
    const input = try c.schema(Input);
    const state = try c.schema(State);
    const integer = try c.schema(u64);
    const model = try a.interop.externalOperation(
        c,
        try P.declare(a.interop.builder(c)),
        try c.schema(P.AdaptiveRequest),
        try c.schema(P.AdaptiveResult),
    );
    const read = try c.external("fixture.recursive.reference-bytes", integer, integer);
    const task = try c.declareSchema(.callable, Task);
    const state_delay = try hyper.delayed(c, state, .{ .captures = .{state} });
    const pair = try hyper.pair(c, task.schema(), task.schema(), .{
        .captures = .{ state, integer, state_delay },
    });
    try c.defineCallable(task, .{}, integer, .{ model, read }, .{
        .use = .reusable,
        .captures = .{ state, pair.peerForward(), pair.peerBackward() },
    });
    return .{
        .input = input,
        .state = state,
        .integer = integer,
        .task = task.schema(),
        .pair = pair,
        .model = model,
        .read = read,
        .sample = try c.function("sample", .{ .input = input }, integer, .{model}),
    };
}

fn add(
    body: anytype,
    left: *const a.Value(Integer),
    right: *const a.Value(Integer),
) a.Error!*const a.Value(Integer) {
    const c = try body.context();
    return body.checkedAdd(left, right, try c.literalFailure(void, {}));
}

const Step = struct {
    types: Types,
    consumer: bool,
    repeat: bool,

    pub fn emit(
        self: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(Task)) {
        const c = try body.context();
        const t = self.types;
        const task = try c.functionFor("recursive task", t.task);
        const task_body = try body.closureBody(task);
        const need = try hyper.demand.family(c, "fixture.recursive.need", t.state, t.integer);
        const interpreted = try hyper.demand.interpret(task_body, query, need, t.integer, .{
            .captures = .{ t.state, t.integer, t.pair.peerForward(), t.pair.peerBackward() },
            .residual = .{ t.model, t.read },
        });
        const inside = try c.functionFor("recursive work", interpreted.body());
        const work = try task_body.closureBody(inside);
        const capability = try work.parameter("capability");
        const result = if (self.consumer) blk: {
            const direct = try work.branch();
            const nested = try work.branch();
            break :blk try work.conditional(
                try work.field(query.state(), "successor"),
                try direct.ret(try direct.perform(t.read, try direct.constant(u64, 0))),
                try nested.ret(try self.contribution(nested, query, need, capability)),
            );
        } else try self.contribution(work, query, need, capability);
        try c.define(inside, try work.ret(result));
        try c.define(task, try task_body.ret(try hyper.demand.handle(
            task_body,
            interpreted,
            try task_body.lambda(inside, interpreted.body()),
        )));
        const description = try c.functionFor("task description", query.types().answerForward());
        const description_body = try body.closureBody(description);
        try c.define(description, try description_body.ret(
            try description_body.lambda(task, t.task),
        ));
        return body.ret(try body.lambda(description, query.types().answerForward()));
    }

    fn contribution(
        self: @This(),
        body: anytype,
        query: anytype,
        need: anytype,
        capability: anytype,
    ) a.Error!*const a.Value(Integer) {
        const input = try body.field(query.state(), "input");
        const next = try body.product(self.types.state, .{
            .input = input,
            .successor = try body.constant(bool, true),
        });
        const first = try hyper.demand.request(body, need, capability, next);
        if (self.repeat) return repeatContribution(body, need, capability, next, first);
        const contribution_value = if (self.consumer) first else try add(
            body,
            first,
            try body.call(self.types.sample, .{
                .input = try body.field(query.state(), "input"),
            }),
        );
        return add(body, contribution_value, try body.constant(u64, if (self.consumer) 13 else 10));
    }
};

fn repeatContribution(
    body: anytype,
    need: anytype,
    capability: anytype,
    next: anytype,
    first: anytype,
) a.Error!*const a.Value(Integer) {
    const second = try hyper.demand.request(body, need, capability, next);
    return add(body, try add(body, first, second), try body.constant(u64, 13));
}

fn object(allocator: std.mem.Allocator, consumer: bool) ![]u8 {
    return objectChecked(allocator, consumer, false, false);
}

fn objectChecked(
    allocator: std.mem.Allocator,
    consumer: bool,
    false_capture: bool,
    alternative: bool,
) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const t = try types(c);
    if (false_capture) {
        const owned = try b.resource(try a.interop.schemaId(c, t.integer));
        const task_id = try a.interop.schemaId(c, t.task);
        b.schemas.items[@intCast(task_id)].internal.computation.capture_bound =
            try b.allocator().dupe(source.Id, &.{owned});
    }
    const pair = if (consumer or alternative) t.pair.swap() else t.pair;
    const entry = try c.function("create", .{ .state = t.state }, pair.forward(), .{});
    const body = try c.body(entry);
    const definition = try hyper.ana(body, pair, t.state, Step{
        .types = t,
        .consumer = consumer or alternative,
        .repeat = alternative,
    });
    const initial = try body.parameter("state");
    try c.define(entry, try body.ret(try hyper.start(body, definition, initial)));
    const entry_id = try a.interop.functionId(c, entry);
    const sample_id = try a.interop.functionId(c, t.sample);
    const interface: source.component.Interface = .{
        .imports = &.{
            .{ .name = "model", .reference = .{
                .kind = .effect,
                .id = try a.interop.operationId(c, t.model),
            } },
            .{ .name = "read", .reference = .{
                .kind = .effect,
                .id = try a.interop.operationId(c, t.read),
            } },
            .{ .name = "sample", .reference = .{ .kind = .function, .id = sample_id } },
        },
        .exports = &.{.{ .name = "create", .reference = .{ .kind = .function, .id = entry_id } }},
        .borrows = &.{.{ .function = sample_id }},
    };
    const module = try a.interop.componentModule(c, entry, try c.schema(void), interface);
    var compiled = try source.component.compile(allocator, module, interface);
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}

fn defineSample(context: protean.Context, t: Types) !void {
    const c = context.author;
    const interpreted = try protean.responders.defineModel(
        P,
        context,
        try context.literal(void, {}),
        false,
    );
    const body = try c.body(t.sample);
    const input = try body.parameter("input");
    const result = try body.call(interpreted, .{
        .request = try body.field(input, "request"),
        .offered = try body.field(input, "offered"),
    });
    const accepted = try body.caseOf(result, "accepted");
    const rejected = try body.caseOf(result, "rejected");
    const answer_body = accepted.body();
    const contribution = try answer_body.caseOf(accepted.payload(), "contribute");
    const value = try contribution.body().field(contribution.payload(), "value");
    const answer = try answer_body.match(accepted.payload(), .{
        .contribute = try contribution.ret(value),
    });
    try c.define(t.sample, try body.ret(try body.match(result, .{
        .accepted = try accepted.ret(answer),
        .rejected = try rejected.fail(t.integer, try rejected.body().constant(void, {})),
    })));
}

const Application = struct {
    var producer_bytes: []const u8 = &.{};
    var consumer_bytes: []const u8 = &.{};
    var omit_reference = false;
    var assessment = false;
    var completion = false;
    pub fn emit(context: protean.Context) !source.Module {
        const c = context.author;
        const t = try types(c);
        try context.registry.classify(try a.interop.operationId(c, t.model), .model);
        try context.registry.classify(try a.interop.operationId(c, t.read), .read);
        try defineSample(context, t);
        var bindings = t;
        if (completion) bindings.sample = try completionHelper(context, t);
        const producer = try install(
            context,
            bindings,
            "producer",
            producer_bytes,
            t.pair.forward(),
        );
        const consumer = try install(
            context,
            bindings,
            "consumer",
            consumer_bytes,
            t.pair.backward(),
        );
        if (assessment) try context.registry.speculate(try a.interop.functionId(c, producer), &.{
            try a.interop.operationId(c, t.model), try a.interop.operationId(c, t.read),
        });
        const entry = try c.function(
            "entry",
            .{ .input = t.input },
            t.integer,
            .{ t.model, t.read },
        );
        const body = try c.body(entry);
        const initial = try body.product(t.state, .{
            .input = try body.parameter("input"),
            .successor = try body.constant(bool, false),
        });
        const p = try body.call(producer, .{ .state = initial });
        const participant = try body.call(consumer, .{ .state = initial });
        const peer = try hyper.deferValue(body, t.pair.peerForward(), p);
        try c.define(entry, try body.ret(try withIdle(body, t, participant, peer)));
        return a.interop.componentModule(c, entry, try c.schema(void), .{
            .exports = &.{},
            .imports = &.{
                .{ .name = "producer", .reference = .{
                    .kind = .function,
                    .id = try a.interop.functionId(c, producer),
                } },
                .{ .name = "consumer", .reference = .{
                    .kind = .function,
                    .id = try a.interop.functionId(c, consumer),
                } },
                .{ .name = "model", .reference = .{
                    .kind = .effect,
                    .id = try a.interop.operationId(c, t.model),
                } },
                .{ .name = "read", .reference = .{
                    .kind = .effect,
                    .id = try a.interop.operationId(c, t.read),
                } },
            },
            .borrows = &.{
                .{ .function = try a.interop.functionId(c, producer) },
                .{ .function = try a.interop.functionId(c, consumer) },
            },
        });
    }
};

fn install(
    context: protean.Context,
    t: Types,
    name: []const u8,
    bytes: []const u8,
    result: *const a.Schema(Endpoint),
) !*const Maker {
    const c = context.author;
    const model = try a.interop.operationId(c, t.model);
    const read = try a.interop.operationId(c, t.read);
    const function = try protean.participant.declare(context, .{
        .instance = name,
        .object = bytes,
        .entry = "create",
        .parameters = &.{try a.interop.schemaId(c, t.state)},
        .result = try a.interop.schemaId(c, result),
        .effects = if (Application.omit_reference) &.{
            .{ .symbol = "model", .effect = model },
        } else &.{
            .{ .symbol = "model", .effect = model },
            .{ .symbol = "read", .effect = read },
        },
        .functions = &.{.{ .symbol = "sample", .function = try a.interop.functionId(c, t.sample) }},
    });
    return a.interop.importFunction(c, function, try c.callable(
        .{ .state = t.state },
        result,
        .{},
        .{ .use = .reusable },
    ));
}
const System = protean.system(.{
    .InitialArgs = Input,
    .Result = u64,
    .Failure = void,
    .application = Application,
});

fn discardIdle(body: anytype, value: anytype) a.Error!void {
    const parts = try body.destructure(value);
    _ = try body.disposePackage(try parts.get("future"));
}

fn withIdle(
    body: anytype,
    t: Types,
    participant: anytype,
    peer: anytype,
) a.Error!*const a.Value(Integer) {
    const c = try body.context();
    const unit = try c.schema(void);
    const g = try generator.create(c, "fixture.recursive.idle", unit, t.integer, unit, .{
        .captures = .{ .continuation = .{ unit, t.integer } },
        .residual = .{t.read},
    });
    const signature = try c.handledSchema(g.handler());
    const producer = try c.functionFor("idle producer", signature);
    const nested = try body.closureBody(producer);
    const capability = try nested.parameter("capability");
    _ = try nested.performLocal(g.effect(), capability, try nested.constant(u64, 7));
    _ = try nested.perform(t.read, try nested.constant(u64, 1));
    try c.define(producer, try nested.ret(try nested.constant(void, {})));
    const answer = try body.handleWith(g.handler(), try body.lambda(producer, signature), .{});
    const done = try body.caseOf(answer, "done");
    const yielded = try body.caseOf(answer, "yielded");
    const running = yielded.body();
    const parts = try running.destructure(yielded.payload());
    const delayed_task = try hyper.invoke(running, participant, peer);
    const task = try hyper.force(running, delayed_task);
    const result = try running.apply(task, .{});
    const next = try running.resumePackage(try parts.get("future"), try running.constant(void, {}));
    const finished = try running.caseOf(next, "done");
    const unexpected = try running.caseOf(next, "yielded");
    try discardIdle(unexpected.body(), unexpected.payload());
    const final = try running.match(next, .{
        .done = try finished.ret(result),
        .yielded = try unexpected.fail(t.integer, try unexpected.body().constant(void, {})),
    });
    return body.match(answer, .{
        .done = try done.fail(t.integer, try done.body().constant(void, {})),
        .yielded = try yielded.ret(final),
    });
}

fn completionHelper(context: protean.Context, t: Types) !*const Sample {
    const c = context.author;
    const write = try context.external(
        "fixture.recursive.target-write",
        t.input,
        t.integer,
        .write,
    );
    const function = try c.function("completion", .{ .input = t.input }, t.integer, .{write});
    const body = try c.body(function);
    const operation = try a.interop.performSite(body, write, try body.parameter("input"));
    try context.registry.protectSite(
        try a.interop.functionId(c, function),
        operation.term,
        try a.interop.operationId(c, write),
    );
    try c.define(function, try body.ret(operation.value));
    return function;
}

test "recursive participant rejects an exclusive resource hidden in a reusable task" {
    try std.testing.expectError(
        error.InvalidOwnership,
        objectChecked(std.testing.allocator, false, true, false),
    );
}

test "recursive participant normal admission rejects missing reference binding" {
    const allocator = std.testing.allocator;
    const p = try object(allocator, false);
    defer allocator.free(p);
    const c = try object(allocator, true);
    defer allocator.free(c);
    Application.producer_bytes = p;
    Application.consumer_bytes = c;
    Application.omit_reference = true;
    defer Application.omit_reference = false;
    try std.testing.expectError(error.InvalidParticipant, protean.compile(allocator, System));
}

test "recursive participant assessment examines imported completion authority" {
    const allocator = std.testing.allocator;
    const p = try object(allocator, false);
    defer allocator.free(p);
    const c = try object(allocator, true);
    defer allocator.free(c);
    Application.producer_bytes = p;
    Application.consumer_bytes = c;
    Application.assessment = true;
    defer Application.assessment = false;
    var permitted = try protean.compile(allocator, System);
    defer permitted.deinit();
    Application.completion = true;
    defer Application.completion = false;
    try std.testing.expectError(error.SpeculativeEffect, protean.compile(allocator, System));
}

test "recursive participant compiles repeated typed demand" {
    const allocator = std.testing.allocator;
    const p = try object(allocator, false);
    defer allocator.free(p);
    const c = try objectChecked(allocator, true, false, true);
    defer allocator.free(c);
    Application.producer_bytes = p;
    Application.consumer_bytes = c;
    var compiled = try protean.compile(allocator, System);
    defer compiled.deinit();
    var external_effects: usize = 0;
    for (compiled.program.effects) |effect| {
        if (effect.external) external_effects += 1;
    }
    try std.testing.expectEqual(2, external_effects);
}

const ExecutionRequest = enum { first_read, first_model, second_read, second_model, idle };

fn executionInput() Input {
    return .{ .offered = .{true}, .request = .{
        .invocation = .{
            .protocol = .{ .bytes = protean.model_invocation.protocol_identity },
            .model = .{ .bytes = "recursive-model" },
            .parameters = .{ .max_output_tokens = 128, .temperature = null, .reasoning = null },
            .messages = .{ .items = &.{.{
                .role = .user,
                .content = .{ .bytes = "Supply the requested contribution." },
            }} },
            .tools = P.allDeclarations(),
            .selection = .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false },
            .response_policy = .{
                .store = false,
                .stream = false,
                .background = false,
                .truncation = .disabled,
            },
            .normalization_limits = P.normalizationLimits(),
            .maximum_provider_response_bytes = 4096,
        },
        .policy = @splat(9),
        .selection = .{
            .profile_id = .{ .bytes = "recursive" },
            .profile_digest = @splat(7),
            .effective_effort = .low,
            .control_revision = 0,
        },
        .plan = .{
            .epoch = 0,
            .reason = .initial,
            .watermark = 0,
            .eviction_generation = 0,
            .prior = null,
            .catalog = .{ .digest = @splat(5), .bytes = 1 },
            .skills = .{ .items = &.{} },
        },
        .materialized = .{true},
        .offered = .{true},
        .results = .{ .items = &.{} },
    } };
}

fn executionReply(allocator: std.mem.Allocator, expected: ExecutionRequest) ![]u8 {
    if (expected != .first_model and expected != .second_model) {
        return protean.contracts.encodeOwned(u64, allocator, switch (expected) {
            .first_read => 3,
            .second_read => 5,
            .idle => 999,
            else => unreachable,
        });
    }
    const item: P.OutputItem = .{ .function_call = .{
        .call_id = .{ .bytes = if (expected == .first_model) "first" else "second" },
        .name = .{ .bytes = "contribute" },
        .arguments_json = .{ .bytes = if (expected == .first_model)
            "{\"value\":7}"
        else
            "{\"value\":11}" },
        .tool_ordinal_claim = 0,
        .decoded_action = .{ .decoded = .{ .contribute = .{
            .value = if (expected == .first_model) 7 else 11,
        } } },
    } };
    return protean.contracts.encodeOwned(P.AdaptiveResult, allocator, .{
        .result = .{ .output = .{
            .items = .{ .items = &.{item} },
            .normalized_output_digest = @splat(0),
        } },
        .replay = null,
        .replay_status = .complete,
        .usage = null,
    });
}

fn checkExecutionRequest(
    allocator: std.mem.Allocator,
    expected: ExecutionRequest,
    request: data.invocation.Request,
) !void {
    const model = expected == .first_model or expected == .second_model;
    try std.testing.expectEqualStrings(
        if (model)
            protean.model_invocation.semantic_identity
        else
            "fixture.recursive.reference-bytes",
        request.binding.semantic_identity,
    );
    const payload = if (model)
        try protean.contracts.encodeOwned(P.AdaptiveRequest, allocator, executionInput().request)
    else
        try protean.contracts.encodeOwned(u64, allocator, if (expected == .idle) 1 else 0);
    defer allocator.free(payload);
    try std.testing.expectEqualSlices(u8, payload, request.binding.payload);
}

fn restoreExecution(
    comptime kosmos: type,
    allocator: std.mem.Allocator,
    prepared: *const kosmos.Prepared,
    session: *?kosmos.Session,
) ![32]u8 {
    var original = try session.*.?.pendingRequest(allocator);
    defer original.deinit();
    const checkpoint = try session.*.?.checkpoint(allocator);
    defer allocator.free(checkpoint);
    session.*.?.deinit();
    session.* = null;
    session.* = try kosmos.Session.restore(allocator, prepared, checkpoint);
    var restored = try session.*.?.pendingRequest(allocator);
    defer restored.deinit();
    try std.testing.expectEqualDeep(original.request, restored.request);
    try std.testing.expectEqualSlices(u8, checkpoint, restored.state);
    return restored.request.request_identity;
}

fn runExecution(
    comptime kosmos: type,
    allocator: std.mem.Allocator,
    prepared: *const kosmos.Prepared,
    repeated: bool,
    restore: bool,
) !u64 {
    const arguments = try protean.contracts.encodeOwned(Input, allocator, executionInput());
    defer allocator.free(arguments);
    var session: ?kosmos.Session = try kosmos.Session.start(allocator, prepared, arguments);
    defer if (session) |*live| live.deinit();
    const requests: []const ExecutionRequest = if (repeated)
        &.{ .first_read, .first_model, .second_read, .second_model, .idle }
    else
        &.{ .first_read, .first_model, .idle };
    var answered: usize = 0;
    for (0..128) |_| switch (try session.?.run(65536)) {
        .progressed => {},
        .requested => {
            try std.testing.expect(answered < requests.len);
            var request = try session.?.pendingRequest(allocator);
            defer request.deinit();
            try checkExecutionRequest(allocator, requests[answered], request.request);
            const identity = if (restore)
                try restoreExecution(kosmos, allocator, prepared, &session)
            else
                request.request.request_identity;
            const reply = try executionReply(allocator, requests[answered]);
            defer allocator.free(reply);
            const response = try data.invocation.encodeOwned(data.invocation.Result, allocator, .{
                .request_identity = identity,
                .value = reply,
            });
            defer allocator.free(response);
            try session.?.answer(response);
            answered += 1;
        },
        .completed => |value| {
            try std.testing.expectEqual(requests.len, answered);
            var result = try protean.contracts.decodeOwned(
                u64,
                allocator,
                try session.?.bytes(&value),
            );
            defer result.deinit();
            return result.value;
        },
        else => return error.UnexpectedRecursiveOutcome,
    };
    return error.RecursiveExecutionBudgetExceeded;
}

pub fn nativeExecution(comptime kosmos: type) !void {
    const allocator = std.testing.allocator;
    const producer = try object(allocator, false);
    defer allocator.free(producer);
    Application.producer_bytes = producer;
    for ([_]bool{ false, true }) |repeated| {
        const consumer = try objectChecked(allocator, true, false, repeated);
        defer allocator.free(consumer);
        Application.consumer_bytes = consumer;
        var compiled = try protean.compile(allocator, System);
        defer compiled.deinit();
        const image = try allocator.alloc(
            u8,
            try data.program_image.encodedLength(compiled.program),
        );
        defer allocator.free(image);
        _ = try compiled.encode(allocator, image);
        var prepared = try kosmos.Prepared.init(allocator, image);
        defer prepared.deinit();
        const uninterrupted = try runExecution(kosmos, allocator, &prepared, repeated, false);
        try std.testing.expectEqual(@as(u64, if (repeated) 59 else 33), uninterrupted);
        try std.testing.expectEqual(
            uninterrupted,
            try runExecution(kosmos, allocator, &prepared, repeated, true),
        );
    }
}
