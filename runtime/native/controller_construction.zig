const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const protean = @import("protean");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;

pub const identity = contracts.controller.identity;
pub const import_prefix = contracts.controller.import_prefix;
pub const effect_prefix = contracts.controller.effect_prefix;
pub const boot_identity = contracts.controller.boot_identity;
pub const TaskAnchor = contracts.controller.TaskAnchor;
pub const Import = contracts.controller.Import;
pub const Contract = contracts.controller.Contract;
pub const Binding = contracts.controller.Binding;
pub const Descriptor = contracts.controller.Descriptor;

pub fn schemas(a: std.mem.Allocator, descriptor: Descriptor) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(a);
    try result.appendSlice(a, &.{
        descriptor.private_input.bytes,
        descriptor.carry.bytes,
        descriptor.handoff_payload.bytes,
    });
    for (descriptor.imports.items) |item| {
        try result.appendSlice(a, &.{ item.payload.bytes, item.result.bytes });
        if (item.public_result) |schema| try result.append(a, schema.bytes);
    }
    return result.toOwnedSlice(a);
}

pub const Generated = struct {
    builder: source.Builder,
    module: source.Module,
    private_input: Id,
    carry: Id,
    imports: []const Import,
    model_function: Id,
    model_effect: Id,
    model_term: Id,
    handoff_effect: Id,
    handoff_term: Id,
    public_result: Id,

    pub fn deinit(self: *Generated) void {
        self.builder.deinit();
        self.* = undefined;
    }

    pub fn register(self: Generated, registry: *protean.admission.Registry) !void {
        for (self.module.effects, 0..) |effect, id| {
            const role: protean.admission.Role = if (!effect.external)
                .internal
            else if (id == self.model_effect)
                .model
            else if (id == self.handoff_effect)
                .commit
            else
                .read;
            try registry.classify(id, role);
        }
        try registry.protectSite(self.model_function, self.model_term, self.model_effect);
        try registry.protectSite(self.model_function, self.handoff_term, self.handoff_effect);
    }

    pub fn describe(
        self: Generated,
        a: std.mem.Allocator,
        program: data.activation.Program,
    ) !Descriptor {
        const bindings = try a.alloc(Binding, self.imports.len);
        for (self.imports, bindings) |imported, *binding| {
            const name = try std.fmt.allocPrint(a, "{s}{s}", .{
                effect_prefix,
                @tagName(imported),
            });
            const effect = for (program.effects) |effect| {
                if (std.mem.eql(u8, effect.identity, name)) break effect;
            } else return error.InvalidControllerInterface;
            binding.* = .{
                .import = imported,
                .identity = .{ .bytes = name },
                .payload = .{
                    .bytes = try data.schema.encodeOwned(a, program.schemas, effect.payload),
                },
                .result = .{
                    .bytes = try data.schema.encodeOwned(a, program.schemas, effect.result),
                },
                .public_result = if (imported == .deliberate) .{
                    .bytes = try data.schema.encodeOwned(
                        a,
                        self.module.schemas,
                        self.public_result,
                    ),
                } else null,
            };
        }
        const handoff = for (program.effects) |effect| {
            if (std.mem.eql(
                u8,
                effect.identity,
                contracts.controller.handoff_identity,
            )) break effect;
        } else return error.InvalidControllerInterface;
        return .{
            .contract = .{ .bytes = identity },
            .private_input = .{
                .bytes = try data.schema.encodeOwned(a, self.module.schemas, self.private_input),
            },
            .carry = .{ .bytes = try data.schema.encodeOwned(a, self.module.schemas, self.carry) },
            .handoff_payload = .{
                .bytes = try data.schema.encodeOwned(a, program.schemas, handoff.payload),
            },
            .imports = .{ .items = bindings },
        };
    }
};

fn matches(a: std.mem.Allocator, module: source.Module, schema: Id, expected: []const u8) !void {
    const actual = try data.schema.encodeOwned(a, module.schemas, schema);
    defer a.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidControllerInterface;
}

pub fn replySchema(a: std.mem.Allocator, native_result: []const u8) ![]u8 {
    var decoded = try data.schema.decode(a, native_result);
    defer decoded.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    try builder.schemas.appendSlice(builder.allocator(), decoded.descriptor.types);
    const diagnostic = try contracts.schema(?contracts.controller.Diagnostic, &builder);
    const root = try builder.schema(.{ .product = &.{ decoded.descriptor.root, diagnostic } });
    return data.schema.encodeOwned(a, builder.schemas.items, root);
}
pub fn conversionSchema(a: std.mem.Allocator, carry: []const u8) ![]u8 {
    var decoded = try data.schema.decode(a, carry);
    defer decoded.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    try builder.schemas.appendSlice(builder.allocator(), decoded.descriptor.types);
    const view = try contracts.schema(contracts.controller.OwnerView, &builder);
    const root = try builder.schema(.{ .product = &.{ decoded.descriptor.root, view } });
    return data.schema.encodeOwned(a, builder.schemas.items, root);
}

fn bridgeEffects(
    a: std.mem.Allocator,
    effects: []const Id,
    deliberate: Id,
    offer: Id,
    handoff: Id,
) ![]const Id {
    if (std.mem.indexOfScalar(Id, effects, deliberate) == null) return effects;
    return std.mem.concat(a, Id, &.{ effects, &.{ offer, handoff } });
}

const Interface = struct { input: Id, private: Id };
fn admitInterface(a: std.mem.Allocator, module: source.Module, contract: Contract) !Interface {
    const entry = module.functions[@intCast(module.entry)];
    if (entry.parameters.len != 1) return error.InvalidControllerInterface;
    const input = module.variables[@intCast(entry.parameters[0])];
    const fields = switch (module.schemas[@intCast(input)]) {
        .product => |fields| fields,
        else => return error.InvalidControllerInterface,
    };
    if (fields.len != 2) return error.InvalidControllerInterface;
    var scratch = source.Builder.init(a);
    defer scratch.deinit();
    const anchor = try contracts.schema(TaskAnchor, &scratch);
    const anchor_bytes = try data.schema.encodeOwned(a, scratch.schemas.items, anchor);
    defer a.free(anchor_bytes);
    try matches(a, module, fields[0], anchor_bytes);
    try matches(a, module, entry.result, contract.result.bytes);
    try matches(a, module, module.failure, contract.failure.bytes);
    const private_bytes = try data.schema.encodeOwned(a, module.schemas, fields[1]);
    defer a.free(private_bytes);
    return .{ .input = input, .private = fields[1] };
}

const Imported = struct {
    effects: std.ArrayList(Id),
    names: std.ArrayList(Import),
    carry: Id,
    fn deinit(self: *Imported, a: std.mem.Allocator) void {
        self.effects.deinit(a);
        self.names.deinit(a);
    }
};
fn admitImports(a: std.mem.Allocator, module: source.Module, contract: Contract) !Imported {
    var imported_effects: std.ArrayList(Id) = .empty;
    errdefer imported_effects.deinit(a);
    var imports: std.ArrayList(Import) = .empty;
    errdefer imports.deinit(a);
    var carry: ?Id = null;
    for (contract.imports.items, 0..) |signature, i| {
        for (contract.imports.items[0..i]) |prior| {
            if (prior.import == signature.import) return error.DuplicateControllerImport;
        }
    }
    for (module.effects, 0..) |effect, id| {
        if (std.mem.startsWith(u8, effect.identity, "agent.") or std.mem.startsWith(
            u8,
            effect.identity,
            "protean.",
        )) return error.ForbiddenEffect;
        if (effect.external) return error.UnboundEffect;
        if (!std.mem.startsWith(u8, effect.identity, import_prefix)) continue;
        const imported = std.meta.stringToEnum(
            Import,
            effect.identity[import_prefix.len..],
        ) orelse return error.UnknownControllerImport;
        if (std.mem.indexOfScalar(
            Import,
            imports.items,
            imported,
        ) != null) return error.DuplicateControllerImport;
        const signature = for (contract.imports.items) |signature| {
            if (signature.import == imported) break signature;
        } else return error.UnavailableControllerImport;
        if (effect.bodies.len != 0 or
            effect.use_site_effects.len != 0 or
            effect.control_use != .linear)
        {
            return error.InvalidControllerInterface;
        }
        if (try admitImport(a, module, effect, signature, imported)) |value| carry = value;
        try imports.append(a, imported);
        try imported_effects.append(a, id);
    }
    if (carry == null) return error.MissingControllerDeliberation;
    return .{ .effects = imported_effects, .names = imports, .carry = carry.? };
}

fn admitImport(
    a: std.mem.Allocator,
    module: source.Module,
    effect: data.program.Effect,
    signature: contracts.controller.Signature,
    imported: Import,
) !?Id {
    var carry: ?Id = null;
    var payload = effect.payload;
    if (imported == .deliberate) {
        const pair = switch (module.schemas[@intCast(payload)]) {
            .product => |pair| pair,
            else => return error.InvalidControllerInterface,
        };
        if (pair.len != 2) return error.InvalidControllerInterface;
        payload = pair[0];
        carry = pair[1];
        const carry_bytes = try data.schema.encodeOwned(a, module.schemas, pair[1]);
        a.free(carry_bytes);
        const result = switch (module.schemas[@intCast(effect.result)]) {
            .product => |result| result,
            else => return error.InvalidControllerInterface,
        };
        if (result.len != 2) return error.InvalidControllerInterface;
        try matches(
            a,
            module,
            result[0],
            (signature.native_result orelse return error.InvalidControllerInterface).bytes,
        );
        const reply = try replySchema(a, signature.native_result.?.bytes);
        defer a.free(reply);
        if (!std.mem.eql(
            u8,
            reply,
            signature.result.bytes,
        )) return error.InvalidControllerInterface;
    } else if (signature.native_result != null) {
        return error.InvalidControllerInterface;
    }
    try matches(a, module, payload, signature.payload.bytes);
    try matches(a, module, effect.result, signature.result.bytes);
    return carry;
}

fn copyModule(b: *source.Builder, module: source.Module, imports: Imported) ![]const Import {
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
    }) |field| try @field(b, field).appendSlice(b.allocator(), @field(module, field));
    b.region_count = module.region_count;
    const owned_imports = try b.allocator().dupe(Import, imports.names.items);
    for (imports.effects.items, owned_imports) |id, imported| {
        const effect = &b.effects.items[@intCast(id)];
        effect.identity = try std.fmt.allocPrint(b.allocator(), "{s}{s}", .{
            effect_prefix,
            @tagName(imported),
        });
        effect.external = true;
    }
    return owned_imports;
}

const Bridge = struct {
    deliberate: Id,
    public_result: Id,
    offer: Id,
    handoff_payload: Id,
    handoff: Id,
};
fn declareBridge(
    b: *source.Builder,
    imported_effects: []const Id,
    owned_imports: []const Import,
) !Bridge {
    const deliberate = for (imported_effects, owned_imports) |id, imported| {
        if (imported == .deliberate) break id;
    } else unreachable;
    const public_result = b.effects.items[@intCast(deliberate)].result;
    b.effects.items[
        @intCast(deliberate)
    ].result = b.schemas.items[
        @intCast(public_result)
    ].product[0];
    const model = b.effects.items[@intCast(deliberate)];
    const offer = try b.effect(.{
        .identity = contracts.controller.offer_identity,
        .payload = model.payload,
        .result = model.payload,
        .external = true,
    });
    const handoff_payload = try b.schema(.{ .product = &.{ model.payload, model.result } });
    const handoff = try b.effect(.{
        .identity = contracts.controller.handoff_identity,
        .payload = handoff_payload,
        .result = public_result,
        .external = true,
    });
    return .{
        .deliberate = deliberate,
        .public_result = public_result,
        .offer = offer,
        .handoff_payload = handoff_payload,
        .handoff = handoff,
    };
}

fn bridgeScopes(b: *source.Builder, imported_effects: []const Id, bridge: Bridge) !void {
    for (b.functions.items) |*function| {
        function.effects = try bridgeEffects(
            b.allocator(),
            function.effects,
            bridge.deliberate,
            bridge.offer,
            bridge.handoff,
        );
    }
    for (b.handlers.items) |*handler| {
        for (handler.clauses) |clause| if (std.mem.indexOfScalar(
            Id,
            imported_effects,
            clause.effect,
        ) != null) return error.InvalidControllerInterface;
        handler.effects = try bridgeEffects(
            b.allocator(),
            handler.effects,
            bridge.deliberate,
            bridge.offer,
            bridge.handoff,
        );
    }
    for (b.schemas.items) |*schema| if (schema.* == .internal) switch (schema.internal) {
        .computation => |*computation| {
            computation.effects = try bridgeEffects(
                b.allocator(),
                computation.effects,
                bridge.deliberate,
                bridge.offer,
                bridge.handoff,
            );
        },
        .resumption => |*resumption| {
            resumption.effects = try bridgeEffects(
                b.allocator(),
                resumption.effects,
                bridge.deliberate,
                bridge.offer,
                bridge.handoff,
            );
            resumption.escaping = try bridgeEffects(
                b.allocator(),
                resumption.escaping,
                bridge.deliberate,
                bridge.offer,
                bridge.handoff,
            );
        },
        else => {},
    };
}

const Wrapper = struct { function: Id, infer: Id, gate: Id };
fn defineWrapper(b: *source.Builder, bridge: Bridge) !Wrapper {
    const model = b.effects.items[@intCast(bridge.deliberate)];
    const wrapper = try b.declare(
        &.{model.payload},
        bridge.public_result,
        &.{ bridge.deliberate, bridge.offer, bridge.handoff },
        &.{},
    );
    for (b.terms.items) |*term| {
        if (term.* != .perform) continue;
        if (term.perform.effect != bridge.deliberate) continue;
        if (term.perform.capability != null or
            term.perform.bodies.len != 0 or
            term.perform.use_site_capabilities.len != 0)
        {
            return error.InvalidControllerInterface;
        }
        const arguments = try b.allocator().dupe(Id, &.{term.perform.payload});
        term.* = .{ .call = .{ .function = wrapper, .arguments = arguments } };
    }
    const proposed = try b.reference(b.parameter(wrapper, 0));
    const prepared = try b.variable(model.payload);
    const response = try b.variable(model.result);
    const offered = try b.term(.{ .perform = .{ .effect = bridge.offer, .payload = proposed } });
    const infer = try b.term(.{ .perform = .{
        .effect = bridge.deliberate,
        .payload = try b.reference(prepared),
    } });
    const bound = try b.primitive(
        bridge.handoff_payload,
        .product,
        &.{ try b.reference(prepared), try b.reference(response) },
        0,
    );
    const gate = try b.term(.{ .perform = .{ .effect = bridge.handoff, .payload = bound } });
    try b.define(wrapper, try b.bind(prepared, offered, try b.bind(response, infer, gate)));
    return .{ .function = wrapper, .infer = infer, .gate = gate };
}

fn defineRoot(
    b: *source.Builder,
    module: source.Module,
    input: Id,
    imported_effects: []const Id,
) !Id {
    const entry = module.functions[@intCast(module.entry)];
    const unit = try b.scalar(void);
    const boot = try b.effect(.{
        .identity = boot_identity,
        .payload = input,
        .result = unit,
        .external = true,
    });
    var effects: std.ArrayList(Id) = .empty;
    try effects.appendSlice(b.allocator(), b.functions.items[@intCast(module.entry)].effects);
    for (imported_effects) |effect| {
        if (std.mem.indexOfScalar(
            Id,
            effects.items,
            effect,
        ) == null) try effects.append(
            b.allocator(),
            effect,
        );
    }
    try effects.append(b.allocator(), boot);
    std.mem.sort(Id, effects.items, {}, std.sort.asc(Id));
    const root = try b.declare(&.{input}, entry.result, effects.items, entry.regions);
    const argument = try b.reference(b.parameter(root, 0));
    const boot_term = try b.term(.{ .perform = .{ .effect = boot, .payload = argument } });
    const invoke = try b.term(.{ .call = .{ .function = module.entry, .arguments = &.{
        argument,
    } } });
    try b.define(root, try b.bind(try b.variable(unit), boot_term, invoke));
    return root;
}

pub fn generate(a: std.mem.Allocator, module: source.Module, contract: Contract) !Generated {
    const interface = try admitInterface(a, module, contract);
    var imports = try admitImports(a, module, contract);
    defer imports.deinit(a);
    var builder = source.Builder.init(a);
    errdefer builder.deinit();
    const b = &builder;
    const owned_imports = try copyModule(b, module, imports);
    const bridge = try declareBridge(b, imports.effects.items, owned_imports);
    try bridgeScopes(b, imports.effects.items, bridge);
    const wrapper = try defineWrapper(b, bridge);
    const root = try defineRoot(b, module, interface.input, imports.effects.items);
    return .{
        .builder = builder,
        .module = b.module(root, module.failure),
        .private_input = interface.private,
        .carry = imports.carry,
        .imports = owned_imports,
        .model_function = wrapper.function,
        .model_effect = bridge.deliberate,
        .model_term = wrapper.infer,
        .handoff_effect = bridge.handoff,
        .handoff_term = wrapper.gate,
        .public_result = bridge.public_result,
    };
}
