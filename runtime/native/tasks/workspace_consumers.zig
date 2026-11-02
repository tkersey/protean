const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const json = @import("../json.zig");
const values = @import("../values.zig");

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Controller = @import("controller_context.zig").Operations(Types, Self);
        const store = Lifecycle.store;
        const record = Records.record;

        pub fn controllerObservation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
        ) !workspace.ControllerObservation {
            return .{
                .binding = parent.controller,
                .epoch = parent.controller_epoch,
                .execution_revision = parent.execution_revision,
                .runtime = parent.controller_runtime,
                .realization_revision = parent.realization_revision,
                .interaction = parent.controller_interaction,
                .residuals = .{ .items = try Recovery.controllerResidualIds(self, a, parent.id) },
                .event_watermark = parent.event_high,
            };
        }

        pub fn observe(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            selection: wc.ConsumerInspection,
            interface: workspace.ConsumerInterface,
            model: ?workspace.ModelBinding,
        ) !workspace.ConsumerObservation {
            const current = try a.alloc(
                workspace.WorkObservation,
                selection.required_current.items.len,
            );
            for (current, selection.required_current.items) |*out, expected| {
                out.* = try Access.freezeWorkspaceWork(self, a, parent.id, expected.work, false);
                try expectWork(out.work, expected);
            }
            var target: ?workspace.WorkObservation = null;
            if (selection.target == .model) {
                const selected = selection.target.model;
                target = try Access.freezeWorkspaceWork(
                    self,
                    a,
                    parent.id,
                    selected.expected.work,
                    false,
                );
                try expectWork(target.?.work, selected.expected);
                try expectPort(self, a, target.?, selected);
                if (model == null) return error.InvalidConsumer;
            } else if (model != null) return error.InvalidConsumer;
            return .{
                .task = parent.id,
                .tenant = parent.tenant,
                .application = parent.image,
                .policy = parent.profile,
                .input = parent.input,
                .next_message = parent.next_message,
                .input_revision = try store(self).userInputRevision(
                    a,
                    parent.id,
                    parent.event_high,
                ),
                .controller = try controllerObservation(self, a, parent),
                .interface = interface,
                .selection = selection,
                .model = model,
                .target = target,
                .required_current = .{ .items = current },
            };
        }

        fn expectWork(work: workspace.Work, expected: wc.Expected) !void {
            if (!std.meta.eql(work.id, try wp.identity(expected.work, .work)) or
                work.execution_revision != expected.execution_revision or
                work.control_revision != expected.control_revision) return error.StaleConsumer;
        }

        fn expectPort(
            self: *Self,
            a: std.mem.Allocator,
            observed: workspace.WorkObservation,
            selected: anytype,
        ) !void {
            const work = observed.work;
            const port = work.current_port orelse return error.StaleConsumer;
            const pending = observed.occurrence orelse return error.StaleConsumer;
            const bytes = try store(self).object(a, port, null);
            defer a.free(bytes);
            var retained = try contracts.decodeOwned(
                workspace.Port,
                a,
                bytes,
            );
            defer retained.deinit();
            if (!std.meta.eql(retained.value.id, try wp.identity(selected.port, .port)) or
                !std.meta.eql(retained.value.task, work.task) or
                !std.meta.eql(retained.value.work, work.id) or
                !std.meta.eql(retained.value.occurrence, pending.id) or
                retained.value.generation != selected.generation or
                work.port_generation != selected.generation or pending.state != .ready)
                return error.StaleConsumer;
        }

        pub fn open(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            reference: wc.Ref,
        ) !contracts.Decoded(workspace.ReplyObservation) {
            const id = try wp.identity(reference, .observation);
            var saved = try record(
                self,
                workspace.ReplyObservation,
                a,
                "workspace_reply",
                id,
                task_id,
            );
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.id, id) or !std.meta.eql(saved.value.task, task_id) or
                saved.value.evidence != .read or saved.value.evidence.read != .consumer)
                return error.InvalidConsumer;
            var pending = try record(self, occurrence.Occurrence, a, "occurrence", id, task_id);
            defer pending.deinit();
            const acquired = switch (pending.value.state) {
                .settled_reply => |value| value,
                .admitted => |value| if (value == .reply)
                    value.reply
                else
                    return error.InvalidConsumer,
                else => return error.InvalidConsumer,
            };
            if (!std.meta.eql(saved.value.attempt, acquired.attempt) or
                !std.meta.eql(saved.value.request, pending.value.request_object))
                return error.InvalidConsumer;
            return saved;
        }

        pub fn applicable(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            observed: workspace.ConsumerObservation,
        ) !void {
            try observed.requireTask(parent);
            if (observed.input_revision != try store(self).userInputRevision(
                a,
                parent.id,
                parent.event_high,
            ))
                return error.StaleConsumer;
            for (observed.selection.required_current.items) |expected| {
                var current = try self.workspaceWork(
                    a,
                    parent.id,
                    try wp.identity(expected.work, .work),
                );
                defer current.deinit();
                try expectWork(current.value, expected);
            }
            if (observed.selection.target == .model) {
                const selected = observed.selection.target.model;
                const current = try Access.freezeWorkspaceWork(
                    self,
                    a,
                    parent.id,
                    selected.expected.work,
                    false,
                );
                try expectPort(self, a, current, selected);
            }
        }

        pub fn validateRead(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            observed: workspace.ConsumerObservation,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            if (!std.meta.eql(observed.task, parent.id) or
                !std.mem.eql(u8, observed.tenant.bytes, parent.tenant.bytes) or
                !std.meta.eql(observed.application, parent.image) or
                !std.meta.eql(observed.policy, parent.profile) or
                !std.meta.eql(observed.input, parent.input) or
                observed.next_message > parent.next_message) return error.InvalidArchive;
            try Replay.validateControllerReadObservation(
                self,
                a,
                parent,
                observed.controller,
                records,
            );
            try Controller.validateControllerMessageCut(
                self,
                a,
                parent,
                observed.controller.event_watermark,
                observed.next_message,
            );
            if (observed.input_revision != try store(self).userInputRevision(
                a,
                parent.id,
                observed.controller.event_watermark,
            )) return error.InvalidArchive;
            const expected = observed.selection.required_current.items;
            if (observed.required_current.items.len != expected.len) return error.InvalidArchive;
            for (observed.required_current.items, expected) |work, requirement| {
                try expectWork(work.work, requirement);
                try validateWork(self, a, parent, work, records, checked);
            }
            if (observed.selection.target == .model) {
                const target = observed.target orelse return error.InvalidArchive;
                try expectWork(target.work, observed.selection.target.model.expected);
                try expectPort(self, a, target, observed.selection.target.model);
                try validateWork(self, a, parent, target, records, checked);
                if (observed.model == null) return error.InvalidArchive;
            } else if (observed.target != null or observed.model != null)
                return error.InvalidArchive;
        }

        fn validateWork(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            observed: workspace.WorkObservation,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            try Snapshots.validateWorkspaceWorkSnapshotIn(self, parent, observed, records, checked);
            try Replay.validateHistoricalOccurrence(self, a, observed);
        }

        pub fn sameInterface(
            a: std.mem.Allocator,
            observed: workspace.ConsumerObservation,
            authorized: workspace.Authorized,
        ) !void {
            const interface = authorized.consumer orelse return error.InvalidConsumer;
            if (!std.meta.eql(interface, observed.interface)) return error.InvalidArchive;
            const expected = try contracts.encodeOwned(
                ?workspace.ModelBinding,
                a,
                authorized.model,
            );
            defer a.free(expected);
            const actual = try contracts.encodeOwned(?workspace.ModelBinding, a, observed.model);
            defer a.free(actual);
            if (!std.mem.eql(u8, expected, actual)) return error.InvalidArchive;
        }

        pub fn render(
            a: std.mem.Allocator,
            reference: wc.Ref,
            observed: workspace.ConsumerObservation,
            page: wc.Page,
        ) !json.Value {
            const Facts = struct {
                task: state.TaskId,
                application: state.Reference,
                policy: state.Reference,
                input: state.Reference,
                instruction_revision: u64,
                controller: ?state.Digest,
                controller_epoch: u64,
                interface: workspace.ConsumerInterface,
                selection: wc.ConsumerInspection,
                model: ?workspace.ModelBinding,
            };
            const facts: Facts = .{
                .task = observed.task,
                .application = observed.application,
                .policy = observed.policy,
                .input = observed.input,
                .instruction_revision = observed.input_revision,
                .controller = observed.controller.binding,
                .controller_epoch = observed.controller.epoch,
                .interface = observed.interface,
                .selection = observed.selection,
                .model = observed.model,
            };
            const bytes = try json.canonical(a, try values.toJson(Facts, a, facts));
            defer a.free(bytes);
            var result = json.object();
            try json.put(a, &result, "consumer", try values.toJson(wc.Ref, a, reference));
            try json.put(a, &result, "binding", try wp.page(a, bytes, page));
            return result;
        }
    };
}
