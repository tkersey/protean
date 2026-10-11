//! Checked responder compositions over ordinary Horos source.
//! A model result is candidate data; this module grants no operation authority.
const horos = @import("horos");
const authoring = @import("authoring.zig");
const source = horos.source;
const typed = horos.authoring;
const Id = source.Id;
const native = horos.data.schema.native;
fn V(comptime T: type) type {
    return *const typed.Value(typed.Shape(T));
}
pub fn ModelFunction(comptime P: type, comptime Request: type, comptime Result: type) type {
    return typed.Function(typed.Signature(native.Fields(&.{ "request", "offered" }, &.{ typed.Shape(Request), typed.Shape([P.declaration_count]bool) }), typed.Shape(Result)));
}

/// Normalized metadata is untrusted external evidence. Its adjacent admission
/// result is candidate data, never a grant or an executable operation.
pub fn ModelObservation(comptime P: type, comptime batch: bool) type {
    return struct {
        normalized: P.Result,
        interpretation: if (batch) P.BatchInterpretation else P.Interpretation,
    };
}

pub fn ReplayModelObservation(comptime P: type, comptime batch: bool) type {
    return struct {
        normalized: P.ReplayResult,
        interpretation: if (batch) P.BatchInterpretation else P.Interpretation,
    };
}

pub fn ReferenceModelObservation(comptime P: type, comptime batch: bool) type {
    return struct {
        normalized: P.ReferenceResult,
        interpretation: if (batch) P.BatchInterpretation else P.Interpretation,
    };
}

pub fn AdaptiveModelObservation(comptime P: type, comptime batch: bool) type {
    return struct {
        normalized: P.AdaptiveResult,
        interpretation: if (batch) P.BatchInterpretation else P.Interpretation,
    };
}

const Format = enum {
    plain,
    inline_replay,
    reference,
    adaptive,

    fn Request(comptime format: Format, comptime P: type) type {
        return switch (format) {
            .plain => P.Request,
            .inline_replay => P.ReplayRequest,
            .reference => P.ReferenceRequest,
            .adaptive => P.AdaptiveRequest,
        };
    }
    fn Result(comptime format: Format, comptime P: type) type {
        return switch (format) {
            .plain => P.Result,
            .inline_replay => P.ReplayResult,
            .reference => P.ReferenceResult,
            .adaptive => P.AdaptiveResult,
        };
    }
    fn Observation(comptime format: Format, comptime P: type, comptime batch: bool) type {
        return switch (format) {
            .plain => ModelObservation(P, batch),
            .inline_replay => ReplayModelObservation(P, batch),
            .reference => ReferenceModelObservation(P, batch),
            .adaptive => AdaptiveModelObservation(P, batch),
        };
    }
};

/// Declare a shared `(P.Request, [P.declaration_count]bool) -> Interpretation`
/// computation. The request is a semantic configuration template: its `tools`
/// field is intentionally replaced with the closed catalog filtered by offered.
/// Other fields are preserved; incompatible normalization bounds take `failure`
/// before external I/O. Selection and the very same offered value
/// are captured before suspension and used to admit the normalized result.
/// `failure` is a literal of the enclosing module's failure schema.
pub fn defineModel(comptime P: type, c: authoring.Context, failure: anytype, comptime batch: bool) !*const ModelFunction(P, P.Request, if (batch) P.BatchInterpretation else P.Interpretation) {
    const observed = try defineModelObserved(P, c, failure, batch);
    const t = c.author;
    const b = c.builder;
    const observed_id = try typed.interop.functionId(t, observed);
    const instance = try b.specialization(Id, "agent.model.candidate-projection/v3", .{ @intFromPtr(t), observed_id });
    const result = try c.schema(if (batch) P.BatchInterpretation else P.Interpretation);
    const effect = try typed.interop.operation(t, b.functions.items[@intCast(observed_id)].effects[0]);
    const signature = try t.callable(.{ .request = try c.schema(P.Request), .offered = try c.schema([P.declaration_count]bool) }, result, .{effect}, .{ .use = .reusable });
    if (instance.cached) |cached| return typed.interop.refineFunction(t, try typed.interop.declaredFunction(t, cached), signature);
    const handle = try t.functionFor("model candidate", signature);
    const body = try t.body(handle);
    const observation = try body.call(observed, .{ .request = try body.parameter("request"), .offered = try body.parameter("offered") });
    try t.define(handle, try body.ret(try body.field(observation, "interpretation")));
    _ = try instance.finish(b, try typed.interop.functionId(t, handle));
    return handle;
}

pub fn defineModelObserved(comptime P: type, c: authoring.Context, failure: anytype, comptime batch: bool) !*const ModelFunction(P, P.Request, ModelObservation(P, batch)) {
    return defineObserved(P, c, failure, batch, .plain);
}
pub fn defineReplayModelObserved(comptime P: type, c: authoring.Context, failure: anytype, comptime batch: bool) !*const ModelFunction(P, P.ReplayRequest, ReplayModelObservation(P, batch)) {
    return defineObserved(P, c, failure, batch, .inline_replay);
}
pub fn defineReferenceModelObserved(comptime P: type, c: authoring.Context, failure: anytype, comptime batch: bool) !*const ModelFunction(P, P.ReferenceRequest, ReferenceModelObservation(P, batch)) {
    return defineObserved(P, c, failure, batch, .reference);
}
pub fn defineAdaptiveModelObserved(comptime P: type, c: authoring.Context, failure: anytype, comptime batch: bool) !*const ModelFunction(P, P.AdaptiveRequest, AdaptiveModelObservation(P, batch)) {
    return defineObserved(P, c, failure, batch, .adaptive);
}
fn defineObserved(comptime P: type, c: authoring.Context, failure: anytype, comptime batch: bool, comptime format: Format) !*const ModelFunction(P, format.Request(P), format.Observation(P, batch)) {
    const b = c.builder;
    const t = c.author;
    const effect = switch (format) {
        .plain => try P.declare(b),
        .inline_replay => try P.declareReplay(b),
        .reference => try P.declareReference(b),
        .adaptive => try P.declareAdaptive(b),
    };
    try c.registry.classify(effect, .model);
    const operation = try typed.interop.externalOperation(t, effect, try c.schema(format.Request(P)), try c.schema(format.Result(P)));
    const fault = try typed.interop.literalFailure(t, failure);
    const instance = try b.specialization(Id, switch (format) {
        .plain => "agent.model.observed-responder/v3",
        .inline_replay => "agent.model.observed-responder/v4",
        .reference => "agent.model.observed-responder/v5",
        .adaptive => "agent.model.observed-responder/v6",
    }, .{ @intFromPtr(t), @typeName(P), effect, try typed.interop.failureLiteralId(t, fault), batch });
    const signature = try t.callable(.{ .request = try c.schema(format.Request(P)), .offered = try c.schema([P.declaration_count]bool) }, try c.schema(format.Observation(P, batch)), .{operation}, .{ .use = .reusable });
    if (instance.cached) |cached| return typed.interop.refineFunction(t, try typed.interop.declaredFunction(t, cached), signature);
    const interpreter = try typed.interop.sourceFunction(t, if (batch) try P.interpretAll(b) else try P.interpreter(b), try t.callable(.{
        .result = try c.schema(P.Result),
        .offered = try c.schema([P.declaration_count]bool),
        .selection = try c.schema(@import("model_invocation.zig").Selection),
    }, try c.schema(if (batch) P.BatchInterpretation else P.Interpretation), .{}, .{ .use = .reusable }));
    const handle = try t.functionFor("observed model response", signature);
    const function = try typed.interop.functionId(t, handle);
    const g = Generator(P, batch, format, @TypeOf(fault), @TypeOf(failure)){ .context = c, .typed_context = t, .handle = handle, .function = function, .fault = fault, .failure = failure };
    try t.define(handle, try g.emitBody(operation, interpreter));
    _ = try instance.finish(b, function);
    return handle;
}

/// Return an ordinary call term. Bind the candidate result before interpreting
/// it further or presenting it to the separate protected commitment path.
pub fn invokeModel(
    comptime P: type,
    c: authoring.Context,
    failure: Id,
    comptime batch: bool,
    request: Id,
    offered: Id,
) !Id {
    return c.builder.term(.{ .call = .{
        .function = try typed.interop.functionId(c.author, try defineModel(P, c, try @import("authoring_imports.zig").literal(c.author, failure), batch)),
        .arguments = &.{ request, offered },
    } });
}

pub fn invokeModelObserved(
    comptime P: type,
    c: authoring.Context,
    failure: Id,
    comptime batch: bool,
    request: Id,
    offered: Id,
) !Id {
    return c.builder.term(.{ .call = .{
        .function = try typed.interop.functionId(c.author, try defineModelObserved(P, c, try @import("authoring_imports.zig").literal(c.author, failure), batch)),
        .arguments = &.{ request, offered },
    } });
}

fn Generator(comptime P: type, comptime batch: bool, comptime format: Format, comptime Fault: type, comptime Failure: type) type {
    return struct {
        context: authoring.Context,
        typed_context: *typed.Context,
        handle: *const ModelFunction(P, format.Request(P), format.Observation(P, batch)),
        function: Id,
        fault: Fault,
        failure: Failure,
        const G = @This();
        const Request = format.Request(P);
        const Result = format.Result(P);
        const replay = format != .plain;

        fn rejectWhen(g: G, body: anytype, invalid: V(bool)) !void {
            const rejected = try body.branch();
            const accepted = try body.branch();
            _ = try body.conditional(invalid, try rejected.fail(try g.context.schema(void), g.failure), try accepted.ret(try accepted.constant(void, {})));
        }
        fn emitBody(g: G, operation: anytype, interpreter: anytype) !*const typed.Computation(typed.Shape(format.Observation(P, batch))) {
            const root = try g.typed_context.body(g.handle);
            const envelope = try root.parameter("request");
            const template = if (replay) try root.field(envelope, "invocation") else envelope;
            const offered = try root.parameter("offered");
            const materialized = if (format == .adaptive) try root.field(envelope, "materialized") else offered;
            if (format == .adaptive) try g.checkMaterialized(root, materialized, offered);
            var tools = try g.context.literal(P.Tools, .{ .items = &.{} });
            for (0..P.declaration_count) |index| tools = try g.filter(root, materialized, index, tools);
            const selection = try root.field(template, "selection");
            try g.checkTemplate(root, template, selection);
            const invocation = try g.request(root, template, tools);
            const payload = if (format == .adaptive) try root.update(envelope, .{ .invocation = invocation, .offered = offered }) else if (replay) try root.update(envelope, .{ .invocation = invocation }) else invocation;
            const site = try typed.interop.performSite(root, operation, payload);
            try g.context.registry.protectSite(g.function, site.term, try typed.interop.operationId(g.typed_context, operation));
            const observation = site.value;
            const normalized = if (replay) try root.field(observation, "result") else observation;
            const interpreted = try root.call(interpreter, .{ .result = normalized, .offered = offered, .selection = selection });
            const admitted = if (replay) blk: {
                const good = try root.branch();
                const lost = try root.branch();
                const Interpretation = if (batch) P.BatchInterpretation else P.Interpretation;
                const status = try root.field(observation, "replay_status");
                break :blk try root.conditional(try root.equal(try root.enumTag(status), try root.constant(u32, @backingInt(@import("model_invocation.zig").ReplayStatus.complete))), try good.ret(interpreted), try lost.ret(try g.context.literal(Interpretation, .{ .rejected = .unsupported })));
            } else interpreted;
            return root.ret(try root.product(try g.context.schema(format.Observation(P, batch)), .{ .normalized = observation, .interpretation = admitted }));
        }
        fn member(_: G, body: anytype, set: V([P.declaration_count]bool), index: usize) !V(bool) {
            const item = try body.sequenceGet(set, try body.constant(u64, index));
            const present = try body.caseOf(item, "some");
            const absent = try body.caseOf(item, "none");
            return body.match(item, .{ .some = try present.ret(present.payload()), .none = try absent.ret(try absent.body().constant(bool, false)) });
        }
        fn checkMaterialized(g: G, body: anytype, materialized: V([P.declaration_count]bool), offered: V([P.declaration_count]bool)) !void {
            for (0..P.declaration_count) |index| {
                const defined = try g.member(body, materialized, index);
                const callable = try g.member(body, offered, index);
                const valid = try body.select(callable, defined, try body.constant(bool, true));
                try g.rejectWhen(body, try body.equal(valid, try body.constant(bool, false)));
            }
        }
        fn declaration(g: G, body: anytype, index: usize) !V(P.ToolDeclaration) {
            const fields = @typeInfo(P.ToolDeclaration).@"struct";
            const Values = comptime blk: {
                var types: [fields.field_types.len]type = undefined;
                for (fields.field_types, 0..) |T, i| types[i] = V(T);
                break :blk native.Fields(fields.field_names, &types);
            };
            var values: Values = undefined;
            const item = P.allDeclarations().items[index];
            inline for (fields.field_names, fields.field_types) |name, T| @field(values, name) = try g.context.literal(T, @field(item, name));
            return body.product(try g.context.schema(P.ToolDeclaration), values);
        }
        fn filter(g: G, body: anytype, offered: V([P.declaration_count]bool), index: usize, previous: V(P.Tools)) !V(P.Tools) {
            const present = try g.member(body, offered, index);
            const included = try body.branch();
            const excluded = try body.branch();
            const appended = try included.append(previous, try g.declaration(included, index), .{ .capacity = g.fault });
            return body.conditional(present, try included.ret(appended), try excluded.ret(previous));
        }
        fn checkTemplate(g: G, body: anytype, template: V(P.Request), selection: V(@import("model_invocation.zig").Selection)) !void {
            const bytes = try body.field(template, "maximum_provider_response_bytes");
            const no_bytes = try body.caseOf(bytes, "none");
            const bounded_bytes = try body.caseOf(bytes, "some");
            try g.rejectWhen(body, try body.match(bytes, .{ .none = try no_bytes.ret(try no_bytes.body().constant(bool, false)), .some = try bounded_bytes.ret(try bounded_bytes.body().equal(bounded_bytes.payload(), try bounded_bytes.body().constant(u32, 0))) }));
            const Limits = @FieldType(P.Request, "normalization_limits");
            const limits = try body.field(template, "normalization_limits");
            const count = try body.field(limits, "maximum_output_items");
            const minimum = try body.field(selection, "minimum_calls");
            const maximum = try body.field(selection, "maximum_calls");
            const no_count = try body.caseOf(count, "none");
            const bounded_count = try body.caseOf(count, "some");
            try g.rejectWhen(body, try body.match(count, .{ .none = try no_count.ret(try no_count.body().constant(bool, false)), .some = try bounded_count.ret(try bounded_count.body().less(bounded_count.payload(), maximum)) }));
            try g.rejectWhen(body, try body.less(maximum, minimum));
            const bounds = P.normalizationLimits();
            // A request cannot promise a wider result than its reply schema.
            inline for (.{ "maximum_result_text_bytes", "maximum_arguments_bytes", "maximum_name_bytes", "maximum_call_id_bytes", "maximum_output_items" }) |name| {
                const actual = try body.field(limits, name);
                if (@typeInfo(@FieldType(Limits, name)) != .optional) {
                    try g.rejectWhen(body, try body.less(try body.constant(u32, @field(bounds, name)), actual));
                } else if (@field(bounds, name)) |bound| {
                    const unbounded = try body.caseOf(actual, "none");
                    const bounded = try body.caseOf(actual, "some");
                    try g.rejectWhen(body, try body.match(actual, .{ .none = try unbounded.ret(try unbounded.body().constant(bool, true)), .some = try bounded.ret(try bounded.body().less(try bounded.body().constant(u32, bound), bounded.payload())) }));
                }
            }
        }
        fn request(_: G, body: anytype, template: V(P.Request), tools: V(P.Tools)) !V(P.Request) {
            return body.update(template, .{ .tools = tools });
        }
    };
}
