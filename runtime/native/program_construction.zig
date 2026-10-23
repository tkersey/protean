//! One checked source build owner. It never executes the authored algorithm.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const protean = @import("protean");
const records = @import("source_records.zig");
const preflight = @import("source_preflight.zig");
const contracts = @import("protean_contracts");
pub const driver = @import("workspace_driver.zig");
pub const controller = @import("controller_construction.zig");
pub const CandidateDocument = struct {
    version: u32,
    proposal: @import("kosmos").RuntimeCompiler.RecordProposal,
};

pub const PortInterface = struct {
    identity: contracts.Utf8,
    class: @FieldType(contracts.workspace.Exposure, "class"),
    argument: contracts.Bytes(null),
    observation: contracts.Bytes(null),
    payload: contracts.Bytes(null),
    command: contracts.Bytes(null),
};

pub const Diagnostic = struct {
    phase: enum { transport, preflight, authority, compilation, interface, complete } = .transport,
    source: horos.source.Diagnostic = .{},
    code: ?anyerror = null,
};

pub const Built = struct {
    arena: std.heap.ArenaAllocator,
    image: []const u8,
    interface: contracts.tool_construction.Interface,
    ports: []const PortInterface = &.{},
    controller: ?controller.Descriptor = null,
    pub fn deinit(self: *Built) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn encodeSource(a: std.mem.Allocator, module: horos.source.Module) ![]u8 {
    return records.encode(a, module);
}

pub const component_identity = "protean-component-recipe/1";

pub fn buildComponent(a: std.mem.Allocator, catalog_bytes: []const u8, text: []const u8) !Built {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const output = arena.allocator();
    var catalog = try contracts.decodeOwned(contracts.tool_construction.Catalog, output, catalog_bytes);
    defer catalog.deinit();
    const built = try @import("tool_construction.zig").build(output, a, catalog.value, text);
    return .{ .arena = arena, .image = built.image.bytes, .interface = built.interface };
}

/// Describe actual compiled symbols and descriptors. No handwritten type menu
/// is involved in component admission or subsequent workspace execution.
pub fn describeComponents(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const json = @import("json.zig");
    const wp = @import("workspace_projection.zig");
    var catalog = try contracts.decodeOwned(contracts.tool_construction.Catalog, a, bytes);
    defer catalog.deinit();
    try @import("tool_construction.zig").validateCatalog(a, catalog.value);
    var description = json.object();
    try json.put(a, &description, "recipe_schema", json.string(&contracts.json.ClientSchema(contracts.tool_construction.Recipe).value));
    var components: json.Value = .{ .array = .init(a) };
    for (catalog.value.items) |item| {
        var decoded = try data.component.decode(a, item.object.bytes);
        defer decoded.deinit();
        const program = decoded.object.program;
        var component = json.object();
        try json.put(a, &component, "id", json.string(try a.dupe(u8, item.id.bytes)));
        inline for (.{ "imports", "exports" }) |field| {
            var symbols: json.Value = .{ .array = .init(a) };
            for (@field(decoded.object, field)) |symbol| {
                if (symbol.reference.kind != .function) return error.UnsupportedCatalogInterface;
                const function = program.functions[@intCast(symbol.reference.id)];
                var signature = json.object();
                try json.put(a, &signature, "name", json.string(try a.dupe(u8, symbol.name)));
                var inputs: json.Value = .{ .array = .init(a) };
                for (function.inputs) |slot| {
                    const descriptor = try data.schema.encodeOwned(a, program.schemas, function.layout.slots[@intCast(slot)]);
                    defer a.free(descriptor);
                    try inputs.array.append(try wp.schema(a, descriptor));
                }
                try json.put(a, &signature, "parameters", inputs);
                const descriptor = try data.schema.encodeOwned(a, program.schemas, function.result);
                defer a.free(descriptor);
                try json.put(a, &signature, "result", try wp.schema(a, descriptor));
                try symbols.array.append(signature);
            }
            try json.put(a, &component, field, symbols);
        }
        try components.array.append(component);
    }
    try json.put(a, &description, "components", components);
    return json.canonical(a, description);
}

pub fn example(a: std.mem.Allocator) ![]u8 {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    return records.encode(a, try horos.source.examples.lexical(&builder));
}

pub fn runtimeQuery(a: std.mem.Allocator, retention: bool) ![]u8 {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const queries = @import("kosmos").RuntimeViews.queries;
    return records.encode(a, if (retention) try queries.retention(&builder) else try queries.divergence(&builder));
}

pub fn hypotheticalReply(a: std.mem.Allocator) ![]u8 {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    return records.encode(a, try @import("kosmos").RuntimeAnalysis.example(&builder));
}

pub fn semanticSource(
    a: std.mem.Allocator,
    runtime: *const @import("kosmos").RuntimeArtifact,
    guest: @import("state.zig").Reference,
    section: contracts.workspace.SemanticSection,
    page: contracts.workspace.Page,
) !@import("json.zig").Value {
    var exported = try @import("kosmos").RuntimeCompiler.exportSource(a, runtime);
    defer exported.deinit();
    const bundle = exported.value;
    return switch (section) {
        .summary => blk: {
            const text = try semanticSummary(a, bundle, guest);
            defer a.free(text);
            break :blk @import("workspace_projection.zig").page(a, text, page);
        },
        .generic => semanticModulePage(a, bundle.generic.module, page),
        .selected => semanticModulePage(a, bundle.selected.module, page),
        .helper => |index| blk: {
            if (index >= bundle.helpers.len) return error.InvalidReference;
            break :blk semanticModulePage(a, bundle.helpers[index].source.module, page);
        },
        .evidence => blk: {
            const evidence = .{
                .builtin = bundle.evidence,
                .construction = bundle.construction,
                .lineage = bundle.lineage,
            };
            break :blk records.pageRecord(@TypeOf(evidence), a, evidence, page);
        },
        .slice => |selection| blk: {
            var extracted = try horos.source.slice.extract(a, bundle.generic.module, .{
                .entry = selection.function,
                .require_pure = true,
            });
            defer extracted.deinit();
            break :blk semanticModulePage(a, extracted.module(), page);
        },
    };
}

fn semanticModulePage(
    a: std.mem.Allocator,
    module: horos.source.Module,
    page: contracts.workspace.Page,
) !@import("json.zig").Value {
    return records.pageRecord(records.Document, a, .{ .version = 1, .module = module }, page);
}

fn semanticSummary(
    a: std.mem.Allocator,
    bundle: @import("kosmos").RuntimeCompiler.SourceBundle,
    guest: @import("state.zig").Reference,
) ![]u8 {
    const json = @import("json.zig");
    const values = @import("values.zig");
    var result = json.object();
    try json.put(a, &result, "contract", json.string("protean-semantic-source/1"));
    const root = if (bundle.lineage) |lineage| lineage.root else bundle.realization;
    try json.put(a, &result, "root_identity", json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(root, .lower)),
    ));
    try json.put(a, &result, "runtime_identity", json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(bundle.realization, .lower)),
    ));
    inline for (.{ "image", "emitter" }) |field| {
        const id = @field(bundle, field);
        try json.put(a, &result, field, json.string(try a.dupe(u8, &std.fmt.bytesToHex(id, .lower))));
    }
    try json.put(a, &result, "guest_image", try values.toJson(@TypeOf(guest), a, guest));
    try json.put(a, &result, "lineage", try records.project(
        @TypeOf(bundle.lineage),
        a,
        bundle.lineage,
    ));
    inline for (.{ "generic", "selected" }) |field| {
        try json.put(a, &result, field, try semanticModuleSummary(a, @field(bundle, field)));
    }
    var helpers: json.Value = .{ .array = .init(a) };
    for (bundle.helpers) |helper| {
        var item = try semanticModuleSummary(a, helper.source);
        try json.put(a, &item, "role", json.string(@tagName(helper.role)));
        try json.put(a, &item, "image", json.string(
            try a.dupe(u8, &std.fmt.bytesToHex(helper.image, .lower)),
        ));
        try helpers.array.append(item);
    }
    try json.put(a, &result, "helpers", helpers);
    inline for (.{ "requirements", "bridge", "generic_roles", "selected_roles", "generic_pure_entries", "generic_entries", "selected_entries", "parameters", "anchors", "branch_returns", "template_entries" }) |field| {
        const value = @field(bundle, field);
        try json.put(a, &result, field, try records.project(@TypeOf(value), a, value));
    }
    return json.canonical(a, result);
}

fn semanticModuleSummary(
    a: std.mem.Allocator,
    value: @import("kosmos").RuntimeCompiler.SourceModule,
) !@import("json.zig").Value {
    const json = @import("json.zig");
    var result = json.object();
    try json.put(a, &result, "digest", json.string(
        try a.dupe(u8, &std.fmt.bytesToHex(value.digest, .lower)),
    ));
    try json.put(a, &result, "functions", try json.number(a, value.module.functions.len));
    try json.put(a, &result, "entry", try json.number(a, value.module.entry));
    try json.put(a, &result, "executable", .{ .bool = true });
    return result;
}

pub const SemanticValue = struct { schema: []u8, value: []u8 };

pub fn semanticModuleValue(
    a: std.mem.Allocator,
    runtime: *const @import("kosmos").RuntimeArtifact,
    selection: contracts.workspace.SemanticModule,
    references: bool,
) !SemanticValue {
    var exported = try @import("kosmos").RuntimeCompiler.exportSource(a, runtime);
    defer exported.deinit();
    var extracted: ?horos.source.slice.Output = null;
    defer if (extracted) |*owned| owned.deinit();
    const module = switch (selection) {
        .generic => exported.value.generic.module,
        .selected => exported.value.selected.module,
        .helper => |index| blk: {
            if (index >= exported.value.helpers.len) return error.InvalidReference;
            break :blk exported.value.helpers[index].source.module;
        },
        .slice => |selected| blk: {
            extracted = try horos.source.slice.extract(a, exported.value.generic.module, .{
                .entry = selected.function,
                .require_pure = true,
            });
            break :blk extracted.?.module();
        },
    };
    if (references) {
        var indexed = try @import("kosmos").RuntimeCompiler.sourceReferences(a, module);
        defer indexed.deinit();
        const schema = try @import("values.zig").schemaBytes(records.IndexedDocument, a);
        errdefer a.free(schema);
        const value = try contracts.encodeOwned(records.IndexedDocument, a, .{
            .version = 1,
            .module = module,
            .references = indexed.value,
        });
        return .{ .schema = schema, .value = value };
    }
    const schema = try @import("values.zig").schemaBytes(records.Document, a);
    errdefer a.free(schema);
    const value = try contracts.encodeOwned(records.Document, a, .{ .version = 1, .module = module });
    return .{ .schema = schema, .value = value };
}

/// The exact canonical descriptors come from compiled code, never model claims.
pub fn interfaceOf(a: std.mem.Allocator, program: data.activation.Program) !contracts.tool_construction.Interface {
    const entry = program.functions[@intCast(program.roots.entry)];
    if (entry.inputs.len != 1) return error.InvalidInterface;
    return .{
        .input = .{ .bytes = try data.schema.encodeOwned(a, program.schemas, entry.layout.slots[@intCast(entry.inputs[0])]) },
        .output = .{ .bytes = try data.schema.encodeOwned(a, program.schemas, program.roots.result) },
        .failure = .{ .bytes = try data.schema.encodeOwned(a, program.schemas, program.roots.failure) },
    };
}

pub fn build(a: std.mem.Allocator, text: []const u8, cancellation: ?*const std.atomic.Value(bool), diagnostic: *Diagnostic) !Built {
    return buildExposed(a, text, &.{}, cancellation, diagnostic);
}
pub fn buildExposed(a: std.mem.Allocator, text: []const u8, exposures: []const contracts.workspace.Exposure, cancellation: ?*const std.atomic.Value(bool), diagnostic: *Diagnostic) !Built {
    diagnostic.* = .{};
    return buildBody(a, text, exposures, null, cancellation, diagnostic) catch |err| {
        diagnostic.code = err;
        return err;
    };
}

pub fn buildController(a: std.mem.Allocator, text: []const u8, contract: controller.Contract, cancellation: ?*const std.atomic.Value(bool), diagnostic: *Diagnostic) !Built {
    diagnostic.* = .{};
    return buildBody(a, text, &.{}, contract, cancellation, diagnostic) catch |err| {
        diagnostic.code = err;
        return err;
    };
}

fn buildBody(a: std.mem.Allocator, text: []const u8, exposures: []const contracts.workspace.Exposure, controller_contract: ?controller.Contract, cancellation: ?*const std.atomic.Value(bool), diagnostic: *Diagnostic) !Built {
    try canceled(cancellation);
    var document = try records.decode(a, text);
    defer document.deinit();
    diagnostic.phase = .preflight;
    try preflight.validate(a, document.module, &diagnostic.source);
    diagnostic.phase = .authority;
    try rejectSemanticBridge(document.module);
    var registry = protean.admission.Registry.init(a);
    defer registry.deinit();
    var controller_generated: ?controller.Generated = if (controller_contract) |contract| try controller.generate(a, document.module, contract) else null;
    defer if (controller_generated) |*g| g.deinit();
    if (controller_generated) |g| {
        try g.register(&registry);
    } else for (document.module.effects, 0..) |effect, id| {
        // Application/private identities are not a public generated-source API.
        // Generated internal effects carry no environmental authority.
        if (std.mem.startsWith(u8, effect.identity, "agent.") or std.mem.startsWith(u8, effect.identity, "protean.")) return error.ForbiddenEffect;
        if (effect.external) return error.UnboundEffect;
        try registry.classify(id, .internal);
    }
    var generated: ?driver.Generated = if (exposures.len != 0) try driver.generate(a, document.module, exposures) else null;
    defer if (generated) |*g| g.deinit();
    const module = if (controller_generated) |g| g.module else if (generated) |g| g.module else document.module;
    if (controller_generated == null) for (document.module.effects.len..module.effects.len) |id| try registry.classify(id, .read);
    if (generated) |g| try registry.speculate(g.body, g.controls);
    if (controller_generated != null or generated != null)
        try preserveConstructors(a, document.module, module);
    try protean.admission.verify(a, module, &registry);
    try canceled(cancellation);
    diagnostic.phase = .compilation;
    var compiled = try horos.source.lowerObserved(a, module, .{ .diagnostic = &diagnostic.source, .contract = .structural });
    defer compiled.deinit();
    try canceled(cancellation);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const output = arena.allocator();
    diagnostic.phase = .interface;
    const interface = try interfaceOf(output, compiled.program);
    const ports = try output.alloc(PortInterface, if (generated) |g| g.ports.len else 0);
    if (generated) |g| for (g.ports, ports) |port, *destination| {
        const effect = for (compiled.program.effects) |effect| {
            if (std.mem.eql(u8, effect.identity, port.identity)) break effect;
        } else return error.InvalidDriverInterface;
        destination.* = .{
            .identity = .{ .bytes = try output.dupe(u8, port.identity) },
            .class = port.class,
            .argument = .{ .bytes = try data.schema.encodeOwned(output, module.schemas, port.argument) },
            .observation = .{ .bytes = try data.schema.encodeOwned(output, module.schemas, port.observation) },
            .payload = .{ .bytes = try data.schema.encodeOwned(output, compiled.program.schemas, effect.payload) },
            .command = .{ .bytes = try data.schema.encodeOwned(output, compiled.program.schemas, effect.result) },
        };
    };
    const image = try output.alloc(u8, try data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    try canceled(cancellation);
    diagnostic.phase = .complete;
    const descriptor = if (controller_generated) |g| try g.describe(output, compiled.program) else null;
    return .{ .arena = arena, .image = image, .interface = interface, .ports = ports, .controller = descriptor };
}

fn preserveConstructors(a: std.mem.Allocator, before: horos.source.Module, after: horos.source.Module) !void {
    const constructors = horos.source.constructor_bindings;
    for (before.values) |value| {
        if (constructors.raw(value) == null) continue;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var work: u64 = std.math.maxInt(u64);
        const old = try constructors.admit(a, arena.allocator(), before, &work);
        const new = try constructors.admit(a, arena.allocator(), after, &work);
        try constructors.validate(before, old, new, .{}, &work);
        return;
    }
}

fn rejectSemanticBridge(module: horos.source.Module) !void {
    for (module.effects) |effect| {
        if (std.mem.startsWith(u8, effect.identity, "kosmos.semantic-service")) {
            return error.ForbiddenEffect;
        }
    }
}

fn canceled(flag: ?*const std.atomic.Value(bool)) !void {
    if (flag) |f| if (f.load(.acquire)) return error.Canceled;
}

test "general source builds through actual checked lowering and rejects private authority" {
    _ = @import("dynamic_values.zig");
    const a = std.testing.allocator;
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const module = try horos.source.examples.lexical(&builder);
    const text = try records.encode(a, module);
    defer a.free(text);
    var diagnostic: Diagnostic = .{};
    var compiled = try build(a, text, null, &diagnostic);
    defer compiled.deinit();
    try std.testing.expectEqual(.complete, diagnostic.phase);
    var image = try data.program_image.decode(a, compiled.image);
    defer image.deinit();
    _ = try builder.effect(.{ .identity = "agent.model.invoke.v11", .payload = module.failure, .result = module.failure, .external = false });
    const forged = try records.encode(a, builder.module(module.entry, module.failure));
    defer a.free(forged);
    try std.testing.expectError(error.ForbiddenEffect, build(a, forged, null, &diagnostic));
    try std.testing.expectEqual(.authority, diagnostic.phase);
}

test "source ingestion rejects unused malformed declarations before lowering" {
    const a = std.testing.allocator;
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const module = try horos.source.examples.lexical(&builder);
    _ = try builder.value(.{ .schema = 0, .expression = .{ .primitive = .{ .opcode = .field, .operands = &.{9999}, .immediate = 0 } } });
    const text = try records.encode(a, builder.module(module.entry, module.failure));
    defer a.free(text);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidReference, build(a, text, null, &diagnostic));
    try std.testing.expectEqual(.preflight, diagnostic.phase);
    try std.testing.expectEqual(builder.values.items.len - 1, diagnostic.source.value.?);
    builder.values.items.len -= 1;
    _ = try builder.term(.{ .yield_then = builder.terms.items.len });
    const cyclic = try records.encode(a, builder.module(module.entry, module.failure));
    defer a.free(cyclic);
    try std.testing.expectError(error.InvalidReference, build(a, cyclic, null, &diagnostic));
    try std.testing.expectEqual(.preflight, diagnostic.phase);
}
