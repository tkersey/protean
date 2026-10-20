//! One host-side compilation emits the canonical image and its ordinary assets.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const json_schema = protean.contracts.json;
const Schema = struct { schema_id: []const u8, wire_sha256: []const u8, wire_base64url: []const u8, json: std.json.Value };
const Capability = struct { identity: []const u8, resource_role: []const u8, payload_sha256: []const u8, resume_sha256: []const u8 };
const Resource = struct { id: []const u8, version: []const u8, media_type: []const u8, sha256: []const u8, bytes: usize, base64url: []const u8 };

fn digest(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn base64(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const result = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    return std.base64.url_safe_no_pad.Encoder.encode(result, bytes);
}
fn schema(comptime T: type, a: std.mem.Allocator, id: []const u8) !Schema {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const root = try protean.contracts.schema(T, &b);
    const wire = try horos.data.schema.encodeOwned(a, b.schemas.items, root);
    return .{
        .schema_id = id,
        .wire_sha256 = try digest(a, wire),
        .wire_base64url = try base64(a, wire),
        .json = try std.json.parseFromSliceLeaky(std.json.Value, a, &json_schema.ClientSchema(T).value, .{ .parse_numbers = false }),
    };
}

fn schemaWire(comptime T: type, a: std.mem.Allocator) ![]const u8 {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const root = try protean.contracts.schema(T, &builder);
    return horos.data.schema.encodeOwned(a, builder.schemas.items, root);
}

/// Native roles bind the complete semantic contract. Legacy identity-only
/// declarations remain valid when every matching declaration names the same
/// role. Specializations with different roles supply both Payload and Reply;
/// declaration order never selects authority.
pub fn capabilityMetadata(comptime declarations: anytype, a: std.mem.Allocator, program: horos.data.activation.Program) ![]Capability {
    var result: std.ArrayList(Capability) = .empty;
    var used: [declarations.len]bool = @splat(false);
    for (program.effects) |effect| {
        if (!effect.external) continue;
        const controller = protean.contracts.controller;
        if (std.mem.eql(u8, effect.identity, controller.boot_identity) or std.mem.eql(u8, effect.identity, controller.offer_identity) or std.mem.eql(u8, effect.identity, controller.handoff_identity)) continue;
        const imported = if (std.mem.startsWith(u8, effect.identity, controller.effect_prefix)) std.meta.stringToEnum(controller.Import, effect.identity[controller.effect_prefix.len..]) else null;
        const payload_schema = if (imported == .deliberate) program.schemas[@intCast(effect.payload)].product[0] else effect.payload;
        const payload = try horos.data.schema.encodeOwned(a, program.schemas, payload_schema);
        const reply = try horos.data.schema.encodeOwned(a, program.schemas, effect.result);
        var role: ?[]const u8 = null;
        var identity = effect.identity;
        inline for (declarations, 0..) |declaration, index| {
            const typed = @hasField(@TypeOf(declaration), "Payload");
            if (typed != @hasField(@TypeOf(declaration), "Reply")) @compileError("native capability requires both Payload and Reply");
            const controller_matches = if (@hasField(@TypeOf(declaration), "controller_import")) imported == @as(controller.Import, declaration.controller_import) else false;
            if (std.mem.eql(u8, declaration.identity, effect.identity) or controller_matches) {
                const matches = if (typed)
                    std.mem.eql(u8, payload, try schemaWire(declaration.Payload, a)) and std.mem.eql(u8, reply, try schemaWire(declaration.Reply, a))
                else
                    true;
                if (matches) {
                    if (role) |prior| if (!std.mem.eql(u8, prior, declaration.resource_role)) return error.AmbiguousNativeCapability;
                    role = declaration.resource_role;
                    identity = declaration.identity;
                    used[index] = true;
                }
            }
        }
        try result.append(a, .{ .identity = identity, .resource_role = role orelse return error.UndeclaredNativeCapability, .payload_sha256 = try digest(a, payload), .resume_sha256 = try digest(a, reply) });
    }
    if (result.items.len != declarations.len) return error.UnusedOrDuplicateCapability;
    for (used) |matched| if (!matched) return error.UnusedOrDuplicateCapability;
    return result.toOwnedSlice(a);
}

const ControllerMetadata = struct { source_records: []const u8, descriptor_base64url: []const u8 };
const Emitted = struct { image: []const u8, controller: ?ControllerMetadata = null };
fn emitProgram(comptime definition: type, a: std.mem.Allocator) !Emitted {
    if (comptime @hasDecl(definition, "ControllerSystem")) {
        const construction = @import("construction");
        var builder = horos.source.Builder.init(a);
        defer builder.deinit();
        var registry = protean.admission.Registry.init(a);
        defer registry.deinit();
        const context = try protean.Context.init(&builder, &registry);
        const module = try definition.ControllerSystem.Application.emit(context);
        const source = try construction.encodeSource(a, module);
        var signatures: std.ArrayList(protean.contracts.controller.Signature) = .empty;
        for (module.effects) |effect| {
            const prefix = protean.contracts.controller.import_prefix;
            if (!std.mem.startsWith(u8, effect.identity, prefix)) continue;
            const imported = std.meta.stringToEnum(protean.contracts.controller.Import, effect.identity[prefix.len..]) orelse return error.UnknownControllerImport;
            const payload = if (imported == .deliberate) module.schemas[@intCast(effect.payload)].product[0] else effect.payload;
            try signatures.append(a, .{
                .import = imported,
                .payload = .{ .bytes = try horos.data.schema.encodeOwned(a, module.schemas, payload) },
                .result = .{ .bytes = try horos.data.schema.encodeOwned(a, module.schemas, effect.result) },
                .native_result = if (imported == .deliberate) .{ .bytes = try horos.data.schema.encodeOwned(a, module.schemas, module.schemas[@intCast(effect.result)].product[0]) } else null,
            });
        }
        const contract: protean.contracts.controller.Contract = .{
            .result = .{ .bytes = try schemaWire(definition.ControllerSystem.Result, a) },
            .failure = .{ .bytes = try schemaWire(definition.ControllerSystem.Failure, a) },
            .imports = .{ .items = signatures.items },
        };
        var diagnostic: construction.Diagnostic = .{};
        var built = construction.buildController(a, source, contract, null, &diagnostic) catch |err| {
            std.log.err("controller construction {s}: phase={s}, function={?d}, term={?d}, value={?d}", .{ @errorName(err), @tagName(diagnostic.phase), diagnostic.source.function, diagnostic.source.term, diagnostic.source.value });
            return err;
        };
        defer built.deinit();
        const descriptor = try protean.contracts.encodeOwned(protean.contracts.controller.Descriptor, a, built.controller.?);
        return .{ .image = try a.dupe(u8, built.image), .controller = .{ .source_records = source, .descriptor_base64url = try base64(a, descriptor) } };
    }
    var compiled = try protean.compile(a, definition.System);
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);
    return .{ .image = image };
}

pub fn main(init: std.process.Init) !void {
    return write(@import("definition"), @import("application_types"), init);
}

/// The standalone build helper and the shared repository fixture compiler use
/// this same writer; application selection changes inputs, not asset semantics.
pub fn write(comptime definition: type, comptime types: type, init: std.process.Init) !void {
    comptime {
        if (definition.System.InitialArgs != types.Input or definition.System.Result != types.Output or definition.System.Failure != types.Failure)
            @compileError("native mappings must name the actual authored system's input, output and failure types");
    }
    var args = init.minimal.args.iterate();
    _ = args.next();
    const image_path = args.next() orelse return error.ExpectedImagePath;
    const application_path = args.next() orelse return error.ExpectedApplicationPath;
    if (args.next() != null) return error.UnexpectedArgument;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const emitted = try emitProgram(definition, a);
    const image = emitted.image;
    var compiled = try horos.data.program_image.decode(a, image);
    defer compiled.deinit();
    const capabilities = try capabilityMetadata(definition.capabilities, a, compiled.program);
    var resources: std.ArrayList(Resource) = .empty;
    inline for (definition.resources) |resource| {
        for (resources.items) |prior| if (std.mem.eql(u8, prior.id, resource.id)) return error.DuplicateResource;
        try resources.append(a, .{ .id = resource.id, .version = resource.version, .media_type = resource.media_type, .sha256 = try digest(a, resource.bytes), .bytes = resource.bytes.len, .base64url = try base64(a, resource.bytes) });
    }
    if (comptime @hasDecl(definition, "generatedResources")) {
        for (try definition.generatedResources(a)) |resource| {
            for (resources.items) |prior| if (std.mem.eql(u8, prior.id, resource.id)) return error.DuplicateResource;
            try resources.append(a, .{ .id = resource.id, .version = resource.version, .media_type = resource.media_type, .sha256 = try digest(a, resource.bytes), .bytes = resource.bytes.len, .base64url = try base64(a, resource.bytes) });
        }
    }
    const metadata = .{
        .format = "agent-native-application/v1",
        .application_id = types.application_id,
        .application_version = types.application_version,
        .program_sha256 = try digest(a, image),
        .program_identity = try a.dupe(u8, &std.fmt.bytesToHex(try horos.data.program_image.identity(a, compiled.program), .lower)),
        .client_mapping = json_schema.client_mapping,
        .input = try schema(types.Input, a, types.input_schema_id),
        .output = try schema(types.Output, a, types.output_schema_id),
        .failure = try schema(types.Failure, a, types.failure_schema_id),
        .answer = try schema(types.Answer, a, types.answer_schema_id),
        .message = try schema(types.Message, a, types.message_schema_id),
        .capabilities = capabilities,
        .resources = resources.items,
        .controller = emitted.controller,
    };
    var writer = std.Io.Writer.Allocating.init(a);
    try std.json.Stringify.value(metadata, .{}, &writer.writer);
    if (comptime @hasDecl(types, "support_types")) {
        var value = try std.json.parseFromSliceLeaky(std.json.Value, a, writer.written(), .{ .allocate = .alloc_always });
        var support: std.json.Value = .{ .object = .empty };
        inline for (types.support_types) |entry| {
            const wire = try schemaWire(entry.T, a);
            var item: std.json.Value = .{ .object = .empty };
            try item.object.put(a, "wire_sha256", .{ .string = try digest(a, wire) });
            try item.object.put(a, "wire_base64url", .{ .string = try base64(a, wire) });
            try support.object.put(a, entry.name, item);
        }
        try value.object.put(a, "support", support);
        writer.clearRetainingCapacity();
        try std.json.Stringify.value(value, .{}, &writer.writer);
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = image_path, .data = image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = application_path, .data = writer.written() });
}
