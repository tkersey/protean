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
const Admission = task_types.Admission;
const ControllerAdoption = task_types.ControllerAdoption;
const ControllerHandoff = task_types.ControllerHandoff;
const ControllerSuccessionAdmission = task_types.ControllerSuccessionAdmission;
const OccurrenceSubject = task_types.OccurrenceSubject;
const Step = task_types.Step;
const Work = task_types.Work;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const activateController = Activation.activateController;
        const blockedOccurrence = Root.blockedOccurrence;
        const compatible = ControllerState.compatible;
        const controllerBinding = ControllerState.controllerBinding;
        const controllerOverlay = Context.controllerOverlay;
        const controllerPermission = Context.controllerPermission;
        const controllerReply = ControllerProtocol.controllerReply;
        const controllerSelection = Context.controllerSelection;
        const controllerView = Context.controllerView;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const event = Records.event;
        const freeControllerViewWorks = Context.freeControllerViewWorks;
        const occurrenceSubject = Root.occurrenceSubject;
        const persist = Records.persist;
        const persistScheduled = Records.persistScheduled;
        const placementSite = Lifecycle.placementSite;
        const receipt = Records.receipt;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const retire = Lifecycle.retire;
        const rootOperation = ControllerState.rootOperation;
        const runnableRemove = Scheduling.runnableRemove;
        const store = Lifecycle.store;
        const workspaceStartAdmitted = Start.workspaceStartAdmitted;
        const Activation = @import("controller_activation.zig").Operations(Types, Self);
        const Context = @import("controller_context.zig").Operations(Types, Self);
        const ControllerProtocol = @import("controller_protocol.zig").Operations(Types, Self);
        const ControllerState = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Control = @import("workspace_control.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Start = @import("workspace_start.zig").Operations(Types, Self);
        fn saveControllerSuccession(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
        ) !Step {
            var value = parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (operation_value.diagnostic != null) value.controller_succession = null;
            const parked = operation_value.diagnostic != null and
                operation_value.operator_admission != null and
                parent.cancellation == null;
            if (parked) value.schedule = .parked;
            try store(self).begin();
            defer store(self).rollback();
            try store(self).putRecord(
                state.ControllerSuccession,
                "controller_succession",
                operation_value.id,
                value.id,
                operation_value,
            );
            try persist(self, a, value, parent.revision, "controller.preparation", .preserve);
            if (parked) runnableRemove(self, value.id);
            return .progressed;
        }
        fn controllerPreparationFailure(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            err: anyerror,
        ) !Step {
            if (err == error.OutOfMemory or err == error.StorageUnavailable or
                err == error.CorruptState or err == error.CorruptObject)
                return err;
            var next = operation_value;
            next.phase = if (err == error.Canceled or err == error.StaleInstructions or
                err == error.StaleController) .aborted else .failed;
            next.diagnostic = .{ .operation = next.id, .code = .{
                .bytes = @errorName(err),
            }, .observation = .{ .bytes = @errorName(err) } };
            if (next.conversion_work) |id| {
                var work = try self.workspaceWork(a, parent.id, id);
                defer work.deinit();
                if (!work.value.terminal() and work.value.cancellation == null) {
                    const operation_id = try std.fmt.allocPrint(a, "controller:{s}:abort", .{
                        std.fmt.bytesToHex(next.id, .lower),
                    });
                    defer a.free(operation_id);
                    _ = try self.workspaceControl(
                        a,
                        operation_id,
                        parent.id,
                        id,
                        work.value.execution_revision,
                        work.value.control_revision,
                        .{ .cancel = .{ .bytes = "Controller preparation invalidated" } },
                    );
                }
            }
            var current = try self.task(a, parent.id);
            defer current.deinit();
            return saveControllerSuccession(self, a, current.value, next);
        }
        pub fn controllerCutCurrent(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
        ) !void {
            if (!std.meta.eql(parent.controller, operation_value.predecessor) or
                !std.meta.eql(parent.current_occurrence, operation_value.handoff) or !std.meta.eql(
                parent.checkpoint,
                operation_value.checkpoint,
            )) return error.StaleController;
            if (parent.next_message != operation_value.next_message or !std.meta.eql(
                parent.profile,
                operation_value.policy,
            )) return error.StaleInstructions;
            if (parent.cancellation != null) return error.Canceled;
            if (!try controllerPermission(self, a, parent)) return error.Unauthorized;
            try requireCustody(self, a, parent.id, null);
            if (self.profile.placement != null) {
                const p = @import("../placement.zig");
                const journal = @import("../placement_journal.zig");
                const site = try placementSite(self);
                try journal.requireSettled(store(self), a, .{ .task = parent.id }, site);
                var moves = try store(self).database.prepare(
                    "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                        "HERE r.kind='placement_move' AND r.task=?",
                    &.{.{ .blob = &parent.id }},
                );
                defer moves.deinit();
                while (try moves.step() == .row) {
                    var moving = try contracts.decodeOwned(p.Move, a, try moves.bytes(0));
                    defer moving.deinit();
                    if (std.meta.eql(moving.value.owner, site) and moving.value.decision == null and
                        !moving.value.cancelled)
                        return error.UnsettledRemoteControl;
                }
            }
        }
        pub fn pumpControllerSuccession(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
        ) !Step {
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
            if (operation_value.phase != .preparing and operation_value.phase != .ready)
                return error.CorruptState;
            controllerCutCurrent(self, a, parent, operation_value) catch |err|
                return controllerPreparationFailure(self, a, parent, operation_value, err);
            if (operation_value.phase == .ready)
                return activateController(self, a, parent, operation_value);
            if (operation_value.conversion_work == null) {
                return startControllerConversion(self, a, parent, operation_value);
            }

            return pumpControllerConversion(self, a, parent, operation_value);
        }
        fn startControllerConversion(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
        ) !Step {
            const id = operation_value.id;

            const operation_id = try std.fmt.allocPrint(a, "controller:{s}:convert", .{
                std.fmt.bytesToHex(id, .lower),
            });
            defer a.free(operation_id);
            const input = try store(self).object(
                a,
                operation_value.conversion_input orelse return error.CorruptState,
                null,
            );
            defer a.free(input);
            _ = workspaceStartAdmitted(
                self,
                a,
                operation_id,
                parent.id,
                operation_value.converter orelse return error.CorruptState,
                input,
                .{ .stop = .terminal, .continuation = .owner_scheduled },
                null,
                null,
                null,
                .{ .none = .{} },
                operation_value,
                null,
            ) catch |err|
                return controllerPreparationFailure(self, a, parent, operation_value, err);
            return .progressed;
        }
        fn pumpControllerConversion(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
        ) !Step {
            var conversion =
                try self.workspaceWork(a, parent.id, operation_value.conversion_work.?);
            defer conversion.deinit();
            if (!conversion.value.terminal()) {
                if (conversion.value.blocker != null or conversion.value.current_occurrence != null)
                    return controllerPreparationFailure(
                        self,
                        a,
                        parent,
                        operation_value,
                        error.ControllerConversionBlocked,
                    );
                return .idle;
            }
            if (conversion.value.outcome_kind != .completed)
                return controllerPreparationFailure(
                    self,
                    a,
                    parent,
                    operation_value,
                    if (conversion.value.outcome_kind == .cancelled)
                        error.ControllerConversionCanceled
                    else
                        error.ControllerConversionFailed,
                );
            return prepareControllerBoot(self, a, parent, operation_value, conversion.value);
        }
        fn prepareControllerBoot(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            conversion: workspace.Work,
        ) !Step {
            const private_ref = conversion.result orelse return error.CorruptState;
            const private = try store(self).object(a, private_ref, null);
            defer a.free(private);
            var successor = try self.workspaceProgram(
                a,
                parent.id,
                operation_value.successor orelse return error.CorruptState,
            );
            defer successor.deinit();
            const descriptor = successor.value.description.controller orelse
                return error.CorruptState;
            var schema = try data.schema.decode(a, descriptor.private_input.bytes);
            defer schema.deinit();
            try data.schema.validateValue(a, schema.descriptor, private);
            const anchor = try contracts.encodeOwned(contracts.controller.TaskAnchor, a, .{
                .task = parent.id,
            });
            defer a.free(anchor);
            const input = try std.mem.concat(a, u8, &.{ anchor, private });
            defer a.free(input);
            const image =
                try store(self).object(a, successor.value.description.image, null);
            defer a.free(image);
            return driveControllerBoot(self, a, parent, operation_value, private_ref, input, image);
        }
        fn commitControllerBoot(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: state.ControllerSuccession,
            private_ref: state.Reference,
            publication: anytype,
        ) !Step {
            var operation_value = initial;
            const id = operation_value.id;
            operation_value.converted = private_ref;
            operation_value.phase = .ready;
            var value = parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            operation_value.boot = .{
                .checkpoint = try store(self).putObject(publication.checkpoint),
                .outcome = try store(self).putObject(publication.outcome),
            };
            try store(self).putRecord(
                state.ControllerSuccession,
                "controller_succession",
                id,
                parent.id,
                operation_value,
            );
            try persist(self, a, value, parent.revision, "controller.boot-ready", .preserve);
            try retire(self, a);
            return .progressed;
        }
        fn driveControllerBoot(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_value: state.ControllerSuccession,
            private_ref: state.Reference,
            input: []const u8,
            image: []const u8,
        ) !Step {
            const id = operation_value.id;
            try retire(self, a);
            var runtime = try self.program.retainRuntime();
            defer runtime.deinit();
            const driver = evaluator.Driver.openSelected(
                self.allocator,
                image,
                .{ .initial_args = input },
                &runtime,
            ) catch |err| return controllerPreparationFailure(
                self,
                a,
                parent,
                operation_value,
                err,
            );
            self.active = .{
                .task = parent.id,
                .subject = .{ .preparation = id },
                .execution_revision = 0,
                .driver = driver,
            };
            const publication = driver.drive(a, .none, 256) catch |err| {
                try retire(self, a);
                return controllerPreparationFailure(self, a, parent, operation_value, err);
            };
            defer a.free(publication.outcome);
            var outcome =
                try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer outcome.deinit();
            if (outcome.value != .requested) {
                try retire(self, a);
                return controllerPreparationFailure(
                    self,
                    a,
                    parent,
                    operation_value,
                    error.InvalidControllerBoot,
                );
            }
            var request = try data.invocation.decode(
                data.invocation.Request,
                a,
                outcome.value.requested.request,
            );
            defer request.deinit();
            if (!same(
                request.value.binding.semantic_identity,
                contracts.controller.boot_identity,
            ) or !same(request.value.binding.payload, input)) return error.InvalidControllerBoot;
            return commitControllerBoot(self, a, parent, operation_value, private_ref, publication);
        }
        fn admitControllerSuccession(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            interaction: state.ControllerInteraction,
            command: wc.Adoption,
            operator: bool,
        ) !ControllerSuccessionAdmission {
            try validateControllerSuccessionAdmission(
                self,
                a,
                parent,
                interaction,
                command,
                operator,
            );
            const successor_id = try wp.identity(command.successor, .program);
            const converter_id = try wp.identity(command.converter, .program);
            var successor = try self.workspaceProgram(a, parent.id, successor_id);
            defer successor.deinit();
            _ = successor.value.description.controller orelse
                return error.InvalidControllerBinding;
            try validateControllerSelectedTrial(self, a, parent, command, successor_id);
            try validateControllerConversion(
                self,
                a,
                parent,
                interaction,
                successor.value,
                converter_id,
            );
            const carry = try store(self).object(a, interaction.carry, null);
            defer a.free(carry);
            const view = try controllerView(self, a, parent);
            defer a.free(view.bytes);
            errdefer freeControllerViewWorks(a, view.works);
            return .{
                .successor = successor_id,
                .converter = converter_id,
                .input = try std.mem.concat(a, u8, &.{ carry, view.bytes }),
                .works = view.works,
            };
        }
        fn validateControllerConversion(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            interaction: state.ControllerInteraction,
            successor: workspace.Program,
            converter_id: state.Digest,
        ) !void {
            var converter = try self.workspaceProgram(a, parent.id, converter_id);
            defer converter.deinit();
            const conversion = converter.value.description;
            if (conversion.controller != null or conversion.ports.items.len != 0 or
                (conversion.source_kind != .source_records and
                    conversion.source_kind != .component_recipe and
                    conversion.source_kind != .source_derivation))
                return error.ImpureControllerConversion;
            const carry_schema =
                try store(self).object(a, interaction.carry_schema, null);
            defer a.free(carry_schema);
            const expected_input =
                try @import("../controller_construction.zig").conversionSchema(a, carry_schema);
            defer a.free(expected_input);
            if (!std.meta.eql(conversion.input_schema.digest, storage.digest(expected_input)) or
                !std.meta.eql(
                    conversion.result_schema.digest,
                    storage.digest(successor.description.controller.?.private_input.bytes),
                )) return error.ControllerConversionSchemaMismatch;
            const result = try values.schemaBytes(Types.Output, a);
            defer a.free(result);
            const failure = try values.schemaBytes(Types.Failure, a);
            defer a.free(failure);
            if (!std.meta.eql(successor.description.result_schema.digest, storage.digest(result)) or
                !std.meta.eql(successor.description.failure_schema.digest, storage.digest(failure)))
                return error.ControllerResultSchemaMismatch;
        }
        fn validateControllerSelectedTrial(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: wc.Adoption,
            successor_id: state.Digest,
        ) !void {
            if (command.trial == .selected) {
                var work = try self.workspaceWork(
                    a,
                    parent.id,
                    try wp.identity(command.trial.selected, .work),
                );
                defer work.deinit();
                if (work.value.trial == null or work.value.outcome_kind != .completed or
                    !std.meta.eql(work.value.program, successor_id))
                    return error.IncompatibleControllerTrial;
                var trial = try record(
                    self,
                    workspace.Trial,
                    a,
                    "workspace_trial",
                    work.value.trial.?,
                    parent.id,
                );
                defer trial.deinit();
                if (!std.meta.eql(trial.value.policy, parent.profile))
                    return error.IncompatibleControllerTrial;
            }
        }
        fn validateControllerSuccessionAdmission(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            interaction: state.ControllerInteraction,
            command: wc.Adoption,
            operator: bool,
        ) !void {
            if (!try controllerPermission(self, a, parent)) return error.Unauthorized;
            _ = try controllerBinding(self, a, parent, interaction.controller);
            if (command.expected_controller_epoch != parent.controller_epoch or
                (!operator and interaction.epoch != parent.controller_epoch) or
                !same(
                    command.expected_handoff_identity.bytes,
                    &std.fmt.bytesToHex(interaction.id, .lower),
                ) or !std.meta.eql(parent.controller, interaction.controller))
                return error.StaleController;
            if ((!operator and parent.next_message != interaction.next_message) or
                !std.meta.eql(parent.profile, interaction.policy)) return error.StaleInstructions;
            if (parent.cancellation != null) return error.Canceled;
            try requireCustody(self, a, parent.id, null);
        }
        fn controllerHandoff(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            response: []const u8,
        ) !ControllerHandoff {
            const command = (try controllerSelection(self, a, initial, response)) orelse
                return .ordinary;
            const canonical = try contracts.encodeOwned(wc.Adoption, a, command);
            defer a.free(canonical);
            const id = initial.controller_interaction orelse return error.InvalidControllerBinding;
            if (try controllerHandoffReplay(self, a, initial, id, canonical)) |prior| return prior;
            var interaction = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                id,
                initial.id,
            );
            defer interaction.deinit();
            if (!std.meta.eql(interaction.value.handoff, pending.id))
                return error.InvalidControllerBinding;
            var operation_value: state.ControllerSuccession = .{
                .id = id,
                .task = initial.id,
                .command = undefined,
                .predecessor = interaction.value.controller,
                .handoff = pending.id,
                .checkpoint = initial.checkpoint,
                .outcome = initial.outcome,
                .event_cut = initial.event_high,
                .next_message = initial.next_message,
                .policy = initial.profile,
                .phase = .preparing,
            };
            defer freeControllerViewWorks(a, operation_value.view_works.items);
            var input: ?[]u8 = null;
            defer if (input) |bytes| a.free(bytes);
            if (admitControllerSuccession(
                self,
                a,
                initial,
                interaction.value,
                command,
                false,
            )) |admitted| {
                operation_value.successor = admitted.successor;
                operation_value.converter = admitted.converter;
                input = admitted.input;
                operation_value.view_works = .{ .items = admitted.works };
            } else |err| {
                if (err == error.OutOfMemory or err == error.StorageUnavailable or
                    err == error.CorruptState or err == error.CorruptObject)
                    return err;
                operation_value.phase = .rejected;
                operation_value.diagnostic = .{ .operation = id, .code = .{
                    .bytes = @errorName(err),
                }, .observation = .{ .bytes = @errorName(err) } };
            }
            return saveControllerHandoff(self, a, initial, &operation_value, canonical, input);
        }
        fn saveControllerHandoff(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            operation_value: *state.ControllerSuccession,
            canonical: []const u8,
            input: ?[]const u8,
        ) !ControllerHandoff {
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (operation_value.phase == .preparing) {
                value.controller_succession = operation_value.id;
            }
            try store(self).begin();
            defer store(self).rollback();
            operation_value.command = try store(self).putObject(canonical);
            if (input) |bytes| operation_value.conversion_input =
                try store(self).putObject(bytes);
            try store(self).createRecord(
                state.ControllerSuccession,
                "controller_succession",
                operation_value.id,
                initial.id,
                operation_value.*,
            );
            try persist(self, a, value, initial.revision, "controller.prepare", .preserve);
            return .progressed;
        }
        fn controllerHandoffReplay(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            id: state.Digest,
            canonical: []const u8,
        ) !?ControllerHandoff {
            if (try store(self).recordBytes(a, "controller_succession", id, initial.id)) |bytes| {
                defer a.free(bytes);
                var prior = try contracts.decodeOwned(state.ControllerSuccession, a, bytes);
                defer prior.deinit();
                if (!std.meta.eql(prior.value.command.digest, storage.digest(canonical)))
                    return error.OperationConflict;
                if (prior.value.diagnostic) |diagnostic| return .{
                    .diagnostic = .{ .operation = diagnostic.operation, .code = .{
                        .bytes = try a.dupe(u8, diagnostic.code.bytes),
                    }, .observation = .{
                        .bytes = try a.dupe(u8, diagnostic.observation.bytes),
                    } },
                };
                return .progressed;
            }
            return null;
        }
        fn controllerRecoveryCut(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
        ) !state.ControllerInteraction {
            if (parent.terminal() or parent.controller_succession != null or
                parent.cancellation != null)
                return error.ControllerRecoveryUnavailable;
            if (self.active) |active| if (std.meta.eql(active.task, parent.id) and
                active.subject == .root and active.root_control != null)
                return error.ControllerRecoveryUnavailable;
            var outer = try rootOperation(self, a, parent);
            defer if (outer) |*saved| saved.deinit();
            if (outer != null and outer.?.value.pending != null)
                return error.ControllerRecoveryUnavailable;
            const current = parent.current_occurrence orelse
                return error.ControllerRecoveryUnavailable;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", current, parent.id);
            defer pending.deinit();
            if (pending.value.state != .ready and pending.value.state != .not_sent)
                return error.UnsettledOccurrence;
            _ = try occurrenceSubject(self, a, parent, pending.value);
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                current,
                parent.id,
            );
            defer route.deinit();
            const id = parent.controller_interaction orelse
                return error.ControllerRecoveryUnavailable;
            if (!std.meta.eql(route.value.interaction, id))
                return error.ControllerRecoveryUnavailable;
            var saved = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                id,
                parent.id,
            );
            defer saved.deinit();
            if (!std.meta.eql(saved.value.model, current) and !std.meta.eql(
                saved.value.handoff,
                current,
            )) return error.ControllerRecoveryUnavailable;
            if (std.meta.eql(saved.value.model, current) and saved.value.handoff != null)
                return error.ControllerRecoveryUnavailable;
            return saved.value;
        }
        pub fn adoptController(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            expected_revision: u64,
            command: wc.Adoption,
        ) !Admission {
            const request = try operation(state.ControllerAdoptionRequest, a, .{
                .task = task_id,
                .revision = expected_revision,
                .command = command,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatible(self, parent.value);
            try requireCustody(self, a, task_id, null);
            if (parent.value.revision != expected_revision) return error.StaleRevision;
            const interaction = try controllerRecoveryCut(self, a, parent.value);
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                parent.value.current_occurrence.?,
                task_id,
            );
            defer pending.deinit();
            const admitted =
                try admitControllerSuccession(self, a, parent.value, interaction, command, true);
            defer a.free(admitted.input);
            defer freeControllerViewWorks(a, admitted.works);
            const encoded = try contracts.encodeOwned(wc.Adoption, a, command);
            defer a.free(encoded);
            var succession_id: state.Digest = undefined;
            try self.io.randomSecure(&succession_id);
            return publishControllerAdoption(self, a, .{
                .operation_id = operation_id,
                .task_id = task_id,
                .expected_revision = expected_revision,
                .request = request,
                .parent = parent.value,
                .interaction = interaction,
                .pending = pending.value,
                .admitted = admitted,
                .encoded = encoded,
                .succession_id = succession_id,
            });
        }
        fn publishControllerAdoption(
            self: *Self,
            a: std.mem.Allocator,
            cut: ControllerAdoption,
        ) !Admission {
            const event_data = try std.fmt.allocPrint(a, "{{\"operation\":\"{s}\"}}", .{
                std.fmt.bytesToHex(cut.succession_id, .lower),
            });
            defer a.free(event_data);
            try ensureOwnershipCapacity(self, cut.task_id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try retire(self, a);
            var value = cut.parent;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.controller_succession = cut.succession_id;
            value.schedule = .queued;
            value.blocker = null;
            try store(self).begin();
            defer store(self).rollback();
            try storeControllerAdoption(self, cut, value);
            try event(self, &value, .controller_requested, event_data);
            const receipt_value = try receipt(
                self,
                a,
                .adopt,
                cut.operation_id,
                cut.request,
                value,
                .accepted,
                null,
                null,
            );
            try persistScheduled(
                self,
                a,
                value,
                cut.expected_revision,
                "controller.operator-prepare",
                .acquire,
                &.{.{ .task = cut.task_id }},
            );
            return receipt_value;
        }
        fn storeControllerAdoption(self: *Self, cut: ControllerAdoption, value: state.Task) !void {
            try store(self).createRecord(
                state.ControllerSuccession,
                "controller_succession",
                cut.succession_id,
                cut.task_id,
                .{
                    .id = cut.succession_id,
                    .task = cut.task_id,
                    .command = try store(self).putObject(cut.encoded),
                    .predecessor = cut.interaction.controller,
                    .handoff = cut.parent.current_occurrence.?,
                    .checkpoint = cut.parent.checkpoint,
                    .outcome = cut.parent.outcome,
                    .event_cut = cut.parent.event_high,
                    .next_message = cut.parent.next_message,
                    .policy = cut.parent.profile,
                    .successor = cut.admitted.successor,
                    .converter = cut.admitted.converter,
                    .conversion_input = try store(self).putObject(cut.admitted.input),
                    .view_works = .{ .items = cut.admitted.works },
                    .phase = .preparing,
                    .operator_admission = .{
                        .revision = value.revision,
                        .event = try std.math.add(u64, value.event_high, 1),
                        .occurrence = cut.pending,
                    },
                },
            );
        }
        pub fn dispatchController(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
            subject: OccurrenceSubject,
        ) !Step {
            var payload = controllerReply(
                self,
                a,
                initial,
                pending,
                request,
            ) catch |err| return blockControllerRequest(self, a, initial, pending, err);
            defer a.free(payload);
            if (same(request.binding.semantic_identity, contracts.controller.handoff_identity)) {
                switch (controllerHandoff(
                    self,
                    a,
                    initial,
                    pending,
                    payload[0 .. payload.len - 1],
                ) catch |err| return blockControllerRequest(self, a, initial, pending, err)) {
                    .ordinary => {},
                    .progressed => return .progressed,
                    .diagnostic => |diagnostic| {
                        const encoded = try contracts.encodeOwned(
                            ?contracts.controller.Diagnostic,
                            a,
                            diagnostic,
                        );
                        defer a.free(encoded);
                        const replacement = try std.mem.concat(a, u8, &.{
                            payload[0 .. payload.len - 1],
                            encoded,
                        });
                        a.free(payload);
                        payload = replacement;
                    },
                }
            }
            return publishControllerReply(self, a, initial, pending, request, subject, payload);
        }
        fn publishControllerReply(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
            subject: OccurrenceSubject,
            payload: []const u8,
        ) !Step {
            const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = payload,
            });
            defer a.free(reply);
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const binding: occurrence.Binding = .{
                .id = pending.id,
                .task = pending.task,
                .request = pending.request,
            };
            const dispatched = try occurrence.dispatch(
                pending,
                binding,
                attempt,
                subject.cancelling,
                subject.cleanup,
            );
            const acquired =
                try occurrence.acquired(dispatched, binding, attempt, storage.digest(reply));
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.schedule = .active;
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(reply);
            try storeControllerOffer(self, a, initial, pending, request, payload, &value);
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                pending.id,
                value.id,
                acquired,
            );
            try persist(self, a, value, initial.revision, "controller.acquire", .preserve);
            return .progressed;
        }
        fn storeControllerOffer(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
            payload: []const u8,
            value: *state.Task,
        ) !void {
            if (same(request.binding.semantic_identity, contracts.controller.offer_identity)) {
                const controller = initial.controller orelse return error.InvalidControllerBinding;
                const binding_value =
                    try controllerBinding(self, a, initial, controller);
                var program =
                    try self.workspaceProgram(a, initial.id, binding_value.program);
                defer program.deinit();
                var entry = for (self.handlers.entries) |item| {
                    if (item.declaration.controller_import == .deliberate) break item;
                } else return error.MissingCapability;
                entry.controller_envelope = true;
                const proposal = try entry.payload(a, payload);
                const overlay = try controllerOverlay(
                    self,
                    a,
                    initial,
                    controller,
                    pending.id,
                    initial.event_high,
                    initial.next_message,
                    initial.controller_epoch,
                );
                defer a.free(overlay);
                try store(self).createRecord(
                    state.ControllerInteraction,
                    "controller_interaction",
                    pending.id,
                    initial.id,
                    .{
                        .id = pending.id,
                        .task = initial.id,
                        .controller = controller,
                        .epoch = initial.controller_epoch,
                        .offered = try store(self).putObject(payload),
                        .carry = try store(self).putObject(payload[proposal.len..]),
                        .carry_schema = try store(self).putObject(
                            program.value.description.controller.?.carry.bytes,
                        ),
                        .overlay = try store(self).putObject(overlay),
                        .event_cut = initial.event_high,
                        .next_message = initial.next_message,
                        .policy = initial.profile,
                    },
                );
                value.controller_interaction = pending.id;
            }
        }
        pub fn blockControllerRequest(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            err: anyerror,
        ) !Step {
            return switch (err) {
                error.CorruptState, error.CorruptObject, error.StorageUnavailable => err,
                error.OutOfMemory, error.Capacity => blockedOccurrence(
                    self,
                    a,
                    parent,
                    pending,
                    .capacity,
                ),
                error.Denied => blockedOccurrence(self, a, parent, pending, .denied),
                else => blockedOccurrence(self, a, parent, pending, .incompatible_profile),
            };
        }
        fn controllerOverlayCurrent(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            interaction: state.ControllerInteraction,
        ) !bool {
            if (interaction.next_message != parent.next_message or
                interaction.epoch != parent.controller_epoch) return false;
            const bytes = try store(self).object(a, interaction.overlay, null);
            defer a.free(bytes);
            var overlay = try json.parseAsset(a, bytes, bytes.len);
            defer overlay.deinit();
            const control = json.get(overlay.value, "control") orelse
                return error.InvalidControllerBinding;
            const target = try values.fromJson(
                wc.ControllerTarget,
                a,
                json.get(control, "realization_target") orelse
                    return error.InvalidControllerBinding,
            );
            if (target != .action) return error.InvalidControllerBinding;
            return target.action.realization_revision == parent.realization_revision;
        }
        pub fn refreshControllerOverlay(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
        ) !bool {
            if (pending.work != null or pending.residual != null) return false;
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                parent.id,
            );
            defer route.deinit();
            const id = route.value.interaction orelse return false;
            var saved = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                id,
                parent.id,
            );
            defer saved.deinit();
            if (!std.meta.eql(saved.value.model, pending.id) or !std.meta.eql(
                saved.value.controller,
                parent.controller orelse return error.InvalidControllerBinding,
            )) return error.InvalidControllerBinding;
            if (try controllerOverlayCurrent(self, a, parent, saved.value)) return false;
            if (pending.state != .ready) return error.UnsettledOccurrence;
            const overlay = try controllerOverlay(
                self,
                a,
                parent,
                saved.value.controller,
                id,
                parent.event_high,
                parent.next_message,
                parent.controller_epoch,
            );
            defer a.free(overlay);
            var value = parent;
            value.revision = try std.math.add(u64, parent.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            saved.value.overlay = try store(self).putObject(overlay);
            saved.value.next_message = parent.next_message;
            saved.value.event_cut = parent.event_high;
            saved.value.epoch = parent.controller_epoch;
            try store(self).putRecord(
                state.ControllerInteraction,
                "controller_interaction",
                id,
                parent.id,
                saved.value,
            );
            try persist(self, a, value, parent.revision, "controller.overlay", .preserve);
            return true;
        }
    };
}
