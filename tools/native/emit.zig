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
        const payload = try horos.data.schema.encodeOwned(a, program.schemas, effect.payload);
        const reply = try horos.data.schema.encodeOwned(a, program.schemas, effect.result);
        var role: ?[]const u8 = null;
        inline for (declarations, 0..) |declaration, index| {
            const typed = @hasField(@TypeOf(declaration), "Payload");
            if (typed != @hasField(@TypeOf(declaration), "Reply")) @compileError("native capability requires both Payload and Reply");
            if (std.mem.eql(u8, declaration.identity, effect.identity)) {
                const matches = if (typed)
                    std.mem.eql(u8, payload, try schemaWire(declaration.Payload, a)) and std.mem.eql(u8, reply, try schemaWire(declaration.Reply, a))
                else
                    true;
                if (matches) {
                    if (role) |prior| if (!std.mem.eql(u8, prior, declaration.resource_role)) return error.AmbiguousNativeCapability;
                    role = declaration.resource_role;
                    used[index] = true;
                }
            }
        }
        try result.append(a, .{ .identity = effect.identity, .resource_role = role orelse return error.UndeclaredNativeCapability, .payload_sha256 = try digest(a, payload), .resume_sha256 = try digest(a, reply) });
    }
    if (result.items.len != declarations.len) return error.UnusedOrDuplicateCapability;
    for (used) |matched| if (!matched) return error.UnusedOrDuplicateCapability;
    return result.toOwnedSlice(a);
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
    var compiled = try protean.compile(a, definition.System);
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    _ = try compiled.encode(a, image);

    const capabilities = try capabilityMetadata(definition.capabilities, a, compiled.program);
    var resources: std.ArrayList(Resource) = .empty;
    var resource_bytes: usize = 0;
    inline for (definition.resources) |resource| {
        resource_bytes = try std.math.add(usize, resource_bytes, resource.bytes.len);
        if (resource.bytes.len > 1024 * 1024 or resource_bytes > 8 * 1024 * 1024) return error.AssetCapacity;
        for (resources.items) |prior| if (std.mem.eql(u8, prior.id, resource.id)) return error.DuplicateResource;
        try resources.append(a, .{ .id = resource.id, .version = resource.version, .media_type = resource.media_type, .sha256 = try digest(a, resource.bytes), .bytes = resource.bytes.len, .base64url = try base64(a, resource.bytes) });
    }
    if (comptime @hasDecl(definition, "generatedResources")) {
        for (try definition.generatedResources(a)) |resource| {
            resource_bytes = try std.math.add(usize, resource_bytes, resource.bytes.len);
            if (resource.bytes.len > 1024 * 1024 or resource_bytes > 8 * 1024 * 1024) return error.AssetCapacity;
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
        .client_mapping = json_schema.clientMapping(.{ types.Input, types.Output, types.Failure, types.Answer, types.Message }),
        .input = try schema(types.Input, a, types.input_schema_id),
        .output = try schema(types.Output, a, types.output_schema_id),
        .failure = try schema(types.Failure, a, types.failure_schema_id),
        .answer = try schema(types.Answer, a, types.answer_schema_id),
        .message = try schema(types.Message, a, types.message_schema_id),
        .capabilities = capabilities,
        .resources = resources.items,
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
