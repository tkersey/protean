const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const Step = task_types.Step;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const controllerBinding = Controller.controllerBinding;
        const initialCustody = Lifecycle.initialCustody;
        const persistScheduled = Records.persistScheduled;
        const placementSite = Lifecycle.placementSite;
        const putRootOperation = Controller.putRootOperation;
        const residualPublication = Residuals.residualPublication;
        const retire = Lifecycle.retire;
        const rootIdentity = Controller.rootIdentity;
        const store = Lifecycle.store;
        const subjectPublicationEvent = Records.subjectPublicationEvent;
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const controller_succession_ops =
            @import("controller_succession.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn activateController(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: state.ControllerSuccession,
        ) !Step {
            try controller_succession_ops.controllerCutCurrent(self, a, parent, initial);
            const boot = initial.boot orelse return error.CorruptState;
            var program = try self.workspaceProgram(a, parent.id, initial.successor orelse
                return error.CorruptState);
            defer program.deinit();
            const old = try controllerBinding(self, a, parent, initial.predecessor);
            const epoch = try std.math.add(u64, parent.controller_epoch, 1);
            const bytes = try store(self).object(a, boot.outcome, null);
            defer a.free(bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, bytes);
            defer outcome.deinit();
            if (outcome.value != .requested) return error.InvalidControllerBoot;
            var request = try data.invocation.decode(
                data.invocation.Request,
                a,
                outcome.value.requested.request,
            );
            defer request.deinit();
            if (!same(request.value.binding.semantic_identity, contracts.controller.boot_identity))
                return error.InvalidControllerBoot;
            return activateDecodedController(
                self,
                a,
                parent,
                initial,
                program.value,
                old,
                epoch,
                outcome.value.requested.request,
                request.value,
            );
        }
        const ControllerActivationPlacement = controllerActivationPlacementType();
        fn controllerActivationPlacementType() type {
            return struct {
                behavior: ?@import("../placement.zig").Signed(@import("../placement.zig").Behavior),
                custody: ?@import("../placement.zig").Custody,
            };
        }
        fn controllerActivationPlacement(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: state.ControllerSuccession,
            old: state.ControllerBinding,
            epoch: u64,
            binding_id: state.Digest,
        ) !ControllerActivationPlacement {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var custody = if (self.profile.placement != null)
                try journal.custody(store(self), a, .{ .task = parent.id })
            else
                null;
            defer if (custody) |*saved| saved.deinit();
            var next_custody: ?p.Custody = null;
            const behavior: ?p.Signed(p.Behavior) = if (self.profile.placement) |placement| blk: {
                const site = try placementSite(self);
                var current = if (custody) |saved| saved.value else try initialCustody(
                    self,
                    a,
                    .{ .task = parent.id },
                    site,
                );
                try current.requireLocal(site);
                if (current.epoch != parent.controller_epoch) return error.StaleController;
                current.epoch = epoch;
                next_custody = current;
                break :blk try p.sign(p.Behavior, a, placement.signing_key, .{
                    .operation = initial.id,
                    .task = parent.id,
                    .owner = site,
                    .previous_epoch = parent.controller_epoch,
                    .epoch = epoch,
                    .predecessor = old.id,
                    .successor = binding_id,
                    .event_cut = parent.event_high,
                });
            } else null;

            return .{ .behavior = behavior, .custody = next_custody };
        }
        fn activatedControllerTask(
            parent: state.Task,
            boot: anytype,
            binding_id: state.Digest,
            occurrence_id: state.Digest,
            epoch: u64,
        ) !state.Task {
            var value = parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.execution_revision = try std.math.add(u64, value.execution_revision, 1);
            value.controller = binding_id;
            value.controller_epoch = epoch;
            value.controller_interaction = null;
            value.controller_succession = null;
            value.controller_runtime = null;
            value.realization_revision = 0;
            value.checkpoint = boot.checkpoint;
            value.outcome = boot.outcome;
            value.outcome_kind = .requested;
            value.current_occurrence = occurrence_id;
            value.schedule = .queued;
            value.blocker = null;

            return value;
        }
        const ControllerActivationRecords = controllerActivationRecordsType();
        fn controllerActivationRecordsType() type {
            return struct {
                binding: state.ControllerBinding,
                residual: state.ControllerResidual,
            };
        }
        fn controllerActivationRecords(
            parent: state.Task,
            initial: state.ControllerSuccession,
            program: workspace.Program,
            old: state.ControllerBinding,
            request: data.invocation.Request,
            binding_id: state.Digest,
            residual_id: state.Digest,
            epoch: u64,
            activation_event: u64,
        ) ControllerActivationRecords {
            const binding: state.ControllerBinding = .{
                .id = binding_id,
                .task = parent.id,
                .epoch = epoch,
                .activated_at = activation_event,
                .program = initial.successor.?,
                .image = program.description.image,
                .program_identity = request.binding.program_identity,
                .predecessor = old.id,
            };
            const residual: state.ControllerResidual = .{
                .id = residual_id,
                .task = parent.id,
                .controller = old.id,
                .succession = initial.id,
                .runtime = parent.controller_runtime,
                .initial_checkpoint = parent.checkpoint,
                .checkpoint = parent.checkpoint,
                .outcome = parent.outcome,
                .outcome_kind = parent.outcome_kind,
                .current_occurrence = parent.current_occurrence,
                .execution_revision = parent.execution_revision,
            };

            return .{ .binding = binding, .residual = residual };
        }
        fn writeControllerActivation(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            initial: state.ControllerSuccession,
            operation_value: state.ControllerSuccession,
            records: ControllerActivationRecords,
            placement: ControllerActivationPlacement,
            occurrence_id: state.Digest,
            request: data.invocation.Request,
            request_bytes: []const u8,
        ) !void {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            if (placement.behavior) |decision| {
                try store(self).createRecord(
                    p.BehaviorRecord,
                    "placement_behavior",
                    initial.id,
                    value.id,
                    .{ .id = initial.id, .task = value.id, .decision = decision },
                );
                try journal.putCustody(store(self), a, placement.custody.?);
            }
            try store(self).createRecord(
                state.ControllerBinding,
                "controller_binding",
                records.binding.id,
                value.id,
                records.binding,
            );
            try store(self).createRecord(
                state.ControllerResidual,
                "controller_residual",
                records.residual.id,
                value.id,
                records.residual,
            );
            try store(self).putRecord(
                state.ControllerSuccession,
                "controller_succession",
                initial.id,
                value.id,
                operation_value,
            );
            try writeActivationOccurrence(
                self,
                value,
                records.binding,
                occurrence_id,
                request,
                request_bytes,
            );
        }
        fn writeActivationOccurrence(
            self: *Self,
            value: state.Task,
            binding: state.ControllerBinding,
            occurrence_id: state.Digest,
            request: data.invocation.Request,
            request_bytes: []const u8,
        ) !void {
            try store(self).createRecord(
                occurrence.Occurrence,
                "occurrence",
                occurrence_id,
                value.id,
                .{
                    .id = occurrence_id,
                    .task = value.id,
                    .request = request.request_identity,
                    .request_object = try store(self).putObject(request_bytes),
                },
            );
            try store(self).createRecord(
                workspace.ExecutionRoute,
                "execution_route",
                occurrence_id,
                value.id,
                .{
                    .id = occurrence_id,
                    .task = value.id,
                    .work = null,
                    .image = binding.image,
                    .program_identity = binding.program_identity,
                    .controller = binding.id,
                    .controller_epoch = binding.epoch,
                },
            );
        }
        fn commitControllerActivation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: *state.Task,
            initial: state.ControllerSuccession,
            operation_value: state.ControllerSuccession,
            records: ControllerActivationRecords,
            placement: ControllerActivationPlacement,
            occurrence_id: state.Digest,
            request: data.invocation.Request,
            request_bytes: []const u8,
            event_data: []const u8,
        ) !Step {
            try store(self).begin();
            defer store(self).rollback();
            try writeControllerActivation(
                self,
                a,
                value.*,
                initial,
                operation_value,
                records,
                placement,
                occurrence_id,
                request,
                request_bytes,
            );
            try putRootOperation(self, a, .{
                .id = rootIdentity(value.id),
                .task = value.id,
                .execution_revision = value.execution_revision,
                .pending = null,
            });
            try subjectPublicationEvent(self, value, .controller, event_data, &.{}, &.{
                try residualPublication(self, a, records.residual),
            }, null, null, .{ .before = .from(parent), .after = .from(value.*) });
            try persistScheduled(
                self,
                a,
                value.*,
                parent.revision,
                "controller.activate",
                .preserve,
                &.{ .{ .task = value.id, .residual = records.residual.id }, .{ .task = value.id } },
            );
            return .progressed;
        }
        fn activateDecodedController(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: state.ControllerSuccession,
            program: workspace.Program,
            old: state.ControllerBinding,
            epoch: u64,
            request_bytes: []const u8,
            request: data.invocation.Request,
        ) !Step {
            var binding_id: state.Digest = undefined;
            var residual_id: state.Digest = undefined;
            var occurrence_id: state.Digest = undefined;
            try self.io.randomSecure(&binding_id);
            try self.io.randomSecure(&residual_id);
            try self.io.randomSecure(&occurrence_id);
            const placement =
                try controllerActivationPlacement(self, a, parent, initial, old, epoch, binding_id);
            const event_data = try std.fmt.allocPrint(
                a,
                "{{\"operation\":\"{s}\",\"phase\":\"activated\",\"epoch\":\"{d}\"}}",
                .{ std.fmt.bytesToHex(initial.id, .lower), epoch },
            );
            defer a.free(event_data);
            try self.runnable.ensureUnusedCapacity(self.allocator, 2);
            try retire(self, a);
            var value = try activatedControllerTask(
                parent,
                initial.boot.?,
                binding_id,
                occurrence_id,
                epoch,
            );
            var operation_value = initial;
            operation_value.phase = .activated;
            operation_value.activated_epoch = epoch;
            operation_value.activation_event = try std.math.add(u64, value.event_high, 1);
            operation_value.residual = residual_id;
            const records = controllerActivationRecords(
                parent,
                initial,
                program,
                old,
                request,
                binding_id,
                residual_id,
                epoch,
                operation_value.activation_event.?,
            );
            return commitControllerActivation(
                self,
                a,
                parent,
                &value,
                initial,
                operation_value,
                records,
                placement,
                occurrence_id,
                request,
                request_bytes,
                event_data,
            );
        }
    };
}
