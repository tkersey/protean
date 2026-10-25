//! Shared fixtures for workspace execution and runtime ownership checks.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("kosmos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const source = horos.source;
const Id = source.Id;

pub fn workspaceRef(a: std.mem.Allocator, kind: @FieldType(contracts.workspace.Ref, "kind"), id: [32]u8) !contracts.workspace.Ref {
    return .{ .kind = kind, .id = .{ .bytes = try a.dupe(u8, &std.fmt.bytesToHex(id, .lower)) } };
}

pub const PoisonFreedAllocator = struct {
    backing: std.mem.Allocator,
    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        @memset(bytes, 'X');
    }
};

pub const AfterCommitAllocator = struct {
    backing: std.mem.Allocator,
    namespace: *native.Namespace,
    generation: u64,
    rejected: usize = 0,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn blocked(self: *@This()) bool {
        if (self.namespace.store.head.generation == self.generation) return false;
        self.rejected += 1;
        return true;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.blocked()) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return false;
        return self.backing.rawResize(bytes, alignment, len, ra);
    }
    fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > bytes.len and self.blocked()) return null;
        return self.backing.rawRemap(bytes, alignment, len, ra);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

pub fn compile(a: std.mem.Allocator, b: *source.Builder, module: source.Module) !native.program_construction.Built {
    _ = b;
    const text = try native.source_records.encode(a, module);
    defer a.free(text);
    var diagnostic: native.program_construction.Diagnostic = .{};
    return native.program_construction.build(a, text, null, &diagnostic);
}

pub const OwnerTypes = struct {
    pub const application_id = "workspace-owner-test";
    pub const input_schema_id = "workspace-owner.input/1";
    pub const output_schema_id = "workspace-owner.output/1";
    pub const failure_schema_id = "workspace-owner.failure/1";
    pub const message_schema_id = "workspace-owner.message/1";
    pub const Input = struct { u64, u64 };
    pub const Output = u64;
    pub const Failure = void;
    pub const Message = void;
};

pub fn expectContextOutputBound(service: anytype, a: std.mem.Allocator, task: native.testing.state.TaskId, operation_id: []const u8, replacement: contracts.workspace.Ref, replacement_reply: ?contracts.workspace.Reply) !void {
    const store = &service.namespace.store;
    var manifest_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(service.assets.manifest, &manifest_digest, .{});
    const index = try store.archiveIndex(a, task, .{ .digest = manifest_digest, .bytes = service.assets.manifest.len });
    var compiler_facts = try service.prepareWorkspaceValidation(task);
    defer compiler_facts.deinit();
    try store.begin();
    defer store.rollback();
    var operations = try store.database.prepare("SELECT p.id,o.body FROM operations p JOIN objects o ON o.digest=p.receipt WHERE p.task=?", &.{.{ .blob = &task }});
    defer operations.deinit();
    var changed = false;
    var revision: u64 = 0;
    while (try operations.step() == .row) {
        var receipt = (try contracts.decodeOwned(native.testing.state.Receipt, a, try operations.bytes(1))).value;
        if (!std.mem.eql(u8, receipt.client_operation_id.bytes, operation_id)) continue;
        revision = receipt.revision;
        try std.testing.expectEqual(replacement.kind, receipt.workspace_kind.?);
        receipt.workspace = try nativeIdentity(replacement);
        receipt.workspace_observation = try store.objectReference(receipt.workspace.?, null);
        const rewritten = try store.putObject(try contracts.encodeOwned(native.testing.state.Receipt, a, receipt));
        try store.database.run("UPDATE operations SET receipt=? WHERE id=?", &.{ .{ .blob = &rewritten.digest }, .{ .text = try operations.bytes(0) } });
        var events = try store.database.prepare("SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WHERE e.task=? AND e.revision=?", &.{ .{ .blob = &task }, .{ .integer = @intCast(receipt.revision) } });
        defer events.deinit();
        try std.testing.expect(try events.step() == .row);
        var event_value = (try contracts.decodeOwned(native.testing.state.Event, a, try events.bytes(0))).value;
        event_value.data.bytes = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{replacement.id.bytes});
        const event_ref = try store.putObject(try contracts.encodeOwned(native.testing.state.Event, a, event_value));
        try store.database.run("UPDATE events SET body=? WHERE task=? AND seq=?", &.{ .{ .blob = &event_ref.digest }, .{ .blob = &task }, .{ .integer = @intCast(event_value.seq) } });
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    if (replacement_reply) |reply| {
        var id: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&id, operation_id);
        var pending = (try contracts.decodeOwned(native.testing.occurrence.Occurrence, a, (try store.recordBytes(a, "occurrence", id, task)).?)).value;
        var projected = reply;
        var observation = (try native.json.parse(a, reply.observation_json.bytes, .{})).value;
        try native.json.put(a, &observation, "receipt_revision", try native.json.number(a, revision));
        projected.observation_json.bytes = try native.json.canonical(a, observation);
        const payload = try contracts.encodeOwned(contracts.workspace.Reply, a, projected);
        const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request, .value = payload });
        pending.state.settled_reply.reply = (try store.putObject(bound)).digest;
        try store.putRecord(native.testing.occurrence.Occurrence, "occurrence", id, task, pending);
    }
    // All substituted objects remain legitimate task-owned artifacts; receipt,
    // event and optional acquired reply have coherent content hashes.
    try std.testing.expectError(error.InvalidArchive, service.validateWorkspaceRecordsPrepared(a, task, index.records.items, &compiler_facts));
}

pub fn nativeIdentity(ref: contracts.workspace.Ref) ![32]u8 {
    var result: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, ref.id.bytes);
    return result;
}

pub fn fixtureManifest(a: std.mem.Allocator, image: []const u8, identity: [32]u8, application_bytes: []const u8) ![]u8 {
    var image_digest: [32]u8 = undefined;
    var assets_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &image_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(application_bytes, &assets_digest, .{});
    const image_hex = std.fmt.bytesToHex(image_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity, .lower);
    const assets_hex = std.fmt.bytesToHex(assets_digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{
        .native_host_contract = "unit-native-contract",
        .protocol = "agent-host/2.1",
        .client_mapping = "agent-client-values/1.1",
        .state_format = "agent-native-state/19",
        .optimize = "debug",
        .program_sha256 = @as([]const u8, &image_hex),
        .program_identity = @as([]const u8, &identity_hex),
        .application_assets_sha256 = @as([]const u8, &assets_hex),
        .dependencies = .{ .world = "unit-kosmos", .boundary = "unit-horos" },
        .compiler = .{ .version = "0.17.0" },
    }, .{});
}
