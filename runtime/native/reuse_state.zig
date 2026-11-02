const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
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

pub fn validatePublication(
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
    if (try capturedPublication(a, store, definition)) return;
    return error.InvalidArchive;
}

fn capturedPublication(a: std.mem.Allocator, store: *storage.Store, value: Definition) !bool {
    var captures: std.AutoHashMap(state.Digest, state.Reference) = .init(a);
    defer captures.deinit();
    for (value.origin.records.items) |row| {
        if (row.kind != .capture) continue;
        const entry = try captures.getOrPut(row.id);
        if (entry.found_existing) return error.InvalidArchive;
        entry.value_ptr.* = row.body;
    }
    for (value.origin.records.items) |row| {
        if (row.kind != .attempt) continue;
        const bytes = try store.object(a, row.body, null);
        defer a.free(bytes);
        var attempt = try contracts.decodeOwned(state.Attempt, a, bytes);
        defer attempt.deinit();
        if (attempt.value.operation != .workspace_build) continue;
        if (!std.meta.eql(attempt.value.id, row.id) or
            !std.meta.eql(attempt.value.task, value.source_task)) return error.InvalidArchive;
        const capture = captures.get(row.id) orelse continue;
        if (try capturePublishes(a, store, value, attempt.value, capture)) return true;
    }
    return false;
}

fn capturePublishes(
    a: std.mem.Allocator,
    store: *storage.Store,
    value: Definition,
    attempt: state.Attempt,
    reference: state.Reference,
) !bool {
    const bytes = try store.object(a, reference, null);
    defer a.free(bytes);
    var raw = try contracts.decodeOwned(state.Capture, a, bytes);
    defer raw.deinit();
    const capture = raw.value;
    const projection = capture.projection orelse return false;
    if (capture.disposition != .complete or capture.response == null or
        !std.meta.eql(capture.task, value.source_task) or
        !std.meta.eql(capture.attempt, attempt.id) or
        !std.meta.eql(capture.occurrence, attempt.occurrence)) return error.InvalidArchive;
    const projected = try store.object(a, projection.reply, null);
    defer a.free(projected);
    var bound = try data.invocation.decode(data.invocation.Result, a, projected);
    defer bound.deinit();
    var reply = try contracts.decodeOwned(contracts.workspace.Reply, a, bound.value.value);
    defer reply.deinit();
    if (reply.value.disposition != .admitted) return false;
    const program = reply.value.program orelse return false;
    const id = try @import("workspace_projection.zig").identity(program, .program);
    if (!std.meta.eql(id, value.program.digest)) return false;
    const occurrence_ref = @import("archive.zig").record(
        value.origin,
        .occurrence,
        attempt.occurrence,
    ) orelse return error.InvalidArchive;
    const occurrence_bytes = try store.object(a, occurrence_ref, null);
    defer a.free(occurrence_bytes);
    var occurrence = try contracts.decodeOwned(
        @import("occurrence.zig").Occurrence,
        a,
        occurrence_bytes,
    );
    defer occurrence.deinit();
    const acquired = switch (occurrence.value.state) {
        .settled_reply => |selected| selected,
        .admitted => |selected| if (selected == .reply)
            selected.reply
        else
            return error.InvalidArchive,
        else => return error.InvalidArchive,
    };
    if (!std.meta.eql(occurrence.value.task, value.source_task) or
        !std.meta.eql(occurrence.value.id, attempt.occurrence) or
        !std.meta.eql(bound.value.request_identity, occurrence.value.request) or
        !std.meta.eql(acquired.attempt, attempt.id) or
        !std.meta.eql(acquired.reply, projection.reply.digest)) return error.InvalidArchive;
    return true;
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
        try self.scanPublications(source, origin);
        for (origin.records.items) |row| {
            if (row.kind != .workspace_reply) continue;
            const bytes = try source.object(self.a, row.body, null);
            defer self.a.free(bytes);
            var decoded = try contracts.decodeOwned(workspace.ReplyObservation, self.a, bytes);
            defer decoded.deinit();
            try state.visitReferences(workspace.ReplyObservation, decoded.value, self);
        }
    }

    pub fn scanPublications(self: *Origins, source: anytype, origin: state.Archive) !void {
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
    }
};
