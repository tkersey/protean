const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("state.zig");
const workspace = @import("workspace_state.zig");
const storage = @import("store.zig");

pub const Description = contracts.workspace.RetainedDescription;

pub const Import = struct {
    task: state.TaskId,
    locator: contracts.workspace.RetainedLocator,
    definition: state.Reference,
    program: state.Reference,
    artifact: workspace.ProgramArtifact,
};

pub const RetainRequest = struct {
    task: state.TaskId,
    retain: contracts.workspace.Retain,
};

pub const ImportRequest = struct {
    task: state.TaskId,
    import: contracts.workspace.Import,
};

pub const Definition = struct {
    version: u32 = 1,
    scope: state.Name,
    description: Description,
    source_task: state.TaskId,
    program: state.Reference,
    artifact: workspace.ProgramArtifact,
    origin: state.Archive,
};

pub fn sameOwner(
    a: std.mem.Allocator,
    store: *storage.Store,
    definition: Definition,
    principal: []const u8,
    tenant: []const u8,
) !bool {
    const bytes = try store.object(a, definition.origin.task, null);
    defer a.free(bytes);
    var origin = try contracts.decodeOwned(state.Task, a, bytes);
    defer origin.deinit();
    if (!std.meta.eql(origin.value.id, definition.source_task)) return error.CorruptState;
    return std.mem.eql(u8, origin.value.principal.bytes, principal) and
        std.mem.eql(u8, origin.value.tenant.bytes, tenant);
}

pub fn validate(
    a: std.mem.Allocator,
    store: *storage.Store,
    definition: Definition,
) !void {
    if (definition.version != 1) return error.UnsupportedCapability;
    try validateConstruction(a, definition);
    var inspected = try @import("archive.zig").inspect(a, store, definition.origin, null);
    defer inspected.task.deinit();
    if (!std.meta.eql(inspected.task.value.id, definition.source_task))
        return error.InvalidArchive;
    const custody = try workspace.custodyId(a, definition.source_task, definition.program.digest);
    const reference = @import("archive.zig").record(
        definition.origin,
        .workspace_program,
        custody,
    ) orelse return error.InvalidArchive;
    const bytes = try store.object(a, reference, null);
    defer a.free(bytes);
    var program = try contracts.decodeOwned(workspace.Program, a, bytes);
    defer program.deinit();
    if (!std.meta.eql(program.value.id, custody) or
        !std.meta.eql(program.value.task, definition.source_task) or
        !std.meta.eql(program.value.artifact, definition.program)) return error.InvalidArchive;
    const artifact = try contracts.encodeOwned(
        workspace.ProgramArtifact,
        a,
        program.value.description,
    );
    defer a.free(artifact);
    if (artifact.len != definition.program.bytes or
        !std.meta.eql(storage.digest(artifact), definition.program.digest))
        return error.InvalidArchive;
    try validatePublication(a, store, definition);
}

pub fn validateConstruction(a: std.mem.Allocator, definition: Definition) !void {
    const artifact = definition.artifact;
    if (artifact.source_kind != .source_records or artifact.catalog != null or
        artifact.controller != null or artifact.controller_schemas.items.len != 0)
        return error.UnsupportedCapability;
    if (definition.scope.bytes.len == 0 or definition.description.name.bytes.len == 0)
        return error.InvalidParams;
    const bytes = try contracts.encodeOwned(workspace.ProgramArtifact, a, artifact);
    defer a.free(bytes);
    if (bytes.len != definition.program.bytes or
        !std.meta.eql(storage.digest(bytes), definition.program.digest))
        return error.InvalidArchive;
}

fn validatePublication(
    a: std.mem.Allocator,
    store: *storage.Store,
    definition: Definition,
) !void {
    for (definition.origin.operations.items) |operation| {
        const bytes = try store.object(a, operation.body, null);
        defer a.free(bytes);
        var receipt = try contracts.decodeOwned(state.Receipt, a, bytes);
        defer receipt.deinit();
        const value = receipt.value;
        if (value.method == .workspace and value.workspace_kind == .program and
            value.workspace != null and value.workspace_observation != null and
            std.meta.eql(value.task, definition.source_task) and
            std.meta.eql(value.workspace.?, definition.program.digest) and
            std.meta.eql(value.workspace_observation.?, definition.program)) return;
        if (value.method == .workspace and value.workspace_kind == .imported and
            value.workspace_observation != null and
            std.meta.eql(value.task, definition.source_task))
        {
            const observed_bytes = try store.object(a, value.workspace_observation.?, null);
            defer a.free(observed_bytes);
            var observed = try contracts.decodeOwned(Import, a, observed_bytes);
            defer observed.deinit();
            if (std.meta.eql(observed.value.task, definition.source_task) and
                std.meta.eql(observed.value.program, definition.program)) return;
        }
    }
    return error.InvalidArchive;
}

pub const Origins = struct {
    a: std.mem.Allocator,
    references: std.AutoArrayHashMapUnmanaged(state.Reference, void) = .empty,

    pub fn deinit(self: *Origins) void {
        self.references.deinit(self.a);
    }

    pub fn add(_: *Origins, _: state.Reference) !void {}
    pub fn reply(_: *Origins, _: @import("occurrence.zig").Acquired) !void {}
    pub fn observerSource(_: *Origins, _: state.Reference) !void {}

    pub fn reuseDefinition(self: *Origins, ref: state.Reference) !void {
        try self.references.put(self.a, ref, {});
    }

    pub fn typed(self: *Origins, comptime T: type, ref: state.Reference, value: T) !void {
        if (T == Definition) return self.reuseDefinition(ref);
        try state.visitReferences(T, value, self);
    }

    pub fn scan(self: *Origins, source: anytype, origin: state.Archive) !void {
        for (origin.operations.items) |row| {
            const bytes = try source.object(self.a, row.body, null);
            defer self.a.free(bytes);
            var receipt = try contracts.decodeOwned(state.Receipt, self.a, bytes);
            defer receipt.deinit();
            if (receipt.value.method != .workspace or
                (receipt.value.workspace_kind != .retained and
                    receipt.value.workspace_kind != .imported)) continue;
            try state.visitWorkspaceReceipt(self.a, source, receipt.value, self);
        }
        for (origin.records.items) |row| {
            if (row.kind != .workspace_reply) continue;
            const bytes = try source.object(self.a, row.body, null);
            defer self.a.free(bytes);
            var decoded = try contracts.decodeOwned(workspace.ReplyObservation, self.a, bytes);
            defer decoded.deinit();
            try state.visitReferences(workspace.ReplyObservation, decoded.value, self);
        }
    }
};
