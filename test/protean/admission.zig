const std = @import("std");
const bnd = @import("horos");
const admission = @import("admission");
const Id = bnd.source.Id;
const B = bnd.source.Builder;
const allocator = std.testing.allocator;

const Fixture = struct {
    b: B,
    registry: admission.Registry,
    unit: Id,
    entry: Id,

    fn init() !Fixture {
        var b = B.init(allocator);
        errdefer b.deinit();
        const unit = try b.scalar(void);
        const entry = try b.declare(&.{}, unit, &.{}, &.{});
        return .{ .b = b, .registry = admission.Registry.init(allocator), .unit = unit, .entry = entry };
    }

    fn deinit(self: *Fixture) void {
        self.registry.deinit();
        self.b.deinit();
    }

    fn effect(self: *Fixture, name: []const u8, role: ?admission.Role) !Id {
        const id = try self.b.effect(.{
            .identity = name,
            .payload = self.unit,
            .result = self.unit,
            .external = role == null or role.? != .internal,
        });
        if (role) |r| try self.registry.classify(id, r);
        return id;
    }

    fn pure(self: *Fixture) !Id {
        return self.b.pure(try self.b.constant(void, {}));
    }

    fn perform(self: *Fixture, effect_id: Id) !Id {
        return self.b.term(.{ .perform = .{
            .effect = effect_id,
            .payload = try self.b.constant(void, {}),
        } });
    }

    fn check(self: *Fixture) !void {
        try admission.verify(allocator, self.b.module(self.entry, self.unit), &self.registry);
    }

    fn compile(self: *Fixture) !void {
        try self.check();
        try self.horosCompile();
    }

    fn horosCompile(self: *Fixture) !void {
        var compiled = try bnd.program.compile(allocator, self.b.module(self.entry, self.unit));
        defer compiled.deinit();
    }

    fn lambda(self: *Fixture, function: Id) !Id {
        const f = self.b.functions.items[@intCast(function)];
        const parameters = try self.b.allocator().alloc(Id, f.parameters.len);
        for (parameters, f.parameters) |*schema, variable| {
            schema.* = self.b.variables.items[@intCast(variable)];
        }
        const computation = try self.b.schema(.{ .internal = .{ .computation = .{
            .parameters = parameters,
            .result = f.result,
            .effects = f.effects,
        } } });
        return self.b.lambda(function, computation);
    }

    fn definePureRoot(self: *Fixture) !void {
        try self.b.define(self.entry, try self.pure());
    }
};

test "reserved mobility identities cannot masquerade as reads even when unused" {
    for ([_][]const u8{ "agent.mobility.resolve.v1", "agent.mobility.relocate.v1" }) |name| {
        var f = try Fixture.init();
        defer f.deinit();
        _ = try f.effect(name, .read);
        try f.definePureRoot();
        try std.testing.expectError(error.EffectRoleMismatch, f.check());
    }
}

test "mobility remains forbidden in speculation even when explicitly allowlisted" {
    for ([_][]const u8{ "agent.mobility.resolve.v1", "agent.mobility.relocate.v1" }) |name| {
        var f = try Fixture.init();
        defer f.deinit();
        const effect = try f.effect(name, .mobility);
        f.b.functions.items[@intCast(f.entry)].effects = &.{effect};
        const term = try f.perform(effect);
        try f.registry.protectSite(f.entry, term, effect);
        try f.b.define(f.entry, term);
        try f.compile();
        try f.registry.speculate(f.entry, &.{effect});
        try std.testing.expectError(error.SpeculativeEffect, f.check());
    }
}

test "recursive and higher-order mobility remain forbidden inside protected speculation" {
    for ([_]bool{ false, true }) |higher_order| {
        var f = try Fixture.init();
        defer f.deinit();
        const move = try f.effect("agent.mobility.relocate.v1", .mobility);
        const recursive = try f.b.declare(&.{}, f.unit, &.{move}, &.{});
        const performed = try f.perform(move);
        try f.registry.protectSite(recursive, performed, move);
        const next = try f.b.term(.{ .call = .{ .function = recursive, .arguments = &.{} } });
        try f.b.define(recursive, try f.b.bind(try f.b.variable(f.unit), performed, next));
        f.b.functions.items[@intCast(f.entry)].effects = &.{move};
        const call = if (higher_order) try f.b.term(.{ .apply = .{ .computation = try f.lambda(recursive), .arguments = &.{} } }) else next;
        try f.b.define(f.entry, call);
        try f.compile();
        try f.registry.speculate(f.entry, &.{move});
        try std.testing.expectError(error.SpeculativeEffect, f.check());
    }
}

test "protected exact site admits and copied DAG term in another owner rejects" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("test.commit", .commit);
    f.b.functions.items[@intCast(f.entry)].effects = &.{effect};
    const perform = try f.perform(effect);
    try f.registry.protectSite(f.entry, perform, effect);
    try f.b.define(f.entry, perform);
    try f.compile();
    const copied_owner = try f.b.declare(&.{}, f.unit, &.{effect}, &.{});
    try f.b.define(copied_owner, perform);
    try std.testing.expectError(error.ProtectedEffectBypass, f.check());
}

test "new perform cannot use an existing protected effect" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("test.approval", .approval);
    try f.b.define(f.entry, try f.perform(effect));
    try std.testing.expectError(error.ProtectedEffectBypass, f.check());
}

test "new effect id cannot alias protected identity" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.effect("test.commit", .commit);
    const alias = try f.effect("test.commit", .read);
    try f.b.define(f.entry, try f.perform(alias));
    try std.testing.expectError(error.DuplicateEffectIdentity, f.check());
}

test "model v3 concrete schema specializations share their semantic family" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    _ = try f.effect("agent.model.invoke.v3", .model);
    const text = try f.b.schema(.text);
    const specialized = try f.b.effect(.{
        .identity = "agent.model.invoke.v3",
        .payload = text,
        .result = text,
    });
    try f.registry.classify(specialized, .model);
    try f.compile();
    const alias = try f.b.effect(.{
        .identity = "agent.model.invoke.v3",
        .payload = f.unit,
        .result = f.unit,
    });
    try f.registry.classify(alias, .read);
    try std.testing.expectError(error.EffectRoleMismatch, f.check());
}

test "private call requires exact owner and term admission" {
    var f = try Fixture.init();
    defer f.deinit();
    const leaf = try f.b.declare(&.{}, f.unit, &.{}, &.{});
    try f.b.define(leaf, try f.pure());
    try f.registry.privateFunction(leaf);
    const call = try f.b.term(.{ .call = .{ .function = leaf, .arguments = &.{} } });
    try f.b.define(f.entry, call);
    try std.testing.expectError(error.PrivateFunctionBypass, f.check());
    try f.registry.allowPrivateCall(f.entry, call, leaf);
    try f.compile();
    const other = try f.b.declare(&.{}, f.unit, &.{}, &.{});
    try f.b.define(other, call);
    try std.testing.expectError(error.PrivateFunctionBypass, f.check());
}

test "private lambda requires exact owner and value admission" {
    var f = try Fixture.init();
    defer f.deinit();
    const leaf = try f.b.declare(&.{}, f.unit, &.{}, &.{});
    try f.b.define(leaf, try f.pure());
    try f.registry.privateFunction(leaf);
    const signature = try f.b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = f.unit,
    } } });
    const lambda = try f.b.lambda(leaf, signature);
    const apply = try f.b.term(.{ .apply = .{ .computation = lambda, .arguments = &.{} } });
    try f.b.define(f.entry, apply);
    try std.testing.expectError(error.PrivateFunctionBypass, f.check());
    try f.registry.allowPrivateLambda(f.entry, lambda, leaf);
    try f.compile();
}

test "private function cannot be used as root" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    try f.registry.privateFunction(f.entry);
    try std.testing.expectError(error.PrivateFunctionBypass, f.check());
}

fn localHandler(f: *Fixture, effect: Id, body: Id, multi: bool) !Id {
    const residual = try (bnd.source.Row{
        .effects = f.b.functions.items[@intCast(body)].effects,
    }).subtract(f.b.allocator(), .{ .effects = &.{effect} });
    if (multi) f.b.effects.items[@intCast(effect)].control_use = .multi;
    const ret = try f.b.declare(&.{f.unit}, f.unit, &.{}, &.{});
    try f.b.define(ret, try f.b.pure(try f.b.reference(f.b.parameter(ret, 0))));
    const resumption_schema = try f.b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = f.unit,
        .answer = f.unit,
        .handled = &.{effect},
        .effects = residual.effects,
        .mode = .deep,
        .use = if (multi) .multi else .linear,
    } } });
    const clause = try f.b.declare(&.{ f.unit, resumption_schema }, f.unit, residual.effects, &.{});
    try f.b.define(clause, try f.b.term(.{ .resume_value = .{
        .resumption = try f.b.reference(f.b.parameter(clause, 1)),
        .argument = try f.b.constant(void, {}),
    } }));
    const handler = try f.b.handler(.{
        .mode = .deep,
        .input = f.unit,
        .answer = f.unit,
        .return_function = ret,
        .effects = residual.effects,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = resumption_schema }},
    });
    return f.b.term(.{ .handle = .{ .handler = handler, .body = try f.lambda(body) } });
}

fn handledBody(f: *Fixture, effect: Id, effects: []const Id) !Id {
    const capability = try f.b.schema(.{ .internal = .{ .capability = effect } });
    return f.b.declare(&.{capability}, f.unit, effects, &.{});
}

fn performHandled(f: *Fixture, body: Id, effect: Id) !Id {
    return f.b.term(.{ .perform = .{
        .effect = effect,
        .capability = try f.b.reference(f.b.parameter(body, 0)),
        .payload = try f.b.constant(void, {}),
    } });
}

test "application cannot handle protected authority even outside speculation" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("test.approval", .approval);
    const body = try handledBody(&f, effect, &.{effect});
    const perform = try performHandled(&f, body, effect);
    try f.b.define(body, perform);
    try f.registry.protectSite(body, perform, effect);
    try f.b.define(f.entry, try localHandler(&f, effect, body, false));
    try f.horosCompile();
    try std.testing.expectError(error.ProtectedHandler, f.check());
}

test "private function cannot become an application's handler callback" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("test.internal", .internal);
    const body = try handledBody(&f, effect, &.{effect});
    try f.b.define(body, try performHandled(&f, body, effect));
    try f.b.define(f.entry, try localHandler(&f, effect, body, false));
    try f.compile();
    try f.registry.privateFunction(f.b.handlers.items[0].return_function);
    try std.testing.expectError(error.PrivateFunctionBypass, f.check());
}

test "speculation cannot hide unclassified effects behind local handler" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("test.unknown", null);
    const body = try handledBody(&f, effect, &.{effect});
    try f.b.define(body, try performHandled(&f, body, effect));
    try f.b.define(f.entry, try localHandler(&f, effect, body, false));
    try f.registry.speculate(f.entry, &.{});
    try f.horosCompile();
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "explicit model read and simulation speculation is admitted" {
    var f = try Fixture.init();
    defer f.deinit();
    const model = try f.effect("test.model", .model);
    const read = try f.effect("test.read", .read);
    const simulation = try f.effect("test.simulation", .simulation);
    const discarded = try f.b.variable(f.unit);
    const model_call = try f.perform(model);
    try f.registry.protectSite(f.entry, model_call, model);
    const run = try f.b.bind(discarded, model_call, try f.b.bind(try f.b.variable(f.unit), try f.perform(read), try f.perform(simulation)));
    f.b.functions.items[@intCast(f.entry)].effects = &.{ model, read, simulation };
    try f.b.define(f.entry, run);
    try f.registry.speculate(f.entry, &.{ model, read, simulation });
    try f.compile();
}

test "speculation checks effects hidden in cleanup function" {
    var f = try Fixture.init();
    defer f.deinit();
    const body = try f.b.declare(&.{}, f.unit, &.{}, &.{});
    try f.b.define(body, try f.pure());
    const effect = try f.effect("test.write", .write);
    const cleanup = try f.b.declare(&.{}, f.unit, &.{effect}, &.{});
    const perform = try f.perform(effect);
    try f.registry.protectSite(cleanup, perform, effect);
    try f.b.define(cleanup, perform);
    try f.b.define(f.entry, try f.b.term(.{ .protect = .{
        .body = try f.lambda(body),
        .cleanup = try f.lambda(cleanup),
    } }));
    try f.registry.speculate(f.entry, &.{effect});
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "captured capability hidden in a product cannot authorize speculation" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const effect = try f.effect("test.commit", .commit);
    const capability = try f.b.schema(.{ .internal = .{ .capability = effect } });
    const product = try f.b.schema(.{ .product = &.{capability} });
    const body = try f.b.declare(&.{product}, f.unit, &.{}, &.{});
    try f.b.define(body, try f.pure());
    try f.registry.speculate(body, &.{effect});
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "raw multi handler cannot omit speculative effect checks" {
    var f = try Fixture.init();
    defer f.deinit();
    const choice = try f.effect("test.choice", .internal);
    const write = try f.effect("test.write", .write);
    const body = try handledBody(&f, choice, &.{ choice, write });
    const perform = try f.perform(write);
    try f.registry.protectSite(body, perform, write);
    try f.b.define(body, try f.b.bind(try f.b.variable(f.unit), try performHandled(&f, body, choice), perform));
    try f.b.define(f.entry, try localHandler(&f, choice, body, true));
    f.b.functions.items[@intCast(f.entry)].effects = &.{write};
    try f.horosCompile();
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "ordinary internally handled multi resumption remains valid" {
    var f = try Fixture.init();
    defer f.deinit();
    const choice = try f.effect("test.choice", .internal);
    const body = try handledBody(&f, choice, &.{choice});
    try f.b.define(body, try performHandled(&f, body, choice));
    try f.b.define(f.entry, try localHandler(&f, choice, body, true));
    try f.compile();
}

test "protected resource must stay inside private function signatures" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const resource = try f.b.resource(f.unit);
    try f.registry.protectResource(resource);
    const escaping = try f.b.declare(&.{resource}, f.unit, &.{}, &.{});
    try f.b.define(escaping, try f.pure());
    try std.testing.expectError(error.ProtectedResourceEscape, f.check());
    try f.registry.privateFunction(escaping);
    try f.check();
    try f.registry.speculate(escaping, &.{});
    try std.testing.expectError(error.SpeculativeCapture, f.check());
}

test "external schemas cannot hide an internal future" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const cell = try f.b.schema(.{ .internal = .{ .cell = .{ .element = f.unit, .region = 0 } } });
    const wrapper = try f.b.schema(.{ .sum = &.{ f.unit, cell } });
    _ = try f.b.effect(.{ .identity = "test.export", .payload = wrapper, .result = f.unit });
    try std.testing.expectError(error.ProtectedResourceEscape, f.check());
}

test "malformed source references reject and recursive schemas terminate" {
    var f = try Fixture.init();
    defer f.deinit();
    const recursive = try f.b.reserveSchema();
    try f.b.defineSchema(recursive, .{ .sum = &.{ f.unit, recursive } });
    try f.b.define(f.entry, try f.pure());
    try f.check();
    f.b.functions.items[@intCast(f.entry)].body = std.math.maxInt(Id);
    try std.testing.expectError(error.InvalidSource, f.check());
}

test "resource schema alias retains the same protected authority" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const resource = try f.b.resource(f.unit);
    try f.registry.protectResource(resource);
    const alias = try f.b.reserveSchema();
    try f.b.defineSchema(alias, f.b.schemas.items[@intCast(resource)]);
    const escaped = try f.b.declare(&.{alias}, f.unit, &.{}, &.{});
    try f.b.define(escaped, try f.pure());
    try std.testing.expectError(error.ProtectedResourceEscape, f.check());
}

test "speculative indirect computation checks source origins with hidden effects" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const unknown = try f.effect("test.hidden", null);
    const unsafe_body = try handledBody(&f, unknown, &.{unknown});
    try f.b.define(unsafe_body, try performHandled(&f, unsafe_body, unknown));
    const hidden = try f.b.declare(&.{}, f.unit, &.{}, &.{});
    try f.b.define(hidden, try localHandler(&f, unknown, unsafe_body, false));
    const computation = try f.b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = f.unit,
    } } });
    _ = try f.b.lambda(hidden, computation);
    const caller = try f.b.declare(&.{computation}, f.unit, &.{}, &.{});
    try f.b.define(caller, try f.b.term(.{ .apply = .{
        .computation = try f.b.reference(f.b.parameter(caller, 0)),
        .arguments = &.{},
    } }));
    try f.registry.speculate(caller, &.{});
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "captured computation bounds inspect latent hidden effects without invocation" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const unknown = try f.effect("test.hidden.capture", null);
    const unsafe_body = try handledBody(&f, unknown, &.{unknown});
    try f.b.define(unsafe_body, try performHandled(&f, unsafe_body, unknown));
    const hidden = try f.b.declare(&.{}, f.unit, &.{}, &.{});
    try f.b.define(hidden, try localHandler(&f, unknown, unsafe_body, false));
    const callable = try f.b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = f.unit,
    } } });
    _ = try f.b.lambda(hidden, callable);
    const carrier = try f.b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = f.unit,
        .capture_bound = &.{callable},
    } } });
    const speculative = try f.b.declare(&.{carrier}, f.unit, &.{}, &.{});
    try f.b.define(speculative, try f.pure());
    try f.compile();
    try f.registry.speculate(speculative, &.{});
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "ordinary source cannot forge a lowered computation constructor" {
    var f = try Fixture.init();
    defer f.deinit();
    const computation = try f.b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = f.unit,
    } } });
    const raw = try f.b.primitive(computation, .computation, &.{}, 0);
    try f.b.define(f.entry, try f.b.term(.{ .apply = .{
        .computation = raw,
        .arguments = &.{},
    } }));
    try std.testing.expectError(error.UnprovenComputationOrigin, f.check());
}

test "multi computation lambda cannot omit speculative admission" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.definePureRoot();
    const write = try f.effect("test.write", .write);
    const body = try f.b.declare(&.{}, f.unit, &.{write}, &.{});
    const perform = try f.perform(write);
    try f.registry.protectSite(body, perform, write);
    try f.b.define(body, perform);
    const computation = try f.b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = f.unit,
        .effects = &.{write},
        .use = .multi,
    } } });
    _ = try f.b.lambda(body, computation);
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "cloning a linear handler continuation checks its original body" {
    var f = try Fixture.init();
    defer f.deinit();
    const choice = try f.effect("test.choice", .internal);
    const write = try f.effect("test.write", .write);
    const body = try handledBody(&f, choice, &.{ choice, write });
    const perform = try f.perform(write);
    try f.registry.protectSite(body, perform, write);
    try f.b.define(body, try f.b.bind(try f.b.variable(f.unit), try performHandled(&f, body, choice), perform));
    try f.b.define(f.entry, try localHandler(&f, choice, body, false));
    const handler = f.b.handlers.items[0];
    const resume_type = handler.clauses[0].resumption;
    var multi_shape = f.b.schemas.items[@intCast(resume_type)];
    multi_shape.internal.resumption.use = .multi;
    const template_type = try f.b.schema(multi_shape);
    const clause = handler.clauses[0].function;
    _ = try f.b.cloneResumption(
        try f.b.reference(f.b.parameter(clause, 1)),
        template_type,
    );
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "a forwarded authority requirement cannot hide in an internal effect" {
    var f = try Fixture.init();
    defer f.deinit();
    const write = try f.effect("test.write", .write);
    const internal = try f.b.effect(.{
        .identity = "test.forwarding",
        .payload = f.unit,
        .result = f.unit,
        .use_site_effects = &.{write},
        .external = false,
    });
    try f.registry.classify(internal, .internal);
    try f.b.define(f.entry, try f.perform(internal));
    try f.registry.speculate(f.entry, &.{});
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "model live observation and mobility effects cannot be locally substituted" {
    for ([_]admission.Role{ .model, .read, .mobility }) |role| {
        var f = try Fixture.init();
        defer f.deinit();
        const effect = try f.effect("test.trusted.environment", role);
        const body = try handledBody(&f, effect, &.{effect});
        const request = try performHandled(&f, body, effect);
        try f.registry.protectSite(body, request, effect);
        try f.b.define(body, request);
        try f.b.define(f.entry, try localHandler(&f, effect, body, false));
        try f.horosCompile();
        try std.testing.expectError(error.ProtectedHandler, f.check());
    }
}

test "ordinary read without evidence authority permits local interpretation" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("test.ordinary.read", .read);
    const body = try handledBody(&f, effect, &.{effect});
    try f.b.define(body, try performHandled(&f, body, effect));
    try f.b.define(f.entry, try localHandler(&f, effect, body, false));
    try f.compile();
}

test "raw model requests require the checked emission owner" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.effect("agent.model.invoke.v3", .model);
    f.b.functions.items[@intCast(f.entry)].effects = &.{effect};
    try f.b.define(f.entry, try f.perform(effect));
    try f.horosCompile();
    try std.testing.expectError(error.ProtectedEffectBypass, f.check());
}
test "delayed shallow package resumed under hidden-effect multi successor" {
    const a = std.testing.allocator;
    var b = B.init(a);
    defer b.deinit();
    var registry = admission.Registry.init(a);
    defer registry.deinit();
    const unit = try b.scalar(void);
    const e = try b.effect(.{ .identity = "probe/decision", .payload = unit, .result = unit, .external = false, .control_use = .multi });
    try registry.classify(e, .internal);
    const u = try b.effect(.{ .identity = "probe/unclassified", .payload = unit, .result = unit, .external = false });
    const cap = try b.schema(.{ .internal = .{ .capability = e } });
    const ucap = try b.schema(.{ .internal = .{ .capability = u } });
    const before = try b.schema(.{ .internal = .{ .resumption = .{ .effect = e, .input = unit, .answer = unit, .effects = &.{e}, .handled = &.{e}, .capture_bound = &.{ unit, cap }, .mode = .shallow, .use = .linear } } });
    const package = try b.schema(.{ .internal = .{ .suspension_package = before } });
    const after = try b.schema(.{ .internal = .{ .resumption = .{ .effect = e, .input = unit, .answer = unit, .effects = &.{}, .handled = &.{e}, .capture_bound = &.{ unit, cap }, .mode = .deep, .use = .multi } } });
    const done = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(done, try b.pure(try b.reference(b.parameter(done, 0))));
    const unexpected_return = try b.declare(&.{unit}, package, &.{}, &.{});
    try b.define(unexpected_return, try b.term(.{ .fail = try b.constant(void, {}) }));
    const park = try b.declare(&.{ unit, before }, package, &.{}, &.{});
    try b.define(park, try b.pure(try b.primitive(package, .package, &.{try b.reference(b.parameter(park, 1))}, 0)));
    const initial = try b.handler(.{ .mode = .shallow, .input = unit, .answer = package, .return_function = unexpected_return, .effects = &.{}, .clauses = &.{.{ .effect = e, .function = park, .resumption = before }} });
    const utoken = try b.schema(.{ .internal = .{ .resumption = .{ .effect = u, .input = unit, .answer = unit, .handled = &.{u}, .mode = .deep, .use = .linear } } });
    const uclause = try b.declare(&.{ unit, utoken }, unit, &.{}, &.{});
    try b.define(uclause, try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(uclause, 1)), .argument = try b.constant(void, {}) } }));
    const uh = try b.handler(.{ .mode = .deep, .input = unit, .answer = unit, .return_function = done, .clauses = &.{.{ .effect = u, .function = uclause, .resumption = utoken }} });
    const ub = try b.declare(&.{ucap}, unit, &.{u}, &.{});
    try b.define(ub, try b.term(.{ .perform = .{ .effect = u, .capability = try b.reference(b.parameter(ub, 0)), .payload = try b.constant(void, {}) } }));
    const ubtype = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ucap}, .result = unit, .effects = &.{u} } } });
    const successor_clause = try b.declare(&.{ unit, after }, unit, &.{}, &.{});
    const ignored = try b.variable(unit);
    try b.define(successor_clause, try b.bind(ignored, try b.term(.{ .handle = .{ .handler = uh, .body = try b.lambda(ub, ubtype) } }), try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(successor_clause, 1)), .argument = try b.constant(void, {}) } })));
    const successor = try b.handler(.{ .mode = .deep, .input = unit, .answer = unit, .return_function = done, .clauses = &.{.{ .effect = e, .function = successor_clause, .resumption = after }} });
    const body = try b.declare(&.{cap}, unit, &.{e}, &.{});
    const op = try b.term(.{ .perform = .{ .effect = e, .capability = try b.reference(b.parameter(body, 0)), .payload = try b.constant(void, {}) } });
    try b.define(body, try b.bind(try b.variable(unit), op, op));
    const bt = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = unit, .effects = &.{e} } } });
    const root = try b.declare(&.{}, unit, &.{}, &.{});
    const saved = try b.variable(package);
    try b.define(root, try b.bind(saved, try b.term(.{ .handle = .{ .handler = initial, .body = try b.lambda(body, bt) } }), try b.term(.{ .resume_with = .{ .resumption = try b.primitive(before, .unpack, &.{try b.reference(saved)}, 0), .argument = try b.constant(void, {}), .handler = successor } })));
    const module = b.module(root, unit);
    var compiled = try bnd.program.compile(a, module);
    defer compiled.deinit();
    // Rejection must be Protean's role check, after independent Horos compile.
    try std.testing.expectError(error.SpeculativeEffect, admission.verify(a, module, &registry));
}
