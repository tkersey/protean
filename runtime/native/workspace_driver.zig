//! Ordinary Horos handlers expose typed boundaries. Only Kosmos applies the
//! retained resumptions; the native owner supplies ordinary exported commands.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;
pub const prefix = "protean.workspace.control/1/";
/// The driver's command algebra transports canonical values unchanged.
/// JSON is a presentation/input syntax, never an intermediate wire value.
pub const Command = union(enum) { resume_value: []const u8, finish };
pub const Protocol = struct {
    class: @FieldType(contracts.workspace.Exposure, "class"),
    command_schema: []const u8,
    payload_schema: []const u8,
    payload: []const u8,

    pub fn encode(self: Protocol, a: std.mem.Allocator, command: Command) ![]u8 {
        const bytes = switch (command) {
            .resume_value => |input| if (self.class == .alternative) try std.mem.concat(a, u8, &.{
                &.{0},
                input,
            }) else try a.dupe(u8, input),
            .finish => if (self.class == .alternative) try a.dupe(u8, &.{
                1,
            }) else return error.InvalidPortCommand,
        };
        errdefer a.free(bytes);
        _ = try self.decode(a, bytes);
        return bytes;
    }

    /// Returned input borrows `bytes`. Validation and interpretation share the
    /// protocol for both live admission and retained-reply verification.
    pub fn decode(self: Protocol, a: std.mem.Allocator, bytes: []const u8) !Command {
        var schema = try data.schema.decode(a, self.command_schema);
        defer schema.deinit();
        try data.schema.validateValue(a, schema.descriptor, bytes);
        if (self.class != .alternative) return .{ .resume_value = bytes };
        var reader: data.wire.Reader = .{ .input = bytes };
        return switch (try reader.natural()) {
            0 => .{ .resume_value = bytes[reader.position..] },
            1 => blk: {
                try reader.finish();
                if (!try self.hasResult(a)) return error.NoBranchResult;
                break :blk .finish;
            },
            else => error.InvalidPortCommand,
        };
    }

    fn hasResult(self: Protocol, a: std.mem.Allocator) !bool {
        var schema = try data.schema.decode(a, self.payload_schema);
        defer schema.deinit();
        const descriptor = schema.descriptor;
        const root = descriptor.types[@intCast(descriptor.root)];
        if (root != .product or root.product.len != 2) return error.InvalidPortCommand;
        const optional = descriptor.types[@intCast(root.product[1])];
        if (optional != .sum or optional.sum.len != 2 or descriptor.types[
            @intCast(optional.sum[0])
        ] != .unit) return error.InvalidPortCommand;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const facts = try data.admission.schemas(scratch, descriptor.types);
        var reader: data.wire.Reader = .{ .input = self.payload };
        _ = try data.admission.readValue(
            scratch,
            descriptor.types,
            facts,
            root.product[0],
            &reader,
        );
        const tag = try reader.natural();
        if (tag > 1) return error.InvalidPortCommand;
        _ = try data.admission.readValue(
            scratch,
            descriptor.types,
            facts,
            optional.sum[@intCast(tag)],
            &reader,
        );
        try reader.finish();
        return tag == 1;
    }
};
pub const Port = struct {
    identity: []const u8,
    class: @FieldType(contracts.workspace.Exposure, "class"),
    argument: Id,
    observation: Id,
};
pub const Generated = struct {
    builder: source.Builder,
    module: source.Module,
    ports: []const Port,
    body: Id,
    controls: []const Id,
    pub fn deinit(self: *Generated) void {
        self.builder.deinit();
        self.* = undefined;
    }
};

fn captureBound(b: *source.Builder, schema: Id) !*[]const Id {
    if (schema >= b.schemas.items.len or b.schemas.items[
        @intCast(schema)
    ] != .internal) return error.InvalidOwnership;
    return switch (b.schemas.items[@intCast(schema)].internal) {
        .computation => |*value| &value.capture_bound,
        .resumption => |*value| &value.capture_bound,
        else => error.InvalidOwnership,
    };
}

fn extendBound(b: *source.Builder, schema: Id, capability: Id) !void {
    const bound = try captureBound(b, schema);
    if (std.mem.indexOfScalar(Id, bound.*, capability) != null) return;
    const extended = try b.allocator().alloc(Id, bound.*.len + 1);
    @memcpy(extended[0..bound.*.len], bound.*);
    extended[bound.*.len] = capability;
    bound.* = extended;
}

const Induced = struct {
    functions: []bool,
    values: []bool,
    terms: []bool,
    fn any(flags: []const bool, ids: []const Id) bool {
        for (ids) |id| if (flags[@intCast(id)]) return true;
        return false;
    }
    fn optional(flags: []const bool, id: ?Id) bool {
        return if (id) |value| flags[@intCast(value)] else false;
    }
    fn handler(self: Induced, value: data.program.Handler) bool {
        if (self.functions[@intCast(value.return_function)]) return true;
        for (value.clauses) |clause| if (self.functions[@intCast(clause.function)]) return true;
        return false;
    }
    fn term(self: Induced, module: source.Module, value: source.ast.Term, effect: Id) bool {
        const v = self.values;
        const t = self.terms;
        return switch (value) {
            .value, .dispose, .fail => |id| v[@intCast(id)],
            .yield_then => |id| t[@intCast(id)],
            .bind => |x| t[@intCast(x.value)] or t[@intCast(x.next)],
            .conditional => |x| v[
                @intCast(x.condition)
            ] or t[
                @intCast(x.when_true)
            ] or t[
                @intCast(x.when_false)
            ],
            .call => |x| self.functions[@intCast(x.function)] or any(v, x.arguments),
            .apply => |x| v[@intCast(x.computation)] or any(v, x.arguments),
            .perform => |x| (x.effect == effect and x.capability == null) or optional(
                v,
                x.capability,
            ) or v[
                @intCast(x.payload)
            ] or any(v, x.bodies) or any(v, x.use_site_capabilities),
            .handle => |x| self.handler(module.handlers[@intCast(x.handler)]) or v[
                @intCast(x.body)
            ] or any(v, x.arguments) or any(v, x.state),
            .resume_value => |x| v[@intCast(x.resumption)] or v[@intCast(x.argument)],
            .resume_with => |x| self.handler(module.handlers[@intCast(x.handler)]) or v[
                @intCast(x.resumption)
            ] or v[
                @intCast(x.argument)
            ] or any(v, x.state),
            .resume_computation => |x| v[@intCast(x.resumption)] or v[@intCast(x.computation)],
            .protect => |x| v[
                @intCast(x.body)
            ] or v[
                @intCast(x.cleanup)
            ] or any(v, x.arguments) or optional(v, x.resource),
            .with_region => |x| v[@intCast(x.body)] or any(v, x.arguments),
            .unpack_product => |x| v[@intCast(x.value)] or t[@intCast(x.body)],
            .match_sum => |x| blk: {
                if (v[@intCast(x.value)]) break :blk true;
                for (x.cases) |case| if (t[@intCast(case.body)]) break :blk true;
                break :blk false;
            },
        };
    }
};

fn inducedCaptures(a: std.mem.Allocator, module: source.Module, effect: Id) !Induced {
    const result: Induced = .{
        .functions = try a.alloc(bool, module.functions.len),
        .values = try a.alloc(bool, module.values.len),
        .terms = try a.alloc(bool, module.terms.len),
    };
    @memset(result.functions, false);
    @memset(result.values, false);
    @memset(result.terms, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (module.values, result.values) |value, *needed| {
            const now = switch (value.expression) {
                .literal, .variable => false,
                .lambda => |f| result.functions[@intCast(f)],
                .primitive => |p| Induced.any(result.values, p.operands),
            };
            changed = (now and !needed.*) or changed;
            needed.* = now;
        }
        for (module.terms, result.terms) |term, *needed| {
            const now = result.term(module, term, effect);
            changed = (now and !needed.*) or changed;
            needed.* = now;
        }
        for (module.functions, result.functions) |function, *needed| {
            const now = result.terms[@intCast(function.body.?)];
            changed = (now and !needed.*) or changed;
            needed.* = now;
        }
    }
    return result;
}

fn prepend(a: std.mem.Allocator, id: Id, ids: []const Id) ![]const Id {
    const result = try a.alloc(Id, ids.len + 1);
    result[0] = id;
    @memcpy(result[1..], ids);
    return result;
}

fn bindHandlerFunction(b: *source.Builder, function: Id, variable: Id) !Id {
    var copied = b.functions.items[@intCast(function)];
    copied.parameters = try prepend(b.allocator(), variable, copied.parameters);
    const id: Id = @intCast(b.functions.items.len);
    try b.functions.append(b.allocator(), copied);
    // A bound entry is the same source function under an added lexical
    // parameter. Transport its authority with its body, including copy chains.
    for (b.resources.items) |*resource| {
        inline for (.{ "introducers", "eliminators" }) |field| {
            const owners = &@field(resource, field);
            if (std.mem.indexOfScalar(Id, owners.*, function) != null) {
                // Function identities are appended, so preserve the existing
                // canonical order without repairing invalid source authority.
                owners.* = try std.mem.concat(b.allocator(), Id, &.{ owners.*, &.{id} });
            }
        }
    }
    return id;
}

// Region IDs are names in a sparse namespace, not a dense allocation size.
fn usedRegions(a: std.mem.Allocator, module: source.Module) ![]const Id {
    var ids: std.ArrayList(Id) = .empty;
    for (module.functions) |function| try ids.appendSlice(a, function.regions);
    for (module.schemas) |schema| if (schema == .internal) switch (schema.internal) {
        .computation => |value| try ids.appendSlice(a, value.regions),
        .resumption => |value| try ids.appendSlice(a, value.owned_regions),
        .region => |id| try ids.append(a, id),
        .cell => |value| try ids.append(a, value.region),
        .borrowed => |value| try ids.append(a, value.region),
        else => {},
    };
    for (module.terms) |term| switch (term) {
        .with_region => |value| try ids.append(a, value.region),
        .protect => |value| if (value.loan_region) |id| {
            try ids.append(a, id);
        },
        else => {},
    };
    std.mem.sort(Id, ids.items, {}, std.sort.asc(Id));
    var count: usize = 0;
    for (ids.items) |id| {
        if (count != 0 and ids.items[count - 1] == id) continue;
        ids.items[count] = id;
        count += 1;
    }
    return ids.items[0..count];
}

fn copyOriginal(b: *source.Builder, original: source.Module) !void {
    inline for (.{
        "schemas",
        "constants",
        "effects",
        "handlers",
        "resources",
        "variables",
        "values",
        "terms",
        "functions",
    }) |field| try @field(b, field).appendSlice(b.allocator(), @field(original, field));
    b.region_count = original.region_count;
}
fn sortedExposures(
    b: *source.Builder,
    requested: []const contracts.workspace.Exposure,
) ![]contracts.workspace.Exposure {
    const exposures = try b.allocator().dupe(contracts.workspace.Exposure, requested);
    std.mem.sort(contracts.workspace.Exposure, exposures, {}, struct {
        fn less(
            _: void,
            left: contracts.workspace.Exposure,
            right: contracts.workspace.Exposure,
        ) bool {
            return left.effect < right.effect;
        }
    }.less);
    return exposures;
}
const Ports = struct {
    ports: []Port,
    effects: []Id,
    exposed: []Id,
    capabilities: []Id,
    port_payloads: []Id,
    port_commands: []Id,
};
fn declarePorts(
    b: *source.Builder,
    original: source.Module,
    exposures: []const contracts.workspace.Exposure,
    unit: Id,
    optional_result: Id,
) !Ports {
    const ports = try b.allocator().alloc(Port, exposures.len);
    const effects = try b.allocator().alloc(Id, exposures.len);
    const exposed = try b.allocator().alloc(Id, exposures.len);
    const capabilities = try b.allocator().alloc(Id, exposures.len);
    const port_payloads = try b.allocator().alloc(Id, exposures.len);
    const port_commands = try b.allocator().alloc(Id, exposures.len);
    const result: Ports = .{
        .ports = ports,
        .effects = effects,
        .exposed = exposed,
        .capabilities = capabilities,
        .port_payloads = port_payloads,
        .port_commands = port_commands,
    };
    for (exposures, 0..) |exposure, i| {
        try declarePort(b, original, exposures, exposure, unit, optional_result, result, i);
    }
    return result;
}
fn declarePort(
    b: *source.Builder,
    original: source.Module,
    exposures: []const contracts.workspace.Exposure,
    exposure: contracts.workspace.Exposure,
    unit: Id,
    optional_result: Id,
    ports: Ports,
    i: usize,
) !void {
    if (exposure.effect >= original.effects.len) return error.InvalidExposure;
    for (exposures[0..i]) |prior| if (prior.effect == exposure.effect)
        return error.DuplicateExposure;
    const operation = original.effects[@intCast(exposure.effect)];
    if (operation.external or operation.bodies.len != 0) return error.InvalidExposure;
    if (exposure.class == .alternative and
        operation.control_use != .multi)
        return error.InvalidExposure;
    if (exposure.class == .observation and original.schemas[
        @intCast(operation.result)
    ] != .unit) return error.InvalidObservationResult;
    const identity = try std.fmt.allocPrint(b.allocator(), "{s}{d}", .{
        prefix,
        exposure.effect,
    });
    const payload = if (exposure.class == .alternative) try b.schema(.{ .product = &.{
        operation.payload,
        optional_result,
    } }) else operation.payload;
    const command = if (exposure.class == .alternative) try b.schema(.{ .sum = &.{
        operation.result,
        unit,
    } }) else operation.result;
    ports.effects[i] = try b.effect(.{
        .identity = identity,
        .payload = payload,
        .result = command,
        .external = true,
    });
    ports.exposed[i] = exposure.effect;
    // Keep the induced capture distinct from original declared captures;
    // schema interning here could repair an invalid original bound.
    ports.capabilities[i] = try b.reserveSchema();
    try b.defineSchema(ports.capabilities[i], .{ .internal = .{ .capability = exposure.effect } });
    ports.port_payloads[i] = payload;
    ports.port_commands[i] = command;
    ports.ports[i] = .{
        .identity = identity,
        .class = exposure.class,
        .argument = operation.result,
        .observation = operation.payload,
    };
}
const Wrapper = struct { root: Id, body: Id, residual: []const Id };
fn declareWrapper(
    b: *source.Builder,
    entry: source.ast.Function,
    input: Id,
    result: Id,
    ports: Ports,
) !Wrapper {
    // Preserve residual internal effects. Exposures intercept only explicitly
    // selected operations, including their deep recursive visits.
    var residual: std.ArrayList(Id) = .empty;
    try residual.appendSlice(b.allocator(), ports.effects);
    // A selected descriptor can also name explicitly attached operations.
    // Those may escape a shallow successor without targeting our capability.
    // Keep their declared residual row; attachment identity governs handling.
    try residual.appendSlice(b.allocator(), entry.effects);
    std.mem.sort(Id, residual.items, {}, std.sort.asc(Id));
    const root = try b.declare(&.{input}, result, residual.items, entry.regions);
    const body = try b.declare(ports.capabilities, result, entry.effects, entry.regions);
    return .{ .root = root, .body = body, .residual = residual.items };
}
fn bindExposed(b: *source.Builder, original: source.Module, ports: Ports, body: Id) !void {
    // Unattached selected operations are lexical holes supplied by this
    // wrapper. Explicit capabilities keep their original attachment identity.
    for (ports.exposed, 0..) |effect, i| {
        const capability = try b.reference(b.parameter(body, i));
        for (b.terms.items[0..original.terms.len]) |*term| {
            if (term.* == .perform and
                term.perform.effect == effect and
                term.perform.capability == null) term.perform.capability = capability;
        }
    }
}
fn extendInduced(b: *source.Builder, original: source.Module, ports: Ports, body: Id) !void {
    // Compute only the new lexical dependencies. Existing capture contracts
    // remain intact; unrelated closures must not acquire a capability bound
    // that changes handler relevance merely because a port was requested.
    for (ports.exposed, ports.capabilities, 0..) |effect, capability, i| {
        const needed = try inducedCaptures(b.allocator(), original, effect);
        for (original.values) |value| if (value.expression == .lambda and needed.functions[
            @intCast(value.expression.lambda)
        ]) {
            try extendBound(b, value.schema, capability);
        };
        try bindCapturingHandlers(b, original, needed, capability, b.parameter(body, i));
        try propagateCapture(b, original, capability);
    }
}
fn bindCapturingHandlers(
    b: *source.Builder,
    original: source.Module,
    needed: Induced,
    capability: Id,
    variable: Id,
) !void {
    // Handler functions are closed. Carry the induced lexical capability
    // through ordinary handler state, binding the same variable at each
    // closed entry. Copy those entries so direct callers and lambdas keep
    // their original signatures. Deep resume retains this state; shallow
    // resumeWith supplies it explicitly at its successor installation.
    const reference = try b.reference(variable);
    for (original.handlers, 0..) |handler, index| if (needed.handler(handler)) {
        var replacement = b.handlers.items[index];
        replacement.state = try prepend(b.allocator(), capability, replacement.state);
        replacement.return_function = try bindHandlerFunction(
            b,
            replacement.return_function,
            variable,
        );
        const copied = try b.allocator().dupe(data.program.Clause, replacement.clauses);
        for (copied) |*clause| {
            clause.function = try bindHandlerFunction(b, clause.function, variable);
            try extendBound(b, clause.resumption, capability);
        }
        replacement.clauses = copied;
        b.handlers.items[index] = replacement;
        for (b.terms.items[0..original.terms.len]) |*term| switch (term.*) {
            .handle => |*handle| if (handle.handler == index) {
                handle.state = try prepend(b.allocator(), reference, handle.state);
            },
            .resume_with => |*resume_with| if (resume_with.handler == index) {
                resume_with.state = try prepend(b.allocator(), reference, resume_with.state);
            },
            else => {},
        };
    };
}
fn propagateCapture(b: *source.Builder, original: source.Module, capability: Id) !void {
    // Captures belong to the computation/token type, including values
    // reached through bindings, parameters and projections. Propagate only
    // this fresh capability; original declared bounds remain unchanged.
    var changed = true;
    while (changed) {
        changed = false;
        for (original.terms) |term| {
            const carried = switch (term) {
                .handle => |h| .{ h.handler, original.values[@intCast(h.body)].schema },
                .resume_with => |r| .{
                    r.handler,
                    original.values[@intCast(r.resumption)].schema,
                },
                else => continue,
            };
            const schema = b.schemas.items[@intCast(carried[1])];
            if (schema != .internal) continue;
            const bound = switch (schema.internal) {
                .computation => |c| c.capture_bound,
                .resumption => |r| r.capture_bound,
                else => continue,
            };
            if (std.mem.indexOfScalar(Id, bound, capability) == null) continue;
            for (b.handlers.items[@intCast(carried[0])].clauses) |clause| {
                const prior = (try captureBound(b, clause.resumption)).*.len;
                try extendBound(b, clause.resumption, capability);
                changed = changed or prior != (try captureBound(b, clause.resumption)).*.len;
            }
        }
    }
}
const BodyDefinition = struct { schema: Id, returns: Id };
fn defineBody(
    b: *source.Builder,
    original: source.Module,
    entry: source.ast.Function,
    input: Id,
    result: Id,
    ports: Ports,
    wrapper: Wrapper,
) !BodyDefinition {
    const body_schema = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = ports.capabilities,
        .result = result,
        .effects = entry.effects,
        .capture_bound = &.{input},
        .regions = entry.regions,
    } } });
    try b.define(
        wrapper.body,
        try b.term(.{ .call = .{ .function = original.entry, .arguments = &.{
            try b.reference(b.parameter(wrapper.root, 0)),
        } } }),
    );
    const returns = try b.declare(&.{result}, result, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    return .{ .schema = body_schema, .returns = returns };
}
const CapturePolicy = struct {
    all: []const Id,
    cloneable: []const Id,
    regions: []const Id,
    obligations: bool,
};
fn capturePolicy(b: *source.Builder, original: source.Module, ports: Ports) !CapturePolicy {
    var capture_bound: std.ArrayList(Id) = .empty;
    for (original.variables) |schema| if (std.mem.indexOfScalar(
        Id,
        capture_bound.items,
        schema,
    ) == null) try capture_bound.append(b.allocator(), schema);
    for (ports.capabilities) |schema| if (std.mem.indexOfScalar(
        Id,
        capture_bound.items,
        schema,
    ) == null) try capture_bound.append(b.allocator(), schema);
    std.mem.sort(Id, capture_bound.items, {}, std.sort.asc(Id));
    const traits = try data.traits.derive(b.allocator(), b.schemas.items);
    var cloneable: std.ArrayList(Id) = .empty;
    for (capture_bound.items) |schema| if (traits.clone[
        @intCast(schema)
    ]) try cloneable.append(b.allocator(), schema);
    const regions = try usedRegions(b.allocator(), original);
    var obligations = false;
    for (original.terms) |term| if (term == .protect) {
        obligations = true;
        break;
    };
    return .{
        .all = capture_bound.items,
        .cloneable = cloneable.items,
        .regions = regions,
        .obligations = obligations,
    };
}
fn defineClause(
    b: *source.Builder,
    original: source.Module,
    exposure: contracts.workspace.Exposure,
    ports: Ports,
    wrapper: Wrapper,
    captures: CapturePolicy,
    entry: source.ast.Function,
    result: Id,
    unit: Id,
    optional_result: Id,
    i: usize,
) !data.program.Clause {
    const operation = original.effects[@intCast(exposure.effect)];
    const alternative = exposure.class == .alternative;
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = exposure.effect,
        .input = operation.result,
        .answer = result,
        .effects = wrapper.residual,
        .capture_bound = if (alternative or
            operation.control_use == .multi) captures.cloneable else captures.all,
        .handled = ports.exposed,
        .owned_regions = captures.regions,
        .mode = .deep,
        .use = if (alternative) .linear else operation.control_use,
        .obligations = !alternative and operation.control_use != .multi and captures.obligations,
    } } });
    const function = try b.declare(
        &.{ operation.payload, token },
        result,
        wrapper.residual,
        entry.regions,
    );
    const clause: data.program.Clause = .{
        .effect = exposure.effect,
        .function = function,
        .resumption = token,
    };
    const payload = try b.reference(b.parameter(function, 0));
    const owned = try b.reference(b.parameter(function, 1));
    if (exposure.class != .alternative) {
        try defineResumedValue(b, function, operation.result, ports.effects[i], payload, owned);
        return clause;
    }
    try defineAlternative(
        b,
        ports,
        wrapper,
        operation,
        entry,
        result,
        unit,
        optional_result,
        i,
        token,
        function,
        payload,
        owned,
    );
    return clause;
}
fn defineResumedValue(
    b: *source.Builder,
    function: Id,
    result: Id,
    effect: Id,
    payload: Id,
    owned: Id,
) !void {
    const answer = try b.variable(result);
    try b.define(
        function,
        try b.bind(
            answer,
            try b.term(.{ .perform = .{ .effect = effect, .payload = payload } }),
            try b.term(.{ .resume_value = .{
                .resumption = owned,
                .argument = try b.reference(answer),
            } }),
        ),
    );
}
fn defineAlternative(
    b: *source.Builder,
    ports: Ports,
    wrapper: Wrapper,
    operation: data.program.Effect,
    entry: source.ast.Function,
    result: Id,
    unit: Id,
    optional_result: Id,
    i: usize,
    token: Id,
    function: Id,
    payload: Id,
    owned: Id,
) !void {
    var template_type = b.schemas.items[@intCast(token)].internal.resumption;
    template_type.use = .multi;
    template_type.obligations = false;
    const template = try b.schema(.{ .internal = .{ .resumption = template_type } });
    const loop = try b.declare(
        &.{ operation.payload, template, optional_result },
        result,
        wrapper.residual,
        entry.regions,
    );
    const loop_payload = try b.reference(b.parameter(loop, 0));
    const loop_template = try b.reference(b.parameter(loop, 1));
    const last = try b.reference(b.parameter(loop, 2));
    const request = try b.primitive(ports.port_payloads[i], .product, &.{ loop_payload, last }, 0);
    const command = try b.variable(ports.port_commands[i]);
    const argument = try b.variable(operation.result);
    const finish = try b.variable(unit);
    const branch_result = try b.variable(result);
    const selected = try alternativeSelection(
        b,
        loop,
        loop_payload,
        loop_template,
        last,
        command,
        argument,
        finish,
        branch_result,
        optional_result,
        unit,
        result,
    );
    try b.define(
        loop,
        try b.bind(
            command,
            try b.term(.{ .perform = .{ .effect = ports.effects[i], .payload = request } }),
            selected,
        ),
    );
    const reusable = try b.cloneResumption(owned, template);
    const empty = try b.primitive(optional_result, .variant, &.{try b.constant(void, {})}, 0);
    try b.define(
        function,
        try b.term(.{ .call = .{ .function = loop, .arguments = &.{
            payload,
            reusable,
            empty,
        } } }),
    );
}
fn alternativeSelection(
    b: *source.Builder,
    loop: Id,
    loop_payload: Id,
    loop_template: Id,
    last: Id,
    command: Id,
    argument: Id,
    finish: Id,
    branch_result: Id,
    optional_result: Id,
    unit: Id,
    result: Id,
) !Id {
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = loop_template,
        .argument = try b.reference(argument),
    } });
    const next = try b.term(.{ .call = .{ .function = loop, .arguments = &.{
        loop_payload,
        loop_template,
        try b.primitive(optional_result, .variant, &.{try b.reference(branch_result)}, 1),
    } } });
    const none = try b.variable(unit);
    const some = try b.variable(result);
    // Reusable templates carry no linear disposal obligation. Returning
    // drops this reference; explicit dispose accepts only owned tokens.
    const completed = try b.pure(try b.reference(some));
    const no_result = try b.term(.{ .call = .{ .function = loop, .arguments = &.{
        loop_payload,
        loop_template,
        last,
    } } });
    const stop = try b.term(.{ .match_sum = .{ .value = last, .cases = &.{ .{
        .variable = none,
        .body = no_result,
    }, .{ .variable = some, .body = completed } } } });
    return b.term(.{ .match_sum = .{ .value = try b.reference(
        command,
    ), .cases = &.{ .{
        .variable = argument,
        .body = try b.bind(branch_result, resumed, next),
    }, .{ .variable = finish, .body = stop } } } });
}
fn extendGeneratedCaptures(b: *source.Builder, generated_schema_start: usize) !void {
    // Driver loops themselves can be retained by a later request. Include
    // their actual variable types in generated contracts, using Horos's clone
    // traits for multi-shot captures (never accepting an exclusive resource).
    const generated_traits = try data.traits.derive(b.allocator(), b.schemas.items);
    for (generated_schema_start..b.schemas.items.len) |schema_id| {
        const shape = b.schemas.items[schema_id];
        if (shape != .internal or shape.internal != .resumption) continue;
        const reusable = shape.internal.resumption.use == .multi or b.effects.items[
            @intCast(shape.internal.resumption.effect)
        ].control_use == .multi;
        for (b.variables.items) |captured| {
            if (!reusable or generated_traits.clone[
                @intCast(captured)
            ]) try extendBound(b, schema_id, captured);
        }
    }
}

pub fn generate(
    a: std.mem.Allocator,
    original: source.Module,
    requested: []const contracts.workspace.Exposure,
) !Generated {
    var b = source.Builder.init(a);
    errdefer b.deinit();
    try copyOriginal(&b, original);
    const exposures = try sortedExposures(&b, requested);
    const entry = original.functions[@intCast(original.entry)];
    if (entry.parameters.len != 1) return error.InvalidInterface;
    const input = original.variables[@intCast(entry.parameters[0])];
    const result = entry.result;
    const unit = try b.scalar(void);
    const optional_result = try b.schema(.{ .sum = &.{ unit, result } });
    const ports = try declarePorts(&b, original, exposures, unit, optional_result);
    const wrapper = try declareWrapper(&b, entry, input, result, ports);
    try bindExposed(&b, original, ports, wrapper.body);
    try extendInduced(&b, original, ports, wrapper.body);
    const body_definition = try defineBody(&b, original, entry, input, result, ports, wrapper);
    const clauses = try b.allocator().alloc(data.program.Clause, exposures.len);
    const captures = try capturePolicy(&b, original, ports);
    const generated_schema_start = b.schemas.items.len;
    for (exposures, clauses, 0..) |exposure, *clause, i| {
        clause.* = try defineClause(
            &b,
            original,
            exposure,
            ports,
            wrapper,
            captures,
            entry,
            result,
            unit,
            optional_result,
            i,
        );
    }
    try extendGeneratedCaptures(&b, generated_schema_start);
    const handler = try b.handler(.{
        .mode = .deep,
        .input = result,
        .answer = result,
        .return_function = body_definition.returns,
        .clauses = clauses,
        .effects = wrapper.residual,
    });
    try b.define(
        wrapper.root,
        try b.term(
            .{
                .handle = .{
                    .handler = handler,
                    .body = try b.lambda(wrapper.body, body_definition.schema),
                },
            },
        ),
    );
    return .{
        .module = b.module(wrapper.root, original.failure),
        .ports = ports.ports,
        .body = wrapper.body,
        .controls = ports.effects,
        .builder = b,
    };
}
