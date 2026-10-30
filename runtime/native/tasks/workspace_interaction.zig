const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const EncodedInteraction = task_types.EncodedInteraction;
const InteractionInput = task_types.InteractionInput;
const InteractionPublication = task_types.InteractionPublication;
const Work = task_types.Work;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const compatible = Controller.compatible;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceInteractionAllowed = Access.workspaceInteractionAllowed;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspacePublishValue = Inspection.workspacePublishValue;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const writeWorkspaceWork = Publication.writeWorkspaceWork;
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        pub fn workspaceInteract(
            self: *Self,
            allocator: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            interaction: @FieldType(wc.Work, "interact"),
        ) !Admission {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const request = try operation(workspace.InteractionRequest, a, .{
                .task = task_id,
                .interaction = interaction,
            });
            if (try replay(self, allocator, operation_id, request)) |prior| return prior;
            const work_id = try wp.identity(interaction.expected.work, .work);
            try requireCustody(self, allocator, task_id, work_id);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            var saved = try self.workspaceWork(a, task_id, work_id);
            defer saved.deinit();
            const value = saved.value;
            if (value.execution_revision != interaction.expected.execution_revision or
                value.control_revision != interaction.expected.control_revision)
                return error.StaleRevision;
            if (!workspaceInteractionAllowed(workspaceParentStopped(self, parent.value), value))
                return error.InvalidState;
            var port = try workspaceInteractionPort(self, a, task_id, value, interaction);
            defer port.deinit();
            const binding = workspaceInteractionBinding(task_id, value.id, port.value);
            var pending = try workspaceInteractionPending(self, a, task_id, binding);
            defer pending.deinit();
            var encoded = try encodeWorkspaceInteraction(self, a, task_id, port.value, interaction);
            defer encoded.deinit(a);
            return commitWorkspaceInteraction(self, a, .{
                .operation_id = operation_id,
                .request = request,
                .parent = parent.value,
                .work = value,
                .port_reference = value.current_port.?,
                .port = port.value,
                .pending = pending.value,
                .interaction = interaction,
                .encoded = encoded,
            });
        }
        fn workspaceInteractionPort(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            value: workspace.Work,
            interaction: @FieldType(wc.Work, "interact"),
        ) !contracts.Decoded(workspace.Port) {
            const reference = value.current_port orelse return error.NoExposedPort;
            const bytes = try store(self).object(a, reference, null);
            defer a.free(bytes);
            var port = try contracts.decodeOwned(workspace.Port, a, bytes);
            errdefer port.deinit();
            if (!std.meta.eql(port.value.id, try wp.identity(interaction.port, .port)) or
                port.value.generation != interaction.generation or
                !std.meta.eql(port.value.task, task_id) or
                !std.meta.eql(port.value.work, value.id) or
                !std.meta.eql(value.current_occurrence, @as(?state.Digest, port.value.occurrence)))
                return error.StalePort;
            return port;
        }
        fn workspaceInteractionBinding(
            task_id: state.TaskId,
            work_id: state.Digest,
            port: workspace.Port,
        ) occurrence.Binding {
            return .{
                .id = port.occurrence,
                .task = task_id,
                .work = work_id,
                .request = port.request_identity,
            };
        }
        fn workspaceInteractionPending(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            binding: occurrence.Binding,
        ) !contracts.Decoded(occurrence.Occurrence) {
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", binding.id, task_id);
            errdefer pending.deinit();
            try occurrence.current(pending.value, binding);
            if (pending.value.state != .ready) return error.PortAlreadyAnswered;
            return pending;
        }
        fn encodeWorkspaceInteraction(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            port: workspace.Port,
            interaction: @FieldType(wc.Work, "interact"),
        ) !EncodedInteraction {
            const argument_schema =
                try store(self).object(a, port.interface.argument, null);
            defer a.free(argument_schema);
            var input: ?InteractionInput = null;
            errdefer if (input) |owned| a.free(owned.bytes);
            const command_schema =
                try store(self).object(a, port.interface.command, null);
            defer a.free(command_schema);
            const payload_schema = if (interaction.command == .finish)
                try store(self).object(a, port.interface.payload, null)
            else
                &.{};
            defer a.free(payload_schema);
            const payload = if (interaction.command == .finish)
                try store(self).object(a, port.payload, null)
            else
                &.{};
            defer a.free(payload);
            const protocol: @import("../workspace_driver.zig").Protocol = .{
                .class = port.interface.class,
                .command_schema = command_schema,
                .payload_schema = payload_schema,
                .payload = payload,
            };
            const command: @import("../workspace_driver.zig").Command =
                switch (interaction.command) {
                    .finish => .finish,
                    .resume_value => |supplied| blk: {
                        input = try workspaceInteractionInput(
                            self,
                            a,
                            task_id,
                            port.interface.argument,
                            argument_schema,
                            supplied,
                        );
                        break :blk .{ .resume_value = input.?.bytes };
                    },
                };
            return .{ .input = input, .bytes = try protocol.encode(a, command) };
        }
        fn workspaceInteractionInput(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            argument: state.Reference,
            schema: []const u8,
            supplied: wc.ValueInput,
        ) !InteractionInput {
            switch (supplied) {
                .inline_json => |inline_value| {
                    if (!std.meta.eql(
                        try wp.identity(inline_value.schema, .schema),
                        argument.digest,
                    ))
                        return error.SchemaMismatch;
                    const text = inline_value.json_text.bytes;
                    var parsed = try json.parse(a, text, .{
                        .bytes = text.len,
                        .depth = text.len,
                        .tokens = text.len,
                        .members = text.len,
                    });
                    defer parsed.deinit();
                    return .{
                        .bytes = try @import("../dynamic_values.zig").encode(
                            a,
                            schema,
                            parsed.value,
                        ),
                    };
                },
                .reference => |ref| {
                    const selected = try workspaceValueReference(self, a, task_id, ref);
                    if (!std.meta.eql(selected.schema, argument)) return error.SchemaMismatch;
                    return .{
                        .origin = selected.artifact,
                        .bytes = try store(self).object(a, selected.value, null),
                    };
                },
            }
        }
        fn commitWorkspaceInteraction(
            self: *Self,
            a: std.mem.Allocator,
            publication: InteractionPublication,
        ) !Admission {
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = publication.pending.request,
                .value = publication.encoded.bytes,
            });
            defer a.free(bound);
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const binding = workspaceInteractionBinding(
                publication.parent.id,
                publication.work.id,
                publication.port,
            );
            const dispatched =
                try occurrence.dispatch(publication.pending, binding, attempt, false, false);
            const acquired =
                try occurrence.acquired(dispatched, binding, attempt, storage.digest(bound));
            return publishWorkspaceInteraction(self, a, publication, attempt, acquired, bound);
        }
        fn publishWorkspaceInteraction(
            self: *Self,
            a: std.mem.Allocator,
            publication: InteractionPublication,
            attempt: state.Digest,
            acquired: occurrence.Occurrence,
            bound: []const u8,
        ) !Admission {
            var value = publication.work;
            const task_id = publication.parent.id;
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try store(self).begin();
            defer store(self).rollback();
            const origin = try retainWorkspaceInteractionInput(
                self,
                a,
                task_id,
                &value,
                publication.port.interface.argument,
                publication.encoded.input,
            );
            try store(self).createRecord(
                workspace.PortReply,
                "workspace_port_reply",
                attempt,
                task_id,
                .{
                    .id = attempt,
                    .task = task_id,
                    .port = publication.port_reference,
                    .reply = try store(self).putObject(bound),
                    .input = origin,
                    .command = if (publication.interaction.command == .finish)
                        .finish
                    else
                        .resume_value,
                },
            );
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                publication.pending.id,
                task_id,
                acquired,
            );
            value.control_revision = try std.math.add(u64, value.control_revision, 1);
            value.event_watermark = try std.math.add(u64, publication.parent.event_high, 1);
            value.schedule = .queued;
            try writeWorkspaceWork(self, &value, .replace);
            return workspaceCommit(
                self,
                a,
                publication.parent,
                publication.operation_id,
                publication.request,
                value.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", value.id, task_id),
                .{ .interact = publication.interaction },
            );
        }
        fn retainWorkspaceInteractionInput(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            value: *workspace.Work,
            argument: state.Reference,
            input: ?InteractionInput,
        ) !?state.Reference {
            const supplied = input orelse return null;
            const origin = supplied.origin orelse try workspacePublishValue(
                self,
                a,
                task_id,
                argument,
                try store(self).putObject(supplied.bytes),
                .{ .kind = .hypothesis, .sources = .{ .items = &.{} } },
            );
            const inputs = try a.alloc(state.Reference, value.inputs.items.len + 1);
            @memcpy(inputs[0..value.inputs.items.len], value.inputs.items);
            inputs[value.inputs.items.len] = origin;
            value.inputs = .{ .items = inputs };
            return origin;
        }
    };
}
