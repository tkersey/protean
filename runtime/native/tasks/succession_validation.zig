const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const controllerAt = Controller.controllerAt;
        const controllerBinding = Controller.controllerBinding;
        const controllerEpochAt = Controller.controllerEpochAt;
        const controllerReply = ControllerProtocol.controllerReply;
        const controllerSelection = Context.controllerSelection;
        const record = Records.record;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const store = Lifecycle.store;
        const validateControllerMessageCut = Context.validateControllerMessageCut;
        const validateControllerViewIn = Context.validateControllerViewIn;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Context = @import("controller_context.zig").Operations(Types, Self);
        const ControllerProtocol = @import("controller_protocol.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn validateControllerSuccession(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var saved = try record(
                self,
                state.ControllerSuccession,
                a,
                "controller_succession",
                id,
                parent.id,
            );
            defer saved.deinit();
            const operation_value = saved.value;
            if (!std.meta.eql(operation_value.id, id) or
                !std.meta.eql(operation_value.task, parent.id)) return error.InvalidArchive;
            try validateSuccessionRecord(self, a, parent, operation_value, records, checked);
        }
        fn validateSuccessionAdmissionEvent(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            admission: anytype,
        ) !void {
            const events =
                try store(self).eventsAfter(a, parent.id, admission.event - 1, 1);
            if (events.len != 1) return error.InvalidArchive;
            var event_value = try contracts.decodeOwned(state.Event, a, events[0]);
            defer event_value.deinit();
            if (event_value.value.kind != .controller_requested or
                event_value.value.seq != admission.event or
                event_value.value.revision != admission.revision)
                return error.InvalidArchive;
            const event_data = (try json.parse(a, event_value.value.data.bytes, .{})).value;
            const operation_id =
                json.get(event_data, "operation") orelse return error.InvalidArchive;
            if (operation_id != .string or !same(
                operation_id.string,
                &std.fmt.bytesToHex(id, .lower),
            )) return error.InvalidArchive;
        }
        fn validateSuccessionAdmission(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            interaction: state.ControllerInteraction,
            pending: occurrence.Occurrence,
            admission: anytype,
        ) !void {
            const id = operation_value.id;
            if (admission.revision <= 1 or
                admission.event != operation_value.event_cut + 1 or
                (!std.meta.eql(interaction.model, operation_value.handoff) and !std.meta.eql(
                    interaction.handoff,
                    operation_value.handoff,
                ))) return error.InvalidArchive;
            if (admission.occurrence.state != .ready and admission.occurrence.state != .not_sent)
                return error.InvalidArchive;
            if (!std.meta.eql(admission.occurrence.id, pending.id) or
                !std.meta.eql(admission.occurrence.task, parent.id) or
                admission.occurrence.work != null or
                admission.occurrence.residual != null or
                !std.meta.eql(admission.occurrence.request, pending.request) or !std.meta.eql(
                admission.occurrence.request_object,
                pending.request_object,
            )) return error.InvalidArchive;
            if (admission.occurrence.state == .not_sent) {
                var attempt = try record(
                    self,
                    state.Attempt,
                    a,
                    "attempt",
                    admission.occurrence.state.not_sent.id,
                    parent.id,
                );
                defer attempt.deinit();
                if (!std.meta.eql(attempt.value.occurrence, pending.id))
                    return error.InvalidArchive;
            }

            try validateSuccessionAdmissionEvent(self, a, parent, id, admission);
        }
        fn successionSelection(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            interaction: state.ControllerInteraction,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
        ) !wc.Adoption {
            const id = operation_value.id;
            const selected = if (operation_value.operator_admission) |admission| blk: {
                try validateSuccessionAdmission(
                    self,
                    a,
                    parent,
                    operation_value,
                    interaction,
                    pending,
                    admission,
                );
                var command_value = try contracts.decodeOwned(
                    wc.Adoption,
                    a,
                    try store(self).object(a, operation_value.command, null),
                );
                defer command_value.deinit();
                break :blk try values.fromJson(
                    wc.Adoption,
                    a,
                    try values.toJson(wc.Adoption, a, command_value.value),
                );
            } else blk: {
                if (!std.meta.eql(id, interaction.id) or !std.meta.eql(
                    interaction.handoff,
                    operation_value.handoff,
                )) return error.InvalidArchive;
                if (operation_value.event_cut < interaction.event_cut or
                    operation_value.next_message < interaction.next_message)
                    return error.InvalidArchive;
                const reply =
                    try controllerReply(self, a, parent, pending, request);
                break :blk (try controllerSelection(
                    self,
                    a,
                    parent,
                    reply[0 .. reply.len - 1],
                )) orelse return error.InvalidArchive;
            };

            return selected;
        }
        fn validateSuccessionActivation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            selected: wc.Adoption,
            predecessor: state.ControllerBinding,
            records: []const state.ArchiveRecord,
        ) !void {
            if (operation_value.phase == .activated) {
                const at = operation_value.activation_event orelse return error.InvalidArchive;
                const epoch = operation_value.activated_epoch orelse return error.InvalidArchive;
                const binding_id = (try controllerAt(self, a, parent, at)) orelse
                    return error.InvalidArchive;
                const binding = try controllerBinding(self, a, parent, binding_id);
                if (epoch != (std.math.add(u64, selected.expected_controller_epoch, 1) catch
                    return error.InvalidArchive) or
                    epoch <= predecessor.epoch or
                    binding.epoch != epoch or
                    binding.activated_at != at or
                    !std.meta.eql(binding.predecessor, predecessor.id) or !std.meta.eql(
                    binding.program,
                    operation_value.successor.?,
                ) or at <= operation_value.event_cut) return error.InvalidArchive;
                try requireArchiveRecord(
                    records,
                    .controller_residual,
                    operation_value.residual orelse return error.InvalidArchive,
                );
            } else if (operation_value.activation_event != null or
                operation_value.activated_epoch != null or operation_value.residual != null)
                return error.InvalidArchive;
        }
        fn validateSuccessionSelection(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            interaction: state.ControllerInteraction,
            selected: wc.Adoption,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const id = operation_value.id;
            const command = try contracts.encodeOwned(wc.Adoption, a, selected);
            if (!std.meta.eql(operation_value.command, state.Reference{
                .digest = storage.digest(command),
                .bytes = command.len,
            })) return error.InvalidArchive;
            const preparing = operation_value.phase == .preparing or
                operation_value.phase == .ready;
            if (preparing != std.meta.eql(parent.controller_succession, @as(?state.Digest, id)))
                return error.InvalidArchive;
            if (preparing and (!std.meta.eql(parent.controller, operation_value.predecessor) or
                !std.meta.eql(parent.checkpoint, operation_value.checkpoint) or
                !std.meta.eql(parent.outcome, operation_value.outcome) or !std.meta.eql(
                parent.current_occurrence,
                operation_value.handoff,
            ))) return error.InvalidArchive;
            const successful = preparing or operation_value.phase == .activated;
            if (successful == (operation_value.diagnostic != null)) return error.InvalidArchive;
            if (operation_value.phase == .rejected) {
                if (operation_value.successor != null or
                    operation_value.converter != null or
                    operation_value.conversion_input != null or
                    operation_value.conversion_work != null or
                    operation_value.converted != null or
                    operation_value.boot != null)
                    return error.InvalidArchive;
            } else {
                try validateSuccessionPrograms(
                    self,
                    a,
                    parent,
                    operation_value,
                    interaction,
                    selected,
                    records,
                    checked,
                );
            }
        }
        fn validateSuccessionBoot(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            successor: workspace.Program,
        ) !void {
            if (operation_value.boot) |boot| {
                const converted = try store(self).object(
                    a,
                    operation_value.converted orelse return error.InvalidArchive,
                    null,
                );
                const anchor = try contracts.encodeOwned(contracts.controller.TaskAnchor, a, .{
                    .task = parent.id,
                });
                const initial = try std.mem.concat(a, u8, &.{ anchor, converted });
                const image =
                    try store(self).object(a, successor.description.image, null);
                var runtime = try self.program.retainRuntime();
                defer runtime.deinit();
                const driver = try evaluator.Driver.openSelected(
                    self.allocator,
                    image,
                    .{ .initial_args = initial },
                    &runtime,
                );
                defer {
                    driver.retire() catch store(self).fence();
                    driver.destroy() catch store(self).fence();
                }
                const actual = try driver.drive(a, .none, 256);
                if (!std.meta.eql(boot.checkpoint, state.Reference{
                    .digest = storage.digest(actual.checkpoint),
                    .bytes = actual.checkpoint.len,
                }) or !std.meta.eql(boot.outcome, state.Reference{
                    .digest = storage.digest(actual.outcome),
                    .bytes = actual.outcome.len,
                })) return error.InvalidArchive;
                var outcome =
                    try data.invocation.decode(data.invocation.Outcome, a, actual.outcome);
                defer outcome.deinit();
                if (outcome.value != .requested) return error.InvalidArchive;
                var boot_request = try data.invocation.decode(
                    data.invocation.Request,
                    a,
                    outcome.value.requested.request,
                );
                defer boot_request.deinit();
                if (!same(
                    boot_request.value.binding.semantic_identity,
                    contracts.controller.boot_identity,
                ) or !same(boot_request.value.binding.payload, initial))
                    return error.InvalidArchive;
            } else if (operation_value.phase == .ready or operation_value.phase == .activated)
                return error.InvalidArchive;
        }
        fn validateSuccessionConversion(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            interaction: state.ControllerInteraction,
            converter_id: state.Digest,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const conversion_input = operation_value.conversion_input orelse
                return error.InvalidArchive;
            const input = try store(self).object(a, conversion_input, null);
            const carry = try store(self).object(a, interaction.carry, null);
            if (input.len < carry.len or !same(input[0..carry.len], carry))
                return error.InvalidArchive;
            var view =
                try contracts.decodeOwned(contracts.controller.OwnerView, a, input[carry.len..]);
            defer view.deinit();
            if (!std.meta.eql(view.value.task, parent.id) or
                view.value.event_cut != operation_value.event_cut or
                view.value.next_message != operation_value.next_message or
                !std.meta.eql(view.value.policy, operation_value.policy.digest) or !same(
                view.value.input.bytes,
                try store(self).object(a, parent.input, null),
            )) return error.InvalidArchive;
            try validateControllerViewIn(
                self,
                a,
                parent,
                view.value,
                operation_value.view_works.items,
                records,
                checked,
            );
            if (operation_value.conversion_work) |work_id| {
                try requireArchiveRecord(records, .workspace_work, work_id);
                var work = try self.workspaceWork(a, parent.id, work_id);
                defer work.deinit();
                if (work.value.trial != null or !std.meta.eql(work.value.program, converter_id) or
                    !std.meta.eql(work.value.input, conversion_input)) return error.InvalidArchive;
                if (operation_value.converted) |converted|
                    if (work.value.outcome_kind != .completed or
                        !std.meta.eql(work.value.result, converted)) return error.InvalidArchive;
            } else if (operation_value.converted != null or operation_value.boot != null)
                return error.InvalidArchive;
        }
        fn validateSuccessionPrograms(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            interaction: state.ControllerInteraction,
            selected: wc.Adoption,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const successor_id = operation_value.successor orelse return error.InvalidArchive;
            const converter_id = operation_value.converter orelse return error.InvalidArchive;
            if (!std.meta.eql(successor_id, try wp.identity(selected.successor, .program)) or
                !std.meta.eql(converter_id, try wp.identity(selected.converter, .program)) or
                selected.expected_controller_epoch != try controllerEpochAt(
                    self,
                    a,
                    parent,
                    operation_value.event_cut,
                ) or !same(
                selected.expected_handoff_identity.bytes,
                &std.fmt.bytesToHex(interaction.id, .lower),
            )) return error.InvalidArchive;
            var successor = try self.workspaceProgram(a, parent.id, successor_id);
            defer successor.deinit();
            const descriptor = successor.value.description.controller orelse
                return error.InvalidArchive;
            var converter = try self.workspaceProgram(a, parent.id, converter_id);
            defer converter.deinit();
            const expected = try @import("../controller_construction.zig").conversionSchema(
                a,
                try store(self).object(a, interaction.carry_schema, null),
            );
            if (converter.value.description.controller != null or
                converter.value.description.ports.items.len != 0 or
                !std.meta.eql(
                    converter.value.description.input_schema.digest,
                    storage.digest(expected),
                ) or !std.meta.eql(
                converter.value.description.result_schema.digest,
                storage.digest(descriptor.private_input.bytes),
            )) return error.InvalidArchive;
            try validateSuccessionConversion(
                self,
                a,
                parent,
                operation_value,
                interaction,
                converter_id,
                records,
                checked,
            );
            try validateSuccessionBoot(self, a, parent, operation_value, successor.value);
        }
        fn validateSuccessionRecord(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                operation_value.handoff,
                parent.id,
            );
            defer route.deinit();
            var interaction = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                route.value.interaction orelse return error.InvalidArchive,
                parent.id,
            );
            defer interaction.deinit();
            if (!std.meta.eql(operation_value.predecessor, interaction.value.controller) or
                !std.meta.eql(operation_value.policy, interaction.value.policy) or !std.meta.eql(
                @as(?state.Digest, operation_value.predecessor),
                try controllerAt(self, a, parent, operation_value.event_cut),
            )) return error.InvalidArchive;
            try validateControllerMessageCut(
                self,
                a,
                parent,
                operation_value.event_cut,
                operation_value.next_message,
            );
            try validateSuccessionHandoff(
                self,
                a,
                parent,
                operation_value,
                interaction.value,
                records,
                checked,
            );
        }
        fn validateSuccessionHandoff(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            interaction: state.ControllerInteraction,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const predecessor =
                try controllerBinding(self, a, parent, operation_value.predecessor);
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                operation_value.handoff,
                parent.id,
            );
            defer pending.deinit();
            var request = try data.invocation.decode(
                data.invocation.Request,
                a,
                try store(self).object(a, pending.value.request_object, null),
            );
            defer request.deinit();
            const selected = try successionSelection(
                self,
                a,
                parent,
                operation_value,
                interaction,
                pending.value,
                request.value,
            );
            try validateSuccessionSelection(
                self,
                a,
                parent,
                operation_value,
                interaction,
                selected,
                records,
                checked,
            );
            try validateSuccessionActivation(
                self,
                a,
                parent,
                operation_value,
                selected,
                predecessor,
                records,
            );
        }
    };
}
