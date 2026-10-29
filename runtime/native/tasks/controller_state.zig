const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const capsuleDependencies = Realization.capsuleDependencies;
        const compatibleApplication = Admission.compatibleApplication;
        const record = Records.record;
        const residualProvenance = Residuals.residualProvenance;
        const retainResidualOperation = Residuals.retainResidualOperation;
        const store = Lifecycle.store;
        const workspaceRuntime = Programs.workspaceRuntime;
        const Admission = @import("admission.zig").Operations(Types, Self);
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        pub fn acceptsMessages(self: *Self) bool {
            for (self.handlers.entries) |entry| if (entry.declaration.kind == .inbox) return true;
            return false;
        }
        pub fn compatible(self: *Self, value: state.Task) !void {
            try compatibleApplication(self, value);
            if (!same(&value.profile.digest, &storage.digest(self.profile.bytes)) or
                !same(&value.runtime_identity, &self.profile.runtime_identity))
                return error.IncompatibleProfile;
            if (value.resources.items.len != self.profile.resources.len)
                return error.IncompatibleProfile;
            for (value.resources.items, self.profile.resources) |reference, bytes| {
                if (reference.bytes != bytes.len or !same(
                    &reference.digest,
                    &storage.digest(bytes),
                )) return error.IncompatibleProfile;
            }
        }
        pub fn controllerBinding(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            id: state.Digest,
        ) !state.ControllerBinding {
            var saved =
                try record(self, state.ControllerBinding, a, "controller_binding", id, value.id);
            defer saved.deinit();
            const binding = saved.value;
            if (!std.meta.eql(binding.id, id) or !std.meta.eql(binding.task, value.id))
                return error.CorruptState;
            var program = try self.workspaceProgram(a, value.id, binding.program);
            defer program.deinit();
            if (program.value.description.controller == null or !std.meta.eql(
                program.value.description.image,
                binding.image,
            )) return error.CorruptState;
            if (binding.predecessor == null) {
                const seed = self.application.controller orelse return error.InvalidArchive;
                if (binding.epoch != 0 or binding.activated_at != 1 or
                    !std.meta.eql(binding.image, value.image) or
                    !std.meta.eql(binding.program_identity, self.application.image_identity) or
                    !std.meta.eql(program.value.description.source, state.Reference{
                        .digest = storage.digest(seed.source),
                        .bytes = seed.source.len,
                    })) return error.InvalidArchive;
            }
            return binding;
        }
        pub fn rootImage(self: *Self, a: std.mem.Allocator, value: state.Task) !state.Reference {
            if (value.controller) |id| return (try controllerBinding(self, a, value, id)).image;
            return value.image;
        }
        pub fn controllerAt(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            watermark: u64,
        ) !?state.Digest {
            if (watermark > value.event_high) return error.InvalidArchive;
            var cursor = value.controller;
            var after: ?u64 = null;
            while (cursor) |id| {
                const binding = try controllerBinding(self, a, value, id);
                if (after) |later| if (binding.activated_at >= later) return error.CorruptState;
                if (binding.activated_at <= watermark) return id;
                after = binding.activated_at;
                cursor = binding.predecessor;
            }
            return null;
        }
        pub fn rootProgramIdentity(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
        ) !state.Digest {
            if (value.controller) |id| return (try controllerBinding(
                self,
                a,
                value,
                id,
            )).program_identity;
            return self.application.image_identity;
        }
        pub fn controllerEpochAt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            watermark: u64,
        ) !u64 {
            if (watermark > parent.event_high) return error.InvalidArchive;
            var epoch: u64 = 0;
            var rows = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq",
                &.{ .{ .blob = &parent.id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer rows.deinit();
            while (try rows.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try rows.bytes(0));
                defer event_value.deinit();
                const saved_event = event_value.value;
                if (saved_event.kind != .controller and saved_event.kind != .imported) continue;
                var parsed = try json.parse(a, saved_event.data.bytes, .{});
                defer parsed.deinit();
                if (saved_event.kind == .controller) {
                    const next = try json.decimal(u64, json.get(parsed.value, "epoch") orelse
                        return error.InvalidArchive);
                    if (next != (std.math.add(u64, epoch, 1) catch return error.InvalidArchive))
                        return error.InvalidArchive;
                    epoch = next;
                } else {
                    epoch = try importedControllerEpoch(self, a, parent.id, parsed.value, epoch);
                }
            }
            return epoch;
        }
        fn importedControllerEpoch(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            event_data: json.Value,
            epoch: u64,
        ) !u64 {
            var id: state.Digest = undefined;
            _ = std.fmt.hexToBytes(&id, try json.text(json.get(event_data, "archive_sha256") orelse
                return error.InvalidArchive)) catch return error.InvalidArchive;
            var origin = try record(self, state.Origin, a, "origin", id, task_id);
            defer origin.deinit();
            if (origin.value.transfer) |transfer| {
                const p = @import("../placement.zig");
                var succession =
                    try record(self, p.Succession, a, "placement_succession", transfer, task_id);
                defer succession.deinit();
                const intent = succession.value.offer.value.intent;
                try p.matchDecision(a, succession.value.offer.value, succession.value.decision);
                if (succession.value.decision.value.verdict != .accepted or
                    !std.meta.eql(intent.subject.task, task_id)) return error.InvalidArchive;
                if (intent.subject.work == null) {
                    if (intent.epoch != epoch) return error.InvalidArchive;
                    return succession.value.decision.value.epoch;
                }
            }

            return epoch;
        }
        pub fn rootRouteImage(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            route: workspace.ExecutionRoute,
        ) !state.Reference {
            if (route.work != null) return error.CorruptState;
            if (route.controller) |id| {
                var cursor = value.controller;
                var last_epoch: ?u64 = null;
                while (cursor) |current| {
                    const binding = try controllerBinding(self, a, value, current);
                    if (last_epoch) |epoch| if (binding.epoch >= epoch) return error.CorruptState;
                    if (std.meta.eql(current, id)) {
                        if (!std.meta.eql(binding.program_identity, route.program_identity))
                            return error.CorruptState;
                        return binding.image;
                    }
                    last_epoch = binding.epoch;
                    cursor = binding.predecessor;
                }
                return error.CorruptState;
            }
            if (!std.meta.eql(route.program_identity, self.application.image_identity))
                return error.CorruptState;
            return value.image;
        }
        pub fn rootDriver(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            instance: data.invocation.Instance,
        ) !*evaluator.Driver {
            const reference = try rootImage(self, a, value);
            if (value.controller_runtime == null and std.meta.eql(reference, value.image))
                return evaluator.Driver.start(self.allocator, self.program, instance);
            const image = try store(self).object(a, reference, null);
            defer a.free(image);
            var runtime =
                try controllerRuntime(self, a, value.id, reference, value.controller_runtime);
            defer runtime.deinit();
            return evaluator.Driver.openSelected(self.allocator, image, instance, &runtime);
        }
        pub fn controllerRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            image: state.Reference,
            reference: ?state.Reference,
        ) !kosmos.RuntimeArtifact {
            const ref = reference orelse return self.program.retainRuntime();
            var selected = try workspaceRuntime(self, a, task_id, ref.digest, null);
            defer selected.record.deinit();
            errdefer selected.admitted.deinit();
            var program =
                try self.workspaceProgram(a, task_id, selected.record.value.program);
            defer program.deinit();
            if (!std.meta.eql(ref, selected.record.value.artifact) or
                !std.meta.eql(image, program.value.description.image)) return error.InvalidRuntime;
            return selected.admitted;
        }
        pub fn rootIdentity(id: state.TaskId) state.Digest {
            return state.controllerExecutionIdentity(id);
        }
        pub fn rootProvenance(value: state.Task) kosmos.RuntimeCapsule.Provenance {
            return .{
                .execution = rootIdentity(value.id),
                .custody = storage.digest(&value.id),
                .publication = .{
                    .digest = value.checkpoint.digest,
                    .bytes = value.checkpoint.bytes,
                },
            };
        }
        pub fn rootOperation(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
        ) !?contracts.Decoded(state.RootOperation) {
            const bytes = try store(self).recordBytes(
                a,
                "root_operation",
                rootIdentity(value.id),
                value.id,
            ) orelse return null;
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.RootOperation, a, bytes);
            errdefer decoded.deinit();
            if (!std.meta.eql(decoded.value.id, rootIdentity(value.id)) or
                !std.meta.eql(decoded.value.task, value.id) or
                decoded.value.execution_revision != value.execution_revision)
                return error.InvalidArchive;
            return decoded;
        }
        pub fn putRootOperation(
            self: *Self,
            a: std.mem.Allocator,
            value: state.RootOperation,
        ) !void {
            if (try store(self).recordBytes(a, "root_operation", value.id, value.task)) |bytes| {
                a.free(bytes);
                try store(self).putRecord(
                    state.RootOperation,
                    "root_operation",
                    value.id,
                    value.task,
                    value,
                );
            } else try store(self).createRecord(
                state.RootOperation,
                "root_operation",
                value.id,
                value.task,
                value,
            );
        }
        pub fn rootConsumed(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            control: data.invocation.Control,
        ) !?occurrence.Occurrence {
            if (control != .reply and control != .cancel) return null;
            const id = value.current_occurrence orelse return null;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, value.id);
            defer pending.deinit();
            return try occurrence.consumed(
                pending.value,
                .{ .id = id, .task = value.id, .request = pending.value.request },
                if (control == .cancel) .cancel else .{ .reply = storage.digest(control.reply) },
                value.cancellation != null,
            );
        }
        pub fn retainRootOperation(self: *Self, a: std.mem.Allocator) !void {
            const active = self.active orelse return;
            if (active.subject == .residual)
                return retainResidualOperation(self, a, active);
            if (active.subject != .root or active.root_control == null) return;
            var saved = try self.task(a, active.task);
            defer saved.deinit();
            if (saved.value.execution_revision != active.execution_revision)
                return error.CorruptState;
            const capsule = try active.driver.retainCapsule(rootProvenance(saved.value));
            const dependencies = try capsuleDependencies(a, capsule);
            defer a.free(dependencies);
            const code = try active.driver.runtimeBytes(a);
            defer a.free(code);
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(code);
            const pending: state.OuterOperation = .{
                .capsule = try store(self).putObject(capsule),
                .dependencies = .{ .items = dependencies },
                .control = try store(self).putObject(active.root_control.?),
                .guest_quantum = active.root_quantum,
            };
            try putRootOperation(self, a, .{
                .id = rootIdentity(active.task),
                .task = active.task,
                .execution_revision = active.execution_revision,
                .pending = pending,
            });
            try self.namespace.commit("controller.outer-suspend");
            self.active.?.outer_operation = pending.capsule;
        }
        pub fn validateRootOperation(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            saved: state.RootOperation,
        ) !bool {
            if (!std.meta.eql(saved.id, rootIdentity(value.id)) or !std.meta.eql(
                saved.task,
                value.id,
            ) or saved.execution_revision != value.execution_revision) return error.InvalidArchive;
            const pending = saved.pending orelse return false;
            return validateControllerOperation(self, a, value, pending, null, false);
        }
        pub fn validateControllerOperation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: state.OuterOperation,
            residual: ?state.ControllerResidual,
            historical: bool,
        ) !bool {
            const value = controllerOperationTask(parent, residual);
            if (value.terminal() or pending.guest_quantum > 256) return error.InvalidArchive;
            const bytes = try store(self).object(a, pending.capsule, null);
            defer a.free(bytes);
            var envelope = try kosmos.RuntimeCapsule.read(a, bytes);
            defer envelope.deinit();
            const record_value = envelope.value.record;
            const effective_image = try validateControllerCapsule(
                self,
                a,
                parent,
                value,
                pending,
                residual,
                record_value,
            );
            const image = try store(self).object(a, effective_image, null);
            defer a.free(image);
            var runtime = try controllerRuntime(
                self,
                a,
                parent.id,
                effective_image,
                if (residual) |retired| retired.runtime else value.controller_runtime,
            );
            defer runtime.deinit();
            var prepared = try kosmos.Prepared.initWithRuntime(a, image, &runtime);
            defer prepared.deinit();
            if (!std.meta.eql(record_value.artifact.digest, prepared.runtime.identity) or
                record_value.artifact.bytes != prepared.runtime.core.?.encoded_length)
                return error.InvalidArchive;
            const code = try store(self).object(
                a,
                .{
                    .digest = record_value.artifact.digest,
                    .bytes = record_value.artifact.bytes,
                },
                null,
            );
            defer a.free(code);
            try validateControllerCommand(
                self,
                a,
                value,
                pending,
                envelope.value.command,
                residual,
                historical,
            );
            const Inspect = struct {
                fn claim(
                    _: *anyopaque,
                    _: kosmos.RuntimeCapsule.Reference,
                    _: kosmos.RuntimeCapsule.Record,
                    _: kosmos.RuntimeCapsule.Reference,
                ) !void {}
            };
            var context: u8 = 0;
            var candidate = try kosmos.RuntimeCapsule.restore(
                a,
                &prepared.guest,
                &prepared.runtime,
                bytes,
                .{ .context = &context, .claim = Inspect.claim },
            );
            defer candidate.deinit();
            return record_value.operation == null;
        }
        fn controllerOperationTask(
            parent: state.Task,
            residual: ?state.ControllerResidual,
        ) state.Task {
            var value = parent;
            if (residual) |retired| {
                value.checkpoint = retired.checkpoint;
                value.outcome = retired.outcome;
                value.outcome_kind = retired.outcome_kind;
                value.current_occurrence = retired.current_occurrence;
                value.cancellation = .{ .bytes = "Controller superseded" };
                value.cancellation_applied = retired.cancellation_applied;
            }
            return value;
        }
        fn validateControllerCapsule(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: state.Task,
            pending: state.OuterOperation,
            residual: ?state.ControllerResidual,
            record_value: kosmos.RuntimeCapsule.Record,
        ) !state.Reference {
            const effective_image = if (residual) |retired| (try controllerBinding(
                self,
                a,
                parent,
                retired.controller,
            )).image else try rootImage(self, a, value);
            const provenance =
                if (residual) |retired| residualProvenance(retired) else rootProvenance(value);
            if (!std.meta.eql(record_value.provenance, provenance) or
                record_value.kind != .outer_execution or
                (record_value.operation != .advance and record_value.operation != null) or
                !std.meta.eql(record_value.guest.image.digest, effective_image.digest) or
                record_value.guest.image.bytes != effective_image.bytes)
                return error.InvalidArchive;
            if (pending.dependencies.items.len != record_value.dependencies.len)
                return error.InvalidArchive;
            for (pending.dependencies.items, record_value.dependencies) |ref, expected|
                if (!std.meta.eql(ref.digest, expected.digest) or ref.bytes != expected.bytes)
                    return error.InvalidArchive;

            return effective_image;
        }
        fn validateControllerCommand(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: state.OuterOperation,
            command_bytes: []const u8,
            residual: ?state.ControllerResidual,
            historical: bool,
        ) !void {
            // Check the exact accepted control against the original guest cut
            // and the acquired occurrence, independently of the outer machine.
            const control_bytes = try store(self).object(a, pending.control, null);
            defer a.free(control_bytes);
            var accepted = try contracts.decodeOwned(data.invocation.Control, a, control_bytes);
            defer accepted.deinit();
            var command = try kosmos.RuntimeCapsule.readCommand(a, command_bytes);
            defer command.deinit();
            if (command.value != .advance or
                command.value.advance.quantum != pending.guest_quantum or
                (pending.guest_quantum == 0 and accepted.value != .reply))
                return error.InvalidArchive;
            const actual = command.value.advance.control;
            switch (accepted.value) {
                .none => if (actual != .none or value.outcome_kind != .progressed or
                    value.current_occurrence != null)
                    return error.InvalidArchive,
                .resume_yield => if (actual != .resume_yield or value.outcome_kind != .yielded or
                    value.current_occurrence != null)
                    return error.InvalidArchive,
                .cancel => try validateControllerCancellation(
                    self,
                    a,
                    value,
                    accepted.value,
                    actual,
                    residual,
                    historical,
                ),
                .reply => try validateControllerAnswer(
                    self,
                    a,
                    value,
                    accepted.value,
                    actual,
                    residual,
                    historical,
                ),
            }
        }
        fn validateControllerCancellation(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            accepted: data.invocation.Control,
            actual: anytype,
            residual: ?state.ControllerResidual,
            historical: bool,
        ) !void {
            const reason = accepted.cancel;

            const cancellation = value.cancellation orelse return error.InvalidArchive;
            if (value.cancellation_applied or reason != .text or
                !same(reason.text, cancellation.bytes) or actual != .cancel or !data.record.equal(
                data.invocation.Reason,
                reason,
                actual.cancel,
            )) return error.InvalidArchive;
            if (residual) |retired| {
                if (value.current_occurrence) |id| {
                    var current =
                        try record(self, occurrence.Occurrence, a, "occurrence", id, value.id);
                    defer current.deinit();
                    if (current.value.work != null or (retired.cancellation_applied and
                        !std.meta.eql(current.value.residual, retired.id)))
                        return error.InvalidArchive;
                    if (historical and current.value.state == .admitted) {
                        if (current.value.state.admitted != .cancelled)
                            return error.InvalidArchive;
                    } else _ = try occurrence.consumed(
                        current.value,
                        .{
                            .id = id,
                            .task = value.id,
                            .work = null,
                            .residual = current.value.residual,
                            .request = current.value.request,
                        },
                        .cancel,
                        true,
                    );
                }
            } else _ = try rootConsumed(self, a, value, accepted);
        }
        fn validateControllerAnswer(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            accepted: data.invocation.Control,
            actual: anytype,
            residual: ?state.ControllerResidual,
            historical: bool,
        ) !void {
            const reply = accepted.reply;

            if (actual != .answer or value.outcome_kind != .requested or
                value.current_occurrence == null)
                return error.InvalidArchive;
            var response = try data.invocation.decode(data.invocation.Result, a, reply);
            defer response.deinit();
            var occurrence_value = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                value.current_occurrence.?,
                value.id,
            );
            defer occurrence_value.deinit();
            const prior = occurrence_value.value;
            const acquired = switch (prior.state) {
                .settled_reply => |saved| saved,
                .admitted => |saved| if (historical and
                    saved == .reply) saved.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (prior.work != null or !std.meta.eql(acquired.reply, storage.digest(reply)) or
                !std.meta.eql(prior.request, response.value.request_identity) or
                !same(actual.answer, response.value.value)) return error.InvalidArchive;
            if (residual) |retired| {
                if (!retired.cancellation_applied or !std.meta.eql(prior.residual, retired.id))
                    return error.InvalidArchive;
                if (!historical or prior.state != .admitted) _ = try occurrence.consumed(
                    prior,
                    .{
                        .id = prior.id,
                        .task = value.id,
                        .work = null,
                        .residual = retired.id,
                        .request = prior.request,
                    },
                    .{ .reply = storage.digest(reply) },
                    true,
                );
            } else _ = try rootConsumed(self, a, value, accepted);
        }
    };
}
