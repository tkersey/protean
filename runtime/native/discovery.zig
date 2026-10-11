//! Embedded application/handler agreement and offline protocol discovery.
const std = @import("std");
const data = @import("horos_data");
const json = @import("json.zig");
const values = @import("values.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const contracts = @import("protean_contracts");

pub const Assets = struct { image: []const u8, application: []const u8, manifest: []const u8 };
/// Non-secret identities derived from the currently admitted launch profile.
pub const LaunchProfile = struct { id: []const u8, sha256: [32]u8, resource_identity: [32]u8 };

pub const Artifact = struct {
    bytes: []const u8,
    sha256: [32]u8,
    schema_id: []const u8 = "",

    fn freeze(a: std.mem.Allocator, value: json.Value, schema_id: []const u8) !Artifact {
        const bytes = try json.canonical(a, value);
        var sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &sha256, .{});
        return .{ .bytes = bytes, .sha256 = sha256, .schema_id = schema_id };
    }
    fn reference(self: Artifact, a: std.mem.Allocator) !json.Value {
        var result = json.object();
        const id = try a.dupe(u8, &std.fmt.bytesToHex(self.sha256, .lower));
        try json.put(a, &result, "artifact_id", json.string(id));
        try json.put(a, &result, "sha256", json.string(id));
        try json.put(a, &result, "bytes", json.string(try std.fmt.allocPrint(a, "{d}", .{self.bytes.len})));
        try json.put(a, &result, "media_type", json.string("application/json"));
        try json.put(a, &result, "schema_id", json.string(self.schema_id));
        try json.put(a, &result, "retention", json.string("embedded"));
        return result;
    }
};

pub const ArtifactRequest = struct { id: [32]u8, offset: u64, length: u32 };
pub fn artifactRequest(params: json.Value) !ArtifactRequest {
    const id = try json.text(json.get(params, "artifact_id") orelse return error.InvalidParams);
    if (id.len != 64) return error.InvalidParams;
    var request: ArtifactRequest = .{
        .id = undefined,
        .offset = try json.decimal(u64, json.get(params, "offset") orelse return error.InvalidParams),
        .length = try json.decimal(u32, json.get(params, "length") orelse return error.InvalidParams),
    };
    if (request.length == 0 or request.length > (protocol.Limits{}).artifact_chunk_bytes) return error.InvalidParams;
    _ = std.fmt.hexToBytes(&request.id, id) catch return error.InvalidParams;
    return request;
}

/// Shared bounded wire projection; callers own artifact lookup and authority.
pub fn artifactChunk(a: std.mem.Allocator, artifact: Artifact, offset: u64, length: u32) !json.Value {
    if (length == 0 or length > (protocol.Limits{}).artifact_chunk_bytes or offset > artifact.bytes.len) return error.InvalidParams;
    const start: usize = @intCast(offset);
    const end = start + @min(length, artifact.bytes.len - start);
    const chunk = artifact.bytes[start..end];
    return artifactRange(a, artifact.sha256, artifact.bytes.len, offset, chunk);
}

/// Project a range already acquired and integrity-checked by its owning store.
pub fn artifactRange(a: std.mem.Allocator, sha256: [32]u8, total: u64, offset: u64, chunk: []const u8) !json.Value {
    if (offset > total or chunk.len > total - offset or chunk.len > (protocol.Limits{}).artifact_chunk_bytes) return error.InvalidParams;
    const end = offset + chunk.len;
    const base64 = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(chunk.len));
    var result = json.object();
    try json.put(a, &result, "encoding", json.string("base64url"));
    try json.put(a, &result, "data", json.string(std.base64.url_safe_no_pad.Encoder.encode(base64, chunk)));
    try json.put(a, &result, "sha256", json.string(try a.dupe(u8, &std.fmt.bytesToHex(sha256, .lower))));
    try json.put(a, &result, "total_bytes", json.string(try std.fmt.allocPrint(a, "{d}", .{total})));
    try json.put(a, &result, "next_offset", json.string(try std.fmt.allocPrint(a, "{d}", .{end})));
    try json.put(a, &result, "eof", .{ .bool = end == total });
    return result;
}

fn publicMetadata(a: std.mem.Allocator, metadata: json.Value) !json.Value {
    var result = json.object();
    for ([_][]const u8{ "application_id", "application_version", "client_mapping", "input", "output", "failure", "answer", "message", "capabilities" }) |key|
        try json.put(a, &result, key, metadata.object.get(key) orelse return error.InvalidAssets);
    return result;
}

pub fn digest(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

pub const Application = struct {
    arena: std.heap.ArenaAllocator,
    metadata: json.Value,
    manifest: json.Value,
    manifest_id: []const u8,
    image_identity: [32]u8,
    protocol_schema: json.Value = .null,
    protocol_schema_sha256: []const u8 = "",
    public_metadata: json.Value = .null,
    schema_artifacts: [2]?Artifact = @splat(null),
    execution_mode: enum { offline, live } = .offline,

    pub fn init(comptime Types: type, a: std.mem.Allocator, assets: Assets, handlers: registry.Registry) !Application {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const storage = arena.allocator();
        const metadata = try json.parseAsset(storage, assets.application, 16 * 1024 * 1024);
        const manifest = try json.parse(storage, assets.manifest, .{ .bytes = 256 * 1024 });
        try sameField(metadata.value, "format", "agent-native-application/v1");
        try sameField(metadata.value, "application_id", Types.application_id);
        try sameField(metadata.value, "application_version", Types.application_version);
        const client_mapping = values.schemas.clientMapping(.{ Types.Input, Types.Output, Types.Failure, Types.Answer, Types.Message });
        try sameField(metadata.value, "client_mapping", client_mapping);
        sameField(metadata.value, "program_sha256", try digest(storage, assets.image)) catch return error.ApplicationProgramDigestMismatch;
        try sameField(manifest.value, "format", "agent-native-build/v1");
        try sameField(manifest.value, "client_mapping", client_mapping);
        try sameField(manifest.value, "state_format", std.fmt.comptimePrint("agent-native-state/{d}", .{@import("store.zig").format}));
        sameField(manifest.value, "program_sha256", try digest(storage, assets.image)) catch return error.ManifestProgramDigestMismatch;
        try sameField(manifest.value, "application_assets_sha256", try digest(storage, assets.application));
        const admitted = try data.program_image.Admitted.decode(storage, assets.image);
        defer admitted.deinit();
        const image_identity = admitted.identity();
        try sameField(metadata.value, "program_identity", &std.fmt.bytesToHex(image_identity, .lower));
        inline for (.{ .{ "input", Types.Input, Types.input_schema_id }, .{ "output", Types.Output, Types.output_schema_id }, .{ "failure", Types.Failure, Types.failure_schema_id }, .{ "answer", Types.Answer, Types.answer_schema_id }, .{ "message", Types.Message, Types.message_schema_id } }) |item| {
            const schema = json.get(metadata.value, item[0]) orelse return error.InvalidAssets;
            try sameField(schema, "schema_id", item[2]);
            const bytes = try values.schemaBytes(item[1], storage);
            try sameField(schema, "wire_sha256", try digest(storage, bytes));
            const client = try json.parseAsset(storage, &values.schemas.ClientSchema(item[1]).value, 16 * 1024 * 1024);
            if (!std.mem.eql(u8, try json.canonical(storage, client.value), try json.canonical(storage, json.get(schema, "json") orelse return error.InvalidAssets)))
                return error.ClientJsonSchemaMismatch;
        }
        const capabilities = json.get(metadata.value, "capabilities") orelse return error.InvalidAssets;
        if (capabilities != .array or capabilities.array.items.len != handlers.entries.len) return error.CapabilityCountMismatch;
        for (handlers.entries) |entry| {
            switch (entry.declaration.kind) {
                .question => {
                    if (!std.mem.eql(u8, entry.declaration.answer_schema_id.?, Types.answer_schema_id) or
                        !std.mem.eql(u8, entry.resume_schema, try values.schemaBytes(Types.Answer, storage))) return error.QuestionSchemaMismatch;
                },
                .inbox => {
                    if (!std.mem.eql(u8, entry.payload_schema, try values.schemaBytes(void, storage)) or
                        !std.mem.eql(u8, entry.resume_schema, try values.schemaBytes(contracts.InboxReply(Types.Message), storage))) return error.InboxSchemaMismatch;
                },
                .leaf => {},
            }
            try validateCapability(storage, capabilities.array.items, entry);
        }
        const protocol_schema = try @import("schemas.zig").document(storage, metadata.value, .{});
        const public_metadata = try publicMetadata(storage, metadata.value);
        const application_artifact = try Artifact.freeze(storage, public_metadata, "agent-native-discovery.application.v1");
        const protocol_artifact = try Artifact.freeze(storage, protocol_schema, "agent-host.protocol-schema.v1");
        const manifest_id = try digest(storage, assets.manifest);
        const protocol_digest = try storage.dupe(u8, &std.fmt.bytesToHex(protocol_artifact.sha256, .lower));
        return .{ .arena = arena, .metadata = metadata.value, .manifest = manifest.value, .manifest_id = manifest_id, .image_identity = image_identity, .protocol_schema = protocol_schema, .protocol_schema_sha256 = protocol_digest, .public_metadata = public_metadata, .schema_artifacts = .{ application_artifact, protocol_artifact } };
    }
    pub fn deinit(self: *Application) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn schemaArtifact(self: Application, id: [32]u8) !Artifact {
        for (self.schema_artifacts) |candidate| if (candidate) |artifact| {
            if (std.mem.eql(u8, &id, &artifact.sha256)) return artifact;
        };
        return error.ArtifactUnavailable;
    }
    pub fn readSchemaArtifact(self: Application, a: std.mem.Allocator, params: json.Value) !json.Value {
        if (json.get(params, "question_id") != null) return error.InvalidParams;
        const request = try artifactRequest(params);
        return artifactChunk(a, try self.schemaArtifact(request.id), request.offset, request.length);
    }

    /// This projection is deliberately bounded; larger schema/resource assets
    /// are retained for the authorized artifact service rather than truncated.
    pub fn describe(self: Application, a: std.mem.Allocator, params: json.Value, launch: ?LaunchProfile) !json.Value {
        if (json.get(params, "application_id")) |id| {
            const expected = try json.text(self.metadata.object.get("application_id").?);
            if (id != .string or !std.mem.eql(u8, id.string, expected)) return error.NotFound;
        }
        const cursor: usize = if (json.get(params, "cursor")) |value| try json.decimal(usize, value) else 0;
        const limit: usize = if (json.get(params, "limit")) |value| blk: {
            if (value != .number_string) return error.InvalidParams;
            break :blk try json.numberInteger(usize, value.number_string);
        } else 16;
        if (limit == 0 or limit > 16) return error.InvalidParams;
        const info = @typeInfo(protocol.Method).@"enum";
        if (cursor > info.field_names.len) return error.InvalidParams;
        const end = @min(info.field_names.len, cursor + limit);
        var methods: std.array_list.Managed(json.Value) = .init(a);
        inline for (info.field_names, 0..) |name, i| {
            if (i >= cursor and i < end) {
                var method = json.object();
                try json.put(a, &method, "name", json.string(name));
                const fields = protocol.fields(@field(protocol.Method, name));
                var required: std.array_list.Managed(json.Value) = .init(a);
                var optional: std.array_list.Managed(json.Value) = .init(a);
                for (fields.required) |key| try required.append(json.string(key));
                for (fields.optional) |key| try optional.append(json.string(key));
                try json.put(a, &method, "required_fields", .{ .array = required });
                try json.put(a, &method, "optional_fields", .{ .array = optional });
                try json.put(a, &method, "params_schema", json.string("#/$defs/" ++ name ++ ".params"));
                try json.put(a, &method, "result_schema", json.string("#/$defs/" ++ name ++ ".result"));
                try methods.append(method);
            }
        }
        var result = json.object();
        try json.put(a, &result, "methods", .{ .array = methods });
        try json.put(a, &result, "next_cursor", if (end < info.field_names.len) json.string(try std.fmt.allocPrint(a, "{d}", .{end})) else .null);
        var app = json.object();
        for ([_][]const u8{ "application_id", "application_version", "client_mapping" }) |key| try json.put(a, &app, key, self.public_metadata.object.get(key).?);
        try json.put(a, &app, "metadata_ref", try self.schema_artifacts[0].?.reference(a));
        try json.put(a, &result, "application", app);
        try json.put(a, &result, "execution_mode", json.string(@tagName(self.execution_mode)));
        var profile: json.Value = .null;
        if (launch) |admitted| {
            profile = json.object();
            try json.put(a, &profile, "id", json.string(admitted.id));
            try json.put(a, &profile, "sha256", json.string(try a.dupe(u8, &std.fmt.bytesToHex(admitted.sha256, .lower))));
            try json.put(a, &profile, "resource_identity", json.string(try a.dupe(u8, &std.fmt.bytesToHex(admitted.resource_identity, .lower))));
        }
        try json.put(a, &result, "profile", profile);
        const protocol_ref = try self.schema_artifacts[1].?.reference(a);
        try json.put(a, &result, "protocol_schema_ref", protocol_ref);
        if (!try fitsDescription(a, result)) return error.Capacity;
        // Inline only when the complete projection fits. Independent per-asset
        // limits do not compose into a bounded response (or a 16-call batch).
        if (self.schema_artifacts[0].?.bytes.len <= (protocol.Limits{}).inline_bytes) {
            try json.put(a, &result, "application", self.public_metadata);
            if (!try fitsDescription(a, result)) try json.put(a, &result, "application", app);
        }
        if (self.schema_artifacts[1].?.bytes.len <= (protocol.Limits{}).inline_bytes) {
            _ = result.object.swapRemove("protocol_schema_ref");
            try json.put(a, &result, "protocol_schema", self.protocol_schema);
            if (!try fitsDescription(a, result)) {
                _ = result.object.swapRemove("protocol_schema");
                try json.put(a, &result, "protocol_schema_ref", protocol_ref);
            }
        }
        return result;
    }
};

fn validateCapability(a: std.mem.Allocator, capabilities: []const json.Value, entry: registry.Entry) !void {
    var matches: usize = 0;
    for (capabilities) |capability| {
        const id = json.get(capability, "identity") orelse return error.InvalidAssets;
        if (id != .string or !std.mem.eql(u8, id.string, entry.declaration.identity)) continue;
        const role = try json.text(json.get(capability, "resource_role") orelse return error.InvalidAssets);
        const payload = try json.text(json.get(capability, "payload_sha256") orelse return error.InvalidAssets);
        const resume_schema = try json.text(json.get(capability, "resume_sha256") orelse return error.InvalidAssets);
        if (std.mem.eql(u8, role, entry.declaration.resource_role) and
            std.mem.eql(u8, payload, try digest(a, entry.payload_schema)) and
            std.mem.eql(u8, resume_schema, try digest(a, entry.resume_schema))) matches += 1;
    }
    if (matches != 1) return error.CapabilityMetadataMismatch;
}

fn fitsDescription(a: std.mem.Allocator, value: json.Value) !bool {
    return json.fits(a, value, json.projection_limits);
}

pub fn sameField(object: json.Value, name: []const u8, expected: []const u8) !void {
    const field = json.get(object, name) orelse return error.InvalidAssets;
    if (field != .string or !std.mem.eql(u8, field.string, expected)) {
        if (std.mem.eql(u8, name, "program_sha256")) return error.ProgramDigestMismatch;
        if (std.mem.eql(u8, name, "program_identity")) return error.ProgramIdentityMismatch;
        if (std.mem.eql(u8, name, "application_assets_sha256")) return error.ApplicationAssetsMismatch;
        if (std.mem.eql(u8, name, "application_id")) return error.ApplicationIdentityMismatch;
        if (std.mem.eql(u8, name, "state_format")) return error.StateFormatMismatch;
        if (std.mem.eql(u8, name, "wire_sha256")) return error.ClientSchemaMismatch;
        if (std.mem.eql(u8, name, "payload_sha256")) return error.CapabilityPayloadMismatch;
        if (std.mem.eql(u8, name, "resume_sha256")) return error.CapabilityResumeMismatch;
        if (std.mem.eql(u8, name, "resource_role")) return error.CapabilityRoleMismatch;
        return error.InvalidAssets;
    }
}

test "oversized discovery stays bounded and its immutable schemas round-trip through artifact chunks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var metadata = json.object();
    try json.put(a, &metadata, "application_id", json.string("large-schema"));
    try json.put(a, &metadata, "application_version", json.string("1"));
    try json.put(a, &metadata, "client_mapping", json.string("agent-client-values/1.0"));
    const padding = try a.alloc(u8, 70 * 1024);
    @memset(padding, 'x');
    var schema = json.object();
    try json.put(a, &schema, "type", json.string("string"));
    try json.put(a, &schema, "description", json.string(padding));
    for ([_][]const u8{ "input", "output", "failure", "answer", "message" }) |key| try json.put(a, &metadata, key, schema);
    try json.put(a, &metadata, "capabilities", .{ .array = .init(a) });
    const artifacts = [2]?Artifact{ try Artifact.freeze(a, metadata, "application"), try Artifact.freeze(a, schema, "protocol") };
    const application: Application = .{ .arena = .init(a), .metadata = metadata, .manifest = .null, .manifest_id = "test", .image_identity = @splat(0), .public_metadata = metadata, .protocol_schema = schema, .schema_artifacts = artifacts };
    const description = try application.describe(a, json.object(), null);
    try std.testing.expect((try json.canonical(a, description)).len < (protocol.Limits{}).inline_bytes);
    try std.testing.expect(json.get(description, "protocol_schema") == null);
    try std.testing.expect(json.get(description.object.get("application").?, "metadata_ref") != null);
    for (artifacts) |candidate| {
        const artifact = try application.schemaArtifact(candidate.?.sha256);
        var offset: usize = 0;
        while (offset < artifact.bytes.len) {
            const chunk = try artifactChunk(a, artifact, offset, 32768);
            const encoded = chunk.object.get("data").?.string;
            const decoder = std.base64.url_safe_no_pad.Decoder;
            const decoded = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
            try decoder.decode(decoded, encoded);
            try std.testing.expectEqualSlices(u8, artifact.bytes[offset..][0..decoded.len], decoded);
            offset += decoded.len;
            try std.testing.expectEqual(offset, try json.decimal(usize, chunk.object.get("next_offset").?));
            try std.testing.expectEqual(offset == artifact.bytes.len, chunk.object.get("eof").?.bool);
        }
        try std.testing.expectError(error.InvalidParams, artifactChunk(a, artifact, artifact.bytes.len + 1, 1));
        try std.testing.expectError(error.InvalidParams, artifactChunk(a, artifact, 0, 32769));
    }
    try std.testing.expectError(error.ArtifactUnavailable, application.schemaArtifact(@splat(0)));
}

test "discovery budgets the combined description before composing a full batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 128, 11 * 1024 }) |size| {
        var metadata = json.object();
        try json.put(a, &metadata, "application_id", json.string("combined-schema"));
        try json.put(a, &metadata, "application_version", json.string("1"));
        try json.put(a, &metadata, "client_mapping", json.string("agent-client-values/1.0"));
        const padding = try a.alloc(u8, size);
        @memset(padding, 'x');
        var schema = json.object();
        try json.put(a, &schema, "type", json.string("string"));
        try json.put(a, &schema, "description", json.string(padding));
        for ([_][]const u8{ "input", "output", "failure", "answer", "message" }) |key| try json.put(a, &metadata, key, schema);
        try json.put(a, &metadata, "capabilities", .{ .array = .init(a) });
        const artifacts = [2]?Artifact{ try Artifact.freeze(a, metadata, "application"), try Artifact.freeze(a, schema, "protocol") };
        for (artifacts) |artifact| try std.testing.expect(artifact.?.bytes.len < (protocol.Limits{}).inline_bytes);
        const application: Application = .{ .arena = .init(a), .metadata = metadata, .manifest = .null, .manifest_id = "test", .image_identity = @splat(0), .public_metadata = metadata, .protocol_schema = schema, .schema_artifacts = artifacts };
        const description = try application.describe(a, json.object(), .{ .id = "fixed", .sha256 = @splat(2), .resource_identity = @splat(3) });
        try std.testing.expect((try json.canonical(a, description)).len <= (protocol.Limits{}).inline_bytes);
        try std.testing.expectEqual(size == 128, json.get(description, "protocol_schema") != null);
        if (json.get(description, "protocol_schema_ref")) |reference| {
            try std.testing.expectEqualStrings(try digest(a, artifacts[1].?.bytes), reference.object.get("sha256").?.string);
        }
        // Escaping a maximal string ID also consumes the shared frame budget.
        var id: [128]u8 = @splat(1);
        var replies: std.array_list.Managed(json.Value) = .init(a);
        for (0..16) |i| {
            id[0] = @intCast(i + 1);
            try replies.append(try protocol.response(a, json.string(try a.dupe(u8, &id)), description));
        }
        const encoded = try json.canonical(a, .{ .array = replies });
        try std.testing.expect(encoded.len + 1 <= (protocol.Limits{}).frame_bytes);
    }
}

test "nested authored schemas remain available beyond the peer frame depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const U1 = union(enum) { value: void };
    const U2 = union(enum) { value: U1 };
    const U3 = union(enum) { value: U2 };
    const U4 = union(enum) { value: U3 };
    const U5 = union(enum) { value: U4 };
    const U6 = union(enum) { value: U5 };
    const U7 = union(enum) { value: U6 };
    const U8 = union(enum) { value: U7 };
    inline for (.{ ????????bool, U8 }) |T| {
        const bytes = &values.schemas.ClientSchema(T).value;
        const schema = (try json.parseAsset(a, bytes, 16 * 1024 * 1024)).value;
        var metadata = json.object();
        try json.put(a, &metadata, "application_id", json.string("deep-schema"));
        try json.put(a, &metadata, "application_version", json.string("1"));
        try json.put(a, &metadata, "client_mapping", json.string("agent-client-values/1.1"));
        for ([_][]const u8{ "input", "output", "failure", "answer", "message" }) |key| {
            var contract = json.object();
            try json.put(a, &contract, "schema_id", json.string("deep.v1"));
            try json.put(a, &contract, "json", schema);
            try json.put(a, &metadata, key, contract);
        }
        try json.put(a, &metadata, "capabilities", .{ .array = .init(a) });
        const encoded = try json.canonical(a, metadata);
        try std.testing.expect(encoded.len < 60 * 1024);
        try std.testing.expectError(error.Capacity, json.parse(a, encoded, .{}));
        _ = try json.parseAsset(a, encoded, 16 * 1024 * 1024);
        const protocol_schema = try @import("schemas.zig").document(a, metadata, .{});
        const artifacts = [2]?Artifact{ try Artifact.freeze(a, metadata, "application"), try Artifact.freeze(a, protocol_schema, "protocol") };
        const app: Application = .{ .arena = .init(a), .metadata = metadata, .manifest = .null, .manifest_id = "test", .image_identity = @splat(0), .public_metadata = metadata, .protocol_schema = protocol_schema, .schema_artifacts = artifacts };
        const description = try app.describe(a, json.object(), null);
        try std.testing.expect(json.get(description.object.get("application").?, "metadata_ref") != null);
        try std.testing.expect(json.get(description, "protocol_schema_ref") != null);
        var replies: std.array_list.Managed(json.Value) = .init(a);
        for (0..16) |i| try replies.append(try protocol.response(a, try json.number(a, i), description));
        const wire = try json.frame(a, .{ .array = replies });
        _ = try json.parse(a, wire, .{});
        const chunk = try artifactChunk(a, try app.schemaArtifact(artifacts[0].?.sha256), 0, 32768);
        const text = chunk.object.get("data").?.string;
        const decoded = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(text));
        try std.base64.url_safe_no_pad.Decoder.decode(decoded, text);
        try std.testing.expectEqualSlices(u8, encoded[0..decoded.len], decoded);
    }
}

test "discovery matches the complete schema specialization rather than its family name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Handler = struct {
        fn run(_: registry.Context, value: u32) !u32 {
            return value;
        }
    };
    var handlers = try registry.Registry.init(a, &.{registry.leaf(u32, u32, .{ .identity = "family", .resource_role = "local" }, Handler.run)});
    defer handlers.deinit();
    const entry = handlers.entries[0];
    const exact = (try json.parse(a, "{\"identity\":\"family\",\"resource_role\":\"local\",\"payload_sha256\":\"\",\"resume_sha256\":\"\"}", .{})).value;
    var matched = exact;
    try json.put(a, &matched, "payload_sha256", json.string(try digest(a, entry.payload_schema)));
    try json.put(a, &matched, "resume_sha256", json.string(try digest(a, entry.resume_schema)));
    var specialized = (try json.parse(a, try json.canonical(a, matched), .{})).value;
    try json.put(a, &specialized, "payload_sha256", json.string(try digest(a, try values.schemaBytes(u64, a))));
    try validateCapability(a, &.{ specialized, matched }, entry);
    try validateCapability(a, &.{ matched, specialized }, entry);
    try std.testing.expectError(error.CapabilityMetadataMismatch, validateCapability(a, &.{specialized}, entry));
    try std.testing.expectError(error.CapabilityMetadataMismatch, validateCapability(a, &.{ matched, matched }, entry));
    try json.put(a, &matched, "resource_role", json.string("other"));
    try std.testing.expectError(error.CapabilityMetadataMismatch, validateCapability(a, &.{matched}, entry));
}
