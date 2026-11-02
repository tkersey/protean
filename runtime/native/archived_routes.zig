const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const storage = @import("store.zig");
const state = @import("state.zig");
const occurrence = @import("occurrence.zig");

pub fn resolve(self: anytype, root: anytype, saved: occurrence.Occurrence) !state.Digest {
    var route = try self.record(.execution_route, saved.task, saved.id);
    defer route.deinit();
    if (!std.meta.eql(route.value.work, saved.work) or
        !std.meta.eql(route.value.residual, saved.residual) or
        !std.meta.eql(route.value.task, saved.task) or
        !std.meta.eql(route.value.id, saved.id))
    {
        return error.CorruptState;
    }
    var image = root.image;
    if (saved.work) |id| {
        var work = try self.record(.workspace_work, saved.task, id);
        defer work.deinit();
        var program = try self.record(
            .workspace_program,
            saved.task,
            try @import("workspace_state.zig").custodyId(
                self.a,
                saved.task,
                work.value.program,
            ),
        );
        defer program.deinit();
        image = program.value.description.image;
        if (!std.meta.eql(
            route.value.delegation,
            work.value.delegation,
        )) return error.CorruptState;
    } else if (route.value.controller) |id| {
        image = try controllerImage(self, root.controller, saved.task, id, route.value);
    }
    if (!std.meta.eql(image, route.value.image)) return error.CorruptState;
    const identity = try self.imageIdentity(image);
    if (!std.meta.eql(identity, route.value.program_identity)) return error.CorruptState;
    return identity;
}

fn controllerImage(
    self: anytype,
    initial: ?state.Digest,
    task: state.TaskId,
    id: state.Digest,
    route: @import("workspace_state.zig").ExecutionRoute,
) !state.Reference {
    var cursor = initial;
    var last_epoch: ?u64 = null;
    return found: {
        while (cursor) |current| {
            var binding = try self.record(.controller_binding, task, current);
            defer binding.deinit();
            if (last_epoch) |epoch| {
                if (binding.value.epoch >= epoch) return error.CorruptState;
            }
            if (std.meta.eql(current, id)) {
                var program = try self.record(
                    .workspace_program,
                    task,
                    try @import("workspace_state.zig").custodyId(
                        self.a,
                        task,
                        binding.value.program,
                    ),
                );
                defer program.deinit();
                if (program.value.description.controller == null or !std.meta.eql(
                    program.value.description.image,
                    binding.value.image,
                ) or !std.meta.eql(
                    binding.value.program_identity,
                    route.program_identity,
                )) return error.CorruptState;
                break :found binding.value.image;
            }
            last_epoch = binding.value.epoch;
            cursor = binding.value.predecessor;
        }
        return error.CorruptState;
    };
}

pub const StoreView = struct {
    a: std.mem.Allocator,
    store: *storage.Store,

    pub fn record(
        self: *StoreView,
        comptime kind: storage.RecordKind,
        task: state.TaskId,
        id: state.Digest,
    ) !contracts.Decoded(storage.Record(@tagName(kind))) {
        const bytes = (try self.store.recordBytes(self.a, @tagName(kind), id, task)) orelse
            return error.CorruptState;
        defer self.a.free(bytes);
        var decoded = try contracts.decodeOwned(storage.Record(@tagName(kind)), self.a, bytes);
        errdefer decoded.deinit();
        if (!std.meta.eql(decoded.value.id, id) or
            !std.meta.eql(decoded.value.task, task)) return error.CorruptState;
        return decoded;
    }

    pub fn validateRequest(
        self: *StoreView,
        root: state.Task,
        saved: occurrence.Occurrence,
        request: data.invocation.Request,
    ) !void {
        const identity = try resolve(self, root, saved);
        if (!std.meta.eql(identity, request.binding.program_identity) or
            !std.meta.eql(saved.request, request.request_identity)) return error.InvalidArchive;
        var route = try self.record(.execution_route, saved.task, saved.id);
        defer route.deinit();
        const bytes = try self.store.object(self.a, route.value.image, null);
        defer self.a.free(bytes);
        var decoded = try data.program_image.decode(self.a, bytes);
        defer decoded.deinit();
        if (request.binding.effect >= decoded.program.effects.len) return error.InvalidArchive;
        const effect = decoded.program.effects[@intCast(request.binding.effect)];
        if (!std.mem.eql(u8, effect.identity, request.binding.semantic_identity))
            return error.InvalidArchive;
        const payload = try data.schema.encodeOwned(
            self.a,
            decoded.program.schemas,
            effect.payload,
        );
        defer self.a.free(payload);
        const result = try data.schema.encodeOwned(self.a, decoded.program.schemas, effect.result);
        defer self.a.free(result);
        if (!std.mem.eql(u8, payload, request.binding.payload_schema) or
            !std.mem.eql(u8, result, request.binding.resume_schema)) return error.InvalidArchive;
    }

    pub fn imageIdentity(self: *StoreView, ref: state.Reference) !state.Digest {
        const bytes = try self.store.object(self.a, ref, null);
        defer self.a.free(bytes);
        var decoded = try data.program_image.decode(self.a, bytes);
        defer decoded.deinit();
        return decoded.identity;
    }
};
