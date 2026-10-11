//! Admission of the protected Protean authoring path. This is an author-time
//! inspection of Horos's source, never another executable representation.
const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const p = horos.data.program;
const Id = p.Id;

pub const Role = enum { internal, model, interaction, read, simulation, approval, commit, write, mobility };
pub const Error = std.mem.Allocator.Error || error{
    InvalidSource,
    EffectRoleMismatch,
    DuplicateEffectIdentity,
    ProtectedEffectBypass,
    ProtectedHandler,
    PrivateFunctionBypass,
    SpeculativeEffect,
    SpeculativeCapture,
    ProtectedResourceEscape,
    UnprovenComputationOrigin,
};

const Classification = struct { effect: Id, role: Role };
const Site = struct { owner: Id, node: Id, target: Id };
const Speculation = struct { body: Id, allowed: []const Id };
pub const CompiledEffect = struct { symbol: []const u8, effect: Id };
pub const CompiledImport = struct {
    function: Id,
    instance: []const u8,
    object: []const u8,
    entry: []const u8,
    effects: []const CompiledEffect,
    functions: []const @import("participant.zig").FunctionBinding = &.{},
    participant: bool = false,
    borrows: @import("horos").data.borrow_contract.Summary = .{ .function = 0 },
};

/// Metadata is private to the trusted Protean constructions during authoring.
/// Native Zig that forges this registry or mutates source is outside the public
/// authoring-path claim. Records never enter BPI3 or PST3.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    classifications: std.ArrayList(Classification) = .empty,
    sites: std.ArrayList(Site) = .empty,
    private_functions: std.ArrayList(Id) = .empty,
    private_calls: std.ArrayList(Site) = .empty,
    private_lambdas: std.ArrayList(Site) = .empty,
    speculations: std.ArrayList(Speculation) = .empty,
    protected_resources: std.ArrayList(Id) = .empty,
    compiled_imports: std.ArrayList(CompiledImport) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn classify(self: *Registry, effect: Id, role: Role) Error!void {
        if (self.roleOf(effect)) |present| {
            if (present != role) return error.EffectRoleMismatch;
            return;
        }
        try self.classifications.append(self.arena.allocator(), .{ .effect = effect, .role = role });
    }

    pub fn protectSite(self: *Registry, owner: Id, term: Id, effect: Id) Error!void {
        try self.sites.append(self.arena.allocator(), .{ .owner = owner, .node = term, .target = effect });
    }

    pub fn privateFunction(self: *Registry, function: Id) Error!void {
        try self.private_functions.append(self.arena.allocator(), function);
    }

    pub fn allowPrivateCall(self: *Registry, owner: Id, term: Id, callee: Id) Error!void {
        try self.private_calls.append(self.arena.allocator(), .{
            .owner = owner,
            .node = term,
            .target = callee,
        });
    }

    pub fn allowPrivateLambda(self: *Registry, owner: Id, value: Id, callee: Id) Error!void {
        try self.private_lambdas.append(self.arena.allocator(), .{
            .owner = owner,
            .node = value,
            .target = callee,
        });
    }

    pub fn speculate(self: *Registry, body: Id, allowed: []const Id) Error!void {
        const owned = try self.arena.allocator().dupe(Id, allowed);
        try self.speculations.append(self.arena.allocator(), .{ .body = body, .allowed = owned });
    }

    pub fn protectResource(self: *Registry, schema: Id) Error!void {
        try self.protected_resources.append(self.arena.allocator(), schema);
    }

    pub fn roleOf(self: *const Registry, effect: Id) ?Role {
        for (self.classifications.items) |item| if (item.effect == effect) return item.role;
        return null;
    }

    fn isPrivate(self: *const Registry, function: Id) bool {
        return contains(self.private_functions.items, function);
    }

    fn isCompiled(self: *const Registry, function: Id) bool {
        for (self.compiled_imports.items) |item| if (item.function == function) return true;
        return false;
    }

    fn allowedFor(self: *const Registry, body: Id) []const Id {
        for (self.speculations.items) |item| if (item.body == body) return item.allowed;
        return &.{};
    }

    fn protectedEffect(self: *const Registry, effect: Id) bool {
        if (self.roleOf(effect)) |role| if (protectedEmission(role)) return true;
        for (self.sites.items) |site| if (site.target == effect) return true;
        return false;
    }
};

const Kind = enum { function, term, value, schema, capture, handler, effect };
const Node = struct { kind: Kind, id: Id, owner: Id = 0 };

/// Work and storage are bounded by source nodes and edges, per owner function
/// and speculation entry. Explicit worklists terminate on recursive functions,
/// recursive schemas, and malformed cyclic term/value graphs.
pub fn verify(allocator: std.mem.Allocator, module: source.Module, registry: *const Registry) Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    try checkCatalogs(module, registry);
    var ordinary = Walker.init(scratch, module, registry, null);
    for (module.functions, 0..) |_, id| try ordinary.push(.function, id, id);
    for (module.handlers, 0..) |_, id| try ordinary.push(.handler, id, 0);
    try ordinary.run();
    try checkExports(scratch, module, registry);
    for (registry.speculations.items) |item| {
        var speculative = Walker.init(scratch, module, registry, item.allowed);
        try speculative.push(.function, item.body, item.body);
        try speculative.run();
    }
    try checkMultiOrigins(scratch, module, registry);
}

fn checkMultiOrigins(a: std.mem.Allocator, m: source.Module, r: *const Registry) Error!void {
    // The actual module determines all multi origins. Registry omission never
    // exempts a raw handle, clone, or multi computation from role checks.
    for (m.terms) |term| switch (term) {
        .handle => |h| if (try multiHandler(m, h.handler)) {
            try checkMultiValue(a, m, r, h.body, h.handler, h.state);
        },
        .resume_with => |h| if (try multiHandler(m, h.handler)) {
            if (h.resumption >= m.values.len) return error.InvalidSource;
            const schema_id = m.values[@intCast(h.resumption)].schema;
            try checkResumptionOrigins(a, m, r, schema_id);
            if (schema_id >= m.schemas.len) return error.InvalidSource;
            const shape = m.schemas[@intCast(schema_id)];
            if (shape != .internal or shape.internal != .resumption) return error.InvalidSource;
            // A packaged continuation can be consumed outside its creator's
            // handler subtree. Inspect this successor and its carried state as
            // well; the original admitted row bounds its external effects.
            var successor = Walker.init(a, m, r, shape.internal.resumption.effects);
            try successor.push(.schema, schema_id, 0);
            try successor.push(.handler, h.handler, 0);
            try successor.values(h.state, 0);
            try successor.run();
        },
        else => {},
    };
    for (m.values) |value_item| {
        if (value_item.schema >= m.schemas.len) return error.InvalidSource;
        const shape = m.schemas[@intCast(value_item.schema)];
        if (value_item.expression == .lambda and shape == .internal and
            shape.internal == .computation and shape.internal.computation.use == .multi)
            try checkMultiBody(a, m, r, value_item.expression.lambda, null, &.{});
        if (value_item.expression == .primitive and
            value_item.expression.primitive.opcode == .clone_resumption)
        {
            const operands = value_item.expression.primitive.operands;
            if (operands.len != 1 or operands[0] >= m.values.len) return error.InvalidSource;
            try checkResumptionOrigins(a, m, r, m.values[@intCast(operands[0])].schema);
        }
    }
}

fn checkResumptionOrigins(a: std.mem.Allocator, m: source.Module, r: *const Registry, id: Id) Error!void {
    if (id >= m.schemas.len) return error.InvalidSource;
    const shape = m.schemas[@intCast(id)];
    if (shape != .internal or shape.internal != .resumption) return error.InvalidSource;
    const signature = shape.internal.resumption;
    // A token's producer may itself have been installed as a successor, without
    // a direct handle of that handler. Its nominal resumption schema identifies
    // the source handler clauses whose code/state can travel with this token.
    for (m.handlers, 0..) |handler, handler_id| {
        for (handler.clauses) |clause| {
            if (clause.resumption != id) continue;
            var producer = Walker.init(a, m, r, signature.effects);
            try producer.push(.handler, handler_id, 0);
            try producer.push(.schema, id, 0);
            try producer.run();
            break;
        }
    }
    for (m.terms) |term| {
        if (term != .handle) continue;
        const h = term.handle;
        if (h.handler >= m.handlers.len) return error.InvalidSource;
        for (m.handlers[@intCast(h.handler)].clauses) |clause| {
            if (clause.effect == signature.effect) {
                try checkMultiValue(a, m, r, h.body, h.handler, h.state);
                break;
            }
        }
    }
}

fn checkMultiValue(
    a: std.mem.Allocator,
    m: source.Module,
    r: *const Registry,
    body: Id,
    handler_id: ?Id,
    state: []const Id,
) Error!void {
    if (body >= m.values.len) return error.InvalidSource;
    const value_item = m.values[@intCast(body)];
    if (value_item.expression == .lambda)
        return checkMultiBody(a, m, r, value_item.expression.lambda, handler_id, state);
    for (m.values) |origin| {
        if (origin.schema == value_item.schema and origin.expression == .lambda)
            try checkMultiBody(a, m, r, origin.expression.lambda, handler_id, state);
    }
}

fn checkMultiBody(
    a: std.mem.Allocator,
    m: source.Module,
    r: *const Registry,
    body: Id,
    handler_id: ?Id,
    state: []const Id,
) Error!void {
    var speculative = Walker.init(a, m, r, r.allowedFor(body));
    try speculative.push(.function, body, body);
    if (handler_id) |h| try speculative.push(.handler, h, body);
    try speculative.values(state, body);
    try speculative.run();
}

fn checkCatalogs(module: source.Module, registry: *const Registry) Error!void {
    for (registry.compiled_imports.items, 0..) |item, index| {
        if (item.function >= module.functions.len or module.functions[@intCast(item.function)].body != null or registry.isPrivate(item.function)) return error.InvalidSource;
        for (registry.compiled_imports.items[0..index]) |prior| if (prior.function == item.function) return error.InvalidSource;
    }
    if (module.entry >= module.functions.len or module.failure >= module.schemas.len)
        return error.InvalidSource;
    if (registry.isPrivate(module.entry)) return error.PrivateFunctionBypass;
    for (registry.classifications.items) |item| {
        if (item.effect >= module.effects.len) return error.InvalidSource;
        const external = module.effects[@intCast(item.effect)].external;
        if (item.role == .internal and external) return error.EffectRoleMismatch;
        if (protectedEmission(item.role) and !external) return error.EffectRoleMismatch;
    }
    for (module.effects, 0..) |effect, id| {
        if ((std.mem.eql(u8, effect.identity, "agent.mobility.resolve.v1") or
            std.mem.eql(u8, effect.identity, "agent.mobility.relocate.v1")) and
            (!effect.external or registry.roleOf(id) != .mobility)) return error.EffectRoleMismatch;
        if (@import("model_invocation.zig").isModelIdentity(effect.identity) and
            (!effect.external or registry.roleOf(id) != .model)) return error.EffectRoleMismatch;
        for (module.effects[0..id], 0..) |earlier, previous| {
            if (!std.mem.eql(u8, effect.identity, earlier.identity)) continue;
            // Model effects are generic semantic contracts: ERQ2's concrete schemas
            // bind its application specialization. Every alias retains .model;
            // a role-changing alias cannot bypass protected admission.
            if (effect.external and earlier.external and
                registry.roleOf(id) == .model and registry.roleOf(previous) == .model and
                @import("model_invocation.zig").isModelIdentity(effect.identity)) continue;
            return error.DuplicateEffectIdentity;
        }
    }
    for (registry.sites.items) |site| {
        if (site.owner >= module.functions.len or site.node >= module.terms.len or
            site.target >= module.effects.len) return error.InvalidSource;
        const term = module.terms[@intCast(site.node)];
        if (term != .perform or term.perform.effect != site.target) return error.InvalidSource;
    }
    for (registry.private_functions.items) |id| {
        if (id >= module.functions.len) return error.InvalidSource;
    }
    for (registry.protected_resources.items) |id| {
        if (id >= module.schemas.len) return error.InvalidSource;
        const shape = module.schemas[@intCast(id)];
        if (shape != .internal or shape.internal != .abstract_resource)
            return error.InvalidSource;
        if (shape.internal.abstract_resource >= module.resources.len) return error.InvalidSource;
        const resource = module.resources[@intCast(shape.internal.abstract_resource)];
        for (resource.introducers) |owner| if (!registry.isPrivate(owner))
            return error.ProtectedResourceEscape;
        for (resource.eliminators) |owner| if (!registry.isPrivate(owner))
            return error.ProtectedResourceEscape;
    }
}

const Walker = struct {
    allocator: std.mem.Allocator,
    module: source.Module,
    registry: *const Registry,
    speculative: ?[]const Id,
    queue: std.ArrayList(Node) = .empty,
    seen: std.AutoHashMapUnmanaged(Node, void) = .empty,

    fn init(a: std.mem.Allocator, m: source.Module, r: *const Registry, s: ?[]const Id) Walker {
        return .{ .allocator = a, .module = m, .registry = r, .speculative = s };
    }

    fn push(self: *Walker, kind: Kind, id: Id, owner: Id) Error!void {
        const node: Node = .{ .kind = kind, .id = id, .owner = owner };
        const entry = try self.seen.getOrPut(self.allocator, node);
        if (!entry.found_existing) try self.queue.append(self.allocator, node);
    }

    fn run(self: *Walker) Error!void {
        var index: usize = 0;
        while (index < self.queue.items.len) : (index += 1) {
            const node = self.queue.items[index];
            switch (node.kind) {
                .function => try self.function(node.id),
                .term => try self.term(node.id, node.owner),
                .value => try self.value(node.id, node.owner),
                .schema => try self.schema(node.id),
                .capture => try self.capture(node.id),
                .handler => try self.handler(node.id, node.owner),
                .effect => try self.effect(node.id),
            }
        }
    }

    fn values(self: *Walker, ids: []const Id, owner: Id) Error!void {
        for (ids) |id| try self.push(.value, id, owner);
    }

    fn schemas(self: *Walker, ids: []const Id) Error!void {
        for (ids) |id| try self.push(.schema, id, 0);
    }

    fn captures(self: *Walker, ids: []const Id) Error!void {
        for (ids) |id| try self.push(.capture, id, 0);
    }

    fn capture(self: *Walker, id: Id) Error!void {
        try self.push(.schema, id, 0);
        if (id >= self.module.schemas.len) return error.InvalidSource;
        if (self.speculative == null) return;
        switch (self.module.schemas[@intCast(id)]) {
            .product, .sum => |fields| try self.captures(fields),
            .seq => |element| try self.push(.capture, element, 0),
            .array => |a| try self.push(.capture, a.element, 0),
            .vector => |v| try self.push(.capture, v.element, 0),
            .internal => |internal| switch (internal) {
                .computation => {
                    // Captured callables require the same origin closure even
                    // when this branch retains rather than invokes the value.
                    for (self.module.values) |origin| {
                        if (origin.schema == id and origin.expression == .lambda)
                            try self.push(.function, origin.expression.lambda, origin.expression.lambda);
                    }
                },
                .cell => |c| try self.push(.capture, c.element, 0),
                .borrowed => |b| try self.push(.capture, b.value, 0),
                .suspension_package => |r| try self.push(.capture, r, 0),
                else => {},
            },
            else => {},
        }
    }

    fn effects(self: *Walker, ids: []const Id) Error!void {
        for (ids) |id| try self.push(.effect, id, 0);
    }

    fn function(self: *Walker, id: Id) Error!void {
        if (id >= self.module.functions.len) return error.InvalidSource;
        const f = self.module.functions[@intCast(id)];
        if (self.registry.isCompiled(id)) {
            for (self.registry.compiled_imports.items) |item| {
                if (item.function != id or !item.participant) continue;
                try self.participant(item);
                if (self.speculative != null) {
                    for (f.parameters) |variable| {
                        try self.variableSchema(variable);
                        try self.push(.capture, self.module.variables[@intCast(variable)], 0);
                    }
                    try self.push(.capture, f.result, 0);
                    try self.effects(f.effects);
                }
                return;
            }
            // An inspected closed read tool is not a proof about speculative
            // control hidden inside an absent source body.
            if (self.speculative != null) return error.UnprovenComputationOrigin;
            for (f.effects) |effect_id| {
                const role = self.registry.roleOf(effect_id) orelse return error.EffectRoleMismatch;
                if (role != .internal and role != .read and role != .simulation)
                    return error.ProtectedEffectBypass;
            }
        } else try self.push(.term, f.body orelse return error.InvalidSource, id);
        if (self.speculative != null) {
            for (f.parameters) |variable| try self.variableSchema(variable);
            try self.push(.schema, f.result, 0);
            try self.effects(f.effects);
        }
    }

    fn participant(self: *Walker, item: CompiledImport) Error!void {
        var decoded = @import("horos").data.component.decode(self.allocator, item.object) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSource;
        defer decoded.deinit();
        @import("participant.zig").inspect(self.allocator, decoded.object, item, self.registry, self.speculative) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SpeculativeEffect => error.SpeculativeEffect,
            error.SpeculativeCapture => error.SpeculativeCapture,
            error.ProtectedEffectBypass => error.ProtectedEffectBypass,
            error.ProtectedHandler => error.ProtectedHandler,
            else => error.InvalidSource,
        };
        for (item.functions) |binding| {
            if (self.registry.isPrivate(binding.function)) return error.PrivateFunctionBypass;
            try self.push(.function, binding.function, binding.function);
        }
    }

    fn variableSchema(self: *Walker, id: Id) Error!void {
        if (id >= self.module.variables.len) return error.InvalidSource;
        try self.push(.schema, self.module.variables[@intCast(id)], 0);
    }

    fn edge(self: *Walker, owner: Id, term_id: Id, callee: Id) Error!void {
        if (self.registry.isPrivate(callee) and
            !hasSite(self.registry.private_calls.items, owner, term_id, callee))
            return error.PrivateFunctionBypass;
        try self.push(.function, callee, callee);
    }

    fn term(self: *Walker, id: Id, owner: Id) Error!void {
        if (id >= self.module.terms.len) return error.InvalidSource;
        switch (self.module.terms[@intCast(id)]) {
            .value, .dispose, .fail => |v| try self.push(.value, v, owner),
            .yield_then => |next| try self.push(.term, next, owner),
            .bind => |b| {
                try self.variableSchema(b.variable);
                try self.push(.term, b.value, owner);
                try self.push(.term, b.next, owner);
            },
            .conditional => |c| {
                try self.push(.value, c.condition, owner);
                try self.push(.term, c.when_true, owner);
                try self.push(.term, c.when_false, owner);
            },
            .call => |c| {
                try self.edge(owner, id, c.function);
                try self.values(c.arguments, owner);
            },
            .apply => |a| {
                try self.computation(a.computation, owner);
                try self.values(a.arguments, owner);
            },
            .perform => |op| try self.operation(op, id, owner),
            .handle => |h| {
                try self.computation(h.body, owner);
                try self.push(.handler, h.handler, owner);
                try self.values(h.arguments, owner);
                try self.values(h.state, owner);
            },
            .resume_value => |r| try self.values(&.{ r.resumption, r.argument }, owner),
            .resume_with => |r| {
                try self.values(&.{ r.resumption, r.argument }, owner);
                try self.push(.handler, r.handler, owner);
                try self.values(r.state, owner);
            },
            .resume_computation => |r| {
                try self.push(.value, r.resumption, owner);
                try self.computation(r.computation, owner);
            },
            .protect => |body| {
                try self.computation(body.body, owner);
                try self.computation(body.cleanup, owner);
                try self.values(body.arguments, owner);
                if (body.resource) |v| try self.push(.value, v, owner);
            },
            .with_region => |r| {
                try self.computation(r.body, owner);
                try self.values(r.arguments, owner);
            },
            .match_sum => |m| {
                try self.push(.value, m.value, owner);
                for (m.cases) |case| {
                    try self.variableSchema(case.variable);
                    try self.push(.term, case.body, owner);
                }
            },
            .unpack_product => |u| {
                try self.push(.value, u.value, owner);
                for (u.variables) |v| try self.variableSchema(v);
                try self.push(.term, u.body, owner);
            },
        }
    }

    fn operation(self: *Walker, op: source.ast.Operation, term_id: Id, owner: Id) Error!void {
        if (op.effect >= self.module.effects.len) return error.InvalidSource;
        if (self.registry.protectedEffect(op.effect) and
            !hasSite(self.registry.sites.items, owner, term_id, op.effect))
            return error.ProtectedEffectBypass;
        try self.push(.effect, op.effect, 0);
        try self.push(.value, op.payload, owner);
        if (op.capability) |v| try self.push(.value, v, owner);
        for (op.bodies) |v| try self.computation(v, owner);
        try self.values(op.use_site_capabilities, owner);
    }

    fn value(self: *Walker, id: Id, owner: Id) Error!void {
        if (id >= self.module.values.len) return error.InvalidSource;
        const v = self.module.values[@intCast(id)];
        try self.push(.schema, v.schema, 0);
        switch (v.expression) {
            .variable => |variable_id| try self.variableSchema(variable_id),
            .literal => |literal| {
                if (literal >= self.module.constants.len) return error.InvalidSource;
            },
            .lambda => |callee| {
                if (self.speculative == null and self.registry.isPrivate(callee) and
                    !hasSite(self.registry.private_lambdas.items, owner, id, callee))
                    return error.PrivateFunctionBypass;
                try self.push(.function, callee, callee);
            },
            .primitive => |op| {
                if (op.opcode == .computation) return error.UnprovenComputationOrigin;
                try self.values(op.operands, owner);
                for (op.failures) |failure| {
                    if (failure.value >= self.module.constants.len) return error.InvalidSource;
                }
            },
        }
    }

    fn computation(self: *Walker, value_id: Id, owner: Id) Error!void {
        try self.push(.value, value_id, owner);
        if (value_id >= self.module.values.len) return error.InvalidSource;
        const v = self.module.values[@intCast(value_id)];
        if (self.speculative == null or v.expression == .lambda) return;
        // Conservative source-origin closure for higher-order values. A row
        // alone cannot disclose effects hidden by a callee's local handlers.
        for (self.module.values) |origin| {
            if (origin.schema == v.schema and origin.expression == .lambda)
                try self.push(.function, origin.expression.lambda, origin.expression.lambda);
        }
    }

    fn handler(self: *Walker, id: Id, owner: Id) Error!void {
        if (id >= self.module.handlers.len) return error.InvalidSource;
        const h = self.module.handlers[@intCast(id)];
        try self.push(.function, h.return_function, h.return_function);
        if (self.registry.isPrivate(h.return_function)) return error.PrivateFunctionBypass;
        for (h.clauses) |clause| {
            if (clause.effect >= self.module.effects.len) return error.InvalidSource;
            if (self.registry.protectedEffect(clause.effect)) return error.ProtectedHandler;
            if (self.registry.isPrivate(clause.function)) return error.PrivateFunctionBypass;
            try self.push(.function, clause.function, clause.function);
            try self.push(.effect, clause.effect, 0);
            try self.push(.schema, clause.resumption, 0);
        }
        if (self.speculative != null) {
            try self.effects(h.effects);
            try self.captures(h.state);
            try self.schemas(&.{ h.input, h.answer });
        }
        _ = owner;
    }

    fn effect(self: *Walker, id: Id) Error!void {
        if (id >= self.module.effects.len) return error.InvalidSource;
        if (self.speculative) |allowed| {
            const role = self.registry.roleOf(id) orelse return error.SpeculativeEffect;
            if (authority(role) or (role != .internal and !contains(allowed, id)))
                return error.SpeculativeEffect;
        }
        const e = self.module.effects[@intCast(id)];
        try self.schemas(&.{ e.payload, e.result });
        try self.schemas(e.bodies);
        try self.effects(e.use_site_effects);
    }

    fn schema(self: *Walker, id: Id) Error!void {
        if (id >= self.module.schemas.len) return error.InvalidSource;
        if (self.speculative != null and protectedResource(self.module, self.registry, id))
            return error.SpeculativeCapture;
        switch (self.module.schemas[@intCast(id)]) {
            .product, .sum => |fields| try self.schemas(fields),
            .seq => |element| try self.push(.schema, element, 0),
            .vector => |s| try self.push(.schema, s.element, 0),
            .array => |s| try self.push(.schema, s.element, 0),
            .internal => |internal| try self.internalSchema(internal),
            else => {},
        }
    }

    fn internalSchema(self: *Walker, internal: p.Internal) Error!void {
        switch (internal) {
            .computation => |c| {
                try self.schemas(c.parameters);
                try self.push(.schema, c.result, 0);
                try self.captures(c.capture_bound);
                if (self.speculative != null) try self.effects(c.effects);
            },
            .resumption => |r| {
                try self.schemas(&.{ r.input, r.answer });
                try self.captures(r.capture_bound);
                if (self.speculative != null) {
                    try self.push(.effect, r.effect, 0);
                    try self.effects(r.effects);
                    try self.effects(r.handled);
                    try self.effects(r.escaping);
                }
            },
            .capability => |effect_id| if (self.speculative != null) {
                try self.push(.effect, effect_id, 0);
            },
            .cell => |c| try self.push(.schema, c.element, 0),
            .borrowed => |b| try self.push(.schema, b.value, 0),
            .suspension_package => |r| try self.push(.schema, r, 0),
            .abstract_resource => |r| {
                if (r >= self.module.resources.len) return error.InvalidSource;
                try self.push(.schema, self.module.resources[@intCast(r)].representation, 0);
            },
            .region => {},
        }
    }
};

fn checkExports(a: std.mem.Allocator, m: source.Module, r: *const Registry) Error!void {
    const root = m.functions[@intCast(m.entry)];
    try portable(a, m, root.result);
    try portable(a, m, m.failure);
    for (root.parameters) |variable| {
        if (variable >= m.variables.len) return error.InvalidSource;
        try portable(a, m, m.variables[@intCast(variable)]);
    }
    for (m.effects) |effect| if (effect.external) {
        try portable(a, m, effect.payload);
        try portable(a, m, effect.result);
    };
    for (m.functions, 0..) |f, id| {
        if (r.isPrivate(id)) continue;
        try noProtectedResource(a, m, r, f.result);
        for (f.parameters) |v| {
            if (v >= m.variables.len) return error.InvalidSource;
            try noProtectedResource(a, m, r, m.variables[@intCast(v)]);
        }
    }
    for (m.handlers) |h| for (h.state) |schema_id| {
        try noProtectedResource(a, m, r, schema_id);
    };
}

fn portable(a: std.mem.Allocator, m: source.Module, root: Id) Error!void {
    return inspectShape(a, m, root, null);
}

fn noProtectedResource(a: std.mem.Allocator, m: source.Module, r: *const Registry, root: Id) Error!void {
    return inspectShape(a, m, root, r);
}

fn inspectShape(a: std.mem.Allocator, m: source.Module, root: Id, r: ?*const Registry) Error!void {
    var queue: std.ArrayList(Id) = .empty;
    var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
    try queue.append(a, root);
    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const id = queue.items[index];
        if (id >= m.schemas.len) return error.InvalidSource;
        const found = try seen.getOrPut(a, id);
        if (found.found_existing) continue;
        if (r) |registry| {
            if (protectedResource(m, registry, id))
                return error.ProtectedResourceEscape;
        }
        switch (m.schemas[@intCast(id)]) {
            .product, .sum => |fields| try queue.appendSlice(a, fields),
            .seq => |element| try queue.append(a, element),
            .array => |s| try queue.append(a, s.element),
            .vector => |s| try queue.append(a, s.element),
            .internal => |internal| {
                if (r == null) return error.ProtectedResourceEscape;
                switch (internal) {
                    .cell => |cell| try queue.append(a, cell.element),
                    .borrowed => |borrow| try queue.append(a, borrow.value),
                    .suspension_package => |schema_id| try queue.append(a, schema_id),
                    .computation => |c| {
                        try queue.appendSlice(a, c.parameters);
                        try queue.appendSlice(a, c.capture_bound);
                        try queue.append(a, c.result);
                    },
                    .resumption => |resumption| {
                        try queue.appendSlice(a, resumption.capture_bound);
                        try queue.appendSlice(a, &.{ resumption.input, resumption.answer });
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn multiHandler(module: source.Module, id: Id) Error!bool {
    if (id >= module.handlers.len) return error.InvalidSource;
    for (module.handlers[@intCast(id)].clauses) |clause| {
        if (clause.resumption >= module.schemas.len) return error.InvalidSource;
        const schema = module.schemas[@intCast(clause.resumption)];
        if (schema == .internal and schema.internal == .resumption and
            schema.internal.resumption.use == .multi) return true;
    }
    return false;
}

fn protectedResource(module: source.Module, registry: *const Registry, schema_id: Id) bool {
    const shape = module.schemas[@intCast(schema_id)];
    if (shape != .internal or shape.internal != .abstract_resource) return false;
    for (registry.protected_resources.items) |registered| {
        const protected = module.schemas[@intCast(registered)].internal.abstract_resource;
        if (shape.internal.abstract_resource == protected) return true;
    }
    return false;
}

fn authority(role: Role) bool {
    return role == .approval or role == .commit or role == .write or role == .mobility;
}

fn protectedEmission(role: Role) bool {
    return authority(role) or role == .model;
}

fn contains(ids: []const Id, id: Id) bool {
    return std.mem.indexOfScalar(Id, ids, id) != null;
}

fn hasSite(sites: []const Site, owner: Id, node: Id, target: Id) bool {
    for (sites) |site| if (site.owner == owner and site.node == node and site.target == target)
        return true;
    return false;
}
