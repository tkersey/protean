const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const authorizeWorkspaceOccurrence = Access.authorizeWorkspaceOccurrence;
        const controllerBinding = Controller.controllerBinding;
        const controllerEpochAt = Controller.controllerEpochAt;
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        const occurrenceImage = Root.occurrenceImage;
        const record = Records.record;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const store = Lifecycle.store;
        const validateArchiveControllerRecord = Publication.validateArchiveControllerRecord;
        const validateArchiveValueDerivation = Snapshots.validateArchiveValueDerivation;
        const validateBindingSuccession = Snapshots.validateBindingSuccession;
        const validateCandidateProduction = Observations.validateCandidateProduction;
        const validateControllerOperation = Controller.validateControllerOperation;
        const validateDelegation = Snapshots.validateDelegation;
        const validateHistoricalOccurrence = Replay.validateHistoricalOccurrence;
        const validateResidualObservation = Residuals.validateResidualObservation;
        const validateRootOperation = Controller.validateRootOperation;
        const validateWaitSelection = Snapshots.validateWaitSelection;
        const validateWorkspaceWorkSnapshotIn = Snapshots.validateWorkspaceWorkSnapshotIn;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceValueReferenceIn = Contexts.workspaceValueReferenceIn;
        const workspaceViewObservation = Sources.workspaceViewObservation;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Sources = @import("workspace_sources.zig").Operations(Types, Self);
        pub fn validateWorkspaceReceipts(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const task_id = parent.id;
            if (parent.controller_epoch != try controllerEpochAt(
                self,
                a,
                parent,
                parent.event_high,
            )) return error.InvalidArchive;
            var receipts = try store(self).database.prepare(
                "SELECT o.body FROM operations p JOIN objects o ON o.digest=p.rec" ++
                    "eipt WHERE p.task=?",
                &.{.{ .blob = &task_id }},
            );
            defer receipts.deinit();
            while (try receipts.step() == .row) {
                var receipt_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer receipt_arena.deinit();
                const frame = receipt_arena.allocator();
                var receipt_value =
                    try contracts.decodeOwned(state.Receipt, frame, try receipts.bytes(0));
                defer receipt_value.deinit();
                try validateWorkspaceReceipt(
                    self,
                    frame,
                    parent,
                    receipt_value.value,
                    records,
                    checked,
                );
            }
        }
        pub fn validateWorkspaceControllerBindings(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            records: []const state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;
            var controller_ids: std.AutoHashMap(state.Digest, void) = .init(a);
            var controller_cursor = parent.controller;
            var controller_epoch: ?u64 = null;
            var controller_activation: ?u64 = null;
            while (controller_cursor) |id| {
                var binding_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer binding_arena.deinit();
                const frame = binding_arena.allocator();
                try requireArchiveRecord(records, .controller_binding, id);
                const binding = try controllerBinding(self, frame, parent, id);
                if (controller_epoch) |epoch| if (binding.epoch >= epoch)
                    return error.InvalidArchive;
                if (binding.activated_at == 0 or binding.activated_at > parent.event_high)
                    return error.InvalidArchive;
                if (controller_activation) |at| if (binding.activated_at >= at)
                    return error.InvalidArchive;
                if (binding.predecessor == null and binding.epoch != 0) return error.InvalidArchive;
                if (binding.epoch > parent.controller_epoch) return error.InvalidArchive;
                if (binding.predecessor != null)
                    try validateBindingSuccession(self, frame, task_id, records, binding);

                var image = try data.program_image.decode(
                    self.allocator,
                    try store(self).object(frame, binding.image, null),
                );
                defer image.deinit();
                if (!std.meta.eql(image.identity, binding.program_identity))
                    return error.InvalidArchive;
                try controller_ids.put(id, {});
                controller_epoch = binding.epoch;
                controller_activation = binding.activated_at;
                controller_cursor = binding.predecessor;
            }
            for (records) |row| if (row.kind == .controller_binding and
                !controller_ids.contains(row.id)) return error.InvalidArchive;
            if (parent.controller_interaction) |id| {
                try requireArchiveRecord(records, .controller_interaction, id);
                var interaction = try record(
                    self,
                    state.ControllerInteraction,
                    a,
                    "controller_interaction",
                    id,
                    task_id,
                );
                defer interaction.deinit();
                if (!std.meta.eql(
                    @as(?state.Digest, interaction.value.controller),
                    parent.controller,
                )) return error.InvalidArchive;
            }
        }
        pub fn validateWorkspaceGenerations(
            self: *Self,
            parent: state.Task,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
            generations: anytype,
        ) !void {
            const task_id = parent.id;
            for (records) |row| {
                if (row.kind != .workspace_work) continue;
                var work_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer work_arena.deinit();
                const frame = work_arena.allocator();
                var saved = try self.workspaceWork(frame, task_id, row.id);
                defer saved.deinit();
                const value = saved.value;
                for (0..std.math.cast(usize, value.port_generation) orelse
                    return error.InvalidArchive) |i| if (!generations.contains(.{
                    .work = value.id,
                    .generation = i + 1,
                })) return error.InvalidArchive;
                try validateWorkspaceWorkSnapshotIn(
                    self,
                    parent,
                    try freezeWorkspaceWork(
                        self,
                        frame,
                        task_id,
                        try wp.reference(frame, .work, value.id),
                        true,
                    ),
                    records,
                    checked,
                );
            }
        }
        pub fn validateWorkspaceRecordBody(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
            generations: anytype,
        ) !void {
            switch (row.kind) {
                .controller_succession,
                .controller_residual,
                .controller_interaction,
                => try validateArchiveControllerRecord(self, parent, row, records, checked),
                .workspace_trial => try validateArchiveWorkspaceTrial(self, frame, parent, row),
                .root_operation => try validateArchiveRootOperation(self, frame, parent, row),
                .workspace_runtime => try validateArchiveWorkspaceRuntime(self, frame, parent, row),
                .workspace_candidate => try validateArchiveWorkspaceCandidate(
                    self,
                    frame,
                    parent,
                    row,
                ),
                .workspace_program => try validateArchiveWorkspaceProgram(self, frame, parent, row),
                .workspace_value => try validateArchiveWorkspaceValue(
                    self,
                    frame,
                    parent,
                    row,
                    records,
                    checked,
                ),
                .workspace_view => try validateArchiveWorkspaceView(self, frame, parent, row),
                .workspace_port => try validateArchiveWorkspacePort(
                    self,
                    frame,
                    parent,
                    row,
                    records,
                    generations,
                ),
                .workspace_port_reply => try validateArchiveWorkspacePortReply(
                    self,
                    frame,
                    parent,
                    row,
                ),
                .execution_route => try requireArchiveRecord(records, .occurrence, row.id),
                .workspace_reply => try validateArchiveWorkspaceReply(
                    self,
                    frame,
                    parent,
                    row,
                    records,
                ),
                .workspace_delegation => try validateDelegation(self, frame, parent, row, records),
                .workspace_wait => try validateArchiveWorkspaceWait(
                    self,
                    frame,
                    parent,
                    row,
                    records,
                ),
                else => {},
            }
        }
        fn validateArchiveWorkspaceTrial(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var work = try self.workspaceWork(frame, task_id, row.id);
            defer work.deinit();
            if (!std.meta.eql(work.value.trial, row.id)) return error.InvalidArchive;
        }
        fn validateArchiveRootOperation(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var saved =
                try record(self, state.RootOperation, frame, "root_operation", row.id, task_id);
            defer saved.deinit();
            _ = try validateRootOperation(self, frame, parent, saved.value);
        }
        fn validateArchiveWorkspaceRuntime(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var record_value =
                try record(self, workspace.Runtime, frame, "workspace_runtime", row.id, task_id);
            defer record_value.deinit();
            var admitted = try workspaceRuntime(
                self,
                frame,
                task_id,
                record_value.value.artifact.digest,
                record_value.value.program,
            );
            defer admitted.deinit();
        }
        fn validateArchiveWorkspaceCandidate(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var saved = try record(
                self,
                workspace.Candidate,
                frame,
                "workspace_candidate",
                row.id,
                task_id,
            );
            defer saved.deinit();
            var candidate =
                try self.workspaceCandidate(frame, task_id, saved.value.artifact.digest);
            defer candidate.deinit();
            try validateCandidateProduction(self, frame, candidate.value);
        }
        fn validateArchiveWorkspaceProgram(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var record_value =
                try record(self, workspace.Program, frame, "workspace_program", row.id, task_id);
            defer record_value.deinit();
            var admitted =
                try self.workspaceProgram(frame, task_id, record_value.value.artifact.digest);
            defer admitted.deinit();
        }
        fn validateArchiveWorkspaceValue(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const task_id = parent.id;

            var record_value =
                try record(self, workspace.Value, frame, "workspace_value", row.id, task_id);
            defer record_value.deinit();
            const admitted = try workspaceValueReferenceIn(
                self,
                frame,
                task_id,
                try wp.reference(frame, .value, record_value.value.artifact.digest),
                checked,
            );
            const descriptor_bytes = try store(self).object(frame, admitted.schema, null);
            var descriptor = try data.schema.decode(frame, descriptor_bytes);
            defer descriptor.deinit();
            try data.schema.validateValue(
                frame,
                descriptor.descriptor,
                try store(self).object(frame, admitted.value, null),
            );
            for (record_value.value.derivation.sources.items) |ref| {
                const source = try workspaceValueReferenceIn(
                    self,
                    frame,
                    task_id,
                    try wp.reference(frame, .value, ref.digest),
                    checked,
                );
                if (!std.meta.eql(source.artifact, ref)) return error.InvalidArchive;
            }
            try validateArchiveValueDerivation(
                self,
                frame,
                parent,
                record_value.value,
                admitted,
                records,
                checked,
            );
        }
        fn validateArchiveWorkspaceView(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var record_value =
                try record(self, workspace.View, frame, "workspace_view", row.id, task_id);
            defer record_value.deinit();
            _ = try workspaceViewObservation(
                self,
                frame,
                task_id,
                record_value.value.artifact.digest,
                .{ .maximum = 1 },
            );
        }
        fn validateArchiveWorkspacePort(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
            generations: anytype,
        ) !void {
            const task_id = parent.id;

            var port =
                try record(self, workspace.Port, frame, "workspace_port", row.id, task_id);
            defer port.deinit();
            try requireArchiveRecord(records, .occurrence, port.value.occurrence);
            var route = try record(
                self,
                workspace.ExecutionRoute,
                frame,
                "execution_route",
                port.value.occurrence,
                task_id,
            );
            defer route.deinit();
            if (route.value.port == null or !std.meta.eql(route.value.port.?, row.body))
                return error.InvalidArchive;
            const entry = try generations.getOrPut(.{
                .work = port.value.work,
                .generation = port.value.generation,
            });
            if (entry.found_existing) return error.InvalidArchive;
        }
        fn validateArchiveWorkspacePortReply(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var answer = try record(
                self,
                workspace.PortReply,
                frame,
                "workspace_port_reply",
                row.id,
                task_id,
            );
            defer answer.deinit();
            var port = try contracts.decodeOwned(
                workspace.Port,
                frame,
                try store(self).object(frame, answer.value.port, null),
            );
            defer port.deinit();
            var pending = try record(
                self,
                occurrence.Occurrence,
                frame,
                "occurrence",
                port.value.occurrence,
                task_id,
            );
            defer pending.deinit();
            const acquired = switch (pending.value.state) {
                .settled_reply => |reply| reply,
                .admitted => |admitted| if (admitted ==
                    .reply) admitted.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (!std.meta.eql(acquired.attempt, row.id) or !std.meta.eql(
                acquired.reply,
                answer.value.reply.digest,
            )) return error.InvalidArchive;
        }
        fn validateArchiveWorkspaceReply(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            try requireArchiveRecord(records, .occurrence, row.id);
            var pending =
                try record(self, occurrence.Occurrence, frame, "occurrence", row.id, task_id);
            defer pending.deinit();
            if (pending.value.work != null or !(pending.value.state == .settled_reply or
                (pending.value.state == .admitted and pending.value.state.admitted == .reply)))
                return error.InvalidArchive;
        }
        fn validateArchiveWorkspaceWait(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
        ) !void {
            const task_id = parent.id;

            var wait =
                try record(self, workspace.Wait, frame, "workspace_wait", row.id, task_id);
            defer wait.deinit();
            try requireArchiveRecord(records, .occurrence, wait.value.id);
            var pending = try record(
                self,
                occurrence.Occurrence,
                frame,
                "occurrence",
                wait.value.id,
                task_id,
            );
            defer pending.deinit();
            if (pending.value.work != null or !std.meta.eql(
                wait.value.request,
                pending.value.request_object,
            )) return error.InvalidArchive;
            var request = try data.invocation.decode(
                data.invocation.Request,
                frame,
                try store(self).object(frame, wait.value.request, null),
            );
            defer request.deinit();
            const entry = try self.handlers.resolve(
                request.value,
                try occurrenceImage(self, frame, parent, pending.value),
            );
            if (entry.declaration.kind != .workspace) return error.InvalidArchive;
            var authorized = try contracts.decodeOwned(
                workspace.Authorized,
                frame,
                try authorizeWorkspaceOccurrence(
                    self,
                    frame,
                    parent,
                    pending.value,
                    entry,
                    request.value.binding.payload,
                ),
            );
            defer authorized.deinit();
            try validateWaitSelection(self, frame, task_id, wait.value, authorized.value);
        }
        fn validateWorkspaceReceipt(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            receipt_value: state.Receipt,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            const task_id = parent.id;
            if (receipt_value.method == .workspace and receipt_value.workspace_kind == .residual) {
                try validateResidualReceipt(self, frame, parent, receipt_value);
                return;
            }
            if (receipt_value.method != .workspace or receipt_value.workspace_kind != .work)
                return;
            var observed = try contracts.decodeOwned(
                workspace.WorkObservation,
                frame,
                try store(self).object(frame, receipt_value.workspace_observation orelse
                    return error.InvalidArchive, null),
            );
            defer observed.deinit();
            if (!std.meta.eql(receipt_value.task, task_id) or !std.meta.eql(
                receipt_value.workspace orelse return error.InvalidArchive,
                observed.value.work.id,
            )) return error.InvalidArchive;
            var publication = try store(self).database.prepare(
                "SELECT revision FROM events WHERE task=? AND seq=?",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, observed.value.work.event_watermark) orelse
                        return error.InvalidArchive,
                } },
            );
            defer publication.deinit();
            if (try publication.step() != .row or try publication.integer(0) != std.math.cast(
                i64,
                receipt_value.revision,
            ) orelse return error.InvalidArchive) return error.InvalidArchive;
            try validateWorkspaceWorkSnapshotIn(self, parent, observed.value, records, checked);
            try validateHistoricalOccurrence(self, frame, observed.value);
        }
        fn validateResidualReceipt(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            receipt_value: state.Receipt,
        ) !void {
            const task_id = parent.id;
            var residual = try contracts.decodeOwned(
                state.ControllerResidual,
                frame,
                try store(self).object(frame, receipt_value.workspace_observation orelse
                    return error.InvalidArchive, null),
            );
            defer residual.deinit();
            if (!std.meta.eql(receipt_value.workspace, residual.value.id) or
                !std.meta.eql(residual.value.task, task_id)) return error.InvalidArchive;
            try validateResidualObservation(self, frame, .from(residual.value));
            if (residual.value.outer_operation) |pending|
                _ =
                    try validateControllerOperation(
                        self,
                        frame,
                        parent,
                        pending,
                        residual.value,
                        true,
                    );
        }
    };
}
