const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const workspace = @import("../workspace_state.zig");
const reuse = @import("../reuse_state.zig");
const wp = @import("../workspace_projection.zig");
const task_types = @import("types.zig");

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);

        pub fn retained(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            event: state.Event,
            admission: task_types.WorkspaceAdmission,
            selected: @FieldType(workspace.PublicationCommand, "retain"),
        ) !state.Digest {
            if (!std.meta.eql(admission.work, selected.definition.digest) or
                !std.meta.eql(admission.observation, selected.definition))
                return error.InvalidArchive;
            const store = Lifecycle.store(self);
            const bytes = try store.object(a, selected.definition, null);
            defer a.free(bytes);
            var definition = try contracts.decodeOwned(reuse.Definition, a, bytes);
            defer definition.deinit();
            try reuse.validate(a, store, definition.value);
            if (!std.meta.eql(definition.value.source_task, parent.id) or
                !std.meta.eql(
                    definition.value.program.digest,
                    try wp.identity(selected.request.program, .program),
                )) return error.InvalidArchive;
            try sameEncoded(a, state.Name, definition.value.scope, selected.request.scope);
            try sameEncoded(
                a,
                reuse.Description,
                definition.value.description,
                selected.request.description,
            );
            const origin = try store.object(a, definition.value.origin.task, null);
            defer a.free(origin);
            var frozen = try contracts.decodeOwned(state.Task, a, origin);
            defer frozen.deinit();
            if (event.revision == 0 or frozen.value.revision != event.revision - 1 or
                event.seq == 0 or frozen.value.event_high != event.seq - 1)
                return error.InvalidArchive;
            return task_types.operation(reuse.RetainRequest, a, .{
                .task = parent.id,
                .retain = selected.request,
            });
        }

        pub fn imported(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            admission: task_types.WorkspaceAdmission,
            selected: @FieldType(workspace.PublicationCommand, "import"),
        ) !state.Digest {
            if (!std.meta.eql(admission.work, selected.observation.digest) or
                !std.meta.eql(admission.observation, selected.observation))
                return error.InvalidArchive;
            const store = Lifecycle.store(self);
            const bytes = try store.object(a, selected.observation, null);
            defer a.free(bytes);
            var observed = try contracts.decodeOwned(reuse.Import, a, bytes);
            defer observed.deinit();
            const value = observed.value;
            try sameEncoded(
                a,
                contracts.workspace.RetainedLocator,
                value.locator,
                selected.request.locator,
            );
            if (!std.meta.eql(value.task, parent.id) or !std.meta.eql(
                value.definition.digest,
                try @import("workspace_reuse.zig").locatorId(value.locator),
            )) return error.InvalidArchive;
            const definition_bytes = try store.object(a, value.definition, null);
            defer a.free(definition_bytes);
            var definition = try contracts.decodeOwned(reuse.Definition, a, definition_bytes);
            defer definition.deinit();
            try reuse.validate(a, store, definition.value);
            if (!std.mem.eql(u8, definition.value.scope.bytes, value.locator.scope.bytes))
                return error.InvalidArchive;
            try sameEncoded(
                a,
                workspace.ProgramArtifact,
                value.artifact,
                definition.value.artifact,
            );
            if (!std.meta.eql(value.program, definition.value.program)) return error.InvalidArchive;
            var program = try Programs.workspaceProgram(self, a, parent.id, value.program.digest);
            defer program.deinit();
            try sameEncoded(
                a,
                workspace.ProgramArtifact,
                program.value.description,
                value.artifact,
            );
            return task_types.operation(reuse.ImportRequest, a, .{
                .task = parent.id,
                .import = selected.request,
            });
        }
    };
}

fn sameEncoded(a: std.mem.Allocator, comptime T: type, left: T, right: T) !void {
    const first = try contracts.encodeOwned(T, a, left);
    defer a.free(first);
    const second = try contracts.encodeOwned(T, a, right);
    defer a.free(second);
    if (!std.mem.eql(u8, first, second)) return error.InvalidArchive;
}
